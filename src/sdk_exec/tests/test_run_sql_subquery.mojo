# =============================================================================
# test_run_sql_subquery: uncorrelated scalar, IN and NOT IN subqueries answer
# what DuckDB answers
# =============================================================================
#
# Covers: run_sql over Parquet tables DuckDB wrote (the :subquery_oracle action
# in BUCK; several row groups, NULLs, duplicate and unmatched values in BIGINT,
# INTEGER, DECIMAL, DATE and VARCHAR columns, an empty table) answers what the
# pinned DuckDB answers for each query of tests/subquery/cases.sql, on one and
# three workers: scalar subqueries in a WHERE (=, <, >, BIGINT, DOUBLE,
# DECIMAL, DATE; the TPC-H Q15 shape over a CTE), over an empty table and as a
# LIMIT body with no row (NULL), in a SELECT list, under CASE and coalesce, in
# a grouped SELECT list, beside an aggregate, in a HAVING (the Q11 shape) and
# nested; IN and NULL-aware NOT IN over one-table bodies and over DISTINCT,
# GROUP BY / HAVING (the Q18 shape), join and expression bodies, with and
# without NULL, over the empty table, and IN and NOT IN lists with NULL; a
# scalar body of several rows and a VARCHAR LIMIT body are refused at optimize,
# DECIMAL and DATE IN keys at lower, an expression left of IN at parse and IN
# in a HAVING at bind; every case is run.
#
# The pinned DuckDB writes the tables (tests/subquery/data.sql: t and u in
# small row groups, with NULL, duplicate and unmatched values in BIGINT,
# INTEGER, DECIMAL(12,2), DATE and VARCHAR columns; nn, no NULL; e, the
# columns of u and no row) and answers each query of tests/subquery/cases.sql
# as a build action (`sql_oracle`). This test reads the same cases.sql for the
# query text, runs it through `run_sql` over the same Parquet files, and
# compares the answer with DuckDB's by value, rows as a multiset
# (komira_plan_harness). Every case runs on one worker and on three.
#
#   test_scalar_subqueries_in_a_where_equal_duckdb
#       a scalar compared with a column on either side, by =, <, >, >= (a
#       BIGINT max, min, sum and count, a DOUBLE avg, a DECIMAL max, a DATE
#       min, an INTEGER against a count), two in one WHERE, under AND and OR,
#       a body with its own WHERE, over a derived table and over a CTE read
#       twice (the TPC-H Q15 shape), and a count over such a WHERE.
#   test_empty_and_limit_scalar_bodies_equal_duckdb
#       a global aggregate over the empty table (max is NULL, count is 0), in a
#       WHERE, under IS NULL, in a SELECT list and under coalesce; a LIMIT 1
#       body of one row (BIGINT, DATE); a LIMIT 1 body of no row (BIGINT,
#       DECIMAL) is NULL in a SELECT list and under IS NULL, so every outer row
#       is kept.
#   test_scalar_subqueries_in_other_positions_equal_duckdb
#       a SELECT item alone, in arithmetic, with no FROM, under CASE; a SELECT
#       item of a grouped query; beside an aggregate (sum(v) + (SELECT ..));
#       in a HAVING over a BIGINT and a DECIMAL sum (the TPC-H Q11 shape); a
#       scalar inside a scalar body.
#   test_in_subqueries_equal_duckdb
#       IN (SELECT) on BIGINT keys with NULL on both sides, INTEGER, INTEGER =
#       BIGINT and VARCHAR keys, over the empty table, two IN in one WHERE, IN
#       beside a scalar, a count and a GROUP BY over an IN, and an IN list
#       holding NULL.
#   test_in_over_a_whole_body_equals_duckdb
#       IN over a body with DISTINCT, GROUP BY and HAVING (the TPC-H Q18
#       shape), a join, an expression, an aggregate and a LIMIT.
#   test_not_in_is_null_aware_like_duckdb
#       NOT IN (SELECT) over a column with NULL (no row), without NULL (the
#       NULL left key dropped), over the empty table (every row, NULL key
#       included), on INTEGER and VARCHAR keys, after a filter, under a count;
#       NOT IN lists with and without NULL.
#   test_not_in_over_a_whole_body_is_null_aware_like_duckdb
#       NOT IN over a DISTINCT, a GROUP BY / HAVING and an expression body,
#       each with a NULL in its result and without; a grouped body with no
#       group; a LIMIT body holding a NULL.
#   test_a_scalar_body_of_several_rows_is_refused_at_optimize
#       a scalar body that is not provably one row (a plain filtered scan) is
#       refused at step `optimize` with OPTIMIZE_UNRESOLVED_SCALAR; DuckDB
#       raises for such a body of several rows.
#   test_a_varchar_limit_body_is_refused_at_optimize
#       a VARCHAR LIMIT 1 body, which only a global max could make one row
#       and the pipeline's max does not carry, is refused the same way.
#   test_in_on_keys_the_hash_join_does_not_serve_is_refused_at_lower
#       IN and NOT IN on DECIMAL and DATE keys are LOWERING_JOIN_UNSERVED.
#   test_in_with_an_expression_on_the_left_is_refused_at_parse
#       `k + 1 IN (SELECT ...)` is refused at step `parse` by name.
#   test_a_predicate_subquery_in_a_having_is_refused_at_bind
#       IN (SELECT) in a HAVING is refused at step `bind` by name.
#   test_every_case_is_run
#       each case of cases.sql belongs to one of the tests above.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

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
from sdk_exec.engine_sql import STEP_BIND, STEP_LOWER, STEP_OPTIMIZE, STEP_PARSE, run_sql


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


def _with_paths(query: String) raises -> String:
    """The query with each table file name replaced by its path."""
    var text = query.replace("'t.parquet'", "'" + data_path("t.parquet") + "'")
    text = text.replace("'u.parquet'", "'" + data_path("u.parquet") + "'")
    text = text.replace("'nn.parquet'", "'" + data_path("nn.parquet") + "'")
    text = text.replace("'e.parquet'", "'" + data_path("e.parquet") + "'")
    return text^


def _check(
    name: String, workers: Int, cases: List[_Case], mut problems: List[String]
) raises:
    var label = name + " on " + String(workers) + " workers"
    var query = String("")
    for i in range(len(cases)):
        if cases[i].name == name:
            query = cases[i].query
    if query == "":
        problems.append(label + ": cases.sql holds no case " + name)
        return
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    var out = run_sql(ctx, _with_paths(query))
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
    var cases = _cases()
    for i in range(len(names)):
        _check(names[i], 1, cases, problems)
        _check(names[i], 3, cases, problems)
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def _refused(query: String, step: String, reason: String) raises:
    """`query` (table file names as in cases.sql) is refused at `step` with
    exactly `reason`, and the context runs the next query."""
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var out = run_sql(ctx, _with_paths(query))
    assert_false(out.ok(), "expected a refusal: " + query)
    assert_equal(out.refusal.value().step, step, query)
    assert_equal(out.refusal.value().reason, reason, query)
    assert_equal(len(out.batches), 0)
    var next = run_sql(ctx, _with_paths("SELECT count(*) AS n FROM read_parquet('nn.parquet') nn"))
    assert_true(next.ok(), "the context runs on after a refusal")


def _scalar_in_where() -> List[String]:
    var out = List[String]()
    out.append("scalar_eq_max")
    out.append("scalar_left_operand")
    out.append("scalar_avg_double")
    out.append("scalar_sum")
    out.append("scalar_decimal_eq")
    out.append("scalar_decimal_lt")
    out.append("scalar_date")
    out.append("scalar_int32_count")
    out.append("scalar_two_bounds")
    out.append("scalar_and_chain")
    out.append("scalar_or")
    out.append("scalar_filtered_body")
    out.append("scalar_count_star_where")
    out.append("scalar_derived_body")
    out.append("scalar_cte_max")
    return out^


def _scalar_empty_and_limit() -> List[String]:
    var out = List[String]()
    out.append("scalar_empty_max")
    out.append("scalar_empty_count")
    out.append("scalar_empty_is_null")
    out.append("scalar_select_empty")
    out.append("scalar_select_coalesce")
    out.append("scalar_limit_one_row")
    out.append("scalar_limit_no_row_select")
    out.append("scalar_limit_no_row_is_null")
    out.append("scalar_limit_date_select")
    out.append("scalar_limit_decimal_no_row")
    return out^


def _scalar_positions() -> List[String]:
    var out = List[String]()
    out.append("scalar_select_item")
    out.append("scalar_select_expr")
    out.append("scalar_select_no_from")
    out.append("scalar_select_case")
    out.append("scalar_grouped_select")
    out.append("scalar_agg_plus")
    out.append("scalar_having")
    out.append("scalar_having_decimal")
    out.append("scalar_nested")
    return out^


def _in() -> List[String]:
    var out = List[String]()
    out.append("in_with_nulls")
    out.append("in_int32")
    out.append("in_int32_int64")
    out.append("in_string")
    out.append("in_empty")
    out.append("in_two")
    out.append("in_and_scalar")
    out.append("in_count")
    out.append("in_grouped_after")
    out.append("in_list_null")
    return out^


def _in_whole_body() -> List[String]:
    var out = List[String]()
    out.append("in_distinct")
    out.append("in_group_having")
    out.append("in_join_body")
    out.append("in_expr_body")
    out.append("in_agg_body")
    out.append("in_limit_body")
    return out^


def _not_in() -> List[String]:
    var out = List[String]()
    out.append("not_in_with_nulls")
    out.append("not_in_null_free")
    out.append("not_in_empty")
    out.append("not_in_int32")
    out.append("not_in_int32_nulls")
    out.append("not_in_string")
    out.append("not_in_and_filter")
    out.append("not_in_count")
    out.append("not_in_list")
    out.append("not_in_list_null")
    return out^


def _not_in_whole_body() -> List[String]:
    var out = List[String]()
    out.append("not_in_distinct_nulls")
    out.append("not_in_distinct_null_free")
    out.append("not_in_group_having_nulls")
    out.append("not_in_group_having_null_free")
    out.append("not_in_group_empty")
    out.append("not_in_expr_body_nulls")
    out.append("not_in_expr_body_null_free")
    out.append("not_in_limit_body")
    return out^


def test_scalar_subqueries_in_a_where_equal_duckdb() raises:
    _check_all(_scalar_in_where())


def test_empty_and_limit_scalar_bodies_equal_duckdb() raises:
    _check_all(_scalar_empty_and_limit())


def test_scalar_subqueries_in_other_positions_equal_duckdb() raises:
    _check_all(_scalar_positions())


def test_in_subqueries_equal_duckdb() raises:
    _check_all(_in())


def test_in_over_a_whole_body_equals_duckdb() raises:
    _check_all(_in_whole_body())


def test_not_in_is_null_aware_like_duckdb() raises:
    _check_all(_not_in())


def test_not_in_over_a_whole_body_is_null_aware_like_duckdb() raises:
    _check_all(_not_in_whole_body())


comptime _UNRESOLVED = "OPTIMIZE_UNRESOLVED_SCALAR: the plan needs a scalar subquery executed first"


def test_a_scalar_body_of_several_rows_is_refused_at_optimize() raises:
    _refused(
        "SELECT t.id AS id FROM read_parquet('t.parquet') t WHERE t.v = (SELECT u.v FROM read_parquet('u.parquet') u WHERE u.k = 4)",
        String(STEP_OPTIMIZE),
        String(_UNRESOLVED),
    )


def test_a_varchar_limit_body_is_refused_at_optimize() raises:
    _refused(
        "SELECT t.id AS id FROM read_parquet('t.parquet') t WHERE t.s = (SELECT u.s FROM read_parquet('u.parquet') u WHERE u.id = 1 LIMIT 1)",
        String(STEP_OPTIMIZE),
        String(_UNRESOLVED),
    )


def test_in_on_keys_the_hash_join_does_not_serve_is_refused_at_lower() raises:
    _refused(
        "SELECT t.id AS id FROM read_parquet('t.parquet') t WHERE t.d IN (SELECT u.d FROM read_parquet('u.parquet') u)",
        String(STEP_LOWER),
        "LOWERING_JOIN_UNSERVED: Join (the key pair d (decimal128) = d (decimal128)) is not served by the hash join",
    )
    _refused(
        "SELECT t.id AS id FROM read_parquet('t.parquet') t WHERE t.dt NOT IN (SELECT u.dt FROM read_parquet('u.parquet') u)",
        String(STEP_LOWER),
        "LOWERING_JOIN_UNSERVED: Join (the key pair dt (date32) = dt (date32)) is not served by the hash join",
    )


def test_in_with_an_expression_on_the_left_is_refused_at_parse() raises:
    _refused(
        "SELECT t.id AS id FROM read_parquet('t.parquet') t WHERE t.k + 1 IN (SELECT u.k FROM read_parquet('u.parquet') u)",
        String(STEP_PARSE),
        "SQL not supported: `IN (subquery)` requires a column on the left",
    )


def test_a_predicate_subquery_in_a_having_is_refused_at_bind() raises:
    _refused(
        "SELECT k, count(*) AS n FROM read_parquet('t.parquet') t GROUP BY k HAVING k IN (SELECT k FROM read_parquet('u.parquet') u)",
        String(STEP_BIND),
        "SQL not supported: an EXISTS or IN subquery in a HAVING clause or in the"
        " SELECT list of a grouped query (a scalar subquery is served there; a"
        " predicate subquery is served as a WHERE conjunct)",
    )


def test_every_case_is_run() raises:
    var known = _scalar_in_where()
    known.extend(_scalar_empty_and_limit())
    known.extend(_scalar_positions())
    known.extend(_in())
    known.extend(_in_whole_body())
    known.extend(_not_in())
    known.extend(_not_in_whole_body())
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
