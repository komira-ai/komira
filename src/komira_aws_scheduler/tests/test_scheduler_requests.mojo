# The requests komira_aws_scheduler builds, exactly: method, path (the
# schedule name a URI label), query (`groupName`, `clientToken`), headers
# and the JSON body, members in the model's order and an unset member
# absent. One or more rows per operation, in the shapes the EventBridge
# Scheduler API reference documents: a cron schedule created in a group
# with a target, read back by name, replaced whole by UpdateSchedule (the
# service resets every field the request leaves out, so an update carries
# the whole schedule), and deleted.
from komira_aws_scheduler.komira_aws_scheduler import (
    SCHEDULER_CONTENT_TYPE,
    SCHEDULER_FLEXIBLE_TIME_WINDOW_MODE_FLEXIBLE,
    SCHEDULER_FLEXIBLE_TIME_WINDOW_MODE_OFF,
    SCHEDULER_SCHEDULE_STATE_DISABLED,
    SCHEDULER_SCHEDULE_STATE_ENABLED,
    SchedulerCreateScheduleInput,
    SchedulerDeleteScheduleInput,
    SchedulerFlexibleTimeWindow,
    SchedulerGetScheduleInput,
    SchedulerRetryPolicy,
    SchedulerTarget,
    SchedulerUpdateScheduleInput,
    build_create_schedule_request,
    build_delete_schedule_request,
    build_get_schedule_request,
    build_update_schedule_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


comptime _FN = "arn:aws:lambda:us-east-1:123456789012:function:reaper"
comptime _ROLE = "arn:aws:iam::123456789012:role/scheduler-invoke"


def _target() -> SchedulerTarget:
    var t = SchedulerTarget(String(_FN), String(_ROLE))
    t.set_input(String('{"job":"reap"}'))
    return t^


def _off() -> SchedulerFlexibleTimeWindow:
    return SchedulerFlexibleTimeWindow(String(SCHEDULER_FLEXIBLE_TIME_WINDOW_MODE_OFF))


def _check_json(req: AwsRequest) raises:
    assert_equal(req.header(String("Content-Type")), "application/json")
    assert_equal(len(req.header_names), 1)


def test_wire_constants() raises:
    assert_equal(SCHEDULER_CONTENT_TYPE, "application/json")
    assert_equal(SCHEDULER_FLEXIBLE_TIME_WINDOW_MODE_OFF, "OFF")
    assert_equal(SCHEDULER_SCHEDULE_STATE_ENABLED, "ENABLED")


def test_create_schedule() raises:
    var input = SchedulerCreateScheduleInput(
        _off(), String("nightly-reap"), String("cron(0 3 * * ? *)"), _target()
    )
    input.set_group_name(String("apps"))
    input.set_schedule_expression_timezone(String("UTC"))
    input.set_state(String(SCHEDULER_SCHEDULE_STATE_ENABLED))
    var req = build_create_schedule_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/schedules/nightly-reap")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"FlexibleTimeWindow":{"Mode":"OFF"},"GroupName":"apps",'
        + '"ScheduleExpression":"cron(0 3 * * ? *)","ScheduleExpressionTimezone":"UTC",'
        + '"State":"ENABLED","Target":{"Arn":"'
        + _FN
        + '","Input":"{\\"job\\":\\"reap\\"}","RoleArn":"'
        + _ROLE
        + '"}}',
    )


def test_create_schedule_flexible_with_retry_and_dates() raises:
    var window = SchedulerFlexibleTimeWindow(String(SCHEDULER_FLEXIBLE_TIME_WINDOW_MODE_FLEXIBLE))
    window.set_maximum_window_in_minutes(Int32(15))
    var target = SchedulerTarget(String(_FN), String(_ROLE))
    var retry = SchedulerRetryPolicy()
    retry.set_maximum_event_age_in_seconds(Int32(3600))
    retry.set_maximum_retry_attempts(Int32(2))
    target.set_retry_policy(retry^)
    var input = SchedulerCreateScheduleInput(
        window^, String("hourly"), String("rate(1 hour)"), target^
    )
    input.set_client_token(String("c0ffee00-0000-4000-8000-000000000001"))
    # 2026-10-01T00:00:00Z: restJson1 sends a body timestamp as epoch seconds.
    input.set_start_date(Float64(1790812800))
    var req = build_create_schedule_request(input)
    assert_equal(req.uri, "/schedules/hourly")
    assert_equal(
        req.body_text(),
        '{"ClientToken":"c0ffee00-0000-4000-8000-000000000001",'
        + '"FlexibleTimeWindow":{"MaximumWindowInMinutes":15,"Mode":"FLEXIBLE"},'
        + '"ScheduleExpression":"rate(1 hour)","StartDate":1790812800,'
        + '"Target":{"Arn":"'
        + _FN
        + '","RetryPolicy":{"MaximumEventAgeInSeconds":3600,"MaximumRetryAttempts":2},'
        + '"RoleArn":"'
        + _ROLE
        + '"}}',
    )


def test_get_schedule() raises:
    var req = build_get_schedule_request(SchedulerGetScheduleInput(String("nightly-reap")))
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/schedules/nightly-reap")
    assert_equal(len(req.header_names), 0)
    assert_equal(len(req.body), 0)


def test_get_schedule_in_a_group() raises:
    var input = SchedulerGetScheduleInput(String("nightly-reap"))
    input.set_group_name(String("apps"))
    var req = build_get_schedule_request(input)
    assert_equal(req.uri, "/schedules/nightly-reap?groupName=apps")


def test_update_schedule_is_the_whole_schedule() raises:
    var input = SchedulerUpdateScheduleInput(
        _off(), String("nightly-reap"), String("cron(30 4 * * ? *)"), _target()
    )
    input.set_group_name(String("apps"))
    input.set_state(String(SCHEDULER_SCHEDULE_STATE_DISABLED))
    var req = build_update_schedule_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(req.uri, "/schedules/nightly-reap")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"FlexibleTimeWindow":{"Mode":"OFF"},"GroupName":"apps",'
        + '"ScheduleExpression":"cron(30 4 * * ? *)","State":"DISABLED",'
        + '"Target":{"Arn":"'
        + _FN
        + '","Input":"{\\"job\\":\\"reap\\"}","RoleArn":"'
        + _ROLE
        + '"}}',
    )


def test_delete_schedule() raises:
    var input = SchedulerDeleteScheduleInput(String("nightly-reap"))
    input.set_group_name(String("apps"))
    input.set_client_token(String("tok-1"))
    var req = build_delete_schedule_request(input)
    assert_equal(req.method, "DELETE")
    # Query members in the model's order.
    assert_equal(req.uri, "/schedules/nightly-reap?clientToken=tok-1&groupName=apps")
    assert_equal(len(req.header_names), 0)
    assert_equal(len(req.body), 0)


def test_a_label_is_percent_encoded() raises:
    # A name the model's pattern allows ([0-9a-zA-Z-_.]+) needs no encoding;
    # a space or a slash would, and is encoded rather than splitting the path.
    var req = build_get_schedule_request(SchedulerGetScheduleInput(String("a b/c")))
    assert_equal(req.uri, "/schedules/a%20b%2Fc")


def test_refusals_before_the_wire() raises:
    # `Name` is `min: 1` in the model, and a retry policy's event age is
    # bounded to [60, 86400].
    with assert_raises(contains="Name"):
        _ = build_get_schedule_request(SchedulerGetScheduleInput(String("")))
    var target = SchedulerTarget(String(_FN), String(_ROLE))
    var retry = SchedulerRetryPolicy()
    retry.set_maximum_event_age_in_seconds(Int32(30))
    target.set_retry_policy(retry^)
    with assert_raises(contains="MaximumEventAgeInSeconds"):
        _ = build_create_schedule_request(
            SchedulerCreateScheduleInput(_off(), String("x"), String("rate(1 hour)"), target^)
        )


def main() raises:
    test_wire_constants()
    test_create_schedule()
    test_create_schedule_flexible_with_retry_and_dates()
    test_get_schedule()
    test_get_schedule_in_a_group()
    test_update_schedule_is_the_whole_schedule()
    test_delete_schedule()
    test_a_label_is_percent_encoded()
    test_refusals_before_the_wire()
    print("OK")
