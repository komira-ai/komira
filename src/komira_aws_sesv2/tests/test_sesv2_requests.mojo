# The requests komira_aws_sesv2 builds, exactly: method, path (the
# identity a URI label), headers and the JSON body, members in the model's
# order and an unset member absent. One or more rows per operation, in the
# shapes the Amazon SES API v2 reference documents: a domain identity
# created with Easy DKIM (and an email-address identity, whose `@` is
# percent-encoded in the path), read back, given a custom MAIL FROM domain
# and cleared of it, bound to a configuration set and unbound, deleted; a
# configuration set created, given an SNS event destination, deleted; a
# simple message sent.
from komira_aws_sesv2.komira_aws_sesv2 import (
    SESV2_CONTENT_TYPE,
    SESv2Body,
    SESv2Content,
    SESv2CreateConfigurationSetEventDestinationRequest,
    SESv2CreateConfigurationSetRequest,
    SESv2CreateEmailIdentityRequest,
    SESv2DeleteConfigurationSetRequest,
    SESv2DeleteEmailIdentityRequest,
    SESv2DeliveryOptions,
    SESv2Destination,
    SESv2EmailContent,
    SESv2EventDestinationDefinition,
    SESv2GetEmailIdentityRequest,
    SESv2Message,
    SESv2MessageTag,
    SESv2PutEmailIdentityConfigurationSetAttributesRequest,
    SESv2PutEmailIdentityMailFromAttributesRequest,
    SESv2RawMessage,
    SESv2SendEmailRequest,
    SESv2SnsDestination,
    SESv2Tag,
    build_create_configuration_set_event_destination_request,
    build_create_configuration_set_request,
    build_create_email_identity_request,
    build_delete_configuration_set_request,
    build_delete_email_identity_request,
    build_get_email_identity_request,
    build_put_email_identity_configuration_set_attributes_request,
    build_put_email_identity_mail_from_attributes_request,
    build_send_email_request,
)
from komira_aws_core import AwsRequest
from std.testing import assert_equal, assert_raises


def _check_json(req: AwsRequest) raises:
    assert_equal(req.header(String("Content-Type")), "application/json")
    assert_equal(len(req.header_names), 1)


def _check_bodiless(req: AwsRequest) raises:
    assert_equal(len(req.header_names), 0)
    assert_equal(len(req.body), 0)


def test_wire_constants() raises:
    assert_equal(SESV2_CONTENT_TYPE, "application/json")


def test_create_email_identity() raises:
    var req = build_create_email_identity_request(SESv2CreateEmailIdentityRequest(String("mail.example.com")))
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/v2/email/identities")
    _check_json(req)
    assert_equal(req.body_text(), '{"EmailIdentity":"mail.example.com"}')


def test_create_email_identity_with_tags_and_a_configuration_set() raises:
    var input = SESv2CreateEmailIdentityRequest(String("mail.example.com"))
    var tags = List[SESv2Tag]()
    tags.append(SESv2Tag(String("app"), String("relay")))
    input.set_tags(tags^)
    input.set_configuration_set_name(String("mail-example-com"))
    var req = build_create_email_identity_request(input)
    assert_equal(
        req.body_text(),
        '{"EmailIdentity":"mail.example.com","Tags":[{"Key":"app","Value":"relay"}],'
        + '"ConfigurationSetName":"mail-example-com"}',
    )


def test_get_email_identity() raises:
    var req = build_get_email_identity_request(SESv2GetEmailIdentityRequest(String("mail.example.com")))
    assert_equal(req.method, "GET")
    assert_equal(req.uri, "/v2/email/identities/mail.example.com")
    _check_bodiless(req)


def test_an_address_identity_is_percent_encoded() raises:
    var req = build_get_email_identity_request(SESv2GetEmailIdentityRequest(String("ops@example.com")))
    assert_equal(req.uri, "/v2/email/identities/ops%40example.com")


def test_delete_email_identity() raises:
    var req = build_delete_email_identity_request(SESv2DeleteEmailIdentityRequest(String("mail.example.com")))
    assert_equal(req.method, "DELETE")
    assert_equal(req.uri, "/v2/email/identities/mail.example.com")
    _check_bodiless(req)


def test_create_configuration_set() raises:
    var input = SESv2CreateConfigurationSetRequest(String("mail-example-com"))
    var delivery = SESv2DeliveryOptions()
    delivery.set_tls_policy(String("REQUIRE"))
    input.set_delivery_options(delivery^)
    var tags = List[SESv2Tag]()
    tags.append(SESv2Tag(String("app"), String("relay")))
    input.set_tags(tags^)
    var req = build_create_configuration_set_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/v2/email/configuration-sets")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"ConfigurationSetName":"mail-example-com","DeliveryOptions":{"TlsPolicy":"REQUIRE"},'
        + '"Tags":[{"Key":"app","Value":"relay"}]}',
    )


def test_put_email_identity_configuration_set_attributes() raises:
    var input = SESv2PutEmailIdentityConfigurationSetAttributesRequest(String("mail.example.com"))
    input.set_configuration_set_name(String("mail-example-com"))
    var req = build_put_email_identity_configuration_set_attributes_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(req.uri, "/v2/email/identities/mail.example.com/configuration-set")
    _check_json(req)
    assert_equal(req.body_text(), '{"ConfigurationSetName":"mail-example-com"}')


def test_put_with_no_configuration_set_unbinds() raises:
    # The API reference: leaving ConfigurationSetName out removes the
    # identity's default configuration set. The body is then an empty object.
    var req = build_put_email_identity_configuration_set_attributes_request(
        SESv2PutEmailIdentityConfigurationSetAttributesRequest(String("mail.example.com"))
    )
    assert_equal(req.body_text(), "{}")
    _check_json(req)


def test_put_email_identity_mail_from_attributes() raises:
    var input = SESv2PutEmailIdentityMailFromAttributesRequest(String("mail.example.com"))
    input.set_mail_from_domain(String("bounce.mail.example.com"))
    input.set_behavior_on_mx_failure(String("USE_DEFAULT_VALUE"))
    var req = build_put_email_identity_mail_from_attributes_request(input)
    assert_equal(req.method, "PUT")
    assert_equal(req.uri, "/v2/email/identities/mail.example.com/mail-from")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"MailFromDomain":"bounce.mail.example.com","BehaviorOnMxFailure":"USE_DEFAULT_VALUE"}',
    )


def test_put_with_no_mail_from_domain_sends_empty_object() raises:
    # The operation "enables or disables" a custom MAIL FROM domain and
    # MailFromDomain is optional; the v2 reference does not say what omitting
    # it does (classic SES documents that a null MailFromDomain disables it, in
    # SetIdentityMailFromDomain). Omitted, the body is an empty object.
    var req = build_put_email_identity_mail_from_attributes_request(
        SESv2PutEmailIdentityMailFromAttributesRequest(String("mail.example.com"))
    )
    assert_equal(req.uri, "/v2/email/identities/mail.example.com/mail-from")
    _check_json(req)
    assert_equal(req.body_text(), "{}")


def _feedback() -> SESv2EventDestinationDefinition:
    var dest = SESv2EventDestinationDefinition()
    dest.set_enabled(True)
    dest.set_matching_event_types([String("BOUNCE"), String("COMPLAINT"), String("DELIVERY_DELAY")])
    dest.set_sns_destination(SESv2SnsDestination(String("arn:aws:sns:us-east-1:123456789012:ses-feedback")))
    return dest^


def test_create_configuration_set_event_destination() raises:
    # The configuration set is the URI label; the destination's name and
    # definition are the body.
    var req = build_create_configuration_set_event_destination_request(
        SESv2CreateConfigurationSetEventDestinationRequest(String("mail-example-com"), String("feedback"), _feedback())
    )
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/v2/email/configuration-sets/mail-example-com/event-destinations")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"EventDestinationName":"feedback","EventDestination":{"Enabled":true,'
        + '"MatchingEventTypes":["BOUNCE","COMPLAINT","DELIVERY_DELAY"],'
        + '"SnsDestination":{"TopicArn":"arn:aws:sns:us-east-1:123456789012:ses-feedback"}}}',
    )


def test_delete_configuration_set() raises:
    var req = build_delete_configuration_set_request(SESv2DeleteConfigurationSetRequest(String("mail-example-com")))
    assert_equal(req.method, "DELETE")
    assert_equal(req.uri, "/v2/email/configuration-sets/mail-example-com")
    _check_bodiless(req)


def _simple() -> SESv2EmailContent:
    var text = SESv2Body()
    text.set_text(SESv2Content(String("Hi there")))
    var content = SESv2EmailContent()
    content.set_simple(SESv2Message(SESv2Content(String("Hello")), text^))
    return content^


def test_send_email_simple() raises:
    var input = SESv2SendEmailRequest(_simple())
    input.set_from_email_address(String("noreply@mail.example.com"))
    var to = SESv2Destination()
    to.set_to_addresses([String("ops@example.com")])
    input.set_destination(to^)
    input.set_configuration_set_name(String("mail-example-com"))
    var req = build_send_email_request(input)
    assert_equal(req.method, "POST")
    assert_equal(req.uri, "/v2/email/outbound-emails")
    _check_json(req)
    assert_equal(
        req.body_text(),
        '{"FromEmailAddress":"noreply@mail.example.com",'
        + '"Destination":{"ToAddresses":["ops@example.com"]},'
        + '"Content":{"Simple":{"Subject":{"Data":"Hello"},"Body":{"Text":{"Data":"Hi there"}}}},'
        + '"ConfigurationSetName":"mail-example-com"}',
    )


def test_send_email_html_charset_reply_to_and_tags() raises:
    var subject = SESv2Content(String("Café"))
    subject.set_charset(String("UTF-8"))
    var body = SESv2Body()
    body.set_html(SESv2Content(String('<p class="x">Hi</p>')))
    var content = SESv2EmailContent()
    content.set_simple(SESv2Message(subject^, body^))
    var input = SESv2SendEmailRequest(content^)
    input.set_from_email_address(String("noreply@mail.example.com"))
    input.set_reply_to_addresses([String("help@example.com")])
    var tags = List[SESv2MessageTag]()
    tags.append(SESv2MessageTag(String("kind"), String("receipt")))
    input.set_email_tags(tags^)
    var req = build_send_email_request(input)
    assert_equal(
        req.body_text(),
        '{"FromEmailAddress":"noreply@mail.example.com","ReplyToAddresses":["help@example.com"],'
        + '"Content":{"Simple":{"Subject":{"Data":"Café","Charset":"UTF-8"},'
        + '"Body":{"Html":{"Data":"<p class=\\"x\\">Hi</p>"}}}},'
        + '"EmailTags":[{"Name":"kind","Value":"receipt"}]}',
    )


def test_send_email_raw_is_base64() raises:
    # A blob member in a JSON body is base64.
    var raw = List[UInt8]()
    raw.extend(Span(String("Subject: x\r\n\r\nhi").as_bytes()))
    var content = SESv2EmailContent()
    content.set_raw(SESv2RawMessage(raw^))
    var req = build_send_email_request(SESv2SendEmailRequest(content^))
    assert_equal(req.body_text(), '{"Content":{"Raw":{"Data":"U3ViamVjdDogeA0KDQpoaQ=="}}}')


def test_refusals_before_the_wire() raises:
    # `EmailIdentity` is `min: 1` in the model.
    with assert_raises(contains="EmailIdentity"):
        _ = build_get_email_identity_request(SESv2GetEmailIdentityRequest(String("")))
    with assert_raises(contains="EmailIdentity"):
        _ = build_create_email_identity_request(SESv2CreateEmailIdentityRequest(String("")))
    with assert_raises(contains="EmailIdentity"):
        _ = build_put_email_identity_mail_from_attributes_request(
            SESv2PutEmailIdentityMailFromAttributesRequest(String(""))
        )
    # A nested bound is checked too: the destination's topic is an
    # AmazonResourceName, `min: 1`.
    var dest = SESv2EventDestinationDefinition()
    dest.set_sns_destination(SESv2SnsDestination(String("")))
    with assert_raises(contains="SESv2SnsDestination.TopicArn: the model states min length 1, got 0"):
        _ = build_create_configuration_set_event_destination_request(
            SESv2CreateConfigurationSetEventDestinationRequest(String("mail-example-com"), String("feedback"), dest^)
        )


def main() raises:
    test_wire_constants()
    test_create_email_identity()
    test_create_email_identity_with_tags_and_a_configuration_set()
    test_get_email_identity()
    test_an_address_identity_is_percent_encoded()
    test_delete_email_identity()
    test_create_configuration_set()
    test_put_email_identity_configuration_set_attributes()
    test_put_with_no_configuration_set_unbinds()
    test_put_email_identity_mail_from_attributes()
    test_put_with_no_mail_from_domain_sends_empty_object()
    test_create_configuration_set_event_destination()
    test_delete_configuration_set()
    test_send_email_simple()
    test_send_email_html_charset_reply_to_and_tags()
    test_send_email_raw_is_base64()
    test_refusals_before_the_wire()
    print("OK")
