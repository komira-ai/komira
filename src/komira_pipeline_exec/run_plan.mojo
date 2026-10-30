# =============================================================================
# run_plan -- the ready-set scheduler over the segments of a plan
# =============================================================================
#
# The plan is checked first (`check_plan`), so a plan the driver cannot run
# fails before any segment is built. The loop then repeats: take the ready set
# (every segment whose waited-for dependencies finished), start the lowest id in
# it, publish its output, mark it finished. The size of the ready set is what a
# concurrent form would exploit; this form starts one segment at a time, so
# the order is a function of the plan alone.
#
# A segment that raises ends the run: segments that have not started do not
# start, and the error is the one the failing segment recorded. The same holds
# when the caller's token is cancelled, checked before each segment.

from komira_async_api.parallel_dispatch import ParallelDispatch
from komira_async_api.token import CancellationToken
from komira_physical_plan.physical_plan import SegmentDescPod

from .plan_check import check_plan, ready_set
from .published_outputs import PublishedOutputs
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
    no dependent took, by segment id."""
    check_plan(descs)
    var n = len(descs)
    var published = PublishedOutputs(n)
    var finished = List[Bool](length=n, fill=False)
    var remaining = n
    while remaining > 0:
        if token.is_cancelled():
            raise cancelled_error(token)
        var ready = ready_set(descs, finished)
        if len(ready) == 0:
            raise Error(
                "komira_pipeline_exec: no segment is ready but "
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
    return published^
