"""Session.sql over generate_series and range in FROM, on the real libkomira,
read as pyarrow:

- `generate_series(1, 5)` is a BIGINT column named `generate_series` holding
  1 to 5, and `range(1, 5)` one named `range` holding 1 to 4;
- a DATE series by day is a `timestamp[us]` column (no time zone) of each
  midnight, and `AS t(d)` names it `d`;
- a step away from the bound and a NULL argument are no rows, with the
  column's type;
- filling gaps: a day series LEFT JOINed with the per-day count of a CSV
  (its `day` a DATE) gives every day, 0 where the CSV has none;
- a zero step raises BindError and a column as an argument
  UnsupportedOperation, each with the engine's message, and the session
  answers the next query after each.

    test_sql_generate_series.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import datetime
import os
import sys
import tempfile

import pyarrow as pa

import komira
from komira import BindError, UnsupportedOperation, _native

WEEK = "generate_series(DATE '2024-01-01', DATE '2024-01-07', INTERVAL '1' DAY)"


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def day(n):
    return datetime.datetime(2024, 1, n)


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))

    with tempfile.TemporaryDirectory() as scratch:
        events = os.path.join(scratch, "events.csv")
        with open(events, "w") as f:
            f.write("day,amount\n2024-01-02,5\n2024-01-02,7\n2024-01-03,2\n2024-01-06,9\n")

        with komira.Session() as s:
            s.register_csv("events", events)

            t = s.sql("SELECT * FROM generate_series(1, 5)").to_arrow()
            assert t.schema.names == ["generate_series"], t.schema
            assert t.schema.field(0).type == pa.int64(), t.schema
            assert t.column(0).to_pylist() == [1, 2, 3, 4, 5]

            t = s.sql("SELECT * FROM range(1, 5)").to_arrow()
            assert t.schema.names == ["range"], t.schema
            assert t.column(0).to_pylist() == [1, 2, 3, 4]

            t = s.sql("SELECT d FROM " + WEEK + " AS t(d)").to_arrow()
            assert t.schema.names == ["d"], t.schema
            assert t.schema.field("d").type == pa.timestamp("us"), t.schema
            assert t.column(0).to_pylist() == [day(n) for n in range(1, 8)]

            for empty in ("generate_series(5, 1)", "range(1, NULL)"):
                t = s.sql("SELECT * FROM " + empty).to_arrow()
                assert t.num_rows == 0, empty
                assert t.schema.field(0).type == pa.int64(), (empty, t.schema)

            t = s.sql(
                "SELECT t.d, COALESCE(c.n, 0) AS n FROM " + WEEK + " AS t(d)"
                " LEFT JOIN (SELECT day, count(*) AS n FROM events GROUP BY day) AS c"
                " ON c.day = t.d ORDER BY t.d"
            ).to_arrow()
            assert t.to_pylist() == [
                {"d": day(n), "n": count} for n, count in zip(range(1, 8), [0, 2, 1, 0, 0, 1, 0])
            ], t.to_pylist()

            e = raised(lambda: s.sql("SELECT * FROM generate_series(1, 5, 0)"))
            assert type(e) is BindError, repr(e)
            assert "interval cannot be 0!" in str(e), str(e)
            assert s.sql("SELECT * FROM range(2)").to_arrow().column(0).to_pylist() == [0, 1]

            e = raised(lambda: s.sql("SELECT * FROM generate_series(1, amount)"))
            assert type(e) is UnsupportedOperation, repr(e)
            assert "column `amount`" in str(e), str(e)
            assert s.sql("SELECT * FROM range(2)").to_arrow().column(0).to_pylist() == [0, 1]

    print("sql_generate_series: libkomira {} serves generate_series and range in FROM".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
