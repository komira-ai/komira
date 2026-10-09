# The shared conformance suite (komira_udf_spike_abi) against the Python
# runtime python_subinterp.so: one sub-interpreter with its own GIL per context. Driven through the C ABI
# only, by the same runner as the reference runtime.
#
# What it proves: every case a managed runtime's user code can express
# (managed_cases.mojo) passes on CPython embedded behind the table: values,
# nulls under MANUAL and PROPAGATE, a sliced input's offset, an error with
# its row and message, a result the host must reject, the cancel flag set
# before and during a call, a passed deadline, two contexts giving the same
# answer, and validate's refusals from the function's source alone. The
# shapes the runtime does not declare (ROW, frames, aggregates, steps) are
# skipped and counted; every array the host exported is released once.
#
# Defects caught: the adapter's list reader (_lists, the column shape)
# reading a sliced argument from offset 0 (the corpus's one sliced case is a
# list[int] column; the per-row and numpy readers' offsets are
# test_python_subinterp's and test_python_shared_gil's), or
# writing a null as a value; the runtime holding an argument array past its
# call (the ledger); cancel or a deadline ignored; validate accepting a
# signature the hints contradict.
#
# Mutant planted: komira_udf_pyrt.py's _lists reading from 0 instead of the
# array offset: red on sliced_input_offset.

from std.testing import assert_equal

from komira_udf_spike_abi.conform import run_suite
from komira_udf_spike_python.managed_cases import managed_cases

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime RUN = 30
"""The corpus's 38 cases less the 8 runtime-fault ones."""
comptime SKIPPED = 9
"""The cases of shapes this runtime does not declare."""


def main() raises:
    var cases = managed_cases(CASES)
    assert_equal(len(cases), RUN, "cases loaded from " + CASES)
    var report = run_suite("./python_subinterp.so", cases)
    print(report)
    assert_equal(report.runtime_id, "komira-test/python")
    assert_equal(report.count("FAIL"), 0, "cases failed")
    assert_equal(report.count("SKIP"), SKIPPED, "cases skipped")
    assert_equal(report.count("PASS"), RUN - SKIPPED + 1, "every case run and the capabilities check pass")
    print("test_conform_subinterp: ok")
