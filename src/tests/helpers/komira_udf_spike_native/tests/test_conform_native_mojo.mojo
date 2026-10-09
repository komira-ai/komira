# The conformance suite against the native runtime (:native) loading the
# Mojo native UDF library
# (//src/tests/helpers/komira_udf_spike_native_mojo:native_mojo), through the
# C ABI only.
#
# What it proves: every case of the corpus passes on a native UDF library
# written in Mojo, behind the native runtime, none skipped: a Mojo package can
# export the table (design section 6.3), read the arrays the host moves in,
# return arrays the host releases, and keep a Mojo error from crossing the
# ABI (raise_on_row_3: the fixture raises a Mojo Error; the library returns
# ERR_RAISED with the row).
#
# Defects caught: a Mojo fixture or entry that breaks the contract: an input
# not moved or released twice, an output left set on failure, a ROW read
# outside the read set that user code catches and the library lets pass, a
# cancel flag not read.
#
# Mutant planted: _fixtures.mojo's RowView.get raising on an undeclared field
# without recording it: red on row_caught_violation ("status OK, expected
# ERR_FIELD_NOT_DECLARED") and row_undeclared_field (no row).

from std.os import getenv
from std.testing import assert_equal

from komira_udf_spike_abi.conform import load_cases, run_suite
from komira_udf_spike_native.code import code_set

comptime CASES = "src/tests/helpers/komira_udf_spike_abi/cases"
comptime CASE_COUNT = 38


def main() raises:
    var cases = load_cases(CASES)
    assert_equal(len(cases), CASE_COUNT, "cases loaded from " + CASES)
    var code = code_set("./native_mojo.so", getenv("TMPDIR") + "/code")
    var report = run_suite("./native.so", cases, code)
    print(report)
    assert_equal(report.runtime_id, "komira/native")
    assert_equal(report.count("FAIL"), 0, "cases failed on the native Mojo library")
    assert_equal(report.count("SKIP"), 0, "cases skipped on the native Mojo library")
    assert_equal(report.count("PASS"), CASE_COUNT + 1, "every case and the capabilities check pass")
    print("test_conform_native_mojo: ok")
