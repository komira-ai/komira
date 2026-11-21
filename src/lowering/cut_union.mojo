# =============================================================================
# cut_union -- the cutter's PLAN_UNION arm: one segment per branch and a
# concatenation of their outputs
# =============================================================================
#
# A UNION ALL is the rows of its branches, branch 1 first. Each branch is cut
# as a plan of its own and ends in a segment: a branch whose top is an
# aggregation or a sort with nothing fused after it is that breaker's segment,
# and any other branch ends in a SINK_COLLECT segment. The union then opens a
# pipeline whose source is SOURCE_CONCAT over those segments, in branch order,
# with one E3 edge to each. Filters, projections and limits above the union
# fuse onto that pipeline, and an aggregation or a sort above it closes it.
#
# Refused (LOWERING_UNCUTTABLE_NODE), before any branch is walked: a union with
# no branch, and a branch whose output schema is not the union's (the column
# count, and per column the name, the Arrow type, the decimal precision and
# scale and the timezone). The concatenation reads every branch's batch by
# position and keeps the first branch's names, so a branch of another layout
# would be read as if it had the union's. The SQL binder casts and renames the
# branches to the union's schema; this check holds every producer of a plan to
# that. Nullability is not compared: the concatenation merges the validity of
# its inputs.
# =============================================================================

from arrow.schema import Schema
from lowering.cut_state import _Cutter, _Pipe, _uncuttable
from lowering.lowered_plan import LoweringInputs
from plan_ir.logical_plan import LogicalPlan
from physical_plan.physical_plan import (
    SourceSpecPod,
    SOURCE_CONCAT,
    EDGE_E3_PUBLISH_WAIT,
    SINK_COLLECT,
    SINK_ORIENT_COLUMNAR,
    KEY_DTYPE_NONE,
)


def _column_text(schema: Schema, col: Int) -> String:
    """`name TYPE` of column `col`, with a decimal's precision and scale and a
    timestamp's timezone."""
    var out = String("`") + schema.field_name(col) + "` " + String(
        schema.field_arrow_type(col)
    )
    if schema.field_decimal_precision(col) != 0:
        out += (
            "("
            + String(schema.field_decimal_precision(col))
            + ", "
            + String(schema.field_decimal_scale(col))
            + ")"
        )
    if schema.field_tz(col) != "":
        out += " tz=" + schema.field_tz(col)
    return out^


def _schema_difference(want: Schema, got: Schema) -> String:
    """How `got` differs from `want` in layout, or "" when it does not."""
    if got.num_columns() != want.num_columns():
        return (
            String("has ")
            + String(got.num_columns())
            + " columns and the union "
            + String(want.num_columns())
        )
    for c in range(want.num_columns()):
        if (
            got.field_name(c) != want.field_name(c)
            or got.field_arrow_type(c) != want.field_arrow_type(c)
            or got.field_decimal_precision(c) != want.field_decimal_precision(c)
            or got.field_decimal_scale(c) != want.field_decimal_scale(c)
            or got.field_tz(c) != want.field_tz(c)
        ):
            return (
                String("column ")
                + String(c + 1)
                + " is "
                + _column_text(got, c)
                + " and the union's is "
                + _column_text(want, c)
            )
    return String("")


def _check_union(node: LogicalPlan) raises:
    """Refuse a union with no branch or a branch of another layout. Called
    before any branch is walked."""
    ref ud = node.union_data_ref()
    if len(ud.children) == 0:
        raise _uncuttable(node, "a union with no branch")
    for b in range(len(ud.children)):
        var why = _schema_difference(
            node.output_schema, ud.children[b][].output_schema
        )
        if why != "":
            raise _uncuttable(
                node,
                "branch "
                + String(b + 1)
                + " "
                + why
                + "; the concatenation reads every branch in the union's"
                " layout",
            )


def _end_branch(
    mut cutter: _Cutter, var pipe: _Pipe, inputs: LoweringInputs
) -> Int:
    """The segment whose output is the branch: the breaker's own segment when
    the branch is a breaker's output with nothing fused after it, and otherwise
    a SINK_COLLECT segment that ends the branch's pipeline."""
    if pipe.broken_by >= 0:
        return pipe.broken_by
    return cutter._close(
        pipe^, SINK_COLLECT, KEY_DTYPE_NONE, SINK_ORIENT_COLUMNAR, -1, inputs
    )


def _open_concat(node: LogicalPlan, producers: List[Int]) -> _Pipe:
    """The pipeline that reads the outputs of `producers`, in that order, as
    the union's rows."""
    var pipe = _Pipe(
        SOURCE_CONCAT,
        SourceSpecPod.concat(producers.copy()),
        node.output_schema.copy(),
        -1,
    )
    for i in range(len(producers)):
        pipe.deps.append(producers[i])
        pipe.edge_tags.append(EDGE_E3_PUBLISH_WAIT)
    return pipe^
