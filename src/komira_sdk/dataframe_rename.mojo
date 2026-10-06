# =============================================================================
# dataframe_rename — the untyped carrier's `rename`, polars'
# `LazyFrame.rename({"old": "new"})` (2026-09-24)
# =============================================================================
#
# A PROJECTION OF EVERY COLUMN, EACH A PLAIN REFERENCE UNDER ITS NEW NAME, in
# the frame's column order — the plan `select(col("k"), col("v").alias("val"),
# ...)` builds, and what the SQL door asks as `SELECT k AS key, g, v AS val`.
# No engine node is new; the carrier had no verb (census row
# `LazyFrame.rename`, EXPOSE_ONLY / T1).
#
# MEASURED against polars 1.44.2 and followed (the same rules the polars
# skin's `LazyFrame.rename` states):
#   * a name NOT in the frame RAISES (polars' `ColumnNotFoundError` under the
#     default `strict=True`);
#   * renaming onto a name another column KEEPS RAISES (polars'
#     `DuplicateError`: `{"k": "g"}` over [k, g, v]); a SWAP
#     (`{"k": "g", "g": "k"}`) is legal and answers [g, k, v];
#   * the column order is unchanged;
#   * a rename that changes nothing returns the plan as it was — no node.
# =============================================================================

from std.collections import Dict

from komira_plan_expr.expr import Expr
from komira_plan_ir.logical_plan import LogicalPlan, ExprArray


def build_rename_plan(
    var plan: LogicalPlan, mapping: Dict[String, String]
) raises -> LogicalPlan:
    """`plan` under a PROJECT renaming per `mapping` (see the header)."""
    ref schema = plan.output_schema
    var n = schema.num_columns()
    # Every key must name a column (polars strict=True).
    for item in mapping.items():
        var found = False
        for i in range(n):
            if schema.field_name(i) == item.key:
                found = True
                break
        if not found:
            raise Error(
                "PlanCarrier.rename: no column named `" + item.key
                + "` in this frame (polars raises ColumnNotFoundError)"
            )
    var out_names = List[String]()
    var changed = False
    for i in range(n):
        var old = schema.field_name(i)
        if old in mapping:
            var nw = mapping[old]
            if nw != old:
                changed = True
            out_names.append(nw)
        else:
            out_names.append(old)
    # Two output columns with one name (polars DuplicateError).
    for i in range(n):
        for j in range(i + 1, n):
            if out_names[i] == out_names[j]:
                raise Error(
                    "PlanCarrier.rename: column `" + out_names[i]
                    + "` would appear twice (polars raises DuplicateError);"
                    " a swap renames BOTH columns"
                )
    if not changed:
        return plan^
    var exprs = ExprArray()
    for i in range(n):
        var old = schema.field_name(i)
        if out_names[i] == old:
            exprs.append(Expr.col_ref(old))
        else:
            exprs.append(Expr.alias(Expr.col_ref(old), out_names[i]))
    return LogicalPlan.project(exprs^, plan^)
