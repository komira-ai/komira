# Where komira_aws_secretsmanager sends a request.
#
# The endpoint comes from AWS Secrets Manager's published endpoint ruleset, embedded in
# the generated module and resolved over `SecretsManagerEndpointConfig`. Rows: every
# case of botocore's secretsmanager endpoint tests (read from the pinned archive at
# test time, never copied), resolved through every operation of the client
# and signed as `secretsmanager`, then the cases a caller depends on, by name: the
# regional default, FIPS, dual-stack, a custom endpoint (a local
# emulator), and the ruleset's refusals.
from komira_json import (
    JSON_ARRAY,
    JSON_BOOL,
    JSON_NUMBER,
    JSON_OBJECT,
    JSON_STRING,
    JsonValue,
    parse_json_value,
)
from komira_aws_core import EndpointRuleSet, ResolvedEndpoint, aws_signing_target
from komira_aws_secretsmanager.komira_aws_secretsmanager import (
    SECRETSMANAGER_SERVICE,
    SecretsManagerCreateSecretRequest,
    SecretsManagerDeleteSecretRequest,
    SecretsManagerDescribeSecretRequest,
    SecretsManagerEndpointConfig,
    SecretsManagerGetSecretValueRequest,
    SecretsManagerPutSecretValueRequest,
    SecretsManagerRestoreSecretRequest,
    komira_aws_secretsmanager_endpoint_rules,
    resolve_create_secret_endpoint,
    resolve_delete_secret_endpoint,
    resolve_describe_secret_endpoint,
    resolve_get_secret_value_endpoint,
    resolve_put_secret_value_endpoint,
    resolve_restore_secret_endpoint,
)
from std.testing import assert_equal, assert_raises


comptime _CASES = "tests/functional/endpoint-rules/secretsmanager/endpoint-tests-1.json"

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


def _case_config(tc: JsonValue) raises -> SecretsManagerEndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = SecretsManagerEndpointConfig()
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
            raise Error(
                "a case parameter the secretsmanager config has no field for: " + name,
            )
    return c^


def _resolve_all(
    rules: EndpointRuleSet,
    config: SecretsManagerEndpointConfig,
) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one: no operation
    binds a ruleset parameter, so each resolves the config alone."""
    var got = resolve_create_secret_endpoint(
        rules,
        config,
        SecretsManagerCreateSecretRequest(String("app/db")),
    )
    var others = List[ResolvedEndpoint]()
    others.append(
        resolve_delete_secret_endpoint(
            rules,
            config,
            SecretsManagerDeleteSecretRequest(String("app/db")),
        ),
    )
    others.append(
        resolve_describe_secret_endpoint(
            rules,
            config,
            SecretsManagerDescribeSecretRequest(String("app/db")),
        ),
    )
    others.append(
        resolve_get_secret_value_endpoint(
            rules,
            config,
            SecretsManagerGetSecretValueRequest(String("app/db")),
        ),
    )
    others.append(
        resolve_put_secret_value_endpoint(
            rules,
            config,
            SecretsManagerPutSecretValueRequest(String("app/db")),
        ),
    )
    others.append(
        resolve_restore_secret_endpoint(
            rules,
            config,
            SecretsManagerRestoreSecretRequest(String("app/db")),
        ),
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
                var t = aws_signing_target(got, region, String(SECRETSMANAGER_SERVICE))
                if t.signing_name != "secretsmanager" or t.signing_region != region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region
                    return False
            else:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(
                        got,
                        String(""),
                        String(SECRETSMANAGER_SERVICE),
                    )
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
    var rules = komira_aws_secretsmanager_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged secretsmanager endpoint cases")
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
        raise Error(
            String(failed) + " of " + String(n) + " secretsmanager endpoint cases failed:\n" + report,
        )


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: SecretsManagerEndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_secretsmanager_endpoint_rules(), config)


def test_regional_default() raises:
    var got = _resolve(SecretsManagerEndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://secretsmanager.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String(SECRETSMANAGER_SERVICE))
    assert_equal(t.signing_name, "secretsmanager")
    assert_equal(t.signing_region, "us-west-2")
    assert_equal(
        _resolve(SecretsManagerEndpointConfig(String("cn-north-1"))).url,
        "https://secretsmanager.cn-north-1.amazonaws.com.cn",
    )


def test_fips_and_dual_stack() raises:
    var fips = SecretsManagerEndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(
        _resolve(fips).url,
        "https://secretsmanager-fips.us-east-1.amazonaws.com",
    )
    var dual = SecretsManagerEndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://secretsmanager.us-east-1.amazonaws.com")
    # GovCloud has its own FIPS host.
    var gov = SecretsManagerEndpointConfig(String("us-gov-west-1"))
    gov.use_fips = Optional[Bool](True)
    assert_equal(
        _resolve(gov).url,
        "https://secretsmanager-fips.us-gov-west-1.amazonaws.com",
    )


def test_custom_endpoint() raises:
    var config = SecretsManagerEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String(SECRETSMANAGER_SERVICE))
    assert_equal(t.signing_name, "secretsmanager")
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    assert_equal(t.endpoint.url_for(String("/")), "http://localhost:4566/")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(SecretsManagerEndpointConfig())
    var fips = SecretsManagerEndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = SecretsManagerEndpointConfig(String("us-east-1"))
    dual.endpoint = Optional[String](String("http://localhost:4566"))
    dual.use_dual_stack = Optional[Bool](True)
    with assert_raises(contains="Dualstack and custom endpoint are not supported"):
        _ = _resolve(dual)


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    print("OK")
