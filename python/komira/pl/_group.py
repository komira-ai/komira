"""`LazyGroupBy`, what `LazyFrame.group_by` returns, and the frame its
aggregation verbs build.

`group_by(keys).agg(exprs)` is one AGGREGATE of the frame by the key columns,
its outputs the keys, then each expression under polars' name: an expression
that is only an aggregate is that aggregate's item, and any other is computed
over the aggregates in a PROJECT above it. A null key is a group of its own,
as in polars. The groups come out in no particular order (rules section 8,
ruling 2): the frame is unordered, and `maintain_order=True` is refused.

Inside `agg`, a column is read only inside an aggregate: a bare column is a
list of the group's values in polars, which is refused, and so is a window.

`len()`, `sum()`, `mean()`, `median()`, `min()`, `max()` and `n_unique()`
reduce every column that is not a key, each under its own name. `sum`,
`mean` and `median` need every such column to be numeric or boolean (ruling
4), and are refused naming the first that is not.
"""

from __future__ import annotations

from komira._errors import UnsupportedOperation
from komira._ops import Aggregate, ColRef, Project, Sort

from . import _names
from ._expr import Expr, col
from ._expr import len as _len_expr
from ._scope import Scope

__all__ = ["LazyGroupBy", "group_keys"]

_NUMERIC = frozenset(
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


def group_keys(frame, verb: str, by: tuple) -> tuple[str, ...]:
    """The column names `by` names: names and `col(name)`, in lists or not.
    An expression that is not a column is refused, as is a name given twice."""
    flat = []
    for item in by:
        flat.extend(item if isinstance(item, (list, tuple)) else [item])
    if not flat:
        raise ValueError(f"{verb} needs at least one column")
    scope = frame._scope(verb)
    out = []
    for item in flat:
        if isinstance(item, str):
            item = col(item)
        if not isinstance(item, Expr):
            raise TypeError(f"{verb} takes column names and komira.pl.col(...), not {type(item).__name__}")
        node = None if item._has_agg else item._lower(scope.row())
        if not isinstance(node, ColRef):
            raise UnsupportedOperation(
                f"{verb}: the key '{item._name}' is an expression, which is not supported; add it "
                "with with_columns(...) and name its column"
            )
        if item._name != node.name:
            raise UnsupportedOperation(
                f"{verb}: the key '{node.name}' is renamed '{item._name}' with alias(), which is "
                "not supported; rename the column with rename(...) first"
            )
        if node.name in out:
            raise ValueError(f"{verb}: the column '{node.name}' is named more than once")
        out.append(node.name)
    return tuple(out)


class LazyGroupBy:
    """The groups of a `LazyFrame` by its key columns, before they are
    aggregated with `agg(...)` or one of the reductions."""

    __slots__ = ("_frame", "_keys")

    def __init__(self, frame, keys: tuple[str, ...]) -> None:
        object.__setattr__(self, "_frame", frame)
        object.__setattr__(self, "_keys", keys)

    def __getattr__(self, name: str):
        raise _names.missing("LazyGroupBy", name)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(
            f"cannot set the attribute '{name}' of a LazyGroupBy; aggregate it with agg(...)"
        )

    def __repr__(self) -> str:
        return f"<komira.pl.LazyGroupBy by [{', '.join(self._keys)}]>"

    def agg(self, *aggs: object, **named_aggs: Expr):
        """A frame of one row per group: the key columns, then each expression
        under polars' name (`named_aggs` under their keyword)."""
        frame, keys = self._frame, self._keys
        items = frame._exprs("agg", aggs, named_aggs)
        names = [e._name for e in items]
        for name in names:
            if name in keys or names.count(name) > 1:
                raise ValueError(
                    f"agg: the output name '{name}' is produced more than once (a key or another "
                    "expression); give it a name of its own with .alias(...)"
                )
        scope = Scope(frame._wire_fields(), "agg", grouped=True)
        scope.reserve(keys + tuple(names))
        from ._frame import _column_literal

        nodes = [_column_literal(e._lower(scope)) for e in items]
        aggregates = scope.aggregates
        child = frame._plan.child if isinstance(frame._plan, Sort) else frame._plan
        if nodes == [ColRef(slot) for slot, _ in aggregates]:
            plan = Aggregate(child, keys, tuple((n, agg) for n, (_, agg) in zip(names, aggregates)))
        else:
            plan = Project(
                Aggregate(child, keys, aggregates),
                tuple((k, ColRef(k)) for k in keys) + tuple(zip(names, nodes)),
            )
        return frame._with(plan, None)

    def len(self, name: str | None = None):
        """The number of rows of each group, an Int64 (polars: UInt32), named
        `len` or `name`."""
        return self.agg(_len_expr().alias("len" if name is None else name))

    def _each(self, verb: str, numeric: bool):
        frame = self._frame
        columns = [c for c in frame.columns if c not in self._keys]
        if numeric:
            from komira._plan._wire import arrow_name

            for f in frame._wire_fields():
                found = arrow_name(f.arrow_type_id)
                if f.name in columns and found not in _NUMERIC:
                    raise UnsupportedOperation(
                        f"group_by().{verb}(): the column '{f.name}' is of type {found}, and "
                        f"{verb}() needs numbers or booleans; select the columns to reduce first"
                    )
        return self.agg(*[getattr(col(c), verb)() for c in columns])

    def sum(self):
        """The sum of every column that is not a key, 0 over no values."""
        return self._each("sum", True)

    def mean(self):
        """The mean of every column that is not a key."""
        return self._each("mean", True)

    def median(self):
        """The median of every column that is not a key."""
        return self._each("median", True)

    def min(self):
        """The smallest value of every column that is not a key."""
        return self._each("min", False)

    def max(self):
        """The largest value of every column that is not a key."""
        return self._each("max", False)

    def n_unique(self):
        """The number of distinct values of every column that is not a key."""
        return self._each("n_unique", False)
