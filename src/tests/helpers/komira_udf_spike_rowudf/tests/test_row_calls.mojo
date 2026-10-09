# The row runtime python_row.so (komira-test/python-row) through the C ABI
# only (komira_udf_spike_abi's harness), with the read sets the producer
# determined (read_sets.tsv, the read_sets oracle).
#
# What it proves, and the defect each part catches:
#   - describe declares ROW only, one sub-interpreter per context, no global
#     lock, thread-affine;
#   - price_qty over its static read set {price, qty} (by attribute and by
#     subscript) computes price * qty from the two fields only, from a
#     sliced input too (a reader that ignores a child's offset);
#   - branchy (`row.b if row.a > 0 else row.c`) given the read set the local
#     run recorded ({a, b}: it never saw a <= 0), or the user's too-small
#     columns=["a", "b"], fails with ERR_FIELD_NOT_DECLARED at the first row
#     with a <= 0, the message naming the field, the read set and the fix-it
#     (a proxy that returns None, or any value, for an undeclared name); the
#     scan's read set {a, b, c} computes every row (a proxy that checks names
#     against something other than the read set);
#   - a function that catches the error, or reads through getattr with a
#     default, still fails the batch (a violation user code swallows), and
#     the next batch of the same instance, with no violation, is OK (a
#     violation that outlives its batch);
#   - a null field reads None and a None result is a null, also on a sliced
#     input (a reader that ignores the offset in the validity bitmap), and
#     at row 8 of nine with two nulls (a bitmap byte index off, a view of the
#     bitmap one byte short, a null count off);
#   - two fields at different Arrow offsets (3 and 0, then 0 and 5), with a
#     null in either, read each field at its own offset (a reader that
#     applies one child's offset, or validity, to every field);
#   - a result of the wrong type fails the batch with ERR_RETURN_TYPE at its
#     row, naming the value and the declared type; an int for a float64
#     result is stored as a float (a runtime that stores any value, or
#     refuses an int it can widen);
#   - a row kept past its batch raises RowExpired when read: from another
#     instance, and from a later batch of the same instance, by a field in
#     the read set and by one outside it (a row of batch 1 reading batch 2's
#     buffers at its old index: a wrong value with status OK, or a
#     violation charged to the wrong row);
#   - an argument struct with a child outside the read set is refused, and
#     its args still moved (a runtime that accepts columns it did not bind);
#   - validate refuses, by name, a shape other than ROW, PROPAGATE, an
#     unnamed or repeated field, a function not of one row, one with no or
#     the wrong return hint, and a missing function.
#
# Every single-point mutant of the runtime and the adapter was run against
# these tests and test_row_args (the PR's mutation scorecard). Mutants
# planted by hand, each red: komira_udf_rowrt.py's __getattr__ returning
# None for an undeclared name instead of raising (branchy with the recorded
# read set returned OK); the row's batch-number check dropped (the kept row
# of the same instance read batch 2's value); the per-batch reset of the
# recorded violation dropped (the batch after a caught violation failed);
# the validity bit read at the row instead of offset + row (the sliced
# nullable_half lost its null); row_call.c's field_columns handing child
# 0's offset to every field (price_qty at offsets 3 and 0 read padding).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import (
    CONTEXT_PER_THREAD,
    NULL_PROPAGATE,
    OK,
    SHAPE_ROW,
    SHAPE_SCALAR,
    status_name,
)
from komira_udf_spike_abi.runtime import CallOptions, CallResult, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, TYPE_FLOAT64, TYPE_INT64
from komira_udf_spike_python.calls import call_once
from komira_udf_spike_rowudf.read_sets import ReadSetRow, load_read_sets, read_set_of, row_spec

comptime LIB = "./python_row.so"


def floats(cols: List[List[Float64]], null_at: Int = -1, offset: Int = 0) -> Batch:
    """A batch of float64 columns; row `null_at` of the first is null; each
    exported at Arrow offset `offset`."""
    var b = Batch(len(cols[0]))
    for j in range(len(cols)):
        var c = Column(TYPE_FLOAT64)
        c.offset = offset
        for i in range(len(cols[j])):
            if j == 0 and i == null_at:
                c.append_null()
            else:
                c.append_float(cols[j][i])
        b.columns.append(c^)
    return b^


def floats_at(cols: List[List[Float64]], offsets: List[Int], nulls: List[Int]) -> Batch:
    """Float64 columns, column j exported at Arrow offset `offsets[j]` with
    row `nulls[j]` null (-1: none)."""
    var b = Batch(len(cols[0]))
    for j in range(len(cols)):
        var c = Column(TYPE_FLOAT64)
        c.offset = offsets[j]
        for i in range(len(cols[j])):
            if i == nulls[j]:
                c.append_null()
            else:
                c.append_float(cols[j][i])
        b.columns.append(c^)
    return b^


def ints(cols: List[List[Int64]]) -> Batch:
    var b = Batch(len(cols[0]))
    for j in range(len(cols)):
        var c = Column(TYPE_INT64)
        for i in range(len(cols[j])):
            c.append_int(cols[j][i])
        b.columns.append(c^)
    return b^


def assert_floats(r: CallResult, want: List[Float64], what: String) raises:
    assert_true(r.outcome.is_ok(), what + ": " + String(r.outcome))
    assert_equal(len(r.column), len(want), what)
    for i in range(len(want)):
        assert_true(r.column.valid[i], what + ": row " + String(i) + " is null")
        assert_equal(r.column.as_float(i), want[i], what + ": row " + String(i))


def assert_not_declared(r: CallResult, field: String, read_set: String, row: Int, what: String) raises:
    var o = r.outcome.copy()
    assert_equal(status_name(o.status), "ERR_FIELD_NOT_DECLARED", what + ": " + String(o))
    assert_equal(o.run_error(), "UDF_FIELD_NOT_DECLARED", what)
    assert_equal(o.row, Int64(row), what + ": " + String(o))
    assert_true("'" + field + "'" in o.message, what + ": message names the field: " + o.message)
    assert_true(read_set in o.message, what + ": message names the read set: " + o.message)
    assert_true("columns=[...]" in o.message, what + ": message has the fix-it: " + o.message)
    assert_equal(o.group, Int64(-1), what + ": " + String(o))


def refused(mut rt: UdfRuntime, spec: UdfSpec, status: String, words: String, what: String) raises:
    var o = rt.validate(spec)
    assert_equal(status_name(o.status), status, what + ": " + String(o))
    assert_true(words in o.message, what + ": '" + words + "' not in: " + o.message)
    assert_equal(o.row, Int64(-1), what + ": " + String(o))
    assert_equal(o.group, Int64(-1), what + ": " + String(o))


def test_describe(mut rt: UdfRuntime) raises:
    var c = rt.describe()
    assert_equal(c.runtime_id, "komira-test/python-row")
    assert_equal(c.shapes, SHAPE_ROW)
    assert_equal(c.threading, CONTEXT_PER_THREAD)
    assert_equal(c.global_lock, 0)
    assert_equal(c.thread_affine, 1)


def test_price_qty(mut rt: UdfRuntime, sets: List[ReadSetRow]) raises:
    var p = read_set_of(sets, "price_qty@4")
    assert_equal(p.source, "static")
    assert_equal(len(p.read_set), 2)
    assert_equal(p.read_set[0], "price")
    assert_equal(p.read_set[1], "qty")
    var price: List[Float64] = [1.5, 2.0, 3.0, 4.0]
    var qty: List[Float64] = [2.0, 3.0, 0.5, 10.0]
    var want: List[Float64] = [3.0, 6.0, 1.5, 40.0]
    var spec = row_spec(p.entry, p.read_set, TYPE_FLOAT64, TYPE_FLOAT64)
    assert_floats(call_once(rt, spec, floats([price.copy(), qty.copy()])), want, "price_qty")
    assert_floats(call_once(rt, spec, floats([price.copy(), qty.copy()], offset=3)), want, "price_qty sliced")
    var k = read_set_of(sets, "price_qty_keys")
    assert_equal(len(k.read_set), 2)
    spec = row_spec(k.entry, k.read_set, TYPE_FLOAT64, TYPE_FLOAT64)
    assert_floats(call_once(rt, spec, floats([price.copy(), qty.copy()])), want, "price_qty_keys")
    # By subscript, a name outside the read set fails the same way.
    spec = row_spec(k.entry, [String("price")], TYPE_FLOAT64, TYPE_FLOAT64)
    assert_not_declared(call_once(rt, spec, floats([price.copy()])), "qty", "['price']", 0, "price_qty_keys {price}")


def test_branchy(mut rt: UdfRuntime, sets: List[ReadSetRow]) raises:
    var b = read_set_of(sets, "branchy")
    assert_equal(b.source, "static")
    assert_equal(len(b.read_set), 3)
    assert_equal(len(b.recorded), 2)
    var a: List[Float64] = [1.0, 2.0, -1.0, 3.0, 0.0]
    var bb: List[Float64] = [10.0, 20.0, 30.0, 40.0, 50.0]
    var c: List[Float64] = [100.0, 200.0, 300.0, 400.0, 500.0]
    # The local run's recording, {a, b}: row 2 reads c.
    var spec = row_spec(b.entry, b.recorded, TYPE_FLOAT64, TYPE_FLOAT64)
    assert_not_declared(call_once(rt, spec, floats([a.copy(), bb.copy()])), "c", "['a', 'b']", 2, "branchy recorded")
    # The user's columns=["a", "b"]: the same.
    var d = read_set_of(sets, "branchy_declared_ab")
    assert_equal(d.source, "columns")
    spec = row_spec(d.entry, d.read_set, TYPE_FLOAT64, TYPE_FLOAT64)
    assert_not_declared(call_once(rt, spec, floats([a.copy(), bb.copy()])), "c", "['a', 'b']", 2, "branchy declared")
    # The scan's read set covers both branches.
    spec = row_spec(b.entry, b.read_set, TYPE_FLOAT64, TYPE_FLOAT64)
    var want: List[Float64] = [10.0, 20.0, 300.0, 40.0, 500.0]
    assert_floats(call_once(rt, spec, floats([a.copy(), bb.copy(), c.copy()])), want, "branchy static")


def test_caught(mut rt: UdfRuntime) raises:
    var flag: List[Int64] = [1, 1, 1, 0, 1]
    var a: List[Int64] = [10, 20, 30, 40, 50]
    var fa: List[String] = ["flag", "a"]
    for name in ["pick_caught", "pick_getattr_default"]:
        var spec = row_spec("udf_rows:" + name, fa, TYPE_INT64, TYPE_INT64)
        assert_not_declared(call_once(rt, spec, ints([flag.copy(), a.copy()])), "b", "['flag', 'a']", 3, name)


def test_nulls(mut rt: UdfRuntime) raises:
    var spec = row_spec("udf_rows:nullable_half", [String("x")], TYPE_FLOAT64, TYPE_FLOAT64)
    var x: List[Float64] = [4.0, 0.0, 9.0]
    var r = call_once(rt, spec, floats([x^], null_at=1))
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_true(r.column.valid[0] and not r.column.valid[1] and r.column.valid[2], String(r.column))
    assert_equal(r.column.as_float(0), 2.0)
    assert_equal(r.column.as_float(2), 4.5)
    var xs: List[Float64] = [4.0, 0.0, 9.0]
    var s = call_once(rt, spec, floats([xs^], null_at=1, offset=3))
    assert_true(s.outcome.is_ok(), "sliced: " + String(s.outcome))
    assert_true(s.column.valid[0] and not s.column.valid[1] and s.column.valid[2], "sliced: " + String(s.column))
    assert_equal(s.column.as_float(0), 2.0, "sliced")
    assert_equal(s.column.as_float(2), 4.5, "sliced")


def test_offsets(mut rt: UdfRuntime) raises:
    """Each field read at its own child's offset, values and validity."""
    var pq: List[String] = ["price", "qty"]
    var spec = row_spec("udf_rows:price_qty", pq, TYPE_FLOAT64, TYPE_FLOAT64)
    var price: List[Float64] = [1.5, 2.0, 3.0, 4.0]
    var qty: List[Float64] = [2.0, 3.0, 0.5, 10.0]
    var want: List[Float64] = [3.0, 6.0, 1.5, 40.0]
    var none: List[Int] = [-1, -1]
    var offsets: List[List[Int]] = [[3, 0], [0, 5]]
    for k in range(len(offsets)):
        var at = String(offsets[k][0]) + "/" + String(offsets[k][1])
        var b = floats_at([price.copy(), qty.copy()], offsets[k].copy(), none.copy())
        assert_floats(call_once(rt, spec, b), want, "price_qty at " + at)
    var xy: List[String] = ["x", "y"]
    spec = row_spec("udf_rows:x_plus_y", xy, TYPE_FLOAT64, TYPE_FLOAT64)
    var x: List[Float64] = [1.0, 2.0, 3.0]
    var y: List[Float64] = [10.0, 20.0, 30.0]
    var cases: List[List[Int]] = [[0, 5, -1, 1], [3, 0, 2, -1]]
    for k in range(len(cases)):
        ref c = cases[k]
        var r = call_once(rt, spec, floats_at([x.copy(), y.copy()], [c[0], c[1]], [c[2], c[3]]))
        var what = "x_plus_y at " + String(c[0]) + "/" + String(c[1]) + ": " + String(r.column)
        assert_true(r.outcome.is_ok(), what + " " + String(r.outcome))
        var null_row = c[2] if c[2] >= 0 else c[3]
        for i in range(3):
            if i == null_row:
                assert_true(not r.column.valid[i], what)
            else:
                assert_true(r.column.valid[i], what)
                assert_equal(r.column.as_float(i), x[i] + y[i], what)


def test_return_types(mut rt: UdfRuntime) raises:
    var p: List[String] = ["price"]
    var v: List[Float64] = [3.75, 8.0]
    var spec = row_spec("udf_rows:as_text", p, TYPE_FLOAT64, TYPE_FLOAT64)
    var r = call_once(rt, spec, floats([v.copy()]))
    assert_equal(status_name(r.outcome.status), "ERR_RETURN_TYPE", String(r.outcome))
    assert_equal(r.outcome.row, Int64(0), String(r.outcome))
    assert_true("row 0: str 'not a number' is not float64" in r.outcome.message, r.outcome.message)
    spec = row_spec("udf_rows:whole", p, TYPE_FLOAT64, TYPE_FLOAT64)
    var want: List[Float64] = [3.0, 8.0]
    assert_floats(call_once(rt, spec, floats([v.copy()])), want, "an int for a float64 result")
    var a: List[String] = ["a"]
    var n: List[Int64] = [4, 6]
    spec = row_spec("udf_rows:halved", a, TYPE_INT64, TYPE_INT64)
    r = call_once(rt, spec, ints([n.copy()]))
    assert_equal(status_name(r.outcome.status), "ERR_RETURN_TYPE", String(r.outcome))
    assert_true("row 0: float 2.0 is not int64" in r.outcome.message, r.outcome.message)


def test_nulls_wide(mut rt: UdfRuntime) raises:
    """Nine rows with nulls at rows 1 and 8: the second validity byte, in
    and out, at offsets 0 and 5."""
    var spec = row_spec("udf_rows:nullable_half", [String("x")], TYPE_FLOAT64, TYPE_FLOAT64)
    for off in [0, 5]:
        var b = Batch(9)
        var c = Column(TYPE_FLOAT64)
        c.offset = off
        for i in range(9):
            if i == 1 or i == 8:
                c.append_null()
            else:
                c.append_float(Float64(2 * i))
        b.columns.append(c^)
        var r = call_once(rt, spec, b)
        var what = "nine rows at offset " + String(off) + ": " + String(r.column)
        assert_true(r.outcome.is_ok(), what + " " + String(r.outcome))
        assert_equal(r.column.null_count(), 2, what)
        for i in range(9):
            if i == 1 or i == 8:
                assert_true(not r.column.valid[i], what)
            else:
                assert_true(r.column.valid[i], what)
                assert_equal(r.column.as_float(i), Float64(i), what)


def two_batches(mut rt: UdfRuntime, spec: UdfSpec, first: Batch, second: Batch, what: String) raises -> CallResult:
    """Calls one instance of `spec` twice, in one context; asserts the first
    call is OK and returns the second's result."""
    var u = rt.load(spec)
    assert_true(u.outcome.is_ok(), what + ": " + String(u.outcome))
    var ctx = rt.open_context(0)
    assert_true(ctx.outcome.is_ok(), what + ": " + String(ctx.outcome))
    var inst = rt.open_instance(ctx.handle, u.handle)
    assert_true(inst.outcome.is_ok(), what + ": " + String(inst.outcome))
    var r1 = rt.call_batch(inst.handle, spec, first, CallOptions.plain())
    assert_true(r1.outcome.is_ok(), what + ", batch 1: " + String(r1.outcome))
    var r2 = rt.call_batch(inst.handle, spec, second, CallOptions.plain())
    rt.close_instance(inst.handle)
    rt.close_context(ctx.handle)
    rt.unload(u.handle)
    return r2^


def test_caught_then_clean(mut rt: UdfRuntime) raises:
    """A caught violation fails its batch only: the same instance's next
    batch, which reads only declared fields, is OK."""
    var fa: List[String] = ["flag", "a"]
    var spec = row_spec("udf_rows:pick_caught", fa, TYPE_INT64, TYPE_INT64)
    var u = rt.load(spec)
    var ctx = rt.open_context(0)
    var inst = rt.open_instance(ctx.handle, u.handle)
    assert_true(inst.outcome.is_ok(), String(inst.outcome))
    var f1: List[Int64] = [1, 0]
    var a1: List[Int64] = [10, 20]
    var f2: List[Int64] = [1, 1]
    var a2: List[Int64] = [30, 40]
    var bad = rt.call_batch(inst.handle, spec, ints([f1^, a1^]), CallOptions.plain())
    assert_not_declared(bad, "b", "['flag', 'a']", 1, "pick_caught batch 1")
    var good = rt.call_batch(inst.handle, spec, ints([f2^, a2^]), CallOptions.plain())
    assert_true(good.outcome.is_ok(), "pick_caught batch 2: " + String(good.outcome))
    assert_equal(good.column.bits[0], 30)
    assert_equal(good.column.bits[1], 40)
    rt.close_instance(inst.handle)
    rt.close_context(ctx.handle)
    rt.unload(u.handle)


def test_kept_row_same_instance(mut rt: UdfRuntime) raises:
    """A row of batch 1 read in batch 2 of the same instance, whose columns
    then hold batch 2's buffers, raises RowExpired: by a declared field (not
    batch 2's value at its index), and by an undeclared one (not a violation
    charged to batch 2's row)."""
    var p: List[String] = ["price"]
    var b1: List[Float64] = [7.0]
    var b2: List[Float64] = [9.0, 11.0]
    for name in ["keeps_then_reads", "keeps_then_misreads"]:
        var spec = row_spec("udf_rows:" + name, p, TYPE_FLOAT64, TYPE_FLOAT64)
        var r = two_batches(rt, spec, floats([b1.copy()]), floats([b2.copy()]), name)
        assert_equal(status_name(r.outcome.status), "ERR_RAISED", name + ": " + String(r.outcome))
        assert_true("RowExpired" in r.outcome.message, name + ": " + r.outcome.message)
        assert_equal(r.outcome.row, Int64(0), name + ": " + String(r.outcome))


def test_kept_row(mut rt: UdfRuntime) raises:
    """keeps_row keeps a row of batch 1; read_kept, another instance in the
    same context (the module's KEPT list is per interpreter), reads it in
    its own batch: another instance's row is never live."""
    var pq: List[String] = ["price"]
    var keep = row_spec("udf_rows:keeps_row", pq, TYPE_FLOAT64, TYPE_FLOAT64)
    var read = row_spec("udf_rows:read_kept", pq, TYPE_FLOAT64, TYPE_FLOAT64)
    var uk = rt.load(keep)
    var ur = rt.load(read)
    assert_true(uk.outcome.is_ok() and ur.outcome.is_ok(), String(uk.outcome) + String(ur.outcome))
    var ctx = rt.open_context(0)
    assert_true(ctx.outcome.is_ok(), String(ctx.outcome))
    var ik = rt.open_instance(ctx.handle, uk.handle)
    var ir = rt.open_instance(ctx.handle, ur.handle)
    assert_true(ik.outcome.is_ok() and ir.outcome.is_ok(), String(ik.outcome) + String(ir.outcome))
    var v: List[Float64] = [7.0]
    var r1 = rt.call_batch(ik.handle, keep, floats([v.copy()]), CallOptions.plain())
    assert_floats(r1, v, "keeps_row")
    var r2 = rt.call_batch(ir.handle, read, floats([v.copy()]), CallOptions.plain())
    assert_equal(status_name(r2.outcome.status), "ERR_RAISED", String(r2.outcome))
    assert_true("RowExpired" in r2.outcome.message, r2.outcome.message)
    rt.close_instance(ik.handle)
    rt.close_instance(ir.handle)
    rt.close_context(ctx.handle)
    rt.unload(uk.handle)
    rt.unload(ur.handle)


def test_extra_column(mut rt: UdfRuntime) raises:
    var pq: List[String] = ["price", "qty"]
    var spec = row_spec("udf_rows:price_qty", pq, TYPE_FLOAT64, TYPE_FLOAT64)
    var x: List[Float64] = [1.0, 2.0]
    var r = call_once(rt, spec, floats([x.copy(), x.copy(), x.copy()]))
    assert_equal(status_name(r.outcome.status), "ERR_INTERNAL", String(r.outcome))
    assert_true("3 children; the read set has 2" in r.outcome.message, r.outcome.message)
    assert_equal(r.outcome.fault, "", "the refused call still moved its args")


def test_validate(mut rt: UdfRuntime) raises:
    var pq: List[String] = ["price", "qty"]
    var ok = row_spec("udf_rows:price_qty", pq, TYPE_FLOAT64, TYPE_FLOAT64)
    assert_equal(rt.validate(ok).status, OK, String(rt.validate(ok)))
    var s = ok.copy()
    s.shape = SHAPE_SCALAR
    refused(rt, s, "ERR_UNSUPPORTED", "ROW UDFs only", "a SCALAR spec")
    s = ok.copy()
    s.null_mode = NULL_PROPAGATE
    refused(rt, s, "ERR_UNSUPPORTED", "MANUAL", "PROPAGATE")
    s = ok.copy()
    s.arg_names[1] = "price"
    refused(rt, s, "ERR_UNSUPPORTED", "names a field twice", "a repeated field")
    s = ok.copy()
    s.arg_names = List[String]()
    s.arg_names.append("price")
    s.arg_names.append("")
    refused(rt, s, "ERR_UNSUPPORTED", "no name", "an unnamed field")
    refused(rt, row_spec("udf_rows:two_rows", pq, TYPE_FLOAT64, TYPE_FLOAT64), "ERR_UNSUPPORTED", "one positional", "two_rows")
    refused(rt, row_spec("udf_rows:no_hint", pq, TYPE_FLOAT64, TYPE_FLOAT64), "ERR_UNSUPPORTED", "no return type hint", "no_hint")
    refused(rt, row_spec("udf_rows:price_qty", pq, TYPE_FLOAT64, TYPE_INT64), "ERR_UNSUPPORTED", "hinted float64, declared int64", "result type")
    refused(rt, row_spec("udf_rows:absent", pq, TYPE_FLOAT64, TYPE_FLOAT64), "ERR_DESCRIPTOR", "no top-level function absent", "absent")


def main() raises:
    var sets = load_read_sets()
    var rt = UdfRuntime.open(LIB)
    test_describe(rt)
    test_validate(rt)
    test_price_qty(rt, sets)
    test_branchy(rt, sets)
    test_caught(rt)
    test_nulls(rt)
    test_offsets(rt)
    test_nulls_wide(rt)
    test_return_types(rt)
    test_caught_then_clean(rt)
    test_kept_row(rt)
    test_kept_row_same_instance(rt)
    test_extra_column(rt)
    var l = rt.ledger()
    assert_equal(l.released, l.exported, "every exported argument array released")
    rt.shutdown()
    print("test_row_calls: ok")
