"""A pandas user's session over TPC-H scale factor 1 (`lineitem`, and `orders` for
the joins), through komira's plan door on the real libkomira, each answer held to
DuckDB's for the SQL that means the same over the same Parquet files
(`pandas_session_tpch_test`, CPython 3.13). Three routes answer each step and each
must equal DuckDB's answer, so they equal each other:

- the pandas skin: the program a pandas user types over `komira.read_parquet`;
- the polars skin: the same program over `komira.pl.scan_parquet`, where the polars
  skin has a spelling of it (a decimal sum has none: see below);
- the SQL entry: the SQL text, run by `Session.sql` over the files registered on the
  same session with `register_parquet`.

The steps, each an answer of a few rows (an aggregate, or the first rows of a sort
on the unique key (l_orderkey, l_linenumber)); no step reads lineitem unfiltered
into Python:

1. a ship-date cut (a date32 column against a `datetime.date`), the rows counted
   by return flag;
2. group by the two flag columns (a composite string key), the count, the least and
   the greatest order key per group, in the order of the keys;
3. the means, least and greatest of the decimal(15,2) columns and the count by the
   two flag columns under the ship-date cut (the shape of TPC-H q1), and, in the
   pandas skin and the SQL entry, the decimal sums (`sum(min_count=1)`, SQL's SUM);
4. a computed decimal column, `l_extendedprice * (1 - l_discount)` with a `Decimal`
   literal, summed (the pandas skin and the SQL entry) and averaged by the two
   flag columns under the cut;
5. the first ten rows by (l_orderkey, l_linenumber) of the lines of the orders up
   to 1000, a decimal column riding through a projection, a sort and a head;
6. a semi join and an anti join against the orders before 1993-03-01 (`isin` with a
   column of another frame; EXISTS and NOT EXISTS in SQL), counted by return flag.

What is held:

- every route's answer has the column names and order, the Arrow type names (a
  decimal's precision and scale, a date, the integer widths DuckDB writes for
  the file) and the values of DuckDB's answer: decimals, dates and integers
  exactly, floats to a relative 1e-12, rows in the order of the keys of a sorted
  step and else as a multiset;
- the polars skin's sum of a decimal column is refused, by name, with its full
  message, so the steps of decimal sums have no polars program;
- the pandas sum with its default `min_count=0` (a sum of nothing is 0, filled
  by a CASE) of a decimal column is refused by the engine with a `KomiraError`,
  whose CASE has no decimal output yet; the test fails when the engine answers
  it, so the program moves into the steps;
- a run does not stop at its first difference: it raises once, listing every
  step and route whose answer differs or that raised, with the error;
- without the library: every step has a pandas program, a SQL text, a polars
  program or none, and order keys that name columns of its SQL.

The comparator, `answer_of` and `duckdb_answer` are those of
`duckdb/test_frame_duckdb.py`, staged beside this file (python/tests/BUCK).

    test_pandas_session_tpch.py --lib-dir <dir> [--runtime-dir <dir>]

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` and `<dir>/tpch/` is
`//src/tpch_answers:tpch_sf1[data]`, whose files are
`tpch/sf1/<table>.parquet`.

Derived from TPC-H; not comparable to published TPC-H results.
"""

import collections
import datetime
import decimal
import importlib.util
import os
import sys


def _load_base():
    """duckdb/test_frame_duckdb.py, staged beside this file (python/tests/BUCK):
    its comparator and its answer helpers."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "duckdb", "test_frame_duckdb.py")
    spec = importlib.util.spec_from_file_location("test_frame_duckdb", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["test_frame_duckdb"] = module
    spec.loader.exec_module(module)
    return module


base = _load_base()

import komira
import komira.pl as kpl
from komira import UnsupportedOperation, _native

D = decimal.Decimal
SHIP_CUT = datetime.date(1998, 9, 2)
ORDER_CUT = datetime.date(1993, 3, 1)
FLAGS = ["l_returnflag", "l_linestatus"]

# One step of the session. `pandas(li, o)` and `polars(lf, lo)` are programs over
# the lineitem and orders frames of their skin (`polars` is None where the skin
# has no spelling); `sql` is DuckDB's text and the SQL entry's; `order` is the
# names of the sort keys of an ordered answer (None: a multiset); `rows` is the
# number of rows DuckDB's answer has.
Step = collections.namedtuple("Step", "name pandas polars sql order rows")


def shipped(li):
    """The lines shipped by the cut, as a pandas user filters them."""
    return li[li["l_shipdate"] <= SHIP_CUT]


def shipped_lazy(lf):
    return lf.filter(kpl.col("l_shipdate") <= SHIP_CUT)


def with_disc_price(f):
    """`f` with the price net of the discount; the `Decimal` literal is a
    decimal(1, 0), so the product's type does not hang on an integer literal."""
    return f.assign(disc_price=f["l_extendedprice"] * (D("1") - f["l_discount"]))


def early_orders(o):
    return o[o["o_orderdate"] < ORDER_CUT]


STEP_1 = Step(
    "ship-date cut, rows counted by return flag",
    lambda li, o: shipped(li).groupby("l_returnflag").agg(n=("l_orderkey", "count")),
    lambda lf, lo: shipped_lazy(lf).group_by("l_returnflag").agg(kpl.col("l_orderkey").count().alias("n")).sort("l_returnflag"),
    "SELECT l_returnflag, COUNT(l_orderkey) AS n FROM lineitem WHERE l_shipdate <= DATE '1998-09-02' "
    "GROUP BY l_returnflag ORDER BY l_returnflag",
    ("l_returnflag",),
    3,
)

STEP_2 = Step(
    "two string keys, count and least and greatest order key",
    lambda li, o: li.groupby(FLAGS).agg(
        lines=("l_orderkey", "count"), first_order=("l_orderkey", "min"), last_order=("l_orderkey", "max")
    ),
    lambda lf, lo: lf.group_by(*FLAGS)
    .agg(
        kpl.col("l_orderkey").count().alias("lines"),
        kpl.col("l_orderkey").min().alias("first_order"),
        kpl.col("l_orderkey").max().alias("last_order"),
    )
    .sort(*FLAGS),
    "SELECT l_returnflag, l_linestatus, COUNT(l_orderkey) AS lines, MIN(l_orderkey) AS first_order, "
    "MAX(l_orderkey) AS last_order FROM lineitem GROUP BY l_returnflag, l_linestatus "
    "ORDER BY l_returnflag, l_linestatus",
    tuple(FLAGS),
    4,
)

STEP_3 = Step(
    "decimal means, least and greatest and the count by the two flags under the cut",
    lambda li, o: shipped(li)
    .groupby(FLAGS)
    .agg(
        avg_qty=("l_quantity", "mean"),
        avg_price=("l_extendedprice", "mean"),
        min_disc=("l_discount", "min"),
        max_disc=("l_discount", "max"),
        count_order=("l_orderkey", "count"),
    ),
    lambda lf, lo: shipped_lazy(lf)
    .group_by(*FLAGS)
    .agg(
        kpl.col("l_quantity").mean().alias("avg_qty"),
        kpl.col("l_extendedprice").mean().alias("avg_price"),
        kpl.col("l_discount").min().alias("min_disc"),
        kpl.col("l_discount").max().alias("max_disc"),
        kpl.len().alias("count_order"),
    )
    .sort(*FLAGS),
    "SELECT l_returnflag, l_linestatus, AVG(l_quantity) AS avg_qty, AVG(l_extendedprice) AS avg_price, "
    "MIN(l_discount) AS min_disc, MAX(l_discount) AS max_disc, COUNT(l_orderkey) AS count_order FROM lineitem "
    "WHERE l_shipdate <= DATE '1998-09-02' GROUP BY l_returnflag, l_linestatus "
    "ORDER BY l_returnflag, l_linestatus",
    tuple(FLAGS),
    4,
)

# A decimal sum with min_count=1 is SQL's SUM: no group is empty, so it equals
# the default min_count=0, whose zero fill the engine does not run on a decimal
# yet (test_the_zero_filled_decimal_sum_is_refused_by_the_engine). The polars
# skin refuses a decimal sum at the verb, so this step has no polars program.
STEP_3_SUMS = Step(
    "decimal sums by the two flags under the cut",
    lambda li, o: shipped(li).groupby(FLAGS)[["l_quantity", "l_extendedprice"]].sum(min_count=1),
    None,
    "SELECT l_returnflag, l_linestatus, SUM(l_quantity) AS l_quantity, SUM(l_extendedprice) AS l_extendedprice "
    "FROM lineitem WHERE l_shipdate <= DATE '1998-09-02' GROUP BY l_returnflag, l_linestatus "
    "ORDER BY l_returnflag, l_linestatus",
    tuple(FLAGS),
    4,
)

# The computed column is held through its sum (decimal(38, 4) in both engines
# whatever width the product has) and its mean (double), not through its least or
# greatest, whose precision is the product's own width, which the two engines
# derive by their own rules.
STEP_4_SUM = Step(
    "computed decimal column summed by the two flags under the cut",
    lambda li, o: with_disc_price(shipped(li)).groupby(FLAGS)["disc_price"].sum(min_count=1),
    None,
    "SELECT l_returnflag, l_linestatus, SUM(l_extendedprice * (1 - l_discount)) AS disc_price FROM lineitem "
    "WHERE l_shipdate <= DATE '1998-09-02' GROUP BY l_returnflag, l_linestatus "
    "ORDER BY l_returnflag, l_linestatus",
    tuple(FLAGS),
    4,
)

STEP_4_MEAN = Step(
    "computed decimal column averaged and its rows counted by the two flags under the cut",
    lambda li, o: with_disc_price(shipped(li))
    .groupby(FLAGS)
    .agg(avg_disc_price=("disc_price", "mean"), n=("disc_price", "size")),
    lambda lf, lo: shipped_lazy(lf)
    .with_columns((kpl.col("l_extendedprice") * (kpl.lit(D("1")) - kpl.col("l_discount"))).alias("disc_price"))
    .group_by(*FLAGS)
    .agg(kpl.col("disc_price").mean().alias("avg_disc_price"), kpl.len().alias("n"))
    .sort(*FLAGS),
    "SELECT l_returnflag, l_linestatus, AVG(l_extendedprice * (1 - l_discount)) AS avg_disc_price, "
    "COUNT(*) AS n FROM lineitem WHERE l_shipdate <= DATE '1998-09-02' GROUP BY l_returnflag, l_linestatus "
    "ORDER BY l_returnflag, l_linestatus",
    tuple(FLAGS),
    4,
)

STEP_5 = Step(
    "first ten lines by the primary key, a decimal column carried through",
    lambda li, o: li[li["l_orderkey"] <= 1000][["l_orderkey", "l_linenumber", "l_quantity"]]
    .sort_values(["l_orderkey", "l_linenumber"])
    .head(10),
    lambda lf, lo: lf.filter(kpl.col("l_orderkey") <= 1000)
    .select("l_orderkey", "l_linenumber", "l_quantity")
    .sort("l_orderkey", "l_linenumber")
    .head(10),
    "SELECT l_orderkey, l_linenumber, l_quantity FROM lineitem WHERE l_orderkey <= 1000 "
    "ORDER BY l_orderkey, l_linenumber LIMIT 10",
    ("l_orderkey", "l_linenumber"),
    10,
)

STEP_6_SEMI = Step(
    "semi join with the early orders, counted by return flag",
    lambda li, o: li[li["l_orderkey"].isin(early_orders(o)["o_orderkey"])]
    .groupby("l_returnflag")
    .agg(n=("l_orderkey", "count")),
    lambda lf, lo: lf.join(
        lo.filter(kpl.col("o_orderdate") < ORDER_CUT), left_on="l_orderkey", right_on="o_orderkey", how="semi"
    )
    .group_by("l_returnflag")
    .agg(kpl.col("l_orderkey").count().alias("n"))
    .sort("l_returnflag"),
    "SELECT l_returnflag, COUNT(l_orderkey) AS n FROM lineitem WHERE EXISTS "
    "(SELECT 1 FROM orders WHERE orders.o_orderkey = lineitem.l_orderkey AND o_orderdate < DATE '1993-03-01') "
    "GROUP BY l_returnflag ORDER BY l_returnflag",
    ("l_returnflag",),
    # Lines of orders placed before the cut were all received before 1995, so
    # none is still open: return flags A and R only.
    2,
)

STEP_6_ANTI = Step(
    "anti join with the early orders, counted by return flag",
    lambda li, o: li[~li["l_orderkey"].isin(early_orders(o)["o_orderkey"])]
    .groupby("l_returnflag")
    .agg(n=("l_orderkey", "count")),
    lambda lf, lo: lf.join(
        lo.filter(kpl.col("o_orderdate") < ORDER_CUT), left_on="l_orderkey", right_on="o_orderkey", how="anti"
    )
    .group_by("l_returnflag")
    .agg(kpl.col("l_orderkey").count().alias("n"))
    .sort("l_returnflag"),
    "SELECT l_returnflag, COUNT(l_orderkey) AS n FROM lineitem WHERE NOT EXISTS "
    "(SELECT 1 FROM orders WHERE orders.o_orderkey = lineitem.l_orderkey AND o_orderdate < DATE '1993-03-01') "
    "GROUP BY l_returnflag ORDER BY l_returnflag",
    ("l_returnflag",),
    3,
)

STEPS = [STEP_1, STEP_2, STEP_3, STEP_3_SUMS, STEP_4_SUM, STEP_4_MEAN, STEP_5, STEP_6_SEMI, STEP_6_ANTI]


# ---- without the library -----------------------------------------------------


def test_every_step_has_programs_sql_and_order_keys_that_name_columns():
    names = [s.name for s in STEPS]
    assert len(set(names)) == len(names), "two steps share a name: {}".format(names)
    for step in STEPS:
        assert callable(step.pandas), "{}: no pandas program".format(step.name)
        assert step.polars is None or callable(step.polars), "{}: the polars program is not callable".format(step.name)
        assert step.sql.startswith("SELECT "), "{}: the SQL is not a SELECT: {}".format(step.name, step.sql)
        assert step.rows > 0, "{}: the step expects no rows, so it would compare nothing".format(step.name)
        head = step.sql.split(" FROM ")[0]
        for key in step.order or ():
            assert key in head, "{}: the order key {} is not a column of the answer: {}".format(step.name, key, head)
        if step.order is not None:
            assert " ORDER BY " in step.sql, "{}: an ordered step whose SQL has no ORDER BY: {}".format(
                step.name, step.sql
            )


# ---- with the library --------------------------------------------------------


def tpch_path(lib_dir, table):
    path = os.path.join(lib_dir, "tpch", "tpch", "sf1", table + ".parquet")
    assert os.path.isfile(path), "the staged TPC-H file {} is missing".format(path)
    return path


def duckdb_over(paths):
    import duckdb

    con = duckdb.connect()
    for table, path in paths.items():
        con.execute("CREATE VIEW {} AS SELECT * FROM read_parquet('{}')".format(table, path.replace("'", "''")))
    return con


def route_failure(step, route, run, want):
    """None when `run()`'s answer is `want`, else the line that names the step and
    the route and what went wrong."""
    try:
        got = base.answer_of(run())
    except Exception as e:  # every refusal and error is named, not only the first
        return "{} [{}]: raised {}: {}".format(step.name, route, type(e).__name__, e)
    found = base.differences(got, want, step.order)
    if found is not None:
        return "{} [{}]: not DuckDB's answer: {}; got {}, DuckDB {}".format(step.name, route, found, got, want)
    return None


def session_failures(session, con, paths):
    li = komira.read_parquet(paths["lineitem"], session=session)
    o = komira.read_parquet(paths["orders"], session=session)
    lf = kpl.scan_parquet(paths["lineitem"], session=session)
    lo = kpl.scan_parquet(paths["orders"], session=session)
    failures = []
    for step in STEPS:
        want = base.duckdb_answer(con, step.sql)
        assert len(want[2]) == step.rows, "{}: DuckDB's answer has {} rows, the step expects {}".format(
            step.name, len(want[2]), step.rows
        )
        routes = [
            ("pandas", lambda: step.pandas(li, o).materialize().to_arrow(), want),
            ("sql", lambda: session.sql(step.sql).to_arrow(), want),
        ]
        if step.polars is not None:
            routes.append(("polars", lambda: step.polars(lf, lo).collect().to_arrow(), want))
        for route, run, expected in routes:
            failure = route_failure(step, route, run, expected)
            if failure is not None:
                failures.append(failure)
    return failures


def test_pandas_polars_and_sql_answers_of_the_session_equal_duckdb(lib_dir):
    paths = {table: tpch_path(lib_dir, table) for table in ("lineitem", "orders")}
    con = duckdb_over(paths)
    with komira.Session() as session:
        for table, path in paths.items():
            session.register_parquet(table, path)
        failures = session_failures(session, con, paths)
    assert not failures, "{} routes of the session differ from DuckDB:\n{}".format(len(failures), "\n".join(failures))


def test_polars_skin_refuses_the_sum_of_a_decimal_column_by_name(lib_dir):
    path = tpch_path(lib_dir, "lineitem")
    with komira.Session() as session:
        lf = kpl.scan_parquet(path, session=session)
        try:
            lf.group_by(*FLAGS).agg(kpl.col("l_quantity").sum())
        except UnsupportedOperation as e:
            assert e.args[0] == "sum of a column of type decimal128 is not supported yet", repr(e.args[0])
        else:
            raise AssertionError("the polars skin summed a decimal column")


# The sum a pandas user writes first, `agg(total=(column, "sum"))`, fills a sum
# of nothing with 0 (min_count=0) by a CASE, and the engine's CASE has no
# decimal output yet; until it has, the engine refuses this program with an
# error of the library (a `KomiraError`). When the engine answers it, this test
# fails and the program moves into the session's steps beside STEP_3_SUMS.
ENGINE_REFUSED = [
    ("a named decimal sum", lambda li: shipped(li).groupby(FLAGS).agg(sum_qty=("l_quantity", "sum"))),
    ("a decimal sum of one column", lambda li: shipped(li).groupby(FLAGS)["l_extendedprice"].sum()),
]


def test_the_zero_filled_decimal_sum_is_refused_by_the_engine(lib_dir):
    path = tpch_path(lib_dir, "lineitem")
    with komira.Session() as session:
        li = komira.read_parquet(path, session=session)
        for name, program in ENGINE_REFUSED:
            try:
                program(li).materialize().to_arrow()
            except komira.KomiraError:
                pass
            else:
                raise AssertionError("{}: the engine answered it; move it into the session's steps".format(name))


PURE = [test_every_step_has_programs_sql_and_order_keys_that_name_columns]

WITH_LIBRARY = [
    test_pandas_polars_and_sql_answers_of_the_session_equal_duckdb,
    test_polars_skin_refuses_the_sum_of_a_decimal_column_by_name,
    test_the_zero_filled_decimal_sum_is_refused_by_the_engine,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    for test in PURE:
        test()
    # The library is loaded before pyarrow and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    for test in WITH_LIBRARY:
        test(lib_dir)
    print(
        "pandas session tpch: {} steps equal DuckDB's answer by the pandas skin, the polars skin and the SQL entry "
        "over libkomira {}".format(len(STEPS), komira.abi_version())
    )


if __name__ == "__main__":
    main(sys.argv[1:])
