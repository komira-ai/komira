"""What "missing" means in the pandas-shaped frame (docs/design/dataframe_surface.md,
ruling 6): a value is missing when it is NULL, or NaN in a float column.

The plan has no `isnan` node, so a float column's NaN test is built the way
the SQL binder builds `isnan`, from comparisons with infinity, and is right
whether the engine orders NaN as IEEE does (NaN equals and orders against
nothing) or as DuckDB does (NaN is the greatest value):

    x is not NaN  =  (x > -inf AND x < inf) OR x = inf OR x = -inf

A float32 or float16 column is compared through a cast to float64. Only
predicate contexts use it: a filter and a CASE condition.
"""

from __future__ import annotations

from . import _ops

__all__ = ["FLOAT_TYPES", "not_nan", "present"]

FLOAT_TYPES = frozenset({"float16", "float32", "float64"})


def not_nan(node: _ops.Node, dtype: str) -> _ops.Node:
    """The predicate that `node`, a float column of type `dtype`, is not NaN;
    it is true for an infinity and unknown for NULL."""
    x = node if dtype == "float64" else _ops.Cast(node, "float64")
    inf = _ops.Lit(float("inf"))
    minus_inf = _ops.Lit(float("-inf"))
    finite = _ops.BoolOp("and", _ops.Compare("gt", x, minus_inf), _ops.Compare("lt", x, inf))
    return _ops.or_all((finite, _ops.Compare("eq", x, inf), _ops.Compare("eq", x, minus_inf)))


def present(node: _ops.Node, dtype: str) -> _ops.Node:
    """The predicate that `node`, of type `dtype`, holds a value: not NULL,
    and for a float type not NaN either."""
    not_null = _ops.Unary("is_not_null", node)
    if dtype not in FLOAT_TYPES:
        return not_null
    return _ops.BoolOp("and", not_null, not_nan(node, dtype))
