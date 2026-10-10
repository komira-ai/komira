# =============================================================================
# test_arrow_ipc_flatbuf_absent_field_defaults.mojo
# =============================================================================
#
# A FlatBuffers writer omits a scalar field whose value equals the default
# its schema declares, and pyarrow does. A reader that returns 0 for an
# absent field misreads every field whose declared default is not 0. In
# Arrow's Schema.fbs those are `Date.unit = MILLISECOND`,
# `Time.unit = MILLISECOND`, `Time.bitWidth = 32`,
# `Duration.unit = MILLISECOND` and `Decimal.bitWidth = 128`: read as 0,
# pyarrow's date64 becomes date32, time32[ms] becomes time32[s] and
# duration[ms] becomes duration[s].
#
# What each group proves:
#
#   1. pyarrow bytes (schema_only.arrow, written by pyarrow 24.0.0). The test
#      first checks on the wire which fields pyarrow omitted (date64,
#      time32[ms] unit and bitWidth, decimal128 bitWidth, float16 precision,
#      Schema endianness) and which it wrote although they are 0 (date32 DAY,
#      duration[s] SECOND), then checks the decoded value of each. A reader
#      that ignores the default fails the first kind; a reader that treats a
#      written 0 as absent fails the second.
#   2. Hand-built tables, the two ways a field can be absent: the vtable is
#      too short to hold the slot (what flatc and pyarrow emit, since they
#      trim trailing empty slots), or the slot is there and holds 0. Every
#      Type table with a defaulted scalar is read both ways, so each default
#      passed to `_read_table_field_u8_or` / `_u32_or` is pinned, including
#      the 0 defaults (Timestamp SECOND, Interval YEAR_MONTH, Union Sparse,
#      FloatingPoint HALF, Schema Little), which a wrong constant would break.
#      duration[ms] has no pyarrow fixture; its table is the empty table
#      pyarrow writes for it (no fields, a 4-byte vtable).
#   3. Explicit values, including a written 0 that differs from the default
#      (SECOND, DAY, bitWidth 0): the reader returns the wire value, not the
#      default. This catches a reader that maps 0 to the default.
#   4. komira's writer writes every unit explicitly, so the bytes it writes
#      read back the same whatever a reader assumes for an absent field; the
#      test checks the slot is present on the wire.
#   5. A table whose soffset points before the buffer raises from the u8 and
#      u32 readers rather than being read as absent.
#   6. A Field with no name: Schema.fbs says "Name is not required (e.g., in
#      a List)", and Arrow C++ reads a missing name as "". read_field returns
#      "" and the rest of the Field, instead of refusing it.
# =============================================================================

from std.io import FileHandle
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufReader,
    FlatbufWriter,
    flatbuf_reader_over,
    parse_ipc_message,
    read_message,
    read_schema,
    read_type_date,
    read_type_decimal,
    read_type_duration,
    read_type_fixed_size_binary,
    read_type_floating_point,
    read_type_interval,
    read_type_time,
    read_type_timestamp,
    read_type_union,
    read_field,
    read_type_int,
    write_type_int,
    start_table,
    add_field_u8,
    add_field_offset,
    end_table,
    TYPE_INT,
    write_type_date,
    write_type_duration,
    write_type_time,
    MESSAGE_HEADER_SCHEMA,
    TYPE_DATE,
    TYPE_DECIMAL,
    TYPE_DURATION,
    TYPE_FIXED_SIZE_BINARY,
    TYPE_FLOATING_POINT,
    TYPE_TIME,
    TYPE_TIMESTAMP,
    DATE_UNIT_DAY,
    DATE_UNIT_MILLISECOND,
    TIME_UNIT_SECOND,
    TIME_UNIT_MILLISECOND,
    TIME_UNIT_MICROSECOND,
    TIME_UNIT_NANOSECOND,
    INTERVAL_UNIT_YEAR_MONTH,
    UNION_MODE_SPARSE,
    PRECISION_HALF,
    PRECISION_SINGLE,
    PRECISION_DOUBLE,
    ENDIANNESS_LITTLE,
)


comptime FIXTURE = "src/komira_arrow_ipc/tests/fixtures/arrow_ipc/schema_only.arrow"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _vtable_slot[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int, field_id: Int) raises -> Int:
    """The vtable entry for `field_id` of the table at `table_pos`, read
    independently of the product's field readers: -1 when the vtable is too
    short to hold the slot, else the slot's value (0 = absent)."""
    var vtable_pos = table_pos - Int(reader.read_i32_le(table_pos))
    var vtable_size = Int(reader.read_u16_le(vtable_pos))
    var slot = 4 + field_id * 2
    if slot + 2 > vtable_size:
        return -1
    return Int(reader.read_u16_le(vtable_pos + slot))


def _absent[
    bo: Origin[mut=False]
](reader: FlatbufReader[bo], table_pos: Int, field_id: Int) raises -> Bool:
    return _vtable_slot(reader, table_pos, field_id) <= 0


def _table(
    slots: List[Int], inline_bytes: List[UInt8]
) raises -> SharedAlignedBuffer[HeapRegion]:
    """One FlatBuffers root table, laid out as flatc lays it out:

        0                 root uoffset -> table
        4                 vtable: u16 vtable size, u16 table size, u16 slots
        table_pos         i32 soffset (table_pos - 4, back to the vtable)
        table_pos + 4     `inline_bytes`

    `slots[i]` is field i's offset from table_pos (0 = absent); the first
    inline byte is at offset 4. table_pos is 4-aligned, so a field at an
    offset that is a multiple of its width is naturally aligned.
    """
    var vtable_size = 4 + 2 * len(slots)
    var table_pos = (4 + vtable_size + 3) // 4 * 4
    var used = table_pos + 4 + len(inline_bytes)
    var total = (used + 7) // 8 * 8
    var buf = SharedAlignedBuffer[HeapRegion].heap_owned(total)
    for i in range(total):
        buf.write_u8_at(i, UInt8(0))
    _put_u32(buf, 0, table_pos)
    _put_u16(buf, 4, vtable_size)
    _put_u16(buf, 6, 4 + len(inline_bytes))
    for i in range(len(slots)):
        _put_u16(buf, 8 + 2 * i, slots[i])
    _put_u32(buf, table_pos, table_pos - 4)
    for i in range(len(inline_bytes)):
        buf.write_u8_at(table_pos + 4 + i, inline_bytes[i])
    buf.set_length(total)
    return buf^


def _put_u16(mut buf: SharedAlignedBuffer[HeapRegion], pos: Int, v: Int):
    buf.write_u8_at(pos, UInt8(v & 0xFF))
    buf.write_u8_at(pos + 1, UInt8((v >> 8) & 0xFF))


def _put_u32(mut buf: SharedAlignedBuffer[HeapRegion], pos: Int, v: Int):
    for i in range(4):
        buf.write_u8_at(pos + i, UInt8((v >> (8 * i)) & 0xFF))


def _i16(v: Int) -> List[UInt8]:
    """A little-endian i16 inline value padded to 4 bytes (Arrow's `short`
    enums are i16 on the wire)."""
    return [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), 0, 0]


def _i32(v: Int) -> List[UInt8]:
    return [
        UInt8(v & 0xFF),
        UInt8((v >> 8) & 0xFF),
        UInt8((v >> 16) & 0xFF),
        UInt8((v >> 24) & 0xFF),
    ]


def _empty() raises -> SharedAlignedBuffer[HeapRegion]:
    """A table with no fields and a 4-byte vtable: what pyarrow writes for
    Date{MILLISECOND}, Duration{MILLISECOND} and friends."""
    return _table([], [])


def _slot0_empty() raises -> SharedAlignedBuffer[HeapRegion]:
    """A table whose vtable holds slot 0 with value 0 (field absent)."""
    return _table([0], [])


def _load_schema_payload() raises -> SharedAlignedBuffer[HeapRegion]:
    var f = FileHandle(String(FIXTURE), "r")
    _ = f.seek(0, 2)  # SEEK_END
    var file_size = Int(f.seek(0, 1))  # SEEK_CUR == tell
    _ = f.seek(0, 0)
    var raw = f.read_bytes(file_size)
    f.close()
    var frame_buf = SharedAlignedBuffer[HeapRegion].heap_owned(len(raw))
    for i in range(len(raw)):
        frame_buf.write_u8_at(i, raw[i])
    frame_buf.set_length(len(raw))
    var frame = parse_ipc_message(frame_buf)
    var size = frame.metadata_size
    var payload = SharedAlignedBuffer[HeapRegion].heap_owned(size)
    for i in range(size):
        payload.write_u8_at(i, frame_buf.read_u8_at(frame.metadata_pos + i))
    payload.set_length(size)
    return payload^


# ---------------------------------------------------------------------------
# 1. pyarrow-written schema
# ---------------------------------------------------------------------------


def test_pyarrow_schema_omitted_fields_read_as_declared_defaults() raises:
    """date64, time32[ms] and the other defaulted fields pyarrow omits."""
    var payload = _load_schema_payload()
    var r = flatbuf_reader_over(payload)
    var msg = read_message(r, r.read_root_offset())
    assert_equal(msg.header_tag, MESSAGE_HEADER_SCHEMA)
    var schema = read_schema(r, msg.header_table_pos)
    assert_equal(len(schema.fields), 23)

    # Schema.endianness = Little, omitted.
    assert_true(_absent(r, msg.header_table_pos, 0), "endianness written")
    assert_equal(schema.endianness, ENDIANNESS_LITTLE)

    # f_float16: FloatingPoint.precision = HALF, omitted.
    ref f16 = schema.fields[10]
    assert_equal(f16.name, "f_float16")
    assert_equal(f16.type_tag, TYPE_FLOATING_POINT)
    assert_true(_absent(r, f16.type_table_pos, 0), "precision written")
    var fp16 = read_type_floating_point(r, f16.type_table_pos)
    assert_equal(fp16.precision, PRECISION_HALF)
    assert_equal(
        read_type_floating_point(r, schema.fields[11].type_table_pos).precision,
        PRECISION_SINGLE,
    )
    assert_equal(
        read_type_floating_point(r, schema.fields[12].type_table_pos).precision,
        PRECISION_DOUBLE,
    )

    # f_decimal128: Decimal.bitWidth = 128, omitted.
    ref fdec = schema.fields[13]
    assert_equal(fdec.name, "f_decimal128")
    assert_equal(fdec.type_tag, TYPE_DECIMAL)
    assert_true(_absent(r, fdec.type_table_pos, 2), "bitWidth written")
    var dec = read_type_decimal(r, fdec.type_table_pos)
    assert_equal(dec.precision, 18)
    assert_equal(dec.scale, 4)
    assert_equal(dec.bit_width, 128)

    # f_date64: Date.unit = MILLISECOND, omitted. The defect read it as DAY.
    ref fd64 = schema.fields[15]
    assert_equal(fd64.name, "f_date64")
    assert_equal(fd64.type_tag, TYPE_DATE)
    assert_true(_absent(r, fd64.type_table_pos, 0), "date64 unit written")
    assert_equal(
        read_type_date(r, fd64.type_table_pos).unit, DATE_UNIT_MILLISECOND
    )

    # f_time32_ms: Time.unit = MILLISECOND and bitWidth = 32, both omitted.
    # The defect read the unit as SECOND.
    ref ft32 = schema.fields[16]
    assert_equal(ft32.name, "f_time32_ms")
    assert_equal(ft32.type_tag, TYPE_TIME)
    assert_true(_absent(r, ft32.type_table_pos, 0), "time32 unit written")
    assert_true(_absent(r, ft32.type_table_pos, 1), "time32 bitWidth written")
    var t32 = read_type_time(r, ft32.type_table_pos)
    assert_equal(t32.unit, TIME_UNIT_MILLISECOND)
    assert_equal(t32.bit_width, 32)


def test_pyarrow_schema_written_zero_reads_as_written() raises:
    """date32 (DAY = 0) and duration[s] (SECOND = 0) differ from the declared
    default MILLISECOND, so pyarrow writes them; the reader must return 0."""
    var payload = _load_schema_payload()
    var r = flatbuf_reader_over(payload)
    var msg = read_message(r, r.read_root_offset())
    var schema = read_schema(r, msg.header_table_pos)

    ref fd32 = schema.fields[14]
    assert_equal(fd32.name, "f_date32")
    assert_true(_vtable_slot(r, fd32.type_table_pos, 0) > 0, "DAY omitted")
    assert_equal(read_type_date(r, fd32.type_table_pos).unit, DATE_UNIT_DAY)

    ref fdur = schema.fields[19]
    assert_equal(fdur.name, "f_duration_s")
    assert_equal(fdur.type_tag, TYPE_DURATION)
    assert_true(_vtable_slot(r, fdur.type_table_pos, 0) > 0, "SECOND omitted")
    assert_equal(
        read_type_duration(r, fdur.type_table_pos).unit, TIME_UNIT_SECOND
    )

    # Non-default, non-zero values pyarrow writes.
    ref ft64 = schema.fields[17]
    assert_equal(ft64.name, "f_time64_us")
    var t64 = read_type_time(r, ft64.type_table_pos)
    assert_equal(t64.unit, TIME_UNIT_MICROSECOND)
    assert_equal(t64.bit_width, 64)
    ref fts = schema.fields[18]
    assert_equal(fts.type_tag, TYPE_TIMESTAMP)
    var ts = read_type_timestamp(r, fts.type_table_pos)
    assert_equal(ts.unit, TIME_UNIT_NANOSECOND)
    assert_equal(ts.timezone, "UTC")
    ref ffsb = schema.fields[22]
    assert_equal(ffsb.type_tag, TYPE_FIXED_SIZE_BINARY)
    assert_equal(
        read_type_fixed_size_binary(r, ffsb.type_table_pos).byte_width, 16
    )


# ---------------------------------------------------------------------------
# 2. Absent fields, both shapes
# ---------------------------------------------------------------------------


def test_short_vtable_reads_declared_defaults() raises:
    """Every defaulted scalar read from a table with a 4-byte vtable."""
    var b = _empty()
    var r = flatbuf_reader_over(b)
    var t = r.read_root_offset()
    assert_equal(_vtable_slot(r, t, 0), -1)
    assert_equal(read_type_date(r, t).unit, DATE_UNIT_MILLISECOND)
    assert_equal(read_type_duration(r, t).unit, TIME_UNIT_MILLISECOND)
    var tm = read_type_time(r, t)
    assert_equal(tm.unit, TIME_UNIT_MILLISECOND)
    assert_equal(tm.bit_width, 32)
    var dec = read_type_decimal(r, t)
    assert_equal(dec.precision, 0)
    assert_equal(dec.scale, 0)
    assert_equal(dec.bit_width, 128)
    assert_equal(read_type_timestamp(r, t).unit, TIME_UNIT_SECOND)
    assert_equal(read_type_interval(r, t).unit, INTERVAL_UNIT_YEAR_MONTH)
    assert_equal(read_type_union(r, t).mode, UNION_MODE_SPARSE)
    assert_equal(read_type_floating_point(r, t).precision, PRECISION_HALF)
    var sd = read_schema(r, t)
    assert_equal(sd.endianness, ENDIANNESS_LITTLE)
    assert_equal(len(sd.fields), 0)


def test_empty_slot_reads_declared_defaults() raises:
    """Every defaulted u8 field read from a vtable whose slot 0 holds 0."""
    var b = _slot0_empty()
    var r = flatbuf_reader_over(b)
    var t = r.read_root_offset()
    assert_equal(_vtable_slot(r, t, 0), 0)
    assert_equal(read_type_date(r, t).unit, DATE_UNIT_MILLISECOND)
    assert_equal(read_type_duration(r, t).unit, TIME_UNIT_MILLISECOND)
    assert_equal(read_type_time(r, t).unit, TIME_UNIT_MILLISECOND)
    assert_equal(read_type_timestamp(r, t).unit, TIME_UNIT_SECOND)
    assert_equal(read_type_interval(r, t).unit, INTERVAL_UNIT_YEAR_MONTH)
    assert_equal(read_type_union(r, t).mode, UNION_MODE_SPARSE)
    assert_equal(read_type_floating_point(r, t).precision, PRECISION_HALF)
    assert_equal(read_schema(r, t).endianness, ENDIANNESS_LITTLE)


def test_time_unit_empty_slot_bit_width_written() raises:
    """Time{unit absent (slot 0 = 0), bitWidth = 32 written}: unit is
    MILLISECOND, bitWidth the written 32."""
    var b = _table([0, 4], _i32(32))
    var r = flatbuf_reader_over(b)
    var tm = read_type_time(r, r.read_root_offset())
    assert_equal(tm.unit, TIME_UNIT_MILLISECOND)
    assert_equal(tm.bit_width, 32)


def test_decimal_bit_width_empty_slot() raises:
    """Decimal{precision 38, scale 10 written, bitWidth slot = 0}: 128."""
    var bytes = _i32(38)
    bytes.extend(_i32(10))
    var b = _table([4, 8, 0], bytes)
    var r = flatbuf_reader_over(b)
    var dec = read_type_decimal(r, r.read_root_offset())
    assert_equal(dec.precision, 38)
    assert_equal(dec.scale, 10)
    assert_equal(dec.bit_width, 128)


def test_time_bit_width_empty_slot() raises:
    """Time{unit = SECOND written, bitWidth slot = 0}: unit SECOND, 32."""
    var b = _table([4, 0], _i16(Int(TIME_UNIT_SECOND)))
    var r = flatbuf_reader_over(b)
    var tm = read_type_time(r, r.read_root_offset())
    assert_equal(tm.unit, TIME_UNIT_SECOND)
    assert_equal(tm.bit_width, 32)


# ---------------------------------------------------------------------------
# 3. Written values, including a written 0 that is not the default
# ---------------------------------------------------------------------------


def test_written_zero_units_read_as_written() raises:
    var b = _table([4], _i16(0))
    var r = flatbuf_reader_over(b)
    var t = r.read_root_offset()
    assert_equal(read_type_date(r, t).unit, DATE_UNIT_DAY)
    assert_equal(read_type_duration(r, t).unit, TIME_UNIT_SECOND)
    assert_equal(read_type_time(r, t).unit, TIME_UNIT_SECOND)


def test_written_non_zero_units_read_as_written() raises:
    var b = _table([4], _i16(Int(TIME_UNIT_NANOSECOND)))
    var r = flatbuf_reader_over(b)
    var t = r.read_root_offset()
    assert_equal(read_type_duration(r, t).unit, TIME_UNIT_NANOSECOND)
    assert_equal(read_type_time(r, t).unit, TIME_UNIT_NANOSECOND)
    assert_equal(read_type_timestamp(r, t).unit, TIME_UNIT_NANOSECOND)
    var b2 = _table([4], _i16(Int(DATE_UNIT_MILLISECOND)))
    var r2 = flatbuf_reader_over(b2)
    assert_equal(
        read_type_date(r2, r2.read_root_offset()).unit, DATE_UNIT_MILLISECOND
    )


def test_written_bit_widths_read_as_written() raises:
    """A written bitWidth is returned as written, 0 included: the reader
    reports the wire value and leaves rejecting a bad width to its caller."""
    var dec_bytes = _i32(76)
    dec_bytes.extend(_i32(0))
    dec_bytes.extend(_i32(256))
    var b = _table([4, 8, 12], dec_bytes)
    var r = flatbuf_reader_over(b)
    assert_equal(read_type_decimal(r, r.read_root_offset()).bit_width, 256)
    var zero_bytes = _i32(5)
    zero_bytes.extend(_i32(2))
    zero_bytes.extend(_i32(0))
    var bz = _table([4, 8, 12], zero_bytes)
    var rz = flatbuf_reader_over(bz)
    assert_equal(read_type_decimal(rz, rz.read_root_offset()).bit_width, 0)
    var tz_bytes = _i16(Int(TIME_UNIT_SECOND))
    tz_bytes.extend(_i32(0))
    var bt = _table([4, 8], tz_bytes)
    var rt = flatbuf_reader_over(bt)
    assert_equal(read_type_time(rt, rt.read_root_offset()).bit_width, 0)


# ---------------------------------------------------------------------------
# 4. komira's writer writes every unit explicitly
# ---------------------------------------------------------------------------


def test_writer_writes_default_units_explicitly() raises:
    var w = FlatbufWriter(256)
    var pos = write_type_duration(w, TIME_UNIT_MILLISECOND)
    var b = w^.finalize(pos)
    var r = flatbuf_reader_over(b)
    var t = r.read_root_offset()
    assert_true(_vtable_slot(r, t, 0) > 0, "Duration unit omitted")
    assert_equal(read_type_duration(r, t).unit, TIME_UNIT_MILLISECOND)

    var w2 = FlatbufWriter(256)
    var pos2 = write_type_time(w2, TIME_UNIT_SECOND, 32)
    var b2 = w2^.finalize(pos2)
    var r2 = flatbuf_reader_over(b2)
    var t2 = r2.read_root_offset()
    assert_true(_vtable_slot(r2, t2, 0) > 0, "Time unit omitted")
    assert_true(_vtable_slot(r2, t2, 1) > 0, "Time bitWidth omitted")
    var tm = read_type_time(r2, t2)
    assert_equal(tm.unit, TIME_UNIT_SECOND)
    assert_equal(tm.bit_width, 32)

    var w3 = FlatbufWriter(256)
    var pos3 = write_type_date(w3, DATE_UNIT_MILLISECOND)
    var b3 = w3^.finalize(pos3)
    var r3 = flatbuf_reader_over(b3)
    var t3 = r3.read_root_offset()
    assert_true(_vtable_slot(r3, t3, 0) > 0, "Date unit omitted")
    assert_equal(read_type_date(r3, t3).unit, DATE_UNIT_MILLISECOND)


# ---------------------------------------------------------------------------
# 5. A corrupt soffset is refused, not read as an absent field
# ---------------------------------------------------------------------------


def test_soffset_before_buffer_start_raises() raises:
    """A table whose soffset points before byte 0 raises from both readers
    instead of reporting the field's default."""
    var b = SharedAlignedBuffer[HeapRegion].heap_owned(8)
    for i in range(8):
        b.write_u8_at(i, UInt8(0))
    _put_u32(b, 0, 4)  # root -> table at 4
    _put_u32(b, 4, 100)  # soffset: vtable at 4 - 100 = -96
    b.set_length(8)
    var r = flatbuf_reader_over(b)
    var t = r.read_root_offset()
    with assert_raises(contains="invalid vtable position"):
        _ = read_type_date(r, t)
    with assert_raises(contains="invalid vtable position"):
        _ = read_type_decimal(r, t)


# ---------------------------------------------------------------------------
# 6. Field.name is optional
# ---------------------------------------------------------------------------


def test_field_without_name_reads_empty_name() raises:
    """A Field table with no name slot (an Int32 list item as writers may
    emit it) reads as name "", with its type intact."""
    var w = FlatbufWriter(1024)
    var int_pos = write_type_int(w, 32, True)
    var tb = start_table()
    add_field_u8(tb, 2, TYPE_INT)
    add_field_offset(tb, 3, int_pos)
    var field_pos = end_table(w, tb^)
    var buf = w^.finalize(field_pos)
    var r = flatbuf_reader_over(buf)
    var t = r.read_root_offset()
    assert_true(_absent(r, t, 0), "the table carries no name slot")
    var fd = read_field(r, t)
    assert_equal(fd.name, "")
    assert_equal(fd.type_tag, TYPE_INT)
    var it = read_type_int(r, fd.type_table_pos)
    assert_equal(it.bit_width, 32)
    assert_true(it.is_signed)


def main() raises:
    var suite = TestSuite()
    suite.test[test_pyarrow_schema_omitted_fields_read_as_declared_defaults]()
    suite.test[test_pyarrow_schema_written_zero_reads_as_written]()
    suite.test[test_short_vtable_reads_declared_defaults]()
    suite.test[test_empty_slot_reads_declared_defaults]()
    suite.test[test_time_unit_empty_slot_bit_width_written]()
    suite.test[test_decimal_bit_width_empty_slot]()
    suite.test[test_time_bit_width_empty_slot]()
    suite.test[test_written_zero_units_read_as_written]()
    suite.test[test_written_non_zero_units_read_as_written]()
    suite.test[test_written_bit_widths_read_as_written]()
    suite.test[test_writer_writes_default_units_explicitly]()
    suite.test[test_soffset_before_buffer_start_raises]()
    suite.test[test_field_without_name_reads_empty_name]()
    suite^.run()
