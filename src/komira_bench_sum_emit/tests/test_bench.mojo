# =============================================================================
# test_bench: a small table through every statement of the bench
# =============================================================================
#
# What it proves: over 4096 rows in four row groups, at one and at three
# threads, with two timed runs, every statement of the bench runs, the answer of
# every run matches the totals the generator computed (whether the engine
# declares the sum INT64 or DECIMAL(38, 0)), and the JSON holds one entry per
# statement and thread count. Catches an oracle that does not match the SQL, a
# statement the engine refuses, and a result that drops an entry.

from std.testing import TestSuite, assert_equal, assert_true

from komira_bench_sum_emit.bench import BenchSettings, run_bench
from komira_runtime_paths import test_tmpdir


def _count(text: String, needle: String) -> Int:
    var n = 0
    var start = 0
    while True:
        var at = text.find(needle, start)
        if at < 0:
            break
        n += 1
        start = at + needle.byte_length()
    return n


def test_every_statement_runs_and_matches_the_oracle() raises:
    var threads = List[Int]()
    threads.append(1)
    threads.append(3)
    var settings = BenchSettings(
        test_tmpdir() + "/sum_emit_smoke",
        String("smoke"),
        threads^,
        2,
        4096,
        1024,
        1024 * 1024 * 1024,
    )
    var result = run_bench(settings)
    assert_true(result.answers_match, result.json)
    assert_equal(_count(result.json, '"query":'), 10)
    assert_equal(_count(result.json, '"answers_match":true'), 10)
    assert_equal(_count(result.json, '"runs_ms":['), 10)
    assert_true('"label":"smoke"' in result.json)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
