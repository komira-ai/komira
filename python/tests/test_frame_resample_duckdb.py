"""`DataFrame.resample(rule, on=column)` held to DuckDB and to pandas: each
frame program runs through komira's plan door (`komira_plan_stream`, no SQL),
and the SQL that means the pandas answer runs in DuckDB over the same Parquet
file; the two answers must be equal. The pinned pandas resamples the same
file too, and its non-empty buckets must be komira's
(`frame_resample_duckdb_test`, CPython 3.13, the real libkomira). The harness
below is a copy of the one in `duckdb/test_frame_verbs_duckdb.py`, since a
test file cannot import another.

- the file: 26 rows built in code. `n` int32, unique; `v` float64 with NULLs,
  one day's rows all NULL; `d` date32 and `t` timestamp[us], each with NULLs,
  at the edges of the buckets: a Sunday and the Monday after it, the last day
  of a month and the first of the next, a week that spans a year end, the end
  of February in a common and in a leap year; `t` also at the last
  microsecond of a Sunday and of a month and at the midnight after each;
- the SQL of each rule is DuckDB's `date_trunc` and the label pandas gives
  the bucket: `D` the day, `W` and `W-SUN` `date_trunc('week', x) + 6 days`
  (the Sunday that ends the Monday-to-Sunday week), `MS` the first day of the
  month, `ME` and `M` `date_trunc('month', x) + 1 month - 1 day`; the rows
  with no date are filtered out, as pandas leaves them out;
- every rule over the date and over the timestamp, by `sum` (a bucket whose
  values are all missing sums to 0, pandas' `min_count=0`), and by `size`,
  `mean`, `min` and a named `agg`;
- pandas' own `resample(rule, on=column)` of the file (`ME` for `M`, which
  pandas 3 spells so), its `sum` and `size` of each bucket that has rows,
  equal to komira's, label by label;
- each row's bucket against a model of pandas' rules written here in Python:
  a Sunday is the label of its own week, and the Monday before it is in that
  week too, where DuckDB's `date_trunc('week', ...)` names the week by that
  Monday;
- columns are equal by name and order; dates and timestamps exactly; floats
  to a relative 1e-12; NULL equals NULL; Arrow type names equal; rows as a
  multiset, since the answer has no row order;
- the comparator is itself checked on plain lists: it refuses answers that
  differ in one cell, in a column name, in a type and in a row count;
- every case runs even when an earlier one fails, and the test then fails
  naming each failing case and why.

    test_frame_resample_duckdb.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which the
rule passes, is not read).
"""

import collections
import datetime
import math
import os
import sys
import tempfile

import komira
from komira import _native

FILE_COLUMNS = ("n", "v", "d", "t")

DATES = [
    datetime.date(2026, 10, 1),  # a Thursday, the first of a month
    datetime.date(2026, 10, 4),  # a Sunday
    datetime.date(2026, 10, 5),  # the Monday after it
    datetime.date(2026, 10, 31),  # a Saturday, the last of a month
    datetime.date(2026, 11, 1),  # a Sunday, the first of a month
    datetime.date(2026, 11, 2),  # a Monday
    datetime.date(2026, 12, 31),  # a Thursday, the year's last day
    datetime.date(2027, 1, 3),  # the Sunday ending the week that spans the year end
    datetime.date(2027, 1, 4),  # the Monday after it
    datetime.date(2027, 2, 28),  # a Sunday, the end of a common February
    datetime.date(2028, 2, 29),  # a Tuesday, the end of a leap February
    datetime.date(2028, 3, 1),
    None,
]
STAMPS = [
    datetime.datetime(2026, 11, 1, 23, 59, 59, 999999),  # the last microsecond of a Sunday
    datetime.datetime(2026, 11, 2, 0, 0, 0),  # the midnight of the Monday after
    datetime.datetime(2026, 10, 31, 23, 59, 59, 999999),  # the last microsecond of a month
    datetime.datetime(2026, 11, 1, 0, 0, 0),  # the midnight that starts the next
    datetime.datetime(2027, 1, 3, 12, 0, 0),
    datetime.datetime(2026, 12, 31, 23, 59, 59),
    datetime.datetime(2028, 2, 29, 6, 30, 0, 250000),
    datetime.datetime(2027, 2, 28, 23, 59, 59, 999999),
    None,
]
ROWS = 2 * len(DATES)
# The rows of this date have no value of v: its bucket's sum is 0.
ALL_MISSING = datetime.date(2028, 3, 1)


# ---- the data ----------------------------------------------------------------


def column_values():
    """The four columns as Python lists: `d` runs through DATES twice and `t`
    through STAMPS; v is NULL at i % 5 == 3 and on the rows of ALL_MISSING."""
    out = {c: [] for c in FILE_COLUMNS}
    for i in range(ROWS):
        d = DATES[i % len(DATES)]
        out["n"].append(i + 1)
        out["v"].append(None if i % 5 == 3 or d == ALL_MISSING else ((i * 7) % 11 - 3) / 4)
        out["d"].append(d)
        out["t"].append(STAMPS[i % len(STAMPS)])
    return out


def write_data(path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    values = column_values()
    table = pa.table(
        {
            "n": pa.array(values["n"], pa.int32()),
            "v": pa.array(values["v"], pa.float64()),
            "d": pa.array(values["d"], pa.date32()),
            "t": pa.array(values["t"], pa.timestamp("us")),
        }
    )
    pq.write_table(table, path, row_group_size=7)
    return path


# ---- pandas' labels, as its documentation states them ------------------------


def pandas_label(rule, value):
    """The label pandas' resample gives `value` under `rule`: the start of its
    day (`D`) or month (`MS`), the Sunday that ends its Monday-to-Sunday week
    (`W`, `W-SUN`), the last day of its month (`ME`, `M`); a timestamp's label
    is that day's midnight."""
    day = value.date() if isinstance(value, datetime.datetime) else value
    if rule == "D":
        out = day
    elif rule in ("W", "W-SUN"):
        out = day + datetime.timedelta(days=6 - day.weekday())
    elif rule == "MS":
        out = day.replace(day=1)
    else:
        following = (day.replace(day=28) + datetime.timedelta(days=4)).replace(day=1)
        out = following - datetime.timedelta(days=1)
    if isinstance(value, datetime.datetime):
        return datetime.datetime.combine(out, datetime.time())
    return out


# ---- the comparator ----------------------------------------------------------
# An answer is (column names, Arrow type names, rows as tuples).


def normalize_type(arrow_type):
    name = str(arrow_type)
    return "string" if name == "large_string" else name


def answer_of(table):
    names = list(table.column_names)
    types = [normalize_type(t) for t in table.schema.types]
    columns = [c.to_pylist() for c in table.columns]
    return names, types, list(zip(*columns))


def cell_equal(a, b):
    if a is None or b is None:
        return a is None and b is None
    if isinstance(a, float) or isinstance(b, float):
        if not (isinstance(a, float) and isinstance(b, float)):
            return False
        if math.isnan(a) or math.isnan(b):
            return math.isnan(a) and math.isnan(b)
        return math.isclose(a, b, rel_tol=1e-12, abs_tol=0.0)
    return type(a) is type(b) and a == b


def row_equal(a, b):
    return len(a) == len(b) and all(cell_equal(x, y) for x, y in zip(a, b))


def cell_key(x):
    if x is None:
        return (0, 0)
    if isinstance(x, float):
        if math.isnan(x):
            return (4, 0)
        return (2, round(x, 9))
    if isinstance(x, int):
        return (2, x)
    return (3, x)


def row_key(row):
    return tuple(cell_key(x) for x in row)


def differences(got, want):
    """None when the two answers are equal as multisets of rows, else the
    first difference as text."""
    (got_names, got_types, got_rows), (want_names, want_types, want_rows) = got, want
    if got_names != want_names:
        return "column names differ: {} != {}".format(got_names, want_names)
    for name, got_type, want_type in zip(got_names, got_types, want_types):
        if got_type != want_type:
            return "column {!r} has type {} but {} was expected".format(name, got_type, want_type)
    if len(got_rows) != len(want_rows):
        return "{} rows, expected {}".format(len(got_rows), len(want_rows))
    for i, (g, w) in enumerate(zip(sorted(got_rows, key=row_key), sorted(want_rows, key=row_key))):
        if not row_equal(g, w):
            return "row {} is {}, expected {}".format(i, g, w)
    return None


# ---- the two sides -----------------------------------------------------------


def komira_answer(session, path, program):
    frame = komira.read_parquet(path, session=session)
    return answer_of(program(frame).materialize().to_arrow())


def duckdb_answer(con, sql):
    cursor = con.execute(sql)
    fetch = getattr(cursor, "fetch_arrow_table", None)
    table = fetch() if fetch is not None else cursor.arrow()
    if hasattr(table, "read_all"):
        table = table.read_all()
    return answer_of(table)


def duckdb_for(path):
    import duckdb

    con = duckdb.connect()
    con.execute("CREATE VIEW t AS SELECT * FROM read_parquet('{}')".format(path.replace("'", "''")))
    return con


Case = collections.namedtuple("Case", "name program sql")

# The cases that failed, each with why: every case runs, and main() fails
# with the whole list at the end, so one run names every failing case.
FAILED = []


def run_cases(path, cases):
    con = duckdb_for(path)
    with komira.Session() as session:
        for case in cases:
            try:
                want = duckdb_answer(con, case.sql)
                assert want[2], "{}: DuckDB's answer has no rows".format(case.name)
                got = komira_answer(session, path, case.program)
                found = differences(got, want)
                assert found is None, "komira's answer is not DuckDB's ({}); komira {}, DuckDB {}".format(
                    found, got, want
                )
            except (AssertionError, komira.KomiraError) as e:
                FAILED.append("{}: {}: {}".format(case.name, type(e).__name__, e))


# ---- the cases ---------------------------------------------------------------

# DuckDB's date_trunc of a date is a timestamp: each label is cast back to the
# column's own type, the type komira keeps.
SQL_TYPE = {"d": "DATE", "t": "TIMESTAMP"}
LABEL_SQL = {
    "D": "date_trunc('day', {c})",
    "W": "date_trunc('week', {c}) + INTERVAL 6 DAY",
    "W-SUN": "date_trunc('week', {c}) + INTERVAL 6 DAY",
    "MS": "date_trunc('month', {c})",
    "ME": "date_trunc('month', {c}) + INTERVAL 1 MONTH - INTERVAL 1 DAY",
    "M": "date_trunc('month', {c}) + INTERVAL 1 MONTH - INTERVAL 1 DAY",
}
RULES = tuple(LABEL_SQL)


def bucketed(rule, column, aggregates):
    """DuckDB's answer of a resample: the label of each dated row, grouped."""
    label = "CAST({} AS {})".format(LABEL_SQL[rule].format(c=column), SQL_TYPE[column])
    return (
        "SELECT b AS {c}, {aggs} FROM (SELECT {label} AS b, n, v FROM t WHERE {c} IS NOT NULL) AS x "
        "GROUP BY b".format(c=column, aggs=aggregates, label=label)
    )


SUM_SQL = "COALESCE(sum(v), CAST(0 AS DOUBLE)) AS v"


def sum_case(rule, column):
    return Case(
        "resample({!r}, on={!r}).sum()".format(rule, column),
        lambda f: f.resample(rule, on=column)["v"].sum(),
        bucketed(rule, column, SUM_SQL),
    )


SUMS = [sum_case(rule, column) for column in ("d", "t") for rule in RULES]

REDUCTIONS = [
    Case(
        "resample('W', on='d').size() counts the dated rows of each week",
        lambda f: f.resample("W", on="d").size(),
        bucketed("W", "d", "count(*) AS size"),
    ),
    Case(
        "resample('ME', on='t').size() counts the stamped rows of each month",
        lambda f: f.resample("ME", on="t").size(),
        bucketed("ME", "t", "count(*) AS size"),
    ),
    Case(
        "resample('MS', on='d').mean() is missing for a bucket with no values",
        lambda f: f[["d", "v"]].resample("MS", on="d").mean(),
        bucketed("MS", "d", "avg(v) AS v"),
    ),
    Case(
        "resample('D', on='d').min() of every other column",
        lambda f: f.resample("D", on="d")[["n", "v"]].min(),
        bucketed("D", "d", "min(n) AS n, min(v) AS v"),
    ),
    Case(
        "resample('W-SUN', on='t').agg(...) of named outputs",
        lambda f: f.resample("W-SUN", on="t").agg(nrows=("n", "size"), hi=("v", "max"), k=("v", "count")),
        bucketed("W-SUN", "t", "count(*) AS nrows, max(v) AS hi, count(v) AS k"),
    ),
]


# ---- the tests ---------------------------------------------------------------


def test_every_rule_summed_over_a_date_and_a_timestamp_equals_duckdb(path):
    run_cases(path, SUMS)


def test_the_other_reductions_of_a_resample_equal_duckdb(path):
    run_cases(path, REDUCTIONS)


def test_each_rows_bucket_is_the_label_pandas_documents(path):
    """Row by row: each row's bucket, kept beside its `n` by a min over the
    bucket of the one row, is pandas' label of its date. A Sunday is the label
    of its own week, and the Monday before it is in that week too, where
    DuckDB's date_trunc('week', ...) names the week by that Monday."""
    values = column_values()
    with komira.Session() as session:
        frame = komira.read_parquet(path, session=session)
        for column in ("d", "t"):
            for rule in RULES:
                got = frame.resample(rule, on=column).agg(lo=("n", "min"), hi=("n", "max"), rows=("n", "size"))
                rows = got.materialize().to_arrow().to_pylist()
                want = collections.defaultdict(list)
                for n, value in zip(values["n"], values[column]):
                    if value is not None:
                        want[pandas_label(rule, value)].append(n)
                found = {r[column]: (r["lo"], r["hi"], r["rows"]) for r in rows}
                expected = {k: (min(ns), max(ns), len(ns)) for k, ns in want.items()}
                if found != expected:
                    FAILED.append(
                        "pandas' labels of {!r} over {!r}: komira {}, pandas {}".format(rule, column, found, expected)
                    )
    sunday, monday = datetime.date(2026, 11, 1), datetime.date(2026, 10, 26)
    assert pandas_label("W", sunday) == sunday
    assert pandas_label("W", monday) == sunday
    assert pandas_label("W", sunday + datetime.timedelta(days=1)) == sunday + datetime.timedelta(days=7)
    con = duckdb_for(path)
    trunc = con.execute("SELECT CAST(date_trunc('week', DATE '2026-11-01') AS DATE)").fetchone()[0]
    assert trunc == monday, trunc
    assert pandas_label("ME", datetime.date(2028, 2, 3)) == datetime.date(2028, 2, 29)
    assert pandas_label("ME", datetime.date(2027, 2, 3)) == datetime.date(2027, 2, 28)
    assert pandas_label("ME", datetime.date(2026, 12, 9)) == datetime.date(2026, 12, 31)
    end = datetime.datetime(2026, 11, 1, 23, 59, 59, 999999)
    assert pandas_label("W", end) == datetime.datetime(2026, 11, 1)
    assert pandas_label("MS", end) == datetime.datetime(2026, 11, 1)


def pandas_buckets(path, rule, column):
    """pandas' resample of the file: {label: (sum of v, rows)} of each bucket
    that has rows, the label as the column's own Python type."""
    import pandas as pd

    frame = pd.read_parquet(path)
    frame[column] = pd.to_datetime(frame[column])
    resampled = frame.resample("ME" if rule == "M" else rule, on=column)
    sums, sizes = resampled["v"].sum(), resampled["n"].size()
    out = {}
    for label, size in sizes.items():
        if size:
            key = label.date() if column == "d" else label.to_pydatetime()
            out[key] = (float(sums[label]), int(size))
    return out


def test_each_rule_equals_pandas_resample_of_the_file(path):
    with komira.Session() as session:
        frame = komira.read_parquet(path, session=session)
        for column in ("d", "t"):
            for rule in RULES:
                want = pandas_buckets(path, rule, column)
                got = frame.resample(rule, on=column).agg(v=("v", "sum"), size=("n", "size"))
                rows = got.materialize().to_arrow().to_pylist()
                found = {r[column]: (r["v"], r["size"]) for r in rows}
                same = found.keys() == want.keys() and all(
                    math.isclose(found[k][0], want[k][0], rel_tol=1e-12, abs_tol=1e-12) and found[k][1] == want[k][1]
                    for k in want
                )
                if not same:
                    FAILED.append(
                        "pandas' resample({!r}, on={!r}): komira {}, pandas {}".format(rule, column, found, want)
                    )


def test_the_file_has_the_edges_the_cases_need(path):
    values = column_values()
    d, t, v = values["d"], values["t"], values["v"]
    assert len(d) == ROWS and None in d and None in t and None in v
    dated = [x for x in d if x is not None]
    assert any(x.weekday() == 6 for x in dated) and any(x.weekday() == 0 for x in dated)
    assert any(x.day == 1 for x in dated) and any((x + datetime.timedelta(days=1)).day == 1 for x in dated)
    assert datetime.date(2028, 2, 29) in dated and datetime.date(2027, 2, 28) in dated
    assert all(v[i] is None for i in range(ROWS) if d[i] == ALL_MISSING)
    stamped = [x for x in t if x is not None]
    assert any(x.weekday() == 6 and x.hour == 23 and x.microsecond == 999999 for x in stamped)
    assert any(x.weekday() == 0 and x.hour == 0 and x.minute == 0 for x in stamped)
    import pyarrow.parquet as pq

    table = pq.read_table(path)
    assert [str(x) for x in table.schema.types] == ["int32", "double", "date32[day]", "timestamp[us]"], table.schema
    read = table.to_pydict()
    for c in FILE_COLUMNS:
        assert all(cell_equal(a, b) for a, b in zip(read[c], values[c])), c


# ---- the tests of the comparator, on plain lists -----------------------------

BASE = (["a", "b"], ["int64", "date32[day]"], [(1, datetime.date(2026, 11, 1)), (2, None)])


def test_compare_accepts_equal_answers_in_any_row_order():
    assert differences(BASE, BASE) is None
    assert differences((BASE[0], BASE[1], list(reversed(BASE[2]))), BASE) is None


def test_compare_refuses_a_different_cell_name_type_or_row_count():
    other = (BASE[0], BASE[1], [(1, datetime.date(2026, 10, 26)), (2, None)])
    assert differences(other, BASE) == (
        "row 0 is (1, datetime.date(2026, 10, 26)), expected (1, datetime.date(2026, 11, 1))"
    )
    assert differences((["a", "c"], BASE[1], BASE[2]), BASE) == "column names differ: ['a', 'c'] != ['a', 'b']"
    retyped = (BASE[0], ["int64", "timestamp[us]"], BASE[2])
    assert differences(retyped, BASE) == "column 'b' has type timestamp[us] but date32[day] was expected"
    assert differences((BASE[0], BASE[1], BASE[2][:1]), BASE) == "1 rows, expected 2"


def test_the_pandas_model_labels_a_week_by_its_sunday_and_a_month_by_its_ends():
    for day in range(26, 32 + 1):
        value = datetime.date(2026, 10, 1) + datetime.timedelta(days=day - 1)
        assert pandas_label("W", value).weekday() == 6, value
        assert 0 <= (pandas_label("W", value) - value).days <= 6, value
    assert pandas_label("D", datetime.datetime(2026, 11, 1, 23, 59)) == datetime.datetime(2026, 11, 1)
    assert pandas_label("M", datetime.date(2026, 11, 30)) == datetime.date(2026, 11, 30)
    assert pandas_label("MS", datetime.date(2026, 11, 30)) == datetime.date(2026, 11, 1)


# ---- main --------------------------------------------------------------------

WITH_FILE = [
    test_the_file_has_the_edges_the_cases_need,
    test_every_rule_summed_over_a_date_and_a_timestamp_equals_duckdb,
    test_the_other_reductions_of_a_resample_equal_duckdb,
    test_each_rows_bucket_is_the_label_pandas_documents,
    test_each_rule_equals_pandas_resample_of_the_file,
]
PURE = [
    test_compare_accepts_equal_answers_in_any_row_order,
    test_compare_refuses_a_different_cell_name_type_or_row_count,
    test_the_pandas_model_labels_a_week_by_its_sunday_and_a_month_by_its_ends,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    for test in PURE:
        test()
    # The library is loaded before pyarrow, pandas and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    with tempfile.TemporaryDirectory() as work:
        path = write_data(os.path.join(work, "resample.parquet"))
        for test in WITH_FILE:
            test(path)
    assert not FAILED, "{} cases failed:\n".format(len(FAILED)) + "\n".join(FAILED)
    print("frame resample duckdb: {} cases".format(len(SUMS) + len(REDUCTIONS)))


if __name__ == "__main__":
    main(sys.argv[1:])
