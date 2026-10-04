# =============================================================================
# split_record_batch STRING / BINARY payload VIEWS (lane G L3, 2026-09-25)
# =============================================================================
#
# WHAT CHANGED. `split_record_batch` used to COPY the payload bytes of every
# plain STRING / BINARY column it split (`_slice_variable_width`: fresh offsets
# + fresh payload + fresh validity). On clickbench/cbq27 that copy was 8.30% of
# the cell's CPU on the benchmark host ("C-split"): every 122,880-row row group's `url` payload, re-materialised in
# three sub-morsels, on every row group.
#
# Now the payload is an Arc WINDOW SHARE of the source's data buffer
# (`SharedAlignedBuffer.share_range_as`), while the offsets are still rebuilt
# REBASED to 0 and the validity is still copied REBASED to bit 0. So a split
# STRING column keeps EXACTLY the copy path's layout -- `_offset == 0`,
# `offsets[0] == 0`, `_data.len() == offsets[rows]`, validity from bit 0 --
# and the ONLY difference is that the payload bytes are the source's bytes.
# That is why no reader has to be audited for `Column._offset` (the gate PLAN
# §2 G put on L3): no split STRING column carries a non-zero `_offset`.
#
# WHAT EACH TEST PINS
#   * T1 aliasing -- a write through a third owner of the SOURCE payload is
#     visible through the split morsel. FAILS on the copy path; this is the
#     test that goes red if the lever silently stops firing.
#   * T2 values + layout invariants, STRING, uneven split, empty strings.
#   * T3 NULLABLE: validity rebased per morsel at a morsel size that is NOT a
#     multiple of 8 (bit windows straddle bytes), null_count per morsel, and
#     the payload is STILL shared (the numeric zero-copy arm excludes nullable
#     columns; this arm must not).
#   * T4 BINARY takes the same arm.
#   * T5 LIFETIME: one morsel's column outlives the source batch AND every
#     sibling morsel, across allocator churn. A missed refcount on the window
#     share reads freed/reused bytes here.
#   * T6 a zero-byte window (all-empty morsel) and an all-empty column.
#   * T7 the COPY arm (the `KOMIRA_SPLIT_STRING_VIEW=0` kill switch and the
#     malformed-short-payload fallback both route here) still copies and still
#     reads identically.
#   * T8 a payload buffer SHORTER than its own offsets claim falls back to the
#     copy for the out-of-bounds windows instead of raising, and still shares
#     the in-bounds ones.
#
# Encapsulation: no UnsafePointer. The aliasing proof is a write through a
# retained `SharedAlignedBuffer.share()` of the source payload, the same
# technique the batch evaluator's string-column share test uses.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.schema import (
    Field,
    RecordBatch,
    SchemaBuilder,
)
from komira_core.arrow.string_array import StringArray
from komira_core.arrow.owned_aligned_buffer import OwnedAlignedBuffer
from komira_core.io.heap_region import HeapRegion
from komira_morsel.morsel import MorselArray, split_record_batch
from komira_morsel.varlen_slice import _slice_variable_width


# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------


def _vals(n: Int) -> List[String]:
    """Deterministic strings of varying length, with empties every 7th row."""
    var out = List[String]()
    for i in range(n):
        if i % 7 == 0:
            out.append(String(""))
        elif i % 3 == 0:
            out.append(String("https://example.com/") + String(i) + "/path")
        else:
            out.append(String("v") + String(i))
    return out^


def _first_byte(s: String) -> UInt8:
    """First byte of `s` (callers only pass non-empty strings)."""
    return s.as_bytes()[0]


def _one_col_batch(var col: Column[HeapRegion], t: ArrowType, nullable: Bool) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field("s", t, nullable))
    var schema = sb.build()
    return RecordBatch.from_typed_columns_1(schema^, col^)


def _src_offset(col: Column[HeapRegion], row: Int) raises -> Int:
    return Int(col._offsets.value().get_typed[Int32](row))


def _first_nonempty_row(vals: List[String], lo: Int, hi: Int) raises -> Int:
    for r in range(lo, hi):
        if vals[r].byte_length() > 0:
            return r
    raise Error("fixture has no non-empty string in [" + String(lo) + ", " + String(hi) + ")")


def _assert_copy_layout(ma: MorselArray, label: String) raises:
    """Every split variable-width column has the COPY path's layout."""
    for m in range(len(ma)):
        var n = ma[m].num_rows()
        ref c = ma[m].column_at(0)
        assert_equal(c._offset, 0, label + ": _offset must be 0 (m=" + String(m) + ")")
        ref off = c._offsets.value()
        assert_equal(Int(off.get_typed[Int32](0)), 0, label + ": offsets[0] must be 0")
        assert_equal(
            c._data.len(),
            Int(off.get_typed[Int32](n)),
            label + ": _data.len() must equal offsets[rows] (m=" + String(m) + ")",
        )


def _assert_string_values(ma: MorselArray, vals: List[String], label: String) raises:
    var cursor = 0
    for m in range(len(ma)):
        var n = ma[m].num_rows()
        var sa = ma[m].column_at(0).as_string()
        for i in range(n):
            var got = sa.get(i)
            if got != vals[cursor + i]:
                raise Error(
                    label + ": m=" + String(m) + " i=" + String(i) + " got='"
                    + got + "' want='" + vals[cursor + i] + "'"
                )
        cursor += n
    assert_equal(cursor, len(vals), label + ": row coverage")


# -----------------------------------------------------------------------------
# T1 -- the payload is SHARED with the source (fails on the copy path)
# -----------------------------------------------------------------------------


def test_split_string_payload_aliases_the_source() raises:
    var vals = _vals(300)
    var col = Column.from_string(StringArray.from_strings(vals))
    # A third owner of the SOURCE payload bytes, taken before the split.
    var src_alias = col._data.share()
    # Byte position (in the source payload) of the first non-empty string of
    # morsel 1 (rows [128, 256)).
    var r = _first_nonempty_row(vals, 128, 256)
    var pos = _src_offset(col, r)
    var batch = _one_col_batch(col^, ArrowType.STRING, False)

    var ma = split_record_batch(batch^, 128)
    assert_equal(len(ma), 3, "300 rows / 128 -> 3 morsels")

    src_alias.write_u8_at(pos, UInt8(ord("Z")))
    var got = ma[1].column_at(0).as_string().get(r - 128)
    assert_equal(
        _first_byte(got),
        UInt8(ord("Z")),
        "split morsel 1 did NOT alias the source payload -- the STRING slice"
        " still COPIES (lane G L3 inert)",
    )
    # And the write is visible ONLY at that row: the neighbouring row is intact.
    if r + 1 < 256 and vals[r + 1].byte_length() > 0:
        assert_equal(
            ma[1].column_at(0).as_string().get(r + 1 - 128),
            vals[r + 1],
            "a one-byte write must not disturb the next row",
        )
    _ = src_alias^


# -----------------------------------------------------------------------------
# T2 -- values + layout, STRING
# -----------------------------------------------------------------------------


def test_split_string_view_values_and_layout() raises:
    var vals = _vals(1000)
    var col = Column.from_string(StringArray.from_strings(vals))
    var batch = _one_col_batch(col^, ArrowType.STRING, False)
    var ma = split_record_batch(batch^, 333)
    assert_equal(len(ma), 4, "1000 / 333 -> [333, 333, 333, 1]")
    assert_equal(ma[3].num_rows(), 1, "tail morsel of 1 row")
    _assert_copy_layout(ma, "T2")
    _assert_string_values(ma, vals, "T2")
    # The zero-copy StringArray share (lane G L1) must accept a split column:
    # it is gated on `_offset == 0`, which this arm preserves.
    for m in range(len(ma)):
        assert_true(
            ma[m].column_at(0).can_share_as_string(),
            "a split STRING column must stay share_as_string-eligible",
        )


# -----------------------------------------------------------------------------
# T3 -- NULLABLE: validity rebased, payload still shared
# -----------------------------------------------------------------------------


def test_split_string_view_nullable_rebases_validity() raises:
    var n = 101
    var vals = _vals(n)
    var valid = List[Bool]()
    for i in range(n):
        valid.append(i % 5 != 2)
    var col = Column.from_string(
        StringArray.from_strings_with_validity(vals, valid)
    )
    assert_true(col._validity.__bool__(), "fixture must carry a bitmap")
    var src_alias = col._data.share()
    # a VALID non-empty row in morsel 3 (rows [39, 52)) at morsel size 13
    var r = -1
    for i in range(39, 52):
        if valid[i] and vals[i].byte_length() > 0:
            r = i
            break
    assert_true(r >= 0, "fixture: need a valid non-empty row in morsel 3")
    var pos = _src_offset(col, r)
    var batch = _one_col_batch(col^, ArrowType.STRING, True)

    var ma = split_record_batch(batch^, 13)  # 13: bit windows straddle bytes
    assert_equal(len(ma), 8, "101 / 13 -> 8 morsels")
    _assert_copy_layout(ma, "T3")

    var cursor = 0
    for m in range(len(ma)):
        var rows = ma[m].num_rows()
        ref c = ma[m].column_at(0)
        var want_nulls = 0
        var sa = c.as_string()
        for i in range(rows):
            var src = cursor + i
            assert_equal(
                sa.is_null(i),
                not valid[src],
                "validity bit m=" + String(m) + " i=" + String(i),
            )
            if not valid[src]:
                want_nulls += 1
            else:
                assert_equal(sa.get(i), vals[src], "value m=" + String(m))
        assert_equal(c.null_count(), want_nulls, "per-morsel null_count m=" + String(m))
        cursor += rows

    src_alias.write_u8_at(pos, UInt8(ord("Q")))
    var got = ma[3].column_at(0).as_string().get(r - 39)
    assert_equal(
        _first_byte(got),
        UInt8(ord("Q")),
        "a NULLABLE STRING split must share its payload too",
    )
    _ = src_alias^


# -----------------------------------------------------------------------------
# T4 -- BINARY takes the same arm
# -----------------------------------------------------------------------------


def test_split_binary_view_aliases_and_reads() raises:
    var vals = _vals(200)
    var sa = StringArray.from_strings(vals)
    var n = sa.length
    var col = Column[HeapRegion](
        arrow_type=ArrowType.BINARY,
        data=sa.data.share(),
        offsets=Optional(sa.offsets.share()),
        validity=None,
        length=n,
        null_count=0,
        offset=0,
    )
    var src_alias = col._data.share()
    var r = _first_nonempty_row(vals, 150, 200)
    var pos = _src_offset(col, r)
    var batch = _one_col_batch(col^, ArrowType.BINARY, False)
    var ma = split_record_batch(batch^, 64)
    assert_equal(len(ma), 4, "200 / 64 -> 4 morsels")
    _assert_copy_layout(ma, "T4")

    var cursor = 0
    for m in range(len(ma)):
        var rows = ma[m].num_rows()
        var ba = ma[m].column_at(0).as_binary()
        for i in range(rows):
            var got = ba.get(i)
            var want = vals[cursor + i].as_bytes()
            assert_equal(len(got), len(want), "binary len m=" + String(m))
            for k in range(len(got)):
                assert_equal(got[k], want[k], "binary byte")
        cursor += rows

    src_alias.write_u8_at(pos, UInt8(ord("B")))
    var got = ma[r // 64].column_at(0).as_binary().get(r % 64)
    assert_equal(got[0], UInt8(ord("B")), "a BINARY split must share its payload")
    _ = src_alias^


# -----------------------------------------------------------------------------
# T5 -- LIFETIME: a morsel column outlives the source and its siblings
# -----------------------------------------------------------------------------


def test_split_string_view_outlives_source_and_siblings() raises:
    var vals = _vals(4096)
    var col = Column.from_string(StringArray.from_strings(vals))
    var batch = _one_col_batch(col^, ArrowType.STRING, False)
    var ma = split_record_batch(batch^, 1000)
    assert_equal(len(ma), 5, "4096 / 1000 -> 5 morsels")
    # Keep ONLY morsel 2's column (an Arc share of the morsel's buffers), then
    # drop every morsel. The source batch was consumed by the split.
    var kept = ma[2].column_at(0).share()
    _ = ma^

    # Churn the allocator with same-sized buffers full of a sentinel. If the
    # window share had not pinned the source region, `kept` would now alias one
    # of these.
    var churn = List[OwnedAlignedBuffer]()
    for _k in range(64):
        var b = OwnedAlignedBuffer(64 * 1024)
        b.set_length(Int64(64 * 1024))
        for j in range(64 * 1024):
            b.set_typed[UInt8](j, UInt8(0xEE))
        churn.append(b^)

    var sa = kept.as_string()
    assert_equal(sa.length, 1000, "kept morsel length")
    for i in range(1000):
        assert_equal(sa.get(i), vals[2000 + i], "kept row " + String(i))
    _ = churn^


# -----------------------------------------------------------------------------
# T6 -- zero-byte windows
# -----------------------------------------------------------------------------


def test_split_string_view_empty_windows() raises:
    # (a) a column whose middle morsel is all empty strings
    var vals = List[String]()
    for i in range(30):
        if i >= 10 and i < 20:
            vals.append(String(""))
        else:
            vals.append(String("x") + String(i))
    var col = Column.from_string(StringArray.from_strings(vals))
    var batch = _one_col_batch(col^, ArrowType.STRING, False)
    var ma = split_record_batch(batch^, 10)
    assert_equal(len(ma), 3, "3 morsels")
    assert_equal(ma[1].column_at(0)._data.len(), 0, "all-empty window is 0 bytes")
    _assert_copy_layout(ma, "T6a")
    _assert_string_values(ma, vals, "T6a")

    # (b) a column that is ALL empty (the source payload itself is 0 bytes)
    var empties = List[String]()
    for _i in range(25):
        empties.append(String(""))
    var col2 = Column.from_string(StringArray.from_strings(empties))
    var batch2 = _one_col_batch(col2^, ArrowType.STRING, False)
    var ma2 = split_record_batch(batch2^, 7)
    assert_equal(len(ma2), 4, "25 / 7 -> 4 morsels")
    _assert_copy_layout(ma2, "T6b")
    _assert_string_values(ma2, empties, "T6b")


# -----------------------------------------------------------------------------
# T7 -- the COPY arm still copies (kill switch / fallback target)
# -----------------------------------------------------------------------------


def test_copy_arm_still_copies_and_reads_identically() raises:
    var vals = _vals(300)
    var col = Column.from_string(StringArray.from_strings(vals))
    var r = _first_nonempty_row(vals, 100, 200)
    var pos = _src_offset(col, r)

    var copied = _slice_variable_width(col, 100, 100, ArrowType.STRING, False)
    var shared = _slice_variable_width(col, 100, 100, ArrowType.STRING, True)
    var a = copied.as_string()
    var b = shared.as_string()
    for i in range(100):
        assert_equal(a.get(i), vals[100 + i], "copy arm value")
        assert_equal(b.get(i), vals[100 + i], "share arm value")
    assert_equal(copied._data.len(), shared._data.len(), "same payload extent")

    var src_alias = col._data.share()
    src_alias.write_u8_at(pos, UInt8(ord("C")))
    assert_equal(
        copied.as_string().get(r - 100),
        vals[r],
        "the COPY arm must NOT alias the source",
    )
    assert_equal(
        _first_byte(shared.as_string().get(r - 100)),
        UInt8(ord("C")),
        "the SHARE arm must alias the source",
    )
    _ = src_alias^


# -----------------------------------------------------------------------------
# T8 -- a payload shorter than its offsets claim: copy fallback, no raise
# -----------------------------------------------------------------------------


def test_short_payload_falls_back_to_copy_per_window() raises:
    # 40 rows of 4 bytes each -> offsets end at 160. Hand the column a payload
    # buffer that CLAIMS only 100 bytes (a window share of the real 160-byte
    # region, so the bytes past 100 still exist). Windows ending <= 100 share;
    # windows ending past it must take the copy path rather than raise.
    var vals = List[String]()
    for i in range(40):
        vals.append(String("r") + String(100 + i))  # "r100".."r139": 4 bytes
    var sa = StringArray.from_strings(vals)
    var short_data = sa.data.share_range_as[HeapRegion](0, 100)
    var col = Column[HeapRegion](
        arrow_type=ArrowType.STRING,
        data=short_data^,
        offsets=Optional(sa.offsets.share()),
        validity=None,
        length=40,
        null_count=0,
        offset=0,
    )
    var src_alias = col._data.share()
    var batch = _one_col_batch(col^, ArrowType.STRING, False)
    var ma = split_record_batch(batch^, 10)  # windows end at 40, 80, 120, 160
    assert_equal(len(ma), 4, "4 morsels")
    _assert_string_values(ma, vals, "T8")

    src_alias.write_u8_at(0, UInt8(ord("S")))    # row 0 (morsel 0, in bounds)
    src_alias.write_u8_at(99, UInt8(ord("9")))   # inside row 24 (morsel 2, OOB window)
    assert_equal(
        _first_byte(ma[0].column_at(0).as_string().get(0)),
        UInt8(ord("S")),
        "an in-bounds window must still share",
    )
    assert_equal(
        ma[2].column_at(0).as_string().get(4),
        vals[24],
        "an out-of-bounds window must have been COPIED (at split time)",
    )
    _ = src_alias^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
