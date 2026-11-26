# =============================================================================
# test_run_sql_set_ops: INTERSECT and EXCEPT through run_sql answer what DuckDB
# answers
# =============================================================================
#
# Covers: INTERSECT and EXCEPT through run_sql answer what the pinned DuckDB
# answers (the :set_ops_oracle action in BUCK) for each case of
# tests/set_ops/cases.sql, on one worker and on three: NULL rows equal, an
# all-NULL and an empty input, repeated rows, several columns of mixed types,
# one column of each key type, NaN, inputs widened to a common type, INTERSECT
# binding tighter than UNION ALL and EXCEPT, a sort and an aggregation over the
# result; every case is run; INTERSECT ALL and EXCEPT ALL are refused at parse
# by name.
#
# The pinned DuckDB writes the tables (tests/set_ops/data.sql: the four
# two-column arms of the conformance corpus's set_operations cases, NULL keys
# and an all-NULL and an empty arm among them, and two files of mixed column
# types whose rows repeat and partly overlap) and answers each query of
# tests/set_ops/cases.sql as a build action (`sql_oracle`). This test reads the
# same cases.sql for the query text, runs it through `run_sql` (parse, bind
# INTERSECT / EXCEPT onto a union, a grouped aggregation and a filter,
# optimize, lower, run) over the same Parquet files, and compares the answer
# with DuckDB's by value, rows as a multiset (komira_plan_harness), so a row
# returned twice, a missing NULL row or an extra row each fail.
#
#   test_the_corpus_arms_equal_duckdb
#                       two columns with NULLs: INTERSECT keeps the all-NULL
#                       row both arms hold, EXCEPT in both directions, one
#                       column; an all-NULL arm (its three rows are one), an
#                       empty arm on either side.
#   test_mixed_columns_equal_duckdb
#                       INTERSECT and EXCEPT over an INTEGER, a VARCHAR (with
#                       the empty string), a DATE and a DECIMAL(12, 2) whose
#                       rows repeat; a file intersected with itself.
#   test_each_key_type_equals_duckdb
#                       one column of INTEGER, BIGINT, VARCHAR (under a WHERE
#                       in each input), DATE, DECIMAL and DOUBLE (NaN equal to
#                       NaN, in INTERSECT and EXCEPT).
#   test_widened_inputs_equal_duckdb
#                       INTEGER with BIGINT, DECIMAL with INTEGER, INTEGER with
#                       DOUBLE: the inputs are compared in their common type.
#   test_precedence_equals_duckdb
#                       INTERSECT binds tighter than UNION ALL and EXCEPT on
#                       either side of them; EXCEPT twice folds left to right;
#                       UNION ALL then EXCEPT, EXCEPT then UNION ALL.
#   test_what_surrounds_a_set_operation_equals_duckdb
#                       ORDER BY after the last branch, count(*) and
#                       GROUP BY over a derived INTERSECT / EXCEPT, a SELECT
#                       DISTINCT input, FROM-less literal inputs.
#   test_every_case_is_run
#                       each case of cases.sql belongs to one of the tests
#                       above.
#   test_the_all_forms_are_refused_by_name
#                       INTERSECT ALL and EXCEPT ALL are refused at parse with
#                       their own names, not answered as the set forms.
#
# Every case runs on one worker and on three, so the workers' partial group
# tables are merged.
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


def _with_paths(query: String) raises -> String:
    """`query` with each quoted Parquet file name replaced by its path."""
    var files: List[String] = ["ta", "tb", "tn", "te", "ab", "l", "r"]
    var text = query
    for i in range(len(files)):
        var name = files[i] + ".parquet"
        text = text.replace("'" + name + "'", "'" + data_path(name) + "'")
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


def _check_all(names: List[String]) raises:
    var problems = List[String]()
    for i in range(len(names)):
        _check(names[i], 1, problems)
        _check(names[i], 3, problems)
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def _arms() -> List[String]:
    return List[String]([
        "arms_intersect", "arms_except", "arms_except_reversed",
        "arms_intersect_k", "null_arm_intersect", "null_arm_except",
        "null_arm_self_except", "empty_arm_intersect", "empty_arm_except",
        "empty_left_except",
    ])


def _mixed() -> List[String]:
    return List[String]([
        "mixed_intersect", "mixed_except", "mixed_except_reversed",
        "mixed_self_intersect",
    ])


def _key_types() -> List[String]:
    return List[String]([
        "int_except", "bigint_intersect", "string_except", "date_intersect",
        "decimal_except", "double_nan_intersect", "double_nan_except",
    ])


def _widened() -> List[String]:
    return List[String](
        ["widen_int_bigint", "widen_decimal_int", "widen_int_double"]
    )


def _precedence() -> List[String]:
    return List[String]([
        "union_all_then_intersect", "intersect_then_union_all",
        "except_then_intersect", "except_twice", "union_all_then_except",
        "except_then_union_all",
    ])


def _surroundings() -> List[String]:
    return List[String]([
        "order_by", "count_over_derived", "group_over_derived",
        "distinct_inputs", "literals",
    ])


def test_the_corpus_arms_equal_duckdb() raises:
    _check_all(_arms())


def test_mixed_columns_equal_duckdb() raises:
    _check_all(_mixed())


def test_each_key_type_equals_duckdb() raises:
    _check_all(_key_types())


def test_widened_inputs_equal_duckdb() raises:
    _check_all(_widened())


def test_precedence_equals_duckdb() raises:
    _check_all(_precedence())


def test_what_surrounds_a_set_operation_equals_duckdb() raises:
    _check_all(_surroundings())


def test_every_case_is_run() raises:
    var known = _arms()
    known.extend(_mixed())
    known.extend(_key_types())
    known.extend(_widened())
    known.extend(_precedence())
    known.extend(_surroundings())
    var cases = _cases()
    assert_equal(len(cases), len(known), "cases in cases.sql")
    for i in range(len(cases)):
        var found = False
        for j in range(len(known)):
            if cases[i].name == known[j]:
                found = True
        assert_true(found, cases[i].name + " belongs to no test")


def test_the_all_forms_are_refused_by_name() raises:
    var words: List[String] = ["INTERSECT", "EXCEPT"]
    for i in range(len(words)):
        var ctx = EngineContext(EngineOptions(worker_count=1))
        var out = run_sql(
            ctx,
            _with_paths(
                "SELECT k FROM read_parquet('ta.parquet') " + words[i]
                + " ALL SELECT k FROM read_parquet('tb.parquet')"
            ),
        )
        assert_true(Bool(out.refusal), words[i] + " ALL answered")
        assert_true(
            out.refusal.value().reason.startswith(
                "SQL not supported: " + words[i] + " ALL."
            ),
            out.refusal.value().reason,
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
