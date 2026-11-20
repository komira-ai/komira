# =============================================================================
# optimizer_udf_opacity.mojo — when a predicate may move below a typed UDF
# =============================================================================
#
# A typed UDF rides on a Filter, Project or Aggregate as a `UdfData` payload
# (`optimizer_udf_carry` holds the rebuild helpers). The node's own expressions
# are placeholders: a UDF Project's `exprs` are col-refs naming the columns the
# UDF writes and the columns it passes through. This module answers one
# question for predicate pushdown: may `Filter(pred)` above a UDF Project move
# below it?
#
# The rule is `docs/design/optimized_plan_udfs.md` section 10.9, read for
# `UdfData`: a predicate that does not read the UDF's output may move below
# it, unless the UDF is `VOLATILE`; a predicate that reads the output stays
# above. Pushing a filter below the UDF changes which rows the UDF sees, so
# this module also asks that the UDF's result on a row does not depend on the
# other rows it saw (`UDF_PAR_STATELESS`).
#
# `UDF_KIND_MAP` is the per-row `MapFn` (one output row per input row). A
# `MAP_BATCHES_FRAME` function is a separate `PLAN_MAP_BATCHES` node, which
# this module never sees; section 10.9 stops pushdown there.
#
# * `udf_modified_columns(udf)` — the columns the UDF adds or rewrites: every
#   name in `udf.output_columns`. A name the UDF writes may also be a column
#   of the child (`map` that rewrites `b`); the Project then names it with a
#   plain `ColRef(b)` that looks like a passthrough and is not one.
# * `udf_opacity_opaque_to_predicate_pushdown(udf)` — True when no predicate
#   may move below the node at all: not a `MAP` UDF, not stateless, volatile,
#   or no declared output column (so what it writes is unknown).
# * `udf_supports_input_passthrough(udf, col)` — True when the UDF passes
#   `col` through unchanged, so a predicate on `col` means the same below it.
# * `udf_project_passes_predicate(plan, pred)` — the plan-level check
#   `optimizer_filter.push_predicates_down` calls on a UDF-carrying Project.
#
# A Project that passes a predicate down is rebuilt with
# `optimizer_udf_carry.project_like`; the non-UDF factory deletes the UDF.
# =============================================================================

from std.collections import Set

from plan_expr.expr import Expr, EXPR_COL_REF
from plan_expr.expr_walk import walk_expr_column_refs, ordered_name_sink
from plan_expr.udf_data import (
    UdfData,
    UDF_KIND_MAP,
    UDF_PAR_STATELESS,
    UDF_STABILITY_VOLATILE,
)
from plan_ir.logical_plan import LogicalPlan, PLAN_PROJECT


def udf_modified_columns(udf: UdfData) -> Set[String]:
    """The names of the columns `udf` adds or rewrites: every output column."""
    var s = Set[String]()
    for i in range(len(udf.output_columns)):
        s.add(udf.output_columns[i][0])
    return s^


def udf_opacity_opaque_to_predicate_pushdown(udf: UdfData) -> Bool:
    """True when no predicate may move below a node carrying `udf`.

    It may move only below a `MAP` UDF that is stateless (its result on a row
    does not depend on the other rows it sees), not volatile (section 10.9),
    and declares at least one output column (with none, what it writes is
    unknown)."""
    if udf.kind != UDF_KIND_MAP:
        return True
    if udf.parallelism_tag != UDF_PAR_STATELESS:
        return True
    if udf.stability == UDF_STABILITY_VOLATILE:
        return True
    return len(udf.output_columns) == 0


def udf_supports_input_passthrough(udf: UdfData, col: String) -> Bool:
    """True when `udf` passes `col` through unchanged: the node is not opaque
    and `col` is not a column it writes. Whether the UDF reads `col` does not
    matter; a column it ignores passes through as well."""
    if udf_opacity_opaque_to_predicate_pushdown(udf):
        return False
    return not (col in udf_modified_columns(udf))


def udf_project_passes_predicate(plan: LogicalPlan, pred: Expr) -> Bool:
    """True when `Filter(pred)` above `plan` may move below it unchanged:
    `plan` is a Project carrying a UDF that is not opaque
    (`udf_opacity_opaque_to_predicate_pushdown`), and every column `pred`
    reads (there may be none) is, at its
    first position in the Project's output, a plain `ColRef` of the same child
    column that the UDF passes through. False for any other node, and for a
    Project flagged `is_cse_introduced`.

    An `Alias(ColRef(x), n)` is not taken: the placeholders are not
    expressions to substitute, so only a column the Project hands on by its
    own name means the same below it."""
    if plan.tag != PLAN_PROJECT or not plan.has_udf():
        return False
    ref proj = plan.project_data_ref()
    # A CSE-introduced Project is a barrier of its own, and `project_like`
    # would drop the flag.
    if proj.is_cse_introduced:
        return False
    ref udf = proj.udf.value()[]
    # First, so a predicate that reads no column does not pass an opaque UDF.
    if udf_opacity_opaque_to_predicate_pushdown(udf):
        return False
    ref child_schema = proj.child[].output_schema
    var names = List[String]()
    var sink = ordered_name_sink(names)
    walk_expr_column_refs(pred, sink)
    # The Project's output schema is built from `exprs`, one field each.
    var width = min(plan.output_schema.num_columns(), len(proj.exprs))
    for i in range(len(names)):
        var at = -1
        for c in range(width):
            if plan.output_schema.field_name(c) == names[i]:
                at = c
                break
        if at < 0:
            return False
        # The field name is the ColRef's own name, so the tag is the check.
        if proj.exprs[at].tag != EXPR_COL_REF:
            return False
        var in_child = False
        for c in range(child_schema.num_columns()):
            if child_schema.field_name(c) == names[i]:
                in_child = True
                break
        if not in_child:
            return False
        if not udf_supports_input_passthrough(udf, names[i]):
            return False
    return True
