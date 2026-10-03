# The GetLogEvents request komira_aws_logs builds, exactly: method, path,
# the awsJson 1.1 headers (X-Amz-Target `Logs_20140328.GetLogEvents`,
# Content-Type `application/x-amz-json-1.1`) and the body, members in the
# model's order and an unset member absent. The rows are the reads a log
# tail makes (CloudWatch Logs API reference, GetLogEvents): the first page
# of a stream from its head, the next page by `nextToken`, a time window,
# and a stream named by the group's ARN (`logGroupIdentifier`). The
# model's bounds are checked before a request exists.
from komira_aws_logs.komira_aws_logs import (
    CLOUDWATCHLOGS_CONTENT_TYPE,
    CLOUDWATCHLOGS_TARGET_PREFIX,
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_false, assert_raises


def _check_envelope(req: AwsRequest) raises:
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(req.header(String("X-Amz-Target")), "Logs_20140328.GetLogEvents")
    assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.1")
    # awsJson carries everything in the body: no query, no other header.
    assert_equal(len(req.header_names), 2)


def test_wire_constants() raises:
    assert_equal(CLOUDWATCHLOGS_TARGET_PREFIX, "Logs_20140328")
    assert_equal(CLOUDWATCHLOGS_CONTENT_TYPE, "application/x-amz-json-1.1")


def test_first_page_from_head() raises:
    var input = CloudWatchLogsGetLogEventsRequest(String("web/app/0123456789abcdef"))
    input.set_log_group_name(String("/ecs/web"))
    input.set_limit(Int32(200))
    input.set_start_from_head(True)
    var req = build_get_log_events_request(input)
    _check_envelope(req)
    assert_equal(
        req.body_text(),
        '{"logGroupName":"/ecs/web","logStreamName":"web/app/0123456789abcdef",'
        + '"limit":200,"startFromHead":true}',
    )


def test_next_page_by_token() raises:
    var input = CloudWatchLogsGetLogEventsRequest(String("web/app/0123456789abcdef"))
    input.set_log_group_name(String("/ecs/web"))
    input.set_next_token(
        String("f/39010232374012345678901234567890123456789012345678901234")
    )
    input.set_limit(Int32(200))
    input.set_start_from_head(True)
    var req = build_get_log_events_request(input)
    _check_envelope(req)
    assert_equal(
        req.body_text(),
        '{"logGroupName":"/ecs/web","logStreamName":"web/app/0123456789abcdef",'
        + '"nextToken":"f/39010232374012345678901234567890123456789012345678901234",'
        + '"limit":200,"startFromHead":true}',
    )


def test_time_window() raises:
    # startTime and endTime are epoch milliseconds, sent as JSON integers.
    var input = CloudWatchLogsGetLogEventsRequest(String("s"))
    input.set_log_group_name(String("g"))
    input.set_start_time(Int64(1790812800000))
    input.set_end_time(Int64(1790816400000))
    var req = build_get_log_events_request(input)
    _check_envelope(req)
    assert_equal(
        req.body_text(),
        '{"logGroupName":"g","logStreamName":"s","startTime":1790812800000,'
        + '"endTime":1790816400000}',
    )


def test_group_by_identifier() raises:
    var input = CloudWatchLogsGetLogEventsRequest(String("s"))
    input.set_log_group_identifier(
        String("arn:aws:logs:us-east-1:123456789012:log-group:/ecs/web")
    )
    var req = build_get_log_events_request(input)
    assert_equal(
        req.body_text(),
        '{"logGroupIdentifier":"arn:aws:logs:us-east-1:123456789012:log-group:'
        + '/ecs/web","logStreamName":"s"}',
    )


def test_only_the_stream_is_required() raises:
    var req = build_get_log_events_request(
        CloudWatchLogsGetLogEventsRequest(String("s"))
    )
    assert_equal(req.body_text(), '{"logStreamName":"s"}')
    # `unmask` is never sent unless a caller sets it.
    assert_false(req.body_text().find("unmask") >= 0)


def test_strings_are_escaped() raises:
    var input = CloudWatchLogsGetLogEventsRequest(String('a"b\\c\n'))
    var req = build_get_log_events_request(input)
    assert_equal(req.body_text(), '{"logStreamName":"a\\"b\\\\c\\n"}')


def test_model_bounds() raises:
    # EventsLimit: min 1, max 10000.
    var low = CloudWatchLogsGetLogEventsRequest(String("s"))
    low.set_limit(Int32(0))
    with assert_raises(contains="limit: the model states min value 1"):
        _ = build_get_log_events_request(low)
    var high = CloudWatchLogsGetLogEventsRequest(String("s"))
    high.set_limit(Int32(10001))
    with assert_raises(contains="limit: the model states max value 10000"):
        _ = build_get_log_events_request(high)
    var edge = CloudWatchLogsGetLogEventsRequest(String("s"))
    edge.set_limit(Int32(10000))
    _ = build_get_log_events_request(edge)
    # LogStreamName: min 1, so the one required member cannot be "".
    with assert_raises(contains="logStreamName: the model states min length 1"):
        _ = build_get_log_events_request(
            CloudWatchLogsGetLogEventsRequest(String(""))
        )


def main() raises:
    test_wire_constants()
    test_first_page_from_head()
    test_next_page_by_token()
    test_time_window()
    test_group_by_identifier()
    test_only_the_stream_is_required()
    test_strings_are_escaped()
    test_model_bounds()
    print("OK")
