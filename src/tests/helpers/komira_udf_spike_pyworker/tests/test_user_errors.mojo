# User code's failures on pyworker_zygote.so, through the C ABI only: every
# exception user code causes, in the function or while the adapter
# converts what it returned, is the user's (ERR_RAISED at its row, or
# ERR_RETURN_TYPE for a plain wrong value), never ERR_INTERNAL (design
# section 4.5: a user exception is UDF_RAISED; ERR_INTERNAL is the
# runtime's own fault). And the error's message is made whatever the
# exception object does, and reaches the engine through the worker.
#
# What it proves, and the defect each case catches:
#   - a returned value whose __index__ (int64) or __float__ (float64) raises
#     RuntimeError: ERR_RAISED at its row, with a trace naming the user's
#     file (the conversion's exception escaping the adapter, which the
#     worker reports as its own fault, ERR_INTERNAL);
#   - a value whose __bool__ raises converts (the adapter never asks a
#     returned value's truth);
#   - a list result whose __len__ or __iter__ raises, or whose iterator
#     raises after its first value: ERR_RAISED naming no row, which the
#     host bisects (design 4.5) to row 0;
#   - a numpy batch result whose __array__ raises: ERR_RAISED (row 0 after
#     the host's bisection), the
#     trace naming the user's file;
#   - a wrong value whose repr raises: ERR_RETURN_TYPE at its row, the
#     message made without the repr;
#   - an exception whose str() raises, whose __str__ returns a non-str, one
#     derived from BaseException only, and one whose message is not valid
#     UTF-8 (a lone surrogate): ERR_RAISED at its row, with a message naming
#     the exception type, the surrogate escaped in the message and in the
#     trace (a message builder that raises, or a worker that replaces what
#     it cannot encode, losing the user's text);
#   - a wrong value whose type's name, or whose repr, is not valid UTF-8,
#     and one whose type's __name__ raises: ERR_RETURN_TYPE at its row,
#     with the name and repr escaped, or "?" for the name;
#   - a list result that says it is one item shorter than it yields:
#     ERR_RETURN_TYPE at the row past its length; a list result whose
#     values' __index__ raises: ERR_RAISED at row 0; a result that is no
#     list: ERR_RETURN_TYPE, row -1.
#
# Mutants planted: the adapter as it was before (only TypeError, ValueError
# and OverflowError caught around a conversion; the exception's text taken
# with str() unguarded; the message not made encodable; a numpy result
# converted outside the guard): red on every case of the first version of
# this file but bad_bool and raise_base, which pin behaviour that held
# already. The cases after raise_surrogate were added for the survivors of
# the pull request's sweep of the adapter's changed lines.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import same_column
from komira_udf_spike_abi.contract import SHAPE_MAP_BATCHES_COLUMN, SHAPE_SCALAR, status_name
from komira_udf_spike_abi.runtime import CallOptions, CallResult, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_FLOAT64, TYPE_INT64


def spec1(shape: UInt32, entry: String, type_id: Int) -> UdfSpec:
    """One nullable argument and a nullable result, both of `type_id`."""
    return UdfSpec(shape, entry, [ColumnType(type_id, True)], [ColumnType(type_id, True)])


def two_rows(type_id: Int) -> Batch:
    """The values 1 and 2, as int64 or float64."""
    var c = Column(type_id)
    if type_id == TYPE_INT64:
        c.append_int(1)
        c.append_int(2)
    else:
        c.append_float(1.0)
        c.append_float(2.0)
    var b = Batch(2)
    b.columns.append(c^)
    return b^


def call_once(mut rt: UdfRuntime, spec: UdfSpec, args: Batch) raises -> CallResult:
    """load, open a context and an instance, one plain call_batch, close
    all. Raises if load, open_context or open_instance fails."""
    var u = rt.load(spec)
    if not u.outcome.is_ok():
        raise Error("load " + spec.entry + ": " + String(u.outcome))
    var c = rt.open_context(0)
    if not c.outcome.is_ok():
        raise Error("open_context: " + String(c.outcome))
    var i = rt.open_instance(c.handle, u.handle)
    if not i.outcome.is_ok():
        rt.close_context(c.handle)
        rt.unload(u.handle)
        raise Error("open_instance " + spec.entry + ": " + String(i.outcome))
    var r = rt.call_batch(i.handle, spec, args, CallOptions.plain())
    rt.close_instance(i.handle)
    rt.close_context(c.handle)
    rt.unload(u.handle)
    return r^


def user_error(
    mut rt: UdfRuntime, shape: UInt32, entry: String, type_id: Int, want_status: String, want_row: Int64,
    text: String, file: String = "udf_fixtures.py", trace_text: String = "",
) raises -> String:
    """"" when the call fails as expected, else why not. Every case runs, so
    a red build names each case that fails. `trace_text`: also in the
    trace."""
    var spec = spec1(shape, entry, type_id)
    var r = call_once(rt, spec, two_rows(type_id))
    var at = entry + ": " + String(r.outcome)
    if status_name(r.outcome.status) != want_status:
        return at + ": expected " + want_status
    if r.outcome.row != want_row:
        return at + ": expected row " + String(want_row)
    if text not in r.outcome.message:
        return at + ": expected '" + text + "' in the message"
    if r.outcome.fault != "":
        return at + ": a host fault"
    if want_status == "ERR_RAISED" and file not in r.outcome.trace:
        return at + ": the trace does not name the user's file: " + r.outcome.trace
    if trace_text not in r.outcome.trace:
        return at + ": expected '" + trace_text + "' in the trace: " + r.outcome.trace
    return ""


def main() raises:
    var rt = UdfRuntime.open("./pyworker_zygote.so")
    var row = SHAPE_SCALAR
    var col = SHAPE_MAP_BATCHES_COLUMN
    var i64 = TYPE_INT64
    var f64 = TYPE_FLOAT64
    var why = List[String]()
    why.append(user_error(rt, row, "udf_fixtures:bad_index", i64, "ERR_RAISED", 0, "RuntimeError: _BadInt: no int"))
    why.append(user_error(rt, row, "udf_fixtures:bad_float", f64, "ERR_RAISED", 0, "RuntimeError: _BadFloat: no float"))
    why.append(user_error(rt, col, "udf_fixtures:bad_len", i64, "ERR_RAISED", 0, "RuntimeError: _BadLen"))
    why.append(user_error(rt, col, "udf_fixtures:bad_iter", i64, "ERR_RAISED", 0, "RuntimeError: _BadIter"))
    why.append(user_error(rt, col, "udf_fixtures:bad_next", i64, "ERR_RAISED", 0, "RuntimeError: _BadNext"))
    why.append(user_error(
        rt, col, "udf_np:np_bad_array", f64, "ERR_RAISED", 0, "RuntimeError: _BadArray: no array", "udf_np.py"
    ))
    why.append(user_error(rt, row, "udf_fixtures:bad_repr_value", i64, "ERR_RETURN_TYPE", 0, "row 0: _BadRepr"))
    why.append(user_error(rt, row, "udf_fixtures:raise_unprintable", i64, "ERR_RAISED", 0, "_Unprintable"))
    why.append(user_error(rt, row, "udf_fixtures:raise_non_str", i64, "ERR_RAISED", 0, "_NonStrMessage"))
    why.append(user_error(
        rt, row, "udf_fixtures:raise_base", i64, "ERR_RAISED", 0, "_NotAnException: raise_base: a BaseException"
    ))
    why.append(user_error(
        rt, row, "udf_fixtures:raise_surrogate", i64, "ERR_RAISED", 0, "ValueError: raise_surrogate: \\udc80",
        trace_text="ValueError: raise_surrogate: \\udc80",
    ))
    why.append(user_error(rt, row, "udf_fixtures:bad_type_name", i64, "ERR_RETURN_TYPE", 0, "row 0: _Bad\\udc80Type <"))
    why.append(user_error(
        rt, row, "udf_fixtures:bad_repr_surrogate", i64, "ERR_RETURN_TYPE", 0,
        "row 0: _SurrogateRepr \\udc80 repr is not int64",
    ))
    why.append(user_error(
        rt, row, "udf_fixtures:bad_type_name_raises", i64, "ERR_RETURN_TYPE", 0, "row 0: ? <udf_fixtures._NoName object"
    ))
    why.append(user_error(rt, col, "udf_fixtures:len_short", i64, "ERR_RETURN_TYPE", 1, "row 1: int 2 is not int64"))
    why.append(user_error(rt, col, "udf_fixtures:bad_index_list", i64, "ERR_RAISED", 0, "RuntimeError: _BadInt: no int"))
    why.append(user_error(rt, col, "udf_fixtures:not_a_list", i64, "ERR_RETURN_TYPE", -1, "the result is a int, not a list"))

    var failed = String("")
    for w in why:
        if w != "":
            print("FAIL", w)
            failed += w + "; "
    assert_equal(failed, "", "user errors")

    var b = call_once(rt, spec1(row, "udf_fixtures:bad_bool", i64), two_rows(i64))
    assert_true(b.outcome.is_ok(), "bad_bool: " + String(b.outcome))
    var sevens = Column(TYPE_INT64)
    sevens.append_int(7)
    sevens.append_int(7)
    assert_equal(same_column(b.column, sevens), "", "bad_bool")
    rt.shutdown()
    print("test_user_errors: ok")
