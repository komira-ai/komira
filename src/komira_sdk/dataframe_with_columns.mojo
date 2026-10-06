# =============================================================================
# DataFrame.with_columns -- multi-column derived projection helper
# =============================================================================
#
# (post-agg arithmetic). Plural mirror of the
# existing `with_column(expr)` (singular) and `select(names)`. Adds N
# derived columns in a single PLAN_PROJECT carrying:
#
#   1) one passthrough col_ref per existing schema column — EXCEPT a column a
#      derived expression is NAMED after, which that expression REPLACES in
#      place (polars' rule), and
#   2) the remaining derived expressions appended after, in order.
#
# ⛔ UNTIL 2026-09-24 (1) had no exception: `with_columns((col("a") * 2)
# .alias("a"))` over [a, b] answered [a, b, a] — a DUPLICATE name, and every
# by-name read downstream saw the ORIGINAL `a`. polars answers [a, b] with `a`
# doubled (measured, polars 1.44.2).
#
# The load-bearing use case is post-aggregate arithmetic, e.g.:
#
#   df.group_by("nation")
#     .agg(sum(col("brazil_vol")).alias("brazil_sum"),
#          sum(col("vol")).alias("total_sum"))
#     .with_columns(
#         (col("brazil_sum") / col("total_sum")).alias("share"),
#         (col("total_sum") - col("brazil_sum")).alias("non_brazil_sum"),
#     )
#     .select(["nation", "share", "non_brazil_sum"])
#
# Lowering: PLAN_AGGREGATE -> PLAN_PROJECT([passthroughs..., derived...]).
# The plan compiler's `_compile_project` already accepts arbitrary scalar
# trees in PLAN_PROJECT.exprs (it routes through the streaming evaluator
# via MorselOp.project), so NO new plan IR variant or optimizer rule is
# required. Keep the with_column singular path in dataframe.mojo as the
# primitive; this module is a thin builder that constructs the plan node
# and lets DataFrame's arity-overloaded methods stay one-liners.
#
# Scope note: this is NOT the input-side derived-col-in-agg fix (Item 15
# / `optimizer_materialize_agg_input.mojo`). That rule fires INSIDE the
# AggregateSink's input-resolver gate; this module fires AFTER the
# AggregateSink and does not interact with `resolve_col_index`.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    _infer_expr_field,
)


def build_with_columns_plan(
    var plan: LogicalPlan,
    var derived: ExprArray,
) raises -> LogicalPlan:
    """Construct the PLAN_PROJECT node for `df.with_columns(derived)`.

    polars' `with_columns`: every column of `plan.output_schema` passes
    through in order, a derived expression whose OUTPUT NAME equals an existing
    column REPLACES that column in its position, and the rest are appended in
    the order given. The output name is the one the projection itself will give
    the expression (`_infer_expr_field`, the ONE output-field inference): an
    alias's name, a bare column's name, else the engine's generated name.

    RAISES when two derived expressions produce the SAME output name — polars
    raises `DuplicateError` there, and answering with two same-named columns is
    the defect this rule removes.

    ⚠ AN UNALIASED computed expression that reaches THIS function is named by
    the ENGINE (`expr`, `case`, ...). `PlanCarrier.with_columns` aliases each
    one with polars' root-column name first (`select_aggregates
    .name_unaliased`), so `with_columns(col("a") * 2)`
    REPLACES `a` as polars does; a direct caller of this function does not
    get that.

    Args:
        plan: Owned input LogicalPlan whose schema we extend.
        derived: Owned list of N new derived expressions (typically
                 user-supplied alias-bound binops over columns produced
                 by an upstream Aggregate).
    """
    var ncols = plan.output_schema.num_columns()
    var n_derived = len(derived)
    var names = List[String]()
    for j in range(n_derived):
        var name = _infer_expr_field(derived[j], plan.output_schema).name
        for k in range(j):
            if names[k] == name:
                raise Error(
                    "with_columns: the output name '"
                    + name
                    + "' is produced by more than one expression (polars"
                    + " raises DuplicateError here); alias them apart"
                )
        names.append(name)
    var placed = List[Bool](length=n_derived, fill=False)
    var exprs = ExprArray()
    for i in range(ncols):
        var src = plan.output_schema.field_name(i)
        var hit = -1
        for j in range(n_derived):
            if not placed[j] and names[j] == src:
                hit = j
                break
        if hit >= 0:
            exprs.append(derived[hit].copy())
            placed[hit] = True
        else:
            exprs.append(Expr.col_ref(src))
    for j in range(n_derived):
        if not placed[j]:
            exprs.append(derived[j].copy())
    return LogicalPlan.project(exprs^, plan^)
