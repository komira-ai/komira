"""The missing-value, naming, type and tail verbs of the pandas-shaped
DataFrame (komira/_frame.py, komira/_verbs.py, komira/_missing.py) with no
libkomira: a frame over a Parquet scan whose schema is made here, on a session
stand-in that records the plan bytes it is given. Checked:

- the plan each verb builds, by equality with a hand-built node tree: the
  expression `fillna` puts over each filled column (a CASE, computed in
  int64 or float64 and cast back for an int32 or float32 column, and boolean
  logic with no CASE for a bool column), the filter of `dropna` (any and all,
  subset), the projection of `isna` and `notna` (and their aliases `isnull`
  and `notnull`) over a frame and the node of each over a Series, the
  projection of `rename`, `add_prefix` and `add_suffix`, the
  casts of `astype`, and the TOPN by the reversed keys under the sort of
  `tail`;
- how a float column's missing value is tested: not NULL and not NaN, built
  from comparisons with infinity, through a cast for float32;
- the output columns and types of each verb;
- the order rules: which verbs keep a sorted frame sorted, and which do not;
- every refusal by its class and its full message.

`concat`, the refusal of `value_counts` and the verbs' names and wire are in
test_frame_concat.py.

    test_frame_verbs.py
"""

import os
import sys
import tempfile

from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import BoolOp, Cast, ColRef, Compare, Field, Lit, SortKey, Unary, When
from komira._plan import parquet_source
from komira._plan._wire import arrow_id, field, pb

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_verbs_test_input.parquet")
FIELDS = (("a", "int64"), ("b", "int64"), ("n", "int32"), ("x", "float64"), ("s", "string"), ("ok", "bool"))
SCAN = _ops.scan(PATH, "parquet", tuple(Field(name, dtype) for name, dtype in FIELDS))
COLS = tuple(name for name, _ in FIELDS)
INF = Lit(float("inf"))
MINUS_INF = Lit(float("-inf"))


class Stub:
    """A session that records what the plan door and the renderer are given."""

    def __init__(self):
        self.calls = []
        self.stream = object()

    def _plan_stream(self, plan):
        self.calls.append(("plan_stream", plan))
        return self.stream

    def _plan_render(self, plan):
        self.calls.append(("plan_render", plan))
        return "rendered plan"


class Env:
    """A frame over a scan of `fields` at `path`; `required` names the columns
    that never hold a missing value, and `stub` is the session."""

    def __init__(self, fields=FIELDS, path=PATH, stub=None, required=()):
        self.stub = stub or Stub()
        schema = pb.WireSchema(fields=[field(n, arrow_id(t), n not in required) for n, t in fields])
        self.sources = {path: parquet_source(path, schema.SerializeToString())}
        self.scan = _ops.scan(path, "parquet", tuple(Field(n, t) for n, t in fields))
        self.df = DataFrame._new(self.stub, self.scan, self.sources)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def unknown(name, columns):
    return _ops.unknown_column(name, tuple(columns)).args[0]


def not_nan(x):
    """x is not NaN, as the SQL binder builds it."""
    finite = BoolOp("and", Compare("gt", x, MINUS_INF), Compare("lt", x, INF))
    return BoolOp("or", BoolOp("or", finite, Compare("eq", x, INF)), Compare("eq", x, MINUS_INF))


def present(name, dtype):
    """The test that the column `name` of type `dtype` holds a value."""
    column = ColRef(name)
    if dtype == "float64":
        return BoolOp("and", Unary("is_not_null", column), not_nan(column))
    if dtype == "float32":
        return BoolOp("and", Unary("is_not_null", column), not_nan(Cast(column, "float64")))
    return Unary("is_not_null", column)


def filled(name, dtype, fill):
    """The column `name` with the literal `fill` where it holds no value: a
    CASE, computed in int64 or float64 for an int32 or float32 column and cast
    back, since the engine's CASE gives int64, float64 or string; for a bool
    column, `x IS NULL OR x = true` (True) or `x IS NOT NULL AND x = true`
    (False)."""
    column = ColRef(name)
    if dtype == "bool":
        is_true = Compare("eq", column, Lit(True))
        if fill.value:
            return BoolOp("or", Unary("is_null", column), is_true)
        return BoolOp("and", Unary("is_not_null", column), is_true)
    wide = {"int32": "int64", "float32": "float64"}.get(dtype)
    if wide is None:
        return When(((present(name, dtype), column),), fill)
    return Cast(When(((present(name, dtype), Cast(column, wide)),), fill), dtype)


def project(columns, replace=None, scan=SCAN):
    """The projection of `scan` that keeps `columns`, with `replace` swapped in by name."""
    replace = replace or {}
    return _ops.Project(scan, tuple((n, replace.get(n, ColRef(n))) for n in columns))


# --- fillna ------------------------------------------------------------------


def test_fillna_of_int_columns_fills_with_an_int_literal_cast_to_the_columns_width():
    env = Env((("a", "int64"), ("n", "int32")))
    got = env.df.fillna(0)
    expected = project(
        ("a", "n"),
        {"a": filled("a", "int64", Lit(0)), "n": filled("n", "int32", Lit(0))},
        env.scan,
    )
    assert got._plan == expected
    assert got.columns == ["a", "n"]
    assert got.dtypes == {"a": "int64", "n": "int32"}


def test_fillna_of_float_columns_tests_nan_and_fills_with_a_float_literal():
    env = Env((("x", "float64"), ("f", "float32")))
    got = env.df.fillna(1)
    expected = project(
        ("x", "f"),
        {
            "x": filled("x", "float64", Lit(1.0)),
            "f": filled("f", "float32", Lit(1.0)),
        },
        env.scan,
    )
    assert got._plan == expected
    assert got.dtypes == {"x": "float64", "f": "float32"}
    # A float fill and an int fill are different literals.
    assert got._plan != env.df.fillna(1.5)._plan


def test_the_missing_test_of_a_float_column_is_not_null_and_not_nan_from_comparisons_with_infinity():
    env = Env((("x", "float64"), ("f", "float32"), ("a", "int64")))
    got = env.df.fillna({"x": 0.0, "f": 0.0})._plan
    x = ColRef("x")
    expected_x = BoolOp(
        "and",
        Unary("is_not_null", x),
        BoolOp(
            "or",
            BoolOp("or", BoolOp("and", Compare("gt", x, MINUS_INF), Compare("lt", x, INF)), Compare("eq", x, INF)),
            Compare("eq", x, MINUS_INF),
        ),
    )
    assert got.items[0][1].cases[0][0] == expected_x
    # A float32 column is compared as float64, and a column that is not a float only for NULL.
    f64 = Cast(ColRef("f"), "float64")
    assert got.items[1][1].child.cases[0][0].right.left.left.left == Compare("gt", f64, MINUS_INF)
    assert got.items[1][1].child.cases[0][1] == f64 and got.items[1][1].target == "float32"
    assert got.items[2][1] == ColRef("a")
    assert present("a", "int64") == Unary("is_not_null", ColRef("a"))


def test_fillna_of_bool_and_string_columns_by_a_dict_leaves_the_other_columns_alone():
    df = Env().df
    got = df.fillna({"ok": False, "s": ""})
    expected = project(
        COLS, {"ok": filled("ok", "bool", Lit(False)), "s": filled("s", "string", Lit(""))}
    )
    assert got._plan == expected
    assert got.dtypes == df.dtypes


def test_fillna_of_a_bool_column_is_boolean_logic_with_no_case():
    df = Env().df
    ok = ColRef("ok")
    with_true = df.fillna({"ok": True})
    assert with_true._plan == project(
        COLS, {"ok": BoolOp("or", Unary("is_null", ok), Compare("eq", ok, Lit(True)))}
    )
    with_false = df.fillna({"ok": False})
    assert with_false._plan == project(
        COLS, {"ok": BoolOp("and", Unary("is_not_null", ok), Compare("eq", ok, Lit(True)))}
    )
    assert with_true.dtypes["ok"] == "bool" and with_false.dtypes["ok"] == "bool"


def test_fillna_of_a_dict_names_unknown_columns_with_a_key_error():
    df = Env().df
    refuses(lambda: df.fillna({"zz": 0}), KeyError, unknown("zz", COLS))
    refuses(lambda: df.fillna({1: 0}), TypeError, "fillna value names columns with str, not a int")


def test_fillna_of_an_empty_dict_changes_nothing():
    df = Env().df
    got = df.fillna({})
    assert got._plan == df._plan and got is not df
    sorted_df = df.sort_values("a")
    assert sorted_df.fillna({})._plan == sorted_df._plan


def test_fillna_keeps_a_sorted_frame_sorted_unless_it_fills_a_sort_key():
    df = Env().df.sort_values("a")
    keys = (SortKey("a"),)
    kept = df.fillna({"x": 0.0})
    items = project(COLS, {"x": filled("x", "float64", Lit(0.0))}).items
    assert kept._plan == _ops.Sort(_ops.Project(SCAN, items), keys)
    assert kept._order() == keys
    lost = df.fillna({"a": 0})
    assert lost._plan == _ops.Project(
        _ops.Sort(SCAN, keys), project(COLS, {"a": filled("a", "int64", Lit(0))}).items
    )
    assert lost._order() is None


def test_fillna_refuses_the_arguments_it_cannot_honour_by_their_full_message():
    df = Env().df
    refuses(
        lambda: df.fillna(0, inplace=True),
        UnsupportedOperation,
        "fillna(inplace=True) changes the frame in place, and komira frames do not change: "
        "use the frame fillna returns",
    )
    refuses(
        lambda: df.fillna(0, axis=1),
        UnsupportedOperation,
        "fillna(axis=1) fills along each row, and a plan fills columns: use axis=0",
    )
    refuses(
        lambda: df.fillna(0, limit=1),
        UnsupportedOperation,
        "fillna(limit=1) fills only the first values of a run, which needs row order: leave limit out",
    )
    refuses(
        lambda: df.fillna(method="ffill"),
        UnsupportedOperation,
        "fillna(method='ffill') fills from the row before or after, which needs row order: "
        "fill with a value, as fillna(0)",
    )
    refuses(
        lambda: df.fillna(0, downcast="infer"),
        UnsupportedOperation,
        "fillna(downcast='infer') changes the columns' types after filling: cast the columns afterwards with astype()",
    )
    series = (
        "fillna(value=a Series) fills each row from the value at its index, and a komira frame has no index "
        "to align by: fill with a literal, or with a dict of literals by column"
    )
    refuses(lambda: df.fillna(df["a"]), UnsupportedOperation, series)
    refuses(lambda: df.fillna({"a": df["a"]}), UnsupportedOperation, series)
    refuses(
        lambda: df.fillna(df),
        UnsupportedOperation,
        series.replace("a Series", "a DataFrame"),
    )
    refuses(lambda: df.fillna(), ValueError, "Must specify a fill 'value' or 'method'.")
    assert df.fillna({"a": 0}, axis=0)._plan == df.fillna({"a": 0}, axis="index")._plan


def test_fillna_refuses_a_value_the_column_cannot_hold_by_naming_the_column_and_both_types():
    df = Env().df
    tail = "the column keeps its type, so fill it with {}, or cast the column first with astype()"
    refuses(
        lambda: df.fillna({"a": "x"}),
        UnsupportedOperation,
        "fillna() cannot fill the int64 column 'a' with a str: " + tail.format("an int"),
    )
    refuses(
        lambda: df.fillna({"a": 1.5}),
        UnsupportedOperation,
        "fillna() cannot fill the int64 column 'a' with a float: " + tail.format("an int"),
    )
    refuses(
        lambda: df.fillna({"a": True}),
        UnsupportedOperation,
        "fillna() cannot fill the int64 column 'a' with a bool: " + tail.format("an int"),
    )
    refuses(
        lambda: df.fillna({"a": None}),
        UnsupportedOperation,
        "fillna() cannot fill the int64 column 'a' with None: " + tail.format("an int"),
    )
    refuses(
        lambda: df.fillna({"x": "x"}),
        UnsupportedOperation,
        "fillna() cannot fill the float64 column 'x' with a str: " + tail.format("an int or a float"),
    )
    refuses(
        lambda: df.fillna({"s": 0}),
        UnsupportedOperation,
        "fillna() cannot fill the string column 's' with a int: " + tail.format("a str"),
    )
    refuses(
        lambda: df.fillna({"ok": 1}),
        UnsupportedOperation,
        "fillna() cannot fill the bool column 'ok' with a int: " + tail.format("a bool"),
    )
    refuses(
        lambda: df.fillna({"n": 2**31}),
        UnsupportedOperation,
        "fillna() cannot fill the int32 column 'n' with 2147483648: it is out of the range of int32, "
        "so fill it with a value in range, or cast the column first with astype()",
    )
    assert df.fillna({"n": 2**31 - 1}) is not None
    refuses(
        lambda: df.fillna({"x": 10**400}),
        UnsupportedOperation,
        "fillna() cannot fill the float64 column 'x' with an int that is too large for a float: "
        "fill it with a smaller value",
    )
    refuses(
        lambda: Env((("x", "float64"),)).df.fillna(10**400),
        UnsupportedOperation,
        "fillna() cannot fill the float64 column 'x' with an int that is too large for a float: "
        "fill it with a smaller value, or pass a dict to fill only some columns",
    )


def test_fillna_of_a_scalar_names_the_first_column_it_does_not_fit_and_how_to_fill_only_some():
    df = Env().df
    refuses(
        lambda: df.fillna("x"),
        UnsupportedOperation,
        "fillna() cannot fill the int64 column 'a' with a str: the column keeps its type, so fill it with "
        "an int, or cast the column first with astype(), or pass a dict to fill only some columns",
    )
    refuses(
        lambda: df.fillna(1),
        UnsupportedOperation,
        "fillna() cannot fill the string column 's' with a int: the column keeps its type, so fill it with "
        "a str, or cast the column first with astype(), or pass a dict to fill only some columns",
    )


def test_fillna_of_a_column_that_is_not_int_float_bool_or_string_says_what_it_fills():
    env = Env((("a", "int64"), ("d", "date32"), ("t", "int8")))
    cast_first = (
        "fillna() fills int32, int64, float32, float64, bool and string columns, and the column {!r} is {}: "
        "cast it first with astype()"
    )
    refuses(
        lambda: env.df.fillna(0),
        UnsupportedOperation,
        cast_first.format("d", "date32") + ", or pass a dict to fill only the other columns",
    )
    refuses(lambda: env.df.fillna({"t": 0}), UnsupportedOperation, cast_first.format("t", "int8"))
    assert env.df.fillna({"a": 0})._plan == project(
        ("a", "d", "t"), {"a": filled("a", "int64", Lit(0))}, env.scan
    )


# --- dropna --------------------------------------------------------------------


def test_dropna_keeps_the_rows_where_every_column_holds_a_value():
    df = Env().df
    got = df.dropna()
    predicate = _ops.and_all(tuple(present(name, dtype) for name, dtype in FIELDS))
    assert got._plan == _ops.Filter(SCAN, predicate)
    assert got.columns == list(COLS) and got.dtypes == df.dtypes
    assert df.dropna(how="any")._plan == got._plan
    # NaN of the float column is missing, and the integer columns are tested for NULL only.
    assert predicate.right == Unary("is_not_null", ColRef("ok"))


def test_dropna_of_how_all_keeps_the_rows_where_one_subset_column_holds_a_value():
    df = Env().df
    got = df.dropna(how="all", subset=["a", "x"])
    assert got._plan == _ops.Filter(SCAN, BoolOp("or", present("a", "int64"), present("x", "float64")))
    assert df.dropna(how="all", subset="x")._plan == _ops.Filter(SCAN, present("x", "float64"))


def test_dropna_of_a_subset_tests_only_those_columns_once_each():
    df = Env().df
    assert df.dropna(subset="s")._plan == _ops.Filter(SCAN, present("s", "string"))
    both = _ops.Filter(SCAN, BoolOp("and", present("n", "int32"), present("s", "string")))
    assert df.dropna(subset=("n", "s"))._plan == both
    assert df.dropna(subset=["n", "s", "n"])._plan == both
    assert df.dropna(axis="index", ignore_index=True)._plan == df.dropna()._plan


def test_dropna_of_an_empty_subset_keeps_every_row_for_any_and_none_for_all():
    df = Env().df
    assert df.dropna(subset=[])._plan == df._plan
    assert df.dropna(subset=(), how="any")._plan == df._plan
    assert df.dropna(subset=(), how="all")._plan == _ops.Filter(SCAN, Lit(False))


def test_dropna_of_a_float32_column_compares_it_as_float64():
    df = Env((("f", "float32"), ("a", "int64"))).df
    got = df.dropna(subset=["f"])
    assert got._plan.predicate == present("f", "float32")
    assert got._plan.predicate.right.left.left.left == Compare("gt", Cast(ColRef("f"), "float64"), MINUS_INF)


def test_dropna_keeps_a_sorted_frame_sorted_with_the_filter_under_the_sort():
    df = Env().df.sort_values("a")
    got = df.dropna(subset=["s"])
    assert got._plan == _ops.Sort(_ops.Filter(SCAN, present("s", "string")), (SortKey("a"),))
    assert got._order() == (SortKey("a"),)


def test_dropna_refuses_what_it_cannot_honour_by_its_full_message():
    df = Env().df
    refuses(
        lambda: df.dropna(inplace=True),
        UnsupportedOperation,
        "dropna(inplace=True) changes the frame in place, and komira frames do not change: "
        "use the frame dropna returns",
    )
    columns = (
        "dropna(axis={!r}) drops the columns that hold a missing value, and a plan's columns cannot depend "
        "on its rows: choose the columns by name with df[[...]]"
    )
    refuses(lambda: df.dropna(axis=1), UnsupportedOperation, columns.format(1))
    refuses(lambda: df.dropna(axis="columns"), UnsupportedOperation, columns.format("columns"))
    refuses(lambda: df.dropna(axis=2), ValueError, "No axis named 2 for object type DataFrame")
    refuses(lambda: df.dropna(axis=True), ValueError, "No axis named True for object type DataFrame")
    refuses(
        lambda: df.dropna(thresh=2),
        UnsupportedOperation,
        "dropna(thresh=2) counts the values each row holds, which this release does not build: "
        'use how="any" or how="all", or name the columns with subset=',
    )
    refuses(
        lambda: df.dropna(how="any", thresh=2),
        TypeError,
        "You cannot set both the how and thresh arguments at the same time.",
    )
    refuses(lambda: df.dropna(how="some"), ValueError, "invalid how option: some")
    refuses(lambda: df.dropna(subset=["zz"]), KeyError, unknown("zz", COLS))
    refuses(lambda: df.dropna(subset=5), TypeError, "dropna subset takes column names, not a int")
    refuses(lambda: df.dropna(subset=[1]), TypeError, "dropna subset takes column names, which are str, not int")
    refuses(lambda: df.dropna(ignore_index="x"), TypeError, "dropna ignore_index must be a bool, not str")
    assert df.dropna(thresh=None)._plan == df.dropna()._plan


# --- isna, notna, isnull, notnull --------------------------------------------

KINDS = (("a", "int64"), ("x", "float64"), ("f", "float32"), ("s", "string"), ("ok", "bool"))
MEMBERSHIP = (
    "isin() with another Series is a semi join, which is a condition of df[...] and nothing else: "
    'filter with it alone, as df[df["k"].isin(other["k"])], and filter that frame by the other conditions'
)


def missing(name, dtype):
    """The test that the column `name` of type `dtype` holds no value."""
    return Unary("not", present(name, dtype))


def test_series_isna_of_an_integer_column_tests_null_only():
    df = Env(KINDS).df
    got = df["a"].isna()
    assert got._node == Unary("not", Unary("is_not_null", ColRef("a")))
    assert got.dtype == "bool"


def test_series_isna_of_a_float_column_tests_null_and_nan():
    df = Env(KINDS).df
    x = ColRef("x")
    assert df["x"].isna()._node == Unary("not", BoolOp("and", Unary("is_not_null", x), not_nan(x)))
    f = ColRef("f")
    assert df["f"].isna()._node == Unary(
        "not", BoolOp("and", Unary("is_not_null", f), not_nan(Cast(f, "float64")))
    )


def test_series_notna_is_the_exact_negation_of_isna_for_every_kind_of_column():
    df = Env(KINDS).df
    for name, dtype in KINDS:
        assert df[name].notna()._node == present(name, dtype), name
        assert df[name].isna()._node == Unary("not", df[name].notna()._node), name
        assert df[name].isna().dtype == df[name].notna().dtype == "bool", name


def test_series_isnull_and_notnull_are_isna_and_notna():
    df = Env(KINDS).df
    for name, dtype in KINDS:
        assert df[name].isnull()._node == missing(name, dtype), name
        assert df[name].notnull()._node == present(name, dtype), name


def test_series_isna_of_an_expression_tests_the_expression_by_its_type():
    df = Env(KINDS).df
    doubled = df["x"] * 2
    e = doubled._node
    assert doubled.isna()._node == Unary("not", BoolOp("and", Unary("is_not_null", e), not_nan(e)))
    sum_ = (df["a"] + 1)._node
    assert (df["a"] + 1).isna()._node == Unary("not", Unary("is_not_null", sum_))


def test_series_isna_of_a_window_keeps_the_windows_it_reads():
    df = Env().df.sort_values("n")
    running = df["a"].cumsum()
    got = running.isna()
    assert got._windows == running._windows and got._windows
    assert got._node == Unary("not", Unary("is_not_null", running._node))
    assert df.assign(m=got).dtypes["m"] == "bool"


def test_series_isna_of_a_float16_column_compares_it_as_float64():
    df = Env((("h", "float16"),)).df
    h = ColRef("h")
    assert df["h"].isna()._node == Unary(
        "not", BoolOp("and", Unary("is_not_null", h), not_nan(Cast(h, "float64")))
    )


def test_series_isna_filters_rows_and_notna_assigns_a_bool_column():
    df = Env().df
    assert df[df["x"].isna()]._plan == _ops.Filter(SCAN, missing("x", "float64"))
    assert df[df["s"].notna()]._plan == _ops.Filter(SCAN, present("s", "string"))
    got = df.assign(m=df["x"].notna())
    assert got._plan == _ops.Project(SCAN, tuple((n, ColRef(n)) for n in COLS) + (("m", present("x", "float64")),))
    assert got.dtypes["m"] == "bool"


def test_frame_isna_is_one_projection_of_every_column_under_its_own_name():
    df = Env(KINDS).df
    got = df.isna()
    assert got._plan == _ops.Project(df._plan, tuple((n, missing(n, t)) for n, t in KINDS))
    assert got.columns == [n for n, _ in KINDS]
    assert got.dtypes == {n: "bool" for n, _ in KINDS}
    assert df.isnull()._plan == got._plan


def test_frame_notna_is_the_exact_negation_of_isna_column_by_column():
    df = Env(KINDS).df
    got = df.notna()
    assert got._plan == _ops.Project(df._plan, tuple((n, present(n, t)) for n, t in KINDS))
    assert got.dtypes == {n: "bool" for n, _ in KINDS}
    assert df.notnull()._plan == got._plan
    negated = tuple((n, Unary("not", node)) for n, node in got._plan.items)
    assert df.isna()._plan.items == negated


def test_frame_isna_sum_counts_per_column_as_int64():
    df = Env(KINDS).df
    got = df.isna().sum()
    assert got.columns == [n for n, _ in KINDS]
    assert got.dtypes == {n: "int64" for n, _ in KINDS}
    assert df.isna().sum()._plan == got._plan


def test_frame_isna_of_a_sorted_frame_is_unordered_and_a_filter_by_isna_keeps_the_order():
    df = Env().df.sort_values("a")
    assert df.isna()._order() is None
    assert df.notna()._order() is None
    kept = df[df["x"].isna()]
    assert kept._plan == _ops.Sort(_ops.Filter(SCAN, missing("x", "float64")), (SortKey("a"),))


def test_isna_and_notna_of_a_stale_series_or_of_isin_by_a_series_are_refused_by_their_full_message():
    df = Env().df
    stale = df["a"]
    df["b"] = df["a"]
    stale_message = (
        'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
        "take it from the frame again"
    )
    for verb in ("isna", "notna", "isnull", "notnull"):
        refuses(getattr(stale, verb), UnsupportedOperation, stale_message)
        refuses(getattr(df["a"].isin(df["b"]), verb), UnsupportedOperation, MEMBERSHIP)


# --- rename, add_prefix, add_suffix ----------------------------------------------


def test_rename_of_a_dict_is_one_projection_of_every_column_with_the_new_names():
    df = Env().df
    got = df.rename(columns={"a": "aa", "x": "xx"})
    assert got._plan == _ops.Project(
        SCAN,
        (
            ("aa", ColRef("a")),
            ("b", ColRef("b")),
            ("n", ColRef("n")),
            ("xx", ColRef("x")),
            ("s", ColRef("s")),
            ("ok", ColRef("ok")),
        ),
    )
    assert got.columns == ["aa", "b", "n", "xx", "s", "ok"]
    assert got.dtypes == {"aa": "int64", "b": "int64", "n": "int32", "xx": "float64", "s": "string", "ok": "bool"}
    assert df.rename(copy=False, columns={"a": "aa", "x": "xx"})._plan == got._plan


def test_rename_of_a_function_calls_it_with_each_column_name():
    df = Env().df
    got = df.rename(columns=str.upper)
    assert got.columns == ["A", "B", "N", "X", "S", "OK"]
    assert got._plan == _ops.Project(SCAN, tuple((name.upper(), ColRef(name)) for name in COLS))
    seen = []
    df.rename(columns=lambda name: seen.append(name) or name)
    assert seen == list(COLS)


def test_rename_of_a_mapper_with_axis_one_is_rename_of_columns():
    df = Env().df
    expected = df.rename(columns={"a": "aa"})._plan
    assert df.rename({"a": "aa"}, axis=1)._plan == expected
    assert df.rename({"a": "aa"}, axis="columns")._plan == expected
    assert df.rename(str.upper, axis=1).columns == ["A", "B", "N", "X", "S", "OK"]


def test_rename_skips_a_name_the_frame_lacks_unless_errors_is_raise():
    df = Env().df
    assert df.rename(columns={"zz": "yy"})._plan == df._plan
    assert df.rename(columns={"zz": "yy"}, errors="ignore")._plan == df._plan
    refuses(lambda: df.rename(columns={"zz": "yy"}, errors="raise"), KeyError, unknown("zz", COLS))
    assert df.rename(columns={"a": "aa"}, errors="raise")._plan == df.rename(columns={"a": "aa"})._plan


def test_rename_to_the_same_name_or_an_empty_dict_adds_no_node():
    df = Env().df
    assert df.rename(columns={"a": "a"})._plan == df._plan
    assert df.rename(columns={})._plan == df._plan
    assert df.rename(columns=lambda name: name)._plan == df._plan


def test_rename_of_two_columns_to_one_name_or_onto_a_kept_name_is_a_value_error():
    df = Env().df
    twice = "rename would give two columns the name {!r}: rename the other column too, or pick another name"
    refuses(lambda: df.rename(columns={"a": "b"}), ValueError, twice.format("b"))
    refuses(lambda: df.rename(columns={"a": "z", "b": "z"}), ValueError, twice.format("z"))
    swapped = df.rename(columns={"a": "b", "b": "a"})
    assert swapped.columns == ["b", "a", "n", "x", "s", "ok"]
    assert swapped._plan.items[0] == ("b", ColRef("a")) and swapped._plan.items[1] == ("a", ColRef("b"))


def test_rename_keeps_a_sorted_frame_sorted_unless_it_renames_a_sort_key():
    df = Env().df.sort_values("a")
    keys = (SortKey("a"),)
    kept = df.rename(columns={"b": "bb"})
    assert kept._plan == _ops.Sort(
        _ops.Project(SCAN, tuple((("bb" if n == "b" else n), ColRef(n)) for n in COLS)), keys
    )
    assert kept._order() == keys
    lost = df.rename(columns={"a": "aa"})
    assert lost._plan == _ops.Project(
        _ops.Sort(SCAN, keys), tuple((("aa" if n == "a" else n), ColRef(n)) for n in COLS)
    )
    assert lost._order() is None


def test_rename_refuses_the_index_and_what_it_cannot_honour_by_its_full_message():
    df = Env().df
    no_index = "komira frames have no index: rename columns with rename(columns={...})"
    refuses(
        lambda: df.rename(columns={"a": "aa"}, inplace=True),
        UnsupportedOperation,
        "rename(inplace=True) changes the frame in place, and komira frames do not change: "
        "use the frame rename returns",
    )
    refuses(
        lambda: df.rename(index={"a": "aa"}),
        UnsupportedOperation,
        "rename(index=...) renames row labels, and " + no_index,
    )
    refuses(
        lambda: df.rename({"a": "aa"}),
        UnsupportedOperation,
        "rename(mapper) renames row labels by default, and " + no_index,
    )
    refuses(
        lambda: df.rename({"a": "aa"}, axis=0),
        UnsupportedOperation,
        "rename(mapper) renames row labels with axis=0, and " + no_index,
    )
    refuses(
        lambda: df.rename({"a": "aa"}, axis="index"),
        UnsupportedOperation,
        "rename(mapper) renames row labels with axis='index', and " + no_index,
    )
    refuses(
        lambda: df.rename(columns={"a": "aa"}, level=0),
        UnsupportedOperation,
        "rename(level=0) picks a level of a multi-level index, and komira frames have no index: "
        "rename columns with rename(columns={...})",
    )
    refuses(
        lambda: df.rename({"a": "aa"}, columns={"b": "bb"}),
        TypeError,
        "Cannot specify both 'mapper' and any of 'index' or 'columns'",
    )
    refuses(lambda: df.rename({"a": "aa"}, axis=2), ValueError, "No axis named 2 for object type DataFrame")
    refuses(lambda: df.rename({"a": "aa"}, axis=True), ValueError, "No axis named True for object type DataFrame")
    refuses(
        lambda: df.rename(columns={"a": "aa"}, errors="warn"),
        ValueError,
        "rename errors must be 'ignore' or 'raise', not 'warn'",
    )
    refuses(lambda: df.rename(columns={"a": "aa"}, copy="x"), TypeError, "rename copy must be a bool, not str")


def test_rename_refuses_a_columns_argument_that_is_not_names_with_its_full_message():
    df = Env().df
    refuses(
        lambda: df.rename(),
        TypeError,
        "rename() needs the new names: pass columns={'old': 'new'}, or a function of the name",
    )
    refuses(
        lambda: df.rename(columns=["a"]), TypeError, "rename columns takes a dict or a function, not a list"
    )
    refuses(
        lambda: df.rename(columns={"a": 1}),
        TypeError,
        "rename columns maps column names to new names, and both are str",
    )
    refuses(
        lambda: df.rename(columns={1: "a"}),
        TypeError,
        "rename columns maps column names to new names, and both are str",
    )
    refuses(
        lambda: df.rename(columns=lambda name: 1),
        TypeError,
        "rename columns function returned a value of type int for the column 'a', and column names are str",
    )


def test_add_prefix_and_add_suffix_rename_every_column():
    df = Env().df
    pre = df.add_prefix("p_")
    assert pre.columns == ["p_" + n for n in COLS]
    assert pre._plan == _ops.Project(SCAN, tuple(("p_" + n, ColRef(n)) for n in COLS))
    assert pre.dtypes == {"p_" + n: t for n, t in FIELDS}
    suf = df.add_suffix("_s")
    assert suf._plan == _ops.Project(SCAN, tuple((n + "_s", ColRef(n)) for n in COLS))
    assert df.add_prefix("p_", axis=1)._plan == pre._plan
    assert df.add_suffix("_s", axis="columns")._plan == suf._plan
    assert df.add_prefix("")._plan == df._plan and df.add_suffix("")._plan == df._plan


def test_add_prefix_and_add_suffix_keep_a_sorted_frame_sorted_only_when_the_sort_key_keeps_its_name():
    df = Env().df.sort_values("a")
    assert df.add_prefix("p_")._order() is None
    assert df.add_suffix("")._order() == (SortKey("a"),)


def test_add_prefix_and_add_suffix_refuse_the_index_and_what_is_not_a_str_by_their_full_message():
    df = Env().df
    refuses(
        lambda: df.add_prefix("p_", axis=0),
        UnsupportedOperation,
        "add_prefix(axis=0) changes row labels, and komira frames have no index: use axis=1, or leave it out",
    )
    refuses(
        lambda: df.add_suffix("_s", axis="index"),
        UnsupportedOperation,
        "add_suffix(axis='index') changes row labels, and komira frames have no index: use axis=1, or leave it out",
    )
    refuses(lambda: df.add_prefix("p_", axis=2), ValueError, "No axis named 2 for object type DataFrame")
    refuses(lambda: df.add_prefix(1), TypeError, "add_prefix prefix must be a str, not int")
    refuses(lambda: df.add_suffix(None), TypeError, "add_suffix suffix must be a str, not NoneType")


# --- astype -------------------------------------------------------------------


def test_astype_of_a_dict_casts_only_the_named_columns_in_one_projection():
    df = Env().df
    got = df.astype({"n": "int64", "x": "string"})
    assert got._plan == project(
        COLS, {"n": Cast(ColRef("n"), "int64"), "x": Cast(ColRef("x"), None, arrow="string")}
    )
    assert got.dtypes == {**df.dtypes, "n": "int64", "x": "string"}
    assert df.astype({"n": "int64", "x": "string"}, copy=True)._plan == got._plan


def test_astype_of_one_dtype_casts_every_column_that_does_not_have_it():
    df = Env((("a", "int64"), ("n", "int32"), ("x", "float64"))).df
    got = df.astype("int64")
    assert got._plan == project(
        ("a", "n", "x"),
        {"n": Cast(ColRef("n"), "int64"), "x": Cast(ColRef("x"), "int64")},
        df._plan,
    )
    assert got.dtypes == {"a": "int64", "n": "int64", "x": "int64"}


def test_astype_of_the_type_every_column_has_or_of_an_empty_dict_changes_nothing():
    df = Env((("a", "int64"), ("b", "int64"))).df
    assert df.astype("int64")._plan == df._plan
    assert df.astype({"a": "int64"})._plan == df._plan
    assert df.astype({})._plan == df._plan


def test_astype_names_unknown_columns_with_a_key_error_and_dict_keys_with_a_type_error():
    df = Env().df
    refuses(lambda: df.astype({"zz": "int64"}), KeyError, unknown("zz", COLS))
    refuses(lambda: df.astype({1: "int64"}), TypeError, "astype dtype names columns with str, not a int")


def test_astype_refuses_errors_ignore_and_other_values_and_checks_copy():
    df = Env().df
    refuses(
        lambda: df.astype("int64", errors="ignore"),
        UnsupportedOperation,
        'astype(errors="ignore") would return the column uncast when a value does not convert, '
        'which a plan cannot decide before it runs: use errors="raise", the default',
    )
    refuses(
        lambda: df.astype("int64", errors="coerce"),
        ValueError,
        "Expected value of kwarg 'errors' to be one of ['raise', 'ignore']. Supplied value is 'coerce'",
    )
    refuses(lambda: df.astype("int64", copy="x"), TypeError, "astype() copy must be a bool or None, not a str")


def test_astype_keeps_a_sorted_frame_sorted_unless_it_casts_a_sort_key():
    df = Env().df.sort_values("a")
    keys = (SortKey("a"),)
    kept = df.astype({"x": "float32"})
    assert kept._plan == _ops.Sort(project(COLS, {"x": Cast(ColRef("x"), "float32")}), keys)
    assert kept._order() == keys
    lost = df.astype({"a": "float64"})
    assert lost._plan == _ops.Project(
        _ops.Sort(SCAN, keys), project(COLS, {"a": Cast(ColRef("a"), "float64")}).items
    )
    assert lost._order() is None


# --- tail ---------------------------------------------------------------------


def test_tail_of_a_sorted_frame_is_a_topn_by_the_reversed_keys_under_the_original_sort():
    df = Env().df.sort_values("a")
    got = df.tail(3)
    assert got._plan == _ops.Sort(
        _ops.TopN(SCAN, (SortKey("a", descending=True, nulls_first=True),), 3), (SortKey("a"),)
    )
    assert got._order() == (SortKey("a"),)
    assert got.columns == list(COLS) and got.dtypes == df.dtypes


def test_tail_of_two_keys_with_missing_values_first_reverses_every_direction_and_null_placement():
    df = Env().df.sort_values(["a", "b"], ascending=[True, False], na_position="first")
    keys = (SortKey("a", descending=False, nulls_first=True), SortKey("b", descending=True, nulls_first=True))
    reversed_keys = (SortKey("a", descending=True, nulls_first=False), SortKey("b", descending=False, nulls_first=False))
    assert df._plan == _ops.Sort(SCAN, keys)
    assert df.tail(4)._plan == _ops.Sort(_ops.TopN(SCAN, reversed_keys, 4), keys)


def test_tail_defaults_to_five_rows_and_tail_of_zero_is_a_topn_of_none():
    df = Env().df.sort_values("a")
    assert df.tail()._plan.child.n == 5
    zero = df.tail(0)
    assert zero._plan.child.n == 0 and zero._order() == (SortKey("a"),)


def test_tail_of_a_filtered_sorted_frame_takes_the_last_of_the_filtered_rows():
    df = Env().df.sort_values("a")
    got = df[df["b"] > 1].tail(2)
    filtered = _ops.Filter(SCAN, Compare("gt", ColRef("b"), Lit(1)))
    assert got._plan == _ops.Sort(
        _ops.TopN(filtered, (SortKey("a", descending=True, nulls_first=True),), 2), (SortKey("a"),)
    )


def test_a_head_of_a_tail_is_a_limit_over_the_tail_and_a_tail_of_a_tail_is_a_topn_of_a_topn():
    df = Env().df.sort_values("a")
    flipped = (SortKey("a", descending=True, nulls_first=True),)
    keys = (SortKey("a"),)
    assert df.tail(5).head(2)._plan == _ops.Limit(_ops.Sort(_ops.TopN(SCAN, flipped, 5), keys), 2)
    assert df.tail(5).tail(2)._plan == _ops.Sort(_ops.TopN(_ops.TopN(SCAN, flipped, 5), flipped, 2), keys)


def test_tail_refuses_an_unsorted_frame_and_a_cut_frame_and_a_bad_n_by_its_full_message():
    df = Env().df
    refuses(
        lambda: df.tail(2),
        UnsupportedOperation,
        "tail(2) takes the last rows by order, and an unsorted frame has none: sort with sort_values(...) first",
    )
    refuses(
        lambda: df.sort_values("a").head(3).tail(2),
        UnsupportedOperation,
        "tail(2) of a frame cut by head() takes the last of the first rows, which needs the row count: "
        "take the tail before the head",
    )
    refuses(
        lambda: df.sort_values("a").tail(-1),
        UnsupportedOperation,
        "tail(-1) keeps all rows but the first 1, which needs the row count: "
        "sort with sort_values(...) and take the rows you want with tail(k)",
    )
    refuses(lambda: df.sort_values("a").tail("2"), TypeError, "tail(n) takes an int, not str")
    refuses(lambda: df.sort_values("a").tail(True), TypeError, "tail(n) takes an int, not bool")
    refuses(
        lambda: df.drop_duplicates().tail(1),
        UnsupportedOperation,
        "tail(1) takes the last rows by order, and an unsorted frame has none: sort with sort_values(...) first",
    )


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame verbs: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
