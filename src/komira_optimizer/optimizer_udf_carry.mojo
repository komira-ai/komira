# =============================================================================
# UDF-carrying nodes: rebuild them without losing the UDF, and read their
# input columns
# =============================================================================
#
# A typed UDF rides on a Filter, Project or Aggregate as a `UdfData` payload
# (`FilterData.udf`, `ProjectData.udf`, `AggregateData.udf`). The node's own
# expressions are the placeholders the UDF path stamps (`lit(true)` on a
# Filter, col-refs naming the UDF's output on a Project); the UDF decides what
# the node computes.
#
# Two facts every rule must respect:
#
# 1. `LogicalPlan.filter`, `.project` and `.aggregate` build a node with NO
#    UDF. A rule that walks through a node and rebuilds it around a new child
#    with one of them deletes the customer's function and leaves the
#    placeholders to run in its place. `filter_like`, `project_like` and
#    `aggregate_like` rebuild a node with the UDF of the node they replace.
# 2. `UdfData.input_columns` are the columns the UDF reads (its read set,
#    `docs/design/udf_runtime_interface.md` section 3.1), present on every UDF
#    in this IR and possibly empty. The placeholders do not name them, so a
#    rule that decides what a node reads from its expressions alone misses
#    them. `collect_udf_input_columns` adds them.
#
# The helpers carry `udf` and nothing else the plain factory drops. A
# Project's `is_cse_introduced` is reset, as the plain factory resets it
# (`plan_helpers._copy_plan` keeps it; komira#1538). An Aggregate's
# `estimated_groups` and `group_topk` are dropped, as `_copy_plan` drops
# them.
# =============================================================================

from std.collections import Set
from std.memory import OwnedPointer

from komira_plan_expr.expr import Expr
from komira_plan_expr.udf_data import UdfData
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    ExprArray,
    AggExprArray,
    FilterData,
    ProjectData,
    AggregateData,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
)


def filter_like(
    src: FilterData, var predicate: Expr, var child: LogicalPlan
) -> LogicalPlan:
    """A Filter over `child` with `predicate` and the UDF of `src`, if any."""
    if src.udf:
        return LogicalPlan.filter_with_udf(
            predicate^, child^, OwnedPointer(src.udf.value()[].copy())
        )
    return LogicalPlan.filter(predicate^, child^)


def project_like(
    src: ProjectData, var exprs: ExprArray, var child: LogicalPlan
) -> LogicalPlan:
    """A Project over `child` with `exprs` and the UDF of `src`, if any."""
    if src.udf:
        return LogicalPlan.project_with_udf(
            exprs^, child^, OwnedPointer(src.udf.value()[].copy())
        )
    return LogicalPlan.project(exprs^, child^)


def aggregate_like(
    src: AggregateData,
    var group_by: ExprArray,
    var agg_exprs: AggExprArray,
    var child: LogicalPlan,
) -> LogicalPlan:
    """An Aggregate over `child` with `group_by`, `agg_exprs` and the UDF of
    `src`, if any."""
    if src.udf:
        return LogicalPlan.aggregate_with_udf(
            group_by^, agg_exprs^, child^, OwnedPointer(src.udf.value()[].copy())
        )
    return LogicalPlan.aggregate(group_by^, agg_exprs^, child^)


def collect_udf_input_columns(plan: LogicalPlan, mut cols: Set[String]):
    """Add the input columns of the UDF `plan` carries to `cols`; a node with
    no UDF adds nothing."""
    if plan.tag == PLAN_FILTER and plan._filter.value()[].udf:
        _add_input_columns(plan._filter.value()[].udf.value()[], cols)
    elif plan.tag == PLAN_PROJECT and plan._project.value()[].udf:
        _add_input_columns(plan._project.value()[].udf.value()[], cols)
    elif plan.tag == PLAN_AGGREGATE and plan._aggregate.value()[].udf:
        _add_input_columns(plan._aggregate.value()[].udf.value()[], cols)


def _add_input_columns(udf: UdfData, mut cols: Set[String]):
    for i in range(len(udf.input_columns)):
        cols.add(udf.input_columns[i][0])
