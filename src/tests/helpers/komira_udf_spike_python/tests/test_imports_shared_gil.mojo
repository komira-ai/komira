# The same import probes (imports.mojo) in the shared-interpreter baseline
# (python_shared_gil.so: every context a thread state of the main
# interpreter), where each library imports once into the one interpreter and
# every context sees it. Pinned, as in test_imports_subinterp: together they
# show which libraries the per-thread mode loses.
#
# Defect caught: a closure of wheels that does not import at all (a missing
# dependency or native library), which would make the sub-interpreter
# results meaningless.
#
# Mutant planted: the test data without the numpy wheel: red (numpy,
# pandas and sklearn fail to import).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import status_name
from komira_udf_spike_abi.runtime import UdfRuntime
from komira_udf_spike_python.imports import import_outcomes, probe_libraries


def main() raises:
    var rt = UdfRuntime.open("./python_shared_gil.so")
    var got = import_outcomes(rt)
    rt.shutdown()
    for g in got:
        print(g)
    assert_equal(len(got), 2 * len(probe_libraries()), "outcomes")
    for g in got:
        assert_equal(status_name(g.status), "OK", String(g))
    print("test_imports_shared_gil: ok")
