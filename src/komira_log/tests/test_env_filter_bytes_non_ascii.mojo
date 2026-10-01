# =============================================================================
# A LOG DIRECTIVE'S MODULE KEY IS A BYTE STRING AND MUST SURVIVE PARSING EXACTLY
# =============================================================================
#
# ⛔ THE DEFECT CLASS THIS FILE GUARDS: a byte-slice helper written as
#
#     def _substr(s, start, end):
#         var out = String("")
#         for i in range(start, end):
#             out += chr(Int(bs[i]))
#
# `chr` maps a CODE POINT to its UTF-8 ENCODING, so a stored byte >= 0x80 is
# not reproduced but RE-ENCODED into two: `ü` (C3 BC) -> `Ã¼` (C3 83 C2 BC).
# ASCII is the corruption's FIXED POINT, which is why an ASCII-only directive
# test cannot see it. A helper NAMED `_substr_ascii` invites exactly this copy:
# it asserts ASCII while its callers never are.
#
# ⚠ THE OBSERVABLE FAILURE IS A SILENTLY INERT DIRECTIVE, NOT A CRASH.
# `EnvFilter._parse` builds a rule's module PREFIX with `_substr`, and
# `effective_level` matches that prefix against the module name, which arrives
# as CORRECT UTF-8 from the call site. Corrupt on ONE side only ⇒ the override
# never matches and the module silently keeps the GLOBAL default — the
# one-sided-corruption shape that makes `WHERE city = 'Zürich'` return an empty
# result set when a query engine corrupts one side of a comparison.
#
# ⚠ WHAT THIS FILE DELIBERATELY DOES NOT ASSERT: that two code paths agree.
# Agreement is also satisfied by both being wrong alike. Every assertion is
# against the EXACT bytes of the fixture's own source text, or against the
# resolved LEVEL, which the defect changes.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_log.env_filter import EnvFilter, _substr
from komira_log.levels import (
    DEFAULT_GLOBAL_LEVEL,
    LEVEL_DEBUG,
    LEVEL_ERROR,
)


# =============================================================================
# THE FIXTURE — all three multi-byte UTF-8 lead classes
# =============================================================================
#
#   'modül'   6 bytes  6D 6F 64 C3 BC 6C    2-byte lead (C3)
#   '東京'    6 bytes  E6 9D B1 E4 BA AC    two 3-byte sequences
#   '𐍈'      4 bytes  F0 90 8D 88          one 4-byte sequence
#   'plain'   5 bytes  ASCII — the CONTROL

comptime _EXPECTED_KEY_BYTES: Int = 21  # 6 + 6 + 4 + 5


def _keys() raises -> List[String]:
    return [
        String("modül"),
        String("東京"),
        String("𐍈"),
        String("plain"),
    ]


# =============================================================================
# Byte helpers
# =============================================================================


def _bytes_of(imm s: String) raises -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
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


def _assert_bytes_eq(
    imm got: String, imm want: String, imm what: String
) raises:
    var gb = _bytes_of(got)
    var wb = _bytes_of(want)
    if len(gb) != len(wb):
        raise Error(
            what
            + ": got "
            + String(len(gb))
            + " bytes ["
            + _hex(gb)
            + "] for a "
            + String(len(wb))
            + "-byte source ["
            + _hex(wb)
            + "]. If every byte >= 0x80 doubled, the per-code-point `chr()`"
            " decode is back — see this file's header"
        )
    for i in range(len(gb)):
        if gb[i] != wb[i]:
            raise Error(
                what
                + ": byte "
                + String(i)
                + " differs (got ["
                + _hex(gb)
                + "] want ["
                + _hex(wb)
                + "])"
            )


# =============================================================================
# NON-VACUITY — without this, an all-ASCII fixture makes the file a tautology
# =============================================================================


def test_fixture_is_actually_non_ascii() raises:
    """NON-VACUITY GUARD FOR EVERY OTHER TEST IN THIS FILE.

    ⛔ THE OLD DECODE IS THE IDENTITY ON ASCII, so an all-ASCII fixture makes
    every assertion below pass against the DEFECTIVE `_substr`. A fixture edit
    swapping `modül` for `module` would fail nothing — it would silently turn
    this file into decoration.

    Four properties, each ruling out a different degenerate fixture:
      1. a key holds a byte >= 0x80;
      2. all three multi-byte lead classes appear (C0-DF, E0-EF, F0-F7) — a
         decode that only handled 2-byte sequences would survive a C3-only
         fixture;
      3. an all-ASCII CONTROL key is present, so a "fix" that damages ASCII is
         caught rather than hidden;
      4. the exact stored byte total, so a substitution that preserves the
         class set still reds.

    Killed by: replacing any non-ASCII key with ASCII; dropping the 3-byte or
    the 4-byte key; dropping the ASCII control.
    """
    var ks = _keys()
    var total = 0
    var n_high = 0
    var saw_2b = False
    var saw_3b = False
    var saw_4b = False
    var saw_ascii_control = False
    for i in range(len(ks)):
        var b = _bytes_of(ks[i])
        total += len(b)
        var this_high = 0
        for j in range(len(b)):
            var v = Int(b[j])
            if v >= 0x80:
                this_high += 1
                n_high += 1
            if v >= 0xC0 and v <= 0xDF:
                saw_2b = True
            if v >= 0xE0 and v <= 0xEF:
                saw_3b = True
            if v >= 0xF0 and v <= 0xF7:
                saw_4b = True
        if this_high == 0:
            saw_ascii_control = True

    if n_high == 0:
        raise Error(
            "VACUOUS FIXTURE: no key holds a byte >= 0x80, so every assertion"
            " in this file passes against the DEFECTIVE per-code-point"
            " `chr` decode. See this file's header."
        )
    if not saw_2b:
        raise Error("VACUOUS FIXTURE: no 2-byte (C0-DF) lead byte present")
    if not saw_3b:
        raise Error("VACUOUS FIXTURE: no 3-byte (E0-EF) lead byte present")
    if not saw_4b:
        raise Error("VACUOUS FIXTURE: no 4-byte (F0-F7) lead byte present")
    if not saw_ascii_control:
        raise Error("VACUOUS FIXTURE: no all-ASCII CONTROL key")
    assert_equal(total, _EXPECTED_KEY_BYTES)


# =============================================================================
# FALSIFIER — `env_filter._substr`
# =============================================================================


def test_substr_reproduces_bytes_exactly() raises:
    """SITE: `komira_log/env_filter._substr` — the direct, minimal falsifier.

    Slices are taken so that the multi-byte sequence lands (a) in the middle,
    (b) at the START of the slice, and (c) at the END of it — a decode that
    only mishandled interior bytes would survive a single centred case.

    Killed by: restoring `out += chr(Int(bs[i]))` in `_substr`.
    """
    var ks = _keys()
    for i in range(len(ks)):
        var s = String("[") + ks[i] + String("]")
        var n = len(s.as_bytes())
        # (a) the whole thing, multi-byte run in the middle.
        _assert_bytes_eq(_substr(s, 0, n), s, "_substr whole")
        # (b) drop the leading `[` — the multi-byte run now starts the slice.
        _assert_bytes_eq(_substr(s, 1, n), ks[i] + String("]"),
                         "_substr from 1")
        # (c) drop the trailing `]` — the run now ends the slice.
        _assert_bytes_eq(_substr(s, 0, n - 1), String("[") + ks[i],
                         "_substr to n-1")


def test_a_non_ascii_module_override_actually_takes_effect() raises:
    """SITE: same, through its ONE production caller (`EnvFilter._parse`).

    THE OBSERVABLE FAILURE. `_parse` stores the rule prefix via `_substr`;
    `effective_level` matches it against a module name that is CORRECT UTF-8.
    Under the defect the prefix is mojibaked, nothing matches, and the module
    silently falls back to the global default — the directive is INERT.

    ⚠ Asserts the resolved LEVEL, not string agreement: `LEVEL_DEBUG` and the
    global default `LEVEL_INFO` are different values, so "both wrong alike"
    cannot satisfy it. The ASCII control key in the same spec must resolve
    correctly at the same time, which rules out a "fix" that breaks ASCII.

    Killed by: restoring `out += chr(Int(bs[i]))` in `_substr`.
    """
    var spec = String("error,modül=debug,東京=debug,𐍈=debug,plain=debug")
    var f = EnvFilter(spec^)

    # The bare token set the global default.
    assert_equal(f.effective_level("unrelated"), LEVEL_ERROR)
    # Every override — non-ASCII and ASCII alike — must take effect.
    assert_equal(f.effective_level("modül"), LEVEL_DEBUG)
    assert_equal(f.effective_level("東京"), LEVEL_DEBUG)
    assert_equal(f.effective_level("𐍈"), LEVEL_DEBUG)
    assert_equal(f.effective_level("plain"), LEVEL_DEBUG)
    # And dotted-path prefixing still works under a non-ASCII prefix.
    assert_equal(f.effective_level("modül.sub"), LEVEL_DEBUG)


def test_a_non_ascii_level_value_still_parses() raises:
    """SITE: same, the VALUE side of the `=` — a separate `_substr` call from
    the key side, so a fix to one arm only cannot pass.

    A level NAME is ASCII by construction, so the discriminating case is a
    non-ASCII value that must be REJECTED (unknown level -> the directive is
    skipped, global default stands) rather than accidentally matching. Under
    the defect the value was mojibaked before `parse_level` saw it, which is
    the same class of silent misparse and could turn a *valid* level name into
    an invalid one had any been non-ASCII.

    ⚠ The load-bearing half is the SECOND assertion: a valid ASCII level under
    a non-ASCII KEY resolves, proving the value slice survived the same call
    that the key slice did.
    """
    var f1 = EnvFilter(String("modül=débug"))
    assert_equal(f1.effective_level("modül"), DEFAULT_GLOBAL_LEVEL)
    var f2 = EnvFilter(String("  modül  =  debug  "))
    assert_equal(f2.effective_level("modül"), LEVEL_DEBUG)


def main() raises:
    test_fixture_is_actually_non_ascii()
    test_substr_reproduces_bytes_exactly()
    test_a_non_ascii_module_override_actually_takes_effect()
    test_a_non_ascii_level_value_still_parses()
    print("test_env_filter_bytes_non_ascii: ALL PASS")
