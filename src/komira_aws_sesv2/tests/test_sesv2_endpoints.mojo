# Where komira_aws_sesv2 sends a request, and the requests it signs.
#
# The endpoint comes from SES v2's published endpoint ruleset, embedded in
# the generated module and resolved over `SESv2EndpointConfig`. Rows: every
# case of botocore's sesv2 endpoint tests (read from the pinned archive at
# test time, never copied), then the cases a caller depends on, by name: the
# regional default (host `email.<region>`, signing name `ses`), FIPS,
# dual-stack, a custom endpoint (LocalStack), and the ruleset's refusals.
#
# A case without `EndpointId` resolves through every operation of the
# client, which must agree. A case with one is SendEmail's alone (the only
# operation here binding that context parameter) and resolves through it,
# with the input's `EndpointId` set: those are multi-region endpoints, which
# the ruleset signs with SigV4a, and the row also asserts that
# komira_aws_core refuses to sign one rather than signing it as SigV4.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock and
# AWS's documented example credentials: SendEmail to us-east-1 and
# GetEmailIdentity of an address identity in eu-west-1, whose `@` is
# percent-encoded in the path and encoded again in the canonical path, as
# SigV4 does for every service but S3. Their signatures were computed by an
# independent SigV4 implementation (one that reproduces the signature AWS
# publishes for its IAM ListUsers SigV4 example) over the canonical requests
# stated beside them.
from komira_json import (
    JSON_ARRAY,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_value,
)
from komira_aws_core import (
    AwsCredential,
    AwsRequest,
    CredentialHttpRequest,
    EndpointRuleSet,
    FixedClock,
    Header,
    ResolvedEndpoint,
    aws_signing_target,
    build_sigv4_signed_request,
)
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
    SESv2SendEmailRequest,
    build_get_email_identity_request,
    build_send_email_request,
    komira_aws_sesv2_endpoint_rules,
    resolve_create_configuration_set_endpoint,
    resolve_create_configuration_set_event_destination_endpoint,
    resolve_create_email_identity_endpoint,
    resolve_delete_configuration_set_endpoint,
    resolve_delete_email_identity_endpoint,
    resolve_get_email_identity_endpoint,
    resolve_put_email_identity_configuration_set_attributes_endpoint,
    resolve_put_email_identity_mail_from_attributes_endpoint,
    resolve_send_email_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/sesv2/endpoint-tests-1.json"

# The case counts at the pinned botocore release: a shrunken file cannot
# pass as the suite.
comptime _EXPECTED_CASES = 62
comptime _EXPECTED_ERROR_CASES = 11
comptime _EXPECTED_ENDPOINT_ID_CASES = 18


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _find(v: JsonValue, key: String) -> Int:
    if v.kind != JSON_OBJECT:
        return -1
    for i in range(len(v.obj_keys)):
        if v.obj_keys[i] == key:
            return i
    return -1


def _member_or_empty(v: JsonValue, key: String) -> JsonValue:
    var i = _find(v, key)
    if i < 0:
        return JsonValue.empty_object()
    return v.children[i].copy()


def _json_equal(a: JsonValue, b: JsonValue) -> Bool:
    """Structural equality: object members by key in any order."""
    if a.kind != b.kind:
        return False
    if a.kind == JSON_BOOL:
        return a.bool_val == b.bool_val
    if a.kind == JSON_STRING or a.kind == JSON_NUMBER:
        return a.text == b.text
    if a.kind == JSON_ARRAY:
        if len(a.children) != len(b.children):
            return False
        for i in range(len(a.children)):
            if not _json_equal(a.children[i], b.children[i]):
                return False
        return True
    if a.kind == JSON_OBJECT:
        if len(a.obj_keys) != len(b.obj_keys):
            return False
        for i in range(len(a.obj_keys)):
            var j = _find(b, a.obj_keys[i])
            if j < 0 or not _json_equal(a.children[i], b.children[j]):
                return False
        return True
    return True


def _case_config(tc: JsonValue, mut endpoint_id: Optional[String]) raises -> SESv2EndpointConfig:
    """The generated config holding the case's client parameters; its
    `EndpointId`, an operation parameter, is returned beside it."""
    var c = SESv2EndpointConfig()
    var pi = _find(tc, "params")
    if pi < 0:
        return c^
    ref p = tc.children[pi]
    for i in range(len(p.obj_keys)):
        ref name = p.obj_keys[i]
        ref v = p.children[i]
        if name == "Region" and v.kind == JSON_STRING:
            c.region = Optional[String](v.text)
        elif name == "Endpoint" and v.kind == JSON_STRING:
            c.endpoint = Optional[String](v.text)
        elif name == "UseFIPS" and v.kind == JSON_BOOL:
            c.use_fips = Optional[Bool](v.bool_val)
        elif name == "UseDualStack" and v.kind == JSON_BOOL:
            c.use_dual_stack = Optional[Bool](v.bool_val)
        elif name == "EndpointId" and v.kind == JSON_STRING:
            endpoint_id = Optional[String](v.text)
        else:
            raise Error("a case parameter the sesv2 config has no field for: " + name)
    return c^


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


def _resolve_all(rules: EndpointRuleSet, config: SESv2EndpointConfig) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one when no
    `EndpointId` is set."""
    var got = resolve_send_email_endpoint(rules, config, _send())
    var others = List[ResolvedEndpoint]()
    others.append(
        resolve_create_configuration_set_endpoint(rules, config, SESv2CreateConfigurationSetRequest(String("c")))
    )
    others.append(resolve_create_email_identity_endpoint(rules, config, SESv2CreateEmailIdentityRequest(String("d"))))
    others.append(resolve_delete_email_identity_endpoint(rules, config, SESv2DeleteEmailIdentityRequest(String("d"))))
    others.append(resolve_get_email_identity_endpoint(rules, config, SESv2GetEmailIdentityRequest(String("d"))))
    others.append(
        resolve_put_email_identity_configuration_set_attributes_endpoint(
            rules, config, SESv2PutEmailIdentityConfigurationSetAttributesRequest(String("d"))
        )
    )
    others.append(
        resolve_put_email_identity_mail_from_attributes_endpoint(
            rules, config, SESv2PutEmailIdentityMailFromAttributesRequest(String("d"))
        )
    )
    others.append(
        resolve_create_configuration_set_event_destination_endpoint(
            rules,
            config,
            SESv2CreateConfigurationSetEventDestinationRequest(
                String("c"), String("e"), SESv2EventDestinationDefinition()
            ),
        )
    )
    others.append(
        resolve_delete_configuration_set_endpoint(rules, config, SESv2DeleteConfigurationSetRequest(String("c")))
    )
    for i in range(len(others)):
        if others[i].url != got.url:
            raise Error("operations disagree: " + others[i].url + " and " + got.url)
    return got^


def _resolve_case(
    rules: EndpointRuleSet, config: SESv2EndpointConfig, endpoint_id: Optional[String]
) raises -> ResolvedEndpoint:
    if endpoint_id:
        var input = _send()
        input.set_endpoint_id(endpoint_id.value())
        return resolve_send_email_endpoint(rules, config, input)
    return _resolve_all(rules, config)


def _check_case(rules: EndpointRuleSet, tc: JsonValue, mut why: String) raises -> Bool:
    var endpoint_id = Optional[String]()
    var config = _case_config(tc, endpoint_id)
    ref expect = tc.children[_find(tc, "expect")]
    var ei = _find(expect, "endpoint")
    if ei >= 0:
        ref want = expect.children[ei]
        var url = want.children[_find(want, "url")].text
        try:
            var got = _resolve_case(rules, config, endpoint_id)
            if got.url != url:
                why = "url " + got.url + ", expected " + url
                return False
            var props = _member_or_empty(want, "properties")
            if not _json_equal(got.properties, props):
                why = "properties " + got.properties.serialize() + ", expected " + props.serialize()
                return False
            var headers = _member_or_empty(want, "headers")
            if not _json_equal(got.headers, headers):
                why = "headers " + got.headers.serialize() + ", expected " + headers.serialize()
                return False
            var region = config.region.value() if config.region else String("")
            if endpoint_id:
                # A multi-region endpoint is signed with SigV4a.
                try:
                    _ = aws_signing_target(got, region, String("ses"))
                    why = "a sigv4a endpoint was signed"
                    return False
                except e:
                    if String(e).find("sigv4a") < 0:
                        why = "signing refused with: " + String(e)
                        return False
            elif config.region:
                var t = aws_signing_target(got, region, String("ses"))
                if t.signing_name != "ses" or t.signing_region != region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region
                    return False
            else:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(got, String(""), String("ses"))
                    why = "signed with no region"
                    return False
                except e:
                    if String(e).find("no signing region") < 0:
                        why = "signing refused with: " + String(e)
                        return False
        except e:
            why = "raised: " + String(e)
            return False
        return True
    var msg = expect.children[_find(expect, "error")].text
    try:
        var got = _resolve_case(rules, config, endpoint_id)
        why = "endpoint " + got.url + ", expected the error '" + msg + "'"
        return False
    except e:
        if String(e).find(msg) < 0:
            why = "raised '" + String(e) + "', expected '" + msg + "'"
            return False
    return True


def test_botocore_endpoint_cases() raises:
    var rules = komira_aws_sesv2_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged sesv2 endpoint cases")
    var errors = 0
    var with_id = 0
    var failed = 0
    var report = String("")
    for i in range(n):
        ref tc = cases.children[i]
        ref expect = tc.children[_find(tc, "expect")]
        if _find(expect, "error") >= 0:
            errors += 1
        var pi = _find(tc, "params")
        if pi >= 0 and _find(tc.children[pi], "EndpointId") >= 0:
            with_id += 1
        var why = String("")
        if not _check_case(rules, tc, why):
            failed += 1
            var d = _find(tc, "documentation")
            report += "  " + (tc.children[d].text if d >= 0 else String("")) + ": " + why + "\n"
    assert_equal(errors, _EXPECTED_ERROR_CASES, "the error cases")
    assert_equal(with_id, _EXPECTED_ENDPOINT_ID_CASES, "the EndpointId cases")
    if failed > 0:
        raise Error(String(failed) + " of " + String(n) + " sesv2 endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: SESv2EndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_sesv2_endpoint_rules(), config)


def test_regional_default() raises:
    var got = _resolve(SESv2EndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://email.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String("ses"))
    assert_equal(t.signing_name, "ses")
    assert_equal(t.signing_region, "us-west-2")


def test_fips_and_dual_stack() raises:
    var fips = SESv2EndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://email-fips.us-east-1.amazonaws.com")
    var dual = SESv2EndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://email.us-east-1.api.aws")


def test_custom_endpoint() raises:
    var config = SESv2EndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String("ses"))
    assert_equal(t.endpoint.host_header(), "localhost:4566")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(SESv2EndpointConfig())
    var fips = SESv2EndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var input = _send()
    input.set_endpoint_id(String("badactor.com?foo=bar"))
    with assert_raises(contains="EndpointId must be a valid host label"):
        _ = resolve_send_email_endpoint(
            komira_aws_sesv2_endpoint_rules(), SESv2EndpointConfig(String("us-east-1")), input
        )


# ---- signed ---------------------------------------------------------------------

comptime _KEY = "AKIAIOSFODNN7EXAMPLE"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
# 2026-10-01T00:00:00Z.
comptime _NOW = 1790812800


def _signed(req: AwsRequest, resolved: ResolvedEndpoint, region: String) raises -> CredentialHttpRequest:
    var t = aws_signing_target(resolved, region, String("ses"))
    var extra = List[Header]()
    var content_type = String("")
    for i in range(len(req.header_names)):
        if req.header_names[i] == "Content-Type":
            content_type = req.header_values[i]
        else:
            extra.append(Header(req.header_names[i], req.header_values[i]))
    var clock = FixedClock(_NOW)
    return build_sigv4_signed_request(
        req.method,
        AwsCredential(String(_KEY), String(_SECRET), String("")),
        t.signing_region,
        t.signing_name,
        t.endpoint,
        req.uri,
        content_type,
        Span(req.body),
        extra,
        clock,
    )


def test_signed_send_email() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /v2/email/outbound-emails
    #
    #   content-type:application/json
    #   host:email.us-east-1.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   d03113b0c7702f44b2f2e55cb9fcd1fab1b447f14cfc1093ed00d4c1cac6a6f7
    var input = _send()
    input.set_configuration_set_name(String("mail-example-com"))
    var built = build_send_email_request(input)
    assert_equal(
        built.body_text(),
        '{"FromEmailAddress":"noreply@mail.example.com",'
        + '"Destination":{"ToAddresses":["ops@example.com"]},'
        + '"Content":{"Simple":{"Subject":{"Data":"Hello"},"Body":{"Text":{"Data":"Hi there"}}}},'
        + '"ConfigurationSetName":"mail-example-com"}',
    )
    var req = _signed(built, _resolve(SESv2EndpointConfig(String("us-east-1"))), String("us-east-1"))
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "email.us-east-1.amazonaws.com")
    assert_equal(req.target, "/v2/email/outbound-emails")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/ses/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=403c7ba60bed3bda194f21297fb6a9246b3289b84c95134ac71b2fc1eaa8b181",
    )


def test_signed_get_email_identity_of_an_address() raises:
    # Canonical request (the empty payload's hash); the path's %40 is
    # encoded again, to %2540:
    #   GET
    #   /v2/email/identities/ops%2540example.com
    #
    #   host:email.eu-west-1.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #
    #   host;x-amz-date
    #   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    var built = build_get_email_identity_request(SESv2GetEmailIdentityRequest(String("ops@example.com")))
    var req = _signed(built, _resolve(SESv2EndpointConfig(String("eu-west-1"))), String("eu-west-1"))
    assert_equal(req.host, "email.eu-west-1.amazonaws.com")
    assert_equal(req.target, "/v2/email/identities/ops%40example.com")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/eu-west-1/ses/aws4_request, "
        + "SignedHeaders=host;x-amz-date, "
        + "Signature=1d40f3abd5e3f14dc832c999ee9a68ca356e34d8a43edd039212bd77ba813c31",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_send_email()
    test_signed_get_email_identity_of_an_address()
    print("OK")
