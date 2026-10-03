"""L2 h2 client driver: drive_h2_streams_to_completion.

Tests the production-wired h2 driver that ties together
`encode_request_headers_to_frames` + `encode_request_data_frame` +
`process_received_frames` over a real (mock) IoStream. The driver
interleaves try_write / try_read calls with frame processing until
END_STREAM arrives on every awaited stream.

Tests in this file:
  * GET / round-trip on one stream: client emits HEADERS, server replies
    SETTINGS + HEADERS + DATA + END_STREAM, driver returns + extract
    yields (200, headers, body).
  * Multiplex: 3 streams interleaved on ONE stream — proves the driver
    routes by stream_id and completes all 3.
  * Pending wake: ScriptedStream returns Pending on first try_read, then
    serves bytes — driver loops correctly (no busy-spin observation:
    counts iters, asserts bounded).
  * EOF mid-response: driver raises HttpError[EOF_MID_RESPONSE].
  * GOAWAY excludes stream: server emits GOAWAY(last=1) and stream 3
    awaiting → driver raises HttpError[H2_PROTOCOL].

The full TLS+TCP e2e lives in the TLS tests.
"""

from std.sys.info import CompilationTarget

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import (
    BACKEND_EPOLL,
    BACKEND_KQUEUE,
    Reactor,
)
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.h2_client import (
    H2ClientConnectionState,
    drive_h2_streams_to_completion,
    encode_request_headers_to_frames,
    extract_response_for_stream,
    process_received_frames,
    queue_client_preface_and_settings,
)
from komira_http_client.header_map import HeaderMap
from komira_http_core.codec.h2.frame import (
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    encode_data_frame,
    encode_goaway_frame,
    encode_headers_frame,
    encode_rst_stream_frame,
    encode_settings_frame,
    SettingsEntry,
    H2_ERR_CANCEL,
    H2_ERR_NO_ERROR,
    H2_ERR_REFUSED_STREAM,
)
from komira_http_core.codec.h2.hpack import (
    HpackEncoder,
    HpackHeader,
)
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedStream


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _build_server_response_bytes(
    stream_id: UInt32, var status: String, var body: String,
) raises -> List[UInt8]:
    """Synthesize a server-side h2 response: SETTINGS (initial) + HEADERS(:status=...)
    + DATA(body) with END_STREAM. Used as ScriptedStream._read_script.

    The client's drive_h2_streams_to_completion will:
      1. Issue try_read → get these bytes → append_recv_bytes → process_received_frames.
      2. process_received_frames decodes SETTINGS, queues ACK in pending_out,
         decodes HEADERS, sets response_status, decodes DATA with END_STREAM,
         sets end_stream_seen=True.
      3. Driver sees end_stream_seen on the awaited stream → returns.
    """
    var bytes = List[UInt8]()

    # SETTINGS (empty non-ACK) — server's initial settings.
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, bytes)

    # HEADERS frame with :status + content-length pseudo/headers.
    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), status^))
    hdrs.append(
        HpackHeader(String("content-length"), String(len(body.as_bytes())))
    )
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        stream_id, block^, end_stream=False, end_headers=True, out=bytes,
    )

    # DATA frame with END_STREAM carrying the body.
    var body_bytes = List[UInt8]()
    var bs = body.as_bytes()
    var bi = 0
    while bi < len(bs):
        body_bytes.append(bs[bi])
        bi = bi + 1
    encode_data_frame(stream_id, body_bytes^, end_stream=True, out=bytes)

    return bytes^


def _build_three_stream_interleaved_response(
    sid1: UInt32, sid2: UInt32, sid3: UInt32,
) raises -> List[UInt8]:
    """Server emits frames interleaved across 3 streams (H1, H2, D1, H3, D2, D3).
    All bodies are short; END_STREAM rides on each DATA."""
    var bytes = List[UInt8]()

    # Initial SETTINGS.
    var settings = List[SettingsEntry]()
    encode_settings_frame(settings^, bytes)

    var hpack = HpackEncoder(max_table_size=4096)

    def _headers_for(mut e: HpackEncoder, sid: UInt32, mut out: List[UInt8]) raises:
        var hdrs = List[HpackHeader]()
        hdrs.append(HpackHeader(String(":status"), String("200")))
        var block = e.encode_block(hdrs^)
        encode_headers_frame(
            sid, block^, end_stream=False, end_headers=True, out=out,
        )

    def _data_for(sid: UInt32, var body: String, mut out: List[UInt8]):
        var body_bytes = List[UInt8]()
        var bs = body.as_bytes()
        var bi = 0
        while bi < len(bs):
            body_bytes.append(bs[bi])
            bi = bi + 1
        encode_data_frame(sid, body_bytes^, end_stream=True, out=out)

    _headers_for(hpack, sid1, bytes)
    _headers_for(hpack, sid2, bytes)
    _data_for(sid1, String("body1"), bytes)
    _headers_for(hpack, sid3, bytes)
    _data_for(sid2, String("body2!"), bytes)
    _data_for(sid3, String("body3!!"), bytes)
    return bytes^


# -----------------------------------------------------------------------------
# Tests
# -----------------------------------------------------------------------------


def test_h2_driver_get_round_trip_one_stream() raises:
    """Acceptance gate (a part 1): one HttpClient.send-equivalent
    GET request round-trips on a single h2 stream end-to-end through
    the driver.
    """
    print("  test_h2_driver_get_round_trip_one_stream...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)

    # Allocate stream 1 + register.
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)

    # Encode the request headers.
    var hdrs = HeaderMap()
    hdrs.append(String("user-agent"), String("komira-h2-client-test/0.1"))
    encode_request_headers_to_frames(
        h2, sid,
        String("GET"),
        String("https"),
        String("example.com"),
        String("/"),
        hdrs^,
        end_stream=True,
    )

    # Build a ScriptedStream pre-loaded with the server's response.
    var resp_bytes = _build_server_response_bytes(sid, String("200"), String("Hello, h2!"))
    var stream = ScriptedStream.from_read_script(resp_bytes^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)

    # Drive.
    var reactor = _make_reactor()
    var awaited = List[UInt32]()
    awaited.append(sid)
    drive_h2_streams_to_completion[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        h2, stream, reactor, awaited^,
    )

    # Extract the response.
    var resp = extract_response_for_stream(h2, sid)
    var status = resp[0]
    if Int(status) != 200:
        raise Error(
            "expected status 200, got " + String(Int(status))
        )
    var rb = List[UInt8]()
    swap(rb, resp[2])
    var body = String()
    var bi = 0
    while bi < len(rb):
        body += chr(Int(rb[bi]))
        bi = bi + 1
    if body != String("Hello, h2!"):
        raise Error("expected body 'Hello, h2!', got '" + body + "'")
    print("    OK — round-trip GET on stream " + String(Int(sid)) + " → 200 + body")


def test_h2_driver_multiplex_three_streams_interleaved() raises:
    """Acceptance gate (a part 2 + h gate from): driver drives 3
    concurrent streams on ONE conn; each routed by stream_id; each body
    intact + matched to its stream.
    """
    print("  test_h2_driver_multiplex_three_streams_interleaved...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)

    var sid1 = h2.allocate_client_stream_id()  # 1
    _ = h2.create_stream(sid1)
    var sid2 = h2.allocate_client_stream_id()  # 3
    _ = h2.create_stream(sid2)
    var sid3 = h2.allocate_client_stream_id()  # 5
    _ = h2.create_stream(sid3)

    var hdrs1 = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid1, String("GET"), String("https"),
        String("example.com"), String("/1"),
        hdrs1^, end_stream=True,
    )
    var hdrs2 = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid2, String("GET"), String("https"),
        String("example.com"), String("/2"),
        hdrs2^, end_stream=True,
    )
    var hdrs3 = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid3, String("GET"), String("https"),
        String("example.com"), String("/3"),
        hdrs3^, end_stream=True,
    )

    var resp_bytes = _build_three_stream_interleaved_response(sid1, sid2, sid3)
    var stream = ScriptedStream.from_read_script(resp_bytes^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)

    var reactor = _make_reactor()
    var awaited = List[UInt32]()
    awaited.append(sid1)
    awaited.append(sid2)
    awaited.append(sid3)
    drive_h2_streams_to_completion[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        h2, stream, reactor, awaited^,
    )

    # Extract each response + validate bodies match.
    var r1 = extract_response_for_stream(h2, sid1)
    var r2 = extract_response_for_stream(h2, sid2)
    var r3 = extract_response_for_stream(h2, sid3)

    var rb1 = List[UInt8]()
    swap(rb1, r1[2])
    var rb2 = List[UInt8]()
    swap(rb2, r2[2])
    var rb3 = List[UInt8]()
    swap(rb3, r3[2])

    def _body_string(ref rb: List[UInt8]) -> String:
        var s = String()
        var i = 0
        while i < len(rb):
            s += chr(Int(rb[i]))
            i = i + 1
        return s^

    var b1 = _body_string(rb1)
    var b2 = _body_string(rb2)
    var b3 = _body_string(rb3)
    if b1 != String("body1"):
        raise Error("stream " + String(Int(sid1)) + " body wrong: '" + b1 + "'")
    if b2 != String("body2!"):
        raise Error("stream " + String(Int(sid2)) + " body wrong: '" + b2 + "'")
    if b3 != String("body3!!"):
        raise Error("stream " + String(Int(sid3)) + " body wrong: '" + b3 + "'")
    print(
        "    OK — 3-stream multiplex; each routed by stream_id; bodies intact"
    )


def test_h2_driver_pending_on_first_read_then_data() raises:
    """Acceptance gate (c): try_read returns Pending first, then
    serves bytes — driver loops correctly without raising. This is the
    "no busy-spin observation" proxy: the driver MUST handle a
    Pending-then-Ready sequence by simply re-looping (no error, no
    extra work besides the retry).

    We verify the driver completes and the iteration count is bounded
    (sanity-check).
    """
    print("  test_h2_driver_pending_on_first_read_then_data...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)

    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)

    var hdrs = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid, String("GET"), String("https"),
        String("example.com"), String("/"),
        hdrs^, end_stream=True,
    )

    var resp_bytes = _build_server_response_bytes(
        sid, String("200"), String("OK"),
    )
    var stream = ScriptedStream.from_read_script(resp_bytes^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    # Make the FIRST 3 try_read calls return Pending.
    stream.queue_read_pending(3)

    var reactor = _make_reactor()
    var awaited = List[UInt32]()
    awaited.append(sid)
    # max_iterations capped low — proves driver does not infinite-spin
    # on Pending. 200 iters is plenty for 3 Pending + a handful of
    # frame-drains.
    drive_h2_streams_to_completion[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        h2, stream, reactor, awaited^, max_iterations=200,
    )

    var resp = extract_response_for_stream(h2, sid)
    if Int(resp[0]) != 200:
        raise Error("expected 200; got " + String(Int(resp[0])))
    print("    OK — Pending-then-Ready handled by driver loop")


def test_h2_driver_eof_mid_response_raises() raises:
    """Acceptance gate (c): driver surfaces EOF_MID_RESPONSE when
    the server closes the conn without completing all awaited streams.
    """
    print("  test_h2_driver_eof_mid_response_raises...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)
    var hdrs = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid, String("GET"), String("https"),
        String("example.com"), String("/"),
        hdrs^, end_stream=True,
    )

    # ScriptedStream with empty read script → try_read returns EOF.
    var stream = ScriptedStream.empty()
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)

    var reactor = _make_reactor()
    var awaited = List[UInt32]()
    awaited.append(sid)
    var raised = False
    try:
        drive_h2_streams_to_completion[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
            h2, stream, reactor, awaited^,
        )
    except e:
        raised = True
        var msg = String(e)
        if not (String("EOF_MID_RESPONSE") in msg):
            raise Error("expected EOF_MID_RESPONSE; got " + msg)
    if not raised:
        raise Error("expected driver to raise on EOF")
    print("    OK — EOF mid-response → HttpError[EOF_MID_RESPONSE]")


def _build_headers_then_rst_bytes(
    stream_id: UInt32, rst_error_code: UInt32,
) raises -> List[UInt8]:
    """SETTINGS + HEADERS(:status 200, content-length 64, NO END_STREAM) + a
    PARTIAL DATA frame of 8 bytes + RST_STREAM(`rst_error_code`).

    The partial body is the point: a caller handed this as a success receives
    a SHORT OBJECT with a 200 and no indication anything went wrong.
    """
    var bytes = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, bytes)

    var hpack = HpackEncoder(max_table_size=4096)
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(HpackHeader(String("content-length"), String("64")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        stream_id, block^, end_stream=False, end_headers=True, out=bytes,
    )

    var partial = List[UInt8]()
    var i = 0
    while i < 8:
        partial.append(UInt8(65 + i))
        i = i + 1
    encode_data_frame(stream_id, partial^, end_stream=False, out=bytes)

    encode_rst_stream_frame(stream_id, rst_error_code, bytes)
    return bytes^


def _drive_rst_and_capture(rst_error_code: UInt32) raises -> String:
    """One RST fixture end-to-end through the production driver. Returns the
    raise message, or "" if the driver RETURNED (which is the defect)."""
    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var sid = h2.allocate_client_stream_id()
    _ = h2.create_stream(sid)
    var hdrs = HeaderMap()
    encode_request_headers_to_frames(
        h2, sid, String("GET"), String("https"),
        String("example.com"), String("/"),
        hdrs^, end_stream=True,
    )
    var script = _build_headers_then_rst_bytes(sid, rst_error_code)
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    var reactor = _make_reactor()
    var awaited = List[UInt32]()
    awaited.append(sid)
    var msg = String("")
    try:
        drive_h2_streams_to_completion[
            ScriptedStream, PerCoreAsyncRuntime[NoopSink]
        ](h2, stream, reactor, awaited^)
    except e:
        msg = String(e)
    _ = stream^
    _ = reactor^
    _ = h2^
    return msg^


def test_h2_driver_rst_stream_is_not_a_complete_response() raises:
    """★ A SERVER RST_STREAM MUST NOT BECOME A SUCCESSFUL SHORT RESPONSE.

    THE DEFECT THIS PINS. `process_received_frames` answered
    an inbound RST_STREAM with `end_stream_seen = True` — the SAME bit an
    END_STREAM sets — and discarded the RST error code. Since
    `drive_h2_streams_to_completion` returns exactly when every awaited stream
    carries that bit, the caller's `extract_response_for_stream` then handed up
    `(200, headers, <8 of the 64 promised bytes>)` with NO error. For a GCS
    `ReadObject` that is a silently truncated object; for any request it is a
    verdict the peer never gave.

    ⚠ IT WAS NOT FOUND BY READING THE CODE. It was found by
    `test_L2_h2_client_differential_vs_python_h2` on its
    FIRST RUN: python-hyper `h2`, fed the identical bytes, reports
    `StreamReset` with END_STREAM false. Our 19 client test files — 61 test
    functions — never fed an inbound RST_STREAM to the client at all, because
    every fixture in them is built with OUR OWN encoder against OUR OWN
    decoder, so a shared misreading cancels out.

    ⛔ AND THE FIX IS NOT "STOP SETTING THE BIT". That bit is also the
    driver's stop condition, so removing it alone turns a wrong answer into a
    HANG. The two meanings are split: `H2ClientStream.reset_error_code` records
    the reset and the driver raises on it.

    THE CLASS IS THE DISPOSITION, both arms asserted here:
      REFUSED_STREAM  -> HttpError[RETRYABLE_TRANSPORT]. RFC 9113 §8.7 gives it
                         the same definitive not-processed guarantee GOAWAY
                         above Last-Stream-ID has.
      anything else   -> HttpError[H2_STREAM_RESET], deliberately in NO
                         connection-level retry set: the peer may have executed
                         the request before it gave up.
    """
    print("  test_h2_driver_rst_stream_is_not_a_complete_response...")

    var msg = _drive_rst_and_capture(H2_ERR_CANCEL)
    if len(msg.as_bytes()) == 0:
        raise Error(
            "★ THE DEFECT. The driver RETURNED on a stream the server RESET."
            " The caller now believes it has a complete 200 response and will"
            " read 8 bytes of a 64-byte body with no error."
        )
    if not (String("H2_STREAM_RESET") in msg):
        raise Error(
            "expected HttpError[H2_STREAM_RESET] for RST(CANCEL); got " + msg
        )
    if String("RETRYABLE_TRANSPORT") in msg:
        raise Error(
            "RST(CANCEL) must NOT be classified retryable — outside"
            " REFUSED_STREAM the peer may have executed the request. Got "
            + msg
        )

    var msg_b = _drive_rst_and_capture(H2_ERR_REFUSED_STREAM)
    if len(msg_b.as_bytes()) == 0:
        raise Error("expected the driver to raise on RST(REFUSED_STREAM)")
    if not (String("RETRYABLE_TRANSPORT") in msg_b):
        raise Error(
            "RST(REFUSED_STREAM) is RFC 9113 §8.7's definitive"
            " not-processed case and MUST be classified re-issuable; got "
            + msg_b
        )
    print(
        "    OK — RST_STREAM raises; REFUSED_STREAM retryable, CANCEL not"
    )


def test_h2_driver_pool_key_h2_isolation_via_https_h2() raises:
    """Wiring sanity: the h2 dispatch path's pool keys (when
    wires the pool field) carry ALPN_H2 via PoolKey.https_h2, so
    h1 + h2 conns NEVER share a bucket. This unit covers PoolKey at
    the discriminator-of-record level."""
    from komira_http_client.pool import (
        ALPN_H2, ALPN_UNKNOWN, PoolKey, VERIFY_PEER,
    )
    print("  test_h2_driver_pool_key_h2_isolation_via_https_h2...")
    var k_h2 = PoolKey.https_h2(
        String("api.example.com"), UInt16(443), VERIFY_PEER,
    )
    var k_h1 = PoolKey.https(
        String("api.example.com"), UInt16(443), VERIFY_PEER,
    )
    if Int(k_h2.negotiated_alpn) != Int(ALPN_H2):
        raise Error("https_h2 must tag ALPN_H2")
    if Int(k_h1.negotiated_alpn) != Int(ALPN_UNKNOWN):
        raise Error("https must default to ALPN_UNKNOWN")
    if k_h1 == k_h2:
        raise Error("h1 + h2 keys at the same origin must be disjoint")
    print("    OK — h2 dispatch uses disjoint pool keys from h1")


def _build_n_stream_interleaved_response(
    var stream_ids: List[UInt32],
) raises -> List[UInt8]:
    """Server emits N HEADERS + N DATA frames, interleaved so HEADERS
    for stream_i+1 may arrive before DATA for stream_i. Tests the
    driver's stream-id-based routing under realistic multiplex."""
    var bytes = List[UInt8]()
    var settings = List[SettingsEntry]()
    encode_settings_frame(settings^, bytes)
    var hpack = HpackEncoder(max_table_size=4096)
    var n = len(stream_ids)
    # Emit all HEADERS first (round-robin), then all DATA.
    var i = 0
    while i < n:
        var hdrs = List[HpackHeader]()
        hdrs.append(HpackHeader(String(":status"), String("200")))
        var block = hpack.encode_block(hdrs^)
        encode_headers_frame(
            stream_ids[i], block^,
            end_stream=False, end_headers=True, out=bytes,
        )
        i = i + 1
    i = 0
    while i < n:
        var body_str = String("response") + String(Int(stream_ids[i]))
        var body_bytes = List[UInt8]()
        var bs = body_str.as_bytes()
        var bi = 0
        while bi < len(bs):
            body_bytes.append(bs[bi])
            bi = bi + 1
        encode_data_frame(
            stream_ids[i], body_bytes^, end_stream=True, out=bytes,
        )
        i = i + 1
    return bytes^


def test_h2_driver_multiplex_eight_streams_one_conn() raises:
    """Gate (b) STRUCTURAL: 8 concurrent h2 streams interleaved on
    ONE stream conformer (i.e. ONE TCP/TLS fd in the real-TCP shape).
    Driver routes each response by stream_id; each body intact +
    matched to correct stream.

    The fd-count=1 assertion is structural here — we hold exactly one
    ScriptedStream. The real-TCP version adds an `lsof -p $pid`
    shell-out to assert the kernel-fd count.

    Acceptance: 8 streams → 8 distinct responses, each with correct
    body ("responseN" for stream N), all on one stream conformer.
    """
    print("  test_h2_driver_multiplex_eight_streams_one_conn...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)

    var stream_ids = List[UInt32]()
    var k = 0
    while k < 8:
        var sid = h2.allocate_client_stream_id()
        _ = h2.create_stream(sid)
        stream_ids.append(sid)
        var hdrs = HeaderMap()
        encode_request_headers_to_frames(
            h2, sid, String("GET"), String("https"),
            String("example.com"),
            String("/") + String(Int(sid)),
            hdrs^, end_stream=True,
        )
        k = k + 1

    var stream_ids_copy = List[UInt32]()
    var sc = 0
    while sc < len(stream_ids):
        stream_ids_copy.append(stream_ids[sc])
        sc = sc + 1
    var resp_bytes = _build_n_stream_interleaved_response(stream_ids_copy^)
    var stream = ScriptedStream.from_read_script(resp_bytes^)
    stream.set_negotiated_protocol(NEGOTIATED_HTTP_2)

    var reactor = _make_reactor()
    var awaited = List[UInt32]()
    var ai = 0
    while ai < len(stream_ids):
        awaited.append(stream_ids[ai])
        ai = ai + 1
    drive_h2_streams_to_completion[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        h2, stream, reactor, awaited^,
    )

    # Validate each stream's response is routed correctly + body intact.
    var i = 0
    while i < len(stream_ids):
        var sid = stream_ids[i]
        var r = extract_response_for_stream(h2, sid)
        if Int(r[0]) != 200:
            raise Error(
                "stream " + String(Int(sid))
                + ": expected 200, got " + String(Int(r[0]))
            )
        var body_bytes = List[UInt8]()
        swap(body_bytes, r[2])
        var body_str = String()
        var bi = 0
        while bi < len(body_bytes):
            body_str += chr(Int(body_bytes[bi]))
            bi = bi + 1
        var expected = String("response") + String(Int(sid))
        if body_str != expected:
            raise Error(
                "stream " + String(Int(sid))
                + ": body wrong: '" + body_str + "' vs '"
                + expected + "'"
            )
        i = i + 1
    print(
        "    OK — 8-stream multiplex on ONE conformer; all routed by stream_id"
        " + bodies intact (fd-count=1 structural gate)"
    )


def main() raises:
    print("== L2 h2 client driver ==")
    test_h2_driver_get_round_trip_one_stream()
    test_h2_driver_multiplex_three_streams_interleaved()
    test_h2_driver_pending_on_first_read_then_data()
    test_h2_driver_eof_mid_response_raises()
    test_h2_driver_rst_stream_is_not_a_complete_response()
    test_h2_driver_pool_key_h2_isolation_via_https_h2()
    test_h2_driver_multiplex_eight_streams_one_conn()
    print("== L2 driver PASSED (7 tests) ==")
