# =============================================================================
# tests/test_apigw_v2_edges.mojo: the API Gateway 2.0 converter's edges that
#   `test_apigw_v2.mojo` leaves out, in both directions.
# =============================================================================
# INBOUND: a 2.0 event with no `requestContext`, a `requestContext` that is
# not an object, a cookie array holding non-strings, an authorizer `lambda`
# member that is not an object, a null body and a non-string body, a
# non-boolean `isBase64Encoded`, non-string `rawPath` / `method`, and every
# verb of the method table (not only GET and POST).
#
# OUTBOUND: the strict UTF-8 check that decides `isBase64Encoded`, swept over
# every lead-byte range and every boundary it rejects: the smallest and the
# largest code point of each sequence length (accepted, sent as text), the
# overlong one just below each length's floor, both ends of the surrogate
# range, the first code point above U+10FFFF, lead bytes outside the table,
# a bad continuation byte, and a sequence cut short at the end of the body
# (all rejected, sent as base64 and round-tripped to the identical bytes),
# and a valid sequence that is the last thing in the body (sent as text).
#
# Every refusal asserts a phrase of ITS OWN message, so a converter that raised
# for another reason (a JSON accessor on the wrong kind) does not pass.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec.types import (
    HTTP_METHOD_DELETE,
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_OPTIONS,
    HTTP_METHOD_PATCH,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
    HTTP_METHOD_UNKNOWN,
    HttpResponse,
)

from komira_json import parse_json_value
from komira_encoding import base64_decode

from komira_aws_lambda_http.apigw_v2 import (
    AuthorizerHeaderPrefix,
    api_gateway_v2_event_to_request,
    response_to_api_gateway_v2,
)


comptime _PREFIX: String = "x-example-authz-"


def _prefix() raises -> AuthorizerHeaderPrefix:
    return AuthorizerHeaderPrefix(String(_PREFIX))


def _event(
    method_json: String,
    extra_members: String,
    request_context_extra: String = String(""),
) -> String:
    """A minimal 2.0 event: `version`, `rawPath`, `requestContext.http.method`
    set to `method_json` (raw JSON), plus `extra_members` (raw JSON members,
    each followed by a comma) and `request_context_extra` (raw JSON members of
    `requestContext`, each preceded by a comma)."""
    return (
        String('{"version": "2.0", "rawPath": "/edge", ')
        + extra_members
        + String('"requestContext": {"http": {"method": ')
        + method_json
        + String("}")
        + request_context_extra
        + String("}}")
    )


def _must_raise_naming(event: String, needle: String) raises:
    var raised = False
    var msg = String("")
    try:
        var req = api_gateway_v2_event_to_request(event, _prefix())
        _ = req.path
    except e:
        raised = True
        msg = String(e)
    if not raised:
        raise Error(String("expected a refusal naming: ") + needle)
    if msg.find(needle) < 0:
        raise Error(
            String("refusal does not name '") + needle + String("': ") + msg
        )


def _ascii(data: List[UInt8]) -> String:
    var out = String("")
    for i in range(len(data)):
        out += chr(Int(data[i]))
    return out^


# =============================================================================
# §1 INBOUND refusals.
# =============================================================================

def test_refuses_a_2_0_event_with_no_request_context() raises:
    """No `requestContext` at all: there is no method to route on. The message
    is the converter's own, not a JSON accessor's `object has no key`."""
    _must_raise_naming(
        String('{"version": "2.0", "rawPath": "/edge"}'),
        String("carries no `requestContext`"),
    )


def test_refuses_a_request_context_that_is_not_an_object() raises:
    """`requestContext` is a string: refused as `requestContext.http` absent,
    not by `get()` on a non-object."""
    _must_raise_naming(
        String('{"version": "2.0", "rawPath": "/edge", "requestContext": "x"}'),
        String("`requestContext.http` is absent"),
    )


def test_refuses_a_request_context_with_no_http_naming_the_field() raises:
    """`requestContext` is an object without `http`: the same refusal, by
    name (`test_apigw_v2.mojo` asserts only that something raised)."""
    _must_raise_naming(
        String(
            '{"version": "2.0", "rawPath": "/edge", "requestContext": {}}'
        ),
        String("`requestContext.http` is absent"),
    )


def test_refuses_a_body_that_is_not_a_string() raises:
    """A number and a boolean `body`: API Gateway only ever sends a string."""
    _must_raise_naming(
        _event(String('"POST"'), String('"body": 17, ')),
        String("`body` is present but is not a JSON string"),
    )
    _must_raise_naming(
        _event(String('"POST"'), String('"body": true, ')),
        String("`body` is present but is not a JSON string"),
    )


def test_two_faults_report_the_missing_request_context_first() raises:
    """No `requestContext` AND a non-string `body`: the routing refusal is the
    one reported, because the request has nothing to route on before its body
    is read."""
    _must_raise_naming(
        String('{"version": "2.0", "rawPath": "/edge", "body": 17}'),
        String("carries no `requestContext`"),
    )


# =============================================================================
# §2 INBOUND values.
# =============================================================================

def test_a_null_body_is_empty_not_a_refusal() raises:
    """`"body": null` is what API Gateway sends for a GET with no body: zero
    bytes, and no refusal."""
    var req = api_gateway_v2_event_to_request(
        _event(String('"GET"'), String('"body": null, ')), _prefix()
    )
    assert_equal(len(req.body), 0)
    assert_equal(req.path, String("/edge"))


def test_a_non_boolean_base64_flag_does_not_decode() raises:
    """`"isBase64Encoded": "true"` (a string, not the boolean) leaves the body
    as its text: only a JSON `true` declares base64."""
    var req = api_gateway_v2_event_to_request(
        _event(
            String('"POST"'),
            String('"body": "aGk=", "isBase64Encoded": "true", '),
        ),
        _prefix(),
    )
    assert_equal(_ascii(req.body), String("aGk="))


def test_non_string_cookies_are_skipped_and_the_rest_joined() raises:
    """A cookie array with a number, a null and an object between two strings:
    the strings are joined in order, the others are skipped, not stringified."""
    var req = api_gateway_v2_event_to_request(
        _event(
            String('"GET"'),
            String('"cookies": ["a=1", 7, null, {"b": 2}, "c=3"], '),
        ),
        _prefix(),
    )
    assert_equal(req.headers[String("cookie")], String("a=1; c=3"))


def test_non_string_cookies_first_add_no_leading_separator() raises:
    """Non-strings BEFORE the first string: the separator goes between joined
    cookies, so the header starts with the first string, not with `; `."""
    var req = api_gateway_v2_event_to_request(
        _event(
            String('"GET"'),
            String('"cookies": [7, null, "a=1", "c=3"], '),
        ),
        _prefix(),
    )
    assert_equal(req.headers[String("cookie")], String("a=1; c=3"))


def test_one_string_cookie_after_a_non_string_has_no_separator() raises:
    """One joinable cookie, not first in the array: no separator at all."""
    var req = api_gateway_v2_event_to_request(
        _event(String('"GET"'), String('"cookies": [false, "a=1"], ')),
        _prefix(),
    )
    assert_equal(req.headers[String("cookie")], String("a=1"))


def test_a_cookie_array_of_only_non_strings_adds_no_cookie_header() raises:
    """Nothing joinable: no `cookie` header at all, not an empty one."""
    var req = api_gateway_v2_event_to_request(
        _event(String('"GET"'), String('"cookies": [7, false], ')), _prefix()
    )
    assert_false(String("cookie") in req.headers)


def test_a_non_object_lambda_authorizer_injects_nothing() raises:
    """`requestContext.authorizer.lambda` is a string: no header under the
    prefix is injected and the conversion does not refuse. A client header
    under the prefix is still dropped."""
    var req = api_gateway_v2_event_to_request(
        _event(
            String('"GET"'),
            String('"headers": {"x-example-authz-sub": "forged", "a": "b"}, '),
            String(', "authorizer": {"lambda": "subject-real"}'),
        ),
        _prefix(),
    )
    for kv in req.headers.items():
        assert_false(String(kv.key).startswith(String(_PREFIX)))
    assert_equal(req.headers[String("a")], String("b"))


def test_non_string_path_and_method_read_as_empty() raises:
    """`rawPath` a number and `method` a number: the path is empty and the
    method UNKNOWN (the dispatcher answers that), not a refusal and not the
    number's text."""
    var req = api_gateway_v2_event_to_request(
        String(
            '{"version": "2.0", "rawPath": 5, "rawQueryString": true,'
            ' "requestContext": {"http": {"method": 7}}}'
        ),
        _prefix(),
    )
    assert_equal(req.path, String(""))
    assert_equal(req.query_string, String(""))
    assert_equal(req.method.code, HTTP_METHOD_UNKNOWN)


def _method_of(name: String) raises -> UInt8:
    var req = api_gateway_v2_event_to_request(
        _event(String('"') + name + String('"'), String("")), _prefix()
    )
    return req.method.code


def test_every_verb_of_the_table_maps_to_its_own_code() raises:
    """All seven verbs, upper and lower case, each to its own code, and a verb
    outside the table (and one that is a prefix of a table verb) to UNKNOWN."""
    assert_equal(_method_of(String("GET")), HTTP_METHOD_GET)
    assert_equal(_method_of(String("POST")), HTTP_METHOD_POST)
    assert_equal(_method_of(String("PUT")), HTTP_METHOD_PUT)
    assert_equal(_method_of(String("DELETE")), HTTP_METHOD_DELETE)
    assert_equal(_method_of(String("PATCH")), HTTP_METHOD_PATCH)
    assert_equal(_method_of(String("HEAD")), HTTP_METHOD_HEAD)
    assert_equal(_method_of(String("OPTIONS")), HTTP_METHOD_OPTIONS)
    assert_equal(_method_of(String("delete")), HTTP_METHOD_DELETE)
    assert_equal(_method_of(String("patch")), HTTP_METHOD_PATCH)
    assert_equal(_method_of(String("head")), HTTP_METHOD_HEAD)
    assert_equal(_method_of(String("options")), HTTP_METHOD_OPTIONS)
    assert_equal(_method_of(String("DEL")), HTTP_METHOD_UNKNOWN)
    assert_equal(_method_of(String("OPTION")), HTTP_METHOD_UNKNOWN)
    assert_equal(_method_of(String("TRACE")), HTTP_METHOD_UNKNOWN)


# =============================================================================
# §3 OUTBOUND: the UTF-8 discriminator of `isBase64Encoded`.
# =============================================================================

def _bytes(*values: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        out.append(UInt8(values[i]))
    return out^


def _framed(inner: List[UInt8]) -> List[UInt8]:
    """`inner` between two ASCII bytes, so a scan that mis-steps over the
    sequence lands on a byte it would judge differently."""
    var out = List[UInt8]()
    out.append(UInt8(0x61))
    for i in range(len(inner)):
        out.append(inner[i])
    out.append(UInt8(0x7A))
    return out^


def _emit(body: List[UInt8]) raises -> List[UInt8]:
    """Serialize a response carrying `body` and return the bytes a client gets
    back from it (base64-decoded when the flag says so, else the text's)."""
    var r = HttpResponse(status=Int32(200))
    for i in range(len(body)):
        r.body.append(body[i])
    var v = parse_json_value(response_to_api_gateway_v2(r^))
    if v.get(String("isBase64Encoded")).as_bool():
        return base64_decode(v.get(String("body")).as_string())
    var out = List[UInt8]()
    var bs = v.get(String("body")).as_string().as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _is_b64(body: List[UInt8]) raises -> Bool:
    var r = HttpResponse(status=Int32(200))
    for i in range(len(body)):
        r.body.append(body[i])
    var v = parse_json_value(response_to_api_gateway_v2(r^))
    return v.get(String("isBase64Encoded")).as_bool()


def _same(a: List[UInt8], b: List[UInt8]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _text_case(inner: List[UInt8], what: String) raises:
    var body = _framed(inner)
    if _is_b64(body):
        raise Error(String("valid UTF-8 sent as base64: ") + what)
    if not _same(_emit(body), body):
        raise Error(String("text body did not round-trip: ") + what)


def _b64_case(body: List[UInt8], what: String) raises:
    if not _is_b64(body):
        raise Error(String("invalid UTF-8 sent as text: ") + what)
    if not _same(_emit(body), body):
        raise Error(String("base64 body did not round-trip: ") + what)


def test_valid_utf8_at_every_length_boundary_goes_out_as_text() raises:
    """The smallest and the largest code point of each sequence length, the two
    neighbours of the surrogate range, and the last code point: each is valid
    and must be sent as text, byte for byte."""
    _text_case(_bytes(0x7F), String("U+007F, largest 1-byte"))
    _text_case(_bytes(0xC2, 0x80), String("U+0080, smallest 2-byte"))
    _text_case(_bytes(0xC3, 0xA9), String("U+00E9"))
    _text_case(_bytes(0xDF, 0xBF), String("U+07FF, largest 2-byte"))
    _text_case(_bytes(0xE0, 0xA0, 0x80), String("U+0800, smallest 3-byte"))
    _text_case(_bytes(0xE2, 0x82, 0xAC), String("U+20AC"))
    _text_case(_bytes(0xED, 0x9F, 0xBF), String("U+D7FF, below surrogates"))
    _text_case(_bytes(0xEE, 0x80, 0x80), String("U+E000, above surrogates"))
    _text_case(_bytes(0xEF, 0xBF, 0xBF), String("U+FFFF, largest 3-byte"))
    _text_case(
        _bytes(0xF0, 0x90, 0x80, 0x80), String("U+10000, smallest 4-byte")
    )
    _text_case(_bytes(0xF0, 0x9F, 0x98, 0x80), String("U+1F600"))
    _text_case(_bytes(0xF4, 0x8F, 0xBF, 0xBF), String("U+10FFFF, the last"))
    _text_case(
        _bytes(0xC3, 0xA9, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98, 0x80),
        String("three lengths back to back"),
    )


def _text_body_case(body: List[UInt8], what: String) raises:
    """`body` as given, NOT framed: a valid sequence may end the body."""
    if _is_b64(body):
        raise Error(String("valid UTF-8 sent as base64: ") + what)
    if not _same(_emit(body), body):
        raise Error(String("text body did not round-trip: ") + what)


def test_valid_utf8_ending_the_body_goes_out_as_text() raises:
    """A valid multi-byte sequence as the LAST bytes of the body, at each
    length, after ASCII and alone: its final continuation byte is the body's
    last byte, so a scan whose end check is one byte too strict says base64."""
    _text_body_case(_bytes(0x61, 0xC3, 0xA9), String("a + U+00E9 at the end"))
    _text_body_case(
        _bytes(0x61, 0xE2, 0x82, 0xAC), String("a + U+20AC at the end")
    )
    _text_body_case(
        _bytes(0x61, 0xF0, 0x9F, 0x98, 0x80), String("a + U+1F600 at the end")
    )
    _text_body_case(_bytes(0xC2, 0x80), String("U+0080 alone"))
    _text_body_case(_bytes(0xE0, 0xA0, 0x80), String("U+0800 alone"))
    _text_body_case(_bytes(0xF0, 0x9F, 0x98, 0x80), String("U+1F600 alone"))
    _text_body_case(_bytes(0xF4, 0x8F, 0xBF, 0xBF), String("U+10FFFF alone"))


def test_overlong_surrogate_and_out_of_range_go_out_as_base64() raises:
    """The values a permissive decoder accepts and a strict one must not."""
    _b64_case(_framed(_bytes(0xC0, 0x80)), String("C0 lead, overlong NUL"))
    _b64_case(_framed(_bytes(0xC1, 0xBF)), String("C1 lead, overlong U+7F"))
    _b64_case(
        _framed(_bytes(0xE0, 0x9F, 0xBF)), String("overlong U+07FF in 3")
    )
    _b64_case(
        _framed(_bytes(0xF0, 0x8F, 0xBF, 0xBF)),
        String("overlong U+FFFF in 4"),
    )
    _b64_case(_framed(_bytes(0xED, 0xA0, 0x80)), String("U+D800"))
    _b64_case(_framed(_bytes(0xED, 0xBF, 0xBF)), String("U+DFFF"))
    _b64_case(
        _framed(_bytes(0xF4, 0x90, 0x80, 0x80)), String("U+110000")
    )
    _b64_case(
        _framed(_bytes(0xF5, 0x80, 0x80, 0x80)), String("F5 lead")
    )
    _b64_case(_framed(_bytes(0xFF)), String("FF lead"))
    _b64_case(_framed(_bytes(0x80)), String("continuation in lead"))
    _b64_case(_framed(_bytes(0xBF)), String("BF in lead"))
    _b64_case(_framed(_bytes(0xC3, 0xC0)), String("C0 as continuation"))
    _b64_case(_framed(_bytes(0xC3, 0x7F)), String("7F as continuation"))
    _b64_case(
        _framed(_bytes(0xE2, 0x82, 0x7A)), String("ASCII as 3rd byte")
    )


def test_a_sequence_cut_short_at_the_end_goes_out_as_base64() raises:
    """The last sequence of the body is missing its final continuation byte,
    at each length: the scan must not read past the end and must say base64."""
    _b64_case(_bytes(0x61, 0xC3), String("2-byte cut after the lead"))
    _b64_case(_bytes(0x61, 0xE2, 0x82), String("3-byte cut one short"))
    _b64_case(_bytes(0x61, 0xF0, 0x9F, 0x98), String("4-byte cut one short"))
    _b64_case(_bytes(0xF0), String("a lone 4-byte lead"))


def main() raises:
    test_refuses_a_2_0_event_with_no_request_context()
    test_refuses_a_request_context_that_is_not_an_object()
    test_refuses_a_request_context_with_no_http_naming_the_field()
    test_refuses_a_body_that_is_not_a_string()
    test_two_faults_report_the_missing_request_context_first()

    test_a_null_body_is_empty_not_a_refusal()
    test_a_non_boolean_base64_flag_does_not_decode()
    test_non_string_cookies_are_skipped_and_the_rest_joined()
    test_non_string_cookies_first_add_no_leading_separator()
    test_one_string_cookie_after_a_non_string_has_no_separator()
    test_a_cookie_array_of_only_non_strings_adds_no_cookie_header()
    test_a_non_object_lambda_authorizer_injects_nothing()
    test_non_string_path_and_method_read_as_empty()
    test_every_verb_of_the_table_maps_to_its_own_code()

    test_valid_utf8_at_every_length_boundary_goes_out_as_text()
    test_valid_utf8_ending_the_body_goes_out_as_text()
    test_overlong_surrogate_and_out_of_range_go_out_as_base64()
    test_a_sequence_cut_short_at_the_end_goes_out_as_base64()

    print("test_apigw_v2_edges: ALL PASS")
