# =============================================================================
# test_run_sql_date_shift: a DATE column plus or minus an INTERVAL or an
# integer answers what DuckDB answers
# =============================================================================
#
# Covers: run_sql over a Parquet table the pinned DuckDB writes (the
# :date_shift_oracle action in BUCK; orders(id, order_date, ship_date), two
# DATE columns with a NULL in each) answers what DuckDB answers for each query
# of tests/date_shift/cases.sql, on one and on three workers. The table's dates
# cover the month-end clamp (31 Jan, 31 Mar, 29 Feb), a non-leap 31 Jan, a date
# before 1970 and a ship date exactly seven days after its order date.
#
# The pinned DuckDB writes the table (tests/date_shift/data.sql) and answers
# each query of tests/date_shift/cases.sql as a build action (`sql_oracle`).
# This test reads the same cases.sql for the query text, runs it through
# `run_sql` over the same Parquet file, and compares the answer with DuckDB's
# by value and column name, rows as a multiset (komira_plan_harness). The type
# of the shifted column is held to DuckDB's too, which the comparison by value
# alone would not see: TIMESTAMP for an INTERVAL, DATE for an integer.
#
#   test_a_date_shifted_by_an_interval_equals_duckdb_and_is_a_timestamp
#       `order_date + INTERVAL '7' DAY`; `+ INTERVAL '1' MONTH` clamping 31 Jan
#       2024 to 29 Feb and 31 Jan 2023 to 28 Feb; `- INTERVAL '1' YEAR`
#       taking 29 Feb 2024 to 28 Feb 2023; `- INTERVAL '1' MONTH`;
#       `INTERVAL '2' WEEK + order_date`; `date_add(order_date, INTERVAL '1'
#       MONTH)`; a negative count; a chain of a month and a day. The NULL
#       order date stays NULL in each.
#   test_a_date_shifted_by_an_integer_equals_duckdb_and_is_a_date
#       `order_date + 7`, `order_date - 30`, `3 + order_date`, `order_date +
#       -5`.
#   test_a_date_compared_with_a_shifted_date_equals_duckdb
#       `ship_date > order_date + INTERVAL '7' DAY` and `ship_date >
#       order_date + 7`; the row whose ship date is exactly seven days later
#       is not in the first answer.
#   test_a_column_valued_interval_is_refused_by_name
#       `INTERVAL (id) DAY` and a date plus an integer column are refused at
#       their own steps (the parser, the binder) with their own messages.
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
    """The first column named `shifted` (a TIMESTAMP in DuckDB) or `moved` (a
    DATE) whose type is not DuckDB's, or ""."""
    for c in range(batch.schema.num_columns()):
        var n = batch.schema.field_name(c)
        var t = batch.schema.field_arrow_type(c)
        var want = ArrowType.NULL
        if n == "shifted":
            want = ArrowType.TIMESTAMP_US
        elif n == "moved":
            want = ArrowType.DATE32
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
        "'orders.parquet'", "'" + data_path("orders.parquet") + "'"
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


def _intervals() -> List[String]:
    var out = List[String]()
    out.append("plus_days_interval")
    out.append("plus_month_clamps")
    out.append("minus_year_clamps")
    out.append("minus_month_interval")
    out.append("interval_on_left")
    out.append("date_add_form")
    out.append("negative_count_interval")
    out.append("interval_chain")
    return out^


def _integers() -> List[String]:
    var out = List[String]()
    out.append("plus_integer")
    out.append("minus_integer")
    out.append("integer_on_left")
    out.append("negative_integer")
    return out^


def _filters() -> List[String]:
    var out = List[String]()
    out.append("probe_ship_after_a_week")
    out.append("filter_on_integer_shift")
    return out^


def test_a_date_shifted_by_an_interval_equals_duckdb_and_is_a_timestamp() raises:
    _check_all(_intervals())


def test_a_date_shifted_by_an_integer_equals_duckdb_and_is_a_date() raises:
    _check_all(_integers())


def test_a_date_compared_with_a_shifted_date_equals_duckdb() raises:
    _check_all(_filters())


def _refusal_reason(sql: String, step: String) raises -> String:
    var ctx = EngineContext(EngineOptions(worker_count=1))
    var out = run_sql(
        ctx,
        sql.replace("'orders.parquet'", "'" + data_path("orders.parquet") + "'"),
    )
    assert_true(Bool(out.refusal), "expected a refusal: " + sql)
    assert_equal(out.refusal.value().step, step, sql)
    return out.refusal.value().reason


def test_a_column_valued_interval_is_refused_by_name() raises:
    var interval = _refusal_reason(
        "SELECT order_date + INTERVAL (id) DAY AS shifted FROM read_parquet('orders.parquet')",
        "parse",
    )
    assert_true("non-constant count" in interval, interval)
    var bare = _refusal_reason(
        "SELECT order_date + INTERVAL id DAY AS shifted FROM read_parquet('orders.parquet')",
        "parse",
    )
    assert_true("non-constant count" in bare, bare)


def test_a_date_plus_an_integer_column_is_refused_by_name() raises:
    var reason = _refusal_reason(
        "SELECT order_date + id AS moved FROM read_parquet('orders.parquet')",
        "bind",
    )
    assert_true("add a constant number of days" in reason, reason)


def test_every_case_is_run() raises:
    var known = _intervals()
    known.extend(_integers())
    known.extend(_filters())
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
