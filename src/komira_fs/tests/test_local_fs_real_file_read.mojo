# LocalFs reads a real file: a file written under the test's own TEST_TMPDIR
# (komira_runtime_paths) is read back through a LocalFs rooted there, and
# through a clone of it.
#
# Rows: the size and a ranged read match what was written; a clone reads the
# same bytes; LocalFs advertises SCHEME 0 (komira_source_url's
# test_source_scheme_agrees holds that to the plan's FS_SCHEME_FILE).
from std.testing import assert_equal, assert_true

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


def test_local_fs_reads_a_real_file() raises:
    var root = test_tmpdir()
    var path = root + "/local_fs_real_file_read.bin"
    _write_payload(path, 2048)
    var fs = LocalFs[NoopSink].from_root(root)
    assert_equal(Int(LocalFs[NoopSink].SCHEME), 0)
    assert_equal(fs.file_size(path), 2048)
    var file = fs.open(path)
    var buf = fs.read_at(file, Int64(1000), Int64(32))
    assert_equal(buf.len(), 32)
    var got = buf.view_range_ro(0, 32).into_span()
    for i in range(32):
        assert_equal(Int(got[i]), (1000 + i) % 251)

    var cfs = fs.clone()
    var cfile = cfs.open(path)
    var cbuf = cfs.read_at(cfile, Int64(1000), Int64(32))
    var cgot = cbuf.view_range_ro(0, 32).into_span()
    for i in range(32):
        assert_equal(cgot[i], got[i])


def main() raises:
    test_local_fs_reads_a_real_file()
    print("OK")
