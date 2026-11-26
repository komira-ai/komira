# =============================================================================
# test_run_sql_cte: WITH queries through run_sql answer what DuckDB answers
# =============================================================================
#
# Covers: WITH queries through run_sql answer what the pinned DuckDB answers
# (the :cte_oracle action in BUCK) for each case of tests/cte/cases.sql: a CTE
# read once (filtered, chained, unread, with NULL counts, sorted, inside a
# derived table) and read more than once (a grouped aggregation, the same under
# two filters, a distinct three times, a filtered scan, a limit, a subquery
# reading a CTE twice, an ungrouped aggregation); every case is run; a grouped
# aggregation read twice is lowered to one aggregation segment both branches
# read, a subquery holding a repeat written twice to one aggregation segment,
# and a filtered scan read twice to two scans.
#
# The cases are the lines of tests/cte/cases.sql: the pinned DuckDB runs each
# query over the committed tests/cte/sales.csv as a build action
# (`sql_oracle`) and writes its answer as a TSV; this test reads the same file
# for the query text, runs that text through `run_sql` (parse, bind, optimize,
# hold each repeated subtree once, lower, run) and compares the answer with
# DuckDB's by value, rows as a multiset (komira_plan_harness).
#
#   test_a_cte_read_once_equals_duckdb
#                       a CTE under a filter and an aggregation, one that reads
#                       an earlier CTE, one never read, NULL counts, a sorted
#                       CTE body, a CTE read inside a derived table.
#   test_a_cte_read_more_than_once_equals_duckdb
#                       a grouped aggregation read twice, the same under two
#                       filters that split its rows, a distinct read three
#                       times, a filtered scan read twice, a limit read twice
#                       (the same rows each time, so the count is exact), a
#                       subquery that reads a CTE twice read twice, a union of a
#                       filtered scan read twice read twice, a CTE joined
#                       with itself, an ungrouped aggregation read twice.
#   test_every_case_is_run
#                       each case of cases.sql belongs to one of the tests
#                       above, so none is skipped.
#   test_a_cte_read_twice_is_aggregated_once
#                       the plan run_sql lowers (`optimize_for_run`, then
#                       `lower_for_context`) for a grouped aggregation read
#                       twice holds one aggregation segment whose output both
#                       branches read, and running it gives each group twice.
#   test_a_repeat_that_holds_a_repeat_is_cut_once
#                       a count over a CTE read twice, itself written twice,
#                       is lowered (each repeat found by its hash before
#                       folding) with one aggregation segment, and answers the
#                       count twice.
#   test_a_filtered_scan_read_twice_is_scanned_twice_over_one_input
#                       a CTE of a filtered scan read twice is two scans of
#                       the file, each with the filter, and no segment reads
#                       another's output to get it.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from lowering.lowered_plan import LoweredPlan
from physical_plan.physical_plan import (
    SINK_AGG,
    SOURCE_CONCAT,
    SOURCE_CSV,
    SOURCE_SINK_OUTPUT,
)
from runtime_paths import data_path, read_data
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_execute import run_lowered_plan
from sdk_exec.engine_lower import lower_for_context
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_plan import optimize_for_run
from sdk_exec.engine_sql import run_sql
from sql.sql_binder import bind_statement
from sql.sql_frontend import query_plan
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize


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
        out.append(
            _Case(String(l[byte = to + 6 : tsv]), String(l[byte=6:to]))
        )
    return out^


def _with_path(query: String) raises -> String:
    """`query` with the quoted fixture name replaced by its staged path."""
    return query.replace("'sales.csv'", "'" + data_path("sales.csv") + "'")


def _check(c: _Case, mut problems: List[String]) raises:
    var ctx = EngineContext(EngineOptions(worker_count=3))
    var out = run_sql(ctx, _with_path(c.query))
    if out.refusal:
        problems.append(
            c.name + ": refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason
        )
        return
    if len(out.batches) != 1:
        problems.append(c.name + ": " + String(len(out.batches)) + " batches")
        return
    var actual = render_batch(out.batches[0], CanonPolicy.unordered())
    try:
        var expected = duckdb_tsv_canon(
            parse_duckdb_tsv(read_data(c.name + ".tsv")), actual
        )
        var report = compare_canon(expected, actual)
        if not report.ok():
            problems.append(c.name + ": " + String(report))
    except e:
        problems.append(c.name + ": " + String(e))


def _check_prefix(prefix: String) raises:
    var problems = List[String]()
    var ran = 0
    var cases = _cases()
    for i in range(len(cases)):
        if not cases[i].name.startswith(prefix):
            continue
        ran += 1
        _check(cases[i], problems)
    assert_true(ran >= 1, "cases.sql holds no case named " + prefix + "*")
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def test_a_cte_read_once_equals_duckdb() raises:
    _check_prefix("one_")


def test_a_cte_read_more_than_once_equals_duckdb() raises:
    _check_prefix("twice_")


def test_every_case_is_run() raises:
    var cases = _cases()
    assert_true(len(cases) >= 15, "cases.sql holds " + String(len(cases)) + " cases")
    for i in range(len(cases)):
        var name = cases[i].name
        assert_true(
            name.startswith("one_") or name.startswith("twice_"),
            name + " belongs to no test",
        )


# =============================================================================
# The plan run_sql lowers
# =============================================================================


def _lowered(mut ctx: EngineContext, text: String) raises -> LoweredPlan:
    """The plan `run_sql` lowers for `text`: the bound plan through
    `optimize_for_run`, then `lower_for_context`."""
    ctx.begin_query()
    var bound = bind_statement(
        parse_sql(tokenize(_with_path(text))), ctx.catalog, ctx.footers
    )
    var optimized = optimize_for_run(query_plan(bound^))
    return lower_for_context(optimized, ctx)


def _count(lp: LoweredPlan, sink_kind: UInt8) -> Int:
    var n = 0
    for i in range(len(lp.segments)):
        if lp.segments[i].sink_kind == sink_kind:
            n += 1
    return n


def _sources(lp: LoweredPlan, source_kind: UInt8) -> Int:
    var n = 0
    for i in range(len(lp.segments)):
        if lp.segments[i].source_kind == source_kind:
            n += 1
    return n


def _reads(lp: LoweredPlan, producer: Int) -> Int:
    """How many times the sources of `lp` name the output of `producer`."""
    var n = 0
    for i in range(len(lp.segments)):
        ref s = lp.segments[i]
        if s.source_kind != SOURCE_SINK_OUTPUT and s.source_kind != SOURCE_CONCAT:
            continue
        for j in range(len(s.source_spec.dep_seg_ids)):
            if s.source_spec.dep_seg_ids[j] == producer:
                n += 1
    return n


def test_a_cte_read_twice_is_aggregated_once() raises:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var lp = _lowered(
        ctx,
        "WITH t AS (SELECT region, count(*) AS n FROM read_csv('sales.csv')"
        " GROUP BY region) SELECT region, n FROM t UNION ALL"
        " SELECT region, n FROM t",
    )
    assert_equal(_count(lp, SINK_AGG), 1)
    assert_equal(_sources(lp, SOURCE_CSV), 1)
    # One segment's output (the aggregation's, or that of the segment that
    # projects it) is what both branches read.
    var twice = 0
    for i in range(len(lp.segments)):
        if _reads(lp, i) == 2:
            twice += 1
    assert_equal(twice, 1)
    var batch = run_lowered_plan(ctx, lp^)
    # Four regions, each twice.
    assert_equal(batch.num_rows(), 8)


def test_a_repeat_that_holds_a_repeat_is_cut_once() raises:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var branch = String(
        "SELECT n FROM (SELECT count(*) AS n FROM (SELECT region FROM d"
        " UNION ALL SELECT region FROM d) u) a"
    )
    var lp = _lowered(
        ctx,
        "WITH d AS (SELECT region FROM read_csv('sales.csv') WHERE qty > 2) "
        + branch
        + " UNION ALL "
        + branch,
    )
    assert_equal(_count(lp, SINK_AGG), 1)
    var batch = run_lowered_plan(ctx, lp^)
    # qty > 2 keeps six rows; d twice is twelve, and a is read twice.
    assert_equal(batch.num_rows(), 2)
    var n = batch.column_at(0).as_primitive[DType.int64]()
    assert_equal(Int(n.get(0)), 12)
    assert_equal(Int(n.get(1)), 12)


def test_a_filtered_scan_read_twice_is_scanned_twice_over_one_input() raises:
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var lp = _lowered(
        ctx,
        "WITH f AS (SELECT id, qty FROM read_csv('sales.csv') WHERE qty > 4)"
        " SELECT id, qty FROM f UNION ALL SELECT id, qty FROM f",
    )
    assert_equal(_sources(lp, SOURCE_CSV), 2)
    assert_equal(_sources(lp, SOURCE_SINK_OUTPUT), 0)
    var batch = run_lowered_plan(ctx, lp^)
    # qty > 4: rows 2, 4, 6 and 8, each twice.
    assert_equal(batch.num_rows(), 8)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
