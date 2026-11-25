"""`GroupBy` and the reductions of a pandas-shaped `DataFrame`
(docs/design/dataframe_surface.md, sections 7 and 8).

Every reduction is one AGGREGATE plan node, run like any other verb's plan at
the frame's terminal: `df.groupby(keys)` and its reductions group by the key
columns, and the frame's own reductions (`df.agg(...)`, `df.sum()`, ...) group
by nothing and give one row. No SQL text is written.

- The keys and the aggregates are columns of the answer, keys first: a komira
  frame has no index to hold them (ruling 1). So `as_index` changes nothing.
- `groupby(sort=True)`, pandas' default, puts a sort on the keys, missing keys
  last, above the aggregate (ruling 2); `sort=False` adds none and the answer
  has no row order. `dropna=True`, the default, filters out the rows with a
  missing key below the aggregate; `dropna=False` keeps their group (ruling 3).
- A reduction's pandas name maps to one engine aggregate: `sum`, `mean`,
  `median`, `min`, `max`, `count` (values that are not missing), `size`
  (rows), `nunique` (distinct values that are not missing), `std` and `var`
  (the sample ones, ddof=1).
- `sum`, `mean`, `median`, `std` and `var` need a numeric or boolean column
  (ruling 4): a reduction of every column names the first one that is not,
  unless `numeric_only=True` leaves it out. pandas counts True as 1: a
  boolean column is summed as `CASE WHEN b = true THEN 1 ELSE 0 END` (a
  missing value adds 0, as it is skipped), and cast to int64 for
  `sum(min_count=1)` and to float64 for the others, where a missing value
  must stay missing.
- A sum of nothing is 0, as in pandas' `min_count=0` (ruling 10): the sum is
  read through `CASE WHEN s IS NOT NULL THEN s ELSE 0 END` above the
  aggregate. `min_count=1` keeps the missing sum.
- Missing values are NULL. A NaN is a value here: pandas' NaN-is-missing
  (ruling 6) needs an `isnan` test the plan's vocabulary lacks.
- A Python function as an aggregate is an aggregate UDF, which no query runs
  yet: it is refused by name, as are the choices that need row order.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from . import _ops, _refusals
from ._errors import UnsupportedOperation

if TYPE_CHECKING:
    from ._frame import DataFrame

__all__ = ["GroupBy", "reduce_frame"]

# The pandas name of each reduction, and the engine aggregate it builds; `size`
# is count() of rows.
_FUNCS = {
    "sum": "sum",
    "mean": "mean",
    "median": "median",
    "std": "stddev_samp",
    "var": "var_samp",
    "min": "min",
    "max": "max",
    "count": "count",
    "nunique": "count_distinct",
    "size": "count",
}
_SUPPORTED = ", ".join(sorted(_FUNCS))
# The reductions defined only over numbers (ruling 4).
_NUMERIC_ONLY = frozenset({"sum", "mean", "median", "std", "var"})
_NUMERIC_TYPES = frozenset(
    {
        "bool",
        "int8",
        "int16",
        "int32",
        "int64",
        "uint8",
        "uint16",
        "uint32",
        "uint64",
        "float16",
        "float32",
        "float64",
        "decimal128",
        "decimal256",
    }
)
_REDUCTION_HINT = "select the columns to reduce first, or pass numeric_only=True to leave it out"
_AGG_HINT = "reduce it with min, max, count, nunique or size"
# Row order picks the answer of these, so they are refused inside agg() as
# their GroupBy attributes are (komira/_refusals.py).
_ROW_ORDER = frozenset({"first", "last", "nth", "cumcount"})


class _Item:
    """One output column of an aggregate: its name, the reduction and the
    column it reads (None for `size`), and whether an empty sum is 0."""

    __slots__ = ("name", "how", "column", "zero")

    def __init__(self, name: str, how: str, column: str | None, zero: bool = True) -> None:
        self.name = name
        self.how = how
        self.column = column
        self.zero = zero


def _is_numeric(dtype: str) -> bool:
    return dtype in _NUMERIC_TYPES


def _check_func(func: object, where: str) -> str:
    """`func`, a reduction's name as agg() is given it, or the refusal."""
    if callable(func):
        raise UnsupportedOperation(
            f"{where} with a Python function runs it once per group, an aggregate UDF that this release "
            f"does not run: name a reduction ({_SUPPORTED})"
        )
    if not isinstance(func, str):
        raise TypeError(f"{where} takes the name of a reduction, a str, not a {type(func).__name__}")
    if func in _ROW_ORDER:
        raise UnsupportedOperation(
            f"{where} with {func!r} picks values by row order, which a frame does not have: "
            "use 'min' or 'max' of an ordered key"
        )
    if func not in _FUNCS:
        raise UnsupportedOperation(f"{where} has no reduction {func!r}: name one of {_SUPPORTED}")
    return func


def _agg_node(dtypes: dict[str, str], item: _Item, where: str, hint: str) -> _ops.Agg:
    """The engine aggregate of `item` over columns of the types `dtypes`."""
    if item.how == "size":
        return _ops.Agg("count")
    ref: _ops.Node = _ops.ColRef(item.column)
    dtype = dtypes[item.column]
    if item.how in _NUMERIC_ONLY:
        if not _is_numeric(dtype):
            raise UnsupportedOperation(
                f"{where} needs numeric or boolean columns, and the column {item.column!r} is {dtype}: {hint}"
            )
        if dtype == "bool" and item.how == "sum" and item.zero:
            ref = _ops.When(((_ops.Compare("eq", ref, _ops.Lit(True)), _ops.Lit(1)),), _ops.Lit(0))
        elif dtype == "bool":
            ref = _ops.Cast(ref, "int64" if item.how == "sum" else "float64")
    return _ops.Agg(_FUNCS[item.how], (ref,))


def _zero(dtype: str, precision: int, scale: int) -> _ops.Node:
    """The 0 of a sum's type: an int literal for int64 and float64 (a float
    CASE makes it a float64 literal), a cast one for decimal128 and uint64;
    a sum of another type (decimal256) is refused."""
    if dtype in ("int64", "float64"):
        return _ops.Lit(0)
    if dtype == "decimal128":
        return _ops.Cast(_ops.Lit(0), None, arrow="decimal128", precision=precision, scale=scale)
    if dtype not in ("uint64",):
        raise UnsupportedOperation(
            f"sum() of a {dtype} column cannot be 0 when the column has no values, since the plan has no "
            f"{dtype} literal: pass min_count=1, where a sum of nothing is missing"
        )
    return _ops.Cast(_ops.Lit(0), dtype)


def _aggregate(
    frame: DataFrame,
    keys: tuple[str, ...],
    items: list[_Item],
    *,
    sort: bool,
    dropna: bool,
    where: str,
    hint: str,
) -> DataFrame:
    """The frame of `items` over `frame`, grouped by `keys` (none for one row
    of the whole frame)."""
    names = list(keys)
    for item in items:
        if item.name in names:
            what = "a group key" if item.name in keys else "another output column"
            raise ValueError(f"{where}: the output column {item.name!r} is named twice: it is also {what}")
        names.append(item.name)
    if not names:
        raise UnsupportedOperation(f"{where} has no column to reduce: select the columns to reduce first")
    dtypes = frame.dtypes
    aggs = tuple((item.name, _agg_node(dtypes, item, where, hint)) for item in items)
    plan = frame._plan
    if keys and dropna:
        plan = _ops.filter_(plan, _ops.and_all(tuple(_ops.Unary("is_not_null", _ops.ColRef(k)) for k in keys)))
    plan = _ops.aggregate(plan, keys, aggs)
    sums = [item.name for item in items if item.how == "sum" and item.zero]
    if sums:
        fields = {f.name: f for f in frame._derive(plan)._fields}
        plan = _ops.with_columns(
            plan,
            tuple(
                (
                    name,
                    _ops.When(
                        ((_ops.Unary("is_not_null", _ops.ColRef(name)), _ops.ColRef(name)),),
                        _zero(
                            frame._type_name(fields[name]),
                            fields[name].decimal_precision,
                            fields[name].decimal_scale,
                        ),
                    ),
                )
                for name in sums
            ),
        )
    if keys and sort:
        plan = _ops.sort(plan, tuple(_ops.SortKey(k) for k in keys))
    return frame._derive(plan)


# ---- the argument checks the reductions share --------------------------------


def _check_bool(value: object, name: str, verb: str) -> None:
    if not isinstance(value, bool):
        raise TypeError(f"{verb} {name} must be a bool, not {type(value).__name__}")


def _check_skipna(skipna: object, verb: str) -> None:
    _check_bool(skipna, "skipna", verb)
    if not skipna:
        raise UnsupportedOperation(
            f"{verb}(skipna=False) is missing for a column that holds a missing value, "
            "which this release does not build: use skipna=True"
        )


def _check_ddof(ddof: object, verb: str) -> None:
    if isinstance(ddof, bool) or not isinstance(ddof, int):
        raise TypeError(f"{verb} ddof must be an int, not {type(ddof).__name__}")
    if ddof != 1:
        raise UnsupportedOperation(f"{verb}(ddof={ddof}) is not supported: the sample one, ddof=1, is")


def _sum_zero(min_count: object, verb: str) -> bool:
    """Whether a sum of nothing is 0 (`min_count=0`) or missing (`1`)."""
    if isinstance(min_count, bool) or not isinstance(min_count, int):
        raise TypeError(f"{verb} min_count must be an int, not {type(min_count).__name__}")
    if min_count not in (0, 1):
        raise UnsupportedOperation(
            f"{verb}(min_count={min_count}) is not supported: use min_count=0, where a sum of nothing "
            "is 0, or min_count=1, where it is missing"
        )
    return min_count == 0


def _check_min_count(min_count: object, verb: str) -> None:
    """min and max of nothing are missing for min_count -1, 0 and 1 alike."""
    if isinstance(min_count, bool) or not isinstance(min_count, int):
        raise TypeError(f"{verb} min_count must be an int, not {type(min_count).__name__}")
    if min_count > 1:
        raise UnsupportedOperation(
            f"{verb}(min_count={min_count}) is not supported: min and max of fewer values are missing "
            "only for min_count of 1 or less"
        )


def _check_dropna(dropna: object, verb: str) -> None:
    _check_bool(dropna, "dropna", verb)
    if not dropna:
        raise UnsupportedOperation(
            f"{verb}(dropna=False) counts a missing value as one more value, which this release does not "
            "build: use dropna=True"
        )


def _check_axis(axis: object, verb: str) -> None:
    if axis not in (0, "index") or isinstance(axis, bool):
        raise UnsupportedOperation(
            f"{verb}(axis={axis!r}) reduces each row, and a plan reduces columns: use axis=0"
        )


def _parse_agg(
    values: tuple[str, ...],
    columns: tuple[str, ...],
    single: bool,
    arg: object,
    named: dict[str, object],
    where: str,
) -> list[_Item] | str:
    """The items of an agg() call, or the name of the reduction when agg()
    is given one name (it then runs as that reduction's method). A named or
    dict aggregate may read any of the frame's `columns`, a key too, as in
    pandas. `single` is a GroupBy of one selected column, `values[0]`, where
    a named aggregate is a reduction's name and a list names its columns."""
    if arg is not None and named:
        raise TypeError(f"{where} takes a reduction or keyword aggregates, not both")
    if arg is None and not named:
        raise TypeError("Must provide 'func' or tuples of '(column, aggfunc).")
    if named:
        items = []
        for out, spec in named.items():
            if single:
                items.append(_Item(out, _check_func(spec, where), None if spec == "size" else values[0]))
                continue
            if not isinstance(spec, tuple) or len(spec) != 2:
                raise TypeError(
                    f'{where} takes each keyword as (column, reduction), as in total=("v", "sum"), '
                    f"not a {type(spec).__name__}"
                )
            column, func = spec
            if not isinstance(column, str):
                raise TypeError(f"{where} names a column with a str, not a {type(column).__name__}")
            _ops.require_columns((column,), columns)
            func = _check_func(func, where)
            items.append(_Item(out, func, None if func == "size" else column))
        return items
    if isinstance(arg, str) or callable(arg):
        return _check_func(arg, where)
    if isinstance(arg, dict):
        items = []
        for column, func in arg.items():
            if not isinstance(column, str):
                raise TypeError(f"{where} names a column with a str, not a {type(column).__name__}")
            if isinstance(func, (list, tuple)):
                raise UnsupportedOperation(
                    f"{where} with a list of reductions for {column!r} names its columns by two levels, "
                    'which a komira frame does not have: name each output, as agg(total=("v", "sum"))'
                )
            _ops.require_columns((column,), columns)
            func = _check_func(func, where)
            items.append(_Item(column, func, None if func == "size" else column))
        return items
    if isinstance(arg, (list, tuple)):
        if not single:
            raise UnsupportedOperation(
                f"{where} with a list of reductions names its columns by two levels, which a komira frame "
                'does not have: name each output, as agg(total=("v", "sum"))'
            )
        funcs = [_check_func(func, where) for func in arg]
        return [_Item(func, func, None if func == "size" else values[0]) for func in funcs]
    raise TypeError(
        f"{where} takes a reduction's name, a dict of column to reduction, or keyword aggregates, "
        f"not a {type(arg).__name__}"
    )


def _keys_of(by: object) -> tuple[str, ...]:
    if isinstance(by, str):
        return (by,)
    if isinstance(by, (list, tuple)):
        keys = tuple(by)
        if not keys:
            raise ValueError("No group keys passed!")
        for key in keys:
            if not isinstance(key, str):
                raise TypeError(f"groupby takes column names, which are str, not {type(key).__name__}")
        if len(set(keys)) != len(keys):
            raise ValueError("groupby names a key twice: " + ", ".join(keys))
        return keys
    if by is None:
        raise TypeError("You have to supply one of 'by' and 'level'")
    raise UnsupportedOperation(
        f"groupby({type(by).__name__}) groups by values that are not a column of the frame: "
        "assign them as a column with assign(), then group by its name"
    )


class GroupBy:
    """The groups of a komira `DataFrame` by its key columns, made by
    `df.groupby(by)`: each reduction is a frame of the keys and one column
    per output, and runs nothing."""

    __slots__ = ("_frame", "_keys", "_sort", "_dropna", "_selection", "_single")

    def __init__(self, *args: object, **kwargs: object) -> None:
        raise TypeError('a komira GroupBy is made by a frame: df.groupby("key")')

    @classmethod
    def _of(
        cls,
        frame: DataFrame,
        keys: tuple[str, ...],
        sort: bool,
        dropna: bool,
        selection: tuple[str, ...] | None = None,
        single: bool = False,
    ) -> GroupBy:
        out = object.__new__(cls)
        object.__setattr__(out, "_frame", frame)
        object.__setattr__(out, "_keys", keys)
        object.__setattr__(out, "_sort", sort)
        object.__setattr__(out, "_dropna", dropna)
        object.__setattr__(out, "_selection", selection)
        object.__setattr__(out, "_single", single)
        return out

    @classmethod
    def _new(cls, frame: DataFrame, by: object, as_index: object, sort: object, dropna: object) -> GroupBy:
        """`df.groupby(...)`: the keys checked against the frame's columns now."""
        keys = _keys_of(by)
        for name, value in (("as_index", as_index), ("sort", sort), ("dropna", dropna)):
            _check_bool(value, name, "groupby")
        _ops.require_columns(keys, frame._plan.columns)
        # The frame's plan as it is now: a later df["x"] = ... does not reach
        # this GroupBy.
        return cls._of(frame.copy(), keys, sort, dropna)

    # ---- the columns it reduces ------------------------------------------

    @property
    def _values(self) -> tuple[str, ...]:
        if self._selection is not None:
            return self._selection
        return tuple(c for c in self._frame._plan.columns if c not in self._keys)

    def __getitem__(self, key: object) -> GroupBy:
        """`gb["v"]` and `gb[["v", "w"]]`: the groups reducing those columns."""
        single = isinstance(key, str)
        if single:
            names = (key,)
        elif isinstance(key, (list, tuple)):
            names = tuple(key)
            for name in names:
                if not isinstance(name, str):
                    raise TypeError(f"a GroupBy is subscripted with column names, which are str, not {type(name).__name__}")
        else:
            raise TypeError(f"a GroupBy is subscripted with a column name or a list of names, not a {type(key).__name__}")
        _ops.require_columns(names, self._frame._plan.columns)
        for name in names:
            if name in self._keys:
                raise ValueError(f"the column {name!r} is a group key, and its groups already hold it once")
        if len(set(names)) != len(names):
            raise ValueError("a GroupBy subscript names a column twice: " + ", ".join(names))
        return GroupBy._of(self._frame, self._keys, self._sort, self._dropna, names, single)

    # ---- agg -------------------------------------------------------------

    def _run(self, items: list[_Item], where: str, hint: str) -> DataFrame:
        return _aggregate(
            self._frame, self._keys, items, sort=self._sort, dropna=self._dropna, where=where, hint=hint
        )

    def _reduce(self, how: str, numeric_only: bool = False, zero: bool = True) -> DataFrame:
        where = f"{how}()"
        _check_bool(numeric_only, "numeric_only", how)
        columns = self._values
        if numeric_only and how in _NUMERIC_ONLY | {"min", "max", "count"}:
            dtypes = self._frame.dtypes
            columns = tuple(c for c in columns if _is_numeric(dtypes[c]))
        return self._run([_Item(c, how, c, zero) for c in columns], where, _REDUCTION_HINT)

    def agg(self, arg: object = None, **named: object) -> DataFrame:
        """The groups reduced: by named aggregates, `agg(total=("v", "sum"))`
        (on one selected column `agg(total="sum")`); by a dict of column to
        reduction, each output named after its column; by one reduction's
        name, as its method; or, on one selected column, by a list of names,
        each output named after its reduction."""
        parsed = _parse_agg(self._values, self._frame._plan.columns, self._single, arg, named, "agg()")
        if isinstance(parsed, str):
            return getattr(self, parsed)()
        return self._run(parsed, "agg()", _AGG_HINT)

    aggregate = agg

    # ---- the reductions ---------------------------------------------------

    def sum(self, numeric_only: bool = False, min_count: int = 0, skipna: bool = True) -> DataFrame:
        """Each group's sum of every value column (or the selected ones),
        missing values skipped; a sum of nothing is 0 (`min_count=0`) or
        missing (`min_count=1`)."""
        _check_skipna(skipna, "sum")
        return self._reduce("sum", numeric_only, _sum_zero(min_count, "sum"))

    def mean(self, numeric_only: bool = False, skipna: bool = True) -> DataFrame:
        """Each group's mean, as float64, missing values skipped."""
        _check_skipna(skipna, "mean")
        return self._reduce("mean", numeric_only)

    def median(self, numeric_only: bool = False, skipna: bool = True) -> DataFrame:
        """Each group's median, as float64: the mean of the two middle values
        of an even count."""
        _check_skipna(skipna, "median")
        return self._reduce("median", numeric_only)

    def std(self, ddof: int = 1, numeric_only: bool = False, skipna: bool = True) -> DataFrame:
        """Each group's sample standard deviation (ddof=1), as float64;
        missing for a group of one value."""
        _check_ddof(ddof, "std")
        _check_skipna(skipna, "std")
        return self._reduce("std", numeric_only)

    def var(self, ddof: int = 1, numeric_only: bool = False, skipna: bool = True) -> DataFrame:
        """Each group's sample variance (ddof=1), as float64; missing for a
        group of one value."""
        _check_ddof(ddof, "var")
        _check_skipna(skipna, "var")
        return self._reduce("var", numeric_only)

    def min(self, numeric_only: bool = False, min_count: int = -1, skipna: bool = True) -> DataFrame:
        """Each group's least value of every column, of the column's type."""
        _check_min_count(min_count, "min")
        _check_skipna(skipna, "min")
        return self._reduce("min", numeric_only)

    def max(self, numeric_only: bool = False, min_count: int = -1, skipna: bool = True) -> DataFrame:
        """Each group's greatest value of every column, of the column's type."""
        _check_min_count(min_count, "max")
        _check_skipna(skipna, "max")
        return self._reduce("max", numeric_only)

    def count(self) -> DataFrame:
        """Each group's count of the values that are not missing, per column,
        as int64."""
        return self._reduce("count")

    def nunique(self, dropna: bool = True) -> DataFrame:
        """Each group's count of distinct values that are not missing, per
        column, as int64."""
        _check_dropna(dropna, "nunique")
        return self._reduce("nunique")

    def size(self) -> DataFrame:
        """Each group's row count, as the int64 column `size`."""
        return self._run([_Item("size", "size", None)], "size()", _REDUCTION_HINT)

    def __repr__(self) -> str:
        return "<komira.GroupBy by " + ", ".join(self._keys) + ">"

    # ---- no dunder runs a query -------------------------------------------

    def __iter__(self):
        raise UnsupportedOperation(
            "iterating a komira GroupBy needs the groups' rows: reduce them with agg() and run the frame "
            "with .materialize()"
        )

    def __len__(self) -> int:
        raise UnsupportedOperation(
            "len() of a komira GroupBy needs a query to run: count the groups with .size() and materialize()"
        )

    # ---- attributes never fall through ------------------------------------

    def __getattr__(self, name: str) -> object:
        message = None if name.startswith("_") else _refusals.refused(_refusals.GROUPBY, name)
        if message is None:
            message = f"'GroupBy' object has no attribute '{name}'"
        raise AttributeError(message, name=name, obj=self)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(
            f"cannot set the attribute '{name}' of a komira GroupBy: a GroupBy is part of a plan and does not change",
            name=name,
            obj=self,
        )


# ---- the frame's own reductions ----------------------------------------------


def reduce_frame(frame: DataFrame, how: str, numeric_only: bool = False, zero: bool = True) -> DataFrame:
    """`df.<how>()`: one row, one column per column of the frame."""
    return GroupBy._of(frame, (), False, False)._reduce(how, numeric_only, zero)


def agg_frame(frame: DataFrame, arg: object, named: dict[str, object]) -> DataFrame:
    """`df.agg(...)`: one row."""
    return GroupBy._of(frame, (), False, False).agg(arg, **named)


def drop_duplicates(frame: DataFrame, subset: object, keep: object) -> DataFrame:
    """`df.drop_duplicates(subset, keep=...)` over every column: a DISTINCT,
    or for `keep=False` the rows no other row equals (an AGGREGATE by every
    column with count(*) = 1, then the columns)."""
    columns = frame._plan.columns
    if subset is not None:
        names = (subset,) if isinstance(subset, str) else subset
        if not isinstance(names, (list, tuple)):
            raise TypeError(f"drop_duplicates subset takes column names, not a {type(subset).__name__}")
        for name in names:
            if not isinstance(name, str):
                raise TypeError(f"drop_duplicates subset takes column names, which are str, not {type(name).__name__}")
        _ops.require_columns(tuple(names), columns)
        if set(names) != set(columns):
            listed = list(names)
            raise UnsupportedOperation(
                f"drop_duplicates(subset={listed!r}) keeps one whole row of each group of rows equal on "
                f"those columns, which this release does not build: keep only those columns first, as "
                f"df[{listed!r}].drop_duplicates()"
            )
    if keep is False:
        count = "count"
        while count in columns:
            count = "_" + count
        plan = _ops.aggregate(frame._plan, columns, ((count, _ops.Agg("count")),))
        plan = _ops.filter_(plan, _ops.Compare("eq", _ops.ColRef(count), _ops.Lit(1)))
        return frame._derive(_ops.select(plan, columns))
    if keep not in ("first", "last"):
        raise ValueError("keep must be either \"first\", \"last\" or False")
    # Rows equal on every column are the same row, so "first" and "last"
    # keep the same one.
    return frame._derive(_ops.distinct(frame._plan))
