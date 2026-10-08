# komira_aws_sns

An Amazon SNS client for topics and subscriptions, generated at build time
from botocore's pinned `sns` model (awsQuery). The module
`komira_aws_sns.komira_aws_sns` holds, for CreateTopic, DeleteTopic,
GetTopicAttributes, SetTopicAttributes, Subscribe, Unsubscribe,
ListSubscriptionsByTopic, GetSubscriptionAttributes and
SetSubscriptionAttributes:

- an input struct (`SNS<Operation>Input`) and its builder
  `build_<operation>_request`, which returns a komira_aws_core `AwsRequest`:
  a POST to `/` whose body is the form `Action=<Operation>&Version=2010-03-31`
  followed by the members, maps and lists flattened as awsQuery flattens them;
- a response parser `parse_<operation>_response`, which reads the
  `<OperationResult>` element of a komira_aws_core `AwsResponse`;
- an endpoint resolver `resolve_<operation>_endpoint`, which runs the
  service's published endpoint ruleset (`komira_aws_sns_endpoint_rules()`)
  over an `SNSEndpointConfig`;
- `SNSClient`, which resolves each call's endpoint, signs it with SigV4
  (signing name `sns`) and sends it over the komira_http_core `Connector` it
  is given, retried as botocore's standard mode retries.

Publish and SNS's other operations are not generated. The package reads no
environment.

## Examples

Build a Subscribe request for an HTTPS endpoint. Nothing is sent; the form
body is percent-encoded:

<!-- mojo-hidden from std.testing import assert_equal, assert_true -->
```mojo
from komira_aws_sns.komira_aws_sns import SNSSubscribeInput, build_subscribe_request

var input = SNSSubscribeInput(String("arn:aws:sns:us-east-1:123456789012:bounces"), String("https"))
input.set_endpoint(String("https://hooks.example.com/sns"))
input.set_return_subscription_arn(True)
var req = build_subscribe_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(
    req.header(String("Content-Type")),
    "application/x-www-form-urlencoded; charset=utf-8",
)
assert_equal(
    req.body_text(),
    "Action=Subscribe&Version=2010-03-31"
    + "&TopicArn=arn%3Aaws%3Asns%3Aus-east-1%3A123456789012%3Abounces"
    + "&Protocol=https&Endpoint=https%3A%2F%2Fhooks.example.com%2Fsns"
    + "&ReturnSubscriptionArn=true",
)
```

A map member is numbered entries, in the caller's insertion order:

```mojo
from komira_aws_sns.komira_aws_sns import SNSCreateTopicInput, build_create_topic_request

var topic = SNSCreateTopicInput(String("bounces"))
var attrs = Dict[String, String]()
attrs["DisplayName"] = String("mail bounces")
topic.set_attributes(attrs^)
assert_equal(
    build_create_topic_request(topic).body_text(),
    "Action=CreateTopic&Version=2010-03-31&Name=bounces"
    + "&Attributes.entry.1.key=DisplayName&Attributes.entry.1.value=mail%20bounces",
)
```

Decode a CreateTopic answer, and read an `<ErrorResponse>` with
komira_aws_core's `aws_query_error`:

```mojo
from komira_aws_core import AwsResponse, aws_query_error
from komira_aws_sns.komira_aws_sns import parse_create_topic_response

var out = parse_create_topic_response(
    AwsResponse.of_text(
        200,
        String(
            '<CreateTopicResponse xmlns="https://sns.amazonaws.com/doc/2010-03-31/">'
            + "<CreateTopicResult><TopicArn>arn:aws:sns:us-east-1:123456789012:bounces</TopicArn>"
            + "</CreateTopicResult><ResponseMetadata><RequestId>req-1</RequestId>"
            + "</ResponseMetadata></CreateTopicResponse>"
        ),
    )
)
assert_equal(out.topic_arn.value(), "arn:aws:sns:us-east-1:123456789012:bounces")

var e = aws_query_error(
    AwsResponse.of_text(
        404,
        String(
            '<ErrorResponse xmlns="https://sns.amazonaws.com/doc/2010-03-31/">'
            + "<Error><Type>Sender</Type><Code>NotFound</Code>"
            + "<Message>Topic does not exist</Message></Error>"
            + "<RequestId>req-2</RequestId></ErrorResponse>"
        ),
    )
)
assert_equal(e.status, 404)
assert_equal(e.code, "NotFound")
assert_equal(e.message, "Topic does not exist")
```

Resolve the endpoint a call goes to:

```mojo
from komira_aws_sns.komira_aws_sns import SNSEndpointConfig, komira_aws_sns_endpoint_rules
from komira_aws_sns.komira_aws_sns import resolve_create_topic_endpoint

var rules = komira_aws_sns_endpoint_rules()
var create = SNSCreateTopicInput(String("bounces"))
assert_equal(
    resolve_create_topic_endpoint(rules, SNSEndpointConfig(String("us-west-2")), create).url,
    "https://sns.us-west-2.amazonaws.com",
)
var fips = SNSEndpointConfig(String("us-east-1"))
fips.use_fips = Optional[Bool](True)
assert_equal(
    resolve_create_topic_endpoint(rules, fips, create).url,
    "https://sns-fips.us-east-1.amazonaws.com",
)
```
