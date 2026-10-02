# Every case of botocore's CloudWatch Logs endpoint tests, resolved through
# the GENERATED client: the case's parameters set on the generated
# `CloudWatchLogsEndpointConfig` (the logs ruleset declares built-ins only,
# so each parameter is a config field), then `resolve_get_log_events_endpoint`
# over the embedded ruleset. An endpoint case must give the expected URL,
# properties and headers (none, when the case states none) and be signable (`aws_signing_target`, under the logs signing name); an error
# case must raise the expected message.
#
# The cases are read from the botocore archive //third_party/botocore pins,
# staged at their path in it.

from komira_json import (
    JSON_ARRAY,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_value,
)

from komira_aws_core import EndpointRuleSet, aws_signing_target

from logs_endpoints.logs_endpoints import (
    CloudWatchLogsEndpointConfig,
    CloudWatchLogsGetLogEventsRequest,
    logs_endpoints_endpoint_rules,
    resolve_get_log_events_endpoint,
)


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


def _config(tc: JsonValue) raises -> CloudWatchLogsEndpointConfig:
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


def _check(rules: EndpointRuleSet, tc: JsonValue, mut why: String) raises -> Bool:
    var config = _config(tc)
    var input = CloudWatchLogsGetLogEventsRequest("stream")
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
            if not config.region:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(got, "", "logs")
                    why = "signed with no region"
                    return False
                except e:
                    if String(e).find("no signing region") < 0:
                        why = "signing refused with: " + String(e)
                        return False
                return True
            var region = config.region.value()
            var t = aws_signing_target(got, region, "logs")
            if t.signing_name != "logs" or t.signing_region != region:
                why = "signs as " + t.signing_name + "/" + t.signing_region
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


def main() raises:
    var rules = logs_endpoints_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    if n != _EXPECTED_CASES:
        raise Error(
            "the staged logs endpoint tests hold " + String(n)
            + " cases, expected " + String(_EXPECTED_CASES)
        )
    var errors = 0
    var failed = 0
    var report = String("")
    for i in range(n):
        ref tc = cases.children[i]
        ref expect = tc.children[_find(tc, "expect")]
        if _find(expect, "error") >= 0:
            errors += 1
        var why = String("")
        if not _check(rules, tc, why):
            failed += 1
            var d = _find(tc, "documentation")
            report += "  " + (tc.children[d].text if d >= 0 else String("")) + ": " + why + "\n"
    if errors != _EXPECTED_ERROR_CASES:
        raise Error("expected " + String(_EXPECTED_ERROR_CASES) + " error cases, found " + String(errors))
    if failed > 0:
        raise Error(String(failed) + " of " + String(n) + " logs endpoint cases failed:\n" + report)
    print("logs endpoint cases through the generated client:", n, "PASS")
