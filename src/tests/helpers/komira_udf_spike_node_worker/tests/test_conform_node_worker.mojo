# The shared conformance suite (komira_udf_spike_abi) against the Node.js
# runtime on the worker transport: node_worker.so, the worker proxy, which
# runs each context in its own `node` process. Driven through the C ABI
# only, by the same runner as the reference runtime.
#
# What it proves: every case user code can express (node_cases.mojo) runs
# through the proxy and a worker: values; nulls under MANUAL and PROPAGATE;
# a sliced input's offset (re-based by the proxy's IPC encoder); an error
# with its row, message and trace; results the host must reject; the cancel
# flag set before and during a call (the worker reads the cancel word
# between rows); a passed deadline; two contexts (two processes) giving the
# same answer; ROW reads by name and a refused undeclared read, caught or
# not; frames that yield before reading all input, raise after yielding, or
# never end; a plain aggregate across batches; a mergeable aggregate split
# PARTIAL/FINAL across three workers; a step; validate's refusals; every
# array and stream the host exported released once.
#
# Two results fail, and the test pins both, each with its reason (the
# pull request's "spec misfits"):
#   - capabilities: "transports lacks IN_PROCESS". The runner drives the
#     in-process path and requires the runtime to report it; this runtime
#     runs only as a worker.
#   - validate_wrong_signature: TypeScript's types are erased by the
#     bundler, so validate, which runs no user code, cannot see that
#     `double` takes an int64 and the spec declares a float64.
#
# Defects caught: the worker's cancel check, the proxy's IPC encoder
# re-basing offsets and validity bits, the frame input exchange, the
# aggregate state across workers, the error row and message.
#
# Mutant planted: worker/calls.mjs Watch.check not reading the cancel word
# (cancelRequested replaced by false): red on cancel_set_during_call, which
# gets ERR_INSTANCE_LOST: the worker keeps running rows, so the proxy kills
# it once its 500 ms grace period after the cancel ends.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import run_suite
from komira_udf_spike_node_worker.node_cases import node_cases

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime RUN = 31
"""The corpus's 38 cases less the 7 runtime-fault ones."""


def main() raises:
    var cases = node_cases(CASES)
    assert_equal(len(cases), RUN, "cases loaded from " + CASES)
    var report = run_suite("./node_worker.so", cases)
    print(report)
    assert_equal(report.runtime_id, "komira-test/node")
    assert_equal(report.count("SKIP"), 0, "cases skipped")
    var caps = report.result("capabilities")
    assert_equal(caps.verdict, "FAIL", "capabilities")
    assert_true("transports lacks IN_PROCESS" in caps.reason, caps.reason)
    var sig = report.result("validate_wrong_signature")
    assert_equal(sig.verdict, "FAIL", "validate_wrong_signature")
    assert_true("status OK" in sig.reason, sig.reason)
    assert_equal(report.count("FAIL"), 2, "cases failed beyond the two pinned")
    assert_equal(report.count("PASS"), RUN - 1, "every other case passes")
    print("test_conform_node_worker: ok")
