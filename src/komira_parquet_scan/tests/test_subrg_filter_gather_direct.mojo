# subrg_filter_gather on hand-built values:
#   - the dict-select-safe shapes (AND/OR of `col <cmp> lit`) and the ones
#     refused (a literal on the left, arithmetic, a bare column);
#   - the single-column test;
#   - the keep-table of a dictionary, INT32 and INT64, with its 0 sentinel,
#     and its refusal of another key type;
#   - the codes compaction: a uniform 16-code block kept and dropped, a mixed
#     block, the tail, an out-of-range code and an empty dictionary (-1),
#     short buffers refused;
#   - the survivor gather, in selection order;
#   - the counters.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.selection_vector import SelectionVector
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_scan.subrg_filter_gather import (
    build_dict_keep_lut,
    compact_codes_by_lut,
    gather_selected,
    pred_is_dict_select_safe,
    pred_refs_only_column,
    subrg_filter_gathered_count,
    subrg_filter_keylut_count,
    subrg_filter_record,
    subrg_filter_skipped_count,
)
from komira_plan_expr.expr import BIN_ADD, BIN_AND, BIN_EQ, BIN_GT, BIN_LT, BIN_NE, BIN_OR, Expr
from komira_plan_expr.scalar_value import ScalarValue


def _lit(v: Int) -> Expr:
    return Expr.literal(ScalarValue.from_int(v))


def _cmp(op: UInt8, col: String, v: Int) -> Expr:
    return Expr.binary(op, Expr.col_ref(col), _lit(v))


def test_dict_select_safe_shapes() raises:
    assert_true(pred_is_dict_select_safe(_cmp(BIN_NE, "k", 0)))
    var tree = Expr.binary(BIN_OR, _cmp(BIN_LT, "k", 3), Expr.binary(BIN_AND, _cmp(BIN_GT, "k", 9), _cmp(BIN_NE, "j", 12)))
    assert_true(pred_is_dict_select_safe(tree))
    assert_false(pred_is_dict_select_safe(Expr.binary(BIN_EQ, _lit(1), Expr.col_ref("k"))))
    var arith = Expr.binary(BIN_GT, Expr.binary(BIN_ADD, Expr.col_ref("k"), _lit(1)), _lit(3))
    assert_false(pred_is_dict_select_safe(arith))
    assert_false(pred_is_dict_select_safe(Expr.col_ref("k")))
    assert_false(pred_is_dict_select_safe(Expr.binary(BIN_AND, _cmp(BIN_NE, "k", 0), arith.copy())))
    assert_false(pred_refs_only_column(tree, "k"))
    assert_true(pred_refs_only_column(Expr.binary(BIN_OR, _cmp(BIN_LT, "k", 3), _cmp(BIN_GT, "k", 9)), "k"))


def test_the_keep_table() raises:
    var d: List[Int64] = [5, -2, 7, 0]
    var pred = Expr.binary(BIN_OR, _cmp(BIN_LT, "k", 0), _cmp(BIN_GT, "k", 6))
    for t in [ArrowType.INT32, ArrowType.INT64]:
        var lut = build_dict_keep_lut(d, "k", t, pred)
        assert_equal(len(lut), 5)
        assert_equal(Int(lut[0]), 0)
        assert_equal(Int(lut[1]), 1)
        assert_equal(Int(lut[2]), 1)
        assert_equal(Int(lut[3]), 0)
        assert_equal(Int(lut[4]), 0)  # the sentinel
    with assert_raises(contains="INT32 or INT64"):
        _ = build_dict_keep_lut(d, "k", ArrowType.FLOAT64, pred)


def _codes(values: List[Int]) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(len(values) * 4)
    b.set_length(Int64(len(values) * 4))
    for i in range(len(values)):
        b.set_typed[Int32](i, Int32(values[i]))
    return b^


def _out(n: Int) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer((n + 1) * 4)
    b.set_length(Int64((n + 1) * 4))
    return b^


def test_the_codes_compaction() raises:
    # Dictionary of 3: codes 0 and 2 are kept.
    var lut: List[UInt8] = [1, 0, 1, 0]
    var values = List[Int]()
    for _ in range(16):
        values.append(2)  # a uniform kept block
    for _ in range(16):
        values.append(1)  # a uniform dropped block
    for i in range(16):
        values.append(i % 3)  # a mixed block
    values.append(0)  # a tail of three
    values.append(1)
    values.append(2)
    var n = len(values)
    var codes = _codes(values)
    var out = _out(n)
    var w = compact_codes_by_lut(codes, n, lut, out)
    var want = List[Int]()
    for i in range(n):
        if values[i] != 1:
            want.append(values[i])
    assert_equal(w, len(want))
    for i in range(w):
        assert_equal(Int(out.get_typed[Int32](i)), want[i])
    assert_equal(compact_codes_by_lut(codes, 0, lut, out), 0)


def test_codes_outside_the_dictionary() raises:
    var lut: List[UInt8] = [1, 1, 0]
    var values: List[Int] = [0, 1, 2, 0]
    var out = _out(4)
    assert_equal(compact_codes_by_lut(_codes(values), 4, lut, out), -1)
    var neg: List[Int] = [0, -1]
    assert_equal(compact_codes_by_lut(_codes(neg), 2, lut, out), -1)
    var empty: List[UInt8] = [0]
    assert_equal(compact_codes_by_lut(_codes([0, 0]), 2, empty, out), -1)
    with assert_raises(contains="buffers too small"):
        _ = compact_codes_by_lut(_codes([0, 0]), 3, lut, out)
    with assert_raises(contains="buffers too small"):
        var small = _out(1)
        _ = compact_codes_by_lut(_codes([0, 0, 0]), 3, lut, small)


def test_the_survivor_gather_and_counters() raises:
    var vals = List[Scalar[DType.int64]]()
    for i in range(6):
        vals.append(Scalar[DType.int64](i * 10))
    var sb = SchemaBuilder()
    sb.add_field(Field("x", ArrowType.INT64, False))
    var batch = RecordBatch.from_typed_columns_1(
        sb.build(), Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(vals^))
    )
    var idx = PrimitiveArray[DType.int32].allocate(3)
    idx.set_typed[Scalar[DType.int32]](0, 1)
    idx.set_typed[Scalar[DType.int32]](1, 4)
    idx.set_typed[Scalar[DType.int32]](2, 5)
    var got = gather_selected(batch, SelectionVector(idx^))
    assert_equal(got.num_rows(), 3)
    assert_equal(Int(got.column_at(0).as_primitive[DType.int64]().get(0)), 10)
    assert_equal(Int(got.column_at(0).as_primitive[DType.int64]().get(2)), 50)
    var g0 = subrg_filter_gathered_count()
    var s0 = subrg_filter_skipped_count()
    var k0 = subrg_filter_keylut_count()
    subrg_filter_record(2, 0, 3)
    subrg_filter_record(0, 1, 0)
    assert_equal(subrg_filter_gathered_count() - g0, 2)
    assert_equal(subrg_filter_skipped_count() - s0, 1)
    assert_equal(subrg_filter_keylut_count() - k0, 3)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
