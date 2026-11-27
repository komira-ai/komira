# =============================================================================
# run_sql: dayname(d) and monthname(d) answer DuckDB's English names
# =============================================================================
#
# Covers: the SQL functions `dayname` and `monthname` bind, plan and run
# through `run_sql` (parse, bind, optimize, lower, execute) and answer a
# VARCHAR column of the names DuckDB gives for the same SQL; and a call with
# the wrong number of arguments is refused at bind by name. The expected names
# were read out of DuckDB for these literals.
#
# What each test proves:
#   * test_dayname_of_every_weekday_is_duckdbs: seven DATE literals, Sunday
#     2026-11-15 to Saturday 2026-11-21, and the leap day 2028-02-29 (a
#     Tuesday), each a STRING column holding DuckDB's name. Catches a
#     weekday table off by one and an ISO (Monday = 1) numbering.
#   * test_monthname_of_every_month_is_duckdbs: the 15th of each month of
#     2027 names its month, and 2028-02-29 is February.
#   * test_a_name_takes_one_argument: `dayname()` and `monthname(d, d)` are
#     refused at bind with the extract functions' arity message.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from arrow.arrow_types import ArrowType
from arrow.schema import RecordBatch
from sdk_exec.engine_context import EngineContext
from sdk_exec.engine_options import EngineOptions
from sdk_exec.engine_sql import STEP_BIND, run_sql


def _new_context() raises -> EngineContext:
    return EngineContext(EngineOptions(worker_count=2))


def _run(mut ctx: EngineContext, sql: String) raises -> RecordBatch:
    var out = run_sql(ctx, sql)
    if out.refusal:
        assert_true(
            False,
            "refused at "
            + out.refusal.value().step
            + ": "
            + out.refusal.value().reason
            + " -- "
            + sql,
        )
    assert_equal(len(out.batches), 1)
    return out.batches.pop(0)


def _two(n: Int) -> String:
    return ("0" if n < 10 else "") + String(n)


def _select_of(fn_name: String, dates: List[String]) -> String:
    """`SELECT <fn>(DATE '<d0>') AS c0, <fn>(DATE '<d1>') AS c1, ...`."""
    var sql = String("SELECT ")
    for i in range(len(dates)):
        if i > 0:
            sql += ", "
        sql += fn_name + "(DATE '" + dates[i] + "') AS c" + String(i)
    return sql^


def _expect_names(
    ref batch: RecordBatch, want: List[String], what: String
) raises:
    assert_equal(batch.num_rows(), 1, what + ": one row")
    assert_equal(batch.num_columns(), len(want), what + ": one column a date")
    for i in range(len(want)):
        assert_equal(batch.schema.field_name(i), "c" + String(i))
        assert_true(
            batch.schema.field_arrow_type(i) == ArrowType.STRING,
            what + ": column c" + String(i) + " is not VARCHAR",
        )
        assert_true(not batch.column_at(i).is_null_at(0))
        assert_equal(
            batch.column_at(i).as_string().get(0),
            want[i],
            what + ": column c" + String(i),
        )


def test_dayname_of_every_weekday_is_duckdbs() raises:
    var dates = List[String]()
    for d in range(15, 22):
        dates.append("2026-11-" + _two(d))
    dates.append("2028-02-29")
    var ctx = _new_context()
    var batch = _run(ctx, _select_of("dayname", dates))
    _expect_names(
        batch,
        List[String](
            [
                "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday",
                "Friday", "Saturday", "Tuesday",
            ]
        ),
        "dayname",
    )


def test_monthname_of_every_month_is_duckdbs() raises:
    var dates = List[String]()
    for m in range(1, 13):
        dates.append("2027-" + _two(m) + "-15")
    dates.append("2028-02-29")
    var ctx = _new_context()
    var batch = _run(ctx, _select_of("monthname", dates))
    _expect_names(
        batch,
        List[String](
            [
                "January", "February", "March", "April", "May", "June",
                "July", "August", "September", "October", "November",
                "December", "February",
            ]
        ),
        "monthname",
    )


def _expect_bind_refusal(sql: String, want: String) raises:
    var ctx = _new_context()
    var out = run_sql(ctx, sql)
    assert_true(Bool(out.refusal), "not refused: " + sql)
    assert_equal(out.refusal.value().step, String(STEP_BIND), sql)
    assert_equal(out.refusal.value().reason, want, sql)


def test_a_name_takes_one_argument() raises:
    _expect_bind_refusal(
        "SELECT dayname()",
        "SQL bind error: dayname() expects exactly 1 argument"
        " (a DATE or TIMESTAMP expression) — got 0",
    )
    _expect_bind_refusal(
        "SELECT monthname(DATE '2026-11-16', DATE '2026-11-16')",
        "SQL bind error: monthname() expects exactly 1 argument"
        " (a DATE or TIMESTAMP expression) — got 2",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_dayname_of_every_weekday_is_duckdbs]()
    suite.test[test_monthname_of_every_month_is_duckdbs]()
    suite.test[test_a_name_takes_one_argument]()
    suite^.run()
