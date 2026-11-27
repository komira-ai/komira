"""The group-by, the reductions and drop_duplicates of the pandas-shaped
DataFrame (komira/_groupby.py, komira/_frame.py) with no libkomira: a frame
over a Parquet scan whose schema is made here, on a session stand-in that
records the plan bytes it is given. Checked:

- the plan each verb builds, by equality with a hand-built node tree: the
  FILTER of missing keys below the AGGREGATE (dropna=True only), the SORT by
  the keys above it, missing keys last (sort=True only), the CASE that makes a
  sum of nothing 0 (min_count=0 only), the casts of a boolean column, the
  engine aggregate of each pandas reduction (std and var by ddof: 1 is the
  sample aggregate, 0 the population one), and the plans of
  drop_duplicates (a DISTINCT, or for keep=False an AGGREGATE with count = 1);
- the output columns and types of every reduction, grouped and ungrouped, the
  frame's own reductions and `agg` among them;
- the order rules: a group-by over a sorted frame, a head after
  groupby(sort=True), a frame changed by df["x"] = ... after its groupby();
- the wire: the encoded aggregate's functions and the sort's NULL placement;
- every refusal by its class and its full message;
- the GroupBy's attribute rules for every row of its refusal table, and no
  dunder of it runs a query;
- a reduced frame reaches the session only as plan bytes, at its terminal.

The test loads no library. It is of the `plan/` family (python/tests/BUCK), on
the same runtimes as `frame_test`: each supported minor under protobuf 7.36.2
and CPython 3.13 also under 5.29.1 (`frame_groupby_test_protobuf_lower_edge`).

    test_frame_groupby.py
"""

import os
import sys
import tempfile

import komira
from komira import _ops, _refusals
from komira._errors import UnsupportedOperation
from komira._frame import DataFrame
from komira._ops import Agg, Cast, ColRef, Compare, Field, Lit, SortKey, Unary, When
from komira._plan import encode_plan, parquet_source
from komira._plan._wire import arrow_id, field, member, pb

# Never opened: the scan only names the file, and the schema is given here.
PATH = os.path.join(tempfile.gettempdir(), "frame_groupby_test_input.parquet")
FIELDS = (("a", "int64"), ("b", "int64"), ("n", "int32"), ("x", "float64"), ("s", "string"), ("ok", "bool"))
SCAN = _ops.scan(PATH, "parquet", tuple(Field(name, dtype) for name, dtype in FIELDS))
NUMERIC_HINT = "select the columns to reduce first, or pass numeric_only=True to leave it out"
AGG_HINT = "reduce it with min, max, count, nunique or size"
SUPPORTED = "count, max, mean, median, min, nunique, size, std, sum, var"


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


# A bool summed with min_count=0: True is 1, False and a missing value 0.
TRUE_IS_ONE = When(((Compare("eq", ColRef("ok"), Lit(True)), Lit(1)),), Lit(0))


def not_null(*keys):
    return _ops.and_all(tuple(Unary("is_not_null", ColRef(k)) for k in keys))


def zero_if_null(name, zero=Lit(0)):
    return When(((Unary("is_not_null", ColRef(name)), ColRef(name)),), zero)


def agg(func, column=None, arg=None):
    if arg is None and column is not None:
        arg = ColRef(column)
    return Agg(func, () if arg is None else (arg,))


def grouped(child, keys, aggs, sums=(), sort=True, dropna=True, zeros=None):
    """The plan of a pandas group-by: the filter, the aggregate, the zero of each sum, the sort."""
    plan = _ops.filter_(child, not_null(*keys)) if dropna and keys else child
    plan = _ops.aggregate(plan, keys, aggs)
    zeros = zeros or {}
    if sums:
        plan = _ops.with_columns(plan, tuple((s, zero_if_null(s, zeros.get(s, Lit(0)))) for s in sums))
    if sort and keys:
        plan = _ops.sort(plan, tuple(SortKey(k) for k in keys))
    return plan


# --- the plans ------------------------------------------------------------------


def test_groupby_sum_filters_missing_keys_aggregates_makes_empty_sums_zero_and_sorts_by_the_key():
    df = Env().df
    got = df.groupby("a").sum(numeric_only=True)
    aggs = (
        ("b", agg("sum", "b")),
        ("n", agg("sum", "n")),
        ("x", agg("sum", "x")),
        ("ok", agg("sum", arg=TRUE_IS_ONE)),
    )
    assert got._plan == grouped(SCAN, ("a",), aggs, sums=("b", "n", "x", "ok"))
    # The literal 0 of the float sum is a float64 literal on the wire.
    assert got.columns == ["a", "b", "n", "x", "ok"]
    assert got.dtypes == {"a": "int64", "b": "int64", "n": "int64", "x": "float64", "ok": "int64"}


def test_each_reduction_builds_its_engine_aggregate_and_type():
    df = Env().df[["a", "b", "n", "x", "ok"]]
    child = df._plan
    numeric = ("b", "n", "x", "ok")
    as_float = lambda c: Cast(ColRef(c), "float64") if c == "ok" else ColRef(c)  # noqa: E731
    cases = [
        (lambda g: g.mean(), tuple((c, agg("mean", arg=as_float(c))) for c in numeric), "float64"),
        (lambda g: g.median(), tuple((c, agg("median", arg=as_float(c))) for c in numeric), "float64"),
        (lambda g: g.std(), tuple((c, agg("stddev_samp", arg=as_float(c))) for c in numeric), "float64"),
        (lambda g: g.var(), tuple((c, agg("var_samp", arg=as_float(c))) for c in numeric), "float64"),
        (lambda g: g.count(), tuple((c, agg("count", c)) for c in numeric), "int64"),
        (lambda g: g.nunique(), tuple((c, agg("count_distinct", c)) for c in numeric), "int64"),
    ]
    for build, aggs, dtype in cases:
        got = build(df.groupby("a"))
        assert got._plan == grouped(child, ("a",), aggs), got._plan
        assert got.dtypes == {"a": "int64", **{c: dtype for c in numeric}}, got.dtypes
    for how in ("min", "max"):
        got = getattr(df.groupby("a"), how)()
        assert got._plan == grouped(child, ("a",), tuple((c, agg(how, c)) for c in numeric))
        assert got.dtypes == {"a": "int64", "b": "int64", "n": "int32", "x": "float64", "ok": "bool"}
    size = df.groupby("a").size()
    assert size._plan == grouped(child, ("a",), (("size", agg("count")),))
    assert size.dtypes == {"a": "int64", "size": "int64"}


def test_min_max_count_and_nunique_take_every_type_and_numeric_only_leaves_out_the_others():
    df = Env().df
    got = df.groupby("a").min()
    assert got.columns == ["a", "b", "n", "x", "s", "ok"]
    assert got.dtypes["s"] == "string"
    assert df.groupby("a").max(numeric_only=True).columns == ["a", "b", "n", "x", "ok"]
    assert df.groupby("a").nunique().dtypes["s"] == "int64"
    assert df.groupby("a").count().dtypes["s"] == "int64"
    assert df.groupby("a").mean(numeric_only=True).columns == ["a", "b", "n", "x", "ok"]


def test_sort_false_adds_no_sort_and_dropna_false_no_filter():
    df = Env().df
    aggs = (("x", agg("max", "x")),)
    assert df.groupby("a", sort=False)["x"].max()._plan == grouped(SCAN, ("a",), aggs, sort=False)
    assert df.groupby("a", dropna=False)["x"].max()._plan == grouped(SCAN, ("a",), aggs, dropna=False)
    both = df.groupby("a", sort=False, dropna=False)["x"].max()._plan
    assert both == _ops.aggregate(SCAN, ("a",), aggs)
    # as_index has nothing to change: the keys are columns either way.
    assert df.groupby("a", as_index=False)["x"].max()._plan == df.groupby("a")["x"].max()._plan


def test_several_keys_filter_every_key_and_sort_by_each_in_the_given_order():
    df = Env().df
    got = df.groupby(["s", "a"])["x"].mean()
    want = _ops.sort(
        _ops.aggregate(_ops.filter_(SCAN, not_null("s", "a")), ("s", "a"), (("x", agg("mean", "x")),)),
        (SortKey("s"), SortKey("a")),
    )
    assert got._plan == want
    assert got.columns == ["s", "a", "x"]
    assert df.groupby(("s", "a"))["x"].mean()._plan == want


def test_named_dict_string_and_list_forms_of_agg():
    df = Env().df
    g = df.groupby("a")
    named = g.agg(total=("x", "sum"), rows=("s", "size"), uniq=("s", "nunique"), hi=("n", "max"))
    want = grouped(
        SCAN,
        ("a",),
        (("total", agg("sum", "x")), ("rows", agg("count")), ("uniq", agg("count_distinct", "s")), ("hi", agg("max", "n"))),
        sums=("total",),
    )
    assert named._plan == want
    assert named.dtypes == {"a": "int64", "total": "float64", "rows": "int64", "uniq": "int64", "hi": "int32"}
    assert g.aggregate(total=("x", "sum"), rows=("s", "size"), uniq=("s", "nunique"), hi=("n", "max"))._plan == want
    by_dict = g.agg({"x": "median", "s": "max"})
    assert by_dict._plan == grouped(SCAN, ("a",), (("x", agg("median", "x")), ("s", agg("max", "s"))))
    assert g[["b", "x"]].agg("sum")._plan == g[["b", "x"]].sum()._plan
    one = g["x"].agg(["sum", "std"])
    assert one._plan == grouped(SCAN, ("a",), (("sum", agg("sum", "x")), ("std", agg("stddev_samp", "x"))), sums=("sum",))
    assert g["x"].agg(lo="min", n="size")._plan == grouped(SCAN, ("a",), (("lo", agg("min", "x")), ("n", agg("count"))))


def test_min_count_one_keeps_the_missing_sum_and_other_sum_types_get_their_own_zero():
    df = Env().df
    assert df.groupby("a")["x"].sum(min_count=1)._plan == grouped(SCAN, ("a",), (("x", agg("sum", "x")),))
    env = Env((("k", "int64"), ("u", "uint32"), ("w", "uint64"), ("f", "float32")))
    got = env.df.groupby("k").sum()
    aggs = (("u", agg("sum", "u")), ("w", agg("sum", "w")), ("f", agg("sum", "f")))
    zeros = {"u": Cast(Lit(0), "uint64"), "w": Cast(Lit(0), "uint64")}
    assert got._plan == grouped(env.scan, ("k",), aggs, sums=("u", "w", "f"), zeros=zeros), got._plan
    assert got.dtypes == {"k": "int64", "u": "uint64", "w": "uint64", "f": "float64"}
    wide = Env((("k", "int64"), ("d", "decimal256")))
    refuses(lambda: wide.df.groupby("k").sum(), UnsupportedOperation,
            "sum() of a decimal256 column cannot be 0 when the column has no values, since the plan has no "
            "decimal256 literal: pass min_count=1, where a sum of nothing is missing")
    assert wide.df.groupby("k").sum(min_count=1)._plan == grouped(wide.scan, ("k",), (("d", agg("sum", "d")),))


def test_the_frame_reductions_are_one_row_aggregates_with_no_key_filter_or_sort():
    df = Env().df
    nums = df[["b", "x", "ok"]]
    child = nums._plan
    assert nums.sum()._plan == grouped(
        child, (), (("b", agg("sum", "b")), ("x", agg("sum", "x")), ("ok", agg("sum", arg=TRUE_IS_ONE))),
        sums=("b", "x", "ok"),
    )
    assert nums.sum(min_count=1)._plan == _ops.aggregate(
        child, (), (("b", agg("sum", "b")), ("x", agg("sum", "x")), ("ok", agg("sum", arg=Cast(ColRef("ok"), "int64"))))
    )
    for how, func in (("mean", "mean"), ("median", "median"), ("std", "stddev_samp"), ("var", "var_samp")):
        got = getattr(nums, how)()
        assert got._plan == _ops.aggregate(
            child, (), (("b", agg(func, "b")), ("x", agg(func, "x")), ("ok", agg(func, arg=Cast(ColRef("ok"), "float64"))))
        ), how
        assert got.dtypes == {"b": "float64", "x": "float64", "ok": "float64"}
    for how, func in (("min", "min"), ("max", "max"), ("count", "count"), ("nunique", "count_distinct")):
        got = getattr(df, how)()
        assert got._plan == _ops.aggregate(SCAN, (), tuple((c, agg(func, c)) for c, _ in FIELDS)), how
    assert df.mean(numeric_only=True).columns == ["a", "b", "n", "x", "ok"]
    assert df.count(numeric_only=True).columns == ["a", "b", "n", "x", "ok"]
    named = df.agg(total=("x", "sum"), rows=("a", "size"))
    assert named._plan == grouped(SCAN, (), (("total", agg("sum", "x")), ("rows", agg("count"))), sums=("total",))
    assert df.aggregate(total=("x", "sum"), rows=("a", "size"))._plan == named._plan
    assert df.agg({"x": "max"})._plan == _ops.aggregate(SCAN, (), (("x", agg("max", "x")),))
    assert df[["x"]].agg("var")._plan == df[["x"]].var()._plan


def test_ddof_1_builds_the_sample_aggregates_and_ddof_0_the_population_ones():
    env = Env()
    df, g = env.df, env.df.groupby("a")
    for how, sample, population in (("std", "stddev_samp", "stddev_pop"), ("var", "var_samp", "var_pop")):
        for ddof, func in ((1, sample), (0, population)):
            want = _ops.aggregate(SCAN, (), (("x", agg(func, "x")),))
            assert getattr(df[["x"]], how)(ddof=ddof)._plan == want, (how, ddof)
            assert getattr(g["x"], how)(ddof=ddof)._plan == grouped(
                SCAN, ("a",), (("x", agg(func, "x")),)
            ), (how, ddof)
        # The default is the sample one, as in pandas.
        assert getattr(df[["x"]], how)()._plan == getattr(df[["x"]], how)(ddof=1)._plan
        assert getattr(df[["x"]], how)(ddof=0).dtypes == {"x": "float64"}
    boolean = df[["ok"]].std(ddof=0)
    assert boolean._plan == _ops.aggregate(SCAN, (), (("ok", agg("stddev_pop", arg=Cast(ColRef("ok"), "float64"))),))


def test_a_ddof_that_is_neither_0_nor_1_is_refused_by_name_listing_both():
    env = Env()
    for how in ("std", "var"):
        for target in (env.df[["x"]], env.df.groupby("a")["x"]):
            for ddof in (2, -1, 5):
                refuses(
                    lambda: getattr(target, how)(ddof=ddof),
                    UnsupportedOperation,
                    f"{how}(ddof={ddof}) is not supported: use ddof=1, the sample {how}, "
                    f"or ddof=0, the population {how}",
                )
        refuses(lambda: getattr(env.df[["x"]], how)(ddof=True), TypeError, f"{how} ddof must be an int, not bool")
    assert env.stub.calls == []


def test_a_groupby_over_a_sorted_frame_and_a_head_after_a_sorted_groupby():
    df = Env().df
    over_sort = df.sort_values("x").groupby("a")["x"].max()
    inner = _ops.filter_(_ops.sort(SCAN, (SortKey("x"),)), not_null("a"))
    assert over_sort._plan == _ops.sort(_ops.aggregate(inner, ("a",), (("x", agg("max", "x")),)), (SortKey("a"),))
    head = df.groupby("a").size().head(3)
    assert head._plan == _ops.limit(grouped(SCAN, ("a",), (("size", agg("count")),)), 3)
    unordered = df.groupby("a", sort=False).size().head(3)
    assert unordered._plan == _ops.limit(_ops.aggregate(_ops.filter_(SCAN, not_null("a")), ("a",), (("size", agg("count")),)), 3)
    # A sort by an output column replaces the key sort.
    by_size = df.groupby("a").size().sort_values("size", ascending=False)
    assert by_size._plan == _ops.sort(
        _ops.aggregate(_ops.filter_(SCAN, not_null("a")), ("a",), (("size", agg("count")),)),
        (SortKey("size", descending=True),),
    )


def test_a_groupby_keeps_the_plan_its_frame_had_when_it_was_made():
    df = Env().df
    g = df.groupby("a")
    df["x"] = df["x"] * 2.0
    assert g["x"].max()._plan == grouped(SCAN, ("a",), (("x", agg("max", "x")),))
    assert df.groupby("a")["x"].max()._plan != g["x"].max()._plan


def test_drop_duplicates_is_a_distinct_of_whole_rows_and_keep_false_keeps_rows_with_no_equal():
    df = Env().df
    pair = df[["a", "s"]]
    assert pair.drop_duplicates()._plan == _ops.distinct(pair._plan)
    assert pair.drop_duplicates(keep="last")._plan == _ops.distinct(pair._plan)
    assert pair.drop_duplicates(subset=["s", "a"])._plan == _ops.distinct(pair._plan)
    assert pair.drop_duplicates(subset=("a", "s"), ignore_index=True)._plan == _ops.distinct(pair._plan)
    assert df[["a"]].drop_duplicates(subset="a")._plan == _ops.distinct(df[["a"]]._plan)
    assert pair.drop_duplicates().dtypes == {"a": "int64", "s": "string"}
    unique = pair.drop_duplicates(keep=False)
    counted = _ops.aggregate(pair._plan, ("a", "s"), (("count", agg("count")),))
    assert unique._plan == _ops.select(_ops.filter_(counted, Compare("eq", ColRef("count"), Lit(1))), ("a", "s"))
    assert unique.columns == ["a", "s"]
    # A column named count leaves its name to it.
    named = Env((("count", "int64"), ("_count", "string"))).df
    counted = _ops.aggregate(named._plan, ("count", "_count"), (("__count", agg("count")),))
    assert named.drop_duplicates(keep=False)._plan == _ops.select(
        _ops.filter_(counted, Compare("eq", ColRef("__count"), Lit(1))), ("count", "_count")
    )
    # A sorted frame's distinct has no order.
    assert df.sort_values("a")[["a"]].drop_duplicates()._plan == _ops.distinct(df.sort_values("a")[["a"]]._plan)


# --- the wire -----------------------------------------------------------------------


def test_the_encoded_groupby_is_sort_over_case_over_aggregate_over_filter():
    env = Env()
    got = env.df.groupby("a").agg(total=("x", "sum"), m=("x", "median"), u=("s", "nunique"), sd=("b", "std"))
    root = encode_plan(got._plan, env.sources).plan
    assert root.WhichOneof("node") == "sort", root.WhichOneof("node")
    assert list(root.sort.nulls_first) == [False]
    project = root.sort.child
    assert project.WhichOneof("node") == "project"
    aggregate = project.project.child
    assert aggregate.WhichOneof("node") == "aggregate"
    funcs = [e.func for e in aggregate.aggregate.agg_exprs]
    assert funcs == [member("AGG_", f) for f in ("sum", "median", "count_distinct", "stddev_samp")], funcs
    assert [e.alias_name for e in aggregate.aggregate.agg_exprs] == ["total", "m", "u", "sd"]
    assert aggregate.aggregate.child.WhichOneof("node") == "filter"
    assert [(f.name, f.arrow_type_id) for f in root.output_schema.fields] == [
        ("a", arrow_id("int64")),
        ("total", arrow_id("float64")),
        ("m", arrow_id("float64")),
        ("u", arrow_id("int64")),
        ("sd", arrow_id("float64")),
    ]


def test_a_reduced_frame_reaches_the_session_only_as_plan_bytes_at_its_terminal():
    env = Env()
    frames = [
        env.df.groupby("a").agg(total=("x", "sum")),
        env.df.agg(n=("a", "count")),
        env.df[["a", "s"]].drop_duplicates(),
        env.df[["a"]].drop_duplicates(keep=False),
    ]
    assert env.stub.calls == []
    for frame in frames:
        frame.materialize()
    assert env.stub.calls == [
        ("plan_stream", encode_plan(frame._plan, env.sources).SerializeToString()) for frame in frames
    ]


# --- refusals ------------------------------------------------------------------------


def test_a_reduction_that_needs_numbers_names_the_first_column_that_is_not_one():
    df = Env().df
    for how in ("sum", "mean", "median", "std", "var"):
        message = f"{how}() needs numeric or boolean columns, and the column 's' is string: {NUMERIC_HINT}"
        refuses(lambda: getattr(df.groupby("a"), how)(), UnsupportedOperation, message)
        refuses(lambda: getattr(df, how)(), UnsupportedOperation, message)
    refuses(
        lambda: df.groupby("a").agg(t=("s", "mean")),
        UnsupportedOperation,
        f"agg() needs numeric or boolean columns, and the column 's' is string: {AGG_HINT}",
    )
    refuses(
        lambda: df.agg({"s": "sum"}),
        UnsupportedOperation,
        f"agg() needs numeric or boolean columns, and the column 's' is string: {AGG_HINT}",
    )
    refuses(
        lambda: df[["s"]].sum(numeric_only=True),
        UnsupportedOperation,
        "sum() has no column to reduce: select the columns to reduce first",
    )


def test_arguments_the_reductions_cannot_honour_are_refused_by_name():
    df = Env().df
    g = df.groupby("a")
    for how in ("std", "var"):
        for target in (g, df):
            refuses(lambda: getattr(target, how)(ddof=2), UnsupportedOperation,
                    f"{how}(ddof=2) is not supported: use ddof=1, the sample {how}, or ddof=0, the population {how}")
            refuses(lambda: getattr(target, how)(ddof=1.0), TypeError, f"{how} ddof must be an int, not float")
    for how in ("sum", "mean", "median", "std", "var", "min", "max"):
        message = (f"{how}(skipna=False) is missing for a column that holds a missing value, "
                   "which this release does not build: use skipna=True")
        refuses(lambda: getattr(g, how)(skipna=False), UnsupportedOperation, message)
        refuses(lambda: getattr(df, how)(skipna=False), UnsupportedOperation, message)
        refuses(lambda: getattr(df, how)(axis=1), UnsupportedOperation,
                f"{how}(axis=1) reduces each row, and a plan reduces columns: use axis=0")
        refuses(lambda: getattr(df, how)(axis=True), UnsupportedOperation,
                f"{how}(axis=True) reduces each row, and a plan reduces columns: use axis=0")
    refuses(lambda: df.count(axis="columns"), UnsupportedOperation,
            "count(axis='columns') reduces each row, and a plan reduces columns: use axis=0")
    sum_message = ("sum(min_count={}) is not supported: use min_count=0, where a sum of nothing is 0, "
                   "or min_count=1, where it is missing")
    for n in (2, -1):
        refuses(lambda: g.sum(min_count=n), UnsupportedOperation, sum_message.format(n))
        refuses(lambda: df[["x"]].sum(min_count=n), UnsupportedOperation, sum_message.format(n))
    refuses(lambda: g.sum(min_count=True), TypeError, "sum min_count must be an int, not bool")
    for how in ("min", "max"):
        assert getattr(g, how)(min_count=1)._plan == getattr(g, how)()._plan
        assert getattr(g, how)(min_count=0)._plan == getattr(g, how)()._plan
        refuses(lambda: getattr(g, how)(min_count=2), UnsupportedOperation,
                f"{how}(min_count=2) is not supported: min and max of fewer values are missing "
                "only for min_count of 1 or less")
        refuses(lambda: getattr(g, how)(min_count="1"), TypeError, f"{how} min_count must be an int, not str")
    nunique = ("nunique(dropna=False) counts a missing value as one more value, which this release does not "
               "build: use dropna=True")
    refuses(lambda: g.nunique(dropna=False), UnsupportedOperation, nunique)
    refuses(lambda: df.nunique(dropna=False), UnsupportedOperation, nunique)
    refuses(lambda: g.sum(numeric_only=1), TypeError, "sum numeric_only must be a bool, not int")


def test_agg_refuses_functions_row_order_unknown_names_and_two_level_columns():
    df = Env().df
    g = df.groupby("a")
    refuses(lambda: g.agg(t=("x", sum)), UnsupportedOperation,
            "agg() with a Python function runs it once per group, an aggregate UDF that this release "
            f"does not run: name a reduction ({SUPPORTED})")
    refuses(lambda: g.agg(lambda s: s), UnsupportedOperation,
            "agg() with a Python function runs it once per group, an aggregate UDF that this release "
            f"does not run: name a reduction ({SUPPORTED})")
    for func in ("first", "last", "nth", "cumcount"):
        refuses(lambda: g.agg(t=("x", func)), UnsupportedOperation,
                f"agg() with {func!r} picks values by row order, which a frame does not have: "
                "use 'min' or 'max' of an ordered key")
    refuses(lambda: g.agg(t=("x", "mode")), UnsupportedOperation,
            f"agg() has no reduction 'mode': name one of {SUPPORTED}")
    refuses(lambda: df.agg("prod"), UnsupportedOperation, f"agg() has no reduction 'prod': name one of {SUPPORTED}")
    refuses(lambda: g.agg(t=("x", 3)), TypeError, "agg() takes the name of a reduction, a str, not a int")
    two_levels = ("agg() with a list of reductions names its columns by two levels, which a komira frame "
                  'does not have: name each output, as agg(total=("v", "sum"))')
    refuses(lambda: g.agg(["sum", "max"]), UnsupportedOperation, two_levels)
    refuses(lambda: df.agg(["sum"]), UnsupportedOperation, two_levels)
    refuses(lambda: g.agg({"x": ["sum", "max"]}), UnsupportedOperation,
            "agg() with a list of reductions for 'x' names its columns by two levels, which a komira frame "
            'does not have: name each output, as agg(total=("v", "sum"))')
    refuses(lambda: g.agg("sum", t=("x", "sum")), TypeError, "agg() takes a reduction or keyword aggregates, not both")
    refuses(lambda: g.agg(), TypeError, "Must provide 'func' or tuples of '(column, aggfunc).")
    refuses(lambda: g.agg(t="x"), TypeError,
            'agg() takes each keyword as (column, reduction), as in total=("v", "sum"), not a str')
    refuses(lambda: g.agg(t=("x", "sum", 1)), TypeError,
            'agg() takes each keyword as (column, reduction), as in total=("v", "sum"), not a tuple')
    refuses(lambda: g.agg(t=(1, "sum")), TypeError, "agg() names a column with a str, not a int")
    refuses(lambda: g.agg({1: "sum"}), TypeError, "agg() names a column with a str, not a int")
    refuses(lambda: g.agg(3), TypeError,
            "agg() takes a reduction's name, a dict of column to reduction, or keyword aggregates, not a int")
    refuses(lambda: g["x"].agg(t=("x", "sum")), TypeError, "agg() takes the name of a reduction, a str, not a tuple")
    refuses(lambda: g.agg(t=("y", "sum")), KeyError,
            "no column named 'y' in this frame; the frame's columns are: a, b, n, x, s, ok")
    refuses(lambda: g.agg({"y": "sum"}), KeyError,
            "no column named 'y' in this frame; the frame's columns are: a, b, n, x, s, ok")


def test_an_output_named_twice_is_refused():
    g = Env().df.groupby("a")
    refuses(lambda: g.agg(a=("x", "sum")), ValueError,
            "agg(): the output column 'a' is named twice: it is also a group key")
    refuses(lambda: g.agg({"a": "count"}), ValueError,
            "agg(): the output column 'a' is named twice: it is also a group key")
    # A key reduced under another name is a column like any other, as in pandas.
    keyed = g.agg(n=("a", "count"), hi=("a", "max"))
    assert keyed._plan == grouped(SCAN, ("a",), (("n", agg("count", "a")), ("hi", agg("max", "a"))))
    refuses(lambda: g["x"].agg(["sum", "sum"]), ValueError,
            "agg(): the output column 'sum' is named twice: it is also another output column")
    size_key = Env((("size", "int64"), ("x", "float64"))).df
    refuses(lambda: size_key.groupby("size").size(), ValueError,
            "size(): the output column 'size' is named twice: it is also a group key")


def test_groupby_and_its_subscript_refuse_what_names_no_column():
    df = Env().df
    refuses(lambda: df.groupby("y"), KeyError,
            "no column named 'y' in this frame; the frame's columns are: a, b, n, x, s, ok")
    refuses(lambda: df.groupby(["a", "bb"]), KeyError,
            "no column named 'bb' in this frame; the closest is 'b'; the frame's columns are: a, b, n, x, s, ok")
    refuses(lambda: df.groupby([]), ValueError, "No group keys passed!")
    refuses(lambda: df.groupby(), TypeError, "You have to supply one of 'by' and 'level'")
    refuses(lambda: df.groupby(["a", "a"]), ValueError, "groupby names a key twice: a, a")
    refuses(lambda: df.groupby(["a", 1]), TypeError, "groupby takes column names, which are str, not int")
    refuses(lambda: df.groupby(df["a"]), UnsupportedOperation,
            "groupby(Series) groups by values that are not a column of the frame: "
            "assign them as a column with assign(), then group by its name")
    refuses(lambda: df.groupby("a", sort=1), TypeError, "groupby sort must be a bool, not int")
    refuses(lambda: df.groupby("a", dropna=None), TypeError, "groupby dropna must be a bool, not NoneType")
    refuses(lambda: df.groupby("a", as_index="no"), TypeError, "groupby as_index must be a bool, not str")
    g = df.groupby("a")
    refuses(lambda: g["y"], KeyError, "no column named 'y' in this frame; the frame's columns are: a, b, n, x, s, ok")
    refuses(lambda: g["a"], ValueError, "the column 'a' is a group key, and its groups already hold it once")
    refuses(lambda: g[["x", "x"]], ValueError, "a GroupBy subscript names a column twice: x, x")
    refuses(lambda: g[["x", 2]], TypeError, "a GroupBy is subscripted with column names, which are str, not int")
    refuses(lambda: g[2], TypeError, "a GroupBy is subscripted with a column name or a list of names, not a int")


def test_drop_duplicates_refuses_a_subset_inplace_and_an_unknown_keep():
    df = Env().df
    pair = df[["a", "s"]]
    refuses(lambda: pair.drop_duplicates(subset=["a"]), UnsupportedOperation,
            "drop_duplicates(subset=['a']) keeps one whole row of each group of rows equal on those columns, "
            "which this release does not build: keep only those columns first, as df[['a']].drop_duplicates()")
    refuses(lambda: pair.drop_duplicates("s", keep=False), UnsupportedOperation,
            "drop_duplicates(subset=['s']) keeps one whole row of each group of rows equal on those columns, "
            "which this release does not build: keep only those columns first, as df[['s']].drop_duplicates()")
    refuses(lambda: pair.drop_duplicates(subset=["y"]), KeyError,
            "no column named 'y' in this frame; the frame's columns are: a, s")
    refuses(lambda: pair.drop_duplicates(subset=[1]), TypeError,
            "drop_duplicates subset takes column names, which are str, not int")
    refuses(lambda: pair.drop_duplicates(subset=3), TypeError, "drop_duplicates subset takes column names, not a int")
    refuses(lambda: pair.drop_duplicates(keep="any"), ValueError, 'keep must be either "first", "last" or False')
    refuses(lambda: pair.drop_duplicates(keep=None), ValueError, 'keep must be either "first", "last" or False')
    refuses(lambda: pair.drop_duplicates(inplace=True), UnsupportedOperation,
            "drop_duplicates(inplace=True) changes the frame in place, and komira frames do not change: "
            "use the frame drop_duplicates returns")
    refuses(lambda: pair.drop_duplicates(ignore_index=1), TypeError,
            "drop_duplicates ignore_index must be a bool, not int")


# --- the GroupBy's attributes and dunders ---------------------------------------------


def check_refused(obj, name, message):
    e = raised(lambda: getattr(obj, name))
    assert type(e) is AttributeError and e.args[0] == message, (name, repr(e))
    assert e.name == name, name
    assert not hasattr(obj, name), name


def test_every_name_in_the_groupby_table_raises_its_message():
    g = Env().df.groupby("a")
    assert len(_refusals.GROUPBY) == 11
    for name, message in _refusals.GROUPBY.items():
        check_refused(g, name, message.format(name=name))
    check_refused(g, "first", ".first() is not supported yet; use min() or max() of an ordered key")
    check_refused(g, "filter", "GroupBy.filter() is not supported yet; aggregate, then filter the result")
    check_refused(g, "ngroups", ".ngroups needs a query to run; aggregate with .size() and materialize()")
    check_refused(g, "ohlc", ".ohlc() is not supported: komira has no time index")
    check_refused(g, "pipe", "'GroupBy' object has no attribute 'pipe'")
    check_refused(g, "_hidden", "'GroupBy' object has no attribute '_hidden'")
    # A column is not an attribute of its groups either.
    check_refused(g, "x", "'GroupBy' object has no attribute 'x'")


def test_a_groupby_is_made_by_a_frame_runs_nothing_and_does_not_change():
    env = Env()
    g = env.df.groupby(["a", "s"])
    assert type(g) is komira.GroupBy and "GroupBy" in komira.__all__
    refuses(lambda: komira.GroupBy(env.df), TypeError, 'a komira GroupBy is made by a frame: df.groupby("key")')
    refuses(lambda: iter(g), UnsupportedOperation,
            "iterating a komira GroupBy needs the groups' rows: reduce them with agg() and run the frame "
            "with .materialize()")
    refuses(lambda: len(g), UnsupportedOperation,
            "len() of a komira GroupBy needs a query to run: count the groups with .size() and materialize()")
    refuses(lambda: setattr(g, "sort", False), AttributeError,
            "cannot set the attribute 'sort' of a komira GroupBy: a GroupBy is part of a plan and does not change")
    assert repr(g) == "<komira.GroupBy by a, s>"
    assert env.stub.calls == []


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("frame groupby: {} tests".format(len(tests)))


if __name__ == "__main__":
    main()
    sys.exit(0)
