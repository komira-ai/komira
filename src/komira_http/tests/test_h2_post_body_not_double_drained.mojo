"""Regression: h2 POST-with-body must NOT send an EMPTY body (the GCS
web-content deploy 503 root cause).

THE BUG: `build_request_with_body` pre-drains the body conformer's cursor to EOF
to serialize the h1 `request_bytes`, then stores the (now-exhausted) conformer in
the ClientRequest. The h1 transport reads the body from `request_bytes` (correct),
but the h2 transport rebuilds its own frames FROM the conformer and RE-drains it —
which yielded 0 bytes, so the request DATA frame was omitted and the server got a
body-LESS POST. The ONLY affected caller was `GeneratedStorageApi` (the sole
`alpn_h2=True` + `build_request_with_body` + `send_buffered` user); every other
POST-with-body caller dials the DEFAULT h1 connector, so the bug hid for months.

THE GUARD: drive the REAL `HttpClient.send_buffered` h2 path over a ScriptedConnector
(negotiated h2, canned 200 response, shared write-capture), then decode the CAPTURED
request bytes and assert a DATA frame carrying the FULL body bytes was emitted.
Pre-fix: no DATA frame (empty body) -> FAIL. Post-fix: DATA frame == body -> PASS.

Mojo 1.0.0b2 (def-only).
"""

from std.memory import ArcPointer

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime

from komira_http.client.body import BytesBody
from komira_http.client.client import HttpClient, build_request_with_body
from komira_http.client.header_map import HeaderMap
from komira_http.client.url import Url
from komira_http.codec.types import HttpMethod
from komira_http.codec.h2.connection_preface import H2_CLIENT_PREFACE_LEN
from komira_http.codec.h2.frame import (
    FLAG_END_STREAM,
    FRAME_DATA,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream

from std.testing import assert_equal, assert_true


comptime BODY: String = '{"cacheControl":"public, max-age=31536000, immutable"}'


def _canned_h2_response_for_stream(stream_id: UInt32) raises -> List[UInt8]:
    """SETTINGS(empty) + HEADERS(:status 200) + DATA(empty, END_STREAM) on
    `stream_id` — enough for the client's drive loop to reach END_STREAM + return."""
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


def _find_request_data_frame(capture: List[UInt8]) raises -> List[UInt8]:
    """Decode the captured client->server bytes (after the 24-byte preface) and
    return the payload of the FIRST DATA frame with END_STREAM. Empty list if none."""
    var out = List[UInt8]()
    # Skip the 24-byte client connection preface (not a frame).
    var off = H2_CLIENT_PREFACE_LEN
    var n = len(capture)
    while off < n:
        var tail = List[UInt8]()
        var i = off
        while i < n:
            tail.append(capture[i])
            i = i + 1
        var res = decode_frame(Span(tail), 16384)
        if not res.status == 0:  # FRAME_DECODE_OK == 0
            break
        if res.frame.header.kind == FRAME_DATA:
            if (res.frame.header.flags & FLAG_END_STREAM) != UInt8(0):
                var pi = 0
                while pi < len(res.frame.payload):
                    out.append(res.frame.payload[pi])
                    pi = pi + 1
                return out^
        off = off + res.consumed
    return out^


def test_h2_post_body_reaches_the_wire() raises:
    print("  test_h2_post_body_reaches_the_wire...")

    # Shared write-capture so the emitted request bytes survive the stream drop.
    var capture = ArcPointer[List[UInt8]](List[UInt8]())
    var resp = _canned_h2_response_for_stream(UInt32(1))
    var stream = ScriptedStream.from_read_script_with_capture(resp^, capture)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    var connector = ScriptedConnector.with_stream_tls(stream^)
    var client = HttpClient[ScriptedConnector].with_defaults(connector^)

    # Build the POST exactly as GeneratedStorageApi.rewrite_object does.
    var url = Url.https(String("storage.googleapis.com"), UInt16(443), String("/rewriteTo"))
    var headers = HeaderMap()
    headers.append(String("Content-Type"), String("application/json"))
    var req = build_request_with_body[BytesBody](
        HttpMethod.post(), url^, headers^, BytesBody.from_str(BODY)
    )

    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var cr = client.send_buffered[BlockingRuntime[NoopSink], BytesBody](req^, reactor)
    assert_equal(Int(cr.status), 200, "scripted server replied 200")

    var data = _find_request_data_frame(capture[])
    var expected = BODY.as_bytes()
    # The REGRESSION assertion: a DATA frame carrying the FULL body must exist.
    assert_equal(
        len(data), len(expected),
        "h2 POST must emit a DATA frame with the FULL body (pre-fix: 0 bytes =="
        " body-less POST -> the GCS rewrite/insert 503)",
    )
    var k = 0
    while k < len(expected):
        assert_equal(Int(data[k]), Int(expected[k]), "body byte mismatch")
        k = k + 1
    assert_true(len(data) > 0, "body must be non-empty on the wire")
    print("    OK — DATA frame carried", len(data), "body bytes")


def main() raises:
    test_h2_post_body_reaches_the_wire()
    print("PASS test_h2_post_body_not_double_drained")
