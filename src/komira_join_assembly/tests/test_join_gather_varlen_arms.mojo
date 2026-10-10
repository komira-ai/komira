# =============================================================================
# test_join_gather_varlen_arms -- the variable-width arms of
# `emit_gather_column_projected` that the parity tests do not reach
# =============================================================================
#
# Cases
#   A  STRING, outer side (`is_nullable=True`) over a source that has its OWN
#      validity, read through a column window (`_offset = 3`): a `-1` index and
#      a source NULL are both NULL; every other row is the source value at
#      `_offset + idx`.
#   B  STRING, inner side (`is_nullable=False`) over the same windowed nullable
#      source: only source validity decides NULLs.
#   C  STRING with no offsets buffer is refused with a message naming the type.
#   D  The serial arm's 64-bit offset promotion, driven by a lowered
#      `offset_promote_at`: the column is retagged LARGE_STRING, its offsets are
#      8 bytes wide, `-1` rows stay flat, empty rows copy nothing and 1- and
#      2-byte rows are copied whole. Its twin at exactly the trip point stays
#      STRING with 4-byte offsets.
#   E  LARGE_STRING, outer side over a windowed nullable source (the Int64
#      offsets arm).
#   F  LARGE_BINARY, inner side over a windowed nullable source: the type tag is
#      carried, not rewritten to LARGE_STRING.
#   G  LARGE_STRING with no source validity on an inner side emits no bitmap.
#   H  LARGE_STRING with no offsets buffer is refused.
#   I  A batch whose column slab is wider than its schema: the emitted Field
#      falls back to (name, column type, nullability) rather than raising.
#
# Every expected value is computed from the fixture lists below, never from the
# code under test.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, SchemaBuilder
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_join_assembly.compiler_join_assembly import (
    emit_gather_column_projected,
)


comptime _BASE: Int = 3
"""The column window: every source column below starts at physical row 3, so a
gather that forgets `_offset` reads the wrong rows and the wrong validity bits."""


def _vals(n: Int) -> List[String]:
    """Distinct per row (for `n <= 52`); row `i % 7 == 5` is the empty string
    so the `slen > 0` skip is exercised next to real copies, row `i % 7 == 3`
    is ONE byte and row `i % 7 == 1` is TWO bytes, so a copy guard raised to
    `slen > 1` or `slen > 2` drops a row the checks read."""
    var out = List[String]()
    for i in range(n):
        if i % 7 == 5:
            out.append(String(""))
        elif i % 7 == 3:
            out.append(chr(65 + i % 26))
        elif i % 7 == 1:
            out.append(String("s") + chr(97 + i % 26))
        else:
            var s = String("r") + String(i)
            for _ in range(i % 4):
                s += "x"
            out.append(s^)
    return out^


def _is_src_null(phys: Int) -> Bool:
    """Physical source rows that are NULL in the source's own bitmap."""
    return phys % 5 == 1


def _varlen_col(
    at: ArrowType, vals: List[String], wide: Bool, with_validity: Bool
) raises -> Column[HeapRegion]:
    """A STRING-family column over ALL of `vals`, then windowed to start at
    physical row `_BASE`. Offsets are 4 or 8 bytes per `wide`. When
    `with_validity`, physical rows with `_is_src_null` are cleared in a
    whole-column bitmap (the window reads it at `_offset + i`)."""
    var n = len(vals)
    var w = 8 if wide else 4
    var total = 0
    for i in range(n):
        total += len(vals[i].as_bytes())
    var offs = OwnedAlignedBuffer((n + 1) * w)
    var data = OwnedAlignedBuffer(max(total, 1))
    var pos = 0
    if wide:
        offs.set_typed[Int64](0, Int64(0))
    else:
        offs.set_typed[Int32](0, Int32(0))
    for i in range(n):
        for b in vals[i].as_bytes():
            data.set_typed[Scalar[DType.uint8]](pos, b)
            pos += 1
        if wide:
            offs.set_typed[Int64](i + 1, Int64(pos))
        else:
            offs.set_typed[Int32](i + 1, Int32(pos))
    offs.set_length(Int64((n + 1) * w))
    data.set_length(Int64(total))
    var validity = Optional[Bitmap[HeapRegion]](None)
    var nulls = 0
    if with_validity:
        var bm = Bitmap.create(n)
        for i in range(n):
            if _is_src_null(i):
                bm.clear(i)
                if i >= _BASE:
                    nulls += 1
            else:
                bm.set(i)
        validity = bm^
    return Column[HeapRegion](
        arrow_type=at,
        data=data^,
        offsets=Optional[OwnedAlignedBuffer](offs^),
        validity=validity^,
        length=n - _BASE,
        null_count=nulls,
        offset=_BASE,
    )


def _one_col_batch(var col: Column[HeapRegion], at: ArrowType) raises -> RecordBatch:
    var sb = SchemaBuilder()
    sb.add_field(Field(String("v"), at, False))
    var bb = RecordBatchBuilder()
    bb.add_column(col^)
    return bb.build(sb.build())


def _out_str(ref col: Column[HeapRegion], i: Int, wide: Bool) raises -> String:
    """Row `i` of a gathered (offset-0) STRING-family column, read off its raw
    offsets and bytes."""
    var s: Int
    var e: Int
    if wide:
        s = Int(col._offsets.value().get_typed[Int64](i))
        e = Int(col._offsets.value().get_typed[Int64](i + 1))
    else:
        s = Int(col._offsets.value().get_typed[Int32](i))
        e = Int(col._offsets.value().get_typed[Int32](i + 1))
    var out = String("")
    for j in range(s, e):
        out += chr(Int(col._data.get_typed[Scalar[DType.uint8]](j)))
    return out^


def _indices(count: Int, n_window: Int, with_sentinels: Bool) -> List[Int]:
    """A non-monotone permutation-like index list over the window, with `-1`
    sentinels at fixed positions when asked."""
    var out = List[Int]()
    for j in range(count):
        if with_sentinels and (j % 6 == 2):
            out.append(-1)
        else:
            out.append((j * 11 + 4) % n_window)
    return out^


def _gather(
    ref batch: RecordBatch,
    idx: List[Int],
    nullable: Bool,
    promote_at: Int = 2147483647,
) raises -> RecordBatch:
    var builder = RecordBatchBuilder()
    var sb = SchemaBuilder()
    emit_gather_column_projected(
        batch,
        0,
        String("out"),
        nullable,
        idx,
        len(idx),
        builder,
        sb,
        offset_promote_at=promote_at,
    )
    return builder.build(sb.build())


def _check_rows(
    ref col: Column[HeapRegion],
    vals: List[String],
    idx: List[Int],
    wide: Bool,
    src_validity: Bool,
    tag: String,
) raises:
    """Every row against the fixture: NULL iff `-1` or a source NULL at
    `_BASE + idx`; a NULL row is a flat (empty) offset span; a valid row is
    `vals[_BASE + idx]`. Also checks `null_count`."""
    var want_nulls = 0
    for i in range(len(idx)):
        var null = idx[i] == -1 or (src_validity and _is_src_null(_BASE + idx[i]))
        if null:
            want_nulls += 1
            assert_false(
                col._validity.value().test(i), tag + " row " + String(i) + " must be NULL"
            )
        else:
            if col._validity:
                assert_true(
                    col._validity.value().test(i),
                    tag + " row " + String(i) + " must be valid",
                )
        if idx[i] == -1:
            assert_equal(_out_str(col, i, wide), String(""), tag + " -1 row is flat")
        else:
            assert_equal(
                _out_str(col, i, wide),
                vals[_BASE + idx[i]],
                tag + " value at row " + String(i),
            )
    assert_equal(col._null_count, want_nulls, tag + " null_count")


def test_a_string_outer_side_over_nullable_window() raises:
    var vals = _vals(40)
    var batch = _one_col_batch(
        _varlen_col(ArrowType.STRING, vals, False, True), ArrowType.STRING
    )
    var idx = _indices(29, 40 - _BASE, True)
    var out = _gather(batch, idx, True)
    ref col = out.column_at(0)
    assert_true(col.arrow_type == ArrowType.STRING, "§A stays STRING")
    assert_true(col._validity.__bool__(), "§A emits a bitmap")
    _check_rows(col, vals, idx, False, True, "§A")


def test_b_string_inner_side_over_nullable_window() raises:
    var vals = _vals(40)
    var batch = _one_col_batch(
        _varlen_col(ArrowType.STRING, vals, False, True), ArrowType.STRING
    )
    var idx = _indices(30, 40 - _BASE, False)
    var out = _gather(batch, idx, False)
    ref col = out.column_at(0)
    assert_true(col._validity.__bool__(), "§B source validity yields a bitmap")
    _check_rows(col, vals, idx, False, True, "§B")


def test_c_string_without_offsets_is_refused() raises:
    var vals = _vals(10)
    var col = _varlen_col(ArrowType.STRING, vals, False, False)
    col._offsets = None
    var batch = _one_col_batch(col^, ArrowType.STRING)
    var idx = _indices(4, 10 - _BASE, False)
    var raised = False
    try:
        _ = _gather(batch, idx, False)
    except e:
        raised = True
        assert_true(
            String(e).find("variable-length column missing offsets") >= 0,
            "§C message: " + String(e),
        )
    assert_true(raised, "§C a STRING column with no offsets must raise")


def test_d_serial_string_promotes_past_the_trip_point() raises:
    var vals = _vals(40)
    var batch = _one_col_batch(
        _varlen_col(ArrowType.STRING, vals, False, True), ArrowType.STRING
    )
    var idx = _indices(23, 40 - _BASE, True)
    var total = 0
    var one_byte = 0
    var two_byte = 0
    for i in range(len(idx)):
        if idx[i] != -1:
            var blen = len(vals[_BASE + idx[i]].as_bytes())
            total += blen
            if blen == 1:
                one_byte += 1
            elif blen == 2:
                two_byte += 1
    # Fixture self-check: the rows gathered here include 1- and 2-byte values,
    # so the short-copy path of both arms is read back below.
    assert_true(one_byte > 0, "§D fixture gathers a 1-byte value")
    assert_true(two_byte > 0, "§D fixture gathers a 2-byte value")

    # One byte below the payload: must promote.
    var out = _gather(batch, idx, True, total - 1)
    ref col = out.column_at(0)
    assert_true(
        col.arrow_type == ArrowType.LARGE_STRING,
        "§D a payload over the trip point is retagged LARGE_STRING",
    )
    assert_equal(
        Int(col._offsets.value().len()),
        (len(idx) + 1) * 8,
        "§D promoted offsets are 8 bytes per entry",
    )
    assert_equal(Int(col._data.len()), total, "§D data length is the payload")
    _check_rows(col, vals, idx, True, True, "§D")

    # Exactly at the trip point: must NOT promote.
    var out2 = _gather(batch, idx, True, total)
    ref col2 = out2.column_at(0)
    assert_true(col2.arrow_type == ArrowType.STRING, "§D at the trip point stays STRING")
    assert_equal(
        Int(col2._offsets.value().len()),
        (len(idx) + 1) * 4,
        "§D unpromoted offsets are 4 bytes per entry",
    )
    _check_rows(col2, vals, idx, False, True, "§D twin")


def test_e_large_string_outer_side_over_nullable_window() raises:
    var vals = _vals(41)
    var batch = _one_col_batch(
        _varlen_col(ArrowType.LARGE_STRING, vals, True, True),
        ArrowType.LARGE_STRING,
    )
    var idx = _indices(31, 41 - _BASE, True)
    var out = _gather(batch, idx, True)
    ref col = out.column_at(0)
    assert_true(col.arrow_type == ArrowType.LARGE_STRING, "§E stays LARGE_STRING")
    assert_equal(
        Int(col._offsets.value().len()), (len(idx) + 1) * 8, "§E int64 offsets"
    )
    _check_rows(col, vals, idx, True, True, "§E")


def test_e2_large_string_outer_side_without_source_validity() raises:
    """The outer-side arm over a source with NO bitmap: only `-1` is NULL."""
    var vals = _vals(20)
    var batch = _one_col_batch(
        _varlen_col(ArrowType.LARGE_STRING, vals, True, False),
        ArrowType.LARGE_STRING,
    )
    var idx = _indices(14, 20 - _BASE, True)
    var out = _gather(batch, idx, True)
    ref col = out.column_at(0)
    assert_true(col._validity.__bool__(), "§E2 outer side emits a bitmap")
    _check_rows(col, vals, idx, True, False, "§E2")


def test_f_large_binary_inner_side_keeps_its_tag() raises:
    var vals = _vals(33)
    var batch = _one_col_batch(
        _varlen_col(ArrowType.LARGE_BINARY, vals, True, True),
        ArrowType.LARGE_BINARY,
    )
    var idx = _indices(25, 33 - _BASE, False)
    var out = _gather(batch, idx, False)
    ref col = out.column_at(0)
    assert_true(col.arrow_type == ArrowType.LARGE_BINARY, "§F tag carried")
    assert_true(col._validity.__bool__(), "§F source validity yields a bitmap")
    _check_rows(col, vals, idx, True, True, "§F")


def test_g_large_string_without_validity_emits_no_bitmap() raises:
    var vals = _vals(12)
    var batch = _one_col_batch(
        _varlen_col(ArrowType.LARGE_STRING, vals, True, False),
        ArrowType.LARGE_STRING,
    )
    var idx = _indices(9, 12 - _BASE, False)
    var out = _gather(batch, idx, False)
    ref col = out.column_at(0)
    assert_false(col._validity.__bool__(), "§G no source bitmap, inner side")
    assert_equal(col._null_count, 0, "§G null_count")
    for i in range(len(idx)):
        assert_equal(_out_str(col, i, True), vals[_BASE + idx[i]], "§G value")


def test_h_large_string_without_offsets_is_refused() raises:
    var vals = _vals(10)
    var col = _varlen_col(ArrowType.LARGE_STRING, vals, True, False)
    col._offsets = None
    var batch = _one_col_batch(col^, ArrowType.LARGE_STRING)
    var idx = _indices(4, 10 - _BASE, False)
    var raised = False
    try:
        _ = _gather(batch, idx, False)
    except e:
        raised = True
        assert_true(
            String(e).find("missing offsets (arrow_type=") >= 0,
            "§H message: " + String(e),
        )
    assert_true(raised, "§H a LARGE_STRING column with no offsets must raise")


def test_i_column_past_the_schema_falls_back_to_a_plain_field() raises:
    var vals = _vals(10)
    var sb = SchemaBuilder()
    sb.add_field(Field(String("a"), ArrowType.STRING, False))
    sb.add_field(Field(String("b"), ArrowType.STRING, False))
    var bb = RecordBatchBuilder()
    bb.add_column(_varlen_col(ArrowType.STRING, vals, False, False))
    bb.add_column(_varlen_col(ArrowType.STRING, vals, False, True))
    var batch = bb.build(sb.build())
    # Narrow the schema to ONE field: column 1 is now past the schema.
    var narrow = SchemaBuilder()
    narrow.add_field(Field(String("a"), ArrowType.STRING, False))
    batch.schema = narrow.build()

    var idx = _indices(5, 10 - _BASE, False)
    var builder = RecordBatchBuilder()
    var osb = SchemaBuilder()
    emit_gather_column_projected(
        batch, 1, String("renamed"), False, idx, len(idx), builder, osb
    )
    var schema = osb.build()
    assert_equal(schema.num_columns(), 1, "§I one field emitted")
    assert_equal(schema.field_name(0), String("renamed"), "§I name")
    assert_true(
        schema.field_arrow_type(0) == ArrowType.STRING, "§I type from the column"
    )
    assert_true(
        schema.field_at(0).nullable,
        "§I nullability from the column's own bitmap",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_a_string_outer_side_over_nullable_window]()
    suite.test[test_b_string_inner_side_over_nullable_window]()
    suite.test[test_c_string_without_offsets_is_refused]()
    suite.test[test_d_serial_string_promotes_past_the_trip_point]()
    suite.test[test_e_large_string_outer_side_over_nullable_window]()
    suite.test[test_e2_large_string_outer_side_without_source_validity]()
    suite.test[test_f_large_binary_inner_side_keeps_its_tag]()
    suite.test[test_g_large_string_without_validity_emits_no_bitmap]()
    suite.test[test_h_large_string_without_offsets_is_refused]()
    suite.test[test_i_column_past_the_schema_falls_back_to_a_plain_field]()
    suite^.run()
