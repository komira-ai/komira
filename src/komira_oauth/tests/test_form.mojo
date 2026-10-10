# =============================================================================
# test_form.mojo: the form encoding of form.mojo: what `encode()` keeps and
#   what it percent-encodes, byte by byte at every edge of the unreserved
#   set; and every refusal of `parse_form` at its boundary, beside the
#   accepted value on the other side of it.
# =============================================================================
#
# main runs every test and reports every failure.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_oauth import (
    OAUTH_FORM_MAX_BYTES,
    FormParams,
    form_encode_value,
    parse_form,
)


def _refusal(body: String) -> String:
    try:
        _ = parse_form(body)
    except e:
        return String(e)
    return String("accepted")


def _one(body: String) raises -> String:
    var p = parse_form(body)
    assert_equal(len(p), 1, "one pair")
    return p.values[0].copy()


def test_encode_keeps_unreserved() raises:
    var kept = String("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    assert_equal(form_encode_value(kept), kept)


def test_encode_escapes_everything_else() raises:
    # Each byte beside an unreserved range, and the rest of printable ASCII.
    assert_equal(
        form_encode_value(" !\"#$%&'()*+,/:;<=>?@[\\]^`{|}"),
        "%20%21%22%23%24%25%26%27%28%29%2A%2B%2C%2F%3A%3B%3C%3D%3E%3F%40%5B%5C%5D%5E%60%7B%7C%7D",
    )
    # Hex digits on both sides of 9/A, and a non-ASCII byte pair.
    assert_equal(form_encode_value("\t\n\x7f"), "%09%0A%7F")
    assert_equal(form_encode_value("é"), "%C3%A9")
    assert_equal(form_encode_value(""), "")


def test_encode_pairs() raises:
    var p = FormParams()
    p.add("grant_type", "client_credentials")
    p.add("a b", "c&d=e")
    p.add("empty", "")
    assert_equal(
        p.encode(), "grant_type=client_credentials&a%20b=c%26d%3De&empty="
    )
    assert_equal(FormParams().encode(), "")


def test_get() raises:
    var p = FormParams()
    p.add("resource", "r1")
    p.add("scope", "s")
    assert_equal(p.get("resource").value(), "r1")
    assert_equal(p.get("scope").value(), "s")
    assert_false(Bool(p.get("resourc")), "a prefix is not the name")
    assert_false(Bool(p.get("resources")), "an extension is not the name")
    assert_false(Bool(p.get("Resource")), "names are case-sensitive")
    assert_false(Bool(p.get("")), "the empty name")


def test_parse_accepts() raises:
    assert_equal(len(parse_form("")), 0)
    var p = parse_form("a=1&b=&c=x%20y+z")
    assert_equal(len(p), 3)
    assert_equal(p.names[0], "a")
    assert_equal(p.values[0], "1")
    assert_equal(p.names[1], "b")
    assert_equal(p.values[1], "")
    assert_equal(p.names[2], "c")
    assert_equal(p.values[2], "x y z")
    # The last pair's last byte is kept (no off-by-one at the end).
    assert_equal(_one("abc=xyz"), "xyz")
    assert_equal(parse_form("abc=xyz").names[0], "abc")
    # Hex digits: each end of each range, both cases.
    assert_equal(_one("v=%30%39%41%46%61%66"), "09AFaf")
    assert_equal(_one("v=%2b%2B%7e%7E"), "++~~")
    # The printable bounds, encoded.
    assert_equal(_one("v=%20"), " ")
    assert_equal(_one("v=%7E"), "~")
    # A % pair at the very end of the body.
    assert_equal(_one("v=a%41"), "aA")
    # An encoded name.
    assert_equal(parse_form("%61%20b=1").names[0], "a b")


def test_round_trip() raises:
    var p = FormParams()
    p.add("client_assertion", "eyJh.eyJp.c2ln-_")
    p.add("resource", "https://pdp.example/a?b=c&d")
    p.add("scope", "read write")
    var q = parse_form(p.encode())
    assert_equal(len(q), 3)
    for i in range(3):
        assert_equal(q.names[i], p.names[i])
        assert_equal(q.values[i], p.values[i])


def test_parse_refusals() raises:
    var empty = "OAuthError: the form has an empty pair"
    assert_equal(_refusal("&a=1"), empty)
    assert_equal(_refusal("a=1&"), empty)
    assert_equal(_refusal("a=1&&b=2"), empty)
    assert_equal(_refusal("&"), empty)
    var no_eq = "OAuthError: the form has a pair without ="
    assert_equal(_refusal("a"), no_eq)
    assert_equal(_refusal("a=1&b"), no_eq)
    assert_equal(_refusal("b&a=1"), no_eq)
    assert_equal(_refusal("=1"), "OAuthError: the form has a pair with an empty name")
    assert_equal(_refusal("a=1&=2"), "OAuthError: the form has a pair with an empty name")
    # `=` inside a value is kept: only the first one splits.
    assert_equal(_one("a=b=c"), "b=c")


def test_percent_refusals() raises:
    var bad = "OAuthError: the form has a % without two hex digits"
    assert_equal(_refusal("a=%"), bad)
    assert_equal(_refusal("a=%4"), bad)
    assert_equal(_refusal("a=%4&b=1"), bad)
    assert_equal(_refusal("%=1"), bad)
    # A byte beside each hex range, in each position.
    assert_equal(_refusal("a=%/0"), bad)
    assert_equal(_refusal("a=%:0"), bad)
    assert_equal(_refusal("a=%@0"), bad)
    assert_equal(_refusal("a=%G0"), bad)
    assert_equal(_refusal("a=%`0"), bad)
    assert_equal(_refusal("a=%g0"), bad)
    assert_equal(_refusal("a=%0/"), bad)
    assert_equal(_refusal("a=%0:"), bad)
    assert_equal(_refusal("a=%0@"), bad)
    assert_equal(_refusal("a=%0G"), bad)
    assert_equal(_refusal("a=%0`"), bad)
    assert_equal(_refusal("a=%0g"), bad)


def test_byte_refusals() raises:
    var bad = "OAuthError: the form holds a byte that is not printable ASCII"
    assert_equal(_refusal("a=%1F"), bad)
    assert_equal(_refusal("a=%7F"), bad)
    assert_equal(_refusal("a=%00"), bad)
    assert_equal(_refusal("a=%C3%A9"), bad)
    assert_equal(_refusal("a=é"), bad)
    assert_equal(_refusal("a=\t"), bad)
    assert_equal(_refusal("a=x\x7f"), bad)
    assert_equal(_refusal("%1F=1"), bad)
    # The last byte of a value is checked too.
    assert_equal(_refusal("a=xyz%1F"), bad)
    assert_equal(_refusal("a=xyz%1F&b=1"), bad)


def test_duplicate_refusals() raises:
    var twice = "OAuthError: the form names a parameter twice"
    assert_equal(_refusal("a=1&a=2"), twice)
    assert_equal(_refusal("a=1&a=1"), twice)
    assert_equal(_refusal("a=1&b=2&a=3"), twice)
    assert_equal(_refusal("b=1&a=2&c=3&a=4"), twice)
    # Names compared after decoding.
    assert_equal(_refusal("a=1&%61=2"), twice)
    # Near names are distinct.
    assert_equal(len(parse_form("a=1&ab=2&A=3&b=4")), 4)


def test_size_limit() raises:
    var buf = List[UInt8]()
    buf.append(0x61)  # 'a'
    buf.append(0x3D)  # '='
    while len(buf) < OAUTH_FORM_MAX_BYTES:
        buf.append(0x78)  # 'x'
    var at_limit = String(unsafe_from_utf8=Span(buf))
    assert_equal(at_limit.byte_length(), OAUTH_FORM_MAX_BYTES)
    assert_equal(len(parse_form(at_limit)), 1)
    assert_equal(
        _refusal(at_limit + "x"), "OAuthError: the form is longer than 65536 bytes"
    )


def main() raises:
    var failures = String("")
    try:
        test_encode_keeps_unreserved()
    except e:
        failures += String("test_encode_keeps_unreserved: ") + String(e) + "\n"
    try:
        test_encode_escapes_everything_else()
    except e:
        failures += String("test_encode_escapes_everything_else: ") + String(e) + "\n"
    try:
        test_encode_pairs()
    except e:
        failures += String("test_encode_pairs: ") + String(e) + "\n"
    try:
        test_get()
    except e:
        failures += String("test_get: ") + String(e) + "\n"
    try:
        test_parse_accepts()
    except e:
        failures += String("test_parse_accepts: ") + String(e) + "\n"
    try:
        test_round_trip()
    except e:
        failures += String("test_round_trip: ") + String(e) + "\n"
    try:
        test_parse_refusals()
    except e:
        failures += String("test_parse_refusals: ") + String(e) + "\n"
    try:
        test_percent_refusals()
    except e:
        failures += String("test_percent_refusals: ") + String(e) + "\n"
    try:
        test_byte_refusals()
    except e:
        failures += String("test_byte_refusals: ") + String(e) + "\n"
    try:
        test_duplicate_refusals()
    except e:
        failures += String("test_duplicate_refusals: ") + String(e) + "\n"
    try:
        test_size_limit()
    except e:
        failures += String("test_size_limit: ") + String(e) + "\n"
    if failures != "":
        print(failures)
        raise Error("test_form failed")
    print("PASS komira_oauth test_form")
