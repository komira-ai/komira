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
#   - two arguments at different offsets (3 and 13, both orders), each read
#     at its own; int32 arguments and results (4 bytes per value) in the
#     per-row path, and 2^31 refused as an int32 result;
#   - a cancel landing while a batch function runs is ERR_CANCELLED with
#     row -1 (a row at the batch's length is a host fault);
#   - validate refuses a list of lists, *args, **kwargs and keyword-only
#     arguments, names the shape a row or list hint does not fit, and reads
#     a subscripted numpy hint's dtype; open_instance refuses live hints that
#     differ from their source (a union, a set, a list of lists, a class
#     named ndarray that is not numpy's: udf_shadow.py);
#   - nulls past the first bitmap byte, per row (row 9 of 12) and in a
#     column result (row 8 of 9); a column function returning no list; an
#     int no float64 holds, refused as ERR_RETURN_TYPE at its row (it was
#     ERR_INTERNAL: the adapter's int-to-float retry raised OverflowError).
#
# Mutants planted: komira_udf_pyrt.py's _rows writing a float into an int64
# column through int() instead of refusing it: red (float_into_int); its
# fast path reading x0[i] instead of x0[off0 + i]: red (the sliced case
# without nulls); its general path reading row p = i instead of
# offs[j] + i: red (the sliced case with a null); and p = offs[0] + i:
# red (two arguments at offsets 3 and 13). The column cancel's row n (the
# code before this case): red (row 3, a host fault).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.conform import same_column
from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_FLOAT64, TYPE_INT32, TYPE_INT64
from komira_udf_spike_python.calls import (
    call_once,
    call_once_with,
    floats,
    int_column,
    ints,
    open_instance_outcome,
    spec1,
)


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
        ERR_UNSUPPORTED, "is a row hint; shape MAP_BATCHES_COLUMN takes list or numpy",
    )
    _refused(
        rt, spec1(SHAPE_SCALAR, "udf_fixtures:identity", TYPE_INT64, TYPE_INT64), ERR_UNSUPPORTED,
        "is a list hint; shape SCALAR takes row",
    )
    _refused(
        rt, spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_fixtures:nested_list", TYPE_INT64, TYPE_INT64), ERR_UNSUPPORTED,
        "argument 0 has no type hint this runtime maps",
    )
    for e in ["var_args", "var_kwargs", "keyword_only"]:
        _refused(rt, spec1(SHAPE_SCALAR, "udf_fixtures:" + e, TYPE_INT64, TYPE_INT64), ERR_UNSUPPORTED, "*args")
    # A subscripted numpy hint's dtype, from the source (numpy is never
    # imported by validate, so this runs in a sub-interpreter too).
    var typed = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_np:typed_np", TYPE_FLOAT64, TYPE_FLOAT64)
    assert_equal(rt.validate(typed).status, OK, "NDArray[np.float64] validates as float64")
    _refused(
        rt, spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_np:typed_np", TYPE_INT64, TYPE_INT64), ERR_UNSUPPORTED,
        "is hinted float64, declared int64",
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


def _ints_want(values: List[Int64]) -> Column:
    var c = Column(TYPE_INT64)
    for v in values:
        c.append_int(v)
    return c^


def _two_args_and_int32(mut rt: UdfRuntime) raises:
    # Two arguments at different Arrow offsets, 3 and 13, no nulls: the
    # per-row general path (more than one argument) reads each argument at
    # its own offset. Reading every argument at the first one's offset reads
    # b's padding (komira_udf_pyrt.py _rows, p = offs[j] + i).
    var two = UdfSpec(
        SHAPE_SCALAR, "udf_fixtures:add_mixed", [ColumnType(TYPE_INT64, True), ColumnType(TYPE_INT64, True)],
        [ColumnType(TYPE_INT64, True)],
    )
    var args = Batch(3)
    args.columns.append(int_column([1, 2, 3], offset=3))
    args.columns.append(int_column([10, 20, 30], offset=13))
    var r = call_once(rt, two, args)
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(same_column(r.column, _ints_want([11, 22, 33])), "", "two arguments at offsets 3 and 13")
    # And the reverse order of offsets: reading at the last one's offset
    # instead reads a's padding.
    var rev = Batch(3)
    rev.columns.append(int_column([1, 2, 3], offset=13))
    rev.columns.append(int_column([10, 20, 30], offset=3))
    r = call_once(rt, two, rev)
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(same_column(r.column, _ints_want([11, 22, 33])), "", "two arguments at offsets 13 and 3")

    # int32 in and out of a per-row function (`int` reads either width): the
    # values view is 4 bytes per row at the argument's offset (5, so not
    # 8-aligned in bytes), the result column 4 bytes per row. A width of 8
    # reads two values as one; a result value past int32 is refused.
    var d32 = spec1(SHAPE_SCALAR, "udf_fixtures:double", TYPE_INT32, TYPE_INT32)
    r = call_once(rt, d32, ints([-5, 6, 7, 1073741823], null_at=1, offset=5, type_id=TYPE_INT32))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    var want32 = Column(TYPE_INT32)
    want32.append_int(-10)
    want32.append_null()
    want32.append_int(14)
    want32.append_int(2147483646)
    assert_equal(same_column(r.column, want32), "", "int32 per row")
    r = call_once(rt, d32, ints([1073741824], type_id=TYPE_INT32))
    assert_equal(status_name(r.outcome.status), "ERR_RETURN_TYPE", "2^31 into int32: " + String(r.outcome))
    assert_equal(r.outcome.row, 0)

    # A cancel that lands while a MAP_BATCHES_COLUMN function runs (the
    # function reads the host clock, where this host sets the flag) is
    # ERR_CANCELLED for the whole batch: row -1, not a row past the batch
    # (which the host reports as a runtime fault).
    var clock = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_fixtures:reads_clock", TYPE_INT64, TYPE_INT64)
    r = call_once_with(rt, clock, ints([1, 2, 3]), CallOptions(False, True, False))
    assert_equal(status_name(r.outcome.status), "ERR_CANCELLED", String(r.outcome))
    assert_equal(r.outcome.row, -1, String(r.outcome))
    assert_equal(r.outcome.fault, "", String(r.outcome))


def _live_hint_refused(mut rt: UdfRuntime, spec: UdfSpec) raises:
    assert_equal(rt.validate(spec).status, OK, spec.entry + ": its source reads as a mapped hint")
    var o = open_instance_outcome(rt, spec)
    assert_equal(status_name(o.status), "ERR_LOAD", spec.entry + ": " + String(o))
    assert_true("type hint this runtime maps" in o.message, spec.entry + ": " + String(o))


def _values_and_refusals(mut rt: UdfRuntime) raises:
    # The live hints, checked again by open_instance: each function's
    # source reads as a mapped hint, and the name it uses was rebound before
    # its def (udf_shadow.py), so the live object is another type.
    _live_hint_refused(rt, spec1(SHAPE_SCALAR, "udf_shadow:union_hint", TYPE_INT64, TYPE_INT64))
    _live_hint_refused(rt, spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_shadow:set_hint", TYPE_INT64, TYPE_INT64))
    _live_hint_refused(rt, spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_shadow:nested_hint", TYPE_INT64, TYPE_INT64))
    _live_hint_refused(rt, spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_shadow:fake_ndarray", TYPE_INT64, TYPE_INT64))

    # A per-row null past the first byte of the validity bitmap: row 9 of 12.
    var nz = spec1(SHAPE_SCALAR, "udf_fixtures:null_on_zero", TYPE_INT64, TYPE_INT64)
    var r = call_once(rt, nz, ints([1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 11, 12]))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    var want = Column(TYPE_INT64)
    for v in [2, 4, 6, 8, 10, 12, 14, 16, 18]:
        want.append_int(Int64(v))
    want.append_null()
    want.append_int(22)
    want.append_int(24)
    assert_equal(same_column(r.column, want), "", "per row, row 9 null")

    # A column result with a null at row 8 of 9: its bitmap needs a second
    # byte, and the bit is row 8's.
    var nzl = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_fixtures:none_on_zero_list", TYPE_INT64, TYPE_INT64)
    r = call_once(rt, nzl, ints([1, 2, 3, 4, 5, 6, 7, 8, 0]))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    var wantl = Column(TYPE_INT64)
    for v in [1, 2, 3, 4, 5, 6, 7, 8]:
        wantl.append_int(Int64(v))
    wantl.append_null()
    assert_equal(same_column(r.column, wantl), "", "column, row 8 null")

    # A column function returning no list: ERR_RETURN_TYPE for the batch.
    var nal = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_fixtures:not_a_list", TYPE_INT64, TYPE_INT64)
    r = call_once(rt, nal, ints([1, 2]))
    assert_equal(status_name(r.outcome.status), "ERR_RETURN_TYPE", String(r.outcome))
    assert_equal(r.outcome.row, -1, String(r.outcome))
    assert_true("the result is a int, not a list" in r.outcome.message, String(r.outcome))

    # An int no float64 holds, returned per row: ERR_RETURN_TYPE at its row
    # (user code's value), not a runtime failure.
    var huge = spec1(SHAPE_SCALAR, "udf_fixtures:huge_float", TYPE_FLOAT64, TYPE_FLOAT64)
    r = call_once(rt, huge, floats([1.0]))
    assert_equal(status_name(r.outcome.status), "ERR_RETURN_TYPE", String(r.outcome))
    assert_equal(r.outcome.row, 0, String(r.outcome))


def _repeated(mut rt: UdfRuntime, spec: UdfSpec, args: Batch, calls: Int) raises -> List[Int64]:
    """`calls` calls on one context and instance; row 0 of each output."""
    var u = rt.load(spec)
    var c = rt.open_context(0)
    var i = rt.open_instance(c.handle, u.handle)
    assert_true(i.outcome.is_ok(), spec.entry + ": " + String(i.outcome))
    var out = List[Int64]()
    for _ in range(calls):
        var r = rt.call_batch(i.handle, spec, args, CallOptions.plain())
        assert_true(r.outcome.is_ok(), spec.entry + ": " + String(r.outcome))
        out.append(r.column.bits[0])
    rt.close_instance(i.handle)
    rt.close_context(c.handle)
    rt.unload(u.handle)
    return out^


def _steady(values: List[Int64], what: String) raises:
    # The first calls warm the interpreter's caches; from the fourth on,
    # every call must find the same number of allocated blocks.
    for k in range(4, len(values)):
        assert_equal(values[k], values[3], what + ": allocated blocks call by call " + String(values.copy()))


def _edges(mut rt: UdfRuntime) raises:
    # Cancelled or past the deadline before the call: the C side refuses the
    # whole batch, row -1, before any row runs.
    var dbl = spec1(SHAPE_SCALAR, "udf_fixtures:double", TYPE_INT64, TYPE_INT64)
    var r = call_once_with(rt, dbl, ints([1, 2, 3]), CallOptions(True, False, False))
    assert_equal(status_name(r.outcome.status), "ERR_CANCELLED", String(r.outcome))
    assert_equal(r.outcome.row, -1, String(r.outcome))
    assert_true("cancelled before the batch" in r.outcome.message, String(r.outcome))
    r = call_once_with(rt, dbl, ints([1, 2, 3]), CallOptions(False, False, True))
    assert_equal(status_name(r.outcome.status), "ERR_DEADLINE", String(r.outcome))
    assert_equal(r.outcome.row, -1, String(r.outcome))
    assert_true("the deadline passed before the batch" in r.outcome.message, String(r.outcome))

    # Column results of 0 and 1 rows.
    var ident = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_fixtures:identity", TYPE_INT64, TYPE_INT64)
    r = call_once(rt, ident, ints(List[Int64]()))
    assert_true(r.outcome.is_ok(), "0 rows: " + String(r.outcome))
    assert_equal(len(r.column), 0)
    r = call_once(rt, ident, ints([5]))
    assert_true(r.outcome.is_ok(), "1 row: " + String(r.outcome))
    assert_equal(same_column(r.column, _ints_want([5])), "", "a one-row column")

    # Column nulls at the bitmap's edges: 1 row, row 7 of 8, row 63 of 64
    # (the bitmap fills its 8 bytes; the values start right after them).
    var nzl = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_fixtures:none_on_zero_list", TYPE_INT64, TYPE_INT64)
    for n in [1, 8, 64]:
        var xs = List[Int64]()
        var want = Column(TYPE_INT64)
        for k in range(n - 1):
            xs.append(Int64(k + 1))
            want.append_int(Int64(k + 1))
        xs.append(0)
        want.append_null()
        r = call_once(rt, nzl, ints(xs))
        assert_true(r.outcome.is_ok(), String(n) + " rows: " + String(r.outcome))
        assert_equal(same_column(r.column, want), "", "column, last of " + String(n) + " rows null")
    # A per-row null at row 8 of 9: the bitmap's second byte.
    var nz = spec1(SHAPE_SCALAR, "udf_fixtures:null_on_zero", TYPE_INT64, TYPE_INT64)
    r = call_once(rt, nz, ints([1, 2, 3, 4, 5, 6, 7, 8, 0]))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    var want9 = _ints_want([2, 4, 6, 8, 10, 12, 14, 16])
    want9.append_null()
    assert_equal(same_column(r.column, want9), "", "per row, row 8 of 9 null")

    # A returned value whose conversion raises RuntimeError escapes the
    # adapter: the C side reports it as ERR_INTERNAL, row -1, naming the
    # exception, with no output (the runtime's failure path, not the user's).
    var bad = spec1(SHAPE_SCALAR, "udf_fixtures:bad_index", TYPE_INT64, TYPE_INT64)
    r = call_once(rt, bad, ints([1, 2]))
    assert_equal(status_name(r.outcome.status), "ERR_INTERNAL", String(r.outcome))
    assert_equal(r.outcome.row, -1, String(r.outcome))
    assert_true("RuntimeError: _BadInt: no int" in r.outcome.message, String(r.outcome))
    assert_equal(r.outcome.fault, "", String(r.outcome))

    # What a call leaves behind in the interpreter: 300 rows (so the row
    # count is not a cached small int), 8 calls on one instance; from the
    # fourth call on, the allocated blocks are the same (a view, a result
    # tuple, a result buffer or an int never let go).
    var rows = List[Int64]()
    for k in range(300):
        rows.append(Int64(k))
    var blocks = spec1(SHAPE_SCALAR, "udf_fixtures:allocated_blocks", TYPE_INT64, TYPE_INT64)
    _steady(_repeated(rt, blocks, ints(rows), 8), "per row")
    var blocks_list = spec1(SHAPE_MAP_BATCHES_COLUMN, "udf_fixtures:allocated_blocks_list", TYPE_INT64, TYPE_INT64)
    _steady(_repeated(rt, blocks_list, ints(rows), 8), "column")


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
    _two_args_and_int32(rt)
    _values_and_refusals(rt)
    _edges(rt)
    _numpy_fails_here(rt)
    rt.shutdown()
    print("test_python_subinterp: ok")
