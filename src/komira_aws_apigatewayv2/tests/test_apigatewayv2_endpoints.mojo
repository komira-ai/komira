# Where komira_aws_apigatewayv2 sends a request, and the requests it signs.
#
# The endpoint comes from API Gateway v2's published endpoint ruleset,
# embedded in the generated module and resolved over
# `ApiGatewayV2EndpointConfig`. Rows: every case of botocore's apigatewayv2
# endpoint tests (read from the pinned archive at test time, never copied),
# resolved through every operation of the client, then the cases a caller
# depends on, by name: the regional default (host `apigateway.<region>`,
# signing name `apigateway`, the v1 names the v2 API is served and signed
# under), FIPS, dual-stack, a custom endpoint (LocalStack), and the
# ruleset's refusals.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock and
# AWS's documented example credentials: CreateApi to us-east-1 and GetRoutes
# with a query (a page token whose `/` and `=` are percent-encoded, and the
# query sorted by name) to LocalStack. Their signatures were computed by an
# independent SigV4 implementation (one that reproduces the signature AWS
# publishes for its IAM ListUsers SigV4 example) over the canonical
# requests stated beside them.
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
from komira_aws_apigatewayv2.komira_aws_apigatewayv2 import (
    ApiGatewayV2CreateApiRequest,
    ApiGatewayV2CreateAuthorizerRequest,
    ApiGatewayV2CreateIntegrationRequest,
    ApiGatewayV2CreateRouteRequest,
    ApiGatewayV2CreateStageRequest,
    ApiGatewayV2DeleteApiRequest,
    ApiGatewayV2EndpointConfig,
    ApiGatewayV2GetApiRequest,
    ApiGatewayV2GetApisRequest,
    ApiGatewayV2GetAuthorizersRequest,
    ApiGatewayV2GetIntegrationsRequest,
    ApiGatewayV2GetRoutesRequest,
    ApiGatewayV2GetStagesRequest,
    ApiGatewayV2UpdateApiRequest,
    ApiGatewayV2UpdateAuthorizerRequest,
    build_create_api_request,
    build_get_routes_request,
    komira_aws_apigatewayv2_endpoint_rules,
    resolve_create_api_endpoint,
    resolve_create_authorizer_endpoint,
    resolve_create_integration_endpoint,
    resolve_create_route_endpoint,
    resolve_create_stage_endpoint,
    resolve_delete_api_endpoint,
    resolve_get_api_endpoint,
    resolve_get_apis_endpoint,
    resolve_get_authorizers_endpoint,
    resolve_get_integrations_endpoint,
    resolve_get_routes_endpoint,
    resolve_get_stages_endpoint,
    resolve_update_api_endpoint,
    resolve_update_authorizer_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/apigatewayv2/endpoint-tests-1.json"

# The case counts at the pinned botocore release: a shrunken file cannot
# pass as the suite.
comptime _EXPECTED_CASES = 43
comptime _EXPECTED_ERROR_CASES = 3

comptime _SERVICE = "apigateway"


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


def _case_config(tc: JsonValue) raises -> ApiGatewayV2EndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = ApiGatewayV2EndpointConfig()
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
            raise Error("a case parameter the apigatewayv2 config has no field for: " + name)
    return c^


def _resolve_all(rules: EndpointRuleSet, config: ApiGatewayV2EndpointConfig) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one: the service binds
    no operation parameter, so each resolves the config alone."""
    var a = String("a1b2c3d4e5")
    var got = resolve_get_apis_endpoint(rules, config, ApiGatewayV2GetApisRequest())
    var others = List[ResolvedEndpoint]()
    others.append(resolve_create_api_endpoint(rules, config, ApiGatewayV2CreateApiRequest(String("n"), String("HTTP"))))
    others.append(
        resolve_create_authorizer_endpoint(
            rules, config, ApiGatewayV2CreateAuthorizerRequest(a, String("REQUEST"), List[String](), String("n"))
        )
    )
    others.append(
        resolve_create_integration_endpoint(rules, config, ApiGatewayV2CreateIntegrationRequest(a, String("AWS_PROXY")))
    )
    others.append(resolve_create_route_endpoint(rules, config, ApiGatewayV2CreateRouteRequest(a, String("$default"))))
    others.append(resolve_create_stage_endpoint(rules, config, ApiGatewayV2CreateStageRequest(a, String("$default"))))
    others.append(resolve_delete_api_endpoint(rules, config, ApiGatewayV2DeleteApiRequest(a)))
    others.append(resolve_get_api_endpoint(rules, config, ApiGatewayV2GetApiRequest(a)))
    others.append(resolve_get_authorizers_endpoint(rules, config, ApiGatewayV2GetAuthorizersRequest(a)))
    others.append(resolve_get_integrations_endpoint(rules, config, ApiGatewayV2GetIntegrationsRequest(a)))
    others.append(resolve_get_routes_endpoint(rules, config, ApiGatewayV2GetRoutesRequest(a)))
    others.append(resolve_get_stages_endpoint(rules, config, ApiGatewayV2GetStagesRequest(a)))
    others.append(resolve_update_api_endpoint(rules, config, ApiGatewayV2UpdateApiRequest(a)))
    others.append(
        resolve_update_authorizer_endpoint(rules, config, ApiGatewayV2UpdateAuthorizerRequest(a, String("auth01")))
    )
    for i in range(len(others)):
        if others[i].url != got.url:
            raise Error("operations disagree: " + others[i].url + " and " + got.url)
    return got^


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
            if config.region:
                var region = config.region.value()
                var t = aws_signing_target(got, region, String(_SERVICE))
                if t.signing_name != _SERVICE or t.signing_region != region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region
                    return False
            else:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(got, String(""), String(_SERVICE))
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
    var rules = komira_aws_apigatewayv2_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged apigatewayv2 endpoint cases")
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
        raise Error(String(failed) + " of " + String(n) + " apigatewayv2 endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: ApiGatewayV2EndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_apigatewayv2_endpoint_rules(), config)


def test_regional_default() raises:
    var got = _resolve(ApiGatewayV2EndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://apigateway.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String(_SERVICE))
    assert_equal(t.signing_name, "apigateway")
    assert_equal(t.signing_region, "us-west-2")
    assert_equal(
        _resolve(ApiGatewayV2EndpointConfig(String("cn-north-1"))).url,
        "https://apigateway.cn-north-1.amazonaws.com.cn",
    )


def test_fips_and_dual_stack() raises:
    var fips = ApiGatewayV2EndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://apigateway-fips.us-east-1.amazonaws.com")
    var dual = ApiGatewayV2EndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://apigateway.us-east-1.api.aws")


def test_custom_endpoint() raises:
    var config = ApiGatewayV2EndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String(_SERVICE))
    assert_equal(t.endpoint.host_header(), "localhost:4566")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(ApiGatewayV2EndpointConfig())
    var fips = ApiGatewayV2EndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = ApiGatewayV2EndpointConfig(String("us-east-1"))
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
    var t = aws_signing_target(resolved, region, String(_SERVICE))
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


def test_signed_create_api() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /v2/apis
    #
    #   content-type:application/json
    #   host:apigateway.us-east-1.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   e56f8c6222ea5af753e58e6280f4cb245b1991e6cd520a32d3fcc21fc71a5589
    var input = ApiGatewayV2CreateApiRequest(String("jobs-edge"), String("HTTP"))
    input.set_description(String("front door"))
    var built = build_create_api_request(input)
    assert_equal(built.body_text(), '{"description":"front door","name":"jobs-edge","protocolType":"HTTP"}')
    var req = _signed(built, _resolve(ApiGatewayV2EndpointConfig(String("us-east-1"))), String("us-east-1"))
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "apigateway.us-east-1.amazonaws.com")
    assert_equal(req.target, "/v2/apis")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/apigateway/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=a77a85715230309173346ae62813795535c116464ed09d9fdfd189e1172a724d",
    )


def test_signed_get_routes_page_to_localstack() raises:
    # Canonical request (the empty payload's hash):
    #   GET
    #   /v2/apis/a1b2c3d4e5/routes
    #   maxResults=25&nextToken=tok%2F2%3D%3D
    #   host:localhost:4566
    #   x-amz-date:20261001T000000Z
    #
    #   host;x-amz-date
    #   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    var input = ApiGatewayV2GetRoutesRequest(String("a1b2c3d4e5"))
    input.set_next_token(String("tok/2=="))
    input.set_max_results(String("25"))
    var built = build_get_routes_request(input)
    var config = ApiGatewayV2EndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var req = _signed(built, _resolve(config), String("us-east-1"))
    assert_equal(req.scheme, "http")
    assert_equal(req.target, "/v2/apis/a1b2c3d4e5/routes?maxResults=25&nextToken=tok%2F2%3D%3D")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/apigateway/aws4_request, "
        + "SignedHeaders=host;x-amz-date, "
        + "Signature=acb478ff541de85df8454c7911e66676cef8172cf5c0ad618f6aed154778cc5a",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_create_api()
    test_signed_get_routes_page_to_localstack()
    print("OK")
