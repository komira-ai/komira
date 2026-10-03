"""THE THIRD WRITE LOOP. An h2 request whose `try_write` accepts 7 bytes a call
must still put byte-identical, correctly-framed bytes on the wire.

⭐ WHY A THIRD FILE. `komira_http` has THREE independent outbound write loops,
and a short-write test that covers one covers neither of the others:

  1. `OutboundDriver._drive_write`      — h1 head, advances `_write_cursor`
  2. `OutboundDriver._drive_write_body` — h1 streaming body, its own
                                          `written < n` inner loop
  3. `drive_h2_*` in `h2_client.mojo`   — h2, which does NOT carry a cursor at
                                          all: it calls
                                          `h2.consume_out_bytes_prefix(n)` to
                                          DROP the accepted prefix from a
                                          staging buffer
                                          (`h2_client.mojo:522-539, 2195-2216`)

(1) and (2) are covered by `test_scripted_fault_vocabulary.mojo`. (3) is the one
whose failure mode is worst — a prefix consumed by the wrong count does not
truncate the request, it DESYNCHRONISES THE FRAMING, and a peer reading a
9-byte h2 frame header out of the middle of a payload sees garbage rather than a
short read.

Why this is not covered elsewhere: the existing
large-body h2 test (`test_h2_large_request_body_send_flow_control.mojo`) drives
its own bespoke `SendFcH2Stream` double rather than `ScriptedStream`, so
`set_max_write_per_call` — the only short-write clamp in the package — cannot
reach the h2 write loop through it. `test_h2_post_body_not_double_drained.mojo`
DOES use `ScriptedStream`, but with a 53-byte body and no clamp, so every write
is accepted whole and the partial-accept branch never executes.

`h2.consume_out_bytes_prefix`'s own docstring says it exists "for the production
driver after a partial `stream.try_write` acceptance". Until this file, nothing
ever produced one.

Idiom + the canned-h2-response helpers are lifted from
`test_h2_post_body_not_double_drained.mojo`, its nearest neighbour.

Mojo 1.0.0b2 (def-only).
"""

from std.memory import ArcPointer

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http_client.body import BytesBody
from komira_http_client.client import HttpClient, build_request_with_body
from komira_http_client.header_map import HeaderMap
from komira_http_client.url import Url
from komira_http_core.codec.types import HttpMethod
from komira_http_core.codec.h2.connection_preface import (
    H2_CLIENT_PREFACE_LEN,
    H2_CLIENT_PREFACE,
)
from komira_http_core.codec.h2.frame import (
    FLAG_END_STREAM,
    FRAME_DATA,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from std.testing import assert_equal, assert_true


# 20000 bytes: comfortably under the 65535 default send window (so this test is
# about the WRITE loop and not about flow control, which has its own test) and
# comfortably over the 16384 default max frame size — so the body is split
# across at least two DATA frames and the framing itself is under test.
comptime BODY_LEN: Int = 20000


def _synthetic_body(n: Int) -> List[UInt8]:
    """Bytes whose value is a function of their own index, with a stride that
    is coprime to 256 — so a body reassembled with a DUPLICATED or DROPPED
    span fails a byte comparison instead of matching a repeat."""
    var b = List[UInt8]()
    var i = 0
    while i < n:
        b.append(UInt8((i * 31 + 7) & 0xFF))
        i = i + 1
    return b^


def _canned_h2_response_for_stream(stream_id: UInt32) raises -> List[UInt8]:
    """SETTINGS(empty) + HEADERS(:status 200) + DATA(empty, END_STREAM) on
    `stream_id` — enough for the client's drive loop to reach END_STREAM."""
    var bytes = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, bytes)
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        stream_id, block^, end_stream=False, end_headers=True, out=bytes
    )
    var empty = List[UInt8]()
    encode_data_frame(stream_id, empty^, True, bytes)
    return bytes^


def _concat_all_request_data_payloads(
    capture: List[UInt8],
) raises -> List[UInt8]:
    """Decode every frame the client emitted (after the 24-byte preface) and
    CONCATENATE the payloads of every DATA frame, in wire order.

    ⚠ Every frame is decoded, not just the DATA ones: a mis-consumed write
    prefix desynchronises the framing, and the only way that surfaces is a
    decode that fails or that produces a frame the client never sent. So the
    decode loop RAISES on a decode error rather than breaking out quietly —
    `break` here would turn a framing corruption into a short body and report
    it as the wrong defect."""
    var out = List[UInt8]()
    var off = H2_CLIENT_PREFACE_LEN
    var n = len(capture)
    var frames = 0
    while off < n:
        var tail = List[UInt8]()
        var i = off
        while i < n:
            tail.append(capture[i])
            i = i + 1
        var res = decode_frame(Span(tail), 16384)
        if not res.status == 0:  # FRAME_DECODE_OK == 0
            raise Error(
                "h2 frame decode FAILED at wire offset "
                + String(off)
                + " after "
                + String(frames)
                + " good frames (status="
                + String(Int(res.status))
                + ") — under a 7-byte-per-call write clamp this is a"
                " DESYNCHRONISED framing, not a short body"
            )
        frames = frames + 1
        if res.frame.header.kind == FRAME_DATA:
            var pi = 0
            while pi < len(res.frame.payload):
                out.append(res.frame.payload[pi])
                pi = pi + 1
        off = off + res.consumed
    return out^


def _run_h2_put_with_write_clamp(clamp: Int) raises -> List[UInt8]:
    """Drive a real `HttpClient.send_buffered` h2 PUT of BODY_LEN bytes over a
    ScriptedStream whose `try_write` accepts at most `clamp` bytes per call.
    Returns the captured client->server wire bytes."""
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var resp = _canned_h2_response_for_stream(UInt32(1))
    var stream = ScriptedStream.from_read_script_with_capture(resp^, capture)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    stream.set_max_write_per_call(clamp)
    var connector = ScriptedConnector.with_stream_tls(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)

    var url = Url.https(
        String("storage.googleapis.com"),
        UInt16(443),
        String("/upload/storage/v1/b/x/o"),
    )
    var headers = HeaderMap()
    headers.append(
        String("Content-Type"), String("application/octet-stream")
    )
    var req = build_request_with_body[BytesBody](
        HttpMethod.put(),
        url^,
        headers^,
        BytesBody.from_bytes(_synthetic_body(BODY_LEN)),
    )

    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var cr = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](
        req^, reactor
    )
    assert_equal(
        Int(cr.status), 200,
        "the scripted h2 server replied 200 — a non-200 here means the drive"
        " loop gave up before END_STREAM, which a short write must not cause",
    )
    return capture[].copy()


def _assert_wire_is_intact(capture: List[UInt8], clamp_label: String) raises:
    # (a) The connection preface must be on the wire, byte-exact and FIRST.
    #     It is not a frame, so a prefix mis-consume that ate into it would
    #     make every later decode nonsense.
    assert_true(
        len(capture) > H2_CLIENT_PREFACE_LEN,
        clamp_label + ": nothing but (at most) a preface reached the wire",
    )
    var pref = H2_CLIENT_PREFACE()
    var p = 0
    while p < H2_CLIENT_PREFACE_LEN:
        assert_equal(
            Int(capture[p]), Int(pref[p]),
            clamp_label + ": client preface byte " + String(p)
            + " is wrong — the write loop mis-consumed its own prefix",
        )
        p = p + 1

    # (b) Every frame decodes, and the DATA payloads reassemble to the body.
    var data = _concat_all_request_data_payloads(capture)
    var expected = _synthetic_body(BODY_LEN)
    assert_equal(
        len(data), BODY_LEN,
        clamp_label + ": the DATA frames must carry the FULL "
        + String(BODY_LEN)
        + "-byte body; got " + String(len(data)),
    )
    var k = 0
    while k < BODY_LEN:
        assert_equal(
            Int(data[k]), Int(expected[k]),
            clamp_label + ": body byte " + String(k)
            + " mismatched — a duplicated or dropped span, which is what a"
            " consume_out_bytes_prefix off by the accepted count produces",
        )
        k = k + 1


def test_h2_request_survives_a_seven_byte_write_clamp() raises:
    print("  test_h2_request_survives_a_seven_byte_write_clamp...")
    var capture = _run_h2_put_with_write_clamp(7)
    _assert_wire_is_intact(capture, String("clamp=7"))
    print("    OK —", len(capture), "wire bytes, framing intact at 7 B/write")


def test_h2_request_survives_a_one_byte_write_clamp() raises:
    """The extreme: ONE byte accepted per `try_write`. Every 9-byte frame
    header is then split across nine separate accepts, so a prefix-consume bug
    cannot hide behind a header that happened to land whole."""
    print("  test_h2_request_survives_a_one_byte_write_clamp...")
    var capture = _run_h2_put_with_write_clamp(1)
    _assert_wire_is_intact(capture, String("clamp=1"))
    print("    OK —", len(capture), "wire bytes, framing intact at 1 B/write")


def test_h2_unclamped_control_produces_the_same_wire_bytes() raises:
    """⚠ THE CONTROL, AND IT IS NOT OPTIONAL. Without it, "the clamped run
    produced a valid wire" is consistent with the clamp never having been
    applied at all. The clamped and unclamped runs must agree BYTE FOR BYTE:
    how many bytes the peer accepts per call is a transport-layer fact the
    framing layer must not be able to observe."""
    print("  test_h2_unclamped_control_produces_the_same_wire_bytes...")
    var unclamped = _run_h2_put_with_write_clamp(-1)
    var clamped = _run_h2_put_with_write_clamp(7)
    _assert_wire_is_intact(unclamped, String("unclamped"))
    assert_equal(
        len(clamped), len(unclamped),
        "a 7-byte write clamp changed the NUMBER of bytes the client emitted"
        " — the wire must not depend on the peer's accept size",
    )
    var i = 0
    while i < len(unclamped):
        assert_equal(
            Int(clamped[i]), Int(unclamped[i]),
            "wire byte " + String(i) + " differs between the clamped and"
            " unclamped runs",
        )
        i = i + 1
    print("    OK —", len(clamped), "bytes identical clamped vs unclamped")


def main() raises:
    test_h2_request_survives_a_seven_byte_write_clamp()
    test_h2_request_survives_a_one_byte_write_clamp()
    test_h2_unclamped_control_produces_the_same_wire_bytes()
    print("PASS test_h2_short_write_frame_integrity")
