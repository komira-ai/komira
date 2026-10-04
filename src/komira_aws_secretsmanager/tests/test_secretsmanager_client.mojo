# The generated AWS Secrets Manager client
# (`SecretsManagerSecretsManagerClient`) end to end over komira_http_client
# and komira_http_core's ScriptedConnector (no socket): a GetSecretValue
# answered, and a DescribeSecret of a secret that does not exist, raised
# under its code with the service's message. The error is a 400 naming no
# code botocore retries, so nothing is retried. An error body carrying a
# field besides the code and message (here a SecretString) does not reach
# the raised text: the client's errors never carry the response body.
#
# Then the CreateSecret request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an awsJson error
# naming the request head, so the row asserts the request line, the Host the
# endpoint ruleset resolved, the awsJson target and content type and the
# SigV4 scope, through the generated client.
#
# Then the writes' idempotency token, over a transport that records each
# attempt: a CreateSecret sent without a ClientRequestToken carries one the
# client made, and its retry after a 500 carries the same one; a token the
# caller set is sent as set, on a PutSecretValue.
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SecretsManagerCreateSecretRequest,
    SecretsManagerDescribeSecretRequest,
    SecretsManagerEndpointConfig,
    SecretsManagerGetSecretValueRequest,
    SecretsManagerPutSecretValueRequest,
    SecretsManagerSecretsManagerClient,
    parse_create_secret_response,
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
            '{"ARN":"arn:aws:secretsmanager:us-east-1:000000000000:secret:app/db-AbCdEf","Name":"app/db","VersionId":"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111","SecretString":"s3cr3t","VersionStages":["AWSCURRENT"],"CreatedDate":1790812800.0}',
            "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890aa\r\n",
        )
    )


def _mk_err() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            "{\"__type\":\"ResourceNotFoundException\",\"Message\":\"Secrets Manager can't find the specified secret.\"}",
            "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890ab\r\n",
        )
    )


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> SecretsManagerSecretsManagerClient[C, StaticCredsSource]:
    var config = SecretsManagerEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return SecretsManagerSecretsManagerClient[C, StaticCredsSource](
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


def test_get_secret_value() raises:
    var client = _client(_mk_ok)
    var out = client.get_secret_value(SecretsManagerGetSecretValueRequest(String("app/db")))
    assert_equal(out.name.value(), "app/db")
    assert_equal(out.secret_string.value(), "s3cr3t")
    assert_equal(out.version_stages.value()[0], "AWSCURRENT")


def test_an_error_is_raised_under_its_code() raises:
    var client = _client(_mk_err)
    with assert_raises(contains="SecretsManagerSecretsManager.DescribeSecret failed: HTTP 400 ResourceNotFoundException Secrets Manager can't find the specified secret."):
        _ = client.describe_secret(SecretsManagerDescribeSecretRequest(String("gone")))


def _mk_canary() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"__type":"InvalidRequestException","Message":"The secret is not valid.","SecretString":"leak-canary"}',
            "x-amzn-RequestId: e9b0a6c4-0000-4000-8000-1234567890ac\r\n",
        )
    )


def test_an_error_does_not_carry_the_body() raises:
    var client = _client(_mk_canary)
    var text = String("")
    try:
        _ = client.get_secret_value(SecretsManagerGetSecretValueRequest(String("app/db")))
    except e:
        text = String(e)
    assert_true(
        text.find("GetSecretValue failed: HTTP 400 InvalidRequestException The secret is not valid.") >= 0,
        text,
    )
    assert_true(text.find("leak-canary") < 0, text)
    assert_true(text.find("SecretString") < 0, text)


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.json()


def test_create_secret_on_the_wire() raises:
    var client = _client(_mk_echo)
    var wire = String("")
    try:
        _ = client.create_secret(SecretsManagerCreateSecretRequest(String("app/db")))
    except e:
        var text = String(e)
        var marker = String("CreateSecret failed: HTTP 400 ") + AWS_ECHO_CODE + " "
        var at = text.find(marker)
        assert_true(at >= 0, text)
        wire = String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:4566",
        "x-amz-target: secretsmanager.createsecret",
        "content-type: application/x-amz-json-1.1",
        "/us-east-1/secretsmanager/aws4_request, signedheaders=",
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


def _loop() raises -> RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng]:
    return RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        aws_standard_retry_policy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(7)
    )


def _token(req: CredentialHttpRequest) raises -> String:
    """The body's ClientRequestToken, or "" when it carries none."""
    var body = req.body_text()
    var key = String('"ClientRequestToken":"')
    var at = body.find(key)
    if at < 0:
        return String("")
    var start = at + key.byte_length()
    var end = body.find('"', start)
    assert_true(end > start, body)
    return String(body[byte=start:end])


def test_create_secret_fills_its_token_once() raises:
    # The model marks ClientRequestToken an idempotency token, and the
    # service refuses a CreateSecret without one. Left unset, the client
    # makes one (a UUID, as botocore does) before the send, so the retry
    # after the 500 is the same request.
    var c = ScriptedConnector.with_stream(
        _answer(
            500,
            "Internal Server Error",
            '{"__type":"InternalServiceError","Message":"try again"}',
            "",
        )
    )
    c.arm_next(
        _answer(
            200,
            "OK",
            '{"ARN":"arn:aws:secretsmanager:us-east-1:000000000000:secret:app/db-AbCdEf","Name":"app/db","VersionId":"a1b2c3d4-5678-90ab-cdef-EXAMPLE11111"}',
            "",
        )
    )
    var t = _Recording(c^)
    var clock = _Clock()
    var loop = _loop()
    var quota = AwsRetryQuota()
    var client = _client(_mk_ok)
    var res = client.create_secret_with(
        SecretsManagerCreateSecretRequest(String("app/db")), t, clock, loop, quota
    )
    assert_equal(res.status, 200)
    assert_equal(parse_create_secret_response(res^.into_response()).name.value(), "app/db")
    assert_equal(len(t.sent), 2)
    var first = _token(t.sent[0])
    # A hyphenated UUID, inside the model's 32..64.
    assert_equal(first.byte_length(), 36, t.sent[0].body_text())
    assert_equal(_token(t.sent[1]), first)

    # Each call makes its own.
    var again = _Recording(ScriptedConnector.with_stream(_answer(200, "OK", "{}", "")))
    var loop2 = _loop()
    _ = client.create_secret_with(
        SecretsManagerCreateSecretRequest(String("app/db")), again, clock, loop2, quota
    )
    assert_equal(len(again.sent), 1)
    assert_equal(_token(again.sent[0]).byte_length(), 36)
    assert_true(_token(again.sent[0]) != first)


def test_a_token_the_caller_set_is_sent_as_set() raises:
    var input = SecretsManagerPutSecretValueRequest(String("app/db"))
    input.secret_string = Optional[String](String("s3cr3t"))
    input.client_request_token = Optional[String](
        String("EXAMPLE1-90ab-cdef-fedc-ba987EXAMPLE")
    )
    var t = _Recording(ScriptedConnector.with_stream(_answer(200, "OK", "{}", "")))
    var clock = _Clock()
    var loop = _loop()
    var quota = AwsRetryQuota()
    var client = _client(_mk_ok)
    _ = client.put_secret_value_with(input, t, clock, loop, quota)
    assert_equal(len(t.sent), 1)
    assert_equal(_token(t.sent[0]), "EXAMPLE1-90ab-cdef-fedc-ba987EXAMPLE")


def main() raises:
    test_get_secret_value()
    test_an_error_is_raised_under_its_code()
    test_an_error_does_not_carry_the_body()
    test_create_secret_on_the_wire()
    test_create_secret_fills_its_token_once()
    test_a_token_the_caller_set_is_sent_as_set()
    print("OK")
