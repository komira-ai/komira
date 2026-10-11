# =============================================================================
# Optimizer count-distinct -- the streaming COUNT(DISTINCT) aggregate shape
# =============================================================================
#
# `detect_count_distinct_agg_shape` recognises the aggregate a streaming
# COUNT(DISTINCT) sink can answer directly from a Parquet scan:
#
#   grouped:    Aggregate(keys = [one INT32 or INT64 column],
#                         aggs = [COUNT(DISTINCT col), ...],
#                         child = Scan(Parquet))
#   ungrouped:  Aggregate(keys = [],
#                         aggs = [COUNT(DISTINCT col), ...],
#                         child = Scan(Parquet))
#
# It reads the plan only (no Parquet statistics) and returns a decision; it
# does not rewrite the plan, and no pass in this package calls it. A caller
# that executes plans uses it to choose the COUNT(DISTINCT) route.
#
# The two column-type gates are the ones the sink states in
# `komira_agg_api.cd_distinct_key`: `cd_value_type_supported` for every
# counted column (the sink reads a value through an Int64 key channel, so a
# type it has no channel for must be declined, not counted at the wrong
# width) and `cd_key_column_type_supported` for the group key (the sink
# emits the key as INT32 or INT64 only).
# =============================================================================

from komira_agg_api.cd_distinct_key import (
    cd_key_column_type_supported,
    cd_value_type_supported,
)
from komira_arrow.schema import Schema
from komira_plan_expr.agg_expr import AGG_COUNT_DISTINCT
from komira_plan_expr.expr import Expr, EXPR_COL_REF, EXPR_ALIAS
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_AGGREGATE,
    PLAN_SCAN,
    SOURCE_PARQUET,
)


def _column_name_of(expr: Expr) -> String:
    """The column `expr` reads when it is a column reference or an alias
    over one; the empty string otherwise."""
    if expr.tag == EXPR_COL_REF:
        return expr.col_ref_name()
    if expr.tag == EXPR_ALIAS:
        ref child = expr.alias_child_ref()
        if child.tag == EXPR_COL_REF:
            return child.col_ref_name()
    return String("")


def _field_index(schema: Schema, name: String) -> Int:
    """The index of the first field of `schema` named `name`, or -1 (always
    -1 for the empty name, which `_column_name_of` returns for an
    expression that is not a column)."""
    if name == "":
        return -1
    for i in range(schema.num_columns()):
        if schema.field_name(i) == name:
            return i
    return -1


def detect_count_distinct_agg_shape(plan: LogicalPlan) -> Bool:
    """True iff `plan` is an Aggregate with no group key or one INT32 /
    INT64 column key, at least one aggregate and every aggregate a
    COUNT(DISTINCT) of a column the sink can read, directly over a Parquet
    scan.

    False for: a node that is not an Aggregate (or carries no payload); two
    or more group keys (a composite key needs another path); no aggregates;
    any aggregate other than COUNT(DISTINCT) (a mixed aggregate belongs to
    the general hash aggregate); a COUNT(DISTINCT) of no argument or of an
    expression that is not a column, or of a column the child does not
    output, or of a type `cd_value_type_supported` refuses; a key that is
    not a column, not in the child's output, or of a type
    `cd_key_column_type_supported` refuses; a child that is not a Parquet
    scan (a Filter between the scan and the aggregate breaks the
    direct-scan contract).
    """
    if plan.tag != PLAN_AGGREGATE or not plan._aggregate:
        return False
    ref agg = plan.aggregate_data_ref()
    var num_keys = len(agg.group_by)
    if num_keys > 1:
        return False
    if len(agg.agg_exprs) == 0:
        return False
    for a in range(len(agg.agg_exprs)):
        if agg.agg_exprs[a].func != AGG_COUNT_DISTINCT:
            return False

    ref child = agg.child[]
    if child.tag != PLAN_SCAN or not child._scan:
        return False
    if child.scan_data_ref().source_type != SOURCE_PARQUET:
        return False
    ref schema = child.output_schema

    for a in range(len(agg.agg_exprs)):
        ref arg = agg.agg_exprs[a].child
        if not arg:
            return False
        var idx = _field_index(schema, _column_name_of(arg.value()))
        if idx < 0:
            return False
        if not cd_value_type_supported(schema.field_arrow_type(idx)):
            return False

    if num_keys == 1:
        var key_idx = _field_index(schema, _column_name_of(agg.group_by[0]))
        if key_idx < 0:
            return False
        if not cd_key_column_type_supported(schema.field_arrow_type(key_idx)):
            return False
    return True
