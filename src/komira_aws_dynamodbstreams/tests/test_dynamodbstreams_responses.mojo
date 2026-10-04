# The responses komira_aws_dynamodbstreams decodes, one or more rows per
# operation, and the error forms DynamoDB Streams answers with. The wire
# texts are written here from the DynamoDB Streams API reference's
# examples, with made-up tables, shards and sequence numbers.
#
# Errors. DynamoDB Streams is awsJson 1.0: the body's `__type` names the
# shape with its namespace (`com.amazonaws.dynamodb.v20120810#...`), which
# komira_aws_core's `aws_json_error_info` strips to the code; the modeled
# error shapes carry the message.
from komira_aws_dynamodbstreams.komira_aws_dynamodbstreams import (
    DynamoDBStreamsExpiredIteratorException,
    DynamoDBStreamsResourceNotFoundException,
    DynamoDBStreamsTrimmedDataAccessException,
    parse_describe_stream_response,
    parse_get_records_response,
    parse_get_shard_iterator_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_json_error_info
from komira_json import parse_json_value
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _STREAM = "arn:aws:dynamodb:us-east-1:123456789012:table/jobs/stream/2026-10-01T00:00:00.000"


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


def test_describe_stream() raises:
    var body = String(
        '{"StreamDescription":{"StreamArn":"' + String(_STREAM) + '",'
        + '"StreamLabel":"2026-10-01T00:00:00.000","StreamStatus":"ENABLED",'
        + '"StreamViewType":"NEW_AND_OLD_IMAGES","CreationRequestDateTime":1790812800.5,'
        + '"TableName":"jobs",'
        + '"KeySchema":[{"AttributeName":"pk","KeyType":"HASH"},{"AttributeName":"sk","KeyType":"RANGE"}],'
        + '"Shards":[{"ShardId":"shardId-00000001790812800000-0a1b2c3d",'
        + '"SequenceNumberRange":{"StartingSequenceNumber":"100000000000000000001",'
        + '"EndingSequenceNumber":"100000000000000000099"}},'
        + '{"ShardId":"shardId-00000001790816400000-0e0f1a2b",'
        + '"ParentShardId":"shardId-00000001790812800000-0a1b2c3d",'
        + '"SequenceNumberRange":{"StartingSequenceNumber":"200000000000000000001"}}],'
        + '"LastEvaluatedShardId":"shardId-00000001790816400000-0e0f1a2b"}}'
    )
    var d = parse_describe_stream_response(_ok(body)).stream_description.value().copy()
    assert_equal(d.stream_arn.value(), _STREAM)
    assert_equal(d.stream_status.value(), "ENABLED")
    assert_equal(d.stream_view_type.value(), "NEW_AND_OLD_IMAGES")
    assert_equal(d.creation_request_date_time.value(), 1790812800.5)
    assert_equal(d.table_name.value(), "jobs")
    var keys = d.key_schema.value().copy()
    assert_equal(len(keys), 2)
    assert_equal(keys[1].attribute_name, "sk")
    assert_equal(keys[1].key_type, "RANGE")
    var shards = d.shards.value().copy()
    assert_equal(len(shards), 2)
    assert_false(Bool(shards[0].parent_shard_id))
    assert_equal(
        shards[0].sequence_number_range.value().ending_sequence_number.value(),
        "100000000000000000099",
    )
    assert_equal(shards[1].parent_shard_id.value(), "shardId-00000001790812800000-0a1b2c3d")
    # An open shard has no ending sequence number.
    assert_false(Bool(shards[1].sequence_number_range.value().ending_sequence_number))
    assert_equal(d.last_evaluated_shard_id.value(), "shardId-00000001790816400000-0e0f1a2b")


def test_get_shard_iterator() raises:
    var r = parse_get_shard_iterator_response(
        _ok(String('{"ShardIterator":"arn:aws:dynamodb:us-east-1:123456789012:iterator/AAAA+/b=="}'))
    )
    assert_equal(r.shard_iterator.value(), "arn:aws:dynamodb:us-east-1:123456789012:iterator/AAAA+/b==")


def test_get_records() raises:
    var body = String(
        '{"Records":[{"eventID":"7de3041dd709b024af6f29e4fa13d34c","eventName":"INSERT",'
        + '"eventVersion":"1.1","eventSource":"aws:dynamodb","awsRegion":"us-east-1",'
        + '"dynamodb":{"ApproximateCreationDateTime":1790812801,'
        + '"Keys":{"pk":{"S":"job#42"}},'
        + '"NewImage":{"pk":{"S":"job#42"},"tries":{"N":"3"},"done":{"BOOL":false},'
        + '"meta":{"M":{"owner":{"S":"ci"}}},"tags":{"SS":["a","b"]},"blob":{"B":"AAEC"}},'
        + '"SequenceNumber":"100000000000000000001","SizeBytes":59,'
        + '"StreamViewType":"NEW_AND_OLD_IMAGES"}},'
        + '{"eventID":"8e0c2a5f","eventName":"REMOVE","eventSource":"aws:dynamodb",'
        + '"dynamodb":{"Keys":{"pk":{"S":"job#7"}},"OldImage":{"pk":{"S":"job#7"}},'
        + '"SequenceNumber":"100000000000000000002","SizeBytes":20},'
        + '"userIdentity":{"PrincipalId":"dynamodb.amazonaws.com","Type":"Service"}}],'
        + '"NextShardIterator":"arn:aws:dynamodb:us-east-1:123456789012:iterator/BBBB"}'
    )
    var r = parse_get_records_response(_ok(body))
    assert_equal(r.next_shard_iterator.value(), "arn:aws:dynamodb:us-east-1:123456789012:iterator/BBBB")
    var recs = r.records.value().copy()
    assert_equal(len(recs), 2)
    assert_equal(recs[0].event_name.value(), "INSERT")
    assert_equal(recs[0].aws_region.value(), "us-east-1")
    var sr = recs[0].dynamodb.value().copy()
    assert_equal(sr.approximate_creation_date_time.value(), 1790812801.0)
    assert_equal(sr.keys.value()["pk"].s.value(), "job#42")
    var img = sr.new_image.value().copy()
    assert_equal(img["tries"].n.value(), "3")
    assert_false(img["done"].bool.value())
    assert_equal(img["meta"].m[0]["owner"].s.value(), "ci")
    assert_equal(len(img["tags"].ss.value()), 2)
    assert_equal(len(img["blob"].b.value()), 3)
    assert_equal(img["blob"].b.value()[2], UInt8(2))
    assert_equal(sr.sequence_number.value(), "100000000000000000001")
    assert_equal(sr.size_bytes.value(), Int64(59))
    # A REMOVE carries the old image and no new one.
    var removed = recs[1].dynamodb.value().copy()
    assert_false(Bool(removed.new_image))
    assert_equal(removed.old_image.value()["pk"].s.value(), "job#7")
    assert_equal(recs[1].user_identity.value().type.value(), "Service")


def test_get_records_at_the_end_of_a_closed_shard() raises:
    # A closed shard read to its end answers no records and no next iterator.
    var r = parse_get_records_response(_ok(String('{"Records":[]}')))
    assert_equal(len(r.records.value()), 0)
    assert_false(Bool(r.next_shard_iterator))


def test_a_body_that_is_not_json_is_refused() raises:
    with assert_raises():
        _ = parse_get_shard_iterator_response(_ok(String("<html/>")))
    with assert_raises():
        _ = parse_get_records_response(_ok(String('{"Records":[{"eventName":5}]}')))


def test_resource_not_found() raises:
    var resp = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.dynamodb.v20120810#ResourceNotFoundException",'
            + '"message":"Requested resource not found: Stream: ' + String(_STREAM) + ' not found"}'
        ),
    )
    resp.add_header(String("x-amzn-RequestId"), String("KT3V6KDLQ7N6F1GA9OR5H0KK6RVV4KQNSO5AEMVJF66Q9ASUAAJG"))
    assert_true(aws_is_error_status(resp.status))
    var info = aws_json_error_info(resp)
    assert_equal(info.code, "ResourceNotFoundException")
    assert_true(info.message.find("Requested resource not found") >= 0)
    assert_equal(info.request_id, "KT3V6KDLQ7N6F1GA9OR5H0KK6RVV4KQNSO5AEMVJF66Q9ASUAAJG")
    var e = DynamoDBStreamsResourceNotFoundException.from_aws_json(parse_json_value(resp.body_text()))
    assert_true(e.message.value().find("not found") >= 0)


def test_iterator_errors() raises:
    var expired = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.dynamodb.v20120810#ExpiredIteratorException",'
            + '"message":"Iterator expired"}'
        ),
    )
    assert_equal(aws_json_error_info(expired).code, "ExpiredIteratorException")
    var e = DynamoDBStreamsExpiredIteratorException.from_aws_json(parse_json_value(expired.body_text()))
    assert_equal(e.message.value(), "Iterator expired")
    var trimmed = AwsResponse.of_text(
        400,
        String(
            '{"__type":"com.amazonaws.dynamodb.v20120810#TrimmedDataAccessException",'
            + '"message":"the record is beyond the trim horizon"}'
        ),
    )
    assert_equal(aws_json_error_info(trimmed).code, "TrimmedDataAccessException")
    var t = DynamoDBStreamsTrimmedDataAccessException.from_aws_json(parse_json_value(trimmed.body_text()))
    assert_true(t.message.value().find("trim horizon") >= 0)


def main() raises:
    test_describe_stream()
    test_get_shard_iterator()
    test_get_records()
    test_get_records_at_the_end_of_a_closed_shard()
    test_a_body_that_is_not_json_is_refused()
    test_resource_not_found()
    test_iterator_errors()
    print("OK")
