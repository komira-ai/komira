# =============================================================================
# FFI-BOUNDARY: nested calls while a frame waits on its input.
# =============================================================================
# The one nesting design section 4.3 allows: while a frame_next waits on its
# `in` pull, the host calls into the same context to produce that input (a
# scalar UDF upstream, or another frame of the same instance), and those
# calls complete before the pull returns. The pulls are answered by the C
# producers of native/producer.c; this file starts them, drives the waiting
# frame, closes what it opened only after the waiting frame_next returned
# (innermost frame first), and reports the run's error: the pipeline's first
# failure (a nested call's, or the run's cancel), and the waiting frame's own
# status only when nothing failed upstream (the host ignores the waiting
# call's status but to learn of a loss).
#
# Who owns and frees each pointer:
#   - the pipe and the producers: malloc'd by native/producer.c, freed here
#     (komira_udf_spike_pipe_free, _producer_free) after every frame is closed.
#   - the stream structs and nested call structs: arena blocks of the
#     UdfRuntime, filled by native/producer.c; each stream is moved to the
#     runtime by frame_open, which releases it.
#   - the prepared input batches: exported arrays of the UdfRuntime's arena,
#     moved to the runtime by the nested call or the pull, or released by
#     the stream's release when never handed out.
#   - the frames: the runtime's handles, closed here once each.
# =============================================================================

from std.ffi import external_call
from std.sys import size_of

from ._cabi import CArrowDeviceArrayStream, CUdfCall, Void, Word, read_cstr
from ._host import (
    array_released,
    clock_of,
    device_struct,
    host_data_of,
    import_column,
    import_struct,
    new_error,
    release_out,
    release_stream,
    stream_moved,
)
from ._table import cancel_value, slot_value, t_frame_close, t_frame_next, t_frame_open, word_array
from .contract import ERR_INSTANCE_LOST, OK
from .runtime import UdfRuntime
from .spec import CallOptions, Handle, KIND_INSTANCE, Outcome, UdfSpec, _MAX_FRAME_OUTPUTS
from .values import Batch

comptime KP_BATCHES = 0
comptime KP_SCALAR = 1
comptime KP_FRAME = 2

comptime PULL_NONE = 0
comptime PULL_CANCEL_EIO = 1
"""The run is cancelled while the pull is held: the waiting call's flag is
set and the pull returns EIO."""
comptime PULL_CANCEL_KEEP = 2
"""The flag is set while the pull is held, and the batch handed out."""
comptime PULL_ADVANCE_CLOCK = 3
"""The host's virtual clock passes the waiting call's deadline while the
pull is held, and the batch is handed out."""


@fieldwise_init
struct NestedResult(Copyable, Movable):
    """The run's outcome (the pipeline's first failure, else the waiting
    frame's), the waiting frame's own outcome, its outputs, and counts: the
    nested calls made, the EIOs returned to pulls, the outer frame's pulls,
    and whether every producer stream was released."""

    var outcome: Outcome
    var frame_outcome: Outcome
    var outputs: List[Batch]
    var nested_calls: Int
    var eio: Int
    var pulls: Int
    var streams_released: Bool


def _pipe_new(first_id: Int64) -> Void:
    return external_call["komira_udf_spike_pipe_new", Void](first_id)


def _pipe_value(pipe: Void, what: Int) -> Int64:
    return external_call["komira_udf_spike_pipe_value", Int64](pipe, Int64(what))


def _producer(
    pipe: Void, stream: Word, kind: Int, t: Word, target: Word, outer: Word, batches: Word, n: Int,
    action_at: Int, action: Int, clock: Word,
) -> Void:
    # SAFETY: every Word is a live block of the harness (stream, outer call,
    # batches, clock) or the runtime (table, target handle); the producer
    # keeps them until it is freed, after the frames are closed.
    return external_call["komira_udf_spike_producer_new", Void](
        pipe, stream.p, Int64(kind), t.p, target.p, outer.p, Int64(n), batches.p, Int64(action_at),
        Int64(action), clock.p,
    )


def run_nested_frame(
    mut rt: UdfRuntime,
    f_inst: Handle,
    f_spec: UdfSpec,
    s_inst: Handle,
    inputs: List[Batch],
    levels: Int,
    action_at: Int,
    action: Int,
    opts: CallOptions,
) raises -> NestedResult:
    """A frame of `f_inst` whose pulls are answered on its own context:
    `levels` 0 hands out `inputs`; 1 calls call_batch on `s_inst` with each
    of `inputs`; 2 does that under a second frame of `f_inst`, whose
    frame_next answers the outer frame's pulls. `action` is planted at pull
    `action_at` of the outer frame (PULL_*)."""
    if f_inst.kind != KIND_INSTANCE or (levels > 0 and s_inst.kind != KIND_INSTANCE):
        raise Error("UDF_HARNESS_HANDLE_KIND: run_nested_frame takes instances")
    rt._live(f_inst, "frame_open")
    if levels > 0:
        rt._live(s_inst, "call_batch")
    var hd = host_data_of(rt._host)
    var prepared = List[Word]()
    for i in range(len(inputs)):
        prepared.append(device_struct(rt._arena, inputs[i], hd))
    var arr = word_array(rt._arena, prepared)
    var c = rt._begin(opts)
    var pipe = _pipe_new(rt._calls + 1)
    var producers = List[Void]()
    var streams = List[Word]()
    var inner = Word.null()
    var inner_out = Outcome.of(OK)
    var outer_kind = KP_BATCHES if levels == 0 else KP_SCALAR
    var target = s_inst._w
    if levels == 2:
        # The inner frame: opened first, on the same instance, its pulls
        # answered by nested call_batch calls; the outer frame pulls it.
        var s2 = rt._arena.word(size_of[CArrowDeviceArrayStream]())
        producers.append(_producer(pipe, s2, KP_SCALAR, rt._table, s_inst._w, c.call, arr, len(inputs), -1, 0, clock_of(hd)))
        streams.append(s2)
        var call2 = rt._arena.word(size_of[CUdfCall]())
        external_call["komira_udf_spike_pipe_call", NoneType](pipe, c.call.p, call2.p)
        var e2 = new_error(rt._arena)
        var slot2 = rt._arena.word(8)
        var rc2 = t_frame_open(rt._table, f_inst._w, call2, s2, slot2, e2)
        inner_out = rt._outcome(rc2, e2)
        if rc2 == OK:
            inner = slot_value(slot2)
        outer_kind = KP_FRAME
        target = inner
    var s1 = rt._arena.word(size_of[CArrowDeviceArrayStream]())
    var n1 = len(inputs) if levels < 2 else 0
    producers.append(_producer(pipe, s1, outer_kind, rt._table, target, c.call, arr, n1, action_at, action, clock_of(hd)))
    streams.append(s1)
    var err = new_error(rt._arena)
    var slot = rt._arena.word(8)
    var outputs = List[Batch]()
    var out: Outcome
    if levels == 2 and inner.is_null():
        # The inner frame did not open: the outer one is not opened either.
        out = inner_out.copy()
        release_stream(s1)
    else:
        var rc = t_frame_open(rt._table, f_inst._w, c.call, s1, slot, err)
        out = rt._outcome(rc, err)
        if rc == OK:
            var frame = slot_value(slot)
            var ended = False
            for _ in range(_MAX_FRAME_OUTPUTS + 1):
                var d_out = rt._arena.word(128)
                var e = new_error(rt._arena)
                var rcn = t_frame_next(rt._table, frame, c.call, d_out, e)
                var got = rt._outcome(rcn, e)
                if rcn != OK:
                    ended = True
                    out = got^
                    if not array_released(d_out):
                        _ = release_out(d_out)
                        out.fault = "UDF_RUNTIME_FAULT: out set on failure"
                    break
                if array_released(d_out):
                    ended = True
                    break
                try:
                    if f_spec.result_is_table:
                        outputs.append(import_struct(d_out, f_spec.result))
                    else:
                        var col = import_column(d_out, f_spec.result[0])
                        var b = Batch(len(col))
                        b.columns.append(col^)
                        outputs.append(b^)
                except ex:
                    out.fault = String(ex)
                if not release_out(d_out) and out.fault == "":
                    out.fault = "UDF_RUNTIME_FAULT: release left its slot set"
                if out.fault != "":
                    ended = True
                    break
            if not ended:
                out.fault = "UDF_RUNTIME_FAULT: frame_next did not end after " + String(len(outputs)) + " outputs"
            # Nothing on the context is closed until the waiting call
            # returned; then frames innermost first.
            if not inner.is_null():
                t_frame_close(rt._table, inner)
            t_frame_close(rt._table, frame)
        elif not inner.is_null():
            t_frame_close(rt._table, inner)
    for i in range(len(streams)):
        if not stream_moved(streams[i]):
            release_stream(streams[i])
    rt._end(c)
    out.shape = f_spec.shape
    out.cancel_was_set = cancel_value(c.call)
    var failed = Int32(_pipe_value(pipe, 0))
    var run = out.copy()
    if failed != OK:
        run = Outcome(
            failed,
            read_cstr(external_call["komira_udf_spike_pipe_message", Void](pipe)),
            "",
            _pipe_value(pipe, 1),
            -1,
            "",
            0,
            cancel_value(c.call),
        )
    var released = True
    var pulls = 0
    for i in range(len(producers)):
        if external_call["komira_udf_spike_producer_value", Int64](producers[i], Int64(1)) != 1:
            released = False
        if i == len(producers) - 1:
            pulls = Int(external_call["komira_udf_spike_producer_value", Int64](producers[i], Int64(0)))
        external_call["komira_udf_spike_producer_free", NoneType](producers[i])
    var nested = Int(_pipe_value(pipe, 3))
    var eio = Int(_pipe_value(pipe, 4))
    var lost = _pipe_value(pipe, 2) != 0
    rt._calls = _pipe_value(pipe, 5) - 1
    external_call["komira_udf_spike_pipe_free", NoneType](pipe)
    # The waiting frame's status is read for one thing: whether it lost the
    # context. A nested status that lost it does too.
    rt._note(f_inst, Outcome.of(ERR_INSTANCE_LOST) if lost else out.copy())
    return NestedResult(run^, out^, outputs^, nested, eio, pulls, released)
