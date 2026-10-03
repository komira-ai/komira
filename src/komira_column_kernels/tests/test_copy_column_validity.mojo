# =============================================================================
# Tests for compiler_helpers.copy_column validity-bitmap rebuild
# =============================================================================
#
# The validity-bitmap rebuild path in `copy_column`:
#   1. Source has no validity bitmap   -> destination has none.
#   2. Source has validity, null_count==0 -> destination drops validity.
#      (Arrow allows omitting validity when null_count==0; this saves the
#      bitmap copy on hot join-build column copies.)
#   3. Source has validity with real nulls -> bulk-copy via
#      `Bitmap.copy_slice_from` (memcpy on byte-aligned offset, scalar
#      shift on misaligned). Bits and null_count are preserved.
#
# Coverage matrix below verifies all three paths plus the edge cases
# (zero rows, single row, alignment-misaligned).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder,
)
from komira_column_kernels.compiler_helpers import copy_column


# ---------------------------------------------------------------------------
# Helpers: build a 1-column RecordBatch with explicit validity state.
# ---------------------------------------------------------------------------


def _make_batch_int64_no_validity(values: List[Int64]) raises -> RecordBatch:
    """Build a 1-col INT64 batch with no validity bitmap (path 1)."""
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    var ptr = arr._typed_ptr_mut()
    for i in range(len(values)):
        ptr[i] = values[i]
    var col = Column.from_primitive(arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, False))
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(sb.build())


def _make_batch_int64_all_valid(values: List[Int64]) raises -> RecordBatch:
    """Build a 1-col INT64 batch with validity present, null_count==0 (path 2).

    This is the case the fast path optimizes: validity bitmap exists
    (because the source supplied one) but every bit is set.
    """
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(values))
    var ptr = arr._typed_ptr_mut()
    for i in range(len(values)):
        ptr[i] = values[i]
        # allocate_nullable initializes all bits to valid; null_count = 0.
    var col = Column.from_primitive(arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(sb.build())


def _make_batch_int64_with_nulls(
    values: List[Int64], null_indices: List[Int]
) raises -> RecordBatch:
    """Build a 1-col INT64 batch with explicit nulls (path 3).

    `null_indices` lists the row positions to mark null; the rest are
    valid. `null_count` is set accurately on the underlying array.
    """
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate_nullable(n)
    var ptr = arr._typed_ptr_mut()
    for i in range(n):
        ptr[i] = values[i]
    # Mark nulls.
    for j in range(len(null_indices)):
        var idx = null_indices[j]
        # _set_null bumps null_count itself; a manual `+= 1` would
        # double-count.
        arr._set_null(idx)
    var col = Column.from_primitive(arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    var b = RecordBatchBuilder()
    b.add_column(col^)
    return b.build(sb.build())


# ---------------------------------------------------------------------------
# Path 1: no source validity -> destination has no validity.
# ---------------------------------------------------------------------------


def test_copy_column_no_validity_source() raises:
    """Source without validity bitmap copies cleanly with no destination bitmap."""
    var vals: List[Int64] = [Int64(10), Int64(20), Int64(30), Int64(40), Int64(50)]
    var batch = _make_batch_int64_no_validity(vals)
    var col = copy_column(batch, 0)
    assert_equal(col._length, 5)
    assert_equal(col._null_count, 0)
    assert_false(Bool(col._validity), "no validity expected when source has none")
    # Values preserved.
    var view = col._data.view_ro()
    for i in range(5):
        assert_equal(Int(view.get_typed[Int64](i)), Int(vals[i]))


# ---------------------------------------------------------------------------
# Path 2: source has validity but null_count==0 -> destination drops it.
# ---------------------------------------------------------------------------


def test_copy_column_all_valid_drops_bitmap() raises:
    """Fast path: source validity + null_count==0 -> dst validity is None."""
    var vals: List[Int64] = [
        Int64(1), Int64(2), Int64(3), Int64(4),
        Int64(5), Int64(6), Int64(7), Int64(8),
    ]
    var batch = _make_batch_int64_all_valid(vals)
    # Sanity-check the source: bitmap present, null_count == 0.
    ref src = batch.column_at(0)
    assert_true(Bool(src._validity), "source should have a validity bitmap")
    assert_equal(src._null_count, 0)

    var col = copy_column(batch, 0)
    assert_equal(col._length, 8)
    assert_equal(col._null_count, 0)
    # The KEY assertion: the copy drops the validity bitmap when null_count==0.
    assert_false(
        Bool(col._validity),
        "A.4: validity bitmap should be dropped when source null_count==0",
    )
    # Values preserved.
    var view = col._data.view_ro()
    for i in range(8):
        assert_equal(Int(view.get_typed[Int64](i)), Int(vals[i]))


def test_copy_column_all_valid_large() raises:
    """Path 2 at 1024 rows (a join-build column size)."""
    var n = 1024
    var vals = List[Int64]()
    for i in range(n):
        vals.append(Int64(i))
    var batch = _make_batch_int64_all_valid(vals)
    var col = copy_column(batch, 0)
    assert_equal(col._length, n)
    assert_equal(col._null_count, 0)
    assert_false(Bool(col._validity))
    var view = col._data.view_ro()
    for i in range(n):
        assert_equal(Int(view.get_typed[Int64](i)), i)


# ---------------------------------------------------------------------------
# Path 3: source has real nulls -> bulk-copy preserves bitmap + null_count.
# ---------------------------------------------------------------------------


def test_copy_column_with_nulls_preserves_bits() raises:
    """Path 3: nulls are preserved bit-for-bit by the bulk-copy primitive."""
    var vals: List[Int64] = [
        Int64(100), Int64(200), Int64(300), Int64(400),
        Int64(500), Int64(600), Int64(700), Int64(800),
    ]
    var nulls: List[Int] = [1, 4, 7]
    var batch = _make_batch_int64_with_nulls(vals, nulls)
    var col = copy_column(batch, 0)
    assert_equal(col._length, 8)
    assert_equal(col._null_count, 3)
    assert_true(Bool(col._validity))
    ref bm = col._validity.value()
    assert_equal(bm.length, 8)
    # Bits 1, 4, 7 are null; the rest are valid.
    assert_true(bm.test(0))
    assert_false(bm.test(1))
    assert_true(bm.test(2))
    assert_true(bm.test(3))
    assert_false(bm.test(4))
    assert_true(bm.test(5))
    assert_true(bm.test(6))
    assert_false(bm.test(7))


def test_copy_column_with_nulls_large_aligned() raises:
    """Path 3 at 256 rows: byte-aligned memcpy fast path through copy_slice_from."""
    var n = 256
    var vals = List[Int64]()
    for i in range(n):
        vals.append(Int64(i))
    var nulls = List[Int]()
    for i in range(n):
        if i % 7 == 0:
            nulls.append(i)
    var batch = _make_batch_int64_with_nulls(vals, nulls)
    var col = copy_column(batch, 0)
    assert_equal(col._length, n)
    assert_equal(col._null_count, len(nulls))
    assert_true(Bool(col._validity))
    ref bm = col._validity.value()
    for i in range(n):
        var should_be_null = (i % 7) == 0
        if should_be_null:
            assert_false(bm.test(i),
                "row " + String(i) + " should be null")
        else:
            assert_true(bm.test(i),
                "row " + String(i) + " should be valid")


def test_copy_column_with_nulls_unaligned_length() raises:
    """Path 3 at 13 rows: tail-bit handling exercised."""
    var vals: List[Int64] = [
        Int64(1), Int64(2), Int64(3), Int64(4), Int64(5), Int64(6),
        Int64(7), Int64(8), Int64(9), Int64(10), Int64(11), Int64(12),
        Int64(13),
    ]
    var nulls: List[Int] = [0, 12]  # first and last null
    var batch = _make_batch_int64_with_nulls(vals, nulls)
    var col = copy_column(batch, 0)
    assert_equal(col._length, 13)
    assert_equal(col._null_count, 2)
    ref bm = col._validity.value()
    assert_false(bm.test(0))
    assert_false(bm.test(12))
    for i in range(1, 12):
        assert_true(bm.test(i),
            "row " + String(i) + " should be valid")


# ---------------------------------------------------------------------------
# Edge cases: zero rows, single row.
# ---------------------------------------------------------------------------


def test_copy_column_zero_rows_no_validity() raises:
    """Zero-row source with no validity round-trips to zero-row no-validity."""
    var vals = List[Int64]()
    var batch = _make_batch_int64_no_validity(vals)
    var col = copy_column(batch, 0)
    assert_equal(col._length, 0)
    assert_equal(col._null_count, 0)
    assert_false(Bool(col._validity))


def test_copy_column_zero_rows_all_valid() raises:
    """Zero-row source WITH all-valid bitmap also produces no-validity dst.

    Path 2 short-circuit: null_count==0 -> drop validity, regardless of
    source row count.
    """
    var vals = List[Int64]()
    var batch = _make_batch_int64_all_valid(vals)
    var col = copy_column(batch, 0)
    assert_equal(col._length, 0)
    assert_equal(col._null_count, 0)
    # Path 2 fires even at zero rows: source had null_count==0.
    assert_false(Bool(col._validity))


def test_copy_column_single_row_valid() raises:
    """Single-row valid source: the fast path drops validity."""
    var vals: List[Int64] = [Int64(42)]
    var batch = _make_batch_int64_all_valid(vals)
    var col = copy_column(batch, 0)
    assert_equal(col._length, 1)
    assert_equal(col._null_count, 0)
    assert_false(Bool(col._validity))
    assert_equal(Int(col._data.view_ro().get_typed[Int64](0)), 42)


def test_copy_column_single_row_null() raises:
    """Single-row source where the only row is null: bitmap preserved."""
    var vals: List[Int64] = [Int64(999)]
    var nulls: List[Int] = [0]
    var batch = _make_batch_int64_with_nulls(vals, nulls)
    var col = copy_column(batch, 0)
    assert_equal(col._length, 1)
    assert_equal(col._null_count, 1)
    assert_true(Bool(col._validity))
    assert_false(col._validity.value().test(0))


# ---------------------------------------------------------------------------
# Float64 sanity (ensure the fast path isn't accidentally INT64-only).
# ---------------------------------------------------------------------------


def test_copy_column_float64_all_valid() raises:
    """Path 2 (drop-validity) fires for FLOAT64 columns too."""
    var n = 16
    var arr = PrimitiveArray[DType.float64].allocate_nullable(n)
    var ptr = arr._typed_ptr_mut()
    for i in range(n):
        ptr[i] = Float64(i) * 0.5
    var c = Column.from_primitive(arr^)
    var sb = SchemaBuilder()
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    var b = RecordBatchBuilder()
    b.add_column(c^)
    var batch = b.build(sb.build())

    var col = copy_column(batch, 0)
    assert_equal(col._length, n)
    assert_equal(col._null_count, 0)
    assert_false(Bool(col._validity))
    var view = col._data.view_ro()
    for i in range(n):
        var got = Float64(view.get_typed[Float64](i))
        assert_equal(Int(got * 2.0), i)  # 0.5 * i * 2 == i


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
