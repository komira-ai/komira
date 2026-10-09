# =============================================================================
# test_fs_handles.mojo
# =============================================================================
# The byte-sink / byte-source handles of `komira_fs.handle`:
#
#   * `FileHandleWriter`: bytes written through `from_path` land in the file
#     in order; an empty write is a no-op; a write after `close` raises; a
#     second `close` is a no-op.
#   * `FileHandleReader`: `read_all` returns the whole file however far the
#     cursor already moved; an empty file reads as no bytes; a read after
#     `close` raises; `close` twice is a no-op.
#   * `BytesHandle`: write then read round-trip, `read_all` drains (a second
#     read is empty), `as_reader` rewinds, `close` resets, the views agree.
#   * The standard-stream constructors open their stream (`from_stdout`
#     writes nothing here; `from_stdin` is opened and closed).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir
from komira_fs.handle import (
    BytesHandle,
    FileHandleReader,
    FileHandleWriter,
    ReadableHandle,
    WritableHandle,
)


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    for i in range(len(bs)):
        out.append(bs[i])
    return out^


def _read_file(path: String) raises -> String:
    var fh = open(path, "r")
    var s = fh.read()
    fh.close()
    return s^


def _write_via[H: WritableHandle](mut h: H, s: String) raises:
    """Drive a writer through the trait (proves the conformance)."""
    var b = _bytes(s)
    h.write_all(Span(b))


def _read_via[H: ReadableHandle](mut h: H) raises -> List[UInt8]:
    return h.read_all()


def test_file_writer_round_trip() raises:
    var path = test_tmpdir() + "/handle_writer.txt"
    var w = FileHandleWriter.from_path(path)
    _write_via(w, "hello ")
    var empty = List[UInt8]()
    w.write_all(Span(empty))  # a no-op
    _write_via(w, "world")
    w.close()
    assert_equal(_read_file(path), "hello world")
    # A write after close raises; a second close is a no-op.
    var raised = False
    try:
        _write_via(w, "late")
    except e:
        raised = True
        assert_true("handle is closed" in String(e))
    assert_true(raised)
    w.close()
    assert_equal(_read_file(path), "hello world")


def test_file_writer_truncates() raises:
    var path = test_tmpdir() + "/handle_writer_trunc.txt"
    var w1 = FileHandleWriter.from_path(path)
    _write_via(w1, "a much longer first payload")
    w1.close()
    var w2 = FileHandleWriter.from_path(path)
    _write_via(w2, "short")
    w2.close()
    assert_equal(_read_file(path), "short")


def test_file_reader_reads_whole_file() raises:
    var path = test_tmpdir() + "/handle_reader.txt"
    var w = FileHandleWriter.from_path(path)
    _write_via(w, "0123456789")
    w.close()
    var r = FileHandleReader.from_path(path)
    var got = _read_via(r)
    assert_equal(len(got), 10)
    assert_equal(Int(got[0]), ord("0"))
    assert_equal(Int(got[9]), ord("9"))
    # A second read rewinds: still the whole file.
    var again = r.read_all()
    assert_equal(len(again), 10)
    assert_equal(Int(again[9]), ord("9"))
    r.close()
    var raised = False
    try:
        _ = r.read_all()
    except e:
        raised = True
        assert_true("handle is closed" in String(e))
    assert_true(raised)
    r.close()


def test_file_reader_empty_file() raises:
    var path = test_tmpdir() + "/handle_reader_empty.txt"
    var w = FileHandleWriter.from_path(path)
    w.close()
    var r = FileHandleReader.from_path(path)
    assert_equal(len(r.read_all()), 0)
    r.close()


def test_bytes_handle() raises:
    var h = BytesHandle()
    assert_equal(h.num_bytes(), 0)
    assert_equal(len(h.read_all()), 0)
    _write_via(h, "abc")
    _write_via(h, "de")
    assert_equal(h.num_bytes(), 5)
    assert_equal(h.cursor(), 0)
    var got = _read_via(h)
    assert_equal(len(got), 5)
    assert_equal(Int(got[0]), ord("a"))
    assert_equal(Int(got[4]), ord("e"))
    assert_equal(h.cursor(), 5)
    # Drained: nothing more to read.
    assert_equal(len(h.read_all()), 0)
    assert_equal(h.cursor(), 5)
    # Rewind and read again.
    h.as_reader()
    assert_equal(h.cursor(), 0)
    assert_equal(len(h.read_all()), 5)
    var v = h.bytes_view()
    assert_equal(len(v), 5)
    assert_equal(Int(v[2]), ord("c"))
    h.close()
    assert_equal(h.num_bytes(), 0)
    assert_equal(h.cursor(), 0)


def test_bytes_handle_from_bytes() raises:
    var h = BytesHandle.from_bytes(_bytes("xyz"))
    assert_equal(h.num_bytes(), 3)
    assert_equal(h.cursor(), 0)
    var got = h.read_all()
    assert_equal(len(got), 3)
    assert_equal(Int(got[1]), ord("y"))


def test_std_streams_open() raises:
    var w = FileHandleWriter.from_stdout()
    # The handle names the standard output device, not some other file.
    assert_equal(w._handle.value().path(), "/dev/stdout")
    var empty = List[UInt8]()
    w.write_all(Span(empty))
    w.close()
    var r = FileHandleReader.from_stdin()
    r.close()


def main() raises:
    var suite = TestSuite()
    suite.test[test_file_writer_round_trip]()
    suite.test[test_file_writer_truncates]()
    suite.test[test_file_reader_reads_whole_file]()
    suite.test[test_file_reader_empty_file]()
    suite.test[test_bytes_handle]()
    suite.test[test_bytes_handle_from_bytes]()
    suite.test[test_std_streams_open]()
    suite^.run()
