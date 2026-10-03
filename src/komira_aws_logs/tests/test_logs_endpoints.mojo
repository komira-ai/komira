# Where komira_aws_logs sends GetLogEvents, and the request it signs.
#
# The endpoint comes from CloudWatch Logs' published endpoint ruleset,
# embedded in the generated module and resolved over
# `CloudWatchLogsEndpointConfig`. Rows: every case of botocore's logs
# endpoint tests (read from the pinned archive at test time, never
# copied), then the cases a caller of this library depends on, by name:
# the regional default, FIPS, dual-stack, a custom endpoint (LocalStack),
# and the ruleset's refusals.
#
# The signed row is the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock
# and AWS's documented example credentials. Its signature was computed by
# an independent SigV4 implementation (one that reproduces the signature
# AWS publishes for its IAM ListUsers SigV4 example) over the canonical
# request stated beside it.
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
from komira_aws_logs.komira_aws_logs import (
    CloudWatchLogsEndpointConfig,
    CloudWatchLogsGetLogEventsRequest,
    build_get_log_events_request,
    komira_aws_logs_endpoint_rules,
    resolve_get_log_events_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/logs/endpoint-tests-1.json"

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


def _case_config(tc: JsonValue) raises -> CloudWatchLogsEndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = CloudWatchLogsEndpointConfig()
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
            raise Error("a case parameter the logs config has no field for: " + name)
    return c^


def _check_case(rules: EndpointRuleSet, tc: JsonValue, mut why: String) raises -> Bool:
    var config = _case_config(tc)
    var input = CloudWatchLogsGetLogEventsRequest(String("stream"))
    ref expect = tc.children[_find(tc, "expect")]
    var ei = _find(expect, "endpoint")
    if ei >= 0:
        ref want = expect.children[ei]
        var url = want.children[_find(want, "url")].text
        try:
            var got = resolve_get_log_events_endpoint(rules, config, input)
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
                var t = aws_signing_target(got, region, String("logs"))
                if t.signing_name != "logs" or t.signing_region != region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region
                    return False
            else:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(got, String(""), String("logs"))
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
        var got = resolve_get_log_events_endpoint(rules, config, input)
        why = "endpoint " + got.url + ", expected the error '" + msg + "'"
        return False
    except e:
        if String(e).find(msg) < 0:
            why = "raised '" + String(e) + "', expected '" + msg + "'"
            return False
    return True


def test_botocore_endpoint_cases() raises:
    var rules = komira_aws_logs_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged logs endpoint cases")
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
        raise Error(String(failed) + " of " + String(n) + " logs endpoint cases failed:\n" + report)


# ---- the cases this library's callers depend on -------------------------------


def _resolve(config: CloudWatchLogsEndpointConfig) raises -> ResolvedEndpoint:
    return resolve_get_log_events_endpoint(
        komira_aws_logs_endpoint_rules(),
        config,
        CloudWatchLogsGetLogEventsRequest(String("s")),
    )


def test_regional_default() raises:
    var got = _resolve(CloudWatchLogsEndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://logs.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String("logs"))
    assert_equal(t.signing_name, "logs")
    assert_equal(t.signing_region, "us-west-2")
    assert_equal(t.endpoint.host_header(), "logs.us-west-2.amazonaws.com")
    var cn = _resolve(CloudWatchLogsEndpointConfig(String("cn-north-1")))
    assert_equal(cn.url, "https://logs.cn-north-1.amazonaws.com.cn")


def test_fips_and_dual_stack() raises:
    var fips = CloudWatchLogsEndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://logs-fips.us-east-1.amazonaws.com")
    var dual = CloudWatchLogsEndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://logs.us-east-1.api.aws")
    var both = CloudWatchLogsEndpointConfig(String("us-east-1"))
    both.use_fips = Optional[Bool](True)
    both.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(both).url, "https://logs-fips.us-east-1.api.aws")
    # GovCloud's FIPS endpoint is the plain regional host.
    var gov = CloudWatchLogsEndpointConfig(String("us-gov-west-1"))
    gov.use_fips = Optional[Bool](True)
    assert_equal(_resolve(gov).url, "https://logs.us-gov-west-1.amazonaws.com")


def test_custom_endpoint() raises:
    var config = CloudWatchLogsEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String("logs"))
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    assert_equal(t.signing_region, "us-east-1")
    assert_equal(
        t.endpoint.url_for(
            build_get_log_events_request(CloudWatchLogsGetLogEventsRequest(String("s"))).uri
        ),
        "http://localhost:4566/",
    )


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(CloudWatchLogsEndpointConfig())
    var fips = CloudWatchLogsEndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = CloudWatchLogsEndpointConfig(String("us-east-1"))
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
    var t = aws_signing_target(resolved, region, String("logs"))
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


def test_signed_get_log_events() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /
    #
    #   content-type:application/x-amz-json-1.1
    #   host:logs.us-east-1.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #   x-amz-target:Logs_20140328.GetLogEvents
    #
    #   content-type;host;x-amz-date;x-amz-target
    #   aa23e2e70adc49f31e6ecee1e61a7a488c5e404ef251367fca7f5915bf925da7
    var input = CloudWatchLogsGetLogEventsRequest(String("web/app/0123456789abcdef"))
    input.set_log_group_name(String("/ecs/web"))
    input.set_limit(Int32(200))
    input.set_start_from_head(True)
    var built = build_get_log_events_request(input)
    assert_equal(
        built.body_text(),
        '{"logGroupName":"/ecs/web","logStreamName":"web/app/0123456789abcdef",'
        + '"limit":200,"startFromHead":true}',
    )
    var resolved = _resolve(CloudWatchLogsEndpointConfig(String("us-east-1")))
    var req = _signed(built, resolved, String("us-east-1"))
    assert_equal(req.method, "POST")
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "logs.us-east-1.amazonaws.com")
    assert_equal(req.target, "/")
    assert_equal(req.header("X-Amz-Date"), "20261001T000000Z")
    assert_equal(req.header("X-Amz-Target"), "Logs_20140328.GetLogEvents")
    assert_equal(req.header("Content-Length"), String(len(built.body)))
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/logs/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date;x-amz-target, "
        + "Signature=239c73b6922b888b6080898258e8356e04f6f74b6ab82dcbbd5dc0e96709eac6",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_get_log_events()
    print("OK")
