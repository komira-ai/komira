# sql_result under a caller's RunControl: the cancel and progress behind
# komira_sql_stream_run, on values.
#
# Rows: a query under a fresh control answers its row and leaves the control's
# progress at done == total, total above 0; under a cancelled control it
# raises exactly `QUERY_CANCELLED: execute: pipeline_exec: the query was
# cancelled: the caller cancelled the run`, which is_cancelled_error accepts,
# and the session records it with step execute and code QUERY_CANCELLED, and
# answers the next query; a bind refusal under a cancelled control keeps its
# own `bind: ` text, step bind and code SQL_BIND_ERROR, which
# is_cancelled_error refuses;
# is_cancelled_error accepts only the `QUERY_CANCELLED: ` prefix (not the
# word without its colon and space, not the engine's cancelled text without
# the word, not the word later in the text).
from std.testing import assert_equal, assert_false, assert_true

from sdk_exec.run_control import RunControl
from so import (
    KOMIRA_STEP_BIND,
    KOMIRA_STEP_EXECUTE,
    QUERY_CANCELLED,
    Session,
    is_cancelled_error,
    sql_result,
)

comptime _CANCELLED = (
    "QUERY_CANCELLED: execute: pipeline_exec: the query was cancelled: the"
    " caller cancelled the run"
)


def _message_of(mut s: Session, sql: String, control: RunControl) -> String:
    """The message `sql_result` raises for `sql` under `control`, or empty
    when it answers."""
    try:
        _ = sql_result(s, sql, control)
    except e:
        return String(e)
    return String()


def test_a_fresh_control_answers_and_counts_every_segment() raises:
    var s = Session()
    var control = RunControl()
    var result = sql_result(s, String("select 1 as n"), control)
    assert_equal(result.batches[0].num_rows(), 1)
    var p = control.snapshot()
    assert_true(p.total > 0)
    assert_equal(p.done, p.total)


def test_a_cancelled_control_raises_the_named_error() raises:
    var s = Session()
    var control = RunControl()
    control.cancel()
    var message = _message_of(s, String("select 1 as n"), control)
    assert_equal(message, String(_CANCELLED))
    assert_true(is_cancelled_error(message))
    assert_equal(control.snapshot().done, 0)
    assert_equal(s.last_error(), String(_CANCELLED))
    assert_equal(s.last_error_step(), KOMIRA_STEP_EXECUTE)
    assert_equal(s.last_error_code(), String("QUERY_CANCELLED"))
    # The session answers the next query.
    var result = sql_result(s, String("select 1 as n"))
    assert_equal(result.batches[0].num_rows(), 1)


def test_a_bind_refusal_keeps_its_own_text() raises:
    var s = Session()
    var control = RunControl()
    control.cancel()
    var message = _message_of(s, String("select * from nosuch"), control)
    assert_true(message.startswith("bind: "), message)
    assert_false(is_cancelled_error(message))
    assert_equal(s.last_error_step(), KOMIRA_STEP_BIND)
    assert_equal(s.last_error_code(), String("SQL_BIND_ERROR"))


def test_is_cancelled_error_reads_only_the_prefix() raises:
    assert_equal(String(QUERY_CANCELLED), String("QUERY_CANCELLED"))
    assert_true(is_cancelled_error(String("QUERY_CANCELLED: execute: x")))
    assert_false(is_cancelled_error(String("QUERY_CANCELLED")))
    assert_false(is_cancelled_error(String("QUERY_CANCELLEDexecute")))
    assert_false(
        is_cancelled_error(
            String("execute: pipeline_exec: the query was cancelled")
        )
    )
    assert_false(is_cancelled_error(String("bind: QUERY_CANCELLED: x")))
    assert_false(is_cancelled_error(String("")))


def main() raises:
    test_a_fresh_control_answers_and_counts_every_segment()
    test_a_cancelled_control_raises_the_named_error()
    test_a_bind_refusal_keeps_its_own_text()
    test_is_cancelled_error_reads_only_the_prefix()
    print("OK")
