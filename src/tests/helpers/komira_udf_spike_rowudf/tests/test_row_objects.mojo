# What a row object does in python_row.so, what user errors look like, and
# how long an argument array lives, through the C ABI only
# (komira_udf_spike_abi's harness; fixtures in pyrt/udf_checks.py).
#
# What it proves, and the defect each part catches:
#   - a user exception is ERR_RAISED at its row with the message on one line
#     (runs of spaces, newlines, carriage returns and tabs each become one
#     space) and the user's traceback (a message that keeps a newline; a
#     trace dropped); an exception raised while converting the result is
#     the user's (ERR_RAISED); an int too large for int64, or for float64,
#     is ERR_RETURN_TYPE;
#   - a dunder the language probes for is not a field read, while `__x`
#     and `x__` are (a guard that takes either end alone); a field with no
#     attribute fast path (a name starting with "_", one that is not an
#     identifier) is still read by attribute, and one named like the row's
#     own slot (`_i`) by subscript; a row refuses assignment, iteration
#     (TypeError, not a field error) and has the runtime's repr;
#   - a row another instance kept, read by a field outside its read set,
#     raises RowExpired (not a field error charged to an idle instance);
#   - an argument array lives while Python holds a view of it: a RowExpired
#     user code keeps (its frames hold a column view) keeps the batch's
#     array until the exception is dropped, and that view is read-only (a
#     reference count that releases early, a writable view); a RowExpired
#     that escapes has its frames cleared, so the array is released when
#     the call returns; the views of the output and of the cancel flag that
#     those kept frames reach are released when the call returns (a view of
#     memory the host frees next), and the cancel flag's view is read-only
#     to user code walking up the stack.
#
# Every single-point mutant of the runtime and the adapter was run against
# the runtime tests (the PR's mutation scorecard). One that this file kills:
# row_call.c's owned_view without its reference on the owner (the kept
# view's array released at the end of batch 2): red.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import status_name
from komira_udf_spike_abi.runtime import CallOptions, CallResult, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, TYPE_FLOAT64, TYPE_INT64
from komira_udf_spike_python.calls import call_once
from komira_udf_spike_rowudf.read_sets import row_spec

comptime LIB = "./python_row.so"


def col(values: List[Float64]) -> Batch:
    var b = Batch(len(values))
    var c = Column(TYPE_FLOAT64)
    for i in range(len(values)):
        c.append_float(values[i])
    b.columns.append(c^)
    return b^


def spec_of(entry: String, read_set: List[String], result: Int = TYPE_FLOAT64) -> UdfSpec:
    return row_spec(entry, read_set, TYPE_FLOAT64, result)


def price() -> List[String]:
    return ["price"]


def expect(r: CallResult, status: String, message: String, row: Int64, what: String) raises:
    var w = what + ": " + String(r.outcome)
    assert_equal(status_name(r.outcome.status), status, w)
    assert_equal(r.outcome.message, message, w)
    assert_equal(r.outcome.row, row, w)
    assert_equal(r.outcome.group, Int64(-1), w)


def test_errors(mut rt: UdfRuntime) raises:
    var one: List[Float64] = [1.0]
    var r = call_once(rt, spec_of("udf_checks:raises_spaced", price()), col(one))
    expect(r, "ERR_RAISED", "ValueError: a b c", 0, "raises_spaced")
    assert_true("Traceback (most recent call last)" in r.outcome.trace, r.outcome.trace)
    assert_true("in raises_spaced" in r.outcome.trace, r.outcome.trace)
    r = call_once(rt, spec_of("udf_checks:bad_float", price()), col(one))
    expect(r, "ERR_RAISED", "RuntimeError: no float", 0, "bad_float")
    assert_true("in __float__" in r.outcome.trace, r.outcome.trace)
    r = call_once(rt, spec_of("udf_checks:huge_int", price(), TYPE_INT64), col(one))
    expect(r, "ERR_RETURN_TYPE", "row 0: int 1180591620717411303424 is not int64", 0, "huge_int")
    r = call_once(rt, spec_of("udf_checks:huge_float", price()), col(one))
    assert_equal(status_name(r.outcome.status), "ERR_RETURN_TYPE", String(r.outcome))
    assert_true(r.outcome.message.startswith("row 0: int 1000000000"), r.outcome.message)
    assert_true(r.outcome.message.endswith("0000 is not float64"), r.outcome.message)


def not_declared(r: CallResult, field: String, what: String) raises:
    var w = what + ": " + String(r.outcome)
    assert_equal(status_name(r.outcome.status), "ERR_FIELD_NOT_DECLARED", w)
    assert_true("read field '" + field + "'" in r.outcome.message, w)


def test_rows(mut rt: UdfRuntime) raises:
    var seven: List[Float64] = [7.0]
    var r = call_once(rt, spec_of("udf_checks:dunder_probe", price()), col(seven))
    assert_true(r.outcome.is_ok() and r.column.as_float(0) == 7.0, "dunder_probe: " + String(r.outcome))
    not_declared(call_once(rt, spec_of("udf_checks:under_x", price()), col(seven)), "__x", "under_x")
    not_declared(call_once(rt, spec_of("udf_checks:x_under", price()), col(seven)), "x__", "x_under")
    var odd: List[String] = ["_hidden", "with space"]
    var b = Batch(1)
    for v in [2.0, 3.5]:
        var c = Column(TYPE_FLOAT64)
        c.append_float(v)
        b.columns.append(c^)
    r = call_once(rt, spec_of("udf_checks:odd_names", odd), b)
    assert_true(r.outcome.is_ok() and r.column.as_float(0) == 5.5, "odd_names: " + String(r.outcome))
    var res: List[String] = ["_i"]
    r = call_once(rt, spec_of("udf_checks:reserved", res), col(seven))
    assert_true(r.outcome.is_ok() and r.column.as_float(0) == 7.0, "reserved: " + String(r.outcome))
    r = call_once(rt, spec_of("udf_checks:assigns", price()), col(seven))
    assert_true(r.outcome.is_ok() and r.column.as_float(0) == 2.0, "assigns: " + String(r.outcome))
    r = call_once(rt, spec_of("udf_checks:iterates", price()), col(seven))
    assert_equal(status_name(r.outcome.status), "ERR_RAISED", String(r.outcome))
    assert_equal(r.outcome.message, "TypeError: a ROW row is not iterable: it holds only its read set ['price']")
    r = call_once(rt, spec_of("udf_checks:reprs", price()), col(seven))
    assert_true(r.outcome.is_ok() and r.column.as_float(0) == 1.0, "reprs: " + String(r.outcome))
    r = call_once(rt, spec_of("udf_checks:writes_cancel", price(), TYPE_INT64), col(seven))
    assert_true(r.outcome.is_ok(), "writes_cancel: " + String(r.outcome))
    assert_equal(r.column.bits[0], 0, "the cancel flag's view is read-only")


def test_kept_misread(mut rt: UdfRuntime) raises:
    """keeps_row keeps a row; read_kept_misread, another instance, reads a
    field outside keeps_row's read set through it: RowExpired."""
    var keep = spec_of("udf_rows:keeps_row", price())
    var read = spec_of("udf_rows:read_kept_misread", price())
    var uk = rt.load(keep)
    var ur = rt.load(read)
    var ctx = rt.open_context(0)
    var ik = rt.open_instance(ctx.handle, uk.handle)
    var ir = rt.open_instance(ctx.handle, ur.handle)
    assert_true(ik.outcome.is_ok() and ir.outcome.is_ok(), String(ik.outcome) + String(ir.outcome))
    var v: List[Float64] = [7.0]
    var r1 = rt.call_batch(ik.handle, keep, col(v), CallOptions.plain())
    assert_true(r1.outcome.is_ok(), String(r1.outcome))
    var r2 = rt.call_batch(ir.handle, read, col(v), CallOptions.plain())
    assert_equal(status_name(r2.outcome.status), "ERR_RAISED", String(r2.outcome))
    assert_true(r2.outcome.message.startswith("RowExpired: "), r2.outcome.message)
    rt.close_instance(ik.handle)
    rt.close_instance(ir.handle)
    rt.close_context(ctx.handle)
    rt.unload(uk.handle)
    rt.unload(ur.handle)


def live(rt: UdfRuntime) -> Int:
    """Argument arrays exported and not yet released."""
    var l = rt.ledger()
    return l.exported - l.released


def test_kept_view(mut rt: UdfRuntime) raises:
    var spec = spec_of("udf_checks:keeps_view", price())
    var u = rt.load(spec)
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, u.handle)
    assert_true(inst.outcome.is_ok(), String(inst.outcome))
    var v: List[Float64] = [7.0]
    var base = live(rt)
    var r = rt.call_batch(inst.handle, spec, col(v), CallOptions.plain())
    assert_true(r.outcome.is_ok() and r.column.as_float(0) == 1.0, "batch 1: " + String(r.outcome))
    assert_equal(live(rt), base, "batch 1's array released when it returned")
    r = rt.call_batch(inst.handle, spec, col(v), CallOptions.plain())
    assert_true(r.outcome.is_ok(), "batch 2: " + String(r.outcome))
    assert_equal(r.column.as_float(0), 2.0, "batch 2: the kept view refused the write")
    assert_equal(live(rt), base + 1, "batch 2's array lives while user code keeps a view of it")
    r = rt.call_batch(inst.handle, spec, col(v), CallOptions.plain())
    assert_true(r.outcome.is_ok(), "batch 3: " + String(r.outcome))
    assert_equal(r.column.as_float(0), 4.0, "batch 3: every view batch 2's call made or was given is released")
    assert_equal(live(rt), base, "batch 2's array released once the view was dropped")
    rt.close_instance(inst.handle)
    rt.close_context(ctx.handle)
    rt.unload(u.handle)


def test_escaped_expired(mut rt: UdfRuntime) raises:
    var spec = spec_of("udf_checks:keeps_raised", price())
    var u = rt.load(spec)
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, u.handle)
    var v: List[Float64] = [7.0]
    var base = live(rt)
    var r = rt.call_batch(inst.handle, spec, col(v), CallOptions.plain())
    assert_true(r.outcome.is_ok(), "batch 1: " + String(r.outcome))
    r = rt.call_batch(inst.handle, spec, col(v), CallOptions.plain())
    assert_equal(status_name(r.outcome.status), "ERR_RAISED", "batch 2: " + String(r.outcome))
    assert_true(r.outcome.message.startswith("RowExpired: "), r.outcome.message)
    assert_equal(live(rt), base, "the escaped exception's frames were cleared: batch 2's array released")
    rt.close_instance(inst.handle)
    rt.close_context(ctx.handle)
    rt.unload(u.handle)


def main() raises:
    var rt = UdfRuntime.open(LIB)
    test_errors(rt)
    test_rows(rt)
    test_kept_misread(rt)
    test_kept_view(rt)
    test_escaped_expired(rt)
    var l = rt.ledger()
    assert_equal(l.released, l.exported, "every exported argument array released")
    assert_equal(l.double_released, 0)
    rt.shutdown()
    print("test_row_objects: ok")
