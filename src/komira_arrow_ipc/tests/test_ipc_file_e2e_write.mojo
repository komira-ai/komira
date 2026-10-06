# =============================================================================
# test_ipc_file_e2e_write.mojo: an Arrow IPC File and stream WRITTEN by
# komira's encoders, read back through the same path the pyarrow fixtures take.
# =============================================================================
#
# Writer: the File grammar assembled from komira's pieces, the way a file sink
# does it: `arrow_ipc_file_magic_header`, `encode_schema_message`, then per
# batch `encode_record_batch_message` or
# `encode_record_batch_message_compressed[Lz4Frame | Zstd]`, a Block per frame
# (`offset` = bytes written so far, `metaDataLength` from
# `arrow_ipc_message_metadata_length`, `bodyLength` = frame - metadata), and
# `encode_footer_message` for the Footer, its length and the trailing magic.
# The dictionary file adds `encode_dictionary_batch_message_from_string_column`
# and a dictionary Block; the dictionary stream adds the LZ4 dictionary encoder
# and `arrow_ipc_eos_bytes`.
#
# Reader: the test-side spec walk (magic, footer length, `read_footer`,
# `read_schema`), then `decode_record_batch_message_with_dicts` and, for
# uncompressed batches, `decode_record_batch_message_mmap` over an mmap of the
# written file. Each decoded batch is compared against an independently built
# expected batch with `record_batch_diff` (bit-exact floats, validity per row).
#
# Layout checks, each on every written message:
#   - the message starts 8-aligned, its metadata length is a multiple of 8;
#   - Block.bodyLength == Message.bodyLength == the bytes between the end of
#     the metadata and the next message (the messages tile the file up to the
#     footer with no gap), and is a multiple of 8;
#   - every Buffer of every RecordBatch and DictionaryBatch starts 8-aligned
#     in the body and lies inside bodyLength;
#   - every compressed buffer is an i64 LE length prefix (-1 or >= 0) and, when
#     compressed, a frame in its codec's format (LZ4 frame / ZSTD magic);
#   - a File may hold an EOS marker only as its last 8 bytes before the footer.
# The batches are sized so that unpadded bodies end off an 8-byte boundary
# (odd row counts, a STRING column last), so a writer that stopped padding the
# body would be caught by the alignment and tiling checks, not just in theory.
# =============================================================================

from std.io import FileHandle
from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, Schema, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.mmap_region import MmapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_compression.compression_codecs import Lz4Frame, Zstd
from komira_libc.chunked_write import write_chunked
from komira_libc.posix import _read_env
from komira_arrow_ipc.ipc_body_compression import (
    decompress_dictionary_batch_frame,
    encode_dictionary_batch_message_from_string_column_compressed,
    encode_record_batch_message_compressed,
    peek_dictionary_batch_codec_from_frame,
)
from komira_arrow_ipc.ipc_decoder_dispatch import (
    decode_record_batch_message_mmap,
    decode_record_batch_message_with_dicts,
)
from komira_arrow_ipc.ipc_encoder_dispatch import (
    arrow_ipc_eos_bytes,
    arrow_ipc_file_magic_header,
    arrow_ipc_message_metadata_length,
    encode_dictionary_batch_message_from_string_column,
    encode_footer_message,
    encode_record_batch_message,
    encode_schema_message,
)
from komira_arrow_ipc.ipc_flatbuf import (
    Block,
    FlatbufReader,
    flatbuf_reader_over,
    parse_ipc_message,
    read_dictionary_batch,
    read_footer,
    read_message,
    read_record_batch,
    read_schema,
    read_type_timestamp,
    COMPRESSION_LZ4_FRAME,
    COMPRESSION_ZSTD,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA,
    TIME_UNIT_MICROSECOND,
    TYPE_BOOL,
    TYPE_FLOATING_POINT,
    TYPE_INT,
    TYPE_TIMESTAMP,
    TYPE_UTF8,
)
from komira_arrow_ipc.record_batch_compare import record_batch_diff


# ---------------------------------------------------------------------------
# Byte plumbing
# ---------------------------------------------------------------------------


def _scratch(name: String) -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + "/komira_ipc_file_e2e_" + name


def _append(mut out: List[UInt8], b: SharedAlignedBuffer[HeapRegion]):
    for i in range(b.len()):
        out.append(b.read_u8_at(i))


def _to_buf(bytes: List[UInt8]) -> SharedAlignedBuffer[HeapRegion]:
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(len(bytes), 1))
    out.copy_from_bytes_list(bytes)
    return out^


def _write_file(path: String, bytes: List[UInt8]) raises:
    var h = FileHandle(path, "w")
    write_chunked(h, Span(bytes))
    _ = h^


def _slice(
    src: SharedAlignedBuffer[HeapRegion], start: Int, n: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    assert_true(start >= 0 and start + n <= src.len(), "slice out of file")
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    if n > 0:
        out.copy_from_view_at(0, src.view_range_ro(start, n))
    out.set_length(n)
    return out^


def _block_for(offset: Int, frame: SharedAlignedBuffer[HeapRegion]) raises -> Block:
    """The Block a writer records for `frame` written at `offset`."""
    var meta = Int(arrow_ipc_message_metadata_length(frame))
    return Block(
        offset=Int64(offset),
        meta_data_length=Int32(meta),
        body_length=Int64(frame.len() - meta),
    )


# ---------------------------------------------------------------------------
# The data: closed forms the expected batches are rebuilt from
# ---------------------------------------------------------------------------


def _schema() -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("v", ArrowType.INT32, True))
    sb.add_field(Field("f", ArrowType.FLOAT64, True))
    sb.add_field(Field("b", ArrowType.BOOL, True))
    try:
        sb.add_field(Field.timestamp("ts", ArrowType.TIMESTAMP_US, "UTC", True))
    except:
        pass
    sb.add_field(Field("s", ArrowType.STRING, True))
    return sb.build()


def _s_value(g: Int) -> String:
    var s = "s" + String(g)
    for _ in range(g % 5):
        s += "x"
    return s^


def _columns(n: Int, base: Int) raises -> Slab[Column[HeapRegion]]:
    """Row i (global g = base + i): id = g; v = g*7 - 50, NULL at g%3==0;
    f = g*0.5 - 3.25, NULL at g%4==1; b = (g%2==0), NULL at g%5==2;
    ts = 1.6e15 + g*1e6 us, NULL at g%6==5; s = "s{g}" + "x"*(g%5), NULL at g%4==3."""
    var cols = Slab[Column[HeapRegion]]()
    var ids = PrimitiveArray[DType.int64].allocate(n)
    var v = PrimitiveArray[DType.int32].allocate_nullable(n)
    var f = PrimitiveArray[DType.float64].allocate_nullable(n)
    var b = BooleanArray.allocate_nullable(n)
    var ts = PrimitiveArray[DType.int64].allocate_nullable(n)
    var s_vals = List[String]()
    var s_valid = List[Bool]()
    for i in range(n):
        var g = base + i
        ids.set(i, Int64(g))
        if g % 3 == 0:
            v._set_null(i)
        else:
            v.set(i, Int32(g * 7 - 50))
        if g % 4 == 1:
            f._set_null(i)
        else:
            f.set(i, Float64(g) * 0.5 - 3.25)
        if g % 5 == 2:
            b._set_null(i)
        else:
            b.set(i, g % 2 == 0)
        if g % 6 == 5:
            ts._set_null(i)
        else:
            ts.set(i, Int64(1600000000000000 + g * 1000000))
        s_valid.append(g % 4 != 3)
        s_vals.append(_s_value(g) if g % 4 != 3 else String(""))
    cols.append(Column.from_primitive[DType.int64](ids^))
    cols.append(Column.from_primitive[DType.int32](v^))
    cols.append(Column.from_primitive[DType.float64](f^))
    cols.append(Column.from_boolean(b^))
    cols.append(Column.from_primitive_with_arrow_type[DType.int64](ts^, ArrowType.TIMESTAMP_US))
    cols.append(Column.from_string(StringArray.from_strings_with_validity(s_vals, s_valid)))
    return cols^


def _batch(var cols: Slab[Column[HeapRegion]], var schema: Schema) raises -> RecordBatch:
    var bb = RecordBatchBuilder()
    while len(cols) > 0:
        bb.add_column(cols.take_at(0))
    return bb.build(schema^)


def _check_diff(expected: RecordBatch, got: RecordBatch, what: String) raises:
    var d = record_batch_diff(expected, got)
    assert_true(d.equal, what + ": " + d.reason)


# ---------------------------------------------------------------------------
# Reader-side layout checks
# ---------------------------------------------------------------------------


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


def _walk_to(buf: SharedAlignedBuffer[HeapRegion], start: Int, end: Int, eos: Bool) raises -> List[_Msg]:
    """Messages from `start`; they must tile [start, end) exactly. A stream
    (`eos`) must end in the 8-byte EOS marker. In a File the EOS marker is
    optional (the File body is the streaming format, and Arrow C++ writes one
    before the footer); when present it must be the last 8 bytes before `end`.
    """
    var out = List[_Msg]()
    var pos = start
    while pos < end:
        assert_equal(pos % 8, 0, "message offset " + String(pos) + " not 8-aligned")
        assert_equal(buf.read_u32_le_at(pos), UInt32(0xFFFFFFFF))
        var meta = Int(buf.read_u32_le_at(pos + 4))
        if meta == 0:
            assert_equal(pos + 8, end, "bytes after EOS")
            return out^
        assert_equal(meta % 8, 0)
        var md = _slice(buf, pos + 8, meta)
        var r = flatbuf_reader_over(md)
        var msg = read_message(r, r.read_root_offset())
        assert_equal(msg.version, Int16(4))
        var body = Int(msg.body_length)
        assert_equal(body % 8, 0, "bodyLength " + String(body) + " not padded to 8")
        if msg.header_tag == MESSAGE_HEADER_RECORD_BATCH:
            _check_body_buffers(buf, pos + 8 + meta, body, r, msg.header_table_pos)
        elif msg.header_tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            var db = read_dictionary_batch(r, msg.header_table_pos)
            _check_body_buffers(buf, pos + 8 + meta, body, r, db.data_table_pos)
        out.append(_Msg(offset=pos, meta_len=8 + meta, body_len=body, tag=msg.header_tag))
        pos += 8 + meta + body
    assert_false(eos, "stream ended without EOS")
    assert_equal(pos, end, "messages overrun the footer")
    return out^


def _check_blocks(msgs: List[_Msg], tag: UInt8, blocks: List[Block]) raises:
    var j = 0
    for i in range(len(msgs)):
        if msgs[i].tag != tag:
            continue
        assert_true(j < len(blocks))
        assert_equal(Int(blocks[j].offset), msgs[i].offset)
        assert_equal(Int(blocks[j].meta_data_length), msgs[i].meta_len)
        assert_equal(Int(blocks[j].body_length), msgs[i].body_len)
        j += 1
    assert_equal(j, len(blocks))


def _frame(buf: SharedAlignedBuffer[HeapRegion], blk: Block) raises -> SharedAlignedBuffer[HeapRegion]:
    return _slice(buf, Int(blk.offset), Int(blk.meta_data_length) + Int(blk.body_length))


def _rb_codec(frame: SharedAlignedBuffer[HeapRegion]) raises -> Int8:
    var md = _slice(frame, 8, Int(frame.read_u32_le_at(4)))
    var r = flatbuf_reader_over(md)
    var msg = read_message(r, r.read_root_offset())
    return read_record_batch(r, msg.header_table_pos).body_compression_codec


def _footer_start(buf: SharedAlignedBuffer[HeapRegion]) raises -> Int:
    var n = buf.len()
    var magic: List[UInt8] = [0x41, 0x52, 0x52, 0x4F, 0x57, 0x31]
    for i in range(6):
        assert_equal(buf.read_u8_at(i), magic[i])
        assert_equal(buf.read_u8_at(n - 6 + i), magic[i])
    assert_equal(buf.read_u8_at(6), UInt8(0))
    assert_equal(buf.read_u8_at(7), UInt8(0))
    var flen = Int(buf.read_i32_le_at(n - 10))
    assert_true(flen > 0 and flen <= n - 18)
    return n - 10 - flen


@fieldwise_init
struct _DictBatch(Movable):
    var id: Int64
    var is_delta: Bool
    var values: List[String]


def _read_dict_batch(var frame: SharedAlignedBuffer[HeapRegion]) raises -> _DictBatch:
    """id, isDelta and values of a DictionaryBatch; an LZ4 or ZSTD body is
    decompressed first with komira's dictionary decompressor."""
    var codec = peek_dictionary_batch_codec_from_frame(frame)
    if codec == Int8(0):
        frame = decompress_dictionary_batch_frame[Lz4Frame](frame^)
    elif codec == Int8(1):
        frame = decompress_dictionary_batch_frame[Zstd[3]](frame^)
    var f = parse_ipc_message(frame)
    var md = _slice(frame, f.metadata_pos, f.metadata_size)
    var r = flatbuf_reader_over(md)
    var msg = read_message(r, r.read_root_offset())
    assert_equal(msg.header_tag, MESSAGE_HEADER_DICTIONARY_BATCH)
    var db = read_dictionary_batch(r, msg.header_table_pos)
    var rb = read_record_batch(r, db.data_table_pos)
    assert_equal(rb.body_compression_codec, Int8(-1))
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


def _placeholders(n: Int) -> Slab[Column[HeapRegion]]:
    var s = Slab[Column[HeapRegion]]()
    for _ in range(n):
        s.append(Column[HeapRegion]())
    return s^


def _strings(vals: List[String]) raises -> Column[HeapRegion]:
    return Column.from_string(StringArray.from_strings(vals))


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


def test_file_round_trip_mixed_codecs() raises:
    """Five batches: uncompressed (7 rows), LZ4 (13), uncompressed (1), ZSTD
    (5), uncompressed (0). Every batch reads back cell-for-cell."""
    var rows: List[Int] = [7, 13, 1, 5, 0]
    var codecs: List[Int8] = [-1, 0, -1, 1, -1]
    var schema = _schema()
    var out = List[UInt8]()
    _append(out, arrow_ipc_file_magic_header())
    _append(out, encode_schema_message(schema))
    var blocks = List[Block]()
    var base = 0
    for k in range(len(rows)):
        var cols = _columns(rows[k], base)
        var frame: SharedAlignedBuffer[HeapRegion]
        if codecs[k] == Int8(0):
            frame = encode_record_batch_message_compressed[Lz4Frame](cols^)
        elif codecs[k] == Int8(1):
            frame = encode_record_batch_message_compressed[Zstd[3]](cols^)
        else:
            frame = encode_record_batch_message(cols^)
        blocks.append(_block_for(len(out), frame))
        _append(out, frame)
        base += rows[k]
    _append(out, encode_footer_message(schema, List[Block](), blocks.copy()))
    var path = _scratch("mixed.arrow")
    _write_file(path, out)

    # ---- read it back through the File path ----
    var buf = _to_buf(out)
    var fstart = _footer_start(buf)
    var fb = _slice(buf, fstart, buf.len() - 10 - fstart)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(footer.version, Int16(4))
    assert_equal(len(footer.dictionaries), 0)
    assert_equal(len(footer.record_batches), len(rows))
    var fields = read_schema(r, footer.schema_table_pos).fields.copy()
    assert_equal(len(fields), 6)
    var names: List[String] = [String("id"), String("v"), String("f"), String("b"), String("ts"), String("s")]
    var tags: List[UInt8] = [TYPE_INT, TYPE_INT, TYPE_FLOATING_POINT, TYPE_BOOL, TYPE_TIMESTAMP, TYPE_UTF8]
    for i in range(6):
        assert_equal(fields[i].name, names[i])
        assert_equal(fields[i].type_tag, tags[i])
        assert_equal(fields[i].nullable, i != 0)
    var tsd = read_type_timestamp(r, fields[4].type_table_pos)
    assert_equal(tsd.unit, TIME_UNIT_MICROSECOND)
    assert_equal(tsd.timezone, "UTC")

    var msgs = _walk_to(buf, 8, fstart, False)
    assert_equal(len(msgs), 1 + len(rows))
    assert_equal(msgs[0].tag, MESSAGE_HEADER_SCHEMA)
    _check_blocks(msgs, MESSAGE_HEADER_RECORD_BATCH, footer.record_batches)
    # The Blocks the writer recorded are the Blocks the footer returns.
    _check_blocks(msgs, MESSAGE_HEADER_RECORD_BATCH, blocks)

    var types = List[ArrowType]()
    for i in range(schema.num_columns()):
        types.append(schema.field_arrow_type(i))
    var no_dict = List[Bool]()
    for _ in range(len(types)):
        no_dict.append(False)
    var region = ArcPointer[MmapRegion](MmapRegion.open_readonly(path))
    base = 0
    for k in range(len(rows)):
        ref blk = footer.record_batches[k]
        assert_equal(_rb_codec(_frame(buf, blk)), codecs[k])
        var what = "batch " + String(k)
        var got = decode_record_batch_message_with_dicts(
            _frame(buf, blk), types, no_dict, _placeholders(len(types))
        )
        _check_diff(_batch(_columns(rows[k], base), _schema()), _batch(got^, _schema()), what + " copy")
        if codecs[k] == Int8(-1):
            var mm = decode_record_batch_message_mmap(_frame(buf, blk), types, region, Int(blk.offset))
            _check_diff(_batch(_columns(rows[k], base), _schema()), _batch(mm^, _schema()), what + " mmap")
        else:
            var raised = False
            try:
                _ = decode_record_batch_message_mmap(_frame(buf, blk), types, region, Int(blk.offset))
            except e:
                raised = True
                assert_equal(
                    String(e),
                    "decode_record_batch_message_mmap: frame carries"
                    + " BodyCompression.codec="
                    + String(Int(codecs[k]))
                    + "; mmap path requires Uncompressed bodies. Caller should"
                    + " fall back to copy-on-read path for compressed frames.",
                )
            assert_true(raised, what + ": mmap must refuse a compressed body")
        base += rows[k]


def _dict_schema() raises -> Schema:
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field.dictionary("k", ArrowType.INT32, True))
    return sb.build()


def _read_schema_out() -> Schema:
    """What the dictionary column decodes to: its value type."""
    var sb = SchemaBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    sb.add_field(Field("k", ArrowType.STRING, True))
    return sb.build()


def _dict_cols(base: Int, idx: List[Int], var dictionary: List[String]) raises -> Slab[Column[HeapRegion]]:
    """id = base + i; k = dictionary[idx[i]], NULL where idx[i] < 0."""
    var n = len(idx)
    var ids = PrimitiveArray[DType.int64].allocate(n)
    var codes = PrimitiveArray[DType.int32].allocate_nullable(n)
    for i in range(n):
        ids.set(i, Int64(base + i))
        if idx[i] < 0:
            codes._set_null(i)
        else:
            codes.set(i, Int32(idx[i]))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](ids^))
    cols.append(Column.from_dictionary(StringDictionaryArray.from_parts(codes^, StringArray.from_strings(dictionary))))
    return cols^


def _expected_dict_batch(base: Int, idx: List[Int], dictionary: List[String]) raises -> RecordBatch:
    var n = len(idx)
    var ids = List[Int64]()
    var vals = List[String]()
    var valid = List[Bool]()
    for i in range(n):
        ids.append(Int64(base + i))
        valid.append(idx[i] >= 0)
        vals.append(dictionary[idx[i]].copy() if idx[i] >= 0 else String(""))
    var cols = Slab[Column[HeapRegion]]()
    cols.append(Column.from_primitive[DType.int64](PrimitiveArray[DType.int64].from_list(ids)))
    cols.append(Column.from_string(StringArray.from_strings_with_validity(vals, valid)))
    return _batch(cols^, _read_schema_out())


def test_file_round_trip_dictionary() raises:
    """A File with one DictionaryBatch (id = the column index, 1) and two
    batches of indices, one with a null. The footer's dictionary Block names
    the DictionaryBatch; both batches resolve through it."""
    var dictionary: List[String] = [String("red"), String("green"), String("blue"), String("cyan"), String("magenta")]
    var idx1: List[Int] = [0, 1, 2, 3, 4, 0, -1]
    var idx2: List[Int] = [4, 4, 1]
    var schema = _dict_schema()
    var out = List[UInt8]()
    _append(out, arrow_ipc_file_magic_header())
    _append(out, encode_schema_message(schema))
    var dict_frame = encode_dictionary_batch_message_from_string_column(
        Int64(1), _strings(dictionary), is_delta=False
    )
    var dict_blocks = List[Block]()
    dict_blocks.append(_block_for(len(out), dict_frame))
    _append(out, dict_frame)
    var rb_blocks = List[Block]()
    var f1 = encode_record_batch_message(_dict_cols(0, idx1, dictionary.copy()))
    rb_blocks.append(_block_for(len(out), f1))
    _append(out, f1)
    var f2 = encode_record_batch_message(_dict_cols(7, idx2, dictionary.copy()))
    rb_blocks.append(_block_for(len(out), f2))
    _append(out, f2)
    _append(out, encode_footer_message(schema, dict_blocks.copy(), rb_blocks.copy()))

    var buf = _to_buf(out)
    var fstart = _footer_start(buf)
    var fb = _slice(buf, fstart, buf.len() - 10 - fstart)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    assert_equal(len(footer.dictionaries), 1)
    assert_equal(len(footer.record_batches), 2)
    var fields = read_schema(r, footer.schema_table_pos).fields.copy()
    assert_equal(len(fields), 2)
    assert_equal(fields[1].name, "k")
    assert_equal(fields[1].type_tag, TYPE_UTF8)
    if not fields[1].dictionary_encoding:
        raise Error("k must carry a DictionaryEncoding")
    var enc = fields[1].dictionary_encoding.value().copy()
    assert_equal(enc.id, Int64(1))
    assert_equal(enc.index_type_bit_width, 32)
    var msgs = _walk_to(buf, 8, fstart, False)
    assert_equal(len(msgs), 4)
    assert_equal(msgs[1].tag, MESSAGE_HEADER_DICTIONARY_BATCH)
    _check_blocks(msgs, MESSAGE_HEADER_DICTIONARY_BATCH, footer.dictionaries)
    _check_blocks(msgs, MESSAGE_HEADER_RECORD_BATCH, footer.record_batches)

    var d = _read_dict_batch(_frame(buf, footer.dictionaries[0]))
    assert_equal(d.id, enc.id)
    assert_false(d.is_delta)
    var types = List[ArrowType]()
    types.append(ArrowType.INT64)
    types.append(ArrowType.STRING)
    var is_dict: List[Bool] = [False, True]
    var widths: List[Int] = [32, 32]
    var bases: List[Int] = [0, 7]
    for k in range(2):
        var values = Slab[Column[HeapRegion]]()
        values.append(Column[HeapRegion]())
        values.append(_strings(d.values))
        var got = decode_record_batch_message_with_dicts(
            _frame(buf, footer.record_batches[k]), types, is_dict, values^, widths
        )
        var want = _expected_dict_batch(bases[k], idx1 if k == 0 else idx2, dictionary)
        _check_diff(want, _batch(got^, _read_schema_out()), "dict batch " + String(k))


def test_stream_dictionary_delta_and_replacement() raises:
    """A stream whose dictionary (id 0) is built p, q; then extended by an LZ4
    delta r; then REPLACED by s, t. Batches [0 1 1], [2 0], [1 0 1] resolve to
    [p q q], [r p], [t s t]: the delta appends, the replacement discards."""
    var sb = SchemaBuilder()
    sb.add_field(Field.dictionary("k", ArrowType.INT32, True))
    var schema = sb.build()
    var first: List[String] = [String("p"), String("q")]
    var delta: List[String] = [String("r")]
    var repl: List[String] = [String("s"), String("t")]
    var full: List[String] = [String("p"), String("q"), String("r")]
    var out = List[UInt8]()
    _append(out, encode_schema_message(schema))
    _append(out, encode_dictionary_batch_message_from_string_column(Int64(0), _strings(first), is_delta=False))
    var b1: List[Int] = [0, 1, 1]
    var c1 = _dict_cols(0, b1, first.copy())
    _ = c1.take_at(0)
    _append(out, encode_record_batch_message(c1^))
    _append(
        out,
        encode_dictionary_batch_message_from_string_column_compressed[Lz4Frame](
            Int64(0), _strings(delta), is_delta=True
        ),
    )
    var b2: List[Int] = [2, 0]
    var c2 = _dict_cols(0, b2, full.copy())
    _ = c2.take_at(0)
    _append(out, encode_record_batch_message(c2^))
    _append(out, encode_dictionary_batch_message_from_string_column(Int64(0), _strings(repl), is_delta=False))
    var b3: List[Int] = [1, 0, 1]
    var c3 = _dict_cols(0, b3, repl.copy())
    _ = c3.take_at(0)
    _append(out, encode_record_batch_message(c3^))
    _append(out, arrow_ipc_eos_bytes())

    var buf = _to_buf(out)
    var msgs = _walk_to(buf, 0, buf.len(), True)
    assert_equal(len(msgs), 7)
    var want: List[List[String]] = [
        [String("p"), String("q"), String("q")],
        [String("r"), String("p")],
        [String("t"), String("s"), String("t")],
    ]
    var want_delta: List[Bool] = [False, True, False]
    var dictionary = List[String]()
    var n_dict = 0
    var n_rb = 0
    var types = List[ArrowType]()
    types.append(ArrowType.STRING)
    var is_dict: List[Bool] = [True]
    for i in range(1, len(msgs)):
        var frame = _slice(buf, msgs[i].offset, msgs[i].meta_len + msgs[i].body_len)
        if msgs[i].tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            var d = _read_dict_batch(frame^)
            assert_equal(d.id, Int64(0))
            assert_equal(d.is_delta, want_delta[n_dict])
            if not d.is_delta:
                dictionary.clear()
            for j in range(len(d.values)):
                dictionary.append(d.values[j].copy())
            n_dict += 1
            continue
        var values = Slab[Column[HeapRegion]]()
        values.append(_strings(dictionary))
        var cols = decode_record_batch_message_with_dicts(frame^, types, is_dict, values^)
        assert_equal(cols[0]._length, len(want[n_rb]))
        for j in range(len(want[n_rb])):
            assert_equal(cols[0].utf8_value_at(j), want[n_rb][j])
        n_rb += 1
    assert_equal(n_dict, 3)
    assert_equal(n_rb, 3)


# ---------------------------------------------------------------------------
# Edges of the same read path: legacy framing, NULL columns, and the refusals
# ---------------------------------------------------------------------------


def _two_col_frame() raises -> SharedAlignedBuffer[HeapRegion]:
    """A 3-row (NULL, INT64) RecordBatch frame; the NULL column has no buffers."""
    var ids = PrimitiveArray[DType.int64].from_list([Int64(5), Int64(6), Int64(7)])
    var cols = Slab[Column[HeapRegion]]()
    cols.append(
        Column[HeapRegion](
            arrow_type=ArrowType.NULL,
            data=OwnedAlignedBuffer(0),
            offsets=None,
            validity=None,
            length=3,
            null_count=3,
            offset=0,
        )
    )
    cols.append(Column.from_primitive[DType.int64](ids^))
    return encode_record_batch_message(cols^)


def _null_int64_types() -> List[ArrowType]:
    var t = List[ArrowType]()
    t.append(ArrowType.NULL)
    t.append(ArrowType.INT64)
    return t^


def _expect_raise(var frame: SharedAlignedBuffer[HeapRegion], types: List[ArrowType], n_slots: Int, want: String) raises:
    """The copy decoder raises, and with exactly `want`: the whole message, so
    an earlier check that fires for a different reason fails the case."""
    var no_dict = List[Bool]()
    for _ in range(len(types)):
        no_dict.append(False)
    var raised = False
    try:
        _ = decode_record_batch_message_with_dicts(frame^, types, no_dict, _placeholders(n_slots))
    except e:
        raised = True
        assert_equal(String(e), want)
    assert_true(raised, "decode must raise: " + want)


def test_null_column_and_legacy_framing() raises:
    """A NULL column decodes to `length` nulls from zero buffers, in both the
    copy and the mmap decoder. The same frame re-framed without the 0xFFFFFFFF
    continuation marker (the pre-1.0 encapsulation, still legal to read)
    decodes identically."""
    var frame = _two_col_frame()
    # Spec layout of the frame komira wrote: no buffers for NULL, two for INT64.
    var md = _slice(frame, 8, Int(frame.read_u32_le_at(4)))
    var r = flatbuf_reader_over(md)
    var rb = read_record_batch(r, read_message(r, r.read_root_offset()).header_table_pos)
    assert_equal(len(rb.nodes), 2)
    assert_equal(len(rb.buffers), 2)
    assert_equal(rb.nodes[0].null_count, Int64(3))

    var legacy = _slice(frame, 4, frame.len() - 4)
    var types = _null_int64_types()
    for k in range(2):
        var f: SharedAlignedBuffer[HeapRegion]
        if k == 0:
            f = _slice(frame, 0, frame.len())
        else:
            f = _slice(legacy, 0, legacy.len())
        var no_dict: List[Bool] = [False, False]
        var cols = decode_record_batch_message_with_dicts(f^, types, no_dict, _placeholders(2))
        assert_equal(cols[0].arrow_type, ArrowType.NULL)
        assert_equal(cols[0]._length, 3)
        assert_equal(cols[0]._null_count, 3)
        for i in range(3):
            assert_equal(cols[1]._data.read_i64_le_at(i * 8), Int64(5 + i))

    var bytes = List[UInt8]()
    _append(bytes, frame)
    var path = _scratch("null_col.bin")
    _write_file(path, bytes)
    var region = ArcPointer[MmapRegion](MmapRegion.open_readonly(path))
    var mm = decode_record_batch_message_mmap(_slice(frame, 0, frame.len()), types, region, 0)
    assert_equal(mm[0].arrow_type, ArrowType.NULL)
    assert_equal(mm[0]._length, 3)
    assert_equal(mm[0]._null_count, 3)
    for i in range(3):
        assert_equal(mm[1]._data.read_i64_le_at(i * 8), Int64(5 + i))


def test_read_path_refusals() raises:
    """Each refusal on this read path raises its full message instead of
    returning columns: a schema with fewer columns than the batch (FieldNode
    count), fewer dictionary slots than columns, a DictionaryBatch handed to
    the RecordBatch decoder (refused by the codec peek that runs before the
    decoder's own header check), an index past the end of its dictionary, and
    a nested type given to the mmap decoder (refused by the flat count helper;
    see the comment at that case)."""
    var too_few = List[ArrowType]()
    too_few.append(ArrowType.INT64)
    _expect_raise(
        _two_col_frame(),
        too_few,
        1,
        "decode_record_batch_message_with_dicts: FieldNode count mismatch (got 2, expected 1)",
    )
    _expect_raise(
        _two_col_frame(),
        _null_int64_types(),
        1,
        "decode_record_batch_message_with_dicts: dict_values has only 1 entries"
        " but the schema has 2 columns (one slot per column is required —"
        " placeholder Columns for non-dict columns)",
    )

    var dict_vals: List[String] = [String("a"), String("b")]
    var dict_frame = encode_dictionary_batch_message_from_string_column(
        Int64(0), _strings(dict_vals), is_delta=False
    )
    var str_types = List[ArrowType]()
    str_types.append(ArrowType.STRING)
    # Tag 2 is DictionaryBatch, 3 RecordBatch. The codec peek in front of the
    # decoder parses the header first, so its message is the one raised.
    _expect_raise(
        dict_frame^,
        str_types,
        1,
        "peek_record_batch_codec_from_frame: expected RECORD_BATCH header (tag 3), got 2",
    )

    # Index 2 against a two-entry dictionary.
    var idx: List[Int] = [0, 2]
    var cols = _dict_cols(0, idx, [String("a"), String("b"), String("c")])
    _ = cols.take_at(0)
    var rb_frame = encode_record_batch_message(cols^)
    var values = Slab[Column[HeapRegion]]()
    values.append(_strings(dict_vals))
    var is_dict: List[Bool] = [True]
    var raised = False
    try:
        _ = decode_record_batch_message_with_dicts(rb_frame^, str_types, is_dict, values^)
    except e:
        raised = True
        assert_equal(String(e), "expand_dict_indices_to_string: index 2 at row 1 out of range [0, 2)")
    assert_true(raised, "an index past the dictionary must raise")

    # A nested type on the mmap path. decode_record_batch_message_mmap ends its
    # per-column loop with its own "nested types are not" refusal, but no
    # schema reaches it: the count pass before the loop calls _node_count_for
    # on every column, which raises for any type outside NULL, BOOL, the four
    # var-len types, DICTIONARY and the fixed-width types, and the loop has an
    # arm for each of those. So the refusal pinned here is _node_count_for's
    # (type id 20 is LIST), and the frame needs no LIST layout to reach it.
    var list_types = List[ArrowType]()
    list_types.append(ArrowType.LIST)
    list_types.append(ArrowType.INT64)
    var frame = _two_col_frame()
    var bytes = List[UInt8]()
    _append(bytes, frame)
    var path = _scratch("refuse.bin")
    _write_file(path, bytes)
    var region = ArcPointer[MmapRegion](MmapRegion.open_readonly(path))
    raised = False
    try:
        _ = decode_record_batch_message_mmap(frame^, list_types, region, 0)
    except e:
        raised = True
        assert_equal(
            String(e),
            "_node_count_for: ArrowType 20 not supported in the flat decoder"
            " (nested types go through decode_record_batch_message_nested)",
        )
    assert_true(raised, "mmap must refuse a nested type (via _node_count_for)")


def test_zstd_dictionary_batch() raises:
    """A ZSTD-compressed DictionaryBatch: the codec is visible without
    decoding, and the values survive komira's decompressor."""
    var vals: List[String] = [String("alpha"), String("beta"), String("gamma")]
    var frame = encode_dictionary_batch_message_from_string_column_compressed[Zstd[3]](
        Int64(4), _strings(vals), is_delta=True
    )
    assert_equal(peek_dictionary_batch_codec_from_frame(frame), Int8(1))
    var d = _read_dict_batch(frame^)
    assert_equal(d.id, Int64(4))
    assert_true(d.is_delta)
    assert_equal(len(d.values), 3)
    for i in range(3):
        assert_equal(d.values[i], vals[i])


def main() raises:
    var suite = TestSuite()
    suite.test[test_file_round_trip_mixed_codecs]()
    suite.test[test_file_round_trip_dictionary]()
    suite.test[test_stream_dictionary_delta_and_replacement]()
    suite.test[test_null_column_and_legacy_framing]()
    suite.test[test_read_path_refusals]()
    suite.test[test_zstd_dictionary_batch]()
    suite^.run()
