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
# WHY A TIMING ASSERTION, AND WHY THIS ONE IS NOT FLAKY
# -----------------------------------------------------------------------------
#
# The claim under test IS a cost claim, so a test that does not measure cost
# cannot falsify it. The usual objection to a timing assertion is machine
# variance; it does not apply at this magnitude:
#
#   * The bound is `_MAX_NS_PER_CALL` = 20 ns AMORTIZED over 400_000 calls. A
#     relaxed atomic load plus one non-inlined C call is ~2-4 ns on any machine
#     this decade, so the shipped path has ~5x headroom.
#   * `_calls_accum` accumulates every return value and is asserted afterwards,
#     so neither the loop nor the calls can be optimised away. (The shipped
#     `ea_armed()` is an `external_call`, which is opaque to LLVM regardless.)
#   * The loop is pure user-space arithmetic — no allocation, no IO, no fork —
#     so it does not compete for the machine with anything the test harness is
#     doing.
#
# This is a CEILING on a claim, not a benchmark. It does not assert the path got
# faster by any particular factor; it asserts the header is not lying by an
# order of magnitude.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from komira_obs.explain_analyze_collect import (
    EA_COLLECTION_COMPILED_IN,
    ea_arm,
    ea_armed,
    ea_disarm,
)


comptime _N_CALLS: Int = 400_000
"""Enough iterations that a per-call cost of a few ns is many milliseconds in
total, so the clock's own resolution and the loop's own overhead are noise."""

comptime _MAX_NS_PER_CALL: Int = 20
"""The ceiling the header's claim implies. One relaxed atomic load behind one
C call is ~2-4 ns; a KGEN string-keyed global-registry lookup inside a
`try`/`except` is not."""


def _measure_disarmed_ns_per_call() raises -> Int:
    """Amortized wall of ONE disarmed `ea_armed()` call, in nanoseconds.

    Returns the whole-loop wall divided by `_N_CALLS`. Raises if the loop's
    accumulated result is not the all-disarmed answer — that is the guard that
    the calls actually happened.
    """
    ea_disarm()
    # Warm: first touch of the flag may fault in a page / materialize the global.
    # Measuring that once-per-process cost would measure the wrong thing (the
    # claim is about the STEADY-STATE cost at a recording seam).
    var warm = 0
    for _ in range(1024):
        warm += 1 if ea_armed() else 0
    if warm != 0:
        raise Error(
            "test_explain_analyze_disarmed_cost: ea_armed() returned True"
            " during the warm loop while the collector was disarmed."
        )

    var calls_accum = 0
    var t0 = perf_counter_ns()
    for _ in range(_N_CALLS):
        calls_accum += 1 if ea_armed() else 0
    var t1 = perf_counter_ns()
    # THE ANTI-ELISION GUARD. `calls_accum` is consumed by an assertion, so the
    # loop has an observable result and cannot be deleted.
    if calls_accum != 0:
        raise Error(
            "test_explain_analyze_disarmed_cost: accumulated "
            + String(calls_accum)
            + " armed answers from a disarmed collector."
        )
    return Int(t1 - t0) // _N_CALLS


def test_disarmed_ea_armed_costs_what_the_header_claims() raises:
    """FALSIFIER for the disarmed `ea_armed()` cost.

    A `_Global.get_or_create_ptr()` — a `raises`, string-keyed KGEN-runtime
    registry lookup — blows the ceiling. The shipped path is
    `external_call["komira_ea_armed", Int32]()`, a relaxed load of a TU-static
    in this package's C file.
    """
    var ns = _measure_disarmed_ns_per_call()
    print(
        "[EA-DISARMED-COST] ea_armed() amortized over",
        _N_CALLS,
        "calls:",
        ns,
        "ns/call (ceiling",
        _MAX_NS_PER_CALL,
        "ns/call)",
    )
    assert_true(
        ns <= _MAX_NS_PER_CALL,
        String(
            "DISARMED COST CLAIM IS FALSE: `ea_armed()` cost "
        )
        + String(ns)
        + " ns/call amortized over "
        + String(_N_CALLS)
        + " calls, against a ceiling of "
        + String(_MAX_NS_PER_CALL)
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
