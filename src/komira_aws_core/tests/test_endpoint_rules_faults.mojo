# =============================================================================
# komira_aws_core/tests/test_endpoint_rules_faults.mojo
# =============================================================================
#
# The endpoint ruleset interpreter (endpoint_rules.mojo) on what S3's
# published ruleset never exercises, each through a small authored ruleset:
#
#   * `not` on every JSON kind, by Python truthiness (botocore applies
#     Python's `not`);
#   * the unset arms of the functions that accept an unset argument, and
#     the faults (raised `EndpointRules: ...`) of each function given a
#     value of the wrong kind, the message naming the kind;
#   * getAttr's index and attribute arms;
#   * a rule's error, url and header values that resolve to a non-string;
#   * template faults;
#   * parseURL on what urlsplit cleans or splits off (leading C0 controls
#     and spaces, tab / CR / LF anywhere, an invalid scheme byte, `;params`
#     on the last segment, a bracket after userinfo), and botocore's
#     remove_dot_segments on its own;
#   * load-time refusals of a malformed document, parameter, call,
#     reference, rule and endpoint.
#
# Expected URLs and unset results are botocore's (endpoint_provider.py,
# utils.py remove_dot_segments, and Python's urllib.parse.urlparse), with
# one deliberate divergence: a URL urlparse raises ValueError on (the two
# bracket-after-userinfo cases in test_parse_url_cleaning) raises out of
# botocore's parseURL, and here answers unset, as the Smithy rules
# language specifies parseURL on a URL it cannot parse. The fault messages
# are this interpreter's contract (a type error in the data is a fault,
# never an answer).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_aws_core import AwsPartitionSet, EndpointParams, EndpointRuleSet
from komira_aws_core.endpoint_rules import _remove_dot_segments


comptime _PARTITIONS = (
    '{"version": "1.1", "partitions": ['
    '{"id": "aws", "regionRegex": "^(us|eu)\\\\-\\\\w+\\\\-\\\\d+$",'
    ' "regions": {}, "outputs": {"name": "aws", "dnsSuffix": "amazonaws.com"}}]}'
)

comptime _IN = '"In": {"type": "string"}'
comptime _NONE = '{"conditions": [], "error": "none", "type": "error"}'


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


def _url(url: String) -> String:
    return '"endpoint": {"url": "' + url + '", "properties": {}, "headers": {}}, "type": "endpoint"'


def _cond(conds: String) raises -> String:
    """In = "v": `url:yes` when every condition holds, else `error:none`,
    or the fault raised."""
    var rs = _ruleset(_IN, '{"conditions": [' + conds + "], " + _url("yes") + "}," + _NONE)
    return _one(rs, "v")


comptime _F = "raised:EndpointRules: "


def test_not_truthiness() raises:
    # Python: "" 0 0.0 -0 [] {} null and false are falsy; the rest truthy.
    var falsy_values: List[String] = [
        '""', "0", "0.0", "-0", "1e-400", "0e400", "[]", "{}", "false", '{"ref": "Nope"}'
    ]
    for falsy in falsy_values:
        assert_equal(_cond('{"fn": "not", "argv": [' + falsy + "]}"), "url:yes", falsy)
    for truthy in ['"a"', "2.5", "1E2", "1e400", '["x"]', '{"k": "v"}', "true", '{"ref": "In"}']:
        assert_equal(_cond('{"fn": "not", "argv": [' + truthy + "]}"), "error:none", truthy)


def test_wrong_kinds() raises:
    # The kind each fault names: unset, a boolean, a number, a string, an
    # array, an object.
    var se = '{"fn": "stringEquals", "argv": ['
    assert_equal(_cond(se + '{"ref": "Nope"}, "x"]}'), _F + "stringEquals needs two strings, got unset and a string")
    assert_equal(_cond(se + 'true, "x"]}'), _F + "stringEquals needs two strings, got a boolean and a string")
    assert_equal(_cond(se + '1, "x"]}'), _F + "stringEquals needs two strings, got a number and a string")
    assert_equal(_cond(se + '"x", ["x"]]}'), _F + "stringEquals needs two strings, got a string and an array")
    assert_equal(_cond(se + '{"k": "v"}, "x"]}'), _F + "stringEquals needs two strings, got an object and a string")
    assert_equal(
        _cond('{"fn": "booleanEquals", "argv": ["x", true]}'),
        _F + "booleanEquals needs two booleans, got a string and a boolean",
    )
    assert_equal(
        _cond('{"fn": "booleanEquals", "argv": [true, 1]}'),
        _F + "booleanEquals needs two booleans, got a boolean and a number",
    )
    assert_equal(_cond('{"fn": "uriEncode", "argv": [true]}'), _F + "uriEncode needs a string, got a boolean")
    assert_equal(
        _cond('{"fn": "isValidHostLabel", "argv": ["a", "x"]}'),
        _F + "isValidHostLabel needs a boolean, got a string",
    )
    assert_equal(_cond('{"fn": "getAttr", "argv": [{"ref": "In"}, true]}'), _F + "getAttr needs a string path")
    assert_equal(_cond('{"fn": "aws.partition", "argv": [true]}'), _F + "aws.partition needs a string, got a boolean")
    assert_equal(_cond('{"fn": "parseURL", "argv": [1]}'), _F + "parseURL needs a string, got a number")
    assert_equal(_cond('{"fn": "aws.parseArn", "argv": [true]}'), _F + "aws.parseArn needs a string, got a boolean")
    assert_equal(
        _cond('{"fn": "substring", "argv": [true, 0, 1, false]}'),
        _F + "substring needs a string, got a boolean",
    )
    assert_equal(
        _cond('{"fn": "substring", "argv": ["abc", "0", 1, false]}'),
        _F + "substring needs an integer, got a string",
    )
    assert_equal(
        _cond('{"fn": "substring", "argv": ["abc", 0, 1.5, false]}'),
        _F + "substring needs an integer, got a number",
    )
    assert_equal(
        _cond('{"fn": "substring", "argv": ["abc", 0, 1, "no"]}'),
        _F + "substring needs a boolean, got a string",
    )


def test_unset_arguments() raises:
    # An unset argument is unset (or false) where botocore's function
    # returns None (or False) for None, so the condition does not hold.
    for call in [
        '{"fn": "uriEncode", "argv": [{"ref": "Nope"}]}',
        '{"fn": "parseURL", "argv": [{"ref": "Nope"}]}',
        '{"fn": "aws.parseArn", "argv": [{"ref": "Nope"}]}',
        '{"fn": "isValidHostLabel", "argv": [{"ref": "Nope"}, false]}',
        '{"fn": "aws.isVirtualHostableS3Bucket", "argv": [{"ref": "Nope"}, false]}',
    ]:
        assert_equal(_cond(call), "error:none", call)
    # Set, the same calls hold.
    assert_equal(_cond('{"fn": "uriEncode", "argv": [{"ref": "In"}]}'), "url:yes")
    assert_equal(_cond('{"fn": "isValidHostLabel", "argv": [{"ref": "In"}, false]}'), "url:yes")


def _get(path: String) raises -> String:
    """getAttr over u = parseURL("https://example.com")."""
    var rs = _ruleset(
        _IN,
        '{"conditions": [{"fn": "parseURL", "argv": ["https://example.com"], "assign": "u"},'
        ' {"fn": "getAttr", "argv": [{"ref": "u"}, "' + path + '"]}],'
        + _url("yes") + "}," + _NONE,
    )
    return _one(rs, "v")


def test_get_attr() raises:
    assert_equal(_get("scheme"), "url:yes")
    assert_equal(_get("nope"), _F + "getAttr 'nope': no attribute 'nope'")
    # An indexed name absent from the object is unset.
    assert_equal(_get("nope[0]"), "error:none")
    assert_equal(_get("[0]"), _F + "getAttr '[0]' indexes an object")
    assert_equal(_get("scheme[0]"), _F + "getAttr 'scheme[0]' indexes a string")
    assert_equal(
        _cond('{"fn": "getAttr", "argv": [{"ref": "In"}, "x[0]"]}'),
        _F + "getAttr 'x[0]' on a string",
    )
    assert_equal(
        _cond('{"fn": "getAttr", "argv": [{"ref": "In"}, "x"]}'),
        _F + "getAttr 'x' on a string",
    )
    # An index into an unset value is unset.
    assert_equal(_cond('{"fn": "getAttr", "argv": [{"ref": "Nope"}, "[0]"]}'), "error:none")


def _out(rules: String) raises -> String:
    return _one(_ruleset(_IN + ', "B": {"type": "boolean"}', rules), "v")


def test_values_of_the_wrong_kind() raises:
    assert_equal(
        _out('{"conditions": [], "error": {"ref": "Nope"}, "type": "error"}'),
        _F + "an error rule's message is unset",
    )
    assert_equal(
        _out(
            '{"conditions": [], "endpoint": {"url": {"fn": "isSet", "argv":'
            ' [{"ref": "In"}]}}, "type": "endpoint"}'
        ),
        _F + "an endpoint url resolved to a boolean",
    )
    assert_equal(
        _out(
            '{"conditions": [], "endpoint": {"url": "https://x", "headers":'
            ' {"h": ["a", {"fn": "isSet", "argv": [{"ref": "In"}]}]}},'
            ' "type": "endpoint"}'
        ),
        _F + "header 'h' resolved to a boolean",
    )


def _tmpl(url: String) raises -> String:
    var rs = _ruleset(
        _IN,
        '{"conditions": [{"fn": "parseURL", "argv": ["https://example.com"], "assign": "u"}],'
        + _url(url) + "}," + _NONE,
    )
    return _one(rs, "v")


def test_template_faults() raises:
    assert_equal(_tmpl("https://{In}"), "url:https://v")
    assert_equal(_tmpl("https://{In}/{x"), _F + "template 'https://{In}/{x' has an unclosed '{'")
    assert_equal(_tmpl("https://{In}/x}"), _F + "template 'https://{In}/x}' has a single '}'")
    assert_equal(_tmpl("https://{Nope}"), _F + "template 'https://{Nope}' names 'Nope', which is not in scope")
    assert_equal(_tmpl("https://{In#x}"), _F + "template 'https://{In#x}': 'In' has no 'x'")
    assert_equal(_tmpl("https://{u#nope}"), _F + "template 'https://{u#nope}': 'u' has no 'nope'")
    assert_equal(_tmpl("https://{u#isIp}"), _F + "template 'https://{u#isIp}': 'u#isIp' is a boolean")


def _parse(value: String) raises -> String:
    var rs = _ruleset(
        _IN,
        '{"conditions": [{"fn": "parseURL", "argv": [{"ref": "In"}], "assign": "u"}],'
        + _url("{u#scheme}|{u#authority}|{u#path}|{u#normalizedPath}")
        + "},"
        + _NONE,
    )
    return _one(rs, value)


def test_parse_url_cleaning() raises:
    # urlsplit drops leading C0 controls and spaces, and every tab, CR, LF.
    assert_equal(_parse(" " + chr(1) + "https://example.com/x"), "url:https|example.com|/x|/x/")
    assert_equal(_parse("https://exa\tmple.com/a\nb\r"), "url:https|example.com|/ab|/ab/")
    # A scheme with a byte outside [A-Za-z0-9+-.] is no scheme.
    assert_equal(_parse("h_ttps://example.com"), "error:none")
    # `;params` split off the last segment only, at its first ';'.
    assert_equal(_parse("https://example.com/a;p"), "url:https|example.com|/a|/a/")
    assert_equal(_parse("https://example.com/a;p;q"), "url:https|example.com|/a|/a/")
    assert_equal(_parse("https://example.com/x;y/z"), "url:https|example.com|/x;y/z|/x%3By/z/")
    # A bracket after userinfo that never closes, and text between '@' and
    # '[': not an IPv6 URL, unset (Smithy's parseURL; urlparse raises
    # ValueError on both, so botocore raises).
    assert_equal(_parse("https://[a]@[b"), "error:none")
    assert_equal(_parse("https://a@b[::1]"), "error:none")


def test_remove_dot_segments() raises:
    assert_equal(_remove_dot_segments(""), "")
    assert_equal(_remove_dot_segments("/"), "/")
    assert_equal(_remove_dot_segments("/a/"), "/a/")
    assert_equal(_remove_dot_segments("/a"), "/a")
    assert_equal(_remove_dot_segments("//a//b//"), "/a/b/")
    assert_equal(_remove_dot_segments("/a/b/../"), "/a/")
    assert_equal(_remove_dot_segments("/../"), "/")
    assert_equal(_remove_dot_segments("a/./b"), "a/b")


def _load_refused(doc: String, want: String) raises:
    try:
        _ = EndpointRuleSet(doc, AwsPartitionSet(_PARTITIONS))
    except e:
        assert_equal(String(e), "EndpointRules: " + want, doc)
        return
    raise Error("ruleset loaded: " + doc)


def _rules(rules: String) -> String:
    return '{"version": "1.0", "parameters": {' + String(_IN) + '}, "rules": [' + rules + "]}"


def test_load_refusals() raises:
    var rs = _ruleset(_IN + ', "B": {"type": "boolean"}', _NONE)
    var names = rs.parameter_names()
    assert_equal(len(names), 2)
    assert_equal(names[0], "In")
    assert_equal(names[1], "B")
    _load_refused("[]", "the ruleset document is not an object")
    _load_refused('{"version": 1, "parameters": {}, "rules": []}', "the ruleset: 'version' has the wrong JSON kind")
    _load_refused('{"version": "2.0", "parameters": {}, "rules": []}', "ruleset version '2.0' is not a 1.x version")
    _load_refused('{"version": "1.0", "parameters": {"In": 1}, "rules": []}', "parameter 'In' is not an object")
    _load_refused(_rules("1"), "rules[0] is not an object")
    _load_refused(
        _rules('{"conditions": [1], "error": "e", "type": "error"}'),
        "rules[0].conditions[0] is not a function call",
    )
    _load_refused(
        _rules('{"conditions": [{"fn": "isSet", "argv": [{"ref": "In"}], "assign": 1}], "error": "e", "type": "error"}'),
        "rules[0].conditions[0]: 'assign' is not a string",
    )
    _load_refused(
        _rules('{"conditions": [{"fn": "isSet", "argv": [{"ref": "In"}], "x": 1}], "error": "e", "type": "error"}'),
        "rules[0].conditions[0] has unknown key 'x'",
    )
    _load_refused(
        _rules('{"conditions": [{"fn": "isSet", "argv": [{"ref": "In", "x": 1}]}], "error": "e", "type": "error"}'),
        "rules[0].conditions[0].argv[0]: a reference has keys besides 'ref'",
    )
    _load_refused(
        _rules('{"conditions": [], "endpoint": {}, "type": "endpoint"}'),
        "rules[0].endpoint has no 'url'",
    )
    _load_refused(
        _rules('{"conditions": [], "endpoint": {"url": "u", "headers": []}, "type": "endpoint"}'),
        "rules[0].endpoint.headers is not an object",
    )
    _load_refused(
        _rules('{"conditions": [], "endpoint": {"url": "u", "headers": {"h": "v"}}, "type": "endpoint"}'),
        "rules[0].endpoint.headers values must be arrays",
    )
    _load_refused(
        _rules('{"conditions": [], "endpoint": {"url": "u", "properties": []}, "type": "endpoint"}'),
        "rules[0].endpoint.properties is not an object",
    )
    _load_refused(
        _rules('{"conditions": [], "endpoint": {"url": "u", "k": 1}, "type": "endpoint"}'),
        "rules[0].endpoint has unknown key 'k'",
    )
    _load_refused(_rules('{"conditions": [], "type": "error"}'), "rules[0] has no 'error'")


def main() raises:
    var failed = 0
    try:
        test_not_truthiness()
    except e:
        print("FAIL test_not_truthiness:", e)
        failed += 1
    try:
        test_wrong_kinds()
    except e:
        print("FAIL test_wrong_kinds:", e)
        failed += 1
    try:
        test_unset_arguments()
    except e:
        print("FAIL test_unset_arguments:", e)
        failed += 1
    try:
        test_get_attr()
    except e:
        print("FAIL test_get_attr:", e)
        failed += 1
    try:
        test_values_of_the_wrong_kind()
    except e:
        print("FAIL test_values_of_the_wrong_kind:", e)
        failed += 1
    try:
        test_template_faults()
    except e:
        print("FAIL test_template_faults:", e)
        failed += 1
    try:
        test_parse_url_cleaning()
    except e:
        print("FAIL test_parse_url_cleaning:", e)
        failed += 1
    try:
        test_remove_dot_segments()
    except e:
        print("FAIL test_remove_dot_segments:", e)
        failed += 1
    try:
        test_load_refusals()
    except e:
        print("FAIL test_load_refusals:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("OK")
