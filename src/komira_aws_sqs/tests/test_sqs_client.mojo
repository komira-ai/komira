# The generated SQS client (`SQSSQSClient`) end to end over
# komira_http_client and komira_http_core's ScriptedConnector (no socket):
# a GetQueueUrl answered, and one whose queue does not exist. SQS is
# awsQueryCompatible, so it names the error's legacy query code in an
# `x-amzn-query-error` header beside the shape name in `__type`; the
# client raises the query code, AWS.SimpleQueueService.NonExistentQueue, as
# botocore and the Go v2 SDK report it. Both answers are a POST's, and the
# error is a 400, so nothing is retried.
#
# Then the GetQueueUrl request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an awsJson error
# naming the request head, so the row asserts the request line, the Host
# the endpoint ruleset resolved, the awsJson target and query-mode headers
# and the SigV4 scope, through the generated client.
from komira_aws_sqs.komira_aws_sqs import (
    SQSEndpointConfig,
    SQSGetQueueUrlRequest,
    SQSSQSClient,
)
from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsCredential,
    AwsEchoConnector,
    StaticCredsSource,
)
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from std.testing import assert_equal, assert_raises, assert_true


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


def _mk_found() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"QueueUrl":"http://127.0.0.1:9324/000000000000/jobs"}',
            "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890aa\r\n",
        )
    )


def _mk_missing() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"__type":"com.amazonaws.sqs#QueueDoesNotExist",'
            '"message":"The specified queue does not exist."}',
            "x-amzn-query-error: AWS.SimpleQueueService.NonExistentQueue;Sender\r\n"
            "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890ab\r\n",
        )
    )


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> SQSSQSClient[C, StaticCredsSource]:
    var config = SQSEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:9324"))
    return SQSSQSClient[C, StaticCredsSource](
        mk,
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


def test_get_queue_url() raises:
    var client = _client(_mk_found)
    var out = client.get_queue_url(SQSGetQueueUrlRequest(String("jobs")))
    assert_equal(out.queue_url.value(), "http://127.0.0.1:9324/000000000000/jobs")


def test_a_missing_queue_is_raised_under_its_query_code() raises:
    var client = _client(_mk_missing)
    with assert_raises(
        contains=(
            "GetQueueUrl failed: HTTP 400 AWS.SimpleQueueService.NonExistentQueue"
            " The specified queue does not exist."
        )
    ):
        _ = client.get_queue_url(SQSGetQueueUrlRequest(String("gone")))


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.json()


def test_get_queue_url_on_the_wire() raises:
    var client = _client(_mk_echo)
    var wire = String("")
    try:
        _ = client.get_queue_url(SQSGetQueueUrlRequest(String("jobs")))
    except e:
        var text = String(e)
        var marker = String("GetQueueUrl failed: HTTP 400 ") + AWS_ECHO_CODE + " "
        var at = text.find(marker)
        assert_true(at >= 0, text)
        wire = String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:9324",
        "x-amz-target: amazonsqs.getqueueurl",
        "x-amzn-query-mode: true",
        "content-type: application/x-amz-json-1.0",
        "/us-east-1/sqs/aws4_request, signedheaders=",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " is not in " + wire)


def main() raises:
    test_get_queue_url()
    test_a_missing_queue_is_raised_under_its_query_code()
    test_get_queue_url_on_the_wire()
    print("OK")
