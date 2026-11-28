"""`Session.register` of a polars DataFrame, held to polars itself
(`register_polars_test`, CPython 3.13, the real libkomira).

The frame is registered through its Arrow PyCapsule stream interface
(`__arrow_c_stream__`), which polars exports with its strings as
`string_view`: komira registers them as `string`. Each SQL query over the
registered frame must answer the rows polars answers for the same program
over the same frame:

- every row: the values and NULLs of each column (an int, a float, a string
  and a bool, each with a missing value), with the strings read as `string`;
- a filter, and a NULL test over three columns;
- a group-by aggregate (count, count of a column, sum, max and mean), with a
  NULL group, which SQL's `NULLS LAST` and polars' `nulls_last` both put last;
- a lazy polars frame is refused with a `TypeError` naming its type, as it
  has no Arrow stream of its own: collect it first.

The test is of the `pl_oracle/` family (python/tests/BUCK): CPython 3.13
alone, the minor with a pinned polars, on the real libkomira, with the
generated plan modules, protobuf, polars and pyarrow.

    test_register_polars.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which the
rule passes, is not read).
"""

import argparse
import math
import os
import sys

from komira import Session, _native

COLUMNS = {
    "id": [1, 2, 3, 4, 5, 6],
    "region": ["east", "west", None, "east", "north", "west"],
    "amount": [120, None, 45, 200, 80, 150],
    "price": [1.5, 2.25, None, 0.5, -1.0, 3.0],
    "ok": [True, None, False, True, True, False],
}


def frame():
    import polars as pl

    return pl.DataFrame(
        COLUMNS,
        schema={"id": pl.Int64, "region": pl.String, "amount": pl.Int64, "price": pl.Float64, "ok": pl.Boolean},
    )


def cases():
    """(name, SQL over `f`, the same program in polars), each answer in a
    complete order."""
    import polars as pl

    return [
        ("every row", "SELECT * FROM f ORDER BY id", lambda d: d.sort("id")),
        (
            "a filter",
            "SELECT id, amount FROM f WHERE amount > 100 ORDER BY id",
            lambda d: d.filter(pl.col("amount") > 100).select("id", "amount").sort("id"),
        ),
        (
            "a NULL test",
            "SELECT id FROM f WHERE region IS NULL OR price IS NULL OR ok IS NULL ORDER BY id",
            lambda d: d.filter(pl.col("region").is_null() | pl.col("price").is_null() | pl.col("ok").is_null())
            .select("id")
            .sort("id"),
        ),
        (
            "a group-by aggregate",
            "SELECT region, count(*) AS n, count(amount) AS counted, sum(amount) AS total, max(price) AS hi,"
            " avg(price) AS mean FROM f GROUP BY region ORDER BY region NULLS LAST",
            lambda d: d.group_by("region")
            .agg(
                pl.len().alias("n"),
                pl.col("amount").count().alias("counted"),
                pl.col("amount").sum().alias("total"),
                pl.col("price").max().alias("hi"),
                pl.col("price").mean().alias("mean"),
            )
            .sort("region", nulls_last=True),
        ),
    ]


def cell_equal(a, b):
    """Cells by value: komira's integer sum is a decimal of scale 0 (as
    DuckDB's HUGEINT is) where polars' is an int; floats to a relative 1e-12."""
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, float) or isinstance(b, float):
        return math.isclose(float(a), float(b), rel_tol=1e-12, abs_tol=0.0)
    if isinstance(a, bool) or isinstance(b, bool):
        return type(a) is type(b) and a == b
    return a == b


def rows_of(table):
    names = list(table.column_names)
    return names, [tuple(r[n] for n in names) for r in table.to_pylist()]


def test_a_polars_frame_answers_as_polars_does(session):
    df = frame()
    session.register("f", df)
    for name, sql, program in cases():
        got_names, got = rows_of(session.sql(sql).to_arrow())
        want_names, want = rows_of(program(df).to_arrow())
        assert got_names == want_names, "{}: columns {} != {}".format(name, got_names, want_names)
        assert len(got) == len(want), "{}: {} rows, expected {}".format(name, len(got), len(want))
        for i, (g, w) in enumerate(zip(got, want)):
            assert all(cell_equal(x, y) for x, y in zip(g, w)), "{}: row {} is {}, expected {}".format(name, i, g, w)


def test_strings_of_a_polars_frame_register_as_string(session):
    import pyarrow as pa

    df = frame()
    # The Arrow stream polars exports, which register reads.
    exported = pa.RecordBatchReader.from_stream(df).schema
    assert str(exported.field("region").type) == "string_view", exported
    session.register("f", df)
    got = session.sql("SELECT region FROM f ORDER BY id").to_arrow()
    assert str(got.schema.field("region").type) == "string", got.schema
    assert got.column(0).to_pylist() == COLUMNS["region"], got.column(0).to_pylist()


def test_a_lazy_polars_frame_is_refused_by_its_type(session):
    lazy = frame().lazy()
    try:
        session.register("f", lazy)
    except TypeError as e:
        want = (
            "register takes a komira frame or an object with the Arrow PyCapsule stream interface "
            "(__arrow_c_stream__), such as a pyarrow.Table or RecordBatchReader, not LazyFrame"
        )
        assert str(e) == want, str(e)
    else:
        raise AssertionError("a polars LazyFrame was registered")


TESTS = [
    test_a_polars_frame_answers_as_polars_does,
    test_strings_of_a_polars_frame_register_as_string,
    test_a_lazy_polars_frame_is_refused_by_its_type,
]


def main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--lib-dir", required=True)
    parser.add_argument("--runtime-dir", required=True)
    args = parser.parse_args(argv)
    # The library is loaded before pyarrow and polars are imported.
    _native.load(os.path.join(args.lib_dir, "libkomira"))
    for test in TESTS:
        with Session() as session:
            test(session)
        print("ok", test.__name__)
    print("register polars: {} tests".format(len(TESTS)))


if __name__ == "__main__":
    main(sys.argv[1:])
