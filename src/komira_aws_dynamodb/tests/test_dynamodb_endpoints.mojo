# Where komira_aws_dynamodb sends a request, and the requests it signs.
#
# The endpoint comes from DynamoDB's published endpoint ruleset, embedded in
# the generated module and resolved over `DynamoDBEndpointConfig` plus the
# one parameter every generated operation binds: `ResourceArn`, from its
# `TableName` (a table name, or a table ARN, which the ruleset reads for
# the account-based endpoint). Rows: botocore's dynamodb endpoint tests
# (read from the pinned archive at test time, never copied), each resolved
# through every operation of the client, then the cases a caller depends
# on, by name: the regional default, FIPS, dual-stack, the account-based
# endpoint, a custom endpoint (LocalStack), and the ruleset's refusals.
#
# Of botocore's 548 cases, 320 set `ResourceArnList` or
# `IsSearchOperation`. No operation of this client binds either: the first
# is bound by BatchGetItem, BatchWriteItem, TransactGetItems and
# TransactWriteItems (`operationContextParams`), the second by
# SearchVectors (`staticContextParams`), none of which is generated. A
# case's parameters cannot reach the ruleset except through the generated
# config and an operation's binding, so those cases are counted, by
# exactly that reason, and not resolved; the count is pinned, so a new
# case of either kind, or one this client could resolve, changes it. The
# other 228 are resolved. A case that sets no `ResourceArn` is resolved
# with the plain table name `table_name`, which every operation sends:
# not an ARN, so the ruleset's ARN rules do not apply to it (a named row
# below pins that). A case's parameters are the whole set the ruleset
# sees, so the config's SDK-default `AccountIdEndpointMode` is cleared
# before a case's own are set.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock
# and AWS's documented example credentials: GetItem to us-east-1, PutItem
# to the FIPS endpoint, and DescribeTable to LocalStack. Their signatures
# were computed by an independent SigV4 implementation (one that
# reproduces the signature AWS publishes for its IAM ListUsers SigV4
# example) over the canonical requests stated beside them.
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
from komira_aws_dynamodb.komira_aws_dynamodb import (
    DynamoDBAttributeValue,
    DynamoDBCreateTableInput,
    DynamoDBDeleteItemInput,
    DynamoDBDeleteTableInput,
    DynamoDBDescribeContinuousBackupsInput,
    DynamoDBDescribeTableInput,
    DynamoDBDescribeTimeToLiveInput,
    DynamoDBEndpointConfig,
    DynamoDBGetItemInput,
    DynamoDBPointInTimeRecoverySpecification,
    DynamoDBPutItemInput,
    DynamoDBQueryInput,
    DynamoDBScanInput,
    DynamoDBTimeToLiveSpecification,
    DynamoDBUpdateContinuousBackupsInput,
    DynamoDBUpdateItemInput,
    DynamoDBUpdateTableInput,
    DynamoDBUpdateTimeToLiveInput,
    build_describe_table_request,
    build_get_item_request,
    build_put_item_request,
    komira_aws_dynamodb_endpoint_rules,
    resolve_create_table_endpoint,
    resolve_delete_item_endpoint,
    resolve_delete_table_endpoint,
    resolve_describe_continuous_backups_endpoint,
    resolve_describe_table_endpoint,
    resolve_describe_time_to_live_endpoint,
    resolve_get_item_endpoint,
    resolve_put_item_endpoint,
    resolve_query_endpoint,
    resolve_scan_endpoint,
    resolve_update_continuous_backups_endpoint,
    resolve_update_item_endpoint,
    resolve_update_table_endpoint,
    resolve_update_time_to_live_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/dynamodb/endpoint-tests-1.json"

# The case counts at the pinned botocore release: a shrunken file cannot
# pass as the suite.
comptime _EXPECTED_CASES = 548
comptime _EXPECTED_RESOLVED = 228
comptime _EXPECTED_RESOLVED_ERRORS = 68
comptime _EXPECTED_NOT_BOUND = 320


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


def _key() -> Dict[String, DynamoDBAttributeValue]:
    var v = DynamoDBAttributeValue()
    v.set_s(String("r"))
    var k = Dict[String, DynamoDBAttributeValue]()
    k["pk"] = v^
    return k^


def _resolve_all(
    rules: EndpointRuleSet, config: DynamoDBEndpointConfig, table: String
) raises -> ResolvedEndpoint:
    """The endpoint of every operation for `table`, which must be one: each
    binds `ResourceArn` from its TableName and nothing else."""
    var got = resolve_get_item_endpoint(rules, config, DynamoDBGetItemInput(table, _key()))
    var urls = List[String]()
    urls.append(resolve_put_item_endpoint(rules, config, DynamoDBPutItemInput(table, _key())).url)
    urls.append(resolve_update_item_endpoint(rules, config, DynamoDBUpdateItemInput(table, _key())).url)
    urls.append(resolve_delete_item_endpoint(rules, config, DynamoDBDeleteItemInput(table, _key())).url)
    urls.append(resolve_query_endpoint(rules, config, DynamoDBQueryInput(table)).url)
    urls.append(resolve_scan_endpoint(rules, config, DynamoDBScanInput(table)).url)
    urls.append(resolve_describe_table_endpoint(rules, config, DynamoDBDescribeTableInput(table)).url)
    urls.append(resolve_create_table_endpoint(rules, config, DynamoDBCreateTableInput(table)).url)
    urls.append(resolve_delete_table_endpoint(rules, config, DynamoDBDeleteTableInput(table)).url)
    urls.append(resolve_update_table_endpoint(rules, config, DynamoDBUpdateTableInput(table)).url)
    urls.append(
        resolve_describe_time_to_live_endpoint(rules, config, DynamoDBDescribeTimeToLiveInput(table)).url
    )
    urls.append(
        resolve_update_time_to_live_endpoint(
            rules,
            config,
            DynamoDBUpdateTimeToLiveInput(table, DynamoDBTimeToLiveSpecification(True, String("ttl"))),
        ).url
    )
    urls.append(
        resolve_describe_continuous_backups_endpoint(
            rules, config, DynamoDBDescribeContinuousBackupsInput(table)
        ).url
    )
    urls.append(
        resolve_update_continuous_backups_endpoint(
            rules,
            config,
            DynamoDBUpdateContinuousBackupsInput(table, DynamoDBPointInTimeRecoverySpecification(True)),
        ).url
    )
    for i in range(len(urls)):
        if urls[i] != got.url:
            raise Error("operations disagree: " + urls[i] + " and " + got.url)
    return got^


def _not_bound(tc: JsonValue) -> Bool:
    """Whether the case sets a parameter no generated operation binds."""
    var pi = _find(tc, "params")
    if pi < 0:
        return False
    ref p = tc.children[pi]
    return _find(p, "ResourceArnList") >= 0 or _find(p, "IsSearchOperation") >= 0


def _case_config(tc: JsonValue, mut table: String) raises -> DynamoDBEndpointConfig:
    """The generated config holding the case's parameters, and in `table`
    its ResourceArn (else the plain table name every operation sends)."""
    var c = DynamoDBEndpointConfig()
    # A case's parameters are the whole set the ruleset sees, so the mode
    # the config starts with (the SDKs' `preferred`) is cleared first.
    c.account_id_endpoint_mode = Optional[String]()
    table = String("table_name")
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
        elif name == "AccountId" and v.kind == JSON_STRING:
            c.account_id = Optional[String](v.text)
        elif name == "AccountIdEndpointMode" and v.kind == JSON_STRING:
            c.account_id_endpoint_mode = Optional[String](v.text)
        elif name == "ResourceArn" and v.kind == JSON_STRING:
            table = v.text
        else:
            raise Error("a case parameter the dynamodb client cannot set: " + name)
    return c^


def _check_case(rules: EndpointRuleSet, tc: JsonValue, mut why: String) raises -> Bool:
    var table = String("")
    var config = _case_config(tc, table)
    ref expect = tc.children[_find(tc, "expect")]
    var ei = _find(expect, "endpoint")
    if ei >= 0:
        ref want = expect.children[ei]
        var url = want.children[_find(want, "url")].text
        try:
            var got = _resolve_all(rules, config, table)
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
                # The region signed for is the case's, unless the endpoint's
                # auth scheme names one (`local` signs as us-east-1).
                var region = config.region.value()
                var want_region = region
                var schemes = _member_or_empty(props, "authSchemes")
                if schemes.kind == JSON_ARRAY and len(schemes.children) > 0:
                    var ri = _find(schemes.children[0], "signingRegion")
                    if ri >= 0:
                        want_region = schemes.children[0].children[ri].text
                var t = aws_signing_target(got, region, String("dynamodb"))
                if t.signing_name != "dynamodb" or t.signing_region != want_region:
                    why = "signs as " + t.signing_name + "/" + t.signing_region
                    return False
            else:
                # A custom endpoint needs no region to resolve, and there is
                # then none to sign with.
                try:
                    _ = aws_signing_target(got, String(""), String("dynamodb"))
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
        var got = _resolve_all(rules, config, table)
        why = "endpoint " + got.url + ", expected the error '" + msg + "'"
        return False
    except e:
        if String(e).find(msg) < 0:
            why = "raised '" + String(e) + "', expected '" + msg + "'"
            return False
    return True


def test_botocore_endpoint_cases() raises:
    var rules = komira_aws_dynamodb_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged dynamodb endpoint cases")
    var resolved = 0
    var errors = 0
    var not_bound = 0
    var failed = 0
    var report = String("")
    for i in range(n):
        ref tc = cases.children[i]
        if _not_bound(tc):
            not_bound += 1
            continue
        resolved += 1
        ref expect = tc.children[_find(tc, "expect")]
        if _find(expect, "error") >= 0:
            errors += 1
        var why = String("")
        if not _check_case(rules, tc, why):
            failed += 1
            var d = _find(tc, "documentation")
            report += "  " + (tc.children[d].text if d >= 0 else String("")) + ": " + why + "\n"
    assert_equal(not_bound, _EXPECTED_NOT_BOUND, "cases setting a parameter no operation binds")
    assert_equal(resolved, _EXPECTED_RESOLVED, "cases resolved")
    assert_equal(errors, _EXPECTED_RESOLVED_ERRORS, "error cases resolved")
    if failed > 0:
        raise Error(String(failed) + " of " + String(resolved) + " dynamodb endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: DynamoDBEndpointConfig, table: String = String("routes")) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_dynamodb_endpoint_rules(), config, table)


def test_regional_default() raises:
    var got = _resolve(DynamoDBEndpointConfig(String("us-west-2")))
    assert_equal(got.url, "https://dynamodb.us-west-2.amazonaws.com")
    var t = aws_signing_target(got, String("us-west-2"), String("dynamodb"))
    assert_equal(t.signing_name, "dynamodb")
    assert_equal(t.signing_region, "us-west-2")
    assert_equal(
        _resolve(DynamoDBEndpointConfig(String("cn-north-1"))).url,
        "https://dynamodb.cn-north-1.amazonaws.com.cn",
    )
    # `local`: the ruleset's own name for DynamoDB Local on this machine.
    assert_equal(_resolve(DynamoDBEndpointConfig(String("local"))).url, "http://localhost:8000")


def test_fips_and_dual_stack() raises:
    var fips = DynamoDBEndpointConfig(String("us-east-1"))
    fips.use_fips = Optional[Bool](True)
    assert_equal(_resolve(fips).url, "https://dynamodb-fips.us-east-1.amazonaws.com")
    var dual = DynamoDBEndpointConfig(String("us-east-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://dynamodb.us-east-1.api.aws")
    var both = DynamoDBEndpointConfig(String("us-east-1"))
    both.use_fips = Optional[Bool](True)
    both.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(both).url, "https://dynamodb-fips.us-east-1.api.aws")


def test_account_based_endpoint() raises:
    # The account-based host (`<account>.ddb.<region>.amazonaws.com`) is
    # chosen by `account_id_endpoint_mode`, which starts as `preferred`, the
    # AWS SDKs' default for the AWS::Auth::AccountIdEndpointMode built-in:
    # an account id alone picks it. Cleared, the ruleset sees no mode and
    # answers the regional host even with an account id.
    var by_default = DynamoDBEndpointConfig(String("us-east-1"))
    assert_equal(by_default.account_id_endpoint_mode.value(), "preferred")
    by_default.account_id = Optional[String](String("111111111111"))
    assert_equal(_resolve(by_default).url, "https://111111111111.ddb.us-east-1.amazonaws.com")
    var unset = DynamoDBEndpointConfig(String("us-east-1"))
    unset.account_id = Optional[String](String("111111111111"))
    unset.account_id_endpoint_mode = Optional[String]()
    assert_equal(_resolve(unset).url, "https://dynamodb.us-east-1.amazonaws.com")
    # Without an account id, `preferred` answers the regional host.
    assert_equal(
        _resolve(DynamoDBEndpointConfig(String("us-east-1"))).url,
        "https://dynamodb.us-east-1.amazonaws.com",
    )
    var preferred = DynamoDBEndpointConfig(String("us-east-1"))
    preferred.account_id = Optional[String](String("111111111111"))
    preferred.account_id_endpoint_mode = Optional[String](String("preferred"))
    var got = _resolve(preferred)
    assert_equal(got.url, "https://111111111111.ddb.us-east-1.amazonaws.com")
    var t = aws_signing_target(got, String("us-east-1"), String("dynamodb"))
    assert_equal(t.signing_name, "dynamodb")
    assert_equal(t.signing_region, "us-east-1")
    # A table named by its ARN names the account too.
    var by_arn = DynamoDBEndpointConfig(String("us-east-1"))
    by_arn.account_id_endpoint_mode = Optional[String](String("preferred"))
    assert_equal(
        _resolve(by_arn, String("arn:aws:dynamodb:us-east-1:222222222222:table/routes")).url,
        "https://222222222222.ddb.us-east-1.amazonaws.com",
    )
    var off = DynamoDBEndpointConfig(String("us-east-1"))
    off.account_id = Optional[String](String("111111111111"))
    off.account_id_endpoint_mode = Optional[String](String("disabled"))
    assert_equal(_resolve(off).url, "https://dynamodb.us-east-1.amazonaws.com")
    var required = DynamoDBEndpointConfig(String("us-east-1"))
    required.account_id_endpoint_mode = Optional[String](String("required"))
    with assert_raises(contains="AccountIdEndpointMode is required but no AccountID was provided"):
        _ = _resolve(required)
    # A plain table name is not an ARN, so the ARN rules do not apply to
    # it: with `required` and an account id it still takes the account
    # endpoint from that id.
    var named = DynamoDBEndpointConfig(String("us-east-1"))
    named.account_id = Optional[String](String("111111111111"))
    named.account_id_endpoint_mode = Optional[String](String("required"))
    assert_equal(
        _resolve(named, String("table_name")).url,
        "https://111111111111.ddb.us-east-1.amazonaws.com",
    )


def test_custom_endpoint() raises:
    var config = DynamoDBEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("us-east-1"), String("dynamodb"))
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    # A custom endpoint is used as given, account id or not.
    config.account_id = Optional[String](String("111111111111"))
    assert_equal(_resolve(config).url, "http://localhost:4566")


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(DynamoDBEndpointConfig())
    var fips = DynamoDBEndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = DynamoDBEndpointConfig(String("us-east-1"))
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
    var t = aws_signing_target(resolved, region, String("dynamodb"))
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


def _auth(scope_region: String, signature: String) -> String:
    return (
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/" + scope_region
        + "/dynamodb/aws4_request, SignedHeaders=content-type;host;x-amz-date;x-amz-target, "
        + "Signature=" + signature
    )


def test_signed_get_item() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /
    #
    #   content-type:application/x-amz-json-1.0
    #   host:dynamodb.us-east-1.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #   x-amz-target:DynamoDB_20120810.GetItem
    #
    #   content-type;host;x-amz-date;x-amz-target
    #   9936f9a3bad61da7ebc8d71d6227c2aa617e1927d765e5ca4680a4310a7d9220
    var key = Dict[String, DynamoDBAttributeValue]()
    var pk = DynamoDBAttributeValue()
    pk.set_s(String("route#1"))
    key["pk"] = pk^
    var input = DynamoDBGetItemInput(String("routes"), key^)
    input.set_consistent_read(True)
    var built = build_get_item_request(input)
    assert_equal(
        built.body_text(),
        '{"TableName":"routes","Key":{"pk":{"S":"route#1"}},"ConsistentRead":true}',
    )
    var req = _signed(built, _resolve(DynamoDBEndpointConfig(String("us-east-1"))), String("us-east-1"))
    assert_equal(req.host, "dynamodb.us-east-1.amazonaws.com")
    assert_equal(req.header("X-Amz-Target"), "DynamoDB_20120810.GetItem")
    assert_equal(
        req.header("Authorization"),
        _auth(String("us-east-1"), String("fff22b3c26f60d65596e680a4883fb6a0c17d7a9c2bec7ec48bd5344aab5ae70")),
    )


def test_signed_put_item_fips() raises:
    # Canonical request:
    #   POST
    #   /
    #
    #   content-type:application/x-amz-json-1.0
    #   host:dynamodb-fips.us-east-1.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #   x-amz-target:DynamoDB_20120810.PutItem
    #
    #   content-type;host;x-amz-date;x-amz-target
    #   ef331e515815d52911aff23af6563ae0556392749c82c2798c8f4d8654fba291
    var item = Dict[String, DynamoDBAttributeValue]()
    var pk = DynamoDBAttributeValue()
    pk.set_s(String("route#1"))
    item["pk"] = pk^
    var n = DynamoDBAttributeValue()
    n.set_n(String("3"))
    item["n"] = n^
    var input = DynamoDBPutItemInput(String("routes"), item^)
    input.set_condition_expression(String("attribute_not_exists(pk)"))
    var config = DynamoDBEndpointConfig(String("us-east-1"))
    config.use_fips = Optional[Bool](True)
    var req = _signed(build_put_item_request(input), _resolve(config), String("us-east-1"))
    assert_equal(req.host, "dynamodb-fips.us-east-1.amazonaws.com")
    assert_equal(
        req.header("Authorization"),
        _auth(String("us-east-1"), String("5d923b9e4254f65f5def2571a97f88b53c38a20b85f00e5cf25733961d183425")),
    )


def test_signed_describe_table_to_localstack() raises:
    # Canonical request:
    #   POST
    #   /
    #
    #   content-type:application/x-amz-json-1.0
    #   host:localhost:4566
    #   x-amz-date:20261001T000000Z
    #   x-amz-target:DynamoDB_20120810.DescribeTable
    #
    #   content-type;host;x-amz-date;x-amz-target
    #   313727f09e71d11b94627ce1e5e03a964fd0831a4076a38930eb7b3abff206a3
    var config = DynamoDBEndpointConfig(String("us-east-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var req = _signed(
        build_describe_table_request(DynamoDBDescribeTableInput(String("routes"))),
        _resolve(config),
        String("us-east-1"),
    )
    assert_equal(req.scheme, "http")
    assert_equal(req.header("Host"), "localhost:4566")
    assert_equal(
        req.header("Authorization"),
        _auth(String("us-east-1"), String("47bb90bbbb4e7509a001f46bb6d1bf48d30c21e23aa9954c7b6e9463c71b8ec6")),
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_regional_default()
    test_fips_and_dual_stack()
    test_account_based_endpoint()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_get_item()
    test_signed_put_item_fips()
    test_signed_describe_table_to_localstack()
    print("OK")
