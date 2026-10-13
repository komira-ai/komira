# The shared conformance suite (komira_udf_spike_abi) against the Node.js
# runtime on the worker transport: node_worker.so, the worker proxy, which
# runs each context in its own `node` process. Driven through the C ABI
# only, by the same runner as the reference runtime.
#
# What it proves: every case user code can express (node_cases.mojo: 93 of
# the corpus's 158) runs
# through the proxy and a worker: values; nulls under MANUAL and PROPAGATE;
# a sliced input's offset (re-based by the proxy's IPC encoder); an error
# with its row, message and trace; results the host must reject; the cancel
# flag set before and during a call (the worker reads the cancel word
# between rows); a passed deadline; two contexts (two processes) giving the
# same answer; ROW reads by name and a refused undeclared read, caught or
# not; frames that yield before reading all input, raise after yielding, or
# never end; a plain aggregate across batches; a mergeable aggregate split
# PARTIAL/FINAL across three workers; a step; validate's refusals from the
# descriptor alone (version 1: the signature lives in the descriptor, so the
# types the bundler erased are still compared); bisection of a batch that
# raises naming no row, and none of a VOLATILE one; nested calls on a
# frame's context while it waits on its input (a scalar, and a frame over a
# frame over a scalar, served by the worker from inside the frame's wait);
# a cancel or a deadline met while a pull is held; the host's breaches as
# ERR_HOST_CONTRACT; every array and stream the host exported released once.
#
# Every result passes, the capability check included (how a runtime
# executes is not a capability, design section 4.2), and one case is
# skipped: the NATIVE-only one.
#
# Defects caught: the worker's cancel check, the proxy's IPC encoder
# re-basing offsets and validity bits, the frame input exchange, the
# aggregate state across workers, the error row and message.
#
# Mutant planted: worker/calls.mjs Watch.check not reading the cancel word
# (cancelRequested replaced by false): red on cancel_set_during_call, which
# gets ERR_KILLED: the worker keeps running rows, so the proxy kills it once
# its 500 ms grace period after the cancel ends. worker/frames.mjs
# needInput aborting on any other request, as it did before nesting: red on
# nested_scalar_in_pull.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import run_suite
from komira_udf_spike_node_worker.node_cases import node_cases
from komira_udf_spike_node_worker.watchdog import arm_watchdog

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime RUN = 93
"""The corpus's 158 cases less the 65 left out (node_cases.mojo)."""


def main() raises:
    arm_watchdog()
    var cases = node_cases(CASES)
    assert_equal(len(cases), RUN, "cases loaded from " + CASES)
    var report = run_suite("./node_worker.so", cases)
    print(report)
    assert_equal(report.runtime_id, "komira-test/node")
    assert_equal(report.count("SKIP"), 1, "cases skipped")
    assert_equal(report.result("validate_recorded_fields_absent_native").verdict, "SKIP", "the NATIVE-only case")
    assert_equal(report.result("capabilities").verdict, "PASS", "capabilities")
    assert_equal(report.result("validate_wrong_signature").verdict, "PASS", "validate_wrong_signature")
    assert_equal(report.count("FAIL"), 0, "cases failed")
    assert_equal(report.count("PASS"), RUN, "every case run, and the capabilities check, pass")
    print("test_conform_node_worker: ok")
