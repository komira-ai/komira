"""What an expression of komira.pl is lowered against: the columns and types of
one frame, and what the verb that lowers it gathers: the aggregates of a
`select` of aggregates or of `group_by().agg()`, or the windows of a row-wise
verb.

A `komira.pl.Expr` names its columns but no frame, as a polars expression
does. A verb lowers it against the frame it is given: a `Scope` holds that
frame's output fields (`WireField`, as the plan encoder derives them), so a
column the frame lacks is refused at the verb, and the few lowerings that
depend on a type (floor division, the boolean column a filter tests, the type
polars gives an aggregate) read the type here.

A scope is of one of four kinds:

- a row scope, the scope of an aggregate's argument and of a sort key: a
  column is read as it is, and an aggregate or a window is refused;
- an aggregate scope (`select` of aggregates): each `Agg` becomes an item of
  the `Aggregate` node under a name of its own, and the expression above it
  reads that name. A column outside an aggregate, or a window, makes the
  select a broadcast: `Broadcast` is raised, and `select` lowers its items
  again in a window scope;
- a grouped scope (`group_by().agg()`): as an aggregate scope, but a column
  outside an aggregate or a window is refused, as polars would give a list;
- a window scope (`select` with a row-wise output, `with_columns`, `filter`):
  an aggregate is a window over the partition of the enclosing `over()`, the
  whole frame when there is none (a broadcast), and `rank`, `cum_*` and
  `rolling_*` are windows too. Each window is gathered into a `Windows`,
  which the verb builds into the plan (komira/pl/_window.py).
"""

from __future__ import annotations

from komira._errors import UnsupportedOperation
from komira._ops import Agg, ColRef, Compare, Lit, Node, SortKey, WindowExpr, column_refs, is_predicate, unknown_column

__all__ = ["Broadcast", "Scope", "WINDOW_ARGS", "Windows"]

# The window function of each aggregate a window computes.
_WINDOW_OF = {"sum": "sum", "mean": "avg", "min": "min", "max": "max", "count": "count"}

# The argument types the engine's SUM, AVG, MIN and MAX windows read.
WINDOW_ARGS = frozenset({"int8", "int16", "int32", "int64", "float64"})

# polars' name of each aggregate no window computes.
_POLARS_NAME = {
    "count_distinct": "n_unique",
    "median": "median",
    "stddev_samp": "std",
    "var_samp": "var",
}


class Broadcast(Exception):
    """Raised in an aggregate scope when an expression reads a column outside
    an aggregate, or a window: the select is a broadcast, not one row."""


class Windows:
    """The columns the expressions of one row-wise verb need beside the
    frame's: an argument computed into a column of its own, and a window.

    `pre` holds the (name, node) argument columns, computed over the frame;
    `wins` the (name, WindowExpr) windows, computed over the frame and `pre`.
    `fields` are the frame's fields, then theirs, so that an expression over
    any of them is typed. `order` is the frame's sort keys, or None."""

    __slots__ = ("fields", "order", "pre", "wins", "_taken", "_frame", "_verb")

    def __init__(self, fields, order, verb: str = "") -> None:
        self._verb = verb
        self.fields = list(fields)
        self._frame = len(self.fields)
        self.order = order
        self.pre: list[tuple[str, Node]] = []
        self.wins: list[tuple[str, WindowExpr]] = []
        self._taken = {f.name for f in self.fields}

    def _slot(self, base: str) -> str:
        name = f"{base}_{len(self.pre) + len(self.wins)}"
        while name in self._taken:
            name = "_" + name
        self._taken.add(name)
        return name

    def reserve(self, names) -> None:
        """Keeps the names of gathered columns apart from `names` too."""
        self._taken.update(names)

    def column(self, node: Node) -> str:
        """The name of a column that holds `node`: a column of the frame's
        own, or an argument column computed for it. A node that reads a
        window's column is refused: a window of a window is not supported."""
        windowed = {name for name, _ in self.wins}
        if any(ref.name in windowed for ref in column_refs(node)):
            raise UnsupportedOperation(
                f"{self._verb}: a window over the result of another window is not supported; "
                "compute the inner one with with_columns(...) first"
            )
        if isinstance(node, ColRef) and node.side is None:
            return node.name
        for name, done in self.pre:
            if done == node:
                return name
        from komira._plan import expr_field

        name = self._slot("__komira_arg")
        f = expr_field(node, self.fields[: self._frame + len(self.pre)])
        f.name = name
        self.fields.insert(self._frame + len(self.pre), f)
        self.pre.append((name, node))
        return name

    def window(self, win: WindowExpr) -> ColRef:
        """A reference to the column of the window `win`; one column for
        windows that are equal."""
        for name, done in self.wins:
            if done == win:
                return ColRef(name)
        from komira._plan._window import window_field

        name = self._slot("__komira_win")
        self.fields.append(window_field(name, win, self.fields[: self._frame + len(self.pre)]))
        self.wins.append((name, win))
        return ColRef(name)


class Scope:
    """The columns an expression may name, and what it gathered."""

    __slots__ = ("_fields", "_columns", "_aggregates", "_taken", "_verb", "_grouped", "_windows", "_over")

    def __init__(
        self,
        fields,
        verb: str,
        *,
        aggregates: bool = False,
        grouped: bool = False,
        windows: Windows | None = None,
        over: tuple | None = None,
    ) -> None:
        self._fields = tuple(fields)
        self._columns = tuple(f.name for f in self._fields)
        self._verb = verb
        # (name, Agg) pairs, or None when this scope gathers no aggregates.
        self._aggregates: list[tuple[str, Agg]] | None = [] if (aggregates or grouped) else None
        self._grouped = grouped
        self._taken = set(self._columns)
        self._windows = windows
        # (partition keys, order keys or None) of the enclosing over(), or None.
        self._over = over

    @property
    def aggregates(self) -> tuple[tuple[str, Agg], ...]:
        """The aggregates gathered so far, each under its own name."""
        return tuple(self._aggregates or ())

    def reserve(self, names) -> None:
        """Keeps the names an aggregate or a window is given apart from
        `names` too."""
        self._taken.update(names)
        if self._windows is not None:
            self._windows.reserve(names)

    def row(self) -> Scope:
        """A scope over the same columns that gathers nothing: the scope of an
        aggregate's own argument."""
        return Scope(self._fields, self._verb)

    def column(self, name: str) -> ColRef:
        """A reference to the column `name`; `KeyError` when the frame has
        none. In a scope that gathers aggregates a column is read only inside
        an aggregate: elsewhere it is a list per group (refused) or a
        broadcast (`Broadcast`)."""
        if name not in self._columns:
            raise unknown_column(name, self._columns)
        if self._grouped:
            raise UnsupportedOperation(
                f"{self._verb}: the column '{name}' is not aggregated, and polars would give "
                "a list of each group's values, which is not supported; aggregate it, for "
                f"example with col({name!r}).max()"
            )
        if self._aggregates is not None:
            raise Broadcast()
        return ColRef(name)

    def arrow_type(self, node: Node) -> str:
        """The name of the Arrow type the engine derives for `node`: over the
        frame's columns and the columns gathered for windows, or, in a scope
        that gathers aggregates, over the aggregates gathered so far, which
        are all such a node reads."""
        from komira._plan import expr_field
        from komira._plan._agg import agg_field
        from komira._plan._wire import arrow_name

        fields = self._fields
        if self._aggregates is not None:
            fields = tuple(agg_field(slot, agg, self._fields) for slot, agg in self._aggregates)
        elif self._windows is not None:
            fields = tuple(self._windows.fields)
        return arrow_name(expr_field(node, fields).arrow_type_id)

    def predicate(self, node: Node, what: str) -> Node:
        """`node` as a predicate: a boolean column or value is compared with
        true, which keeps the rows where it is true, as polars does. Any other
        type is a `TypeError` naming `what`."""
        if is_predicate(node):
            return node
        found = self.arrow_type(node)
        if found == "bool":
            return Compare("eq", node, Lit(True))
        raise TypeError(f"{what} needs a boolean expression, and this one is of type {found}")

    def aggregate(self, agg: Agg, name: str) -> Node:
        """A reference to the aggregate `agg` of an expression named `name`:
        gathered under a name of its own in a scope that gathers aggregates,
        a window over the partition of the enclosing `over()` (the whole frame
        when there is none) in a window scope, and refused in a row scope."""
        if self._aggregates is not None:
            slot = f"__komira_agg_{len(self._aggregates)}"
            while slot in self._taken:
                slot = "_" + slot
            self._taken.add(slot)
            self._aggregates.append((slot, agg))
            return ColRef(slot)
        if self._windows is None:
            raise UnsupportedOperation(
                f"{self._verb}: the aggregate of '{name}' is inside another aggregate or a "
                "sort key, which is not supported"
            )
        func = _WINDOW_OF.get(agg.func)
        if func is None:
            raise UnsupportedOperation(
                f"{self._verb}: {_POLARS_NAME.get(agg.func, agg.func)}() of '{name}' over rows "
                "(a window) is not supported: the plan has no window function for it; "
                "aggregate it in group_by().agg(...) and join the result"
            )
        if agg.args and func != "count":
            found = self.arrow_type(agg.args[0])
            if found not in WINDOW_ARGS:
                raise UnsupportedOperation(
                    f"{self._verb}: {agg.func}() of '{name}' over rows "
                    f"(a window) of type {found} is not supported; the window reads int8 to int64 "
                    "and float64"
                )
        arg = self._windows.column(agg.args[0]) if agg.args else self._windows.column(Lit(1))
        partition = self._over[0] if self._over is not None else ()
        return self._windows.window(WindowExpr(func, arg, 0, partition))

    # ---- windows ------------------------------------------------------------------

    def _need_windows(self, what: str) -> Windows:
        if self._windows is not None:
            return self._windows
        if self._grouped:
            raise UnsupportedOperation(
                f"{self._verb}: {what} is a window, which is not supported inside "
                "group_by().agg(); compute it with with_columns(...) first"
            )
        if self._aggregates is not None:
            raise Broadcast()
        raise UnsupportedOperation(
            f"{self._verb}: {what} is a window inside an aggregate or a sort key, which is not supported"
        )

    def partitioned(self, keys: tuple[str, ...], order: tuple[SortKey, ...] | None) -> Scope:
        """The scope of the expression `over(keys, order_by=...)` wraps: its
        aggregates and windows are computed per partition of `keys`."""
        windows = self._need_windows("over()")
        if self._over is not None:
            raise UnsupportedOperation(f"{self._verb}: over() inside over() is not supported")
        for key in keys:
            self.column(key)
        if order is not None:
            for key in order:
                self.column(key.column)
        return Scope(self._fields, self._verb, windows=windows, over=(keys, order))

    def window(self, func: str, arg: Node | None, what: str, *, order=(), frame=None, offset: int = 0) -> ColRef:
        """A reference to the window `func` of `arg` (a node, or None for a
        ranking) over the partition of the enclosing `over()`, ordered by
        `order` and reading `frame`; `offset` is the row distance of a lag or
        lead."""
        windows = self._need_windows(what)
        column = None if arg is None else windows.column(arg)
        partition = self._over[0] if self._over is not None else ()
        return windows.window(WindowExpr(func, column, offset, partition, tuple(order), frame))

    def sort_key(self, node: Node, what: str, descending: bool) -> SortKey:
        """`node` as a window's order key, its nulls last: a column of its
        own, computed into one when it is not a column."""
        windows = self._need_windows(what)
        return SortKey(windows.column(node), descending, False)

    def order(self, what: str) -> tuple[SortKey, ...]:
        """The order a running or rolling window reads its rows in: the
        `order_by` of the enclosing `over()`, else the frame's sort (rules
        section 7)."""
        windows = self._need_windows(what)
        if self._over is not None and self._over[1] is not None:
            return self._over[1]
        if windows.order is None:
            raise UnsupportedOperation(
                f"{self._verb}: {what} reads the rows in order, and a plan promises no row "
                "order unless it is sorted; sort(...) the frame first, or give the order "
                "with .over(..., order_by=...)"
            )
        return windows.order
