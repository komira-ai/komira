"""The refusal tables of the pandas-shaped skin (docs/design/dataframe_surface_verbs.md,
"The refusal tables"): names the skin does not define, each with the message
of the `AttributeError` its lookup raises, `{name}` standing for the name
looked up.

A name in no table raises Python's own `AttributeError`; a verb that exists
but refuses an argument raises `UnsupportedOperation` at the call and is not
listed here (docs/design/dataframe_surface.md, section 5).
"""

from __future__ import annotations

__all__ = ["DATETIME", "FRAME", "GROUPBY", "MODULE", "SERIES", "STRING", "refused"]


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
    (
        ("value_counts",),
        ".{name}() gives a Series indexed by the values in pandas, and a komira Series has no index: "
        'count the rows per value with df.groupby(column).size(), and sort them with sort_values("size", ascending=False)',
    ),
    (
        ("unique",),
        ".{name}() gives the distinct values as an array in pandas, which needs the rows, and a komira Series is "
        "part of a plan: select the column as a frame and drop its duplicates, as "
        "df[[column]].drop_duplicates(), then run it with materialize()",
    ),
)

GROUPBY = _rows(
    (("first", "last", "nth", "cumcount"), ".{name}() is not supported yet; use min() or max() of an ordered key"),
    (("filter",), "GroupBy.filter() is not supported yet; aggregate, then filter the result"),
    (
        ("ngroups", "groups", "indices", "get_group"),
        ".{name} needs a query to run; aggregate with .size() and materialize()",
    ),
    (("ohlc",), ".{name}() is not supported: komira has no time index"),
    (
        ("resample",),
        "GroupBy.resample() is not supported yet: resample the frame with df.resample(rule, on=column), "
        "which groups by the bucket alone",
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


# The names the `.str` accessor of a Series does not define.
STRING = _rows(
    (
        ("strip", "lstrip", "rstrip"),
        ".str.{name}() is not supported yet: the engine trims spaces only, and pandas trims all whitespace",
    ),
    (
        ("split", "rsplit", "cat", "get", "join", "findall", "extractall", "get_dummies", "partition", "rpartition"),
        ".str.{name}() is not supported yet: the plan has no node for it",
    ),
    (
        ("ljust", "rjust"),
        ".str.{name}() is not supported yet: use .str.pad(width, side=...), which pads to one side",
    ),
    (
        ("center", "zfill", "wrap", "normalize", "translate", "slice_replace", "encode", "decode"),
        ".str.{name}() is not supported yet: the plan has no node for it",
    ),
    (
        ("title", "capitalize", "swapcase", "casefold"),
        ".str.{name}() is not supported yet: use .str.lower() or .str.upper()",
    ),
    (
        ("count", "find", "rfind", "index", "rindex", "repeat", "removeprefix", "removesuffix"),
        ".str.{name}() is not supported yet",
    ),
    (
        (
            "isalpha",
            "isdigit",
            "isalnum",
            "isnumeric",
            "isdecimal",
            "isspace",
            "islower",
            "isupper",
            "istitle",
        ),
        ".str.{name}() is not supported yet: test the text with .str.fullmatch(pattern)",
    ),
)

# The names the `.dt` accessor of a Series does not define.
DATETIME = _rows(
    (
        ("date", "time", "timetz"),
        ".dt.{name} is not supported yet: the engine cannot cast a timestamp to a date or a time of day; "
        '.dt.floor("D") cuts the time off and stays a timestamp',
    ),
    (
        ("tz", "tz_localize", "tz_convert"),
        ".dt.{name} is not supported: a komira timestamp carries no time zone to convert",
    ),
    (
        ("strftime", "day_name", "month_name"),
        ".dt.{name}() is not supported yet: the engine does not format a timestamp as text",
    ),
    (
        ("round", "ceil"),
        ".dt.{name}() is not supported yet: only .dt.floor() has a plan node",
    ),
    (
        ("normalize",),
        '.dt.normalize() is not supported yet: use .dt.floor("D")',
    ),
    (
        ("to_period", "to_pydatetime", "to_pytimedelta", "as_unit"),
        ".dt.{name}() is not supported: a komira Series is part of a plan, and has no such object",
    ),
    (
        ("total_seconds", "days", "seconds", "microseconds", "nanoseconds", "components"),
        ".dt.{name} is of a timedelta, and komira has no timedelta type",
    ),
    (
        ("nanosecond",),
        ".dt.nanosecond is not supported yet: the plan's extract has no nanosecond part",
    ),
    (
        ("week", "weekofyear", "isocalendar", "isocalendar_week"),
        ".dt.{name} is not supported yet",
    ),
    (
        (
            "is_month_start",
            "is_month_end",
            "is_quarter_start",
            "is_quarter_end",
            "is_year_start",
            "is_year_end",
            "is_leap_year",
            "days_in_month",
            "daysinmonth",
        ),
        ".dt.{name} is not supported yet: the plan has no node for it",
    ),
)


def refused(table: dict[str, str], name: str) -> str | None:
    """The message of `name` in `table`, or None when the table has no row for it."""
    message = table.get(name)
    return None if message is None else message.format(name=name)
