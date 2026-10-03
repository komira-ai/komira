# =============================================================================
# komira_http/tests/test_client_send_buffered_honors_request_timeout.mojo
#   `HttpClient.with_request_timeout_us(...)` + `send_buffered(...)` must
#   HONOR the configured wall-clock budget.
# =============================================================================
#
# THE BUG THIS REPRODUCES. A client built with an 8 s request timeout
# precisely so a non-responsive peer cannot wedge its caller's serve thread
# blocked for **~300 s** — the platform's own request cut — not 8 s, and the
# caller returned 504.
#
# THE CAUSE IS A DROPPED ARGUMENT, NOT A BROKEN DEADLINE. The deadline machinery
# in `OutboundDriver` is correct and already has a falsifier
# (`test_head_drive_busy_spin.mojo::test_stuck_server_fails_with_deadline_not_
# iteration_cap`) — but that test drives `OutboundDriver` DIRECTLY. One layer up,
# `HttpClient._dispatch_pooled_buffered` (the path `send_buffered` takes) calls
# `_run_one_request_buffered_h1(...)`; WITHOUT its trailing `request_timeout_us`
# argument the parameter defaults to 0 and the driver silently uses
# `_HEAD_DRIVE_DEFAULT_TIMEOUT_US` (600 s) instead of the configured budget,
# while the `call` / `call_pooled` path still passes it — so the omission reads
# as "timeouts work".
#
# ⚠ A TEST AIMED ONE LAYER BELOW THE BUG MISSES IT. A deadline is only as good
# as the LAST frame that forwards it, so the assertion has to be made at the
# surface a CALLER actually uses — and most callers of
# `with_request_timeout_us` reach the wire through `send_buffered`.
#
# THE RED, VERBATIM:
#
#   AssertionError: must fail via the wall-clock deadline; got:
#   HttpError[RETRYABLE_TRANSPORT]: peer closed before any response byte
#
# ⚠ READ WHY THAT IS THE PRE-FIX SHAPE, because it is not the obvious one. With
# the budget dropped the driver takes the 600 s default, so the 150 ms deadline
# never fires; the request instead runs until the scripted stream's queued
# Pendings are EXHAUSTED and then EOFs, which the state machine reports as
# `RETRYABLE_TRANSPORT`. Both assertions below are therefore load-bearing and
# neither is redundant: the CLASS assertion is what catches the budget being
# dropped, and the ELAPSED assertion is what catches it being honoured but
# wrong. Raising the Pending budget past the 600 s default converts the first
# failure into the second — same defect, slower to observe.
#
# CORRECT: `HttpError[TIMEOUT]: request deadline exceeded` in ~150 ms.
#
# ★ TWO TESTS, ONE PER ARM — AND THE SECOND ONE IS NOT REDUNDANT.
# `_dispatch_pooled_buffered` reaches `_run_one_request_buffered_h1` at TWO
# sites, each forwarding `request_timeout_us` independently:
#   * the FRESH-DIAL arm  — a client that builds a fresh connector per call
#   * the CACHED-CONN arm — every keepalive reuser
# With ONLY the dial-arm test present, deleting the argument at the CACHED arm
# alone builds GREEN. With both tests present the same deletion is RED. Do not delete either test
# on the grounds that they "look the same" — they cover different call sites,
# and the arm with no test is the arm that silently regresses.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.client import HttpClient, build_get_request
from komira_http.client.header_map import HeaderMap
from komira_http.client.pool import PoolKey
from komira_http.client.url import Url
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream
from komira_clock import now_ns as _now_ns


comptime _BUDGET_US: Int = 150_000
"""The configured request budget (150 ms) — the same shape the busy-spin
regression uses, small enough that a PASS is unambiguous."""

comptime _CEILING_US: Int = 10_000_000
"""The elapsed ceiling (10 s). Generously above the 150 ms budget + one park
interval, and two orders of magnitude BELOW the 600 s default the dropped
argument selected — so this assertion cannot pass for the pre-fix code."""


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def test_send_buffered_honors_the_configured_request_timeout() raises:
    """A stuck server + an explicitly configured 150 ms budget must raise a
    wall-clock TIMEOUT promptly through `HttpClient.send_buffered`.

    This is the FRESH-DIAL arm of `_dispatch_pooled_buffered` — the arm a
    caller that builds a fresh connector per call takes. An empty
    read script plus a large queued-pending count is the canonical
    "server accepted the connection and never answered" double: `try_read`
    returns Pending forever, so the ONLY thing that can end the request is the
    deadline."""
    var stream = ScriptedStream.empty()
    # Pending takes precedence over the (empty) script, so this stream never
    # produces a byte and never EOFs: the server is stuck, not gone.
    stream.queue_read_pending(50_000_000)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    var reactor = _make_reactor()

    var url = Url.parse(String("http://127.0.0.1:8080/health"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var raised = False
    var detail = String()
    var start_us = Int(_now_ns() // UInt64(1000))
    try:
        var _resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = Int(_now_ns() // UInt64(1000)) - start_us

    assert_true(raised, msg="a stuck server must raise, not return")
    assert_true(
        "deadline exceeded" in detail,
        msg="must fail via the wall-clock deadline; got: " + detail,
    )
    # ★ THE HEADLINE ASSERTION. Pre-fix the configured budget was dropped and the
    # driver used the 600 s default, so this is the assertion that goes RED.
    assert_true(
        elapsed_us < _CEILING_US,
        msg=(
            "send_buffered ignored the configured "
            + String(_BUDGET_US)
            + " us request timeout: elapsed "
            + String(elapsed_us)
            + " us (the 600 s default was used)"
        ),
    )
    # And it must not fire EARLY either — a deadline that trips before its budget
    # would pass the ceiling assertion while being just as wrong.
    assert_true(
        elapsed_us >= _BUDGET_US,
        msg="deadline fired before its budget: " + String(elapsed_us) + " us",
    )


def test_send_buffered_cached_conn_honors_the_configured_request_timeout(
) raises:
    """The CACHED-connection arm must honour the budget too.

    ⚠ WHY THIS SECOND TEST EXISTS. `_dispatch_pooled_buffered` reaches
    `_run_one_request_buffered_h1` at TWO sites — a cached-idle-conn arm and a
    fresh-dial arm — and each forwards `request_timeout_us` independently. The
    sibling test above drives only the DIAL arm, so without this test the
    cached arm's forwarding is unfalsified: deleting the argument at the
    cached arm alone builds GREEN. A silent hole in a keepalive path is exactly
    how this defect survives.

    THE CACHED ARM IS NOT AN EDGE CASE — it is the steady state for any client
    that keeps a connection alive across requests (the object-store flush sink,
    every same-origin polling loop). Under the pre-fix defect those callers had
    the 600 s default on every request after their first.
    """
    # The stuck peer, pre-stashed as this client's h1 idle conn. Empty script +
    # a large pending count = `try_read` returns Pending forever, so the ONLY
    # thing that can end the request is the deadline.
    var stuck = ScriptedStream.empty()
    stuck.queue_read_pending(50_000_000)

    # ★ THE DIAL TRIPWIRE, AND IT IS LOAD-BEARING. An empty stream with NO
    # queued pendings EOFs on its first read, which the state machine reports as
    # RETRYABLE_TRANSPORT — NOT "deadline exceeded". So if the cache lookup ever
    # misses and this request DIALS instead, the class assertion below goes RED
    # rather than passing for the wrong reason. Without this, a key-mismatch
    # regression would silently convert this into a duplicate of the dial test.
    var dial_tripwire = ScriptedStream.empty()
    var connector = ScriptedConnector.with_stream(dial_tripwire^)

    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    # Stash the stuck conn under the key `http://127.0.0.1:8080` resolves to —
    # `host_copy()` + `effective_port()`, the same pair `_dispatch_pooled_
    # buffered` rebuilds for its cache probe.
    client._stash_h1_idle_stream(
        stuck^, PoolKey.http(String("127.0.0.1"), UInt16(8080)),
    )
    assert_true(
        client.h1_idle_conn_is_cached(),
        msg="fixture precondition: the idle conn must be stashed before send",
    )

    var reactor = _make_reactor()
    var url = Url.parse(String("http://127.0.0.1:8080/health"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var raised = False
    var detail = String()
    var start_us = Int(_now_ns() // UInt64(1000))
    try:
        var _resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = Int(_now_ns() // UInt64(1000)) - start_us

    assert_true(raised, msg="a stuck cached conn must raise, not return")
    # ★ PROVES WHICH ARM RAN. The cached arm skips the dial entirely, so a
    # nonzero connect count means the cache MISSED and this test measured the
    # dial arm — i.e. proved nothing about the code it exists to cover.
    assert_true(
        client._connector.connect_call_count() == 0,
        msg=(
            "expected the CACHED arm (zero dials), but the connector dialled "
            + String(client._connector.connect_call_count())
            + " time(s): the idle-conn cache missed, so this test measured the"
            " dial arm and proved nothing about the cached arm"
        ),
    )
    assert_true(
        "deadline exceeded" in detail,
        msg="must fail via the wall-clock deadline; got: " + detail,
    )
    # ★ THE HEADLINE ASSERTION, same shape as the dial test: pre-fix the budget
    # was dropped and the driver used the 600 s default.
    assert_true(
        elapsed_us < _CEILING_US,
        msg=(
            "send_buffered on a CACHED conn ignored the configured "
            + String(_BUDGET_US)
            + " us request timeout: elapsed "
            + String(elapsed_us)
            + " us (the 600 s default was used)"
        ),
    )
    assert_true(
        elapsed_us >= _BUDGET_US,
        msg="deadline fired before its budget: " + String(elapsed_us) + " us",
    )


def main() raises:
    test_send_buffered_honors_the_configured_request_timeout()
    test_send_buffered_cached_conn_honors_the_configured_request_timeout()
    print("OK: test_client_send_buffered_honors_request_timeout")
