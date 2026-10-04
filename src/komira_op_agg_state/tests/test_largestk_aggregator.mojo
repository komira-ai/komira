# =============================================================================
# test_largestk_aggregator — LargestKAggregator (K=2) regression suite
# =============================================================================
#
# Item 19b regression suite for the top-K-largest per-group kernel
# `LargestKAggregator` (with `LargestKState` 24-byte min-heap state).
# K is hardcoded to 2 (H2O Q8's `largest2(v3)` query is the only consumer).
#
# Test cases:
#   T1 — `init` returns zero state (count=0, heap=[0.0, 0.0]).
#   T2 — single update: largest2([5.0]) -> count=1, heap[0]=5.0; finalize=5.0.
#   T3 — two updates ascending: largest2([3.0, 5.0]) -> heap[0]=3, heap[1]=5;
#        finalize=5.0 (heap max = larger of top-2).
#   T4 — two updates descending: largest2([5.0, 3.0]) -> heap[0]=3, heap[1]=5
#        (min-heap invariant: smaller at root).
#   T5 — three updates with eviction: largest2([3, 5, 1]) -> [3, 5];
#        the 1.0 is below the current min (3.0) and rejected.
#   T6 — three updates with replacement: largest2([3, 5, 7]) -> [5, 7];
#        7.0 evicts 3.0; min-heap restores 5 at root.
#   T7 — combine equivalence: split a 100-row sequence in half, combine
#        partials, verify same top-2 as single pass.
#   T8 — combine with empty donor: no-op.
#   T9 — combine with empty accum: takes donor.
#   T10 — finalize on empty state: NaN.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_state.aggregators_struct_builtin import (
    LargestKAggregator,
    LargestKState,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _abs(x: Float64) -> Float64:
    if x < Float64(0.0):
        return -x
    return x


def _approx_equal(a: Float64, b: Float64, tol: Float64 = 1e-12) -> Bool:
    return _abs(a - b) <= tol


# -----------------------------------------------------------------------------
# T1 — init returns zero state
# -----------------------------------------------------------------------------


def test_T1_init_returns_zero_state() raises:
    var s = LargestKAggregator.init()
    assert_equal(s.count, Int32(0))
    assert_true(s.heap[0] == Float64(0.0))
    assert_true(s.heap[1] == Float64(0.0))


# -----------------------------------------------------------------------------
# T2 — single update
# -----------------------------------------------------------------------------


def test_T2_single_update() raises:
    """After one update(5.0): count=1, heap[0]=5.0, finalize=5.0."""
    var s = LargestKAggregator.init()
    LargestKAggregator.update(s, Float64(5.0))
    assert_equal(s.count, Int32(1))
    assert_true(s.heap[0] == Float64(5.0))
    var r = LargestKAggregator.finalize(s)
    assert_true(Float64(r) == Float64(5.0))


# -----------------------------------------------------------------------------
# T3 — two updates ascending
# -----------------------------------------------------------------------------


def test_T3_two_updates_ascending() raises:
    """largest2([3.0, 5.0]) -> heap[0]=3, heap[1]=5; finalize=5.0."""
    var s = LargestKAggregator.init()
    LargestKAggregator.update(s, Float64(3.0))
    LargestKAggregator.update(s, Float64(5.0))
    assert_equal(s.count, Int32(2))
    # Min-heap invariant: smaller at root.
    assert_true(s.heap[0] == Float64(3.0))
    assert_true(s.heap[1] == Float64(5.0))
    var r = LargestKAggregator.finalize(s)
    assert_true(Float64(r) == Float64(5.0))


# -----------------------------------------------------------------------------
# T4 — two updates descending (heap orders min at root)
# -----------------------------------------------------------------------------


def test_T4_two_updates_descending() raises:
    """largest2([5.0, 3.0]) -> heap reorganizes to [3, 5]."""
    var s = LargestKAggregator.init()
    LargestKAggregator.update(s, Float64(5.0))
    LargestKAggregator.update(s, Float64(3.0))
    assert_equal(s.count, Int32(2))
    # Min-heap invariant: 3 at root, 5 at slot 1.
    assert_true(s.heap[0] == Float64(3.0))
    assert_true(s.heap[1] == Float64(5.0))
    var r = LargestKAggregator.finalize(s)
    assert_true(Float64(r) == Float64(5.0))


# -----------------------------------------------------------------------------
# T5 — three updates with eviction (smaller value rejected)
# -----------------------------------------------------------------------------


def test_T5_three_updates_eviction() raises:
    """largest2([3, 5, 1]) -> still [3, 5]; the 1.0 doesn't beat min=3."""
    var s = LargestKAggregator.init()
    LargestKAggregator.update(s, Float64(3.0))
    LargestKAggregator.update(s, Float64(5.0))
    LargestKAggregator.update(s, Float64(1.0))
    assert_equal(s.count, Int32(2))
    assert_true(s.heap[0] == Float64(3.0))
    assert_true(s.heap[1] == Float64(5.0))
    var r = LargestKAggregator.finalize(s)
    assert_true(Float64(r) == Float64(5.0))


# -----------------------------------------------------------------------------
# T6 — three updates with replacement (larger value evicts old min)
# -----------------------------------------------------------------------------


def test_T6_three_updates_replacement() raises:
    """largest2([3, 5, 7]) -> [5, 7]; 7 evicts 3; heap restores 5 at root."""
    var s = LargestKAggregator.init()
    LargestKAggregator.update(s, Float64(3.0))
    LargestKAggregator.update(s, Float64(5.0))
    LargestKAggregator.update(s, Float64(7.0))
    assert_equal(s.count, Int32(2))
    # New min-heap: 5 at root, 7 at slot 1.
    assert_true(s.heap[0] == Float64(5.0))
    assert_true(s.heap[1] == Float64(7.0))
    var r = LargestKAggregator.finalize(s)
    assert_true(Float64(r) == Float64(7.0))


# -----------------------------------------------------------------------------
# T7 — combine equivalence: split-merge matches single-pass
# -----------------------------------------------------------------------------


def test_T7_combine_split_merge_equivalence() raises:
    """Split a 100-row sequence in half; combine partials; assert
    combined top-2 matches the single-pass top-2.

    Sequence: i*1.5 for i in [0, 100) — strictly increasing, so the
    correct top-2 is the last two values: 99*1.5=148.5 and 98*1.5=147.0.
    """
    # Single pass.
    var ref_state = LargestKAggregator.init()
    for i in range(100):
        LargestKAggregator.update(ref_state, Float64(i) * Float64(1.5))

    # Two halves.
    var a = LargestKAggregator.init()
    for i in range(50):
        LargestKAggregator.update(a, Float64(i) * Float64(1.5))

    var b = LargestKAggregator.init()
    for i in range(50, 100):
        LargestKAggregator.update(b, Float64(i) * Float64(1.5))

    LargestKAggregator.combine(a, b)

    assert_equal(a.count, ref_state.count)
    var ref_max = LargestKAggregator.finalize(ref_state)
    var combined_max = LargestKAggregator.finalize(a)
    assert_true(_approx_equal(Float64(ref_max), Float64(combined_max)))
    # Sanity: the actual top-2 should be 99*1.5=148.5 and 98*1.5=147.0.
    assert_true(Float64(combined_max) == Float64(99) * Float64(1.5))


def test_T7b_combine_random_order() raises:
    """Combine equivalence with a non-monotonic sequence — values that
    bounce around exercise both eviction branches in update."""
    # Single pass.
    var ref_state = LargestKAggregator.init()
    var values = List[Float64]()
    values.append(Float64(2.0))
    values.append(Float64(7.0))
    values.append(Float64(1.0))
    values.append(Float64(9.0))
    values.append(Float64(4.0))
    values.append(Float64(8.0))
    values.append(Float64(3.0))
    values.append(Float64(6.0))
    values.append(Float64(5.0))
    for i in range(len(values)):
        LargestKAggregator.update(ref_state, values[i])

    # Two halves: [0:5] and [5:].
    var a = LargestKAggregator.init()
    for i in range(5):
        LargestKAggregator.update(a, values[i])
    var b = LargestKAggregator.init()
    for i in range(5, len(values)):
        LargestKAggregator.update(b, values[i])
    LargestKAggregator.combine(a, b)

    # Expected top-2 of the full set: 9.0 and 8.0 — finalize returns 9.0.
    assert_equal(a.count, Int32(2))
    assert_true(_approx_equal(
        Float64(LargestKAggregator.finalize(a)), Float64(9.0)
    ))
    assert_true(_approx_equal(
        Float64(LargestKAggregator.finalize(ref_state)), Float64(9.0)
    ))


# -----------------------------------------------------------------------------
# T8 — combine with empty donor is a no-op
# -----------------------------------------------------------------------------


def test_T8_combine_empty_donor_noop() raises:
    var accum = LargestKAggregator.init()
    LargestKAggregator.update(accum, Float64(10.0))
    LargestKAggregator.update(accum, Float64(20.0))
    var saved_count = accum.count
    var saved_h0 = accum.heap[0]
    var saved_h1 = accum.heap[1]

    var empty = LargestKAggregator.init()
    LargestKAggregator.combine(accum, empty)

    assert_equal(accum.count, saved_count)
    assert_true(accum.heap[0] == saved_h0)
    assert_true(accum.heap[1] == saved_h1)


# -----------------------------------------------------------------------------
# T9 — combine with empty accum takes donor
# -----------------------------------------------------------------------------


def test_T9_combine_empty_accum_takes_donor() raises:
    var donor = LargestKAggregator.init()
    LargestKAggregator.update(donor, Float64(11.0))
    LargestKAggregator.update(donor, Float64(22.0))

    var accum = LargestKAggregator.init()
    LargestKAggregator.combine(accum, donor)

    assert_equal(accum.count, Int32(2))
    # Both donor values should now live in accum (heap order
    # equivalent: smaller at root).
    assert_true(accum.heap[0] == Float64(11.0))
    assert_true(accum.heap[1] == Float64(22.0))
    var r = LargestKAggregator.finalize(accum)
    assert_true(Float64(r) == Float64(22.0))


# -----------------------------------------------------------------------------
# T10 — finalize on empty state returns NaN
# -----------------------------------------------------------------------------


def test_T10_finalize_empty_returns_nan() raises:
    var s = LargestKAggregator.init()
    var r = LargestKAggregator.finalize(s)
    # NaN: self-inequality.
    assert_true(r != r)


# -----------------------------------------------------------------------------
# Test runner
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_T1_init_returns_zero_state]()
    suite.test[test_T2_single_update]()
    suite.test[test_T3_two_updates_ascending]()
    suite.test[test_T4_two_updates_descending]()
    suite.test[test_T5_three_updates_eviction]()
    suite.test[test_T6_three_updates_replacement]()
    suite.test[test_T7_combine_split_merge_equivalence]()
    suite.test[test_T7b_combine_random_order]()
    suite.test[test_T8_combine_empty_donor_noop]()
    suite.test[test_T9_combine_empty_accum_takes_donor]()
    suite.test[test_T10_finalize_empty_returns_nan]()
    suite^.run()
