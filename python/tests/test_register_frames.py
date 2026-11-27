"""`Session.register` of a pandas and a polars DataFrame, which it reads
through their Arrow PyCapsule stream interface (`__arrow_c_stream__`), held
to DuckDB's answer to the same SQL over the same frame, which DuckDB reads
through its own `register` (`register_frames_test`, CPython 3.13, the real
libkomira):

- a pandas DataFrame and a polars DataFrame of the same rows, with a NULL in
  every column (a missing int, float, string and bool), each answer a filter,
  a NULL test and a group-by aggregate equal to DuckDB's; pandas' strings
  reach komira as `large_string` and polars' as `string_view`, both read as
  `string`;
- the registered rows are a copy: a pandas frame changed after it was
  registered still answers the rows it had, and registering it again answers
  the new ones.

    test_register_frames.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which the
rule passes, is not read).
"""

import math
import os
import sys

import komira
from komira import _native

COLUMNS = {
    "id": [1, 2, 3, 4, 5, 6],
    "region": ["east", "west", None, "east", "north", "west"],
    "amount": [120, None, 45, 200, 80, 150],
    "price": [1.5, 2.25, None, 0.5, -1.0, 3.0],
    "ok": [True, None, False, True, True, False],
}

QUERIES = (
    ("every row", "SELECT * FROM f ORDER BY id"),
    ("a filter", "SELECT id, amount FROM f WHERE amount > 100 ORDER BY id"),
    ("a NULL test", "SELECT id FROM f WHERE region IS NULL OR price IS NULL OR ok IS NULL ORDER BY id"),
    (
        "a group-by aggregate",
        "SELECT region, count(*) AS n, count(amount) AS counted, sum(amount) AS total,"
        " max(price) AS hi, avg(price) AS mean FROM f GROUP BY region ORDER BY region NULLS LAST",
    ),
)


def pandas_frame():
    import pandas as pd

    return pd.DataFrame(
        {
            "id": pd.array(COLUMNS["id"], dtype="Int64"),
            "region": pd.array(COLUMNS["region"], dtype="string"),
            "amount": pd.array(COLUMNS["amount"], dtype="Int64"),
            "price": pd.array(COLUMNS["price"], dtype="Float64"),
            "ok": pd.array(COLUMNS["ok"], dtype="boolean"),
        }
    )


def polars_frame():
    import polars as pl

    return pl.DataFrame(COLUMNS, schema={"id": pl.Int64, "region": pl.String, "amount": pl.Int64, "price": pl.Float64, "ok": pl.Boolean})


def rows_of(table):
    """Names and rows of a pyarrow table, a large string read as a string."""
    names = list(table.column_names)
    return names, [tuple(r[n] for n in names) for r in table.to_pylist()]


def cell_equal(a, b):
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, float) or isinstance(b, float):
        return isinstance(a, float) and isinstance(b, float) and math.isclose(a, b, rel_tol=1e-12, abs_tol=0.0)
    return type(a) is type(b) and a == b


def assert_equal_answers(got, want, what):
    assert got[0] == want[0], "{}: columns {} != {}".format(what, got[0], want[0])
    assert len(got[1]) == len(want[1]), "{}: {} rows, expected {}".format(what, len(got[1]), len(want[1]))
    for i, (g, w) in enumerate(zip(got[1], want[1])):
        assert len(g) == len(w) and all(cell_equal(x, y) for x, y in zip(g, w)), "{}: row {} is {}, expected {}".format(
            what, i, g, w
        )


def duckdb_rows(con, sql):
    cursor = con.execute(sql)
    fetch = getattr(cursor, "to_arrow_table", None) or getattr(cursor, "fetch_arrow_table", None)
    table = fetch() if fetch is not None else cursor.arrow()
    if hasattr(table, "read_all"):
        table = table.read_all()
    return rows_of(table)


def assert_frame_equals_duckdb(frame, what):
    import duckdb

    con = duckdb.connect()
    con.register("f", frame)
    with komira.Session() as s:
        s.register("f", frame)
        for name, sql in QUERIES:
            assert_equal_answers(rows_of(s.sql(sql).to_arrow()), duckdb_rows(con, sql), "{}, {}".format(what, name))


def test_a_pandas_frame_answers_equal_to_duckdb():
    assert_frame_equals_duckdb(pandas_frame(), "pandas.DataFrame")


def test_a_polars_frame_answers_equal_to_duckdb():
    assert_frame_equals_duckdb(polars_frame(), "polars.DataFrame")


def test_a_frame_changed_after_it_was_registered_keeps_the_rows_it_had():
    frame = pandas_frame()
    with komira.Session() as s:
        s.register("f", frame)
        frame.loc[0, "amount"] = 999
        sql = "SELECT amount FROM f WHERE id = 1"
        assert s.sql(sql).to_arrow().to_pylist() == [{"amount": 120}]
        s.register("f", frame)
        assert s.sql(sql).to_arrow().to_pylist() == [{"amount": 999}]


TESTS = [
    test_a_pandas_frame_answers_equal_to_duckdb,
    test_a_polars_frame_answers_equal_to_duckdb,
    test_a_frame_changed_after_it_was_registered_keeps_the_rows_it_had,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    # The library is loaded before pyarrow, pandas, polars and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    failed = []
    for test in TESTS:
        try:
            test()
            print("ok", test.__name__)
        except Exception as e:  # every test runs, and each failure is listed
            failed.append(test.__name__)
            print("FAIL", test.__name__, "{}: {}".format(type(e).__name__, e))
    if failed:
        raise SystemExit("register frames: {} of {} tests failed: {}".format(len(failed), len(TESTS), ", ".join(failed)))
    print("register frames: {} tests over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
