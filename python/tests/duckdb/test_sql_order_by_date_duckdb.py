"""ORDER BY a DATE column through Session.sql, held to DuckDB
(`sql_order_by_date_duckdb_test`, CPython 3.13, the real libkomira).

Each query runs in komira and in DuckDB over the same files, and both answers
must equal the rows written here:

- a CSV file registered with register_csv and read with `read_csv(...)` in the
  query (orders.csv: six orders of January and February 2024, every date
  distinct), whose `order_date` reads as a DATE;
- a Parquet file (days.parquet) whose DATE column `d` holds 2024-01-03,
  NULL, 1969-12-31 (a day before the epoch), 2024-01-05, 1970-01-01, NULL and
  2024-02-29, by `id` 0 to 6;
- `ORDER BY month_start` and `ORDER BY month_start DESC` over
  `date_trunc('month', order_date)` grouped, and the same by week;
- `ORDER BY order_date DESC LIMIT 2`, over the registered table and over
  `read_csv(...)`;
- `ORDER BY d` and `ORDER BY d DESC`, NULLs last in both directions (DuckDB's
  default null order, and komira's), `NULLS FIRST` in both directions, a
  LIMIT that cuts before the NULLs, one that cuts between the two NULLs and
  one that keeps only NULLs, and `d DESC, id` as two keys;
- every DATE column comes back as pyarrow `date32`, its values as
  `datetime.date`;
- the pandas-shaped frame over the same files sorts by a date too:
  `sort_values` ascending and descending with NULLs last (pandas' default) and
  `na_position="first"`, `head(2)` after a descending sort, and `groupby` on a
  date with its default `sort=True`, the groups in date order.

DuckDB sorts are not stable, so no query here orders rows that tie on every
key and differ in another column.

    test_sql_order_by_date_duckdb.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which the
rule passes, is not read).
"""

import datetime
import os
import sys
import tempfile

import komira
from komira import _native

D = datetime.date

ORDERS_CSV = (
    "order_id,order_date,amount\n"
    "1,2024-01-03,10\n"
    "2,2024-01-15,20\n"
    "3,2024-01-16,5\n"
    "4,2024-02-05,40\n"
    "5,2024-02-07,15\n"
    "6,2024-02-29,30\n"
)

DAYS = [D(2024, 1, 3), None, D(1969, 12, 31), D(2024, 1, 5), D(1970, 1, 1), None, D(2024, 2, 29)]

BY_MONTH = (
    "SELECT date_trunc('month', order_date) AS month_start, count(*) AS n"
    " FROM orders GROUP BY 1 ORDER BY month_start"
)

BY_WEEK = (
    "SELECT date_trunc('week', order_date) AS week_start, count(*) AS n"
    " FROM orders GROUP BY 1 ORDER BY week_start"
)

LATEST_TWO = "SELECT order_id, order_date FROM {} ORDER BY order_date DESC LIMIT 2"

ASCENDING = [D(1969, 12, 31), D(1970, 1, 1), D(2024, 1, 3), D(2024, 1, 5), D(2024, 2, 29)]
DESCENDING = list(reversed(ASCENDING))

# (SQL over `orders` and `days`, the rows both engines must answer, the names
# of the DATE columns of the answer).
CASES = [
    (BY_MONTH, [(D(2024, 1, 1), 3), (D(2024, 2, 1), 3)], ["month_start"]),
    (BY_MONTH + " DESC", [(D(2024, 2, 1), 3), (D(2024, 1, 1), 3)], ["month_start"]),
    (
        BY_WEEK,
        [(D(2024, 1, 1), 1), (D(2024, 1, 15), 2), (D(2024, 2, 5), 2), (D(2024, 2, 26), 1)],
        ["week_start"],
    ),
    (LATEST_TWO.format("orders"), [(6, D(2024, 2, 29)), (5, D(2024, 2, 7))], ["order_date"]),
    ("SELECT d FROM days ORDER BY d", [(d,) for d in ASCENDING + [None, None]], ["d"]),
    ("SELECT d FROM days ORDER BY d DESC", [(d,) for d in DESCENDING + [None, None]], ["d"]),
    ("SELECT d FROM days ORDER BY d ASC NULLS LAST", [(d,) for d in ASCENDING + [None, None]], ["d"]),
    ("SELECT d FROM days ORDER BY d NULLS FIRST", [(d,) for d in [None, None] + ASCENDING], ["d"]),
    ("SELECT d FROM days ORDER BY d DESC NULLS FIRST", [(d,) for d in [None, None] + DESCENDING], ["d"]),
    ("SELECT id, d FROM days ORDER BY d LIMIT 2", [(2, D(1969, 12, 31)), (4, D(1970, 1, 1))], ["d"]),
    ("SELECT d FROM days ORDER BY d DESC LIMIT 6", [(d,) for d in DESCENDING + [None]], ["d"]),
    ("SELECT d FROM days ORDER BY d NULLS FIRST LIMIT 2", [(None,), (None,)], ["d"]),
    ("SELECT id, d FROM days ORDER BY d DESC NULLS FIRST LIMIT 3", None, ["d"]),
    (
        "SELECT id, d FROM days ORDER BY d DESC, id",
        [(6, D(2024, 2, 29)), (3, D(2024, 1, 5)), (0, D(2024, 1, 3)), (4, D(1970, 1, 1)), (2, D(1969, 12, 31)), (1, None), (5, None)],
        ["d"],
    ),
]


def write_files(work):
    import pyarrow as pa
    import pyarrow.parquet as pq

    orders = os.path.join(work, "orders.csv")
    with open(orders, "w") as f:
        f.write(ORDERS_CSV)
    days = os.path.join(work, "days.parquet")
    table = pa.table({"id": pa.array(range(len(DAYS)), pa.int64()), "d": pa.array(DAYS, pa.date32())})
    pq.write_table(table, days)
    return orders, days


def as_date(v):
    """DuckDB answers some date_trunc calls as a TIMESTAMP at midnight; the
    rows here are dates."""
    if isinstance(v, datetime.datetime):
        assert v.time() == datetime.time(0), v
        return v.date()
    return v


def komira_rows(s, sql, date_columns):
    import pyarrow as pa

    t = s.sql(sql).to_arrow()
    for name in date_columns:
        assert t.schema.field(name).type == pa.date32(), (sql, t.schema)
    return [tuple(row[name] for name in t.schema.names) for row in t.to_pylist()]


def duckdb_rows(con, sql):
    return [tuple(as_date(v) for v in row) for row in con.execute(sql).fetchall()]


def check(s, con, sql, want, date_columns):
    got = komira_rows(s, sql, date_columns)
    assert got == want, (sql, got, want)
    oracle = duckdb_rows(con, sql)
    assert oracle == want, ("duckdb", sql, oracle, want)


# (program over the frames of orders.csv and days.parquet, the rows it must
# answer). DuckDB is not asked: these are the frame forms of the SQL above.
FRAMES = [
    (
        lambda orders, days: days[["d"]].sort_values("d"),
        [(d,) for d in ASCENDING + [None, None]],
    ),
    (
        lambda orders, days: days[["d"]].sort_values("d", ascending=False),
        [(d,) for d in DESCENDING + [None, None]],
    ),
    (
        lambda orders, days: days[["d"]].sort_values("d", na_position="first"),
        [(d,) for d in [None, None] + ASCENDING],
    ),
    (
        lambda orders, days: orders.sort_values("order_date", ascending=False).head(2)[["order_id", "order_date"]],
        [(6, D(2024, 2, 29)), (5, D(2024, 2, 7))],
    ),
    (
        lambda orders, days: orders.groupby("order_date").agg(n=("amount", "size")),
        [(D(2024, 1, 3), 1), (D(2024, 1, 15), 1), (D(2024, 1, 16), 1), (D(2024, 2, 5), 1), (D(2024, 2, 7), 1), (D(2024, 2, 29), 1)],
    ),
]


def frame_rows(frame):
    t = frame.materialize().to_arrow()
    return [tuple(row[name] for name in t.schema.names) for row in t.to_pylist()]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    # The library is loaded before pyarrow and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    import duckdb

    with tempfile.TemporaryDirectory() as work:
        orders, days = write_files(work)
        quoted = "'{}'".format(orders.replace("'", "''"))
        con = duckdb.connect()
        con.execute("CREATE VIEW orders AS SELECT * FROM read_csv({})".format(quoted))
        con.execute("CREATE VIEW days AS SELECT * FROM read_parquet('{}')".format(days.replace("'", "''")))
        with komira.Session() as s:
            s.register_csv("orders", orders)
            s.register_parquet("days", days)
            for sql, want, date_columns in CASES:
                if want is None:
                    # The two NULLs first, then the latest day: the NULL rows
                    # tie on the key, so their ids may come in either order.
                    got = komira_rows(s, sql, date_columns)
                    oracle = duckdb_rows(con, sql)
                    for rows in (got, oracle):
                        assert sorted(rows[:2]) == [(1, None), (5, None)], (sql, rows)
                        assert rows[2:] == [(6, D(2024, 2, 29))], (sql, rows)
                    continue
                check(s, con, sql, want, date_columns)
            orders_frame = komira.read_csv(orders, session=s)
            days_frame = komira.read_parquet(days, session=s)
            for i, (program, want) in enumerate(FRAMES):
                got = frame_rows(program(orders_frame, days_frame))
                assert got == want, ("frame", i, got, want)
            # read_csv in the query: the same file, the same answer.
            check(
                s,
                con,
                LATEST_TWO.format("read_csv({})".format(quoted)),
                [(6, D(2024, 2, 29)), (5, D(2024, 2, 7))],
                ["order_date"],
            )
    print("sql order by date: {} queries equal DuckDB's answer and {} frames theirs over libkomira {}".format(
        len(CASES) + 1, len(FRAMES), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
