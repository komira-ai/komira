# =============================================================================
# Schema Propagation — infer output schemas for LogicalPlan nodes
# =============================================================================
#
# Every LogicalPlan node computes its output_schema at construction time
# (in the factory methods). This module provides utility functions for
# external callers to re-derive schemas from plan nodes, which is useful
# for validation and optimizer passes that rewrite the plan tree.
#
# The propagation rules:
#   Scan     -> file schema, optionally projected
#   Filter   -> same schema as child (preserves columns)
#   Project  -> new schema from expression output types
#   Aggregate -> group_by columns + aggregate output columns
#   Join     -> merged schemas from both sides (semi/anti: left only); the
#               NULL-supplying side of LEFT/RIGHT/FULL is nullable
#   Sort     -> same schema as child
#   Limit    -> same schema as child
#   Distinct -> same schema as child
#
# It lives in core so callers that cannot reach the SDK layer (notably
# `komira_parquet`) can consume the canonical helper directly rather than
# maintaining a divergent local twin. `komira_sdk.schema_propagation`
# re-exports it.
# =============================================================================

from komira_arrow.schema import Schema, SchemaBuilder, Field
from komira_arrow.arrow_types import ArrowType
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
    PLAN_CAST_TO_VARCHAR,
    JOIN_SEMI,
    JOIN_ANTI,
    JOIN_LEFT,
    JOIN_RIGHT,
    JOIN_FULL,
)
from komira_plan_expr.expr import Expr, EXPR_COL_REF, EXPR_ALIAS
from komira_plan_ir.logical_plan import ExprArray
# Underscore-prefixed symbols are not re-exported by `import *` in the shim;
# import directly from the canonical module.
from komira_plan_ir.logical_plan import _infer_expr_field, _infer_agg_field


# =============================================================================
# Public API
# =============================================================================

def infer_schema(plan: LogicalPlan) raises -> Schema:
    """Recursively infer the output schema of a logical plan.

    This re-derives the schema from the plan structure. It should match
    the output_schema stored on the plan node (which is computed at
    construction time). This function is useful for validation: compare
    the stored schema against the re-derived schema to detect corruption
    or stale schemas after plan rewriting.

    Args:
        plan: The LogicalPlan node to infer the schema for.

    Returns:
        The inferred output Schema.

    Raises:
        Error if schema inference fails (e.g., column not found in child).

    Examples:
        ```mojo
        from komira_sdk import infer_schema, col
        from komira_plan_ir.logical_plan import LogicalPlan, SOURCE_PARQUET
        var scan = LogicalPlan.scan("data.parquet", SOURCE_PARQUET, schema^)
        var filtered = LogicalPlan.filter((col("age") > 25)^, scan^)
        var out = infer_schema(filtered)     # Filter passes the child schema through
        ```
    """
    if plan.tag == PLAN_SCAN:
        return _infer_scan_schema(plan)
    elif plan.tag == PLAN_FILTER:
        return _infer_filter_schema(plan)
    elif plan.tag == PLAN_PROJECT:
        return _infer_project_schema(plan)
    elif plan.tag == PLAN_AGGREGATE:
        return _infer_aggregate_schema(plan)
    elif plan.tag == PLAN_JOIN:
        return _infer_join_schema(plan)
    elif plan.tag == PLAN_SORT:
        return _infer_passthrough_schema(plan.sort_data_ref().child[])
    elif plan.tag == PLAN_LIMIT:
        return _infer_passthrough_schema(plan.limit_data_ref().child[])
    elif plan.tag == PLAN_DISTINCT:
        return _infer_passthrough_schema(plan.distinct_data_ref().child[])
    elif plan.tag == PLAN_TOPN:
        return _infer_passthrough_schema(plan.topn_data_ref().child[])
    elif plan.tag == PLAN_PARTITION_BY:
        # PartitionBy output schema is computed at construction time
        # (child columns + one per partition expression).
        return _copy_schema(plan.output_schema)
    elif plan.tag == PLAN_PARTITION_TOPN:
        # PartitionTopN preserves the child schema (selects rows, no new cols).
        return _infer_passthrough_schema(plan.partition_topn_data_ref().child[])
    elif plan.tag == PLAN_CAST_TO_VARCHAR:
        # cast_to_varchar: the STRING-typed mirror schema is
        # synthesized at factory construction time (per-column rewrite from
        # child schema). Return the stored schema directly — re-derivation
        # would just walk the child and rebuild the same shape.
        return _copy_schema(plan.output_schema)
    else:
        raise Error("infer_schema: unknown plan tag " + String(Int(plan.tag)))


def schema_num_columns(plan: LogicalPlan) -> Int:
    """Return the number of output columns for a plan node.

    Convenience wrapper around plan.output_schema.num_columns().
    """
    return plan.output_schema.num_columns()


def schema_column_name(plan: LogicalPlan, index: Int) -> String:
    """Return the name of output column at the given index.

    Convenience wrapper around plan.output_schema.field_name(index).
    """
    return plan.output_schema.field_name(index)


def schema_column_type(plan: LogicalPlan, index: Int) -> ArrowType:
    """Return the ArrowType of output column at the given index.

    Convenience wrapper around plan.output_schema.field_arrow_type(index).
    """
    return plan.output_schema.field_arrow_type(index)


def schema_from_project_exprs(
    source_schema: Schema, exprs: ExprArray
) raises -> Schema:
    """Derive the output Schema produced by applying `exprs` (as projection
    expressions) to `source_schema`.

    This is the standalone twin of `_infer_project_schema(plan)`: same
    rules, but does not require materializing a synthetic `LogicalPlan.project`
    node. Built for scan sites that need the post-projection schema for
    morsel sizing (e.g.
    `ctx.bulk_scan_morsel_rows(schema)` /
    `ctx.default_morsel_rows(schema)` need the SAME row-width-aware schema
    that the engine will actually emit downstream of the projection).

    Each output column's `(name, arrow_type, nullable, decimal_p/s,
    children)` is resolved by `_infer_expr_field(expr, source_schema)`,
    which is the same helper `LogicalPlan.project` invokes at construction
    time and `_infer_project_schema` invokes from a built plan.

    Pre-validation: a top-level `EXPR_COL_REF` (or an `EXPR_ALIAS` whose
    immediate child is an `EXPR_COL_REF`) is checked against the source
    schema BEFORE inference. If the named column is not in
    `source_schema`, this raises with a clear message naming the
    projection index and the missing column. (Deeper col_refs nested
    inside binary / unary ops follow `_infer_expr_field`'s pre-existing
    silent `ArrowType.NULL` placeholder behavior — same as the legacy
    `_infer_project_schema` plan path.)

    Args:
        source_schema: The input batch schema (the SCAN's output, or the
            output of whichever node sits below the projection).
        exprs: The projection expression list, one per output column.

    Returns:
        A fresh Schema with one field per expr in `exprs`.

    Raises:
        Error("schema_from_project_exprs: cannot resolve dtype for Expr at
        projection index N: column 'X' not in source schema [a, b, c]") on
        a top-level missing column ref.
    """
    var builder = SchemaBuilder()
    for i in range(len(exprs)):
        # Pre-validate top-level col_refs (also through one ALIAS layer)
        # against the source schema — surface a clear error before falling
        # through to `_infer_expr_field`'s silent NULL placeholder.
        var probe_tag = exprs[i].tag
        var probe_name = String("")
        var have_probe = False
        if probe_tag == EXPR_COL_REF:
            probe_name = exprs[i].col_ref_name()
            have_probe = True
        elif probe_tag == EXPR_ALIAS:
            ref child = exprs[i].alias_child_ref()
            if child.tag == EXPR_COL_REF:
                probe_name = child.col_ref_name()
                have_probe = True
        if have_probe:
            var found = False
            for k in range(source_schema.num_columns()):
                if source_schema.field_name(k) == probe_name:
                    found = True
                    break
            if not found:
                # Build a list of available column names for the error
                # message — small (typically <= 32 cols) and only walked
                # on the error path.
                var avail = String("[")
                for k in range(source_schema.num_columns()):
                    if k > 0:
                        avail += String(", ")
                    avail += source_schema.field_name(k)
                avail += String("]")
                raise Error(
                    String(
                        "schema_from_project_exprs: cannot resolve dtype"
                        " for Expr at projection index "
                    )
                    + String(i)
                    + String(": column '")
                    + probe_name
                    + String("' not in source schema ")
                    + avail
                )
        var field = _infer_expr_field(exprs[i], source_schema)
        builder.add_field(field^)
    return builder.build()


# =============================================================================
# Internal: per-node schema inference
# =============================================================================

def _copy_schema(schema: Schema) -> Schema:
    """Create a new Schema with the same fields as the input.

    Schema is Movable-only (no copy() method), so we rebuild it
    field-by-field using SchemaBuilder.

    Uses `Schema.field_at_unchecked(idx)`
    rather than the bare 3-arg `Field` ctor, so every metadata
    slot (`_tz`, decimal `(p, s)`, `_dict_index_type`, `_union_type_ids`,
    `_flags`, kv-metadata, nested children) is preserved across this
    SCAN / FILTER / SORT / LIMIT / DISTINCT / TOPN / PARTITION_BY
    output_schema re-derivation. Uses the non-raising `field_at_unchecked`
    sibling so the function signature stays non-raising — every callsite
    walks `range(num_columns())`, which is always in-range. Mirrors
    the engine-side `plan_compiler._copy_schema`.
    """
    var builder = SchemaBuilder()
    for i in range(schema.num_columns()):
        builder.add_field(schema.field_at_unchecked(i))
    return builder.build()


def _infer_scan_schema(plan: LogicalPlan) raises -> Schema:
    """Infer schema for a Scan node: return the stored output_schema."""
    return _copy_schema(plan.output_schema)


def _infer_filter_schema(plan: LogicalPlan) raises -> Schema:
    """Infer schema for a Filter node: same as child schema."""
    return _copy_schema(plan.filter_data_ref().child[].output_schema)


def _infer_project_schema(plan: LogicalPlan) raises -> Schema:
    """Infer schema for a Project node: derived from expression list."""
    # Access child schema by reference inline (Schema is not ImplicitlyCopyable)
    var builder = SchemaBuilder()
    for i in range(len(plan.project_data_ref().exprs)):
        var field = _infer_expr_field(
            plan.project_data_ref().exprs[i],
            plan.project_data_ref().child[].output_schema,
        )
        builder.add_field(field^)
    return builder.build()


def _infer_aggregate_schema(plan: LogicalPlan) raises -> Schema:
    """Infer schema for an Aggregate node: group_by keys + agg outputs."""
    # Access child schema by reference inline (Schema is not ImplicitlyCopyable)
    var builder = SchemaBuilder()
    # Group-by columns
    for i in range(len(plan.aggregate_data_ref().group_by)):
        var field = _infer_expr_field(
            plan.aggregate_data_ref().group_by[i],
            plan.aggregate_data_ref().child[].output_schema,
        )
        builder.add_field(field^)
    # Aggregate outputs
    for i in range(len(plan.aggregate_data_ref().agg_exprs)):
        var field = _infer_agg_field(
            plan.aggregate_data_ref().agg_exprs[i],
            plan.aggregate_data_ref().child[].output_schema,
        )
        builder.add_field(field^)
    return builder.build()


def _infer_join_schema(plan: LogicalPlan) raises -> Schema:
    """Infer schema for a Join node: left + right (or left only for semi/anti).

    Uses `Schema.field_at(idx)`
    on both sides — the cloned Field carries every metadata
    slot. For right-side collisions, clone-then-mutate `name` to apply
    the `_right` suffix without rebuilding the Field. Mirrors the
    engine-side `join_probe._build_join_output_schema`.
    """
    var jt = plan.join_data_ref().join_type
    # The NULL-supplying side of an outer join is nullable — the same rule as
    # `LogicalPlan.join` (see the note there).
    var left_nulls = jt == JOIN_RIGHT or jt == JOIN_FULL
    var right_nulls = jt == JOIN_LEFT or jt == JOIN_FULL
    var builder = SchemaBuilder()

    # Always include left-side columns (access schema by ref inline).
    # field_at_unchecked: in-range by construction; non-raising.
    for i in range(plan.join_data_ref().left[].output_schema.num_columns()):
        var lf = plan.join_data_ref().left[].output_schema.field_at_unchecked(i)
        if left_nulls:
            lf.nullable = True
        builder.add_field(lf^)

    # For non-semi/anti joins, also include right-side columns
    if jt != JOIN_SEMI and jt != JOIN_ANTI:
        for i in range(plan.join_data_ref().right[].output_schema.num_columns()):
            var rname = plan.join_data_ref().right[].output_schema.field_name(i)
            var has_collision = False
            for j in range(plan.join_data_ref().left[].output_schema.num_columns()):
                if plan.join_data_ref().left[].output_schema.field_name(j) == rname:
                    has_collision = True
                    break
            var rf = plan.join_data_ref().right[].output_schema.field_at_unchecked(i)
            if has_collision:
                rf.name = rname + "_right"
            if right_nulls:
                rf.nullable = True
            builder.add_field(rf^)

    return builder.build()


def _infer_passthrough_schema(child: LogicalPlan) raises -> Schema:
    """Infer schema for nodes that preserve child schema (Sort, Limit, Distinct)."""
    return _copy_schema(child.output_schema)
