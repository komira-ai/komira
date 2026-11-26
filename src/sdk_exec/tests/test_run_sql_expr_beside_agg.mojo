# =============================================================================
# test_run_sql_expr_beside_agg: a literal or an expression of the GROUP BY keys
# beside an aggregate answers what DuckDB answers
# =============================================================================
#
# Covers: run_sql over a Parquet table the pinned DuckDB writes (the
# :expr_beside_agg_oracle action in BUCK; three row groups, NULLs in every
# column, the empty string) answers what DuckDB answers for each query of
# tests/expr_beside_agg/cases.sql, on one and on three workers. Each query has
# a SELECT item that is neither an aggregate nor a GROUP BY key: a literal
# beside an ungrouped aggregate (also over no row, which is one row, and in
# each branch of a UNION ALL), a literal beside a grouped one (over no row,
# which is no row), an integer literal per group, a function or an operator of
# one key, of two keys and of a computed key, and an item under a WHERE and a
# HAVING.
#
# The pinned DuckDB writes the table (tests/expr_beside_agg/data.sql: 3000 rows,
# an INTEGER k, a VARCHAR s holding the empty string, a BIGINT v, each with
# NULLs at a period of its own) and answers each query of
# tests/expr_beside_agg/cases.sql as a build action (`sql_oracle`). This test
# reads the same cases.sql for the query text, runs it through `run_sql` over
# the same Parquet file, and compares the answer with DuckDB's by value and
# column name, rows as a multiset (komira_plan_harness). The columns the new
# items produce also have DuckDB's type (a string label VARCHAR, the integer
# literal `one` INTEGER, the count BIGINT), which the comparison by value alone
# would not see.
#
#   test_a_literal_beside_an_aggregate_equals_duckdb
#       `SELECT 'o' AS src, count(*), sum(v)` with no GROUP BY; the same over
#       no row (one row, count 0); the same grouped over no row (no row); a
#       label per branch of a UNION ALL of three ungrouped counts; `1 AS one`
#       beside a GROUP BY k (INTEGER, one value per group, the NULL key's
#       group included).
#   test_an_expression_of_the_keys_beside_an_aggregate_equals_duckdb
#       coalesce(s, 'none') and upper(s) over GROUP BY s (the NULL group and
#       the empty-string group apart); k + 1 and the unaliased k * 2, named
#       `(k * 2)` as DuckDB names it, over GROUP BY k; a CASE over two keys;
#       (k + 1) * 2 over GROUP BY k + 1; coalesce(s, 'none') under a WHERE and
#       a HAVING.
#   test_every_case_is_run
#       each case of cases.sql belongs to one of the tests above.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
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
        out.append(
            _Case(String(l[byte = to + 6 : tsv]), String(l[byte=6:to]))
        )
    return out^


def _type_problem(ref batch: RecordBatch) -> String:
    """The first column of a name below whose type is not DuckDB's, or ""."""
    for c in range(batch.schema.num_columns()):
        var n = batch.schema.field_name(c)
        var t = batch.schema.field_arrow_type(c)
        var want = ArrowType.NULL
        if n == "src" or n == "st" or n == "us":
            want = ArrowType.STRING
        elif n == "one":
            want = ArrowType.INT32
        elif n == "n":
            want = ArrowType.INT64
        else:
            continue
        if t != want:
            return "column " + n + " is " + String(t) + ", DuckDB's " + String(want)
    return ""


def _check(name: String, workers: Int, mut problems: List[String]) raises:
    var label = name + " on " + String(workers) + " workers"
    var query = String("")
    var cases = _cases()
    for i in range(len(cases)):
        if cases[i].name == name:
            query = cases[i].query
    if query == "":
        problems.append(label + ": cases.sql holds no case " + name)
        return
    var text = query.replace(
        "'expr.parquet'", "'" + data_path("expr.parquet") + "'"
    )
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    var out = run_sql(ctx, text)
    if out.refusal:
        problems.append(
            label + ": refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason
        )
        return
    if len(out.batches) != 1:
        problems.append(label + ": " + String(len(out.batches)) + " batches")
        return
    var typed = _type_problem(out.batches[0])
    if typed != "":
        problems.append(label + ": " + typed)
    var actual = render_batch(out.batches[0], CanonPolicy.unordered())
    try:
        var expected = duckdb_tsv_canon(
            parse_duckdb_tsv(read_data(name + ".tsv")), actual
        )
        var report = compare_canon(expected, actual)
        if not report.ok():
            problems.append(label + ": " + String(report))
    except e:
        problems.append(label + ": " + String(e))


def _check_all(var names: List[String]) raises:
    var problems = List[String]()
    for i in range(len(names)):
        _check(names[i], 1, problems)
        _check(names[i], 3, problems)
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def _literals() -> List[String]:
    var out = List[String]()
    out.append("literal_ungrouped")
    out.append("literal_ungrouped_no_row")
    out.append("literal_grouped_no_row")
    out.append("literal_union_labels")
    out.append("int_literal_grouped")
    return out^


def _expressions() -> List[String]:
    var out = List[String]()
    out.append("coalesce_of_key")
    out.append("upper_of_key")
    out.append("arith_of_key")
    out.append("expr_of_two_keys")
    out.append("expr_of_computed_key")
    out.append("item_under_where_having")
    return out^


def test_a_literal_beside_an_aggregate_equals_duckdb() raises:
    _check_all(_literals())


def test_an_expression_of_the_keys_beside_an_aggregate_equals_duckdb() raises:
    _check_all(_expressions())


def test_every_case_is_run() raises:
    var known = _literals()
    known.extend(_expressions())
    var cases = _cases()
    assert_equal(len(cases), len(known), "cases in cases.sql")
    for i in range(len(cases)):
        var found = False
        for j in range(len(known)):
            if cases[i].name == known[j]:
                found = True
        assert_true(found, cases[i].name + " belongs to no test")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
