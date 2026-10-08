# The responses komira_aws_sesv2 decodes, one or more rows per operation,
# and the restJson1 error form SES v2 answers with. The wire texts are
# written here from the Amazon SES API v2 reference, with made-up domains,
# tokens and ids.
#
# Errors. SES v2 names the error in the `X-Amzn-Errortype` header and
# carries `message` in the body; its error shapes have no members, so the
# code and message are read through komira_aws_core's
# `aws_rest_json_error`.
from komira_aws_sesv2.komira_aws_sesv2 import (
    parse_create_configuration_set_event_destination_response,
    parse_create_configuration_set_response,
    parse_create_email_identity_response,
    parse_delete_configuration_set_response,
    parse_delete_email_identity_response,
    parse_get_email_identity_response,
    parse_put_email_identity_configuration_set_attributes_response,
    parse_put_email_identity_mail_from_attributes_response,
    parse_send_email_response,
)
from komira_aws_core import AwsResponse, aws_is_error_status, aws_rest_json_error
from std.testing import assert_equal, assert_false, assert_true


def _ok(body: String) -> AwsResponse:
    return AwsResponse.of_text(200, body)


def test_create_email_identity() raises:
    var r = parse_create_email_identity_response(
        _ok(
            String(
                '{"IdentityType":"DOMAIN","VerifiedForSendingStatus":false,'
                + '"DkimAttributes":{"SigningEnabled":true,"Status":"PENDING",'
                + '"Tokens":["tok1abc","tok2def","tok3ghi"],'
                + '"SigningAttributesOrigin":"AWS_SES","NextSigningKeyLength":"RSA_2048_BIT",'
                + '"CurrentSigningKeyLength":"RSA_2048_BIT","LastKeyGenerationTimestamp":1790812800}}'
            )
        )
    )
    assert_equal(r.identity_type.value(), "DOMAIN")
    assert_false(r.verified_for_sending_status.value())
    ref d = r.dkim_attributes.value()
    assert_true(d.signing_enabled.value())
    assert_equal(d.status.value(), "PENDING")
    assert_equal(len(d.tokens.value()), 3)
    assert_equal(d.tokens.value()[2], "tok3ghi")
    assert_equal(d.signing_attributes_origin.value(), "AWS_SES")
    assert_equal(d.last_key_generation_timestamp.value(), Float64(1790812800))


def test_get_email_identity() raises:
    var r = parse_get_email_identity_response(
        _ok(
            String(
                '{"IdentityType":"DOMAIN","FeedbackForwardingStatus":true,'
                + '"VerifiedForSendingStatus":true,'
                + '"DkimAttributes":{"SigningEnabled":true,"Status":"SUCCESS",'
                + '"Tokens":["tok1abc","tok2def","tok3ghi"]},'
                + '"MailFromAttributes":{"MailFromDomain":"bounce.mail.example.com",'
                + '"MailFromDomainStatus":"SUCCESS","BehaviorOnMxFailure":"USE_DEFAULT_VALUE"},'
                + '"Policies":{},"Tags":[{"Key":"app","Value":"relay"}],'
                + '"ConfigurationSetName":"mail-example-com","VerificationStatus":"SUCCESS"}'
            )
        )
    )
    assert_equal(r.identity_type.value(), "DOMAIN")
    assert_true(r.feedback_forwarding_status.value())
    assert_true(r.verified_for_sending_status.value())
    assert_equal(r.dkim_attributes.value().status.value(), "SUCCESS")
    assert_equal(r.mail_from_attributes.value().mail_from_domain, "bounce.mail.example.com")
    assert_equal(r.mail_from_attributes.value().behavior_on_mx_failure, "USE_DEFAULT_VALUE")
    assert_equal(len(r.policies.value()), 0)
    assert_equal(r.tags.value()[0].key, "app")
    assert_equal(r.tags.value()[0].value, "relay")
    assert_equal(r.configuration_set_name.value(), "mail-example-com")
    assert_equal(r.verification_status.value(), "SUCCESS")
    assert_false(Bool(r.verification_info))


def test_get_email_identity_pending() raises:
    # A new identity before its DNS records are found.
    var r = parse_get_email_identity_response(
        _ok(
            String(
                '{"IdentityType":"DOMAIN","VerifiedForSendingStatus":false,'
                + '"DkimAttributes":{"Status":"NOT_STARTED"},"VerificationStatus":"PENDING"}'
            )
        )
    )
    assert_false(r.verified_for_sending_status.value())
    assert_equal(r.dkim_attributes.value().status.value(), "NOT_STARTED")
    assert_false(Bool(r.dkim_attributes.value().tokens))
    assert_false(Bool(r.configuration_set_name))


def test_empty_results() raises:
    # Each of these answers 200 with an empty object.
    _ = parse_create_configuration_set_response(_ok(String("{}")))
    _ = parse_delete_email_identity_response(_ok(String("{}")))
    _ = parse_put_email_identity_configuration_set_attributes_response(_ok(String("{}")))
    _ = parse_put_email_identity_mail_from_attributes_response(_ok(String("{}")))
    _ = parse_create_configuration_set_event_destination_response(_ok(String("{}")))
    _ = parse_delete_configuration_set_response(_ok(String("{}")))


def test_send_email() raises:
    var r = parse_send_email_response(
        _ok(String('{"MessageId":"010001900000abcd-1234abcd-0000-4000-8000-0123456789ab-000000"}'))
    )
    assert_equal(r.message_id.value(), "010001900000abcd-1234abcd-0000-4000-8000-0123456789ab-000000")


def _error(status: Int, kind: String, message: String) -> AwsResponse:
    var r = AwsResponse.of_text(status, String('{"message":"') + message + '"}')
    r.add_header(String("X-Amzn-Errortype"), kind)
    r.add_header(String("x-amzn-RequestId"), String("0d5c7f9e-0000-4000-8000-00000000000b"))
    return r^


def test_not_found() raises:
    var r = _error(404, String("NotFoundException:"), String("Email identity mail.example.com does not exist."))
    assert_true(aws_is_error_status(r.status))
    var info = aws_rest_json_error(r)
    assert_equal(info.status, 404)
    assert_equal(info.code, "NotFoundException")
    assert_equal(info.message, "Email identity mail.example.com does not exist.")
    assert_equal(info.request_id, "0d5c7f9e-0000-4000-8000-00000000000b")


def test_already_exists() raises:
    var info = aws_rest_json_error(
        _error(400, String("AlreadyExistsException"), String("Email identity mail.example.com already exist."))
    )
    assert_equal(info.status, 400)
    assert_equal(info.code, "AlreadyExistsException")


def test_message_rejected() raises:
    var info = aws_rest_json_error(
        _error(
            400,
            String("MessageRejected"),
            String("Email address is not verified. The following identities failed the check in region"
            " US-EAST-1: noreply@mail.example.com"),
        )
    )
    assert_equal(info.code, "MessageRejected")
    assert_true(info.message.startswith("Email address is not verified."))


def test_configuration_set_not_found() raises:
    # DeleteConfigurationSet and CreateConfigurationSetEventDestination of a
    # set that does not exist.
    var info = aws_rest_json_error(
        _error(404, String("NotFoundException"), String("Configuration set <mail-example-com> does not exist."))
    )
    assert_equal(info.status, 404)
    assert_equal(info.code, "NotFoundException")
    assert_equal(info.message, "Configuration set <mail-example-com> does not exist.")


def main() raises:
    test_create_email_identity()
    test_get_email_identity()
    test_get_email_identity_pending()
    test_empty_results()
    test_send_email()
    test_not_found()
    test_already_exists()
    test_message_rejected()
    test_configuration_set_not_found()
    print("OK")
