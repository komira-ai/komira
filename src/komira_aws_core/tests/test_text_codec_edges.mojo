# =============================================================================
# komira_aws_core/tests/test_text_codec_edges.mojo
# =============================================================================
#
# The text readers under the codecs, at the edges the protocol tests do not
# reach: the credential endpoints' flat JSON reader (every escape, every
# refusal), UTF-8 well-formedness past the second byte, the ISO 8601 and
# http-date readers' malformed forms, the awsJson token readers' refusals,
# the restXml element-name check on multi-byte names, the restXml readers'
# absent members, the request id filter, request header names, host
# prefixes, Content-Range, and the SigV4 method / payload-hash checks and
# percent-decoding. Each expected value is the protocol's (RFC 8259 for
# JSON, RFC 3629 for UTF-8, RFC 9110 for the http-date, XML 1.0 for names,
# SigV4 for the canonical query), not a run of this code.
#
# main() runs every test and reports each failure before it fails, so one
# run shows every test a change breaks.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_xml import XmlWriter

from komira_aws_core import (
    AWS_TS_ISO8601,
    AwsCredential,
    AwsRequest,
    CredentialHttpResponse,
    Header,
    SigV4SigningContext,
    aws_host_prefix,
    aws_http_date_from_text,
    aws_ts_from_text,
    aws_xml_blob_of,
    aws_xml_end,
    aws_xml_error_info,
    aws_xml_get_blob,
    aws_xml_get_bool,
    aws_xml_get_f32,
    aws_xml_get_f64,
    aws_xml_get_ts,
    aws_xml_parse,
    aws_xml_start,
    canonical_query,
    canonical_uri,
    s3_content_range_total,
    sigv4_sign_payload_hash,
    EMPTY_PAYLOAD_SHA256,
)
from komira_aws_core._flat_json import parse_flat_json, parse_top_level_strings
from komira_aws_core.aws_codec import (
    AWS_JSON_BOOL,
    AWS_JSON_NUMBER,
    AWS_JSON_STRING,
    AwsJsonToken,
    aws_token_f32,
    aws_ts_from_token,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _contains(msg: String, want: String) raises:
    assert_true(msg.find(want) >= 0, "'" + msg + "' lacks '" + want + "'")


# -----------------------------------------------------------------------------
# The flat JSON reader (credential endpoints, error bodies)
# -----------------------------------------------------------------------------


def _flat(doc: String, key: String) raises -> String:
    var j = parse_flat_json(doc)
    assert_true(j.has(key), "no member " + key)
    return j.get(key)


def _flat_refused(doc: String, want: String) raises:
    try:
        _ = parse_flat_json(doc)
    except e:
        _contains(String(e), "not a flat JSON object (" + want + ")")
        return
    raise Error("parse_flat_json accepted a document it must refuse: " + want)


def _top_refused(doc: String, want: String) raises:
    try:
        _ = parse_top_level_strings(doc)
    except e:
        _contains(String(e), "not a JSON object (" + want + ")")
        return
    raise Error("parse_top_level_strings accepted: " + want)


def test_flat_json_escapes() raises:
    # RFC 8259 section 7: the two-character escapes.
    assert_equal(
        _flat('{"a":"x\\by\\fz\\nw\\rv\\tu\\"\\\\\\/"}', "a"),
        "x" + chr(8) + "y" + chr(12) + "z\nw" + chr(13) + "v\tu\"\\/",
    )
    # \uXXXX in lower- and upper-case hex, at each UTF-8 width.
    assert_equal(_flat('{"a":"\\u0041"}', "a"), "A")
    assert_equal(_flat('{"a":"\\u00e9\\u00C9"}', "a"), "éÉ")
    assert_equal(_flat('{"a":"\\u07FF"}', "a"), chr(0x7FF))
    assert_equal(_flat('{"a":"\\u20aC"}', "a"), "€")
    assert_equal(_flat('{"a":"\\uFFFD"}', "a"), chr(0xFFFD))
    # A surrogate pair is one code point, four UTF-8 bytes.
    assert_equal(_flat('{"a":"\\ud83d\\ude00"}', "a"), chr(0x1F600))
    assert_equal(_flat('{"a":"\\uDBFF\\uDFFF"}', "a"), chr(0x10FFFF))
    # An absent member reads as "".
    var j = parse_flat_json('{"a":"b"}')
    assert_false(j.has("z"))
    assert_equal(j.get("z"), "")
    # Number, true/false/null members are skipped, not kept.
    var k = parse_flat_json('{"n": -1.5E+3, "t": true, "z": null, "s": "x"}')
    assert_false(k.has("n"))
    assert_false(k.has("t"))
    assert_equal(k.get("s"), "x")
    assert_equal(len(parse_flat_json("  {  }  ").keys), 0)


def test_flat_json_refusals() raises:
    _flat_refused('{"a":"\\u00g9"}', "bad \\u escape")
    _flat_refused('{"a":"\\u0', "short \\u escape")
    _flat_refused('{"a":"' + chr(1) + '"}', "control byte in a string")
    _flat_refused('{"a":"\\', "unterminated escape")
    _flat_refused('{"a":"abc', "unterminated string")
    _flat_refused('{"a":"\\x"}', "bad escape")
    # A high surrogate alone, before a non-escape, or before a non-low
    # escape; a low surrogate alone.
    _flat_refused('{"a":"\\ud83d"}', "unpaired surrogate")
    _flat_refused('{"a":"\\ud83dxxxxxx"}', "unpaired surrogate")
    _flat_refused('{"a":"\\ud83d\\nxxxx"}', "unpaired surrogate")
    _flat_refused('{"a":"\\ud83d\\u0041"}', "unpaired surrogate")
    _flat_refused('{"a":"\\ud83d\\uE000"}', "unpaired surrogate")
    _flat_refused('{"a":"\\ude00"}', "unpaired surrogate")
    _flat_refused("[]", "expected '{'")
    _flat_refused("", "expected '{'")
    _flat_refused('{"a":"b",}', "expected a member name")
    _flat_refused('{"a" "b"}', "expected ':'")
    _flat_refused('{"a":', "expected a value")
    _flat_refused('{"a":}', "expected a value")
    _flat_refused('{"a":[1]}', "nested value")
    _flat_refused('{"a":"b" "c"}', "expected ',' or '}'")
    _flat_refused('{"a":"b"', "expected ',' or '}'")
    _flat_refused("{} x", "text after the object")


def test_top_level_strings() raises:
    # Nested values are skipped whole, strings inside them included.
    var j = parse_top_level_strings(
        '{"__type":"T","x":{"y":["}",{"z":"]"}]},"n":1,"message":"m"}'
    )
    assert_equal(j.get("__type"), "T")
    assert_equal(j.get("message"), "m")
    assert_false(j.has("x"))
    assert_equal(len(parse_top_level_strings("{}").keys), 0)
    _top_refused("[1]", "expected '{'")
    _top_refused('{"a":[1,2', "unterminated nested value")
    _top_refused('{"a":1,}', "expected a member name")
    _top_refused('{"a" 1}', "expected ':'")
    _top_refused('{"a": ', "expected a value")
    _top_refused('{"a":1 2}', "expected ',' or '}'")
    _top_refused('{"a":1}}', "text after the object")


# -----------------------------------------------------------------------------
# UTF-8 (RFC 3629) past the second byte
# -----------------------------------------------------------------------------


def _hex(h: String) -> List[UInt8]:
    """The bytes of a hex string ("E282AC")."""
    var b = h.as_bytes()
    var out = List[UInt8]()
    for i in range(0, len(b), 2):
        var v = 0
        for k in range(2):
            var c = Int(b[i + k])
            v = v * 16 + (c - 0x30 if c <= 0x39 else c - 0x41 + 10)
        out.append(UInt8(v))
    return out^


def _utf8_ok(h: String) -> Bool:
    var b = _hex(h)
    try:
        _ = CredentialHttpResponse.of_bytes(200, Span(b))
        return True
    except:
        return False


def test_utf8_continuation_bytes() raises:
    # U+20AC and U+1F600 are well formed.
    assert_true(_utf8_ok("E282AC"))
    assert_true(_utf8_ok("F09F9880"))
    # A third or fourth byte that is not 10xxxxxx is not.
    assert_false(_utf8_ok("E28241"))
    assert_false(_utf8_ok("E282C0"))
    assert_false(_utf8_ok("F09F4180"))
    assert_false(_utf8_ok("F09F9841"))
    assert_false(_utf8_ok("F09F98FF"))


# -----------------------------------------------------------------------------
# Timestamps
# -----------------------------------------------------------------------------


def _iso_refused(text: String, want: String) raises:
    try:
        _ = aws_ts_from_text(text, AWS_TS_ISO8601)
    except e:
        assert_equal(String(e), want, text)
        return
    raise Error("an ISO 8601 date-time was accepted: " + text)


def test_iso8601_malformed() raises:
    assert_equal(aws_ts_from_text("2026-09-15T13:00:00+01:00", AWS_TS_ISO8601), 1789473600.0)
    _iso_refused("2026-09-15T00:00:00+0", "an AWS timestamp is truncated")
    _iso_refused("2026-09-15T00:00:00+01", "an AWS timestamp is malformed")
    _iso_refused("2026/09-15T00:00:00Z", "an AWS timestamp is malformed")
    _iso_refused("2026-09/15T00:00:00Z", "an AWS timestamp is malformed")
    _iso_refused("2026-09-15T00-00:00Z", "an AWS timestamp is malformed")
    _iso_refused("2026-09-15T00:00-00Z", "an AWS timestamp is malformed")
    _iso_refused("2026-09-15X00:00:00Z", "an AWS timestamp is malformed")
    _iso_refused("2026-09-15T00:00:00.Z", "an AWS timestamp has an empty fraction")
    _iso_refused("2026-09-15T00:00:00Zx", "an AWS timestamp has text after it")
    _iso_refused("2026-09-15T00:00:00+01:00x", "an AWS timestamp has text after it")


def _date_refused(text: String, want: String) raises:
    try:
        _ = aws_http_date_from_text(text)
    except e:
        assert_equal(String(e), want, text)
        return
    raise Error("an http-date was accepted: " + text)


def test_http_date_malformed() raises:
    # Each fixed separator of `Www, DD Mmm YYYY HH:MM:SS GMT` (RFC 9110
    # section 5.6.7), and a non-digit in a two-digit field.
    assert_equal(aws_http_date_from_text("Tue, 15 Sep 2026 12:00:00 GMT"), 1789473600.0)
    var bad = String("an AWS http-date is malformed")
    _date_refused("Tue; 15 Sep 2026 12:00:00 GMT", bad)
    _date_refused("Tue,x15 Sep 2026 12:00:00 GMT", bad)
    _date_refused("Tue, 1x Sep 2026 12:00:00 GMT", bad)
    _date_refused("Tue, x5 Sep 2026 12:00:00 GMT", bad)
    _date_refused("Tue, 15xSep 2026 12:00:00 GMT", bad)
    _date_refused("Tue, 15 Sepx2026 12:00:00 GMT", bad)
    _date_refused("Tue, 15 Sep 2026x12:00:00 GMT", bad)
    _date_refused("Tue, 15 Sep 2026 12x00:00 GMT", bad)
    _date_refused("Tue, 15 Sep 2026 12:00x00 GMT", bad)
    _date_refused("Tue, 15 Sep 2026 12:00:0x GMT", bad)


def test_aws_json_tokens() raises:
    # A Float32 NaN is the string "NaN" (awsJson's special floats).
    var z = Float32(0.0)
    var t = aws_token_f32(z / z)
    assert_equal(t.kind, AWS_JSON_STRING)
    assert_equal(t.text, "NaN")
    assert_true(t.is_string())
    assert_false(t.is_number())
    assert_true(AwsJsonToken(AWS_JSON_NUMBER, "1").is_number())
    try:
        _ = aws_ts_from_token(AwsJsonToken(AWS_JSON_BOOL, "true"))
        raise Error("a boolean timestamp was accepted")
    except e:
        assert_equal(
            String(e), "an awsJson timestamp is neither a number nor a string"
        )
    try:
        _ = aws_ts_from_token(AwsJsonToken(AWS_JSON_STRING, ""))
        raise Error("an empty timestamp was accepted")
    except e:
        assert_equal(String(e), "an awsJson number is empty")
    # 29 bytes is the only IMF-fixdate length; one more is refused.
    assert_equal(
        aws_ts_from_token(AwsJsonToken(AWS_JSON_STRING, "Tue, 15 Sep 2026 12:00:00 GMT")),
        1789473600.0,
    )
    try:
        _ = aws_ts_from_token(
            AwsJsonToken(AWS_JSON_STRING, "Tue, 15 Sep 2026 12:00:00 GMTx")
        )
        raise Error("a 30-byte http-date was accepted")
    except e:
        assert_equal(String(e), "an AWS timestamp is malformed")


# -----------------------------------------------------------------------------
# restXml names, absent members, request ids
# -----------------------------------------------------------------------------


def _name_ok(name: String) -> Bool:
    var w = XmlWriter()
    try:
        aws_xml_start(w, name)
        aws_xml_end(w)
        return True
    except:
        return False


def test_xml_multibyte_names() raises:
    # XML 1.0 NameStartChar by code point, decoded from 3- and 4-byte UTF-8:
    # U+3001 and U+10000 start a name; U+3000 and U+F0000 do not.
    assert_true(_name_ok(chr(0x3001)))
    assert_true(_name_ok("a" + chr(0x3001)))
    assert_false(_name_ok(chr(0x3000)))
    assert_true(_name_ok(chr(0x10000)))
    assert_true(_name_ok(chr(0xEFFFF)))
    assert_false(_name_ok(chr(0xF0000)))
    # Two-byte: U+00B7 continues a name but does not start one.
    assert_true(_name_ok("a" + chr(0xB7)))
    assert_false(_name_ok(chr(0xB7)))


def test_xml_absent_members() raises:
    var root = aws_xml_parse(_bytes("<S><A>1</A></S>"))
    assert_true(not aws_xml_get_bool(root, "Z"))
    assert_true(not aws_xml_get_f64(root, "Z"))
    assert_true(not aws_xml_get_f32(root, "Z"))
    assert_true(not aws_xml_get_blob(root, "Z"))
    assert_true(not aws_xml_get_ts(root, "Z", AWS_TS_ISO8601))
    # A blob element holding elements is refused.
    var b = aws_xml_parse(_bytes("<B><x/></B>"))
    try:
        _ = aws_xml_blob_of(b)
        raise Error("a blob with child elements was accepted")
    except e:
        assert_equal(String(e), "the AWS XML scalar <B> holds child elements")


def test_xml_request_ids() raises:
    var body = _bytes(
        "<Error><Code>C</Code><RequestId>R1</RequestId></Error>"
    )
    # A request id with a space, a control byte or DEL, or over
    # AWS_REQUEST_ID_MAX_BYTES (128) is dropped; the body's is read instead.
    assert_equal(aws_xml_error_info(400, body, "a b").request_id, "R1")
    assert_equal(aws_xml_error_info(400, body, "a\tb").request_id, "R1")
    assert_equal(aws_xml_error_info(400, body, "ab" + chr(0x7F)).request_id, "R1")
    var max_id = String("")
    for _ in range(128):
        max_id += "r"
    assert_equal(aws_xml_error_info(400, body, max_id).request_id, max_id)
    assert_equal(aws_xml_error_info(400, body, max_id + "r").request_id, "R1")
    assert_equal(aws_xml_error_info(400, body, "ab").request_id, "ab")
    var spaced = _bytes(
        "<Error><Code>C</Code><RequestId>R 1</RequestId></Error>"
    )
    assert_equal(aws_xml_error_info(400, spaced, "").request_id, "")


# -----------------------------------------------------------------------------
# Request headers, host prefixes, Content-Range
# -----------------------------------------------------------------------------


def test_request_header_and_host_prefix() raises:
    var req = AwsRequest("GET", "/")
    try:
        req.set_header("", "v")
        raise Error("an empty header name was accepted")
    except e:
        assert_equal(String(e), "an AWS request header has an empty name")
    try:
        var names = List[String]()
        names.append("A")
        names.append("B")
        var values = List[String]()
        values.append("x")
        _ = aws_host_prefix("{A}.", names, values)
        raise Error("host labels of unequal lengths were accepted")
    except e:
        assert_equal(
            String(e), "AWS host labels: names and values differ in length"
        )


def test_content_range_without_first_last() raises:
    try:
        _ = s3_content_range_total("bytes 5/10")
        raise Error("a range without '-' was accepted")
    except e:
        assert_equal(String(e), "Content-Range 'bytes 5/10' has no 'first-last'")


# -----------------------------------------------------------------------------
# SigV4
# -----------------------------------------------------------------------------


def _ctx() -> SigV4SigningContext:
    return SigV4SigningContext(
        AwsCredential(
            String("AKIDEXAMPLE"),
            String("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"),
            String(""),
        ),
        "us-east-1",
        "service",
        "20260915T120000Z",
    )


def _sign_refused(method: String, payload_hash: String, want: String) raises:
    var headers = List[Header]()
    headers.append(Header(String("Host"), String("example.amazonaws.com")))
    try:
        _ = sigv4_sign_payload_hash(method, "/", headers, payload_hash, _ctx())
    except e:
        assert_equal(String(e), want)
        return
    raise Error("signed: method '" + method + "', hash '" + payload_hash + "'")


def test_sigv4_token_checks() raises:
    _sign_refused("", EMPTY_PAYLOAD_SHA256, "SigV4: the method is empty")
    _sign_refused("GE T", EMPTY_PAYLOAD_SHA256, "SigV4: the method holds whitespace or a control byte")
    _sign_refused("GET" + chr(0x7F), EMPTY_PAYLOAD_SHA256, "SigV4: the method holds whitespace or a control byte")
    _sign_refused("GET", "", "SigV4: the payload hash is empty")
    _sign_refused("GET", "ab\tcd", "SigV4: the payload hash holds whitespace or a control byte")


def test_sigv4_percent_decoding() raises:
    # A parameter is decoded, then encoded the SigV4 way (upper-case hex),
    # whichever case its hex digits arrived in; '%' before a non-hex pair
    # is a literal '%'.
    assert_equal(canonical_query("a%2fb=%7e"), "a%2Fb=~")
    assert_equal(canonical_query("a%2Fb=%7E"), "a%2Fb=~")
    assert_equal(canonical_query("k=%c3%a9"), "k=%C3%A9")
    assert_equal(canonical_query("k=%zz"), "k=%25zz")
    assert_equal(canonical_query("k=%2g"), "k=%252g")
    assert_equal(canonical_query("k=%g2"), "k=%25g2")
    # An empty path is "/" with or without normalization.
    assert_equal(canonical_uri("", False, False), "/")
    assert_equal(canonical_uri("", False, True), "/")


def main() raises:
    var failed = 0
    try:
        test_flat_json_escapes()
    except e:
        print("FAIL test_flat_json_escapes:", e)
        failed += 1
    try:
        test_flat_json_refusals()
    except e:
        print("FAIL test_flat_json_refusals:", e)
        failed += 1
    try:
        test_top_level_strings()
    except e:
        print("FAIL test_top_level_strings:", e)
        failed += 1
    try:
        test_utf8_continuation_bytes()
    except e:
        print("FAIL test_utf8_continuation_bytes:", e)
        failed += 1
    try:
        test_iso8601_malformed()
    except e:
        print("FAIL test_iso8601_malformed:", e)
        failed += 1
    try:
        test_http_date_malformed()
    except e:
        print("FAIL test_http_date_malformed:", e)
        failed += 1
    try:
        test_aws_json_tokens()
    except e:
        print("FAIL test_aws_json_tokens:", e)
        failed += 1
    try:
        test_xml_multibyte_names()
    except e:
        print("FAIL test_xml_multibyte_names:", e)
        failed += 1
    try:
        test_xml_absent_members()
    except e:
        print("FAIL test_xml_absent_members:", e)
        failed += 1
    try:
        test_xml_request_ids()
    except e:
        print("FAIL test_xml_request_ids:", e)
        failed += 1
    try:
        test_request_header_and_host_prefix()
    except e:
        print("FAIL test_request_header_and_host_prefix:", e)
        failed += 1
    try:
        test_content_range_without_first_last()
    except e:
        print("FAIL test_content_range_without_first_last:", e)
        failed += 1
    try:
        test_sigv4_token_checks()
    except e:
        print("FAIL test_sigv4_token_checks:", e)
        failed += 1
    try:
        test_sigv4_percent_decoding()
    except e:
        print("FAIL test_sigv4_percent_decoding:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("OK")
