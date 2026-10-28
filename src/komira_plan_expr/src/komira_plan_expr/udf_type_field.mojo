# =============================================================================
# udf_type_field — `UdfType` to and from the engine's `Field`
# =============================================================================
#
# `UdfType` nests to any depth; `Field` stores one level of children (a name,
# a type id and a nullability each, nothing deeper). These two conversions
# are the only bridge between them, kept out of `udf_type.mojo` so that that
# module stays a leaf `expr.mojo` can import (see its header).
#
#   * `field_to_udf_type` is exact: every fact of the `Field` lands, and its
#     flat children become children with no children of their own.
#   * `udf_type_to_field` is exact for a type of depth 1 or 2. For a deeper
#     type it keeps the first level of children and drops what is below it,
#     because `Field` has nowhere to put it. A caller that must not lose a
#     level checks `UdfType.depth()` first: the plan-wire decoder refuses a
#     node output column deeper than a `Field` holds.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.schema import Field

from komira_plan_expr.udf_type import UdfType


def field_to_udf_type(f: Field) -> UdfType:
    """Every fact of `f`, its flat children as leaf children."""
    var kids = List[UdfType]()
    for i in range(len(f._child_names)):
        var t = ArrowType(f._child_types[i])
        kids.append(
            UdfType(
                f._child_names[i].copy(), t, _dtype_of(t),
                f._child_nullables[i],
            )
        )
    var u = UdfType(f.name.copy(), f.arrow_type, f.dtype, f.nullable, kids^)
    u.decimal_precision = f.decimal_precision
    u.decimal_scale = f.decimal_scale
    u.tz = f._tz.copy()
    u.dict_index_type = f._dict_index_type
    u.union_type_ids = f._union_type_ids.copy()
    u.flags = f._flags
    u.metadata_keys = f._metadata_keys.copy()
    u.metadata_values = f._metadata_values.copy()
    return u^


def udf_type_to_field(t: UdfType) -> Field:
    """`t` as a `Field`: its own facts, and its first level of children as the
    field's flat child lists (each child's name, type id and nullability).
    Exact when `t.depth() <= 2`."""
    var f = Field(t.name.copy(), t.arrow_type, t.nullable)
    f.dtype = t.dtype
    f.decimal_precision = t.decimal_precision
    f.decimal_scale = t.decimal_scale
    f._tz = t.tz.copy()
    f._dict_index_type = t.dict_index_type
    f._union_type_ids = t.union_type_ids.copy()
    f._flags = t.flags
    f._metadata_keys = t.metadata_keys.copy()
    f._metadata_values = t.metadata_values.copy()
    var names = List[String]()
    var types = List[UInt8]()
    var nulls = List[Bool]()
    for i in range(len(t.children)):
        names.append(t.children[i].name.copy())
        types.append(t.children[i].arrow_type.type_id)
        nulls.append(t.children[i].nullable)
    f._child_names = names^
    f._child_types = types^
    f._child_nullables = nulls^
    return f^


def _dtype_of(t: ArrowType) -> DType:
    """The `DType` a `Field` built from `t` alone carries: a flat child keeps
    a type id and nothing else, so its `DType` is the one `Field`'s arrow
    constructor derives."""
    return Field(String(""), t, True).dtype
