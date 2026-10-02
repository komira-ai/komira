# =============================================================================
# komira_http/tests/test_body_drain_deadline.mojo
#   THE REQUEST'S WALL-CLOCK BUDGET MUST BOUND THE BODY DRAIN, NOT ONLY THE
#   HEAD.
# =============================================================================
#
# ⭐ THE FAILURE THIS GUARDS AGAINST.
#
#     HttpError[EOF_MID_RESPONSE: chunked body unterminated]
#
# raised by `RecvRingBody._finalize_on_eof` (`client/response_body.mojo`, the
# `_BODY_FRAMING_CHUNKED` arm). ⚠ THAT ERROR IS THE *SYMPTOM*, AND IT FIRES
# PROMPTLY — the instant EOF arrives. Minutes can pass BEFORE it — up to a
# platform's 504 at its request ceiling — waiting for that EOF in a body drain
# with no wall-clock bound.
#
# An ITERATION COUNT IS NOT A DEADLINE. A drain bounded only by
#
#     max_iter = 1_000_000
#     _COLLECT_BODY_SPIN_BUDGET     = 4       spins before a park
#     _COLLECT_BODY_PARK_TIMEOUT_US = 50_000  50 ms per park
#
# has, on a real socket where a park actually parks, the implied worst case
#
#     (1_000_000 / 4) parks x 50 ms = 12_500 s ~ 3.5 HOURS
#
# for ONE response body — against a configured budget the caller may have set to
# 8 s. `test_wall_bound_implied_by_the_modules_own_constants` below asserts that
# arithmetic so it cannot drift silently.
#
# ⚠ AND A `TimeoutLayer` THAT ONLY SAMPLES THE CLOCK at layer entry and exit
# does not BOUND a 300 s call — it LABELS it, 300 s later. (Its own falsifier
# is the sibling file `test_timeout_layer_bounds_wall_time.mojo`.)
#
# ── WHAT IS COVERED ELSEWHERE, SO THIS FILE DOES NOT DUPLICATE IT ───────────
#
#   * `test_head_drive_deadline_survives_byte_dribble.mojo` — the HEAD loop's
#     deadline survives a dribbling peer: "A deadline the peer can defeat by
#     dribbling is not a deadline." The head loop ends at
#     `OUTBOUND_STATE_DONE` — reached the moment the HEAD is parsed — and the
#     body drain that runs after it is a different function in a different
#     file, which is why the rule needs its own test here.
#   * `test_client_send_buffered_honors_request_timeout.mojo` — `send_buffered`
#     FORWARDS the configured budget (the dropped-argument defect). It proves
#     the driver holds the right number. This file is about the phase that
#     must look at that number too.
#   * `test_outbound_budget_rule.mojo` — the clamp ARITHMETIC, as pure
#     functions. `test_derived_context_budget_is_the_budget_enforced` below
#     drives a clamped value through a drive loop.
#
# ── THE ANTI-VACUITY NEGATIVE CONTROL ───────────────────────────────────────
#
#   `test_slow_but_progressing_body_under_the_same_budget_succeeds` is NOT
#   optional. The obvious "fix" for a body that never ends — abandon the drain
#   on any stall — trades a hang for DATA LOSS and would satisfy every other
#   test here. This test is what makes that fix RED.
#
# ⛔ DO NOT "FIX" A RED HERE BY DELETING THE ASSERTION. The deadline threaded
# into the body drain IS the subject.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http.client.client import (
    HttpClient,
    HttpClientConfig,
    build_get_request,
)
from komira_http.client.header_map import HeaderMap
from komira_http.client.pool import PoolKey
from komira_http.client.response_body import (
    _COLLECT_BODY_PARK_TIMEOUT_US,
    _COLLECT_BODY_SPIN_BUDGET,
    RecvRingBody,
    collect_body,
)
from komira_http.client.url import Url
from komira_http.transport.scripted import ScriptedConnector, ScriptedStream
from komira_clock import now_ns as _now_ns


# =============================================================================
# Constants. Every one is DERIVED from something; none is a preference.
# =============================================================================

comptime _BUDGET_US: Int = 150_000
"""The configured request budget (150 ms) — the same shape both sibling
deadline regressions use, small enough that a PASS is unambiguous."""

comptime _CEILING_US: Int = 10_000_000
"""The elapsed ceiling (10 s). Generously above the 150 ms budget plus one
50 ms park interval, and far below both the 600 s driver default and the
~3.5 h the iteration cap implies on a real socket."""

comptime _DRAIN_MAX_ITER: Int = 1_000_000
"""`max_iter` in BOTH `collect_body` and (scaled by K) in
`drain_bodies_round_robin`. Restated here because it is module-private; the
arithmetic test below is what keeps the restatement honest."""

comptime _STALL_PENDING_COUNT: Int = 50_000_000
"""Queued read-Pendings for the "server accepted the connection and never
answered" double — the same count the `send_buffered` sibling uses. Far above
any loop bound in the tree, so the stream never produces a byte and never EOFs:
the peer is STUCK, not GONE. The difference matters — a peer that closes SHOULD
report EOF_MID_RESPONSE; a peer that stalls should report a deadline."""

comptime _TINY_SCRATCH: Int = 64
"""Per-poll scratch for the DIRECT `collect_body` test only.

⚠ NOT COSMETIC. `RecvRingBody.poll_frame` builds a fresh scratch List and
appends `_scratch_size` zero bytes into it ON EVERY POLL — 65_536 of them at the
64 KiB default. At the default, spinning out the 1_000_000-iteration cap is
~65e9 appends and takes minutes, which would make this file's runtime a worse
problem than the bug. Shrinking the scratch changes the COST of a poll and
nothing about the control flow under test."""

comptime _DRIBBLE_CHUNKS: Int = 30_000
"""Body chunks in the never-terminated dribble script.

⚠ THIS NUMBER IS A MARGIN AGAINST A BOUND. Below 1.0x of that bound THE
FIXTURE IS VACUOUS: the script runs out BEFORE the bound it is measured against
expires, so the peer stops reading as STALLED and starts reading as GONE. Case
4 below then gets `EOF_MID_RESPONSE` — the right answer to the question the
fixture would actually be asking — and fails on fast machines while passing on
slow ones. The ASSERTION is right; such a FIXTURE never creates the state.

THE DERIVATION (re-measure it; do not trust these numbers).

  THE BOUND TO OUTLAST is the LARGER of the two this one script is driven
  against — 400 ms, `response_body.mojo`'s `_UNSTAMPED_DRAIN_BACKSTOP_US`
  (8 x `_COLLECT_BODY_PARK_TIMEOUT_US`), which is what stops case 4's
  HAND-BUILT, therefore UNSTAMPED, body. Case 3's driver-stamped `_BUDGET_US`
  is 150 ms and is the slacker constraint.

  THE COST OF A POLL at the 64 KiB default scratch — `poll_frame` builds a
  fresh scratch List and appends `_scratch_size` zero bytes into it EVERY
  poll — measured by instrumenting case 4:

      fast machine   2200 chunks x 6 polls = 13_200 polls in 314_207 us
                     => 23.80 us/poll => 400 ms needs 2801 CHUNKS.
                     2200 would be 0.79x — vacuous.
      slow machine   the same drain is CUT by the backstop at ~400 ms, i.e.
                     it never reaches the end of the same script. The split
                     is machine speed, not an optname.

  THE MARGIN: 10x the fastest box measured (2801 -> 28_010, rounded to 30_000).

⭐ THE SURPLUS IS FREE WHEN THE BOUND WORKS. The drain stops AT the bound and
never reads the tail, so on a green run these chunks cost one 180 KB List build
and nothing else — the healthy runtime IS THE BOUND, 400 ms, at 2200 chunks and
at 30_000 alike. The full 4.3 s is paid only by a build in which the bound has
been REMOVED, which is precisely the mutation this case exists to red, and it
stays observably RED rather than hanging. That is why the script is still
FINITE.

Each chunk is the 6 bytes `1\\r\\nA\\r\\n`; the `0\\r\\n\\r\\n`
terminator is deliberately NEVER written."""


# =============================================================================
# Helpers — the shapes the neighbouring tests use.
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


def _chunked_head() -> List[UInt8]:
    """A COMPLETE, well-formed chunked response head. Complete on purpose: this
    file is about the phase AFTER the head, and a head that is still arriving
    would make the head loop's (working) deadline the thing under test."""
    var out = List[UInt8]()
    _append_str(
        out,
        String("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"),
    )
    return out^


def _never_terminated_chunked_body(n_chunks: Int) -> List[UInt8]:
    """`n_chunks` well-formed 1-byte chunks and NEVER the terminating
    `0\\r\\n\\r\\n`. Every prefix of this is a valid, incomplete chunked body,
    so the decoder keeps asking for more — exactly what a stalled peer does."""
    var out = List[UInt8]()
    var i = 0
    while i < n_chunks:
        _append_str(out, String("1\r\nA\r\n"))
        i = i + 1
    return out^


def _complete_small_chunked_body() -> List[UInt8]:
    """Three 1-byte chunks `0`,`1`,`2` and the terminator. The payload is the
    3 bytes `012` — the same assertion reqwest's
    `read_timeout_allows_slow_response_body` makes."""
    var out = List[UInt8]()
    _append_str(out, String("1\r\n0\r\n"))
    _append_str(out, String("1\r\n1\r\n"))
    _append_str(out, String("1\r\n2\r\n"))
    _append_str(out, String("0\r\n\r\n"))
    return out^


def _concat(var a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a^
    var i = 0
    var n = b.__len__()
    while i < n:
        out.append(b[i])
        i = i + 1
    return out^


def _get_request() raises -> Url:
    return Url.parse(String("http://127.0.0.1:8080/health"))


# =============================================================================
# 1 — the bound on the body drain is an ITERATION COUNT. (EXPECT RED)
# =============================================================================


def test_collect_body_bound_is_an_iteration_count_not_a_deadline() raises:
    """A stalled peer must end the body drain via a WALL-CLOCK DEADLINE.

    This drives `collect_body` directly — no head, no client — so nothing but
    the body drain is under test. The stream is the canonical stuck-peer double
    (`queue_read_pending` above every loop bound in the tree): `try_read`
    returns Pending forever, never a byte and never an EOF.

    WITHOUT A WALL-CLOCK BOUND THE RESULT IS:

        HttpError[TIMEOUT]: collect_body iteration cap exceeded

    ⚠ READ WHY THAT STRING IS A FAILURE AND NOT A PASS. It is spelled `TIMEOUT`,
    so a laxer assertion — `"TIMEOUT" in detail`, which is what a reader reaches
    for first — goes GREEN on it and certifies the exact defect. The word is a LABEL on an iteration count. What ended the loop was
    1_000_000 polls, a quantity with no unit of time in it: on this fixture
    (fd = -1, so `park_on_fds` returns immediately and a park is free) that is
    under a second, and on a real socket where each park costs its full 50 ms it
    is ~3.5 hours. Same code, same constant, two answers four orders of
    magnitude apart — which is precisely what "not a deadline" means.

    So the assertions below are the narrow ones: the failure must NOT be
    attributable to an iteration count, and it MUST be attributable to a
    configured wall-clock budget."""
    var stream = ScriptedStream.empty()
    stream.queue_read_pending(_STALL_PENDING_COUNT)
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, List[UInt8](), 100 * 1024 * 1024,
    )
    body.set_scratch_size(_TINY_SCRATCH)

    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var raised = False
    var detail = String()
    var start_us = Int(_now_ns() // UInt64(1000))
    try:
        var _bytes = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
            body, reactor, tok,
        )
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = Int(_now_ns() // UInt64(1000)) - start_us

    assert_true(raised, msg="a stalled body must raise, not return")
    # ★ THE HEADLINE ASSERTION. RED today: the message is literally
    # "collect_body iteration cap exceeded".
    assert_false(
        "iteration cap" in detail,
        msg=(
            "the body drain ended on an ITERATION COUNT, not a clock — an"
            " iteration cap is not a deadline (on a real socket the same"
            " 1_000_000 iterations are ~3.5 h of 50 ms parks). got: "
            + detail
            + " (elapsed_us="
            + String(elapsed_us)
            + ")"
        ),
    )
    # ★ AND THE POSITIVE HALF: it must name a deadline, the way the head loop's
    # `_check_deadline` does ("request deadline exceeded while driving ...").
    assert_true(
        "deadline" in detail,
        msg=(
            "a stalled body drain must fail via a configured wall-clock"
            " deadline; got: "
            + detail
        ),
    )


# =============================================================================
# 2 — the ARITHMETIC. What wall time does the module's own bound imply?
# =============================================================================


def test_wall_bound_implied_by_the_modules_own_constants() raises:
    """The iteration cap, read together with the park interval, implies a
    worst-case wall time for ONE body. Assert it, so the "3.5 hours" in this
    file's header is a MEASUREMENT and not a remembered number — and so a future
    edit that changes either constant has to confront what it means in seconds.

    This test PASSES today, and it is the one that quantifies why the three REDs
    matter. It is deliberately independent of any fixture: it is arithmetic over
    two exported constants, so it cannot be made green by a faster machine."""
    assert_true(
        _COLLECT_BODY_SPIN_BUDGET > 0,
        msg="spin budget must be positive or the parks-per-iteration is 0/0",
    )
    assert_true(
        Int(_COLLECT_BODY_PARK_TIMEOUT_US) > 0,
        msg="a zero park timeout would make the drain a pure busy-spin",
    )
    var parks = _DRAIN_MAX_ITER // _COLLECT_BODY_SPIN_BUDGET
    var implied_wall_us = parks * Int(_COLLECT_BODY_PARK_TIMEOUT_US)
    var implied_wall_s = implied_wall_us // 1_000_000
    # 12_500 s at the constants as written. The assertion is not that it equals
    # 12_500 — it is that the implied bound is ABSURD as a request bound, which
    # stays true under any reasonable re-tuning of either constant.
    assert_true(
        implied_wall_s > 600,
        msg=(
            "the implied worst-case body-drain wall is "
            + String(implied_wall_s)
            + " s, which is no longer absurd — if the constants were retuned"
            " deliberately, retune this assertion with them; if a real"
            " deadline landed, this test should be replaced by one that"
            " asserts the deadline"
        ),
    )
    # ⚠ AND THE COMPARISON THAT MAKES IT A FINDING: the implied bound exceeds
    # even the drive loop's own generous 600 s default, and by two orders of
    # magnitude exceeds the 300 s Cloud Run request ceiling the whole
    # `outbound_budget.mojo` clamp exists to respect. A budget the body phase
    # can exceed by 40x is not a budget.
    assert_true(
        implied_wall_us > 300_000_000,
        msg=(
            "expected the implied body-drain wall ("
            + String(implied_wall_s)
            + " s) to exceed the 300 s Cloud Run request ceiling"
        ),
    )


# =============================================================================
# 3 — end to end: the request budget must bound the BODY phase. (EXPECT RED)
# =============================================================================


def test_request_budget_bounds_the_body_phase_not_only_the_head() raises:
    """A configured 150 ms request budget must bound the WHOLE request, and the
    body drain is part of the request.

    THE FIXTURE IS THE INCIDENT. A complete, well-formed chunked head arrives
    (so the head loop — which DOES have a working deadline — finishes normally
    and hands off at `OUTBOUND_STATE_DONE`), and then the peer dribbles body
    bytes it never terminates. From that hand-off onward not one line of code
    between here and the wire consults a clock.

    ⚠ THE HEAD IS SERVED AT FULL SPEED AND THE BODY ONE BYTE AT A TIME, AND THAT
    ASYMMETRY IS LOAD-BEARING. `set_max_read_per_call(1)` applies to the whole
    stream, so the head is dribbled too — but the head is 47 bytes, i.e. 47
    iterations of a loop that costs microseconds, against a 150 ms budget three
    orders of magnitude larger. The body is ~180 KB at ~65_536 scratch appends
    per poll. There is therefore no ambiguity about WHICH phase burned the
    budget: if this ever fails during the head, it fails on the `elapsed >=
    _BUDGET_US` floor rather than passing for the wrong reason.

    WITHOUT THE BOUND: `HttpError[EOF_MID_RESPONSE: chunked body
    unterminated]`, arriving only when
    the finite dribble script runs out, one to several seconds in. A live peer
    holding the socket open supplies the dribble indefinitely and the request
    then runs to the platform's request ceiling. The finite script
    is what makes the bug observable in bounded time; the error CLASS is the
    assertion."""
    var script = _concat(
        _chunked_head(), _never_terminated_chunked_body(_DRIBBLE_CHUNKS),
    )
    var stream = ScriptedStream.from_read_script(script^)
    # THE DRIBBLE. One byte per read is the minimum that still counts as
    # progress — the same device the head-phase sibling uses.
    stream.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    var reactor = _make_reactor()

    var url = _get_request()
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

    assert_true(raised, msg="a stalled body must raise, not return")
    # ★ THE CLASS ASSERTION — catches the budget never being consulted in the
    # body phase: EOF_MID_RESPONSE.
    assert_true(
        "deadline exceeded" in detail,
        msg=(
            "the configured "
            + String(_BUDGET_US)
            + " us budget did not bound the BODY phase; the request ran to the"
            " end of the peer's dribble and reported: "
            + detail
            + " (elapsed_us="
            + String(elapsed_us)
            + "). The EOF_MID_RESPONSE fires promptly once EOF arrives; the"
            " time was spent waiting for it."
        ),
    )
    # ★ THE ELAPSED ASSERTION — catches a deadline that is consulted but wrong.
    assert_true(
        elapsed_us < _CEILING_US,
        msg=(
            "the body phase ran "
            + String(elapsed_us)
            + " us under a "
            + String(_BUDGET_US)
            + " us budget"
        ),
    )
    # And it must not fire EARLY — a body drain abandoned before its budget is
    # data loss, not a fix. The negative control below is the other half of this.
    assert_true(
        elapsed_us >= _BUDGET_US,
        msg="deadline fired before its budget: " + String(elapsed_us) + " us",
    )


# =============================================================================
# 4 — the body-phase twin of the head dribble regression. (EXPECT RED)
# =============================================================================


def test_body_dribble_cannot_defeat_the_request_deadline() raises:
    """`state_machine.mojo:732` records the rule this asserts, verbatim:

        "A deadline the peer can defeat by dribbling is not a deadline."

    ⛔ IT WAS NEVER CARRIED TO THE BODY PATH, AND THE BODY PATH IS WORSE. In the
    head loop the defect was a deadline check REACHABLE only through a
    counter-gated branch the dribble kept resetting; `collect_body`'s equivalent
    branch (`pending_run >= _COLLECT_BODY_SPIN_BUDGET`) is reset by every Data
    frame in the same way — but there is no deadline check behind it to reach.
    There is no clock in the file at all.

    THE DIFFERENCE FROM THE TEST ABOVE, so neither is redundant: that one drives
    the whole client and asserts the REQUEST budget; this one drives
    `collect_body` directly with a peer that is DELIVERING PAYLOAD the entire
    time — the case a "no progress" heuristic cannot catch, because there is
    progress on every single poll. Only a clock catches it.

    Without a clock anywhere in the body path the result is `EOF_MID_RESPONSE:
    chunked body unterminated`, when the dribble runs out. This body is
    HAND-BUILT and therefore carries no stamp, so what must stop it is
    `_UNSTAMPED_DRAIN_BACKSTOP_US` (400 ms). ⚠ `EOF_MID_RESPONSE` is now a VACUOUS-FIXTURE
    signal rather than the contract failure — see the guard below."""
    var stream = ScriptedStream.from_read_script(
        _never_terminated_chunked_body(_DRIBBLE_CHUNKS)
    )
    stream.set_max_read_per_call(1)
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, List[UInt8](), 100 * 1024 * 1024,
    )
    var reactor = _make_reactor()
    var tok = CancellationToken.never()

    var raised = False
    var detail = String()
    try:
        var _bytes = collect_body[PerCoreAsyncRuntime[NoopSink], ScriptedStream](
            body, reactor, tok,
        )
    except e:
        raised = True
        detail = String(e)

    assert_true(raised, msg="an unterminated dribbled body must raise")
    # ★ THE ANTI-VACUITY GUARD ON THE FIXTURE ITSELF. The dribble
    # script is FINITE, so on a box fast enough to drain all of it inside
    # `_UNSTAMPED_DRAIN_BACKSTOP_US` the peer stops being a STALLED peer and
    # becomes a peer that CLOSED — and `EOF_MID_RESPONSE` is then the CORRECT
    # answer to a question this case is not asking. That is not a contract
    # failure, it is a fixture that never created the asserted state, and it
    # went unnoticed once already (see `_DRIBBLE_CHUNKS`). Name it separately
    # so the next occurrence reads as what it is.
    assert_false(
        "EOF_MID_RESPONSE" in detail,
        msg=(
            "VACUOUS FIXTURE, not a contract failure: the finite dribble"
            " script ran out before the drain's bound expired, so this box"
            " measured a peer that CLOSED instead of one that is still"
            " dribbling. RAISE `_DRIBBLE_CHUNKS` — re-derive it from the"
            " per-poll cost on this box, as its docstring does. got: "
            + detail
        ),
    )
    assert_true(
        "deadline" in detail,
        msg=(
            "a peer dribbling body bytes it never terminates defeated the"
            " drain's bound entirely — there is no clock in the body path to"
            " defeat. got: "
            + detail
        ),
    )


# =============================================================================
# 5 — ⭐ THE ANTI-VACUITY NEGATIVE CONTROL. Mandatory; nothing in the tree
#     had one.
# =============================================================================


def test_slow_but_progressing_body_under_the_same_budget_succeeds() raises:
    """A healthy peer that is SLOW but PROGRESSING must return its WHOLE body
    under the SAME budget the stalled peer fails under, and must not consume
    that budget.

    ⛔ WHY THIS TEST IS NOT OPTIONAL. The obvious fix for every RED in this file
    — abandon the drain when the peer stalls, or bound it by a per-poll idle
    timer — makes all three green while TRADING A HANG FOR DATA LOSS. That is a
    strictly worse defect than the one being fixed: a hang is loud and a
    truncated body is silent. This test is the only thing in the file that goes
    RED on that fix, and there was no test of this shape anywhere in
    `komira_http`.

    Modelled on reqwest's `read_timeout_allows_slow_response_body`, which
    asserts `body == "012"` for three chunks 100 ms apart under a 200 ms read
    timeout: the assertion is on the BYTES, not merely on "it did not raise".

    THE FIXTURE: a peer slower than any healthy one in the suite — it stalls for
    several polls before answering at all, then hands over ONE BYTE PER READ for
    the entire head and body — but it finishes, well inside the budget. A
    correct implementation returns 200 and the three payload bytes `012`."""
    var script = _concat(_chunked_head(), _complete_small_chunked_body())
    var stream = ScriptedStream.from_read_script(script^)
    # SLOW ON BOTH AXES: a stall before the first byte, then one byte per read.
    stream.queue_read_pending(8)
    stream.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    var reactor = _make_reactor()

    var url = _get_request()
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var start_us = Int(_now_ns() // UInt64(1000))
    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    var elapsed_us = Int(_now_ns() // UInt64(1000)) - start_us

    assert_equal(Int(resp.status), 200)
    # ★ THE BYTES. "did not raise" is not the assertion — a drain that returns a
    # TRUNCATED body raises nothing at all, and that is the exact failure mode a
    # careless deadline introduces.
    var got = resp.body.take_bytes()
    assert_equal(
        got.__len__(),
        3,
        msg=(
            "slow-but-progressing peer lost body bytes: expected 3, got "
            + String(got.__len__())
        ),
    )
    assert_equal(Int(got[0]), Int(UInt8(ord("0"))))
    assert_equal(Int(got[1]), Int(UInt8(ord("1"))))
    assert_equal(Int(got[2]), Int(UInt8(ord("2"))))
    # ★ AND IT MUST NOT HAVE SPENT THE BUDGET. A "fix" that always waits out the
    # full deadline before returning a completed body would satisfy every
    # assertion above while making every healthy request 150 ms slower.
    assert_true(
        elapsed_us < _BUDGET_US,
        msg=(
            "a healthy slow peer consumed the whole "
            + String(_BUDGET_US)
            + " us budget (elapsed "
            + String(elapsed_us)
            + " us) — a completed body must return when it completes"
        ),
    )


# =============================================================================
# 6 — a failed body drain must DESTROY its connection, not pool it.
# =============================================================================


def test_a_failed_body_drain_does_not_poison_the_connection_pool() raises:
    """A request that fails mid-BODY must not leave its connection cached.

    Go carries two dedicated tests for exactly this (issue 23399, `net/http`
    `TestTransportTimeoutServerHangs` and its body twin): a connection whose
    response was abandoned part-way holds UNCONSUMED BYTES, so handing it to the
    next caller feeds them the tail of somebody else's response. It is a poison
    pill that fails a DIFFERENT request than the one that went wrong, which is
    why it is so expensive to diagnose.

    ⚠ THE HEAD HALF OF THIS IS ALREADY COVERED — `test_client_send_buffered_
    honors_request_timeout.mojo` asserts `h1_idle_conn_is_cached() == False`
    after a mid-HEAD timeout. The BODY half was not, and the body half is the
    one with bytes still on the wire: a mid-head failure has nothing buffered to
    leak, while a mid-body failure has, by construction, a partially-drained
    response.

    This asserts the invariant over whatever failure the body phase currently
    produces, so it is meaningful before the deadline lands and stays meaningful
    after.

    ★ IT IS TWO-SIDED, AND THAT IS NOT DECORATION. `assert_false(is_cached())`
    on its own is satisfied by an accessor that returns False unconditionally,
    by a pool that never caches anything, and by a request that never ran — none
    of which is the property under test. So the fixture SEEDS the stuck
    connection into the idle cache and asserts `is_cached() == True` BEFORE the
    request, which is the positive control: the accessor is shown saying True
    about this exact key moments before it is required to say False.

    ⚠ IT ALSO PUTS THE TEST ON THE CACHED ARM DELIBERATELY. The dial arm ends
    with the connection dropping on the floor whether or not anything is
    correct; the CACHED arm is the one with a connection already in the pool
    that must be EVICTED rather than left behind, and it is the steady state for
    every keepalive caller."""
    var script = _concat(
        _chunked_head(), _never_terminated_chunked_body(64),
    )
    var stuck = ScriptedStream.from_read_script(script^)

    # THE DIAL TRIPWIRE (the sibling regression's device): an empty stream EOFs
    # on its first read, which is NOT a body-phase failure. If the cache lookup
    # ever misses and this request DIALS, the precondition below has already
    # failed and the test cannot pass for the wrong reason.
    var dial_tripwire = ScriptedStream.empty()
    var connector = ScriptedConnector.with_stream(dial_tripwire^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    client._stash_h1_idle_stream(
        stuck^, PoolKey.http(String("127.0.0.1"), UInt16(8080)),
    )
    # ★ THE POSITIVE CONTROL. Without this the `assert_false` below is satisfied
    # by an accessor that can only ever say False.
    assert_true(
        client.h1_idle_conn_is_cached(),
        msg="fixture precondition: the conn must be cached before the request",
    )

    var reactor = _make_reactor()
    var url = _get_request()
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var raised = False
    var detail = String()
    try:
        var _resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
    except e:
        raised = True
        detail = String(e)

    assert_true(
        raised,
        msg="fixture precondition: an unterminated body must fail the request",
    )
    # ★ PROVES WHICH ARM RAN. A nonzero dial count means the cache missed and
    # this measured the dial arm, i.e. proved nothing about eviction.
    assert_equal(
        client._connector.connect_call_count(),
        0,
        msg=(
            "expected the CACHED arm (zero dials); the idle-conn cache missed"
            " so this test measured the dial arm and proved nothing about"
            " evicting a failed connection"
        ),
    )
    # ★ THE INVARIANT. A conn whose response was abandoned mid-body has
    # unconsumed bytes; leaving it pooled hands the NEXT caller the tail of
    # this response.
    assert_false(
        client.h1_idle_conn_is_cached(),
        msg=(
            "a connection whose body drain failed was left in the idle cache —"
            " the next same-origin request will read the tail of this"
            " response. failure was: "
            + detail
        ),
    )


# =============================================================================
# 7 — fast / slow / fast: a fired failure must leave the client USABLE.
# =============================================================================


def test_client_stays_usable_after_a_body_phase_failure() raises:
    """Three requests on ONE client: healthy, then a stalled body, then healthy.

    A body-phase failure that poisons the client's own state would pass every
    other test in this file — each of them builds a fresh client — and would
    then break the first caller unlucky enough to come after a timeout. At the
    service level the FIRST failure is cheap; what makes the service
    unavailable is every subsequent request inheriting the damage.

    Each response carries `Connection: close`, so each request dials its own
    scripted stream (`arm_next` queues them oldest-first) and the assertion is
    about the CLIENT's state, not about pool reuse."""
    var close_head = List[UInt8]()
    _append_str(
        close_head,
        String(
            "HTTP/1.1 200 OK\r\nConnection: close\r\n"
            "Transfer-Encoding: chunked\r\n\r\n"
        ),
    )
    var stall_head = List[UInt8]()
    _append_str(
        stall_head,
        String(
            "HTTP/1.1 200 OK\r\nConnection: close\r\n"
            "Transfer-Encoding: chunked\r\n\r\n"
        ),
    )

    var ok1 = ScriptedStream.from_read_script(
        _concat(close_head.copy(), _complete_small_chunked_body())
    )
    var bad = ScriptedStream.from_read_script(
        _concat(stall_head^, _never_terminated_chunked_body(64))
    )
    var ok2 = ScriptedStream.from_read_script(
        _concat(close_head^, _complete_small_chunked_body())
    )

    var connector = ScriptedConnector.with_stream(ok1^)
    connector.arm_next(bad^)
    connector.arm_next(ok2^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    var reactor = _make_reactor()

    # --- 1: FAST. Establishes that the fixture answers at all.
    var url1 = _get_request()
    var h1 = HeaderMap()
    var r1 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        build_get_request(url1^, h1^), reactor,
    )
    assert_equal(Int(r1.status), 200)
    assert_equal(r1.body.take_bytes().__len__(), 3)

    # --- 2: SLOW. Must fail.
    var url2 = _get_request()
    var h2 = HeaderMap()
    var raised = False
    try:
        var _r2 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            build_get_request(url2^, h2^), reactor,
        )
    except e:
        raised = True
        _ = String(e)
    assert_true(
        raised,
        msg="fixture precondition: the stalled-body request must fail",
    )

    # --- 3: FAST AGAIN. ★ THE ASSERTION. A timeout that poisons the client
    # would pass every other test we have and fail exactly here.
    var url3 = _get_request()
    var h3 = HeaderMap()
    var r3 = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        build_get_request(url3^, h3^), reactor,
    )
    assert_equal(
        Int(r3.status),
        200,
        msg="the client was left unusable by the preceding body-phase failure",
    )
    var got3 = r3.body.take_bytes()
    assert_equal(
        got3.__len__(),
        3,
        msg=(
            "the request after a body-phase failure returned a short body ("
            + String(got3.__len__())
            + " bytes) — the failure leaked into the next request"
        ),
    )


# =============================================================================
# 8 — the CLAMPED budget must be the budget ENFORCED.
# =============================================================================


def test_derived_context_budget_is_the_budget_enforced() raises:
    """A budget DERIVED from the containing request's ceiling must reach the
    drive loop and bound it.

    ⚠ THIS IS THE GAP `test_outbound_budget_rule.mojo` LEAVES. Its 15 tests
    exercise `outbound_budget_us` / `largest_permissible_budget_us` /
    `serving_request_ceiling_us` as PURE FUNCTIONS — correct arithmetic, and
    nothing that carries the answer to a socket. The 600 s-inside-a-300 s-ceiling
    bug lived in the WIRING, and this is the first test that drives a derived,
    clamped value through a real drive loop.

    ⛔ THE CEILING IS SYNTHETIC ON PURPOSE, AND IT IS NOT A WEAKER TEST. The real
    Cloud Run ceiling is 300 s, whose derived budget is 295 s — unusable in a
    unit test, and a test that waited it out would be replaced by one that did
    not. `HttpClientConfig.for_serving_ceiling` exists precisely so the decision
    can be exercised without a platform: the ceiling here is 5.15 s, which drives
    the SAME subtractive arm as the real one
    (`ceiling - OUTBOUND_CEILING_RESERVE_US`, 5 s) and yields a 150 ms budget.
    The arithmetic is asserted first so a failure separates "the rule changed"
    from "the wiring dropped it"."""
    var cfg = HttpClientConfig.for_serving_ceiling(5_150_000)
    # FIXTURE PRECONDITION: the derived budget is the reserve-subtracted one.
    assert_equal(
        cfg.request_timeout_us,
        150_000,
        msg=(
            "expected a 5.15 s ceiling to derive a 150 ms budget (ceiling minus"
            " the 5 s reserve); got "
            + String(cfg.request_timeout_us)
        ),
    )
    assert_true(
        cfg.budget_was_clamped(),
        msg="a derived budget must report itself as clamped",
    )

    var stream = ScriptedStream.empty()
    stream.queue_read_pending(_STALL_PENDING_COUNT)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector](
        config=cfg, connector=connector^,
    )
    var reactor = _make_reactor()

    var url = _get_request()
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

    assert_true(raised, msg="a stuck peer must raise, not return")
    assert_true(
        "deadline exceeded" in detail,
        msg="must fail via the derived wall-clock budget; got: " + detail,
    )
    # ★ THE HEADLINE ASSERTION: the DERIVED budget, not the 600 s default, is
    # what bounded the call.
    assert_true(
        elapsed_us < _CEILING_US,
        msg=(
            "the derived 150 ms budget did not reach the drive loop: elapsed "
            + String(elapsed_us)
            + " us (the 600 s default was used)"
        ),
    )
    assert_true(
        elapsed_us >= cfg.request_timeout_us,
        msg="deadline fired before its budget: " + String(elapsed_us) + " us",
    )


# =============================================================================
# main — REPORTS EVERY CASE, THEN FAILS.
# =============================================================================
#
# ⚠ DELIBERATELY NOT THE NEIGHBOURS' STRAIGHT-LINE `main`. A Mojo test aborts on
# the first `AssertionError`, so a straight-line `main` over a file whose
# PURPOSE is to enumerate which cases are red reports exactly one of them and
# hides the rest — and the ones it hides are the anti-vacuity controls, whose
# value is entirely in being seen to PASS while the others fail.
#
# ⛔ THIS IS NOT A SOFTENED GATE. Every failure is re-raised at the bottom, so
# the target is RED whenever any case is red; the only thing that changed is
# that the log names all of them.


def _run(name: String, mut failures: List[String], passed: Bool, detail: String):
    if passed:
        print("  PASS  " + name)
    else:
        print("  FAIL  " + name + "  --  " + detail)
        failures.append(name)


def main() raises:
    var failures = List[String]()
    print("test_body_drain_deadline:")

    var ok = False
    var why = String()

    ok = False
    try:
        test_wall_bound_implied_by_the_modules_own_constants()
        ok = True
    except e:
        why = String(e)
    _run(String("wall_bound_implied_by_the_modules_own_constants"), failures, ok, why)

    ok = False
    try:
        test_slow_but_progressing_body_under_the_same_budget_succeeds()
        ok = True
    except e:
        why = String(e)
    _run(String("slow_but_progressing_body_under_the_same_budget_succeeds"), failures, ok, why)

    ok = False
    try:
        test_a_failed_body_drain_does_not_poison_the_connection_pool()
        ok = True
    except e:
        why = String(e)
    _run(String("a_failed_body_drain_does_not_poison_the_connection_pool"), failures, ok, why)

    ok = False
    try:
        test_client_stays_usable_after_a_body_phase_failure()
        ok = True
    except e:
        why = String(e)
    _run(String("client_stays_usable_after_a_body_phase_failure"), failures, ok, why)

    ok = False
    try:
        test_derived_context_budget_is_the_budget_enforced()
        ok = True
    except e:
        why = String(e)
    _run(String("derived_context_budget_is_the_budget_enforced"), failures, ok, why)

    ok = False
    try:
        test_collect_body_bound_is_an_iteration_count_not_a_deadline()
        ok = True
    except e:
        why = String(e)
    _run(String("collect_body_bound_is_an_iteration_count_not_a_deadline"), failures, ok, why)

    ok = False
    try:
        test_body_dribble_cannot_defeat_the_request_deadline()
        ok = True
    except e:
        why = String(e)
    _run(String("body_dribble_cannot_defeat_the_request_deadline"), failures, ok, why)

    ok = False
    try:
        test_request_budget_bounds_the_body_phase_not_only_the_head()
        ok = True
    except e:
        why = String(e)
    _run(String("request_budget_bounds_the_body_phase_not_only_the_head"), failures, ok, why)

    if failures.__len__() > 0:
        var names = String()
        var i = 0
        while i < failures.__len__():
            if i > 0:
                names = names + String(", ")
            names = names + failures[i]
            i = i + 1
        raise Error(
            String("test_body_drain_deadline: ")
            + String(failures.__len__())
            + String(" case(s) RED: ")
            + names
        )
    print("OK: test_body_drain_deadline")
