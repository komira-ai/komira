# =============================================================================
# Tests: a U+0000 inside a JSON string is kept, with every byte after it.
# =============================================================================
#
# RFC 8259 §7 lets a string carry U+0000 through the escape backslash-u-0000.
# The decoded string holds the byte 0x00 and keeps every byte after it. Each
# case asserts the exact byte length AND the bytes, so a builder that stops at
# the first 0x00 (a NUL-terminated copy) is red: it returns the bytes before
# the 0x00 only.
#
#   N1 parse_string_with_escapes: `a`, escape of U+0000, `b` -> 61 00 62
#   N2 the escape of U+0000 alone -> 00 (one byte, not the empty string)
#   N3 the escape of U+0000 first, then `\n` and `z` -> 00 0A 7A
#   N4 parse_string (has_escapes=True) routes to the same decoder -> 61 00 62
#   N5 parse_string_raw over a raw 0x00 byte (accepted by the UTF-8 check)
#      -> 61 00 62, not 61
#   N6 extract_column `->>` over {"k":"a<escape of U+0000>b"} -> a 3-byte
#      value (the StringArray offsets carry the length; `get_length` reads
#      them)
# =============================================================================

from std.testing import assert_equal, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_plan_expr.expr import parse_json_path

from komira_json_index.json_extract_kernel import extract_column
from komira_json_index.parse_string import (
    parse_string,
    parse_string_raw,
    parse_string_with_escapes,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        out.append(b[i])
    return out^


def _assert_bytes(got: String, *want: UInt8) raises:
    """`got` is exactly the bytes `want`, length first."""
    var g = got.as_bytes()
    assert_equal(len(g), len(want), "byte length")
    for i in range(len(want)):
        assert_equal(g[i], want[i], "byte " + String(i))


def _column(rows: List[List[UInt8]]) raises -> Column[HeapRegion]:
    var sa = StringArray.from_byte_lists(rows)
    return Column.from_string(sa^)


def test_escape_between_bytes() raises:
    var b = _bytes("a\\u0000b")
    _assert_bytes(parse_string_with_escapes(Span(b), 0, len(b)), 0x61, 0x00, 0x62)


def test_escape_alone() raises:
    var b = _bytes("\\u0000")
    _assert_bytes(parse_string_with_escapes(Span(b), 0, len(b)), 0x00)


def test_escape_then_more_escapes() raises:
    var b = _bytes("\\u0000\\nz")
    _assert_bytes(parse_string_with_escapes(Span(b), 0, len(b)), 0x00, 0x0A, 0x7A)


def test_dispatcher_escape_path() raises:
    var b = _bytes("a\\u0000b")
    _assert_bytes(parse_string(Span(b), 0, len(b), True), 0x61, 0x00, 0x62)


def test_raw_path_keeps_bytes_after_nul() raises:
    var b = List[UInt8]()
    b.append(0x61)
    b.append(0x00)
    b.append(0x62)
    _assert_bytes(parse_string_raw(Span(b), 0, len(b)), 0x61, 0x00, 0x62)


def test_extract_unquoted_keeps_bytes_after_nul() raises:
    var rows = List[List[UInt8]]()
    rows.append(_bytes('{"k":"a\\u0000b"}'))
    var col = _column(rows)
    var out = extract_column(col, parse_json_path(String("$.k")), ArrowType.STRING, False)
    assert_false(out.is_null_at(0))
    assert_equal(out.as_string().get_length(0), 3, "->> value byte length")


def _run(name: String, f: def() raises thin -> None, mut failed: List[String]):
    """Run one case; a failure is recorded, not fatal, so a red build names
    EVERY failing case rather than only the first."""
    try:
        f()
        print("PASS", name)
    except e:
        print("FAIL", name, ":", e)
        failed.append(name)


def main() raises:
    var failed = List[String]()
    _run("test_escape_between_bytes", test_escape_between_bytes, failed)
    _run("test_escape_alone", test_escape_alone, failed)
    _run("test_escape_then_more_escapes", test_escape_then_more_escapes, failed)
    _run("test_dispatcher_escape_path", test_dispatcher_escape_path, failed)
    _run("test_raw_path_keeps_bytes_after_nul", test_raw_path_keeps_bytes_after_nul, failed)
    _run("test_extract_unquoted_keeps_bytes_after_nul", test_extract_unquoted_keeps_bytes_after_nul, failed)
    if len(failed) > 0:
        raise Error(String(len(failed)) + " case(s) failed")
    print("parse_string_nul: ALL 6 CASES PASS")
