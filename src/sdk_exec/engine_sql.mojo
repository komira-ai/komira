# =============================================================================
# engine_sql -- run_sql: SQL text to record batches, or a named refusal
# =============================================================================
#
# In order: tokenize and parse; bind against the context's catalog and footers;
# optimize, then hold each subtree the optimized plan repeats once
# (`optimize_for_run`); lower with inputs from the same footers; run. A
# `COPY ... TO` runs its query the same way and then writes the result as a
# local Parquet, CSV or newline-delimited JSON file (`engine_write`, still
# step `execute`), answering one row with the BIGINT column `Count`; its
# destination and compression are checked at step `bind`, so a refused COPY
# touches no file. A step that refuses
# ends the call, and the outcome says which step and the step's own message
# unchanged; the door retries nothing and keeps no second route. Nothing here
# raises: a failure of any step is a value.
#
# The footer cache is pinned to the call (`EngineContext.begin_query`), so the
# binder and lowering read each file's footer once and the next call reads
# again.
#
# `run_sql_with` takes the `ScanFsOpener` the run reads a remote store
# through: a catalog table whose `ParquetSource` names an S3 or GCS bucket or
# an Azure container is bound
# from the catalog's schema, lowered with no footer facts, and read through
# the file system the opener opens on the bucket. `run_sql` is `run_sql_with`
# and `LocalOnlyScanFs`, which refuses such a scan at step `execute` with
# `SCAN_FS_UNSERVED`.
#
# Parse and bind are the steps `sql.sql_frontend.plan_from_sql` composes; they
# are called one by one here so a refusal names the step that refused. A refusal
# of the parse step also carries the line and column where the text stopped
# parsing (`sql.sql_position.parse_sql_text`).
# `STATEMENT_NOT_A_QUERY` is `sql.sql_frontend`'s refusal, named here too so a
# caller of this module finds it beside the `STEP_*` names.

from arrow.schema import RecordBatch
from optimizer.optimizer_config import OptimizerConfig
from optimizer.optimizer_driver import optimize
from optimizer.optimizer_scalar_deps import ScalarDepTable
from optimizer.plan_cse import plan_cse_eliminate
from plan_ir.logical_plan import LogicalPlan
from phase_timers.phase_timers import (
    PH_BIND,
    PH_LOWER,
    PH_OPTIMIZE,
    PH_PARSE,
    pt_now,
    pt_record,
)
from sql.sql_ast import STMT_COPY, STMT_QUERY
from sql.sql_binder import bind_statement
from sql.sql_frontend import (
    STATEMENT_NOT_A_QUERY as _SQL_STATEMENT_NOT_A_QUERY,
)
from sql.sql_position import SqlPosition, parse_sql_text
from fs.scan_fs import ScanFsOpener
from pipeline_exec.source_parquet import LocalOnlyScanFs

from .engine_context import EngineContext
from .engine_execute import run_lowered_plan_with
from .engine_lower import lower_for_context
from .engine_write import check_copy_target, count_result, write_copy_result

comptime STEP_PARSE = "parse"
comptime STEP_BIND = "bind"
comptime STEP_OPTIMIZE = "optimize"
comptime STEP_LOWER = "lower"
comptime STEP_EXECUTE = "execute"

comptime STATEMENT_NOT_A_QUERY = _SQL_STATEMENT_NOT_A_QUERY
"""Refusal (step `bind`): CREATE TABLE AS, which writes into a catalog table,
and no catalog is bound. The same name `sql.sql_frontend.plan_from_sql`
refuses a write with."""

comptime OPTIMIZE_UNRESOLVED_SCALAR = "OPTIMIZE_UNRESOLVED_SCALAR"
"""Refusal (step `optimize`): the plan needs a scalar subquery executed first,
which this door does not do yet."""


struct SqlRefusal(Copyable, Movable):
    """Which step refused and why."""

    var step: String
    """One of the `STEP_*` names."""
    var reason: String
    """The step's own message, unchanged."""
    var position: Optional[SqlPosition]
    """Where the SQL text stopped parsing: set for a refusal of step `parse`,
    `None` for every other step."""

    def __init__(out self, var step: String, var reason: String):
        self.step = step^
        self.reason = reason^
        self.position = None

    def __init__(
        out self,
        var step: String,
        var reason: String,
        var position: Optional[SqlPosition],
    ):
        self.step = step^
        self.reason = reason^
        self.position = position^


struct SqlOutcome(Movable):
    """What `run_sql` returns: the result batches, or the refusal."""

    var batches: List[RecordBatch]
    var refusal: Optional[SqlRefusal]

    def __init__(out self):
        self.batches = List[RecordBatch]()
        self.refusal = None

    def __init__(out self, var step: String, var reason: String):
        self.batches = List[RecordBatch]()
        self.refusal = Optional(SqlRefusal(step^, reason^))

    def __init__(
        out self,
        var step: String,
        var reason: String,
        var position: Optional[SqlPosition],
    ):
        self.batches = List[RecordBatch]()
        self.refusal = Optional(SqlRefusal(step^, reason^, position^))

    def ok(self) -> Bool:
        return not self.refusal


def optimize_for_run(var plan: LogicalPlan) raises -> LogicalPlan:
    """The plan `run_sql` lowers for the bound `plan`: `optimize`, then each
    subtree the optimized plan repeats held once and every later occurrence a
    reference to it (`plan_cse_eliminate`: a CTE the query reads twice, two
    equal UNION ALL branches), which lowering cuts once
    (`lowering.cut_shared`).

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


def run_sql(mut ctx: EngineContext, text: String) -> SqlOutcome:
    """Run the SQL statement `text` against `ctx` (a query, or a `COPY ... TO`
    a local Parquet, CSV or JSON file), reading the local file system only (`run_sql_with`
    and `LocalOnlyScanFs`)."""
    return run_sql_with(ctx, text, LocalOnlyScanFs())


def run_sql_with[
    R: ScanFsOpener
](mut ctx: EngineContext, text: String, var opener: R) -> SqlOutcome:
    """Run the SQL statement `text` against `ctx`: a query, or a `COPY ... TO`
    a local Parquet, CSV or JSON file. A Parquet scan of a remote store (a catalog table
    whose source names a bucket) reads through the file system `opener` opens
    on the bucket."""
    ctx.begin_query()
    var step = String(STEP_PARSE)
    var stopped_at = SqlPosition(0, 0)
    try:
        var t_parse = pt_now()
        var stmt = parse_sql_text(text, stopped_at)
        pt_record[PH_PARSE](t_parse)
        step = String(STEP_BIND)
        var t_bind = pt_now()
        var bound = bind_statement(stmt, ctx.catalog, ctx.footers)
        pt_record[PH_BIND](t_bind)
        if bound.kind == STMT_COPY:
            check_copy_target(bound.dest_path, bound.fmt, bound.codec)
        elif bound.kind != STMT_QUERY:
            raise Error(
                String(STATEMENT_NOT_A_QUERY)
                + ": CREATE TABLE AS writes into a catalog table, and no"
                " catalog is bound; write COPY (<query>) TO '<file>.parquet'"
                " to write a file"
            )
        var plan = bound.take_plan()
        step = String(STEP_OPTIMIZE)
        var t_optimize = pt_now()
        var optimized = optimize_for_run(plan^)
        pt_record[PH_OPTIMIZE](t_optimize)
        step = String(STEP_LOWER)
        var t_lower = pt_now()
        var lowered = lower_for_context(optimized, ctx)
        pt_record[PH_LOWER](t_lower)
        step = String(STEP_EXECUTE)
        var batch = run_lowered_plan_with(ctx, lowered^, opener^)
        var outcome = SqlOutcome()
        if bound.kind == STMT_COPY:
            var rows = write_copy_result(
                batch^, bound.dest_path, bound.fmt, bound.codec
            )
            outcome.batches.append(count_result(rows))
        else:
            outcome.batches.append(batch^)
        return outcome^
    except e:
        if step == STEP_PARSE:
            return SqlOutcome(step^, String(e), Optional(stopped_at.copy()))
        return SqlOutcome(step^, String(e))
