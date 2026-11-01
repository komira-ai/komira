# The h2o-style group-by table, generated from a seed. It has the columns and
# the value ranges of the h2o db-benchmark group-by data (the G1 files): three
# string keys, three integer keys, two small integers and a score. It is not
# the original generator's random stream, which is an R script; the values are
# komira's own and are the same on every machine for the same seed and sizes.
#
#   id1, id2  STRING   "id" + a number in 1..k, three digits ("id042")
#   id3       STRING   "id" + a number in 1..n3, ten digits ("id0000004711")
#   id4, id5  INT32    1..k
#   id6       INT32    1..n3
#   v1, v2    INT32    1..5
#   v3        FLOAT64  0..100 with six decimals
#
# k is the group count and n3 is `rows // k` (at least 1). No column holds a
# null.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from .draw import draw_range, draw_score, padded_id
from .manifest import h2o_groupby_id3_range


def h2o_groupby_batch(
    rows: Int, groups: Int, seed: UInt64, start: Int, count: Int
) raises -> RecordBatch:
    """Rows `start` .. `start + count - 1` of the group-by table of `rows`
    rows and `groups` groups.

    Raises:
        Error: `groups` outside 1..rows, or a row range outside 0..rows.
    """
    if groups < 1 or groups > rows:
        raise Error("h2o_groupby_batch: groups must be in 1..rows, got " + String(groups))
    if start < 0 or count < 0 or start + count > rows:
        raise Error("h2o_groupby_batch: rows " + String(start) + "+" + String(count) + " are outside 0.." + String(rows))
    var n3 = h2o_groupby_id3_range(rows, groups)
    var id1 = List[String]()
    var id2 = List[String]()
    var id3 = List[String]()
    var id4 = PrimitiveArray[DType.int32].allocate(count)
    var id5 = PrimitiveArray[DType.int32].allocate(count)
    var id6 = PrimitiveArray[DType.int32].allocate(count)
    var v1 = PrimitiveArray[DType.int32].allocate(count)
    var v2 = PrimitiveArray[DType.int32].allocate(count)
    var v3 = PrimitiveArray[DType.float64].allocate(count)
    for i in range(count):
        var r = start + i
        id1.append(padded_id(draw_range(seed, 1, r, groups), 3))
        id2.append(padded_id(draw_range(seed, 2, r, groups), 3))
        id3.append(padded_id(draw_range(seed, 3, r, n3), 10))
        id4.set(i, Int32(draw_range(seed, 4, r, groups)))
        id5.set(i, Int32(draw_range(seed, 5, r, groups)))
        id6.set(i, Int32(draw_range(seed, 6, r, n3)))
        v1.set(i, Int32(draw_range(seed, 7, r, 5)))
        v2.set(i, Int32(draw_range(seed, 8, r, 5)))
        v3.set(i, draw_score(seed, 9, r))
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    sb.add_field(Field("id1", ArrowType.STRING, False))
    b.add_column(Column.from_string(StringArray.from_strings(id1)))
    sb.add_field(Field("id2", ArrowType.STRING, False))
    b.add_column(Column.from_string(StringArray.from_strings(id2)))
    sb.add_field(Field("id3", ArrowType.STRING, False))
    b.add_column(Column.from_string(StringArray.from_strings(id3)))
    sb.add_field(Field("id4", ArrowType.INT32, False))
    b.add_column(Column.from_primitive[DType.int32](id4))
    sb.add_field(Field("id5", ArrowType.INT32, False))
    b.add_column(Column.from_primitive[DType.int32](id5))
    sb.add_field(Field("id6", ArrowType.INT32, False))
    b.add_column(Column.from_primitive[DType.int32](id6))
    sb.add_field(Field("v1", ArrowType.INT32, False))
    b.add_column(Column.from_primitive[DType.int32](v1))
    sb.add_field(Field("v2", ArrowType.INT32, False))
    b.add_column(Column.from_primitive[DType.int32](v2))
    sb.add_field(Field("v3", ArrowType.FLOAT64, False))
    b.add_column(Column.from_primitive[DType.float64](v3))
    return b.build(sb.build())
