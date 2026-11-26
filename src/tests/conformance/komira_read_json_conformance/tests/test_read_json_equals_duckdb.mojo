# =============================================================================
# read_json through run_sql, by value against the pinned DuckDB's read_json
# =============================================================================
#
# rows.jsonl is the input of both engines. Each case is one oracle/<case>.sql:
# DuckDB ran it in the build and wrote <case>.tsv; this test runs the query
# text of the same file (between `COPY (` and `) TO`, with the file name made
# a path) through run_sql, whose plan reads the file through a SOURCE_JSONL
# segment, and compares the result with DuckDB's by value
# (komira_plan_harness: the TSV read at the engine's schema, compare_canon).
# Row order is compared only where the query states one.
#
# What the fixture leaves out, and why:
#   * An integer key holding both negative and non-negative values: the pinned
#     DuckDB's read_json gives that column HUGEINT, while the binder here
#     infers BIGINT (values equal, type not). An inference difference
#     (src/jsonl, the SQL binder), not of the scan.
#
#   * test_the_columns_and_their_types_are_duckdbs: the names, order and types
#     of `SELECT *` are the ones DuckDB's read_json gives (types.tsv).
#   * test_<case>_is_duckdbs, one per case of the BUCK list (every row and
#     column, a projection in another order, a comparison filter over NULLs, a
#     boolean filter, a filter on a column left out, count(*), ungrouped
#     aggregates, a string group key with a NULL group) and
#     test_an_order_by_is_duckdbs_in_order: the case's column names, their
#     order and every value (NULLs included) are DuckDB's. Catches a
#     key read at the wrong type or not at all, a missing key that is not
#     NULL, a column order that is not the first-seen key order, a filter or
#     an aggregate over a JSON scan that differs from DuckDB, a count(*) that
#     reads no column and loses the rows, and a refusal where DuckDB answers.

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch, Schema
from komira_plan_harness.canon_text import CanonPolicy
from komira_plan_harness.compare import compare_canon
from komira_plan_harness.duckdb_tsv import duckdb_tsv_canon, parse_duckdb_tsv
from komira_plan_harness.render import render_batch
from runtime_paths import data_path
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import run_sql


def _read(name: String) raises -> String:
    var fh = open(data_path(name), "r")
    var text = fh.read()
    fh.close()
    return text^


def _query(name: String) raises -> String:
    """The query of oracle/<name>.sql, reading rows.jsonl by its path here."""
    var lines = _read(name + ".sql").split("\n")
    var out = String()
    var inside = False
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.startswith(") TO "):
            inside = False
        if inside:
            out += line + "\n"
        if line == "COPY (":
            inside = True
    assert_true(out.byte_length() > 0, name + ".sql holds no query")
    return out.replace("'rows.jsonl'", "'" + data_path("rows.jsonl") + "'")


def _run(mut ctx: EngineContext, name: String) raises -> RecordBatch:
    var outcome = run_sql(ctx, _query(name))
    if outcome.refusal:
        ref r = outcome.refusal.value()
        raise Error(name + ": refused at " + r.step + ": " + r.reason)
    assert_equal(len(outcome.batches), 1, name + ": one batch")
    return outcome.batches.pop()


def _check(mut ctx: EngineContext, name: String, var policy: CanonPolicy) raises:
    var got = render_batch(_run(ctx, name), policy^)
    var expected = duckdb_tsv_canon(parse_duckdb_tsv(_read(name + ".tsv")), got)
    var report = compare_canon(expected, got)
    if not report.ok():
        raise Error(name + ": the result is not DuckDB's: " + String(report))


def _duckdb_type(t: ArrowType) raises -> String:
    if t == ArrowType.INT64:
        return "BIGINT"
    if t == ArrowType.FLOAT64:
        return "DOUBLE"
    if t == ArrowType.BOOL:
        return "BOOLEAN"
    if t == ArrowType.STRING:
        return "VARCHAR"
    raise Error("no DuckDB name for the type " + String(t))


def _check_types(schema: Schema) raises:
    var tsv = parse_duckdb_tsv(_read("types.tsv"))
    assert_equal(len(tsv.rows), schema.num_columns(), "the column count")
    for i in range(schema.num_columns()):
        assert_equal(tsv.rows[i][0].value(), schema.field_name(i), "column " + String(i))
        assert_equal(
            tsv.rows[i][1].value(),
            _duckdb_type(schema.field_arrow_type(i)),
            "the type of " + schema.field_name(i),
        )


def _ctx() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def test_the_columns_and_their_types_are_duckdbs() raises:
    var ctx = _ctx()
    _check_types(_run(ctx, "scan_all").schema)


def test_every_row_and_column_is_duckdbs() raises:
    var ctx = _ctx()
    _check(ctx, "scan_all", CanonPolicy.unordered())


def test_a_projection_in_another_order_is_duckdbs() raises:
    var ctx = _ctx()
    _check(ctx, "project_reordered", CanonPolicy.unordered())


def test_a_comparison_filter_over_nulls_is_duckdbs() raises:
    var ctx = _ctx()
    _check(ctx, "filter_compare", CanonPolicy.unordered())


def test_a_boolean_filter_is_duckdbs() raises:
    var ctx = _ctx()
    _check(ctx, "filter_bool", CanonPolicy.unordered())


def test_a_filter_on_a_column_left_out_is_duckdbs() raises:
    var ctx = _ctx()
    _check(ctx, "filter_unprojected", CanonPolicy.unordered())


def test_count_star_is_duckdbs() raises:
    var ctx = _ctx()
    _check(ctx, "count_star", CanonPolicy.unordered())


def test_ungrouped_aggregates_are_duckdbs() raises:
    var ctx = _ctx()
    _check(ctx, "aggregate", CanonPolicy.unordered())


def test_a_string_group_key_with_a_null_group_is_duckdbs() raises:
    var ctx = _ctx()
    _check(ctx, "group_by", CanonPolicy.unordered())


def test_an_order_by_is_duckdbs_in_order() raises:
    var ctx = _ctx()
    _check(ctx, "order_by", CanonPolicy.total())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
