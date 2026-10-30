# =============================================================================
# test_cli: the bench's command line
# =============================================================================
#
# What each test proves, and the defect it would catch:
#   * test_the_defaults: only --out-dir given, the settings are the defaults.
#     Catches a default that drifted from the README.
#   * test_every_flag_is_read: each flag lands in its own setting. Catches two
#     flags swapped.
#   * test_what_is_refused: a missing --out-dir, fewer than five runs, an
#     unknown flag, a repeated flag, a flag with no value and a bad thread
#     list are each refused with a message naming the flag.

from std.testing import TestSuite, assert_equal, assert_raises

from komira_bench_sum_emit.cli import parse_bench_args


def _args(a: String, b: String = "", c: String = "", d: String = "") -> List[String]:
    var out = List[String]()
    out.append(a)
    if b != "":
        out.append(b)
    if c != "":
        out.append(c)
    if d != "":
        out.append(d)
    return out^


def test_the_defaults() raises:
    var s = parse_bench_args(_args("--out-dir", "o"))
    assert_equal(s.out_dir, "o")
    assert_equal(s.runs, 9)
    assert_equal(s.rows, 16000000)
    assert_equal(s.row_group_rows, 1000000)
    assert_equal(len(s.threads), 2)
    assert_equal(s.threads[0], 1)
    assert_equal(s.threads[1], 8)
    assert_equal(s.memory_budget_bytes, 32 * 1024 * 1024 * 1024)


def test_every_flag_is_read() raises:
    var a = List[String]()
    for w in [
        "--out-dir", "dir", "--label", "pr2", "--threads", "2,4,6", "--runs", "7",
        "--rows", "1000", "--row-group-rows", "100", "--memory-limit-gib", "3",
    ]:
        a.append(String(w))
    var s = parse_bench_args(a)
    assert_equal(s.out_dir, "dir")
    assert_equal(s.label, "pr2")
    assert_equal(len(s.threads), 3)
    assert_equal(s.threads[2], 6)
    assert_equal(s.runs, 7)
    assert_equal(s.rows, 1000)
    assert_equal(s.row_group_rows, 100)
    assert_equal(s.memory_budget_bytes, 3 * 1024 * 1024 * 1024)


def test_what_is_refused() raises:
    with assert_raises(contains="--out-dir is required"):
        _ = parse_bench_args(_args("--runs", "9"))
    with assert_raises(contains="--runs must be at least 5"):
        _ = parse_bench_args(_args("--out-dir", "o", "--runs", "4"))
    with assert_raises(contains="unknown flag --bogus"):
        _ = parse_bench_args(_args("--out-dir", "o", "--bogus", "1"))
    with assert_raises(contains="--runs given twice"):
        var a = _args("--out-dir", "o", "--runs", "9")
        a.append("--runs")
        a.append("9")
        _ = parse_bench_args(a)
    with assert_raises(contains="--out-dir needs a value"):
        _ = parse_bench_args(_args("--out-dir"))
    with assert_raises(contains="--threads entries must be at least 1"):
        _ = parse_bench_args(_args("--out-dir", "o", "--threads", "0"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
