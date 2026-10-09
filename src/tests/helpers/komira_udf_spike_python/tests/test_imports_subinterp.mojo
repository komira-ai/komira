# Which of numpy, pandas, pyarrow, sklearn and cloudpickle import inside a
# sub-interpreter with its own GIL (python_subinterp.so: PyInterpreterConfig
# OWN_GIL, check_multi_interp_extensions 1), each in a first context and
# again in a second one. Each outcome is pinned: a library that starts (or
# stops) loading there turns this red, and the PR that changes the pin says
# why.
#
# Defect caught: a runtime that reports a library as usable per engine
# thread when it is not (or the reverse); a sub-interpreter created without
# the extension check, which would let a single-phase extension module load
# into a second interpreter.
#
# Mutants planted in python_runtime.c's sub-interpreter config:
#   - check_multi_interp_extensions 0 alone: red (CPython refuses the config,
#     "per-interpreter obmalloc does not support single-phase init extension
#     modules", so no context opens);
#   - the legacy kind (the shared GIL, the main obmalloc, no extension
#     check): red. numpy and pyarrow then load in the first sub-interpreter
#     and fail in the second ("cannot load module more than once per
#     process"; pyarrow: "Interpreter change detected - this module can only
#     be loaded into one interpreter per process"), and sklearn fails in both.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import status_name
from komira_udf_spike_abi.runtime import UdfRuntime
from komira_udf_spike_python.imports import import_outcomes


def _want() -> List[List[String]]:
    """library, context, status, a substring of the message."""
    return [
        ["numpy", "0", "ERR_LOAD", "module numpy._core._multiarray_umath does not support loading in subinterpreters"],
        ["numpy", "1", "ERR_LOAD", "module numpy._core._multiarray_umath does not support loading in subinterpreters"],
        ["pandas", "0", "ERR_LOAD", "Unable to import required dependency numpy"],
        ["pandas", "1", "ERR_LOAD", "Unable to import required dependency numpy"],
        ["pyarrow", "0", "ERR_LOAD", "module pyarrow.lib does not support loading in subinterpreters"],
        ["pyarrow", "1", "ERR_LOAD", "module pyarrow.lib does not support loading in subinterpreters"],
        ["sklearn", "0", "ERR_LOAD", "module sklearn.__check_build._check_build does not support loading in subinterpreters"],
        ["sklearn", "1", "ERR_LOAD", "module sklearn.__check_build._check_build does not support loading in subinterpreters"],
        ["cloudpickle", "0", "OK", ""],
        ["cloudpickle", "1", "OK", ""],
    ]


def main() raises:
    var rt = UdfRuntime.open("./python_subinterp.so")
    var got = import_outcomes(rt)
    rt.shutdown()
    for g in got:
        print(g)
    var want = _want()
    assert_equal(len(got), len(want), "outcomes")
    for i in range(len(want)):
        var w = want[i].copy()
        assert_equal(got[i].library, w[0])
        assert_equal(String(got[i].context), w[1])
        assert_equal(status_name(got[i].status), w[2], String(got[i]))
        assert_true(w[3] in got[i].message, String(got[i]) + ": expected '" + w[3] + "' in the message")
    print("test_imports_subinterp: ok")
