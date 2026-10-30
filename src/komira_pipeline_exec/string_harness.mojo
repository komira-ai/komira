# =============================================================================
# string_harness -- a table with string keys, for tests of the string-keyed sink
# =============================================================================
#
# `string_column(values, valid, form, rot)` is one string key column of a
# morsel in one of three forms:
#
#   FORM_FLAT       a STRING column.
#   FORM_DICT       a DICTIONARY column whose entries are the distinct values
#                   in the order they first appear.
#   FORM_SHUFFLED   a DICTIONARY column whose entries are those, rotated left
#                   by `rot`, then two entries no row uses, then a second copy
#                   of the first distinct value: rows holding that value at an
#                   even position use the copy's code. So the same string has
#                   two codes in one dictionary and different codes in
#                   different batches. The code under a NULL row is far outside
#                   the dictionary (a reader that looked at it would fail).
#
# `string_batch(start, rows, form)` holds rows `start .. start + rows - 1` of a
# table of four columns, the value of every cell a function of its row number
# r, given below, so a test computes what it expects from r alone:
#
#   s1  string, NULL where r % 13 == 5, else S1[(r * 5 + r // 6) % 6] with
#       S1 = ["pear", "apple", "", "fig", "kiwi", "a longer key with spaces"]
#   s2  string, NULL where r % 17 == 4, else S2[(r * 3 + r // 4) % 5] with
#       S2 = ["red", "green", "", "blue", "été"]
#   v   INT64, NULL where r % 5 == 2, else r * 3 - 50
#   d   DECIMAL(20,2), NULL where r % 7 == 3, else the unscaled r * 1000 + 7
#
# The empty string is a value of both keys, and NULL is another.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.column_builder import ColumnBuilder
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_scalar_arithmetic.decimal_arith import I128

from .group_harness import d_null, d_unscaled, v_null, v_value

comptime FORM_FLAT: Int = 0
comptime FORM_DICT: Int = 1
comptime FORM_SHUFFLED: Int = 2

comptime _FAR_CODE: Int = 1000000


def s1_pool() -> List[String]:
    var out = List[String]()
    out.append("pear")
    out.append("apple")
    out.append("")
    out.append("fig")
    out.append("kiwi")
    out.append("a longer key with spaces")
    return out^


def s2_pool() -> List[String]:
    var out = List[String]()
    out.append("red")
    out.append("green")
    out.append("")
    out.append("blue")
    out.append("été")
    return out^


def s1_null(r: Int) -> Bool:
    return r % 13 == 5


def s1_value(r: Int) -> String:
    return s1_pool()[(r * 5 + r // 6) % 6]


def s2_null(r: Int) -> Bool:
    return r % 17 == 4


def s2_value(r: Int) -> String:
    return s2_pool()[(r * 3 + r // 4) % 5]


def string_column(
    ref values: List[String], ref valid: List[Bool], form: Int, rot: Int
) raises -> Column[HeapRegion]:
    """The column of `values` (`valid[i]` False: row i is NULL) in `form`; the
    dictionary of FORM_SHUFFLED is rotated left by `rot`."""
    var n = len(values)
    if form == FORM_FLAT:
        return Column.from_string(
            StringArray.from_strings_with_validity(values, valid)
        )
    # The distinct non-NULL values in order of first appearance.
    var distinct = List[String]()
    var code_of = List[Int](length=n, fill=0)
    for i in range(n):
        if not valid[i]:
            continue
        var at = -1
        for j in range(len(distinct)):
            if distinct[j] == values[i]:
                at = j
        if at < 0:
            at = len(distinct)
            distinct.append(values[i])
        code_of[i] = at
    var m = len(distinct)
    var entries = List[String]()
    var codes = PrimitiveArray[DType.int32].allocate_nullable(n)
    if form == FORM_DICT or m == 0:
        for j in range(m):
            entries.append(distinct[j])
        for i in range(n):
            codes.set(i, Int32(code_of[i]))
    else:
        var turn = rot % m
        for j in range(m):
            entries.append(distinct[(j + turn) % m])
        entries.append("unused entry one")
        entries.append("unused entry two")
        entries.append(distinct[0])  # code m + 2: a second copy of value 0
        for i in range(n):
            var c = (code_of[i] - turn + m) % m
            if code_of[i] == 0 and i % 2 == 0:
                c = m + 2
            codes.set(i, Int32(c))
    for i in range(n):
        if not valid[i]:
            codes.set(i, Int32(_FAR_CODE))
            codes._set_null(i)
    return Column.from_dictionary(
        StringDictionaryArray.from_parts(codes^, StringArray.from_strings(entries))
    )


def string_batch(start: Int, rows: Int, form: Int) raises -> RecordBatch:
    var s1 = List[String]()
    var s1_valid = List[Bool]()
    var s2 = List[String]()
    var s2_valid = List[Bool]()
    var v = ColumnBuilder[DType.int64].with_capacity(rows)
    var d = Decimal128Array.allocate_nullable(rows, 20, 2)
    for i in range(rows):
        var r = start + i
        s1.append(String("") if s1_null(r) else s1_value(r))
        s1_valid.append(not s1_null(r))
        s2.append(String("") if s2_null(r) else s2_value(r))
        s2_valid.append(not s2_null(r))
        if v_null(r):
            v.append_null()
        else:
            v.append(Int64(v_value(r)))
        if d_null(r):
            d.set_null(i)
        else:
            d.set_i128(i, I128(d_unscaled(r)))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    if form == FORM_FLAT:
        sb.add_field(Field("s1", ArrowType.STRING, True))
    else:
        sb.add_field(Field.dictionary("s1", ArrowType.INT32, True))
    rb.add_column(string_column(s1, s1_valid, form, start))
    if form == FORM_FLAT:
        sb.add_field(Field("s2", ArrowType.STRING, True))
    else:
        sb.add_field(Field.dictionary("s2", ArrowType.INT32, True))
    rb.add_column(string_column(s2, s2_valid, form, start + 1))
    sb.add_field(Field("v", ArrowType.INT64, True))
    rb.add_column(v^.materialize())
    sb.add_field(Field.decimal128("d", 20, 2, True))
    rb.add_column(Column.from_decimal128(d^))
    return rb.build(sb.build())


def key_batch(
    ref values: List[String], ref valid: List[Bool], form: Int, rot: Int = 0
) raises -> RecordBatch:
    """A batch of a key column `s1` over `values` and an INT64 column `v`
    holding the row number plus one."""
    var v = PrimitiveArray[DType.int64].allocate(len(values))
    for i in range(len(values)):
        v.set(i, Int64(i + 1))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    if form == FORM_FLAT:
        sb.add_field(Field("s1", ArrowType.STRING, True))
    else:
        sb.add_field(Field.dictionary("s1", ArrowType.INT32, True))
    rb.add_column(string_column(values, valid, form, rot))
    sb.add_field(Field("v", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](v^))
    return rb.build(sb.build())
