# =============================================================================
# test_log_sink_and_engine_edges.mojo — the output-sink and engine arms the
# other suites do not reach:
#
#   * `SegmentFile.open_live` on an already-open segment (reopen truncates and
#     resets the byte counter);
#   * per-core routing of an out-of-range worker id to the fallback segment,
#     and `segment_bytes` off the per-core mode / out of range;
#   * the STDERR sink mode's own write, and the P1 `StderrSink` announcing a
#     lost line on the next healthy one (fd 2 is pointed at a scratch file for
#     the duration, then restored);
#   * a failing fsync counted by `escalate_line` and `flush_sink` (Linux: the
#     live file is a symlink to /dev/null, whose fsync is EINVAL);
#   * the drain's span arms: the retained buffer at its cap, a span written to
#     the sink when capture is off, and that write failing;
#   * a disabled engine opening and closing no span;
#   * `overflow_dropped_count`, `drain_captured_spans`, `set_sink_stderr`.
# =============================================================================

from std.ffi import external_call
from std.io import FileHandle
from std.os import remove
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir

from komira_log import SharedEngine
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE
from komira_log.stderr_sink import StderrSink
from komira_log.engine.log_event_record import LogEventRecord
from komira_log.engine.output_sink import (
    LogSink,
    SegmentFile,
    SINK_STDERR,
    SINK_FILE,
)
from komira_log.engine.rotation import RotationPolicy


comptime _O_WRONLY: Int32 = 1


@always_inline
def _at_fdcwd() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(-2)
    else:
        return Int32(-100)


@always_inline
def _o_creat() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0x0200)
    else:
        return Int32(0x0040)


@always_inline
def _o_trunc() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0x0400)
    else:
        return Int32(0x0200)


def _base(tag: String) raises -> String:
    """A path under this run's private $TEST_TMPDIR. Raises when it is unset:
    a fixed /tmp path would be shared by concurrent runs."""
    return test_tmpdir() + String("/komira_log_edges_") + tag


def _open_fd(path: String) -> Int32:
    var p = path
    # SAFETY: the NUL-terminated view is owned by `p`, held alive across the
    # syscall; the kernel copies the path and the pointer does not escape.
    return external_call["komira_openat_creat", Int32](
        _at_fdcwd(),
        p.as_c_string_slice().unsafe_ptr(),
        _O_WRONLY | _o_creat() | _o_trunc(),
        Int32(0o644),
    )


def _read(path: String) raises -> String:
    var f = FileHandle(path, "r")
    return String(f.read())


def _rm(path: String):
    try:
        remove(path)
    except:
        pass


def _cleanup(tag: String) raises:
    _rm(_base(tag) + ".log")
    for c in range(4):
        _rm(_base(tag) + String(".core") + String(c) + ".log")
        _rm(_base(tag) + String(".") + String(c) + ".log")


def _trace_engine() raises -> SharedEngine:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    return SharedEngine(num_workers=1, filter=f^)


# -----------------------------------------------------------------------------
# fd 2 redirection. Every case that moves fd 2 puts it back before asserting,
# so a failing assertion still reports on the real stderr.
# -----------------------------------------------------------------------------


def _dup(fd: Int32) -> Int32:
    return external_call["dup", Int32](fd)


def _dup2(src: Int32, dst: Int32) -> Int32:
    return external_call["dup2", Int32](src, dst)


def _close(fd: Int32):
    _ = external_call["close", Int32](fd)


# -----------------------------------------------------------------------------
# output_sink
# -----------------------------------------------------------------------------


def test_reopening_a_live_segment_truncates_and_resets_its_count() raises:
    var tag = String("reopen")
    var seg = SegmentFile(_base(tag), RotationPolicy.none())
    seg.append_line(String("abc"))
    assert_equal(seg.current_bytes(), 4)
    seg.open_live()
    assert_equal(seg.current_bytes(), 0, "the count restarts with the file")
    seg.append_line(String("z"))
    var got = _read(_base(tag) + ".log")
    _cleanup(tag)
    assert_equal(got, String("z\n"), "the reopened file was truncated")


def test_an_out_of_range_worker_writes_the_fallback_segment() raises:
    var tag = String("route")
    var sink = LogSink.per_core_segments(_base(tag), 2, RotationPolicy.none())
    sink.write_line_core(-1, String("neg"))
    sink.write_line_core(7, String("big"))
    # num_cores + 1 == the slot count: the first id past the end. A `>` in
    # place of `>=` in the range check would index one past the last slot.
    sink.write_line_core(3, String("eq"))
    var fallback = sink.segment_bytes(2)
    var core0 = sink.segment_bytes(0)
    var below = sink.segment_bytes(-1)
    var above = sink.segment_bytes(3)
    _cleanup(tag)
    assert_equal(fallback, 11, "all three lines landed in the last (fallback) slot")
    assert_equal(core0, 0, "and not in core 0")
    assert_equal(below, 0, "segment_bytes(-1) is 0")
    assert_equal(above, 0, "segment_bytes(num_segments) is 0")


def test_segment_bytes_is_zero_for_a_single_file_sink() raises:
    var tag = String("single")
    var sink = LogSink.single_file(_base(tag), RotationPolicy.none())
    sink.write_line_core(0, String("line"))
    var got = sink.segment_bytes(0)
    _cleanup(tag)
    assert_equal(got, 0, "only the per-core mode has segments")


def test_stderr_sink_mode_puts_the_line_on_fd_2() raises:
    var path = _base("stderr_mode.txt")
    var fd = _open_fd(path)
    assert_true(Int(fd) >= 0, "openat failed for " + path)
    var saved = _dup(Int32(2))
    _ = _dup2(fd, Int32(2))
    var sink = LogSink.stderr()
    sink.write_line_core(0, String("cov stderr-mode line"))
    _ = _dup2(saved, Int32(2))
    _close(saved)
    _close(fd)
    var got = _read(path)
    _rm(path)
    assert_equal(got, String("cov stderr-mode line\n"))


def test_p1_stderr_sink_announces_a_loss_on_the_next_line() raises:
    """fd 2 closed: the line is lost and counted. fd 2 a file again: the next
    line lands and is followed by the announcement of the lost one."""
    var path = _base("p1_announce.txt")
    var fd = _open_fd(path)
    assert_true(Int(fd) >= 0, "openat failed for " + path)
    var saved = _dup(Int32(2))
    var sink = StderrSink()
    _close(Int32(2))
    sink.write_line(String("cov lost line"))
    _ = _dup2(fd, Int32(2))
    sink.write_line(String("cov survivor"))
    _ = _dup2(saved, Int32(2))
    _close(saved)
    _close(fd)
    var got = _read(path)
    _rm(path)
    assert_equal(sink.dropped_line_count(), Int64(1), "the lost line counted")
    assert_true(String("cov survivor\n") in got, got)
    assert_false(String("cov lost line") in got, got)
    assert_true(
        String("DROPPED 1") in got,
        String("the loss is announced after the survivor: <") + got + ">",
    )


def test_a_failed_fsync_is_counted_not_charged_as_a_lost_line() raises:
    comptime if CompilationTarget.is_linux():
        _fsync_case()
    else:
        print("SKIP: fsync of /dev/null is EINVAL on Linux only")


def _fsync_case() raises:
    var tag = String("fsync")
    _cleanup(tag)
    var link = _base(tag) + ".log"
    var target = String("/dev/null")
    # SAFETY: both NUL-terminated views are owned by locals held alive across
    # the synchronous syscall.
    var rc = external_call["symlink", Int32](
        target.as_c_string_slice().unsafe_ptr(),
        link.as_c_string_slice().unsafe_ptr(),
    )
    assert_equal(Int(rc), 0, "symlink to /dev/null")
    var eng = _trace_engine()
    eng.set_sink_single_file(_base(tag), RotationPolicy.none())
    eng.escalate_line(String("cov escalated"))
    var after_escalate = eng.sink_flush_failure_count()
    eng.flush_sink()
    var after_flush = eng.sink_flush_failure_count()
    var dropped = eng.sink_dropped_line_count()
    _cleanup(tag)
    assert_equal(after_escalate, Int64(1), "escalate_line's flush failed")
    assert_equal(after_flush, Int64(2), "flush_sink's flush failed")
    assert_equal(dropped, Int64(0), "the line itself was written")


def test_set_sink_stderr_switches_back() raises:
    var tag = String("kind")
    var eng = _trace_engine()
    eng.set_sink_single_file(_base(tag), RotationPolicy.none())
    assert_equal(eng.sink_kind(), SINK_FILE)
    eng.set_sink_stderr()
    _cleanup(tag)
    assert_equal(eng.sink_kind(), SINK_STDERR)
    eng.flush_sink()
    assert_equal(
        eng.sink_flush_failure_count(), Int64(0), "a stderr flush is a no-op"
    )


# -----------------------------------------------------------------------------
# engine: spans through `drain_worker`, the disabled engine, counters
# -----------------------------------------------------------------------------


def test_a_full_span_buffer_drops_and_counts() raises:
    var eng = _trace_engine()
    eng.set_capture_spans(True)
    eng.set_span_buf_max(1)
    var a = eng.start_span["cov.a"](0)
    eng.end_span(a, 0)
    var b = eng.start_span["cov.b"](0)
    eng.end_span(b, 0)
    assert_equal(eng.drain_worker(0, 64), 4)
    assert_equal(eng.span_buf_len(0), 1, "the buffer holds its cap")
    assert_equal(eng.spans_dropped_count(), Int64(1), "the second is counted")


def test_with_capture_off_a_span_is_written_to_the_sink() raises:
    var tag = String("spansink")
    var eng = _trace_engine()
    eng.set_sink_single_file(_base(tag), RotationPolicy.none())
    var s = eng.start_span["cov.sink.span"](0)
    eng.end_span(s, 0)
    assert_equal(eng.drain_worker(0, 64), 2)
    var got = _read(_base(tag) + ".log")
    _cleanup(tag)
    assert_true(String('"name":"cov.sink.span"') in got, got)
    assert_equal(eng.sink_dropped_line_count(), Int64(0))


def test_a_span_lost_to_a_sink_error_is_counted() raises:
    """The rotation trick of test_log_sink_error_evidence: `by_size(1)` rotates
    after every line; with the reopened live file unlinked, the next rotate's
    rename has no source and raises."""
    var tag = String("spanerr")
    _cleanup(tag)
    var eng = _trace_engine()
    eng.set_sink_single_file(_base(tag), RotationPolicy.by_size(1))
    eng.emit_fallback_line(String("prime"))
    assert_equal(eng.sink_dropped_line_count(), Int64(0), "priming succeeded")
    _rm(_base(tag) + ".log")
    var s = eng.start_span["cov.lost.span"](0)
    eng.end_span(s, 0)
    _ = eng.drain_worker(0, 64)
    var dropped = eng.sink_dropped_line_count()
    _cleanup(tag)
    assert_equal(dropped, Int64(1), "the span line's failed write is counted")


def test_a_disabled_engine_opens_and_closes_no_span() raises:
    var eng = _trace_engine()
    eng.set_enabled(False)
    assert_equal(Int(eng.start_span["cov.off"](0)), 0, "span id 0")
    eng.end_span(UInt64(5), 0)
    assert_true(eng.ring(0).is_empty(), "no SPAN record pushed")
    assert_equal(eng.span_depth(0), 0, "the span stack did not move")


def test_overflow_dropped_count_sums_the_worker_ring() raises:
    var eng = _trace_engine()
    var n = 0
    while n < 1 << 20 and eng.ring(0).try_push(LogEventRecord()):
        n += 1
    assert_false(eng.ring(0).try_push(LogEventRecord()), "still full")
    assert_equal(eng.overflow_dropped_count(), Int64(2), "both refusals")


def test_drain_captured_spans_flushes_the_ring_tail() raises:
    var eng = _trace_engine()
    eng.set_capture_spans(True)
    var s = eng.start_span["cov.tail"](0)
    eng.end_span(s, 0)
    var lines = eng.drain_captured_spans(0)
    assert_equal(len(lines), 1, "the undrained span came back")
    assert_true(String('"name":"cov.tail"') in lines[0], lines[0])
    assert_equal(len(eng.drain_captured_spans(0)), 0, "and was moved out")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
