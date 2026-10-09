# =============================================================================
# test_local_fs_read_paths.mojo
# =============================================================================
# The LocalFs read-side methods the scan paths use besides `read_at`:
#
#   * `read_at` refuses a negative offset and a negative length.
#   * `read_ranges_prefetched` returns one buffer per range, in input order,
#     each holding that range's bytes; no ranges give no buffers.
#   * `read_footer`: a window shorter than the file reads the last `window`
#     bytes (offset and total size reported); a window longer than the file
#     reads all of it; a missing file and a non-seekable file (a pipe) raise;
#     a file whose reported size exceeds what a read returns (a sysfs
#     attribute) raises a short read.
#   * `file_size`: a missing file and a pipe raise.
#   * `read_whole` / `read_range` return the file's bytes.
# =============================================================================

from std.ffi import external_call
from std.os.path import exists
from std.memory import alloc
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir
from komira_fs.local_fs import LocalFs
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion


def _write_pattern(path: String, n: Int) raises:
    """`n` bytes of the `i % 251` pattern."""
    var fh = open(path, "w")
    var buf = List[UInt8]()
    buf.resize(n, UInt8(0))
    for i in range(n):
        buf[i] = UInt8(i % 251)
    fh.write_bytes(buf)
    fh.close()


def _byte_at(buf: SharedAlignedBuffer[HeapRegion], offset: Int) -> Int:
    var view = buf.view_range_ro(offset, 1)
    return Int(view.into_span()[0])


def _assert_pattern(
    buf: SharedAlignedBuffer[HeapRegion], file_offset: Int, n: Int
) raises:
    assert_equal(buf.len(), n)
    for i in range(n):
        assert_equal(_byte_at(buf, i), (file_offset + i) % 251)


struct _Pipe(Movable):
    """A pipe whose read end is reopened by path (`/dev/fd/<r>`): a
    file `fopen` opens but cannot seek in."""

    var r: Int32
    var w: Int32

    def __init__(out self) raises:
        var fds = alloc[Int32](2)
        fds[0] = Int32(-1)
        fds[1] = Int32(-1)
        var rc = external_call["pipe", Int32](fds)
        self.r = fds[0]
        self.w = fds[1]
        fds.unsafe_free()
        if Int(rc) != 0:
            raise Error("pipe(2) failed")

    def path(self) -> String:
        return String("/dev/fd/") + String(Int(self.r))

    def __del__(deinit self):
        _ = external_call["close", Int32](self.r)
        _ = external_call["close", Int32](self.w)


def test_read_at_refuses_negative() raises:
    var path = test_tmpdir() + "/read_neg.bin"
    _write_pattern(path, 64)
    var fs = LocalFs[NoopSink].new()
    var file = fs.open(path)
    var raised_off = False
    try:
        _ = fs.read_at(file, Int64(-1), Int64(1))
    except e:
        raised_off = True
        assert_true("negative offset/length: offset=-1 length=1" in String(e))
    assert_true(raised_off)
    var raised_len = False
    try:
        _ = fs.read_at(file, Int64(4), Int64(-2))
    except e:
        raised_len = True
        assert_true("negative offset/length: offset=4 length=-2" in String(e))
    assert_true(raised_len)
    # A valid read still works on the same file.
    _assert_pattern(fs.read_at(file, Int64(3), Int64(5)), 3, 5)


def test_read_ranges_prefetched_in_order() raises:
    var path = test_tmpdir() + "/read_ranges.bin"
    _write_pattern(path, 1000)
    var fs = LocalFs[NoopSink].new()
    var file = fs.open(path)
    var ranges = List[Tuple[Int64, Int64]]()
    ranges.append((Int64(500), Int64(10)))
    ranges.append((Int64(0), Int64(3)))
    ranges.append((Int64(990), Int64(10)))
    var bufs = fs.read_ranges_prefetched(file, ranges)
    assert_equal(bufs.len(), 3)
    _assert_pattern(bufs[0], 500, 10)
    _assert_pattern(bufs[1], 0, 3)
    _assert_pattern(bufs[2], 990, 10)
    var none = fs.read_ranges_prefetched(file, List[Tuple[Int64, Int64]]())
    assert_equal(none.len(), 0)


def test_read_footer_window_shorter_than_file() raises:
    var path = test_tmpdir() + "/footer_tail.bin"
    _write_pattern(path, 1000)
    var fs = LocalFs[NoopSink].new()
    var fr = fs.read_footer(path, 100)
    assert_equal(fr.offset, 900)
    assert_equal(fr.file_size, 1000)
    assert_equal(fr.len(), 100)
    for i in range(100):
        assert_equal(Int(fr.bytes[i]), (900 + i) % 251)


def test_read_footer_window_longer_than_file() raises:
    var path = test_tmpdir() + "/footer_whole.bin"
    _write_pattern(path, 300)
    var fs = LocalFs[NoopSink].new()
    var fr = fs.read_footer(path, 4096)
    assert_equal(fr.offset, 0)
    assert_equal(fr.file_size, 300)
    assert_equal(fr.len(), 300)
    assert_equal(Int(fr.bytes[0]), 0)
    assert_equal(Int(fr.bytes[299]), 299 % 251)


def test_read_footer_missing_raises() raises:
    var fs = LocalFs[NoopSink].new()
    var raised = False
    try:
        _ = fs.read_footer(test_tmpdir() + "/footer_missing.bin", 64)
    except e:
        raised = True
        assert_true("read_footer: open failed" in String(e))
    assert_true(raised)


def test_read_footer_unseekable_raises() raises:
    var p = _Pipe()
    var fs = LocalFs[NoopSink].new()
    var raised = False
    try:
        _ = fs.read_footer(p.path(), 64)
    except e:
        raised = True
        assert_true("read_footer: fseek/ftell failed" in String(e))
    assert_true(raised)
    _ = p^  # the pipe's fds stay open until here


def test_read_footer_short_read_raises() raises:
    """A sysfs attribute reports a page-sized file but reads back a few
    bytes: the read comes up short of the size and must raise. Linux only
    (no sysfs elsewhere), and only where sysfs is mounted; each skip says
    why."""
    comptime if not CompilationTarget.is_linux():
        print("SKIP test_read_footer_short_read_raises: needs Linux sysfs")
        return
    var path = String("/sys/devices/system/cpu/online")
    if not exists(path):
        print(
            "SKIP test_read_footer_short_read_raises: " + path
            + " is absent (sysfs not mounted in this sandbox)"
        )
        return
    var fs = LocalFs[NoopSink].new()
    var size = fs.file_size(path)
    assert_true(size > 64)  # the reported size, not the content length
    var raised = False
    try:
        _ = fs.read_footer(path, size)
    except e:
        raised = True
        assert_true("read_footer: short read" in String(e))
    assert_true(raised)


def test_file_size_failures() raises:
    var fs = LocalFs[NoopSink].new()
    var raised_missing = False
    try:
        _ = fs.file_size(test_tmpdir() + "/size_missing.bin")
    except e:
        raised_missing = True
        assert_true("file_size: open failed" in String(e))
    assert_true(raised_missing)
    var p = _Pipe()
    var raised_pipe = False
    try:
        _ = fs.file_size(p.path())
    except e:
        raised_pipe = True
        assert_true("file_size: fseek/ftell failed" in String(e))
    assert_true(raised_pipe)
    _ = p^  # the pipe's fds stay open until here


def test_read_whole_and_range() raises:
    var path = test_tmpdir() + "/read_whole.bin"
    _write_pattern(path, 700)
    var fs = LocalFs[NoopSink].new()
    _assert_pattern(fs.read_whole(path), 0, 700)
    _assert_pattern(fs.read_range(path, 260, 40), 260, 40)


def main() raises:
    var suite = TestSuite()
    suite.test[test_read_at_refuses_negative]()
    suite.test[test_read_ranges_prefetched_in_order]()
    suite.test[test_read_footer_window_shorter_than_file]()
    suite.test[test_read_footer_window_longer_than_file]()
    suite.test[test_read_footer_missing_raises]()
    suite.test[test_read_footer_unseekable_raises]()
    suite.test[test_read_footer_short_read_raises]()
    suite.test[test_file_size_failures]()
    suite.test[test_read_whole_and_range]()
    suite^.run()
