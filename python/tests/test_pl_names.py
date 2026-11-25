"""The names of komira.pl (dataframe_surface.md, section 5, and the refusal
tables of dataframe_surface_verbs.md), with no library and no plan modules:

- importing komira.pl loads no library and imports neither pyarrow, protobuf,
  polars, pandas nor the plan encoder;
- `komira.pl.__all__` is the module's public names, `dir()` lists exactly
  them, and every one is defined;
- for every name in each refusal table (the module, `LazyFrame`, `Expr`),
  `hasattr` is False and the `AttributeError` message equals the table's text
  word for word;
- a name in no table raises Python's own message, and a name starting with
  `_` a bare `AttributeError` (so `_repr_html_` and other probes find
  nothing);
- `lf.<column>` raises, naming `komira.pl.col("<column>")`, and a column
  named like a verb (`head`) is reached only by `col`, while `lf.head()` is
  still the verb;
- setting an attribute is refused on a frame and an expression;
- `len()`, `bool()`, `iter()` and the array protocols of a frame raise
  `UnsupportedOperation` naming `collect()`, and a frame survives
  `copy.copy`.

    test_pl_names.py
"""

import copy
import sys

import komira.pl as kpl
from komira import UnsupportedOperation
from komira._ops import Field, Limit, Scan
from komira._native import _loaded

for module in ("pyarrow", "google.protobuf", "polars", "pandas", "komira._plan", "komira.plan.v1"):
    assert module not in sys.modules, f"importing komira.pl imported {module}"
assert _loaded is None, "importing komira.pl loaded the library"

from komira.pl._frame import LazyFrame  # noqa: E402

PUBLIC = [
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

READ = "komira.pl frames are lazy: use komira.pl.scan_{}(...) and run it with .collect()"

MODULE_TABLE = {
    "read_parquet": READ.format("parquet"),
    "read_csv": READ.format("csv"),
    "read_ndjson": READ.format("ndjson"),
    "read_ipc": READ.format("ipc"),
    "read_avro": READ.format("avro"),
    "count": "komira.pl.count() is refused: it named both questions in polars; say komira.pl.len() "
    "for rows or komira.pl.col(name).count() for non-null values",
    "DataFrame": "komira.pl has no eager frame: a LazyFrame runs at .collect(), which returns a Result",
}

PLAN = "a LazyFrame is a plan: run it with .collect(), then convert the Result"
RUNS = ".{}() is not supported: komira runs a plan only at .collect()"
FRAME_TABLE = {
    "materialize": ".materialize() is the pandas-shaped skin's word; this frame runs at .collect()",
    "to_pandas": PLAN,
    "to_polars": PLAN,
    "to_arrow": PLAN,
    "fetch": PLAN,
    "with_column": "with_column() is not a polars verb; use with_columns()",
    "unpivot": ".unpivot() is not supported yet: the plan has no node for it",
    "explode": ".explode() is not supported yet: the plan has no node for it",
    "cache": RUNS.format("cache"),
    "profile": RUNS.format("profile"),
    "collect_async": RUNS.format("collect_async"),
}

EXPR_TABLE = {
    "apply": "Expr.apply is not a polars verb; use map_elements(f, return_dtype=...)",
    "sort_by": "Expr.sort_by() is not supported: the plan carries no order inside an expression; sort the frame instead",
    "first": ".first() is not supported yet; use .min() or .max() of an ordered key",
    "last": ".last() is not supported yet; use .min() or .max() of an ordered key",
}


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, cls, message):
    e = raised(call)
    assert type(e) is cls, (type(e), e)
    assert str(e) == message, str(e)


def frame():
    """A frame over a scan with columns named like a verb, with no session:
    nothing here runs or encodes it."""
    plan = Scan("t.parquet", "parquet", (Field("head", "int64"), Field("x", "int64")))
    return LazyFrame(None, plan, {}, None)


def test_public_names_are_all_and_dir():
    assert sorted(kpl.__all__) == PUBLIC
    assert dir(kpl) == PUBLIC
    for name in PUBLIC:
        assert hasattr(kpl, name), name


def test_module_refusal_table():
    for name, message in MODULE_TABLE.items():
        assert not hasattr(kpl, name), name
        refused(lambda: getattr(kpl, name), AttributeError, message)
    refused(lambda: kpl.Timestamp, AttributeError, "module 'komira.pl' has no attribute 'Timestamp'")
    refused(lambda: kpl._hidden, AttributeError, "_hidden")


def test_frame_refusal_table_and_python_message():
    lf = frame()
    for name, message in FRAME_TABLE.items():
        assert not hasattr(lf, name), name
        refused(lambda: getattr(lf, name), AttributeError, message)
    refused(lambda: lf.pivot, AttributeError, "'LazyFrame' object has no attribute 'pivot'")
    assert not hasattr(lf, "_repr_html_")
    refused(lambda: lf._repr_html_, AttributeError, "_repr_html_")


def test_expr_refusal_table_and_python_message():
    e = kpl.col("x")
    for name, message in EXPR_TABLE.items():
        assert not hasattr(e, name), name
        refused(lambda: getattr(e, name), AttributeError, message)
    refused(lambda: e.rank, AttributeError, "'Expr' object has no attribute 'rank'")
    refused(lambda: e.str.split, AttributeError, "'ExprStringNameSpace' object has no attribute 'split'")
    refused(lambda: kpl.when(e > 1).else_, AttributeError, "'When' object has no attribute 'else_'")
    refused(lambda: kpl.when(e > 1).then(1).else_, AttributeError, "'Then' object has no attribute 'else_'")


def test_no_attribute_is_a_column():
    lf = frame()
    refused(
        lambda: lf.x,
        AttributeError,
        "'LazyFrame' object has no attribute 'x': no attribute is a column; name the column with komira.pl.col('x')",
    )
    assert callable(lf.head)
    assert isinstance(lf.head(2)._plan, Limit)
    assert "x" not in dir(lf) and "head" in dir(lf)
    for name in FRAME_TABLE:
        assert name not in dir(lf), name


def test_setting_an_attribute_is_refused():
    def set_frame():
        frame().x = 1

    def set_expr():
        kpl.col("x").name = "y"

    refused(
        set_frame,
        AttributeError,
        "cannot set the attribute 'x' of a LazyFrame: a frame is immutable; add or replace a column with with_columns(...)",
    )
    refused(
        set_expr,
        AttributeError,
        "cannot set the attribute 'name' of an Expr: an Expr is immutable; build a new one with its methods",
    )


def test_no_dunder_runs_a_query():
    lf = frame()
    cases = [
        (lambda: len(lf), "len() of a LazyFrame"),
        (lambda: bool(lf), "the truth value of a LazyFrame"),
        (lambda: iter(lf), "iterating a LazyFrame"),
        (lambda: lf.__array__(), "a LazyFrame as an array"),
        (lambda: lf.__arrow_c_stream__(), "a LazyFrame as an Arrow stream"),
    ]
    for call, what in cases:
        refused(
            call,
            UnsupportedOperation,
            f"{what} needs the rows of the frame: run it with .collect(), which returns a Result",
        )


def test_a_frame_survives_copy():
    lf = frame()
    other = copy.copy(lf)
    assert other is not lf
    assert other._plan == lf._plan and other.columns == ["head", "x"]


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("pl_names: {} tests passed".format(len(tests)))


if __name__ == "__main__":
    main()
