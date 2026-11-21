# =============================================================================
# sdk/cast_to_varchar_insert.mojo
#   Put one cast-to-string node above a plan whose result a text sink writes.
# =============================================================================
#
# A text sink (CSV, JSONL, and their compressed forms) writes every column as
# text. `insert_cast_if_text_output` puts one `PLAN_CAST_TO_VARCHAR` node above
# the root of such a plan, so the conversion is one node at the top of the plan
# instead of work inside each sink. The node's output schema is the child's
# with every column typed STRING, names and nullability kept
# (`LogicalPlan.cast_to_varchar`).
#
# The rule only looks at the root. A root that already is a
# `PLAN_CAST_TO_VARCHAR` is left as it is, so applying the rule twice gives one
# cast. A plan whose sink writes Arrow-typed batches (Parquet, Arrow IPC, the
# in-memory and Arrow C stream results) is returned unchanged.
#
# The caller says whether its sink writes text: this module knows no sink type,
# so the plan layer does not depend on the sinks. Nothing calls it yet: the CSV
# and JSONL write sinks are its callers, and lowering refuses the node until
# they land (src/lowering/README.md).

from plan_ir.logical_plan import LogicalPlan, PLAN_CAST_TO_VARCHAR


def insert_cast_if_text_output(
    var plan: LogicalPlan, is_text_output: Bool
) -> LogicalPlan:
    """Return `plan` under one `PLAN_CAST_TO_VARCHAR` node when
    `is_text_output` is True and the root of `plan` is not already one;
    otherwise return `plan` unchanged.

    Args:
        plan: The plan whose result the sink writes. Taken by value: the
            caller gets the plan back, wrapped or not.
        is_text_output: True when the sink writes text (CSV, JSONL and their
            compressed forms).

    Returns:
        `LogicalPlan.cast_to_varchar(plan^)`, or `plan` itself.
    """
    if not is_text_output or plan.tag == PLAN_CAST_TO_VARCHAR:
        return plan^
    return LogicalPlan.cast_to_varchar(plan^)
