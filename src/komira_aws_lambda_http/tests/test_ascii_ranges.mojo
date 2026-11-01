# =============================================================================
# tests/test_ascii_ranges.mojo: both ends of every ASCII character range the
#   API Gateway 2.0 converter tests a byte against.
# =============================================================================
# An inclusive range check (`b >= 0x41 and b <= 0x5A`) is pinned only by a
# fixture holding the first and the last character of the range, and the
# character just outside each end. The other test files spell the authorizer
# prefix `Authz`, with a lower-case z, so a fold that stopped at `Y` passed
# them all while a forged `X-EXAMPLE-AUTHZ-*` header escaped the strip.
#
# - the header-name fold (`_ascii_lower`), seen through the inbound headers,
#   the authorizer context keys and the outbound headers: `A` and `Z` lowered,
#   `@` and `[` (the bytes beside them) left alone;
# - the prefix check: an upper-case `A` or `Z` alone is refused as UPPER-CASE,
#   `@` and `[` are refused as non-token bytes, and a prefix whose only letter
#   or digit is `a`, `z`, `0` or `9` names a namespace while one of only a
#   backtick (a token byte beside `a`) does not;
# - the RFC 9110 token check of a context key (`_is_tchar`): every one of the
#   fifteen token punctuation bytes and both ends of each letter and digit
#   range is accepted, and every byte beside a range end, every other
#   printable punctuation byte, a control byte and DEL are refused.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http_core.codec.types import HttpResponse

from komira_json import parse_json_value

from komira_aws_lambda_http.apigw_v2 import (
    AuthorizerHeaderPrefix,
    api_gateway_v2_event_to_request,
    response_to_api_gateway_v2,
)


comptime _PREFIX: String = "x-example-authz-"


def _prefix() raises -> AuthorizerHeaderPrefix:
    return AuthorizerHeaderPrefix(String(_PREFIX))


def _header(req_headers: Dict[String, String], name: String) raises -> String:
    if name not in req_headers:
        raise Error(String("expected header absent: ") + name)
    return req_headers[name]


def _hex2(b: Int) -> String:
    var digits = String("0123456789abcdef")
    var d = digits.as_bytes()
    return chr(Int(d[(b >> 4) & 0xF])) + chr(Int(d[b & 0xF]))


def _json_u(b: Int) -> String:
    """The JSON escape of one byte below 0x80, `\\u00HH`, so a key may hold a
    quote, a backslash or a control byte without a hand-written escape."""
    return String("\\u00") + _hex2(b)


def _event_with_context_key(key_json: String) -> String:
    return (
        String(
            '{"version": "2.0", "rawPath": "/private", "rawQueryString": "",'
            '"requestContext": {"http": {"method": "GET"},'
            '"authorizer": {"lambda": {"'
        )
        + key_json
        + String('": "v"}}}}')
    )


# =============================================================================
# §1 the header-name fold, A through Z and nothing beside them.
# =============================================================================

def test_an_inbound_header_name_is_lowered_from_A_through_Z_only() raises:
    """FALSIFIES a fold whose range is one short at either end (`A` or `Z`
    kept) or one long (`@` turned into a backtick, `[` into `{`): the whole
    alphabet must arrive lower-cased and `x@[` byte for byte."""
    var event = String(
        '{"version": "2.0", "rawPath": "/fold", "rawQueryString": "",'
        '"headers": {"ABCDEFGHIJKLMNOPQRSTUVWXYZ": "upper",'
        '"X@[": "beside"},'
        '"requestContext": {"http": {"method": "GET"}}}'
    )
    var req = api_gateway_v2_event_to_request(event, _prefix())
    assert_equal(
        _header(req.headers, String("abcdefghijklmnopqrstuvwxyz")),
        String("upper"),
    )
    assert_equal(_header(req.headers, String("x@[")), String("beside"))
    assert_equal(len(req.headers), 2)


def test_a_forged_header_in_capitals_with_a_Z_is_stripped() raises:
    """⛔ The security consequence of a fold that stops before `Z`: the client
    header `X-EXAMPLE-AUTHZ-ZONE` would lower to `x-example-authz-zone` with
    an upper-case Z left in it, miss the prefix, and reach the dispatcher. It
    must be dropped, and `X-Zone` (the non-empty arm) must arrive as
    `x-zone`."""
    var event = String(
        '{"version": "2.0", "rawPath": "/public", "rawQueryString": "",'
        '"headers": {"X-EXAMPLE-AUTHZ-ZONE": "forged", "X-Zone": "eu"},'
        '"requestContext": {"http": {"method": "GET"}}}'
    )
    var req = api_gateway_v2_event_to_request(event, _prefix())
    assert_equal(_header(req.headers, String("x-zone")), String("eu"))
    assert_equal(len(req.headers), 1)


def test_a_context_key_is_lowered_through_Z() raises:
    """The injected name is `<prefix>` plus the key lower-cased: `AZ` must
    become `az`, so a handler reading `x-example-authz-az` finds it."""
    var req = api_gateway_v2_event_to_request(
        _event_with_context_key(String("AZ")), _prefix()
    )
    assert_equal(
        _header(req.headers, String(_PREFIX) + String("az")), String("v")
    )
    assert_equal(len(req.headers), 1)


def test_an_outbound_header_name_is_lowered_through_Z() raises:
    """The response's header names go out lower-cased: `X-ZONE` as
    `x-zone`, and no `X-ZONE` member."""
    var r = HttpResponse(status=Int32(200))
    r.headers[String("X-ZONE")] = String("eu")
    var h = parse_json_value(response_to_api_gateway_v2(r^)).get(
        String("headers")
    )
    assert_true(h.has(String("x-zone")))
    assert_equal(h.get(String("x-zone")).as_string(), String("eu"))
    assert_equal(h.num_members(), 1)


# =============================================================================
# §2 the prefix check.
# =============================================================================

def _prefix_must_be_refused(prefix: String, mention: String) raises:
    var raised = False
    try:
        var p = AuthorizerHeaderPrefix(prefix)
        _ = p.value()
    except e:
        raised = True
        if String(e).find(mention) < 0:
            raise Error(
                String("prefix '")
                + prefix
                + String("' refused for the wrong reason: ")
                + String(e)
            )
    if not raised:
        raise Error(String("expected the prefix to be REFUSED: ") + prefix)


def test_a_prefix_whose_only_capital_is_A_or_Z_is_refused() raises:
    """FALSIFIES an upper-case check one short at either end: `x-Aa-` and
    `x-authZ-` would be accepted, and since client names are lower-cased
    before the compare, `x-authZ-` would strip no forged header at all."""
    _prefix_must_be_refused(String("x-Aa-"), String("UPPER-CASE"))
    _prefix_must_be_refused(String("x-authZ-"), String("UPPER-CASE"))


def test_the_bytes_beside_the_capitals_are_refused_as_non_tokens() raises:
    """`@` (0x40) and `[` (0x5B) are refused as non-token bytes, not as
    capitals: an upper-case check one long at either end names the wrong
    rule."""
    _prefix_must_be_refused(String("x-@-"), String("token character"))
    _prefix_must_be_refused(String("x-[-"), String("token character"))


def test_a_prefix_whose_only_alnum_ends_a_range_names_a_namespace() raises:
    """`a-`, `z-`, `0-` and `9-` each hold one letter or digit, at an end of
    its range, and are accepted as given. A backtick is a token byte just
    below `a` and no letter: `` `- `` is refused as naming nothing."""
    assert_equal(AuthorizerHeaderPrefix(String("a-")).value(), String("a-"))
    assert_equal(AuthorizerHeaderPrefix(String("z-")).value(), String("z-"))
    assert_equal(AuthorizerHeaderPrefix(String("0-")).value(), String("0-"))
    assert_equal(AuthorizerHeaderPrefix(String("9-")).value(), String("9-"))
    _prefix_must_be_refused(String("`-"), String("no letter or digit"))


# =============================================================================
# §3 the token check of a context key.
# =============================================================================

def test_every_token_byte_is_accepted_in_a_context_key() raises:
    """Each of RFC 9110's fifteen token punctuation bytes, and both ends of
    the letter and digit ranges, in a key of its own (`k` then the byte): the
    member is injected as `<prefix>k<byte>`, the letter lower-cased.

    FALSIFIES a token check missing any one of them, or one short at either
    end of a range: that key would be skipped."""
    var accepted = List[Int]()
    var punct_text = String("!#$%&'*+-.^_`|~")
    var punct = punct_text.as_bytes()
    for i in range(len(punct)):
        accepted.append(Int(punct[i]))
    var ends: List[Int] = [0x41, 0x5A, 0x61, 0x7A, 0x30, 0x39]
    for i in range(len(ends)):
        accepted.append(ends[i])
    assert_equal(len(accepted), 21)
    for i in range(len(accepted)):
        var b = accepted[i]
        var req = api_gateway_v2_event_to_request(
            _event_with_context_key(String("k") + _json_u(b)), _prefix()
        )
        var lowered = b
        if b >= 0x41 and b <= 0x5A:
            lowered = b + 32
        var name = String(_PREFIX) + String("k") + chr(lowered)
        if name not in req.headers or len(req.headers) != 1:
            raise Error(
                String("token byte 0x")
                + _hex2(b)
                + String(" in a context key was not injected as ")
                + name
            )


def test_every_non_token_byte_is_refused_in_a_context_key() raises:
    """The byte beside each range end (`/` `:` `@` `[` `{`), every other
    printable ASCII byte outside the token set (space, quote, parentheses,
    comma, `;<=>?`, backslash, `]`, `}`), a control byte and DEL: each key is
    skipped and nothing is injected.

    FALSIFIES a token check one long at a range end, or one whose
    punctuation test names a neighbour of a token byte (`"` for `!`, `(` for
    `'`, `,` for `+`, `/` for `.`, `]` for `^`, `}` for `|` or `~`)."""
    var refused: List[Int] = [
        0x1F, 0x20, 0x22, 0x28, 0x29, 0x2C, 0x2F, 0x3A, 0x3B, 0x3C, 0x3D,
        0x3E, 0x3F, 0x40, 0x5B, 0x5C, 0x5D, 0x7B, 0x7D, 0x7F,
    ]
    for i in range(len(refused)):
        var b = refused[i]
        var req = api_gateway_v2_event_to_request(
            _event_with_context_key(String("k") + _json_u(b)), _prefix()
        )
        if len(req.headers) != 0:
            raise Error(
                String("non-token byte 0x")
                + _hex2(b)
                + String(" in a context key was injected")
            )


def main() raises:
    test_an_inbound_header_name_is_lowered_from_A_through_Z_only()
    test_a_forged_header_in_capitals_with_a_Z_is_stripped()
    test_a_context_key_is_lowered_through_Z()
    test_an_outbound_header_name_is_lowered_through_Z()
    test_a_prefix_whose_only_capital_is_A_or_Z_is_refused()
    test_the_bytes_beside_the_capitals_are_refused_as_non_tokens()
    test_a_prefix_whose_only_alnum_ends_a_range_names_a_namespace()
    test_every_token_byte_is_accepted_in_a_context_key()
    test_every_non_token_byte_is_refused_in_a_context_key()

    print("test_ascii_ranges: ALL PASS")
