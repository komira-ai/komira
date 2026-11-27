# =============================================================================
# The CSV and JSON bytes a COPY writes are DuckDB's bytes
# =============================================================================
#
# Covers: The CSV and JSON encoders on batches of every type they write give
# DuckDB's bytes: each type and NULL, doubles across fixed and exponent
# notation, NaN and the infinities, FLOATs, dates before year 1 (BC dates) and
# after 9999, timestamps of each unit (fractions, BC, extremes, `infinity`,
# `+00`), exact decimals, quoting and escaping; gzip and zstd decompress to
# their input; the writable types.
#
# `engine_write_text` called directly on record batches built here. Every
# expected text below is what the pinned DuckDB's COPY writes for the same
# value (the module header lists the rules); DuckDB reading back the files
# run_sql writes is `test_copy_readback_duckdb`.
#
# What each test proves:
#   * test_every_type_as_csv / test_every_type_as_ndjson: a batch of every
#     type the writer takes (BIGINT, INTEGER, SMALLINT, TINYINT, the four
#     unsigned widths at their maximum, DOUBLE, FLOAT, BOOLEAN, VARCHAR,
#     LARGE VARCHAR, a dictionary under a STRING field and under a
#     DICTIONARY field, DECIMAL, DATE and the NULL type), with a NULL row, is
#     the exact file: header, cells, separators, `\n` after every line.
#     Catches a NULL written as `NULL` (CSV) or a key left out (JSON), a
#     dictionary written as its codes, a date written as its day count, a
#     decimal rounded or quoted, and a type read at the wrong width.
#   * test_doubles_as_duckdb_renders_them: twenty-two values from 5e-324 to
#     1e300, both signs, zero, -0.0, NaN and the infinities, in CSV and JSON
#     text, and FLOATs with their own shortest digits in CSV and widened in
#     JSON. Catches each switch between fixed and exponent notation off by
#     one place, a `+` or a padded exponent in JSON, a missing `.0`, and NaN
#     or an infinity spelled otherwise than DuckDB does.
#   * test_dates_as_duckdb_renders_them: the epoch and the day before it,
#     year 1, the day before it (1 BC), years past 9999 and BC dates.
#   * test_timestamps_as_duckdb_renders_them: a column of each timestamp
#     type (the legacy TIMESTAMP tag, which holds microseconds, TIMESTAMP_MS,
#     TIMESTAMP_NS and TIMESTAMP_S) and a TIMESTAMP_US field with a time zone,
#     in CSV and JSON: NULL, the epoch, one tick before it, fractions with
#     their trailing zeros removed (.5, .12, .000001, .123456789), 1900,
#     year 1, 1 BC, 45 BC with a fraction, 9999 and 10000, DuckDB's smallest
#     and largest values of each unit, and INT64's largest and its negation as
#     `infinity` and `-infinity` (with no `+00` on the zoned column). Catches
#     a fraction padded or cut, a time of day computed by truncating toward
#     zero (negative before 1970), `(BC)` put after the time, and `+00`
#     missing or added where DuckDB has none.
#   * test_decimals_exactly: every scale digit kept (`12.50`, `0.00`),
#     `-0.05`, scale 0, and a 38-digit value past what a double holds.
#   * test_strings_quoted_and_escaped: CSV quotes exactly the empty string
#     and a string holding `,`, `"`, `\n` or `\r` (doubling `"`), and leaves
#     padding, `NULL`, a tab and non-ASCII as they are; JSON escapes `"` and
#     `\`, uses `\b \f \n \r \t`, writes other control bytes as upper-case
#     `\u00XX` and leaves `/`, DEL, U+2028 and non-ASCII as they are; a
#     column name is quoted and escaped the same way.
#   * test_json_decimal_38_0_is_an_integer: the DECIMAL(38, 0) an integer
#     sum() answers is written to JSON as exact digits, as DuckDB writes its
#     HUGEINT, while DECIMAL(18, 0) and a scale-30 decimal are doubles.
#   * test_an_empty_batch: CSV is the header row alone and JSON no byte.
#   * test_compression: gzip and zstd output starts with the format's magic
#     bytes and decompresses to the input (also for no input); any other
#     code returns the input.
#   * test_text_writable: true for every type above and false for a
#     time, duration, DATE64, binary, FLOAT16, DECIMAL256 and the nested
#     types.
#   * test_every_type_in_a_dialect: the every-type batch with DELIMITER '5',
#     NULL 'N', QUOTE '|', ESCAPE '\' and DATEFORMAT '%d %b %Y' is DuckDB's
#     file for the same rows and options: every cell holding a `5` quoted
#     with `|`, integers, doubles and decimals included, `N` for every
#     NULL, the empty string bare, `a"b` bare, dates in the format (1 BC as
#     year `0000`), and a dictionary read through its values. Catches a
#     number left unquoted, the default `"` or `,` used, and a type whose
#     NULL is still written empty.
#   * test_timestamp_units_under_timestampformat: TIMESTAMPFORMAT formats a
#     TIMESTAMP_US and a legacy TIMESTAMP column and leaves TIMESTAMP_NS and
#     _S in DuckDB's own text, as DuckDB does; JSON ignores the dialect.
#     Catches a format applied to a unit DuckDB writes as it is.
#   * test_write_refuses_a_timestamp_format_it_cannot_apply:
#     `write_text_result` with a TIMESTAMPFORMAT refuses a TIMESTAMP_MS
#     column (DuckDB formats one it read from Parquet and not a
#     TIMESTAMP_MS) and a zoned TIMESTAMP_NS (DuckDB has no such type),
#     each by exact message before any file is made; it writes them without
#     the format, and as JSON with it.

from std.os import listdir, makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.bitmap import Bitmap
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.dictionary_array import StringDictionaryArray
from arrow.large_string_array import LargeStringArray
from arrow.primitive_array import PrimitiveArray
from arrow.record_batch import RecordBatch, RecordBatchBuilder
from arrow.schema import Field, Schema, SchemaBuilder
from arrow.string_array import StringArray
from arrow.write_target import (
    WCOMP_GZIP,
    WCOMP_LZ4,
    WCOMP_SNAPPY,
    WCOMP_UNCOMPRESSED,
    WCOMP_ZSTD,
    WFMT_CSV,
    WFMT_JSONL,
)
from byte_buffer.heap_region import HeapRegion
from byte_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from compression.compression_codecs import Gzip
from compression.zstd_frame import zstd_decompress_into
from csv.csv_write_dialect import CsvWriteDialect, make_csv_write_dialect
from runtime_paths import test_tmpdir
from sdk_exec.engine_write import write_copy_result, write_text_result
from sdk_exec.engine_write_text import (
    compress_text,
    csv_double_text,
    date_text,
    decimal_text,
    encode_csv,
    encode_ndjson,
    json_double_text,
    text_writable,
)


def _text(bytes: List[UInt8]) -> String:
    return String(unsafe_from_utf8=Span(bytes))


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _prim[
    dt: DType
](a: Scalar[dt], c: Scalar[dt], at: ArrowType) raises -> Column[HeapRegion]:
    """Rows: a, NULL, c."""
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
    """Rows: "x", NULL, "y" through the dictionary ["y", "x"]."""
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


def _middle_null() -> List[Bool]:
    var v = List[Bool]()
    v.append(True)
    v.append(False)
    v.append(True)
    return v^


def _every_type_schema(dict_field: ArrowType) raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("i64", ArrowType.INT64, True))
    sb.add_field(Field("i32", ArrowType.INT32, True))
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
    sb.add_field(Field.decimal128("dec", 10, 2, True))
    sb.add_field(Field("d", ArrowType.DATE32, True))
    sb.add_field(Field("n", ArrowType.NULL, True))
    return sb.build()


def _every_type_batch(dict_field: ArrowType) raises -> RecordBatch:
    """Three rows: the first and last hold values, the middle one NULL in
    every column."""
    var rbb = RecordBatchBuilder()
    rbb.add_column(_prim[DType.int64](-5, 9223372036854775807, ArrowType.INT64))
    rbb.add_column(_prim[DType.int32](-7, 2147483647, ArrowType.INT32))
    rbb.add_column(_prim[DType.int16](-300, 32767, ArrowType.INT16))
    rbb.add_column(_prim[DType.int8](-8, 127, ArrowType.INT8))
    rbb.add_column(_prim[DType.uint64](18446744073709551615, 0, ArrowType.UINT64))
    rbb.add_column(_prim[DType.uint32](4294967295, 1, ArrowType.UINT32))
    rbb.add_column(_prim[DType.uint16](65535, 2, ArrowType.UINT16))
    rbb.add_column(_prim[DType.uint8](255, 3, ArrowType.UINT8))
    rbb.add_column(_prim[DType.float64](1.5, -1e16, ArrowType.FLOAT64))
    rbb.add_column(_prim[DType.float32](0.1, 1.5, ArrowType.FLOAT32))
    var b = BooleanArray.allocate_nullable(3)
    b.set(0, True)
    b.set(2, False)
    b._set_null(1)
    rbb.add_column(Column.from_boolean(b^))
    var sv = List[String]()
    sv.append('a"b')
    sv.append("")
    sv.append("")
    rbb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(sv, _middle_null()))
    )
    var lv = List[String]()
    lv.append("L,M")
    lv.append("")
    lv.append("cr\r")
    rbb.add_column(
        Column.from_large_string(
            LargeStringArray.from_strings_with_validity(lv, _middle_null())
        )
    )
    rbb.add_column(_dict_column())
    var dec = Decimal128Array.allocate_nullable(3, 10, 2)
    dec.set_raw(0, Int64(250), Int64(0))
    dec.set_raw(2, Int64(-5), Int64(-1))
    dec.set_null(1)
    rbb.add_column(Column.from_decimal128(dec^))
    rbb.add_column(_prim[DType.int32](19000, -719163, ArrowType.DATE32))
    rbb.add_column(_null_column(3))
    # `build` sets a STRING field over a DICTIONARY column to DICTIONARY;
    # the schema is put back afterwards to hold the field the test asks for.
    var batch = rbb.build(_every_type_schema(ArrowType.DICTIONARY))
    batch.schema = _every_type_schema(dict_field)
    return batch^


def test_every_type_as_csv() raises:
    var want = String(
        "i64,i32,i16,i8,u64,u32,u16,u8,f64,f32,b,s,ls,dict,dec,d,n\n"
        '-5,-7,-300,-8,18446744073709551615,4294967295,65535,255,1.5,0.1,true,"a""b","L,M",x,2.50,2022-01-08,\n'
        ",,,,,,,,,,,,,,,,\n"
        '9223372036854775807,2147483647,32767,127,0,1,2,3,-1e+16,1.5,false,"","cr\r",y,-0.05,0001-12-31 (BC),\n'
    )
    assert_equal(_text(encode_csv(_every_type_batch(ArrowType.DICTIONARY))), want)
    assert_equal(_text(encode_csv(_every_type_batch(ArrowType.STRING))), want)


def test_every_type_as_ndjson() raises:
    var want = String(
        '{"i64":-5,"i32":-7,"i16":-300,"i8":-8,"u64":18446744073709551615,'
        '"u32":4294967295,"u16":65535,"u8":255,"f64":1.5,'
        '"f32":0.10000000149011612,"b":true,"s":"a\\"b","ls":"L,M","dict":"x",'
        '"dec":2.5,"d":"2022-01-08","n":null}\n'
        '{"i64":null,"i32":null,"i16":null,"i8":null,"u64":null,"u32":null,'
        '"u16":null,"u8":null,"f64":null,"f32":null,"b":null,"s":null,'
        '"ls":null,"dict":null,"dec":null,"d":null,"n":null}\n'
        '{"i64":9223372036854775807,"i32":2147483647,"i16":32767,"i8":127,'
        '"u64":0,"u32":1,"u16":2,"u8":3,"f64":-10000000000000000.0,"f32":1.5,'
        '"b":false,"s":"","ls":"cr\\r","dict":"y","dec":-0.05,'
        '"d":"0001-12-31 (BC)","n":null}\n'
    )
    assert_equal(_text(encode_ndjson(_every_type_batch(ArrowType.DICTIONARY))), want)
    assert_equal(_text(encode_ndjson(_every_type_batch(ArrowType.STRING))), want)


def _double(v: Float64, csv: String, json: String) raises:
    assert_equal(csv_double_text[DType.float64](v), csv, csv)
    assert_equal(json_double_text(v), json, json)


def test_doubles_as_duckdb_renders_them() raises:
    var zero = Float64(0)
    _double(3.0, "3.0", "3.0")
    _double(0.1, "0.1", "0.1")
    _double(12.5, "12.5", "12.5")
    _double(0.0001, "0.0001", "0.0001")
    _double(1e-5, "1e-05", "0.00001")
    _double(1e-6, "1e-06", "0.000001")
    _double(1.25e-7, "1.25e-07", "1.25e-7")
    _double(-1e-7, "-1e-07", "-1e-7")
    _double(1e15, "1000000000000000.0", "1000000000000000.0")
    _double(1e16, "1e+16", "10000000000000000.0")
    _double(1e20, "1e+20", "100000000000000000000.0")
    _double(1e21, "1e+21", "1e21")
    _double(1.2345678901234569e23, "1.2345678901234569e+23", "1.2345678901234569e23")
    _double(1e300, "1e+300", "1e300")
    _double(5e-324, "5e-324", "5e-324")
    _double(123456789.125, "123456789.125", "123456789.125")
    _double(-2.5, "-2.5", "-2.5")
    _double(zero, "0.0", "0.0")
    _double(-zero, "-0.0", "-0.0")
    _double(zero / zero, "nan", "NaN")
    _double(1.0 / zero, "inf", "Infinity")
    _double(-1.0 / zero, "-inf", "-Infinity")
    assert_equal(csv_double_text[DType.float32](Float32(0.1)), "0.1")
    assert_equal(csv_double_text[DType.float32](Float32(-2.0)), "-2.0")
    assert_equal(csv_double_text[DType.float32](Float32(1e-5)), "1e-05")
    assert_equal(csv_double_text[DType.float32](Float32(3.4e38)), "3.4e+38")
    assert_equal(json_double_text(Float32(0.1).cast[DType.float64]()), "0.10000000149011612")


def test_dates_as_duckdb_renders_them() raises:
    assert_equal(date_text(0), "1970-01-01")
    assert_equal(date_text(-1), "1969-12-31")
    assert_equal(date_text(19000), "2022-01-08")
    assert_equal(date_text(-719162), "0001-01-01")
    assert_equal(date_text(-719163), "0001-12-31 (BC)")
    assert_equal(date_text(3652060), "11969-01-01")
    assert_equal(date_text(-735550), "0045-02-19 (BC)")
    assert_equal(date_text(-2932897), "6061-01-02 (BC)")


def _ts_column(
    mut sb: SchemaBuilder,
    mut rb: RecordBatchBuilder,
    name: String,
    at: ArrowType,
    tz: String,
    values: List[Int64],
) raises:
    """A nullable timestamp column: a NULL, then `values`."""
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(values) + 1)
    arr._set_null(0)
    for i in range(len(values)):
        arr.set(i + 1, values[i])
    sb.add_field(Field.timestamp(name, at, tz, True))
    rb.add_column(Column.from_primitive_with_arrow_type[DType.int64](arr^, at))


def _lines(header: String, cells: List[String]) -> String:
    var out = header + "\n"
    for i in range(len(cells)):
        out += cells[i] + "\n"
    return out^


def test_timestamps_as_duckdb_renders_them() raises:
    # The legacy tag: microseconds, as the pinned DuckDB renders a TIMESTAMP.
    var us: List[Int64] = [
        0, -1, 1441369845123456, 1441369845500000, 1441369845120000,
        1441369845000001, -2208985076600000, -62135596800000000,
        -62135683200000000, -63526982399999999, 253402300799999999,
        253402300800000000, 9223372036854775806, -9223372022400000000,
        Int64.MAX, -Int64.MAX,
    ]
    var us_text: List[String] = [
        "1970-01-01 00:00:00", "1969-12-31 23:59:59.999999",
        "2015-09-04 12:30:45.123456", "2015-09-04 12:30:45.5",
        "2015-09-04 12:30:45.12", "2015-09-04 12:30:45.000001",
        "1900-01-01 01:02:03.4", "0001-01-01 00:00:00",
        "0001-12-31 (BC) 00:00:00", "0045-11-29 (BC) 00:00:00.000001",
        "9999-12-31 23:59:59.999999", "10000-01-01 00:00:00",
        "294247-01-10 04:00:54.775806", "290309-12-22 (BC) 00:00:00",
        "infinity", "-infinity",
    ]
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    _ts_column(sb, rb, "ts", ArrowType.TIMESTAMP, "", us)
    var batch = rb.build(sb.build())
    var csv = List[String]()
    var json = List[String]()
    csv.append("")
    json.append('{"ts":null}')
    for i in range(len(us_text)):
        csv.append(us_text[i])
        json.append('{"ts":"' + us_text[i] + '"}')
    assert_equal(_text(encode_csv(batch)), _lines("ts", csv))
    var want_json = String()
    for i in range(len(json)):
        want_json += json[i] + "\n"
    assert_equal(_text(encode_ndjson(batch)), want_json)

    # Milliseconds, nanoseconds, seconds, and a zoned column (DuckDB's
    # TIMESTAMPTZ in the UTC session), four rows each after the NULL.
    var sb2 = SchemaBuilder()
    var rb2 = RecordBatchBuilder()
    _ts_column(sb2, rb2, "ms", ArrowType.TIMESTAMP_MS, "", [
        -1, 1441369845120, 9223372036854775, -9223372022400000, Int64.MAX,
    ])
    _ts_column(sb2, rb2, "ns", ArrowType.TIMESTAMP_NS, "", [
        1441369845123456789, -1, 1441369845000000001, -9223286400000000000,
        -Int64.MAX,
    ])
    _ts_column(sb2, rb2, "s", ArrowType.TIMESTAMP_S, "", [
        -1, 1441369845, 9223372036854, -9223372022400, Int64.MAX,
    ])
    _ts_column(sb2, rb2, "tz", ArrowType.TIMESTAMP_US, "UTC", [
        0, -1, 1441369845123456, -62135683200000000, Int64.MAX,
    ])
    var b2 = rb2.build(sb2.build())
    assert_equal(
        _text(encode_csv(b2)),
        "ms,ns,s,tz\n"
        ",,,\n"
        "1969-12-31 23:59:59.999,2015-09-04 12:30:45.123456789,"
        "1969-12-31 23:59:59,1970-01-01 00:00:00+00\n"
        "2015-09-04 12:30:45.12,1969-12-31 23:59:59.999999999,"
        "2015-09-04 12:30:45,1969-12-31 23:59:59.999999+00\n"
        "294247-01-10 04:00:54.775,2015-09-04 12:30:45.000000001,"
        "294247-01-10 04:00:54,2015-09-04 12:30:45.123456+00\n"
        "290309-12-22 (BC) 00:00:00,1677-09-22 00:00:00,"
        "290309-12-22 (BC) 00:00:00,0001-12-31 (BC) 00:00:00+00\n"
        "infinity,-infinity,infinity,infinity\n",
    )
    assert_equal(
        _text(encode_ndjson(b2)),
        '{"ms":null,"ns":null,"s":null,"tz":null}\n'
        '{"ms":"1969-12-31 23:59:59.999","ns":"2015-09-04 12:30:45.123456789",'
        '"s":"1969-12-31 23:59:59","tz":"1970-01-01 00:00:00+00"}\n'
        '{"ms":"2015-09-04 12:30:45.12","ns":"1969-12-31 23:59:59.999999999",'
        '"s":"2015-09-04 12:30:45","tz":"1969-12-31 23:59:59.999999+00"}\n'
        '{"ms":"294247-01-10 04:00:54.775","ns":"2015-09-04 12:30:45.000000001",'
        '"s":"294247-01-10 04:00:54","tz":"2015-09-04 12:30:45.123456+00"}\n'
        '{"ms":"290309-12-22 (BC) 00:00:00","ns":"1677-09-22 00:00:00",'
        '"s":"290309-12-22 (BC) 00:00:00","tz":"0001-12-31 (BC) 00:00:00+00"}\n'
        '{"ms":"infinity","ns":"-infinity","s":"infinity","tz":"infinity"}\n',
    )


def test_decimals_exactly() raises:
    comptime I = DType.int128
    assert_equal(decimal_text(Scalar[I](1250), 2), "12.50")
    assert_equal(decimal_text(Scalar[I](-5), 2), "-0.05")
    assert_equal(decimal_text(Scalar[I](0), 2), "0.00")
    assert_equal(decimal_text(Scalar[I](42), 0), "42")
    assert_equal(decimal_text(Scalar[I](-42), 0), "-42")
    assert_equal(decimal_text(Scalar[I](0), 0), "0")
    var big = Scalar[I](0)
    for _ in range(38):
        big = big * 10 + 9
    assert_equal(decimal_text(big, 10), "9999999999999999999999999999.9999999999")
    assert_equal(decimal_text(-big, 38), "-0.99999999999999999999999999999999999999")


def _one_string_column(name: String, values: List[String]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, False))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_string(StringArray.from_strings(values)))
    return rbb.build(sb.build())


def test_strings_quoted_and_escaped() raises:
    var values = List[String]()
    values.append("")
    values.append("plain")
    values.append("a,b")
    values.append('q"x')
    values.append("line\nbreak")
    values.append("cr\rhere")
    values.append("  padded  ")
    values.append("NULL")
    values.append("tab\there")
    values.append("café")
    values.append("ctl" + chr(1) + chr(31) + chr(8) + chr(12))
    values.append("back\\slash/" + chr(127) + chr(8232))
    var batch = _one_string_column("na,me\"", values)
    assert_equal(
        _text(encode_csv(batch)),
        String(
            '"na,me"""\n'
            '""\n'
            "plain\n"
            '"a,b"\n'
            '"q""x"\n'
            '"line\nbreak"\n'
            '"cr\rhere"\n'
            "  padded  \n"
            "NULL\n"
            "tab\there\n"
            "café\n"
        ) + "ctl" + chr(1) + chr(31) + chr(8) + chr(12) + "\n"
        + "back\\slash/" + chr(127) + chr(8232) + "\n",
    )
    assert_equal(
        _text(encode_ndjson(batch)),
        String(
            '{"na,me\\"":""}\n'
            '{"na,me\\"":"plain"}\n'
            '{"na,me\\"":"a,b"}\n'
            '{"na,me\\"":"q\\"x"}\n'
            '{"na,me\\"":"line\\nbreak"}\n'
            '{"na,me\\"":"cr\\rhere"}\n'
            '{"na,me\\"":"  padded  "}\n'
            '{"na,me\\"":"NULL"}\n'
            '{"na,me\\"":"tab\\there"}\n'
            '{"na,me\\"":"café"}\n'
            '{"na,me\\"":"ctl\\u0001\\u001F\\b\\f"}\n'
            '{"na,me\\"":"back\\\\slash/'
        ) + chr(127) + chr(8232) + "\"}\n",
    )


def test_json_decimal_38_0_is_an_integer() raises:
    """DECIMAL(38, 0) (an integer sum(), DuckDB's HUGEINT) is written to JSON
    as its exact digits, past what a double holds; DECIMAL(18, 0) and a
    DECIMAL(38, 30) as the double nearest their value; CSV keeps every digit
    of each."""
    var big = Scalar[DType.int128](0)
    for _ in range(38):
        big = big * 10 + 9
    var sb = SchemaBuilder()
    sb.add_field(Field.decimal128("h", 38, 0, False))
    sb.add_field(Field.decimal128("e", 18, 0, False))
    sb.add_field(Field.decimal128("f", 38, 30, False))
    var h = Decimal128Array.allocate(1, 38, 0)
    h.set_i128(0, -big)
    var e = Decimal128Array.allocate(1, 18, 0)
    e.set_i128(0, Scalar[DType.int128](42))
    var f = Decimal128Array.allocate(1, 38, 30)
    var one = Scalar[DType.int128](1)
    for _ in range(30):
        one = one * 10
    f.set_i128(0, one)
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_decimal128(h^))
    rbb.add_column(Column.from_decimal128(e^))
    rbb.add_column(Column.from_decimal128(f^))
    var batch = rbb.build(sb.build())
    assert_equal(
        _text(encode_ndjson(batch)),
        String('{"h":-99999999999999999999999999999999999999,"e":42.0,"f":1.0}\n'),
    )
    assert_equal(
        _text(encode_csv(batch)),
        String("h,e,f\n-99999999999999999999999999999999999999,42,1.000000000000000000000000000000\n"),
    )


def test_an_empty_batch() raises:
    var batch = _one_string_column("s", List[String]())
    assert_equal(_text(encode_csv(batch)), "s\n")
    assert_equal(len(encode_ndjson(batch)), 0)


def _unzstd(frame: List[UInt8], size: Int) raises -> List[UInt8]:
    var out = List[UInt8](capacity=size + 1)
    out.resize(size + 1, UInt8(0))
    var n = zstd_decompress_into(Span(out), Span(frame))
    out.resize(n, UInt8(0))
    return out^


def test_compression() raises:
    var plain = _bytes("a,b\n1,2\n")
    var gz = compress_text(plain.copy(), WCOMP_GZIP)
    assert_equal(gz[0], UInt8(0x1F))
    assert_equal(gz[1], UInt8(0x8B))
    assert_equal(_text(Gzip[6].decompress(Span(gz), len(plain))), "a,b\n1,2\n")
    var zst = compress_text(plain.copy(), WCOMP_ZSTD)
    assert_equal(zst[0], UInt8(0x28))
    assert_equal(zst[1], UInt8(0xB5))
    assert_equal(zst[2], UInt8(0x2F))
    assert_equal(zst[3], UInt8(0xFD))
    assert_equal(_text(_unzstd(zst, len(plain))), "a,b\n1,2\n")
    var empty_zst = compress_text(List[UInt8](), WCOMP_ZSTD)
    assert_equal(empty_zst[0], UInt8(0x28))
    assert_equal(len(_unzstd(empty_zst, 0)), 0)
    var empty_gz = compress_text(List[UInt8](), WCOMP_GZIP)
    assert_equal(empty_gz[0], UInt8(0x1F))
    assert_equal(len(empty_gz), 20)
    assert_equal(_text(compress_text(plain.copy(), WCOMP_UNCOMPRESSED)), "a,b\n1,2\n")
    assert_equal(_text(compress_text(plain.copy(), WCOMP_SNAPPY)), "a,b\n1,2\n")
    assert_equal(_text(compress_text(plain.copy(), WCOMP_LZ4)), "a,b\n1,2\n")


def test_text_writable() raises:
    var yes = List[ArrowType]()
    yes.append(ArrowType.NULL)
    yes.append(ArrowType.BOOL)
    yes.append(ArrowType.INT8)
    yes.append(ArrowType.INT16)
    yes.append(ArrowType.INT32)
    yes.append(ArrowType.INT64)
    yes.append(ArrowType.UINT8)
    yes.append(ArrowType.UINT16)
    yes.append(ArrowType.UINT32)
    yes.append(ArrowType.UINT64)
    yes.append(ArrowType.FLOAT32)
    yes.append(ArrowType.FLOAT64)
    yes.append(ArrowType.STRING)
    yes.append(ArrowType.LARGE_STRING)
    yes.append(ArrowType.DICTIONARY)
    yes.append(ArrowType.DATE32)
    yes.append(ArrowType.DECIMAL128)
    yes.append(ArrowType.TIMESTAMP)
    yes.append(ArrowType.TIMESTAMP_S)
    yes.append(ArrowType.TIMESTAMP_MS)
    yes.append(ArrowType.TIMESTAMP_US)
    yes.append(ArrowType.TIMESTAMP_NS)
    for i in range(len(yes)):
        assert_true(text_writable(yes[i]), String(yes[i]))
    var no = List[ArrowType]()
    no.append(ArrowType.TIME32_S)
    no.append(ArrowType.TIME64_US)
    no.append(ArrowType.DURATION_US)
    no.append(ArrowType.DATE64)
    no.append(ArrowType.BINARY)
    no.append(ArrowType.FLOAT16)
    no.append(ArrowType.DECIMAL256)
    no.append(ArrowType.LIST)
    no.append(ArrowType.STRUCT)
    no.append(ArrowType.MAP)
    for i in range(len(no)):
        assert_false(text_writable(no[i]), String(no[i]))


def _opt(v: String) -> Optional[String]:
    return Optional[String](v)


def test_every_type_in_a_dialect() raises:
    var dialect = make_csv_write_dialect(
        _opt("5"), _opt("|"), _opt("\\"), _opt("N"), True,
        _opt("%d %b %Y"), Optional[String](),
    )
    var want = String(
        "i645i325i165i85u645u325u165u85f645f325b5s5ls5dict5dec5d5n\n"
        "|-5|5-75-3005-85|18446744073709551615|5|4294967295|5|65535|5|255|5|1.5|50.15true5a\"b5L,M5x5|2.50|508 Jan 20225N\n"
        "N5N5N5N5N5N5N5N5N5N5N5N5N5N5N5N5N\n"
        "|9223372036854775807|521474836475327675127505152535-1e+165|1.5|5false55|cr\r|5y5|-0.05|531 Dec 00005N\n"
    )
    assert_equal(_text(encode_csv(_every_type_batch(ArrowType.DICTIONARY), dialect)), want)
    assert_equal(_text(encode_csv(_every_type_batch(ArrowType.STRING), dialect)), want)


def _units_batch() raises -> RecordBatch:
    """One row of 2020-01-02 03:04:05 with a fraction, in each unit."""
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    var units: List[ArrowType] = [
        ArrowType.TIMESTAMP_NS, ArrowType.TIMESTAMP_S, ArrowType.TIMESTAMP_US,
        ArrowType.TIMESTAMP,
    ]
    var names: List[String] = ["ns", "s", "us", "legacy"]
    var values: List[Int64] = [
        1577934245123456789, 1577934245, 1577934245123456, 1577934245123456,
    ]
    for i in range(len(units)):
        var arr = PrimitiveArray[DType.int64].allocate(1)
        arr.set(0, values[i])
        sb.add_field(Field.timestamp(names[i], units[i], "", True))
        rbb.add_column(Column.from_primitive_with_arrow_type[DType.int64](arr^, units[i]))
    return rbb.build(sb.build())


def test_timestamp_units_under_timestampformat() raises:
    var dialect = make_csv_write_dialect(
        Optional[String](), Optional[String](), Optional[String](),
        Optional[String](), True, Optional[String](), _opt("%Y|%f"),
    )
    assert_equal(
        _text(encode_csv(_units_batch(), dialect)),
        "ns,s,us,legacy\n"
        "2020-01-02 03:04:05.123456789,2020-01-02 03:04:05,2020|123456,"
        "2020|123456\n",
    )
    assert_equal(
        _text(encode_ndjson(_units_batch())),
        '{"ns":"2020-01-02 03:04:05.123456789","s":"2020-01-02 03:04:05",'
        '"us":"2020-01-02 03:04:05.123456","legacy":"2020-01-02 03:04:05.123456"}\n',
    )


def _one_timestamp(name: String, at: ArrowType, tz: String, v: Int64) raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rbb = RecordBatchBuilder()
    var arr = PrimitiveArray[DType.int64].allocate(1)
    arr.set(0, v)
    sb.add_field(Field.timestamp(name, at, tz, True))
    rbb.add_column(Column.from_primitive_with_arrow_type[DType.int64](arr^, at))
    return rbb.build(sb.build())


def _refused_write(var batch: RecordBatch, dest: String, dialect: CsvWriteDialect, want: String) raises:
    try:
        _ = write_text_result(batch^, dest, WFMT_CSV, WCOMP_UNCOMPRESSED, dialect)
    except e:
        assert_equal(String(e), want)
        return
    assert_true(False, "not refused: " + want)


def test_write_refuses_a_timestamp_format_it_cannot_apply() raises:
    var dir = test_tmpdir() + "/copy_text_timestamp_format"
    makedirs(dir, exist_ok=True)
    var dest = dir + "/t.csv"
    var dialect = make_csv_write_dialect(
        Optional[String](), Optional[String](), Optional[String](),
        Optional[String](), True, Optional[String](), _opt("%c"),
    )
    var head = "COPY_TYPE_UNSUPPORTED: COPY ... TO '" + dest + "' (TIMESTAMPFORMAT): column "
    _refused_write(
        _one_timestamp("ms", ArrowType.TIMESTAMP_MS, "", 1577934245123), dest, dialect,
        head + "'ms' has type timestamp[ms], which DuckDB formats when it read"
        " it from Parquet (as a TIMESTAMP) and writes in its own text when it"
        " is a TIMESTAMP_MS; cast it to TIMESTAMP",
    )
    _refused_write(
        _one_timestamp("zns", ArrowType.TIMESTAMP_NS, "UTC", 1577934245123456789), dest, dialect,
        head + "'zns' has type timestamp[ns] with a time zone, which DuckDB"
        " holds only at microseconds; cast it to TIMESTAMPTZ",
    )
    assert_equal(len(listdir(dir)), 0)
    assert_equal(write_copy_result(_one_timestamp("ms", ArrowType.TIMESTAMP_MS, "", 1577934245123), dest, WFMT_CSV, WCOMP_UNCOMPRESSED), 1)
    var fh = open(dest, "r")
    assert_equal(fh.read(), "ms\n2020-01-02 03:04:05.123\n")
    fh.close()
    assert_equal(
        write_copy_result(_one_timestamp("zns", ArrowType.TIMESTAMP_NS, "UTC", 1577934245123456789), dir + "/t.json", WFMT_JSONL, WCOMP_UNCOMPRESSED, dialect), 1
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
