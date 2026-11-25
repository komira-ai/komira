"""`LazyFrame`, the polars-shaped frame, its readers and `concat`.

A frame is a plan of the private node tree (komira._ops), the session it runs
on, the sources its scans read, and whether its rows are ordered. A verb
returns a new frame with a larger plan and runs nothing; `collect()` encodes
the plan as a `komira.plan.v1.WirePlanEnvelope` (komira._plan) and runs it on
the frame's session through the plan entry, `komira_plan_stream`, which
answers a `Result`. No SQL text is made anywhere on this path.

A reader reads its file's schema when it is called, through libkomira (the
schema of a Parquet file, the binding of a CSV or NDJSON file), so every verb
knows its frame's columns and their types, and a column the frame lacks is
refused at the verb that names it.

Row order (rules section 7): `sort` makes a frame ordered; `filter`, a
projection that keeps every sort key, `rename`, `head`, `limit` and `slice`
keep it ordered, and the plan's root stays a sort (a filter or projection goes
below it, a limit above it; over a limit, the sort is written again on top).
Every other verb makes the frame unordered. `tail` and `slice` with an offset
need an ordered frame.
"""

from __future__ import annotations

import os

from komira._errors import UnsupportedOperation
from komira._ops import (
    Aggregate,
    Cast,
    ColRef,
    Filter,
    Limit,
    Lit,
    Project,
    Sort,
    SortKey,
    TopN,
    and_all,
    drop_nulls,
    filter_,
    rename,
    require_columns,
    scan,
    select,
    sort,
    with_columns,
)
from komira._session import Result, Session, _local_path, default_session

from . import _names
from ._expr import Expr, col, lit
from ._scope import Scope

__all__ = ["LazyFrame", "concat", "scan_csv", "scan_ndjson", "scan_parquet"]


def _encoder():
    """The plan encoder, imported when a frame is first made: it needs the
    generated `komira.plan.v1` modules and protobuf, which `import komira`
    does not, and which the wheel does not ship yet."""
    try:
        from komira import _plan
    except ImportError as e:
        raise ImportError(
            "komira.pl needs the plan modules komira.plan.v1 and protobuf, which this "
            f"installation of komira does not have: {e}"
        ) from e
    return _plan


class LazyFrame:
    """A lazy, polars-shaped frame: a plan, run at `collect()`.

    Made by `scan_parquet`, `scan_ndjson` or `scan_csv`, and by the verbs of a
    frame. No verb, attribute or dunder runs a query: `len()`, `bool()`,
    `iter()` and the array protocols raise `UnsupportedOperation` naming
    `collect()`. `columns` and `schema` run nothing.
    """

    __slots__ = ("_session", "_plan", "_sources", "_order", "_fields")

    def __init__(self, session: Session, plan, sources: dict, order: tuple[SortKey, ...] | None) -> None:
        object.__setattr__(self, "_session", session)
        object.__setattr__(self, "_plan", plan)
        object.__setattr__(self, "_sources", sources)
        object.__setattr__(self, "_order", order)
        object.__setattr__(self, "_fields", None)

    # ---- the attribute rule (rules section 5) -------------------------------------

    def __getattr__(self, name: str):
        plan = object.__getattribute__(self, "_plan") if not name.startswith("_") else None
        raise _names.frame_missing(name, plan.columns if plan is not None else ())

    def __setattr__(self, name: str, value: object) -> None:
        if name.startswith("_"):
            object.__setattr__(self, name, value)
            return
        raise AttributeError(
            f"cannot set the attribute '{name}' of a LazyFrame: a frame is immutable; "
            "add or replace a column with with_columns(...)"
        )

    # ---- no dunder runs a query (rules section 2) ---------------------------------

    def _runs(self, what: str) -> UnsupportedOperation:
        return UnsupportedOperation(
            f"{what} needs the rows of the frame: run it with .collect(), which returns a Result"
        )

    def __len__(self) -> int:
        raise self._runs("len() of a LazyFrame")

    def __bool__(self) -> bool:
        raise self._runs("the truth value of a LazyFrame")

    def __iter__(self):
        raise self._runs("iterating a LazyFrame")

    def __array__(self, *args: object, **kwargs: object):
        raise self._runs("a LazyFrame as an array")

    def __arrow_c_stream__(self, requested_schema: object = None):
        raise self._runs("a LazyFrame as an Arrow stream")

    def __repr__(self) -> str:
        try:
            shown = ", ".join(f"{n}: {t}" for n, t in self.schema.items())
        except Exception:
            shown = ", ".join(self._plan.columns)
        return f"<komira.pl.LazyFrame [{shown}]>"

    # ---- what a frame knows without running ----------------------------------------

    def _wire_fields(self) -> tuple:
        if self._fields is None:
            envelope = _encoder().encode_plan(self._plan, self._sources)
            object.__setattr__(self, "_fields", tuple(envelope.plan.output_schema.fields))
        return self._fields

    @property
    def columns(self) -> list[str]:
        """The column names, in order."""
        return list(self._plan.columns)

    @property
    def width(self) -> int:
        """The number of columns."""
        return len(self._plan.columns)

    @property
    def schema(self) -> dict:
        """The columns and their types, as `{name: pyarrow.DataType}` in order."""
        from ._schema import arrow_type

        return {f.name: arrow_type(f) for f in self._wire_fields()}

    def collect_schema(self) -> dict:
        """The same as `schema`."""
        return self.schema

    # ---- building ----------------------------------------------------------------

    def _with(self, plan, order: tuple[SortKey, ...] | None) -> LazyFrame:
        return LazyFrame(self._session, plan, self._sources, order)

    def _scope(self, verb: str, *, aggregates: bool = False) -> Scope:
        return Scope(self._wire_fields(), verb, aggregates=aggregates)

    def _row_verb(self, plan) -> LazyFrame:
        """A frame of `plan`, which a filter or projection made from this
        frame's plan: ordered when the order survives it (rules section 7)."""
        if isinstance(plan, Sort):
            return self._with(plan, plan.keys)
        if self._order is None or plan == self._plan:
            return self._with(plan, self._order)
        keys = _carried(self._order, plan, self._plan)
        if keys is None:
            return self._with(plan, None)
        return self._with(Sort(plan, keys), keys)

    def _exprs(self, verb: str, exprs: tuple, named: dict) -> list[Expr]:
        out = []
        for item in exprs:
            if isinstance(item, (list, tuple)):
                out.extend(item)
            else:
                out.append(item)
        resolved = []
        for item in out:
            if isinstance(item, str):
                resolved.append(col(item))
            elif isinstance(item, Expr):
                resolved.append(item)
            else:
                raise TypeError(
                    f"{verb} takes column names and komira.pl expressions, not {type(item).__name__}"
                )
        for name, item in named.items():
            resolved.append(lit(item).alias(name))
        return resolved

    # ---- verbs ------------------------------------------------------------------

    def select(self, *exprs: object, **named: Expr) -> LazyFrame:
        """A frame of the given columns and expressions, in order, each under
        polars' output name. A select of aggregates only is one row (the
        AGGREGATE of the plan); an aggregate beside a row-wise value is not
        supported yet."""
        items = self._exprs("select", exprs, named)
        if not items:
            raise ValueError("select needs at least one column or expression")
        names = _unique_names("select", items)
        if any(e._has_agg for e in items):
            return self._aggregate(items, names)
        scope = self._scope("select")
        nodes = tuple(_column_literal(e._lower(scope)) for e in items)
        if not any(_reads_columns(n) for n in nodes):
            raise UnsupportedOperation(
                "select: an expression of literals only has no rows of the frame to "
                "give it; add it to the frame with with_columns(...)"
            )
        return self._row_verb(_project(self._plan, tuple(zip(names, nodes))))

    def _aggregate(self, items: list[Expr], names: list[str]) -> LazyFrame:
        scope = self._scope("select", aggregates=True)
        scope.reserve(names)
        nodes = [e._lower(scope) for e in items]
        child = self._plan.child if isinstance(self._plan, Sort) else self._plan
        aggs = scope.aggregates
        bare = [ColRef(slot) for slot, _ in aggs]
        if nodes == bare:
            plan = Aggregate(child, (), tuple((n, agg) for n, (_, agg) in zip(names, aggs)))
        else:
            plan = Project(Aggregate(child, (), aggs), tuple(zip(names, nodes)))
        return self._with(plan, None)

    def with_columns(self, *exprs: object, **named: Expr) -> LazyFrame:
        """The frame with the given expressions added as columns, or in place
        of the column of the same name (the plan of `build_with_columns_plan`:
        one PROJECT, the input columns in order, new ones appended)."""
        items = self._exprs("with_columns", exprs, named)
        if not items:
            return self
        names = _unique_names("with_columns", items)
        for e in items:
            if e._has_agg:
                raise UnsupportedOperation(
                    f"with_columns: '{e._name}' is an aggregate, which would be broadcast over "
                    "the rows (a window); that is not supported yet"
                )
        scope = self._scope("with_columns")
        nodes = [_column_literal(e._lower(scope)) for e in items]
        return self._row_verb(with_columns(self._plan, list(zip(names, nodes))))

    def filter(self, *predicates: Expr) -> LazyFrame:
        """The rows for which every predicate is true (a null is not true)."""
        if not predicates:
            raise ValueError("filter needs at least one predicate")
        scope = self._scope("filter")
        nodes = []
        for p in predicates:
            if not isinstance(p, Expr):
                raise TypeError(f"filter takes komira.pl expressions, not {type(p).__name__}")
            if p._has_agg:
                raise UnsupportedOperation(
                    "filter: a predicate over an aggregate needs a window, which is not supported yet"
                )
            nodes.append(scope.predicate(p._lower(scope), "filter"))
        return self._row_verb(filter_(self._plan, and_all(tuple(nodes))))

    def drop(self, *columns: str, strict: bool = True) -> LazyFrame:
        """The frame without the named columns. With `strict=False` a name the
        frame lacks is ignored."""
        names = _names_of("drop", columns)
        if strict:
            require_columns(names, self._plan.columns)
        kept = [c for c in self._plan.columns if c not in names]
        if not kept:
            raise UnsupportedOperation("drop: a frame with no columns is not supported")
        return self._row_verb(select(self._plan, kept))

    def rename(self, mapping, *, strict: bool = True) -> LazyFrame:
        """The frame with columns renamed by `mapping`, a dict of old to new
        names or a function of the old name, applied to the names now. With
        `strict=False` an old name the frame lacks is ignored."""
        if callable(mapping) and not isinstance(mapping, dict):
            mapping = {c: mapping(c) for c in self._plan.columns}
        if not isinstance(mapping, dict):
            raise TypeError(f"rename takes a dict or a function, not {type(mapping).__name__}")
        if not strict:
            mapping = {k: v for k, v in mapping.items() if k in self._plan.columns}
        return self._row_verb(rename(self._plan, mapping))

    def drop_nulls(self, subset: str | list[str] | None = None) -> LazyFrame:
        """The rows with no null in the subset of columns, every column when
        it is None (the FILTER of `drop_nulls_predicate`). A NaN is not null."""
        names = None if subset is None else _names_of("drop_nulls", (subset,))
        return self._row_verb(drop_nulls(self._plan, names))

    def sort(
        self,
        by,
        *more_by,
        descending: bool | list[bool] = False,
        nulls_last: bool | list[bool] = False,
        maintain_order: bool = False,
        multithreaded: bool = True,
    ) -> LazyFrame:
        """The frame sorted by the columns `by` and `more_by`. Nulls come first
        unless `nulls_last` (polars' default). Ties come out in no particular
        order: `maintain_order=True` is refused, as no sort in the plan is
        stable."""
        if maintain_order:
            raise UnsupportedOperation(
                "sort: maintain_order=True keeps tied rows in input order, and no sort in "
                "the plan is stable; sort by more columns to break the ties"
            )
        columns = self._sort_columns("sort", (by,) + more_by)
        down = _per_key("sort", "descending", descending, len(columns))
        last = _per_key("sort", "nulls_last", nulls_last, len(columns))
        keys = tuple(SortKey(c, d, not n) for c, d, n in zip(columns, down, last))
        return self._with(sort(self._plan, keys), keys)

    def _sort_columns(self, verb: str, by: tuple) -> list[str]:
        flat = []
        for item in by:
            flat.extend(item if isinstance(item, (list, tuple)) else [item])
        if not flat:
            raise ValueError(f"{verb} needs at least one column")
        scope = self._scope(verb)
        out = []
        for item in flat:
            if isinstance(item, str):
                item = col(item)
            if not isinstance(item, Expr):
                raise TypeError(f"{verb} takes column names and komira.pl.col(...), not {type(item).__name__}")
            node = item._lower(scope.row()) if not item._has_agg else None
            if not isinstance(node, ColRef):
                raise UnsupportedOperation(
                    f"{verb}: sorting by the expression '{item._name}' is not supported; add it "
                    "with with_columns(...) and sort by its name"
                )
            out.append(node.name)
        return out

    def top_k(self, k: int, *, by, reverse: bool | list[bool] = False) -> LazyFrame:
        """The `k` rows with the largest values of `by`, in no particular order
        (as polars promises none). A null is never preferred over a value;
        which of several tied rows at the boundary is kept is not specified."""
        return self._top("top_k", k, by, reverse, largest=True)

    def bottom_k(self, k: int, *, by, reverse: bool | list[bool] = False) -> LazyFrame:
        """The `k` rows with the smallest values of `by`, as `top_k`."""
        return self._top("bottom_k", k, by, reverse, largest=False)

    def _top(self, verb: str, k: int, by, reverse, *, largest: bool) -> LazyFrame:
        n = _count_arg(verb, "k", k)
        columns = self._sort_columns(verb, (by,))
        flip = _per_key(verb, "reverse", reverse, len(columns))
        keys = tuple(SortKey(c, largest != r, False) for c, r in zip(columns, flip))
        return self._with(TopN(self._plan, keys, n), None)

    def head(self, n: int = 5) -> LazyFrame:
        """The first `n` rows of an ordered frame; of an unordered one, some
        `n` rows (rules section 7)."""
        return self._with(Limit(self._plan, _count_arg("head", "n", n)), self._order)

    def limit(self, n: int = 5) -> LazyFrame:
        """The same as `head`."""
        return self._with(Limit(self._plan, _count_arg("limit", "n", n)), self._order)

    def slice(self, offset: int, length: int | None = None) -> LazyFrame:
        """`length` rows from row `offset` of an ordered frame. An offset other
        than 0 needs an ordered frame; a negative one, and an offset with no
        length, are not supported."""
        start = _count_arg("slice", "offset", offset)
        if length is None:
            raise UnsupportedOperation("slice: give a length; slice(offset) with no length is not supported")
        n = _count_arg("slice", "length", length)
        if start == 0:
            return self.head(n)
        self._need_order("slice with an offset")
        return self._with(Limit(self._plan, n, start), self._order)

    def tail(self, n: int = 5) -> LazyFrame:
        """The last `n` rows of an ordered frame, in its order."""
        count = _count_arg("tail", "n", n)
        keys = self._need_order("tail")
        flipped = tuple(SortKey(k.column, not k.descending, not k.nulls_first) for k in keys)
        base = self._plan.child if isinstance(self._plan, Sort) else self._plan
        return self._with(Sort(TopN(base, flipped, count), keys), keys)

    def _need_order(self, what: str) -> tuple[SortKey, ...]:
        if self._order is None:
            raise UnsupportedOperation(
                f"{what} needs an ordered frame, and a plan promises no row order "
                "unless it is sorted; sort(...) the frame first"
            )
        return self._order

    # ---- terminals ----------------------------------------------------------------

    def _encode(self) -> bytes:
        return _encoder().encode_plan(self._plan, self._sources).SerializeToString()

    def collect(self) -> Result:
        """Runs the plan on the frame's session and returns its answer, a
        `Result` read once (`to_arrow`, `to_polars`, ...). Each call runs the
        plan again. A plan the engine cannot run raises `KomiraError` (or
        `UnsupportedOperation`) with the engine's code and step."""
        return self._session._run_plan(self._encode())

    def explain(self) -> str:
        """The engine's text of the plan, which is not run."""
        return self._session._render_plan(self._encode())



def _carried(order: tuple[SortKey, ...], plan, below) -> tuple[SortKey, ...] | None:
    """The sort keys of `order` as the columns of `plan`, a filter or a
    projection over `below`, or None when a key does not reach its output
    unchanged."""
    if isinstance(plan, Filter):
        return order
    if not isinstance(plan, Project) or plan.child != below:
        return None
    out = []
    for key in order:
        name = next((n for n, node in plan.items if node == ColRef(key.column)), None)
        if name is None:
            return None
        out.append(SortKey(name, key.descending, key.nulls_first))
    return tuple(out)


def _project(plan, items: tuple) -> object:
    """A PROJECT of `items` over `plan`; under a root sort whose keys it keeps
    by name, below the sort; no node when the items are the plan's columns."""
    if isinstance(plan, Sort) and all((k.column, ColRef(k.column)) in items for k in plan.keys):
        return Sort(_project(plan.child, items), plan.keys)
    if items == tuple((c, ColRef(c)) for c in plan.columns):
        return plan
    return Project(plan, items)


def _column_literal(node):
    """An int literal that is a column of its own is an Int32, as polars
    types `lit(1)`; any other node is itself."""
    if isinstance(node, Lit) and isinstance(node.value, int) and not isinstance(node.value, bool):
        return Cast(node, "int32")
    return node


def _reads_columns(node) -> bool:
    from komira._ops import column_refs

    return len(column_refs(node)) > 0


def _unique_names(verb: str, items: list[Expr]) -> list[str]:
    names = [e._name for e in items]
    seen = set()
    for name in names:
        if name in seen:
            raise ValueError(
                f"{verb}: the output name '{name}' is produced by more than one expression; "
                "give each a name of its own with .alias(...)"
            )
        seen.add(name)
    return names


def _names_of(verb: str, values: tuple) -> list[str]:
    out = []
    for item in values:
        for name in item if isinstance(item, (list, tuple)) else [item]:
            if not isinstance(name, str):
                raise TypeError(f"{verb} takes column names, not {type(name).__name__}")
            out.append(name)
    return out


def _per_key(verb: str, what: str, value, count: int) -> list[bool]:
    if isinstance(value, bool):
        return [value] * count
    if isinstance(value, (list, tuple)) and all(isinstance(v, bool) for v in value):
        if len(value) != count:
            raise ValueError(
                f"{verb}: {what} has {len(value)} values for {count} sort columns"
            )
        return list(value)
    raise TypeError(f"{verb}: {what} must be a bool or a list of bools")


def _count_arg(verb: str, what: str, value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{verb}: {what} must be an int, not {type(value).__name__}")
    if value < 0:
        raise UnsupportedOperation(
            f"{verb}: a negative {what} counts from the end of the frame, which is not supported"
        )
    return value


# ---- readers -------------------------------------------------------------------


def _session_of(session: object) -> Session:
    if session is None:
        return default_session()
    if not isinstance(session, Session):
        raise TypeError(f"session must be a komira.Session, not {type(session).__name__}")
    return session


def _path_of(verb: str, source: object) -> str:
    if isinstance(source, (list, tuple)):
        raise UnsupportedOperation(f"{verb}: a list of files is not supported yet; read one file")
    return _local_path(source)


def _scan_frame(session: Session, path: str, fmt: str, source, schema) -> LazyFrame:
    from komira._plan._wire import arrow_name

    fields = [(f.name, arrow_name(f.arrow_type_id)) for f in schema.fields]
    return LazyFrame(session, scan(path, fmt, fields), {path: source}, None)


def scan_parquet(source: str | os.PathLike[str], *, session: Session | None = None) -> LazyFrame:
    """A frame of the local Parquet file `source`, whose schema is read now
    (a missing or unreadable file raises here). It runs on `session`, the
    process's default session when None."""
    s = _session_of(session)
    path = _path_of("scan_parquet", source)
    plan = _encoder()
    data = s._parquet_schema(path)
    src = plan.parquet_source(path, data)
    return _scan_frame(s, path, "parquet", src, src.parquet.schema)


def scan_ndjson(source: str | os.PathLike[str], *, session: Session | None = None) -> LazyFrame:
    """A frame of the local newline-delimited JSON file `source`, with the
    column types the engine infers now. It runs on `session`, the process's
    default session when None."""
    s = _session_of(session)
    path = _path_of("scan_ndjson", source)
    src = _encoder().binding_source(s._json_binding(path))
    return _scan_frame(s, path, "ndjson", src, src.binding.schema)


def scan_csv(
    source: str | os.PathLike[str],
    *,
    separator: str = ",",
    has_header: bool = True,
    session: Session | None = None,
) -> LazyFrame:
    """A frame of the local CSV file `source`, with the column types the
    engine infers now; `separator` is one ASCII character. It runs on
    `session`, the process's default session when None."""
    s = _session_of(session)
    path = _path_of("scan_csv", source)
    src = _encoder().binding_source(s._csv_binding(path, delimiter=separator, has_header=has_header))
    return _scan_frame(s, path, "csv", src, src.binding.schema)


def concat(items, *, how: str = "vertical", rechunk: bool = False, parallel: bool = True) -> LazyFrame:
    """The rows of every frame, one frame after another (a UNION ALL). With
    `how="vertical"`, the one supported, every frame has the same column
    names in the same order and the same types, which is checked here. The frames run on one
    session. The result is unordered."""
    if how != "vertical":
        raise UnsupportedOperation(f"concat: how={how!r} is not supported; only how='vertical' is")
    frames = list(items)
    if not frames:
        raise ValueError("concat needs at least one frame")
    for f in frames:
        if not isinstance(f, LazyFrame):
            raise TypeError(f"concat takes komira.pl LazyFrames, not {type(f).__name__}")
    first = frames[0]
    if len(frames) == 1:
        return first
    sources = dict(first._sources)
    for i, f in enumerate(frames[1:], start=1):
        if f._session is not first._session:
            raise UnsupportedOperation(
                f"concat: frame {i} runs on another session than frame 0; frames of two "
                "sessions never meet"
            )
        if f._plan.columns != first._plan.columns:
            raise UnsupportedOperation(
                f"concat: frame {i} has the columns ({', '.join(f._plan.columns)}) and frame 0 "
                f"has ({', '.join(first._plan.columns)}); how='vertical' needs the same names "
                "in the same order"
            )
        theirs = f.schema
        for name, t in first.schema.items():
            if theirs[name] != t:
                raise UnsupportedOperation(
                    f"concat: the column '{name}' is of type {theirs[name]} in frame {i} and "
                    f"{t} in frame 0; cast it to one type first"
                )
        for path, src in f._sources.items():
            sources.setdefault(path, src)
    from komira._ops import concat as union

    return LazyFrame(first._session, union([f._plan for f in frames]), sources, None)
