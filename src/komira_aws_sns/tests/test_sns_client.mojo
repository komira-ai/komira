# The generated SNS client (`SNSSNSClient`) end to end over
# komira_http_client and komira_http_core's ScriptedConnector (no socket),
# sent to a custom endpoint: a Subscribe answered with its
# <SubscribeResult>, and a DeleteTopic answered with an <ErrorResponse>,
# raised under the error's code and message (a 404 naming no code botocore
# retries, so nothing is retried).
#
# Then the CreateTopic request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an XML error naming the
# request head, so the row asserts the request line, the Host, the form
# Content-Type and the SigV4 scope, through the generated client.
from komira_aws_sns.komira_aws_sns import (
    SNSCreateTopicInput,
    SNSDeleteTopicInput,
    SNSEndpointConfig,
    SNSSNSClient,
    SNSSubscribeInput,
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


comptime _TOPIC = "arn:aws:sns:us-east-1:000000000000:bounces"


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
            + "\r\nContent-Type: text/xml\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n"
            + "x-amzn-RequestId: 0a7e1a7b-0000-4000-8000-1234567890aa\r\n"
            + "\r\n"
            + body
        )
    )


def _mk_subscribed() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            "<SubscribeResponse><SubscribeResult>"
            + "<SubscriptionArn>arn:aws:sns:us-east-1:000000000000:bounces:4f6a0c1e</SubscriptionArn>"
            + "</SubscribeResult><ResponseMetadata><RequestId>r-1</RequestId>"
            + "</ResponseMetadata></SubscribeResponse>",
        )
    )


def _mk_missing() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            "<ErrorResponse><Error><Type>Sender</Type><Code>NotFound</Code>"
            + "<Message>Topic does not exist</Message></Error>"
            + "<RequestId>0a7e1a7b-0000-4000-8000-1234567890aa</RequestId></ErrorResponse>",
        )
    )


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> SNSSNSClient[C, StaticCredsSource]:
    var config = SNSEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return SNSSNSClient[C, StaticCredsSource](
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


def test_subscribe() raises:
    var client = _client(_mk_subscribed)
    var input = SNSSubscribeInput(String(_TOPIC), String("sqs"))
    input.set_endpoint(String("arn:aws:sqs:us-east-1:000000000000:bounces"))
    var out = client.subscribe(input)
    assert_equal(out.subscription_arn.value(), "arn:aws:sns:us-east-1:000000000000:bounces:4f6a0c1e")


def test_a_missing_topic_is_raised_under_its_code() raises:
    var client = _client(_mk_missing)
    with assert_raises(contains="SNSSNS.DeleteTopic failed: HTTP 404 NotFound Topic does not exist"):
        _ = client.delete_topic(SNSDeleteTopicInput(String(_TOPIC)))


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def test_create_topic_on_the_wire() raises:
    var client = _client(_mk_echo)
    var wire = String("")
    try:
        _ = client.create_topic(SNSCreateTopicInput(String("bounces")))
    except e:
        var text = String(e)
        var marker = String("CreateTopic failed: HTTP 400 ") + AWS_ECHO_CODE + " "
        var at = text.find(marker)
        assert_true(at >= 0, text)
        wire = String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:4566",
        "content-type: application/x-www-form-urlencoded; charset=utf-8",
        "/us-east-1/sns/aws4_request, signedheaders=content-type;host;x-amz-date,",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " is not in " + wire)


def main() raises:
    test_subscribe()
    test_a_missing_topic_is_raised_under_its_code()
    test_create_topic_on_the_wire()
    print("OK")
