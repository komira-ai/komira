# =============================================================================
# engine_sql -- run_sql: SQL text to record batches, or a named refusal
# =============================================================================
#
# In order: tokenize and parse; bind against the context's catalog and footers;
# optimize; lower with inputs from the same footers; run. A step that refuses
# ends the call, and the outcome says which step and the step's own message
# unchanged; the door retries nothing and keeps no second route. Nothing here
# raises: a failure of any step is a value.
#
# The footer cache is pinned to the call (`EngineContext.begin_query`), so the
# binder and lowering read each file's footer once and the next call reads
# again.

from komira_arrow.schema import RecordBatch
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_driver import optimize
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_sql.sql_ast import STMT_QUERY
from komira_sql.sql_binder import bind_statement
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize

from .engine_context import EngineContext
from .engine_execute import run_lowered_plan
from .engine_lower import lower_for_context

comptime STEP_PARSE = "parse"
comptime STEP_BIND = "bind"
comptime STEP_OPTIMIZE = "optimize"
comptime STEP_LOWER = "lower"
comptime STEP_EXECUTE = "execute"

comptime STATEMENT_NOT_A_QUERY = "STATEMENT_NOT_A_QUERY"
"""Refusal (step `bind`): COPY and CREATE TABLE AS wait for a writes slice."""

comptime OPTIMIZE_UNRESOLVED_SCALAR = "OPTIMIZE_UNRESOLVED_SCALAR"
"""Refusal (step `optimize`): the plan needs a scalar subquery executed first,
which this door does not do yet."""


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
    """What `run_sql` returns: the result batches, or the refusal."""

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


def run_sql(mut ctx: EngineContext, text: String) -> SqlOutcome:
    """Run the SQL query `text` against `ctx`."""
    ctx.begin_query()
    var step = String(STEP_PARSE)
    try:
        var stmt = parse_sql(tokenize(text))
        step = String(STEP_BIND)
        var bound = bind_statement(stmt, ctx.catalog, ctx.footers)
        if bound.kind != STMT_QUERY:
            raise Error(
                String(STATEMENT_NOT_A_QUERY)
                + ": only a query runs here; COPY and CREATE TABLE AS are not"
                " served yet"
            )
        var plan = bound.take_plan()
        step = String(STEP_OPTIMIZE)
        var deps = ScalarDepTable()
        var optimized = optimize(plan^, OptimizerConfig(), deps)
        if deps.has_requests():
            raise Error(
                String(OPTIMIZE_UNRESOLVED_SCALAR)
                + ": the plan needs a scalar subquery executed first"
            )
        step = String(STEP_LOWER)
        var lowered = lower_for_context(optimized, ctx)
        step = String(STEP_EXECUTE)
        var batch = run_lowered_plan(ctx, lowered^)
        var outcome = SqlOutcome()
        outcome.batches.append(batch^)
        return outcome^
    except e:
        return SqlOutcome(step^, String(e))
