# =============================================================================
# test_thp_parse.mojo — the pure half of `thp_policy`: the three file parsers,
# the decision table, the name ladders, and the small-file reader.
# =============================================================================
#
# Every parser and the decision table take file CONTENTS as a `String`, so the
# whole table is asserted here from literal text, on every host, whatever the
# host's own THP policy is. The reader is exercised against files this test
# writes under `TEST_TMPDIR`: a missing file, an empty file, a file holding
# bytes >= 0x80 (which must come back byte for byte, not re-encoded), and files
# on both sides of the 8 KiB read cap.
# =============================================================================

from std.os import getenv
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_host.thp_policy import (
    ADVICE_HUGEPAGE,
    ADVICE_OFF,
    ADVICE_POPULATE,
    THP_DEFRAG_ALWAYS,
    THP_DEFRAG_DEFER,
    THP_DEFRAG_DEFER_MADVISE,
    THP_DEFRAG_MADVISE,
    THP_DEFRAG_NEVER,
    THP_DEFRAG_UNKNOWN,
    THP_ENABLED_ALWAYS,
    THP_ENABLED_MADVISE,
    THP_ENABLED_NEVER,
    THP_ENABLED_UNKNOWN,
    THP_PROCESS_AVAILABLE,
    THP_PROCESS_DISABLED,
    _ThpSnapshot,
    _defrag_name,
    _enabled_name,
    _mode_name,
    _read_small_file,
    defrag_is_compaction_hazard,
    parse_bracketed_token,
    parse_thp_defrag,
    parse_thp_enabled,
    parse_thp_process_enabled,
    resolve_auto_mode,
)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _scratch(name: String) raises -> String:
    var base = getenv("TEST_TMPDIR")
    if base.byte_length() == 0:
        raise Error("TEST_TMPDIR is not set")
    return base + String("/") + name


def _write(path: String, bytes: List[UInt8]) raises:
    with open(path, "w") as f:
        f.write_bytes(Span(bytes))


def _ascii(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    for b in s.as_bytes():
        out.append(b)
    return out^


def _repeat(byte: UInt8, n: Int) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(byte)
    return out^


# -----------------------------------------------------------------------------
# parse_bracketed_token
# -----------------------------------------------------------------------------


def test_bracketed_token_is_the_active_value() raises:
    assert_equal(parse_bracketed_token("always [madvise] never\n"), "madvise")
    assert_equal(
        parse_bracketed_token("always defer [defer+madvise] madvise never"),
        "defer+madvise",
    )
    # The FIRST bracket wins; a later one is not looked at.
    assert_equal(parse_bracketed_token("[always] madvise [never]"), "always")


def test_bracketed_token_refuses_what_has_no_closed_bracket() raises:
    assert_equal(parse_bracketed_token(""), "")
    assert_equal(parse_bracketed_token("always madvise never"), "")
    # Unterminated: the tail after '[' is NOT the token.
    assert_equal(parse_bracketed_token("always [madvise"), "")
    assert_equal(parse_bracketed_token("always ["), "")
    assert_equal(parse_bracketed_token("[]"), "")


# -----------------------------------------------------------------------------
# parse_thp_enabled / parse_thp_defrag
# -----------------------------------------------------------------------------


def test_enabled_parses_each_kernel_value() raises:
    assert_equal(parse_thp_enabled("[always] madvise never"), THP_ENABLED_ALWAYS)
    assert_equal(parse_thp_enabled("always [madvise] never"), THP_ENABLED_MADVISE)
    assert_equal(parse_thp_enabled("always madvise [never]"), THP_ENABLED_NEVER)


def test_enabled_fails_closed_on_anything_else() raises:
    assert_equal(parse_thp_enabled(""), THP_ENABLED_UNKNOWN)
    assert_equal(parse_thp_enabled("madvise"), THP_ENABLED_UNKNOWN)
    assert_equal(parse_thp_enabled("[defer]"), THP_ENABLED_UNKNOWN)
    assert_equal(parse_thp_enabled("[Madvise]"), THP_ENABLED_UNKNOWN)


def test_defrag_parses_each_of_its_five_values() raises:
    var line = String("always defer defer+madvise madvise never")
    assert_equal(
        parse_thp_defrag("[always] defer defer+madvise madvise never"),
        THP_DEFRAG_ALWAYS,
    )
    assert_equal(
        parse_thp_defrag("always [defer] defer+madvise madvise never"),
        THP_DEFRAG_DEFER,
    )
    assert_equal(
        parse_thp_defrag("always defer [defer+madvise] madvise never"),
        THP_DEFRAG_DEFER_MADVISE,
    )
    assert_equal(
        parse_thp_defrag("always defer defer+madvise [madvise] never"),
        THP_DEFRAG_MADVISE,
    )
    assert_equal(
        parse_thp_defrag("always defer defer+madvise madvise [never]"),
        THP_DEFRAG_NEVER,
    )
    assert_equal(parse_thp_defrag(line), THP_DEFRAG_UNKNOWN)
    assert_equal(parse_thp_defrag("[madvise+defer]"), THP_DEFRAG_UNKNOWN)
    assert_equal(parse_thp_defrag(""), THP_DEFRAG_UNKNOWN)


def test_compaction_hazard_table() raises:
    assert_true(defrag_is_compaction_hazard(THP_DEFRAG_ALWAYS))
    assert_true(defrag_is_compaction_hazard(THP_DEFRAG_MADVISE))
    assert_true(defrag_is_compaction_hazard(THP_DEFRAG_DEFER_MADVISE))
    assert_true(defrag_is_compaction_hazard(THP_DEFRAG_UNKNOWN))
    assert_false(defrag_is_compaction_hazard(THP_DEFRAG_DEFER))
    assert_false(defrag_is_compaction_hazard(THP_DEFRAG_NEVER))


# -----------------------------------------------------------------------------
# parse_thp_process_enabled
# -----------------------------------------------------------------------------


def test_process_enabled_reads_the_field_on_a_later_line() raises:
    var on = String("Name:\tmojo\nUmask:\t0022\nTHP_enabled:\t1\nThreads:\t4\n")
    var off = String("Name:\tmojo\nUmask:\t0022\nTHP_enabled:\t0\nThreads:\t4\n")
    assert_equal(parse_thp_process_enabled(on), THP_PROCESS_AVAILABLE)
    assert_equal(parse_thp_process_enabled(off), THP_PROCESS_DISABLED)


def test_process_enabled_skips_tabs_and_spaces_before_the_digit() raises:
    assert_equal(
        parse_thp_process_enabled("THP_enabled:   0\n"), THP_PROCESS_DISABLED
    )
    assert_equal(
        parse_thp_process_enabled("THP_enabled:\t \t0"), THP_PROCESS_DISABLED
    )
    assert_equal(
        parse_thp_process_enabled("THP_enabled:7\n"), THP_PROCESS_AVAILABLE
    )


def test_process_enabled_absent_or_unparseable_is_available() raises:
    assert_equal(parse_thp_process_enabled(""), THP_PROCESS_AVAILABLE)
    assert_equal(
        parse_thp_process_enabled("Name:\tmojo\nThreads:\t4\n"),
        THP_PROCESS_AVAILABLE,
    )
    # Present but no digit before the line ends, or the buffer ends.
    assert_equal(
        parse_thp_process_enabled("THP_enabled:\t\nX:\t0\n"),
        THP_PROCESS_AVAILABLE,
    )
    assert_equal(parse_thp_process_enabled("THP_enabled:\t"), THP_PROCESS_AVAILABLE)
    # The key must be followed by ':' ...
    assert_equal(parse_thp_process_enabled("THP_enabled 0\n"), THP_PROCESS_AVAILABLE)
    # ... must start the line ...
    assert_equal(
        parse_thp_process_enabled("xTHP_enabled:\t0\n"), THP_PROCESS_AVAILABLE
    )
    # ... must match every byte ...
    assert_equal(
        parse_thp_process_enabled("THP_enablex:\t0\n"), THP_PROCESS_AVAILABLE
    )
    # ... and a key that ends the buffer has no ':' after it.
    assert_equal(parse_thp_process_enabled("A\nTHP_enabled"), THP_PROCESS_AVAILABLE)


# -----------------------------------------------------------------------------
# resolve_auto_mode and the snapshot
# -----------------------------------------------------------------------------


def test_auto_mode_table() raises:
    for defrag in range(THP_DEFRAG_UNKNOWN, THP_DEFRAG_NEVER + 1):
        # Row 4: the only HUGEPAGE row.
        assert_equal(
            resolve_auto_mode(THP_ENABLED_MADVISE, defrag, THP_PROCESS_AVAILABLE),
            ADVICE_HUGEPAGE,
        )
        # Row 1: PR_SET_THP_DISABLE overrides even [madvise].
        assert_equal(
            resolve_auto_mode(THP_ENABLED_MADVISE, defrag, THP_PROCESS_DISABLED),
            ADVICE_OFF,
        )
        # Rows 2, 3, 5.
        assert_equal(
            resolve_auto_mode(THP_ENABLED_NEVER, defrag, THP_PROCESS_AVAILABLE),
            ADVICE_OFF,
        )
        assert_equal(
            resolve_auto_mode(THP_ENABLED_ALWAYS, defrag, THP_PROCESS_AVAILABLE),
            ADVICE_OFF,
        )
        assert_equal(
            resolve_auto_mode(THP_ENABLED_UNKNOWN, defrag, THP_PROCESS_AVAILABLE),
            ADVICE_OFF,
        )
        assert_equal(resolve_auto_mode(99, defrag, THP_PROCESS_AVAILABLE), ADVICE_OFF)


def test_snapshot_resolves_its_mode_and_unknown_is_closed() raises:
    var s = _ThpSnapshot(
        THP_ENABLED_MADVISE, THP_DEFRAG_DEFER, THP_PROCESS_AVAILABLE
    )
    assert_equal(s.enabled, THP_ENABLED_MADVISE)
    assert_equal(s.defrag, THP_DEFRAG_DEFER)
    assert_equal(s.proc_enabled, THP_PROCESS_AVAILABLE)
    assert_equal(s.mode, ADVICE_HUGEPAGE)
    var u = _ThpSnapshot.unknown()
    assert_equal(u.enabled, THP_ENABLED_UNKNOWN)
    assert_equal(u.defrag, THP_DEFRAG_UNKNOWN)
    assert_equal(u.proc_enabled, THP_PROCESS_AVAILABLE)
    assert_equal(u.mode, ADVICE_OFF)


# -----------------------------------------------------------------------------
# The name ladders
# -----------------------------------------------------------------------------


def test_enabled_and_defrag_names() raises:
    assert_equal(String(_enabled_name(THP_ENABLED_ALWAYS)), "always")
    assert_equal(String(_enabled_name(THP_ENABLED_MADVISE)), "madvise")
    assert_equal(String(_enabled_name(THP_ENABLED_NEVER)), "never")
    assert_equal(String(_enabled_name(THP_ENABLED_UNKNOWN)), "unknown")
    assert_equal(String(_enabled_name(42)), "unknown")
    assert_equal(String(_defrag_name(THP_DEFRAG_ALWAYS)), "always")
    assert_equal(String(_defrag_name(THP_DEFRAG_DEFER)), "defer")
    assert_equal(String(_defrag_name(THP_DEFRAG_DEFER_MADVISE)), "defer+madvise")
    assert_equal(String(_defrag_name(THP_DEFRAG_MADVISE)), "madvise")
    assert_equal(String(_defrag_name(THP_DEFRAG_NEVER)), "never")
    assert_equal(String(_defrag_name(THP_DEFRAG_UNKNOWN)), "unknown")
    assert_equal(String(_defrag_name(-3)), "unknown")


def test_mode_names() raises:
    assert_equal(_mode_name(ADVICE_OFF), "off")
    assert_equal(_mode_name(ADVICE_HUGEPAGE), "hugepage")
    assert_equal(_mode_name(ADVICE_POPULATE), "populate")
    assert_equal(_mode_name(ADVICE_HUGEPAGE | ADVICE_POPULATE), "hugepage|populate")
    assert_equal(_mode_name(7), "mode:7")
    assert_equal(_mode_name(-1), "mode:-1")


# -----------------------------------------------------------------------------
# _read_small_file
# -----------------------------------------------------------------------------


def test_reader_missing_and_empty_files_read_empty() raises:
    var empty = _scratch("thp_empty")
    _write(empty, List[UInt8]())
    assert_equal(_read_small_file(_scratch("thp_no_such_file")), "")
    assert_equal(_read_small_file(empty), "")


def test_reader_keeps_bytes_above_0x7f_unchanged() raises:
    var path = _scratch("thp_high_bytes")
    # "é" (C3 A9), then the policy line, then a 4-byte code point (F0 9F 98 80).
    var bytes = List[UInt8]()
    bytes.append(0xC3)
    bytes.append(0xA9)
    bytes.extend(_ascii(" [madvise] "))
    bytes.append(0xF0)
    bytes.append(0x9F)
    bytes.append(0x98)
    bytes.append(0x80)
    _write(path, bytes)
    var got = _read_small_file(path)
    comptime if CompilationTarget.is_linux():
        var gb = got.as_bytes()
        assert_equal(len(gb), len(bytes), "a byte >= 0x80 must stay one byte")
        for i in range(len(bytes)):
            assert_equal(gb[i], bytes[i], "byte " + String(i))
        assert_equal(parse_thp_enabled(got), THP_ENABLED_MADVISE)
    else:
        assert_equal(got, "")


def test_reader_caps_at_8_kib() raises:
    var at_cap = _scratch("thp_8192")
    var over_cap = _scratch("thp_9000")
    _write(at_cap, _repeat(0x61, 8192))
    _write(over_cap, _repeat(0x62, 9000))
    comptime if CompilationTarget.is_linux():
        assert_equal(_read_small_file(at_cap).byte_length(), 8192)
        var got = _read_small_file(over_cap)
        assert_equal(got.byte_length(), 8192, "read stops at the cap")
        assert_equal(Int(got.as_bytes()[8191]), 0x62)
    else:
        assert_equal(_read_small_file(at_cap), "")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
