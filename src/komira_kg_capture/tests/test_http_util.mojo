# =============================================================================
# test_http_util.mojo -- the helpers every route shares.
# =============================================================================
#
#   query_value   the first matching pair wins, a value is percent-decoded
#                 (multi-byte text intact), an absent key or a key without a
#                 value is "", a key that only starts like the wanted one does
#                 not match, a broken escape or bytes that are not UTF-8 raise.
#   bearer        only "Bearer <token>" matches: the scheme in any case, the
#                 token exactly (a prefix, an extension, another token, no
#                 scheme, a different scheme and a missing space all fail).
#   checks        token and label rules at each side of each limit.
#   writers       an error body and a JSON body carry multi-byte text unchanged
#                 and escape every control byte (the source wrote each byte of
#                 a multi-byte character as a separate code point and left most
#                 control bytes raw).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_json import JsonValue, parse_json_bytes
from komira_kg_capture import (
    LABEL_MAX_BYTES,
    bearer_matches,
    check_label,
    check_token,
    error_response,
    json_response,
    query_value,
)


def test_query_value_finds_the_first_pair_and_decodes_it() raises:
    assert_equal(query_value("a=1&b=2", "b"), "2")
    assert_equal(query_value("a=1&a=2", "a"), "1")
    assert_equal(query_value("x=%7Ba%20b%7D", "x"), "{a b}")
    # U+00E9 and U+4E2D as UTF-8 escapes come back as the two characters.
    assert_equal(query_value("x=%C3%A9%E4%B8%AD", "x"), "é中")
    assert_equal(query_value("x=a+b", "x"), "a+b")  # '+' is not a space here


def test_query_value_absent_empty_and_lookalike_keys() raises:
    assert_equal(query_value("", "a"), "")
    assert_equal(query_value("b=1", "a"), "")
    assert_equal(query_value("a", "a"), "")  # a key with no '='
    assert_equal(query_value("a=", "a"), "")
    assert_equal(query_value("ab=1&a=2", "a"), "2")  # "ab" is not "a"
    assert_equal(query_value("a=1&&b=2", "b"), "2")
    assert_equal(query_value("xa=1", "a"), "")
    assert_equal(query_value("a=1", "ab"), "")  # the wanted key is longer


def test_query_value_refuses_broken_escapes_and_bad_utf8() raises:
    with assert_raises():
        _ = query_value("x=%", "x")
    with assert_raises():
        _ = query_value("x=%4", "x")
    with assert_raises():
        _ = query_value("x=%zz", "x")
    with assert_raises():
        _ = query_value("x=%4z", "x")
    with assert_raises():
        _ = query_value("x=%C3", "x")  # a lead byte with no continuation
    with assert_raises():
        _ = query_value("x=%FF", "x")


def test_query_value_reads_every_hex_digit_class() raises:
    assert_equal(query_value("x=%41%61%39", "x"), "Aa9")
    assert_equal(query_value("x=%4a%4A", "x"), "JJ")
    with assert_raises():
        _ = query_value("x=%G1", "x")
    with assert_raises():
        _ = query_value("x=%1G", "x")
    with assert_raises():
        _ = query_value("x=%g1", "x")
    with assert_raises():
        _ = query_value("x=%/1", "x")  # '/' is just below '0'
    with assert_raises():
        _ = query_value("x=%:1", "x")  # ':' is just above '9'
    with assert_raises():
        _ = query_value("x=%@1", "x")  # '@' is just below 'A'
    with assert_raises():
        _ = query_value("x=%`1", "x")  # '`' is just below 'a'


def test_bearer_matches_only_the_exact_token() raises:
    assert_true(bearer_matches("Bearer tok-123", "tok-123"))
    assert_true(bearer_matches("bearer tok-123", "tok-123"))
    assert_true(bearer_matches("BEARER tok-123", "tok-123"))
    assert_false(bearer_matches("Bearer tok-12", "tok-123"))  # a prefix
    assert_false(bearer_matches("Bearer tok-1234", "tok-123"))  # an extension
    assert_false(bearer_matches("Bearer tok-124", "tok-123"))  # last byte
    assert_false(bearer_matches("Bearer Tok-123", "tok-123"))  # case matters
    assert_false(bearer_matches("tok-123", "tok-123"))  # no scheme
    assert_false(bearer_matches("Basic tok-123", "tok-123"))
    assert_false(bearer_matches("Bearertok-123", "tok-123"))  # no space
    assert_false(bearer_matches("Bearer  tok-123", "tok-123"))  # two spaces
    assert_false(bearer_matches("Bearer ", "tok-123"))
    assert_false(bearer_matches("", "tok-123"))
    assert_false(bearer_matches("Bearer", "tok-123"))  # shorter than the scheme


def test_token_rules() raises:
    check_token("a")
    check_token("~!")
    var longest = String("")
    for _ in range(4096):
        longest += "x"
    check_token(longest)
    with assert_raises():
        check_token(longest + "x")
    with assert_raises():
        check_token("")
    with assert_raises():
        check_token("a b")  # 0x20
    with assert_raises():
        check_token("a\tb")
    with assert_raises():
        check_token("aé")
    with assert_raises():
        check_token("a\x7fb")


def test_label_rules() raises:
    check_label("partition", "p")
    var longest = String("")
    for _ in range(LABEL_MAX_BYTES):
        longest += "x"
    check_label("partition", longest)
    with assert_raises(contains="partition"):
        check_label("partition", longest + "x")
    with assert_raises(contains="partition"):
        check_label("partition", "")
    with assert_raises(contains="control"):
        check_label("partition", "a\nb")
    with assert_raises(contains="control"):
        check_label("partition", "a\x7fb")
    check_label("partition", "a b é")  # space and non-ASCII are allowed


def test_error_response_escapes_and_keeps_multibyte_text() raises:
    var r = error_response(Int32(422), "quote \" slash \\ nl \n tab \t bell \x07 é中")
    assert_equal(Int(r.status), 422)
    assert_equal(r.headers["content-type"], "application/json")
    assert_equal(r.headers["content-length"], String(len(r.body)))
    var doc = parse_json_bytes(r.body)
    assert_equal(
        doc.get("error").as_string(),
        "quote \" slash \\ nl \n tab \t bell \x07 é中",
    )
    # The control bytes are escapes on the wire, never raw.
    for i in range(len(r.body)):
        assert_true(r.body[i] >= 0x20)
    # The two-byte and three-byte characters are on the wire as they came.
    var wire = String(from_utf8_lossy=Span(r.body))
    assert_true("é中" in wire)


def test_json_response_serializes_the_value() raises:
    var v = JsonValue.empty_object()
    v.set_member("n", JsonValue.from_i64(Int64(7)))
    var r = json_response(Int32(200), v^)
    assert_equal(Int(r.status), 200)
    assert_equal(String(from_utf8_lossy=Span(r.body)), '{"n":7}')
    assert_equal(r.headers["content-length"], "7")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
