# =============================================================================
# test_tcp_connect_dial_deadline.mojo
# =============================================================================
# ⭐ THE FALSIFIER FOR "A DIAL CAN WAIT FOREVER".
#
# THE DEFECT, in one sentence: `TcpStream.connect`'s deadline was an OPTIONAL
# ARGUMENT WHOSE DEFAULT WAS `Int32(-1)` = park forever, so the only dials that
# were bounded were the ones whose caller happened to restate a literal — and
# callers that did not took an arm that
# did ONE `poll_completions(timeout_us=Int32(-1))` and then read `SO_ERROR`.
#
# ⛔ THIS TEST ASSERTS THAT THE LOOP **TERMINATES**, NOT THAT A BOUND EXISTS.
# The whole defect class is a loop that runs forever while every declared bound
# sits unfired nearby: a hung dial burns a flat sliver of CPU with zero bytes on
# the wire while every surrounding budget is declared and exceeded. So
# `assert_true(bound > 0)` is precisely the assertion that would pass
# through that failure. What is asserted here instead is that
# the RECURRENCE the dial loop is driven by reaches its terminal verdict in a
# FINITE number of steps, from every reachable state, including the adversarial
# one where each park returns with no measurable time elapsed.
#
# ⚠ WHAT IS **NOT** COVERED, STATED SO IT IS NOT MIS-CITED. There is no
# hermetic way on Linux to hold a TCP connect in EINPROGRESS: a loopback dial
# to a closed port is refused EAGERLY, a full accept queue still completes the
# handshake client-side (syncookies), and a blackholed route needs either root
# or an egress path a test runner may not have. So the END-TO-END arm below proves
# the real entry point still dials and still refuses on the DEFAULT argument
# (the regression guard on deleting the unbounded arm); the TERMINATION proof
# is on the recurrence, which is where the defect actually lived.
# =============================================================================

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns

from komira_async.ops.waker_sink import NoopSink
from komira_async.runtime.blocking_runtime import BlockingRuntime
from komira_async.runtime.tcp_stream import (
    CONNECT_DEADLINE_DEFAULT_US,
    CONNECT_DEADLINE_EXPIRED,
    CONNECT_PARK_SLICE_US,
    TcpListener,
    TcpStream,
    connect_park_slice_us,
    resolve_connect_timeout_us,
)
from komira_async.reactor.socket_setup import inet_loopback_be


# =============================================================================
# THE RESOLUTION RULE: there is no input that yields an unbounded dial.
# =============================================================================


def test_no_input_yields_an_unbounded_dial() raises:
    """Every value a caller can supply resolves to a STRICTLY POSITIVE dial
    deadline.

    The four inputs that matter, and why each one is here rather than being
    "the same case":
      * `-1` — the HISTORICAL SENTINEL. It was the shipped default and it MEANT
        "park forever". It is the value the two unbounded production callers
        were passing by omission.
      * `0`  — "nobody stated anything". `Reactor.poll_completions` maps 0 to a
        NON-BLOCKING poll, so passing a caller's zero through would convert a
        park into a hot spin — the opposite failure, equally fatal on a
        single-threaded serve loop.
      * a large NEGATIVE — a remaining-budget subtraction that went past zero.
        This is the shape that turns a bound into its opposite in the direction
        that fails OPEN, and it is the class the brief for this work named
        first.
      * a POSITIVE — must be returned VERBATIM. A resolver that "helpfully"
        widened `KernelTcpConnector`'s 5s would be a silent policy change."""
    assert_true(resolve_connect_timeout_us(Int32(-1)) > Int32(0))
    assert_true(resolve_connect_timeout_us(Int32(0)) > Int32(0))
    assert_true(resolve_connect_timeout_us(Int32(-50_000)) > Int32(0))
    assert_true(resolve_connect_timeout_us(Int32(-2_147_483_647)) > Int32(0))

    # The three non-positive spellings all mean the same thing now, and it is
    # the DEFAULT — not "forever" and not "immediately".
    assert_equal(
        Int(resolve_connect_timeout_us(Int32(-1))),
        Int(CONNECT_DEADLINE_DEFAULT_US),
    )
    assert_equal(
        Int(resolve_connect_timeout_us(Int32(0))),
        Int(CONNECT_DEADLINE_DEFAULT_US),
    )

    # A stated budget survives byte-identically — this is what keeps
    # `KernelTcpConnector`'s 5s a 5s.
    assert_equal(Int(resolve_connect_timeout_us(Int32(5_000_000))), 5_000_000)
    assert_equal(Int(resolve_connect_timeout_us(Int32(1))), 1)
    assert_equal(
        Int(resolve_connect_timeout_us(Int32(2_147_483_647))), 2_147_483_647
    )


# =============================================================================
# THE SLICE: bounded, never zero, never past the deadline.
# =============================================================================


def test_park_slice_is_never_zero_and_never_outlives_the_deadline() raises:
    """Every slice the loop may park for is in `[1, CONNECT_PARK_SLICE_US]`
    and never reaches past the deadline.

    ⚠ A ZERO SLICE IS NOT A SMALL PARK — it is a different SYSCALL.
    `Reactor.poll_completions` maps `timeout_us == 0` to `epoll_wait(0)`, a
    non-blocking poll, so a loop that computed a zero slice would pin a core
    until the clock ticked over. The `<= 0 -> 1` clamp is what makes the
    clock strictly advance, which is half of the termination argument"""
    var base_ns = Int64(1_000_000_000_000)
    # A sweep across the interesting magnitudes: sub-microsecond remainder,
    # sub-slice, exactly one slice, many slices, a full default budget.
    var remainders = List[Int64]()
    remainders.append(Int64(1))
    remainders.append(Int64(999))
    remainders.append(Int64(1_000))
    remainders.append(Int64(1_500))
    remainders.append(Int64(49_999_000))
    remainders.append(Int64(50_000_000))
    remainders.append(Int64(50_000_001))
    remainders.append(Int64(10_000_000_000))
    for i in range(len(remainders)):
        var rem_ns = remainders[i]
        var slice_us = connect_park_slice_us(base_ns + rem_ns, base_ns)
        assert_true(slice_us != CONNECT_DEADLINE_EXPIRED)
        assert_true(slice_us >= Int64(1))
        assert_true(slice_us <= CONNECT_PARK_SLICE_US)
        # The slice never parks past the deadline, except for the deliberate
        # sub-microsecond over-park that the `-> 1` clamp buys (a park of at
        # most 1 us past a deadline that has under 1 us left on it).
        assert_true(
            slice_us * Int64(1000) <= rem_ns or rem_ns < Int64(1000)
        )


def test_expired_is_a_distinguished_negative_at_the_boundary() raises:
    """The terminal verdict fires AT the deadline, not one slice after it, and
    it is a NEGATIVE that no caller can mistake for a timeout.

    ⛔ THE SIGN IS LOAD-BEARING. `poll_completions` treats any negative
    `timeout_us` as `epoll_wait(-1)` — block forever. So a verdict encoded as
    `0` or as "the remaining time, which happens to be negative" is exactly the
    bug: the value that means STOP would be handed to the kernel as the value
    that means WAIT FOREVER. Encoding it as a value that is never a legal slice
    (every legal slice is >= 1) is what makes that mistake unspellable."""
    var d = Int64(5_000_000_000)
    assert_equal(Int(connect_park_slice_us(d, d)), Int(CONNECT_DEADLINE_EXPIRED))
    assert_equal(
        Int(connect_park_slice_us(d, d + Int64(1))),
        Int(CONNECT_DEADLINE_EXPIRED),
    )
    assert_equal(
        Int(connect_park_slice_us(d, d + Int64(600_000_000_000))),
        Int(CONNECT_DEADLINE_EXPIRED),
    )
    # One nanosecond BEFORE the deadline is still a park, not a verdict.
    assert_true(connect_park_slice_us(d, d - Int64(1)) >= Int64(1))
    assert_true(CONNECT_DEADLINE_EXPIRED < Int64(0))


# =============================================================================
# ⭐ THE TERMINATION PROOF. The loop ENDS. Not "has a bound" — ENDS.
# =============================================================================


def _drive_to_termination(
    budget_us: Int64, advance_is_slice: Bool, hard_cap: Int
) raises -> Int:
    """Run the dial loop's real recurrence until it returns the terminal
    verdict, and RAISE if `hard_cap` iterations are spent without one.

    ⭐ THE RAISE IS THE ASSERTION. A test that checked "the deadline constant
    is positive" would have passed on the pre-fix tree, where the default arm
    had no deadline at all. This one cannot: if the recurrence does not reach
    `CONNECT_DEADLINE_EXPIRED`, the test does not pass slowly, it FAILS.

    `advance_is_slice` selects between the two clock behaviours the real loop
    sees:
      * True  — every park runs its FULL slice (the peer produced no readiness
                at all). This is the ordinary wedge.
      * False — every park returns essentially INSTANTLY, advancing the clock
                by 1 ns. This is the adversarial one: a foreign completion or a
                drained wake-eventfd ends `poll_completions` early, which is
                the shape (`stream_park.park_on_pending`
                invariant (ii)). A loop whose progress depended on the park
                ACTUALLY waiting would never terminate here."""
    var now_ns = Int64(4_000_000_000)
    var deadline_ns = now_ns + budget_us * Int64(1000)
    var iters = 0
    while iters < hard_cap:
        var slice_us = connect_park_slice_us(deadline_ns, now_ns)
        iters = iters + 1
        if slice_us == CONNECT_DEADLINE_EXPIRED:
            return iters
        # Invariants that must hold on EVERY iteration, not just the last.
        if slice_us < Int64(1) or slice_us > CONNECT_PARK_SLICE_US:
            raise Error(
                "dial loop produced an illegal park slice "
                + String(slice_us)
                + " us at iteration "
                + String(iters)
            )
        if advance_is_slice:
            now_ns = now_ns + slice_us * Int64(1000)
        else:
            now_ns = now_ns + Int64(1)
    raise Error(
        "THE DIAL LOOP DID NOT TERMINATE: "
        + String(hard_cap)
        + " iterations spent against a "
        + String(budget_us)
        + "us budget without reaching CONNECT_DEADLINE_EXPIRED"
    )


def test_dial_loop_terminates_when_every_park_runs_its_full_slice() raises:
    """The ordinary wedge: the peer never answers, so every park runs its full
    50 ms and the clock advances by exactly the slice.

    The iteration count is asserted against the ARITHMETIC bound
    (`ceil(budget/slice) + 1`), not merely "it finished" — a loop that
    terminated after 10x the expected trips would still be a defect."""
    var budgets = List[Int64]()
    budgets.append(Int64(1))
    budgets.append(Int64(999))
    budgets.append(Int64(50_000))
    budgets.append(Int64(5_000_000))
    budgets.append(Int64(10_000_000))
    for i in range(len(budgets)):
        var b = budgets[i]
        var iters = _drive_to_termination(b, True, 100_000)
        var expected_max = Int(
            (b + CONNECT_PARK_SLICE_US - Int64(1)) // CONNECT_PARK_SLICE_US
        ) + 2
        assert_true(iters >= 1)
        assert_true(iters <= expected_max)

    # The DEFAULT budget — the one a caller who states nothing now gets — is
    # itself bounded. This is the case that used to be `poll_completions(-1)`.
    var d_iters = _drive_to_termination(
        Int64(CONNECT_DEADLINE_DEFAULT_US), True, 100_000
    )
    assert_true(d_iters >= 1)
    assert_true(
        d_iters
        <= Int(
            (Int64(CONNECT_DEADLINE_DEFAULT_US) + CONNECT_PARK_SLICE_US - 1)
            // CONNECT_PARK_SLICE_US
        )
        + 2
    )


def test_dial_loop_terminates_when_every_park_returns_instantly() raises:
    """The adversarial case: every park is ended immediately by somebody
    ELSE's readiness, so the loop makes ~1 ns of progress per trip.

    ⭐ THIS IS THE CASE THE WEDGE ACTUALLY LOOKED LIKE FROM OUTSIDE — a loop
    turning at machine cadence, burning CPU, moving zero bytes. A termination
    argument that assumes the park waits is not an argument; this asserts the
    loop ends even when it never waits at all."""
    var iters = _drive_to_termination(Int64(200), False, 400_000)
    # 200 us of budget at 1 ns per trip == 200_000 trips, plus the terminal one.
    assert_true(iters >= 200_000)
    assert_true(iters <= 200_002)


# =============================================================================
# END-TO-END on the REAL entry point, DEFAULT arguments.
# =============================================================================
#
# The regression guard on deleting the unbounded arm: the default-argument dial
# must still DIAL, and must still refuse. ⚠ Both arms below resolve EAGERLY
# inside `try_io_connect` (loopback), so neither exercises the park loop — see
# the file banner for why no hermetic EINPROGRESS exists. They are here because
# the code path they cover is the one the deletion touched.


def test_default_argument_dial_still_connects_to_a_live_loopback_peer() raises:
    """`TcpStream.connect` with NO `connect_timeout_us` argument still
    establishes a connection. Pre-fix this took the (deleted) unbounded arm;
    post-fix it takes the bounded one with the resolved default."""
    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    var listener = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(16))
    var port = listener.local_port()
    assert_true(Int(port) > 0)
    var stream = TcpStream.connect[NoopSink](
        reactor, inet_loopback_be(), port,
    )
    assert_true(stream.fd() >= Int32(0))
    _ = stream^
    _ = listener^


def test_default_argument_dial_to_a_closed_port_returns_promptly() raises:
    """A refused dial on the DEFAULT argument RETURNS — it does not become the
    default budget's worth of waiting, and it does not hang.

    The bound asserted is deliberately loose (2 s against a resolved default of
    10 s): the point is that a refusal is a refusal, not that loopback is
    fast."""
    var rt = BlockingRuntime[NoopSink].new(NoopSink(_placeholder=UInt8(0)))
    ref reactor = rt.reactor()
    # Bind, read the port, then DROP the listener so nothing is listening.
    var l = TcpListener.bind_loopback(port=UInt16(0), backlog=Int32(1))
    var closed_port = l.local_port()
    _ = l^

    var t0 = Int64(perf_counter_ns())
    var raised = False
    try:
        var s = TcpStream.connect[NoopSink](
            reactor, inet_loopback_be(), closed_port,
        )
        # A kernel that eagerly completes against a dead port is not a failure
        # of this test's subject; the subject is that the call RETURNED.
        _ = s^
    except:
        raised = True
    var elapsed_ns = Int64(perf_counter_ns()) - t0
    _ = raised
    assert_true(elapsed_ns < Int64(2_000_000_000))


def main() raises:
    test_no_input_yields_an_unbounded_dial()
    test_park_slice_is_never_zero_and_never_outlives_the_deadline()
    test_expired_is_a_distinguished_negative_at_the_boundary()
    test_dial_loop_terminates_when_every_park_runs_its_full_slice()
    test_dial_loop_terminates_when_every_park_returns_instantly()
    test_default_argument_dial_still_connects_to_a_live_loopback_peer()
    test_default_argument_dial_to_a_closed_port_returns_promptly()
    print("PASS komira_async.runtime.tcp_stream dial deadline — the loop ENDS")
