# Where komira_aws_lambda sends a request, and the requests it signs.
#
# The endpoint comes from Lambda's published endpoint ruleset, embedded in
# the generated module and resolved over `LambdaEndpointConfig`. Rows: every
# case of botocore's lambda endpoint tests (read from the pinned archive at
# test time, never copied), resolved through every operation of the client,
# then the cases a caller depends on, by name: the regional default, FIPS,
# dual-stack, a custom endpoint (LocalStack), and the ruleset's refusals.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock and
# AWS's documented example credentials: Invoke of a function named by its
# ARN (each ':' percent-encoded in the path, and encoded again in the
# canonical path, as SigV4 does for every service but S3; the invocation
# type header signed) to us-east-1, and GetFunction with a qualifier to
# LocalStack. Their signatures were computed by an independent SigV4
# implementation (one that reproduces the signature AWS publishes for its
# IAM ListUsers SigV4 example) over the canonical requests stated beside
# them.
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
from komira_aws_lambda.komira_aws_lambda import (
    LambdaAddPermissionRequest,
    LambdaCreateFunctionRequest,
    LambdaCreateFunctionUrlConfigRequest,
    LambdaDeleteFunctionRequest,
    LambdaEndpointConfig,
    LambdaFunctionCode,
    LambdaGetFunctionRequest,
    LambdaGetFunctionUrlConfigRequest,
    LambdaInvocationRequest,
    LambdaPutFunctionConcurrencyRequest,
    LambdaUpdateFunctionCodeRequest,
    LambdaUpdateFunctionConfigurationRequest,
    LambdaUpdateFunctionUrlConfigRequest,
    build_get_function_request,
    build_invoke_request,
    komira_aws_lambda_endpoint_rules,
    resolve_add_permission_endpoint,
    resolve_create_function_endpoint,
    resolve_create_function_url_config_endpoint,
    resolve_delete_function_endpoint,
    resolve_get_function_endpoint,
    resolve_get_function_url_config_endpoint,
    resolve_invoke_endpoint,
    resolve_put_function_concurrency_endpoint,
    resolve_update_function_code_endpoint,
    resolve_update_function_configuration_endpoint,
    resolve_update_function_url_config_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/lambda/endpoint-tests-1.json"

# The case counts at the pinned botocore release: a shrunken file cannot
# pass as the suite.
comptime _EXPECTED_CASES = 71
comptime _EXPECTED_ERROR_CASES = 3

comptime _SERVICE = "lambda"


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


def _case_config(tc: JsonValue) raises -> LambdaEndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = LambdaEndpointConfig()
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
            raise Error("a case parameter the lambda config has no field for: " + name)
    return c^


def _resolve_all(rules: EndpointRuleSet, config: LambdaEndpointConfig) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one: Lambda binds no
    operation parameter, so each resolves the config alone."""
    var f = String("jobs")
    var got = resolve_invoke_endpoint(rules, config, LambdaInvocationRequest(f))
    var others = List[ResolvedEndpoint]()
    others.append(
        resolve_add_permission_endpoint(
            rules, config, LambdaAddPermissionRequest(f, String("s"), String("lambda:InvokeFunction"), String("*"))
        )
    )
    others.append(
        resolve_create_function_endpoint(
            rules, config, LambdaCreateFunctionRequest(f, String("arn:aws:iam::123456789012:role/r"), LambdaFunctionCode())
        )
    )
    others.append(
        resolve_create_function_url_config_endpoint(rules, config, LambdaCreateFunctionUrlConfigRequest(f, String("NONE")))
    )
    others.append(resolve_delete_function_endpoint(rules, config, LambdaDeleteFunctionRequest(f)))
    others.append(resolve_get_function_endpoint(rules, config, LambdaGetFunctionRequest(f)))
    others.append(resolve_get_function_url_config_endpoint(rules, config, LambdaGetFunctionUrlConfigRequest(f)))
    others.append(
        resolve_put_function_concurrency_endpoint(rules, config, LambdaPutFunctionConcurrencyRequest(f, Int32(1)))
    )
    others.append(resolve_update_function_code_endpoint(rules, config, LambdaUpdateFunctionCodeRequest(f)))
    others.append(
        resolve_update_function_configuration_endpoint(rules, config, LambdaUpdateFunctionConfigurationRequest(f))
    )
    others.append(resolve_update_function_url_config_endpoint(rules, config, LambdaUpdateFunctionUrlConfigRequest(f)))
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
    var rules = komira_aws_lambda_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged lambda endpoint cases")
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
        raise Error(String(failed) + " of " + String(n) + " lambda endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: LambdaEndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_lambda_endpoint_rules(), config)


def test_regional_default() raises:
    var got = _resolve(LambdaEndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://lambda.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String(_SERVICE))
    assert_equal(t.signing_name, "lambda")
    assert_equal(t.signing_region, "us-west-2")
    assert_equal(_resolve(LambdaEndpointConfig(String("cn-north-1"))).url, "https://lambda.cn-north-1.amazonaws.com.cn")


def test_fips_and_dual_stack() raises:
    var fips = LambdaEndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://lambda-fips.us-east-1.amazonaws.com")
    var dual = LambdaEndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://lambda.us-east-1.api.aws")
    var both = LambdaEndpointConfig(String("us-east-1"))
    both.use_fips = Optional[Bool](True)
    both.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(both).url, "https://lambda-fips.us-east-1.api.aws")


def test_custom_endpoint() raises:
    var config = LambdaEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String(_SERVICE))
    assert_equal(t.endpoint.host_header(), "localhost:4566")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(LambdaEndpointConfig())
    var fips = LambdaEndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = LambdaEndpointConfig(String("us-east-1"))
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


def test_signed_invoke_by_arn() raises:
    # Canonical request (hashed payload: SHA-256 of {"ping":true}):
    #   POST
    #   /2015-03-31/functions/arn%253Aaws%253Alambda%253Aus-east-1%253A123456789012%253Afunction%253Ajobs/invocations
    #
    #   content-type:application/octet-stream
    #   host:lambda.us-east-1.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #   x-amz-invocation-type:RequestResponse
    #
    #   content-type;host;x-amz-date;x-amz-invocation-type
    #   5b871adb197c8d0d5961b9c660416758a58ebd630603814a81a386fc0f4535e3
    var input = LambdaInvocationRequest(String("arn:aws:lambda:us-east-1:123456789012:function:jobs"))
    input.set_invocation_type(String("RequestResponse"))
    var payload = List[UInt8]()
    payload.extend(Span(String('{"ping":true}').as_bytes()))
    input.set_payload(payload^)
    var built = build_invoke_request(input)
    var req = _signed(built, _resolve(LambdaEndpointConfig(String("us-east-1"))), String("us-east-1"))
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "lambda.us-east-1.amazonaws.com")
    assert_equal(
        req.target,
        "/2015-03-31/functions/arn%3Aaws%3Alambda%3Aus-east-1%3A123456789012%3Afunction%3Ajobs/invocations",
    )
    assert_equal(req.header("X-Amz-Invocation-Type"), "RequestResponse")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/lambda/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date;x-amz-invocation-type, "
        + "Signature=94c8a8e9889c0558a3077953257db02854590225525a9d502af90a76f6e1919c",
    )


def test_signed_get_function_to_localstack() raises:
    # Canonical request (the empty payload's hash):
    #   GET
    #   /2015-03-31/functions/jobs
    #   Qualifier=live
    #   host:localhost:4566
    #   x-amz-date:20261001T000000Z
    #
    #   host;x-amz-date
    #   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    var input = LambdaGetFunctionRequest(String("jobs"))
    input.set_qualifier(String("live"))
    var built = build_get_function_request(input)
    var config = LambdaEndpointConfig(String("us-west-2"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var req = _signed(built, _resolve(config), String("us-west-2"))
    assert_equal(req.scheme, "http")
    assert_equal(req.port, 4566)
    assert_equal(req.target, "/2015-03-31/functions/jobs?Qualifier=live")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-west-2/lambda/aws4_request, "
        + "SignedHeaders=host;x-amz-date, "
        + "Signature=31d51fddc0bcd12546a373268c1656dcd6cadf4fa28fc16b422e749f6c354ab5",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_invoke_by_arn()
    test_signed_get_function_to_localstack()
    print("OK")
