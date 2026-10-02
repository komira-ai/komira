# The caller's test of the generated pure-mode CloudWatch Logs client: the
# GetLogEvents request it builds (method, URI, X-Amz-Target, Content-Type and
# the exact awsJson body) and a GetLogEvents response decoded. The response
# body is a scrubbed wire text in the shape CloudWatch Logs answers with
# (made-up group, stream and tokens); it exercises the decoder rules the
# generator states: an unknown key and an explicit null are ignored.
#
# ERRORS ARE NOT DECODED HERE, AND THIS FILE DOES NOT CLAIM THEY ARE. In the
# pinned botocore logs model all three GetLogEvents error shapes
# (InvalidParameterException, ResourceNotFoundException,
# ServiceUnavailableException) have 0 members, so a generated error shape
# reads nothing from an error body: test_error_shape only pins that it is
# memberless (it re-encodes as `{}` after decoding a body that carries a
# message). Reading the error code and message (`__type`, `message`) is
# komira_aws_core's (aws_error_code_from_body, aws_error_message_from_body),
# which pure-mode code imports and never calls; it is stubbed here and is
# tested on the real core in P06.
from komira_aws_logs.komira_aws_logs import (
    CloudWatchLogsGetLogEventsRequest,
    CloudWatchLogsResourceNotFoundException,
    build_get_log_events_request,
    parse_get_log_events_response,
)
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def test_request() raises:
    var input = CloudWatchLogsGetLogEventsRequest(String("web-1"))
    input.set_log_group_name(String("/example/app"))
    input.set_start_time(Int64(1790812800000))
    input.set_limit(Int32(10))
    input.set_start_from_head(True)
    var req = build_get_log_events_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(req.header(String("X-Amz-Target")), "Logs_20140328.GetLogEvents")
    assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.1")
    # Members in model order, an unset member absent rather than null.
    assert_equal(
        req.body,
        '{"logGroupName":"/example/app","logStreamName":"web-1",'
        + '"startTime":1790812800000,"limit":10,"startFromHead":true}',
    )


def test_request_is_validated() raises:
    # The model's `min: 1` on limit: build_get_log_events_request refuses it,
    # so no request below the bound can be produced.
    var input = CloudWatchLogsGetLogEventsRequest(String("web-1"))
    input.set_limit(Int32(0))
    with assert_raises(contains="limit: the model states min value 1"):
        _ = build_get_log_events_request(input)


comptime _RESPONSE = (
    '{"events":[{"timestamp":1790812800000,"message":"started",'
    + '"ingestionTime":1790812800250},'
    + '{"timestamp":1790812801000,"message":"ready","ingestionTime":null,'
    + '"unknownMember":"ignored"}],'
    + '"nextForwardToken":"f/00000000000000000000000000000000000000000000000000000001",'
    + '"nextBackwardToken":"b/00000000000000000000000000000000000000000000000000000000"}'
)


def test_response() raises:
    var resp = parse_get_log_events_response(String(_RESPONSE))
    assert_true(Bool(resp.events))
    var events = resp.events.value().copy()
    assert_equal(len(events), 2)
    assert_equal(events[0].timestamp.value(), Int64(1790812800000))
    assert_equal(events[0].message.value(), "started")
    assert_equal(events[0].ingestion_time.value(), Int64(1790812800250))
    assert_equal(events[1].message.value(), "ready")
    # An explicit null is an unset member, not a zero.
    assert_false(Bool(events[1].ingestion_time))
    assert_equal(
        resp.next_forward_token.value(),
        "f/00000000000000000000000000000000000000000000000000000001",
    )
    assert_equal(
        resp.next_backward_token.value(),
        "b/00000000000000000000000000000000000000000000000000000000",
    )


def test_empty_response_body() raises:
    # awsJson answers an empty body for an empty result: it decodes as `{}`.
    var resp = parse_get_log_events_response(String(""))
    assert_false(Bool(resp.events))
    assert_false(Bool(resp.next_forward_token))


comptime _ERROR = (
    '{"__type":"ResourceNotFoundException",'
    + '"message":"The specified log stream does not exist."}'
)


def test_error_shape() raises:
    # GetLogEvents' error shapes are memberless in the pinned model, so the
    # generated ResourceNotFoundException decodes nothing from the body:
    # re-encoded, it is `{}`. A model or generator change that gives it a
    # member reds this line, and then an error decode is worth asserting.
    var e = CloudWatchLogsResourceNotFoundException.from_aws_json(
        parse_json_value(String(_ERROR))
    )
    assert_equal(e.to_aws_json().serialize(), "{}")
    # The result decoder is not an error decoder: the error body has no
    # result member, so it decodes as an empty result rather than raising,
    # which is why a caller must classify the status before decoding.
    var resp = parse_get_log_events_response(String(_ERROR))
    assert_false(Bool(resp.events))
    # A body that is not JSON is refused, not decoded as empty. (The refusal
    # is the JSON parser's; the generated decoder only passes it on.)
    with assert_raises():
        _ = parse_get_log_events_response(String("<html>503</html>"))


def main() raises:
    test_request()
    test_request_is_validated()
    test_response()
    test_empty_response_body()
    test_error_shape()
