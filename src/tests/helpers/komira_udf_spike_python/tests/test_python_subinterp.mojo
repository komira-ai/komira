# The Python runtime's own cases, on python_subinterp.so (one
# sub-interpreter with its own GIL per context), through the C ABI only.
#
# What it proves, and the defect each part catches:
#   - describe: komira-test/python, MANAGED, EMBEDDED, CONTEXT_PER_THREAD,
#     thread_affine, global_lock 0, SCALAR and MAP_BATCHES_COLUMN only (a
#     capability the host would bind wrongly);
#   - validate reads the function's type hints from its source without
#     running it, and refuses by name: no return hint, a hint contradicting
#     the declared type, a row function declared as a column one, a module
#     not on the path, an entry without `module:function`, code form VALUE
#     and a shape it does not declare (a validator that accepts what load
#     would fail on, mid-run);
#   - open_instance refuses a hint that does not resolve when the module is
#     imported (ERR_LOAD), after validate accepted its source;
#   - calls: a per-row function's values; a sliced argument (Arrow offset
#     13, not a multiple of 8) read from its offset, both without nulls (no
#     validity buffer: the single-argument fast path) and with a null (the
#     validity bitmap at the same offset) (a reader that starts at row 0
#     reads the exporter's padding); a raise on row 3 as ERR_RAISED
#     with the row and a user_trace naming the user's file; a float returned
#     for an int64 result refused as ERR_RETURN_TYPE (an unsafe cast); and
#   - the numpy batch function cannot load here: numpy does not import in a
#     sub-interpreter, so this mode reports it FAIL with numpy's error.
#
# Mutants planted: komira_udf_pyrt.py's _rows writing a float into an int64
# column through int() instead of refusing it: red (float_into_int); its
# fast path reading x0[i] instead of x0[off0 + i]: red (the sliced case
# without nulls); its general path reading row p = i instead of
# offs[j] + i: red (the sliced case with a null).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import same_column
from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Column, TYPE_FLOAT64, TYPE_INT64
from komira_udf_spike_python.calls import call_once, floats, ints, open_instance_outcome, spec1


def _refused(mut rt: UdfRuntime, spec: UdfSpec, want: Int32, text: String) raises:
    var o = rt.validate(spec)
    assert_equal(status_name(o.status), status_name(want), spec.entry + ": " + String(o))
    assert_true(text in o.message, spec.entry + ": expected '" + text + "' in '" + o.message + "'")


def _describe(mut rt: UdfRuntime) raises:
    var c = rt.describe()
    assert_equal(c.runtime_id, "komira-test/python")
    assert_equal(c.runtime_abi, "cp313")
    assert_equal(c.udf_class, CLASS_MANAGED)
    assert_equal(c.hosting, HOSTING_EMBEDDED)
    assert_equal(c.threading, CONTEXT_PER_THREAD)
    assert_equal(c.thread_affine, 1)
    assert_equal(c.global_lock, 0)
    assert_equal(c.shapes, SHAPE_SCALAR | SHAPE_MAP_BATCHES_COLUMN)


def _validate(mut rt: UdfRuntime) raises:
    var ok = spec1(SHAPE_SCALAR, "udf_fixtures:fahrenheit_rows", TYPE_FLOAT64, TYPE_FLOAT64)
    assert_equal(rt.validate(ok).status, OK, "fahrenheit_rows validates")
    _refused(rt, spec1(SHAPE_SCALAR, "udf_fixtures:no_hints", TYPE_INT64, TYPE_INT64), ERR_UNSUPPORTED, "no return type hint")
    _refused(
        rt, spec1(SHAPE_SCALAR, "udf_fixtures:returns_float_hint", TYPE_INT64, TYPE_INT64), ERR_UNSUPPORTED,
        "the return type is hinted float64, declared int64",
    )
    _refused(
        rt, spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_fixtures:fahrenheit_rows", TYPE_FLOAT64, TYPE_FLOAT64),
        ERR_UNSUPPORTED, "is a row hint",
    )
    _refused(rt, spec1(SHAPE_SCALAR, "no_such_module:f", TYPE_INT64, TYPE_INT64), ERR_DESCRIPTOR, "not on the runtime's path")
    _refused(rt, spec1(SHAPE_SCALAR, "udf_fixtures.double", TYPE_INT64, TYPE_INT64), ERR_DESCRIPTOR, "<module>:<function>")
    var value = spec1(SHAPE_SCALAR, "udf_fixtures:double", TYPE_INT64, TYPE_INT64)
    value.form = FORM_VALUE
    _refused(rt, value, ERR_UNSUPPORTED, "VALUE")
    _refused(rt, spec1(SHAPE_ROW, "udf_fixtures:double", TYPE_INT64, TYPE_INT64), ERR_UNSUPPORTED, "shape")


def _calls(mut rt: UdfRuntime) raises:
    var unresolved = spec1(SHAPE_SCALAR, "udf_fixtures:unresolved_hint", TYPE_INT64, TYPE_FLOAT64)
    assert_equal(rt.validate(unresolved).status, OK, "its source reads as Optional[float]")
    var o = open_instance_outcome(rt, unresolved)
    assert_equal(status_name(o.status), "ERR_LOAD", String(o))
    assert_true("do not resolve" in o.message, String(o))

    var f = spec1(SHAPE_SCALAR, "udf_fixtures:fahrenheit_rows", TYPE_FLOAT64, TYPE_FLOAT64)
    var r = call_once(rt, f, floats([0.0, 100.0, -40.0, 37.0]))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    var want = Column(TYPE_FLOAT64)
    for v in [32.0, 212.0, -40.0, 98.6]:
        want.append_float(v)
    assert_equal(same_column(r.column, want), "")

    # Sliced at offset 13: rows 0..12 of the buffers are the exporter's
    # padding. Without nulls the column has no validity buffer.
    var dbl = spec1(SHAPE_SCALAR, "udf_fixtures:double", TYPE_INT64, TYPE_INT64)
    r = call_once(rt, dbl, ints([5, 6, 7, 8, 9], offset=13))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    var doubled = Column(TYPE_INT64)
    for v in [10, 12, 14, 16, 18]:
        doubled.append_int(Int64(v))
    assert_equal(same_column(r.column, doubled), "", "sliced, no nulls")
    r = call_once(rt, dbl, ints([5, 6, 7, 8, 9], null_at=3, offset=13))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    var doubled_null = Column(TYPE_INT64)
    for v in [10, 12, 14]:
        doubled_null.append_int(Int64(v))
    doubled_null.append_null()
    doubled_null.append_int(18)
    assert_equal(same_column(r.column, doubled_null), "", "sliced, row 3 null")

    # A null reaches the per-row function as None, and `None * 1.8` raises.
    r = call_once(rt, f, floats([0.0, 1.0, 2.0, 3.0, 4.0], null_at=3))
    assert_equal(status_name(r.outcome.status), "ERR_RAISED", String(r.outcome))
    assert_equal(r.outcome.row, 3)
    assert_true("TypeError" in r.outcome.message, String(r.outcome))
    assert_true("udf_fixtures.py" in r.outcome.trace, "the trace names the user's file: " + r.outcome.trace)

    var bad = spec1(SHAPE_SCALAR, "udf_fixtures:float_into_int", TYPE_INT64, TYPE_INT64)
    r = call_once(rt, bad, ints([1, 2]))
    assert_equal(status_name(r.outcome.status), "ERR_RETURN_TYPE", String(r.outcome))
    assert_equal(r.outcome.row, 0)
    assert_true("float 0.5 is not int64" in r.outcome.message, String(r.outcome))


def _numpy_fails_here(mut rt: UdfRuntime) raises:
    var np = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_np:fahrenheit_np", TYPE_FLOAT64, TYPE_FLOAT64)
    assert_equal(rt.validate(np).status, OK, "validate reads the source; numpy is never imported")
    var o = open_instance_outcome(rt, np)
    print("numpy batch function in a sub-interpreter: ", o)
    assert_equal(status_name(o.status), "ERR_LOAD", String(o))
    assert_true("import udf_np: ImportError" in o.message, String(o))


def main() raises:
    var rt = UdfRuntime.open("./python_subinterp.so")
    _describe(rt)
    _validate(rt)
    _calls(rt)
    _numpy_fails_here(rt)
    rt.shutdown()
    print("test_python_subinterp: ok")
