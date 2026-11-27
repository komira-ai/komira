"""`shift`, `diff` and `pct_change` of a column of the pandas-shaped DataFrame
(komira/_windows.py, komira/_series.py) with no libkomira: a frame over a
Parquet scan whose schema is made here, on a session stand-in that records the
plan bytes it is given. Checked:

- the plan each verb builds, by equality with a hand-built node tree, assigned
  as a column of a sorted frame: `shift(n)` is LAG by n rows in the frame's sort
  order, `shift(-n)` LEAD by n, `shift(0)` the column itself; `diff(n)` the
  column less that window, cast to float64 over an int64 column and left a
  float64 over a float64 one; `pct_change(n)` the quotient less 1 under the
  CASE that gives pandas' inf, -inf and NaN over a previous value of 0;
- the output types: shift keeps int64, float64 and string; diff and
  pct_change are float64;
- the wire: the window is a partition-by node with the function LAG or LEAD,
  the row distance as its offset and the frame's sort key as its order, and
  its column is nullable;
- a window of a frame sorted descending reads that order;
- every refusal by its class and its full message: an unsorted frame, a frame
  that dropped its sort key, a type LAG and LEAD do not read, a non-numeric
  column for diff and pct_change, `periods` that is not an int, `freq`,
  `fill_value`, `suffix`, `axis=1`, `fill_method`, other keywords, and a
  Series that is an expression;
- the verbs run nothing and reach the session only as plan bytes.

    test_frame_shift.py
"""

import os
import sys
import tempfile

from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Arith, BoolOp, Cast, ColRef, Compare, Field, Lit, Project, Sort, SortKey, Unary, When
from komira._ops import WindowExpr
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, member, pb

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_shift_test_input.parquet")
FIELDS = (("a", "int64"), ("b", "int64"), ("n", "int32"), ("x", "float64"), ("s", "string"), ("ok", "bool"))
COLS = tuple(name for name, _ in FIELDS)
SCAN = _ops.scan(PATH, "parquet", tuple(Field(name, dtype) for name, dtype in FIELDS))
BY_X = (SortKey("x"),)

NOT_SORTED = (
    "{verb} runs in row order, and this frame is not sorted, so its rows have no order: "
    'sort it first, as df.sort_values("column")'
)
EXPRESSION = (
    "{verb} takes a column of the frame, and this Series is an expression: "
    'assign it as a column first, as df.assign(x=...), then take df["x"]'
)
NEEDS_NUMBER = "{verb} needs a numeric column, and the column {column!r} is {dtype}"
NOT_READ = (
    "{verb} reads the column {column!r} of type {dtype}, and the window reads int64, float64 and "
    'string columns: assign it as one of those first, as df.assign({column}=df["{column}"].astype("int64"))'
)


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
    def __init__(self):
        self.stub = Stub()
        schema = pb.WireSchema(fields=[field(n, arrow_id(t), True) for n, t in FIELDS])
        self.sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
        self.df = DataFrame._new(self.stub, SCAN, self.sources)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def w(i):
    return ColRef(f"_w{i}")


def assigned(wins, items, keys=BY_X):
    """The sorted frame with `items` assigned over the projection that keeps
    the columns and appends one column per window."""
    kept = tuple((c, ColRef(c)) for c in COLS)
    inner = Project(SCAN, kept + tuple((f"_w{i}", win) for i, win in enumerate(wins)))
    out = kept + tuple(items.items())
    return Sort(Project(inner, out), keys)


def lag(column, n, keys=BY_X):
    return WindowExpr("lag", column, offset=n, order_by=keys)


def lead(column, n, keys=BY_X):
    return WindowExpr("lead", column, offset=n, order_by=keys)


def pandas_ratio(x, before):
    """`x / before - 1`, and pandas' answer where `before` is 0."""
    zero = Lit(0.0)
    at_zero = Compare("eq", before, zero)
    inf, minus_inf = Lit(float("inf")), Lit(float("-inf"))
    not_nan = BoolOp(
        "or",
        BoolOp(
            "or",
            BoolOp("and", Compare("gt", x, minus_inf), Compare("lt", x, inf)),
            Compare("eq", x, inf),
        ),
        Compare("eq", x, minus_inf),
    )
    positive = BoolOp("and", BoolOp("and", at_zero, not_nan), Compare("gt", x, zero))
    negative = BoolOp("and", at_zero, Compare("lt", x, zero))
    other = BoolOp("and", at_zero, Unary("is_not_null", x))
    return When(
        ((positive, inf), (negative, minus_inf), (other, Lit(float("nan")))),
        Arith("sub", Arith("div", x, before), Lit(1.0)),
    )


# --- shift ----------------------------------------------------------------------------------


def test_shift_is_a_lag_window_in_the_frame_order_and_keeps_the_column_type():
    df = Env().df.sort_values("x")
    for column, dtype in (("b", "int64"), ("x", "float64"), ("s", "string")):
        for n in (1, 3):
            series = df[column].shift(n)
            got = df.assign(r=series)
            assert got._plan == assigned((lag(column, n),), {"r": w(0)}), (column, n)
            assert series.dtype == dtype and got.dtypes["r"] == dtype, (column, n)
    # periods defaults to 1.
    assert df.assign(r=df["b"].shift())._plan == assigned((lag("b", 1),), {"r": w(0)})


def test_shift_of_a_negative_period_is_a_lead_window_of_the_rows_after():
    df = Env().df.sort_values("x")
    for n in (1, 2):
        got = df.assign(r=df["b"].shift(-n))
        assert got._plan == assigned((lead("b", n),), {"r": w(0)}), n
        assert got.dtypes["r"] == "int64"


def test_shift_of_zero_is_the_column_itself():
    df = Env().df.sort_values("x")
    assert df.assign(r=df["b"].shift(0))._plan == df.assign(r=df["b"])._plan


def test_a_shift_of_a_frame_sorted_descending_reads_that_order():
    df = Env().df.sort_values(["a", "x"], ascending=[False, True])
    keys = (SortKey("a", descending=True), SortKey("x"))
    got = df.assign(r=df["b"].shift(1))
    assert got._plan == assigned((lag("b", 1, keys),), {"r": w(0)}, keys)


def partitions(plan):
    """The partition-by nodes of an encoded plan, the lowest first."""
    nodes, p = [], plan
    while True:
        kind = p.WhichOneof("node")
        if kind == "partition_by":
            nodes.append(p.partition_by)
            p = p.partition_by.child
        elif kind in ("project", "sort", "filter"):
            p = getattr(p, kind).child
        else:
            return nodes[::-1]


def test_shift_and_its_lead_reach_the_wire_as_lag_and_lead_with_the_row_distance_and_a_nullable_column():
    env = Env()
    df = env.df.sort_values("x")
    got = df.assign(back=df["b"].shift(2), ahead=df["s"].shift(-1))
    root = encode_plan(got._plan, env.sources).plan
    assert root.WhichOneof("node") == "sort"
    back, ahead = partitions(root)
    for node in (back, ahead):
        assert list(node.partition_keys) == [] and list(node.order_keys) == ["x"]
        assert list(node.descending) == [False]
    (e,) = back.partition_exprs
    assert (e.func, e.column, e.offset, e.has_default) == (member("PF_", "lag"), "b", 2, False)
    (e,) = ahead.partition_exprs
    assert (e.func, e.column, e.offset, e.has_default) == (member("PF_", "lead"), "s", 1, False)
    assert [f.name for f in root.output_schema.fields] == list(COLS) + ["back", "ahead"]
    types = {f.name: f for f in root.output_schema.fields}
    assert types["back"].arrow_type_id == arrow_id("int64") and types["back"].nullable
    assert types["ahead"].arrow_type_id == arrow_id("string") and types["ahead"].nullable


# --- diff -----------------------------------------------------------------------------------


def test_diff_of_an_int_column_subtracts_its_shift_and_answers_float64_as_pandas_does():
    df = Env().df.sort_values("x")
    for n, win in ((1, lag("b", 1)), (2, lag("b", 2)), (-1, lead("b", 1))):
        series = df["b"].diff(n)
        got = df.assign(r=series)
        assert got._plan == assigned((win,), {"r": Cast(Arith("sub", ColRef("b"), w(0)), "float64")}), n
        assert series.dtype == "float64" and got.dtypes["r"] == "float64", n
    assert df.assign(r=df["b"].diff())._plan == df.assign(r=df["b"].diff(1))._plan


def test_diff_of_a_float_column_is_a_float64_without_a_cast():
    df = Env().df.sort_values("x")
    got = df.assign(r=df["x"].diff())
    assert got._plan == assigned((lag("x", 1),), {"r": Arith("sub", ColRef("x"), w(0))})
    assert got.dtypes["r"] == "float64"


def test_diff_of_zero_rows_is_the_column_less_itself():
    df = Env().df.sort_values("x")
    got = df.assign(r=df["b"].diff(0))
    assert got._plan == _ops.with_columns(df._plan, (("r", Cast(Arith("sub", ColRef("b"), ColRef("b")), "float64")),))


# --- pct_change -----------------------------------------------------------------------------


def test_pct_change_divides_by_the_shift_less_one_with_pandas_answer_over_a_zero_previous_value():
    df = Env().df.sort_values("x")
    series = df["x"].pct_change()
    got = df.assign(r=series)
    assert got._plan == assigned((lag("x", 1),), {"r": pandas_ratio(ColRef("x"), w(0))})
    assert series.dtype == "float64" and got.dtypes["r"] == "float64"
    ints = df["b"].pct_change(-2)
    want = pandas_ratio(Cast(ColRef("b"), "float64"), Cast(w(0), "float64"))
    assert df.assign(r=ints)._plan == assigned((lead("b", 2),), {"r": want})
    assert ints.dtype == "float64"


# --- a shifted Series in an expression -------------------------------------------------------


def test_a_shift_combines_with_its_own_column_in_an_expression():
    df = Env().df.sort_values("x")
    got = df.assign(r=df["x"] - df["x"].shift(1))
    assert got._plan == assigned((lag("x", 1),), {"r": Arith("sub", ColRef("x"), w(0))})
    assert got._plan == df.assign(r=df["x"].diff())._plan


# --- refusals -------------------------------------------------------------------------------


def test_shift_diff_and_pct_change_of_an_unsorted_frame_are_refused_by_name():
    df = Env().df
    for verb, call in (
        ("shift(1)", lambda: df["b"].shift(1)),
        ("shift(-2)", lambda: df["b"].shift(-2)),
        ("shift(0)", lambda: df["b"].shift(0)),
        ("diff(1)", lambda: df["b"].diff()),
        ("pct_change(3)", lambda: df["x"].pct_change(3)),
    ):
        refuses(call, UnsupportedOperation, NOT_SORTED.format(verb=verb))
    dropped = df.sort_values("x")[["a", "b"]]
    refuses(lambda: dropped["b"].shift(), UnsupportedOperation, NOT_SORTED.format(verb="shift(1)"))


def test_a_column_type_lag_does_not_read_is_refused_with_the_cast_to_assign():
    df = Env().df.sort_values("x")
    refuses(lambda: df["n"].shift(), UnsupportedOperation,
            NOT_READ.format(verb="shift(1)", column="n", dtype="int32"))
    refuses(lambda: df["ok"].shift(2), UnsupportedOperation,
            NOT_READ.format(verb="shift(2)", column="ok", dtype="bool"))
    refuses(lambda: df["n"].diff(), UnsupportedOperation,
            NOT_READ.format(verb="diff(1)", column="n", dtype="int32"))
    refuses(lambda: df["n"].pct_change(), UnsupportedOperation,
            NOT_READ.format(verb="pct_change(1)", column="n", dtype="int32"))


def test_diff_and_pct_change_of_a_column_that_is_not_a_number_are_refused():
    df = Env().df.sort_values("x")
    refuses(lambda: df["s"].diff(), UnsupportedOperation,
            NEEDS_NUMBER.format(verb="diff(1)", column="s", dtype="string"))
    refuses(lambda: df["ok"].pct_change(), UnsupportedOperation,
            NEEDS_NUMBER.format(verb="pct_change(1)", column="ok", dtype="bool"))


def test_periods_that_is_not_an_int_is_a_type_error():
    df = Env().df.sort_values("x")
    for verb in ("shift", "diff", "pct_change"):
        for bad, name in (("1", "str"), (1.0, "float"), (True, "bool"), (None, "NoneType")):
            refuses(lambda: getattr(df["b"], verb)(bad), TypeError,
                    f"{verb}() periods must be an int, the number of rows, not a {name}")


def test_the_arguments_pandas_has_and_komira_does_not_build_are_refused_by_name():
    df = Env().df.sort_values("x")
    s = df["b"]
    refuses(lambda: s.shift(1, freq="D"), UnsupportedOperation,
            "shift(freq='D') moves a time index, which komira frames do not have: leave freq=None")
    refuses(lambda: s.shift(1, fill_value=0), UnsupportedOperation,
            "shift(fill_value=0) is not supported: a row with no row to read is missing, "
            "leave fill_value at its default")
    refuses(lambda: s.shift(1, suffix="_p"), UnsupportedOperation,
            "shift(suffix='_p') names the columns of a frame shifted by several periods; "
            "a Series shifts once: leave suffix=None")
    refuses(lambda: s.shift(1, axis=1), UnsupportedOperation,
            "shift(axis=1) runs along a row, and a Series has one column: use axis=0")
    refuses(lambda: s.pct_change(fill_method="pad"), UnsupportedOperation,
            "pct_change(fill_method='pad') fills missing values from a neighbouring row first, "
            "which this release does not build: leave fill_method=None")
    refuses(lambda: s.pct_change(freq="D"), UnsupportedOperation,
            "pct_change(freq='D') moves a time index, which komira frames do not have: leave freq=None")
    refuses(lambda: s.pct_change(limit=1), UnsupportedOperation,
            "pct_change(limit=...) is not supported: pct_change takes periods alone")
    # The defaults are accepted.
    assert s.shift(1, freq=None, axis=0, fill_value=None, suffix=None).dtype == "int64"
    assert s.shift(1, axis="index").dtype == "int64"
    assert s.pct_change(1, fill_method=None, freq=None).dtype == "float64"


def test_a_series_that_is_an_expression_is_refused():
    df = Env().df.sort_values("x")
    for verb in ("shift", "diff", "pct_change"):
        refuses(lambda: getattr(df["b"] + 1, verb)(), UnsupportedOperation, EXPRESSION.format(verb=f"{verb}()"))
        refuses(lambda: getattr(df["b"].shift(), verb)(), UnsupportedOperation, EXPRESSION.format(verb=f"{verb}()"))


def test_the_frame_verbs_are_refused_with_the_column_form():
    df = Env().df.sort_values("x")
    for name in ("shift", "diff", "pct_change"):
        e = raised(lambda: getattr(df, name))
        assert type(e) is AttributeError and e.name == name
        assert e.args[0] == (
            f'DataFrame.{name}() of every column is not supported yet: take one column, as df["column"].{name}()'
        )


def test_the_verbs_run_nothing_and_reach_the_session_only_as_plan_bytes():
    env = Env()
    df = env.df.sort_values("x")
    got = df.assign(p=df["b"].shift(), d=df["b"].diff(), c=df["x"].pct_change())
    assert env.stub.calls == []
    got.materialize()
    assert env.stub.calls == [("plan_stream", encode_plan(got._plan, env.sources).SerializeToString())]


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame shift: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
