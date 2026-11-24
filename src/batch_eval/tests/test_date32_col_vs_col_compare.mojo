# =============================================================================
# test_date32_col_vs_col_compare: two DATE32 columns compare by their days
# =============================================================================
#
# A scalar subquery over a DATE (`d >= (SELECT min(d2) FROM u)`) is a column
# of the cross join it is decorrelated into, so the filter compares two DATE32
# columns. `_eval_col_vs_col` compares them as the int32 days they hold, with
# a NULL on either side giving NULL (dropped by a filter).
#
#   test_date32_columns_compare_by_day   GE, LT and EQ of two DATE32 columns
#                                        give the per-row answer of the days,
#                                        and a NULL on either side is NULL.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from byte_buffer.heap_region import HeapRegion
from plan_expr.expr import BIN_EQ, BIN_GE, BIN_LT

from batch_eval.predicate_compare import _eval_col_vs_col


def _date_column(values: List[Int32], nulls: List[Bool]) -> Column[HeapRegion]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int32].allocate_nullable(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = values[i]
    for i in range(n):
        if nulls[i]:
            arr._set_null(i)
    return Column.from_primitive_with_arrow_type[DType.int32](arr^, ArrowType.DATE32)


def _batch() raises -> RecordBatch:
    """a = [20000, 20001, 20002, NULL, 20003], b = [20001, 20001, 20001, 20001, NULL]."""
    var a: List[Int32] = [20000, 20001, 20002, 0, 20003]
    var an: List[Bool] = [False, False, False, True, False]
    var b: List[Int32] = [20001, 20001, 20001, 20001, 0]
    var bn: List[Bool] = [False, False, False, False, True]
    var rbb = RecordBatchBuilder.with_capacity(2)
    rbb.add_column(_date_column(a, an))
    rbb.add_column(_date_column(b, bn))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.DATE32, True))
    sb.add_field(Field("b", ArrowType.DATE32, True))
    return rbb.build(sb.build())


def _check(op: UInt8, want: List[Bool], label: String) raises:
    var batch = _batch()
    var got = _eval_col_vs_col(batch, 0, 1, ArrowType.DATE32, op)
    assert_equal(got.length, 5, label + ": length")
    for i in range(3):
        assert_false(got.is_null(i), label + ": row " + String(i) + " is not NULL")
        assert_equal(got.get(i), want[i], label + ": row " + String(i))
    assert_true(got.is_null(3), label + ": a NULL left date is NULL")
    assert_true(got.is_null(4), label + ": a NULL right date is NULL")


def test_date32_columns_compare_by_day() raises:
    var ge: List[Bool] = [False, True, True]
    _check(BIN_GE, ge, "a >= b")
    var lt: List[Bool] = [True, False, False]
    _check(BIN_LT, lt, "a < b")
    var eq: List[Bool] = [False, True, False]
    _check(BIN_EQ, eq, "a = b")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
