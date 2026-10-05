# Where komira_aws_route53 sends a request, and how it signs it.
#
# Route 53 is a global service: one endpoint per partition, whatever
# region the client is configured with, signed in that partition's
# global region (`implicitGlobalRegion`: us-east-1 in `aws`,
# cn-northwest-1 in `aws-cn`, us-gov-west-1 in `aws-us-gov`). Nothing
# here hard-codes a host or a signing region: the endpoint comes from
# Route 53's published endpoint ruleset, embedded in the generated module
# and resolved over `Route53EndpointConfig`, and the signing region from
# the `authSchemes` property of the endpoint it chooses, through
# komira_aws_core's `aws_signing_target`.
#
# Rows: every case of botocore's route53 endpoint tests (read from the
# pinned archive at test time, never copied), resolved through every
# operation of the client, each endpoint's signing name and region
# checked against the case's authSchemes; then the cases a caller depends
# on, by name: a regional client (eu-west-1, ap-southeast-2, which no
# botocore case names) sent to route53.amazonaws.com and signed in
# us-east-1, the China and GovCloud partitions, FIPS, dual-stack, a custom
# endpoint (LocalStack), and the ruleset's refusals.
#
# The signed rows are the whole send-side chain -- built, resolved, signed
# with komira_aws_core's build_sigv4_signed_request -- for a fixed clock
# and AWS's documented example credentials, from a client configured in
# eu-west-1: a ListResourceRecordSets and a ChangeResourceRecordSets, each
# to route53.amazonaws.com in scope us-east-1/route53. Their signatures
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
from komira_aws_route53.komira_aws_route53 import (
    ROUTE53_CHANGE_ACTION_UPSERT,
    ROUTE53_RRTYPE_TXT,
    Route53Change,
    Route53ChangeBatch,
    Route53ChangeResourceRecordSetsRequest,
    Route53EndpointConfig,
    Route53ListHostedZonesByNameRequest,
    Route53ListResourceRecordSetsRequest,
    Route53ResourceRecord,
    Route53ResourceRecordSet,
    build_change_resource_record_sets_request,
    build_list_resource_record_sets_request,
    komira_aws_route53_endpoint_rules,
    resolve_change_resource_record_sets_endpoint,
    resolve_list_hosted_zones_by_name_endpoint,
    resolve_list_resource_record_sets_endpoint,
)
from std.testing import assert_equal, assert_raises, assert_true


comptime _CASES = "tests/functional/endpoint-rules/route53/endpoint-tests-1.json"

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


def _case_config(tc: JsonValue) raises -> Route53EndpointConfig:
    """The generated config holding exactly the case's parameters."""
    var c = Route53EndpointConfig()
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
            raise Error("a case parameter the route53 config has no field for: " + name)
    return c^


comptime _ZONE = "Z1D633PJN98FT9"


def _change() -> Route53ChangeResourceRecordSetsRequest:
    var rrset = Route53ResourceRecordSet(String("tok.example.com."), String(ROUTE53_RRTYPE_TXT))
    rrset.set_ttl(Int64(300))
    var records = List[Route53ResourceRecord]()
    records.append(Route53ResourceRecord(String('"token"')))
    rrset.set_resource_records(records^)
    var changes = List[Route53Change]()
    changes.append(Route53Change(String(ROUTE53_CHANGE_ACTION_UPSERT), rrset^))
    return Route53ChangeResourceRecordSetsRequest(String(_ZONE), Route53ChangeBatch(changes^))


def _resolve_all(rules: EndpointRuleSet, config: Route53EndpointConfig) raises -> ResolvedEndpoint:
    """The endpoint of every operation, which must be one: Route 53 binds
    no operation parameter, so each resolves the config alone."""
    var got = resolve_list_resource_record_sets_endpoint(
        rules, config, Route53ListResourceRecordSetsRequest(String(_ZONE))
    )
    var others = List[ResolvedEndpoint]()
    others.append(
        resolve_list_hosted_zones_by_name_endpoint(rules, config, Route53ListHostedZonesByNameRequest())
    )
    others.append(resolve_change_resource_record_sets_endpoint(rules, config, _change()))
    for i in range(len(others)):
        if others[i].url != got.url:
            raise Error("operations disagree: " + others[i].url + " and " + got.url)
        if not _json_equal(others[i].properties, got.properties):
            raise Error("operations disagree on properties: " + others[i].properties.serialize())
    return got^


def _scheme_signing_region(props: JsonValue) raises -> String:
    """The signingRegion of the one sigv4 scheme of a case's properties,
    or "" when it states no scheme."""
    var ai = _find(props, "authSchemes")
    if ai < 0:
        return String("")
    ref schemes = props.children[ai]
    assert_equal(len(schemes.children), 1, "one auth scheme per route53 endpoint")
    ref s = schemes.children[0]
    assert_equal(s.children[_find(s, "name")].text, "sigv4")
    return s.children[_find(s, "signingRegion")].text


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
            var signing_region = _scheme_signing_region(props)
            if signing_region.byte_length() > 0:
                # The client's region is the case's; the scheme names the
                # region it is signed in, which wins.
                var region = config.region.value() if config.region else String("")
                var t = aws_signing_target(got, region, String("route53"))
                if t.signing_name != "route53" or t.signing_region != signing_region:
                    why = (
                        "signs as " + t.signing_name + "/" + t.signing_region
                        + ", expected route53/" + signing_region
                    )
                    return False
            elif config.region:
                # A custom endpoint states no scheme, and the client signs
                # in its own region, as botocore signs it.
                var region = config.region.value()
                var t = aws_signing_target(got, region, String("route53"))
                if t.signing_name != "route53" or t.signing_region != region:
                    why = (
                        "signs as " + t.signing_name + "/" + t.signing_region
                        + ", expected route53/" + region
                    )
                    return False
            else:
                # A custom endpoint needs no region to resolve; a client
                # given none has no region to sign in, and says so.
                try:
                    _ = aws_signing_target(got, String(""), String("route53"))
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
    var rules = komira_aws_route53_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var n = len(cases.children)
    assert_equal(n, _EXPECTED_CASES, "the staged route53 endpoint cases")
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
        raise Error(String(failed) + " of " + String(n) + " route53 endpoint cases failed:\n" + report)


# ---- the cases a caller depends on ---------------------------------------------


def _resolve(config: Route53EndpointConfig) raises -> ResolvedEndpoint:
    return _resolve_all(komira_aws_route53_endpoint_rules(), config)


def _check_global(region: String, url: String, signing_region: String) raises:
    var got = _resolve(Route53EndpointConfig(region))
    assert_equal(got.url, url, region)
    var t = aws_signing_target(got, region, String("route53"))
    assert_equal(t.signing_name, "route53", region)
    assert_equal(t.signing_region, signing_region, region)
    assert_equal(t.endpoint.url_for(String("/2013-04-01/hostedzonesbyname")), url + "/2013-04-01/hostedzonesbyname")


def test_a_regional_client_reaches_the_global_endpoint() raises:
    # No botocore case names these regions: a client configured anywhere in
    # the `aws` partition sends to the one global endpoint, in us-east-1.
    _check_global(String("eu-west-1"), String("https://route53.amazonaws.com"), String("us-east-1"))
    _check_global(String("ap-southeast-2"), String("https://route53.amazonaws.com"), String("us-east-1"))
    _check_global(String("us-west-2"), String("https://route53.amazonaws.com"), String("us-east-1"))
    # A region the partition table does not list, matched by its regex.
    _check_global(String("eu-west-9"), String("https://route53.amazonaws.com"), String("us-east-1"))
    # botocore's own pseudo-region for the global endpoint.
    _check_global(String("aws-global"), String("https://route53.amazonaws.com"), String("us-east-1"))


def test_the_other_partitions() raises:
    # China signs in cn-northwest-1 even from cn-north-1; GovCloud in
    # us-gov-west-1 even from us-gov-east-1.
    _check_global(String("cn-north-1"), String("https://route53.amazonaws.com.cn"), String("cn-northwest-1"))
    _check_global(String("us-gov-east-1"), String("https://route53.us-gov.amazonaws.com"), String("us-gov-west-1"))


def test_fips_and_dual_stack() raises:
    var fips = Route53EndpointConfig(String("eu-central-1"))
    fips.use_fips = Optional[Bool](True)
    var f = _resolve(fips)
    assert_equal(f.url, "https://route53-fips.amazonaws.com")
    assert_equal(aws_signing_target(f, String("eu-central-1"), String("route53")).signing_region, "us-east-1")
    var dual = Route53EndpointConfig(String("eu-central-1"))
    dual.use_dual_stack = Optional[Bool](True)
    assert_equal(_resolve(dual).url, "https://route53.global.api.aws")
    # In GovCloud the FIPS endpoint is the plain one.
    var gov = Route53EndpointConfig(String("us-gov-east-1"))
    gov.use_fips = Optional[Bool](True)
    assert_equal(_resolve(gov).url, "https://route53.us-gov.amazonaws.com")


def test_custom_endpoint() raises:
    # A custom endpoint states no auth scheme, so the request is signed in
    # the client's own region, as botocore signs it.
    var config = Route53EndpointConfig(String("eu-west-1"))
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var got = _resolve(config)
    assert_equal(got.url, "http://localhost:4566")
    var t = aws_signing_target(got, String("eu-west-1"), String("route53"))
    assert_equal(t.signing_region, "eu-west-1")
    assert_equal(t.endpoint.host_header(), "localhost:4566")
    assert_equal(
        t.endpoint.url_for(String("/2013-04-01/hostedzone/Z1/rrset/")),
        "http://localhost:4566/2013-04-01/hostedzone/Z1/rrset/",
    )


def test_ruleset_refusals() raises:
    with assert_raises(contains="Invalid Configuration: Missing Region"):
        _ = _resolve(Route53EndpointConfig())
    var fips = Route53EndpointConfig(String("us-east-1"))
    fips.endpoint = Optional[String](String("http://localhost:4566"))
    fips.use_fips = Optional[Bool](True)
    with assert_raises(contains="FIPS and custom endpoint are not supported"):
        _ = _resolve(fips)
    var dual = Route53EndpointConfig(String("us-east-1"))
    dual.endpoint = Optional[String](String("http://localhost:4566"))
    dual.use_dual_stack = Optional[Bool](True)
    with assert_raises(contains="Dualstack and custom endpoint are not supported"):
        _ = _resolve(dual)
    # A region no partition's regex matches falls to `aws`, as the
    # partition function's default does.
    assert_equal(_resolve(Route53EndpointConfig(String("mars-north-1"))).url, "https://route53.amazonaws.com")


# ---- signed ---------------------------------------------------------------------

comptime _KEY = "AKIAIOSFODNN7EXAMPLE"
comptime _SECRET = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
# 2026-10-01T00:00:00Z.
comptime _NOW = 1790812800


def _signed(req: AwsRequest, resolved: ResolvedEndpoint, region: String) raises -> CredentialHttpRequest:
    var t = aws_signing_target(resolved, region, String("route53"))
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


def test_signed_list_resource_record_sets_from_eu_west_1() raises:
    # Canonical request (the query sorted by name; empty payload hashed):
    #   GET
    #   /2013-04-01/hostedzone/Z1D633PJN98FT9/rrset
    #   maxitems=1&name=tok.example.com.&type=TXT
    #   host:route53.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #
    #   host;x-amz-date
    #   e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    var input = Route53ListResourceRecordSetsRequest(String(_ZONE))
    input.set_start_record_name(String("tok.example.com."))
    input.set_start_record_type(String(ROUTE53_RRTYPE_TXT))
    input.set_max_items(String("1"))
    var built = build_list_resource_record_sets_request(input)
    var config = Route53EndpointConfig(String("eu-west-1"))
    var req = _signed(built, _resolve(config), String("eu-west-1"))
    assert_equal(req.method, "GET")
    assert_equal(req.scheme, "https")
    assert_equal(req.host, "route53.amazonaws.com")
    assert_equal(req.port, 443)
    assert_equal(req.target, "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset?name=tok.example.com.&type=TXT&maxitems=1")
    assert_equal(req.header("Host"), "route53.amazonaws.com")
    assert_equal(req.header("X-Amz-Date"), "20261001T000000Z")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/route53/aws4_request, "
        + "SignedHeaders=host;x-amz-date, "
        + "Signature=483d56a4261952711c3f7147c7e21784211335f11b1effbb095f7490abc78202",
    )


def test_signed_change_resource_record_sets_from_eu_west_1() raises:
    # Canonical request (hashed payload: SHA-256 of the body below):
    #   POST
    #   /2013-04-01/hostedzone/Z1D633PJN98FT9/rrset/
    #
    #   content-type:application/xml
    #   host:route53.amazonaws.com
    #   x-amz-date:20261001T000000Z
    #
    #   content-type;host;x-amz-date
    #   f6e451a8cefa5e44bbaaea97981b999ab8f7dd7b5d3e3d382e07bfe07505c182
    var built = build_change_resource_record_sets_request(_change())
    assert_equal(
        built.body_text(),
        '<ChangeResourceRecordSetsRequest xmlns="https://route53.amazonaws.com/doc/2013-04-01/">'
        + "<ChangeBatch><Changes><Change><Action>UPSERT</Action><ResourceRecordSet>"
        + "<Name>tok.example.com.</Name><Type>TXT</Type><TTL>300</TTL>"
        + '<ResourceRecords><ResourceRecord><Value>"token"</Value></ResourceRecord>'
        + "</ResourceRecords></ResourceRecordSet></Change></Changes></ChangeBatch>"
        + "</ChangeResourceRecordSetsRequest>",
    )
    var req = _signed(built, _resolve(Route53EndpointConfig(String("eu-west-1"))), String("eu-west-1"))
    assert_equal(req.method, "POST")
    assert_equal(req.host, "route53.amazonaws.com")
    assert_equal(req.target, "/2013-04-01/hostedzone/Z1D633PJN98FT9/rrset/")
    assert_equal(req.header("Content-Type"), "application/xml")
    assert_equal(
        req.header("Authorization"),
        "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20261001/us-east-1/route53/aws4_request, "
        + "SignedHeaders=content-type;host;x-amz-date, "
        + "Signature=054375825171bbc74164c34ec23e5ba24763cdfb2e66778d92a895a37da11394",
    )


def main() raises:
    test_botocore_endpoint_cases()
    test_a_regional_client_reaches_the_global_endpoint()
    test_the_other_partitions()
    test_fips_and_dual_stack()
    test_custom_endpoint()
    test_ruleset_refusals()
    test_signed_list_resource_record_sets_from_eu_west_1()
    test_signed_change_resource_record_sets_from_eu_west_1()
    print("OK")
