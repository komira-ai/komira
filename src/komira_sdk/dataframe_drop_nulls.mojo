# =============================================================================
# dataframe_drop_nulls — the untyped carrier's `drop_nulls`, polars'
# `LazyFrame.drop_nulls(subset=None)` (2026-09-24)
# =============================================================================
#
# `WHERE a IS NOT NULL AND b IS NOT NULL AND ...` over the named columns, or
# over EVERY column when no subset is given — the predicate the polars skin
# builds (`pl.py` `LazyFrame.drop_nulls`) and the SQL door asks. No engine node
# is new; the carrier had no verb (polars
# `LazyFrame.drop_nulls`). MEASURED against polars 1.44.2 and followed:
#   * a NaN is NOT null — its row is KEPT (pandas' `dropna` drops it; that is
#     the pandas door's own answer, not this one);
#   * `subset=[]` drops nothing (polars returns the frame unchanged, no node);
#   * a name NOT in the frame RAISES (polars' ColumnNotFoundError).
# =============================================================================

from komira_arrow.schema import Schema
from komira_plan_expr.expr import Expr, BIN_AND, UN_IS_NOT_NULL


def drop_nulls_predicate(
    schema: Schema, subset: List[String]
) raises -> Optional[Expr]:
    """The conjunction of `c IS NOT NULL` over `subset` (in its order), or
    `None` for an empty subset. RAISES on a name `schema` does not hold."""
    var acc = Optional[Expr]()
    for i in range(len(subset)):
        var found = False
        for j in range(schema.num_columns()):
            if schema.field_name(j) == subset[i]:
                found = True
                break
        if not found:
            raise Error(
                "PlanCarrier.drop_nulls: no column named `" + subset[i]
                + "` in this frame (polars raises ColumnNotFoundError)"
            )
        var nn = Expr.unary(UN_IS_NOT_NULL, Expr.col_ref(subset[i]))
        if acc:
            acc = Expr.binary(BIN_AND, acc.take(), nn^)
        else:
            acc = nn^
    return acc^


def every_column(schema: Schema) -> List[String]:
    """`schema`'s column names, in order — `drop_nulls()`'s default subset."""
    var out = List[String]()
    for j in range(schema.num_columns()):
        out.append(schema.field_name(j))
    return out^
