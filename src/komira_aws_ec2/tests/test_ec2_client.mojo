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
#
# Then the verbs over their seams (`<verb>_with`: a transport that records
# each signed request and answers from a script, a fixed signing clock, a
# retry loop whose sleeper records):
#
# - RunInstances' ClientToken, the model's idempotency token. Left unset, the
#   client fills it with a fresh version 4 UUID once per call, as botocore's
#   generate_idempotent_uuid does, so a launch answered 503 and resent
#   carries the same token both times; a second call draws a new one. A
#   token the caller sets is sent as given, on every attempt.
# - RequestLimitExceeded, EC2's throttle (a 503 with the ec2Query error
#   document): a DescribeInstances answered with it is resent after one
#   backoff, and the second answer is returned.
from komira_aws_ec2.komira_aws_ec2 import (
    EC2DescribeInstancesRequest,
    EC2DescribeVpcsRequest,
    EC2EC2Client,
    EC2EndpointConfig,
    EC2RunInstancesRequest,
    EC2TerminateInstancesRequest,
    parse_describe_instances_response,
    parse_run_instances_response,
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
from std.testing import assert_equal, assert_false, assert_raises, assert_true


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


struct Script(AwsHttpTransport, Movable, Deinitable):
    """Records each signed request and answers it with the next scripted
    (status, body)."""

    var sent: List[CredentialHttpRequest]
    var statuses: List[Int]
    var bodies: List[String]

    def __init__(out self):
        self.sent = List[CredentialHttpRequest]()
        self.statuses = List[Int]()
        self.bodies = List[String]()

    def answer(mut self, status: Int, body: String):
        self.statuses.append(status)
        self.bodies.append(body)

    def send(mut self, req: CredentialHttpRequest) raises -> HttpResult:
        var i = len(self.sent)
        self.sent.append(req.copy())
        if i >= len(self.statuses):
            raise Error("the script has no answer for send " + String(i + 1))
        return HttpResult(self.statuses[i], _bytes(self.bodies[i]))

    def form_value(self, i: Int, name: String) raises -> String:
        """The value of parameter `name` in send `i`'s form body, or "" when
        the body holds none."""
        var body = self.sent[i].body_text()
        var key = name + "="
        for part in body.split("&"):
            var p = String(part)
            if p.startswith(key):
                return String(p[byte = key.byte_length() : p.byte_length()])
        return String("")


comptime _UNAVAILABLE = (
    "<Response><Errors><Error><Code>Unavailable</Code>"
    "<Message>The server is overloaded.</Message></Error></Errors>"
    "<RequestID>r-503</RequestID></Response>"
)

comptime _THROTTLED = (
    "<Response><Errors><Error><Code>RequestLimitExceeded</Code>"
    "<Message>Request limit exceeded.</Message></Error></Errors>"
    "<RequestID>r-throttle</RequestID></Response>"
)

comptime _LAUNCHED = (
    '<RunInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">'
    "<requestId>r-1</requestId><reservationId>r-0a1b2c3d4e5f60718</reservationId>"
    "<ownerId>123456789012</ownerId><instancesSet><item>"
    "<instanceId>i-0123456789abcdef0</instanceId></item></instancesSet>"
    "</RunInstancesResponse>"
)

comptime _FOUND = (
    '<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">'
    "<requestId>r-2</requestId><reservationSet/></DescribeInstancesResponse>"
)


def _loop() raises -> RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng]:
    return RetryLoop[ManualClock, RecordingSleeper, SplitMix64Rng](
        aws_standard_retry_policy(), ManualClock(), RecordingSleeper(), SplitMix64Rng(7)
    )


def _launch(
    mut client: EC2EC2Client[ScriptedConnector, StaticCredsSource],
    input: EC2RunInstancesRequest,
    mut transport: Script,
) raises:
    """One RunInstances call over `transport`, which must end in a launch."""
    # 2026-10-01T00:00:00Z.
    var clock = FixedClock(1790812800)
    var retry = _loop()
    var budget = NoBudget()
    var res = client.run_instances_with(input, transport, clock, retry, budget)
    assert_equal(res.status, 200)
    var out = parse_run_instances_response(res^.into_response())
    assert_equal(out.reservation_id.value(), "r-0a1b2c3d4e5f60718")


def _is_uuid4(t: String) -> Bool:
    var b = t.as_bytes()
    if len(b) != 36:
        return False
    for i in range(36):
        var c = b[i]
        if i == 8 or i == 13 or i == 18 or i == 23:
            if c != 0x2D:
                return False
        elif not ((c >= 0x30 and c <= 0x39) or (c >= 0x61 and c <= 0x66)):
            return False
    return b[14] == 0x34 and (b[19] == 0x38 or b[19] == 0x39 or b[19] == 0x61 or b[19] == 0x62)


def test_an_unset_client_token_is_filled_once_per_call() raises:
    var client = _client(_mk_found)
    var transport = Script()
    transport.answer(503, String(_UNAVAILABLE))
    transport.answer(200, String(_LAUNCHED))
    transport.answer(200, String(_LAUNCHED))
    var input = EC2RunInstancesRequest(Int32(1), Int32(1))
    input.set_image_id(String("ami-0abcdef1234567890"))
    _launch(client, input, transport)
    assert_equal(len(transport.sent), 2)
    var token = transport.form_value(0, String("ClientToken"))
    assert_true(_is_uuid4(token), token)
    # The resend is the same launch: the same token, the same body.
    assert_equal(transport.form_value(1, String("ClientToken")), token)
    assert_equal(transport.sent[1].body_text(), transport.sent[0].body_text())
    # The caller's input is not changed, and a second call is a new launch.
    assert_false(Bool(input.client_token))
    _launch(client, input, transport)
    assert_equal(len(transport.sent), 3)
    var second = transport.form_value(2, String("ClientToken"))
    assert_true(_is_uuid4(second), second)
    assert_true(second != token, second)


def test_a_client_token_the_caller_sets_is_sent_as_given() raises:
    var client = _client(_mk_found)
    var transport = Script()
    transport.answer(503, String(_UNAVAILABLE))
    transport.answer(200, String(_LAUNCHED))
    var input = EC2RunInstancesRequest(Int32(1), Int32(1))
    input.set_client_token(String("launch-0001"))
    _launch(client, input, transport)
    assert_equal(len(transport.sent), 2)
    assert_equal(transport.form_value(0, String("ClientToken")), "launch-0001")
    assert_equal(transport.form_value(1, String("ClientToken")), "launch-0001")


def test_a_throttled_call_is_resent_after_a_backoff() raises:
    var client = _client(_mk_found)
    var transport = Script()
    transport.answer(503, String(_THROTTLED))
    transport.answer(200, String(_FOUND))
    # 2026-10-01T00:00:00Z.
    var clock = FixedClock(1790812800)
    var retry = _loop()
    var budget = NoBudget()
    var res = client.describe_instances_with(
        EC2DescribeInstancesRequest(), transport, clock, retry, budget
    )
    assert_equal(res.status, 200)
    _ = parse_describe_instances_response(res^.into_response())
    assert_equal(len(transport.sent), 2)
    assert_equal(len(retry.sleeper().slept), 1)


def main() raises:
    test_describe_instances()
    test_a_missing_instance_is_raised_under_its_code()
    test_describe_vpcs_on_the_wire()
    test_an_unset_client_token_is_filled_once_per_call()
    test_a_client_token_the_caller_sets_is_sent_as_given()
    test_a_throttled_call_is_resent_after_a_backoff()
    print("OK")
