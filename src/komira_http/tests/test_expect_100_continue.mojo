# =============================================================================
# src/komira_http/tests/test_expect_100_continue.mojo
# =============================================================================
# Expect: 100-continue + WaitingForContinue state
# acceptance tests.
#
# Two cases:
#   1. Server sends 100 Continue, then accepts body, replies 200.
#      Driver passes through WAITING_FOR_CONTINUE → WRITING_REQUEST_BODY
#      → READING_RESPONSE_HEAD → DONE. ClientResponse carries 200.
#   2. Server sends 4xx (e.g. 417 Expectation Failed) directly without
#      waiting for body. Driver detects non-100 status, skips body
#      write, transitions to DONE. ClientResponse carries 417.

from std.testing import assert_equal, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from std.sys.info import CompilationTarget

from komira_http.client.body import BytesBody
from komira_http.client.header_map import HeaderMap
from komira_http.client.request_writer import (
    method_post,
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
)
from komira_http.client.url import Url
from komira_http.transport.scripted import ScriptedStream



def _make_scratch() -> List[UInt8]:
    """REUSE local helper."""
    var s = List[UInt8]()
    var i = 0
    while i < 4096:
        s.append(UInt8(0))
        i = i + 1
    return s^


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var i = 0
    while i < len(bytes_ref):
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        from komira_async.reactor.reactor import BACKEND_EPOLL
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _build_post_head_with_expect() raises -> List[UInt8]:
    """Build a POST request head with Expect: 100-continue."""
    var url = Url.parse(String("http://127.0.0.1:8080/upload"))
    var hdrs = HeaderMap()
    hdrs.append(String("Expect"), String("100-continue"))
    var out = List[UInt8]()
    serialize_request_head(method_post(), url, hdrs, 11, out)
    return out^


# =============================================================================
# Test 1: 100 Continue → body sent → 200 OK final.
# =============================================================================


def test_expect_100_continue_accept() raises:
    """Server sends 100 Continue interim, then 200 OK final after
    receiving body. Driver: WRITING_HEAD → WAITING_FOR_CONTINUE (sees
    100) → WRITING_BODY → READING_HEAD (sees 200) → DONE."""
    var req_bytes = _build_post_head_with_expect()
    var resp_script = _b(String(
        "HTTP/1.1 100 Continue\r\n\r\n"
        + "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var body = BytesBody.from_str(String("hello world"))
    var scratch_local = _make_scratch()

    var resp = driver.run_with_body[
        ScriptedStream, PerCoreAsyncRuntime[NoopSink], BytesBody,
    ](stream^, body^, reactor, Span[UInt8](scratch_local), expect_continue=True)
    assert_equal(Int(resp.status), 200)
    assert_equal(driver.state(), OUTBOUND_STATE_DONE)
    var tok = CancellationToken.never()
    var body_bytes = collect_body[
        PerCoreAsyncRuntime[NoopSink], ScriptedStream,
    ](resp.body, reactor, tok)
    assert_equal(body_bytes.__len__(), 2)


# =============================================================================
# Test 2: 417 Expectation Failed — body NOT sent, response is 417.
# =============================================================================


def test_expect_100_continue_reject() raises:
    """Server rejects with 417 Expectation Failed instead of 100
    Continue. Driver: WRITING_HEAD → WAITING_FOR_CONTINUE (sees 417,
    != 100) → DONE. ClientResponse carries 417."""
    var req_bytes = _build_post_head_with_expect()
    var resp_script = _b(String(
        "HTTP/1.1 417 Expectation Failed\r\nContent-Length: 0\r\n\r\n"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var body = BytesBody.from_str(String("hello world"))
    var scratch_local = _make_scratch()

    var resp = driver.run_with_body[
        ScriptedStream, PerCoreAsyncRuntime[NoopSink], BytesBody,
    ](stream^, body^, reactor, Span[UInt8](scratch_local), expect_continue=True)
    assert_equal(Int(resp.status), 417)
    assert_equal(driver.state(), OUTBOUND_STATE_DONE)


def main() raises:
    test_expect_100_continue_accept()
    test_expect_100_continue_reject()
    print("OK: test_expect_100_continue")
