"""komira.pl: the polars-shaped DataFrame surface.

    import komira.pl as kpl

    lf = kpl.scan_parquet("trips.parquet")
    out = (
        lf.filter(kpl.col("fare") > 10)
        .with_columns((kpl.col("fare") / kpl.col("miles")).alias("per_mile"))
        .sort("per_mile", descending=True)
        .head(5)
        .collect()
    )
    out.to_polars()

Lazy frames and unbound expressions, as in polars (docs/design/dataframe_surface.md).
A frame is a plan of the package's private node tree. No verb runs a query:
`collect()` encodes the plan and runs it through libkomira's plan entry
(`komira_plan_stream`), and returns the package's `Result`, read once. Nothing
here writes SQL text, and nothing imports polars to compute.

The names are exactly `__all__`. A name the module or one of its classes does
not define raises `AttributeError`; for the names in the refusal tables
(docs/design/dataframe_surface_verbs.md) the message says why the name is
missing and what to write instead.

Running a frame needs the generated plan modules (`komira.plan.v1`) and
protobuf, which the encoder imports when the first frame is made.
"""

from __future__ import annotations

from . import _names
from ._expr import Expr, ExprStringNameSpace, col, len, lit, when
from ._frame import LazyFrame, concat, scan_csv, scan_ndjson, scan_parquet

__all__ = [
    "Expr",
    "ExprStringNameSpace",
    "LazyFrame",
    "col",
    "concat",
    "len",
    "lit",
    "scan_csv",
    "scan_ndjson",
    "scan_parquet",
    "when",
]


def __getattr__(name: str):
    raise _names.module_missing(name)


def __dir__() -> list[str]:
    return sorted(__all__)
