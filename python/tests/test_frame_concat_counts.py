"""`komira.concat`, `Series.value_counts` and the names and wire of the new
frame verbs (komira/_frame.py, komira/_verbs.py, komira/_groupby.py,
komira/_series.py) with no libkomira: a frame over a Parquet scan whose schema
is made here, on a session stand-in that records the plan bytes it is given.
Checked:

- the union `concat` builds, with the projection that reorders a frame's
  columns, the sources of frames from different readers, and every refusal
  of a column set, a type, a nullability or a session, by its full message;
- the filter, aggregate and sort `value_counts` builds, NaN as missing in a
  float column, and every refusal by its class and full message;
- that the new verbs are attributes of the frame, even when a column has
  their name, and that a verb's frame reaches the session only as plan
  bytes, at its terminal.

    test_frame_concat_counts.py
"""

import os
import sys
import tempfile

from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame, concat
from komira._ops import Agg, BoolOp, Cast, ColRef, Compare, Field, Lit, SortKey, Unary, When
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, pb


# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_verbs_test_input.parquet")
OTHER_PATH = os.path.join(tempfile.gettempdir(), "frame_verbs_test_other_input.parquet")
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
    """The column `name` with `fill` where it holds no value."""
    return When(((present(name, dtype), ColRef(name)),), fill)


def project(columns, replace=None, scan=SCAN):
    """The projection of `scan` that keeps `columns`, with `replace` swapped in by name."""
    replace = replace or {}
    return _ops.Project(scan, tuple((n, replace.get(n, ColRef(n))) for n in columns))


# --- concat -------------------------------------------------------------------


def test_concat_of_frames_of_one_schema_is_a_union_with_no_row_order():
    env = Env()
    df = env.df
    low, high = df[df["a"] < 0], df[df["a"] > 10]
    got = concat([low, high])
    assert got._plan == _ops.Union((low._plan, high._plan))
    assert got.columns == list(COLS) and got.dtypes == df.dtypes
    assert got._order() is None and got._session is env.stub and got._sources == env.sources
    assert concat((low, high))._plan == got._plan
    assert concat([low, high], join="inner", ignore_index=True, copy=False)._plan == got._plan


def test_concat_of_sorted_frames_has_no_order_and_of_three_frames_is_one_union():
    df = Env().df
    sorted_df = df.sort_values("a")
    got = concat([sorted_df, sorted_df, df])
    assert got._plan == _ops.Union((sorted_df._plan, sorted_df._plan, df._plan))
    assert got._order() is None


def test_concat_of_one_frame_is_an_equal_frame():
    df = Env().df.sort_values("a")
    got = concat([df])
    assert got._plan == df._plan and got is not df and got._order() == (SortKey("a"),)
    assert concat((df,))._plan == df._plan


def test_concat_reorders_a_frame_with_the_same_columns_in_another_order_by_a_projection():
    df = Env((("a", "int64"), ("b", "string"))).df
    swapped = df[["b", "a"]]
    swapped_plan = _ops.Project(df._plan, (("b", ColRef("b")), ("a", ColRef("a"))))
    assert swapped._plan == swapped_plan
    got = concat([df, swapped])
    assert got._plan == _ops.Union(
        (df._plan, _ops.Project(swapped_plan, (("a", ColRef("a")), ("b", ColRef("b")))))
    )
    assert got.columns == ["a", "b"]
    first_swapped = concat([swapped, df])
    assert first_swapped.columns == ["b", "a"]
    assert first_swapped._plan == _ops.Union(
        (swapped_plan, _ops.Project(df._plan, (("b", ColRef("b")), ("a", ColRef("a")))))
    )


def test_concat_of_frames_from_different_readers_reads_the_sources_of_all():
    stub = Stub()
    first = Env((("a", "int64"),), PATH, stub)
    second = Env((("a", "int64"),), OTHER_PATH, stub)
    got = concat([first.df, second.df])
    assert got._plan == _ops.Union((first.scan, second.scan))
    assert got._sources == {**first.sources, **second.sources} and set(got._sources) == {PATH, OTHER_PATH}
    got.materialize()
    assert stub.calls == [("plan_stream", encode_plan(got._plan, got._sources).SerializeToString())]


def test_concat_refuses_what_it_cannot_honour_by_its_full_message():
    df = Env().df
    refuses(lambda: concat(df), TypeError, "concat() takes a list or tuple of DataFrames, not a DataFrame")
    refuses(lambda: concat({"a": df}), TypeError, "concat() takes a list or tuple of DataFrames, not a dict")
    refuses(lambda: concat(df["a"]), TypeError, "concat() takes a list or tuple of DataFrames, not a Series")
    refuses(lambda: concat([]), ValueError, "No objects to concatenate")
    refuses(
        lambda: concat([df, df["a"]]), TypeError, "concat() takes DataFrames, and frame 1 is of type Series"
    )
    refuses(
        lambda: concat([1, df]), TypeError, "concat() takes DataFrames, and the first frame is of type int"
    )
    refuses(
        lambda: concat([df, df], axis=1),
        UnsupportedOperation,
        "concat(axis=1) sets frames side by side by their rows' index, and komira frames have no index: "
        "add columns with assign(), or join the frames with merge()",
    )
    refuses(lambda: concat([df, df], axis=2), ValueError, "No axis named 2 for object type DataFrame")
    refuses(lambda: concat([df, df], join="left"), ValueError, "concat join must be 'outer' or 'inner', not 'left'")
    for label in ("keys", "levels", "names"):
        refuses(
            lambda label=label: concat([df, df], **{label: ["x", "y"]}),
            UnsupportedOperation,
            f"concat({label}=...) builds a row index from the frames, and komira frames have no index: "
            f"leave {label} out",
        )
    refuses(
        lambda: concat([df, df], verify_integrity=True),
        UnsupportedOperation,
        "concat(verify_integrity=True) checks the row index for duplicates, and komira frames have no index: "
        "use verify_integrity=False",
    )
    refuses(
        lambda: concat([df, df], sort=True),
        UnsupportedOperation,
        "concat(sort=True) sorts the columns by name, which this release does not build: "
        "order the columns in every frame yourself, as df[sorted(df.columns)]",
    )
    refuses(lambda: concat([df, df], ignore_index="x"), TypeError, "concat ignore_index must be a bool, not str")
    refuses(lambda: concat([df, df], copy="x"), TypeError, "concat copy must be a bool, not str")


def test_concat_of_frames_of_two_sessions_is_refused():
    refuses(
        lambda: concat([Env().df, Env().df]),
        UnsupportedOperation,
        "concat() takes frames of one session, and frames of two sessions never meet: "
        "read every frame on the same session",
    )


def test_concat_of_different_column_sets_names_the_missing_and_the_extra_columns():
    df = Env().df
    refuses(
        lambda: concat([df[["a", "b"]], df[["a", "n"]]]),
        UnsupportedOperation,
        "concat() needs every frame to have the same columns, and frame 1 lacks the column 'b' and has the "
        "column 'n', which the first frame does not: pandas would fill the missing columns with NaN, which "
        "komira does not: select the same columns in every frame",
    )
    refuses(
        lambda: concat([df[["a", "b", "n"]], df[["a"]]]),
        UnsupportedOperation,
        "concat() needs every frame to have the same columns, and frame 1 lacks the columns 'b', 'n': "
        "pandas would fill the missing columns with NaN, which komira does not: "
        "select the same columns in every frame",
    )
    refuses(
        lambda: concat([df[["a"]], df[["a", "b"]]]),
        UnsupportedOperation,
        "concat() needs every frame to have the same columns, and frame 1 has the column 'b', which the "
        "first frame does not: pandas would fill the missing columns with NaN, which komira does not: "
        "select the same columns in every frame",
    )


def test_concat_of_a_column_with_two_types_names_the_column_and_both_types():
    stub = Stub()
    ints = Env((("a", "int64"), ("b", "string")), PATH, stub).df
    floats = Env((("a", "float64"), ("b", "string")), OTHER_PATH, stub).df
    refuses(
        lambda: concat([ints, floats]),
        UnsupportedOperation,
        "concat() needs each column to have one type, and the column 'a' is int64 in the first frame and "
        "float64 in frame 1: cast one of them first with astype()",
    )
    refuses(
        lambda: concat([ints, ints, floats]),
        UnsupportedOperation,
        "concat() needs each column to have one type, and the column 'a' is int64 in the first frame and "
        "float64 in frame 2: cast one of them first with astype()",
    )


def test_concat_of_a_column_that_allows_missing_values_in_one_frame_only_says_which():
    stub = Stub()
    strict = Env((("a", "int64"),), PATH, stub, required=("a",)).df
    loose = Env((("a", "int64"),), OTHER_PATH, stub).df
    refuses(
        lambda: concat([strict, loose]),
        UnsupportedOperation,
        "concat() needs a column to allow missing values in every frame or in none, and the column 'a' "
        "allows them in frame 1 but not in the first frame: apply fillna() to that column in the first "
        "frame, which makes it allow them",
    )
    refuses(
        lambda: concat([loose, strict]),
        UnsupportedOperation,
        "concat() needs a column to allow missing values in every frame or in none, and the column 'a' "
        "allows them in the first frame but not in frame 1: apply fillna() to that column in frame 1, "
        "which makes it allow them",
    )


# --- value_counts -------------------------------------------------------------------


def counted(plan, column, sort=True, descending=True):
    """The plan of value_counts: the aggregate of count(*) by `column`, sorted by the count."""
    plan = _ops.aggregate(plan, (column,), (("count", Agg("count")),))
    if sort:
        plan = _ops.sort(plan, (SortKey("count", descending=descending),))
    return plan


def test_value_counts_of_an_int_column_is_count_by_value_sorted_by_count_descending():
    df = Env().df
    got = df["a"].value_counts()
    filtered = _ops.Filter(SCAN, Unary("is_not_null", ColRef("a")))
    assert got._plan == counted(filtered, "a")
    assert got.columns == ["a", "count"]
    assert got.dtypes == {"a": "int64", "count": "int64"}
    assert got._order() == (SortKey("count", descending=True),)


def test_value_counts_of_string_and_bool_columns_filter_only_null():
    df = Env().df
    assert df["s"].value_counts()._plan == counted(_ops.Filter(SCAN, Unary("is_not_null", ColRef("s"))), "s")
    got = df["ok"].value_counts()
    assert got._plan == counted(_ops.Filter(SCAN, Unary("is_not_null", ColRef("ok"))), "ok")
    assert got.dtypes == {"ok": "bool", "count": "int64"}


def test_value_counts_of_a_float_column_leaves_out_nan_as_well_as_null():
    df = Env((("x", "float64"), ("f", "float32"))).df
    assert df["x"].value_counts()._plan == counted(
        _ops.Filter(df._plan, present("x", "float64")), "x"
    )
    assert df["f"].value_counts()._plan == counted(
        _ops.Filter(df._plan, present("f", "float32")), "f"
    )


def test_value_counts_of_sort_false_is_unordered_and_ascending_sorts_the_other_way():
    df = Env().df
    filtered = _ops.Filter(SCAN, Unary("is_not_null", ColRef("a")))
    unsorted = df["a"].value_counts(sort=False)
    assert unsorted._plan == counted(filtered, "a", sort=False) and unsorted._order() is None
    ascending = df["a"].value_counts(ascending=True)
    assert ascending._plan == counted(filtered, "a", descending=False)
    assert df["a"].value_counts(False, True, True)._plan == ascending._plan


def test_value_counts_of_dropna_false_keeps_the_null_group_of_a_column_that_is_not_a_float():
    df = Env().df
    got = df["s"].value_counts(dropna=False)
    assert got._plan == counted(SCAN, "s")


def test_value_counts_of_a_filtered_or_sorted_frame_counts_its_rows():
    df = Env().df
    filtered = df[df["b"] > 1]
    got = filtered["s"].value_counts()
    assert got._plan == counted(_ops.Filter(filtered._plan, Unary("is_not_null", ColRef("s"))), "s")
    ordered = df.sort_values("a")
    under = ordered["s"].value_counts()
    assert under._plan == counted(_ops.Sort(_ops.Filter(SCAN, Unary("is_not_null", ColRef("s"))), (SortKey("a"),)), "s")


def test_value_counts_refuses_what_it_cannot_honour_by_its_full_message():
    df = Env().df
    refuses(
        lambda: df["a"].value_counts(normalize=True),
        UnsupportedOperation,
        "value_counts(normalize=True) divides each count by the row total, which this release does not build: "
        "use normalize=False and divide the count column by its sum",
    )
    refuses(
        lambda: df["a"].value_counts(bins=3),
        UnsupportedOperation,
        "value_counts(bins=...) counts values per numeric range, which this release does not build: "
        "assign the range of each row as a column, then count that column",
    )
    refuses(
        lambda: Env(FIELDS + (("count", "int64"),)).df["count"].value_counts(),
        UnsupportedOperation,
        "value_counts() of the column 'count' would give two output columns named 'count': "
        "rename the column first, as df.rename(columns={'count': 'value'})",
    )
    refuses(
        lambda: df["x"].value_counts(dropna=False),
        UnsupportedOperation,
        "value_counts(dropna=False) of the float64 column 'x' would count NULL and NaN as two groups, "
        "where pandas counts one missing group: use dropna=True, or fill the missing values first with fillna()",
    )
    refuses(
        lambda: (df["a"] + 1).value_counts(),
        UnsupportedOperation,
        "value_counts() of a computed Series counts values the frame does not hold as a column: "
        "assign it as a column first, then count df[name].value_counts()",
    )
    refuses(lambda: df["a"].value_counts(sort="yes"), TypeError, "value_counts sort must be a bool, not str")
    refuses(lambda: df["a"].value_counts(ascending=1), TypeError, "value_counts ascending must be a bool, not int")
    refuses(lambda: df["a"].value_counts(dropna=None), TypeError, "value_counts dropna must be a bool, not NoneType")
    refuses(lambda: df["a"].value_counts(normalize=0), TypeError, "value_counts normalize must be a bool, not int")


def test_value_counts_of_a_series_taken_before_the_frame_changed_is_refused():
    df = Env().df
    stale = df["a"]
    df["b"] = df["a"] + 1
    refuses(
        lambda: stale.value_counts(),
        UnsupportedOperation,
        'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
        "take it from the frame again",
    )
    assert df["a"].value_counts().columns == ["a", "count"]


# --- the names and the wire --------------------------------------------------------------


def test_the_new_verbs_are_attributes_of_the_frame_and_value_counts_of_a_series():
    df = Env().df
    for name in ("fillna", "dropna", "rename", "add_prefix", "add_suffix", "astype", "tail"):
        assert hasattr(df, name) and callable(getattr(df, name)), name
    assert hasattr(df["a"], "value_counts")
    assert callable(concat)


def test_a_column_with_a_verbs_name_is_reached_by_subscript_and_the_verb_by_attribute():
    env = Env((("fillna", "float64"), ("dropna", "int64"), ("tail", "int64")))
    df = env.df
    assert df["fillna"]._node == ColRef("fillna") and df["fillna"].dtype == "float64"
    assert df.fillna({"fillna": 0.5})._plan == project(
        ("fillna", "dropna", "tail"), {"fillna": filled("fillna", "float64", Lit(0.5))}, env.scan
    )
    assert df.dropna(subset="dropna")._plan == _ops.Filter(env.scan, present("dropna", "int64"))
    assert df.rename(columns={"tail": "last"}).columns == ["fillna", "dropna", "last"]


def test_every_new_verb_reaches_the_session_only_as_the_plan_bytes_at_its_terminal():
    sorted_frame = lambda env: env.df.sort_values("a")
    verbs = {
        "fillna": lambda env: env.df.fillna({"x": 0.0, "s": ""}),
        "dropna": lambda env: env.df.dropna(how="all", subset=["a", "x"]),
        "rename": lambda env: env.df.rename(columns=str.upper),
        "add_prefix": lambda env: env.df.add_prefix("p_"),
        "astype": lambda env: env.df.astype({"n": "int64"}),
        "tail": lambda env: sorted_frame(env).tail(3),
        "value_counts": lambda env: env.df["s"].value_counts(),
    }
    for name, build in verbs.items():
        env = Env()
        frame = build(env)
        assert env.stub.calls == [], name
        frame.materialize()
        encoded = encode_plan(frame._plan, env.sources).SerializeToString()
        assert env.stub.calls == [("plan_stream", encoded)], name


def test_the_encoded_fillna_is_a_projection_whose_case_tests_the_value_and_the_encoded_tail_is_a_topn():
    env = Env()
    fill = encode_plan(env.df.fillna({"a": 0})._plan, env.sources).plan
    assert fill.WhichOneof("node") == "project", fill.WhichOneof("node")
    tail = encode_plan(env.df.sort_values("a").tail(2)._plan, env.sources).plan
    assert tail.WhichOneof("node") == "sort", tail.WhichOneof("node")
    assert list(tail.sort.nulls_first) == [False]
    topn = tail.sort.child
    assert topn.WhichOneof("node") == "topn", topn.WhichOneof("node")
    assert topn.topn.n == 2 and list(topn.topn.nulls_first) == [True]


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame concat counts: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
