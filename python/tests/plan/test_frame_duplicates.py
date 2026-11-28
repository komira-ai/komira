"""`drop_duplicates(subset=...)` over fewer than every column, `duplicated()`
and the refusal of `Series.unique()` on the pandas-shaped DataFrame
(komira/_groupby.py, komira/_windows.py, komira/_frame.py, komira/_refusals.py)
with no libkomira: a frame over a Parquet scan whose schema is made here, on a
session stand-in that records the plan bytes it is given. Checked:

- the plan each verb builds, by equality with a hand-built node tree:
  drop_duplicates of a subset of one and of two columns is the ROW_NUMBER
  window over each value of the subset, ordered by its first column, projected
  over the frame, the filter of the window's 1 and the projection back to the
  frame's columns, for keep="first" and keep="last" alike; keep=False is the
  COUNT window of a column of the literal 1 projected below it;
- the subset as one name, a list or a tuple, in the order given, a name given
  twice taken once, and a subset naming every column still the DISTINCT (or
  for keep=False the AGGREGATE) of plain drop_duplicates();
- the names of the added columns (`_w0`, `_one`) take an underscore more while
  the frame has a column of that name;
- order: over a sorted frame the sort is dropped, the window is over its
  input and the answer is unordered; over a head of a sort the window is above the limit;
- duplicated(subset, keep) is a bool Series that reads the window, `> 1`; in a
  filter (`df[df.duplicated(...)]` and its negation), in assign beside another
  window, and with no subset partitioning by every column;
- the wire: the encoded plans hold one partition-by node of the function and
  keys above, and the output schema is the frame's columns and types;
- every refusal by its class and its full message: a subset naming a missing
  column, an empty subset, a subset that is not names, an unknown keep, for
  both verbs; `Series.unique` by its refusal row;
- the verbs run nothing, and reach the session only as plan bytes at the
  terminal.

The test loads no library. It is of the `plan/` family (python/tests/BUCK).

    test_frame_duplicates.py
"""

import os
import sys
import tempfile

from komira import _ops, _refusals
from komira._frame import DataFrame
from komira._ops import Agg, ColRef, Compare, Field, Filter, Lit, Project, Sort, SortKey, Unary, When, WindowExpr
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, member, pb

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_duplicates_test_input.parquet")
FIELDS = (("a", "int64"), ("b", "int64"), ("x", "float64"), ("s", "string"), ("ok", "bool"))
COLS = tuple(name for name, _ in FIELDS)

UNIQUE_REFUSED = (
    ".unique() gives the distinct values as an array in pandas, which needs the rows, and a komira Series is "
    "part of a plan: select the column as a frame and drop its duplicates, as df[[column]].drop_duplicates(), "
    "then run it with materialize()"
)


class Stub:
    """A session that records what the plan door is given."""

    def __init__(self):
        self.calls = []

    def _plan_stream(self, plan):
        self.calls.append(("plan_stream", plan))
        return object()


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


def kept(cols):
    return tuple((c, ColRef(c)) for c in cols)


def numbered(keys):
    """The window of keep "first" and "last": ROW_NUMBER over each value of
    `keys`, ordered by the first of them."""
    return WindowExpr("row_number", None, partition_by=keys, order_by=(SortKey(keys[0]),))


def counted(keys, one="_one"):
    """The window of keep=False: the count of the rows of each value of `keys`."""
    return WindowExpr("count", one, partition_by=keys)


def with_one(child, cols=COLS, one="_one"):
    """The frame's columns and a column of the literal 1, `one`."""
    return Project(child, kept(cols) + ((one, Lit(1)),))


def unique_of(child, win, cols=COLS, below=None, name="_w0"):
    """The rows whose window is 1: the window projected over `below` (the
    child, or the child with its `_one` column), the filter, the columns."""
    below = child if below is None else below
    windowed = Project(below, kept(below.columns) + ((name, win),))
    return Project(Filter(windowed, Compare("eq", ColRef(name), Lit(1))), kept(cols))


def partitions(plan):
    """The partition-by nodes of an encoded plan, the lowest first."""
    nodes, p = [], plan
    while True:
        kind = p.WhichOneof("node")
        if kind == "partition_by":
            nodes.append(p.partition_by)
            p = p.partition_by.child
        elif kind in ("project", "sort", "filter", "limit"):
            p = getattr(p, kind).child
        else:
            return nodes[::-1]


# --- drop_duplicates(subset=...) ------------------------------------------------------------


def test_a_subset_of_one_column_keeps_the_row_numbered_1_of_each_value_for_first_and_last():
    env = Env()
    df = env.df
    want = unique_of(env.scan, numbered(("s",)))
    for got in (
        df.drop_duplicates(subset=["s"]),
        df.drop_duplicates("s"),
        df.drop_duplicates(subset=("s",), keep="last"),
        df.drop_duplicates(subset=["s", "s"], keep="first"),
    ):
        assert got._plan == want, got._plan
        # Whole rows: every column of the frame, with its type.
        assert got.columns == list(COLS)
        assert got.dtypes == df.dtypes
        assert got._order() is None


def test_a_subset_of_two_columns_partitions_by_both_in_the_order_given():
    env = Env()
    assert env.df.drop_duplicates(subset=["s", "a"])._plan == unique_of(env.scan, numbered(("s", "a")))
    assert env.df.drop_duplicates(subset=("a", "s"))._plan == unique_of(env.scan, numbered(("a", "s")))


def test_keep_false_over_a_subset_keeps_the_rows_whose_value_count_is_1():
    env = Env()
    got = env.df.drop_duplicates(subset=["s", "a"], keep=False)
    want = unique_of(env.scan, counted(("s", "a")), below=with_one(env.scan))
    assert got._plan == want, got._plan
    assert got.columns == list(COLS)
    # pandas takes a keep equal to False (0) as False.
    assert env.df.drop_duplicates(subset=["s", "a"], keep=0)._plan == want
    assert env.df.duplicated(["s"], keep=0)._windows == env.df.duplicated(["s"], keep=False)._windows


def test_a_subset_naming_every_column_is_still_plain_drop_duplicates():
    df = Env().df
    pair = df[["a", "s"]]
    assert pair.drop_duplicates(subset=["s", "a"])._plan == pair.drop_duplicates()._plan == _ops.distinct(pair._plan)
    assert pair.drop_duplicates(subset=["s", "a", "s"], keep="last")._plan == _ops.distinct(pair._plan)
    assert pair.drop_duplicates(subset=("a", "s"), keep=False)._plan == pair.drop_duplicates(keep=False)._plan
    assert pair.drop_duplicates(keep=False)._plan == _ops.select(
        _ops.filter_(
            _ops.aggregate(pair._plan, ("a", "s"), (("count", Agg("count", ())),)),
            Compare("eq", ColRef("count"), Lit(1)),
        ),
        ("a", "s"),
    )


def test_the_added_columns_take_an_underscore_more_while_the_frame_has_their_name():
    fields = (("k", "int64"), ("_w0", "string"), ("_one", "int64"), ("__one", "int64"))
    env = Env(fields)
    cols = tuple(n for n, _ in fields)
    got = env.df.drop_duplicates(subset=["k"])
    assert got._plan == unique_of(env.scan, numbered(("k",)), cols, name="__w0")
    got = env.df.drop_duplicates(subset=["k"], keep=False)
    want = unique_of(
        env.scan, counted(("k",), "___one"), cols, below=with_one(env.scan, cols, "___one"), name="__w0"
    )
    assert got._plan == want, got._plan
    assert got.columns == list(cols)


def test_over_a_sorted_frame_the_sort_is_dropped_and_the_answer_is_unordered():
    env = Env()
    got = env.df.sort_values("a").drop_duplicates(subset=["s"])
    assert got._plan == unique_of(env.scan, numbered(("s",)))
    assert got._order() is None
    # A head of a sort is a set of rows the sort chose: the window is above it.
    head = env.df.sort_values("a").head(3)
    got = head.drop_duplicates(subset=["s"], keep=False)
    assert got._plan == unique_of(head._plan, counted(("s",)), below=with_one(head._plan))
    assert got._order() is None


def test_the_encoded_subset_plans_hold_one_partition_by_node_and_the_frames_schema():
    env = Env()
    want_fields = [(n, arrow_id(t)) for n, t in FIELDS]
    for keep, func in (("first", "row_number"), (False, "count")):
        got = env.df.drop_duplicates(subset=["s", "a"], keep=keep)
        root = encode_plan(got._plan, env.sources).plan
        assert root.WhichOneof("node") == "project", root.WhichOneof("node")
        assert root.project.child.WhichOneof("node") == "filter"
        (node,) = partitions(root)
        assert list(node.partition_keys) == ["s", "a"], node.partition_keys
        (expr,) = node.partition_exprs
        assert expr.func == member("PF_", func), (keep, expr.func)
        assert [(f.name, f.arrow_type_id) for f in root.output_schema.fields] == want_fields


# --- duplicated() ------------------------------------------------------------------------


def test_duplicated_is_a_bool_series_true_past_the_first_row_number_or_count_of_a_value():
    df = Env().df
    first = df.duplicated(subset=["s"])
    assert first.dtype == "bool"
    win = numbered(("s",))
    ((placeholder, got),) = first._windows
    assert got == win
    assert first._node == Compare("gt", ColRef(placeholder), Lit(1))
    assert df.duplicated("s", keep="last")._windows == first._windows
    # keep=False counts every row of the value, through the reserved argument
    # `_computed` replaces with a column of the literal 1.
    every = df.duplicated(["s", "a"], keep=False)
    ((placeholder, got),) = every._windows
    assert got.func == "count" and got.partition_by == ("s", "a") and got.order_by == ()
    assert every._node == Compare("gt", ColRef(placeholder), Lit(1))
    assert every.dtype == "bool"
    # No subset: every column.
    ((_, got),) = df.duplicated()._windows
    assert got == numbered(COLS)


def test_a_filter_on_duplicated_and_its_negation_split_the_rows_drop_duplicates_keeps():
    env = Env()
    df = env.df
    flag = "_keep"

    def filtered(predicate, below, win):
        windowed = Project(below, kept(below.columns) + (("_w0", win),))
        tested = Project(windowed, kept(COLS) + ((flag, When(((predicate, Lit(1)),), Lit(0))),))
        return Project(Filter(tested, Compare("eq", ColRef(flag), Lit(1))), kept(COLS))

    dup = Compare("gt", ColRef("_w0"), Lit(1))
    assert df[df.duplicated(["s"])]._plan == filtered(dup, env.scan, numbered(("s",)))
    assert df[~df.duplicated(["s"])]._plan == filtered(Unary("not", dup), env.scan, numbered(("s",)))
    assert df[df.duplicated(["s"], keep=False)]._plan == filtered(dup, with_one(env.scan), counted(("s",)))


def test_two_duplicated_windows_in_one_assign_share_the_column_of_1():
    env = Env()
    df = env.df
    got = df.assign(any_dup=df.duplicated(["s"]), all_dup=df.duplicated(["s"], keep=False))
    below = with_one(env.scan)
    windowed = Project(below, kept(below.columns) + (("_w0", numbered(("s",))), ("_w1", counted(("s",)))))
    want = Project(
        windowed,
        kept(COLS)
        + (("any_dup", Compare("gt", ColRef("_w0"), Lit(1))), ("all_dup", Compare("gt", ColRef("_w1"), Lit(1)))),
    )
    assert got._plan == want, got._plan
    assert got.dtypes["any_dup"] == "bool" and got.dtypes["all_dup"] == "bool"
    assert got.columns == list(COLS) + ["any_dup", "all_dup"]


def test_duplicated_of_a_sorted_frame_filters_under_the_sort_and_keeps_it():
    env = Env()
    df = env.df.sort_values("a")
    got = df[~df.duplicated("s")]
    assert isinstance(got._plan, Sort) and got._order() == df._order() and df._order() is not None


# --- refusals -----------------------------------------------------------------------------


def test_both_verbs_refuse_a_missing_column_an_empty_subset_a_subset_not_of_names_and_an_unknown_keep():
    df = Env().df
    for verb in ("drop_duplicates", "duplicated"):
        call = getattr(df, verb)
        refuses(lambda: call(subset=["s", "y"]), KeyError,
                "no column named 'y' in this frame; the frame's columns are: a, b, x, s, ok")
        refuses(lambda: call(subset=[]), ValueError,
                f"{verb} subset names no column: name at least one, or leave it out to compare every column")
        refuses(lambda: call(subset=["s", 1]), TypeError, f"{verb} subset takes column names, which are str, not int")
        refuses(lambda: call(subset=3), TypeError, f"{verb} subset takes column names, not a int")
        refuses(lambda: call(subset={"s"}), TypeError, f"{verb} subset takes column names, not a set")
        for keep in ("any", None, True, 1, "none"):
            refuses(lambda: call(subset=["s"], keep=keep), ValueError, 'keep must be either "first", "last" or False')


def test_series_unique_is_refused_by_name_naming_drop_duplicates_of_the_column():
    df = Env().df
    assert _refusals.SERIES["unique"].format(name="unique") == UNIQUE_REFUSED
    e = raised(lambda: df["s"].unique)
    assert type(e) is AttributeError and e.args[0] == UNIQUE_REFUSED and e.name == "unique", repr(e)
    assert not hasattr(df["s"], "unique")
    # The frame has no unique() either: pandas' DataFrame has none.
    e = raised(lambda: df.unique)
    assert type(e) is AttributeError and e.args[0] == "'DataFrame' object has no attribute 'unique'", repr(e)


# --- nothing runs -----------------------------------------------------------------------


def test_the_verbs_run_nothing_and_reach_the_session_only_as_plan_bytes():
    env = Env()
    df = env.df
    frames = [
        df.drop_duplicates(subset=["s"]),
        df.drop_duplicates(subset=["s", "a"], keep=False),
        df[df.duplicated(["s"])],
        df.assign(d=df.duplicated(keep=False)),
    ]
    assert env.stub.calls == []
    for frame in frames:
        frame.materialize()
    assert env.stub.calls == [
        ("plan_stream", encode_plan(frame._plan, env.sources).SerializeToString()) for frame in frames
    ]


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame duplicates: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
