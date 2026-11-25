"""DataFrame.merge and isin with another frame's column of the pandas-shaped
DataFrame (komira/_merge.py, komira/_frame.py, komira/_series.py) with no
libkomira: two frames over Parquet scans whose schemas are made here, on one
session stand-in that records the plan bytes it is given. Checked:

- the plan of merge for each how (inner, left, right, outer which is the
  plan's full join, cross), by equality with a hand-built node tree: the
  right frame's names the left has renamed by a projection under the join, the
  naming projection over it (a key named alike once at its left position, the
  right frame's for how="right", the side that has a value for how="outer",
  the other shared names suffixed), custom and empty suffixes, keys named
  differently on the two sides, several keys, the default keys, sort=True and
  the sorts of the inputs, which a join drops;
- the output columns, types and nullability of each how: the padded side
  of a join is nullable;
- the wire: the join arm and its join type for each how;
- isin with another frame's column as a semi join, ~ as an anti join, an
  expression on the right as a key column, a sorted frame, a head of a sorted
  frame and a sorted right frame;
- the sources of the merged frame: both frames' files, one source for a file
  both read, a file read two ways refused;
- every refusal of merge by its class and its full message;
- the membership value, which only df[...] takes: refused inside every
  operator and verb, and its repr and type;
- a merged or semi-joined frame reaches the session only as plan bytes, at
  its terminal, and no SQL text is written.

    test_frame_merge.py
"""

import os
import sys
import tempfile

from komira import _ops
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Arith, ColRef, Compare, Field, Lit, SortKey, Unary, When
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, member, pb

# Never opened: a scan only names its file, and the schema is given here.
PATH_L = os.path.join(tempfile.gettempdir(), "frame_merge_test_left.parquet")
PATH_R = os.path.join(tempfile.gettempdir(), "frame_merge_test_right.parquet")
LEFT = (("k", "int64"), ("a", "int64"), ("x", "float64"), ("s", "string"))
RIGHT = (("k", "int64"), ("b", "int64"), ("x", "float64"), ("t", "string"))
MEMBERSHIP = (
    "isin() with another Series is a semi join, which is a condition of df[...] and nothing else: "
    'filter with it alone, as df[df["k"].isin(other["k"])], and filter that frame by the other conditions'
)
OTHER_FRAME = (
    "this Series belongs to another frame, and a komira frame has no index to align two frames by: "
    'take the column from the frame you use it with, or pass a function, as in assign(name=lambda d: d["column"])'
)
STALE = (
    'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
    "take it from the frame again"
)
TWO_SESSIONS = "combines frames of two sessions, which never meet: read both frames on one session"
C = ColRef


class Stub:
    """A session that records what the plan door and the renderer are given.
    It has no `sql`, no `sql_stream` and no `register_*`."""

    def __init__(self):
        self.calls = []
        self.stream = object()

    def _plan_stream(self, plan):
        self.calls.append(("plan_stream", plan))
        return self.stream

    def _plan_render(self, plan):
        self.calls.append(("plan_render", plan))
        return "rendered plan"


def frame(stub, path, fields):
    """A frame over a scan of `path`, its columns not nullable; also its scan and sources."""
    schema = pb.WireSchema(fields=[field(n, arrow_id(t), False) for n, t in fields])
    sources = {path: parquet_source(path, schema.SerializeToString())}
    scan = _ops.scan(path, "parquet", tuple(Field(n, t) for n, t in fields))
    return DataFrame._new(stub, scan, sources), scan, sources


class Env:
    """A left and a right frame on one session."""

    def __init__(self, left=LEFT, right=RIGHT):
        self.stub = Stub()
        self.df, self.left, self.sources = frame(self.stub, PATH_L, left)
        self.o, self.right, self.right_sources = frame(self.stub, PATH_R, right)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def project(child, *items):
    return _ops.Project(child, tuple(items))


def renamed_right(right, *pairs):
    """The right frame with the names the left has renamed: `pairs` are (new, old); the others stay."""
    moved = {old: new for new, old in pairs}
    return project(right, *((moved.get(c, c), C(c)) for c in right.columns))


# The right frame of RIGHT as the join sees it when "k" and "x" are the left's too.
def default_right(env):
    return renamed_right(env.right, ("k_right", "k"), ("x_right", "x"))


def joined(env, how, left_on, right_on, right=None, left=None):
    return _ops.Join(left or env.left, right or default_right(env), how, left_on, right_on)


def naming(plan, key, x_left="x_x", x_right="x_y"):
    """The answer of merging LEFT and RIGHT on "k": the columns pandas names them."""
    return project(
        plan,
        ("k", key),
        ("a", C("a")),
        (x_left, C("x")),
        ("s", C("s")),
        ("b", C("b")),
        (x_right, C("x_right")),
        ("t", C("t")),
    )


def nullable(df):
    plan = encode_plan(df._plan, df._sources).plan
    return {f.name: f.nullable for f in plan.output_schema.fields}


def find_join(plan):
    """The join node under a merged frame's projections and sort."""
    while plan.WhichOneof("node") in ("project", "sort"):
        plan = getattr(plan, plan.WhichOneof("node")).child
    assert plan.WhichOneof("node") == "join", plan.WhichOneof("node")
    return plan.join


# --- the plans of merge ----------------------------------------------------------


def test_inner_merge_on_a_key_keeps_the_key_once_and_suffixes_the_other_shared_name():
    env = Env()
    got = env.df.merge(env.o, on="k")
    assert got._plan == naming(joined(env, "inner", ("k",), ("k_right",)), C("k"))
    assert got.columns == ["k", "a", "x_x", "s", "b", "x_y", "t"]
    assert got.dtypes == {
        "k": "int64", "a": "int64", "x_x": "float64", "s": "string", "b": "int64", "x_y": "float64", "t": "string",
    }
    # how defaults to inner, a str and a list of one key are the same key, and copy changes nothing.
    assert env.df.merge(env.o, "inner", ["k"], copy=False)._plan == got._plan
    assert env.df.merge(env.o, how="inner", on="k")._plan == got._plan


def test_left_merge_keeps_the_left_key_and_right_merge_takes_the_right_frames_key():
    env = Env()
    left = env.df.merge(env.o, how="left", on="k")
    assert left._plan == naming(joined(env, "left", ("k",), ("k_right",)), C("k"))
    right = env.df.merge(env.o, how="right", on="k")
    assert right._plan == naming(joined(env, "right", ("k",), ("k_right",)), C("k_right"))
    assert right.columns == left.columns == ["k", "a", "x_x", "s", "b", "x_y", "t"]


def test_outer_merge_is_a_full_join_whose_key_is_the_one_of_the_side_that_has_a_value():
    env = Env()
    got = env.df.merge(env.o, how="outer", on="k")
    key = When(((Unary("is_not_null", C("k")), C("k")),), C("k_right"))
    assert got._plan == naming(joined(env, "full", ("k",), ("k_right",)), key)
    assert got.columns == ["k", "a", "x_x", "s", "b", "x_y", "t"]
    assert got.dtypes["k"] == "int64"


def test_cross_merge_has_no_keys_and_suffixes_every_shared_name():
    env = Env()
    got = env.df.merge(env.o, how="cross")
    plan = joined(env, "cross", (), ())
    items = (
        ("k_x", C("k")), ("a", C("a")), ("x_x", C("x")), ("s", C("s")),
        ("k_y", C("k_right")), ("b", C("b")), ("x_y", C("x_right")), ("t", C("t")),
    )
    assert got._plan == project(plan, *items)
    assert got.columns == ["k_x", "a", "x_x", "s", "k_y", "b", "x_y", "t"]
    # cross has no key column to sort by, so sort=True adds no sort.
    assert env.df.merge(env.o, how="cross", sort=True)._plan == got._plan


def test_custom_suffixes_and_an_empty_or_none_suffix_on_one_side():
    env = Env()
    plan = joined(env, "inner", ("k",), ("k_right",))
    assert env.df.merge(env.o, on="k", suffixes=("_l", "_r"))._plan == naming(plan, C("k"), "x_l", "x_r")
    assert env.df.merge(env.o, on="k", suffixes=["_l", "_r"])._plan == naming(plan, C("k"), "x_l", "x_r")
    assert env.df.merge(env.o, on="k", suffixes=(None, "_r"))._plan == naming(plan, C("k"), "x", "x_r")
    assert env.df.merge(env.o, on="k", suffixes=("", "_r"))._plan == naming(plan, C("k"), "x", "x_r")
    assert env.df.merge(env.o, on="k", suffixes=("_l", None))._plan == naming(plan, C("k"), "x_l", "x")
    assert env.df.merge(env.o, on="k", suffixes=("_l", ""))._plan == naming(plan, C("k"), "x_l", "x")


def test_keys_named_differently_on_the_two_sides_are_both_kept():
    env = Env()
    got = env.df.merge(env.o, left_on="a", right_on="b")
    items = (
        ("k_x", C("k")), ("a", C("a")), ("x_x", C("x")), ("s", C("s")),
        ("k_y", C("k_right")), ("b", C("b")), ("x_y", C("x_right")), ("t", C("t")),
    )
    assert got._plan == project(joined(env, "inner", ("a",), ("b",)), *items)
    assert got.columns == ["k_x", "a", "x_x", "s", "k_y", "b", "x_y", "t"]
    # One key named alike and one not: the alike one is the single key column.
    mixed = env.df.merge(env.o, left_on=["k", "a"], right_on=["k", "b"])
    items = (
        ("k", C("k")), ("a", C("a")), ("x_x", C("x")), ("s", C("s")),
        ("b", C("b")), ("x_y", C("x_right")), ("t", C("t")),
    )
    assert mixed._plan == project(joined(env, "inner", ("k", "a"), ("k_right", "b")), *items)


def test_left_on_and_right_on_with_the_same_names_are_on():
    env = Env()
    want = env.df.merge(env.o, on="k")._plan
    assert env.df.merge(env.o, left_on="k", right_on="k")._plan == want
    assert env.df.merge(env.o, left_on=["k"], right_on=("k",))._plan == want


def test_several_keys_and_the_default_keys_which_are_the_common_columns():
    env = Env()
    plan = joined(env, "inner", ("k", "x"), ("k_right", "x_right"))
    items = (
        ("k", C("k")), ("a", C("a")), ("x", C("x")), ("s", C("s")), ("b", C("b")), ("t", C("t")),
    )
    want = project(plan, *items)
    got = env.df.merge(env.o, on=["k", "x"])
    assert got._plan == want
    assert got.columns == ["k", "a", "x", "s", "b", "t"]
    assert env.df.merge(env.o, on=("k", "x"))._plan == want
    # With no keys named the common columns are the keys, in the left frame's order.
    assert env.df.merge(env.o)._plan == want
    assert env.df.merge(env.o, how="left")._plan == project(
        joined(env, "left", ("k", "x"), ("k_right", "x_right")), *items
    )
    # With every shared name a key, no suffix is needed, so both suffixes may be empty.
    assert env.df.merge(env.o, on=["k", "x"], suffixes=(None, None))._plan == want


def test_no_projection_is_added_when_the_join_already_has_the_answers_names():
    env = Env(left=(("a", "int64"), ("x", "float64")), right=(("b", "int64"), ("y", "string")))
    got = env.df.merge(env.o, left_on="a", right_on="b")
    assert got._plan == _ops.Join(env.left, env.right, "inner", ("a",), ("b",))
    assert got.columns == ["a", "x", "b", "y"]
    cross = env.df.merge(env.o, how="cross")
    assert cross._plan == _ops.Join(env.left, env.right, "cross", (), ())


def test_sort_true_sorts_by_the_keys_with_missing_keys_last_and_sort_false_adds_none():
    env = Env()
    inner = naming(joined(env, "inner", ("k",), ("k_right",)), C("k"))
    got = env.df.merge(env.o, on="k", sort=True)
    assert got._plan == _ops.Sort(inner, (SortKey("k"),))
    assert env.df.merge(env.o, on="k", sort=False)._plan == inner
    right = env.df.merge(env.o, how="right", on="k", sort=True)
    assert right._plan == _ops.Sort(naming(joined(env, "right", ("k",), ("k_right",)), C("k_right")), (SortKey("k"),))
    both = env.df.merge(env.o, on=["x", "k"], sort=True)
    assert both._plan.keys == (SortKey("x"), SortKey("k"))
    assert both._plan.keys[0].nulls_first is False and both._plan.keys[0].descending is False
    root = encode_plan(got._plan, got._sources).plan
    assert root.WhichOneof("node") == "sort", root.WhichOneof("node")
    assert list(root.sort.keys) == ["k"] and list(root.sort.nulls_first) == [False]
    assert list(root.sort.descending) == [False]


def test_the_sort_of_an_input_is_dropped_under_the_join_and_the_answer_is_unordered():
    env = Env()
    want = env.df.merge(env.o, on="k")._plan
    left_sorted = env.df.sort_values("a")
    right_sorted = env.o.sort_values(["b", "t"])
    assert left_sorted.merge(env.o, on="k")._plan == want
    assert env.df.merge(right_sorted, on="k")._plan == want
    both = left_sorted.merge(right_sorted, on="k")
    assert both._plan == want
    assert both._order() is None
    # sort=True sorts by the keys, not by the input's order.
    assert left_sorted.merge(env.o, on="k", sort=True)._plan == _ops.Sort(want, (SortKey("k"),))
    # A limit stays: only a sort at the root is dropped.
    head = left_sorted.head(2)
    assert head.merge(env.o, on="k")._plan == naming(
        _ops.Join(head._plan, default_right(env), "inner", ("k",), ("k_right",)), C("k")
    )


def test_a_right_column_renamed_away_from_a_name_the_left_has_avoids_names_either_frame_has():
    env = Env(left=(("k", "int64"), ("x", "float64"), ("x_right", "float64")), right=(("k", "int64"), ("x", "float64")))
    got = env.df.merge(env.o, on="k")
    right = renamed_right(env.right, ("k_right", "k"), ("_x_right", "x"))
    items = (("k", C("k")), ("x_x", C("x")), ("x_right", C("x_right")), ("x_y", C("_x_right")))
    assert got._plan == project(_ops.Join(env.left, right, "inner", ("k",), ("k_right",)), *items)
    assert got.columns == ["k", "x_x", "x_right", "x_y"]
    # The name is also avoided when only the right frame has it.
    env = Env(left=(("k", "int64"), ("x", "float64")), right=(("k", "int64"), ("x", "float64"), ("x_right", "float64")))
    got = env.df.merge(env.o, on="k")
    right = renamed_right(env.right, ("k_right", "k"), ("_x_right", "x"))
    items = (("k", C("k")), ("x_x", C("x")), ("x_y", C("_x_right")), ("x_right", C("x_right")))
    assert got._plan == project(_ops.Join(env.left, right, "inner", ("k",), ("k_right",)), *items)
    assert got.columns == ["k", "x_x", "x_y", "x_right"]


# --- the output of merge ------------------------------------------------------------


def test_the_padded_side_of_each_merge_is_nullable_on_the_wire():
    env = Env()
    left_side = {"a": False, "x_x": False, "s": False}
    right_side = {"b": False, "x_y": False, "t": False}
    inner = nullable(env.df.merge(env.o, on="k"))
    assert inner == {"k": False, **left_side, **right_side}
    assert list(inner) == ["k", "a", "x_x", "s", "b", "x_y", "t"]
    left = nullable(env.df.merge(env.o, how="left", on="k"))
    assert left == {"k": False, **left_side, "b": True, "x_y": True, "t": True}
    right = nullable(env.df.merge(env.o, how="right", on="k"))
    assert right == {"k": False, "a": True, "x_x": True, "s": True, **right_side}
    outer = nullable(env.df.merge(env.o, how="outer", on="k"))
    assert {n: v for n, v in outer.items() if n != "k"} == {
        "a": True, "x_x": True, "s": True, "b": True, "x_y": True, "t": True,
    }
    cross = nullable(env.df.merge(env.o, how="cross"))
    assert list(cross) == ["k_x", "a", "x_x", "s", "k_y", "b", "x_y", "t"]
    assert not any(cross.values())


def test_the_columns_and_types_of_each_how():
    env = Env()
    types = {"k": "int64", "a": "int64", "x_x": "float64", "s": "string", "b": "int64", "x_y": "float64", "t": "string"}
    for how in ("inner", "left", "right", "outer"):
        got = env.df.merge(env.o, how=how, on="k")
        assert got.columns == list(types), how
        assert got.dtypes == types, how
    cross = env.df.merge(env.o, how="cross")
    assert cross.dtypes == {
        "k_x": "int64", "a": "int64", "x_x": "float64", "s": "string",
        "k_y": "int64", "b": "int64", "x_y": "float64", "t": "string",
    }
    # A merge builds a frame, and runs nothing.
    assert env.stub.calls == []


def test_the_wire_has_a_join_arm_with_the_join_type_of_each_how():
    env = Env()
    for how, wire in (("inner", "inner"), ("left", "left"), ("right", "right"), ("outer", "full")):
        got = env.df.merge(env.o, how=how, on="k")
        join = find_join(encode_plan(got._plan, got._sources).plan)
        assert join.join_type == member("JOIN_", wire), how
        assert list(join.left_on) == ["k"] and list(join.right_on) == ["k_right"], how
    cross = env.df.merge(env.o, how="cross")
    join = find_join(encode_plan(cross._plan, cross._sources).plan)
    assert join.join_type == member("JOIN_", "cross")
    assert list(join.left_on) == [] and list(join.right_on) == []
    plain = Env(left=(("a", "int64"),), right=(("b", "int64"),))
    got = plain.df.merge(plain.o, left_on="a", right_on="b")
    root = encode_plan(got._plan, got._sources).plan
    assert root.WhichOneof("node") == "join"
    assert root.join.join_type == member("JOIN_", "inner")


# --- the sources ---------------------------------------------------------------------


def test_the_merged_frame_holds_the_sources_of_both_frames():
    env = Env()
    got = env.df.merge(env.o, on="k")
    assert sorted(got._sources) == sorted([PATH_L, PATH_R])
    assert got._sources[PATH_L] == env.sources[PATH_L]
    assert got._sources[PATH_R] == env.right_sources[PATH_R]
    semi = env.df[env.df["k"].isin(env.o["b"])]
    assert sorted(semi._sources) == sorted([PATH_L, PATH_R])
    # The frames' own sources do not change.
    assert sorted(env.df._sources) == [PATH_L] and sorted(env.o._sources) == [PATH_R]


def test_a_file_both_frames_read_the_same_way_is_one_source():
    env = Env()
    twin = DataFrame._new(env.stub, env.left, dict(env.sources))
    got = env.df.merge(twin, on="k")
    assert sorted(got._sources) == [PATH_L]
    encode_plan(got._plan, got._sources)
    # A frame merged with itself reads its file once.
    own = env.df.merge(env.df, on="k")
    assert sorted(own._sources) == [PATH_L]
    assert own.columns == ["k", "a_x", "x_x", "s_x", "a_y", "x_y", "s_y"]


def test_a_file_read_two_ways_is_refused_by_merge_and_by_isin_with_its_path():
    env = Env()
    other, _, _ = frame(env.stub, PATH_L, RIGHT)
    assert other._sources[PATH_L] != env.sources[PATH_L]
    tail = "two frames that read the file {!r} in two ways: read it once, and take both frames from that one".format(PATH_L)
    refuses(lambda: env.df.merge(other, on="k"), UnsupportedOperation, "merge() combines " + tail)
    refuses(lambda: env.df[env.df["k"].isin(other["b"])], UnsupportedOperation, "isin() combines " + tail)


def test_frames_of_two_sessions_are_refused_by_merge_and_by_isin():
    env = Env()
    elsewhere = Env()
    refuses(lambda: env.df.merge(elsewhere.o, on="k"), UnsupportedOperation, "merge() " + TWO_SESSIONS)
    refuses(lambda: env.df.merge(elsewhere.df, on="k"), UnsupportedOperation, "merge() " + TWO_SESSIONS)
    refuses(
        lambda: env.df["k"].isin(elsewhere.o["b"]),
        UnsupportedOperation,
        "isin() with a Series of a frame on another session: frames of two sessions never meet; "
        "read both frames on one session",
    )
    assert env.stub.calls == [] and elsewhere.stub.calls == []


# --- isin with another frame's column ------------------------------------------------


def semi(env, how="semi", left=None, right=None, key="b", left_on="k"):
    return _ops.Join(left or env.left, right or project(env.right, (key, C(key))), how, (left_on,), (key,))


def test_isin_with_another_frames_column_is_a_semi_join_and_its_negation_an_anti_join():
    env = Env()
    got = env.df[env.df["k"].isin(env.o["b"])]
    assert got._plan == semi(env)
    assert got.columns == ["k", "a", "x", "s"]
    assert got.dtypes == env.df.dtypes
    anti = env.df[~env.df["k"].isin(env.o["b"])]
    assert anti._plan == semi(env, "anti")
    assert anti.columns == ["k", "a", "x", "s"]
    # A double negation is the semi join again, and the Series it was made from does not change.
    member_ = env.df["k"].isin(env.o["b"])
    assert env.df[~~member_]._plan == semi(env)
    assert env.df[~member_]._plan == semi(env, "anti")
    assert env.df[member_]._plan == semi(env)
    assert env.df[lambda d: d["k"].isin(env.o["b"])]._plan == semi(env)
    assert env.df[lambda d: ~d["k"].isin(env.o["b"])]._plan == semi(env, "anti")


def test_isin_with_a_column_of_the_same_frame_joins_the_frame_with_itself():
    env = Env()
    got = env.df[env.df["k"].isin(env.df["a"])]
    assert got._plan == _ops.Join(env.left, project(env.left, ("a", C("a"))), "semi", ("k",), ("a",))
    assert sorted(got._sources) == [PATH_L]


def test_the_right_series_of_a_semi_join_that_is_an_expression_becomes_a_column_named_key():
    env = Env()
    got = env.df[env.df["k"].isin(env.o["b"] + 1)]
    right = project(env.right, ("key", Arith("add", C("b"), Lit(1))))
    assert got._plan == _ops.Join(env.left, right, "semi", ("k",), ("key",))
    anti = env.df[~env.df["k"].isin(env.o["b"] > 1)]
    right = project(env.right, ("key", Compare("gt", C("b"), Lit(1))))
    assert anti._plan == _ops.Join(env.left, right, "anti", ("k",), ("key",))
    # A semi join is a filter: the frame can be filtered by other conditions after it.
    after = got[got["a"] > 1]
    assert after._plan == _ops.Filter(got._plan, Compare("gt", C("a"), Lit(1)))


def test_a_semi_join_over_a_sorted_frame_keeps_the_sort_over_the_join():
    env = Env()
    keys = (SortKey("a"),)
    s = env.df.sort_values("a")
    got = s[s["k"].isin(env.o["b"])]
    assert got._plan == _ops.Sort(semi(env), keys)
    assert got._order() == keys
    anti = s[~s["k"].isin(env.o["b"])]
    assert anti._plan == _ops.Sort(semi(env, "anti"), keys)


def test_a_semi_join_over_the_head_of_a_sorted_frame_adds_a_sort_over_the_join():
    env = Env()
    keys = (SortKey("a"),)
    head = env.df.sort_values("a").head(3)
    assert head._plan == _ops.Limit(_ops.Sort(env.left, keys), 3)
    got = head[head["k"].isin(env.o["b"])]
    assert got._plan == _ops.Sort(semi(env, left=head._plan), keys)
    assert got._order() == keys


def test_the_sort_of_the_right_frame_is_dropped_under_a_semi_join():
    env = Env()
    right_sorted = env.o.sort_values("b")
    got = env.df[env.df["k"].isin(right_sorted["b"])]
    assert got._plan == semi(env)
    assert got._order() is None
    assert env.df.sort_values("a")[lambda d: d["k"].isin(right_sorted["b"])]._plan == _ops.Sort(
        semi(env), (SortKey("a"),)
    )


def test_the_wire_of_a_semi_and_an_anti_join_has_the_left_frames_columns_only():
    env = Env()
    for how, flip in (("semi", False), ("anti", True)):
        cond = env.df["k"].isin(env.o["b"])
        got = env.df[~cond if flip else cond]
        root = encode_plan(got._plan, got._sources).plan
        assert root.WhichOneof("node") == "join", how
        assert root.join.join_type == member("JOIN_", how)
        assert list(root.join.left_on) == ["k"] and list(root.join.right_on) == ["b"]
        assert [f.name for f in root.output_schema.fields] == ["k", "a", "x", "s"]
        assert [f.nullable for f in root.output_schema.fields] == [False] * 4


# --- the refusals of merge -----------------------------------------------------------


def test_merge_with_something_that_is_not_a_frame_is_refused():
    env = Env()
    refuses(lambda: env.df.merge("right", on="k"), TypeError, "merge() takes a komira DataFrame to merge with, not a str")
    refuses(lambda: env.df.merge(None), TypeError, "merge() takes a komira DataFrame to merge with, not a NoneType")
    refuses(lambda: env.df.merge(env.o["k"], on="k"), TypeError, "merge() takes a komira DataFrame to merge with, not a Series")


def test_the_index_indicator_and_validate_arguments_are_refused_by_name():
    env = Env()
    for name in ("left_index", "right_index"):
        refuses(
            lambda: env.df.merge(env.o, **{name: True}),
            UnsupportedOperation,
            f"merge({name}=True) joins on the index, which komira frames do not have: "
            "name the key columns with on=, or left_on= and right_on=",
        )
    refuses(
        lambda: env.df.merge(env.o, on="k", left_index=1),
        UnsupportedOperation,
        "merge(left_index=1) joins on the index, which komira frames do not have: "
        "name the key columns with on=, or left_on= and right_on=",
    )
    refuses(
        lambda: env.df.merge(env.o, on="k", indicator=True),
        UnsupportedOperation,
        "merge(indicator=True) adds a column saying which frame each row came from, "
        "which this release does not build: use indicator=False",
    )
    refuses(
        lambda: env.df.merge(env.o, on="k", indicator="where"),
        UnsupportedOperation,
        "merge(indicator='where') adds a column saying which frame each row came from, "
        "which this release does not build: use indicator=False",
    )
    refuses(
        lambda: env.df.merge(env.o, on="k", validate="one_to_one"),
        UnsupportedOperation,
        "merge(validate='one_to_one') checks that the keys are unique, which needs a query to run: "
        "use validate=None",
    )


def test_the_anti_hows_and_the_semi_hows_are_refused_with_the_isin_form_that_means_them():
    env = Env()
    for how in ("left_anti", "right_anti"):
        refuses(
            lambda: env.df.merge(env.o, how=how, on="k"),
            UnsupportedOperation,
            f"merge(how={how!r}) is not supported: "
            'filter with ~isin instead, as df[~df["k"].isin(other["k"])]',
        )
    for how in ("semi", "anti"):
        refuses(
            lambda: env.df.merge(env.o, how=how, on="k"),
            UnsupportedOperation,
            f"merge(how={how!r}) is not pandas': filter with isin instead, as "
            'df[df["k"].isin(other["k"])] for a semi join and df[~df["k"].isin(other["k"])] for an anti join',
        )


def test_an_unknown_how_and_a_sort_that_is_not_a_bool_are_refused():
    env = Env()
    refuses(lambda: env.df.merge(env.o, how="full", on="k"), ValueError,
            "'full' is not a valid Merge type: left, right, inner, outer, cross")
    refuses(lambda: env.df.merge(env.o, how=None, on="k"), ValueError,
            "None is not a valid Merge type: left, right, inner, outer, cross")
    refuses(lambda: env.df.merge(env.o, how=["inner"], on="k"), ValueError,
            "['inner'] is not a valid Merge type: left, right, inner, outer, cross")
    refuses(lambda: env.df.merge(env.o, on="k", sort=1), TypeError, "merge sort must be a bool, not int")
    refuses(lambda: env.df.merge(env.o, on="k", sort=None), TypeError, "merge sort must be a bool, not NoneType")


def test_suffixes_that_are_not_two_str_or_none_are_refused():
    env = Env()
    refuses(lambda: env.df.merge(env.o, on="k", suffixes="_x"), TypeError,
            "merge suffixes must be a tuple of two str (or None), not a str")
    refuses(lambda: env.df.merge(env.o, on="k", suffixes=None), TypeError,
            "merge suffixes must be a tuple of two str (or None), not a NoneType")
    refuses(lambda: env.df.merge(env.o, on="k", suffixes=("_x",)), ValueError,
            "merge suffixes must be two, a left and a right one, not 1")
    refuses(lambda: env.df.merge(env.o, on="k", suffixes=("_x", "_y", "_z")), ValueError,
            "merge suffixes must be two, a left and a right one, not 3")
    refuses(lambda: env.df.merge(env.o, on="k", suffixes=("_x", 1)), TypeError,
            "merge suffixes must be str or None, not int")
    refuses(lambda: env.df.merge(env.o, on="k", suffixes=(b"_x", "_y")), TypeError,
            "merge suffixes must be str or None, not bytes")


def test_shared_names_that_no_suffix_separates_or_that_make_duplicate_columns_are_refused():
    env = Env()
    refuses(lambda: env.df.merge(env.o, on="k", suffixes=(None, None)), ValueError,
            "columns overlap but no suffix specified: ['x']")
    refuses(lambda: env.df.merge(env.o, on="k", suffixes=("", "")), ValueError,
            "columns overlap but no suffix specified: ['x']")
    refuses(lambda: env.df.merge(env.o, how="cross", suffixes=(None, None)), ValueError,
            "columns overlap but no suffix specified: ['k', 'x']")
    dup = Env(left=(("k", "int64"), ("x", "float64"), ("x_y", "float64")), right=(("k", "int64"), ("x", "float64")))
    refuses(lambda: dup.df.merge(dup.o, on="k"), ValueError,
            "Passing 'suffixes' which cause duplicate columns ['x_y'] is not allowed.")
    # Suffixes that keep the names apart make the same merge work.
    assert dup.df.merge(dup.o, on="k", suffixes=("_l", "_r")).columns == ["k", "x_l", "x_y", "x_r"]


def test_cross_merge_takes_no_keys_and_on_cannot_be_combined_with_left_on_or_right_on():
    env = Env()
    cross = "Can not pass on, right_on, left_on or set right_index=True or left_index=True"
    refuses(lambda: env.df.merge(env.o, how="cross", on="k"), ValueError, cross)
    refuses(lambda: env.df.merge(env.o, how="cross", left_on="a"), ValueError, cross)
    refuses(lambda: env.df.merge(env.o, how="cross", right_on="b"), ValueError, cross)
    both = 'Can only pass argument "on" OR "left_on" and "right_on", not a combination of both.'
    refuses(lambda: env.df.merge(env.o, on="k", left_on="a"), ValueError, both)
    refuses(lambda: env.df.merge(env.o, on="k", right_on="b"), ValueError, both)
    refuses(lambda: env.df.merge(env.o, on="k", left_on="a", right_on="b"), ValueError, both)


def test_left_on_needs_right_on_and_the_two_need_as_many_names():
    env = Env()
    refuses(lambda: env.df.merge(env.o, left_on="a"), ValueError, 'Must pass "right_on" OR "right_index".')
    refuses(lambda: env.df.merge(env.o, right_on="b"), ValueError, 'Must pass "left_on" OR "left_index".')
    refuses(lambda: env.df.merge(env.o, left_on=["k", "a"], right_on="b"), ValueError,
            "len(right_on) must equal len(left_on)")
    refuses(lambda: env.df.merge(env.o, left_on="a", right_on=["k", "b"]), ValueError,
            "len(right_on) must equal len(left_on)")


def test_frames_with_no_common_column_need_keys_and_a_missing_key_column_is_refused_by_name():
    env = Env(left=(("a", "int64"),), right=(("b", "int64"),))
    refuses(lambda: env.df.merge(env.o), ValueError,
            "No common columns to perform merge on. Merge options: left_on=None, right_on=None, "
            "left_index=False, right_index=False")
    assert env.df.merge(env.o, how="cross").columns == ["a", "b"]
    env = Env()
    plain = "no column named 'zz' in this frame; the frame's columns are: "
    refuses(lambda: env.df.merge(env.o, on="zz"), KeyError, plain + "k, a, x, s")
    refuses(lambda: env.df.merge(env.o, on="kk"), KeyError,
            "no column named 'kk' in this frame; the closest is 'k'; the frame's columns are: k, a, x, s")
    refuses(lambda: env.df.merge(env.o, left_on="zz", right_on="k"), KeyError, plain + "k, a, x, s")
    refuses(lambda: env.df.merge(env.o, left_on="k", right_on="zz"), KeyError, plain + "k, b, x, t")
    # A key only one frame has is not found in the other.
    refuses(lambda: env.df.merge(env.o, on="a"), KeyError,
            "no column named 'a' in this frame; the frame's columns are: k, b, x, t")


def test_keys_that_are_not_names_or_are_empty_or_repeated_are_refused():
    env = Env()
    refuses(lambda: env.df.merge(env.o, on=[]), ValueError, "merge on must name at least one column")
    refuses(lambda: env.df.merge(env.o, left_on=[], right_on=[]), ValueError, "merge left_on must name at least one column")
    refuses(lambda: env.df.merge(env.o, left_on="a", right_on=[]), ValueError, "merge right_on must name at least one column")
    refuses(lambda: env.df.merge(env.o, on=5), TypeError, "merge on takes a column name or a list of names, not a int")
    refuses(lambda: env.df.merge(env.o, left_on=1.5, right_on="b"), TypeError,
            "merge left_on takes a column name or a list of names, not a float")
    refuses(lambda: env.df.merge(env.o, on=["k", 1]), TypeError, "merge on takes column names, which are str, not int")
    refuses(lambda: env.df.merge(env.o, on=["k", "k"]), ValueError, "merge: the output name 'k' appears more than once")


def test_sort_true_with_keys_named_differently_is_refused():
    env = Env()
    message = (
        "merge(sort=True) with keys named differently on the two sides has no one key column to sort by: "
        "sort the answer with sort_values"
    )
    refuses(lambda: env.df.merge(env.o, left_on="a", right_on="b", sort=True), UnsupportedOperation, message)
    refuses(lambda: env.df.merge(env.o, left_on=["k", "a"], right_on=["k", "b"], sort=True), UnsupportedOperation, message)
    assert env.df.merge(env.o, left_on="a", right_on="b", sort=False).columns[1] == "a"


def test_a_refused_merge_runs_nothing_and_leaves_both_frames_as_they_were():
    env = Env()
    before = (env.df._plan, env.o._plan, dict(env.df._sources), dict(env.o._sources))
    raised(lambda: env.df.merge(env.o, on="zz"))
    raised(lambda: env.df.merge(env.o, how="semi", on="k"))
    assert before == (env.df._plan, env.o._plan, dict(env.df._sources), dict(env.o._sources))
    assert env.stub.calls == []


# --- the membership value ------------------------------------------------------------


def test_a_membership_has_a_repr_and_the_bool_type_and_runs_nothing():
    env = Env()
    member_ = env.df["k"].isin(env.o["b"])
    assert repr(member_) == "<komira.Series k in another Series' values>"
    assert repr(~member_) == "<komira.Series k not in another Series' values>"
    assert repr(~~member_) == "<komira.Series k in another Series' values>"
    assert member_.dtype == "bool" and (~member_).dtype == "bool"
    assert env.stub.calls == []


def test_a_membership_is_refused_inside_and_and_or_in_both_orders_and_with_a_bool():
    env = Env()
    df = env.df
    m = df["k"].isin(env.o["b"])
    cond = df["a"] > 1
    for call in (
        lambda: m & cond,
        lambda: cond & m,
        lambda: m | cond,
        lambda: cond | m,
        lambda: m & True,
        lambda: True & m,
        lambda: m | False,
        lambda: False | m,
        lambda: m & m,
        lambda: ~m & cond,
        lambda: cond | ~m,
        lambda: df[m & cond],
        lambda: df[cond & ~m],
    ):
        refuses(call, UnsupportedOperation, MEMBERSHIP)


def test_a_membership_is_refused_in_comparisons_arithmetic_and_negation_with_minus():
    env = Env()
    df = env.df
    m = df["k"].isin(env.o["b"])
    for call in (
        lambda: m == True,  # noqa: E712
        lambda: m != False,  # noqa: E712
        lambda: m < 1,
        lambda: m <= 1,
        lambda: m > 1,
        lambda: m >= 1,
        lambda: df["a"] == m,
        lambda: df["a"] < m,
        lambda: m + 1,
        lambda: 1 + m,
        lambda: m - 1,
        lambda: 1 - m,
        lambda: m * 2,
        lambda: 2 * m,
        lambda: m / 2,
        lambda: 2 / m,
        lambda: df["a"] + m,
        lambda: df["a"] * m,
        lambda: -m,
    ):
        refuses(call, UnsupportedOperation, MEMBERSHIP)


def test_a_membership_is_refused_by_assign_setitem_and_the_verbs_of_a_series():
    env = Env()
    df = env.df
    m = df["k"].isin(env.o["b"])
    plan = df._plan
    refuses(lambda: df.assign(flag=m), UnsupportedOperation, MEMBERSHIP)
    refuses(lambda: df.assign(flag=lambda d: d["k"].isin(env.o["b"])), UnsupportedOperation, MEMBERSHIP)
    refuses(lambda: df.assign(flag=~m), UnsupportedOperation, MEMBERSHIP)

    def setitem():
        df["flag"] = m

    refuses(setitem, UnsupportedOperation, MEMBERSHIP)
    assert df._plan == plan and df.columns == ["k", "a", "x", "s"]
    # The failed assignment did not replace the frame, so a Series taken before it is still current.
    assert df["k"].dtype == "int64"
    for call in (
        lambda: m.isin([1, 2]),
        lambda: m.isin(env.o["b"]),
        lambda: m.cumsum(),
        lambda: m.cummin(),
        lambda: m.cummax(),
        lambda: m.rank(),
        lambda: m.rank(method="min"),
        lambda: m.rolling(2),
    ):
        refuses(call, UnsupportedOperation, MEMBERSHIP)


def test_a_membership_of_another_frame_or_of_a_copy_cannot_subscript_the_frame():
    env = Env()
    foreign = env.o["b"].isin(env.df["k"])
    refuses(lambda: env.df[foreign], UnsupportedOperation, OTHER_FRAME)
    twin = env.df.copy()
    refuses(lambda: env.df[twin["k"].isin(env.o["b"])], UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: env.df[~foreign], UnsupportedOperation, OTHER_FRAME)
    # A frame subscripted by its own membership works, and so does the other frame by its own.
    assert env.o[foreign]._plan == _ops.Join(env.right, project(env.left, ("k", C("k"))), "semi", ("b",), ("k",))


def test_isin_with_a_series_needs_a_column_on_the_left_and_a_series_without_windows_on_the_right():
    env = Env()
    expression = (
        "isin() with a Series takes a column of the frame, and this Series is an expression: "
        'assign it as a column first, as df.assign(x=...), then take df["x"]'
    )
    refuses(lambda: (env.df["a"] + 1).isin(env.o["b"]), UnsupportedOperation, expression)
    refuses(lambda: (env.df["a"] > 1).isin(env.o["b"]), UnsupportedOperation, expression)
    ordered = env.o.sort_values("b")
    running = ordered["b"].cumsum()
    refuses(
        lambda: env.df["k"].isin(running),
        UnsupportedOperation,
        "isin() with a Series of windows is not supported: assign the windows as a column of their frame "
        "first, and pass that column",
    )
    # Assigned as a column of its frame first, the same values are accepted.
    assigned = ordered.assign(running=ordered["b"].cumsum())
    got = env.df[env.df["k"].isin(assigned["running"])]
    assert got.columns == ["k", "a", "x", "s"]
    assert encode_plan(got._plan, got._sources).plan.WhichOneof("node") == "join"


def test_a_membership_of_a_membership_is_refused():
    env = Env()
    inner = env.o["b"].isin(env.df["k"])
    refuses(lambda: env.df["k"].isin(inner), UnsupportedOperation, MEMBERSHIP)
    refuses(lambda: env.df["k"].isin(~inner), UnsupportedOperation, MEMBERSHIP)


def test_a_stale_series_on_either_side_of_isin_or_a_membership_is_refused():
    env = Env()
    df, o = env.df, env.o
    left, values = df["k"], o["b"]
    member_ = df["k"].isin(o["b"])
    negated = ~member_
    df["z"] = 1
    refuses(lambda: left.isin(values), UnsupportedOperation, STALE)
    refuses(lambda: df[member_], UnsupportedOperation, STALE)
    refuses(lambda: ~member_, UnsupportedOperation, STALE)
    refuses(lambda: df[negated], UnsupportedOperation, STALE)
    refuses(lambda: member_.dtype, UnsupportedOperation, STALE)
    fresh = df["k"].isin(values)
    assert df[fresh].columns == ["k", "a", "x", "s", "z"]
    o["z"] = 1
    refuses(lambda: df["k"].isin(values), UnsupportedOperation, STALE)
    refuses(lambda: df[fresh], UnsupportedOperation, STALE)
    assert df[df["k"].isin(o["b"])].columns == ["k", "a", "x", "s", "z"]


# --- the terminal ----------------------------------------------------------------------


def test_a_merged_or_semi_joined_frame_reaches_the_session_only_as_plan_bytes_at_its_terminal():
    env = Env()
    frames = [
        env.df.merge(env.o, on="k"),
        env.df.merge(env.o, how="outer", on="k", sort=True),
        env.df.merge(env.o, how="cross"),
        env.df[env.df["k"].isin(env.o["b"])],
        env.df[~env.df["k"].isin(env.o["b"])],
    ]
    assert env.stub.calls == []
    for got in frames:
        got.materialize()
    assert env.stub.calls == [
        ("plan_stream", encode_plan(got._plan, got._sources).SerializeToString()) for got in frames
    ]
    assert not hasattr(env.stub, "sql") and not hasattr(env.stub, "sql_stream")
    for (_, arg), got in zip(env.stub.calls, frames):
        envelope = pb.WirePlanEnvelope.FromString(arg)
        find_join(envelope.plan)
        assert envelope.plan.output_schema.fields[0].name in ("k", "k_x")
    root = pb.WirePlanEnvelope.FromString(env.stub.calls[3][1]).plan
    assert root.WhichOneof("node") == "join" and root.join.join_type == member("JOIN_", "semi")
    root = pb.WirePlanEnvelope.FromString(env.stub.calls[4][1]).plan
    assert root.WhichOneof("node") == "join" and root.join.join_type == member("JOIN_", "anti")
    assert [name for name, _ in env.stub.calls] == ["plan_stream"] * 5


def test_explain_of_a_merged_frame_renders_the_plan_bytes():
    env = Env()
    got = env.df.merge(env.o, on="k")
    assert got.explain() == "rendered plan"
    assert env.stub.calls == [("plan_render", encode_plan(got._plan, got._sources).SerializeToString())]


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame merge: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
