# komira_aws_dynamodb

An Amazon DynamoDB client generated at build time from botocore's `dynamodb`
service model (awsJson 1.0), for the operations a table's owner and its
readers and writers call: `GetItem`, `PutItem`, `UpdateItem`, `DeleteItem`,
`Query`, `Scan`, `CreateTable`, `DescribeTable`, `UpdateTable`,
`DeleteTable`, `DescribeTimeToLive`, `UpdateTimeToLive`,
`DescribeContinuousBackups` and `UpdateContinuousBackups`.

For each operation the module `komira_aws_dynamodb.komira_aws_dynamodb` has
an input struct (`DynamoDBGetItemInput`, ...), `build_<op>_request`, which
returns the exact `komira_aws_core.AwsRequest` (method, path, the
`X-Amz-Target` and `Content-Type` headers, the JSON body, an unset member
absent), `parse_<op>_response`, which decodes the service's answer into the
operation's output struct, and `resolve_<op>_endpoint`, which runs the
service's published endpoint ruleset (embedded in the module) over a
`DynamoDBEndpointConfig` (region, FIPS, dual stack, custom endpoint, account
id). Each modeled error has a struct with `from_aws_json`.

This package is pure: it has no transport and opens no connection. A caller
signs a built request with `komira_aws_core.build_sigv4_signed_request`
(signing name `dynamodb`) and sends it with an HTTP client of its choice.
It reads no environment variable and no credential file; every input,
credentials included, is a parameter.

## Examples

A `GetItem` request, exactly as it goes on the wire:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_dynamodb.komira_aws_dynamodb import DynamoDBAttributeValue, DynamoDBGetItemInput, build_get_item_request

var pk = DynamoDBAttributeValue()
pk.set_s(String("route#1"))
var key = Dict[String, DynamoDBAttributeValue]()
key["pk"] = pk^
var input = DynamoDBGetItemInput(String("routes"), key^)
input.set_consistent_read(True)

var req = build_get_item_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(req.header(String("X-Amz-Target")), "DynamoDB_20120810.GetItem")
assert_equal(req.header(String("Content-Type")), "application/x-amz-json-1.0")
assert_equal(
    req.body_text(),
    '{"TableName":"routes","Key":{"pk":{"S":"route#1"}},"ConsistentRead":true}',
)
```

Where the request goes: the endpoint ruleset resolved for a region, and for
the FIPS endpoint. A missing region is refused with the ruleset's own message:

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_aws_dynamodb.komira_aws_dynamodb import DynamoDBDescribeTableInput, DynamoDBEndpointConfig, komira_aws_dynamodb_endpoint_rules, resolve_describe_table_endpoint

var rules = komira_aws_dynamodb_endpoint_rules()
var table = DynamoDBDescribeTableInput(String("routes"))
var got = resolve_describe_table_endpoint(rules, DynamoDBEndpointConfig(String("us-west-2")), table)
assert_equal(got.url, "https://dynamodb.us-west-2.amazonaws.com")

var fips = DynamoDBEndpointConfig(String("us-east-1"))
fips.use_fips = Optional[Bool](True)
assert_equal(
    resolve_describe_table_endpoint(rules, fips, table).url,
    "https://dynamodb-fips.us-east-1.amazonaws.com",
)

with assert_raises(contains="Invalid Configuration: Missing Region"):
    _ = resolve_describe_table_endpoint(rules, DynamoDBEndpointConfig(), table)
```

The send-side chain without the send: built, resolved, and signed with SigV4
by `komira_aws_core` for a fixed clock and the documentation's example key
(no real credential, no network). The signature is the one AWS's algorithm
gives for these exact bytes:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsCredential, FixedClock, Header, aws_signing_target, build_sigv4_signed_request
from komira_aws_dynamodb.komira_aws_dynamodb import DynamoDBAttributeValue, DynamoDBEndpointConfig, DynamoDBGetItemInput, build_get_item_request, komira_aws_dynamodb_endpoint_rules, resolve_get_item_endpoint

var pk = DynamoDBAttributeValue()
pk.set_s(String("route#1"))
var key = Dict[String, DynamoDBAttributeValue]()
key["pk"] = pk^
var input = DynamoDBGetItemInput(String("routes"), key^)
input.set_consistent_read(True)
var built = build_get_item_request(input)

var config = DynamoDBEndpointConfig(String("us-east-1"))
var resolved = resolve_get_item_endpoint(komira_aws_dynamodb_endpoint_rules(), config, input)
var target = aws_signing_target(resolved, String("us-east-1"), String("dynamodb"))

var extra = List[Header]()
var content_type = String("")
for i in range(len(built.header_names)):
    if built.header_names[i] == "Content-Type":
        content_type = built.header_values[i]
    else:
        extra.append(Header(built.header_names[i], built.header_values[i]))
var clock = FixedClock(1790812800)  # 2026-10-01T00:00:00Z
var signed = build_sigv4_signed_request(
    built.method,
    AwsCredential(
        String("AKIAIOSFODNN7EXAMPLE"),
        String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
        String(""),
    ),
    target.signing_region,
    target.signing_name,
    target.endpoint,
    built.uri,
    content_type,
    Span(built.body),
    extra,
    clock,
)
assert_equal(signed.host, "dynamodb.us-east-1.amazonaws.com")
assert_equal(
    signed.header("Authorization"),
    "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1"
    + "/dynamodb/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-target, "
    + "Signature=fff22b3c26f60d65596e680a4883fb6a0c17d7a9c2bec7ec48bd5344aab5ae70",
)
```

Reading answers: a `GetItem` result decoded, and a failed conditional write
read through `komira_aws_core.aws_json_error_info` and then as its modeled
error shape, which carries the item the condition saw:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_aws_core import AwsResponse, aws_is_error_status, aws_json_error_info
from komira_aws_dynamodb.komira_aws_dynamodb import DynamoDBConditionalCheckFailedException, parse_get_item_response
from komira_json import parse_json_value

var r = parse_get_item_response(
    AwsResponse.of_text(200, String('{"Item":{"pk":{"S":"route#1"},"n":{"N":"3"}}}'))
)
var item = r.item.value().copy()
assert_equal(item["pk"].s.value(), "route#1")
assert_equal(item["n"].n.value(), "3")
assert_false(Bool(parse_get_item_response(AwsResponse.of_text(200, String("{}"))).item))

var resp = AwsResponse.of_text(
    400,
    String(
        '{"__type":"com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException",'
        + '"message":"The conditional request failed","Item":{"pk":{"S":"r"},"v":{"N":"3"}}}'
    ),
)
assert_true(aws_is_error_status(resp.status))
var info = aws_json_error_info(resp)
assert_equal(info.code, "ConditionalCheckFailedException")
assert_equal(info.message, "The conditional request failed")
var e = DynamoDBConditionalCheckFailedException.from_aws_json(parse_json_value(resp.body_text()))
assert_equal(e.item.value()["v"].n.value(), "3")
```
