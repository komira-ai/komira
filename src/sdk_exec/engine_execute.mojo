# =============================================================================
# engine_execute -- run a lowered plan on the context's workers
# =============================================================================
#
# One `RealBuilder` per run: it borrows a metadata cache and an expression pool
# that live as long as the run, so nothing a run read outlives it (the scan
# reads through `parquet`'s metadata cache, which is new for every run,
# so a later query never sees an earlier run's footer; within a run the scan
# reads the footer a second time and nothing checks it against the footer
# lowering read: komira#2024). The
# builder's segment pool is sized from the host profile's memory budget, and
# the context's spill directory, when it has one, is the builder's (a grouped
# aggregation over fixed-width keys then spills instead of being refused).
#
# A Parquet scan of a remote store is read through the file system the
# caller's `ScanFsOpener` opens on its bucket (`run_lowered_plan_with`);
# `run_lowered_plan` gives the builder `LocalOnlyScanFs`, so such a scan is
# refused with `SCAN_FS_UNSERVED`. The run's one footer cache keys each file
# system's entries apart (`FileSystem.key_prefix`).
#
# A plan that scans an in-memory batch (a SELECT with no FROM reads the
# binder's one-row relation) names it by its index in `params.batches`; each
# source is handed to the builder as one resident batch, in that order, so
# the builder's handle is the plan's index. A source of several batches is
# concatenated into one, and a source of none is an empty batch of its schema.
#
# The run's cancel token and progress counter are the caller's `RunControl`
# when it gives one (`run_lowered_plan_with(ctx, lowered, opener, control)`):
# a cancel on the control stops the run at its next check, and the run counts
# its segments into the control's progress. Without one, the run has a token
# of its own that nothing cancels.

from std.memory import ArcPointer

from arrow.concat import concat_record_batches_nway_ref
from arrow.schema import RecordBatch
from column_kernels.compiler_helpers import empty_batch_like_schema
from lowering.lowered_plan import LoweredPlan
from parquet.runtime_footer_cache import ParquetMetadataCache
from phase_timers.phase_timers import (
    PH_EXEC_SETUP,
    PH_RUN_PLAN,
    pt_now,
    pt_record,
)
from physical_plan.physical_plan import (
    AggSinkData,
    PartitionBySinkData,
    SortSinkData,
    TopNSinkData,
)
from fs.scan_fs import ScanFsOpener
from pipeline_exec.real_builder import RealBuilder
from pipeline_exec.run_plan import run_plan
from pipeline_exec.source_parquet import LocalOnlyScanFs
from plan_expr.expr_pool import ExprPool
from scan_source.in_memory_source import InMemorySource
from udf_host.runtime import UdfBinding

from .engine_context import EngineContext
from .run_control import RunControl

comptime EXECUTE_POOL_NOT_RELEASED = "EXECUTE_POOL_NOT_RELEASED"
"""Refusal: a run ended with the segment pool not whole (a sink kept its
reservation)."""


def _resident_batch(src: InMemorySource) raises -> RecordBatch:
    """The rows of `src` as one batch the builder owns: its batches
    concatenated (a copy; the source's payload is shared with the plan), or
    an empty batch of its schema when it holds none."""
    if len(src.data[]) == 0:
        return empty_batch_like_schema(src.schema())
    return concat_record_batches_nway_ref(src.data[])


def run_lowered_plan(
    mut ctx: EngineContext, var lowered: LoweredPlan
) raises -> RecordBatch:
    """`run_lowered_plan_with` reading the local file system only: a scan of
    a remote store is refused with `SCAN_FS_UNSERVED`."""
    return run_lowered_plan_with(ctx, lowered^, LocalOnlyScanFs())


def run_lowered_plan_with[
    R: ScanFsOpener
](mut ctx: EngineContext, var lowered: LoweredPlan, var opener: R) raises -> RecordBatch:
    """Run `lowered` on `ctx.runtime` with `ctx.host_profile.thread_count`
    workers and return the result segment's batch. A Parquet scan of a remote
    store reads through the file system `opener` opens on its bucket. Nothing
    can cancel the run.

    Raises:
        Error starting with `EXECUTE_POOL_NOT_RELEASED` when a run leaves
        bytes granted, `SCAN_FS_UNSERVED` when `opener` does not serve a
        scan's store, and the driver's, a member's or the store's error
        otherwise.
    """
    return run_lowered_plan_with(ctx, lowered^, opener^, RunControl())


def run_lowered_plan_with[
    R: ScanFsOpener
](
    mut ctx: EngineContext,
    var lowered: LoweredPlan,
    var opener: R,
    control: RunControl,
) raises -> RecordBatch:
    """`run_lowered_plan_with` under `control`: the run polls the control's
    token and counts its segments into the control's progress.

    Raises:
        `pipeline_exec`'s cancelled error (`pipeline_exec: the query was
        cancelled: <reason>`) when the control is cancelled before the run's
        last check; otherwise what the form without a control raises.
    """
    return run_lowered_plan_with(ctx, lowered^, opener^, control, ArcPointer(UdfBinding()))


def run_lowered_plan_with[
    R: ScanFsOpener
](
    mut ctx: EngineContext,
    var lowered: LoweredPlan,
    var opener: R,
    control: RunControl,
    udfs: ArcPointer[UdfBinding],
) raises -> RecordBatch:
    """`run_lowered_plan_with` under `control`, with the plan's UDFs loaded
    in `udfs`: each OP_UDF_APPLY calls the UDF of the binding its call
    names (`RealBuilder.set_udfs`).

    Raises:
        What the form without `udfs` raises, and a UDF call's refusal
        (`udf_host.instance`: `UDF_RAISED`, `UDF_WORKER_CRASHED`, ...).
    """
    var t_setup = pt_now()
    var cache = ParquetMetadataCache()
    var pool = ExprPool()
    var placeholder = 0
    var builder = RealBuilder[
        origin_of(cache), origin_of(pool), origin_of(placeholder), R
    ](cache, pool, opener^)
    builder.set_memory_budget(ctx.host_profile.memory_budget_bytes)
    builder.set_udfs(udfs)
    if ctx.spill_directory:
        builder.set_spill_directory(ctx.spill_directory.value())
    # A fresh builder holds no resident batch, so the i-th `add_resident` is
    # handle i, the index the plan's SOURCE_BATCH specs name.
    for i in range(len(lowered.params.batches)):
        _ = builder.add_resident(_resident_batch(lowered.params.batches[i]))
    # The descriptors index the sink data by position, and `pop` takes from the
    # end: reverse once, then add in the plan's order.
    var reversed_sinks = List[AggSinkData]()
    while len(lowered.params.agg) > 0:
        reversed_sinks.append(lowered.params.agg.pop())
    while len(reversed_sinks) > 0:
        _ = builder.add_agg_sink(reversed_sinks.pop())
    # The same for the sort sinks, which SINK_SORT segments index apart from
    # the aggregation sinks: without them a plan with an ORDER BY names sort
    # sink data the builder does not hold.
    var reversed_sorts = List[SortSinkData]()
    while len(lowered.params.sort) > 0:
        reversed_sorts.append(lowered.params.sort.pop())
    while len(reversed_sorts) > 0:
        _ = builder.add_sort_sink(reversed_sorts.pop())
    # And the top-n sinks, which SINK_TOPN segments index: an ORDER BY with a
    # LIMIT or an OFFSET.
    var reversed_topns = List[TopNSinkData]()
    while len(lowered.params.topn) > 0:
        reversed_topns.append(lowered.params.topn.pop())
    while len(reversed_topns) > 0:
        _ = builder.add_topn_sink(reversed_topns.pop())
    # And for the window sinks, which SINK_PARTITION_BY segments index apart
    # from the others.
    var reversed_windows = List[PartitionBySinkData]()
    while len(lowered.params.window) > 0:
        reversed_windows.append(lowered.params.window.pop())
    while len(reversed_windows) > 0:
        _ = builder.add_window_sink(reversed_windows.pop())
    var token = control.token()
    ref dispatch = ctx.runtime.dispatcher()
    pt_record[PH_EXEC_SETUP](t_setup)
    var t_run = pt_now()
    var out = run_plan(
        lowered.segments,
        builder,
        dispatch,
        ctx.host_profile.thread_count,
        token,
        control.progress(),
    )
    pt_record[PH_RUN_PLAN](t_run)
    var result = out.take(lowered.result_seg_id)
    if builder.pool_granted() != 0:
        raise Error(
            String(EXECUTE_POOL_NOT_RELEASED)
            + ": the segment pool still holds "
            + String(builder.pool_granted())
            + " bytes after the run"
        )
    return result^
