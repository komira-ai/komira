# The GENERATED endpoint bindings, over S3's published ruleset.
#
# 1. Every `operationInputs` entry of botocore's S3 endpoint tests: the
#    entry's built-in and client parameters are set on the generated
#    `EndpointBindingsEndpointConfig`, its operation parameters on the
#    generated request of the named operation, and the generated
#    `resolve_<op>_endpoint` must give the case's expected URL, properties
#    and headers, or raise its expected error. Each operation of this
#    package's model binds S3's ruleset as the S3 model's operation of the
#    same name does, so this checks the generator's contextParam and
#    staticContextParams bindings and the config against upstream answers.
#    Each endpoint is then given to `aws_signing_target`, which must sign a
#    plain `sigv4` / `s3` scheme and refuse every other, by name.
# 2. What no `operationInputs` entry reaches: CopyObject's
#    staticContextParams (`DisableS3ExpressSessionAuth`) and the same
#    parameter as a client setting, each checked against the upstream case
#    stating those parameters; an operationContextParams member path; and
#    a custom endpoint keeping the ruleset's virtual-host addressing unless
#    `force_path_style` is set.
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

from komira_aws_core import EndpointRuleSet, ResolvedEndpoint, aws_signing_target

from endpoint_bindings.endpoint_bindings import (
    EndpointBindingsCopyObjectRequest,
    EndpointBindingsCreateBucketRequest,
    EndpointBindingsEndpointConfig,
    EndpointBindingsGetObjectRequest,
    EndpointBindingsListBucketsRequest,
    EndpointBindingsListDirectoryBucketsRequest,
    EndpointBindingsListObjectsRequest,
    EndpointBindingsPutTargetRequest,
    EndpointBindingsTarget,
    EndpointBindingsWriteGetObjectResponseRequest,
    endpoint_bindings_endpoint_rules,
    resolve_copy_object_endpoint,
    resolve_create_bucket_endpoint,
    resolve_get_object_endpoint,
    resolve_list_buckets_endpoint,
    resolve_list_directory_buckets_endpoint,
    resolve_list_objects_endpoint,
    resolve_put_target_endpoint,
    resolve_write_get_object_response_endpoint,
)


comptime _CASES = "tests/functional/endpoint-rules/s3/endpoint-tests-1.json"

# The `operationInputs` entries at the pinned botocore release: a shrunken
# file cannot pass as the suite.
comptime _EXPECTED_OPERATION_INPUTS = 215


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


def _flag(v: JsonValue, name: String) raises -> Optional[Bool]:
    if v.kind != JSON_BOOL:
        raise Error(name + " is not a boolean")
    return Optional[Bool](v.bool_val)


def _set(mut c: EndpointBindingsEndpointConfig, name: String, v: JsonValue) raises:
    """Sets the config field of ruleset parameter `name`."""
    if name == "Region":
        c.region = Optional[String](v.text)
    elif name == "Endpoint":
        c.endpoint = Optional[String](v.text)
    elif name == "UseFIPS":
        c.use_fips = _flag(v, name)
    elif name == "UseDualStack":
        c.use_dual_stack = _flag(v, name)
    elif name == "ForcePathStyle":
        c.force_path_style = _flag(v, name)
    elif name == "Accelerate":
        c.accelerate = _flag(v, name)
    elif name == "UseGlobalEndpoint":
        c.use_global_endpoint = _flag(v, name)
    elif name == "DisableMultiRegionAccessPoints":
        c.disable_multi_region_access_points = _flag(v, name)
    elif name == "UseArnRegion":
        c.use_arn_region = _flag(v, name)
    elif name == "DisableS3ExpressSessionAuth":
        c.disable_s3_express_session_auth = _flag(v, name)
    else:
        raise Error("no config field for the parameter " + name)


def _builtin_param(builtin: String) raises -> String:
    """The S3 ruleset parameter a built-in names (its `builtIn` field)."""
    if builtin == "AWS::Region":
        return "Region"
    if builtin == "SDK::Endpoint":
        return "Endpoint"
    if builtin == "AWS::UseFIPS":
        return "UseFIPS"
    if builtin == "AWS::UseDualStack":
        return "UseDualStack"
    if builtin == "AWS::S3::ForcePathStyle":
        return "ForcePathStyle"
    if builtin == "AWS::S3::Accelerate":
        return "Accelerate"
    if builtin == "AWS::S3::UseGlobalEndpoint":
        return "UseGlobalEndpoint"
    if builtin == "AWS::S3::DisableMultiRegionAccessPoints":
        return "DisableMultiRegionAccessPoints"
    if builtin == "AWS::S3::UseArnRegion":
        return "UseArnRegion"
    raise Error("an unknown built-in " + builtin)


def _config(op: JsonValue) raises -> EndpointBindingsEndpointConfig:
    var c = EndpointBindingsEndpointConfig("")
    c.region = Optional[String]()
    var b = _find(op, "builtInParams")
    if b >= 0:
        ref bp = op.children[b]
        for i in range(len(bp.obj_keys)):
            _set(c, _builtin_param(bp.obj_keys[i]), bp.children[i])
    var k = _find(op, "clientParams")
    if k >= 0:
        ref cp = op.children[k]
        for i in range(len(cp.obj_keys)):
            _set(c, cp.obj_keys[i], cp.children[i])
    return c^


def _arg(p: JsonValue, key: String) raises -> String:
    var i = _find(p, key)
    if i < 0 or p.children[i].kind != JSON_STRING:
        raise Error("the operation parameter " + key + " is missing")
    return p.children[i].text


def _only(p: JsonValue, known: String) raises:
    """Refuses an operation parameter not in `known` (comma-separated)."""
    var all = "," + known + ","
    for i in range(len(p.obj_keys)):
        if all.find("," + p.obj_keys[i] + ",") < 0:
            raise Error("an operation parameter the test does not bind: " + p.obj_keys[i])


def _resolve(rules: EndpointRuleSet, op: JsonValue) raises -> ResolvedEndpoint:
    """The generated resolution of one `operationInputs` entry."""
    var config = _config(op)
    var name = op.children[_find(op, "operationName")].text
    var p = _member_or_empty(op, "operationParams")
    if name == "GetObject":
        _only(p, "Bucket,Key")
        return resolve_get_object_endpoint(
            rules, config, EndpointBindingsGetObjectRequest(_arg(p, "Bucket"), _arg(p, "Key"))
        )
    if name == "CreateBucket":
        _only(p, "Bucket")
        return resolve_create_bucket_endpoint(
            rules, config, EndpointBindingsCreateBucketRequest(_arg(p, "Bucket"))
        )
    if name == "ListBuckets":
        _only(p, "")
        return resolve_list_buckets_endpoint(
            rules, config, EndpointBindingsListBucketsRequest()
        )
    if name == "ListDirectoryBuckets":
        _only(p, "")
        return resolve_list_directory_buckets_endpoint(
            rules, config, EndpointBindingsListDirectoryBucketsRequest()
        )
    if name == "ListObjects":
        _only(p, "Bucket,Prefix")
        var input = EndpointBindingsListObjectsRequest(_arg(p, "Bucket"))
        if _find(p, "Prefix") >= 0:
            input.prefix = Optional[String](_arg(p, "Prefix"))
        return resolve_list_objects_endpoint(rules, config, input)
    if name == "WriteGetObjectResponse":
        _only(p, "RequestRoute,RequestToken")
        return resolve_write_get_object_response_endpoint(
            rules,
            config,
            EndpointBindingsWriteGetObjectResponseRequest(
                _arg(p, "RequestRoute"), _arg(p, "RequestToken")
            ),
        )
    raise Error("an operation this package's model does not declare: " + name)


def _same_endpoint(got: ResolvedEndpoint, want: JsonValue, mut why: String) -> Bool:
    var url = want.children[_find(want, "url")].text
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
    return True


def _signable(props: JsonValue) -> Bool:
    """Whether the first sigv4 scheme of `props` signs as s3, the one this
    signer encodes a path once for (every S3 sigv4 scheme sets
    disableDoubleEncoding)."""
    var a = _find(props, "authSchemes")
    if a < 0:
        return False
    ref schemes = props.children[a]
    for i in range(len(schemes.children)):
        ref s = schemes.children[i]
        if s.children[_find(s, "name")].text == "sigv4":
            var n = _find(s, "signingName")
            return n >= 0 and s.children[n].text == "s3"
    return False


def _check(
    rules: EndpointRuleSet, op: JsonValue, expect: JsonValue, mut why: String,
    mut signed: Int, mut refused: Int,
) raises -> Bool:
    var ei = _find(expect, "endpoint")
    if ei < 0:
        var msg = expect.children[_find(expect, "error")].text
        try:
            var got = _resolve(rules, op)
            why = "endpoint " + got.url + ", expected the error '" + msg + "'"
            return False
        except e:
            if String(e).find(msg) < 0:
                why = "raised '" + String(e) + "', expected '" + msg + "'"
                return False
        return True
    var got: ResolvedEndpoint
    try:
        got = _resolve(rules, op)
    except e:
        why = "raised: " + String(e)
        return False
    if not _same_endpoint(got, expect.children[ei], why):
        return False
    var config = _config(op)
    var region = config.region.value() if config.region else String("")
    if _signable(got.properties):
        try:
            var t = aws_signing_target(got, region, "s3")
            if t.signing_name != "s3":
                why = "signs as " + t.signing_name
                return False
        except e:
            why = "signing refused: " + String(e)
            return False
        signed += 1
    else:
        try:
            _ = aws_signing_target(got, region, "s3")
            why = "signed an endpoint whose auth schemes are " + got.properties.serialize()
            return False
        except:
            refused += 1
    return True


def _case(cases: JsonValue, documentation: String) raises -> JsonValue:
    for i in range(len(cases.children)):
        ref tc = cases.children[i]
        var d = _find(tc, "documentation")
        if d >= 0 and tc.children[d].text == documentation:
            return tc.copy()
    raise Error("no S3 endpoint case is documented '" + documentation + "'")


def _expect_endpoint(cases: JsonValue, documentation: String, got: ResolvedEndpoint) raises:
    var tc = _case(cases, documentation)
    ref expect = tc.children[_find(tc, "expect")]
    var why = String("")
    if not _same_endpoint(got, expect.children[_find(expect, "endpoint")], why):
        raise Error(documentation + ": " + why)


def _refused(got: ResolvedEndpoint, want: String) raises:
    try:
        _ = aws_signing_target(got, "us-west-2", "s3")
    except e:
        if String(e).find(want) < 0:
            raise Error("signing refused with '" + String(e) + "', not '" + want + "'")
        return
    raise Error("signed; expected a refusal saying '" + want + "'")


def test_static_and_client_context_params(rules: EndpointRuleSet, cases: JsonValue) raises:
    # CopyObject's staticContextParams sets DisableS3ExpressSessionAuth: the
    # upstream case stating that parameter (the ruleset reads neither Key
    # nor CopySource, so they change nothing).
    var config = EndpointBindingsEndpointConfig("us-west-2")
    var copy = resolve_copy_object_endpoint(
        rules,
        config,
        EndpointBindingsCopyObjectRequest("mybucket--usw2-az1--x-s3", "src/key", "dst/key"),
    )
    _expect_endpoint(cases, "Data Plane sigv4 auth with short AZ", copy)
    # GetObject has no such binding: the S3 Express session scheme, which
    # this core cannot sign.
    var get = resolve_get_object_endpoint(
        rules, config, EndpointBindingsGetObjectRequest("mybucket--usw2-az1--x-s3", "k")
    )
    _refused(get, "auth scheme(s) sigv4-s3express,")
    # sigv4 under `s3express` is refused too: the signer would encode the
    # path twice.
    _refused(copy, "for the signing name s3express")
    # The same parameter as a client setting reaches GetObject.
    config.disable_s3_express_session_auth = Optional[Bool](True)
    var get2 = resolve_get_object_endpoint(
        rules, config, EndpointBindingsGetObjectRequest("mybucket--usw2-az1--x-s3", "k")
    )
    _expect_endpoint(cases, "Data Plane sigv4 auth with short AZ", get2)


def test_operation_context_param_path(rules: EndpointRuleSet) raises:
    # PutTarget binds Bucket from `Target.Bucket`.
    var config = EndpointBindingsEndpointConfig("us-west-2")
    var input = EndpointBindingsPutTargetRequest()
    var none = resolve_put_target_endpoint(rules, config, input)
    if none.url != "https://s3.us-west-2.amazonaws.com":
        raise Error("PutTarget with no Target: " + none.url)
    var target = EndpointBindingsTarget()
    var empty = input.copy()
    empty.target = Optional[EndpointBindingsTarget](target.copy())
    var unset = resolve_put_target_endpoint(rules, config, empty)
    if unset.url != "https://s3.us-west-2.amazonaws.com":
        raise Error("PutTarget with an empty Target: " + unset.url)
    target.bucket = Optional[String](String("bucket-name"))
    input.target = Optional[EndpointBindingsTarget](target^)
    var got = resolve_put_target_endpoint(rules, config, input)
    if got.url != "https://bucket-name.s3.us-west-2.amazonaws.com":
        raise Error("PutTarget with Target.Bucket: " + got.url)


def test_custom_endpoint_addressing(rules: EndpointRuleSet) raises:
    # A custom endpoint, as a local S3-compatible store is reached: the
    # ruleset's default addresses the bucket by virtual host on it...
    var config = EndpointBindingsEndpointConfig("us-east-1")
    config.endpoint = Optional[String](String("http://localhost:4566"))
    var input = EndpointBindingsGetObjectRequest("my-bucket", "a/b.txt")
    var vhost = resolve_get_object_endpoint(rules, config, input)
    if vhost.url != "http://my-bucket.localhost:4566":
        raise Error("custom endpoint, default addressing: " + vhost.url)
    var t = aws_signing_target(vhost, "us-east-1", "s3")
    if t.endpoint.host != "my-bucket.localhost" or t.endpoint.port != 4566:
        raise Error("custom endpoint, default addressing: host " + t.endpoint.host)
    # ...and force_path_style puts it in the path.
    config.force_path_style = Optional[Bool](True)
    var path = resolve_get_object_endpoint(rules, config, input)
    if path.url != "http://localhost:4566/my-bucket":
        raise Error("custom endpoint, force_path_style: " + path.url)
    var p = aws_signing_target(path, "us-east-1", "s3")
    if p.endpoint.host != "localhost" or p.endpoint.target_for("/a/b.txt") != "/my-bucket/a/b.txt":
        raise Error("custom endpoint, force_path_style: target " + p.endpoint.target_for("/a/b.txt"))
    # An IP-literal endpoint is path-style whatever the setting.
    config.force_path_style = Optional[Bool]()
    config.endpoint = Optional[String](String("http://127.0.0.1:9000"))
    var ip = resolve_get_object_endpoint(rules, config, input)
    if ip.url != "http://127.0.0.1:9000/my-bucket":
        raise Error("IP-literal endpoint: " + ip.url)


def main() raises:
    var rules = endpoint_bindings_endpoint_rules()
    var doc = parse_json_value(_read(_CASES))
    ref cases = doc.children[_find(doc, "testCases")]
    var inputs = 0
    var failed = 0
    var signed = 0
    var refused = 0
    var report = String("")
    for i in range(len(cases.children)):
        ref tc = cases.children[i]
        var oi = _find(tc, "operationInputs")
        if oi < 0:
            continue
        ref expect = tc.children[_find(tc, "expect")]
        ref ops = tc.children[oi]
        for j in range(len(ops.children)):
            inputs += 1
            var why = String("")
            if not _check(rules, ops.children[j], expect, why, signed, refused):
                failed += 1
                var d = _find(tc, "documentation")
                report += "  " + (tc.children[d].text if d >= 0 else String("")) + ": " + why + "\n"
    if inputs != _EXPECTED_OPERATION_INPUTS:
        raise Error(
            "the staged S3 endpoint tests hold " + String(inputs)
            + " operation inputs, expected " + String(_EXPECTED_OPERATION_INPUTS)
        )
    if failed > 0:
        raise Error(String(failed) + " of " + String(inputs) + " S3 operation inputs failed:\n" + report)
    test_static_and_client_context_params(rules, cases)
    test_operation_context_param_path(rules)
    test_custom_endpoint_addressing(rules)
    print(
        "S3 operation inputs through the generated bindings:", inputs, "PASS (",
        signed, "signable,", refused, "refused at signing )",
    )
