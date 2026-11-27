"""The pandas-shaped frame's `melt` and `komira.melt` against pandas itself, on
the real libkomira (`frame_melt_pandas_test`, CPython 3.13).

Each case is one call written once for both: komira's frame over a Parquet
file, encoded as a plan (a union of one projection per value column) and run
by `komira_plan_stream`, and pandas' `melt` over the same file read with
pyarrow into a frame of Arrow dtypes, which keep a missing integer a missing
integer. The two answers must have the same column names, the same Arrow type
for each column (a string in any of Arrow's string layouts), and the same rows
as a multiset: komira's frame has no row order, while pandas gives every row
of the first value column, then of the next.

The file has a string id with a missing value, an int64 id, int64 columns
with missing values and one written as never missing, int32 and float64
columns, and string columns with missing values and two written as never
missing. The cases cover: `id_vars`, `value_vars`, `var_name` and
`value_name` given; the default names; `value_vars` None (every column not in
`id_vars`); no `id_vars`; one value column; two id columns; `value_vars` in
another order; a value column that is also an id column and one named twice;
int32, float64 and string values; an int64 column that never holds a missing
value beside ones that do; two string columns that never hold one; melt of a filtered and of a
sorted frame; a sort of the melt, compared in order; `komira.melt(frame, ...)`
against `pandas.melt`.

    test_frame_melt_pandas.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import argparse
import os
import sys
import tempfile

import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

import komira
from komira import Session
from komira import _native

assert pd.__version__ == "3.0.6", pd.__version__

# name: (type, allows missing values, values)
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

_STRING_LAYOUTS = (pa.string(), pa.large_string(), pa.string_view())


def table():
    schema = pa.schema([pa.field(n, t, nullable=null) for n, (t, null, _) in WIDE.items()])
    return pa.table({n: pa.array(v, type=t) for n, (t, _, v) in WIDE.items()}, schema=schema)


def _type(t):
    return "string" if t in _STRING_LAYOUTS else str(t)


def _rows(arrow):
    return [repr(row) for row in arrow.to_pylist()]


def check(name, got, want, ordered):
    """komira's answer `got` (a pyarrow Table) equals pandas' `want` (a pandas
    frame): names, types, and rows (in order when `ordered`)."""
    want = pa.Table.from_pandas(want, preserve_index=False)
    assert got.schema.names == want.schema.names, (name, got.schema.names, want.schema.names)
    assert [_type(f.type) for f in got.schema] == [_type(f.type) for f in want.schema], (name, got.schema, want.schema)
    g, w = _rows(got), _rows(want)
    if not ordered:
        g, w = sorted(g), sorted(w)
    assert g == w, f"{name}: komira\n{g}\npandas\n{w}"


# Each case: (name, program, ordered). `program(frame)` calls melt on a
# komira frame or a pandas one; `module` cases call the module's melt.
CASES = [
    (
        "melt_with_every_argument",
        lambda d: d.melt(id_vars=["name"], value_vars=["q1", "q2", "q3"], var_name="quarter", value_name="score"),
        False,
    ),
    ("melt_default_names", lambda d: d.melt(id_vars="name", value_vars=["q1", "q2"]), False),
    ("melt_value_vars_none_is_every_other_column", lambda d: d[["name", "q1", "q2"]].melt(id_vars="name"), False),
    ("melt_with_no_id_vars", lambda d: d[["q1", "q2"]].melt(), False),
    ("melt_one_value_column", lambda d: d.melt(id_vars="name", value_vars="q2"), False),
    ("melt_two_id_columns", lambda d: d.melt(id_vars=["k", "name"], value_vars=["q1", "q2"]), False),
    ("melt_value_vars_in_another_order", lambda d: d.melt(id_vars="name", value_vars=["q2", "q1"]), False),
    (
        "melt_value_vars_with_an_id_and_a_column_twice",
        lambda d: d.melt(id_vars="name", value_vars=["name", "q1", "q2", "q1"]),
        False,
    ),
    ("melt_int32_values", lambda d: d.melt(id_vars="name", value_vars=["i1", "i2"]), False),
    ("melt_float_values_with_missing", lambda d: d.melt(id_vars="k", value_vars=["f1", "f2"]), False),
    ("melt_string_values", lambda d: d.melt(id_vars="name", value_vars=["s1", "s2"], value_name="text"), False),
    (
        "melt_a_column_that_never_holds_a_missing_value",
        lambda d: d.melt(id_vars="name", value_vars=["q1", "q3", "q2"]),
        False,
    ),
    ("melt_string_columns_that_never_hold_a_missing_value", lambda d: d.melt(id_vars="k", value_vars=["s3", "s4"]), False),
    ("melt_of_a_filtered_frame", lambda d: d[d["q3"] > 4].melt(id_vars="name", value_vars=["q1", "q2"]), False),
    ("melt_of_a_sorted_frame", lambda d: d.sort_values("q1").melt(id_vars="name", value_vars=["q1", "q2"]), False),
    (
        "sort_of_a_melt",
        lambda d: d.melt(id_vars="name", value_vars=["q1", "q2"]).sort_values(["name", "variable"]),
        True,
    ),
]

MODULE_CASES = [
    (
        "module_melt",
        lambda m, d: m.melt(d, id_vars=["name"], value_vars=["q1", "q2"], var_name="quarter"),
        False,
    ),
]


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib-dir", required=True)
    parser.add_argument("--runtime-dir", required=True)
    args = parser.parse_args(argv)
    _native.load(os.path.join(args.lib_dir, "libkomira"))
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "wide.parquet")
        pq.write_table(table(), path)
        pandas_frame = pq.read_table(path).to_pandas(types_mapper=pd.ArrowDtype)
        with Session() as session:
            frame = komira.read_parquet(path, session=session)
            for name, program, ordered in CASES:
                got = program(frame)
                assert (got._order() is not None) == ordered, (name, got._order())
                check(name, got.materialize().to_arrow(), program(pandas_frame), ordered)
            for name, program, ordered in MODULE_CASES:
                check(name, program(komira, frame).materialize().to_arrow(), program(pd, pandas_frame), ordered)
    print("frame_melt_pandas: {} cases equal pandas' answers".format(len(CASES) + len(MODULE_CASES)))


if __name__ == "__main__":
    main(sys.argv[1:])
