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
#   - a cancel belongs to its call: after a call cancelled mid-batch, the
#     next call on the same instance runs to the end (the proxy never clears
#     the cancel word, so a worker that honours any nonzero word, not only
#     its own request's id, would cancel every later call);
#   - a frame that yields a non-table is ERR_RETURN_TYPE; a step generator's
#     three tables come back in order;
#   - replies a worker in its --corrupt-output mode sends
#     (node_worker_corrupt.so, worker/corrupt.mjs), each refused with its
#     own reason: one RecordBatch layout per refusal of the proxy's IPC
#     validation (ipc.c, kudfw_ipc_decode), before any pointer is formed,
#     including a row count whose byte size wraps int64; malformed ERROR
#     replies and ERROR codes that are not errors (the worker stays usable);
#     and each break of the framing (magic, request id, op, INLINE flag,
#     payload limit), after which the worker is killed (a validator that
#     lets a layout through hands the host a pointer past the reply);
#   - every array and stream the host exported is released once.
#
# Mutants planted, each red on the farm: channel.c mapping end of file on
# the channel to ERR_INTERNAL instead of ERR_INSTANCE_LOST ("exit
# mid-batch"); ipc.c without the "a buffer lies outside the body" check
# (corrupt case 1 accepted); ipc.c without the column length check (case
# 5); ipc.c without the validity bitmap check (case 6); ipc.c with the
# values check back to `dl < nlen * w` (case 8, the wrapping row count);
# ipc.c without the compressed check (case 9); ipc.c without the buffer
# vector's half of the past-the-metadata check (case 17); channel.c without
# the request id check of the framing (case 102); channel.c without the
# payload limit (case 105); channel.c keeping an ERROR code of 0 (case
# 113); wire.mjs honouring any nonzero cancel word (the call after a
# cancel).

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


def _cancel_scoped(mut rt: UdfRuntime) raises:
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#slow_loop", TYPE_INT64)
    var b = _bind(rt, s, 0)
    var c = rt.call_batch(b.inst, s, _ints([0, 0, 0, 0, 0]), CallOptions(False, True, False))
    _expect(c.outcome, ERR_CANCELLED, "cancelled at row", "a cancel during the call")
    var after = rt.call_batch(b.inst, s, _ints([1, 2, 3]), CallOptions.plain())
    assert_true(after.outcome.is_ok(), "the call after a cancelled one: " + String(after.outcome))
    assert_equal(after.column.bits[2], 3)
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
    # The RecordBatch cases 1 to 17 of worker/corrupt.mjs, by number.
    var layouts: List[String] = [
        "a buffer lies outside the body",
        "a values buffer is shorter than the column",
        "the RecordBatch's columns or buffers differ from the bound schema",
        "a column's null count is out of range",
        "a column's length differs from the batch's",
        "a validity bitmap is shorter than the column",
        "a values buffer is not aligned to its type",
        "a values buffer is shorter than the column",
        "the RecordBatch is compressed",
        "the IPC message is not a RecordBatch",
        "the reply is not an IPC message (no continuation marker)",
        "the IPC metadata length is past the payload or not a multiple of 8",
        "the IPC metadata length is past the payload or not a multiple of 8",
        "the RecordBatch body is longer than the payload",
        "the RecordBatch metadata is malformed",
        "a node or buffer vector runs past the metadata",
        "a node or buffer vector runs past the metadata",
    ]
    for i in range(len(layouts)):
        var r = rt.call_batch(b.inst, s, _ints([i + 1]), CallOptions.plain())
        _expect(r.outcome, ERR_INTERNAL, "failed validation: " + layouts[i], "corrupt case " + String(i + 1))
    # Malformed ERROR replies (cases 111 to 114): the framing holds, so the
    # worker stays usable.
    var errors: List[String] = [
        "a malformed ERROR reply (10 bytes)",
        "a malformed ERROR reply",
        "an ERROR reply with code 0",
        "an ERROR reply with code -5",
    ]
    for i in range(len(errors)):
        var r = rt.call_batch(b.inst, s, _ints([111 + i]), CallOptions.plain())
        _expect(r.outcome, ERR_INTERNAL, errors[i], "corrupt case " + String(111 + i))
    var ok = rt.call_batch(b.inst, s, _ints([1, 2, 3, 4, 5]), CallOptions.plain())
    assert_true(ok.outcome.is_ok(), "the worker after refused replies: " + String(ok.outcome))
    assert_equal(ok.column.bits[4], 10)
    _unbind(rt, b)
    # Breaks of the framing (cases 101 to 105): the worker is killed, so
    # each case gets its own context.
    for k in range(101, 106):
        var f = _bind(rt, s, 0)
        var r = rt.call_batch(f.inst, s, _ints([k]), CallOptions.plain())
        _expect(r.outcome, ERR_INSTANCE_LOST, "a reply broke the framing", "corrupt case " + String(k))
        _unbind(rt, f)
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
    _cancel_scoped(rt)
    _frames(rt)
    var l = rt.ledger()
    assert_equal(l.exported, l.released, "arrays exported vs released")
    assert_equal(l.double_released, 0)
    assert_equal(l.streams_exported, l.streams_released, "streams exported vs released")
    rt.shutdown()
    _corrupt_outputs()
    print("test_node_worker: ok")
