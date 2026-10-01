# =============================================================================
# test_log_manager_global.mojo — the LogManager immortal-global regression guard.
# =============================================================================
#
# Proves the process-global immortal LogManager (log_manager.mojo):
#   * install-once: the FIRST install wins and is immortal; a SECOND install is
#     a no-op (no clobber — two contexts cannot stomp one global);
#   * the resolve returns a STABLE pointer to the immortal engine across calls;
#   * the reconstructed engine reads its heap-owning fields COHERENTLY
#     (num_workers) through the single confined `unsafe_from_address` accessor;
#   * is_installed() transitions correctly, and the test-only reset clears it.
#
# The immortal engine is LEAKED by design (never freed) — so this test's process
# ends with leaked engines, which is the intended forever-root contract, not a
# bug. There is NO movable-field capture.
# =============================================================================

from std.testing import TestSuite, assert_true, assert_false, assert_equal

from komira_log.engine.log_manager import LogManager
from komira_log.engine.shared_engine import SharedEngine
from komira_log.env_filter import EnvFilter


def _f() -> EnvFilter:
    var f = EnvFilter()
    return f^


def test_install_once_immortal_no_clobber() raises:
    """The core guard: first install wins + is immortal; a second install (a
    different-sized engine, mimicking a second EngineContext/service) is a NO-OP
    — it cannot stomp the global. This is the multi-context no-clobber
    property."""
    assert_false(
        LogManager.is_installed(),
        "no global installed at process start",
    )

    # First install: 3-worker engine. Wins, immortal.
    LogManager.install(SharedEngine(num_workers=3, filter=_f()))
    assert_true(LogManager.is_installed(), "installed after first install")
    assert_equal(
        LogManager._resolve()[].num_workers(),
        3,
        "the immortal engine reads num_workers==3 coherently (confined resolve)",
    )

    # Second install: 7-worker engine (a second context). MUST be a no-op — the
    # first engine stays installed; the global is NOT clobbered.
    LogManager.install(SharedEngine(num_workers=7, filter=_f()))
    assert_true(LogManager.is_installed(), "still installed after second")
    assert_equal(
        LogManager._resolve()[].num_workers(),
        3,
        "second install did NOT clobber — the immortal first engine (nw=3) wins",
    )


def test_resolve_stable_across_calls() raises:
    """After install, two independent resolves name the SAME stable immortal
    address (getLogger()-from-anywhere reaches one engine)."""
    # (install-once means the engine from the prior test is still the global;
    #  a fresh install here is a no-op, so we resolve whatever is installed.)
    if not LogManager.is_installed():
        LogManager.install(SharedEngine(num_workers=2, filter=_f()))
    var a = Int(LogManager._resolve())
    var b = Int(LogManager._resolve())
    assert_true(a != 0, "resolve is non-null after install")
    assert_equal(a, b, "two resolves name one stable immortal pointer")


def test_reset_then_reinstall_reads_the_new_engine() raises:
    """The test-only reset clears the C-static cell, and the next install is
    the one every resolve then reaches: the holder reads ONLY that cell."""
    LogManager._test_reset()
    assert_false(LogManager.is_installed(), "cleared by the test-only reset")
    LogManager.install(SharedEngine(num_workers=5, filter=_f()))
    assert_true(LogManager.is_installed(), "installed via the C-static holder")
    assert_equal(
        LogManager._resolve()[].num_workers(),
        5,
        "resolve reads the C-static immortal engine (nw=5)",
    )


def main() raises:
    var suite = TestSuite()
    suite.test[test_install_once_immortal_no_clobber]()
    suite.test[test_resolve_stable_across_calls]()
    suite.test[test_reset_then_reinstall_reads_the_new_engine]()
    suite^.run()
