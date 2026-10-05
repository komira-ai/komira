# =============================================================================
# Tests for SIMD STRING column builder.
# =============================================================================
#
#
# Goal: verify the SIMD-vectorized STRING column builder
# (`string_column_simd.build_string_column_simd`) produces byte-identical
# results to the prior `cell_to_string` + `StringArray.from_strings`
# baseline on every applicable input AND correctly handles edge cases.
#
# Test taxonomy:
#   T1  escaped-quote handling (`""` -> `"`) — Rfc4180 / Excel double-quote
#       collapse parity with the scalar `unescape_cell_double_quote` baseline.
#   T2  multi-byte UTF-8 content — non-ASCII bytes (0x80-0xFF continuation
#       bytes) must pass through bulk memcpy with no false-positive on
#       quote-byte detection.
#   T3  mixed-length cells — short cells (1-3 bytes) interleaved with
#       long cells (32-128 bytes) to exercise the bulk memcpy across both
#       sub-SIMD-width and multi-SIMD-width payloads in the same batch.
#   T4  all-empty column fast path — every cell is the empty string;
#       output offsets are all 0; data buffer is length 1 (min alloc);
#       validity = None (no nulls means no bitmap allocated).
#
# Each test exercises `read_csv_bytes_to_batch` (Phase 3 single-thread)
# end-to-end so the new STRING column builder is on the actual production
# path. The serial reader and parallel reader share the same helper
# (`build_string_column_simd`), so a serial test covers both paths.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType

from komira_csv import (
    CsvReadOptions,
    Rfc4180,
    Posix,
    read_csv_bytes_to_batch,
)


def _bytes(s: String) -> List[UInt8]:
    """Convert a String to a List[UInt8] for test fixtures."""
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


# =============================================================================
# T1: escaped-quote handling (`""` -> `"`).
# =============================================================================


def test_t1_escaped_quote_handling() raises:
    """T1: doubled-quote collapse parity.

    Exercises the `_collapse_doubled_quote_into_buf` path. Per RFC-4180,
    an escaped quote inside a quoted cell is represented as two
    consecutive quote bytes; the unescaper collapses them to one.

    Fixture covers:
      - simple doubled-quote collapse: a-quote-b
      - back-to-back collapses
      - boundary collapse at start / end
      - empty quoted cell
    """
    # Single column ("text"), 4 rows.
    var buf = _bytes(String(
        "text\n"
        "\"a\"\"b\"\n"          # a"b
        "\"\"\"\"\n"              # "
        "\"\"\"hello\"\"\"\n"     # "hello"
        "\"\"\n"                  # empty
    ))
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_rows(), 4, "4 rows")
    assert_equal(rb.num_columns(), 1)
    assert_true(
        rb.schema.field_at(0).arrow_type == ArrowType.STRING,
        "text col is STRING",
    )
    ref col = rb.column_at(0)
    var sarr = col.as_string()
    assert_equal(sarr.get(0), String("a\"b"), "row 0: a\"b")
    assert_equal(sarr.get(1), String("\""), "row 1: lone quote")
    assert_equal(sarr.get(2), String("\"hello\""), "row 2: quoted hello")
    assert_equal(sarr.get(3), String(""), "row 3: empty")


# =============================================================================
# T2: multi-byte UTF-8 content (no false-positive on continuation bytes).
# =============================================================================


def test_t2_multibyte_utf8_passthrough() raises:
    """T2: multi-byte UTF-8 cells survive bulk memcpy unchanged.

    Bulk memcpy is byte-blind (it just copies N bytes), so this test
    establishes that the SIMD fast path does NOT decode/inspect cell
    bytes -- it should treat them as opaque bytes. This is the same
    behavior as the scalar baseline.

    Fixture includes:
      - 2-byte sequences: U+00E9 = 0xC3 0xA9 (`é`)
      - 3-byte sequences: U+4E2D = 0xE4 0xB8 0xAD (`中`)
      - 4-byte sequences: U+1F600 = 0xF0 0x9F 0x98 0x80 (`😀`)
      - mixed ASCII + multi-byte: `Hello 世界`
    """
    # Construct fixture as raw bytes (Mojo String literal handling of
    # arbitrary UTF-8 sequences can vary, so we build the buffer byte-by-byte
    # for the multi-byte cells but use String for ASCII / header.
    var buf = List[UInt8]()
    # Header: "text\n"
    var hdr = String("text\n").as_bytes()
    for i in range(len(hdr)):
        buf.append(hdr[i])
    # Row 0: 'café' = c(0x63) a(0x61) f(0x66) é(0xC3 0xA9) + \n
    buf.append(UInt8(0x63))
    buf.append(UInt8(0x61))
    buf.append(UInt8(0x66))
    buf.append(UInt8(0xC3))
    buf.append(UInt8(0xA9))
    buf.append(UInt8(0x0A))
    # Row 1: '中' = 0xE4 0xB8 0xAD + \n
    buf.append(UInt8(0xE4))
    buf.append(UInt8(0xB8))
    buf.append(UInt8(0xAD))
    buf.append(UInt8(0x0A))
    # Row 2: '😀' = 0xF0 0x9F 0x98 0x80 + \n
    buf.append(UInt8(0xF0))
    buf.append(UInt8(0x9F))
    buf.append(UInt8(0x98))
    buf.append(UInt8(0x80))
    buf.append(UInt8(0x0A))
    # Row 3: 'Hello 世界' = 'H' 'e' 'l' 'l' 'o' ' ' (0xE4 0xB8 0x96)(0xE7 0x95 0x8C) + \n
    var hello = String("Hello ").as_bytes()
    for i in range(len(hello)):
        buf.append(hello[i])
    buf.append(UInt8(0xE4))
    buf.append(UInt8(0xB8))
    buf.append(UInt8(0x96))
    buf.append(UInt8(0xE7))
    buf.append(UInt8(0x95))
    buf.append(UInt8(0x8C))
    buf.append(UInt8(0x0A))

    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_rows(), 4, "4 multi-byte rows")
    assert_equal(rb.num_columns(), 1)
    ref col = rb.column_at(0)
    var sarr = col.as_string()
    # Verify byte-level equality via the underlying view.
    # Row 0: 'café' -> 5 bytes
    var s0 = sarr.get(0)
    assert_equal(len(s0.as_bytes()), 5, "row 0: 5 bytes (1 multi-byte char)")
    # Row 1: '中' -> 3 bytes
    var s1 = sarr.get(1)
    assert_equal(len(s1.as_bytes()), 3, "row 1: 3 bytes (1 CJK char)")
    # Row 2: '😀' -> 4 bytes
    var s2 = sarr.get(2)
    assert_equal(len(s2.as_bytes()), 4, "row 2: 4 bytes (1 emoji)")
    # Row 3: 'Hello 世界' -> 6 ASCII + 6 multi-byte = 12 bytes
    var s3 = sarr.get(3)
    assert_equal(
        len(s3.as_bytes()), 12, "row 3: 12 bytes (6 ASCII + 2 CJK)"
    )
    # Verify specific bytes for row 1 (smallest test case to spot-check).
    var s1b = s1.as_bytes()
    assert_equal(Int(s1b[0]), 0xE4, "row 1 byte 0")
    assert_equal(Int(s1b[1]), 0xB8, "row 1 byte 1")
    assert_equal(Int(s1b[2]), 0xAD, "row 1 byte 2")


# =============================================================================
# T3: mixed-length cells (short + long alternating).
# =============================================================================


def test_t3_mixed_length_cells() raises:
    """T3: short (1-3 byte) and long (32-128 byte) cells interleaved.

    The bulk memcpy path varies in efficiency by cell length:
      - sub-SIMD-width cells (<16 bytes) may inline as scalar moves
      - multi-SIMD-width cells (32-128 bytes) trigger wide vector loads
    Both must produce byte-identical output.

    Fixture: alternating short codes ("AA", "BB", "CC", "DD") and 64-byte
    payloads (repeated patterns easy to verify).
    """
    # Long payload: 64-byte alphabet repeat.
    var long1 = String("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#$%^&*()abcdefghijklmnopqr")  # exactly 64 bytes
    assert_equal(len(long1.as_bytes()), 64, "long1 sanity: 64 bytes")
    # Build CSV: header + 8 rows alternating short and long.
    var s = String("code\n")
    s += String("AA\n")
    s += long1 + String("\n")
    s += String("BB\n")
    s += long1 + String("\n")
    s += String("CC\n")
    s += long1 + String("\n")
    s += String("DD\n")
    s += long1 + String("\n")
    var buf = _bytes(s)
    var opts = CsvReadOptions()
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_rows(), 8, "8 rows")
    assert_equal(rb.num_columns(), 1)
    ref col = rb.column_at(0)
    var sarr = col.as_string()
    assert_equal(sarr.get(0), String("AA"), "row 0 short")
    assert_equal(sarr.get(1), long1, "row 1 long (64 bytes)")
    assert_equal(sarr.get(2), String("BB"), "row 2 short")
    assert_equal(sarr.get(3), long1, "row 3 long")
    assert_equal(sarr.get(4), String("CC"), "row 4 short")
    assert_equal(sarr.get(5), long1, "row 5 long")
    assert_equal(sarr.get(6), String("DD"), "row 6 short")
    assert_equal(sarr.get(7), long1, "row 7 long")


# =============================================================================
# T4: all-empty column fast path (validity = None).
# =============================================================================


def test_t4_all_empty_column_fast_path() raises:
    """T4: every cell is the empty string -> all-valid fast path.

    Empty strings in CSV are written as zero-length cells (e.g.
    `a,,c\\n` -> middle column is empty). When the null-token cascade is
    configured (default pandas-parity: empty matches null), empty cells
    become NULLS, not empty strings. To test the all-empty STRING case,
    we use a non-default options set with NO null tokens, so empty cells
    are actually empty strings (zero-byte payloads).

    Expected:
      - 4 rows, all with empty STRING cells
      - StringArray has zero data_length
      - StringArray.validity is None (no nulls, since strict-no-null mode)
      - all offsets are 0
    """
    var buf = _bytes(String("text\n\n\n\n\n"))
    # Strict mode: NO null tokens -> empty cells coerce to empty string.
    # This is the "strict" CsvReadOptions config (set _n_null_strings = 0).
    var opts = CsvReadOptions()
    opts._n_null_strings = 0  # Strict-no-null mode.
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_rows(), 4, "4 rows")
    assert_equal(rb.num_columns(), 1)
    ref col = rb.column_at(0)
    var sarr = col.as_string()
    # All cells empty -> data_length is 0
    assert_equal(sarr.data_length, 0, "data_length == 0 (all empty)")
    # No nulls -> validity is None (the all-valid fast path)
    assert_false(
        Bool(sarr.validity), "validity is None (no nulls in all-empty case)"
    )
    # All offsets are 0
    var i = 0
    while i < 4:
        assert_equal(sarr.get(i), String(""), "row " + String(i) + " is empty")
        i = i + 1
    # null_count is 0
    assert_equal(sarr.null_count, 0, "null_count == 0")


# =============================================================================
# Driver.
# =============================================================================


def main() raises:
    test_t1_escaped_quote_handling()
    test_t2_multibyte_utf8_passthrough()
    test_t3_mixed_length_cells()
    test_t4_all_empty_column_fast_path()
    print("test_csv_simd_string_column: 4/4 PASS")
