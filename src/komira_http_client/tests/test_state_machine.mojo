# =============================================================================
# src/komira_http_client/tests/test_state_machine.mojo
# =============================================================================
# Tier-2 ScriptedStream-driven state-machine tests
#
# Each test pre-loads a ScriptedStream with the bytes a "server" would
# emit, optionally queues Pending(READ) frames to exercise the park-and-
# wake path, then runs OutboundDriver.run over the scripted stream and
# asserts on the resulting ClientResponse.

from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from std.sys.info import CompilationTarget

from komira_http_client.body import EmptyBody
from komira_http_client.header_map import HeaderMap
from komira_http_client.request_writer import (
    method_get,
    serialize_request_head,
)
from komira_http_client.response_body import (
    BufferedResponseBody,
    RecvRingBody,
    collect_body,
)
from komira_http_client.state_machine import (
    ClientResponse,
    OutboundDriver,
    OUTBOUND_STATE_DONE,
)
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedStream



def _make_scratch() -> List[UInt8]:
    """
    OutboundDriver.{run, run_with_body, run_buffered} now take a
    `scratch: Span[UInt8, _]` arg. This helper allocates a 4 KB local
    List[UInt8] buffer the test can Span over."""
    var s = List[UInt8]()
    var i = 0
    while i < 4096:
        s.append(UInt8(0))
        i = i + 1
    return s^


def _make_reactor() raises -> Reactor[NoopSink]:
    """Build a per-test reactor with the right backend for the OS.
    ScriptedStream ignores the reactor (it's a mock), so any backend
    works — but the Reactor must be CONSTRUCTIBLE, which means picking
    BACKEND_EPOLL on Linux and BACKEND_KQUEUE on macOS."""
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _bytes_to_str(buf: List[UInt8]) -> String:
    var out = String()
    var i = 0
    while i < buf.__len__():
        out = out + chr(Int(buf[i]))
        i = i + 1
    return out^


def _take_body_bytes(
    mut resp: ClientResponse[RecvRingBody[ScriptedStream]],
) raises -> List[UInt8]:
    """Drain the RecvRingBody via collect_body. Returns
    the full body bytes (empty for HEAD / 204 / 304 / empty bodies).
    """
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    return collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        resp.body, reactor, tok,
    )


def _drain_body_detail(
    mut resp: ClientResponse[RecvRingBody[ScriptedStream]],
    mut out: List[UInt8],
) raises -> String:
    """Drive `resp.body` to End, concatenating Data frames into `out`, and
    return the terminal Error frame's DETAIL ("" on a clean End).

    ⚠ WHY THIS EXISTS ALONGSIDE `_take_body_bytes`. `collect_body` RAISES on
    an Error frame, so it can hand back the bytes OR the failure, never both
    — and "were the bytes that did arrive still delivered before the error"
    is exactly the question a truncation test has to answer. This helper
    keeps both halves as values."""
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var iter = 0
    while True:
        iter = iter + 1
        if iter > 200000:
            return String("ITER_CAP")
        var f = resp.body.poll_frame[PerCoreAsyncRuntime[NoopSink]](
            reactor, tok,
        )
        if f.is_end():
            return String("")
        if f.is_error():
            return f.error_detail()
        if f.is_data():
            var chunk = f.take_data_chunk()
            var k = 0
            while k < chunk.__len__():
                out.append(chunk[k])
                k = k + 1
    return String("")


def _make_get_request_bytes() raises -> List[UInt8]:
    var url = Url.parse(String("http://example.com/health"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    return out^


def test_simple_200_round_trip() raises:
    """Happy path: writer emits GET; scripted server replies 200 OK +
    "hello"; driver parses + returns ClientResponse."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    # ScriptedStream ignores the reactor, so any reactor works.
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(resp.reason, String("OK"))
    var body_bytes = _take_body_bytes(resp)
    assert_equal(body_bytes.__len__(), 5)
    assert_equal(_bytes_to_str(body_bytes), String("hello"))
    assert_equal(driver.state(), OUTBOUND_STATE_DONE)


def test_empty_body_204() raises:
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n"))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 204)
    var body_bytes = _take_body_bytes(resp)
    assert_equal(body_bytes.__len__(), 0)


def test_chunked_response() raises:
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\nhello\r\n"
        "6\r\n world\r\n"
        "0\r\n\r\n"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)
    var body_bytes = _take_body_bytes(resp)
    assert_equal(body_bytes.__len__(), 11)
    assert_equal(_bytes_to_str(body_bytes), String("hello world"))


def test_partial_read_loops() raises:
    """ScriptedStream clamps bytes-per-Ready; driver must loop to
    accumulate the full head + body."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\nhello, world!"))
    var stream = ScriptedStream.from_read_script(resp_script^)
    # Force partial reads at 7-byte clamp.
    stream.set_max_read_per_call(7)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)
    var body_bytes = _take_body_bytes(resp)
    assert_equal(_bytes_to_str(body_bytes), String("hello, world!"))


def test_pending_then_data() raises:
    """ScriptedStream returns Pending for the first N reads, then
    serves bytes. The driver loops on Pending (re-tries next iteration)
    until data arrives."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"))
    var stream = ScriptedStream.from_read_script(resp_script^)
    stream.queue_read_pending(3)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)
    var body_bytes = _take_body_bytes(resp)
    assert_equal(_bytes_to_str(body_bytes), String("OK"))


def test_eof_mid_head_is_retryable_transport() raises:
    """Peer closes before any response byte — should surface
    RETRYABLE_TRANSPORT.

    BUT: ScriptedStream returns EOF immediately on empty script, AND
    the writer is also a no-op on empty scripts, so the driver should
    see EOF immediately. The driver raises with the appropriate kind.
    """
    var req_bytes = _make_get_request_bytes()
    var empty_script = List[UInt8]()
    var stream = ScriptedStream.from_read_script(empty_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var caught = False
    try:
        var _r = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
            stream^, reactor, Span[UInt8](scratch_local),
        )
    except _e:
        caught = True
    assert_true(caught)


def test_eof_mid_body_with_cl_is_error() raises:
    """Response says CL=10 but only 4 bytes + EOF arrive — EOF_MID_RESPONSE.

    reshape: the error fires when the BODY is polled (the head
    parses fine; the body comes up short). Drain via collect_body
    which surfaces the BodyFrame.error as a raise."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nhalf"))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var caught = False
    try:
        var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
            stream^, reactor, Span[UInt8](scratch_local),
        )
        var _bytes = _take_body_bytes(resp)
    except _e:
        caught = True
    assert_true(caught)


def test_hard_io_error_surfaces() raises:
    """The I/O error fires during HEAD read (the script is incomplete;
    armed error fires on the next try_read trying to find the CRLFCRLF
    terminator). Same shape as the original test."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String("HTTP/1.1 200 OK\r\n"))
    var stream = ScriptedStream.from_read_script(resp_script^)
    # Arm an error to fire on the NEXT read (after some bytes are
    # served). The first read returns the bytes; the second triggers
    # the error.
    stream.arm_error(Int64(104))  # ECONNRESET on macOS
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var caught = False
    try:
        var _r = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
            stream^, reactor, Span[UInt8](scratch_local),
        )
    except _e:
        caught = True
    assert_true(caught)


def test_write_then_read_cycle_smoke() raises:
    """Verify the driver completes a full write-then-read cycle without
    error. (The ScriptedStream is owned by the
    returned RecvRingBody inside the response — to inspect the write
    capture after run(), use the test_client_writes_correct_request_bytes
    test in test_http_client_send.mojo, which uses ScriptedConnector's
    captured-stream pattern.)"""
    var req_bytes = _make_get_request_bytes()
    var n_req = req_bytes.__len__()
    _ = n_req
    var resp_script = _b(String("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var _r = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    # Verify state machine reached DONE.
    assert_equal(driver.state(), OUTBOUND_STATE_DONE)


# =============================================================================
# ⛔ THE TRUNCATION TWINS — the error the CALLER sees is the one asserted.
# =============================================================================
#
# `test_eof_mid_head_is_retryable_transport` and
# `test_eof_mid_body_with_cl_is_error` above both end in
# `except _e: caught = True`. That assertion cannot tell the bug from the
# fix: it stays GREEN if the driver raises a 250-second TIMEOUT instead of a
# fast, named failure — and a multi-minute stall then a 504 IS the production
# symptom. These twins assert the
# DETAIL. They are additions, not replacements: the originals still pin that
# the driver raises at all.
#
# The chunked leg is the one that had no twin whatsoever:
# `test_chunked_response` above is the chunked HAPPY path, ~80 lines above
# the Content-Length truncation test that is its own template.


def test_eof_mid_chunked_body_raises_the_chunked_truncation_error() raises:
    """FULL-STACK TWIN of the observed failure: head parses, `Transfer-Encoding:
    chunked` selects the chunked body, and the wire dies mid-chunk. The
    error that escapes `OutboundDriver.run` + `collect_body` must NAME
    chunked truncation.

    ⛔ Asserting `caught == True` here would be worthless — the production
    defect ALSO raised, ~250s later, after the request wall fired. The point
    of the assertion is that the failure is the fast, specific one."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\nhello\r\n"
        "6\r\n worl"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var msg = String("<no raise>")
    try:
        var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
            stream^, reactor, Span[UInt8](scratch_local),
        )
        var _bytes = _take_body_bytes(resp)
    except e:
        msg = String(e)
    assert_true(
        msg.find(String("chunked body unterminated")) >= 0,
        String("expected the chunked truncation error, got: ") + msg,
    )
    assert_true(
        msg.find(String("TIMEOUT")) < 0,
        String("a truncated chunked body must NOT surface as a timeout: ")
        + msg,
    )


def test_eof_mid_chunked_body_delivers_the_bytes_that_arrived() raises:
    """Same wire, driven frame-by-frame: the 5 bytes of the chunk that DID
    complete must reach the caller before the error. A refactor that dropped
    them would be invisible to the raise-only twin above."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\n"
        "Transfer-Encoding: chunked\r\n"
        "\r\n"
        "5\r\nhello\r\n"
        "6\r\n worl"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)
    var got = List[UInt8]()
    var detail = _drain_body_detail(resp, got)
    assert_true(
        detail.find(String("chunked body unterminated")) >= 0,
        String("expected chunked truncation, got detail=<") + detail
        + String(">"),
    )
    assert_equal(_bytes_to_str(got), String("hello worl"))


def test_eof_mid_cl_body_detail_names_cl_and_got_and_is_not_chunked() raises:
    """THE CONTRAST CASE, and the reason the chunked arm went untested for so
    long. `Content-Length: 123` with 26 body bytes then EOF must report the
    SHORT-BODY form, naming both numbers, and must be textually
    DISTINGUISHABLE from the chunked form.

    ⚠ A premature-EOF test that asserts `detail.find("EOF_MID_RESPONSE") >= 0`
    on a Content-Length body cannot tell anyone which arm ran — both arms of
    `_finalize_on_eof` emit that prefix — which is how an unexercised
    chunked-truncation line ships.
    (Go pins the same contrast in TestResponseContentLengthShortBody.)"""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\n"
        "Content-Length: 123\r\n"
        "\r\n"
        "abcdefghijklmnopqrstuvwxyz"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)
    var got = List[UInt8]()
    var detail = _drain_body_detail(resp, got)
    assert_true(
        detail.find(String("EOF_MID_RESPONSE")) >= 0,
        String("expected EOF_MID_RESPONSE, got detail=<") + detail
        + String(">"),
    )
    assert_true(
        detail.find(String("CL=123")) >= 0,
        String("short-body detail must name the declared length: ") + detail,
    )
    assert_true(
        detail.find(String("got=26")) >= 0,
        String("short-body detail must name what arrived: ") + detail,
    )
    assert_true(
        detail.find(String("chunked body unterminated")) < 0,
        String("a CL short body must NOT read as chunked truncation: ")
        + detail,
    )
    # The 26 bytes that did arrive are still the caller's.
    assert_equal(_bytes_to_str(got), String("abcdefghijklmnopqrstuvwxyz"))


def main() raises:
    test_simple_200_round_trip()
    test_empty_body_204()
    test_chunked_response()
    test_partial_read_loops()
    test_pending_then_data()
    test_eof_mid_head_is_retryable_transport()
    test_eof_mid_body_with_cl_is_error()
    test_hard_io_error_surfaces()
    test_write_then_read_cycle_smoke()
    test_eof_mid_chunked_body_raises_the_chunked_truncation_error()
    test_eof_mid_chunked_body_delivers_the_bytes_that_arrived()
    test_eof_mid_cl_body_detail_names_cl_and_got_and_is_not_chunked()
    print("OK: test_state_machine")
