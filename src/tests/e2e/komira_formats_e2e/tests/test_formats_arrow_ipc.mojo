# =============================================================================
# The dataset and the numeric edges through Arrow IPC File and Stream, on disk.
# =============================================================================
#
# Writer: komira_arrow_ipc's message encoders strung into a File or a Stream
# by `IpcAssembly` (the package's fixture; komira ships no IPC file or stream
# writer, only the encoders and framing pieces), written through LocalFs.
# Reader: LocalFs (`file_size`, `read_footer`, `read_whole`, `read_range`),
# komira_arrow_ipc's flatbuffer readers (`read_message`, `read_footer`,
# `read_schema`, `read_record_batch`) and its RecordBatch decoders: the copy
# decoder `decode_record_batch_message` on every batch and, for the File, the
# mmap decoder `decode_record_batch_message_mmap` too. No file or stream
# reader exists either; the framing walk below is the test's own, from the
# spec.
#
# Two oracles, so a writer and reader that agree on a wrong encoding do not
# pass:
#   1. The read-back: every value and every NULL position of the source rows
#      (`dataset.mojo`: NULLs in every column, 2-, 3- and 4-byte UTF-8, an
#      empty string kept apart from NULL, 2^53 + 1) and of the edge numerics
#      (integer limits; -0.0, subnormals, +-Inf and NaN payloads by bit
#      pattern), exactly.
#   2. The bytes. Checked by hand against the Arrow columnar spec
#      (format/Columnar.rst), never against komira's output:
#        * File: "ARROW1" + 2 zero pad bytes first; "ARROW1" last; the int32
#          LE before it (the Footer size), read from the tail
#          LocalFs.read_footer returns;
#        * every message starts 8-aligned with the continuation marker
#          0xFFFFFFFF and an int32 metadata size that is a multiple of 8,
#          and the messages tile the stream exactly up to the EOS marker
#          0xFFFFFFFF 0x00000000 (the Stream's last 8 bytes; the File's last
#          8 before the Footer);
#        * the body bytes: validity bitmaps LSB-first, bit i set iff row i
#          is not NULL (a Buffer of length 0 accepted only when null_count
#          is 0); INT64 and DOUBLE values as 8 little-endian bytes (spelled
#          with `le_bytes` from the source values); Utf8 int32 offsets,
#          non-decreasing, each non-NULL slot exactly its UTF-8 bytes (the
#          empty string a zero-length slot); Bool values bit-packed
#          LSB-first.
#      Read through komira's own flatbuffer readers (`read_message`,
#      `read_record_batch`, `read_footer`, `read_schema`, `read_type_*`) and
#      then compared with the spec's rules or the source: the Message
#      version (V5) and bodyLength (a multiple of 8, inside the stream); the
#      FieldNodes (length, null_count); the Buffers (8-aligned, inside
#      bodyLength), which locate the bytes above; the Footer version and
#      Blocks (equal to the walked messages, metaDataLength counting the
#      8-byte prefix); the schema (names, Int 64/32 signed, FloatingPoint
#      DOUBLE, Utf8, Bool, nullability). A defect in those readers that
#      agreed with the encoder would pass here; komira_arrow_ipc's own
#      tests read pyarrow-written files through them.
#
# Defects this reds on (each planted alone and seen red on the farm): the
# assembly recording Block.metaDataLength without the 8-byte prefix ("Footer
# Block 0 (264, 296, 192) is not the RecordBatch message at (264, 304,
# 192)"); a validity bit flipped in the written bytes (the bit pin and the
# copy and mmap read-backs all name the row). A copy decoder reading each
# validity bitmap one byte late is caught first by komira_arrow_ipc's own
# tests, so this package does not build under it.
#
# What this cannot see: no IPC bytes written by another implementation are
# read here (komira_arrow_ipc's own tests read pyarrow's files); NULL slots'
# value bytes are not pinned (the spec leaves them undefined).
# =============================================================================

from std.memory import ArcPointer, bitcast
from std.os import makedirs

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow_ipc.ipc_decoder_dispatch import (
    decode_record_batch_message,
    decode_record_batch_message_mmap,
)
from komira_arrow_ipc.ipc_flatbuf import (
    Block,
    FieldDescriptor,
    FlatbufReader,
    RecordBatchDescriptor,
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
)
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.heap_region import HeapRegion
from komira_buffer.mmap_region import MmapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_fs.local_fs import LocalFs
from komira_runtime_paths import test_tmpdir

from komira_formats_e2e import (
    IpcAssembly,
    Mismatches,
    batch_for_city,
    bits_of,
    check_bytes,
    check_float_column_bits,
    check_int_column,
    city_oslo,
    city_zurich,
    column_index,
    flag_at,
    float_edge_batch,
    float_edge_bits,
    id_at,
    int32_edges,
    int64_edges,
    int_edge_batch,
    le_bytes,
    name_at,
    rows_of,
    score_at,
    write_ipc,
)


comptime _Fs = LocalFs[NoopSink]
comptime _MESSAGE_V5 = Int16(4)  # Schema.fbs MetadataVersion.V5


def _root() raises -> String:
    var root = test_tmpdir() + "/formats_e2e_ipc"
    makedirs(root, exist_ok=True)
    return root^


def _arrow1() -> List[UInt8]:
    return [0x41, 0x52, 0x52, 0x4F, 0x57, 0x31]  # "ARROW1"


def _bytes_at(buf: SharedAlignedBuffer[HeapRegion], start: Int, n: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(n):
        out.append(buf.read_u8_at(start + i))
    return out^


def _slice(
    src: SharedAlignedBuffer[HeapRegion], start: Int, n: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    if start < 0 or n < 0 or start + n > src.len():
        raise Error("slice [" + String(start) + ", +" + String(n) + ") outside " + String(src.len()))
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(n, 1))
    if n > 0:
        out.copy_from_view_at(0, src.view_range_ro(start, n))
    out.set_length(n)
    return out^


def _bit(buf: SharedAlignedBuffer[HeapRegion], pos: Int, i: Int) -> Bool:
    """Bit i of the bitmap at `pos`, LSB-first within each byte (spec)."""
    return ((Int(buf.read_u8_at(pos + (i >> 3))) >> (i & 7)) & 1) == 1


# =============================================================================
# The framing walk, from the spec.
# =============================================================================


@fieldwise_init
struct _Msg(Copyable, Movable):
    var offset: Int
    var meta_len: Int  # 8-byte prefix + padded flatbuffer
    var body_len: Int
    var tag: UInt8


def _walk(
    buf: SharedAlignedBuffer[HeapRegion], start: Int, end: Int, label: String
) raises -> List[_Msg]:
    """The messages in [start, end), which must tile it exactly and end with
    the EOS marker as its last 8 bytes. Returns the messages before EOS."""
    var out = List[_Msg]()
    var pos = start
    while pos + 8 <= end:
        var at = label + " message at " + String(pos)
        if pos % 8 != 0:
            raise Error(at + ": not 8-aligned")
        if buf.read_u32_le_at(pos) != UInt32(0xFFFFFFFF):
            raise Error(at + ": no continuation marker 0xFFFFFFFF")
        var meta = Int(buf.read_i32_le_at(pos + 4))
        if meta == 0:
            if pos + 8 != end:
                raise Error(at + ": EOS marker with " + String(end - pos - 8) + " bytes after it")
            return out^
        if meta < 0 or meta % 8 != 0 or pos + 8 + meta > end:
            raise Error(at + ": metadata size " + String(meta) + " not a multiple of 8 inside the stream")
        var md = _slice(buf, pos + 8, meta)
        var r = flatbuf_reader_over(md)
        var msg = read_message(r, r.read_root_offset())
        if msg.version != _MESSAGE_V5:
            raise Error(at + ": MetadataVersion " + String(msg.version) + ", want V5 (4)")
        var body = Int(msg.body_length)
        if body < 0 or body % 8 != 0 or pos + 8 + meta + body > end:
            raise Error(at + ": bodyLength " + String(body) + " not a multiple of 8 inside the stream")
        if msg.header_tag == MESSAGE_HEADER_RECORD_BATCH:
            var rb = read_record_batch(r, msg.header_table_pos)
            if rb.body_compression_codec != Int8(-1):
                raise Error(at + ": compressed body, none was asked for")
            for k in range(len(rb.buffers)):
                var off = Int(rb.buffers[k].offset)
                var ln = Int(rb.buffers[k].length)
                if ln > 0 and (off % 8 != 0 or off < 0 or off + ln > body):
                    raise Error(
                        at + ": Buffer " + String(k) + " [" + String(off) + ", +" + String(ln)
                        + ") not 8-aligned inside bodyLength " + String(body)
                    )
        out.append(_Msg(offset=pos, meta_len=8 + meta, body_len=body, tag=msg.header_tag))
        pos += 8 + meta + body
    raise Error(label + ": no EOS marker before byte " + String(end))


def _rb(buf: SharedAlignedBuffer[HeapRegion], msg: _Msg) raises -> RecordBatchDescriptor:
    var md = _slice(buf, msg.offset + 8, msg.meta_len - 8)
    var r = flatbuf_reader_over(md)
    return read_record_batch(r, read_message(r, r.read_root_offset()).header_table_pos)


def _arrow_type[
    bo: Origin[mut=False]
](r: FlatbufReader[bo], f: FieldDescriptor) raises -> ArrowType:
    if f.type_tag == TYPE_INT:
        var t = read_type_int(r, f.type_table_pos)
        if t.is_signed and t.bit_width == 64:
            return ArrowType.INT64
        if t.is_signed and t.bit_width == 32:
            return ArrowType.INT32
    elif f.type_tag == TYPE_FLOATING_POINT:
        if read_type_floating_point(r, f.type_table_pos).precision == PRECISION_DOUBLE:
            return ArrowType.FLOAT64
    elif f.type_tag == TYPE_UTF8:
        return ArrowType.STRING
    elif f.type_tag == TYPE_BOOL:
        return ArrowType.BOOL
    raise Error("field " + f.name + ": Type tag " + String(Int(f.type_tag)) + " is none this test writes")


def _schema_at[
    bo: Origin[mut=False]
](r: FlatbufReader[bo], table_pos: Int) raises -> Schema:
    var sd = read_schema(r, table_pos)
    var sb = SchemaBuilder()
    for i in range(len(sd.fields)):
        sb.add_field(Field(sd.fields[i].name, _arrow_type(r, sd.fields[i]), sd.fields[i].nullable))
    return sb.build()


def _schema_message(buf: SharedAlignedBuffer[HeapRegion], msg: _Msg, label: String) raises -> Schema:
    if msg.tag != MESSAGE_HEADER_SCHEMA:
        raise Error(label + ": first message has header " + String(Int(msg.tag)) + ", want Schema (1)")
    var md = _slice(buf, msg.offset + 8, msg.meta_len - 8)
    var r = flatbuf_reader_over(md)
    return _schema_at(r, read_message(r, r.read_root_offset()).header_table_pos)


def _check_schema(got: Schema, want: Schema, label: String) raises:
    var ok = got.num_columns() == want.num_columns()
    if ok:
        for i in range(want.num_columns()):
            ok = ok and got.field_name(i) == want.field_name(i)
            ok = ok and got.field_arrow_type(i) == want.field_arrow_type(i)
            ok = ok and got.field_nullable(i) == want.field_nullable(i)
    if not ok:
        raise Error(label + ": schema " + String(got) + ", want " + String(want))


struct _IpcRead(Movable):
    """A File or Stream read back through LocalFs, its framing checked."""

    var bytes: SharedAlignedBuffer[HeapRegion]
    var msgs: List[_Msg]  # Schema, then the RecordBatches; EOS excluded
    var blocks: List[Block]  # the Footer's record batch Blocks (File only)
    var schema: Schema

    def __init__(
        out self,
        var bytes: SharedAlignedBuffer[HeapRegion],
        var msgs: List[_Msg],
        var blocks: List[Block],
        var schema: Schema,
    ):
        self.bytes = bytes^
        self.msgs = msgs^
        self.blocks = blocks^
        self.schema = schema^


def _read_file(path: String, want: Schema, n_batches: Int) raises -> _IpcRead:
    var label = String("file ") + path
    var fs = _Fs.new()
    var size = fs.file_size(path)
    # The tail as a columnar reader fetches it first (the whole small file).
    var tail = fs.read_footer(path, 64 * 1024)
    if tail.file_size != size or tail.offset != 0 or len(tail.bytes) != size:
        raise Error(label + ": read_footer returned [" + String(tail.offset) + ", +" + String(len(tail.bytes)) + ") of " + String(tail.file_size))
    var m = Mismatches()
    check_bytes(m, Span(tail.bytes)[size - 6 : size], Span(_arrow1()), label + " trailing magic")
    # FOOTER SIZE: int32 little-endian, assembled from the bytes by hand.
    var flen = 0
    for k in range(4):
        flen |= Int(tail.bytes[size - 10 + k]) << (8 * k)
    var whole = fs.read_whole(path)
    check_bytes(m, Span(_bytes_at(whole, 0, 6)), Span(_arrow1()), label + " leading magic")
    var pad: List[UInt8] = [0, 0]
    check_bytes(m, Span(_bytes_at(whole, 6, 2)), Span(pad), label + " magic padding")
    m.raise_if_any(label)
    var fstart = size - 10 - flen
    if flen <= 0 or fstart < 8:
        raise Error(label + ": footer size " + String(flen) + " leaves no stream")

    var msgs = _walk(whole, 8, fstart, label)
    var fb = _slice(whole, fstart, flen)
    var r = flatbuf_reader_over(fb)
    var footer = read_footer(r, r.read_root_offset())
    if footer.version != _MESSAGE_V5:
        raise Error(label + ": Footer version " + String(footer.version))
    if len(footer.dictionaries) != 0:
        raise Error(label + ": dictionary Blocks in a file with no dictionaries")
    if len(msgs) != 1 + n_batches or len(footer.record_batches) != n_batches:
        raise Error(
            label + ": " + String(len(msgs)) + " messages, " + String(len(footer.record_batches))
            + " Footer Blocks; want 1 + " + String(n_batches) + ", " + String(n_batches)
        )
    var schema = _schema_message(whole, msgs[0], label)
    _check_schema(schema, want, label + " Schema message")
    _check_schema(_schema_at(r, footer.schema_table_pos), want, label + " Footer schema")
    for k in range(n_batches):
        ref b = footer.record_batches[k]
        ref w = msgs[1 + k]
        if w.tag != MESSAGE_HEADER_RECORD_BATCH or Int(b.offset) != w.offset or Int(b.meta_data_length) != w.meta_len or Int(b.body_length) != w.body_len:
            raise Error(
                label + ": Footer Block " + String(k) + " (" + String(b.offset) + ", " + String(b.meta_data_length)
                + ", " + String(b.body_length) + ") is not the RecordBatch message at (" + String(w.offset)
                + ", " + String(w.meta_len) + ", " + String(w.body_len) + ")"
            )
    return _IpcRead(whole^, msgs^, footer.record_batches.copy(), schema^)


def _read_stream(path: String, want: Schema, n_batches: Int) raises -> _IpcRead:
    var label = String("stream ") + path
    var whole = _Fs.new().read_whole(path)
    var n = whole.len()
    var m = Mismatches()
    # A stream opens with a message, not the File magic, and closes with EOS.
    var cont: List[UInt8] = [0xFF, 0xFF, 0xFF, 0xFF]
    check_bytes(m, Span(_bytes_at(whole, 0, 4)), Span(cont), label + " first bytes")
    var eos: List[UInt8] = [0xFF, 0xFF, 0xFF, 0xFF, 0, 0, 0, 0]
    check_bytes(m, Span(_bytes_at(whole, n - 8, 8)), Span(eos), label + " EOS marker")
    m.raise_if_any(label)
    var msgs = _walk(whole, 0, n, label)
    if len(msgs) != 1 + n_batches:
        raise Error(label + ": " + String(len(msgs)) + " messages, want 1 + " + String(n_batches))
    var schema = _schema_message(whole, msgs[0], label)
    _check_schema(schema, want, label + " Schema message")
    for k in range(n_batches):
        if msgs[1 + k].tag != MESSAGE_HEADER_RECORD_BATCH:
            raise Error(label + ": message " + String(1 + k) + " is not a RecordBatch")
    return _IpcRead(whole^, msgs^, List[Block](), schema^)


def _types(schema: Schema) -> List[ArrowType]:
    var out = List[ArrowType]()
    for i in range(schema.num_columns()):
        out.append(schema.field_arrow_type(i))
    return out^


def _batch(var cols: Slab[Column[HeapRegion]], schema: Schema) raises -> RecordBatch:
    var bb = RecordBatchBuilder.with_capacity(len(cols))
    while len(cols) > 0:
        bb.add_column(cols.take_at(0))
    return bb.build(schema.copy())


def _decode(f: _IpcRead, k: Int) raises -> RecordBatch:
    """RecordBatch k, copied out of the bytes read and decoded by copy."""
    ref w = f.msgs[1 + k]
    return _batch(
        decode_record_batch_message(_slice(f.bytes, w.offset, w.meta_len + w.body_len), _types(f.schema)),
        f.schema,
    )


def _decode_mmap(path: String, f: _IpcRead, k: Int) raises -> RecordBatch:
    """RecordBatch k of a File, its frame read at the Footer Block's range
    through LocalFs.read_range, decoded by the mmap decoder."""
    ref b = f.blocks[k]
    var off = Int(b.offset)
    var frame = _Fs.new().read_range(path, off, Int(b.meta_data_length) + Int(b.body_length))
    var region = ArcPointer[MmapRegion](MmapRegion.open_readonly(path))
    return _batch(decode_record_batch_message_mmap(frame^, _types(f.schema), region, off), f.schema)


# =============================================================================
# The dataset: read-back and body bytes.
# =============================================================================


def _valid(c: Int, r: Int) -> Bool:
    if c == 0:
        return Bool(id_at(r))
    if c == 1:
        return Bool(score_at(r))
    if c == 2:
        return Bool(name_at(r))
    return Bool(flag_at(r))


def _check_rows(mut m: Mismatches, batch: RecordBatch, rows: List[Int], label: String) raises:
    """Every value and NULL of the source rows, exactly (floats by bits)."""
    if batch.num_rows() != len(rows) or batch.num_columns() != 4:
        m.add(label + ": " + String(batch.num_rows()) + " rows x " + String(batch.num_columns()) + " columns")
        return
    var ids = batch.column_as_primitive_int64(column_index(batch, "id"))
    var scores = batch.column_as_primitive_float64(column_index(batch, "score"))
    var names = batch.column_as_string(column_index(batch, "name"))
    var flags = batch.column_as_boolean(column_index(batch, "flag"))
    for i in range(len(rows)):
        var r = rows[i]
        var at = label + " row " + String(r)
        var idw = id_at(r)
        if not idw:
            m.check(ids.is_null(i), at + " id: got " + String(ids.get(i)) + ", want NULL")
        elif ids.is_null(i):
            m.add(at + " id: NULL, want " + String(idw.value()))
        else:
            m.check(ids.get(i) == idw.value(), at + " id: got " + String(ids.get(i)) + ", want " + String(idw.value()))
        var sw = score_at(r)
        if not sw:
            m.check(scores.is_null(i), at + " score: got " + String(scores.get(i)) + ", want NULL")
        elif scores.is_null(i):
            m.add(at + " score: NULL, want " + String(sw.value()))
        else:
            m.check(bits_of(scores.get(i)) == bits_of(sw.value()), at + " score: got " + String(scores.get(i)) + ", want " + String(sw.value()))
        var nw = name_at(r)
        if not nw:
            m.check(names.is_null(i), at + " name: got '" + names.get(i) + "', want NULL")
        elif names.is_null(i):
            m.add(at + " name: NULL, want '" + nw.value() + "'")
        else:
            m.check(names.get(i) == nw.value(), at + " name: got '" + names.get(i) + "', want '" + nw.value() + "'")
        var fw = flag_at(r)
        if not fw:
            m.check(flags.is_null(i), at + " flag: got " + String(flags.get(i)) + ", want NULL")
        elif flags.is_null(i):
            m.add(at + " flag: NULL, want " + String(fw.value()))
        else:
            m.check(flags.get(i) == fw.value(), at + " flag: got " + String(flags.get(i)) + ", want " + String(fw.value()))


def _pin_dataset_body(
    mut m: Mismatches, buf: SharedAlignedBuffer[HeapRegion], msg: _Msg, rows: List[Int], label: String
) raises:
    """The RecordBatch body of the source rows against the spec layout:
    (id INT64, score DOUBLE, name Utf8, flag Bool) = 2 + 2 + 3 + 2 Buffers."""
    var rb = _rb(buf, msg)
    var body = msg.offset + msg.meta_len
    var n = len(rows)
    m.check(Int(rb.length) == n, label + ": RecordBatch.length " + String(rb.length) + ", want " + String(n))
    if len(rb.nodes) != 4 or len(rb.buffers) != 9:
        m.add(label + ": " + String(len(rb.nodes)) + " FieldNodes, " + String(len(rb.buffers)) + " Buffers; want 4, 9")
        return
    var cols: List[String] = [String("id"), String("score"), String("name"), String("flag")]
    var vbuf: List[Int] = [0, 2, 4, 7]
    for c in range(4):
        var at = label + " " + cols[c]
        var nulls = 0
        for i in range(n):
            if not _valid(c, rows[i]):
                nulls += 1
        m.check(Int(rb.nodes[c].length) == n, at + ": FieldNode.length " + String(rb.nodes[c].length))
        m.check(
            Int(rb.nodes[c].null_count) == nulls,
            at + ": FieldNode.null_count " + String(rb.nodes[c].null_count) + ", want " + String(nulls),
        )
        # The spec lets a writer omit the validity Buffer (length 0) only
        # when null_count is 0; a Buffer that is present must hold one bit
        # per row, each exactly the source's validity (all set if no NULLs).
        ref vb = rb.buffers[vbuf[c]]
        if vb.length == 0:
            m.check(nulls == 0, at + ": validity Buffer absent, but the column has " + String(nulls) + " NULLs")
            continue
        if Int(vb.length) < (n + 7) // 8:
            m.add(at + ": validity Buffer of " + String(vb.length) + " bytes for " + String(n) + " rows")
            continue
        for i in range(n):
            var got = _bit(buf, body + Int(vb.offset), i)
            m.check(
                got == _valid(c, rows[i]),
                at + ": validity bit " + String(i) + " (row " + String(rows[i]) + ") is " + String(got),
            )

    var want8 = List[UInt8]()
    var got8 = List[UInt8]()
    ref idb = rb.buffers[1]
    ref scb = rb.buffers[3]
    if Int(idb.length) < 8 * n or Int(scb.length) < 8 * n:
        m.add(label + ": INT64 / DOUBLE value Buffers of " + String(idb.length) + " / " + String(scb.length) + " bytes")
    else:
        for i in range(n):
            var r = rows[i]
            if id_at(r):
                got8 = _bytes_at(buf, body + Int(idb.offset) + 8 * i, 8)
                want8 = le_bytes(bitcast[DType.uint64, 1](id_at(r).value()), 8)
                check_bytes(m, Span(got8), Span(want8), label + " id value bytes row " + String(r))
            if score_at(r):
                got8 = _bytes_at(buf, body + Int(scb.offset) + 8 * i, 8)
                want8 = le_bytes(bits_of(score_at(r).value()), 8)
                check_bytes(m, Span(got8), Span(want8), label + " score value bytes row " + String(r))

    ref ob = rb.buffers[5]
    ref db = rb.buffers[6]
    if Int(ob.length) < 4 * (n + 1):
        m.add(label + " name: offsets Buffer of " + String(ob.length) + " bytes for " + String(n) + " rows")
    else:
        for i in range(n):
            var a = Int(buf.read_i32_le_at(body + Int(ob.offset) + 4 * i))
            var b = Int(buf.read_i32_le_at(body + Int(ob.offset) + 4 * (i + 1)))
            var at = label + " name row " + String(rows[i])
            if a < 0 or b < a or b > Int(db.length):
                m.add(at + ": offsets [" + String(a) + ", " + String(b) + ") outside the data Buffer")
                continue
            var nw = name_at(rows[i])
            if not nw:
                continue
            var s = nw.value()
            var sv = s.as_bytes()
            var want = List[UInt8]()
            for j in range(len(sv)):
                want.append(sv[j])
            check_bytes(m, Span(_bytes_at(buf, body + Int(db.offset) + a, b - a)), Span(want), at + " UTF-8 slot")

    ref fb = rb.buffers[8]
    if Int(fb.length) < (n + 7) // 8:
        m.add(label + " flag: values Buffer of " + String(fb.length) + " bytes")
    else:
        for i in range(n):
            var fw = flag_at(rows[i])
            if fw:
                var got = _bit(buf, body + Int(fb.offset), i)
                m.check(got == fw.value(), label + " flag value bit " + String(i) + " (row " + String(rows[i]) + ") is " + String(got))


# =============================================================================
# Tests
# =============================================================================


def test_ipc_file_dataset() raises:
    """Zürich then Oslo as two RecordBatches of one File; each read back
    through the Footer by both decoders, and its body pinned."""
    var path = _root() + "/dataset.arrow"
    var first = batch_for_city(city_zurich())
    var want = first.schema.copy()
    var ipc = IpcAssembly(first.schema.copy(), True)
    ipc.add(first^)
    ipc.add(batch_for_city(city_oslo()))
    write_ipc(path, ipc)

    var f = _read_file(path, want, 2)
    var cities: List[String] = [city_zurich(), city_oslo()]
    var m = Mismatches()
    for k in range(2):
        var rows = rows_of(cities[k])
        var label = "file " + cities[k]
        _pin_dataset_body(m, f.bytes, f.msgs[1 + k], rows, label)
        _check_rows(m, _decode(f, k), rows, label + " copy")
        _check_rows(m, _decode_mmap(path, f, k), rows, label + " mmap")
    m.raise_if_any("test_ipc_file_dataset")


def test_ipc_stream_dataset() raises:
    """The same two RecordBatches as a Stream: Schema, batches, EOS."""
    var path = _root() + "/dataset.arrows"
    var first = batch_for_city(city_zurich())
    var want = first.schema.copy()
    var ipc = IpcAssembly(first.schema.copy(), False)
    ipc.add(first^)
    ipc.add(batch_for_city(city_oslo()))
    write_ipc(path, ipc)
    # EOS is written once: a second finish raises instead of appending.
    var refused = False
    try:
        _ = ipc.finish()
    except e:
        refused = String(e).startswith("IpcAssembly.finish: already finished")
    if not refused:
        raise Error("IpcAssembly.finish: a second call did not raise")

    var f = _read_stream(path, want, 2)
    var cities: List[String] = [city_zurich(), city_oslo()]
    var m = Mismatches()
    for k in range(2):
        var rows = rows_of(cities[k])
        var label = "stream " + cities[k]
        _pin_dataset_body(m, f.bytes, f.msgs[1 + k], rows, label)
        _check_rows(m, _decode(f, k), rows, label)
    m.raise_if_any("test_ipc_stream_dataset")


def _pin_fixed_column(
    mut m: Mismatches,
    buf: SharedAlignedBuffer[HeapRegion],
    msg: _Msg,
    c: Int,
    want: List[List[UInt8]],
    label: String,
) raises:
    """Non-nullable fixed-width column c (Buffers 2c, 2c + 1): null_count 0,
    no validity bitmap or one with every bit set, and each row's value bytes
    exactly `want[row]`."""
    var rb = _rb(buf, msg)
    var body = msg.offset + msg.meta_len
    var n = len(want)
    if len(rb.nodes) <= c or len(rb.buffers) <= 2 * c + 1:
        m.add(label + ": " + String(len(rb.nodes)) + " FieldNodes, " + String(len(rb.buffers)) + " Buffers")
        return
    m.check(Int(rb.nodes[c].length) == n and rb.nodes[c].null_count == 0, label + ": FieldNode (" + String(rb.nodes[c].length) + ", " + String(rb.nodes[c].null_count) + ")")
    ref vb = rb.buffers[2 * c]
    if vb.length != 0:
        if Int(vb.length) < (n + 7) // 8:
            m.add(label + ": validity Buffer of " + String(vb.length) + " bytes")
        else:
            for i in range(n):
                m.check(_bit(buf, body + Int(vb.offset), i), label + ": validity bit " + String(i) + " clear")
    ref db = rb.buffers[2 * c + 1]
    var w = len(want[0])
    if Int(db.length) < w * n:
        m.add(label + ": value Buffer of " + String(db.length) + " bytes, want >= " + String(w * n))
        return
    for i in range(n):
        check_bytes(m, Span(_bytes_at(buf, body + Int(db.offset) + w * i, w)), Span(want[i]), label + " row " + String(i))


def test_ipc_edge_numerics() raises:
    """Integer limits and IEEE-754 edges through a File: value bytes are
    little-endian two's complement / binary64 bit patterns, and the
    read-back is exact to the bit (-0.0, subnormals, NaN payloads)."""
    var m = Mismatches()

    var ipath = _root() + "/edge_int.arrow"
    var ib = int_edge_batch()
    var iwant = ib.schema.copy()
    var ipc = IpcAssembly(ib.schema.copy(), True)
    ipc.add(ib^)
    write_ipc(ipath, ipc)
    var fi = _read_file(ipath, iwant, 1)
    var a = int64_edges()
    var b = int32_edges()
    var wa = List[List[UInt8]]()
    var wb = List[List[UInt8]]()
    var a64 = List[Int64]()
    var b64 = List[Int64]()
    for r in range(len(a)):
        wa.append(le_bytes(bitcast[DType.uint64, 1](a[r]), 8))
        wb.append(le_bytes(UInt64(bitcast[DType.uint32, 1](b[r])), 4))
        a64.append(a[r])
        b64.append(Int64(b[r]))
    _pin_fixed_column(m, fi.bytes, fi.msgs[1], 0, wa, "edge i64")
    _pin_fixed_column(m, fi.bytes, fi.msgs[1], 1, wb, "edge i32")
    var ints = _decode(fi, 0)
    check_int_column(m, ints, "i64", a64, "ipc copy")
    check_int_column(m, ints, "i32", b64, "ipc copy")
    var ints_mm = _decode_mmap(ipath, fi, 0)
    check_int_column(m, ints_mm, "i64", a64, "ipc mmap")
    check_int_column(m, ints_mm, "i32", b64, "ipc mmap")

    var fpath = _root() + "/edge_float.arrow"
    var fbatch = float_edge_batch()
    var fwant = fbatch.schema.copy()
    var ipc2 = IpcAssembly(fbatch.schema.copy(), True)
    ipc2.add(fbatch^)
    write_ipc(fpath, ipc2)
    var ff = _read_file(fpath, fwant, 1)
    var bits = float_edge_bits()
    var wf = List[List[UInt8]]()
    var wbits = List[Optional[UInt64]]()
    for r in range(len(bits)):
        wf.append(le_bytes(bits[r], 8))
        wbits.append(Optional[UInt64](bits[r]))
    _pin_fixed_column(m, ff.bytes, ff.msgs[1], 0, wf, "edge f64")
    check_float_column_bits(m, _decode(ff, 0), "f64", wbits, "ipc copy")
    check_float_column_bits(m, _decode_mmap(fpath, ff, 0), "f64", wbits, "ipc mmap")
    m.raise_if_any("test_ipc_edge_numerics")


def main() raises:
    test_ipc_file_dataset()
    test_ipc_stream_dataset()
    test_ipc_edge_numerics()
    print("test_formats_arrow_ipc: ALL PASS")
