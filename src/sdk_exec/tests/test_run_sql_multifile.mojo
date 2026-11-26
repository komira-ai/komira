# =============================================================================
# run_sql over a table of several Parquet files: a directory, a glob, a Hive tree
# =============================================================================
#
# Covers: run_sql over a table of several Parquet files: a directory (files at
# any depth; a dot-name and a non-Parquet file skipped), a glob, a brace glob,
# read_parquet('<glob>') and FROM '<glob>' in SQL text; a Hive tree whose int,
# string and date keys are columns after the data columns in key order, filters
# on a key (files pruned) and on a data column, a key alone, GROUP BY a key,
# count(*), ORDER BY and LIMIT; hive_partitioning = false; a glob with no file,
# a directory in SQL text and files of different schemas are named refusals at
# their step; a replaced file is read again.
#
# Each test writes small INT64 / STRING Parquet files under `test_tmpdir()` (a
# directory of its own per test), registers them or names them in SQL text, runs
# SQL through `run_sql`, and compares the answer with an oracle computed HERE
# from the rows it wrote, never from the engine. Row order across files is not
# promised, so every query that returns rows sorts them.
#
# What each test proves:
#   * test_a_directory_is_every_parquet_file_under_it: register_parquet of a
#     directory reads the files at any depth, skips a file that is not
#     `.parquet` and a name that starts with a dot, and count(*) is their rows.
#   * test_a_glob_and_a_brace_glob_register_the_files_they_match: a `*` glob and
#     a `{a,b}` glob each give exactly the matched files' rows.
#   * test_read_parquet_and_from_take_a_glob_in_sql_text: read_parquet('<glob>')
#     and FROM '<glob>' read the matched files, with no table registered.
#   * test_hive_keys_become_columns_after_the_data_columns: SELECT * over a tree
#     of yr=<int>/tag=<string>/dt=<date> directories has the data columns, then
#     the keys in name order (dt DATE, tag STRING, yr INT64), with each file's
#     values, though the directories nest in the order yr, tag, dt.
#   * test_a_filter_on_a_partition_column_keeps_that_partitions_rows: a filter
#     on the integer, the string and the date key, one on a data column, and
#     both together, answer the rows of the matching files.
#   * test_a_partition_column_can_be_the_only_column_and_a_group_key: selecting
#     only yr, count(*), GROUP BY an integer key and ORDER BY answer
#     the oracle's counts.
#   * test_hive_partitioning_false_reads_the_data_columns_only: the option in
#     read_parquet turns the key columns off.
#   * test_a_glob_with_no_file_is_refused_by_name: PARQUET_GLOB_NO_MATCH, from
#     register_parquet and at step `bind` for read_parquet.
#   * test_a_directory_in_sql_text_is_refused_by_name: PARQUET_PATH_IS_DIRECTORY
#     for read_parquet('<dir>') at step `bind`.
#   * test_files_with_different_schemas_are_refused_by_name:
#     PARQUET_FILES_SCHEMA_MISMATCH from register_parquet and at step `bind`
#     for read_parquet, naming the file that differs.
#   * test_a_file_replaced_between_queries_is_read_again: one file of a
#     registered directory is replaced by one of the same schema (the next
#     query answers the new rows), then by one of another schema (a refusal at
#     step `lower` naming that file).

from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from arrow.string_array import StringArray
from parquet_footers.parquet_files import (
    PARQUET_FILES_SCHEMA_MISMATCH,
    PARQUET_GLOB_NO_MATCH,
    PARQUET_PATH_IS_DIRECTORY,
)
from parquet_writer.record_batch_writer import (
    write_record_batch_to_parquet_bytes,
)
from runtime_paths import test_tmpdir
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import SqlOutcome, STEP_BIND, STEP_LOWER, run_sql


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def _s_of(id: Int) -> String:
    """The string column's value of row `id`."""
    return String("s") + String(id % 3)


def _batch(first: Int, n: Int, extra: Bool) raises -> RecordBatch:
    """Rows id = first .. first + n - 1 with s = _s_of(id), and, when `extra`,
    a third column."""
    var ids = PrimitiveArray[DType.int64].allocate(n)
    var strs = List[String]()
    for i in range(n):
        ids.set(i, Int64(first + i))
        strs.append(_s_of(first + i))
    var sb = SchemaBuilder()
    var rb = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    rb.add_column(Column.from_primitive[DType.int64](ids^))
    sb.add_field(Field("s", ArrowType.STRING, False))
    rb.add_column(Column.from_string(StringArray.from_strings(strs)))
    if extra:
        var more = PrimitiveArray[DType.int64].allocate(n)
        for i in range(n):
            more.set(i, Int64(0))
        sb.add_field(Field("extra", ArrowType.INT64, False))
        rb.add_column(Column.from_primitive[DType.int64](more^))
    return rb.build(sb.build())


def _write(dir: String, name: String, first: Int, n: Int, extra: Bool = False) raises:
    """Write `dir/name` (creating `dir`) with `n` rows from id `first`."""
    makedirs(dir, exist_ok=True)
    var bytes = write_record_batch_to_parquet_bytes(
        _batch(first, n, extra), max_rows_per_rg=3
    )
    var fh = open(dir + "/" + name, "w")
    fh.write_bytes(Span(bytes))
    fh.close()


def _write_text(dir: String, name: String, text: String) raises:
    makedirs(dir, exist_ok=True)
    var fh = open(dir + "/" + name, "w")
    fh.write(text)
    fh.close()


def _run(mut ctx: EngineContext, sql: String) raises -> SqlOutcome:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at "
            + out.refusal.value().step
            + ": "
            + out.refusal.value().reason
            + " -- "
            + sql,
        )
    return out^


def _ints(ref out: SqlOutcome, col: Int) raises -> List[Int]:
    var r = List[Int]()
    for b in range(len(out.batches)):
        ref batch = out.batches[b]
        var a = batch.column_at(col).as_primitive[DType.int64]()
        for i in range(batch.num_rows()):
            r.append(Int(a.get(i)))
    return r^


def _days(ref out: SqlOutcome, col: Int) raises -> List[Int]:
    var r = List[Int]()
    for b in range(len(out.batches)):
        ref batch = out.batches[b]
        var a = batch.column_at(col).as_primitive[DType.int32]()
        for i in range(batch.num_rows()):
            r.append(Int(a.get(i)))
    return r^


def _strs(ref out: SqlOutcome, col: Int) raises -> List[String]:
    var r = List[String]()
    for b in range(len(out.batches)):
        ref batch = out.batches[b]
        var a = batch.column_at(col).as_string()
        for i in range(batch.num_rows()):
            r.append(a.get(i))
    return r^


def _expect_ints(got: List[Int], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": row count")
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + ": row " + String(i))


def _range(first: Int, last: Int) -> List[Int]:
    """first, first + 1, .. last."""
    var r = List[Int]()
    for v in range(first, last + 1):
        r.append(v)
    return r^


def _count(mut ctx: EngineContext, sql: String) raises -> Int:
    var out = _run(ctx, sql)
    var c = _ints(out, 0)
    assert_equal(len(c), 1, sql)
    return c[0]


def _expect_refusal(
    ref out: SqlOutcome, step: String, token: String
) raises:
    assert_false(out.ok(), "expected a refusal")
    assert_equal(out.refusal.value().step, step)
    var reason = out.refusal.value().reason
    assert_true(
        reason.find(token) >= 0,
        "reason '" + reason + "' does not hold '" + token + "'",
    )
    assert_equal(len(out.batches), 0)


def _register_error(path: String) raises -> String:
    """The message register_parquet raises for `path`; fails when it does not."""
    var ctx = _new_context()
    try:
        register_parquet(ctx, "t", path)
    except e:
        return String(e)
    assert_true(False, "register_parquet accepted " + path)
    return String("")


def test_a_directory_is_every_parquet_file_under_it() raises:
    var dir = test_tmpdir() + "/mf_directory"
    _write(dir, "part-0.parquet", 1, 4)
    _write(dir, "part-1.parquet", 5, 4)
    _write(dir, "part-2.parquet", 9, 4)
    _write(dir + "/sub", "part-3.parquet", 13, 2)
    _write(dir, ".hidden.parquet", 100, 2)
    _write_text(dir, "notes.txt", "not parquet")
    var ctx = _new_context()
    register_parquet(ctx, "t", dir)
    assert_equal(_count(ctx, "select count(*) from t"), 14)
    var out = _run(ctx, "select id, s from t order by id")
    var want = _range(1, 14)
    _expect_ints(_ints(out, 0), want, "ids")
    var s = _strs(out, 1)
    for i in range(len(want)):
        assert_equal(s[i], _s_of(want[i]))
    assert_equal(out.batches[0].schema.field_name(0), String("id"))
    assert_equal(out.batches[0].schema.field_name(1), String("s"))


def test_a_glob_and_a_brace_glob_register_the_files_they_match() raises:
    var dir = test_tmpdir() + "/mf_glob"
    _write(dir, "part-0.parquet", 1, 4)
    _write(dir, "part-1.parquet", 5, 4)
    _write(dir, "part-2.parquet", 9, 4)
    _write(dir, "other.parquet", 50, 2)
    var ctx = _new_context()
    register_parquet(ctx, "star", dir + "/part-*.parquet")
    register_parquet(ctx, "brace", dir + "/part-{0,2}.parquet")
    _expect_ints(
        _ints(_run(ctx, "select id from star order by id"), 0),
        _range(1, 12),
        "star",
    )
    var want = _range(1, 4)
    want.extend(_range(9, 12))
    _expect_ints(
        _ints(_run(ctx, "select id from brace order by id"), 0), want, "brace"
    )


def test_read_parquet_and_from_take_a_glob_in_sql_text() raises:
    var dir = test_tmpdir() + "/mf_sql_text"
    _write(dir, "part-0.parquet", 1, 4)
    _write(dir, "part-1.parquet", 5, 4)
    _write(dir, "other.parquet", 50, 2)
    var ctx = _new_context()
    # A registered table of other files does not take over a scan of these.
    register_parquet(ctx, "o", dir + "/other.parquet")
    _expect_ints(
        _ints(
            _run(
                ctx,
                "select id from read_parquet('"
                + dir
                + "/part-*.parquet') order by id",
            ),
            0,
        ),
        _range(1, 8),
        "read_parquet",
    )
    assert_equal(
        _count(ctx, "select count(*) from '" + dir + "/part-*.parquet'"), 8
    )
    assert_equal(
        _count(
            ctx,
            "select count(*) from read_parquet('" + dir + "/*.parquet')",
        ),
        10,
    )


def _hive_tree(name: String) raises -> String:
    """Three leaf files, nested yr / tag / dt:
    yr=2028/tag=a/dt=2028-01-01 ids 1..3, yr=2028/tag=b/dt=2028-02-02 ids 4..6,
    yr=2029/tag=a/dt=2028-01-01 ids 7..9."""
    var root = test_tmpdir() + "/" + name
    _write(root + "/yr=2028/tag=a/dt=2028-01-01", "part-0.parquet", 1, 3)
    _write(root + "/yr=2028/tag=b/dt=2028-02-02", "part-0.parquet", 4, 3)
    _write(root + "/yr=2029/tag=a/dt=2028-01-01", "part-0.parquet", 7, 3)
    return root^


# Days since 1970-01-01.
comptime _JAN_1_2028 = 21184
comptime _FEB_2_2028 = 21216


def _yr_of(id: Int) -> Int:
    return 2028 if id <= 6 else 2029


def _tag_of(id: Int) -> String:
    return String("b") if (id >= 4 and id <= 6) else String("a")


def _dt_of(id: Int) -> Int:
    return _FEB_2_2028 if (id >= 4 and id <= 6) else _JAN_1_2028


def test_hive_keys_become_columns_after_the_data_columns() raises:
    var root = _hive_tree("mf_hive_columns")
    var ctx = _new_context()
    register_parquet(ctx, "hv", root)
    var out = _run(ctx, "select * from hv order by id")
    ref schema = out.batches[0].schema
    assert_equal(schema.num_columns(), 5)
    assert_equal(schema.field_name(0), String("id"))
    assert_equal(schema.field_name(1), String("s"))
    assert_equal(schema.field_name(2), String("dt"))
    assert_equal(schema.field_name(3), String("tag"))
    assert_equal(schema.field_name(4), String("yr"))
    assert_true(schema.field_arrow_type(2) == ArrowType.DATE32)
    assert_true(schema.field_arrow_type(3) == ArrowType.STRING)
    assert_true(schema.field_arrow_type(4) == ArrowType.INT64)
    var ids = _ints(out, 0)
    _expect_ints(ids, _range(1, 9), "ids")
    var dt = _days(out, 2)
    var tag = _strs(out, 3)
    var yr = _ints(out, 4)
    var s = _strs(out, 1)
    for i in range(9):
        var id = ids[i]
        assert_equal(s[i], _s_of(id))
        assert_equal(dt[i], _dt_of(id), "dt of " + String(id))
        assert_equal(tag[i], _tag_of(id), "tag of " + String(id))
        assert_equal(yr[i], _yr_of(id), "yr of " + String(id))
    assert_equal(_count(ctx, "select count(*) from hv"), 9)


def test_a_filter_on_a_partition_column_keeps_that_partitions_rows() raises:
    var root = _hive_tree("mf_hive_filter")
    var ctx = _new_context()
    register_parquet(ctx, "hv", root + "/**/*.parquet")
    _expect_ints(
        _ints(_run(ctx, "select id, yr from hv where yr = 2029 order by id"), 0),
        _range(7, 9),
        "yr = 2029",
    )
    var want_a = _range(1, 3)
    want_a.extend(_range(7, 9))
    _expect_ints(
        _ints(_run(ctx, "select id, tag from hv where tag = 'a' order by id"), 0),
        want_a,
        "tag = 'a'",
    )
    _expect_ints(
        _ints(
            _run(
                ctx,
                "select id, dt from hv where dt = date '2028-02-02' order by id",
            ),
            0,
        ),
        _range(4, 6),
        "dt = date",
    )
    _expect_ints(
        _ints(_run(ctx, "select id from hv where id >= 5 order by id"), 0),
        _range(5, 9),
        "id >= 5",
    )
    var both = _range(2, 3)
    _expect_ints(
        _ints(
            _run(
                ctx,
                "select id from hv where yr = 2028 and tag = 'a' and id > 1 order by id",
            ),
            0,
        ),
        both,
        "partition and data columns",
    )
    # A filter no partition meets keeps no file and no row.
    assert_equal(_count(ctx, "select count(*) from hv where yr = 1999"), 0)


def test_a_partition_column_can_be_the_only_column_and_a_group_key() raises:
    var root = _hive_tree("mf_hive_group")
    var ctx = _new_context()
    register_parquet(ctx, "hv", root)
    var only = _ints(_run(ctx, "select yr from hv order by yr"), 0)
    var want = List[Int]()
    for _ in range(6):
        want.append(2028)
    for _ in range(3):
        want.append(2029)
    _expect_ints(only, want, "yr alone")
    var grouped = _run(
        ctx, "select yr, count(*) as n from hv group by yr order by yr"
    )
    _expect_ints(_ints(grouped, 0), [2028, 2029], "group keys")
    _expect_ints(_ints(grouped, 1), [6, 3], "group counts")
    var by_tag = _run(
        ctx, "select tag, count(*) as n from hv group by tag order by tag"
    )
    var tags = _strs(by_tag, 0)
    assert_equal(len(tags), 2)
    assert_equal(tags[0], String("a"))
    assert_equal(tags[1], String("b"))
    _expect_ints(_ints(by_tag, 1), [6, 3], "tag counts")


def test_hive_partitioning_false_reads_the_data_columns_only() raises:
    var root = _hive_tree("mf_hive_off")
    var ctx = _new_context()
    var off = _run(
        ctx,
        "select * from read_parquet('"
        + root
        + "/**/*.parquet', hive_partitioning = false) order by id",
    )
    assert_equal(off.batches[0].schema.num_columns(), 2)
    _expect_ints(_ints(off, 0), _range(1, 9), "ids")
    var on = _run(
        ctx,
        "select * from read_parquet('"
        + root
        + "/**/*.parquet', hive_partitioning = true) order by id",
    )
    assert_equal(on.batches[0].schema.num_columns(), 5)
    var auto = _run(
        ctx,
        "select * from read_parquet('" + root + "/**/*.parquet') order by id",
    )
    assert_equal(auto.batches[0].schema.num_columns(), 5)


def test_a_glob_with_no_file_is_refused_by_name() raises:
    var dir = test_tmpdir() + "/mf_no_match"
    _write(dir, "part-0.parquet", 1, 2)
    var missing = dir + "/nothing-*.parquet"
    assert_true(
        _register_error(missing).find(PARQUET_GLOB_NO_MATCH) >= 0,
        "register_parquet of a glob that matches no file",
    )
    var ctx = _new_context()
    var out = run_sql(ctx, "select * from read_parquet('" + missing + "')")
    _expect_refusal(out, String(STEP_BIND), PARQUET_GLOB_NO_MATCH)
    # The context runs the next query.
    assert_equal(
        _count(ctx, "select count(*) from read_parquet('" + dir + "/part-*.parquet')"),
        2,
    )


def test_a_directory_in_sql_text_is_refused_by_name() raises:
    var dir = test_tmpdir() + "/mf_sql_directory"
    _write(dir, "part-0.parquet", 1, 2)
    var ctx = _new_context()
    var out = run_sql(ctx, "select * from read_parquet('" + dir + "')")
    _expect_refusal(out, String(STEP_BIND), PARQUET_PATH_IS_DIRECTORY)
    # The same directory registered is served.
    register_parquet(ctx, "t", dir)
    assert_equal(_count(ctx, "select count(*) from t"), 2)


def test_files_with_different_schemas_are_refused_by_name() raises:
    var dir = test_tmpdir() + "/mf_mismatch"
    _write(dir, "part-0.parquet", 1, 2)
    _write(dir, "part-1.parquet", 3, 2, extra=True)
    var message = _register_error(dir)
    assert_true(message.find(PARQUET_FILES_SCHEMA_MISMATCH) >= 0, message)
    assert_true(message.find("part-1.parquet") >= 0, message)
    var ctx = _new_context()
    var out = run_sql(
        ctx, "select * from read_parquet('" + dir + "/part-*.parquet')"
    )
    _expect_refusal(out, String(STEP_BIND), PARQUET_FILES_SCHEMA_MISMATCH)
    assert_true(out.refusal.value().reason.find("part-1.parquet") >= 0)


def test_a_file_replaced_between_queries_is_read_again() raises:
    var dir = test_tmpdir() + "/mf_replaced"
    _write(dir, "part-0.parquet", 1, 3)
    _write(dir, "part-1.parquet", 4, 3)
    var ctx = _new_context()
    register_parquet(ctx, "t", dir)
    _expect_ints(
        _ints(_run(ctx, "select id from t order by id"), 0),
        _range(1, 6),
        "before",
    )
    # Same schema, other rows: the next query reads the new file.
    _write(dir, "part-1.parquet", 20, 2)
    var after = _range(1, 3)
    after.extend(_range(20, 21))
    _expect_ints(
        _ints(_run(ctx, "select id from t order by id"), 0), after, "after"
    )
    # Another schema: refused at lowering, naming the file.
    _write(dir, "part-1.parquet", 20, 2, extra=True)
    var out = run_sql(ctx, "select id from t order by id")
    _expect_refusal(out, String(STEP_LOWER), "part-1.parquet")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
