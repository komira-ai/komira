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
# WHY A TIMING ASSERTION, AND WHY IT IS AGAINST A BASELINE
# -----------------------------------------------------------------------------
#
# The claim under test IS a cost claim, so a test that does not measure cost
# cannot falsify it. What it asserts is the cost OVER A BASELINE, not an
# absolute number of nanoseconds:
#
#   * `_baseline()` is the same shape as the shipped path without the C call:
#     one non-inlined call that does one load and compares it with 0. Both are
#     timed in the same loop, for the same `_N_CALLS`, in the same binary.
#   * The assertion is `ns(ea_armed) - ns(baseline) <= _MAX_NS_OVER_BASELINE`
#     (20 ns) per call. The C call and its relaxed atomic load are ~2-4 ns; a
#     KGEN string-keyed registry lookup inside a `try`/`except` is not.
#   * An absolute ceiling was flaky: the coverage build compiles this test at
#     -O0 and runs it under kcov, where the loop, the call and the compare cost
#     ~20 ns more than in a release build, and a 20 ns ceiling calibrated on
#     release code read 26 ns/call there. That overhead is in both loops and
#     cancels in the difference.
#   * In a release build the optimiser may fold `_baseline()` (it returns a
#     constant) and drop its loop. That makes the baseline ~0 ns and the
#     assertion the old absolute one: stricter, never looser.
#   * Each loop is timed `_N_ROUNDS` times, alternating, and the fastest round
#     of each is kept, so a round the scheduler preempted does not count.
#   * The loops accumulate every return value and the result is checked, so
#     neither the loop nor the calls can be optimised away. (The shipped
#     `ea_armed()` is an `external_call`, which is opaque to LLVM regardless.)
#
# This is a CEILING on a claim, not a benchmark. It does not assert the path got
# faster by any particular factor; it asserts the header is not lying by an
# order of magnitude.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_metrics.explain_analyze_collect import (
    EA_COLLECTION_COMPILED_IN,
    ea_arm,
    ea_armed,
    ea_disarm,
)


comptime _N_CALLS: Int = 400_000
"""Enough iterations that a per-call cost of a few ns is many milliseconds in
total, so the clock's own resolution is noise."""

comptime _N_ROUNDS: Int = 3
"""Rounds per loop; the fastest is kept."""

comptime _MAX_NS_OVER_BASELINE: Int = 20
"""The ceiling the header's claim implies, per call, over `_baseline()`. One
relaxed atomic load behind one C call is ~2-4 ns; a KGEN string-keyed
global-registry lookup inside a `try`/`except` is not."""


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


def test_disarmed_ea_armed_costs_what_the_header_claims() raises:
    """FALSIFIER for the disarmed `ea_armed()` cost.

    A `_Global.get_or_create_ptr()` — a `raises`, string-keyed KGEN-runtime
    registry lookup — blows the ceiling. The shipped path is
    `external_call["komira_ea_armed", Int32]()`, a relaxed load of a TU-static
    in this package's C file.
    """
    ea_disarm()
    # Warm: first touch of the flag may fault in a page / materialize the
    # global. The claim is about the STEADY-STATE cost at a recording seam.
    var warm = 0
    for _ in range(1024):
        warm += 1 if ea_armed() else 0
        warm += 1 if _baseline() else 0
    if warm != 0:
        raise Error(
            "test_explain_analyze_disarmed_cost: a call returned True"
            " during the warm loop while the collector was disarmed."
        )

    var ea_ns = _loop_ns[True]()
    var base_ns = _loop_ns[False]()
    for _ in range(_N_ROUNDS - 1):
        ea_ns = min(ea_ns, _loop_ns[True]())
        base_ns = min(base_ns, _loop_ns[False]())
    var delta_ns = ea_ns - base_ns
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
        _per_call(delta_ns),
        "ns/call (ceiling",
        _MAX_NS_OVER_BASELINE,
        "ns/call over the baseline)",
    )
    assert_true(
        delta_ns <= _MAX_NS_OVER_BASELINE * _N_CALLS,
        String("DISARMED COST CLAIM IS FALSE: `ea_armed()` cost ")
        + String(_per_call(ea_ns))
        + " ns/call against a baseline of "
        + String(_per_call(base_ns))
        + " ns/call for one non-inlined load-and-compare: "
        + String(_per_call(delta_ns))
        + " ns/call over it, against a ceiling of "
        + String(_MAX_NS_OVER_BASELINE)
        + " ns/call implied by the module header's 'one relaxed atomic load'."
        + " This path sits at four collection seams including"
        + " `materialize_subplan._dispatch_thunk`, which every breaker passes"
        + " through.",
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
    suite.test[test_disarmed_ea_armed_costs_what_the_header_claims]()
    suite.test[
        test_the_comptime_kill_switch_governs_whether_the_collector_can_arm
    ]()
    suite.test[test_arming_does_not_leak_out_of_this_file]()
    suite^.run()
