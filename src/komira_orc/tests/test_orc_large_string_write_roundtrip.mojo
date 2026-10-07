# =============================================================================
# ORC WRITE OF A PROMOTED (large_string) COLUMN — VALUES, NOT SURVIVAL
# =============================================================================
#
# TARGET: `stripe_emit.build_col_encoders` + `_emit_string` +
# `_compute_chunk_stats` + `_column_present` + `_enc_has_nulls` + `_build_bloom`.
#
# ⛔ THE HAZARD, WHICH IS INVISIBLE FROM EITHER END. `orc_writer._orc_kind`
# maps BOTH `ArrowType.STRING` and `ArrowType.LARGE_STRING` onto
# `ORC_KIND_STRING` — correctly: ORC has one string kind, and the Arrow offset
# width has no ORC representation. A `build_col_encoders` that fetched every
# ORC_KIND_STRING column with an unconditional `batch.column_as_string(c)`
# would hit that accessor's NARROW-IF-IT-FITS arm: below
# `ARROW_INT32_OFFSET_MAX` it silently pays a whole-column narrowing copy, and
# at or above it RAISES. That ceiling is precisely the size at which
# `large_string` is the ONLY representation of the column — i.e. ORC could not
# write the promoted column that the promotion exists to produce, and the
# failure would be reported by an accessor three modules away rather than by
# ORC.
#
# The encoder therefore branches on the COLUMN's own tag (the kind cannot tell
# the widths apart) and holds an Int64-offset array in a second encoder slot,
# so the stripe walk reads the source at the width it was written at.
#
# ★ THE ORACLE IS DIFFERENTIAL. ORC's on-disk string form is a raw UTF-8 DATA
# stream plus an RLEv2 LENGTH stream of per-row byte lengths — no offset width
# anywhere. So `string` and `large_string` carrying the same values MUST
# produce byte-identical ORC files, and §2 asserts that on the whole file.
#
# ⚠ A DIFFERENTIAL IS COMMON-MODE-BLIND, so every leg also asserts read-back
# VALUES against hand-computed expectations. Nothing here treats "the write
# did not raise" as evidence.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.large_string_array import LargeStringArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_arrow.string_array import StringArray

from komira_orc.orc_schema import ORC_KIND_STRING
from komira_orc.stripe_emit import build_col_encoders
from komira_orc import (
    OrcWriterOptions,
    write_orc_bytes,
    read_orc_bytes,
    ORC_COMPRESSION_NONE,
    ORC_COMPRESSION_ZSTD,
)


# ---------------------------------------------------------------------------
# Fixtures — ONE value set, TWO offset widths.
#
# ⚠ VARIABLE-LENGTH AND ROW-STAMPED ON PURPOSE. Uniform-width values are
# reproduced by any constant stride (so a dropped-offsets bug passes), and
# values that do not name their row survive being swapped.
# ---------------------------------------------------------------------------


def _expected_value(i: Int) -> String:
    var w = i % 4
    if w == 0:
        return String("r") + String(i)
    elif w == 1:
        return String("row-") + String(i) + String("-padded-out")
    elif w == 2:
        return String("v") + String(i) + String("!")
    return String("wide-value-row-") + String(i) + String("-tail")


def _values(n: Int) -> List[String]:
    var out = List[String]()
    for i in range(n):
        out.append(_expected_value(i))
    return out^


def _wide_batch(n: Int) raises -> RecordBatch:
    var arr = LargeStringArray.from_strings(_values(n))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.LARGE_STRING, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_large_string(arr))
    return b.build(sb.build())


def _narrow_batch(n: Int) raises -> RecordBatch:
    var arr = StringArray.from_strings(_values(n))
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.STRING, False))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_string(arr))
    return b.build(sb.build())


def _wide_nullable_batch(n: Int) raises -> RecordBatch:
    """Nulls at every third row. This is the leg that drives the PRESENT
    stream, `_enc_has_nulls` and `_column_present` — all three of which read
    the string array through the encoder slot, so all three had to become
    width-aware together."""
    var vals = List[String]()
    var valid = List[Bool]()
    for i in range(n):
        if i % 3 == 2:
            vals.append(String(""))
            valid.append(False)
        else:
            vals.append(_expected_value(i))
            valid.append(True)
    var arr = LargeStringArray.from_strings_with_validity(vals, valid)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("s"), ArrowType.LARGE_STRING, True))
    var b = RecordBatchBuilder()
    b.add_column(Column.from_large_string(arr))
    return b.build(sb.build())


# =============================================================================
# §0 — THE PRECONDITION. Without this every leg below could be a vacuous pass
#      over a narrow column.
# =============================================================================


def test_the_wide_fixture_is_physically_wide() raises:
    comptime N = 24
    var b = _wide_batch(N)
    assert_equal(
        b.column_at(0).arrow_type,
        ArrowType.LARGE_STRING,
        "fixture Column tag is not LARGE_STRING — every leg below would take"
        " the narrow encoder slot and prove nothing",
    )
    ref off = b.column_at(0)._offsets
    assert_true(off.__bool__(), "wide fixture has no offsets buffer")
    assert_equal(
        Int(off.value().len()),
        (N + 1) * 8,
        "offsets buffer is not (n+1)*8 bytes — the fixture silently narrowed",
    )


# =============================================================================
# §1 — VALUES through the ORC write/read round trip.
# =============================================================================


def _roundtrip_values(codec: Int, label: String) raises:
    comptime N = 24
    var opts = OrcWriterOptions(codec, 10000, String("UTC"))
    var bytes = write_orc_bytes(_wide_batch(N), opts)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_rows(), N, label + ": row count")
    var s = back.column_as_string(0)
    for i in range(N):
        assert_equal(
            s.get(i),
            _expected_value(i),
            label + ": value at row " + String(i),
        )


def test_wide_roundtrip_none() raises:
    """Regression coverage for the values. The leg that FALSIFIES a narrowing
    encoder at test scale is §5 — see its block comment for why a
    values-only assertion cannot, and must not be claimed to."""
    _roundtrip_values(ORC_COMPRESSION_NONE, "NONE")


def test_wide_roundtrip_zstd() raises:
    _roundtrip_values(ORC_COMPRESSION_ZSTD, "ZSTD")


# =============================================================================
# §2 — THE DIFFERENTIAL. The offset width must be INVISIBLE on disk.
# =============================================================================


def test_wide_and_narrow_orc_files_are_byte_identical() raises:
    comptime N = 24
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String("UTC"))
    var wide = write_orc_bytes(_wide_batch(N), opts)
    var narrow = write_orc_bytes(_narrow_batch(N), opts)
    assert_equal(
        len(wide),
        len(narrow),
        "large_string and string wrote DIFFERENT-LENGTH ORC files for the same"
        " values; ORC records no offset width, so they must not differ at all",
    )
    for i in range(len(wide)):
        assert_equal(
            Int(wide[i]),
            Int(narrow[i]),
            "ORC byte " + String(i) + " differs between the large_string and"
            " string encodes of identical values",
        )


# =============================================================================
# §3 — NULLABLE. PRESENT stream + the null-skipping DATA/LENGTH walk.
# =============================================================================


def test_wide_nullable_roundtrip() raises:
    comptime N = 24
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 10000, String("UTC"))
    var bytes = write_orc_bytes(_wide_nullable_batch(N), opts)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_rows(), N, "nullable row count")
    var s = back.column_as_string(0)
    for i in range(N):
        if i % 3 == 2:
            assert_true(
                s.is_null(i), "row " + String(i) + " should be NULL"
            )
        else:
            assert_true(
                not s.is_null(i), "row " + String(i) + " should NOT be null"
            )
            assert_equal(
                s.get(i),
                _expected_value(i),
                "nullable value at row " + String(i),
            )


# =============================================================================
# §4 — MULTI-STRIPE. `_emit_string` runs once PER STRIPE over a row RANGE.
# =============================================================================


def test_wide_multistripe_roundtrip() raises:
    """A stripe row-count below the row count forces several stripes, so the
    wide span walk runs with `row_start != 0`. An implementation that read
    from row 0 in every stripe would repeat the first stripe's values and
    still produce a well-formed file with the right row count."""
    comptime N = 50
    var opts = OrcWriterOptions(ORC_COMPRESSION_NONE, 10, String("UTC"))
    var bytes = write_orc_bytes(_wide_batch(N), opts)
    var back = read_orc_bytes(Span(bytes))
    assert_equal(back.num_rows(), N, "multi-stripe row count")
    var s = back.column_as_string(0)
    for i in range(N):
        assert_equal(
            s.get(i),
            _expected_value(i),
            "multi-stripe value at row " + String(i),
        )


# =============================================================================
# §5 — THE STRUCTURAL LEG, AND WHY IT IS THE FALSIFIER HERE.
# =============================================================================
#
# ⚠ READ THIS BEFORE TREATING §1–§4 AS FALSIFIERS. They are not, at test
# scale, and pretending otherwise would be the exact kind of unearned
# evidence this file's header refuses.
#
# `RecordBatch.column_as_string` has a NARROW-IF-IT-FITS arm: a
# `large_string` column whose payload is at or below `ARROW_INT32_OFFSET_MAX`
# is losslessly re-expressed at Int32 and returned. So a narrowing ORC writer
# produces CORRECT bytes for every fixture a test can afford to build — it
# simply pays a whole-column copy to do it, and RAISES for the one column size
# that cannot be narrowed, which is the size `large_string` exists for. A values-only test cannot see that difference,
# and the >2 GiB fixture that could costs 2,147,483,648 bytes of live string
# payload in the test process.
#
# What IS observable at test scale is WHICH PATH the encoder took. That is the
# property the >2 GiB capability rests on, so it is asserted directly.
#
# ★ Against a single-string-slot encoder (no wide slot):
#     * §1-§4 alone -> `ALL PASS`. The values legs are genuinely not
#       falsifiers.
#     * with §5 present -> the file does not COMPILE:
#       `'_OrcColEncoder' value has no attribute 'str_is_wide'`, and the same
#       for `str_null_count` / `str_is_null` / `str_get`: with one string
#       slot there is no way to ask which width it holds.


def test_the_encoder_holds_the_wide_array_not_a_narrowed_copy() raises:
    """A LARGE_STRING column must reach the stripe walk as `large_string`.

    FAILS against an encoder with ONE string slot (`s:
    Optional[StringArray]`) filled with `batch.column_as_string(c)`
    unconditionally: there is nothing wide to hold and no accessor to ask.
    """
    comptime N = 24
    var batch = _wide_batch(N)
    var kinds = List[Int]()
    kinds.append(ORC_KIND_STRING)
    var encs = build_col_encoders(batch, kinds)
    assert_true(
        encs[0].str_is_wide(),
        "the ORC encoder narrowed a large_string column instead of holding"
        " it at its own width. Below 2 GiB that is merely a wasted copy;"
        " at or above it, it is the `column_as_string` refusal, i.e. ORC"
        " cannot write the column the promotion produced",
    )
    assert_equal(
        encs[0].str_null_count(), 0, "non-nullable fixture has no nulls"
    )
    # The width-agnostic accessors must agree with the fixture, or the wide
    # slot is holding something other than the column under test.
    for i in range(N):
        assert_true(
            not encs[0].str_is_null(i), "row " + String(i) + " is not null"
        )
        assert_equal(
            encs[0].str_get(i),
            _expected_value(i),
            "encoder-slot value at row " + String(i),
        )


def test_a_narrow_column_still_takes_the_narrow_slot() raises:
    """The CONTROL. A plain STRING column must NOT be routed to the wide slot.

    Without this, a fix that simply widened everything would pass §5 while
    silently changing the hot path every existing ORC write takes.
    """
    var batch = _narrow_batch(8)
    var kinds = List[Int]()
    kinds.append(ORC_KIND_STRING)
    var encs = build_col_encoders(batch, kinds)
    assert_true(
        not encs[0].str_is_wide(),
        "a plain STRING column was routed into the int64-offset slot",
    )


def main() raises:
    test_the_wide_fixture_is_physically_wide()
    test_wide_roundtrip_none()
    test_wide_roundtrip_zstd()
    test_wide_and_narrow_orc_files_are_byte_identical()
    test_wide_nullable_roundtrip()
    test_wide_multistripe_roundtrip()
    test_the_encoder_holds_the_wide_array_not_a_narrowed_copy()
    test_a_narrow_column_still_takes_the_narrow_slot()
    print("test_orc_large_string_write_roundtrip: ALL PASS")
