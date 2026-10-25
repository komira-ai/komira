# SASL PLAIN decoding (RFC 4616). What each case catches:
# - a good payload gives the authcid and password (a decoder that returns the
#   authzid, or swaps the fields, fails);
# - an extra NUL field, a missing NUL, an authzid that differs from the
#   authcid (also a prefix of it, and longer), and an empty authcid or
#   password are refused (a decoder that checks only for "at least three
#   fields", as a naive split does, accepts the first and last of these);
# - an authzid equal to the authcid is accepted;
# - base64 that is not canonical, and fields that are not UTF-8, are refused;
# - a password with non-ASCII text and with `=` survives.

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import base64_encode
from komira_mail_auth import decode_sasl_plain


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


def main() raises:
    test_good()
    test_authzid_equal_accepted()
    test_authzid_mismatch_refused()
    test_nul_count()
    test_empty_fields_refused()
    test_bad_base64_refused()
    test_utf8()
    print("test_sasl_plain: OK")
