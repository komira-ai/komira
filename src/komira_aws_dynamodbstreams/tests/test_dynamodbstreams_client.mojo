# The generated DynamoDB Streams client
# (`DynamoDBStreamsClient`) end to end over
# komira_http_client and komira_http_core's ScriptedConnector (no socket): a
# GetShardIterator answered, and a GetRecords whose iterator has expired,
# raised under its code with the service's message. The error is a 400
# naming no code botocore retries, so nothing is retried.
#
# Then the DescribeStream request as it reached the wire: the client is
# given komira_aws_core's AwsEchoConnector, whose answer is an awsJson error
# naming the request head, so the row asserts the request line, the Host the
# endpoint ruleset resolved, the awsJson target and content type and the
# SigV4 scope, through the generated client.
from komira_aws_dynamodbstreams.komira_aws_dynamodbstreams import (
    DynamoDBStreamsDescribeStreamInput,
    DynamoDBStreamsClient,
    DynamoDBStreamsEndpointConfig,
    DynamoDBStreamsGetRecordsInput,
    DynamoDBStreamsGetShardIteratorInput,
)
from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsCredential,
    AwsEchoConnector,
    StaticCredsSource,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from std.testing import assert_equal, assert_raises, assert_true

comptime _ARN = "arn:aws:dynamodb:us-east-1:123456789012:table/jobs/stream/2026-10-01T00:00:00.000"
comptime _SHARD = "shardId-00000001790812800000-0a1b2c3d"


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String, headers: String) -> ScriptedStream:
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 ")
            + String(status)
            + " "
            + reason
            + "\r\nContent-Type: application/x-amz-json-1.0\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n"
            + headers
            + "\r\n"
            + body
        )
    )


def _mk_ok() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"ShardIterator":"arn:aws:dynamodb:us-east-1:000000000000:iterator/AAAA"}',
            "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890aa\r\n",
        )
    )


def _mk_err() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"__type":"com.amazonaws.dynamodb.v20120810#ExpiredIteratorException","message":"Iterator expired"}',
            "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890ab\r\n",
        )
    )


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> DynamoDBStreamsClient[C, StaticCredsSource]:
    var config = DynamoDBStreamsEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return DynamoDBStreamsClient[C, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(
            AwsCredential(
                String("AKIDEXAMPLE"),
                String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
                String(""),
            )
        ),
        String("us-east-1"),
        config^,
    )


def test_get_shard_iterator() raises:
    var client = _client(_mk_ok)
    var out = client.get_shard_iterator(DynamoDBStreamsGetShardIteratorInput(String(_ARN), String(_SHARD), String("TRIM_HORIZON")))
    assert_equal(out.shard_iterator.value(), "arn:aws:dynamodb:us-east-1:000000000000:iterator/AAAA")


def test_an_error_is_raised_under_its_code() raises:
    var client = _client(_mk_err)
    with assert_raises(contains="DynamoDBStreams.GetRecords failed: HTTP 400 ExpiredIteratorException Iterator expired"):
        _ = client.get_records(DynamoDBStreamsGetRecordsInput(String("arn:aws:dynamodb:us-east-1:000000000000:iterator/OLD")))


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.json()


def test_describe_stream_on_the_wire() raises:
    var client = _client(_mk_echo)
    var wire = String("")
    try:
        _ = client.describe_stream(DynamoDBStreamsDescribeStreamInput(String(_ARN)))
    except e:
        var text = String(e)
        var marker = String("DescribeStream failed: HTTP 400 ") + AWS_ECHO_CODE + " "
        var at = text.find(marker)
        assert_true(at >= 0, text)
        wire = String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:4566",
        "x-amz-target: dynamodbstreams_20120810.describestream",
        "content-type: application/x-amz-json-1.0",
        "/us-east-1/dynamodb/aws4_request, signedheaders=",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " is not in " + wire)
    # awsJson 1.0 sends no query-mode header: only SQS asks for one.
    assert_true(wire.find("x-amzn-query-mode") < 0, wire)


def main() raises:
    test_get_shard_iterator()
    test_an_error_is_raised_under_its_code()
    test_describe_stream_on_the_wire()
    print("OK")
