# =============================================================================
# komira_http/tests/test_head_drive_deadline_survives_byte_dribble.mojo
#   The H1 drive loop's wall-clock deadline must be EVALUATED even while the
#   peer is delivering bytes. A peer that dribbles is still a stuck peer.
# =============================================================================
#
# THE BUG THIS REPRODUCES: hours of 504s at exactly the platform's 300.000 s
# request ceiling.
#
# `OutboundDriver.run` / `run_with_body` bound themselves by REAL time — but
# only through `_tick_no_progress`, and only inside its spin-budget branch:
#
#     no_progress = no_progress + 1
#     if no_progress >= _HEAD_DRIVE_SPIN_BUDGET:        # 64
#         ...park...
#         if now_us >= deadline_us: raise TIMEOUT       # <-- ONLY HERE
#
# and every caller reset the counter the moment ANY byte arrived:
#
#     elif self._recv_buf.__len__() > before_recv:
#         no_progress = 0                              # <-- the reset
#
# So a peer that hands over one byte more often than every 64 iterations keeps
# `no_progress` below the budget FOREVER, `_tick_no_progress` never reaches its
# deadline check, and the request never times out — not at the configured
# budget, not at the 600 s default, not ever. The deadline was defeatable by
# the very peer it exists to defend against.
#
# ⚠ WHY THIS IS AN OUTAGE AND NOT A CURIOSITY. A strictly serial serve loop
# (one `serve_one_iteration_dispatch` + background pumps, in one thread) whose
# pumps refresh an OAuth token through a PLAIN-HTTP/1.1 `send_buffered` GET to
# the metadata server, built with `with_defaults`, stops EVERY route on the
# instance when one such call never returns: every route 504s together at the
# Cloud Run 300 s ceiling while the process stays alive at a steady low CPU
# (64 spins + one 50 ms park per cycle — the signature of this exact loop).
#
# ⚠ THIS IS A DIFFERENT DEFECT FROM THE DROPPED ARGUMENT.
# `test_client_send_buffered_honors_request_timeout.mojo` covers
# `_dispatch_pooled_buffered` FORGETTING to forward `request_timeout_us`, so
# the driver silently takes the 600 s default. That is necessary but NOT
# sufficient: it makes the driver hold the RIGHT number, while this
# defect is the driver never LOOKING at whatever number it holds. Neither test
# covers the other — the sibling's stream never sends a byte, so it never
# exercises the reset that hides the check.
#
# THE RED (this file against a driver whose deadline is gated):
#
#   AssertionError: a dribbling peer must fail via the wall-clock deadline;
#   got: HttpError[EOF_MID_RESPONSE]: peer closed during head
#
# ⚠ READ WHY THAT IS THE PRE-FIX SHAPE. With the deadline never evaluated, the
# request does not hang forever in the TEST — it hangs until the scripted
# stream runs out of dribble and EOFs, which the state machine reports as
# `EOF_MID_RESPONSE`. A live peer holding the socket open supplies the dribble
# indefinitely and the request then hangs forever, which is the outage. The
# finite script is what makes the bug OBSERVABLE in bounded time; the error
# CLASS is the assertion, and it is the load-bearing one.
#
# POST-FIX: `HttpError[TIMEOUT]: request deadline exceeded` in ~150 ms.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.client import HttpClient, build_get_request
from komira_http.client.header_map import HeaderMap
from komira_http.client.url import Url
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream
from komira_obs.clock import now_ns as _now_ns


comptime _BUDGET_US: Int = 150_000
"""The configured request budget (150 ms) — the same shape the sibling
`send_buffered` regression uses."""

comptime _CEILING_US: Int = 30_000_000
"""The elapsed ceiling (30 s). Generously above the 150 ms budget plus the
whole dribble, and far below the unbounded wait the defect produced."""

comptime _DRIBBLE_HEADERS: Int = 60
"""Header lines in the never-terminated head. MUST stay under
`DEFAULT_RESP_MAX_HEADERS` (100) or the parser raises a limits error — a
DIFFERENT error class, which would make this test pass for the wrong reason."""

comptime _DRIBBLE_PAD: Int = 380
"""Padding bytes per header line. Total head stays near 23 KiB — under
`DEFAULT_RESP_MAX_TOTAL_HEADER_BYTES` (65536) and each line far under
`DEFAULT_RESP_MAX_HEADER_BYTES` (16384), for the same reason."""


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](
            NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL,
        )
    return Reactor[NoopSink](
        NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE,
    )


def _append_str(mut out: List[UInt8], s: String):
    var bytes_ref = s.as_bytes()
    var n = len(bytes_ref)
    var i = 0
    while i < n:
        out.append(bytes_ref[i])
        i = i + 1


def _never_terminated_head() -> List[UInt8]:
    """A syntactically VALID but INCOMPLETE response head: a status line and
    `_DRIBBLE_HEADERS` complete header lines, and never the blank line that
    ends a head. `parse_response_head` returns `need_more` on every prefix of
    this, so the driver keeps reading — exactly what a half-answering peer
    does — while every byte read resets the no-progress counter."""
    var out = List[UInt8]()
    _append_str(out, String("HTTP/1.1 200 OK\r\n"))
    var i = 0
    while i < _DRIBBLE_HEADERS:
        var line = String("X-Pad-") + String(i) + String(": ")
        var k = 0
        while k < _DRIBBLE_PAD:
            line = line + String("a")
            k = k + 1
        _append_str(out, line + String("\r\n"))
        i = i + 1
    return out^


def test_dribbling_peer_cannot_defeat_the_request_deadline() raises:
    """A peer that trickles head bytes without ever finishing the head must
    still fail on the configured wall-clock budget.

    `set_max_read_per_call(1)` is the whole fixture: one byte per `try_read`
    means `_recv_buf` grows on EVERY iteration, so the caller takes the
    `no_progress = 0` arm every single time and `_tick_no_progress` — the only
    place the pre-fix driver consulted the clock — is never called at all."""
    var stream = ScriptedStream.from_read_script(_never_terminated_head())
    # THE DRIBBLE. One byte per read is the minimum that still counts as
    # progress, and it is what makes the reset fire on every iteration.
    stream.set_max_read_per_call(1)
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

    assert_true(raised, msg="a dribbling peer must raise, not return")
    # THE CLASS ASSERTION — the one that catches the deadline never being
    # evaluated. Pre-fix this reads EOF_MID_RESPONSE (the dribble ran out).
    assert_true(
        detail.find(String("TIMEOUT")) >= 0,
        msg=(
            "a dribbling peer must fail via the wall-clock deadline; got: "
            + detail
        ),
    )
    # THE ELAPSED ASSERTION — catches a deadline that is evaluated but wrong.
    assert_true(
        elapsed_us < _CEILING_US,
        msg=(
            "deadline must fire promptly; elapsed_us="
            + String(elapsed_us)
            + " ceiling_us="
            + String(_CEILING_US)
        ),
    )
    # And it must not fire EARLY — a deadline that trips before its budget
    # would satisfy both assertions above while being just as wrong.
    assert_true(
        elapsed_us >= _BUDGET_US,
        msg="deadline fired before its budget: " + String(elapsed_us) + " us",
    )


def main() raises:
    test_dribbling_peer_cannot_defeat_the_request_deadline()
    print("test_head_drive_deadline_survives_byte_dribble: OK")
