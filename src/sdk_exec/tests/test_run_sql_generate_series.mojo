# =============================================================================
# test_run_sql_generate_series: generate_series and range in FROM through
# run_sql answer what DuckDB answers
# =============================================================================
#
# Covers: `generate_series(...)` and `range(...)` as table functions in FROM,
# run through run_sql (parse, bind, optimize, lower, run on three workers),
# answer what the pinned DuckDB answers (the :generate_series_oracle action in
# BUCK) for each case of tests/generate_series/cases.sql, in DuckDB's row
# order; the column of a series has DuckDB's name and type; a zero step, a
# column-valued argument and the scalar spelling are refused by name.
#
# The cases are the lines of tests/generate_series/cases.sql: the pinned DuckDB
# runs each query as a build action (`sql_oracle`) and writes its answer as a
# TSV; this test reads the same file for the query text, runs that text
# through `run_sql` and compares the answer with DuckDB's by value
# (komira_plan_harness). A case whose query has no ORDER BY over a join
# compares its rows as a multiset; every other case compares them in order,
# since a series yields its values in order.
#
#   test_an_integer_series_equals_duckdb
#                       generate_series stops at the bound and range before
#                       it; a step; a negative step; the one-argument forms
#                       (from 0); a step away from the bound, an empty range,
#                       a NULL bound and a NULL step give no rows; an alias
#                       names the column; a series ending on the largest
#                       BIGINT; a filter; an aggregation over a million rows; a
#                       LIMIT over a series of 2^62 rows; two series joined;
#                       the column is a BIGINT named `range`.
#   test_a_date_or_timestamp_series_equals_duckdb
#                       a DATE series by day, week and month (the day held at
#                       the end of a shorter month and kept there), a range by
#                       year from a leap day, a TIMESTAMP series by hour across
#                       midnight, by month downwards, a range by 90 seconds;
#                       a DATE series is a TIMESTAMP column.
#   test_filling_gaps_equals_duckdb
#                       every day of a week LEFT JOINed with a per-day count
#                       and sum of a CSV, so a day without events is 0: the
#                       CSV's DATE key meets the series' TIMESTAMP at midnight,
#                       on either side of the `=`.
#   test_every_case_is_run
#                       each case of cases.sql belongs to one of the tests
#                       above, so none is skipped.
#   test_a_zero_step_is_refused
#                       an integer step of 0 and an INTERVAL of 0 are refused
#                       as DuckDB refuses them (`interval cannot be 0!`).
#   test_a_column_valued_argument_is_refused_by_name
#                       a bound that is a column (a LATERAL argument) is
#                       refused, naming the column.
#   test_the_scalar_spelling_stays_refused
#                       `range(3)` in the SELECT list (DuckDB's list-valued
#                       scalar) is refused, saying the FROM spelling is served.
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

comptime _DESCRIBE = "SELECT column_name, column_type FROM (DESCRIBE "


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
    return query.replace("'events.csv'", "'" + data_path("events.csv") + "'")


def _duckdb_type(t: ArrowType) -> String:
    if t == ArrowType.INT64:
        return "BIGINT"
    if t == ArrowType.TIMESTAMP_US:
        return "TIMESTAMP"
    return "arrow " + String(t)


def _run(
    text: String, mut problems: List[String], label: String
) raises -> Optional[RecordBatch]:
    var ctx = EngineContext(EngineOptions(worker_count=3))
    var out = run_sql(ctx, _with_path(text))
    if out.refusal:
        problems.append(
            label + ": refused at " + out.refusal.value().step + ": "
            + out.refusal.value().reason
        )
        return None
    if len(out.batches) != 1:
        problems.append(label + ": " + String(len(out.batches)) + " batches")
        return None
    return Optional(out.batches.pop(0))


def _check_types(c: _Case, mut problems: List[String]) raises:
    var head = String(_DESCRIBE)
    var inner = String(
        c.query[byte = head.byte_length() : c.query.byte_length() - 1]
    )
    var got = _run(inner, problems, c.name)
    if not got:
        return
    ref batch = got.value()
    var want = parse_duckdb_tsv(read_data(c.name + ".tsv"))
    var n = batch.schema.num_columns()
    if n != len(want.rows):
        problems.append(
            c.name + ": " + String(n) + " columns, DuckDB "
            + String(len(want.rows))
        )
        return
    for i in range(n):
        var name = batch.schema.field_name(i)
        var type_name = _duckdb_type(batch.schema.field_arrow_type(i))
        var want_name = want.rows[i][0].value()
        var want_type = want.rows[i][1].value()
        if name != want_name or type_name != want_type:
            problems.append(
                c.name + ": column " + String(i + 1) + " is " + name + " "
                + type_name + ", DuckDB " + want_name + " " + want_type
            )


def _check_rows(c: _Case, mut problems: List[String]) raises:
    var got = _run(c.query, problems, c.name)
    if not got:
        return
    var policy = CanonPolicy.total()
    if " JOIN " in c.query and "ORDER BY" not in c.query:
        policy = CanonPolicy.unordered()
    var actual = render_batch(got.value(), policy)
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
        ref c = cases[i]
        if not c.name.startswith(prefix):
            continue
        ran += 1
        if c.query.startswith(_DESCRIBE):
            _check_types(c, problems)
        else:
            _check_rows(c, problems)
    assert_true(ran >= 1, "cases.sql holds no case named " + prefix + "*")
    var text = String("")
    for i in range(len(problems)):
        text += "\n  " + problems[i]
    assert_equal(len(problems), 0, text)


def test_an_integer_series_equals_duckdb() raises:
    _check_prefix("int_")


def test_a_date_or_timestamp_series_equals_duckdb() raises:
    _check_prefix("date_")


def test_filling_gaps_equals_duckdb() raises:
    _check_prefix("fill_gaps_")


def test_every_case_is_run() raises:
    var cases = _cases()
    assert_true(
        len(cases) >= 29, "cases.sql holds " + String(len(cases)) + " cases"
    )
    for i in range(len(cases)):
        var name = cases[i].name
        assert_true(
            name.startswith("int_")
            or name.startswith("date_")
            or name.startswith("fill_gaps_"),
            name + " belongs to no test",
        )


# =============================================================================
# Refusals
# =============================================================================


def _reason(text: String) raises -> String:
    """The reason run_sql refuses `text` with; fails when it runs."""
    var ctx = EngineContext(EngineOptions(worker_count=1))
    var out = run_sql(ctx, text)
    assert_true(Bool(out.refusal), "ran, not refused: " + text)
    return out.refusal.value().reason


def test_a_zero_step_is_refused() raises:
    var ints = _reason("SELECT * FROM generate_series(1, 5, 0)")
    assert_true("interval cannot be 0!" in ints, ints)
    var days = _reason(
        "SELECT * FROM range(DATE '2024-01-01', DATE '2024-01-07',"
        " INTERVAL '0' DAY)"
    )
    assert_true("interval cannot be 0!" in days, days)


def test_a_column_valued_argument_is_refused_by_name() raises:
    var reason = _reason("SELECT * FROM generate_series(1, amount)")
    assert_true("column `amount`" in reason, reason)
    assert_true("LATERAL" in reason, reason)


def test_the_scalar_spelling_stays_refused() raises:
    var reason = _reason("SELECT range(3)")
    assert_true("range" in reason, reason)
    assert_true("FROM" in reason, reason)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
