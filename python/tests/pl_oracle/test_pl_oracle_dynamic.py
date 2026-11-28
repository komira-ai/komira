"""komira.pl's `Expr.dt.truncate(every)` and `LazyFrame.group_by_dynamic`
against polars itself, on the real libkomira.

As test_pl_oracle_frames.py: each case is one program written once for both
modules, run through komira.pl, whose frame is encoded as a plan and run by
`komira_plan_stream`, and through the pinned polars; its answer must be the
same frame, values and dtypes (`polars.testing.assert_frame_equal`, rows as a
multiset, since komira's answer has no row order), and the schema komira.pl
derives without running must be the answer's. polars' UInt32 `len()` is
compared as Int64, komira.pl's type for it.

The file holds a Date `d` and a Datetime[us] `t`, both ascending in row order
(polars' group_by_dynamic needs its index sorted), at the edges of the
windows: a Sunday and the Monday after it, the last day of a month and the
first of the next, a week that spans a year end, the end of February in a
common and in a leap year, and for `t` the last microsecond of a Sunday and
of a month and the midnight after each; a key `g` and a value `x` with a null.
The programs cover:

- `dt.truncate("1d" | "1w" | "1mo")` of the Date and of the Datetime, as a
  new column and in place;
- `group_by_dynamic(index, every=...)` for each unit over each index, with
  sums, counts and `len()`, with a `group_by` key, and with polars' defaults
  named;
- a second file with null dates: komira.pl leaves the rows of a null index
  out of every window, which is polars' answer over the file with those rows
  dropped.

    test_pl_oracle_dynamic.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import argparse
import datetime
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

D = datetime.date
T = datetime.datetime

DATES = [
    D(2026, 10, 1),
    D(2026, 10, 4),  # a Sunday
    D(2026, 10, 5),  # the Monday after it
    D(2026, 10, 31),  # the last of a month
    D(2026, 11, 1),  # a Sunday, the first of a month
    D(2026, 11, 2),
    D(2026, 12, 31),
    D(2027, 1, 3),  # the Sunday ending the week that spans the year end
    D(2027, 1, 4),
    D(2027, 2, 28),  # the end of a common February
    D(2028, 2, 29),  # the end of a leap February
    D(2028, 3, 1),
]
STAMPS = [
    T(2026, 10, 1, 8, 0, 0),
    T(2026, 10, 4, 23, 59, 59, 999999),  # the last microsecond of a Sunday
    T(2026, 10, 5, 0, 0, 0),  # the midnight of the Monday after
    T(2026, 10, 31, 23, 59, 59, 999999),  # the last microsecond of a month
    T(2026, 11, 1, 0, 0, 0),  # the midnight that starts the next
    T(2026, 11, 2, 12, 30, 0),
    T(2026, 12, 31, 23, 0, 0),
    T(2027, 1, 3, 12, 0, 0),
    T(2027, 1, 4, 0, 0, 0, 1),
    T(2027, 2, 28, 23, 59, 59, 999999),
    T(2028, 2, 29, 6, 30, 0, 250000),
    T(2028, 3, 1, 0, 0, 0),
]
SORTED = {
    "id": (pa.int64(), list(range(len(DATES)))),
    "g": (pa.string(), ["a", "b", "a", "b", "a", "a", "b", "b", "a", "b", "a", "a"]),
    "x": (pa.int64(), [5, -3, None, 7, 0, -8, 2, 4, 9, 1, 6, -2]),
    "d": (pa.date32(), DATES),
    "t": (pa.timestamp("us"), STAMPS),
}
WITH_NULLS = {
    "x": (pa.int64(), [1, 2, 3, 4, 5, 6]),
    "d": (pa.date32(), [D(2026, 11, 1), None, D(2026, 11, 2), D(2026, 11, 9), None, D(2026, 12, 1)]),
}


def table(columns):
    return pa.table({name: pa.array(values, type=t) for name, (t, values) in columns.items()})


# ---- the comparison ------------------------------------------------------------

# The engine may answer a string column as any of Arrow's three string
# layouts; each is the same polars String.
_STRING_LAYOUTS = (pa.string(), pa.large_string(), pa.string_view())


def _same_type(derived, answered):
    if derived in _STRING_LAYOUTS:
        return answered in _STRING_LAYOUTS
    return derived == answered


def check(name, lf_k, lf_p):
    """The komira.pl frame's answer equals polars', as a multiset of rows,
    and its schema the answer's; polars' UInt32 columns compared as Int64."""
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
        assert_frame_equal(got, want, check_row_order=False)
    except AssertionError as e:
        raise AssertionError(f"{name}: komira.pl\n{got}\npolars\n{want}\n{e}") from None


UNITS = ("1d", "1w", "1mo")

# Each case: (name, program). `program(P, lf)` builds a frame with the module
# P (komira.pl or polars) over the frame lf of the sorted file.
TRUNCATES = [
    (
        f"truncate_{every}_{column}",
        lambda P, lf, every=every, column=column: lf.select(
            "id", P.col(column), P.col(column).dt.truncate(every).alias("start")
        ),
    )
    for every in UNITS
    for column in ("d", "t")
] + [
    ("truncate_in_place", lambda P, lf: lf.with_columns(P.col("t").dt.truncate("1mo"))),
]

DYNAMICS = [
    (
        f"group_by_dynamic_{every}_{column}",
        lambda P, lf, every=every, column=column: lf.group_by_dynamic(column, every=every).agg(
            P.col("x").sum(), P.col("x").count().alias("xc"), P.len(), P.col("id").min().alias("first_id")
        ),
    )
    for every in UNITS
    for column in ("d", "t")
] + [
    (
        "group_by_dynamic_with_a_group_by_key",
        lambda P, lf: lf.group_by_dynamic("d", every="1mo", group_by="g").agg(P.col("x").sum(), P.len()),
    ),
    (
        "group_by_dynamic_with_the_defaults_named",
        lambda P, lf: lf.group_by_dynamic(
            P.col("t"),
            every="1w",
            period="1w",
            include_boundaries=False,
            closed="left",
            label="left",
            start_by="window",
        ).agg(P.col("x").max().alias("hi")),
    ),
]


def run_cases(session, path, cases):
    failed = []
    for name, program in cases:
        try:
            check(name, program(kpl, kpl.scan_parquet(path, session=session)), program(pl, pl.scan_parquet(path)))
        except Exception as e:  # every case runs; the failures are listed at the end
            failed.append(f"{name}: {type(e).__name__}: {e}")
    return failed


def test_null_dates_are_in_no_window(session, path):
    """komira.pl over a file with null dates is polars over the same file with
    those rows dropped, for each unit."""
    failed = []
    for every in UNITS:
        name = f"null_index_{every}"
        try:
            check(
                name,
                kpl.scan_parquet(path, session=session).group_by_dynamic("d", every=every).agg(kpl.col("x").sum()),
                pl.scan_parquet(path).drop_nulls("d").group_by_dynamic("d", every=every).agg(pl.col("x").sum()),
            )
        except Exception as e:  # every case runs; the failures are listed at the end
            failed.append(f"{name}: {type(e).__name__}: {e}")
    return failed


def test_the_files_have_the_edges_the_cases_need():
    assert DATES == sorted(DATES) and STAMPS == sorted(STAMPS)
    assert any(d.weekday() == 6 for d in DATES) and any(d.weekday() == 0 for d in DATES)
    assert any((d + datetime.timedelta(days=1)).day == 1 for d in DATES)
    assert any(t.weekday() == 6 and t.microsecond == 999999 for t in STAMPS)
    assert None in SORTED["x"][1] and None in WITH_NULLS["d"][1]


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib-dir", required=True)
    parser.add_argument("--runtime-dir", required=True)
    args = parser.parse_args(argv)
    test_the_files_have_the_edges_the_cases_need()
    _native.load(os.path.join(args.lib_dir, "libkomira"))
    with tempfile.TemporaryDirectory() as work:
        ordered = os.path.join(work, "sorted.parquet")
        nulls = os.path.join(work, "nulls.parquet")
        pq.write_table(table(SORTED), ordered)
        pq.write_table(table(WITH_NULLS), nulls)
        with Session() as session:
            failed = run_cases(session, ordered, TRUNCATES + DYNAMICS)
            failed += test_null_dates_are_in_no_window(session, nulls)
    assert not failed, "{} cases failed:\n".format(len(failed)) + "\n".join(failed)
    print("pl_oracle_dynamic: {} programs equal polars' answers".format(len(TRUNCATES) + len(DYNAMICS) + len(UNITS)))


if __name__ == "__main__":
    main(sys.argv[1:])
