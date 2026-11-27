# =============================================================================
# run_sql: COPY (query) TO '<dir>' (..., PARTITION_BY (<columns>))
# =============================================================================
#
# Each test writes its own input CSV (sales.csv: id, amount, year, month,
# region; five rows over three (year, month) pairs and two regions) under the
# test's scratch directory and copies from read_csv over it.
#
# What each test proves:
#   * test_year_and_month_make_the_tree_duckdb_writes: PARTITION_BY
#     (year, month) writes `year=<y>/month=<m>/data_0.parquet` for each pair,
#     as the pinned DuckDB names them; `Count` is every row; the tree read
#     back with `hive_partitioning = true` holds the rows and values of the
#     query, and one file read alone holds only the columns that are not
#     partition columns. Catches a level missing or out of order, a file name
#     other than DuckDB's, and a row lost or put in the wrong directory.
#   * test_one_column_to_gzip_csv: a bare `PARTITION_BY region` to a target
#     written with a trailing `/` writes `region=<r>/data_0.csv.gz`.
#   * test_escaped_null_and_empty_values: a value with `/`, one with a space
#     and a multi-byte character are URL-escaped, the empty string is the
#     directory `k=` and NULL is `k=__HIVE_DEFAULT_PARTITION__`; komira reads
#     an escaped directory back as its value; the tree with a NULL directory
#     is refused by komira's reader, which does not read a NULL partition yet.
#   * test_an_empty_result_makes_an_empty_directory: no row makes the target
#     directory and nothing in it, and answers 0.
#   * test_refusals_touch_nothing: a target directory holding a file, a
#     target that is a file, a missing parent directory and a URL target are
#     refused at bind; a PARTITION_BY column the result does not have, or
#     that covers every column, at bind; a FLOAT partition column at execute;
#     FORMAT json at parse; each with its whole message, and no file or
#     directory is made or changed.

from std.os import listdir, makedirs
from std.os.path import exists, isdir
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from komira_plan_harness import CanonPolicy, render_batch
from runtime_paths import test_tmpdir
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_EXECUTE, STEP_PARSE, run_sql
from sdk_exec.engine_write import COPY_TYPE_UNSUPPORTED, STORAGE_URL_REFUSED
from sdk_exec.engine_write_partitioned import COPY_TARGET_EXISTS
from fs.atomic_write import STORAGE_NOT_FOUND

comptime _SALES = (
    "id,amount,year,month,region\n"
    "1,120,2027,1,east\n"
    "2,40,2027,2,west\n"
    "3,75,2028,1,east\n"
    "4,200,2027,1,west\n"
    "5,10,2028,1,east\n"
)


def _dir(name: String) raises -> String:
    var d = test_tmpdir() + "/copy_partitioned_" + name
    makedirs(d, exist_ok=True)
    with open(d + "/sales.csv", "w") as f:
        f.write(_SALES)
    return d^


def _sales(d: String) -> String:
    return "read_csv('" + d + "/sales.csv')"


def _tree(root: String, prefix: String, mut out: List[String]) raises:
    var names = listdir(root)
    for i in range(len(names)):
        var path = root + "/" + names[i]
        if isdir(path):
            _tree(path, prefix + names[i] + "/", out)
        else:
            out.append(prefix + names[i])


def _files(root: String) raises -> String:
    """Every file under `root`, relative to it, sorted, one per line."""
    var out = List[String]()
    _tree(root, String(""), out)
    sort(out)
    var s = String("")
    for i in range(len(out)):
        s += out[i] + "\n"
    return s^


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


def _rows(mut ctx: EngineContext, sql: String) raises -> String:
    """The rows of `sql`'s answer in the canonical text, one per line, without
    the schema line: a partition column read back is NOT NULL where the
    query's column is nullable, and only the values are compared here."""
    var text = render_batch(_ok(ctx, sql), CanonPolicy())
    var out = String("")
    for r in range(text.num_rows()):
        out += text.row_text(r) + "\n"
    return out^


def _count(mut ctx: EngineContext, sql: String) raises -> Int:
    var batch = _ok(ctx, sql)
    assert_equal(batch.num_rows(), 1)
    assert_equal(batch.schema.field_name(0), "Count")
    return Int(batch.column_at(0).as_primitive[DType.int64]().get(0))


def _refusal(mut ctx: EngineContext, sql: String, step: String, reason: String) raises:
    var out = run_sql(ctx, sql)
    assert_true(Bool(out.refusal), "not refused: " + sql)
    assert_equal(out.refusal.value().step, step, sql)
    assert_equal(out.refusal.value().reason, reason, sql)


def _context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def test_year_and_month_make_the_tree_duckdb_writes() raises:
    var ctx = _context()
    var d = _dir("tree")
    var out = d + "/out"
    assert_equal(
        _count(
            ctx,
            "COPY (SELECT id, amount, year, month FROM " + _sales(d) + ") TO '"
            + out + "' (FORMAT parquet, PARTITION_BY (year, month))",
        ),
        5,
    )
    assert_equal(
        _files(out),
        "year=2027/month=1/data_0.parquet\n"
        "year=2027/month=2/data_0.parquet\n"
        "year=2028/month=1/data_0.parquet\n",
    )
    assert_equal(
        _rows(
            ctx,
            "SELECT id, amount, year, month FROM read_parquet('" + out
            + "/**/*.parquet', hive_partitioning = true) ORDER BY id",
        ),
        _rows(ctx, "SELECT id, amount, year, month FROM " + _sales(d) + " ORDER BY id"),
    )
    var back = _ok(
        ctx,
        "SELECT * FROM read_parquet('" + out + "/**/*.parquet', hive_partitioning = true)",
    )
    assert_equal(back.num_columns(), 4)
    assert_equal(back.schema.field_name(2), "month")
    assert_equal(back.schema.field_name(3), "year")
    assert_true(back.schema.field_arrow_type(3) == ArrowType.INT64)
    assert_equal(
        _rows(
            ctx,
            "SELECT * FROM read_parquet('" + out
            + "/year=2027/month=1/data_0.parquet', hive_partitioning = false)"
            " ORDER BY id",
        ),
        _rows(
            ctx,
            "SELECT id, amount FROM " + _sales(d)
            + " WHERE year = 2027 AND month = 1 ORDER BY id",
        ),
    )


def test_one_column_to_gzip_csv() raises:
    var ctx = _context()
    var d = _dir("csv")
    assert_equal(
        _count(
            ctx,
            "COPY (SELECT id, region FROM " + _sales(d) + " ORDER BY id) TO '" + d
            + "/out/' (FORMAT csv, COMPRESSION gzip, PARTITION_BY region)",
        ),
        5,
    )
    assert_equal(
        _files(d + "/out"), "region=east/data_0.csv.gz\nregion=west/data_0.csv.gz\n"
    )


def test_escaped_null_and_empty_values() raises:
    var ctx = _context()
    var d = _dir("escaped")
    var out = d + "/out"
    assert_equal(
        _count(
            ctx,
            "COPY (SELECT id, CASE WHEN id = 1 THEN 'a/b' WHEN id = 2 THEN 'sp ace'"
            " WHEN id = 3 THEN NULL WHEN id = 4 THEN '' ELSE 'é' END AS k FROM "
            + _sales(d) + ") TO '" + out + "' (FORMAT parquet, PARTITION_BY (k))",
        ),
        5,
    )
    assert_equal(
        _files(out),
        "k=%C3%A9/data_0.parquet\n"
        "k=/data_0.parquet\n"
        "k=__HIVE_DEFAULT_PARTITION__/data_0.parquet\n"
        "k=a%2Fb/data_0.parquet\n"
        "k=sp%20ace/data_0.parquet\n",
    )
    assert_equal(
        _rows(
            ctx,
            "SELECT k FROM read_parquet('" + out
            + "/k=a%2Fb/*.parquet', hive_partitioning = true)",
        ),
        _rows(ctx, "SELECT 'a/b' AS k"),
    )
    var back = run_sql(
        ctx,
        "SELECT * FROM read_parquet('" + out + "/**/*.parquet', hive_partitioning = true)",
    )
    assert_true(Bool(back.refusal), "a NULL partition was read")
    assert_true(
        "NULL" in back.refusal.value().reason, back.refusal.value().reason
    )


def test_an_empty_result_makes_an_empty_directory() raises:
    var ctx = _context()
    var d = _dir("empty")
    assert_equal(
        _count(
            ctx,
            "COPY (SELECT id, year FROM " + _sales(d) + " WHERE id < 0) TO '" + d
            + "/out' (FORMAT parquet, PARTITION_BY (year))",
        ),
        0,
    )
    assert_true(isdir(d + "/out"))
    assert_equal(len(listdir(d + "/out")), 0)


def test_refusals_touch_nothing() raises:
    var ctx = _context()
    var d = _dir("refused")
    var src = "COPY (SELECT id, amount, year FROM " + _sales(d) + ") TO '"
    makedirs(d + "/full", exist_ok=True)
    with open(d + "/full/old.txt", "w") as f:
        f.write("old")
    _refusal(
        ctx,
        src + d + "/full' (FORMAT parquet, PARTITION_BY (year))",
        String(STEP_BIND),
        String(COPY_TARGET_EXISTS) + ": COPY ... TO '" + d + "/full' (PARTITION_BY"
        " (year)): the directory is not empty; OVERWRITE, OVERWRITE_OR_IGNORE and"
        " APPEND are not supported",
    )
    assert_equal(_files(d + "/full"), "old.txt\n")
    _refusal(
        ctx,
        src + d + "/sales.csv' (FORMAT parquet, PARTITION_BY (year))",
        String(STEP_BIND),
        String(COPY_TARGET_EXISTS) + ": COPY ... TO '" + d + "/sales.csv'"
        " (PARTITION_BY (year)): it is a file, not a directory; OVERWRITE is not"
        " supported",
    )
    _refusal(
        ctx,
        src + d + "/no/out' (FORMAT parquet, PARTITION_BY (year))",
        String(STEP_BIND),
        String(STORAGE_NOT_FOUND) + ": COPY ... TO '" + d + "/no/out' (PARTITION_BY"
        " (year)): the directory '" + d + "/no' does not exist",
    )
    _refusal(
        ctx,
        src + "s3://bucket/out' (FORMAT parquet, PARTITION_BY (year))",
        String(STEP_BIND),
        String(STORAGE_URL_REFUSED)
        + ": COPY ... TO 's3://bucket/out': only a local file path is written",
    )
    _refusal(
        ctx,
        src + d + "/out' (FORMAT parquet, PARTITION_BY (day))",
        String(STEP_BIND),
        "SQL bind error: COPY ... PARTITION_BY names column 'day', which is not"
        " a column of the query's result (id, amount, year)",
    )
    _refusal(
        ctx,
        "COPY (SELECT year FROM " + _sales(d) + ") TO '" + d
        + "/out' (FORMAT parquet, PARTITION_BY (year))",
        String(STEP_BIND),
        "SQL bind error: COPY ... PARTITION_BY names every column of the result"
        " (year): no column is left to write in the files",
    )
    _refusal(
        ctx,
        "COPY (SELECT id, year, CAST(amount AS DOUBLE) AS f FROM " + _sales(d)
        + ") TO '" + d + "/out' (FORMAT parquet, PARTITION_BY (year, f))",
        String(STEP_EXECUTE),
        String(COPY_TYPE_UNSUPPORTED) + ": COPY ... TO '" + d + "/out' (PARTITION_BY"
        " (year, f)): column 'f' has type " + String(ArrowType.FLOAT64)
        + ", which is not written as a partition directory name yet",
    )
    _refusal(
        ctx,
        src + d + "/out' (FORMAT json, PARTITION_BY (year))",
        String(STEP_PARSE),
        "SQL not supported: COPY option PARTITION_BY applies to FORMAT 'parquet'"
        " or 'csv', not 'json' (DuckDB refuses it for JSON too)",
    )
    assert_false(exists(d + "/out"))
    assert_false(exists(d + "/no"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
