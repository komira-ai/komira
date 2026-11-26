# =============================================================================
# run_sql: COPY ... TO a local CSV or newline-delimited JSON file
# =============================================================================
#
# Covers: COPY ... TO a local CSV or newline-delimited JSON file through
# run_sql writes the bytes DuckDB writes for a table of BIGINT, DOUBLE,
# VARCHAR, BOOLEAN, DATE and DECIMAL columns with NULLs (the empty string,
# quoting) and for a filtered query; the format from .csv, .json, .ndjson,
# .jsonl or FORMAT; gzip and zstd from the extension or COMPRESSION; an empty
# result as DuckDB writes it; lz4, a TIMESTAMP column and two columns of one
# name are refused by name with no file made; a full disk and a missing
# directory leave the old file and no temporary file.
#
# Each test writes into its own directory under test_tmpdir() and lists it
# afterwards, so a temporary file left behind, or a file a refused COPY should
# not have made, fails the test. Each file is read back as bytes and compared
# with the exact text DuckDB's COPY writes for the same rows
# (`engine_write_text` says how each value is written;
# `test_copy_text_encoding` holds every rule, `test_copy_readback_duckdb` has
# the pinned DuckDB read komira's files).
#
# The table `t` is a Parquet file of 4 rows: k BIGINT NOT NULL 0..3, and
# nullable v DOUBLE, s VARCHAR (a comma, the empty string, NULL and quotes),
# b BOOLEAN, d DATE (before and after the epoch) and m DECIMAL(12, 2), each
# NULL in one row.
#
# What each test proves:
#   * test_a_table_as_csv_and_json: `COPY (SELECT * FROM t ORDER BY k)` to
#     `.csv` and `.json` answers `Count` 4 and writes DuckDB's bytes; `.ndjson`
#     and `.jsonl` are JSON; FORMAT csv and FORMAT json write those bytes to a
#     destination whose extension names no format. Catches a format taken
#     from the wrong place and any cell, separator or line end that differs.
#   * test_a_filtered_query: a WHERE and a projection: only the rows and
#     columns the query answers, `Count` 2. Catches a selection mask ignored.
#   * test_compression_from_the_destination_and_the_option: `.csv.gz` and
#     `.json.gz` are gzip, `.csv.zst` and `.json.zst` zstd, each
#     decompressing to the uncompressed file's bytes; COMPRESSION gzip on a
#     `.csv` destination is gzip and COMPRESSION none on a `.csv.gz` one is
#     plain text.
#   * test_an_empty_result: `Count` 0; the CSV file is the header row and the
#     JSON file is empty, as DuckDB writes them.
#   * test_refused_text_copies_touch_no_file: COMPRESSION lz4 for CSV and for
#     JSON at `bind` (COPY_COMPRESSION_UNSUPPORTED), a TIMESTAMP column to CSV
#     and to JSON at `execute` (COPY_TYPE_UNSUPPORTED) and two columns of one
#     name at `execute` (COPY_DUPLICATE_COLUMN), each by exact message; the
#     directory stays empty and the next COPY writes.
#   * test_a_failed_write_leaves_the_old_file: a full disk injected through
#     the file system's test seam gives STORAGE_IO at `execute`, the old CSV
#     file keeps its bytes, no temporary file is left, and the next COPY
#     writes; a missing directory is STORAGE_NOT_FOUND and creates nothing.

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
from compression.compression_codecs import Gzip
from compression.zstd_frame import zstd_decompress_into
from fs.atomic_write import STORAGE_IO, STORAGE_NOT_FOUND
from parquet_writer.record_batch_writer import write_record_batch_to_parquet_bytes
from runtime_paths import test_tmpdir
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_EXECUTE, run_sql
from sdk_exec.engine_write import (
    COPY_COMPRESSION_UNSUPPORTED,
    COPY_COUNT_COLUMN,
    COPY_DUPLICATE_COLUMN,
    COPY_TYPE_UNSUPPORTED,
)

# KOMIRA_FS_INJECT_* in src/fs/_fs_shim.c.
comptime _INJECT_NONE: Int32 = 0
comptime _INJECT_WRITE: Int32 = 2

comptime _CSV = (
    "k,v,s,b,d,m\n"
    '0,3.0,"x,y",true,1970-01-01,12.50\n'
    '1,,"",,1969-12-31,-0.05\n'
    "2,1e+16,,false,,0.00\n"
    '3,-0.5,"say ""hi""",true,2022-01-08,\n'
)

comptime _JSON = (
    '{"k":0,"v":3.0,"s":"x,y","b":true,"d":"1970-01-01","m":12.5}\n'
    '{"k":1,"v":null,"s":"","b":null,"d":"1969-12-31","m":-0.05}\n'
    '{"k":2,"v":10000000000000000.0,"s":null,"b":false,"d":null,"m":0.0}\n'
    '{"k":3,"v":-0.5,"s":"say \\"hi\\"","b":true,"d":"2022-01-08","m":null}\n'
)

comptime _ALL = "(SELECT * FROM t ORDER BY k)"


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/copy_text_" + name
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


def _gunzip(path: String, size: Int) raises -> String:
    var raw = _read(path)
    assert_equal(raw[0], UInt8(0x1F), path)
    assert_equal(raw[1], UInt8(0x8B), path)
    return String(unsafe_from_utf8=Span(Gzip[6].decompress(Span(raw), size)))


def _unzstd(path: String, size: Int) raises -> String:
    var raw = _read(path)
    assert_equal(raw[0], UInt8(0x28), path)
    assert_equal(raw[3], UInt8(0xFD), path)
    var out = List[UInt8](capacity=size + 1)
    out.resize(size + 1, UInt8(0))
    var n = zstd_decompress_into(Span(out), Span(raw))
    out.resize(n, UInt8(0))
    return String(unsafe_from_utf8=Span(out))


def _table() raises -> RecordBatch:
    var k = PrimitiveArray[DType.int64].allocate(4)
    var v = PrimitiveArray[DType.float64].allocate_nullable(4)
    var b = BooleanArray.allocate_nullable(4)
    var d = PrimitiveArray[DType.int32].allocate_nullable(4)
    var m = Decimal128Array.allocate_nullable(4, 12, 2)
    for x in range(4):
        k.set(x, Int64(x))
    v.set(0, 3.0)
    v._set_null(1)
    v.set(2, 1e16)
    v.set(3, -0.5)
    var strs = List[String]()
    strs.append("x,y")
    strs.append("")
    strs.append("")
    strs.append('say "hi"')
    var valid = List[Bool]()
    valid.append(True)
    valid.append(True)
    valid.append(False)
    valid.append(True)
    b.set(0, True)
    b._set_null(1)
    b.set(2, False)
    b.set(3, True)
    d.set(0, 0)
    d.set(1, -1)
    d._set_null(2)
    d.set(3, 19000)
    m.set_i128(0, Scalar[DType.int128](1250))
    m.set_i128(1, Scalar[DType.int128](-5))
    m.set_i128(2, Scalar[DType.int128](0))
    m.set_null(3)
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


def _context_with_t() raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var path = _dir("input") + "/t.parquet"
    var bytes = write_record_batch_to_parquet_bytes(_table())
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    register_parquet(ctx, "t", path)
    return ctx^


def _copy(mut ctx: EngineContext, sql: String, rows: Int) raises:
    """Run the COPY `sql` and check its answer: one row, one BIGINT NOT NULL
    column `Count` holding `rows`."""
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason + " -- " + sql,
        )
    assert_equal(len(out.batches), 1)
    ref batch = out.batches[0]
    assert_equal(batch.num_rows(), 1)
    assert_equal(batch.schema.field_name(0), String(COPY_COUNT_COLUMN))
    assert_true(batch.schema.field_arrow_type(0) == ArrowType.INT64)
    assert_equal(Int(batch.column_at(0).as_primitive[DType.int64]().get(0)), rows)


def _refusal(mut ctx: EngineContext, sql: String, step: String, reason: String) raises:
    var out = run_sql(ctx, sql)
    assert_true(Bool(out.refusal), "not refused: " + sql)
    assert_equal(out.refusal.value().step, step, sql)
    assert_equal(out.refusal.value().reason, reason, sql)


def test_a_table_as_csv_and_json() raises:
    var ctx = _context_with_t()
    var d = _dir("table")
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/t.csv'", 4)
    assert_equal(_text(d + "/t.csv"), String(_CSV))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/t.json'", 4)
    assert_equal(_text(d + "/t.json"), String(_JSON))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/t.ndjson'", 4)
    assert_equal(_text(d + "/t.ndjson"), String(_JSON))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/t.jsonl'", 4)
    assert_equal(_text(d + "/t.jsonl"), String(_JSON))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/csv.txt' (FORMAT csv)", 4)
    assert_equal(_text(d + "/csv.txt"), String(_CSV))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/json.parquet' (FORMAT json)", 4)
    assert_equal(_text(d + "/json.parquet"), String(_JSON))
    _assert_only(d, ["csv.txt", "json.parquet", "t.csv", "t.json", "t.jsonl", "t.ndjson"])


def test_a_filtered_query() raises:
    var ctx = _context_with_t()
    var d = _dir("filtered")
    _copy(ctx, "COPY (SELECT k, s FROM t WHERE k >= 2 ORDER BY k) TO '" + d + "/f.csv'", 2)
    assert_equal(_text(d + "/f.csv"), String('k,s\n2,\n3,"say ""hi"""\n'))
    _copy(ctx, "COPY (SELECT k, s FROM t WHERE k >= 2 ORDER BY k) TO '" + d + "/f.json'", 2)
    assert_equal(
        _text(d + "/f.json"),
        String('{"k":2,"s":null}\n{"k":3,"s":"say \\"hi\\""}\n'),
    )


def test_compression_from_the_destination_and_the_option() raises:
    var ctx = _context_with_t()
    var d = _dir("compressed")
    var csv_len = String(_CSV).byte_length()
    var json_len = String(_JSON).byte_length()
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/t.csv.gz'", 4)
    assert_equal(_gunzip(d + "/t.csv.gz", csv_len), String(_CSV))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/t.json.gz'", 4)
    assert_equal(_gunzip(d + "/t.json.gz", json_len), String(_JSON))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/t.csv.zst'", 4)
    assert_equal(_unzstd(d + "/t.csv.zst", csv_len), String(_CSV))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/t.json.zst'", 4)
    assert_equal(_unzstd(d + "/t.json.zst", json_len), String(_JSON))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/named.csv' (COMPRESSION gzip)", 4)
    assert_equal(_gunzip(d + "/named.csv", csv_len), String(_CSV))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/plain.csv.gz' (COMPRESSION none)", 4)
    assert_equal(_text(d + "/plain.csv.gz"), String(_CSV))
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/z.json' (FORMAT json, COMPRESSION zstd)", 4)
    assert_equal(_unzstd(d + "/z.json", json_len), String(_JSON))


def test_an_empty_result() raises:
    var ctx = _context_with_t()
    var d = _dir("empty")
    _copy(ctx, "COPY (SELECT * FROM t WHERE k < 0) TO '" + d + "/e.csv'", 0)
    assert_equal(_text(d + "/e.csv"), String("k,v,s,b,d,m\n"))
    _copy(ctx, "COPY (SELECT * FROM t WHERE k < 0) TO '" + d + "/e.json'", 0)
    assert_equal(len(_read(d + "/e.json")), 0)
    _assert_only(d, ["e.csv", "e.json"])


def test_refused_text_copies_touch_no_file() raises:
    var ctx = _context_with_t()
    var d = _dir("refused")
    var lz = d + "/out.csv.lz4"
    _refusal(
        ctx, "COPY t TO '" + lz + "' (FORMAT csv, COMPRESSION lz4)", String(STEP_BIND),
        String(COPY_COMPRESSION_UNSUPPORTED) + ": COPY ... TO '" + lz
        + "' (FORMAT csv, COMPRESSION lz4): CSV and JSON are written"
        " uncompressed, with gzip or with zstd",
    )
    var jlz = d + "/out.json"
    _refusal(
        ctx, "COPY t TO '" + jlz + "' (COMPRESSION lz4)", String(STEP_BIND),
        String(COPY_COMPRESSION_UNSUPPORTED) + ": COPY ... TO '" + jlz
        + "' (FORMAT json, COMPRESSION lz4): CSV and JSON are written"
        " uncompressed, with gzip or with zstd",
    )
    var ts = PrimitiveArray[DType.int64].allocate(2)
    ts.set(0, 0)
    ts.set(1, 86_400_000_000)
    var sb = SchemaBuilder()
    sb.add_field(Field("ts", ArrowType.TIMESTAMP_US, False))
    var rb = RecordBatchBuilder()
    rb.add_column(
        Column.from_primitive_with_arrow_type[DType.int64](ts^, ArrowType.TIMESTAMP_US)
    )
    ctx.catalog.add_in_memory("times", rb.build(sb.build()))
    var tc = d + "/ts.csv"
    _refusal(
        ctx, "COPY times TO '" + tc + "'", String(STEP_EXECUTE),
        String(COPY_TYPE_UNSUPPORTED) + ": COPY ... TO '" + tc
        + "': column 'ts' has type " + String(ArrowType.TIMESTAMP_US)
        + ", which is not written to CSV yet",
    )
    var tj = d + "/ts.json"
    _refusal(
        ctx, "COPY times TO '" + tj + "'", String(STEP_EXECUTE),
        String(COPY_TYPE_UNSUPPORTED) + ": COPY ... TO '" + tj
        + "': column 'ts' has type " + String(ArrowType.TIMESTAMP_US)
        + ", which is not written to JSON yet",
    )
    var dup = d + "/dup.json"
    _refusal(
        ctx, "COPY (SELECT k, s, k FROM t) TO '" + dup + "'", String(STEP_EXECUTE),
        String(COPY_DUPLICATE_COLUMN) + ": COPY ... TO '" + dup
        + "': the result has two columns named 'k'; give each column of a"
        " JSON file its own name (AS)",
    )
    _assert_only(d, List[String]())
    _copy(ctx, "COPY " + _ALL + " TO '" + d + "/after.csv'", 4)
    assert_equal(_text(d + "/after.csv"), String(_CSV))


def test_a_failed_write_leaves_the_old_file() raises:
    var ctx = _context_with_t()
    var d = _dir("full")
    var f = d + "/out.csv"
    _copy(ctx, "COPY (SELECT k FROM t ORDER BY k) TO '" + f + "'", 4)
    external_call["komira_fs_test_inject_write_failure", NoneType](_INJECT_WRITE)
    var out = run_sql(ctx, "COPY " + _ALL + " TO '" + f + "'")
    external_call["komira_fs_test_inject_write_failure", NoneType](_INJECT_NONE)
    assert_true(Bool(out.refusal))
    assert_equal(out.refusal.value().step, String(STEP_EXECUTE))
    assert_equal(
        out.refusal.value().reason,
        String(STORAGE_IO) + ": write '" + f + "': write failed: errno 28 (ENOSPC)",
    )
    assert_equal(_text(f), String("k\n0\n1\n2\n3\n"))
    _assert_only(d, ["out.csv"])
    _copy(ctx, "COPY " + _ALL + " TO '" + f + "'", 4)
    assert_equal(_text(f), String(_CSV))
    var missing = d + "/no_such_dir/out.json"
    _refusal(
        ctx, "COPY t TO '" + missing + "'", String(STEP_EXECUTE),
        String(STORAGE_NOT_FOUND) + ": write '" + missing + "': the directory '"
        + d + "/no_such_dir' does not exist",
    )
    _assert_only(d, ["out.csv"])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
