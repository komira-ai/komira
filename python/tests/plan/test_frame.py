"""The pandas-shaped DataFrame and Series (komira/_frame.py, komira/_series.py,
komira/_refusals.py) with no libkomira: a frame over a Parquet scan whose
schema is made here, on a session stand-in that records the plan bytes it is
given and has no SQL entry. Checked:

- the plan each verb builds, by equality with a hand-built node tree: a column,
  a projection, a filter, assign, sort_values (direction and NULL placement),
  head, each over an unsorted, a sorted and a sorted-and-limited frame, with
  the sort above a limit when a verb keeps the order and none when it drops a
  key; the operators of a Series (comparisons, arithmetic with true division
  and reflected integer literals, `& | ~`, isin);
- the types: columns, dtypes and repr of frames and Series after the verbs,
  and each output type, which is the engine's;
- every refusal by its class and its full message;
- the attribute rules for every row of the frame, Series and module refusal
  tables, assignment to an attribute, dir, copy and `in`; a pandas verb the
  skin lacks raises `AttributeError` (so `getattr` with a default returns the
  default) and is never read as a column, even when a column has its name; a
  column named after a verb (`fillna`, `dropna`) leaves `df.<verb>` the verb;
- no dunder runs a query;
- the terminals send exactly the encoded plan bytes to the session and
  nothing else, each time they are called;
- no SQL: the frame modules import and call nothing that reaches SQL, and a
  chain of verbs reaches the session only as plan bytes;
- the argument checks of the readers that fail before any library call.

The test loads no library. It is of the `plan/` family (python/tests/BUCK):
`frame_test` runs on each supported minor under protobuf 7.36.2, the newest
runtime the range admits, and `frame_test_protobuf_lower_edge` on CPython 3.13
under 5.29.1, the oldest.

    test_frame.py
"""

import ast
import copy
import operator
import os
import sys
import tempfile

import komira
from komira import _ops, _refusals
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Arith, BoolOp, Cast, ColRef, Compare, Field, Filter, Limit, Lit, Project, Sort, SortKey, Unary
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, pb

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_test_input.parquet")
FIELDS = (("a", "int64"), ("b", "int64"), ("n", "int32"), ("x", "float64"), ("s", "string"), ("ok", "bool"))
COLS = tuple(name for name, _ in FIELDS)
LISTED = "a, b, n, x, s, ok"
SCAN = _ops.scan(PATH, "parquet", tuple(Field(name, dtype) for name, dtype in FIELDS))

K_A = (SortKey("a"),)
GT_A1 = Compare("gt", ColRef("a"), Lit(1))
GT_B1 = Compare("gt", ColRef("b"), Lit(1))
LITERALS = "None, bool, int, float, str, bytes, Decimal, date, datetime, time or timedelta"
OTHER_FRAME = (
    "this Series belongs to another frame, and a komira frame has no index to align two frames by: "
    'take the column from the frame you use it with, or pass a function, as in assign(name=lambda d: d["column"])'
)
STALE = (
    'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
    "take it from the frame again"
)
TERMINAL = "run it with .materialize() and read the Result"
NO_ROWS = "needs the rows, and a komira Series is part of a plan: run its frame with .materialize()"


class Stub:
    """A session that records what the plan door and the renderer are given.
    It has no `sql`, no `sql_stream` and no `register_*`."""

    def __init__(self):
        self.calls = []
        self.stream = object()
        self.text = "rendered plan"

    def _plan_stream(self, plan):
        self.calls.append(("plan_stream", plan))
        return self.stream

    def _plan_render(self, plan):
        self.calls.append(("plan_render", plan))
        return self.text


class Env:
    def __init__(self, fields=FIELDS):
        self.stub = Stub()
        schema = pb.WireSchema(fields=[field(n, arrow_id(t), True) for n, t in fields])
        self.sources = {PATH: parquet_source(PATH, schema.SerializeToString())}
        scan = _ops.scan(PATH, "parquet", tuple(Field(n, t) for n, t in fields))
        self.df = DataFrame._new(self.stub, scan, self.sources)


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refuses(call, cls, message):
    e = raised(call)
    assert type(e) is cls and e.args[0] == message, repr(e)


def items(columns, replace=None, extra=()):
    """The items of a projection that keeps `columns`, with `replace` swapped in by name and `extra` appended."""
    replace = replace or {}
    return tuple((n, replace.get(n, ColRef(n))) for n in columns) + tuple(extra)


def setitem(frame, key, value):
    frame[key] = value


def not_literal(what, type_name):
    return f"{what} takes a literal ({LITERALS}) or a Series of the same frame, not a {type_name}"


# --- node structure per verb --------------------------------------------------


def test_a_column_subscript_is_a_series_node_of_its_frame():
    df = Env().df
    s = df["a"]
    assert type(s) is komira.Series and s._node == ColRef("a") and s._frame is df


def test_a_list_or_tuple_subscript_is_a_projection_in_the_given_order():
    df = Env().df
    want = Project(SCAN, (("b", ColRef("b")), ("a", ColRef("a"))))
    assert df[["b", "a"]]._plan == want
    assert df[("b", "a")]._plan == want
    assert df[["b", "a"]].columns == ["b", "a"]
    assert df[list(COLS)]._plan == SCAN


def test_a_boolean_subscript_is_a_filter_and_a_function_of_the_frame_is_called():
    df = Env().df
    assert df[df["a"] > 1]._plan == Filter(SCAN, GT_A1)
    assert df[lambda d: d["a"] > 1]._plan == Filter(SCAN, GT_A1)
    assert df[df["a"].isin([])]._plan == Filter(SCAN, Lit(False))


def test_filter_select_and_assign_over_a_sorted_frame_go_under_the_sort():
    ds = Env().df.sort_values("a")
    assert ds._plan == Sort(SCAN, K_A)
    assert ds[ds["b"] > 1]._plan == Sort(Filter(SCAN, GT_B1), K_A)
    assert ds[["a", "b"]]._plan == Sort(Project(SCAN, items(("a", "b"))), K_A)
    z = Arith("mul", ColRef("x"), Cast(Lit(2), "float64"))
    assert ds.assign(z=ds["x"] * 2)._plan == Sort(Project(SCAN, items(COLS, extra=(("z", z),))), K_A)
    assert ds.assign()._plan == ds._plan


def test_a_select_that_drops_a_sort_key_or_an_assign_that_replaces_one_leaves_the_sort_below():
    ds = Env().df.sort_values("a")
    assert ds[["b", "n"]]._plan == Project(Sort(SCAN, K_A), items(("b", "n")))
    plus = Arith("add", ColRef("a"), Lit(1))
    assert ds.assign(a=ds["a"] + 1)._plan == Project(Sort(SCAN, K_A), items(COLS, replace={"a": plus}))


def test_head_is_a_limit_and_head_zero_builds_a_limit_of_zero():
    df = Env().df
    assert df.head(3)._plan == Limit(SCAN, 3)
    assert df.head()._plan == Limit(SCAN, 5)
    assert df.head(0)._plan == Limit(SCAN, 0)
    assert df.sort_values("a").head(3)._plan == Limit(Sort(SCAN, K_A), 3)


def test_sort_values_directions_and_null_placement():
    df = Env().df

    def keys(**kw):
        by = kw.pop("by", "a")
        return df.sort_values(by, **kw)._plan

    assert keys() == Sort(SCAN, (SortKey("a", descending=False, nulls_first=False),))
    assert keys(ascending=False) == Sort(SCAN, (SortKey("a", descending=True, nulls_first=False),))
    assert keys(na_position="first") == Sort(SCAN, (SortKey("a", descending=False, nulls_first=True),))
    assert keys(na_position="last", ascending=False) == Sort(SCAN, (SortKey("a", descending=True, nulls_first=False),))
    two = Sort(SCAN, (SortKey("a", descending=False, nulls_first=True), SortKey("b", descending=True, nulls_first=True)))
    assert keys(by=["a", "b"], ascending=[True, False], na_position="first") == two
    assert keys(by=("a", "b"), ascending=(True, False), na_position="first") == two
    plain = Sort(SCAN, K_A)
    for extra in ({"axis": "index"}, {"axis": 0}, {"kind": "quicksort"}, {"kind": "heapsort"}, {"ignore_index": True}):
        assert keys(**extra) == plain, extra


def test_sort_values_on_a_sorted_frame_replaces_the_sort_and_over_a_limit_sorts_the_limit():
    ds = Env().df.sort_values("a")
    assert ds.sort_values("b")._plan == Sort(SCAN, (SortKey("b"),))
    top = ds.head(3)
    assert top.sort_values("b")._plan == Sort(Limit(Sort(SCAN, K_A), 3), (SortKey("b"),))


def test_a_verb_that_keeps_the_order_after_head_over_a_sort_sorts_again_above_the_limit():
    top = Env().df.sort_values("a").head(3)
    limit = top._plan
    assert limit == Limit(Sort(SCAN, K_A), 3)
    filtered = top[top["b"] > 1]
    assert filtered._plan == Sort(Filter(limit, GT_B1), K_A)
    assert filtered[filtered["n"] > 0]._plan == Sort(
        Filter(Filter(limit, GT_B1), Compare("gt", ColRef("n"), Cast(Lit(0), "int32"))), K_A
    )
    assert top[["b", "a"]]._plan == Sort(Project(limit, items(("b", "a"))), K_A)
    z = Arith("mul", ColRef("a"), Lit(2))
    assert top.assign(z=top["a"] * 2)._plan == Sort(Project(limit, items(COLS, extra=(("z", z),))), K_A)
    assert top[list(COLS)]._plan == limit
    assert top.assign()._plan == limit


def test_a_verb_that_drops_a_key_after_head_over_a_sort_adds_no_sort():
    top = Env().df.sort_values("a").head(3)
    limit = top._plan
    assert top[["b", "n"]]._plan == Project(limit, items(("b", "n")))
    plus = Arith("add", ColRef("a"), Lit(1))
    assert top.assign(a=top["a"] + 1)._plan == Project(limit, items(COLS, replace={"a": plus}))


def test_assign_keeps_a_replaced_column_in_place_appends_new_ones_and_builds_one_projection():
    df = Env().df
    plus = Arith("add", ColRef("a"), Lit(1))
    times = Arith("mul", ColRef("x"), Cast(Lit(2), "float64"))
    out = df.assign(a=df["a"] + 1, z=df["x"] * 2, k=5)
    assert out._plan == Project(SCAN, items(COLS, replace={"a": plus}, extra=(("z", times), ("k", Lit(5)))))
    assert out.columns == list(COLS) + ["z", "k"]
    assert df.assign(k="u")._plan == Project(SCAN, items(COLS, extra=(("k", Lit("u")),)))
    assert df.assign()._plan == SCAN


def test_assign_with_a_function_sees_the_earlier_keywords():
    df = Env().df
    doubled = Arith("mul", ColRef("a"), Lit(2))
    out = df.assign(a2=df["a"] * 2, b=lambda d: d["a2"] + 1)
    plus = Arith("add", doubled, Lit(1))
    assert out._plan == Project(SCAN, items(COLS, replace={"b": plus}, extra=(("a2", doubled),)))
    assert df.assign(k=lambda d: 7)._plan == Project(SCAN, items(COLS, extra=(("k", Lit(7)),)))


def test_a_series_given_to_assign_reads_the_original_column_and_a_function_reads_the_new_one():
    df = Env().df
    plus = Arith("add", ColRef("a"), Lit(1))
    by_series = df.assign(a=df["a"] + 1, c=df["a"] * 2)
    assert by_series._plan == Project(
        SCAN, items(COLS, replace={"a": plus}, extra=(("c", Arith("mul", ColRef("a"), Lit(2))),))
    )
    by_function = df.assign(a=df["a"] + 1, c=lambda d: d["a"] * 2)
    assert by_function._plan == Project(
        SCAN, items(COLS, replace={"a": plus}, extra=(("c", Arith("mul", plus, Lit(2))),))
    )


def test_setting_a_column_equals_assign_in_place_and_makes_earlier_series_stale():
    env = Env()
    df, base = env.df, env.df.copy()
    s = df["a"]
    df["a"] = df["a"] + 1
    assert df._plan == base.assign(a=base["a"] + 1)._plan
    refuses(lambda: df.assign(z=s), UnsupportedOperation, STALE)
    refuses(lambda: df[s], UnsupportedOperation, STALE)
    refuses(lambda: s + 1, UnsupportedOperation, STALE)
    refuses(lambda: -s, UnsupportedOperation, STALE)
    refuses(lambda: ~s, UnsupportedOperation, STALE)
    refuses(lambda: s.isin([1]), UnsupportedOperation, STALE)
    refuses(lambda: s.dtype, UnsupportedOperation, STALE)
    assert repr(s) == "<komira.Series (stale)>"
    assert df["a"].dtype == "int64" and repr(df["a"]) == "<komira.Series dtype=int64>"
    df["z"] = lambda d: d["a"] * 2
    assert df._plan == base.assign(a=base["a"] + 1).assign(z=lambda d: d["a"] * 2)._plan
    df["k"] = 5
    assert df.columns == list(COLS) + ["z", "k"] and df.dtypes["k"] == "int64"


def test_a_refused_assignment_leaves_the_frame_and_its_series_as_they_were():
    env = Env()
    df, other = env.df, Env().df
    s, plan = df["a"], df._plan
    refuses(lambda: setitem(df, "z", other["a"]), UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: setitem(df, "z", object()), TypeError, not_literal("assign()", "object"))
    assert df._plan == plan and s.dtype == "int64"


WIDE_FIELDS = (
    ("i8", "int8"), ("i16", "int16"), ("i32", "int32"), ("i64", "int64"),
    ("u8", "uint8"), ("u16", "uint16"), ("u32", "uint32"), ("u64", "uint64"),
    ("f32", "float32"), ("f64", "float64"), ("s", "string"), ("ok", "bool"),
)


def test_every_widening_rule_of_two_numeric_columns():
    df = Env(WIDE_FIELDS).df
    c = ColRef

    def cast(name, to):
        return Cast(c(name), to)

    # Two signed or two unsigned integers: the wider; computed in int64 and
    # cast back when that type is narrower than 64 bits.
    assert (df["i8"] + df["i16"])._node == Cast(Arith("add", cast("i8", "int64"), cast("i16", "int64")), "int16")
    assert (df["i32"] + df["i64"])._node == Arith("add", cast("i32", "int64"), c("i64"))
    assert (df["u8"] * df["u32"])._node == Cast(Arith("mul", cast("u8", "int64"), cast("u32", "int64")), "uint32")
    assert (df["u64"] - df["u8"])._node == Arith("sub", c("u64"), cast("u8", "uint64"))
    # A signed and an unsigned one: the next signed type holding both.
    assert (df["i16"] + df["u16"])._node == Cast(Arith("add", cast("i16", "int64"), cast("u16", "int64")), "int32")
    assert (df["i32"] > df["u32"])._node == Compare("gt", cast("i32", "int64"), cast("u32", "int64"))
    assert (df["i8"] == df["u8"])._node == Compare("eq", cast("i8", "int16"), cast("u8", "int16"))
    # uint64 with a signed type has no common integer type: left as it is,
    # for the engine to answer or refuse.
    assert (df["u64"] + df["i64"])._node == Arith("add", c("u64"), c("i64"))
    # Floats: float64 wins; an integer meeting float32 is float32, computed in
    # float64 and cast back.
    assert (df["f32"] + df["f64"])._node == Arith("add", cast("f32", "float64"), c("f64"))
    assert (df["i64"] * df["f32"])._node == Cast(Arith("mul", cast("i64", "float64"), cast("f32", "float64")), "float32")
    assert (df["f32"] * df["f32"])._node == Cast(Arith("mul", cast("f32", "float64"), cast("f32", "float64")), "float32")
    assert (df["f32"] < df["i8"])._node == Compare("lt", c("f32"), cast("i8", "float32"))
    # A non-numeric operand is never widened.
    assert (df["s"] == df["s"])._node == Compare("eq", c("s"), c("s"))
    assert (df["ok"] == df["i8"])._node == Compare("eq", c("ok"), c("i8"))
    # The types of the answers.
    for expr, want in (
        (df["i8"] + df["i16"], "int16"), (df["u8"] * df["u32"], "uint32"), (df["i16"] + df["u16"], "int32"),
        (df["i64"] * df["f32"], "float32"), (df["f32"] + df["f64"], "float64"), (df["i8"] / df["i8"], "float64"),
        (-df["i32"], "int32"), (df["u8"] + 1, "uint8"), (df["u8"] - 1, "uint8"), (df["u8"] + -1, "int64"),
    ):
        assert expr.dtype == want, (repr(expr), want)


def test_an_unsigned_or_narrow_column_takes_the_int_literals_that_fit_it():
    df = Env(WIDE_FIELDS).df
    c = ColRef
    assert (df["u8"] + 1)._node == Cast(Arith("add", Cast(c("u8"), "int64"), Lit(1)), "uint8")
    assert (df["u8"] - 1)._node == Cast(Arith("sub", Cast(c("u8"), "int64"), Lit(1)), "uint8")
    # -1 does not fit uint8: the column meets the literal's int64 as a signed
    # and an unsigned type do.
    assert (df["u8"] + -1)._node == Arith("add", Cast(c("u8"), "int64"), Lit(-1))
    assert (df["u8"] > -1)._node == Compare("gt", Cast(c("u8"), "int64"), Lit(-1))
    assert (df["i8"] < 127)._node == Compare("lt", c("i8"), Cast(Lit(127), "int8"))
    assert (df["i8"] < 128)._node == Compare("lt", Cast(c("i8"), "int64"), Lit(128))
    # A literal above int64 is uint64 already.
    assert (df["u64"] == 2**64 - 1)._node == Compare("eq", c("u64"), Lit(2**64 - 1))
    assert (df["f32"] * 2)._node == Cast(Arith("mul", Cast(c("f32"), "float64"), Cast(Lit(2), "float64")), "float32")


def test_isin_widens_each_value_as_a_comparison_does():
    df = Env().df
    n, x, s = ColRef("n"), ColRef("x"), ColRef("s")
    assert df["n"].isin([1, 3_000_000_000])._node == BoolOp(
        "or", Compare("eq", n, Cast(Lit(1), "int32")), Compare("eq", Cast(n, "int64"), Lit(3_000_000_000))
    )
    assert df["x"].isin([1, 2.5])._node == BoolOp(
        "or", Compare("eq", x, Cast(Lit(1), "float64")), Compare("eq", x, Lit(2.5))
    )
    assert df["s"].isin(["a"])._node == Compare("eq", s, Lit("a"))


def test_a_head_of_a_head_is_one_limit_that_keeps_the_order():
    df = Env().df
    ds = df.sort_values("a")
    assert ds.head(9).head(6)._plan == Limit(Sort(SCAN, K_A), 6)
    assert ds.head(3).head(6)._plan == Limit(Sort(SCAN, K_A), 3)
    assert df.head(4).head(2)._plan == Limit(SCAN, 2)
    twice = ds.head(9).head(6)
    assert twice[twice["b"] > 1]._plan == Sort(Filter(Limit(Sort(SCAN, K_A), 6), GT_B1), K_A)


def test_division_casts_the_left_to_float64_only_when_both_sides_are_integers():
    df = Env().df
    a, b, n, x = ColRef("a"), ColRef("b"), ColRef("n"), ColRef("x")
    to_f = lambda node: Cast(node, "float64")
    # The left of an integer division is cast to float64; the right is then
    # widened to it, as any integer meeting a float64 is.
    assert (df["a"] / df["b"])._node == Arith("div", to_f(a), to_f(b))
    assert (df["a"] / 2)._node == Arith("div", to_f(a), to_f(Lit(2)))
    assert (df["n"] / df["a"])._node == Arith("div", to_f(n), to_f(a))
    assert (2 / df["a"])._node == Arith("div", to_f(Lit(2)), to_f(a))
    # A float operand makes it true division already: only the integer side is widened.
    assert (df["a"] / 2.0)._node == Arith("div", to_f(a), Lit(2.0))
    assert (df["x"] / 2)._node == Arith("div", x, to_f(Lit(2)))
    assert (df["x"] / df["a"])._node == Arith("div", x, to_f(a))
    assert (df["a"] / df["x"])._node == Arith("div", to_f(a), x)
    assert (2 / df["x"])._node == Arith("div", to_f(Lit(2)), x)
    assert (df["x"] / df["x"])._node == Arith("div", x, x)


def test_numeric_operands_are_widened_to_one_type():
    df = Env().df
    a, n, x = ColRef("a"), ColRef("n"), ColRef("x")
    # Two integer columns of different widths: the narrower is cast to the wider.
    assert (df["a"] + df["n"])._node == Arith("add", a, Cast(n, "int64"))
    assert (df["n"] - df["a"])._node == Arith("sub", Cast(n, "int64"), a)
    assert (df["a"] > df["n"])._node == Compare("gt", a, Cast(n, "int64"))
    # An integer column meeting a float64 one is cast to float64.
    assert (df["a"] * df["x"])._node == Arith("mul", Cast(a, "float64"), x)
    assert (df["x"] <= df["n"])._node == Compare("le", x, Cast(n, "float64"))
    # Equal types and non-numeric types are left as they are.
    assert (df["a"] + df["b"])._node == Arith("add", a, ColRef("b"))
    assert (df["s"] == "u")._node == Compare("eq", ColRef("s"), Lit("u"))


def test_an_integer_literal_takes_the_type_of_the_integer_operand_it_fits():
    df = Env().df
    a, n, x = ColRef("a"), ColRef("n"), ColRef("x")
    assert (2 * df["a"])._node == Arith("mul", Lit(2), a)
    assert (df["a"] * 2)._node == Arith("mul", a, Lit(2))
    # An operator over int32 is computed in int64, which the engine's
    # arithmetic runs on, and cast back to int32.
    n64 = Cast(n, "int64")
    assert (10 - df["n"])._node == Cast(Arith("sub", Lit(10), n64), "int32")
    assert (df["n"] * 2)._node == Cast(Arith("mul", n64, Lit(2)), "int32")
    assert (df["n"] * df["n"])._node == Cast(Arith("mul", n64, n64), "int32")
    assert (df["n"] / df["n"])._node == Arith("div", Cast(n, "float64"), Cast(n, "float64"))
    assert (df["n"] > 30)._node == Compare("gt", n, Cast(Lit(30), "int32"))
    assert df["n"].isin([1])._node == Compare("eq", n, Cast(Lit(1), "int32"))
    # A literal outside the column's range widens the column instead.
    assert (df["n"] + 3_000_000_000)._node == Arith("add", Cast(n, "int64"), Lit(3_000_000_000))
    assert (df["n"] < -(2**31) - 1)._node == Compare("lt", Cast(n, "int64"), Lit(-(2**31) - 1))
    assert (df["n"] + (2**31 - 1))._node == Cast(Arith("add", n64, Lit(2**31 - 1)), "int32")
    # Against a float column an int literal is widened to float64, and a float
    # literal against an integer column widens the column.
    assert (2 * df["x"])._node == Arith("mul", Cast(Lit(2), "float64"), x)
    assert (1.5 * df["a"])._node == Arith("mul", Lit(1.5), Cast(a, "float64"))


def test_arithmetic_and_negation_build_arith_and_unary_nodes():
    df = Env().df
    a, b = ColRef("a"), ColRef("b")
    for op, fn in (("add", operator.add), ("sub", operator.sub), ("mul", operator.mul)):
        assert fn(df["a"], df["b"])._node == Arith(op, a, b), op
        assert fn(df["x"], 1.5)._node == Arith(op, ColRef("x"), Lit(1.5)), op
    assert (-df["a"])._node == Unary("negate", a)


def test_comparisons_build_compare_nodes_and_a_literal_on_the_left_reflects():
    df = Env().df
    for op, fn in (("eq", operator.eq), ("ne", operator.ne), ("lt", operator.lt),
                   ("le", operator.le), ("gt", operator.gt), ("ge", operator.ge)):
        assert fn(df["a"], 1)._node == Compare(op, ColRef("a"), Lit(1)), op
        assert fn(df["a"], df["b"])._node == Compare(op, ColRef("a"), ColRef("b")), op
    assert (df["s"] == "u")._node == Compare("eq", ColRef("s"), Lit("u"))
    assert (1 < df["a"])._node == Compare("gt", ColRef("a"), Lit(1))


def test_boolean_operators_build_bool_ops_and_a_boolean_column_is_compared_to_true():
    df = Env().df
    gt, lt = df["a"] > 1, df["b"] < 5
    lt_b5 = Compare("lt", ColRef("b"), Lit(5))
    is_ok = Compare("eq", ColRef("ok"), Lit(True))
    assert (gt & lt)._node == BoolOp("and", GT_A1, lt_b5)
    assert (gt | lt)._node == BoolOp("or", GT_A1, lt_b5)
    assert (~gt)._node == Unary("not", GT_A1)
    assert (True & gt)._node == BoolOp("and", Lit(True), GT_A1)
    assert (gt | False)._node == BoolOp("or", GT_A1, Lit(False))
    assert (False | gt)._node == BoolOp("or", Lit(False), GT_A1)
    assert (df["ok"] & gt)._node == BoolOp("and", is_ok, GT_A1)
    assert (gt | df["ok"])._node == BoolOp("or", GT_A1, is_ok)
    assert (~df["ok"])._node == Unary("not", is_ok)
    assert df[df["ok"]]._plan == Filter(SCAN, is_ok)
    assert (df["ok"] & gt).dtype == "bool" and (~gt).dtype == "bool"


def test_isin_builds_an_or_chain_of_equalities_and_an_empty_list_is_false():
    df = Env().df
    eq = lambda v: Compare("eq", ColRef("a"), Lit(v))
    assert df["a"].isin([1])._node == eq(1)
    assert df["a"].isin([1, 2, 3])._node == BoolOp("or", BoolOp("or", eq(1), eq(2)), eq(3))
    assert df["a"].isin((1, 2))._node == BoolOp("or", eq(1), eq(2))
    empty = df["a"].isin([])
    assert empty._node == Lit(False) and empty.dtype == "bool"
    many = df["a"].isin(list(range(_ops.IN_LIST_MAX)))
    assert len(_ops.column_refs(many._node)) == _ops.IN_LIST_MAX and many.dtype == "bool"


# --- types ----------------------------------------------------------------------


def test_columns_dtypes_and_repr_of_a_reader_frame():
    df = Env().df
    assert df.columns == list(COLS)
    assert list(df.dtypes.items()) == list(FIELDS)
    assert repr(df) == "<komira.DataFrame a: int64, b: int64, n: int32, x: float64, s: string, ok: bool>"
    assert df._plan == SCAN


def test_dtypes_after_assign_follow_the_engines_types():
    df = Env().df
    out = df.assign(
        q=df["a"] / df["b"], c=df["a"] > 1, d=df["n"] * 2, e=2 * df["n"], f=df["a"] + df["x"],
        g=-df["a"], h=df["a"] / 2.0, i=df["s"] == "u", big=df["n"] + 3_000_000_000,
        k=5, y=1.5, w="u", t=True,
    )
    assert list(out.dtypes.items()) == list(FIELDS) + [
        ("q", "float64"), ("c", "bool"), ("d", "int32"), ("e", "int32"), ("f", "float64"),
        ("g", "int64"), ("h", "float64"), ("i", "bool"), ("big", "int64"),
        ("k", "int64"), ("y", "float64"), ("w", "string"), ("t", "bool"),
    ]
    assert out.columns == list(out.dtypes)


def test_dtypes_after_the_other_verbs():
    df = Env().df
    assert list(df[["s", "a"]].dtypes.items()) == [("s", "string"), ("a", "int64")]
    for out in (df[df["a"] > 1], df.sort_values("a"), df.head(2), df.sort_values("a").head(2)):
        assert list(out.dtypes.items()) == list(FIELDS)
    df["x"] = df["a"] * 2
    assert df.dtypes["x"] == "int64" and repr(df) == (
        "<komira.DataFrame a: int64, b: int64, n: int32, x: int64, s: string, ok: bool>"
    )


def test_series_dtype_and_repr():
    df = Env().df
    for expr, name in ((df["a"], "int64"), (df["n"], "int32"), (df["s"], "string"), (df["ok"], "bool"),
                       (df["a"] / df["b"], "float64"), (df["a"] > 1, "bool"), (df["a"].isin([1]), "bool"),
                       (df["n"] * 2, "int32")):
        assert expr.dtype == name, name
        assert repr(expr) == f"<komira.Series dtype={name}>"


# --- refusals ---------------------------------------------------------------------


def test_a_series_of_another_frame_is_refused_wherever_it_is_used():
    df, other = Env().df, Env().df
    o = other["a"]
    refuses(lambda: df[o > 1], UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: df.assign(z=o), UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: df["a"] + o, UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: df["a"] == o, UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: (df["a"] > 1) & (o > 1), UnsupportedOperation, OTHER_FRAME)
    refuses(lambda: df.copy()[df["a"] > 1], UnsupportedOperation, OTHER_FRAME)


def test_subscripts_a_frame_does_not_take():
    df = Env().df
    refuses(
        lambda: df[1:2], UnsupportedOperation,
        "df[start:stop] selects rows by position, and a komira frame has no row positions: "
        "sort with sort_values(...) and take rows with head(n)",
    )
    refuses(lambda: df[0], KeyError,
            "no column labelled 0: a komira frame's column names are str; the frame's columns are: " + LISTED)
    refuses(lambda: df[True], KeyError,
            "no column labelled True: a komira frame's column names are str; the frame's columns are: " + LISTED)
    for key, name in ((1.5, "float"), (None, "NoneType"), ({"a"}, "set")):
        refuses(
            lambda: df[key], TypeError,
            "a komira DataFrame is subscripted with a column name, a list of names or a boolean Series, "
            f"not a {name}",
        )
    refuses(lambda: df[[1]], TypeError, "df[[...]] takes column names, which are str, not int")
    refuses(lambda: df[["a", None]], TypeError, "df[[...]] takes column names, which are str, not NoneType")
    refuses(lambda: df[[]], ValueError, "select needs at least one column")
    refuses(lambda: df[["a", "a"]], ValueError, "Project: the output name 'a' appears more than once")
    refuses(lambda: df[df["a"]], TypeError, "a condition must be a boolean Series, and this one is int64")
    refuses(lambda: df[lambda d: d["x"]], TypeError, "a condition must be a boolean Series, and this one is float64")


def test_unknown_columns_are_a_key_error_at_the_verb_that_names_them():
    df = Env().df
    plain = "no column named 'zzz' in this frame; the frame's columns are: " + LISTED
    close = "no column named 'okk' in this frame; the closest is 'ok'; the frame's columns are: " + LISTED
    refuses(lambda: df["zzz"], KeyError, plain)
    refuses(lambda: df["okk"], KeyError, close)
    refuses(lambda: df[["a", "zzz"]], KeyError, plain)
    refuses(lambda: df.sort_values("zzz"), KeyError, plain)
    refuses(lambda: df.sort_values(["a", "okk"]), KeyError, close)
    refuses(lambda: df.sort_values("a")["zzz"], KeyError, plain)


def test_assignment_subscripts_a_frame_does_not_take():
    df = Env().df
    refuses(
        lambda: setitem(df, df["a"] > 1, 0), UnsupportedOperation,
        "df[cond] = value sets the rows where cond holds, which needs the rows in place: "
        'write df["column"] = ... with a value that chooses per row',
    )
    refuses(lambda: setitem(df, 1, 0), TypeError, "df[name] = value takes one column name, a str, not a int")
    refuses(lambda: setitem(df, ["a"], 0), TypeError, "df[name] = value takes one column name, a str, not a list")
    refuses(lambda: setitem(df, "z", [1, 2]), TypeError, not_literal("assign()", "list"))


def test_sort_values_refusals():
    df = Env().df
    refuses(lambda: df.sort_values("a", axis=1), UnsupportedOperation,
            "sort_values(axis=1) sorts columns, and a plan sorts rows: use axis=0")
    refuses(lambda: df.sort_values("a", axis="columns"), UnsupportedOperation,
            "sort_values(axis='columns') sorts columns, and a plan sorts rows: use axis=0")
    refuses(lambda: df.sort_values("a", inplace=True), UnsupportedOperation,
            "sort_values(inplace=True) changes the frame in place, and komira frames do not change: "
            "use the frame sort_values returns")
    for kind in ("stable", "mergesort"):
        refuses(lambda: df.sort_values("a", kind=kind), UnsupportedOperation,
                f"sort_values(kind='{kind}') asks for a stable sort, and no sort in a plan is stable: "
                "add a column that breaks the ties to by=")
    refuses(lambda: df.sort_values("a", kind="radix"), ValueError,
            "sort_values kind must be 'quicksort', 'heapsort', 'mergesort' or 'stable', not 'radix'")
    refuses(lambda: df.sort_values("a", key=len), UnsupportedOperation,
            "sort_values(key=...) calls a Python function on the columns, which a plan cannot: "
            "assign the sort key as a column with assign(), then sort by it")
    refuses(lambda: df.sort_values(["a", "b"], ascending=[True]), ValueError,
            "Length of ascending (1) != length of by (2)")
    refuses(lambda: df.sort_values("a", ascending=[True, False]), ValueError,
            "Length of ascending (2) != length of by (1)")
    refuses(lambda: df.sort_values("a", na_position="middle"), ValueError, "invalid na_position: middle")
    for by in ([], (), 5, None):
        refuses(lambda: df.sort_values(by), TypeError,
                "sort_values by must be a column name or a non-empty list of names")
    refuses(lambda: df.sort_values(["a", 1]), TypeError, "sort_values by takes column names, which are str, not int")
    refuses(lambda: df.sort_values("a", ignore_index=1), TypeError, "sort_values ignore_index must be a bool, not int")
    for bad in (1, None, [1], "yes"):
        refuses(lambda: df.sort_values("a", ascending=bad), TypeError,
                "sort_values ascending must be a bool or a list of bools")


def test_head_refusals_and_boundaries():
    df = Env().df
    for n in (-1, -3):
        refuses(lambda: df.head(n), UnsupportedOperation,
                f"head({n}) keeps all rows but the last {-n}, which needs the row count: "
                "sort with sort_values(...) and take the rows you want with head(k)")
    for bad, name in (("3", "str"), (True, "bool"), (2.0, "float"), (None, "NoneType")):
        refuses(lambda: df.head(bad), TypeError, f"head(n) takes an int, not {name}")
    assert df.head(0)._plan == Limit(SCAN, 0)


def test_isin_refusals():
    df = Env().df
    refuses(lambda: (df["a"] + 1).isin(df["b"]), UnsupportedOperation,
            "isin() with a Series takes a column of the frame, and this Series is an expression: "
            'assign it as a column first, as df.assign(x=...), then take df["x"]')
    refuses(lambda: df["a"].isin({1, 2}), TypeError, "isin() takes a list or tuple of values, not a set")
    refuses(lambda: df["a"].isin(list(range(65))), UnsupportedOperation,
            "isin() takes at most 64 values, and was given 65")
    refuses(lambda: df["a"].isin([1, object()]), TypeError, not_literal("isin()", "object"))


def test_a_literal_of_an_unsupported_type_is_refused_in_assign_and_in_operators():
    df = Env().df
    refuses(lambda: df.assign(k=object()), TypeError, not_literal("assign()", "object"))
    refuses(lambda: df.assign(k=lambda d: object()), TypeError, not_literal("assign()", "object"))
    refuses(lambda: df["a"] + object(), TypeError, not_literal("a komira Series", "object"))
    refuses(lambda: object() + df["a"], TypeError, not_literal("a komira Series", "object"))
    refuses(lambda: df["a"] == object(), TypeError, not_literal("a komira Series", "object"))


def test_boolean_operators_refuse_what_is_not_boolean():
    df = Env().df
    cond = df["a"] > 1
    refuses(lambda: cond & 1, TypeError, "& and | combine boolean Series (or True and False), not a int")
    refuses(lambda: cond | "u", TypeError, "& and | combine boolean Series (or True and False), not a str")
    not_bool = "a condition must be a boolean Series, and this one is int64"
    refuses(lambda: cond & df["a"], TypeError, not_bool)
    refuses(lambda: df["a"] | cond, TypeError, not_bool)
    refuses(lambda: ~df["a"], TypeError, not_bool)


def test_a_frame_and_a_series_cannot_be_constructed():
    message = "a komira DataFrame is made by a reader, such as komira.read_parquet(path)"
    refuses(lambda: komira.DataFrame(), TypeError, message)
    refuses(lambda: komira.DataFrame(1, x=2), TypeError, message)
    series = 'a komira Series is taken from a frame: df["column"]'
    refuses(lambda: komira.Series(), TypeError, series)
    refuses(lambda: komira.Series(1, x=2), TypeError, series)
    assert type(raised(lambda: hash(Env().df["a"]))) is TypeError


# --- attribute rules ----------------------------------------------------------------


def check_refused(obj, name, message, label):
    e = raised(lambda: getattr(obj, name))
    assert type(e) is AttributeError and e.args[0] == message, (label, name, repr(e))
    assert e.name == name, (label, name)
    assert not hasattr(obj, name), (label, name)


def test_every_name_in_the_frame_table_raises_its_message_on_a_frame():
    df = Env().df
    assert len(_refusals.FRAME) > 40
    for name, message in _refusals.FRAME.items():
        check_refused(df, name, message.format(name=name), "frame")
    check_refused(df, "loc", ".loc selects by index label or position, and komira frames have no index: "
                  "filter with df[pred], or sort_values(...).head(n)", "frame")
    check_refused(df, "to_pandas", "a komira DataFrame is a plan: run it with .materialize(), "
                  "then call .to_pandas() on the Result", "frame")
    check_refused(df, "join", "DataFrame.join joins on the index, which komira frames do not have; "
                  "use merge(other, on=...)", "frame")


def test_every_name_in_the_series_table_raises_its_message_on_a_series():
    s = Env().df["a"]
    assert len(_refusals.SERIES) > 20
    for name, message in _refusals.SERIES.items():
        check_refused(s, name, message.format(name=name), "series")
    check_refused(s, "cat", "the .cat accessor is not supported: komira has no categorical or sparse dtype", "series")
    check_refused(s, "values", ".values needs the rows: run the frame with materialize(), "
                  "then convert the Result with to_pandas()", "series")
    assert "join" not in _refusals.SERIES


def test_every_name_in_the_module_table_raises_its_message_on_the_module():
    assert len(_refusals.MODULE) > 8
    for name, message in _refusals.MODULE.items():
        check_refused(komira, name, message.format(name=name), "module")
    check_refused(komira, "Index", "komira frames have no index", "module")
    check_refused(komira, "melt", "komira.melt() is not supported yet: the plan has no node for it", "module")
    check_refused(komira, "nothing_here", "module 'komira' has no attribute 'nothing_here'", "module")
    check_refused(komira, "_nothing_here", "module 'komira' has no attribute '_nothing_here'", "module")


def test_a_name_in_no_table_gets_pythons_own_message():
    env = Env()
    check_refused(env.df, "nothing_here", "'DataFrame' object has no attribute 'nothing_here'", "frame")
    check_refused(env.df, "_nothing_here", "'DataFrame' object has no attribute '_nothing_here'", "frame")
    check_refused(env.df["a"], "nothing_here", "'Series' object has no attribute 'nothing_here'", "series")
    check_refused(env.df["a"], "count", "'Series' object has no attribute 'count'", "series")
    check_refused(env.df["a"], "_nothing_here", "'Series' object has no attribute '_nothing_here'", "series")
    for name in ("_repr_mimebundle_", "_ipython_display_", "__array_interface__", "__array_struct__"):
        assert not hasattr(env.df, name), name
        assert not hasattr(env.df["a"], name), name
    # A frame's notebook display is its names and types (test_display.py); a
    # Series has none.
    assert not hasattr(env.df["a"], "_repr_html_")


def test_a_column_is_not_an_attribute_and_a_column_named_count_is_reached_by_subscript():
    df = Env((("zeta", "int64"), ("count", "int64"), ("index", "int64"), ("_hidden", "int64"))).df
    hint = "'DataFrame' object has no attribute '{0}': a column is not an attribute; write df[\"{0}\"]"
    check_refused(df, "zeta", hint.format("zeta"), "frame")
    check_refused(df, "index", "komira frames have no index", "frame")
    check_refused(df, "_hidden", "'DataFrame' object has no attribute '_hidden'", "frame")
    assert df["count"]._node == ColRef("count") and df["count"].dtype == "int64"
    assert "count" in df and "zeta" in df
    assert not {"zeta", "index", "_hidden"} & set(dir(df))
    # The verb is not hidden by the column of its name: df.count() counts the
    # values of every column, the column `count` among them.
    counted = df.count()
    assert counted.columns == ["zeta", "count", "index", "_hidden"], counted.columns
    assert counted._plan == _ops.aggregate(
        df._plan, (), tuple((c, _ops.Agg("count", (ColRef(c),))) for c in ("zeta", "count", "index", "_hidden"))
    )
    check_refused(Env().df, "a", hint.format("a"), "frame")


def test_a_pandas_verb_komira_lacks_raises_and_is_never_a_column():
    missing = object()
    df = Env().df
    for name in ("clip", "combine_first"):
        check_refused(df, name, f"'DataFrame' object has no attribute '{name}'", "frame")
        check_refused(df["a"], name, f"'Series' object has no attribute '{name}'", "series")
        assert getattr(df, name, missing) is missing, name
        assert getattr(df["a"], name, missing) is missing, name
    # The frame has fillna and dropna; a Series has neither.
    for name in ("fillna", "dropna"):
        check_refused(df["a"], name, f"'Series' object has no attribute '{name}'", "series")
        assert getattr(df["a"], name, missing) is missing, name
    named = Env((("clip", "float64"), ("combine_first", "int64"))).df
    hint = "'DataFrame' object has no attribute '{0}': a column is not an attribute; write df[\"{0}\"]"
    for name in ("clip", "combine_first"):
        check_refused(named, name, hint.format(name), "frame")
        assert getattr(named, name, missing) is missing, name
    assert named["clip"]._node == ColRef("clip") and named["clip"].dtype == "float64"


def test_a_column_named_after_a_verb_leaves_the_verb_in_place():
    named = Env((("fillna", "float64"), ("dropna", "int64"))).df
    # df.fillna and df.dropna are the verbs, never the columns of their names,
    # which are reached by subscript.
    assert named.fillna.__name__ == "fillna" and named.dropna.__name__ == "dropna"
    assert named["fillna"]._node == ColRef("fillna") and named["fillna"].dtype == "float64"
    assert named["dropna"]._node == ColRef("dropna") and named["dropna"].dtype == "int64"
    kept = named.dropna(subset=["dropna"])
    assert kept._plan == _ops.filter_(named._plan, Unary("is_not_null", ColRef("dropna")))


def test_setting_an_attribute_of_a_frame_or_a_series_is_refused():
    df = Env().df
    for name in ("x", "a", "columns"):
        refuses(lambda: setattr(df, name, 1), AttributeError,
                f"cannot set the attribute '{name}' of a komira DataFrame: to set a column, "
                f'write df["{name}"] = ...')
    assert df.columns == list(COLS)
    for name in ("x", "dtype", "_node"):
        refuses(lambda: setattr(df["a"], name, 1), AttributeError,
                f"cannot set the attribute '{name}' of a komira Series: a Series is part of a plan "
                'and does not change; to set a column, write df["name"] = ...')
    assert df["a"]._node == ColRef("a")


def test_copy_gives_an_equal_plan_on_the_same_session_and_sources():
    env = Env()
    df = env.df.sort_values("a").head(2)
    for twin in (df.copy(), df.copy(deep=False), copy.copy(df)):
        assert type(twin) is DataFrame and twin is not df
        assert twin._plan == df._plan and twin._session is env.stub and twin._sources is env.sources
        assert twin.dtypes == df.dtypes


def test_in_is_column_membership():
    df = Env().df
    assert "a" in df and "ok" in df
    assert "zzz" not in df and 0 not in df and None not in df
    assert df._session.calls == []


# --- no dunder runs a query ----------------------------------------------------------


def test_no_dunder_of_a_frame_runs_a_query():
    env = Env()
    df = env.df
    for call, what in (
        (lambda: len(df), "len() of a komira DataFrame"),
        (lambda: bool(df), "the truth value of a komira DataFrame"),
        (lambda: iter(df), "iterating a komira DataFrame"),
        (lambda: list(df), "iterating a komira DataFrame"),
        (lambda: df.__array__(), "converting a komira DataFrame to an array"),
        (lambda: df.__array__("float64", copy=False), "converting a komira DataFrame to an array"),
    ):
        refuses(call, UnsupportedOperation, f"{what} needs a query to run: {TERMINAL}")
    refuses(lambda: df.__arrow_c_stream__(), UnsupportedOperation,
            f"reading a komira DataFrame as Arrow needs a query to run: {TERMINAL}, which exports the Arrow stream")
    refuses(lambda: df.__arrow_c_stream__(None), UnsupportedOperation,
            f"reading a komira DataFrame as Arrow needs a query to run: {TERMINAL}, which exports the Arrow stream")
    assert env.stub.calls == []


def test_no_dunder_of_a_series_runs_a_query():
    env = Env()
    s = env.df["a"]
    no_truth = (
        "a komira Series has no truth value: combine conditions with & and |, each in parentheses, "
        "and filter with df[cond]"
    )
    refuses(lambda: bool(s), UnsupportedOperation, no_truth)
    refuses(lambda: bool(s > 1), UnsupportedOperation, no_truth)
    refuses(lambda: (s > 1) and (s < 5), UnsupportedOperation, no_truth)
    refuses(lambda: len(s), UnsupportedOperation, f"len() of a Series {NO_ROWS}")
    refuses(lambda: iter(s), UnsupportedOperation, f"iterating a Series {NO_ROWS}")
    refuses(lambda: list(s), UnsupportedOperation, f"iterating a Series {NO_ROWS}")
    refuses(lambda: s.__array__(), UnsupportedOperation, f"converting a Series to an array {NO_ROWS}")
    refuses(lambda: s.__array__(None, copy=False), UnsupportedOperation, f"converting a Series to an array {NO_ROWS}")
    refuses(lambda: s.__arrow_c_stream__(), UnsupportedOperation, f"reading a Series as Arrow {NO_ROWS}")
    assert env.stub.calls == []


# --- terminals -------------------------------------------------------------------------


def test_materialize_sends_exactly_the_encoded_plan_bytes_and_returns_the_answer():
    env = Env()
    df = env.df.sort_values("a").head(2)
    want = encode_plan(Limit(Sort(SCAN, K_A), 2), env.sources).SerializeToString()
    assert df.materialize() is env.stub.stream
    assert env.stub.calls == [("plan_stream", want)]
    assert type(env.stub.calls[0][1]) is bytes
    assert df.materialize() is env.stub.stream
    assert env.stub.calls == [("plan_stream", want)] * 2


def test_explain_sends_the_same_bytes_to_the_renderer_each_time():
    env = Env()
    df = env.df[env.df["a"] > 1]
    want = encode_plan(Filter(SCAN, GT_A1), env.sources).SerializeToString()
    assert df.explain() == "rendered plan" and df.explain() == "rendered plan"
    assert env.stub.calls == [("plan_render", want)] * 2
    df.materialize()
    assert env.stub.calls[-1] == ("plan_stream", want)


def test_sort_keys_reach_the_wire_with_pandas_defaults():
    env = Env()
    env.df.sort_values(["a", "b"], ascending=[True, False]).materialize()
    root = pb.WirePlanEnvelope.FromString(env.stub.calls[0][1]).plan
    assert root.WhichOneof("node") == "sort"
    assert list(root.sort.keys) == ["a", "b"]
    assert list(root.sort.descending) == [False, True]
    assert list(root.sort.nulls_first) == [False, False]
    env.df.sort_values("a", na_position="first").materialize()
    root = pb.WirePlanEnvelope.FromString(env.stub.calls[1][1]).plan
    assert list(root.sort.nulls_first) == [True]


# --- no SQL --------------------------------------------------------------------------------


def arms(plan):
    out = []
    while True:
        arm = plan.WhichOneof("node")
        out.append(arm)
        if arm == "scan":
            return out
        plan = getattr(plan, arm).child


def test_a_chain_of_verbs_reaches_the_session_only_as_plan_bytes():
    env = Env()
    assert not hasattr(env.stub, "sql") and not hasattr(env.stub, "sql_stream")
    df = env.df
    c = df[df["a"] > 1]
    c = c.assign(z=c["a"] * 2)
    c = c.sort_values(["z", "b"], ascending=[False, True])
    c = c.head(10)
    c = c[c["b"] > 0]
    c = c[["z", "b", "a"]]
    assert env.stub.calls == []
    keys = (SortKey("z", descending=True), SortKey("b"))
    z = Arith("mul", ColRef("a"), Lit(2))
    limit = Limit(Sort(Project(Filter(SCAN, GT_A1), items(COLS, extra=(("z", z),))), keys), 10)
    want = Sort(Project(Filter(limit, Compare("gt", ColRef("b"), Lit(0))), items(("z", "b", "a"))), keys)
    assert c._plan == want
    c.materialize()
    c.explain()
    assert [name for name, _ in env.stub.calls] == ["plan_stream", "plan_render"]
    for _, arg in env.stub.calls:
        assert isinstance(arg, bytes) and not isinstance(arg, str)
        assert arg == encode_plan(want, env.sources).SerializeToString()
        envelope = pb.WirePlanEnvelope.FromString(arg)
        assert arms(envelope.plan) == ["sort", "project", "filter", "limit", "sort", "project", "filter", "scan"]
        assert [f.name for f in envelope.plan.output_schema.fields] == ["z", "b", "a"]
        assert list(envelope.plan.sort.keys) == ["z", "b"]


FRAME_MODULES = (
    "_frame.py", "_groupby.py", "_series.py", "_refusals.py", "_verbs.py", "_missing.py", "_cast.py", "_accessors.py",
    "_display.py", "_merge.py", "_windows.py", "_write.py", "_resample.py",
)
PRIVATE_SESSION = {"_plan_stream", "_plan_render", "_plan_write", "_parquet_schema", "_csv_binding", "_json_binding"}
ALLOWED_IMPORTS = {
    "__future__:annotations", "collections.abc:Callable", "types:ModuleType", "typing:TYPE_CHECKING",
    ".:_ops", ".:_refusals", ".:_plan", "._errors:UnsupportedOperation", "._series:Series", "._series:operand",
    "._session:Result", "._session:Session", "._session:_local_path", "._session:default_session",
    "._plan:_wire", ".plan.v1:plan_pb2", "._frame:DataFrame", "os", ".:_groupby", "._groupby:GroupBy",
    ".:_merge", ".:_windows", "._series:_Membership", "._windows:Windows", "._windows:merged",
    "._plan._window:window_field", "hashlib",
    ".:_verbs", ".:_cast", ".:_accessors", "._missing:present", "._series:_fits",
    "typing:Any", "re",
    # The notebook display (komira/_display.py): it escapes HTML and formats
    # a result's rows with pyarrow, and reads no stream.
    ".:_display", "html", "collections.abc:Sequence", "pyarrow", "pyarrow.compute",
    ".:_write", "collections.abc:Mapping",
    # DataFrame.resample (komira/_resample.py) builds the bucket and a GroupBy.
    ".:_resample", "._frame:DataFrame", "._groupby:GroupBy",
}


def frame_sources():
    directory = os.path.dirname(komira.__file__)
    out = {}
    for name in FRAME_MODULES:
        with open(os.path.join(directory, name), encoding="utf-8") as f:
            out[name] = f.read()
    return out


def sql_names(source):
    """Every name `source` binds, reads or imports that contains "sql"."""
    found = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Name):
            names = [node.id]
        elif isinstance(node, ast.Attribute):
            names = [node.attr]
        elif isinstance(node, (ast.FunctionDef, ast.ClassDef, ast.AsyncFunctionDef)):
            names = [node.name]
        elif isinstance(node, ast.arg):
            names = [node.arg]
        elif isinstance(node, ast.alias):
            names = [node.name, node.asname or ""]
        elif isinstance(node, ast.keyword):
            names = [node.arg or ""]
        else:
            continue
        found.extend(n for n in names if "sql" in n.lower())
    return found


def import_problems(source):
    """The imports of `source` outside ALLOWED_IMPORTS, as `module:name` ("." for a relative one)."""
    bad = []
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.Import):
            found = [a.name for a in node.names]
        elif isinstance(node, ast.ImportFrom):
            found = [f"{'.' * node.level}{node.module or ''}:{a.name}" for a in node.names]
        else:
            continue
        bad.extend(name for name in found if name not in ALLOWED_IMPORTS)
    return bad


def session_attrs(source):
    """The attributes read off a session (`session`, `x._session`) and every attribute that starts
    with `register_` or contains "sql"."""
    on_session, stray = set(), []
    for node in ast.walk(ast.parse(source)):
        if not isinstance(node, ast.Attribute):
            continue
        value = node.value
        if (isinstance(value, ast.Name) and value.id == "session") or (
            isinstance(value, ast.Attribute) and value.attr == "_session"
        ):
            on_session.add(node.attr)
        if node.attr.startswith("register_") or "sql" in node.attr.lower():
            stray.append(node.attr)
    return on_session, stray


def test_the_frame_modules_import_and_call_nothing_that_reaches_sql_or_the_library():
    sources = frame_sources()
    assert sorted(sources) == sorted(FRAME_MODULES)
    for name, source in sources.items():
        assert sql_names(source) == [], (name, sql_names(source))
        assert import_problems(source) == [], (name, import_problems(source))
        on_session, stray = session_attrs(source)
        assert stray == [] and on_session <= PRIVATE_SESSION, (name, on_session, stray)
    assert session_attrs(sources["_frame.py"])[0] == PRIVATE_SESSION - {"_plan_write"}
    assert session_attrs(sources["_write.py"])[0] == {"_plan_write"}
    assert session_attrs(sources["_series.py"])[0] == set()


def test_the_source_checks_fail_on_sql_entries_a_library_import_and_other_session_calls():
    assert sql_names("session.sql(q)") == ["sql"]
    assert sql_names("lib.komira_sql_stream(ctx, text)") == ["komira_sql_stream"]
    assert sql_names("def to_sql(frame):\n    return frame") == ["to_sql"]
    assert sql_names("run(frame)") == []
    assert import_problems("from ._session import Session, sql_stream") == ["._session:sql_stream"]
    assert import_problems("from ._native import load") == ["._native:load"]
    assert import_problems("import sqlite3") == ["sqlite3"]
    assert import_problems("import ctypes") == ["ctypes"]
    assert import_problems("import os\nfrom ._session import Result") == []
    assert session_attrs("session.sql(q)") == ({"sql"}, ["sql"])
    assert session_attrs("self._session.register_parquet(n, p)") == ({"register_parquet"}, ["register_parquet"])
    assert session_attrs("self._session._live()") == ({"_live"}, [])
    assert session_attrs("session._plan_stream(b)") == ({"_plan_stream"}, [])


# --- readers' argument checks ----------------------------------------------------------------


def test_read_json_needs_lines_true_before_any_library_call():
    message = (
        "read_json(lines={0!r}) reads one JSON document, which komira does not read: "
        "write one object per line and pass lines=True"
    )
    refuses(lambda: komira.read_json(PATH), UnsupportedOperation, message.format(False))
    refuses(lambda: komira.read_json(PATH, lines=False), UnsupportedOperation, message.format(False))
    refuses(lambda: komira.read_json(PATH, lines=1), UnsupportedOperation, message.format(1))
    refuses(lambda: komira.read_json(PATH, lines=None), UnsupportedOperation, message.format(None))


def test_read_csv_header_must_be_infer_zero_or_none_before_any_library_call():
    message = (
        "read_csv(header={0!r}) reads the column names from another line than the first: "
        'use header="infer" (or 0) for names on the first line, or header=None for none'
    )
    for header in (1, True, False, "first", 2.5):
        refuses(lambda: komira.read_csv(PATH, header=header), UnsupportedOperation, message.format(header))


def test_the_readers_refuse_a_session_that_is_not_a_session_before_any_library_call():
    for session in ("x", Stub()):
        name = type(session).__name__
        message = f"session must be a komira Session, not {name}"
        refuses(lambda: komira.read_parquet(PATH, session=session), TypeError, message)
        refuses(lambda: komira.read_csv(PATH, session=session), TypeError, message)
        refuses(lambda: komira.read_csv(PATH, header=None, sep=";", session=session), TypeError, message)
        refuses(lambda: komira.read_json(PATH, lines=True, session=session), TypeError, message)


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
