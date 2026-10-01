# =============================================================================
# src/komira_http/tests/test_nonblocking_send_head.mojo
# =============================================================================
# tests for the non-blocking send+head
# stepper that enables concurrent (overlapped) dial+head for the K-stream
# prefetch round-robin. Drives `OutboundDriver.step_send_head_nonblocking`
# over a ScriptedStream and asserts:
#   1. While the response head is not yet on the wire (queued Pending reads),
#      the stepper returns OUTBOUND_STEP_NOT_READY (does NOT spin / block).
#   2. Once the head bytes arrive, it returns OUTBOUND_STEP_HEAD_DONE.
#   3. `finish_into_response` builds the correct ClientResponse and the body
#      drains via poll_frame (the deferred-body contract).
#   4. A hard IO error surfaces as OUTBOUND_STEP_ERROR with a non-empty
#      `last_error_detail()` — and does NOT raise (the round-robin contract).

from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from std.sys.info import CompilationTarget

from komira_http.client.body import EmptyBody
from komira_http.client.header_map import HeaderMap
from komira_http.client.request_writer import (
    method_get,
    serialize_request_head,
)
from komira_http.client.response_body import (
    RecvRingBody,
    collect_body,
)
from komira_http.client.state_machine import (
    ClientResponse,
    OutboundDriver,
    OUTBOUND_STATE_DONE,
    OUTBOUND_STEP_ERROR,
    OUTBOUND_STEP_HEAD_DONE,
    OUTBOUND_STEP_NOT_READY,
)
from komira_http.client.url import Url
from komira_http.transport.scripted import ScriptedStream



def _make_scratch() -> List[UInt8]:
    var s = List[UInt8]()
    var i = 0
    while i < 4096:
        s.append(UInt8(0))
        i = i + 1
    return s^


def _make_reactor() raises -> Reactor[NoopSink]:
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


def _make_get_request_bytes() raises -> List[UInt8]:
    var url = Url.parse(String("http://example.com/health"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    return out^


def _drain_body(
    mut resp: ClientResponse[RecvRingBody[ScriptedStream]],
) raises -> List[UInt8]:
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    return collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
        resp.body, reactor, tok,
    )


def test_not_ready_then_head_done() raises:
    """While the head is not yet on the wire (3 queued Pending reads),
    step_send_head_nonblocking returns NOT_READY; once bytes arrive it
    returns HEAD_DONE and finish_into_response yields the parsed response
    with the body deferred to poll_frame."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(
        String("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello")
    )
    var stream = ScriptedStream.from_read_script(resp_script^)
    stream.queue_read_pending(3)
    var driver = OutboundDriver.new(req_bytes^)
    driver.begin_send_head_nonblocking()
    var reactor = _make_reactor()
    var scratch = _make_scratch()

    # Step until HEAD_DONE; assert we observe at least one NOT_READY (the
    # head was deferred, not spun on). Bounded loop guards a logic bug.
    var saw_not_ready = False
    var step: UInt8 = OUTBOUND_STEP_NOT_READY
    var iters = 0
    while iters < 1000:
        iters = iters + 1
        step = driver.step_send_head_nonblocking[
            ScriptedStream, PerCoreAsyncRuntime[NoopSink]
        ](stream, reactor, Span[UInt8](scratch))
        if step == OUTBOUND_STEP_NOT_READY:
            saw_not_ready = True
            continue
        break

    assert_true(saw_not_ready, msg="expected at least one NOT_READY step")
    assert_equal(Int(step), Int(OUTBOUND_STEP_HEAD_DONE))
    assert_equal(driver.state(), OUTBOUND_STATE_DONE)

    var resp = driver.finish_into_response[ScriptedStream](stream^)
    assert_equal(Int(resp.status), 200)
    assert_equal(resp.reason, String("OK"))
    var body = _drain_body(resp)
    assert_equal(body.__len__(), 5)
    assert_equal(_bytes_to_str(body), String("hello"))


def test_immediate_head_done_no_pending() raises:
    """When the full head + body are already on the wire, the stepper
    reaches HEAD_DONE without needing a NOT_READY (single-pass case)."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(
        String("HTTP/1.1 206 Partial Content\r\nContent-Length: 2\r\n\r\nOK")
    )
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    driver.begin_send_head_nonblocking()
    var reactor = _make_reactor()
    var scratch = _make_scratch()

    var step: UInt8 = OUTBOUND_STEP_NOT_READY
    var iters = 0
    while iters < 1000:
        iters = iters + 1
        step = driver.step_send_head_nonblocking[
            ScriptedStream, PerCoreAsyncRuntime[NoopSink]
        ](stream, reactor, Span[UInt8](scratch))
        if step != OUTBOUND_STEP_NOT_READY:
            break

    assert_equal(Int(step), Int(OUTBOUND_STEP_HEAD_DONE))
    var resp = driver.finish_into_response[ScriptedStream](stream^)
    assert_equal(Int(resp.status), 206)
    var body = _drain_body(resp)
    assert_equal(_bytes_to_str(body), String("OK"))


def test_eof_before_head_is_step_error_not_raise() raises:
    """An empty script (peer closed before any response byte) surfaces as
    OUTBOUND_STEP_ERROR with a non-empty detail — and does NOT raise, so a
    fault on one stream never unwinds the round-robin caller's other
    in-flight streams."""
    var req_bytes = _make_get_request_bytes()
    var empty_script = List[UInt8]()
    var stream = ScriptedStream.from_read_script(empty_script^)
    var driver = OutboundDriver.new(req_bytes^)
    driver.begin_send_head_nonblocking()
    var reactor = _make_reactor()
    var scratch = _make_scratch()

    var step: UInt8 = OUTBOUND_STEP_NOT_READY
    var iters = 0
    while iters < 1000:
        iters = iters + 1
        step = driver.step_send_head_nonblocking[
            ScriptedStream, PerCoreAsyncRuntime[NoopSink]
        ](stream, reactor, Span[UInt8](scratch))
        if step != OUTBOUND_STEP_NOT_READY:
            break

    assert_equal(Int(step), Int(OUTBOUND_STEP_ERROR))
    assert_true(
        driver.last_error_detail().byte_length() > 0,
        msg="OUTBOUND_STEP_ERROR must carry a non-empty error detail",
    )
    # Drop the stream explicitly (driver did not consume it on error).
    _ = stream^


def main() raises:
    test_not_ready_then_head_done()
    test_immediate_head_done_no_pending()
    test_eof_before_head_is_step_error_not_raise()
    print("OK: test_nonblocking_send_head")
