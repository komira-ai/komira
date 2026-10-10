# The conformance suite against the native runtime (:native) loading the C
# native UDF library (:native_c), through the C ABI only.
#
# What it proves: every case of the corpus passes on a native C library
# behind the native runtime, none skipped and none left out (the C library is
# echo_runtime.c built as a native library, so it has every fixture, the
# ABI-breaking ones included), and the native runtime's describe
# passes the capability checks: the runtime verifies the library's digest,
# loads it, and forwards every entry without changing what a case sees.
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
from std.testing import assert_equal

from komira_udf_spike_abi.conform import load_cases, run_suite
from komira_udf_spike_native.code import code_set

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime CASE_COUNT = 107


def main() raises:
    var cases = load_cases(CASES)
    assert_equal(len(cases), CASE_COUNT, "cases loaded from " + CASES)
    var code = code_set("./native_c.so", getenv("TMPDIR") + "/code")
    var report = run_suite("./native.so", cases, code)
    print(report)
    assert_equal(report.runtime_id, "komira/native")
    assert_equal(report.count("FAIL"), 0, "cases failed on the native C library")
    assert_equal(report.count("SKIP"), 0, "cases skipped on the native C library")
    assert_equal(report.count("PASS"), CASE_COUNT + 1, "every case and the capabilities check pass")
    print("test_conform_native_c: ok")
