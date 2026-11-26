"""The pandas-shaped DataFrame held to DuckDB: each frame program runs through
komira's plan door (`komira_plan_stream`, no SQL), and the SQL that means the
same thing runs in DuckDB over the same Parquet file; the two answers must be
equal (`frame_duckdb_test`, CPython 3.13, the real libkomira).

- the file: 40 rows built in code, no randomness. `k` int64 with NULLs,
  negatives, duplicates and six outliers that make a top-3 unique; `v` float64
  with NULLs, negatives and zero in quarters (exact in binary); `s` string with
  NULLs, an empty string and non-ASCII text; `flag` bool with NULLs; `n` int32,
  unique, never NULL and never zero. There is no NaN: pandas and SQL order NaN
  differently, so NaN is out of scope here;
- filters: a comparison on each type, two columns compared, `&`, `|` and `~`,
  `isin` with a list (and an empty one), a boolean column as the condition, a
  function of the frame as the condition;
- projections, in file order and reordered, before and after a filter;
- computed columns: `+ - *` on ints (a literal on either side, an int32
  column), true division of ints (DOUBLE, as DuckDB's `/`), float arithmetic,
  int with float, negation, literals, boolean columns, a column replaced in
  place, a later keyword using an earlier one, and `df["x"] = ...`;
- sorts: ascending and descending over ints, floats, strings, a bool and a
  computed column, with NULLs last (pandas' default in both directions) or
  first, several keys with mixed directions, a second sort replacing the first;
  the answer is in the order of the keys, and rows that tie on every key may
  come out in any order;
- head: a sort then `head(n)` with a cut that falls between two distinct keys,
  a filter, projection, assign or sort after it, `head(0)`, a head larger than
  the file, a head of an unsorted frame that keeps every row;
- groupby, over what the engine's aggregation sinks run: sum, mean, min and
  max of ints and floats (a bool summed as a count, and its mean the share of
  its trues), count and size of every type,
  nunique of a float, a string and an int; one-row groups, one of them
  all-missing, whose sum is 0 (and missing under min_count=1); named, dict and
  list agg; sort=False (a multiset), dropna=False (the missing group last),
  two keys, string, bool and float keys; after a filter and a computed
  column; a sort by an output then head, head of the key sort, a filter of
  the groups, and a groupby of rows that match nothing;
- the frame's own reductions and agg, one row each (float sums, means, mins
  and maxes too, and a mean of a bool, the share of its trues), also over no
  rows (a sum of 0, a count of 0, a missing mean and max);
- the reductions the engine does not run yet (median, std, var, min and
  max of a string or a bool, nunique of a bool)
  build their plan and are refused at materialize() with the engine's step;
- drop_duplicates of whole rows over one and several columns, with NULLs,
  keep="last", a subset naming every column, and keep=False (only the rows
  no other row equals);
- a frame that is not ordered (no sort, or a verb that dropped a sort key)
  answers as a multiset of rows;
- columns are equal by name and order; ints, strings and bools exactly; floats
  to a relative 1e-12; NULL equals NULL; Arrow type names equal for every
  column but an int literal assigned as a column, which komira types int64
  and DuckDB int32 (an integer sum, int64 in komira and HUGEINT in DuckDB, is
  cast to BIGINT in the SQL);
- the comparator is itself checked on plain lists: it refuses answers that
  differ in one cell, in row order for an ordered case, in a column name, in a
  type, in a row count, and in a float beyond its tolerance, and it accepts
  rows that only move within a tie group.

The test is of the `duckdb/` family (python/tests/BUCK): CPython 3.13 alone,
the minor with a pinned DuckDB, on the real libkomira, with the generated plan
modules, duckdb, protobuf and pyarrow.

    test_frame_duckdb.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which the
rule passes, is not read).
"""

import collections
import math
import os
import sys
import tempfile

import komira
from komira import _native

ROWS = 40
FILE_COLUMNS = ("k", "v", "s", "flag", "n")

# k at these rows is an outlier, so the first and last three keys are distinct.
K_OUTLIERS = {7: 100, 19: 90, 28: 80, 36: -100, 2: -90, 11: -80}
STRINGS = ["alpha", "beta", "", "été", "日本語", None, "Zed", "alpha"]


# ---- the data ----------------------------------------------------------------


def column_values():
    """The five columns as Python lists. Rows with k NULL are 4, 13, 22 and 31."""
    k, v, s, flag, n = [], [], [], [], []
    for i in range(ROWS):
        k.append(K_OUTLIERS.get(i, None if i % 9 == 4 else (i * 5) % 11 - 4))
        v.append(None if i % 8 == 2 else ((i * 37) % 19 - 9) / 4)
        s.append(STRINGS[i % 8])
        flag.append([True, False, None][i % 3])
        n.append((i * 7) % 41 + 1)
    return {"k": k, "v": v, "s": s, "flag": flag, "n": n}


def write_data(path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    values = column_values()
    table = pa.table(
        {
            "k": pa.array(values["k"], pa.int64()),
            "v": pa.array(values["v"], pa.float64()),
            "s": pa.array(values["s"], pa.string()),
            "flag": pa.array(values["flag"], pa.bool_()),
            "n": pa.array(values["n"], pa.int32()),
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
        return isinstance(a, float) and isinstance(b, float) and math.isclose(a, b, rel_tol=1e-12, abs_tol=0.0)
    return type(a) is type(b) and a == b


def row_equal(a, b):
    return len(a) == len(b) and all(cell_equal(x, y) for x, y in zip(a, b))


def cell_key(x):
    if x is None:
        return (0, 0)
    if isinstance(x, bool):
        return (1, int(x))
    if isinstance(x, float):
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


def run_cases(path, cases):
    con = duckdb_for(path)
    with komira.Session() as session:
        for case in cases:
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


# ---- the cases ---------------------------------------------------------------

FILTERS = [
    Case("plain read", lambda d: d, "SELECT * FROM t"),
    Case("int greater", lambda d: d[d["k"] > 3], "SELECT * FROM t WHERE k > 3"),
    Case("int equal", lambda d: d[d["k"] == 2], "SELECT * FROM t WHERE k = 2"),
    Case("int not equal drops NULL", lambda d: d[d["k"] != 2], "SELECT * FROM t WHERE k <> 2"),
    Case("int negative bound", lambda d: d[d["k"] <= -4], "SELECT * FROM t WHERE k <= -4"),
    Case("int32 less or equal", lambda d: d[d["n"] <= 10], "SELECT * FROM t WHERE n <= 10"),
    Case("float less or equal", lambda d: d[d["v"] <= 0.5], "SELECT * FROM t WHERE v <= 0.5"),
    Case("float below negative", lambda d: d[d["v"] < -1.0], "SELECT * FROM t WHERE v < -1.0"),
    Case("string equal", lambda d: d[d["s"] == "alpha"], "SELECT * FROM t WHERE s = 'alpha'"),
    Case("string empty", lambda d: d[d["s"] == ""], "SELECT * FROM t WHERE s = ''"),
    Case("string non-ASCII", lambda d: d[d["s"] == "été"], "SELECT * FROM t WHERE s = 'été'"),
    Case("string greater or equal", lambda d: d[d["s"] >= "b"], "SELECT * FROM t WHERE s >= 'b'"),
    Case("bool equal false", lambda d: d[d["flag"] == False], "SELECT * FROM t WHERE flag = false"),  # noqa: E712
    Case("two columns compared", lambda d: d[d["k"] > d["n"]], "SELECT * FROM t WHERE k > n"),
    Case(
        "and",
        lambda d: d[(d["k"] > 0) & (d["v"] < 3.0)],
        "SELECT * FROM t WHERE k > 0 AND v < 3.0",
    ),
    Case(
        "or",
        lambda d: d[(d["k"] < 0) | (d["s"] == "alpha")],
        "SELECT * FROM t WHERE k < 0 OR s = 'alpha'",
    ),
    Case(
        "not over or",
        lambda d: d[~((d["k"] > 0) | (d["v"] > 0.0))],
        "SELECT * FROM t WHERE NOT (k > 0 OR v > 0.0)",
    ),
    Case(
        "and inside or with not",
        lambda d: d[((d["k"] > 0) & (d["n"] < 20)) | ~(d["s"] == "beta")],
        "SELECT * FROM t WHERE (k > 0 AND n < 20) OR NOT (s = 'beta')",
    ),
    Case("isin ints", lambda d: d[d["k"].isin([-4, 0, 6, 100])], "SELECT * FROM t WHERE k IN (-4, 0, 6, 100)"),
    Case(
        "isin strings with empty and non-ASCII",
        lambda d: d[d["s"].isin(["", "été", "Zed"])],
        "SELECT * FROM t WHERE s IN ('', 'été', 'Zed')",
    ),
    Case("isin floats", lambda d: d[d["v"].isin([0.25, -0.5])], "SELECT * FROM t WHERE v IN (0.25, -0.5)"),
    Case("not isin drops NULL", lambda d: d[~d["k"].isin([1, 2, 3])], "SELECT * FROM t WHERE NOT (k IN (1, 2, 3))"),
    Case("bool column as condition", lambda d: d[d["flag"]], "SELECT * FROM t WHERE flag"),
    Case("negated bool column", lambda d: d[~d["flag"]], "SELECT * FROM t WHERE NOT flag"),
    Case(
        "bool column and comparison",
        lambda d: d[d["flag"] & (d["k"] > 0)],
        "SELECT * FROM t WHERE flag AND k > 0",
    ),
    Case("function of the frame as condition", lambda d: d[lambda f: f["k"] > 0], "SELECT * FROM t WHERE k > 0"),
    Case("project", lambda d: d[["s", "k"]], "SELECT s, k FROM t"),
    Case("project one column", lambda d: d[["flag"]], "SELECT flag FROM t"),
    Case(
        "project reordered",
        lambda d: d[["n", "flag", "s", "v", "k"]],
        "SELECT n, flag, s, v, k FROM t",
    ),
    Case("filter then project", lambda d: d[d["k"] > 0][["k", "s"]], "SELECT k, s FROM t WHERE k > 0"),
    Case(
        "project then filter",
        lambda d: on(d[["k", "v"]], lambda p: p[p["v"] > 0.0]),
        "SELECT k, v FROM t WHERE v > 0.0",
    ),
]

ASSIGNS = [
    Case(
        "int add and subtract",
        lambda d: d.assign(a=d["k"] + 1, b=1 + d["k"], c=d["k"] - d["n"]),
        "SELECT *, k + 1 AS a, 1 + k AS b, k - n AS c FROM t",
    ),
    Case(
        "reflected subtract and multiply",
        lambda d: d.assign(a=10 - d["k"], b=3 * d["k"], c=2 * d["n"], e=100 - d["n"]),
        "SELECT *, 10 - k AS a, 3 * k AS b, 2 * n AS c, 100 - n AS e FROM t",
    ),
    Case(
        "int32 column arithmetic",
        lambda d: d.assign(a=d["n"] + 1, b=d["n"] * d["n"], c=d["n"] - 50),
        "SELECT *, n + 1 AS a, n * n AS b, n - 50 AS c FROM t",
    ),
    Case(
        "int64 times int32 column",
        lambda d: d.assign(a=d["k"] * d["n"]),
        "SELECT *, k * n AS a FROM t",
    ),
    Case(
        "negation",
        lambda d: d.assign(a=-d["k"], b=-d["v"], c=-d["n"]),
        "SELECT *, -k AS a, -v AS b, -n AS c FROM t",
    ),
    Case(
        "true division of ints is DOUBLE",
        lambda d: d.assign(a=d["k"] / 4, b=d["k"] / d["n"], c=100 / d["n"], e=d["n"] / 2),
        "SELECT *, k / 4 AS a, k / n AS b, 100 / n AS c, n / 2 AS e FROM t",
    ),
    Case(
        "float arithmetic",
        lambda d: d.assign(
            a=d["v"] * 2.5, b=d["v"] - 1.5, c=d["v"] + d["v"], e=2.0 * d["v"], f=1.0 - d["v"], g=d["v"] / 4.0
        ),
        "SELECT *, v * CAST(2.5 AS DOUBLE) AS a, v - CAST(1.5 AS DOUBLE) AS b, v + v AS c, "
        "CAST(2.0 AS DOUBLE) * v AS e, CAST(1.0 AS DOUBLE) - v AS f, v / CAST(4.0 AS DOUBLE) AS g FROM t",
    ),
    Case(
        "int with float",
        lambda d: d.assign(a=d["v"] + d["k"], b=d["k"] * d["v"], c=d["v"] * 2),
        "SELECT *, v + k AS a, k * v AS b, v * 2 AS c FROM t",
    ),
    Case(
        "literal columns",
        lambda d: d.assign(i=-3, f=2.5, yes=True, no=False, z="x"),
        "SELECT *, -3 AS i, CAST(2.5 AS DOUBLE) AS f, true AS yes, false AS no, 'x' AS z FROM t",
        untyped=("i",),
    ),
    Case(
        "boolean columns",
        lambda d: d.assign(
            pos=d["k"] > 0,
            both=(d["k"] > 0) & (d["v"] > 0.0),
            either=d["flag"] | (d["n"] > 30),
            neg=~(d["k"] > 0),
        ),
        "SELECT *, k > 0 AS pos, (k > 0 AND v > 0.0) AS both, (flag OR n > 30) AS either, "
        "NOT (k > 0) AS neg FROM t",
    ),
    Case(
        "replace int and float in place",
        lambda d: d.assign(k=d["k"] * 2, v=d["v"] + 1.0),
        "SELECT * REPLACE (k * 2 AS k, v + CAST(1.0 AS DOUBLE) AS v) FROM t",
    ),
    Case(
        "replace int32 in place",
        lambda d: d.assign(n=d["n"] + 1),
        "SELECT * REPLACE (n + 1 AS n) FROM t",
    ),
    Case("replace a column by another", lambda d: d.assign(k=d["n"]), "SELECT * REPLACE (n AS k) FROM t"),
    Case(
        "later keyword uses an earlier one",
        lambda d: d.assign(a=d["k"] + 1, b=lambda f: f["a"] * 2),
        "SELECT *, k + 1 AS a, (k + 1) * 2 AS b FROM t",
    ),
    Case(
        "subscript assignment appends and replaces",
        lambda d: on(d, subscript_assignments),
        "SELECT * REPLACE (v * CAST(2.0 AS DOUBLE) AS v, n AS k), k + 1 AS a, (k + 1) * 2 AS b, 5 AS c, "
        "CAST(0.5 AS DOUBLE) AS f FROM t",
        untyped=("c",),
    ),
    Case(
        "filter on a computed column",
        lambda d: on(d.assign(a=d["k"] * 2), lambda e: e[e["a"] > 10]),
        "SELECT *, k * 2 AS a FROM t WHERE k * 2 > 10",
    ),
    Case(
        "assign after a filter",
        lambda d: on(d[d["k"] > 0], lambda f: f.assign(a=f["k"] + f["n"])),
        "SELECT *, k + n AS a FROM t WHERE k > 0",
    ),
]


def subscript_assignments(d):
    d["a"] = d["k"] + 1
    d["b"] = d["a"] * 2
    d["c"] = 5
    d["f"] = 0.5
    d["v"] = d["v"] * 2.0
    d["k"] = d["n"]
    return d


def asc(name, nulls="LAST"):
    return "{} ASC NULLS {}".format(name, nulls)


def desc(name, nulls="LAST"):
    return "{} DESC NULLS {}".format(name, nulls)


SORTS = [
    Case("int ascending", lambda d: d.sort_values("k"), "SELECT * FROM t ORDER BY " + asc("k"), ("k",)),
    Case(
        "int descending keeps NULLs last",
        lambda d: d.sort_values("k", ascending=False),
        "SELECT * FROM t ORDER BY " + desc("k"),
        ("k",),
    ),
    Case(
        "int ascending NULLs first",
        lambda d: d.sort_values("k", na_position="first"),
        "SELECT * FROM t ORDER BY " + asc("k", "FIRST"),
        ("k",),
    ),
    Case(
        "int descending NULLs first",
        lambda d: d.sort_values("k", ascending=False, na_position="first"),
        "SELECT * FROM t ORDER BY " + desc("k", "FIRST"),
        ("k",),
    ),
    Case(
        "float descending",
        lambda d: d.sort_values("v", ascending=False),
        "SELECT * FROM t ORDER BY " + desc("v"),
        ("v",),
    ),
    Case("int32 descending", lambda d: d.sort_values("n", ascending=False), "SELECT * FROM t ORDER BY n DESC", ("n",)),
    Case("string ascending", lambda d: d.sort_values("s"), "SELECT * FROM t ORDER BY " + asc("s"), ("s",)),
    Case(
        "string descending NULLs first",
        lambda d: d.sort_values("s", ascending=False, na_position="first"),
        "SELECT * FROM t ORDER BY " + desc("s", "FIRST"),
        ("s",),
    ),
    Case(
        "bool descending",
        lambda d: d.sort_values("flag", ascending=False),
        "SELECT * FROM t ORDER BY " + desc("flag"),
        ("flag",),
    ),
    Case(
        "two keys, descending then ascending",
        lambda d: d.sort_values(["flag", "k"], ascending=[False, True]),
        "SELECT * FROM t ORDER BY {}, {}".format(desc("flag"), asc("k")),
        ("flag", "k"),
    ),
    Case(
        "two keys, NULLs first",
        lambda d: d.sort_values(["s", "k"], ascending=[True, False], na_position="first"),
        "SELECT * FROM t ORDER BY {}, {}".format(asc("s", "FIRST"), desc("k", "FIRST")),
        ("s", "k"),
    ),
    Case(
        "keys given as a tuple",
        lambda d: d.sort_values(("k", "n")),
        "SELECT * FROM t ORDER BY {}, {}".format(asc("k"), asc("n")),
        ("k", "n"),
    ),
    Case(
        "second sort replaces the first",
        lambda d: d.sort_values("k").sort_values("n"),
        "SELECT * FROM t ORDER BY n ASC",
        ("n",),
    ),
    Case(
        "sort by a computed column",
        lambda d: on(d.assign(w=d["k"] * -1), lambda e: e.sort_values("w")),
        "SELECT *, k * -1 AS w FROM t ORDER BY " + asc("w"),
        ("w",),
    ),
    Case(
        "filter after a sort keeps its order",
        lambda d: on(d.sort_values("k"), lambda s: s[s["v"] > 0.0]),
        "SELECT * FROM t WHERE v > 0.0 ORDER BY " + asc("k"),
        ("k",),
    ),
    Case(
        "filter before a sort",
        lambda d: d[d["k"] > 0].sort_values("v", ascending=False),
        "SELECT * FROM t WHERE k > 0 ORDER BY " + desc("v"),
        ("v",),
    ),
    Case(
        "assign after a sort keeps its order",
        lambda d: on(d.sort_values("k"), lambda s: s.assign(w=s["n"] + 1)),
        "SELECT *, n + 1 AS w FROM t ORDER BY " + asc("k"),
        ("k",),
    ),
    Case(
        "projection keeping the keys after a sort keeps its order",
        lambda d: on(d.sort_values(["k", "n"]), lambda s: s[["n", "k"]]),
        "SELECT n, k FROM t ORDER BY {}, {}".format(asc("k"), asc("n")),
        ("k", "n"),
    ),
    Case(
        "projection dropping the key after a sort is a multiset",
        lambda d: d.sort_values("k")[["s", "v"]],
        "SELECT s, v FROM t",
    ),
    Case(
        "assign replacing the key after a sort is a multiset",
        lambda d: on(d.sort_values("k"), lambda s: s.assign(k=s["k"] * -1)),
        "SELECT * REPLACE (k * -1 AS k) FROM t",
    ),
]

HEADS = [
    Case(
        "ascending top three",
        lambda d: d.sort_values("k").head(3),
        "SELECT * FROM t ORDER BY k ASC NULLS LAST LIMIT 3",
        ("k",),
    ),
    Case(
        "descending top three",
        lambda d: d.sort_values("k", ascending=False).head(3),
        "SELECT * FROM t ORDER BY k DESC NULLS LAST LIMIT 3",
        ("k",),
    ),
    Case(
        "NULLs first takes the four NULL rows",
        lambda d: d.sort_values("k", na_position="first").head(4),
        "SELECT * FROM t ORDER BY k ASC NULLS FIRST LIMIT 4",
        ("k",),
    ),
    Case(
        "descending NULLs first takes NULLs then the top two",
        lambda d: d.sort_values("k", ascending=False, na_position="first").head(6),
        "SELECT * FROM t ORDER BY k DESC NULLS FIRST LIMIT 6",
        ("k",),
    ),
    Case("unique key top five", lambda d: d.sort_values("n").head(5), "SELECT * FROM t ORDER BY n LIMIT 5", ("n",)),
    Case(
        "a head of a head, then a filter, keeps the sort",
        lambda d: on(d.sort_values("n").head(9).head(6), lambda e: e[e["n"] > 0]),
        "SELECT * FROM (SELECT * FROM t ORDER BY n LIMIT 6) WHERE n > 0 ORDER BY n",
        ("n",),
    ),
    Case(
        "unique key descending top seven",
        lambda d: d.sort_values("n", ascending=False).head(7),
        "SELECT * FROM t ORDER BY n DESC LIMIT 7",
        ("n",),
    ),
    Case(
        "filter then sort then head",
        lambda d: d[d["k"] > 0].sort_values("n", ascending=False).head(3),
        "SELECT * FROM t WHERE k > 0 ORDER BY n DESC LIMIT 3",
        ("n",),
    ),
    Case(
        "filter after a sort stays under the head",
        lambda d: on(d.sort_values("n"), lambda s: s[s["k"] > 0].head(3)),
        "SELECT * FROM t WHERE k > 0 ORDER BY n LIMIT 3",
        ("n",),
    ),
    Case(
        "filter after head keeps the order",
        lambda d: on(d.sort_values("k", ascending=False).head(3), lambda s: s[s["v"] > 0.0]),
        "SELECT * FROM (SELECT * FROM t ORDER BY k DESC NULLS LAST LIMIT 3) WHERE v > 0.0 "
        "ORDER BY k DESC NULLS LAST",
        ("k",),
    ),
    Case(
        "assign after head keeps the order",
        lambda d: on(d.sort_values("n").head(5), lambda s: s.assign(w=s["k"] * 2)),
        "SELECT *, k * 2 AS w FROM (SELECT * FROM t ORDER BY n LIMIT 5) ORDER BY n",
        ("n",),
    ),
    Case(
        "projection keeping the key after head keeps the order",
        lambda d: d.sort_values("n").head(5)[["n", "s"]],
        "SELECT n, s FROM (SELECT * FROM t ORDER BY n LIMIT 5) ORDER BY n",
        ("n",),
    ),
    Case(
        "projection dropping the key after head is a multiset",
        lambda d: d.sort_values("n").head(5)[["s", "v"]],
        "SELECT s, v FROM (SELECT * FROM t ORDER BY n LIMIT 5)",
    ),
    Case(
        "sort after head sorts the rows head kept",
        lambda d: d.sort_values("n").head(10).sort_values("k"),
        "SELECT * FROM (SELECT * FROM t ORDER BY n LIMIT 10) ORDER BY k ASC NULLS LAST",
        ("k",),
    ),
    Case(
        "head larger than the file keeps every row in order",
        lambda d: d.sort_values("n").head(100),
        "SELECT * FROM t ORDER BY n",
        ("n",),
    ),
    Case("head of an unsorted frame that keeps every row", lambda d: d.head(1000), "SELECT * FROM t"),
]

EMPTIES = [
    Case("head of zero after a sort", lambda d: d.sort_values("k").head(0), "SELECT * FROM t ORDER BY k LIMIT 0", ("k",), True),
    Case("head of zero unsorted", lambda d: d.head(0), "SELECT * FROM t LIMIT 0", None, True),
    Case("filter that matches nothing", lambda d: d[d["k"] > 1000], "SELECT * FROM t WHERE k > 1000", None, True),
    Case("isin of an empty list", lambda d: d[d["k"].isin([])], "SELECT * FROM t WHERE false", None, True),
    Case(
        "contradictory conditions",
        lambda d: d[(d["k"] > 5) & (d["k"] < 0)],
        "SELECT * FROM t WHERE k > 5 AND k < 0",
        None,
        True,
    ),
    Case(
        "sorted frame filtered to nothing",
        lambda d: d.sort_values("k")[lambda s: s["k"] > 1000],
        "SELECT * FROM t WHERE k > 1000 ORDER BY k",
        ("k",),
        True,
    ),
    Case(
        "projection of an empty filter keeps the names and types",
        lambda d: d[d["k"] > 1000][["s", "n"]],
        "SELECT s, n FROM t WHERE k > 1000",
        None,
        True,
    ),
    Case(
        "computed column of an empty filter keeps its type",
        lambda d: on(d[d["k"] > 1000], lambda f: f.assign(a=f["v"] * 2.0, ok=f["k"] > 0)),
        "SELECT *, v * CAST(2.0 AS DOUBLE) AS a, k > 0 AS ok FROM t WHERE k > 1000",
        None,
        True,
    ),
]


# ---- group-by, reductions and drop_duplicates ----------------------------------
# The SQL of a pandas groupby: WHERE <keys> IS NOT NULL (dropna=True), GROUP BY,
# ORDER BY <keys> ASC NULLS LAST (sort=True); a sum is COALESCE(SUM(x), 0).
#
# The plan door's aggregation sinks run SUM, AVG, MIN, MAX, COUNT, COUNT(*)
# and COUNT(DISTINCT): SUM and AVG over integers and floats (a bool's sum over
# the CASE that makes True 1, its mean over its cast to float64); MIN and MAX
# over numbers; COUNT(DISTINCT) over
# numbers and strings. These cases are those; ENGINE_REFUSED below holds the
# rest.

GROUPED_BY_K = "FROM t WHERE k IS NOT NULL GROUP BY k ORDER BY k ASC NULLS LAST"
GROUPED_BY_S = "FROM t WHERE s IS NOT NULL GROUP BY s ORDER BY s ASC NULLS LAST"

GROUPS = [
    Case(
        "groupby sum of ints with NULLs, by a string key",
        lambda d: d.groupby("s")[["k", "n"]].sum(),
        "SELECT s, CAST(COALESCE(SUM(k), 0) AS BIGINT) AS k, CAST(COALESCE(SUM(n), 0) AS BIGINT) AS n "
        + GROUPED_BY_S,
        ("s",),
    ),
    Case(
        "groupby sum of one-row groups, an all-missing one summing to 0",
        lambda d: d.groupby("n")["k"].sum(),
        "SELECT n, CAST(COALESCE(SUM(k), 0) AS BIGINT) AS k FROM t WHERE n IS NOT NULL GROUP BY n "
        "ORDER BY n ASC NULLS LAST",
        ("n",),
    ),
    Case(
        "groupby sum with min_count=1 keeps the missing sum",
        lambda d: d.groupby("n")["k"].sum(min_count=1),
        "SELECT n, CAST(SUM(k) AS BIGINT) AS k FROM t WHERE n IS NOT NULL GROUP BY n ORDER BY n ASC NULLS LAST",
        ("n",),
    ),
    Case(
        "groupby sum of a bool with min_count=1 keeps the missing sum",
        lambda d: d.groupby("k")["flag"].sum(min_count=1),
        "SELECT k, CAST(SUM(CAST(flag AS BIGINT)) AS BIGINT) AS flag " + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby sum of a bool counts True",
        lambda d: d.groupby("k")["flag"].sum(),
        "SELECT k, CAST(COALESCE(SUM(CAST(flag AS BIGINT)), 0) AS BIGINT) AS flag " + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby sum of a float, an all-missing group summing to 0",
        lambda d: d.groupby("k")["v"].sum(),
        "SELECT k, COALESCE(SUM(v), 0) AS v " + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby sum of a float with min_count=1 keeps the missing sum",
        lambda d: d.groupby("k")["v"].sum(min_count=1),
        "SELECT k, SUM(v) AS v " + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby mean, min and max of a float, by a string key",
        lambda d: d.groupby("s").agg(m=("v", "mean"), lo=("v", "min"), hi=("v", "max")),
        "SELECT s, AVG(v) AS m, MIN(v) AS lo, MAX(v) AS hi " + GROUPED_BY_S,
        ("s",),
    ),
    Case(
        "groupby mean of a bool is the share of its trues, NULL left out",
        lambda d: d.groupby("k")["flag"].mean(),
        "SELECT k, AVG(CAST(flag AS INTEGER)) AS flag " + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby mean of ints",
        lambda d: d.groupby("s")[["k", "n"]].mean(),
        "SELECT s, AVG(k) AS k, AVG(n) AS n " + GROUPED_BY_S,
        ("s",),
    ),
    Case(
        "groupby min of ints",
        lambda d: d.groupby("s")[["k", "n"]].min(),
        "SELECT s, MIN(k) AS k, MIN(n) AS n " + GROUPED_BY_S,
        ("s",),
    ),
    Case(
        "groupby max of ints",
        lambda d: d.groupby("s")[["k", "n"]].max(),
        "SELECT s, MAX(k) AS k, MAX(n) AS n " + GROUPED_BY_S,
        ("s",),
    ),
    Case(
        "groupby count of values that are not missing, every type",
        lambda d: d.groupby("k").count(),
        "SELECT k, COUNT(v) AS v, COUNT(s) AS s, COUNT(flag) AS flag, COUNT(n) AS n " + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby size counts rows",
        lambda d: d.groupby("k").size(),
        'SELECT k, COUNT(*) AS "size" ' + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby nunique of a float, a string and an int",
        lambda d: d.groupby("k")[["v", "s", "n"]].nunique(),
        "SELECT k, COUNT(DISTINCT v) AS v, COUNT(DISTINCT s) AS s, COUNT(DISTINCT n) AS n " + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby named agg",
        lambda d: d.groupby("k").agg(
            total=("n", "sum"), hi=("n", "max"), rows=("s", "size"), names=("s", "nunique"), avg=("n", "mean")
        ),
        "SELECT k, CAST(COALESCE(SUM(n), 0) AS BIGINT) AS total, MAX(n) AS hi, COUNT(*) AS rows, "
        "COUNT(DISTINCT s) AS names, AVG(n) AS avg " + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby dict agg by a string key",
        lambda d: d.groupby("s").agg({"k": "mean", "n": "min"}),
        "SELECT s, AVG(k) AS k, MIN(n) AS n " + GROUPED_BY_S,
        ("s",),
    ),
    Case(
        "groupby of one column with a list of reductions",
        lambda d: d.groupby("k")["n"].agg(["sum", "mean", "count"]),
        'SELECT k, CAST(COALESCE(SUM(n), 0) AS BIGINT) AS "sum", AVG(n) AS mean, COUNT(n) AS "count" '
        + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby dropna=False keeps the missing group, last",
        lambda d: d.groupby("k", dropna=False)[["n"]].sum(),
        "SELECT k, CAST(COALESCE(SUM(n), 0) AS BIGINT) AS n FROM t GROUP BY k ORDER BY k ASC NULLS LAST",
        ("k",),
    ),
    Case(
        "groupby sort=False is a multiset",
        lambda d: d.groupby("k", sort=False)["n"].max(),
        "SELECT k, MAX(n) AS n FROM t WHERE k IS NOT NULL GROUP BY k",
    ),
    Case(
        "groupby two keys, a bool and an int",
        lambda d: d.groupby(["flag", "k"]).agg(rows=("n", "size"), total=("n", "sum")),
        "SELECT flag, k, COUNT(*) AS rows, CAST(COALESCE(SUM(n), 0) AS BIGINT) AS total FROM t "
        "WHERE flag IS NOT NULL AND k IS NOT NULL GROUP BY flag, k ORDER BY flag ASC NULLS LAST, k ASC NULLS LAST",
        ("flag", "k"),
    ),
    Case(
        "groupby a bool key with dropna=False",
        lambda d: d.groupby("flag", dropna=False)["n"].count(),
        "SELECT flag, COUNT(n) AS n FROM t GROUP BY flag ORDER BY flag ASC NULLS LAST",
        ("flag",),
    ),
    Case(
        "groupby a float key",
        lambda d: d.groupby("v")["n"].count(),
        "SELECT v, COUNT(n) AS n FROM t WHERE v IS NOT NULL GROUP BY v ORDER BY v ASC NULLS LAST",
        ("v",),
    ),
    Case(
        "groupby after a filter",
        lambda d: d[d["n"] > 10].groupby("k")["n"].mean(),
        "SELECT k, AVG(n) AS n FROM t WHERE n > 10 AND k IS NOT NULL GROUP BY k ORDER BY k ASC NULLS LAST",
        ("k",),
    ),
    Case(
        "groupby of a computed column",
        lambda d: d.assign(m=d["n"] * 2).groupby("k")["m"].sum(),
        "SELECT k, CAST(COALESCE(SUM(n * 2), 0) AS BIGINT) AS m " + GROUPED_BY_K,
        ("k",),
    ),
    Case(
        "groupby sorted by its output, then head",
        lambda d: d.groupby("k").size().sort_values(["size", "k"], ascending=[False, True]).head(3),
        'SELECT k, COUNT(*) AS "size" FROM t WHERE k IS NOT NULL GROUP BY k '
        'ORDER BY "size" DESC NULLS LAST, k ASC NULLS LAST LIMIT 3',
        ("size", "k"),
    ),
    Case(
        "head of the key sort of a groupby",
        lambda d: d.groupby("k")["n"].max().head(4),
        "SELECT k, MAX(n) AS n " + GROUPED_BY_K + " LIMIT 4",
        ("k",),
    ),
    Case(
        "a filter of the groups keeps the key order",
        lambda d: on(d.groupby("k").size(), lambda g: g[g["size"] > 2]),
        'SELECT * FROM (SELECT k, COUNT(*) AS "size" FROM t WHERE k IS NOT NULL GROUP BY k) '
        'WHERE "size" > 2 ORDER BY k ASC NULLS LAST',
        ("k",),
    ),
    Case(
        "groupby of rows that match nothing",
        lambda d: d[d["k"] > 1000].groupby("k")[["n"]].sum(),
        "SELECT k, CAST(COALESCE(SUM(n), 0) AS BIGINT) AS n FROM t WHERE k > 1000 GROUP BY k "
        "ORDER BY k ASC NULLS LAST",
        ("k",),
        True,
    ),
]

REDUCTIONS = [
    Case(
        "agg of the whole frame",
        lambda d: d.agg(
            total=("v", "sum"), rows=("k", "size"), keys=("k", "count"), uniq=("s", "nunique"), lo=("v", "min"),
            hi=("k", "max"),
        ),
        "SELECT COALESCE(SUM(v), 0) AS total, COUNT(*) AS rows, COUNT(k) AS keys, COUNT(DISTINCT s) AS uniq, "
        "MIN(v) AS lo, MAX(k) AS hi FROM t",
    ),
    Case(
        "sum of the frame: a float, an int32 and a bool",
        lambda d: d[["v", "n", "flag"]].sum(),
        "SELECT COALESCE(SUM(v), 0) AS v, CAST(COALESCE(SUM(n), 0) AS BIGINT) AS n, "
        "CAST(COALESCE(SUM(CAST(flag AS BIGINT)), 0) AS BIGINT) AS flag FROM t",
    ),
    Case(
        "mean of a bool is the share of its trues, NULL left out",
        lambda d: d[["flag"]].mean(),
        "SELECT AVG(CAST(flag AS INTEGER)) AS flag FROM t",
    ),
    Case(
        "mean of the frame's numbers",
        lambda d: d[["k", "v", "n"]].mean(),
        "SELECT AVG(k) AS k, AVG(v) AS v, AVG(n) AS n FROM t",
    ),
    Case(
        "min of the frame's numbers",
        lambda d: d[["k", "v", "n"]].min(),
        "SELECT MIN(k) AS k, MIN(v) AS v, MIN(n) AS n FROM t",
    ),
    Case(
        "max of the frame's numbers",
        lambda d: d[["k", "v", "n"]].max(),
        "SELECT MAX(k) AS k, MAX(v) AS v, MAX(n) AS n FROM t",
    ),
    Case(
        "count of the frame",
        lambda d: d.count(),
        "SELECT COUNT(k) AS k, COUNT(v) AS v, COUNT(s) AS s, COUNT(flag) AS flag, COUNT(n) AS n FROM t",
    ),
    Case(
        "nunique of the frame",
        lambda d: d[["k", "v", "s", "n"]].nunique(),
        "SELECT COUNT(DISTINCT k) AS k, COUNT(DISTINCT v) AS v, COUNT(DISTINCT s) AS s, COUNT(DISTINCT n) AS n FROM t",
    ),
    Case(
        "dict agg of the frame",
        lambda d: d.agg({"v": "max", "s": "count"}),
        "SELECT MAX(v) AS v, COUNT(s) AS s FROM t",
    ),
    Case(
        "agg of the frame by a reduction's name",
        lambda d: d[["v"]].agg("mean"),
        "SELECT AVG(v) AS v FROM t",
    ),
    Case(
        "agg of no rows: a sum of 0, a count of 0, a missing mean and max",
        lambda d: d[d["k"] > 1000].agg(total=("v", "sum"), rows=("v", "size"), m=("v", "mean"), hi=("k", "max")),
        "SELECT COALESCE(SUM(v), 0) AS total, COUNT(*) AS rows, AVG(v) AS m, MAX(k) AS hi FROM t WHERE k > 1000",
    ),
    Case(
        "sum of no rows with min_count=1 is missing",
        lambda d: d[d["k"] > 1000][["v"]].sum(min_count=1),
        "SELECT SUM(v) AS v FROM t WHERE k > 1000",
    ),
]

# Programs whose plan the verb builds and the engine does not run yet: each is
# refused at materialize() with the engine's step, never answered otherwise
# (docs/design/dataframe_surface.md, section 6). When the engine runs one,
# its check here fails and the program moves to the cases above.
ENGINE_REFUSED = [
    ("a grouped median", lambda d: d.groupby("k")["n"].median()),
    ("a grouped std", lambda d: d.groupby("k")["n"].std()),
    ("a grouped var", lambda d: d.groupby("k")["n"].var()),
    ("a median", lambda d: d[["v"]].median()),
    ("a std", lambda d: d[["v"]].std()),
    ("a var", lambda d: d[["n"]].var()),
    ("a min of a string", lambda d: d[["s"]].min()),
    ("a grouped max of a bool", lambda d: d.groupby("k")["flag"].max()),
    ("an nunique of a bool", lambda d: d[["flag"]].nunique()),
]

DISTINCTS = [
    Case("drop_duplicates of one column, NULL kept once", lambda d: d[["s"]].drop_duplicates(), "SELECT DISTINCT s FROM t"),
    Case(
        "drop_duplicates of two columns",
        lambda d: d[["flag", "k"]].drop_duplicates(),
        "SELECT DISTINCT flag, k FROM t",
    ),
    Case(
        "drop_duplicates keep=last of whole rows",
        lambda d: d[["flag", "s"]].drop_duplicates(keep="last"),
        "SELECT DISTINCT flag, s FROM t",
    ),
    Case(
        "drop_duplicates with a subset naming every column",
        lambda d: d[["k", "s"]].drop_duplicates(subset=["s", "k"]),
        "SELECT DISTINCT k, s FROM t",
    ),
    Case("drop_duplicates of rows that are all distinct", lambda d: d.drop_duplicates(), "SELECT DISTINCT * FROM t"),
    Case(
        "drop_duplicates keep=False keeps the keys seen once, not the NULL seen four times",
        lambda d: d[["k"]].drop_duplicates(keep=False),
        "SELECT k FROM t GROUP BY k HAVING COUNT(*) = 1",
    ),
    Case(
        "drop_duplicates keep=False of two columns",
        lambda d: d[["flag", "s"]].drop_duplicates(keep=False),
        "SELECT flag, s FROM t GROUP BY flag, s HAVING COUNT(*) = 1",
    ),
    Case(
        "drop_duplicates then a sort",
        lambda d: d[["s"]].drop_duplicates().sort_values("s"),
        "SELECT DISTINCT s FROM t ORDER BY s ASC NULLS LAST",
        ("s",),
    ),
]


# ---- the tests that run frames -----------------------------------------------


def test_filters_and_projections_equal_duckdb(path):
    run_cases(path, FILTERS)


def test_computed_columns_equal_duckdb(path):
    run_cases(path, ASSIGNS)


def test_sorts_equal_duckdb_in_the_order_of_their_keys(path):
    run_cases(path, SORTS)


def test_head_after_a_sort_equals_duckdb_limit(path):
    run_cases(path, HEADS)


def test_empty_answers_keep_the_names_and_types(path):
    run_cases(path, EMPTIES)


def test_groupby_reductions_equal_duckdb_group_by(path):
    run_cases(path, GROUPS)


def test_frame_reductions_equal_duckdb_aggregates_of_one_row(path):
    run_cases(path, REDUCTIONS)


def test_drop_duplicates_equals_duckdb_distinct(path):
    run_cases(path, DISTINCTS)


def test_aggregates_the_engine_does_not_run_yet_are_refused_at_the_terminal(path):
    with komira.Session() as session:
        base = komira.read_parquet(path, session=session)
        for name, program in ENGINE_REFUSED:
            frame = program(base)
            try:
                frame.materialize().to_arrow()
            except komira.KomiraError as e:
                # The engine's refusal: it names the step of the query that refused.
                assert e.step is not None, "{}: refused with no engine step: {}".format(name, e)
            else:
                raise AssertionError("{}: the engine answered it; move it to the oracle cases".format(name))


def test_a_frame_answers_alike_after_other_frames_derive_from_it(path):
    con = duckdb_for(path)
    want = duckdb_answer(con, "SELECT * FROM t")
    with komira.Session() as session:
        base = komira.read_parquet(path, session=session)
        before = answer_of(base.materialize().to_arrow())
        derived = [
            (base[base["k"] > 0], "SELECT * FROM t WHERE k > 0"),
            (base.sort_values("k").head(3), "SELECT * FROM t ORDER BY k ASC NULLS LAST LIMIT 3"),
            (base.assign(a=base["k"] + 1), "SELECT *, k + 1 AS a FROM t"),
            (base[["k"]], "SELECT k FROM t"),
        ]
        for frame, sql in derived:
            found = differences(answer_of(frame.materialize().to_arrow()), duckdb_answer(con, sql))
            assert found is None, "{}: {}".format(sql, found)
        after = answer_of(base.materialize().to_arrow())
    for label, got in (("before", before), ("after", after)):
        found = differences(got, want)
        assert found is None, "the base frame {} its derived frames ran: {}".format(label, found)


def test_the_file_has_nulls_negatives_ties_and_distinct_cuts(path):
    values = column_values()
    k, v, s, flag, n = (values[c] for c in FILE_COLUMNS)
    assert len(k) == ROWS
    assert k.count(None) == 4 and [i for i, x in enumerate(k) if x is None] == [4, 13, 22, 31], k
    present = [x for x in k if x is not None]
    assert min(present) == -100 and max(present) == 100
    assert len(set(present)) < len(present), "k has no ties"
    top, bottom = sorted(present, reverse=True)[:4], sorted(present)[:4]
    assert top[2] > top[3] and bottom[2] < bottom[3], (top, bottom)
    assert None in v and any(x is not None and x < 0 for x in v) and 0.0 in v
    assert not any(isinstance(x, float) and math.isnan(x) for x in v)
    assert None in s and "" in s and any(x is not None and not x.isascii() for x in s)
    assert None in flag and True in flag and False in flag
    assert len(set(n)) == ROWS and 0 not in n and max(n) < 2**31
    import pyarrow.parquet as pq

    table = pq.read_table(path)
    assert [str(t) for t in table.schema.types] == ["int64", "double", "string", "bool", "int32"], table.schema
    assert table.to_pydict() == values


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


# ---- main --------------------------------------------------------------------

WITH_FILE = [
    test_the_file_has_nulls_negatives_ties_and_distinct_cuts,
    test_filters_and_projections_equal_duckdb,
    test_computed_columns_equal_duckdb,
    test_sorts_equal_duckdb_in_the_order_of_their_keys,
    test_head_after_a_sort_equals_duckdb_limit,
    test_empty_answers_keep_the_names_and_types,
    test_a_frame_answers_alike_after_other_frames_derive_from_it,
    test_groupby_reductions_equal_duckdb_group_by,
    test_frame_reductions_equal_duckdb_aggregates_of_one_row,
    test_drop_duplicates_equals_duckdb_distinct,
    test_aggregates_the_engine_does_not_run_yet_are_refused_at_the_terminal,
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
    print("frame duckdb: {} programs equal DuckDB's answer over libkomira {}".format(
        sum(len(c) for c in (FILTERS, ASSIGNS, SORTS, HEADS, EMPTIES, GROUPS, REDUCTIONS, DISTINCTS)), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
