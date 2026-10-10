# =============================================================================
# test_ipc_coalesced_decompress_refusal.mojo: the coalesced multi-frame
# decompress refuses a malformed frame without freeing any frame twice
# =============================================================================
#
# decompress_all_rbs_into_with_dispatcher takes ownership of a slab of
# compressed RecordBatch frames and builds one context per frame. When a
# frame is refused (here: a compressed values buffer of 4 bytes, shorter
# than its 8-byte length prefix), the error must reach the caller and every
# frame must be freed exactly once: the frames already built into contexts,
# the refused frame, and the frames not yet reached. A driver that moves
# frames out of the slab and fixes the slab's length only after the loop
# frees the moved frames a second time when the refusal unwinds; that is
# a double free of each frame's region, which corrupts the allocator and
# crashes the process (or a later allocation).
#
# Each case runs many times, allocating between runs, so a double free
# shows up as a crash or as a corrupted later buffer rather than passing
# on a quiet heap. Positions covered: the refused frame first (nothing
# built yet), last (two contexts built), and in the middle (frames after
# it not yet reached). A control case decompresses the same valid frames.
# =============================================================================

from std.memory import Pointer
from std.testing import TestSuite, assert_equal

from komira_arrow.arrow_types import ArrowType
from komira_buffer.heap_region import HeapRegion
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_compression.compression_codecs import Lz4Frame
from komira_async_api.parallel_dispatch import NoDispatch
from komira_async_api.token import CancellationToken
from komira_arrow_ipc.ipc_body_compression import (
    decompress_all_rbs_into_with_dispatcher,
)
from komira_arrow_ipc.ipc_decoder_dispatch import decode_record_batch_message
from komira_arrow_ipc.ipc_flatbuf import (
    BufferDescriptor,
    FieldNode,
    FlatbufWriter,
    MESSAGE_HEADER_RECORD_BATCH,
    write_body_compression,
    write_ipc_message,
    write_message,
    write_record_batch_compressed,
)

comptime RUNS = 200


def _frame(
    buf_len: Int, prefix: Int64, tag: Int
) raises -> SharedAlignedBuffer[HeapRegion]:
    """A compressed (LZ4) RecordBatch of one INT64 column of 2 rows over a
    32-byte body: the values buffer is (0, buf_len) and the body's first
    8 bytes are `prefix` and the two values after it are 100 * tag + 1
    and 100 * tag + 2. buf_len 24 with prefix -1 is a valid stored-raw
    buffer (the 16 raw bytes after the prefix); buf_len 4 is refused."""
    var w = FlatbufWriter(2048)
    var nodes = List[FieldNode]()
    nodes.append(FieldNode(length=Int64(2), null_count=Int64(0)))
    var bufs = List[BufferDescriptor]()
    bufs.append(BufferDescriptor(offset=Int64(0), length=Int64(0)))
    bufs.append(BufferDescriptor(offset=Int64(0), length=Int64(buf_len)))
    var bc = write_body_compression(w, Int8(0))
    var rb = write_record_batch_compressed(w, Int64(2), nodes, bufs, bc)
    var msg = write_message(
        w, Int16(4), MESSAGE_HEADER_RECORD_BATCH, rb, Int64(32)
    )
    var fb = w^.finalize(msg)
    var body = SharedAlignedBuffer[HeapRegion].heap_owned(32)
    body.zero()
    body.write_i64_le_at(0, prefix)
    body.write_i64_le_at(8, Int64(100 * tag + 1))
    body.write_i64_le_at(16, Int64(100 * tag + 2))
    body.set_length(32)
    var w2 = FlatbufWriter(64)
    return write_ipc_message(
        w2, fb^, body.view_range_ro(0, 32).into_span(), True
    )


def _good(tag: Int) raises -> SharedAlignedBuffer[HeapRegion]:
    return _frame(24, Int64(-1), tag)


def _bad(tag: Int) raises -> SharedAlignedBuffer[HeapRegion]:
    return _frame(4, Int64(16), tag)


def _run(bad_at: Int, n: Int) raises -> String:
    """Decompress `n` frames, the one at `bad_at` malformed (none if
    bad_at < 0); returns the error text, or "ok" once each output frame
    has decoded to its own values, in input order."""
    var frames = Slab[SharedAlignedBuffer[HeapRegion]]()
    for i in range(n):
        frames.append(_bad(i) if i == bad_at else _good(i))
    var nd = NoDispatch()
    try:
        var outs = decompress_all_rbs_into_with_dispatcher[Lz4Frame](
            frames^, Pointer(to=nd), CancellationToken.never()
        )
        assert_equal(len(outs), n)
        var types = List[ArrowType]()
        types.append(ArrowType.INT64)
        for i in range(n - 1, -1, -1):
            var last = outs.pop()
            var cols = decode_record_batch_message(last.take(), types)
            assert_equal(cols[0]._data.read_i64_le_at(0), Int64(100 * i + 1))
            assert_equal(cols[0]._data.read_i64_le_at(8), Int64(100 * i + 2))
        return String("ok")
    except e:
        return String(e)


def _churn() raises:
    """Allocate and check buffers of the frames' sizes, so a block freed
    twice is handed out twice and its contents are overwritten."""
    var held = List[SharedAlignedBuffer[HeapRegion]]()
    for k in range(8):
        var b = SharedAlignedBuffer[HeapRegion].heap_owned(32)
        b.zero()
        b.write_i64_le_at(0, Int64(k))
        b.set_length(32)
        held.append(b^)
    for k in range(8):
        assert_equal(held[k].read_i64_le_at(0), Int64(k))


comptime REFUSAL = (
    "_build_rb_context: buffer 1 has length 4 < 8 (the i64"
    " uncompressed_length prefix); malformed compressed body"
)


def _check_refused(bad_at: Int, n: Int) raises:
    for _ in range(RUNS):
        assert_equal(_run(bad_at, n), String(REFUSAL))
        _churn()


def test_refused_first_frame_frees_each_frame_once() raises:
    _check_refused(0, 3)


def test_refused_middle_frame_frees_each_frame_once() raises:
    _check_refused(1, 3)


def test_refused_last_frame_frees_each_frame_once() raises:
    _check_refused(2, 3)


def test_refused_only_frame_frees_it_once() raises:
    _check_refused(0, 1)


def test_valid_frames_decompress() raises:
    """The control: the same frames, none malformed, decompress, each to
    its own values and in input order."""
    for _ in range(RUNS):
        assert_equal(_run(-1, 3), String("ok"))
        _churn()


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
