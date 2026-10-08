# =============================================================================
# parse_full_metadata and the struct parsers under it.
#
# Footers are written here with a small Thrift Compact writer built from the
# protocol's definition and parquet.thrift's field ids. Each struct parser is
# also driven directly, so every field it reads, every field it skips, a
# field id sent with the wrong wire type, and a struct cut off by the end of
# the bytes (the loop ends without a STOP) each run.
#
# The defects these tests hold fixed:
#   * a LogicalType JSON or BSON member backfilled ConvertedType 24 / 25;
#     parquet.thrift's values are 19 / 20, so a JSON column with only the
#     modern annotation was not taken as text;
#   * Statistics field 9 is the spec's i64 `nan_count`; a binary field 9 was
#     read as HLL registers. The registers come from the chunk's key-value
#     metadata (ColumnMetaData field 8) under `hll_footer.HLL_REGISTERS_KEY`;
#   * each string field (created_by, KeyValue key and value, SchemaElement
#     name, a path_in_schema segment) checked its length as
#     `pos + len <= data_len`; a length near Int.MAX wrapped that sum
#     negative, passed, and the copy's allocation aborted the process.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_buffer.byte_view import ByteView
from komira_parquet_api.hll_footer import HLL_REGISTERS_KEY, hll_registers_to_key_value
from komira_parquet_api.types import CONVERTED_TYPE_BSON, CONVERTED_TYPE_ENUM
from komira_parquet_api.types import CONVERTED_TYPE_JSON, CONVERTED_TYPE_UTF8
from komira_parquet.thrift_compact import ThriftCompactReader
from komira_parquet.metadata_parser import (
    _parse_column_chunk,
    _parse_column_metadata,
    _parse_key_value,
    _parse_logical_type,
    _parse_row_group,
    _parse_schema_element,
    _parse_statistics,
    _parse_time_unit,
    _parse_timestamp_logical,
    parse_full_metadata,
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


struct _W(Movable):
    """A Thrift Compact writer: field ids are tracked per open struct."""

    var out: List[UInt8]
    var prev: List[Int]

    def __init__(out self):
        self.out = List[UInt8]()
        self.prev = [0]

    def field(mut self, id: Int, t: Int):
        var d = id - self.prev[len(self.prev) - 1]
        if d > 0 and d <= 15:
            self.out.append(UInt8((d << 4) | t))
        else:
            self.out.append(UInt8(t))
            _uleb(self.out, (id << 1) ^ (id >> 63))
        self.prev[len(self.prev) - 1] = id

    def zz(mut self, v: Int):
        _uleb(self.out, (v << 1) ^ (v >> 63))

    def i32(mut self, id: Int, v: Int):
        self.field(id, 5)
        self.zz(v)

    def i64(mut self, id: Int, v: Int):
        self.field(id, 6)
        self.zz(v)

    def text(mut self, id: Int, s: String):
        self.field(id, 8)
        _uleb(self.out, s.byte_length())
        for b in s.as_bytes():
            self.out.append(b)

    def flag(mut self, id: Int, v: Bool):
        self.field(id, 1 if v else 2)

    def begin(mut self, id: Int):
        """A struct-typed field `id`; its fields follow."""
        self.field(id, 12)
        self.prev.append(0)

    def end(mut self):
        """STOP of the innermost open struct."""
        self.out.append(0)
        _ = self.prev.pop()

    def list(mut self, id: Int, size: Int, elem: Int):
        self.field(id, 9)
        self.list_header(size, elem)

    def list_header(mut self, size: Int, elem: Int):
        if size < 15:
            self.out.append(UInt8((size << 4) | elem))
        else:
            self.out.append(UInt8(0xF0 | elem))
            _uleb(self.out, size)

    def elem(mut self):
        """A struct element of a list; its fields follow."""
        self.prev.append(0)

    def stop(mut self):
        self.out.append(0)


def _raises(data: List[UInt8], needle: String) -> Bool:
    try:
        _ = parse_full_metadata(_view(Span(data)))
    except e:
        return String(e).find(needle) >= 0
    return False


# ---- the small union / struct parsers ------------------------------------------


def test_time_unit_members_unknown_and_truncated() raises:
    for unit in range(1, 4):
        var w = _W()
        w.begin(unit)
        w.end()
        w.stop()
        var r = ThriftCompactReader(_view(Span(w.out)))
        r.prev_field_id = 9
        assert_equal(_parse_time_unit(r), unit)
        assert_equal(r.prev_field_id, 9)
    var w = _W()
    w.begin(4)  # not a TimeUnit member
    w.end()
    w.stop()
    var r = ThriftCompactReader(_view(Span(w.out)))
    assert_equal(_parse_time_unit(r), 0)
    var cut: List[UInt8] = []  # no STOP: the loop ends with the bytes
    var r2 = ThriftCompactReader(_view(Span(cut)))
    assert_equal(_parse_time_unit(r2), 0)


def test_timestamp_logical_fields() raises:
    var w = _W()
    w.flag(1, True)
    w.begin(2)
    w.begin(3)  # NANOS
    w.end()
    w.end()
    w.i32(3, 7)  # unknown field, skipped
    w.stop()
    var r = ThriftCompactReader(_view(Span(w.out)))
    var ts = _parse_timestamp_logical(r)
    assert_equal(ts[0], 3)
    assert_true(ts[1])
    var w2 = _W()
    w2.flag(1, False)
    w2.i32(2, 1)  # field 2 with a non-struct type: skipped
    var r2 = ThriftCompactReader(_view(Span(w2.out)))  # no STOP
    var ts2 = _parse_timestamp_logical(r2)
    assert_equal(ts2[0], 0)
    assert_false(ts2[1])
    var w3 = _W()
    w3.i32(1, 1)  # field 1 not a bool: skipped
    w3.stop()
    var r3 = ThriftCompactReader(_view(Span(w3.out)))
    assert_false(_parse_timestamp_logical(r3)[1])


def _logical(member: Int) -> Tuple[Int, Bool, Int]:
    var w = _W()
    w.begin(member)
    w.end()
    w.stop()
    var r = ThriftCompactReader(_view(Span(w.out)))
    try:
        return _parse_logical_type(r)
    except:
        return (-9, False, -9)


def test_logical_type_text_members_use_the_spec_converted_values() raises:
    assert_equal(_logical(1)[2], CONVERTED_TYPE_UTF8)
    assert_equal(_logical(4)[2], CONVERTED_TYPE_ENUM)
    # JSON and BSON are ConvertedType 19 and 20 in parquet.thrift.
    assert_equal(_logical(12)[2], CONVERTED_TYPE_JSON)
    assert_equal(_logical(13)[2], CONVERTED_TYPE_BSON)
    assert_equal(_logical(12)[2], 19)
    assert_equal(_logical(13)[2], 20)
    # A member that is not text (DATE, union field 6): no equivalent.
    assert_equal(_logical(6)[2], -1)


def test_logical_type_timestamp_and_wrong_wire_types() raises:
    var w = _W()
    w.begin(8)
    w.flag(1, True)
    w.begin(2)
    w.begin(1)  # MILLIS
    w.end()
    w.end()
    w.end()
    w.i32(12, 1)  # JSON's id with a non-struct type: skipped
    w.i32(13, 1)
    w.i32(4, 1)
    w.i32(1, 1)
    var r = ThriftCompactReader(_view(Span(w.out)))  # no STOP
    var lt = _parse_logical_type(r)
    assert_equal(lt[0], 1)
    assert_true(lt[1])
    assert_equal(lt[2], -1)
    var w2 = _W()
    w2.i32(8, 1)  # TIMESTAMP's id, not a struct
    w2.stop()
    var r2 = ThriftCompactReader(_view(Span(w2.out)))
    assert_equal(_parse_logical_type(r2)[0], 0)


def test_key_value_fields() raises:
    var w = _W()
    w.text(1, "k")
    w.text(2, "v")
    w.i32(3, 5)  # unknown, skipped
    w.stop()
    var r = ThriftCompactReader(_view(Span(w.out)))
    var kv = _parse_key_value(r)
    assert_equal(kv.key, "k")
    assert_equal(kv.value.value(), "v")
    # An empty value is present and empty; a key without a value has none.
    var w2 = _W()
    w2.text(1, "only")
    w2.text(2, "")
    w2.i32(1, 3)  # field 1 with a non-binary type: skipped
    var r2 = ThriftCompactReader(_view(Span(w2.out)))  # no STOP
    var kv2 = _parse_key_value(r2)
    assert_equal(kv2.key, "only")
    assert_equal(kv2.value.value(), "")
    var w3 = _W()
    w3.text(1, "solo")
    w3.stop()
    var r3 = ThriftCompactReader(_view(Span(w3.out)))
    assert_false(Bool(_parse_key_value(r3).value))
    # A length past the bytes: the text is left empty and the walk ends.
    var w4 = _W()
    w4.field(1, 8)
    _uleb(w4.out, 40)
    w4.out.append(0x61)
    var r4 = ThriftCompactReader(_view(Span(w4.out)))
    assert_equal(_parse_key_value(r4).key, "")


# ---- SchemaElement ----------------------------------------------------------------


def test_schema_element_every_field() raises:
    var w = _W()
    w.i32(1, 7)  # FIXED_LEN_BYTE_ARRAY
    w.i32(2, 16)
    w.i32(3, 1)  # OPTIONAL
    w.text(4, "price")
    w.i32(5, 0)
    w.i32(6, 5)  # DECIMAL
    w.i32(7, 2)
    w.i32(8, 30)
    w.i64(9, 11)  # field_id: skipped
    w.begin(10)
    w.begin(8)  # TIMESTAMP
    w.flag(1, False)
    w.begin(2)
    w.begin(2)  # MICROS
    w.end()
    w.end()
    w.end()
    w.end()
    w.stop()
    var r = ThriftCompactReader(_view(Span(w.out)))
    var e = _parse_schema_element(r)
    assert_equal(e.name, "price")
    assert_equal(Int(e.type.value().value), 7)
    assert_equal(e.type_length.value(), 16)
    assert_equal(Int(e.repetition_type.value().value), 1)
    assert_equal(e.num_children, 0)
    assert_equal(e.converted_type.value(), 5)
    assert_equal(e.scale.value(), 2)
    assert_equal(e.precision.value(), 30)
    assert_equal(e.logical_timestamp_unit.value(), 2)
    assert_false(e.logical_timestamp_is_utc.value())


def test_schema_element_text_backfill_never_overrides_field_6() raises:
    # JSON in the modern union only: backfilled to 19.
    var w = _W()
    w.text(4, "doc")
    w.begin(10)
    w.begin(12)
    w.end()
    w.end()
    w.stop()
    var r = ThriftCompactReader(_view(Span(w.out)))
    var e = _parse_schema_element(r)
    assert_equal(e.converted_type.value(), CONVERTED_TYPE_JSON)
    assert_false(Bool(e.logical_timestamp_unit))
    # Field 6 present (ENUM) and the union says STRING: field 6 is kept.
    var w2 = _W()
    w2.i32(6, 4)
    w2.begin(10)
    w2.begin(1)
    w2.end()
    w2.end()
    w2.stop()
    var r2 = ThriftCompactReader(_view(Span(w2.out)))
    assert_equal(_parse_schema_element(r2).converted_type.value(), 4)
    # A union with no text member and no timestamp changes nothing.
    var w3 = _W()
    w3.begin(10)
    w3.begin(6)
    w3.end()
    w3.end()
    w3.stop()
    var r3 = ThriftCompactReader(_view(Span(w3.out)))
    assert_false(Bool(_parse_schema_element(r3).converted_type))


def test_schema_element_wrong_types_long_name_and_no_stop() raises:
    var w = _W()
    w.i64(1, 1)  # each id with a type it does not have: skipped
    w.i64(2, 1)
    w.i64(3, 1)
    w.i32(4, 1)
    w.i64(5, 1)
    w.i64(6, 1)
    w.i64(7, 1)
    w.i64(8, 1)
    w.i32(10, 1)
    var r = ThriftCompactReader(_view(Span(w.out)))  # no STOP
    var e = _parse_schema_element(r)
    assert_false(Bool(e.type))
    assert_false(Bool(e.type_length))
    assert_false(Bool(e.repetition_type))
    assert_equal(e.name, "")
    assert_false(Bool(e.converted_type))
    assert_false(Bool(e.scale))
    assert_false(Bool(e.precision))
    var w2 = _W()
    w2.field(4, 8)
    _uleb(w2.out, 99)  # longer than the bytes: the name stays empty
    var r2 = ThriftCompactReader(_view(Span(w2.out)))
    assert_equal(_parse_schema_element(r2).name, "")


# ---- Statistics -------------------------------------------------------------------


def test_statistics_every_field_and_field_9_as_nan_count() raises:
    var w = _W()
    w.text(1, "zz")  # legacy max: skipped
    w.text(2, "aa")  # legacy min: skipped
    w.i64(3, 4)
    w.i64(4, 17)
    w.field(5, 8)
    _uleb(w.out, 1)
    w.out.append(9)
    w.field(6, 8)
    _uleb(w.out, 1)
    w.out.append(1)
    w.flag(7, False)
    w.flag(8, True)
    w.i64(9, 3)  # nan_count
    w.i32(10, 1)  # unknown: skipped
    w.stop()
    var r = ThriftCompactReader(_view(Span(w.out)))
    var s = _parse_statistics(r)
    assert_equal(s.null_count.value(), 4)
    assert_equal(s.distinct_count.value(), 17)
    assert_equal(s.max_value.value()[0], 9)
    assert_equal(s.min_value.value()[0], 1)
    assert_false(s.is_max_value_exact)
    assert_true(s.is_min_value_exact)
    assert_equal(s.nan_count.value(), 3)
    assert_false(Bool(s.hll_registers))


def test_statistics_binary_field_9_is_skipped_not_taken_as_registers() raises:
    var w = _W()
    w.field(9, 8)
    _uleb(w.out, 4096)
    for _ in range(4096):
        w.out.append(0x41)
    w.flag(7, True)
    w.flag(8, False)
    var r = ThriftCompactReader(_view(Span(w.out)))  # no STOP
    var s = _parse_statistics(r)
    assert_false(Bool(s.hll_registers))
    assert_false(Bool(s.nan_count))
    assert_true(s.is_max_value_exact)
    assert_false(s.is_min_value_exact)
    var w2 = _W()
    for id in range(1, 9):  # each id with a type it does not have
        w2.i32(id, 1)
    w2.stop()
    var r2 = ThriftCompactReader(_view(Span(w2.out)))
    var s2 = _parse_statistics(r2)
    assert_false(Bool(s2.null_count))
    assert_false(Bool(s2.min_value))
    assert_true(s2.is_min_value_exact)


# ---- ColumnMetaData ---------------------------------------------------------------


def _registers() -> List[UInt8]:
    var regs = List[UInt8](capacity=4096)
    for i in range(4096):
        regs.append(UInt8(i % 54))
    return regs^


def _column_metadata(
    mut w: _W, with_stats: Bool, kv_value: String, with_kv: Bool
) raises:
    w.i32(1, 2)  # INT64
    w.list(2, 3, 5)  # encodings
    w.zz(0)
    w.zz(3)
    w.zz(8)
    w.list(3, 2, 8)  # path_in_schema
    _uleb(w.out, 1)
    w.out.append(0x67)  # "g"
    _uleb(w.out, 3)
    for b in String("col").as_bytes():
        w.out.append(b)
    w.i32(4, 6)  # ZSTD
    w.i64(5, 100)
    w.i64(6, 800)
    w.i64(7, 400)
    if with_kv:
        w.list(8, 2, 12)
        w.elem()
        w.text(1, "other")
        w.text(2, "x")
        w.end()
        w.elem()
        w.text(1, HLL_REGISTERS_KEY)
        w.text(2, kv_value)
        w.end()
    w.i64(9, 4)
    w.i64(10, 8)
    w.i64(11, 12)
    if with_stats:
        w.begin(12)
        w.i64(3, 0)
        w.end()
    w.i64(13, 1)  # encoding_stats id with a wrong type: skipped
    w.i64(14, 500)
    w.i32(15, 64)
    w.stop()


def _registers_text() raises -> String:
    var regs = _registers()
    var kv = hll_registers_to_key_value(Span(regs))
    return kv.value.value().copy()


def test_column_metadata_every_field_and_hll_registers() raises:
    var w = _W()
    _column_metadata(w, True, _registers_text(), True)
    var r = ThriftCompactReader(_view(Span(w.out)))
    var m = _parse_column_metadata(r)
    assert_equal(Int(m.type.value), 2)
    assert_equal(len(m.encodings), 3)
    assert_equal(Int(m.encodings[2].value), 8)
    assert_equal(len(m.path_in_schema), 2)
    assert_equal(m.path_in_schema[1], "col")
    assert_equal(Int(m.codec.value), 6)
    assert_equal(m.num_values, 100)
    assert_equal(m.total_uncompressed_size, 800)
    assert_equal(m.total_compressed_size, 400)
    assert_equal(m.data_page_offset, 4)
    assert_equal(m.index_page_offset.value(), 8)
    assert_equal(m.dictionary_page_offset.value(), 12)
    assert_equal(m.bloom_filter_offset.value(), 500)
    assert_equal(m.bloom_filter_length.value(), 64)
    assert_equal(len(m.key_value_metadata.value()), 2)
    var regs = m.statistics.value().hll_registers.value().copy()
    var want = _registers()
    assert_equal(len(regs), 4096)
    for i in range(4096):
        assert_equal(regs[i], want[i])


def test_damaged_registers_are_dropped_and_stats_or_kv_alone_are_kept() raises:
    var w = _W()
    _column_metadata(w, True, "not registers", True)
    var r = ThriftCompactReader(_view(Span(w.out)))
    var m = _parse_column_metadata(r)
    assert_false(Bool(m.statistics.value().hll_registers))
    assert_equal(len(m.key_value_metadata.value()), 2)
    var w2 = _W()
    _column_metadata(w2, False, _registers_text(), True)
    var r2 = ThriftCompactReader(_view(Span(w2.out)))
    var m2 = _parse_column_metadata(r2)
    assert_false(Bool(m2.statistics))
    assert_true(Bool(m2.key_value_metadata))
    var w3 = _W()
    _column_metadata(w3, True, "", False)
    var r3 = ThriftCompactReader(_view(Span(w3.out)))
    var m3 = _parse_column_metadata(r3)
    assert_false(Bool(m3.statistics.value().hll_registers))
    assert_false(Bool(m3.key_value_metadata))


def test_column_metadata_odd_lists_wrong_types_and_no_stop() raises:
    var w = _W()
    w.list(2, 1, 8)  # encodings of a non-i32 element type: skipped
    _uleb(w.out, 0)
    w.list(3, 2, 8)  # path segments: one empty, one past the bytes
    _uleb(w.out, 0)
    _uleb(w.out, 90)
    w.out.append(0x61)
    var r = ThriftCompactReader(_view(Span(w.out)))  # no STOP
    var m = _parse_column_metadata(r)
    assert_equal(len(m.encodings), 0)
    assert_equal(len(m.path_in_schema), 0)
    # Long-form (15 or more) encodings and path lists.
    var wl = _W()
    wl.list(2, 15, 5)
    for i in range(15):
        wl.zz(i % 10)
    wl.list(3, 15, 8)
    for _ in range(15):
        _uleb(wl.out, 1)
        wl.out.append(0x70)
    wl.stop()
    var rl = ThriftCompactReader(_view(Span(wl.out)))
    var ml = _parse_column_metadata(rl)
    assert_equal(len(ml.encodings), 15)
    assert_equal(Int(ml.encodings[14].value), 4)
    assert_equal(len(ml.path_in_schema), 15)
    assert_equal(ml.path_in_schema[14], "p")
    var w2 = _W()
    for id in range(1, 16):  # each id with a type it does not have
        w2.flag(id, True)
    w2.i64(15, 9)  # bloom_filter_length as an i64: accepted
    w2.list(16, 15, 8)  # long-form list for an unknown id: skipped
    for _ in range(15):
        _uleb(w2.out, 0)
    w2.stop()
    var r2 = ThriftCompactReader(_view(Span(w2.out)))
    var m2 = _parse_column_metadata(r2)
    assert_equal(m2.bloom_filter_length.value(), 9)
    assert_false(Bool(m2.bloom_filter_offset))
    assert_false(Bool(m2.statistics))
    var w3 = _W()
    w3.list(8, 20, 12)  # key-value list (long form) longer than the bytes
    var r3 = ThriftCompactReader(_view(Span(w3.out)))
    var raised = False
    try:
        _ = _parse_column_metadata(r3)
    except e:
        raised = String(e).find("list declares 20") >= 0
    assert_true(raised)


# ---- ColumnChunk and RowGroup -----------------------------------------------------


def test_column_chunk_fields_and_missing_meta_data() raises:
    var w = _W()
    w.text(1, "elsewhere.parquet")  # file_path: skipped
    w.i64(2, 4)
    w.begin(3)
    w.i32(1, 1)
    w.end()
    w.i64(4, 1000)
    w.i32(5, 40)
    w.i64(6, 2000)
    w.i64(7, 80)  # an i64 length is accepted too
    w.stop()
    var r = ThriftCompactReader(_view(Span(w.out)))
    var c = _parse_column_chunk(r)
    assert_equal(c.file_offset, 4)
    assert_equal(c.offset_index_offset.value(), 1000)
    assert_equal(c.offset_index_length.value(), 40)
    assert_equal(c.column_index_offset.value(), 2000)
    assert_equal(c.column_index_length.value(), 80)
    var w2 = _W()
    w2.i64(2, 4)
    w2.i64(5, 40)  # i64 offset_index_length
    w2.i32(7, 80)  # i32 column_index_length
    w2.begin(3)
    w2.end()
    var r2 = ThriftCompactReader(_view(Span(w2.out)))  # no STOP
    var c2 = _parse_column_chunk(r2)
    assert_equal(c2.offset_index_length.value(), 40)
    assert_equal(c2.column_index_length.value(), 80)
    var w3 = _W()
    for id in range(2, 8):  # each id with a type it does not have
        w3.flag(id, True)
    w3.stop()
    var r3 = ThriftCompactReader(_view(Span(w3.out)))
    var raised = False
    try:
        _ = _parse_column_chunk(r3)
    except e:
        raised = String(e).find("ColumnChunk missing meta_data") >= 0
    assert_true(raised)


def test_row_group_fields() raises:
    var w = _W()
    w.list(1, 2, 12)
    for _ in range(2):
        w.elem()
        w.begin(3)
        w.end()
        w.end()
    w.i64(2, 4096)
    w.i64(3, 77)
    w.i64(4, 1)  # sorting_columns id with a wrong type: skipped
    w.stop()
    var r = ThriftCompactReader(_view(Span(w.out)))
    var g = _parse_row_group(r)
    assert_equal(len(g.columns), 2)
    assert_equal(g.total_byte_size, 4096)
    assert_equal(g.num_rows, 77)
    var w2 = _W()
    w2.i32(1, 1)
    w2.i32(2, 1)
    w2.i32(3, 1)
    var r2 = ThriftCompactReader(_view(Span(w2.out)))  # no STOP
    var g2 = _parse_row_group(r2)
    assert_equal(len(g2.columns), 0)
    assert_equal(g2.num_rows, 0)
    var w3 = _W()
    w3.list(1, 40, 12)
    var r3 = ThriftCompactReader(_view(Span(w3.out)))
    var raised = False
    try:
        _ = _parse_row_group(r3)
    except:
        raised = True
    assert_true(raised)


# ---- parse_full_metadata --------------------------------------------------------


def _footer(created_by: String, kv_count: Int) -> List[UInt8]:
    var w = _W()
    w.i32(1, 2)
    w.list(2, 2, 12)
    w.elem()
    w.text(4, "schema")
    w.i32(5, 1)
    w.end()
    w.elem()
    w.i32(1, 2)
    w.text(4, "id")
    w.end()
    w.i64(3, 77)
    w.list(4, 1, 12)
    w.elem()
    w.i64(3, 77)
    w.end()
    w.list(5, kv_count, 12)
    for _ in range(kv_count):
        w.elem()
        w.text(1, "writer")
        w.text(2, "test")
        w.end()
    w.text(6, created_by)
    w.list(7, 0, 12)  # column_orders: skipped
    w.stop()
    return w.out.copy()


def test_full_metadata_every_top_level_field() raises:
    var footer = _footer("komira test", 1)
    var md = parse_full_metadata(_view(Span(footer)))
    assert_equal(md.version, 2)
    assert_equal(len(md.schema), 2)
    assert_equal(md.schema[0].num_children, 1)
    assert_equal(md.schema[1].name, "id")
    assert_equal(md.num_rows, 77)
    assert_equal(len(md.row_groups), 1)
    assert_equal(md.row_groups[0].num_rows, 77)
    assert_equal(md.key_value_metadata.value()[0].key, "writer")
    assert_equal(md.created_by.value(), "komira test")


def test_full_metadata_empty_kv_list_and_empty_created_by() raises:
    var footer = _footer("", 0)
    var md = parse_full_metadata(_view(Span(footer)))
    assert_false(Bool(md.key_value_metadata))
    assert_false(Bool(md.created_by))


def test_full_metadata_wrong_types_long_lists_and_no_stop() raises:
    var w = _W()
    w.i64(1, 2)  # each id with a type it does not have: skipped
    w.i32(2, 2)
    w.i32(3, 2)
    w.i32(4, 2)
    w.i32(5, 2)
    w.i32(6, 2)
    w.list(7, 16, 5)  # a long-form list nobody reads
    for _ in range(16):
        w.zz(1)
    var md = parse_full_metadata(_view(Span(w.out)))  # no STOP
    assert_equal(md.version, 0)
    assert_equal(md.num_rows, 0)
    assert_equal(len(md.schema), 0)
    var w2 = _W()
    w2.field(6, 8)
    _uleb(w2.out, 64)  # created_by past the bytes
    w2.out.append(0x61)
    var md2 = parse_full_metadata(_view(Span(w2.out)))
    assert_false(Bool(md2.created_by))


def test_full_metadata_long_form_lists_and_counts_too_large() raises:
    var w = _W()
    w.list(2, 15, 12)
    for _ in range(15):
        w.elem()
        w.end()
    w.list(4, 15, 12)
    for _ in range(15):
        w.elem()
        w.end()
    w.list(5, 15, 12)
    for _ in range(15):
        w.elem()
        w.text(1, "k")
        w.end()
    w.stop()
    var md = parse_full_metadata(_view(Span(w.out)))
    assert_equal(len(md.schema), 15)
    assert_equal(len(md.row_groups), 15)
    assert_equal(len(md.key_value_metadata.value()), 15)
    for field in range(3):
        var ids: List[Int] = [2, 4, 5]
        var bad = _W()
        bad.list(ids[field], 1000, 12)
        assert_true(_raises(bad.out, "list declares 1000"), "field " + String(ids[field]))


# ---- string lengths near Int.MAX ---------------------------------------------
#
# Each test ends a string field with a length of Int.MAX - 1 and four bytes of
# padding. Before the fix the bound `pos + len` wrapped negative, the check
# passed, and `List[UInt8](capacity=len + 1)` aborted the process (a null
# allocation), so each test failed by crashing. Now the string is left empty,
# `pos` stops at the end of the bytes (it is not moved past it, which would
# wrap it negative and make the next field read raise), and the walk ends.


def _huge_string(mut out: List[UInt8]):
    _uleb(out, Int.MAX - 1)
    for _ in range(4):
        out.append(0x00)


def test_full_metadata_created_by_length_near_int_max() raises:
    var b = List[UInt8]()
    b.append(0x68)  # field 6 (created_by), binary
    _huge_string(b)
    var md = parse_full_metadata(_view(Span(b)))
    assert_false(Bool(md.created_by))
    assert_equal(len(md.schema), 0)


def test_key_value_length_near_int_max() raises:
    var b = List[UInt8]()
    b.append(0x18)  # field 1 (key), binary
    _huge_string(b)
    var r = ThriftCompactReader(_view(Span(b)))
    var kv = _parse_key_value(r)
    assert_equal(kv.key, "")
    assert_false(Bool(kv.value))
    assert_equal(r.pos, len(b))


def test_schema_element_name_length_near_int_max() raises:
    var b = List[UInt8]()
    b.append(0x48)  # field 4 (name), binary
    _huge_string(b)
    var r = ThriftCompactReader(_view(Span(b)))
    var e = _parse_schema_element(r)
    assert_equal(e.name, "")
    assert_equal(r.pos, len(b))


def test_path_in_schema_segment_length_near_int_max() raises:
    var b = List[UInt8]()
    b.append(0x39)  # field 3 (path_in_schema), list
    b.append(0x18)  # one binary element
    _huge_string(b)
    var r = ThriftCompactReader(_view(Span(b)))
    var m = _parse_column_metadata(r)
    assert_equal(len(m.path_in_schema), 0)
    assert_equal(r.pos, len(b))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
