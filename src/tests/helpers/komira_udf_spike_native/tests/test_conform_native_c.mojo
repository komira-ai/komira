# The conformance suite against the native runtime (:native) loading the C
# native UDF library (:native_c), through the C ABI only.
#
# What it proves: every case of the corpus, and its double and fahrenheit
# cases again on double_batch and fahrenheit_batch (the batch-loop
# fixtures), passes on a native C library behind the native runtime, none
# left out (the C library is echo_runtime.c built as a native library, so it
# has every fixture, the ABI-breaking ones included) and two skipped: the
# MANAGED-only case, and the one about a shape the runtime lacks (it has
# every shape). The native runtime's describe passes the capability checks:
# the runtime verifies the library's digest, loads it, and forwards every
# entry without changing what a case sees, the nested calls of a frame's
# pull included.
#
# Defects caught: a forwarding entry that drops or swaps an argument, a
# handle of the library's handed back where the runtime's is expected, a
# stream or array the runtime keeps or releases twice (the release ledger of
# every case), code objects that never reach the runtime.
#
# Mutants planted: native_runtime.c's frame_close freeing its own handle
# without forwarding to the library's: red on every frame case's ledger
# ("an input stream was not released"), here and in test_conform_native_mojo.
# The harness's new_spec writing no code objects (n_code 0): red on every
# case ("no library for this host's platform").

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import load_cases, run_suite
from komira_udf_spike_native.code import code_set, with_batch_twins

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime CASE_COUNT = 159
comptime BATCH_TWINS = 6
"""The corpus cases on double or fahrenheit, each run again on its batch-loop
fixture (code.with_batch_twins)."""


def main() raises:
    var corpus = load_cases(CASES)
    assert_equal(len(corpus), CASE_COUNT, "cases loaded from " + CASES)
    var cases = with_batch_twins(corpus)
    assert_equal(len(cases), CASE_COUNT + BATCH_TWINS, "the batch-loop twins")
    # Each twin runs its batch fixture, not the generic one it copies.
    var twins = 0
    for i in range(len(cases)):
        if cases[i].name.endswith("_batch_twin"):
            assert_true(cases[i].spec.entry.endswith("_batch"), cases[i].name + " runs " + cases[i].spec.entry)
            twins += 1
    assert_equal(twins, BATCH_TWINS, "twins on a batch-loop fixture")
    var code = code_set("./native_c.so", getenv("TMPDIR") + "/code")
    var report = run_suite("./native.so", cases, code)
    print(report)
    assert_equal(report.runtime_id, "komira/native")
    assert_equal(report.count("FAIL"), 0, "cases failed on the native C library")
    assert_equal(report.count("SKIP"), 2, "cases skipped on the native C library")
    assert_equal(report.result("validate_recorded_fields_absent_managed").verdict, "SKIP")
    assert_equal(report.result("validate_unsupported_shape").verdict, "SKIP")
    assert_equal(report.count("PASS"), len(cases) - 1, "every case but the two skipped, and the capabilities check, pass")
    print("test_conform_native_c: ok")
