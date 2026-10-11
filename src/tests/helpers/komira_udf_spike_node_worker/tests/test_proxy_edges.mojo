# The node worker proxy's own refusals and messages that the conformance
# corpus and test_node_worker leave open, each found by the scripted
# mutation sweep of proxy/*.c (the pull request's scorecard), through the C
# ABI only (UdfRuntime).
#
# What it proves, and the defect each part catches:
#   - a spec the transport cannot carry is refused before any worker sees
#     it: 65 argument fields, a field name of 64 bytes, a descriptor of 1025
#     bytes (a fixed-size copy overrun); 63 bytes and 1024 bytes pass the
#     proxy (a bound one too strict);
#   - load refuses a spec the worker refuses, with the worker's reason, and
#     returns no udf (a load answered OK without asking the worker, or a
#     refusal turned into a udf);
#   - one context holds 32 UDFs and refuses the 33rd by name, and serves 40
#     instances of one UDF (a full table written past its end, or a UDF
#     loaded again for every instance);
#   - a cancel already set is refused before anything is sent, by name, for
#     a call (row 0), a frame's open and an aggregate's update (a cancel
#     left to the worker instead);
#   - an input struct whose width differs from the bound schema is refused
#     for a frame and for an aggregate update (extra columns dropped, or an
#     empty FRAME_IN sent after the refusal);
#   - an aggregate whose finish raises is ERR_RAISED with the worker's
#     message (an error reply decoded as an output);
#   - after shutdown no descriptor and no child process of the runtime is
#     left (the channel or the cancel word not closed, a worker not reaped).
#
# Mutants planted (the sweep's ids in the pull request): ipc.c without the
# 64-field bound (m0547) or the name-length bound (m0539); proxy.c without
# the descriptor bound (m1111), t_load not sending LOAD (m1124) or keeping a
# refused udf (m1128), t_open_instance never finding a loaded UDF (m1151)
# or without the 32-UDF bound (m1155), call_batch's (m1179), frame_open's
# (m1192) and agg_send's (m1231) cancel checks, encode_struct's width check
# (m1168), frame_next going on after a failed input (m1219), agg_send's
# width check (m1242), agg_emit decoding an ERROR reply (m1258); channel.c
# kudfw_stop not closing the channel (m0915) or the cancel word (m0917), or
# not reaping (m0919). Each red on the farm.

from std.os import listdir
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, Handle, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_INT64
from komira_udf_spike_node_worker.watchdog import arm_watchdog

comptime LIB = "./node_worker.so"


def _ints(vals: List[Int]) -> Batch:
    var b = Batch(len(vals))
    var c = Column(TYPE_INT64)
    for v in vals:
        c.append_int(Int64(v))
    b.columns.append(c^)
    return b^


def _two_columns() -> Batch:
    var b = Batch(1)
    for v in range(2):
        var c = Column(TYPE_INT64)
        c.append_int(Int64(v + 1))
        b.columns.append(c^)
    return b^


def _spec(shape: UInt32, entry: String, n_args: Int = 1) -> UdfSpec:
    var args = List[ColumnType]()
    for _ in range(n_args):
        args.append(ColumnType(TYPE_INT64, True))
    return UdfSpec(shape, entry, args^, [ColumnType(TYPE_INT64, True)])


def _expect(got: Outcome, status: Int32, text: String, what: String) raises:
    assert_equal(status_name(got.status), status_name(status), what + ": " + String(got))
    assert_true(text in got.message, what + ": message '" + got.message + "' lacks '" + text + "'")


def _spec_refusals(mut rt: UdfRuntime) raises:
    var wide = _spec(SHAPE_SCALAR, "fixtures.mjs#sum64", 65)
    _expect(rt.validate(wide), ERR_UNSUPPORTED, "more fields than the transport carries", "65 fields")
    for n in range(63, 65):
        var name = String("")
        for _ in range(n):
            name += "a"
        var row = _spec(SHAPE_ROW, "fixtures.mjs#pick")
        row.arg_names = [name]
        var got = rt.validate(row)
        if n == 64:
            _expect(got, ERR_UNSUPPORTED, "a field name longer than 63 bytes", "a 64-byte name")
        else:
            _expect(got, OK, "", "a 63-byte name")
    for n in range(1024, 1026):
        var d = _spec(SHAPE_SCALAR, "fixtures.mjs#double")
        for _ in range(n):
            d.descriptor.append(UInt8(7))
        var got = rt.validate(d)
        if n == 1025:
            _expect(got, ERR_DESCRIPTOR, "a descriptor longer than 1024 bytes", "a 1025-byte descriptor")
        else:
            # past the proxy; the worker refuses it for its own reason
            _expect(got, ERR_DESCRIPTOR, "these bytes are not canonical", "a 1024-byte descriptor")


def _load_refusal(mut rt: UdfRuntime) raises:
    var u = rt.load(_spec(SHAPE_SCALAR, "missing.mjs#double"))
    _expect(u.outcome, ERR_DESCRIPTOR, "no bundle missing.mjs", "load of a missing bundle")


def _udfs_per_context(mut rt: UdfRuntime) raises:
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#double")
    var udfs = List[Handle]()
    for _ in range(33):
        var u = rt.load(s)
        assert_true(u.outcome.is_ok(), "load: " + String(u.outcome))
        udfs.append(u.handle.copy())
    var c = rt.open_context(0)
    assert_true(c.outcome.is_ok(), String(c.outcome))
    var insts = List[Handle]()
    for i in range(33):
        var o = rt.open_instance(c.handle, udfs[i])
        if i < 32:
            assert_true(o.outcome.is_ok(), "UDF " + String(i) + " in one context: " + String(o.outcome))
            insts.append(o.handle.copy())
        else:
            _expect(o.outcome, ERR_UNSUPPORTED, "more than 32 UDFs in one context", "the 33rd UDF")
    for i in range(len(insts)):
        rt.close_instance(insts[i])
    rt.close_context(c.handle)
    # 40 instances of one UDF in one context: loaded once.
    var c2 = rt.open_context(1)
    var many = List[Handle]()
    for i in range(40):
        var o = rt.open_instance(c2.handle, udfs[0])
        assert_true(o.outcome.is_ok(), "instance " + String(i) + " of one UDF: " + String(o.outcome))
        many.append(o.handle.copy())
    var r = rt.call_batch(many[39], s, _ints([4]), CallOptions.plain())
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(r.column.bits[0], 8)
    for i in range(len(many)):
        rt.close_instance(many[i])
    rt.close_context(c2.handle)
    for i in range(len(udfs)):
        rt.unload(udfs[i])


def _cancelled_before(mut rt: UdfRuntime) raises:
    var cancel = CallOptions(True, False, False)
    var s = _spec(SHAPE_SCALAR, "fixtures.mjs#slow_loop")
    var u = rt.load(s)
    var c = rt.open_context(0)
    var i = rt.open_instance(c.handle, u.handle)
    var r = rt.call_batch(i.handle, s, _ints([1, 2]), cancel)
    _expect(r.outcome, ERR_CANCELLED, "cancelled before the batch was sent", "a call cancelled before it")
    assert_equal(r.outcome.row, 0, "the row of a call cancelled before it")
    rt.close_instance(i.handle)
    var f = _spec(SHAPE_MAP_BATCHES_FRAME, "fixtures.mjs#running_sum")
    f.result_is_table = True
    var fu = rt.load(f)
    var fi = rt.open_instance(c.handle, fu.handle)
    var fr = rt.run_frame(fi.handle, f, [_ints([1])], cancel)
    _expect(fr.outcome, ERR_CANCELLED, "cancelled before the frame opened", "a frame cancelled before it")
    # an input of two columns for one bound argument
    var w = rt.run_frame(fi.handle, f, [_two_columns()], CallOptions.plain())
    _expect(w.outcome, ERR_INTERNAL, "the host passed a struct of 2 children", "a frame input of two columns")
    rt.close_instance(fi.handle)
    rt.close_context(c.handle)
    rt.unload(u.handle)
    rt.unload(fu.handle)


def _aggregates(mut rt: UdfRuntime) raises:
    var c = rt.open_context(0)
    for k in range(2):
        var entry = "fixtures.mjs#sum" if k == 0 else "fixtures.mjs#sum_finish_raises"
        var s = _spec(SHAPE_AGG_MERGEABLE, entry)
        s.state = ColumnType(TYPE_INT64, True)
        var u = rt.load(s)
        assert_true(u.outcome.is_ok(), String(u.outcome))
        var i = rt.open_instance(c.handle, u.handle)
        assert_true(i.outcome.is_ok(), String(i.outcome))
        var g = rt.agg_open(i.handle)
        assert_true(g.outcome.is_ok(), String(g.outcome))
        if k == 0:
            var cancelled = rt.agg_update(g.handle, _ints([5]), [Int32(0)], 1, CallOptions(True, False, False))
            _expect(cancelled, ERR_CANCELLED, "cancelled before the batch was sent", "an update cancelled before it")
            var wide = rt.agg_update(g.handle, _two_columns(), [Int32(0)], 1, CallOptions.plain())
            _expect(wide, ERR_INTERNAL, "the argument struct does not match the bound schema", "an update of two columns")
        var ok = rt.agg_update(g.handle, _ints([5, 6]), [Int32(0), Int32(0)], 1, CallOptions.plain())
        assert_true(ok.is_ok(), "update: " + String(ok))
        var fin = rt.agg_finish(g.handle, 1, ColumnType(TYPE_INT64, True))
        if k == 0:
            assert_true(fin.outcome.is_ok(), "finish: " + String(fin.outcome))
            assert_equal(fin.column.bits[0], 11, "sum of 5 and 6")
        else:
            _expect(fin.outcome, ERR_RAISED, "sum_finish_raises: finish", "a finish that raises")
        rt.agg_close(g.handle)
        rt.close_instance(i.handle)
        rt.unload(u.handle)
    rt.close_context(c.handle)


def _fds() raises -> Int:
    return len(listdir("/proc/self/fd"))


def _children() raises -> String:
    """The pids of this process's children, from every thread's list."""
    var out = String("")
    for t in listdir("/proc/self/task"):
        with open("/proc/self/task/" + t + "/children", "r") as f:
            out += f.read()
    return out^


def main() raises:
    arm_watchdog()
    var fds0 = _fds()
    var rt = UdfRuntime.open(LIB)
    _spec_refusals(rt)
    _load_refusal(rt)
    _udfs_per_context(rt)
    _cancelled_before(rt)
    _aggregates(rt)
    var l = rt.ledger()
    assert_equal(l.exported, l.released, "arrays exported vs released")
    assert_equal(l.streams_exported, l.streams_released, "streams exported vs released")
    rt.shutdown()
    assert_equal(_fds(), fds0, "descriptors open after shutdown, against before open")
    assert_equal(_children().strip(), "", "child processes left after shutdown")
    print("test_proxy_edges: ok")
