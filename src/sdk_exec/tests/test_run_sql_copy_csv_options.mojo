# =============================================================================
# run_sql: COPY ... TO a CSV file with DELIMITER, QUOTE, ESCAPE, NULL, HEADER
# false, DATEFORMAT and TIMESTAMPFORMAT
# =============================================================================
#
# Covers: `COPY (SELECT ...) TO '<file>.csv' (<CSV options>)` through run_sql
# writes the bytes DuckDB's COPY writes for the same rows and options, and
# refuses by name, with no file made, what DuckDB refuses or this engine
# cannot write.
#
# The table `u` is a Parquet file of 5 rows: k BIGINT NOT NULL 0..4 and
# nullable s VARCHAR (`x;y`, the empty string, NULL, `say "hi"` and a line
# break, `NA`), t2 VARCHAR (a tab, a backslash, a comma, a `|`, an
# apostrophe), v DOUBLE, d DATE (2020, 1969, 44 BC, 2026), ts TIMESTAMP_US
# and z, ts with the time zone "UTC" (DuckDB's TIMESTAMPTZ), each NULL in
# row 1. Every expected file below is the one the pinned DuckDB's COPY wrote
# for the same table, query and options (in a session whose time zone is
# UTC). Each test writes into its own directory under test_tmpdir() and
# lists it afterwards, so a file a refused COPY should not have made fails
# the test.
#
# What each test proves:
#   * test_a_semicolon_and_a_tab: DELIMITER ';' puts `;` between cells and
#     quotes `x;y` (and no longer `c,d`); DELIM '\t' puts a tab between them
#     and quotes the cell holding a tab. Catches the comma kept, and quoting
#     that still tests for `,`.
#   * test_delim_and_sep_are_delimiter: DELIM ';' and SEP ';' write the
#     bytes DELIMITER ';' writes. Catches an alias read as another option.
#   * test_header_false: SEP '|' with HEADER false writes no header line and
#     quotes `p|q`; HEADER false on an empty result writes an empty file.
#     Catches the header written anyway, and an empty file given a header.
#   * test_null_na: NULL 'NA' writes NA for every NULL, quotes the string
#     `NA` so it reads back as a string, and leaves the empty string
#     unquoted, as DuckDB does. Catches the empty string still quoted (it is
#     only quoted when it equals the NULL text) and `NA` written bare.
#   * test_quote_and_escape: QUOTE '''' with ESCAPE '\' quotes with `'`,
#     escapes the apostrophe of `it's` as `\'`, leaves `say "hi"` with its
#     `"` as it is; QUOTE '' quotes nothing, not even a cell holding the
#     delimiter. Catches the default `"` kept, a quote doubled where DuckDB
#     escapes it, and an empty QUOTE read as `"`.
#   * test_date_and_timestamp_formats: DATEFORMAT '%d/%m/%Y' and
#     TIMESTAMPFORMAT '%d/%m/%Y %H:%M:%S.%f %Z' write each DATE (44 BC as
#     `15/03/-43`) and each TIMESTAMP in the format, `UTC` for %Z only in the
#     zoned column; with DELIMITER '.', a formatted date and a DOUBLE holding
#     the delimiter are quoted. Catches a format applied to the wrong type,
#     the zoned column written in DuckDB's default text, and quoting applied
#     to strings only.
#   * test_a_format_no_column_uses: DATEFORMAT '%Q' on a result with no DATE
#     column writes the file, as DuckDB does. Catches a format refused before
#     the writer knows whether a column uses it.
#   * test_compressed_with_options: DELIMITER ';' with HEADER false and
#     COMPRESSION gzip is the gzip of those bytes.
#   * test_refused_options_touch_no_file: DATEFORMAT '%Q' and
#     TIMESTAMPFORMAT '' over columns they apply to, `%n`, a two-byte
#     delimiter, QUOTE inside DELIMITER, the delimiter inside NULL, an
#     unknown option and DELIMITER on Parquet are refused at their steps
#     (`parse`, or `execute` for a format, which is parsed when a column
#     uses it) by exact message, and the directory stays empty until the
#     same COPY without the refused option writes. Catches an option
#     ignored and the file written in DuckDB's defaults instead.

from std.os import listdir, makedirs
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow.string_array import StringArray
from compression.compression_codecs import Gzip
from parquet_writer.record_batch_writer import write_record_batch_to_parquet_bytes
from runtime_paths import test_tmpdir
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_EXECUTE, STEP_PARSE, run_sql
from sdk_exec.engine_write import COPY_COUNT_COLUMN

comptime _SEMICOLON = (
    "k;s;t2;v;d;ts;z\n"
    "0;\"x;y\";a\tb;1.5;2020-01-02;2020-01-02 03:04:05.5;2020-01-02 03:04:05.5+00\n"
    "1;\"\";a\\b;;;;\n"
    "2;;c,d;-0.25;1969-12-31;1969-12-31 23:59:59.999999;1969-12-31 23:59:59.999999+00\n"
    "3;\"say \"\"hi\"\"\n"
    "\";p|q;1e+16;0044-03-15 (BC);2005-03-07 13:04:05.123456;2005-03-07 13:04:05.123456+00\n"
    "4;NA;it's;2.0;2026-11-27;2026-11-27 00:00:00;2026-11-27 00:00:00+00\n"
)
comptime _TAB = (
    "k\ts\tt2\tv\td\tts\tz\n"
    "0\tx;y\t\"a\tb\"\t1.5\t2020-01-02\t2020-01-02 03:04:05.5\t2020-01-02 03:04:05.5+00\n"
    "1\t\"\"\ta\\b\t\t\t\t\n"
    "2\t\tc,d\t-0.25\t1969-12-31\t1969-12-31 23:59:59.999999\t1969-12-31 23:59:59.999999+00\n"
    "3\t\"say \"\"hi\"\"\n"
    "\"\tp|q\t1e+16\t0044-03-15 (BC)\t2005-03-07 13:04:05.123456\t2005-03-07 13:04:05.123456+00\n"
    "4\tNA\tit's\t2.0\t2026-11-27\t2026-11-27 00:00:00\t2026-11-27 00:00:00+00\n"
)
comptime _PIPE_NO_HEADER = (
    "0|x;y|a\tb|1.5|2020-01-02|2020-01-02 03:04:05.5|2020-01-02 03:04:05.5+00\n"
    "1|\"\"|a\\b||||\n"
    "2||c,d|-0.25|1969-12-31|1969-12-31 23:59:59.999999|1969-12-31 23:59:59.999999+00\n"
    "3|\"say \"\"hi\"\"\n"
    "\"|\"p|q\"|1e+16|0044-03-15 (BC)|2005-03-07 13:04:05.123456|2005-03-07 13:04:05.123456+00\n"
    "4|NA|it's|2.0|2026-11-27|2026-11-27 00:00:00|2026-11-27 00:00:00+00\n"
)
comptime _NULL_NA = (
    "k,s,t2,v,d,ts,z\n"
    "0,x;y,a\tb,1.5,2020-01-02,2020-01-02 03:04:05.5,2020-01-02 03:04:05.5+00\n"
    "1,,a\\b,NA,NA,NA,NA\n"
    "2,NA,\"c,d\",-0.25,1969-12-31,1969-12-31 23:59:59.999999,1969-12-31 23:59:59.999999+00\n"
    "3,\"say \"\"hi\"\"\n"
    "\",p|q,1e+16,0044-03-15 (BC),2005-03-07 13:04:05.123456,2005-03-07 13:04:05.123456+00\n"
    "4,\"NA\",it's,2.0,2026-11-27,2026-11-27 00:00:00,2026-11-27 00:00:00+00\n"
)
comptime _QUOTE_ESCAPE = (
    "k,s,t2,v,d,ts,z\n"
    "0,x;y,a\tb,1.5,2020-01-02,2020-01-02 03:04:05.5,2020-01-02 03:04:05.5+00\n"
    "1,'',a\\b,,,,\n"
    "2,,'c,d',-0.25,1969-12-31,1969-12-31 23:59:59.999999,1969-12-31 23:59:59.999999+00\n"
    "3,'say \"hi\"\n"
    "',p|q,1e+16,0044-03-15 (BC),2005-03-07 13:04:05.123456,2005-03-07 13:04:05.123456+00\n"
    "4,NA,'it\\'s',2.0,2026-11-27,2026-11-27 00:00:00,2026-11-27 00:00:00+00\n"
)
comptime _NO_QUOTE = (
    "k,s,t2,v,d,ts,z\n"
    "0,x;y,a\tb,1.5,2020-01-02,2020-01-02 03:04:05.5,2020-01-02 03:04:05.5+00\n"
    "1,,a\\b,,,,\n"
    "2,,c,d,-0.25,1969-12-31,1969-12-31 23:59:59.999999,1969-12-31 23:59:59.999999+00\n"
    "3,say \"hi\"\n"
    ",p|q,1e+16,0044-03-15 (BC),2005-03-07 13:04:05.123456,2005-03-07 13:04:05.123456+00\n"
    "4,NA,it's,2.0,2026-11-27,2026-11-27 00:00:00,2026-11-27 00:00:00+00\n"
)
comptime _FORMATS = (
    "k,s,t2,v,d,ts,z\n"
    "0,x;y,a\tb,1.5,02/01/2020,02/01/2020 03:04:05.500000 ,02/01/2020 03:04:05.500000 UTC\n"
    "1,\"\",a\\b,,,,\n"
    "2,,\"c,d\",-0.25,31/12/1969,31/12/1969 23:59:59.999999 ,31/12/1969 23:59:59.999999 UTC\n"
    "3,\"say \"\"hi\"\"\n"
    "\",p|q,1e+16,15/03/-43,07/03/2005 13:04:05.123456 ,07/03/2005 13:04:05.123456 UTC\n"
    "4,NA,it's,2.0,27/11/2026,27/11/2026 00:00:00.000000 ,27/11/2026 00:00:00.000000 UTC\n"
)
comptime _DOT_DATES = (
    "k.v.d\n"
    "0.\"1.5\".\"02.01.2020\"\n"
    "1..\n"
    "2.\"-0.25\".\"31.12.1969\"\n"
    "3.1e+16.\"15.03.-43\"\n"
    "4.\"2.0\".\"27.11.2026\"\n"
)
comptime _UNUSED_FORMAT = (
    "k,s\n"
    "0,x;y\n"
    "1,\"\"\n"
    "2,\n"
    "3,\"say \"\"hi\"\"\n"
    "\"\n"
    "4,NA\n"
)
comptime _KS_SEMICOLON_NO_HEADER = (
    "0;\"x;y\"\n"
    "1;\"\"\n"
    "2;\n"
    "3;\"say \"\"hi\"\"\n"
    "\"\n"
    "4;NA\n"
)

comptime _ALL = "(SELECT * FROM u ORDER BY k)"
comptime _ROWS = 5


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/copy_csv_options_" + name
    makedirs(d, exist_ok=True)
    return d^


def _assert_only(dir: String, want: List[String]) raises:
    var got = listdir(dir)
    sort(got)
    assert_equal(len(got), len(want), "entries of " + dir)
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _read(path: String) raises -> List[UInt8]:
    var fh = open(path, "r")
    var bytes = fh.read_bytes()
    fh.close()
    return bytes^


def _text(path: String) raises -> String:
    return String(unsafe_from_utf8=Span(_read(path)))


def _strings(
    mut sb: SchemaBuilder,
    mut rb: RecordBatchBuilder,
    name: String,
    values: List[String],
    valid: List[Bool],
) raises:
    sb.add_field(Field(name, ArrowType.STRING, True))
    rb.add_column(
        Column.from_string(StringArray.from_strings_with_validity(values, valid))
    )


def _timestamps(
    mut sb: SchemaBuilder,
    mut rb: RecordBatchBuilder,
    name: String,
    at: ArrowType,
    tz: String,
    values: List[Int64],
) raises:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(_ROWS)
    for r in range(_ROWS):
        if r == 1:
            arr._set_null(r)
        else:
            arr.set(r, values[r])
    sb.add_field(Field.timestamp(name, at, tz, True))
    rb.add_column(Column.from_primitive_with_arrow_type[DType.int64](arr^, at))


def _table() raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    var k = PrimitiveArray[DType.int64].allocate(_ROWS)
    for x in range(_ROWS):
        k.set(x, Int64(x))
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    _strings(sb, rb, "s", ["x;y", "", "", "say \"hi\"\n", "NA"], [True, True, False, True, True])
    _strings(sb, rb, "t2", ["a\tb", "a\\b", "c,d", "p|q", "it's"], [True, True, True, True, True])
    var v = PrimitiveArray[DType.float64].allocate_nullable(_ROWS)
    var vs: List[Float64] = [1.5, 0.0, -0.25, 1e16, 2.0]
    var d = PrimitiveArray[DType.int32].allocate_nullable(_ROWS)
    var ds: List[Int32] = [18263, 0, -1, -735160, 20784]
    for r in range(_ROWS):
        if r == 1:
            v._set_null(r)
            d._set_null(r)
        else:
            v.set(r, vs[r])
            d.set(r, ds[r])
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    rb.add_column(Column.from_primitive[DType.float64](v^))
    sb.add_field(Field("d", ArrowType.DATE32, True))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](d^, ArrowType.DATE32)
    )
    var us: List[Int64] = [1577934245500000, 0, -1, 1110200645123456, 1795737600000000]
    _timestamps(sb, rb, "ts", ArrowType.TIMESTAMP_US, "", us)
    _timestamps(sb, rb, "z", ArrowType.TIMESTAMP_US, "UTC", us)
    return rb.build(sb.build())


def _write_parquet(path: String, batch: RecordBatch) raises:
    var bytes = write_record_batch_to_parquet_bytes(batch)
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()


def _context() raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var input = _dir("input")
    _write_parquet(input + "/u.parquet", _table())
    register_parquet(ctx, "u", input + "/u.parquet")
    return ctx^


def _copy(mut ctx: EngineContext, sql: String, rows: Int) raises:
    """Run the COPY `sql` and check its answer: one row, `Count` = `rows`."""
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason + " -- " + sql,
        )
    assert_equal(len(out.batches), 1)
    ref batch = out.batches[0]
    assert_equal(batch.schema.field_name(0), String(COPY_COUNT_COLUMN))
    assert_equal(Int(batch.column_at(0).as_primitive[DType.int64]().get(0)), rows)


def _file(mut ctx: EngineContext, query: String, opts: String, rows: Int, dir: String, name: String) raises -> String:
    """COPY `query` to `dir`/`name` with the options `opts`, and the file's text."""
    var path = dir + "/" + name
    _copy(ctx, "COPY " + query + " TO '" + path + "' (" + opts + ")", rows)
    return _text(path)


def _refusal(mut ctx: EngineContext, sql: String, step: String, reason: String) raises:
    var out = run_sql(ctx, sql)
    assert_true(Bool(out.refusal), "not refused: " + sql)
    assert_equal(out.refusal.value().step, step, sql)
    assert_equal(out.refusal.value().reason, reason, sql)


def test_a_semicolon_and_a_tab() raises:
    var ctx = _context()
    var d = _dir("delimiters")
    assert_equal(_file(ctx, _ALL, "FORMAT csv, DELIMITER ';'", 5, d, "semi.csv"), String(_SEMICOLON))
    assert_equal(_file(ctx, _ALL, "DELIM '\\t'", 5, d, "tab.csv"), String(_TAB))


def test_delim_and_sep_are_delimiter() raises:
    var ctx = _context()
    var d = _dir("aliases")
    assert_equal(_file(ctx, _ALL, "DELIM ';'", 5, d, "delim.csv"), String(_SEMICOLON))
    assert_equal(_file(ctx, _ALL, "SEP ';'", 5, d, "sep.csv"), String(_SEMICOLON))


def test_header_false() raises:
    var ctx = _context()
    var d = _dir("header")
    assert_equal(_file(ctx, _ALL, "SEP '|', HEADER false", 5, d, "pipe.csv"), String(_PIPE_NO_HEADER))
    assert_equal(_file(ctx, "(SELECT * FROM u WHERE k < 0)", "HEADER false", 0, d, "empty.csv"), String(""))


def test_null_na() raises:
    var ctx = _context()
    var d = _dir("null")
    assert_equal(_file(ctx, _ALL, "NULL 'NA'", 5, d, "na.csv"), String(_NULL_NA))
    assert_equal(_file(ctx, _ALL, "NULLSTR 'NA'", 5, d, "nullstr.csv"), String(_NULL_NA))


def test_quote_and_escape() raises:
    var ctx = _context()
    var d = _dir("quote")
    assert_equal(_file(ctx, _ALL, "QUOTE '''', ESCAPE '\\'", 5, d, "q.csv"), String(_QUOTE_ESCAPE))
    assert_equal(_file(ctx, _ALL, "QUOTE ''", 5, d, "none.csv"), String(_NO_QUOTE))


def test_date_and_timestamp_formats() raises:
    var ctx = _context()
    var d = _dir("formats")
    assert_equal(
        _file(ctx, _ALL, "DATEFORMAT '%d/%m/%Y', TIMESTAMPFORMAT '%d/%m/%Y %H:%M:%S.%f %Z'", 5, d, "f.csv"),
        String(_FORMATS),
    )
    assert_equal(
        _file(ctx, "(SELECT k, v, d FROM u ORDER BY k)", "DATEFORMAT '%d.%m.%Y', DELIMITER '.'", 5, d, "dot.csv"),
        String(_DOT_DATES),
    )


def test_a_format_no_column_uses() raises:
    var ctx = _context()
    var d = _dir("unused")
    assert_equal(
        _file(ctx, "(SELECT k, s FROM u ORDER BY k)", "DATEFORMAT '%Q'", 5, d, "u.csv"),
        String(_UNUSED_FORMAT),
    )


def test_compressed_with_options() raises:
    var ctx = _context()
    var d = _dir("gzip")
    var path = d + "/ks.csv.gz"
    _copy(ctx, "COPY (SELECT k, s FROM u ORDER BY k) TO '" + path + "' (DELIMITER ';', HEADER false)", 5)
    var raw = _read(path)
    assert_equal(raw[0], UInt8(0x1F))
    assert_equal(raw[1], UInt8(0x8B))
    var want = String(_KS_SEMICOLON_NO_HEADER)
    assert_equal(
        String(unsafe_from_utf8=Span(Gzip[6].decompress(Span(raw), want.byte_length()))),
        want,
    )


def test_refused_options_touch_no_file() raises:
    var ctx = _context()
    var d = _dir("refused")
    var f = d + "/out.csv"
    var copy = "COPY " + String(_ALL) + " TO '" + f + "' "
    _refusal(
        ctx, copy + "(DATEFORMAT '%Q')", STEP_EXECUTE,
        "CSV_DIALECT_INVALID: COPY ... (DATEFORMAT '%Q'): Failed to parse format specifier %Q: Unrecognized format for strftime/strptime: %Q",
    )
    _refusal(
        ctx, copy + "(TIMESTAMPFORMAT '')", STEP_EXECUTE,
        "CSV_DIALECT_INVALID: COPY ... (TIMESTAMPFORMAT ''): Failed to parse format specifier : Empty format string",
    )
    _refusal(
        ctx, copy + "(TIMESTAMPFORMAT '%H:%M:%S.%n')", STEP_EXECUTE,
        "CSV_DIALECT_UNSUPPORTED: COPY ... (TIMESTAMPFORMAT '%H:%M:%S.%n'): %n, which DuckDB's COPY writes padded with spaces beside another specifier; write %f for the microseconds",
    )
    _refusal(
        ctx, copy + "(DELIMITER '||')", STEP_PARSE,
        "CSV_DIALECT_UNSUPPORTED: COPY ... (DELIMITER '||'): a delimiter of 2 bytes; DuckDB writes only its first byte between the cells, so the delimiter is one byte",
    )
    _refusal(
        ctx, copy + "(DELIMITER '|', QUOTE '|')", STEP_PARSE,
        "CSV_DIALECT_INVALID: COPY ... (DELIMITER '|'): QUOTE must not appear in the DELIMITER specification and vice versa",
    )
    _refusal(
        ctx, copy + "(DELIMITER ';', NULL 'N;A')", STEP_PARSE,
        "CSV_DIALECT_INVALID: COPY ... (NULL 'N;A'): DELIMITER must not appear in the NULL specification and vice versa",
    )
    _refusal(
        ctx, copy + "(FORCE_QUOTE k)", STEP_PARSE,
        "SQL not supported: COPY option 'force_quote' (FORMAT / COMPRESSION / COMPRESSION_LEVEL / HEADER / ARRAY / DELIMITER / QUOTE / ESCAPE / NULL / DATEFORMAT / TIMESTAMPFORMAT)",
    )
    _refusal(
        ctx, copy + "(FORMAT parquet, DELIMITER ';')", STEP_PARSE,
        "SQL not supported: COPY option DELIMITER applies to FORMAT 'csv', not 'parquet'",
    )
    _assert_only(d, List[String]())
    # The same COPY without the refused option writes the file.
    _copy(ctx, copy + "(DELIMITER ';')", 5)
    _assert_only(d, ["out.csv"])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
