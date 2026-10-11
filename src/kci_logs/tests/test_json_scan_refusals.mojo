# =============================================================================
# kci_logs/tests/test_json_scan_refusals.mojo — the shared JSON scanner's
#   whitespace, escape and refusal arms, byte for byte.
# =============================================================================
#
# Both cloud arms parse through `json_scan`, so every allow-listed parse in the
# package is only as sound as these four functions. The UTF-8 repair has its
# own file (`test_json_scan_utf8.mojo`); this one pins the rest:
#
#   S1  `json_skip_space` skips all four JSON whitespace bytes and stops at
#       the first other byte (and at the end of the span).
#   S2  `json_scan_string` decodes `\n` `\r` `\t` to their control bytes and
#       passes any other escaped byte through (`\"` `\\` `\/`).
#   S3  `json_scan_string` refuses (-1) a backslash that is the LAST byte, an
#       unterminated string, and a value that does not start with a quote;
#       each refusal leaves `out` empty (no stale or partial value).
#   S4  `json_scan_number` reads a signed integer and stops at the first
#       non-digit; a sign with no digit, or no digit at all, is -1.
#   S5  `json_skip_value` skips a string, a nested object/array (a brace
#       INSIDE a string does not count), and a bare literal up to `,` `}` `]`
#       or whitespace; it refuses an empty tail, an unterminated nested string
#       and an unclosed container.
# =============================================================================

from std.testing import assert_equal

from kci_logs.json_scan import (
    json_scan_number,
    json_scan_string,
    json_skip_space,
    json_skip_value,
)


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    for i in range(len(sb)):
        out.append(sb[i])
    return out^


def test_skip_space_all_four_bytes() raises:
    var b = _b(" \t\n\rx ")
    assert_equal(json_skip_space(Span(b), 0), 4, "stops at the `x`")
    assert_equal(json_skip_space(Span(b), 4), 4, "a non-space is not skipped")
    assert_equal(json_skip_space(Span(b), 5), 6, "runs to the end of the span")


def test_scan_string_decodes_escapes() raises:
    # `"a\nb\rc\td\"e\\f\/g"` -> a LF b CR c TAB d " e \ f / g
    var b = _b('"a\\nb\\rc\\td\\"e\\\\f\\/g"!')
    var out = String()
    var end = json_scan_string(Span(b), 0, out)
    assert_equal(end, len(b) - 1, "ends just after the closing quote")
    assert_equal(out, String('a\nb\rc\td"e\\f/g'))
    var ob = out.as_bytes()
    assert_equal(ob[1], UInt8(0x0A), "`\\n` is LF")
    assert_equal(ob[3], UInt8(0x0D), "`\\r` is CR")
    assert_equal(ob[5], UInt8(0x09), "`\\t` is TAB")


def test_scan_string_refusals() raises:
    # Each refusal starts from a stale `out` and must leave it empty: neither
    # the old value nor the partly decoded prefix survives a -1.
    var out = String("stale")
    var trailing = _b('"ab\\')
    assert_equal(
        json_scan_string(Span(trailing), 0, out),
        -1,
        "a backslash with nothing after it is unterminated",
    )
    assert_equal(out, String(""), "trailing backslash: no partial value")
    out = String("stale")
    var open = _b('"abc')
    assert_equal(json_scan_string(Span(open), 0, out), -1, "no closing quote")
    assert_equal(out, String(""), "unterminated: no partial value")
    out = String("stale")
    var bare = _b("abc")
    assert_equal(json_scan_string(Span(bare), 0, out), -1, "not a string")
    assert_equal(out, String(""), "not a string: no stale value")


def test_scan_number_signed_and_refused() raises:
    var out = 99
    var neg = _b("-12x")
    assert_equal(json_scan_number(Span(neg), 0, out), 3)
    assert_equal(out, -12)
    var pos = _b("4070.5")
    assert_equal(json_scan_number(Span(pos), 0, out), 4, "a `.` ends it")
    assert_equal(out, 4070)
    var sign_only = _b("-x")
    assert_equal(json_scan_number(Span(sign_only), 0, out), -1, "sign only")
    var none = _b("x1")
    assert_equal(json_scan_number(Span(none), 0, out), -1, "no digit")
    assert_equal(out, 0)


def test_skip_value_shapes() raises:
    var s = _b('  "a,}" ,')
    assert_equal(json_skip_value(Span(s), 0), 7, "a string, after leading space")
    var obj = _b('{"k":"}]{[","n":[1,{"m":2}]},')
    assert_equal(
        json_skip_value(Span(obj), 0),
        len(obj) - 1,
        "braces inside a string do not count; nesting is by depth",
    )
    var lit = _b("true,1")
    assert_equal(json_skip_value(Span(lit), 0), 4, "a literal ends at `,`")
    var lit_brace = _b("null}")
    assert_equal(json_skip_value(Span(lit_brace), 0), 4, "ends at `}`")
    var lit_bracket = _b("12]")
    assert_equal(json_skip_value(Span(lit_bracket), 0), 2, "ends at `]`")
    var lit_space = _b("false x")
    assert_equal(json_skip_value(Span(lit_space), 0), 5, "ends at a space")
    var lit_end = _b("123")
    assert_equal(json_skip_value(Span(lit_end), 0), 3, "or at the end")


def test_skip_value_refusals() raises:
    var empty = _b("   ")
    assert_equal(json_skip_value(Span(empty), 0), -1, "nothing to skip")
    var bad_str = _b('{"k":"open}')
    assert_equal(
        json_skip_value(Span(bad_str), 0), -1, "an unterminated nested string"
    )
    var unclosed = _b("[1,[2]")
    assert_equal(json_skip_value(Span(unclosed), 0), -1, "an unclosed array")


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    try:
        f()
        print("PASS", name)
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("test_skip_space_all_four_bytes", test_skip_space_all_four_bytes, failed)
    _run("test_scan_string_decodes_escapes", test_scan_string_decodes_escapes, failed)
    _run("test_scan_string_refusals", test_scan_string_refusals, failed)
    _run("test_scan_number_signed_and_refused", test_scan_number_signed_and_refused, failed)
    _run("test_skip_value_shapes", test_skip_value_shapes, failed)
    _run("test_skip_value_refusals", test_skip_value_refusals, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("test_json_scan_refusals: ALL 6 CASES PASS")
