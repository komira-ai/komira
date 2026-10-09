# =============================================================================
# test_log_facade_cold_gates.mojo — the facade's three early returns that no
# other suite reaches:
#
#   * `_write_rendered` asked for an engine sink when NO engine is installed
#     returns instead of dereferencing a null engine;
#   * the P1 config disabled: `log.info` writes nothing to fd 2;
#   * the installed engine disabled: `log.info` writes nothing to its sink.
#
# The two disabled-gate cases check their "nothing" against a control line
# written the same way once the gate is open again, so an empty capture cannot
# come from a broken capture. The no-engine case has no control line: no
# engine is installed, so no line can be written; it asserts an empty capture
# and that the call returns (a dereference of the null engine crashes the
# test). fd 2 is pointed at a scratch file for the P1 cases and restored
# before any assertion.
# =============================================================================

from std.ffi import external_call
from std.io import FileHandle
from std.os import remove
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_runtime_paths import test_tmpdir

import komira_log as log
from komira_log import SharedEngine
from komira_log.config import _ensure_config
from komira_log.env_filter import EnvFilter
from komira_log.facade import _write_rendered, _SINK_FALLBACK, _SINK_ESCALATE
from komira_log.levels import LEVEL_INFO
from komira_log.engine.log_manager import LogManager
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
    return test_tmpdir() + String("/komira_log_facade_") + tag


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
    var s = String(f.read())
    f.close()
    return s^


def _rm(path: String):
    try:
        remove(path)
    except:
        pass


struct _Fd2Capture:
    """fd 2 pointed at a scratch file until `stop()`."""

    var path: String
    var fd: Int32
    var saved: Int32

    def __init__(out self, tag: String) raises:
        self.path = _base(tag) + String(".txt")
        self.fd = _open_fd(self.path)
        if Int(self.fd) < 0:
            raise Error("openat failed for " + self.path)
        self.saved = external_call["dup", Int32](Int32(2))
        _ = external_call["dup2", Int32](self.fd, Int32(2))

    def stop(mut self) raises -> String:
        _ = external_call["dup2", Int32](self.saved, Int32(2))
        _ = external_call["close", Int32](self.saved)
        _ = external_call["close", Int32](self.fd)
        var s = _read(self.path)
        _rm(self.path)
        return s^


def test_an_engine_sink_with_no_engine_installed_writes_nothing() raises:
    LogManager._test_reset()
    var cap = _Fd2Capture(String("noengine"))
    _write_rendered(
        _SINK_FALLBACK,
        LEVEL_INFO,
        "cov_facade",
        String("cov no engine fallback"),
        List[String](),
        List[String](),
    )
    _write_rendered(
        _SINK_ESCALATE,
        LEVEL_INFO,
        "cov_facade",
        String("cov no engine escalate"),
        List[String](),
        List[String](),
    )
    var got = cap.stop()
    assert_equal(got, String(""), "no engine: no line, and no crash")


def test_a_disabled_p1_config_writes_nothing() raises:
    LogManager._test_reset()
    var cfg = _ensure_config()
    var cap = _Fd2Capture(String("p1off"))
    cfg[].set_enabled(False)
    log.error["cov p1 while disabled", "cov_facade"]()
    cfg[].set_enabled(True)
    log.error["cov p1 control", "cov_facade"]()
    var got = cap.stop()
    assert_true(String("cov p1 control") in got, "control landed: " + got)
    assert_false(String("cov p1 while disabled") in got, got)


def test_a_disabled_engine_writes_nothing_through_the_facade() raises:
    LogManager._test_reset()
    var tag = String("engoff")
    var eng = SharedEngine(num_workers=1, filter=EnvFilter())
    eng.set_sink_single_file(_base(tag), RotationPolicy.none())
    LogManager._test_install_borrow(eng)
    eng.set_enabled(False)
    log.error["cov engine while disabled", "cov_facade"]()
    eng.set_enabled(True)
    log.error["cov engine control", "cov_facade"]()
    LogManager._test_reset()
    # Keeps `eng` (and its sink's fd) alive past the facade calls that reach it
    # through the global: Mojo ends a value's life at its last direct use.
    _ = eng.enabled()
    var got = _read(_base(tag) + ".log")
    _rm(_base(tag) + ".log")
    assert_true(String("cov engine control") in got, "control landed: " + got)
    assert_false(String("cov engine while disabled") in got, got)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
