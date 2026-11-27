"""The verbs the DataFrame skins call to grow a plan.

Each verb takes a plan and plain Python arguments (lists or tuples), checks
them, and returns a new plan node, or the same plan when the verb changes
nothing. Wrong argument types raise `TypeError`; unknown columns raise
`KeyError` with the message of `unknown_column`.

A `Sort` stays the root of the plan where it can: `filter_` goes below it, and
`select`, `with_columns` and `rename` go below it when every sort key reaches
the output under its own name. Nothing goes below a `TopN` or a `Limit`.
"""

from __future__ import annotations

from collections.abc import Sequence

from ._columns import require_columns
from ._expr import ColRef, Node, UdfSpec, Unary, and_all
from ._rel import (
    PLAN_NODES,
    Agg,
    Aggregate,
    Distinct,
    Field,
    Filter,
    Join,
    Limit,
    MapBatches,
    Plan,
    Project,
    Scan,
    Sort,
    SortKey,
    TopN,
    Union,
    Unnest,
    Write,
    WriteTarget,
)

__all__ = [
    "aggregate",
    "concat",
    "distinct",
    "drop_nulls",
    "filter_",
    "join",
    "limit",
    "map_batches",
    "rename",
    "scan",
    "select",
    "sort",
    "top_n",
    "unnest",
    "with_columns",
    "write",
]


def _plan(value: object, what: str) -> Plan:
    if not isinstance(value, PLAN_NODES):
        raise TypeError(f"{what} must be a plan node, not {type(value).__name__}")
    return value


def _seq(value: object, what: str) -> tuple:
    if isinstance(value, (list, tuple)):
        return tuple(value)
    raise TypeError(f"{what} must be a list or tuple, not {type(value).__name__}")


def _names(value: object, what: str) -> tuple[str, ...]:
    names = _seq(value, what)
    for name in names:
        if not isinstance(name, str):
            raise TypeError(f"{what} must hold str values, not {type(name).__name__}")
    return names


def _pairs(value: object, what: str) -> tuple[tuple[str, object], ...]:
    pairs = []
    for item in _seq(value, what):
        if not isinstance(item, (list, tuple)) or len(item) != 2:
            raise TypeError(f"{what} must hold (name, value) pairs")
        name, inner = item
        if not isinstance(name, str):
            raise TypeError(f"{what} names must be str, not {type(name).__name__}")
        pairs.append((name, inner))
    return tuple(pairs)


def scan(path: str, format: str, schema: Sequence[object]) -> Scan:
    """A `Scan`; `schema` holds `Field` values or (name, dtype) pairs."""
    fields = []
    for item in _seq(schema, "scan schema"):
        if isinstance(item, Field):
            fields.append(item)
        elif isinstance(item, (list, tuple)) and len(item) == 2:
            fields.append(Field(item[0], item[1]))
        else:
            raise TypeError("scan schema must hold Field values or (name, dtype) pairs")
    return Scan(path, format, tuple(fields))


def filter_(plan: Plan, predicate: Node) -> Plan:
    """A `Filter`; over a `Sort` the filter goes under it."""
    _plan(plan, "filter plan")
    if isinstance(plan, Sort):
        return Sort(filter_(plan.child, predicate), plan.keys)
    return Filter(plan, predicate)


def select(plan: Plan, columns: Sequence[str]) -> Plan:
    """A `Project` of the named columns, or the plan itself when it already is those.

    Over a `Sort` whose keys are all selected, the `Project` goes under the sort.
    """
    _plan(plan, "select plan")
    names = _names(columns, "select columns")
    if not names:
        raise ValueError("select needs at least one column")
    require_columns(names, plan.columns)
    if names == plan.columns:
        return plan
    if isinstance(plan, Sort) and all(key.column in names for key in plan.keys):
        return Sort(select(plan.child, names), plan.keys)
    return Project(plan, tuple((name, ColRef(name)) for name in names))


def with_columns(plan: Plan, items: Sequence[tuple[str, Node]]) -> Plan:
    """A `Project` that keeps every column, replacing or appending the derived ones.

    Over a `Sort` whose keys none of the items replaces, the `Project` goes under
    the sort.
    """
    _plan(plan, "with_columns plan")
    derived = _pairs(items, "with_columns items")
    if not derived:
        return plan
    seen: set[str] = set()
    for name, _ in derived:
        if name in seen:
            raise ValueError(
                f"with_columns: the output name '{name}' is produced by more than one expression"
            )
        seen.add(name)
    by_name = dict(derived)
    if isinstance(plan, Sort) and all(
        by_name.get(key.column, ColRef(key.column)) == ColRef(key.column)
        for key in plan.keys
    ):
        return Sort(with_columns(plan.child, derived), plan.keys)
    out: list[tuple[str, Node]] = []
    for column in plan.columns:
        out.append((column, by_name[column] if column in by_name else ColRef(column)))
    out.extend((name, expr) for name, expr in derived if name not in plan.columns)
    return Project(plan, tuple(out))


def rename(plan: Plan, mapping: dict[str, str]) -> Plan:
    """A `Project` giving columns new names, or the plan itself when no name changes.

    Over a `Sort` whose keys are all kept by name, the `Project` goes under the sort.
    """
    _plan(plan, "rename plan")
    if not isinstance(mapping, dict):
        raise TypeError(f"rename mapping must be a dict, not {type(mapping).__name__}")
    for old, new in mapping.items():
        if not isinstance(old, str) or not isinstance(new, str):
            raise TypeError("rename mapping must map str to str")
    require_columns(tuple(mapping), plan.columns)
    if all(old == new for old, new in mapping.items()):
        return plan
    if isinstance(plan, Sort) and all(
        mapping.get(key.column, key.column) == key.column for key in plan.keys
    ):
        return Sort(rename(plan.child, mapping), plan.keys)
    seen: set[str] = set()
    items = []
    for column in plan.columns:
        new = mapping.get(column, column)
        if new in seen:
            raise ValueError(f"rename: the column '{new}' would appear twice")
        seen.add(new)
        items.append((new, ColRef(column)))
    return Project(plan, tuple(items))


def drop_nulls(plan: Plan, subset: Sequence[str] | None = None) -> Plan:
    """A `Filter` keeping rows with no null in the subset (every column when None)."""
    _plan(plan, "drop_nulls plan")
    names = plan.columns if subset is None else _names(subset, "drop_nulls subset")
    if not names:
        return plan
    require_columns(names, plan.columns)
    predicate = and_all(tuple(Unary("is_not_null", ColRef(name)) for name in names))
    return filter_(plan, predicate)


def _sort_keys(keys: object, what: str) -> tuple[SortKey, ...]:
    out = _seq(keys, what)
    for key in out:
        if not isinstance(key, SortKey):
            raise TypeError(f"{what} must hold SortKey values, not {type(key).__name__}")
    return out


def sort(plan: Plan, keys: Sequence[SortKey]) -> Plan:
    """A `Sort`; sorting a sorted plan replaces the inner sort."""
    _plan(plan, "sort plan")
    ordered = _sort_keys(keys, "sort keys")
    if isinstance(plan, Sort):
        return Sort(plan.child, ordered)
    return Sort(plan, ordered)


def limit(plan: Plan, n: int, offset: int = 0) -> Limit:
    """A `Limit`."""
    return Limit(_plan(plan, "limit plan"), n, offset)


def top_n(plan: Plan, keys: Sequence[SortKey], n: int) -> TopN:
    """A `TopN`."""
    return TopN(_plan(plan, "top_n plan"), _sort_keys(keys, "top_n keys"), n)


def distinct(plan: Plan, subset: Sequence[str] | None = None) -> Distinct:
    """A `Distinct` over every column, or over the subset."""
    _plan(plan, "distinct plan")
    names = None if subset is None else _names(subset, "distinct subset")
    return Distinct(plan, names)


def aggregate(
    plan: Plan, keys: Sequence[str], aggs: Sequence[tuple[str, Agg]]
) -> Aggregate:
    """An `Aggregate` over the key columns with named aggregates."""
    _plan(plan, "aggregate plan")
    return Aggregate(
        plan, _names(keys, "aggregate keys"), _pairs(aggs, "aggregate aggs")
    )


def join(
    left: Plan,
    right: Plan,
    how: str,
    left_on: Sequence[str] = (),
    right_on: Sequence[str] = (),
    residual: Node | None = None,
) -> Join:
    """A `Join`."""
    return Join(
        _plan(left, "join left"),
        _plan(right, "join right"),
        how,
        _names(left_on, "join left_on"),
        _names(right_on, "join right_on"),
        residual,
    )


def concat(plans: Sequence[Plan]) -> Plan:
    """A `Union` of the plans, or the plan itself when there is one."""
    inputs = _seq(plans, "concat plans")
    if not inputs:
        raise ValueError("concat needs at least one frame")
    for item in inputs:
        _plan(item, "concat plans")
    if len(inputs) == 1:
        return inputs[0]
    return Union(inputs)


def write(plan: Plan, path: str, format: str) -> Write:
    """A `Write` of the plan to a path."""
    return Write(_plan(plan, "write plan"), WriteTarget(path, format))


def map_batches(plan: Plan, udf: UdfSpec) -> MapBatches:
    """A `MapBatches` of the `map_batches_frame` function over the plan."""
    return MapBatches(_plan(plan, "map_batches plan"), udf)


def unnest(plan: Plan, column: str, keep_empty: bool) -> Unnest:
    """An `Unnest` of the plan's list column, one row per element."""
    return Unnest(_plan(plan, "unnest plan"), column, keep_empty)
