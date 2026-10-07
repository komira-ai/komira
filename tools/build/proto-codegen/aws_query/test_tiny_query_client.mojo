# The generated awsQuery client (`TinyQueryClient`) end to end over
# komira_http_client and komira_http_core's ScriptedConnector (no socket): a
# SendThing answered with its <SendThingResult>, and one answered with an
# <ErrorResponse>, raised under the error's code and message (a 400 naming
# no code botocore retries, so nothing is retried).
#
# Then the Ping request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an XML error naming the
# request head, so the row asserts the request line, the Host, the form
# Content-Type and the SigV4 scope, through the generated client.
#
# Then the two anonymous operations the same way (PingAnonymous, `authtype`
# `none`; PingNoAuth, `auth` `smithy.api#noAuth`): each reaches the wire with
# its Host, Content-Type and form body, and with no Authorization,
# X-Amz-Date or X-Amz-Security-Token, through a client whose credential
# source raises when it is read, so neither reads it; Ping through that
# client raises the source's error.
from komira_aws_tiny_query_client.komira_aws_tiny_query_client import (
    TinyQueryPingAnonymousRequest,
    TinyQueryPingNoAuthRequest,
    TinyQueryPingRequest,
    TinyQuerySendThingRequest,
    TinyQueryClient,
)
from komira_aws_core import (
    AWS_ECHO_CODE,
    AwsCredential,
    AwsCredsSource,
    AwsEchoConnector,
    AwsEndpoint,
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
            + "\r\nContent-Type: text/xml\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n"
            + "x-amzn-RequestId: 3f1c2a9e-0000-4000-8000-1234567890aa\r\n"
            + "\r\n"
            + body
        )
    )


def _mk_sent() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            "<SendThingResponse><SendThingResult><MessageId>m-1</MessageId>"
            + "</SendThingResult></SendThingResponse>",
        )
    )


def _mk_missing() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            "<ErrorResponse><Error><Type>Sender</Type>"
            + "<Code>Tiny.ThingNotFound</Code>"
            + "<Message>no such thing</Message></Error>"
            + "<RequestId>3f1c2a9e-0000-4000-8000-1234567890aa</RequestId>"
            + "</ErrorResponse>",
        )
    )


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> TinyQueryClient[C, StaticCredsSource]:
    return TinyQueryClient[C, StaticCredsSource](
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
        Optional[AwsEndpoint](
            AwsEndpoint.parse(String("http://127.0.0.1:4566"), String("endpoint"))
        ),
    )


def test_send_thing() raises:
    var client = _client(_mk_sent)
    var out = client.send_thing(TinyQuerySendThingRequest(String("t")))
    assert_equal(out.message_id, "m-1")


def test_an_error_is_raised_under_its_code() raises:
    var client = _client(_mk_missing)
    with assert_raises(
        contains=(
            "TinyQuery.SendThing failed: HTTP 400 Tiny.ThingNotFound"
            " no such thing"
        )
    ):
        _ = client.send_thing(TinyQuerySendThingRequest(String("gone")))


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def test_ping_on_the_wire() raises:
    var client = _client(_mk_echo)
    var wire = String("")
    try:
        _ = client.ping(TinyQueryPingRequest())
    except e:
        var text = String(e)
        var marker = String("Ping failed: HTTP 400 ") + AWS_ECHO_CODE + " "
        var at = text.find(marker)
        assert_true(at >= 0, text)
        wire = String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:4566",
        "content-type: application/x-www-form-urlencoded; charset=utf-8",
        "/us-east-1/tinyquery/aws4_request, signedheaders=",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " is not in " + wire)


struct _NoCreds(AwsCredsSource, Movable, Deinitable):
    """A credential source that must not be read."""

    def __init__(out self):
        pass

    def credentials(mut self) raises -> AwsCredential:
        raise Error("the credential source was read")


def _anonymous_client() raises -> TinyQueryClient[AwsEchoConnector, _NoCreds]:
    return TinyQueryClient[AwsEchoConnector, _NoCreds](
        _mk_echo,
        HttpClientConfig.defaults(),
        _NoCreds(),
        String("us-east-1"),
        Optional[AwsEndpoint](
            AwsEndpoint.parse(String("http://127.0.0.1:4566"), String("endpoint"))
        ),
    )


def _wire_of(text: String, op: String) raises -> String:
    """The echoed request head in `text`, the error a call to `op` raised."""
    var marker = op + String(" failed: HTTP 400 ") + AWS_ECHO_CODE + " "
    var at = text.find(marker)
    assert_true(at >= 0, text)
    return String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()


def _assert_unsigned_on_the_wire(wire: String) raises:
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:4566",
        "content-type: application/x-www-form-urlencoded; charset=utf-8",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " is not in " + wire)
    for absent in ["authorization", "x-amz-date", "x-amz-security-token", "aws4_request"]:
        assert_true(wire.find(absent) < 0, String(absent) + " is in " + wire)


def test_anonymous_operations_are_sent_unsigned() raises:
    var client = _anonymous_client()
    var wire = String("")
    try:
        _ = client.ping_anonymous(TinyQueryPingAnonymousRequest())
    except e:
        wire = _wire_of(String(e), String("PingAnonymous"))
    _assert_unsigned_on_the_wire(wire)
    wire = String("")
    try:
        _ = client.ping_no_auth(TinyQueryPingNoAuthRequest())
    except e:
        wire = _wire_of(String(e), String("PingNoAuth"))
    _assert_unsigned_on_the_wire(wire)
    # A signed operation of the same client reads the credential source.
    with assert_raises(contains="the credential source was read"):
        _ = client.ping(TinyQueryPingRequest())


def main() raises:
    test_send_thing()
    test_an_error_is_raised_under_its_code()
    test_ping_on_the_wire()
    test_anonymous_operations_are_sent_unsigned()
    print("OK")
