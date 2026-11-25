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
  `sort_values` and `head`. Each derives the output schema now, as the engine
  will, so `columns`, `dtypes` and `repr` run nothing and an unknown column is
  a `KeyError` at the verb that names it.
- `groupby` gives a `GroupBy`, and `agg`, `sum`, `mean`, `median`, `std`,
  `var`, `min`, `max`, `count` and `nunique` reduce the whole frame to one
  row; each builds one aggregate node (komira/_groupby.py).
  `drop_duplicates` builds a distinct over every column.
- Row order (section 7): a sort makes a frame ordered; a filter, a projection
  that keeps the sort keys, an `assign` that replaces none of them and `head`
  keep it ordered, the builder placing filters and projections under the sort
  and a limit above it, and a sort above a limit when a verb comes after one.
  A reduction and `drop_duplicates` give an unordered frame, except that
  `groupby(sort=True)` sorts by its keys.
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
from collections.abc import Callable
from types import ModuleType
from typing import TYPE_CHECKING

from . import _groupby, _ops, _refusals, _write
from ._errors import UnsupportedOperation
from ._groupby import GroupBy
from ._series import Series, operand
from ._session import Result, Session, _local_path, default_session

if TYPE_CHECKING:
    from .plan.v1 import plan_pb2

__all__ = ["DataFrame", "read_csv", "read_json", "read_parquet"]

_TERMINAL = "run it with .materialize() and read the Result"


def _encoder() -> ModuleType:
    """komira._plan, imported on first use: it imports the generated plan modules."""
    from . import _plan

    return _plan


def _wire() -> ModuleType:
    from ._plan import _wire

    return _wire


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

    def _field_of(self, node: _ops.Node) -> plan_pb2.WireField:
        """The field the engine derives for `node` over this frame's columns."""
        return _encoder().expr_field(node, self._fields)

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

    def _ordered(self, plan: _ops.Plan, keep: Callable[[tuple[_ops.SortKey, ...]], bool]) -> DataFrame:
        """The frame of `plan`, a verb's plan over this frame: when this frame
        is ordered, `keep(keys)` says the verb kept its order, and the plan's
        root is a limit or another node the order does not pass, the plan
        gets a sort by the same keys on top."""
        keys = self._order()
        if keys is not None and keep(keys) and not isinstance(plan, (_ops.Sort, _ops.TopN)):
            inner = plan.child if isinstance(plan, _ops.Limit) else None
            if not isinstance(inner, (_ops.Sort, _ops.TopN)):
                plan = _ops.Sort(plan, keys)
        return self._derive(plan)

    # ---- subscripts -----------------------------------------------------

    def __getitem__(self, key: object) -> DataFrame | Series:
        """`df["x"]` is the column `x`, `df[["a", "b"]]` the frame of those
        columns, `df[cond]` the rows where the boolean Series `cond` (or a
        function of the frame returning one) is true."""
        if callable(key) and not isinstance(key, Series):
            key = key(self)
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
        cond._bound_node(self)
        predicate = cond._predicate()
        return self._ordered(_ops.filter_(self._plan, predicate), lambda keys: True)

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
        an earlier one, as in pandas. Builds one projection."""
        items: dict[str, _ops.Node] = {}
        for name, value in columns.items():
            if callable(value) and not isinstance(value, Series):
                current = self._derive(_ops.with_columns(self._plan, tuple(items.items()))) if items else self
                result = value(current)
                if isinstance(result, Series) and result._frame is self:
                    # A Series of this frame, as a plain value would be: it
                    # reads the columns as they were before this call.
                    node = operand(self, result, "assign()")
                else:
                    node = _ops.substitute(operand(current, result, "assign()"), items)
            else:
                node = operand(self, value, "assign()")
            items[name] = node
        plan = _ops.with_columns(self._plan, tuple(items.items()))
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


def read_csv(
    path: str | os.PathLike[str],
    *,
    sep: str = ",",
    header: int | str | None = "infer",
    session: Session | None = None,
) -> DataFrame:
    """A frame of the local CSV file at `path`, its column names and types
    inferred by the engine now, from the start of the file. `sep` is the one
    ASCII character between fields; `header` is "infer" or 0 when the first
    line holds the column names, None when it does not. Failures, paths and
    `session` are as for `read_parquet`."""
    if header is None:
        has_header = False
    elif header == "infer" or (header == 0 and not isinstance(header, bool)):
        has_header = True
    else:
        raise UnsupportedOperation(
            f"read_csv(header={header!r}) reads the column names from another line than the first: "
            'use header="infer" (or 0) for names on the first line, or header=None for none'
        )
    session = _session_of(session)
    path = _local_path(path)
    binding = session._csv_binding(path, delimiter=sep, header=has_header)
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
