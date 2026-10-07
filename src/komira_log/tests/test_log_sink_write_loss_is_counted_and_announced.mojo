# =============================================================================
# test_log_sink_write_loss_is_counted_and_announced.mojo — the two komira_log
# sinks, at the seam where a line is lost.
# =============================================================================
#
# SCOPE. The POLICY (retry budget, errno classification, anti-spin, the loss
# counters) is tested once, where it lives, in
# `tests/test_log_write_retry_and_loss_accounting.mojo`. This file
# tests the two things that can only be wrong HERE:
#
#   1. that `LogSink._write_all_fd` and `StderrSink._write_all` ARE WIRED to it
#      at all -- a sink that still carries its own `break` loop would pass
#      every arm of the policy suite while losing every line;
#   2. that a loss is ANNOUNCED on the next healthy line rather than merely
#      counted into a field only tests read. A counter no production site reads
#      is not observability; the edge-report pattern (`_report_overflow_drops`)
#      closes that for ring overflow, and this is the same pattern for the sink
#      write.
#
# ⭐ WHY `LogSink` AND NOT JUST `StderrSink`. `SharedEngine.__init__` installs
# `LogSink.stderr()`, and a service that never calls `set_sink_single_file` /
# `set_sink_per_core_segments` stays on it. So `LogSink._write_all_fd` is the
# loop such a service's log line actually goes through, and it is the one with a
# real fd seam (`_write_all_fd` takes the fd; `StderrSink._write_all` hardcodes
# fd 2), so it is where an fd can be made to fail without dup2'ing stderr out
# from under the test runner.
# =============================================================================

from std.ffi import external_call
from std.io import FileHandle
from std.os import remove
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir

from komira_log.engine.output_sink import LogSink
from komira_log.stderr_sink import StderrSink


comptime _EBADF: Int32 = 9

# openat(2) constants. AT_FDCWD is PLATFORM-SPECIFIC (-100 Linux / -2 Darwin);
# the rest agree except O_CREAT/O_TRUNC, mirrored from
# `komira_libc/posix_io.mojo`.
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


# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH. Two runs of the same test may
# execute at once on one machine, and a fixed `/tmp` path is shared by all of
# them. The test runner makes `TEST_TMPDIR` private to each run;
# `komira_runtime_paths.test_tmpdir` is the one helper that reads it.
def _scratch_dir() -> String:
    try:
        return test_tmpdir()
    except:
        return String("/tmp")


def _tmp(name: String) -> String:
    return (_scratch_dir() + String("/komira_log_writeloss_")) + name


def _open_fd(path: String) -> Int32:
    """A raw writable fd on `path`, via the same fixed-arity openat shim
    `RawWriteFd` uses. Raw rather than a `RawWriteFd` because the seam under
    test (`LogSink._write_all_fd`) takes an fd, and `RawWriteFd` deliberately
    exposes none."""
    var p = path
    # SAFETY: the NUL-terminated view is owned by `p`, held alive across the
    # syscall; the kernel copies the path and the pointer does not escape.
    return external_call["komira_openat_creat", Int32](
        _at_fdcwd(),
        p.as_c_string_slice().unsafe_ptr(),
        _O_WRONLY | _o_creat() | _o_trunc(),
        Int32(0o644),
    )


def _read_file(path: String) raises -> String:
    var f = FileHandle(path, "r")
    return String(f.read())


def _rm(path: String):
    try:
        remove(path)
    except:
        pass


# =============================================================================
# §WIRED — the sink calls the shared policy, and a dead fd is COUNTED.
# =============================================================================


def test_a_dead_fd_is_counted_as_a_LOST_line_not_silently_dropped() raises:
    """⛔ THE HEADLINE. A write to a dead fd must not vanish: it is counted as
    a LOST line, observable through `dropped_line_count()`, rather than a
    `void` return indistinguishable from a delivered line. A dropped line is
    acceptable; an unobservable drop is not."""
    var sink = LogSink.stderr()
    assert_equal(
        sink.dropped_line_count(), Int64(0), "a fresh sink has lost nothing"
    )
    sink._write_all_fd(Int32(-1), String("a line for a closed fd\n"))
    assert_equal(
        sink.dropped_line_count(),
        Int64(1),
        "the line is GONE and the sink must say so",
    )
    assert_equal(
        sink.truncated_line_count(),
        Int64(0),
        "nothing landed, so it is LOST, not TRUNCATED -- the two are different"
        " failures once every line is JSON",
    )
    assert_equal(
        sink.last_write_errno(),
        _EBADF,
        "and the cause must be an errno an operator can look up, not a"
        " boolean. EBADF here; EPIPE would mean the collector went away.",
    )


def test_losses_accumulate_and_the_loop_does_not_hang_on_a_dead_fd() raises:
    """⛔ THE ANTI-SPIN ARM AT THE SINK. A bounded retry budget is only an
    improvement if it TERMINATES; an unbounded one on a permanently-failing fd
    wedges the process, which is strictly worse than the drop it replaces. If
    this arm ever hangs, that is the regression."""
    var sink = LogSink.stderr()
    for _i in range(64):
        sink._write_all_fd(Int32(-1), String("x\n"))
    assert_equal(
        sink.dropped_line_count(),
        Int64(64),
        "64 lines attempted, 64 lost, 64 counted -- and the test returned",
    )


def test_a_healthy_fd_counts_NOTHING() raises:
    """The fix must be invisible when the fd works. A counter that ticks on a
    good write is worse than no counter."""
    var path = _tmp("healthy")
    var fd = _open_fd(path)
    assert_true(Int(fd) >= 0, "openat failed for " + path)
    var sink = LogSink.stderr()
    sink._write_all_fd(fd, String("hello, operator\n"))
    _ = external_call["close", Int32](fd)
    assert_equal(sink.dropped_line_count(), Int64(0))
    assert_equal(sink.truncated_line_count(), Int64(0))
    assert_equal(
        sink.last_write_errno(),
        Int32(0),
        "and NO errno is attributed -- write(2) does not clear errno on"
        " success, so a sink that read it unconditionally would report a stale"
        " cause for a healthy line",
    )
    assert_equal(
        _read_file(path),
        String("hello, operator\n"),
        "every byte, exactly once",
    )
    _rm(path)


# =============================================================================
# §ANNOUNCED — the loss reaches an operator, not just a field.
# =============================================================================


def test_a_loss_is_ANNOUNCED_on_the_next_healthy_line() raises:
    """⭐ THE HALF THAT MAKES IT OBSERVABLE. A counter only tests read is not
    observability -- the edge-report pattern (`_report_overflow_drops`)
    exists to close exactly that for ring overflow. The sink mirrors it: the next line that DOES land carries the
    announcement of everything that did not."""
    var path = _tmp("announce")
    var fd = _open_fd(path)
    assert_true(Int(fd) >= 0, "openat failed for " + path)
    var sink = LogSink.stderr()
    # Two lines into the void...
    sink._write_all_fd(Int32(-1), String("lost one\n"))
    sink._write_all_fd(Int32(-1), String("lost two\n"))
    # ...then one that lands.
    sink._write_all_fd(fd, String("survivor\n"))
    _ = external_call["close", Int32](fd)

    var got = _read_file(path)
    assert_true(
        String("survivor") in got, "the healthy line itself must land: " + got
    )
    assert_true(
        String("DROPPED 2") in got,
        "and it must be followed by an announcement of the TWO lines that did"
        " not, got <" + got + ">",
    )
    assert_true(
        String("errno=9") in got,
        "carrying the errno, because 'some writes failed' is not actionable."
        " got <" + got + ">",
    )
    _rm(path)


def test_the_announcement_is_EDGE_triggered_not_repeated_per_line() raises:
    """A level-triggered report would re-print a cumulative total on EVERY
    subsequent line -- a log flood caused by the log-loss reporter, on a sink
    that is by hypothesis already under pressure."""
    var path = _tmp("edge")
    var fd = _open_fd(path)
    assert_true(Int(fd) >= 0, "openat failed for " + path)
    var sink = LogSink.stderr()
    sink._write_all_fd(Int32(-1), String("lost\n"))
    sink._write_all_fd(fd, String("first\n"))
    sink._write_all_fd(fd, String("second\n"))
    sink._write_all_fd(fd, String("third\n"))
    _ = external_call["close", Int32](fd)

    var got = _read_file(path)
    var first_at = got.find(String("DROPPED"))
    assert_true(first_at >= 0, "announced once, got <" + got + ">")
    assert_equal(
        got.find(String("DROPPED"), start=first_at + 1),
        -1,
        "and EXACTLY once -- the watermark must suppress the repeat. got <"
        + got
        + ">",
    )
    _rm(path)


def test_the_announcement_is_not_attempted_into_the_broken_fd() raises:
    """The report is gated on the preceding write having COMPLETED. Writing an
    announcement into the same congestion that caused the loss is a second lost
    line, and noting ITS outcome would make the reporter its own subject --
    a recursion with no fixed point."""
    var sink = LogSink.stderr()
    sink._write_all_fd(Int32(-1), String("lost\n"))
    sink._write_all_fd(Int32(-1), String("also lost\n"))
    assert_equal(
        sink.dropped_line_count(),
        Int64(2),
        "exactly the two LINES are counted. If the announcement were attempted"
        " into the dead fd and its own failure noted, this would be 3 or more"
        " and would grow without bound.",
    )


# =============================================================================
# §P1 — the StderrSink twin. Its fd is hardcoded to 2, so it cannot be driven
# into failure without dup2'ing stderr out from under the test runner. What IS
# assertable here is that the accounting exists and that the healthy path stays
# silent -- which is what a future edit reintroducing a bare `break` loop would
# break.
# =============================================================================


def test_the_P1_stderr_sink_exposes_the_same_accounting() raises:
    var sink = StderrSink()
    assert_equal(sink.dropped_line_count(), Int64(0))
    assert_equal(sink.truncated_line_count(), Int64(0))
    assert_equal(sink.last_write_errno(), Int32(0))


def test_the_P1_stderr_sink_counts_nothing_on_a_healthy_write() raises:
    """fd 2 under the test runner is a real, working descriptor, so this line
    lands and nothing may be counted."""
    var sink = StderrSink()
    sink.write_line(String("[test] komira_log write-loss accounting probe"))
    assert_equal(
        sink.dropped_line_count(),
        Int64(0),
        "a delivered line is not a loss",
    )
    assert_equal(sink.truncated_line_count(), Int64(0))
    assert_equal(sink.last_write_errno(), Int32(0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
