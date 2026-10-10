# The conformance runner's own checks, each shown to fail: every case under
# cases_runner/ is meant to fail on the reference runtime echo.so, and the
# runner must fail it for the reason its "runner_fails_with" names (or skip
# it, for "SKIP").
#
# What it proves: each comparison the runner makes against a case's
# expectation (status, message present, run error, an unexpected host fault,
# the expected fault's text, error row exact and at least, column values, nulls, length and float
# tolerance, the split run, frame batch count, values, length and first
# output, the aggregate's result and an expected fault that never came,
# validate's status) and each release-ledger rule (an array released twice,
# a borrowed schema released, an input stream not released, reserved bytes
# still held) goes off; and a case of a shape the runtime does not report is
# skipped, not run. The fixtures behind the ledger cases (release_args_twice,
# release_schema, stream_kept, leak_reservation) and raise_no_message are
# echo entries no case under cases/ uses.
#
# Defect caught: a runner check deleted or weakened, so the suite passes a
# runtime that breaks the rule it stands for (test_conform_echo cannot see
# that: a weakened check passes every good runtime). Each mutant is listed
# with this file in the pull request's sweep table.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import load_cases, run_suite

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases_runner"
comptime CASE_COUNT = 29
"""The JSON files under cases_runner/: an empty or partial staging cannot
pass."""


def main() raises:
    var cases = load_cases(CASES)
    assert_equal(len(cases), CASE_COUNT, "cases loaded from " + CASES)
    var report = run_suite("./echo.so", cases)
    print(report)
    assert_equal(report.result("capabilities").verdict, "PASS")
    for i in range(len(cases)):
        ref c = cases[i]
        assert_true(c.runner_fails_with != "", c.name + " has no runner_fails_with")
        var r = report.result(c.name)
        if c.runner_fails_with == "SKIP":
            assert_equal(r.verdict, "SKIP", c.name + ": " + r.reason)
            continue
        assert_equal(r.verdict, "FAIL", c.name + " passed: the runner check it targets did not go off")
        assert_true(
            c.runner_fails_with in r.reason,
            c.name + " failed for another reason: '" + r.reason + "', wanted '" + c.runner_fails_with + "'",
        )
    assert_equal(report.count("FAIL"), CASE_COUNT - 1)
    assert_equal(report.count("SKIP"), 1)
    print("test_conform_runner: ok")
