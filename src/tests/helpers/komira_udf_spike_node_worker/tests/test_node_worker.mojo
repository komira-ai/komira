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
#   - under PROPAGATE, a raise names the row of the compacted batch the
#     worker saw, which the host maps to the caller's (a row reported twice
#     mapped, or dropped);
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
#     own reason: one RecordBatch layout per condition of each refusal of the
#     proxy's IPC validation (ipc.c, kudfw_ipc_decode), so each of the six
#     conditions of the buffer check (an offset or a length below 0, a
#     validity bitmap or a values buffer past the body) is refused alone,
#     including a row count whose byte size wraps int64; a values buffer and
#     a validity bitmap that each end exactly at the body's end are accepted
#     (a bound check off by one); the bitmap's (rows + 7) / 8 and the
#     alignment to the type's width each have a refused case and an
#     accepted one beside the bound (9 rows with 1 byte refused, 9 with 2
#     and 8 with 1 accepted; int64 at offset 4 refused, int32 at 4
#     accepted); malformed ERROR replies and ERROR codes
#     that are not errors (the worker stays usable); five malformed DESCRIBE
#     replies, one per length check, each failing the runtime's open (a
#     runtime id or ABI copied past its buffer); and each break of the
#     framing (magic, request id, op, INLINE flag, payload limit), after
#     which the worker is killed (a validator that lets a layout through
#     hands the host a pointer outside the reply);
#   - every array and stream the host exported is released once.
#
# Mutants planted, each alone, each red on the farm (the corrupt case it
# failed at in brackets): channel.c mapping end of file on the channel to
# ERR_INTERNAL ("exit mid-batch"); ipc.c, kudfw_ipc_decode, without each
# condition of the buffer check: the validity offset past the body (18, a
# SIGSEGV in the host's read), a negative validity offset (19) or length
# (20), a negative values offset (21) or length (22), and the values past
# the body (1); the validity bound as >= (24) and the values bound as >=
# (6, before 23 is reached);
# without the column length check (5), the validity bitmap check (6), the
# compressed check (9), the short-payload half of the marker check (25), the
# header-present check (26), the malformed check after the vectors (27),
# either half of the columns-or-buffers check (28, 29), the negative null
# count check (31), field_at's negative vtable check (32), its short-vtable
# check (33, and every reply apache-arrow writes) or its field-past-the-
# metadata check (34), and the buffer vector's half of the past-the-metadata
# check (17); the values check back to `dl < nlen * w` (8, the wrapping row
# count); the bitmap bound as `nlen / 8` (35, where the host then reads
# row 8's bit past the bitmap) or `(nlen + 8) / 8` (37), the alignment as
# `% 4` (38) or `% 8` (39); channel.c without the request id check of the framing (102), the
# payload limit (105), the bound of an ERROR string's length (115), the
# trace's read (116), or keeping an ERROR code of 0 (113); proxy.c's
# t_describe accepting a runtime id of 128 bytes (DESCRIBE 1), a runtime ABI
# of 64 bytes (DESCRIBE 3), or an ABI 4 bytes past the reply (DESCRIBE 4);
# wire.mjs honouring any nonzero cancel word (the call after a cancel).
#
# Planted and green, each equivalent: ipc.c without `body_len < 0` (a
# negative body length cast to size_t is past every payload, so the next
# condition refuses case 30 with the same reason); proxy.c t_describe
# without its first length check, or with its second one 4 bytes short
# (DESCRIBE 0 and 2 are then refused by the next check, whose bound is past
# the reply whatever the over-read length holds; the up-to-4-byte read past
# the payload it lets through is visible only to a memory checker).

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, Handle, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_FLOAT64, TYPE_INT32, TYPE_INT64
from komira_udf_spike_node_worker.watchdog import arm_watchdog

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
    # "node" and the major version, nothing else: an ABI copied from the
    # wrong offset of the reply starts with the id's last bytes, "node".
    assert_true(caps.runtime_abi.startswith("node"), caps.runtime_abi)
    var abi = caps.runtime_abi.as_bytes()
    assert_true(len(abi) > 4, caps.runtime_abi)
    for i in range(4, len(abi)):
        assert_true(abi[i] >= 48 and abi[i] <= 57, "runtime_abi '" + caps.runtime_abi + "': not node<major>")
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


def _propagate_error_row(mut rt: UdfRuntime) raises:
    # Under PROPAGATE the host drops the null rows, the worker sees the
    # compacted batch, and the error names a row of that batch, which the
    # host maps back (design section 3.4, rule 2). raise_on_row_3 raises on
    # the value 3: compacted row 1 here, caller row 3. A proxy or worker
    # that reported the caller's row would make the host map it again (to
    # row 5); one that dropped the row would report -1.
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#raise_on_row_3", TYPE_INT64)
    s.null_mode = NULL_PROPAGATE
    var b = _bind(rt, s, 0)
    var batch = Batch(5)
    var c = Column(TYPE_INT64)
    c.append_null()
    c.append_int(2)
    c.append_null()
    c.append_int(3)
    c.append_int(4)
    batch.columns.append(c^)
    var r = rt.call_batch(b.inst, s, batch, CallOptions.plain())
    _expect(r.outcome, ERR_RAISED, "raise_on_row_3", "a raise under PROPAGATE")
    assert_equal(r.outcome.row, 3, "the caller's row of the value 3")
    # The worker's JavaScript stack is the error's trace, and a call that
    # is no aggregate names no group.
    assert_true("raise_on_row_3" in r.outcome.trace, "trace: '" + r.outcome.trace + "'")
    assert_equal(r.outcome.group, -1, "the group of a scalar call's error")
    _unbind(rt, b)


def _deadline_before_send(mut rt: UdfRuntime) raises:
    # A call whose deadline has passed is refused before it is sent: the
    # worker never sees it, so it is not killed, and the next call on the
    # same instance runs. A proxy that sent it anyway would wait out the
    # grace period and kill the worker.
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#slow_loop", TYPE_INT64)
    var b = _bind(rt, s, 0)
    var d = rt.call_batch(b.inst, s, _ints([1, 2]), CallOptions(False, False, True))
    _expect(d.outcome, ERR_DEADLINE, "the call's deadline passed before it was sent", "a passed deadline")
    var after = rt.call_batch(b.inst, s, _ints([5]), CallOptions.plain())
    assert_true(after.outcome.is_ok(), "the call after a refused deadline: " + String(after.outcome))
    assert_equal(after.column.bits[0], 5)
    _unbind(rt, b)


def _crashes(mut rt: UdfRuntime) raises:
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#exit_on_row_2", TYPE_INT64)
    var b = _bind(rt, s, 0)
    var r = rt.call_batch(b.inst, s, _ints([0, 1, 2, 3]), CallOptions.plain())
    _expect(r.outcome, ERR_INSTANCE_LOST, "exited with status 3", "exit mid-batch")
    assert_equal(r.outcome.row, -1, "the row of a lost worker's error")
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
    # killed, then reaped and named (a kill left unreaped reads "could not
    # be reaped")
    _expect(r.outcome, ERR_INSTANCE_LOST, "was killed by signal 9", "a cancel user code ignores")
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


def _open_fails(lib: String) -> String:
    try:
        var rt = UdfRuntime.open(lib)
        rt.shutdown()
        return "opened"
    except e:
        return String(e)


def _corrupt_hellos() raises:
    # The corrupt runtime's workers break the HELLO handshake by the order
    # they start (worker/corrupt.mjs, helloCorrupt): the first three are
    # admission workers, so the first three opens fail at init.
    var why = _open_fails(CORRUPT_LIB)
    assert_true("ERR_INSTANCE_LOST" in why and "exited with status 5" in why, "HELLO 0, no answer: " + why)
    why = _open_fails(CORRUPT_LIB)
    assert_true("ERR_ABI" in why and "the worker speaks wire 2, ABI 1.0" in why, "HELLO 1, wire 2: " + why)
    why = _open_fails(CORRUPT_LIB)
    assert_true("ERR_ABI" in why and "the worker speaks wire 0, ABI 0.0" in why, "HELLO 2, 8 bytes: " + why)


def _corrupt_describes() raises:
    # The corrupt runtime's first five DESCRIBE replies are malformed, one
    # length check each (worker/corrupt.mjs, describeCorrupt); open asks
    # describe, so the first five opens fail and the sixth gets the right
    # reply.
    for i in range(5):
        var why = String("")
        try:
            var bad = UdfRuntime.open(CORRUPT_LIB)
            bad.shutdown()
            why = "accepted"
        except e:
            why = String(e)
        assert_true("describe returned ERR_INTERNAL" in why, "corrupt DESCRIBE " + String(i) + ": " + why)
    # The sixth is valid: a runtime ABI of 0 bytes ending the reply (a bound
    # one byte too strict refuses it).
    var empty = UdfRuntime.open(CORRUPT_LIB)
    assert_equal(empty.describe().runtime_abi, "", "DESCRIBE 5: an empty runtime ABI")
    # Workers 0 to 8 were admission workers (three HELLO cases, six opens
    # since); the tenth is this context's, which exits before its HELLO: the
    # context is refused with the spawn's reason, and the next one opens.
    var lost = empty.open_context(0)
    _expect(lost.outcome, ERR_INSTANCE_LOST, "exited with status 5", "a context whose worker dies at HELLO")
    var next = empty.open_context(0)
    assert_true(next.outcome.is_ok(), "the context after: " + String(next.outcome))
    empty.close_context(next.handle)
    empty.shutdown()


def _same(k: Int, n: Int) -> Batch:
    var vals = List[Int]()
    for _ in range(n):
        vals.append(k)
    return _ints(vals)


def _bitmap_and_alignment(mut rt: UdfRuntime, b: Bound, s: UdfSpec) raises:
    # The arithmetic inside two refusals, each with a case on both sides of
    # its bound (worker/corrupt.mjs, cases 35 to 39). The bitmap's rounding
    # (rows + 7) / 8: 9 rows with a 1-byte bitmap are refused (a bound of
    # rows / 8 accepts them, and the host reads row 8's bit past the
    # bitmap), 9 rows with 2 bytes and 8 rows with 1 byte, each bitmap ending
    # at the body's end, are accepted (a bound rounded up once too often
    # refuses 37). The alignment to the type's width: int64 values at offset
    # 4 are refused (an alignment of 4 for every type accepts them), int32
    # values at offset 4 are accepted (an alignment of 8 refuses them).
    var r35 = rt.call_batch(b.inst, s, _ints([35]), CallOptions.plain())
    _expect(r35.outcome, ERR_INTERNAL, "failed validation: a validity bitmap is shorter than the column", "corrupt case 35")
    for k in range(36, 38):
        var n = 9 if k == 36 else 8
        var r = rt.call_batch(b.inst, s, _same(k, n), CallOptions.plain())
        assert_true(r.outcome.is_ok(), "corrupt case " + String(k) + " is valid: " + String(r.outcome))
        assert_equal(len(r.column), n, "corrupt case " + String(k))
        for i in range(n):
            assert_equal(r.column.valid[i], i != 0, "corrupt case " + String(k) + ": row " + String(i) + " null")
            assert_equal(r.column.bits[i], 0, "corrupt case " + String(k) + ": row " + String(i))
    var r38 = rt.call_batch(b.inst, s, _ints([38]), CallOptions.plain())
    _expect(r38.outcome, ERR_INTERNAL, "failed validation: a values buffer is not aligned to its type", "corrupt case 38")
    var n32 = UdfSpec(SHAPE_MAP_BATCHES_COLUMN, "fixtures.mjs#narrow", [ColumnType(TYPE_INT64, True)], [ColumnType(TYPE_INT32, True)])
    var nb = _bind(rt, n32, 0)
    var r39 = rt.call_batch(nb.inst, n32, _ints([39]), CallOptions.plain())
    assert_true(r39.outcome.is_ok(), "corrupt case 39 is valid: " + String(r39.outcome))
    assert_equal(len(r39.column), 1, "corrupt case 39")
    assert_equal(r39.column.bits[0], 0, "corrupt case 39")
    _unbind(rt, nb)


def _reader_bounds(mut rt: UdfRuntime, b: Bound, s: UdfSpec) raises:
    # The flatbuffer reader's own bounds and the payload's (corrupt cases 40
    # to 56, laid out byte by byte by worker/corrupt.mjs's layout()): each
    # piece moved to the metadata's end, past it by part of its width, or
    # onto offset 0; "" is a layout the proxy must accept (one row, 0).
    var reasons: List[String] = [
        "",
        "the RecordBatch metadata is malformed",
        "the RecordBatch metadata is malformed",
        "",
        "the RecordBatch metadata is malformed",
        "the IPC message is not a RecordBatch",
        "the RecordBatch's columns or buffers differ from the bound schema",
        "the RecordBatch metadata is malformed",
        "",
        "the IPC message is not a RecordBatch",
        "the IPC message is not a RecordBatch",
        "the IPC metadata length is past the payload or not a multiple of 8",
        "the RecordBatch body is longer than the payload",
        "a node or buffer vector runs past the metadata",
        "a node or buffer vector runs past the metadata",
        "a buffer lies outside the body",
        "a buffer lies outside the body",
    ]
    for i in range(len(reasons)):
        var k = 40 + i
        var r = rt.call_batch(b.inst, s, _ints([k]), CallOptions.plain())
        if reasons[i] != "":
            _expect(r.outcome, ERR_INTERNAL, "failed validation: " + reasons[i], "corrupt case " + String(k))
            continue
        assert_true(r.outcome.is_ok(), "corrupt case " + String(k) + " is valid: " + String(r.outcome))
        assert_equal(len(r.column), 1, "corrupt case " + String(k))
        assert_true(r.column.valid[0], "corrupt case " + String(k) + ": null")
        assert_equal(r.column.bits[0], 0, "corrupt case " + String(k))


def _corrupt_refusals(mut rt: UdfRuntime) raises:
    # Requests the corrupt worker refuses (worker/corrupt.mjs,
    # refuseCorrupt), each passed on by the proxy with the worker's reason
    # and no handle: OPEN_CONTEXT, a context's LOAD of a UDF the admission
    # worker loaded, AGG_OPEN.
    var c7 = rt.open_context(7)
    _expect(c7.outcome, ERR_INTERNAL, "OPEN_CONTEXT refused for slot 7", "a refused OPEN_CONTEXT")
    var c = rt.open_context(0)
    assert_true(c.outcome.is_ok(), String(c.outcome))
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#refused_in_context", TYPE_INT64)
    var u = rt.load(s)
    assert_true(u.outcome.is_ok(), "the admission worker's LOAD: " + String(u.outcome))
    var i = rt.open_instance(c.handle, u.handle)
    _expect(i.outcome, ERR_INTERNAL, "LOAD refused in a context", "a context's refused LOAD")
    rt.unload(u.handle)
    var a = _spec(SHAPE_AGG_MERGEABLE, "fixtures.mjs#agg_open_refused", TYPE_INT64)
    a.state = ColumnType(TYPE_INT64, True)
    var au = rt.load(a)
    var ai = rt.open_instance(c.handle, au.handle)
    assert_true(ai.outcome.is_ok(), String(ai.outcome))
    var g = rt.agg_open(ai.handle)
    _expect(g.outcome, ERR_INTERNAL, "AGG_OPEN refused", "a refused AGG_OPEN")
    rt.close_instance(ai.handle)
    rt.unload(au.handle)
    rt.close_context(c.handle)


def _corrupt_outputs() raises:
    _corrupt_hellos()
    _corrupt_describes()
    var rt = UdfRuntime.open(CORRUPT_LIB)
    assert_equal(rt.describe().runtime_id, "komira-test/node", "the DESCRIBE after the malformed ones")
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#double", TYPE_INT64)
    var b = _bind(rt, s, 0)
    # The refused RecordBatch cases of worker/corrupt.mjs, by number, each
    # with its reason: one layout per condition of each refusal (the buffer
    # check's six conditions are cases 1 and 18 to 22).
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
        "a buffer lies outside the body",
        "a buffer lies outside the body",
        "a buffer lies outside the body",
        "a buffer lies outside the body",
        "a buffer lies outside the body",
        "",
        "",
        "the reply is not an IPC message (no continuation marker)",
        "the IPC message is not a RecordBatch",
        "the RecordBatch metadata is malformed",
        "the RecordBatch's columns or buffers differ from the bound schema",
        "the RecordBatch's columns or buffers differ from the bound schema",
        "the RecordBatch body is longer than the payload",
        "a column's null count is out of range",
        "the RecordBatch metadata is malformed",
        "",
        "the IPC message is not a RecordBatch",
    ]
    for i in range(len(layouts)):
        var k = i + 1
        var r = rt.call_batch(b.inst, s, _ints([k]), CallOptions.plain())
        if layouts[i] != "":
            _expect(r.outcome, ERR_INTERNAL, "failed validation: " + layouts[i], "corrupt case " + String(k))
            continue
        # Cases 23, 24 and 33 are valid, so the proxy must accept them: a
        # buffer that ends exactly at the end of the body is inside it (a
        # bound check off by one refuses 23 or 24), and a vtable shorter than
        # a slot leaves that field absent. 24's one row is null; 23's and
        # 33's is 0.
        assert_true(r.outcome.is_ok(), "corrupt case " + String(k) + " is valid: " + String(r.outcome))
        assert_equal(len(r.column), 1, "corrupt case " + String(k))
        assert_equal(r.column.valid[0], k != 24, "corrupt case " + String(k) + ": null")
        assert_equal(r.column.bits[0], 0, "corrupt case " + String(k))
    _bitmap_and_alignment(rt, b, s)
    _reader_bounds(rt, b, s)
    # Malformed ERROR replies and ERROR codes that are not errors (cases 111
    # to 117: too short, a message longer than the payload, codes 0 and -5,
    # no message length, a trace longer than the payload, code 999, past
    # the status table): the framing holds, so the worker stays usable.
    var errors: List[String] = [
        "a malformed ERROR reply (10 bytes)",
        "a malformed ERROR reply",
        "an ERROR reply with code 0",
        "an ERROR reply with code -5",
        "a malformed ERROR reply",
        "a malformed ERROR reply",
        "an ERROR reply with code 999",
    ]
    # Case 118: code 1 (ERR_ABI), the status table's first code, is passed
    # on as it is (a bound one too high maps it to ERR_INTERNAL).
    var abi = rt.call_batch(b.inst, s, _ints([118]), CallOptions.plain())
    _expect(abi.outcome, ERR_ABI, "an ERROR reply with code 1", "corrupt case 118")
    for i in range(len(errors)):
        var r = rt.call_batch(b.inst, s, _ints([111 + i]), CallOptions.plain())
        _expect(r.outcome, ERR_INTERNAL, errors[i], "corrupt case " + String(111 + i))
        if i == 4:
            # 20 bytes, exactly the fixed fields: refused by the message's
            # length field, not by the short-reply check (which names the
            # byte count)
            assert_true("bytes)" not in r.outcome.message, "corrupt case 115: " + r.outcome.message)
    var ok = rt.call_batch(b.inst, s, _ints([1, 2, 3, 4, 5]), CallOptions.plain())
    assert_true(ok.outcome.is_ok(), "the worker after refused replies: " + String(ok.outcome))
    assert_equal(ok.column.bits[4], 10)
    _unbind(rt, b)
    _corrupt_refusals(rt)
    # Breaks of the framing (cases 101 to 105): the worker is killed, so
    # each case gets its own context.
    for k in range(101, 106):
        var f = _bind(rt, s, 0)
        var r = rt.call_batch(f.inst, s, _ints([k]), CallOptions.plain())
        _expect(r.outcome, ERR_INSTANCE_LOST, "a reply broke the framing", "corrupt case " + String(k))
        _unbind(rt, f)
    # Case 106: a payload of exactly the limit (2^31 bytes) is not a framing
    # break; the worker exits before sending it, so the call ends at end of
    # file (or, where the 2 GiB buffer cannot be had, out of memory).
    var f6 = _bind(rt, s, 0)
    var r6 = rt.call_batch(f6.inst, s, _ints([106]), CallOptions.plain())
    assert_true("broke the framing" not in r6.outcome.message, "corrupt case 106: " + String(r6.outcome))
    assert_true(
        r6.outcome.status == ERR_INSTANCE_LOST or r6.outcome.status == ERR_OUT_OF_MEMORY,
        "corrupt case 106: " + String(r6.outcome),
    )
    _unbind(rt, f6)
    var l = rt.ledger()
    assert_equal(l.exported, l.released, "corrupt: arrays exported vs released")
    rt.shutdown()


def main() raises:
    arm_watchdog()
    var rt = UdfRuntime.open(LIB)
    _describe(rt)
    _validate(rt)
    _load_refusals(rt)
    _return_types(rt)
    _propagate_error_row(rt)
    _deadline_before_send(rt)
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
