# =============================================================================
# test_arrow_ipc_flatbuf_vtable_dedup.mojo
# vtable dedup
# =============================================================================
#
# Validates the size optimization: `end_table` keeps a
# per-writer cache of vtable SHAPES (field_count + inline_size +
# field_offsets[]) and reuses an existing vtable when a later table has an
# identical shape, instead of emitting a duplicate. This is wire-COMPATIBLE
# (a vtable is shared, not changed; the reader resolves table->vtable
# identically) and cuts repeated vtable bytes — the dominant metadata cost
# on wide / primitive-heavy schemas.
#
# Coordinate note: `write_type_int` / `end_table` return a WRITER-side
# logical position. `finalize()` compacts the back-to-front buffer to a
# forward-order buffer, rebasing every position by `src_cursor =
# capacity - bytes_written`. So a writer position P maps to reader
# position `P - delta`, where `delta = root_writer_pos -
# reader.read_root_offset()` (the root table's writer pos vs its rebased
# pos). The `_rebase` helper applies this. A table's i32 soffset is
# coordinate-INDEPENDENT (it's the relative distance table_pos -
# vtable_pos), so once table_pos is rebased, `rebased - soffset` yields
# the rebased vtable position directly.
#
# Test strategy:
#   1. dedup-hit: two / three identical-shape Int tables in one writer
#      resolve to the SAME rebased vtable position (one physical vtable).
#   2. size-locking: the Int-table vtable header carries the CANONICAL
#      inline_size (= 9: 4-byte soffset + u32 bit_width @ off 4 + bool
#      is_signed @ off 8) + canonical field_offsets (4, 8). Locks the
#      tight-pack layout the dedup keys on.
#   3. size-reduction: a writer that emits N identical Int tables writes
#      strictly FEWER bytes than N fresh-vtable copies would.
#   4. round-trip preserved: a deduped Int table still reads back its
#      bit_width + is_signed correctly through the canonical reader.
#   5. distinct-shape: two DIFFERENT shapes do NOT share a vtable.
#
# pyarrow validity of deduped output is covered by a cross-implementation
# test in `komira_sdk` (IPC bytes produced here -> pyarrow reader), which
# routes every table through this same `end_table` dedup path.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    start_table,
    add_field_u8,
    end_table,
    write_type_int,
    read_type_int,
)


# ---------------------------------------------------------------------------
# §1 — dedup hit: identical-shape tables share one vtable.
# ---------------------------------------------------------------------------


def test_two_identical_int_tables_share_vtable() raises:
    """Two `write_type_int(64, True)` tables in the same writer must
    resolve to the SAME (rebased) vtable position — the second table
    reuses the first table's cached vtable rather than emitting a copy."""
    var w = FlatbufWriter(2048)
    var t1 = write_type_int(w, 64, True)
    var t2 = write_type_int(w, 64, True)
    # Root at t2; delta rebases writer positions into reader coordinates.
    var buf = w^.finalize(t2)
    var reader = flatbuf_reader_over(buf)
    var delta = t2 - reader.read_root_offset()

    var r1 = t1 - delta
    var r2 = t2 - delta
    var so1 = Int(reader.read_i32_le(r1))
    var so2 = Int(reader.read_i32_le(r2))
    var vt1 = r1 - so1
    var vt2 = r2 - so2

    # Same shape => shared vtable => identical resolved vtable position.
    assert_equal(vt1, vt2)
    # The shared vtable must be in-bounds and carry the canonical Int
    # vtable header (vtable_size=8). A reused vtable may sit either BEFORE
    # or AFTER a given table in output order (FB soffset is signed), so we
    # assert the resolved vtable is valid rather than asserting a sign.
    assert_true(vt1 >= 0)
    assert_equal(Int(reader.read_u16_le(vt1)), 8)  # vtable_size
    assert_equal(Int(reader.read_u16_le(vt1 + 2)), 9)  # inline_size
    # Both tables decode their own values through the shared vtable.
    var it1 = read_type_int(reader, r1)
    var it2 = read_type_int(reader, r2)
    assert_equal(it1.bit_width, 64)
    assert_equal(it2.bit_width, 64)


def test_three_identical_int_tables_one_vtable() raises:
    """Three identical Int tables -> exactly one shared vtable."""
    var w = FlatbufWriter(2048)
    var a = write_type_int(w, 32, True)
    var b = write_type_int(w, 32, True)
    var c = write_type_int(w, 32, True)
    var buf = w^.finalize(c)
    var reader = flatbuf_reader_over(buf)
    var delta = c - reader.read_root_offset()

    var ra = a - delta
    var rb = b - delta
    var rc = c - delta
    var vt_a = ra - Int(reader.read_i32_le(ra))
    var vt_b = rb - Int(reader.read_i32_le(rb))
    var vt_c = rc - Int(reader.read_i32_le(rc))
    assert_equal(vt_a, vt_b)
    assert_equal(vt_b, vt_c)


# ---------------------------------------------------------------------------
# §2 — size-locking: canonical vtable header + field offsets.
# ---------------------------------------------------------------------------


def test_int_table_vtable_canonical_inline_size() raises:
    """Lock the tight-pack layout the dedup keys on.

    Int table fields: bit_width (u32, width 4) + is_signed (bool, width 1).
    With table-min-alignment 4:
      - bit_width  inline_offset 0 -> vtable field_offset 4
      - is_signed  inline_offset 4 -> vtable field_offset 8
      - inline_size_data = 5 -> inline_size_with_soffset = 9
      - vtable_size = 2 + 2 + 2*2 = 8
    """
    var w = FlatbufWriter(512)
    var t = write_type_int(w, 64, True)
    var buf = w^.finalize(t)
    var reader = flatbuf_reader_over(buf)

    # Single table rooted -> its rebased pos == read_root_offset().
    var rt = reader.read_root_offset()
    var vt = rt - Int(reader.read_i32_le(rt))
    var vtable_size = Int(reader.read_u16_le(vt))
    var inline_size = Int(reader.read_u16_le(vt + 2))
    var off_bit_width = Int(reader.read_u16_le(vt + 4))
    var off_is_signed = Int(reader.read_u16_le(vt + 6))

    assert_equal(vtable_size, 8)
    assert_equal(inline_size, 9)
    assert_equal(off_bit_width, 4)
    assert_equal(off_is_signed, 8)


# ---------------------------------------------------------------------------
# §3 — size reduction: deduped writer emits strictly fewer bytes.
# ---------------------------------------------------------------------------


def test_dedup_reduces_total_bytes() raises:
    """A writer emitting N identical Int tables must write strictly fewer
    bytes than N fresh vtables would. The Int vtable is 8 bytes; with
    dedup, (N-1) of those 8-byte vtables vanish."""
    var w_one = FlatbufWriter(2048)
    _ = write_type_int(w_one, 32, True)
    var bytes_one_table = w_one.bytes_written()

    var w_four = FlatbufWriter(2048)
    _ = write_type_int(w_four, 32, True)
    _ = write_type_int(w_four, 32, True)
    _ = write_type_int(w_four, 32, True)
    var last = write_type_int(w_four, 32, True)
    var bytes_four_tables = w_four.bytes_written()
    _ = last

    # Per-table cost WITHOUT a vtable = (bytes for tables 2..4) / 3.
    var added_for_three = bytes_four_tables - bytes_one_table
    var per_extra_table = added_for_three // 3

    # With dedup the 4-table writer is >= 24 bytes smaller than 4 copies
    # of the single-table cost (3 saved 8-byte vtables).
    var no_dedup_estimate = 4 * bytes_one_table
    var saved = no_dedup_estimate - bytes_four_tables
    assert_true(saved >= 24)
    # The deduped extra-table cost must be < the first table's cost (the
    # first table pays for the vtable; the extras don't).
    assert_true(per_extra_table < bytes_one_table)


# ---------------------------------------------------------------------------
# §4 — round-trip preserved through dedup.
# ---------------------------------------------------------------------------


def test_deduped_int_table_round_trips() raises:
    """A deduped (second-emitted) Int table must read back its field
    values correctly — dedup shares the vtable, not the inline data, so
    each table still carries its own bit_width / is_signed."""
    var w = FlatbufWriter(1024)
    var t1 = write_type_int(w, 16, False)  # bit_width=16, is_signed=False
    var t2 = write_type_int(w, 16, False)  # identical shape -> deduped vtable
    var buf = w^.finalize(t2)
    var reader = flatbuf_reader_over(buf)
    var delta = t2 - reader.read_root_offset()

    var it1 = read_type_int(reader, t1 - delta)
    var it2 = read_type_int(reader, t2 - delta)
    assert_equal(it1.bit_width, 16)
    assert_equal(it1.is_signed, False)
    assert_equal(it2.bit_width, 16)
    assert_equal(it2.is_signed, False)


def test_deduped_distinct_values_same_shape() raises:
    """Two Int tables with the SAME shape but DIFFERENT values share one
    vtable yet decode their own values."""
    var w = FlatbufWriter(1024)
    var t1 = write_type_int(w, 32, True)   # signed 32
    var t2 = write_type_int(w, 8, False)   # unsigned 8 — SAME shape
    var buf = w^.finalize(t2)
    var reader = flatbuf_reader_over(buf)
    var delta = t2 - reader.read_root_offset()

    var r1 = t1 - delta
    var r2 = t2 - delta
    var vt1 = r1 - Int(reader.read_i32_le(r1))
    var vt2 = r2 - Int(reader.read_i32_le(r2))
    assert_equal(vt1, vt2)  # shared vtable shape

    var it1 = read_type_int(reader, r1)
    var it2 = read_type_int(reader, r2)
    assert_equal(it1.bit_width, 32)
    assert_equal(it1.is_signed, True)
    assert_equal(it2.bit_width, 8)
    assert_equal(it2.is_signed, False)


# ---------------------------------------------------------------------------
# §5 — distinct shapes do NOT share a vtable.
# ---------------------------------------------------------------------------


def test_distinct_shapes_distinct_vtables() raises:
    """A 2-field table and a 1-field table have different shapes and must
    NOT share a vtable, even in one writer."""
    var w = FlatbufWriter(1024)

    # Table A: 2 fields (u32 @0, bool @1) — Int shape.
    var ta = write_type_int(w, 32, True)

    # Table B: 1 field (u8 @0) — different field_count + offsets.
    var tbb = start_table()
    add_field_u8(tbb, 0, UInt8(7))
    var tb_pos = end_table(w, tbb^)

    var buf = w^.finalize(ta)
    var reader = flatbuf_reader_over(buf)
    var delta = ta - reader.read_root_offset()

    var ra = ta - delta
    var rb = tb_pos - delta
    var vt_a = ra - Int(reader.read_i32_le(ra))
    var vt_b = rb - Int(reader.read_i32_le(rb))
    assert_true(vt_a != vt_b)


# ---------------------------------------------------------------------------
# TestSuite registration
# ---------------------------------------------------------------------------


def main() raises:
    var suite = TestSuite()
    suite.test[test_two_identical_int_tables_share_vtable]()
    suite.test[test_three_identical_int_tables_one_vtable]()
    suite.test[test_int_table_vtable_canonical_inline_size]()
    suite.test[test_dedup_reduces_total_bytes]()
    suite.test[test_deduped_int_table_round_trips]()
    suite.test[test_deduped_distinct_values_same_shape]()
    suite.test[test_distinct_shapes_distinct_vtables]()
    suite^.run()
