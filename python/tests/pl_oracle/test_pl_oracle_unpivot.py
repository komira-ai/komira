"""komira.pl's `LazyFrame.unpivot` against polars itself, on the real libkomira.

As test_pl_oracle_frames.py: each case is one program written once for both
modules, run through komira.pl, whose frame is encoded as a plan (a union of
one projection per unpivoted column) and run by `komira_plan_stream`, and
through the pinned polars; the answer must be the same frame, values and
dtypes (`polars.testing.assert_frame_equal`, rows as a multiset, since polars
leaves the row order of an unpivot unspecified and komira's frame is
unordered), and the schema komira.pl derives without running must be the
answer's.

The file has a string id with a null, int64 columns with nulls, a column that
never holds a null written as not nullable, int32 and float64 columns with
nulls, two string columns with nulls and two written as not nullable. The
programs cover: `on` and `index` with custom names; the default names; `on`
None (every column not in `index`); no `index`; one column; two index
columns; string values; float values with nulls; a not-nullable int64 column
beside nullable ones; two not-nullable string columns; unpivot of a filtered and of
a sorted frame; a sort of the unpivot (its answer in order); an unpivot of the
empty file.

    test_pl_oracle_unpivot.py --lib-dir <dir> --runtime-dir <dir>

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


# ---- the file ------------------------------------------------------------------

# name: (type, allows nulls, values)
WIDE = {
    "name": (pa.string(), True, ["Ana", "Bo", "Cy", None, "Di", "Ed"]),
    "k": (pa.int64(), True, [1, 1, 2, 2, None, 3]),
    "q1": (pa.int64(), True, [10, 5, 1, None, 7, -3]),
    "q2": (pa.int64(), True, [20, None, 2, None, 8, 0]),
    "q3": (pa.int64(), False, [30, 7, 3, 4, 9, 11]),
    "i1": (pa.int32(), True, [1, None, 3, 4, 5, 6]),
    "i2": (pa.int32(), True, [None, 2, 3, None, 5, 6]),
    "f1": (pa.float64(), True, [1.5, None, -2.25, 4.0, 0.5, 0.0]),
    "f2": (pa.float64(), True, [None, 2.5, 3.75, None, -1.0, 8.0]),
    "s1": (pa.string(), True, ["a", None, "", "dd", "e", "ff"]),
    "s2": (pa.string(), True, [None, "B", "cc", "D", None, "é"]),
    "s3": (pa.string(), False, ["x", "", "yy", "z", "w", "v"]),
    "s4": (pa.string(), False, ["p", "q", "", "r", "s", "t"]),
}


def table(rows=True):
    schema = pa.schema([pa.field(n, t, nullable=null) for n, (t, null, _) in WIDE.items()])
    return pa.table({n: pa.array(v if rows else [], type=t) for n, (t, _, v) in WIDE.items()}, schema=schema)


# ---- the comparison ------------------------------------------------------------

# The engine may answer a string column as any of Arrow's three string
# layouts; each is the same polars String.
_STRING_LAYOUTS = (pa.string(), pa.large_string(), pa.string_view())


def _same_type(derived, answered):
    if derived in _STRING_LAYOUTS:
        return answered in _STRING_LAYOUTS
    return derived == answered


def check(name, lf_k, lf_p, ordered):
    """The komira.pl frame's answer equals polars', and its schema the answer's."""
    want = lf_p.collect()
    arrow = lf_k.collect().to_arrow()
    derived = lf_k.schema
    assert list(derived) == arrow.schema.names, (name, list(derived), arrow.schema.names)
    for field in arrow.schema:
        assert _same_type(derived[field.name], field.type), (name, field.name, derived[field.name], field.type)
    got = pl.from_arrow(arrow)
    try:
        assert_frame_equal(got, want, check_row_order=ordered)
    except AssertionError as e:
        raise AssertionError(f"{name}: komira.pl\n{got}\npolars\n{want}\n{e}") from None


# Each case: (name, program, ordered). `program(P, lf)` builds a frame with
# the module P (komira.pl or polars) over the frame lf of the file.
CASES = [
    (
        "unpivot_on_and_index_with_names",
        lambda P, lf: lf.unpivot(["q1", "q2"], index="name", variable_name="quarter", value_name="score"),
        False,
    ),
    ("unpivot_default_names", lambda P, lf: lf.unpivot(["q1", "q2", "q3"], index=["name"]), False),
    ("unpivot_on_none_is_every_other_column", lambda P, lf: lf.select("name", "q1", "q2").unpivot(index="name"), False),
    ("unpivot_with_no_index", lambda P, lf: lf.unpivot(["q1", "q2"]), False),
    ("unpivot_with_neither", lambda P, lf: lf.select("q1", "q2").unpivot(), False),
    ("unpivot_one_column", lambda P, lf: lf.unpivot("q2", index="name"), False),
    ("unpivot_two_index_columns", lambda P, lf: lf.unpivot(["q1", "q2"], index=["k", "name"]), False),
    ("unpivot_on_in_another_order", lambda P, lf: lf.unpivot(["q2", "q1"], index="name"), False),
    ("unpivot_int32_values", lambda P, lf: lf.unpivot(["i1", "i2"], index="name"), False),
    ("unpivot_float_values_with_nulls", lambda P, lf: lf.unpivot(["f1", "f2"], index="k"), False),
    ("unpivot_string_values", lambda P, lf: lf.unpivot(["s1", "s2"], index="name", value_name="text"), False),
    ("unpivot_a_column_that_never_holds_a_null", lambda P, lf: lf.unpivot(["q1", "q3", "q2"], index="name"), False),
    ("unpivot_string_columns_that_never_hold_a_null", lambda P, lf: lf.unpivot(["s3", "s4"], index="k"), False),
    ("unpivot_of_a_filtered_frame", lambda P, lf: lf.filter(P.col("k") > 1).unpivot(["q1", "q2"], index="name"), False),
    ("unpivot_of_a_sorted_frame", lambda P, lf: lf.sort("q1").unpivot(["q1", "q2"], index="name"), False),
    (
        "sort_of_an_unpivot",
        lambda P, lf: lf.unpivot(["q1", "q2"], index="name").sort("name", "variable", nulls_last=True),
        True,
    ),
    (
        "unpivot_then_filter_and_group_by",
        lambda P, lf: lf.unpivot(["q1", "q2", "q3"], index="name")
        .filter(P.col("value").is_not_null())
        .group_by("variable")
        .agg(P.col("value").sum()),
        False,
    ),
]

EMPTY = [("unpivot_of_the_empty_file", lambda P, lf: lf.unpivot(["q1", "q2"], index="name"), False)]


def run_cases(session, path, cases):
    for name, program, ordered in cases:
        lf_k = program(kpl, kpl.scan_parquet(path, session=session))
        lf_p = program(pl, pl.scan_parquet(path))
        assert (lf_k._order is not None) == ordered, (name, lf_k._order)
        check(name, lf_k, lf_p, ordered)
    print("pl_oracle_unpivot: {} programs equal polars' answers".format(len(cases)))


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib-dir", required=True)
    parser.add_argument("--runtime-dir", required=True)
    args = parser.parse_args(argv)
    _native.load(os.path.join(args.lib_dir, "libkomira"))
    with tempfile.TemporaryDirectory() as work:
        wide = os.path.join(work, "wide.parquet")
        empty = os.path.join(work, "empty.parquet")
        pq.write_table(table(), wide)
        pq.write_table(table(rows=False), empty)
        with Session() as session:
            run_cases(session, wide, CASES)
            run_cases(session, empty, EMPTY)


if __name__ == "__main__":
    main(sys.argv[1:])
