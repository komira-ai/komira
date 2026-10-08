# The generated SES v2 client (`SESv2Client`) end to end over
# komira_http_client and komira_http_core's ScriptedConnector (no socket).
#
# Every verb meets one error answer and raises it under the restJson1 code
# SES names in `X-Amzn-Errortype`, with the body's `message`: a create of
# an identity, a configuration set or an event destination that already
# exists (400), a read, binding, MAIL FROM change or delete of a missing
# identity (404), a delete of a missing configuration set (404), and a send
# SES rejects (400). None is a status or code botocore retries, so each call is one
# request. Two verbs are answered successfully.
#
# Then each verb's request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an error naming the
# request head, so each row asserts the request line, the Host the endpoint
# ruleset resolved, the content type of a request with a body, and the
# SigV4 scope (signing name `ses`, not the endpoint prefix `email`).
from komira_aws_sesv2.komira_aws_sesv2 import (
    SESv2Body,
    SESv2Content,
    SESv2CreateConfigurationSetEventDestinationRequest,
    SESv2CreateConfigurationSetRequest,
    SESv2CreateEmailIdentityRequest,
    SESv2DeleteConfigurationSetRequest,
    SESv2DeleteEmailIdentityRequest,
    SESv2Destination,
    SESv2EmailContent,
    SESv2EndpointConfig,
    SESv2EventDestinationDefinition,
    SESv2GetEmailIdentityRequest,
    SESv2Message,
    SESv2PutEmailIdentityConfigurationSetAttributesRequest,
    SESv2PutEmailIdentityMailFromAttributesRequest,
    SESv2SnsDestination,
    SESv2Client,
    SESv2SendEmailRequest,
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


def _answer(status: Int, reason: String, body: String, headers: String) -> ScriptedStream:
    return ScriptedStream.from_read_script(
        _bytes(
            String("HTTP/1.1 ")
            + String(status)
            + " "
            + reason
            + "\r\nContent-Type: application/json\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n"
            + headers
            + "\r\n"
            + body
        )
    )


def _mk_identity() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            '{"IdentityType":"DOMAIN","VerifiedForSendingStatus":true,'
            + '"DkimAttributes":{"SigningEnabled":true,"Status":"SUCCESS",'
            + '"Tokens":["tok1abc","tok2def","tok3ghi"]},"VerificationStatus":"SUCCESS"}',
            "",
        )
    )


def _mk_sent() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(200, "OK", '{"MessageId":"0100019000000001-aaaa"}', "")
    )


def _mk_exists() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"message":"Resource already exists."}',
            "X-Amzn-Errortype: AlreadyExistsException:\r\n",
        )
    )


def _mk_not_found() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            '{"message":"Email identity mail.example.com does not exist."}',
            "X-Amzn-Errortype: NotFoundException:\r\n",
        )
    )


def _mk_no_set() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            404,
            "Not Found",
            '{"message":"Configuration set <mail-example-com> does not exist."}',
            "X-Amzn-Errortype: NotFoundException:\r\n",
        )
    )


def _mk_rejected() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            400,
            "Bad Request",
            '{"message":"Email address is not verified."}',
            "X-Amzn-Errortype: MessageRejected:\r\n",
        )
    )


def _never() raises -> ScriptedConnector:
    raise Error("the client opened a connection")


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.json()


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> SESv2Client[C, StaticCredsSource]:
    var config = SESv2EndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return SESv2Client[C, StaticCredsSource](
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


def _send() -> SESv2SendEmailRequest:
    var text = SESv2Body()
    text.set_text(SESv2Content(String("Hi there")))
    var content = SESv2EmailContent()
    content.set_simple(SESv2Message(SESv2Content(String("Hello")), text^))
    var input = SESv2SendEmailRequest(content^)
    input.set_from_email_address(String("noreply@mail.example.com"))
    var to = SESv2Destination()
    to.set_to_addresses([String("ops@example.com")])
    input.set_destination(to^)
    return input^


def _bind() -> SESv2PutEmailIdentityConfigurationSetAttributesRequest:
    var input = SESv2PutEmailIdentityConfigurationSetAttributesRequest(String("mail.example.com"))
    input.set_configuration_set_name(String("mail-example-com"))
    return input^


def _mail_from() -> SESv2PutEmailIdentityMailFromAttributesRequest:
    var input = SESv2PutEmailIdentityMailFromAttributesRequest(String("mail.example.com"))
    input.set_mail_from_domain(String("bounce.mail.example.com"))
    return input^


def _feedback() -> SESv2CreateConfigurationSetEventDestinationRequest:
    var dest = SESv2EventDestinationDefinition()
    dest.set_enabled(True)
    dest.set_matching_event_types([String("BOUNCE"), String("COMPLAINT")])
    dest.set_sns_destination(SESv2SnsDestination(String("arn:aws:sns:us-east-1:000000000000:ses-feedback")))
    return SESv2CreateConfigurationSetEventDestinationRequest(String("mail-example-com"), String("feedback"), dest^)


# ---- answered ----------------------------------------------------------------


def test_get_email_identity_answered() raises:
    var client = _client(_mk_identity)
    var out = client.get_email_identity(SESv2GetEmailIdentityRequest(String("mail.example.com")))
    assert_true(out.verified_for_sending_status.value())
    assert_equal(out.dkim_attributes.value().tokens.value()[0], "tok1abc")


def test_send_email_answered() raises:
    var client = _client(_mk_sent)
    assert_equal(client.send_email(_send()).message_id.value(), "0100019000000001-aaaa")


# ---- one error per verb ------------------------------------------------------


def test_create_email_identity_exists() raises:
    var client = _client(_mk_exists)
    with assert_raises(contains="CreateEmailIdentity failed: HTTP 400 AlreadyExistsException Resource already exists."):
        _ = client.create_email_identity(SESv2CreateEmailIdentityRequest(String("mail.example.com")))


def test_create_configuration_set_exists() raises:
    var client = _client(_mk_exists)
    with assert_raises(contains="CreateConfigurationSet failed: HTTP 400 AlreadyExistsException Resource already exists."):
        _ = client.create_configuration_set(SESv2CreateConfigurationSetRequest(String("mail-example-com")))


def test_get_email_identity_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(
        contains="GetEmailIdentity failed: HTTP 404 NotFoundException Email identity mail.example.com does not exist."
    ):
        _ = client.get_email_identity(SESv2GetEmailIdentityRequest(String("mail.example.com")))


def test_delete_email_identity_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(
        contains="DeleteEmailIdentity failed: HTTP 404 NotFoundException Email identity mail.example.com does not exist."
    ):
        _ = client.delete_email_identity(SESv2DeleteEmailIdentityRequest(String("mail.example.com")))


def test_put_configuration_set_attributes_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(
        contains=(
            "PutEmailIdentityConfigurationSetAttributes failed: HTTP 404 NotFoundException"
            " Email identity mail.example.com does not exist."
        )
    ):
        _ = client.put_email_identity_configuration_set_attributes(_bind())


def test_put_mail_from_attributes_not_found() raises:
    var client = _client(_mk_not_found)
    with assert_raises(
        contains=(
            "PutEmailIdentityMailFromAttributes failed: HTTP 404 NotFoundException"
            " Email identity mail.example.com does not exist."
        )
    ):
        _ = client.put_email_identity_mail_from_attributes(_mail_from())


def test_create_event_destination_exists() raises:
    var client = _client(_mk_exists)
    with assert_raises(
        contains=(
            "CreateConfigurationSetEventDestination failed: HTTP 400 AlreadyExistsException"
            " Resource already exists."
        )
    ):
        _ = client.create_configuration_set_event_destination(_feedback())


def test_delete_configuration_set_not_found() raises:
    var client = _client(_mk_no_set)
    with assert_raises(
        contains=(
            "DeleteConfigurationSet failed: HTTP 404 NotFoundException"
            " Configuration set <mail-example-com> does not exist."
        )
    ):
        _ = client.delete_configuration_set(SESv2DeleteConfigurationSetRequest(String("mail-example-com")))


def test_send_email_rejected() raises:
    var client = _client(_mk_rejected)
    with assert_raises(contains="SendEmail failed: HTTP 400 MessageRejected Email address is not verified."):
        _ = client.send_email(_send())


# ---- each verb on the wire ---------------------------------------------------


def _wire_of(text: String, op: String) raises -> String:
    var marker = op + " failed: HTTP 400 " + AWS_ECHO_CODE + " "
    var at = text.find(marker)
    assert_true(at >= 0, text)
    return String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()


def _check(wire: String, line: String, has_body: Bool) raises:
    assert_true(wire.startswith(line + " http/1.1 | "), wire)
    var want: List[String] = [
        "host: 127.0.0.1:4566",
        "/us-east-1/ses/aws4_request, signedheaders=",
    ]
    if has_body:
        want.append("content-type: application/json")
    for i in range(len(want)):
        assert_true(wire.find(want[i]) >= 0, want[i] + " is not in " + wire)
    if not has_body:
        assert_true(wire.find("content-type") < 0, wire)


def test_create_email_identity_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_email_identity(SESv2CreateEmailIdentityRequest(String("mail.example.com")))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateEmailIdentity"), "post /v2/email/identities", True)


def test_get_email_identity_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.get_email_identity(SESv2GetEmailIdentityRequest(String("ops@example.com")))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "GetEmailIdentity"), "get /v2/email/identities/ops%40example.com", False)


def test_delete_email_identity_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.delete_email_identity(SESv2DeleteEmailIdentityRequest(String("mail.example.com")))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "DeleteEmailIdentity"), "delete /v2/email/identities/mail.example.com", False)


def test_create_configuration_set_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_configuration_set(SESv2CreateConfigurationSetRequest(String("mail-example-com")))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateConfigurationSet"), "post /v2/email/configuration-sets", True)


def test_put_configuration_set_attributes_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.put_email_identity_configuration_set_attributes(_bind())
        raise Error("the echo answered nothing")
    except e:
        _check(
            _wire_of(String(e), "PutEmailIdentityConfigurationSetAttributes"),
            "put /v2/email/identities/mail.example.com/configuration-set",
            True,
        )


def test_put_mail_from_attributes_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.put_email_identity_mail_from_attributes(_mail_from())
        raise Error("the echo answered nothing")
    except e:
        _check(
            _wire_of(String(e), "PutEmailIdentityMailFromAttributes"),
            "put /v2/email/identities/mail.example.com/mail-from",
            True,
        )


def test_create_event_destination_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_configuration_set_event_destination(_feedback())
        raise Error("the echo answered nothing")
    except e:
        _check(
            _wire_of(String(e), "CreateConfigurationSetEventDestination"),
            "post /v2/email/configuration-sets/mail-example-com/event-destinations",
            True,
        )


def test_delete_configuration_set_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.delete_configuration_set(SESv2DeleteConfigurationSetRequest(String("mail-example-com")))
        raise Error("the echo answered nothing")
    except e:
        _check(
            _wire_of(String(e), "DeleteConfigurationSet"),
            "delete /v2/email/configuration-sets/mail-example-com",
            False,
        )


def test_send_email_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.send_email(_send())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "SendEmail"), "post /v2/email/outbound-emails", True)


def test_send_email_to_a_multi_region_endpoint_is_refused() raises:
    # An `EndpointId` sends to a multi-region endpoint, which the ruleset
    # signs with SigV4a; komira_aws_core signs SigV4 only, so the client
    # refuses before anything reaches the wire. Its connector factory
    # raises if it is ever called, so the refusal naming SigV4a is also
    # the proof that no connection was opened.
    var config = SESv2EndpointConfig(String("us-east-1"))
    var client = SESv2Client[ScriptedConnector, StaticCredsSource](
        _never,
        HttpClientConfig.defaults(),
        StaticCredsSource(AwsCredential(String("AKIDEXAMPLE"), String("secret"), String(""))),
        String("us-east-1"),
        config^,
    )
    var input = _send()
    input.set_endpoint_id(String("abc123.456def"))
    with assert_raises(contains="sigv4a"):
        _ = client.send_email(input)


def main() raises:
    test_get_email_identity_answered()
    test_send_email_answered()
    test_create_email_identity_exists()
    test_create_configuration_set_exists()
    test_get_email_identity_not_found()
    test_delete_email_identity_not_found()
    test_put_configuration_set_attributes_not_found()
    test_put_mail_from_attributes_not_found()
    test_create_event_destination_exists()
    test_delete_configuration_set_not_found()
    test_send_email_rejected()
    test_create_email_identity_on_the_wire()
    test_get_email_identity_on_the_wire()
    test_delete_email_identity_on_the_wire()
    test_create_configuration_set_on_the_wire()
    test_put_configuration_set_attributes_on_the_wire()
    test_put_mail_from_attributes_on_the_wire()
    test_create_event_destination_on_the_wire()
    test_delete_configuration_set_on_the_wire()
    test_send_email_on_the_wire()
    test_send_email_to_a_multi_region_endpoint_is_refused()
    print("OK")
