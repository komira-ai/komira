# =============================================================================
# Tests for the `gather_into_recordbatch` substrate primitive.
#
# Covers the additive `gather_into_recordbatch[bo](batch_view, sel) ->
# RecordBatch` primitive at `komira_core.arrow.gather_recordbatch`.
# Used by the untyped wrapper and typed templates to materialize survivor
# selection into a downstream RecordBatch after a row-mode filter pass.
#
# 8 test cases (matches slot dispatch directive Surface 2 spec):
#   1. Empty selection (sel.len() == 0) — output is 0-row RecordBatch
#      with correct schema preserved.
#   2. Identity selection ([0, 1, ..., N-1]) — output equals input batch.
#   3. Sparse selection (every 3rd row) — output rows in correct order,
#      values bit-exact.
#   4. Single-column Int64.
#   5. Single-column Float64.
#   6. Two-column (Int64 + Float64) — column ordering preserved.
#   7. Three-column with nullable middle column — validity bitmap is
#      preserved across gather (per existing gather_batch contract).
#   8. Larger N (1024 rows, sel.len() == 300) — exercises SIMD chunk +
#      scalar tail through the underlying gather_batch delegate.
# =============================================================================

from std.memory import OwnedPointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.column import Column
from komira_core.arrow.gather_recordbatch import gather_into_recordbatch
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch
from komira_core.arrow.schema import Field, Schema
from komira_core.collections.batch_view import BatchView, batch_view_over
from komira_core.eval.selection_vector_row import RowSelectionVector


# -----------------------------------------------------------------------------
# Batch builders
# -----------------------------------------------------------------------------


def _build_i64_batch(
    var vals: List[Scalar[DType.int64]], col_name: String
) raises -> RecordBatch:
    """1-column Int64 RecordBatch named `col_name`."""
    var arr = PrimitiveArray[DType.int64].from_list(vals^)
    var schema = Schema.from_fields_1(Field(col_name, DType.int64, True))
    var col = Column.from_primitive[DType.int64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_f64_batch(
    var vals: List[Scalar[DType.float64]], col_name: String
) raises -> RecordBatch:
    """1-column Float64 RecordBatch named `col_name`."""
    var arr = PrimitiveArray[DType.float64].from_list(vals^)
    var schema = Schema.from_fields_1(Field(col_name, DType.float64, True))
    var col = Column.from_primitive[DType.float64](arr^)
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _build_i64_f64_batch(
    var v0: List[Scalar[DType.int64]],
    var v1: List[Scalar[DType.float64]],
) raises -> RecordBatch:
    """2-column (Int64, Float64) RecordBatch."""
    var a0 = PrimitiveArray[DType.int64].from_list(v0^)
    var a1 = PrimitiveArray[DType.float64].from_list(v1^)
    var schema = Schema.from_fields_2(
        Field("a", DType.int64, True),
        Field("b", DType.float64, True),
    )
    var c0 = Column.from_primitive[DType.int64](a0^)
    var c1 = Column.from_primitive[DType.float64](a1^)
    return RecordBatch.from_typed_columns_2(schema^, c0^, c1^)


def _build_3col_nullable_middle_batch(
    var v0: List[Scalar[DType.int64]],
    var v1: List[Scalar[DType.float64]],
    var v1_validity: List[Bool],
    var v2: List[Scalar[DType.int64]],
) raises -> RecordBatch:
    """3-column batch (Int64, nullable Float64, Int64)."""
    var n = len(v0)
    var a0 = PrimitiveArray[DType.int64].from_list(v0^)
    var a2 = PrimitiveArray[DType.int64].from_list(v2^)

    # Build nullable Float64 column with explicit validity bitmap.
    var bm = Bitmap.create(n)
    var nulls = 0
    for i in range(n):
        if v1_validity[i]:
            bm.set(i)
        else:
            bm.clear(i)
            nulls += 1
    var buf = OwnedAlignedBuffer(max(n, 1) * 8)
    for i in range(n):
        buf.set_typed[Scalar[DType.float64]](i, v1[i])
    buf.set_length(Int64(n * 8))

    var a1 = PrimitiveArray[DType.float64](buf^, n, bm^, nulls, 0)

    var schema = Schema.from_fields_3(
        Field("x", DType.int64, True),
        Field("y", DType.float64, True),
        Field("z", DType.int64, True),
    )
    var c0 = Column.from_primitive[DType.int64](a0^)
    var c1 = Column.from_primitive[DType.float64](a1^)
    var c2 = Column.from_primitive[DType.int64](a2^)
    return RecordBatch.from_typed_columns_3(schema^, c0^, c1^, c2^)


# -----------------------------------------------------------------------------
# Sel helpers
# -----------------------------------------------------------------------------


def _sel_from_indices(var indices: List[Int]) raises -> RowSelectionVector:
    """Build a RowSelectionVector populated with the given indices."""
    var sel = RowSelectionVector()
    for i in range(len(indices)):
        sel.append(UInt32(indices[i]))
    return sel^


def _sel_identity(n: Int) raises -> RowSelectionVector:
    """Build a RowSelectionVector with identity selection [0, 1, ..., n-1]."""
    var sel = RowSelectionVector()
    for i in range(n):
        sel.append(UInt32(i))
    return sel^


# -----------------------------------------------------------------------------
# Case 1: Empty selection (sel.len() == 0)
# -----------------------------------------------------------------------------


def test_empty_selection() raises:
    """sel.len() == 0 ⇒ 0-row RecordBatch with source schema preserved."""
    var vals = List[Scalar[DType.int64]]()
    vals.append(Scalar[DType.int64](10))
    vals.append(Scalar[DType.int64](20))
    vals.append(Scalar[DType.int64](30))
    var batch = _build_i64_batch(vals^, String("x"))

    var sel = RowSelectionVector()  # empty
    var view = batch_view_over(batch)
    var out = gather_into_recordbatch(view, sel)

    assert_equal(out.num_rows(), 0, "empty-sel: output should have 0 rows")
    assert_equal(
        out.num_columns(), 1, "empty-sel: schema should preserve 1 column"
    )
    assert_equal(
        out.schema.field_name(0), String("x"),
        "empty-sel: column name should be preserved",
    )


# -----------------------------------------------------------------------------
# Case 2: Identity selection
# -----------------------------------------------------------------------------


def test_identity_selection_i64() raises:
    """sel = [0, 1, ..., N-1] ⇒ output values match input row-for-row."""
    var vals = List[Scalar[DType.int64]]()
    var n = 8
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i * 7 + 3)))
    var batch = _build_i64_batch(vals^, String("x"))

    var sel = _sel_identity(n)
    var view = batch_view_over(batch)
    var out = gather_into_recordbatch(view, sel)

    assert_equal(out.num_rows(), n, "identity: row count")
    assert_equal(out.num_columns(), 1, "identity: column count")
    var arr = out.column_as_primitive_int64(0)
    for i in range(n):
        assert_equal(
            Int(arr.get(i)), i * 7 + 3,
            "identity: gathered value at index " + String(i),
        )


# -----------------------------------------------------------------------------
# Case 3: Sparse selection (every 3rd row)
# -----------------------------------------------------------------------------


def test_sparse_every_third_row_i64() raises:
    """Sparse sel [0, 3, 6, 9, 12, 15] over 18-row Int64 batch."""
    var vals = List[Scalar[DType.int64]]()
    var n = 18
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i * 100)))
    var batch = _build_i64_batch(vals^, String("x"))

    var idxs = List[Int]()
    idxs.append(0)
    idxs.append(3)
    idxs.append(6)
    idxs.append(9)
    idxs.append(12)
    idxs.append(15)
    var sel = _sel_from_indices(idxs^)
    var view = batch_view_over(batch)
    var out = gather_into_recordbatch(view, sel)

    assert_equal(out.num_rows(), 6, "sparse: row count")
    var arr = out.column_as_primitive_int64(0)
    var expected = List[Int]()
    expected.append(0)
    expected.append(300)
    expected.append(600)
    expected.append(900)
    expected.append(1200)
    expected.append(1500)
    for i in range(6):
        assert_equal(
            Int(arr.get(i)), expected[i],
            "sparse: gathered value at position " + String(i),
        )


# -----------------------------------------------------------------------------
# Case 4: Single-column Int64 (covered by identity + sparse, but adds
# negative + zero coverage)
# -----------------------------------------------------------------------------


def test_i64_with_negative_and_zero() raises:
    """Int64 with negative + zero values; sel picks alternating rows."""
    var vals = List[Scalar[DType.int64]]()
    vals.append(Scalar[DType.int64](-100))
    vals.append(Scalar[DType.int64](0))
    vals.append(Scalar[DType.int64](42))
    vals.append(Scalar[DType.int64](-7))
    vals.append(Scalar[DType.int64](Int64.MAX))
    vals.append(Scalar[DType.int64](Int64.MIN))
    var batch = _build_i64_batch(vals^, String("x"))

    var idxs = List[Int]()
    idxs.append(1)
    idxs.append(3)
    idxs.append(5)
    var sel = _sel_from_indices(idxs^)
    var view = batch_view_over(batch)
    var out = gather_into_recordbatch(view, sel)

    assert_equal(out.num_rows(), 3, "i64-neg: row count")
    var arr = out.column_as_primitive_int64(0)
    assert_equal(Int(arr.get(0)), 0, "i64-neg: row 0 = zero")
    assert_equal(Int(arr.get(1)), -7, "i64-neg: row 1 = -7")
    assert_equal(arr.get(2), Int64.MIN, "i64-neg: row 2 = INT64_MIN")


# -----------------------------------------------------------------------------
# Case 5: Single-column Float64
# -----------------------------------------------------------------------------


def test_f64_sparse_selection() raises:
    """Float64 column with sparse sel; verify bit-exact float values."""
    var vals = List[Scalar[DType.float64]]()
    vals.append(Scalar[DType.float64](1.5))
    vals.append(Scalar[DType.float64](2.25))
    vals.append(Scalar[DType.float64](-3.125))
    vals.append(Scalar[DType.float64](0.0))
    vals.append(Scalar[DType.float64](100.001))
    var batch = _build_f64_batch(vals^, String("v"))

    var idxs = List[Int]()
    idxs.append(0)
    idxs.append(2)
    idxs.append(4)
    var sel = _sel_from_indices(idxs^)
    var view = batch_view_over(batch)
    var out = gather_into_recordbatch(view, sel)

    assert_equal(out.num_rows(), 3, "f64: row count")
    var arr = out.column_as_primitive_float64(0)
    assert_equal(arr.get(0), Float64(1.5), "f64: row 0 = 1.5")
    assert_equal(arr.get(1), Float64(-3.125), "f64: row 1 = -3.125")
    assert_equal(arr.get(2), Float64(100.001), "f64: row 2 = 100.001")


# -----------------------------------------------------------------------------
# Case 6: Two-column (Int64 + Float64) — column ordering preserved
# -----------------------------------------------------------------------------


def test_two_column_ordering() raises:
    """2-column gather; verify column ordering + per-row alignment."""
    var v0 = List[Scalar[DType.int64]]()
    var v1 = List[Scalar[DType.float64]]()
    for i in range(10):
        v0.append(Scalar[DType.int64](Int64(i * 10)))
        v1.append(Scalar[DType.float64](Float64(i) * 1.5))
    var batch = _build_i64_f64_batch(v0^, v1^)

    var idxs = List[Int]()
    idxs.append(7)
    idxs.append(2)
    idxs.append(9)
    var sel = _sel_from_indices(idxs^)
    var view = batch_view_over(batch)
    var out = gather_into_recordbatch(view, sel)

    assert_equal(out.num_rows(), 3, "2col: row count")
    assert_equal(out.num_columns(), 2, "2col: column count")
    assert_equal(
        out.schema.field_name(0), String("a"), "2col: col 0 name = a"
    )
    assert_equal(
        out.schema.field_name(1), String("b"), "2col: col 1 name = b"
    )

    var ai = out.column_as_primitive_int64(0)
    var af = out.column_as_primitive_float64(1)

    assert_equal(Int(ai.get(0)), 70, "2col: i64[0] = 70 (src row 7)")
    assert_equal(Int(ai.get(1)), 20, "2col: i64[1] = 20 (src row 2)")
    assert_equal(Int(ai.get(2)), 90, "2col: i64[2] = 90 (src row 9)")

    assert_equal(af.get(0), Float64(10.5), "2col: f64[0] = 10.5 (src row 7)")
    assert_equal(af.get(1), Float64(3.0), "2col: f64[1] = 3.0 (src row 2)")
    assert_equal(af.get(2), Float64(13.5), "2col: f64[2] = 13.5 (src row 9)")


# -----------------------------------------------------------------------------
# Case 7: 3-column with nullable middle column
# -----------------------------------------------------------------------------


def test_three_column_with_nullable_middle() raises:
    """Nullable Float64 in the middle of 3 columns; verify validity gather."""
    var v0 = List[Scalar[DType.int64]]()
    var v1 = List[Scalar[DType.float64]]()
    var v1_valid = List[Bool]()
    var v2 = List[Scalar[DType.int64]]()

    # Build 6 rows; rows 1 + 4 are null in column 1.
    for i in range(6):
        v0.append(Scalar[DType.int64](Int64(i + 100)))
        v1.append(Scalar[DType.float64](Float64(i) * 0.5))
        if i == 1 or i == 4:
            v1_valid.append(False)
        else:
            v1_valid.append(True)
        v2.append(Scalar[DType.int64](Int64(i + 1000)))

    var batch = _build_3col_nullable_middle_batch(v0^, v1^, v1_valid^, v2^)

    # Sel picks rows [0, 1, 3, 4] — captures one valid + one null
    # from the first half and one valid + one null from the second half.
    var idxs = List[Int]()
    idxs.append(0)
    idxs.append(1)
    idxs.append(3)
    idxs.append(4)
    var sel = _sel_from_indices(idxs^)
    var view = batch_view_over(batch)
    var out = gather_into_recordbatch(view, sel)

    assert_equal(out.num_rows(), 4, "3col-nullable: row count")
    assert_equal(out.num_columns(), 3, "3col-nullable: column count")

    # Column 0 (non-nullable Int64): rows 0, 1, 3, 4 → 100, 101, 103, 104.
    var ai0 = out.column_as_primitive_int64(0)
    assert_equal(Int(ai0.get(0)), 100, "3col-nullable: col0[0] = 100")
    assert_equal(Int(ai0.get(1)), 101, "3col-nullable: col0[1] = 101")
    assert_equal(Int(ai0.get(2)), 103, "3col-nullable: col0[2] = 103")
    assert_equal(Int(ai0.get(3)), 104, "3col-nullable: col0[3] = 104")

    # Column 1 (nullable Float64): rows 0 + 3 valid; rows 1 + 4 null.
    var af = out.column_as_primitive_float64(1)
    assert_true(
        Bool(af.validity), "3col-nullable: middle col validity present"
    )
    # Valid rows: src row 0 → 0.0, src row 3 → 1.5.
    # Null rows (sel positions 1, 2 → src rows 1, 4) — the value is
    # undefined per Arrow spec; we only assert validity bits.
    assert_true(
        af.validity.value().test(0),
        "3col-nullable: col1[0] (src row 0) is valid",
    )
    assert_true(
        not af.validity.value().test(1),
        "3col-nullable: col1[1] (src row 1) is null",
    )
    assert_true(
        af.validity.value().test(2),
        "3col-nullable: col1[2] (src row 3) is valid",
    )
    assert_true(
        not af.validity.value().test(3),
        "3col-nullable: col1[3] (src row 4) is null",
    )
    assert_equal(
        af.get(0), Float64(0.0), "3col-nullable: col1[0] value = 0.0"
    )
    assert_equal(
        af.get(2), Float64(1.5), "3col-nullable: col1[2] value = 1.5"
    )

    # Column 2 (non-nullable Int64): rows 0, 1, 3, 4 → 1000, 1001, 1003, 1004.
    var ai2 = out.column_as_primitive_int64(2)
    assert_equal(Int(ai2.get(0)), 1000, "3col-nullable: col2[0] = 1000")
    assert_equal(Int(ai2.get(1)), 1001, "3col-nullable: col2[1] = 1001")
    assert_equal(Int(ai2.get(2)), 1003, "3col-nullable: col2[2] = 1003")
    assert_equal(Int(ai2.get(3)), 1004, "3col-nullable: col2[3] = 1004")


# -----------------------------------------------------------------------------
# Case 8: Larger N (1024 rows; sel.len() == 300)
# -----------------------------------------------------------------------------


def test_large_batch_sparse_300_of_1024() raises:
    """1024-row Int64 batch; sel picks 300 evenly-spaced rows."""
    var vals = List[Scalar[DType.int64]]()
    var n = 1024
    for i in range(n):
        vals.append(Scalar[DType.int64](Int64(i)))
    var batch = _build_i64_batch(vals^, String("x"))

    # Stride 1024 / 300 ≈ 3.41; pick every k_step-th row, capping at 300.
    var idxs = List[Int]()
    var stride = 3
    var k = 0
    var picked = 0
    while picked < 300 and k < n:
        idxs.append(k)
        picked += 1
        k += stride
    # Top-up to exactly 300 if stride loop under-shot.
    while picked < 300:
        idxs.append(k % n)
        picked += 1
        k += 1

    var sel = _sel_from_indices(idxs.copy())
    var view = batch_view_over(batch)
    var out = gather_into_recordbatch(view, sel)

    assert_equal(out.num_rows(), 300, "large: row count")
    assert_equal(out.num_columns(), 1, "large: column count")
    var arr = out.column_as_primitive_int64(0)
    # Spot-check first / middle / last gathered values.
    assert_equal(Int(arr.get(0)), idxs[0], "large: row 0 spot check")
    assert_equal(
        Int(arr.get(150)), idxs[150], "large: row 150 spot check"
    )
    assert_equal(
        Int(arr.get(299)), idxs[299], "large: row 299 (last) spot check"
    )


# -----------------------------------------------------------------------------
# TestSuite registration
# -----------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()

    suite.test[test_empty_selection]()
    suite.test[test_identity_selection_i64]()
    suite.test[test_sparse_every_third_row_i64]()
    suite.test[test_i64_with_negative_and_zero]()
    suite.test[test_f64_sparse_selection]()
    suite.test[test_two_column_ordering]()
    suite.test[test_three_column_with_nullable_middle]()
    suite.test[test_large_batch_sparse_300_of_1024]()

    suite^.run()
