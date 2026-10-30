# =============================================================================
# run_segment -- build, size, run, combine, finalize and take one segment
# =============================================================================
#
#   1. Build: the builder constructs the source, one operator chain per worker
#      and the sink from the segment's descriptor.
#   2. Size: `sink.resize_worker_state(num_workers)`, once, before any consume.
#   3. Run: the dispatcher runs a `SegmentTask` once per worker
#      (`run_with_state`), and the segment's workers share one `SegmentRun`.
#   4. After the join, a recorded error is raised; so is a cancellation by the
#      caller. A failed or cancelled segment never combines, finalizes or takes
#      output, and its sink, operators and source are dropped by ownership.
#   5. Combine runs once on the calling thread, then finalize, then the output
#      is taken.

from komira_arrow.schema import RecordBatch
from komira_async_api.parallel_dispatch import ParallelDispatch
from komira_async_api.token import CancellationToken
from komira_phase_timers.phase_timers import (
    PH_COMBINE,
    PH_DISPATCH,
    PH_SEG_OPS_SINK,
    PH_SEG_SOURCE,
    pt_mark_fork,
    pt_now,
    pt_record,
    pt_record_join_tails,
)
from komira_physical_plan.physical_plan import SegmentDescPod

from .published_outputs import PublishedOutputs
from .segment_builder import SegmentBuilder
from .segment_task import SegmentRun, SegmentTask

comptime MAX_INT: Int = 0x7FFFFFFFFFFFFFFF


def cancelled_error(token: CancellationToken) -> Error:
    """The error a cancelled query returns, with the token's reason."""
    var reason = token.reason()
    if reason.byte_length() == 0:
        return Error("komira_pipeline_exec: the query was cancelled")
    return Error("komira_pipeline_exec: the query was cancelled: " + reason)


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
            "komira_pipeline_exec: a segment needs at least one worker, got "
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
            "komira_pipeline_exec: "
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
    var sink = builder.build_sink(desc, source.output_schema())

    var run = SegmentRun[B.Source, B.Op, B.Sink](
        source^, ops^, sink^, num_workers, n_ops, token.clone()
    )
    run.sink.resize_worker_state(num_workers)
    pt_record[PH_SEG_OPS_SINK](t_ops)

    pt_mark_fork()
    var t_dispatch = pt_now()
    _ = dispatch.run_with_state[
        SegmentRun[B.Source, B.Op, B.Sink],
        SegmentTask[B.Source, B.Op, B.Sink],
    ](run, SegmentTask[B.Source, B.Op, B.Sink](), num_workers, token.clone())
    pt_record[PH_DISPATCH](t_dispatch)
    pt_record_join_tails()

    var err = run.pipeline.take_error()
    if err:
        raise err.take().to_error()
    # A cancel that lands after every worker finished normally still fails the
    # run: the caller asked to stop, so a finished result is not returned.
    if run.token.is_cancelled():
        raise cancelled_error(run.token)
    if run.pipeline.is_cancelled():
        raise Error(
            "komira_pipeline_exec: the segment stopped without a recorded error"
        )

    var t_combine = pt_now()
    run.sink.combine(run.pipeline)
    run.sink.finalize()
    var output = run.sink.take_output()
    pt_record[PH_COMBINE](t_combine)
    return output^
