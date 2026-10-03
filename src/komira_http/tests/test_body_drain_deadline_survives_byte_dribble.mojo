# =============================================================================
# komira_http/tests/test_body_drain_deadline_survives_byte_dribble.mojo
#   The RESPONSE-BODY drain's wall-clock deadline must be EVALUATED even while
#   the peer is delivering bytes. A peer that dribbles is still a stuck peer.
# =============================================================================
#
# THE BODY-PHASE TWIN of `test_head_drive_deadline_survives_byte_dribble.mojo`.
# Same attack, one layer up. A body layer without its own deadline has no
# bound at ALL — not a defeatable one, none:
#
#   * `collect_body` takes NO deadline parameter.
#   * Callers pass `CancellationToken.never()`, which by construction never
#     trips.
#   * A driver deadline that bounds the HEAD phase only hands the
#     responsibility to RecvRingBody.
#   * The drain loop's other stop is `max_iter = 1_000_000` — 4 spins then one
#     50 ms park, i.e. roughly 10,000 SECONDS, which is not a bound.
#
# ⚠ WHY THIS IS AN OUTAGE AND NOT A CURIOSITY. Unbounded, the only thing that
# ends these requests is the platform's own request ceiling: the service
# serves 504s at exactly its 300 s ceiling and is unavailable in multi-minute
# windows, while the process stays alive the whole time.
#
# ⚠ THIS IS A DIFFERENT DEFECT FROM A SWALLOWED CHUNKED PARSE ERROR: there, a
# read boundary inside a chunked framing token drops the token and the
# resulting parse error is swallowed, so the drain never self-terminates
# (covered by the recv-ring chunked tests). THIS half is a body that simply
# never arrives — no parse error exists to surface, so only a deadline bounds
# the wait.
#
# =============================================================================
# THE SIX CASES, AND WHY EACH ONE IS HERE
# =============================================================================
#
#  1. DRIBBLE (end-to-end)  — the load-bearing one. One byte per read keeps
#     `_accum` non-empty and resets `pending_run` on EVERY poll, so a check
#     placed inside the spin-budget branch is never REACHED. This is the exact
#     shape that defeated the head loop's first deadline.
#  2. STALL (end-to-end)    — the easy half. Head arrives, body never does.
#  3. CONTROL (end-to-end)  — ⭐ a slow-but-COMPLETE body must NOT be killed.
#     Without this, an over-aggressive deadline passes 1 and 2 and ships,
#     silently breaking large object-store downloads. reqwest asserts the same
#     thing (`read_timeout_allows_slow_response_body`), as do Go
#     (`TestClientTimeoutDoesNotExpire`) and Envoy
#     (`PerStreamIdleTimeoutRequestAndResponse`).
#  4. ARITHMETIC (no clock) — deterministic, microseconds, zero flake: an
#     already-expired deadline must fire on the FIRST poll EVEN THOUGH THE
#     STREAM HAS BYTES READY. That is the "gated on nothing" property stated
#     as an assertion rather than as a comment.
#  5. EXEMPTIONS            — the three carve-outs asserted POSITIVELY, so a
#     later "simplification" that drops the guard predicate goes noticed.
#  6. K-STREAM              — `drain_bodies_round_robin`, the parquet prefetch
#     path, which calls `collect_body` NEVER and whose fallback cap gets
#     LOOSER as K grows (`1_000_000 * k`). Three healthy streams must not keep
#     a fourth, silent one alive.
#  7. NO POOLING            — a timed-out body must refuse to surrender its
#     stream. An h1 connection whose drain was abandoned is at an UNKNOWN BYTE
#     OFFSET; returning it to the keepalive cache is silent cross-request
#     corruption, strictly worse than the hang. reqwest pins this separately
#     (`timeout_closes_connection`).
#  8. OVERFLOW              — an absurd budget must read as "generous", not
#     wrap into a past instant (reqwest `big_timeout_duration_does_not_
#     overflow`).
#  9. ⭐ THE STEPPER STAMP   — the non-blocking stepper is the ONE
#     piece of genuinely new plumbing in this change, and it is INVISIBLE
#     from every `collect_body` call site. Forget it and the parquet
#     K-stream path — the loosest bound in the tree — stays unbounded
#     while `collect_body` looks fixed. Case 6 drives
#     `drain_bodies_round_robin` with a HAND-stamped deadline and so
#     cannot catch that; this case drives the driver itself.
#
# ⛔ NO `sleep` ANYWHERE. Case 4 moves time by ARITHMETIC (the deadline is a
# plain absolute `Int`, so a test can stamp one in the past). Cases 1-3 are
# bounded by a tight configured budget and a generous elapsed ceiling; they
# spend real time the way their head-phase twin already does.
#
# ⛔ DO NOT ASSERT ON THE STRING `collect_body iteration cap exceeded`. That
# is the 10,000-second ITERATION CAP, not a deadline — it says TIMEOUT while
# measuring no time, and external log checks may match on it. A test asserting on it would pass for the
# wrong reason. Every assertion below keys on `response body deadline`, the
# text only the deadline produces.
#
# THE MEASURED RED (this file against the pre-fix drain): cases 1, 2 and 6
# raise `HttpError[EOF_MID_RESPONSE]` / `HttpError[...]` instead of a TIMEOUT,
# and case 4 returns a Data frame instead of raising. The finite scripts and
# finite pending counts are what make an UNBOUNDED wait observable in BOUNDED
# time; the error CLASS and the phase word are the assertions.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime
from komira_core.collections.slab import Slab

from komira_http.client.client import HttpClient, build_get_request
from komira_http.client.header_map import HeaderMap
from komira_http.client.response_body import (
    RecvRingBody,
    collect_body,
    drain_bodies_round_robin,
)
from komira_http.client.state_machine import (
    OUTBOUND_STEP_HEAD_DONE,
    OUTBOUND_STEP_NOT_READY,
    OutboundDriver,
)
from komira_http.client.url import Url
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream
from komira_clock import now_ns as _now_ns


# =============================================================================
# Sizing constants. ⚠ READ THIS BEFORE CHANGING ONE.
# =============================================================================
#
# The wall time of cases 1 and 2 is `polls x cost_per_poll`, and
# `cost_per_poll` is dominated by ONE thing: `RecvRingBody.poll_frame`
# allocates a fresh `_scratch_size`-byte (64 KiB by default) scratch List
# by appending a zero byte at a time, on EVERY poll, INCLUDING a poll that
# ends in Pending. Measured with the deadline check neutered so the drain ran
# to script exhaustion:
#     400,000 one-byte polls in 14.77 s  =>  ~37 us per poll.
# `_report` prints that number on every run, so the next person to resize
# these does not have to re-derive it.
#
# ⚠ AND IT DOES NOT TRANSFER FROM THE HEAD TWIN. That test gets its wall time
# from `parse_response_head` RE-SCANNING the whole buffer per byte — O(n^2)
# over 23 KiB. Body decode is INCREMENTAL and O(n), so a body dribble runs
# far more cheaply PER BYTE and the script must be correspondingly larger to
# outlast the same budget. Size these by measurement, never by copying the
# head twin's numbers.
#
# The invariant each constant must keep:
#   case 1:  _DRIBBLE_BODY_BYTES * cost  >>  _BUDGET_US      (deadline first)
#   case 2:  _STALL_PENDING_READS * cost >>  _BUDGET_US      (deadline first)
#   case 3:  _CONTROL_BODY_BYTES  * cost <<  _CONTROL_BUDGET_US (no fire)
# and in every case `... * cost < _CEILING_US`, so the PRE-FIX red still
# lands in bounded time instead of hanging the suite.

comptime _BUDGET_US: Int = 150_000
"""The configured request budget (150 ms) for cases 1 and 2 — the same shape
the head-phase twin uses. It bounds head AND body out of ONE budget, so it
must also be comfortably above the cost of reading the (tiny) head."""

comptime _CEILING_US: Int = 60_000_000
"""Elapsed ceiling (60 s). Far above the 150 ms budget plus the whole scripted
dribble, and far below the unbounded wait the defect produced."""

comptime _DRIBBLE_BODY_BYTES: Int = 200_000
"""Body bytes in case 1's script, delivered ONE PER READ. Must outlast
`_BUDGET_US`; see the invariant above. At the measured ~37 us/poll the
150 ms budget is reached after ~4,100 polls, so this carries ~49x margin
-- and a box 10x faster still carries ~5x. The PRE-FIX red costs ~7.4 s
(the whole script), which is why it is not larger still."""

comptime _STALL_PENDING_READS: Int = 200_000
"""Pending reads case 2's peer returns after its script is exhausted,
before EOF. Must outlast `_BUDGET_US`; see the invariant above -- same
arithmetic and same margins as `_DRIBBLE_BODY_BYTES`. A Pending poll pays
the SAME scratch allocation as a Data poll, which is why one measured cost
sizes both."""

comptime _CONTROL_BODY_BYTES: Int = 4096
"""Body bytes in case 3's COMPLETE body, delivered ONE PER READ. Must finish
well inside `_CONTROL_BUDGET_US`."""

comptime _CONTROL_BUDGET_US: Int = 120_000_000
"""Case 3's budget (120 s) — two orders of magnitude of headroom over the
measured cost of dribbling `_CONTROL_BODY_BYTES` one byte at a time. A
CONTROL that flakes teaches people to widen the deadline, which is the one
lesson this file must not teach."""

comptime _PHASE_WORD: String = String("response body deadline")
"""The phrase an operator greps for. It is what makes a body timeout
distinguishable, in one log line, from a CONNECT timeout, from the head
loop's "while driving the request", and from the iteration cap's
"collect_body iteration cap exceeded" (which says TIMEOUT while measuring no
time). Every assertion in this file keys on THIS, not on "TIMEOUT"."""


# =============================================================================
# Fixtures
# =============================================================================


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


def _head_with_content_length(cl: Int) -> List[UInt8]:
    """A COMPLETE, well-formed response head announcing `cl` body bytes. The
    head is deliberately whole: this file is about the BODY phase, and a test
    whose head never finished would be testing the head loop's deadline
    instead (which its own twin already covers)."""
    var out = List[UInt8]()
    _append_str(out, String("HTTP/1.1 200 OK\r\n"))
    _append_str(out, String("Content-Length: ") + String(cl) + String("\r\n"))
    _append_str(out, String("\r\n"))
    return out^


def _pattern_byte(i: Int) -> UInt8:
    """Distinct per-offset byte so a CONTROL body can be checked BYTE-EXACT,
    not merely by length."""
    return UInt8((i * 31 + 7) % 251)


def _body_bytes(n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    var i = 0
    while i < n:
        out.append(_pattern_byte(i))
        i = i + 1
    return out^


def _concat(var a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a^
    var i = 0
    var n = b.__len__()
    while i < n:
        out.append(b[i])
        i = i + 1
    return out^


def _report(label: String, elapsed_us: Int, polls: Int):
    """Print the measured per-poll cost. NOT an assertion — it is the number
    the sizing constants above are derived from, printed every run so the next
    person to resize them does not have to guess."""
    print(
        String("  [") + label + String("] elapsed_us=") + String(elapsed_us)
        + String(" over ~") + String(polls) + String(" polls")
    )


# =============================================================================
# Case 1 — ⭐ THE DRIBBLE. The load-bearing case.
# =============================================================================


def test_dribbling_body_cannot_defeat_the_response_body_deadline() raises:
    """A peer that trickles BODY bytes without ever satisfying its announced
    Content-Length must still fail on the configured wall-clock budget.

    `set_max_read_per_call(1)` is the whole fixture. One byte per `try_read`
    means every `poll_frame` returns a Data frame, so `collect_body` takes its
    `pending_run = 0` arm on EVERY iteration and NEVER reaches
    `_COLLECT_BODY_SPIN_BUDGET`. A deadline check placed in the spin/park
    branch — the natural place, since the park already lives there — would
    therefore never execute. That is why the check lives at the TOP of
    `poll_frame`, gated on nothing the peer can steer.

    The announced Content-Length is far larger than the script, so the body
    can never complete; the script is FINITE so the pre-fix red lands in
    bounded time (as `EOF_MID_RESPONSE` once the dribble runs out) instead of
    hanging the suite forever, which is what a live peer would do."""
    var script = _concat(
        _head_with_content_length(100_000_000),
        _body_bytes(_DRIBBLE_BODY_BYTES),
    )
    var stream = ScriptedStream.from_read_script(script^)
    # THE DRIBBLE. One byte per read is the minimum that still counts as
    # progress, and it is what makes the reset fire on every single poll.
    stream.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    var reactor = _make_reactor()

    var url = Url.parse(String("http://127.0.0.1:8080/blob"))
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
    _report(String("dribble"), elapsed_us, _DRIBBLE_BODY_BYTES)

    assert_true(raised, msg="a dribbling body must raise, not return")
    # THE CLASS + PHASE ASSERTION — the one that catches the deadline never
    # being evaluated. Pre-fix this reads EOF_MID_RESPONSE (the dribble ran
    # out). It keys on the PHASE WORD, never on the bare word TIMEOUT, so the
    # iteration cap cannot satisfy it.
    assert_true(
        detail.find(String("TIMEOUT")) >= 0
        and detail.find(_PHASE_WORD) >= 0,
        msg=(
            "a dribbling body must fail via the body drain's wall-clock"
            " deadline; got: " + detail + " (elapsed_us="
            + String(elapsed_us) + ")"
        ),
    )
    # THE ELAPSED ASSERTION — catches a deadline that is evaluated but wrong.
    assert_true(
        elapsed_us < _CEILING_US,
        msg=(
            "deadline must fire promptly; elapsed_us="
            + String(elapsed_us) + " ceiling_us=" + String(_CEILING_US)
        ),
    )
    # And it must not fire EARLY — a deadline that trips before its budget
    # would satisfy both assertions above while being just as wrong.
    assert_true(
        elapsed_us >= _BUDGET_US,
        msg="deadline fired before its budget: " + String(elapsed_us) + " us",
    )


# =============================================================================
# Case 2 — THE FULL STALL. The easy half. Do not mistake it for case 1.
# =============================================================================


def test_stalled_body_is_bounded_by_the_response_body_deadline() raises:
    """Headers arrive; the body never does. The peer holds the connection
    open and sends nothing — every `try_read` is a WouldBlock.

    `set_pending_after_script` is the stall generator, and it is deliberately
    NOT `queue_read_pending`: that counter is consumed from the very first
    read, so on an end-to-end fixture the HEAD phase eats it and the stall
    lands in the wrong phase. This one arms only once the script is
    exhausted, which is the real shape — a peer that completed the response
    head and then went quiet.

    Pre-fix, `collect_body` spins 4 and parks, walking toward a `max_iter`
    cap of roughly 10,000 SECONDS, which is not observable in a test. The
    FINITE pending count is what makes the pre-fix red land in bounded time
    (as EOF_MID_RESPONSE, once the peer finally closes)."""
    var stream = ScriptedStream.from_read_script(
        _head_with_content_length(1000)
    )
    stream.set_pending_after_script(_STALL_PENDING_READS)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    var reactor = _make_reactor()

    var url = Url.parse(String("http://127.0.0.1:8080/blob"))
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
    _report(String("stall"), elapsed_us, _STALL_PENDING_READS)

    assert_true(raised, msg="a stalled body must raise, not return")
    assert_true(
        detail.find(String("TIMEOUT")) >= 0
        and detail.find(_PHASE_WORD) >= 0,
        msg=(
            "a stalled body must fail via the body drain's wall-clock"
            " deadline; got: " + detail + " (elapsed_us="
            + String(elapsed_us) + ")"
        ),
    )
    assert_true(
        elapsed_us < _CEILING_US,
        msg="stall deadline must fire promptly; elapsed_us="
        + String(elapsed_us),
    )
    assert_true(
        elapsed_us >= _BUDGET_US,
        msg="stall deadline fired before its budget: "
        + String(elapsed_us) + " us",
    )


# =============================================================================
# Case 3 — ⭐ THE CONTROL. A slow but PROGRESSING body must NOT be killed.
# =============================================================================


def test_slow_but_complete_body_is_not_killed() raises:
    """A COMPLETE body, dribbled one byte per read, well inside a generous
    budget, must come back WHOLE and BYTE-EXACT with no error.

    This is the assertion that stops an over-aggressive fix from shipping.
    Cases 1 and 2 are both satisfied by a deadline that is simply too short;
    only this one says the deadline may not punish slowness that is making
    progress toward a finite end. Every surveyed client asserts the same
    property explicitly rather than leaving it implicit — reqwest's
    `read_timeout_allows_slow_response_body` REQUIRES a trickling body to
    succeed; Envoy's `PerStreamIdleTimeoutAfterBidiData` interleaves clock
    advances with one-byte writes six times and asserts the stream SURVIVES;
    urllib3 states it in its own class docstring ("if a server streams one
    byte every fifteen seconds, a timeout of 20 seconds will not trigger").

    ⚠ It is also why an IDLE (per-read / no-progress) bound was NOT shipped
    as the primary: a dribbler defeats an idle bound BY DEFINITION, so an
    idle-only fix would leave the same failure in place under a friendlier
    name. An idle bound belongs NESTED INSIDE this total."""
    var expected = _body_bytes(_CONTROL_BODY_BYTES)
    var script = _concat(
        _head_with_content_length(_CONTROL_BODY_BYTES),
        _body_bytes(_CONTROL_BODY_BYTES),
    )
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _CONTROL_BUDGET_US,
    )
    var reactor = _make_reactor()

    var url = Url.parse(String("http://127.0.0.1:8080/blob"))
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var start_us = Int(_now_ns() // UInt64(1000))
    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    var elapsed_us = Int(_now_ns() // UInt64(1000)) - start_us
    _report(String("control"), elapsed_us, _CONTROL_BODY_BYTES)

    assert_equal(Int(resp.status), 200)
    var got = resp.body.take_bytes()
    assert_equal(
        got.__len__(),
        _CONTROL_BODY_BYTES,
        msg="a slow but complete body must come back WHOLE",
    )
    # BYTE-EXACT, not merely the right length: a deadline that truncated the
    # body and returned what it had would pass a length-only check.
    var i = 0
    while i < _CONTROL_BODY_BYTES:
        assert_equal(Int(got[i]), Int(expected[i]))
        i = i + 1


# =============================================================================
# Case 4 — ⭐ THE ARITHMETIC CASE. Deterministic, no wall clock, no flake.
# =============================================================================


def test_expired_deadline_fires_on_first_poll_even_with_bytes_ready() raises:
    """An ALREADY-EXPIRED deadline must fire on the FIRST `poll_frame` even
    though the body has decoded bytes sitting in `_accum` ready to emit.

    THIS IS THE "GATED ON NOTHING" PROPERTY, STATED AS AN ASSERTION. The
    obvious fourth exemption — "skip the check if we have work to do" — is
    the one the PEER controls: a dribbler keeps `_accum` non-empty on every
    poll, so exempting it recreates the head-loop dribble defect one layer down.
    Bytes being ready must not suppress the check.

    It is also the already-expired-before-any-I/O semantic that grpc-go pins
    at `http2_client.go:621-624` and Envoy at `router.cc:302-304`.

    No clock is injected into `RecvRingBody` and none is needed: the deadline
    is a plain ABSOLUTE `Int`, so the test moves time by ARITHMETIC. That is
    deliberate — threading a `Clock` conformer would add a second type
    parameter to `RecvRingBody[S]` and to every `ClientResponse[RecvRingBody[
    S]]` in the tree, for a determinism this shape already gives free."""
    var content = _body_bytes(64)
    var stream = ScriptedStream.from_read_script(_body_bytes(64))
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, 128, content^,
    )
    # 64 of the 128 announced bytes are already decoded and waiting, and the
    # stream holds 64 more that are READY to read. Neither may save it.
    var now_us = Int(_now_ns() // UInt64(1000))
    body.set_deadline_us(now_us - 1)

    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var raised = False
    var detail = String()
    try:
        var _frame = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](
            reactor, tok,
        )
    except e:
        raised = True
        detail = String(e)

    assert_true(
        raised,
        msg=(
            "an expired deadline must fire on the FIRST poll even with bytes"
            " ready to emit"
        ),
    )
    assert_true(
        detail.find(_PHASE_WORD) >= 0,
        msg="wrong error for an expired body deadline: " + detail,
    )
    # The message must carry the BYTES DRAINED SO FAR — the single most
    # useful number for telling "the peer never started" from "the peer
    # started and stalled". Zero emitted + 64 accumulated.
    assert_true(
        detail.find(String("64 body bytes")) >= 0,
        msg="body timeout must report the bytes drained so far: " + detail,
    )


def test_deadline_only_ever_tightens() raises:
    """Go's deference rule (`setRequestCancel`, client.go:366-369): a client's
    budget may TIGHTEN a caller's deadline and may never LOOSEN it. A second
    stamp that is LATER than the one already held must be dropped, so a layer
    added above this one cannot silently widen a bound a layer below already
    committed to."""
    var stream = ScriptedStream.from_read_script(List[UInt8]())
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, 128, List[UInt8](),
    )
    body.set_deadline_us(1_000_000)
    assert_equal(body.deadline_us(), 1_000_000)
    # LOOSER — must be ignored.
    body.set_deadline_us(9_000_000)
    assert_equal(
        body.deadline_us(),
        1_000_000,
        msg="a later deadline must never widen an earlier one",
    )
    # TIGHTER — must win.
    body.set_deadline_us(500_000)
    assert_equal(
        body.deadline_us(),
        500_000,
        msg="a tighter deadline must always win",
    )
    # `_NO_DEADLINE` (0) is "nothing to arm", not "unbound me".
    body.set_deadline_us(0)
    assert_equal(
        body.deadline_us(),
        500_000,
        msg="stamping 0 must not clear a live deadline",
    )


def test_absurd_budget_does_not_wrap_into_the_past() raises:
    """The reqwest case `big_timeout_duration_does_not_overflow`. A caller
    passing an enormous budget must read as "generous", never wrap
    `started + budget`
    into a PAST instant and fail instantly — which is a timeout that fires
    BECAUSE the timeout was large."""
    var content = _body_bytes(8)
    var stream = ScriptedStream.from_read_script(List[UInt8]())
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, 8, content^,
    )
    # Int.MAX-ish. Saturation must keep it in the future.
    body.set_deadline_us((1 << 62) + (1 << 61))
    assert_true(
        body.deadline_us() > Int(_now_ns() // UInt64(1000)),
        msg="a saturated deadline must still be in the FUTURE",
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var frame = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(
        frame.is_data(),
        msg="an absurd budget must behave as generous, not fire instantly",
    )


# =============================================================================
# Case 5 — THE EXEMPTIONS, ASSERTED POSITIVELY.
# =============================================================================
#
# The check is gated on a WHITELIST OF OUR OWN STATES: not `_done`, not EMPTY
# framing, not PREBUFFERED framing. Each is a state in which this call
# performs NO WIRE WAIT AT ALL, so bounding it would cost bytes for zero
# benefit. If these are not asserted, a later "simplification" that drops the
# predicate — and so starts failing a completed body — goes unnoticed.


def test_a_finished_body_still_returns_end_after_its_deadline() raises:
    """`_done` must stay idempotent. A body that already completed has
    nothing in flight; failing it would retract a complete answer."""
    var content = _body_bytes(16)
    var stream = ScriptedStream.from_read_script(List[UInt8]())
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, 16, content^,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f1.is_data())
    var f2 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f2.is_end())
    assert_true(body.is_done())
    # NOW expire it. End must still be End.
    body.set_deadline_us(Int(_now_ns() // UInt64(1000)) - 1)
    var f3 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(
        f3.is_end(),
        msg="a finished body must keep returning End after its deadline",
    )


def test_an_empty_body_still_returns_end_after_its_deadline() raises:
    """HEAD / 204 / 304 / CL=0: returns End without touching the stream."""
    var stream = ScriptedStream.from_read_script(List[UInt8]())
    var body = RecvRingBody[ScriptedStream].new_empty(stream^)
    body.set_deadline_us(Int(_now_ns() // UInt64(1000)) - 1)
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var f = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(
        f.is_end(),
        msg="an EMPTY-framed body must return End regardless of deadline",
    )


def test_a_prebuffered_body_still_emits_after_its_deadline() raises:
    """The GCS-gRPC-h2 Gap-A shape has NO wire stream at all. Failing it
    would discard bytes already in hand for zero benefit, since no wait can
    occur."""
    var body = RecvRingBody[ScriptedStream].from_buffered_bytes(
        _body_bytes(24)
    )
    body.set_deadline_us(Int(_now_ns() // UInt64(1000)) - 1)
    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var f1 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(
        f1.is_data(),
        msg="a PREBUFFERED body must still emit its seeded bytes",
    )
    var f2 = body.poll_frame[PerCoreAsyncRuntime[NoopSink]](reactor, tok)
    assert_true(f2.is_end())


# =============================================================================
# Case 6 — ⭐ THE K-STREAM DRAIN. The path `collect_body` never touches.
# =============================================================================


def test_one_stalled_stream_among_k_still_hits_its_own_deadline() raises:
    """`drain_bodies_round_robin` — the objectstore / parquet prefetch drain,
    reached through `finish_into_response`, which calls `collect_body` NEVER.

    Its own fallback cap is `1_000_000 * k`, i.e. it gets LOOSER as K grows,
    and its `made_progress` flag is computed across ALL K streams — so one
    healthy stream among K resets the sweep counter and keeps a silent stream
    alive forever. A sweep-level deadline would have to reason about that.

    ⭐ PER-BODY DEADLINES MAKE THE PROBLEM DISSOLVE: the silent stream raises
    on its OWN `poll_frame`, regardless of what the other K-1 are doing. That
    is strictly better than one shared sweep budget and it falls out of the
    design for free — which is also why the `made_progress`-across-all-K reset
    is NOT touched by this change."""
    var bodies = Slab[RecvRingBody[ScriptedStream]]()
    var now_us = Int(_now_ns() // UInt64(1000))
    var i = 0
    while i < 3:
        # Three healthy streams: fully pre-seeded, complete on first poll.
        var healthy_stream = ScriptedStream.from_read_script(List[UInt8]())
        bodies.append(
            RecvRingBody[ScriptedStream].new_content_length(
                healthy_stream^, 32, _body_bytes(32),
            )
        )
        i = i + 1
    # The fourth: a peer that announced 4096 bytes and sends nothing.
    var silent_stream = ScriptedStream.from_read_script(List[UInt8]())
    silent_stream.set_pending_after_script(_STALL_PENDING_READS)
    bodies.append(
        RecvRingBody[ScriptedStream].new_content_length(
            silent_stream^, 4096, List[UInt8](),
        )
    )
    # Stamp every body, exactly as `finish_into_response` does.
    var s = 0
    while s < 4:
        bodies[s].set_deadline_us(now_us + _BUDGET_US)
        s = s + 1

    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var raised = False
    var detail = String()
    var start_us = Int(_now_ns() // UInt64(1000))
    try:
        var _out = drain_bodies_round_robin[
            PerCoreAsyncRuntime[NoopSink], ScriptedStream,
        ](bodies, reactor, tok)
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = Int(_now_ns() // UInt64(1000)) - start_us
    _report(String("k-stream"), elapsed_us, _STALL_PENDING_READS)

    assert_true(
        raised,
        msg="a silent stream among K must not be kept alive by its peers",
    )
    assert_true(
        detail.find(String("TIMEOUT")) >= 0
        and detail.find(_PHASE_WORD) >= 0,
        msg=(
            "the K-stream drain must fail on the stalled body's OWN deadline;"
            " got: " + detail
        ),
    )
    assert_true(
        elapsed_us < _CEILING_US,
        msg="K-stream deadline must fire promptly; elapsed_us="
        + String(elapsed_us),
    )


# =============================================================================
# Case 7 — THE CONNECTION MUST NOT BE POOLED.
# =============================================================================


def test_timed_out_body_refuses_to_surrender_its_stream() raises:
    """A SEPARATE defect from the deadline, tested separately (reqwest does
    the same with `timeout_closes_connection`).

    An HTTP/1.1 connection whose body drain was ABANDONED sits at an UNKNOWN
    BYTE OFFSET. Returning it to the keepalive cache makes the NEXT request on
    it parse the previous response's leftover bytes as its own status line:
    one slow request converted into SILENT CROSS-REQUEST CORRUPTION for every
    later user of that connection — strictly worse than the hang it replaced.
    Go makes the bad reuse structurally impossible (`alive = alive && bodyEOF
    && ...` in `tryPutIdleConn`); ours is guarded by `take_stream`'s `_done`
    precondition, and until now that was an invariant nobody had asserted."""
    var stream = ScriptedStream.from_read_script(List[UInt8]())
    stream.set_pending_after_script(_STALL_PENDING_READS)
    var body = RecvRingBody[ScriptedStream].new_content_length(
        stream^, 4096, List[UInt8](),
    )
    body.set_deadline_us(Int(_now_ns() // UInt64(1000)) - 1)

    var reactor = _make_reactor()
    var tok = CancellationToken.never()
    var drained = False
    try:
        var _bytes = collect_body[
            PerCoreAsyncRuntime[NoopSink], ScriptedStream,
        ](body, reactor, tok)
        drained = True
    except e:
        _ = e
    assert_false(drained, msg="the drain must have raised")

    # The stream is STILL OWNED by the body (it was never handed back)...
    assert_true(
        body.has_stream(),
        msg="a timed-out body must still own its stream",
    )
    # ...and it REFUSES to give it up, because `_done` is False.
    assert_false(
        body.is_done(),
        msg="a timed-out body is not done",
    )
    var surrendered = False
    try:
        var _s = body.take_stream()
        surrendered = True
    except e:
        _ = e
    assert_false(
        surrendered,
        msg=(
            "take_stream must REFUSE a body whose drain was abandoned — a"
            " stream at an unknown byte offset must never reach the keepalive"
            " cache"
        ),
    )


# =============================================================================
# Case 9 — ⭐ THE STEPPER STAMP. The one genuinely new piece of plumbing.
# =============================================================================


def _stepper_scratch() -> List[UInt8]:
    var out = List[UInt8]()
    var i = 0
    while i < 4096:
        out.append(UInt8(0))
        i = i + 1
    return out^


def test_the_nonblocking_stepper_stamps_the_body_it_builds() raises:
    """`begin_send_head_nonblocking` -> `step_send_head_nonblocking` ->
    `finish_into_response` must produce a body carrying the DRIVER's deadline.

    ⚠ NOTE WHAT IS DELIBERATELY *NOT* CONFIGURED HERE: no
    `set_request_timeout_us`. That mirrors `issue_streaming_get_nonblocking`
    exactly — the issue path does not set one — so this asserts the case
    that actually ships: an unconfigured driver still arms the GENEROUS
    DEFAULT, and the body it builds still carries a FINITE bound. Before this
    change the same path produced a body bounded by nothing at all, and its
    drain (`drain_bodies_round_robin`) got LOOSER as K grew.

    The deadline must also be the DRIVER's own — equality, not merely
    non-zero. A body stamped from some other clock read would still be
    bounded, but it would not be the ONE budget spanning head and body, which
    is the composition property the whole design rests on."""
    var req_bytes = List[UInt8]()
    _append_str(req_bytes, String("GET /blob HTTP/1.1\r\nHost: h\r\n\r\n"))
    var script = _concat(_head_with_content_length(2), _body_bytes(2))
    var stream = ScriptedStream.from_read_script(script^)

    var driver = OutboundDriver.new(req_bytes^)
    driver.begin_send_head_nonblocking()
    assert_true(
        driver.deadline_us() > 0,
        msg="begin_send_head_nonblocking must ARM the request deadline",
    )
    var armed = driver.deadline_us()

    var reactor = _make_reactor()
    var scratch = _stepper_scratch()
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
    # Stepping must NOT re-arm — one budget for the whole request, never a
    # fresh one per step (which would be no bound at all).
    assert_equal(
        driver.deadline_us(),
        armed,
        msg="the deadline must be armed ONCE, never re-armed while stepping",
    )

    var resp = driver.finish_into_response[ScriptedStream](stream^)
    assert_equal(Int(resp.status), 200)
    assert_equal(
        resp.body.deadline_us(),
        armed,
        msg=(
            "finish_into_response must stamp the DRIVER's deadline onto the"
            " body it builds — this is the line that bounds the parquet"
            " K-stream drain"
        ),
    )


def main() raises:
    # STALL first, DRIBBLE second -- deliberately. A neutered run aborts at
    # the first failure, so this order is what let both reds be recorded in
    # two runs rather than four.
    test_stalled_body_is_bounded_by_the_response_body_deadline()
    test_dribbling_body_cannot_defeat_the_response_body_deadline()
    test_slow_but_complete_body_is_not_killed()
    test_expired_deadline_fires_on_first_poll_even_with_bytes_ready()
    test_deadline_only_ever_tightens()
    test_absurd_budget_does_not_wrap_into_the_past()
    test_a_finished_body_still_returns_end_after_its_deadline()
    test_an_empty_body_still_returns_end_after_its_deadline()
    test_a_prebuffered_body_still_emits_after_its_deadline()
    test_one_stalled_stream_among_k_still_hits_its_own_deadline()
    test_timed_out_body_refuses_to_surrender_its_stream()
    test_the_nonblocking_stepper_stamps_the_body_it_builds()
    print("test_body_drain_deadline_survives_byte_dribble: OK")
