# =============================================================================
# run_segment -- build, size, run, combine, finalize and take one segment
# =============================================================================
#
#   1. Build: the builder constructs the source, one operator chain per worker
#      and the sink from the segment's descriptor.
#   2. Size: `sink.resize_worker_state(num_workers)`, once, before any consume.
#   3. Run: the dispatcher runs a `SegmentTask` once per worker
#      (`run_with_state`), and the segment's workers share one `SegmentRun`.
#   4. After the join, a recorded error is raised, also when the dispatcher
#      raised (it does when it sees the token cancelled between tasks); a
#      cancel the dispatcher raised is reported as the segment's
#      cancellation. A failed segment pushes no tail, and never combines,
#      finalizes or takes output; its sink, operators and source are dropped
#      by ownership.
#   5. Tails: for each operator, in chain order, the builder's `op_tail`
#      gives the rows it owes after every worker finished (the build rows a
#      RIGHT or FULL join matched to no probe row). Each batch is pushed, on
#      the calling thread, through the operators after that one and into the
#      sink as worker 0, as a morsel at a position after every source
#      position (`TAIL_PARTITION_BASE` plus the operator's index, and the
#      batch's index), so a sink that orders by position puts it last. An
#      operator after it that reports FINISHED (a spent limit) ends that
#      operator's tail; the tails of operators after the limit still run.
#      A cancellation by the caller, before or during the tails, is raised
#      after them, and the segment never combines.
#   6. Combine runs once on the calling thread, then finalize, then the output
#      is taken.

from arrow.schema import RecordBatch, Schema
from morsel.morsel import Morsel
from async_api.parallel_dispatch import ParallelDispatch
from async_api.token import CancellationToken
from phase_timers.phase_timers import (
    PH_COMBINE,
    PH_DISPATCH,
    PH_SEG_OPS_SINK,
    PH_SEG_SOURCE,
    pt_mark_fork,
    pt_now,
    pt_record,
    pt_record_join_tails,
)
from physical_plan.physical_plan import SegmentDescPod

from .published_outputs import PublishedOutputs
from .segment_builder import SegmentBuilder
from .segment_task import SegmentRun, SegmentTask, _push

comptime MAX_INT: Int = 0x7FFFFFFFFFFFFFFF

comptime TAIL_PARTITION_BASE: Int = 1 << 62
"""The partition id of the first operator's tail morsels: after every
position a source gives (see step 5 of the header)."""


def cancelled_error(token: CancellationToken) -> Error:
    """The error a cancelled query returns, with the token's reason."""
    var reason = token.reason()
    if reason.byte_length() == 0:
        return Error("pipeline_exec: the query was cancelled")
    return Error("pipeline_exec: the query was cancelled: " + reason)


def run_segment[
    B: SegmentBuilder, D: ParallelDispatch
](
    mut builder: B,
    mut dispatch: D,
    ref desc: SegmentDescPod,
    mut published: PublishedOutputs,
    num_workers: Int,
    ref token: CancellationToken,
) raises -> RecordBatch:
    """Run the segment `desc` on `num_workers` workers of `dispatch` and return
    its output batch. Raises the first error a worker recorded, or the
    cancellation of `token`, and in either case produces no output."""
    if num_workers < 1:
        raise Error(
            "pipeline_exec: a segment needs at least one worker, got "
            + String(num_workers)
        )
    if token.is_cancelled():
        raise cancelled_error(token)

    var n_ops = builder.op_count(desc)
    var t_source = pt_now()
    var source = builder.build_source(desc, published, num_workers)
    pt_record[PH_SEG_SOURCE](t_source)
    if n_ops > 0 and num_workers > MAX_INT // n_ops:
        raise Error(
            "pipeline_exec: "
            + String(num_workers)
            + " workers of a chain of "
            + String(n_ops)
            + " operators overflow the operator store"
        )
    var t_ops = pt_now()
    var ops = List[B.Op](capacity=num_workers * n_ops)
    for w in range(num_workers):
        for i in range(n_ops):
            ops.append(builder.build_op(desc, i, w))
    var source_schema = source.output_schema().copy()
    var sink = builder.build_sink(desc, source_schema)

    var run = SegmentRun[B.Source, B.Op, B.Sink](
        source^, ops^, sink^, num_workers, n_ops, token.clone()
    )
    run.sink.resize_worker_state(num_workers)
    pt_record[PH_SEG_OPS_SINK](t_ops)

    pt_mark_fork()
    var t_dispatch = pt_now()
    try:
        _ = dispatch.run_with_state[
            SegmentRun[B.Source, B.Op, B.Sink],
            SegmentTask[B.Source, B.Op, B.Sink],
        ](
            run,
            SegmentTask[B.Source, B.Op, B.Sink](),
            num_workers,
            token.clone(),
        )
    except e:
        # A dispatcher that sees the token cancelled between tasks raises its
        # own error; the segment reports the worker's first error, or the
        # cancellation, the same way whichever side saw it first.
        var first = run.pipeline.take_error()
        if first:
            raise first.take().to_error()
        if run.token.is_cancelled():
            raise cancelled_error(run.token)
        raise e^
    pt_record[PH_DISPATCH](t_dispatch)
    pt_record_join_tails()

    var err = run.pipeline.take_error()
    if err:
        raise err.take().to_error()
    if run.pipeline.is_cancelled():
        raise Error(
            "pipeline_exec: the segment stopped without a recorded error"
        )

    _push_tails(builder, desc, run, source_schema)
    # A cancel that lands after every worker finished normally, or while the
    # tails were pushed, still fails the run: the caller asked to stop, so a
    # finished result is not returned.
    if run.token.is_cancelled():
        raise cancelled_error(run.token)

    var t_combine = pt_now()
    run.sink.combine(run.pipeline)
    run.sink.finalize()
    var output = run.sink.take_output()
    pt_record[PH_COMBINE](t_combine)
    return output^


def _push_tails[
    B: SegmentBuilder
](
    mut builder: B,
    ref desc: SegmentDescPod,
    mut run: SegmentRun[B.Source, B.Op, B.Sink],
    ref source_schema: Schema,
) raises:
    """Step 5 of the header: push each operator's tail through the operators
    after it and into the sink, as worker 0. A push that reports the worker
    must stop (a FINISHED operator after this one, or a cancel the caller then
    raises) ends this operator's tail; the next operator's tail is still
    pushed, since it enters the chain after the operator that finished."""
    for i in range(run.n_ops):
        var tail = builder.op_tail(desc, i, source_schema)
        var c = 0
        while len(tail) > 0:
            var m = Morsel(tail.pop(0), 0, TAIL_PARTITION_BASE + i, c)
            if _push(run, 0, i + 1, m^):
                break
            c += 1
