# =============================================================================
# engine_sql -- run_sql: SQL text to record batches, or a named refusal
# =============================================================================
#
# In order: tokenize and parse; bind against the context's catalog and footers;
# then the route a plan takes (`engine_plan.run_plan_batch`): optimize, then
# hold each subtree the optimized plan repeats once (`optimize_for_run`);
# lower with inputs from the same footers; run. A
# `COPY ... TO` runs its query the same way and then writes the result as a
# local Parquet, CSV or newline-delimited JSON file (`engine_write`, still
# step `execute`), answering one row with the BIGINT column `Count`; its
# destination and compression are checked at step `bind`, so a refused COPY
# touches no file. A step that refuses
# ends the call, and the outcome says which step and the step's own message
# unchanged; the door retries nothing and keeps no second route. Nothing here
# raises: a failure of any step is a value.
#
# Each call counts one statement parsed on the context
# (`EngineContext.statements_parsed`) as it starts to parse; the plan door
# (`engine_plan.run_plan`) parses nothing and leaves the count as it is.
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
# are called one by one here so a refusal names the step that refused.
# `STATEMENT_NOT_A_QUERY` is `sql.sql_frontend`'s refusal, named here too so a
# caller of this module finds it beside the `STEP_*` names. `SqlOutcome`,
# `SqlRefusal`, `OPTIMIZE_UNRESOLVED_SCALAR` and the steps from `optimize` on
# are `engine_plan`'s, named here too; `optimize_for_run` is
# `engine_plan.optimize_for_run`.

from phase_timers.phase_timers import PH_BIND, PH_PARSE, pt_now, pt_record
from sql.sql_ast import STMT_COPY, STMT_QUERY
from sql.sql_binder import bind_statement
from sql.sql_frontend import (
    STATEMENT_NOT_A_QUERY as _SQL_STATEMENT_NOT_A_QUERY,
)
from sql.sql_parser import parse_sql
from sql.sql_token import tokenize
from fs.scan_fs import ScanFsOpener
from pipeline_exec.source_parquet import LocalOnlyScanFs

from .engine_context import EngineContext
from .engine_plan import (
    OPTIMIZE_UNRESOLVED_SCALAR as _OPTIMIZE_UNRESOLVED_SCALAR,
    STEP_EXECUTE as _STEP_EXECUTE,
    STEP_LOWER as _STEP_LOWER,
    STEP_OPTIMIZE as _STEP_OPTIMIZE,
    SqlOutcome as _SqlOutcome,
    SqlRefusal as _SqlRefusal,
    run_plan_batch,
)
from .engine_write import check_copy_target, count_result, write_copy_result

comptime STEP_PARSE = "parse"
comptime STEP_BIND = "bind"
comptime STEP_OPTIMIZE = _STEP_OPTIMIZE
comptime STEP_LOWER = _STEP_LOWER
comptime STEP_EXECUTE = _STEP_EXECUTE
comptime OPTIMIZE_UNRESOLVED_SCALAR = _OPTIMIZE_UNRESOLVED_SCALAR
"""Refusal (step `optimize`): `engine_plan`'s, named here too."""
comptime SqlOutcome = _SqlOutcome
"""`engine_plan.SqlOutcome`: the batches, or the step that refused and why."""
comptime SqlRefusal = _SqlRefusal
"""`engine_plan.SqlRefusal`."""

comptime STATEMENT_NOT_A_QUERY = _SQL_STATEMENT_NOT_A_QUERY
"""Refusal (step `bind`): CREATE TABLE AS, which writes into a catalog table,
and no catalog is bound. The same name `sql.sql_frontend.plan_from_sql`
refuses a write with."""


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
    ctx.statements_parsed += 1
    var step = String(STEP_PARSE)
    try:
        var t_parse = pt_now()
        var stmt = parse_sql(tokenize(text))
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
        var batch = run_plan_batch(ctx, plan^, opener^, step)
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
        return SqlOutcome(step^, String(e))
