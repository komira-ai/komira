# The generated Amazon ECS client (`ECSECSClient`) end to end over
# komira_http_client and komira_http_core's ScriptedConnector (no socket): a
# ListClusters answered, and a StopTask in a cluster that does not exist,
# raised under its code with the service's message. The error is a 400
# naming no code botocore retries, so nothing is retried.
#
# Then the RunTask request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an awsJson error
# naming the request head, so the row asserts the request line, the Host the
# endpoint ruleset resolved, the awsJson target and content type and the
# SigV4 scope, through the generated client.
from komira_aws_ecs.komira_aws_ecs import (
    ECSECSClient,
    ECSEndpointConfig,
    ECSListClustersRequest,
    ECSRunTaskRequest,
    ECSStopTaskRequest,
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


def _stop(cluster: String) -> ECSStopTaskRequest:
    var r = ECSStopTaskRequest(String("arn:aws:ecs:us-east-1:000000000000:task/gone/0123456789abcdef"))
    r.set_cluster(cluster)
    return r^


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
            + "\r\nContent-Type: application/x-amz-json-1.1\r\nContent-Length: "
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
            '{"clusterArns":["arn:aws:ecs:us-east-1:000000000000:cluster/jobs"],"nextToken":"page-2"}',
            "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890aa\r\n",
        )
    )


def _mk_err() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"__type":"ClusterNotFoundException","message":"Cluster not found."}',
            "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890ab\r\n",
        )
    )


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> ECSECSClient[C, StaticCredsSource]:
    var config = ECSEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return ECSECSClient[C, StaticCredsSource](
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


def test_list_clusters() raises:
    var client = _client(_mk_ok)
    var out = client.list_clusters(ECSListClustersRequest())
    var arns = out.cluster_arns.value().copy()
    assert_equal(len(arns), 1)
    assert_equal(arns[0], "arn:aws:ecs:us-east-1:000000000000:cluster/jobs")
    assert_equal(out.next_token.value(), "page-2")


def test_an_error_is_raised_under_its_code() raises:
    var client = _client(_mk_err)
    with assert_raises(contains="ECSECS.StopTask failed: HTTP 400 ClusterNotFoundException Cluster not found."):
        _ = client.stop_task(_stop(String("gone")))


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.json()


def test_run_task_on_the_wire() raises:
    var client = _client(_mk_echo)
    var wire = String("")
    try:
        _ = client.run_task(ECSRunTaskRequest(String("jobs:3")))
    except e:
        var text = String(e)
        var marker = String("RunTask failed: HTTP 400 ") + AWS_ECHO_CODE + " "
        var at = text.find(marker)
        assert_true(at >= 0, text)
        wire = String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:4566",
        "x-amz-target: amazonec2containerservicev20141113.runtask",
        "content-type: application/x-amz-json-1.1",
        "/us-east-1/ecs/aws4_request, signedheaders=",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " is not in " + wire)
    # awsJson 1.1 sends no query-mode header: only SQS asks for one.
    assert_true(wire.find("x-amzn-query-mode") < 0, wire)


def main() raises:
    test_list_clusters()
    test_an_error_is_raised_under_its_code()
    test_run_task_on_the_wire()
    print("OK")
