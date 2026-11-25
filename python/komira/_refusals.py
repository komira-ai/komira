"""The refusal tables of the pandas-shaped skin (docs/design/dataframe_surface_verbs.md,
"The refusal tables"): names the skin does not define, each with the message
of the `AttributeError` its lookup raises, `{name}` standing for the name
looked up.

A name in no table raises Python's own `AttributeError`; a verb that exists
but refuses an argument raises `UnsupportedOperation` at the call and is not
listed here (docs/design/dataframe_surface.md, section 5).
"""

from __future__ import annotations

__all__ = ["FRAME", "MODULE", "SERIES", "refused"]


def _rows(*rows: tuple[tuple[str, ...], str]) -> dict[str, str]:
    out: dict[str, str] = {}
    for names, message in rows:
        for name in names:
            out[name] = message
    return out


# The rows the DataFrame and the Series share.
_BOTH = _rows(
    (
        ("loc", "iloc", "at", "iat"),
        ".{name} selects by index label or position, and komira frames have no index: "
        "filter with df[pred], or sort_values(...).head(n)",
    ),
    (("index", "set_index", "reset_index", "sort_index", "reindex"), "komira frames have no index"),
    (("sample",), ".sample() is not supported: it picks rows at random, and a plan names no random rows"),
    (
        ("shift", "diff", "pct_change", "ffill", "bfill", "interpolate", "expanding"),
        ".{name}() is not supported yet",
    ),
    (
        ("iterrows", "itertuples", "items", "values", "to_numpy", "to_list", "tolist", "item"),
        ".{name} needs the rows: run the frame with materialize(), then convert the Result with to_pandas()",
    ),
    (("plot",), ".plot needs the rows: use materialize().to_pandas().plot"),
)

FRAME = _BOTH | _rows(
    (
        ("join",),
        "DataFrame.join joins on the index, which komira frames do not have; use merge(other, on=...)",
    ),
    (
        ("to_pandas", "to_polars", "to_arrow"),
        "a komira DataFrame is a plan: run it with .materialize(), then call .{name}() on the Result",
    ),
    (
        ("shape", "size", "empty"),
        '.{name} needs a query to run: count rows with df.agg(n=(column, "size")).materialize()',
    ),
    (
        ("to_dict", "to_records", "to_excel", "to_sql", "to_string", "to_markdown"),
        ".{name}() is pandas' own: run with materialize(), then call to_pandas().{name}()",
    ),
    (
        ("pivot", "pivot_table", "melt", "stack", "unstack", "explode", "transpose", "T"),
        ".{name}() is not supported yet: the plan has no node for it",
    ),
    (
        ("describe", "info", "memory_usage"),
        ".{name}() reports on a pandas object; run with materialize(), then call to_pandas().{name}()",
    ),
    (
        ("query", "eval"),
        '.{name}() takes an expression as text, which komira does not parse; write df[df["a"] > 1]',
    ),
    (("collect",), ".collect() is the polars-shaped skin's word; this frame runs at .materialize()"),
    (("compute",), ".compute() is dask's word; this frame runs at .materialize()"),
)

SERIES = _BOTH | _rows(
    (
        ("cat", "sparse"),
        "the .{name} accessor is not supported: komira has no categorical or sparse dtype",
    ),
)

MODULE = _rows(
    (("Index", "MultiIndex", "RangeIndex"), "komira frames have no index"),
    (
        ("pivot_table", "melt", "crosstab", "get_dummies"),
        "komira.{name}() is not supported yet: the plan has no node for it",
    ),
    (
        ("merge_ordered",),
        "merge_ordered() fills by row order, which a frame does not have; use merge() then sort_values()",
    ),
    (("to_datetime", "to_numeric"), "komira.{name}() is not supported; cast a column with s.astype(...)"),
    (("NamedAgg",), 'use a tuple: agg(out=("column", "func"))'),
)


def refused(table: dict[str, str], name: str) -> str | None:
    """The message of `name` in `table`, or None when the table has no row for it."""
    message = table.get(name)
    return None if message is None else message.format(name=name)
