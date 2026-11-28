"""`expr.dt`, the temporal functions of an `Expr`: `truncate(every)` to the
day, the week or the month, which `LazyFrame.group_by_dynamic` groups by.

`truncate` is the engine's `date_trunc` (an EXTRACT of the unit
`trunc_day`, `trunc_week` or `trunc_month`), so its value is DuckDB's: the
day, the Monday that starts the ISO week, or the first day of the month, as
polars' `Expr.dt.truncate("1d" | "1w" | "1mo")` gives them. The type is the
input's: a Date stays a Date and a Datetime keeps its unit (DuckDB widens a
date to a timestamp; the day it names is the same). A null stays null.

Only the one-unit spellings are built: a multiple (`"2d"`) or another unit
(`"1h"`, `"1q"`) is refused naming it, as is a duration that is not a str, an
input that is not a Date or a Datetime, and a Datetime with a time zone
(polars truncates it by the local day, which the plan does not compute).
"""

from __future__ import annotations

import re

from komira._errors import UnsupportedOperation
from komira._ops import Extract

from . import _names

__all__ = ["ExprDateTimeNameSpace", "truncate_unit"]

# every -> the engine's unit.
_EVERY = {"1d": "trunc_day", "1w": "trunc_week", "1mo": "trunc_month"}
_LISTED = "'1d', '1w' or '1mo'"


def truncate_unit(verb: str, every: object) -> str:
    """The engine's unit of the duration `every`, or the refusal naming it."""
    if not isinstance(every, str):
        raise TypeError(f"{verb}: every must be a duration string such as '1w', not {type(every).__name__}")
    unit = _EVERY.get(every)
    if unit is not None:
        return unit
    multiple = re.fullmatch(r"(\d+)(d|w|mo)", every)
    if multiple is not None:
        raise UnsupportedOperation(
            f"{verb}: every={every!r} is a multiple of a unit, and the plan cuts to one whole day, "
            f"week or month: use {_LISTED}"
        )
    raise UnsupportedOperation(f"{verb}: every={every!r} is not a duration this release truncates to: use {_LISTED}")


def truncated(verb: str, node, scope, unit: str):
    """`node` truncated to `unit`, once its type is known to be a Date or a
    Datetime with no time zone."""
    found = scope.arrow_type(node)
    if found != "date32" and not found.startswith("timestamp"):
        raise TypeError(f"{verb} needs a Date or a Datetime expression, and this one is of type {found}")
    zone = scope.zone(node)
    if zone:
        raise UnsupportedOperation(
            f"{verb} of a Datetime with the time zone {zone} is not supported: polars truncates it by the "
            "local day, which the plan does not compute"
        )
    return Extract(unit, node)


class ExprDateTimeNameSpace:
    """The temporal functions of an `Expr`, as `expr.dt`."""

    __slots__ = ("_expr",)

    def __init__(self, expr) -> None:
        object.__setattr__(self, "_expr", expr)

    def __getattr__(self, name: str):
        raise _names.missing("ExprDateTimeNameSpace", name)

    def __setattr__(self, name: str, value: object) -> None:
        raise AttributeError(f"cannot set the attribute '{name}' of a temporal namespace")

    def truncate(self, every: str) -> object:
        """Each value cut down to the start of its day (`"1d"`), its week from
        Monday (`"1w"`) or its month (`"1mo"`), of the input's type."""
        unit = truncate_unit("dt.truncate", every)
        return self._expr._unary(lambda a, s: truncated("dt.truncate", a, s, unit))
