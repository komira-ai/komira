"""komira.pl against polars itself, on the real libkomira.

Each case is one program written once for both modules: run through
komira.pl, whose frame is encoded as a plan and run by `komira_plan_stream`,
and through the pinned polars, its answer must be the same frame, values and
dtypes (`polars.testing.assert_frame_equal`; floats to its default relative
tolerance, rows in order when the frame is ordered and as a multiset when it
is not). The schema komira.pl derives without running (`LazyFrame.schema`)
must also be the schema of the answer the engine gives.

The programs cover every verb and expression of komira.pl over a Parquet
file pyarrow writes here, with nulls in every column but the key, negative
values, a NaN-free float column, a boolean, strings and narrow types, and over
an empty file of the same columns:

- the readers: a whole Parquet file, an NDJSON file, and the default session;
- select of columns and of expressions, with polars' output names (the
  leftmost column, `literal` for a literal on the left);
- arithmetic with true division, and floor division and modulo with negative
  operands, by a negative divisor and by zero;
- comparisons, `&`, `|`, `~`, a boolean column as a filter, is_null,
  is_not_null, fill_null, is_in, is_between with each `closed`, when/then/
  otherwise with several branches and a null condition, cast, abs, negation;
- the string functions;
- sort by several keys, each direction and null placement, then head, slice,
  tail, filter, select, with_columns and rename that keep the order; head on
  an unordered frame (some n rows of the frame); top_k and bottom_k over a
  column with nulls;
- drop, drop_nulls with and without a subset, with_columns that replaces a
  column and appends one;
- every aggregate, the types polars gives a sum, mean and count over int32,
  float32, uint16 and bool, expressions over aggregates, and the aggregates
  of the empty file (a sum of nothing is 0);
- int literals beside an int32 column and alone (Int32, as in polars), and
  fill_null and when/then over int32, int64, float64 and string columns;
- concat of two frames of the file.

And the edges the oracle does not cover: collect() twice runs the plan
twice; collect() calls the plan entry and never the SQL entry; explain()
renders the plan; a missing file is refused at the reader with the engine's
message; frames of two sessions are refused by concat; a CSV scan, which the
engine does not lower yet, is refused at the terminal with the engine's step;
and median, std, var and the min of a string column, which the engine's
aggregation sinks do not serve yet, are refused at the terminal at execute.

    test_pl_oracle.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import argparse
import json
import os
import sys
import tempfile

import polars as pl
import pyarrow as pa
import pyarrow.parquet as pq
from polars.testing import assert_frame_equal

import komira
import komira.pl as kpl
from komira import KomiraError, Session, UnsupportedOperation
from komira import _native

assert pl.__version__ == "1.44.2", pl.__version__


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


# ---- the files -----------------------------------------------------------------

COLUMNS = {
    "id": (pa.int64(), [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]),
    "g": (pa.string(), ["a", "b", "a", None, "c", "b", "a", "c", None, "b"]),
    "x": (pa.int64(), [5, -3, None, 7, 0, -8, 2, None, 9, 4]),
    "y": (pa.float64(), [1.5, None, -2.25, 4.0, 0.5, None, 3.75, -1.0, 2.0, 0.0]),
    "flag": (pa.bool_(), [True, False, None, True, True, False, None, False, True, True]),
    "s": (pa.string(), ["Apple", "banana", "Cherry", None, "date", "Elder", "fig", "grape", None, "apple pie"]),
    "i32": (pa.int32(), [1, 2, None, -4, 5, 6, 7, None, 9, 10]),
    "f32": (pa.float32(), [0.5, 1.5, None, -2.0, 4.0, None, 0.25, 8.0, 1.0, -0.5]),
    "u16": (pa.uint16(), [1, 2, 3, None, 65535, 6, 7, 8, None, 10]),
}


def table(rows=True):
    return pa.table(
        {name: pa.array(values if rows else [], type=t) for name, (t, values) in COLUMNS.items()}
    )


# ---- the comparison ------------------------------------------------------------


# The engine may answer a string column as any of Arrow's three string
# layouts; each is the same polars String.
_STRING_LAYOUTS = (pa.string(), pa.large_string(), pa.string_view())


def _same_type(derived, answered):
    if derived in _STRING_LAYOUTS:
        return answered in _STRING_LAYOUTS
    return derived == answered


def check(name, lf_k, lf_p, ordered):
    """The komira.pl frame's answer equals polars', and its schema the answer's.

    The one departure applied: where polars answers UInt32 (a count, len(),
    str.len_chars(), the sum of a boolean or of a UInt32), komira.pl answers
    Int64, so polars' column is compared as Int64."""
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


# Each case: (name, program, ordered). `program(P, lf)` builds a frame with
# the module P (komira.pl or polars) over the frame lf of the file.
CASES = [
    ("scan", lambda P, lf: lf, False),
    ("select_names", lambda P, lf: lf.select("id", "g", P.col("x")), False),
    (
        "select_exprs_named_by_leftmost_column",
        lambda P, lf: lf.select(
            P.col("id"),
            P.col("x") + 1,
            (P.col("y") * P.col("x")).alias("yx"),
            (P.col("id") - 100).alias("d"),
        ),
        False,
    ),
    ("literal_on_the_left_is_named_literal", lambda P, lf: lf.select(P.col("id"), 10 - P.col("x")), False),
    ("named_keyword_outputs", lambda P, lf: lf.select("id", twice=P.col("x") * 2), False),
    (
        "true_division",
        lambda P, lf: lf.filter(P.col("y") != 0).select(
            "id",
            (P.col("x") / 2).alias("half"),
            (P.col("x") / P.col("y")).alias("ratio"),
            (P.col("i32") / P.col("x")).alias("narrow"),
        ),
        False,
    ),
    (
        "floor_division_and_modulo",
        lambda P, lf: lf.select(
            "id",
            (P.col("x") // 3).alias("fd"),
            (P.col("x") % 3).alias("md"),
            (P.col("x") // -3).alias("fdn"),
            (P.col("x") % -3).alias("mdn"),
            (-7 // P.col("i32")).alias("rfd"),
            (-7 % P.col("i32")).alias("rmd"),
        ),
        False,
    ),
    (
        "integer_division_by_zero_is_null",
        lambda P, lf: lf.select("id", (P.col("x") // 0).alias("fd"), (P.col("x") % 0).alias("md")),
        False,
    ),
    (
        "float_floor_division_and_modulo",
        lambda P, lf: lf.select("id", (P.col("y") // 2).alias("fd"), (P.col("y") % -2).alias("md")),
        False,
    ),
    ("filter_and", lambda P, lf: lf.filter((P.col("x") > 0) & (P.col("y") < 3)), False),
    ("filter_or_not", lambda P, lf: lf.filter((P.col("x") >= 5) | ~(P.col("g") == "a")), False),
    ("filter_several_predicates", lambda P, lf: lf.filter(P.col("x") != 0, P.col("y") <= 2.0), False),
    ("filter_boolean_column", lambda P, lf: lf.filter(P.col("flag")), False),
    ("filter_boolean_column_and", lambda P, lf: lf.filter(P.col("flag") & (P.col("id") > 2)), False),
    (
        "missing_values",
        lambda P, lf: lf.select(
            "id",
            P.col("x").is_null().alias("xn"),
            P.col("g").is_not_null().alias("gn"),
            P.col("x").fill_null(0).alias("xf"),
            P.col("y").fill_null(-1.0).alias("yf"),
            P.col("s").fill_null("none").alias("sf"),
            P.col("x").fill_null(P.col("id")).alias("xi"),
        ),
        False,
    ),
    ("is_in_filter", lambda P, lf: lf.filter(P.col("g").is_in(["a", "c"])), False),
    (
        "is_in_and_is_between",
        lambda P, lf: lf.select(
            "id",
            P.col("x").is_in([5, -8, 100]).alias("inx"),
            P.col("x").is_between(0, 5).alias("both"),
            P.col("x").is_between(0, 5, closed="left").alias("left"),
            P.col("x").is_between(0, 5, closed="right").alias("right"),
            P.col("x").is_between(0, 5, closed="none").alias("none"),
        ),
        False,
    ),
    (
        "when_then_otherwise",
        lambda P, lf: lf.select(
            "id",
            P.when(P.col("x") > 0)
            .then(P.lit("pos"))
            .when(P.col("x") < 0)
            .then(P.lit("neg"))
            .otherwise(P.lit("zero or null"))
            .alias("sign"),
            P.when(P.col("flag")).then(P.col("y")).otherwise(0.0),
        ),
        False,
    ),
    (
        "int32_columns_and_literals",
        lambda P, lf: lf.select(
            "id",
            (P.col("i32") + 1).alias("plus"),
            (2 * P.col("i32")).alias("twice"),
            P.col("i32").fill_null(0).alias("filled"),
            P.when(P.col("i32") > 3).then(P.col("i32")).otherwise(-1).alias("capped"),
            P.col("f32").fill_null(0.5).alias("f32_filled"),
            (P.col("f32") * 2).alias("f32_twice"),
        ),
        False,
    ),
    (
        "casts",
        lambda P, lf: lf.select(
            "id",
            P.col("y").cast(P.Int64 if P is pl else "int64", strict=False).alias("y_int"),
            P.col("x").cast(P.Float32 if P is pl else "float32").alias("x_f32"),
            P.col("u16").cast(P.Int32 if P is pl else "int32").alias("u16_i32"),
            P.col("x").cast(P.String if P is pl else "string").alias("x_str"),
        ),
        False,
    ),
    ("abs_and_negation", lambda P, lf: lf.select("id", P.col("x").abs().alias("a"), (-P.col("x")).alias("n")), False),
    (
        "strings",
        lambda P, lf: lf.select(
            "id",
            P.col("s").str.to_lowercase().alias("lo"),
            P.col("s").str.to_uppercase().alias("up"),
            P.col("s").str.len_chars().alias("n"),
            P.col("s").str.starts_with("a").alias("sw"),
            P.col("s").str.ends_with("e").alias("ew"),
            P.col("s").str.contains("an", literal=True).alias("has"),
        ),
        False,
    ),
    ("string_filter", lambda P, lf: lf.filter(P.col("s").str.contains("p", literal=True)), False),
    ("sort_one_key_nulls_first", lambda P, lf: lf.sort("y", "id"), True),
    ("sort_keys_and_directions", lambda P, lf: lf.sort(["g", "id"], descending=[True, False]), True),
    ("sort_nulls_last", lambda P, lf: lf.sort("x", "id", nulls_last=True), True),
    (
        "sort_descending_nulls_last",
        lambda P, lf: lf.sort("y", "id", descending=[True, False], nulls_last=True),
        True,
    ),
    ("sort_then_head", lambda P, lf: lf.sort("id", descending=True).head(3), True),
    ("sort_then_limit", lambda P, lf: lf.sort("x", "id").limit(4), True),
    ("sort_then_slice", lambda P, lf: lf.sort("id").slice(2, 3), True),
    ("sort_then_slice_from_0", lambda P, lf: lf.sort("id").slice(0, 2), True),
    ("sort_then_tail", lambda P, lf: lf.sort("id").tail(3), True),
    ("sort_head_then_tail", lambda P, lf: lf.sort("id").head(6).tail(2), True),
    ("sort_head_then_filter", lambda P, lf: lf.sort("id").head(6).filter(P.col("x") > 0), True),
    ("sort_then_filter", lambda P, lf: lf.sort("y", "id").filter(P.col("x").is_not_null()), True),
    ("sort_then_select", lambda P, lf: lf.sort("id", descending=True).select("id", "x"), True),
    (
        "sort_head_then_with_columns",
        lambda P, lf: lf.sort("id").head(5).with_columns((P.col("x") * 2).alias("x2")),
        True,
    ),
    ("sort_then_rename", lambda P, lf: lf.sort("id").rename({"id": "key", "x": "value"}), True),
    ("sort_head_then_rename", lambda P, lf: lf.sort("id").head(4).rename({"id": "key"}), True),
    ("sort_then_drop_key", lambda P, lf: lf.sort("id").drop("id"), False),
    ("top_k", lambda P, lf: lf.top_k(3, by="x"), False),
    ("top_k_reverse", lambda P, lf: lf.top_k(3, by="y", reverse=True), False),
    ("bottom_k", lambda P, lf: lf.bottom_k(4, by="y"), False),
    ("drop", lambda P, lf: lf.drop("s", "flag"), False),
    ("drop_nulls", lambda P, lf: lf.drop_nulls(), False),
    ("drop_nulls_subset", lambda P, lf: lf.drop_nulls("x"), False),
    ("drop_nulls_subset_list", lambda P, lf: lf.drop_nulls(["x", "y"]), False),
    ("rename_function", lambda P, lf: lf.rename(lambda c: c.upper()), False),
    (
        "with_columns_replaces_and_appends",
        lambda P, lf: lf.with_columns(P.col("x") + 1, (P.col("y") * 2).alias("y2"), z=P.lit(1)),
        False,
    ),
    (
        "aggregates",
        lambda P, lf: lf.select(
            P.col("x").sum(),
            P.col("y").mean().alias("mean"),
            P.col("x").min().alias("min"),
            P.col("x").max().alias("max"),
            P.col("x").count().alias("count"),
            P.len(),
            P.col("g").n_unique().alias("n_unique"),
            P.col("x").n_unique().alias("n_unique_x"),
            P.col("id").n_unique().alias("n_unique_no_nulls"),
        ),
        False,
    ),
    (
        "aggregate_types",
        lambda P, lf: lf.select(
            P.col("i32").sum(),
            P.col("f32").sum(),
            P.col("u16").sum(),
            P.col("flag").sum(),
            (P.col("x") > 0).sum().alias("positive"),
            P.col("f32").mean().alias("f32_mean"),
            P.col("i32").mean().alias("i32_mean"),
            P.col("i32").min().alias("i32_min"),
            P.col("f32").max().alias("f32_max"),
        ),
        False,
    ),
    (
        "expressions_over_aggregates",
        lambda P, lf: lf.select(
            (P.col("x").sum() * 2).alias("twice"),
            (P.col("x").max() - P.col("x").min()).alias("range"),
            (P.col("x").sum() / P.col("x").count()).alias("avg"),
            (P.col("x") * 2).sum().alias("sum_of_double"),
        ),
        False,
    ),
    ("aggregate_after_filter", lambda P, lf: lf.filter(P.col("x") > 100).select(P.col("x").sum(), P.len()), False),
    ("aggregate_after_sort", lambda P, lf: lf.sort("id").select(P.col("id").max()), False),
    ("concat", lambda P, lf: P.concat([lf.filter(P.col("x") > 0), lf.filter(P.col("x") <= 0)]), False),
]

EMPTY_CASES = [
    (
        "empty_aggregates",
        lambda P, lf: lf.select(
            P.col("x").sum(),
            P.col("y").sum().alias("ysum"),
            P.col("y").mean().alias("mean"),
            P.col("x").min().alias("min"),
            P.col("x").count().alias("count"),
            P.len(),
        ),
        False,
    ),
    ("empty_select", lambda P, lf: lf.filter(P.col("x") > 0).select("id", "g"), False),
    ("empty_sort_head", lambda P, lf: lf.sort("id").head(3), True),
]


def run_cases(session, path, cases):
    for name, program, ordered in cases:
        lf_k = program(kpl, kpl.scan_parquet(path, session=session))
        lf_p = program(pl, pl.scan_parquet(path))
        assert (lf_k._order is not None) == ordered, (name, lf_k._order)
        check(name, lf_k, lf_p, ordered)
    print("pl_oracle: {} programs equal polars' answers".format(len(cases)))


# ---- the edges ---------------------------------------------------------------


def test_head_of_an_unordered_frame_is_some_rows_of_it(session, path):
    got = kpl.scan_parquet(path, session=session).head(3).collect().to_arrow()
    assert got.num_rows == 3
    rows = table().to_pylist()
    for row in got.to_pylist():
        assert row in rows, row


def test_ndjson_scan(session, work):
    path = os.path.join(work, "events.ndjson")
    with open(path, "w", encoding="utf-8") as f:
        for i, (name, score) in enumerate([("a", 1.5), ("b", None), ("c", -2.0), (None, 4.25)]):
            f.write(json.dumps({"n": i, "name": name, "score": score}) + "\n")
    program = lambda P, lf: lf.filter(P.col("n") > 0).select("n", "name", (P.col("score") * 2).alias("twice"))
    check("ndjson", program(kpl, kpl.scan_ndjson(path, session=session)), program(pl, pl.scan_ndjson(path)), False)


def test_default_session(path):
    got = kpl.scan_parquet(path).select(kpl.len()).collect().to_arrow()
    assert got.to_pylist() == [{"len": 10}]
    assert kpl.scan_parquet(path)._session is kpl.scan_parquet(path)._session


def test_collect_twice_runs_twice(session, path):
    lf = kpl.scan_parquet(path, session=session).filter(kpl.col("x") > 0).select("id")
    first = lf.collect()
    second = lf.collect()
    assert first is not second
    assert sorted(first.to_arrow()["id"].to_pylist()) == [0, 3, 6, 8, 9]
    assert sorted(second.to_arrow()["id"].to_pylist()) == [0, 3, 6, 8, 9]


class Spy:
    """The library's calls, recording the name of each one made."""

    def __init__(self, native):
        self.native = native
        self.calls = []

    def __getattr__(self, name):
        self.calls.append(name)
        return getattr(self.native, name)


def test_collect_calls_the_plan_entry_and_never_sql(path):
    s = Session()
    spy = Spy(s._native)
    s._native = spy
    lf = kpl.scan_parquet(path, session=s).filter(kpl.col("x") > 0).sort("id").head(2)
    lf.explain()
    got = lf.collect().to_arrow()
    assert got["id"].to_pylist() == [0, 3]
    assert "sql_stream" not in spy.calls, spy.calls
    assert spy.calls == ["parquet_schema", "plan_render", "plan_stream"], spy.calls
    s.close()


def test_explain_renders_the_plan(session, path):
    text = kpl.scan_parquet(path, session=session).filter(kpl.col("x") > 0).select("id").explain()
    assert isinstance(text, str) and text, text
    assert "SELECT" not in text, text


def test_missing_file_is_refused_at_the_reader(session, work):
    missing = os.path.join(work, "missing.parquet")
    e = raised(lambda: kpl.scan_parquet(missing, session=session))
    assert isinstance(e, KomiraError), repr(e)
    assert missing in str(e), str(e)


def test_two_sessions_never_meet(session, path):
    other = Session()
    a = kpl.scan_parquet(path, session=session)
    b = kpl.scan_parquet(path, session=other)
    e = raised(lambda: kpl.concat([a, b]))
    assert type(e) is UnsupportedOperation, repr(e)
    assert str(e) == "concat: frame 1 runs on another session than frame 0; frames of two sessions never meet"
    other.close()


def test_statistics_the_engine_does_not_serve_are_refused_at_the_terminal(session, path):
    """median, std and var, and min of a string column, build the plan's own
    aggregates (the engine's to refuse, rules section 6); the engine's
    aggregation sinks serve none of them yet, so collect() raises its refusal
    at execute."""
    lf = kpl.scan_parquet(path, session=session)
    for expr in (kpl.col("y").median(), kpl.col("y").std(), kpl.col("y").var(), kpl.col("s").min()):
        frame = lf.select(expr)
        e = raised(frame.collect)
        assert isinstance(e, KomiraError), repr(e)
        assert e.step == "execute", (e.step, e.code, str(e))


def test_csv_scan_is_refused_at_the_terminal_by_the_engine(session, work):
    path = os.path.join(work, "people.csv")
    with open(path, "w", encoding="utf-8") as f:
        f.write("name,age\nann,31\nbob,\n")
    lf = kpl.scan_csv(path, session=session)
    assert lf.columns == ["name", "age"]
    e = raised(lf.collect)
    assert isinstance(e, KomiraError), repr(e)
    assert e.step == "lower", (e.step, e.code, str(e))


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib-dir", required=True)
    parser.add_argument("--runtime-dir", required=True)
    args = parser.parse_args(argv)
    lib_dir = os.path.join(args.lib_dir, "libkomira")
    _native.load(lib_dir)
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "t.parquet")
        empty = os.path.join(work, "empty.parquet")
        pq.write_table(table(), path)
        pq.write_table(table(rows=False), empty)
        with Session() as session:
            run_cases(session, path, CASES)
            run_cases(session, empty, EMPTY_CASES)
            test_head_of_an_unordered_frame_is_some_rows_of_it(session, path)
            test_ndjson_scan(session, work)
            test_default_session(path)
            test_collect_twice_runs_twice(session, path)
            test_collect_calls_the_plan_entry_and_never_sql(path)
            test_explain_renders_the_plan(session, path)
            test_missing_file_is_refused_at_the_reader(session, work)
            test_two_sessions_never_meet(session, path)
            test_statistics_the_engine_does_not_serve_are_refused_at_the_terminal(session, path)
            test_csv_scan_is_refused_at_the_terminal_by_the_engine(session, work)
    print("pl_oracle: the edge cases passed")


if __name__ == "__main__":
    main(sys.argv[1:])
