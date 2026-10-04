# The responses komira_aws_scheduler decodes, one or more rows per
# operation, and the restJson1 error form EventBridge Scheduler answers
# with. The wire texts are written here from the EventBridge Scheduler API
# reference, with made-up names and ARNs.
#
# Errors. A restJson1 service names the error in the `X-Amzn-Errortype`
# header, the body carrying `Message`; komira_aws_core's
# `aws_rest_json_error` reads the code from that header (else the body's
# `code` or `__type`), and the generated error shapes read the body.
from komira_aws_scheduler.komira_aws_scheduler import (
    SchedulerConflictException,
    SchedulerResourceNotFoundException,
    SchedulerValidationException,
    parse_create_schedule_response,
    parse_delete_schedule_response,
    parse_get_schedule_response,
    parse_update_schedule_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_rest_json_error
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_true


comptime _ARN = "arn:aws:scheduler:us-east-1:123456789012:schedule/apps/nightly-reap"


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


def test_create_schedule() raises:
    var r = parse_create_schedule_response(_ok(String('{"ScheduleArn":"') + _ARN + '"}'))
    assert_equal(r.schedule_arn, _ARN)


def test_update_schedule() raises:
    var r = parse_update_schedule_response(_ok(String('{"ScheduleArn":"') + _ARN + '"}'))
    assert_equal(r.schedule_arn, _ARN)


def test_delete_schedule() raises:
    # DeleteSchedule answers 200 with an empty object, or no body at all.
    _ = parse_delete_schedule_response(_ok(String("{}")))
    _ = parse_delete_schedule_response(_ok(String("")))


def test_get_schedule() raises:
    var r = parse_get_schedule_response(
        _ok(
            String('{"ActionAfterCompletion":"NONE","Arn":"')
            + _ARN
            + '","CreationDate":1790812800.5,"FlexibleTimeWindow":{"Mode":"OFF"},'
            + '"GroupName":"apps","LastModificationDate":1790816400,'
            + '"Name":"nightly-reap","ScheduleExpression":"cron(0 3 * * ? *)",'
            + '"ScheduleExpressionTimezone":"UTC","State":"ENABLED",'
            + '"Target":{"Arn":"arn:aws:lambda:us-east-1:123456789012:function:reaper",'
            + '"Input":"{\\"job\\":\\"reap\\"}",'
            + '"RetryPolicy":{"MaximumEventAgeInSeconds":86400,"MaximumRetryAttempts":185},'
            + '"RoleArn":"arn:aws:iam::123456789012:role/scheduler-invoke"}}'
        )
    )
    assert_equal(r.arn.value(), _ARN)
    assert_equal(r.name.value(), "nightly-reap")
    assert_equal(r.group_name.value(), "apps")
    assert_equal(r.state.value(), "ENABLED")
    assert_equal(r.action_after_completion.value(), "NONE")
    assert_equal(r.schedule_expression.value(), "cron(0 3 * * ? *)")
    assert_equal(r.schedule_expression_timezone.value(), "UTC")
    assert_equal(r.creation_date.value(), Float64(1790812800.5))
    assert_equal(r.last_modification_date.value(), Float64(1790816400))
    assert_equal(r.flexible_time_window.value().mode, "OFF")
    assert_false(Bool(r.flexible_time_window.value().maximum_window_in_minutes))
    ref t = r.target.value()
    assert_equal(t.arn, "arn:aws:lambda:us-east-1:123456789012:function:reaper")
    assert_equal(t.role_arn, "arn:aws:iam::123456789012:role/scheduler-invoke")
    assert_equal(t.input.value(), '{"job":"reap"}')
    assert_equal(t.retry_policy.value().maximum_retry_attempts.value(), Int32(185))
    # Absent members stay unset.
    assert_false(Bool(r.description))
    assert_false(Bool(r.kms_key_arn))
    assert_false(Bool(r.start_date))


def _error(status: Int, kind: String, body: String) -> AwsResponse:
    var r = AwsResponse.of_text(status, body)
    r.add_header(String("X-Amzn-Errortype"), kind)
    r.add_header(String("x-amzn-RequestId"), String("6b8e3c1a-0000-4000-8000-00000000000a"))
    return r^


def test_not_found() raises:
    var r = _error(
        404,
        String("ResourceNotFoundException:http://internal.amazon.com/coral/com.amazonaws.chronos/"),
        String('{"Message":"Schedule nightly-reap does not exist."}'),
    )
    assert_true(aws_is_error_status(r.status))
    var info = aws_rest_json_error(r)
    assert_equal(info.status, 404)
    # The header's code is cut at its first ':'.
    assert_equal(info.code, "ResourceNotFoundException")
    assert_equal(info.message, "Schedule nightly-reap does not exist.")
    assert_equal(info.request_id, "6b8e3c1a-0000-4000-8000-00000000000a")
    var e = SchedulerResourceNotFoundException.from_aws_json(parse_json_value(r.body_text()))
    assert_equal(e.message, "Schedule nightly-reap does not exist.")


def test_conflict() raises:
    var r = _error(
        409,
        String("ConflictException"),
        String('{"Message":"Schedule nightly-reap already exists."}'),
    )
    var info = aws_rest_json_error(r)
    assert_equal(info.code, "ConflictException")
    var e = SchedulerConflictException.from_aws_json(parse_json_value(r.body_text()))
    assert_equal(e.message, "Schedule nightly-reap already exists.")


def test_validation_without_the_header() raises:
    # With no header the code is the body's `__type`, after its last '#'.
    var r = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.chronos#ValidationException",'
            + '"Message":"Invalid Schedule Expression cron(0 3 * * *)."}'
        ),
    )
    var info = aws_rest_json_error(r)
    assert_equal(info.code, "ValidationException")
    assert_equal(info.message, "Invalid Schedule Expression cron(0 3 * * *).")
    var e = SchedulerValidationException.from_aws_json(parse_json_value(r.body_text()))
    assert_equal(e.message, "Invalid Schedule Expression cron(0 3 * * *).")


def main() raises:
    test_create_schedule()
    test_update_schedule()
    test_delete_schedule()
    test_get_schedule()
    test_not_found()
    test_conflict()
    test_validation_without_the_header()
    print("OK")
