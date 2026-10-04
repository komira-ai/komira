# =============================================================================
# Morsel.replace_batch unit test (EXEC-OPCHAIN / WS-EXEC RFC stage 2)
# =============================================================================
#
# Guards the safe encapsulated batch swap added for OpChainAdapter (S5,
# mojo-expert review). `replace_batch` must (a) install the new
# batch, (b) drop the old one, (c) leave the POD id fields untouched. Body is
# a plain field-assign — NOT a relocated UnsafePointer destroy/init dance.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_morsel.morsel import Morsel


comptime I64 = DType.int64


def _mk_i64_batch(name: String, var vals: List[Int64]) raises -> RecordBatch:
    var n = len(vals)
    var arr = PrimitiveArray[I64].allocate(n)
    for i in range(n):
        arr.set(i, vals[i])
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.INT64, True))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_primitive[I64](arr^))
    return b.build(sb.build())


def test_replace_batch_installs_new_drops_old() raises:
    # Original batch: 1 col "a" of [1,2,3].
    var m = Morsel(_mk_i64_batch(String("a"), [Int64(1), 2, 3]), 5, 9, 3)
    assert_equal(m.batch.num_columns(), 1, "original 1 col")
    assert_equal(m.batch.num_rows(), 3, "original 3 rows")

    # Replace with a 2-col batch "b","c" of length 2.
    var newb = RecordBatchBuilder()
    var sb = SchemaBuilder()
    sb.add_field(Field("b", ArrowType.INT64, True))
    sb.add_field(Field("c", ArrowType.INT64, True))
    var barr = PrimitiveArray[I64].allocate(2)
    barr.set(0, 10); barr.set(1, 11)
    var carr = PrimitiveArray[I64].allocate(2)
    carr.set(0, 20); carr.set(1, 21)
    newb.add_column(Column.from_primitive[I64](barr^))
    newb.add_column(Column.from_primitive[I64](carr^))
    m.replace_batch(newb.build(sb.build()))

    # New batch installed.
    assert_equal(m.batch.num_columns(), 2, "replaced -> 2 cols")
    assert_equal(m.batch.num_rows(), 2, "replaced -> 2 rows")
    assert_equal(m.batch.schema.field_name(0), "b", "col0 name")
    assert_equal(m.batch.schema.field_name(1), "c", "col1 name")
    var c0 = m.batch.column_at(0).as_primitive[I64]()
    assert_equal(c0.get(0), 10, "b[0]")
    assert_equal(c0.get(1), 11, "b[1]")

    # POD id fields untouched.
    assert_equal(m.morsel_id, 5, "morsel_id preserved")
    assert_equal(m.partition_id, 9, "partition_id preserved")
    assert_equal(m.origin_hint, 3, "origin_hint preserved")


def test_replace_batch_with_empty() raises:
    var m = Morsel(_mk_i64_batch(String("a"), [Int64(7), 8]), 0, 0, 0)
    m.replace_batch(RecordBatch())
    assert_equal(m.batch.num_rows(), 0, "empty batch installed")
    assert_true(m.batch.num_columns() == 0, "empty batch 0 cols")


def main() raises:
    var suite = TestSuite()
    suite.test[test_replace_batch_installs_new_drops_old]()
    suite.test[test_replace_batch_with_empty]()
    suite^.run()
