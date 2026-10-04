# =============================================================================
# test_substring_duckdb_semantics — the 23 values DuckDB v1.5.3 answers, and
# the THREE silent wrong answers this kernel used to give
# =============================================================================
#
# ⛔ EVERY EXPECTATION BELOW WAS READ OUT OF DuckDB v1.5.3, ONE STATEMENT PER
# CELL. None is inferred from a rule, because the rule is what was wrong: the
# pre kernel's own docstring stated the PostgreSQL negative-start
# rule and asserted it "matched DuckDB", and it does not.
#
# THE THREE DEFECTS, all silent, all green over the TPC-H corpus:
#
#   1. A NEGATIVE `start` COUNTS FROM THE END. `substring('hello',-1)` is `o`
#      in DuckDB and was `hello` here; `substring('hello',-1,4)` is `o` there
#      and was `he` here. ⚠ `start == 0` does NOT take that branch — DuckDB
#      leaves 0 on the counted-against-length rule (`substring('hello',0,2)`
#      = `h`), so the boundary between the two rules is at 0, not at 1, and
#      the tests that pin it are the `0`-start ones.
#
#   2. INDICES ARE CHARACTERS, NOT BYTES. `substring('héllo',2,2)` is `él`;
#      byte indexing answers the two bytes of `é` alone. Every TPC-H string
#      column is single-byte, which is exactly why this survived.
#
#   3. `chr(Int(byte))` IS A CODEPOINT CONSTRUCTOR and the old loop built its
#      output with it, so a byte >= 0x80 was re-encoded as its own two-byte
#      UTF-8 sequence — non-ASCII text was not merely mis-indexed, it was
#      CORRUPTED and lengthened. The assertions below compare BYTE LENGTH
#      before content for exactly this reason: `substring('Straße',4,3)` is
#      `aße` = FOUR bytes, and the old kernel emitted six.
#
# ⚠ ALL THREE ARE ONE FIX. A codepoint-indexed kernel returning `List[UInt8]`
# closes them together, which is why there is one test file and not three.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_compiler.compiler_eval_column import _sql_substring_bytes


def _assert_sub(
    s: String, start: Int, length: Int, expected: String, why: String
) raises:
    """Assert `substring(s, start, length)` == `expected`, BYTES AND ALL.

    ⚠ THE BYTE-LENGTH ASSERTION COMES FIRST AND IS NOT REDUNDANT. The
    `chr`-corruption defect produced output that was WRONG IN LENGTH before
    it was wrong in content, and a content loop that stopped at the shorter of
    the two would have passed on the prefix.
    """
    var got = _sql_substring_bytes(s, start, length)
    var want = expected.as_bytes()
    assert_equal(
        len(got),
        len(want),
        "substring('" + s + "', " + String(start) + ", " + String(length)
        + ") BYTE LENGTH — " + why,
    )
    for i in range(len(want)):
        assert_equal(
            Int(got[i]),
            Int(want[i]),
            "substring('" + s + "', " + String(start) + ", " + String(length)
            + ") byte " + String(i) + " — " + why,
        )


# ===========================================================================
# (1) POSITIVE start — the shape that always worked. The CONTROL.
# ===========================================================================


def test_positive_start() raises:
    _assert_sub("hello", 1, 3, "hel", "1-based start, 3 chars")
    _assert_sub("hello", 2, -1, "ello", "omitted length = to end")
    _assert_sub("hello", 1, 0, "", "zero length is empty, not the whole string")
    _assert_sub("hello", 5, 10, "o", "length past the end clamps")
    _assert_sub("hello", 6, -1, "", "start past the end is empty")
    print("PASS: positive start (5 cells)")


# ===========================================================================
# (2) start == 0 — the BOUNDARY. It stays on the counted-against-length rule.
# ===========================================================================


def test_zero_start_is_counted_against_length() raises:
    """★ THE CELL THAT DECIDES WHERE THE TWO RULES MEET. If `start <= 0` had
    been made the from-the-end branch — the obvious reading of "negative
    counts from the end" — `substring('hello',0,2)` would answer `lo`
    (begin = 5+0 = 5, clamped) or the empty string, not `h`."""
    _assert_sub("hello", 0, -1, "hello", "start 0, no length = whole string")
    _assert_sub("hello", 0, 1, "", "position 0 consumes the only unit of length")
    _assert_sub("hello", 0, 2, "h", "positions 0..1 -> just character 1")
    _assert_sub("hello", 0, 6, "hello", "0 costs one, so 6 reaches all five")
    print("PASS: start == 0 stays on the counted-against-length rule (4 cells)")


# ===========================================================================
# (3) NEGATIVE start — from the END. ⛔ Every one of these was WRONG before.
# ===========================================================================


def test_negative_start_counts_from_the_end() raises:
    """DEFECT 1. The old kernel answered `hello` for `substring('hello',-1)`
    and `he` for `substring('hello',-1,4)`."""
    _assert_sub("hello", -1, -1, "o", "-1 is the LAST character")
    _assert_sub("hello", -1, 4, "o", "clamped at the end, not extended")
    _assert_sub("hello", -2, 1, "l", "-2 is the second from last, 1 char")
    _assert_sub("hello", -3, -1, "llo", "-3 to the end")
    _assert_sub("hello", -3, 2, "ll", "-3, two characters")
    _assert_sub("hello", -5, -1, "hello", "-n where n == the length")
    print("PASS: negative start counts from the END (6 cells)")


def test_negative_start_before_the_string() raises:
    """A start further back than the string is long lands BEFORE position 1 —
    and the length is still consumed from there, so it does not simply clamp
    to the beginning. `substring('hello',-6,2)` is `h`, NOT `he`."""
    _assert_sub("hello", -6, -1, "hello", "-6 with no length is still all of it")
    _assert_sub("hello", -6, 2, "h", "one unit of length is spent before pos 1")
    _assert_sub("hello", -6, 7, "hello", "6 units past the start reaches all 5")
    _assert_sub("hello", -10, 3, "", "the whole window is before the string")
    print("PASS: negative start BEFORE the string (4 cells)")


# ===========================================================================
# (4) MULTI-BYTE — defects 2 and 3 together.
# ===========================================================================


def test_characters_not_bytes() raises:
    """DEFECT 2. `héllo` is 5 characters over 6 bytes.

    ⚠ `substring('héllo',1,3)` = `hél` is FOUR BYTES. A byte-indexed kernel
    answers three bytes (`hé`) and a byte-indexed kernel built with `chr`
    answers five (`hÃ©`), so the byte-length assertion alone separates all
    three implementations.
    """
    _assert_sub("héllo", 1, 3, "hél", "3 CHARACTERS spanning 4 bytes")
    _assert_sub("héllo", 2, 2, "él", "starts INSIDE what a byte index calls 1")
    _assert_sub("héllo", -2, -1, "lo", "negative start over multi-byte text")
    print("PASS: indices are CHARACTERS, not bytes (3 cells)")


def test_multibyte_bytes_are_verbatim() raises:
    """DEFECT 3. `substring('Straße',4,3)` = `aße` — FOUR bytes (a, C3, 9F, e).

    The old `out += chr(Int(b[j]))` loop re-encoded C3 and 9F as two bytes
    EACH, so it emitted six bytes and the consumer decoded `aÃŸe`. Comparing
    against `"aße".as_bytes` catches it on the length assertion before it
    ever reaches a content one.
    """
    _assert_sub("Straße", 4, 3, "aße", "a + the two bytes of ß + e")
    _assert_sub("Straße", 5, 1, "ß", "a lone multi-byte character, 2 bytes")
    _assert_sub("Straße", 1, 6, "Straße", "all six characters, seven bytes")
    print("PASS: multi-byte bytes pass through VERBATIM (3 cells)")


def main() raises:
    print("=== substring vs DuckDB v1.5.3 ===")
    test_positive_start()
    test_zero_start_is_counted_against_length()
    test_negative_start_counts_from_the_end()
    test_negative_start_before_the_string()
    test_characters_not_bytes()
    test_multibyte_bytes_are_verbatim()
    print()
    print("All 25 substring cells match DuckDB v1.5.3")
