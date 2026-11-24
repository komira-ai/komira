# =============================================================================
# iceberg_scan through run_sql against the pinned DuckDB's Iceberg extension
# =============================================================================
#
# The table `orders` (komira_iceberg_test_tables: six snapshots, a position
# delete, an equality delete, an overwrite, recorded under
# file:///warehouse/db/orders and staged here as orders/) is read by DuckDB
# (the :answers action: its avro and iceberg extensions, each line of
# oracle/cases.sql) and, by this test, through run_sql with the same query
# over the staged directory.
#
#   * test_every_case_equals_duckdbs_answer: each COPY line of cases.sql, run
#     through run_sql with 'orders' replaced by the staged table's path, gives
#     the rows of the TSV DuckDB wrote (compared by value, as a multiset, the
#     column names included): the full scan, a projection, count(*), a
#     partition equality (and one no partition holds), a bound above every
#     file of one partition, a range, a date range, IS NULL and IS NOT NULL,
#     a NaN above a bound, a double range, a boolean, two aggregates, and the
#     table as of an older snapshot (two, with a filter; one with a position
#     delete only; one with the equality delete, before the overwrite).
#   * test_every_case_is_run: cases.sql holds a case for each answer staged,
#     every one reads 'orders', and every file the fixture lists is staged.
#   * test_a_metadata_file_path_reads_the_table_too: iceberg_scan of the
#     current metadata file, and of the table directory, count the ten live
#     rows; the same file at an older snapshot counts that snapshot's rows.
#   * test_an_unknown_snapshot_is_refused_by_name: ICEBERG_SNAPSHOT_NOT_FOUND.
#   * test_a_moved_table_is_refused_without_allow_moved_paths: the stored
#     paths name a directory that does not exist.

from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_true

from komira_iceberg_test_tables.orders_fixture import orders_files
from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from runtime_paths import data_path, read_data
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql


struct _Case(Copyable, Movable):
    var name: String
    var query: String

    def __init__(out self, var name: String, var query: String):
        self.name = name^
        self.query = query^


def _cases() raises -> List[_Case]:
    """Every `COPY (<query>) TO '<name>.tsv' ...;` line of cases.sql."""
    var out = List[_Case]()
    var text = read_data("cases.sql")
    for line in text.split("\n"):
        var l = String(line)
        if not l.startswith("COPY ("):
            continue
        var to = l.rfind(") TO '")
        var tsv = l.rfind(".tsv'")
        assert_true(to > 0 and tsv > to, "a COPY line of cases.sql: " + l)
        out.append(_Case(String(l[byte = to + 6 : tsv]), String(l[byte=6:to])))
    return out^


def _with_table(query: String) raises -> String:
    """`query` reading the staged table: its quoted name is its path."""
    return query.replace("iceberg_scan('orders'", "iceberg_scan('" + data_path("orders") + "'")


def _run_case(c: _Case, mut problems: List[String]) raises:
    var ctx = EngineContext(EngineOptions(worker_count=3))
    var out = run_sql(ctx, _with_table(c.query))
    if out.refusal:
        problems.append(
            c.name + ": refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason
        )
        return
    var want = parse_duckdb_tsv(read_data(c.name + ".tsv"))
    if len(out.batches) == 0:
        # An answer of no batch is no row.
        if len(want.rows) != 0:
            problems.append(c.name + ": no batch, DuckDB " + String(len(want.rows)) + " rows")
        return
    if len(out.batches) != 1:
        problems.append(c.name + ": " + String(len(out.batches)) + " batches")
        return
    var actual = render_batch(out.batches[0], CanonPolicy.unordered())
    try:
        var expected = duckdb_tsv_canon(want, actual)
        var report = compare_canon(expected, actual)
        if not report.ok():
            problems.append(c.name + ": " + String(report))
    except e:
        problems.append(c.name + ": " + String(e))


def test_every_case_equals_duckdbs_answer() raises:
    var problems = List[String]()
    var cases = _cases()
    for i in range(len(cases)):
        _run_case(cases[i], problems)
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def test_every_case_is_run() raises:
    var cases = _cases()
    assert_equal(len(cases), 19)
    for i in range(len(cases)):
        assert_true(
            cases[i].query.find("iceberg_scan('orders'") >= 0,
            cases[i].name + " does not read 'orders'",
        )
        assert_true(
            Path(data_path(cases[i].name + ".tsv")).exists(),
            cases[i].name + ".tsv is not staged",
        )
    var files = orders_files()
    for i in range(len(files)):
        assert_true(
            Path(data_path("orders/" + files[i])).exists(),
            "orders/" + files[i] + " is not staged",
        )


def _count(sql: String) raises -> Int:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason + " -- " + sql,
        )
    return Int(out.batches[0].column_at(0).as_primitive[DType.int64]().get(0))


def test_a_metadata_file_path_reads_the_table_too() raises:
    var table = data_path("orders")
    var metadata = data_path("orders/metadata/v6.metadata.json")
    assert_equal(_count("SELECT count(*) FROM iceberg_scan('" + table + "', allow_moved_paths = true)"), 10)
    assert_equal(_count("SELECT count(*) FROM iceberg_scan('" + metadata + "', allow_moved_paths = true)"), 10)
    assert_equal(
        _count("SELECT count(*) FROM iceberg_scan('" + metadata + "', allow_moved_paths = true, snapshot_from_id = 6000000002)"),
        13,
    )


def test_an_unknown_snapshot_is_refused_by_name() raises:
    var ctx = EngineContext(EngineOptions(worker_count=1))
    var out = run_sql(
        ctx,
        "SELECT count(*) FROM iceberg_scan('" + data_path("orders")
        + "', allow_moved_paths = true, snapshot_from_id = 42)",
    )
    assert_true(Bool(out.refusal))
    assert_true(
        "ICEBERG_SNAPSHOT_NOT_FOUND" in out.refusal.value().reason,
        out.refusal.value().reason,
    )
    assert_equal(len(out.batches), 0)


def test_a_moved_table_is_refused_without_allow_moved_paths() raises:
    var ctx = EngineContext(EngineOptions(worker_count=1))
    var out = run_sql(
        ctx, "SELECT count(*) FROM iceberg_scan('" + data_path("orders") + "')"
    )
    assert_true(Bool(out.refusal))
    assert_equal(len(out.batches), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
