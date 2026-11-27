"""The refusal tables of komira.pl (dataframe_surface_verbs.md, "The refusal
tables") and the `AttributeError` a name a class or the module does not
define raises (dataframe_surface.md, section 5).

`__getattr__` of every public class and of the module only ever raises:

- a name that starts with `_` raises a bare `AttributeError` at once, so
  Python's and its tools' probes (`_repr_html_`, `__array__`, pickle and copy)
  find nothing;
- a name in the class's table raises its message, which says why the name is
  missing and what to write instead;
- any other name raises Python's own message.

A `LazyFrame` adds one case before Python's own (`frame_missing`): a name that
is one of the frame's columns is answered with how to name a column.
"""

from __future__ import annotations

__all__ = ["MODULE", "TABLES", "frame_missing", "missing", "module_missing"]

_LAZY_ONLY = "komira.pl frames are lazy: use komira.pl.scan_{fmt}(...) and run it with .collect()"
_NO_NODE = ".{name}() is not supported yet: the plan has no node for it"
_RUNS_AT = ".{name}() is not supported: komira runs a plan only at .collect()"
_ORDERED_KEY = ".{name}() is not supported yet; use .min() or .max() of an ordered key"
_PLAN = "a LazyFrame is a plan: run it with .collect(), then convert the Result"

# The module `komira.pl`: name -> message.
MODULE = {
    "read_parquet": _LAZY_ONLY.format(fmt="parquet"),
    "read_csv": _LAZY_ONLY.format(fmt="csv"),
    "read_ndjson": _LAZY_ONLY.format(fmt="ndjson"),
    "read_ipc": _LAZY_ONLY.format(fmt="ipc"),
    "read_avro": _LAZY_ONLY.format(fmt="avro"),
    "count": (
        "komira.pl.count() is refused: it named both questions in polars; say "
        "komira.pl.len() for rows or komira.pl.col(name).count() for non-null values"
    ),
    "DataFrame": (
        "komira.pl has no eager frame: a LazyFrame runs at .collect(), which returns a Result"
    ),
}

# Each class: name -> message, `{name}` standing for the name looked up.
TABLES = {
    "LazyFrame": {
        "materialize": (
            ".materialize() is the pandas-shaped skin's word; this frame runs at .collect()"
        ),
        "to_pandas": _PLAN,
        "to_polars": _PLAN,
        "to_arrow": _PLAN,
        "fetch": _PLAN,
        "with_column": "with_column() is not a polars verb; use with_columns()",
        "unpivot": _NO_NODE,
        "cache": _RUNS_AT,
        "profile": _RUNS_AT,
        "collect_async": _RUNS_AT,
    },
    "Expr": {
        "apply": "Expr.apply is not a polars verb; use map_elements(f, return_dtype=...)",
        "sort_by": (
            "Expr.sort_by() is not supported: the plan carries no order inside an "
            "expression; sort the frame instead"
        ),
        "first": _ORDERED_KEY,
        "last": _ORDERED_KEY,
    },
    "LazyGroupBy": {
        "first": _ORDERED_KEY,
        "last": _ORDERED_KEY,
    },
}


def _python_message(owner: str, name: str) -> str:
    return f"'{owner}' object has no attribute '{name}'"


def missing(owner: str, name: str) -> AttributeError:
    """The `AttributeError` for the name `name` that the class `owner` does
    not define; the caller raises it."""
    if name.startswith("_"):
        return AttributeError(name)
    message = TABLES.get(owner, {}).get(name)
    if message is not None:
        return AttributeError(message.format(name=name))
    return AttributeError(_python_message(owner, name))


def frame_missing(name: str, columns: tuple[str, ...]) -> AttributeError:
    """`missing` for a `LazyFrame`, which first answers a column's name with
    how to name a column (no attribute is a column)."""
    if not name.startswith("_") and name not in TABLES["LazyFrame"] and name in columns:
        return AttributeError(
            f"'LazyFrame' object has no attribute '{name}': no attribute is a column; "
            f"name the column with komira.pl.col({name!r})"
        )
    return missing("LazyFrame", name)


def module_missing(name: str) -> AttributeError:
    """The `AttributeError` for a name the module `komira.pl` does not define."""
    if name.startswith("_"):
        return AttributeError(name)
    if name in MODULE:
        return AttributeError(MODULE[name])
    return AttributeError(f"module 'komira.pl' has no attribute '{name}'")
