# =============================================================================
# tests/sdk/test_display_width_non_ascii.mojo
#   `format_table` aligns COLUMNS. A column is a count of characters, not of
#   UTF-8 bytes — pin that the box stays square when a cell is not ASCII.
# =============================================================================
#
# WHY THIS EXISTS. `table_display.mojo` computes each column's width and then
# pads every cell to it. Both halves used `len()`, which on a Mojo `String` is
# the UTF-8 BYTE count, so for any non-ASCII cell the width is over-counted
# while the padding under-counts, and the two errors do NOT cancel:
#
#   value "café"  -> len() = 5 bytes, 4 characters
#   width  w      = max(len("name")=4, len("café")=5) = 5
#   pad          = w - len("café") = 5 - 5 = 0
#   rendered row  "| café |"      <- 4 columns of text in a 5-wide cell
#   separator     "+-------+"     <- drawn for 5 + 2
#
# The row is one column SHORT of its own rule and the table visibly breaks. It
# gets worse with width: an emoji is 4 bytes to 1 column, so a single emoji cell
# skews its column by 3.
#
# THE UNIT IS DECIDABLE HERE. `_pad_right`'s entire job is visual alignment, so
# the question "bytes or characters" has an answer that the surrounding code
# states: the separator rule is drawn in CHARACTERS (`for _ in range(w + 2)`
# appends one `-` per iteration), so the width it is drawn from must be a
# character count or the two can never agree. `count_codepoints()` it is.
#
# ⚠ CODEPOINTS IS CORRECT, NOT PERFECT, AND THE REMAINDER IS DELIBERATE. Terminal
# display width is a wcwidth problem, not a codepoint count: East-Asian wide
# characters occupy 2 terminal columns and combining marks occupy 0, so a CJK
# table is still not square under either rule. Codepoints is EXACTLY right for
# the dominant non-ASCII case (Latin with diacritics — 2 bytes, 1 codepoint, 1
# column) and strictly closer than bytes everywhere else. This test therefore
# asserts exactness on accented Latin and does not claim it for CJK.
#
# Encapsulation: RecordBatch in, String out. No UnsafePointer, no wildcard
# origin.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.schema import (
    Field,
    RecordBatch,
    RecordBatchBuilder,
    SchemaBuilder,
)
from komira_arrow.string_array import StringArray

from komira_sdk.table_display import format_table


def _string_batch(name: String, vals: List[String]) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(name, ArrowType.STRING, False))
    var schema = sb.build()
    var builder = RecordBatchBuilder()
    builder.add_column(Column.from_string(StringArray.from_strings(vals)))
    return builder.build(schema^)


def _box_lines(table: String) raises -> List[String]:
    """The lines of `table` that are part of the box — the ones that open with
    `+` or `|`. The trailing "N rows" summary is not part of the grid.

    Splitting on `"\\n"` is safe for arbitrary UTF-8: `\\n` is 0x0A and no byte
    of a multi-byte sequence is ever < 0x80, so a newline can never appear
    inside a character."""
    var out = List[String]()
    for piece in table.split(String("\n")):
        var line = String(piece)
        if line.startswith(String("+")) or line.startswith(String("|")):
            out.append(line^)
    return out^


def _assert_square(table: String, why: String) raises:
    """Every box line must be the same number of CHARACTERS wide. This is the
    whole property; it is false today for any non-ASCII cell."""
    var lines = _box_lines(table)
    assert_true(len(lines) >= 2, "the table has a grid at all: " + why)
    var want = lines[0].count_codepoints()
    for i in range(len(lines)):
        assert_equal(
            lines[i].count_codepoints(),
            want,
            why
            + " — box line "
            + String(i)
            + " is "
            + String(lines[i].count_codepoints())
            + " characters, the rule is "
            + String(want)
            + ": >"
            + lines[i]
            + "<",
        )


def test_ascii_table_is_square() raises:
    """The invariant holds today for ASCII. This leg is the control: it must
    stay green across the fix, proving the change moved nothing for the 99%
    case and that `_assert_square` is not vacuous."""
    var vals: List[String] = ["alice", "bob", "carol"]
    var table = format_table(_string_batch(String("name"), vals))
    _assert_square(table, String("an all-ASCII table"))
    print("    [OK] ASCII table is square (control)")


def test_accented_latin_table_is_square() raises:
    """THE FALSIFIER. `café` is 5 UTF-8 bytes and 4 characters. Under byte
    widths the data row renders one column narrower than its own separator."""
    var vals: List[String] = ["café", "bob"]
    assert_equal(vals[0].byte_length(), 5, "café is 5 UTF-8 bytes")
    assert_equal(vals[0].count_codepoints(), 4, "café is 4 characters")

    var table = format_table(_string_batch(String("name"), vals))
    _assert_square(table, String("a table with an accented-Latin cell"))
    print("    [OK] accented-Latin cell — table stays square")


def test_emoji_cell_table_is_square() raises:
    """The widest skew: 4 bytes to 1 character. A single emoji cell threw its
    column off by 3."""
    var vals: List[String] = ["🔒", "ok"]
    assert_equal(vals[0].byte_length(), 4, "the emoji is 4 UTF-8 bytes")
    assert_equal(vals[0].count_codepoints(), 1, "the emoji is 1 character")

    var table = format_table(_string_batch(String("name"), vals))
    _assert_square(table, String("a table with an emoji cell"))
    print("    [OK] emoji cell — table stays square")


def test_non_ascii_column_NAME_is_square() raises:
    """The width seed is the column NAME, not just the cells — a non-ASCII
    header skews the same way."""
    var vals: List[String] = ["a", "b"]
    var table = format_table(_string_batch(String("prénom"), vals))
    _assert_square(table, String("a table with an accented column name"))
    print("    [OK] accented column name — table stays square")


def main() raises:
    print(
        "=== format_table aligns CHARACTERS, not UTF-8 bytes"
        " (the separator rule is drawn per-character) ==="
    )
    test_ascii_table_is_square()
    test_accented_latin_table_is_square()
    test_emoji_cell_table_is_square()
    test_non_ascii_column_NAME_is_square()
    print("=== all display-width legs passed ===")
