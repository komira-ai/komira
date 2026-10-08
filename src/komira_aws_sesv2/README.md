# komira_aws_sesv2

An Amazon SES API v2 client for a sending domain's onboarding, its sends and
its removal, generated at build time from botocore's pinned `sesv2` model
(restJson1). The module `komira_aws_sesv2.komira_aws_sesv2` holds, for
CreateEmailIdentity, GetEmailIdentity, PutEmailIdentityMailFromAttributes,
PutEmailIdentityConfigurationSetAttributes, DeleteEmailIdentity,
CreateConfigurationSet, CreateConfigurationSetEventDestination,
DeleteConfigurationSet and SendEmail:

- a request struct (`SESv2<Operation>Request`) and its builder
  `build_<operation>_request`, which returns a komira_aws_core `AwsRequest`
  (method, `/v2/email/...` path, JSON body), refusing a value outside the
  model's bounds before a request exists;
- a response parser `parse_<operation>_response` over a komira_aws_core
  `AwsResponse`;
- an endpoint resolver `resolve_<operation>_endpoint`, which runs the
  service's published endpoint ruleset (`komira_aws_sesv2_endpoint_rules()`)
  over an `SESv2EndpointConfig` (the host is `email.<region>`);
- `SESv2Client`, which resolves each call's endpoint, signs it with SigV4
  (signing name `ses`) and sends it over the komira_http_core `Connector` it
  is given.

A SendEmail with `EndpointId` goes to a multi-region endpoint that needs
SigV4a, which komira_aws_core does not sign: the client refuses such a call
before sending it. Other SES v2 operations are not generated; the classic SES
receipt rules are `komira_aws_ses`. The package reads no environment.

## Examples

Build a SendEmail request for a plain-text message. Nothing is sent:

<!-- mojo-hidden from std.testing import assert_equal, assert_false, assert_true -->
```mojo
from komira_aws_sesv2.komira_aws_sesv2 import SESv2Body, SESv2Content, SESv2Destination
from komira_aws_sesv2.komira_aws_sesv2 import SESv2EmailContent, SESv2Message
from komira_aws_sesv2.komira_aws_sesv2 import SESv2SendEmailRequest, build_send_email_request

var text = SESv2Body()
text.set_text(SESv2Content(String("Hi there")))
var content = SESv2EmailContent()
content.set_simple(SESv2Message(SESv2Content(String("Hello")), text^))
var input = SESv2SendEmailRequest(content^)
input.set_from_email_address(String("noreply@mail.example.com"))
var to = SESv2Destination()
to.set_to_addresses([String("ops@example.com")])
input.set_destination(to^)
var req = build_send_email_request(input)
assert_equal(req.method, "POST")
assert_equal(req.uri, "/v2/email/outbound-emails")
assert_equal(req.header(String("Content-Type")), "application/json")
assert_equal(
    req.body_text(),
    '{"FromEmailAddress":"noreply@mail.example.com",'
    + '"Destination":{"ToAddresses":["ops@example.com"]},'
    + '"Content":{"Simple":{"Subject":{"Data":"Hello"},"Body":{"Text":{"Data":"Hi there"}}}}}',
)
```

An identity in the path is percent-encoded:

```mojo
from komira_aws_sesv2.komira_aws_sesv2 import SESv2GetEmailIdentityRequest
from komira_aws_sesv2.komira_aws_sesv2 import build_get_email_identity_request

var get = build_get_email_identity_request(SESv2GetEmailIdentityRequest(String("ops@example.com")))
assert_equal(get.method, "GET")
assert_equal(get.uri, "/v2/email/identities/ops%40example.com")
assert_equal(len(get.body), 0)
```

Decode a GetEmailIdentity answer (an identity whose DNS records are not found
yet), and read a restJson1 error:

```mojo
from komira_aws_core import AwsResponse, aws_rest_json_error
from komira_aws_sesv2.komira_aws_sesv2 import parse_get_email_identity_response

var identity = parse_get_email_identity_response(
    AwsResponse.of_text(
        200,
        String(
            '{"IdentityType":"DOMAIN","VerifiedForSendingStatus":false,'
            + '"DkimAttributes":{"Status":"NOT_STARTED"},"VerificationStatus":"PENDING"}'
        ),
    )
)
assert_equal(identity.identity_type.value(), "DOMAIN")
assert_false(identity.verified_for_sending_status.value())
assert_equal(identity.dkim_attributes.value().status.value(), "NOT_STARTED")

var resp = AwsResponse.of_text(
    404, String('{"message":"Email identity mail.example.com does not exist."}')
)
resp.add_header(String("X-Amzn-Errortype"), String("NotFoundException:"))
var info = aws_rest_json_error(resp)
assert_equal(info.status, 404)
assert_equal(info.code, "NotFoundException")
assert_equal(info.message, "Email identity mail.example.com does not exist.")
```

Resolve the endpoint a call goes to:

```mojo
from komira_aws_sesv2.komira_aws_sesv2 import SESv2EndpointConfig, komira_aws_sesv2_endpoint_rules
from komira_aws_sesv2.komira_aws_sesv2 import resolve_get_email_identity_endpoint

var rules = komira_aws_sesv2_endpoint_rules()
var lookup = SESv2GetEmailIdentityRequest(String("mail.example.com"))
assert_equal(
    resolve_get_email_identity_endpoint(rules, SESv2EndpointConfig(String("us-west-2")), lookup).url,
    "https://email.us-west-2.amazonaws.com",
)
var fips = SESv2EndpointConfig(String("us-east-1"))
fips.use_fips = Optional[Bool](True)
assert_equal(
    resolve_get_email_identity_endpoint(rules, fips, lookup).url,
    "https://email-fips.us-east-1.amazonaws.com",
)
```
