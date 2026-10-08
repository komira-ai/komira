# Where komira_aws_ses sends a request, and the requests it signs.
#
# The endpoint comes from SES's published endpoint ruleset, embedded in the
# generated module and resolved over `SESEndpointConfig`. Rows: every case
# of botocore's ses endpoint tests (read from the pinned archive at test
# time, never copied), resolved through every operation of the client and
# signed for the case's region, then the cases a caller depends on, by
# name: the regional default (host `email.<region>`, signing name `ses`),
# FIPS, dual-stack, a custom endpoint (LocalStack), and the ruleset's
# refusals.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock and
# AWS's documented example credentials: CreateReceiptRuleSet to us-west-2
# and DescribeActiveReceiptRuleSet to LocalStack. Their signatures were
# computed by an independent SigV4 implementation (one that reproduces
# komira_aws_sns's and komira_aws_sesv2's signed rows) over the canonical
# requests stated beside them.
# The method, to rerun: the SHA-256 of the canonical request, then the
# SigV4 HMAC-SHA256 key chain (date, region, service, "aws4_request") and
# the HMAC-SHA256 of the string-to-sign, each step a standard openssl
# invocation (`openssl dgst -sha256 [-mac HMAC -macopt hexkey:<key>]`).
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
from komira_aws_ses.komira_aws_ses import (
    SESCreateReceiptRuleRequest,
    SESCreateReceiptRuleSetRequest,
    SESDeleteReceiptRuleRequest,
    SESDescribeActiveReceiptRuleSetRequest,
    SESEndpointConfig,
    SESReceiptRule,
    SESSetActiveReceiptRuleSetRequest,
    build_create_receipt_rule_set_request,
    build_describe_active_receipt_rule_set_request,
    komira_aws_ses_endpoint_rules,
    resolve_create_receipt_rule_endpoint,
    resolve_create_receipt_rule_set_endpoint,
    resolve_delete_receipt_rule_endpoint,
    resolve_describe_active_receipt_rule_set_endpoint,
    resolve_set_active_receipt_rule_set_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/ses/endpoint-tests-1.json"

# The case counts at the pinned botocore release: a shrunken file cannot
# pass as the suite.
comptime _EXPECTED_CASES = 43
comptime _EXPECTED_ERROR_CASES = 3


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


def _case_config(tc: JsonValue) raises -> SESEndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = SESEndpointConfig()
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
        else:
            raise Error("a case parameter the ses config has no field for: " + name)
    return c^


def _resolve_all(rules: EndpointRuleSet, config: SESEndpointConfig) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one: SES binds no
    operation parameter, so each resolves the config alone."""
    var got = resolve_create_receipt_rule_set_endpoint(rules, config, SESCreateReceiptRuleSetRequest(String("r")))
    var others = List[ResolvedEndpoint]()
    others.append(
        resolve_create_receipt_rule_endpoint(
            rules, config, SESCreateReceiptRuleRequest(String("r"), SESReceiptRule(String("n")))
        )
    )
    others.append(
        resolve_delete_receipt_rule_endpoint(rules, config, SESDeleteReceiptRuleRequest(String("r"), String("n")))
    )
    others.append(
        resolve_describe_active_receipt_rule_set_endpoint(rules, config, SESDescribeActiveReceiptRuleSetRequest())
    )
    others.append(resolve_set_active_receipt_rule_set_endpoint(rules, config, SESSetActiveReceiptRuleSetRequest()))
    for i in range(len(others)):
        if others[i].url != got.url:
            raise Error("operations disagree: " + others[i].url + " and " + got.url)
        if not _json_equal(others[i].properties, got.properties):
            raise Error("operations disagree on the properties of " + got.url)
    return got^


def _case_signing_region(want: JsonValue, config: SESEndpointConfig) -> String:
    """The case's `authSchemes[0].signingRegion`, else the configured
    region (a custom endpoint states none)."""
    var props = _member_or_empty(want, "properties")
    var ai = _find(props, "authSchemes")
    if ai >= 0 and len(props.children[ai].children) > 0:
        ref scheme = props.children[ai].children[0]
        var si = _find(scheme, "signingRegion")
        if si >= 0:
            return scheme.children[si].text
    if config.region:
        return config.region.value()
    return String("")


def _check_case(rules: EndpointRuleSet, tc: JsonValue, mut why: String) raises -> Bool:
    var config = _case_config(tc)
    ref expect = tc.children[_find(tc, "expect")]
    var ei = _find(expect, "endpoint")
    if ei >= 0:
        ref want = expect.children[ei]
        var url = want.children[_find(want, "url")].text
        try:
            var got = _resolve_all(rules, config)
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
            var region = _case_signing_region(want, config)
            if region.byte_length() > 0:
                # The caller's region is the case's; the signing region is
                # the ruleset's when it states one.
                var caller = config.region.value() if config.region else region
                var t = aws_signing_target(got, caller, String("ses"))
                if t.signing_name != "ses" or t.signing_region != region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region + ", expected ses/" + region
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
        var got = _resolve_all(rules, config)
        why = "endpoint " + got.url + ", expected the error '" + msg + "'"
        return False
    except e:
        if String(e).find(msg) < 0:
            why = "raised '" + String(e) + "', expected '" + msg + "'"
            return False
    return True


def test_botocore_endpoint_cases() raises:
    var rules = komira_aws_ses_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged ses endpoint cases")
    var errors = 0
    var failed = 0
    var report = String("")
    for i in range(n):
        ref tc = cases.children[i]
        ref expect = tc.children[_find(tc, "expect")]
        if _find(expect, "error") >= 0:
            errors += 1
        var why = String("")
        if not _check_case(rules, tc, why):
            failed += 1
            var d = _find(tc, "documentation")
            report += "  " + (tc.children[d].text if d >= 0 else String("")) + ": " + why + "\n"
    assert_equal(errors, _EXPECTED_ERROR_CASES, "the error cases")
    if failed > 0:
        raise Error(String(failed) + " of " + String(n) + " ses endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: SESEndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_ses_endpoint_rules(), config)


def test_regional_default() raises:
    var got = _resolve(SESEndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://email.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String("ses"))
    assert_equal(t.signing_name, "ses")
    assert_equal(t.signing_region, "us-west-2")


def test_fips_and_dual_stack() raises:
    var fips = SESEndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://email-fips.us-east-1.amazonaws.com")
    var dual = SESEndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://email.us-east-1.api.aws")


def test_custom_endpoint() raises:
    var config = SESEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String("ses"))
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    assert_equal(t.endpoint.url_for(String("/")), "http://localhost:4566/")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(SESEndpointConfig())
    var fips = SESEndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = SESEndpointConfig(String("us-east-1"))
    dual.endpoint = Optional[String](String("http://localhost:4566"))
    dual.use_dual_stack = Optional[Bool](True)
    with assert_raises(contains="Dualstack and custom endpoint are not supported"):
        _ = _resolve(dual)


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


def test_signed_create_receipt_rule_set() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /
    #
    #   content-type:application/x-www-form-urlencoded; charset=utf-8
    #   host:email.us-west-2.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   820b4e9fe6de750340a522cdd1ec8d64495e09939accacb40578d98c128078d1
    var built = build_create_receipt_rule_set_request(SESCreateReceiptRuleSetRequest(String("inbound-rules")))
    assert_equal(built.body_text(), "Action=CreateReceiptRuleSet&Version=2010-12-01&RuleSetName=inbound-rules")
    var req = _signed(built, _resolve(SESEndpointConfig(String("us-west-2"))), String("us-west-2"))
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "email.us-west-2.amazonaws.com")
    assert_equal(req.target, "/")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-west-2/ses/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=83fafae0b5d276fc2e40a2f8a53310aea33082d9759097bcaf2cadacc93df919",
    )


def test_signed_describe_active_receipt_rule_set_to_localstack() raises:
    # Canonical request:
    #   POST
    #   /
    #
    #   content-type:application/x-www-form-urlencoded; charset=utf-8
    #   host:localhost:4566
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   52a090e191fe93a14208e893092c24b84500b839685fefd82dbf0508c98802ec
    var built = build_describe_active_receipt_rule_set_request(SESDescribeActiveReceiptRuleSetRequest())
    assert_equal(built.body_text(), "Action=DescribeActiveReceiptRuleSet&Version=2010-12-01")
    var config = SESEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var req = _signed(built, _resolve(config), String("us-east-1"))
    assert_equal(req.scheme, "http")
    assert_equal(req.host, "localhost")
    assert_equal(req.port, 4566)
    assert_equal(req.header("Host"), "localhost:4566")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/ses/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=858dc7e9b3348b6634e8580d45e14dcc07e39340ef292af7c2cfef12905b926b",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_create_receipt_rule_set()
    test_signed_describe_active_receipt_rule_set_to_localstack()
    print("OK")
