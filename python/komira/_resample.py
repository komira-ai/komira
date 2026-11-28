"""`DataFrame.resample(rule, on=column)`: the rows bucketed by a date or
timestamp column into days, weeks or months, as a `GroupBy` to reduce
(docs/design/dataframe_surface_verbs.md, the `resample` row).

pandas resamples a time index; a komira frame has none, so the column is
named with `on=` (pandas' own keyword for a column) and is required. The
bucket of each row replaces the value of that column, under its name, and the
`GroupBy` groups by it: `df.resample("MS", on="d")["v"].sum()` is a frame of
`d` (the bucket) and `v`. Each bucket is the engine's `date_trunc` of the
column, so the groups are DuckDB's `GROUP BY date_trunc(unit, d)`:

| rule | bucket | label (pandas' default) |
|---|---|---|
| `D` | the day | the day |
| `W`, `W-SUN` | the week from Monday to Sunday | its Sunday, `date_trunc('week', d) + 6 days` |
| `MS` | the month | its first day, `date_trunc('month', d)` |
| `ME`, `M` | the month | its last day |

pandas' `W` is `W-SUN`, weeks ending on Sunday, closed and labelled on the
right; with its edges moved to the end of the day (pandas' resample does this
for the offsets that name the end of a period), a week holds Monday to Sunday
whole, the week of DuckDB's `date_trunc('week', d)`, which starts on Monday.
The two name the week by different days: pandas by its Sunday, DuckDB by its
Monday. `ME` is closed and labelled on the right too, and holds the calendar
month. Only these default edges are built: `closed=` and `label=` may name
them, and any other is refused by name.

As in pandas, a row whose date is missing is in no bucket. Unlike pandas, a
bucket with no rows has no row in the answer: komira does not fill gaps
(komira-ai/komira#2343). The answer has no row order: the `GroupBy` is made
with `sort=False`.

The engine groups by no timestamp key (`LOWERING_SINK_UNSERVED`): a timestamp
bucket is grouped as its int64 count of ticks, and cast back to the column's
timestamp type above the aggregate, so the answer's key is the timestamp.

The labels at the right edge are built in whole days: the bucket is cast to
its integer count of days (date32) or ticks (timestamp), shifted, and cast
back, since the plan has no date arithmetic. A month's last day is the first
day of the month 31 days after its first day, less one day.
"""

from __future__ import annotations

import re
from typing import TYPE_CHECKING

from . import _ops
from ._errors import UnsupportedOperation

if TYPE_CHECKING:
    from ._frame import DataFrame
    from ._groupby import GroupBy

__all__ = ["resample"]

# rule -> (the engine's unit, whether the label is the last day of the bucket).
_RULES = {
    "D": ("trunc_day", False),
    "W": ("trunc_week", True),
    "W-SUN": ("trunc_week", True),
    "MS": ("trunc_month", False),
    "ME": ("trunc_month", True),
    "M": ("trunc_month", True),
}
_LISTED = "'D', 'W' (or 'W-SUN'), 'MS' or 'ME' (or 'M')"

# The integer each kind of column counts in, and how many of it make a day.
_DAY_TICKS = {
    "date32": ("int32", 1),
    "timestamp_s": ("int64", 86_400),
    "timestamp_ms": ("int64", 86_400_000),
    "timestamp_us": ("int64", 86_400_000_000),
    "timestamp_ns": ("int64", 86_400_000_000_000),
}


def _edge(value: object, name: str, right: bool, rule: str) -> None:
    if value is None:
        return
    if value not in ("left", "right"):
        raise ValueError(f"resample() {name} must be 'left', 'right' or None, not {value!r}")
    default = "right" if right else "left"
    if value != default:
        raise UnsupportedOperation(
            f"resample({rule!r}, {name}={value!r}) moves the bucket edges from pandas' default, "
            f"{name}={default!r} for {rule!r}, which is the only one built: leave {name} at its default"
        )


def _rule(rule: object) -> tuple[str, bool]:
    if not isinstance(rule, str):
        raise TypeError(f"resample() rule must be a str, not {type(rule).__name__}")
    # pandas reads "1D" as "D": one of the unit is the unit.
    found = _RULES.get(rule[1:] if rule.startswith("1") and not rule[1:2].isdigit() else rule)
    if found is not None:
        return found
    if re.match(r"^\d", rule):
        raise UnsupportedOperation(
            f"resample({rule!r}) buckets by a multiple of a unit, and the plan cuts to one whole day, "
            f"week or month: use {_LISTED}"
        )
    raise UnsupportedOperation(f"resample({rule!r}) is not a rule this release buckets by: use {_LISTED}")


def _shift(node: _ops.Node, arrow: str, days: int) -> _ops.Node:
    """`node` plus `days` whole days, through its integer count."""
    integer, per_day = _DAY_TICKS[arrow]
    moved = _ops.Arith("add", _ops.Cast(node, integer), _ops.Lit(days * per_day))
    return _ops.Cast(moved, None, arrow=arrow)


def bucket(node: _ops.Node, arrow: str, unit: str, at_end: bool) -> _ops.Node:
    """The bucket of `node`, a column of the Arrow type `arrow`: the start of
    its `unit` (`trunc_day`, `trunc_week` or `trunc_month`), or with `at_end`
    the last day of it."""
    start = _ops.Extract(unit, node)
    if not at_end:
        return start
    if unit == "trunc_week":
        return _shift(start, arrow, 6)
    following = _ops.Extract("trunc_month", _shift(start, arrow, 31))
    return _shift(following, arrow, -1)


def resample(
    frame: DataFrame,
    rule: object,
    *,
    closed: object,
    label: object,
    on: object,
    level: object,
    origin: object,
    offset: object,
) -> GroupBy:
    """`frame.resample(...)`: the arguments checked now, and the `GroupBy`
    by the bucket of `on`."""
    from ._groupby import GroupBy

    unit, at_end = _rule(rule)
    if level is not None:
        raise UnsupportedOperation(
            "resample(level=...) names a level of the index, and a komira frame has no index: "
            'name the date column with on="column"'
        )
    if on is None:
        raise UnsupportedOperation(
            "resample() buckets a time index, and a komira frame has no index: "
            'name the date or timestamp column with on="column"'
        )
    if not isinstance(on, str):
        raise TypeError(f"resample() on must be a column name, which is a str, not {type(on).__name__}")
    _edge(closed, "closed", at_end, rule)
    _edge(label, "label", at_end, rule)
    if origin != "start_day" or offset is not None:
        raise UnsupportedOperation(
            "resample(origin=..., offset=...) moves where the buckets start, and the buckets here are "
            "whole calendar days, weeks and months: leave both at their default"
        )
    _ops.require_columns((on,), frame._plan.columns)
    series = frame[on]
    arrow = series._type
    if arrow not in _DAY_TICKS:
        raise TypeError(
            f"resample(on={on!r}) needs a date32 or timestamp column, and {on!r} is {arrow}"
        )
    if series._field.tz:
        raise UnsupportedOperation(
            f"resample(on={on!r}) of a timestamp with the time zone {series._field.tz} is not supported: "
            "pandas buckets it by the local day, which the plan does not compute"
        )
    node = bucket(series._node, arrow, unit, at_end)
    if arrow == "date32":
        return GroupBy._of(frame.assign(**{on: series._derive(node)}), (on,), sort=False, dropna=True)
    # The engine groups by no timestamp key: the bucket is grouped as its
    # count of ticks and cast back to the timestamp above the aggregate.
    ticks = frame.assign(**{on: series._derive(_ops.Cast(node, "int64"))})
    return GroupBy._of(ticks, (on,), sort=False, dropna=True, restore=((on, arrow),))
