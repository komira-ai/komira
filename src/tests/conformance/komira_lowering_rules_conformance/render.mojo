# =============================================================================
# render: a case's footer list, and decisions rendered as table rows
# =============================================================================
#
# A rendering is the optimizer table's: every scan in pre-order as
# `scan#<i>: <column>:<bytes>:<base>,...`, with nothing after the colon when
# the scan narrows nothing, joined by ` | `; a plan with no scan renders as the
# empty string. A row is `<case> => <rendering>`, or `<case> =>` when the
# rendering is empty.
# =============================================================================

from komira_plan_expr.payload_narrow import PayloadNarrowSpec
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
    PLAN_CAST_TO_VARCHAR,
)
from komira_plan_stats.table_stats import TableStats


def _collect_stats(node: LogicalPlan, mut out: List[Optional[TableStats]]) raises:
    """Each scan's plan statistics in scan pre-order, by a walk written apart
    from the rule's (the tags the fixtures use)."""
    if node.tag == PLAN_SCAN:
        out.append(node.scan_data_ref().table_stats.copy())
    elif node.tag == PLAN_JOIN:
        _collect_stats(node.join_data_ref().left[], out)
        _collect_stats(node.join_data_ref().right[], out)
    elif node.tag == PLAN_ASOF_JOIN:
        _collect_stats(node.asof_join_data_ref().left[], out)
        _collect_stats(node.asof_join_data_ref().right[], out)
    elif node.tag == PLAN_UNION:
        ref kids = node.union_data_ref().children
        for i in range(len(kids)):
            _collect_stats(kids[i][], out)
    elif node.tag == PLAN_FILTER:
        _collect_stats(node.filter_data_ref().child[], out)
    elif node.tag == PLAN_PROJECT:
        _collect_stats(node.project_data_ref().child[], out)
    elif node.tag == PLAN_AGGREGATE:
        _collect_stats(node.aggregate_data_ref().child[], out)
    elif node.tag == PLAN_SORT:
        _collect_stats(node.sort_data_ref().child[], out)
    elif node.tag == PLAN_LIMIT:
        _collect_stats(node.limit_data_ref().child[], out)
    elif node.tag == PLAN_DISTINCT:
        _collect_stats(node.distinct_data_ref().child[], out)
    elif node.tag == PLAN_TOPN:
        _collect_stats(node.topn_data_ref().child[], out)
    elif node.tag == PLAN_PARTITION_BY:
        _collect_stats(node.partition_by_data_ref().child[], out)
    elif node.tag == PLAN_PARTITION_TOPN:
        _collect_stats(node.partition_topn_data_ref().child[], out)
    elif node.tag == PLAN_CAST_TO_VARCHAR:
        _collect_stats(node.cast_to_varchar_data_ref().child[], out)


def case_footers(plan: LogicalPlan) raises -> List[Optional[TableStats]]:
    """The footer list the host rule takes for `plan`: each scan's plan
    statistics, in scan pre-order."""
    var out = List[Optional[TableStats]]()
    _collect_stats(plan, out)
    return out^


def render(slots: List[List[PayloadNarrowSpec]]) -> String:
    """Every scan's specs in scan pre-order, as the optimizer table renders them."""
    var out = String()
    for s in range(len(slots)):
        if s > 0:
            out += " | "
        out += "scan#" + String(s) + ":"
        for i in range(len(slots[s])):
            out += " " if i == 0 else ","
            ref p = slots[s][i]
            out += p.column_name + ":" + String(Int(p.target_bytes)) + ":" + String(p.base)
    return out^


def row(name: String, rendering: String) -> String:
    """The table row of case `name`."""
    if rendering.byte_length() == 0:
        return name + " =>"
    return name + " => " + rendering
