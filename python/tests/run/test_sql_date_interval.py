"""A DATE column plus or minus an INTERVAL or an integer, through Session.sql on
the real libkomira, as DuckDB answers it (the expected values are worked out by
hand and checked against DuckDB). A CSV of five rows registers a `d` column with
a leap day, the last day of January in a leap and a common year, and a NULL:

- test_interval_forms_answer_a_timestamp_at_midnight: `d + INTERVAL '7' DAY`,
  `INTERVAL '1' WEEK + d`, `d - INTERVAL '7' DAY` and `date_add(d, INTERVAL '2'
  DAY)` answer timestamp[us] values, datetime.datetime at midnight, also for day
  units; a NULL date stays None;
- test_month_and_year_units_clamp_to_the_last_day_of_the_month: 2024-01-31 plus
  one month is 2024-02-29, 2023-01-31 plus one month is 2023-02-28, 2024-02-29
  minus one year is 2023-02-28, and a negative count moves back;
- test_integer_forms_answer_a_date: `d + 7`, `d - 7`, `7 + d` and `d + -3`
  answer date32 values, datetime.date, with NULL kept;
- test_a_filter_compares_a_column_with_a_shifted_column: `WHERE s > d +
  INTERVAL '7' DAY` keeps the rows whose later date is more than a week on, and
  a NULL date drops the row;
- test_a_column_valued_interval_is_refused_by_name: `INTERVAL (n) DAY` raises
  UnsupportedOperation naming the non-constant interval, and the session answers
  after.

The test is of the `run/` family (python/tests/BUCK): `sql_date_interval_test`
runs on the real libkomira on each supported minor, with pyarrow.

    test_sql_date_interval.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which
the rule passes, is not read).
"""

import datetime
import os
import sys
import tempfile

import pyarrow as pa

import komira
from komira import UnsupportedOperation
from komira import _native

D = datetime.date
T = datetime.datetime

CSV = (
    "id,d,s,n\n"
    "1,2024-01-31,2024-02-10,1\n"
    "2,2023-01-31,2023-02-01,2\n"
    "3,2024-02-29,2024-03-10,3\n"
    "4,2024-03-01,2024-03-01,4\n"
    "5,,2024-03-01,5\n"
)


def column(s, expr):
    """The Arrow table of `SELECT <expr> AS v FROM t ORDER BY id`."""
    return s.sql("SELECT {} AS v FROM t ORDER BY id".format(expr)).to_arrow()


def values(s, expr):
    return column(s, expr).column("v").to_pylist()


def with_session(lib_dir, body):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "t.csv")
        with open(path, "w") as f:
            f.write(CSV)
        with komira.Session() as s:
            s.register_csv("t", path)
            body(s)


def test_interval_forms_answer_a_timestamp_at_midnight(lib_dir):
    def body(s):
        week = column(s, "d + INTERVAL '7' DAY")
        assert week.schema.field("v").type == pa.timestamp("us"), week.schema
        assert week.column("v").to_pylist() == [
            T(2024, 2, 7), T(2023, 2, 7), T(2024, 3, 7), T(2024, 3, 8), None,
        ]
        assert values(s, "INTERVAL '1' WEEK + d") == [
            T(2024, 2, 7), T(2023, 2, 7), T(2024, 3, 7), T(2024, 3, 8), None,
        ]
        assert values(s, "d - INTERVAL '7' DAY") == [
            T(2024, 1, 24), T(2023, 1, 24), T(2024, 2, 22), T(2024, 2, 23), None,
        ]
        added = column(s, "date_add(d, INTERVAL '2' DAY)")
        assert added.schema.field("v").type == pa.timestamp("us"), added.schema
        assert added.column("v").to_pylist() == [
            T(2024, 2, 2), T(2023, 2, 2), T(2024, 3, 2), T(2024, 3, 3), None,
        ]

    with_session(lib_dir, body)


def test_month_and_year_units_clamp_to_the_last_day_of_the_month(lib_dir):
    def body(s):
        assert values(s, "d + INTERVAL '1' MONTH") == [
            T(2024, 2, 29), T(2023, 2, 28), T(2024, 3, 29), T(2024, 4, 1), None,
        ]
        assert values(s, "d - INTERVAL '1' YEAR") == [
            T(2023, 1, 31), T(2022, 1, 31), T(2023, 2, 28), T(2023, 3, 1), None,
        ]
        assert values(s, "d + INTERVAL '-1' MONTH") == [
            T(2023, 12, 31), T(2022, 12, 31), T(2024, 1, 29), T(2024, 2, 1), None,
        ]
        assert values(s, "d + INTERVAL '1' YEAR") == [
            T(2025, 1, 31), T(2024, 1, 31), T(2025, 2, 28), T(2025, 3, 1), None,
        ]

    with_session(lib_dir, body)


def test_integer_forms_answer_a_date(lib_dir):
    def body(s):
        plus = column(s, "d + 7")
        assert plus.schema.field("v").type == pa.date32(), plus.schema
        assert plus.column("v").to_pylist() == [
            D(2024, 2, 7), D(2023, 2, 7), D(2024, 3, 7), D(2024, 3, 8), None,
        ]
        assert values(s, "d - 7") == [
            D(2024, 1, 24), D(2023, 1, 24), D(2024, 2, 22), D(2024, 2, 23), None,
        ]
        assert values(s, "7 + d") == values(s, "d + 7")
        assert values(s, "d + -3") == [
            D(2024, 1, 28), D(2023, 1, 28), D(2024, 2, 26), D(2024, 2, 27), None,
        ]
        assert values(s, "d - 0") == [
            D(2024, 1, 31), D(2023, 1, 31), D(2024, 2, 29), D(2024, 3, 1), None,
        ]

    with_session(lib_dir, body)


def test_a_filter_compares_a_column_with_a_shifted_column(lib_dir):
    def body(s):
        rows = s.sql(
            "SELECT id FROM t WHERE s > d + INTERVAL '7' DAY ORDER BY id"
        ).to_arrow().to_pylist()
        assert rows == [{"id": 1}, {"id": 3}], rows
        rows = s.sql(
            "SELECT id FROM t WHERE s > d + 7 ORDER BY id"
        ).to_arrow().to_pylist()
        assert rows == [{"id": 1}, {"id": 3}], rows

    with_session(lib_dir, body)


def test_a_column_valued_interval_is_refused_by_name(lib_dir):
    def body(s):
        try:
            s.sql("SELECT d + INTERVAL (n) DAY AS v FROM t").to_arrow()
        except UnsupportedOperation as e:
            assert "non-constant" in str(e), str(e)
        else:
            raise AssertionError("a column-valued INTERVAL was accepted")
        assert values(s, "d + 7")[0] == D(2024, 2, 7)

    with_session(lib_dir, body)


TESTS = [
    test_interval_forms_answer_a_timestamp_at_midnight,
    test_month_and_year_units_clamp_to_the_last_day_of_the_month,
    test_integer_forms_answer_a_date,
    test_a_filter_compares_a_column_with_a_shifted_column,
    test_a_column_valued_interval_is_refused_by_name,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    for test in TESTS:
        test(lib_dir)
        print("ok", test.__name__)
    print("date interval: {} cases over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
