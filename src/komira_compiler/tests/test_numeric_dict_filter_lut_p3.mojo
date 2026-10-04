# =============================================================================
# Numeric-dict predicate-over-codes LUT falsifying suite.
# =============================================================================
#
# The compute-over-codes LUT (`numeric_dict_filter_bool_mask`) REPLACES the v1
# densification band-aid (`resolve_numeric_dict_to_flat` per-row gather AT
# FILTER TIME). This suite is the falsifying oracle the band-aid removal is
# gated on:
#
#   1. VALUE-EQUIV: for INT64 / INT32 / FLOAT64 / FLOAT32 dict value types, over
#      every comparison op and a spread of selectivities, the LUT mask ==
#      the retained flat-densification mask == a hand-computed ground truth
#      (per-ROW data bits, not physical buffers).
#   2. EXCLUSION: a dict code present ONLY in filtered-OUT rows must NOT survive
#      (the keep-bit LUT gates per code, not per dict entry blindly).
#   3. TWO-DISTINCT-DICT col-vs-col: a numeric-dict-col vs numeric-dict-col
#      comparison across DIFFERENT per-RG dictionaries must DECLINE to the value
#      domain (code-vs-code across distinct dicts is silent-wrong) — it RAISES.
#   4. NULLS: a numeric-dict column carrying a validity bitmap filters correctly
#      (the null-collapse runs over the codes' row-validity, UNCHANGED).
#
# Encapsulation: public Column / RecordBatch / Expr / _eval_predicate surface
# only — no UnsafePointer, no wildcard origin, no unsafe_from_address.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    SchemaBuilder,
    RecordBatchBuilder,
)
from komira_core.arrow.boolean_array import BooleanArray
from komira_core.arrow.bitmap import Bitmap
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.plan.col_expr import col
from komira_core.plan.expr import Expr
from komira_core.plan.scalar_value import ScalarValue
from komira_core.io.heap_region import HeapRegion
from komira_compiler.compiler_eval_predicate import (
    _eval_predicate,
    numeric_dict_filter_bool_mask,
    numeric_dict_filter_via_flat,
)
from komira_compiler.conjunction import evaluate_filter_narrowed


# -----------------------------------------------------------------------------
# Fixture helpers
# -----------------------------------------------------------------------------


def _codes_i32(vals: List[Int32]) raises -> PrimitiveArray[DType.int32]:
    var l: List[Scalar[DType.int32]] = []
    for i in range(len(vals)):
        l.append(vals[i])
    return PrimitiveArray[DType.int32].from_list(l)


def _codes_i32_nullable(
    vals: List[Int32], null_rows: List[Int]
) raises -> PrimitiveArray[DType.int32]:
    """Codes array with a validity bitmap; rows in `null_rows` are NULL."""
    var n = len(vals)
    var buf = OwnedAlignedBuffer(max(n * 4, 1))
    var p = buf.view_typed_ro[DType.int32]()
    for i in range(n):
        p[i] = vals[i]
    buf.set_length(Int64(n * 4))
    var bm = Bitmap.create_all_valid(n)
    var nulls = 0
    for k in range(len(null_rows)):
        bm.clear(null_rows[k])
        nulls += 1
    var arr = PrimitiveArray[DType.int32](buf^, n, Optional(bm^), nulls, 0)
    return arr^


def _dict_i64(codes: List[Int32], dvals: List[Int64]) raises -> Column[HeapRegion]:
    var entries = List[Int64]()
    for i in range(len(dvals)):
        entries.append(dvals[i])
    return Column.from_numeric_dict[DType.int32, DType.int64](
        _codes_i32(codes), entries^
    )


def _dict_i32(codes: List[Int32], dvals: List[Int32]) raises -> Column[HeapRegion]:
    var entries = List[Int64]()
    for i in range(len(dvals)):
        entries.append(Int64(Int(dvals[i])))
    return Column.from_numeric_dict[DType.int32, DType.int32](
        _codes_i32(codes), entries^
    )


def _dict_f64(codes: List[Int32], dvals: List[Float64]) raises -> Column[HeapRegion]:
    var bits = List[Int64]()
    for i in range(len(dvals)):
        bits.append(Float64(dvals[i]).to_bits().cast[DType.int64]())
    return Column.from_numeric_dict[DType.int32, DType.float64](
        _codes_i32(codes), bits^
    )


def _dict_f32(codes: List[Int32], dvals: List[Float32]) raises -> Column[HeapRegion]:
    var bits = List[Int64]()
    for i in range(len(dvals)):
        bits.append(Int64(Int(Float32(dvals[i]).to_bits())))
    return Column.from_numeric_dict[DType.int32, DType.float32](
        _codes_i32(codes), bits^
    )


def _batch_1col(field_type: ArrowType, var c0: Column[HeapRegion]) raises -> RecordBatch:
    """Single-column batch; schema reports the LOGICAL `field_type` (NOT
    DICTIONARY — the contract the predicate name-resolver depends on)."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("x"), field_type, True))
    var rbb = RecordBatchBuilder.with_capacity(1)
    rbb.add_column(c0^)
    return rbb.build(sb.build())


def _assert_masks_equal(
    a: BooleanArray, b: BooleanArray, label: String
) raises:
    assert_equal(a.length, b.length, label + ": length")
    for i in range(a.length):
        assert_equal(a.get(i), b.get(i), label + ": bit " + String(i))


# -----------------------------------------------------------------------------
# 1. VALUE-EQUIV — LUT mask == flat mask == ground truth, all dtypes/ops.
# -----------------------------------------------------------------------------


def _check_i64_op(op_label: String, pred: Expr, codes: List[Int32], dvals: List[Int64], expected: List[Bool]) raises:
    var col_d = _dict_i64(codes, dvals)
    # Direct LUT + retained flat band-aid on the SAME column shape.
    var lut = numeric_dict_filter_bool_mask(col_d, _op_of(pred), _lit_of(pred))
    var col_d2 = _dict_i64(codes, dvals)
    var flat = numeric_dict_filter_via_flat(col_d2, _op_of(pred), _lit_of(pred))
    _assert_masks_equal(lut, flat, "i64 " + op_label + " LUT==flat")
    # Ground truth.
    assert_equal(lut.length, len(expected), "i64 " + op_label + " len")
    for i in range(len(expected)):
        assert_equal(lut.get(i), expected[i], "i64 " + op_label + " gt bit " + String(i))
    # End-to-end through _eval_predicate (the dispatcher arm).
    var batch = _batch_1col(ArrowType.INT64, _dict_i64(codes, dvals))
    var e2e = _eval_predicate(pred, batch)
    _assert_masks_equal(lut, e2e, "i64 " + op_label + " e2e")
    _ = batch^


def _op_of(pred: Expr) raises -> UInt8:
    return pred.binary_op()


def _lit_of(pred: Expr) raises -> ScalarValue:
    return pred.binary_right_ref().literal_value()


def test_value_equiv_int64_all_ops() raises:
    # codes -> dict [10, 20, 30, 40]; rows: 0,1,2,3,2,0 -> vals 10,20,30,40,30,10
    var codes: List[Int32] = [Int32(0), Int32(1), Int32(2), Int32(3), Int32(2), Int32(0)]
    var dvals: List[Int64] = [10, 20, 30, 40]
    # vals = [10,20,30,40,30,10]
    var gt25: List[Bool] = [False, False, True, True, True, False]
    _check_i64_op("GT25", col("x") > 25, codes, dvals, gt25)
    var lt25: List[Bool] = [True, True, False, False, False, True]
    _check_i64_op("LT25", col("x") < 25, codes, dvals, lt25)
    var eq30: List[Bool] = [False, False, True, False, True, False]
    _check_i64_op("EQ30", col("x") == 30, codes, dvals, eq30)
    var ne30: List[Bool] = [True, True, False, True, False, True]
    _check_i64_op("NE30", col("x") != 30, codes, dvals, ne30)
    var ge20: List[Bool] = [False, True, True, True, True, False]
    _check_i64_op("GE20", col("x") >= 20, codes, dvals, ge20)
    var le20: List[Bool] = [True, True, False, False, False, True]
    _check_i64_op("LE20", col("x") <= 20, codes, dvals, le20)


def test_value_equiv_int32() raises:
    var codes: List[Int32] = [Int32(0), Int32(1), Int32(2), Int32(1), Int32(0), Int32(2)]
    var dvals: List[Int32] = [Int32(-5), Int32(0), Int32(100)]
    # vals = [-5, 0, 100, 0, -5, 100]
    var pred = col("x") >= 0
    var col_d = _dict_i32(codes, dvals)
    var lut = numeric_dict_filter_bool_mask(col_d, pred.binary_op(), pred.binary_right_ref().literal_value())
    var col_d2 = _dict_i32(codes, dvals)
    var flat = numeric_dict_filter_via_flat(col_d2, pred.binary_op(), pred.binary_right_ref().literal_value())
    _assert_masks_equal(lut, flat, "i32 GE0 LUT==flat")
    var expected: List[Bool] = [False, True, True, True, False, True]
    for i in range(len(expected)):
        assert_equal(lut.get(i), expected[i], "i32 GE0 gt bit " + String(i))
    var batch = _batch_1col(ArrowType.INT32, _dict_i32(codes, dvals))
    var e2e = _eval_predicate(pred, batch)
    _assert_masks_equal(lut, e2e, "i32 GE0 e2e")
    _ = batch^


def test_value_equiv_float64() raises:
    var codes: List[Int32] = [Int32(0), Int32(1), Int32(2), Int32(0), Int32(2)]
    var dvals: List[Float64] = [1.5, 2.5, 3.5]
    # vals = [1.5, 2.5, 3.5, 1.5, 3.5]
    var pred = col("x") > 2.0
    var col_d = _dict_f64(codes, dvals)
    var lut = numeric_dict_filter_bool_mask(col_d, pred.binary_op(), pred.binary_right_ref().literal_value())
    var col_d2 = _dict_f64(codes, dvals)
    var flat = numeric_dict_filter_via_flat(col_d2, pred.binary_op(), pred.binary_right_ref().literal_value())
    _assert_masks_equal(lut, flat, "f64 GT2.0 LUT==flat")
    var expected: List[Bool] = [False, True, True, False, True]
    for i in range(len(expected)):
        assert_equal(lut.get(i), expected[i], "f64 GT2.0 gt bit " + String(i))
    var batch = _batch_1col(ArrowType.FLOAT64, _dict_f64(codes, dvals))
    var e2e = _eval_predicate(pred, batch)
    _assert_masks_equal(lut, e2e, "f64 GT2.0 e2e")
    _ = batch^


def test_value_equiv_float32() raises:
    var codes: List[Int32] = [Int32(0), Int32(1), Int32(2), Int32(1)]
    var dvals: List[Float32] = [Float32(0.25), Float32(0.75), Float32(1.25)]
    # vals = [0.25, 0.75, 1.25, 0.75]
    var pred = col("x") <= 0.75
    var col_d = _dict_f32(codes, dvals)
    var lut = numeric_dict_filter_bool_mask(col_d, pred.binary_op(), pred.binary_right_ref().literal_value())
    var col_d2 = _dict_f32(codes, dvals)
    var flat = numeric_dict_filter_via_flat(col_d2, pred.binary_op(), pred.binary_right_ref().literal_value())
    _assert_masks_equal(lut, flat, "f32 LE0.75 LUT==flat")
    var expected: List[Bool] = [True, True, False, True]
    for i in range(len(expected)):
        assert_equal(lut.get(i), expected[i], "f32 LE0.75 gt bit " + String(i))
    _ = col_d^
    _ = col_d2^


def test_value_equiv_wide_selectivities() raises:
    """A larger batch (crosses byte boundaries) at low / mid / high selectivity;
    LUT==flat at every threshold."""
    var dvals: List[Int64] = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]
    var codes = List[Int32]()
    for i in range(133):  # crosses 16 full bytes + a 5-bit tail.
        codes.append(Int32(i % 10))
    var thresholds: List[Int64] = [0, 1, 5, 9, 10]
    for ti in range(len(thresholds)):
        var thr = thresholds[ti]
        var pred = col("x") < Int(thr)
        var col_d = _dict_i64(codes, dvals)
        var lut = numeric_dict_filter_bool_mask(col_d, pred.binary_op(), pred.binary_right_ref().literal_value())
        var col_d2 = _dict_i64(codes, dvals)
        var flat = numeric_dict_filter_via_flat(col_d2, pred.binary_op(), pred.binary_right_ref().literal_value())
        _assert_masks_equal(lut, flat, "wide LT" + String(thr) + " LUT==flat")
        # Ground truth: val < thr where val = i%10.
        for i in range(len(codes)):
            var v = Int64(i % 10)
            assert_equal(lut.get(i), v < thr, "wide LT" + String(thr) + " bit " + String(i))


# -----------------------------------------------------------------------------
# 2. EXCLUSION — a dict code present ONLY in filtered-OUT rows must NOT survive.
# -----------------------------------------------------------------------------


def test_excluded_code_does_not_survive() raises:
    """dict = [100, 200]; code 1 (->200) appears ONLY at rows that the filter
    `x < 150` rejects. The keep-bit for code 1 is False, so NO row carrying it
    survives — and every code-0 row does."""
    var codes: List[Int32] = [Int32(0), Int32(1), Int32(0), Int32(1), Int32(1), Int32(0)]
    var dvals: List[Int64] = [100, 200]
    var pred = col("x") < 150
    var batch = _batch_1col(ArrowType.INT64, _dict_i64(codes, dvals))
    var mask = _eval_predicate(pred, batch)
    # rows with code 0 (val=100) pass; rows with code 1 (val=200) fail.
    var expected: List[Bool] = [True, False, True, False, False, True]
    for i in range(len(expected)):
        assert_equal(mask.get(i), expected[i], "exclusion bit " + String(i))
    assert_equal(mask.true_count(), 3, "exactly the 3 code-0 rows survive")
    _ = batch^


# -----------------------------------------------------------------------------
# 3. TWO-DISTINCT-DICT — col-vs-col across different dicts DECLINES (raises).
# -----------------------------------------------------------------------------


def test_two_distinct_dict_col_vs_col_declines() raises:
    """`a < b` where a and b are SEPARATE numeric-dict columns with DIFFERENT
    dictionaries. A code-vs-code compare across distinct dicts is silent-wrong;
    the evaluator must DECLINE (route to _eval_col_vs_col, which has no
    DICTIONARY arm -> raises). FAILS-ON-A-CODE-VS-CODE-IMPL: if a future change
    added a DICTIONARY arm to _eval_col_vs_col comparing raw codes, this would
    return a wrong mask instead of raising."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.INT64, False))
    sb.add_field(Field(String("b"), ArrowType.INT64, False))
    # a: dict [10, 99]; codes -> [10, 99]  (code 1 = value 99)
    # b: dict [50, 60]; codes -> [50, 60]  (code 1 = value 60)
    # By VALUE: a<b is [10<50, 99<60] = [True, False].
    # By CODE (the silent-wrong path): codes_a<codes_b = [0<0, 1<1] = [F, F] WRONG.
    var rbb = RecordBatchBuilder.with_capacity(2)
    var a_codes: List[Int32] = [Int32(0), Int32(1)]
    var a_dict: List[Int64] = [10, 99]
    var b_codes: List[Int32] = [Int32(0), Int32(1)]
    var b_dict: List[Int64] = [50, 60]
    rbb.add_column(_dict_i64(a_codes, a_dict))
    rbb.add_column(_dict_i64(b_codes, b_dict))
    var batch = rbb.build(sb.build())
    var pred = col("a") < col("b")
    var raised = False
    try:
        var _m = _eval_predicate(pred, batch)
    except e:
        raised = True
    assert_true(raised, "numeric-dict col-vs-col must DECLINE (raise), not code-compare")
    _ = batch^


# -----------------------------------------------------------------------------
# 4. NULLS — a numeric-dict column with a validity bitmap filters correctly.
# -----------------------------------------------------------------------------


def test_nulls_filtered_correctly() raises:
    """Rows 1 and 4 are NULL. The predicate `x > 15`, run through the REAL
    filter entry (`evaluate_filter_narrowed`, which applies the Arrow null
    collapse), must keep only non-null rows whose value passes; NULL rows
    collapse to FALSE. The dict column flows through as a dict (no
    pre-densification), so this exercises the LUT-over-codes + the row-validity
    null collapse together."""
    var dvals: List[Int64] = [10, 20, 30]
    # codes (value where valid): [0->10, X, 2->30, 1->20, X, 2->30]
    var codes: List[Int32] = [Int32(0), Int32(1), Int32(2), Int32(1), Int32(2), Int32(2)]
    var null_rows: List[Int] = [1, 4]
    var col_d = Column.from_numeric_dict[DType.int32, DType.int64](
        _codes_i32_nullable(codes, null_rows), _dict_entries(dvals)
    )
    var batch = _batch_1col(ArrowType.INT64, col_d^)
    var pred = col("x") > 15
    var sv = evaluate_filter_narrowed(batch, pred)
    # Surviving rows: r2(30), r3(20), r5(30). r0=10 fails; r1,r4 NULL -> drop.
    assert_equal(sv.length(), 3, "3 surviving rows (nulls excluded)")
    var survivors: List[Int] = []
    for i in range(sv.length()):
        survivors.append(Int(sv.indices.get_typed[Scalar[DType.int32]](i)))
    var want: List[Int] = [2, 3, 5]
    for k in range(len(want)):
        assert_equal(survivors[k], want[k], "survivor " + String(k))
    _ = batch^

    # Cross-check the raw LUT vs the flat band-aid on the SAME nullable column
    # (the predicate-level null-collapse is applied by the caller, so the raw
    # data masks must still agree before collapse).
    var col_lut = Column.from_numeric_dict[DType.int32, DType.int64](
        _codes_i32_nullable(codes, null_rows), _dict_entries(dvals)
    )
    var raw_lut = numeric_dict_filter_bool_mask(col_lut, pred.binary_op(), pred.binary_right_ref().literal_value())
    var col_flat = Column.from_numeric_dict[DType.int32, DType.int64](
        _codes_i32_nullable(codes, null_rows), _dict_entries(dvals)
    )
    var raw_flat = numeric_dict_filter_via_flat(col_flat, pred.binary_op(), pred.binary_right_ref().literal_value())
    _assert_masks_equal(raw_lut, raw_flat, "nullable raw LUT==flat")


# -----------------------------------------------------------------------------
# 5. THE PHASE-2 KERNEL'S TWO HOISTED DECISIONS (`numeric_dict_lut_scan`):
#    the CODE WIDTH (int64 codes take a different pointer type)
#    and the SLICE OFFSET (a zero-copy `Column.slice` addresses its codes at
#    `_offset + row`). Each is a branch the old per-row `dict_code_at` took
#    implicitly and the kernel now takes once, so each needs a leg of its own.
# -----------------------------------------------------------------------------


def test_int64_codes_match_flat() raises:
    """INT64 codes (`_dict_index_byte_width == 8`) through the LUT == flat,
    across byte boundaries and a partial tail byte."""
    var dvals: List[Int64] = [7, -3, 42, 0, 99]
    var l: List[Scalar[DType.int64]] = []
    for i in range(141):
        l.append(Int64((i * 3) % 5))
    var thresholds: List[Int64] = [-4, 0, 7, 42, 100]
    for ti in range(len(thresholds)):
        var pred = col("x") >= Int(thresholds[ti])
        var col_lut = Column.from_numeric_dict[DType.int64, DType.int64](
            PrimitiveArray[DType.int64].from_list(l), _dict_entries(dvals)
        )
        var lut = numeric_dict_filter_bool_mask(col_lut, pred.binary_op(), pred.binary_right_ref().literal_value())
        var col_flat = Column.from_numeric_dict[DType.int64, DType.int64](
            PrimitiveArray[DType.int64].from_list(l), _dict_entries(dvals)
        )
        var flat = numeric_dict_filter_via_flat(col_flat, pred.binary_op(), pred.binary_right_ref().literal_value())
        _assert_masks_equal(lut, flat, "int64-code GE" + String(thresholds[ti]))
        for i in range(len(l)):
            var v = dvals[(i * 3) % 5]
            assert_equal(lut.get(i), v >= thresholds[ti], "int64-code truth bit " + String(i))


def test_sliced_column_reads_from_its_offset() raises:
    """A zero-copy slice (`_offset > 0`) is scanned from ITS first row, not
    from row 0 of the shared code buffer."""
    var dvals: List[Int64] = [10, 20, 30, 40]
    var codes = List[Int32]()
    for i in range(200):
        codes.append(Int32(i % 4))
    var whole = _dict_i64(codes, dvals)
    var start = 37  # not a multiple of 8, so a row-0 read would shift the bits
    var n = 101
    var sliced = whole.slice(start, n)
    var pred = col("x") == 30
    var lut = numeric_dict_filter_bool_mask(sliced, pred.binary_op(), pred.binary_right_ref().literal_value())
    assert_equal(lut.length, n, "slice mask length")
    for i in range(n):
        assert_equal(lut.get(i), (start + i) % 4 == 2, "slice truth bit " + String(i))
    _ = whole^


def _dict_entries(dvals: List[Int64]) -> List[Int64]:
    var entries = List[Int64]()
    for i in range(len(dvals)):
        entries.append(dvals[i])
    return entries^


def main() raises:
    var suite = TestSuite()
    suite.test[test_value_equiv_int64_all_ops]()
    suite.test[test_value_equiv_int32]()
    suite.test[test_value_equiv_float64]()
    suite.test[test_value_equiv_float32]()
    suite.test[test_value_equiv_wide_selectivities]()
    suite.test[test_excluded_code_does_not_survive]()
    suite.test[test_two_distinct_dict_col_vs_col_declines]()
    suite.test[test_nulls_filtered_correctly]()
    suite.test[test_int64_codes_match_flat]()
    suite.test[test_sliced_column_reads_from_its_offset]()
    suite^.run()
