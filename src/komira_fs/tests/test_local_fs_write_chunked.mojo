# =============================================================================
# test_local_fs_write_chunked.mojo
# =============================================================================
# `LocalFs.write_at` splits a payload over 64 MiB into 64 MiB writes. One
# payload of 64 MiB + 5 bytes takes that path: a full chunk, then a 5-byte
# tail. The file must be exactly the payload: its size, the cursor and the
# bytes on each side of the chunk boundary and at both ends.
#
# The payload is a zero fill with four marker bytes, so the fixture costs one
# allocation rather than a per-byte loop (this runs under the coverage
# tracer too). `test_local_fs_write_at`'s 70 MiB pattern test stays behind its
# `--large-writes` flag; this is the gated proof of the chunked path.
# =============================================================================

from std.testing import TestSuite, assert_equal

from komira_runtime_paths import test_tmpdir
from komira_fs.file_system import WriteMode
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

comptime _CHUNK = 64 * 1024 * 1024


def _byte_at(buf: SharedAlignedBuffer[HeapRegion], offset: Int) -> Int:
    var view = buf.view_range_ro(offset, 1)
    return Int(view.into_span()[0])


def test_write_at_over_one_chunk() raises:
    """64 MiB + 5 bytes: one full chunk, then the 5-byte tail. Size, cursor
    and the bytes at both ends and on both sides of the boundary."""
    var n = _CHUNK + 5
    var data = List[UInt8]()
    data.resize(n, UInt8(0))
    data[0] = UInt8(1)
    data[_CHUNK - 1] = UInt8(2)
    data[_CHUNK] = UInt8(3)
    data[n - 1] = UInt8(4)
    var path = test_tmpdir() + "/write_chunked.bin"
    var fs = LocalFs[NoopSink].new()
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var written = fs.write_at(wf, Span(data))
    assert_equal(Int(written), n)
    assert_equal(Int(wf.cursor()), n)
    fs.close_write(wf^)
    _ = data^
    assert_equal(fs.file_size(path), n)
    var file = fs.open(path)
    var head = fs.read_at(file, Int64(0), Int64(2))
    assert_equal(_byte_at(head, 0), 1)
    assert_equal(_byte_at(head, 1), 0)
    var mid = fs.read_at(file, Int64(_CHUNK - 2), Int64(4))
    assert_equal(_byte_at(mid, 0), 0)
    assert_equal(_byte_at(mid, 1), 2)
    assert_equal(_byte_at(mid, 2), 3)
    assert_equal(_byte_at(mid, 3), 0)
    var tail = fs.read_at(file, Int64(n - 2), Int64(2))
    assert_equal(_byte_at(tail, 0), 0)
    assert_equal(_byte_at(tail, 1), 4)
    fs.delete(path)


def main() raises:
    var suite = TestSuite()
    suite.test[test_write_at_over_one_chunk]()
    suite^.run()
