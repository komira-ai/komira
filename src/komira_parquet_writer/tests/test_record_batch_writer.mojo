# RecordBatches to Parquet bytes, decoded by komira_parquet's reader.
#
# The reader shares no code with the writer. Each test builds Arrow batches,
# writes them with `write_record_batch(es)_to_parquet_bytes`, parses the footer
# with `parse_full_metadata` and decodes every row group with
# `decode_row_group_from_bytes`, then compares every value and null with the
# rows the batch was built from.
#
#   * test_one_batch_roundtrips_every_type: INT32, INT64, FLOAT32, FLOAT64
#     (with NaN), STRING (plain and dictionary-eligible), LARGE_STRING, BOOL,
#     DATE32, a timestamp, DECIMAL128 and a DICTIONARY column, with nulls, under
#     three codecs. Catches a physical type that disagrees with the pages
#     (the schema claims INT64, the pages carry INT32), definition levels
#     missing for an OPTIONAL column, and a dictionary column's null row
#     taking its stale ordinal's string.
#   * test_date_and_decimal_keep_their_types: DATE32 reads back as DATE32 and a
#     decimal with its precision and scale (the footer annotations).
#   * test_a_large_batch_is_cut_into_row_groups: 1000 rows at 300 per row group
#     are four row groups of 300, 300, 300 and 100, every row where it
#     belongs, an OffsetIndex per chunk.
#   * test_several_batches_without_a_concat: three batches of eligible columns
#     are one row group written PLAIN (the footer lists no dictionary or delta
#     encoding), with the values of every batch in order and, per column, the
#     statistics of the whole.
#   * test_several_batches_with_an_ineligible_column_are_concatenated: a BOOL
#     column forces the concat path; values across the batch boundaries.
#   * test_nullability_is_the_field_for_one_batch_and_the_data_for_several:
#     footer repetition types.
#   * test_refusals: no batch, no column, a batch with another column count, a
#     non-positive row group size, an unsigned column, a REQUIRED field that
#     holds a null.
from std.math import nan
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.byte_view import ByteView
from komira_collections.slab import Slab
from komira_parquet.bytes_decode import (
    decode_row_group_from_bytes,
    row_group_byte_range,
)
from komira_parquet.metadata_parser import parse_full_metadata
from komira_parquet.morsel_reader import ColumnProjection
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_api.types import CompressionCodec, Encoding, FieldRepetitionType
from komira_parquet_writer import (
    write_record_batch_to_parquet_bytes,
    write_record_batches_to_parquet_bytes,
)


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _footer(file: List[UInt8]) raises -> FileMetaData:
    var n = len(file)
    var flen = 0
    for k in range(4):
        flen |= Int(file[n - 8 + k]) << (8 * k)
    return parse_full_metadata(_view(Span(file)[n - 8 - flen : n - 8]))


def _read_rg(file: List[UInt8], md: FileMetaData, g: Int) raises -> RecordBatch:
    ref rg = md.row_groups[g]
    var br = row_group_byte_range(rg)
    return decode_row_group_from_bytes(
        _view(Span(file)[br.start : br.end]),
        br,
        rg,
        md.schema,
        ColumnProjection.all(),
    )


# --- the rows ---------------------------------------------------------------
# Column            type             null when
#  0 i32            INT32            never
#  1 i64            INT64            r % 7 == 2
#  2 f32            FLOAT32          never            -r / 4
#  3 f64            FLOAT64          r % 11 == 5      NaN at r % 17 == 3
#  4 s_plain        STRING           r % 13 == 3      "row-r" (unique)
#  5 s_dict         STRING           never            "k" + r % 5
#  6 large          LARGE_STRING     r % 19 == 6      "L" + r % 4
#  7 flag           BOOL             r % 5 == 4       r % 3 == 0
#  8 day            DATE32           never            r * 2
#  9 ts             TIMESTAMP_US     r % 23 == 9      r * 1000
# 10 dec            DECIMAL128(20,2) r % 29 == 4      r * 100 + 7
# 11 dsn            DICTIONARY       r % 31 == 7      "d" + r % 3


def _i64_null(r: Int) -> Bool:
    return r % 7 == 2


def _f64_null(r: Int) -> Bool:
    return r % 11 == 5


def _s_null(r: Int) -> Bool:
    return r % 13 == 3


def _large_null(r: Int) -> Bool:
    return r % 19 == 6


def _flag_null(r: Int) -> Bool:
    return r % 5 == 4


def _ts_null(r: Int) -> Bool:
    return r % 23 == 9


def _dec_null(r: Int) -> Bool:
    return r % 29 == 4


def _dsn_null(r: Int) -> Bool:
    return r % 31 == 7


def _f64(r: Int) -> Float64:
    if r % 17 == 3:
        return nan[DType.float64]()
    return Float64(r) / 8.0


def _batch(start: Int, n: Int, general: Bool) raises -> RecordBatch:
    """Rows start..start+n-1. `general` False builds only the columns the
    multi-batch fast path can take (0-6)."""
    var sb = SchemaBuilder()
    var b = RecordBatchBuilder()
    var a0 = PrimitiveArray[DType.int32].allocate(n)
    var a1 = PrimitiveArray[DType.int64].allocate_nullable(n)
    var a2 = PrimitiveArray[DType.float32].allocate(n)
    var a3 = PrimitiveArray[DType.float64].allocate_nullable(n)
    var s4 = List[String]()
    var v4 = List[Bool]()
    var s5 = List[String]()
    var s6 = List[String]()
    var v6 = List[Bool]()
    var flag = BooleanArray.allocate_nullable(n)
    var day = PrimitiveArray[DType.int32].allocate(n)
    var ts = PrimitiveArray[DType.int64].allocate_nullable(n)
    var dec = Decimal128Array.allocate_nullable(n, 20, 2)
    var codes = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        var r = start + i
        a0.set(i, Int32(r * 3 - 700))
        a1.set(i, Int64(-5) if _i64_null(r) else Int64(r * 1000003))
        if _i64_null(r):
            a1._set_null(i)
        a2.set(i, Float32(-r) / 4.0)
        a3.set(i, _f64(r))
        if _f64_null(r):
            a3._set_null(i)
        s4.append(String("row-") + String(r))
        v4.append(not _s_null(r))
        s5.append(String("k") + String(r % 5))
        s6.append(String("L") + String(r % 4))
        v6.append(not _large_null(r))
        flag.set(i, r % 3 == 0)
        if _flag_null(r):
            flag._set_null(i)
        day.set(i, Int32(r * 2))
        ts.set(i, Int64(r * 1000))
        if _ts_null(r):
            ts._set_null(i)
        dec.set_i128(i, SIMD[DType.int128, 1](r * 100 + 7))
        if _dec_null(r):
            dec.set_null(i)
        codes.set(i, Int32(r % 3))
        if _dsn_null(r):
            codes._set_null(i)
    sb.add_field(Field("i32", ArrowType.INT32, False))
    b.add_column(Column.from_primitive[DType.int32](a0))
    sb.add_field(Field("i64", ArrowType.INT64, True))
    b.add_column(Column.from_primitive[DType.int64](a1))
    sb.add_field(Field("f32", ArrowType.FLOAT32, False))
    b.add_column(Column.from_primitive[DType.float32](a2))
    sb.add_field(Field("f64", ArrowType.FLOAT64, True))
    b.add_column(Column.from_primitive[DType.float64](a3))
    sb.add_field(Field("s_plain", ArrowType.STRING, True))
    b.add_column(Column.from_string(StringArray.from_strings_with_validity(s4, v4)))
    sb.add_field(Field("s_dict", ArrowType.STRING, False))
    b.add_column(Column.from_string(StringArray.from_strings(s5)))
    sb.add_field(Field("large", ArrowType.LARGE_STRING, True))
    b.add_column(Column.from_large_string(LargeStringArray.from_strings_with_validity(s6, v6)))
    if general:
        sb.add_field(Field("flag", ArrowType.BOOL, True))
        b.add_column(Column.from_boolean(flag))
        sb.add_field(Field("day", ArrowType.DATE32, False))
        b.add_column(
            Column.from_primitive_with_arrow_type[DType.int32](day, ArrowType.DATE32)
        )
        sb.add_field(Field("ts", ArrowType.TIMESTAMP_US, True))
        b.add_column(
            Column.from_primitive_with_arrow_type[DType.int64](ts, ArrowType.TIMESTAMP_US)
        )
        sb.add_field(Field.decimal128("dec", 20, 2, True))
        b.add_column(Column.from_decimal128(dec))
        sb.add_field(Field("dsn", ArrowType.DICTIONARY, True))
        var dict_vals: List[String] = ["d0", "d1", "d2"]
        b.add_column(
            Column.from_dictionary(
                StringDictionaryArray.from_parts(codes^, StringArray.from_strings(dict_vals))
            )
        )
    return b.build(sb.build())


def _check(b: RecordBatch, start: Int, n: Int, general: Bool) raises:
    assert_equal(b.num_rows(), n)
    assert_equal(b.num_columns(), 12 if general else 7)
    for i in range(n):
        var r = start + i
        var w = "row " + String(r)
        assert_equal(Int(b.column_at(0).as_primitive[DType.int32]().get(i)), r * 3 - 700, w)
        assert_equal(b.column_at(1).is_null_at(i), _i64_null(r), w)
        if not _i64_null(r):
            assert_equal(Int(b.column_at(1).as_primitive[DType.int64]().get(i)), r * 1000003, w)
        assert_equal(b.column_at(2).as_primitive[DType.float32]().get(i), Float32(-r) / 4.0, w)
        assert_equal(b.column_at(3).is_null_at(i), _f64_null(r), w)
        if not _f64_null(r):
            var got = b.column_at(3).as_primitive[DType.float64]().get(i)
            if r % 17 == 3:
                assert_true(got != got, w + ": NaN")
            else:
                assert_equal(got, Float64(r) / 8.0, w)
        assert_equal(b.column_at(4).is_null_at(i), _s_null(r), w)
        if not _s_null(r):
            assert_equal(b.column_at(4).as_string().get(i), String("row-") + String(r), w)
        assert_equal(b.column_at(5).as_string().get(i), String("k") + String(r % 5), w)
        assert_equal(b.column_at(6).is_null_at(i), _large_null(r), w)
        if not _large_null(r):
            ref c6 = b.column_at(6)
            var text = c6.as_large_string().get(i) if c6.arrow_type == ArrowType.LARGE_STRING else c6.as_string().get(i)
            assert_equal(text, String("L") + String(r % 4), w)
        if not general:
            continue
        assert_equal(b.column_at(7).is_null_at(i), _flag_null(r), w)
        if not _flag_null(r):
            assert_equal(b.column_at(7).as_boolean().get(i), r % 3 == 0, w)
        assert_equal(Int(b.column_at(8).as_primitive[DType.int32]().get(i)), r * 2, w)
        assert_equal(b.column_at(9).is_null_at(i), _ts_null(r), w)
        if not _ts_null(r):
            assert_equal(Int(b.column_at(9).as_primitive[DType.int64]().get(i)), r * 1000, w)
        assert_equal(b.column_at(10).is_null_at(i), _dec_null(r), w)
        if not _dec_null(r):
            assert_equal(Int(b.column_at(10).as_decimal128().get_i128(i)), r * 100 + 7, w)
        assert_equal(b.column_at(11).is_null_at(i), _dsn_null(r), w)
        if not _dsn_null(r):
            assert_equal(b.column_at(11).as_string().get(i), String("d") + String(r % 3), w)


def _check_file(file: List[UInt8], n: Int, general: Bool, rg_rows: Int) raises:
    var md = _footer(file)
    assert_equal(md.num_rows, n)
    var groups = (n + rg_rows - 1) // rg_rows
    assert_equal(len(md.row_groups), groups)
    for g in range(groups):
        var first = g * rg_rows
        var count = min(rg_rows, n - first)
        assert_equal(md.row_groups[g].num_rows, count)
        _check(_read_rg(file, md, g), first, count, general)


def test_one_batch_roundtrips_every_type() raises:
    for codec in [CompressionCodec.UNCOMPRESSED, CompressionCodec.SNAPPY, CompressionCodec.ZSTD]:
        var file = write_record_batch_to_parquet_bytes(_batch(0, 1000, True), codec)
        _check_file(file, 1000, True, 1000)


def test_date_and_decimal_keep_their_types() raises:
    var file = write_record_batch_to_parquet_bytes(_batch(0, 50, True))
    var b = _read_rg(file, _footer(file), 0)
    assert_true(b.column_at(8).arrow_type == ArrowType.DATE32)
    assert_true(b.column_at(10).arrow_type == ArrowType.DECIMAL128)
    assert_equal(b.schema.field_decimal_precision(10), 20)
    assert_equal(b.schema.field_decimal_scale(10), 2)


def test_a_large_batch_is_cut_into_row_groups() raises:
    var file = write_record_batch_to_parquet_bytes(
        _batch(0, 1000, True), CompressionCodec.SNAPPY, max_rows_per_rg=300
    )
    _check_file(file, 1000, True, 300)
    var md = _footer(file)
    for g in range(4):
        for c in range(12):
            assert_true(Bool(md.row_groups[g].columns[c].offset_index_offset))


def _three_batches(general: Bool) raises -> Slab[RecordBatch]:
    var batches = Slab[RecordBatch]()
    batches.append(_batch(0, 400, general))
    batches.append(_batch(400, 350, general))
    batches.append(_batch(750, 250, general))
    return batches^


def test_several_batches_without_a_concat() raises:
    var file = write_record_batches_to_parquet_bytes(_three_batches(False), CompressionCodec.SNAPPY)
    _check_file(file, 1000, False, 1000)
    var md = _footer(file)
    assert_equal(len(md.row_groups), 1)
    for c in range(7):
        for e in md.row_groups[0].columns[c].meta_data.encodings:
            assert_true(
                e == Encoding.PLAIN or e == Encoding.RLE,
                "column " + String(c) + " is PLAIN on the multi-batch path",
            )
    # The whole column's statistics, not the last batch's: row 0 holds the
    # minimum and row 999 the maximum of i32.
    ref s = md.row_groups[0].columns[0].meta_data.statistics.value()
    var lo = 0
    var hi = 0
    for k in range(4):
        lo |= Int(s.min_value.value()[k]) << (8 * k)
        hi |= Int(s.max_value.value()[k]) << (8 * k)
    assert_equal(lo - (1 << 32) if lo >= (1 << 31) else lo, -700)
    assert_equal(hi, 999 * 3 - 700)
    ref s1 = md.row_groups[0].columns[1].meta_data.statistics.value()
    var nulls = 0
    for r in range(1000):
        if _i64_null(r):
            nulls += 1
    assert_equal(s1.null_count.value(), nulls)


def test_several_batches_with_an_ineligible_column_are_concatenated() raises:
    var file = write_record_batches_to_parquet_bytes(_three_batches(True), CompressionCodec.ZSTD)
    _check_file(file, 1000, True, 1000)
    # Concatenated, the single-batch path picks its own encodings: the
    # low-cardinality string column is a dictionary chunk.
    assert_true(Bool(_footer(file).row_groups[0].columns[5].meta_data.dictionary_page_offset))


def test_several_batches_cut_into_row_groups() raises:
    var file = write_record_batches_to_parquet_bytes(
        _three_batches(True), CompressionCodec.SNAPPY, max_rows_per_rg=400
    )
    _check_file(file, 1000, True, 400)


def _repetition(md: FileMetaData, leaf: Int) -> FieldRepetitionType:
    return md.schema[leaf + 1].repetition_type.value()


def test_nullability_is_the_field_for_one_batch_and_the_data_for_several() raises:
    # One batch: the Arrow field says OPTIONAL (i64, f64, ...) or REQUIRED
    # (i32), whether or not the data holds a null.
    var one = _footer(write_record_batch_to_parquet_bytes(_batch(0, 20, False)))
    assert_true(_repetition(one, 0) == FieldRepetitionType.REQUIRED)
    assert_true(_repetition(one, 1) == FieldRepetitionType.OPTIONAL)
    # Several batches: OPTIONAL iff a batch has a validity buffer or a null.
    # Rows 0..19 of i64 hold a null (r % 7 == 2), so it is OPTIONAL; the
    # unmasked columns stay REQUIRED.
    var many = _footer(write_record_batches_to_parquet_bytes(_three_batches(False)))
    assert_true(_repetition(many, 0) == FieldRepetitionType.REQUIRED)
    assert_true(_repetition(many, 1) == FieldRepetitionType.OPTIONAL)
    assert_true(_repetition(many, 5) == FieldRepetitionType.REQUIRED)


def test_refusals() raises:
    with assert_raises(contains="no batches"):
        _ = write_record_batches_to_parquet_bytes(Slab[RecordBatch]())
    var empty_schema = SchemaBuilder()
    var no_cols_builder = RecordBatchBuilder()
    var no_cols = no_cols_builder.build(empty_schema.build())
    with assert_raises(contains="batch has no columns"):
        _ = write_record_batch_to_parquet_bytes(no_cols)
    with assert_raises(contains="max_rows_per_rg must be positive"):
        _ = write_record_batch_to_parquet_bytes(_batch(0, 10, False), max_rows_per_rg=0)
    var mismatch = Slab[RecordBatch]()
    mismatch.append(_batch(0, 10, False))
    mismatch.append(_batch(10, 10, True))
    with assert_raises(contains="schema mismatch at batch 1"):
        _ = write_record_batches_to_parquet_bytes(mismatch^)
    # An unsigned column has no writer: refused up front, not written as a
    # signed one.
    var usb = SchemaBuilder()
    usb.add_field(Field("u", ArrowType.UINT32, False))
    var ub = RecordBatchBuilder()
    ub.add_column(Column.from_primitive[DType.uint32](PrimitiveArray[DType.uint32].from_list([UInt32(1), UInt32(2)])))
    with assert_raises(contains="no encoding for Arrow type"):
        _ = write_record_batch_to_parquet_bytes(ub.build(usb.build()))
    # A REQUIRED field whose column holds a null.
    var rsb = SchemaBuilder()
    rsb.add_field(Field("r", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    var holes = PrimitiveArray[DType.int64].allocate_nullable(3)
    holes._set_null(1)
    rb.add_column(Column.from_primitive[DType.int64](holes))
    with assert_raises(contains="is REQUIRED but holds"):
        _ = write_record_batch_to_parquet_bytes(rb.build(rsb.build()))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
