# =============================================================================
# komira_aws_core/tests/test_s3_endpoint_rules.mojo
# =============================================================================
#
# Runs every case of botocore's S3 endpoint tests through the ruleset
# interpreter (endpoint_rules.mojo) over S3's published ruleset, and
# requires every one to pass:
#
#   an endpoint case: the URL, the properties (authSchemes and backend among
#     them) and the headers equal the expected ones, as JSON values;
#   an error case:    the error message equals the expected one, byte for
#     byte.
#
# Nothing is skipped: ARN, access point, Outposts, Object Lambda, Express,
# accelerate, FIPS and dual-stack cases are all branches of the ruleset, and
# the interpreter evaluates them as data.
#
# The ruleset, the partition table and the cases are read from the botocore
# archive //third_party/botocore pins by sha256, staged at their paths in it;
# none is copied into this repository. Each case's `params` are the ruleset
# parameters; its `operationInputs` (how a client derives those parameters
# from an operation call) are the generator's subject, not this test's.
# =============================================================================

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
    AwsPartitionSet,
    EndpointOutcome,
    EndpointParams,
    EndpointRuleSet,
)


comptime _RULESET = "botocore/data/s3/2006-03-01/endpoint-rule-set-1.json"
comptime _PARTITIONS = "botocore/data/partitions.json"
comptime _CASES = "tests/functional/endpoint-rules/s3/endpoint-tests-1.json"

# The case counts at the pinned botocore release (third_party/botocore).
# Update them with the pin: a shrunken file cannot pass as the suite.
comptime _EXPECTED_CASES = 393
comptime _EXPECTED_ENDPOINT_CASES = 267
comptime _EXPECTED_ERROR_CASES = 126


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


def _json_equal(a: JsonValue, b: JsonValue) -> Bool:
    """Structural equality: object members compared by key, in any order;
    numbers by value."""
    if a.kind != b.kind:
        return False
    if a.kind == JSON_BOOL:
        return a.bool_val == b.bool_val
    if a.kind == JSON_STRING:
        return a.text == b.text
    if a.kind == JSON_NUMBER:
        if a.text == b.text:
            return True
        try:
            return Float64(a.text) == Float64(b.text)
        except:
            return False
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
    return True  # both null


def _member_or_empty(v: JsonValue, key: String) -> JsonValue:
    var i = _find(v, key)
    if i < 0:
        return JsonValue.empty_object()
    return v.children[i].copy()


def _check_case(
    rs: EndpointRuleSet, tc: JsonValue, mut why: String
) raises -> Bool:
    """Runs one case; on a failure, says why and returns False."""
    var params = EndpointParams()
    var pi = _find(tc, "params")
    if pi >= 0:
        ref p = tc.children[pi]
        for i in range(len(p.obj_keys)):
            params.set_json(p.obj_keys[i], p.children[i].copy())
    ref expect = tc.children[_find(tc, "expect")]
    var got: EndpointOutcome
    try:
        got = rs.resolve(params)
    except e:
        why = "raised: " + String(e)
        return False
    var ei = _find(expect, "endpoint")
    if ei >= 0:
        ref want = expect.children[ei]
        if got.is_error:
            why = "error '" + got.error + "', expected an endpoint"
            return False
        var url = want.children[_find(want, "url")].text
        if got.endpoint.url != url:
            why = "url " + got.endpoint.url + ", expected " + url
            return False
        var props = _member_or_empty(want, "properties")
        if not _json_equal(got.endpoint.properties, props):
            why = (
                "properties "
                + got.endpoint.properties.serialize()
                + ", expected "
                + props.serialize()
            )
            return False
        var headers = _member_or_empty(want, "headers")
        if not _json_equal(got.endpoint.headers, headers):
            why = (
                "headers "
                + got.endpoint.headers.serialize()
                + ", expected "
                + headers.serialize()
            )
            return False
        return True
    var xi = _find(expect, "error")
    if xi < 0:
        why = "the case expects neither an endpoint nor an error"
        return False
    var msg = expect.children[xi].text
    if not got.is_error:
        why = "endpoint " + got.endpoint.url + ", expected error '" + msg + "'"
        return False
    if got.error != msg:
        why = "error '" + got.error + "', expected '" + msg + "'"
        return False
    return True


def main() raises:
    var rs = EndpointRuleSet(
        _read(_RULESET), AwsPartitionSet(_read(_PARTITIONS))
    )
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    if n != _EXPECTED_CASES:
        raise Error(
            "the staged S3 endpoint tests hold "
            + String(n)
            + " cases, expected "
            + String(_EXPECTED_CASES)
        )
    var endpoints = 0
    var errors = 0
    var passed = 0
    var report = String("")
    for i in range(n):
        ref tc = cases.children[i]
        ref expect = tc.children[_find(tc, "expect")]
        if _find(expect, "endpoint") >= 0:
            endpoints += 1
        else:
            errors += 1
        var why = String("")
        if _check_case(rs, tc, why):
            passed += 1
        else:
            var doc_i = _find(tc, "documentation")
            var name = tc.children[doc_i].text if doc_i >= 0 else String("")
            report += (
                "  case " + String(i) + " (" + name + "): " + why + "\n"
            )
    print(
        "S3 endpoint rules: "
        + String(passed)
        + "/"
        + String(n)
        + " PASS ("
        + String(endpoints)
        + " endpoint, "
        + String(errors)
        + " error cases)"
    )
    if endpoints != _EXPECTED_ENDPOINT_CASES or errors != _EXPECTED_ERROR_CASES:
        raise Error(
            "case kinds changed: "
            + String(endpoints)
            + " endpoint and "
            + String(errors)
            + " error cases"
        )
    if passed != n:
        raise Error(
            String(n - passed) + " of " + String(n) + " cases failed:\n" + report
        )
    print("OK")
