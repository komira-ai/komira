# =============================================================================
# test_ipc_file_e2e_pyarrow_batches.mojo: pyarrow-written Arrow IPC FILES with
# several batches, compressed bodies, and a dictionary.
# =============================================================================
#
# Fixtures (Arrow IPC File format, written by pyarrow 24.0.0 with
# `fixtures/arrow_ipc/gen_pyarrow_interop_fixtures.py`):
#
#   interop_multi_batch.arrow        3 batches of 40, 55, 30 rows; nulls span
#                                    batch boundaries; id == global row index
#   interop_codec_lz4.arrow          1 batch, BodyCompression LZ4_FRAME
#   interop_codec_zstd.arrow         1 batch, BodyCompression ZSTD
#   interop_dict_string_nulls.arrow  dictionary<int32, utf8> column with nulls;
#                                    the footer carries one dictionary Block
#
# For each file the footer is read (`read_footer`), every Block is matched to
# the message the stream holds at that offset (dictionary Blocks to
# DictionaryBatch messages, record-batch Blocks to RecordBatch messages), and
# every batch is decoded with `decode_record_batch_message_with_dicts`; the
# uncompressed, dictionary-free batches are also decoded through
# `decode_record_batch_message_mmap`. The mmap decoder refuses compressed and
# DICTIONARY batches by contract; that refusal is asserted, so a silent
# zero-copy of compressed bytes would fail here.
#
# The dictionary is resolved the way the Arrow spec says a reader must: the
# DictionaryBatch's values are read from its body (an isDelta=false batch
# replaces the dictionary for its id, an isDelta=true batch appends), and the
# resolved values go to the decoder as the column's dictionary. komira_arrow_ipc
# has no dictionary-batch reader of its own (its decoder takes resolved values),
# so that step lives in this test, built only on `read_dictionary_batch` and
# `read_record_batch`.
#
# Expected values are the generator's closed forms, recomputed here.
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
    Block,
    FieldDescriptor,
    FlatbufReader,
    flatbuf_reader_over,
    parse_ipc_message,
    read_dictionary_batch,
    read_footer,
    read_message,
    read_record_batch,
    read_schema,
    read_type_int,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA,
    TYPE_INT,
    TYPE_UTF8,
    COMPRESSION_LZ4_FRAME,
    COMPRESSION_ZSTD,
    ENDIANNESS_LITTLE,
)


comptime FIX = "src/komira_arrow_ipc/tests/fixtures/arrow_ipc/"


# ---------------------------------------------------------------------------
# File-format helpers (the Arrow File grammar, spelled from the spec)
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
    assert_true(start >= 0 and start + n <= src.len(), "slice out of file")
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    if n > 0:
        out.copy_from_view_at(0, src.view_range_ro(start, n))
    out.set_length(n)
    return out^


def _check_magic(buf: SharedAlignedBuffer[HeapRegion]) raises:
    var n = buf.len()
    assert_true(n >= 8 + 4 + 6)
    var magic: List[UInt8] = [0x41, 0x52, 0x52, 0x4F, 0x57, 0x31]
    for i in range(6):
        assert_equal(buf.read_u8_at(i), magic[i])
        assert_equal(buf.read_u8_at(n - 6 + i), magic[i])
    assert_equal(buf.read_u8_at(6), UInt8(0))
    assert_equal(buf.read_u8_at(7), UInt8(0))


def _footer_bytes(
    buf: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    var n = buf.len()
    var flen = Int(buf.read_i32_le_at(n - 10))
    assert_true(flen > 0 and flen <= n - 8 - 10, "footer length out of file")
    return _slice(buf, n - 10 - flen, flen)


@fieldwise_init
struct _Msg(Copyable, Movable):
    var offset: Int
    var meta_len: Int
    var body_len: Int
    var tag: UInt8


def _check_body_buffers[
    bo: Origin[mut=False]
](
    buf: SharedAlignedBuffer[HeapRegion],
    body_start: Int,
    body: Int,
    r: FlatbufReader[bo],
    rb_pos: Int,
) raises:
    """Every Buffer of the RecordBatch table at `rb_pos` (a RecordBatch, or a
    DictionaryBatch's data) starts 8-aligned in the body and lies inside
    bodyLength. When the batch is compressed, each non-empty buffer is the
    spec's i64 LE uncompressed-length prefix (-1 = left uncompressed) followed,
    when compressed, by a frame in the codec's own format: LZ4 frame magic
    0x184D2204 or ZSTD frame magic 0xFD2FB528. A writer emitting raw LZ4 blocks
    or a bad prefix would round-trip through its own reader and still fail
    here."""
    var rb = read_record_batch(r, rb_pos)
    for k in range(len(rb.buffers)):
        ref bd = rb.buffers[k]
        if bd.length == 0:
            continue
        var off = Int(bd.offset)
        var ln = Int(bd.length)
        assert_equal(off % 8, 0, "buffer " + String(k) + " not 8-aligned")
        assert_true(off >= 0 and off + ln <= body, "buffer past bodyLength")
        if rb.body_compression_codec < 0:
            continue
        assert_true(ln >= 8, "compressed buffer shorter than its length prefix")
        var prefix = buf.read_i64_le_at(body_start + off)
        assert_true(prefix >= -1, "bad uncompressed-length prefix")
        if prefix == -1:
            continue
        if ln == 8:
            assert_equal(prefix, Int64(0), "empty frame for a non-empty buffer")
            continue
        var magic = buf.read_u32_le_at(body_start + off + 8)
        if rb.body_compression_codec == COMPRESSION_LZ4_FRAME:
            assert_equal(magic, UInt32(0x184D2204), "not an LZ4 frame")
        else:
            assert_equal(rb.body_compression_codec, COMPRESSION_ZSTD)
            assert_equal(magic, UInt32(0xFD2FB528), "not a ZSTD frame")


def _check_schema_pair(
    buf: SharedAlignedBuffer[HeapRegion], schema_msg_offset: Int
) raises:
    """The Schema message at the head of the File and the Footer's Schema
    agree field for field (name, nullability, type tag, dictionary id), and
    both declare little-endian data (komira's decoders read LE only)."""
    var meta = Int(buf.read_u32_le_at(schema_msg_offset + 4))
    var md = _slice(buf, schema_msg_offset + 8, meta)
    var sr = flatbuf_reader_over(md)
    var smsg = read_message(sr, sr.read_root_offset())
    assert_equal(smsg.header_tag, MESSAGE_HEADER_SCHEMA)
    var head = read_schema(sr, smsg.header_table_pos)
    var fb = _footer_bytes(buf)
    var fr = flatbuf_reader_over(fb)
    var foot = read_schema(fr, read_footer(fr, fr.read_root_offset()).schema_table_pos)
    assert_equal(head.endianness, ENDIANNESS_LITTLE, "stream Schema not little-endian")
    assert_equal(foot.endianness, ENDIANNESS_LITTLE, "footer Schema not little-endian")
    assert_equal(len(head.fields), len(foot.fields))
    for i in range(len(head.fields)):
        ref a = head.fields[i]
        ref b = foot.fields[i]
        assert_equal(a.name, b.name)
        assert_equal(a.nullable, b.nullable)
        assert_equal(a.type_tag, b.type_tag)
        assert_equal(a.dictionary_encoding.__bool__(), b.dictionary_encoding.__bool__())
        if a.dictionary_encoding.__bool__():
            assert_equal(a.dictionary_encoding.value().id, b.dictionary_encoding.value().id)


def _walk(buf: SharedAlignedBuffer[HeapRegion], start: Int, end: Int) raises -> List[_Msg]:
    """Encapsulated messages from `start` to the EOS marker or `end`; each
    8-aligned, V5, with an 8-aligned body."""
    var out = List[_Msg]()
    var pos = start
    while pos < end:
        assert_equal(pos % 8, 0, "message offset not 8-aligned")
        assert_equal(buf.read_u32_le_at(pos), UInt32(0xFFFFFFFF))
        var meta = Int(buf.read_u32_le_at(pos + 4))
        if meta == 0:
            # pyarrow writes the optional EOS marker before the footer; it
            # must be the last 8 bytes, with nothing between it and the footer.
            assert_equal(pos + 8, end, "bytes between EOS and the footer")
            return out^
        var md = _slice(buf, pos + 8, meta)
        var r = flatbuf_reader_over(md)
        var msg = read_message(r, r.read_root_offset())
        assert_equal(msg.version, Int16(4))
        var body = Int(msg.body_length)
        assert_equal(body % 8, 0, "body length not 8-aligned")
        assert_true(pos + 8 + meta + body <= end, "body overruns the footer")
        if msg.header_tag == MESSAGE_HEADER_RECORD_BATCH:
            _check_body_buffers(buf, pos + 8 + meta, body, r, msg.header_table_pos)
        elif msg.header_tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            var db = read_dictionary_batch(r, msg.header_table_pos)
            _check_body_buffers(buf, pos + 8 + meta, body, r, db.data_table_pos)
        out.append(_Msg(offset=pos, meta_len=8 + meta, body_len=body, tag=msg.header_tag))
        pos += 8 + meta + body
    assert_equal(pos, end, "messages do not tile up to the footer")
    return out^


def _check_blocks(
    buf: SharedAlignedBuffer[HeapRegion],
    dict_blocks: List[Block],
    rb_blocks: List[Block],
    expected_tags: List[UInt8],
) raises:
    """The stream holds exactly `expected_tags`, and the footer's dictionary
    and record-batch Blocks name those messages in order."""
    var n = buf.len()
    var flen = Int(buf.read_i32_le_at(n - 10))
    var msgs = _walk(buf, 8, n - 10 - flen)
    assert_true(len(msgs) >= 1)
    _check_schema_pair(buf, msgs[0].offset)
    assert_equal(len(msgs), len(expected_tags))
    var d = 0
    var b = 0
    for i in range(len(msgs)):
        assert_equal(msgs[i].tag, expected_tags[i])
        if msgs[i].tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            ref blk = dict_blocks[d]
            assert_equal(Int(blk.offset), msgs[i].offset)
            assert_equal(Int(blk.meta_data_length), msgs[i].meta_len)
            assert_equal(Int(blk.body_length), msgs[i].body_len)
            d += 1
        elif msgs[i].tag == MESSAGE_HEADER_RECORD_BATCH:
            ref blk = rb_blocks[b]
            assert_equal(Int(blk.offset), msgs[i].offset)
            assert_equal(Int(blk.meta_data_length), msgs[i].meta_len)
            assert_equal(Int(blk.body_length), msgs[i].body_len)
            b += 1
    assert_equal(d, len(dict_blocks))
    assert_equal(b, len(rb_blocks))


def _block_frame(
    buf: SharedAlignedBuffer[HeapRegion], blk: Block
) raises -> SharedAlignedBuffer[HeapRegion]:
    return _slice(buf, Int(blk.offset), Int(blk.meta_data_length) + Int(blk.body_length))


def _rb_codec(frame: SharedAlignedBuffer[HeapRegion]) raises -> Int8:
    """The RecordBatch's BodyCompression codec (-1 when absent)."""
    var md = _slice(frame, 8, Int(frame.read_u32_le_at(4)))
    var r = flatbuf_reader_over(md)
    var msg = read_message(r, r.read_root_offset())
    assert_equal(msg.header_tag, MESSAGE_HEADER_RECORD_BATCH)
    return read_record_batch(r, msg.header_table_pos).body_compression_codec


def _no_dicts(n: Int) -> List[Bool]:
    var out = List[Bool]()
    for _ in range(n):
        out.append(False)
    return out^


def _placeholders(n: Int) -> Slab[Column[HeapRegion]]:
    var s = Slab[Column[HeapRegion]]()
    for _ in range(n):
        s.append(Column[HeapRegion]())
    return s^


def _decode_copy(
    buf: SharedAlignedBuffer[HeapRegion], blk: Block, types: List[ArrowType]
) raises -> Slab[Column[HeapRegion]]:
    return decode_record_batch_message_with_dicts(
        _block_frame(buf, blk), types, _no_dicts(len(types)), _placeholders(len(types))
    )


def _decode_mmap(
    path: String, buf: SharedAlignedBuffer[HeapRegion], blk: Block, types: List[ArrowType]
) raises -> Slab[Column[HeapRegion]]:
    var region = ArcPointer[MmapRegion](MmapRegion.open_readonly(path))
    return decode_record_batch_message_mmap(
        _block_frame(buf, blk), types, region, Int(blk.offset)
    )


def _mmap_refuses(
    path: String,
    buf: SharedAlignedBuffer[HeapRegion],
    blk: Block,
    types: List[ArrowType],
    needle: String,
) raises:
    """The mmap decoder raises, naming `needle`, rather than borrowing bytes it
    cannot serve zero-copy."""
    var raised = False
    try:
        _ = _decode_mmap(path, buf, blk, types)
    except e:
        raised = True
        assert_true(needle in String(e), String(e))
    assert_true(raised, "mmap decode must refuse this batch")


# ---------------------------------------------------------------------------
# Dictionary resolution (Arrow spec: isDelta=false replaces, true appends)
# ---------------------------------------------------------------------------


@fieldwise_init
struct _DictBatch(Movable):
    var id: Int64
    var is_delta: Bool
    var values: List[String]


def _read_dict_batch(frame: SharedAlignedBuffer[HeapRegion]) raises -> _DictBatch:
    """The id, isDelta flag and utf8 values of an uncompressed DictionaryBatch."""
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
    assert_equal(Int(rb.nodes[0].length), n)
    assert_equal(Int(rb.nodes[0].null_count), 0)
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


def _resolve(mut dictionary: List[String], d: _DictBatch):
    if not d.is_delta:
        dictionary.clear()
    for i in range(len(d.values)):
        dictionary.append(d.values[i].copy())


# ---------------------------------------------------------------------------
# Value checks
# ---------------------------------------------------------------------------


def _check_id_anchor(col: Column[HeapRegion], n: Int, base: Int) raises:
    assert_equal(col.arrow_type, ArrowType.INT64)
    assert_equal(col._length, n)
    assert_equal(col._null_count, 0)
    for i in range(n):
        assert_false(col.is_null_at(i))
        assert_equal(col._data.read_i64_le_at(i * 8), Int64(base + i))


def _check_id_n_s(
    cols: Slab[Column[HeapRegion]],
    rows: Int,
    base: Int,
    mul: Int,
    cat: List[String],
) raises:
    """id == base + i; n NULL at (base+i) % 5 == 0 else (base+i) * mul; s NULL
    at (base+i) % 3 == 0 else cat[(base+i) % 4]."""
    assert_equal(len(cols), 3)
    _check_id_anchor(cols[0], rows, base)
    ref n = cols[1]
    ref s = cols[2]
    assert_equal(n.arrow_type, ArrowType.INT64)
    assert_equal(s.arrow_type, ArrowType.STRING)
    assert_equal(n._length, rows)
    assert_equal(s._length, rows)
    var n_nulls = 0
    var s_nulls = 0
    for i in range(rows):
        var g = base + i
        if g % 5 == 0:
            assert_true(n.is_null_at(i))
            n_nulls += 1
        else:
            assert_false(n.is_null_at(i))
            assert_equal(n._data.read_i64_le_at(i * 8), Int64(g * mul))
        if g % 3 == 0:
            assert_true(s.is_null_at(i))
            s_nulls += 1
        else:
            assert_false(s.is_null_at(i))
            assert_equal(s.utf8_value_at(i), cat[g % 4])
    assert_equal(n._null_count, n_nulls)
    assert_equal(s._null_count, s_nulls)


def _check_three_col_schema[
    bo: Origin[mut=False]
](r: FlatbufReader[bo], fields: List[FieldDescriptor]) raises:
    assert_equal(len(fields), 3)
    var names: List[String] = [String("id"), String("n"), String("s")]
    for i in range(3):
        assert_equal(fields[i].name, names[i])
        assert_true(fields[i].nullable)
        assert_true(not fields[i].dictionary_encoding)
    for i in range(2):
        assert_equal(fields[i].type_tag, TYPE_INT)
        var t = read_type_int(r, fields[i].type_table_pos)
        assert_equal(t.bit_width, 64)
        assert_true(t.is_signed)
    assert_equal(fields[2].type_tag, TYPE_UTF8)


def _types_i64_i64_str() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.INT64)
    t.append(ArrowType.INT64)
    t.append(ArrowType.STRING)
    return t^


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_multi_batch() raises:
    """Three Blocks, decoded in footer order; the id anchor proves each Block
    is the batch it claims to be (40, 55, 30 rows at bases 0, 40, 95)."""
    var path = String(FIX) + "interop_multi_batch.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(footer.version, Int16(4))
    assert_equal(len(footer.dictionaries), 0)
    assert_equal(len(footer.record_batches), 3)
    var schema = read_schema(r, footer.schema_table_pos)
    _check_three_col_schema(r, schema.fields)
    var tags: List[UInt8] = [
        MESSAGE_HEADER_SCHEMA,
        MESSAGE_HEADER_RECORD_BATCH,
        MESSAGE_HEADER_RECORD_BATCH,
        MESSAGE_HEADER_RECORD_BATCH,
    ]
    _check_blocks(buf, footer.dictionaries, footer.record_batches, tags)
    var cat: List[String] = [String("a"), String("bb"), String("ccc"), String("dddd")]
    var sizes: List[Int] = [40, 55, 30]
    var types = _types_i64_i64_str()
    var base = 0
    for k in range(3):
        ref blk = footer.record_batches[k]
        assert_equal(_rb_codec(_block_frame(buf, blk)), Int8(-1))
        _check_id_n_s(_decode_copy(buf, blk, types), sizes[k], base, 1, cat)
        _check_id_n_s(_decode_mmap(path, buf, blk, types), sizes[k], base, 1, cat)
        base += sizes[k]
    assert_equal(base, 125)


def _codec_file(name: String, codec: Int8, mul: Int, var cat: List[String]) raises:
    var path = String(FIX) + name
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.dictionaries), 0)
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    _check_three_col_schema(r, schema.fields)
    var tags: List[UInt8] = [MESSAGE_HEADER_SCHEMA, MESSAGE_HEADER_RECORD_BATCH]
    _check_blocks(buf, footer.dictionaries, footer.record_batches, tags)
    ref blk = footer.record_batches[0]
    assert_equal(_rb_codec(_block_frame(buf, blk)), codec)
    var types = _types_i64_i64_str()
    _check_id_n_s(_decode_copy(buf, blk, types), 300, 0, mul, cat)
    _mmap_refuses(path, buf, blk, types, "BodyCompression.codec=" + String(Int(codec)))


def test_codec_lz4() raises:
    """LZ4_FRAME body: n = i * 2, cat lz/frame/compressed/values."""
    _codec_file(
        "interop_codec_lz4.arrow",
        Int8(0),
        2,
        [String("lz"), String("frame"), String("compressed"), String("values")],
    )


def test_codec_zstd() raises:
    """ZSTD body: n = i * 3, cat zstd/block/deflate/stream."""
    _codec_file(
        "interop_codec_zstd.arrow",
        Int8(1),
        3,
        [String("zstd"), String("block"), String("deflate"), String("stream")],
    )


def test_dict_string_nulls() raises:
    """id INT64 anchor + color dictionary<int32, utf8>, NULL every 3rd row,
    else cat[i % 5]. The footer names one dictionary Block, isDelta=false, id 0,
    holding the five colours in first-appearance order."""
    var cat: List[String] = [
        String("red"), String("green"), String("blue"), String("yellow"), String("purple")
    ]
    var path = String(FIX) + "interop_dict_string_nulls.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.dictionaries), 1)
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 2)
    assert_equal(schema.fields[0].name, "id")
    assert_true(not schema.fields[0].dictionary_encoding)
    ref color = schema.fields[1]
    assert_equal(color.name, "color")
    assert_true(color.nullable)
    # A dictionary field's type is its VALUE type; the index type rides in
    # the DictionaryEncoding.
    assert_equal(color.type_tag, TYPE_UTF8)
    if not color.dictionary_encoding:
        raise Error("color must carry a DictionaryEncoding")
    ref enc = color.dictionary_encoding.value()
    assert_equal(enc.id, Int64(0))
    assert_equal(enc.index_type_bit_width, 32)
    assert_true(enc.index_type_is_signed)
    assert_false(enc.is_ordered)
    var tags: List[UInt8] = [
        MESSAGE_HEADER_SCHEMA,
        MESSAGE_HEADER_DICTIONARY_BATCH,
        MESSAGE_HEADER_RECORD_BATCH,
    ]
    _check_blocks(buf, footer.dictionaries, footer.record_batches, tags)

    var d = _read_dict_batch(_block_frame(buf, footer.dictionaries[0]))
    assert_equal(d.id, enc.id)
    assert_false(d.is_delta)
    var expected_dict: List[String] = [
        String("green"), String("blue"), String("purple"), String("red"), String("yellow")
    ]
    assert_equal(len(d.values), 5)
    for i in range(5):
        assert_equal(d.values[i], expected_dict[i])
    var dictionary = List[String]()
    _resolve(dictionary, d)

    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    var is_dict: List[Bool] = [False, True]
    var widths: List[Int] = [32, enc.index_type_bit_width]
    var values = Slab[Column[HeapRegion]]()
    values.append(Column[HeapRegion]())
    values.append(Column.from_string(StringArray.from_strings(dictionary)))
    ref blk = footer.record_batches[0]
    var cols = decode_record_batch_message_with_dicts(
        _block_frame(buf, blk), types, is_dict, values^, widths
    )
    assert_equal(len(cols), 2)
    _check_id_anchor(cols[0], 300, 0)
    ref c = cols[1]
    assert_equal(c.arrow_type, ArrowType.STRING)
    assert_equal(c._length, 300)
    for i in range(300):
        if i % 3 == 0:
            assert_true(c.is_null_at(i))
        else:
            assert_false(c.is_null_at(i))
            assert_equal(c.utf8_value_at(i), cat[i % 5])
    assert_equal(c._null_count, 100)

    var dict_types = List[ArrowType]()
    dict_types.append(ArrowType.INT64)
    dict_types.append(ArrowType.DICTIONARY)
    _mmap_refuses(path, buf, blk, dict_types, "DICTIONARY")


def main() raises:
    var suite = TestSuite()
    suite.test[test_multi_batch]()
    suite.test[test_codec_lz4]()
    suite.test[test_codec_zstd]()
    suite.test[test_dict_string_nulls]()
    suite^.run()
