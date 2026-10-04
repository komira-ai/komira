# The local arm reads a real file: a file written under the test's own
# TEST_TMPDIR (komira_runtime_paths) is read back through the FsHandle the
# LocalFs was wrapped into, and through a clone of that handle.
#
# Rows: the size and a ranged read through the handle's arm match what was
# written; a clone of the handle reads the same bytes.
from std.testing import assert_equal, assert_true

from komira_async.ops.waker_sink import NoopSink
from komira_fs.local_fs import LocalFs
from komira_fs_registry import fs_handle_from_typed_fs
from komira_runtime_paths import test_tmpdir


def _write_payload(path: String, n: Int) raises:
    """`n` bytes of the pattern `i % 251` at `path`."""
    var buf = List[UInt8](capacity=n)
    for i in range(n):
        buf.append(UInt8(i % 251))
    with open(path, "w") as fh:
        fh.write_bytes(buf)


def test_local_arm_reads_a_real_file() raises:
    var root = test_tmpdir()
    var path = root + "/fs_handle_local_read.bin"
    _write_payload(path, 2048)
    var maybe = fs_handle_from_typed_fs(LocalFs[NoopSink].from_root(root))
    assert_true(Bool(maybe))
    var h = maybe.take()
    assert_true(h.is_local())

    ref fs = h.local_ref().value()
    assert_equal(fs.file_size(path), 2048)
    var file = fs.open(path)
    var buf = fs.read_at(file, Int64(1000), Int64(32))
    assert_equal(buf.len(), 32)
    var got = buf.view_range_ro(0, 32).into_span()
    for i in range(32):
        assert_equal(Int(got[i]), (1000 + i) % 251)

    var c = h.clone()
    ref cfs = c.local_ref().value()
    var cfile = cfs.open(path)
    var cbuf = cfs.read_at(cfile, Int64(1000), Int64(32))
    var cgot = cbuf.view_range_ro(0, 32).into_span()
    for i in range(32):
        assert_equal(cgot[i], got[i])


def main() raises:
    test_local_arm_reads_a_real_file()
    print("OK")
