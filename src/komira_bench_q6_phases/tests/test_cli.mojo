# The probe's command line.
#
# What each test proves, and the defect it would catch:
# - test_defaults_and_cache_dir: only --cache-dir and --out-dir give threads
#   1, 8, 32 and 88, 9 runs, 32 GiB, the staged file under the cache directory
#   and no expected answer. Catches a changed default or a wrong staged path.
# - test_expect_flag_sets_the_sf1_answer: --expect-tpch-sf1 carries the
#   TPC-H answer. Catches a probe that never checks the answer.
# - test_refusals: each of these is refused with a reason naming the flag: no
#   input, both inputs, no --out-dir, fewer than 5 runs, an unknown flag, a
#   repeated flag, a flag with no value, a thread count of 0 or text.
#   Catches a run that starts on arguments it misread.

from std.testing import TestSuite, assert_equal, assert_true

from komira_bench_q6_phases.cli import parse_probe_args, parse_thread_list
from komira_bench_q6_phases.probe import (
    NO_EXPECTED_REVENUE,
    TPCH_SF1_Q6_REVENUE_UNSCALED,
)


def _args(*words: String) -> List[String]:
    var out = List[String]()
    for w in words:
        out.append(String(w))
    return out^


def _refused(args: List[String], needle: String) raises:
    try:
        _ = parse_probe_args(args)
    except e:
        assert_true(needle in String(e), "'" + String(e) + "' lacks '" + needle + "'")
        return
    assert_true(False, "expected a refusal containing '" + needle + "'")


def test_defaults_and_cache_dir() raises:
    var s = parse_probe_args(_args("--cache-dir", "/c", "--out-dir", "o"))
    assert_equal(s.lineitem_path, "/c/tpch/sf1/lineitem.parquet")
    assert_equal(s.out_dir, "o")
    assert_equal(len(s.threads), 4)
    assert_equal(s.threads[0], 1)
    assert_equal(s.threads[1], 8)
    assert_equal(s.threads[2], 32)
    assert_equal(s.threads[3], 88)
    assert_equal(s.runs, 9)
    assert_equal(s.memory_budget_bytes, 32 * 1024 * 1024 * 1024)
    assert_equal(s.expected_revenue, NO_EXPECTED_REVENUE)


def test_expect_flag_sets_the_sf1_answer() raises:
    var s = parse_probe_args(
        _args(
            "--lineitem", "f.parquet", "--out-dir", "o", "--threads", "2,4",
            "--runs", "5", "--expect-tpch-sf1",
        )
    )
    assert_equal(s.lineitem_path, "f.parquet")
    assert_equal(s.expected_revenue, TPCH_SF1_Q6_REVENUE_UNSCALED)
    assert_equal(len(s.threads), 2)
    assert_equal(s.runs, 5)


def test_refusals() raises:
    _refused(_args("--out-dir", "o"), "exactly one of")
    _refused(_args("--lineitem", "f", "--cache-dir", "c", "--out-dir", "o"), "exactly one of")
    _refused(_args("--lineitem", "f"), "--out-dir is required")
    _refused(_args("--lineitem", "f", "--out-dir", "o", "--runs", "4"), "at least 5")
    _refused(_args("--lineitem", "f", "--out-dir", "o", "--bogus", "1"), "unknown flag --bogus")
    _refused(_args("--lineitem", "f", "--lineitem", "g", "--out-dir", "o"), "given twice")
    _refused(_args("--lineitem", "f", "--out-dir"), "needs a value")
    _refused(_args("--lineitem", "f", "--out-dir", "o", "--threads", "0"), "at least 1")
    _refused(_args("--lineitem", "f", "--out-dir", "o", "--threads", "a"), "not a number")
    _refused(_args("--lineitem", "f", "--out-dir", "o", "--threads", "1,,2"), "not a number")


def test_thread_list() raises:
    var t = parse_thread_list("3")
    assert_equal(len(t), 1)
    assert_equal(t[0], 3)


def main() raises:
    var suite = TestSuite()
    suite.test[test_defaults_and_cache_dir]()
    suite.test[test_expect_flag_sets_the_sf1_answer]()
    suite.test[test_refusals]()
    suite.test[test_thread_list]()
    suite^.run()
