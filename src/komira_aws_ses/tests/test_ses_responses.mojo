# The responses komira_aws_ses reads, exactly. An awsQuery answer is
# `<OpResponse><OpResult>...</OpResult><ResponseMetadata>...`, and each
# operation's members are read from its `<OpResult>` element (the model's
# resultWrapper): the active rule set's metadata (a timestamp read as epoch
# seconds) and its rules, each a structure in `<member>` holding lists of
# its own (recipients, and actions each holding one action structure). An
# operation whose result has no members reads none. Then the error document
# every SES operation answers with, `<ErrorResponse><Error>`, read through
# komira_aws_core's aws_query_error.
#
# The bodies are in the form the Amazon SES API reference documents for
# each operation, with documentation account ids.
from komira_aws_ses.komira_aws_ses import (
    parse_create_receipt_rule_response,
    parse_create_receipt_rule_set_response,
    parse_delete_receipt_rule_response,
    parse_describe_active_receipt_rule_set_response,
    parse_set_active_receipt_rule_set_response,
)
from komira_aws_core import AwsResponse, aws_query_error
from std.testing import assert_equal, assert_false, assert_raises, assert_true


comptime _NS = ' xmlns="http://ses.amazonaws.com/doc/2010-12-01/"'
comptime _META = (
    "<ResponseMetadata><RequestId>0a7e1a7b-0000-4000-8000-1234567890aa</RequestId>"
    "</ResponseMetadata>"
)
comptime _TOPIC = "arn:aws:sns:us-east-1:123456789012:inbound-mail"


def _ok(op: String, result: String) -> AwsResponse:
    """`<op>Response` holding `<op>Result` with `result` inside, and the
    response metadata after it."""
    return AwsResponse.of_text(
        200,
        String("<")
        + op
        + "Response"
        + _NS
        + "><"
        + op
        + "Result>"
        + result
        + "</"
        + op
        + "Result>"
        + _META
        + "</"
        + op
        + "Response>",
    )


def test_describe_active_receipt_rule_set() raises:
    var out = parse_describe_active_receipt_rule_set_response(
        _ok(
            String("DescribeActiveReceiptRuleSet"),
            String(
                "<Metadata><Name>inbound-rules</Name>"
                "<CreatedTimestamp>2026-10-01T00:00:00.000Z</CreatedTimestamp></Metadata>"
                "<Rules>"
                "<member><Name>mail-example-com</Name><Enabled>true</Enabled>"
                "<TlsPolicy>Require</TlsPolicy>"
                "<Recipients><member>mail.example.com</member>"
                "<member>postmaster@example.org</member></Recipients>"
                "<Actions>"
                "<member><S3Action><TopicArn>arn:aws:sns:us-east-1:123456789012:inbound-mail</TopicArn>"
                "<BucketName>inbound-mail</BucketName>"
                "<ObjectKeyPrefix>inbound/mail.example.com/</ObjectKeyPrefix></S3Action></member>"
                "<member><StopAction><Scope>RuleSet</Scope></StopAction></member>"
                "</Actions>"
                "<ScanEnabled>true</ScanEnabled></member>"
                "<member><Name>catch-all</Name><Enabled>false</Enabled>"
                "<TlsPolicy>Optional</TlsPolicy><ScanEnabled>false</ScanEnabled></member>"
                "</Rules>"
            ),
        )
    )
    ref meta = out.metadata.value()
    assert_equal(meta.name.value(), "inbound-rules")
    # 2026-10-01T00:00:00Z.
    assert_equal(meta.created_timestamp.value(), Float64(1790812800))
    var rules = out.rules.value().copy()
    assert_equal(len(rules), 2)
    assert_equal(rules[0].name, "mail-example-com")
    assert_true(rules[0].enabled.value())
    assert_equal(rules[0].tls_policy.value(), "Require")
    assert_equal(len(rules[0].recipients.value()), 2)
    assert_equal(rules[0].recipients.value()[1], "postmaster@example.org")
    assert_true(rules[0].scan_enabled.value())
    var actions = rules[0].actions.value().copy()
    assert_equal(len(actions), 2)
    ref s3 = actions[0].s3_action.value()
    assert_equal(s3.topic_arn.value(), _TOPIC)
    assert_equal(s3.bucket_name, "inbound-mail")
    assert_equal(s3.object_key_prefix.value(), "inbound/mail.example.com/")
    assert_false(Bool(s3.iam_role_arn))
    assert_false(Bool(actions[0].stop_action))
    assert_equal(actions[1].stop_action.value().scope, "RuleSet")
    assert_false(Bool(actions[1].s3_action))
    assert_equal(rules[1].name, "catch-all")
    assert_false(rules[1].enabled.value())
    assert_false(Bool(rules[1].recipients))
    assert_false(Bool(rules[1].actions))


def test_no_active_receipt_rule_set() raises:
    # With no active rule set the result is empty.
    var out = parse_describe_active_receipt_rule_set_response(
        _ok(String("DescribeActiveReceiptRuleSet"), String(""))
    )
    assert_false(Bool(out.metadata))
    assert_false(Bool(out.rules))


def test_results_with_no_members() raises:
    # Each answers with its empty result element.
    _ = parse_create_receipt_rule_set_response(_ok(String("CreateReceiptRuleSet"), String("")))
    _ = parse_set_active_receipt_rule_set_response(_ok(String("SetActiveReceiptRuleSet"), String("")))
    _ = parse_create_receipt_rule_response(_ok(String("CreateReceiptRule"), String("")))
    _ = parse_delete_receipt_rule_response(_ok(String("DeleteReceiptRule"), String("")))


def test_a_response_without_its_result_element_is_refused() raises:
    with assert_raises(contains="holds no <DescribeActiveReceiptRuleSetResult> element"):
        _ = parse_describe_active_receipt_rule_set_response(
            AwsResponse.of_text(
                200,
                String("<DescribeActiveReceiptRuleSetResponse><Metadata><Name>inbound-rules</Name></Metadata>")
                + "</DescribeActiveReceiptRuleSetResponse>",
            )
        )


def test_the_error_document() raises:
    var e = aws_query_error(
        AwsResponse.of_text(
            400,
            String("<ErrorResponse")
            + _NS
            + "><Error><Type>Sender</Type><Code>RuleSetDoesNotExist</Code>"
            + "<Message>Rule set does not exist: inbound-rules</Message></Error>"
            + "<RequestId>0a7e1a7b-0000-4000-8000-1234567890ab</RequestId></ErrorResponse>",
        )
    )
    assert_equal(e.status, 400)
    assert_equal(e.code, "RuleSetDoesNotExist")
    assert_equal(e.message, "Rule set does not exist: inbound-rules")
    assert_equal(e.request_id, "0a7e1a7b-0000-4000-8000-1234567890ab")


def test_already_exists() raises:
    var e = aws_query_error(
        AwsResponse.of_text(
            400,
            "<ErrorResponse><Error><Type>Sender</Type><Code>AlreadyExists</Code>"
            + "<Message>Rule set named inbound-rules already exists.</Message></Error>"
            + "<RequestId>r-1</RequestId></ErrorResponse>",
        )
    )
    assert_equal(e.code, "AlreadyExists")
    assert_equal(e.message, "Rule set named inbound-rules already exists.")


def main() raises:
    test_describe_active_receipt_rule_set()
    test_no_active_receipt_rule_set()
    test_results_with_no_members()
    test_a_response_without_its_result_element_is_refused()
    test_the_error_document()
    test_already_exists()
    print("OK")
