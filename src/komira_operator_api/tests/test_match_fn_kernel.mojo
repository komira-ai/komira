# =============================================================================
# test_match_fn_kernel.mojo — EXECUTOR-KERNEL-COMPTIME Phase 1.b regression
# =============================================================================
#
# Exercises the Phase 1.b deliverables:
#
#   - `LtI64.eval_chunk` correctness over {empty, 1-row, 2048-row, 4097-row}.
#     2048 is the morsel chunk size; 4097 forces ragged tail at every SIMD width.
#   - PROPAGATE null handling across all 4 (LHS_VALID, RHS_VALID) cells.
#   - `MatchFnOp[LtI64]` end-to-end through one Morsel.execute call.
#   - Byte-identical to `eval_col_lt[DType.int64]` (the existing SIMD primitive).
#   - Distinct monomorphizations across (T, OP) cells AND across the 4 validity
#     cells of one (T, OP).
#   - NO_MATCH_SEL=False (bitmap) <-> sel-vector equivalence: every row reachable
#     by `filter_to_indices(bitmap)` corresponds to a set bit in the bitmap.
#   - Unary IsNullI64 / IsNotNullI64 correctness.
# =============================================================================

from std.testing import (
    TestSuite,
    assert_equal,
    assert_true,
    assert_false,
    assert_almost_equal,
)

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.schema import Field, RecordBatch, Schema
from komira_morsel.morsel import Morsel
from komira_operator_api.match_fn_op import MatchFnOp, UnaryMatchFnOp
from komira_kernels.builtin_match_fns import (
    LtI64,
    LtI64_LV,
    LtI64_RV,
    LtI64_LRV,
    LeI64,
    GtI64,
    GeI64,
    EqI64,
    NeI64,
    LtF64,
    EqF64,
    IsNullI64,
    IsNotNullI64,
)
from komira_kernels.match_fn import MatchFn, UnaryMatchFn
from komira_column_kernels.comparison import (
    eval_col_lt,
    eval_col_gt,
    eval_col_eq,
    filter_to_indices,
)


# =============================================================================
# Fixture helpers
# =============================================================================


def _make_l_i64(n: Int) raises -> PrimitiveArray[DType.int64]:
    """L[i] = i."""
    var L = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        L.set(i, Int64(i))
    return L^


def _make_r_i64_shifted(n: Int) raises -> PrimitiveArray[DType.int64]:
    """R[i] = i + 100 — paired with `_make_l_i64` ensures L<R always."""
    var R = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        R.set(i, Int64(i + 100))
    return R^


def _make_lr_i64_batch(n: Int) raises -> RecordBatch:
    """Build a 2-col Int64 batch: L[i]=i, R[i]=i+100 (L<R always)."""
    var L = _make_l_i64(n)
    var R = _make_r_i64_shifted(n)
    var schema = Schema.from_fields_2(
        Field("l", ArrowType.INT64, False),
        Field("r", ArrowType.INT64, False),
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](L^),
        Column.from_primitive[DType.int64](R^),
    )


def _make_lr_i64_mixed_batch(n: Int) raises -> RecordBatch:
    """Mixed batch: L[i]=i, R[i]=(2*i + 1) % 50 — so L<R holds for some rows."""
    var L = PrimitiveArray[DType.int64].allocate(n)
    var R = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        L.set(i, Int64(i))
        R.set(i, Int64((2 * i + 1) % 50))
    var schema = Schema.from_fields_2(
        Field("l", ArrowType.INT64, False),
        Field("r", ArrowType.INT64, False),
    )
    return RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](L^),
        Column.from_primitive[DType.int64](R^),
    )


def _make_l_nullable_i64(n: Int, null_lhs_at: Int) raises -> PrimitiveArray[DType.int64]:
    """Allocate nullable L; L[i]=i. Row `null_lhs_at` nulled when in range."""
    var L = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        L.set(i, Int64(i))
    if 0 <= null_lhs_at < n:
        L._set_null(null_lhs_at)
        L.null_count = L.null_count + 1
    return L^


def _make_r_nullable_i64(n: Int, null_rhs_at: Int) raises -> PrimitiveArray[DType.int64]:
    """Allocate nullable R; R[i]=i+100. Row `null_rhs_at` nulled when in range."""
    var R = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        R.set(i, Int64(i + 100))
    if 0 <= null_rhs_at < n:
        R._set_null(null_rhs_at)
        R.null_count = R.null_count + 1
    return R^


# =============================================================================
# (a) LtI64.eval_chunk correctness over {0, 1, 2048, 4097} rows
# =============================================================================


def _check_lt_i64(n: Int) raises:
    var L = _make_l_i64(n)
    var R = _make_r_i64_shifted(n)
    var out = Bitmap.create(n)
    var f = LtI64()
    var match_count = f.eval_chunk(L, R, out)
    # L < R is always true for our fixture (R = L + 100).
    assert_equal(match_count, n, "LtI64 match_count == n for L<R fixture")
    # Every bit in the output mask should be set (within length).
    for i in range(n):
        assert_true(out.test(i), "out bit " + String(i) + " should be set (n=" + String(n) + ")")


def test_lt_i64_empty() raises:
    _check_lt_i64(0)


def test_lt_i64_one_row() raises:
    _check_lt_i64(1)


def test_lt_i64_2048_rows() raises:
    _check_lt_i64(2048)


def test_lt_i64_4097_rows_ragged_tail() raises:
    _check_lt_i64(4097)


def test_lt_i64_mixed_pattern_correctness() raises:
    """Verify per-row correctness against eval_col_lt on a mixed pattern."""
    var n = 256
    var rb = _make_lr_i64_mixed_batch(n)
    var L_col = rb.column_at(0).as_primitive[DType.int64]()
    var R_col = rb.column_at(1).as_primitive[DType.int64]()
    var out = Bitmap.create(n)
    var f = LtI64()
    var match_count = f.eval_chunk(L_col, R_col, out)

    # Recompute expected match count via the reference primitive.
    var L2 = rb.column_at(0).as_primitive[DType.int64]()
    var R2 = rb.column_at(1).as_primitive[DType.int64]()
    var gold = eval_col_lt[DType.int64](L2, R2)
    # Compare row-by-row.
    var gold_count = 0
    for i in range(n):
        var expected = gold.data.test(i)
        var actual = out.test(i)
        assert_equal(actual, expected, "LtI64 vs eval_col_lt mismatch at row " + String(i))
        if expected:
            gold_count += 1
    assert_equal(match_count, gold_count, "match_count agrees with bit-count")


# =============================================================================
# (b) Validity fanout — all 4 (LHS_VALID, RHS_VALID) cells exist & work
# =============================================================================


def test_lt_i64_no_validity_cell() raises:
    """(F, F): non-nullable inputs. Row null at neither side."""
    var n = 8
    var L = _make_l_i64(n)
    var R = _make_r_i64_shifted(n)
    var out = Bitmap.create(n)
    var f = LtI64()
    var match_count = f.eval_chunk(L, R, out)
    assert_equal(match_count, n, "all rows match")


def test_lt_i64_lhs_validity_cell() raises:
    """(T, F): lhs has nulls — row at null_lhs is dropped."""
    var n = 8
    var L = _make_l_nullable_i64(n, 2)  # lhs[2] null
    var R = _make_r_nullable_i64(n, -1)
    var out = Bitmap.create(n)
    var f = LtI64_LV()
    var match_count = f.eval_chunk(L, R, out)
    assert_equal(match_count, n - 1, "all rows except null_lhs match")
    assert_false(out.test(2), "row 2 (lhs null) should not match")
    assert_true(out.test(0), "row 0 should match")
    assert_true(out.test(5), "row 5 should match")


def test_lt_i64_rhs_validity_cell() raises:
    """(F, T): rhs has nulls."""
    var n = 8
    var L = _make_l_nullable_i64(n, -1)
    var R = _make_r_nullable_i64(n, 4)  # rhs[4] null
    var out = Bitmap.create(n)
    var f = LtI64_RV()
    var match_count = f.eval_chunk(L, R, out)
    assert_equal(match_count, n - 1)
    assert_false(out.test(4), "row 4 (rhs null) should not match")


def test_lt_i64_both_validity_cell() raises:
    """(T, T): both sides have nulls."""
    var n = 8
    var L = _make_l_nullable_i64(n, 1)  # lhs[1] null
    var R = _make_r_nullable_i64(n, 5)  # rhs[5] null
    var out = Bitmap.create(n)
    var f = LtI64_LRV()
    var match_count = f.eval_chunk(L, R, out)
    assert_equal(match_count, n - 2)
    assert_false(out.test(1))
    assert_false(out.test(5))
    assert_true(out.test(0))
    assert_true(out.test(7))


# =============================================================================
# (c) MatchFnOp[LtI64] end-to-end through Morsel.execute
# =============================================================================


def test_lt_i64_op_end_to_end() raises:
    var n = 64
    var rb = _make_lr_i64_batch(n)
    var m = Morsel(rb^, 0, 0)
    var op = MatchFnOp[LtI64](LtI64(), "l", "r")
    var _r = op.execute(m)
    # L < R for all rows → all 64 rows survive.
    assert_equal(m.batch.num_rows(), n, "all rows pass L<R")
    assert_equal(m.batch.num_columns(), 2, "schema unchanged")


def test_lt_i64_op_filters_correctly() raises:
    """Confirm the operator narrows rows correctly when only SOME match."""
    var n = 32
    # L[i] = i (0..31); R[i] = 10 (constant). L<R iff i<10.
    var L = PrimitiveArray[DType.int64].allocate(n)
    var R = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        L.set(i, Int64(i))
        R.set(i, Int64(10))
    var schema = Schema.from_fields_2(
        Field("l", ArrowType.INT64, False),
        Field("r", ArrowType.INT64, False),
    )
    var rb = RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](L^),
        Column.from_primitive[DType.int64](R^),
    )
    var m = Morsel(rb^, 0, 0)
    var op = MatchFnOp[LtI64](LtI64(), "l", "r")
    var _r = op.execute(m)
    assert_equal(m.batch.num_rows(), 10, "10 rows match L<10")
    assert_equal(m.batch.num_columns(), 2)


# =============================================================================
# (d) Byte-identical to eval_col_lt (the existing SIMD primitive)
# =============================================================================


def test_lt_i64_byte_identical_to_eval_col_lt() raises:
    """Compare every bit of LtI64.eval_chunk against eval_col_lt on
    a 4097-row mixed-magnitude input."""
    var n = 4097
    var lhs1 = PrimitiveArray[DType.int64].allocate(n)
    var rhs1 = PrimitiveArray[DType.int64].allocate(n)
    var lhs2 = PrimitiveArray[DType.int64].allocate(n)
    var rhs2 = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        var l = Int64(i - 2000)
        var r = Int64((i * 7) % 1024 - 512)
        lhs1.set(i, l)
        rhs1.set(i, r)
        lhs2.set(i, l)
        rhs2.set(i, r)
    # Path A: comptime fast path (LtI64).
    var out_a = Bitmap.create(n)
    var f = LtI64()
    var match_count = f.eval_chunk(lhs1, rhs1, out_a)
    # Path B: existing eval_col_lt primitive.
    var gold = eval_col_lt[DType.int64](lhs2, rhs2)
    var gold_count = 0
    for i in range(n):
        var expected = gold.data.test(i)
        var actual = out_a.test(i)
        assert_equal(actual, expected, "bit " + String(i) + " diverges (n=" + String(n) + ")")
        if expected:
            gold_count += 1
    assert_equal(match_count, gold_count, "match_count matches gold bit-count")


# =============================================================================
# (e) Distinct monomorphizations: per (T, OP) AND per (LHS_VALID, RHS_VALID)
# =============================================================================


def _assert_kernel_ids_differ[F: MatchFn, G: MatchFn]() raises:
    assert_true(
        F.KERNEL_ID != G.KERNEL_ID,
        "F.KERNEL_ID != G.KERNEL_ID",
    )


def test_distinct_monomorphizations_per_op() raises:
    _assert_kernel_ids_differ[LtI64, LeI64]()
    _assert_kernel_ids_differ[LtI64, GtI64]()
    _assert_kernel_ids_differ[LtI64, GeI64]()
    _assert_kernel_ids_differ[LtI64, EqI64]()
    _assert_kernel_ids_differ[LtI64, NeI64]()
    _assert_kernel_ids_differ[LtI64, LtF64]()
    _assert_kernel_ids_differ[EqI64, EqF64]()


def test_distinct_monomorphizations_per_validity() raises:
    _assert_kernel_ids_differ[LtI64, LtI64_LV]()
    _assert_kernel_ids_differ[LtI64, LtI64_RV]()
    _assert_kernel_ids_differ[LtI64, LtI64_LRV]()
    _assert_kernel_ids_differ[LtI64_LV, LtI64_RV]()
    _assert_kernel_ids_differ[LtI64_LV, LtI64_LRV]()
    _assert_kernel_ids_differ[LtI64_RV, LtI64_LRV]()
    # Sanity: same OP_TAG across the 4 validity cells.
    assert_equal(Int(LtI64.OP_TAG), Int(LtI64_LV.OP_TAG))
    assert_equal(Int(LtI64.OP_TAG), Int(LtI64_RV.OP_TAG))
    assert_equal(Int(LtI64.OP_TAG), Int(LtI64_LRV.OP_TAG))
    # Sanity: LHS_VALID / RHS_VALID flags read correctly.
    assert_equal(Bool(LtI64.LHS_VALID), False)
    assert_equal(Bool(LtI64.RHS_VALID), False)
    assert_equal(Bool(LtI64_LV.LHS_VALID), True)
    assert_equal(Bool(LtI64_LV.RHS_VALID), False)
    assert_equal(Bool(LtI64_RV.LHS_VALID), False)
    assert_equal(Bool(LtI64_RV.RHS_VALID), True)
    assert_equal(Bool(LtI64_LRV.LHS_VALID), True)
    assert_equal(Bool(LtI64_LRV.RHS_VALID), True)


# =============================================================================
# (f) NO_MATCH_SEL=False (bitmap) <-> sel-vector equivalence
# =============================================================================


def test_lt_i64_bitmap_to_sel_vector_consistent() raises:
    """The bitmap output and the corresponding sel-vector (via
    filter_to_indices) must contain the same row indices in order."""
    var n = 4097
    var lhs = PrimitiveArray[DType.int64].allocate(n)
    var rhs = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        lhs.set(i, Int64(i - 2000))
        rhs.set(i, Int64((i * 7) % 1024 - 512))
    var out = Bitmap.create(n)
    var f = LtI64()
    var match_count = f.eval_chunk(lhs, rhs, out)

    var bool_arr = BooleanArray.from_bitmap(out^)
    var sel = filter_to_indices(bool_arr)
    assert_equal(len(sel), match_count, "sel-vector length == match_count")
    # Reconstruct the bitmap from the sel-vector and confirm round-trip.
    var rebuilt = Bitmap.create(n)
    for idx in range(len(sel)):
        rebuilt.set(sel[idx])
    for i in range(n):
        assert_equal(
            rebuilt.test(i), bool_arr.data.test(i), "round-trip bit " + String(i)
        )


# =============================================================================
# Additional sanity — GT/EQ kernels are correct on a known input
# =============================================================================


def test_gt_i64_basic() raises:
    var n = 16
    var L = PrimitiveArray[DType.int64].allocate(n)
    var R = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        L.set(i, Int64(i))
        R.set(i, Int64(8))
    var out = Bitmap.create(n)
    var f = GtI64()
    var match_count = f.eval_chunk(L, R, out)
    # L > 8 iff i in {9, 10, ..., 15} -> 7 matches
    assert_equal(match_count, 7)
    for i in range(n):
        var expected = i > 8
        assert_equal(out.test(i), expected, "GtI64 row " + String(i))


def test_eq_i64_basic() raises:
    var n = 32
    var L = PrimitiveArray[DType.int64].allocate(n)
    var R = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        L.set(i, Int64(i % 4))
        R.set(i, Int64(2))
    var out = Bitmap.create(n)
    var f = EqI64()
    var match_count = f.eval_chunk(L, R, out)
    # i % 4 == 2 for i in {2, 6, 10, 14, 18, 22, 26, 30} -> 8 matches
    assert_equal(match_count, 8)
    for i in range(n):
        var expected = (i % 4) == 2
        assert_equal(out.test(i), expected, "EqI64 row " + String(i))


def test_lt_f64_basic() raises:
    var n = 64
    var L = PrimitiveArray[DType.float64].allocate(n)
    var R = PrimitiveArray[DType.float64].allocate(n)
    for i in range(n):
        L.set(i, Float64(i))
        R.set(i, Float64(32))
    var out = Bitmap.create(n)
    var f = LtF64()
    var match_count = f.eval_chunk(L, R, out)
    assert_equal(match_count, 32)
    for i in range(n):
        var expected = i < 32
        assert_equal(out.test(i), expected, "LtF64 row " + String(i))


# =============================================================================
# Unary tests — IsNullI64 / IsNotNullI64
# =============================================================================


def test_is_null_i64_basic() raises:
    """IS_NULL on a nullable Int64 column with two nulls."""
    var n = 16
    var L = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        L.set(i, Int64(i))
    L._set_null(3)
    L.null_count = L.null_count + 1
    L._set_null(11)
    L.null_count = L.null_count + 1
    var out = Bitmap.create(n)
    var f = IsNullI64()
    var match_count = f.eval_chunk(L, out)
    assert_equal(match_count, 2, "2 null rows")
    assert_true(out.test(3))
    assert_true(out.test(11))
    assert_false(out.test(0))
    assert_false(out.test(15))


def test_is_not_null_i64_basic() raises:
    """IS_NOT_NULL on the same input."""
    var n = 16
    var L = PrimitiveArray[DType.int64].allocate_nullable(n)
    for i in range(n):
        L.set(i, Int64(i))
    L._set_null(3)
    L.null_count = L.null_count + 1
    L._set_null(11)
    L.null_count = L.null_count + 1
    var out = Bitmap.create(n)
    var f = IsNotNullI64()
    var match_count = f.eval_chunk(L, out)
    assert_equal(match_count, n - 2)
    assert_false(out.test(3))
    assert_false(out.test(11))
    assert_true(out.test(0))
    assert_true(out.test(15))


def test_unary_match_fn_op_end_to_end() raises:
    """UnaryMatchFnOp[IsNotNullI64] over a Morsel narrows to non-null rows."""
    var n = 10
    var L = PrimitiveArray[DType.int64].allocate_nullable(n)
    var R = PrimitiveArray[DType.int64].allocate(n)
    for i in range(n):
        L.set(i, Int64(i))
        R.set(i, Int64(i + 100))
    L._set_null(2)
    L.null_count = L.null_count + 1
    L._set_null(7)
    L.null_count = L.null_count + 1
    var schema = Schema.from_fields_2(
        Field("l", ArrowType.INT64, True),
        Field("r", ArrowType.INT64, False),
    )
    var rb = RecordBatch.from_typed_columns_2(
        schema^,
        Column.from_primitive[DType.int64](L^),
        Column.from_primitive[DType.int64](R^),
    )
    var m = Morsel(rb^, 0, 0)
    var op = UnaryMatchFnOp[IsNotNullI64](IsNotNullI64(), "l")
    var _r = op.execute(m)
    assert_equal(m.batch.num_rows(), n - 2, "8 non-null rows survive")


def main() raises:
    var suite = TestSuite()
    # (a) correctness over varied chunk sizes
    suite.test[test_lt_i64_empty]()
    suite.test[test_lt_i64_one_row]()
    suite.test[test_lt_i64_2048_rows]()
    suite.test[test_lt_i64_4097_rows_ragged_tail]()
    suite.test[test_lt_i64_mixed_pattern_correctness]()
    # (b) validity fanout
    suite.test[test_lt_i64_no_validity_cell]()
    suite.test[test_lt_i64_lhs_validity_cell]()
    suite.test[test_lt_i64_rhs_validity_cell]()
    suite.test[test_lt_i64_both_validity_cell]()
    # (c) operator end-to-end
    suite.test[test_lt_i64_op_end_to_end]()
    suite.test[test_lt_i64_op_filters_correctly]()
    # (d) byte-identical
    suite.test[test_lt_i64_byte_identical_to_eval_col_lt]()
    # (e) distinct monomorphizations
    suite.test[test_distinct_monomorphizations_per_op]()
    suite.test[test_distinct_monomorphizations_per_validity]()
    # (f) bitmap <-> sel-vector consistency
    suite.test[test_lt_i64_bitmap_to_sel_vector_consistent]()
    # additional sanity
    suite.test[test_gt_i64_basic]()
    suite.test[test_eq_i64_basic]()
    suite.test[test_lt_f64_basic]()
    # unary
    suite.test[test_is_null_i64_basic]()
    suite.test[test_is_not_null_i64_basic]()
    suite.test[test_unary_match_fn_op_end_to_end]()
    suite^.run()
