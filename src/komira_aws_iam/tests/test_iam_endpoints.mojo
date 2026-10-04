# Where komira_aws_iam sends a request, and the requests it signs.
#
# IAM is a global service: in the aws partition every region resolves to
# https://iam.amazonaws.com, and the ruleset's `authSchemes` says to sign
# for us-east-1 whatever region the caller is in (cn-north-1 in China, the
# region itself in GovCloud and the isolated partitions). The endpoint
# comes from IAM's published endpoint ruleset, embedded in the generated
# module and resolved over `IAMEndpointConfig`. Rows: every case of
# botocore's iam endpoint tests (read from the pinned archive at test time,
# never copied), resolved through every operation of the client, and its
# signing region and name checked against the case's `authSchemes`; then
# the cases a caller depends on, by name: a regional caller sent to the
# global endpoint and signing for us-east-1, FIPS, dual-stack, a custom
# endpoint (LocalStack), and the ruleset's refusals.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock and
# AWS's documented example credentials: CreateUser from eu-west-1 (to
# iam.amazonaws.com, signed for us-east-1) and GetRole to LocalStack. Their
# signatures were computed by an independent SigV4 implementation (one that
# reproduces komira_aws_sqs's signed rows) over the canonical requests
# stated beside them.
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
from komira_aws_iam.komira_aws_iam import (
    IAMAddClientIDToOpenIDConnectProviderRequest,
    IAMCreateAccessKeyRequest,
    IAMCreateRoleRequest,
    IAMCreateUserRequest,
    IAMDeleteRolePolicyRequest,
    IAMDeleteRoleRequest,
    IAMEndpointConfig,
    IAMGetOpenIDConnectProviderRequest,
    IAMGetRolePolicyRequest,
    IAMGetRoleRequest,
    IAMListRolePoliciesRequest,
    IAMPutRolePolicyRequest,
    IAMPutUserPolicyRequest,
    IAMRemoveClientIDFromOpenIDConnectProviderRequest,
    IAMTag,
    IAMTagRoleRequest,
    IAMUpdateAssumeRolePolicyRequest,
    build_create_user_request,
    build_get_role_request,
    komira_aws_iam_endpoint_rules,
    resolve_add_client_id_to_open_id_connect_provider_endpoint,
    resolve_create_access_key_endpoint,
    resolve_create_role_endpoint,
    resolve_create_user_endpoint,
    resolve_delete_role_endpoint,
    resolve_delete_role_policy_endpoint,
    resolve_get_open_id_connect_provider_endpoint,
    resolve_get_role_endpoint,
    resolve_get_role_policy_endpoint,
    resolve_list_role_policies_endpoint,
    resolve_put_role_policy_endpoint,
    resolve_put_user_policy_endpoint,
    resolve_remove_client_id_from_open_id_connect_provider_endpoint,
    resolve_tag_role_endpoint,
    resolve_update_assume_role_policy_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/iam/endpoint-tests-1.json"

# The case counts at the pinned botocore release: a shrunken file cannot
# pass as the suite.
comptime _EXPECTED_CASES = 26
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


def _case_config(tc: JsonValue) raises -> IAMEndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = IAMEndpointConfig()
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
            raise Error("a case parameter the iam config has no field for: " + name)
    return c^


comptime _ROLE = "deploy"
comptime _OIDC = "arn:aws:iam::123456789012:oidc-provider/token.actions.example.com"


def _resolve_all(rules: EndpointRuleSet, config: IAMEndpointConfig) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one: IAM binds no
    operation parameter, so each resolves the config alone."""
    var got = resolve_get_role_endpoint(rules, config, IAMGetRoleRequest(String(_ROLE)))
    var others = List[ResolvedEndpoint]()
    others.append(
        resolve_add_client_id_to_open_id_connect_provider_endpoint(
            rules, config, IAMAddClientIDToOpenIDConnectProviderRequest(String(_OIDC), String("a"))
        )
    )
    others.append(resolve_create_access_key_endpoint(rules, config, IAMCreateAccessKeyRequest()))
    others.append(
        resolve_create_role_endpoint(rules, config, IAMCreateRoleRequest(String(_ROLE), String("{}")))
    )
    others.append(resolve_create_user_endpoint(rules, config, IAMCreateUserRequest(String("u"))))
    others.append(resolve_delete_role_endpoint(rules, config, IAMDeleteRoleRequest(String(_ROLE))))
    others.append(
        resolve_delete_role_policy_endpoint(rules, config, IAMDeleteRolePolicyRequest(String(_ROLE), String("p")))
    )
    others.append(
        resolve_get_open_id_connect_provider_endpoint(
            rules, config, IAMGetOpenIDConnectProviderRequest(String(_OIDC))
        )
    )
    others.append(
        resolve_get_role_policy_endpoint(rules, config, IAMGetRolePolicyRequest(String(_ROLE), String("p")))
    )
    others.append(resolve_list_role_policies_endpoint(rules, config, IAMListRolePoliciesRequest(String(_ROLE))))
    others.append(
        resolve_put_role_policy_endpoint(
            rules, config, IAMPutRolePolicyRequest(String(_ROLE), String("p"), String("{}"))
        )
    )
    others.append(
        resolve_put_user_policy_endpoint(
            rules, config, IAMPutUserPolicyRequest(String("u"), String("p"), String("{}"))
        )
    )
    others.append(
        resolve_remove_client_id_from_open_id_connect_provider_endpoint(
            rules, config, IAMRemoveClientIDFromOpenIDConnectProviderRequest(String(_OIDC), String("a"))
        )
    )
    others.append(
        resolve_tag_role_endpoint(rules, config, IAMTagRoleRequest(String(_ROLE), List[IAMTag]()))
    )
    others.append(
        resolve_update_assume_role_policy_endpoint(
            rules, config, IAMUpdateAssumeRolePolicyRequest(String(_ROLE), String("{}"))
        )
    )
    for i in range(len(others)):
        if others[i].url != got.url:
            raise Error("operations disagree: " + others[i].url + " and " + got.url)
        if not _json_equal(others[i].properties, got.properties):
            raise Error("operations disagree on the properties of " + got.url)
    return got^


def _case_signing_region(want: JsonValue, config: IAMEndpointConfig) -> String:
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
                var t = aws_signing_target(got, caller, String("iam"))
                if t.signing_name != "iam" or t.signing_region != region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region + ", expected iam/" + region
                    return False
            else:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(got, String(""), String("iam"))
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
    var rules = komira_aws_iam_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged iam endpoint cases")
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
        raise Error(String(failed) + " of " + String(n) + " iam endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: IAMEndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_iam_endpoint_rules(), config)


def test_a_regional_caller_signs_for_us_east_1() raises:
    # Not among botocore's cases: a caller in eu-west-1 (or any aws-partition
    # region) reaches the one global endpoint, signed for us-east-1.
    for region in ["eu-west-1", "us-west-2", "ap-southeast-2", "aws-global"]:
        var got = _resolve(IAMEndpointConfig(String(region)))
        assert_equal(got.url, "https://iam.amazonaws.com")
        var t = aws_signing_target(got, String(region), String("iam"))
        assert_equal(t.signing_name, "iam")
        assert_equal(t.signing_region, "us-east-1")
        assert_equal(t.endpoint.host_header(), "iam.amazonaws.com")
    # In China the global endpoint is in cn-north-1, and signs for it.
    var cn = _resolve(IAMEndpointConfig(String("cn-north-1")))
    assert_equal(cn.url, "https://iam.cn-north-1.amazonaws.com.cn")
    assert_equal(aws_signing_target(cn, String("cn-north-1"), String("iam")).signing_region, "cn-north-1")


def test_fips_and_dual_stack() raises:
    var fips = IAMEndpointConfig(String("eu-west-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://iam-fips.amazonaws.com")
    var dual = IAMEndpointConfig(String("eu-west-1"))
    dual.use_dual_stack = Optional[Bool](True)
    var got = _resolve(dual)
    assert_equal(got.url, "https://iam.global.api.aws")
    assert_equal(aws_signing_target(got, String("eu-west-1"), String("iam")).signing_region, "us-east-1")


def test_custom_endpoint() raises:
    var config = IAMEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String("iam"))
    assert_equal(t.signing_region, "us-east-1")
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    assert_equal(t.endpoint.url_for(String("/")), "http://localhost:4566/")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(IAMEndpointConfig())
    var fips = IAMEndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = IAMEndpointConfig(String("us-east-1"))
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
    var t = aws_signing_target(resolved, region, String("iam"))
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


def test_signed_create_user_from_eu_west_1() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /
    #
    #   content-type:application/x-www-form-urlencoded; charset=utf-8
    #   host:iam.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   7eaac55cab6948f9f266285455ef401f9779ca70f499eb61654bfb4a7de2c13b
    # Scope: 20261001/us-east-1/iam/aws4_request.
    var built = build_create_user_request(IAMCreateUserRequest(String("smtp-relay")))
    assert_equal(built.body_text(), "Action=CreateUser&Version=2010-05-08&UserName=smtp-relay")
    var req = _signed(built, _resolve(IAMEndpointConfig(String("eu-west-1"))), String("eu-west-1"))
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "iam.amazonaws.com")
    assert_equal(req.target, "/")
    assert_equal(req.header("Host"), "iam.amazonaws.com")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/iam/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=a0a2bd060ebf1fe300579cbb0f24e324f7a95e7f1ecc135f7db474de645b82a3",
    )


def test_signed_get_role_to_localstack() raises:
    # Canonical request:
    #   POST
    #   /
    #
    #   content-type:application/x-www-form-urlencoded; charset=utf-8
    #   host:localhost:4566
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   0f9169ca531d4af8f5167cfb4d5ac7759efb311e304dc25aaffcd9a786c0c851
    var built = build_get_role_request(IAMGetRoleRequest(String("deploy")))
    var config = IAMEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var req = _signed(built, _resolve(config), String("us-east-1"))
    assert_equal(req.scheme, "http")
    assert_equal(req.host, "localhost")
    assert_equal(req.port, 4566)
    assert_equal(req.header("Host"), "localhost:4566")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/iam/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=36a98b705dad99e7b0563aaec47a9bef9f8f4ef8eaefcedbc9a0323ad423545a",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_a_regional_caller_signs_for_us_east_1()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_create_user_from_eu_west_1()
    test_signed_get_role_to_localstack()
    print("OK")
