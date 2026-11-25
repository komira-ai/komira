# =============================================================================
# engine_plan -- run_plan: a logical plan to record batches, or a named refusal
# =============================================================================
#
# The route both doors share from the optimizer down. `run_plan` takes a
# logical plan that is already built (decoded from an authored
# `WirePlanEnvelope` by `plan_wire.plan_from_bytes`, or built in Mojo) and, in
# order: optimizes it, then holds each subtree the optimized plan repeats once
# (`optimize_for_run`); lowers it with inputs from the context's footers
# (`lower_for_context`); runs it (`run_lowered_plan_with`). `run_sql` parses
# and binds its text and then runs the same steps (`run_plan_batch`), so a SQL
# query and a plan of the same query take one route to their answer.
#
# Nothing here reads SQL text: this module imports no part of the SQL front
# end (`sql.sql_token`, `sql.sql_parser`, `sql.sql_binder`, `sql.sql_frontend`).
# A plan needs no registered table: a scan leaf carries its own source (its
# paths, schema and orientation), and a Parquet scan of a file no table
# names reads that file's footer for its lowering facts
# (`engine_lower.lowering_inputs`).
#
# A step that refuses ends the call, and the outcome says which step
# (`optimize`, `lower` or `execute`) and the step's own message unchanged.
# `run_plan`, `run_plan_with` and `run_plan_write` raise nothing; `optimize_for_run` and
# `run_plan_batch` raise, and their callers turn the raise into an outcome.
#
# `run_plan_write` is the same route for a plan that has a destination (a
# `WriteTarget`, the envelope's `write_target`): it checks the destination and
# its compression at step `bind`, before the plan runs or any file is touched,
# runs the plan, then writes the answer as a local Parquet, CSV or
# newline-delimited JSON file (`engine_write`, still step `execute`) and
# answers one row, the BIGINT column `Count`, exactly as a SQL
# `COPY ... TO` does, and with its messages word for word.
#
# `SqlOutcome`, `SqlRefusal`, the four step names and `optimize_for_run` are
# defined here and imported by `engine_sql`, so callers of either module find
# them under the names they always had.

from arrow.schema import RecordBatch
from arrow.write_target import WriteTarget
from fs.scan_fs import ScanFsOpener
from optimizer.optimizer_config import OptimizerConfig
from optimizer.optimizer_driver import optimize
from optimizer.optimizer_scalar_deps import ScalarDepTable
from optimizer.plan_cse import plan_cse_eliminate
from phase_timers.phase_timers import PH_LOWER, PH_OPTIMIZE, pt_now, pt_record
from pipeline_exec.source_parquet import LocalOnlyScanFs
from plan_ir.logical_plan import LogicalPlan

from .engine_context import EngineContext
from .engine_execute import run_lowered_plan_with
from .engine_lower import lower_for_context
from .engine_write import check_copy_target, count_result, write_copy_result
from .run_control import RunControl

comptime STEP_BIND = "bind"
"""The step at which `run_plan_write` checks the destination; `engine_sql`
binds its statement at the same step."""
comptime STEP_OPTIMIZE = "optimize"
comptime STEP_LOWER = "lower"
comptime STEP_EXECUTE = "execute"

comptime OPTIMIZE_UNRESOLVED_SCALAR = "OPTIMIZE_UNRESOLVED_SCALAR"
"""Refusal (step `optimize`): the plan needs a scalar subquery executed first,
which neither door does yet."""


struct SqlRefusal(Copyable, Movable):
    """Which step refused and why."""

    var step: String
    """One of the `STEP_*` names."""
    var reason: String
    """The step's own message, unchanged."""

    def __init__(out self, var step: String, var reason: String):
        self.step = step^
        self.reason = reason^


struct SqlOutcome(Movable):
    """What `run_sql` and `run_plan` return: the result batches, or the
    refusal."""

    var batches: List[RecordBatch]
    var refusal: Optional[SqlRefusal]

    def __init__(out self):
        self.batches = List[RecordBatch]()
        self.refusal = None

    def __init__(out self, var step: String, var reason: String):
        self.batches = List[RecordBatch]()
        self.refusal = Optional(SqlRefusal(step^, reason^))

    def ok(self) -> Bool:
        return not self.refusal


def optimize_for_run(var plan: LogicalPlan) raises -> LogicalPlan:
    """The plan that is lowered for `plan`: `optimize`, then each subtree the
    optimized plan repeats held once and every later occurrence a reference to
    it (`plan_cse_eliminate`: a CTE the query reads twice, two equal UNION ALL
    branches), which lowering cuts once (`lowering.cut_shared`).

    Raises:
        OPTIMIZE_UNRESOLVED_SCALAR when the plan needs a scalar subquery
        executed first; an optimizer pass's own error otherwise.
    """
    var deps = ScalarDepTable()
    var optimized = optimize(plan^, OptimizerConfig(), deps)
    if deps.has_requests():
        raise Error(
            String(OPTIMIZE_UNRESOLVED_SCALAR)
            + ": the plan needs a scalar subquery executed first"
        )
    return plan_cse_eliminate(optimized^)


def run_plan_batch[
    R: ScanFsOpener
](
    mut ctx: EngineContext,
    var plan: LogicalPlan,
    var opener: R,
    mut step: String,
    control: RunControl,
) raises -> RecordBatch:
    """Optimize, lower and run `plan` on `ctx` and return the result batch.

    `step` is set to each step's name as the step starts, so a caller that
    catches the raise knows which step refused. The caller has started the
    query (`EngineContext.begin_query`): the footers lowering reads are the
    ones already cached for it. The run polls `control`'s cancel token and
    counts its segments into its progress (`run_lowered_plan_with`); optimize
    and lower do not poll it.
    """
    step = String(STEP_OPTIMIZE)
    var t_optimize = pt_now()
    var optimized = optimize_for_run(plan^)
    pt_record[PH_OPTIMIZE](t_optimize)
    step = String(STEP_LOWER)
    var t_lower = pt_now()
    var lowered = lower_for_context(optimized, ctx)
    pt_record[PH_LOWER](t_lower)
    step = String(STEP_EXECUTE)
    return run_lowered_plan_with(ctx, lowered^, opener^, control)


def run_plan(mut ctx: EngineContext, var plan: LogicalPlan) -> SqlOutcome:
    """Run the logical plan `plan` on `ctx`, reading the local file system only
    (`run_plan_with` and `LocalOnlyScanFs`)."""
    return run_plan_with(ctx, plan^, LocalOnlyScanFs())


def run_plan_with[
    R: ScanFsOpener
](mut ctx: EngineContext, var plan: LogicalPlan, var opener: R) -> SqlOutcome:
    """Run the logical plan `plan` on `ctx` and return its answer as one batch,
    or the refusal of the step (`optimize`, `lower`, `execute`) that ended it.

    The call is a query of its own: the footer cache is replaced first
    (`EngineContext.begin_query`), so the files the plan names are read as
    they are now. A Parquet scan of a remote store reads through the file
    system `opener` opens on its bucket. Nothing cancels the run. Nothing
    raises.
    """
    ctx.begin_query()
    var step = String(STEP_OPTIMIZE)
    try:
        var batch = run_plan_batch(ctx, plan^, opener^, step, RunControl())
        var outcome = SqlOutcome()
        outcome.batches.append(batch^)
        return outcome^
    except e:
        return SqlOutcome(step^, String(e))


def run_plan_write(
    mut ctx: EngineContext, var plan: LogicalPlan, target: WriteTarget
) -> SqlOutcome:
    """`run_plan_write` reading the local file system only (`LocalOnlyScanFs`)."""
    return run_plan_write(ctx, plan^, target, LocalOnlyScanFs())


def run_plan_write[
    R: ScanFsOpener
](
    mut ctx: EngineContext,
    var plan: LogicalPlan,
    target: WriteTarget,
    var opener: R,
) -> SqlOutcome:
    """Run the logical plan `plan` on `ctx` and write its answer to `target`,
    a local Parquet, CSV or newline-delimited JSON file, answering one batch
    of one row: the NOT NULL BIGINT column `Count` holding the rows written.

    The call is a query of its own (`run_plan_with`). The destination and its
    compression are checked first, at step `bind`, so a refused write runs
    nothing and touches no file: `STORAGE_URL_REFUSED` for a path with
    `://`, `COPY_COMPRESSION_UNSUPPORTED` for CSV or JSON with lz4. The plan
    then runs (`optimize`, `lower`, `execute`) and the file is written at step
    `execute`, all or nothing, replacing a file already there; a destination
    that cannot be written (a missing directory, `STORAGE_NOT_FOUND`) is
    refused at `execute`. Nothing raises.
    """
    ctx.begin_query()
    var step = String(STEP_BIND)
    try:
        check_copy_target(target.path, target.fmt, target.codec)
        var batch = run_plan_batch(ctx, plan^, opener^, step, RunControl())
        var rows = write_copy_result(
            batch^, target.path, target.fmt, target.codec
        )
        var outcome = SqlOutcome()
        outcome.batches.append(count_result(rows))
        return outcome^
    except e:
        return SqlOutcome(step^, String(e))
