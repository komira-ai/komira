"""Windows of komira.pl: `over`, `rank`, `cum_*`, `rolling_*`, `shift` and
`diff`, and the plan
a row-wise verb builds for the windows its expressions gather.

A window is a `WindowExpr` item of a `Project`, which the plan encoder writes
as a partition-by node (komira/_plan/_window.py). Its argument and its order
keys are columns, so an expression that is not a column of the frame is first
computed into one. A verb whose expressions hold windows builds:

    PROJECT  the verb's outputs, over
    PROJECT  the frame's columns, the argument columns and the windows, over
    PROJECT  the frame's columns and the argument columns (when there are any), over
    the frame's plan below its sort

and, on an ordered frame whose sort keys the outputs keep, the sort again on
top, as a window's output comes out in its partitions' order (rules section 7).

How each polars answer is built (rules sections 7 and 8):

- an aggregate is a window over the partition of `over(...)`, the whole frame
  without one (a broadcast), with no order and no frame: the aggregate of the
  whole partition, whatever `order_by` says, as in polars;
- `rank` orders by its own value, nulls last, and a null ranks null.
  `"min"` is RANK, `"dense"` DENSE_RANK; `"max"` is the count of the
  partition's values that are not null, less the RANK in the other direction,
  plus 1; `"average"` is the mean of the `"min"` and `"max"` ranks.
  `"ordinal"` and `"random"` break ties by row order or at random and are
  refused;
- `cum_sum`, `cum_min` and `cum_max` are the window over the rows from the
  partition's first to the current one, in the order of `over(order_by=...)`
  or the frame's sort, and null where the value is null; `cum_count` counts
  the values that are not null, and is never null. `reverse=True` reads the
  rows in the other order;
- `rolling_*` is the window over the `window_size` rows up to the current
  one, null where fewer than `min_samples` of them (`window_size` when not
  given) are not null;
- `shift(n)` is LAG by `n` rows in that order, or LEAD by `-n` when `n` is
  negative, null where there is no such row; `diff(n)` is the value less
  its `shift(n)` (`null_behavior="ignore"`, polars' default). LAG and LEAD
  read int64, float64 and string columns, so an int8 to int32 or a float32
  column is shifted through int64 or float64 and cast back.

The types are polars' (komira/pl/_types.py): a rank is an Int64 (polars:
UInt32), an `"average"` rank a Float64, a cumulative or rolling sum is typed as
`sum`, a rolling mean is a Float64 (Float32 over a Float32), and a minimum or
maximum keeps the column's type, and so do `shift` and `diff`. polars' diff
of an unsigned column is signed, and is refused here.
"""

from __future__ import annotations

from komira._errors import UnsupportedOperation
from komira._ops import Arith, Cast, ColRef, Compare, Frame, Lit, Project, SortKey, Unary, When

from ._scope import WINDOW_ARGS

__all__ = ["carried", "cumulative", "diff", "over", "rank", "rolling", "shift", "windowed"]

_RUNNING = Frame("rows", "unbounded_preceding", "current_row")

# polars' type of a rolling sum, minimum or maximum, by the column's type:
# (the type the window reads, polars' type).
_ROLLING = {
    "int32": ("int64", "int32"),
    "int64": ("int64", "int64"),
    "float32": ("float64", "float32"),
    "float64": ("float64", "float64"),
}


def _expr():
    from . import _expr

    return _expr


def _null_where_null(value, arg, scope, what):
    """`value`, null where `arg` is null."""
    return _expr()._case(((Unary("is_null", arg), Lit(None)),), value, scope, what)


def _flags(verb: str, what: str, value) -> bool:
    if not isinstance(value, bool):
        raise TypeError(f"{verb}: {what} must be a bool, not {type(value).__name__}")
    return value


def _column_name(item, scope, verb: str, what: str) -> str:
    """The name of the column `item` (a name or `col(name)`) names."""
    E = _expr()
    if isinstance(item, str):
        item = E.col(item)
    if not isinstance(item, E.Expr):
        raise TypeError(f"{verb}: {what} must be a column name or komira.pl.col(...), not {type(item).__name__}")
    node = None if item._has_agg else item._lower(scope.row())
    if not isinstance(node, ColRef):
        raise UnsupportedOperation(
            f"{verb}: {what} '{item._name}' is an expression, which is not supported; add it "
            "with with_columns(...) and name its column"
        )
    return node.name


def _flat(values: tuple) -> list:
    out = []
    for item in values:
        if isinstance(item, (list, tuple)):
            out.extend(item)
        elif item is not None:
            out.append(item)
    return out


def over(inner, partition_by, more, order_by, descending, nulls_last, mapping_strategy):
    """`inner.over(partition_by, *more, order_by=..., ...)`."""
    E = _expr()
    if mapping_strategy != "group_to_rows":
        raise UnsupportedOperation(
            f"over: mapping_strategy={mapping_strategy!r} changes the number of rows or gives a "
            "list; only mapping_strategy='group_to_rows' is supported"
        )
    down = _flags("over", "descending", descending)
    last = _flags("over", "nulls_last", nulls_last)
    keys = _flat((partition_by,) + tuple(more))
    ordering = _flat((order_by,))
    if not keys and not ordering:
        raise ValueError("over needs a partition key or an order_by")

    def lower(scope):
        names = tuple(_column_name(k, scope, "over", "the partition key") for k in keys)
        if len(set(names)) != len(names):
            raise ValueError("over: a partition key is named more than once")
        order = None
        if ordering:
            order = tuple(
                SortKey(_column_name(k, scope, "over", "the order key"), down, not last) for k in ordering
            )
        return inner._lower(scope.partitioned(names, order))

    return E.Expr(lower, inner._name, False)


_RANK_METHODS = ("average", "min", "max", "dense", "ordinal", "random")


def rank(inner, method, descending, seed):
    """`inner.rank(method, descending=..., seed=...)`."""
    E = _expr()
    if method not in _RANK_METHODS:
        raise ValueError(f"rank: method must be one of {', '.join(map(repr, _RANK_METHODS))}, not {method!r}")
    if method in ("ordinal", "random"):
        how = "by row order" if method == "ordinal" else "at random"
        raise UnsupportedOperation(
            f"rank: method={method!r} breaks ties {how}, and a plan has no row order; use "
            "method='min', 'max', 'dense' or 'average'"
        )
    if seed is not None:
        raise UnsupportedOperation("rank: seed= is for method='random', which is not supported")
    down = _flags("rank", "descending", descending)
    inner._no_agg("rank")
    what = f"rank(method={method!r})"

    def lower(scope):
        arg = inner._lower(scope)
        key = scope.sort_key(arg, what, down).column

        def ranked(func, d):
            return scope.window(func, None, what, order=(SortKey(key, d, False),))

        if method == "min":
            value = ranked("rank", down)
        elif method == "dense":
            value = ranked("dense_rank", down)
        else:
            count = scope.window("count", ColRef(key), what)
            # The rank of the last of the tied values: the values not after
            # them, the count less those after them.
            top = Arith("add", Arith("sub", count, ranked("rank", not down)), Lit(1))
            if method == "max":
                value = top
            else:
                both = Arith("add", ranked("rank", down), top)
                value = Arith("div", Cast(both, "float64"), Lit(2.0))
        return _null_where_null(value, arg, scope, "rank")

    return E.Expr(lower, inner._name, False)


def _flip(order: tuple[SortKey, ...]) -> tuple[SortKey, ...]:
    return tuple(SortKey(k.column, not k.descending, not k.nulls_first) for k in order)


def cumulative(inner, func: str, reverse):
    """`inner.cum_<func>(reverse=...)`, for sum, count, min and max."""
    E = _expr()
    verb = f"cum_{func}"
    back = _flags(verb, "reverse", reverse)
    inner._no_agg(verb)
    what = f"{verb}()"

    def lower(scope):
        arg = inner._lower(scope)
        order = scope.order(what)
        if back:
            order = _flip(order)
        found = scope.arrow_type(arg)

        def running(func_, value):
            return scope.window(func_, value, what, order=order, frame=_RUNNING)

        if func == "count":
            return running("count", arg)
        if func == "sum":
            if found not in E._SUMS:
                raise UnsupportedOperation(f"{verb} of a column of type {found} is not supported yet")
            widen, final = E._SUMS[found]
            if found == "bool":
                summed = When(((E._is_true(arg), Lit(1)),), Lit(0))
            else:
                summed = arg if widen is None else Cast(arg, widen)
            value = running("sum", summed)
        else:
            wide = E._wide(arg, found)
            if scope.arrow_type(wide) not in WINDOW_ARGS:
                raise UnsupportedOperation(
                    f"{verb} of a column of type {found} is not supported; the window reads int8 "
                    "to int64 and float64"
                )
            value = running(func, wide)
            final = found
        out = _null_where_null(value, arg, scope, verb)
        return out if scope.arrow_type(out) == final else Cast(out, final)

    return E.Expr(lower, inner._name, False)


def _count_arg(verb: str, what: str, value) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{verb}: {what} must be an int, not {type(value).__name__}")
    if value < 1:
        raise ValueError(f"{verb}: {what} must be at least 1, not {value}")
    return value


def rolling(inner, func: str, window_size, weights, min_samples, center):
    """`inner.rolling_<func>(window_size, ...)`, for sum, mean, min and max."""
    E = _expr()
    verb = f"rolling_{func}"
    size = _count_arg(verb, "window_size", window_size)
    least = size if min_samples is None else _count_arg(verb, "min_samples", min_samples)
    if least > size:
        raise ValueError(f"{verb}: min_samples ({least}) must be at most window_size ({size})")
    if weights is not None:
        raise UnsupportedOperation(f"{verb}: weights= is not supported; a window frame has no weights")
    if _flags(verb, "center", center):
        raise UnsupportedOperation(
            f"{verb}: center=True is not supported; the window is the rows up to the current one"
        )
    inner._no_agg(verb)
    what = f"{verb}({size})"
    if size == 1:
        frame = Frame("rows", "current_row", "current_row")
    else:
        frame = Frame("rows", "preceding", "current_row", size - 1)

    def lower(scope):
        arg = inner._lower(scope)
        order = scope.order(what)
        found = scope.arrow_type(arg)
        if found not in _ROLLING:
            raise UnsupportedOperation(
                f"{verb} of a column of type {found} is not supported yet; cast it to int64 or float64"
            )
        read, final = _ROLLING[found]
        wide = arg if read == found else Cast(arg, read)
        if func == "mean":
            value = scope.window("avg", wide, what, order=order, frame=frame)
            final = "float32" if found == "float32" else "float64"
        else:
            value = scope.window(func, wide, what, order=order, frame=frame)
        values = scope.window("count", arg, what, order=order, frame=frame)
        out = E._case(((Compare("lt", values, Lit(least)), Lit(None)),), value, scope, verb)
        return out if scope.arrow_type(out) == final else Cast(out, final)

    return E.Expr(lower, inner._name, False)


# The type LAG and LEAD read a column of each type through, None for the
# column's own: polars' shift keeps the type, and so does its diff.
_SHIFTS = {
    "int8": "int64",
    "int16": "int64",
    "int32": "int64",
    "int64": None,
    "float32": "float64",
    "float64": None,
    "string": None,
}
_DIFFS = frozenset({"int8", "int16", "int32", "int64", "float32", "float64"})


def _rows_arg(verb: str, value) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{verb}: n must be an int, the number of rows, not {type(value).__name__}")
    return value


def _previous(scope, arg, n: int, verb: str, what: str, types):
    """`arg` `n` rows before each row in the scope's order (after it when
    `n` is negative), null where there is no such row, read through the
    wider type of `_SHIFTS`; and that read type of `arg` itself."""
    order = scope.order(what)
    found = scope.arrow_type(arg)
    if found not in types:
        to = "int64, float64 or string" if "string" in types else "int64 or float64"
        raise UnsupportedOperation(f"{verb} of a column of type {found} is not supported yet; cast it to {to}")
    read = _SHIFTS[found]
    wide = arg if read is None else Cast(arg, read)
    if n == 0:
        return wide, wide
    func = "lag" if n > 0 else "lead"
    return scope.window(func, wide, what, order=order, offset=abs(n)), wide


def _narrowed(scope, node, found: str):
    return node if scope.arrow_type(node) == found else Cast(node, found)


def shift(inner, n, fill_value):
    """`inner.shift(n, fill_value=...)`."""
    E = _expr()
    rows = _rows_arg("shift", n)
    if fill_value is not None:
        raise UnsupportedOperation("shift: fill_value= is not supported; a row with no row to read is null")
    inner._no_agg("shift")
    what = f"shift({rows})"

    def lower(scope):
        arg = inner._lower(scope)
        before, _ = _previous(scope, arg, rows, "shift", what, _SHIFTS)
        return _narrowed(scope, before, scope.arrow_type(arg))

    return E.Expr(lower, inner._name, False)


def diff(inner, n, null_behavior):
    """`inner.diff(n, null_behavior)`."""
    E = _expr()
    rows = _rows_arg("diff", n)
    if null_behavior == "drop":
        raise UnsupportedOperation(
            "diff: null_behavior='drop' leaves out the first rows, which changes the number of rows; "
            "only null_behavior='ignore' is supported"
        )
    if null_behavior != "ignore":
        raise ValueError(f"diff: null_behavior must be 'ignore' or 'drop', not {null_behavior!r}")
    inner._no_agg("diff")
    what = f"diff({rows})"

    def lower(scope):
        arg = inner._lower(scope)
        before, wide = _previous(scope, arg, rows, "diff", what, _DIFFS)
        return _narrowed(scope, Arith("sub", wide, before), scope.arrow_type(arg))

    return E.Expr(lower, inner._name, False)


# ---- the plan ------------------------------------------------------------------


def carried(order, items) -> tuple[SortKey, ...] | None:
    """The sort keys `order` as the names of `items` ((name, node) pairs)
    that keep their columns unchanged, or None when one does not."""
    if order is None:
        return None
    out = []
    for key in order:
        name = next((n for n, node in items if node == ColRef(key.column)), None)
        if name is None:
            return None
        out.append(SortKey(name, key.descending, key.nulls_first))
    return tuple(out)


def windowed(base, windows):
    """`base` with the argument columns, then the windows, of `windows`
    appended (rules above)."""
    plan = base
    for added in (windows.pre, windows.wins):
        if added:
            plan = Project(plan, tuple((c, ColRef(c)) for c in plan.columns) + tuple(added))
    return plan
