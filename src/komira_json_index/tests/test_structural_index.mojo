# =============================================================================
# Tests for komira_jsonl/structural_index.mojo — JSON Stage 1 driver.
# =============================================================================
#
# Coverage (inline fixtures; 20+ algorithmic edge cases):
#   T1  Empty input → empty index.
#   T2  Single object `{}` → 2 entries: {, }.
#   T3  Single key-value `{"a":1}` → { " " : } (5 entries: open-brace,
#       open-quote, close-quote, colon, close-brace; scalar value '1'
#       is NOT a structural — Stage 2 derives it from the gap).
#   T4  Two key-value pairs `{"a":1,"b":2}` → 7 structural entries.
#   T5  Nested object `{"a":{"b":1}}`.
#   T6  Array `[1,2,3]` → 5 structurals ([, ,, ,, ,, ]; scalars not counted).
#   T7  Nested array `[[1],[2]]`.
#   T8  Escape — quotes inside string `{"a":"b\"c"}` — escape doesn't
#       terminate the string.
#   T9  Escape — backslash sequence `{"a":"\\\\"}` — paired backslashes
#       don't escape.
#   T10 Cross-chunk string — string spans 16-byte boundary.
#   T11 Cross-chunk escape — backslash at byte 15 escapes byte 16.
#   T12 Unterminated string raises.
#   T13 Tail handling — input < 16 bytes.
#   T14 Tail handling — input is exactly 16 bytes.
#   T15 Tail handling — input is 17 bytes.
#   T16 Large input — 1024 bytes synthetic, verify total structural
#       count matches scalar reference.
#   T17 All-whitespace input → empty index.
#   T18 String containing structurals `{"k":"a{b}c"}` — inner {,} ignored.
#   T19 Multiple top-level objects (JSONL `{}{}`) — 4 structurals.
#   T20 UTF-8 multi-byte chars inside string `{"k":"héllo"}`.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_jsonl.structural_index import (
    StructuralIndex,
    build_structural_index,
)
from komira_jsonl.simd_primitives import (
    TAG_OPEN_BRACE,
    TAG_CLOSE_BRACE,
    TAG_OPEN_BRACKET,
    TAG_CLOSE_BRACKET,
    TAG_COLON,
    TAG_COMMA,
    TAG_QUOTE_OPEN,
    TAG_QUOTE_CLOSE,
)


# =============================================================================
# Helpers
# =============================================================================


def _idx_from_str(s: String) raises -> StructuralIndex:
    """Build a StructuralIndex from a String fixture."""
    var bs = s.as_bytes()
    return build_structural_index(bs)


def _expect_tags(idx: StructuralIndex, expected: List[UInt8]) raises:
    """Verify the tag sequence in `idx` matches `expected`."""
    assert_equal(idx.size(), len(expected))
    for k in range(idx.size()):
        assert_equal(Int(idx.tags[k]), Int(expected[k]))


def _expect_offsets(idx: StructuralIndex, expected: List[Int]) raises:
    """Verify the offset sequence in `idx` matches `expected`."""
    assert_equal(idx.size(), len(expected))
    for k in range(idx.size()):
        assert_equal(Int(idx.offsets[k]), expected[k])


# Scalar reference: counts the number of structural chars (any of
# {}[]:,") OUTSIDE strings via a simple linear scan. Used as the golden
# for large-buffer correctness checks.
def _scalar_count_structurals(bytes: Span[UInt8, _]) -> Int:
    var n = len(bytes)
    var in_string = False
    var escape_carry = False  # True if prev byte was unescaped '\\' inside a string
    var count = 0
    var i = 0
    while i < n:
        var b = bytes[i]
        if escape_carry:
            escape_carry = False
        elif in_string:
            if b == UInt8(0x5C):  # '\\'
                escape_carry = True
            elif b == UInt8(0x22):  # '"' (close)
                count += 1
                in_string = False
        else:
            if b == UInt8(0x22):  # '"' (open)
                count += 1
                in_string = True
            elif (
                b == UInt8(0x7B)
                or b == UInt8(0x7D)
                or b == UInt8(0x5B)
                or b == UInt8(0x5D)
                or b == UInt8(0x3A)
                or b == UInt8(0x2C)
            ):
                count += 1
        i += 1
    return count


# =============================================================================
# T1 — empty input
# =============================================================================


def test_empty_input() raises:
    var idx = _idx_from_str("")
    assert_equal(idx.size(), 0)


# =============================================================================
# T2 — single object
# =============================================================================


def test_single_empty_object() raises:
    var idx = _idx_from_str("{}")
    assert_equal(idx.size(), 2)
    assert_equal(Int(idx.offsets[0]), 0)
    assert_equal(Int(idx.tags[0]), Int(TAG_OPEN_BRACE))
    assert_equal(Int(idx.offsets[1]), 1)
    assert_equal(Int(idx.tags[1]), Int(TAG_CLOSE_BRACE))


# =============================================================================
# T3 — single key-value
# =============================================================================


def test_single_kv() raises:
    # `{"a":1}`. Structurals at: 0 ({), 1 (" open), 3 (" close), 4 (:), 6 (}).
    var idx = _idx_from_str('{"a":1}')
    var expected_offsets: List[Int] = [0, 1, 3, 4, 6]
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACE,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_CLOSE_BRACE,
    ]
    _expect_offsets(idx, expected_offsets)
    _expect_tags(idx, expected_tags)


# =============================================================================
# T4 — two key-value pairs
# =============================================================================


def test_two_kv() raises:
    # `{"a":1,"b":2}`. Structurals: { " " : , " " : }
    # idx:                          0 1 3 4 5 6 8 9 11
    # Wait: `{"a":1,"b":2}` is 13 bytes: { " a " : 1 , " b " : 2 }
    #                                    0 1 2 3 4 5 6 7 8 9 10 11 12
    var idx = _idx_from_str('{"a":1,"b":2}')
    var expected_offsets: List[Int] = [0, 1, 3, 4, 6, 7, 9, 10, 12]
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACE,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_COMMA,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_CLOSE_BRACE,
    ]
    _expect_offsets(idx, expected_offsets)
    _expect_tags(idx, expected_tags)


# =============================================================================
# T5 — nested object
# =============================================================================


def test_nested_object() raises:
    # `{"a":{"b":1}}`. 13 bytes.
    # idx:        { " a " : { " b " : 1 } }
    # offsets:    0 1 2 3 4 5 6 7 8 9 10 11 12
    var idx = _idx_from_str('{"a":{"b":1}}')
    var expected_offsets: List[Int] = [0, 1, 3, 4, 5, 6, 8, 9, 11, 12]
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACE,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_OPEN_BRACE,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_CLOSE_BRACE,
        TAG_CLOSE_BRACE,
    ]
    _expect_offsets(idx, expected_offsets)
    _expect_tags(idx, expected_tags)


# =============================================================================
# T6 — flat array
# =============================================================================


def test_flat_array() raises:
    # `[1,2,3]`. 7 bytes. Structurals: [ , , ]
    # idx:                              0 2 4 6
    var idx = _idx_from_str("[1,2,3]")
    var expected_offsets: List[Int] = [0, 2, 4, 6]
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACKET,
        TAG_COMMA,
        TAG_COMMA,
        TAG_CLOSE_BRACKET,
    ]
    _expect_offsets(idx, expected_offsets)
    _expect_tags(idx, expected_tags)


# =============================================================================
# T7 — nested array
# =============================================================================


def test_nested_array() raises:
    # `[[1],[2]]`. 9 bytes.
    # idx:        [ [ 1 ] , [ 2 ] ]
    # offsets:    0 1 2 3 4 5 6 7 8
    var idx = _idx_from_str("[[1],[2]]")
    var expected_offsets: List[Int] = [0, 1, 3, 4, 5, 7, 8]
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACKET,
        TAG_OPEN_BRACKET,
        TAG_CLOSE_BRACKET,
        TAG_COMMA,
        TAG_OPEN_BRACKET,
        TAG_CLOSE_BRACKET,
        TAG_CLOSE_BRACKET,
    ]
    _expect_offsets(idx, expected_offsets)
    _expect_tags(idx, expected_tags)


# =============================================================================
# T8 — escaped quote inside string
# =============================================================================


def test_escaped_quote_in_string() raises:
    # `{"a":"b\"c"}`. 12 bytes.
    # idx:        { " a " : " b \ " c " }
    # offsets:    0 1 2 3 4 5 6 7 8 9 10 11
    # Quotes at 1 (open key), 3 (close key), 5 (open val), 10 (close val).
    # The quote at byte 8 is ESCAPED by the backslash at byte 7 — not a
    # structural.
    var idx = _idx_from_str('{"a":"b\\"c"}')
    var expected_offsets: List[Int] = [0, 1, 3, 4, 5, 10, 11]
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACE,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_CLOSE_BRACE,
    ]
    _expect_offsets(idx, expected_offsets)
    _expect_tags(idx, expected_tags)


# =============================================================================
# T9 — paired backslashes don't escape
# =============================================================================


def test_paired_backslashes_dont_escape() raises:
    # Mojo string literal `'{"a":"\\\\"}'` becomes the 10-byte runtime
    # string `{"a":"\\"}` (each `\\` in the literal is one `\` byte).
    # Byte stream: { " a " : " \ \ " }
    #               0 1 2 3 4 5 6 7 8 9
    # Backslashes at 6 and 7 form a pair — neither escapes the other or
    # the quote at 8 (per simdjson odd-length-run semantics).
    var idx = _idx_from_str('{"a":"\\\\"}')
    var expected_offsets: List[Int] = [0, 1, 3, 4, 5, 8, 9]
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACE,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_CLOSE_BRACE,
    ]
    _expect_offsets(idx, expected_offsets)
    _expect_tags(idx, expected_tags)


# =============================================================================
# T10 — string spanning 16-byte chunk boundary
# =============================================================================


def test_string_spans_chunk_boundary() raises:
    # 32-byte input that opens a string at byte 12 and closes at byte 20
    # — crossing the 16-byte chunk boundary.
    # `{"key":"aaaaaaaaa","b":1}`
    #   0123456789012345 6789012345
    # Let's count: { " k e y " : " a a a a a a a a a " , " b " : 1 }
    #              0 1 2 3 4 5 6 7 8 9 ...
    # Total chars: 1 + 5 + 1 + 11 + 1 + 3 + 1 + 1 + 1 + 1 = need to count exactly
    # `{"key":"aaaaaaaaa","b":1}`
    # Just let _scalar_count_structurals verify.
    var s = String('{"key":"aaaaaaaaa","b":1}')
    var idx = _idx_from_str(s)
    var bs = s.as_bytes()
    var expected_count = _scalar_count_structurals(bs)
    assert_equal(idx.size(), expected_count)
    # Specifically: { " k e y " : " a a a a a a a a a " , " b " : 1 }
    # offsets:      0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24
    # Structurals at: 0, 1, 5, 6, 7, 17, 18, 19, 21, 22, 24
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACE,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COMMA,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_CLOSE_BRACE,
    ]
    _expect_tags(idx, expected_tags)


# =============================================================================
# T11 — backslash at byte 15 escapes byte 16 (cross-chunk escape carry)
# =============================================================================


def test_backslash_cross_chunk_escape() raises:
    # Build a string where a backslash sits at chunk boundary (byte 15)
    # and escapes byte 16 (start of chunk 2).
    # `{"a":"xxxxxxxx\"yy"}` — 20 bytes:
    #   { " a " : " x x x x x x x x \ " y y " }
    #   0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19
    # Backslash at 14, escapes the quote at 15. Wait — chunk boundary is
    # at byte 16 (lanes 0..15 are chunk 1; byte 16 starts chunk 2).
    # Need backslash at 15 to escape byte 16:
    # `{"a":"xxxxxxxxx\"yy"}` — 21 bytes:
    #   { " a " : " x x x x x x x x x \ " y y " }
    #   0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20
    # Backslash at 15 escapes quote at 16.
    var s = String('{"a":"xxxxxxxxx\\"yy"}')
    var idx = _idx_from_str(s)
    var bs = s.as_bytes()
    var expected_count = _scalar_count_structurals(bs)
    assert_equal(idx.size(), expected_count)
    # Structurals: 0 ({), 1 (" open k), 3 (" close k), 4 (:),
    #              5 (" open v), 19 (" close v), 20 (}).
    var expected_offsets: List[Int] = [0, 1, 3, 4, 5, 19, 20]
    _expect_offsets(idx, expected_offsets)


# =============================================================================
# T12 — unterminated string raises
# =============================================================================


def test_unterminated_string_raises() raises:
    var raised = False
    try:
        var _idx = _idx_from_str('{"a":"oops')
    except _e:
        raised = True
    assert_true(raised)


# =============================================================================
# T13/T14/T15 — tail handling
# =============================================================================


def test_tail_below_16() raises:
    # 7-byte input — entirely in the tail path.
    var idx = _idx_from_str('{"a":1}')
    assert_equal(idx.size(), 5)


def test_tail_exactly_16() raises:
    # 16-byte input — runs through the SIMD loop once with 0 tail.
    # `{"abc":"defghi"}` — { " a b c " : " d e f g h i " }
    #   0 1 2 3 4 5 6 7 8 9 ...
    # Length check: 1+1+3+1+1+1+6+1+1 = 16. Good.
    var s = String('{"abc":"defghi"}')
    var idx = _idx_from_str(s)
    # Verify via scalar reference.
    var bs = s.as_bytes()
    var expected_count = _scalar_count_structurals(bs)
    assert_equal(idx.size(), expected_count)


def test_tail_17_bytes() raises:
    # 17-byte input — runs SIMD loop once + 1-byte tail.
    var s = String('{"abc":"defghix"}')
    # We need length 17 — { " a b c " : " d e f g h i x " }
    var idx = _idx_from_str(s)
    var bs = s.as_bytes()
    var expected_count = _scalar_count_structurals(bs)
    assert_equal(idx.size(), expected_count)


# =============================================================================
# T16 — large synthetic; correctness vs scalar reference
# =============================================================================


def test_large_synthetic_vs_scalar() raises:
    # Build a JSONL-shaped buffer of tweet-like records.
    # Wrap in an array; emit comma between elements only.
    var s = String("[")
    var i = 0
    while i < 20:
        if i > 0:
            s += ","
        s += '{"id":' + String(i) + ',"name":"alice"}'
        i += 1
    s += "]"
    var idx = _idx_from_str(s)
    var bs = s.as_bytes()
    var expected_count = _scalar_count_structurals(bs)
    assert_equal(idx.size(), expected_count)


# =============================================================================
# T17 — all whitespace
# =============================================================================


def test_all_whitespace() raises:
    var idx = _idx_from_str("                        ")
    assert_equal(idx.size(), 0)


# =============================================================================
# T18 — structurals inside string are ignored
# =============================================================================


def test_structurals_inside_string_ignored() raises:
    # `{"k":"a{b}c"}` — the inner { and } are inside the string.
    var idx = _idx_from_str('{"k":"a{b}c"}')
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACE,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_COLON,
        TAG_QUOTE_OPEN,
        TAG_QUOTE_CLOSE,
        TAG_CLOSE_BRACE,
    ]
    _expect_tags(idx, expected_tags)


# =============================================================================
# T19 — multiple top-level objects (JSONL)
# =============================================================================


def test_multiple_top_level_objects() raises:
    # `{}{}`. 4 structurals: { } { }
    var idx = _idx_from_str("{}{}")
    var expected_offsets: List[Int] = [0, 1, 2, 3]
    var expected_tags: List[UInt8] = [
        TAG_OPEN_BRACE,
        TAG_CLOSE_BRACE,
        TAG_OPEN_BRACE,
        TAG_CLOSE_BRACE,
    ]
    _expect_offsets(idx, expected_offsets)
    _expect_tags(idx, expected_tags)


# =============================================================================
# T20 — UTF-8 multi-byte char inside string
# =============================================================================


def test_utf8_in_string() raises:
    # `{"k":"héllo"}` — `é` is 2 bytes (C3 A9). Total: 14 bytes.
    # Structurals at: 0, 1, 3, 4, 5, 12, 13.
    var s = String('{"k":"héllo"}')
    var idx = _idx_from_str(s)
    var bs = s.as_bytes()
    var expected_count = _scalar_count_structurals(bs)
    assert_equal(idx.size(), expected_count)


# =============================================================================
# T21 — regression: structural-dense JSONL est_size overflow
# =============================================================================


def test_structural_dense_jsonl_no_overflow() raises:
    """Regression for the structural-dense estimate overflow.

    An estimate of `est_size = (n // 2) + 32` under-allocates for structural-dense JSONL like
    `{"id":N,"v":2N}\\n` where structural density is 9/17 = 52.9%.

    A 1501-byte fixture has 783 structural tokens but `est_size = 782`,
    a one-byte buffer overrun and corrupted scalar offsets at
    the file tail. Downstream materialize_jsonl_to_batch then sees
    garbage offsets and emits "empty scalar value after key at byte
    N" errors near end-of-input.

    `build_structural_index` uses `est_size = n + 32` (the JSON-grammar upper bound is
    `n` — every byte could be structural in pathological `[[[[...]]]]`
    shapes). This test asserts the index produces the right token
    count on a 1501-byte JSONL fixture matching the failure shape.
    """
    var s = String("")
    var line_count: Int = 0
    var bytes_written: Int = 0
    while bytes_written < 1500:
        var rec = (
            '{"id":' + String(line_count)
            + ',"v":' + String(line_count * 2)
            + '}\n'
        )
        s += rec
        bytes_written += rec.byte_length()
        line_count += 1
    var idx = _idx_from_str(s)
    var bs = s.as_bytes()
    var expected_count = _scalar_count_structurals(bs)
    assert_equal(idx.size(), expected_count)
    # 87 records × 9 structural tokens = 783 tokens. Verify the exact
    # count to lock in the regression.
    assert_equal(idx.size(), line_count * 9)


# =============================================================================
# main
# =============================================================================


def main() raises:
    test_empty_input()
    test_single_empty_object()
    test_single_kv()
    test_two_kv()
    test_nested_object()
    test_flat_array()
    test_nested_array()
    test_escaped_quote_in_string()
    test_paired_backslashes_dont_escape()
    test_string_spans_chunk_boundary()
    test_backslash_cross_chunk_escape()
    test_unterminated_string_raises()
    test_tail_below_16()
    test_tail_exactly_16()
    test_tail_17_bytes()
    test_large_synthetic_vs_scalar()
    test_all_whitespace()
    test_structurals_inside_string_ignored()
    test_multiple_top_level_objects()
    test_utf8_in_string()
    test_structural_dense_jsonl_no_overflow()
    print("structural_index: ALL TESTS PASS (21/21)")
