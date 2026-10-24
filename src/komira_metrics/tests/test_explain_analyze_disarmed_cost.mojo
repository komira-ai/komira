# =============================================================================
# Tests: the DISARMED cost of the EXPLAIN ANALYZE collector is what its header
# claims, and the comptime kill-switch exists
# =============================================================================
#
# WHAT THIS FALSIFIES.
#
# `explain_analyze_collect.mojo`'s header claims the disarmed `ea_armed()` is
# one relaxed atomic load behind one C call. The tempting implementation is
# not that:
#
#     try:
#         var g = _EA_ARMED.get_or_create_ptr()
#         return g[][].load() != Int64(0)
#     except:
#         return False
#
# `_Global.get_or_create_ptr()` is a `raises` lookup into the KGEN runtime's
# process-global registry, keyed by the global's NAME STRING. It is a call, a
# string-keyed lookup and a `try`/`except` landing pad — not a relaxed atomic
# load. And it would sit on the collection path at every seam, one of which
# EVERY breaker in the engine passes through.
#
# The header also claims a comptime kill-switch that compiles the collection
# out: a module-level `comptime Bool` that every call site wraps its body in
# via `@parameter if`.
#
# -----------------------------------------------------------------------------
# WHY THE FALSIFIER READS THE FLAG'S LOCATION, NOT A CLOCK
# -----------------------------------------------------------------------------
#
# The claim is a cost claim, but a time on a shared or loaded machine does not
# measure it: any ns ceiling depends on the hardware and flakes on a busy
# node. What the claim MEANS is structural, and a structure can be asserted
# exactly:
#
#   * the arm flag is one TU-static `int` in the package's C file, and
#     `ea_armed()` is a call to `komira_ea_armed`, which loads it. It does not
#     consult any Mojo-side storage.
#
# If the flag lived in a Mojo `_Global` (the tempting implementation above),
# `ea_armed()` would read that storage and a write to the C flag would not be
# seen by it. So the test drives the C flag DIRECTLY, through the same
# `komira_ea_set_armed` the shipped `ea_arm()` calls, and asserts `ea_armed()`
# follows it, in both directions, over many calls; and that `ea_arm()` and
# `ea_disarm()` move the very same flag, read back through `komira_ea_armed`.
# A flag kept anywhere else cannot satisfy all three.
#
# What this does NOT prove: an `ea_armed()` that did a registry lookup AND then
# still read the C flag would pass; there is no counter on the lookup and none
# is added, because a counter on a read every breaker passes through would
# cost more than the claim allows. The cost of the shipped path is still
# printed (fastest of `_N_ROUNDS` loops against a non-inlined load-and-compare
# baseline) as information; NO TIME IS ASSERTED.
# =============================================================================

from std.ffi import external_call
from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_metrics.explain_analyze_collect import (
    EA_COLLECTION_COMPILED_IN,
    ea_arm,
    ea_armed,
    ea_disarm,
)


comptime _N_CALLS: Int = 400_000
"""Calls per loop."""

comptime _N_ROUNDS: Int = 3
"""Rounds per loop; the fastest is kept."""


@no_inline
def _baseline() -> Bool:
    """The shipped `ea_armed()`'s shape without the C call: one non-inlined
    call, one load, one compare with 0. Always False, like a disarmed
    collector."""
    var flag = Int32(0)
    # SAFETY: `p` points at `flag`, a local of this frame that outlives the
    # one read through `p` below; nothing else aliases it.
    var p = Pointer(to=flag)
    return p[] != Int32(0)


def _loop_ns[shipped: Bool]() raises -> Int:
    """Wall of `_N_CALLS` calls of `ea_armed()` (`shipped`) or `_baseline()`,
    in nanoseconds, with the collector disarmed.

    Raises if any call answered True: that is the guard that the calls
    actually happened (an accumulated result consumed by a check cannot be
    deleted) and that the collector is disarmed.
    """
    var calls_accum = 0
    var t0 = perf_counter_ns()
    for _ in range(_N_CALLS):
        comptime if shipped:
            calls_accum += 1 if ea_armed() else 0
        else:
            calls_accum += 1 if _baseline() else 0
    var t1 = perf_counter_ns()
    if calls_accum != 0:
        raise Error(
            "test_explain_analyze_disarmed_cost: accumulated "
            + String(calls_accum)
            + " True answers from a disarmed collector (shipped="
            + String(shipped)
            + ")."
        )
    return Int(t1 - t0)


def _per_call(total_ns: Int) -> Float64:
    return Float64(total_ns) / Float64(_N_CALLS)


def _c_flag() -> Int32:
    """The arm flag as the C file holds it: `komira_ea_armed`, the same symbol
    `ea_armed()` calls, called directly."""
    return external_call["komira_ea_armed", Int32]()


def _c_set_flag(v: Int32):
    """Write the C flag directly, as `ea_arm()` / `ea_disarm()` do."""
    _ = external_call["komira_ea_set_armed", Int32](v)


def _count_armed_answers(n: Int) -> Int:
    """How many of `n` calls of `ea_armed()` answered True."""
    var accum = 0
    for _ in range(n):
        accum += 1 if ea_armed() else 0
    return accum


def test_ea_armed_reads_the_c_flag_and_nothing_else() raises:
    """FALSIFIER for the disarmed `ea_armed()` being one load of the C flag.

    The shipped path is `external_call["komira_ea_armed", Int32]()`, a relaxed
    load of a TU-static in this package's C file. A `_Global.get_or_create_ptr()`
    mirror of the flag (the header's tempting implementation) would not follow a
    write to the C flag, and fails here.
    """
    ea_disarm()
    assert_equal(Int(_c_flag()), 0, "ea_disarm() leaves the C flag at 0")
    assert_equal(
        _count_armed_answers(_N_CALLS), 0, "disarmed: every call answers False"
    )

    comptime if EA_COLLECTION_COMPILED_IN:
        # Drive the C flag directly: `ea_armed()` must follow it, every call.
        _c_set_flag(Int32(1))
        assert_equal(
            _count_armed_answers(_N_CALLS),
            _N_CALLS,
            "the C flag is 1: every call of ea_armed() answers True",
        )
        _c_set_flag(Int32(0))
        assert_equal(
            _count_armed_answers(_N_CALLS),
            0,
            "the C flag is back to 0: every call answers False",
        )

        # ea_arm() / ea_disarm() move that same flag.
        ea_arm()
        assert_equal(Int(_c_flag()), 1, "ea_arm() sets the C flag")
        assert_equal(
            _count_armed_answers(_N_CALLS), _N_CALLS, "armed: every call True"
        )
        ea_disarm()
        assert_equal(Int(_c_flag()), 0, "ea_disarm() clears the C flag")
        assert_equal(
            _count_armed_answers(_N_CALLS), 0, "disarmed again: every call False"
        )
    else:
        # Compiled out: ea_armed() is a comptime False, the C flag is never
        # written by ea_arm(), and a direct write is invisible to it.
        _c_set_flag(Int32(1))
        assert_equal(
            _count_armed_answers(_N_CALLS),
            0,
            "compiled out: ea_armed() ignores the flag",
        )
        _c_set_flag(Int32(0))
    ea_disarm()


def test_disarmed_cost_is_reported_not_asserted() raises:
    """Print the disarmed cost of `ea_armed()` against a non-inlined
    load-and-compare baseline. Information only: NO TIME IS ASSERTED. The
    accumulated answers are still checked, so neither loop can be optimised
    away and the collector is known to be disarmed."""
    ea_disarm()
    var warm = 0
    for _ in range(1024):
        warm += 1 if ea_armed() else 0
        warm += 1 if _baseline() else 0
    assert_equal(warm, 0, "a call returned True while the collector was disarmed")

    var ea_ns = _loop_ns[True]()
    var base_ns = _loop_ns[False]()
    for _ in range(_N_ROUNDS - 1):
        ea_ns = min(ea_ns, _loop_ns[True]())
        base_ns = min(base_ns, _loop_ns[False]())
    print(
        "[EA-DISARMED-COST] fastest of",
        _N_ROUNDS,
        "rounds of",
        _N_CALLS,
        "calls: ea_armed()",
        _per_call(ea_ns),
        "ns/call, baseline",
        _per_call(base_ns),
        "ns/call, delta",
        _per_call(ea_ns - base_ns),
        "ns/call (information only)",
    )


def test_the_comptime_kill_switch_governs_whether_the_collector_can_arm() raises:
    """FALSIFIER for the comptime kill-switch.

    Without `EA_COLLECTION_COMPILED_IN` this file does not COMPILE — the
    strongest form of "the switch is missing".

    The switch is load-bearing in BOTH settings, and this asserts the
    contract for whichever one is shipped: compiled in, arming works; compiled
    out, `ea_armed()` is a comptime False and NOTHING at any recording seam can
    observe an armed collector.
    """
    ea_arm()

    comptime if EA_COLLECTION_COMPILED_IN:
        assert_true(
            ea_armed(),
            "EA_COLLECTION_COMPILED_IN is True, so ea_arm() must be"
            " observable at every recording seam.",
        )
    else:
        assert_false(
            ea_armed(),
            "EA_COLLECTION_COMPILED_IN is False, so the collection is compiled"
            " out and ea_armed() must be a comptime False regardless of"
            " ea_arm() — otherwise the kill-switch does not kill anything.",
        )

    ea_disarm()
    assert_false(
        ea_armed(),
        "ea_disarm() must leave the collector disarmed in either"
        " configuration.",
    )


def test_arming_does_not_leak_out_of_this_file() raises:
    """Housekeeping guard: the collector is process-global, so a test that
    armed it and did not disarm would silently arm every later test in the
    binary. Asserts the disarmed steady state this file must leave behind."""
    assert_false(ea_armed(), "the collector must be disarmed at rest")
    assert_equal(0, 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_ea_armed_reads_the_c_flag_and_nothing_else]()
    suite.test[test_disarmed_cost_is_reported_not_asserted]()
    suite.test[
        test_the_comptime_kill_switch_governs_whether_the_collector_can_arm
    ]()
    suite.test[test_arming_does_not_leak_out_of_this_file]()
    suite^.run()
