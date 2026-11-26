"""komira.pl's group_by, join, unique and windows as plans, with no library.

Frames are scans of a stand-in session, a `Session` whose file schemas are
written here as the engine's `WireSchema` bytes and whose terminals record the
plan bytes they are given (as test_pl_verbs.py does). For each verb:

- the frame's plan equals a hand-written tree of komira._ops nodes, its columns
  and its order: `group_by(...).agg(...)` and its reductions (an AGGREGATE, or
  a PROJECT over one when an expression computes over the aggregates), `join`
  in each of its hows (the right input renamed first, a PROJECT above the join
  that gives polars' columns), `unique` (a DISTINCT, or the rows a window
  numbers 1 or counts as alone), `over`, `rank`, `cum_*` and `rolling_*` (a
  PROJECT of the windows, under a PROJECT of the outputs, the sort of an
  ordered frame written again on top), and an aggregate beside row-wise values
  in `select`, `with_columns` and `filter` (a window over the whole frame);
- the types they give (a rank is an Int64 and an average rank a Float64, a
  count is an Int64, the sum of an Int32 is an Int32, the key types of a
  join) as `schema` names them, derived without running;
- each refusal raises its class with its full message: a bare column, a
  window or a key that is an expression in `agg`, a join of keys of two types,
  a window with no row order, a rank by row order, a window of a window;
- `collect()` hands the session the bytes of a `WirePlanEnvelope` that holds
  no SQL text.

    test_pl_frames.py
"""

import os
import tempfile

import pyarrow as pa

import komira.pl as kpl
from komira import Session, UnsupportedOperation
from komira._ops import (
    Agg,
    Aggregate,
    Arith,
    Cast,
    ColRef,
    Compare,
    Distinct,
    Field,
    Filter,
    Frame,
    Join,
    Lit,
    Project,
    Scan,
    Sort,
    SortKey,
    Unary,
    When,
    WindowExpr,
)
from komira._plan._wire import arrow_id, field, pb

# Never opened: the stand-in answers its schema.
PATH = os.path.join(tempfile.gettempdir(), "frames_left.parquet")
PATH_R = os.path.join(tempfile.gettempdir(), "frames_right.parquet")
PATH_BAD = os.path.join(tempfile.gettempdir(), "frames_bad_key.parquet")
PATH_X = os.path.join(tempfile.gettempdir(), "frames_suffix.parquet")
TYPES = [
    ("id", "int64"),
    ("x", "int64"),
    ("y", "float64"),
    ("g", "string"),
    ("flag", "bool"),
    ("i32", "int32"),
    ("f32", "float32"),
    ("u16", "uint16"),
]
RTYPES = [("rid", "int64"), ("g", "string"), ("w", "float64"), ("x", "int64")]
# A right file whose `i32` is an Int64 where the left's is an Int32.
BAD_TYPES = [("rid", "int64"), ("i32", "int64")]
# A left file that already has the `x_right` a joined `x` would be named.
SUFFIX_TYPES = [("g", "string"), ("x", "int64"), ("x_right", "int64")]
T = Scan(PATH, "parquet", tuple(Field(n, t) for n, t in TYPES))
R = Scan(PATH_R, "parquet", tuple(Field(n, t) for n, t in RTYPES))


class StandIn(Session):
    """A session with no library: schemas from `schemas`, plans recorded."""

    def __init__(self, schemas):
        self.schemas = schemas
        self.ran = []
        self.rendered = []

    def _parquet_schema(self, path):
        fields = [field(n, arrow_id(t), True) for n, t in self.schemas[path]]
        return pb.WireSchema(fields=fields).SerializeToString()

    def _plan_stream(self, plan):
        self.ran.append(plan)
        return "result"

    def _plan_render(self, plan):
        self.rendered.append(plan)
        return "rendered"

    def close(self):
        pass


SESSION = StandIn(
    {PATH: TYPES, PATH_R: RTYPES, PATH_BAD: BAD_TYPES, PATH_X: SUFFIX_TYPES}
)


def frame():
    return kpl.scan_parquet(PATH, session=SESSION)


def right():
    return kpl.scan_parquet(PATH_R, session=SESSION)


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, cls, message):
    e = raised(call)
    assert type(e) is cls, (type(e), e)
    text = e.args[0] if isinstance(e, KeyError) else str(e)
    assert text == message, text


def c(name):
    return ColRef(name)


ALL = tuple((n, c(n)) for n, _ in TYPES)
ID_ORDER = (SortKey("id", False, True),)


def extend(plan, items):
    """A PROJECT of every column of `plan`, then the `items` (name, node)."""
    return Project(plan, tuple((n, c(n)) for n in plan.columns) + tuple(items))


def win(i):
    return f"__komira_win_{i}"


def arg(i):
    return f"__komira_arg_{i}"


def total(ref, zero):
    """What `sum()` makes of the aggregate or window `ref`: 0 over no values."""
    return When(((Unary("is_null", c(ref)), Lit(zero)),), c(ref))


def null_where_null(source, value):
    """`value`, null where the column `source` is null."""
    return When(((Unary("is_null", c(source)), Lit(None)),), value)


def replacing(name, node):
    """Every column of the left frame, `name` replaced by `node`."""
    return tuple((n, node) if n == name else (n, c(n)) for n, _ in TYPES)


# ---- group_by --------------------------------------------------------------------


def test_group_by_a_key_with_a_bare_aggregate_is_one_aggregate_node():
    lf = frame().group_by("g").agg(kpl.col("x").max())
    assert lf._plan == Aggregate(T, ("g",), (("x", Agg("max", (c("x"),))),))
    assert lf.columns == ["g", "x"]
    assert lf._order is None


def test_group_by_two_keys_and_a_col_key_name_the_same_columns():
    expected = Aggregate(T, ("g", "flag"), (("top", Agg("max", (c("y"),))),))
    top = kpl.col("y").max().alias("top")
    assert frame().group_by(kpl.col("g"), "flag").agg(top)._plan == expected
    assert frame().group_by(["g", kpl.col("flag")]).agg(top)._plan == expected
    assert frame().group_by("g", "flag").agg(top).columns == ["g", "flag", "top"]


def test_group_by_agg_of_a_sum_computes_over_the_aggregate_in_a_project():
    lf = frame().group_by("g").agg(kpl.col("x").sum())
    slot = "__komira_agg_0"
    assert lf._plan == Project(
        Aggregate(T, ("g",), ((slot, Agg("sum", (c("x"),))),)),
        (("g", c("g")), ("x", total(slot, 0))),
    )
    assert lf.columns == ["g", "x"]


def test_group_by_agg_of_an_expression_over_aggregates_is_a_project_over_the_aggregate():
    lf = frame().group_by("g").agg((kpl.col("y").max() - kpl.col("y").min()).alias("spread"))
    aggs = (("__komira_agg_0", Agg("max", (c("y"),))), ("__komira_agg_1", Agg("min", (c("y"),))))
    assert lf._plan == Project(
        Aggregate(T, ("g",), aggs),
        (("g", c("g")), ("spread", Arith("sub", c("__komira_agg_0"), c("__komira_agg_1")))),
    )
    assert lf.columns == ["g", "spread"]
    assert lf.schema == {"g": pa.string(), "spread": pa.float64()}


def test_group_by_len_counts_the_rows_of_each_group_under_len_or_a_name():
    assert frame().group_by("g").len()._plan == Aggregate(T, ("g",), (("len", Agg("count")),))
    assert frame().group_by("g").len(name="n")._plan == Aggregate(T, ("g",), (("n", Agg("count")),))
    assert frame().group_by("g").agg(kpl.len())._plan == Aggregate(T, ("g",), (("len", Agg("count")),))
    assert frame().group_by("g").len().schema == {"g": pa.string(), "len": pa.int64()}


def test_group_by_sum_reduces_every_non_key_column_under_its_own_name():
    base = frame().select("g", "x", "y")
    lf = base.group_by("g").sum()
    aggs = (("__komira_agg_0", Agg("sum", (c("x"),))), ("__komira_agg_1", Agg("sum", (c("y"),))))
    assert lf._plan == Project(
        Aggregate(base._plan, ("g",), aggs),
        (("g", c("g")), ("x", total("__komira_agg_0", 0)), ("y", total("__komira_agg_1", 0.0))),
    )
    assert lf.columns == ["g", "x", "y"]


def test_group_by_mean_and_median_reduce_every_non_key_column():
    base = frame().select("id", "x")
    assert base.group_by("id").mean()._plan == Aggregate(
        base._plan, ("id",), (("x", Agg("mean", (c("x"),))),)
    )
    assert base.group_by("id").median()._plan == Aggregate(
        base._plan, ("id",), (("x", Agg("median", (c("x"),))),)
    )


def test_group_by_min_max_and_n_unique_reduce_columns_of_any_type():
    base = frame().select("id", "g")
    assert base.group_by("id").min()._plan == Aggregate(base._plan, ("id",), (("g", Agg("min", (c("g"),))),))
    assert base.group_by("id").max()._plan == Aggregate(base._plan, ("id",), (("g", Agg("max", (c("g"),))),))
    lf = base.group_by("id").n_unique()
    aggs = (
        ("__komira_agg_0", Agg("count_distinct", (c("g"),))),
        ("__komira_agg_1", Agg("count")),
        ("__komira_agg_2", Agg("count", (c("g"),))),
    )
    extra = When(((Compare("gt", c("__komira_agg_1"), c("__komira_agg_2")), Lit(1)),), Lit(0))
    assert lf._plan == Project(
        Aggregate(base._plan, ("id",), aggs),
        (("id", c("id")), ("g", Arith("add", c("__komira_agg_0"), extra))),
    )
    assert lf.schema == {"id": pa.int64(), "g": pa.int64()}


def test_group_by_drops_a_sort_below_it_and_the_frame_is_unordered():
    lf = frame().sort("id").group_by("g").agg(kpl.col("x").max())
    assert lf._plan == Aggregate(T, ("g",), (("x", Agg("max", (c("x"),))),))
    assert lf._order is None


def test_group_by_result_types_are_polars_types():
    lf = frame().group_by("g").agg(
        kpl.col("i32").sum().alias("s32"),
        kpl.col("x").mean().alias("mean_x"),
        kpl.col("x").sum().alias("sum_x"),
        kpl.col("f32").max().alias("max_f32"),
    )
    assert lf.schema == {
        "g": pa.string(),
        "s32": pa.int32(),
        "mean_x": pa.float64(),
        "sum_x": pa.int64(),
        "max_f32": pa.float32(),
    }


def test_group_by_refuses_keys_that_are_not_plain_columns():
    refused(
        lambda: frame().group_by("g", maintain_order=True),
        UnsupportedOperation,
        "group_by: maintain_order=True keeps the groups in input order, and a plan has no row "
        "order; sort the result instead",
    )
    refused(
        lambda: frame().group_by(k=kpl.col("g")),
        UnsupportedOperation,
        "group_by: a named key expression is not supported; add it with with_columns(...) and "
        "group by its name",
    )
    refused(
        lambda: frame().group_by(kpl.col("x") + 1),
        UnsupportedOperation,
        "group_by: the key 'x' is an expression, which is not supported; add it with "
        "with_columns(...) and name its column",
    )
    refused(
        lambda: frame().group_by(kpl.col("g").alias("k")),
        UnsupportedOperation,
        "group_by: the key 'g' is renamed 'k' with alias(), which is not supported; rename the "
        "column with rename(...) first",
    )
    refused(lambda: frame().group_by("g", "g"), ValueError, "group_by: the column 'g' is named more than once")
    refused(lambda: frame().group_by(), ValueError, "group_by needs at least one column")


def test_group_by_agg_refuses_a_bare_column_a_repeated_name_and_a_window():
    refused(
        lambda: frame().group_by("g").agg(kpl.col("x")),
        UnsupportedOperation,
        "agg: the column 'x' is not aggregated, and polars would give a list of each group's "
        "values, which is not supported; aggregate it, for example with col('x').max()",
    )
    again = (
        "agg: the output name '{}' is produced more than once (a key or another expression); "
        "give it a name of its own with .alias(...)"
    )
    refused(lambda: frame().group_by("g").agg(kpl.col("g").count()), ValueError, again.format("g"))
    refused(
        lambda: frame().group_by("g").agg(kpl.col("x").sum(), kpl.col("x").max()),
        ValueError,
        again.format("x"),
    )
    refused(
        lambda: frame().group_by("g").agg(kpl.col("x").sum().over("id")),
        UnsupportedOperation,
        "agg: over() is a window, which is not supported inside group_by().agg(); compute it "
        "with with_columns(...) first",
    )
    refused(
        lambda: frame().group_by("g").agg(kpl.col("x").rank().sum()),
        UnsupportedOperation,
        "agg: rank(method='average') is a window inside an aggregate or a sort key, which is "
        "not supported",
    )


def test_group_by_sum_mean_and_median_refuse_a_column_that_is_not_a_number():
    base = frame().select("id", "g")
    for verb in ("sum", "mean", "median"):
        refused(
            lambda verb=verb: getattr(base.group_by("id"), verb)(),
            UnsupportedOperation,
            f"group_by().{verb}(): the column 'g' is of type string, and {verb}() needs numbers "
            "or booleans; select the columns to reduce first",
        )


# ---- unique ----------------------------------------------------------------------


def test_unique_of_whole_rows_is_a_distinct_below_any_sort():
    lf = frame().unique()
    assert lf._plan == Distinct(T)
    assert lf._order is None
    assert frame().sort("id").unique()._plan == Distinct(T)
    assert frame().sort("id").unique()._order is None
    assert frame().unique([n for n, _ in TYPES])._plan == Distinct(T)


def test_unique_of_a_subset_keeps_the_row_a_window_numbers_one():
    lf = frame().unique("g")
    numbered = WindowExpr("row_number", None, 0, ("g",), (SortKey("g"),))
    assert lf._plan == Project(
        Filter(extend(T, [(win(0), numbered)]), Compare("eq", c(win(0)), Lit(1))), ALL
    )
    assert lf.columns == [n for n, _ in TYPES]
    assert lf._order is None
    assert frame().sort("id").unique("g")._plan == lf._plan
    two = frame().unique(["g", kpl.col("flag")])
    both = WindowExpr("row_number", None, 0, ("g", "flag"), (SortKey("g"),))
    assert two._plan == Project(
        Filter(extend(T, [(win(0), both)]), Compare("eq", c(win(0)), Lit(1))), ALL
    )


def test_unique_keep_none_keeps_the_rows_whose_value_no_other_row_has():
    lf = frame().unique("g", keep="none")
    counted = WindowExpr("count", arg(0), 0, ("g",))
    below = extend(extend(T, [(arg(0), Lit(1))]), [(win(1), counted)])
    assert lf._plan == Project(Filter(below, Compare("eq", c(win(1)), Lit(1))), ALL)
    assert lf._order is None


def test_unique_refusals():
    refused(
        lambda: frame().unique("g", keep="first"),
        UnsupportedOperation,
        "unique: keep='first' picks a row by row order, which a plan does not have; use keep='any'",
    )
    refused(
        lambda: frame().unique("g", keep="last"),
        UnsupportedOperation,
        "unique: keep='last' picks a row by row order, which a plan does not have; use keep='any'",
    )
    refused(
        lambda: frame().unique("g", keep="some"),
        ValueError,
        "unique: keep must be 'any', 'first', 'last' or 'none', not 'some'",
    )
    refused(
        lambda: frame().unique("g", maintain_order=True),
        UnsupportedOperation,
        "unique: maintain_order=True keeps rows in input order, and a plan has no row order; "
        "sort the result instead",
    )


# ---- join ------------------------------------------------------------------------

KEY_G = "__komira_key_g"
RIGHT_G = "__komira_right_g"
LEFT_AND_RIGHT = ALL + (("rid", c("rid")), ("w", c("w")), ("x_right", c("x_right")))


def right_keyed_on_g():
    """The right input of a join on `g` that drops the right key: `g` is
    named apart, and `x`, which the left has, is `x_right`."""
    return Project(R, (("rid", c("rid")), (KEY_G, c("g")), ("w", c("w")), ("x_right", c("x"))))


def test_inner_and_left_join_on_a_key_rename_the_right_key_inside_and_drop_it():
    for how in ("inner", "left"):
        lf = frame().join(right(), on="g", how=how)
        join = Join(T, right_keyed_on_g(), how, ("g",), (KEY_G,))
        assert lf._plan == Project(join, LEFT_AND_RIGHT)
        assert lf.columns == [n for n, _ in TYPES] + ["rid", "w", "x_right"]
        assert lf._order is None
    assert frame().join(right(), on=kpl.col("g"))._plan == frame().join(right(), on="g")._plan
    assert frame().join(right(), "g")._plan == frame().join(right(), on="g")._plan


def test_join_result_is_unordered_and_holds_the_sources_of_both_frames():
    lf = frame().sort("id").join(right(), on="g")
    assert lf._order is None
    assert set(lf._sources) == {PATH, PATH_R}
    assert lf.collect() == "result"


def test_join_types_are_the_types_of_the_two_inputs():
    lf = frame().join(right(), on="g")
    assert lf.schema == {
        "id": pa.int64(),
        "x": pa.int64(),
        "y": pa.float64(),
        "g": pa.string(),
        "flag": pa.bool_(),
        "i32": pa.int32(),
        "f32": pa.float32(),
        "u16": pa.uint16(),
        "rid": pa.int64(),
        "w": pa.float64(),
        "x_right": pa.int64(),
    }


def test_join_on_keys_of_different_names_drops_the_right_key():
    lf = frame().join(right(), left_on="id", right_on="rid")
    renamed = Project(
        R,
        (("__komira_key_rid", c("rid")), ("g_right", c("g")), ("w", c("w")), ("x_right", c("x"))),
    )
    assert lf._plan == Project(
        Join(T, renamed, "inner", ("id",), ("__komira_key_rid",)),
        ALL + (("g_right", c("g_right")), ("w", c("w")), ("x_right", c("x_right"))),
    )
    assert lf.columns == [n for n, _ in TYPES] + ["g_right", "w", "x_right"]


def test_full_join_keeps_both_keys():
    lf = frame().join(right(), on="g", how="full")
    renamed = Project(R, (("rid", c("rid")), ("g_right", c("g")), ("w", c("w")), ("x_right", c("x"))))
    # The join's own columns are polars' output: no projection over it.
    assert lf._plan == Join(T, renamed, "full", ("g",), ("g_right",))
    assert lf.columns == [n for n, _ in TYPES] + ["rid", "g_right", "w", "x_right"]


def test_full_join_with_coalesce_takes_the_right_key_where_the_left_is_null():
    lf = frame().join(right(), on="g", how="full", coalesce=True)
    key = When(((Unary("is_null", c("g")), c(KEY_G)),), c("g"))
    assert lf._plan == Project(
        Join(T, right_keyed_on_g(), "full", ("g",), (KEY_G,)),
        replacing("g", key) + (("rid", c("rid")), ("w", c("w")), ("x_right", c("x_right"))),
    )
    assert lf.columns == [n for n, _ in TYPES] + ["rid", "w", "x_right"]
    assert lf.schema["g"] == pa.string()


def test_inner_join_without_coalesce_keeps_the_right_key():
    lf = frame().join(right(), on="g", coalesce=False)
    assert lf.columns == [n for n, _ in TYPES] + ["rid", "g_right", "w", "x_right"]


def test_right_join_gives_the_left_columns_but_the_keys_then_every_right_column():
    left = frame().select("id", "g", "y")
    lf = left.join(right(), on="g", how="right")
    renamed = Project(R, (("rid", c("rid")), (RIGHT_G, c("g")), ("w", c("w")), ("x", c("x"))))
    assert lf._plan == Project(
        Join(left._plan, renamed, "right", ("g",), (RIGHT_G,)),
        (
            ("id", c("id")),
            ("y", c("y")),
            ("rid", c("rid")),
            ("g", c(RIGHT_G)),
            ("w", c("w")),
            ("x", c("x")),
        ),
    )
    assert lf.columns == ["id", "y", "rid", "g", "w", "x"]


def test_semi_and_anti_join_give_the_left_columns_with_no_projection():
    for how in ("semi", "anti"):
        lf = frame().join(right(), on="g", how=how)
        assert lf._plan == Join(T, R, how, ("g",), ("g",))
        assert lf.columns == [n for n, _ in TYPES]
    keyed = frame().join(right(), left_on="id", right_on="rid", how="semi")
    assert keyed._plan == Join(T, R, "semi", ("id",), ("rid",))


def test_cross_join_names_a_colliding_right_column_with_the_suffix():
    lf = frame().join(right(), how="cross")
    renamed = Project(R, (("rid", c("rid")), ("g_right", c("g")), ("w", c("w")), ("x_right", c("x"))))
    assert lf._plan == Join(T, renamed, "cross")
    assert lf._order is None


def test_join_suffix_names_the_colliding_right_columns():
    lf = frame().join(right(), how="cross", suffix="_r")
    renamed = Project(R, (("rid", c("rid")), ("g_r", c("g")), ("w", c("w")), ("x_r", c("x"))))
    assert lf._plan == Join(T, renamed, "cross")
    assert lf.columns == [n for n, _ in TYPES] + ["rid", "g_r", "w", "x_r"]


def test_join_refuses_what_it_cannot_run_or_what_polars_refuses():
    refused(lambda: frame().join(1, on="g"), TypeError, "join takes a komira.pl LazyFrame, not int")
    refused(
        lambda: frame().join(right(), on="g", how="outer"),
        ValueError,
        "join: how must be one of 'inner', 'left', 'right', 'full', 'semi', 'anti', 'cross', "
        "not 'outer'",
    )
    other = StandIn({PATH_R: RTYPES})
    refused(
        lambda: frame().join(kpl.scan_parquet(PATH_R, session=other), on="g"),
        UnsupportedOperation,
        "join: the other frame runs on another session than this one; frames of two sessions "
        "never meet",
    )
    refused(
        lambda: frame().join(right(), on="g", nulls_equal=True),
        UnsupportedOperation,
        "join: nulls_equal=True is not supported: in a plan a null key matches nothing",
    )
    refused(
        lambda: frame().join(right(), on="g", validate="1:1"),
        UnsupportedOperation,
        "join: validate='1:1' checks that keys are unique, which is not supported; only "
        "validate='m:m' is",
    )
    refused(
        lambda: frame().join(right(), on="g", maintain_order="left"),
        UnsupportedOperation,
        "join: maintain_order='left' keeps an input's row order, and a join promises none; sort "
        "the result",
    )


def test_join_refuses_keys_of_two_types():
    bad = kpl.scan_parquet(PATH_BAD, session=SESSION)
    refused(
        lambda: frame().join(bad, on="i32"),
        UnsupportedOperation,
        "join: the key 'i32' is of type int32 on the left and 'i32' of type int64 on the right; "
        "cast one side to the other's type first",
    )


def test_join_refuses_inconsistent_keys():
    refused(
        lambda: frame().join(right(), how="cross", on="g"),
        ValueError,
        "join: a cross join takes no keys",
    )
    refused(
        lambda: frame().join(right(), how="cross", left_on="id", right_on="rid"),
        ValueError,
        "join: a cross join takes no keys",
    )
    refused(
        lambda: frame().join(right(), on="g", left_on="g"),
        ValueError,
        "join: give on=, or left_on= and right_on=, not both",
    )
    refused(
        lambda: frame().join(right(), left_on="id"),
        ValueError,
        "join: give the keys with on=, or with left_on= and right_on=",
    )
    refused(
        lambda: frame().join(right()),
        ValueError,
        "join: give the keys with on=, or with left_on= and right_on=",
    )
    refused(
        lambda: frame().join(right(), left_on=["id", "x"], right_on="rid"),
        ValueError,
        "join: left_on has 2 columns and right_on 1",
    )


def test_right_join_refusals():
    refused(
        lambda: frame().join(right(), on="g", how="right"),
        UnsupportedOperation,
        "join: how='right' with the column 'x' on both sides is not supported; rename one "
        "side's column first",
    )
    refused(
        lambda: frame().select("id", "g").join(right(), on="g", how="right", coalesce=False),
        UnsupportedOperation,
        "join: how='right' with coalesce=False is not supported",
    )


def test_join_refuses_a_suffix_the_output_already_has():
    taken = kpl.scan_parquet(PATH_X, session=SESSION)
    refused(
        lambda: taken.join(right(), on="g"),
        ValueError,
        "join: the right column 'x' would be named 'x_right', which the output already has; "
        "rename one side's column first",
    )


# ---- an aggregate beside row-wise values -------------------------------------------


def test_with_columns_broadcasts_an_aggregate_as_a_window_over_the_whole_frame():
    lf = frame().with_columns(kpl.col("x").sum().alias("t"))
    window = WindowExpr("sum", "x", 0, ())
    assert lf._plan == Project(extend(T, [(win(0), window)]), ALL + (("t", total(win(0), 0)),))
    assert lf.columns == [n for n, _ in TYPES] + ["t"]
    assert lf._order is None
    assert lf.schema["t"] == pa.int64()


def test_a_broadcast_aggregate_keeps_the_sort_of_an_ordered_frame_on_top():
    lf = frame().sort("id").with_columns(kpl.col("x").sum().alias("t"))
    window = WindowExpr("sum", "x", 0, ())
    inner = Project(extend(T, [(win(0), window)]), ALL + (("t", total(win(0), 0)),))
    assert lf._plan == Sort(inner, ID_ORDER)
    assert lf._order == ID_ORDER


def test_a_broadcast_sum_of_an_int32_column_is_an_int32_over_an_int64_argument():
    lf = frame().with_columns(kpl.col("i32").sum().alias("t"))
    window = WindowExpr("sum", arg(0), 0, ())
    node = Cast(total(win(1), 0), "int32")
    below = extend(extend(T, [(arg(0), Cast(c("i32"), "int64"))]), [(win(1), window)])
    assert lf._plan == Project(below, ALL + (("t", node),))
    assert lf.schema["t"] == pa.int32()


def test_select_of_an_aggregate_beside_a_column_broadcasts_the_aggregate():
    lf = frame().select(kpl.col("x").sum(), kpl.col("y"))
    window = WindowExpr("sum", "x", 0, ())
    assert lf._plan == Project(
        extend(T, [(win(0), window)]), (("x", total(win(0), 0)), ("y", c("y")))
    )
    assert lf.columns == ["x", "y"]
    assert lf._order is None
    assert lf.schema == {"x": pa.int64(), "y": pa.float64()}


def test_filter_by_a_comparison_with_an_aggregate_keeps_the_rows_above_the_mean():
    lf = frame().filter(kpl.col("x") > kpl.col("x").mean())
    window = WindowExpr("avg", "x", 0, ())
    kept = Filter(extend(T, [(win(0), window)]), Compare("gt", c("x"), c(win(0))))
    assert lf._plan == Project(kept, ALL)
    assert lf.columns == [n for n, _ in TYPES]
    assert lf._order is None


def test_a_filter_with_a_window_keeps_the_sort_of_an_ordered_frame_on_top():
    lf = frame().sort("id").filter(kpl.col("x") > kpl.col("x").mean())
    window = WindowExpr("avg", "x", 0, ())
    kept = Filter(extend(T, [(win(0), window)]), Compare("gt", c("x"), c(win(0))))
    assert lf._plan == Sort(Project(kept, ALL), ID_ORDER)
    assert lf._order == ID_ORDER


def test_over_makes_an_aggregate_a_window_per_partition():
    lf = frame().with_columns(kpl.col("x").sum().over("g").alias("t"))
    window = WindowExpr("sum", "x", 0, ("g",))
    assert lf._plan == Project(extend(T, [(win(0), window)]), ALL + (("t", total(win(0), 0)),))
    two = frame().with_columns(kpl.col("x").sum().over("g", kpl.col("flag")).alias("t"))
    assert two._plan.child.items[-1][1] == WindowExpr("sum", "x", 0, ("g", "flag"))


def test_len_over_a_key_counts_the_rows_of_the_partition_through_a_literal_column():
    lf = frame().with_columns(kpl.len().over("g"))
    window = WindowExpr("count", arg(0), 0, ("g",))
    below = extend(extend(T, [(arg(0), Lit(1))]), [(win(1), window)])
    assert lf._plan == Project(below, ALL + (("len", c(win(1))),))
    assert lf.schema["len"] == pa.int64()


# ---- rank -----------------------------------------------------------------------


def test_rank_min_is_a_rank_window_ordered_by_the_value_and_null_where_it_is_null():
    lf = frame().with_columns(kpl.col("x").rank("min").alias("r"))
    window = WindowExpr("rank", None, 0, (), (SortKey("x"),))
    assert lf._plan == Project(
        extend(T, [(win(0), window)]), ALL + (("r", null_where_null("x", c(win(0)))),)
    )
    assert lf.schema["r"] == pa.int64()


def test_rank_dense_descending_orders_the_window_by_the_value_downwards():
    lf = frame().with_columns(kpl.col("y").rank("dense", descending=True).alias("r"))
    window = WindowExpr("dense_rank", None, 0, (), (SortKey("y", True),))
    assert lf._plan == Project(
        extend(T, [(win(0), window)]), ALL + (("r", null_where_null("y", c(win(0)))),)
    )
    assert lf.schema["r"] == pa.int64()


def test_rank_max_is_the_count_less_the_rank_the_other_way_plus_one():
    lf = frame().with_columns(kpl.col("x").rank("max").alias("r"))
    counted = WindowExpr("count", "x", 0, ())
    behind = WindowExpr("rank", None, 0, (), (SortKey("x", True),))
    top = Arith("add", Arith("sub", c(win(0)), c(win(1))), Lit(1))
    assert lf._plan == Project(
        extend(T, [(win(0), counted), (win(1), behind)]), ALL + (("r", null_where_null("x", top)),)
    )
    assert lf.schema["r"] == pa.int64()


def test_rank_average_is_the_mean_of_the_min_and_max_ranks():
    lf = frame().with_columns(kpl.col("x").rank().alias("r"))
    counted = WindowExpr("count", "x", 0, ())
    behind = WindowExpr("rank", None, 0, (), (SortKey("x", True),))
    ahead = WindowExpr("rank", None, 0, (), (SortKey("x"),))
    top = Arith("add", Arith("sub", c(win(0)), c(win(1))), Lit(1))
    average = Arith("div", Cast(Arith("add", c(win(2)), top), "float64"), Lit(2.0))
    assert lf._plan == Project(
        extend(T, [(win(0), counted), (win(1), behind), (win(2), ahead)]),
        ALL + (("r", null_where_null("x", average)),),
    )
    assert lf.schema["r"] == pa.float64()


def test_rank_refusals():
    refused(
        lambda: kpl.col("x").rank("ordinal"),
        UnsupportedOperation,
        "rank: method='ordinal' breaks ties by row order, and a plan has no row order; use "
        "method='min', 'max', 'dense' or 'average'",
    )
    refused(
        lambda: kpl.col("x").rank("random"),
        UnsupportedOperation,
        "rank: method='random' breaks ties at random, and a plan has no row order; use "
        "method='min', 'max', 'dense' or 'average'",
    )
    refused(
        lambda: kpl.col("x").rank(seed=1),
        UnsupportedOperation,
        "rank: seed= is for method='random', which is not supported",
    )
    refused(
        lambda: kpl.col("x").rank("first"),
        ValueError,
        "rank: method must be one of 'average', 'min', 'max', 'dense', 'ordinal', 'random', "
        "not 'first'",
    )


# ---- cum_* -----------------------------------------------------------------------

RUNNING = Frame("rows", "unbounded_preceding", "current_row")


def test_cum_sum_on_a_sorted_frame_is_a_running_window_in_the_frames_order():
    lf = frame().sort("id").with_columns(kpl.col("x").cum_sum().alias("c"))
    window = WindowExpr("sum", "x", 0, (), ID_ORDER, RUNNING)
    inner = Project(extend(T, [(win(0), window)]), ALL + (("c", null_where_null("x", c(win(0)))),))
    assert lf._plan == Sort(inner, ID_ORDER)
    assert lf._order == ID_ORDER
    assert lf.schema["c"] == pa.int64()


def test_cum_sum_reverse_reads_the_rows_in_the_other_order():
    lf = frame().sort("id").with_columns(kpl.col("x").cum_sum(reverse=True).alias("c"))
    window = WindowExpr("sum", "x", 0, (), (SortKey("id", True, False),), RUNNING)
    inner = Project(extend(T, [(win(0), window)]), ALL + (("c", null_where_null("x", c(win(0)))),))
    assert lf._plan == Sort(inner, ID_ORDER)
    assert lf._order == ID_ORDER


def test_cum_sum_over_order_by_reads_the_rows_per_partition_of_an_unordered_frame():
    lf = frame().with_columns(kpl.col("x").cum_sum().over("g", order_by="id").alias("c"))
    window = WindowExpr("sum", "x", 0, ("g",), ID_ORDER, RUNNING)
    assert lf._plan == Project(
        extend(T, [(win(0), window)]), ALL + (("c", null_where_null("x", c(win(0)))),)
    )
    assert lf._order is None


def test_cum_count_counts_the_values_that_are_not_null_and_is_an_int64():
    lf = frame().sort("id").with_columns(kpl.col("y").cum_count().alias("n"))
    window = WindowExpr("count", "y", 0, (), ID_ORDER, RUNNING)
    assert lf._plan == Sort(Project(extend(T, [(win(0), window)]), ALL + (("n", c(win(0))),)), ID_ORDER)
    assert lf.schema["n"] == pa.int64()


def test_cum_min_of_a_float_column_keeps_the_type_and_is_null_where_the_value_is():
    lf = frame().sort("id").with_columns(kpl.col("y").cum_min().alias("m"))
    window = WindowExpr("min", "y", 0, (), ID_ORDER, RUNNING)
    inner = Project(extend(T, [(win(0), window)]), ALL + (("m", null_where_null("y", c(win(0)))),))
    assert lf._plan == Sort(inner, ID_ORDER)
    assert lf.schema["m"] == pa.float64()


def test_cum_max_of_an_int32_column_reads_int64_and_is_cast_back_in_place():
    lf = frame().with_columns(kpl.col("i32").cum_max().over(order_by="id"))
    window = WindowExpr("max", arg(0), 0, (), ID_ORDER, RUNNING)
    node = Cast(null_where_null("i32", c(win(1))), "int32")
    below = extend(extend(T, [(arg(0), Cast(c("i32"), "int64"))]), [(win(1), window)])
    assert lf._plan == Project(below, replacing("i32", node))
    assert lf.columns == [n for n, _ in TYPES]
    assert lf.schema["i32"] == pa.int32()


def test_cum_refusals():
    ordered = (
        "with_columns: {}() reads the rows in order, and a plan promises no row order unless it "
        "is sorted; sort(...) the frame first, or give the order with .over(..., order_by=...)"
    )
    refused(
        lambda: frame().with_columns(kpl.col("x").cum_sum()),
        UnsupportedOperation,
        ordered.format("cum_sum"),
    )
    refused(
        lambda: frame().with_columns(kpl.col("x").cum_count(reverse=True)),
        UnsupportedOperation,
        ordered.format("cum_count"),
    )
    refused(
        lambda: frame().sort("id").with_columns(kpl.col("g").cum_min()),
        UnsupportedOperation,
        "cum_min of a column of type string is not supported; the window reads "
        "int8 to int64 and float64",
    )
    refused(
        lambda: frame().sort("id").with_columns(kpl.col("g").cum_sum()),
        UnsupportedOperation,
        "cum_sum of a column of type string is not supported yet",
    )
    refused(
        lambda: frame().sort("id").with_columns(kpl.col("x").cum_sum().cum_max()),
        UnsupportedOperation,
        "with_columns: a window over the result of another window is not supported; compute the "
        "inner one with with_columns(...) first",
    )
    refused(
        lambda: kpl.col("x").sum().cum_sum(),
        UnsupportedOperation,
        "cum_sum: 'x' is already an aggregate; an aggregate of an aggregate is not supported",
    )
    refused(lambda: kpl.col("x").cum_sum(reverse=1), TypeError, "cum_sum: reverse must be a bool, not int")


# ---- rolling_* ---------------------------------------------------------------------


def test_rolling_sum_is_a_sum_window_over_the_rows_up_to_this_one_null_below_min_samples():
    lf = frame().sort("id").with_columns(kpl.col("x").rolling_sum(3).alias("r"))
    rows = Frame("rows", "preceding", "current_row", 2)
    summed = WindowExpr("sum", "x", 0, (), ID_ORDER, rows)
    counted = WindowExpr("count", "x", 0, (), ID_ORDER, rows)
    out = When(((Compare("lt", c(win(1)), Lit(3)), Lit(None)),), c(win(0)))
    inner = Project(extend(T, [(win(0), summed), (win(1), counted)]), ALL + (("r", out),))
    assert lf._plan == Sort(inner, ID_ORDER)
    assert lf._order == ID_ORDER
    assert lf.schema["r"] == pa.int64()


def test_rolling_mean_with_min_samples_is_a_float_replacing_the_column():
    lf = frame().with_columns(kpl.col("y").rolling_mean(2, min_samples=1).over(order_by="id"))
    rows = Frame("rows", "preceding", "current_row", 1)
    mean = WindowExpr("avg", "y", 0, (), ID_ORDER, rows)
    counted = WindowExpr("count", "y", 0, (), ID_ORDER, rows)
    out = When(((Compare("lt", c(win(1)), Lit(1)), Lit(None)),), c(win(0)))
    assert lf._plan == Project(
        extend(T, [(win(0), mean), (win(1), counted)]), replacing("y", out)
    )
    assert lf.schema["y"] == pa.float64()


def test_rolling_window_of_one_row_is_the_current_row():
    lf = frame().with_columns(kpl.col("x").rolling_max(1).over(order_by="id").alias("r"))
    one = Frame("rows", "current_row", "current_row")
    assert lf._plan.child.items[-2:] == (
        (win(0), WindowExpr("max", "x", 0, (), ID_ORDER, one)),
        (win(1), WindowExpr("count", "x", 0, (), ID_ORDER, one)),
    )


def test_rolling_refusals():
    refused(
        lambda: kpl.col("x").rolling_sum(3, weights=[1.0, 2.0, 3.0]),
        UnsupportedOperation,
        "rolling_sum: weights= is not supported; a window frame has no weights",
    )
    refused(
        lambda: kpl.col("x").rolling_sum(3, center=True),
        UnsupportedOperation,
        "rolling_sum: center=True is not supported; the window is the rows up to the current one",
    )
    refused(
        lambda: kpl.col("x").rolling_sum(3, min_samples=4),
        ValueError,
        "rolling_sum: min_samples (4) must be at most window_size (3)",
    )
    refused(
        lambda: kpl.col("x").rolling_mean(0),
        ValueError,
        "rolling_mean: window_size must be at least 1, not 0",
    )
    refused(
        lambda: kpl.col("x").rolling_min(2.5),
        TypeError,
        "rolling_min: window_size must be an int, not float",
    )
    refused(
        lambda: frame().with_columns(kpl.col("x").rolling_sum(3)),
        UnsupportedOperation,
        "with_columns: rolling_sum(3) reads the rows in order, and a plan promises no row order "
        "unless it is sorted; sort(...) the frame first, or give the order with "
        ".over(..., order_by=...)",
    )
    refused(
        lambda: frame().sort("id").with_columns(kpl.col("g").rolling_sum(3)),
        UnsupportedOperation,
        "rolling_sum of a column of type string is not supported yet; cast it to "
        "int64 or float64",
    )


# ---- refusals of windows and of broadcasts ------------------------------------------


def test_over_refusals():
    refused(
        lambda: kpl.col("x").sum().over("g", mapping_strategy="explode"),
        UnsupportedOperation,
        "over: mapping_strategy='explode' changes the number of rows or gives a list; only "
        "mapping_strategy='group_to_rows' is supported",
    )
    refused(lambda: kpl.col("x").sum().over(), ValueError, "over needs a partition key or an order_by")
    refused(
        lambda: frame().with_columns(kpl.col("x").sum().over(kpl.col("x") + 1)),
        UnsupportedOperation,
        "over: the partition key 'x' is an expression, which is not supported; add it with "
        "with_columns(...) and name its column",
    )
    refused(
        lambda: frame().with_columns(kpl.col("x").sum().over("g").over("flag")),
        UnsupportedOperation,
        "with_columns: over() inside over() is not supported",
    )
    refused(
        lambda: frame().with_columns(kpl.col("x").sum().over("g", "g")),
        ValueError,
        "over: a partition key is named more than once",
    )


def test_an_aggregate_with_no_window_function_is_refused_over_rows():
    refused(
        lambda: frame().with_columns(kpl.col("x").n_unique().over("g")),
        UnsupportedOperation,
        "with_columns: n_unique() of 'x' over rows (a window) is not supported: the plan has no "
        "window function for it; aggregate it in group_by().agg(...) and join the result",
    )
    refused(
        lambda: frame().with_columns(kpl.col("y").median().over("g")),
        UnsupportedOperation,
        "with_columns: median() of 'y' over rows (a window) is not supported: the plan has no "
        "window function for it; aggregate it in group_by().agg(...) and join the result",
    )


def test_a_window_aggregate_of_a_string_column_is_refused():
    refused(
        lambda: frame().with_columns(kpl.col("g").min().alias("m")),
        UnsupportedOperation,
        "with_columns: min() of 'g' over rows (a window) of type string is not supported; the "
        "window reads int8 to int64 and float64",
    )


def test_a_window_inside_an_aggregate_is_refused():
    refused(
        lambda: frame().select(kpl.col("x").rank().sum()),
        UnsupportedOperation,
        "select: rank(method='average') is a window inside an aggregate or a sort key, which is "
        "not supported",
    )
    refused(
        lambda: frame().select(kpl.col("x").sum().rank()),
        UnsupportedOperation,
        "rank: 'x' is already an aggregate; an aggregate of an aggregate is not supported",
    )


# ---- terminals ------------------------------------------------------------------


def test_collect_hands_the_session_plan_bytes_with_no_sql_text():
    SESSION.ran.clear()
    frames = [
        frame().group_by("g").agg(kpl.col("x").sum(), kpl.len()),
        frame().join(right(), on="g"),
        frame().unique("g"),
        frame().sort("id").with_columns(
            kpl.col("x").cum_sum().alias("c"), kpl.col("x").rank().over("g").alias("r")
        ),
    ]
    for lf in frames:
        assert lf.collect() == "result"
    assert len(SESSION.ran) == len(frames)
    for lf, plan in zip(frames, SESSION.ran):
        envelope = pb.WirePlanEnvelope()
        envelope.ParseFromString(plan)
        for word in (b"SELECT", b"FROM", b"GROUP BY", b"JOIN", b"OVER", b"PARTITION BY"):
            assert word not in plan, word
        assert [f.name for f in envelope.plan.output_schema.fields] == lf.columns


def main():
    tests = [(n, f) for n, f in globals().items() if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("pl_frames: {} tests passed".format(len(tests)))


if __name__ == "__main__":
    main()
