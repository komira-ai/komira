"""The pandas-shaped frame's `melt` and `komira.melt` held to DuckDB's `UNPIVOT
INCLUDE NULLS`, on the real libkomira (`frame_melt_duckdb_test`, CPython 3.13).

Each case is a melt program run through komira's plan door (`komira_plan_stream`,
no SQL), and the DuckDB query that means pandas' answer to it: `UNPIVOT INCLUDE
NULLS (value FOR variable IN (...))` over the same Parquet file, which keeps a
missing value as a row as pandas' melt does, with the id columns and the value
columns that pandas' argument rules resolve the call to. The answers must have
the same column names, the same Arrow type for each column (a string in any of
Arrow's string layouts), and the same rows: as a multiset, since komira's frame
has no row order, and in order for a sorted melt.

The file has a string id with a missing value, an int64 id, int64 columns
with missing values and one written as never missing, int32 and float64
columns with missing values, and string columns with missing values and two
written as never missing. The cases cover: `id_vars`, `value_vars`,
`var_name` and `value_name` given; the default names; `value_vars` None
(every column not in `id_vars`); no `id_vars`; one value column; two id
columns; `value_vars` in another order; a value column that is also an id
column and one named twice; int32, float64 and string values; an int64
column that never holds a missing value beside ones that do; two string
columns that never hold one; melt of a filtered and of a sorted frame; a sort
of the melt, compared in order; `komira.melt(frame, ...)`. And the oracle
itself: DuckDB's `INCLUDE NULLS` keeps the rows whose value is missing.

    test_frame_melt_duckdb.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir` is not
read).
"""

import collections
import os
import sys
import tempfile

import komira
from komira import Session
from komira import _native

# name: (Arrow type name, allows missing values, values)
WIDE = {
    "name": ("string", True, ["Ana", "Bo", "Cy", None, "Di", "Ed"]),
    "k": ("int64", True, [1, 1, 2, 2, None, 3]),
    "q1": ("int64", True, [10, 5, 1, None, 7, -3]),
    "q2": ("int64", True, [20, None, 2, None, 8, 0]),
    "q3": ("int64", False, [30, 7, 3, 4, 9, 11]),
    "i1": ("int32", True, [1, None, 3, 4, 5, 6]),
    "i2": ("int32", True, [None, 2, 3, None, 5, 6]),
    "f1": ("float64", True, [1.5, None, -2.25, 4.0, 0.5, 0.0]),
    "f2": ("float64", True, [None, 2.5, 3.75, None, -1.0, 8.0]),
    "s1": ("string", True, ["a", None, "", "dd", "e", "ff"]),
    "s2": ("string", True, [None, "B", "cc", "D", None, "é"]),
    "s3": ("string", False, ["x", "", "yy", "z", "w", "v"]),
    "s4": ("string", False, ["p", "q", "", "r", "s", "t"]),
}


def write_table(path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    types = {"string": pa.string(), "int64": pa.int64(), "int32": pa.int32(), "float64": pa.float64()}
    schema = pa.schema([pa.field(n, types[t], nullable=null) for n, (t, null, _) in WIDE.items()])
    table = pa.table({n: pa.array(v, type=types[t]) for n, (t, _, v) in WIDE.items()}, schema=schema)
    pq.write_table(table, path)


# ---- the comparison ------------------------------------------------------------


def _type(t):
    import pyarrow as pa

    return "string" if t in (pa.string(), pa.large_string(), pa.string_view()) else str(t)


def answer_of(table):
    """(names, types, rows) of a pyarrow Table, each row as its repr."""
    return (
        table.schema.names,
        [_type(f.type) for f in table.schema],
        [repr(row) for row in table.to_pylist()],
    )


def differences(got, want, ordered):
    """What differs between two answers, or "" when they are the same."""
    if got[0] != want[0]:
        return f"column names {got[0]} != {want[0]}"
    if got[1] != want[1]:
        return f"column types {got[1]} != {want[1]}"
    g, w = (got[2], want[2]) if ordered else (sorted(got[2]), sorted(want[2]))
    if g != w:
        return f"rows\nkomira {g}\nduckdb {w}"
    return ""


def duckdb_answer(con, sql):
    cursor = con.execute(sql)
    fetch = getattr(cursor, "fetch_arrow_table", None)
    table = fetch() if fetch is not None else cursor.arrow()
    if hasattr(table, "read_all"):
        table = table.read_all()
    return answer_of(table)


def unpivot_sql(ids, values, variable="variable", value="value", where="", order=""):
    """DuckDB's answer to pandas' melt with the id columns `ids` and the value
    columns `values`, as pandas resolves them."""
    inner = ", ".join(ids + values)
    listed = ", ".join(values)
    kept = ", ".join(ids + [variable, value])
    return (
        f"SELECT {kept} FROM (SELECT {inner} FROM t{where}) "
        f"UNPIVOT INCLUDE NULLS ({value} FOR {variable} IN ({listed})){order}"
    )


# Each case: the name, the program over a komira frame, the DuckDB SQL, and
# whether the answer is ordered.
Case = collections.namedtuple("Case", "name program sql ordered")

CASES = [
    Case(
        "melt_with_every_argument",
        lambda d: d.melt(id_vars=["name"], value_vars=["q1", "q2", "q3"], var_name="quarter", value_name="score"),
        unpivot_sql(["name"], ["q1", "q2", "q3"], "quarter", "score"),
        False,
    ),
    Case(
        "melt_default_names",
        lambda d: d.melt(id_vars="name", value_vars=["q1", "q2"]),
        unpivot_sql(["name"], ["q1", "q2"]),
        False,
    ),
    Case(
        "melt_value_vars_none_is_every_other_column",
        lambda d: d[["name", "q1", "q2"]].melt(id_vars="name"),
        unpivot_sql(["name"], ["q1", "q2"]),
        False,
    ),
    Case("melt_with_no_id_vars", lambda d: d[["q1", "q2"]].melt(), unpivot_sql([], ["q1", "q2"]), False),
    Case("melt_one_value_column", lambda d: d.melt(id_vars="name", value_vars="q2"), unpivot_sql(["name"], ["q2"]), False),
    Case(
        "melt_two_id_columns",
        lambda d: d.melt(id_vars=["k", "name"], value_vars=["q1", "q2"]),
        unpivot_sql(["k", "name"], ["q1", "q2"]),
        False,
    ),
    Case(
        "melt_value_vars_in_another_order",
        lambda d: d.melt(id_vars="name", value_vars=["q2", "q1"]),
        unpivot_sql(["name"], ["q2", "q1"]),
        False,
    ),
    Case(
        "melt_value_vars_with_an_id_and_a_column_twice",
        lambda d: d.melt(id_vars="name", value_vars=["name", "q1", "q2", "q1"]),
        unpivot_sql(["name"], ["q1", "q2"]),
        False,
    ),
    Case(
        "melt_int32_values",
        lambda d: d.melt(id_vars="name", value_vars=["i1", "i2"]),
        unpivot_sql(["name"], ["i1", "i2"]),
        False,
    ),
    Case(
        "melt_float_values_with_missing",
        lambda d: d.melt(id_vars="k", value_vars=["f1", "f2"]),
        unpivot_sql(["k"], ["f1", "f2"]),
        False,
    ),
    Case(
        "melt_string_values",
        lambda d: d.melt(id_vars="name", value_vars=["s1", "s2"], value_name="text"),
        unpivot_sql(["name"], ["s1", "s2"], value="text"),
        False,
    ),
    Case(
        "melt_a_column_that_never_holds_a_missing_value",
        lambda d: d.melt(id_vars="name", value_vars=["q1", "q3", "q2"]),
        unpivot_sql(["name"], ["q1", "q3", "q2"]),
        False,
    ),
    Case(
        "melt_string_columns_that_never_hold_a_missing_value",
        lambda d: d.melt(id_vars="k", value_vars=["s3", "s4"]),
        unpivot_sql(["k"], ["s3", "s4"]),
        False,
    ),
    Case(
        "melt_of_a_filtered_frame",
        lambda d: d[d["q3"] > 4].melt(id_vars="name", value_vars=["q1", "q2"]),
        unpivot_sql(["name"], ["q1", "q2"], where=" WHERE q3 > 4"),
        False,
    ),
    Case(
        "melt_of_a_sorted_frame",
        lambda d: d.sort_values("q1").melt(id_vars="name", value_vars=["q1", "q2"]),
        unpivot_sql(["name"], ["q1", "q2"]),
        False,
    ),
    Case(
        "sort_of_a_melt",
        lambda d: d.melt(id_vars="name", value_vars=["q1", "q2"]).sort_values(["name", "variable"]),
        unpivot_sql(["name"], ["q1", "q2"], order=" ORDER BY name ASC NULLS LAST, variable ASC NULLS LAST"),
        True,
    ),
    Case(
        "module_melt",
        lambda d: komira.melt(d, id_vars=["name"], value_vars=["q1", "q2"], var_name="quarter"),
        unpivot_sql(["name"], ["q1", "q2"], "quarter"),
        False,
    ),
]


def test_duckdb_include_nulls_keeps_the_rows_of_a_missing_value(con):
    """The oracle keeps a missing value as a row, as pandas' melt does: `Bo`'s
    `q2` and `Ana`'s missing name are rows of its answer."""
    names, _, rows = duckdb_answer(con, unpivot_sql(["name"], ["q1", "q2"]))
    assert names == ["name", "variable", "value"], names
    assert len(rows) == 12, rows
    assert repr({"name": "Bo", "variable": "q2", "value": None}) in rows, rows
    assert repr({"name": None, "variable": "q1", "value": None}) in rows, rows


def test_melt_equals_duckdb_unpivot_include_nulls(con, session, path):
    failed = []
    for case in CASES:
        frame = komira.read_parquet(path, session=session)
        got = case.program(frame)
        if (got._order() is not None) != case.ordered:
            failed.append(f"{case.name}: the frame's order is {got._order()}")
            continue
        why = differences(answer_of(got.materialize().to_arrow()), duckdb_answer(con, case.sql), case.ordered)
        if why:
            failed.append(f"{case.name}: {why}")
    assert not failed, "{} cases failed:\n".format(len(failed)) + "\n".join(failed)


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    # The library is loaded before pyarrow and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    import duckdb

    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "wide.parquet")
        write_table(path)
        con = duckdb.connect()
        con.execute("CREATE VIEW t AS SELECT * FROM read_parquet('{}')".format(path.replace("'", "''")))
        test_duckdb_include_nulls_keeps_the_rows_of_a_missing_value(con)
        with Session() as session:
            test_melt_equals_duckdb_unpivot_include_nulls(con, session, path)
        con.close()
    print("frame melt duckdb: {} cases".format(len(CASES)))


if __name__ == "__main__":
    main(sys.argv[1:])
