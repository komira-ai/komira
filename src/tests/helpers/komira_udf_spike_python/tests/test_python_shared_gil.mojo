# The Python runtime's shared-interpreter baseline, python_shared_gil.so
# (every context a thread state of the main interpreter), through the C ABI
# only: the mode where numpy loads, so the batch path is exercised here.
#
# What it proves, and the defect each part catches:
#   - describe reports global_lock 1 beside CONTEXT_PER_THREAD (a baseline
#     that hid its lock would pass the parallelism case it fails);
#   - the numpy batch function: numpy arrays over the Arrow buffers, nulls
#     as a masked array and back as nulls, a float64 result copied out once
#     (values wrong, or a null lost, in either direction);
#   - a sliced argument (Arrow offset 13) with a null: the numpy array and
#     its mask both start at the offset (values read from row 0 are the
#     exporter's padding; a mask read from bit 0 loses the null);
#   - an int64 numpy result for a declared float64 column is cast (a safe
#     cast), and a column of the right length comes back;
#   - an argument array user code still views after its call (a numpy
#     array over it, kept in a global) is not released then; it is released
#     as soon as user code drops the view (here inside the next call), and,
#     when the context closes with the view still held, when finalization
#     frees it at shutdown (a release while user code can still read the
#     engine's buffer; a leak).
#
# Mutants planted: komira_udf_pyrt.py's _numpy dropping the mask of a
# masked result (mask = None): red (row 1 comes back as a value).
# _numpy reading count=n values from 0 instead of [off:off + n]: red
# (sliced case: padding values); _numpy reading the mask bits [:n] instead
# of [off:off + n]: red (sliced case: row 1 not null).
# python_call.c releasing the argument array when the call returns, whatever
# views remain: red ("the kept argument array is still the runtime's").
#
# Each kind of numpy result (_numpy_results): a raise names no row; a list
# is converted; two dimensions are refused; int64 for a declared float64 is
# cast, float64 for a declared int64 refused; a reversed view is made
# contiguous; a plain result of a masked input has no null (the result's
# validity is not the input's). The round-2 sweep's survivors in _numpy
# (komira_udf_pyrt.py lines asarray, ndim, dtype, ascontiguousarray,
# `valid = None`) go red on these.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import same_column
from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Column, TYPE_FLOAT64, TYPE_INT64
from komira_udf_spike_python.calls import call_once, floats, ints, spec1


def main() raises:
    var rt = UdfRuntime.open("./python_shared_gil.so")
    var c = rt.describe()
    assert_equal(c.runtime_id, "komira-test/python-shared-gil")
    assert_equal(c.threading, CONTEXT_PER_THREAD)
    assert_equal(c.global_lock, 1)
    assert_equal(c.thread_affine, 1)

    var f = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_np:fahrenheit_np", TYPE_FLOAT64, TYPE_FLOAT64)
    var r = call_once(rt, f, floats([0.0, 1.0, 100.0, -40.0], null_at=1))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    var want = Column(TYPE_FLOAT64)
    want.append_float(32.0)
    want.append_null()
    want.append_float(212.0)
    want.append_float(-40.0)
    assert_equal(same_column(r.column, want), "")

    r = call_once(rt, f, floats([0.0, 1.0, 100.0, -40.0], null_at=1, offset=13))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(same_column(r.column, want), "", "sliced at offset 13")

    var cast = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_np:as_float", TYPE_INT64, TYPE_FLOAT64)
    r = call_once(rt, cast, ints([1, 2, 3]))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    var halves = Column(TYPE_FLOAT64)
    for v in [0.5, 1.0, 1.5]:
        halves.append_float(v)
    assert_equal(same_column(r.column, halves), "")
    _numpy_results(rt)
    _kept_views(rt)
    print("test_python_shared_gil: ok")


def _floats_want(values: List[Float64], null_at: Int = -1) -> Column:
    var c = Column(TYPE_FLOAT64)
    for i in range(len(values)):
        if i == null_at:
            c.append_null()
        else:
            c.append_float(values[i])
    return c^


def _np(entry: String, arg: Int, result: Int) -> UdfSpec:
    return spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_np:" + entry, arg, result)


def _numpy_results(mut rt: UdfRuntime) raises:
    """What the adapter does with each kind of numpy result."""
    var r = call_once(rt, _np("np_raise", TYPE_FLOAT64, TYPE_FLOAT64), floats([1.0, 2.0]))
    assert_equal(status_name(r.outcome.status), "ERR_RAISED", String(r.outcome))
    assert_equal(r.outcome.row, -1, "a batch function's raise names no row")
    # A list result is converted.
    r = call_once(rt, _np("np_list", TYPE_FLOAT64, TYPE_FLOAT64), floats([1.0, 2.5]))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(same_column(r.column, _floats_want([2.0, 5.0])), "", "a list result")
    # Two dimensions: refused for the batch.
    r = call_once(rt, _np("np_2d", TYPE_FLOAT64, TYPE_FLOAT64), floats([1.0, 2.0]))
    assert_equal(status_name(r.outcome.status), "ERR_RETURN_TYPE", String(r.outcome))
    assert_equal(r.outcome.row, -1, String(r.outcome))
    assert_true("2 dimensions" in r.outcome.message, String(r.outcome))
    # int64 for a declared float64: cast (safe), values kept.
    r = call_once(rt, _np("np_int_out", TYPE_INT64, TYPE_FLOAT64), ints([1, 2, 3]))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(same_column(r.column, _floats_want([2.0, 4.0, 6.0])), "", "int64 cast to float64")
    # float64 for a declared int64: refused (unsafe).
    r = call_once(rt, _np("np_float_out", TYPE_INT64, TYPE_INT64), ints([1, 2, 3]))
    assert_equal(status_name(r.outcome.status), "ERR_RETURN_TYPE", String(r.outcome))
    assert_equal(r.outcome.row, -1, String(r.outcome))
    assert_true("the result is float64, not int64" in r.outcome.message, String(r.outcome))
    # A view with a negative stride: made contiguous before the copy.
    r = call_once(rt, _np("np_reversed", TYPE_FLOAT64, TYPE_FLOAT64), floats([1.0, 2.0, 3.0]))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(same_column(r.column, _floats_want([3.0, 2.0, 1.0])), "", "a reversed view")
    # A masked input, a plain result: no null in the result, even though the
    # input's row 1 was null.
    r = call_once(rt, _np("np_filled", TYPE_FLOAT64, TYPE_FLOAT64), floats([1.0, 7.0, 3.0], null_at=1))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(same_column(r.column, _floats_want([2.0, 1.0, 4.0])), "", "a plain result of a masked input")


def _unreleased(rt: UdfRuntime) -> Int:
    var l = rt.ledger()
    return l.exported - l.released


def _kept_views(mut rt: UdfRuntime) raises:
    var keep = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_np:keep_view", TYPE_FLOAT64, TYPE_FLOAT64)
    var drop = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_np:drop_views", TYPE_FLOAT64, TYPE_FLOAT64)
    var uk = rt.load(keep)
    var ud = rt.load(drop)
    assert_true(uk.outcome.is_ok() and ud.outcome.is_ok(), "load")
    var c = rt.open_context(0)
    var ik = rt.open_instance(c.handle, uk.handle)
    var id = rt.open_instance(c.handle, ud.handle)
    assert_true(ik.outcome.is_ok() and id.outcome.is_ok(), "open_instance")
    assert_equal(_unreleased(rt), 0)
    var r = rt.call_batch(ik.handle, keep, floats([1.0, 2.0]), CallOptions.plain())
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(_unreleased(rt), 1, "the kept argument array is still the runtime's")
    r = rt.call_batch(id.handle, drop, floats([3.0]), CallOptions.plain())
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(_unreleased(rt), 0, "released once user code dropped its view")
    # Kept again, and the context closed with the view held.
    r = rt.call_batch(ik.handle, keep, floats([4.0]), CallOptions.plain())
    assert_true(r.outcome.is_ok(), String(r.outcome))
    rt.close_instance(ik.handle)
    rt.close_instance(id.handle)
    rt.close_context(c.handle)
    rt.unload(uk.handle)
    rt.unload(ud.handle)
    assert_equal(_unreleased(rt), 1, "held past close_context while the interpreter lives")
    rt.shutdown()
    assert_equal(_unreleased(rt), 0, "released after finalization")
