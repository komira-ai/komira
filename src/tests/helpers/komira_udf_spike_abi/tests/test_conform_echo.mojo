# The conformance suite against the reference runtime echo.so
# (the :echo target, refrt/echo_runtime.c), through the C ABI only.
#
# What it proves: every case under cases/ passes on a runtime that keeps the
# contract, with no case skipped, and the describe answer passes the
# capability checks. With test_conform_broken (the same suite failing on
# exactly the planted defects of echo_broken.so) it shows the suite can pass
# and can fail.
#
# Defects caught: a harness that breaks a rule of the contract itself (a
# post-condition that fires on a correct output, a release counted wrongly,
# compaction under PROPAGATE that drops or misplaces rows, a stream handed
# out wrongly) fails a case here.
#
# Mutants planted: runtime.mojo's PROPAGATE compaction keeps rows with a null
# argument (`all_valid = True` where it is set False): scalar_nulls_propagate
# goes red. runtime.mojo starting no cancel timer: cancel_set_during_call goes
# red (the call runs to the end and returns OK). _host.mojo's check_device
# returning at once: fault_output_not_on_cpu goes red. The PROPAGATE null scan
# reading only the first argument: scalar_nulls_propagate_second_arg goes red.
# The length post-condition weakened to `len(col) < rows`: column_long_by_one
# goes red. _moved_check not releasing an input the runtime kept: the ledger
# of fault_agg_args_not_moved goes red. run_frame recording no fault when its
# bound is reached: fault_frame_never_ends goes red. The mutants of the
# review fixes that added the cases after those (an output's offset ignored,
# the PROPAGATE scatter's validity forced, the agg_state and agg_finish
# lengths not checked, each import and ownership check weakened) are listed
# with the case each one turned red in the pull request's sweep table; each
# case's "defect" names what it catches.

from std.testing import assert_equal

from komira_udf_spike_abi.conform import load_cases, run_suite

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime CASE_COUNT = 76
"""The JSON files under cases/: an empty or partial staging cannot pass."""


def main() raises:
    var cases = load_cases(CASES)
    assert_equal(len(cases), CASE_COUNT, "cases loaded from " + CASES)
    var report = run_suite("./echo.so", cases)
    print(report)
    assert_equal(report.runtime_id, "komira-test/echo")
    assert_equal(report.count("FAIL"), 0, "cases failed on the reference runtime")
    assert_equal(report.count("SKIP"), 0, "cases skipped on the reference runtime")
    assert_equal(report.count("PASS"), CASE_COUNT + 1, "every case and the capabilities check pass")
    print("test_conform_echo: ok")
