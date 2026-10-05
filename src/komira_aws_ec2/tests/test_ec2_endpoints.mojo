# Where komira_aws_ec2 sends a request, and the requests it signs.
#
# The endpoint comes from EC2's published endpoint ruleset, embedded in the
# generated module and resolved over `EC2EndpointConfig`. Rows: every case
# of botocore's ec2 endpoint tests (read from the pinned archive at test
# time, never copied), resolved through every operation of the client and
# signed for the case's region, then the cases a caller depends on, by
# name: the regional default, FIPS, dual-stack, a custom endpoint
# (LocalStack), and the ruleset's refusals.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock and
# AWS's documented example credentials: DescribeInstances by tag to
# us-west-2 and TerminateInstances to LocalStack. Their signatures were
# computed by an independent SigV4 implementation (one that reproduces
# komira_aws_sqs's signed rows) over the canonical requests stated beside
# them.
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
from komira_aws_ec2.komira_aws_ec2 import (
    EC2AuthorizeSecurityGroupIngressRequest,
    EC2CancelSpotInstanceRequestsRequest,
    EC2CreateSecurityGroupRequest,
    EC2DeleteSecurityGroupRequest,
    EC2DescribeInstancesRequest,
    EC2DescribeSecurityGroupsRequest,
    EC2DescribeSpotInstanceRequestsRequest,
    EC2DescribeSubnetsRequest,
    EC2DescribeVpcsRequest,
    EC2EndpointConfig,
    EC2Filter,
    EC2RevokeSecurityGroupIngressRequest,
    EC2RunInstancesRequest,
    EC2TerminateInstancesRequest,
    build_describe_instances_request,
    build_terminate_instances_request,
    komira_aws_ec2_endpoint_rules,
    resolve_authorize_security_group_ingress_endpoint,
    resolve_cancel_spot_instance_requests_endpoint,
    resolve_create_security_group_endpoint,
    resolve_delete_security_group_endpoint,
    resolve_describe_instances_endpoint,
    resolve_describe_security_groups_endpoint,
    resolve_describe_spot_instance_requests_endpoint,
    resolve_describe_subnets_endpoint,
    resolve_describe_vpcs_endpoint,
    resolve_revoke_security_group_ingress_endpoint,
    resolve_run_instances_endpoint,
    resolve_terminate_instances_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/ec2/endpoint-tests-1.json"

# The case counts at the pinned botocore release: a shrunken file cannot
# pass as the suite.
comptime _EXPECTED_CASES = 54
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


def _case_config(tc: JsonValue) raises -> EC2EndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = EC2EndpointConfig()
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
            raise Error("a case parameter the ec2 config has no field for: " + name)
    return c^


def _ids(id: String) -> List[String]:
    var out = List[String]()
    out.append(id)
    return out^


def _resolve_all(rules: EndpointRuleSet, config: EC2EndpointConfig) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one: EC2 binds no
    operation parameter, so each resolves the config alone."""
    var got = resolve_describe_instances_endpoint(rules, config, EC2DescribeInstancesRequest())
    var others = List[ResolvedEndpoint]()
    others.append(
        resolve_authorize_security_group_ingress_endpoint(rules, config, EC2AuthorizeSecurityGroupIngressRequest())
    )
    others.append(
        resolve_cancel_spot_instance_requests_endpoint(
            rules, config, EC2CancelSpotInstanceRequestsRequest(_ids(String("sir-1")))
        )
    )
    others.append(
        resolve_create_security_group_endpoint(
            rules, config, EC2CreateSecurityGroupRequest(String("d"), String("g"))
        )
    )
    others.append(resolve_delete_security_group_endpoint(rules, config, EC2DeleteSecurityGroupRequest()))
    others.append(resolve_describe_security_groups_endpoint(rules, config, EC2DescribeSecurityGroupsRequest()))
    others.append(
        resolve_describe_spot_instance_requests_endpoint(rules, config, EC2DescribeSpotInstanceRequestsRequest())
    )
    others.append(resolve_describe_subnets_endpoint(rules, config, EC2DescribeSubnetsRequest()))
    others.append(resolve_describe_vpcs_endpoint(rules, config, EC2DescribeVpcsRequest()))
    others.append(
        resolve_revoke_security_group_ingress_endpoint(rules, config, EC2RevokeSecurityGroupIngressRequest())
    )
    others.append(resolve_run_instances_endpoint(rules, config, EC2RunInstancesRequest(Int32(1), Int32(1))))
    others.append(
        resolve_terminate_instances_endpoint(rules, config, EC2TerminateInstancesRequest(_ids(String("i-1"))))
    )
    for i in range(len(others)):
        if others[i].url != got.url:
            raise Error("operations disagree: " + others[i].url + " and " + got.url)
        if not _json_equal(others[i].properties, got.properties):
            raise Error("operations disagree on the properties of " + got.url)
    return got^


def _case_signing_region(want: JsonValue, config: EC2EndpointConfig) -> String:
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
                var t = aws_signing_target(got, caller, String("ec2"))
                if t.signing_name != "ec2" or t.signing_region != region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region + ", expected ec2/" + region
                    return False
            else:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(got, String(""), String("ec2"))
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
    var rules = komira_aws_ec2_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged ec2 endpoint cases")
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
        raise Error(String(failed) + " of " + String(n) + " ec2 endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: EC2EndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_ec2_endpoint_rules(), config)


def test_regional_default() raises:
    var got = _resolve(EC2EndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://ec2.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String("ec2"))
    assert_equal(t.signing_name, "ec2")
    assert_equal(t.signing_region, "us-west-2")
    assert_equal(_resolve(EC2EndpointConfig(String("cn-north-1"))).url, "https://ec2.cn-north-1.amazonaws.com.cn")
    assert_equal(_resolve(EC2EndpointConfig(String("us-gov-west-1"))).url, "https://ec2.us-gov-west-1.amazonaws.com")


def test_fips_and_dual_stack() raises:
    var fips = EC2EndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://ec2-fips.us-east-1.amazonaws.com")
    var dual = EC2EndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://ec2.us-east-1.api.aws")
    var both = EC2EndpointConfig(String("us-east-1"))
    both.use_fips = Optional[Bool](True)
    both.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(both).url, "https://ec2-fips.us-east-1.api.aws")


def test_custom_endpoint() raises:
    var config = EC2EndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String("ec2"))
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    assert_equal(t.endpoint.url_for(String("/")), "http://localhost:4566/")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(EC2EndpointConfig())
    var fips = EC2EndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = EC2EndpointConfig(String("us-east-1"))
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
    var t = aws_signing_target(resolved, region, String("ec2"))
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


def test_signed_describe_instances() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /
    #
    #   content-type:application/x-www-form-urlencoded; charset=utf-8
    #   host:ec2.us-west-2.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   6e11cf05a7f72249c48c847c5a2fb60693ca7bd86fce537d7cc28e9374127ad6
    var input = EC2DescribeInstancesRequest()
    var f = EC2Filter()
    f.set_name(String("tag:komira-placement"))
    f.set_values(_ids(String("p-1")))
    var filters = List[EC2Filter]()
    filters.append(f^)
    input.set_filters(filters^)
    var built = build_describe_instances_request(input)
    assert_equal(
        built.body_text(),
        "Action=DescribeInstances&Version=2016-11-15&Filter.1.Name=tag%3Akomira-placement&Filter.1.Value.1=p-1",
    )
    var req = _signed(built, _resolve(EC2EndpointConfig(String("us-west-2"))), String("us-west-2"))
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "ec2.us-west-2.amazonaws.com")
    assert_equal(req.target, "/")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-west-2/ec2/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=84027a8231276f2fa287b5e09d6852a790d0315f4b7afab0c55090318c77d04c",
    )


def test_signed_terminate_instances_to_localstack() raises:
    # Canonical request:
    #   POST
    #   /
    #
    #   content-type:application/x-www-form-urlencoded; charset=utf-8
    #   host:localhost:4566
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   26bbf2cb3801c8bd7b54f29d347222ea5664bc2eee394d2f5a2c49c8a053eb06
    var built = build_terminate_instances_request(EC2TerminateInstancesRequest(_ids(String("i-0123456789abcdef0"))))
    var config = EC2EndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var req = _signed(built, _resolve(config), String("us-east-1"))
    assert_equal(req.scheme, "http")
    assert_equal(req.host, "localhost")
    assert_equal(req.port, 4566)
    assert_equal(req.header("Host"), "localhost:4566")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/ec2/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=ba18c402755544545a82489b52cb3e82636aaa32ecb8ed831352acfef14633c4",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_describe_instances()
    test_signed_terminate_instances_to_localstack()
    print("OK")
