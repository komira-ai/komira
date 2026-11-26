"""The pandas-shaped DataFrame's later verbs held to DuckDB: each frame program
runs through komira's plan door (`komira_plan_stream`, no SQL), and the SQL that
means the pandas answer runs in DuckDB over the same Parquet file; the two
answers must be equal (`frame_verbs_duckdb_test`, CPython 3.13, the real
libkomira). `test_frame_duckdb.py` holds the verbs before these; the harness
below is a copy of its own, since a test file cannot import another.

- the file: 40 rows built in code, no randomness, row groups of 7. `k` int64
  with NULLs and duplicates; `v` float64 with NULLs and NaN (no infinity); `w`
  float32 with NULLs; `n` int32, unique, never NULL; `s` string with NULLs, an
  empty string, mixed case, non-ASCII text, leading and trailing spaces, a
  repeated substring ("banana") and digits ("a1b22"); `flag` bool with NULLs;
  `t` timestamp[us] with NULLs, a leap day, a year end, midnight and
  microseconds; `d` date32 with NULLs;
- fillna: a scalar over a projection of each column type (int64, int32, float64
  where NaN is filled as NULL is, float32, string, bool), a scalar over several
  numeric types, a dict, an empty dict, fillna keeping a sort and one that fills
  the sort key, a filter on a filled column;
- dropna: how="any" over the whole frame and over a subset, how="all" over two
  float columns (NaN counts as missing), a subset given as one name, dropna on a
  sorted frame, dropna then fillna;
- rename with a dict, with a callable, with a name the frame does not have
  (skipped), then a filter on the new name, on a sorted frame (a renamed sort
  key leaves a multiset), add_prefix and add_suffix; column names are compared;
- astype of the casts the engine runs: int32 to int64, int64 to float64, int32
  and int64 to string, int64 to int32, float32 to float64, pandas spellings and
  builtin types, a whole projection, no-op casts, a Series cast inside assign, a
  string of digits cast back to int64 and float64, a float of whole numbers cast
  to int64, astype on a sorted frame (keeping and casting the sort key);
- tail of a sorted frame: one key, two keys, mixed directions, NULLs first and
  last (the tail reaching the NULL rows), n of 0, n beyond the rows, a filter
  before the sort, a sort of a head; the answer is in the frame's order;
- concat: two filtered frames, reordered columns, three frames, one frame, a
  frame with itself, a sort of the concat, frames of two readers (a multiset);
- the spelling value_counts is refused for, groupby(column).size() sorted by
  size descending: an int, a string, a filtered frame's column; ordered by
  size, rows with the same size form a tie group;
- Series.str: lower, upper, len, startswith, endswith, contains (literal, regex,
  case=False), match, fullmatch, replace (literal, every occurrence; regex; regex
  ignoring case), slice (several), pad (left, right, a width shorter and longer
  than the values), extract(expand=False) over rows that match; each as a column
  and as a filter; a NULL in is a NULL out;
- Series.dt: year, quarter, month, day, hour, minute, second, microsecond,
  dayofweek and aliases, dayofyear, floor("D"), floor("h") on the timestamp;
  year, month, day and dayofweek on the date; a filter on a field;
- casts and string functions the engine does not run build their plan and are
  refused at materialize() with the engine's step (ENGINE_REFUSED);
- columns are equal by name and order; ints, strings, bools, dates and
  timestamps exactly; floats to a relative 1e-12 and NaN equal to NaN; NULL
  equals NULL; Arrow type names equal for every column;
- the comparator is itself checked on plain lists: it refuses answers that
  differ in one cell, in row order for an ordered case, in a column name, in a
  type, in a row count, and in a float beyond its tolerance; it accepts rows
  that only move within a tie group and NaN against NaN;
- every case runs even when an earlier one fails, and the test then fails
  naming each failing case and why.

    test_frame_verbs_duckdb.py --lib-dir <dir> --runtime-dir <dir>

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

ROWS = 40
FILE_COLUMNS = ("k", "v", "w", "n", "s", "flag", "t", "d")

STRINGS = [
    "alpha", "Beta", "", "été", "日本語", None, "  pad  ", "banana", "a1b22", "Été", "x", "banana split",
]
STAMPS = [
    datetime.datetime(2028, 2, 29, 12, 30, 45, 123456),
    datetime.datetime(2026, 12, 31, 23, 59, 59, 999999),
    datetime.datetime(2027, 1, 1, 0, 0, 0, 0),
    datetime.datetime(2028, 3, 1, 0, 0, 0, 1),
    datetime.datetime(2032, 2, 29, 6, 5, 4, 300000),
    datetime.datetime(2027, 7, 15, 13, 0, 0, 500),
    datetime.datetime(2099, 12, 31, 23, 59, 59, 0),
    datetime.datetime(2100, 1, 1, 0, 0, 1, 999999),
    datetime.datetime(2026, 11, 6, 18, 45, 30, 250000),
]
DATES = [
    datetime.date(2028, 2, 29),
    datetime.date(2026, 12, 31),
    datetime.date(2027, 1, 1),
    datetime.date(2032, 2, 29),
    datetime.date(2027, 7, 15),
    datetime.date(2100, 1, 1),
]


# ---- the data ----------------------------------------------------------------


def column_values():
    """The eight columns as Python lists.
    k is NULL at i % 7 == 3; v is NULL at i % 8 == 2 and NaN at i % 8 == 5; w is
    NULL at i % 6 == 1 (rows 13 and 37 are NaN in v and NULL in w); flag is NULL
    at i % 4 == 1; t is NULL at i % 7 == 6; d is NULL at i % 9 == 4."""
    out = {c: [] for c in FILE_COLUMNS}
    for i in range(ROWS):
        out["k"].append(None if i % 7 == 3 else (i * 5) % 11 - 4)
        if i % 8 == 2:
            out["v"].append(None)
        elif i % 8 == 5:
            out["v"].append(math.nan)
        else:
            out["v"].append(((i * 37) % 19 - 9) / 4)
        out["w"].append(None if i % 6 == 1 else ((i * 7) % 9 - 4) / 4)
        out["n"].append((i * 7) % 41 + 1)
        out["s"].append(STRINGS[i % len(STRINGS)])
        out["flag"].append(None if i % 4 == 1 else i % 3 == 0)
        out["t"].append(None if i % 7 == 6 else STAMPS[i % len(STAMPS)])
        out["d"].append(None if i % 9 == 4 else DATES[i % len(DATES)])
    return out


def write_data(path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    values = column_values()
    table = pa.table(
        {
            "k": pa.array(values["k"], pa.int64()),
            "v": pa.array(values["v"], pa.float64()),
            "w": pa.array(values["w"], pa.float32()),
            "n": pa.array(values["n"], pa.int32()),
            "s": pa.array(values["s"], pa.string()),
            "flag": pa.array(values["flag"], pa.bool_()),
            "t": pa.array(values["t"], pa.timestamp("us")),
            "d": pa.array(values["d"], pa.date32()),
        }
    )
    pq.write_table(table, path, row_group_size=7)
    return path


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
    if isinstance(x, bool):
        return (1, int(x))
    if isinstance(x, float):
        if math.isnan(x):
            return (4, 0)
        return (2, round(x, 9))
    if isinstance(x, int):
        return (2, x)
    return (3, x)


def row_key(row):
    return tuple(cell_key(x) for x in row)


def tie_groups(rows, positions):
    """Consecutive rows with the same values at `positions`, as (key, rows)."""
    groups = []
    for row in rows:
        key = tuple(row[p] for p in positions)
        if groups and row_equal(groups[-1][0], key):
            groups[-1][1].append(row)
        else:
            groups.append((key, [row]))
    return groups


def differences(got, want, order=None, skip_types=()):
    """None when the two answers are equal, else the first difference as text.
    `order` is None when the rows are a multiset, else the names of the sort
    keys: the rows are then in the order of those columns, and rows equal on
    all of them may be in any order among themselves."""
    (got_names, got_types, got_rows), (want_names, want_types, want_rows) = got, want
    if got_names != want_names:
        return "column names differ: {} != {}".format(got_names, want_names)
    for name, got_type, want_type in zip(got_names, got_types, want_types):
        if name not in skip_types and got_type != want_type:
            return "column {!r} has type {} but {} was expected".format(name, got_type, want_type)
    if len(got_rows) != len(want_rows):
        return "{} rows, expected {}".format(len(got_rows), len(want_rows))
    if order is None:
        return first_row_difference(sorted(got_rows, key=row_key), sorted(want_rows, key=row_key))
    positions = [want_names.index(name) for name in order]
    got_groups, want_groups = tie_groups(got_rows, positions), tie_groups(want_rows, positions)
    if len(got_groups) != len(want_groups):
        return "{} runs of equal {}, expected {}".format(len(got_groups), list(order), len(want_groups))
    for i, ((got_key, got_group), (want_key, want_group)) in enumerate(zip(got_groups, want_groups)):
        if not row_equal(got_key, want_key):
            return "rows are not in the order of {}: run {} has key {}, expected {}".format(
                list(order), i, got_key, want_key
            )
        found = first_row_difference(sorted(got_group, key=row_key), sorted(want_group, key=row_key))
        if found is not None:
            return "run {} of key {}: {}".format(i, want_key, found)
    return None


def first_row_difference(got_rows, want_rows):
    if len(got_rows) != len(want_rows):
        return "{} rows, expected {}".format(len(got_rows), len(want_rows))
    for i, (g, w) in enumerate(zip(got_rows, want_rows)):
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


Case = collections.namedtuple("Case", "name program sql order empty untyped", defaults=(None, False, ()))


def on(frame, step):
    return step(frame)


# The cases that failed, each with why: every case runs, and main() fails
# with the whole list at the end, so one run names every failing case.
FAILED = []


def run_cases(path, cases):
    con = duckdb_for(path)
    with komira.Session() as session:
        for case in cases:
            try:
                check_case(con, session, path, case)
            except (AssertionError, komira.KomiraError) as e:
                FAILED.append("{}: {}: {}".format(case.name, type(e).__name__, e))


def check_case(con, session, path, case):
    want = duckdb_answer(con, case.sql)
    assert bool(want[2]) != case.empty, "{}: DuckDB's answer has {} rows, not the {} the case expects".format(
        case.name, len(want[2]), "no" if case.empty else "some"
    )
    got = komira_answer(session, path, case.program)
    skip = set(case.untyped)
    found = differences(got, want, case.order, skip)
    assert found is None, "{}: komira's answer is not DuckDB's ({}); komira {}, DuckDB {}".format(
        case.name, found, got, want
    )


def asc(name, nulls="LAST"):
    return "{} ASC NULLS {}".format(name, nulls)


def desc(name, nulls="LAST"):
    return "{} DESC NULLS {}".format(name, nulls)


# ---- fillna ------------------------------------------------------------------
# pandas fills NULL and NaN alike: a float column's SQL is a CASE over isnan.


def fill_double(column, literal):
    return "CASE WHEN {c} IS NULL OR isnan({c}) THEN CAST({l} AS DOUBLE) ELSE {c} END".format(
        c=column, l=literal
    )


def fill_float(column, literal):
    return "CAST(COALESCE({c}, CAST({l} AS FLOAT)) AS FLOAT)".format(c=column, l=literal)


FILLS = [
    Case("fillna of an int64 column", lambda d: d[["k"]].fillna(-1), "SELECT COALESCE(k, -1) AS k FROM t"),
    Case("fillna of an int32 column that has no NULL", lambda d: d[["n"]].fillna(0), "SELECT COALESCE(n, 0) AS n FROM t"),
    Case(
        "fillna of a float64 column fills NULL and NaN",
        lambda d: d[["v"]].fillna(0.5),
        "SELECT {} AS v FROM t".format(fill_double("v", "0.5")),
    ),
    Case(
        "fillna of a float64 column with an int",
        lambda d: d[["v"]].fillna(2),
        "SELECT {} AS v FROM t".format(fill_double("v", "2")),
    ),
    Case(
        "fillna of a float32 column",
        lambda d: d[["w"]].fillna(1.5),
        "SELECT {} AS w FROM t".format(fill_float("w", "1.5")),
    ),
    Case("fillna of a string column", lambda d: d[["s"]].fillna("?"), "SELECT COALESCE(s, '?') AS s FROM t"),
    Case("fillna of a string column with an empty string", lambda d: d[["s"]].fillna(""), "SELECT COALESCE(s, '') AS s FROM t"),
    Case("fillna of a bool column", lambda d: d[["flag"]].fillna(False), "SELECT COALESCE(flag, false) AS flag FROM t"),
    Case(
        "fillna of numeric columns of four types with one scalar",
        lambda d: d[["k", "v", "w", "n"]].fillna(0),
        "SELECT COALESCE(k, 0) AS k, {} AS v, {} AS w, COALESCE(n, 0) AS n FROM t".format(
            fill_double("v", "0"), fill_float("w", "0")
        ),
    ),
    Case(
        "fillna with a dict over five types",
        lambda d: d.fillna({"k": -1, "v": 0.5, "w": 1.5, "s": "?", "flag": True}),
        "SELECT * REPLACE (COALESCE(k, -1) AS k, {} AS v, {} AS w, COALESCE(s, '?') AS s, "
        "COALESCE(flag, true) AS flag) FROM t".format(fill_double("v", "0.5"), fill_float("w", "1.5")),
    ),
    Case("fillna with a dict of one column", lambda d: d.fillna({"s": ""}), "SELECT * REPLACE (COALESCE(s, '') AS s) FROM t"),
    Case("fillna with an empty dict changes nothing", lambda d: d.fillna({}), "SELECT * FROM t"),
    Case(
        "fillna keeps the order of a sort it does not fill",
        lambda d: d.sort_values("n").fillna({"k": 0}),
        "SELECT * REPLACE (COALESCE(k, 0) AS k) FROM t ORDER BY n",
        ("n",),
    ),
    Case(
        "fillna of the sort key leaves a multiset",
        lambda d: d.sort_values("k").fillna({"k": 0}),
        "SELECT * REPLACE (COALESCE(k, 0) AS k) FROM t",
    ),
    Case(
        "a filter on a filled column sees the fill",
        lambda d: on(d.fillna({"k": 0}), lambda f: f[f["k"] == 0]),
        "SELECT * REPLACE (COALESCE(k, 0) AS k) FROM t WHERE COALESCE(k, 0) = 0",
    ),
]


# ---- dropna ------------------------------------------------------------------


def present(column, is_float=False):
    if is_float:
        return "({c} IS NOT NULL AND NOT isnan({c}))".format(c=column)
    return "{} IS NOT NULL".format(column)


ALL_PRESENT = " AND ".join(
    [
        present("k"),
        present("v", True),
        present("w", True),
        present("n"),
        present("s"),
        present("flag"),
        present("t"),
        present("d"),
    ]
)

DROPS = [
    Case("dropna of the whole frame", lambda d: d.dropna(), "SELECT * FROM t WHERE " + ALL_PRESENT),
    Case(
        "dropna how=any over a subset drops NULL and NaN",
        lambda d: d.dropna(subset=["k", "v"]),
        "SELECT * FROM t WHERE {} AND {}".format(present("k"), present("v", True)),
    ),
    Case(
        "dropna of a subset given as one name drops the NaN rows",
        lambda d: d.dropna(subset="v"),
        "SELECT * FROM t WHERE " + present("v", True),
    ),
    Case(
        "dropna how=all keeps a row with one value present",
        lambda d: d.dropna(how="all", subset=["v", "w"]),
        "SELECT * FROM t WHERE {} OR {}".format(present("v", True), present("w", True)),
    ),
    Case(
        "dropna with an empty subset changes nothing",
        lambda d: d.dropna(subset=[]),
        "SELECT * FROM t",
    ),
    Case(
        "dropna of a string column",
        lambda d: d.dropna(subset=["s"]),
        "SELECT * FROM t WHERE s IS NOT NULL",
    ),
    Case(
        "dropna of a timestamp and a date",
        lambda d: d.dropna(subset=["t", "d"]),
        "SELECT * FROM t WHERE t IS NOT NULL AND d IS NOT NULL",
    ),
    Case(
        "dropna keeps the order of a sorted frame",
        lambda d: d.sort_values("n").dropna(subset=["k", "v"]),
        "SELECT * FROM t WHERE {} AND {} ORDER BY n".format(present("k"), present("v", True)),
        ("n",),
    ),
    Case(
        "dropna of a two-key sort keeps its order",
        lambda d: d.sort_values(["k", "n"]).dropna(subset=["s"]),
        "SELECT * FROM t WHERE s IS NOT NULL ORDER BY {}, {}".format(asc("k"), asc("n")),
        ("k", "n"),
    ),
    Case(
        "dropna then fillna",
        lambda d: d.dropna(subset=["k"]).fillna({"v": 0.0}),
        "SELECT * REPLACE ({} AS v) FROM t WHERE k IS NOT NULL".format(fill_double("v", "0.0")),
    ),
    Case(
        "dropna of rows that all drop",
        lambda d: on(d[d["n"] > 1000], lambda f: f.dropna()),
        "SELECT * FROM t WHERE n > 1000",
        None,
        True,
    ),
]


# ---- rename, add_prefix, add_suffix ------------------------------------------

COLUMNS = ["k", "v", "w", "n", "s", "flag", "t", "d"]


def select_as(rename):
    return "SELECT " + ", ".join('{} AS "{}"'.format(c, rename(c)) for c in COLUMNS) + " FROM t"


RENAMES = [
    Case(
        "rename with a dict",
        lambda d: d.rename(columns={"k": "key", "s": "name"}),
        select_as(lambda c: {"k": "key", "s": "name"}.get(c, c)),
    ),
    Case(
        "rename with a callable",
        lambda d: d.rename(columns=str.upper),
        select_as(str.upper),
    ),
    Case(
        "rename skips a name the frame does not have",
        lambda d: d.rename(columns={"k": "key", "nope": "x"}),
        select_as(lambda c: {"k": "key"}.get(c, c)),
    ),
    Case(
        "rename with errors=raise of names that all exist",
        lambda d: d.rename(columns={"n": "num"}, errors="raise"),
        select_as(lambda c: {"n": "num"}.get(c, c)),
    ),
    Case(
        "rename with an empty dict changes nothing",
        lambda d: d.rename(columns={}),
        "SELECT * FROM t",
    ),
    Case(
        "a filter on the new name",
        lambda d: on(d.rename(columns={"k": "key"}), lambda f: f[f["key"] > 3]),
        select_as(lambda c: {"k": "key"}.get(c, c)) + ' WHERE k > 3',
    ),
    Case(
        "rename of a column that is not a sort key keeps the order",
        lambda d: d.sort_values("k").rename(columns={"n": "num"}),
        select_as(lambda c: {"n": "num"}.get(c, c)) + " ORDER BY k ASC NULLS LAST",
        ("k",),
    ),
    Case(
        "rename of the sort key leaves a multiset",
        lambda d: d.sort_values("k").rename(columns={"k": "key"}),
        select_as(lambda c: {"k": "key"}.get(c, c)),
    ),
    Case("add_prefix", lambda d: d.add_prefix("p_"), select_as(lambda c: "p_" + c)),
    Case("add_suffix", lambda d: d.add_suffix("_x"), select_as(lambda c: c + "_x")),
    Case(
        "add_prefix renames the sort key, so a sorted frame leaves a multiset",
        lambda d: d.sort_values("n").add_prefix("p_"),
        select_as(lambda c: "p_" + c),
    ),
]


# ---- astype ------------------------------------------------------------------
# The casts the engine runs: int32 and int64 to each other, to float64 and to
# string, float32 to float64, float of whole numbers to int64, string of digits
# to int64 and float64. The others are in ENGINE_REFUSED.

CASTS = [
    Case(
        "astype int32 to int64",
        lambda d: d.astype({"n": "int64"}),
        "SELECT * REPLACE (CAST(n AS BIGINT) AS n) FROM t",
    ),
    Case(
        "astype int64 to float64",
        lambda d: d.astype({"k": "float64"}),
        "SELECT * REPLACE (CAST(k AS DOUBLE) AS k) FROM t",
    ),
    Case(
        "astype int64 to string",
        lambda d: d.astype({"k": "string"}),
        "SELECT * REPLACE (CAST(k AS VARCHAR) AS k) FROM t",
    ),
    Case(
        "astype int32 to string",
        lambda d: d.astype({"n": "string"}),
        "SELECT * REPLACE (CAST(n AS VARCHAR) AS n) FROM t",
    ),
    Case(
        "astype int64 to int32",
        lambda d: d.astype({"k": "int32"}),
        "SELECT * REPLACE (CAST(k AS INTEGER) AS k) FROM t",
    ),
    Case(
        "astype float32 to float64",
        lambda d: d.astype({"w": "float64"}),
        "SELECT * REPLACE (CAST(w AS DOUBLE) AS w) FROM t",
    ),
    Case(
        "astype of two columns",
        lambda d: d.astype({"n": "float64", "k": "string"}),
        "SELECT * REPLACE (CAST(n AS DOUBLE) AS n, CAST(k AS VARCHAR) AS k) FROM t",
    ),
    Case(
        "astype with pandas spellings and builtin types",
        lambda d: d.astype({"n": "Int64", "k": float, "w": "Float64"}),
        "SELECT * REPLACE (CAST(n AS BIGINT) AS n, CAST(k AS DOUBLE) AS k, CAST(w AS DOUBLE) AS w) FROM t",
    ),
    Case(
        "astype to the builtin str",
        lambda d: d.astype({"n": str}),
        "SELECT * REPLACE (CAST(n AS VARCHAR) AS n) FROM t",
    ),
    Case(
        "astype of one dtype over a projection",
        lambda d: d[["k", "n"]].astype("float64"),
        "SELECT CAST(k AS DOUBLE) AS k, CAST(n AS DOUBLE) AS n FROM t",
    ),
    Case("astype to the type a column has changes nothing", lambda d: d.astype({"k": "int64"}), "SELECT * FROM t"),
    Case(
        "Series.astype inside assign",
        lambda d: d.assign(kf=d["k"].astype("float64"), nn=d["n"].astype("int64"), ns=d["n"].astype("string")),
        "SELECT *, CAST(k AS DOUBLE) AS kf, CAST(n AS BIGINT) AS nn, CAST(n AS VARCHAR) AS ns FROM t",
    ),
    Case(
        "a string of digits cast back to int64 and float64",
        lambda d: d.assign(a=d["n"].astype("string"), b=lambda f: f["a"].astype("int64"), c=lambda f: f["a"].astype("float64")),
        "SELECT *, CAST(n AS VARCHAR) AS a, CAST(CAST(n AS VARCHAR) AS BIGINT) AS b, "
        "CAST(CAST(n AS VARCHAR) AS DOUBLE) AS c FROM t",
    ),
    Case(
        "a float of whole numbers cast to int64",
        lambda d: d.assign(f=d["k"].astype("float64"), i=lambda g: g["f"].astype("int64")),
        "SELECT *, CAST(k AS DOUBLE) AS f, CAST(CAST(k AS DOUBLE) AS BIGINT) AS i FROM t",
    ),
    Case(
        "astype keeps the order of a sort it does not cast",
        lambda d: d.sort_values("n").astype({"k": "float64"}),
        "SELECT * REPLACE (CAST(k AS DOUBLE) AS k) FROM t ORDER BY n",
        ("n",),
    ),
    Case(
        "astype of the sort key leaves a multiset",
        lambda d: d.sort_values("k").astype({"k": "float64"}),
        "SELECT * REPLACE (CAST(k AS DOUBLE) AS k) FROM t",
    ),
    Case(
        "rename then astype the new name",
        lambda d: d.rename(columns={"n": "num"}).astype({"num": "float64"}),
        'SELECT k, v, w, CAST(n AS DOUBLE) AS "num", s, flag, t, d FROM t',
    ),
]


# ---- tail --------------------------------------------------------------------
# DuckDB's answer: the last n rows are the first n of the reversed order, put
# back in the frame's order. Every case sorts on a unique key (n, or n as the
# second key), so the cut never falls inside a tie.


def tail_sql(order, flipped, n, where=""):
    return "SELECT * FROM (SELECT * FROM t {w} ORDER BY {f} LIMIT {n}) ORDER BY {o}".format(
        w=where, f=flipped, n=n, o=order
    )


K_N = "k ASC NULLS LAST, n ASC NULLS LAST"
K_N_FLIPPED = "k DESC NULLS FIRST, n DESC NULLS FIRST"
K_N_FIRST = "k ASC NULLS FIRST, n ASC NULLS FIRST"
K_N_FIRST_FLIPPED = "k DESC NULLS LAST, n DESC NULLS LAST"

TAILS = [
    Case(
        "tail of a one-key sort",
        lambda d: d.sort_values("n").tail(4),
        tail_sql("n ASC", "n DESC", 4),
        ("n",),
    ),
    Case(
        "tail of a descending sort",
        lambda d: d.sort_values("n", ascending=False).tail(4),
        tail_sql("n DESC", "n ASC", 4),
        ("n",),
    ),
    Case(
        "tail of a two-key sort reaches the NULL keys placed last",
        lambda d: d.sort_values(["k", "n"]).tail(3),
        tail_sql(K_N, K_N_FLIPPED, 3),
        ("k", "n"),
    ),
    Case(
        "tail of a two-key sort that crosses from the NULL keys into the values",
        lambda d: d.sort_values(["k", "n"]).tail(9),
        tail_sql(K_N, K_N_FLIPPED, 9),
        ("k", "n"),
    ),
    Case(
        "tail of a two-key sort with NULLs first",
        lambda d: d.sort_values(["k", "n"], na_position="first").tail(5),
        tail_sql(K_N_FIRST, K_N_FIRST_FLIPPED, 5),
        ("k", "n"),
    ),
    Case(
        "tail of a two-key sort with NULLs first that reaches into the NULL rows",
        lambda d: d.sort_values(["k", "n"], na_position="first").tail(38),
        tail_sql(K_N_FIRST, K_N_FIRST_FLIPPED, 38),
        ("k", "n"),
    ),
    Case(
        "tail of a two-key sort of mixed directions",
        lambda d: d.sort_values(["k", "n"], ascending=[False, True]).tail(6),
        tail_sql(
            "k DESC NULLS LAST, n ASC NULLS LAST", "k ASC NULLS FIRST, n DESC NULLS FIRST", 6
        ),
        ("k", "n"),
    ),
    Case(
        "tail of a sort by a string and a unique key",
        lambda d: d.sort_values(["s", "n"], ascending=[False, False], na_position="first").tail(7),
        tail_sql(
            "s DESC NULLS FIRST, n DESC NULLS FIRST", "s ASC NULLS LAST, n ASC NULLS LAST", 7
        ),
        ("s", "n"),
    ),
    Case(
        "tail of a filtered, sorted frame",
        lambda d: d[d["k"] > 0].sort_values("n", ascending=False).tail(3),
        tail_sql("n DESC", "n ASC", 3, "WHERE k > 0"),
        ("n",),
    ),
    Case(
        "tail larger than the frame keeps every row in order",
        lambda d: d.sort_values("n").tail(100),
        "SELECT * FROM t ORDER BY n",
        ("n",),
    ),
    Case(
        "tail of the whole frame's size",
        lambda d: d.sort_values("n").tail(40),
        "SELECT * FROM t ORDER BY n",
        ("n",),
    ),
    Case(
        "tail of a sort after a head",
        lambda d: d.sort_values("n").head(15).sort_values(["k", "n"], ascending=False).tail(4),
        "SELECT * FROM (SELECT * FROM (SELECT * FROM t ORDER BY n LIMIT 15) ORDER BY {f} LIMIT 4) ORDER BY {o}".format(
            o="k DESC NULLS LAST, n DESC NULLS LAST", f="k ASC NULLS FIRST, n ASC NULLS FIRST"
        ),
        ("k", "n"),
    ),
    Case(
        "a column added after a tail keeps its order",
        lambda d: on(d.sort_values("n").tail(5), lambda f: f.assign(w2=f["n"] * 2)),
        "SELECT *, n * 2 AS w2 FROM ({}) ORDER BY n".format(tail_sql("n ASC", "n DESC", 5)),
        ("n",),
    ),
    Case(
        "tail of zero",
        lambda d: d.sort_values("n").tail(0),
        tail_sql("n ASC", "n DESC", 0),
        ("n",),
        True,
    ),
]


# ---- concat ------------------------------------------------------------------


def concat_of_filters(d):
    return komira.concat([d[d["k"] > 3], d[d["k"] < 0]])


def concat_with_reordered_columns(d):
    first = on(d[["k", "s"]], lambda f: f[f["k"] > 3])
    second = on(d[["s", "k"]], lambda f: f[f["k"] < 0])
    return komira.concat([first, second])


def concat_of_three(d):
    return komira.concat([d[d["k"] > 5], d[d["k"] < -2], d[d["n"] < 5]])


CONCATS = [
    Case(
        "concat of two filtered frames",
        concat_of_filters,
        "SELECT * FROM t WHERE k > 3 UNION ALL SELECT * FROM t WHERE k < 0",
    ),
    Case(
        "concat puts the columns of a reordered frame in the first frame's order",
        concat_with_reordered_columns,
        "SELECT k, s FROM t WHERE k > 3 UNION ALL SELECT k, s FROM t WHERE k < 0",
    ),
    Case(
        "concat of three frames, one row in two of them",
        concat_of_three,
        "SELECT * FROM t WHERE k > 5 UNION ALL SELECT * FROM t WHERE k < -2 UNION ALL SELECT * FROM t WHERE n < 5",
    ),
    Case("concat of one frame", lambda d: komira.concat([d[d["k"] > 3]]), "SELECT * FROM t WHERE k > 3"),
    Case(
        "concat of a frame with itself keeps every row twice",
        lambda d: komira.concat([d, d]),
        "SELECT * FROM t UNION ALL SELECT * FROM t",
    ),
    Case(
        "concat accepts ignore_index",
        lambda d: komira.concat([d[d["k"] > 3], d[d["k"] < 0]], ignore_index=True),
        "SELECT * FROM t WHERE k > 3 UNION ALL SELECT * FROM t WHERE k < 0",
    ),
    Case(
        "concat of frames with a computed column",
        lambda d: komira.concat([f.assign(x=f["k"] + 1) for f in (d[d["k"] > 3], d[d["k"] < 0])]),
        "SELECT *, k + 1 AS x FROM t WHERE k > 3 UNION ALL SELECT *, k + 1 AS x FROM t WHERE k < 0",
    ),
    Case(
        "a sort of a concat orders the rows of both frames",
        lambda d: komira.concat([d[d["k"] > 3], d[d["n"] < 10]]).sort_values("n"),
        "SELECT * FROM (SELECT * FROM t WHERE k > 3 UNION ALL SELECT * FROM t WHERE n < 10) ORDER BY n ASC",
        ("n",),
    ),
    Case(
        "a filter after a concat",
        lambda d: on(concat_of_filters(d), lambda f: f[f["n"] > 20]),
        "SELECT * FROM (SELECT * FROM t WHERE k > 3 UNION ALL SELECT * FROM t WHERE k < 0) WHERE n > 20",
    ),
]


# ---- the count per value that value_counts is refused for ---------------------
# value_counts is refused by name; the spelling its message gives is a groupby
# of the column, its size, sorted by size descending. Rows with one size may
# come out in any order, so each case is ordered by size alone.

COUNTS_BY_GROUP = [
    Case(
        "groupby size of an int column, sorted by size descending, drops the NULL key",
        lambda d: d.groupby("k").size().sort_values("size", ascending=False),
        'SELECT k, COUNT(*) AS "size" FROM t WHERE k IS NOT NULL GROUP BY k ORDER BY "size" DESC NULLS LAST',
        ("size",),
    ),
    Case(
        "groupby size of a string column, sorted by size descending",
        lambda d: d.groupby("s").size().sort_values("size", ascending=False),
        'SELECT s, COUNT(*) AS "size" FROM t WHERE s IS NOT NULL GROUP BY s ORDER BY "size" DESC NULLS LAST',
        ("size",),
    ),
    Case(
        "groupby size of a filtered frame, sorted by size descending",
        lambda d: d[d["n"] > 10].groupby("s").size().sort_values("size", ascending=False),
        'SELECT s, COUNT(*) AS "size" FROM t WHERE n > 10 AND s IS NOT NULL GROUP BY s '
        'ORDER BY "size" DESC NULLS LAST',
        ("size",),
    ),
]


# ---- Series.str --------------------------------------------------------------
# Each program reads n and s and adds r, so the answer holds the input beside
# the result. A NULL in s is a NULL in r. The SQL is pandas' meaning: pad never
# cuts a string, so it is a CASE over length.


def str_case(name, make, expr):
    def program(d):
        f = d[["n", "s"]]
        return f.assign(r=make(f["s"]))

    return Case(name, program, "SELECT n, s, {} AS r FROM t".format(expr))


def str_filter(name, pred, where):
    def program(d):
        f = d[["n", "s"]]
        return f[pred(f)]

    return Case(name, program, "SELECT n, s FROM t WHERE {}".format(where))


def padded(width, side, fill):
    return "CASE WHEN length(s) >= {w} THEN s ELSE {side}(s, {w}, '{f}') END".format(w=width, side=side, f=fill)


def extract_program(pattern, guard):
    def program(d):
        f = d[["n", "s"]]
        f = f[f["s"].str.contains(guard)]
        return f.assign(r=f["s"].str.extract(pattern, expand=False))

    return program


STRS = [
    str_case("str.lower", lambda s: s.str.lower(), "lower(s)"),
    str_case("str.upper", lambda s: s.str.upper(), "upper(s)"),
    str_case("str.len counts characters", lambda s: s.str.len(), "CAST(length(s) AS BIGINT)"),
    str_case("str.startswith", lambda s: s.str.startswith("al"), "starts_with(s, 'al')"),
    str_case("str.endswith", lambda s: s.str.endswith("a"), "ends_with(s, 'a')"),
    str_case("str.contains a literal", lambda s: s.str.contains("an", regex=False), "contains(s, 'an')"),
    str_case("str.contains a regex", lambda s: s.str.contains("an+a"), "regexp_matches(s, 'an+a')"),
    str_case("str.contains a regex of digits", lambda s: s.str.contains("[0-9]+"), "regexp_matches(s, '[0-9]+')"),
    str_case(
        "str.contains a regex ignoring case",
        lambda s: s.str.contains("ET", case=False),
        "regexp_matches(s, 'ET', 'i')",
    ),
    str_case("str.match anchors at the start", lambda s: s.str.match("ba"), "regexp_matches(s, '^(?:ba)')"),
    str_case(
        "str.match groups an alternation", lambda s: s.str.match("al|x"), "regexp_matches(s, '^(?:al|x)')"
    ),
    str_case("str.fullmatch", lambda s: s.str.fullmatch("[a-z]+"), "regexp_full_match(s, '[a-z]+')"),
    str_case(
        "str.replace a literal changes every occurrence",
        lambda s: s.str.replace("an", "AN", regex=False),
        "replace(s, 'an', 'AN')",
    ),
    str_case(
        "str.replace a literal of spaces",
        lambda s: s.str.replace("  ", "_", regex=False),
        "replace(s, '  ', '_')",
    ),
    str_case(
        "str.replace a regex",
        lambda s: s.str.replace("[0-9]+", "#", regex=True),
        "regexp_replace(s, '[0-9]+', '#', 'g')",
    ),
    str_case(
        "str.replace a regex ignoring case",
        lambda s: s.str.replace("A", "_", case=False, regex=True),
        "regexp_replace(s, 'A', '_', 'gi')",
    ),
    str_case("str.slice(1, 3)", lambda s: s.str.slice(1, 3), "substr(s, 2, 2)"),
    str_case("str.slice(2)", lambda s: s.str.slice(2), "substr(s, 3)"),
    str_case("str.slice(None, 2)", lambda s: s.str.slice(None, 2), "substr(s, 1, 2)"),
    str_case("str.slice with the stop before the start", lambda s: s.str.slice(3, 1), "substr(s, 4, 0)"),
    str_case("str.pad to a width longer than most values", lambda s: s.str.pad(10), padded(10, "lpad", " ")),
    str_case("str.pad to a width shorter than most values", lambda s: s.str.pad(2), padded(2, "lpad", " ")),
    str_case(
        "str.pad on the right with a fill character",
        lambda s: s.str.pad(8, side="right", fillchar="-"),
        padded(8, "rpad", "-"),
    ),
    str_case(
        "str.pad on the left with a fill character",
        lambda s: s.str.pad(6, fillchar="*"),
        padded(6, "lpad", "*"),
    ),
    str_case(
        "str.len of a lowered string",
        lambda s: s.str.lower().str.len(),
        "CAST(length(lower(s)) AS BIGINT)",
    ),
    str_case(
        "str.startswith of an uppered string",
        lambda s: s.str.upper().str.startswith("BA"),
        "starts_with(upper(s), 'BA')",
    ),
    Case(
        "str.extract of the digits of the rows that have some",
        extract_program("([0-9]+)", "[0-9]+"),
        "SELECT n, s, regexp_extract(s, '([0-9]+)', 1) AS r FROM t WHERE regexp_matches(s, '[0-9]+')",
    ),
    Case(
        "str.extract of a group over the rows that match",
        extract_program("(an+)", "an+"),
        "SELECT n, s, regexp_extract(s, '(an+)', 1) AS r FROM t WHERE regexp_matches(s, 'an+')",
    ),
    str_filter("str.startswith as a filter", lambda f: f["s"].str.startswith("b"), "starts_with(s, 'b')"),
    str_filter(
        "str.contains a regex as a filter",
        lambda f: f["s"].str.contains("an+a"),
        "regexp_matches(s, 'an+a')",
    ),
    str_filter(
        "str.contains a regex ignoring case as a filter",
        lambda f: f["s"].str.contains("BETA", case=False),
        "regexp_matches(s, 'BETA', 'i')",
    ),
    str_filter("str.match as a filter", lambda f: f["s"].str.match("a"), "regexp_matches(s, '^(?:a)')"),
    str_filter(
        "str.fullmatch as a filter", lambda f: f["s"].str.fullmatch("[a-z]+"), "regexp_full_match(s, '[a-z]+')"
    ),
    str_filter("a negated str.contains drops the NULL rows", lambda f: ~f["s"].str.contains("a", regex=False), "NOT contains(s, 'a')"),
    str_filter("str.upper compared to a literal", lambda f: f["s"].str.upper() == "ALPHA", "upper(s) = 'ALPHA'"),
    str_filter(
        "str.len and another column in one filter",
        lambda f: (f["s"].str.len() > 3) & (f["n"] > 5),
        "length(s) > 3 AND n > 5",
    ),
]


# ---- Series.dt ---------------------------------------------------------------


def dt_case(name, column, make, expr):
    def program(d):
        f = d[["n", column]]
        return f.assign(r=make(f[column]))[["n", "r"]]

    return Case(name, program, "SELECT n, {} AS r FROM t".format(expr))


def field(column, unit):
    return "CAST({}({}) AS BIGINT)".format(unit, column)


DTS = [
    dt_case("dt.year of a timestamp", "t", lambda s: s.dt.year, field("t", "year")),
    dt_case("dt.quarter of a timestamp", "t", lambda s: s.dt.quarter, field("t", "quarter")),
    dt_case("dt.month of a timestamp", "t", lambda s: s.dt.month, field("t", "month")),
    dt_case("dt.day of a timestamp", "t", lambda s: s.dt.day, field("t", "day")),
    dt_case("dt.hour of a timestamp", "t", lambda s: s.dt.hour, field("t", "hour")),
    dt_case("dt.minute of a timestamp", "t", lambda s: s.dt.minute, field("t", "minute")),
    dt_case("dt.second of a timestamp", "t", lambda s: s.dt.second, field("t", "second")),
    dt_case(
        "dt.microsecond of a timestamp is the part below the second",
        "t",
        lambda s: s.dt.microsecond,
        "CAST(microsecond(t) % 1000000 AS BIGINT)",
    ),
    dt_case(
        "dt.dayofweek counts Monday as 0", "t", lambda s: s.dt.dayofweek, "CAST(isodow(t) - 1 AS BIGINT)"
    ),
    dt_case("dt.weekday is dt.dayofweek", "t", lambda s: s.dt.weekday, "CAST(isodow(t) - 1 AS BIGINT)"),
    dt_case("dt.dayofyear of a timestamp", "t", lambda s: s.dt.dayofyear, field("t", "dayofyear")),
    dt_case("dt.day_of_year is dt.dayofyear", "t", lambda s: s.dt.day_of_year, field("t", "dayofyear")),
    dt_case(
        "dt.floor to the day",
        "t",
        lambda s: s.dt.floor("D"),
        "CAST(date_trunc('day', t) AS TIMESTAMP)",
    ),
    dt_case(
        "dt.floor to the hour",
        "t",
        lambda s: s.dt.floor("h"),
        "CAST(date_trunc('hour', t) AS TIMESTAMP)",
    ),
    dt_case("dt.year of a date", "d", lambda s: s.dt.year, field("d", "year")),
    dt_case("dt.month of a date", "d", lambda s: s.dt.month, field("d", "month")),
    dt_case("dt.day of a date", "d", lambda s: s.dt.day, field("d", "day")),
    dt_case("dt.dayofweek of a date", "d", lambda s: s.dt.dayofweek, "CAST(isodow(d) - 1 AS BIGINT)"),
    Case(
        "a filter on dt.year",
        lambda d: on(d[["n", "t"]], lambda f: f[f["t"].dt.year == 2028]),
        "SELECT n, t FROM t WHERE year(t) = 2028",
    ),
    Case(
        "a filter on dt.dayofweek of a date",
        lambda d: on(d[["n", "d"]], lambda f: f[f["d"].dt.dayofweek >= 5]),
        "SELECT n, d FROM t WHERE isodow(d) - 1 >= 5",
    ),
]

TYPES = [
    Case("a plain read has every column type", lambda d: d, "SELECT * FROM t"),
    Case(
        "the file's NaN rows pass through a filter on another column",
        lambda d: d[d["n"] > 30],
        "SELECT * FROM t WHERE n > 30",
    ),
]

# Programs whose plan the verb builds and the engine does not run: each is
# refused at materialize() with the engine's step, never answered otherwise.
# When the engine runs one, its check fails and the program moves to a case list.
#   - a cast to bool, from a bool to a string, from a date or timestamp to a
#     string, from a timestamp to a date, from a string to a date: the engine's
#     cast has no arm for those pairs;
#   - a regex over a computed string (the lowered Series): the engine's regex
#     operations take a column as their input, not an expression.
ENGINE_REFUSED = [
    ("a cast of an int to bool", lambda d: d.astype({"k": "bool"})),
    ("a cast of a bool to a string", lambda d: d.astype({"flag": "string"})),
    ("a cast of a timestamp to a string", lambda d: d.astype({"t": "string"})),
    ("a cast of a date to a string", lambda d: d.astype({"d": "string"})),
    ("a cast of a timestamp to a date", lambda d: d.astype({"t": "date32"})),
    ("a cast of a string to a date", lambda d: d.astype({"s": "date32"})),
    (
        "a regex replace over a lowered string",
        lambda d: on(d[["n", "s"]], lambda f: f.assign(r=f["s"].str.lower().str.replace("a", "b", regex=True))),
    ),
    (
        "a regex match over a lowered string",
        lambda d: on(d[["n", "s"]], lambda f: f.assign(r=f["s"].str.lower().str.contains("an+a"))),
    ),
]


# ---- the tests that run frames -----------------------------------------------


def test_the_types_of_the_file_read_back_as_duckdb_reads_them(path):
    run_cases(path, TYPES)


def test_fillna_equals_duckdb_coalesce(path):
    run_cases(path, FILLS)


def test_dropna_equals_duckdb_where_not_null_and_not_nan(path):
    run_cases(path, DROPS)


def test_rename_and_affixes_equal_duckdb_aliases(path):
    run_cases(path, RENAMES)


def test_astype_equals_duckdb_cast(path):
    run_cases(path, CASTS)


def test_tail_equals_the_last_rows_of_duckdb_order_by(path):
    run_cases(path, TAILS)


def test_concat_equals_duckdb_union_all(path):
    run_cases(path, CONCATS)


def test_groupby_size_sorted_descending_equals_duckdb_group_by_count(path):
    run_cases(path, COUNTS_BY_GROUP)


def test_str_methods_equal_duckdb_string_functions(path):
    run_cases(path, STRS)


def test_dt_fields_equal_duckdb_date_parts(path):
    run_cases(path, DTS)


def test_concat_of_frames_from_two_readers_equals_duckdb_union_all(path):
    con = duckdb_for(path)
    want = duckdb_answer(con, "SELECT * FROM t WHERE k > 3 UNION ALL SELECT * FROM t WHERE k < 0")
    with komira.Session() as session:
        first = komira.read_parquet(path, session=session)
        second = komira.read_parquet(path, session=session)
        frame = komira.concat([first[first["k"] > 3], second[second["k"] < 0]])
        got = answer_of(frame.materialize().to_arrow())
    found = differences(got, want)
    assert found is None, "frames of two readers: {}".format(found)


def test_casts_and_regexes_the_engine_does_not_run_are_refused_at_the_terminal(path):
    with komira.Session() as session:
        base = komira.read_parquet(path, session=session)
        for name, program in ENGINE_REFUSED:
            frame = program(base)
            try:
                frame.materialize().to_arrow()
            except komira.KomiraError as e:
                # The engine's refusal: it names the step of the query that refused.
                if e.step is None:
                    FAILED.append("{}: refused with no engine step: {}".format(name, e))
            else:
                FAILED.append("{}: the engine answered it; move it to the oracle cases".format(name))


def test_the_file_has_nulls_nan_and_the_strings_and_times_the_cases_need(path):
    values = column_values()
    k, v, w, n, s, flag, t, d = (values[c] for c in FILE_COLUMNS)
    assert len(k) == ROWS
    assert k.count(None) == 6 and len(set(x for x in k if x is not None)) < ROWS - 6
    assert None in v and any(isinstance(x, float) and math.isnan(x) for x in v)
    assert not any(isinstance(x, float) and math.isinf(x) for x in v)
    assert None in w and not any(isinstance(x, float) and math.isnan(x) for x in w)
    both = [i for i in range(ROWS) if w[i] is None and isinstance(v[i], float) and math.isnan(v[i])]
    assert both == [13, 37], both
    assert len(set(n)) == ROWS and 0 not in n and max(n) < 2**31
    assert None in s and "" in s and any(x is not None and not x.isascii() for x in s)
    assert any(x is not None and x != x.strip() for x in s)
    assert any(x is not None and "banana" in x for x in s) and "a1b22" in s
    assert None in flag and True in flag and False in flag
    assert None in t and None in d
    assert any(x is not None and x.month == 2 and x.day == 29 for x in t)
    assert any(x is not None and x.microsecond not in (0,) for x in t)
    assert any(x is not None and x.hour == 0 and x.minute == 0 for x in t)
    survivors = [i for i in range(ROWS) if all(values[c][i] is not None for c in FILE_COLUMNS)
                 and not (isinstance(v[i], float) and math.isnan(v[i]))]
    assert survivors, "dropna of the whole frame would drop every row"
    import pyarrow.parquet as pq

    table = pq.read_table(path)
    assert [str(x) for x in table.schema.types] == [
        "int64", "double", "float", "int32", "string", "bool", "timestamp[us]", "date32[day]",
    ], table.schema
    read = table.to_pydict()
    for c in FILE_COLUMNS:
        assert all(cell_equal(a, b) for a, b in zip(read[c], values[c])), c


# ---- the tests of the comparator, on plain lists -----------------------------

BASE = (["a", "b"], ["int64", "string"], [(1, "x"), (2, "y"), (3, "z")])


def with_rows(rows, names=None, types=None):
    return (names or BASE[0], types or BASE[1], rows)


def test_compare_accepts_equal_answers_and_moved_rows_of_a_multiset():
    assert differences(BASE, BASE) is None
    assert differences(with_rows([(3, "z"), (1, "x"), (2, "y")]), BASE) is None
    assert differences(BASE, BASE, order=("a",)) is None
    assert differences(with_rows([(1, None), (None, "q")]), with_rows([(None, "q"), (1, None)])) is None


def test_compare_accepts_rows_that_move_within_a_tie_group():
    tied = (["a", "b"], ["int64", "string"], [(1, "x"), (1, "y"), (2, "z")])
    moved = (["a", "b"], ["int64", "string"], [(1, "y"), (1, "x"), (2, "z")])
    assert differences(moved, tied, order=("a",)) is None


def test_compare_refuses_a_different_cell():
    other = with_rows([(1, "x"), (2, "y"), (3, "w")])
    assert differences(other, BASE) == "row 2 is (3, 'w'), expected (3, 'z')"
    assert differences(other, BASE, order=("a",)) == "run 2 of key (3,): row 0 is (3, 'w'), expected (3, 'z')"


def test_compare_refuses_a_null_where_a_value_is_expected():
    got = with_rows([(1, "x"), (2, None), (3, "z")])
    assert differences(got, BASE) == "row 1 is (2, None), expected (2, 'y')"
    assert differences(got, BASE, order=("a",)) == "run 1 of key (2,): row 0 is (2, None), expected (2, 'y')"
    assert differences(BASE, got) == "row 1 is (2, 'y'), expected (2, None)"


def test_compare_refuses_a_different_row_order_of_an_ordered_case():
    swapped = with_rows([(2, "y"), (1, "x"), (3, "z")])
    assert differences(swapped, BASE, order=("a",)) == (
        "rows are not in the order of ['a']: run 0 has key (2,), expected (1,)"
    )
    assert differences(swapped, BASE) is None, "a multiset case does not look at the order"


def test_compare_refuses_a_different_column_name():
    renamed = (["a", "c"], BASE[1], BASE[2])
    assert differences(renamed, BASE) == "column names differ: ['a', 'c'] != ['a', 'b']"
    reordered = (["b", "a"], ["string", "int64"], [("x", 1), ("y", 2), ("z", 3)])
    assert differences(reordered, BASE) == "column names differ: ['b', 'a'] != ['a', 'b']"


def test_compare_refuses_a_different_type_unless_the_column_is_skipped():
    retyped = (BASE[0], ["int32", "string"], BASE[2])
    assert differences(retyped, BASE) == "column 'a' has type int32 but int64 was expected"
    assert differences(retyped, BASE, skip_types=("a",)) is None
    assert differences(with_rows([(1.0, "x"), (2, "y"), (3, "z")]), BASE) is not None, "a float is not an int"
    assert differences(with_rows([(True, "x"), (2, "y"), (3, "z")]), BASE) is not None, "a bool is not an int"


def test_compare_refuses_a_different_number_of_rows():
    assert differences(with_rows(BASE[2][:2]), BASE) == "2 rows, expected 3"
    assert differences(with_rows(BASE[2][:2]), BASE, order=("a",)) == "2 rows, expected 3"
    assert differences(with_rows([]), BASE) == "0 rows, expected 3"


def test_compare_holds_floats_to_a_relative_tolerance_of_1e_12():
    want = (["x"], ["double"], [(1.0,), (None,), (1e300,)])
    near = (["x"], ["double"], [(1.0 + 1e-13,), (None,), (1e300 * (1 + 1e-13),)])
    far = (["x"], ["double"], [(1.0 + 1e-9,), (None,), (1e300,)])
    assert differences(near, want) is None
    assert differences(far, want) == "row 1 is (1.000000001,), expected (1.0,)"


def test_compare_equates_nan_with_nan_and_nothing_else():
    nan = float("nan")
    want = (["x", "y"], ["double", "int64"], [(nan, 1), (2.5, 2), (None, 3)])
    moved = (["x", "y"], ["double", "int64"], [(None, 3), (nan, 1), (2.5, 2)])
    assert differences(moved, want) is None
    assert differences(moved, want, order=("y",)) == (
        "rows are not in the order of ['y']: run 0 has key (3,), expected (1,)"
    )
    value = (["x", "y"], ["double", "int64"], [(0.0, 1), (2.5, 2), (None, 3)])
    assert differences(value, want) is not None, "a number is not NaN"
    null = (["x", "y"], ["double", "int64"], [(None, 1), (2.5, 2), (None, 3)])
    assert differences(null, want) is not None, "NULL is not NaN"
    assert differences(want, null) is not None, "NaN is not NULL"


# ---- main --------------------------------------------------------------------

WITH_FILE = [
    test_the_file_has_nulls_nan_and_the_strings_and_times_the_cases_need,
    test_the_types_of_the_file_read_back_as_duckdb_reads_them,
    test_fillna_equals_duckdb_coalesce,
    test_dropna_equals_duckdb_where_not_null_and_not_nan,
    test_rename_and_affixes_equal_duckdb_aliases,
    test_astype_equals_duckdb_cast,
    test_tail_equals_the_last_rows_of_duckdb_order_by,
    test_concat_equals_duckdb_union_all,
    test_concat_of_frames_from_two_readers_equals_duckdb_union_all,
    test_groupby_size_sorted_descending_equals_duckdb_group_by_count,
    test_str_methods_equal_duckdb_string_functions,
    test_dt_fields_equal_duckdb_date_parts,
    test_casts_and_regexes_the_engine_does_not_run_are_refused_at_the_terminal,
]

PURE = [
    test_compare_accepts_equal_answers_and_moved_rows_of_a_multiset,
    test_compare_accepts_rows_that_move_within_a_tie_group,
    test_compare_refuses_a_different_cell,
    test_compare_refuses_a_null_where_a_value_is_expected,
    test_compare_refuses_a_different_row_order_of_an_ordered_case,
    test_compare_refuses_a_different_column_name,
    test_compare_refuses_a_different_type_unless_the_column_is_skipped,
    test_compare_refuses_a_different_number_of_rows,
    test_compare_holds_floats_to_a_relative_tolerance_of_1e_12,
    test_compare_equates_nan_with_nan_and_nothing_else,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    for test in PURE:
        test()
    # The library is loaded before pyarrow and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    with tempfile.TemporaryDirectory() as work:
        path = write_data(os.path.join(work, "frame.parquet"))
        for test in WITH_FILE:
            test(path)
    assert not FAILED, "{} cases failed:\n".format(len(FAILED)) + "\n".join(FAILED)
    lists = (TYPES, FILLS, DROPS, RENAMES, CASTS, TAILS, CONCATS, COUNTS_BY_GROUP, STRS, DTS)
    print("frame verbs duckdb: {} cases".format(sum(len(c) for c in lists)))


if __name__ == "__main__":
    main(sys.argv[1:])
