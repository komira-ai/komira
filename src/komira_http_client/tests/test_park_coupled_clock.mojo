"""`ParkCoupledClock` — and the falsifier for the test-clock idiom this package
already had.

⭐ THE POINT, in one sentence: the existing `AutoAdvancingClock` /
`IncrementingClock` idiom (`komira_http_client/tests/test_timeout_layer.mojo:64-199`)
advances on EVERY `now_us()` call, so a client that BUSY-POLLS reads the clock
more often than one that parks and is therefore REWARDED with elapsed time it
never spent. A promptness assertion written against it passes for the spinner.

That is not hypothetical. A production service's wedge is a busy-poll — 64
spins plus one 50 ms park per cycle, 22 h of 504s at the Cloud Run ceiling with
the process at a steady ~7 % CPU — and an auto-advancing clock is structurally
blind to it: the more it spins, the more time the clock says it waited.

`ParkCoupledClock` states Go's `testing/synctest` contract instead: "Time in a
bubble only advances when every goroutine in the bubble is durably blocked."
`now_us()` is FROZEN; the only thing that moves it is a park, by the timeout
the parking code actually requested.

⚠ TEST 5 IS THE ONE THAT MATTERS. It runs the SAME spinning consumer against
both clocks and asserts they disagree — the auto-advancing clock reports half a
second of elapsed time for a loop that did nothing but read the clock, and the
park-coupled clock reports ZERO. Without that side-by-side the new conformer is
just another clock; with it, the defect in the old idiom is a recorded fact.

Mojo 1.0.0b2 (def-only).
"""

from std.memory import OwnedPointer
from std.testing import assert_equal, assert_true

from komira_http_client.clock import Clock, MockClock, ParkCoupledClock


# =============================================================================
# A BYTE-FAITHFUL COPY of the idiom under criticism.
# =============================================================================
#
# `AutoAdvancingClock` is defined INSIDE `test_timeout_layer.mojo`, which is a
# test entry point and not importable. It is reproduced here — same
# `OwnedPointer[state]` shape, same "read the value, then advance by delta,
# then return the PRE-advance value" body — so the comparison in test 5 is
# against the real idiom and not a strawman built to lose.
#
# If `test_timeout_layer.mojo`'s version ever changes, THIS COPY IS STALE and
# test 5 is comparing against history. That is a real hazard of copying, and it
# is preferred here to the alternative (asserting nothing about the idiom at
# all), because the copy is 12 lines and the claim it supports is the reason
# this file exists.


@fieldwise_init
struct _AutoAdvState(Copyable, ImplicitlyCopyable, Movable, Deinitable):
    var counter: Int
    var delta: Int


struct AutoAdvancingClockCopy(Clock, Movable, Deinitable):
    """COPY of `test_timeout_layer.mojo`'s `AutoAdvancingClock`: advances on
    every `now_us()` call and returns the pre-advance value."""

    var _state: OwnedPointer[_AutoAdvState]

    @staticmethod
    def new(starting_t: Int, delta_per_call: Int) -> AutoAdvancingClockCopy:
        return AutoAdvancingClockCopy(
            _state=OwnedPointer(
                _AutoAdvState(counter=starting_t, delta=delta_per_call)
            )
        )

    def __init__(out self, var _state: OwnedPointer[_AutoAdvState]):
        self._state = _state^

    def now_us(mut self) -> Int:
        var current = self._state[].counter
        self._state[].counter = current + self._state[].delta
        return current


# =============================================================================
# §1 — the contract
# =============================================================================


def test_now_us_is_frozen_across_reads() raises:
    """READING THE CLOCK DOES NOT MOVE IT. This is the single property the
    auto-advancing idiom does not have, and everything else follows from it."""
    print("  test_now_us_is_frozen_across_reads...")
    var clk = ParkCoupledClock.starting_at(7_000_000)
    var i = 0
    while i < 1000:
        assert_equal(
            clk.now_us(), 7_000_000,
            "read " + String(i) + " moved a FROZEN clock",
        )
        i = i + 1
    assert_equal(clk.park_count(), 0, "1000 reads are not a park")
    assert_equal(clk.parked_us(), 0, "and cost no time")
    print("    OK — 1000 reads, 0 us elapsed")


def test_time_advances_only_by_the_park_timeout_requested() raises:
    """The advance is the timeout the PARKING CODE asked for — not a per-call
    delta the test picked, which is what makes a deadline assertion exact
    instead of approximate."""
    print("  test_time_advances_only_by_the_park_timeout_requested...")
    var clk = ParkCoupledClock.new()
    clk.on_park(50_000)
    assert_equal(clk.now_us(), 50_000)
    clk.on_park(50_000)
    assert_equal(clk.now_us(), 100_000)
    clk.on_park(1_234)
    assert_equal(
        clk.now_us(), 101_234,
        "a park for an ODD timeout advances by exactly that, not by a rounded"
        " or fixed step",
    )
    print("    OK")


def test_park_count_and_parked_us_are_a_ledger_of_behaviour() raises:
    """`park_count` is what `MockClock` cannot express: its advance is
    something the TEST decided, so it can report elapsed time for a client
    that never waited. This counts what the CODE did."""
    print("  test_park_count_and_parked_us_are_a_ledger_of_behaviour...")
    var clk = ParkCoupledClock.starting_at(1_000_000)
    clk.on_park(50_000)
    clk.on_park(50_000)
    clk.on_park(0)
    assert_equal(clk.park_count(), 3, "a ZERO-timeout poll is still a park")
    assert_equal(
        clk.parked_us(), 100_000,
        "but it costs no time — parked_us is time, park_count is events, and"
        " conflating them is how a spin-poll looks like a wait",
    )
    assert_equal(clk.now_us(), 1_100_000, "relative to the starting value")
    print("    OK")


def test_an_unbounded_park_is_refused_as_a_deadlock() raises:
    """`park_on_fds` spells "block indefinitely" as `timeout_us = -1`. In a
    bubble whose only time source is the park, that cannot advance the clock by
    any finite amount, so every later deadline is unreachable. Refusing it
    reports a deadlock as a deadlock; treating it as zero would turn a hung
    test into a passing one."""
    print("  test_an_unbounded_park_is_refused_as_a_deadlock...")
    var clk = ParkCoupledClock.new()
    var raised = False
    var detail = String()
    try:
        clk.on_park(-1)
    except e:
        raised = True
        detail = String(e)
    assert_true(raised, "an unbounded park must be REFUSED, not absorbed")
    assert_true(
        String("deadlock") in detail,
        "and must say so — 'this is a deadlock, not a long wait'; got: "
        + detail,
    )
    assert_equal(clk.now_us(), 0, "the refused park moved nothing")
    assert_equal(clk.park_count(), 0, "and was not counted")
    print("    OK")


# =============================================================================
# §2 — ⭐ THE FALSIFIER FOR THE EXISTING IDIOM
# =============================================================================


def _spin_reading_the_clock[C: Clock](mut clock: C, reads: Int) -> Int:
    """A consumer that makes NO PROGRESS and never parks — it only reads the
    clock, which is what a busy-poll loop's deadline check does. Returns the
    elapsed time the clock claims passed."""
    var t0 = clock.now_us()
    var i = 0
    while i < reads:
        _ = clock.now_us()
        i = i + 1
    return clock.now_us() - t0


def test_the_auto_advancing_idiom_pays_a_spinning_client_for_time_it_never_spent(
) raises:
    """⭐ THE POINT, AS AN ASSERTION.

    The SAME spinning consumer, 10 000 clock reads and zero parks, run against
    both clocks:

      * `AutoAdvancingClockCopy(delta=50us)` reports ~500 ms of elapsed time.
        Every microsecond of it is FABRICATED — the loop waited for nothing.
      * `ParkCoupledClock` reports ZERO, because nothing parked.

    A promptness or deadline assertion written against the first clock is
    satisfied by spinning HARDER (more reads, more "elapsed" time), which is
    the exact inversion that makes a busy-poll invisible to it."""
    print(
        "  test_the_auto_advancing_idiom_pays_a_spinning_client_for_time_it"
        "_never_spent..."
    )
    var reads = 10_000
    var delta = 50

    var auto = AutoAdvancingClockCopy.new(starting_t=0, delta_per_call=delta)
    var auto_elapsed = _spin_reading_the_clock[AutoAdvancingClockCopy](
        auto, reads,
    )

    var park = ParkCoupledClock.new()
    var park_elapsed = _spin_reading_the_clock[ParkCoupledClock](park, reads)

    assert_true(
        auto_elapsed >= reads * delta,
        "the auto-advancing idiom must be shown to FABRICATE time for a"
        " spinner — it reported " + String(auto_elapsed) + " us for "
        + String(reads) + " reads and zero parks",
    )
    assert_equal(
        park_elapsed, 0,
        "a park-coupled clock pays a spinner NOTHING: it reported "
        + String(park_elapsed) + " us for the same loop",
    )
    assert_true(
        auto_elapsed > park_elapsed,
        "the two clocks must DISAGREE on this loop; if they ever agree, the"
        " copy of the old idiom above has gone stale and this file is"
        " comparing against history",
    )
    print(
        "    OK — same spin: auto-advancing says", auto_elapsed,
        "us, park-coupled says", park_elapsed, "us",
    )


def test_a_deadline_check_is_satisfiable_by_spinning_under_the_old_idiom(
) raises:
    """The consequence, stated as the assertion a real timeout test would make.

    A 200 ms deadline is 'reached' by a loop that did nothing but read the
    auto-advancing clock ~4 000 times — so `raise TIMEOUT` fires on a client
    that never waited, and equally a `assert elapsed >= budget` promptness
    check passes for one. Under the park-coupled clock the same loop never
    reaches the deadline, which is the correct answer: no time passed."""
    print(
        "  test_a_deadline_check_is_satisfiable_by_spinning_under_the_old"
        "_idiom..."
    )
    var deadline_us = 200_000

    var auto = AutoAdvancingClockCopy.new(starting_t=0, delta_per_call=50)
    var auto_hit = False
    var i = 0
    while i < 5_000:
        if auto.now_us() >= deadline_us:
            auto_hit = True
            break
        i = i + 1
    assert_true(
        auto_hit,
        "a 200 ms deadline must be shown to be REACHABLE by pure spinning"
        " under the auto-advancing idiom",
    )

    var park = ParkCoupledClock.new()
    var park_hit = False
    var j = 0
    while j < 5_000:
        if park.now_us() >= deadline_us:
            park_hit = True
            break
        j = j + 1
    assert_true(
        not park_hit,
        "and must be UNREACHABLE by spinning under the park-coupled clock —"
        " a deadline a busy-poll can reach without waiting is not a deadline",
    )

    # ...and reachable the honest way: four 50 ms parks.
    var k = 0
    while k < 4:
        park.on_park(50_000)
        k = k + 1
    assert_true(
        park.now_us() >= deadline_us,
        "the same deadline IS reached by actually parking for it",
    )
    assert_equal(park.park_count(), 4)
    print("    OK — reachable by spinning under the old idiom, not under this")


def test_mock_clock_is_frozen_too_but_carries_no_ledger() raises:
    """Stated so the obvious question — 'why not `MockClock`?' — is answered by
    an assertion rather than by prose. `MockClock` IS frozen on read, and that
    half is fine. What it cannot do is tell you what the code under test DID:
    its advance is a number the test typed, so there is no `park_count` to
    assert and 'the client parked twice for 50 ms' is unwritable."""
    print("  test_mock_clock_is_frozen_too_but_carries_no_ledger...")
    var mock = MockClock.new()
    var elapsed = _spin_reading_the_clock[MockClock](mock, 1000)
    assert_equal(
        elapsed, 0, "MockClock is frozen on read — it shares that half",
    )
    mock.advance_us(100_000)
    assert_equal(
        mock.now_us(), 100_000,
        "but the advance is the TEST's declaration, indistinguishable from a"
        " client that parked, one that spun, and one that did nothing",
    )
    print("    OK")


def main() raises:
    test_now_us_is_frozen_across_reads()
    test_time_advances_only_by_the_park_timeout_requested()
    test_park_count_and_parked_us_are_a_ledger_of_behaviour()
    test_an_unbounded_park_is_refused_as_a_deadlock()
    test_the_auto_advancing_idiom_pays_a_spinning_client_for_time_it_never_spent()
    test_a_deadline_check_is_satisfiable_by_spinning_under_the_old_idiom()
    test_mock_clock_is_frozen_too_but_carries_no_ledger()
    print("PASS test_park_coupled_clock")
