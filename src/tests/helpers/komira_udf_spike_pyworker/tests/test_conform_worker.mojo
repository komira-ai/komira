# The shared conformance suite (komira_udf_spike_abi) against the Python
# worker runtime, through its runtime library, on two builds: the runtime
# (pyworker_zygote.so: a zygote, context workers forked from it, payloads in
# shared memory) and the same with the workers' Arrow IPC read and written
# by pyarrow (pyworker_pyarrow.so). The same runner as echo; the engine
# side drives the C ABI table only.
#
# What it proves: every case a managed runtime's user code can express
# (managed_cases.mojo: the corpus less the cases whose fixtures are runtime
# bugs only C code commits) passes through the worker protocol: values,
# nulls under MANUAL and PROPAGATE, a sliced input (re-based by the engine's
# IPC writer), errors with their rows, messages and traces, a result the
# host must reject, cancel set before and during a call (the worker's clock
# reads forwarded to the host, the flag forwarded back), deadlines passed
# before and during a call, two contexts (two workers) giving the same
# answer, validate's refusals, and every exported array released. The
# pyarrow build shows the engine's IPC messages are Arrow IPC pyarrow
# reads, and that the engine reads what pyarrow writes.
#
# The capabilities check passes: the runtime id's grammar, CPU, class
# MANAGED, and features CONTAINS_CRASHES and FORCED_STOP, both defined, with
# no memory_report entry and no MEMORY_REPORT bit.
#
# Defects caught: the engine's IPC writer ignoring the offset of a
# one-argument batch (sliced_input_offset; two arguments at different
# offsets are test_worker_calls' two_args), a validity bitmap re-based
# wrongly, a null count lost on the wire, an error's row or message lost,
# cancel not forwarded.
#
# Mutant planted: ipc_codec.c copy_bits reading from bit 0 instead of the
# array's offset: red on sliced_input_offset (and only there).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import run_suite
from komira_udf_spike_pyworker.managed_cases import managed_cases

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime RUN = 85
"""The corpus's 164 cases less managed_cases' 79 left out."""
comptime SKIPPED = 33
"""The cases of shapes this runtime does not declare."""


def main() raises:
    var cases = managed_cases(CASES)
    assert_equal(len(cases), RUN, "cases loaded from " + CASES)
    for v in ["zygote", "pyarrow"]:
        var report = run_suite("./pyworker_" + v + ".so", cases)
        print(v, report)
        assert_equal(report.runtime_id, "komira-test/python-worker", v)
        var caps = report.result("capabilities")
        assert_equal(caps.verdict, "PASS", v + ": " + caps.reason)
        assert_equal(report.count("FAIL"), 0, v + ": cases failed")
        assert_equal(report.count("SKIP"), SKIPPED, v + ": cases skipped")
        assert_equal(report.count("PASS"), RUN - SKIPPED + 1, v + ": every case run passes, and capabilities")
    print("test_conform_worker: ok")
