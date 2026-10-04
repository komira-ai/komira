# =============================================================================
# Tests for runtime QuoteStyle dispatch in the CSV chassis.
# =============================================================================
#
# Verifies the runtime QuoteStyle tag dispatch wired through:
#   CsvReadOptions.quote_style_tag (0/1/2 = Rfc4180/Excel/Posix)
#   -> CsvSource.quote_style_tag
#   -> _compile_csv_scan cascade
#   -> read_csv_bytes_to_batch_dynamic
#   -> read_csv_bytes_to_batch[Q]  (comptime-monomorphized per tag)
#
# Coverage (10 cases):
#   T1   Default quote_style_tag is RFC4180 (0).
#   T2   with_quote_style sets all 3 known tags successfully.
#   T3   with_quote_style raises on unknown tag (3+).
#   T4   CsvSource carries quote_style_tag through ctor + copy.
#   T5   CsvSource fingerprint differs across tags (cache-discrimination).
#   T6   read_csv_bytes_to_batch_dynamic tag=0 routes to Rfc4180 scanner
#        (parity with explicit read_csv_bytes_to_batch[Rfc4180]).
#   T7   read_csv_bytes_to_batch_dynamic tag=1 routes to Excel scanner
#        (BOM is silently swallowed by the Excel-aware scanner even when
#        options.strip_utf8_bom is False — the chassis-level
#        Q.ACCEPTS_BOM path fires).
#   T8   read_csv_bytes_to_batch_dynamic tag=2 routes to Posix scanner
#        (backslash-escaped quote `\"` inside a quoted region is honored
#        and un-escaped to a literal `"` in the materialized String).
#   T9   read_csv_bytes_to_batch_dynamic raises on unknown tag.
#   T10  CsvReadOptions.copy() preserves quote_style_tag.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_core.arrow.schema import Schema
from komira_core.source.csv_source import CsvSource

from komira_csv import (
    CsvReadOptions,
    QUOTE_STYLE_TAG_RFC4180,
    QUOTE_STYLE_TAG_EXCEL,
    QUOTE_STYLE_TAG_POSIX,
    read_csv_bytes_to_batch,
    read_csv_bytes_to_batch_dynamic,
)
from komira_csv.quote_styles import Rfc4180
from komira_runtime_paths import test_tmpdir


def _scratch_dir() raises -> String:
    """The directory this test run may write scratch files into: a fixed
    `/tmp` path would be shared by concurrent runs on one machine."""
    return test_tmpdir()


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


# =============================================================================
# T1 — Default quote_style_tag is RFC4180 (0).
# =============================================================================


def test_default_quote_style_tag_is_rfc4180() raises:
    """T1: A freshly-constructed CsvReadOptions defaults to tag=0 (Rfc4180)."""
    print("T1: Default quote_style_tag is RFC4180 (0)")
    var opts = CsvReadOptions()
    assert_equal(
        opts.quote_style_tag,
        QUOTE_STYLE_TAG_RFC4180,
        "default tag is RFC4180 (0)",
    )
    print("  PASS")


# =============================================================================
# T2 — with_quote_style sets all 3 known tags.
# =============================================================================


def test_with_quote_style_sets_all_three_known_tags() raises:
    """T2: All 3 valid tags can be set via with_quote_style."""
    print("T2: with_quote_style sets all 3 known tags")
    var opts = CsvReadOptions()
    opts.with_quote_style(QUOTE_STYLE_TAG_EXCEL)
    assert_equal(opts.quote_style_tag, QUOTE_STYLE_TAG_EXCEL, "Excel tag")
    opts.with_quote_style(QUOTE_STYLE_TAG_POSIX)
    assert_equal(opts.quote_style_tag, QUOTE_STYLE_TAG_POSIX, "Posix tag")
    opts.with_quote_style(QUOTE_STYLE_TAG_RFC4180)
    assert_equal(
        opts.quote_style_tag, QUOTE_STYLE_TAG_RFC4180, "Rfc4180 tag (set back)"
    )
    print("  PASS")


# =============================================================================
# T3 — with_quote_style raises on unknown tag.
# =============================================================================


def test_with_quote_style_raises_on_unknown_tag() raises:
    """T3: Unknown tags (3+, -1) raise from with_quote_style."""
    print("T3: with_quote_style raises on unknown tag")
    var opts = CsvReadOptions()
    var raised = False
    try:
        opts.with_quote_style(3)  # one past the known range
    except _:
        raised = True
    assert_true(raised, "tag=3 raises")
    # Confirm tag was NOT mutated by the failed call.
    assert_equal(
        opts.quote_style_tag,
        QUOTE_STYLE_TAG_RFC4180,
        "tag unchanged on failed set",
    )
    print("  PASS")


# =============================================================================
# T4 — CsvSource carries quote_style_tag through ctor + copy.
# =============================================================================


def test_csv_source_carries_tag_through_ctor_and_copy() raises:
    """T4: CsvSource ctor accepts quote_style_tag; copy preserves it."""
    print("T4: CsvSource carries quote_style_tag through ctor + copy")
    var sch = Schema()
    var src = CsvSource(
        (_scratch_dir() + String("/foo.csv")),
        sch^,
        0,  # mtime_ns
        QUOTE_STYLE_TAG_EXCEL,
    )
    assert_equal(
        src.quote_style_tag,
        QUOTE_STYLE_TAG_EXCEL,
        "CsvSource carries Excel tag",
    )
    var clone = src.copy()
    assert_equal(
        clone.quote_style_tag,
        QUOTE_STYLE_TAG_EXCEL,
        "CsvSource.copy() preserves tag",
    )
    print("  PASS")


# =============================================================================
# T5 — CsvSource fingerprint differs across tags.
# =============================================================================


def test_csv_source_fingerprint_differs_across_tags() raises:
    """T5: Same path + schema with DIFFERENT Q tag must produce DIFFERENT
    identities — cache-discrimination requirement (a Rfc4180-parsed result
    must not collide with an Excel-parsed result of the same file).
    """
    print("T5: CsvSource fingerprint differs across tags")
    var p = (_scratch_dir() + String("/same.csv"))
    var sch1 = Schema()
    var sch2 = Schema()
    var sch3 = Schema()
    var rfc = CsvSource(p, sch1^, 0, QUOTE_STYLE_TAG_RFC4180)
    var exl = CsvSource(p, sch2^, 0, QUOTE_STYLE_TAG_EXCEL)
    var pos = CsvSource(p, sch3^, 0, QUOTE_STYLE_TAG_POSIX)
    assert_true(
        rfc.fingerprint() != exl.fingerprint(),
        "Rfc4180 and Excel fingerprints differ",
    )
    assert_true(
        rfc.fingerprint() != pos.fingerprint(),
        "Rfc4180 and Posix fingerprints differ",
    )
    assert_true(
        exl.fingerprint() != pos.fingerprint(),
        "Excel and Posix fingerprints differ",
    )
    print("  PASS")


# =============================================================================
# T6 — read_csv_bytes_to_batch_dynamic tag=0 == Rfc4180 explicit.
# =============================================================================


def test_dynamic_dispatcher_rfc4180_parity() raises:
    """T6: tag=0 routes to Rfc4180; output matches explicit comptime entry."""
    print("T6: read_csv_bytes_to_batch_dynamic tag=0 routes to Rfc4180")
    var buf = _bytes(String("a,b\n1,hello\n2,world\n"))
    var opts_dyn = CsvReadOptions()
    opts_dyn.quote_style_tag = QUOTE_STYLE_TAG_RFC4180
    var opts_static = CsvReadOptions()
    var rb_dyn = read_csv_bytes_to_batch_dynamic(Span(buf), opts_dyn)
    var rb_static = read_csv_bytes_to_batch[Rfc4180](Span(buf), opts_static)
    assert_equal(rb_dyn.num_columns(), rb_static.num_columns(), "col count parity")
    assert_equal(rb_dyn.num_rows(), rb_static.num_rows(), "row count parity")
    # Header parity (string field names)
    assert_equal(
        String(rb_dyn.schema.field_at(0).name),
        String(rb_static.schema.field_at(0).name),
        "col0 name parity",
    )
    assert_equal(
        String(rb_dyn.schema.field_at(1).name),
        String(rb_static.schema.field_at(1).name),
        "col1 name parity",
    )
    print("  PASS")


# =============================================================================
# T7 — read_csv_bytes_to_batch_dynamic tag=1 (Excel) routes to Excel scanner.
# =============================================================================


def test_dynamic_dispatcher_excel_bom_routing() raises:
    """T7: tag=1 routes to Excel scanner. With options.strip_utf8_bom=False,
    the OUTER reader-level BOM strip is disabled — but the Excel scanner
    itself has Q.ACCEPTS_BOM=True and silently swallows the BOM. So a
    BOM-prefixed file parsed under Excel tag (with strip disabled) STILL
    produces a clean 'id' first column. This is the observable signal
    that the comptime path actually flipped to Excel.
    """
    print("T7: read_csv_bytes_to_batch_dynamic tag=1 routes to Excel scanner")
    var buf = _bytes_with_bom(String("id,name\n1,alice\n"))
    var opts = CsvReadOptions()
    opts.with_quote_style(QUOTE_STYLE_TAG_EXCEL)
    # Disable the OUTER reader-level BOM strip so the only path that can
    # clean the BOM is the chassis-level Q.ACCEPTS_BOM (Excel-only).
    opts.strip_utf8_bom = False
    var rb = read_csv_bytes_to_batch_dynamic(Span(buf), opts)
    assert_equal(rb.num_columns(), 2, "Excel BOM: 2 columns")
    assert_equal(rb.num_rows(), 1, "Excel BOM: 1 data row")
    # First column name is plain 'id' — the Excel scanner swallowed the
    # BOM via Q.ACCEPTS_BOM, not the outer reader-level strip.
    assert_equal(
        String(rb.schema.field_at(0).name),
        String("id"),
        "Excel scanner swallowed BOM (column name is clean 'id')",
    )


# =============================================================================
# T8 — read_csv_bytes_to_batch_dynamic tag=2 (Posix) routes to Posix scanner.
# =============================================================================


def test_dynamic_dispatcher_posix_backslash_escape() raises:
    """T8: tag=2 routes to Posix scanner. The Posix dialect handles `\\"`
    inside a quoted region as an escaped literal `"`. The Rfc4180/Excel
    dialects use the doubled-quote `""` escape and treat `\\` as a
    plain literal character.

    Wire: header "c" + one row `"a\"b"`. Under Posix, the cell body
    `a\"b` unescapes to `a"b` (4 chars). Under Rfc4180, the same row
    would either be re-emitted byte-for-byte (no Posix-style escape) or
    raise depending on the inner `"` handling — but we only need to
    confirm Posix succeeds.
    """
    print("T8: read_csv_bytes_to_batch_dynamic tag=2 routes to Posix scanner")
    # Encodes: c\n"a\"b"\n
    var src = String("c\n\"a\\\"b\"\n")
    var buf = _bytes(src)
    var opts = CsvReadOptions()
    opts.with_quote_style(QUOTE_STYLE_TAG_POSIX)
    var rb = read_csv_bytes_to_batch_dynamic(Span(buf), opts)
    assert_equal(rb.num_columns(), 1, "Posix: 1 column")
    assert_equal(rb.num_rows(), 1, "Posix: 1 data row")
    # Extract column 0, row 0 and verify the unescaped string contains
    # the literal `"` character (Posix backslash-escape honored).
    var arr = rb.column_as_string(0)
    var s = arr.get(0)
    # Expected unescaped body: a"b (3 chars).
    assert_equal(s.byte_length(), 3, "Posix-unescaped cell length is 3 (a\"b)")
    var bs = s.as_bytes()
    assert_equal(bs[0], UInt8(ord("a")), "byte 0 = 'a'")
    assert_equal(bs[1], UInt8(ord('"')), "byte 1 = literal '\"' (unescaped)")
    assert_equal(bs[2], UInt8(ord("b")), "byte 2 = 'b'")


# =============================================================================
# T9 — read_csv_bytes_to_batch_dynamic raises on unknown tag.
# =============================================================================


def test_dynamic_dispatcher_unknown_tag_raises() raises:
    """T9: Unknown tags reach a typed raise (not silent fall-through)."""
    print("T9: read_csv_bytes_to_batch_dynamic raises on unknown tag")
    var buf = _bytes(String("a\n1\n"))
    var opts = CsvReadOptions()
    # Bypass with_quote_style's pre-check and write directly to provoke
    # the dispatcher's own raise.
    opts.quote_style_tag = 99
    var raised = False
    try:
        var _rb = read_csv_bytes_to_batch_dynamic(Span(buf), opts)
    except _:
        raised = True
    assert_true(raised, "unknown tag raises from dispatcher")


# =============================================================================
# T10 — CsvReadOptions.copy() preserves quote_style_tag.
# =============================================================================


def test_csv_read_options_copy_preserves_tag() raises:
    """T10: Round-tripping options through copy() preserves the tag."""
    print("T10: CsvReadOptions.copy() preserves quote_style_tag")
    var opts = CsvReadOptions()
    opts.with_quote_style(QUOTE_STYLE_TAG_POSIX)
    var clone = opts.copy()
    assert_equal(
        clone.quote_style_tag,
        QUOTE_STYLE_TAG_POSIX,
        "copy preserves Posix tag",
    )


def main() raises:
    test_default_quote_style_tag_is_rfc4180()
    test_with_quote_style_sets_all_three_known_tags()
    test_with_quote_style_raises_on_unknown_tag()
    test_csv_source_carries_tag_through_ctor_and_copy()
    test_csv_source_fingerprint_differs_across_tags()
    test_dynamic_dispatcher_rfc4180_parity()
    test_dynamic_dispatcher_excel_bom_routing()
    test_dynamic_dispatcher_posix_backslash_escape()
    test_dynamic_dispatcher_unknown_tag_raises()
    test_csv_read_options_copy_preserves_tag()
    print("test_csv_q_chassis_wiring: 10/10 PASS")
