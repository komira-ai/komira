# =============================================================================
# Tests for CSV reader and chassis features.
# =============================================================================
#
# Coverage (10 cases):
#   T1   UTF-8 BOM strip: 0xEF 0xBB 0xBF prefix is silently consumed.
#   T2   UTF-8 BOM strict mode (strip_utf8_bom=False): BOM bytes survive
#        as first column's first cell.
#   T3   Projection fast-skip: subset of columns appears in output schema.
#   T4   Projection empty list = read all columns (default behavior).
#   T5   Per-column date_format registration + lookup.
#   T6   Per-column date_format cap exceeded -> raises.
#   T7   Projection cap exceeded -> raises.
#   T8   Csv[Rfc4180] parametric typed compile.
#   T9   Csv[Excel] != Csv[Posix] != Csv[Rfc4180] at the type level.
#   T10  Csv[Q].detect_extension("foo.csv") works for all 3 Q dialects.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false


from komira_arrow.arrow_types import ArrowType
from komira_arrow.formats import Csv
from komira_arrow.quote_styles import Excel, Posix, QuoteStyle, Rfc4180
from komira_arrow.schema import RecordBatch

from komira_csv import (
    CsvReadOptions,
    read_csv_bytes_to_batch,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def _bytes_with_bom(s: String) -> List[UInt8]:
    """Prefix bytes with UTF-8 BOM (0xEF 0xBB 0xBF)."""
    var out = List[UInt8]()
    out.append(UInt8(0xEF))
    out.append(UInt8(0xBB))
    out.append(UInt8(0xBF))
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


def test_utf8_bom_strip_default() raises:
    """T1: BOM prefix is silently consumed by default."""
    var buf = _bytes_with_bom(String("id,name\n1,alice\n2,bob\n"))
    var opts = CsvReadOptions()
    # default opts.strip_utf8_bom = True
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_columns(), 2, "BOM-strip: 2 columns")
    assert_equal(rb.num_rows(), 2, "BOM-strip: 2 data rows")
    # The first column name must be plain "id" — not "﻿id" (BOM-tainted).
    assert_equal(
        String(rb.schema.field_at(0).name),
        String("id"),
        "BOM-strip: first column name is clean 'id'",
    )


def test_utf8_bom_strict_mode() raises:
    """T2: BOM strict mode (strip_utf8_bom=False): BOM bytes survive."""
    var buf = _bytes_with_bom(String("id,name\n1,alice\n"))
    var opts = CsvReadOptions()
    opts.strip_utf8_bom = False
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    # The first column name is now BOM-tainted; we just verify the count
    # of columns + rows matches the no-BOM-strip wire interpretation.
    # In this mode, "id" -> "﻿id" (3 BOM bytes + "id") -> still
    # parses as a column name (no delimiter / newline in the BOM bytes).
    assert_equal(rb.num_columns(), 2, "strict BOM: 2 columns")
    assert_equal(rb.num_rows(), 1, "strict BOM: 1 data row")
    # First column name is NOT plain "id" — it carries the 3 BOM bytes.
    assert_false(
        String(rb.schema.field_at(0).name) == String("id"),
        "strict BOM: first column name is NOT plain 'id'",
    )


def test_projection_fast_skip() raises:
    """T3: Projection fast-skip yields only requested columns."""
    var buf = _bytes(String("a,b,c\n1,10,100\n2,20,200\n"))
    var opts = CsvReadOptions()
    opts.with_projection(String("a"))
    opts.with_projection(String("c"))
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    # Output schema is the projection subset: {a, c} only.
    assert_equal(rb.num_columns(), 2, "projection: 2 columns")
    assert_equal(rb.num_rows(), 2, "projection: 2 rows")
    assert_equal(
        String(rb.schema.field_at(0).name), String("a"), "first col is 'a'"
    )
    assert_equal(
        String(rb.schema.field_at(1).name), String("c"), "second col is 'c'"
    )


def test_projection_empty_reads_all() raises:
    """T4: Empty projection list = read all columns (default behavior)."""
    var buf = _bytes(String("a,b,c\n1,2,3\n"))
    var opts = CsvReadOptions()
    # No with_projection calls -> projection list empty -> read all.
    var rb = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts)
    assert_equal(rb.num_columns(), 3, "no projection: read all 3 columns")
    assert_equal(rb.num_rows(), 1, "no projection: 1 row")


def test_per_column_date_format_lookup() raises:
    """T5: Per-column date_format registration + lookup roundtrip."""
    var opts = CsvReadOptions()
    opts.with_per_column_date_format(
        String("birth_date"), String("MM/DD/YYYY")
    )
    opts.with_per_column_date_format(
        String("event_date"), String("DD-MM-YYYY")
    )
    # Lookup hits
    assert_equal(
        opts.get_per_column_date_format(String("birth_date")),
        String("MM/DD/YYYY"),
        "per-column lookup birth_date",
    )
    assert_equal(
        opts.get_per_column_date_format(String("event_date")),
        String("DD-MM-YYYY"),
        "per-column lookup event_date",
    )
    # Lookup miss falls back to global date_format (default empty)
    assert_equal(
        opts.get_per_column_date_format(String("unknown_col")),
        String(""),
        "per-column lookup miss returns global default",
    )


def test_per_column_date_format_cap_exceeded() raises:
    """T6: Per-column date_format cap (MAX_DATE_FORMATS=8) exceeded raises."""
    var opts = CsvReadOptions()
    # Register 8 — the cap.
    opts.with_per_column_date_format(String("c0"), String("f0"))
    opts.with_per_column_date_format(String("c1"), String("f1"))
    opts.with_per_column_date_format(String("c2"), String("f2"))
    opts.with_per_column_date_format(String("c3"), String("f3"))
    opts.with_per_column_date_format(String("c4"), String("f4"))
    opts.with_per_column_date_format(String("c5"), String("f5"))
    opts.with_per_column_date_format(String("c6"), String("f6"))
    opts.with_per_column_date_format(String("c7"), String("f7"))
    # The 9th raises.
    var raised = False
    try:
        opts.with_per_column_date_format(String("c8"), String("f8"))
    except _:
        raised = True
    assert_true(raised, "9th per-column date_format must raise (cap=8)")


def test_projection_cap_exceeded() raises:
    """T7: Projection cap (8) exceeded raises a clear error."""
    var opts = CsvReadOptions()
    var i = 0
    while i < 8:
        opts.with_projection(String("c") + String(i))
        i = i + 1
    var raised = False
    try:
        opts.with_projection(String("c8"))
    except _:
        raised = True
    assert_true(raised, "9th projection column must raise (cap=8)")


def test_csv_parametric_typed_compile() raises:
    """T8: Csv[Q] parametric type compiles for all 3 Q conformers."""
    # Static-compile checks (constrained at runtime here, since the spike
    # showed L1 (constructor) GREEN — the typed-form smoke is the safer
    # gate).
    var c1 = Csv[Rfc4180]()
    var c2 = Csv[Excel]()
    var c3 = Csv[Posix]()
    # Each is a fresh zero-byte struct; smoke check.
    _ = c1
    _ = c2
    _ = c3


def test_csv_per_q_type_identity() raises:
    """T9: Csv[Excel] != Csv[Posix] != Csv[Rfc4180] at the type level."""
    comptime assert not (Csv[Rfc4180] == Csv[Excel]), "Csv[Rfc4180] and Csv[Excel] must be distinct types"
    comptime assert not (Csv[Rfc4180] == Csv[Posix]), "Csv[Rfc4180] and Csv[Posix] must be distinct types"
    comptime assert not (Csv[Excel] == Csv[Posix]), "Csv[Excel] and Csv[Posix] must be distinct types"
    comptime assert (Csv[Rfc4180] == Csv[Rfc4180]), "Csv[Rfc4180] == Csv[Rfc4180]"


def test_csv_per_q_detect_extension() raises:
    """T10: Csv[Q].detect_extension('foo.csv') works for all 3 Q dialects.

    The detect_extension is a static method on the family marker — should
    give the same result regardless of Q (the dialect determines parsing,
    not file-extension recognition).
    """
    assert_true(
        Csv[Rfc4180].detect_extension(String("foo.csv")),
        "Csv[Rfc4180] detects .csv",
    )
    assert_true(
        Csv[Excel].detect_extension(String("foo.csv")),
        "Csv[Excel] detects .csv",
    )
    assert_true(
        Csv[Posix].detect_extension(String("foo.csv")),
        "Csv[Posix] detects .csv",
    )


def main() raises:
    test_utf8_bom_strip_default()
    test_utf8_bom_strict_mode()
    test_projection_fast_skip()
    test_projection_empty_reads_all()
    test_per_column_date_format_lookup()
    test_per_column_date_format_cap_exceeded()
    test_projection_cap_exceeded()
    test_csv_parametric_typed_compile()
    test_csv_per_q_type_identity()
    test_csv_per_q_detect_extension()
    print("test_csv_phase_b: 10/10 PASS")
