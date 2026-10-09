# =============================================================================
# test_thp_frozen.mojo — the probe-once snapshot and the public accessors.
# =============================================================================
#
# The snapshot reads this host's real files, so the oracle is the same three
# files read again here through the pure parsers: every accessor must agree with
# them, and the probe must have run exactly once however many accessors are
# called. The report line is checked against a name table written out in this
# file, not against the module's own ladders.
#
# `test_thp_process_disabled.mojo` is the other half: there the process sets
# PR_SET_THP_DISABLE before its first probe.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_host.thp_policy import (
    ADVICE_HUGEPAGE,
    ADVICE_OFF,
    THP_PROCESS_DISABLED,
    _probe_thp_policy_uncached,
    _read_small_file,
    defrag_is_compaction_hazard,
    hugepage_auto_advice_mode,
    parse_thp_defrag,
    parse_thp_enabled,
    parse_thp_process_enabled,
    prime_thp_policy,
    resolve_auto_mode,
    thp_defrag_is_compaction_hazard,
    thp_defrag_policy,
    thp_enabled_policy,
    thp_policy_report,
    thp_probe_count,
    thp_process_enabled,
)


def _enabled_word(tok: Int) -> String:
    var words = List[String]()
    words.append("unknown")
    words.append("always")
    words.append("madvise")
    words.append("never")
    if tok >= 0 and tok < len(words):
        return words[tok]
    return "unknown"


def _defrag_word(tok: Int) -> String:
    var words = List[String]()
    words.append("unknown")
    words.append("always")
    words.append("defer")
    words.append("defer+madvise")
    words.append("madvise")
    words.append("never")
    if tok >= 0 and tok < len(words):
        return words[tok]
    return "unknown"


def test_the_probe_runs_once_and_agrees_with_the_files() raises:
    assert_true(thp_probe_count() <= 1)
    var mode = prime_thp_policy()
    for _ in range(5):
        assert_equal(hugepage_auto_advice_mode(), mode)
        _ = thp_enabled_policy()
        _ = thp_defrag_policy()
        _ = thp_process_enabled()
        _ = thp_defrag_is_compaction_hazard()
        _ = thp_policy_report()
    assert_equal(thp_probe_count(), 1, "the probe is frozen once per process")

    var enabled = parse_thp_enabled(
        _read_small_file("/sys/kernel/mm/transparent_hugepage/enabled")
    )
    var defrag = parse_thp_defrag(
        _read_small_file("/sys/kernel/mm/transparent_hugepage/defrag")
    )
    var proc = parse_thp_process_enabled(_read_small_file("/proc/self/status"))
    assert_equal(thp_enabled_policy(), enabled)
    assert_equal(thp_defrag_policy(), defrag)
    assert_equal(thp_process_enabled(), proc)
    assert_equal(mode, resolve_auto_mode(enabled, defrag, proc))
    assert_equal(thp_defrag_is_compaction_hazard(), defrag_is_compaction_hazard(defrag))

    # The uncached probe reads the same files and does not count.
    var again = _probe_thp_policy_uncached()
    assert_equal(again.enabled, enabled)
    assert_equal(again.defrag, defrag)
    assert_equal(again.proc_enabled, proc)
    assert_equal(again.mode, mode)
    assert_equal(thp_probe_count(), 1)


def test_the_report_names_what_was_read() raises:
    var e = thp_enabled_policy()
    var d = thp_defrag_policy()
    var want = String("thp_policy: enabled=[") + _enabled_word(e)
    want += String("] defrag=[") + _defrag_word(d) + "] THP_enabled="
    if thp_process_enabled() == THP_PROCESS_DISABLED:
        want += "0(PR_SET_THP_DISABLE)"
    else:
        want += "1"
    want += " compaction_hazard="
    want += "yes" if defrag_is_compaction_hazard(d) else "no"
    want += " -> auto="
    var mode = hugepage_auto_advice_mode()
    if mode == ADVICE_OFF:
        want += "off"
    elif mode == ADVICE_HUGEPAGE:
        want += "hugepage"
    else:
        want += String("unexpected:") + String(mode)
    assert_equal(thp_policy_report(), want)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
