# SASL PLAIN decoding (RFC 4616). What each case catches:
# - a good payload gives the authcid and password (a decoder that returns the
#   authzid, or swaps the fields, fails);
# - an extra NUL field, a missing NUL, an authzid that differs from the
#   authcid (also a prefix of it, and longer), and an empty authcid or
#   password are refused (a decoder that checks only for "at least three
#   fields", as a naive split does, accepts the first and last of these);
# - an authzid equal to the authcid is accepted;
# - base64 that is not canonical, and fields that are not UTF-8, are refused;
# - a password with non-ASCII text and with `=` survives;
# - UTF-8 edges, in the password and in the authcid: a 2-, 3- and 4-byte
#   character at the end of the field is accepted; an overlong form, a code
#   point above U+10FFFF, a truncated sequence and a bad continuation byte at
#   the end of the field are refused;
# - the RFC 4954 empty initial response `=` and the empty string are None, so
#   a server must handle them itself (send an empty 334) before decoding;
# - a payload over the line cap is refused, one at the cap is decoded.

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import base64_encode
from komira_mail_auth import MAX_SASL_LINE_BYTES, decode_sasl_plain


def _b64(s: List[UInt8]) -> String:
    return base64_encode(Span(s))


def _payload(authzid: String, authcid: String, password: String) -> String:
    var raw = List[UInt8]()
    raw.extend(authzid.as_bytes())
    raw.append(0)
    raw.extend(authcid.as_bytes())
    raw.append(0)
    raw.extend(password.as_bytes())
    return _b64(raw)


def test_good() raises:
    var c = decode_sasl_plain(_payload("", "alice", "s3cret"))
    assert_true(Bool(c))
    assert_equal(c.value().authcid, "alice")
    assert_equal(c.value().password, "s3cret")


def test_authzid_equal_accepted() raises:
    var c = decode_sasl_plain(_payload("alice", "alice", "s3cret"))
    assert_true(Bool(c))
    assert_equal(c.value().authcid, "alice")
    assert_equal(c.value().password, "s3cret")


def test_authzid_mismatch_refused() raises:
    assert_false(Bool(decode_sasl_plain(_payload("bob", "alice", "s3cret"))))
    assert_false(Bool(decode_sasl_plain(_payload("ali", "alice", "s3cret"))))
    assert_false(Bool(decode_sasl_plain(_payload("alicee", "alice", "s3cret"))))
    assert_false(Bool(decode_sasl_plain(_payload("Alice", "alice", "s3cret"))))


def test_nul_count() raises:
    # Four fields: a NUL inside the password.
    var extra = List[UInt8]()
    extra.extend(String("\0alice\0pa").as_bytes())
    extra.append(0)
    extra.extend(String("ss").as_bytes())
    assert_false(Bool(decode_sasl_plain(_b64(extra))))
    # Only two fields.
    var two = List[UInt8]()
    two.extend(String("alice").as_bytes())
    two.append(0)
    two.extend(String("s3cret").as_bytes())
    assert_false(Bool(decode_sasl_plain(_b64(two))))
    # No NUL at all, and nothing at all.
    assert_false(Bool(decode_sasl_plain(base64_encode(String("alice").as_bytes()))))
    assert_false(Bool(decode_sasl_plain(String(""))))


def test_empty_fields_refused() raises:
    assert_false(Bool(decode_sasl_plain(_payload("", "", "s3cret"))))
    assert_false(Bool(decode_sasl_plain(_payload("", "alice", ""))))
    assert_false(Bool(decode_sasl_plain(_payload("", "", ""))))


def test_bad_base64_refused() raises:
    var good = _payload("", "alice", "s3cret")
    assert_false(Bool(decode_sasl_plain(String("!!!!"))))
    assert_false(Bool(decode_sasl_plain(String("AGFsaWNlAHMzY3JldA"))))  # unpadded
    assert_false(Bool(decode_sasl_plain(good + String(" "))))
    assert_false(Bool(decode_sasl_plain(String("=="))))


def test_utf8() raises:
    var pw = String("p") + chr(0xE9) + String("=w")
    var c = decode_sasl_plain(_payload("", "alice", pw))
    assert_true(Bool(c))
    assert_equal(c.value().password, pw)
    var bad = List[UInt8]()
    bad.append(0)
    bad.extend(String("alice").as_bytes())
    bad.append(0)
    bad.append(0xC3)  # a lead byte with no continuation
    assert_false(Bool(decode_sasl_plain(_b64(bad))))
    var bad_user = List[UInt8]()
    bad_user.append(0)
    bad_user.append(0xFF)
    bad_user.append(0)
    bad_user.extend(String("x").as_bytes())
    assert_false(Bool(decode_sasl_plain(_b64(bad_user))))
    var surrogate = List[UInt8]()
    surrogate.append(0)
    surrogate.extend(String("u").as_bytes())
    surrogate.append(0)
    surrogate.append(0xED)
    surrogate.append(0xA0)
    surrogate.append(0x80)
    assert_false(Bool(decode_sasl_plain(_b64(surrogate))))


def _fields(authcid: List[UInt8], password: List[UInt8]) -> String:
    var raw = List[UInt8]()
    raw.append(0)
    raw.extend(authcid.copy())
    raw.append(0)
    raw.extend(password.copy())
    return _b64(raw)


def _bytes(*values: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in values:
        out.append(UInt8(v))
    return out^


def _with_tail(head: String, *tail: Int) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(head.as_bytes())
    for v in tail:
        out.append(UInt8(v))
    return out^


def test_utf8_edges_accepted() raises:
    var user = _bytes(0x61)
    # 2-, 3- and 4-byte characters last in the password.
    var tails = List[List[UInt8]]()
    tails.append(_with_tail("p", 0xC3, 0xA9))  # U+00E9
    tails.append(_with_tail("p", 0xE2, 0x82, 0xAC))  # U+20AC
    tails.append(_with_tail("p", 0xF0, 0x9F, 0x98, 0x80))  # U+1F600
    tails.append(_with_tail("p", 0xF4, 0x8F, 0xBF, 0xBF))  # U+10FFFF
    tails.append(_with_tail("p", 0xE0, 0xA0, 0x80))  # U+0800, lowest 3-byte
    tails.append(_with_tail("p", 0xF0, 0x90, 0x80, 0x80))  # U+10000
    for i in range(len(tails)):
        var c = decode_sasl_plain(_fields(user.copy(), tails[i].copy()))
        assert_true(Bool(c))
        assert_equal(c.value().authcid, "a")
        assert_equal(len(c.value().password.as_bytes()), len(tails[i]))
        # The same character last in the authcid.
        var d = decode_sasl_plain(_fields(tails[i].copy(), _bytes(0x70)))
        assert_true(Bool(d))
        assert_equal(len(d.value().authcid.as_bytes()), len(tails[i]))


def test_utf8_edges_refused() raises:
    var bads = List[List[UInt8]]()
    bads.append(_with_tail("p", 0xC0, 0x80))  # overlong NUL
    bads.append(_with_tail("p", 0xC1, 0xBF))  # overlong, below U+0080
    bads.append(_with_tail("p", 0xE0, 0x80, 0x80))  # overlong 3-byte
    bads.append(_with_tail("p", 0xE0, 0x9F, 0xBF))  # overlong 3-byte
    bads.append(_with_tail("p", 0xF0, 0x80, 0x80, 0x80))  # overlong 4-byte
    bads.append(_with_tail("p", 0xF4, 0x90, 0x80, 0x80))  # U+110000
    bads.append(_with_tail("p", 0xF8, 0x88, 0x80, 0x80, 0x80))  # 5-byte form
    bads.append(_with_tail("p", 0xE2, 0x82))  # truncated 3-byte
    bads.append(_with_tail("p", 0xF0, 0x9F, 0x98))  # truncated 4-byte
    bads.append(_with_tail("p", 0xC3))  # truncated 2-byte
    bads.append(_with_tail("p", 0xE2, 0x41, 0xAC))  # bad continuation
    bads.append(_with_tail("p", 0xE2, 0x82, 0x41))  # bad last continuation
    bads.append(_with_tail("p", 0xF0, 0x9F, 0x41, 0x80))  # bad continuation
    bads.append(_with_tail("p", 0x80))  # a lone continuation byte
    bads.append(_with_tail("p", 0xED, 0xA0, 0x80))  # surrogate
    for i in range(len(bads)):
        assert_false(Bool(decode_sasl_plain(_fields(_bytes(0x61), bads[i].copy()))))
        assert_false(Bool(decode_sasl_plain(_fields(bads[i].copy(), _bytes(0x70)))))


def test_line_cap() raises:
    # 0 + "a" + 0 + password: 3 raw bytes per 4 base64 characters. A raw
    # length of 9213 gives 12284 characters, within the cap.
    var pw = List[UInt8]()
    for _ in range(9213 - 3):
        pw.append(0x70)
    var within = _fields(_bytes(0x61), pw.copy())
    assert_equal(len(within.as_bytes()), 12284)
    assert_true(Bool(decode_sasl_plain(within)))
    # A raw length of 9216 gives exactly 12288 characters: accepted.
    pw.append(0x70)
    pw.append(0x70)
    pw.append(0x70)
    var at_cap = _fields(_bytes(0x61), pw.copy())
    assert_equal(len(at_cap.as_bytes()), MAX_SASL_LINE_BYTES)
    assert_true(Bool(decode_sasl_plain(at_cap)))
    # One more group is 12292 characters: refused although it is valid base64.
    pw.append(0x70)
    var over = _fields(_bytes(0x61), pw.copy())
    assert_true(len(over.as_bytes()) > MAX_SASL_LINE_BYTES)
    assert_false(Bool(decode_sasl_plain(over)))


def test_empty_initial_response() raises:
    assert_false(Bool(decode_sasl_plain("=")))
    assert_false(Bool(decode_sasl_plain("")))


def main() raises:
    test_good()
    test_authzid_equal_accepted()
    test_authzid_mismatch_refused()
    test_nul_count()
    test_empty_fields_refused()
    test_bad_base64_refused()
    test_utf8()
    test_utf8_edges_accepted()
    test_utf8_edges_refused()
    test_line_cap()
    test_empty_initial_response()
    print("test_sasl_plain: OK")
