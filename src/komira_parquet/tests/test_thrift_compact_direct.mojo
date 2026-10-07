# =============================================================================
# ThriftCompactReader and parse_metadata_summary.
#
# Every input is built here, byte by byte, from the Thrift Compact Protocol's
# definition (a field header is `delta << 4 | type`, or `type` followed by a
# zigzag field id; integers are zigzag ULEB128 varints; a list header is
# `size << 4 | element type`, size 15 meaning a varint follows). The tests
# read each wire type, and hold the reader to its refusals: a read outside the
# view, a varint past 64 bits or negative, a length or element count the
# bytes cannot hold, and nesting past the depth cap, which a list of lists or
# a map of maps reaches without passing through a struct. The summary's
# created_by is held to a length near Int.MAX, which wrapped its bound.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.byte_view import ByteView
from komira_parquet.thrift_compact import (
    ParquetMetadataSummary,
    ThriftCompactReader,
    parse_metadata_summary,
)


def _view[
    mut: Bool, //, o: Origin[mut=mut]
](data: Span[UInt8, o]) -> ByteView[o]:
    return ByteView[o](data.unsafe_ptr(), len(data))


def _uleb(mut out: List[UInt8], v: Int):
    var x = UInt64(v)
    while x >= 0x80:
        out.append(UInt8((x & 0x7F) | 0x80))
        x >>= 7
    out.append(UInt8(x))


def _zz(mut out: List[UInt8], v: Int):
    _uleb(out, (v << 1) ^ (v >> 63))


def _fh(mut out: List[UInt8], delta: Int, wire_type: Int):
    out.append(UInt8((delta << 4) | wire_type))


def _raises_with(data: List[UInt8], wire_type: Int, needle: String) -> Bool:
    """Whether `_skip_field(wire_type)` over `data` raises an error naming
    `needle`."""
    try:
        var r = ThriftCompactReader(_view(Span(data)))
        r._skip_field(wire_type)
    except e:
        return String(e).find(needle) >= 0
    return False


# ---- byte_at / load_i64_le_at / _read_byte ---------------------------------


def test_byte_at_reads_inside_and_refuses_outside() raises:
    var data: List[UInt8] = [7, 8, 9]
    var r = ThriftCompactReader(_view(Span(data)))
    assert_equal(r.data_len, 3)
    assert_equal(r.byte_at(0), 7)
    assert_equal(r.byte_at(2), 9)
    var low = False
    try:
        _ = r.byte_at(-1)
    except:
        low = True
    var high = False
    try:
        _ = r.byte_at(3)
    except:
        high = True
    assert_true(low)
    assert_true(high)


def test_load_i64_le_at_reads_and_refuses_a_partial_word() raises:
    var data: List[UInt8] = [0xFF, 1, 2, 3, 4, 5, 6, 7, 0x80]
    var r = ThriftCompactReader(_view(Span(data)))
    assert_equal(r.load_i64_le_at(1), UInt64(0x8007060504030201).cast[DType.int64]())
    var low = False
    try:
        _ = r.load_i64_le_at(-1)
    except e:
        low = String(e).find("load_i64_le_at") >= 0
    assert_true(low)
    # Offset 2 leaves 7 bytes: the word would end one byte past the view.
    var high = False
    try:
        _ = r.load_i64_le_at(2)
    except e:
        high = String(e).find("load_i64_le_at") >= 0
    assert_true(high)


def test_read_byte_refuses_a_position_on_either_side() raises:
    var data: List[UInt8] = [5]
    var r = ThriftCompactReader(_view(Span(data)))
    assert_equal(r._read_byte(), 5)
    assert_equal(r.pos, 1)
    var past = False
    try:
        _ = r._read_byte()
    except:
        past = True
    assert_true(past)
    r.pos = -1
    var before = False
    try:
        _ = r._read_byte()
    except:
        before = True
    assert_true(before)


# ---- varints and field headers -----------------------------------------------


def test_varint_and_zigzag_round_trip() raises:
    var values: List[Int] = [0, 1, 127, 128, 300, 1 << 40, (1 << 62) + 5]
    for i in range(len(values)):
        var data = List[UInt8]()
        _uleb(data, values[i])
        var r = ThriftCompactReader(_view(Span(data)))
        assert_equal(r._read_varint(), values[i])
        assert_equal(r.pos, len(data))
    var signed: List[Int] = [0, -1, 1, -64, 63, -(1 << 40), 1 << 40]
    for i in range(len(signed)):
        var data = List[UInt8]()
        _zz(data, signed[i])
        var r = ThriftCompactReader(_view(Span(data)))
        assert_equal(r._read_zigzag(), signed[i])


def test_varint_past_64_bits_is_refused() raises:
    # Ten continuation bytes: the eleventh would start past bit 63.
    var data = List[UInt8](length=11, fill=0x80)
    var r = ThriftCompactReader(_view(Span(data)))
    var raised = False
    try:
        _ = r._read_varint()
    except e:
        raised = String(e).find("past 64 bits") >= 0
    assert_true(raised)


def test_varint_with_the_sign_bit_set_is_refused() raises:
    # Nine bytes of all-ones payload then a 1 in bit 63: the value is negative
    # as an Int, and a caller advancing `pos` by it would walk backward.
    var data = List[UInt8](length=9, fill=0xFF)
    data.append(0x01)
    var r = ThriftCompactReader(_view(Span(data)))
    var raised = False
    try:
        _ = r._read_varint()
    except e:
        raised = String(e).find("does not fit") >= 0
    assert_true(raised)


def test_a_varint_cut_by_the_end_of_the_view_raises() raises:
    var data: List[UInt8] = [0x80, 0x80]
    var r = ThriftCompactReader(_view(Span(data)))
    var raised = False
    try:
        _ = r._read_varint()
    except:
        raised = True
    assert_true(raised)


def test_field_headers_short_long_and_stop() raises:
    var data = List[UInt8]()
    _fh(data, 1, 5)  # field 1, i32
    _fh(data, 3, 8)  # field 4, binary
    data.append(0x06)  # long form: type 6 (i64) ...
    _zz(data, 300)  # ... field id 300
    data.append(0x00)  # STOP
    var r = ThriftCompactReader(_view(Span(data)))
    var f = r._read_field_header()
    assert_equal(f[0], 1)
    assert_equal(f[1], 5)
    f = r._read_field_header()
    assert_equal(f[0], 4)
    assert_equal(f[1], 8)
    f = r._read_field_header()
    assert_equal(f[0], 300)
    assert_equal(f[1], 6)
    f = r._read_field_header()
    assert_equal(f[0], 0)
    assert_equal(f[1], 0)
    assert_equal(r.prev_field_id, 300)


# ---- binary, list size, advance ----------------------------------------------


def test_read_binary_to_list_copies_and_advances() raises:
    var data: List[UInt8] = [9, 1, 2, 3, 4]
    var r = ThriftCompactReader(_view(Span(data)))
    r.pos = 1
    var empty = r._read_binary_to_list(0)
    assert_equal(len(empty), 0)
    assert_equal(r.pos, 1)
    var got = r._read_binary_to_list(3)
    assert_equal(len(got), 3)
    assert_equal(got[0], 1)
    assert_equal(got[2], 3)
    assert_equal(r.pos, 4)


def test_read_binary_to_list_refuses_negative_short_and_wrapping_lengths() raises:
    var data: List[UInt8] = [1, 2, 3, 4]
    var r = ThriftCompactReader(_view(Span(data)))
    r.pos = 2
    # -1, one past the end, and a length whose sum with `pos` wraps Int:
    # the last allocated 2^63 bytes and copied past the view before the
    # check compared `length` with the bytes that remain.
    var lengths: List[Int] = [-1, 3, Int.MAX - 1]
    for i in range(len(lengths)):
        var raised = False
        try:
            _ = r._read_binary_to_list(lengths[i])
        except e:
            raised = String(e).find("binary read past end") >= 0
        assert_true(raised, "length " + String(lengths[i]))
        assert_equal(r.pos, 2)


def test_checked_list_size_bounds_the_count_by_the_bytes_left() raises:
    var data = List[UInt8](length=10, fill=0)
    var r = ThriftCompactReader(_view(Span(data)))
    r.pos = 4
    assert_equal(r._checked_list_size(6), 6)
    assert_equal(r._checked_list_size(0), 0)
    var over = False
    try:
        _ = r._checked_list_size(7)
    except e:
        over = String(e).find("list declares 7") >= 0
    assert_true(over)
    var negative = False
    try:
        _ = r._checked_list_size(-1)
    except:
        negative = True
    assert_true(negative)


def test_advance_stays_inside_the_view() raises:
    var data = List[UInt8](length=4, fill=0)
    var r = ThriftCompactReader(_view(Span(data)))
    r._advance(4)
    assert_equal(r.pos, 4)
    var past = False
    try:
        r._advance(1)
    except e:
        past = String(e).find("runs past the end") >= 0
    assert_true(past)
    var back = False
    try:
        r._advance(-1)
    except:
        back = True
    assert_true(back)
    assert_equal(r.pos, 4)


# ---- _skip_field, every wire type ---------------------------------------------


def test_skip_field_consumes_each_scalar_type_exactly() raises:
    # bool true / false: nothing.
    var none: List[UInt8] = [0xAA]
    var r = ThriftCompactReader(_view(Span(none)))
    r._skip_field(1)
    r._skip_field(2)
    assert_equal(r.pos, 0)
    # i8: one byte; i16/i32/i64: a varint; double: eight bytes.
    var data: List[UInt8] = [0x7F, 0x80, 0x01, 0x05, 0x96, 0x01]
    for _ in range(8):
        data.append(0x11)
    data.append(0xEE)
    var r1 = ThriftCompactReader(_view(Span(data)))
    r1._skip_field(3)
    assert_equal(r1.pos, 1)
    r1._skip_field(4)
    assert_equal(r1.pos, 3)
    r1._skip_field(5)
    assert_equal(r1.pos, 4)
    r1._skip_field(6)
    assert_equal(r1.pos, 6)
    r1._skip_field(7)
    assert_equal(r1.pos, 14)


def test_skip_field_binary_and_its_refusals() raises:
    var data: List[UInt8] = [3, 0x61, 0x62, 0x63, 0xFF]
    var r = ThriftCompactReader(_view(Span(data)))
    r._skip_field(8)
    assert_equal(r.pos, 4)
    var short: List[UInt8] = [5, 0x61]
    assert_true(_raises_with(short, 8, "runs past the end"))
    var i8_at_end = List[UInt8]()
    assert_true(_raises_with(i8_at_end, 3, "runs past the end"))
    var short_double: List[UInt8] = [1, 2, 3]
    assert_true(_raises_with(short_double, 7, "runs past the end"))


def test_skip_field_lists_and_sets() raises:
    # list<i32> of 3: header 0x35, then three varints.
    var data: List[UInt8] = [0x35, 0x02, 0x04, 0x06, 0xEE]
    var r = ThriftCompactReader(_view(Span(data)))
    r._skip_field(9)
    assert_equal(r.pos, 4)
    # set<binary> of 2, the long size form (nibble 15, then a varint).
    var long_form: List[UInt8] = [0xF8, 0x02, 0x01, 0x61, 0x00, 0xEE]
    var r2 = ThriftCompactReader(_view(Span(long_form)))
    r2._skip_field(10)
    assert_equal(r2.pos, 5)
    # list<bool> of 2^40 (long form): bools take no bytes, so the elements are
    # skipped without a loop and without reading past the header.
    var bools: List[UInt8] = [0xF1]
    _uleb(bools, 1 << 40)
    var r3 = ThriftCompactReader(_view(Span(bools)))
    r3._skip_field(9)
    assert_equal(r3.pos, len(bools))
    # list<bool> with the false type nibble, too.
    var falses: List[UInt8] = [0x52]
    var r4 = ThriftCompactReader(_view(Span(falses)))
    r4._skip_field(9)
    assert_equal(r4.pos, 1)
    # A count the remaining bytes cannot hold is refused up front.
    var too_many: List[UInt8] = [0x55, 0x01]
    assert_true(_raises_with(too_many, 9, "list/set declares 5"))


def test_skip_field_maps() raises:
    # An empty map is a single zero varint: no types byte follows.
    var empty: List[UInt8] = [0x00, 0xEE]
    var r = ThriftCompactReader(_view(Span(empty)))
    r._skip_field(11)
    assert_equal(r.pos, 1)
    # map<i32, binary> of 2.
    var data: List[UInt8] = [0x02, 0x58, 0x02, 0x01, 0x61, 0x04, 0x00, 0xEE]
    var r5 = ThriftCompactReader(_view(Span(data)))
    r5._skip_field(11)
    assert_equal(r5.pos, 7)
    # map<bool, bool> of 2^40: bool entries take no bytes, so the count is
    # bounded by the bytes left, with no exception for bools.
    var bools: List[UInt8] = []
    _uleb(bools, 1 << 40)
    bools.append(0x11)
    assert_true(_raises_with(bools, 11, "map declares"))


def test_skip_field_struct_and_unknown_type() raises:
    # A struct with an i32 field 1 and a binary field 2, then STOP.
    var data: List[UInt8] = [0x15, 0x02, 0x18, 0x01, 0x61, 0x00, 0xEE]
    var r = ThriftCompactReader(_view(Span(data)))
    r.prev_field_id = 7
    r._skip_field(12)
    assert_equal(r.pos, 6)
    # The enclosing struct's field id is restored after the nested one.
    assert_equal(r.prev_field_id, 7)
    var any: List[UInt8] = [0x00]
    assert_true(_raises_with(any, 13, "unknown wire type 13"))
    assert_true(_raises_with(any, 0, "unknown wire type 0"))


def test_nesting_past_the_cap_is_refused_for_structs() raises:
    # Each 0x1C opens a struct field (field 1, type 12) inside the last.
    var data = List[UInt8](length=200, fill=0x1C)
    assert_true(_raises_with(data, 12, "nesting depth exceeds 64"))


def test_nesting_past_the_cap_is_refused_for_lists_and_maps() raises:
    # Each 0x19 is a list of one element whose type is list: nested lists
    # never pass through `_skip_struct`, so before the cap was checked in
    # `_skip_field` a long run of these recursed once per byte (a footer of a
    # few MB overflows the stack).
    var lists = List[UInt8](length=200, fill=0x19)
    assert_true(_raises_with(lists, 9, "nesting depth exceeds 64"))
    # A map of one entry whose key type is map, repeated.
    var maps = List[UInt8]()
    for _ in range(200):
        maps.append(0x01)
        maps.append(0xBB)
    assert_true(_raises_with(maps, 11, "nesting depth exceeds 64"))
    # 64 levels are allowed: a list of lists nested to depth 64, ending in an
    # empty list.
    var ok = List[UInt8](length=64, fill=0x19)
    ok.append(0x05)
    var r = ThriftCompactReader(_view(Span(ok)))
    r._skip_field(9)
    assert_equal(r.pos, 65)


def test_skip_struct_reads_at_most_10000_fields() raises:
    # 10001 bool fields: the skip stops after 10000 of them, leaving the
    # reader at the last one rather than walking on.
    var data = List[UInt8](length=10001, fill=0x11)
    data.append(0x00)
    var r = ThriftCompactReader(_view(Span(data)))
    r._skip_struct()
    assert_equal(r.pos, 10000)
    var deep = False
    try:
        r._skip_struct(65)
    except e:
        deep = String(e).find("malformed struct") >= 0
    assert_true(deep)


# ---- parse_metadata_summary ----------------------------------------------------


def _summary_footer(created_by: String) -> List[UInt8]:
    var out = List[UInt8]()
    _fh(out, 1, 5)  # version
    _zz(out, 2)
    _fh(out, 1, 9)  # schema: list<struct> of 2
    out.append(0x2C)
    out.append(0x00)  # an empty SchemaElement
    out.append(0x00)
    _fh(out, 1, 6)  # num_rows
    _zz(out, 1234)
    _fh(out, 1, 9)  # row_groups: list<struct>, long form, 1 element
    out.append(0xFC)
    _uleb(out, 1)
    out.append(0x00)
    _fh(out, 1, 9)  # field 5, key_value_metadata: skipped
    out.append(0x08)
    _fh(out, 1, 8)  # created_by
    _uleb(out, created_by.byte_length())
    for b in created_by.as_bytes():
        out.append(b)
    _fh(out, 1, 5)  # field 7: an i32 nobody asked for, skipped
    _zz(out, 9)
    out.append(0x00)  # STOP
    out.append(0x77)  # trailing byte after STOP: not read
    return out^


def test_summary_reads_the_top_level_fields() raises:
    var footer = _summary_footer("komira test writer")
    var s = parse_metadata_summary(_view(Span(footer)))
    assert_equal(s.version, 2)
    assert_equal(s.num_schema_elements, 2)
    assert_equal(s.num_rows, 1234)
    assert_equal(s.num_row_groups, 1)
    assert_equal(s.created_by, "komira test writer")
    var copy = s.copy()
    assert_equal(copy.num_rows, 1234)


def test_summary_schema_as_a_struct_and_an_empty_created_by() raises:
    var out = List[UInt8]()
    _fh(out, 2, 12)  # field 2 sent as a struct: skipped, no count
    out.append(0x15)
    _zz(out, 3)
    out.append(0x00)
    _fh(out, 4, 8)  # created_by, empty
    _uleb(out, 0)
    var s = parse_metadata_summary(_view(Span(out)))
    assert_equal(s.num_schema_elements, 0)
    assert_equal(s.created_by, "")
    var default = ParquetMetadataSummary()
    assert_equal(default.version, 0)


def test_summary_created_by_longer_than_the_footer_stops_the_walk() raises:
    var out = List[UInt8]()
    _fh(out, 6, 8)
    _uleb(out, 50)
    out.append(0x61)
    var s = parse_metadata_summary(_view(Span(out)))
    assert_equal(s.created_by, "")


def test_summary_refuses_a_list_count_the_bytes_cannot_hold() raises:
    # schema declared as 1000 bools: bools take no bytes, so without the
    # bound the walk ran 1000 no-op skips and reported 1000 elements (and a
    # varint count of 2^40 hung it).
    var schema = List[UInt8]()
    _fh(schema, 2, 9)
    schema.append(0xF1)
    _uleb(schema, 1000)
    var raised = False
    try:
        _ = parse_metadata_summary(_view(Span(schema)))
    except e:
        raised = String(e).find("list declares 1000") >= 0
    assert_true(raised)
    var groups = List[UInt8]()
    _fh(groups, 4, 9)
    groups.append(0xF2)
    _uleb(groups, 1000)
    raised = False
    try:
        _ = parse_metadata_summary(_view(Span(groups)))
    except e:
        raised = String(e).find("list declares 1000") >= 0
    assert_true(raised)


def test_summary_created_by_length_near_int_max_stops_the_walk() raises:
    # A length of Int.MAX - 1 wrapped `pos + len` negative and passed the
    # bound, and the copy's allocation aborted the process. Now the string is
    # left empty and `pos` stops at the end of the bytes.
    var out = List[UInt8]()
    _fh(out, 6, 8)
    _uleb(out, Int.MAX - 1)
    for _ in range(4):
        out.append(0x00)
    var s = parse_metadata_summary(_view(Span(out)))
    assert_equal(s.created_by, "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
