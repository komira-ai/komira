# Where komira_aws_sns sends a request, and the requests it signs.
#
# The endpoint comes from SNS's published endpoint ruleset, embedded in the
# generated module and resolved over `SNSEndpointConfig`. Rows: every case
# of botocore's sns endpoint tests (read from the pinned archive at test
# time, never copied), resolved through every operation of the client and
# signed for the case's region, then the cases a caller depends on, by
# name: the regional default, FIPS, dual-stack, a custom endpoint
# (LocalStack), and the ruleset's refusals.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock and
# AWS's documented example credentials: CreateTopic to us-west-2 and
# GetTopicAttributes to LocalStack. Their signatures were computed by an
# independent SigV4 implementation (one that reproduces komira_aws_sqs's
# signed rows) over the canonical requests stated beside them.
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
from komira_aws_sns.komira_aws_sns import (
    SNSCreateTopicInput,
    SNSDeleteTopicInput,
    SNSEndpointConfig,
    SNSGetSubscriptionAttributesInput,
    SNSGetTopicAttributesInput,
    SNSListSubscriptionsByTopicInput,
    SNSSetSubscriptionAttributesInput,
    SNSSetTopicAttributesInput,
    SNSSubscribeInput,
    SNSUnsubscribeInput,
    build_create_topic_request,
    build_get_topic_attributes_request,
    komira_aws_sns_endpoint_rules,
    resolve_create_topic_endpoint,
    resolve_delete_topic_endpoint,
    resolve_get_subscription_attributes_endpoint,
    resolve_get_topic_attributes_endpoint,
    resolve_list_subscriptions_by_topic_endpoint,
    resolve_set_subscription_attributes_endpoint,
    resolve_set_topic_attributes_endpoint,
    resolve_subscribe_endpoint,
    resolve_unsubscribe_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/sns/endpoint-tests-1.json"

# The case counts at the pinned botocore release: a shrunken file cannot
# pass as the suite.
comptime _EXPECTED_CASES = 49
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


def _case_config(tc: JsonValue) raises -> SNSEndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = SNSEndpointConfig()
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
            raise Error("a case parameter the sns config has no field for: " + name)
    return c^


comptime _TOPIC = "arn:aws:sns:us-east-1:123456789012:bounces"
comptime _SUB = "arn:aws:sns:us-east-1:123456789012:bounces:4f6a0c1e"


def _resolve_all(rules: EndpointRuleSet, config: SNSEndpointConfig) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one: SNS binds no
    operation parameter, so each resolves the config alone."""
    var got = resolve_create_topic_endpoint(rules, config, SNSCreateTopicInput(String("bounces")))
    var others = List[ResolvedEndpoint]()
    others.append(resolve_delete_topic_endpoint(rules, config, SNSDeleteTopicInput(String(_TOPIC))))
    others.append(
        resolve_get_subscription_attributes_endpoint(rules, config, SNSGetSubscriptionAttributesInput(String(_SUB)))
    )
    others.append(resolve_get_topic_attributes_endpoint(rules, config, SNSGetTopicAttributesInput(String(_TOPIC))))
    others.append(
        resolve_list_subscriptions_by_topic_endpoint(rules, config, SNSListSubscriptionsByTopicInput(String(_TOPIC)))
    )
    others.append(
        resolve_set_subscription_attributes_endpoint(
            rules, config, SNSSetSubscriptionAttributesInput(String(_SUB), String("FilterPolicy"))
        )
    )
    others.append(
        resolve_set_topic_attributes_endpoint(
            rules, config, SNSSetTopicAttributesInput(String(_TOPIC), String("DisplayName"))
        )
    )
    others.append(resolve_subscribe_endpoint(rules, config, SNSSubscribeInput(String(_TOPIC), String("sqs"))))
    others.append(resolve_unsubscribe_endpoint(rules, config, SNSUnsubscribeInput(String(_SUB))))
    for i in range(len(others)):
        if others[i].url != got.url:
            raise Error("operations disagree: " + others[i].url + " and " + got.url)
        if not _json_equal(others[i].properties, got.properties):
            raise Error("operations disagree on the properties of " + got.url)
    return got^


def _case_signing_region(want: JsonValue, config: SNSEndpointConfig) -> String:
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
                var t = aws_signing_target(got, caller, String("sns"))
                if t.signing_name != "sns" or t.signing_region != region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region + ", expected sns/" + region
                    return False
            else:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(got, String(""), String("sns"))
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
    var rules = komira_aws_sns_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged sns endpoint cases")
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
        raise Error(String(failed) + " of " + String(n) + " sns endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: SNSEndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_sns_endpoint_rules(), config)


def test_regional_default() raises:
    var got = _resolve(SNSEndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://sns.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String("sns"))
    assert_equal(t.signing_name, "sns")
    assert_equal(t.signing_region, "us-west-2")
    assert_equal(_resolve(SNSEndpointConfig(String("cn-north-1"))).url, "https://sns.cn-north-1.amazonaws.com.cn")


def test_fips_and_dual_stack() raises:
    var fips = SNSEndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://sns-fips.us-east-1.amazonaws.com")
    var dual = SNSEndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://sns.us-east-1.api.aws")
    # In GovCloud the FIPS endpoint is the plain regional host.
    var gov = SNSEndpointConfig(String("us-gov-west-1"))
    gov.use_fips = Optional[Bool](True)
    assert_equal(_resolve(gov).url, "https://sns.us-gov-west-1.amazonaws.com")


def test_custom_endpoint() raises:
    var config = SNSEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String("sns"))
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    assert_equal(t.endpoint.url_for(String("/")), "http://localhost:4566/")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(SNSEndpointConfig())
    var fips = SNSEndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = SNSEndpointConfig(String("us-east-1"))
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
    var t = aws_signing_target(resolved, region, String("sns"))
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


def test_signed_create_topic() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /
    #
    #   content-type:application/x-www-form-urlencoded; charset=utf-8
    #   host:sns.us-west-2.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   01aaf026d0fad7056b617869c5cd6926cc11e38de05a1a06764069c39bd5dd24
    var built = build_create_topic_request(SNSCreateTopicInput(String("bounces")))
    assert_equal(built.body_text(), "Action=CreateTopic&Version=2010-03-31&Name=bounces")
    var req = _signed(built, _resolve(SNSEndpointConfig(String("us-west-2"))), String("us-west-2"))
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "sns.us-west-2.amazonaws.com")
    assert_equal(req.target, "/")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-west-2/sns/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=44be8eb4e1a4c4891b53b33cb72bd1db2968582247055910ec95ce5a282b3aff",
    )


def test_signed_get_topic_attributes_to_localstack() raises:
    # Canonical request:
    #   POST
    #   /
    #
    #   content-type:application/x-www-form-urlencoded; charset=utf-8
    #   host:localhost:4566
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   e30c41b3b4f1948ab20297366c9d2814134096068866eb2b1574c232e7af5389
    var built = build_get_topic_attributes_request(
        SNSGetTopicAttributesInput(String("arn:aws:sns:us-east-1:000000000000:bounces"))
    )
    var config = SNSEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var req = _signed(built, _resolve(config), String("us-east-1"))
    assert_equal(req.scheme, "http")
    assert_equal(req.host, "localhost")
    assert_equal(req.port, 4566)
    assert_equal(req.header("Host"), "localhost:4566")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/sns/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=a3781da64840c1f1aa99743d82d6aab1133bb036973810624957e7b3a958f689",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_create_topic()
    test_signed_get_topic_attributes_to_localstack()
    print("OK")
