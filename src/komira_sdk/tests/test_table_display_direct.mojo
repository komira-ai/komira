# =============================================================================
# table_display, branch by branch: every type label, the alignment rule, the
# row limit, the empty batch and every cell reader.
# =============================================================================
#
# `test_display_stats` and `test_display_width_non_ascii` check that a table
# contains its values and stays square. This file pins the exact text: the
# label of every ArrowType arm, which columns are right-aligned, the footer
# for each row-limit case, and the cell reader for each storage shape
# (string, dictionary-encoded string, large string, int32, int64, float64,
# float32, and the int64 fallback). The FLOAT32 arm's return line is
# unreachable; the last test pins the route that would reach it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
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

from komira_sdk.table_display import (
    format_table,
    _type_short_name,
    _is_numeric_type,
    _pad_left,
    _pad_right,
    _separator_line,
)


def _i64(vals: List[Int]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate(len(vals))
    var ptr = arr._typed_ptr_mut()
    for i in range(len(vals)):
        ptr.store[width=1](i, Scalar[DType.int64](vals[i]))
    return Column.from_primitive[DType.int64](arr)


def _i32(vals: List[Int]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int32].allocate(len(vals))
    var ptr = arr._typed_ptr_mut()
    for i in range(len(vals)):
        ptr.store[width=1](i, Scalar[DType.int32](vals[i]))
    return Column.from_primitive[DType.int32](arr)


def _f64(vals: List[Float64]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.float64].allocate(len(vals))
    var ptr = arr._typed_ptr_mut()
    for i in range(len(vals)):
        ptr.store[width=1](i, vals[i])
    return Column.from_primitive[DType.float64](arr)


def _f32(vals: List[Float64]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.float32].allocate(len(vals))
    var ptr = arr._typed_ptr_mut()
    for i in range(len(vals)):
        ptr.store[width=1](i, Scalar[DType.float32](vals[i]))
    return Column.from_primitive[DType.float32](arr)


def _date64(vals: List[Int]) -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate(len(vals))
    var ptr = arr._typed_ptr_mut()
    for i in range(len(vals)):
        ptr.store[width=1](i, Scalar[DType.int64](vals[i]))
    return Column.from_primitive_with_arrow_type[DType.int64](
        arr, ArrowType.DATE64
    )


def _one_column(
    name: String, at: ArrowType, var col: Column[HeapRegion]
) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, at, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(col^)
    return builder.build(schema^)


def _line(table: String, i: Int) raises -> String:
    return String(table.split(String("\n"))[i])


# -----------------------------------------------------------------------------
# The type labels: one assertion per arm, so swapping any two arms, or dropping
# one to the `?` fallback, fails here.
# -----------------------------------------------------------------------------


def test_type_short_name_every_arm() raises:
    assert_equal(_type_short_name(ArrowType.BOOL), "bool")
    assert_equal(_type_short_name(ArrowType.INT8), "i8")
    assert_equal(_type_short_name(ArrowType.INT16), "i16")
    assert_equal(_type_short_name(ArrowType.INT32), "i32")
    assert_equal(_type_short_name(ArrowType.INT64), "i64")
    assert_equal(_type_short_name(ArrowType.UINT8), "u8")
    assert_equal(_type_short_name(ArrowType.UINT16), "u16")
    assert_equal(_type_short_name(ArrowType.UINT32), "u32")
    assert_equal(_type_short_name(ArrowType.UINT64), "u64")
    assert_equal(_type_short_name(ArrowType.FLOAT16), "f16")
    assert_equal(_type_short_name(ArrowType.FLOAT32), "f32")
    assert_equal(_type_short_name(ArrowType.FLOAT64), "f64")
    assert_equal(_type_short_name(ArrowType.STRING), "str")
    assert_equal(_type_short_name(ArrowType.LARGE_STRING), "str")
    assert_equal(_type_short_name(ArrowType.BINARY), "bin")
    assert_equal(_type_short_name(ArrowType.LARGE_BINARY), "bin")
    assert_equal(_type_short_name(ArrowType.DATE32), "date")
    assert_equal(_type_short_name(ArrowType.DATE64), "date")
    assert_equal(_type_short_name(ArrowType.DICTIONARY), "dict")
    assert_equal(_type_short_name(ArrowType.DECIMAL128), "dec128")
    # Any type with no arm is `?`.
    assert_equal(_type_short_name(ArrowType.TIMESTAMP), "?")


def test_is_numeric_type() raises:
    """The right-alignment set: the integers, the floats and DECIMAL128."""
    var numeric: List[ArrowType] = [
        ArrowType.INT8, ArrowType.INT16, ArrowType.INT32, ArrowType.INT64,
        ArrowType.UINT8, ArrowType.UINT16, ArrowType.UINT32, ArrowType.UINT64,
        ArrowType.FLOAT16, ArrowType.FLOAT32, ArrowType.FLOAT64,
        ArrowType.DECIMAL128,
    ]
    for i in range(len(numeric)):
        assert_true(_is_numeric_type(numeric[i]), String(numeric[i]))
    assert_false(_is_numeric_type(ArrowType.STRING))
    assert_false(_is_numeric_type(ArrowType.BOOL))
    assert_false(_is_numeric_type(ArrowType.DATE32))


def test_padding_counts_characters() raises:
    """Both pads count codepoints, and a string wider than the width is
    returned unpadded."""
    assert_equal(_pad_right("ab", 4), "ab  ")
    assert_equal(_pad_left("ab", 4), "  ab")
    assert_equal(_pad_right("café", 5), "café ")
    assert_equal(_pad_left("café", 5), " café")
    assert_equal(_pad_right("abcdef", 3), "abcdef")
    assert_equal(_pad_left("abcdef", 3), "abcdef")


def test_separator_line() raises:
    """Each column is its width plus two padding dashes, between `+`s."""
    var widths: List[Int] = [1, 3]
    assert_equal(_separator_line(widths), "+---+-----+")
    assert_equal(_separator_line(List[Int]()), "+")


# -----------------------------------------------------------------------------
# format_table, whole outputs.
# -----------------------------------------------------------------------------


def test_zero_column_batch() raises:
    """A batch with no columns renders as one line naming its row count."""
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    var batch = builder.build(sb.build())
    assert_equal(format_table(batch), "(empty: 0 columns, 0 rows)")


def test_exact_table_alignment() raises:
    """The whole text of a two-column table: the string column is left-
    aligned, the int64 column right-aligned, and each width is the widest of
    the name, the type label and the cells (`id`'s width is its label `i64`)."""
    var sb = SchemaBuilder()
    sb.add_field(Field("name", ArrowType.STRING, False))
    sb.add_field(Field("id", ArrowType.INT64, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    var names: List[String] = ["alice", "bo"]
    builder.add_column(Column.from_string(StringArray.from_strings(names)))
    var ids: List[Int] = [7, 42]
    builder.add_column(_i64(ids))
    var batch = builder.build(schema^)
    var want = String(
        "+-------+-----+\n"
        "| name  | id  |\n"
        "| str   | i64 |\n"
        "+-------+-----+\n"
        "| alice |   7 |\n"
        "| bo    |  42 |\n"
        "+-------+-----+\n"
        "2 rows"
    )
    assert_equal(format_table(batch), want)


def test_row_limit_footer() raises:
    """Over the limit: the first `max_rows` rows and a footer naming the rest.
    At the limit, and with a negative limit, every row shows and the footer
    has no `showing` clause."""
    var vals: List[Int] = [1, 2, 3]
    var batch = _one_column("x", ArrowType.INT64, _i64(vals))
    var cut = format_table(batch, max_rows=1)
    assert_true(
        cut.endswith("3 rows (showing 1, ... 2 more rows)"), cut
    )
    # One data line: header, type, two rules, one row, the bottom rule.
    assert_equal(_line(cut, 4), "|   1 |")
    assert_equal(_line(cut, 5), "+-----+")
    var at_limit = format_table(batch, max_rows=3)
    assert_true(at_limit.endswith("+-----+\n3 rows"), at_limit)
    var unlimited = format_table(batch, max_rows=-1)
    assert_equal(unlimited, at_limit)
    var zero = format_table(batch, max_rows=0)
    assert_true(zero.endswith("3 rows (showing 0, ... 3 more rows)"), zero)


# -----------------------------------------------------------------------------
# The cell readers.
# -----------------------------------------------------------------------------


def test_cell_int32_and_float64() raises:
    var i32s: List[Int] = [-5, 123]
    var t32 = format_table(_one_column("n", ArrowType.INT32, _i32(i32s)))
    assert_equal(_line(t32, 4), "|  -5 |")
    assert_equal(_line(t32, 5), "| 123 |")
    var f64s: List[Float64] = [1.5, -0.25]
    var tf = format_table(_one_column("f", ArrowType.FLOAT64, _f64(f64s)))
    assert_equal(_line(tf, 4), "|   1.5 |")
    assert_equal(_line(tf, 5), "| -0.25 |")


def _dict_batch() raises -> RecordBatch:
    var dict_vals: List[String] = ["red", "green"]
    var idx = PrimitiveArray[DType.int32].allocate(3)
    var p = idx._typed_ptr_mut()
    p.store[width=1](0, Int32(1))
    p.store[width=1](1, Int32(0))
    p.store[width=1](2, Int32(1))
    var arr = StringDictionaryArray(
        idx^, StringArray.from_strings(dict_vals), 3
    )
    return _one_column("c", ArrowType.STRING, Column.from_dictionary(arr))


def test_cell_dictionary_under_a_string_field() raises:
    """A STRING field over a dictionary-encoded column decodes each code.
    `RecordBatchBuilder.build` re-types such a field DICTIONARY, so the test
    sets the field back to STRING, the shape this arm reads."""
    var batch = _dict_batch()
    assert_true(
        batch.schema.field_arrow_type(0) == ArrowType.DICTIONARY,
        "build re-types the field",
    )
    batch.schema._arrow_types[0] = ArrowType.STRING.type_id
    var t = format_table(batch)
    assert_equal(_line(t, 4), "| green |")
    assert_equal(_line(t, 5), "| red   |")
    assert_equal(_line(t, 6), "| green |")


def test_cell_dictionary_field_reaches_the_fallback() raises:
    """A DICTIONARY field has no reader of its own: the int64 fallback
    refuses its int32 codes, so format_table raises. This pins what the
    moved code does."""
    var batch = _dict_batch()
    var raised = False
    try:
        _ = format_table(batch)
    except e:
        raised = True
        assert_true(String(e).find("mismatch") != -1, String(e))
    assert_true(raised, "a DICTIONARY field is not rendered")


def test_cell_large_string() raises:
    """A LARGE_STRING column (int64 offsets) reads through the same call."""
    var vals: List[String] = ["x", "yz"]
    var col = Column.from_strings_promoting(vals, offset_promote_at=1)
    assert_true(col.arrow_type == ArrowType.LARGE_STRING, "promoted")
    var t = format_table(_one_column("s", ArrowType.LARGE_STRING, col^))
    assert_equal(_line(t, 2), "| str |")
    assert_equal(_line(t, 4), "| x   |")
    assert_equal(_line(t, 5), "| yz  |")


def test_cell_fallback_reads_int64_storage() raises:
    """A type with no reader of its own (DATE64) reads as its int64 storage."""
    var vals: List[Int] = [86400000]
    var t = format_table(_one_column("d", ArrowType.DATE64, _date64(vals)))
    assert_equal(_line(t, 2), "| date     |")
    assert_equal(_line(t, 4), "| 86400000 |")


def test_cell_float32_arm_reads_float64() raises:
    """The FLOAT32 arm reads the column as float64, which a float32 column
    refuses: format_table raises on a float32 column. This pins what the
    moved code does; a fix reads it as float32 and changes this test."""
    var vals: List[Float64] = [2.5]
    var batch = _one_column("g", ArrowType.FLOAT32, _f32(vals))
    var raised = False
    try:
        _ = format_table(batch)
    except e:
        raised = True
        assert_true(String(e).find("mismatch") != -1, String(e))
    assert_true(raised, "a float32 cell read as float64 raises")


def test_cell_float32_field_over_float64_storage_is_refused() raises:
    """The FLOAT32 arm's return line cannot run, and this pins the last way
    in. Its float64 read needs a column tagged FLOAT64 under a FLOAT32
    field. The test above covers a float32 column, which fails the tag
    check. Re-typing the field over float64 storage, as the dictionary test
    does, is refused by RecordBatch's layout guard (4-byte against 8-byte
    values) before the cell is read. The tag repair rewrites any other
    column tag to FLOAT32, which also fails the float64 read."""
    var vals: List[Float64] = [2.5, -1.25]
    var batch = _one_column("g", ArrowType.FLOAT64, _f64(vals))
    batch.schema._arrow_types[0] = ArrowType.FLOAT32.type_id
    assert_true(
        batch.schema.field_arrow_type(0) == ArrowType.FLOAT32, "re-typed"
    )
    var raised = False
    try:
        _ = format_table(batch)
    except e:
        raised = True
        assert_true(String(e).find("LAYOUT CONFLICT") != -1, String(e))
    assert_true(raised, "float64 storage under a FLOAT32 field is refused")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
