# =============================================================================
# dataframe_concat — the untyped carrier's UNION ALL, `PlanCarrier.concat`
# (2026-09-24)
# =============================================================================
#
# `LogicalPlan.union` (a `PLAN_UNION` with N children) has existed since v4.2
# and the SQL binder reaches it for `UNION ALL` (`_bind_union_all_chain`), but
# the untyped Mojo carrier had NO verb over it: the corpus element `union` was
# a DECLARED absence at @mojo (`MOJO_NO_VERB`). `PlanCarrier.concat(top,
# bottom)` is that verb — polars' `pl.concat([top, bottom])`, answered the way
# the SQL door answers `UNION ALL`, which is DuckDB's:
#
#   * rows of `top`, then rows of `bottom` — duplicates KEPT (UNION ALL, not
#     UNION);
#   * the output schema is `top`'s, NAMES INCLUDED, and the branches are
#     matched by POSITION (DuckDB: `SELECT a ... UNION ALL SELECT b ...` is a
#     column called `a`). ⚠ polars' `how="vertical"` matches by NAME and
#     raises on a name mismatch; this door answers like DuckDB and says so.
#     ⚠ `UnionData` REQUIRES every child to advertise the union's schema,
#     names included, so a differently-named `bottom` is first wrapped in a
#     PROJECT that renames its columns to `top`'s (`concat_align_names`) —
#     the positional rule made structural rather than assumed.
#
# ⛔ A TYPE MISMATCH IS REFUSED BY NAME, NOT COERCED — the SQL binder's rule
# (`_union_branch_schema_check`) for the same reason: `PLAN_UNION` concatenates
# batches that must already share a physical layout, and admitting two
# layouts under one advertised schema returns reinterpreted bytes, not an
# error. DuckDB coerces (`1 UNION ALL 1.5` is DOUBLE); cast a branch first.
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray


def concat_schema_check(top: Schema, bottom: Schema) raises:
    """RAISE unless `bottom` advertises `top`'s column COUNT and, position by
    position, `top`'s Arrow TYPE. Names are not compared (DuckDB's rule)."""
    if top.num_columns() != bottom.num_columns():
        raise Error(
            "PlanCarrier.concat: the second frame has "
            + String(bottom.num_columns()) + " column(s) and the first "
            + String(top.num_columns())
            + ". A UNION ALL needs the same number of columns, in the same"
            " order."
        )
    for i in range(top.num_columns()):
        if top.field_arrow_type(i) != bottom.field_arrow_type(i):
            raise Error(
                "PlanCarrier.concat: column " + String(i + 1)
                + " differs in TYPE — the first frame has "
                + String(top.field_arrow_type(i)) + " and the second "
                + String(bottom.field_arrow_type(i))
                + ". DuckDB coerces UNION ALL branches to a common type; this"
                " engine's PLAN_UNION does not (it concatenates batches that"
                " must already share a layout), so cast one frame first."
            )


def concat_align_names(top: Schema, var bottom: LogicalPlan) -> LogicalPlan:
    """`bottom` unchanged when its column NAMES already equal `top`'s;
    otherwise `bottom` under a PROJECT that aliases column i to `top`'s name
    i. Call AFTER `concat_schema_check` (count and types already agree)."""
    var same = True
    for i in range(top.num_columns()):
        if top.field_name(i) != bottom.output_schema.field_name(i):
            same = False
            break
    if same:
        return bottom^
    var exprs = ExprArray()
    for i in range(top.num_columns()):
        exprs.append(
            Expr.alias(
                Expr.col_ref(bottom.output_schema.field_name(i)),
                top.field_name(i),
            )
        )
    return LogicalPlan.project(exprs^, bottom^)
