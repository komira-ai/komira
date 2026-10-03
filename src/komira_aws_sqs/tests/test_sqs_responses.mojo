# The responses komira_aws_sqs decodes, one or more rows per operation, and
# the error forms SQS answers with. The wire texts are written here from
# the Amazon SQS API reference's JSON-protocol examples, with made-up
# queues, ids and handles.
#
# Errors. SQS answers an error with the shape name in the body's `__type`
# (`com.amazonaws.sqs#QueueDoesNotExist`) and, as an awsQueryCompatible
# service, the legacy query code in an `x-amzn-query-error` header
# (`AWS.SimpleQueueService.NonExistentQueue;Sender`). The pinned model omits
# those codes (no error shape has an `error.code`), but the live service
# sends them, and two differ from the shape name on these operations:
# QueueDoesNotExist arrives as AWS.SimpleQueueService.NonExistentQueue and
# QueueNameExists as QueueAlreadyExists. A caller reads the failure through
# komira_aws_core's `aws_json_error_info`, whose code is the header's query
# code, as botocore and the Go v2 SDK report it; the shape name, the name of
# the generated error struct, is the body's `__type`.
from komira_aws_sqs.komira_aws_sqs import (
    SQSQueueDoesNotExist,
    SQSQueueNameExists,
    SQSReceiptHandleIsInvalid,
    parse_create_queue_response,
    parse_delete_message_response,
    parse_delete_queue_response,
    parse_get_queue_attributes_response,
    parse_get_queue_url_response,
    parse_receive_message_response,
    parse_set_queue_attributes_response,
)
from komira_aws_core import (
    AwsResponse,
    aws_error_code_from_body,
    aws_is_error_status,
    aws_json_error_info,
)
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_raises, assert_true


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


def test_create_queue() raises:
    var r = parse_create_queue_response(
        _ok(String('{"QueueUrl":"https://sqs.us-east-1.amazonaws.com/123456789012/jobs"}'))
    )
    assert_equal(r.queue_url.value(), "https://sqs.us-east-1.amazonaws.com/123456789012/jobs")


def test_get_queue_url() raises:
    var r = parse_get_queue_url_response(
        _ok(String('{"QueueUrl":"http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/jobs"}'))
    )
    assert_equal(
        r.queue_url.value(),
        "http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/jobs",
    )


def test_get_queue_attributes() raises:
    var r = parse_get_queue_attributes_response(
        _ok(
            String(
                '{"Attributes":{"QueueArn":"arn:aws:sqs:us-east-1:123456789012:jobs",'
                + '"ApproximateNumberOfMessages":"7","VisibilityTimeout":"30",'
                + '"CreatedTimestamp":"1790812800"}}'
            )
        )
    )
    var a = r.attributes.value().copy()
    assert_equal(len(a), 4)
    assert_equal(a["QueueArn"], "arn:aws:sqs:us-east-1:123456789012:jobs")
    assert_equal(a["ApproximateNumberOfMessages"], "7")
    assert_equal(a["CreatedTimestamp"], "1790812800")


def test_receive_message() raises:
    var body = String(
        '{"Messages":[{"MessageId":"219f8380-5770-4cc2-8c3e-5c715e145f5e",'
        + '"ReceiptHandle":"AQEBexample+receipt/handle==",'
        + '"MD5OfBody":"fafb00f5732ab283681e124bf8747ed1",'
        + '"Body":"{\\"job\\":42}",'
        + '"Attributes":{"ApproximateReceiveCount":"1","SentTimestamp":"1790812800123"},'
        + '"MD5OfMessageAttributes":"d25a6aea97eb8f585bfa92d314504a92",'
        + '"MessageAttributes":{"kind":{"StringValue":"build","DataType":"String"},'
        + '"blob":{"BinaryValue":"AAEC/w==","DataType":"Binary"}}},'
        + '{"MessageId":"b1d0bd48-0000-4000-8000-000000000002",'
        + '"ReceiptHandle":"AQEBsecond","Body":"plain"}]}'
    )
    var r = parse_receive_message_response(_ok(body))
    var msgs = r.messages.value().copy()
    assert_equal(len(msgs), 2)
    ref m = msgs[0]
    assert_equal(m.message_id.value(), "219f8380-5770-4cc2-8c3e-5c715e145f5e")
    assert_equal(m.receipt_handle.value(), "AQEBexample+receipt/handle==")
    assert_equal(m.md5_of_body.value(), "fafb00f5732ab283681e124bf8747ed1")
    assert_equal(m.body.value(), '{"job":42}')
    assert_equal(m.attributes.value()["ApproximateReceiveCount"], "1")
    assert_equal(m.attributes.value()["SentTimestamp"], "1790812800123")
    var attrs = m.message_attributes.value().copy()
    assert_equal(attrs["kind"].data_type, "String")
    assert_equal(attrs["kind"].string_value.value(), "build")
    # A Binary attribute is base64 on the wire and bytes here.
    var blob = attrs["blob"].binary_value.value().copy()
    assert_equal(len(blob), 4)
    assert_equal(blob[0], UInt8(0))
    assert_equal(blob[1], UInt8(1))
    assert_equal(blob[2], UInt8(2))
    assert_equal(blob[3], UInt8(255))
    assert_false(Bool(msgs[1].attributes))
    assert_equal(msgs[1].body.value(), "plain")


def test_receive_nothing() raises:
    # A long poll that times out answers no `Messages` at all, or an empty list.
    assert_false(Bool(parse_receive_message_response(_ok(String("{}"))).messages))
    var empty = parse_receive_message_response(_ok(String('{"Messages":[]}')))
    assert_equal(len(empty.messages.value()), 0)


def test_empty_results() raises:
    # DeleteMessage, DeleteQueue and SetQueueAttributes answer 200 with an
    # empty body, or `{}`; both decode.
    _ = parse_delete_message_response(_ok(String("")))
    _ = parse_delete_message_response(_ok(String("{}")))
    _ = parse_delete_queue_response(_ok(String("")))
    _ = parse_set_queue_attributes_response(_ok(String("{}")))


def test_a_body_that_is_not_json_is_refused() raises:
    with assert_raises():
        _ = parse_get_queue_url_response(_ok(String("<GetQueueUrlResponse/>")))
    with assert_raises():
        _ = parse_receive_message_response(_ok(String('{"Messages":[{"Body":5}]}')))


def test_queue_does_not_exist() raises:
    var resp = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.sqs#QueueDoesNotExist",'
            + '"message":"The specified queue does not exist."}'
        ),
    )
    resp.add_header(
        String("x-amzn-query-error"),
        String("AWS.SimpleQueueService.NonExistentQueue;Sender"),
    )
    resp.add_header(
        String("x-amzn-RequestId"), String("e9b0a6c4-0000-4000-8000-1234567890ab")
    )
    assert_true(aws_is_error_status(resp.status))
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "AWS.SimpleQueueService.NonExistentQueue")
    assert_equal(aws_error_code_from_body(resp.body), "QueueDoesNotExist")
    assert_equal(info.message, "The specified queue does not exist.")
    assert_equal(info.request_id, "e9b0a6c4-0000-4000-8000-1234567890ab")
    # The modeled error shape carries the message.
    var e = SQSQueueDoesNotExist.from_aws_json(parse_json_value(resp.body_text()))
    assert_equal(e.message.value(), "The specified queue does not exist.")


def test_queue_name_exists() raises:
    # CreateQueue of an existing name with other attributes.
    var resp = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.sqs#QueueNameExists",'
            + '"message":"A queue already exists with the same name and a'
            + ' different value for attribute VisibilityTimeout"}'
        ),
    )
    resp.add_header(String("x-amzn-query-error"), String("QueueAlreadyExists;Sender"))
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "QueueAlreadyExists")
    assert_equal(aws_error_code_from_body(resp.body), "QueueNameExists")
    var e = SQSQueueNameExists.from_aws_json(parse_json_value(resp.body_text()))
    assert_true(e.message.value().find("VisibilityTimeout") >= 0)


def test_receipt_handle_is_invalid_from_the_header() raises:
    var resp = AwsResponse.of_text(
        400,
        String('{"__type":"com.amazonaws.sqs#ReceiptHandleIsInvalid","message":"bad handle"}'),
    )
    resp.add_header(String("X-Amzn-Errortype"), String("ReceiptHandleIsInvalid:http://internal.amazon.com/"))
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "ReceiptHandleIsInvalid")
    var e = SQSReceiptHandleIsInvalid.from_aws_json(parse_json_value(resp.body_text()))
    assert_equal(e.message.value(), "bad handle")


def test_throttled_without_a_body() raises:
    var info = aws_json_error_info(AwsResponse.of_text(503, String("")))
    assert_equal(info.status, 503)
    assert_equal(info.code, "")


def main() raises:
    test_create_queue()
    test_get_queue_url()
    test_get_queue_attributes()
    test_receive_message()
    test_receive_nothing()
    test_empty_results()
    test_a_body_that_is_not_json_is_refused()
    test_queue_does_not_exist()
    test_queue_name_exists()
    test_receipt_handle_is_invalid_from_the_header()
    test_throttled_without_a_body()
    print("OK")
