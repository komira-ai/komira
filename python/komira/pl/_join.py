"""`LazyFrame.join`: the plan's JOIN, under the projections that give polars'
output columns (rules section 8, ruling 8).

The plan's join keeps the left names and suffixes a right name the left has
with `_right`. polars names the output itself, so the right input is renamed
first, every column to the name polars gives it (or, for a key polars drops,
to a name of its own), and the plan's join never renames. A projection over
the join then gives polars' columns in polars' order:

- `inner` and `left`: the left columns, then the right ones but the keys,
  which are the left keys' (`coalesce=True`, the default). With
  `coalesce=False` the right keys stay;
- `full`: the left columns, then every right one (`coalesce=False`, the
  default); with `coalesce=True` each key is the left key, or the right one
  where the left is null, under the left name, and the right keys go;
- `right`: the left columns but the keys, then every right one, in polars'
  layout. A column of one name on both sides but the keys is refused, as is
  `coalesce=False`;
- `semi` and `anti`: the left columns;
- `cross`: the left columns, then every right one; it takes no keys.

A right column whose name the left output has is named with `suffix`; a name
that is then still taken is refused, as polars refuses it. Keys are column
names, or `col(name)`; their types must be equal on both sides. A null key
matches nothing (ruling 7): `nulls_equal=True` is refused, as are `validate`
other than `"m:m"` and a `maintain_order` other than `"none"`, since a join
promises no row order. The frame is unordered.
"""

from __future__ import annotations

from komira._errors import UnsupportedOperation
from komira._ops import ColRef, Join, Project, rename

__all__ = ["join"]

_HOWS = ("inner", "left", "right", "full", "semi", "anti", "cross")


def _keys(frame, value) -> tuple[str, ...]:
    from ._group import group_keys

    if value is None:
        return ()
    return group_keys(frame, "join", (value,))


def _fresh(base: str, taken: set) -> str:
    name = f"__komira_{base}"
    while name in taken:
        name = "_" + name
    taken.add(name)
    return name


def join(left, other, on, how, left_on, right_on, suffix, validate, nulls_equal, coalesce, maintain_order):
    from ._frame import LazyFrame, _encoder

    if not isinstance(other, LazyFrame):
        raise TypeError(f"join takes a komira.pl LazyFrame, not {type(other).__name__}")
    if how not in _HOWS:
        raise ValueError(f"join: how must be one of {', '.join(map(repr, _HOWS))}, not {how!r}")
    if other._session is not left._session:
        raise UnsupportedOperation(
            "join: the other frame runs on another session than this one; frames of two "
            "sessions never meet"
        )
    if nulls_equal is not False:
        raise UnsupportedOperation(
            "join: nulls_equal=True is not supported: in a plan a null key matches nothing"
        )
    if validate != "m:m":
        raise UnsupportedOperation(
            f"join: validate={validate!r} checks that keys are unique, which is not supported; "
            "only validate='m:m' is"
        )
    if maintain_order not in (None, "none"):
        raise UnsupportedOperation(
            f"join: maintain_order={maintain_order!r} keeps an input's row order, and a join "
            "promises none; sort the result"
        )
    if not isinstance(suffix, str) or not suffix:
        raise TypeError("join: suffix must be a non-empty str")
    if coalesce not in (None, True, False):
        raise TypeError("join: coalesce must be None or a bool")
    if how == "cross":
        if on is not None or left_on is not None or right_on is not None:
            raise ValueError("join: a cross join takes no keys")
        lk = rk = ()
    elif on is not None:
        if left_on is not None or right_on is not None:
            raise ValueError("join: give on=, or left_on= and right_on=, not both")
        lk, rk = _keys(left, on), _keys(other, on)
    else:
        if left_on is None or right_on is None:
            raise ValueError("join: give the keys with on=, or with left_on= and right_on=")
        lk, rk = _keys(left, left_on), _keys(other, right_on)
        if len(lk) != len(rk):
            raise ValueError(f"join: left_on has {len(lk)} columns and right_on {len(rk)}")
    lt, rt = left.schema, other.schema
    for a, b in zip(lk, rk):
        if lt[a] != rt[b]:
            raise UnsupportedOperation(
                f"join: the key '{a}' is of type {lt[a]} on the left and '{b}' of type {rt[b]} on "
                "the right; cast one side to the other's type first"
            )
    if how == "right" and coalesce is False:
        raise UnsupportedOperation("join: how='right' with coalesce=False is not supported")
    merged = how in ("inner", "left", "right") if coalesce is None else coalesce

    L, R = left._plan.columns, other._plan.columns
    taken = set(L) | set(R)
    # Each right column: the name the plan's join gives it (never one of the
    # left's), and its output name, or None when polars drops it.
    inner: dict[str, str] = {}
    output: dict[str, str | None] = {}
    if how == "right":
        kept_left = [c for c in L if c not in lk]
        for c in R:
            if c in kept_left:
                raise UnsupportedOperation(
                    f"join: how='right' with the column '{c}' on both sides is not supported; "
                    "rename one side's column first"
                )
            inner[c] = _fresh(f"right_{c}", taken) if c in L else c
            output[c] = c
    elif how not in ("semi", "anti"):
        dropped = set(rk) if merged and how != "cross" else set()
        names = []
        for c in R:
            if c in dropped:
                inner[c] = _fresh(f"key_{c}", taken)
                output[c] = None
                continue
            name = c + suffix if c in L else c
            if name in L or name in names:
                raise ValueError(
                    f"join: the right column '{c}' would be named '{name}', which the output "
                    "already has; rename one side's column first"
                )
            names.append(name)
            output[c] = name
        for c in R:
            if output[c] is not None:
                inner[c] = output[c] if output[c] not in R or output[c] == c else _fresh(f"right_{c}", taken)
    right_plan = rename(other._plan, {c: n for c, n in inner.items() if n != c}) if inner else other._plan
    plan = Join(left._plan, right_plan, how, lk, tuple(inner.get(k, k) for k in rk))
    sources = dict(left._sources)
    for path, src in other._sources.items():
        sources.setdefault(path, src)

    if how == "right":
        items = [(c, ColRef(c)) for c in L if c not in lk] + [(c, ColRef(inner[c])) for c in R]
    elif how in ("semi", "anti"):
        items = [(c, ColRef(c)) for c in L]
    else:
        items = [(c, ColRef(c)) for c in L]
        if how == "full" and merged:
            from ._expr import _fill
            from ._scope import Scope

            fields = _encoder().encode_plan(plan, sources).plan.output_schema.fields
            scope = Scope(fields, "join")
            pairs = dict(zip(lk, rk))
            items = [
                (c, _fill(ColRef(c), ColRef(inner[pairs[c]]), scope) if c in pairs else node)
                for c, node in items
            ]
        items += [(output[c], ColRef(inner[c])) for c in R if output[c] is not None]
    items = tuple(items)
    if items != tuple((c, ColRef(c)) for c in plan.columns):
        plan = Project(plan, items)
    return LazyFrame(left._session, plan, sources, None)
