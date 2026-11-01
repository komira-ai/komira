# =============================================================================
# test_ipc_encoder_streaming.mojo: encode_record_batch_message_streaming and
# the two BodySink conformers
# =============================================================================
#
# The streaming encoder writes the frame through a BodySink instead of
# returning it; its contract is that the bytes are the bytes
# encode_record_batch_message returns. Checked here through an
# AlignedBufferBodySink (in memory) and a StreamingFileBodySink (a file in
# the test's scratch directory, read back), with the result's byte counts.
#
# The sinks themselves: AlignedBufferBodySink refuses every write and a
# second finalize after finalize (capacity 0); StreamingFileBodySink refuses
# a write at any cursor but the next one, ignores an empty copy, sends a
# copy of 4 KiB or more straight to the file, and flushes its 1 MiB staging
# area when a small write or a single byte would overflow it. A file written
# through each path must hold exactly the bytes sent, in order.
# =============================================================================

from std.io import FileHandle
from std.memory import Pointer
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_libc.posix import _read_env
from komira_arrow_ipc.chunked_read import read_chunked_into_list
from komira_arrow_ipc.ipc_body_sink import (
    AlignedBufferBodySink,
    StreamingFileBodySink,
)
from komira_arrow_ipc.ipc_encoder_dispatch import (
    encode_record_batch_message,
    encode_record_batch_message_streaming,
)


def _scratch(name: String) -> String:
    var d = _read_env("TEST_TMPDIR")
    if d.byte_length() == 0:
        d = _read_env("TMPDIR")
    if d.byte_length() == 0:
        d = String("/tmp")
    return d + "/komira_ipc_streaming_" + name


def _columns(string_last: Bool = False) raises -> Slab[Column[HeapRegion]]:
    """STRING "a".."eeeee" (15 data bytes, so padding follows it) and
    INT64 1..5: the STRING first (padding between buffers), or last
    (padding at the end of the body)."""
    var ints = List[Int64]()
    var strs = List[String]()
    for i in range(5):
        ints.append(Int64(i + 1))
        var s = String("")
        for _ in range(i + 1):
            s += String(chr(ord("a") + i))
        strs.append(s)
    var cols = Slab[Column[HeapRegion]]()
    if not string_last:
        cols.append(Column.from_string(StringArray.from_strings(strs)))
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(ints)
        )
    )
    if string_last:
        cols.append(Column.from_string(StringArray.from_strings(strs)))
    return cols^


def test_streaming_into_memory_equals_the_staged_encode() raises:
    _check_in_memory(False)
    _check_in_memory(True)


def _check_in_memory(string_last: Bool) raises:
    var expected = encode_record_batch_message(_columns(string_last))
    var sink = AlignedBufferBodySink(4096)
    var res = encode_record_batch_message_streaming(_columns(string_last), sink)
    assert_equal(res.total_bytes, expected.len())
    assert_equal(res.meta_data_length + res.body_length, res.total_bytes)
    assert_equal(res.body_length % 8, 0)
    assert_equal(sink.bytes_written(), expected.len())
    var got = sink.finalize()
    assert_equal(got.len(), expected.len())
    for i in range(got.len()):
        assert_equal(got.read_u8_at(i), expected.read_u8_at(i), String(i))


def test_streaming_into_a_file_equals_the_staged_encode() raises:
    var expected = encode_record_batch_message(_columns())
    var path = _scratch("frame")
    var h = FileHandle(path, "w")
    var sink = StreamingFileBodySink(Pointer(to=h))
    # A flush with nothing staged writes nothing.
    sink.flush()
    assert_equal(sink.bytes_written(), 0)
    var res = encode_record_batch_message_streaming(_columns(), sink)
    sink.flush()
    assert_equal(sink.bytes_written(), res.total_bytes)
    assert_true(sink.capacity() > expected.len())
    _ = sink^
    _ = h^
    var got = read_chunked_into_list(path)
    assert_equal(len(got), expected.len())
    for i in range(len(got)):
        assert_equal(got[i], expected.read_u8_at(i), String(i))


def test_streaming_refuses_zero_and_ragged_columns() raises:
    var sink = AlignedBufferBodySink(64)
    var msg = String("")
    try:
        _ = encode_record_batch_message_streaming(
            Slab[Column[HeapRegion]](), sink
        )
    except e:
        msg = String(e)
    assert_equal(msg, "encode_record_batch_message_streaming: zero columns")
    var cols = _columns()
    var one = List[Int64]()
    one.append(1)
    cols.append(
        Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].from_list(one)
        )
    )
    msg = String("")
    try:
        _ = encode_record_batch_message_streaming(cols^, sink)
    except e:
        msg = String(e)
    assert_equal(
        msg,
        "encode_record_batch_message_streaming: row count mismatch at column"
        " 2 (expected 5, got 1)",
    )
    msg = String("")
    try:
        _ = encode_record_batch_message(Slab[Column[HeapRegion]]())
    except e:
        msg = String(e)
    assert_equal(msg, "encode_record_batch_message: zero columns")


# ---------------------------------------------------------------------------
# AlignedBufferBodySink
# ---------------------------------------------------------------------------


def test_aligned_sink_refuses_everything_after_finalize() raises:
    var sink = AlignedBufferBodySink(16)
    sink.write_u8_at(0, UInt8(9))
    assert_equal(sink.capacity() >= 16, True)
    var out = sink.finalize()
    assert_equal(out.len(), 1)
    assert_equal(out.read_u8_at(0), UInt8(9))
    assert_equal(sink.capacity(), 0)
    var msgs = List[String]()
    try:
        sink.write_u8_at(1, UInt8(1))
    except e:
        msgs.append(String(e))
    var src = OwnedAlignedBuffer(4)
    src.set_length(Int64(4))
    try:
        sink.copy_from_view_at(1, src.view_range_ro(0, 4))
    except e:
        msgs.append(String(e))
    try:
        _ = sink.finalize()
    except e:
        msgs.append(String(e))
    assert_equal(len(msgs), 3)
    assert_equal(
        msgs[0], "AlignedBufferBodySink: buffer was finalize()d; cannot write"
    )
    assert_equal(
        msgs[1], "AlignedBufferBodySink: buffer was finalize()d; cannot write"
    )
    assert_equal(msgs[2], "AlignedBufferBodySink.finalize: already finalized")


# ---------------------------------------------------------------------------
# StreamingFileBodySink
# ---------------------------------------------------------------------------


def _pattern(n: Int, seed: Int) -> OwnedAlignedBuffer:
    var b = OwnedAlignedBuffer(max(n, 1))
    b.set_length(Int64(n))
    for i in range(n):
        b.write_u8_at(i, UInt8((i * 7 + seed) & 0xFF))
    return b^


def test_streaming_sink_refuses_out_of_order_cursors() raises:
    var path = _scratch("order")
    var h = FileHandle(path, "w")
    var sink = StreamingFileBodySink(Pointer(to=h))
    sink.write_u8_at(0, UInt8(1))
    var msgs = List[String]()
    try:
        sink.write_u8_at(0, UInt8(2))
    except e:
        msgs.append(String(e))
    var src = _pattern(4, 0)
    try:
        sink.copy_from_view_at(5, src.view_range_ro(0, 4))
    except e:
        msgs.append(String(e))
    assert_equal(len(msgs), 2)
    assert_equal(
        msgs[0],
        "StreamingFileBodySink.write_u8_at: out-of-order cursor 0 (expected 1)",
    )
    assert_equal(
        msgs[1],
        "StreamingFileBodySink.copy_from_view_at: out-of-order cursor 5"
        " (expected 1)",
    )
    # An empty copy at the right cursor writes nothing.
    sink.copy_from_view_at(1, src.view_range_ro(0, 0))
    assert_equal(sink.bytes_written(), 1)
    sink.flush()
    _ = sink^
    _ = h^
    var got = read_chunked_into_list(path)
    assert_equal(len(got), 1)
    assert_equal(got[0], UInt8(1))


def test_streaming_sink_paths_keep_the_byte_order() raises:
    """Small copies (4000 bytes) fill the 1 MiB staging area until the
    next one would overflow it (a flush), a direct 4096-byte copy flushes
    staging first, and 1 MiB of single bytes fill staging so the next byte
    flushes it. The file is every byte in the order sent."""
    comptime SMALL = 4000
    comptime N_SMALL = 263  # 263 * 4000 > 1 MiB: the 263rd flushes first
    comptime BIG = 4096
    comptime STAGING = 1024 * 1024
    var path = _scratch("paths")
    var h = FileHandle(path, "w")
    var sink = StreamingFileBodySink(Pointer(to=h))
    var small = _pattern(SMALL, 3)
    var cursor = 0
    for _ in range(N_SMALL):
        sink.copy_from_view_at(cursor, small.view_range_ro(0, SMALL))
        cursor += SMALL
    var big = _pattern(BIG, 11)
    sink.copy_from_view_at(cursor, big.view_range_ro(0, BIG))
    cursor += BIG
    for i in range(STAGING + 1):
        sink.write_u8_at(cursor, UInt8(i & 0xFF))
        cursor += 1
    sink.flush()
    assert_equal(sink.bytes_written(), cursor)
    _ = sink^
    _ = h^
    var got = read_chunked_into_list(path)
    assert_equal(len(got), cursor)
    var at = 0
    for k in range(N_SMALL):
        for i in range(0, SMALL, 997):
            assert_equal(got[at + i], UInt8((i * 7 + 3) & 0xFF), String(k))
        at += SMALL
    for i in range(BIG):
        assert_equal(got[at + i], UInt8((i * 7 + 11) & 0xFF))
    at += BIG
    for i in range(0, STAGING + 1, 4093):
        assert_equal(got[at + i], UInt8(i & 0xFF))
    assert_equal(got[at + STAGING], UInt8(STAGING & 0xFF))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
