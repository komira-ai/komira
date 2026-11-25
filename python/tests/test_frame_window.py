"""The window verbs of the pandas-shaped DataFrame (komira/_windows.py,
komira/_series.py, komira/_groupby.py, komira/_frame.py) with no libkomira: a
frame over a Parquet scan whose schema is made here, on a session stand-in that
records the plan bytes it is given. Checked:

- the plan each verb builds, by equality with a hand-built node tree, each
  assigned as a column: `groupby(keys)[c].transform(func)` for sum (the CASE
  that makes an empty sum 0), mean, min, max and count, with the mask of a
  missing key under dropna=True only and with two keys; cumsum, cummin and
  cummax over a sorted frame (the frame's sort keys as the window's order, rows
  from the first to the current, a missing value kept missing), ungrouped and
  grouped; rank (rank and dense_rank, ascending or not, na_option keep or
  bottom), ungrouped and grouped; rolling sums, means, minima and maxima (the
  frame of the n - 1 rows before, the second window that counts the values when
  min_periods is more than 1);
- where the window projection sits: under the sort of a sorted frame, below a
  sort added over a limit, above the sort when the assign replaces a sort key;
  descending and several sort keys reaching the window's order;
- a Series that reads windows: in an expression, two different windows in one
  assign, one window read twice (computed once, also from two GroupBys), a
  window in a filter (over an unsorted, a sorted and a limited frame), the
  name of the window column when the frame has `_w0`, `df["x"] = ...` equal to
  assign, and a function that returns a window of the frame in assign();
- the output types of each verb;
- the wire: an assigned window is a partition-by node under the projection
  (its keys, order, function, argument, frame and alias), and the window
  columns never reach the frame's columns or output schema;
- Series of one frame only: the frame groupby() was called on, not its copy;
- every refusal by its class and its full message;
- the verbs run nothing and reach the session only as plan bytes.

    test_frame_window.py
"""

import os
import sys
import tempfile

from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Arith, BoolOp, Cast, ColRef, Compare, Field, Filter, Frame, Lit, Project, Sort, SortKey
from komira._ops import Unary, When, WindowExpr
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, member, pb
from komira._windows import Rolling

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_window_test_input.parquet")
FIELDS = (("a", "int64"), ("b", "int64"), ("n", "int32"), ("x", "float64"), ("s", "string"), ("ok", "bool"))
COLS = tuple(name for name, _ in FIELDS)
SCAN = _ops.scan(PATH, "parquet", tuple(Field(name, dtype) for name, dtype in FIELDS))

RUNNING = Frame("rows", "unbounded_preceding", "current_row")
BY_X = (SortKey("x"),)
OTHER_FRAME = (
    "this Series belongs to another frame, and a komira frame has no index to align two frames by: "
    'take the column from the frame you use it with, or pass a function, as in assign(name=lambda d: d["column"])'
)
STALE = (
    'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
    "take it from the frame again"
)
STALE_GROUPBY = (
    'this GroupBy was made before df["name"] = ... replaced the frame\'s columns: group the frame again'
)
TRANSFORMS = "count, max, mean, min, sum"
NOT_SORTED = (
    "{verb} runs in row order, and this frame is not sorted, so its rows have no order: "
    'sort it first, as df.sort_values("column")'
)
NULLS_FIRST = (
    "{verb} runs in the frame's sort order, which puts the missing values of {column!r} first, "
    'and a window orders them last: sort with na_position="last"'
)
EXPRESSION = (
    "{verb} takes a column of the frame, and this Series is an expression: "
    'assign it as a column first, as df.assign(x=...), then take df["x"]'
)
NEEDS_NUMBER = "{verb} needs a numeric column, and the column {column!r} is {dtype}"
ONE_COLUMN = (
    '{verb} of a GroupBy gives one value per row, as a Series of one column: '
    'select the column first, as df.groupby(...)["column"].{verb}'
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
    def __init__(self, fields=FIELDS):
        self.stub = Stub()
        schema = pb.WireSchema(fields=[field(n, arrow_id(t), True) for n, t in fields])
        self.sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
        self.scan = _ops.scan(PATH, "parquet", tuple(Field(n, t) for n, t in fields))
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


# --- the trees the verbs build ---------------------------------------------------------


def not_null(*columns):
    return _ops.and_all(tuple(Unary("is_not_null", ColRef(c)) for c in columns))


def missing(column, node, null=Lit(None)):
    """`node`, missing where `column` is."""
    return When(((not_null(column), node),), null)


def null_of(dtype):
    """The NULL a CASE of the type `dtype` ends in."""
    if dtype in ("int64", "float64"):
        return Lit(None)
    return Cast(Lit(None), None, arrow=dtype)


def w(i):
    return ColRef(f"_w{i}")


def with_windows(child, wins, cols=COLS, names=None):
    """The projection that keeps the columns and appends one column per window."""
    names = names or [f"_w{i}" for i in range(len(wins))]
    kept = tuple((c, ColRef(c)) for c in cols)
    return Project(child, kept + tuple(zip(names, wins)))


def assigned(child, wins, items, cols=COLS, names=None):
    """The projection of the frame's columns and the assigned ones over the
    window projection."""
    inner = with_windows(child, wins, cols, names)
    out = [(c, items.get(c, ColRef(c))) for c in cols]
    out.extend((name, node) for name, node in items.items() if name not in cols)
    return Project(inner, tuple(out))


def filtered(child, wins, predicate, cols=COLS, names=None, keep="_keep"):
    """The rows where the predicate holds: the predicate projected as the
    int64 column `keep` (1 where it holds, else 0) over the window projection,
    the filter `keep = 1`, and the frame's columns."""
    kept = tuple((c, ColRef(c)) for c in cols)
    flag = When(((predicate, Lit(1)),), Lit(0))
    tested = Project(with_windows(child, wins, cols, names), kept + ((keep, flag),))
    return Project(Filter(tested, Compare("eq", ColRef(keep), Lit(1))), kept)


def running(how, column, keys, partition=()):
    return WindowExpr(how, column, partition_by=partition, order_by=keys, frame=RUNNING)


def trailing(func, column, keys, n):
    rows = Frame("rows", "current_row", "current_row") if n == 1 else Frame("rows", "preceding", "current_row", start_offset=n - 1)
    return WindowExpr(func, column, order_by=keys, frame=rows)


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


# --- transform ----------------------------------------------------------------------------


def test_transform_is_a_partition_window_under_a_missing_key_mask_and_an_empty_sum_is_zero():
    cases = [
        # func, column, window function, the type of the answer
        ("sum", "b", "sum", "int64"),
        ("sum", "x", "sum", "float64"),
        ("mean", "b", "avg", "float64"),
        ("min", "b", "min", "int64"),
        ("min", "n", "min", "int32"),
        ("max", "x", "max", "float64"),
        ("max", "s", "max", "string"),
        ("count", "s", "count", "int64"),
    ]
    for func, column, win, dtype in cases:
        df = Env().df
        series = df.groupby("a")[column].transform(func)
        value = w(0)
        if func == "sum":
            value = When(((Unary("is_not_null", w(0)), w(0)),), Lit(0))
        want = assigned(
            SCAN, (WindowExpr(win, column, partition_by=("a",)),), {"t": missing("a", value, null_of(dtype))}
        )
        got = df.assign(t=series)
        assert got._plan == want, (func, column, got._plan)
        assert series.dtype == dtype and got.dtypes["t"] == dtype, (func, column)
        assert got.columns == list(COLS) + ["t"]
        df["t"] = series
        assert df._plan == want


def test_transform_under_dropna_false_has_no_key_mask_and_two_keys_mask_both():
    df = Env().df
    win = WindowExpr("avg", "x", partition_by=("a",))
    assert df.assign(m=df.groupby("a", dropna=False)["x"].transform("mean"))._plan == assigned(SCAN, (win,), {"m": w(0)})
    total = When(((Unary("is_not_null", w(0)), w(0)),), Lit(0))
    both = df.assign(t=df.groupby("a", dropna=False)["b"].transform("sum"))
    assert both._plan == assigned(SCAN, (WindowExpr("sum", "b", partition_by=("a",)),), {"t": total})
    two = df.assign(m=df.groupby(["a", "s"])["x"].transform("mean"))
    assert two._plan == assigned(
        SCAN, (WindowExpr("avg", "x", partition_by=("a", "s")),), {"m": When(((not_null("a", "s"), w(0)),), Lit(None))}
    )
    # as_index and sort of the groupby change nothing about the windows.
    plain = df.assign(m=df.groupby("a")["x"].transform("mean"))._plan
    assert df.assign(m=df.groupby("a", sort=False, as_index=False)["x"].transform("mean"))._plan == plain


def test_a_transform_replaces_an_existing_column_in_place_and_keeps_literals_in_keyword_order():
    df = Env().df
    win = WindowExpr("avg", "x", partition_by=("a",))
    got = df.assign(x=df.groupby("a")["x"].transform("mean"), one=1)
    assert got._plan == assigned(SCAN, (win,), {"x": missing("a", w(0)), "one": Lit(1)})
    assert got.columns == list(COLS) + ["one"]
    assert got.dtypes["x"] == "float64"


def test_transform_on_a_sorted_frame_goes_under_the_sort_and_the_frame_stays_sorted():
    df = Env().df.sort_values("b")
    win = WindowExpr("max", "x", partition_by=("a",))
    got = df.assign(m=df.groupby("a")["x"].transform("max"))
    assert got._plan == Sort(assigned(SCAN, (win,), {"m": missing("a", w(0))}), (SortKey("b"),))
    # Assigning over the sort key keeps the sort's rows below it: nothing is sorted any more.
    over = df.assign(b=df.groupby("a")["x"].transform("max"))
    assert over._plan == assigned(Sort(SCAN, (SortKey("b"),)), (win,), {"b": missing("a", w(0))})
    assert over._order() is None


# --- running windows -------------------------------------------------------------------


def test_cumsum_cummin_and_cummax_run_in_the_frames_sort_order_and_keep_missing_values_missing():
    cases = [
        ("sum", "b", "int64"),
        ("sum", "x", "float64"),
        ("sum", "n", "int64"),
        ("min", "x", "float64"),
        ("max", "b", "int64"),
        ("min", "s", "string"),
        ("max", "n", "int32"),
    ]
    for how, column, dtype in cases:
        df = Env().df.sort_values("x")
        series = getattr(df[column], f"cum{how}")()
        node = missing(column, w(0), null_of(dtype))
        want = Sort(assigned(SCAN, (running(how, column, BY_X),), {"c": node}), BY_X)
        got = df.assign(c=series)
        assert got._plan == want, (how, column, got._plan)
        assert series.dtype == dtype and got.dtypes["c"] == dtype, (how, column)
        assert got._order() == BY_X
        df["c"] = series
        assert df._plan == want
    # axis=None, 0 and "index" and skipna=True are the defaults.
    df = Env().df.sort_values("x")
    plain = df.assign(c=df["b"].cumsum())._plan
    for kwargs in ({"axis": None}, {"axis": 0}, {"axis": "index"}, {"skipna": True}):
        assert df.assign(c=df["b"].cumsum(**kwargs))._plan == plain, kwargs


def test_the_window_order_is_the_sort_keys_of_the_frame_with_their_directions_and_every_key():
    df = Env().df.sort_values("x", ascending=False)
    keys = (SortKey("x", descending=True),)
    got = df.assign(c=df["b"].cumsum())
    assert got._plan == Sort(assigned(SCAN, (running("sum", "b", keys),), {"c": missing("b", w(0))}), keys)
    df = Env().df.sort_values(["a", "x"], ascending=[True, False])
    keys = (SortKey("a"), SortKey("x", descending=True))
    got = df.assign(c=df["b"].cummax())
    assert got._plan == Sort(assigned(SCAN, (running("max", "b", keys),), {"c": missing("b", w(0))}), keys)


def test_a_running_window_over_a_limit_of_a_sort_adds_the_sort_above_and_over_a_replaced_key_none():
    df = Env().df.sort_values("x").head(3)
    limit = _ops.limit(Sort(SCAN, BY_X), 3)
    assert df._plan == limit
    got = df.assign(c=df["b"].cumsum())
    assert got._plan == Sort(assigned(limit, (running("sum", "b", BY_X),), {"c": missing("b", w(0))}), BY_X)
    assert got._order() == BY_X
    # An assign that replaces a sort key leaves the frame unordered.
    sorted_frame = Env().df.sort_values("x")
    over = sorted_frame.assign(x=sorted_frame["b"].cumsum())
    assert over._plan == assigned(
        Sort(SCAN, BY_X), (running("sum", "b", BY_X),), {"x": missing("b", w(0))}
    )
    assert over._order() is None


def test_a_grouped_running_window_partitions_by_the_keys_and_masks_a_missing_key():
    df = Env().df.sort_values("x")
    for how, column, dtype in (("sum", "b", "int64"), ("min", "x", "float64"), ("max", "s", "string")):
        series = getattr(df.groupby("a")[column], f"cum{how}")()
        win = running(how, column, BY_X, ("a",))
        node = missing("a", missing(column, w(0), null_of(dtype)), null_of(dtype))
        want = Sort(assigned(SCAN, (win,), {"c": node}), BY_X)
        assert df.assign(c=series)._plan == want, (how, column)
        assert series.dtype == dtype
    kept = df.groupby("a", dropna=False)["b"].cumsum()
    assert df.assign(c=kept)._plan == Sort(
        assigned(SCAN, (running("sum", "b", BY_X, ("a",)),), {"c": missing("b", w(0))}), BY_X
    )
    two = df.groupby(["a", "s"])["b"].cummin()
    node = When(((not_null("a", "s"), missing("b", w(0))),), Lit(None))
    assert df.assign(c=two)._plan == Sort(assigned(SCAN, (running("min", "b", BY_X, ("a", "s")),), {"c": node}), BY_X)


# --- rank --------------------------------------------------------------------------------


def test_rank_orders_by_the_column_as_float64_and_keep_masks_a_missing_value():
    for method, func in (("min", "rank"), ("dense", "dense_rank")):
        for ascending in (True, False):
            keys = (SortKey("b", descending=not ascending),)
            win = WindowExpr(func, None, order_by=keys)
            df = Env().df
            kept = df["b"].rank(method=method, ascending=ascending)
            assert df.assign(r=kept)._plan == assigned(
                SCAN, (win,), {"r": missing("b", Cast(w(0), "float64"))}
            ), (method, ascending)
            assert kept.dtype == "float64"
            bottom = df["b"].rank(method=method, ascending=ascending, na_option="bottom")
            assert df.assign(r=bottom)._plan == assigned(SCAN, (win,), {"r": Cast(w(0), "float64")})
    df = Env().df
    text = df["s"].rank(method="min")
    assert df.assign(r=text)._plan == assigned(
        SCAN, (WindowExpr("rank", None, order_by=(SortKey("s"),)),), {"r": missing("s", Cast(w(0), "float64"))}
    )
    assert text.dtype == "float64"
    # axis=0 and "index" are the defaults; a sorted frame needs no order for it.
    sorted_frame = df.sort_values("x")
    got = sorted_frame.assign(r=sorted_frame["b"].rank(axis="index", method="min", pct=False))
    assert got._plan == Sort(
        assigned(
            SCAN,
            (WindowExpr("rank", None, order_by=(SortKey("b"),)),),
            {"r": missing("b", Cast(w(0), "float64"))},
        ),
        BY_X,
    )


def test_a_grouped_rank_partitions_by_the_keys_and_masks_a_missing_key_outside_the_value_mask():
    df = Env().df
    for method, func in (("min", "rank"), ("dense", "dense_rank")):
        series = df.groupby("a")["b"].rank(method=method, ascending=False)
        win = WindowExpr(func, None, partition_by=("a",), order_by=(SortKey("b", descending=True),))
        node = missing("a", missing("b", Cast(w(0), "float64")))
        assert df.assign(r=series)._plan == assigned(SCAN, (win,), {"r": node}), method
        assert series.dtype == "float64"
    bottom = df.groupby(["a", "s"], dropna=False)["x"].rank(method="min", na_option="bottom")
    win = WindowExpr("rank", None, partition_by=("a", "s"), order_by=(SortKey("x"),))
    assert df.assign(r=bottom)._plan == assigned(SCAN, (win,), {"r": Cast(w(0), "float64")})


# --- rolling -------------------------------------------------------------------------------


def test_rolling_is_the_window_of_the_row_and_the_ones_before_it_with_a_count_window_for_min_periods():
    df = Env().df.sort_values("x")
    funcs = (("sum", "sum"), ("mean", "avg"), ("min", "min"), ("max", "max"))
    for how, func in funcs:
        # min_periods defaults to the window: a second window counts the values.
        series = getattr(df["b"].rolling(3), how)()
        node = When(((Compare("ge", w(1), Lit(3)), Cast(w(0), "float64")),), Lit(None))
        wins = (trailing(func, "b", BY_X, 3), trailing("count", "b", BY_X, 3))
        got = df.assign(r=series)
        assert got._plan == Sort(assigned(SCAN, wins, {"r": node}), BY_X), how
        assert series.dtype == "float64" and got.dtypes["r"] == "float64"
        # Whatever min_periods is, a min_periods of 1 needs no count.
        one = getattr(df["b"].rolling(3, min_periods=1), how)()
        assert df.assign(r=one)._plan == Sort(
            assigned(SCAN, (trailing(func, "b", BY_X, 3),), {"r": Cast(w(0), "float64")}), BY_X
        ), how
    some = df["n"].rolling(5, min_periods=2).sum()
    node = When(((Compare("ge", w(1), Lit(2)), Cast(w(0), "float64")),), Lit(None))
    assert df.assign(r=some)._plan == Sort(
        assigned(SCAN, (trailing("sum", "n", BY_X, 5), trailing("count", "n", BY_X, 5)), {"r": node}), BY_X
    )
    assert some.dtype == "float64"
    full = df["x"].rolling(4, min_periods=4).max()
    node = When(((Compare("ge", w(1), Lit(4)), Cast(w(0), "float64")),), Lit(None))
    assert df.assign(r=full)._plan == Sort(
        assigned(SCAN, (trailing("max", "x", BY_X, 4), trailing("count", "x", BY_X, 4)), {"r": node}), BY_X
    )


def test_a_rolling_window_of_one_row_is_the_current_row_and_needs_no_count():
    df = Env().df.sort_values("x")
    for kwargs in ({}, {"min_periods": 1}):
        got = df.assign(r=df["b"].rolling(1, **kwargs).mean())
        assert got._plan == Sort(
            assigned(SCAN, (trailing("avg", "b", BY_X, 1),), {"r": Cast(w(0), "float64")}), BY_X
        ), kwargs
    assert trailing("avg", "b", BY_X, 1).frame == Frame("rows", "current_row", "current_row")
    two = df.assign(r=df["b"].rolling(2).sum())
    assert two._plan == Sort(
        assigned(
            SCAN,
            (trailing("sum", "b", BY_X, 2), trailing("count", "b", BY_X, 2)),
            {"r": When(((Compare("ge", w(1), Lit(2)), Cast(w(0), "float64")),), Lit(None))},
        ),
        BY_X,
    )
    assert trailing("sum", "b", BY_X, 2).frame == Frame("rows", "preceding", "current_row", start_offset=1)


def test_rolling_follows_the_sort_directions_and_a_limit_and_two_rollings_share_their_count():
    df = Env().df.sort_values(["a", "x"], ascending=[False, True])
    keys = (SortKey("a", descending=True), SortKey("x"))
    got = df.assign(m=df["b"].rolling(3).mean(), t=df["b"].rolling(3).sum())
    wins = (trailing("avg", "b", keys, 3), trailing("count", "b", keys, 3), trailing("sum", "b", keys, 3))
    ge = Compare("ge", w(1), Lit(3))
    items = {
        "m": When(((ge, Cast(w(0), "float64")),), Lit(None)),
        "t": When(((ge, Cast(w(2), "float64")),), Lit(None)),
    }
    assert got._plan == Sort(assigned(SCAN, wins, items), keys)
    limited = Env().df.sort_values("x").head(4)
    got = limited.assign(r=limited["b"].rolling(2, min_periods=1).min())
    assert got._plan == Sort(
        assigned(limited._plan, (trailing("min", "b", BY_X, 2),), {"r": Cast(w(0), "float64")}), BY_X
    )


# --- a Series that reads windows -----------------------------------------------------------


def test_a_window_combines_with_columns_in_an_expression_and_is_computed_once_per_distinct_window():
    df = Env().df
    gb = df.groupby("a")
    mean = missing("a", w(0))
    centred = df["x"] - gb["x"].transform("mean")
    assert df.assign(d=centred)._plan == assigned(
        SCAN, (WindowExpr("avg", "x", partition_by=("a",)),), {"d": Arith("sub", ColRef("x"), mean)}
    )
    assert centred.dtype == "float64"
    # Two different windows, one assign: _w0 and _w1 in the order they first appear.
    both = df.assign(m=gb["x"].transform("mean"), hi=gb["x"].transform("max"))
    assert both._plan == assigned(
        SCAN,
        (WindowExpr("avg", "x", partition_by=("a",)), WindowExpr("max", "x", partition_by=("a",))),
        {"m": missing("a", w(0)), "hi": missing("a", w(1))},
    )
    # The same window read twice, also through another GroupBy of the same frame, is one window.
    m = gb["x"].transform("mean")
    twice = df.assign(p=m, q=m + m, r=df.groupby("a")["x"].transform("mean"))
    assert twice._plan == assigned(
        SCAN,
        (WindowExpr("avg", "x", partition_by=("a",)),),
        {"p": mean, "q": Arith("add", mean, mean), "r": mean},
    )
    # A window read by both sides of a division is one window.
    ratio = gb["x"].transform("max") / gb["x"].transform("max")
    assert df.assign(q=ratio)._plan == assigned(
        SCAN, (WindowExpr("max", "x", partition_by=("a",)),), {"q": Arith("div", missing("a", w(0)), missing("a", w(0)))}
    )


def test_a_window_in_a_filter_is_a_projection_a_filter_and_a_projection_back_to_the_columns():
    df = Env().df
    gb = df.groupby("a")
    win = WindowExpr("avg", "x", partition_by=("a",))
    above = df["x"] > gb["x"].transform("mean")
    predicate = Compare("gt", ColRef("x"), missing("a", w(0)))
    got = df[above]
    assert got._plan == filtered(SCAN, (win,), predicate)
    assert got.columns == list(COLS)
    assert df[lambda f: f["x"] > f.groupby("a")["x"].transform("mean")]._plan == got._plan
    both = df[(df["b"] > 1) & above]
    assert both._plan == filtered(SCAN, (win,), BoolOp("and", Compare("gt", ColRef("b"), Lit(1)), predicate))
    either = df[above | (df["b"] > 1)]
    assert either._plan == filtered(SCAN, (win,), BoolOp("or", predicate, Compare("gt", ColRef("b"), Lit(1))))
    negated = df[~above]
    assert negated._plan == filtered(SCAN, (win,), Unary("not", predicate))
    top = df[gb["b"].transform("max") == df["b"]]
    assert top._plan == filtered(
        SCAN,
        (WindowExpr("max", "b", partition_by=("a",)),),
        Compare("eq", missing("a", w(0)), ColRef("b")),
    )


def test_a_window_filter_goes_under_the_sort_of_a_sorted_frame_and_a_sort_is_added_over_a_limit():
    df = Env().df.sort_values("b")
    win = WindowExpr("avg", "x", partition_by=("a",))
    predicate = Compare("gt", ColRef("x"), missing("a", w(0)))
    got = df[df["x"] > df.groupby("a")["x"].transform("mean")]
    assert got._plan == Sort(filtered(SCAN, (win,), predicate), (SortKey("b"),))
    assert got._order() == (SortKey("b"),)
    limited = df.head(5)
    got = limited[limited["x"] > limited.groupby("a")["x"].transform("mean")]
    assert got._plan == Sort(filtered(limited._plan, (win,), predicate), (SortKey("b"),))
    # A filter by a running window of a sorted frame reads the same order.
    ordered = Env().df.sort_values("x")
    got = ordered[ordered["b"].cumsum() > 10]
    assert got._plan == Sort(
        filtered(SCAN, (running("sum", "b", BY_X),), Compare("gt", missing("b", w(0)), Lit(10))), BY_X
    )


def test_the_window_column_takes_an_underscore_more_until_the_frame_has_no_column_of_its_name():
    env = Env((("k", "int64"), ("v", "float64"), ("_w0", "float64")))
    df = env.df
    cols = ("k", "v", "_w0")
    both = df.assign(m=df.groupby("k")["v"].transform("mean"), hi=df.groupby("k")["v"].transform("max"))
    wins = (WindowExpr("avg", "v", partition_by=("k",)), WindowExpr("max", "v", partition_by=("k",)))
    assert both._plan == assigned(
        env.scan,
        wins,
        {"m": missing("k", ColRef("__w0")), "hi": missing("k", ColRef("_w1"))},
        cols=cols,
        names=["__w0", "_w1"],
    )
    assert both.columns == ["k", "v", "_w0", "m", "hi"]
    over = df[df["v"] > df.groupby("k")["v"].transform("mean")]
    assert over._plan == filtered(
        env.scan,
        wins[:1],
        Compare("gt", ColRef("v"), missing("k", ColRef("__w0"))),
        cols=cols,
        names=["__w0"],
    )
    twice = Env((("k", "int64"), ("v", "float64"), ("_w0", "float64"), ("__w0", "float64")))
    got = twice.df.assign(m=twice.df.groupby("k")["v"].transform("mean"))
    assert got._plan == assigned(
        twice.scan,
        wins[:1],
        {"m": missing("k", ColRef("___w0"))},
        cols=("k", "v", "_w0", "__w0"),
        names=["___w0"],
    )
    # A window column that is assigned over the frame's own `_w0` replaces it.
    again = df.assign(_w0=df.groupby("k")["v"].transform("mean"))
    assert again._plan == assigned(
        env.scan, wins[:1], {"_w0": missing("k", ColRef("__w0"))}, cols=cols, names=["__w0"]
    )


def test_the_predicate_column_of_a_window_filter_takes_an_underscore_more_until_no_column_has_its_name():
    env = Env((("k", "int64"), ("v", "float64"), ("_keep", "bool")))
    df = env.df
    cols = ("k", "v", "_keep")
    win = WindowExpr("avg", "v", partition_by=("k",))
    got = df[df["v"] > df.groupby("k")["v"].transform("mean")]
    predicate = Compare("gt", ColRef("v"), missing("k", ColRef("_w0")))
    assert got._plan == filtered(env.scan, (win,), predicate, cols=cols, keep="__keep")
    assert got.columns == list(cols)


def test_setting_a_column_to_a_window_series_is_assign_and_a_function_of_the_frame_may_return_one():
    df = Env().df
    series = df.groupby("a")["b"].transform("sum")
    want = df.assign(t=series)._plan
    df["t"] = series
    assert df._plan == want
    fresh = Env().df
    by_function = fresh.assign(t=lambda f: f.groupby("a")["b"].transform("sum"))
    assert by_function._plan == want
    # A later keyword's function reads the columns the earlier keywords made.
    chained = fresh.assign(one=1, t=lambda f: f["one"] + 1)
    assert chained.columns == list(COLS) + ["one", "t"]
    # The first keyword's function gets the frame itself, so a window of it is a window of the frame.
    sorted_frame = Env().df.sort_values("x")
    got = sorted_frame.assign(c=lambda f: f["b"].cumsum())
    assert got._plan == Sort(assigned(SCAN, (running("sum", "b", BY_X),), {"c": missing("b", w(0))}), BY_X)


def test_a_condition_that_reads_a_window_must_still_be_boolean():
    df = Env().df
    refuses(lambda: df[df.groupby("a")["b"].transform("sum")], TypeError,
            "a condition must be a boolean Series, and this one is int64")


# --- the wire --------------------------------------------------------------------------------


def test_an_assigned_window_is_a_partition_by_node_under_the_projection_and_its_column_never_leaks():
    env = Env()
    df = env.df.sort_values("x")
    df["r"] = df.groupby("a")["b"].cumsum()
    root = encode_plan(df._plan, env.sources).plan
    assert root.WhichOneof("node") == "sort"
    (node,) = partitions(root)
    assert list(node.partition_keys) == ["a"]
    assert list(node.order_keys) == ["x"] and list(node.descending) == [False]
    (expr,) = node.partition_exprs
    assert (expr.func, expr.column, expr.alias_name) == (member("PF_", "sum"), "b", "_w0")
    assert expr.frame == pb.WireFrame(
        units=member("FRAME_UNITS_", "rows"),
        start_tag=member("FRAME_BOUND_", "unbounded_preceding"),
        end_tag=member("FRAME_BOUND_", "current_row"),
    )
    assert [f.name for f in root.output_schema.fields] == list(COLS) + ["r"]
    assert df.columns == list(COLS) + ["r"] and "_w0" not in df.dtypes
    assert root.output_schema.fields[-1].arrow_type_id == arrow_id("int64")


def test_stacked_windows_are_one_partition_by_node_each_in_order_and_a_rolling_frame_reaches_the_wire():
    env = Env()
    df = env.df
    got = df.assign(m=df.groupby("a")["x"].transform("mean"), hi=df.groupby("a")["x"].transform("max"))
    root = encode_plan(got._plan, env.sources).plan
    nodes = partitions(root)
    assert [e.alias_name for n in nodes for e in n.partition_exprs] == ["_w0", "_w1"]
    assert [e.func for n in nodes for e in n.partition_exprs] == [member("PF_", "avg"), member("PF_", "max")]
    assert [list(n.partition_keys) for n in nodes] == [["a"], ["a"]]
    assert [f.name for f in root.output_schema.fields] == list(COLS) + ["m", "hi"]
    assert [f.arrow_type_id for f in root.output_schema.fields][-2:] == [arrow_id("float64")] * 2
    ordered = df.sort_values("x")
    rolled = ordered.assign(r=ordered["b"].rolling(3).sum())
    nodes = partitions(encode_plan(rolled._plan, env.sources).plan)
    assert [e.func for n in nodes for e in n.partition_exprs] == [member("PF_", "sum"), member("PF_", "count")]
    for n in nodes:
        assert list(n.partition_keys) == [] and list(n.order_keys) == ["x"]
        assert n.partition_exprs[0].frame == pb.WireFrame(
            units=member("FRAME_UNITS_", "rows"),
            start_tag=member("FRAME_BOUND_", "preceding"),
            start_offset=2,
            end_tag=member("FRAME_BOUND_", "current_row"),
        )
    ranked = df.assign(r=df["b"].rank(method="dense", ascending=False))
    (node,) = partitions(encode_plan(ranked._plan, env.sources).plan)
    assert list(node.order_keys) == ["b"] and list(node.descending) == [True]
    assert node.partition_exprs[0].func == member("PF_", "dense_rank")
    assert node.partition_exprs[0].column == ""


def test_a_window_frame_reaches_the_session_only_as_plan_bytes_at_its_terminal():
    env = Env()
    df = env.df
    gb = df.groupby("a")
    frames = [
        df.assign(t=gb["b"].transform("sum")),
        df[df["x"] > gb["x"].transform("mean")],
        df.sort_values("x").assign(r=lambda f: f["b"].rolling(2).sum()),
        df.assign(r=df["b"].rank(method="min")),
    ]
    assert env.stub.calls == []
    for frame in frames:
        frame.materialize()
    assert env.stub.calls == [
        ("plan_stream", encode_plan(frame._plan, env.sources).SerializeToString()) for frame in frames
    ]


# --- a window Series is of the frame groupby() was called on ----------------------------------


def test_a_window_series_is_of_the_frame_groupby_was_called_on_and_not_of_its_copy():
    df = Env().df
    series = df.groupby("a")["b"].transform("sum")
    assert df.assign(t=series)._plan == assigned(
        SCAN,
        (WindowExpr("sum", "b", partition_by=("a",)),),
        {"t": missing("a", When(((Unary("is_not_null", w(0)), w(0)),), Lit(0)))},
    )
    other = df.copy()
    refuses(lambda: other.assign(t=series), UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: other[series > 1], UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: df.sort_values("x").assign(t=series), UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: other.__setitem__("t", series), UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: other["b"] + series, UnsupportedOperation, OTHER_FRAME)
    # A running window is of the sorted frame the groupby was made on.
    ordered = df.sort_values("x")
    running_sum = ordered.groupby("a")["b"].cumsum()
    assert ordered.assign(c=running_sum)._plan.keys == BY_X
    refuses(lambda: ordered.copy().assign(c=running_sum), UnsupportedOperation, OTHER_FRAME)


# --- refusals -------------------------------------------------------------------------------------


def test_a_running_or_rolling_verb_of_an_unsorted_frame_is_refused_at_the_verb():
    df = Env().df
    for how in ("sum", "min", "max"):
        verb = f"cum{how}()"
        refuses(lambda: getattr(df["b"], f"cum{how}")(), UnsupportedOperation, NOT_SORTED.format(verb=verb))
        refuses(lambda: getattr(df.groupby("a")["b"], f"cum{how}")(), UnsupportedOperation,
                NOT_SORTED.format(verb=verb))
    for how in ("sum", "mean", "min", "max"):
        refuses(lambda: getattr(df["b"].rolling(5), how)(), UnsupportedOperation,
                NOT_SORTED.format(verb=f"rolling(5).{how}()"))
    # A frame that dropped its sort key has no row order any more.
    dropped = df.sort_values("x")[["a", "b"]]
    refuses(lambda: dropped["b"].cumsum(), UnsupportedOperation, NOT_SORTED.format(verb="cumsum()"))
    refuses(lambda: dropped["b"].rolling(2).sum(), UnsupportedOperation, NOT_SORTED.format(verb="rolling(2).sum()"))
    # A grouped frame is sorted by its keys, and a sort_values replaces them.
    assert df.groupby("a").size()["size"].cumsum().dtype == "int64"
    # A rank and a transform need no row order.
    assert df["b"].rank(method="min").dtype == "float64"
    assert df.groupby("a")["b"].transform("sum").dtype == "int64"


def test_a_frame_sorted_with_missing_values_first_is_refused_by_the_running_and_rolling_verbs():
    df = Env().df.sort_values("x", na_position="first")
    for how in ("sum", "min", "max"):
        message = NULLS_FIRST.format(verb=f"cum{how}()", column="x")
        refuses(lambda: getattr(df["b"], f"cum{how}")(), UnsupportedOperation, message)
        refuses(lambda: getattr(df.groupby("a")["b"], f"cum{how}")(), UnsupportedOperation, message)
    for how in ("sum", "mean", "min", "max"):
        refuses(lambda: getattr(df["b"].rolling(3), how)(), UnsupportedOperation,
                NULLS_FIRST.format(verb=f"rolling(3).{how}()", column="x"))
    # The first key that puts missing values first is named.
    mixed = Env().df.sort_values(["a", "x"], na_position="first")
    refuses(lambda: mixed["b"].cumsum(), UnsupportedOperation, NULLS_FIRST.format(verb="cumsum()", column="a"))
    # A rank reads no row order, so the frame's sort does not matter to it.
    keys = (SortKey("x", nulls_first=True),)
    assert df.assign(r=df["b"].rank(method="min"))._plan == Sort(
        assigned(SCAN, (WindowExpr("rank", None, order_by=(SortKey("b"),)),), {"r": missing("b", Cast(w(0), "float64"))}),
        keys,
    )


def test_cum_verbs_refuse_skipna_false_a_non_bool_skipna_and_an_axis_other_than_the_column():
    df = Env().df.sort_values("x")
    gb = df.groupby("a")["b"]
    for how in ("sum", "min", "max"):
        verb = f"cum{how}"
        skip = (f"{verb}(skipna=False) is missing from the first missing value on, which this release does not "
                "build: use skipna=True")
        refuses(lambda: getattr(df["b"], verb)(skipna=False), UnsupportedOperation, skip)
        refuses(lambda: getattr(gb, verb)(skipna=False), UnsupportedOperation, skip)
        for bad, name in ((1, "int"), (None, "NoneType"), ("yes", "str")):
            refuses(lambda: getattr(df["b"], verb)(skipna=bad), TypeError, f"{verb} skipna must be a bool, not {name}")
            refuses(lambda: getattr(gb, verb)(skipna=bad), TypeError, f"{verb} skipna must be a bool, not {name}")
        for axis in (1, "columns", True, False, 2):
            refuses(lambda: getattr(df["b"], verb)(axis=axis), UnsupportedOperation,
                    f"{verb}(axis={axis!r}) runs along a row, and a Series has one column: use axis=0")
    refuses(lambda: df["b"].rank(axis=1, method="min"), UnsupportedOperation,
            "rank(axis=1) runs along a row, and a Series has one column: use axis=0")
    refuses(lambda: df["b"].rank(axis="columns", method="min"), UnsupportedOperation,
            "rank(axis='columns') runs along a row, and a Series has one column: use axis=0")


def test_a_verb_that_needs_numbers_refuses_a_string_and_a_bool_column_by_name():
    df = Env().df.sort_values("x")
    for column, dtype in (("s", "string"), ("ok", "bool")):
        for how in ("sum", "mean"):
            refuses(lambda: df.groupby("a")[column].transform(how), UnsupportedOperation,
                    NEEDS_NUMBER.format(verb=f"transform({how!r})", column=column, dtype=dtype))
        refuses(lambda: df[column].cumsum(), UnsupportedOperation,
                NEEDS_NUMBER.format(verb="cumsum()", column=column, dtype=dtype))
        refuses(lambda: df.groupby("a")[column].cumsum(), UnsupportedOperation,
                NEEDS_NUMBER.format(verb="cumsum()", column=column, dtype=dtype))
        for how in ("sum", "mean", "min", "max"):
            refuses(lambda: getattr(df[column].rolling(2), how)(), UnsupportedOperation,
                    NEEDS_NUMBER.format(verb=f"rolling(2).{how}()", column=column, dtype=dtype))
    # The numeric check comes before the row-order check.
    refuses(lambda: Env().df["s"].cumsum(), UnsupportedOperation,
            NEEDS_NUMBER.format(verb="cumsum()", column="s", dtype="string"))
    # Verbs that compare values take any type.
    for how in ("min", "max", "count"):
        assert df.groupby("a")["s"].transform(how) is not None
    assert df["s"].cummin().dtype == "string"
    assert df["s"].rank(method="dense").dtype == "float64"


def test_rank_refuses_the_methods_and_options_no_window_function_computes():
    df = Env().df
    gb = df.groupby("a")["b"]
    for method in ("average", "max"):
        message = (f'rank(method="{method}") has no window function in the plan: use method="min" '
                   '(ties take the lowest rank) or method="dense"')
        refuses(lambda: df["b"].rank(method=method), UnsupportedOperation, message)
        refuses(lambda: gb.rank(method=method), UnsupportedOperation, message)
    # pandas' default method is average, which is refused.
    default = ('rank(method="average") has no window function in the plan: use method="min" '
               '(ties take the lowest rank) or method="dense"')
    refuses(lambda: df["b"].rank(), UnsupportedOperation, default)
    refuses(lambda: gb.rank(), UnsupportedOperation, default)
    first = ('rank(method="first") breaks ties by row order, which a frame does not have: '
             'use method="min" or method="dense"')
    refuses(lambda: df["b"].rank(method="first"), UnsupportedOperation, first)
    refuses(lambda: gb.rank(method="first"), UnsupportedOperation, first)
    unknown = "method must be one of 'average', 'min', 'max', 'first' or 'dense'"
    for bad in ("median", None, 1):
        refuses(lambda: df["b"].rank(method=bad), ValueError, unknown)
        refuses(lambda: gb.rank(method=bad), ValueError, unknown)
    top = ('rank(na_option="top") ranks the missing values first, and a window orders them last: '
           'use na_option="keep" or "bottom"')
    refuses(lambda: df["b"].rank(method="min", na_option="top"), UnsupportedOperation, top)
    refuses(lambda: gb.rank(method="min", na_option="top"), UnsupportedOperation, top)
    for bad in ("middle", None):
        refuses(lambda: df["b"].rank(method="min", na_option=bad), ValueError,
                "na_option must be one of 'keep', 'top', or 'bottom'")
        refuses(lambda: gb.rank(method="min", na_option=bad), ValueError,
                "na_option must be one of 'keep', 'top', or 'bottom'")
    pct = ("rank(pct=True) divides each rank by the count of values, which this release does not build: "
           "use pct=False")
    refuses(lambda: df["b"].rank(method="min", pct=True), UnsupportedOperation, pct)
    refuses(lambda: gb.rank(method="min", pct=True), UnsupportedOperation, pct)
    refuses(lambda: df["b"].rank(method="min", pct=1), TypeError, "rank pct must be a bool, not int")
    refuses(lambda: gb.rank(method="min", pct="no"), TypeError, "rank pct must be a bool, not str")
    for bad, name in ((1, "int"), (None, "NoneType"), ("up", "str")):
        refuses(lambda: df["b"].rank(method="min", ascending=bad), TypeError, f"rank ascending must be a bool, not {name}")
        refuses(lambda: gb.rank(method="min", ascending=bad), TypeError, f"rank ascending must be a bool, not {name}")
    refuses(lambda: df["b"].rank(method="min", numeric_only=True), UnsupportedOperation,
            "rank(numeric_only=True) is for a frame's columns; a Series ranks its own values")


def test_rolling_refuses_a_time_window_a_bad_window_and_every_option_that_is_not_the_default():
    df = Env().df.sort_values("x")
    s = df["b"]
    refuses(lambda: s.rolling("3D"), UnsupportedOperation,
            "rolling('3D') is a window of time, which needs a time index komira frames do not have: "
            "give the number of rows, as rolling(3)")
    for bad, name in ((2.5, "float"), (True, "bool"), (None, "NoneType"), ((3,), "tuple")):
        refuses(lambda: s.rolling(bad), TypeError,
                f"rolling window must be an int, the number of rows, not a {name}")
    for bad in (0, -1):
        refuses(lambda: s.rolling(bad), ValueError, "rolling window must be at least 1")
    refuses(lambda: s.rolling(3, min_periods=4), ValueError, "min_periods 4 must be <= window 3")
    refuses(lambda: s.rolling(1, min_periods=2), ValueError, "min_periods 2 must be <= window 1")
    refuses(lambda: s.rolling(3, min_periods=0), UnsupportedOperation,
            "rolling(min_periods=0) answers a window with no values, which this release "
            "does not build: use min_periods of 1 or more")
    refuses(lambda: s.rolling(3, min_periods=-1), ValueError, "min_periods must be >= 0")
    for bad, name in ((1.5, "float"), (True, "bool"), ("1", "str")):
        refuses(lambda: s.rolling(3, min_periods=bad), TypeError, f"rolling min_periods must be an int, not {name}")
    refuses(lambda: s.rolling(3, center=True), UnsupportedOperation,
            "rolling(center=True) centres each window on its row, which this release does not build: "
            "use center=False, a window of the row and the ones before it")
    for name, value in (("win_type", "triang"), ("on", "t"), ("closed", "left"), ("step", 2), ("method", "table")):
        refuses(lambda: s.rolling(3, **{name: value}), UnsupportedOperation,
                f"rolling({name}={value!r}) is not supported: leave {name} at its default")
    # The defaults are accepted, written out.
    plain = df.assign(r=s.rolling(3).sum())._plan
    explicit = s.rolling(3, None, False, None, None, None, None, "single").sum()
    assert df.assign(r=explicit)._plan == plain


def test_transform_refuses_a_function_a_non_name_and_a_name_no_window_computes():
    df = Env().df
    gb = df.groupby("a")["b"]
    refuses(lambda: gb.transform(lambda s: s - s.mean()), UnsupportedOperation,
            "transform() with a Python function runs it once per group, a user function that this release "
            f"does not run: name one of {TRANSFORMS}")
    refuses(lambda: gb.transform(sum), UnsupportedOperation,
            "transform() with a Python function runs it once per group, a user function that this release "
            f"does not run: name one of {TRANSFORMS}")
    for bad, name in ((3, "int"), (None, "NoneType"), (["sum"], "list")):
        refuses(lambda: gb.transform(bad), TypeError,
                f"transform() takes the name of a reduction, a str, not a {name}")
    for bad in ("median", "std", "nunique", "size", "first", "cumsum", ""):
        refuses(lambda: gb.transform(bad), UnsupportedOperation,
                f"transform({bad!r}) is not supported: name one of {TRANSFORMS}")


def test_a_groupby_window_verb_needs_one_selected_column_of_a_frame_that_was_not_replaced():
    df = Env().df
    gb = df.groupby("a")
    calls = {
        "transform()": lambda g: g.transform("sum"),
        "cumsum()": lambda g: g.cumsum(),
        "cummin()": lambda g: g.cummin(),
        "cummax()": lambda g: g.cummax(),
        "rank()": lambda g: g.rank(method="min"),
    }
    for verb, call in calls.items():
        refuses(lambda: call(gb), UnsupportedOperation, ONE_COLUMN.format(verb=verb))
        refuses(lambda: call(gb[["b", "x"]]), UnsupportedOperation, ONE_COLUMN.format(verb=verb))
        refuses(lambda: call(gb[["b"]]), UnsupportedOperation, ONE_COLUMN.format(verb=verb))
    # A GroupBy made before df["x"] = ... replaced the frame is refused by every window verb.
    sorted_frame = Env().df.sort_values("x")
    old = sorted_frame.groupby("a")["b"]
    old_frame = df.groupby("a")["b"]
    sorted_frame["z"] = 1
    df["z"] = 1
    for verb, call in calls.items():
        refuses(lambda: call(old), UnsupportedOperation, STALE_GROUPBY)
        refuses(lambda: call(old_frame), UnsupportedOperation, STALE_GROUPBY)
    # A GroupBy made after it is fine.
    assert df.groupby("a")["b"].transform("sum").dtype == "int64"
    assert sorted_frame.groupby("a")["b"].cumsum().dtype == "int64"


def test_a_window_verb_of_an_expression_or_a_stale_series_is_refused():
    df = Env().df.sort_values("x")
    expressions = {
        "arithmetic": df["b"] + 1,
        "comparison": df["b"] > 1,
        "window": df.groupby("a")["b"].transform("sum"),
        "running window": df["b"].cumsum(),
    }
    for series in expressions.values():
        refuses(lambda: series.cumsum(), UnsupportedOperation, EXPRESSION.format(verb="cumsum()"))
        refuses(lambda: series.cummin(), UnsupportedOperation, EXPRESSION.format(verb="cummin()"))
        refuses(lambda: series.cummax(), UnsupportedOperation, EXPRESSION.format(verb="cummax()"))
        refuses(lambda: series.rank(method="min"), UnsupportedOperation, EXPRESSION.format(verb="rank()"))
        refuses(lambda: series.rolling(2), UnsupportedOperation, EXPRESSION.format(verb="rolling()"))
    # After df["z"] = ..., a Series taken before it is stale for each window verb.
    series = df["b"]
    roll = df["b"].rolling(2)
    window = df.groupby("a")["b"].transform("sum")
    df["z"] = 1
    refuses(lambda: series.cumsum(), UnsupportedOperation, STALE)
    refuses(lambda: series.cummin(), UnsupportedOperation, STALE)
    refuses(lambda: series.cummax(), UnsupportedOperation, STALE)
    refuses(lambda: series.rank(method="min"), UnsupportedOperation, STALE)
    refuses(lambda: series.rolling(2), UnsupportedOperation, STALE)
    for how in ("sum", "mean", "min", "max"):
        refuses(lambda: getattr(roll, how)(), UnsupportedOperation, STALE)
    refuses(lambda: df.assign(t=window), UnsupportedOperation, STALE)
    refuses(lambda: df[window > 1], UnsupportedOperation, STALE)
    refuses(lambda: window.dtype, UnsupportedOperation, STALE)
    # Taken again, the same verbs work.
    assert df["b"].cumsum().dtype == "int64"
    assert df["b"].rolling(2).sum().dtype == "float64"


def test_a_rolling_is_made_by_a_series_runs_nothing_and_does_not_change():
    env = Env()
    df = env.df.sort_values("x")
    rolling = df["b"].rolling(3, min_periods=2)
    assert type(rolling) is Rolling
    assert repr(rolling) == "<komira.Rolling window=3 min_periods=2>"
    assert repr(df["b"].rolling(4)) == "<komira.Rolling window=4 min_periods=4>"
    refuses(lambda: Rolling(df["b"], 3), TypeError, 'a komira Rolling is made by a Series: df["column"].rolling(3)')
    refuses(lambda: Rolling(), TypeError, 'a komira Rolling is made by a Series: df["column"].rolling(3)')
    e = raised(lambda: setattr(rolling, "window", 5))
    assert type(e) is AttributeError and e.name == "window" and e.obj is rolling
    assert e.args[0] == "cannot set the attribute 'window' of a komira Rolling: it is part of a plan and does not change"
    refuses(lambda: setattr(rolling, "_window", 5), AttributeError,
            "cannot set the attribute '_window' of a komira Rolling: it is part of a plan and does not change")
    assert repr(rolling) == "<komira.Rolling window=3 min_periods=2>"
    assert env.stub.calls == []


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame window: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
