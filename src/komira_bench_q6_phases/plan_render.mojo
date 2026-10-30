# =============================================================================
# plan_render -- the plans of a query as text, to see what the engine decided
# =============================================================================
#
# Runs the front half of `run_sql` (parse, bind, optimize, lower) and renders
# three views, none of which executes the query:
#   * the bound plan (before the optimizer),
#   * the optimized plan,
#   * the lowered plan (`render_lowered_plan`): per segment, the source with
#     its pushed filter, the operators (a residual filter is an `op ... FILTER`
#     line) and the sink.
# A predicate is printed as the expression the plan holds, so a bound that was
# folded to a literal reads as a literal and one that was not reads as the
# arithmetic.

from komira_lowering.render import render_lowered_plan
from komira_optimizer.optimizer_config import OptimizerConfig
from komira_optimizer.optimizer_driver import optimize
from komira_optimizer.optimizer_scalar_deps import ScalarDepTable
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_FILTER,
    PLAN_LIMIT,
    PLAN_PROJECT,
    PLAN_SCAN,
    PLAN_SORT,
    plan_tag_name,
)
from komira_sdk_exec.engine_context import EngineContext
from komira_sdk_exec.engine_lower import lower_for_context
from komira_sql.sql_binder import bind_statement
from komira_sql.sql_parser import parse_sql
from komira_sql.sql_token import tokenize


def _indent(n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += "  "
    return out^


def _describe(node: LogicalPlan, depth: Int, mut out: String):
    var pad = _indent(depth)
    var tag = node.tag
    if tag == PLAN_SCAN:
        ref sd = node.scan_data_ref()
        out += pad + "Scan path=" + sd.source_path
        if sd.projection:
            out += " projection=["
            ref cols = sd.projection.value()
            for i in range(len(cols)):
                if i > 0:
                    out += ", "
                out += cols[i]
            out += "]"
        if sd.filter:
            out += " pushed_filter=" + String(sd.filter.value())
        else:
            out += " pushed_filter=none"
        out += "\n"
    elif tag == PLAN_FILTER:
        ref fd = node.filter_data_ref()
        out += pad + "Filter predicate=" + String(fd.predicate) + "\n"
        _describe(fd.child[], depth + 1, out)
    elif tag == PLAN_PROJECT:
        ref pd = node.project_data_ref()
        out += pad + "Project " + String(len(pd.exprs)) + " exprs\n"
        _describe(pd.child[], depth + 1, out)
    elif tag == PLAN_AGGREGATE:
        ref ad = node.aggregate_data_ref()
        out += pad + "Aggregate group_by=" + String(len(ad.group_by)) + " aggs=["
        for i in range(len(ad.agg_exprs)):
            if i > 0:
                out += ", "
            out += String(ad.agg_exprs[i])
        out += "]\n"
        _describe(ad.child[], depth + 1, out)
    else:
        out += pad + plan_tag_name(tag) + " (not expanded)\n"


def render_plans(mut ctx: EngineContext, text: String) raises -> String:
    """The bound, optimized and lowered plans of the SQL `text` on `ctx`.

    Raises:
        Whatever the parser, binder, optimizer or lowering raises.
    """
    ctx.begin_query()
    var stmt = parse_sql(tokenize(text))
    var bound = bind_statement(stmt, ctx.catalog, ctx.footers)
    var plan = bound.take_plan()
    var out = String("== bound plan (before the optimizer)\n")
    _describe(plan, 1, out)
    var deps = ScalarDepTable()
    var optimized = optimize(plan^, OptimizerConfig(), deps)
    out += "== optimized plan\n"
    _describe(optimized, 1, out)
    var lowered = lower_for_context(optimized, ctx)
    out += "== lowered plan\n"
    out += render_lowered_plan(lowered)
    return out^
