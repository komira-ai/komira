# =============================================================================
# test_ipc_file_e2e_pyarrow_nullable.mojo: pyarrow-written Arrow IPC FILES,
# read end to end through the footer, one batch each.
# =============================================================================
#
# Every fixture here is an Arrow IPC File (ARROW1 magic, Schema, RecordBatch,
# Footer, footer length, ARROW1) written by pyarrow 24.0.0 with
# `fixtures/arrow_ipc/gen_pyarrow_interop_fixtures.py` (and `arrow_file.arrow`
# with `gen_fixtures.py`). For each file the test:
#
#   1. checks the leading `ARROW1\0\0` and trailing `ARROW1` magic;
#   2. reads the footer length and the Footer table (`read_footer`), then the
#      footer's Schema (`read_schema`), asserting every field's name, nullability
#      and type parameters against the generator script;
#   3. walks the message stream from byte 8 independently of the footer and
#      asserts the footer's record-batch Blocks name exactly the RecordBatch
#      messages found, with `metaDataLength = 8 + metadata size`, an 8-aligned
#      offset, and `bodyLength` equal to the Message's own bodyLength and to the
#      bytes up to the next message;
#   4. decodes each Block twice, copy-on-read through
#      `decode_record_batch_message_with_dicts` and zero-copy through
#      `decode_record_batch_message_mmap` over an mmap of the same file, and
#      asserts row counts, null counts, null positions and every value.
#
# The expected values are the generator's closed forms, recomputed here; nothing
# is compared against komira's own decode. What each check catches:
#   - a null placed at the wrong row, or the null rows dropped (N-K rows):
#     the per-row `is_null_at` + value loop;
#   - a FieldNode null_count that disagrees with the bitmap: `_null_count`;
#   - a footer Block that points into the wrong message, or a bodyLength that
#     is not the bytes on disk: `_check_blocks_match_stream`;
#   - the mmap path reading at a wrong absolute offset: the mmap decode runs the
#     same value checks as the copy decode.
# =============================================================================

from std.io import FileHandle
from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
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
    read_footer,
    read_message,
    read_record_batch,
    read_schema,
    read_type_floating_point,
    read_type_int,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA,
    PRECISION_DOUBLE,
    TYPE_BOOL,
    TYPE_FLOATING_POINT,
    TYPE_INT,
    TYPE_UTF8,
    read_dictionary_batch,
    COMPRESSION_LZ4_FRAME,
    COMPRESSION_ZSTD,
    ENDIANNESS_LITTLE,
    MESSAGE_HEADER_DICTIONARY_BATCH,
)


comptime FIX = "src/komira_arrow_ipc/tests/fixtures/arrow_ipc/"


# ---------------------------------------------------------------------------
# File-format helpers (the Arrow File grammar, spelled from the spec)
# ---------------------------------------------------------------------------


def _load(path: String) raises -> SharedAlignedBuffer[HeapRegion]:
    """The whole file, as a heap buffer."""
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
    """A fresh heap copy of `src[start, start + n)`."""
    assert_true(start >= 0 and start + n <= src.len(), "slice out of file")
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    if n > 0:
        out.copy_from_view_at(0, src.view_range_ro(start, n))
    out.set_length(n)
    return out^


def _check_magic(buf: SharedAlignedBuffer[HeapRegion]) raises:
    """`ARROW1` + two zero pad bytes at the head, `ARROW1` at the tail."""
    var n = buf.len()
    assert_true(n >= 8 + 4 + 6, "file shorter than magic + footer length")
    var magic: List[UInt8] = [0x41, 0x52, 0x52, 0x4F, 0x57, 0x31]
    for i in range(6):
        assert_equal(buf.read_u8_at(i), magic[i])
        assert_equal(buf.read_u8_at(n - 6 + i), magic[i])
    assert_equal(buf.read_u8_at(6), UInt8(0))
    assert_equal(buf.read_u8_at(7), UInt8(0))


def _footer_bytes(
    buf: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    """The Footer flatbuffer: the i32 before the trailing magic is its size."""
    var n = buf.len()
    var flen = Int(buf.read_i32_le_at(n - 10))
    assert_true(flen > 0 and flen <= n - 8 - 10, "footer length out of file")
    return _slice(buf, n - 10 - flen, flen)


@fieldwise_init
struct _Msg(Copyable, Movable):
    """One message found by walking the stream: where it starts, its
    metaDataLength (prefix + metadata), its body length and header tag."""

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
    """Walk encapsulated messages from `start` until the EOS marker or `end`.
    Every message must start 8-aligned with the continuation marker, carry
    MetadataVersion V5, and have an 8-aligned body length."""
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
        assert_equal(meta % 8, 0, "metadata size not 8-aligned")
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


def _check_blocks_match_stream(
    buf: SharedAlignedBuffer[HeapRegion], blocks: List[Block]
) raises:
    """The footer's record-batch Blocks are exactly the RecordBatch messages of
    the stream, in order, with matching lengths."""
    var n = buf.len()
    var flen = Int(buf.read_i32_le_at(n - 10))
    var msgs = _walk(buf, 8, n - 10 - flen)
    assert_true(len(msgs) >= 1)
    _check_schema_pair(buf, msgs[0].offset)
    assert_equal(msgs[0].tag, UInt8(MESSAGE_HEADER_SCHEMA))
    var rb_idx = 0
    for i in range(len(msgs)):
        if msgs[i].tag != MESSAGE_HEADER_RECORD_BATCH:
            continue
        assert_true(rb_idx < len(blocks), "stream has more batches than footer")
        ref b = blocks[rb_idx]
        assert_equal(Int(b.offset), msgs[i].offset)
        assert_equal(Int(b.meta_data_length), msgs[i].meta_len)
        assert_equal(Int(b.body_length), msgs[i].body_len)
        rb_idx += 1
    assert_equal(rb_idx, len(blocks))


def _block_frame(
    buf: SharedAlignedBuffer[HeapRegion], blk: Block
) raises -> SharedAlignedBuffer[HeapRegion]:
    """The bytes a Block names: [offset, offset + metaDataLength + bodyLength)."""
    var total = Int(blk.meta_data_length) + Int(blk.body_length)
    return _slice(buf, Int(blk.offset), total)


def _placeholders(n: Int) -> Slab[Column[HeapRegion]]:
    var s = Slab[Column[HeapRegion]]()
    for _ in range(n):
        s.append(Column[HeapRegion]())
    return s^


def _decode_copy(
    buf: SharedAlignedBuffer[HeapRegion], blk: Block, types: List[ArrowType]
) raises -> Slab[Column[HeapRegion]]:
    var is_dict = List[Bool]()
    for _ in range(len(types)):
        is_dict.append(False)
    return decode_record_batch_message_with_dicts(
        _block_frame(buf, blk), types, is_dict, _placeholders(len(types))
    )


def _decode_mmap(
    path: String,
    buf: SharedAlignedBuffer[HeapRegion],
    blk: Block,
    types: List[ArrowType],
) raises -> Slab[Column[HeapRegion]]:
    var region = ArcPointer[MmapRegion](MmapRegion.open_readonly(path))
    return decode_record_batch_message_mmap(
        _block_frame(buf, blk), types, region, Int(blk.offset)
    )


def _decode_pass(
    pass_: Int,
    path: String,
    buf: SharedAlignedBuffer[HeapRegion],
    blk: Block,
    types: List[ArrowType],
) raises -> Slab[Column[HeapRegion]]:
    """Pass 0 decodes copy-on-read, pass 1 through the mmap."""
    if pass_ == 0:
        return _decode_copy(buf, blk, types)
    return _decode_mmap(path, buf, blk, types)


# ---------------------------------------------------------------------------
# Schema checks
# ---------------------------------------------------------------------------


def _check_int_field[
    bo: Origin[mut=False]
](
    r: FlatbufReader[bo], fd: FieldDescriptor, name: String, bits: Int
) raises:
    assert_equal(fd.name, name)
    assert_true(fd.nullable)
    assert_equal(fd.type_tag, TYPE_INT)
    assert_true(not fd.dictionary_encoding)
    var t = read_type_int(r, fd.type_table_pos)
    assert_equal(t.bit_width, bits)
    assert_true(t.is_signed)


def _check_tag_field(fd: FieldDescriptor, name: String, tag: UInt8) raises:
    assert_equal(fd.name, name)
    assert_true(fd.nullable)
    assert_equal(fd.type_tag, tag)
    assert_true(not fd.dictionary_encoding)


def _check_f64_field[
    bo: Origin[mut=False]
](r: FlatbufReader[bo], fd: FieldDescriptor, name: String) raises:
    _check_tag_field(fd, name, TYPE_FLOATING_POINT)
    var t = read_type_floating_point(r, fd.type_table_pos)
    assert_equal(t.precision, PRECISION_DOUBLE)


# ---------------------------------------------------------------------------
# Value checks
# ---------------------------------------------------------------------------


def _bit(col: Column[HeapRegion], row: Int) -> Bool:
    """Value bit `row` of a BOOL column (LSB-first)."""
    var byte = col._data.read_u8_at(row // 8)
    return ((byte >> UInt8(row % 8)) & UInt8(1)) == UInt8(1)


def _check_id_anchor(col: Column[HeapRegion], n: Int, base: Int) raises:
    """An all-valid INT64 column whose row i holds base + i."""
    assert_equal(col.arrow_type, ArrowType.INT64)
    assert_equal(col._length, n)
    assert_equal(col._null_count, 0)
    for i in range(n):
        assert_false(col.is_null_at(i))
        assert_equal(col._data.read_i64_le_at(i * 8), Int64(base + i))


def _check_nullable_string(cols: Slab[Column[HeapRegion]]) raises:
    """interop_nullable_string: label NULL every 3rd row, else cat[i % 4]."""
    var cat: List[String] = [String("alpha"), String("beta"), String("gamma"), String("delta")]
    assert_equal(len(cols), 2)
    _check_id_anchor(cols[0], 300, 0)
    ref lab = cols[1]
    assert_equal(lab.arrow_type, ArrowType.STRING)
    assert_equal(lab._length, 300)
    var nulls = 0
    for i in range(300):
        if i % 3 == 0:
            assert_true(lab.is_null_at(i), "row " + String(i) + " must be null")
            nulls += 1
        else:
            assert_false(lab.is_null_at(i), "row " + String(i) + " must be valid")
            assert_equal(lab.utf8_value_at(i), cat[i % 4])
    assert_equal(nulls, 100)
    assert_equal(lab._null_count, nulls)


def _check_nullable_int64(cols: Slab[Column[HeapRegion]]) raises:
    """interop_nullable_int64: v NULL every 5th row, else i * 10."""
    assert_equal(len(cols), 2)
    _check_id_anchor(cols[0], 300, 0)
    ref v = cols[1]
    assert_equal(v.arrow_type, ArrowType.INT64)
    assert_equal(v._length, 300)
    for i in range(300):
        if i % 5 == 0:
            assert_true(v.is_null_at(i))
        else:
            assert_false(v.is_null_at(i))
            assert_equal(v._data.read_i64_le_at(i * 8), Int64(i * 10))
    assert_equal(v._null_count, 60)


def _check_nullable_float64(cols: Slab[Column[HeapRegion]]) raises:
    """interop_nullable_float64: v NULL every 4th row, else i + 0.5 (exact)."""
    assert_equal(len(cols), 2)
    _check_id_anchor(cols[0], 300, 0)
    ref v = cols[1]
    assert_equal(v.arrow_type, ArrowType.FLOAT64)
    assert_equal(v._length, 300)
    for i in range(300):
        if i % 4 == 0:
            assert_true(v.is_null_at(i))
        else:
            assert_false(v.is_null_at(i))
            assert_equal(v._data.read_f64_le_at(i * 8), Float64(i) + 0.5)
    assert_equal(v._null_count, 75)


def _check_nullable_bool(cols: Slab[Column[HeapRegion]]) raises:
    """interop_nullable_bool: v NULL every 7th row, else (i % 2 == 0)."""
    assert_equal(len(cols), 2)
    _check_id_anchor(cols[0], 300, 0)
    ref v = cols[1]
    assert_equal(v.arrow_type, ArrowType.BOOL)
    assert_equal(v._length, 300)
    var nulls = 0
    for i in range(300):
        if i % 7 == 0:
            assert_true(v.is_null_at(i))
            nulls += 1
        else:
            assert_false(v.is_null_at(i))
            assert_equal(_bit(v, i), i % 2 == 0, "bool value at row " + String(i))
    assert_equal(nulls, 43)
    assert_equal(v._null_count, nulls)


def _big_value(i: Int) -> String:
    """interop_large_strings row i: "row{i}:" + "x" * ((i + 1) * 64)."""
    var s = "row" + String(i) + ":"
    for _ in range((i + 1) * 64):
        s += "x"
    return s^


def _check_large_strings(cols: Slab[Column[HeapRegion]]) raises:
    assert_equal(len(cols), 2)
    _check_id_anchor(cols[0], 60, 0)
    ref big = cols[1]
    assert_equal(big.arrow_type, ArrowType.STRING)
    assert_equal(big._length, 60)
    for i in range(60):
        if i % 4 == 0:
            assert_true(big.is_null_at(i))
        else:
            assert_false(big.is_null_at(i))
            assert_equal(big.utf8_value_at(i), _big_value(i))
    assert_equal(big._null_count, 15)


def _check_mixed(cols: Slab[Column[HeapRegion]]) raises:
    """interop_mixed_schema: 120 rows; i32 NULL %2 else i+1; f64 NULL %3 else
    i*1.25; b NULL %4 else (i % 3 == 0); s NULL %5 else cat[i % 5]."""
    var cat: List[String] = [String("q"), String("ww"), String("eee"), String("rrrr"), String("ttttt")]
    assert_equal(len(cols), 5)
    _check_id_anchor(cols[0], 120, 0)
    ref i32 = cols[1]
    ref f64 = cols[2]
    ref b = cols[3]
    ref s = cols[4]
    assert_equal(i32.arrow_type, ArrowType.INT32)
    assert_equal(f64.arrow_type, ArrowType.FLOAT64)
    assert_equal(b.arrow_type, ArrowType.BOOL)
    assert_equal(s.arrow_type, ArrowType.STRING)
    for i in range(120):
        assert_equal(i32.is_null_at(i), i % 2 == 0)
        if i % 2 != 0:
            assert_equal(i32._data.read_i32_le_at(i * 4), Int32(i + 1))
        assert_equal(f64.is_null_at(i), i % 3 == 0)
        if i % 3 != 0:
            assert_equal(f64._data.read_f64_le_at(i * 8), Float64(i) * 1.25)
        assert_equal(b.is_null_at(i), i % 4 == 0)
        if i % 4 != 0:
            assert_equal(_bit(b, i), i % 3 == 0)
        assert_equal(s.is_null_at(i), i % 5 == 0)
        if i % 5 != 0:
            assert_equal(s.utf8_value_at(i), cat[i % 5])
    assert_equal(i32._null_count, 60)
    assert_equal(f64._null_count, 40)
    assert_equal(b._null_count, 30)
    assert_equal(s._null_count, 24)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def _id_and(t: ArrowType) -> List[ArrowType]:
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(t)
    return types^


def test_nullable_string() raises:
    var path = String(FIX) + "interop_nullable_string.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(footer.version, Int16(4))
    assert_equal(len(footer.dictionaries), 0)
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 2)
    _check_int_field(r, schema.fields[0], "id", 64)
    _check_tag_field(schema.fields[1], "label", TYPE_UTF8)
    _check_blocks_match_stream(buf, footer.record_batches)
    var types = _id_and(ArrowType.STRING)
    _check_nullable_string(_decode_copy(buf, footer.record_batches[0], types))
    _check_nullable_string(_decode_mmap(path, buf, footer.record_batches[0], types))


def test_nullable_int64() raises:
    var path = String(FIX) + "interop_nullable_int64.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 2)
    _check_int_field(r, schema.fields[0], "id", 64)
    _check_int_field(r, schema.fields[1], "v", 64)
    _check_blocks_match_stream(buf, footer.record_batches)
    var types = _id_and(ArrowType.INT64)
    _check_nullable_int64(_decode_copy(buf, footer.record_batches[0], types))
    _check_nullable_int64(_decode_mmap(path, buf, footer.record_batches[0], types))


def test_nullable_float64() raises:
    var path = String(FIX) + "interop_nullable_float64.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 2)
    _check_int_field(r, schema.fields[0], "id", 64)
    _check_f64_field(r, schema.fields[1], "v")
    _check_blocks_match_stream(buf, footer.record_batches)
    var types = _id_and(ArrowType.FLOAT64)
    _check_nullable_float64(_decode_copy(buf, footer.record_batches[0], types))
    _check_nullable_float64(_decode_mmap(path, buf, footer.record_batches[0], types))


def test_nullable_bool() raises:
    var path = String(FIX) + "interop_nullable_bool.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 2)
    _check_int_field(r, schema.fields[0], "id", 64)
    _check_tag_field(schema.fields[1], "v", TYPE_BOOL)
    _check_blocks_match_stream(buf, footer.record_batches)
    var types = _id_and(ArrowType.BOOL)
    _check_nullable_bool(_decode_copy(buf, footer.record_batches[0], types))
    _check_nullable_bool(_decode_mmap(path, buf, footer.record_batches[0], types))


def test_single_row() raises:
    """interop_single_row: n INT64 [null], s STRING ["only"]."""
    var path = String(FIX) + "interop_single_row.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 2)
    _check_int_field(r, schema.fields[0], "n", 64)
    _check_tag_field(schema.fields[1], "s", TYPE_UTF8)
    _check_blocks_match_stream(buf, footer.record_batches)
    var types = _id_and(ArrowType.STRING)
    for pass_ in range(2):
        var cols = _decode_pass(pass_, path, buf, footer.record_batches[0], types)
        assert_equal(len(cols), 2)
        assert_equal(cols[0]._length, 1)
        assert_equal(cols[0]._null_count, 1)
        assert_true(cols[0].is_null_at(0))
        assert_equal(cols[1]._length, 1)
        assert_equal(cols[1]._null_count, 0)
        assert_false(cols[1].is_null_at(0))
        assert_equal(cols[1].utf8_value_at(0), "only")


def test_empty() raises:
    """interop_empty: one zero-row batch; the schema keeps both fields."""
    var path = String(FIX) + "interop_empty.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 2)
    _check_int_field(r, schema.fields[0], "id", 64)
    _check_tag_field(schema.fields[1], "label", TYPE_UTF8)
    _check_blocks_match_stream(buf, footer.record_batches)
    # The RecordBatch table itself says zero rows.
    var frame = _block_frame(buf, footer.record_batches[0])
    var md = _slice(frame, 8, Int(frame.read_u32_le_at(4)))
    var mr = flatbuf_reader_over(md)
    var msg = read_message(mr, mr.read_root_offset())
    assert_equal(read_record_batch(mr, msg.header_table_pos).length, Int64(0))
    var types = _id_and(ArrowType.STRING)
    for pass_ in range(2):
        var cols = _decode_pass(pass_, path, buf, footer.record_batches[0], types)
        assert_equal(len(cols), 2)
        assert_equal(cols[0]._length, 0)
        assert_equal(cols[1]._length, 0)
        assert_equal(cols[0]._null_count, 0)
        assert_equal(cols[1]._null_count, 0)


def test_large_strings() raises:
    var path = String(FIX) + "interop_large_strings.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 2)
    _check_int_field(r, schema.fields[0], "id", 64)
    _check_tag_field(schema.fields[1], "big", TYPE_UTF8)
    _check_blocks_match_stream(buf, footer.record_batches)
    var types = _id_and(ArrowType.STRING)
    _check_large_strings(_decode_copy(buf, footer.record_batches[0], types))
    _check_large_strings(_decode_mmap(path, buf, footer.record_batches[0], types))


def test_mixed_schema() raises:
    var path = String(FIX) + "interop_mixed_schema.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 5)
    _check_int_field(r, schema.fields[0], "id", 64)
    _check_int_field(r, schema.fields[1], "i32", 32)
    _check_f64_field(r, schema.fields[2], "f64")
    _check_tag_field(schema.fields[3], "b", TYPE_BOOL)
    _check_tag_field(schema.fields[4], "s", TYPE_UTF8)
    _check_blocks_match_stream(buf, footer.record_batches)
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.INT32)
    types.append(ArrowType.FLOAT64)
    types.append(ArrowType.BOOL)
    types.append(ArrowType.STRING)
    _check_mixed(_decode_copy(buf, footer.record_batches[0], types))
    _check_mixed(_decode_mmap(path, buf, footer.record_batches[0], types))


def test_arrow_file_fifty_rows() raises:
    """arrow_file.arrow: i INT64 0..49 and f FLOAT64 i * 0.25, no nulls."""
    var path = String(FIX) + "arrow_file.arrow"
    var buf = _load(path)
    _check_magic(buf)
    var fb = _footer_bytes(buf)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.record_batches), 1)
    var schema = read_schema(r, footer.schema_table_pos)
    assert_equal(len(schema.fields), 2)
    _check_int_field(r, schema.fields[0], "i", 64)
    _check_f64_field(r, schema.fields[1], "f")
    _check_blocks_match_stream(buf, footer.record_batches)
    var types = _id_and(ArrowType.FLOAT64)
    for pass_ in range(2):
        var cols = _decode_pass(pass_, path, buf, footer.record_batches[0], types)
        _check_id_anchor(cols[0], 50, 0)
        assert_equal(cols[1]._null_count, 0)
        for i in range(50):
            assert_equal(cols[1]._data.read_f64_le_at(i * 8), Float64(i) * 0.25)


def main() raises:
    var suite = TestSuite()
    suite.test[test_nullable_string]()
    suite.test[test_nullable_int64]()
    suite.test[test_nullable_float64]()
    suite.test[test_nullable_bool]()
    suite.test[test_single_row]()
    suite.test[test_empty]()
    suite.test[test_large_strings]()
    suite.test[test_mixed_schema]()
    suite.test[test_arrow_file_fifty_rows]()
    suite^.run()
