# The generated IAM client (`IAMIAMClient`) end to end, with no socket.
#
# Over komira_http_client and komira_http_core's ScriptedConnector, sent to
# a custom endpoint: a GetRole answered with its <GetRoleResult>, and one
# answered with an <ErrorResponse>, raised under the error's code and
# message (a 404 naming no code botocore retries, so nothing is retried).
#
# Then the GetRole request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an XML error naming the
# request head, so the row asserts the request line, the Host, the form
# Content-Type and the SigV4 scope, through the generated client.
#
# Then IAM as a global service, through the client's own resolution: a
# client in eu-west-1 with no endpoint override sends CreateUser to
# https://iam.amazonaws.com, signed for us-east-1. The call goes over the
# client's `create_user_with` seam (a transport that records the signed
# request and answers it, a fixed signing clock), so no TLS connection is
# needed, and the signature is the one test_iam_endpoints states for the
# same request, computed independently.
from komira_aws_iam.komira_aws_iam import (
    IAMCreateUserRequest,
    IAMEndpointConfig,
    IAMGetRoleRequest,
    IAMIAMClient,
    parse_create_user_response,
)
from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsCredential,
    AwsEchoConnector,
    AwsHttpTransport,
    CredentialHttpRequest,
    FixedClock,
    HttpResult,
    StaticCredsSource,
    aws_standard_retry_policy,
)
from komira_http_client.client import HttpClientConfig
from komira_http_core.transport.io_stream import Connector
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream
from komira_retry import ManualClock, NoBudget, RecordingSleeper, RetryLoop, SplitMix64Rng
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
            + "\r\nContent-Type: text/xml\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n"
            + "x-amzn-RequestId: 6a0e1c55-0000-4000-8000-1234567890aa\r\n"
            + "\r\n"
            + body
        )
    )


def _mk_found() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            "<GetRoleResponse><GetRoleResult><Role><Path>/</Path>"
            + "<RoleName>deploy</RoleName><RoleId>AROADBQP57FF2AEXAMPLE</RoleId>"
            + "<Arn>arn:aws:iam::123456789012:role/deploy</Arn>"
            + "<CreateDate>2026-10-01T00:00:00Z</CreateDate></Role></GetRoleResult>"
            + "<ResponseMetadata><RequestId>r-1</RequestId></ResponseMetadata>"
            + "</GetRoleResponse>",
        )
    )


def _mk_missing() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            "<ErrorResponse><Error><Type>Sender</Type><Code>NoSuchEntity</Code>"
            + "<Message>The role with name gone cannot be found.</Message></Error>"
            + "<RequestId>6a0e1c55-0000-4000-8000-1234567890aa</RequestId></ErrorResponse>",
        )
    )


def _creds() -> StaticCredsSource:
    return StaticCredsSource(
        AwsCredential(
            String("AKIAIOSFODNN7EXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"),
            String(""),
        )
    )


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> IAMIAMClient[C, StaticCredsSource]:
    var config = IAMEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return IAMIAMClient[C, StaticCredsSource](
        mk,
        HttpClientConfig.defaults(),
        _creds(),
        String("us-east-1"),
        config^,
    )


def test_get_role() raises:
    var client = _client(_mk_found)
    var out = client.get_role(IAMGetRoleRequest(String("deploy")))
    assert_equal(out.role.role_name, "deploy")
    assert_equal(out.role.arn, "arn:aws:iam::123456789012:role/deploy")


def test_a_missing_role_is_raised_under_its_code() raises:
    var client = _client(_mk_missing)
    with assert_raises(
        contains=(
            "IAMIAM.GetRole failed: HTTP 404 NoSuchEntity"
            " The role with name gone cannot be found."
        )
    ):
        _ = client.get_role(IAMGetRoleRequest(String("gone")))


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def test_get_role_on_the_wire() raises:
    var client = _client(_mk_echo)
    var wire = String("")
    try:
        _ = client.get_role(IAMGetRoleRequest(String("deploy")))
    except e:
        var text = String(e)
        var marker = String("GetRole failed: HTTP 400 ") + AWS_ECHO_CODE + " "
        var at = text.find(marker)
        assert_true(at >= 0, text)
        wire = String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:4566",
        "content-type: application/x-www-form-urlencoded; charset=utf-8",
        "/us-east-1/iam/aws4_request, signedheaders=content-type;host;x-amz-date,",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " is not in " + wire)


struct Answering(AwsHttpTransport, Movable, Deinitable):
    """Records each signed request and answers it with `body`, HTTP 200."""

    var sent: List[CredentialHttpRequest]
    var body: String

    def __init__(out self, body: String):
        self.sent = List[CredentialHttpRequest]()
        self.body = body

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        self.sent.append(req.copy())
        return HttpResult(200, _bytes(self.body))


def test_a_regional_client_reaches_the_global_endpoint() raises:
    # No endpoint override: the client resolves IAM's ruleset for its own
    # region, eu-west-1.
    var client = IAMIAMClient[ScriptedConnector, StaticCredsSource](
        _mk_missing, HttpClientConfig.defaults(), _creds(), String("eu-west-1")
    )
    var transport = Answering(
        String(
            "<CreateUserResponse><CreateUserResult><User><Path>/</Path>"
            "<UserName>smtp-relay</UserName><UserId>AIDACKCEVSQ6C2EXAMPLE</UserId>"
            "<Arn>arn:aws:iam::123456789012:user/smtp-relay</Arn>"
            "<CreateDate>2026-10-01T00:00:00Z</CreateDate></User></CreateUserResult>"
            "</CreateUserResponse>"
        )
    )
    # 2026-10-01T00:00:00Z.
    var clock = FixedClock(1790812800)
    var retry = RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        aws_standard_retry_policy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(7)
    )
    var budget = NoBudget()
    var res = client.create_user_with(
        IAMCreateUserRequest(String("smtp-relay")), transport, clock, retry, budget
    )
    assert_equal(res.status, 200)
    var out = parse_create_user_response(res^.into_response())
    assert_equal(out.user.value().user_name, "smtp-relay")
    assert_equal(len(transport.sent), 1)
    ref req = transport.sent[0]
    assert_equal(req.method, "POST")
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "iam.amazonaws.com")
    assert_equal(req.target, "/")
    assert_equal(req.header("Host"), "iam.amazonaws.com")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/iam/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=a0a2bd060ebf1fe300579cbb0f24e324f7a95e7f1ecc135f7db474de645b82a3",
    )


def main() raises:
    test_get_role()
    test_a_missing_role_is_raised_under_its_code()
    test_get_role_on_the_wire()
    test_a_regional_client_reaches_the_global_endpoint()
    print("OK")
