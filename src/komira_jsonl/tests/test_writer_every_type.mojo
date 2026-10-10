# =============================================================================
# Every Arrow type through every batch writer, with a null row between two
# valued rows.
# =============================================================================
#
# One 3-row batch holds a column of each type the writers support (INT8..64,
# UINT8..64, FLOAT32/64, BOOL, DATE32, STRING, LARGE_STRING, DICTIONARY,
# DECIMAL128, NULL); row 1 is null in every column. Each writer's whole
# output is compared with a hand-written expected text, so a writer arm
# that reads the wrong width, drops the null check or prints the wrong
# literal changes a byte the test names:
#
#   * test_legacy_writer_every_type -- `encode.write_batch_jsonl`
#     (`_format_column_cells_json`): DATE32 as day numbers, DECIMAL128 as
#     a float.
#   * test_direct_writer_every_type -- `write_batch_jsonl_direct`
#     (`_write_cell_pretty`): DATE32 as an ISO date string, DECIMAL128 as
#     an exact decimal string; a DICTIONARY column under a STRING field
#     (as a reader that types the field from the file may hand it over)
#     decodes through its dictionary, not as offsets.
#   * test_fused_writer_every_type -- `write_batch_jsonl_fused` and
#     `write_batch_jsonl_fused_range` over rows [1, 3): the range output is
#     the full output's last two lines (offset slices start at a null row).
#   * test_unsupported_type_refused -- a TIMESTAMP column is refused by the
#     three writers, naming the column index.
#   * test_direct_empty_batches -- no rows, or no columns, writes nothing.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer

from komira_jsonl.encode import write_batch_jsonl
from komira_jsonl.json_writer import (
    write_batch_json_pretty,
    write_batch_jsonl_direct,
    write_batch_jsonl_fused,
    write_batch_jsonl_fused_range,
)


def _text(buf: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(buf))


def _prim[
    dt: DType
](a: Scalar[dt], c: Scalar[dt], at: ArrowType) raises -> Column[HeapRegion]:
    """Rows: a, null, c."""
    var arr = PrimitiveArray[dt].allocate_nullable(3)
    arr.set(0, a)
    arr.set(1, Scalar[dt](0))
    arr.set(2, c)
    arr._set_null(1)
    return Column.from_primitive_with_arrow_type[dt](arr^, at)


def _null_column(n: Int) -> Column[HeapRegion]:
    return Column[HeapRegion](
        arrow_type=ArrowType.NULL,
        data=OwnedAlignedBuffer(0),
        offsets=Optional[OwnedAlignedBuffer](None),
        validity=Optional[Bitmap[HeapRegion]](None),
        length=n,
        null_count=n,
        offset=0,
    )


def _dict_column() raises -> Column[HeapRegion]:
    """Rows: "x", null, "y" through dictionary ["y", "x"]."""
    var idx = PrimitiveArray[DType.int32].allocate_nullable(3)
    idx.set(0, Int32(1))
    idx.set(1, Int32(0))
    idx.set(2, Int32(0))
    idx._set_null(1)
    var d = List[String]()
    d.append("y")
    d.append("x")
    return Column.from_dictionary(
        StringDictionaryArray.from_parts(idx^, StringArray.from_strings(d))
    )


def _valid_mask() -> List[Bool]:
    var v = List[Bool]()
    v.append(True)
    v.append(False)
    v.append(True)
    return v^


def _every_type_schema(dict_field: ArrowType) -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", ArrowType.INT64, True))
    sb.add_field(Field("i32", ArrowType.INT32, True))
    sb.add_field(Field("d", ArrowType.DATE32, True))
    sb.add_field(Field("i16", ArrowType.INT16, True))
    sb.add_field(Field("i8", ArrowType.INT8, True))
    sb.add_field(Field("u64", ArrowType.UINT64, True))
    sb.add_field(Field("u32", ArrowType.UINT32, True))
    sb.add_field(Field("u16", ArrowType.UINT16, True))
    sb.add_field(Field("u8", ArrowType.UINT8, True))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    sb.add_field(Field("f32", ArrowType.FLOAT32, True))
    sb.add_field(Field("b", ArrowType.BOOL, True))
    sb.add_field(Field("s", ArrowType.STRING, True))
    sb.add_field(Field("ls", ArrowType.LARGE_STRING, True))
    sb.add_field(Field("dict", dict_field, True))
    sb.add_field(Field("dec", ArrowType.DECIMAL128, True))
    sb.add_field(Field("n", ArrowType.NULL, True))
    return sb.build()


def _every_type_batch(dict_field: ArrowType) raises -> RecordBatch:
    var rbb = RecordBatchBuilder()
    rbb.add_column(_prim[DType.int64](-5, 9223372036854775807, ArrowType.INT64))
    rbb.add_column(_prim[DType.int32](-7, 2147483647, ArrowType.INT32))
    rbb.add_column(_prim[DType.int32](19000, -1, ArrowType.DATE32))
    rbb.add_column(_prim[DType.int16](-300, 32767, ArrowType.INT16))
    rbb.add_column(_prim[DType.int8](-8, 127, ArrowType.INT8))
    rbb.add_column(
        _prim[DType.uint64](18446744073709551615, 0, ArrowType.UINT64)
    )
    rbb.add_column(_prim[DType.uint32](4000000000, 1, ArrowType.UINT32))
    rbb.add_column(_prim[DType.uint16](65535, 2, ArrowType.UINT16))
    rbb.add_column(_prim[DType.uint8](255, 3, ArrowType.UINT8))
    rbb.add_column(_prim[DType.float64](1.5, -1.5, ArrowType.FLOAT64))
    rbb.add_column(_prim[DType.float32](0.25, 1.5, ArrowType.FLOAT32))
    var b = BooleanArray.allocate_nullable(3)
    b.set(0, True)
    b.set(2, False)
    b._set_null(1)
    rbb.add_column(Column.from_boolean(b^))
    var sv = List[String]()
    sv.append('a"b')
    sv.append("")
    sv.append("tab\there")
    rbb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(sv, _valid_mask()))
    )
    var lv = List[String]()
    lv.append("L")
    lv.append("")
    lv.append("cr\r")
    rbb.add_column(
        Column.from_large_string(
            LargeStringArray.from_strings_with_validity(lv, _valid_mask())
        )
    )
    rbb.add_column(_dict_column())
    var dec = Decimal128Array.allocate_nullable(3, 10, 2)
    dec.set_raw(0, Int64(250), Int64(0))
    dec.set_raw(2, Int64(-5), Int64(-1))
    dec.set_null(1)
    rbb.add_column(Column.from_decimal128(dec^))
    rbb.add_column(_null_column(3))
    # `build` sets a STRING field over a DICTIONARY column to DICTIONARY;
    # the schema is put back afterwards to hold the field the test asks for.
    var batch = rbb.build(_every_type_schema(ArrowType.DICTIONARY))
    batch.schema = _every_type_schema(dict_field)
    return batch^


comptime _NULL_ROW = (
    '{"i64":null,"i32":null,"d":null,"i16":null,"i8":null,"u64":null,'
    '"u32":null,"u16":null,"u8":null,"f64":null,"f32":null,"b":null,'
    '"s":null,"ls":null,"dict":null,"dec":null,"n":null}\n'
)


def test_legacy_writer_every_type() raises:
    var batch = _every_type_batch(ArrowType.DICTIONARY)
    var buf = List[UInt8]()
    write_batch_jsonl(buf, batch)
    var want = String(
        '{"i64":-5,"i32":-7,"d":19000,"i16":-300,"i8":-8,'
        '"u64":18446744073709551615,"u32":4000000000,"u16":65535,"u8":255,'
        '"f64":1.5,"f32":0.25,"b":true,"s":"a\\"b","ls":"L","dict":"x",'
        '"dec":2.5,"n":null}\n'
    )
    want += _NULL_ROW
    want += (
        '{"i64":9223372036854775807,"i32":2147483647,"d":-1,"i16":32767,'
        '"i8":127,"u64":0,"u32":1,"u16":2,"u8":3,"f64":-1.5,"f32":1.5,'
        '"b":false,"s":"tab\\there","ls":"cr\\r","dict":"y","dec":-0.05,'
        '"n":null}\n'
    )
    assert_equal(_text(buf), want)


def test_direct_writer_every_type() raises:
    var want = String(
        '{"i64":-5,"i32":-7,"d":"2022-01-08","i16":-300,"i8":-8,'
        '"u64":18446744073709551615,"u32":4000000000,"u16":65535,"u8":255,'
        '"f64":1.5,"f32":0.25,"b":true,"s":"a\\"b","ls":"L","dict":"x",'
        '"dec":"2.50","n":null}\n'
    )
    want += _NULL_ROW
    want += (
        '{"i64":9223372036854775807,"i32":2147483647,"d":"1969-12-31",'
        '"i16":32767,"i8":127,"u64":0,"u32":1,"u16":2,"u8":3,"f64":-1.5,'
        '"f32":1.5,"b":false,"s":"tab\\there","ls":"cr\\r","dict":"y",'
        '"dec":"-0.05","n":null}\n'
    )
    # The dictionary column under a DICTIONARY field, then under a STRING
    # field (the column's own tag picks the dictionary decode).
    var tags = List[ArrowType]()
    tags.append(ArrowType.DICTIONARY)
    tags.append(ArrowType.STRING)
    for t in range(len(tags)):
        var batch = _every_type_batch(tags[t])
        var buf = List[UInt8]()
        write_batch_jsonl_direct(buf, batch)
        assert_equal(_text(buf), want)


def test_pretty_writer_every_type_nulls() raises:
    """The pretty writer shares `_write_cell_pretty`: its null row prints
    `null` for every column."""
    var batch = _every_type_batch(ArrowType.DICTIONARY)
    var buf = List[UInt8]()
    write_batch_json_pretty(buf, batch, 1)
    var text = _text(buf)
    var want_null_record = String(
        ' {\n'
        '  "i64": null,\n  "i32": null,\n  "d": null,\n  "i16": null,\n'
        '  "i8": null,\n  "u64": null,\n  "u32": null,\n  "u16": null,\n'
        '  "u8": null,\n  "f64": null,\n  "f32": null,\n  "b": null,\n'
        '  "s": null,\n  "ls": null,\n  "dict": null,\n  "dec": null,\n'
        '  "n": null\n'
        ' },\n'
    )
    assert_true(want_null_record in text, text)
    assert_true(text.startswith('[\n {\n  "i64": -5,\n'), text)
    assert_true(text.endswith('  "n": null\n }\n]'), text)


def test_fused_writer_every_type() raises:
    var batch = _every_type_batch(ArrowType.DICTIONARY)
    var buf = List[UInt8]()
    write_batch_jsonl_fused(buf, batch)
    var row2 = String(
        '{"i64":9223372036854775807,"i32":2147483647,"d":-1,"i16":32767,'
        '"i8":127,"u64":0,"u32":1,"u16":2,"u8":3,"f64":-1.5,"f32":1.5,'
        '"b":false,"s":"tab\\there","ls":"cr\\r","dict":"y","dec":-0.05,'
        '"n":null}\n'
    )
    var want = String(
        '{"i64":-5,"i32":-7,"d":19000,"i16":-300,"i8":-8,'
        '"u64":18446744073709551615,"u32":4000000000,"u16":65535,"u8":255,'
        '"f64":1.5,"f32":0.25,"b":true,"s":"a\\"b","ls":"L","dict":"x",'
        '"dec":2.5,"n":null}\n'
    )
    want += _NULL_ROW
    want += row2
    assert_equal(_text(buf), want)
    # Rows [1, 3): every column encoder starts at a null row.
    var part = List[UInt8]()
    write_batch_jsonl_fused_range(part, batch, 1, 3)
    assert_equal(_text(part), String(_NULL_ROW) + row2)
    # Rows [2, 3): one valued row.
    var last = List[UInt8]()
    write_batch_jsonl_fused_range(last, batch, 2, 3)
    assert_equal(_text(last), row2)


def _timestamp_batch() raises -> RecordBatch:
    var arr = PrimitiveArray[DType.int64].allocate(1)
    arr.set(0, Int64(1))
    var rbb = RecordBatchBuilder()
    rbb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](arr^, ArrowType.TIMESTAMP)
    )
    var sb = SchemaBuilder()
    sb.add_field(Field("ts", ArrowType.TIMESTAMP, True))
    return rbb.build(sb.build())


def _refusal(which: Int) raises -> String:
    var batch = _timestamp_batch()
    var buf = List[UInt8]()
    try:
        if which == 0:
            write_batch_jsonl(buf, batch)
        elif which == 1:
            write_batch_jsonl_direct(buf, batch)
        else:
            write_batch_jsonl_fused(buf, batch)
    except e:
        return String(e)
    raise Error("writer " + String(which) + " wrote a TIMESTAMP column")


def test_unsupported_type_refused() raises:
    var ts = String(ArrowType.TIMESTAMP)
    var m0 = _refusal(0)
    assert_true(
        m0.startswith(
            "JSON: unsupported ArrowType '" + ts + "' at column index 0."
        ),
        m0,
    )
    var m1 = _refusal(1)
    assert_equal(
        m1, "json_writer: unsupported ArrowType '" + ts + "' at column index 0"
    )
    var m2 = _refusal(2)
    assert_true(
        m2.startswith(
            "json_writer (fused): unsupported ArrowType '" + ts
            + "' at column index 0."
        ),
        m2,
    )


def test_direct_empty_batches() raises:
    # No rows: nothing is written (not even a newline).
    var arr = PrimitiveArray[DType.int64].allocate(0)
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    var sb = SchemaBuilder()
    sb.add_field(Field("a", ArrowType.INT64, True))
    var batch = rbb.build(sb.build())
    var buf = List[UInt8]()
    buf.append(UInt8(0x41))
    write_batch_jsonl_direct(buf, batch)
    assert_equal(len(buf), 1)
    # No columns: nothing is written.
    var empty = RecordBatch()
    write_batch_jsonl_direct(buf, empty)
    assert_equal(len(buf), 1)


def main() raises:
    test_legacy_writer_every_type()
    test_direct_writer_every_type()
    test_pretty_writer_every_type_nulls()
    test_fused_writer_every_type()
    test_unsupported_type_refused()
    test_direct_empty_batches()
    print("test_writer_every_type: all passed")
