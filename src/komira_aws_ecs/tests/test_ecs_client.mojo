# The generated Amazon ECS client (`ECSClient`) end to end over
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
#
# Then RunTask's idempotency token, over a transport that records each
# attempt: a RunTask sent without a clientToken carries one the client made,
# and its retry after a 500 carries the same one, so the service starts the
# task once; a token the caller set is sent as set.
from komira_aws_ecs.komira_aws_ecs import (
    ECSClient,
    ECSEndpointConfig,
    ECSListClustersRequest,
    ECSRunTaskRequest,
    ECSStopTaskRequest,
)
from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsClock,
    AwsConnectorTransport,
    AwsCredential,
    AwsEchoConnector,
    AwsHttpTransport,
    AwsRetryQuota,
    CredentialHttpRequest,
    HttpResult,
    StaticCredsSource,
    aws_standard_retry_policy,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock, RecordingSleeper, RetryLoop, SplitMix64Rng
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
) raises -> ECSClient[C, StaticCredsSource]:
    var config = ECSEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return ECSClient[C, StaticCredsSource](
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
    with assert_raises(contains="ECS.StopTask failed: HTTP 400 ClusterNotFoundException Cluster not found."):
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


struct _Clock(AwsClock, Movable):
    def __init__(out self):
        pass

    def now_unix_seconds(mut self) -> Int:
        return 1_790_000_000


struct _Recording(AwsHttpTransport, Movable, Deinitable):
    """Keeps each attempt's signed request, then sends it on."""

    var inner: AwsConnectorTransport[ScriptedConnector]
    var sent: List[CredentialHttpRequest]

    def __init__(out self, var c: ScriptedConnector) raises:
        self.inner = AwsConnectorTransport[ScriptedConnector](c^)
        self.sent = List[CredentialHttpRequest]()

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        self.sent.append(req.copy())
        return self.inner.send(req)


def _assert_uuid4(tok: String) raises:
    """A version 4 UUID in its lowercase hyphenated form, as botocore's
    `str(uuid.uuid4())` writes it: 36 bytes, hyphens at 8, 13, 18 and 23,
    the version nibble 4 and a variant nibble of 8, 9, a or b."""
    assert_equal(tok.byte_length(), 36, tok)
    var hex = String("0123456789abcdef")
    for i in range(36):
        var ch = String(tok[byte=i:i+1])
        if i == 8 or i == 13 or i == 18 or i == 23:
            assert_equal(ch, "-", tok)
        else:
            assert_true(hex.find(ch) >= 0, tok)
    assert_equal(String(tok[byte=14:15]), "4", tok)
    assert_true(String("89ab").find(String(tok[byte=19:20])) >= 0, tok)


def _token(req: CredentialHttpRequest) raises -> String:
    """The body's clientToken, or "" when it carries none."""
    var body = req.body_text()
    var key = String('"clientToken":"')
    var at = body.find(key)
    if at < 0:
        return String("")
    var start = at + key.byte_length()
    var end = body.find('"', start)
    assert_true(end > start, body)
    return String(body[byte=start:end])


def _run_task(var input: ECSRunTaskRequest, var c: ScriptedConnector) raises -> List[String]:
    """Each attempt's clientToken, for one RunTask over `c`."""
    var t = _Recording(c^)
    var clock = _Clock()
    var loop = RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        aws_standard_retry_policy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(7)
    )
    var quota = AwsRetryQuota()
    var client = _client(_mk_ok)
    var res = client.run_task_with(input, t, clock, loop, quota)
    assert_equal(res.status, 200)
    var out = List[String]()
    for i in range(len(t.sent)):
        out.append(_token(t.sent[i]))
    return out^


def _500_then_200() -> ScriptedConnector:
    var c = ScriptedConnector.with_stream(
        _answer(
            500,
            "Internal Server Error",
            '{"__type":"ServerException","message":"try again"}',
            "",
        )
    )
    c.arm_next(_answer(200, "OK", '{"tasks":[],"failures":[]}', ""))
    return c^


def test_run_task_retries_under_one_token() raises:
    # clientToken is an idempotency token in the model: left unset, the
    # client makes one (a UUID, as botocore does) before the send, so the
    # retry after the 500 is the same request and does not start a second
    # task.
    var sent = _run_task(ECSRunTaskRequest(String("jobs:3")), _500_then_200())
    assert_equal(len(sent), 2)
    # A version 4 UUID, as botocore makes one.
    _assert_uuid4(sent[0])
    assert_equal(sent[1], sent[0])
    # Each call makes its own.
    var again = _run_task(ECSRunTaskRequest(String("jobs:3")), _500_then_200())
    _assert_uuid4(again[0])
    assert_equal(again[1], again[0])
    assert_true(again[0] != sent[0])

    var input = ECSRunTaskRequest(String("jobs:3"))
    input.client_token = Optional[String](String("run-2026-10-04-jobs-3"))
    var given = _run_task(input^, _500_then_200())
    assert_equal(len(given), 2)
    assert_equal(given[0], "run-2026-10-04-jobs-3")
    assert_equal(given[1], "run-2026-10-04-jobs-3")


def main() raises:
    test_list_clusters()
    test_an_error_is_raised_under_its_code()
    test_run_task_on_the_wire()
    test_run_task_retries_under_one_token()
    print("OK")
