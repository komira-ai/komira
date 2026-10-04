# The generated EC2 client (`EC2EC2Client`) end to end over
# komira_http_client and komira_http_core's ScriptedConnector (no socket),
# sent to a custom endpoint: a DescribeInstances answered with its
# reservations, and a TerminateInstances answered with ec2's
# <Response><Errors><Error> document, raised under the error's code and
# message (a 400 naming no code botocore retries, so nothing is retried).
#
# Then the DescribeVpcs request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an XML error naming the
# request head, so the row asserts the request line, the Host, the form
# Content-Type and the SigV4 scope, through the generated client.
from komira_aws_ec2.komira_aws_ec2 import (
    EC2DescribeInstancesRequest,
    EC2DescribeVpcsRequest,
    EC2EC2Client,
    EC2EndpointConfig,
    EC2TerminateInstancesRequest,
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


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _answer(status: Int, reason: String, body: String) -> ScriptedStream:
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 ")
            + String(status)
            + " "
            + reason
            + "\r\nContent-Type: text/xml;charset=UTF-8\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n"
            + "\r\n"
            + body
        )
    )


def _mk_found() raises -> ScriptedConnector:
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


def _mk_missing() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            "<Response><Errors><Error><Code>InvalidInstanceID.NotFound</Code>"
            + "<Message>The instance ID 'i-0fedcba9876543210' does not exist</Message>"
            + "</Error></Errors><RequestID>5a2c9a5f-0000-4000-8000-1234567890aa</RequestID></Response>",
        )
    )


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> EC2EC2Client[C, StaticCredsSource]:
    var config = EC2EndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return EC2EC2Client[C, StaticCredsSource](
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


def test_describe_instances() raises:
    var client = _client(_mk_found)
    var out = client.describe_instances(EC2DescribeInstancesRequest())
    var reservations = out.reservations.value().copy()
    assert_equal(len(reservations), 1)
    var instances = reservations[0].instances.value().copy()
    assert_equal(instances[0].instance_id.value(), "i-0123456789abcdef0")
    assert_equal(instances[0].state.value().name.value(), "running")


def test_a_missing_instance_is_raised_under_its_code() raises:
    var client = _client(_mk_missing)
    var ids: List[String] = ["i-0fedcba9876543210"]
    with assert_raises(
        contains=(
            "EC2EC2.TerminateInstances failed: HTTP 400 InvalidInstanceID.NotFound"
            " The instance ID 'i-0fedcba9876543210' does not exist"
        )
    ):
        _ = client.terminate_instances(EC2TerminateInstancesRequest(ids^))


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def test_describe_vpcs_on_the_wire() raises:
    var client = _client(_mk_echo)
    var wire = String("")
    try:
        _ = client.describe_vpcs(EC2DescribeVpcsRequest())
    except e:
        var text = String(e)
        var marker = String("DescribeVpcs failed: HTTP 400 ") + AWS_ECHO_CODE + " "
        var at = text.find(marker)
        assert_true(at >= 0, text)
        wire = String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:4566",
        "content-type: application/x-www-form-urlencoded; charset=utf-8",
        "/us-east-1/ec2/aws4_request, signedheaders=content-type;host;x-amz-date,",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " is not in " + wire)


def main() raises:
    test_describe_instances()
    test_a_missing_instance_is_raised_under_its_code()
    test_describe_vpcs_on_the_wire()
    print("OK")
