# The package's CloudWatch facts, checked against the CloudWatch model and
# endpoint tests in the pinned botocore archive (staged by BUCK, read here
# at test time, never copied).
#
# From the model: the signing name and endpoint prefix, the awsJson target
# prefix and version, the protocols list in order (the AWS generator
# chooses its first supported entry, `json`, the protocol this package
# speaks), the `awsQueryCompatible` trait
# behind the query-mode header, the operation's method and path, the
# dimension cap, the MaxDatapoints default, the accepted periods, the
# ScanBy values, and that a point is stamped with its period's START and
# that StartTime is inclusive and EndTime exclusive.
#
# From the endpoint tests: every case without a custom `Endpoint` and
# without FIPS resolves through komira_aws_core's generic
# `aws_service_endpoint` (dual-stack or not) to the URL the ruleset gives,
# and every such error case is refused by it. FIPS cases are left out on
# purpose: in aws-us-gov the CloudWatch ruleset answers FIPS with the plain
# `monitoring.` host, which the generic `-fips` form gets wrong, so this
# package offers no FIPS endpoint (BUCK says so).
#
# A botocore bump that changes any of these fails the build here.

from std.testing import assert_equal, assert_true

from komira_aws_core import AwsEndpoint, aws_service_endpoint
from komira_aws_metrics import (
    CLOUDWATCH_JSON_CONTENT_TYPE,
    CLOUDWATCH_MAX_DIMENSIONS,
    CLOUDWATCH_SIGNING_NAME,
    GET_METRIC_DATA_MAX_DATAPOINTS,
    GET_METRIC_DATA_TARGET,
    cloudwatch_endpoint,
    cloudwatch_period_ok,
)
from komira_json import JsonValue, parse_json_value


comptime _MODEL = "cloudwatch/2010-08-01/service-2.json"
comptime _CASES = "tests/functional/endpoint-rules/cloudwatch/endpoint-tests-1.json"

# The case count at the pinned botocore release: a shrunken file cannot pass
# as the suite.
comptime _EXPECTED_CASES = 26


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _model() raises -> JsonValue:
    return parse_json_value(_read(_MODEL))


def _shape(model: JsonValue, name: String) raises -> JsonValue:
    return model.get(String("shapes")).get(name)


def _doc(model: JsonValue, shape: String, member: String) raises -> String:
    return (
        _shape(model, shape)
        .get(String("members"))
        .get(member)
        .get(String("documentation"))
        .as_string()
    )


def _strings(v: JsonValue) raises -> List[String]:
    var out = List[String]()
    for i in range(v.array_len()):
        out.append(v.element_at(i).as_string())
    return out^


def _has(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def test_service_metadata() raises:
    var meta = _model().get(String("metadata"))
    assert_equal(meta.get(String("endpointPrefix")).as_string(), String(CLOUDWATCH_SIGNING_NAME))
    if meta.has(String("signingName")):
        assert_equal(meta.get(String("signingName")).as_string(), String(CLOUDWATCH_SIGNING_NAME))
    assert_equal(
        meta.get(String("targetPrefix")).as_string() + String(".GetMetricData"),
        String(GET_METRIC_DATA_TARGET),
    )
    assert_equal(
        String("application/x-amz-json-") + meta.get(String("jsonVersion")).as_string(),
        String(CLOUDWATCH_JSON_CONTENT_TYPE),
    )
    # The declared protocol is CBOR; the AWS generator chooses the first
    # entry of `protocols` it supports, which is `json`, the protocol this
    # package speaks. Generating the client into this package is a
    # follow-up. The choice depends on the list's order, so the order is
    # pinned.
    assert_equal(meta.get(String("protocol")).as_string(), String("smithy-rpc-v2-cbor"))
    var protocols = _strings(meta.get(String("protocols")))
    assert_equal(len(protocols), 3)
    assert_equal(protocols[0], String("smithy-rpc-v2-cbor"))
    assert_equal(protocols[1], String("json"))
    assert_equal(protocols[2], String("query"))
    # The query-mode header the reader sends follows from this trait.
    assert_true(meta.has(String("awsQueryCompatible")))


def test_operation_and_bounds() raises:
    var model = _model()
    var http = model.get(String("operations")).get(String("GetMetricData")).get(String("http"))
    assert_equal(http.get(String("method")).as_string(), String("POST"))
    assert_equal(http.get(String("requestUri")).as_string(), String("/"))
    assert_equal(
        Int(_shape(model, String("Dimensions")).get(String("max")).as_int64()),
        CLOUDWATCH_MAX_DIMENSIONS,
    )
    assert_equal(GET_METRIC_DATA_MAX_DATAPOINTS, 100_800)
    assert_true(
        "the default of 100,800 is used"
        in _doc(model, String("GetMetricDataInput"), String("MaxDatapoints"))
    )
    assert_true(
        _has(_strings(_shape(model, String("ScanBy")).get(String("enum"))), String("TimestampDescending"))
    )


def test_periods() raises:
    var doc = _doc(_model(), String("MetricStat"), String("Period"))
    assert_true("the period can be 1, 5, 10, 20, 30, 60, or any multiple of 60" in doc, doc)
    for p in [1, 5, 10, 20, 30, 60, 120, 3600]:
        assert_true(cloudwatch_period_ok(p), String(p))


def test_window_semantics() raises:
    var model = _model()
    var start = _doc(model, String("GetMetricDataInput"), String("StartTime"))
    var end = _doc(model, String("GetMetricDataInput"), String("EndTime"))
    assert_true("The value specified is inclusive" in start, start)
    assert_true("The value specified is exclusive" in end, end)
    # A point is stamped with its period's start: the last five 5-second
    # periods before 15:07:17 are those starting 15:02:15 .. 15:07:10.
    assert_true(
        "you receive data timestamped between 15:02:15 and 15:07:15" in start,
        start,
    )


def _flag(params: JsonValue, key: String) raises -> Bool:
    if not params.has(key):
        return False
    return params.get(key).as_bool()


def test_endpoint_cases() raises:
    var doc = parse_json_value(_read(_CASES))
    var cases = doc.get(String("testCases"))
    var n = cases.array_len()
    assert_equal(n, _EXPECTED_CASES, "the staged CloudWatch endpoint cases")
    var resolved = 0
    var refused = 0
    var failed = 0
    var report = String("")
    for i in range(n):
        var tc = cases.element_at(i)
        var params = JsonValue.empty_object()
        if tc.has(String("params")):
            params = tc.get(String("params"))
        if params.has(String("Endpoint")) or _flag(params, String("UseFIPS")):
            continue
        var region = String("")
        if params.has(String("Region")):
            region = params.get(String("Region")).as_string()
        var fips = False
        var dual = _flag(params, String("UseDualStack"))
        var label = region + String(" fips=") + String(fips) + String(" dual=") + String(dual)
        var expect = tc.get(String("expect"))
        if expect.has(String("endpoint")):
            var want = AwsEndpoint.parse(
                expect.get(String("endpoint")).get(String("url")).as_string(),
                String("the case"),
            ).url_for(String("/"))
            try:
                var got = aws_service_endpoint(
                    String(CLOUDWATCH_SIGNING_NAME), region, fips, dual
                ).url_for(String("/"))
                if got != want:
                    failed += 1
                    report += String("  ") + label + String(": ") + got + String(", expected ") + want + String("\n")
                else:
                    resolved += 1
                if not fips and not dual:
                    assert_equal(cloudwatch_endpoint(region).url_for(String("/")), want)
            except e:
                failed += 1
                report += String("  ") + label + String(": raised ") + String(e) + String("\n")
        else:
            try:
                var got = aws_service_endpoint(
                    String(CLOUDWATCH_SIGNING_NAME), region, fips, dual
                )
                failed += 1
                report += String("  ") + label + String(": ") + got.url_for(String("/")) + String(", expected a refusal\n")
            except:
                refused += 1
    if failed > 0:
        raise Error(String(failed) + String(" CloudWatch endpoint cases disagree:\n") + report)
    assert_true(resolved > 0 and refused > 0, String(resolved) + String(" ") + String(refused))


def main() raises:
    test_service_metadata()
    test_operation_and_bounds()
    test_periods()
    test_window_semantics()
    test_endpoint_cases()
    print("OK")
