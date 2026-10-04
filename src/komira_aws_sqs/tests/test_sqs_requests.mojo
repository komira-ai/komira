# The requests komira_aws_sqs builds, exactly: method, path, the awsJson
# 1.0 headers (X-Amz-Target `AmazonSQS.<Operation>`, Content-Type
# `application/x-amz-json-1.0`, and `x-amzn-query-mode: true`, which SQS's
# model asks for as an awsQueryCompatible service) and the body, members
# in the model's order and an unset member absent. One or more rows per
# operation, in the shapes the Amazon SQS API reference documents for its
# JSON protocol: a queue created with attributes and tags, a queue looked
# up by name (and in another account), its attributes read and set, a
# long-poll receive, a message deleted, a queue deleted.
from komira_aws_sqs.komira_aws_sqs import (
    SQSQUEUE_ATTRIBUTE_NAME_ALL,
    SQSQUEUE_ATTRIBUTE_NAME_APPROXIMATE_NUMBER_OF_MESSAGES,
    SQS_CONTENT_TYPE,
    SQS_TARGET_PREFIX,
    SQSCreateQueueRequest,
    SQSDeleteMessageRequest,
    SQSDeleteQueueRequest,
    SQSGetQueueAttributesRequest,
    SQSGetQueueUrlRequest,
    SQSReceiveMessageRequest,
    SQSSetQueueAttributesRequest,
    build_create_queue_request,
    build_delete_message_request,
    build_delete_queue_request,
    build_get_queue_attributes_request,
    build_get_queue_url_request,
    build_receive_message_request,
    build_set_queue_attributes_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal


comptime _QUEUE = "https://sqs.us-east-1.amazonaws.com/123456789012/jobs"


def _check_envelope(req: AwsRequest, op: String) raises:
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(req.header(String("X-Amz-Target")), "AmazonSQS." + op)
    assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.0")
    assert_equal(req.header(String("x-amzn-query-mode")), "true")
    assert_equal(len(req.header_names), 3)


def test_wire_constants() raises:
    assert_equal(SQS_TARGET_PREFIX, "AmazonSQS")
    assert_equal(SQS_CONTENT_TYPE, "application/x-amz-json-1.0")


def test_create_queue() raises:
    var input = SQSCreateQueueRequest(String("jobs.fifo"))
    var attrs = Dict[String, String]()
    attrs["FifoQueue"] = String("true")
    attrs["VisibilityTimeout"] = String("60")
    attrs["RedrivePolicy"] = String(
        '{"deadLetterTargetArn":"arn:aws:sqs:us-east-1:123456789012:dlq.fifo",'
        + '"maxReceiveCount":"5"}'
    )
    input.set_attributes(attrs^)
    var tags = Dict[String, String]()
    tags["team"] = String("platform")
    input.set_tags(tags^)
    var req = build_create_queue_request(input)
    _check_envelope(req, String("CreateQueue"))
    # A map's entries in the caller's insertion order; a JSON string in an
    # attribute value is a string, escaped.
    assert_equal(
        req.body_text(),
        '{"QueueName":"jobs.fifo","Attributes":{"FifoQueue":"true",'
        + '"VisibilityTimeout":"60","RedrivePolicy":"{\\"deadLetterTargetArn\\":'
        + '\\"arn:aws:sqs:us-east-1:123456789012:dlq.fifo\\",\\"maxReceiveCount\\":'
        + '\\"5\\"}"},"tags":{"team":"platform"}}',
    )


def test_create_queue_name_only() raises:
    var req = build_create_queue_request(SQSCreateQueueRequest(String("jobs")))
    _check_envelope(req, String("CreateQueue"))
    assert_equal(req.body_text(), '{"QueueName":"jobs"}')


def test_get_queue_url() raises:
    var req = build_get_queue_url_request(SQSGetQueueUrlRequest(String("jobs")))
    _check_envelope(req, String("GetQueueUrl"))
    assert_equal(req.body_text(), '{"QueueName":"jobs"}')
    var other = SQSGetQueueUrlRequest(String("jobs"))
    other.set_queue_owner_aws_account_id(String("210987654321"))
    assert_equal(
        build_get_queue_url_request(other).body_text(),
        '{"QueueName":"jobs","QueueOwnerAWSAccountId":"210987654321"}',
    )


def test_get_queue_attributes() raises:
    var input = SQSGetQueueAttributesRequest(String(_QUEUE))
    var names: List[String] = [
        String(SQSQUEUE_ATTRIBUTE_NAME_APPROXIMATE_NUMBER_OF_MESSAGES),
        String("QueueArn"),
    ]
    input.set_attribute_names(names^)
    var req = build_get_queue_attributes_request(input)
    _check_envelope(req, String("GetQueueAttributes"))
    assert_equal(
        req.body_text(),
        '{"QueueUrl":"' + String(_QUEUE)
        + '","AttributeNames":["ApproximateNumberOfMessages","QueueArn"]}',
    )
    var all = SQSGetQueueAttributesRequest(String(_QUEUE))
    var all_names: List[String] = [String(SQSQUEUE_ATTRIBUTE_NAME_ALL)]
    all.set_attribute_names(all_names^)
    assert_equal(
        build_get_queue_attributes_request(all).body_text(),
        '{"QueueUrl":"' + String(_QUEUE) + '","AttributeNames":["All"]}',
    )


def test_set_queue_attributes() raises:
    var attrs = Dict[String, String]()
    attrs["MessageRetentionPeriod"] = String("1209600")
    var req = build_set_queue_attributes_request(
        SQSSetQueueAttributesRequest(String(_QUEUE), attrs^)
    )
    _check_envelope(req, String("SetQueueAttributes"))
    assert_equal(
        req.body_text(),
        '{"QueueUrl":"' + String(_QUEUE)
        + '","Attributes":{"MessageRetentionPeriod":"1209600"}}',
    )
    # A required map that is empty is still sent: presence is not emptiness.
    var none = build_set_queue_attributes_request(
        SQSSetQueueAttributesRequest(String(_QUEUE), Dict[String, String]())
    )
    assert_equal(none.body_text(), '{"QueueUrl":"' + String(_QUEUE) + '","Attributes":{}}')


def test_receive_message_long_poll() raises:
    var input = SQSReceiveMessageRequest(String(_QUEUE))
    var sys_names: List[String] = [String("ApproximateReceiveCount"), String("SentTimestamp")]
    input.set_message_system_attribute_names(sys_names^)
    var attr_names: List[String] = [String("All")]
    input.set_message_attribute_names(attr_names^)
    input.set_max_number_of_messages(Int32(10))
    input.set_visibility_timeout(Int32(30))
    input.set_wait_time_seconds(Int32(20))
    var req = build_receive_message_request(input)
    _check_envelope(req, String("ReceiveMessage"))
    assert_equal(
        req.body_text(),
        '{"QueueUrl":"' + String(_QUEUE)
        + '","MessageSystemAttributeNames":["ApproximateReceiveCount","SentTimestamp"],'
        + '"MessageAttributeNames":["All"],"MaxNumberOfMessages":10,'
        + '"VisibilityTimeout":30,"WaitTimeSeconds":20}',
    )


def test_receive_message_fifo_attempt() raises:
    var input = SQSReceiveMessageRequest(String(_QUEUE))
    input.set_receive_request_attempt_id(String("attempt-0001"))
    assert_equal(
        build_receive_message_request(input).body_text(),
        '{"QueueUrl":"' + String(_QUEUE) + '","ReceiveRequestAttemptId":"attempt-0001"}',
    )


def test_delete_message() raises:
    var req = build_delete_message_request(
        SQSDeleteMessageRequest(String(_QUEUE), String("AQEBexample+receipt/handle=="))
    )
    _check_envelope(req, String("DeleteMessage"))
    assert_equal(
        req.body_text(),
        '{"QueueUrl":"' + String(_QUEUE)
        + '","ReceiptHandle":"AQEBexample+receipt/handle=="}',
    )


def test_delete_queue() raises:
    var req = build_delete_queue_request(SQSDeleteQueueRequest(String(_QUEUE)))
    _check_envelope(req, String("DeleteQueue"))
    assert_equal(req.body_text(), '{"QueueUrl":"' + String(_QUEUE) + '"}')


def main() raises:
    test_wire_constants()
    test_create_queue()
    test_create_queue_name_only()
    test_get_queue_url()
    test_get_queue_attributes()
    test_set_queue_attributes()
    test_receive_message_long_poll()
    test_receive_message_fifo_attempt()
    test_delete_message()
    test_delete_queue()
    print("OK")
