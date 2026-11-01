# =============================================================================
# komira_http_client/tests/test_body_drain_deadline.mojo
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

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_false, assert_true

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import (
    HttpClient,
    HttpClientConfig,
    build_get_request,
)
from komira_http_client.header_map import HeaderMap
from komira_http_client.pool import PoolKey
from komira_http_client.response_body import (
    _COLLECT_BODY_PARK_TIMEOUT_US,
    _COLLECT_BODY_SPIN_BUDGET,
    _UNSTAMPED_DRAIN_BACKSTOP_US,
    RecvRingBody,
    collect_body,
)
from komira_http_client.url import Url
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream


# =============================================================================
# Constants. Every one is DERIVED from something; none is a preference.
# =============================================================================

comptime _BUDGET_US: Int = 150_000
"""The configured request budget (150 ms) — the same shape both sibling
deadline regressions use, small enough that a PASS is unambiguous."""

comptime _CLOCK_START_US: Int = 1_000_000
"""Where the fake clock starts. Away from 0, which the driver and the body use to
mean "no deadline armed"."""

comptime _PENDING_STEP_US: Int = 10_000
"""Fake time that passes on every read where the scripted peer says nothing
(Pending). A silent peer is the only thing that moves the clock in the stalled
and slow-start cases, so their elapsed time is a function of the script."""

comptime _DATA_STEP_US: Int = 100
"""Fake time that passes on every read that delivers bytes, in the dribble
cases: a peer that keeps sending, one byte at a time, still lets time pass."""

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
"""Per-poll scratch for the DIRECT `collect_body` test only. `poll_frame` builds
a fresh scratch List of `_scratch_size` zero bytes on every poll (65_536 at the
default), so a small scratch keeps the many polls of a stalled drain cheap. It
changes the cost of a poll and nothing about the control flow under test."""

comptime _DRIBBLE_CHUNKS: Int = 1_000
"""Body chunks in the never-terminated dribble script (6 bytes each, one byte per
read, `_DATA_STEP_US` of fake time per read). 1_000 chunks are 600_000 us of
fake time: more than the 150_000 us request budget and more than the 400_000 us
unstamped-body backstop. The script therefore outlasts every bound it is driven
against by arithmetic, not by how fast the machine polls, and the peer reads as
STALLED (still dribbling), never as GONE. The `0\\r\\n\\r\\n` terminator is
deliberately never written."""


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


def _fake_clock() -> ArcPointer[Int]:
    """A shared clock cell, in microseconds, that only the scripted stream moves."""
    return ArcPointer[Int](_CLOCK_START_US)


def _get_request() raises -> Url:
    return Url.parse(String("http://127.0.0.1:8080/health"))


# =============================================================================
# 1 — the bound on the body drain is an ITERATION COUNT. (EXPECT RED)
# =============================================================================


def test_collect_body_bound_is_an_iteration_count_not_a_deadline() raises:
    """A stalled peer must end the body drain via a DEADLINE, not an iteration
    count.

    Drives `collect_body` directly with the canonical stuck-peer double
    (`queue_read_pending` above every loop bound in the tree), on the fake
    clock. An iteration cap spelled `HttpError[TIMEOUT]: collect_body iteration
    cap exceeded` is a failure, not a pass: it says TIMEOUT while measuring no
    time (the same 1_000_000 iterations are under a second on this fixture and
    ~3.5 hours on a real socket). So the assertions are narrow: the failure must
    NOT name an iteration cap, it MUST name a deadline, and it must arrive at the
    unstamped-body backstop."""
    var clock = _fake_clock()
    var stream = ScriptedStream.empty()
    stream.queue_read_pending(_STALL_PENDING_COUNT)
    stream.advance_clock_on_read(clock, _PENDING_STEP_US)
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, List[UInt8](), 100 * 1024 * 1024,
    )
    body.set_test_clock(Optional[ArcPointer[Int]](clock))
    body.set_scratch_size(_TINY_SCRATCH)

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
    # It stopped at the unstamped backstop, on the fake clock: the first
    # Pending step at or after the backstop (400_000 us is a multiple of the
    # 10_000 us step, so exactly there).
    assert_equal(
        clock[] - _CLOCK_START_US,
        _UNSTAMPED_DRAIN_BACKSTOP_US,
        msg="the stalled drain did not stop at the unstamped backstop",
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

    THE FIXTURE IS THE INCIDENT. A complete chunked head arrives (so the head
    loop, which has a working deadline, finishes and hands off), then the peer
    dribbles body bytes it never terminates. From that hand-off onward nothing
    between here and the wire consults a clock unless the body carries the
    request's deadline. Without the bound the result is `EOF_MID_RESPONSE`, when
    the finite dribble runs out; with it, a TIMEOUT at the budget. The head is 47
    bytes at 100 us per byte (4_700 us of the 150_000 us budget), so the budget
    is spent in the body."""
    var script = _concat(
        _chunked_head(), _never_terminated_chunked_body(_DRIBBLE_CHUNKS),
    )
    var clock = _fake_clock()
    var stream = ScriptedStream.from_read_script(script^)
    # THE DRIBBLE. One byte per read is the minimum that still counts as
    # progress — the same device the head-phase sibling uses. Each byte read
    # moves the fake clock by `_DATA_STEP_US`.
    stream.set_max_read_per_call(1)
    stream.advance_clock_on_read(clock, 0, _DATA_STEP_US)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    client.set_test_clock(clock)
    var reactor = _make_reactor()

    var url = _get_request()
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var raised = False
    var detail = String()
    var start_us = clock[]
    try:
        var _resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = clock[] - start_us

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
    # ★ THE ELAPSED ASSERTION, on the fake clock: the failure arrives at the
    # budget, not before (a drain abandoned early is data loss) and not after.
    # The clock moves 100 us per byte read and the deadline is checked before
    # every read, so the clock stops exactly on the budget.
    assert_equal(
        elapsed_us,
        _BUDGET_US,
        msg="the body phase must fail at its budget on the fake clock",
    )


# =============================================================================
# 4 — the body-phase twin of the head dribble regression. (EXPECT RED)
# =============================================================================


def test_body_dribble_cannot_defeat_the_request_deadline() raises:
    """"A deadline the peer can defeat by dribbling is not a deadline", carried
    to the body path.

    Drives `collect_body` directly with a peer that DELIVERS PAYLOAD on every
    poll, so a "no progress" heuristic never fires; only a clock catches it.
    This body is hand-built and carries no stamp, so what must stop it is
    `_UNSTAMPED_DRAIN_BACKSTOP_US`, measured on the fake clock."""
    var clock = _fake_clock()
    var stream = ScriptedStream.from_read_script(
        _never_terminated_chunked_body(_DRIBBLE_CHUNKS)
    )
    stream.set_max_read_per_call(1)
    stream.advance_clock_on_read(clock, 0, _DATA_STEP_US)
    var body = RecvRingBody[ScriptedStream].new_chunked(
        stream^, List[UInt8](), 100 * 1024 * 1024,
    )
    body.set_test_clock(Optional[ArcPointer[Int]](clock))
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
    # ★ THE ANTI-VACUITY GUARD ON THE FIXTURE ITSELF. The dribble script is
    # FINITE: if it ran out before the bound, the peer would read as one that
    # CLOSED and `EOF_MID_RESPONSE` would be the correct answer to a question
    # this case is not asking. `_DRIBBLE_CHUNKS` outlasts the bound in fake
    # time by arithmetic, so on any machine this must not happen.
    assert_false(
        "EOF_MID_RESPONSE" in detail,
        msg=(
            "VACUOUS FIXTURE, not a contract failure: the finite dribble"
            " script ran out before the drain's bound expired. RAISE"
            " `_DRIBBLE_CHUNKS`. got: "
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
    # The drain stopped exactly at the unstamped backstop on the fake clock:
    # 100 us per byte read, the bound checked before every read.
    assert_equal(
        clock[] - _CLOCK_START_US,
        _UNSTAMPED_DRAIN_BACKSTOP_US,
        msg="the dribbled drain must stop at the unstamped backstop",
    )


# =============================================================================
# 5 — ⭐ THE ANTI-VACUITY NEGATIVE CONTROL. Mandatory; nothing in the tree
#     had one.
# =============================================================================


def test_slow_but_progressing_body_under_the_same_budget_succeeds() raises:
    """A healthy peer that is SLOW but PROGRESSING must return its WHOLE body
    under the SAME budget the stalled peer fails under, and must not consume
    that budget.

    ⛔ NOT OPTIONAL. The obvious fix for every RED in this file (abandon the
    drain when the peer stalls) trades a hang for silent DATA LOSS and would
    pass every other test here; this test fails for that fix, because it
    asserts the bytes arrive. Modelled on
    reqwest's `read_timeout_allows_slow_response_body`: the assertion is on the
    BYTES (`012`), not merely on "it did not raise". The peer stalls for 8
    reads, then hands over one byte per read."""
    var clock = _fake_clock()
    var script = _concat(_chunked_head(), _complete_small_chunked_body())
    var stream = ScriptedStream.from_read_script(script^)
    # SLOW ON BOTH AXES: a stall before the first byte, then one byte per read.
    # The 8 silent reads cost `_PENDING_STEP_US` of fake time each, 80_000 us
    # in all; delivering bytes costs nothing.
    stream.queue_read_pending(8)
    stream.set_max_read_per_call(1)
    stream.advance_clock_on_read(clock, _PENDING_STEP_US)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    client.set_test_clock(clock)
    var reactor = _make_reactor()

    var url = _get_request()
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var start_us = clock[]
    var resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
        req^, reactor,
    )
    var elapsed_us = clock[] - start_us

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
    # ★ ON THE FAKE CLOCK THE REQUEST SPENT EXACTLY THE SILENCE THE PEER SCRIPTED
    # (8 x 10_000 us) and returned when the body completed. A "fix" that always
    # waits out the full deadline before returning a completed body would show
    # 150_000 here.
    assert_equal(
        elapsed_us,
        8 * _PENDING_STEP_US,
        msg="the request must take exactly the scripted silence, got "
        + String(elapsed_us)
        + " us",
    )
    assert_true(
        elapsed_us < _BUDGET_US,
        msg="a completed body must return before the budget is spent",
    )


def test_stalled_body_hits_the_deadline_by_advancing_the_fake_clock() raises:
    """The counterpart of the case above, same budget, same clock: a peer that
    sends a complete head and one body byte and then goes silent must fail with
    the response-body deadline, and at the budget exactly.

    Each silent read moves the fake clock by 10_000 us and the deadline is
    checked before every read, so the clock must stop at the first multiple of
    the step at or after the 150_000 us budget: 150_000 us. An early failure
    (data loss) or a late one (an unbounded wait) both move that number. No
    real time passes."""
    var clock = _fake_clock()
    var script = _concat(_chunked_head(), _never_terminated_chunked_body(1))
    var stream = ScriptedStream.from_read_script(script^)
    stream.set_pending_after_script(_STALL_PENDING_COUNT)
    stream.advance_clock_on_read(clock, _PENDING_STEP_US)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector].with_request_timeout_us(
        connector^, _BUDGET_US,
    )
    client.set_test_clock(clock)
    var reactor = _make_reactor()

    var url = _get_request()
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var raised = False
    var detail = String()
    var start_us = clock[]
    try:
        var _resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
    except e:
        raised = True
        detail = String(e)

    assert_true(raised, msg="a stalled body must raise, not return")
    assert_true(
        "response body deadline exceeded" in detail,
        msg="the stalled body must fail with the body deadline; got: " + detail,
    )
    assert_equal(
        clock[] - start_us,
        _BUDGET_US,
        msg="the body deadline must fire at the budget on the fake clock",
    )


# =============================================================================
# 6 — a failed body drain must DESTROY its connection, not pool it.
# =============================================================================


def test_a_failed_body_drain_does_not_poison_the_connection_pool() raises:
    """A request that fails mid-BODY must not leave its connection cached.

    A connection whose response was abandoned part-way holds unconsumed bytes;
    handing it to the next caller feeds them the tail of somebody else's
    response (Go issue 23399). The head half is covered by
    `test_client_send_buffered_honors_request_timeout.mojo`; this is the body
    half, and the one with bytes still on the wire.

    TWO-SIDED: the fixture SEEDS the stuck connection into the idle cache and
    asserts `is_cached() == True` BEFORE the request (an accessor that can only
    say False would otherwise pass), and it runs the CACHED arm, where a conn
    already in the pool must be EVICTED. A dial tripwire proves which arm ran."""
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

    `test_outbound_budget_rule.mojo` exercises the clamp as pure functions; the
    600 s-inside-a-300 s-ceiling bug lived in the WIRING, and this drives a
    derived, clamped value through a real drive loop. The ceiling is synthetic
    on purpose: 5.15 s takes the same subtractive arm as the real 300 s one
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

    var clock = _fake_clock()
    var stream = ScriptedStream.empty()
    stream.queue_read_pending(_STALL_PENDING_COUNT)
    stream.advance_clock_on_read(clock, _PENDING_STEP_US)
    var connector = ScriptedConnector.with_stream(stream^)
    var client = HttpClient[ScriptedConnector](
        config=cfg, connector=connector^,
    )
    client.set_test_clock(clock)
    var reactor = _make_reactor()

    var url = _get_request()
    var hdrs = HeaderMap()
    var req = build_get_request(url^, hdrs^)

    var raised = False
    var detail = String()
    var start_us = clock[]
    try:
        var _resp = client.send_buffered[PerCoreAsyncRuntime[NoopSink]](
            req^, reactor,
        )
    except e:
        raised = True
        detail = String(e)
    var elapsed_us = clock[] - start_us

    assert_true(raised, msg="a stuck peer must raise, not return")
    assert_true(
        "deadline exceeded" in detail,
        msg="must fail via the derived wall-clock budget; got: " + detail,
    )
    # ★ THE HEADLINE ASSERTION: the DERIVED budget, not the 600 s default, is
    # what bounded the call. On the fake clock it fires at the derived budget
    # exactly: not before it (150_000 us) and not after.
    assert_equal(
        elapsed_us,
        cfg.request_timeout_us,
        msg=(
            "the derived 150 ms budget did not bound the drive loop: elapsed "
            + String(elapsed_us)
            + " us on the fake clock"
        ),
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
        test_stalled_body_hits_the_deadline_by_advancing_the_fake_clock()
        ok = True
    except e:
        why = String(e)
    _run(String("stalled_body_hits_the_deadline_by_advancing_the_fake_clock"), failures, ok, why)

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
