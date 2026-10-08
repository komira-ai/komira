# komira_aws_ec2

An Amazon EC2 client generated at build time from botocore's `ec2` service
model (ec2Query). EC2's model declares several hundred operations; this
package has the twelve that cover an instance's, a spot request's and a
security group's lifecycle: `RunInstances`, `DescribeInstances`,
`TerminateInstances`, `DescribeSpotInstanceRequests`,
`CancelSpotInstanceRequests`, `DescribeVpcs`, `DescribeSubnets`,
`CreateSecurityGroup`, `DescribeSecurityGroups`,
`AuthorizeSecurityGroupIngress`, `RevokeSecurityGroupIngress` and
`DeleteSecurityGroup`.

The module `komira_aws_ec2.komira_aws_ec2` has, for each operation, a
request struct (`EC2RunInstancesRequest`, ...), `build_<op>_request` (a POST
to `/` with a form body `Action=<Operation>&Version=2016-11-15&...`, lists
under their singular names from 1, as botocore's EC2 serializer writes
them), `parse_<op>_response` (the members of the XML root) and
`resolve_<op>_endpoint` (EC2's published endpoint ruleset, embedded in the
module, over an `EC2EndpointConfig`). `EC2Client[C, S]` puts them together:
each call resolves its endpoint, signs with SigV4 (signing name `ec2`) using
the credentials source `S`, sends over the `komira_http_core` `Connector` `C`
it is given, retries as botocore's standard mode does (EC2's
`RequestLimitExceeded` throttle included), and returns the decoded result or
raises `EC2.<Operation> failed: HTTP <status> <code> <message>`. When a
`RunInstances` caller leaves `ClientToken` unset, the client fills it with a
fresh UUID once per call, so a retried launch does not launch twice.

One departure from botocore: a 200 with an empty body parses as a result
with no members set. The package reads no environment variable and no
credential file.

## Examples

A `RunInstances` request: required counts in the constructor, lists written
under their singular names:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_ec2.komira_aws_ec2 import EC2RunInstancesRequest, EC2TerminateInstancesRequest, build_run_instances_request, build_terminate_instances_request

var input = EC2RunInstancesRequest(Int32(1), Int32(1))  # MaxCount, MinCount
input.set_image_id(String("ami-0abcdef1234567890"))
input.set_instance_type(String("t3.micro"))
var groups: List[String] = ["sg-0aaa", "sg-0bbb"]
input.set_security_group_ids(groups^)
input.set_client_token(String("launch-0001"))
var req = build_run_instances_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(req.header(String("Content-Type")), "application/x-www-form-urlencoded; charset=utf-8")
assert_equal(
    req.body_text(),
    "Action=RunInstances&Version=2016-11-15"
    + "&ImageId=ami-0abcdef1234567890&InstanceType=t3.micro&MaxCount=1&MinCount=1"
    + "&SecurityGroupId.1=sg-0aaa&SecurityGroupId.2=sg-0bbb&ClientToken=launch-0001",
)

var ids: List[String] = ["i-0123456789abcdef0"]
assert_equal(
    build_terminate_instances_request(EC2TerminateInstancesRequest(ids^)).body_text(),
    "Action=TerminateInstances&Version=2016-11-15&InstanceId.1=i-0123456789abcdef0",
)
```

Where a call goes, from the endpoint ruleset:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_ec2.komira_aws_ec2 import EC2DescribeInstancesRequest, EC2EndpointConfig, komira_aws_ec2_endpoint_rules, resolve_describe_instances_endpoint

var rules = komira_aws_ec2_endpoint_rules()
var input = EC2DescribeInstancesRequest()
assert_equal(
    resolve_describe_instances_endpoint(rules, EC2EndpointConfig(String("us-west-2")), input).url,
    "https://ec2.us-west-2.amazonaws.com",
)
assert_equal(
    resolve_describe_instances_endpoint(rules, EC2EndpointConfig(String("cn-north-1")), input).url,
    "https://ec2.cn-north-1.amazonaws.com.cn",
)
```

Reading answers: a `TerminateInstances` result decoded, and EC2's error
document read through `komira_aws_core.aws_query_error`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_aws_core import AwsResponse, aws_query_error
from komira_aws_ec2.komira_aws_ec2 import parse_terminate_instances_response

var out = parse_terminate_instances_response(
    AwsResponse.of_text(
        200,
        String(
            '<TerminateInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">'
            + "<requestId>r-1</requestId><instancesSet><item>"
            + "<instanceId>i-0123456789abcdef0</instanceId>"
            + "<currentState><code>32</code><name>shutting-down</name></currentState>"
            + "<previousState><code>16</code><name>running</name></previousState>"
            + "</item></instancesSet></TerminateInstancesResponse>"
        ),
    )
)
var changes = out.terminating_instances.value().copy()
assert_equal(len(changes), 1)
assert_equal(changes[0].instance_id.value(), "i-0123456789abcdef0")
assert_equal(changes[0].current_state.value().code.value(), Int32(32))
assert_equal(changes[0].previous_state.value().name.value(), "running")

var e = aws_query_error(
    AwsResponse.of_text(
        400,
        String(
            "<Response><Errors><Error><Code>InvalidGroup.NotFound</Code>"
            + "<Message>The security group 'sg-0aaa' does not exist</Message></Error></Errors>"
            + "<RequestID>r-2</RequestID></Response>"
        ),
    )
)
assert_equal(e.code, "InvalidGroup.NotFound")
assert_equal(e.request_id, "r-2")
```

The client end to end, with no socket: `komira_http_core`'s
`ScriptedConnector` answers with canned HTTP responses, so each call is
built, resolved, signed, sent, and its answer decoded or raised, all in
memory. A real program passes a connector that dials the network instead.

<!-- mojo-hidden from std.testing import assert_equal, assert_raises -->
```mojo
from komira_aws_core import AwsCredential, StaticCredsSource
from komira_aws_ec2.komira_aws_ec2 import EC2Client, EC2DescribeInstancesRequest, EC2EndpointConfig, EC2TerminateInstancesRequest
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

def _answer(status: Int, reason: String, body: String) -> ScriptedStream:
    var text = (
        String("HTTP/1.1 ") + String(status) + " " + reason
        + "\r\nContent-Type: text/xml;charset=UTF-8\r\nContent-Length: "
        + String(body.byte_length())
        + "\r\nConnection: close\r\n\r\n" + body
    )
    var raw = List[UInt8]()
    raw.extend(Span(text.as_bytes()))
    return ScriptedStream.from_read_script(raw^)

def _running_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">'
            + "<requestId>r-1</requestId><reservationSet><item>"
            + "<reservationId>r-0a1b2c3d4e5f60718</reservationId><instancesSet><item>"
            + "<instanceId>i-0123456789abcdef0</instanceId>"
            + "<instanceState><code>16</code><name>running</name></instanceState>"
            + "</item></instancesSet></item></reservationSet></DescribeInstancesResponse>",
        )
    )

def _missing_answer() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            "<Response><Errors><Error><Code>InvalidInstanceID.NotFound</Code>"
            + "<Message>The instance ID 'i-0fedcba9876543210' does not exist</Message>"
            + "</Error></Errors><RequestID>r-2</RequestID></Response>",
        )
    )

def _ec2(mk: def () raises thin -> ScriptedConnector) raises -> EC2Client[ScriptedConnector, StaticCredsSource]:
    # A custom endpoint: the scripted connector is plain HTTP and dials nothing.
    var config = EC2EndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return EC2Client[ScriptedConnector, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        StaticCredsSource(AwsCredential(String("AKIDEXAMPLE"), String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"), String(""))),
        String("us-east-1"),
        config^,
    )

var client = _ec2(_running_answer)
var out = client.describe_instances(EC2DescribeInstancesRequest())
var instances = out.reservations.value()[0].instances.value().copy()
assert_equal(instances[0].instance_id.value(), "i-0123456789abcdef0")
assert_equal(instances[0].state.value().name.value(), "running")

var missing = _ec2(_missing_answer)
var ids: List[String] = ["i-0fedcba9876543210"]
with assert_raises(contains="EC2.TerminateInstances failed: HTTP 400 InvalidInstanceID.NotFound"):
    _ = missing.terminate_instances(EC2TerminateInstancesRequest(ids^))
```
