# Both native libraries (the C library and the Mojo library) called through
# the native runtime, with every output compared whole. The conformance
# corpus checks a case's status and some of its outputs; this test pins what
# the corpus leaves open, the same way on both libraries.
#
# What it proves and the defect each part catches:
#   - frames: running_sum over nulls and two batches, group_max with two
#     groups completed in one batch and a group spanning batches,
#     yield_two_then_raise's exactly two outputs before its error, a step's
#     row count (3 and 0), endless's first output; each output whole (a
#     null summed, a running total reset, a completed group written to the
#     wrong row, an output lost or added before an error).
#   - frame refusals: a step given no literal batch or a literal of two rows,
#     a running_sum batch without its column, a group_max batch without its
#     value column, each refused by name with every input array released
#     (an error path that reads past the batch, or leaks it).
#   - mergeable aggregate: sums over three groups emitted in two steps
#     (emit_first_n), a group id equal to n_groups and one below zero,
#     values and group ids of different lengths, an argument batch without
#     columns, a cancelled update, emit_first_n above the group count, each
#     refused by name (a group id bound off by one; the groups after an
#     early emit kept wrong).
#   - shapes: call_batch on a frame UDF, frame_open on a scalar one and
#     agg_open on a scalar one, each ERR_UNSUPPORTED naming the entry, the
#     frame's input stream released (a library or the runtime running a UDF
#     through the wrong entry).
#   - a frame cancelled before frame_open is refused by frame_open itself,
#     before any pull ("cancelled before the batch"; a frame opened anyway
#     and cancelled at its first frame_next says "between batches").
#   - load: an entry the library does not have is refused by the library's
#     load, through the runtime, with no handle (a library's refusal turned
#     into a handle).
#   - args_kept: the host reports the args it still holds ("args not
#     moved"), not another fault first (the fixture's own output left off
#     the CPU).
# Mutants planted (the scorecard in the pull request lists each): the
# group-id bound `>=` made `>`, the running_sum null test dropped, the
# output index of a completed group made 0, yield_two's count made 1, the
# step's row bound `< 0` made `<= 0`, the frame_open shape and cancel
# checks dropped, the native runtime's load ignoring the library's refusal:
# each red here.

from std.os import getenv
from std.testing import assert_equal, assert_true

from komira_udf_spike_abi.contract import *
from komira_udf_spike_abi.runtime import CallOptions, CodeSet, FrameResult, Handle, Outcome, UdfRuntime, UdfSpec
from komira_udf_spike_abi.values import Batch, Column, ColumnType, TYPE_INT64

from komira_udf_spike_native.code import code_set


def _i64() -> List[ColumnType]:
    return [ColumnType(TYPE_INT64, True)]


def _spec(shape: UInt32, entry: String, code: CodeSet, table: Bool = False, state: Bool = False) -> UdfSpec:
    var s = UdfSpec(shape, entry, _i64(), _i64() if not (table and entry == "empty_table") else List[ColumnType]())
    s.result_is_table = table
    if state:
        s.state = ColumnType(TYPE_INT64, True)
    s.code_root = code.root
    s.code = code.objects.copy()
    return s^


def _col(values: List[Int], nulls: List[Int] = List[Int]()) -> Column:
    var c = Column(TYPE_INT64)
    for i in range(len(values)):
        if i in nulls:
            c.append_null()
        else:
            c.append_int(Int64(values[i]))
    return c^


def _batch(var cols: List[Column], length: Int) -> Batch:
    var b = Batch(length)
    for i in range(len(cols)):
        b.columns.append(cols[i].copy())
    return b^


def _outputs(outs: List[Batch]) -> String:
    var s = String()
    for i in range(len(outs)):
        if i > 0:
            s += " "
        s += String(outs[i])
    return s^


def _status(got: Outcome, status: Int32, words: String, what: String) raises:
    assert_equal(status_name(got.status), status_name(status), what + ": " + String(got))
    assert_true(words in got.message, what + ": message '" + got.message + "' lacks '" + words + "'")


struct _Lib(Movable):
    """One library behind the native runtime, and one context."""

    var rt: UdfRuntime
    var ctx: Handle
    var code: CodeSet
    var name: String

    def __init__(out self, path: String, root: String) raises:
        self.rt = UdfRuntime.open("./native.so")
        self.code = code_set(path, root)
        var c = self.rt.open_context(0)
        assert_true(c.outcome.is_ok(), path + ": open_context: " + String(c.outcome))
        self.ctx = c.handle.copy()
        self.name = path

    def frame(mut self, inst: Handle, spec: UdfSpec, inputs: List[Batch], opts: CallOptions) raises -> FrameResult:
        """run_frame, which must leave the library's reserved bytes as they
        were (a scratch block or frame not freed, on any path)."""
        var before = self.rt.reserved_bytes()
        var r = self.rt.run_frame(inst, spec, inputs, opts)
        assert_equal(self.rt.reserved_bytes(), before, self.name + ": " + spec.entry + ": a frame kept library memory")
        return r^

    def update(mut self, g: Handle, args: Batch, gids: List[Int32], n: UInt32, opts: CallOptions) raises -> Outcome:
        """agg_update, which must leave the library's reserved bytes as they
        were."""
        var before = self.rt.reserved_bytes()
        var r = self.rt.agg_update(g, args, gids, n, opts)
        assert_equal(self.rt.reserved_bytes(), before, self.name + ": agg_update kept library memory")
        return r^

    def instance(mut self, spec: UdfSpec) raises -> Handle:
        var u = self.rt.load(spec)
        assert_true(u.outcome.is_ok(), self.name + ": load " + spec.entry + ": " + String(u.outcome))
        var i = self.rt.open_instance(self.ctx, u.handle)
        assert_true(i.outcome.is_ok(), self.name + ": open_instance " + spec.entry + ": " + String(i.outcome))
        return i.handle.copy()


def _frames(mut lib: _Lib) raises:
    var n = lib.name
    var rs = _spec(SHAPE_MAP_BATCHES_FRAME, "running_sum", lib.code, True)
    var i_rs = lib.instance(rs)
    var r = lib.frame(i_rs, rs, [_batch([_col([1, 9, 2], [1])], 3), _batch([_col([3, 4])], 2)], CallOptions.plain())
    assert_true(r.outcome.is_ok(), n + ": running_sum: " + String(r.outcome))
    assert_equal(_outputs(r.outputs), "{3 rows; int64[1, null, 3]} {2 rows; int64[6, 10]}", n + ": running_sum")

    var gm = _spec(SHAPE_AGG_PLAIN, "group_max", lib.code)
    var i_gm = lib.instance(gm)
    var g = lib.frame(
        i_gm,
        gm,
        [_batch([_col([0, 1, 1, 2]), _col([5, 3, 8, 1])], 4), _batch([_col([2]), _col([7])], 1)],
        CallOptions.plain(),
    )
    assert_true(g.outcome.is_ok(), n + ": group_max: " + String(g.outcome))
    assert_equal(_outputs(g.outputs), "{2 rows; int64[5, 8]} {1 rows; int64[7]}", n + ": group_max")
    # Group 0's values all below zero (its maximum is no default), and no input at all.
    var neg = lib.frame(i_gm, gm, [_batch([_col([0, 0]), _col([-5, -3])], 2)], CallOptions.plain())
    assert_equal(_outputs(neg.outputs), "{1 rows; int64[-3]}", n + ": group_max of negative values: " + String(neg.outcome))
    var empty = lib.frame(i_gm, gm, List[Batch](), CallOptions.plain())
    assert_true(empty.outcome.is_ok(), n + ": group_max of no input: " + String(empty.outcome))
    assert_equal(_outputs(empty.outputs), "", n + ": group_max of no input")

    var y = _spec(SHAPE_MAP_BATCHES_FRAME, "yield_two_then_raise", lib.code, True)
    var i_y = lib.instance(y)
    var yr = lib.frame(i_y, y, [_batch([_col([1])], 1), _batch([_col([2])], 1), _batch([_col([3])], 1)], CallOptions.plain())
    _status(yr.outcome, ERR_RAISED, "after two outputs", n + ": yield_two_then_raise")
    assert_equal(_outputs(yr.outputs), "{1 rows; int64[1]} {1 rows; int64[2]}", n + ": yield_two_then_raise outputs")

    var st = _spec(SHAPE_STEP, "empty_table", lib.code, True)
    var i_st = lib.instance(st)
    for rows in [3, 0]:
        var sr = lib.frame(i_st, st, [_batch([_col([rows])], 1)], CallOptions.plain())
        assert_true(sr.outcome.is_ok(), n + ": step of " + String(rows) + " rows: " + String(sr.outcome))
        assert_equal(_outputs(sr.outputs), "{" + String(rows) + " rows}", n + ": step")
    _status(lib.frame(i_st, st, List[Batch](), CallOptions.plain()).outcome, ERR_INTERNAL, "no literal batch", n + ": step, no batch")
    _status(
        lib.frame(i_st, st, [_batch([_col([3, 4])], 2)], CallOptions.plain()).outcome,
        ERR_INTERNAL,
        "not one int64 row",
        n + ": step, two rows",
    )
    _status(
        lib.frame(i_st, st, [_batch([_col([-1])], 1)], CallOptions.plain()).outcome,
        ERR_INTERNAL,
        "not one int64 row",
        n + ": step, -1 rows",
    )

    var en = _spec(SHAPE_MAP_BATCHES_FRAME, "endless", lib.code, True)
    var i_en = lib.instance(en)
    var er = lib.frame(i_en, en, [_batch([_col([1])], 1)], CallOptions.plain())
    assert_true(len(er.outputs) > 0, n + ": endless: no output: " + String(er.outcome))
    assert_equal(String(er.outputs[0]), "{1 rows; int64[0]}", n + ": endless's first output")

    # Batches without the columns a fixture reads: refused, every input released.
    var before = lib.rt.ledger()
    _status(
        lib.frame(i_rs, rs, [Batch(2)], CallOptions.plain()).outcome,
        ERR_INTERNAL,
        "running_sum: no input column",
        n + ": running_sum, a batch without columns",
    )
    for rows in [2, 1]:
        var ids: List[Int] = [0]
        if rows == 2:
            ids.append(1)
        _status(
            lib.frame(i_gm, gm, [_batch([_col(ids)], rows)], CallOptions.plain()).outcome,
            ERR_INTERNAL,
            "without its group and value columns",
            n + ": group_max, a batch of " + String(rows) + " rows without its value column",
        )
    var after = lib.rt.ledger()
    assert_equal(after.released - before.released, after.exported - before.exported, n + ": an input array not released")

    # Cancelled before the frame opens: frame_open refuses it, before any pull.
    var c = lib.frame(i_rs, rs, [_batch([_col([1])], 1)], CallOptions(True, False, False))
    _status(c.outcome, ERR_CANCELLED, "cancelled before the batch", n + ": a frame cancelled before frame_open")
    assert_equal(c.pulls, 0, n + ": a cancelled frame pulled input")


def _aggregate(mut lib: _Lib) raises:
    var n = lib.name
    var sum = _spec(SHAPE_AGG_MERGEABLE, "sum", lib.code, False, True)
    var i_sum = lib.instance(sum)
    var g = lib.rt.agg_open(i_sum)
    assert_true(g.outcome.is_ok(), n + ": agg_open: " + String(g.outcome))
    var three = _batch([_col([1, 2, 3, 4], [3])], 4)
    var ok = lib.update(g.handle, three, [0, 2, 0, 1], 3, CallOptions.plain())
    assert_true(ok.is_ok(), n + ": agg_update: " + String(ok))
    var first = lib.rt.agg_state(g.handle, 2, ColumnType(TYPE_INT64, True))
    assert_equal(String(first.column), "int64[4, 0]", n + ": the first two groups' states: " + String(first.outcome))
    var rest = lib.rt.agg_finish(g.handle, 1, ColumnType(TYPE_INT64, True))
    assert_equal(String(rest.column), "int64[2]", n + ": the group after them: " + String(rest.outcome))
    _status(
        lib.rt.agg_finish(g.handle, 1, ColumnType(TYPE_INT64, True)).outcome,
        ERR_INTERNAL,
        "above the group count",
        n + ": emit after every group was emitted",
    )
    var before = lib.rt.ledger()
    _status(
        lib.update(g.handle, _batch([_col([1])], 1), [2], 2, CallOptions.plain()),
        ERR_INTERNAL,
        "not below n_groups",
        n + ": a group id equal to n_groups",
    )
    _status(
        lib.update(g.handle, _batch([_col([1])], 1), [-1], 2, CallOptions.plain()),
        ERR_INTERNAL,
        "not below n_groups",
        n + ": a group id below zero",
    )
    _status(
        lib.update(g.handle, _batch([_col([1, 2])], 2), [0], 2, CallOptions.plain()),
        ERR_INTERNAL,
        "differ in length",
        n + ": values and group ids of different lengths",
    )
    _status(
        lib.update(g.handle, Batch(1), [0], 2, CallOptions.plain()),
        ERR_INTERNAL,
        "differ in length",
        n + ": an argument batch without columns",
    )
    _status(
        lib.update(g.handle, _batch([_col([1])], 1), [0], 2, CallOptions(True, False, False)),
        ERR_CANCELLED,
        "cancelled before the batch",
        n + ": a cancelled agg_update",
    )
    var after = lib.rt.ledger()
    assert_equal(after.released - before.released, after.exported - before.exported, n + ": an input array not released")
    lib.rt.agg_close(g.handle)
    # sum_args_kept keeps the host's args (the fixture's planted fault): the
    # host reports it, and the library's view of them is freed.
    var kept = _spec(SHAPE_AGG_MERGEABLE, "sum_args_kept", lib.code, False, True)
    var i_kept = lib.instance(kept)
    var gk = lib.rt.agg_open(i_kept)
    var fault = lib.update(gk.handle, _batch([_col([1])], 1), [0], 1, CallOptions.plain())
    assert_true("an input not moved by agg_update" in fault.fault, n + ": sum_args_kept: " + String(fault))
    lib.rt.agg_close(gk.handle)


def _shapes(mut lib: _Lib) raises:
    var n = lib.name
    var rs = _spec(SHAPE_MAP_BATCHES_FRAME, "running_sum", lib.code, True)
    var i_rs = lib.instance(rs)
    var b = _batch([_col([1])], 1)
    _status(lib.rt.call_batch(i_rs, rs, b, CallOptions.plain()).outcome, ERR_UNSUPPORTED, "call_batch on a fixture of another shape", n)
    var d = _spec(SHAPE_SCALAR, "double", lib.code)
    var i_d = lib.instance(d)
    var before = lib.rt.ledger()
    var fr = lib.frame(i_d, d, [b.copy()], CallOptions.plain())
    _status(fr.outcome, ERR_UNSUPPORTED, "frame_open on a fixture of another shape", n)
    var after = lib.rt.ledger()
    assert_equal(after.streams_released - before.streams_released, 1, n + ": the refused frame's stream was not released")
    var g = lib.rt.agg_open(i_d)
    _status(g.outcome, ERR_UNSUPPORTED, "agg_open on a fixture of another shape", n)
    var kept = _spec(SHAPE_SCALAR, "args_kept", lib.code)
    var i_k = lib.instance(kept)
    var k = lib.rt.call_batch(i_k, kept, b, CallOptions.plain())
    assert_true("args not moved" in k.outcome.fault, n + ": args_kept: " + String(k.outcome))
    var none = lib.rt.load(_spec(SHAPE_SCALAR, "no_such_entry", lib.code))
    _status(none.outcome, ERR_DESCRIPTOR, "no fixture has this entry", n + ": load of an entry the library lacks")


def main() raises:
    var tmp = getenv("TMPDIR")
    for path in ["./native_c.so", "./native_mojo.so"]:
        var lib = _Lib(path, tmp + "/calls")
        _frames(lib)
        _aggregate(lib)
        _shapes(lib)
        lib.rt.shutdown()
    print("test_library_calls: ok")
