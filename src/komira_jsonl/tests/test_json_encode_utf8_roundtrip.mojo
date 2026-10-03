# =============================================================================
# Regression test — _emit_string_escaped must NOT double-UTF-8-encode
# non-ASCII bytes.
# =============================================================================
#
# The hazard (output-only): a pass-through branch that does
# `out += s[byte=i]`. `s[byte=i]` returns a String whose single codepoint
# is the raw byte value U+00XX. For any byte >= 0x80 — i.e. every
# continuation / lead byte of a multi-byte UTF-8 char — appending that
# codepoint-promoted String re-UTF-8-encodes it into 2 bytes. The em-dash
# "—" (UTF-8 e2 80 94) would come out as c3a2 c280 c294. ASCII (< 0x80)
# is unaffected, so ASCII-only tests cannot see it.
#
# `_emit_string_escaped` accumulates a `List[UInt8]` and appends the RAW
# byte in the pass-through branch, the same idiom as `write_record`.
#
# These assertions are at the BYTE level — the only level at which the
# double-encode is visible.
# =============================================================================

from komira_jsonl.encode import _emit_string_escaped


def _bytes_of(s: String) -> List[UInt8]:
    """Recover the raw UTF-8 bytes backing `s`. Reads `s.as_bytes()`
    directly — `s[byte=i]` would raise on any non-codepoint-boundary byte
    of a multi-byte char, which is exactly the input we're testing."""
    var out = List[UInt8]()
    var src = s.as_bytes()
    var n = len(src)
    for i in range(n):
        out.append(src[i])
    return out^


def _nib(n: UInt8) -> String:
    """0..15 -> "0".."9","a".."f" (a single hex digit)."""
    if n < UInt8(10):
        return chr(Int(UInt8(0x30) + n))
    return chr(Int(UInt8(0x61) + (n - UInt8(10))))


def _hex(b: UInt8) -> String:
    var hi = (b >> UInt8(4)) & UInt8(0xF)
    var lo = b & UInt8(0xF)
    return _nib(hi) + _nib(lo)


def _hex_dump(bs: List[UInt8]) -> String:
    var out = String("[")
    for i in range(len(bs)):
        if i > 0:
            out += String(" ")
        out += _hex(bs[i])
    out += String("]")
    return out


def _assert_bytes_eq(
    got: List[UInt8], expected: List[UInt8], label: String
) raises:
    var ok = len(got) == len(expected)
    if ok:
        for i in range(len(got)):
            if got[i] != expected[i]:
                ok = False
                break
    if not ok:
        raise Error(
            String("FAIL ") + label + String(": expected ")
            + _hex_dump(expected) + String(" got ") + _hex_dump(got)
        )
    print("  PASS", label)


def _b(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for v in vals:
        out.append(UInt8(v))
    return out^


def main() raises:
    print("== _emit_string_escaped UTF-8 round-trip ==")

    # --- 2-byte char: "é" = c3 a9. Output must be quote, é, quote. ---
    # The bug would double-encode to 22 c3 83 c2 a9 22.
    var two_in = String(unsafe_from_utf8=_b(0xC3, 0xA9))  # "é"
    var two_out = _bytes_of(_emit_string_escaped(two_in))
    _assert_bytes_eq(
        two_out, _b(0x22, 0xC3, 0xA9, 0x22), String("2-byte char é")
    )

    # --- 3-byte char: em-dash "—" = e2 80 94. ---
    var three_in = String(unsafe_from_utf8=_b(0xE2, 0x80, 0x94))  # "—"
    var three_out = _bytes_of(_emit_string_escaped(three_in))
    _assert_bytes_eq(
        three_out,
        _b(0x22, 0xE2, 0x80, 0x94, 0x22),
        String("3-byte char — (em-dash)"),
    )

    # --- 4-byte char: emoji "😀" = f0 9f 98 80. ---
    var four_in = String(unsafe_from_utf8=_b(0xF0, 0x9F, 0x98, 0x80))  # "😀"
    var four_out = _bytes_of(_emit_string_escaped(four_in))
    _assert_bytes_eq(
        four_out,
        _b(0x22, 0xF0, 0x9F, 0x98, 0x80, 0x22),
        String("4-byte char 😀 (emoji)"),
    )

    # --- ASCII escaping still correct. ---
    # `"` -> \"
    var quote_out = _bytes_of(_emit_string_escaped(String('"')))
    _assert_bytes_eq(
        quote_out, _b(0x22, 0x5C, 0x22, 0x22), String('escape " -> \\"')
    )
    # `\` -> \\
    var bs_out = _bytes_of(_emit_string_escaped(String("\\")))
    _assert_bytes_eq(
        bs_out, _b(0x22, 0x5C, 0x5C, 0x22), String("escape \\ -> \\\\")
    )
    # newline -> \n
    var nl_out = _bytes_of(_emit_string_escaped(String("\n")))
    _assert_bytes_eq(
        nl_out, _b(0x22, 0x5C, 0x6E, 0x22), String("escape \\n")
    )
    # control char 0x01 -> 
    var ctrl_in = String(unsafe_from_utf8=_b(0x01))
    var ctrl_out = _bytes_of(_emit_string_escaped(ctrl_in))
    _assert_bytes_eq(
        ctrl_out,
        _b(0x22, 0x5C, 0x75, 0x30, 0x30, 0x30, 0x31, 0x22),
        String("escape 0x01 -> \\u0001"),
    )

    # --- Plain ASCII passes through unchanged. ---
    var ascii_out = _bytes_of(_emit_string_escaped(String("hello")))
    _assert_bytes_eq(
        ascii_out,
        _b(0x22, 0x68, 0x65, 0x6C, 0x6C, 0x6F, 0x22),  # "hello"
        String("plain ASCII unchanged"),
    )

    # --- Mixed ASCII + multi-byte (the real-world task-title shape). ---
    # "A—B" = 41 e2 80 94 42
    var mixed_in = String(unsafe_from_utf8=_b(0x41, 0xE2, 0x80, 0x94, 0x42))
    var mixed_out = _bytes_of(_emit_string_escaped(mixed_in))
    _assert_bytes_eq(
        mixed_out,
        _b(0x22, 0x41, 0xE2, 0x80, 0x94, 0x42, 0x22),
        String("mixed ASCII + em-dash"),
    )

    print("ALL PASS")
