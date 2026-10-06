# =============================================================================
# test_ipc_file_e2e_pyarrow_stream.mojo: pyarrow-written Arrow IPC STREAMS:
# typed primitives, temporal and decimal columns, and dictionary deltas.
# =============================================================================
#
# Fixtures (Arrow IPC stream format, written by pyarrow 24.0.0 with
# `fixtures/arrow_ipc/gen_fixtures.py`):
#
#   primitives_int_float.arrow     int32/int64/uint32/uint64/float32/float64,
#                                  8 rows at the signed and unsigned limits
#   temporal_batch.arrow           date32, time32[ms], timestamp[us, tz=UTC],
#                                  duration[us]; 4 rows
#   decimal128_batch.arrow         decimal128(18, 4); 4 rows
#   dict_delta_stream.arrow        dictionary<int32, utf8>; DictionaryBatches
#                                  isDelta = false, true, true
#   dict_replacement_stream.arrow  dictionary<int32, utf8>; one DictionaryBatch
#                                  shared by two RecordBatches
#
# Each stream is walked message by message (continuation marker, metadata
# size, Message table, body), every message 8-aligned with an 8-aligned body,
# ending in the EOS marker at exactly the last 8 bytes. The Schema message's
# fields are checked against the generator (bit widths, signedness, float
# precision, the date unit, the timestamp and duration units, the timestamp's
# timezone, decimal precision, scale and width). pyarrow omits the time32[ms]
# field's unit and bitWidth, because they equal Schema.fbs's declared defaults
# (MILLISECOND, 32), so those checks fail if the reader returns 0 for an absent
# field instead of the declared default; it writes the date32 unit, DAY,
# because DAY is not the default. Each RecordBatch is decoded copy-on-read through
# `decode_record_batch_message_with_dicts` and, for the dictionary-free
# streams, zero-copy through `decode_record_batch_message_mmap`.
#
# Dictionary streams are resolved per the Arrow spec by a reference resolver
# that lives in this test: komira_arrow_ipc has no dictionary cache, and its
# record-batch decoder takes already-resolved dictionary values. The product
# code exercised is `read_dictionary_batch` (id, isDelta, data) and the
# decode of the dictionary and index buffers. The resolver's rules: an isDelta=false DictionaryBatch replaces the
# dictionary for its id, an isDelta=true one appends to it. With the deltas
# applied, batch 2's index 3 and batch 3's index 5 resolve to "d" and "f";
# a reader that treated a delta as a replacement would see indices past the
# end of a two-entry dictionary, and the decode raises.
# =============================================================================

from std.io import FileHandle
from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_arrow_ipc.ipc_decoder_dispatch import (
    decode_record_batch_message_mmap,
    decode_record_batch_message_with_dicts,
)
from komira_arrow_ipc.ipc_flatbuf import (
    ENDIANNESS_LITTLE,
    flatbuf_reader_over,
    parse_ipc_message,
    read_dictionary_batch,
    read_message,
    read_record_batch,
    read_schema,
    read_type_date,
    read_type_decimal,
    read_type_duration,
    read_type_floating_point,
    read_type_int,
    read_type_time,
    read_type_timestamp,
    DATE_UNIT_DAY,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA,
    PRECISION_DOUBLE,
    PRECISION_SINGLE,
    TIME_UNIT_MICROSECOND,
    TIME_UNIT_MILLISECOND,
    TYPE_DATE,
    TYPE_DECIMAL,
    TYPE_DURATION,
    TYPE_FLOATING_POINT,
    TYPE_INT,
    TYPE_TIME,
    TYPE_TIMESTAMP,
    TYPE_UTF8,
)


comptime FIX = "src/komira_arrow_ipc/tests/fixtures/arrow_ipc/"


# ---------------------------------------------------------------------------
# Stream-format helpers (the encapsulated message grammar, from the spec)
# ---------------------------------------------------------------------------


def _load(path: String) raises -> SharedAlignedBuffer[HeapRegion]:
    var f = FileHandle(path, "r")
    _ = f.seek(0, 2)
    var n = Int(f.seek(0, 1))
    _ = f.seek(0, 0)
    var raw = f.read_bytes(n)
    f.close()
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    out.copy_from_bytes_list(raw)
    return out^


def _slice(
    src: SharedAlignedBuffer[HeapRegion], start: Int, n: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    assert_true(start >= 0 and start + n <= src.len(), "slice out of stream")
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    if n > 0:
        out.copy_from_view_at(0, src.view_range_ro(start, n))
    out.set_length(n)
    return out^


@fieldwise_init
struct _Msg(Copyable, Movable):
    var offset: Int
    var meta_len: Int
    var body_len: Int
    var tag: UInt8


def _walk_stream(buf: SharedAlignedBuffer[HeapRegion]) raises -> List[_Msg]:
    """Every message of a stream; the EOS marker must be the last 8 bytes."""
    var out = List[_Msg]()
    var pos = 0
    var n = buf.len()
    while True:
        assert_true(pos + 8 <= n, "stream ended without EOS")
        assert_equal(pos % 8, 0, "message offset not 8-aligned")
        assert_equal(buf.read_u32_le_at(pos), UInt32(0xFFFFFFFF))
        var meta = Int(buf.read_u32_le_at(pos + 4))
        if meta == 0:
            assert_equal(pos + 8, n, "bytes after EOS")
            break
        var md = _slice(buf, pos + 8, meta)
        var r = flatbuf_reader_over(md)
        var msg = read_message(r, r.read_root_offset())
        assert_equal(msg.version, Int16(4))
        var body = Int(msg.body_length)
        assert_equal(body % 8, 0, "body length not 8-aligned")
        out.append(_Msg(offset=pos, meta_len=8 + meta, body_len=body, tag=msg.header_tag))
        pos += 8 + meta + body
    return out^


def _frame(buf: SharedAlignedBuffer[HeapRegion], m: _Msg) raises -> SharedAlignedBuffer[HeapRegion]:
    return _slice(buf, m.offset, m.meta_len + m.body_len)


def _metadata(frame: SharedAlignedBuffer[HeapRegion]) raises -> SharedAlignedBuffer[HeapRegion]:
    return _slice(frame, 8, Int(frame.read_u32_le_at(4)))


def _placeholders(n: Int) -> Slab[Column[HeapRegion]]:
    var s = Slab[Column[HeapRegion]]()
    for _ in range(n):
        s.append(Column[HeapRegion]())
    return s^


def _no_dicts(n: Int) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(False)
    return out^


def _decode_pass(
    pass_: Int,
    path: String,
    buf: SharedAlignedBuffer[HeapRegion],
    m: _Msg,
    types: List[ArrowType],
) raises -> Slab[Column[HeapRegion]]:
    """Pass 0: copy-on-read with dicts. Pass 1: mmap of the same file, with the
    message's absolute offset."""
    if pass_ == 0:
        return decode_record_batch_message_with_dicts(
            _frame(buf, m), types, _no_dicts(len(types)), _placeholders(len(types))
        )
    var region = ArcPointer[MmapRegion](MmapRegion.open_readonly(path))
    return decode_record_batch_message_mmap(_frame(buf, m), types, region, m.offset)


def _expect_tags(msgs: List[_Msg], tags: List[UInt8]) raises:
    assert_equal(len(msgs), len(tags))
    for i in range(len(tags)):
        assert_equal(msgs[i].tag, tags[i])


# ---------------------------------------------------------------------------
# Dictionary resolution (Arrow spec: isDelta=false replaces, true appends)
# ---------------------------------------------------------------------------


@fieldwise_init
struct _DictBatch(Movable):
    var id: Int64
    var is_delta: Bool
    var values: List[String]


def _read_dict_batch(frame: SharedAlignedBuffer[HeapRegion]) raises -> _DictBatch:
    var f = parse_ipc_message(frame)
    var md = _slice(frame, f.metadata_pos, f.metadata_size)
    var r = flatbuf_reader_over(md)
    var msg = read_message(r, r.read_root_offset())
    assert_equal(msg.header_tag, MESSAGE_HEADER_DICTIONARY_BATCH)
    var db = read_dictionary_batch(r, msg.header_table_pos)
    var rb = read_record_batch(r, db.data_table_pos)
    assert_equal(rb.body_compression_codec, Int8(-1))
    assert_equal(len(rb.nodes), 1)
    assert_equal(len(rb.buffers), 3)
    var n = Int(rb.length)
    var off_pos = f.body_pos + Int(rb.buffers[1].offset)
    var data_pos = f.body_pos + Int(rb.buffers[2].offset)
    var values = List[String]()
    for i in range(n):
        var a = Int(frame.read_i32_le_at(off_pos + 4 * i))
        var b = Int(frame.read_i32_le_at(off_pos + 4 * (i + 1)))
        var s = String("")
        for j in range(a, b):
            s += chr(Int(frame.read_u8_at(data_pos + j)))
        values.append(s^)
    return _DictBatch(id=db.id, is_delta=db.is_delta, values=values^)


@fieldwise_init
struct _DictStream(Movable):
    """What a dictionary stream resolved to: the isDelta flag of each
    DictionaryBatch in order, and the decoded strings of each RecordBatch."""

    var deltas: List[Bool]
    var batches: List[List[String]]


def _read_dict_stream(path: String) raises -> _DictStream:
    """Walk a one-column dictionary<int32, utf8> stream, resolving each
    DictionaryBatch into the dictionary for its id before the batches that
    follow it are decoded."""
    var buf = _load(path)
    var msgs = _walk_stream(buf)
    assert_true(len(msgs) >= 1)
    assert_equal(msgs[0].tag, MESSAGE_HEADER_SCHEMA)
    var schema_frame = _frame(buf, msgs[0])
    var smd = _metadata(schema_frame)
    var sr = flatbuf_reader_over(smd)
    var smsg = read_message(sr, sr.read_root_offset())
    var schema = read_schema(sr, smsg.header_table_pos)
    assert_equal(schema.endianness, ENDIANNESS_LITTLE, "Schema not little-endian")
    assert_equal(len(schema.fields), 1)
    ref k = schema.fields[0]
    assert_equal(k.name, "k")
    assert_equal(k.type_tag, TYPE_UTF8)
    if not k.dictionary_encoding:
        raise Error("field k must carry a DictionaryEncoding")
    ref enc = k.dictionary_encoding.value()
    assert_equal(enc.index_type_bit_width, 32)
    assert_true(enc.index_type_is_signed)

    var dictionary = List[String]()
    var deltas = List[Bool]()
    var batches = List[List[String]]()
    for i in range(1, len(msgs)):
        if msgs[i].tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            var d = _read_dict_batch(_frame(buf, msgs[i]))
            assert_equal(d.id, enc.id)
            deltas.append(d.is_delta)
            if not d.is_delta:
                dictionary.clear()
            for j in range(len(d.values)):
                dictionary.append(d.values[j].copy())
            continue
        assert_equal(msgs[i].tag, MESSAGE_HEADER_RECORD_BATCH)
        var types = List[ArrowType]()
        types.append(ArrowType.STRING)
        var is_dict: List[Bool] = [True]
        var widths: List[Int] = [enc.index_type_bit_width]
        var values = Slab[Column[HeapRegion]]()
        values.append(Column.from_string(StringArray.from_strings(dictionary)))
        var cols = decode_record_batch_message_with_dicts(
            _frame(buf, msgs[i]), types, is_dict, values^, widths
        )
        assert_equal(len(cols), 1)
        ref c = cols[0]
        assert_equal(c.arrow_type, ArrowType.STRING)
        assert_equal(c._null_count, 0)
        var rows = List[String]()
        for r in range(c._length):
            assert_false(c.is_null_at(r))
            rows.append(c.utf8_value_at(r))
        batches.append(rows^)
    return _DictStream(deltas=deltas^, batches=batches^)


def _expect_batch(got: List[String], want: List[String]) raises:
    assert_equal(len(got), len(want))
    for i in range(len(want)):
        assert_equal(got[i], want[i])


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_primitives_int_float() raises:
    var path = String(FIX) + "primitives_int_float.arrow"
    var buf = _load(path)
    var msgs = _walk_stream(buf)
    var tags: List[UInt8] = [MESSAGE_HEADER_SCHEMA, MESSAGE_HEADER_RECORD_BATCH]
    _expect_tags(msgs, tags)
    var smd = _metadata(_frame(buf, msgs[0]))
    var r = flatbuf_reader_over(smd)
    var schema = read_schema(r, read_message(r, r.read_root_offset()).header_table_pos)
    assert_equal(schema.endianness, ENDIANNESS_LITTLE, "Schema not little-endian")
    var names: List[String] = [
        String("i32"), String("i64"), String("u32"), String("u64"), String("f32"), String("f64")
    ]
    var bits: List[Int] = [32, 64, 32, 64]
    var signed: List[Bool] = [True, True, False, False]
    assert_equal(len(schema.fields), 6)
    for i in range(6):
        assert_equal(schema.fields[i].name, names[i])
        assert_true(schema.fields[i].nullable)
    for i in range(4):
        assert_equal(schema.fields[i].type_tag, TYPE_INT)
        var t = read_type_int(r, schema.fields[i].type_table_pos)
        assert_equal(t.bit_width, bits[i])
        assert_equal(t.is_signed, signed[i])
    assert_equal(schema.fields[4].type_tag, TYPE_FLOATING_POINT)
    assert_equal(read_type_floating_point(r, schema.fields[4].type_table_pos).precision, PRECISION_SINGLE)
    assert_equal(schema.fields[5].type_tag, TYPE_FLOATING_POINT)
    assert_equal(read_type_floating_point(r, schema.fields[5].type_table_pos).precision, PRECISION_DOUBLE)

    var i32: List[Int32] = [-2147483648, -1, 0, 1, 2147483647, 42, -42, 100]
    var i64: List[Int64] = [-9223372036854775807, -1, 0, 1, 9223372036854775807, 42, -42, 100]
    var u32: List[UInt32] = [0, 1, 2, 4294967295, 100, 42, 7, 99]
    var u64: List[UInt64] = [0, 1, 2, 18446744073709551615, 100, 42, 7, 99]
    # pyarrow converts each Python float (a double) to float32.
    var f32: List[Float32] = [
        Float32(Float64(0.0)), Float32(Float64(1.5)), Float32(Float64(-1.5)),
        Float32(Float64(3.14)), Float32(Float64(-3.14)), Float32(Float64(1e10)),
        Float32(Float64(-1e10)), Float32(Float64(0.0)),
    ]
    var f64: List[Float64] = [
        0.0, 1.5, -1.5, 3.141592653589793, -3.141592653589793, 1e100, -1e100, 0.0
    ]
    var types = List[ArrowType]()
    types.append(ArrowType.INT32)
    types.append(ArrowType.INT64)
    types.append(ArrowType.UINT32)
    types.append(ArrowType.UINT64)
    types.append(ArrowType.FLOAT32)
    types.append(ArrowType.FLOAT64)
    for pass_ in range(2):
        var cols = _decode_pass(pass_, path, buf, msgs[1], types)
        assert_equal(len(cols), 6)
        for c in range(6):
            assert_equal(cols[c]._length, 8)
            assert_equal(cols[c]._null_count, 0)
            assert_equal(cols[c].arrow_type, types[c])
        for i in range(8):
            assert_equal(cols[0]._data.read_i32_le_at(i * 4), i32[i])
            assert_equal(cols[1]._data.read_i64_le_at(i * 8), i64[i])
            assert_equal(cols[2]._data.read_u32_le_at(i * 4), u32[i])
            assert_equal(cols[3]._data.read_u64_le_at(i * 8), u64[i])
            assert_equal(cols[4]._data.read_f32_le_at(i * 4), f32[i])
            assert_equal(cols[5]._data.read_f64_le_at(i * 8), f64[i])


def test_temporal_batch() raises:
    var path = String(FIX) + "temporal_batch.arrow"
    var buf = _load(path)
    var msgs = _walk_stream(buf)
    var tags: List[UInt8] = [MESSAGE_HEADER_SCHEMA, MESSAGE_HEADER_RECORD_BATCH]
    _expect_tags(msgs, tags)
    var smd = _metadata(_frame(buf, msgs[0]))
    var r = flatbuf_reader_over(smd)
    var schema = read_schema(r, read_message(r, r.read_root_offset()).header_table_pos)
    assert_equal(schema.endianness, ENDIANNESS_LITTLE, "Schema not little-endian")
    assert_equal(len(schema.fields), 4)
    assert_equal(schema.fields[0].name, "d32")
    assert_equal(schema.fields[0].type_tag, TYPE_DATE)
    # pyarrow writes DAY (= 0): it is not Date.unit's default, MILLISECOND.
    assert_equal(read_type_date(r, schema.fields[0].type_table_pos).unit, DATE_UNIT_DAY)
    assert_equal(schema.fields[1].name, "t32_ms")
    assert_equal(schema.fields[1].type_tag, TYPE_TIME)
    var tt = read_type_time(r, schema.fields[1].type_table_pos)
    # pyarrow omits both fields: Schema.fbs declares
    # `Time.unit: TimeUnit = MILLISECOND` and `bitWidth: int = 32`, and
    # FlatBuffers drops a field equal to its default. A reader returning 0 for
    # the absent unit reads time32[s] here (komira-ai/komira#506).
    assert_equal(tt.unit, TIME_UNIT_MILLISECOND)
    assert_equal(tt.bit_width, 32)
    assert_equal(schema.fields[2].name, "ts_us_utc")
    assert_equal(schema.fields[2].type_tag, TYPE_TIMESTAMP)
    var ts = read_type_timestamp(r, schema.fields[2].type_table_pos)
    assert_equal(ts.unit, TIME_UNIT_MICROSECOND)
    assert_equal(ts.timezone, "UTC")
    assert_equal(schema.fields[3].name, "dur_us")
    assert_equal(schema.fields[3].type_tag, TYPE_DURATION)
    assert_equal(read_type_duration(r, schema.fields[3].type_table_pos).unit, TIME_UNIT_MICROSECOND)

    var d32: List[Int32] = [0, 1, 18250, 19000]
    var t32: List[Int32] = [0, 1000, 86399000, 43200000]
    var ts_us: List[Int64] = [0, 1000000, 1577836800000000, 1640995200000000]
    var dur_us: List[Int64] = [0, 1000000, 3600000000, 86400000000]
    var types = List[ArrowType]()
    types.append(ArrowType.DATE32)
    types.append(ArrowType.TIME32_MS)
    types.append(ArrowType.TIMESTAMP_US)
    types.append(ArrowType.DURATION_US)
    for pass_ in range(2):
        var cols = _decode_pass(pass_, path, buf, msgs[1], types)
        assert_equal(len(cols), 4)
        for c in range(4):
            assert_equal(cols[c]._length, 4)
            assert_equal(cols[c]._null_count, 0)
            assert_equal(cols[c].arrow_type, types[c])
        for i in range(4):
            assert_equal(cols[0]._data.read_i32_le_at(i * 4), d32[i])
            assert_equal(cols[1]._data.read_i32_le_at(i * 4), t32[i])
            assert_equal(cols[2]._data.read_i64_le_at(i * 8), ts_us[i])
            assert_equal(cols[3]._data.read_i64_le_at(i * 8), dur_us[i])


def test_decimal128_batch() raises:
    """decimal128(18, 4): 0.0000, 1.5000, -1.5000, 12345.6789 are the unscaled
    16-byte little-endian integers 0, 15000, -15000, 123456789."""
    var path = String(FIX) + "decimal128_batch.arrow"
    var buf = _load(path)
    var msgs = _walk_stream(buf)
    var tags: List[UInt8] = [MESSAGE_HEADER_SCHEMA, MESSAGE_HEADER_RECORD_BATCH]
    _expect_tags(msgs, tags)
    var smd = _metadata(_frame(buf, msgs[0]))
    var r = flatbuf_reader_over(smd)
    var schema = read_schema(r, read_message(r, r.read_root_offset()).header_table_pos)
    assert_equal(schema.endianness, ENDIANNESS_LITTLE, "Schema not little-endian")
    assert_equal(len(schema.fields), 1)
    assert_equal(schema.fields[0].name, "amount")
    assert_equal(schema.fields[0].type_tag, TYPE_DECIMAL)
    var dt = read_type_decimal(r, schema.fields[0].type_table_pos)
    assert_equal(dt.precision, 18)
    assert_equal(dt.scale, 4)
    assert_equal(dt.bit_width, 128)

    var unscaled: List[Int] = [0, 15000, -15000, 123456789]
    var types = List[ArrowType]()
    types.append(ArrowType.DECIMAL128)
    for pass_ in range(2):
        var cols = _decode_pass(pass_, path, buf, msgs[1], types)
        assert_equal(len(cols), 1)
        assert_equal(cols[0].arrow_type, ArrowType.DECIMAL128)
        assert_equal(cols[0]._length, 4)
        assert_equal(cols[0]._null_count, 0)
        for i in range(4):
            assert_equal(
                cols[0]._data.read_i128_le_at(i * 16),
                Scalar[DType.int128](unscaled[i]),
            )


def test_dict_delta_stream() raises:
    """Three DictionaryBatches (isDelta false, true, true) build the dictionary
    a, b, c | d, e | f; the batches resolve to [a b c], [a d e], [c e f]."""
    var path = String(FIX) + "dict_delta_stream.arrow"
    var buf = _load(path)
    var msgs = _walk_stream(buf)
    var tags: List[UInt8] = [
        MESSAGE_HEADER_SCHEMA,
        MESSAGE_HEADER_DICTIONARY_BATCH,
        MESSAGE_HEADER_RECORD_BATCH,
        MESSAGE_HEADER_DICTIONARY_BATCH,
        MESSAGE_HEADER_RECORD_BATCH,
        MESSAGE_HEADER_DICTIONARY_BATCH,
        MESSAGE_HEADER_RECORD_BATCH,
    ]
    _expect_tags(msgs, tags)
    # The delta batches carry only the new entries.
    var d2 = _read_dict_batch(_frame(buf, msgs[3]))
    assert_equal(len(d2.values), 2)
    assert_equal(d2.values[0], "d")
    assert_equal(d2.values[1], "e")
    var d3 = _read_dict_batch(_frame(buf, msgs[5]))
    assert_equal(len(d3.values), 1)
    assert_equal(d3.values[0], "f")

    var s = _read_dict_stream(path)
    assert_equal(len(s.deltas), 3)
    assert_false(s.deltas[0])
    assert_true(s.deltas[1])
    assert_true(s.deltas[2])
    assert_equal(len(s.batches), 3)
    _expect_batch(s.batches[0], [String("a"), String("b"), String("c")])
    _expect_batch(s.batches[1], [String("a"), String("d"), String("e")])
    _expect_batch(s.batches[2], [String("c"), String("e"), String("f")])

    # The mmap decoder has no dictionary arm; it refuses rather than guess.
    var dict_types = List[ArrowType]()
    dict_types.append(ArrowType.DICTIONARY)
    var raised = False
    try:
        _ = _decode_pass(1, path, buf, msgs[2], dict_types)
    except e:
        raised = True
        assert_equal(
            String(e),
            "decode_record_batch_message_mmap: DICTIONARY columns require"
            " dict-aware decode. Caller should use the copy-on-read dict-aware"
            " dispatch instead of the mmap path for files containing"
            " dict-encoded columns.",
        )
    assert_true(raised)


def test_dict_replacement_stream() raises:
    """pyarrow emits one isDelta=false DictionaryBatch (x, y, z) and does not
    re-emit an equal dictionary; both batches resolve to [x y z]."""
    var path = String(FIX) + "dict_replacement_stream.arrow"
    var buf = _load(path)
    var msgs = _walk_stream(buf)
    var tags: List[UInt8] = [
        MESSAGE_HEADER_SCHEMA,
        MESSAGE_HEADER_DICTIONARY_BATCH,
        MESSAGE_HEADER_RECORD_BATCH,
        MESSAGE_HEADER_RECORD_BATCH,
    ]
    _expect_tags(msgs, tags)
    var s = _read_dict_stream(path)
    assert_equal(len(s.deltas), 1)
    assert_false(s.deltas[0])
    assert_equal(len(s.batches), 2)
    _expect_batch(s.batches[0], [String("x"), String("y"), String("z")])
    _expect_batch(s.batches[1], [String("x"), String("y"), String("z")])


def main() raises:
    var suite = TestSuite()
    suite.test[test_primitives_int_float]()
    suite.test[test_temporal_batch]()
    suite.test[test_decimal128_batch]()
    suite.test[test_dict_delta_stream]()
    suite.test[test_dict_replacement_stream]()
    suite^.run()
