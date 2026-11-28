"""The relational plan nodes: one frozen dataclass per plan operator.

Each node checks its fields when it is built: the Python type of every field,
the vocabulary of every operator name, the arity of aggregates, and that every
column an expression names exists in the node's input. A node's output column
names are computed once and read through `columns`. Column types are not
tracked; a `Scan` carries its declared type tokens unchanged.
"""

from __future__ import annotations

from collections.abc import Iterator
from dataclasses import dataclass, field

from ._columns import require_columns, require_unique, unknown_column
from ._expr import EXPR_NODES, Alias, Node, UdfSpec, is_predicate
from ._vocab import (
    AGG_FUNCS,
    AGG_K_ARG,
    AGG_TWO_ARG,
    AGG_ZERO_OR_ONE_ARG,
    FRAME_BOUNDS,
    FRAME_UNITS,
    JOIN_HOWS,
    KEYLESS_HOWS,
    LEFT_ONLY_HOWS,
    RIGHT_SUFFIX,
    SOURCE_FORMATS,
    WINDOW_AGGREGATE,
    WINDOW_FUNCS,
    WINDOW_OFFSET,
    WINDOW_RANKING,
    WRITE_CODECS,
    WRITE_FORMATS,
)
from ._walk import column_refs

__all__ = [
    "Agg",
    "Aggregate",
    "Distinct",
    "Field",
    "Filter",
    "Frame",
    "Join",
    "Limit",
    "MapBatches",
    "PLAN_NODES",
    "Plan",
    "Project",
    "Scan",
    "Sort",
    "SortKey",
    "TopN",
    "Union",
    "Unnest",
    "WindowExpr",
    "Write",
    "WriteTarget",
    "walk_plan",
]


# ---------------------------------------------------------------------------
# Field checks
# ---------------------------------------------------------------------------


def _need_tuple(value: object, field_name: str, owner: str) -> None:
    if not isinstance(value, tuple):
        raise TypeError(
            f"{owner}.{field_name} must be a tuple, not {type(value).__name__}"
        )


def _need_str(value: object, field_name: str, owner: str) -> None:
    if not isinstance(value, str):
        raise TypeError(
            f"{owner}.{field_name} must be a str, not {type(value).__name__}"
        )


def _need_name(value: object, field_name: str, owner: str) -> None:
    _need_str(value, field_name, owner)
    if value == "":
        raise ValueError(f"{owner}.{field_name} must not be empty")


def _need_bool(value: object, field_name: str, owner: str) -> None:
    if not isinstance(value, bool):
        raise TypeError(
            f"{owner}.{field_name} must be a bool, not {type(value).__name__}"
        )


def _need_int(value: object, field_name: str, owner: str, minimum: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(
            f"{owner}.{field_name} must be an int, not {type(value).__name__}"
        )
    if value < minimum:
        raise ValueError(f"{owner}.{field_name} must be at least {minimum}")


def _need_op(op: object, vocab: frozenset[str], owner: str) -> None:
    if not isinstance(op, str):
        raise TypeError(f"{owner} op must be a str, not {type(op).__name__}")
    if op not in vocab:
        raise ValueError(f"{owner} op {op!r} is not one of: " + ", ".join(sorted(vocab)))


def _need_node(value: object, field_name: str, owner: str) -> None:
    if not isinstance(value, EXPR_NODES):
        raise TypeError(
            f"{owner}.{field_name} must be an expression node, not {type(value).__name__}"
        )


def _need_plan(value: object, field_name: str, owner: str) -> None:
    if isinstance(value, Write):
        raise TypeError("a Write can only be the root of a plan")
    if not isinstance(value, PLAN_NODES):
        raise TypeError(
            f"{owner}.{field_name} must be a plan node, not {type(value).__name__}"
        )


def _need_names(value: object, field_name: str, owner: str) -> None:
    _need_tuple(value, field_name, owner)
    for name in value:
        _need_name(name, field_name, owner)


def _set_columns(node: object, columns: tuple[str, ...]) -> None:
    object.__setattr__(node, "_columns", columns)


def _check_refs(node: Node, columns: tuple[str, ...], owner: str) -> None:
    """Every column the expression names is in `columns` and carries no side."""
    for ref in column_refs(node):
        if ref.side is not None:
            raise ValueError(
                f"{owner}: the column '{ref.name}' has a side, which only a join residual may carry"
            )
        if ref.name not in columns:
            raise unknown_column(ref.name, columns)


def _check_sort_keys(keys: object, columns: tuple[str, ...], owner: str) -> None:
    _need_tuple(keys, "keys", owner)
    if not keys:
        raise ValueError(f"{owner}.keys must not be empty")
    seen: set[str] = set()
    for key in keys:
        if not isinstance(key, SortKey):
            raise TypeError(
                f"{owner}.keys must hold SortKey values, not {type(key).__name__}"
            )
        if key.column not in columns:
            raise unknown_column(key.column, columns)
        if key.column in seen:
            raise ValueError(f"{owner}: the column '{key.column}' is a key more than once")
        seen.add(key.column)


# ---------------------------------------------------------------------------
# Support types
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Field:
    """A declared column of a scan: a name and an opaque type token."""

    name: str
    dtype: str

    def __post_init__(self) -> None:
        _need_name(self.name, "name", "Field")
        _need_name(self.dtype, "dtype", "Field")


@dataclass(frozen=True, slots=True)
class SortKey:
    """One sort key: a column, a direction and where nulls go."""

    column: str
    descending: bool = False
    nulls_first: bool = False

    def __post_init__(self) -> None:
        _need_name(self.column, "column", "SortKey")
        _need_bool(self.descending, "descending", "SortKey")
        _need_bool(self.nulls_first, "nulls_first", "SortKey")


@dataclass(frozen=True, slots=True)
class Agg:
    """An aggregate function over zero, one or two argument expressions."""

    func: str
    args: tuple[Node, ...] = ()
    k: int | None = None

    def __post_init__(self) -> None:
        _need_op(self.func, AGG_FUNCS, "Agg")
        _need_tuple(self.args, "args", "Agg")
        for arg in self.args:
            _need_node(arg, "args", "Agg")
        if self.func in AGG_ZERO_OR_ONE_ARG:
            expected, ok = "0 or 1", len(self.args) in (0, 1)
        elif self.func in AGG_TWO_ARG:
            expected, ok = "2", len(self.args) == 2
        else:
            expected, ok = "1", len(self.args) == 1
        if not ok:
            raise ValueError(
                f"Agg {self.func} takes {expected} argument(s), and was given {len(self.args)}"
            )
        if self.func in AGG_K_ARG:
            if self.k is None:
                raise ValueError(f"Agg {self.func} needs k")
            _need_int(self.k, "k", "Agg", 1)
        elif self.k is not None:
            raise ValueError(f"Agg {self.func} takes no k")


@dataclass(frozen=True, slots=True)
class Frame:
    """A window frame: units, a start bound and an end bound."""

    units: str
    start: str
    end: str
    start_offset: int = 0
    end_offset: int = 0

    def __post_init__(self) -> None:
        _need_op(self.units, FRAME_UNITS, "Frame units")
        _need_op(self.start, FRAME_BOUNDS, "Frame start")
        _need_op(self.end, FRAME_BOUNDS, "Frame end")
        _need_int(self.start_offset, "start_offset", "Frame", 0)
        _need_int(self.end_offset, "end_offset", "Frame", 0)
        if self.start == "unbounded_following":
            raise ValueError("Frame start cannot be unbounded_following")
        if self.end == "unbounded_preceding":
            raise ValueError("Frame end cannot be unbounded_preceding")


@dataclass(frozen=True, slots=True)
class WindowExpr:
    """A window function over a column, with partitioning, ordering and a frame."""

    func: str
    arg: str | None = None
    offset: int = 0
    partition_by: tuple[str, ...] = ()
    order_by: tuple[SortKey, ...] = ()
    frame: Frame | None = None

    def __post_init__(self) -> None:
        _need_op(self.func, WINDOW_FUNCS, "WindowExpr")
        func = self.func
        if func in WINDOW_RANKING:
            if self.arg is not None:
                raise ValueError(f"WindowExpr {func} takes no argument column")
        else:
            if self.arg is None:
                raise ValueError(f"WindowExpr {func} needs an argument column")
            _need_name(self.arg, "arg", "WindowExpr")
        if func == "ntile" or func == "nth_value":
            _need_int(self.offset, "offset", "WindowExpr", 1)
        elif func in WINDOW_OFFSET or func in WINDOW_AGGREGATE:
            _need_int(self.offset, "offset", "WindowExpr", 0)
        else:
            _need_int(self.offset, "offset", "WindowExpr", 0)
            if self.offset != 0:
                raise ValueError(f"WindowExpr {func} takes no offset")
        _need_names(self.partition_by, "partition_by", "WindowExpr")
        _need_tuple(self.order_by, "order_by", "WindowExpr")
        for key in self.order_by:
            if not isinstance(key, SortKey):
                raise TypeError(
                    f"WindowExpr.order_by must hold SortKey values, not {type(key).__name__}"
                )
        if self.frame is not None and not isinstance(self.frame, Frame):
            raise TypeError(
                f"WindowExpr.frame must be a Frame, not {type(self.frame).__name__}"
            )
        if (func in WINDOW_RANKING or func in ("lag", "lead")) and not self.order_by:
            raise ValueError(f"WindowExpr {func} needs an order_by")


def _check_window_refs(win: WindowExpr, columns: tuple[str, ...]) -> None:
    names: list[str] = []
    if win.arg is not None:
        names.append(win.arg)
    names.extend(win.partition_by)
    names.extend(key.column for key in win.order_by)
    require_columns(names, columns)


# ---------------------------------------------------------------------------
# Plan nodes
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class Scan:
    """A read of a file with a declared schema."""

    path: str
    format: str
    schema: tuple[Field, ...]
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_name(self.path, "path", "Scan")
        _need_op(self.format, SOURCE_FORMATS, "Scan format")
        _need_tuple(self.schema, "schema", "Scan")
        if not self.schema:
            raise ValueError("Scan.schema must not be empty")
        for column in self.schema:
            if not isinstance(column, Field):
                raise TypeError(
                    f"Scan.schema must hold Field values, not {type(column).__name__}"
                )
        names = tuple(column.name for column in self.schema)
        require_unique(names, "Scan")
        _set_columns(self, names)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class Filter:
    """Rows of the child for which the predicate is true."""

    child: Plan
    predicate: Node
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "Filter")
        _need_node(self.predicate, "predicate", "Filter")
        if not is_predicate(self.predicate):
            raise TypeError(
                f"Filter needs a predicate, not a {type(self.predicate).__name__}"
            )
        if isinstance(self.predicate, Alias):
            raise ValueError("Filter.predicate must not be an Alias")
        _check_refs(self.predicate, self.child.columns, "Filter")
        _set_columns(self, self.child.columns)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class Project:
    """Named expressions or window expressions computed from the child."""

    child: Plan
    items: tuple[tuple[str, Node | WindowExpr], ...]
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "Project")
        _need_tuple(self.items, "items", "Project")
        if not self.items:
            raise ValueError("Project.items must not be empty")
        child_columns = self.child.columns
        names: list[str] = []
        for item in self.items:
            if not isinstance(item, tuple) or len(item) != 2:
                raise TypeError("Project.items must hold (name, expression) pairs")
            name, expr = item
            _need_name(name, "item name", "Project")
            if isinstance(expr, WindowExpr):
                _check_window_refs(expr, child_columns)
            else:
                _need_node(expr, "items", "Project")
                if isinstance(expr, Alias):
                    raise ValueError(
                        f"Project item '{name}' must not be an Alias at the root; the item names it"
                    )
                _check_refs(expr, child_columns, "Project")
            names.append(name)
        output = tuple(names)
        require_unique(output, "Project")
        _set_columns(self, output)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class Aggregate:
    """Grouping keys followed by named aggregates."""

    child: Plan
    keys: tuple[str, ...]
    aggs: tuple[tuple[str, Agg], ...]
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "Aggregate")
        _need_names(self.keys, "keys", "Aggregate")
        _need_tuple(self.aggs, "aggs", "Aggregate")
        if not self.keys and not self.aggs:
            raise ValueError("Aggregate needs at least one key or one aggregate")
        child_columns = self.child.columns
        require_unique(self.keys, "Aggregate")
        require_columns(self.keys, child_columns)
        names: list[str] = []
        for item in self.aggs:
            if not isinstance(item, tuple) or len(item) != 2:
                raise TypeError("Aggregate.aggs must hold (name, Agg) pairs")
            name, agg = item
            _need_name(name, "agg name", "Aggregate")
            if not isinstance(agg, Agg):
                raise TypeError(
                    f"Aggregate.aggs must hold Agg values, not {type(agg).__name__}"
                )
            for arg in agg.args:
                _check_refs(arg, child_columns, "Aggregate")
            names.append(name)
        output = self.keys + tuple(names)
        require_unique(output, "Aggregate")
        _set_columns(self, output)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class Sort:
    """The child's rows ordered by the keys."""

    child: Plan
    keys: tuple[SortKey, ...]
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "Sort")
        _check_sort_keys(self.keys, self.child.columns, "Sort")
        _set_columns(self, self.child.columns)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class Limit:
    """At most `n` rows of the child after skipping `offset` rows."""

    child: Plan
    n: int
    offset: int = 0
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "Limit")
        _need_int(self.n, "n", "Limit", 0)
        _need_int(self.offset, "offset", "Limit", 0)
        _set_columns(self, self.child.columns)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class TopN:
    """The first `n` rows of the child in key order."""

    child: Plan
    keys: tuple[SortKey, ...]
    n: int
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "TopN")
        _check_sort_keys(self.keys, self.child.columns, "TopN")
        _need_int(self.n, "n", "TopN", 0)
        _set_columns(self, self.child.columns)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class Distinct:
    """The child's rows with duplicates removed, over all columns or a subset."""

    child: Plan
    subset: tuple[str, ...] | None = None
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "Distinct")
        if self.subset is not None:
            _need_names(self.subset, "subset", "Distinct")
            if not self.subset:
                raise ValueError("Distinct.subset must not be empty")
            require_unique(self.subset, "Distinct")
            require_columns(self.subset, self.child.columns)
        _set_columns(self, self.child.columns)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class Unnest:
    """The child with its list column `column` replaced by one row per
    element: the other columns repeat, and the column holds the element.
    A row whose list is empty or NULL gives no row, or one row holding NULL
    when `keep_empty` is true."""

    child: Plan
    column: str
    keep_empty: bool
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "Unnest")
        _need_name(self.column, "column", "Unnest")
        _need_bool(self.keep_empty, "keep_empty", "Unnest")
        require_columns((self.column,), self.child.columns)
        _set_columns(self, self.child.columns)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class Join:
    """Two inputs joined on key columns, a residual predicate, or both."""

    left: Plan
    right: Plan
    how: str
    left_on: tuple[str, ...] = ()
    right_on: tuple[str, ...] = ()
    residual: Node | None = None
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.left, "left", "Join")
        _need_plan(self.right, "right", "Join")
        _need_op(self.how, JOIN_HOWS, "Join")
        _need_names(self.left_on, "left_on", "Join")
        _need_names(self.right_on, "right_on", "Join")
        if self.residual is not None:
            _need_node(self.residual, "residual", "Join")
        if len(self.left_on) != len(self.right_on):
            raise ValueError(
                f"Join: left_on has {len(self.left_on)} column(s) and right_on {len(self.right_on)}"
            )
        has_keys = bool(self.left_on)
        if self.how in KEYLESS_HOWS:
            if has_keys or self.residual is not None:
                raise ValueError(f"Join {self.how} takes no keys and no residual")
        elif not has_keys and self.residual is None:
            raise ValueError(f"Join {self.how} needs keys or a residual")
        left_columns = self.left.columns
        right_columns = self.right.columns
        require_columns(self.left_on, left_columns)
        require_columns(self.right_on, right_columns)
        if self.residual is not None:
            self._check_residual(left_columns, right_columns)
        _set_columns(self, self._output_columns(left_columns, right_columns))

    def _check_residual(
        self, left_columns: tuple[str, ...], right_columns: tuple[str, ...]
    ) -> None:
        residual = self.residual
        if not is_predicate(residual):
            raise TypeError(
                f"Join residual must be a predicate, not a {type(residual).__name__}"
            )
        for ref in column_refs(residual):
            if ref.side is None:
                raise ValueError(
                    f"Join residual column '{ref.name}' has no side; give it side='left' or side='right'"
                )
            side_columns = left_columns if ref.side == "left" else right_columns
            if ref.name not in side_columns:
                raise unknown_column(ref.name, side_columns)

    def _output_columns(
        self, left_columns: tuple[str, ...], right_columns: tuple[str, ...]
    ) -> tuple[str, ...]:
        if self.how in LEFT_ONLY_HOWS:
            return left_columns
        taken = set(left_columns) | set(right_columns)
        renamed: list[str] = []
        for name in right_columns:
            if name in left_columns:
                new = name + RIGHT_SUFFIX
                if new in taken:
                    raise ValueError(
                        f"Join: the right column '{name}' would be renamed '{new}', "
                        "which the frame already has; rename one first"
                    )
                renamed.append(new)
            else:
                renamed.append(name)
        output = left_columns + tuple(renamed)
        require_unique(output, "Join")
        return output

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class Union:
    """The rows of several inputs with the same columns, one after another."""

    children: tuple[Plan, ...]
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_tuple(self.children, "children", "Union")
        if len(self.children) < 2:
            raise ValueError("Union needs at least two inputs")
        for child in self.children:
            _need_plan(child, "children", "Union")
        first = self.children[0].columns
        for i, child in enumerate(self.children):
            if child.columns != first:
                raise ValueError(
                    f"Union: input {i} has columns ({', '.join(child.columns)}), "
                    f"and the first input has ({', '.join(first)})"
                )
        _set_columns(self, first)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class WriteTarget:
    """Where a plan's rows are written, in which format and with which
    compression. `codec` None is the format's default: snappy for Parquet,
    uncompressed for CSV and JSONL."""

    path: str
    format: str
    codec: str | None = None

    def __post_init__(self) -> None:
        _need_name(self.path, "path", "WriteTarget")
        _need_op(self.format, WRITE_FORMATS, "WriteTarget format")
        if self.codec is not None:
            _need_op(self.codec, WRITE_CODECS, "WriteTarget codec")
            if self.codec == "snappy" and self.format != "parquet":
                raise ValueError(f"WriteTarget: no file sink writes {self.format} with snappy")


@dataclass(frozen=True, slots=True)
class Write:
    """The root of a plan that writes the child's rows to a target."""

    child: Plan
    target: WriteTarget
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "Write")
        if not isinstance(self.target, WriteTarget):
            raise TypeError(
                f"Write.target must be a WriteTarget, not {type(self.target).__name__}"
            )
        _set_columns(self, self.child.columns)

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


@dataclass(frozen=True, slots=True)
class MapBatches:
    """A `map_batches_frame` user function over the child's rows, called once
    per batch. Its output columns are the columns of the function's declared
    return type, and it reads the columns of the function's read set."""

    child: Plan
    udf: UdfSpec
    _columns: tuple[str, ...] = field(init=False, repr=False, compare=False)

    def __post_init__(self) -> None:
        _need_plan(self.child, "child", "MapBatches")
        if not isinstance(self.udf, UdfSpec):
            raise TypeError(
                f"MapBatches.udf must be a UdfSpec, not {type(self.udf).__name__}"
            )
        if self.udf.kind != "map_batches_frame":
            raise ValueError(
                f"MapBatches runs a map_batches_frame function, and {self.udf.name} "
                f"is a {self.udf.kind} function"
            )
        require_columns(self.udf.read_set, self.child.columns)
        _set_columns(self, tuple(name for name, _ in self.udf.return_type))

    @property
    def columns(self) -> tuple[str, ...]:
        return self._columns


Plan = (
    Scan
    | Filter
    | Project
    | Aggregate
    | Sort
    | Limit
    | TopN
    | Distinct
    | Join
    | Union
    | Write
    | MapBatches
    | Unnest
)

PLAN_NODES = (
    Scan,
    Filter,
    Project,
    Aggregate,
    Sort,
    Limit,
    TopN,
    Distinct,
    Join,
    Union,
    Write,
    MapBatches,
    Unnest,
)


def walk_plan(plan: Plan) -> Iterator[Plan]:
    """Yield the plan node, then its inputs in order, depth first."""
    if not isinstance(plan, PLAN_NODES):
        raise TypeError(f"not a plan node: {type(plan).__name__}")
    yield plan
    if isinstance(plan, Join):
        inputs: tuple[Plan, ...] = (plan.left, plan.right)
    elif isinstance(plan, Union):
        inputs = plan.children
    elif isinstance(plan, Scan):
        inputs = ()
    else:
        inputs = (plan.child,)
    for child in inputs:
        yield from walk_plan(child)
