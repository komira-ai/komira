# =============================================================================
# test_run_sql_star_exclude: a star with an EXCLUDE list, and a table-qualified
# star, answer what DuckDB answers
# =============================================================================
#
# Covers: run_sql over two Parquet tables the pinned DuckDB writes (the
# :star_exclude_oracle action in BUCK) answers what DuckDB answers for each
# query of tests/star_exclude/cases.sql, on one and on three workers.
#
# The pinned DuckDB writes the tables (tests/star_exclude/data.sql: orders,
# 600 rows in three row groups with NULLs in every column, and customers, which
# matches some orders and not others) and answers each query of
# tests/star_exclude/cases.sql as a build action (`sql_oracle`). This test reads
# the same cases.sql for the query text, runs it through `run_sql` over the
# same Parquet files, and compares the answer with DuckDB's by value and by
# column name and order, rows as a multiset (komira_plan_harness). So a column
# the star should have dropped, kept, or put in another place is a difference.
#
#   test_exclude_over_one_table_equals_duckdb
#       `* EXCLUDE (note)`; two names written in another case than the
#       columns'; one name without parentheses; under a WHERE; with an ORDER
#       BY of the dropped column and a LIMIT (the sort's key carried and
#       pruned); under DISTINCT; in a CTE, and again over the CTE.
#   test_exclude_over_a_join_and_a_qualified_star_equal_duckdb
#       `* EXCLUDE (customer)` over a join drops the key of both sides;
#       `o.* EXCLUDE (note, amount)` keeps the rest of the left relation;
#       `c.*` is the right relation's columns under their own names; and
#       `c.* EXCLUDE (tier)` over a LEFT JOIN is the right key, NULL where
#       the order has no customer row.
#   test_every_case_is_run
#       each case of cases.sql belongs to one of the tests above.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

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
        "'orders.parquet'", "'" + data_path("orders.parquet") + "'"
    ).replace(
        "'customers.parquet'", "'" + data_path("customers.parquet") + "'"
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


def _one_table() -> List[String]:
    var out = List[String]()
    out.append("exclude_one")
    out.append("exclude_two_any_case")
    out.append("exclude_bare_name")
    out.append("exclude_under_where")
    out.append("exclude_order_by_dropped")
    out.append("exclude_distinct")
    out.append("exclude_in_cte")
    return out^


def _joins() -> List[String]:
    var out = List[String]()
    out.append("exclude_join_key")
    out.append("qualified_left_exclude")
    out.append("qualified_right")
    out.append("qualified_right_of_left_join")
    return out^


def test_exclude_over_one_table_equals_duckdb() raises:
    _check_all(_one_table())


def test_exclude_over_a_join_and_a_qualified_star_equal_duckdb() raises:
    _check_all(_joins())


def test_every_case_is_run() raises:
    var known = _one_table()
    known.extend(_joins())
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
