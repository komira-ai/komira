# =============================================================================
# test_run_sql_join_kinds: LEFT, RIGHT, FULL, SEMI, ANTI and CROSS joins answer
# what DuckDB answers
# =============================================================================
#
# Covers: run_sql over small Parquet tables DuckDB wrote (the
# :join_kinds_oracle action in BUCK; several row groups, NULL, duplicate and
# unmatched keys, an empty table) answers what the pinned DuckDB answers for
# each case of tests/join_kinds/cases.sql, on one and three workers: LEFT,
# RIGHT and FULL joins on BIGINT, VARCHAR, INTEGER = BIGINT, DOUBLE and
# two-column keys, under counts, filters and chained joins, and against an
# empty table on either side; SEMI and ANTI joins as EXISTS, NOT EXISTS, IN,
# NOT IN (NULL-aware) and the SEMI JOIN and ANTI JOIN keywords; CROSS joins
# (also past one output chunk), a comma join and uncorrelated scalar
# subqueries; a LEFT JOIN with a residual over both sides is still refused at
# lower; every case is run.
#
# The pinned DuckDB writes the tables (tests/join_kinds/data.sql: l and r in
# small row groups, each with NULL, duplicate and unmatched keys of BIGINT,
# VARCHAR, INTEGER and DOUBLE; n, a BIGINT column without NULL; e, the columns
# of r and no row; big, 300 rows) and answers each query of
# tests/join_kinds/cases.sql as a build action (`sql_oracle`). This test reads
# the same cases.sql for the query text, runs it through `run_sql` (parse, bind,
# optimize, lower to a hash build segment and a fused probe, run on the
# pipeline) over the same Parquet files, and compares the answer with DuckDB's
# by value, rows as a multiset (komira_plan_harness): the same rows, the NULL
# padding of an unmatched row, the same aggregates. Every case runs on one
# worker and on three, so a RIGHT or FULL join's unmatched build rows are
# found after the workers' matches are merged.
#
#   test_left_right_and_full_joins_on_an_int64_key_equal_duckdb
#                                            LEFT, RIGHT and FULL OUTER JOIN on a BIGINT key with NULL, duplicate and
#                                            unmatched keys on both sides, and the LEFT OUTER spelling.
#   test_outer_joins_on_other_key_types_equal_duckdb
#                                            LEFT, RIGHT and FULL on a VARCHAR key (the empty string and
#                                            NULL included), on an INTEGER = BIGINT key, on an
#                                            INTEGER = INTEGER key, a DOUBLE key, and on two keys.
#   test_outer_joins_under_aggregates_filters_and_chains_equal_duckdb
#                                            count(*) and count(col) per group over LEFT and RIGHT, an
#                                            ungrouped count over FULL, a right-only ON conjunct,
#                                            the anti-join idiom (WHERE r.rk IS NULL), a WHERE on
#                                            the left side, two LEFT joins in a row, and an INNER
#                                            join followed by a RIGHT join.
#   test_outer_joins_against_an_empty_table_equal_duckdb
#                                            LEFT, RIGHT and FULL with the zero-row table as the build
#                                            side and as the probe side: rows kept NULL-padded or
#                                            none, as DuckDB gives.
#   test_semi_and_anti_joins_equal_duckdb
#                                            EXISTS and NOT EXISTS (one key, two keys, an inner
#                                            filter, a VARCHAR key, an empty table), IN (SELECT)
#                                            on BIGINT, INTEGER = BIGINT and VARCHAR keys, the SEMI
#                                            JOIN and ANTI JOIN keywords, and a count over EXISTS.
#   test_not_in_is_null_aware_like_duckdb
#                                            NOT IN (SELECT) over a column holding NULL gives no
#                                            row; over a column without NULL the NULL left key is
#                                            dropped; over an empty subquery (filtered, or an empty
#                                            table) every row, the NULL key included, is kept; over
#                                            a subquery whose NULLs are filtered out the NULL left
#                                            key is dropped; on BIGINT and VARCHAR.
#   test_cross_joins_and_scalar_subqueries_equal_duckdb
#                                            CROSS JOIN rows, a comma join with no WHERE, counts
#                                            over a CROSS join, an empty build and an empty probe
#                                            side, a CROSS join of 90000 rows (past one output
#                                            chunk), and uncorrelated scalar subqueries compared
#                                            with a column.
#   test_a_left_join_with_a_residual_over_both_sides_is_refused_by_lowering
#                                            a LEFT JOIN whose ON holds a
#                                            conjunct over both sides is
#                                            refused at step `lower` with
#                                            LOWERING_JOIN_UNSERVED naming
#                                            the residual predicate.
#   test_a_right_join_after_an_inner_join_on_is_refused_at_parse
#                                            an INNER JOIN ... ON followed by a
#                                            RIGHT JOIN is refused at step
#                                            `parse` by name (its folded ON
#                                            would drop the padded rows).
#   test_every_case_is_run                   each case of cases.sql belongs to
#                                            one of the tests above.
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
from sdk_exec.engine_sql import STEP_LOWER, STEP_PARSE, run_sql


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
    var text = query.replace("'l.parquet'", "'" + data_path("l.parquet") + "'")
    text = text.replace("'r.parquet'", "'" + data_path("r.parquet") + "'")
    text = text.replace("'n.parquet'", "'" + data_path("n.parquet") + "'")
    text = text.replace("'e.parquet'", "'" + data_path("e.parquet") + "'")
    text = text.replace("'big.parquet'", "'" + data_path("big.parquet") + "'")
    return text^


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
    for i in range(len(names)):
        _check(names[i], 1, problems)
        _check(names[i], 3, problems)
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def _left_right_full_int64() -> List[String]:
    var out = List[String]()
    out.append("left_rows")
    out.append("right_rows")
    out.append("full_rows")
    out.append("left_outer_keyword")
    return out^


def _left_right_full_other_keys() -> List[String]:
    var out = List[String]()
    out.append("left_string")
    out.append("right_string")
    out.append("full_string")
    out.append("left_int32_int64")
    out.append("right_int32_int64")
    out.append("full_int32_int64")
    out.append("full_int32_int32")
    out.append("left_double")
    out.append("full_double")
    out.append("left_two_keys")
    out.append("right_two_keys")
    out.append("full_two_keys")
    return out^


def _left_right_full_aggregates_and_filters() -> List[String]:
    var out = List[String]()
    out.append("left_count")
    out.append("right_count")
    out.append("full_count")
    out.append("left_right_conjunct")
    out.append("left_anti_idiom")
    out.append("left_where_left")
    out.append("left_chain")
    out.append("inner_then_left")
    return out^


def _empty_sides() -> List[String]:
    var out = List[String]()
    out.append("left_empty_build")
    out.append("left_empty_probe")
    out.append("right_empty_build")
    out.append("right_empty_probe")
    out.append("full_empty_build")
    out.append("full_empty_probe")
    return out^


def _semi_and_anti() -> List[String]:
    var out = List[String]()
    out.append("exists")
    out.append("exists_inner_filter")
    out.append("exists_two_keys")
    out.append("exists_string")
    out.append("not_exists")
    out.append("not_exists_two_keys")
    out.append("exists_empty")
    out.append("not_exists_empty")
    out.append("in_subquery")
    out.append("in_int32_int64")
    out.append("in_string")
    out.append("semi_keyword")
    out.append("anti_keyword")
    out.append("semi_count")
    return out^


def _not_in() -> List[String]:
    var out = List[String]()
    out.append("not_in_with_nulls")
    out.append("not_in_null_free")
    out.append("not_in_empty_filtered")
    out.append("not_in_empty_table")
    out.append("not_in_nulls_filtered")
    out.append("not_in_string_nulls_filtered")
    out.append("not_in_string_with_nulls")
    return out^


def _cross_and_scalar() -> List[String]:
    var out = List[String]()
    out.append("cross_rows")
    out.append("comma_rows")
    out.append("cross_count")
    out.append("cross_empty_build")
    out.append("cross_empty_probe")
    out.append("cross_chunked")
    out.append("scalar_max")
    out.append("scalar_count")
    return out^


def test_left_right_and_full_joins_on_an_int64_key_equal_duckdb() raises:
    _check_all(_left_right_full_int64())


def test_outer_joins_on_other_key_types_equal_duckdb() raises:
    _check_all(_left_right_full_other_keys())


def test_outer_joins_under_aggregates_filters_and_chains_equal_duckdb() raises:
    _check_all(_left_right_full_aggregates_and_filters())


def test_outer_joins_against_an_empty_table_equal_duckdb() raises:
    _check_all(_empty_sides())


def test_semi_and_anti_joins_equal_duckdb() raises:
    _check_all(_semi_and_anti())


def test_not_in_is_null_aware_like_duckdb() raises:
    _check_all(_not_in())


def test_cross_joins_and_scalar_subqueries_equal_duckdb() raises:
    _check_all(_cross_and_scalar())


def test_a_left_join_with_a_residual_over_both_sides_is_refused_by_lowering() raises:
    var query = (
        "SELECT l.lk AS lk, r.rk AS rk FROM read_parquet('l.parquet') l LEFT"
        " JOIN read_parquet('r.parquet') r ON l.lk = r.rk AND l.lv < r.rv"
    )
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var out = run_sql(ctx, _with_paths(query))
    assert_false(out.ok(), "expected a refusal")
    assert_equal(out.refusal.value().step, String(STEP_LOWER))
    assert_equal(
        out.refusal.value().reason,
        "LOWERING_JOIN_UNSERVED: Join (a residual predicate) is not served by"
        " the hash join",
    )
    assert_equal(len(out.batches), 0)


def test_a_right_join_after_an_inner_join_on_is_refused_at_parse() raises:
    var query = (
        "SELECT l.lk AS lk, r.rv AS rv, n.nk AS nk FROM read_parquet('l.parquet')"
        " l JOIN read_parquet('r.parquet') r ON l.lk = r.rk RIGHT JOIN"
        " read_parquet('n.parquet') n ON r.rk = n.nk"
    )
    var ctx = EngineContext(EngineOptions(worker_count=2))
    var out = run_sql(ctx, _with_paths(query))
    assert_false(out.ok(), "expected a refusal")
    assert_equal(out.refusal.value().step, String(STEP_PARSE))
    assert_true(
        out.refusal.value().reason.startswith(
            "SQL not supported: a RIGHT or FULL JOIN after an INNER JOIN"
        ),
        out.refusal.value().reason,
    )
    assert_equal(len(out.batches), 0)


def test_every_case_is_run() raises:
    var known = _left_right_full_int64()
    known.extend(_left_right_full_other_keys())
    known.extend(_left_right_full_aggregates_and_filters())
    known.extend(_empty_sides())
    known.extend(_semi_and_anti())
    known.extend(_not_in())
    known.extend(_cross_and_scalar())
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
