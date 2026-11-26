"""The pandas skin (komira) and the polars skin (komira.pl) held to each other,
as plans, with no library.

Both skins are built over one stand-in `Session` whose file schemas are written
here as the engine's `WireSchema` bytes and whose terminals record the plan
bytes they are given. `komira.read_parquet(PATH, session=S)` and
`kpl.scan_parquet(PATH, session=S)` start from the same Scan and the same
sources, and:

- the equal table: for each program that means the same in both skins (a filter
  with each comparison operator, `&`, `|`, `~` and a boolean column, a
  projection, a column set by arithmetic, a cast or a string function, a sort
  with its null placement, a head and a tail, a group-by with each aggregate,
  a merge or join of each kind, a concat, a distinct, a dropna, a rename, an
  isin, a between, and programs stacked on one another), the pandas frame's
  plan equals the polars frame's plan, the column names are equal, the
  sources are equal, and the plan bytes (`_plan_bytes()` and `_encode()`) are
  equal. The table holds the programs whose trees are equal; a program
  missing from it is not claimed to agree;
- the terminals: `materialize()` and `collect()` hand the session exactly the
  bytes `_plan_bytes()` and `_encode()` give, and `explain()` of both hands
  the session those bytes to render;
- the comparison tells programs apart: two programs of one skin that differ in
  meaning (a filter before a join and after it, `count(*)` and the count of a
  column, `nunique` and `count`, ascending and descending, `head(3)` and
  `head(4)`, an inner and a left join) give unequal trees and unequal bytes
  in each skin, while each program still agrees across the skins;
- the differences the rulings give the skins on purpose, each held to exactly
  its nodes: a pandas group-by adds the filter of the null keys and the sort
  of the keys, a pandas sort puts nulls last and a polars sort first, a pandas
  dropna of a float column adds the NaN test, a polars int literal column is
  an int32 cast, polars `n_unique` counts a null and pandas `nunique` does
  not, a polars join drops the right key it coalesces, the temporary name of a
  right key under a join, a polars float to int cast truncates first, and a
  rename of an unknown column is ignored by pandas and refused by polars;
- the refusals the skins share: an unknown column is a `KeyError` with one
  message on both skins (with and without a near-miss suggestion) from a
  subscript or select, a sort, a group-by, a dropna or drop_nulls, the keys
  of a merge or join, a cast and a rename.

The test loads no library and is of the `pl/` family (python/tests/BUCK): it
runs on each supported minor, with the generated plan modules, protobuf 7.36.2
and pyarrow.

    skins_agree_test
"""

import dataclasses
import operator
import os
import tempfile
from collections import namedtuple

import pyarrow as pa

import komira
import komira.pl as kpl
from komira import Session
from komira._missing import not_nan
from komira._ops import (
    Agg,
    Aggregate,
    Arith,
    BoolOp,
    Cast,
    ColRef,
    Compare,
    Field,
    Filter,
    Join,
    Lit,
    Project,
    Scan,
    Sort,
    SortKey,
    Unary,
    When,
    and_all,
)
from komira._plan._wire import arrow_id, field, pb

# Never opened: the stand-in answers its schema.
PATH = os.path.join(tempfile.gettempdir(), "skins_t.parquet")
PATH_R2 = os.path.join(tempfile.gettempdir(), "skins_r2.parquet")
PATH_RG = os.path.join(tempfile.gettempdir(), "skins_rg.parquet")
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
# A right side with no column of the left's, and one that shares only `g`.
R2_TYPES = [("rid", "int64"), ("w2", "float64")]
RG_TYPES = [("g", "string"), ("w", "float64")]
COLUMNS = [n for n, _ in TYPES]
LISTED = ", ".join(COLUMNS)

T = Scan(PATH, "parquet", tuple(Field(n, t) for n, t in TYPES))
R2 = Scan(PATH_R2, "parquet", tuple(Field(n, t) for n, t in R2_TYPES))
RG = Scan(PATH_RG, "parquet", tuple(Field(n, t) for n, t in RG_TYPES))


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


SESSION = StandIn({PATH: TYPES, PATH_R2: R2_TYPES, PATH_RG: RG_TYPES})


class Frames:
    """The three files of the stand-in as frames of one skin."""

    def __init__(self, t, r2, rg):
        self.t, self.r2, self.rg = t, r2, rg


def pandas_frames():
    return Frames(
        komira.read_parquet(PATH, session=SESSION),
        komira.read_parquet(PATH_R2, session=SESSION),
        komira.read_parquet(PATH_RG, session=SESSION),
    )


def polars_frames():
    return Frames(
        kpl.scan_parquet(PATH, session=SESSION),
        kpl.scan_parquet(PATH_R2, session=SESSION),
        kpl.scan_parquet(PATH_RG, session=SESSION),
    )


def c(name):
    return ColRef(name)


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def ident(names):
    """A projection's items that keep the columns `names` as they are."""
    return tuple((n, c(n)) for n in names)


def agree(name, pandas_frame, polars_frame):
    """Both frames hold one tree, one column list, one set of sources and one
    set of plan bytes."""
    assert isinstance(pandas_frame, komira.DataFrame), "{}: the pandas program gave {!r}".format(
        name, type(pandas_frame)
    )
    assert isinstance(polars_frame, kpl.LazyFrame), "{}: the polars program gave {!r}".format(
        name, type(polars_frame)
    )
    assert pandas_frame._plan == polars_frame._plan, "{}: the trees differ\n  pandas: {!r}\n  polars: {!r}".format(
        name, pandas_frame._plan, polars_frame._plan
    )
    assert pandas_frame.columns == polars_frame.columns, "{}: the columns differ: {} and {}".format(
        name, pandas_frame.columns, polars_frame.columns
    )
    assert pandas_frame._sources == polars_frame._sources, "{}: the sources differ".format(name)
    assert pandas_frame._plan_bytes() == polars_frame._encode(), "{}: the plan bytes differ".format(name)


def differ(name, first, second, bytes_of):
    """Two frames of one skin that mean different things: unequal trees and
    unequal plan bytes."""
    assert first._plan != second._plan, "{}: the trees are equal: {!r}".format(name, first._plan)
    assert bytes_of(first) != bytes_of(second), "{}: the plan bytes are equal".format(name)


def pandas_bytes(frame):
    return frame._plan_bytes()


def polars_bytes(frame):
    return frame._encode()


Case = namedtuple("Case", "name pandas polars")
col = kpl.col

# ---- the equal table -----------------------------------------------------------

CASES = []


def case(name, pandas, polars):
    assert name not in [k.name for k in CASES], name
    CASES.append(Case(name, pandas, polars))


# filters
_COMPARISONS = [
    ("eq", operator.eq),
    ("ne", operator.ne),
    ("lt", operator.lt),
    ("le", operator.le),
    ("gt", operator.gt),
    ("ge", operator.ge),
]
for _op_name, _op in _COMPARISONS:
    case(
        "filter_int_column_{}_int_literal".format(_op_name),
        lambda f, _op=_op: f.t[_op(f.t["x"], 1)],
        lambda f, _op=_op: f.t.filter(_op(col("x"), 1)),
    )
case("filter_float_column_lt_float_literal", lambda f: f.t[f.t["y"] < 2.0], lambda f: f.t.filter(col("y") < 2.0))
case("filter_string_column_eq_string_literal", lambda f: f.t[f.t["g"] == "a"], lambda f: f.t.filter(col("g") == "a"))
case(
    "filter_and",
    lambda f: f.t[(f.t["x"] > 1) & (f.t["y"] < 2.0)],
    lambda f: f.t.filter((col("x") > 1) & (col("y") < 2.0)),
)
case(
    "filter_or",
    lambda f: f.t[(f.t["x"] > 1) | (f.t["g"] == "a")],
    lambda f: f.t.filter((col("x") > 1) | (col("g") == "a")),
)
case("filter_not", lambda f: f.t[~(f.t["x"] > 1)], lambda f: f.t.filter(~(col("x") > 1)))
case("filter_bool_column", lambda f: f.t[f.t["flag"]], lambda f: f.t.filter(col("flag")))
case("filter_not_bool_column", lambda f: f.t[~f.t["flag"]], lambda f: f.t.filter(~col("flag")))
case(
    "filter_several_predicates_is_a_left_nested_and",
    lambda f: f.t[(f.t["x"] > 1) & (f.t["id"] > 0) & f.t["flag"]],
    lambda f: f.t.filter(col("x") > 1, col("id") > 0, col("flag")),
)
case("filter_column_vs_column", lambda f: f.t[f.t["x"] > f.t["id"]], lambda f: f.t.filter(col("x") > col("id")))
case("filter_isin_list", lambda f: f.t[f.t["x"].isin([1, 2, 3])], lambda f: f.t.filter(col("x").is_in([1, 2, 3])))
_BETWEEN = {
    "both": (operator.ge, operator.le),
    "left": (operator.ge, operator.lt),
    "right": (operator.gt, operator.le),
    "none": (operator.gt, operator.lt),
}
for _closed, (_lo, _hi) in _BETWEEN.items():
    case(
        "filter_between_closed_{}".format(_closed),
        lambda f, _lo=_lo, _hi=_hi: f.t[_lo(f.t["x"], 1) & _hi(f.t["x"], 5)],
        lambda f, _closed=_closed: f.t.filter(col("x").is_between(1, 5, closed=_closed)),
    )
case(
    "filter_string_contains_literal",
    lambda f: f.t[f.t["g"].str.contains("a", regex=False)],
    lambda f: f.t.filter(col("g").str.contains("a", literal=True)),
)
case(
    "filter_string_startswith",
    lambda f: f.t[f.t["g"].str.startswith("a")],
    lambda f: f.t.filter(col("g").str.starts_with("a")),
)
case(
    "filter_string_endswith",
    lambda f: f.t[f.t["g"].str.endswith("a")],
    lambda f: f.t.filter(col("g").str.ends_with("a")),
)

# projections
case("select_two_columns", lambda f: f.t[["id", "x"]], lambda f: f.t.select("id", "x"))
case("select_reordered", lambda f: f.t[["x", "id"]], lambda f: f.t.select("x", "id"))
case("select_every_column_is_the_scan", lambda f: f.t[f.t.columns], lambda f: f.t.select(f.t.columns))
case(
    "select_without_two_columns",
    lambda f: f.t[[n for n in f.t.columns if n not in ("flag", "f32")]],
    lambda f: f.t.drop("flag", "f32"),
)
case(
    "select_after_filter",
    lambda f: f.t[f.t["x"] > 1][["id", "x"]],
    lambda f: f.t.filter(col("x") > 1).select("id", "x"),
)

# columns set by arithmetic, literals, casts and string functions
case(
    "assign_int_column_plus_int_literal",
    lambda f: f.t.assign(z=f.t["x"] + 1),
    lambda f: f.t.with_columns((col("x") + 1).alias("z")),
)
case(
    "assign_two_int_columns",
    lambda f: f.t.assign(a=f.t["x"] + f.t["id"], b=f.t["x"] * f.t["id"], d=f.t["x"] - f.t["id"]),
    lambda f: f.t.with_columns(
        (col("x") + col("id")).alias("a"),
        (col("x") * col("id")).alias("b"),
        (col("x") - col("id")).alias("d"),
    ),
)
case(
    "assign_reflected_subtraction_and_negation",
    lambda f: f.t.assign(a=1 - f.t["x"], b=-f.t["x"]),
    lambda f: f.t.with_columns((1 - col("x")).alias("a"), (-col("x")).alias("b")),
)
case(
    "assign_true_division_of_columns_and_by_a_float_literal",
    lambda f: f.t.assign(a=f.t["x"] / f.t["y"], b=f.t["y"] / 2.0),
    lambda f: f.t.with_columns((col("x") / col("y")).alias("a"), (col("y") / 2.0).alias("b")),
)
case("assign_float_and_string_literals", lambda f: f.t.assign(d=1.5, e="a"), lambda f: f.t.with_columns(d=1.5, e="a"))
case(
    "assign_string_lower_upper_and_length",
    lambda f: f.t.assign(a=f.t["g"].str.lower(), b=f.t["g"].str.upper(), n=f.t["g"].str.len()),
    lambda f: f.t.with_columns(
        col("g").str.to_lowercase().alias("a"),
        col("g").str.to_uppercase().alias("b"),
        col("g").str.len_chars().alias("n"),
    ),
)
case(
    "assign_astype_numeric_and_string",
    lambda f: f.t.assign(
        a=f.t["x"].astype("float64"), b=f.t["x"].astype("string"), n=f.t["x"].astype("int32")
    ),
    lambda f: f.t.with_columns(
        col("x").cast("float64").alias("a"),
        col("x").cast("string").alias("b"),
        col("x").cast("int32").alias("n"),
    ),
)
case(
    "astype_one_column_replaces_it",
    lambda f: f.t.astype({"x": "float64"}),
    lambda f: f.t.with_columns(col("x").cast("float64")),
)

# sorts and limits
case("sort_nulls_last", lambda f: f.t.sort_values("x"), lambda f: f.t.sort("x", nulls_last=True))
case("sort_nulls_first", lambda f: f.t.sort_values("x", na_position="first"), lambda f: f.t.sort("x"))
case(
    "sort_descending_nulls_last",
    lambda f: f.t.sort_values("x", ascending=False),
    lambda f: f.t.sort("x", descending=True, nulls_last=True),
)
case(
    "sort_several_keys_with_a_direction_each",
    lambda f: f.t.sort_values(["g", "x"], ascending=[True, False]),
    lambda f: f.t.sort(["g", "x"], descending=[False, True], nulls_last=True),
)
case(
    "sort_keys_as_varargs",
    lambda f: f.t.sort_values(["g", "x"], ascending=[True, False]),
    lambda f: f.t.sort("g", "x", descending=[False, True], nulls_last=True),
)
case(
    "sort_twice_keeps_the_last_sort",
    lambda f: f.t.sort_values("x", na_position="first").sort_values("id", na_position="first"),
    lambda f: f.t.sort("x").sort("id"),
)
case("head", lambda f: f.t.head(3), lambda f: f.t.head(3))
case("limit", lambda f: f.t.head(3), lambda f: f.t.limit(3))
case("head_default_count", lambda f: f.t.head(), lambda f: f.t.head())
case("sort_then_head", lambda f: f.t.sort_values("x", na_position="first").head(3), lambda f: f.t.sort("x").head(3))
case(
    "tail_of_a_sorted_frame",
    lambda f: f.t.sort_values("x", na_position="first").tail(3),
    lambda f: f.t.sort("x").tail(3),
)


def _pandas_filter_after_sorted_head(f):
    cut = f.t.sort_values("x", na_position="first").head(3)
    return cut[cut["y"] > 1.0]


def _pandas_assign_on_sorted(f):
    ordered = f.t.sort_values("x", na_position="first")
    return ordered.assign(z=ordered["id"] + 1)


def _pandas_select_on_sorted(f):
    ordered = f.t.sort_values("x", na_position="first")
    return ordered[["x", "id"]]


def _pandas_filter_on_sorted(f):
    ordered = f.t.sort_values("x", na_position="first")
    return ordered[ordered["y"] > 1.0]


case(
    "filter_after_a_sorted_head_sorts_again_above",
    _pandas_filter_after_sorted_head,
    lambda f: f.t.sort("x").head(3).filter(col("y") > 1.0),
)
case(
    "assign_on_a_sorted_frame_keeps_the_sort_at_the_root",
    _pandas_assign_on_sorted,
    lambda f: f.t.sort("x").with_columns((col("id") + 1).alias("z")),
)
case(
    "select_on_a_sorted_frame_keeps_the_sort_at_the_root",
    _pandas_select_on_sorted,
    lambda f: f.t.sort("x").select("x", "id"),
)
case(
    "filter_on_a_sorted_frame_keeps_the_sort_at_the_root",
    _pandas_filter_on_sorted,
    lambda f: f.t.sort("x").filter(col("y") > 1.0),
)


# group-by, with the pandas defaults that polars does not have turned off
def _pd_group(f, **kw):
    return f.t.groupby("g", sort=False, dropna=False, **kw)


for _fn in ("max", "min", "count", "mean"):
    case(
        "groupby_{}_of_a_column".format(_fn),
        lambda f, _fn=_fn: getattr(_pd_group(f)["x"], _fn)(),
        lambda f, _fn=_fn: f.t.group_by("g").agg(getattr(col("x"), _fn)()),
    )
case(
    "groupby_min_of_a_float_column",
    lambda f: _pd_group(f)["y"].min(),
    lambda f: f.t.group_by("g").agg(col("y").min()),
)
case("groupby_size_is_len", lambda f: _pd_group(f).size(), lambda f: f.t.group_by("g").agg(kpl.len().alias("size")))
case(
    "groupby_two_keys",
    lambda f: f.t.groupby(["g", "flag"], sort=False, dropna=False)["x"].max(),
    lambda f: f.t.group_by("g", "flag").agg(col("x").max()),
)
case(
    "groupby_named_aggregates",
    lambda f: _pd_group(f).agg(hi=("x", "max"), n=("x", "size"), lo=("y", "min")),
    lambda f: f.t.group_by("g").agg(
        col("x").max().alias("hi"), kpl.len().alias("n"), col("y").min().alias("lo")
    ),
)
case(
    "groupby_two_aggregates_of_one_column",
    lambda f: _pd_group(f).agg(hi=("x", "max"), lo=("x", "min")),
    lambda f: f.t.group_by("g").agg(col("x").max().alias("hi"), col("x").min().alias("lo")),
)
case(
    "whole_frame_named_aggregates",
    lambda f: f.t.agg(m=("x", "max"), n=("x", "size")),
    lambda f: f.t.select(col("x").max().alias("m"), kpl.len().alias("n")),
)
case(
    "groupby_pandas_defaults_spelled_out_in_polars",
    lambda f: f.t.groupby("g")["x"].max(),
    lambda f: f.t.filter(col("g").is_not_null()).group_by("g").agg(col("x").max()).sort("g", nulls_last=True),
)
case(
    "groupby_sorted_keys_spelled_out_in_polars",
    lambda f: f.t.groupby("g", dropna=False)["x"].max(),
    lambda f: f.t.group_by("g").agg(col("x").max()).sort("g", nulls_last=True),
)
case(
    "groupby_dropped_null_keys_spelled_out_in_polars",
    lambda f: f.t.groupby("g", sort=False)["x"].max(),
    lambda f: f.t.filter(col("g").is_not_null()).group_by("g").agg(col("x").max()),
)
case(
    "groupby_of_a_groupby",
    lambda f: _pd_group(f)["x"].max().groupby("x", sort=False, dropna=False).size(),
    lambda f: f.t.group_by("g").agg(col("x").max()).group_by("x").agg(kpl.len().alias("size")),
)
case(
    "groupby_of_a_filtered_and_projected_frame",
    lambda f: f.t[f.t["x"] > 1][["g", "x", "y"]].groupby("g", sort=False, dropna=False)["y"].max(),
    lambda f: f.t.filter(col("x") > 1).select("g", "x", "y").group_by("g").agg(col("y").max()),
)

# merge and join, with the polars right key kept where pandas keeps it
case(
    "merge_inner_on_differently_named_keys",
    lambda f: f.t.merge(f.r2, left_on="id", right_on="rid"),
    lambda f: f.t.join(f.r2, left_on="id", right_on="rid", coalesce=False),
)
case(
    "merge_left_on_differently_named_keys",
    lambda f: f.t.merge(f.r2, how="left", left_on="id", right_on="rid"),
    lambda f: f.t.join(f.r2, how="left", left_on="id", right_on="rid", coalesce=False),
)
case(
    "merge_outer_is_a_full_join",
    lambda f: f.t.merge(f.r2, how="outer", left_on="id", right_on="rid"),
    lambda f: f.t.join(f.r2, how="full", left_on="id", right_on="rid"),
)
case("merge_cross", lambda f: f.t.merge(f.r2, how="cross"), lambda f: f.t.join(f.r2, how="cross"))
case(
    "isin_of_another_frames_column_is_a_semi_join_of_its_key",
    lambda f: f.t[f.t["g"].isin(f.rg["g"])],
    lambda f: f.t.join(f.rg.select("g"), on="g", how="semi"),
)
case(
    "not_isin_of_another_frames_column_is_an_anti_join_of_its_key",
    lambda f: f.t[~f.t["g"].isin(f.rg["g"])],
    lambda f: f.t.join(f.rg.select("g"), on="g", how="anti"),
)
case(
    "isin_of_differently_named_keys",
    lambda f: f.t[f.t["id"].isin(f.r2["rid"])],
    lambda f: f.t.join(f.r2.select("rid"), left_on="id", right_on="rid", how="semi"),
)

# stacking, distinct, missing values and names
case("concat", lambda f: komira.concat([f.t, f.t.head(1)]), lambda f: kpl.concat([f.t, f.t.head(1)]))
case("distinct_over_every_column", lambda f: f.t.drop_duplicates(), lambda f: f.t.unique())
case("dropna_of_non_float_columns", lambda f: f.t.dropna(subset=["x", "g"]), lambda f: f.t.drop_nulls(["x", "g"]))
case("dropna_of_one_non_float_column", lambda f: f.t.dropna(subset="x"), lambda f: f.t.drop_nulls("x"))
case(
    "dropna_subset_equals_filter_of_not_null",
    lambda f: f.t.dropna(subset=["x"]),
    lambda f: f.t.filter(col("x").is_not_null()),
)
case("rename_one_column", lambda f: f.t.rename(columns={"x": "z"}), lambda f: f.t.rename({"x": "z"}))
case(
    "rename_of_an_unknown_column_ignored_on_both",
    lambda f: f.t.rename(columns={"zzz": "a"}),
    lambda f: f.t.rename({"zzz": "a"}, strict=False),
)
case(
    "filter_then_select_then_sort_then_head",
    lambda f: f.t[f.t["x"] > 1][["id", "x", "y"]].sort_values("y", ascending=False).head(4),
    lambda f: f.t.filter(col("x") > 1).select("id", "x", "y").sort("y", descending=True, nulls_last=True).head(4),
)


def test_both_skins_start_from_the_same_scan_and_sources():
    p, q = pandas_frames(), polars_frames()
    for name in ("t", "r2", "rg"):
        agree("scan of " + name, getattr(p, name), getattr(q, name))
    assert p.t._plan == T and p.r2._plan == R2 and p.rg._plan == RG
    assert p.t.columns == COLUMNS


def test_equal_table_names_each_case_once_and_covers_every_verb_family():
    names = [k.name for k in CASES]
    assert len(names) == len(set(names)), "a case name is used twice"
    assert len(names) >= 70, "the table has {} cases".format(len(names))
    for family in ("filter", "select", "assign", "sort", "head", "tail", "groupby", "merge", "concat", "distinct"):
        assert any(n.startswith(family) for n in names), "no case for " + family


def test_every_equal_program_gives_one_tree_one_column_list_and_one_set_of_bytes():
    for k in CASES:
        agree(k.name, k.pandas(pandas_frames()), k.polars(polars_frames()))


# ---- the terminals send those bytes ------------------------------------------------


def _terminal_cases():
    wanted = (
        "filter_int_column_gt_int_literal",
        "groupby_max_of_a_column",
        "groupby_pandas_defaults_spelled_out_in_polars",
        "merge_inner_on_differently_named_keys",
        "sort_then_head",
        "concat",
    )
    by_name = {k.name: k for k in CASES}
    return [by_name[n] for n in wanted]


def test_materialize_and_collect_hand_the_session_the_same_bytes():
    for k in _terminal_cases():
        p, q = k.pandas(pandas_frames()), k.polars(polars_frames())
        SESSION.ran.clear()
        assert p.materialize() == "result", k.name
        assert q.collect() == "result", k.name
        expected = p._plan_bytes()
        assert SESSION.ran == [expected, expected], "{}: the terminals sent different bytes".format(k.name)
        assert expected == q._encode(), k.name


def test_explain_hands_the_session_the_same_bytes_to_render():
    for k in _terminal_cases():
        p, q = k.pandas(pandas_frames()), k.polars(polars_frames())
        SESSION.rendered.clear()
        SESSION.ran.clear()
        assert p.explain() == "rendered", k.name
        assert q.explain() == "rendered", k.name
        expected = p._plan_bytes()
        assert SESSION.rendered == [expected, expected], "{}: explain sent different bytes".format(k.name)
        assert SESSION.ran == [], "{}: explain ran the plan".format(k.name)


# ---- the comparison tells programs apart ---------------------------------------------


def _filter_before_join(f, skin):
    if skin == "pandas":
        return f.t[f.t["x"] > 1].merge(f.r2, left_on="id", right_on="rid")
    return f.t.filter(col("x") > 1).join(f.r2, left_on="id", right_on="rid", coalesce=False)


def _filter_after_join(f, skin):
    if skin == "pandas":
        joined = f.t.merge(f.r2, left_on="id", right_on="rid")
        return joined[joined["x"] > 1]
    return f.t.join(f.r2, left_on="id", right_on="rid", coalesce=False).filter(col("x") > 1)


def _count_rows(f, skin):
    if skin == "pandas":
        return _pd_group(f).agg(n=("x", "size"))
    return f.t.group_by("g").agg(kpl.len().alias("n"))


def _count_column(f, skin):
    if skin == "pandas":
        return _pd_group(f).agg(n=("x", "count"))
    return f.t.group_by("g").agg(col("x").count().alias("n"))


def _count_distinct(f, skin):
    if skin == "pandas":
        return _pd_group(f).agg(n=("x", "nunique"))
    return f.t.group_by("g").agg(col("x").n_unique().alias("n"))


def _sort_ascending(f, skin):
    if skin == "pandas":
        return f.t.sort_values("x", na_position="first")
    return f.t.sort("x")


def _sort_descending(f, skin):
    if skin == "pandas":
        return f.t.sort_values("x", ascending=False, na_position="first")
    return f.t.sort("x", descending=True)


def _head_three(f, skin):
    return f.t.head(3)


def _head_four(f, skin):
    return f.t.head(4)


def _inner_join(f, skin):
    if skin == "pandas":
        return f.t.merge(f.r2, left_on="id", right_on="rid")
    return f.t.join(f.r2, left_on="id", right_on="rid", coalesce=False)


def _left_join(f, skin):
    if skin == "pandas":
        return f.t.merge(f.r2, how="left", left_on="id", right_on="rid")
    return f.t.join(f.r2, how="left", left_on="id", right_on="rid", coalesce=False)


DIFFERENT_MEANINGS = [
    ("filter before a join and after it", _filter_before_join, _filter_after_join),
    ("count of rows and count of a column", _count_rows, _count_column),
    ("count of a column and count of distinct values", _count_column, _count_distinct),
    ("sort ascending and descending", _sort_ascending, _sort_descending),
    ("head 3 and head 4", _head_three, _head_four),
    ("inner join and left join", _inner_join, _left_join),
]


def test_programs_of_different_meaning_give_unequal_trees_and_bytes_in_each_skin():
    for name, first, second in DIFFERENT_MEANINGS:
        p, q = pandas_frames(), polars_frames()
        differ("pandas " + name, first(p, "pandas"), second(p, "pandas"), pandas_bytes)
        differ("polars " + name, first(q, "polars"), second(q, "polars"), polars_bytes)


def test_the_programs_of_different_meaning_each_still_agree_across_the_skins():
    # The pairs above are not unequal because the skins build one of them
    # differently: each side of each pair is equal across the skins, except
    # where a pair holds a polars construction the ruling gives (the null-aware
    # n_unique), which the deliberate-difference tests hold.
    for name, first, second in DIFFERENT_MEANINGS:
        if first is _count_distinct or second is _count_distinct:
            sides = [s for s in (first, second) if s is not _count_distinct]
        else:
            sides = [first, second]
        for side in sides:
            agree(name, side(pandas_frames(), "pandas"), side(polars_frames(), "polars"))


# ---- the differences the rulings give the skins on purpose ------------------------


def test_pandas_groupby_defaults_add_the_null_key_filter_and_the_key_sort():
    f, g = pandas_frames(), polars_frames()
    base = g.t.group_by("g").agg(col("x").max())._plan
    assert base == Aggregate(T, ("g",), (("x", Agg("max", (c("x"),))),))
    keys_present = Unary("is_not_null", c("g"))
    filtered = Aggregate(Filter(base.child, keys_present), base.keys, base.aggs)
    sorted_keys = (SortKey("g"),)

    both = f.t.groupby("g")["x"].max()._plan
    assert both == Sort(filtered, sorted_keys), both
    assert both != base
    dropna_only = f.t.groupby("g", sort=False)["x"].max()._plan
    assert dropna_only == filtered, dropna_only
    sort_only = f.t.groupby("g", dropna=False)["x"].max()._plan
    assert sort_only == Sort(base, sorted_keys), sort_only
    neither = f.t.groupby("g", sort=False, dropna=False)["x"].max()._plan
    assert neither == base, neither


def test_pandas_sort_puts_nulls_last_and_polars_first_and_nothing_else_differs():
    f, g = pandas_frames(), polars_frames()
    by_polars = g.t.sort(["g", "x"], descending=[False, True])._plan
    assert by_polars == Sort(T, (SortKey("g", False, True), SortKey("x", True, True)))
    by_pandas = f.t.sort_values(["g", "x"], ascending=[True, False])._plan
    assert by_pandas == Sort(T, tuple(dataclasses.replace(k, nulls_first=False) for k in by_polars.keys))
    assert by_pandas.child == by_polars.child
    assert [(k.column, k.descending) for k in by_pandas.keys] == [(k.column, k.descending) for k in by_polars.keys]
    assert [k.nulls_first for k in by_pandas.keys] == [False, False]
    assert [k.nulls_first for k in by_polars.keys] == [True, True]


def test_pandas_dropna_of_a_float_column_adds_the_nan_test_and_nothing_else():
    f, g = pandas_frames(), polars_frames()
    for name, dtype in (("y", "float64"), ("f32", "float32")):
        polars_plan = g.t.drop_nulls(name)._plan
        assert polars_plan == Filter(T, Unary("is_not_null", c(name))), name
        expected = Filter(T, BoolOp("and", Unary("is_not_null", c(name)), not_nan(c(name), dtype)))
        assert f.t.dropna(subset=[name])._plan == expected, name
    inf = float("inf")
    assert not_nan(c("y"), "float64") == BoolOp(
        "or",
        BoolOp(
            "or",
            BoolOp("and", Compare("gt", c("y"), Lit(-inf)), Compare("lt", c("y"), Lit(inf))),
            Compare("eq", c("y"), Lit(inf)),
        ),
        Compare("eq", c("y"), Lit(-inf)),
    )
    mixed_polars = g.t.drop_nulls(["x", "y"])._plan
    assert mixed_polars == Filter(T, and_all((Unary("is_not_null", c("x")), Unary("is_not_null", c("y")))))
    mixed = Filter(
        T,
        and_all(
            (
                Unary("is_not_null", c("x")),
                BoolOp("and", Unary("is_not_null", c("y")), not_nan(c("y"), "float64")),
            )
        ),
    )
    assert f.t.dropna(subset=["x", "y"])._plan == mixed
    # A column that is not a float has no NaN to test: the skins agree.
    agree("dropna of an int column", f.t.dropna(subset=["x"]), g.t.drop_nulls("x"))


def test_polars_int_literal_column_is_an_int32_cast_and_the_pandas_one_is_an_int64_literal():
    f, g = pandas_frames(), polars_frames()
    by_polars = g.t.with_columns(c=1)
    by_pandas = f.t.assign(c=1)
    assert by_polars._plan == Project(T, ident(COLUMNS) + (("c", Cast(Lit(1), "int32")),))
    assert by_pandas._plan == Project(T, ident(COLUMNS) + (("c", Lit(1)),))
    assert by_pandas.dtypes["c"] == "int64"
    assert by_polars.schema["c"] == pa.int32()
    assert by_pandas.columns == by_polars.columns
    # Only that item differs: the other columns and a float or string literal are the same.
    assert by_pandas._plan.items[:-1] == by_polars._plan.items[:-1]


def test_polars_n_unique_counts_a_null_and_pandas_nunique_does_not():
    f, g = pandas_frames(), polars_frames()
    distinct = Agg("count_distinct", (c("x"),))
    by_pandas = f.t.groupby("g", sort=False, dropna=False)["x"].nunique()
    assert by_pandas._plan == Aggregate(T, ("g",), (("x", distinct),))
    rows, values = "__komira_agg_1", "__komira_agg_2"
    by_polars = g.t.group_by("g").agg(col("x").n_unique())
    assert by_polars._plan == Project(
        Aggregate(
            T,
            ("g",),
            (
                ("__komira_agg_0", distinct),
                (rows, Agg("count")),
                (values, Agg("count", (c("x"),))),
            ),
        ),
        (
            ("g", c("g")),
            (
                "x",
                Arith(
                    "add",
                    c("__komira_agg_0"),
                    When(((Compare("gt", c(rows), c(values)), Lit(1)),), Lit(0)),
                ),
            ),
        ),
    )
    assert by_pandas.columns == by_polars.columns == ["g", "x"]


def test_polars_join_drops_the_right_key_it_coalesces_and_pandas_keeps_both_keys():
    f, g = pandas_frames(), polars_frames()
    by_pandas = f.t.merge(f.r2, left_on="id", right_on="rid")
    assert by_pandas._plan == Join(T, R2, "inner", ("id",), ("rid",))
    assert by_pandas.columns == COLUMNS + ["rid", "w2"]
    key = "__komira_key_rid"
    under_join = Project(R2, ((key, c("rid")), ("w2", c("w2"))))
    by_polars = g.t.join(g.r2, left_on="id", right_on="rid")
    assert by_polars._plan == Project(
        Join(T, under_join, "inner", ("id",), (key,)), ident(COLUMNS) + (("w2", c("w2")),)
    )
    assert by_polars.columns == COLUMNS + ["w2"]
    # With coalesce=False polars keeps the right key, and the skins agree.
    agree("join keeping the right key", by_pandas, g.t.join(g.r2, left_on="id", right_on="rid", coalesce=False))


def test_inner_join_on_a_shared_key_name_differs_only_in_the_right_keys_temporary_name():
    f, g = pandas_frames(), polars_frames()

    def expected(key):
        under_join = Project(RG, ((key, c("g")), ("w", c("w"))))
        return Project(Join(T, under_join, "inner", ("g",), (key,)), ident(COLUMNS) + (("w", c("w")),))

    by_pandas = f.t.merge(f.rg, on="g")
    by_polars = g.t.join(g.rg, on="g")
    assert by_pandas._plan == expected("g_right"), by_pandas._plan
    assert by_polars._plan == expected("__komira_key_g"), by_polars._plan
    assert by_pandas.columns == by_polars.columns == COLUMNS + ["w"]


def test_polars_float_to_int_cast_truncates_first_and_pandas_casts_directly():
    f, g = pandas_frames(), polars_frames()
    by_pandas = f.t.assign(z=f.t["y"].astype("int64"))
    by_polars = g.t.with_columns(col("y").cast("int64").alias("z"))
    assert by_pandas._plan == Project(T, ident(COLUMNS) + (("z", Cast(c("y"), "int64")),))
    assert by_polars._plan == Project(T, ident(COLUMNS) + (("z", Cast(Unary("trunc", c("y")), "int64")),))
    assert by_pandas.columns == by_polars.columns


def test_rename_of_an_unknown_column_is_ignored_by_pandas_and_refused_by_polars():
    f, g = pandas_frames(), polars_frames()
    message = "no column named 'zzz' in this frame; the frame's columns are: " + LISTED
    assert f.t.rename(columns={"zzz": "a"})._plan == T
    e = raised(lambda: g.t.rename({"zzz": "a"}))
    assert type(e) is KeyError and e.args[0] == message, e
    # The aligned spellings: pandas errors="raise" refuses it as polars does,
    # and polars strict=False ignores it as pandas does.
    e = raised(lambda: f.t.rename(columns={"zzz": "a"}, errors="raise"))
    assert type(e) is KeyError and e.args[0] == message, e
    assert g.t.rename({"zzz": "a"}, strict=False)._plan == T


# ---- the refusals the skins share ---------------------------------------------------


def both_refuse_with(call_pandas, call_polars, message):
    for call in (call_pandas, call_polars):
        e = raised(call)
        assert type(e) is KeyError, (type(e), e)
        assert e.args[0] == message, e.args[0]


def missing(name):
    return "no column named '{}' in this frame; the frame's columns are: {}".format(name, LISTED)


def near(name, closest):
    return "no column named '{}' in this frame; the closest is '{}'; the frame's columns are: {}".format(
        name, closest, LISTED
    )


def test_unknown_column_is_one_message_from_a_subscript_or_select():
    f, g = pandas_frames(), polars_frames()
    both_refuse_with(lambda: f.t["zzz"], lambda: g.t.select("zzz"), missing("zzz"))
    both_refuse_with(lambda: f.t["xx"], lambda: g.t.select("xx"), near("xx", "x"))
    both_refuse_with(lambda: f.t[["x", "zzz"]], lambda: g.t.select("x", "zzz"), missing("zzz"))
    both_refuse_with(lambda: f.t[["x", "xx"]], lambda: g.t.select("x", "xx"), near("xx", "x"))


def test_unknown_column_is_one_message_from_a_sort():
    f, g = pandas_frames(), polars_frames()
    both_refuse_with(lambda: f.t.sort_values("zzz"), lambda: g.t.sort("zzz"), missing("zzz"))
    both_refuse_with(lambda: f.t.sort_values(["x", "xx"]), lambda: g.t.sort("x", "xx"), near("xx", "x"))


def test_unknown_column_is_one_message_from_a_groupby():
    f, g = pandas_frames(), polars_frames()
    both_refuse_with(lambda: f.t.groupby("zzz"), lambda: g.t.group_by("zzz"), missing("zzz"))
    both_refuse_with(lambda: f.t.groupby("xx"), lambda: g.t.group_by("xx"), near("xx", "x"))


def test_unknown_column_is_one_message_from_a_dropna_or_drop_nulls():
    f, g = pandas_frames(), polars_frames()
    both_refuse_with(lambda: f.t.dropna(subset=["zzz"]), lambda: g.t.drop_nulls(["zzz"]), missing("zzz"))
    both_refuse_with(lambda: f.t.dropna(subset=["xx"]), lambda: g.t.drop_nulls(["xx"]), near("xx", "x"))


def test_unknown_column_is_one_message_from_the_keys_of_a_merge_or_join():
    f, g = pandas_frames(), polars_frames()
    both_refuse_with(
        lambda: f.t.merge(f.r2, left_on="zzz", right_on="rid"),
        lambda: g.t.join(g.r2, left_on="zzz", right_on="rid"),
        missing("zzz"),
    )
    both_refuse_with(
        lambda: f.t.merge(f.r2, left_on="xx", right_on="rid"),
        lambda: g.t.join(g.r2, left_on="xx", right_on="rid"),
        near("xx", "x"),
    )
    on_the_right = "no column named 'ridd' in this frame; the closest is 'rid'; the frame's columns are: rid, w2"
    both_refuse_with(
        lambda: f.t.merge(f.r2, left_on="id", right_on="ridd"),
        lambda: g.t.join(g.r2, left_on="id", right_on="ridd"),
        on_the_right,
    )


def test_unknown_column_is_one_message_from_a_cast():
    f, g = pandas_frames(), polars_frames()
    both_refuse_with(
        lambda: f.t.astype({"zzz": "int64"}),
        lambda: g.t.with_columns(col("zzz").cast("int64")),
        missing("zzz"),
    )
    both_refuse_with(
        lambda: f.t.astype({"xx": "int64"}),
        lambda: g.t.with_columns(col("xx").cast("int64")),
        near("xx", "x"),
    )


def test_unknown_column_is_one_message_from_a_rename_that_refuses_it():
    f, g = pandas_frames(), polars_frames()
    both_refuse_with(
        lambda: f.t.rename(columns={"xx": "a"}, errors="raise"),
        lambda: g.t.rename({"xx": "a"}),
        near("xx", "x"),
    )


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    for _, f in tests:
        f()
    print("skins_agree: {} tests passed".format(len(tests)))


if __name__ == "__main__":
    main()
