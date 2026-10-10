# The generated classic SES client (`SESClient`) end to end over
# komira_http_client and komira_http_core's ScriptedConnector (no socket),
# sent to a custom endpoint.
#
# The active rule set is answered with its <DescribeActiveReceiptRuleSetResult>.
# Every other verb meets one <ErrorResponse> and raises it under its code
# and message: a create of a rule set or a rule that already exists, and an
# activation, a rule create or a rule delete in a rule set that does not
# exist (each a 400 naming no code botocore retries, so each call is one
# request).
#
# Then each verb's request as it reached the wire: the client is given
# komira_aws_core's AwsEchoConnector, whose answer is an XML error naming
# the request head, so each row asserts the request line, the Host, the
# form Content-Type and the SigV4 scope (signing name `ses`, not the
# endpoint prefix `email`), through the generated client.
from komira_aws_ses.komira_aws_ses import (
    SESClient,
    SESCreateReceiptRuleRequest,
    SESCreateReceiptRuleSetRequest,
    SESDeleteReceiptRuleRequest,
    SESDescribeActiveReceiptRuleSetRequest,
    SESEndpointConfig,
    SESReceiptAction,
    SESReceiptRule,
    SESS3Action,
    SESSetActiveReceiptRuleSetRequest,
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
            + "\r\nContent-Type: text/xml\r\nContent-Length: "
            + String(body.byte_length())
            + "\r\nConnection: close\r\n"
            + "x-amzn-RequestId: 0a7e1a7b-0000-4000-8000-1234567890aa\r\n"
            + "\r\n"
            + body
        )
    )


def _error(code: String, message: String) -> ScriptedStream:
    return _answer(
        400,
        "Bad Request",
        String("<ErrorResponse><Error><Type>Sender</Type><Code>")
        + code
        + "</Code><Message>"
        + message
        + "</Message></Error>"
        + "<RequestId>0a7e1a7b-0000-4000-8000-1234567890aa</RequestId></ErrorResponse>",
    )


def _mk_active() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _answer(
            200,
            "OK",
            "<DescribeActiveReceiptRuleSetResponse><DescribeActiveReceiptRuleSetResult>"
            + "<Metadata><Name>inbound-rules</Name></Metadata>"
            + "<Rules><member><Name>mail-example-com</Name>"
            + "<Recipients><member>mail.example.com</member></Recipients></member></Rules>"
            + "</DescribeActiveReceiptRuleSetResult><ResponseMetadata><RequestId>r-1</RequestId>"
            + "</ResponseMetadata></DescribeActiveReceiptRuleSetResponse>",
        )
    )


def _mk_set_exists() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _error(String("AlreadyExists"), String("Rule set named inbound-rules already exists."))
    )


def _mk_rule_exists() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _error(String("AlreadyExists"), String("Rule named mail-example-com already exists."))
    )


def _mk_no_set() raises -> ScriptedConnector:
    return ScriptedConnector.with_stream(
        _error(String("RuleSetDoesNotExist"), String("Rule set does not exist: inbound-rules"))
    )


def _mk_echo() raises -> AwsEchoConnector:
    return AwsEchoConnector.xml()


def _client[C: Connector](
    mk: def () raises thin -> C,
) raises -> SESClient[C, StaticCredsSource]:
    var config = SESEndpointConfig()
    config.endpoint = Optional[String](String("http://127.0.0.1:4566"))
    return SESClient[C, StaticCredsSource](
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


def _rule() -> SESCreateReceiptRuleRequest:
    var store = SESReceiptAction()
    store.set_s3_action(SESS3Action(String("inbound-mail")))
    var actions = List[SESReceiptAction]()
    actions.append(store^)
    var rule = SESReceiptRule(String("mail-example-com"))
    rule.set_recipients([String("mail.example.com")])
    rule.set_actions(actions^)
    return SESCreateReceiptRuleRequest(String("inbound-rules"), rule^)


def _activate() -> SESSetActiveReceiptRuleSetRequest:
    var input = SESSetActiveReceiptRuleSetRequest()
    input.set_rule_set_name(String("inbound-rules"))
    return input^


def _delete() -> SESDeleteReceiptRuleRequest:
    return SESDeleteReceiptRuleRequest(String("inbound-rules"), String("mail-example-com"))


# ---- answered ----------------------------------------------------------------


def test_describe_active_receipt_rule_set_answered() raises:
    var client = _client(_mk_active)
    var out = client.describe_active_receipt_rule_set(SESDescribeActiveReceiptRuleSetRequest())
    assert_equal(out.metadata.value().name.value(), "inbound-rules")
    assert_equal(out.rules.value()[0].name, "mail-example-com")
    assert_equal(out.rules.value()[0].recipients.value()[0], "mail.example.com")


# ---- one error per verb ------------------------------------------------------


def test_create_receipt_rule_set_exists() raises:
    var client = _client(_mk_set_exists)
    with assert_raises(
        contains="SES.CreateReceiptRuleSet failed: HTTP 400 AlreadyExists Rule set named inbound-rules already exists."
    ):
        _ = client.create_receipt_rule_set(SESCreateReceiptRuleSetRequest(String("inbound-rules")))


def test_set_active_receipt_rule_set_missing() raises:
    var client = _client(_mk_no_set)
    with assert_raises(
        contains=(
            "SES.SetActiveReceiptRuleSet failed: HTTP 400 RuleSetDoesNotExist"
            " Rule set does not exist: inbound-rules"
        )
    ):
        _ = client.set_active_receipt_rule_set(_activate())


def test_create_receipt_rule_exists() raises:
    var client = _client(_mk_rule_exists)
    with assert_raises(
        contains="SES.CreateReceiptRule failed: HTTP 400 AlreadyExists Rule named mail-example-com already exists."
    ):
        _ = client.create_receipt_rule(_rule())


def test_delete_receipt_rule_missing_set() raises:
    var client = _client(_mk_no_set)
    with assert_raises(
        contains="SES.DeleteReceiptRule failed: HTTP 400 RuleSetDoesNotExist Rule set does not exist: inbound-rules"
    ):
        _ = client.delete_receipt_rule(_delete())


# ---- each verb on the wire ---------------------------------------------------


def _wire_of(text: String, op: String) raises -> String:
    var marker = op + " failed: HTTP 400 " + AWS_ECHO_CODE + " "
    var at = text.find(marker)
    assert_true(at >= 0, text)
    return String(text[byte = at + marker.byte_length() : text.byte_length()]).lower()


def _check(wire: String) raises:
    assert_true(wire.startswith("post / http/1.1 | "), wire)
    for want in [
        "host: 127.0.0.1:4566",
        "content-type: application/x-www-form-urlencoded; charset=utf-8",
        "/us-east-1/ses/aws4_request, signedheaders=content-type;host;x-amz-date,",
    ]:
        assert_true(wire.find(want) >= 0, String(want) + " is not in " + wire)


def test_create_receipt_rule_set_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_receipt_rule_set(SESCreateReceiptRuleSetRequest(String("inbound-rules")))
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateReceiptRuleSet"))


def test_set_active_receipt_rule_set_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.set_active_receipt_rule_set(_activate())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "SetActiveReceiptRuleSet"))


def test_describe_active_receipt_rule_set_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.describe_active_receipt_rule_set(SESDescribeActiveReceiptRuleSetRequest())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "DescribeActiveReceiptRuleSet"))


def test_create_receipt_rule_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.create_receipt_rule(_rule())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "CreateReceiptRule"))


def test_delete_receipt_rule_on_the_wire() raises:
    var client = _client(_mk_echo)
    try:
        _ = client.delete_receipt_rule(_delete())
        raise Error("the echo answered nothing")
    except e:
        _check(_wire_of(String(e), "DeleteReceiptRule"))


def main() raises:
    test_describe_active_receipt_rule_set_answered()
    test_create_receipt_rule_set_exists()
    test_set_active_receipt_rule_set_missing()
    test_create_receipt_rule_exists()
    test_delete_receipt_rule_missing_set()
    test_create_receipt_rule_set_on_the_wire()
    test_set_active_receipt_rule_set_on_the_wire()
    test_describe_active_receipt_rule_set_on_the_wire()
    test_create_receipt_rule_on_the_wire()
    test_delete_receipt_rule_on_the_wire()
    print("OK")
