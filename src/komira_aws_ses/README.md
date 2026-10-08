# komira_aws_ses

A classic Amazon SES client for inbound mail routing (receipt rule sets and
receipt rules, which SES API v2 does not have), generated at build time from
botocore's pinned `ses` model (awsQuery). The module
`komira_aws_ses.komira_aws_ses` holds, for CreateReceiptRuleSet,
SetActiveReceiptRuleSet, DescribeActiveReceiptRuleSet, CreateReceiptRule and
DeleteReceiptRule:

- a request struct (`SES<Operation>Request`) and its builder
  `build_<operation>_request`, which returns a komira_aws_core `AwsRequest`:
  a POST to `/` whose body is the form `Action=<Operation>&Version=2010-12-01`
  followed by the members, nested structures and lists flattened as awsQuery
  flattens them, refusing a value outside the model's bounds before a request
  exists;
- a response parser `parse_<operation>_response`, which reads the
  `<OperationResult>` element of a komira_aws_core `AwsResponse`;
- an endpoint resolver `resolve_<operation>_endpoint`, which runs the
  service's published endpoint ruleset (`komira_aws_ses_endpoint_rules()`)
  over an `SESEndpointConfig` (the host is `email.<region>`);
- `SESClient`, which resolves each call's endpoint, signs it with SigV4
  (signing name `ses`) and sends it over the komira_http_core `Connector` it
  is given.

Sending, identities and configuration sets are `komira_aws_sesv2`; the other
classic SES operations are not generated. The package reads no environment.

## Examples

Build a CreateReceiptRule request: mail for a domain stored to an S3 bucket,
then the rule set stopped. Nothing is sent:

<!-- mojo-hidden from std.testing import assert_equal, assert_false -->
```mojo
from komira_aws_ses.komira_aws_ses import SESCreateReceiptRuleRequest, SESReceiptAction, SESReceiptRule
from komira_aws_ses.komira_aws_ses import SESS3Action, SESStopAction, build_create_receipt_rule_request

var s3 = SESS3Action(String("inbound-mail"))
s3.set_object_key_prefix(String("inbound/"))
var store = SESReceiptAction()
store.set_s3_action(s3^)
var stop = SESReceiptAction()
stop.set_stop_action(SESStopAction(String("RuleSet")))
var actions = List[SESReceiptAction]()
actions.append(store^)
actions.append(stop^)
var rule = SESReceiptRule(String("mail-example-com"))
rule.set_recipients([String("mail.example.com")])
rule.set_actions(actions^)
var req = build_create_receipt_rule_request(SESCreateReceiptRuleRequest(String("inbound-rules"), rule^))
assert_equal(req.method, "POST")
assert_equal(req.uri, "/")
assert_equal(
    req.header(String("Content-Type")),
    "application/x-www-form-urlencoded; charset=utf-8",
)
assert_equal(
    req.body_text(),
    "Action=CreateReceiptRule&Version=2010-12-01&RuleSetName=inbound-rules"
    + "&Rule.Name=mail-example-com&Rule.Recipients.member.1=mail.example.com"
    + "&Rule.Actions.member.1.S3Action.BucketName=inbound-mail"
    + "&Rule.Actions.member.1.S3Action.ObjectKeyPrefix=inbound%2F"
    + "&Rule.Actions.member.2.StopAction.Scope=RuleSet",
)
```

Decode a DescribeActiveReceiptRuleSet answer, and read an `<ErrorResponse>`
with komira_aws_core's `aws_query_error`:

```mojo
from komira_aws_core import AwsResponse, aws_query_error
from komira_aws_ses.komira_aws_ses import parse_describe_active_receipt_rule_set_response

var active = parse_describe_active_receipt_rule_set_response(
    AwsResponse.of_text(
        200,
        String(
            '<DescribeActiveReceiptRuleSetResponse xmlns="http://ses.amazonaws.com/doc/2010-12-01/">'
            + "<DescribeActiveReceiptRuleSetResult><Metadata><Name>inbound-rules</Name></Metadata>"
            + "<Rules><member><Name>mail-example-com</Name></member></Rules>"
            + "</DescribeActiveReceiptRuleSetResult><ResponseMetadata><RequestId>req-1</RequestId>"
            + "</ResponseMetadata></DescribeActiveReceiptRuleSetResponse>"
        ),
    )
)
assert_equal(active.metadata.value().name.value(), "inbound-rules")
assert_equal(active.rules.value()[0].name, "mail-example-com")
assert_false(Bool(active.rules.value()[0].actions))

var e = aws_query_error(
    AwsResponse.of_text(
        400,
        String(
            '<ErrorResponse xmlns="http://ses.amazonaws.com/doc/2010-12-01/">'
            + "<Error><Type>Sender</Type><Code>RuleSetDoesNotExist</Code>"
            + "<Message>Rule set does not exist: inbound-rules</Message></Error>"
            + "<RequestId>req-2</RequestId></ErrorResponse>"
        ),
    )
)
assert_equal(e.status, 400)
assert_equal(e.code, "RuleSetDoesNotExist")
assert_equal(e.message, "Rule set does not exist: inbound-rules")
```

Resolve the endpoint a call goes to:

```mojo
from komira_aws_ses.komira_aws_ses import SESDescribeActiveReceiptRuleSetRequest, SESEndpointConfig
from komira_aws_ses.komira_aws_ses import komira_aws_ses_endpoint_rules
from komira_aws_ses.komira_aws_ses import resolve_describe_active_receipt_rule_set_endpoint

var rules = komira_aws_ses_endpoint_rules()
var describe = SESDescribeActiveReceiptRuleSetRequest()
assert_equal(
    resolve_describe_active_receipt_rule_set_endpoint(rules, SESEndpointConfig(String("us-west-2")), describe).url,
    "https://email.us-west-2.amazonaws.com",
)
var fips = SESEndpointConfig(String("us-east-1"))
fips.use_fips = Optional[Bool](True)
assert_equal(
    resolve_describe_active_receipt_rule_set_endpoint(rules, fips, describe).url,
    "https://email-fips.us-east-1.amazonaws.com",
)
```
