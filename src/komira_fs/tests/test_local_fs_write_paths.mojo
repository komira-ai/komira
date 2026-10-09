# =============================================================================
# test_local_fs_write_paths.mojo
# =============================================================================
# The LocalFs write-side methods the parallel-write and error paths use:
#
#   * `open_write` refuses a `WriteMode` discriminant it does not know.
#   * `open_write(CREATE_EXCLUSIVE)` on a path that does not exist creates
#     it; the bytes written read back, and a second exclusive open of the
#     now-existing path raises.
#   * `write_at` / `pwrite_at` of an empty payload write nothing and return 0.
#   * `seek_write_to_end`: after a `pwrite_at` past the cursor, the next
#     `write_at` lands at the new end of file, not at the stale cursor.
#   * `LocalWriteFile.ftruncate_size` / `seek_to_end`.
#   * `writev_at_cursor`: refuses mismatched spans; an empty gather writes
#     nothing; a gather of IOV_MAX + 3 buffers (two batches, the second
#     short) lands every byte in order after the bytes already written and
#     advances the cursor by the total.
#   * `fsync_file` / `fsync_dir` succeed on what exists and raise on what
#     does not.
#   * `abort_write` removes the partial file, and is quiet when it is gone.
# =============================================================================

from std.io import FileHandle
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir
from komira_fs.file_system import WriteMode
from komira_fs.local_fs import LocalFs, LocalWriteFile
from komira_async.ops.waker_sink import NoopSink
from komira_libc.posix_io import IOV_MAX


def _path(name: String) raises -> String:
    return test_tmpdir() + "/" + name


def _read_file_bytes(path: String) raises -> List[UInt8]:
    var fh = open(path, "r")
    _ = fh.seek(0, 2)
    var n = Int(fh.seek(0, 1))
    _ = fh.seek(0, 0)
    if n == 0:
        fh.close()
        return List[UInt8]()
    var out = fh.read_bytes(n)
    fh.close()
    return out^


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _exists(fs: LocalFs[NoopSink], path: String) -> Bool:
    try:
        _ = fs.file_size(path)
        return True
    except:
        return False


def test_open_write_unknown_mode_raises() raises:
    var fs = LocalFs[NoopSink].new()
    var path = _path("unknown_mode.bin")
    var raised = False
    try:
        var wf = fs.open_write(path, WriteMode(UInt8(9)))
        fs.close_write(wf^)
    except e:
        raised = True
        var msg = String(e)
        assert_true("unknown WriteMode discriminant value=9" in msg)
    assert_true(raised)
    # Nothing was created.
    assert_false(_exists(fs, path))


def test_open_write_create_exclusive_new_path() raises:
    var fs = LocalFs[NoopSink].new()
    var path = _path("exclusive_new.bin")
    assert_false(_exists(fs, path))
    var wf = fs.open_write(path, WriteMode.create_exclusive())
    var b = _bytes("exclusive")
    assert_equal(fs.write_at(wf, Span(b)), 9)
    fs.close_write(wf^)
    var got = _read_file_bytes(path)
    assert_equal(len(got), 9)
    for i in range(9):
        assert_equal(got[i], b[i])
    # The path exists now, so a second exclusive open must refuse it.
    var raised = False
    try:
        var wf2 = fs.open_write(path, WriteMode.create_exclusive())
        fs.close_write(wf2^)
    except:
        raised = True
    assert_true(raised)
    assert_equal(fs.file_size(path), 9)


def test_write_at_empty_is_noop() raises:
    var fs = LocalFs[NoopSink].new()
    var path = _path("write_empty.bin")
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var head = _bytes("ab")
    _ = fs.write_at(wf, Span(head))
    var empty = List[UInt8]()
    assert_equal(Int(fs.write_at(wf, Span(empty))), 0)
    assert_equal(Int(wf.cursor()), 2)
    fs.close_write(wf^)
    assert_equal(fs.file_size(path), 2)


def test_pwrite_at_empty_is_noop() raises:
    var fs = LocalFs[NoopSink].new()
    var path = _path("pwrite_empty.bin")
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var empty = List[UInt8]()
    assert_equal(Int(fs.pwrite_at(wf, Int64(5), Span(empty))), 0)
    fs.close_write(wf^)
    assert_equal(fs.file_size(path), 0)


def test_seek_write_to_end_resyncs_cursor() raises:
    var fs = LocalFs[NoopSink].new()
    var path = _path("seek_write_to_end.bin")
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var head = _bytes("AAAA")
    _ = fs.write_at(wf, Span(head))
    assert_equal(Int(wf.cursor()), 4)
    # pwrite past the cursor: the file grows to 12, the cursor stays at 4.
    var tail = _bytes("BB")
    _ = fs.pwrite_at(wf, Int64(10), Span(tail))
    assert_equal(Int(wf.cursor()), 4)
    var end = fs.seek_write_to_end(wf)
    assert_equal(Int(end), 12)
    assert_equal(Int(wf.cursor()), 12)
    var more = _bytes("CC")
    _ = fs.write_at(wf, Span(more))
    assert_equal(Int(wf.cursor()), 14)
    fs.close_write(wf^)
    var got = _read_file_bytes(path)
    assert_equal(len(got), 14)
    assert_equal(Int(got[3]), ord("A"))
    assert_equal(Int(got[4]), 0)  # the hole pwrite left
    assert_equal(Int(got[10]), ord("B"))
    assert_equal(Int(got[12]), ord("C"))
    assert_equal(Int(got[13]), ord("C"))


def test_ftruncate_and_seek_to_end() raises:
    var fs = LocalFs[NoopSink].new()
    var path = _path("ftruncate.bin")
    var wf = fs.open_write(path, WriteMode.create_truncate())
    wf.ftruncate_size(100)
    assert_equal(Int(wf.seek_to_end()), 100)
    wf.ftruncate_size(30)
    assert_equal(Int(wf.seek_to_end()), 30)
    fs.close_write(wf^)
    assert_equal(fs.file_size(path), 30)


def test_writev_mismatched_spans_raise() raises:
    var fs = LocalFs[NoopSink].new()
    var path = _path("writev_mismatch.bin")
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var data = _bytes("xy")
    var addrs = List[Int]()
    # SAFETY: `data` outlives the call; the address is never dereferenced
    # (the call refuses the mismatched spans first).
    addrs.append(Int(Span(data).unsafe_ptr()))
    var lens = List[Int]()
    lens.append(1)
    lens.append(1)
    var raised = False
    try:
        _ = fs.writev_at_cursor(wf, Span(addrs), Span(lens))
    except e:
        raised = True
        assert_true("addrs.len=1 != lens.len=2" in String(e))
    assert_true(raised)
    assert_equal(Int(wf.cursor()), 0)
    fs.close_write(wf^)
    assert_equal(fs.file_size(path), 0)


def test_writev_empty_writes_nothing() raises:
    var fs = LocalFs[NoopSink].new()
    var path = _path("writev_empty.bin")
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var addrs = List[Int]()
    var lens = List[Int]()
    assert_equal(Int(fs.writev_at_cursor(wf, Span(addrs), Span(lens))), 0)
    assert_equal(Int(wf.cursor()), 0)
    fs.close_write(wf^)
    assert_equal(fs.file_size(path), 0)


def test_writev_two_batches_in_order() raises:
    """IOV_MAX + 3 one-byte buffers: one full batch, then a short one. Every
    byte lands in order after the two bytes already written."""
    var fs = LocalFs[NoopSink].new()
    var path = _path("writev_batches.bin")
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var pre = _bytes("XY")
    _ = fs.write_at(wf, Span(pre))
    var n = IOV_MAX + 3
    var data = List[UInt8](capacity=n)
    for i in range(n):
        data.append(UInt8(i % 251))
    var addrs = List[Int](capacity=n)
    var lens = List[Int](capacity=n)
    # SAFETY: `data` is not resized after this point and is kept alive past
    # the writev call that reads these addresses (the `_ = data^` below).
    var base = Int(Span(data).unsafe_ptr())
    for i in range(n):
        addrs.append(base + i)
        lens.append(1)
    var total = fs.writev_at_cursor(wf, Span(addrs), Span(lens))
    _ = data^  # keep the gathered buffer alive past the writev
    assert_equal(Int(total), n)
    assert_equal(Int(wf.cursor()), n + 2)
    fs.close_write(wf^)
    var got = _read_file_bytes(path)
    assert_equal(len(got), n + 2)
    assert_equal(Int(got[0]), ord("X"))
    assert_equal(Int(got[1]), ord("Y"))
    for i in range(n):
        assert_equal(Int(got[i + 2]), i % 251)


def test_fsync_file_and_dir() raises:
    var fs = LocalFs[NoopSink].new()
    var dir = test_tmpdir()
    var path = _path("fsync.bin")
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var b = _bytes("data")
    _ = fs.write_at(wf, Span(b))
    fs.close_write(wf^)
    fs.fsync_file(path)
    fs.fsync_dir(dir)
    # Both raise on a path that does not exist.
    var missing = _path("fsync_missing_dir/none.bin")
    var raised_file = False
    try:
        fs.fsync_file(missing)
    except:
        raised_file = True
    assert_true(raised_file)
    var raised_dir = False
    try:
        fs.fsync_dir(_path("fsync_missing_dir"))
    except:
        raised_dir = True
    assert_true(raised_dir)
    # The file is intact.
    assert_equal(fs.file_size(path), 4)


def test_abort_write_removes_partial_file() raises:
    var fs = LocalFs[NoopSink].new()
    var path = _path("abort.bin")
    var wf = fs.open_write(path, WriteMode.create_truncate())
    var b = _bytes("partial")
    _ = fs.write_at(wf, Span(b))
    assert_true(_exists(fs, path))
    fs.abort_write(wf^)
    assert_false(_exists(fs, path))
    # Aborting a handle whose file is already gone does not raise.
    var wf2 = fs.open_write(path, WriteMode.create_truncate())
    fs.delete(path)
    fs.abort_write(wf2^)
    assert_false(_exists(fs, path))


def main() raises:
    var suite = TestSuite()
    suite.test[test_open_write_unknown_mode_raises]()
    suite.test[test_open_write_create_exclusive_new_path]()
    suite.test[test_write_at_empty_is_noop]()
    suite.test[test_pwrite_at_empty_is_noop]()
    suite.test[test_seek_write_to_end_resyncs_cursor]()
    suite.test[test_ftruncate_and_seek_to_end]()
    suite.test[test_writev_mismatched_spans_raise]()
    suite.test[test_writev_empty_writes_nothing]()
    suite.test[test_writev_two_batches_in_order]()
    suite.test[test_fsync_file_and_dir]()
    suite.test[test_abort_write_removes_partial_file]()
    suite^.run()
