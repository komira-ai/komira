"""komira.pl's group_by, join, unique and windows against polars itself, on
the real libkomira.

As test_pl_oracle.py: each case is one program written once for both modules,
run through komira.pl, whose frame is encoded as a plan and run by
`komira_plan_stream`, and through the pinned polars; its answer must be the
same frame, values and dtypes (`polars.testing.assert_frame_equal`; floats to
its default relative tolerance, rows in order when the frame is ordered and as
a multiset when it is not), and the schema komira.pl derives without running
must be the answer's. Where polars answers UInt32 (a count, `len()`, a rank
other than "average"), komira.pl answers Int64, so polars' column is compared
as Int64.

The left file has nulls in every column but `id`, a string key `g` whose null
is a group of its own, a key with ties `t`, narrow types, and an empty file of
the same columns; the right file has a duplicated key, keys the left lacks, a
null key, and columns named like the left's. The programs cover:

- group_by with one and two keys, a null key, the aggregates the engine's
  grouped sinks serve (sums, means, minimums and maximums of integers and of
  a float, counts), expressions over aggregates, polars' types of a sum over
  int32, uint16 and bool, len(), the per-column reductions, a key given as
  col(), and over the empty file;
- join with each how (inner, left, right, full, semi, anti, cross), on one
  key and two, with left_on/right_on of different names, coalesce=True and
  False, a custom suffix, a null key (which matches nothing), and right
  columns named like left ones;
- unique over whole rows and keep="none" over a subset with nulls (nulls are
  equal);
- an aggregate beside row-wise values in select, with_columns and filter (a
  broadcast), aggregates over() a partition with a null key, an expression
  over() a partition, rank with every supported method over ties, descending
  and per partition, cum_sum, cum_count, cum_min, cum_max (also reversed and
  over a partition with order_by) on a sorted frame, rolling_sum,
  rolling_mean, rolling_min and rolling_max with and without min_samples, and
  the types of cum_sum over int32, float32 and bool.

And the edges the oracle does not cover: unique(subset, keep="any") keeps one
row of each value, any of them; and collect() of a frame of all of these calls
the plan entry and never the SQL one, whose explain() holds no SQL text.

    test_pl_oracle_frames.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import argparse
import os
import sys
import tempfile

import polars as pl
import pyarrow as pa
import pyarrow.parquet as pq
from polars.testing import assert_frame_equal

import komira.pl as kpl
from komira import Session
from komira import _native

assert pl.__version__ == "1.44.2", pl.__version__


# ---- the files -----------------------------------------------------------------

LEFT = {
    "id": (pa.int64(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]),
    "g": (pa.string(), ["a", "b", "a", None, "c", "b", "a", "c", None, "b"]),
    "t": (pa.int64(), [3, 1, 3, None, 2, 1, 3, 2, None, 5]),
    "x": (pa.int64(), [5, -3, None, 7, 0, -8, 2, None, 9, 4]),
    "y": (pa.float64(), [1.5, None, -2.25, 4.0, 0.5, None, 3.75, -1.0, 2.0, 0.0]),
    "flag": (pa.bool_(), [True, False, None, True, True, False, None, False, True, True]),
    "i32": (pa.int32(), [1, 2, None, -4, 5, 6, 7, None, 9, 10]),
    "f32": (pa.float32(), [0.5, 1.5, None, -2.0, 4.0, None, 0.25, 8.0, 1.0, -0.5]),
    "u16": (pa.uint16(), [1, 2, 3, None, 65535, 6, 7, 8, None, 10]),
}

RIGHT = {
    "rid": (pa.int64(), [0, 2, 2, 4, 11, 6]),
    "g": (pa.string(), ["a", "b", "d", None, "a", "c"]),
    "w": (pa.float64(), [10.0, 20.0, None, 40.0, 50.0, 60.0]),
    "x": (pa.int64(), [1, -3, 3, 4, 5, None]),
}


def table(columns, rows=True):
    return pa.table({name: pa.array(values if rows else [], type=t) for name, (t, values) in columns.items()})


# ---- the comparison ------------------------------------------------------------

# The engine may answer a string column as any of Arrow's three string
# layouts; each is the same polars String.
_STRING_LAYOUTS = (pa.string(), pa.large_string(), pa.string_view())


def _same_type(derived, answered):
    if derived in _STRING_LAYOUTS:
        return answered in _STRING_LAYOUTS
    return derived == answered


def check(name, lf_k, lf_p, ordered):
    """The komira.pl frame's answer equals polars', and its schema the
    answer's; polars' UInt32 columns compared as Int64."""
    want = lf_p.collect()
    arrow = lf_k.collect().to_arrow()
    derived = lf_k.schema
    assert list(derived) == arrow.schema.names, (name, list(derived), arrow.schema.names)
    for field in arrow.schema:
        assert _same_type(derived[field.name], field.type), (name, field.name, derived[field.name], field.type)
    got = pl.from_arrow(arrow)
    want = want.with_columns(
        [
            pl.col(c).cast(pl.Int64)
            for c, t in want.schema.items()
            if t == pl.UInt32 and c in got.columns and got.schema[c] == pl.Int64
        ]
    )
    try:
        assert_frame_equal(got, want, check_row_order=ordered)
    except AssertionError as e:
        raise AssertionError(f"{name}: komira.pl\n{got}\npolars\n{want}\n{e}") from None


# Each case: (name, program, ordered). `program(P, lf, rf)` builds a frame
# with the module P (komira.pl or polars) over the frames lf and rf of the
# left and right files.
GROUP_BY = [
    (
        "group_by_aggregates",
        lambda P, lf, rf: lf.group_by("g").agg(
            P.col("x").sum(),
            P.col("x").mean().alias("xm"),
            P.col("x").min().alias("xmin"),
            P.col("x").max().alias("xmax"),
            P.col("x").count().alias("xc"),
            P.len(),
            P.col("t").n_unique().alias("tu"),
        ),
        False,
    ),
    (
        "group_by_float_aggregates",
        lambda P, lf, rf: lf.group_by("g").agg(
            P.col("y").sum(),
            P.col("y").mean().alias("ym"),
            P.col("y").min().alias("ymin"),
            P.col("y").max().alias("ymax"),
            (P.col("y") * 2.0).sum().alias("twice"),
        ),
        False,
    ),
    ("group_by_two_keys", lambda P, lf, rf: lf.group_by("g", "flag").agg(P.col("x").sum(), P.len()), False),
    ("group_by_col_key", lambda P, lf, rf: lf.group_by(P.col("t")).agg(P.col("x").max()), False),
    ("group_by_len", lambda P, lf, rf: lf.group_by("g").len(), False),
    ("group_by_len_named", lambda P, lf, rf: lf.group_by("g").len(name="rows"), False),
    (
        "group_by_expressions_over_aggregates",
        lambda P, lf, rf: lf.group_by("g").agg(
            (P.col("x").sum() / P.col("x").count()).alias("avg"),
            (P.col("x").max() - P.col("x").min()).alias("range"),
            (P.col("x") * 2).sum().alias("twice"),
        ),
        False,
    ),
    (
        "group_by_sum_types",
        lambda P, lf, rf: lf.group_by("g").agg(
            P.col("i32").sum(),
            P.col("u16").sum(),
            P.col("flag").sum(),
            P.col("i32").min().alias("i32_min"),
            P.col("i32").mean().alias("i32_mean"),
            P.col("i32").max().alias("i32_max"),
        ),
        False,
    ),
    ("group_by_sum_of_columns", lambda P, lf, rf: lf.select("g", "x", "t", "i32").group_by("g").sum(), False),
    ("group_by_mean_of_columns", lambda P, lf, rf: lf.select("g", "x", "t").group_by("g").mean(), False),
    ("group_by_min_of_columns", lambda P, lf, rf: lf.select("g", "x", "t").group_by("g").min(), False),
    ("group_by_max_of_columns", lambda P, lf, rf: lf.select("g", "x", "t").group_by("g").max(), False),
    ("group_by_n_unique_of_columns", lambda P, lf, rf: lf.select("g", "t", "x").group_by("g").n_unique(), False),
    (
        "group_by_after_filter_and_sort",
        lambda P, lf, rf: lf.filter(P.col("x") > -5).sort("id").group_by("g").agg(P.col("id").max()),
        False,
    ),
]

JOINS = [
    ("join_inner_on", lambda P, lf, rf: lf.select("id", "g", "x").join(rf, on="g"), False),
    ("join_left_on", lambda P, lf, rf: lf.select("id", "g", "x").join(rf, on="g", how="left"), False),
    ("join_full_on", lambda P, lf, rf: lf.select("id", "g", "x").join(rf, on="g", how="full"), False),
    (
        "join_full_coalesce",
        lambda P, lf, rf: lf.select("id", "g", "x").join(rf, on="g", how="full", coalesce=True),
        False,
    ),
    (
        "join_right_on",
        lambda P, lf, rf: lf.select("id", "g", "x").join(rf.select("rid", "g", "w"), on="g", how="right"),
        False,
    ),
    ("join_semi", lambda P, lf, rf: lf.join(rf, on="g", how="semi"), False),
    ("join_anti", lambda P, lf, rf: lf.join(rf, on="g", how="anti"), False),
    ("join_cross", lambda P, lf, rf: lf.select("id", "x").join(rf.select("rid", "x"), how="cross"), False),
    ("join_two_keys", lambda P, lf, rf: lf.select("id", "g", "x").join(rf, on=["g", "x"]), False),
    (
        "join_left_on_right_on",
        lambda P, lf, rf: lf.select("id", "g", "x").join(rf, left_on="id", right_on="rid"),
        False,
    ),
    (
        "join_left_on_right_on_left",
        lambda P, lf, rf: lf.select("id", "g").join(rf, left_on="id", right_on="rid", how="left"),
        False,
    ),
    (
        "join_left_on_right_on_full",
        lambda P, lf, rf: lf.select("id", "g").join(rf, left_on="id", right_on="rid", how="full"),
        False,
    ),
    (
        "join_inner_no_coalesce",
        lambda P, lf, rf: lf.select("id", "g").join(rf, on="g", coalesce=False),
        False,
    ),
    ("join_suffix", lambda P, lf, rf: lf.select("id", "g", "x").join(rf, on="g", suffix="_r"), False),
    (
        "join_then_group_by",
        lambda P, lf, rf: lf.join(rf, on="g").group_by("g").agg(P.col("rid").sum(), P.col("rid").max().alias("rid_max"), P.len()),
        False,
    ),
]

UNIQUE = [
    ("unique_rows", lambda P, lf, rf: lf.select("g", "flag").unique(), False),
    ("unique_rows_of_one_column", lambda P, lf, rf: lf.select("g").unique(), False),
    ("unique_subset_every_column", lambda P, lf, rf: lf.select("g", "t").unique(subset=["t", "g"]), False),
    ("unique_keep_none_subset", lambda P, lf, rf: lf.unique(subset="x", keep="none"), False),
    ("unique_keep_none_subset_ties", lambda P, lf, rf: lf.unique(subset=["g"], keep="none"), False),
    ("unique_keep_none_rows", lambda P, lf, rf: lf.select("g", "flag").unique(keep="none"), False),
]

WINDOWS = [
    (
        "broadcast_in_with_columns",
        lambda P, lf, rf: lf.select("id", "x", "y").with_columns(
            P.col("x").sum().alias("total"),
            P.col("y").mean().alias("ym"),
            P.col("x").max().alias("xmax"),
            P.len().alias("n"),
        ),
        False,
    ),
    (
        "broadcast_in_select",
        lambda P, lf, rf: lf.select("id", P.col("x").min().alias("xmin"), (P.col("x") - P.col("x").mean()).alias("dev")),
        False,
    ),
    ("broadcast_in_filter", lambda P, lf, rf: lf.filter(P.col("x") > P.col("x").mean()), False),
    (
        "over_partition",
        lambda P, lf, rf: lf.select("id", "g", "x", "flag").with_columns(
            P.col("x").sum().over("g").alias("gs"),
            P.col("x").mean().over("g").alias("gm"),
            P.col("x").min().over("g").alias("gmin"),
            P.col("x").count().over("g").alias("gc"),
            P.len().over("g").alias("gn"),
            P.col("x").max().over("g", "flag").alias("gfmax"),
        ),
        False,
    ),
    (
        "over_an_expression",
        lambda P, lf, rf: lf.select("id", (P.col("x") - P.col("x").mean()).over("g").alias("dev")),
        False,
    ),
    (
        "over_filter",
        lambda P, lf, rf: lf.filter(P.col("x") == P.col("x").max().over("g")),
        False,
    ),
    (
        "over_types",
        lambda P, lf, rf: lf.select(
            "id",
            P.col("i32").sum().over("g").alias("i32_sum"),
            P.col("f32").sum().over("g").alias("f32_sum"),
            P.col("u16").sum().over("g").alias("u16_sum"),
            P.col("flag").sum().over("g").alias("trues"),
            P.col("i32").max().over("g").alias("i32_max"),
            P.col("f32").mean().over("g").alias("f32_mean"),
        ),
        False,
    ),
    (
        "rank_methods_over_ties",
        lambda P, lf, rf: lf.select(
            "id",
            P.col("t").rank().alias("average"),
            P.col("t").rank("min").alias("min"),
            P.col("t").rank("max").alias("max"),
            P.col("t").rank("dense").alias("dense"),
            P.col("t").rank("min", descending=True).alias("min_down"),
            P.col("t").rank("average", descending=True).alias("average_down"),
        ),
        False,
    ),
    (
        "rank_over_partition",
        lambda P, lf, rf: lf.select(
            "id",
            P.col("t").rank("min").over("g").alias("min"),
            P.col("x").rank("dense", descending=True).over("g").alias("dense"),
            P.col("t").rank().over("flag").alias("average"),
        ),
        False,
    ),
    ("rank_of_int32", lambda P, lf, rf: lf.select("id", P.col("i32").rank("max")), False),
    (
        "cumulative_on_a_sorted_frame",
        lambda P, lf, rf: lf.sort("id").select(
            "id",
            P.col("x").cum_sum().alias("cs"),
            P.col("x").cum_count().alias("cc"),
            P.col("x").cum_min().alias("cmin"),
            P.col("x").cum_max().alias("cmax"),
            P.col("y").cum_sum().alias("ycs"),
            P.col("x").cum_sum(reverse=True).alias("rcs"),
        ),
        True,
    ),
    (
        "cumulative_types",
        lambda P, lf, rf: lf.sort("id").select(
            "id",
            P.col("i32").cum_sum(),
            P.col("f32").cum_sum(),
            P.col("flag").cum_sum(),
            P.col("i32").cum_max().alias("i32_max"),
        ),
        True,
    ),
    (
        "cumulative_over_partition_order_by",
        lambda P, lf, rf: lf.select(
            "id",
            "g",
            P.col("x").cum_sum().over("g", order_by="id").alias("gcs"),
            P.col("x").cum_max().over("g", order_by="id", descending=True).alias("gcmax"),
        ),
        False,
    ),
    (
        "rolling_on_a_sorted_frame",
        lambda P, lf, rf: lf.sort("id").select(
            "id",
            P.col("x").rolling_sum(3).alias("rs"),
            P.col("x").rolling_mean(2).alias("rm"),
            P.col("y").rolling_min(3, min_samples=1).alias("rmin"),
            P.col("y").rolling_max(2, min_samples=2).alias("rmax"),
            P.col("x").rolling_sum(1).alias("rs1"),
            P.col("x").rolling_sum(4, min_samples=2).alias("rs4"),
        ),
        True,
    ),
    (
        "rolling_over_partition_order_by",
        lambda P, lf, rf: lf.select(
            "id",
            P.col("x").rolling_sum(2, min_samples=1).over("g", order_by="id").alias("grs"),
            P.col("y").rolling_mean(2, min_samples=1).over("g", order_by="id").alias("grm"),
        ),
        False,
    ),
    (
        "window_keeps_the_frame_order",
        lambda P, lf, rf: lf.sort("id", descending=True).with_columns(
            P.col("x").sum().over("g").alias("gs"), P.col("t").rank("dense").alias("r")
        ),
        True,
    ),
]

EMPTY = [
    ("empty_group_by", lambda P, lf, rf: lf.group_by("g").agg(P.col("x").sum(), P.len()), False),
    ("empty_join", lambda P, lf, rf: lf.select("id", "g").join(rf, on="g"), False),
    ("empty_window", lambda P, lf, rf: lf.select("id", P.col("x").sum().over("g").alias("gs")), False),
]


def run_cases(session, left, right, cases):
    for name, program, ordered in cases:
        lf_k = program(kpl, kpl.scan_parquet(left, session=session), kpl.scan_parquet(right, session=session))
        lf_p = program(pl, pl.scan_parquet(left), pl.scan_parquet(right))
        assert (lf_k._order is not None) == ordered, (name, lf_k._order)
        check(name, lf_k, lf_p, ordered)
    print("pl_oracle_frames: {} programs equal polars' answers".format(len(cases)))


# ---- the edges ---------------------------------------------------------------


def test_unique_keep_any_keeps_one_row_of_each_value(session, left):
    """polars' keep="any" promises no particular row of a value, so the
    answer is checked for what it promises: one row of each value of the
    subset, null included, and each a row of the frame."""
    got = kpl.scan_parquet(left, session=session).unique(subset="g").collect().to_arrow().to_pylist()
    rows = table(LEFT).to_pylist()
    assert sorted((r["g"] is None, r["g"] or "") for r in got) == [
        (False, "a"),
        (False, "b"),
        (False, "c"),
        (True, ""),
    ], got
    for row in got:
        assert row in rows, row


class Spy:
    """The library's calls, recording the name of each one made."""

    def __init__(self, native):
        self.native = native
        self.calls = []

    def __getattr__(self, name):
        self.calls.append(name)
        return getattr(self.native, name)


def test_collect_calls_the_plan_entry_and_never_sql(left, right):
    s = Session()
    spy = Spy(s._native)
    s._native = spy
    lf = kpl.scan_parquet(left, session=s)
    rf = kpl.scan_parquet(right, session=s)
    frame = (
        lf.select("id", "g", "t", "x")
        .join(rf.select("g", "w"), on="g")
        .with_columns(kpl.col("x").sum().over("g").alias("gs"), kpl.col("t").rank("dense").alias("r"))
        .unique()
        .group_by("g")
        .agg(kpl.col("gs").max(), kpl.len())
    )
    text = frame.explain()
    for word in ("SELECT", "FROM", "GROUP BY", "JOIN", "OVER", "PARTITION BY"):
        assert word not in text, (word, text)
    got = frame.collect().to_arrow()
    assert sorted(got["g"].to_pylist()) == ["a", "b", "c"], got
    assert "sql_stream" not in spy.calls, spy.calls
    assert spy.calls == ["parquet_schema", "parquet_schema", "plan_render", "plan_stream"], spy.calls
    s.close()


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib-dir", required=True)
    parser.add_argument("--runtime-dir", required=True)
    args = parser.parse_args(argv)
    _native.load(os.path.join(args.lib_dir, "libkomira"))
    with tempfile.TemporaryDirectory() as work:
        left = os.path.join(work, "left.parquet")
        right = os.path.join(work, "right.parquet")
        empty = os.path.join(work, "empty.parquet")
        pq.write_table(table(LEFT), left)
        pq.write_table(table(RIGHT), right)
        pq.write_table(table(LEFT, rows=False), empty)
        with Session() as session:
            run_cases(session, left, right, GROUP_BY + JOINS + UNIQUE + WINDOWS)
            run_cases(session, empty, right, EMPTY)
            test_unique_keep_any_keeps_one_row_of_each_value(session, left)
            test_collect_calls_the_plan_entry_and_never_sql(left, right)
    print("pl_oracle_frames: the edge cases passed")


if __name__ == "__main__":
    main(sys.argv[1:])
