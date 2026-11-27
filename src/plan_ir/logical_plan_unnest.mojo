# =============================================================================
# logical_plan_unnest — the payload and schema rule of PLAN_UNNEST
# =============================================================================
#
# `PLAN_UNNEST` turns one LIST column of its child into one row per element:
# SQL `unnest(list)` and DataFrame `explode(column)` are both this node, and
# they differ in `keep_empty` alone. A row whose list is empty or NULL gives
# no row when `keep_empty` is False, and one row whose element is NULL when it
# is True.
#
# The output schema is the child's, with the field `column` replaced in place
# (same position, same name) by the list's element type. `unnest_output_schema`
# is that rule and the only place that raises for a column that cannot be
# unnested; `LogicalPlan.unnest` and the plan-wire decoder both build through
# it, so a node that exists always has a list column in its child.
#
# Kept out of `logical_plan.mojo` only for size. Like the variants, this module
# and `logical_plan.mojo` import each other; the recursive edge goes through
# `OwnedPointer[LogicalPlan]`.
# =============================================================================

from std.memory import OwnedPointer

from arrow.arrow_types import ArrowType
from arrow.schema import Field, Schema, SchemaBuilder
from plan_ir.logical_plan import LogicalPlan


struct UnnestData(Movable):
    """Payload for `LogicalPlan` tag `PLAN_UNNEST`.

    Fields:
        child: the input.
        column: the name of the LIST column of `child` that is unnested.
        keep_empty: when True a row whose list is empty or NULL yields one row
            with a NULL element; when False it yields no row.
    """

    var child: OwnedPointer[LogicalPlan]
    var column: String
    var keep_empty: Bool

    def __init__(
        out self, var child: LogicalPlan, column: String, keep_empty: Bool
    ):
        self.child = OwnedPointer(child^)
        self.column = column
        self.keep_empty = keep_empty

    def copy(self) -> Self:
        """Deep-clone (recurses into the child plan)."""
        return Self(self.child[].copy(), self.column, self.keep_empty)

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    def __deinit__(deinit self):
        pass


def unnest_output_schema(
    child_schema: Schema, column: String, keep_empty: Bool
) raises -> Schema:
    """The output schema of `Unnest(child, column, keep_empty)`: `child_schema`
    with the field `column` replaced in place by `Field(column, element type,
    element nullable or keep_empty)`; every other field is copied unchanged.

    RAISES, naming the column, when `child_schema` has no field `column`
    ("unnest: no column '<c>' in its input") or when that field is not a LIST
    with exactly one element type ("unnest: column '<c>' is <TYPE>, not a
    list").
    """
    var at = -1
    for i in range(child_schema.num_columns()):
        if child_schema.field_name(i) == column:
            at = i
            break
    if at < 0:
        raise Error("unnest: no column '" + column + "' in its input")
    var list_field = child_schema.field_at_unchecked(at)
    if (
        list_field.arrow_type != ArrowType.LIST
        or list_field.num_children() != 1
    ):
        raise Error(
            "unnest: column '"
            + column
            + "' is "
            + String(list_field.arrow_type)
            + ", not a list"
        )
    var builder = SchemaBuilder()
    for i in range(child_schema.num_columns()):
        if i == at:
            builder.add_field(
                Field(
                    column,
                    list_field.child_arrow_type(0),
                    list_field.child_nullable(0) or keep_empty,
                )
            )
        else:
            builder.add_field(child_schema.field_at_unchecked(i))
    return builder.build()
