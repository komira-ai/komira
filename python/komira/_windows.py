"""Window functions of the pandas-shaped DataFrame (docs/design/dataframe_surface.md,
section 7; docs/design/dataframe_surface_verbs.md, the `window` row).

A window gives one value per row, computed over other rows. In the plan it is
a `WindowExpr` item of a projection (komira/_ops), which the encoder sends as a
partition-by node (komira/_plan/_window.py). A Series that reads windows holds
each one, under a placeholder name, beside its expression, and the expression
reads the window as a column of that name; so a window combines with columns,
literals and other windows as any column does:
`df["v"] - df.groupby("k")["v"].transform("mean")`.

The verbs that take a Series compute its windows first. `assign` (and
`df["x"] = ...`) builds a projection that keeps the frame's columns and
appends one column per window, `_w0`, `_w1`, ... (an underscore is prepended
until the name is not one of the frame's), and over it the projection of the
frame's columns and the assigned ones, each placeholder read as its window's
column. A filter builds the same window projection, over it a projection of
the frame's columns and the predicate as an int64 column (`_keep`, 1 where
the predicate holds and 0 elsewhere, underscores prepended as above; the
engine's filter takes no CASE, and a window's value often is one), the
filter `_keep = 1` and a projection back to the frame's columns. Over a sort that the verb keeps (an
assign that replaces no sort key, any filter) both go under the sort, as
`with_columns` and `filter_` place a projection and a filter.

The verbs, each of one column but the last, and what each builds:

- `df.groupby(keys)["c"].transform(func)`, func one of "sum", "mean", "min",
  "max", "count": the aggregate over the row's group (its partition, no
  order, the whole partition). A sum of a group with no values is 0, as in
  pandas' `min_count=0` (`CASE WHEN w IS NOT NULL THEN w ELSE 0 END`).
- `cumsum()`, `cummin()`, `cummax()` of a column, or of `groupby(keys)["c"]`:
  the aggregate over the rows from the first of the partition to this one
  (ROWS UNBOUNDED PRECEDING .. CURRENT ROW), in the order of the frame's sort,
  each key with its direction and its NULL placement.
  A frame that is not sorted has no row order, so they are refused there
  (section 7). A missing value stays missing (`skipna=True`).
- `rolling(window, min_periods=None)` of a column, then `sum()`, `mean()`,
  `min()` or `max()`: the aggregate over this row and the `window - 1` rows
  before it in the frame's sort order (ROWS n - 1 PRECEDING .. CURRENT ROW),
  missing when fewer than `min_periods` (by default `window`) of those rows
  hold a value: a second window counts them. The answer is float64, as
  pandas gives it.
- `rank(method="min" | "dense", ascending=True, na_option="keep")` of a
  column or of `groupby(keys)["c"]`: RANK or DENSE_RANK ordered by the column
  itself, as float64, as pandas gives it; a missing value has a missing rank
  (`na_option="keep"`), or ranks after every value (`"bottom"`) or before
  every value (`"top"`).
- `df.duplicated(subset, keep)`: `ROW_NUMBER() > 1` over the rows of each
  value of the subset (keep "first" or "last"; the row numbered 1 is any one
  of them, as a plan has no row order), or `COUNT(*) > 1` (keep=False), the
  count reading a column of the literal 1 projected below the windows (`_one`,
  underscores prepended as above). `df.drop_duplicates(subset, keep)` over
  fewer than every column keeps the rows whose window is 1, with the plan of
  polars' `unique(subset)`: the windows, a filter on the window's column and
  a projection back to the frame's columns.

Under `groupby(dropna=True)`, pandas' default, a row whose key is missing
belongs to no group, and its value is missing.
"""

from __future__ import annotations

import dataclasses
import hashlib
from typing import TYPE_CHECKING

from . import _ops
from ._errors import UnsupportedOperation

if TYPE_CHECKING:
    from ._frame import DataFrame
    from ._series import Series

__all__ = [
    "Rolling",
    "Windows",
    "cumulative",
    "duplicates",
    "filter_plan",
    "merged",
    "project_plan",
    "rank",
    "transform",
    "unique_rows",
]

# The windows a Series reads: (placeholder, WindowExpr) pairs, in the order
# they first appear.
Windows = tuple[tuple[str, _ops.WindowExpr], ...]

_PLACEHOLDER = "__komira_window_"
_RUNNING = _ops.Frame("rows", "unbounded_preceding", "current_row")
_TRANSFORMS = {"sum": "sum", "mean": "avg", "min": "min", "max": "max", "count": "count"}
_TRANSFORM_NAMES = ", ".join(sorted(_TRANSFORMS))
_RANKS = {"min": "rank", "dense": "dense_rank"}
_NUMBERS = frozenset(
    {"int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64", "float16", "float32", "float64"}
)
_CASE_NULLS = frozenset({"int64", "float64"})
# The argument of a count window that counts every row of its partition, NULLs
# and all: `_computed` reads it from a column of the literal 1.
_EVERY_ROW = "__komira_every_row"


# ---- the windows of a Series ---------------------------------------------------


def _placeholder(win: _ops.WindowExpr) -> str:
    """The name a Series reads `win` by: the same for equal windows, so a
    window read twice is computed once."""
    return _PLACEHOLDER + hashlib.sha256(repr(win).encode("utf-8")).hexdigest()[:20]


def merged(*groups: Windows) -> Windows:
    """The windows of `groups`, each once, in the order they first appear."""
    out: dict[str, _ops.WindowExpr] = {}
    for group in groups:
        for name, win in group:
            out.setdefault(name, win)
    return tuple(out.items())


# ---- the plans of the verbs that take a Series -------------------------------


def _computed(plan: _ops.Plan, windows: Windows) -> tuple[_ops.Plan, dict[str, _ops.Node]]:
    """The projection of `plan`'s columns and one column per window, and the
    reference that replaces each placeholder. A count of every row (its
    argument `_EVERY_ROW`) reads a column of the literal 1, `_one`, projected
    below the windows."""
    taken = set(plan.columns)

    def free(name: str) -> str:
        while name in taken:
            name = "_" + name
        taken.add(name)
        return name

    if any(win.arg == _EVERY_ROW for _, win in windows):
        one = free("_one")
        plan = _ops.Project(plan, tuple((c, _ops.ColRef(c)) for c in plan.columns) + ((one, _ops.Lit(1)),))
        windows = tuple(
            (placeholder, dataclasses.replace(win, arg=one) if win.arg == _EVERY_ROW else win)
            for placeholder, win in windows
        )
    subs: dict[str, _ops.Node] = {}
    items: list[tuple[str, object]] = [(c, _ops.ColRef(c)) for c in plan.columns]
    for i, (placeholder, win) in enumerate(windows):
        name = free(f"_w{i}")
        subs[placeholder] = _ops.ColRef(name)
        items.append((name, win))
    return _ops.Project(plan, tuple(items)), subs


def project_plan(plan: _ops.Plan, items: tuple[tuple[str, _ops.Node], ...], windows: Windows) -> _ops.Plan:
    """`plan` with each item's column set, as `with_columns` sets it, where the
    items read the windows `windows`."""
    if not windows:
        return _ops.with_columns(plan, items)
    by_name = dict(items)
    if isinstance(plan, _ops.Sort) and all(
        by_name.get(k.column, _ops.ColRef(k.column)) == _ops.ColRef(k.column) for k in plan.keys
    ):
        return _ops.Sort(project_plan(plan.child, items, windows), plan.keys)
    below, subs = _computed(plan, windows)
    out = [(c, _ops.substitute(by_name[c], subs) if c in by_name else _ops.ColRef(c)) for c in plan.columns]
    out.extend((name, _ops.substitute(node, subs)) for name, node in items if name not in plan.columns)
    return _ops.Project(below, tuple(out))


def filter_plan(plan: _ops.Plan, predicate: _ops.Node, windows: Windows) -> _ops.Plan:
    """The rows of `plan` where `predicate`, which reads the windows
    `windows`, is true."""
    if not windows:
        return _ops.filter_(plan, predicate)
    if isinstance(plan, _ops.Sort):
        return _ops.Sort(filter_plan(plan.child, predicate, windows), plan.keys)
    below, subs = _computed(plan, windows)
    # The predicate is a column of its own, 1 where it holds and 0 elsewhere
    # (where it is false or missing), and the filter reads that column: a
    # window's value is a CASE (the masks above), and the engine's filter takes
    # no CASE in its predicate.
    name = "_keep"
    while name in below.columns:
        name = "_" + name
    flag = _ops.When(((_ops.substitute(predicate, subs), _ops.Lit(1)),), _ops.Lit(0))
    kept = _ops.Project(below, tuple((c, _ops.ColRef(c)) for c in plan.columns) + ((name, flag),))
    test = _ops.Compare("eq", _ops.ColRef(name), _ops.Lit(1))
    return _ops.select(_ops.Filter(kept, test), plan.columns)


# ---- the verbs -----------------------------------------------------------------


def _present(names: tuple[str, ...]) -> _ops.Node:
    return _ops.and_all(tuple(_ops.Unary("is_not_null", _ops.ColRef(n)) for n in names))


def _null(dtype: str) -> _ops.Node:
    """A NULL of the type `dtype`, the default of a CASE of that type."""
    if dtype in _CASE_NULLS:
        return _ops.Lit(None)
    return _ops.Cast(_ops.Lit(None), None, arrow=dtype)


def _need_number(frame: DataFrame, column: str, verb: str) -> None:
    dtype = frame.dtypes[column]
    if dtype not in _NUMBERS:
        raise UnsupportedOperation(f"{verb} needs a numeric column, and the column {column!r} is {dtype}")


def _order(frame: DataFrame, verb: str) -> tuple[_ops.SortKey, ...]:
    keys = frame._order()
    if keys is None:
        raise UnsupportedOperation(
            f"{verb} runs in row order, and this frame is not sorted, so its rows have no order: "
            'sort it first, as df.sort_values("column")'
        )
    return keys


class _Built:
    """A window verb's answer before it is a Series: the expression and the
    windows it reads."""

    __slots__ = ("node", "windows")

    def __init__(self, node: _ops.Node, windows: Windows) -> None:
        self.node = node
        self.windows = windows


def _build(
    frame: DataFrame,
    wins: tuple[_ops.WindowExpr, ...],
    value: object,
    keys: tuple[str, ...],
    dropna: bool,
) -> _Built:
    """The expression `value(*refs)`, each ref reading one of `wins`; under
    `groupby(dropna=True)` missing where a key is."""
    windows = tuple((_placeholder(w), w) for w in wins)
    node = value(*(_ops.ColRef(name) for name, _ in windows))
    if keys and dropna:
        dtype = frame._type_name(frame._field_of(node, windows))
        node = _ops.When(((_present(keys), node),), _null(dtype))
    return _Built(node, windows)


def _masked(frame: DataFrame, column: str, node: _ops.Node, windows: Windows) -> _ops.Node:
    """`node`, missing where `column` is (skipna)."""
    dtype = frame._type_name(frame._field_of(node, windows))
    return _ops.When(((_present((column,)), node),), _null(dtype))


def transform(frame: DataFrame, column: str, keys: tuple[str, ...], dropna: bool, func: object) -> _Built:
    """`groupby(keys)[column].transform(func)`."""
    if callable(func):
        raise UnsupportedOperation(
            "transform() with a Python function runs it once per group, a user function that this release "
            f"does not run: name one of {_TRANSFORM_NAMES}"
        )
    if not isinstance(func, str):
        raise TypeError(f"transform() takes the name of a reduction, a str, not a {type(func).__name__}")
    if func not in _TRANSFORMS:
        raise UnsupportedOperation(f"transform({func!r}) is not supported: name one of {_TRANSFORM_NAMES}")
    if func in ("sum", "mean"):
        _need_number(frame, column, f"transform({func!r})")
    win = _ops.WindowExpr(_TRANSFORMS[func], column, partition_by=keys)
    if func == "sum":
        def value(w):
            return _ops.When(((_ops.Unary("is_not_null", w), w),), _ops.Lit(0))
    else:
        def value(w):
            return w
    return _build(frame, (win,), value, keys, dropna)


def cumulative(frame: DataFrame, column: str, keys: tuple[str, ...], dropna: bool, how: str, skipna: object) -> _Built:
    """`cumsum`, `cummin` and `cummax` (`how` sum, min, max) of `column`."""
    verb = f"cum{how}()"
    if not isinstance(skipna, bool):
        raise TypeError(f"cum{how} skipna must be a bool, not {type(skipna).__name__}")
    if not skipna:
        raise UnsupportedOperation(
            f"cum{how}(skipna=False) is missing from the first missing value on, which this release does not "
            "build: use skipna=True"
        )
    if how == "sum":
        _need_number(frame, column, verb)
    order = _order(frame, verb)
    win = _ops.WindowExpr(how, column, partition_by=keys, order_by=order, frame=_RUNNING)
    placeholder = _placeholder(win)

    def value(w):
        return _masked(frame, column, w, ((placeholder, win),))

    return _build(frame, (win,), value, keys, dropna)


def rank(
    frame: DataFrame,
    column: str,
    keys: tuple[str, ...],
    dropna: bool,
    method: object,
    ascending: object,
    na_option: object,
    pct: object,
) -> _Built:
    """`rank(method, ascending, na_option, pct)` of `column`."""
    if method in ("average", "max"):
        raise UnsupportedOperation(
            f'rank(method="{method}") has no window function in the plan: use method="min" (ties take '
            'the lowest rank) or method="dense"'
        )
    if method == "first":
        raise UnsupportedOperation(
            'rank(method="first") breaks ties by row order, which a frame does not have: '
            'use method="min" or method="dense"'
        )
    if method not in _RANKS:
        raise ValueError("method must be one of 'average', 'min', 'max', 'first' or 'dense'")
    if not isinstance(ascending, bool):
        raise TypeError(f"rank ascending must be a bool, not {type(ascending).__name__}")
    if na_option not in ("keep", "top", "bottom"):
        raise ValueError("na_option must be one of 'keep', 'top', or 'bottom'")
    if not isinstance(pct, bool):
        raise TypeError(f"rank pct must be a bool, not {type(pct).__name__}")
    if pct:
        raise UnsupportedOperation(
            "rank(pct=True) divides each rank by the count of values, which this release does not build: "
            "use pct=False"
        )
    order = _ops.SortKey(column, descending=not ascending, nulls_first=na_option == "top")
    win = _ops.WindowExpr(_RANKS[method], None, partition_by=keys, order_by=(order,))

    def value(w):
        ranked = _ops.Cast(w, "float64")
        if na_option == "keep":
            ranked = _ops.When(((_present((column,)), ranked),), _ops.Lit(None))
        return ranked

    return _build(frame, (win,), value, keys, dropna)


def duplicates(names: tuple[str, ...], keep: object) -> _Built:
    """`df.duplicated(subset, keep)` over the columns `names`: true where the
    row's window is over 1. For `keep` "first" or "last" the window is
    ROW_NUMBER over the rows of each value of `names`, so every row of a value
    is true but the one numbered 1; the number follows no row order, so that
    row is any one of them, not the first or the last (a plan has no row
    order). For `keep=False` it is the count of the value's rows, so every
    row of a value more than one row has is true. A NULL is a value of its
    own, as in pandas."""
    if keep is False:
        win = _ops.WindowExpr("count", _EVERY_ROW, partition_by=names)
    else:
        win = _ops.WindowExpr("row_number", None, partition_by=names, order_by=(_ops.SortKey(names[0]),))
    placeholder = _placeholder(win)
    return _Built(_ops.Compare("gt", _ops.ColRef(placeholder), _ops.Lit(1)), ((placeholder, win),))


def unique_rows(plan: _ops.Plan, names: tuple[str, ...], keep: object) -> _ops.Plan:
    """The rows of `plan` that `duplicates(names, keep)` holds false: one row
    of each value of `names` (keep "first" or "last"), or the rows of the
    values no other row has (keep=False). The plan is polars' `unique(subset)`
    (komira/pl/_frame.py): the window projected over `plan`, the filter of the
    window's 1, and the projection back to `plan`'s columns."""
    built = duplicates(names, keep)
    below, subs = _computed(plan, built.windows)
    kept = _ops.Filter(below, _ops.Compare("eq", subs[built.windows[0][0]], _ops.Lit(1)))
    return _ops.select(kept, plan.columns)


class Rolling:
    """The windows of the rows of one column of an ordered frame, made by
    `s.rolling(window, min_periods=None)`: `sum()`, `mean()`, `min()` and
    `max()` each give a float64 Series of the frame, and run nothing."""

    __slots__ = ("_series", "_column", "_window", "_min_periods")

    def __init__(self, *args: object, **kwargs: object) -> None:
        raise TypeError('a komira Rolling is made by a Series: df["column"].rolling(3)')

    @classmethod
    def _of(cls, series: Series, column: str, window: object, min_periods: object) -> Rolling:
        if isinstance(window, bool) or not isinstance(window, int):
            if isinstance(window, str):
                raise UnsupportedOperation(
                    f"rolling({window!r}) is a window of time, which needs a time index komira frames do not "
                    "have: give the number of rows, as rolling(3)"
                )
            raise TypeError(f"rolling window must be an int, the number of rows, not a {type(window).__name__}")
        if window < 1:
            raise ValueError("rolling window must be at least 1")
        if min_periods is None:
            min_periods = window
        elif isinstance(min_periods, bool) or not isinstance(min_periods, int):
            raise TypeError(f"rolling min_periods must be an int, not {type(min_periods).__name__}")
        elif min_periods > window:
            raise ValueError(f"min_periods {min_periods} must be <= window {window}")
        elif min_periods < 0:
            raise ValueError("min_periods must be >= 0")
        elif min_periods == 0:
            raise UnsupportedOperation(
                f"rolling(min_periods={min_periods}) answers a window with no values, which this release "
                "does not build: use min_periods of 1 or more"
            )
        out = object.__new__(cls)
        object.__setattr__(out, "_series", series)
        object.__setattr__(out, "_column", column)
        object.__setattr__(out, "_window", window)
        object.__setattr__(out, "_min_periods", min_periods)
        return out

    def _reduce(self, how: str, func: str) -> Series:
        series = self._series
        series._check_current()
        frame = series._frame
        verb = f"rolling({self._window}).{how}()"
        _need_number(frame, self._column, verb)
        order = _order(frame, verb)
        n = self._window
        rows = (
            _ops.Frame("rows", "current_row", "current_row")
            if n == 1
            else _ops.Frame("rows", "preceding", "current_row", start_offset=n - 1)
        )
        wins = (_ops.WindowExpr(func, self._column, order_by=order, frame=rows),)
        if self._min_periods > 1:
            wins += (_ops.WindowExpr("count", self._column, order_by=order, frame=rows),)
        least = self._min_periods

        def value(w, count=None):
            out = _ops.Cast(w, "float64")
            if count is not None:
                out = _ops.When(((_ops.Compare("ge", count, _ops.Lit(least)), out),), _ops.Lit(None))
            return out

        built = _build(frame, wins, value, (), False)
        return series._windowed(built.node, built.windows)

    def sum(self) -> Series:
        """The sum of the values of each row's window, as float64."""
        return self._reduce("sum", "sum")

    def mean(self) -> Series:
        """The mean of the values of each row's window, as float64."""
        return self._reduce("mean", "avg")

    def min(self) -> Series:
        """The least value of each row's window, as float64."""
        return self._reduce("min", "min")

    def max(self) -> Series:
        """The greatest value of each row's window, as float64."""
        return self._reduce("max", "max")

    def __repr__(self) -> str:
        return f"<komira.Rolling window={self._window} min_periods={self._min_periods}>"

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(
            f"cannot set the attribute '{name}' of a komira Rolling: it is part of a plan and does not change",
            name=name,
            obj=self,
        )
