# The komira-test/node worker's own refusals and loops that the conformance
# corpus and test_node_worker leave open, each found by the scripted
# mutation sweep of worker/*.mjs (the pull request's scorecard), through the
# C ABI only (UdfRuntime).
#
# What it proves, and the defect each part catches:
#   - a returned value of the wrong type or range is ERR_RETURN_TYPE with
#     its row: a string for float64, a bigint past int64, a number past
#     int32; a safe integer number for int64 is taken (a check dropped or
#     too strict, a value wrapped silently);
#   - a cancel during the call is honoured by every per-row loop: no
#     argument, two arguments, ROW (a loop that never reads the cancel word
#     runs on until the proxy kills the worker);
#   - a symbol read on a row is not a field read (a ROW guard that records
#     every property access);
#   - a frame yielding a table of the wrong width or a column of the wrong
#     length, or returning no iterator, is ERR_RETURN_TYPE with its reason;
#     a frame closed before it ended has its generator closed (its finally
#     runs);
#   - an aggregate's merge is its merge, not its update;
#   - validate refuses a column shape returning a table, a mergeable
#     aggregate without a state, and ROW fields named twice; open_instance
#     refuses a mergeable aggregate whose export is a function.
#
# Mutants planted (the sweep's ids in the pull request): calls.mjs Out.set
# without its float64 (m1415), int64 range (m1421), safe-number (m1423) and
# int32 (m1426) checks, the cancel check of the zero-argument (m1445),
# many-argument (m1448) and ROW (m1457) loops, the row guard's symbol test
# (m1451); frames.mjs outputOf without its RecordBatch width (m1490),
# table width (m1499) and column length (m1503) checks, Frame.start without
# its iterator check (m1549), Frame.close not closing the generator
# (m1564), Groups.update merging as an update (m1575); runtime.mjs spec()
# without its column-shape (m1598), state (m1602) and ROW name (m1608,
# m1610) checks, openInstance without its aggregate check (m1629), and
# FRAME_CLOSE not closing the frame (m1656). Each red on the farm.

from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, Handle, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_FLOAT64, TYPE_INT32, TYPE_INT64
from komira_udf_spike_node_worker.watchdog import arm_watchdog

comptime LIB = "./node_worker.so"


def _ints(vals: List[Int], n_cols: Int = 1) -> Batch:
    var b = Batch(len(vals))
    for _ in range(n_cols):
        var c = Column(TYPE_INT64)
        for v in vals:
            c.append_int(Int64(v))
        b.columns.append(c^)
    return b^


def _spec(shape: UInt32, entry: String, n_args: Int = 1, result: Int = TYPE_INT64) -> UdfSpec:
    var args = List[ColumnType]()
    for _ in range(n_args):
        args.append(ColumnType(TYPE_INT64, True))
    return UdfSpec(shape, entry, args^, [ColumnType(result, True)])


def _expect(got: Outcome, status: Int32, text: String, what: String) raises:
    assert_equal(status_name(got.status), status_name(status), what + ": " + String(got))
    assert_true(text in got.message, what + ": message '" + got.message + "' lacks '" + text + "'")


struct Bound(Copyable, Movable):
    var udf: Handle
    var inst: Handle

    def __init__(out self, var udf: Handle, var inst: Handle):
        self.udf = udf^
        self.inst = inst^


def _bind(mut rt: UdfRuntime, ctx: Handle, spec: UdfSpec) raises -> Bound:
    var u = rt.load(spec)
    assert_true(u.outcome.is_ok(), "load " + spec.entry + ": " + String(u.outcome))
    var i = rt.open_instance(ctx, u.handle)
    assert_true(i.outcome.is_ok(), "open_instance " + spec.entry + ": " + String(i.outcome))
    return Bound(u.handle.copy(), i.handle.copy())


def _unbind(mut rt: UdfRuntime, b: Bound) raises:
    rt.close_instance(b.inst)
    rt.unload(b.udf)


def _return_types(mut rt: UdfRuntime, ctx: Handle) raises:
    var cases: List[String] = ["returns_text", "returns_huge", "returns_number", "returns_big_int32"]
    var results: List[Int] = [TYPE_FLOAT64, TYPE_INT64, TYPE_INT64, TYPE_INT32]
    var texts: List[String] = ["returned string x, not float64", "returned 18446744073709551616n, not int64", "", "returned number 2147483648, not int32"]
    for k in range(len(cases)):
        var s = _spec(SHAPE_SCALAR, "fixtures.mjs#" + cases[k], 1, results[k])
        var b = _bind(rt, ctx, s)
        var r = rt.call_batch(b.inst, s, _ints([4, 5]), CallOptions.plain())
        if texts[k] == "":
            assert_true(r.outcome.is_ok(), cases[k] + ": " + String(r.outcome))
            assert_equal(r.column.bits[1], 6, cases[k] + ": a safe integer number for int64")
        else:
            _expect(r.outcome, ERR_RETURN_TYPE, texts[k], cases[k])
            assert_equal(r.outcome.row, 0, cases[k] + ": the row")
        _unbind(rt, b)


def _cancel_every_loop(mut rt: UdfRuntime, ctx: Handle) raises:
    var during = CallOptions(False, True, False)
    for k in range(3):
        var s: UdfSpec
        if k == 0:
            s = _spec(SHAPE_SCALAR, "fixtures.mjs#slow_zero", 0)
        elif k == 1:
            s = _spec(SHAPE_SCALAR, "fixtures.mjs#slow_pair", 2)
        else:
            s = _spec(SHAPE_ROW, "fixtures.mjs#slow_row")
            s.arg_names = ["a"]
        var b = _bind(rt, ctx, s)
        var vals = List[Int]()
        for i in range(10):
            vals.append(i)
        var batch = _ints(vals, 2 if k == 1 else 1)
        if k == 0:
            batch = Batch(10)
        var r = rt.call_batch(b.inst, s, batch, during)
        _expect(r.outcome, ERR_CANCELLED, "cancelled at row", s.entry + " cancelled during the call")
        _unbind(rt, b)


def _row_symbol(mut rt: UdfRuntime, ctx: Handle) raises:
    var s = _spec(SHAPE_ROW, "fixtures.mjs#row_symbol_probe")
    s.arg_names = ["a"]
    var b = _bind(rt, ctx, s)
    var r = rt.call_batch(b.inst, s, _ints([3]), CallOptions.plain())
    assert_true(r.outcome.is_ok(), "a symbol read on a row: " + String(r.outcome))
    assert_equal(r.column.bits[0], 3)
    _unbind(rt, b)


def _two_column_table() -> List[ColumnType]:
    return [ColumnType(TYPE_INT64, True), ColumnType(TYPE_INT64, True)]


def _frames(mut rt: UdfRuntime, ctx: Handle) raises:
    var entries: List[String] = ["frame_rb_one_col", "frame_one_column", "frame_short_column", "not_an_iterator"]
    var texts: List[String] = [
        "a table of 1 columns for 2 declared",
        "a table of 1 columns for 2 declared",
        "a table column of 1 rows in a table of 2",
        "a frame function returned no iterator",
    ]
    for k in range(len(entries)):
        var s = _spec(SHAPE_MAP_BATCHES_FRAME, "fixtures.mjs#" + entries[k])
        s.result_is_table = True
        if k < 2:
            s.result = _two_column_table()
        var b = _bind(rt, ctx, s)
        var f = rt.run_frame(b.inst, s, [_ints([1])], CallOptions.plain())
        _expect(f.outcome, ERR_RETURN_TYPE, texts[k], entries[k])
        _unbind(rt, b)
    # An endless frame, which the host closes after 1001 outputs: its
    # generator is closed, so its finally runs once.
    var e = _spec(SHAPE_MAP_BATCHES_FRAME, "fixtures.mjs#endless_counted")
    e.result_is_table = True
    var eb = _bind(rt, ctx, e)
    _ = rt.run_frame(eb.inst, e, [_ints([1])], CallOptions.plain())
    _unbind(rt, eb)
    var c = _spec(SHAPE_SCALAR, "fixtures.mjs#closed_frames")
    var cb = _bind(rt, ctx, c)
    var r = rt.call_batch(cb.inst, c, _ints([0]), CallOptions.plain())
    assert_true(r.outcome.is_ok(), String(r.outcome))
    assert_equal(r.column.bits[0], 1, "generators closed")
    _unbind(rt, cb)


def _merge(mut rt: UdfRuntime, ctx: Handle) raises:
    var s = _spec(SHAPE_AGG_MERGEABLE, "fixtures.mjs#count")
    s.state = ColumnType(TYPE_INT64, True)
    var b = _bind(rt, ctx, s)
    var partial = rt.agg_open(b.inst)
    var up = rt.agg_update(partial.handle, _ints([5, 6, 7]), [Int32(0), Int32(0), Int32(0)], 1, CallOptions.plain())
    assert_true(up.is_ok(), String(up))
    var st = rt.agg_state(partial.handle, 1, ColumnType(TYPE_INT64, True))
    assert_true(st.outcome.is_ok(), String(st.outcome))
    assert_equal(st.column.bits[0], 3, "count of three rows")
    rt.agg_close(partial.handle)
    var final = rt.agg_open(b.inst)
    var m = rt.agg_merge(final.handle, st.column, [Int32(0)], 1, CallOptions.plain())
    assert_true(m.is_ok(), String(m))
    var fin = rt.agg_finish(final.handle, 1, ColumnType(TYPE_INT64, True))
    assert_true(fin.outcome.is_ok(), String(fin.outcome))
    assert_equal(fin.column.bits[0], 3, "merge adds the state, update would count 1")
    rt.agg_close(final.handle)
    _unbind(rt, b)


def _validate(mut rt: UdfRuntime, ctx: Handle) raises:
    var table = _spec(SHAPE_SCALAR, "fixtures.mjs#double")
    table.result_is_table = True
    _expect(rt.validate(table), ERR_UNSUPPORTED, "returns one column, not a table", "a SCALAR returning a table")
    var stateless = _spec(SHAPE_AGG_MERGEABLE, "fixtures.mjs#sum")
    _expect(rt.validate(stateless), ERR_UNSUPPORTED, "AGG_MERGEABLE needs one state column", "no state")
    var twice = _spec(SHAPE_ROW, "fixtures.mjs#pick", 2)
    twice.arg_names = ["a", "a"]
    _expect(rt.validate(twice), ERR_UNSUPPORTED, "unique, non-empty field names", "ROW fields named twice")
    var agg_fn = _spec(SHAPE_AGG_MERGEABLE, "fixtures.mjs#double")
    agg_fn.state = ColumnType(TYPE_INT64, True)
    var u = rt.load(agg_fn)
    assert_true(u.outcome.is_ok(), String(u.outcome))
    var i = rt.open_instance(ctx, u.handle)
    _expect(i.outcome, ERR_LOAD, "is not an aggregate", "a function as a mergeable aggregate")
    rt.unload(u.handle)


def main() raises:
    arm_watchdog()
    var rt = UdfRuntime.open(LIB)
    var c = rt.open_context(0)
    assert_true(c.outcome.is_ok(), String(c.outcome))
    _return_types(rt, c.handle)
    _row_symbol(rt, c.handle)
    _frames(rt, c.handle)
    _merge(rt, c.handle)
    _validate(rt, c.handle)
    rt.close_context(c.handle)
    # cancels end in the worker's error, so each gets a fresh context
    var c2 = rt.open_context(1)
    _cancel_every_loop(rt, c2.handle)
    rt.close_context(c2.handle)
    var l = rt.ledger()
    assert_equal(l.exported, l.released, "arrays exported vs released")
    assert_equal(l.streams_exported, l.streams_released, "streams exported vs released")
    rt.shutdown()
    print("test_worker_edges: ok")
