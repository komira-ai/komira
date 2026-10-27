# The h2o-style join tables, generated from a seed: x, small, medium and big,
# after the h2o db-benchmark join data. It is not the original generator's
# random stream; the values are komira's own and are the same on every machine
# for the same seed and sizes.
#
# With N rows in x, K1 = N // 1000000, K2 = N // 1000 (each at least 1):
#
#   x       N rows   id1 INT32 1..K1, id2 INT32 1..K2, id3 INT32 1..N,
#                    id4 STRING "id"+id1, id5 STRING "id"+id2,
#                    id6 STRING "id"+id3, v1 FLOAT64 0..100
#   small   K1 rows  id1 INT32 (every key 1..K1 once), id4 STRING, v2 FLOAT64
#   medium  K2 rows  id1 INT32 1..K1, id2 INT32 (every key 1..K2 once),
#                    id4 STRING, id5 STRING, v2 FLOAT64
#   big     N rows   id1 INT32 1..K1, id2 INT32 1..K2,
#                    id3 INT32 (every key 1..N once),
#                    id4, id5, id6 STRING, v2 FLOAT64
#
# so every x key has a partner in each table, and the key a table is unique on
# is spread over its rows by a seeded bijection. No column holds a null.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from .draw import Bijection, draw_range, draw_score, plain_id
from .manifest import h2o_join_medium_rows, h2o_join_small_rows

def h2o_join_table_names() -> List[String]:
    """The four join tables, in the order the manifest lists them."""
    var out = List[String]()
    out.append(String("x"))
    out.append(String("small"))
    out.append(String("medium"))
    out.append(String("big"))
    return out^


def h2o_join_table_rows(table: String, rows: Int) raises -> Int:
    """The row count of a join table for an x table of `rows` rows.

    Raises:
        Error: a name that is not x, small, medium or big.
    """
    if table == "x" or table == "big":
        return rows
    if table == "small":
        return h2o_join_small_rows(rows)
    if table == "medium":
        return h2o_join_medium_rows(rows)
    raise Error("h2o join: no table '" + table + "' (x, small, medium, big)")


def _int_column(
    mut sb: SchemaBuilder, mut b: RecordBatchBuilder, name: String, var values: PrimitiveArray[DType.int32]
) raises:
    sb.add_field(Field(name, ArrowType.INT32, False))
    b.add_column(Column.from_primitive[DType.int32](values^))


def _string_column(
    mut sb: SchemaBuilder, mut b: RecordBatchBuilder, name: String, values: List[String]
) raises:
    sb.add_field(Field(name, ArrowType.STRING, False))
    b.add_column(Column.from_string(StringArray.from_strings(values)))


def _float_column(
    mut sb: SchemaBuilder, mut b: RecordBatchBuilder, name: String, var values: PrimitiveArray[DType.float64]
) raises:
    sb.add_field(Field(name, ArrowType.FLOAT64, False))
    b.add_column(Column.from_primitive[DType.float64](values^))


def h2o_join_batch(
    table: String, rows: Int, seed: UInt64, start: Int, count: Int
) raises -> RecordBatch:
    """Rows `start` .. `start + count - 1` of join table `table` (x, small,
    medium or big) for an x table of `rows` rows.

    Raises:
        Error: an unknown table, `rows` below 1, or a row range outside the
            table.
    """
    if rows < 1:
        raise Error("h2o_join_batch: rows must be at least 1")
    var total = h2o_join_table_rows(table, rows)
    if start < 0 or count < 0 or start + count > total:
        raise Error("h2o_join_batch: rows " + String(start) + "+" + String(count) + " are outside the " + String(total) + " rows of " + table)
    var k1 = h2o_join_small_rows(rows)
    var k2 = h2o_join_medium_rows(rows)
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    var id1 = PrimitiveArray[DType.int32].allocate(count)
    var id2 = PrimitiveArray[DType.int32].allocate(count)
    var id3 = PrimitiveArray[DType.int32].allocate(count)
    var id4 = List[String]()
    var id5 = List[String]()
    var id6 = List[String]()
    var score = PrimitiveArray[DType.float64].allocate(count)
    if table == "x":
        for i in range(count):
            var r = start + i
            var a = draw_range(seed, 20, r, k1)
            var c = draw_range(seed, 21, r, k2)
            var d = draw_range(seed, 22, r, rows)
            id1.set(i, Int32(a))
            id2.set(i, Int32(c))
            id3.set(i, Int32(d))
            id4.append(plain_id(a))
            id5.append(plain_id(c))
            id6.append(plain_id(d))
            score.set(i, draw_score(seed, 23, r))
        _int_column(sb, b, "id1", id1^)
        _int_column(sb, b, "id2", id2^)
        _int_column(sb, b, "id3", id3^)
        _string_column(sb, b, "id4", id4)
        _string_column(sb, b, "id5", id5)
        _string_column(sb, b, "id6", id6)
        _float_column(sb, b, "v1", score^)
    elif table == "small":
        var keys = Bijection(seed, 30, k1)
        for i in range(count):
            var a = keys.key(start + i)
            id1.set(i, Int32(a))
            id4.append(plain_id(a))
            score.set(i, draw_score(seed, 31, start + i))
        _int_column(sb, b, "id1", id1^)
        _string_column(sb, b, "id4", id4)
        _float_column(sb, b, "v2", score^)
    elif table == "medium":
        var keys = Bijection(seed, 32, k2)
        for i in range(count):
            var r = start + i
            var a = draw_range(seed, 33, r, k1)
            var c = keys.key(r)
            id1.set(i, Int32(a))
            id2.set(i, Int32(c))
            id4.append(plain_id(a))
            id5.append(plain_id(c))
            score.set(i, draw_score(seed, 34, r))
        _int_column(sb, b, "id1", id1^)
        _int_column(sb, b, "id2", id2^)
        _string_column(sb, b, "id4", id4)
        _string_column(sb, b, "id5", id5)
        _float_column(sb, b, "v2", score^)
    else:
        var keys = Bijection(seed, 35, rows)
        for i in range(count):
            var r = start + i
            var a = draw_range(seed, 36, r, k1)
            var c = draw_range(seed, 37, r, k2)
            var d = keys.key(r)
            id1.set(i, Int32(a))
            id2.set(i, Int32(c))
            id3.set(i, Int32(d))
            id4.append(plain_id(a))
            id5.append(plain_id(c))
            id6.append(plain_id(d))
            score.set(i, draw_score(seed, 38, r))
        _int_column(sb, b, "id1", id1^)
        _int_column(sb, b, "id2", id2^)
        _int_column(sb, b, "id3", id3^)
        _string_column(sb, b, "id4", id4)
        _string_column(sb, b, "id5", id5)
        _string_column(sb, b, "id6", id6)
        _float_column(sb, b, "v2", score^)
    return b.build(sb.build())
