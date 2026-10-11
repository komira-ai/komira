# The Thrift compact serializer (`thrift_writer`) against parquet.thrift.
#
# The bytes are read back by a compact-protocol walker written here from the
# protocol's rules (field header = delta << 4 | type, or type then a zigzag
# id; varints; list header = count << 4 | element type), not by the
# writer's own code and not by the package's reader.
#
# What each test proves, and the defect it catches:
#   * zigzag / varint / long-form field header: the protocol primitives
#     (a field id delta over 15 written short corrupts every later field).
#   * test_statistics_bytes: the Statistics struct byte for byte. Field 9 is
#     nan_count as an i64, and the HLL registers are NOT in Statistics (the
#     predecessor wrote them as a binary field 9, which parquet.thrift
#     reads as `nan_count`). Red if field 9 is binary or carries registers.
#   * test_hll_registers_travel_in_column_key_values: the registers are
#     ColumnMetaData field 8, under HLL_REGISTERS_KEY, encoded exactly as
#     hll_registers_to_key_value encodes them; the chunk's own pairs come
#     first; a stale HLL pair already in the metadata (a footer read back)
#     is dropped, so the key appears once.
#   * a chunk without pairs or registers writes no field 8.
#   * page index locations: offset_index_* are fields 4/5 and
#     column_index_* are 6/7 (swapping them is a file only its own reader
#     opens).
#   * footer: column_orders (field 7) has one TypeDefinedOrder per leaf, not
#     per schema element; the key-value list is field 5.
#   * page headers: the CRC is field 4, and a V2 header's is_compressed is
#     written only when false.
#   * malformed registers (not 4096) raise instead of writing a footer.
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_parquet_api.hll_footer import HLL_REGISTERS_KEY, hll_registers_to_key_value
from komira_parquet_api.metadata import (
    ColumnChunk,
    ColumnMetaData,
    FileMetaData,
    KeyValue,
    RowGroup,
    SchemaElement,
    Statistics,
)
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_parquet_writer.thrift_writer import (
    ThriftCompactWriter,
    serialize_file_metadata,
)


# --- a compact-protocol walker ----------------------------------------------


@fieldwise_init
struct Fields(Movable):
    var ids: List[Int]
    var types: List[Int]
    var starts: List[Int]
    var end: Int

    def at(self, id: Int) raises -> Int:
        """Index of field `id`; raises if absent."""
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return i
        raise Error("field " + String(id) + " is absent")

    def has(self, id: Int) -> Bool:
        for i in range(len(self.ids)):
            if self.ids[i] == id:
                return True
        return False


def _varint(b: List[UInt8], mut pos: Int) raises -> Int:
    var shift = 0
    var v = 0
    while True:
        var x = Int(b[pos])
        pos += 1
        v |= (x & 0x7F) << shift
        if x & 0x80 == 0:
            break
        shift += 7
    return v


def _unzig(v: Int) -> Int:
    return (v >> 1) ^ -(v & 1)


def _skip(b: List[UInt8], mut pos: Int, t: Int) raises:
    if t == 1 or t == 2:
        return
    if t == 3:
        pos += 1
        return
    if t == 4 or t == 5 or t == 6:
        _ = _varint(b, pos)
        return
    if t == 8:
        var n = _varint(b, pos)
        pos += n
        return
    if t == 9:
        var h = Int(b[pos])
        pos += 1
        var n = h >> 4
        if n == 15:
            n = _varint(b, pos)
        var et = h & 0xF
        for _ in range(n):
            if et == 1 or et == 2:
                pos += 1
            else:
                _skip(b, pos, et)
        return
    if t == 12:
        var f = _fields(b, pos)
        pos = f.end
        return
    raise Error("unknown compact type " + String(t))


def _fields(b: List[UInt8], start: Int) raises -> Fields:
    """The fields of the struct starting at `start`, up to its STOP."""
    var ids = List[Int]()
    var types = List[Int]()
    var starts = List[Int]()
    var pos = start
    var last = 0
    while True:
        var h = Int(b[pos])
        pos += 1
        if h == 0:
            break
        var t = h & 0xF
        var d = h >> 4
        var id: Int
        if d == 0:
            id = _unzig(_varint(b, pos))
        else:
            id = last + d
        last = id
        ids.append(id)
        types.append(t)
        starts.append(pos)
        _skip(b, pos, t)
    return Fields(ids^, types^, starts^, pos)


def _int_at(b: List[UInt8], pos: Int) raises -> Int:
    var p = pos
    return _unzig(_varint(b, p))


def _string_at(b: List[UInt8], pos: Int) raises -> String:
    var p = pos
    var n = _varint(b, p)
    var s = String()
    for i in range(n):
        s += chr(Int(b[p + i]))
    return s^


# --- fixtures ---------------------------------------------------------------


def _registers(value: UInt8) -> List[UInt8]:
    var r = List[UInt8]()
    for _ in range(4096):
        r.append(value)
    return r^


def _meta(
    var stats: Optional[Statistics], var kvs: Optional[List[KeyValue]]
) -> ColumnMetaData:
    var enc: List[Encoding] = [Encoding.PLAIN]
    var path: List[String] = ["c"]
    return ColumnMetaData(
        type=ParquetType.INT64,
        encodings=enc^,
        path_in_schema=path^,
        codec=CompressionCodec.UNCOMPRESSED,
        num_values=3,
        total_uncompressed_size=30,
        total_compressed_size=30,
        data_page_offset=4,
        statistics=stats^,
        key_value_metadata=kvs^,
    )


# --- primitives -------------------------------------------------------------


def test_zigzag_and_varint() raises:
    assert_equal(ThriftCompactWriter.zigzag_i32(0), 0)
    assert_equal(ThriftCompactWriter.zigzag_i32(-1), 1)
    assert_equal(ThriftCompactWriter.zigzag_i32(1), 2)
    assert_equal(ThriftCompactWriter.zigzag_i32(-2147483648), 4294967295)
    assert_equal(ThriftCompactWriter.zigzag_i64(-1), 1)
    assert_equal(ThriftCompactWriter.zigzag_i64(2), 4)
    var w = ThriftCompactWriter()
    w.write_varint(300)
    var b = w.take_bytes()
    assert_equal(len(b), 2)
    assert_equal(Int(b[0]), 0xAC)
    assert_equal(Int(b[1]), 0x02)


def test_long_form_field_header() raises:
    var w = ThriftCompactWriter()
    w.push_struct()
    w.write_i32_field(1, 7)
    w.write_i32_field(20, 7)  # delta 19 > 15: type byte, then zigzag id
    w.pop_struct()
    var b = w.take_bytes()
    assert_equal(Int(b[0]), 0x15)
    assert_equal(Int(b[2]), 0x05)
    assert_equal(Int(b[3]), 40)
    var f = _fields(b, 0)
    assert_equal(f.ids[1], 20)
    assert_equal(_int_at(b, f.starts[1]), 7)


# --- statistics and the HLL registers --------------------------------------


def test_statistics_bytes() raises:
    var stats = Statistics(
        null_count=2,
        min_value=List[UInt8](length=1, fill=1),
        max_value=List[UInt8](length=1, fill=9),
        hll_registers=_registers(3),
        nan_count=0,
    )
    var w = ThriftCompactWriter()
    w.push_struct()
    w.write_statistics(stats)
    w.pop_struct()
    var got = w.take_bytes()
    var want: List[UInt8] = [
        0xCC,  # field 12, struct
        0x36, 0x04,  # 3: i64 null_count = 2
        0x28, 0x01, 0x09,  # 5: binary max_value
        0x18, 0x01, 0x01,  # 6: binary min_value
        0x11,  # 7: bool true
        0x11,  # 8: bool true
        0x16, 0x00,  # 9: i64 nan_count = 0
        0x00,  # Statistics STOP
        0x00,  # outer STOP
    ]
    assert_equal(len(got), len(want), "no 4 KiB of registers in Statistics")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), "byte " + String(i))


def test_statistics_without_nan_count_has_no_field_9() raises:
    var w = ThriftCompactWriter()
    w.push_struct()
    w.write_statistics(Statistics(null_count=0))
    w.pop_struct()
    var b = w.take_bytes()
    var outer = _fields(b, 0)
    var inner = _fields(b, outer.starts[outer.at(12)])
    assert_false(inner.has(9))


def test_hll_registers_travel_in_column_key_values() raises:
    var kvs = List[KeyValue]()
    kvs.append(KeyValue(String("a"), String("b")))
    kvs.append(KeyValue(String(HLL_REGISTERS_KEY), String("stale")))
    var stats = Statistics(null_count=0, hll_registers=_registers(3))
    var chunk = ColumnChunk(file_offset=4, meta_data=_meta(stats^, kvs^))
    var w = ThriftCompactWriter()
    w.write_column_chunk(chunk)
    var b = w.take_bytes()

    var cc = _fields(b, 0)
    var md = _fields(b, cc.starts[cc.at(3)])
    var i8 = md.at(8)
    assert_equal(md.types[i8], 9, "field 8 is a list")
    var p = md.starts[i8]
    var h = Int(b[p])
    assert_equal(h >> 4, 2, "two pairs: the chunk's own and the registers")
    assert_equal(h & 0xF, 12)
    var first = _fields(b, p + 1)
    assert_equal(_string_at(b, first.starts[first.at(1)]), "a")
    assert_equal(_string_at(b, first.starts[first.at(2)]), "b")
    var second = _fields(b, first.end)
    assert_equal(_string_at(b, second.starts[second.at(1)]), String(HLL_REGISTERS_KEY))
    var want = hll_registers_to_key_value(Span(_registers(3)))
    assert_equal(_string_at(b, second.starts[second.at(2)]), want.value.value())
    # The Statistics struct carries no registers and no binary field 9.
    var st = _fields(b, md.starts[md.at(12)])
    for i in range(len(st.ids)):
        assert_false(st.ids[i] == 9 and st.types[i] == 8)
    # Field order: 7 < 8 < 9 inside ColumnMetaData.
    assert_true(md.at(7) < md.at(8) and md.at(8) < md.at(9))


def test_no_pairs_no_field_8() raises:
    var chunk = ColumnChunk(
        file_offset=4, meta_data=_meta(Statistics(null_count=0), None)
    )
    var w = ThriftCompactWriter()
    w.write_column_chunk(chunk)
    var b = w.take_bytes()
    var cc = _fields(b, 0)
    var md = _fields(b, cc.starts[cc.at(3)])
    assert_false(md.has(8))
    assert_equal(md.ids[0], 1)


def test_malformed_registers_raise() raises:
    var stats = Statistics(null_count=0, hll_registers=List[UInt8](length=10, fill=0))
    var chunk = ColumnChunk(file_offset=4, meta_data=_meta(stats^, None))
    var w = ThriftCompactWriter()
    with assert_raises(contains="4096"):
        w.write_column_chunk(chunk)


# --- page index locations and the footer ------------------------------------


def test_page_index_field_ids() raises:
    var chunk = ColumnChunk(
        file_offset=4,
        meta_data=_meta(None, None),
        column_index_offset=200,
        column_index_length=20,
        offset_index_offset=100,
        offset_index_length=10,
    )
    var w = ThriftCompactWriter()
    w.write_column_chunk(chunk)
    var b = w.take_bytes()
    var cc = _fields(b, 0)
    assert_equal(_int_at(b, cc.starts[cc.at(4)]), 100, "4: offset_index_offset")
    assert_equal(_int_at(b, cc.starts[cc.at(5)]), 10, "5: offset_index_length")
    assert_equal(_int_at(b, cc.starts[cc.at(6)]), 200, "6: column_index_offset")
    assert_equal(_int_at(b, cc.starts[cc.at(7)]), 20, "7: column_index_length")
    assert_equal(cc.types[cc.at(5)], 5, "lengths are i32")
    assert_equal(cc.types[cc.at(4)], 6, "offsets are i64")


def test_footer_column_orders_one_per_leaf() raises:
    var schema = List[SchemaElement]()
    schema.append(SchemaElement(name="schema", num_children=2))
    schema.append(SchemaElement(name="x", type=ParquetType.INT64))
    schema.append(SchemaElement(name="y", type=ParquetType.DOUBLE))
    var kvs = List[KeyValue]()
    kvs.append(KeyValue(String("k"), String("v")))
    var cols = List[ColumnChunk]()
    cols.append(ColumnChunk(file_offset=4, meta_data=_meta(None, None)))
    var rgs = List[RowGroup]()
    rgs.append(RowGroup(columns=cols^, total_byte_size=30, num_rows=3))
    var footer = FileMetaData(
        version=2, schema=schema^, num_rows=3, row_groups=rgs^,
        key_value_metadata=kvs^, created_by=String("w"),
    )
    var b = serialize_file_metadata(footer)
    var f = _fields(b, 0)
    assert_equal(f.end, len(b))
    assert_equal(_int_at(b, f.starts[f.at(1)]), 2)
    assert_equal(_int_at(b, f.starts[f.at(3)]), 3)
    assert_equal(Int(b[f.starts[f.at(5)]]) >> 4, 1, "one key-value pair")
    assert_equal(_string_at(b, f.starts[f.at(6)]), "w")
    var p7 = f.starts[f.at(7)]
    assert_equal(Int(b[p7]) >> 4, 2, "one column order per LEAF (2), not per element (3)")
    assert_equal(Int(b[p7]) & 0xF, 12)
    var order = _fields(b, p7 + 1)
    assert_equal(order.ids[0], 1, "TYPE_ORDER")


def test_data_page_headers() raises:
    var w = ThriftCompactWriter()
    w.write_data_page_header(100, 60, 10, Encoding.PLAIN, UInt32(0xDEADBEEF))
    var b = w.take_bytes()
    var f = _fields(b, 0)
    assert_equal(_int_at(b, f.starts[f.at(1)]), 0, "DATA_PAGE")
    assert_equal(_int_at(b, f.starts[f.at(2)]), 100)
    assert_equal(_int_at(b, f.starts[f.at(3)]), 60)
    # The CRC is an i32: its bits are the UInt32's.
    assert_equal(UInt32(_int_at(b, f.starts[f.at(4)]) & 0xFFFFFFFF), UInt32(0xDEADBEEF))
    var dp = _fields(b, f.starts[f.at(5)])
    assert_equal(_int_at(b, dp.starts[dp.at(1)]), 10)

    var w2 = ThriftCompactWriter()
    w2.write_data_page_v2_header(100, 60, 10, 2, 10, Encoding.PLAIN, 4, 0, False)
    var b2 = w2.take_bytes()
    var g = _fields(b2, 0)
    assert_false(g.has(4), "no CRC given, none written")
    var v2 = _fields(b2, g.starts[g.at(8)])
    assert_equal(_int_at(b2, v2.starts[v2.at(2)]), 2, "num_nulls")
    assert_equal(v2.types[v2.at(7)], 2, "is_compressed written as false")
    var w3 = ThriftCompactWriter()
    w3.write_data_page_v2_header(100, 60, 10, 2, 10, Encoding.PLAIN, 4, 0)
    var b3 = w3.take_bytes()
    var g3 = _fields(b3, 0)
    var v3 = _fields(b3, g3.starts[g3.at(8)])
    assert_false(v3.has(7), "is_compressed defaults to true and is omitted")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
