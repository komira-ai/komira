# =============================================================================
# run_plan -- the ready-set scheduler over the segments of a plan
# =============================================================================
#
# The plan is checked first (`check_plan`), so a plan the driver cannot run
# fails before any segment is built. The loop then repeats: take the ready set
# (every segment whose waited-for dependencies finished), start the lowest id in
# it, publish its output, mark it finished. The size of the ready set is what a
# concurrent form would exploit; this form starts one segment at a time, so
# the order is a function of the plan alone. The published outputs count each
# segment's readers from the plan, so a segment read by several others hands
# each of them the same rows (`PublishedOutputs`).
#
# A segment that raises ends the run: segments that have not started do not
# start, and the error is the one the failing segment recorded. The same holds
# when the caller's token is cancelled, checked before each segment.
#
# Progress. The form that takes a `RunProgress` adds the plan's segment count
# to its total once the plan is checked, and one to its done count after each
# segment finishes, so a reader on another thread sees how far the run is; a
# plan refused by `check_plan` adds nothing. A cancelled or failed run leaves
# done below total.

from async_api.parallel_dispatch import ParallelDispatch
from async_api.token import CancellationToken
from physical_plan.physical_plan import SegmentDescPod

from .plan_check import check_plan, ready_set
from .published_outputs import PublishedOutputs
from .run_progress import RunProgress
from .run_segment import cancelled_error, run_segment
from .segment_builder import SegmentBuilder


def run_plan[
    B: SegmentBuilder, D: ParallelDispatch
](
    ref descs: List[SegmentDescPod],
    mut builder: B,
    mut dispatch: D,
    num_workers: Int,
    ref token: CancellationToken,
) raises -> PublishedOutputs:
    """Run every segment of `descs` in dependency order and return the outputs
    no dependent took, by segment id. Counts into no progress counter."""
    return run_plan(descs, builder, dispatch, num_workers, token, RunProgress())


def run_plan[
    B: SegmentBuilder, D: ParallelDispatch
](
    ref descs: List[SegmentDescPod],
    mut builder: B,
    mut dispatch: D,
    num_workers: Int,
    ref token: CancellationToken,
    progress: RunProgress,
) raises -> PublishedOutputs:
    """Run every segment of `descs` in dependency order and return the outputs
    no dependent took, by segment id. `progress` counts the plan's segments
    once it is checked, and each segment as it finishes."""
    check_plan(descs)
    var n = len(descs)
    progress.start(n)
    var published = PublishedOutputs(descs)
    var finished = List[Bool](length=n, fill=False)
    var remaining = n
    while remaining > 0:
        if token.is_cancelled():
            raise cancelled_error(token)
        var ready = ready_set(descs, finished)
        if len(ready) == 0:
            raise Error(
                "pipeline_exec: no segment is ready but "
                + String(remaining)
                + " have not finished"
            )
        var next = ready[0]
        var out = run_segment(
            builder, dispatch, descs[next], published, num_workers, token
        )
        published.publish(next, out^)
        finished[next] = True
        remaining -= 1
        progress.finish_segment()
    return published^
