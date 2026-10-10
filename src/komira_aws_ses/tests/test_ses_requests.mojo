# The requests komira_aws_ses builds, exactly: a POST to `/` whose form
# body (Content-Type `application/x-www-form-urlencoded; charset=utf-8`)
# starts `Action=<Operation>&Version=2010-12-01` and then names the input's
# members in the model's order, each value percent-encoded (every byte
# outside A-Z a-z 0-9 `-` `.` `_` `~`), an unset member absent, a nested
# structure `<Name>.<Member>` and a list `<Name>.member.<i>` from 1, as
# botocore's QuerySerializer writes them. One or more rows per operation,
# in the shapes the Amazon SES API reference documents: a receipt rule set
# created, made the active set and every set made inactive; the active set
# read; a receipt rule created (stored to S3 with an SNS notice, then the
# rule set stopped; and one placed after another, invoking a Lambda
# function) and deleted. Then the model's bounds, refused before the wire.
from komira_aws_ses.komira_aws_ses import (
    SES_API_VERSION,
    SESCreateReceiptRuleRequest,
    SESCreateReceiptRuleSetRequest,
    SESDeleteReceiptRuleRequest,
    SESDescribeActiveReceiptRuleSetRequest,
    SESLambdaAction,
    SESReceiptAction,
    SESReceiptRule,
    SESS3Action,
    SESSetActiveReceiptRuleSetRequest,
    SESStopAction,
    build_create_receipt_rule_request,
    build_create_receipt_rule_set_request,
    build_delete_receipt_rule_request,
    build_describe_active_receipt_rule_set_request,
    build_set_active_receipt_rule_set_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


comptime _TOPIC = "arn:aws:sns:us-east-1:123456789012:inbound-mail"
comptime _TOPIC_ENC = "arn%3Aaws%3Asns%3Aus-east-1%3A123456789012%3Ainbound-mail"
comptime _ROUTER = "arn:aws:lambda:us-east-1:123456789012:function:router"
comptime _ROUTER_ENC = "arn%3Aaws%3Alambda%3Aus-east-1%3A123456789012%3Afunction%3Arouter"


def _body(req: AwsRequest, op: String) raises -> String:
    """The form body after `Action=<op>&Version=...`, once the envelope is
    checked: a POST to `/` with the form Content-Type as its only header."""
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/")
    assert_equal(
        req.header(String("Content-Type")),
        "application/x-www-form-urlencoded; charset=utf-8",
    )
    assert_equal(len(req.header_names), 1)
    var text = req.body_text()
    var head = String("Action=") + op + "&Version=2010-12-01"
    assert_equal(String(text[byte = 0 : min(head.byte_length(), text.byte_length())]), head)
    return String(text[byte = head.byte_length() : text.byte_length()])


def test_api_version() raises:
    assert_equal(SES_API_VERSION, "2010-12-01")


def test_create_receipt_rule_set() raises:
    var req = build_create_receipt_rule_set_request(SESCreateReceiptRuleSetRequest(String("inbound-rules")))
    assert_equal(_body(req, String("CreateReceiptRuleSet")), "&RuleSetName=inbound-rules")


def test_set_active_receipt_rule_set() raises:
    var input = SESSetActiveReceiptRuleSetRequest()
    input.set_rule_set_name(String("inbound-rules"))
    assert_equal(
        _body(build_set_active_receipt_rule_set_request(input), String("SetActiveReceiptRuleSet")),
        "&RuleSetName=inbound-rules",
    )


def test_set_active_with_no_name_makes_every_set_inactive() raises:
    # The API reference: with RuleSetName left out, no rule set is active.
    # The body is then the envelope alone.
    var req = build_set_active_receipt_rule_set_request(SESSetActiveReceiptRuleSetRequest())
    assert_equal(_body(req, String("SetActiveReceiptRuleSet")), "")


def test_describe_active_receipt_rule_set() raises:
    var req = build_describe_active_receipt_rule_set_request(SESDescribeActiveReceiptRuleSetRequest())
    assert_equal(_body(req, String("DescribeActiveReceiptRuleSet")), "")


def _store_and_stop() -> SESReceiptRule:
    """A domain's route: the message stored under its prefix with an SNS
    notice, then the rule set stopped."""
    var s3 = SESS3Action(String("inbound-mail"))
    s3.set_topic_arn(String(_TOPIC))
    s3.set_object_key_prefix(String("inbound/mail.example.com/"))
    var store = SESReceiptAction()
    store.set_s3_action(s3^)
    var stop = SESReceiptAction()
    stop.set_stop_action(SESStopAction(String("RuleSet")))
    var actions = List[SESReceiptAction]()
    actions.append(store^)
    actions.append(stop^)
    var rule = SESReceiptRule(String("mail-example-com"))
    rule.set_enabled(True)
    rule.set_tls_policy(String("Require"))
    rule.set_recipients([String("mail.example.com"), String("postmaster@example.org")])
    rule.set_actions(actions^)
    rule.set_scan_enabled(True)
    return rule^


def test_create_receipt_rule() raises:
    var req = build_create_receipt_rule_request(SESCreateReceiptRuleRequest(String("inbound-rules"), _store_and_stop()))
    # The rule's members in the model's order (Name, Enabled, TlsPolicy,
    # Recipients, Actions, ScanEnabled); each action a structure holding
    # one action, numbered from 1.
    assert_equal(
        _body(req, String("CreateReceiptRule")),
        "&RuleSetName=inbound-rules"
        + "&Rule.Name=mail-example-com&Rule.Enabled=true&Rule.TlsPolicy=Require"
        + "&Rule.Recipients.member.1=mail.example.com"
        + "&Rule.Recipients.member.2=postmaster%40example.org"
        + "&Rule.Actions.member.1.S3Action.TopicArn="
        + _TOPIC_ENC
        + "&Rule.Actions.member.1.S3Action.BucketName=inbound-mail"
        + "&Rule.Actions.member.1.S3Action.ObjectKeyPrefix=inbound%2Fmail.example.com%2F"
        + "&Rule.Actions.member.2.StopAction.Scope=RuleSet"
        + "&Rule.ScanEnabled=true",
    )


def test_create_receipt_rule_after_another() raises:
    var invoke = SESLambdaAction(String(_ROUTER))
    invoke.set_invocation_type(String("Event"))
    var action = SESReceiptAction()
    action.set_lambda_action(invoke^)
    var actions = List[SESReceiptAction]()
    actions.append(action^)
    var rule = SESReceiptRule(String("catch-all"))
    rule.set_actions(actions^)
    var input = SESCreateReceiptRuleRequest(String("inbound-rules"), rule^)
    input.set_after(String("mail-example-com"))
    assert_equal(
        _body(build_create_receipt_rule_request(input), String("CreateReceiptRule")),
        "&RuleSetName=inbound-rules&After=mail-example-com&Rule.Name=catch-all"
        + "&Rule.Actions.member.1.LambdaAction.FunctionArn="
        + _ROUTER_ENC
        + "&Rule.Actions.member.1.LambdaAction.InvocationType=Event",
    )


def test_delete_receipt_rule() raises:
    var req = build_delete_receipt_rule_request(
        SESDeleteReceiptRuleRequest(String("inbound-rules"), String("mail-example-com"))
    )
    assert_equal(_body(req, String("DeleteReceiptRule")), "&RuleSetName=inbound-rules&RuleName=mail-example-com")


def test_refusals_before_the_wire() raises:
    # An S3 action's IamRoleArn is an IAMRoleARN, `min: 20`, checked inside
    # the rule's list of actions.
    var s3 = SESS3Action(String("inbound-mail"))
    s3.set_iam_role_arn(String("arn:x"))
    var action = SESReceiptAction()
    action.set_s3_action(s3^)
    var actions = List[SESReceiptAction]()
    actions.append(action^)
    var rule = SESReceiptRule(String("mail-example-com"))
    rule.set_actions(actions^)
    with assert_raises(contains="SESS3Action.IamRoleArn: the model states min length 20, got 5"):
        _ = build_create_receipt_rule_request(SESCreateReceiptRuleRequest(String("inbound-rules"), rule^))


def main() raises:
    test_api_version()
    test_create_receipt_rule_set()
    test_set_active_receipt_rule_set()
    test_set_active_with_no_name_makes_every_set_inactive()
    test_describe_active_receipt_rule_set()
    test_create_receipt_rule()
    test_create_receipt_rule_after_another()
    test_delete_receipt_rule()
    test_refusals_before_the_wire()
    print("OK")
