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
- a frame that is not ordered (no sort, or a verb that dropped a sort key)
  answers as a multiset of rows;
- columns are equal by name and order; ints, strings and bools exactly; floats
  to a relative 1e-12; NULL equals NULL; Arrow type names equal for the
  columns read from the file and for computed float and bool columns, and not
  compared for computed integer columns;
- the comparator is itself checked on plain lists: it refuses answers that
  differ in one cell, in row order for an ordered case, in a column name, in a
  type, in a row count, and in a float beyond its tolerance, and it accepts
  rows that only move within a tie group.

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
INTEGER_TYPES = frozenset({"int8", "int16", "int32", "int64", "uint8", "uint16", "uint32", "uint64"})

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
            skip = set(case.untyped) | {
                name for name, t in zip(want[0], want[1]) if name not in FILE_COLUMNS and t in INTEGER_TYPES
            }
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
    Case("negation", lambda d: d.assign(a=-d["k"], b=-d["v"]), "SELECT *, -k AS a, -v AS b FROM t"),
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
        untyped=("n",),
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
        sum(len(c) for c in (FILTERS, ASSIGNS, SORTS, HEADS, EMPTIES)), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
