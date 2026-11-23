# =============================================================================
# test_empty_batch_decimal_metadata -- an empty batch keeps a DECIMAL column's
# precision and scale on the column
# =============================================================================
#
# `empty_batch_like` and `empty_batch_like_schema` build the zero-row batch an
# operator answers when no row survives (`sink_collect`, the group sinks, an
# in-memory source of no batches). A DECIMAL column reads its (precision,
# scale) from the column itself (`Column.as_decimal128`), not from the schema,
# so a zero-row column without them is refused by every reader that decodes
# it: `COPY (SELECT * FROM t WHERE false) TO 'x.parquet'` over a DECIMAL column
# failed with "column carries no precision/scale metadata".
#
# What each test proves:
#   * test_empty_batch_like_keeps_the_decimal_metadata: the zero-row copy of a
#     batch of a DECIMAL(12, 2) and an INT64 column has a DECIMAL column of
#     precision 12 and scale 2 that `as_decimal128` reads as no values, and an
#     INT64 column with no decimal metadata.
#   * test_empty_batch_like_schema_keeps_the_decimal_metadata: the same from
#     the schema alone, for DECIMAL(30, 4).

from std.testing import TestSuite, assert_equal

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from column_kernels.compiler_helpers import (
    empty_batch_like,
    empty_batch_like_schema,
)


def _batch(precision: Int, scale: Int) raises -> RecordBatch:
    var m = Decimal128Array.allocate_nullable(2, precision, scale)
    m.set_i128(0, Scalar[DType.int64](1234).cast[DType.int128]())
    m.set_null(1)
    var k = PrimitiveArray[DType.int64].allocate(2)
    k.set(0, 1)
    k.set(1, 2)
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("m", precision, scale, True))
    sb.add_field(Field("k", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_decimal128(m^))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    return rb.build(sb.build())


def _check(ref empty: RecordBatch, precision: Int, scale: Int) raises:
    assert_equal(empty.num_rows(), 0)
    assert_equal(empty.column_at(0).decimal_precision(), precision)
    assert_equal(empty.column_at(0).decimal_scale(), scale)
    assert_equal(len(empty.column_at(0).as_decimal128()), 0)
    assert_equal(empty.column_at(1).decimal_precision(), 0)
    assert_equal(empty.schema.field_decimal_precision(0), precision)


def test_empty_batch_like_keeps_the_decimal_metadata() raises:
    var batch = _batch(12, 2)
    var empty = empty_batch_like(batch)
    _check(empty, 12, 2)


def test_empty_batch_like_schema_keeps_the_decimal_metadata() raises:
    var batch = _batch(30, 4)
    var empty = empty_batch_like_schema(batch.schema)
    _check(empty, 30, 4)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
