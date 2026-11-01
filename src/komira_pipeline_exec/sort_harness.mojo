# =============================================================================
# sort_harness -- the table the sort tests share, and the oracle they compare against
# =============================================================================
#
# Row r of the table (a function of r alone, so any slice of rows can be built):
#   id  INT64, no NULL, r
#   x   INT64, NULL where r % 6 == 1, else (r * 7) % 5
#   t   STRING, NULL where r % 5 == 2, else "k" + ((r * 3) % 4)
#   f   FLOAT64, NULL where r % 4 == 3, else (r * 5) % 7
# The values repeat, so keys tie often, and the id says in what order the tied
# rows came out.
#
# `oracle_order` sorts the ids 0 .. n-1 by a key list with an insertion sort
# that places a row after every row not greater than it (stable), comparing
# each key as the plan states: a NULL against a NULL is a tie, a NULL against a
# value goes first or last by `nulls_first`, two values by the direction.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray

comptime X = 0
comptime T = 1
comptime F = 2


def null_at(col: Int, r: Int) -> Bool:
    if col == X:
        return r % 6 == 1
    if col == T:
        return r % 5 == 2
    return r % 4 == 3


def key_value(col: Int, r: Int) -> Float64:
    """The value of a numeric column at row r (the string column's rank
    "k0" .. "k3" is its number)."""
    if col == X:
        return Float64((r * 7) % 5)
    if col == T:
        return Float64((r * 3) % 4)
    return Float64((r * 5) % 7)


def table(start: Int, rows: Int) raises -> RecordBatch:
    var ids = PrimitiveArray[DType.int64].allocate(rows)
    var x = ColumnBuilder[DType.int64].with_capacity(rows)
    var f = ColumnBuilder[DType.float64].with_capacity(rows)
    var t = List[String]()
    var t_valid = List[Bool]()
    for i in range(rows):
        var r = start + i
        ids.set(i, Int64(r))
        if null_at(X, r):
            x.append_null()
        else:
            x.append(Int64(key_value(X, r)))
        if null_at(F, r):
            f.append_null()
        else:
            f.append(key_value(F, r))
        t_valid.append(not null_at(T, r))
        t.append(String("k") + String(Int(key_value(T, r))))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](ids^))
    sb.add_field(Field("x", ArrowType.INT64, True))
    rb.add_column(x^.materialize())
    sb.add_field(Field("t", ArrowType.STRING, True))
    rb.add_column(Column.from_string(StringArray.from_strings_with_validity(t, t_valid)))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    rb.add_column(f^.materialize())
    return rb.build(sb.build())


def col_name(col: Int) -> String:
    if col == X:
        return "x"
    if col == T:
        return "t"
    return "f"


def _cmp(a: Int, b: Int, cols: List[Int], desc: List[Bool], nf: List[Bool]) -> Int:
    """Negative when row a sorts before row b, positive after, 0 on a tie."""
    for k in range(len(cols)):
        var an = null_at(cols[k], a)
        var bn = null_at(cols[k], b)
        if an and bn:
            continue
        if an:
            return -1 if nf[k] else 1
        if bn:
            return 1 if nf[k] else -1
        var av = key_value(cols[k], a)
        var bv = key_value(cols[k], b)
        if av == bv:
            continue
        var lt = av < bv
        if desc[k]:
            lt = not lt
        return -1 if lt else 1
    return 0


def oracle_order(
    n: Int, cols: List[Int], desc: List[Bool], nf: List[Bool]
) -> List[Int]:
    var out = List[Int]()
    for r in range(n):
        var at = len(out)
        while at > 0 and _cmp(out[at - 1], r, cols, desc, nf) > 0:
            at -= 1
        out.insert(at, r)
    return out^
