# =============================================================================
# engine_execute -- run a lowered plan on the context's workers
# =============================================================================
#
# One `RealBuilder` per run: it borrows a metadata cache and an expression pool
# that live as long as the run, so nothing a run read outlives it (the scan
# reads through `komira_parquet`'s metadata cache, which is new for every run,
# so a later query never sees an earlier run's footer; within a run the scan
# reads the footer a second time and nothing checks it against the footer
# lowering read: komira#2024). The
# builder's segment pool is sized from the host profile's memory budget.

from komira_arrow.schema import RecordBatch
from komira_async_api.token import CancellationToken
from komira_lowering.lowered_plan import LoweredPlan
from komira_parquet.runtime_footer_cache import ParquetMetadataCache
from komira_physical_plan.physical_plan import AggSinkData
from komira_pipeline_exec.real_builder import RealBuilder
from komira_pipeline_exec.run_plan import run_plan
from komira_plan_expr.expr_pool import ExprPool

from .engine_context import EngineContext

comptime EXECUTE_UNSUPPORTED_PARAM = "EXECUTE_UNSUPPORTED_PARAM"
"""Refusal: the lowered plan carries a parameter kind this door does not run."""


comptime EXECUTE_POOL_NOT_RELEASED = "EXECUTE_POOL_NOT_RELEASED"
"""Refusal: a run ended with the segment pool not whole (a sink kept its
reservation)."""


def run_lowered_plan(
    mut ctx: EngineContext, var lowered: LoweredPlan
) raises -> RecordBatch:
    """Run `lowered` on `ctx.runtime` with `ctx.host_profile.thread_count`
    workers and return the result segment's batch.

    Raises:
        Error starting with `EXECUTE_UNSUPPORTED_PARAM` for a plan that scans
        an in-memory batch, `EXECUTE_POOL_NOT_RELEASED` when a run leaves bytes granted,
        and the driver's or a member's error otherwise.
    """
    if len(lowered.params.batches) > 0:
        raise Error(
            String(EXECUTE_UNSUPPORTED_PARAM)
            + ": the plan scans an in-memory batch; this door runs Parquet"
            " scans only"
        )
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var placeholder = 0
    var builder = RealBuilder[
        origin_of(cache), origin_of(pool), origin_of(placeholder)
    ](cache, pool)
    builder.set_memory_budget(ctx.host_profile.memory_budget_bytes)
    # The descriptors index the sink data by position, and `pop` takes from the
    # end: reverse once, then add in the plan's order.
    var reversed_sinks = List[AggSinkData]()
    while len(lowered.params.agg) > 0:
        reversed_sinks.append(lowered.params.agg.pop())
    while len(reversed_sinks) > 0:
        _ = builder.add_agg_sink(reversed_sinks.pop())
    var token = CancellationToken.new()
    ref dispatch = ctx.runtime.dispatcher()
    var out = run_plan(
        lowered.segments,
        builder,
        dispatch,
        ctx.host_profile.thread_count,
        token,
    )
    var result = out.take(lowered.result_seg_id)
    if builder.pool_granted() != 0:
        raise Error(
            String(EXECUTE_POOL_NOT_RELEASED)
            + ": the segment pool still holds "
            + String(builder.pool_granted())
            + " bytes after the run"
        )
    return result^
