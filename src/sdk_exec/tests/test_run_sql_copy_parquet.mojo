# =============================================================================
# run_sql: COPY ... TO a local Parquet file
# =============================================================================
#
# Each test writes into its own directory under test_tmpdir() and lists it
# afterwards, so a temporary file left behind, or a file a refused COPY should
# not have made, fails the test. A file is read back through run_sql (a table
# registered on the file, or the path in FROM) and compared with the query
# that wrote it as canonical text: names, types and every row, in ORDER BY k.
# DuckDB reading the same files is `test_copy_readback_duckdb`.
#
# The table `t` is 50 rows in row groups of 16: k BIGINT NOT NULL 0..49, and
# nullable v DOUBLE, s VARCHAR (NULL and the empty string both occur), b
# BOOLEAN, d DATE (before and after the epoch) and m DECIMAL(12, 2).
#
# What each test proves:
#   * test_a_copied_table_reads_back_equal: `COPY t TO '<dir>/all.parquet'`
#     answers one row, one BIGINT NOT NULL column `Count` holding 50; the file
#     read back equals `SELECT * FROM t`, by table name and by path.
#   * test_a_copied_query_reads_back_equal: the rows, names and types of
#     `COPY (SELECT k, v * 2 AS w, s FROM t WHERE k >= 30)`, and `Count` 20.
#   * test_every_codec_is_the_footers_codec: no option and snappy, uncompressed,
#     zstd, gzip, lz4 and lz4_raw each read back equal, and every column chunk
#     of the footer names the codec asked for (lz4 is LZ4_RAW).
#   * test_an_empty_result_writes_the_schema: `Count` 0, and the file reads
#     back as no rows with every column's name and type.
#   * test_a_result_past_one_row_group: 130,000 rows give `Count` 130000, a
#     footer of two row groups and the same count, min and max read back.
#   * test_a_copy_replaces_the_file_it_reads: a COPY from `'<f>'` to `'<f>'`
#     answers its rows, the next query reads the new file, and the directory
#     holds only it.
#   * test_a_relative_destination_is_the_working_directory: `TO 'rel.parquet'`
#     is written where the process runs.
#   * test_timestamps_and_narrow_integers_read_back: the table `times`
#     (below) copied to Parquet and read back through run_sql: each column
#     keeps its type (TIMESTAMP_US, _MS and _NS, TINYINT, UBIGINT; the zoned
#     column keeps its time zone) and every value and NULL, including the
#     epoch, a tick before it, year 1 BC, each unit's extremes and INT64's
#     largest and its negation; a TIMESTAMP_S column reads back as
#     TIMESTAMP_US holding each second times a million.
#   * test_the_footer_carries_each_unit: the same file's footer gives each
#     timestamp leaf its LogicalType unit (MICROS, MILLIS, NANOS, MICROS for
#     seconds, MICROS), isAdjustedToUTC only on the zoned column, and the
#     ConvertedType TIMESTAMP_MICROS or TIMESTAMP_MILLIS (none for
#     nanoseconds); TINYINT is INT_8 and UBIGINT UINT_64. Catches a unit off
#     by 1000, which no reader can tell from the values alone.
#   * test_refused_copies_touch_no_file: `.txt` at `parse`
#     (COPY_FORMAT_NOT_INFERRED), an `s3://` URL at `bind`
#     (STORAGE_URL_REFUSED), CREATE TABLE AS at `bind`
#     (STATEMENT_NOT_A_QUERY), a TIME column at `execute`
#     (COPY_TYPE_UNSUPPORTED) and a TIMESTAMP_S value whose microseconds do
#     not fit in an INT64 at `execute`, each by exact message, and the
#     directory stays empty.
#   * test_a_missing_directory_and_a_directory_at_the_path: STORAGE_NOT_FOUND
#     and STORAGE_IO (rename, EISDIR) at `execute` by exact message; nothing is
#     created and the directory at the path stays; the context runs on.
#   * test_a_failed_write_leaves_the_old_file: a full disk injected through the
#     file system's test seam gives STORAGE_IO at `execute`, the old file reads
#     back unchanged, no temporary file is left, and the next COPY writes.

from std.ffi import external_call
from std.os import listdir, makedirs
from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.boolean_array import BooleanArray
from arrow.column import Column
from arrow.decimal_array import Decimal128Array
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow.string_array import StringArray
from byte_buffer.byte_view import ByteView
from komira_plan_harness import CanonPolicy, render_batch
from parquet.metadata_parser import parse_full_metadata
from parquet_api.metadata import FileMetaData
from parquet_api.types import CompressionCodec
from parquet_writer.record_batch_writer import write_record_batch_to_parquet_bytes
from runtime_paths import test_tmpdir
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import (
    STATEMENT_NOT_A_QUERY,
    STEP_BIND,
    STEP_EXECUTE,
    STEP_PARSE,
    run_sql,
)
from sdk_exec.engine_write import (
    COPY_COUNT_COLUMN,
    COPY_TYPE_UNSUPPORTED,
    STORAGE_URL_REFUSED,
)
from fs.atomic_write import STORAGE_IO, STORAGE_NOT_FOUND
from sql.sql_copy_format import COPY_FORMAT_NOT_INFERRED

comptime _ROWS = 50

# KOMIRA_FS_INJECT_* in src/fs/_fs_shim.c.
comptime _INJECT_NONE: Int32 = 0
comptime _INJECT_WRITE: Int32 = 2


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/copy_" + name
    makedirs(d, exist_ok=True)
    return d^


def _entries(dir: String) raises -> List[String]:
    var names = listdir(dir)
    sort(names)
    return names^


def _assert_only(dir: String, want: List[String]) raises:
    var got = _entries(dir)
    assert_equal(len(got), len(want), "entries of " + dir)
    for i in range(len(want)):
        assert_equal(got[i], want[i])


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def _table() raises -> RecordBatch:
    var n = _ROWS
    var k = PrimitiveArray[DType.int64].allocate(n)
    var v = PrimitiveArray[DType.float64].allocate_nullable(n)
    var strs = List[String]()
    var valid = List[Bool]()
    var b = BooleanArray.allocate_nullable(n)
    var d = PrimitiveArray[DType.int32].allocate_nullable(n)
    var m = Decimal128Array.allocate_nullable(n, 12, 2)
    for x in range(n):
        k.set(x, Int64(x))
        if x % 7 == 3:
            v._set_null(x)
        else:
            v.set(x, Float64(x) * 0.5 - 3.25)
        strs.append(String("") if x % 9 == 4 else String("s") + String(x % 11))
        valid.append(x % 5 != 1)
        if x % 6 == 0:
            b._set_null(x)
        else:
            b.set(x, x % 4 < 2)
        if x % 8 == 5:
            d._set_null(x)
        else:
            d.set(x, Int32((x - 20) * 37))
        if x % 10 == 7:
            m.set_null(x)
        else:
            m.set_i128(x, Scalar[DType.int64]((x - 25) * 1234 + 7).cast[DType.int128]())
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    sb.add_field(Field("v", ArrowType.FLOAT64, True))
    rb.add_column(Column.from_primitive[DType.float64](v^))
    sb.add_field(Field("s", ArrowType.STRING, True))
    rb.add_column(Column.from_string(StringArray.from_strings_with_validity(strs, valid)))
    sb.add_field(Field("b", ArrowType.BOOL, True))
    rb.add_column(Column.from_boolean(b))
    sb.add_field(Field("d", ArrowType.DATE32, True))
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int32](d^, ArrowType.DATE32)
    )
    sb.add_field(Field.decimal128("m", 12, 2, True))
    rb.add_column(Column.from_decimal128(m^))
    return rb.build(sb.build())


def _keys(n: Int) raises -> RecordBatch:
    var k = PrimitiveArray[DType.int64].allocate(n)
    for x in range(n):
        k.set(x, Int64(x))
    var sb = SchemaBuilder()
    sb.add_field(Field("k", ArrowType.INT64, False))
    var rb = RecordBatchBuilder()
    rb.add_column(Column.from_primitive[DType.int64](k^))
    return rb.build(sb.build())


def _put(path: String, batch: RecordBatch, rows_per_group: Int) raises:
    var bytes = write_record_batch_to_parquet_bytes(batch, max_rows_per_rg=rows_per_group)
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()


# The table `times`, 5 rows, k BIGINT NOT NULL 0..4 and nullable columns,
# all NULL in row 0: us TIMESTAMP_US, ms TIMESTAMP_MS, ns TIMESTAMP_NS,
# s TIMESTAMP_S, utc TIMESTAMP_US with the time zone "UTC", i8 TINYINT and
# u64 UBIGINT. Rows 1..4 hold the epoch, a tick before it, fractions, year 1
# BC, each unit's extremes as DuckDB holds them, and INT64's largest and its
# negation (DuckDB's infinity and -infinity).
comptime _TIMES_ROWS = 5


def _times_column(
    mut sb: SchemaBuilder,
    mut rb: RecordBatchBuilder,
    name: String,
    at: ArrowType,
    tz: String,
    values: List[Int64],
) raises:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(_TIMES_ROWS)
    arr._set_null(0)
    for r in range(1, _TIMES_ROWS):
        arr.set(r, values[r - 1])
    sb.add_field(Field.timestamp(name, at, tz, True))
    rb.add_column(Column.from_primitive_with_arrow_type[DType.int64](arr^, at))


def _times() raises -> RecordBatch:
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    var k = PrimitiveArray[DType.int64].allocate(_TIMES_ROWS)
    for x in range(_TIMES_ROWS):
        k.set(x, Int64(x))
    sb.add_field(Field("k", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](k^))
    _times_column(sb, rb, "us", ArrowType.TIMESTAMP_US, "", [
        0, -62135683200000000, 9223372036854775806, -9223372022400000000,
    ])
    _times_column(sb, rb, "ms", ArrowType.TIMESTAMP_MS, "", [
        -1, 1441369845120, Int64.MAX, -9223372022400000,
    ])
    _times_column(sb, rb, "ns", ArrowType.TIMESTAMP_NS, "", [
        1441369845123456789, -1, -Int64.MAX, 9223286400000000000,
    ])
    _times_column(sb, rb, "s", ArrowType.TIMESTAMP_S, "", [
        -1, 9223372036854, -9223372022400, 0,
    ])
    _times_column(sb, rb, "utc", ArrowType.TIMESTAMP_US, "UTC", [
        1441369845123456, -1, Int64.MAX, -62135683200000000,
    ])
    var i8 = PrimitiveArray[DType.int8].allocate_nullable(_TIMES_ROWS)
    var u64 = PrimitiveArray[DType.uint64].allocate_nullable(_TIMES_ROWS)
    i8._set_null(0)
    u64._set_null(0)
    var i8s: List[Int8] = [-128, 127, 0, -1]
    var u64s: List[UInt64] = [UInt64.MAX, 9223372036854775808, 0, 1]
    for r in range(1, _TIMES_ROWS):
        i8.set(r, i8s[r - 1])
        u64.set(r, u64s[r - 1])
    sb.add_field(Field("i8", ArrowType.INT8, True))
    rb.add_column(Column.from_primitive[DType.int8](i8^))
    sb.add_field(Field("u64", ArrowType.UINT64, True))
    rb.add_column(Column.from_primitive[DType.uint64](u64^))
    return rb.build(sb.build())


def _context_with_t() raises -> EngineContext:
    var ctx = _new_context()
    var path = _dir("input") + "/t.parquet"
    _put(path, _table(), 16)
    register_parquet(ctx, "t", path)
    return ctx^


def _ok(mut ctx: EngineContext, sql: String) raises -> RecordBatch:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason + " -- " + sql,
        )
    assert_equal(len(out.batches), 1)
    return out.batches.pop(0)


def _text(mut ctx: EngineContext, sql: String) raises -> String:
    return render_batch(_ok(ctx, sql), CanonPolicy()).to_text()


def _copy(mut ctx: EngineContext, sql: String, rows: Int) raises:
    """Run the COPY `sql` and check its answer: one row, one BIGINT NOT NULL
    column `Count` holding `rows`."""
    var batch = _ok(ctx, sql)
    assert_equal(batch.num_rows(), 1)
    assert_equal(batch.num_columns(), 1)
    assert_equal(batch.schema.field_name(0), String(COPY_COUNT_COLUMN))
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_true(not batch.schema.field_nullable(0))
    assert_equal(Int(batch.column_at(0).as_primitive[DType.int64]().get(0)), rows)


def _refusal(mut ctx: EngineContext, sql: String, step: String, reason: String) raises:
    var out = run_sql(ctx, sql)
    assert_true(Bool(out.refusal), "not refused: " + sql)
    assert_equal(out.refusal.value().step, step, sql)
    assert_equal(out.refusal.value().reason, reason, sql)


def _footer(path: String) raises -> FileMetaData:
    var fh = open(path, "r")
    var bytes = fh.read_bytes()
    fh.close()
    var n = len(bytes)
    var flen = (
        Int(bytes[n - 8])
        | (Int(bytes[n - 7]) << 8)
        | (Int(bytes[n - 6]) << 16)
        | (Int(bytes[n - 5]) << 24)
    )
    # SAFETY: the view covers the `flen` footer bytes inside `bytes`, which
    # outlives the parse; the parser copies what it keeps.
    var view = ByteView(bytes.unsafe_ptr() + (n - 8 - flen), flen)
    return parse_full_metadata(view)


def test_a_copied_table_reads_back_equal() raises:
    var ctx = _context_with_t()
    var d = _dir("table")
    _copy(ctx, "COPY t TO '" + d + "/all.parquet'", _ROWS)
    _assert_only(d, ["all.parquet"])
    register_parquet(ctx, "back", d + "/all.parquet")
    var want = _text(ctx, "SELECT * FROM t ORDER BY k")
    assert_equal(_text(ctx, "SELECT * FROM back ORDER BY k"), want)
    assert_equal(_text(ctx, "SELECT * FROM '" + d + "/all.parquet' ORDER BY k"), want)


def test_a_copied_query_reads_back_equal() raises:
    var ctx = _context_with_t()
    var d = _dir("query")
    var q = String("SELECT k, v * 2 AS w, s FROM t WHERE k >= 30")
    _copy(ctx, "COPY (" + q + ") TO '" + d + "/q.parquet'", 20)
    assert_equal(
        _text(ctx, "SELECT * FROM '" + d + "/q.parquet' ORDER BY k"),
        _text(ctx, q + " ORDER BY k"),
    )
    _assert_only(d, ["q.parquet"])


def test_every_codec_is_the_footers_codec() raises:
    var ctx = _context_with_t()
    var d = _dir("codecs")
    var options: List[String] = [
        "", "(COMPRESSION snappy)", "(FORMAT parquet, COMPRESSION uncompressed)",
        "(COMPRESSION zstd)", "(COMPRESSION gzip)", "(COMPRESSION lz4)",
        "(COMPRESSION lz4_raw)",
    ]
    var codecs: List[CompressionCodec] = [
        CompressionCodec.SNAPPY, CompressionCodec.SNAPPY,
        CompressionCodec.UNCOMPRESSED, CompressionCodec.ZSTD,
        CompressionCodec.GZIP, CompressionCodec.LZ4_RAW, CompressionCodec.LZ4_RAW,
    ]
    var want = _text(ctx, "SELECT * FROM t ORDER BY k")
    for i in range(len(options)):
        var path = d + "/c" + String(i) + ".parquet"
        _copy(ctx, "COPY t TO '" + path + "' " + options[i], _ROWS)
        assert_equal(_text(ctx, "SELECT * FROM '" + path + "' ORDER BY k"), want, options[i])
        var meta = _footer(path)
        assert_true(len(meta.row_groups) >= 1)
        for rg in range(len(meta.row_groups)):
            for c in range(len(meta.row_groups[rg].columns)):
                assert_true(
                    meta.row_groups[rg].columns[c].meta_data.codec == codecs[i],
                    options[i] + ": codec of column " + String(c),
                )


def test_an_empty_result_writes_the_schema() raises:
    var ctx = _context_with_t()
    var d = _dir("empty")
    var q = String("SELECT * FROM t WHERE k < 0")
    _copy(ctx, "COPY (" + q + ") TO '" + d + "/none.parquet'", 0)
    var back = _ok(ctx, "SELECT * FROM '" + d + "/none.parquet'")
    assert_equal(back.num_rows(), 0)
    assert_equal(render_batch(back, CanonPolicy()).to_text(), _text(ctx, q))
    _assert_only(d, ["none.parquet"])


def test_a_result_past_one_row_group() raises:
    var ctx = _new_context()
    var d = _dir("big")
    var src = d + "/src.parquet"
    _put(src, _keys(130_000), 50_000)
    _copy(ctx, "COPY (SELECT k FROM '" + src + "') TO '" + d + "/big.parquet'", 130_000)
    assert_equal(len(_footer(d + "/big.parquet").row_groups), 2)
    var q = String(" SELECT count(*) AS n, min(k) AS lo, max(k) AS hi FROM '")
    assert_equal(_text(ctx, q + d + "/big.parquet'"), _text(ctx, q + src + "'"))
    _assert_only(d, ["big.parquet", "src.parquet"])


def test_a_copy_replaces_the_file_it_reads() raises:
    var ctx = _new_context()
    var d = _dir("self")
    var f = d + "/self.parquet"
    _put(f, _keys(50), 16)
    _copy(ctx, "COPY (SELECT k FROM '" + f + "' WHERE k < 10) TO '" + f + "'", 10)
    var back = _ok(ctx, "SELECT count(*) AS n, max(k) AS hi FROM '" + f + "'")
    assert_equal(Int(back.column_at(0).as_primitive[DType.int64]().get(0)), 10)
    assert_equal(Int(back.column_at(1).as_primitive[DType.int64]().get(0)), 9)
    _assert_only(d, ["self.parquet"])


def test_a_relative_destination_is_the_working_directory() raises:
    var ctx = _context_with_t()
    var d = _dir("relative")
    var c = d.copy()
    # SAFETY: `c` is a local that outlives the call; chdir copies the path.
    assert_equal(external_call["chdir", Int32](c.as_c_string_slice().unsafe_ptr()), 0)
    var out = run_sql(ctx, "COPY t TO 'rel.parquet'")
    var back = test_tmpdir()
    # SAFETY: as above.
    assert_equal(external_call["chdir", Int32](back.as_c_string_slice().unsafe_ptr()), 0)
    assert_true(not out.refusal)
    _assert_only(d, ["rel.parquet"])
    assert_equal(
        _text(ctx, "SELECT * FROM '" + d + "/rel.parquet' ORDER BY k"),
        _text(ctx, "SELECT * FROM t ORDER BY k"),
    )


def test_refused_copies_touch_no_file() raises:
    var ctx = _context_with_t()
    var d = _dir("refused")
    var txt = d + "/out.txt"
    _refusal(
        ctx, "COPY t TO '" + txt + "'", String(STEP_PARSE),
        String(COPY_FORMAT_NOT_INFERRED) + ": COPY ... TO '" + txt
        + "' has no FORMAT, and its extension is not .parquet, .csv, .json,"
        " .jsonl or .ndjson; add (FORMAT parquet), (FORMAT csv) or"
        " (FORMAT json)",
    )
    _refusal(
        ctx, "COPY t TO 's3://bucket/out.parquet'", String(STEP_BIND),
        String(STORAGE_URL_REFUSED)
        + ": COPY ... TO 's3://bucket/out.parquet': only a local file path is written",
    )
    _refusal(
        ctx, "CREATE TABLE c AS SELECT k FROM t", String(STEP_BIND),
        String(STATEMENT_NOT_A_QUERY)
        + ": CREATE TABLE AS writes into a catalog table, and no catalog is"
        " bound; write COPY (<query>) TO '<file>.parquet' to write a file",
    )
    var tm = PrimitiveArray[DType.int64].allocate(2)
    tm.set(0, 0)
    tm.set(1, 45_045_000_000)
    var sb = SchemaBuilder()
    sb.add_field(Field("tm", ArrowType.TIME64_US, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](tm^, ArrowType.TIME64_US)
    )
    ctx.catalog.add_in_memory("clock", rb.build(sb.build()))
    var tmp = d + "/tm.parquet"
    _refusal(
        ctx, "COPY clock TO '" + tmp + "'", String(STEP_EXECUTE),
        String(COPY_TYPE_UNSUPPORTED) + ": COPY ... TO '" + tmp
        + "': column 'tm' has type " + String(ArrowType.TIME64_US)
        + ", which is not written to Parquet yet",
    )
    var big = Int64.MAX // 1_000_000 + 1
    var secs = PrimitiveArray[DType.int64].from_list([Int64(0), big])
    var ssb = SchemaBuilder()
    ssb.add_field(Field("at", ArrowType.TIMESTAMP_S, False))
    var srb = RecordBatchBuilder()
    srb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](secs^, ArrowType.TIMESTAMP_S)
    )
    ctx.catalog.add_in_memory("far", srb.build(ssb.build()))
    var farp = d + "/far.parquet"
    _refusal(
        ctx, "COPY far TO '" + farp + "'", String(STEP_EXECUTE),
        String("parquet writer: column 'at' row 1 holds the TIMESTAMP_S value ")
        + String(big) + ", whose microseconds do not fit in an INT64 (a Parquet"
        " timestamp has no seconds unit, so seconds are written as"
        " microseconds)",
    )
    _assert_only(d, List[String]())
    _copy(ctx, "COPY t TO '" + d + "/after.parquet'", _ROWS)


def _times_file(mut ctx: EngineContext, name: String) raises -> String:
    """COPY the table `times` to `<dir name>/times.parquet` and return the
    file's path."""
    ctx.catalog.add_in_memory("times", _times())
    var d = _dir(name)
    var f = d + "/times.parquet"
    _copy(ctx, "COPY times TO '" + f + "'", _TIMES_ROWS)
    _assert_only(d, ["times.parquet"])
    return f^


def test_timestamps_and_narrow_integers_read_back() raises:
    var ctx = _new_context()
    var f = _times_file(ctx, "times")
    var back = _ok(ctx, "SELECT * FROM '" + f + "' ORDER BY k")
    var want = _times()
    assert_equal(back.num_rows(), _TIMES_ROWS)
    assert_equal(back.num_columns(), want.num_columns())
    var types: List[ArrowType] = [
        ArrowType.INT64, ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_MS,
        ArrowType.TIMESTAMP_NS, ArrowType.TIMESTAMP_US, ArrowType.TIMESTAMP_US,
        ArrowType.INT8, ArrowType.UINT64,
    ]
    for c in range(back.num_columns()):
        var w = back.schema.field_name(c)
        assert_equal(w, want.schema.field_name(c))
        assert_true(back.schema.field_arrow_type(c) == types[c], w)
        assert_equal(back.schema.field_tz(c), String("UTC") if w == "utc" else String(""), w)
    for c in range(1, 6):
        var w = back.schema.field_name(c)
        var got = back.column_at(c).as_primitive[DType.int64]()
        var put = want.column_at(c).as_primitive[DType.int64]()
        assert_true(got.is_null(0), w)
        for r in range(1, _TIMES_ROWS):
            var scale = Int64(1_000_000) if w == "s" else Int64(1)
            assert_equal(got.get(r), put.get(r) * scale, w + " row " + String(r))
    var i8 = back.column_at(6).as_primitive[DType.int8]()
    var u64 = back.column_at(7).as_primitive[DType.uint64]()
    var i8_put = want.column_at(6).as_primitive[DType.int8]()
    var u64_put = want.column_at(7).as_primitive[DType.uint64]()
    assert_true(i8.is_null(0))
    assert_true(u64.is_null(0))
    for r in range(1, _TIMES_ROWS):
        assert_equal(i8.get(r), i8_put.get(r), "i8 row " + String(r))
        assert_equal(u64.get(r), u64_put.get(r), "u64 row " + String(r))


def test_the_footer_carries_each_unit() raises:
    var ctx = _new_context()
    var meta = _footer(_times_file(ctx, "footer"))
    # Leaf c + 1 is column c: k, us, ms, ns, s, utc, i8, u64.
    var units: List[Int] = [2, 1, 3, 2, 2]
    var converted: List[Int] = [10, 9, -1, 10, 10]
    for c in range(1, 6):
        ref leaf = meta.schema[c + 1]
        assert_equal(leaf.logical_timestamp_unit.value(), units[c - 1], leaf.name)
        assert_equal(leaf.logical_timestamp_is_utc.value(), leaf.name == "utc", leaf.name)
        if converted[c - 1] < 0:
            assert_true(not leaf.converted_type, leaf.name)
        else:
            assert_equal(leaf.converted_type.value(), converted[c - 1], leaf.name)
    assert_true(not meta.schema[1].logical_timestamp_unit)
    assert_equal(meta.schema[7].converted_type.value(), 15)
    assert_equal(meta.schema[8].converted_type.value(), 14)


def test_a_missing_directory_and_a_directory_at_the_path() raises:
    var ctx = _context_with_t()
    var d = _dir("paths")
    var missing = d + "/no_such_dir/out.parquet"
    _refusal(
        ctx, "COPY t TO '" + missing + "'", String(STEP_EXECUTE),
        String(STORAGE_NOT_FOUND) + ": write '" + missing + "': the directory '"
        + d + "/no_such_dir' does not exist",
    )
    var at_dir = d + "/taken.parquet"
    makedirs(at_dir, exist_ok=True)
    _refusal(
        ctx, "COPY t TO '" + at_dir + "'", String(STEP_EXECUTE),
        String(STORAGE_IO) + ": write '" + at_dir + "': rename failed: errno 21 (EISDIR)",
    )
    _assert_only(d, ["taken.parquet"])
    _assert_only(at_dir, List[String]())
    _copy(ctx, "COPY t TO '" + d + "/fine.parquet'", _ROWS)


def test_a_failed_write_leaves_the_old_file() raises:
    var ctx = _context_with_t()
    var d = _dir("full")
    var f = d + "/out.parquet"
    _copy(ctx, "COPY (SELECT * FROM t WHERE k < 10) TO '" + f + "'", 10)
    var old = _text(ctx, "SELECT * FROM '" + f + "' ORDER BY k")
    external_call["komira_fs_test_inject_write_failure", NoneType](_INJECT_WRITE)
    var out = run_sql(ctx, "COPY t TO '" + f + "'")
    external_call["komira_fs_test_inject_write_failure", NoneType](_INJECT_NONE)
    assert_true(Bool(out.refusal))
    assert_equal(out.refusal.value().step, String(STEP_EXECUTE))
    assert_equal(
        out.refusal.value().reason,
        String(STORAGE_IO) + ": write '" + f + "': write failed: errno 28 (ENOSPC)",
    )
    assert_equal(_text(ctx, "SELECT * FROM '" + f + "' ORDER BY k"), old)
    _assert_only(d, ["out.parquet"])
    _copy(ctx, "COPY t TO '" + f + "'", _ROWS)
    assert_equal(
        _text(ctx, "SELECT * FROM '" + f + "' ORDER BY k"),
        _text(ctx, "SELECT * FROM t ORDER BY k"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
