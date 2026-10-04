# `LocalFs.clone()`. A reader that opens several files of a directory moves
# one file system into each file's reader, so it opens each from a clone of
# the one it was given; a clone must read as the original does.
#
# Rows: a clone reads the bytes the original reads; a clone of a rooted
# LocalFs opens the same paths. The scratch files are under the test's own
# TEST_TMPDIR, from komira_runtime_paths.
from std.testing import assert_equal, assert_false

from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_runtime_paths import test_tmpdir


def _write_payload(path: String, n: Int) raises:
    """`n` bytes of the pattern `i % 251` at `path`."""
    var buf = List[UInt8](capacity=n)
    for i in range(n):
        buf.append(UInt8(i % 251))
    with open(path, "w") as fh:
        fh.write_bytes(buf)


def test_localfs_clone_reads_as_the_original() raises:
    var path = test_tmpdir() + "/clone_round_trip.bin"
    _write_payload(path, 4096)
    var fs = LocalFs[NoopSink].new()
    var clone_fs = fs.clone()
    var file_a = fs.open(path)
    var buf_a = fs.read_at(file_a, Int64(100), Int64(64))
    var file_b = clone_fs.open(path)
    var buf_b = clone_fs.read_at(file_b, Int64(100), Int64(64))
    assert_equal(buf_a.len(), 64)
    assert_equal(buf_b.len(), 64)
    var a = buf_a.view_range_ro(0, 64).into_span()
    var b = buf_b.view_range_ro(0, 64).into_span()
    for i in range(64):
        assert_equal(Int(a[i]), (100 + i) % 251)
        assert_equal(a[i], b[i])


def test_localfs_clone_keeps_its_root() raises:
    var root = test_tmpdir()
    var path = root + "/clone_root.bin"
    _write_payload(path, 256)
    var fs = LocalFs[NoopSink].from_root(root)
    var clone_fs = fs.clone()
    var file_a = fs.open(path)
    var file_b = clone_fs.open(path)
    assert_equal(file_a.path(), file_b.path())
    assert_false(file_a.is_mmap_cached())
    assert_false(file_b.is_mmap_cached())


def main() raises:
    test_localfs_clone_reads_as_the_original()
    test_localfs_clone_keeps_its_root()
    print("OK")
