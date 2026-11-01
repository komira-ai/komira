# =============================================================================
# tests/test_env_name.mojo: the handle grammar, `is_secret_env_name` and
#   `check_secret_env_name`, against an oracle written from the spec.
# =============================================================================
#
# The spec (README, env_name.mojo): a handle matches `[A-Za-z_][A-Za-z0-9_]*`
# and is 1 to 128 bytes. The oracle below spells the two byte classes out as
# literal alphabets, so it shares no comparison with the code under test.
# Pinned here:
#   * every ASCII byte, alone and after a valid first byte, gets the oracle's
#     answer from BOTH functions (a range boundary moved by one, a dropped
#     class, or digits allowed first, is a wrong answer at one byte);
#   * lengths 0, 1, 2, 128 and 129, and a bad byte first, in the middle and
#     last (a loop that skips the first or the last byte);
#   * `check_secret_env_name` raises exactly when `is_secret_env_name` says
#     no, with the exact message (length and first bad position, never the
#     name);
#   * a non-ASCII byte is outside the grammar wherever it stands.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_secret_env import (
    MAX_SECRET_NAME_LEN,
    check_secret_env_name,
    is_secret_env_name,
)

comptime _FIRST = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_"
comptime _REST = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_0123456789"
comptime _BAD_TAIL = " is outside [A-Za-z_][A-Za-z0-9_]*"


def _in_alphabet(b: Int, alphabet: String) -> Bool:
    var a = alphabet.as_bytes()
    for i in range(len(a)):
        if Int(a[i]) == b:
            return True
    return False


def _check_message(name: String) -> String:
    """What `check_secret_env_name(name)` raises, or "<ok>"."""
    try:
        check_secret_env_name(name)
    except e:
        return String(e)
    return String("<ok>")


def _bad_byte(n: Int, i: Int) -> String:
    return (
        String("secret env name (")
        + String(n)
        + " bytes) is not an environment variable name: byte "
        + String(i)
        + _BAD_TAIL
    )


def _expect(name: String, want_ok: Bool, want_msg: String, label: String) raises:
    """Run `name` through both checkers with the exact expected answer."""
    assert_equal(is_secret_env_name(name), want_ok, label)
    if want_ok:
        assert_equal(_check_message(name), "<ok>", label)
    else:
        assert_equal(_check_message(name), want_msg, label)


def test_limit_is_128() raises:
    assert_equal(MAX_SECRET_NAME_LEN, 128)


def test_every_ascii_byte_first_and_second() raises:
    for b in range(128):
        var c = chr(b)
        var label = String("byte ") + String(b)
        # Alone: the first-byte class.
        var first_ok = _in_alphabet(b, _FIRST)
        _expect(c, first_ok, _bad_byte(1, 0), label + " first")
        # After a valid first byte: the rest class.
        var rest_ok = _in_alphabet(b, _REST)
        _expect(String("A") + c, rest_ok, _bad_byte(2, 1), label + " second")
        # After a valid first byte and before a valid last one: the loop
        # reaches the middle and reports this position, not a later one.
        _expect(
            String("_") + c + "Z", rest_ok, _bad_byte(3, 1), label + " middle"
        )


def test_lengths() raises:
    _expect("", False, "secret env name is empty", "length 0")
    _expect("x", True, "", "length 1")
    _expect("x9", True, "", "length 2")
    _expect(String("A") * MAX_SECRET_NAME_LEN, True, "", "length 128")
    _expect(
        String("A") * (MAX_SECRET_NAME_LEN + 1),
        False,
        "secret env name is 129 bytes; the limit is 128"
        " (a handle names a variable, it is not a value)",
        "length 129",
    )
    # A too-long name is refused for its length even when every byte is bad:
    # the length check comes first.
    _expect(
        String("-") * (MAX_SECRET_NAME_LEN + 1),
        False,
        "secret env name is 129 bytes; the limit is 128"
        " (a handle names a variable, it is not a value)",
        "length 129 bad bytes",
    )


def test_bad_byte_position_is_the_first_bad_one() raises:
    _expect("-A", False, _bad_byte(2, 0), "bad first")
    _expect("A-", False, _bad_byte(2, 1), "bad last")
    _expect("AB.C/D", False, _bad_byte(6, 2), "first of two bad")
    _expect("9", False, _bad_byte(1, 0), "digit alone")
    _expect(String("A") * (MAX_SECRET_NAME_LEN - 1) + "-", False,
            _bad_byte(128, 127), "bad at byte 127 of 128")


def test_non_ascii_is_outside_the_grammar() raises:
    # "Ä" is two bytes, 0xC3 0x84; the first of them is the bad byte.
    _expect("Ä", False, _bad_byte(2, 0), "non-ASCII first")
    _expect("AÄ", False, _bad_byte(3, 1), "non-ASCII second")
    assert_false(is_secret_env_name("NAME\x00"))


def test_refusal_never_quotes_the_name() raises:
    var pasted = String("ghp_pasted.token/value")
    var msg = _check_message(pasted)
    assert_equal(msg, _bad_byte(22, 10))
    assert_equal(msg.find("ghp_"), -1)
    assert_equal(msg.find("token"), -1)


def main() raises:
    test_limit_is_128()
    test_every_ascii_byte_first_and_second()
    test_lengths()
    test_bad_byte_position_is_the_first_bad_one()
    test_non_ascii_is_outside_the_grammar()
    test_refusal_never_quotes_the_name()
    print("PASS test_env_name")
