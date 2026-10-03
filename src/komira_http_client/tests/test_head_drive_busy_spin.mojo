# =============================================================================
# src/komira_http_client/tests/test_head_drive_busy_spin.mojo
# =============================================================================
# regression.
#
# The blocking OutboundDriver `run` / `run_with_body` head-read + head-write
# loops drove non-blocking I/O helpers (`_drive_read_head` / `_drive_write`)
# that make NO progress on EWOULDBLOCK. The loops re-issued the syscall
# immediately with no park and no yield — a pure busy-spin — bounded only by a
# hard iteration cap (1M for `run`, 10M for `run_with_body`). A healthy server
# that holds the connection open while it WORKS before replying (e.g. an MLX /
# local-LLM chat-completion generation taking seconds) spun through the cap and
# then RAISED "state-machine iteration cap exceeded", FAILING a perfectly good
# request.
#
# These tests reproduce the spin/cap-out and pin the cooperative-wait fix:
#   1. A slow server that returns Pending MORE times than the OLD iteration
#      cap, then a valid response, must SUCCEED (no cap-out). Under the old
#      code this raised the iteration-cap TIMEOUT.
#   2. A genuinely-stuck server (never responds) must fail with a wall-clock
#      DEADLINE TIMEOUT in roughly the CONFIGURED time — cooperatively, not by
#      pinning a core through 1M/10M iterations.
#   3. The fast happy path (no pendings) is unchanged.
#
# ScriptedStream.fd() returns -1, so the cooperative park (`reactor.
# park_on_fds`) yields ~10 µs per park (a nanosleep) instead of pinning a core,
# keeping the test fast and deterministic.

from std.testing import assert_equal, assert_true

from std.sys.info import CompilationTarget

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.body import BytesBody, EmptyBody
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
from komira_clock import now_ns as _now_ns
from komira_http_core.transport.scripted import ScriptedStream



def _make_scratch() -> List[UInt8]:
    var s = List[UInt8]()
    var i = 0
    while i < 4096:
        s.append(UInt8(0))
        i = i + 1
    return s^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1
    return out^


def _make_get_request_bytes() raises -> List[UInt8]:
    var url = Url.parse(String("http://127.0.0.1/v1/chat/completions"))
    var hdrs = HeaderMap()
    var out = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 0, out)
    return out^


def test_run_slow_server_does_not_cap_out() raises:
    """REGRESSION: a slow server that returns Pending MORE than the OLD
    `run` iteration cap (1,000,000) before replying must SUCCEED. Under the
    old busy-spin code this raised "state-machine iteration cap exceeded".

    Queue 1,000,200 read-Pendings, then serve a valid 200 OK. The fix parks
    cooperatively after a small spin budget and bounds the loop by wall-clock
    time (generous default), so the eventual response is parsed."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    # OVER the old 1M cap — the distinguishing condition.
    stream.queue_read_pending(1_000_200)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(driver.state(), OUTBOUND_STATE_DONE)
    var tok = CancellationToken.never()
    var body_bytes = collect_body[
        PerCoreAsyncRuntime[NoopSink], ScriptedStream,
    ](resp.body, reactor, tok)
    assert_equal(body_bytes.__len__(), 5)


def test_run_with_body_slow_server_does_not_cap_out() raises:
    """REGRESSION on the POST path (the one the LLM transport drives via
    `build_request_with_body` / `run_with_body`): a slow server (Pending many
    times before the head arrives) must SUCCEED rather than cap out. Models a
    local-LLM generation that holds the connection open before its first
    response byte."""
    var url = Url.parse(String("http://127.0.0.1/v1/chat/completions"))
    var hdrs = HeaderMap()
    var req_bytes = List[UInt8]()
    serialize_request_head(method_get(), url, hdrs, 11, req_bytes)
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    # Many pendings before the head arrives (the server is "generating").
    stream.queue_read_pending(200_000)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var body = BytesBody.from_str(String("hello world"))
    var scratch_local = _make_scratch()
    var resp = driver.run_with_body[
        ScriptedStream, PerCoreAsyncRuntime[NoopSink], BytesBody,
    ](stream^, body^, reactor, Span[UInt8](scratch_local))
    assert_equal(Int(resp.status), 200)
    assert_equal(driver.state(), OUTBOUND_STATE_DONE)
    var tok = CancellationToken.never()
    var body_bytes = collect_body[
        PerCoreAsyncRuntime[NoopSink], ScriptedStream,
    ](resp.body, reactor, tok)
    assert_equal(body_bytes.__len__(), 2)


def test_stuck_server_fails_with_deadline_not_iteration_cap() raises:
    """A genuinely stuck server (never sends the head) must fail with a
    wall-clock DEADLINE TIMEOUT — cooperatively, in roughly the CONFIGURED
    time — not by busy-spinning through the old iteration cap.

    Configure a short 150 ms request timeout and queue far more pendings than
    can complete within it; the loop parks repeatedly and fails when the
    deadline elapses. Assert the error is the deadline message (not the old
    "iteration cap exceeded") and that the elapsed wall time is in the right
    ballpark (>= the configured budget, and not minutes)."""
    var req_bytes = _make_get_request_bytes()
    # Empty read-script + a large pending count = "server never responds".
    var stream = ScriptedStream.empty()
    stream.queue_read_pending(50_000_000)
    var driver = OutboundDriver.new(req_bytes^)
    driver.set_request_timeout_us(150_000)  # 150 ms budget
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()

    var raised = False
    var detail = String()
    var start_us = Int(_now_ns() // UInt64(1000))
    try:
        var _r = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
            stream^, reactor, Span[UInt8](scratch_local),
        )
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = Int(_now_ns() // UInt64(1000)) - start_us

    assert_true(raised, msg="stuck server must raise")
    # Cooperative deadline, NOT the old iteration-cap message.
    assert_true(
        "deadline exceeded" in detail,
        msg="must fail via wall-clock deadline; got: " + detail,
    )
    assert_true(
        "iteration cap" not in detail,
        msg="must NOT be the old iteration-cap failure; got: " + detail,
    )
    # Honored the configured budget (>= 150 ms) and resolved promptly after
    # (within one park interval + slack); definitely not minutes.
    assert_true(
        elapsed_us >= 150_000,
        msg="deadline fired too early: " + String(elapsed_us) + " us",
    )
    assert_true(
        elapsed_us < 10_000_000,
        msg="deadline took far too long: " + String(elapsed_us) + " us",
    )


def test_fast_path_unchanged() raises:
    """Happy path with ZERO pendings is unaffected by the spin-then-park
    machinery (no park taken; parses immediately)."""
    var req_bytes = _make_get_request_bytes()
    var resp_script = _b(String(
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello"
    ))
    var stream = ScriptedStream.from_read_script(resp_script^)
    var driver = OutboundDriver.new(req_bytes^)
    var reactor = _make_reactor()
    var scratch_local = _make_scratch()
    var resp = driver.run[ScriptedStream, PerCoreAsyncRuntime[NoopSink]](
        stream^, reactor, Span[UInt8](scratch_local),
    )
    assert_equal(Int(resp.status), 200)
    assert_equal(driver.state(), OUTBOUND_STATE_DONE)


def main() raises:
    test_fast_path_unchanged()
    test_run_slow_server_does_not_cap_out()
    test_run_with_body_slow_server_does_not_cap_out()
    test_stuck_server_fails_with_deadline_not_iteration_cap()
    print("OK: test_head_drive_busy_spin")
