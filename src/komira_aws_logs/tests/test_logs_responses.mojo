# The GetLogEvents responses komira_aws_logs decodes, and the error forms
# CloudWatch Logs answers with. The wire texts are written here from the
# CloudWatch Logs API reference (GetLogEvents: `events[]` of timestamp,
# message and ingestionTime, `nextForwardToken`, `nextBackwardToken`;
# "Common Errors"), with made-up streams and tokens.
#
# Errors. The model's GetLogEvents error shapes have no members, so the
# generated ones decode nothing (the last row pins that). A caller reads a
# failure through komira_aws_core's `aws_json_error_info`: the code from
# the `X-Amzn-Errortype` header when the response has one, else the body's
# `__type`, either one cut to the short name; the message from `message`;
# the request id from `x-amzn-RequestId`.
from komira_aws_logs.komira_aws_logs import (
    CloudWatchLogsInvalidParameterException,
    CloudWatchLogsResourceNotFoundException,
    CloudWatchLogsServiceUnavailableException,
    parse_get_log_events_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_json_error_info
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _PAGE = (
    '{"events":['
    + '{"timestamp":1790812800000,"message":"listening on :8080",'
    + '"ingestionTime":1790812800412},'
    + '{"timestamp":1790812801500,"message":"GET /healthz 200",'
    + '"ingestionTime":1790812801903}],'
    + '"nextForwardToken":"f/39010232374012345678901234567890123456789012345678901235",'
    + '"nextBackwardToken":"b/39010232374012345678901234567890123456789012345678901234"}'
)


def test_a_page_of_events() raises:
    var resp = parse_get_log_events_response(AwsResponse.of_text(200, String(_PAGE)))
    var events = resp.events.value().copy()
    assert_equal(len(events), 2)
    assert_equal(events[0].timestamp.value(), Int64(1790812800000))
    assert_equal(events[0].message.value(), "listening on :8080")
    assert_equal(events[0].ingestion_time.value(), Int64(1790812800412))
    assert_equal(events[1].timestamp.value(), Int64(1790812801500))
    assert_equal(events[1].message.value(), "GET /healthz 200")
    assert_equal(
        resp.next_forward_token.value(),
        "f/39010232374012345678901234567890123456789012345678901235",
    )
    assert_equal(
        resp.next_backward_token.value(),
        "b/39010232374012345678901234567890123456789012345678901234",
    )


def test_end_of_stream() raises:
    # Past the last event the page is empty and the forward token is the
    # one the caller sent: the stream has nothing more yet.
    var body = String(
        '{"events":[],'
        + '"nextForwardToken":"f/39010232374012345678901234567890123456789012345678901235",'
        + '"nextBackwardToken":"b/39010232374012345678901234567890123456789012345678901235"}'
    )
    var resp = parse_get_log_events_response(AwsResponse.of_text(200, body))
    assert_true(Bool(resp.events))
    assert_equal(len(resp.events.value()), 0)
    assert_true(Bool(resp.next_forward_token))


def test_message_escapes_and_unknown_keys() raises:
    # A message holds what the program printed: quotes, backslashes,
    # control characters and non-ASCII, JSON-escaped on the wire. A key the
    # model does not name is ignored.
    var body = String(
        '{"events":[{"timestamp":1,"message":"a \\"b\\" c\\\\d\\te\\u00e9\\u2603",'
        + '"ingestionTime":2,"logStreamArn":"ignored"}],"futureMember":{"x":1}}'
    )
    var resp = parse_get_log_events_response(AwsResponse.of_text(200, body))
    var ev = resp.events.value()[0].copy()
    assert_equal(ev.message.value(), 'a "b" c\\d\teé☃')
    assert_false(Bool(resp.next_forward_token))


def test_null_and_empty() raises:
    var resp = parse_get_log_events_response(
        AwsResponse.of_text(200, String('{"events":null,"nextForwardToken":null}'))
    )
    assert_false(Bool(resp.events))
    assert_false(Bool(resp.next_forward_token))
    var empty = parse_get_log_events_response(AwsResponse.of_text(200, String("")))
    assert_false(Bool(empty.events))


def test_a_body_that_is_not_json_is_refused() raises:
    with assert_raises():
        _ = parse_get_log_events_response(
            AwsResponse.of_text(200, String('{"events":[{"timestamp":1'))
        )
    with assert_raises():
        _ = parse_get_log_events_response(
            AwsResponse.of_text(200, String('{"events":[{"timestamp":"one"}]}'))
        )


def test_error_from_the_body() raises:
    var resp = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.logs#ResourceNotFoundException",'
            + '"message":"The specified log stream does not exist."}'
        ),
    )
    resp.add_header(String("x-amzn-RequestId"), String("5c1f2a9e-0000-4000-8000-1234567890ab"))
    assert_true(aws_is_error_status(resp.status))
    var info = aws_json_error_info(resp)
    assert_equal(info.status, 400)
    assert_equal(info.code, "ResourceNotFoundException")
    assert_equal(info.message, "The specified log stream does not exist.")
    assert_equal(info.request_id, "5c1f2a9e-0000-4000-8000-1234567890ab")


def test_error_from_the_header() raises:
    # X-Amzn-Errortype wins over the body, and its `:<uri>` tail is cut.
    var resp = AwsResponse.of_text(
        400,
        String('{"__type":"InvalidParameterException","message":"limit"}'),
    )
    resp.add_header(
        String("X-Amzn-Errortype"),
        String("ThrottlingException:http://internal.amazon.com/coral/com.amazonaws.logs/"),
    )
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "ThrottlingException")
    assert_equal(info.message, "limit")


def test_error_without_a_code() raises:
    # A gateway's HTML 503 names no code: the status is what is left.
    var info = aws_json_error_info(
        AwsResponse.of_text(503, String("<html>Service Unavailable</html>"))
    )
    assert_equal(info.status, 503)
    assert_equal(info.code, "")
    assert_equal(info.message, "")


def test_generated_error_shapes_are_memberless() raises:
    var body = parse_json_value(
        String('{"__type":"ResourceNotFoundException","message":"m"}')
    )
    assert_equal(
        CloudWatchLogsResourceNotFoundException.from_aws_json(body)
        .to_aws_json()
        .serialize(),
        "{}",
    )
    assert_equal(
        CloudWatchLogsInvalidParameterException.from_aws_json(body)
        .to_aws_json()
        .serialize(),
        "{}",
    )
    assert_equal(
        CloudWatchLogsServiceUnavailableException.from_aws_json(body)
        .to_aws_json()
        .serialize(),
        "{}",
    )


def main() raises:
    test_a_page_of_events()
    test_end_of_stream()
    test_message_escapes_and_unknown_keys()
    test_null_and_empty()
    test_a_body_that_is_not_json_is_refused()
    test_error_from_the_body()
    test_error_from_the_header()
    test_error_without_a_code()
    test_generated_error_shapes_are_memberless()
    print("OK")
