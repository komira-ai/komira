# The shared conformance suite (komira_udf_spike_abi) against the Python
# runtime behind its worker transport, through the proxy runtime library,
# on four builds: workers spawned (pyworker_spawn.so) or forked from a zygote
# (pyworker_zygote.so) over shared memory, spawned over the socket alone
# (pyworker_pipe.so), and spawned with the worker's Arrow IPC read and
# written by pyarrow (pyworker_pyarrow.so). The same runner as echo and the
# in-process runtime; the engine side drives the C ABI table only.
#
# What it proves: every case a managed runtime's user code can express
# (komira_udf_spike_python's managed_cases) passes through the worker
# protocol: values, nulls under MANUAL and PROPAGATE, a sliced input (re-based
# by the engine's IPC writer), errors with their rows, messages and traces, a
# result the host must reject, cancel set before and during a call (the
# worker's clock reads forwarded to the host, the flag forwarded back), a
# passed deadline, two contexts (two workers) giving the same answer,
# validate's refusals, and every exported array released. The pyarrow build
# shows the engine's IPC messages are Arrow IPC pyarrow reads, and that the
# engine reads what pyarrow writes.
#
# The capabilities check fails, and only it, on purpose: the worker reports
# transports WORKER, and the runner requires IN_PROCESS ("the in-process
# path is what this suite drives"). The test pins that reason.
#
# Defects caught: the engine's IPC writer ignoring the offset of a
# one-argument batch (sliced_input_offset; two arguments at different
# offsets are test_worker_calls' two_args), a validity bitmap re-based
# wrongly, a null count
# lost on the wire, an error's row or message lost, cancel not forwarded.
#
# Mutant planted: ipc_codec.c copy_bits reading from bit 0 instead of the
# array's offset: red on sliced_input_offset (and only there).

from std.testing import assert_equal, assert_true

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
    for v in ["spawn", "zygote", "pipe", "pyarrow"]:
        var report = run_suite("./pyworker_" + v + ".so", cases)
        print(v, report)
        assert_equal(report.runtime_id, "komira-test/python-worker", v)
        var caps = report.result("capabilities")
        assert_equal(caps.verdict, "FAIL", v)
        assert_true(caps.reason.startswith("transports lacks IN_PROCESS"), v + ": " + caps.reason)
        assert_equal(report.count("FAIL"), 1, v + ": cases failed besides capabilities")
        assert_equal(report.count("SKIP"), SKIPPED, v + ": cases skipped")
        assert_equal(report.count("PASS"), RUN - SKIPPED, v + ": every case run passes")
    print("test_conform_worker: ok")
