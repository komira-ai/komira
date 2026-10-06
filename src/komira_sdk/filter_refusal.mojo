# =============================================================================
# filter_refusal — why `PlanCarrier.filter` cannot serve a predicate, CARRIED
# in the plan (2026-09-25)
# =============================================================================
#
# `PlanCarrier.filter` cannot raise, and until this module it ABORTED the
# process for every predicate it could not serve (a refused `.over()`, an
# aggregate of a computed operand). Two things were wrong with that:
#
#   * MEASURED (review round 2, LOCAL darwin, 3 of 3): the abort for
#     `filter(col("x") > (col("x") * 2).mean())` died SIGBUS in
#     `String._realloc_mutable` and printed NOTHING -- a crash where the verb
#     claimed a named refusal (see `select_aggregates._owned`);
#   * it aborted because the alternative was worse: a FILTER whose predicate
#     names a column the input lacks is DROPPED by the engine
#     (`parquet_source.next_morsel`), so a refusal smuggled in
#     as an unknown column answered EVERY row -- and so did the customer's own
#     typo: `filter(col("nope") > 3)` answered 6 of 6 rows where polars raises
#     `ColumnNotFoundError`.
#
# `filter_refusal` names all three, and `refused_filter_plan` CARRIES the
# reason the way `select` carries its own: a PROJECT of one column whose NAME
# is the refusal. Over a parquet source the run then fails naming it
# ("... column 'filter(): ...'"); over an IN-MEMORY source it fails with the
# in-memory leaf's envelope text ("materialize_subplan: non-breaker child is
# not a parquet-collect shape ..."), not by name -- a naming gap of that leaf.
#
# ⛔ A PROJECT UNDER ANOTHER VERB IS PRUNED LIKE ANY UNREAD COLUMN (the
# untyped round-3 review, a P0 regression of this module's first version).
# "A PROJECT is never dropped -- it IS the output" was true only while the
# refusal was the LAST verb: MEASURED (LOCAL darwin, the Mojo
# surface) `filter(col("nope") > 3).select(col("k"))` answered all 6 rows,
# `.select(col("k").count())` 6 and `.group_by(["g"]).count()` 3 groups (the
# optimized plan: `Project(exprs=[ColRef(k)])`), where the tree before this
# module RAISED and polars raises ColumnNotFoundError. So every carrier is
# built over the refusal ALONE (`keep_refusal_at_root`, called by
# `PlanCarrier.__init__`, the one constructor every verb's successor goes
# through): a plan's ROOT output IS the result, and nothing prunes it.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_plan_expr.expr_walk import walk_expr_column_refs, ordered_name_sink
from komira_plan_expr.expr import EXPR_COL_REF
from komira_plan_ir.logical_plan import (
    ExprArray, LogicalPlan, PLAN_PROJECT, PLAN_FILTER, PLAN_AGGREGATE,
    PLAN_JOIN, PLAN_SORT, PLAN_LIMIT, PLAN_DISTINCT, PLAN_TOPN,
    PLAN_PARTITION_BY, PLAN_PARTITION_TOPN, PLAN_ASOF_JOIN, PLAN_UNION,
    PLAN_CAST_TO_VARCHAR,
)
from komira_plan_expr.col_expr_bind import over_refusal

from .select_aggregates import has_aggregate, predicate_aggregate_refusal


def _has_name(schema: Schema, name: String) -> Bool:
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return True
    return False


def unknown_column_refusal(predicate: Expr, schema: Schema) -> String:
    """polars' `ColumnNotFoundError` for the first column `predicate` names
    that `schema` lacks, or "". (A `COUNT(*)` window carries no column: an
    empty name is not a reference.)"""
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(predicate, sink)
    for i in range(len(names)):
        if names[i].byte_length() == 0 or _has_name(schema, names[i]):
            continue
        var s = String("unable to find column \"")
        s += names[i]
        s += "\"; valid columns: ["
        for c in range(schema.num_columns()):
            if c > 0:
                s += ", "
            s += "\""
            s += schema.field_name(c)
            s += "\""
        s += "] (polars: ColumnNotFoundError)"
        return s^
    return String("")


def filter_refusal(
    predicate: Expr, schema: Schema, above_aggregate: Bool
) -> String:
    """Why `filter(predicate)` over an input of `schema` cannot be served, or
    "". In order: a refused `.over()` anywhere in it (its own reason, which
    `walk_expr_column_refs` would otherwise report as an unknown column), a
    column the input lacks, and -- unless the filter sits directly above an
    AGGREGATE, which the optimizer's scalar broadcast serves -- an aggregate
    of a COMPUTED operand."""
    var why = over_refusal(predicate)
    if why.byte_length() > 0:
        return why^
    why = unknown_column_refusal(predicate, schema)
    if why.byte_length() > 0:
        return why^
    if not above_aggregate and has_aggregate(predicate):
        return predicate_aggregate_refusal(predicate)
    return String("")


def refused_plan(
    verb: String, why: String, var input: LogicalPlan
) -> LogicalPlan:
    """The plan that CARRIES a refusal of a verb that cannot raise: a PROJECT
    of one column named `<verb><why>` (`select(): ...`), which fails when the
    plan runs (naming it over a parquet source; see the module header).
    `keep_refusal_at_root` keeps it the plan's root under every later verb."""
    var name = String()
    name += verb
    name += why
    var refused = ExprArray()
    refused.append(Expr.col_ref(name))
    return LogicalPlan.project(refused^, input^)


def refused_filter_plan(why: String, var input: LogicalPlan) -> LogicalPlan:
    return refused_plan(String("filter(): "), why, input^)


def duplicate_name_refusal(schema: Schema) -> String:
    """polars' `DuplicateError` for the first output name `schema` repeats,
    or ""."""
    for i in range(schema.num_columns()):
        for j in range(i):
            if schema.field_name(i) == schema.field_name(j):
                var s = String("projections contained duplicate output name '")
                s += schema.field_name(i)
                s += (
                    "' (polars: DuplicateError); name one of them with"
                    " `.alias(\"...\")`"
                )
                return s^
    return String("")


def refuse_duplicate_names(var plan: LogicalPlan) -> LogicalPlan:
    """`plan`, or -- when its output repeats a name, which polars refuses
    and which leaves a frame no caller can read by name -- the carried
    `select(): ` refusal over it. ⛔ MEASURED (the round-2 review):
    `select([col("v").max(), col("v") - col("v").mean()])` answered TWO
    columns both named `v`. (The 0-key aggregate route is not checked here:
    `logical_plan.agg_out_field_name` owns its documented `v` / `v_1`
    scheme.)"""
    var why = duplicate_name_refusal(plan.output_schema)
    if why.byte_length() == 0:
        return plan^
    return refused_plan(String("select(): "), why, plan^)


# -----------------------------------------------------------------------------
# ⛔ A CARRIED REFUSAL STAYS THE PLAN'S ROOT (see the module header). The two
# prefixes below are the only ones `refused_plan` is called with.
# -----------------------------------------------------------------------------


def _is_refusal(plan: LogicalPlan) -> Bool:
    """`plan` IS a carried refusal: `refused_plan`'s PROJECT of one column
    named `filter(): ...` / `select(): ...`."""
    if plan.tag != PLAN_PROJECT or not plan._project:
        return False
    ref pe = plan._project.value()[].exprs
    if len(pe) != 1 or pe[0].tag != EXPR_COL_REF:
        return False
    var n = pe[0].col_ref_name()
    return n.startswith("filter(): ") or n.startswith("select(): ")


def _innermost_refusal(plan: LogicalPlan) -> Optional[LogicalPlan]:
    """A copy of the INNERMOST carried refusal in `plan` (the customer's
    first error; a join's left side first), or None. Walks every plan node
    that has an input."""
    var inner: Optional[LogicalPlan] = None
    if plan.tag == PLAN_PROJECT and plan._project:
        inner = _innermost_refusal(plan._project.value()[].child[])
    elif plan.tag == PLAN_FILTER and plan._filter:
        inner = _innermost_refusal(plan._filter.value()[].child[])
    elif plan.tag == PLAN_AGGREGATE and plan._aggregate:
        inner = _innermost_refusal(plan._aggregate.value()[].child[])
    elif plan.tag == PLAN_SORT and plan._sort:
        inner = _innermost_refusal(plan._sort.value()[].child[])
    elif plan.tag == PLAN_LIMIT and plan._limit:
        inner = _innermost_refusal(plan._limit.value()[].child[])
    elif plan.tag == PLAN_DISTINCT and plan._distinct:
        inner = _innermost_refusal(plan._distinct.value()[].child[])
    elif plan.tag == PLAN_TOPN and plan._topn:
        inner = _innermost_refusal(plan._topn.value()[].child[])
    elif plan.tag == PLAN_PARTITION_BY and plan._partition_by:
        inner = _innermost_refusal(plan._partition_by.value()[].child[])
    elif plan.tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        inner = _innermost_refusal(plan._partition_topn.value()[].child[])
    elif plan.tag == PLAN_CAST_TO_VARCHAR and plan._cast_to_varchar:
        inner = _innermost_refusal(plan._cast_to_varchar.value()[].child[])
    elif plan.tag == PLAN_JOIN and plan._join:
        inner = _innermost_refusal(plan._join.value()[].left[])
        if not inner:
            inner = _innermost_refusal(plan._join.value()[].right[])
    elif plan.tag == PLAN_ASOF_JOIN and plan._asof_join:
        inner = _innermost_refusal(plan._asof_join.value()[].left[])
        if not inner:
            inner = _innermost_refusal(plan._asof_join.value()[].right[])
    elif plan.tag == PLAN_UNION and plan._union:
        ref kids = plan._union.value()[].children
        for i in range(len(kids)):
            inner = _innermost_refusal(kids[i][])
            if inner:
                break
    if inner:
        return inner^
    if _is_refusal(plan):
        return Optional[LogicalPlan](plan.copy())
    return None


def keep_refusal_at_root(var plan: LogicalPlan) -> LogicalPlan:
    """`plan`, or -- when it was built over a carried refusal -- that refusal
    ALONE: the verbs above it are dropped, because the query is refused
    whatever follows (polars raises at collect), and a refusal that is the
    plan's root cannot be pruned by any rewrite."""
    var r = _innermost_refusal(plan)
    if not r:
        return plan^
    return r.take()
