# The flags of the answers program.
#
# What each test proves:
# - test_the_three_required_flags_and_the_default_memory: with only the three
#   required flags the memory limit is 8 GiB, and both flag spellings parse.
# - test_a_memory_limit_is_a_positive_whole_number: a given limit is used; zero,
#   a negative number, a fraction and text are refused naming the flag.
# - test_a_missing_or_malformed_flag_is_refused: each required flag missing, an
#   unknown flag, a repeated flag, a flag with no value and a bare word each
#   raise.

from std.testing import TestSuite, assert_equal, assert_raises

from tpch_answers import DEFAULT_MEMORY_GIB, parse_answer_args


def _args(var words: List[String]) -> List[String]:
    return words^


def test_the_three_required_flags_and_the_default_memory() raises:
    var s = parse_answer_args(_args(["--duckdb", "d", "--cache-dir", "c", "--out-dir=o"]))
    assert_equal(s.duckdb, "d")
    assert_equal(s.cache_dir, "c")
    assert_equal(s.out_dir, "o")
    assert_equal(s.memory_limit_gib, DEFAULT_MEMORY_GIB)
    assert_equal(DEFAULT_MEMORY_GIB, 8)


def test_a_memory_limit_is_a_positive_whole_number() raises:
    var base = _args(["--duckdb", "d", "--cache-dir", "c", "--out-dir", "o"])
    var ok = base.copy()
    ok.append("--memory-limit-gib")
    ok.append("32")
    assert_equal(parse_answer_args(_args(ok^)).memory_limit_gib, 32)
    for bad in ["0", "-1", "1.5", "lots", ""]:
        var words = base.copy()
        words.append("--memory-limit-gib")
        words.append(String(bad))
        with assert_raises(contains="--memory-limit-gib"):
            _ = parse_answer_args(_args(words^))


def test_a_missing_or_malformed_flag_is_refused() raises:
    with assert_raises(contains="missing --duckdb"):
        _ = parse_answer_args(_args(["--cache-dir", "c", "--out-dir", "o"]))
    with assert_raises(contains="missing --cache-dir"):
        _ = parse_answer_args(_args(["--duckdb", "d", "--out-dir", "o"]))
    with assert_raises(contains="missing --out-dir"):
        _ = parse_answer_args(_args(["--duckdb", "d", "--cache-dir", "c"]))
    with assert_raises(contains="unknown flag --scale"):
        _ = parse_answer_args(_args(["--duckdb", "d", "--cache-dir", "c", "--out-dir", "o", "--scale", "1"]))
    with assert_raises(contains="--duckdb given twice"):
        _ = parse_answer_args(_args(["--duckdb", "d", "--duckdb", "e", "--cache-dir", "c", "--out-dir", "o"]))
    with assert_raises(contains="needs a value"):
        _ = parse_answer_args(_args(["--duckdb", "d", "--cache-dir", "c", "--out-dir"]))
    with assert_raises(contains="not a flag: stray"):
        _ = parse_answer_args(_args(["stray"]))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
