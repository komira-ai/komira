# =============================================================================
# test_median_aggregator — MedianAggregator + MedianState unit tests
# =============================================================================
#
# Item 19b H2O Q6 real-query. MedianAggregator uses a
# fixed-capacity inline reservoir of Float64 values (capacity 64) so
# the per-group state is POD (gap6-safe inside the byte-Slab). Cap
# reduced 128→64 by Tier S Fix #3 (v0.4 perf sweep).
#
# Test cases:
#   T1 — `init` returns zero state (count == 0).
#   T2 — single update: count == 1, median == single value.
#   T3 — odd count: median([1,2,3]) == 2.0.
#   T4 — even count: median([1,2,3,4]) == 2.5.
#   T5 — combine: two halves merge to same result as single pass.
#   T6 — empty state: finalize → NaN (count == 0).
#   T7 — near-capacity: 63 values, correct median.
#   T8 — at-capacity: exactly 64 values, correct median.
#   T9 — overflow: 200 updates, count clamped at 64 (FIRST-64 retention).
#   T10 — combine respects capacity (donor partially absorbed).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_engine_operators.unified.agg.storage.aggregators_struct_builtin import (
    MAX_MEDIAN_VALUES,
    MedianAggregator,
    MedianState,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _abs(x: Float64) -> Float64:
    if x < Float64(0.0):
        return -x
    return x


def _approx_equal(a: Float64, b: Float64, tol: Float64 = 1e-9) -> Bool:
    var diff = _abs(a - b)
    if diff <= tol:
        return True
    var mag = _abs(a) + _abs(b)
    return diff <= tol * mag


# -----------------------------------------------------------------------------
# T1 — init returns zero state
# -----------------------------------------------------------------------------


def test_T1_init_returns_zero_state() raises:
    var s = MedianAggregator.init()
    assert_equal(s.count, Int32(0))
    # Constant assertion — ensure capacity matches the documented value.
    assert_equal(MAX_MEDIAN_VALUES, 64)


# -----------------------------------------------------------------------------
# T2 — single update
# -----------------------------------------------------------------------------


def test_T2_single_update() raises:
    """After one update(x): count=1, median == x."""
    var s = MedianAggregator.init()
    MedianAggregator.update(s, Float64(42.5))
    assert_equal(s.count, Int32(1))
    var r = MedianAggregator.finalize(s)
    assert_true(_approx_equal(Float64(r), Float64(42.5)))


# -----------------------------------------------------------------------------
# T3 — odd count median
# -----------------------------------------------------------------------------


def test_T3_odd_count_median() raises:
    """median([1,2,3]) == 2.0 (middle element)."""
    var s = MedianAggregator.init()
    MedianAggregator.update(s, Float64(1.0))
    MedianAggregator.update(s, Float64(2.0))
    MedianAggregator.update(s, Float64(3.0))
    assert_equal(s.count, Int32(3))
    var r = MedianAggregator.finalize(s)
    assert_true(_approx_equal(Float64(r), Float64(2.0)))


def test_T3b_odd_count_median_unsorted() raises:
    """median([5,1,9,3,7]) == 5.0 (sorted: [1,3,5,7,9])."""
    var s = MedianAggregator.init()
    MedianAggregator.update(s, Float64(5.0))
    MedianAggregator.update(s, Float64(1.0))
    MedianAggregator.update(s, Float64(9.0))
    MedianAggregator.update(s, Float64(3.0))
    MedianAggregator.update(s, Float64(7.0))
    var r = MedianAggregator.finalize(s)
    assert_true(_approx_equal(Float64(r), Float64(5.0)))


# -----------------------------------------------------------------------------
# T4 — even count median
# -----------------------------------------------------------------------------


def test_T4_even_count_median() raises:
    """median([1,2,3,4]) == 2.5 (avg of middle two)."""
    var s = MedianAggregator.init()
    MedianAggregator.update(s, Float64(1.0))
    MedianAggregator.update(s, Float64(2.0))
    MedianAggregator.update(s, Float64(3.0))
    MedianAggregator.update(s, Float64(4.0))
    assert_equal(s.count, Int32(4))
    var r = MedianAggregator.finalize(s)
    assert_true(_approx_equal(Float64(r), Float64(2.5)))


def test_T4b_even_count_median_unsorted() raises:
    """median([10,2,8,4,6,12]) == 7.0 (sorted: [2,4,6,8,10,12], avg of 6+8)."""
    var s = MedianAggregator.init()
    MedianAggregator.update(s, Float64(10.0))
    MedianAggregator.update(s, Float64(2.0))
    MedianAggregator.update(s, Float64(8.0))
    MedianAggregator.update(s, Float64(4.0))
    MedianAggregator.update(s, Float64(6.0))
    MedianAggregator.update(s, Float64(12.0))
    var r = MedianAggregator.finalize(s)
    assert_true(_approx_equal(Float64(r), Float64(7.0)))


# -----------------------------------------------------------------------------
# T5 — combine: two halves merge to same result as single pass
# -----------------------------------------------------------------------------


def test_T5_combine_halves_match_single_pass() raises:
    """A 60-element sequence split 30+30, combined, must produce the
    same median as a single-pass pipeline. 60 < 64 so no truncation.
    """
    var single = MedianAggregator.init()
    for i in range(60):
        MedianAggregator.update(single, Float64(i))
    var ref_val = MedianAggregator.finalize(single)

    var a = MedianAggregator.init()
    for i in range(30):
        MedianAggregator.update(a, Float64(i))
    var b = MedianAggregator.init()
    for i in range(30, 60):
        MedianAggregator.update(b, Float64(i))

    MedianAggregator.combine(a, b)
    assert_equal(a.count, Int32(60))
    var combined_val = MedianAggregator.finalize(a)
    assert_true(_approx_equal(Float64(combined_val), Float64(ref_val)))


def test_T5b_combine_zero_donor_is_noop() raises:
    var accum = MedianAggregator.init()
    MedianAggregator.update(accum, Float64(1.0))
    MedianAggregator.update(accum, Float64(2.0))
    MedianAggregator.update(accum, Float64(3.0))
    var saved_count = accum.count

    var zero_donor = MedianAggregator.init()
    MedianAggregator.combine(accum, zero_donor)
    assert_equal(accum.count, saved_count)
    var r = MedianAggregator.finalize(accum)
    assert_true(_approx_equal(Float64(r), Float64(2.0)))


# -----------------------------------------------------------------------------
# T6 — empty state: finalize → NaN
# -----------------------------------------------------------------------------


def test_T6_empty_state_finalize_returns_nan() raises:
    var s = MedianAggregator.init()
    var r = MedianAggregator.finalize(s)
    # NaN: self-inequality.
    assert_true(r != r)


# -----------------------------------------------------------------------------
# T7 — near-capacity: 63 values, correct median
# -----------------------------------------------------------------------------


def test_T7_near_capacity_63_values() raises:
    """63 sequential values [0..63): odd count, median = buf[31] = 31.0."""
    var s = MedianAggregator.init()
    for i in range(63):
        MedianAggregator.update(s, Float64(i))
    assert_equal(s.count, Int32(63))
    var r = MedianAggregator.finalize(s)
    # Sorted = [0..63), middle index = 63 // 2 = 31 → 31.0.
    assert_true(_approx_equal(Float64(r), Float64(31.0)))


# -----------------------------------------------------------------------------
# T8 — at-capacity: exactly 64 values, correct median
# -----------------------------------------------------------------------------


def test_T8_at_capacity_64_values() raises:
    """64 sequential values [0..64): even count, median = (31+32)/2 = 31.5."""
    var s = MedianAggregator.init()
    for i in range(64):
        MedianAggregator.update(s, Float64(i))
    assert_equal(s.count, Int32(64))
    var r = MedianAggregator.finalize(s)
    assert_true(_approx_equal(Float64(r), Float64(31.5)))


# -----------------------------------------------------------------------------
# T9 — overflow: 200 updates, count clamped at 64
# -----------------------------------------------------------------------------


def test_T9_overflow_clamped_at_capacity() raises:
    """Push 200 sequential values: count saturates at 64. FIRST-64
    retention means the buffer holds [0..64); median = 31.5.
    """
    var s = MedianAggregator.init()
    for i in range(200):
        MedianAggregator.update(s, Float64(i))
    # Must not crash; count clamped at 64.
    assert_equal(s.count, Int32(64))
    var r = MedianAggregator.finalize(s)
    # Buffer = [0..64); even count → (31 + 32)/2 = 31.5.
    assert_true(_approx_equal(Float64(r), Float64(31.5)))


# -----------------------------------------------------------------------------
# T10 — combine respects capacity (donor partially absorbed)
# -----------------------------------------------------------------------------


def test_T10_combine_respects_capacity() raises:
    """accum has 50 values; donor has 50 values. Combined should
    take min(14, 50) = 14 from donor (room = 64 - 50 = 14).
    Final count = 64. No crash.
    """
    var accum = MedianAggregator.init()
    for i in range(50):
        MedianAggregator.update(accum, Float64(i))
    var donor = MedianAggregator.init()
    for i in range(1000, 1050):
        MedianAggregator.update(donor, Float64(i))

    MedianAggregator.combine(accum, donor)
    assert_equal(accum.count, Int32(64))
    # No crash; semantic correctness is "combine does not exceed cap".


def test_T10b_combine_into_full_accum_is_noop() raises:
    """If accum is already at capacity, combine must be a no-op."""
    var accum = MedianAggregator.init()
    for i in range(64):
        MedianAggregator.update(accum, Float64(i))
    var donor = MedianAggregator.init()
    MedianAggregator.update(donor, Float64(9999.0))

    MedianAggregator.combine(accum, donor)
    assert_equal(accum.count, Int32(64))
    var r = MedianAggregator.finalize(accum)
    # Buffer untouched: median = 31.5.
    assert_true(_approx_equal(Float64(r), Float64(31.5)))


# -----------------------------------------------------------------------------
# T11 — STATE_BYTES contract
# -----------------------------------------------------------------------------


def test_T11_state_bytes_constant() raises:
    """`STATE_BYTES` must equal sizeof[MedianState](). Asserted via the
    documented constant; the storage layer relies on this for stride
    math on the byte-Slab.
    """
    assert_equal(MedianAggregator.STATE_BYTES, 520)


# -----------------------------------------------------------------------------
# Test runner
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_T1_init_returns_zero_state]()
    suite.test[test_T2_single_update]()
    suite.test[test_T3_odd_count_median]()
    suite.test[test_T3b_odd_count_median_unsorted]()
    suite.test[test_T4_even_count_median]()
    suite.test[test_T4b_even_count_median_unsorted]()
    suite.test[test_T5_combine_halves_match_single_pass]()
    suite.test[test_T5b_combine_zero_donor_is_noop]()
    suite.test[test_T6_empty_state_finalize_returns_nan]()
    suite.test[test_T7_near_capacity_63_values]()
    suite.test[test_T8_at_capacity_64_values]()
    suite.test[test_T9_overflow_clamped_at_capacity]()
    suite.test[test_T10_combine_respects_capacity]()
    suite.test[test_T10b_combine_into_full_accum_is_noop]()
    suite.test[test_T11_state_bytes_constant]()
    suite^.run()
