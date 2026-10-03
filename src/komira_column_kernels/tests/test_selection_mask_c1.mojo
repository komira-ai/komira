# =============================================================================
# Test: selection-mask infrastructure (late-materialization short-circuit)
# =============================================================================
#
# Verifies the RecordBatch._selection_mask field, accessor methods, and
# the `materialize_selection_if_present` defensive helper that consumers
# call to perform the gather when they do not honor masks natively.
#
# Cases:
#   1. Default: no mask attached. has_selection_mask() -> False.
#   2. Set/take: round-trip mask attach + extract preserves the value.
#   3. selection_mask_true_count(): correct under None / partial / full.
#   4. materialize_selection_if_present at 0% selectivity -> empty batch.
#   5. materialize_selection_if_present at 50% selectivity -> half rows.
#   6. materialize_selection_if_present at 95% selectivity -> 95% rows.
#   7. materialize_selection_if_present at 100% selectivity -> all rows,
#      mask cleared.
#   8. materialize on a no-mask batch is a no-op.
#   9. Length-mismatch mask raises.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_equal, assert_raises

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_column_kernels.compiler_helpers import materialize_selection_if_present


def _make_int64_batch(num_rows: Int) raises -> RecordBatch:
    """Build a 1-column INT64 RecordBatch with values [0..num_rows)."""
    var arr = PrimitiveArray[DType.int64].allocate(num_rows)
    var p = arr._typed_ptr_mut()
    for i in range(num_rows):
        (p + i)[] = Int64(i)
    var builder = RecordBatchBuilder.with_capacity(1)
    builder.add_column(Column.from_primitive(arr^))
    var sb = SchemaBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    var schema = sb.build()
    return builder.build(schema^)


def _bitmap_with_truth_pattern(
    length: Int, true_count: Int
) raises -> BooleanArray:
    """Build a BooleanArray of `length` bits with the FIRST `true_count`
    bits set to 1 and the rest 0. Deterministic for test correctness.
    """
    var bm = Bitmap.create(length)
    for i in range(length):
        if i < true_count:
            bm.set(i)
        else:
            bm.clear(i)
    return BooleanArray.from_bitmap(bm^)


def test_default_no_mask() raises:
    """Case 1: a freshly-built RecordBatch has no selection mask."""
    var batch = _make_int64_batch(10)
    assert_true(not batch.has_selection_mask())
    assert_equal(batch.selection_mask_true_count(), 10)
    _ = batch^


def test_set_and_take_mask() raises:
    """Case 2: set_selection_mask / take_selection_mask round-trip."""
    var batch = _make_int64_batch(8)
    var mask = _bitmap_with_truth_pattern(8, 5)
    batch.set_selection_mask(mask^)
    assert_true(batch.has_selection_mask())
    assert_equal(batch.selection_mask_true_count(), 5)
    var taken_opt = batch.take_selection_mask()
    assert_true(Bool(taken_opt))
    var taken = taken_opt.take()
    assert_equal(taken.true_count(), 5)
    assert_true(not batch.has_selection_mask())
    _ = batch^


def test_clear_mask() raises:
    """clear_selection_mask drops the mask without performing the gather."""
    var batch = _make_int64_batch(8)
    var mask = _bitmap_with_truth_pattern(8, 5)
    batch.set_selection_mask(mask^)
    assert_true(batch.has_selection_mask())
    batch.clear_selection_mask()
    assert_true(not batch.has_selection_mask())
    _ = batch^


def test_materialize_no_mask_is_noop() raises:
    """Case 8: materialize on a batch with no mask returns it unchanged."""
    var batch = _make_int64_batch(7)
    var out = materialize_selection_if_present(batch^)
    assert_equal(out.num_rows(), 7)
    assert_true(not out.has_selection_mask())
    _ = out^


def test_materialize_full_selectivity() raises:
    """Case 7: materialize at 100% selectivity returns all rows + clears mask."""
    var batch = _make_int64_batch(20)
    var mask = _bitmap_with_truth_pattern(20, 20)
    batch.set_selection_mask(mask^)
    var out = materialize_selection_if_present(batch^)
    assert_equal(out.num_rows(), 20)
    assert_true(not out.has_selection_mask())
    # Verify rows preserved.
    var col = out.column_at(0).as_primitive[DType.int64]()
    var p = col._typed_ptr_ro()
    for i in range(20):
        assert_equal(Int((p + i)[]), i)
    _ = out^


def test_materialize_zero_selectivity() raises:
    """Case 4: materialize at 0% selectivity returns empty batch + cleared mask."""
    var batch = _make_int64_batch(10)
    var mask = _bitmap_with_truth_pattern(10, 0)
    batch.set_selection_mask(mask^)
    var out = materialize_selection_if_present(batch^)
    assert_equal(out.num_rows(), 0)
    assert_true(not out.has_selection_mask())
    _ = out^


def test_materialize_half_selectivity() raises:
    """Case 5: materialize at 50% selectivity returns half rows
    (the FIRST half by construction of the truth-pattern bitmap)."""
    var batch = _make_int64_batch(20)
    var mask = _bitmap_with_truth_pattern(20, 10)
    batch.set_selection_mask(mask^)
    var out = materialize_selection_if_present(batch^)
    assert_equal(out.num_rows(), 10)
    assert_true(not out.has_selection_mask())
    var col = out.column_at(0).as_primitive[DType.int64]()
    var p = col._typed_ptr_ro()
    for i in range(10):
        assert_equal(Int((p + i)[]), i)
    _ = out^


def test_materialize_high_selectivity() raises:
    """Case 6: materialize at 95% selectivity returns 95% of rows.
    This is the target operating window (`>= 0.95`)."""
    var batch = _make_int64_batch(100)
    var mask = _bitmap_with_truth_pattern(100, 95)
    batch.set_selection_mask(mask^)
    var out = materialize_selection_if_present(batch^)
    assert_equal(out.num_rows(), 95)
    assert_true(not out.has_selection_mask())
    var col = out.column_at(0).as_primitive[DType.int64]()
    var p = col._typed_ptr_ro()
    for i in range(95):
        assert_equal(Int((p + i)[]), i)
    _ = out^


def test_set_mask_length_mismatch_raises() raises:
    """Case 9: set_selection_mask on a length-mismatched mask raises."""
    var batch = _make_int64_batch(10)
    var mask = _bitmap_with_truth_pattern(7, 4)
    with assert_raises():
        batch.set_selection_mask(mask^)
    _ = batch^


def main() raises:
    var suite = TestSuite()
    suite.test[test_default_no_mask]()
    suite.test[test_set_and_take_mask]()
    suite.test[test_clear_mask]()
    suite.test[test_materialize_no_mask_is_noop]()
    suite.test[test_materialize_full_selectivity]()
    suite.test[test_materialize_zero_selectivity]()
    suite.test[test_materialize_half_selectivity]()
    suite.test[test_materialize_high_selectivity]()
    suite.test[test_set_mask_length_mismatch_raises]()
    suite^.run()
