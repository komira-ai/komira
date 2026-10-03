# Where komira_aws_sqs sends a request, and the requests it signs.
#
# The endpoint comes from SQS's published endpoint ruleset, embedded in the
# generated module and resolved over `SQSEndpointConfig`. Rows: every case
# of botocore's sqs endpoint tests (read from the pinned archive at test
# time, never copied), resolved through every operation of the client,
# then the cases a caller depends on, by name: the regional default, FIPS,
# dual-stack, a custom endpoint (LocalStack), and the ruleset's refusals.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock and
# AWS's documented example credentials: ReceiveMessage to LocalStack and
# DeleteMessage to us-west-2. Their signatures were computed by an
# independent SigV4 implementation (one that reproduces the signature AWS
# publishes for its IAM ListUsers SigV4 example) over the canonical
# requests stated beside them. `x-amzn-query-mode` is signed, as every
# operation header is.
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
from komira_aws_sqs.komira_aws_sqs import (
    SQSCreateQueueRequest,
    SQSDeleteMessageRequest,
    SQSDeleteQueueRequest,
    SQSEndpointConfig,
    SQSGetQueueAttributesRequest,
    SQSGetQueueUrlRequest,
    SQSReceiveMessageRequest,
    SQSSetQueueAttributesRequest,
    build_delete_message_request,
    build_receive_message_request,
    komira_aws_sqs_endpoint_rules,
    resolve_create_queue_endpoint,
    resolve_delete_message_endpoint,
    resolve_delete_queue_endpoint,
    resolve_get_queue_attributes_endpoint,
    resolve_get_queue_url_endpoint,
    resolve_receive_message_endpoint,
    resolve_set_queue_attributes_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/sqs/endpoint-tests-1.json"

# The case counts at the pinned botocore release: a shrunken file cannot
# pass as the suite.
comptime _EXPECTED_CASES = 48
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


def _case_config(tc: JsonValue) raises -> SQSEndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = SQSEndpointConfig()
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
            raise Error("a case parameter the sqs config has no field for: " + name)
    return c^


comptime _Q = "https://sqs.us-east-1.amazonaws.com/123456789012/jobs"


def _resolve_all(rules: EndpointRuleSet, config: SQSEndpointConfig) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one: SQS binds no
    operation parameter, so each resolves the config alone."""
    var got = resolve_receive_message_endpoint(rules, config, SQSReceiveMessageRequest(String(_Q)))
    var others = List[ResolvedEndpoint]()
    others.append(resolve_create_queue_endpoint(rules, config, SQSCreateQueueRequest(String("jobs"))))
    others.append(resolve_delete_message_endpoint(rules, config, SQSDeleteMessageRequest(String(_Q), String("h"))))
    others.append(resolve_delete_queue_endpoint(rules, config, SQSDeleteQueueRequest(String(_Q))))
    others.append(resolve_get_queue_attributes_endpoint(rules, config, SQSGetQueueAttributesRequest(String(_Q))))
    others.append(resolve_get_queue_url_endpoint(rules, config, SQSGetQueueUrlRequest(String("jobs"))))
    others.append(
        resolve_set_queue_attributes_endpoint(
            rules, config, SQSSetQueueAttributesRequest(String(_Q), Dict[String, String]())
        )
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
                var t = aws_signing_target(got, region, String("sqs"))
                if t.signing_name != "sqs" or t.signing_region != region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region
                    return False
            else:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(got, String(""), String("sqs"))
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
    var rules = komira_aws_sqs_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged sqs endpoint cases")
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
        raise Error(String(failed) + " of " + String(n) + " sqs endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: SQSEndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_sqs_endpoint_rules(), config)


def test_regional_default() raises:
    var got = _resolve(SQSEndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://sqs.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String("sqs"))
    assert_equal(t.signing_name, "sqs")
    assert_equal(t.signing_region, "us-west-2")
    assert_equal(_resolve(SQSEndpointConfig(String("cn-north-1"))).url, "https://sqs.cn-north-1.amazonaws.com.cn")


def test_fips_and_dual_stack() raises:
    var fips = SQSEndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://sqs-fips.us-east-1.amazonaws.com")
    var dual = SQSEndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://sqs.us-east-1.api.aws")
    # In GovCloud the FIPS endpoint is the plain regional host.
    var gov = SQSEndpointConfig(String("us-gov-west-1"))
    gov.use_fips = Optional[Bool](True)
    assert_equal(_resolve(gov).url, "https://sqs.us-gov-west-1.amazonaws.com")


def test_custom_endpoint() raises:
    var config = SQSEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String("sqs"))
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    assert_equal(t.endpoint.url_for(String("/")), "http://localhost:4566/")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(SQSEndpointConfig())
    var fips = SQSEndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = SQSEndpointConfig(String("us-east-1"))
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
    var t = aws_signing_target(resolved, region, String("sqs"))
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


def test_signed_receive_message_to_localstack() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /
    #
    #   content-type:application/x-amz-json-1.0
    #   host:localhost:4566
    #   x-amz-date:20261001T000000Z
    #   x-amz-target:AmazonSQS.ReceiveMessage
    #   x-amzn-query-mode:true
    #
    #   content-type;host;x-amz-date;x-amz-target;x-amzn-query-mode
    #   2dacd79460172b2c1010c71e0cc598bbea93ca4601d007a4aad041bca1e21d6c
    var input = SQSReceiveMessageRequest(
        String("http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/jobs")
    )
    input.set_max_number_of_messages(Int32(10))
    input.set_wait_time_seconds(Int32(20))
    var built = build_receive_message_request(input)
    assert_equal(
        built.body_text(),
        '{"QueueUrl":"http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/jobs",'
        + '"MaxNumberOfMessages":10,"WaitTimeSeconds":20}',
    )
    var config = SQSEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var req = _signed(built, _resolve(config), String("us-east-1"))
    assert_equal(req.scheme, "http")
    assert_equal(req.host, "localhost")
    assert_equal(req.port, 4566)
    assert_equal(req.target, "/")
    assert_equal(req.header("Host"), "localhost:4566")
    assert_equal(req.header("x-amzn-query-mode"), "true")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/sqs/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date;x-amz-target;x-amzn-query-mode, "
        + "Signature=4c75d07b9a2271219fd331e78b453b716213574a9cefd62c4d6ebfc65c2301f3",
    )


def test_signed_delete_message() raises:
    # Canonical request:
    #   POST
    #   /
    #
    #   content-type:application/x-amz-json-1.0
    #   host:sqs.us-west-2.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #   x-amz-target:AmazonSQS.DeleteMessage
    #   x-amzn-query-mode:true
    #
    #   content-type;host;x-amz-date;x-amz-target;x-amzn-query-mode
    #   1a3ddd4844e82725c6f8a51c111adcdcaa5ce209241aeb17f4de2a2346c08061
    var built = build_delete_message_request(
        SQSDeleteMessageRequest(
            String("https://sqs.us-west-2.amazonaws.com/123456789012/jobs"),
            String("AQEBexample+receipt/handle=="),
        )
    )
    var req = _signed(built, _resolve(SQSEndpointConfig(String("us-west-2"))), String("us-west-2"))
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "sqs.us-west-2.amazonaws.com")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-west-2/sqs/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date;x-amz-target;x-amzn-query-mode, "
        + "Signature=7b07658a49b157fc8009460b2c923247e86a10fe1ce6d85ef20b76fbf428cca6",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_receive_message_to_localstack()
    test_signed_delete_message()
    print("OK")
