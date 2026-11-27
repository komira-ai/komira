"""The plan of a melt (pandas' `DataFrame.melt`) and of an unpivot (polars'
`LazyFrame.unpivot`), which both skins build the same way: wide columns
turned into long rows with no plan node of their own.

For each value column, in the order given, one `Project` of the frame's plan
keeps the id columns, adds the column's name as a string literal under the
variable name, and the column itself under the value name; a `Union` stacks
the projections, so the answer holds every row of the frame once per value
column, a missing value kept as a missing value. One value column is its
projection and no union.

The engine's union takes inputs of one schema: the same names, types and
nullability (komira/_plan/_rel.py). So the value columns are of one type,
checked here and refused by name otherwise (pandas would make an object
column, and polars cast to a supertype; komira does neither). Columns of one
type that differ in allowing missing values are made to allow them alike: a
column that never holds one is read through a `try_cast` to its own type,
which the engine types as allowing them (`walk_expr_field`) and which changes
no value. Only the types `Cast` names a target for (the integers, floats and
bool) and strings take that cast; another type of mixed nullability is refused
by name.

The skins check their own arguments (komira/_frame.py, komira/pl/_frame.py)
and call `unpivot_plan` with the column names resolved.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence

from . import _ops
from ._errors import UnsupportedOperation

__all__ = ["unpivot_plan"]

# The types a column that never holds a missing value is cast to, as itself,
# to allow one: `Cast` targets by name, and strings by Arrow type.
_CAST_TARGETS = _ops.CAST_TARGETS
_ARROW_CASTS = frozenset({"string"})


def _type_key(field: object) -> tuple:
    """What makes two columns of one type to the engine's union: the Arrow
    type, a decimal's precision and scale, a timestamp's zone and a nested
    type's children."""
    return (
        field.arrow_type_id,
        field.decimal_precision,
        field.decimal_scale,
        field.tz,
        tuple(field.child_names),
        tuple(field.child_type_ids),
        tuple(field.child_nullables),
    )


def _allowing_missing(name: str, arrow: str, verb: str, other: str) -> _ops.Node:
    """The column `name`, of the Arrow type `arrow`, as an expression of that
    type that allows missing values."""
    column = _ops.ColRef(name)
    if arrow in _CAST_TARGETS:
        return _ops.Cast(column, arrow, True)
    if arrow in _ARROW_CASTS:
        return _ops.Cast(column, None, True, arrow=arrow)
    raise UnsupportedOperation(
        f"{verb}: the value column {name!r} never holds a missing value and {other!r} can, and the "
        "engine stacks only columns that allow missing values alike, which komira cannot make "
        f"{arrow} columns do yet"
    )


def unpivot_plan(
    plan: _ops.Plan,
    fields: Sequence[object],
    ids: Sequence[str],
    values: Sequence[str],
    variable_name: str,
    value_name: str,
    *,
    verb: str,
    type_text: Callable[[object], str],
) -> _ops.Plan:
    """The plan of the frame `plan`, whose output fields are `fields` (the
    encoder's `WireField`s), melted: the columns `ids`, `variable_name` and
    `value_name`, one block of rows per column of `values`, in their order.

    `ids` and `values` are distinct columns of the frame, `values` is not
    empty, and the output names are distinct; the skins check these. `verb`
    starts each refusal's message and `type_text` names a field's type in
    it."""
    from ._plan._wire import arrow_name

    by_name = {f.name: f for f in fields}
    first = by_name[values[0]]
    for name in values[1:]:
        other = by_name[name]
        if _type_key(other) != _type_key(first):
            raise UnsupportedOperation(
                f"{verb}: the value columns {values[0]!r} and {name!r} are of two types, "
                f"{type_text(first)} and {type_text(other)}, and the value column holds one type: "
                "cast them to one type first"
            )
    nullable = [name for name in values if by_name[name].nullable]
    branches = []
    for name in values:
        value: _ops.Node = _ops.ColRef(name)
        if nullable and not by_name[name].nullable:
            value = _allowing_missing(name, arrow_name(first.arrow_type_id), verb, nullable[0])
        items = tuple((n, _ops.ColRef(n)) for n in ids)
        items += ((variable_name, _ops.Lit(name)), (value_name, value))
        branches.append(_ops.Project(plan, items))
    return _ops.concat(branches)
