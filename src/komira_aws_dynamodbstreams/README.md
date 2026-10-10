# komira_aws_dynamodbstreams

An Amazon DynamoDB Streams client generated at build time from botocore's
`dynamodbstreams` service model (awsJson 1.0), for what a change-stream
reader calls: `DescribeStream` (a stream and its shards), `GetShardIterator`
(an iterator on a shard) and `GetRecords` (the shard's records, a page at a
time, with each record's keys and old and new images).

The module `komira_aws_dynamodbstreams.komira_aws_dynamodbstreams` has, for
each operation, an input struct, `build_<op>_request` (the exact
`komira_aws_core.AwsRequest`), `parse_<op>_response` and
`resolve_<op>_endpoint` (the service's published endpoint ruleset, embedded
in the module, over a `DynamoDBStreamsEndpointConfig`).
`DynamoDBStreamsClient[C, S]` puts them together: each call resolves its
endpoint, signs with SigV4 (signing name `dynamodb`, as the model says)
using the credentials source `S`, sends over the `komira_http_core`
`Connector` `C` it is given, retries as botocore's standard mode does, and
returns the decoded result or raises `DynamoDBStreams.<Operation> failed:
HTTP <status> <code> <message>`.

It reads no environment variable and no credential file. It does not track
shard lineage or checkpoint a reader's position: the caller walks shards and
keeps its own iterators.

## Examples

A `GetShardIterator` request, exactly as it goes on the wire, and where it
goes:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_dynamodbstreams.komira_aws_dynamodbstreams import DynamoDBStreamsEndpointConfig, DynamoDBStreamsGetShardIteratorInput, build_get_shard_iterator_request, komira_aws_dynamodbstreams_endpoint_rules, resolve_get_shard_iterator_endpoint

var stream = String("arn:aws:dynamodb:us-east-1:123456789012:table/jobs/stream/2026-10-01T00:00:00.000")
var shard = String("shardId-00000001790812800000-0a1b2c3d")
var input = DynamoDBStreamsGetShardIteratorInput(stream, shard, String("TRIM_HORIZON"))
var req = build_get_shard_iterator_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(req.header(String("X-Amz-Target")), "DynamoDBStreams_20120810.GetShardIterator")
assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.0")
assert_equal(
    req.body_text(),
    '{"StreamArn":"' + stream + '","ShardId":"' + shard + '","ShardIteratorType":"TRIM_HORIZON"}',
)

var got = resolve_get_shard_iterator_endpoint(
    komira_aws_dynamodbstreams_endpoint_rules(),
    DynamoDBStreamsEndpointConfig(String("us-west-2")),
    input,
)
assert_equal(got.url, "https://streams.dynamodb.us-west-2.amazonaws.com")
```

A `GetRecords` page decoded: each record's event, keys and new image, and the
iterator for the next page:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsResponse
from komira_aws_dynamodbstreams.komira_aws_dynamodbstreams import parse_get_records_response

var body = String(
    '{"Records":[{"eventID":"7de3041d","eventName":"INSERT","eventSource":"aws:dynamodb",'
    + '"awsRegion":"us-east-1","dynamodb":{"ApproximateCreationDateTime":1790812801,'
    + '"Keys":{"pk":{"S":"job#42"}},"NewImage":{"pk":{"S":"job#42"},"tries":{"N":"3"}},'
    + '"SequenceNumber":"100000000000000000001","SizeBytes":30,'
    + '"StreamViewType":"NEW_AND_OLD_IMAGES"}}],'
    + '"NextShardIterator":"arn:aws:dynamodb:us-east-1:123456789012:iterator/BBBB"}'
)
var page = parse_get_records_response(AwsResponse.of_text(200, body))
assert_equal(page.next_shard_iterator.value(), "arn:aws:dynamodb:us-east-1:123456789012:iterator/BBBB")
var records = page.records.value().copy()
assert_equal(len(records), 1)
assert_equal(records[0].event_name.value(), "INSERT")
var change = records[0].dynamodb.value().copy()
assert_equal(change.sequence_number.value(), "100000000000000000001")
assert_equal(change.keys.value()["pk"].s.value(), "job#42")
assert_equal(change.new_image.value()["tries"].n.value(), "3")
```

The client end to end, with no socket: `komira_http_core`'s
`ScriptedConnector` answers with canned HTTP responses, so each call is
built, resolved, signed, sent, and its answer decoded or raised, all in
memory. A real program passes a connector that dials the network instead.

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_dynamodbstreams.komira_aws_dynamodbstreams import DynamoDBStreamsClient, DynamoDBStreamsEndpointConfig, DynamoDBStreamsGetRecordsInput, DynamoDBStreamsGetShardIteratorInput
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

def _answer(status: Int, reason: String, body: String) -> ScriptedStream:
    var text = (
        String("HTTP/1.1 ") + String(status) + " " + reason
        + "\r\nContent-Type: application/x-amz-json-1.0\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var raw = List[UInt8]()
    raw.extend(Span(text.as_bytes()))
    return ScriptedStream.from_read_script(raw^)

def _iterator_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(200, "OK", '{"ShardIterator":"arn:aws:dynamodb:us-east-1:000000000000:iterator/AAAA"}')
    )

def _expired_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(400, "Bad Request", '{"__type":"ExpiredIteratorException","message":"Iterator expired"}')
    )

def _streams(mk: def () raises thin -> ScriptedConnector) raises -> DynamoDBStreamsClient[ScriptedConnector, StaticCredsSource]:
    # A custom endpoint: the scripted connector is plain HTTP and dials nothing.
    var config = DynamoDBStreamsEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return DynamoDBStreamsClient[ScriptedConnector, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(AwsCredential(String("AKIDEXAMPLE"), String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), String(""))),
        String("us-east-1"),
        config^,
    )

var client = _streams(_iterator_answer)
var out = client.get_shard_iterator(
    DynamoDBStreamsGetShardIteratorInput(
        String("arn:aws:dynamodb:us-east-1:000000000000:table/jobs/stream/2026-10-01T00:00:00.000"),
        String("shardId-00000001790812800000-0a1b2c3d"),
        String("LATEST"),
    )
)
assert_equal(out.shard_iterator.value(), "arn:aws:dynamodb:us-east-1:000000000000:iterator/AAAA")

var stale = _streams(_expired_answer)
with assert_raises(contains="DynamoDBStreams.GetRecords failed: HTTP 400 ExpiredIteratorException Iterator expired"):
    _ = stale.get_records(DynamoDBStreamsGetRecordsInput(String("arn:aws:dynamodb:us-east-1:000000000000:iterator/OLD")))
```
