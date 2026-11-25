"""What an expression of komira.pl is lowered against: the columns and types of
one frame, and, inside `select`, the aggregates it gathers.

A `komira.pl.Expr` names its columns but no frame, as a polars expression
does. A verb lowers it against the frame it is given: a `Scope` holds that
frame's output fields (`WireField`, as the plan encoder derives them), so a
column the frame lacks is refused at the verb, and the few lowerings that
depend on a type (floor division, the boolean column a filter tests, the type
polars gives an aggregate) read the type here.

An aggregate is lowered only in a scope that gathers aggregates (`select`
with no row-wise output): each `Agg` becomes an item of the `Aggregate` node
under a name of its own, and the expression above it reads that name.
"""

from __future__ import annotations

from komira._errors import UnsupportedOperation
from komira._ops import Agg, ColRef, Compare, Lit, Node, is_predicate, unknown_column

__all__ = ["Scope"]


class Scope:
    """The columns an expression may name, and the aggregates it gathered."""

    __slots__ = ("_fields", "_columns", "_aggregates", "_taken", "_verb")

    def __init__(self, fields, verb: str, *, aggregates: bool = False) -> None:
        self._fields = tuple(fields)
        self._columns = tuple(f.name for f in self._fields)
        self._verb = verb
        # (name, Agg) pairs, or None when this scope refuses aggregates.
        self._aggregates: list[tuple[str, Agg]] | None = [] if aggregates else None
        self._taken = set(self._columns)

    @property
    def verb(self) -> str:
        """The verb the expression is lowered for, as messages name it."""
        return self._verb

    @property
    def fields(self) -> tuple:
        """The frame's output fields."""
        return self._fields

    @property
    def aggregates(self) -> tuple[tuple[str, Agg], ...]:
        """The aggregates gathered so far, each under its own name."""
        return tuple(self._aggregates or ())

    def reserve(self, names) -> None:
        """Keeps the names an aggregate is given apart from `names` too."""
        self._taken.update(names)

    def row(self) -> Scope:
        """A scope over the same columns that refuses aggregates: the scope of
        an aggregate's own argument."""
        return Scope(self._fields, self._verb)

    def column(self, name: str) -> ColRef:
        """A reference to the column `name`; `KeyError` when the frame has
        none. In a scope that gathers aggregates a column is read only inside
        an aggregate, and a bare one is refused: it would be a broadcast."""
        if name not in self._columns:
            raise unknown_column(name, self._columns)
        if self._aggregates is not None:
            raise UnsupportedOperation(
                f"{self._verb}: the column '{name}' is used beside an aggregate; an "
                "aggregate broadcast over rows (a window) is not supported yet, so "
                "aggregate every column of this select()"
            )
        return ColRef(name)

    def arrow_type(self, node: Node) -> str:
        """The name of the Arrow type the engine derives for `node`: over the
        frame's columns, or, in a scope that gathers aggregates, over the
        aggregates gathered so far, which are all such a node reads."""
        from komira._plan import expr_field
        from komira._plan._agg import agg_field
        from komira._plan._wire import arrow_name

        fields = self._fields
        if self._aggregates is not None:
            fields = tuple(agg_field(slot, agg, self._fields) for slot, agg in self._aggregates)
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
        """A reference to the aggregate `agg`, gathered under a name made from
        `name`; `UnsupportedOperation` in a scope that gathers none."""
        if self._aggregates is None:
            raise UnsupportedOperation(
                f"{self._verb}: the aggregate of '{name}' is used beside row-wise values; "
                "an aggregate broadcast over rows (a window) is not supported yet, so "
                "aggregate in a select() of aggregates only"
            )
        slot = f"__komira_agg_{len(self._aggregates)}"
        while slot in self._taken:
            slot = "_" + slot
        self._taken.add(slot)
        self._aggregates.append((slot, agg))
        return ColRef(slot)
