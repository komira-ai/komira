# The endpoint ruleset interpreter's parts, each through a small authored
# ruleset: the standard library functions, scoping, templates, tree
# fall-through, parameter checks, and the load-time refusals; and the two
# tables beneath them, the regular-expression matcher and the partitions.
#
# The semantics are the Smithy endpoint rules specification's as botocore
# implements them (botocore/endpoint_provider.py at the pinned release);
# each row's expected value is derived from that, not from a run. The
# partition rows read botocore's partitions.json, staged from the pinned
# archive.

from std.testing import assert_equal, assert_false, assert_true

from komira_json import JsonValue

from komira_aws_core import (
    AwsPartitionSet,
    EndpointParams,
    EndpointRuleSet,
    is_valid_host_label,
)
from komira_aws_core._regex import Regex


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


# A partition table of two partitions, enough for the rulesets below.
comptime _PARTITIONS = (
    '{"version": "1.1", "partitions": ['
    '{"id": "aws", "regionRegex": "^(us|eu)\\\\-\\\\w+\\\\-\\\\d+$",'
    ' "regions": {"aws-global": {}},'
    ' "outputs": {"name": "aws", "dnsSuffix": "amazonaws.com",'
    ' "supportsFIPS": true}},'
    '{"id": "aws-cn", "regionRegex": "^cn\\\\-\\\\w+\\\\-\\\\d+$",'
    ' "regions": {},'
    ' "outputs": {"name": "aws-cn", "dnsSuffix": "amazonaws.com.cn",'
    ' "supportsFIPS": false}}]}'
)


def _ruleset(params: String, rules: String) raises -> EndpointRuleSet:
    return EndpointRuleSet(
        '{"version": "1.0", "parameters": {' + params + '}, "rules": [' + rules + "]}",
        AwsPartitionSet(_PARTITIONS),
    )


def _run(rs: EndpointRuleSet, params: EndpointParams) raises -> String:
    """`url:<url>`, `error:<message>`, or `raised:<message>`."""
    try:
        var o = rs.resolve(params)
        if o.is_error:
            return "error:" + o.error
        return "url:" + o.endpoint.url
    except e:
        return "raised:" + String(e)


def _one(rs: EndpointRuleSet, value: String) raises -> String:
    var p = EndpointParams()
    p.set_string("In", value)
    return _run(rs, p)


comptime _IN = '"In": {"type": "string"}'
comptime _NONE = '{"conditions": [], "error": "none", "type": "error"}'


def _url(url: String) -> String:
    return '"endpoint": {"url": "' + url + '", "properties": {}, "headers": {}}, "type": "endpoint"'


# -----------------------------------------------------------------------------
# The matcher and the tables
# -----------------------------------------------------------------------------


def test_regex() raises:
    var region = Regex("^(us|eu|ap|sa|ca|me|af|il|mx)\\-\\w+\\-\\d+$")
    assert_true(region.matches("us-east-1"))
    assert_true(region.matches("ap-southeast-12"))
    assert_false(region.matches("us-east-1x"))
    assert_false(region.matches("us-gov-west-1"))  # \w has no '-'
    assert_false(region.matches("xx-east-1"))
    assert_false(region.matches("us-east-"))
    assert_false(region.matches(""))
    var v4 = Regex("^(?:[0-9]{1,3}\\.){3}[0-9]{1,3}$")
    assert_true(v4.matches("192.168.0.1"))
    assert_false(v4.matches("192.168.0"))
    assert_false(v4.matches("1922.168.0.1"))
    # `re.match`: anchored at the start, not at the end without `$`.
    var pre = Regex("ab*")
    assert_true(pre.matches("abbbc"))
    assert_false(pre.matches("cab"))
    # Classes, negation, ranges, alternation, bounded repeats.
    assert_true(Regex("^[^a-c]{2,3}$").matches("xyz"))
    assert_false(Regex("^[^a-c]{2,3}$").matches("xaz"))
    assert_false(Regex("^[^a-c]{2,3}$").matches("wxyz"))
    assert_true(Regex("^(?:%25|%)[a-z]+$").matches("%25eth"))
    assert_true(Regex("^a.c$").matches("abc"))
    assert_false(Regex("^a.c$").matches("a\nc"))
    # `$` is the end of input only.
    assert_false(Regex("^a$").matches("a\n"))
    # Refused at compile time, never misread.
    for bad in ["(?=a)", "a+?", "\\bx", "(a", "a)", "*a", "\\1", "[a-", "a{3,2}"]:
        try:
            _ = Regex(bad)
        except:
            continue
        raise Error("regex not refused: " + bad)


def test_partitions() raises:
    var t = AwsPartitionSet(_read("partitions.json"))
    assert_equal(t.lookup("us-east-1").get("name").as_string(), "aws")
    assert_equal(
        t.lookup("us-east-1").get("dnsSuffix").as_string(), "amazonaws.com"
    )
    assert_equal(t.lookup("cn-north-1").get("name").as_string(), "aws-cn")
    assert_equal(t.lookup("us-gov-west-1").get("name").as_string(), "aws-us-gov")
    assert_equal(t.lookup("us-isob-east-1").get("name").as_string(), "aws-iso-b")
    assert_equal(t.lookup("eusc-de-east-1").get("name").as_string(), "aws-eusc")
    # Listed by name, not by pattern.
    assert_equal(t.lookup("aws-global").get("name").as_string(), "aws")
    assert_equal(t.lookup("aws-cn-global").get("name").as_string(), "aws-cn")
    # A region no partition claims is in the first partition.
    assert_equal(t.lookup("mars-east-1").get("name").as_string(), "aws")
    assert_equal(t.default_outputs().get("name").as_string(), "aws")
    try:
        _ = AwsPartitionSet('{"version": "1.0", "partitions": []}')
        raise Error("a version 1.0 partitions document was accepted")
    except e:
        assert_true(String(e).find("is not 1.1") >= 0, String(e))


def test_host_labels() raises:
    assert_true(is_valid_host_label("a", False))
    assert_true(is_valid_host_label("a-1", False))
    assert_true(is_valid_host_label("A1", False))
    assert_false(is_valid_host_label("", False))
    assert_false(is_valid_host_label("-a", False))
    assert_false(is_valid_host_label("a-", False))
    assert_false(is_valid_host_label("a_b", False))
    assert_false(is_valid_host_label("a.b", False))
    assert_true(is_valid_host_label("a.b", True))
    assert_false(is_valid_host_label("a..b", True))
    var l63 = String("")
    for _ in range(63):
        l63 += "x"
    assert_true(is_valid_host_label(l63, False))
    assert_false(is_valid_host_label(l63 + "x", False))


# -----------------------------------------------------------------------------
# Functions
# -----------------------------------------------------------------------------


def test_parse_url() raises:
    var rs = _ruleset(
        _IN,
        '{"conditions": [{"fn": "parseURL", "argv": [{"ref": "In"}], "assign": "u"},'
        ' {"fn": "booleanEquals", "argv": [{"fn": "getAttr", "argv": [{"ref": "u"}, "isIp"]}, true]}],'
        + _url("ip {u#scheme}|{u#authority}|{u#path}|{u#normalizedPath}")
        + "},"
        '{"conditions": [{"fn": "parseURL", "argv": [{"ref": "In"}], "assign": "u"}],'
        + _url("host {u#scheme}|{u#authority}|{u#path}|{u#normalizedPath}")
        + "},"
        + _NONE,
    )
    assert_equal(_one(rs, "https://example.com"), "url:host https|example.com||/")
    assert_equal(
        _one(rs, "HTTP://127.0.0.1:8080/a/b"), "url:ip http|127.0.0.1:8080|/a/b|/a/b/"
    )
    assert_equal(_one(rs, "https://[::1]:443/"), "url:ip https|[::1]:443|/|/")
    assert_equal(
        _one(rs, "https://[fe80::1%25eth0]/x"), "url:ip https|[fe80::1%25eth0]|/x|/x/"
    )
    # The authority keeps its case; the normalized path drops dot segments
    # and empty segments, and is percent-encoded with '/' kept.
    assert_equal(
        _one(rs, "https://Example.COM/a//b/../c"),
        "url:host https|Example.COM|/a//b/../c|/a/c/",
    )
    assert_equal(
        _one(rs, "https://example.com/a b"), "url:host https|example.com|/a b|/a%20b/"
    )
    # A host that only looks numeric is not an IP.
    assert_equal(
        _one(rs, "https://1.2.3.4.5"), "url:host https|1.2.3.4.5||/"
    )
    # Not http(s), a query, a port that is not 0..65535, an open bracket.
    assert_equal(_one(rs, "ftp://example.com"), "error:none")
    assert_equal(_one(rs, "https://example.com?q=1"), "error:none")
    assert_equal(_one(rs, "https://example.com:99999"), "error:none")
    assert_equal(_one(rs, "https://example.com:8a"), "error:none")
    assert_equal(_one(rs, "https://[::1"), "error:none")
    assert_equal(_one(rs, "https://[nothex]"), "error:none")
    assert_equal(_one(rs, "example.com"), "error:none")


def test_substring_and_uri_encode() raises:
    var rs = _ruleset(
        _IN,
        '{"conditions": [{"fn": "substring", "argv": [{"ref": "In"}, 0, 6, true], "assign": "s"},'
        ' {"fn": "substring", "argv": [{"ref": "In"}, 1, 3, false], "assign": "f"}],'
        + _url("{s}|{f}")
        + "},"
        + _NONE,
    )
    assert_equal(_one(rs, "mybucket--x-s3"), "url:--x-s3|yb")
    assert_equal(_one(rs, "abcdef"), "url:abcdef|bc")
    # Shorter than the range, or not ASCII: unset.
    assert_equal(_one(rs, "abcde"), "error:none")
    assert_equal(_one(rs, "abcdé"), "error:none")
    var enc = _ruleset(
        _IN,
        '{"conditions": [{"fn": "uriEncode", "argv": [{"ref": "In"}], "assign": "e"}],'
        + _url("{e}")
        + "},"
        + _NONE,
    )
    assert_equal(_one(enc, "a b/c?é~"), "url:a%20b%2Fc%3F%C3%A9~")


def test_parse_arn_and_get_attr() raises:
    var rs = _ruleset(
        _IN,
        '{"conditions": [{"fn": "aws.parseArn", "argv": [{"ref": "In"}], "assign": "a"},'
        ' {"fn": "getAttr", "argv": [{"ref": "a"}, "resourceId[1]"], "assign": "r1"},'
        ' {"fn": "not", "argv": [{"fn": "getAttr", "argv": [{"ref": "a"}, "resourceId[9]"]}]}],'
        + _url("{a#partition}|{a#service}|{a#region}|{a#accountId}|{r1}")
        + "},"
        + _NONE,
    )
    assert_equal(
        _one(rs, "arn:aws:s3:us-west-2:123456789012:accesspoint/my-ap:x"),
        "url:aws|s3|us-west-2|123456789012|my-ap",
    )
    # The region and account may be empty; partition, service and resource
    # may not.
    assert_equal(_one(rs, "arn:aws:s3:::accesspoint:b"), "url:aws|s3|||b")
    assert_equal(_one(rs, "arn::s3:::accesspoint:b"), "error:none")
    assert_equal(_one(rs, "arn:aws:s3:us-west-2:1:"), "error:none")
    assert_equal(_one(rs, "arn:aws:s3:us-west-2"), "error:none")
    assert_equal(_one(rs, "notarn:aws:s3:::a:b"), "error:none")
    # A resource of one part: resourceId[1] is unset, so the rule fails.
    assert_equal(_one(rs, "arn:aws:s3:::bucket"), "error:none")


def test_virtual_hostable_and_partition() raises:
    var rs = _ruleset(
        _IN + ', "Sub": {"type": "boolean", "required": true, "default": false}',
        '{"conditions": [{"fn": "aws.isVirtualHostableS3Bucket", "argv": [{"ref": "In"}, {"ref": "Sub"}]}],'
        + _url("yes")
        + "},"
        + _NONE,
    )
    assert_equal(_one(rs, "my-bucket"), "url:yes")
    assert_equal(_one(rs, "my.bucket"), "error:none")
    assert_equal(_one(rs, "MyBucket"), "error:none")
    assert_equal(_one(rs, "ab"), "error:none")
    assert_equal(_one(rs, "192.168.1.1"), "error:none")
    var p = EndpointParams()
    p.set_string("In", "my.bucket")
    p.set_bool("Sub", True)
    assert_equal(_run(rs, p), "url:yes")
    p.set_string("In", "192.168.1.1")
    assert_equal(_run(rs, p), "error:none")
    var part = _ruleset(
        _IN,
        '{"conditions": [{"fn": "aws.partition", "argv": [{"ref": "In"}], "assign": "p"}],'
        + _url("https://x.{p#dnsSuffix}/{p#name}")
        + "}",
    )
    assert_equal(_one(part, "cn-north-1"), "url:https://x.amazonaws.com.cn/aws-cn")
    assert_equal(_one(part, "eu-west-1"), "url:https://x.amazonaws.com/aws")
    assert_equal(_one(part, "aws-global"), "url:https://x.amazonaws.com/aws")
    # An unset region is in the first partition.
    assert_equal(_run(part, EndpointParams()), "url:https://x.amazonaws.com/aws")


# -----------------------------------------------------------------------------
# Evaluation
# -----------------------------------------------------------------------------


def test_scope_and_fall_through() raises:
    var rs = _ruleset(
        _IN,
        # A tree: its first rule assigns `p` and fails; the second must not
        # see `p`; the third applies.
        '{"conditions": [{"fn": "isSet", "argv": [{"ref": "In"}]}], "type": "tree", "rules": ['
        '  {"conditions": [{"fn": "aws.partition", "argv": [{"ref": "In"}], "assign": "p"},'
        '   {"fn": "stringEquals", "argv": [{"fn": "getAttr", "argv": [{"ref": "p"}, "name"]}, "nope"]}],'
        '   "error": "unreachable", "type": "error"},'
        '  {"conditions": [{"fn": "isSet", "argv": [{"ref": "p"}]}], "error": "leaked", "type": "error"},'
        '  {"conditions": [{"fn": "stringEquals", "argv": [{"ref": "In"}, "go"]}],'
        + _url("https://{In}")
        + "}]},"
        # Reached when no rule of the tree applies.
        + '{"conditions": [], "error": "fell through {In}", "type": "error"}',
    )
    assert_equal(_one(rs, "go"), "url:https://go")
    assert_equal(_one(rs, "stop"), "error:fell through stop")


def test_templates_and_headers() raises:
    var rs = _ruleset(
        _IN,
        '{"conditions": [{"fn": "stringEquals", "argv": [{"ref": "In"}, "h"]}],'
        ' "endpoint": {"url": {"ref": "In"}, "properties": {"authSchemes": [{"name": "sigv4", "signingRegion": "{In}"}], "n": 3},'
        ' "headers": {"x-a": ["{In}", "lit"]}}, "type": "endpoint"},'
        '{"conditions": [{"fn": "stringEquals", "argv": [{"ref": "In"}, "braces"]}],'
        ' "error": "{{literal}} {In}", "type": "error"},'
        '{"conditions": [], "error": "not a template {in_scope}", "type": "error"}',
    )
    var p = EndpointParams()
    p.set_string("In", "h")
    var o = rs.resolve(p)
    assert_false(o.is_error)
    assert_equal(o.endpoint.url, "h")
    assert_equal(
        o.endpoint.headers.serialize(), '{"x-a":["h","lit"]}'
    )
    assert_equal(
        o.endpoint.properties.serialize(),
        '{"authSchemes":[{"name":"sigv4","signingRegion":"h"}],"n":3}',
    )
    assert_equal(o.endpoint.auth_schemes().array_len(), 1)
    assert_equal(_one(rs, "braces"), "error:{literal} braces")
    # `\{[a-zA-Z#]+\}` is what makes a template; `{in_scope}` is not one.
    assert_equal(_one(rs, "x"), "error:not a template {in_scope}")


def test_parameter_checks() raises:
    var rs = _ruleset(
        _IN + ', "Req": {"type": "boolean", "required": true},'
        ' "Def": {"type": "string", "required": true, "default": "d"},'
        ' "Arr": {"type": "stringArray"}',
        '{"conditions": [], ' + _url("https://{Def}") + "}",
    )
    var p = EndpointParams()
    assert_true(_run(rs, p).find("required parameter 'Req' is not set") >= 0)
    p.set_bool("Req", True)
    assert_equal(_run(rs, p), "url:https://d")
    p.set_string("Def", "given")
    assert_equal(_run(rs, p), "url:https://given")
    p.set_string("Nope", "x")
    assert_true(_run(rs, p).find("'Nope' is not a parameter") >= 0)
    p.set_json("Nope", JsonValue.null())  # unsets it
    assert_equal(_run(rs, p), "url:https://given")
    p.set_bool("In", True)
    assert_true(_run(rs, p).find("parameter 'In' is a boolean") >= 0)
    p.set_string("In", "s")
    var arr = List[String]()
    arr.append("a")
    p.set_string_array("Arr", arr)
    assert_equal(_run(rs, p), "url:https://given")
    # Assigning a name already in scope is a fault.
    var twice = _ruleset(
        _IN,
        '{"conditions": [{"fn": "isSet", "argv": [{"ref": "In"}], "assign": "In"}],'
        + _url("x")
        + "}",
    )
    assert_true(_one(twice, "v").find("already in scope") >= 0)


def test_load_refusals() raises:
    var rows: List[List[String]] = [
        [
            '{"conditions": [{"fn": "aws.frob", "argv": [{"ref": "In"}]}], "error": "x", "type": "error"}',
            "unknown function 'aws.frob'",
        ],
        [
            '{"conditions": [{"fn": "isSet", "argv": []}], "error": "x", "type": "error"}',
            "isSet takes 1 arguments, not 0",
        ],
        [
            '{"conditions": [], "error": "x", "type": "nope"}',
            "unknown rule type 'nope'",
        ],
        [
            '{"conditions": [{"fn": "not", "argv": [{"fn": "isSet", "argv": [{"ref": "In"}], "assign": "z"}]}], "error": "x", "type": "error"}',
            "a nested call may not assign",
        ],
        [
            '{"conditions": [], "error": "x", "type": "error", "extra": 1}',
            "unknown key 'extra'",
        ],
        [
            '{"conditions": [], "type": "tree"}',
            "has no 'rules'",
        ],
    ]
    for i in range(len(rows)):
        try:
            _ = _ruleset(_IN, rows[i][0])
        except e:
            assert_true(String(e).find(rows[i][1]) >= 0, String(e))
            assert_true(String(e).startswith("EndpointRules: "), String(e))
            continue
        raise Error("not refused: " + rows[i][0])
    try:
        _ = _ruleset('"In": {"type": "integer"}', _NONE)
        raise Error("an integer parameter was accepted")
    except e:
        assert_true(String(e).find("unknown type 'integer'") >= 0, String(e))


def main() raises:
    test_regex()
    test_partitions()
    test_host_labels()
    test_parse_url()
    test_substring_and_uri_encode()
    test_parse_arn_and_get_attr()
    test_virtual_hostable_and_partition()
    test_scope_and_fall_through()
    test_templates_and_headers()
    test_parameter_checks()
    test_load_refusals()
    print("OK")
