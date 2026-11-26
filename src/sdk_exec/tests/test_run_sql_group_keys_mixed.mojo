# =============================================================================
# test_run_sql_group_keys_mixed: GROUP BY keys of mixed types answers what
# DuckDB answers
# =============================================================================
#
# Covers: run_sql over a Parquet table the pinned DuckDB writes (the
# :group_keys_mixed_oracle action in BUCK; five row groups, NULLs in every
# column, the empty string) answers what DuckDB answers for each query of
# tests/group_keys_mixed/cases.sql, on one and on three workers: GROUP BY an
# INTEGER, a VARCHAR and a DATE (in both orders, with count, sum, min and max),
# a BIGINT and an INTEGER, a BOOLEAN, a DECIMAL and a VARCHAR; under a WHERE
# and a HAVING; count(DISTINCT) per mixed key; SELECT DISTINCT over three
# columns; an all-NULL key; no row; every case is run.
#
# The pinned DuckDB writes the table (tests/group_keys_mixed/data.sql: 10000
# rows in five row groups, an INTEGER, a BIGINT, a VARCHAR, a DATE, a
# DECIMAL(12, 2), a BOOLEAN and a BIGINT value column, each with NULLs at a
# period of its own, the VARCHAR also holding the empty string) and answers
# each query of tests/group_keys_mixed/cases.sql as a build action
# (`sql_oracle`). This test reads the same cases.sql for the query text, runs
# it through `run_sql` (parse, bind, optimize, lower to a SINK_AGG segment of
# the COMPOSITE row, run on the pipeline) over the same Parquet file, and
# compares the answer with DuckDB's by value, rows as a multiset
# (komira_plan_harness): the same groups, the NULL of each key column a value
# of its own and the empty string another, the same aggregates. Each key
# column of the answer also keeps the type the table declares for it (i
# INT32, big INT64, s STRING, d DATE32, m DECIMAL128 (12, 2), b BOOL), which
# the comparison by value alone would not see.
#
#   test_int_string_date_keys_equal_duckdb   GROUP BY i, s, d with count(*),
#                                            count(v), sum(v), min(v), max(v),
#                                            and GROUP BY d, s, i (the key
#                                            columns in their order).
#   test_other_mixed_keys_equal_duckdb       GROUP BY a BIGINT and an INTEGER;
#                                            a BOOLEAN, a DECIMAL and a
#                                            VARCHAR with sum of the decimal.
#   test_mixed_keys_under_where_having_and_distinct_equal_duckdb
#                                            a WHERE before the grouping, a
#                                            HAVING after it, count(DISTINCT s)
#                                            per (i, d), SELECT DISTINCT over
#                                            three columns.
#   test_an_all_null_key_and_no_row_equal_duckdb
#                                            rows whose two keys are both NULL
#                                            are one group; a WHERE no row
#                                            passes gives no group.
#   test_every_case_is_run                   each case of cases.sql belongs to
#                                            one of the tests above.
#
# Every case runs on one worker and on three, so the workers' partial tables
# (strings interned in different orders) are merged.
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


def _key_type_problem(ref batch: RecordBatch) -> String:
    """The first key column whose type is not the table's, or ""."""
    for c in range(batch.schema.num_columns()):
        var n = batch.schema.field_name(c)
        var t = batch.schema.field_arrow_type(c)
        var want = ArrowType.NULL
        if n == "i":
            want = ArrowType.INT32
        elif n == "big":
            want = ArrowType.INT64
        elif n == "s":
            want = ArrowType.STRING
        elif n == "d":
            want = ArrowType.DATE32
        elif n == "m":
            want = ArrowType.DECIMAL128
        elif n == "b":
            want = ArrowType.BOOL
        else:
            continue
        if t != want:
            return "key " + n + " is " + String(t) + ", the table's " + String(want)
        if n == "m" and (
            batch.schema.field_decimal_precision(c) != 12
            or batch.schema.field_decimal_scale(c) != 2
        ):
            return "key m is not DECIMAL(12, 2)"
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
        "'mixed.parquet'", "'" + data_path("mixed.parquet") + "'"
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
    var typed = _key_type_problem(out.batches[0])
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


def _int_string_date() -> List[String]:
    var out = List[String]()
    out.append("int_string_date")
    out.append("date_string_int")
    return out^


def _other_keys() -> List[String]:
    var out = List[String]()
    out.append("bigint_int")
    out.append("bool_decimal_string")
    return out^


def _clauses() -> List[String]:
    var out = List[String]()
    out.append("filtered")
    out.append("having")
    out.append("count_distinct")
    out.append("distinct")
    return out^


def _edges() -> List[String]:
    var out = List[String]()
    out.append("all_null")
    out.append("no_row")
    return out^


def test_int_string_date_keys_equal_duckdb() raises:
    _check_all(_int_string_date())


def test_other_mixed_keys_equal_duckdb() raises:
    _check_all(_other_keys())


def test_mixed_keys_under_where_having_and_distinct_equal_duckdb() raises:
    _check_all(_clauses())


def test_an_all_null_key_and_no_row_equal_duckdb() raises:
    _check_all(_edges())


def test_every_case_is_run() raises:
    var known = _int_string_date()
    known.extend(_other_keys())
    known.extend(_clauses())
    known.extend(_edges())
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
