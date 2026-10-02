# =============================================================================
# test_log_facade_error_escalation.mojo — the ERROR-never-dropped arm of the
# AMBIENT facade, end to end.
# =============================================================================
#
# WHY THIS FILE EXISTS. `facade._emit` has three ways to reach a synchronous
# rendered write. `test_log_engine.test_backpressure_drop` proves the RING
# drops and counts; this file proves that a dropped ERROR then comes back out
# of the SINK, THROUGH THE FACADE, which is the actual promise ("never drop
# WARN/ERROR").
#
# The three cold arms — the non-worker fallback, the no-engine P1 path, and
# this escalation — share one out-of-line `_write_rendered` rather than three
# inline copies of the render sequence. A restructure of an untested path is a
# coin flip, so the escalation arm is tested here end to end.
#
# ⚠ THIS IS A CONTENT-CONTRACT TEST, NOT JUST A LIVENESS TEST. The assertions
# below are on the SHAPE OF THE LINE — level word, `[module]` tag, interpolated
# `{}` — because the thing a reader of these logs depends on is the bytes, and
# a refactor that keeps the line flowing while changing its shape is exactly
# the regression that is easy to ship and hard to notice.
#
# THE MECHANISM UNDER TEST, and why the fill loop is 4096 long:
#   * a per-WORKER ring is `OVERFLOW_DROP` with `DEFAULT_RING_CAPACITY = 4096`
#     (shared_engine.mojo, ring_buffer.mojo);
#   * nothing drains it here, so 4096 admitted pushes fill it exactly;
#   * push 4097 is rejected -> `_emit` must NOT silently drop it, because the
#     level is ERROR -> it renders on the caller and calls `escalate_line`,
#     which writes synchronously AND flushes.
# So the file is empty until the escalation happens, and the escalated record
# is the ONLY thing in it. That makes the assertion unambiguous: if the
# escalation arm is broken the file is empty, and if the arm fires for the
# wrong record the file has the wrong text.
# =============================================================================

from std.os import remove
from std.io import FileHandle

from std.testing import TestSuite, assert_true, assert_equal

from komira_log.engine.log_manager import LogManager
from komira_log.engine.shared_engine import SharedEngine
from komira_log.engine.rotation import RotationPolicy
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE
from komira_log.log_arg import ArgI64, ArgStr

import komira_log as log
from komira_runtime_paths import test_tmpdir


# ---------------------------------------------------------------------------
# ⚠ $TEST_TMPDIR, NOT A HARD-CODED `/tmp` PATH. Two runs of the same test may
# execute at once on one machine, and a fixed `/tmp` path is shared by all of
# them. The test runner makes `TEST_TMPDIR` private to each run;
# `komira_runtime_paths.test_tmpdir` is the one helper that reads it.
# ---------------------------------------------------------------------------
def _scratch_dir() -> String:
    """The directory THIS execution may write scratch files into."""
    try:
        return test_tmpdir()
    except:
        return String("/tmp")


comptime _RING_CAPACITY = 4096
"""`DEFAULT_RING_CAPACITY` (`komira_spsc_ring`). Restated rather
than imported so that a change to the engine's default makes THIS test fail
loudly (the fill loop stops filling) instead of silently ceasing to exercise
the escalation arm."""


def _BASE() -> String:
    return _scratch_dir() + String("/komira_log_escalation_probe")


def _filter() -> EnvFilter:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    return f^


def _read(path: String) raises -> String:
    var f = FileHandle(path, "r")
    return String(f.read())


def _rm(path: String):
    try:
        remove(path)
    except:
        pass


def _contains(haystack: String, needle: String) -> Bool:
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0:
        return True
    if len(n) > len(h):
        return False
    for i in range(len(h) - len(n) + 1):
        var hit = True
        for j in range(len(n)):
            if h[i + j] != n[j]:
                hit = False
                break
        if hit:
            return True
    return False


def test_dropped_error_escalates_with_its_line_intact() raises:
    """A worker-ring ERROR that the DROP ring rejects is written SYNCHRONOUSLY
    to the sink, with the same rendered shape every other line has.

    FAILS if the escalation arm is dead (file empty), if it escalates the wrong
    record, or if the line loses its level word / module tag / interpolated
    argument.
    """
    var live = String(_BASE()) + ".log"
    _rm(live)

    LogManager.install(SharedEngine(num_workers=1, filter=_filter()))
    ref e = LogManager._resolve()[]
    e.set_sink_single_file(String(_BASE()), RotationPolicy.none())

    # Bind THIS thread as worker 0 so the ambient facade takes the ring path
    # (`wid != WORKER_ID_UNSET`) rather than the non-worker fallback. Without
    # this the test would exercise a different arm and still pass, which is the
    # failure mode a reviewer should look for first.
    e.bind_worker_thread(UInt16(0))

    # ---- Fill worker 0's ring exactly to capacity. Nothing drains it, so
    # every one of these is a successful push and NOTHING reaches the sink.
    for i in range(_RING_CAPACITY):
        log.error["fill {}", "esc"](ArgI64(Int64(i)))

    # The ring is now full, so the sink must still be empty: this is the
    # control that proves the next assertion is about the ESCALATION and not
    # about ordinary emission.
    var before = String("")
    try:
        before = _read(live)
    except:
        before = String("")
    assert_equal(
        before.byte_length(),
        0,
        (
            "the DROP ring absorbed every admitted push; nothing should have"
            " reached the sink yet"
        ),
    )

    # ---- One more ERROR. The ring rejects it; the facade must escalate.
    log.error["ESCALATED {}", "esc"](ArgStr(String("marker42")))

    var after = _read(live)
    assert_true(
        after.byte_length() > 0,
        (
            "a dropped ERROR must reach the sink via escalate_line — an empty"
            " file means the ERROR-never-dropped arm is dead"
        ),
    )

    # ---- THE CONTENT CONTRACT. Same `render_line` shape as every other line:
    # `{ts} {LEVEL} [{module}] {message}`.
    assert_true(
        _contains(after, String("ERROR")),
        "the escalated line carries its LEVEL word",
    )
    assert_true(
        _contains(after, String("[esc]")),
        "the escalated line carries its `[module]` tag",
    )
    assert_true(
        _contains(after, String("ESCALATED marker42")),
        (
            "the escalated line carries the INTERPOLATED message — `{}`"
            " substituted with the positional arg, not the raw fmt"
        ),
    )
    # It is the escalated record and not a leaked fill record.
    assert_true(
        not _contains(after, String("fill ")),
        "only the rejected record escalates; the 4096 accepted ones stay in"
        " the ring",
    )

    _rm(live)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
