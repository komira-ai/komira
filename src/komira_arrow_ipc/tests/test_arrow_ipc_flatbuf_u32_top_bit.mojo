# =============================================================================
# test_arrow_ipc_flatbuf_u32_top_bit.mojo
# =============================================================================
#
# `end_table` once told an offset field from a u32 scalar by bit 31 of the
# stored value: `add_field_offset` stored `target | 0x80000000`, and any
# `add_field_u32` value with bit 31 set was also written as an offset. A
# negative Decimal scale (Schema.fbs `Decimal.scale: int`; Arrow allows a
# negative scale) is such a value, so it was written as an offset and read
# back as another number. komira-ai/komira#1257.
#
# What each test proves:
#
#   1. u32 values with bit 31 set (0x80000000, 0xFFFFFFFE, 0xFFFFFFFF) are
#      written as themselves, next to an offset field in the same table.
#      0x7FFFFFFF is the control (bit 31 clear, correct before the fix too)
#      and the offset field resolves to its string, so the offset path still
#      works with the new marker.
#   2. A u32 field set after an offset field on the same slot is written as
#      a u32: the offset marker does not outlive the value it marked.
#   3. `write_type_decimal` with scale -2 puts FE FF FF FF on the wire
#      (checked through the raw u32 reader, independent of the Decimal
#      reader).
#   4. `read_type_decimal` returns that scale as -2, and -2^31 as -2^31:
#      the reader reads the field as Schema.fbs's `int`, not as a u32. Scale
#      4 and scale 0 are the controls.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_arrow_ipc.ipc_flatbuf import (
    FlatbufWriter,
    flatbuf_reader_over,
    start_table,
    add_field_u32,
    add_field_offset,
    end_table,
    write_type_decimal,
    read_type_decimal,
    _read_table_field_u32,
    _read_table_field_offset,
)


def test_u32_with_top_bit_set_is_written_as_itself() raises:
    var w = FlatbufWriter(256)
    var name_pos = w.write_string("abc")
    var tb = start_table()
    add_field_u32(tb, 0, UInt32(0x80000000))
    add_field_u32(tb, 1, UInt32(0xFFFFFFFF))
    add_field_u32(tb, 2, UInt32(0x7FFFFFFF))
    add_field_offset(tb, 3, name_pos)
    add_field_u32(tb, 4, UInt32(0xFFFFFFFE))
    var table_pos = end_table(w, tb^)
    var buf = w^.finalize(table_pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    assert_equal(_read_table_field_u32(r, root, 0), UInt32(0x80000000))
    assert_equal(_read_table_field_u32(r, root, 1), UInt32(0xFFFFFFFF))
    assert_equal(_read_table_field_u32(r, root, 2), UInt32(0x7FFFFFFF))
    assert_equal(_read_table_field_u32(r, root, 4), UInt32(0xFFFFFFFE))
    var target = _read_table_field_offset(r, root, 3)
    assert_equal(r.read_string_at(target), "abc")


def test_u32_after_offset_on_same_slot_is_written_as_u32() raises:
    var w = FlatbufWriter(256)
    var name_pos = w.write_string("abc")
    var tb = start_table()
    add_field_offset(tb, 0, name_pos)
    add_field_u32(tb, 0, UInt32(7))
    var table_pos = end_table(w, tb^)
    var buf = w^.finalize(table_pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    assert_equal(_read_table_field_u32(r, root, 0), UInt32(7))


def test_negative_decimal_scale_on_the_wire() raises:
    var w = FlatbufWriter(256)
    var type_pos = write_type_decimal(w, 38, -2, 128)
    var buf = w^.finalize(type_pos)
    var r = flatbuf_reader_over(buf)
    var root = r.read_root_offset()
    assert_equal(_read_table_field_u32(r, root, 1), UInt32(0xFFFFFFFE))
    assert_equal(_read_table_field_u32(r, root, 0), UInt32(38))
    assert_equal(_read_table_field_u32(r, root, 2), UInt32(128))


def _decimal_round_trip(precision: Int, scale: Int) raises:
    var w = FlatbufWriter(256)
    var type_pos = write_type_decimal(w, precision, scale, 256)
    var buf = w^.finalize(type_pos)
    var r = flatbuf_reader_over(buf)
    var d = read_type_decimal(r, r.read_root_offset())
    assert_equal(d.precision, precision)
    assert_equal(d.scale, scale)
    assert_equal(d.bit_width, 256)


def test_negative_decimal_scale_round_trips() raises:
    _decimal_round_trip(38, -2)
    _decimal_round_trip(76, -2147483648)


def test_non_negative_decimal_scale_round_trips() raises:
    _decimal_round_trip(18, 4)
    _decimal_round_trip(10, 0)


def main() raises:
    var suite = TestSuite()
    suite.test[test_u32_with_top_bit_set_is_written_as_itself]()
    suite.test[test_u32_after_offset_on_same_slot_is_written_as_u32]()
    suite.test[test_negative_decimal_scale_on_the_wire]()
    suite.test[test_negative_decimal_scale_round_trips]()
    suite.test[test_non_negative_decimal_scale_round_trips]()
    suite^.run()
