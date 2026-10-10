# =============================================================================
# Tests for SelectionInterval (komira_parquet.selection_vector)
# =============================================================================
#
# Covers:
#   - from_bool_mask: all True, all False, alternating, single True
#   - all(n): one interval of given length
#   - intervals_total_selected: sum across intervals
#   - boolean_to_intervals: append to existing list
#   - boolean_to_indices: fallback index list
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap
from komira_parquet.selection_vector import (
    SelectionInterval,
    intervals_total_selected,
    boolean_to_intervals,
    boolean_to_indices,
)


def _mask_from_bits(bits: List[Bool]) raises -> BooleanArray:
    var arr = BooleanArray.allocate(len(bits))
    for i in range(len(bits)):
        if bits[i]:
            arr.data.set(i)
    return arr^


def test_from_bool_mask_all_true() raises:
    """All True: single interval (skip=0, select=n)."""
    var bits: List[Bool] = [True, True, True, True]
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 1)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 4)


def test_from_bool_mask_all_false() raises:
    """All False: zero intervals emitted (only a trailing pending_skip)."""
    var bits: List[Bool] = [False, False, False]
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 0)


def test_from_bool_mask_alternating() raises:
    """Alternating T/F/T/F produces 1-row select intervals with skip separators."""
    var bits: List[Bool] = [True, False, True, False, True]
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    # Runs: T(1), F(1), T(1), F(1), T(1).  Skips accumulate before the next T.
    assert_equal(len(intervals), 3)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 1)
    assert_equal(Int(intervals[1].skip), 1)
    assert_equal(Int(intervals[1].select), 1)
    assert_equal(Int(intervals[2].skip), 1)
    assert_equal(Int(intervals[2].select), 1)


def test_from_bool_mask_single_true_in_middle() raises:
    """FFFTFF: skip=3, select=1; trailing Fs emit no interval."""
    var bits: List[Bool] = [False, False, False, True, False, False]
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 1)
    assert_equal(Int(intervals[0].skip), 3)
    assert_equal(Int(intervals[0].select), 1)


def test_from_bool_mask_run_then_gap_then_run() raises:
    """TTFFFTT produces two intervals."""
    var bits: List[Bool] = [True, True, False, False, False, True, True]
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 2)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 2)
    assert_equal(Int(intervals[1].skip), 3)
    assert_equal(Int(intervals[1].select), 2)


def test_all_helper() raises:
    """SelectionInterval.all(n) returns one interval covering n rows."""
    var intervals = SelectionInterval.all(UInt32(100))
    assert_equal(len(intervals), 1)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 100)


def test_all_zero() raises:
    """SelectionInterval.all(0) returns zero intervals."""
    var intervals = SelectionInterval.all(UInt32(0))
    assert_equal(len(intervals), 0)


def test_intervals_total_selected() raises:
    """intervals_total_selected sums `select` across intervals."""
    var xs = List[SelectionInterval]()
    xs.append(SelectionInterval(UInt32(0), UInt32(3)))
    xs.append(SelectionInterval(UInt32(2), UInt32(5)))
    xs.append(SelectionInterval(UInt32(1), UInt32(7)))
    var total = intervals_total_selected(Span(xs))
    assert_equal(Int(total), 15)


def test_intervals_total_selected_empty() raises:
    var xs = List[SelectionInterval]()
    var total = intervals_total_selected(Span(xs))
    assert_equal(Int(total), 0)


def test_boolean_to_intervals_appends() raises:
    """boolean_to_intervals appends to existing list (does not clear)."""
    var xs = List[SelectionInterval]()
    xs.append(SelectionInterval(UInt32(9), UInt32(9)))  # sentinel
    var bits: List[Bool] = [True, True]
    var mask = _mask_from_bits(bits)
    boolean_to_intervals(mask, xs)
    assert_equal(len(xs), 2)
    # Sentinel preserved:
    assert_equal(Int(xs[0].skip), 9)
    assert_equal(Int(xs[0].select), 9)
    # Appended interval:
    assert_equal(Int(xs[1].skip), 0)
    assert_equal(Int(xs[1].select), 2)


def test_boolean_to_indices() raises:
    """boolean_to_indices returns positions of True bits."""
    var bits: List[Bool] = [False, True, False, True, True, False]
    var mask = _mask_from_bits(bits)
    var idx = boolean_to_indices(mask)
    assert_equal(len(idx), 3)
    assert_equal(Int(idx[0]), 1)
    assert_equal(Int(idx[1]), 3)
    assert_equal(Int(idx[2]), 4)


def test_boolean_to_indices_all_false() raises:
    var bits: List[Bool] = [False, False, False]
    var mask = _mask_from_bits(bits)
    var idx = boolean_to_indices(mask)
    assert_equal(len(idx), 0)


# =============================================================================
# SIMD u64 word-walk fast paths.
# Cover the AllZero / AllOne / Mixed branches + boundary alignments.
# Verified against scalar-equivalent expectations.
# =============================================================================


def test_simd_all_zero_64() raises:
    """64 False bits — AllZero u64 fast path; should emit zero intervals."""
    var bits = List[Bool]()
    for _ in range(64):
        bits.append(False)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 0)


def test_simd_all_one_64() raises:
    """64 True bits — AllOne u64 fast path; one interval skip=0 select=64."""
    var bits = List[Bool]()
    for _ in range(64):
        bits.append(True)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 1)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 64)


def test_simd_all_one_128_two_words() raises:
    """128 True bits — two AllOne words; runs should COALESCE into one
    single interval (run_select += 64 across both words, no flush in between)."""
    var bits = List[Bool]()
    for _ in range(128):
        bits.append(True)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 1)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 128)


def test_simd_zero_then_one_two_words() raises:
    """64 False then 64 True — AllZero word followed by AllOne word.
    One interval skip=64 select=64."""
    var bits = List[Bool]()
    for _ in range(64):
        bits.append(False)
    for _ in range(64):
        bits.append(True)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 1)
    assert_equal(Int(intervals[0].skip), 64)
    assert_equal(Int(intervals[0].select), 64)


def test_simd_one_then_zero_two_words() raises:
    """64 True then 64 False — AllOne word followed by AllZero word.
    One interval skip=0 select=64; trailing Falses do not emit."""
    var bits = List[Bool]()
    for _ in range(64):
        bits.append(True)
    for _ in range(64):
        bits.append(False)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 1)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 64)


def test_simd_one_zero_one_three_words() raises:
    """64 True / 64 False / 64 True — AllOne, AllZero (flush), AllOne."""
    var bits = List[Bool]()
    for _ in range(64):
        bits.append(True)
    for _ in range(64):
        bits.append(False)
    for _ in range(64):
        bits.append(True)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 2)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 64)
    assert_equal(Int(intervals[1].skip), 64)
    assert_equal(Int(intervals[1].select), 64)


def test_simd_mixed_word_alternating() raises:
    """64 alternating T/F bits — Mixed word, scalar walk."""
    var bits = List[Bool]()
    for i in range(64):
        bits.append(i % 2 == 0)  # T at even, F at odd
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    # 32 single-True intervals.
    assert_equal(len(intervals), 32)
    for i in range(32):
        if i == 0:
            assert_equal(Int(intervals[i].skip), 0)
        else:
            assert_equal(Int(intervals[i].skip), 1)
        assert_equal(Int(intervals[i].select), 1)


def test_simd_mixed_at_word_boundary() raises:
    """A run that straddles a u64-word boundary: positions 60..70.
    Should produce one contiguous interval skip=60 select=11."""
    var bits = List[Bool]()
    for i in range(128):
        if i >= 60 and i < 71:
            bits.append(True)
        else:
            bits.append(False)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 1)
    assert_equal(Int(intervals[0].skip), 60)
    assert_equal(Int(intervals[0].select), 11)


def test_simd_byte_tail_path() raises:
    """68 bits = 1 full u64 (64) + 4-bit tail. Hits the bit-tail path (no
    whole byte past the word; the byte tail is in test_selection_vector_direct)."""
    var bits = List[Bool]()
    # 64 trues
    for _ in range(64):
        bits.append(True)
    # 4-bit tail: T F T F  → run extends one bit past 64 to 65, then F flush
    bits.append(True)
    bits.append(False)
    bits.append(True)
    bits.append(False)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 2)
    # First: skip=0, select=65
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 65)
    # Second: skip=1, select=1 (the lone T at index 66)
    assert_equal(Int(intervals[1].skip), 1)
    assert_equal(Int(intervals[1].select), 1)


def test_simd_bit_tail_only() raises:
    """7 bits — full_bytes=0; only the bit-tail path runs."""
    var bits: List[Bool] = [True, False, True, True, False, True, False]
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    # T F TT F T F  → intervals: (0,1), (1,2), (1,1)
    assert_equal(len(intervals), 3)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 1)
    assert_equal(Int(intervals[1].skip), 1)
    assert_equal(Int(intervals[1].select), 2)
    assert_equal(Int(intervals[2].skip), 1)
    assert_equal(Int(intervals[2].select), 1)


def test_simd_zero_word_after_run_flushes() raises:
    """Mixed run in word 1, then AllZero word 2 — the flush path inside
    the AllZero branch must emit the in-flight interval (regression guard
    for the run-extending-into-zero-word edge)."""
    var bits = List[Bool]()
    # word 0: 60 zeros + 4 ones (mixed).
    for _ in range(60):
        bits.append(False)
    for _ in range(4):
        bits.append(True)
    # word 1: 64 zeros (AllZero — must flush the mixed-word run).
    for _ in range(64):
        bits.append(False)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 1)
    assert_equal(Int(intervals[0].skip), 60)
    assert_equal(Int(intervals[0].select), 4)


def test_simd_one_word_then_zero_word_then_one_word() raises:
    """Coalescing edge: AllOne -> AllZero (flush) -> AllOne -> end."""
    var bits = List[Bool]()
    for _ in range(64):
        bits.append(True)
    for _ in range(64):
        bits.append(False)
    for _ in range(64):
        bits.append(True)
    var mask = _mask_from_bits(bits)
    var intervals = SelectionInterval.from_bool_mask(mask)
    assert_equal(len(intervals), 2)
    assert_equal(Int(intervals[0].skip), 0)
    assert_equal(Int(intervals[0].select), 64)
    assert_equal(Int(intervals[1].skip), 64)
    assert_equal(Int(intervals[1].select), 64)


def test_simd_match_scalar_random_5000() raises:
    """SIMD output equals scalar output on a 5000-bit deterministic mask."""
    from komira_parquet.selection_vector import _boolean_to_intervals_scalar

    var bits = List[Bool]()
    # Deterministic pseudo-random pattern using a simple LCG.
    var seed: UInt64 = 0xDEADBEEFCAFEBABE
    for _ in range(5000):
        seed = seed * UInt64(6364136223846793005) + UInt64(1442695040888963407)
        bits.append((seed >> UInt64(33)) & UInt64(1) == UInt64(1))

    var mask_a = _mask_from_bits(bits)
    var mask_b = _mask_from_bits(bits)

    var simd_out = List[SelectionInterval]()
    boolean_to_intervals(mask_a, simd_out)

    var scalar_out = List[SelectionInterval]()
    _boolean_to_intervals_scalar(mask_b, scalar_out)

    assert_equal(len(simd_out), len(scalar_out))
    for i in range(len(simd_out)):
        assert_equal(Int(simd_out[i].skip), Int(scalar_out[i].skip))
        assert_equal(Int(simd_out[i].select), Int(scalar_out[i].select))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
