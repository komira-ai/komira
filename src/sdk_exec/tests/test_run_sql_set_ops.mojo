# =============================================================================
# test_run_sql_set_ops: UNION, INTERSECT and EXCEPT through run_sql answer what
# DuckDB answers
# =============================================================================
#
# The pinned DuckDB writes the tables (tests/set_ops/data.sql: the two-column
# arms of the conformance corpus's set_operations cases, NULL keys, an all-NULL
# and an empty arm and a VARCHAR-keyed arm among them, two one-column DOUBLE
# files holding 0.0 and -0.0, and two files of mixed column types whose rows
# repeat and partly overlap) and answers each query of tests/set_ops/cases.sql
# as a build action (`sql_oracle`). This test reads the same cases.sql for the
# query text, runs it through `run_sql` (parse, bind UNION onto a distinct over
# a union and INTERSECT / EXCEPT onto a union, a grouped aggregation and a
# filter, optimize, lower, run) over the same Parquet files, and compares the answer
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
#   test_the_corpus_unions_equal_duckdb
#                       the conformance corpus's bare-UNION cases: one and two
#                       columns, three branches, an empty, an all-NULL and the
#                       same arm, a UNION in a CTE and in a derived table under
#                       count(*), a scan with a literal, a UNION before an
#                       INTERSECT (the INTERSECT binds first), BIGINT with
#                       VARCHAR (the key widened to VARCHAR, so 3 and '3' are
#                       one row).
#   test_union_forms_and_key_types_equal_duckdb
#                       UNION DISTINCT; an empty left arm; four columns of
#                       mixed types whose rows repeat across and within the
#                       files; one VARCHAR key with the empty string; one
#                       DOUBLE key with NaN (every NaN one row) and one with
#                       0.0 in one input and -0.0 in the other; INTEGER with
#                       BIGINT; VARCHAR with BIGINT; BIGINT with VARCHAR under
#                       UNION ALL, INTERSECT and EXCEPT (the widening is every
#                       set operation's); INTEGER with VARCHAR.
#   test_union_precedence_equals_duckdb
#                       a UNION ALL after a UNION keeps its duplicates; a
#                       UNION after a UNION ALL dedups everything to its left;
#                       UNION ALL, UNION, UNION ALL in one chain; UNION then
#                       EXCEPT and EXCEPT then UNION fold left to right; an
#                       INTERSECT before a UNION binds first; a chain in a CTE.
#   test_what_surrounds_a_union_equals_duckdb
#                       ORDER BY, LIMIT and OFFSET after the last branch;
#                       GROUP BY over a derived UNION; FROM-less literal
#                       branches.
#   test_every_case_is_run
#                       each case of cases.sql belongs to one of the tests
#                       above.
#   test_the_all_forms_are_refused_by_name
#                       INTERSECT ALL and EXCEPT ALL are refused at parse with
#                       their own names, not answered as the set forms, also
#                       after a UNION.
#
# Every case runs on one worker and on three, so the workers' partial group
# and distinct tables are merged.
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
from sdk_exec.engine_sql import STEP_PARSE, run_sql


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
    var files: List[String] = [
        "ta", "tb", "tn", "te", "tv", "ab", "z0", "zn", "l", "r"
    ]
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


def _corpus_unions() -> List[String]:
    return List[String]([
        "union_basic", "union_twocol", "union_three_arms", "union_empty_arm",
        "union_allnull_arm", "union_self", "union_in_cte", "union_in_derived",
        "union_scan_vs_literal", "union_then_intersect",
        "union_widen_int_varchar",
    ])


def _union_forms() -> List[String]:
    return List[String]([
        "union_distinct_twocol", "union_empty_left", "union_mixed",
        "union_varchar_key", "union_double_nan", "union_double_zero",
        "union_widen_int_bigint", "union_varchar_then_bigint",
        "union_all_widen_int_varchar", "union_widen_integer_varchar",
        "intersect_widen_int_varchar", "except_widen_varchar_int",
    ])


def _union_precedence() -> List[String]:
    return List[String]([
        "union_then_union_all", "union_all_then_union",
        "union_all_union_union_all", "union_then_except", "except_then_union",
        "intersect_then_union", "intersect_in_cte",
    ])


def _union_surroundings() -> List[String]:
    return List[String](
        ["union_order_by_limit", "union_group_over_derived", "union_literals"]
    )


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


def test_the_corpus_unions_equal_duckdb() raises:
    _check_all(_corpus_unions())


def test_union_forms_and_key_types_equal_duckdb() raises:
    _check_all(_union_forms())


def test_union_precedence_equals_duckdb() raises:
    _check_all(_union_precedence())


def test_what_surrounds_a_union_equals_duckdb() raises:
    _check_all(_union_surroundings())


def test_every_case_is_run() raises:
    var known = _arms()
    known.extend(_mixed())
    known.extend(_key_types())
    known.extend(_widened())
    known.extend(_precedence())
    known.extend(_surroundings())
    known.extend(_corpus_unions())
    known.extend(_union_forms())
    known.extend(_union_precedence())
    known.extend(_union_surroundings())
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
    # Each ALL form as the first operator and after a UNION.
    var heads: List[String] = [
        "SELECT k FROM read_parquet('ta.parquet') ",
        "SELECT k FROM read_parquet('ta.parquet') UNION"
        " SELECT k FROM read_parquet('tn.parquet') ",
    ]
    for h in range(len(heads)):
        for i in range(len(words)):
            var ctx = EngineContext(EngineOptions(worker_count=1))
            var out = run_sql(
                ctx,
                _with_paths(
                    heads[h] + words[i]
                    + " ALL SELECT k FROM read_parquet('tb.parquet')"
                ),
            )
            assert_true(Bool(out.refusal), words[i] + " ALL answered")
            assert_equal(out.refusal.value().step, String(STEP_PARSE))
            assert_true(
                out.refusal.value().reason.startswith(
                    "SQL not supported: " + words[i] + " ALL."
                ),
                out.refusal.value().reason,
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
