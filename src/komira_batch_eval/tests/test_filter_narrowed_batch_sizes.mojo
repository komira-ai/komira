# =============================================================================
# test_filter_narrowed_batch_sizes.mojo
#
# evaluate_filter_narrowed over int batches of the sizes a scan hands the
# filter (2048, 4096, 30000 rows, and sizes that are not multiples of the
# column's period). The predicate `c0 >= 25` keeps the rows whose value
# `i % 50` is at least 25; the survivors must be exactly those rows, in order.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Schema, Field, SchemaBuilder, RecordBatch, RecordBatchBuilder,
)
from komira_arrow.column import Column
from komira_arrow.arrow_types import ArrowType
from komira_plan_expr.col_expr import col, lit
from komira_plan_expr.expr import Expr
from komira_batch_eval.conjunction import evaluate_filter_narrowed


def _make_int_batch(n_rows: Int) raises -> RecordBatch:
    var c0 = PrimitiveArray[DType.int64].allocate(n_rows)
    var c1 = PrimitiveArray[DType.int64].allocate(n_rows)
    var p0 = c0._typed_ptr_mut()
    var p1 = c1._typed_ptr_mut()
    for i in range(n_rows):
        p0.store[width=1](i, Scalar[DType.int64](i % 50))
        p1.store[width=1](i, Scalar[DType.int64](100 + (i % 7)))
    var b = RecordBatchBuilder.with_capacity(2)
    var sb = SchemaBuilder()
    sb.add_field(Field("c0", ArrowType.INT64, False))
    sb.add_field(Field("c1", ArrowType.INT64, False))
    b.add_column(Column.from_primitive[DType.int64](c0^))
    b.add_column(Column.from_primitive[DType.int64](c1^))
    return b.build(sb.build())


def _check_size(n_rows: Int) raises:
    var batch = _make_int_batch(n_rows)
    var sel = evaluate_filter_narrowed(batch, col("c0") >= 25)
    var expected = 0
    for i in range(n_rows):
        if i % 50 >= 25:
            expected += 1
    assert_equal(sel.length(), expected)
    var ptr = sel.indices._typed_ptr_mut()
    var k = 0
    for i in range(n_rows):
        if i % 50 >= 25:
            assert_equal(Int(ptr[k]), i)
            k += 1


def test_filter_narrowed_2048_rows() raises:
    _check_size(2048)


def test_filter_narrowed_4096_rows() raises:
    _check_size(4096)


def test_filter_narrowed_30000_rows() raises:
    _check_size(30000)


def test_filter_narrowed_odd_size() raises:
    _check_size(1237)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
