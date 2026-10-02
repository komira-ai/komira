# =============================================================================
# test_fault_report_emit_line_loss.mojo — the fd-1 JSON emitter, at the seam
# where the line does not land.
# =============================================================================
#
# SCOPE. `fault_report._emit_line` / `emit_line_to_fd` / `fault_sos_line`. The
# retry policy itself is tested where it lives
# (`komira_log/tests/test_log_write_retry_and_loss_accounting.mojo`); what can
# only be wrong HERE is whether this emitter is wired to it and what it does
# when fd 1 refuses.
#
# ⚠ THIS SITE IS WORSE THAN THE TWO `komira_log` SINKS IN ONE SPECIFIC WAY.
# It emits JSON. A truncated write to a TEXT sink produces a damaged line an
# operator can still read; a truncated write here produces an unparseable one
# the collector DROPS — so a partial write is a total loss, not a partial one.
# And it fires during a 5xx burst: exactly when fd 1 is most likely to be
# congested, and exactly when the diagnostic matters most. It used to
# `break` on the first non-positive `write(2)` return and tell nobody.
#
# THE FALLBACK IS AN SOS ON fd 2, NOT A COUNTER, because this is a free
# function with no owning struct and Mojo 1.0.0 has no mutable module-level
# globals. That is not a downgrade: the fault line is the ONLY place the
# incident id and the raw cause exist (the HTTP response carries the id alone,
# by the disclosure split), so re-emitting it on the other fd preserves the
# thing an operator needs, where a counter would preserve only the fact that
# something was lost.
# =============================================================================

from std.ffi import external_call
from std.io import FileHandle
from std.os import remove
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir
from komira_log.log_write import LineWrite

from komira_http.middleware.fault_report import (
    _emit_line,
    emit_line_to_fd,
    fault_sos_line,
)


comptime _EBADF: Int32 = 9
comptime _EPIPE: Int32 = 32
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


# The runner's per-run scratch directory, not a hard-coded /tmp path: two
# runs of this test on one machine must not share files.
def _tmp(name: String) raises -> String:
    return (test_tmpdir() + String("/komira_fault_emit_")) + name


def _open_fd(path: String) -> Int32:
    var p = path
    # SAFETY: the NUL-terminated view is owned by `p` and held alive across the
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
# §DELIVERED — the healthy path is unchanged.
# =============================================================================


def test_the_json_line_lands_whole_with_exactly_one_newline() raises:
    """One `write(2)`, whole line, one trailing newline. `O_APPEND` writes
    under PIPE_BUF are not interleaved by the kernel, which is what stops two
    concurrent faults splicing half of one JSON object into the other — a
    property that only holds if the line is built and written as ONE payload.
    """
    var path = _tmp("delivered")
    var fd = _open_fd(path)
    assert_true(Int(fd) >= 0, "openat failed for " + path)
    var line = String('{"severity":"ERROR","incidentId":"deadbeefdeadbeef"}')
    var out = emit_line_to_fd(fd, line)
    _ = external_call["close", Int32](fd)

    assert_true(out.complete(), "a healthy fd takes the whole envelope")
    assert_equal(
        out.last_errno,
        Int32(0),
        "and NOTHING is attributed -- write(2) does not clear errno on"
        " success, so an emitter that read it unconditionally would blame a"
        " healthy line for an earlier failure",
    )
    assert_equal(_read_file(path), line + String("\n"))
    _rm(path)


def test_emit_line_still_works_and_does_not_raise() raises:
    """The production entry point is unchanged in signature and still cannot
    raise into the serve loop. A diagnostic that raised would turn a logged 500
    into a DROPPED CONNECTION -- strictly worse than the silence being fixed,
    which is the argument `trace_header_of` already makes in this file."""
    _emit_line(String('{"severity":"ERROR","probe":"emit_line smoke"}'))


# =============================================================================
# §LOST — fd 1 refuses.
# =============================================================================


def test_a_dead_fd_is_reported_not_swallowed_and_does_not_hang() raises:
    """⛔ THE DEFECT. This used to produce nothing at all: `break`,
    `void` return, no errno, no evidence. The SOS lands on fd 2 (the test
    runner's stderr, where you can see it in this action's log)."""
    var out = emit_line_to_fd(
        Int32(-1), String('{"severity":"ERROR","incidentId":"0123456789abcdef"}')
    )
    assert_false(out.complete(), "a closed fd cannot take the line")
    assert_true(out.lost(), "and nothing landed, so it is LOST")
    assert_equal(
        out.last_errno,
        _EBADF,
        "carrying a REAL errno read from the kernel, not a placeholder",
    )
    assert_equal(out.retries, 0, "EBADF is fatal -- we must NOT spin on it")


def test_many_dead_writes_terminate() raises:
    """⛔ THE ANTI-SPIN ARM. A retry budget that can loop on a permanently
    failing fd is strictly worse than the drop it replaces. If this hangs, that
    is the regression."""
    for _i in range(64):
        _ = emit_line_to_fd(Int32(-1), String('{"n":1}'))


# =============================================================================
# §SOS — what an operator actually reads. Pure, so it is assertable without
# breaking fd 2 under the test runner.
# =============================================================================


def test_the_sos_carries_the_ORIGINAL_line_not_a_summary() raises:
    """⭐ THE LOAD-BEARING PROPERTY. The fault line is the ONLY place the
    incident id and the raw cause exist -- the HTTP response carries the id and
    nothing else, by this file's disclosure split. An SOS saying merely "a line
    was lost" would leave an operator holding an id that leads nowhere."""
    var line = String(
        '{"severity":"ERROR","incidentId":"cafebabecafebabe","code":'
        '"internal.unattributed"}'
    )
    var w = LineWrite(120)
    _ = w.observe(-1, _EPIPE)
    var sos = fault_sos_line(Int32(1), w, line)
    assert_true(
        String("cafebabecafebabe") in sos,
        "the incident id must survive, got <" + sos + ">",
    )
    assert_true(
        String("internal.unattributed") in sos,
        "and so must the cause code, got <" + sos + ">",
    )
    assert_true(
        String("errno=32") in sos,
        "with the errno, so an operator can tell a departed collector (EPIPE)"
        " from a full disk (ENOSPC). got <" + sos + ">",
    )
    assert_true(
        String("LOST") in sos, "and which of the two failures it was"
    )
    assert_true(sos.endswith(String("\n")), "one line, newline-terminated")


def test_the_sos_distinguishes_TRUNCATED_from_LOST() raises:
    """The distinction is the whole reason this site is worse than a text sink:
    a line that half landed is an unparseable JSON entry the collector DROPS,
    and an operator chasing it needs to know it was ever on the wire."""
    var w = LineWrite(120)
    _ = w.observe(40, Int32(0))
    _ = w.observe(-1, _EPIPE)
    var sos = fault_sos_line(Int32(1), w, String('{"a":1}'))
    assert_true(
        String("TRUNCATED") in sos, "40 of 120 bytes on the wire, got <" + sos + ">"
    )
    assert_true(
        String("40 of 120") in sos,
        "and it must say HOW MUCH -- a truncation at byte 40 of 120 and one at"
        " byte 119 are the same word and very different evidence. got <"
        + sos
        + ">",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
