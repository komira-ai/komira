# The shared conformance suite's ROW cases (komira_udf_spike_abi/cases,
# row_*) against the row runtime python_row.so, through the same runner as
# the reference runtime: the corpus's `pick` and `pick_caught` fixtures,
# written in Python (pyrt/udf_rows.py).
#
# What it proves: a correct read set computes every row from the right
# child; a read outside the read set fails with ERR_FIELD_NOT_DECLARED at
# its row, with a message; a function that catches the language's error
# around that read still fails the batch; every exported array is released
# once (the runner's ledger). The corpus's other cases are of shapes this
# runtime does not declare; komira_udf_spike_python's suites run them.
#
# Mutant planted: komira_udf_rowrt.py's RowInstance._rows without its
# check after a successful row (only uncaught violations reported): red on
# row_caught_violation.

from std.testing import assert_equal

from komira_udf_spike_abi.cases import Case
from komira_udf_spike_abi.conform import load_cases, run_suite
from komira_udf_spike_abi.contract import SHAPE_ROW

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime ROW_CASES = 3
"""row_caught_violation, row_declared_fields, row_undeclared_field."""


def main() raises:
    var all = load_cases(CASES)
    var cases = List[Case]()
    for i in range(len(all)):
        if all[i].spec.shape == SHAPE_ROW:
            var c = all[i].copy()
            c.spec.entry = "udf_rows:" + c.spec.entry
            cases.append(c^)
    assert_equal(len(cases), ROW_CASES, "ROW cases in " + CASES)
    var report = run_suite("./python_row.so", cases)
    print(report)
    assert_equal(report.runtime_id, "komira-test/python-row")
    assert_equal(report.count("FAIL"), 0, "cases failed")
    assert_equal(report.count("SKIP"), 0, "cases skipped")
    assert_equal(report.count("PASS"), ROW_CASES + 1, "every case run and the capabilities check pass")
    print("test_row_conform: ok")
