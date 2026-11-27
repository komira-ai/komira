"""`DataFrame.merge` and the semi and anti joins of `isin` (docs/design/dataframe_surface.md,
section 8, rulings 7, 8 and 16; dataframe_surface_verbs.md, the `join_*` rows).

Each builds one JOIN plan node of the two frames' plans, run with the rest of
the plan at the terminal; no SQL text is written.

- `df.merge(other, how=..., on=... | left_on=..., right_on=...)`: `how` is
  "inner", "left", "right", "outer" (a FULL join) or "cross"; with no keys
  named, the columns the two frames share are the keys, as in pandas.
- The answer's columns are pandas' (ruling 8): the left frame's columns,
  then the right frame's, a key named alike on both sides (`on=`) once, at its
  left position; and every other name the two frames share suffixed, by
  default `_x` on the left and `_y` on the right. For `how="right"` a shared
  key is the right frame's, and for `how="outer"` the one of the side that
  has a value (`CASE WHEN k IS NOT NULL THEN k ELSE k_right END`). The plan's
  join renames a right column the left also has to `<name>_right`; so the
  right frame's shared names are renamed first, by a projection under the
  join, to names neither frame has, and a projection over the join gives the
  answer's names.
- A missing key matches nothing (ruling 7): pandas matches missing keys to
  each other, so that is a departure.
- The answer has no row order (section 7), unless `sort=True` sorts it by
  the keys, missing keys last.
- `df[df["k"].isin(other["k"])]` is a SEMI join of `df` with the column of
  `other`, and `df[~df["k"].isin(other["k"])]` an ANTI join (ruling 16): the
  rows of `df`, in `df`'s order when `df` is sorted, as a filter keeps it.
- Frames of two sessions never meet, and a file the two frames read in two
  ways (two formats or two CSV dialects) is refused.

Refused by name: the index arguments (`left_index`, `right_index`),
`indicator`, `validate`, pandas 3's "left_anti" and "right_anti" (`~isin` is
the anti join), and a "semi" or "anti" `how`, which pandas does not have.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import _ops
from ._errors import UnsupportedOperation

if TYPE_CHECKING:
    from ._frame import DataFrame
    from ._series import Series

__all__ = ["merge", "semi_join"]

_HOWS = {"inner": "inner", "left": "left", "right": "right", "outer": "full", "cross": "cross"}
_ANTI_HINT = 'filter with ~isin instead, as df[~df["k"].isin(other["k"])]'


def _sources(left: DataFrame, right: DataFrame, verb: str) -> dict[str, object]:
    """The sources of both frames' scans, by path."""
    if right._session is not left._session:
        raise UnsupportedOperation(
            f"{verb} combines frames of two sessions, which never meet: read both frames on one session"
        )
    out = dict(left._sources)
    for path, source in right._sources.items():
        if path in out and out[path] != source:
            raise UnsupportedOperation(
                f"{verb} combines two frames that read the file {path!r} in two ways: read it once, "
                "and take both frames from that one"
            )
        out[path] = source
    return out


def _unsorted(plan: _ops.Plan) -> _ops.Plan:
    """`plan` without a sort at its root: a join keeps no row order."""
    return plan.child if isinstance(plan, _ops.Sort) else plan


def _names(value: object, what: str) -> tuple[str, ...]:
    names = (value,) if isinstance(value, str) else value
    if not isinstance(names, (list, tuple)):
        raise TypeError(f"merge {what} takes a column name or a list of names, not a {type(value).__name__}")
    for name in names:
        if not isinstance(name, str):
            raise TypeError(f"merge {what} takes column names, which are str, not {type(name).__name__}")
    if not names:
        raise ValueError(f"merge {what} must name at least one column")
    return tuple(names)


def _keys(left: DataFrame, right: DataFrame, how: str, on: object, left_on: object, right_on: object):
    """The key columns of each side, pandas' way."""
    if how == "cross":
        if on is not None or left_on is not None or right_on is not None:
            raise ValueError(
                "Can not pass on, right_on, left_on or set right_index=True or left_index=True"
            )
        return (), ()
    if on is not None:
        if left_on is not None or right_on is not None:
            raise ValueError(
                'Can only pass argument "on" OR "left_on" and "right_on", not a combination of both.'
            )
        lk = rk = _names(on, "on")
    elif left_on is not None or right_on is not None:
        if right_on is None:
            raise ValueError('Must pass "right_on" OR "right_index".')
        if left_on is None:
            raise ValueError('Must pass "left_on" OR "left_index".')
        lk, rk = _names(left_on, "left_on"), _names(right_on, "right_on")
        if len(lk) != len(rk):
            raise ValueError("len(right_on) must equal len(left_on)")
    else:
        common = tuple(c for c in left._plan.columns if c in right._plan.columns)
        if not common:
            raise ValueError(
                "No common columns to perform merge on. Merge options: left_on=None, right_on=None, "
                "left_index=False, right_index=False"
            )
        lk = rk = common
    _ops.require_columns(lk, left._plan.columns)
    _ops.require_columns(rk, right._plan.columns)
    _ops.require_unique(lk, "merge")
    _ops.require_unique(rk, "merge")
    return lk, rk


def _suffixes(value: object) -> tuple[str, str]:
    if not isinstance(value, (list, tuple)):
        raise TypeError(f"merge suffixes must be a tuple of two str (or None), not a {type(value).__name__}")
    if len(value) != 2:
        raise ValueError(f"merge suffixes must be two, a left and a right one, not {len(value)}")
    out = []
    for suffix in value:
        if suffix is not None and not isinstance(suffix, str):
            raise TypeError(f"merge suffixes must be str or None, not {type(suffix).__name__}")
        out.append(suffix or "")
    return out[0], out[1]


def merge(
    left: DataFrame,
    right: object,
    how: object,
    on: object,
    left_on: object,
    right_on: object,
    left_index: object,
    right_index: object,
    sort: object,
    suffixes: object,
    indicator: object,
    validate: object,
) -> DataFrame:
    """`left.merge(right, ...)`: see the module's text."""
    from ._frame import DataFrame

    if not isinstance(right, DataFrame):
        raise TypeError(f"merge() takes a komira DataFrame to merge with, not a {type(right).__name__}")
    sources = _sources(left, right, "merge()")
    for name, value in (("left_index", left_index), ("right_index", right_index)):
        if value is not False:
            raise UnsupportedOperation(
                f"merge({name}={value!r}) joins on the index, which komira frames do not have: "
                "name the key columns with on=, or left_on= and right_on="
            )
    if indicator is not False:
        raise UnsupportedOperation(
            f"merge(indicator={indicator!r}) adds a column saying which frame each row came from, "
            "which this release does not build: use indicator=False"
        )
    if validate is not None:
        raise UnsupportedOperation(
            f"merge(validate={validate!r}) checks that the keys are unique, which needs a query to run: "
            "use validate=None"
        )
    if how in ("left_anti", "right_anti"):
        raise UnsupportedOperation(f"merge(how={how!r}) is not supported: {_ANTI_HINT}")
    if how in ("semi", "anti"):
        raise UnsupportedOperation(
            f"merge(how={how!r}) is not pandas': filter with isin instead, as "
            'df[df["k"].isin(other["k"])] for a semi join and df[~df["k"].isin(other["k"])] for an anti join'
        )
    if not isinstance(how, str) or how not in _HOWS:
        raise ValueError(f"{how!r} is not a valid Merge type: left, right, inner, outer, cross")
    if not isinstance(sort, bool):
        raise TypeError(f"merge sort must be a bool, not {type(sort).__name__}")
    lsuffix, rsuffix = _suffixes(suffixes)
    lk, rk = _keys(left, right, how, on, left_on, right_on)

    left_columns, right_columns = left._plan.columns, right._plan.columns
    shared = {a: b for a, b in zip(lk, rk) if a == b}
    overlap = (set(left_columns) & set(right_columns)) - set(shared)
    if overlap and not lsuffix and not rsuffix:
        raise ValueError(f"columns overlap but no suffix specified: {sorted(overlap)}")
    names = [c + lsuffix if c in overlap else c for c in left_columns]
    names += [c + rsuffix if c in overlap else c for c in right_columns if c not in shared]
    duplicated = sorted({n for n in names if names.count(n) > 1})
    if duplicated:
        raise ValueError(f"Passing 'suffixes' which cause duplicate columns {duplicated} is not allowed.")
    if sort and any(a != b for a, b in zip(lk, rk)):
        raise UnsupportedOperation(
            "merge(sort=True) with keys named differently on the two sides has no one key column to sort by: "
            "sort the answer with sort_values"
        )

    # The right frame's names the left also has, renamed to names neither
    # frame has, so the join renames nothing.
    taken = set(left_columns) | set(right_columns)
    renamed: dict[str, str] = {}
    for c in right_columns:
        if c in left_columns:
            new = c + "_right"
            while new in taken:
                new = "_" + new
            taken.add(new)
            renamed[c] = new
    rplan = _unsorted(right._plan)
    if renamed:
        rplan = _ops.rename(rplan, renamed)
    plan = _ops.join(
        _unsorted(left._plan), rplan, _HOWS[how], lk, tuple(renamed.get(k, k) for k in rk)
    )

    items: list[tuple[str, _ops.Node]] = []
    for c, name in zip(left_columns, names):
        node: _ops.Node = _ops.ColRef(c)
        if c in shared:
            theirs = _ops.ColRef(renamed[c])
            if how == "right":
                node = theirs
            elif how == "outer":
                node = _ops.When(((_ops.Unary("is_not_null", node), node),), theirs)
        items.append((name, node))
    rest = [c for c in right_columns if c not in shared]
    for c, name in zip(rest, names[len(left_columns):]):
        items.append((name, _ops.ColRef(renamed.get(c, c))))
    if tuple(n for n, _ in items) != plan.columns or any(node != _ops.ColRef(n) for n, node in items):
        plan = _ops.Project(plan, tuple(items))
    if sort and lk:
        plan = _ops.Sort(plan, tuple(_ops.SortKey(k) for k in lk))
    return DataFrame._new(left._session, plan, sources)


def semi_join(frame: DataFrame, how: str, column: str, values: Series) -> DataFrame:
    """`frame[frame[column].isin(values)]` (`how` "semi") or its negation
    ("anti"): the rows of `frame` whose `column` does (does not) equal a value
    of `values`, a Series of `frame` or of another frame of its session."""
    other = values._frame
    sources = _sources(frame, other, "isin()")
    right = _unsorted(other._plan)
    node = values._node
    if isinstance(node, _ops.ColRef):
        key = node.name
        right = _ops.select(right, (key,))
    else:
        key = "key"
        right = _ops.Project(right, ((key, node),))
    plan = frame._plan

    def joined(p: _ops.Plan) -> _ops.Plan:
        return _ops.join(p, right, how, (column,), (key,))

    if isinstance(plan, _ops.Sort):
        out = _ops.Sort(joined(plan.child), plan.keys)
    else:
        out = joined(plan)
    return frame._ordered(out, lambda keys: True, sources)
