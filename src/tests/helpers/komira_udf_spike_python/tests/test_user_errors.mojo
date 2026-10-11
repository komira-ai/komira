# User code's failures on python_subinterp.so, through the C ABI only: every
# exception user code causes, in the function or while the runtime converts
# what it returned, is the user's (ERR_RAISED at its row, or ERR_RETURN_TYPE
# for a plain wrong value), never ERR_INTERNAL (design section 4.5: a user
# exception is UDF_RAISED; ERR_INTERNAL is the runtime's own fault). And the
# error's message is made whatever the exception object does.
#
# What it proves, and the defect each case catches:
#   - a returned value whose __index__ (int64) or __float__ (float64) raises
#     RuntimeError: ERR_RAISED at its row, with a trace naming the user's
#     file (the conversion's exception escaping the adapter, reported by the
#     C side as ERR_INTERNAL);
#   - a value whose __bool__ raises converts (the adapter never asks a
#     returned value's truth);
#   - a list result whose __len__ or __iter__ raises: ERR_RAISED, row -1;
#   - a wrong value whose repr raises: ERR_RETURN_TYPE at its row, the
#     message made without the repr;
#   - an exception whose str() raises, whose __str__ returns a non-str, one
#     derived from BaseException only, and one whose message is not valid
#     UTF-8 (a lone surrogate): ERR_RAISED at its row, with a message naming
#     the exception type (a message builder that raises, or one the C side
#     cannot encode, losing the user's error).
#
# Mutants planted: the previous adapter (only TypeError, ValueError and
# OverflowError caught around a conversion; the exception's text taken with
# str() unguarded; the message not made encodable): red on every case but
# bad_bool and raise_base, which pin behaviour that held already.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import same_column
from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Column, TYPE_FLOAT64, TYPE_INT64
from komira_udf_spike_python.calls import call_once, floats, ints, spec1


def _user_error(mut rt: UdfRuntime, spec: UdfSpec, want_status: String, want_row: Int64, text: String) raises -> String:
    """"" when the call fails as expected, else why not. Every case runs,
    so a red build names each case that fails."""
    var r = call_once(rt, spec, ints([1, 2]) if spec.args[0].type_id == TYPE_INT64 else floats([1.0, 2.0]))
    var at = spec.entry + ": " + String(r.outcome)
    if status_name(r.outcome.status) != want_status:
        return at + ": expected " + want_status
    if r.outcome.row != want_row:
        return at + ": expected row " + String(want_row)
    if text not in r.outcome.message:
        return at + ": expected '" + text + "' in the message"
    if r.outcome.fault != "":
        return at + ": a host fault"
    if want_status == "ERR_RAISED" and "udf_fixtures.py" not in r.outcome.trace:
        return at + ": the trace does not name the user's file: " + r.outcome.trace
    return ""


def main() raises:
    var rt = UdfRuntime.open("./python_subinterp.so")
    var row = SHAPE_SCALAR
    var col = SHAPE_MAP_BATCHES_COLUMN
    var why = List[String]()
    why.append(_user_error(rt, spec1(row, "udf_fixtures:bad_index", TYPE_INT64, TYPE_INT64), "ERR_RAISED", 0, "RuntimeError: _BadInt: no int"))
    why.append(_user_error(
        rt, spec1(row, "udf_fixtures:bad_float", TYPE_FLOAT64, TYPE_FLOAT64), "ERR_RAISED", 0,
        "RuntimeError: _BadFloat: no float",
    ))
    why.append(_user_error(rt, spec1(col, "udf_fixtures:bad_len", TYPE_INT64, TYPE_INT64), "ERR_RAISED", -1, "RuntimeError: _BadLen"))
    why.append(_user_error(rt, spec1(col, "udf_fixtures:bad_iter", TYPE_INT64, TYPE_INT64), "ERR_RAISED", -1, "RuntimeError: _BadIter"))
    why.append(_user_error(
        rt, spec1(row, "udf_fixtures:bad_repr_value", TYPE_INT64, TYPE_INT64), "ERR_RETURN_TYPE", 0,
        "row 0: _BadRepr",
    ))
    why.append(_user_error(rt, spec1(row, "udf_fixtures:raise_unprintable", TYPE_INT64, TYPE_INT64), "ERR_RAISED", 0, "_Unprintable"))
    why.append(_user_error(rt, spec1(row, "udf_fixtures:raise_non_str", TYPE_INT64, TYPE_INT64), "ERR_RAISED", 0, "_NonStrMessage"))
    why.append(_user_error(
        rt, spec1(row, "udf_fixtures:raise_base", TYPE_INT64, TYPE_INT64), "ERR_RAISED", 0,
        "_NotAnException: raise_base: a BaseException",
    ))
    why.append(_user_error(
        rt, spec1(row, "udf_fixtures:raise_surrogate", TYPE_INT64, TYPE_INT64), "ERR_RAISED", 0,
        "ValueError: raise_surrogate: \\udc80",
    ))

    var failed = String("")
    for w in why:
        if w != "":
            print("FAIL", w)
            failed += w + "; "
    assert_equal(failed, "", "user errors")

    var b = call_once(rt, spec1(row, "udf_fixtures:bad_bool", TYPE_INT64, TYPE_INT64), ints([1, 2]))
    assert_true(b.outcome.is_ok(), "bad_bool: " + String(b.outcome))
    var sevens = Column(TYPE_INT64)
    sevens.append_int(7)
    sevens.append_int(7)
    assert_equal(same_column(b.column, sevens), "", "bad_bool")
    rt.shutdown()
    print("test_user_errors: ok")
