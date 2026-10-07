# The requests komira_aws_dynamodbstreams builds, exactly: method, path,
# the awsJson 1.0 headers (X-Amz-Target `DynamoDBStreams_20120810.<Operation>`
# and Content-Type `application/x-amz-json-1.0`) and the body, members in
# the model's order and an unset member absent. One or more rows per
# operation, in the shapes the DynamoDB Streams API reference documents: a
# stream described (and its next page of shards), an iterator taken at the
# trim horizon and after a sequence number, and a page of records read.
# Then the model's bounds, which `build_<op>_request` checks before any
# byte is written.
from komira_aws_dynamodbstreams.komira_aws_dynamodbstreams import (
    DYNAMODBSTREAMS_CONTENT_TYPE,
    DYNAMODBSTREAMS_SERVICE,
    DYNAMODBSTREAMS_TARGET_PREFIX,
    DYNAMO_DBSTREAMS_SHARD_ITERATOR_TYPE_AFTER_SEQUENCE_NUMBER,
    DYNAMO_DBSTREAMS_SHARD_ITERATOR_TYPE_TRIM_HORIZON,
    DynamoDBStreamsDescribeStreamInput,
    DynamoDBStreamsGetRecordsInput,
    DynamoDBStreamsGetShardIteratorInput,
    DynamoDBStreamsShardFilter,
    build_describe_stream_request,
    build_get_records_request,
    build_get_shard_iterator_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


comptime _STREAM = "arn:aws:dynamodb:us-east-1:123456789012:table/jobs/stream/2026-10-01T00:00:00.000"
comptime _SHARD = "shardId-00000001790812800000-0a1b2c3d"


def _check_envelope(req: AwsRequest, op: String) raises:
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(req.header(String("X-Amz-Target")), "DynamoDBStreams_20120810." + op)
    assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.0")
    assert_equal(len(req.header_names), 2)


def test_wire_constants() raises:
    assert_equal(DYNAMODBSTREAMS_TARGET_PREFIX, "DynamoDBStreams_20120810")
    assert_equal(DYNAMODBSTREAMS_CONTENT_TYPE, "application/x-amz-json-1.0")
    # Streams signs as DynamoDB: the model's signingName.
    assert_equal(DYNAMODBSTREAMS_SERVICE, "dynamodb")


def test_describe_stream() raises:
    var req = build_describe_stream_request(DynamoDBStreamsDescribeStreamInput(String(_STREAM)))
    _check_envelope(req, String("DescribeStream"))
    assert_equal(req.body_text(), '{"StreamArn":"' + String(_STREAM) + '"}')


def test_describe_stream_next_page() raises:
    var input = DynamoDBStreamsDescribeStreamInput(String(_STREAM))
    input.set_limit(Int32(100))
    input.set_exclusive_start_shard_id(String(_SHARD))
    var filter = DynamoDBStreamsShardFilter()
    filter.set_type(String("CHILD_SHARDS"))
    filter.set_shard_id(String(_SHARD))
    input.set_shard_filter(filter^)
    assert_equal(
        build_describe_stream_request(input).body_text(),
        '{"StreamArn":"' + String(_STREAM) + '","Limit":100,"ExclusiveStartShardId":"'
        + String(_SHARD) + '","ShardFilter":{"Type":"CHILD_SHARDS","ShardId":"'
        + String(_SHARD) + '"}}',
    )


def test_get_shard_iterator_trim_horizon() raises:
    var req = build_get_shard_iterator_request(
        DynamoDBStreamsGetShardIteratorInput(
            String(_STREAM),
            String(_SHARD),
            String(DYNAMO_DBSTREAMS_SHARD_ITERATOR_TYPE_TRIM_HORIZON),
        )
    )
    _check_envelope(req, String("GetShardIterator"))
    assert_equal(
        req.body_text(),
        '{"StreamArn":"' + String(_STREAM) + '","ShardId":"' + String(_SHARD)
        + '","ShardIteratorType":"TRIM_HORIZON"}',
    )


def test_get_shard_iterator_after_sequence_number() raises:
    var input = DynamoDBStreamsGetShardIteratorInput(
        String(_STREAM),
        String(_SHARD),
        String(DYNAMO_DBSTREAMS_SHARD_ITERATOR_TYPE_AFTER_SEQUENCE_NUMBER),
    )
    input.set_sequence_number(String("400000000000000499660"))
    assert_equal(
        build_get_shard_iterator_request(input).body_text(),
        '{"StreamArn":"' + String(_STREAM) + '","ShardId":"' + String(_SHARD)
        + '","ShardIteratorType":"AFTER_SEQUENCE_NUMBER","SequenceNumber":"400000000000000499660"}',
    )


def test_get_records() raises:
    var req = build_get_records_request(
        DynamoDBStreamsGetRecordsInput(String("arn:aws:dynamodb:us-east-1:123456789012:iterator/AAAA+/b=="))
    )
    _check_envelope(req, String("GetRecords"))
    assert_equal(
        req.body_text(),
        '{"ShardIterator":"arn:aws:dynamodb:us-east-1:123456789012:iterator/AAAA+/b=="}',
    )
    var page = DynamoDBStreamsGetRecordsInput(String("it"))
    page.set_limit(Int32(1000))
    assert_equal(build_get_records_request(page).body_text(), '{"ShardIterator":"it","Limit":1000}')


def test_model_bounds() raises:
    # StreamArn has min length 37, ShardId 28, Limit min 1, ShardIterator 1.
    with assert_raises(contains="StreamArn: the model states min length 37"):
        _ = build_describe_stream_request(DynamoDBStreamsDescribeStreamInput(String("arn:aws:dynamodb:short")))
    with assert_raises(contains="ShardId: the model states min length 28"):
        _ = build_get_shard_iterator_request(
            DynamoDBStreamsGetShardIteratorInput(String(_STREAM), String("shardId-1"), String("LATEST"))
        )
    var zero = DynamoDBStreamsGetRecordsInput(String("it"))
    zero.set_limit(Int32(0))
    with assert_raises(contains="Limit: the model states min value 1"):
        _ = build_get_records_request(zero)
    with assert_raises(contains="ShardIterator: the model states min length 1"):
        _ = build_get_records_request(DynamoDBStreamsGetRecordsInput(String("")))


def main() raises:
    test_wire_constants()
    test_describe_stream()
    test_describe_stream_next_page()
    test_get_shard_iterator_trim_horizon()
    test_get_shard_iterator_after_sequence_number()
    test_get_records()
    test_model_bounds()
    print("OK")
