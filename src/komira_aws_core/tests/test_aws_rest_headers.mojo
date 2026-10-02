# Headers, the response code and restJson1 errors (aws_rest.mojo). Each row
# is derived from the rule it cites:
#
#   [L]  RFC 9110 section 5.6.1: a list is elements separated by commas
#        with optional spaces/tabs; a recipient ignores empty elements
#   [QS] RFC 9110 section 5.6.4: quoted-string, with '\' quoting the next
#        byte
#   [F]  RFC 9110 sections 5.1 / 5.3 / 5.5: field names are
#        case-insensitive, lines of one field combine with ", ", and
#        leading/trailing whitespace is not part of a value
#   [H]  https://smithy.io/2.0/spec/http-bindings.html#httpheader-trait:
#        lists in one header; timestamps default to http-date;
#        #httpprefixheaders-trait: prefix + key, read case-insensitively;
#        #httpresponsecode-trait: the status
#   [D]  RFC 9110 section 5.6.7: IMF-fixdate holds a comma
#   [J]  https://smithy.io/2.0/aws/protocols/aws-restjson1-protocol.html,
#        "Operation error serialization": X-Amzn-Errortype, then `code`,
#        then `__type`; cut at ':' and after '#'

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import (
    AwsRequest,
    AwsResponse,
    aws_header_field,
    aws_header_http_date_list,
    aws_header_http_date_list_from,
    aws_header_list,
    aws_header_list_from,
    aws_prefix_headers,
    aws_response_code,
    aws_rest_json_error,
    aws_set_prefix_headers,
)


def _list_is(got: List[String], want: List[String], what: String) raises:
    assert_equal(len(got), len(want), what)
    for i in range(len(want)):
        assert_equal(got[i], want[i], what + " #" + String(i))


def _refused_list(text: String, why: String) raises:
    try:
        _ = aws_header_list_from(text)
    except e:
        assert_true(String(e).find(why) >= 0, String(e))
        return
    raise Error("list header '" + text + "' was read")


def test_list_write() raises:
    # [L] plain elements joined by ", ".
    assert_equal(aws_header_list(["a", "b", "c"]), "a, b, c")
    assert_equal(aws_header_list(["true", "false"]), "true, false")
    assert_equal(aws_header_list(["1", "-2", "NaN"]), "1, -2, NaN")
    assert_equal(aws_header_list(List[String]()), "")
    # [QS] an element that would not read back bare is quoted: one with a
    # comma or a quote, an empty one, one with edge whitespace.
    assert_equal(aws_header_list(["b,c"]), '"b,c"')
    assert_equal(aws_header_list(['"q"']), '"\\"q\\""')
    assert_equal(aws_header_list(["", "x"]), '"", x')
    assert_equal(aws_header_list([" x", "y\t"]), '" x", "y\t"')
    # Inside quotes '\' is escaped too; bare it needs nothing.
    assert_equal(aws_header_list(['a\\"b']), '"a\\\\\\"b"')
    assert_equal(aws_header_list(["a\\b"]), "a\\b")


def test_list_read() raises:
    # [L] whitespace around elements is dropped; empty elements skipped.
    _list_is(aws_header_list_from("a, b ,c"), ["a", "b", "c"], "plain")
    _list_is(aws_header_list_from("a,,b, ,"), ["a", "b"], "empties")
    _list_is(aws_header_list_from(""), List[String](), "empty field")
    _list_is(aws_header_list_from(" \t "), List[String](), "blank field")
    _list_is(aws_header_list_from("in ner"), ["in ner"], "inner space")
    # [QS] quoted elements keep commas, spaces and escaped bytes.
    _list_is(
        aws_header_list_from('"x, y" , z,"\\"q\\"",  "a\\\\b"'),
        ["x, y", "z", '"q"', "a\\b"],
        "quoted",
    )
    _list_is(aws_header_list_from('""'), [""], "empty quoted")
    _list_is(aws_header_list_from('" sp "'), [" sp "], "quoted edges")
    _refused_list('"open', "unterminated quote")
    _refused_list('"open\\"', "unterminated quote")
    _refused_list('"a"b', "text after a quote")
    _refused_list('"a" b, c', "text after a quote")
    # Every element the writer can be given reads back.
    var rows: List[String] = [
        "plain", "b,c", '"q"', "", " lead", "trail ", "a\\b", 'm\\"x', "é",
    ]
    _list_is(aws_header_list_from(aws_header_list(rows)), rows, "round trip")


def test_http_date_lists() raises:
    # [H] [D] timestamps in a header are http-dates, written bare.
    var ts: List[Float64] = [784111777.0, 0.0]
    var text = aws_header_http_date_list(ts)
    assert_equal(
        text, "Sun, 06 Nov 1994 08:49:37 GMT, Thu, 01 Jan 1970 00:00:00 GMT"
    )
    var back = aws_header_http_date_list_from(text)
    assert_equal(len(back), 2)
    assert_equal(back[0], 784111777.0)
    assert_equal(back[1], 0.0)
    # Quoted dates read as whole elements, and may mix with bare ones.
    var mixed = aws_header_http_date_list_from(
        '"Sun, 06 Nov 1994 08:49:37 GMT", Thu, 01 Jan 1970 00:00:00 GMT'
    )
    assert_equal(len(mixed), 2)
    assert_equal(mixed[0], 784111777.0)
    assert_equal(mixed[1], 0.0)
    assert_equal(len(aws_header_http_date_list_from("")), 0)
    var bad: List[String] = [
        "Sun",
        "Sun, 06 Nov 1994 08:49:37 GMT, Thu",
        "1994-11-06T08:49:37Z",
    ]
    for i in range(len(bad)):
        try:
            _ = aws_header_http_date_list_from(bad[i])
            raise Error("http-date list '" + bad[i] + "' was read")
        except e:
            assert_true(String(e).find("http-date") >= 0, String(e))


def test_response_fields() raises:
    # [F] case-insensitive, lines combined, whitespace trimmed.
    var r = AwsResponse.of_text(200, "")
    r.add_header("X-List", "a")
    r.add_header("Other", "o")
    r.add_header("x-list", "  b, c\t")
    r.add_header("X-Empty", "")
    assert_equal(aws_header_field(r, "x-LIST"), "a, b, c")
    assert_equal(aws_header_field(r, "Other"), "o")
    assert_equal(aws_header_field(r, "absent"), "")
    assert_false(r.has_header("absent"))
    assert_equal(aws_header_field(r, "X-Empty"), "")
    assert_true(r.has_header("X-Empty"))
    _list_is(aws_header_list_from(aws_header_field(r, "X-List")), ["a", "b", "c"], "lines")
    # [H] the response code.
    assert_equal(aws_response_code(AwsResponse.of_text(201, "")), Int32(201))
    assert_equal(aws_response_code(AwsResponse.of_text(204, "")), Int32(204))


def test_prefix_headers() raises:
    # [H] one header per entry, prefix + key.
    var req = AwsRequest("PUT", "/b/k")
    aws_set_prefix_headers(req, "x-amz-meta-", ["Color", "size"], ["red", ""])
    assert_equal(req.header("x-amz-meta-color"), "red")
    assert_equal(len(req.header_names), 2)
    assert_equal(req.header_names[0], "x-amz-meta-Color")
    assert_equal(req.header_names[1], "x-amz-meta-size")
    assert_equal(req.header_values[1], "")
    # Refused: an empty key, a key that is no header name, unequal lists.
    var refused: List[String] = ["", "a:b", "a b", "a\r\nb"]
    for i in range(len(refused)):
        var q = AwsRequest("PUT", "/")
        try:
            aws_set_prefix_headers(q, "x-amz-meta-", [refused[i]], ["v"])
            raise Error("prefix key '" + refused[i] + "' was set")
        except e:
            assert_true(String(e).find("header") >= 0, String(e))
    try:
        var q = AwsRequest("PUT", "/")
        aws_set_prefix_headers(q, "p-", ["a", "b"], ["v"])
        raise Error("unequal prefix-header lists were set")
    except e:
        assert_true(String(e).find("differ in length") >= 0, String(e))
    # [H] [F] read back case-insensitively; the key in its arrival case;
    # names differing only in case are one field.
    var r = AwsResponse.of_text(200, "")
    r.add_header("X-Amz-Meta-Color", "red")
    r.add_header("Content-Type", "text/plain")
    r.add_header("x-amz-meta-color", " blue ")
    r.add_header("x-amz-meta-", "no key")
    r.add_header("x-amz-metadata", "other prefix")
    r.add_header("x-amz-meta-Size", "3")
    var m = aws_prefix_headers(r, "x-amz-meta-")
    assert_equal(len(m), 2)
    assert_equal(m[0].name, "Color")
    assert_equal(m[0].value, "red, blue")
    assert_equal(m[1].name, "Size")
    assert_equal(m[1].value, "3")
    # [H] an empty prefix binds every header.
    var all = aws_prefix_headers(r, "")
    assert_equal(len(all), 5)
    assert_equal(all[0].name, "X-Amz-Meta-Color")
    assert_equal(all[0].value, "red, blue")


def _err(var r: AwsResponse, code: String, message: String, rid: String) raises:
    var e = aws_rest_json_error(r)
    assert_equal(e.status, r.status)
    assert_equal(e.code, code)
    assert_equal(e.message, message)
    assert_equal(e.request_id, rid)


def test_rest_json_errors() raises:
    # [J] the header wins, cut at ':'.
    var h = AwsResponse.of_text(400, '{"code":"BodyCode","message":"m"}')
    h.add_header("X-Amzn-Errortype", "HeaderCode:http://internal.example/")
    h.add_header("x-amzn-RequestId", "req-1")
    _err(h^, "HeaderCode", "m", "req-1")
    # [J] then `code`, before `__type`; cut after the last '#'.
    _err(
        AwsResponse.of_text(
            404, '{"__type":"Other","code":"ns.a#NotFound","Message":"gone"}'
        ),
        "NotFound",
        "gone",
        "",
    )
    # [J] then `__type`, both cuts.
    _err(
        AwsResponse.of_text(409, '{"__type":"ns#Conflict:extra"}'),
        "Conflict",
        "",
        "",
    )
    # An empty header falls through to the body.
    var e = AwsResponse.of_text(400, '{"code":"FromBody"}')
    e.add_header("x-amzn-errortype", "")
    _err(e^, "FromBody", "", "")
    # Nothing names a code: "", whatever the body holds.
    _err(AwsResponse.of_text(500, ""), "", "", "")
    _err(AwsResponse.of_text(500, "<html>busy</html>"), "", "", "")
    _err(AwsResponse.of_text(500, '{"code":7}'), "", "", "")
    var notutf8: List[UInt8] = [UInt8(0xFF), UInt8(0x7B)]
    _err(AwsResponse(502, notutf8^), "", "", "")
    # Only the code and the message are read from a body.
    var leak = aws_rest_json_error(
        AwsResponse.of_text(400, '{"code":"C","secret":"s3cr3t"}')
    )
    assert_equal(String(leak.to_error("Op")).find("s3cr3t"), -1)


def main() raises:
    test_list_write()
    test_list_read()
    test_http_date_lists()
    test_response_fields()
    test_prefix_headers()
    test_rest_json_errors()
    print("OK")
