"""The pandas-shaped `DataFrame` and its readers (docs/design/dataframe_surface.md).

A frame is a plan: a tree of the private node classes (komira/_ops), the
sources its scans read, and the session it runs on. Every verb returns a new
frame with a larger plan and runs nothing; a query runs only at the terminal
`materialize()`, which encodes the plan as a `komira.plan.v1.WirePlanEnvelope`
(komira/_plan) and runs it through the session's plan door,
`komira_plan_stream`. No SQL text is written or read anywhere on this path.

- Readers (`read_parquet`, `read_csv`, `read_json`) read the file's schema now,
  through libkomira, and build a scan that names the file itself; no table name
  is registered. They take the session as a keyword and use the process's
  default session without one.
- The verbs are `df["x"]` (a `Series`), `df[["a", "b"]]` (a projection),
  `df[cond]` (a filter), `assign` and `df["x"] = ...` (computed columns),
  `sort_values`, `head` and `tail`. Each derives the output schema now, as the engine
  will, so `columns`, `dtypes`, `repr` and the notebook display
  (`_repr_html_`, the names and types) run nothing, and an unknown column is
  a `KeyError` at the verb that names it.
- `groupby` gives a `GroupBy`, and `agg`, `sum`, `mean`, `median`, `std`,
  `var`, `min`, `max`, `count` and `nunique` reduce the whole frame to one
  row; each builds one aggregate node (komira/_groupby.py).
  `drop_duplicates` builds a distinct over every column.
- `merge` joins two frames with one join node, and `df[df["k"].isin(o["k"])]`
  (`~` for its negation) is a semi (anti) join (komira/_merge.py).
- A Series may read windows (`cumsum`, `rank`, `rolling`, a group's
  `transform`, komira/_windows.py): `assign`, `df["x"] = ...` and `df[cond]`
  compute them in a projection of their own first.
- `fillna`, `dropna`, `rename`, `add_prefix`, `add_suffix` and `astype` each
  build one projection or filter. A value is missing when it is NULL, or NaN
  in a float column (komira/_missing.py): `fillna` replaces it with a literal
  of the column's type, and `dropna` filters on it. `astype` casts through
  komira/_cast.py. `tail` takes the last rows of a sorted frame as a TOPN by
  the reversed keys, sorted back. `komira.concat` is a union of frames of one
  schema, checked in komira/_verbs.py before it is built.
- Row order (section 7): a sort makes a frame ordered; a filter, a projection
  that keeps the sort keys, an `assign`, `fillna`, `astype` or `rename` that
  changes none of them, a `dropna` and `head`
  keep it ordered, the builder placing filters and projections under the sort
  and a limit above it, and a sort above a limit when a verb comes after one.
  `tail` of a sorted frame is sorted. A reduction, `drop_duplicates`,
  `concat` and `merge` give an unordered frame, except that
  `groupby(sort=True)` and `merge(sort=True)` sort by their keys; a semi or
  anti join keeps the order, as a filter does.
- The write terminals `to_parquet`, `to_csv` and `to_json(orient="records",
  lines=True)` run the plan once and write its rows to a file through the same
  plan door, with a write target in the envelope (komira/_write.py); they
  return None. The format follows the verb, not the file's extension.
- No dunder runs a query, no attribute is a column, and a name the class does
  not define raises `AttributeError` (komira/_refusals.py).

The generated plan modules, and so protobuf, are imported when the first frame
is made, not when `komira` is imported.
"""

from __future__ import annotations

import os
from collections.abc import Callable, Iterable
from types import ModuleType
from typing import TYPE_CHECKING, Any

from . import _display, _groupby, _merge, _ops, _refusals, _verbs, _windows, _write
from ._errors import UnsupportedOperation
from ._groupby import GroupBy
from ._missing import present
from ._series import Series, _Membership, operand
from ._session import Result, Session, _local_path, default_session
from ._windows import Windows, merged

if TYPE_CHECKING:
    from .plan.v1 import plan_pb2

__all__ = ["DataFrame", "concat", "read_csv", "read_json", "read_parquet"]

_TERMINAL = "run it with .materialize() and read the Result"


# The default of an argument pandas tells apart from None.
_UNSET: Any = object()


def _encoder() -> ModuleType:
    """komira._plan, imported on first use: it imports the generated plan modules."""
    from . import _plan

    return _plan


def _wire() -> ModuleType:
    from ._plan import _wire

    return _wire


def _window_field(name: str, win: _ops.WindowExpr, schema: tuple) -> plan_pb2.WireField:
    from ._plan._window import window_field

    return window_field(name, win, schema)


class DataFrame:
    """A lazy, pandas-shaped frame: a plan over files, run by `materialize()`.

    It is made by a reader (`komira.read_parquet(path)` and its siblings) and
    by the verbs of another frame, never by calling the class.
    """

    __slots__ = ("_session", "_plan", "_sources", "_fields", "_generation")

    def __init__(self, *args: object, **kwargs: object) -> None:
        raise TypeError("a komira DataFrame is made by a reader, such as komira.read_parquet(path)")

    @classmethod
    def _new(cls, session: Session, plan: _ops.Plan, sources: dict[str, object]) -> DataFrame:
        """The frame of `plan` over `sources` on `session`; the output schema
        is derived now, by the encoder, as the engine derives it."""
        out = object.__new__(cls)
        out._session = session
        out._plan = plan
        out._sources = sources
        out._fields = tuple(_encoder().encode_plan(plan, sources).plan.output_schema.fields)
        out._generation = 0
        return out

    def _derive(self, plan: _ops.Plan) -> DataFrame:
        return self._new(self._session, plan, self._sources)

    # ---- schema ---------------------------------------------------------

    def _field_of(self, node: _ops.Node, windows: Windows = ()) -> plan_pb2.WireField:
        """The field the engine derives for `node` over this frame's columns
        and, by their placeholders, the columns of the windows `windows`."""
        schema = self._fields
        if windows:
            schema = schema + tuple(_window_field(name, win, self._fields) for name, win in windows)
        return _encoder().expr_field(node, schema)

    @staticmethod
    def _type_name(field: plan_pb2.WireField) -> str:
        return _wire().arrow_name(field.arrow_type_id)

    @property
    def columns(self) -> list[str]:
        """The column names, in order; runs nothing."""
        return list(self._plan.columns)

    @property
    def dtypes(self) -> dict[str, str]:
        """Each column's Arrow type name (`int64`, `float64`, `string`, `bool`,
        ...), as the engine derives it; runs nothing."""
        return {f.name: self._type_name(f) for f in self._fields}

    def __repr__(self) -> str:
        listed = ", ".join(f"{name}: {dtype}" for name, dtype in self.dtypes.items())
        return f"<komira.DataFrame {listed}>"

    def _repr_html_(self) -> str:
        """IPython's HTML display of the frame: its column names, each over
        its type, and a line saying the frame has not run and
        `.materialize()` runs it (komira/_display.py). It runs nothing and
        shows no rows, since a frame is a plan."""
        return _display.frame_html(self.dtypes)

    def __contains__(self, name: object) -> bool:
        """Whether `name` is a column, as `in` asks of a pandas frame; runs nothing."""
        return name in self._plan.columns

    # ---- row order ------------------------------------------------------

    def _order(self) -> tuple[_ops.SortKey, ...] | None:
        """The sort keys of an ordered frame, None for an unordered one."""
        plan = self._plan
        if isinstance(plan, _ops.Limit):
            plan = plan.child
        if isinstance(plan, (_ops.Sort, _ops.TopN)):
            return plan.keys
        return None

    def _ordered(
        self,
        plan: _ops.Plan,
        keep: Callable[[tuple[_ops.SortKey, ...]], bool],
        sources: dict[str, object] | None = None,
    ) -> DataFrame:
        """The frame of `plan`, a verb's plan over this frame (and over
        `sources`, when the verb reads another frame too): when this frame
        is ordered, `keep(keys)` says the verb kept its order, and the plan's
        root is a limit or another node the order does not pass, the plan
        gets a sort by the same keys on top."""
        keys = self._order()
        if keys is not None and keep(keys) and not isinstance(plan, (_ops.Sort, _ops.TopN)):
            inner = plan.child if isinstance(plan, _ops.Limit) else None
            if not isinstance(inner, (_ops.Sort, _ops.TopN)):
                plan = _ops.Sort(plan, keys)
        if sources is not None:
            return self._new(self._session, plan, sources)
        return self._derive(plan)

    # ---- subscripts -----------------------------------------------------

    def __getitem__(self, key: object) -> DataFrame | Series:
        """`df["x"]` is the column `x`, `df[["a", "b"]]` the frame of those
        columns, `df[cond]` the rows where the boolean Series `cond` (or a
        function of the frame returning one) is true."""
        if callable(key) and not isinstance(key, Series):
            key = key(self)
        if isinstance(key, _Membership):
            how, column, values = key._join(self)
            return _merge.semi_join(self, how, column, values)
        if isinstance(key, Series):
            return self._filter(key)
        if isinstance(key, str):
            _ops.require_columns((key,), self._plan.columns)
            return Series._of(self, _ops.ColRef(key))
        if isinstance(key, (list, tuple)):
            return self._select(key)
        if isinstance(key, slice):
            raise UnsupportedOperation(
                "df[start:stop] selects rows by position, and a komira frame has no row positions: "
                "sort with sort_values(...) and take rows with head(n)"
            )
        if isinstance(key, int):
            raise KeyError(
                f"no column labelled {key!r}: a komira frame's column names are str; "
                "the frame's columns are: " + ", ".join(self._plan.columns)
            )
        raise TypeError(
            "a komira DataFrame is subscripted with a column name, a list of names or a boolean Series, "
            f"not a {type(key).__name__}"
        )

    def _filter(self, cond: Series) -> DataFrame:
        _, windows = cond._bound(self)
        predicate = cond._predicate()
        return self._ordered(_windows.filter_plan(self._plan, predicate, windows), lambda keys: True)

    def _select(self, names: list | tuple) -> DataFrame:
        for name in names:
            if not isinstance(name, str):
                raise TypeError(f"df[[...]] takes column names, which are str, not {type(name).__name__}")
        names = tuple(names)
        plan = _ops.select(self._plan, names)
        return self._ordered(plan, lambda keys: all(k.column in names for k in keys))

    def __setitem__(self, key: object, value: object) -> None:
        """`df["x"] = value` sets the column `x`, as `df.assign(x=value)`
        does, in this frame: its plan becomes that plan, and a Series taken
        from it before is stale from then on."""
        if isinstance(key, Series):
            raise UnsupportedOperation(
                "df[cond] = value sets the rows where cond holds, which needs the rows in place: "
                'write df["column"] = ... with a value that chooses per row'
            )
        if not isinstance(key, str):
            raise TypeError(f'df[name] = value takes one column name, a str, not a {type(key).__name__}')
        replacement = self.assign(**{key: value})
        self._plan = replacement._plan
        self._fields = replacement._fields
        self._generation += 1

    # ---- verbs ----------------------------------------------------------

    def assign(self, **columns: object) -> DataFrame:
        """A frame with each keyword's column set: an existing name replaced
        in place, a new one appended, in keyword order. A value is a Series of
        this frame, a literal, or a function called with the frame as the
        earlier keywords left it, returning either; so a later keyword may use
        an earlier one, as in pandas. Builds one projection, and under it one
        of the windows the values read, if they read any."""
        items: dict[str, _ops.Node] = {}
        windows: Windows = ()
        for name, value in columns.items():
            if callable(value) and not isinstance(value, Series):
                current = self
                if items:
                    current = self._derive(_windows.project_plan(self._plan, tuple(items.items()), windows))
                result = value(current)
                if isinstance(result, Series) and result._frame is self:
                    # A Series of this frame, as a plain value would be: it
                    # reads the columns as they were before this call.
                    node, read = operand(self, result, "assign()")
                else:
                    node, read = operand(current, result, "assign()")
                    if read and current is not self:
                        raise UnsupportedOperation(
                            f"assign({name}=...) is given a function that returns a window of the frame as the "
                            "earlier keywords left it: assign the window in an assign() call of its own"
                        )
                    node = _ops.substitute(node, items)
            else:
                node, read = operand(self, value, "assign()")
            items[name] = node
            windows = merged(windows, read)
        plan = _windows.project_plan(self._plan, tuple(items.items()), windows)
        return self._ordered(plan, lambda keys: not any(k.column in items for k in keys))

    def sort_values(
        self,
        by: str | list[str] | tuple[str, ...],
        *,
        axis: int | str = 0,
        ascending: bool | list[bool] | tuple[bool, ...] = True,
        inplace: bool = False,
        kind: str = "quicksort",
        na_position: str = "last",
        ignore_index: bool = False,
        key: object = None,
    ) -> DataFrame:
        """A frame sorted by the columns `by`, each ascending unless
        `ascending` says otherwise, missing values last unless `na_position`
        is "first". Rows that tie come out in any order: no sort is stable.
        `ignore_index` is accepted and does nothing, since a frame has no index."""
        if axis not in (0, "index"):
            raise UnsupportedOperation(f"sort_values(axis={axis!r}) sorts columns, and a plan sorts rows: use axis=0")
        if inplace is not False:
            raise UnsupportedOperation(
                "sort_values(inplace=True) changes the frame in place, and komira frames do not change: "
                "use the frame sort_values returns"
            )
        if kind in ("stable", "mergesort"):
            raise UnsupportedOperation(
                f"sort_values(kind={kind!r}) asks for a stable sort, and no sort in a plan is stable: "
                "add a column that breaks the ties to by="
            )
        if kind not in ("quicksort", "heapsort"):
            raise ValueError(f"sort_values kind must be 'quicksort', 'heapsort', 'mergesort' or 'stable', not {kind!r}")
        if key is not None:
            raise UnsupportedOperation(
                "sort_values(key=...) calls a Python function on the columns, which a plan cannot: "
                "assign the sort key as a column with assign(), then sort by it"
            )
        if not isinstance(ignore_index, bool):
            raise TypeError(f"sort_values ignore_index must be a bool, not {type(ignore_index).__name__}")
        names = (by,) if isinstance(by, str) else by
        if not isinstance(names, (list, tuple)) or not names:
            raise TypeError("sort_values by must be a column name or a non-empty list of names")
        for name in names:
            if not isinstance(name, str):
                raise TypeError(f"sort_values by takes column names, which are str, not {type(name).__name__}")
        flags = [ascending] * len(names) if isinstance(ascending, bool) else ascending
        if not isinstance(flags, (list, tuple)) or not all(isinstance(f, bool) for f in flags):
            raise TypeError("sort_values ascending must be a bool or a list of bools")
        if len(flags) != len(names):
            raise ValueError(f"Length of ascending ({len(flags)}) != length of by ({len(names)})")
        if na_position not in ("first", "last"):
            raise ValueError(f"invalid na_position: {na_position}")
        _ops.require_columns(names, self._plan.columns)
        keys = tuple(
            _ops.SortKey(name, descending=not up, nulls_first=na_position == "first")
            for name, up in zip(names, flags)
        )
        return self._derive(_ops.sort(self._plan, keys))

    def head(self, n: int = 5) -> DataFrame:
        """The first `n` rows of an ordered frame; of an unordered one, some
        `n` rows (a frame that was not sorted promises no row order)."""
        if isinstance(n, bool) or not isinstance(n, int):
            raise TypeError(f"head(n) takes an int, not {type(n).__name__}")
        if n < 0:
            raise UnsupportedOperation(
                f"head({n}) keeps all rows but the last {-n}, which needs the row count: "
                "sort with sort_values(...) and take the rows you want with head(k)"
            )
        plan = self._plan
        if isinstance(plan, _ops.Limit) and plan.offset == 0:
            # head of a head is one limit, so the limit stays over the sort
            # that orders the frame.
            return self._derive(_ops.limit(plan.child, min(plan.n, n)))
        return self._derive(_ops.limit(plan, n))

    def tail(self, n: int = 5) -> DataFrame:
        """The last `n` rows of a sorted frame, in the frame's order: the
        first `n` rows by the sort's keys reversed, sorted back by its keys.
        Of rows that tie at the cut, any are taken. An unsorted frame has no
        last rows, and a frame cut by `head` has the row count to find them
        by: both are refused."""
        if isinstance(n, bool) or not isinstance(n, int):
            raise TypeError(f"tail(n) takes an int, not {type(n).__name__}")
        if n < 0:
            raise UnsupportedOperation(
                f"tail({n}) keeps all rows but the first {-n}, which needs the row count: "
                "sort with sort_values(...) and take the rows you want with tail(k)"
            )
        plan = self._plan
        if isinstance(plan, (_ops.Limit, _ops.TopN)):
            raise UnsupportedOperation(
                f"tail({n}) of a frame cut by head() takes the last of the first rows, which needs the row "
                "count: take the tail before the head"
            )
        if not isinstance(plan, _ops.Sort):
            raise UnsupportedOperation(
                f"tail({n}) takes the last rows by order, and an unsorted frame has none: "
                "sort with sort_values(...) first"
            )
        reversed_keys = tuple(
            _ops.SortKey(k.column, descending=not k.descending, nulls_first=not k.nulls_first) for k in plan.keys
        )
        return self._derive(_ops.Sort(_ops.TopN(plan.child, reversed_keys, n), plan.keys))

    # ---- missing values, names and types ----------------------------------

    def fillna(
        self,
        value: object = None,
        *,
        axis: int | str | None = None,
        inplace: bool = False,
        limit: int | None = None,
        method: str | None = None,
        downcast: object = None,
    ) -> DataFrame:
        """A frame with each missing value (NULL, and NaN in a float column)
        replaced: by `value` in every column, or by `{column: value}` in those
        columns only. The value is a literal of the column's type: an int for
        an int32 or int64 column, an int or a float for a float32 or float64
        one, a bool, a str. Builds one projection; an empty dict changes
        nothing."""
        if inplace is not False:
            raise UnsupportedOperation(
                "fillna(inplace=True) changes the frame in place, and komira frames do not change: "
                "use the frame fillna returns"
            )
        if axis is not None and (isinstance(axis, bool) or axis not in (0, "index")):
            raise UnsupportedOperation(f"fillna(axis={axis!r}) fills along each row, and a plan fills columns: use axis=0")
        if limit is not None:
            raise UnsupportedOperation(
                f"fillna(limit={limit!r}) fills only the first values of a run, which needs row order: "
                "leave limit out"
            )
        if method is not None:
            raise UnsupportedOperation(
                f"fillna(method={method!r}) fills from the row before or after, which needs row order: "
                "fill with a value, as fillna(0)"
            )
        if downcast is not None:
            raise UnsupportedOperation(
                f"fillna(downcast={downcast!r}) changes the columns' types after filling: "
                "cast the columns afterwards with astype()"
            )
        if value is None:
            raise ValueError("Must specify a fill 'value' or 'method'.")
        columns = self._plan.columns
        dtypes = self.dtypes
        scalar = not isinstance(value, dict)
        if scalar:
            fills = {name: value for name in columns}
            _verbs.no_series_fill(value)
        else:
            for name, each in value.items():
                if not isinstance(name, str):
                    raise TypeError(f"fillna value names columns with str, not a {type(name).__name__}")
                _verbs.no_series_fill(each)
            _ops.require_columns(tuple(value), columns)
            fills = value
        items = tuple(
            (
                name,
                _verbs.fill_column(name, dtypes[name], fills[name], scalar),
            )
            for name in columns
            if name in fills
        )
        filled = {name for name, _ in items}
        plan = _ops.with_columns(self._plan, items)
        return self._ordered(plan, lambda keys: not any(k.column in filled for k in keys))

    def dropna(
        self,
        *,
        axis: int | str = 0,
        how: str = _UNSET,
        thresh: int = _UNSET,
        subset: str | list[str] | tuple[str, ...] | None = None,
        inplace: bool = False,
        ignore_index: bool = False,
    ) -> DataFrame:
        """The rows where every one of the `subset` columns (all columns when
        None) holds a value, `how="any"`, the default; or where at least one
        does, `how="all"`. A value is not NULL, and in a float column not NaN.
        Builds one filter. An empty subset keeps every row under
        `how="any"`, with no node, and no row under `how="all"`, as pandas
        does. `ignore_index` is accepted and does nothing, since a frame has
        no index."""
        if inplace is not False:
            raise UnsupportedOperation(
                "dropna(inplace=True) changes the frame in place, and komira frames do not change: "
                "use the frame dropna returns"
            )
        _groupby._check_bool(ignore_index, "ignore_index", "dropna")
        if isinstance(axis, bool) or axis not in (0, 1, "index", "columns"):
            raise ValueError(f"No axis named {axis} for object type DataFrame")
        if axis in (1, "columns"):
            raise UnsupportedOperation(
                f"dropna(axis={axis!r}) drops the columns that hold a missing value, and a plan's columns "
                "cannot depend on its rows: choose the columns by name with df[[...]]"
            )
        if how is not _UNSET and thresh is not _UNSET:
            raise TypeError("You cannot set both the how and thresh arguments at the same time.")
        if thresh is not _UNSET and thresh is not None:
            raise UnsupportedOperation(
                f"dropna(thresh={thresh!r}) counts the values each row holds, which this release does not build: "
                'use how="any" or how="all", or name the columns with subset='
            )
        if how is _UNSET:
            how = "any"
        if how not in ("any", "all"):
            raise ValueError(f"invalid how option: {how}")
        columns = self._plan.columns
        if subset is None:
            names = columns
        else:
            names = (subset,) if isinstance(subset, str) else subset
            if not isinstance(names, (list, tuple)):
                raise TypeError(f"dropna subset takes column names, not a {type(subset).__name__}")
            for name in names:
                if not isinstance(name, str):
                    raise TypeError(f"dropna subset takes column names, which are str, not {type(name).__name__}")
            _ops.require_columns(tuple(names), columns)
        names = tuple(dict.fromkeys(names))
        if not names:
            if how == "any":
                return self._derive(self._plan)
            # pandas keeps a row when any of no columns is present: no row.
            return self._ordered(_ops.filter_(self._plan, _ops.Lit(False)), lambda keys: True)
        dtypes = self.dtypes
        tests = tuple(present(_ops.ColRef(name), dtypes[name]) for name in names)
        predicate = _ops.and_all(tests) if how == "any" else _ops.or_all(tests)
        return self._ordered(_ops.filter_(self._plan, predicate), lambda keys: True)

    def rename(
        self,
        mapper: object = None,
        *,
        index: object = None,
        columns: object = None,
        axis: int | str | None = None,
        copy: bool | None = None,
        inplace: bool = False,
        level: object = None,
        errors: str = "ignore",
    ) -> DataFrame:
        """A frame with columns renamed: `columns` is a dict of old name to
        new name, or a function called with each column name; `mapper` with
        `axis=1` is the same. A name the frame lacks is skipped with
        `errors="ignore"`, pandas' default, and is a `KeyError` with
        `errors="raise"`. Two columns given one name are refused. A frame has
        no index to rename. Builds one projection, none when no name changes."""
        if inplace is not False:
            raise UnsupportedOperation(
                "rename(inplace=True) changes the frame in place, and komira frames do not change: "
                "use the frame rename returns"
            )
        if copy is not None:
            _groupby._check_bool(copy, "copy", "rename")
        if errors not in ("ignore", "raise"):
            raise ValueError(f"rename errors must be 'ignore' or 'raise', not {errors!r}")
        if level is not None:
            raise UnsupportedOperation(
                f"rename(level={level!r}) picks a level of a multi-level index, and komira frames have no "
                "index: rename columns with rename(columns={...})"
            )
        if mapper is not None and (index is not None or columns is not None):
            raise TypeError("Cannot specify both 'mapper' and any of 'index' or 'columns'")
        if index is not None:
            raise UnsupportedOperation(
                "rename(index=...) renames row labels, and komira frames have no index: "
                "rename columns with rename(columns={...})"
            )
        if mapper is not None:
            if isinstance(axis, bool) or (axis is not None and axis not in (0, 1, "index", "columns")):
                raise ValueError(f"No axis named {axis} for object type DataFrame")
            if axis not in (1, "columns"):
                where = "by default" if axis is None else f"with axis={axis!r}"
                raise UnsupportedOperation(
                    f"rename(mapper) renames row labels {where}, and komira frames have no index: "
                    "rename columns with rename(columns={...})"
                )
            columns = mapper
        if columns is None:
            raise TypeError("rename() needs the new names: pass columns={'old': 'new'}, or a function of the name")
        existing = self._plan.columns
        if isinstance(columns, dict):
            for old, new in columns.items():
                if not isinstance(old, str) or not isinstance(new, str):
                    raise TypeError("rename columns maps column names to new names, and both are str")
            if errors == "raise":
                _ops.require_columns(tuple(columns), existing)
            wanted = {old: new for old, new in columns.items() if old in existing}
        elif callable(columns):
            wanted = {}
            for old in existing:
                new = columns(old)
                if not isinstance(new, str):
                    raise TypeError(
                        f"rename columns function returned a value of type {type(new).__name__} for the column {old!r}, "
                        "and column names are str"
                    )
                wanted[old] = new
        else:
            raise TypeError(f"rename columns takes a dict or a function, not a {type(columns).__name__}")
        return self._renamed(wanted)

    def _renamed(self, wanted: dict[str, str]) -> DataFrame:
        """The frame with the columns in `wanted` (old name to new) renamed,
        one projection, none when no name changes."""
        mapping = {old: new for old, new in wanted.items() if old != new}
        if not mapping:
            return self._derive(self._plan)
        seen: set[str] = set()
        for old in self._plan.columns:
            new = mapping.get(old, old)
            if new in seen:
                raise ValueError(
                    f"rename would give two columns the name {new!r}: rename the other column too, "
                    "or pick another name"
                )
            seen.add(new)
        plan = _ops.rename(self._plan, mapping)
        return self._ordered(plan, lambda keys: all(mapping.get(k.column, k.column) == k.column for k in keys))

    def add_prefix(self, prefix: str, axis: int | str | None = None) -> DataFrame:
        """A frame with `prefix` put before every column name."""
        _verbs.check_label_axis(axis, "add_prefix")
        if not isinstance(prefix, str):
            raise TypeError(f"add_prefix prefix must be a str, not {type(prefix).__name__}")
        return self._renamed({name: prefix + name for name in self._plan.columns})

    def add_suffix(self, suffix: str, axis: int | str | None = None) -> DataFrame:
        """A frame with `suffix` put after every column name."""
        _verbs.check_label_axis(axis, "add_suffix")
        if not isinstance(suffix, str):
            raise TypeError(f"add_suffix suffix must be a str, not {type(suffix).__name__}")
        return self._renamed({name: name + suffix for name in self._plan.columns})

    def astype(self, dtype: object, copy: bool | None = None, errors: str = "raise") -> DataFrame:
        """A frame with every column cast to `dtype`, or the columns of
        `{column: dtype}` cast to theirs. A dtype is named as `Series.astype`
        takes it (komira/_cast.py); a column that already has it is left as it
        is. Builds one projection. `errors="ignore"` is refused: a plan cannot
        decide before it runs which values fail to cast."""
        from . import _cast

        _cast.check_astype_args(copy, errors, "astype")
        columns = self._plan.columns
        if isinstance(dtype, dict):
            for name in dtype:
                if not isinstance(name, str):
                    raise TypeError(f"astype dtype names columns with str, not a {type(name).__name__}")
            _ops.require_columns(tuple(dtype), columns)
            targets = dtype
        else:
            targets = {name: dtype for name in columns}
        current = self.dtypes
        items = []
        for name in columns:
            if name not in targets:
                continue
            node = _cast.cast_node(_ops.ColRef(name), current[name], targets[name], "astype")
            if node is not None:
                items.append((name, node))
        cast = {name for name, _ in items}
        plan = _ops.with_columns(self._plan, tuple(items))
        return self._ordered(plan, lambda keys: not any(k.column in cast for k in keys))

    # ---- group-by and reductions (komira/_groupby.py) ---------------------

    def groupby(
        self,
        by: str | list[str] | tuple[str, ...] | None = None,
        *,
        as_index: bool = True,
        sort: bool = True,
        dropna: bool = True,
    ) -> GroupBy:
        """The groups of the rows by the key columns `by`. Its reductions give
        a frame of the keys and one column per output; `as_index` changes
        nothing, since a frame has no index to put the keys in. `sort=True`
        sorts the answer by the keys, missing keys last; `dropna=True` leaves
        out the rows with a missing key, `dropna=False` keeps their group."""
        return GroupBy._new(self, by, as_index, sort, dropna)

    def agg(self, arg: object = None, **named: object) -> DataFrame:
        """The frame reduced to one row: by named aggregates,
        `agg(total=("v", "sum"), n=("v", "size"))`; by a dict of column to
        reduction, each output named after its column; or by one reduction's
        name, as its method."""
        return _groupby.agg_frame(self, arg, named)

    aggregate = agg

    def sum(
        self, axis: int | str = 0, skipna: bool = True, numeric_only: bool = False, min_count: int = 0
    ) -> DataFrame:
        """One row: the sum of each column, missing values skipped, 0 for a
        column with none (`min_count=0`) or missing (`min_count=1`); each
        column numeric or boolean, unless `numeric_only=True` leaves the
        others out."""
        _groupby._check_axis(axis, "sum")
        _groupby._check_skipna(skipna, "sum")
        return _groupby.reduce_frame(self, "sum", numeric_only, _groupby._sum_zero(min_count, "sum"))

    def mean(self, axis: int | str = 0, skipna: bool = True, numeric_only: bool = False) -> DataFrame:
        """One row: the mean of each column, as float64."""
        return self._reduce("mean", axis, skipna, numeric_only)

    def median(self, axis: int | str = 0, skipna: bool = True, numeric_only: bool = False) -> DataFrame:
        """One row: the median of each column, as float64."""
        return self._reduce("median", axis, skipna, numeric_only)

    def std(
        self, axis: int | str = 0, skipna: bool = True, ddof: int = 1, numeric_only: bool = False
    ) -> DataFrame:
        """One row: the sample standard deviation (ddof=1) of each column."""
        _groupby._check_ddof(ddof, "std")
        return self._reduce("std", axis, skipna, numeric_only)

    def var(
        self, axis: int | str = 0, skipna: bool = True, ddof: int = 1, numeric_only: bool = False
    ) -> DataFrame:
        """One row: the sample variance (ddof=1) of each column."""
        _groupby._check_ddof(ddof, "var")
        return self._reduce("var", axis, skipna, numeric_only)

    def min(self, axis: int | str = 0, skipna: bool = True, numeric_only: bool = False) -> DataFrame:
        """One row: the least value of each column, of its type."""
        return self._reduce("min", axis, skipna, numeric_only)

    def max(self, axis: int | str = 0, skipna: bool = True, numeric_only: bool = False) -> DataFrame:
        """One row: the greatest value of each column, of its type."""
        return self._reduce("max", axis, skipna, numeric_only)

    def count(self, axis: int | str = 0, numeric_only: bool = False) -> DataFrame:
        """One row: the count of values that are not missing in each column,
        as int64."""
        _groupby._check_axis(axis, "count")
        return _groupby.reduce_frame(self, "count", numeric_only)

    def nunique(self, axis: int | str = 0, dropna: bool = True) -> DataFrame:
        """One row: the count of distinct values that are not missing in each
        column, as int64."""
        _groupby._check_axis(axis, "nunique")
        _groupby._check_dropna(dropna, "nunique")
        return _groupby.reduce_frame(self, "nunique")

    def _reduce(self, how: str, axis: object, skipna: object, numeric_only: bool) -> DataFrame:
        _groupby._check_axis(axis, how)
        _groupby._check_skipna(skipna, how)
        return _groupby.reduce_frame(self, how, numeric_only)

    def drop_duplicates(
        self,
        subset: str | list[str] | tuple[str, ...] | None = None,
        *,
        keep: str | bool = "first",
        inplace: bool = False,
        ignore_index: bool = False,
    ) -> DataFrame:
        """The rows with duplicates removed. Equal rows are the same row, so
        `keep="first"` and `keep="last"` give one of each; `keep=False` gives
        only the rows no other row equals. `subset` must name every column (in
        any order); `ignore_index` is accepted and does nothing, since a frame
        has no index. The answer has no row order."""
        if inplace is not False:
            raise UnsupportedOperation(
                "drop_duplicates(inplace=True) changes the frame in place, and komira frames do not change: "
                "use the frame drop_duplicates returns"
            )
        if not isinstance(ignore_index, bool):
            raise TypeError(f"drop_duplicates ignore_index must be a bool, not {type(ignore_index).__name__}")
        return _groupby.drop_duplicates(self, subset, keep)

    # ---- joins (komira/_merge.py) ------------------------------------------

    def merge(
        self,
        right: DataFrame,
        how: str = "inner",
        on: str | list[str] | None = None,
        left_on: str | list[str] | None = None,
        right_on: str | list[str] | None = None,
        left_index: bool = False,
        right_index: bool = False,
        sort: bool = False,
        suffixes: tuple[str | None, str | None] = ("_x", "_y"),
        copy: object = None,
        indicator: bool = False,
        validate: str | None = None,
    ) -> DataFrame:
        """This frame joined with `right`, a frame of the same session, on
        the key columns `on` (named alike in both) or `left_on` and
        `right_on` (by default the columns both frames have). `how` is
        "inner", "left", "right", "outer" or "cross". The answer has this
        frame's columns, then `right`'s: a key named alike once, and every
        other name both frames have suffixed by `suffixes`. A missing key
        matches nothing. The answer has no row order unless `sort=True`
        sorts it by the keys. `copy` is accepted and does nothing, since a
        plan holds no rows."""
        return _merge.merge(
            self, right, how, on, left_on, right_on, left_index, right_index, sort, suffixes, indicator, validate
        )

    def copy(self, deep: bool = True) -> DataFrame:
        """An equal frame: the same plan, on the same session. `deep` is
        accepted and changes nothing, since a plan holds no rows."""
        return self._derive(self._plan)

    # ---- terminals ------------------------------------------------------

    def _plan_bytes(self) -> bytes:
        return _encoder().encode_plan(self._plan, self._sources).SerializeToString()

    def materialize(self) -> Result:
        """Runs the frame's plan on its session and returns the answer as a
        `Result`, read once (`to_arrow`, `to_pandas`, ...). Every call runs
        the plan again. A plan the engine refuses raises its error here."""
        return self._session._plan_stream(self._plan_bytes())

    def to_parquet(self, path: str | os.PathLike[str], *, compression: str | None = "snappy") -> None:
        """Runs the frame's plan and writes all its rows to the Parquet file
        `path`, in the frame's order when it is ordered. `compression` is
        "snappy" (the default), "gzip", "zstd", "lz4" or None. The file is
        written whole or not at all, an existing one is replaced, and
        the call returns None once the write is complete. A relative `path` is
        resolved against the working directory now and `~` is expanded. The
        engine's refusal raises its error: a URL (`UnsupportedOperation`,
        `STORAGE_URL_REFUSED`), a directory that is not there (`StorageError`),
        a column type the writer does not write (`UnsupportedOperation`)."""
        dest = _write.destination(path, "to_parquet")
        codec = _write.parquet_codec(compression)
        _write.write(self._session, self._plan, self._sources, dest, "parquet", codec)

    def to_csv(
        self,
        path_or_buf: str | os.PathLike[str] | None = None,
        *,
        compression: str | dict | None = "infer",
        index: bool = True,
    ) -> None:
        """Runs the frame's plan and writes all its rows to the CSV file
        `path_or_buf`: a header line of the column names, then a line per row,
        in the frame's order when it is ordered. The format is CSV whatever the
        file's extension. `compression` is "infer" (gzip for `.gz`, zstd for
        `.zst`, else none), "gzip", "zstd" or None. `index` is accepted and
        changes nothing, since a frame has no index. Path, replacement,
        refusals and the return are as for `to_parquet`; there is no string
        result: a `path_or_buf` of None is refused."""
        dest = _write.destination(path_or_buf, "to_csv")
        if not isinstance(index, bool):
            raise TypeError(f"to_csv index must be a bool, not {type(index).__name__}")
        codec = _write.text_codec(compression, dest, "to_csv")
        _write.write(self._session, self._plan, self._sources, dest, "csv", codec)

    def to_json(
        self,
        path_or_buf: str | os.PathLike[str] | None = None,
        *,
        orient: str | None = None,
        lines: bool = False,
        compression: str | dict | None = "infer",
    ) -> None:
        """Runs the frame's plan and writes all its rows to the newline-delimited
        JSON file `path_or_buf`, one object per row, in the frame's order when
        it is ordered; only `orient="records"` with `lines=True` is written. The
        format is JSON whatever the file's extension, and `compression`, path,
        replacement, refusals and the return are as for `to_csv`."""
        dest = _write.destination(path_or_buf, "to_json")
        if orient != "records" or lines is not True:
            raise UnsupportedOperation(
                f"to_json(orient={orient!r}, lines={lines!r}) writes one JSON document, which komira "
                'does not write: pass orient="records", lines=True for one object per line'
            )
        codec = _write.text_codec(compression, dest, "to_json")
        _write.write(self._session, self._plan, self._sources, dest, "jsonl", codec)

    def explain(self) -> str:
        """The engine's text of the frame's plan; runs nothing."""
        return self._session._plan_render(self._plan_bytes())

    # ---- no dunder runs a query -----------------------------------------

    def __len__(self) -> int:
        raise UnsupportedOperation(f"len() of a komira DataFrame needs a query to run: {_TERMINAL}")

    def __bool__(self) -> bool:
        raise UnsupportedOperation(f"the truth value of a komira DataFrame needs a query to run: {_TERMINAL}")

    def __iter__(self):
        raise UnsupportedOperation(f"iterating a komira DataFrame needs a query to run: {_TERMINAL}")

    def __array__(self, *args: object, **kwargs: object) -> object:
        raise UnsupportedOperation(f"converting a komira DataFrame to an array needs a query to run: {_TERMINAL}")

    def __arrow_c_stream__(self, requested_schema: object | None = None) -> object:
        raise UnsupportedOperation(
            f"reading a komira DataFrame as Arrow needs a query to run: {_TERMINAL}, which exports the Arrow stream"
        )

    # ---- attributes never fall through ----------------------------------

    def __getattr__(self, name: str) -> object:
        message = None
        if not name.startswith("_"):
            message = _refusals.refused(_refusals.FRAME, name)
            try:
                columns = object.__getattribute__(self, "_plan").columns
            except AttributeError:
                columns = ()
            if message is None and name in columns:
                message = (
                    f"'DataFrame' object has no attribute '{name}': "
                    f'a column is not an attribute; write df["{name}"]'
                )
        if message is None:
            message = f"'DataFrame' object has no attribute '{name}'"
        raise AttributeError(message, name=name, obj=self)

    def __setattr__(self, name: str, value: object) -> None:
        if name.startswith("_"):
            object.__setattr__(self, name, value)
            return
        raise AttributeError(
            f"cannot set the attribute '{name}' of a komira DataFrame: to set a column, "
            f'write df["{name}"] = ...',
            name=name,
            obj=self,
        )


# ---- concat ---------------------------------------------------------------


def concat(
    objs: list[DataFrame] | tuple[DataFrame, ...],
    *,
    axis: int | str = 0,
    join: str = "outer",
    ignore_index: bool = False,
    keys: object = None,
    levels: object = None,
    names: object = None,
    verify_integrity: bool = False,
    sort: bool = False,
    copy: bool | None = None,
) -> DataFrame:
    """The rows of the frames one after another: a union of inputs of one
    schema. The frames are on one session (their readers may differ, and the
    answer reads the sources of all); their columns are the same set (a frame
    with them in another order is reordered to the first frame's by a
    projection), of one type each, and allow missing values alike. pandas
    would fill missing columns with NaN and upcast types, and this refuses
    both. The answer has no row order. `ignore_index` and `copy` are accepted
    and do nothing, since a frame has no index and a plan holds no rows; with
    equal column sets `join` "outer" and "inner" mean the same."""
    return _verbs.concat_frames(
        objs,
        axis=axis,
        join=join,
        ignore_index=ignore_index,
        keys=keys,
        levels=levels,
        names=names,
        verify_integrity=verify_integrity,
        sort=sort,
        copy=copy,
    )


# ---- readers -------------------------------------------------------------


def _session_of(session: Session | None) -> Session:
    if session is None:
        return default_session()
    if not isinstance(session, Session):
        raise TypeError(f"session must be a komira Session, not {type(session).__name__}")
    return session


def _scan_frame(session: Session, path: str, fmt: str, schema: object, source: object) -> DataFrame:
    wire = _wire()
    fields = tuple(_ops.Field(f.name, wire.arrow_name(f.arrow_type_id)) for f in schema.fields)
    return DataFrame._new(session, _ops.scan(path, fmt, fields), {path: source})


def read_parquet(path: str | os.PathLike[str], *, session: Session | None = None) -> DataFrame:
    """A frame of the local Parquet file at `path`. Its schema is read from
    the footer now, so a missing or unreadable file raises here; the rows are
    read when the frame runs. `session` is the session the frame runs on, the
    process's default session when None. A relative `path` is resolved
    against the working directory now and `~` is expanded."""
    session = _session_of(session)
    path = _local_path(path)
    schema_bytes = session._parquet_schema(path)
    schema = _wire().pb.WireSchema.FromString(schema_bytes)
    return _scan_frame(session, path, "parquet", schema, _encoder().parquet_source(path, schema_bytes))


def _skiprows(skiprows: object) -> int:
    """The number of lines `read_csv(skiprows=...)` skips: None is 0, an int
    from 0 up is itself; a collection of row numbers or a function is refused
    as unbuilt, a bool or another type as a TypeError, a negative int as a
    ValueError."""
    if skiprows is None:
        return 0
    if callable(skiprows) or (isinstance(skiprows, Iterable) and not isinstance(skiprows, (str, bytes))):
        raise UnsupportedOperation(
            f"read_csv(skiprows=<{type(skiprows).__name__}>) drops the rows it names or selects, "
            "which komira does not build: pass the number of lines to skip at the start of the file, or None"
        )
    if isinstance(skiprows, bool) or not isinstance(skiprows, int):
        raise TypeError("skiprows must be None or an int, not {}".format(type(skiprows).__name__))
    if skiprows < 0:
        raise ValueError("skiprows must be 0 or more, not {}".format(skiprows))
    return skiprows


def read_csv(
    path: str | os.PathLike[str],
    *,
    sep: str = ",",
    header: int | str | None = "infer",
    skiprows: int | None = None,
    session: Session | None = None,
) -> DataFrame:
    """A frame of the local CSV file at `path`, its column names and types
    inferred by the engine now, from the start of the file. `sep` is the one
    ASCII character between fields; `header` is "infer" or 0 when the first
    line holds the column names, None when it does not. `skiprows` is None
    or the number of lines (0 or more) to skip at the start of the file
    before the header, as SQL's `read_csv(..., skip = n)` does; a list of row
    numbers or a function of the row number, which pandas reads as rows to
    drop, is not built. Needs libkomira ABI 1.11 when `skiprows` is above 0.
    Failures, paths and `session` are as for `read_parquet`."""
    if header is None:
        has_header = False
    elif header == "infer" or (header == 0 and not isinstance(header, bool)):
        has_header = True
    else:
        raise UnsupportedOperation(
            f"read_csv(header={header!r}) reads the column names from another line than the first: "
            'use header="infer" (or 0) for names on the first line, or header=None for none'
        )
    skip = _skiprows(skiprows)
    session = _session_of(session)
    path = _local_path(path)
    binding = session._csv_binding(path, delimiter=sep, header=has_header, skip=skip)
    schema = _wire().pb.WireScanBinding.FromString(binding).schema
    return _scan_frame(session, path, "csv", schema, _encoder().binding_source(binding))


def read_json(
    path: str | os.PathLike[str],
    *,
    lines: bool = False,
    session: Session | None = None,
) -> DataFrame:
    """A frame of the local newline-delimited JSON file at `path` (one object
    per line), which needs `lines=True`, as in pandas; its column names and
    types are inferred by the engine now, from the leading records. Failures,
    paths and `session` are as for `read_parquet`."""
    if lines is not True:
        raise UnsupportedOperation(
            f"read_json(lines={lines!r}) reads one JSON document, which komira does not read: "
            "write one object per line and pass lines=True"
        )
    session = _session_of(session)
    path = _local_path(path)
    binding = session._json_binding(path)
    schema = _wire().pb.WireScanBinding.FromString(binding).schema
    return _scan_frame(session, path, "ndjson", schema, _encoder().binding_source(binding))
