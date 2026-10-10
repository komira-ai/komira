# The conformance suite against echo_broken.so
# (the :echo_broken target): echo's source
# with seven planted defects (echo_runtime.c lists them). The suite must fail
# on exactly the cases that name those defects, each for the reason it
# names, and pass every other case.
#
# What it proves: the suite can fail. Each planted defect is caught by a case:
#   1. args not released when the fixture raises      raise_on_row_3, fault_out_set_on_error,
#                                                      scalar_propagate_error_row,
#                                                      column_propagate_error_no_row and the three
#                                                      fault_error_row_* cases (the release ledger)
#   2. int64 bits in a float64 result                  column_float_result
#   3. the cancel flag never read                      cancel_set_before_call, cancel_set_during_call,
#                                                      frame_cancelled_at_open
#   4. agg_merge overwrites instead of adding          agg_mergeable_sum
#   5. the input offset ignored                        sliced_input_offset
#   6. a per-instance call counter in the result       split_across_contexts
#   7. a caught undeclared ROW read not reported       row_caught_violation
# and no other case fails, so a harness that fails everything cannot pass.
#
# Mutant planted: conform.mojo's _ledger_check returning "" first (no
# release accounting): raise_on_row_3 passes on echo_broken, the failing set
# differs, red; test_conform_echo stays green.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import load_cases, run_suite

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"


def _expected() -> List[String]:
    """`<case>|<a fragment of its failure reason>`, in case-name order (the
    order run_suite reports them)."""
    return [
        "agg_mergeable_sum|row 0",
        "agg_partials_differ_in_groups|row 0",
        "cancel_set_before_call|expected ERR_CANCELLED",
        "cancel_set_during_call|expected ERR_CANCELLED",
        "column_float_result|row 0",
        "column_float_rounding|row 0",
        "column_propagate_error_no_row|released",
        "error_row_at_least_edge|released",
        "error_row_left_unset|released",
        "fault_error_row_below_minus_one|released",
        "fault_error_row_past_batch|released",
        "fault_error_row_past_batch_propagate|released",
        "fault_out_set_on_error|released",
        "frame_cancelled_at_open|expected ERR_CANCELLED",
        "raise_on_row_3|released",
        "row_caught_violation|expected ERR_FIELD_NOT_DECLARED",
        "scalar_propagate_error_row|released",
        "sliced_input_offset|row 0",
        "sliced_input_offset_first_null|row 0",
        "split_across_contexts|two batches on a second instance",
    ]


def main() raises:
    var cases = load_cases(CASES)
    assert_equal(len(cases), 107, "cases loaded from " + CASES)
    var report = run_suite("./echo_broken.so", cases)
    print(report)
    assert_equal(report.runtime_id, "komira-test/echo-broken")
    assert_equal(report.result("capabilities").verdict, "PASS")
    assert_equal(report.count("SKIP"), 0)
    var want = _expected()
    var failed = List[String]()
    for i in range(len(report.results)):
        if report.results[i].verdict == "FAIL":
            failed.append(report.results[i].name)
    var got = String(", ").join(failed)
    var names = List[String]()
    for i in range(len(want)):
        names.append(String(want[i].split("|")[0]))
    assert_equal(got, String(", ").join(names), "the cases that fail on echo_broken.so")
    for i in range(len(want)):
        var parts = want[i].split("|")
        var r = report.result(String(parts[0]))
        assert_true(String(parts[1]) in r.reason, r.name + " failed for another reason: " + r.reason)
        assert_true("[defect caught: " in r.reason, r.name + " does not name its defect")
    print("test_conform_broken: ok")
