# =============================================================================
# group_harness -- a table to group, for tests and measurements of the grouped sink
# =============================================================================
#
# `group_batch(start, rows)` holds rows `start .. start + rows - 1` of a table
# of five columns; the value of every cell is a function of its row number r,
# given below, so a test computes what it expects from r alone:
#
#   k1  INT64, NULL where r % 13 == 5, else (r * 7) % 11
#   k2  INT32, NULL where r % 17 == 4, else r % 3
#   v   INT64, NULL where r % 5 == 2, else r * 3 - 50
#   d   DECIMAL(20,2), NULL where r % 7 == 3, else the unscaled r * 1000 + 7
#   id  INT64, no NULL, r (a key with a group for every row)
#
# `float_batch(start, rows)` holds a FLOAT64 key `kf`, a FLOAT32 key `kg` and
# an INT64 value `v` (as above):
#
#   kf  NULL where r % 9 == 0, else by r % 4: -0.0, 0.0, NaN, 1.5
#   kg  NULL where r % 9 == 0, else by r % 4: -0.0, 0.0, NaN, 2.5

from std.memory import bitcast

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_scalar_arithmetic.decimal_arith import I128


def k1_null(r: Int) -> Bool:
    return r % 13 == 5


def k1_value(r: Int) -> Int:
    return (r * 7) % 11


def k2_null(r: Int) -> Bool:
    return r % 17 == 4


def k2_value(r: Int) -> Int:
    return r % 3


def v_null(r: Int) -> Bool:
    return r % 5 == 2


def v_value(r: Int) -> Int:
    return r * 3 - 50


def d_null(r: Int) -> Bool:
    return r % 7 == 3


def d_unscaled(r: Int) -> Int:
    return r * 1000 + 7


def float_null(r: Int) -> Bool:
    return r % 9 == 0


def float_class(r: Int) -> Int:
    """0 is -0.0, 1 is 0.0, 2 is NaN and 3 is the plain value."""
    return r % 4


def group_batch(start: Int, rows: Int) raises -> RecordBatch:
    var k1 = ColumnBuilder[DType.int64].with_capacity(rows)
    var k2 = ColumnBuilder[DType.int32].with_capacity(rows)
    var v = ColumnBuilder[DType.int64].with_capacity(rows)
    var d = Decimal128Array.allocate_nullable(rows, 20, 2)
    var id = PrimitiveArray[DType.int64].allocate(rows)
    for i in range(rows):
        var r = start + i
        if k1_null(r):
            k1.append_null()
        else:
            k1.append(Int64(k1_value(r)))
        if k2_null(r):
            k2.append_null()
        else:
            k2.append(Int32(k2_value(r)))
        if v_null(r):
            v.append_null()
        else:
            v.append(Int64(v_value(r)))
        if d_null(r):
            d.set_null(i)
        else:
            d.set_i128(i, I128(d_unscaled(r)))
        id.set(i, Int64(r))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k1", ArrowType.INT64, True))
    rb.add_column(k1^.materialize())
    sb.add_field(Field("k2", ArrowType.INT32, True))
    rb.add_column(k2^.materialize())
    sb.add_field(Field("v", ArrowType.INT64, True))
    rb.add_column(v^.materialize())
    sb.add_field(Field.decimal128("d", 20, 2, True))
    rb.add_column(Column.from_decimal128(d^))
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](id^))
    return rb.build(sb.build())


def _float_of(r: Int) -> Float64:
    var c = float_class(r)
    if c == 0:
        return -0.0
    if c == 1:
        return 0.0
    if c == 2:
        return bitcast[DType.float64](UInt64(0x7FF8000000000000))
    return 1.5


def float_batch(start: Int, rows: Int) raises -> RecordBatch:
    var kf = ColumnBuilder[DType.float64].with_capacity(rows)
    var kg = ColumnBuilder[DType.float32].with_capacity(rows)
    var v = ColumnBuilder[DType.int64].with_capacity(rows)
    for i in range(rows):
        var r = start + i
        if float_null(r):
            kf.append_null()
            kg.append_null()
        else:
            var f = _float_of(r)
            kf.append(f)
            if float_class(r) == 3:
                kg.append(Float32(2.5))
            else:
                kg.append(f.cast[DType.float32]())
        if v_null(r):
            v.append_null()
        else:
            v.append(Int64(v_value(r)))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("kf", ArrowType.FLOAT64, True))
    rb.add_column(kf^.materialize())
    sb.add_field(Field("kg", ArrowType.FLOAT32, True))
    rb.add_column(kg^.materialize())
    sb.add_field(Field("v", ArrowType.INT64, True))
    rb.add_column(v^.materialize())
    return rb.build(sb.build())
