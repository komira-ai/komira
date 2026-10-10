# =============================================================================
# test_posix_read_env.mojo — unit test for komira_libc.posix
# =============================================================================
#
# Validates `_read_env` in `komira_libc.posix`, the one home of the
# `getenv` declaration and the only env read the libraries keep (platform
# handshake values and test-runner variables).
#
# Tests set variables with libc `setenv(3)` directly (via `external_call`):
# setenv is only called from test setup like this file. Removal goes through
# komira_libc.posix's `_unset_env`, the one `unsetenv` declaration, so this
# binary never links a second one.
# =============================================================================

from std.ffi import external_call
from std.testing import assert_equal, assert_true, assert_false

from komira_libc.posix import _read_env, _read_env_into, _unset_env


# -----------------------------------------------------------------------------
# Test helpers — libc setenv (tests only) and the library's unset.
# -----------------------------------------------------------------------------


def _setenv(name: String, value: String):
    """Set env var `name` to `value` via libc `setenv(3)`."""
    var name_str = name
    var value_str = value
    # SAFETY: both Strings outlive the setenv(3) call, which copies them.
    var name_ptr = name_str.as_c_string_slice().unsafe_ptr()
    var value_ptr = value_str.as_c_string_slice().unsafe_ptr()
    var _rc = external_call["setenv", Int32](name_ptr, value_ptr, Int32(1))


def _unsetenv(name: String) raises:
    """Unset env var `name` through komira_libc's `_unset_env`."""
    _unset_env(name)


# -----------------------------------------------------------------------------
# _read_env
# -----------------------------------------------------------------------------


def test_read_env_unset_returns_empty() raises:
    """Unset variable -> empty string."""
    _unsetenv("KOMIRA_TEST_POSIX_UNSET_VAR_A")
    var v = _read_env("KOMIRA_TEST_POSIX_UNSET_VAR_A")
    assert_equal(v.byte_length(), 0)


def test_read_env_set_returns_value() raises:
    """Set variable -> string with the value bytes."""
    _setenv("KOMIRA_TEST_POSIX_VAR_B", "hello_world")
    var v = _read_env("KOMIRA_TEST_POSIX_VAR_B")
    assert_equal(v, "hello_world")
    _unsetenv("KOMIRA_TEST_POSIX_VAR_B")


def test_read_env_empty_value_returns_empty() raises:
    """Set to empty string -> empty (indistinguishable from unset by design)."""
    _setenv("KOMIRA_TEST_POSIX_VAR_EMPTY", "")
    var v = _read_env("KOMIRA_TEST_POSIX_VAR_EMPTY")
    assert_equal(v.byte_length(), 0)
    _unsetenv("KOMIRA_TEST_POSIX_VAR_EMPTY")


def test_read_env_long_value() raises:
    """Long-ish value (~1 KB) reads back byte-for-byte."""
    var long_value = String("")
    for _ in range(100):
        long_value += String("0123456789")
    _setenv("KOMIRA_TEST_POSIX_VAR_LONG", long_value)
    var v = _read_env("KOMIRA_TEST_POSIX_VAR_LONG")
    assert_equal(v.byte_length(), 1000)
    # spot-check a few bytes via the byte projection
    var bs = v.as_bytes()
    assert_equal(Int(bs[0]), Int(ord("0")))
    assert_equal(Int(bs[9]), Int(ord("9")))
    _unsetenv("KOMIRA_TEST_POSIX_VAR_LONG")


def test_read_env_special_chars() raises:
    """Special characters (slashes, equals, etc.) read back faithfully."""
    _setenv("KOMIRA_TEST_POSIX_VAR_PATH", "/tmp/foo=bar/baz")
    var v = _read_env("KOMIRA_TEST_POSIX_VAR_PATH")
    assert_equal(v, "/tmp/foo=bar/baz")
    _unsetenv("KOMIRA_TEST_POSIX_VAR_PATH")


def _bytes_of(imm x: String) raises -> List[UInt8]:
    var out = List[UInt8]()
    var b = x.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _hex(imm b: List[UInt8]) raises -> String:
    var digits: List[String] = [
        String("0"), String("1"), String("2"), String("3"),
        String("4"), String("5"), String("6"), String("7"),
        String("8"), String("9"), String("a"), String("b"),
        String("c"), String("d"), String("e"), String("f"),
    ]
    var out = String("")
    for i in range(len(b)):
        if i > 0:
            out += " "
        var v = Int(b[i])
        out += digits[v >> 4]
        out += digits[v & 15]
    return out^


def _non_ascii_value() raises -> String:
    """`/tmp/données-ok` + one character from EACH multi-byte UTF-8 class.

    Widths on purpose: 2-byte (C3), 3-byte (E6), 4-byte (F0). A per-byte
    `chr` decode doubles EVERY byte >= 0x80, so a fixture with only 2-byte
    sequences cannot tell a correct copy from a two-byte special case.
    """
    return String("/tmp/donn") + "é" + "es-ok" + "é" + "日" + "𐍈"


def test_read_env_value_is_not_ascii_only() raises:
    """NON-VACUITY GUARD FOR `test_read_env_preserves_non_ascii_bytes`.

    ⛔ THE DEFECT THAT TEST PINS IS THE IDENTITY ON ASCII. A `_read_env` that
    builds its result with `out += chr(Int(b))` per byte returns every byte
    >= 0x80 as TWO (`chr` maps a CODE POINT to its UTF-8 ENCODING), and every
    byte < 0x80 correct. An ASCII fixture therefore passes against the bug,
    which is exactly why the neighbouring `test_read_env_special_chars` — a
    test whose NAME promises special characters, using `/tmp/foo=bar/baz` —
    cannot catch it.

    Killed by: replacing any non-ASCII character in `_non_ascii_value` with an
    ASCII one, or dropping the 3-byte or 4-byte character.
    """
    var b = _bytes_of(_non_ascii_value())
    var n_high = 0
    var saw_2b = False
    var saw_3b = False
    var saw_4b = False
    for i in range(len(b)):
        var v = Int(b[i])
        if v >= 0x80:
            n_high += 1
        if v >= 0xC0 and v <= 0xDF:
            saw_2b = True
        if v >= 0xE0 and v <= 0xEF:
            saw_3b = True
        if v >= 0xF0 and v <= 0xF7:
            saw_4b = True
    if n_high == 0:
        raise Error(
            "the fixture is ALL-ASCII — a per-byte `chr` decode is the"
            " identity on ASCII, so the non-ASCII test below is vacuous"
        )
    if not saw_2b or not saw_3b or not saw_4b:
        raise Error(
            "the fixture lost a UTF-8 lead-byte class (2-byte="
            + String(saw_2b)
            + " 3-byte="
            + String(saw_3b)
            + " 4-byte="
            + String(saw_4b)
            + ")"
        )


def test_read_env_preserves_non_ascii_bytes() raises:
    """An env value's bytes must come back EXACTLY.

    ⛔ THE DEFECT: `out += chr(Int(b))` per byte re-encodes every byte >= 0x80
    into two, so `TMPDIR=/tmp/données` reads back as `/tmp/donnÃ©es` — a path
    that opens nothing. ⚠ THIS IS THE CONSOLIDATED getenv, so such a defect
    reaches every consumer of a non-ASCII env value.

    Asserted as EXACT BYTES with a hex diagnostic, not as `assert_equal` on
    the String alone: the failure mode is a length change, and the hex is what
    makes "every byte >= 0x80 doubled" legible in the log.

    Killed by: restoring `out += chr(Int(b))` in `posix._read_env`.
    """
    var want = _non_ascii_value()
    _setenv("KOMIRA_TEST_POSIX_VAR_UTF8", want)
    var got = _read_env("KOMIRA_TEST_POSIX_VAR_UTF8")
    _unsetenv("KOMIRA_TEST_POSIX_VAR_UTF8")  # RESTORE BEFORE ASSERTING
    var gb = _bytes_of(got)
    var wb = _bytes_of(want)
    if len(gb) != len(wb):
        raise Error(
            "_read_env returned "
            + String(len(gb))
            + " bytes ["
            + _hex(gb)
            + "] for a "
            + String(len(wb))
            + "-byte value ["
            + _hex(wb)
            + "]. If every byte >= 0x80 doubled, the per-code-point `chr()`"
            " decode is back"
        )
    for i in range(len(gb)):
        if gb[i] != wb[i]:
            raise Error(
                "_read_env byte "
                + String(i)
                + " differs: got ["
                + _hex(gb)
                + "] want ["
                + _hex(wb)
                + "]"
            )


# -----------------------------------------------------------------------------
# _read_env_into (the secret reader): N = 8 so both sides of the limit are
# cheap to reach.
# -----------------------------------------------------------------------------


def test_read_env_into_unset_empty_and_set_differ() raises:
    """Unset is -1 and set-but-empty is 0: the two answers `_read_env` merges."""
    var buf = Array[UInt8, 8](fill=UInt8(0x5A))
    _unsetenv("KOMIRA_TEST_POSIX_INTO_UNSET")
    assert_equal(_read_env_into("KOMIRA_TEST_POSIX_INTO_UNSET", buf), -1)
    _setenv("KOMIRA_TEST_POSIX_INTO_EMPTY", "")
    var n_empty = _read_env_into("KOMIRA_TEST_POSIX_INTO_EMPTY", buf)
    _unsetenv("KOMIRA_TEST_POSIX_INTO_EMPTY")
    assert_equal(n_empty, 0)
    _setenv("KOMIRA_TEST_POSIX_INTO_SET", "abc")
    var n = _read_env_into("KOMIRA_TEST_POSIX_INTO_SET", buf)
    _unsetenv("KOMIRA_TEST_POSIX_INTO_SET")
    assert_equal(n, 3)
    assert_equal(Int(buf[0]), Int(ord("a")))
    assert_equal(Int(buf[2]), Int(ord("c")))
    assert_equal(Int(buf[3]), 0x5A, "bytes past n are not written")


def test_read_env_into_at_the_limit_and_one_past() raises:
    """N bytes are read whole; N + 1 bytes are refused, never truncated to N.

    Killed by: scanning `while n < N` (an N + 1 byte value would then read as
    its first N bytes, a corrupted credential)."""
    var buf = Array[UInt8, 8](fill=UInt8(0))
    _setenv("KOMIRA_TEST_POSIX_INTO_MAX", "qqqqqqqq")
    var n = _read_env_into("KOMIRA_TEST_POSIX_INTO_MAX", buf)
    _unsetenv("KOMIRA_TEST_POSIX_INTO_MAX")
    assert_equal(n, 8)
    assert_equal(Int(buf[7]), Int(ord("q")))

    var clean = Array[UInt8, 8](fill=UInt8(0))
    _setenv("KOMIRA_TEST_POSIX_INTO_LONG", "rrrrrrrrr")
    var msg = String("<not refused>")
    try:
        _ = _read_env_into("KOMIRA_TEST_POSIX_INTO_LONG", clean)
    except e:
        msg = String(e)
    _unsetenv("KOMIRA_TEST_POSIX_INTO_LONG")
    assert_equal(msg, "environment value is longer than 8 bytes")
    for i in range(8):
        assert_equal(Int(clean[i]), 0, "a refused value is not copied")


def test_read_env_into_preserves_non_ascii_bytes() raises:
    """Byte-exact, like `_read_env`: no byte >= 0x80 is re-encoded."""
    var want = String("donn") + "é" + "日"
    var buf = Array[UInt8, 16](fill=UInt8(0))
    _setenv("KOMIRA_TEST_POSIX_INTO_UTF8", want)
    var n = _read_env_into("KOMIRA_TEST_POSIX_INTO_UTF8", buf)
    _unsetenv("KOMIRA_TEST_POSIX_INTO_UTF8")
    var wb = want.as_bytes()
    assert_equal(n, len(wb))
    for i in range(len(wb)):
        assert_equal(Int(buf[i]), Int(wb[i]))


# -----------------------------------------------------------------------------
# Test driver
# -----------------------------------------------------------------------------


def main() raises:
    test_read_env_unset_returns_empty()
    test_read_env_set_returns_value()
    test_read_env_empty_value_returns_empty()
    test_read_env_long_value()
    test_read_env_special_chars()
    test_read_env_value_is_not_ascii_only()
    test_read_env_preserves_non_ascii_bytes()
    test_read_env_into_unset_empty_and_set_differ()
    test_read_env_into_at_the_limit_and_one_past()
    test_read_env_into_preserves_non_ascii_bytes()
    print("[test_posix_read_env] all 10 tests PASS")
