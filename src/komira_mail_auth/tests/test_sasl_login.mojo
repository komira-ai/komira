# SASL LOGIN decoding, the prompts and the 334 line cap. What each case
# catches:
# - a username and password encoded by the client decode back (a swap, or a
#   decoder that keeps the base64, fails);
# - bad base64, an empty value, a NUL byte and invalid UTF-8 are refused;
# - one bad reply refuses the pair;
# - the two prompts are the base64 of "Username:" and "Password:";
# - the cap accepts exactly 12288 bytes and refuses 12289, and refuses a
#   negative length.

from std.testing import assert_equal, assert_false, assert_true

from komira_encoding import base64_encode
from komira_mail_auth import (
    MAX_SASL_LINE_BYTES,
    SASL_LOGIN_PASSWORD_CHALLENGE,
    SASL_LOGIN_USERNAME_CHALLENGE,
    decode_sasl_login,
    decode_sasl_login_value,
    sasl_line_within_cap,
)


def _b64(s: String) -> String:
    return base64_encode(s.as_bytes())


def test_round_trip() raises:
    var c = decode_sasl_login(_b64("alice@example.com"), _b64("pa ss=word"))
    assert_true(Bool(c))
    assert_equal(c.value().authcid, "alice@example.com")
    assert_equal(c.value().password, "pa ss=word")
    var one = decode_sasl_login_value(_b64("alice"))
    assert_true(Bool(one))
    assert_equal(one.value(), "alice")


def test_refusals() raises:
    assert_false(Bool(decode_sasl_login_value(String("!!!!"))))
    assert_false(Bool(decode_sasl_login_value(String(""))))
    assert_false(Bool(decode_sasl_login_value(String("YQ"))))  # unpadded
    assert_false(Bool(decode_sasl_login_value(_b64("a\0b"))))
    var bad = List[UInt8]()
    bad.append(0xC3)
    assert_false(Bool(decode_sasl_login_value(base64_encode(Span(bad)))))
    assert_false(Bool(decode_sasl_login(String("!!!!"), _b64("pw"))))
    assert_false(Bool(decode_sasl_login(_b64("alice"), String("!!!!"))))
    assert_false(Bool(decode_sasl_login(String(""), _b64("pw"))))
    assert_false(Bool(decode_sasl_login(_b64("alice"), String(""))))


def test_prompts() raises:
    assert_equal(String(SASL_LOGIN_USERNAME_CHALLENGE), _b64("Username:"))
    assert_equal(String(SASL_LOGIN_PASSWORD_CHALLENGE), _b64("Password:"))


def test_cap() raises:
    assert_equal(MAX_SASL_LINE_BYTES, 12288)
    assert_true(sasl_line_within_cap(0))
    assert_true(sasl_line_within_cap(1))
    assert_true(sasl_line_within_cap(12287))
    assert_true(sasl_line_within_cap(12288))
    assert_false(sasl_line_within_cap(12289))
    assert_false(sasl_line_within_cap(1000000))
    assert_false(sasl_line_within_cap(-1))


def main() raises:
    test_round_trip()
    test_refusals()
    test_prompts()
    test_cap()
    print("test_sasl_login: OK")
