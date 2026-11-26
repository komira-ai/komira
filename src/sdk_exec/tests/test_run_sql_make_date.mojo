# =============================================================================
# run_sql: make_date, last_day and the six-argument make_timestamp equal DuckDB
# =============================================================================
#
# The table T is the `scalar_fn` corpus's table (src/tests/conformance/
# komira_sql_conformance, tables.sql) as the pinned DuckDB wrote it to Parquet:
# the calendar columns yr, mo, dy, hr, mi (BIGINT), sec (DOUBLE) and dt (DATE)
# hold leap and non-leap Februaries, a 24:00 hour, 60 seconds, seconds finer
# than a microsecond, NULLs, and DuckDB's DATE infinity and -infinity. It is
# registered as `t`. The corpus's make_date, last_day and make_timestamp cases
# are staged as `sql/<case>.sql` with the answer the pinned DuckDB gives each as
# `duckdb/<case>.tsv`, and run through `run_sql`. The comparison is by value
# (the answers are multisets) and not by column name: the header line of the
# answer is replaced with the batch's own names.
#
# What each test proves:
#   * test_cases_equal_duckdb_on_one_worker, ..._on_three_workers: each staged
#     case answers DuckDB's rows in one batch, with no refusal.
#   * test_every_case_is_run: the staged cases are the fourteen named here,
#     each with a SQL text and an answer.
#   * test_the_comparison_is_not_vacuous: an answer with a changed date, a
#     missing row and an added row is reported as a mismatch; the answer itself
#     is not.
#   * test_constant_arguments_out_of_range_are_refused_at_bind_with_duckdbs_text:
#     a call whose arguments are all constants and invalid is refused at bind
#     with DuckDB's message, word for word.
#   * test_column_arguments_out_of_range_fail_at_execute: when an argument is a
#     column and a row is invalid, the query fails at execute and the reason
#     holds the function's guard text.
#   * test_a_null_argument_gives_null_and_never_raises: NULL in one argument
#     beats an invalid value in another.
#   * test_a_column_call_in_a_where_is_refused_by_the_filter_by_name: a call
#     over columns in a WHERE is refused at execute, naming the CASE node the
#     filter cannot scope.
#   * test_make_date_stored_day_numbers_at_the_edges: the day numbers stored
#     for dates DuckDB prints with a BC suffix, year 0 and the ends of the
#     date range equal DuckDB's, for constants and for a column.
#   * test_make_date_in_a_year_without_the_leap_day_fails_at_execute: February 29
#     of year -1 through a column is refused at execute.
#   * test_make_timestamp_before_year_one_stores_duckdbs_microseconds: the
#     stored microseconds of a timestamp in year -1 equal DuckDB's.
#   * test_last_day_of_an_infinite_timestamp_is_null: last_day of a timestamp
#     stored as the largest or the smallest microsecond count is NULL.

from std.os import listdir
from std.testing import TestSuite, assert_equal, assert_true

from arrow.schema import RecordBatch
from komira_plan_harness import (
    CanonPolicy,
    compare_canon,
    duckdb_tsv_canon,
    parse_duckdb_tsv,
    render_batch,
)
from runtime_paths import data_path, read_data
from sdk_exec.engine_catalog import register_parquet
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, STEP_EXECUTE, run_sql

comptime _STAGED_CASES = 14


def _context(workers: Int) raises -> EngineContext:
    var ctx = EngineContext(EngineOptions(worker_count=workers))
    register_parquet(ctx, "t", data_path("scalar_fn_t.parquet"))
    return ctx^


def _case_names() raises -> List[String]:
    """The cases staged as `sql/<case>.sql`, sorted."""
    var out = List[String]()
    for entry in listdir(data_path("sql")):
        var f = String(entry)
        if f.endswith(".sql"):
            out.append(String(f[byte = 0 : f.byte_length() - 4]))
    # insertion sort: the listing order is the file system's
    for i in range(1, len(out)):
        var j = i
        while j > 0 and out[j - 1] > out[j]:
            var tmp = out[j - 1]
            out[j - 1] = out[j]
            out[j] = tmp
            j -= 1
    return out^


def _query(name: String) raises -> String:
    """The case's SELECT: its file without the comment lines."""
    var text = read_data("sql/" + name + ".sql")
    var out = String("")
    for line in text.split("\n"):
        var l = String(line)
        if l.startswith("--") or l == "":
            continue
        out += l + " "
    return out^


def _compare(batch: RecordBatch, tsv: String) raises -> String:
    """"" when `batch` equals the DuckDB answer `tsv` by value (rows as a
    multiset, column names not compared), else the report."""
    var actual = render_batch(batch, CanonPolicy.unordered())
    var header = String("")
    for c in range(batch.num_columns()):
        if c > 0:
            header += "\t"
        header += batch.schema.field_name(c)
    var body_at = tsv.find("\n")
    if body_at < 0:
        return String("an answer without a header line")
    try:
        var expected = duckdb_tsv_canon(
            parse_duckdb_tsv(
                header + String(tsv[byte = body_at : tsv.byte_length()])
            ),
            actual,
        )
        var report = compare_canon(expected, actual)
        if not report.ok():
            return String(report)
        return String("")
    except e:
        return String(e)


def _run_cases(workers: Int) raises:
    var ctx = _context(workers)
    var names = _case_names()
    var problems = String("")
    for i in range(len(names)):
        ref name = names[i]
        var out = run_sql(ctx, _query(name))
        if out.refusal:
            problems += (
                "\n  " + name + ": refused at " + out.refusal.value().step
                + ": " + out.refusal.value().reason
            )
            continue
        if len(out.batches) != 1:
            problems += "\n  " + name + ": " + String(len(out.batches)) + " batches"
            continue
        var diff = _compare(out.batches[0], read_data("duckdb/" + name + ".tsv"))
        if diff != "":
            problems += "\n  " + name + " on " + String(workers) + " workers: " + diff
    assert_equal(problems, String(""))


def test_cases_equal_duckdb_on_one_worker() raises:
    _run_cases(1)


def test_cases_equal_duckdb_on_three_workers() raises:
    _run_cases(3)


def test_every_case_is_run() raises:
    var names = _case_names()
    assert_equal(len(names), _STAGED_CASES)
    var expected = List[String]()
    expected.append("last_day_date_column")
    expected.append("last_day_literals")
    expected.append("last_day_of_make_date")
    expected.append("last_day_timestamp_columns")
    expected.append("make_date_columns")
    expected.append("make_date_from_k")
    expected.append("make_date_in_where")
    expected.append("make_date_integer_columns")
    expected.append("make_date_literals")
    expected.append("make_date_null_argument")
    expected.append("make_timestamp_columns")
    expected.append("make_timestamp_epoch_micros")
    expected.append("make_timestamp_integer_seconds")
    expected.append("make_timestamp_literals")
    for i in range(len(expected)):
        assert_equal(names[i], expected[i])
    for i in range(len(names)):
        assert_true(
            "make_date" in _query(names[i])
            or "last_day" in _query(names[i])
            or "make_timestamp" in _query(names[i]),
            names[i] + " calls none of the three functions",
        )
        assert_true(
            read_data("duckdb/" + names[i] + ".tsv").byte_length() > 0, names[i]
        )


def test_the_comparison_is_not_vacuous() raises:
    var ctx = _context(1)
    var out = run_sql(ctx, "SELECT k, dt FROM t WHERE k < 3")
    assert_true(not out.refusal)
    assert_equal(len(out.batches), 1)
    ref batch = out.batches[0]
    var answer = "k\tdt\n0\t2024-02-10\n1\t2028-02-29\n2\t2000-02-01\n"
    assert_equal(_compare(batch, answer), String(""))
    assert_true(
        _compare(batch, "k\tdt\n0\t2024-02-10\n1\t2028-02-28\n2\t2000-02-01\n") != "",
        "a changed date",
    )
    assert_true(
        _compare(batch, "k\tdt\n0\t2024-02-10\n1\t2028-02-29\n") != "",
        "a row missing",
    )
    assert_true(
        _compare(batch, answer + "3\t2100-02-15\n") != "", "a row added"
    )


# =============================================================================
# Refusals
# =============================================================================


def _refusal(mut ctx: EngineContext, sql: String, step: String) raises -> String:
    """The reason `sql` is refused at `step`; fails when it is answered or
    refused at another step."""
    var out = run_sql(ctx, sql)
    assert_true(Bool(out.refusal), sql + " was not refused")
    assert_equal(out.refusal.value().step, step, sql)
    assert_equal(len(out.batches), 0, sql)
    return out.refusal.value().reason


def _bind_refusal(mut ctx: EngineContext, call: String, text: String) raises:
    assert_equal(
        _refusal(ctx, "SELECT " + call + " FROM t", String(STEP_BIND)), text, call
    )


# Each text is what the pinned DuckDB (v1.5.6) answers for the same call.
def test_constant_arguments_out_of_range_are_refused_at_bind_with_duckdbs_text() raises:
    var ctx = _context(1)
    var date_range = "Conversion Error: Date out of range: "
    var int32 = (
        "Invalid Input Error: Type INT64 with value "
        "9223372036854775807 can't be cast because the value is out of range"
        " for the destination type INT32"
    )
    var time_range = "Conversion Error: Time out of range: "
    _bind_refusal(ctx, "make_date(2023, 2, 29)", date_range + "2023-2-29")
    _bind_refusal(ctx, "make_date(2024, 13, 1)", date_range + "2024-13-1")
    _bind_refusal(ctx, "make_date(2024, 4, 31)", date_range + "2024-4-31")
    _bind_refusal(ctx, "make_date(2024, 1, 0)", date_range + "2024-1-0")
    _bind_refusal(ctx, "make_date(2100, 2, 29)", date_range + "2100-2-29")
    _bind_refusal(ctx, "make_date(9223372036854775807, 1, 1)", int32)
    # DuckDB names the last argument that does not fit INT32.
    _bind_refusal(
        ctx,
        "make_date(1, 9223372036854775806, 9223372036854775805)",
        "Invalid Input Error: Type INT64 with value 9223372036854775805 can't"
        " be cast because the value is out of range for the destination type"
        " INT32",
    )
    _bind_refusal(ctx, "make_date(5881580, 7, 11)", date_range + "5881580-7-11")
    _bind_refusal(ctx, "make_date(-5877641, 6, 24)", date_range + "-5877641-6-24")
    _bind_refusal(
        ctx, "make_timestamp(2024, 2, 29, 25, 0, 0)", time_range + "25:0:0.0"
    )
    _bind_refusal(
        ctx, "make_timestamp(2024, 2, 29, 24, 1, 0)", time_range + "24:1:0.0"
    )
    _bind_refusal(
        ctx, "make_timestamp(2024, 1, 1, 0, 0, 61.5)", time_range + "0:0:62.-500000"
    )
    _bind_refusal(
        ctx, "make_timestamp(2024, 1, 1, 0, 0, -0.5)", time_range + "0:0:0.-500000"
    )
    # The date is checked before the time.
    _bind_refusal(
        ctx, "make_timestamp(2024, 13, 1, 25, 1, 0)", date_range + "2024-13-1"
    )
    _bind_refusal(
        ctx,
        "make_timestamp(294247, 1, 11, 0, 0, 0)",
        "Conversion Error: Date and time not in timestamp range",
    )
    _bind_refusal(ctx, "make_timestamp(2024, 1, 1, 9223372036854775807, 1, 0)", int32)


def _execute_refusal(mut ctx: EngineContext, call: String, guard: String) raises:
    var reason = _refusal(ctx, "SELECT " + call + " FROM t", String(STEP_EXECUTE))
    assert_true(guard in reason, call + ": " + reason)


def test_column_arguments_out_of_range_fail_at_execute() raises:
    var ctx = _context(1)
    # k = 1 gives February 29 of 2023
    _execute_refusal(ctx, "make_date(2023, 2, k + 28)", "make_date: Date out of range")
    # k = 12 gives month 13
    _execute_refusal(ctx, "make_date(yr, k + 1, 1)", "make_date: Date out of range")
    # row k1 reads 24:59:59.999999
    _execute_refusal(
        ctx,
        "make_timestamp(yr, mo, dy, hr + 1, mi, sec)",
        "make_timestamp: Time out of range",
    )
    # row k9 is year 999900, beyond the timestamp range
    _execute_refusal(
        ctx,
        "make_timestamp(yr * 100, mo, dy, 0, 0, 0)",
        "make_timestamp: Date and time not in timestamp range",
    )
    # row k7 reads 61 seconds
    _execute_refusal(
        ctx,
        "make_timestamp(yr, mo, dy, hr, mi, sec + 1)",
        "make_timestamp: Time out of range",
    )
    _execute_refusal(
        ctx,
        "make_timestamp(yr, 13 + k, dy, 0, 0, 0)",
        "make_timestamp: Date out of range",
    )
    # July of year 5881580 has its last day past the DATE range
    _execute_refusal(
        ctx,
        "last_day(make_date(5881580, 7, k % 10 + 1))",
        "last_day: Date out of range",
    )


def test_a_null_argument_gives_null_and_never_raises() raises:
    var ctx = _context(3)
    var out = run_sql(
        ctx,
        "SELECT k, make_date(NULL, 13, 1), make_date(yr, 13 + k * 0, NULL),"
        " make_timestamp(yr, 13 + k * 0, dy, 25, mi, NULL) FROM t",
    )
    if out.refusal:
        assert_true(False, "refused: " + out.refusal.value().reason)
    assert_equal(len(out.batches), 1)
    ref batch = out.batches[0]
    assert_equal(batch.num_rows(), 13)
    for c in range(1, 4):
        for r in range(13):
            assert_true(batch.column_at(c).is_null_at(r), "column " + String(c) + " row " + String(r))


def test_a_column_call_in_a_where_is_refused_by_the_filter_by_name() raises:
    # A call over columns is a CASE tree, and a filter refuses a predicate
    # holding a CASE (batch_eval/predicate_null_scope.mojo): the query is
    # refused by name, never answered with rows dropped. A call of constants
    # is a literal and filters (the corpus case make_date_in_where).
    var ctx = _context(1)
    var reason = _refusal(
        ctx,
        "SELECT k FROM t WHERE make_date(yr, mo, dy) >= DATE '2015-01-01'",
        String(STEP_EXECUTE),
    )
    assert_true("`EXPR_WHEN` has no arm" in reason, reason)


# =============================================================================
# Stored values the corpus cannot hold
# =============================================================================
#
# DuckDB prints a date before year 1 with a "(BC)" suffix, which the answer
# reader refuses, so the day numbers are held to DuckDB's own
# (make_date(...) - DATE '1970-01-01').


def _single_row(mut ctx: EngineContext, sql: String) raises -> RecordBatch:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            sql + " refused at " + out.refusal.value().step + ": " + out.refusal.value().reason,
        )
    assert_equal(len(out.batches), 1, sql)
    assert_equal(out.batches[0].num_rows(), 1, sql)
    return out.batches.pop(0)


def _day(batch: RecordBatch, col: Int) raises -> Int:
    assert_true(not batch.column_at(col).is_null_at(0), "NULL in column " + String(col))
    return Int(batch.column_at(col).as_primitive[DType.int32]().get(0))


def test_make_date_stored_day_numbers_at_the_edges() raises:
    var ctx = _context(1)
    var b = _single_row(
        ctx,
        "SELECT make_date(0, 1, 1), make_date(-1, 3, 1), make_date(-4, 2, 29),"
        " make_date(-5877641, 6, 25), make_date(5881580, 7, 10) FROM t WHERE k = 0",
    )
    assert_equal(_day(b, 0), -719528)
    assert_equal(_day(b, 1), -719834)
    assert_equal(_day(b, 2), -720930)
    assert_equal(_day(b, 3), -2147483646)
    assert_equal(_day(b, 4), 2147483646)
    # the same through columns: row k0 is year 0, which has a February 29
    var c = _single_row(
        ctx, "SELECT make_date(yr - 2024, mo, dy) FROM t WHERE k = 0"
    )
    assert_equal(_day(c, 0), -719469)


def test_make_date_in_a_year_without_the_leap_day_fails_at_execute() raises:
    var ctx = _context(1)
    var reason = _refusal(
        ctx,
        "SELECT make_date(yr * 0 - 1, mo, dy) FROM t WHERE k = 0",
        String(STEP_EXECUTE),
    )
    assert_true("make_date: Date out of range" in reason, reason)


def test_make_timestamp_before_year_one_stores_duckdbs_microseconds() raises:
    var ctx = _context(1)
    var b = _single_row(
        ctx, "SELECT make_timestamp(-1, 3, 1, 12, 0, 0) FROM t WHERE k = 0"
    )
    # DuckDB: epoch_us(make_timestamp(-1, 3, 1, 12, 0, 0))
    assert_equal(
        Int(b.column_at(0).as_primitive[DType.int64]().get(0)),
        -62193614400000000,
    )


def test_last_day_of_an_infinite_timestamp_is_null() raises:
    # DuckDB answers NULL for last_day(TIMESTAMP 'infinity') and for
    # last_day(TIMESTAMP '-infinity'), the timestamps stored as the largest and
    # the smallest nonnegated microsecond count. The one-argument make_timestamp
    # labels a microsecond count, so these are those two timestamps.
    var ctx = _context(1)
    var b = _single_row(
        ctx,
        "SELECT last_day(make_timestamp(9223372036854775807)),"
        " last_day(make_timestamp(-9223372036854775807)) FROM t WHERE k = 0",
    )
    assert_true(b.column_at(0).is_null_at(0), "infinity")
    assert_true(b.column_at(1).is_null_at(0), "-infinity")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
