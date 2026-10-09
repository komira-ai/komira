# =============================================================================
# udf_execution_refusal.mojo — REFUSE a plan whose UDF this build cannot run.
# =============================================================================
#
# ⛔ THIS IS A REFUSAL, NOT A FEATURE. There is no column-side UDF execution
# path. Until there is, a plan node carrying a `UdfData` must DECLINE at the
# door rather than run the node's ORDINARY field, because that field is a
# SURROGATE the caller did not write:
#
#   `filter_with_udf`  -> `FilterData.predicate` is a `lit(true)` PLACEHOLDER
#   `project_with_udf` -> `ProjectData.exprs` are "placeholder col_refs"
#
# and the column side reads exactly those and never asks `has_udf()`. So the
# caller's UDF would be DISCARDED and the surrogate executed as if it were the
# query — a UDF filter would return EVERY ROW with a success code.
#
# THE GUARD IS AT THE DOOR because the surrogate fields are read in hundreds of
# places across the engine and almost none of them ask `has_udf()`; refusing the
# plan before any of them sees it is the fix, not teaching each site.
#
# Every other consumer of a UDF-carrying node already refuses it (the plan wire
# codec on encode and decode, the aggregate node, the typed direct stage), and
# they refuse on the `udf` FIELD, never on the predicate's CONTENTS, because a
# `lit(true)` placeholder passes any content check.
#
# ⚠ WHY THE GUARD RUNS BEFORE THE OPTIMIZER. No optimizer pass preserves a
# `UdfData`: the passes rebuild filters and projections with the non-UDF
# factories, and predicate push-down can delete a Filter outright after folding
# the `lit(true)` placeholder into the scan. By the time a later stage sees the
# plan, `has_udf()` is already False. The guard must run before the plan is
# prepared.
#
# ⚠ THE VOCABULARY IS COPIED, NOT IMPORTED. The token below is a literal
# because the plan endpoint package depends on the SDK, so the constant cannot
# be imported here without a cycle. A test in a package that can see both pins
# the copy against the real constant.
# =============================================================================

from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_CAST_TO_VARCHAR,
    PLAN_JOIN,
    PLAN_ASOF_JOIN,
    PLAN_UNION,
)


# ⛔ THIS REFUSAL IS DEBT. What makes it unnecessary is a column-side UDF
# execution entry for filter and map UDFs. ⇒ WHEN ONE EXISTS, DELETE THIS
# GUARD — do not "fix" it by narrowing.

comptime UDF_NODE_REFUSAL_TOKEN: String = "PLAN_ENDPOINT_UNSUPPORTED_UDF(11)"
"""The frozen-vocabulary token this refusal leads with, so a non-Mojo caller
can branch on the integer 11 rather than on English. `11` is the plan
endpoint's unsupported-UDF code, the one the wire codec's own UDF refusal maps
to. It is deliberately NOT a new code: this is the same refusal ("this plan
carries a UDF this build cannot honour") reaching the caller from the executor
instead of from the codec, and a second integer would make one condition
indistinguishable from two."""


def _udf_refusal(imm node_name: String, imm where: String) -> String:
    return (
        UDF_NODE_REFUSAL_TOKEN
        + ": "
        + where
        + " received a "
        + node_name
        + " node carrying a UdfData. There is no column-side UDF execution"
        + " path in this build, and the node's ordinary field is a PLACEHOLDER"
        + " the caller did not write (a `lit(true)` predicate; placeholder"
        + " col_refs) — executing it would DISCARD the UDF and return the"
        + " wrong rows with a success code. Drive the UDF stage directly,"
        + " which threads the UDF VALUE — the type-erased UdfData snapshot"
        + " carries only `F.UDF_ID`, never the instance's captured state."
    )


def refuse_udf_carrying_node(imm plan: LogicalPlan, imm where: String) raises:
    """Raise on the FIRST node in `plan` carrying a `UdfData`.

    Call this BEFORE any optimize pass — see the module header: the optimizer
    erases the evidence, so a later check silently passes.

    ⚠ SCOPE, STATED. `UdfData` rides on exactly three variants — FILTER,
    PROJECT and AGGREGATE (`LogicalPlan.has_udf()`) — so
    those are the only tags interrogated. The child enumeration below is the
    SAME one `lower_untyped._has_row_source_signal` walks, deliberately, so the
    two can be diffed by eye; a node reachable only through an edge kind absent
    from BOTH is invisible to BOTH, and that is the shared assumption to break
    if a new multi-child variant lands."""
    if plan.has_udf():
        var name = String("Filter")
        if plan.tag == PLAN_PROJECT:
            name = String("Project")
        elif plan.tag == PLAN_AGGREGATE:
            name = String("Aggregate")
        raise Error(_udf_refusal(name, where))

    var tag = plan.tag
    if tag == PLAN_FILTER and plan._filter:
        refuse_udf_carrying_node(plan.filter_data_ref().child[], where)
        return
    if tag == PLAN_PROJECT and plan._project:
        refuse_udf_carrying_node(plan.project_data_ref().child[], where)
        return
    if tag == PLAN_AGGREGATE and plan._aggregate:
        refuse_udf_carrying_node(plan.aggregate_data_ref().child[], where)
        return
    if tag == PLAN_SORT and plan._sort:
        refuse_udf_carrying_node(plan.sort_data_ref().child[], where)
        return
    if tag == PLAN_LIMIT and plan._limit:
        refuse_udf_carrying_node(plan.limit_data_ref().child[], where)
        return
    if tag == PLAN_DISTINCT and plan._distinct:
        refuse_udf_carrying_node(plan.distinct_data_ref().child[], where)
        return
    if tag == PLAN_TOPN and plan._topn:
        refuse_udf_carrying_node(plan.topn_data_ref().child[], where)
        return
    if tag == PLAN_PARTITION_BY and plan._partition_by:
        refuse_udf_carrying_node(plan.partition_by_data_ref().child[], where)
        return
    if tag == PLAN_PARTITION_TOPN and plan._partition_topn:
        refuse_udf_carrying_node(
            plan.partition_topn_data_ref().child[], where
        )
        return
    if tag == PLAN_CAST_TO_VARCHAR and plan._cast_to_varchar:
        refuse_udf_carrying_node(
            plan.cast_to_varchar_data_ref().child[], where
        )
        return
    if tag == PLAN_JOIN and plan._join:
        ref jd = plan.join_data_ref()
        refuse_udf_carrying_node(jd.left[], where)
        refuse_udf_carrying_node(jd.right[], where)
        return
    if tag == PLAN_ASOF_JOIN and plan._asof_join:
        ref ad = plan.asof_join_data_ref()
        refuse_udf_carrying_node(ad.left[], where)
        refuse_udf_carrying_node(ad.right[], where)
        return
    if tag == PLAN_UNION and plan._union:
        ref ud = plan.union_data_ref()
        for i in range(ud.num_children()):
            refuse_udf_carrying_node(ud.children[i][], where)
        return
