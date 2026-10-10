# =============================================================================
# test_thp_process_disabled.mojo — decision row 1 on a real process.
# =============================================================================
#
# This process sets PR_SET_THP_DISABLE before anything reads the THP policy,
# so the frozen snapshot is taken from a `/proc/self/status` that reports
# `THP_enabled: 0`. The `auto` mode must then be OFF whatever `enabled` says,
# and the report must name the flag. Kept in its own test binary because the
# flag is process-wide and inherited.
#
# Requires Linux 5.0 or later to build: `THP_enabled:` first appears in
# `/proc/<pid>/status` in 5.0 (the upstream change "mm, proc: report
# PR_SET_THP_DISABLE in proc"). On an older kernel this test fails with that
# message rather than passing without observing row 1.
# =============================================================================

from std.ffi import external_call, c_int
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from komira_host.thp_policy import (
    ADVICE_OFF,
    THP_PROCESS_DISABLED,
    _read_small_file,
    hugepage_auto_advice_mode,
    parse_thp_process_enabled,
    thp_policy_report,
    thp_probe_count,
    thp_process_enabled,
)

comptime _PR_SET_THP_DISABLE: Int = 41


def test_pr_set_thp_disable_resolves_off_and_is_reported() raises:
    comptime if CompilationTarget.is_linux():
        assert_equal(thp_probe_count(), 0, "nothing probed before the flag")
        var rc = external_call["prctl", c_int](
            c_int(_PR_SET_THP_DISABLE), Int(1), Int(0), Int(0), Int(0)
        )
        assert_equal(Int(rc), 0, "prctl(PR_SET_THP_DISABLE) failed")
        var status = _read_small_file("/proc/self/status")
        if status.find("THP_enabled:") < 0:
            # A kernel before 5.0: absent reads as available, and row 1
            # cannot be observed through /proc/self/status on this host.
            raise Error(
                "komira_host tests require Linux 5.0 or later: this kernel's"
                " /proc/self/status has no THP_enabled field"
            )
        assert_equal(parse_thp_process_enabled(status), THP_PROCESS_DISABLED)
        assert_equal(thp_process_enabled(), THP_PROCESS_DISABLED)
        assert_equal(hugepage_auto_advice_mode(), ADVICE_OFF)
        var report = thp_policy_report()
        assert_true(
            report.find(" THP_enabled=0(PR_SET_THP_DISABLE) ") >= 0, report
        )
        assert_true(report.endswith(" -> auto=off"), report)
        assert_equal(thp_probe_count(), 1)
    else:
        # No THP and no prctl off Linux: the snapshot is the closed UNKNOWN one.
        assert_equal(hugepage_auto_advice_mode(), ADVICE_OFF)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
