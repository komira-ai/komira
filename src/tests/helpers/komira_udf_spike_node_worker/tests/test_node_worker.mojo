# The komira-test/node worker runtime's own cases, through the C ABI only
# (UdfRuntime), beyond the shared corpus.
#
# What it proves, and the defect each part catches:
#   - describe: a managed runtime, one context per engine thread, the
#     worker transport only, no global lock (capabilities copied wrongly
#     across the wire);
#   - validate refuses by name, from the descriptor and the bundle's text
#     alone: an entry without `#`, a bundle path that leaves the code
#     directory, a missing bundle, form VALUE, an unbuilt shape (a validator
#     that lets mid-run failures through);
#   - open_instance refuses an export that is not a function (ERR_LOAD);
#   - a float returned for int64, and an Int32Array returned for float64,
#     are ERR_RETURN_TYPE with the row (an unsafe cast accepted);
#   - state per context: a module-global counter counts 1, 2, 3 in one
#     context and starts at 1 in another (contexts sharing one process);
#   - a worker that exits mid-batch, and one killed by a signal, are
#     ERR_INSTANCE_LOST naming the exit status or signal; the lost context is
#     never called again, and a new context works (a crash mapped to a user
#     error, or a dead channel reused);
#   - a cancel the user's code never checks (a batch function that spins):
#     the proxy kills the worker after its grace period, ERR_INSTANCE_LOST;
#   - a frame that yields a non-table is ERR_RETURN_TYPE; a step generator's
#     three tables come back in order;
#   - outputs that break the IPC layout, sent by a worker in its
#     --corrupt-output mode (node_worker_corrupt.so), are refused by the
#     proxy's validation before any pointer is formed, each by its reason,
#     and the worker stays usable;
#   - every array and stream the host exported is released once.
#
# Mutants planted: channel.c mapping end of file on the channel to
# ERR_INTERNAL instead of ERR_INSTANCE_LOST: red ("exit mid-batch").
# ipc.c without the "a buffer lies outside the body" check: red (the
# corrupt worker's first output is accepted).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, Handle, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_FLOAT64, TYPE_INT64

comptime LIB = "./node_worker.so"
comptime CORRUPT_LIB = "./node_worker_corrupt.so"


@fieldwise_init
struct Bound(Copyable, Movable):
    var udf: Handle
    var ctx: Handle
    var inst: Handle


def _ints(vals: List[Int]) -> Batch:
    var b = Batch(len(vals))
    var c = Column(TYPE_INT64)
    for v in vals:
        c.append_int(Int64(v))
    b.columns.append(c^)
    return b^


def _floats(vals: List[Float64]) -> Batch:
    var b = Batch(len(vals))
    var c = Column(TYPE_FLOAT64)
    for v in vals:
        c.append_float(v)
    b.columns.append(c^)
    return b^


def _spec(shape: UInt32, entry: String, t: Int) -> UdfSpec:
    return UdfSpec(shape, entry, [ColumnType(t, True)], [ColumnType(t, True)])


def _bind(mut rt: UdfRuntime, spec: UdfSpec, slot: UInt32) raises -> Bound:
    var u = rt.load(spec)
    assert_true(u.outcome.is_ok(), "load " + spec.entry + ": " + String(u.outcome))
    var c = rt.open_context(slot)
    assert_true(c.outcome.is_ok(), "open_context: " + String(c.outcome))
    var i = rt.open_instance(c.handle, u.handle)
    assert_true(i.outcome.is_ok(), "open_instance " + spec.entry + ": " + String(i.outcome))
    return Bound(u.handle.copy(), c.handle.copy(), i.handle.copy())


def _unbind(mut rt: UdfRuntime, b: Bound) raises:
    rt.close_instance(b.inst)
    rt.close_context(b.ctx)
    rt.unload(b.udf)


def _expect(got: Outcome, status: Int32, text: String, what: String) raises:
    assert_equal(status_name(got.status), status_name(status), what + ": " + String(got))
    assert_true(text in got.message, what + ": message '" + got.message + "' lacks '" + text + "'")


def _describe(mut rt: UdfRuntime) raises:
    var caps = rt.describe()
    assert_equal(caps.runtime_id, "komira-test/node")
    assert_true(caps.runtime_abi.startswith("node"), caps.runtime_abi)
    assert_equal(caps.udf_class, CLASS_MANAGED)
    assert_equal(caps.hosting, HOSTING_EMBEDDED)
    assert_equal(caps.threading, CONTEXT_PER_THREAD)
    assert_equal(caps.transports, TRANSPORT_WORKER)
    assert_equal(caps.global_lock, 0)
    assert_equal(caps.thread_affine, 0)


def _validate(mut rt: UdfRuntime) raises:
    _expect(rt.validate(_spec(SHAPE_SCALAR, "fixtures.mjs#double", TYPE_INT64)), OK, "", "a good entry")
    _expect(rt.validate(_spec(SHAPE_SCALAR, "fixtures.mjs", TYPE_INT64)), ERR_DESCRIPTOR, "is not <bundle>.mjs#<export>", "no #")
    _expect(
        rt.validate(_spec(SHAPE_SCALAR, "../code/fixtures.mjs#double", TYPE_INT64)),
        ERR_DESCRIPTOR,
        "is not <bundle>.mjs#<export>",
        "a path out of the code directory",
    )
    _expect(rt.validate(_spec(SHAPE_SCALAR, "missing.mjs#double", TYPE_INT64)), ERR_DESCRIPTOR, "no bundle missing.mjs", "no bundle")
    var value = _spec(SHAPE_SCALAR, "fixtures.mjs#double", TYPE_INT64)
    value.form = FORM_VALUE
    _expect(rt.validate(value), ERR_UNSUPPORTED, "BUNDLE only", "form VALUE")
    _expect(
        rt.validate(_spec(SHAPE_MAP_BATCHES_FRAME_GROUPED, "fixtures.mjs#running_sum", TYPE_INT64)),
        ERR_UNSUPPORTED,
        "is not a shape this runtime runs",
        "a grouped frame",
    )


def _load_refusals(mut rt: UdfRuntime) raises:
    var u = rt.load(_spec(SHAPE_SCALAR, "fixtures.mjs#not_a_function", TYPE_INT64))
    assert_true(u.outcome.is_ok(), String(u.outcome))
    var c = rt.open_context(0)
    var i = rt.open_instance(c.handle, u.handle)
    _expect(i.outcome, ERR_LOAD, "'not_a_function' is a number, not a function", "not a function")
    rt.close_context(c.handle)
    rt.unload(u.handle)


def _return_types(mut rt: UdfRuntime) raises:
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#returns_float", TYPE_INT64)
    var b = _bind(rt, s, 0)
    var r = rt.call_batch(b.inst, s, _ints([1, 2]), CallOptions.plain())
    _expect(r.outcome, ERR_RETURN_TYPE, "returned number 0.5, not int64", "a float for int64")
    assert_equal(r.outcome.row, 0)
    _unbind(rt, b)
    var s2 = _spec(SHAPE_MAP_BATCHES_COLUMN, "fixtures.mjs#returns_wrong_array", TYPE_FLOAT64)
    var b2 = _bind(rt, s2, 0)
    var r2 = rt.call_batch(b2.inst, s2, _floats([1.0, 2.0]), CallOptions.plain())
    _expect(r2.outcome, ERR_RETURN_TYPE, "Int32Array", "an Int32Array for float64")
    _unbind(rt, b2)


def _state_per_context(mut rt: UdfRuntime) raises:
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#call_counter", TYPE_INT64)
    var a = _bind(rt, s, 0)
    for k in range(3):
        var r = rt.call_batch(a.inst, s, _ints([0]), CallOptions.plain())
        assert_true(r.outcome.is_ok(), String(r.outcome))
        assert_equal(r.column.bits[0], Int64(k + 1), "context A, call " + String(k))
    var c = rt.open_context(1)
    var i = rt.open_instance(c.handle, a.udf)
    var r = rt.call_batch(i.handle, s, _ints([0]), CallOptions.plain())
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(r.column.bits[0], 1, "context B's first row: its own module")
    rt.close_instance(i.handle)
    rt.close_context(c.handle)
    _unbind(rt, a)


def _crashes(mut rt: UdfRuntime) raises:
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#exit_on_row_2", TYPE_INT64)
    var b = _bind(rt, s, 0)
    var r = rt.call_batch(b.inst, s, _ints([0, 1, 2, 3]), CallOptions.plain())
    _expect(r.outcome, ERR_INSTANCE_LOST, "exited with status 3", "exit mid-batch")
    var again = rt.call_batch(b.inst, s, _ints([0]), CallOptions.plain())
    _expect(again.outcome, ERR_INSTANCE_LOST, "worker lost", "a call on the lost context")
    _unbind(rt, b)
    var s2 = _spec(SHAPE_SCALAR, "fixtures.mjs#double", TYPE_INT64)
    var fresh = _bind(rt, s2, 0)
    var ok = rt.call_batch(fresh.inst, s2, _ints([21]), CallOptions.plain())
    assert_true(ok.outcome.is_ok(), "a new context after a crash: " + String(ok.outcome))
    assert_equal(ok.column.bits[0], 42)
    _unbind(rt, fresh)
    var s3 = _spec(SHAPE_SCALAR, "fixtures.mjs#abort_now", TYPE_INT64)
    var ab = _bind(rt, s3, 0)
    var r3 = rt.call_batch(ab.inst, s3, _ints([0]), CallOptions.plain())
    _expect(r3.outcome, ERR_INSTANCE_LOST, "killed by signal 6", "abort")
    _unbind(rt, ab)


def _hard_cancel(mut rt: UdfRuntime) raises:
    var s = _spec(SHAPE_MAP_BATCHES_COLUMN, "fixtures.mjs#spin_forever", TYPE_INT64)
    var b = _bind(rt, s, 0)
    var r = rt.call_batch(b.inst, s, _ints([1, 2]), CallOptions(False, True, False))
    _expect(r.outcome, ERR_INSTANCE_LOST, "did not answer within 500 ms", "a cancel user code ignores")
    _unbind(rt, b)


def _frames(mut rt: UdfRuntime) raises:
    var s = _spec(SHAPE_MAP_BATCHES_FRAME, "fixtures.mjs#not_a_table", TYPE_INT64)
    s.result_is_table = True
    var b = _bind(rt, s, 0)
    var f = rt.run_frame(b.inst, s, [_ints([1])], CallOptions.plain())
    _expect(f.outcome, ERR_RETURN_TYPE, "not a table", "a frame yielding a number")
    _unbind(rt, b)
    var st = _spec(SHAPE_STEP, "fixtures.mjs#step_rows", TYPE_INT64)
    st.result_is_table = True
    st.stability = VOLATILE
    var sb = _bind(rt, st, 0)
    var g = rt.run_frame(sb.inst, st, [_ints([3])], CallOptions.plain())
    assert_true(g.outcome.is_ok(), "step: " + String(g.outcome))
    assert_equal(len(g.outputs), 3, "a step generator's tables")
    for k in range(3):
        assert_equal(g.outputs[k].length, 1)
        assert_equal(g.outputs[k].columns[0].bits[0], Int64(k))
    _unbind(rt, sb)


def _corrupt_outputs() raises:
    var rt = UdfRuntime.open(CORRUPT_LIB)
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#double", TYPE_INT64)
    var b = _bind(rt, s, 0)
    var reasons: List[String] = [
        "a buffer lies outside the body",
        "a values buffer is shorter than the column",
        "columns or buffers differ from the bound schema",
        "null count is out of range",
    ]
    for n in range(1, 5):
        var vals = List[Int]()
        for k in range(n):
            vals.append(k)
        var r = rt.call_batch(b.inst, s, _ints(vals), CallOptions.plain())
        _expect(r.outcome, ERR_INTERNAL, reasons[n - 1], "corrupt output of " + String(n) + " rows")
    var ok = rt.call_batch(b.inst, s, _ints([1, 2, 3, 4, 5]), CallOptions.plain())
    assert_true(ok.outcome.is_ok(), "the worker after refused outputs: " + String(ok.outcome))
    assert_equal(ok.column.bits[4], 10)
    _unbind(rt, b)
    var l = rt.ledger()
    assert_equal(l.exported, l.released, "corrupt: arrays exported vs released")
    rt.shutdown()


def main() raises:
    var rt = UdfRuntime.open(LIB)
    _describe(rt)
    _validate(rt)
    _load_refusals(rt)
    _return_types(rt)
    _state_per_context(rt)
    _crashes(rt)
    _hard_cancel(rt)
    _frames(rt)
    var l = rt.ledger()
    assert_equal(l.exported, l.released, "arrays exported vs released")
    assert_equal(l.double_released, 0)
    assert_equal(l.streams_exported, l.streams_released, "streams exported vs released")
    rt.shutdown()
    _corrupt_outputs()
    print("test_node_worker: ok")
