# =============================================================================
# test_ipc_view_compression_variadic.mojo: RecordBatch.variadicBufferCounts
# survives every decompressor that rebuilds the RecordBatch metadata.
# =============================================================================
#
# Arrow Message.fbs `RecordBatch.variadicBufferCounts` holds one entry per
# BinaryView / Utf8View field, in schema order with nested fields included,
# giving the number of variadic data buffers that field contributes. A
# reader cannot split the Buffer list into columns without it.
#
# The three decompressors in ipc_body_compression.mojo re-emit the
# RecordBatch table with uncompressed Buffer offsets:
#   - decompress_record_batch_frame (serial per-batch path),
#   - decompress_all_rbs_into_with_dispatcher (coalesced multi-batch path,
#     compressed and uncompressed input arms),
#   - decompress_dictionary_batch_frame (the DictionaryBatch's inner
#     RecordBatch).
# Each case builds a frame by hand with view fields and a known
# variadicBufferCounts, runs the decompressor, decodes the output metadata
# and asserts the counts exactly; the record-batch cases then decode the
# values through `decode_record_batch_message_nested`. If a decompressor
# drops the field, the counts assertion fails with an empty list.
#
# The multi-column batch has, in schema order:
#   0 s: utf8_view, 3 rows, 2 variadic buffers
#   1 i: int64 (not a view field: takes no entry)
#   2 b: binary_view, 3 rows, all inline, 0 variadic buffers
#   3 l: list<utf8_view>, 3 rows; the child has 1 variadic buffer
# so the expected counts are [2, 0, 1].
# =============================================================================

from std.memory import Pointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_compression.compression import ArrowIpcCompression
from komira_compression.compression_codecs import Lz4Frame, Zstd
from komira_async_api.parallel_dispatch import NoDispatch
from komira_async_api.token import CancellationToken
from komira_arrow_ipc.ipc_body_compression import (
    _compress_buffers_into,
    decompress_all_rbs_into_with_dispatcher,
    decompress_dictionary_batch_frame,
    decompress_record_batch_frame,
)
from komira_arrow_ipc.ipc_decoder_dispatch import (
    ColumnTypeSpec,
    decode_record_batch_message_nested,
)
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FieldNode,
    FlatbufWriter,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    RecordBatchDescriptor,
    flatbuf_reader_over,
    parse_ipc_message,
    read_dictionary_batch,
    read_message,
    read_record_batch,
    write_body_compression,
    write_dictionary_batch,
    write_ipc_message,
    write_message,
    write_record_batch,
    write_record_batch_compressed,
)


comptime S1 = "alpha string over twelve"  # 24 bytes, variadic buffer 0
comptime S2 = "beta string beyond twelve!"  # 26 bytes, variadic buffer 1
comptime L0 = "nested long string value"  # 24 bytes, child variadic buffer 0


# --- raw (uncompressed) body builder ------------------------------------------


struct _Body(Movable):
    """An uncompressed body under construction plus its Buffer list."""

    var bytes: List[UInt8]
    var buffers: List[BufferDescriptor]

    def __init__(out self):
        self.bytes = List[UInt8]()
        self.buffers = List[BufferDescriptor]()

    def empty(mut self):
        """A zero-length Buffer (absent validity bitmap)."""
        self.buffers.append(
            BufferDescriptor(offset=Int64(len(self.bytes)), length=Int64(0))
        )

    def add(mut self, var data: List[UInt8]):
        """`data` as the next Buffer, padded to 8 bytes."""
        var off = len(self.bytes)
        for i in range(len(data)):
            self.bytes.append(data[i])
        while len(self.bytes) % 8 != 0:
            self.bytes.append(UInt8(0))
        self.buffers.append(
            BufferDescriptor(offset=Int64(off), length=Int64(len(data)))
        )


def _str_bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _put_i32(mut out: List[UInt8], v: Int):
    for k in range(4):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _view_inline(mut out: List[UInt8], s: String):
    """A 16-byte view holding `s` (at most 12 bytes) inline."""
    var b = _str_bytes(s)
    _put_i32(out, len(b))
    for i in range(12):
        out.append(b[i] if i < len(b) else UInt8(0))


def _view_ref(mut out: List[UInt8], s: String, buf_idx: Int, offset: Int):
    """A 16-byte view of `s` (over 12 bytes) in variadic buffer `buf_idx`."""
    var b = _str_bytes(s)
    _put_i32(out, len(b))
    for i in range(4):
        out.append(b[i])
    _put_i32(out, buf_idx)
    _put_i32(out, offset)


def _node(length: Int) -> FieldNode:
    return FieldNode(length=Int64(length), null_count=Int64(0))


def _multi_body() -> _Body:
    """Body of the four-column batch (see the header)."""
    var body = _Body()
    # 0 s: utf8_view ["short", S1, S2]
    body.empty()
    var sv = List[UInt8]()
    _view_inline(sv, "short")
    _view_ref(sv, S1, 0, 0)
    _view_ref(sv, S2, 1, 0)
    body.add(sv^)
    body.add(_str_bytes(S1))
    body.add(_str_bytes(S2))
    # 1 i: int64 [7, 8, 9]
    body.empty()
    var iv = List[UInt8]()
    for v in range(7, 10):
        _put_i32(iv, v)
        _put_i32(iv, 0)
    body.add(iv^)
    # 2 b: binary_view ["ab", "", "xyz"]
    body.empty()
    var bv = List[UInt8]()
    _view_inline(bv, "ab")
    _view_inline(bv, "")
    _view_inline(bv, "xyz")
    body.add(bv^)
    # 3 l: list<utf8_view> [[L0], [], ["tiny"]]
    body.empty()
    var lo = List[UInt8]()
    for v in [0, 1, 1, 2]:
        _put_i32(lo, v)
    body.add(lo^)
    body.empty()
    var cv = List[UInt8]()
    _view_ref(cv, L0, 0, 0)
    _view_inline(cv, "tiny")
    body.add(cv^)
    body.add(_str_bytes(L0))
    return body^


def _multi_nodes() -> List[FieldNode]:
    var nodes = List[FieldNode]()
    for _ in range(4):
        nodes.append(_node(3))
    nodes.append(_node(2))
    return nodes^


def _multi_counts() -> List[Int64]:
    return [Int64(2), Int64(0), Int64(1)]


def _multi_specs() raises -> Slab[ColumnTypeSpec]:
    var s = Slab[ColumnTypeSpec]()
    s.append(ColumnTypeSpec.leaf(ArrowType.UTF8_VIEW))
    s.append(ColumnTypeSpec.leaf(ArrowType.INT64))
    s.append(ColumnTypeSpec.leaf(ArrowType.BINARY_VIEW))
    s.append(ColumnTypeSpec.list_of(ColumnTypeSpec.leaf(ArrowType.UTF8_VIEW)))
    return s^


def _single_body() -> _Body:
    """One binary_view column [S1, S2]: validity absent, views, 2 variadic
    buffers. Three non-empty Buffers, under the coalesced decompressor's
    parallel threshold of four, so it takes the serial branch."""
    var body = _Body()
    body.empty()
    var v = List[UInt8]()
    _view_ref(v, S1, 0, 0)
    _view_ref(v, S2, 1, 0)
    body.add(v^)
    body.add(_str_bytes(S1))
    body.add(_str_bytes(S2))
    return body^


# --- frame builders ------------------------------------------------------------


def _shared(bytes: List[UInt8]) -> SharedAlignedBuffer[HeapRegion]:
    var out = SharedAlignedBuffer[HeapRegion].heap_owned(max(len(bytes), 1))
    for i in range(len(bytes)):
        out.write_u8_at(i, bytes[i])
    out.set_length(len(bytes))
    return out^


def _compressed_frame[
    C: ArrowIpcCompression
](
    body: _Body,
    rb_len: Int,
    nodes: List[FieldNode],
    counts: List[Int64],
    dict_id: Int64 = -1,
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A per-buffer `C`-compressed frame carrying `counts` as
    variadicBufferCounts: a RecordBatch message, or a DictionaryBatch
    message with id `dict_id` when `dict_id >= 0`."""
    var raw = _shared(body.bytes)
    var cbody = OwnedAlignedBuffer(len(body.bytes) + 64 * len(body.buffers) + 1024)
    var cbufs = List[BufferDescriptor]()
    var cursor = _compress_buffers_into[C](raw, body.buffers, cbody, cbufs)
    while cursor % 8 != 0:
        cbody.write_u8_at(cursor, UInt8(0))
        cursor += 1
    cbody.set_length(Int64(cursor))
    var w = FlatbufWriter(2048)
    var bc_pos = write_body_compression(w, C.ARROW_IPC_CODEC_ID)
    var rb_pos = write_record_batch_compressed(
        w, Int64(rb_len), nodes, cbufs, bc_pos, counts
    )
    var tag = MESSAGE_HEADER_RECORD_BATCH
    var header_pos = rb_pos
    if dict_id >= 0:
        tag = MESSAGE_HEADER_DICTIONARY_BATCH
        header_pos = write_dictionary_batch(w, dict_id, rb_pos, False)
    var msg_pos = write_message(w, Int16(4), tag, header_pos, Int64(cursor))
    var fb = w^.finalize(msg_pos)
    var w2 = FlatbufWriter(64)
    var frame = write_ipc_message(
        w2, fb^, cbody.view_range_ro(0, cursor).into_span(), True
    )
    _ = cbody^
    _ = raw^
    return frame^


def _plain_frame(
    body: _Body, rb_len: Int, nodes: List[FieldNode], counts: List[Int64]
) raises -> SharedAlignedBuffer[HeapRegion]:
    """An uncompressed RecordBatch frame carrying `counts`."""
    var w = FlatbufWriter(2048)
    var rb_pos = write_record_batch(w, Int64(rb_len), nodes, body.buffers, counts)
    var msg_pos = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb_pos, Int64(len(body.bytes))
    )
    var fb = w^.finalize(msg_pos)
    var w2 = FlatbufWriter(64)
    return write_ipc_message(w2, fb^, Span(body.bytes), True)


def _rb_of(frame: SharedAlignedBuffer[HeapRegion]) raises -> RecordBatchDescriptor:
    """The RecordBatch table of a RecordBatch or DictionaryBatch frame."""
    var f = parse_ipc_message(frame)
    var md = SharedAlignedBuffer[HeapRegion].heap_owned(max(f.metadata_size, 1))
    for i in range(f.metadata_size):
        md.write_u8_at(i, frame.read_u8_at(f.metadata_pos + i))
    md.set_length(f.metadata_size)
    var r = flatbuf_reader_over(md)
    var msg = read_message(r, r.read_root_offset())
    if msg.header_tag == MESSAGE_HEADER_DICTIONARY_BATCH:
        var db = read_dictionary_batch(r, msg.header_table_pos)
        return read_record_batch(r, db.data_table_pos)
    return read_record_batch(r, msg.header_table_pos)


def _counts_str(rb: RecordBatchDescriptor) -> String:
    var s = String("[")
    for i in range(len(rb.variadic_buffer_counts)):
        if i > 0:
            s += ", "
        s += String(rb.variadic_buffer_counts[i])
    return s + "]"


# --- value assertions ------------------------------------------------------------


def _assert_strings(
    data: SharedAlignedBuffer[HeapRegion],
    offsets: SharedAlignedBuffer[HeapRegion],
    expected: List[String],
) raises:
    for r in range(len(expected)):
        var lo = Int(offsets.read_i32_le_at(r * 4))
        var hi = Int(offsets.read_i32_le_at((r + 1) * 4))
        var got = String()
        for k in range(lo, hi):
            got += chr(Int(data.read_u8_at(k)))
        assert_equal(got, expected[r])


def _assert_multi_values(var frame: SharedAlignedBuffer[HeapRegion]) raises:
    var cols = decode_record_batch_message_nested(frame^, _multi_specs())
    assert_equal(len(cols), 4)
    assert_equal(cols[0].arrow_type, ArrowType.STRING)
    _assert_strings(
        cols[0]._data, cols[0]._offsets.value(), [String("short"), S1, S2]
    )
    assert_equal(cols[1]._data.read_i64_le_at(0), Int64(7))
    assert_equal(cols[1]._data.read_i64_le_at(16), Int64(9))
    assert_equal(cols[2].arrow_type, ArrowType.BINARY)
    _assert_strings(
        cols[2]._data,
        cols[2]._offsets.value(),
        [String("ab"), String(""), String("xyz")],
    )
    ref child = cols[3].child_at(0)
    assert_equal(child.arrow_type, ArrowType.STRING)
    _assert_strings(
        child._data, child._offsets.value(), [String(L0), String("tiny")]
    )


# --- cases -------------------------------------------------------------------------


def _check_serial[C: ArrowIpcCompression]() raises:
    var body = _multi_body()
    var frame = _compressed_frame[C](body, 3, _multi_nodes(), _multi_counts())
    assert_equal(_counts_str(_rb_of(frame)), "[2, 0, 1]")
    var out = decompress_record_batch_frame[C](
        _compressed_frame[C](body, 3, _multi_nodes(), _multi_counts())
    )
    var rb = _rb_of(out)
    assert_equal(rb.body_compression_codec, Int8(-1))
    assert_equal(len(rb.nodes), 5)
    assert_equal(len(rb.buffers), 13)
    assert_equal(_counts_str(rb), "[2, 0, 1]")
    # The decoder decompresses internally through the same function.
    _assert_multi_values(frame^)


def test_serial_record_batch_keeps_counts_lz4() raises:
    _check_serial[Lz4Frame]()


def test_serial_record_batch_keeps_counts_zstd() raises:
    _check_serial[Zstd[3]]()


def _coalesced_one(
    var frame: SharedAlignedBuffer[HeapRegion],
) raises -> SharedAlignedBuffer[HeapRegion]:
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    frames.append(frame^)
    var nd = NoDispatch()
    var outs = decompress_all_rbs_into_with_dispatcher[Lz4Frame](
        frames^, Pointer(to=nd), CancellationToken.never()
    )
    assert_equal(len(outs), 1)
    var last = outs.pop()
    return last.take()


def _assert_single_values(var frame: SharedAlignedBuffer[HeapRegion]) raises:
    var specs = Slab[ColumnTypeSpec]()
    specs.append(ColumnTypeSpec.leaf(ArrowType.BINARY_VIEW))
    var cols = decode_record_batch_message_nested(frame^, specs^)
    assert_equal(len(cols), 1)
    _assert_strings(cols[0]._data, cols[0]._offsets.value(), [String(S1), S2])


def test_coalesced_compressed_keeps_counts() raises:
    var body = _single_body()
    var nodes: List[FieldNode] = [_node(2)]
    var out = _coalesced_one(
        _compressed_frame[Lz4Frame](body, 2, nodes, [Int64(2)])
    )
    var rb = _rb_of(out)
    assert_equal(rb.body_compression_codec, Int8(-1))
    assert_equal(_counts_str(rb), "[2]")
    _assert_single_values(out^)


def test_coalesced_uncompressed_keeps_counts() raises:
    var body = _single_body()
    var nodes: List[FieldNode] = [_node(2)]
    var out = _coalesced_one(_plain_frame(body, 2, nodes, [Int64(2)]))
    assert_equal(_counts_str(_rb_of(out)), "[2]")
    _assert_single_values(out^)


def test_dictionary_batch_keeps_counts() raises:
    """A DictionaryBatch whose values are utf8_view [S1, S2]; after
    decompression the inner RecordBatch keeps counts [2] and the view and
    variadic Buffers hold the original bytes."""
    var body = _single_body()
    var nodes: List[FieldNode] = [_node(2)]
    var frame = _compressed_frame[Lz4Frame](
        body, 2, nodes, [Int64(2)], dict_id=7
    )
    var out = decompress_dictionary_batch_frame[Lz4Frame](frame^)
    var rb = _rb_of(out)
    assert_equal(rb.body_compression_codec, Int8(-1))
    assert_equal(_counts_str(rb), "[2]")
    assert_equal(len(rb.buffers), 4)
    var f = parse_ipc_message(out)
    for bi in range(1, 4):
        ref want = body.buffers[bi]
        ref got = rb.buffers[bi]
        assert_equal(got.length, want.length)
        for k in range(Int(want.length)):
            assert_equal(
                out.read_u8_at(f.body_pos + Int(got.offset) + k),
                body.bytes[Int(want.offset) + k],
            )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
