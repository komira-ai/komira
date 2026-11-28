"""Merges, semi and anti joins, and windows of the pandas-shaped DataFrame held to
DuckDB: each frame program runs through komira's plan door (no SQL), and the SQL
that means the same pandas answer runs in DuckDB over the same two Parquet files;
the two answers must be equal (`frame_join_window_duckdb_test`, CPython 3.13, the
real libkomira). The comparator, the left file and the Case type are
those of `duckdb/test_frame_duckdb.py`, staged beside this file
(python/tests/BUCK).

- the files: the left one is `test_frame_duckdb.write_data` (k int64 with NULLs,
  v float64, s string, flag bool, n int32 unique); the right one is written here,
  12 rows built in code, no randomness: k int64 with duplicates, two NULLs, values
  the left file has and values it has not, and v float64 and s string, whose names
  collide with the left file's, and w int64, a column of its own, with a NULL.
  DuckDB sees them as the views `t` (left) and `o` (right);
- merge, how inner, left, right, outer and cross, over `on="k"` (a key named alike
  on both sides is one column: the left frame's for inner and left, the right
  frame's for right, the one with a value for outer), the default and custom
  suffixes, `left_on`/`right_on` with different names, two keys (a string and an
  int, and two ints named differently on one side), a merge of the left file with
  itself, `sort=True` (the key ascending, NULLs last), a merge then a filter, an
  assign, a groupby and a window, a merge of filtered and projected frames, and a
  merge of a sorted frame (its answer has no order);
- a missing key matches nothing, as in SQL's `=`: both files have NULL keys, and
  no merge row pairs one with another. pandas matches missing keys to each other;
  komira departs (ruling 7 of docs/design/dataframe_surface.md, section 8), so the
  SQL here is the plain `=` and not pandas' answer;
- isin with a Series of a frame: `df[df["k"].isin(o["k"])]` is WHERE EXISTS and
  `df[~df["k"].isin(o["k"])]` is WHERE NOT EXISTS (a left row with a NULL key is
  kept by the anti join, and a NULL key on the right removes nothing), over the
  right frame, a filtered one, an expression of one, the left frame itself, and a
  sorted frame, which keeps its order through the join;
- windows, over the plan's window projections: `groupby(...)[c].transform` of sum,
  mean, min, max and count (NULL where the key is NULL, or the NULL group computed
  under `dropna=False`), cumsum, cummin and cummax of a column and of a group on
  a frame sorted by the unique `n`, ascending and descending, rank of method min
  and dense, ascending and descending, `na_option` keep, bottom and top, a running sum down a frame sorted with
  its missing keys first, over a column
  and a group, rolling of 1, 2 and 3 rows with `min_periods` of 1 and 2 (missing
  when fewer than `min_periods` rows of the window hold a value), shift as LAG
  and LEAD (NULL on the first or last rows, over an int column with NULLs, a
  float, a string, a period of 0 and a frame sorted descending), diff (an int
  column's as a double, a float's two rows ahead) and pct_change where no
  previous value is 0, a filter by a diff, a window inside an expression, a
  filter by a window, and two windows in one assign;
- shift, diff and pct_change held to pandas itself over a file written in the
  test, sorted by t: an int64 column without NULLs (pandas' diff and
  pct_change of it are float64) and a float64 one with NULL, NaN, zeros and
  negatives, so a previous value of 0 meets a positive, a negative, a 0 and a
  NaN value; the frames are equal, dtypes included;
- each answer is equal by column names and order, the Arrow type names, and the
  values (floats to a relative 1e-12), in the order of the sort keys for a sorted
  frame, else as a multiset;
- a run does not stop at its first difference: it names every program whose
  answer differs or that the engine refused, with the engine's step;
- the files are checked to hold the NULLs, duplicates and absent keys the cases
  rely on, and the report of the runner is checked on plain lists.

    test_frame_join_window_duckdb.py --lib-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`.
"""

import importlib.util
import os
import sys
import tempfile


def _load_base():
    """duckdb/test_frame_duckdb.py, staged beside this file (python/tests/BUCK):
    its comparator, its left file and its Case type."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "duckdb", "test_frame_duckdb.py")
    spec = importlib.util.spec_from_file_location("test_frame_duckdb", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules["test_frame_duckdb"] = module
    spec.loader.exec_module(module)
    return module


base = _load_base()

import komira
from komira import _native

Case = base.Case

RIGHT_ROWS = 12
RIGHT_COLUMNS = ("k", "v", "s", "w")


# ---- the right file ----------------------------------------------------------


def right_values():
    """The right file's four columns as Python lists. k has the duplicates 2 and 3,
    the NULLs at rows 3 and 9, the keys 1, 2, 3, 0, -4 and 100 that the left file
    has, and 50 and 999, which it has not; (k, s) pairs (1, "alpha"), (-4, "alpha")
    and (100, "alpha") are also left rows; v and s share their names with the left
    file's, and w, with a NULL, is the right file's own."""
    return {
        "k": [1, 2, 2, None, 3, 3, 100, -4, 50, None, 0, 999],
        "v": [0.5, None, 1.5, -2.0, 2.5, 0.25, 3.0, -0.5, 4.0, 1.0, 0.0, 2.0],
        "s": ["alpha", "beta", "beta", None, "Zed", "gamma", "alpha", "alpha", "delta", "alpha", "été", "omega"],
        "w": [3, 4, 4, 5, 5, 8, 102, 2, -4, 4, 2, None],
    }


def write_right(path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    values = right_values()
    table = pa.table(
        {
            "k": pa.array(values["k"], pa.int64()),
            "v": pa.array(values["v"], pa.float64()),
            "s": pa.array(values["s"], pa.string()),
            "w": pa.array(values["w"], pa.int64()),
        }
    )
    pq.write_table(table, path, row_group_size=5)
    return path


# ---- the two sides -----------------------------------------------------------


def duckdb_for_two(left, right):
    import duckdb

    con = duckdb.connect()
    for name, path in (("t", left), ("o", right)):
        con.execute("CREATE VIEW {} AS SELECT * FROM read_parquet('{}')".format(name, path.replace("'", "''")))
    return con


def check_case(case, got, want):
    """None when komira's answer `got` is DuckDB's `want` for `case`, else the
    case's name and the first difference."""
    found = base.differences(got, want, case.order, set(case.untyped))
    if found is None:
        return None
    return "{}: komira's answer is not DuckDB's ({})".format(case.name, found)


def refused_by_the_engine(case, error):
    return "{}: the engine refused the program at step {}: {}".format(case.name, error.step, error)


def report(problems):
    """Raise one AssertionError naming every problem, when there is one."""
    assert not problems, "{} programs differ from DuckDB:\n{}".format(len(problems), "\n".join(problems))


def run_programs(left, right, cases):
    """Run each case's program over the frame `d` of the left file and `o` of
    the right one, and compare it with DuckDB's answer to the case's SQL."""
    con = duckdb_for_two(left, right)
    problems = []
    with komira.Session() as session:
        for case in cases:
            # Fresh frames per case: a program may assign by subscript.
            d = komira.read_parquet(left, session=session)
            o = komira.read_parquet(right, session=session)
            want = base.duckdb_answer(con, case.sql)
            assert bool(want[2]) != case.empty, "{}: DuckDB's answer has {} rows, not the {} the case expects".format(
                case.name, len(want[2]), "no" if case.empty else "some"
            )
            try:
                got = base.answer_of(case.program(d, o).materialize().to_arrow())
            except komira.KomiraError as e:
                problems.append(refused_by_the_engine(case, e))
                continue
            problem = check_case(case, got, want)
            if problem is not None:
                problems.append("{}; komira {}, DuckDB {}".format(problem, got, want))
    report(problems)


# ---- merge: the SQL of pandas' answer ----------------------------------------
# The columns of a merge on k: the left frame's, the right frame's after them, v
# and s suffixed on both sides. A NULL key matches nothing (the plain `=`).

BOTH_SUFFIXED = "t.v AS v_x, t.s AS s_x, t.flag, t.n, o.v AS v_y, o.s AS s_y, o.w"


def merge_on_k(kind, key=None, tail=BOTH_SUFFIXED):
    key = key or ("o.k" if kind == "RIGHT" else "t.k")
    return "SELECT {} AS k, {} FROM t {} JOIN o ON t.k = o.k".format(key, tail, kind)


INNER = merge_on_k("INNER")
LEFT = merge_on_k("LEFT")
RIGHT = merge_on_k("RIGHT")
OUTER = merge_on_k("FULL", "COALESCE(t.k, o.k)")

DIFFERENT_NAMES = (
    "SELECT t.k AS k_x, t.v AS v_x, t.s AS s_x, t.flag, t.n, o.k AS k_y, o.v AS v_y, o.s AS s_y, o.w "
    "FROM t {} JOIN o ON t.k = o.w"
)

MERGES = [
    Case("merge inner on k", lambda d, o: d.merge(o, on="k"), INNER),
    Case(
        "merge with no key named joins on the columns the frames share",
        lambda d, o: d.merge(o[["k", "s", "w"]]),
        "SELECT t.k, t.v, t.s, t.flag, t.n, o.w FROM t JOIN o ON t.k = o.k AND t.s = o.s",
    ),
    Case("merge left keeps every left row, the right columns NULL", lambda d, o: d.merge(o, on="k", how="left"), LEFT),
    Case("merge right keeps every right row and takes the right key", lambda d, o: d.merge(o, on="k", how="right"), RIGHT),
    Case("merge outer takes the key of the side that has one", lambda d, o: d.merge(o, on="k", how="outer"), OUTER),
    Case(
        "merge cross pairs every row, shared names suffixed",
        lambda d, o: d.merge(o, how="cross"),
        "SELECT t.k AS k_x, t.v AS v_x, t.s AS s_x, t.flag, t.n, o.k AS k_y, o.v AS v_y, o.s AS s_y, o.w "
        "FROM t CROSS JOIN o",
    ),
    Case(
        "merge with custom suffixes",
        lambda d, o: d.merge(o, on="k", suffixes=("_left", "_right")),
        "SELECT t.k, t.v AS v_left, t.s AS s_left, t.flag, t.n, o.v AS v_right, o.s AS s_right, o.w "
        "FROM t JOIN o ON t.k = o.k",
    ),
    Case(
        "merge with an empty left suffix keeps the left names",
        lambda d, o: d.merge(o, on="k", how="left", suffixes=("", "_o")),
        "SELECT t.k, t.v, t.s, t.flag, t.n, o.v AS v_o, o.s AS s_o, o.w FROM t LEFT JOIN o ON t.k = o.k",
    ),
    Case(
        "merge with a None right suffix keeps the right names",
        lambda d, o: d.merge(o[["k", "w", "v"]], on="k", suffixes=("_l", None)),
        "SELECT t.k, t.v AS v_l, t.s, t.flag, t.n, o.w, o.v FROM t JOIN o ON t.k = o.k",
    ),
    Case(
        "merge left_on k and right_on w, two different names",
        lambda d, o: d.merge(o, left_on="k", right_on="w"),
        DIFFERENT_NAMES.format("INNER"),
    ),
    Case(
        "merge left with left_on and right_on",
        lambda d, o: d.merge(o, how="left", left_on="k", right_on="w"),
        DIFFERENT_NAMES.format("LEFT"),
    ),
    Case(
        "merge outer with left_on and right_on keeps both key columns",
        lambda d, o: d.merge(o, how="outer", left_on="k", right_on="w"),
        DIFFERENT_NAMES.format("FULL"),
    ),
    Case(
        "merge on two keys, a int and a string",
        lambda d, o: d.merge(o, on=["k", "s"]),
        "SELECT t.k, t.v AS v_x, t.s, t.flag, t.n, o.v AS v_y, o.w FROM t JOIN o ON t.k = o.k AND t.s = o.s",
    ),
    Case(
        "merge left on two keys",
        lambda d, o: d.merge(o, on=["k", "s"], how="left"),
        "SELECT t.k, t.v AS v_x, t.s, t.flag, t.n, o.v AS v_y, o.w FROM t LEFT JOIN o ON t.k = o.k AND t.s = o.s",
    ),
    Case(
        "merge outer on two keys takes each key from the side that has one",
        lambda d, o: d.merge(o, on=["k", "s"], how="outer"),
        "SELECT COALESCE(t.k, o.k) AS k, t.v AS v_x, COALESCE(t.s, o.s) AS s, t.flag, t.n, o.v AS v_y, o.w "
        "FROM t FULL JOIN o ON t.k = o.k AND t.s = o.s",
    ),
    Case(
        "merge on a shared int key and two differently named keys",
        lambda d, o: d.assign(j=d["k"] + 2).merge(o, left_on=["k", "j"], right_on=["k", "w"]),
        "SELECT t.k, t.v AS v_x, t.s AS s_x, t.flag, t.n, t.k + 2 AS j, o.v AS v_y, o.s AS s_y, o.w "
        "FROM t JOIN o ON t.k = o.k AND t.k + 2 = o.w",
    ),
    Case(
        "merge of the left file with itself on k",
        lambda d, o: d.merge(d, on="k"),
        "SELECT a.k, a.v AS v_x, a.s AS s_x, a.flag AS flag_x, a.n AS n_x, b.v AS v_y, b.s AS s_y, "
        "b.flag AS flag_y, b.n AS n_y FROM t a JOIN t b ON a.k = b.k",
    ),
    Case(
        "merge of the left file with itself on its unique n, left",
        lambda d, o: d.merge(d[d["k"] > 0], on="n", how="left"),
        "SELECT a.k AS k_x, a.v AS v_x, a.s AS s_x, a.flag AS flag_x, a.n, b.k AS k_y, b.v AS v_y, b.s AS s_y, "
        "b.flag AS flag_y FROM t a LEFT JOIN (SELECT * FROM t WHERE k > 0) b ON a.n = b.n",
    ),
    Case(
        "merge with sort=True sorts by the key, NULLs last",
        lambda d, o: d.merge(o, on="k", how="left", sort=True),
        LEFT + " ORDER BY k ASC NULLS LAST",
        ("k",),
    ),
    Case(
        "merge outer with sort=True sorts by the combined key",
        lambda d, o: d.merge(o, on="k", how="outer", sort=True),
        OUTER + " ORDER BY k ASC NULLS LAST",
        ("k",),
    ),
    Case(
        "merge right with sort=True sorts by the right key",
        lambda d, o: d.merge(o, on="k", how="right", sort=True),
        RIGHT + " ORDER BY k ASC NULLS LAST",
        ("k",),
    ),
    Case(
        "merge of a sorted frame answers in no order",
        lambda d, o: d.sort_values("n", ascending=False).merge(o, on="k"),
        INNER,
    ),
    Case(
        "merge then a filter on a right column",
        lambda d, o: on(d.merge(o, on="k", how="left"), lambda m: m[m["w"] > 3]),
        "SELECT * FROM ({}) WHERE w > 3".format(LEFT),
    ),
    Case(
        "merge then a filter on the key",
        lambda d, o: on(d.merge(o, on="k", how="outer"), lambda m: m[m["k"] > 0]),
        "SELECT * FROM ({}) WHERE k > 0".format(OUTER),
    ),
    Case(
        "merge then assign of a left and a right column",
        lambda d, o: on(d.merge(o, on="k"), lambda m: m.assign(total=m["n"] + m["w"], both=m["v_x"] + m["v_y"])),
        "SELECT *, n + w AS total, v_x + v_y AS both FROM ({})".format(INNER),
    ),
    Case(
        "merge then groupby of the right column",
        lambda d, o: d.merge(o, on="k").groupby("k")["w"].sum(),
        "SELECT k, CAST(COALESCE(SUM(w), 0) AS BIGINT) AS w FROM ({}) WHERE k IS NOT NULL GROUP BY k "
        "ORDER BY k ASC NULLS LAST".format(INNER),
        ("k",),
    ),
    Case(
        "merge left then groupby size keeps the NULL key group last",
        lambda d, o: d.merge(o, on="k", how="left").groupby("k", dropna=False).size(),
        'SELECT k, COUNT(*) AS "size" FROM ({}) GROUP BY k ORDER BY k ASC NULLS LAST'.format(LEFT),
        ("k",),
    ),
    Case(
        "merge then a window over the merged columns",
        lambda d, o: on(d.merge(o, on="k"), lambda m: m.assign(rows=m.groupby("k")["w"].transform("count"))),
        "SELECT *, COUNT(w) OVER (PARTITION BY k) AS rows FROM ({})".format(INNER),
    ),
    Case(
        "merge of filtered and projected frames",
        lambda d, o: d[d["k"] > 0][["k", "n"]].merge(o[o["w"] > 2][["k", "w"]], on="k"),
        "SELECT t.k, t.n, o.w FROM (SELECT k, n FROM t WHERE k > 0) t JOIN (SELECT k, w FROM o WHERE w > 2) o "
        "ON t.k = o.k",
    ),
    Case(
        "merge of a projected right frame renames nothing it does not share",
        lambda d, o: d[["k", "n"]].merge(o[["w", "k"]], on="k", how="left"),
        "SELECT t.k, t.n, o.w FROM (SELECT k, n FROM t) t LEFT JOIN (SELECT w, k FROM o) o ON t.k = o.k",
    ),
    Case(
        "merge of frames that match nothing keeps the names and types",
        lambda d, o: d[d["k"] > 1000].merge(o, on="k"),
        INNER.replace("FROM t INNER JOIN", "FROM (SELECT * FROM t WHERE k > 1000) t INNER JOIN"),
        None,
        True,
    ),
    Case(
        "merge left of an empty right frame keeps every left row",
        lambda d, o: d.merge(o[o["w"] > 1000], on="k", how="left"),
        LEFT.replace("JOIN o ", "JOIN (SELECT * FROM o WHERE w > 1000) o "),
    ),
]


def on(frame, step):
    return step(frame)


# ---- merge: where the NULL keys sit ------------------------------------------
# Both files have NULL keys. The SQL is the plain `=`, under which a NULL key
# equals nothing: the documented departure from pandas (ruling 7), which pairs
# a left NULL with a right NULL. The two NULL-keyed right rows and the four
# NULL-keyed left rows appear once each in an outer merge, never paired.

NULL_KEYS = [
    Case(
        "NULL keys on both sides stay apart in an outer merge",
        lambda d, o: d.merge(o, on="k", how="outer"),
        OUTER,
    ),
    Case(
        "NULL keys on both sides stay apart under left_on and right_on of one name",
        lambda d, o: d.merge(o, how="outer", left_on="k", right_on="k"),
        OUTER,
    ),
]


# ---- isin of a Series: the semi and anti join --------------------------------

SEMI = "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM o WHERE o.k = t.k)"
ANTI = "SELECT * FROM t WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.k = t.k)"

SEMI_ANTI = [
    Case("isin another frame's column is a semi join", lambda d, o: d[d["k"].isin(o["k"])], SEMI),
    Case(
        "not isin another frame's column is an anti join keeping the NULL-keyed rows",
        lambda d, o: d[~d["k"].isin(o["k"])],
        ANTI,
    ),
    Case(
        "a semi join keeps a left row once however many right rows match",
        lambda d, o: d[d["k"].isin(o["k"])][["k", "n"]],
        "SELECT k, n FROM t WHERE EXISTS (SELECT 1 FROM o WHERE o.k = t.k)",
    ),
    Case(
        "isin the frame's own filtered column",
        lambda d, o: d[d["k"].isin(d[d["v"] > 0.0]["k"])],
        "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM t u WHERE u.v > 0.0 AND u.k = t.k)",
    ),
    Case(
        "not isin the frame's own filtered column",
        lambda d, o: d[~d["k"].isin(d[d["v"] > 0.0]["k"])],
        "SELECT * FROM t WHERE NOT EXISTS (SELECT 1 FROM t u WHERE u.v > 0.0 AND u.k = t.k)",
    ),
    Case(
        "isin a filtered column of the other frame",
        lambda d, o: d[d["k"].isin(o[o["v"] > 0.0]["k"])],
        "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM o WHERE o.v > 0.0 AND o.k = t.k)",
    ),
    Case(
        "isin an expression of the other frame",
        lambda d, o: d[d["k"].isin(o["w"] + 1)],
        "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM o WHERE o.w + 1 = t.k)",
    ),
    Case(
        "not isin an expression of the other frame",
        lambda d, o: d[~d["k"].isin(o["w"] + 1)],
        "SELECT * FROM t WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.w + 1 = t.k)",
    ),
    Case(
        "isin a column of another name",
        lambda d, o: d[d["k"].isin(o["w"])],
        "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM o WHERE o.w = t.k)",
    ),
    Case(
        "isin a string column",
        lambda d, o: d[d["s"].isin(o["s"])],
        "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM o WHERE o.s = t.s)",
    ),
    Case(
        "not isin a string column keeps the NULL strings",
        lambda d, o: d[~d["s"].isin(o["s"])],
        "SELECT * FROM t WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.s = t.s)",
    ),
    Case(
        "a sorted frame keeps its order through a semi join",
        lambda d, o: on(d.sort_values("n", ascending=False), lambda s: s[s["k"].isin(o["k"])]),
        SEMI + " ORDER BY n DESC",
        ("n",),
    ),
    Case(
        "a sorted frame keeps its order through an anti join",
        lambda d, o: on(d.sort_values("k"), lambda s: s[~s["k"].isin(o["k"])]),
        ANTI + " ORDER BY k ASC NULLS LAST",
        ("k",),
    ),
    Case(
        "a sorted other frame sends its rows without their order",
        lambda d, o: d[d["k"].isin(o.sort_values("w")["k"])],
        SEMI,
    ),
    Case(
        "a semi join then a sort",
        lambda d, o: d[d["k"].isin(o["k"])].sort_values("n"),
        SEMI + " ORDER BY n",
        ("n",),
    ),
    Case(
        "a semi join of a filtered frame",
        lambda d, o: on(d[d["v"] > 0.0], lambda f: f[f["k"].isin(o["k"])]),
        "SELECT * FROM t WHERE v > 0.0 AND EXISTS (SELECT 1 FROM o WHERE o.k = t.k)",
    ),
    Case(
        "an anti join then a filter and a projection",
        lambda d, o: on(d[~d["k"].isin(o["k"])], lambda f: f[f["n"] > 10][["n", "k"]]),
        "SELECT n, k FROM t WHERE n > 10 AND NOT EXISTS (SELECT 1 FROM o WHERE o.k = t.k)",
    ),
    Case(
        "an anti join then a groupby",
        lambda d, o: d[~d["k"].isin(o["k"])].groupby("k")["n"].count(),
        "SELECT k, COUNT(n) AS n FROM t WHERE k IS NOT NULL AND NOT EXISTS (SELECT 1 FROM o WHERE o.k = t.k) "
        "GROUP BY k ORDER BY k ASC NULLS LAST",
        ("k",),
    ),
    Case(
        "an anti join where the right side holds only a NULL key keeps every left row",
        lambda d, o: d[~d["k"].isin(o[o["v"] == -2.0]["k"])],
        "SELECT * FROM t WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.v = -2.0 AND o.k = t.k)",
    ),
    Case(
        "a semi join where the right side holds only a NULL key matches nothing",
        lambda d, o: d[d["k"].isin(o[o["v"] == -2.0]["k"])],
        "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM o WHERE o.v = -2.0 AND o.k = t.k)",
        None,
        True,
    ),
    Case(
        "a semi join with a right side that has no rows matches nothing",
        lambda d, o: d[d["k"].isin(o[o["w"] > 1000]["k"])],
        "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM o WHERE o.w > 1000 AND o.k = t.k)",
        None,
        True,
    ),
    Case(
        "an anti join with a right side that has no rows keeps every row",
        lambda d, o: d[~d["k"].isin(o[o["w"] > 1000]["k"])],
        "SELECT * FROM t WHERE NOT EXISTS (SELECT 1 FROM o WHERE o.w > 1000 AND o.k = t.k)",
    ),
]


# ---- windows -----------------------------------------------------------------

RUNNING = "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW"


def partition(keys):
    return "PARTITION BY {} ".format(keys) if keys else ""


def present(*columns):
    return " AND ".join("{} IS NOT NULL".format(c) for c in columns)


def per_row(expr, *guards, name="m", where="", order=""):
    """`SELECT *, CASE WHEN <guards> THEN expr END AS name FROM t`: a window's
    value, missing where a guard column is."""
    value = "CASE WHEN {} THEN {} END".format(present(*guards), expr) if guards else expr
    return "SELECT *, {} AS {} FROM t{}{}".format(value, name, where, order)


def transform_sql(func, column, keys, dropna=True, cast=""):
    agg = {"sum": "COALESCE(SUM({}) OVER (PARTITION BY {}), 0)", "mean": "AVG({}) OVER (PARTITION BY {})"}.get(
        func, func.upper() + "({}) OVER (PARTITION BY {})"
    )
    expr = agg.format(column, keys)
    if cast:
        expr = "CAST({} AS {})".format(expr, cast)
    return per_row(expr, *((keys,) if dropna else ()))


def cum_sql(func, column, keys=None, direction="ASC", cast=""):
    expr = "{}({}) OVER ({}ORDER BY n {} {})".format(func, column, partition(keys), direction, RUNNING)
    if cast:
        expr = "CAST({} AS {})".format(expr, cast)
    return per_row(expr, column, *((keys,) if keys else ()), name="c", order=" ORDER BY n " + direction)


def rank_sql(func, column, direction="ASC", keys=None, bottom=False):
    expr = "CAST({}() OVER ({}ORDER BY {} {} NULLS LAST) AS DOUBLE)".format(
        func, partition(keys), column, direction
    )
    guards = (() if bottom else (column,)) + ((keys,) if keys else ())
    return per_row(expr, *guards, name="r")


def rolling_sql(func, column, rows, least, where="", direction="ASC"):
    frame = (
        "ROWS BETWEEN CURRENT ROW AND CURRENT ROW" if rows == 1 else "ROWS BETWEEN {} PRECEDING AND CURRENT ROW".format(rows - 1)
    )
    window = "(ORDER BY n {} {})".format(direction, frame)
    expr = "CAST({}({}) OVER {} AS DOUBLE)".format(func, column, window)
    if least > 1:
        expr = "CASE WHEN COUNT({}) OVER {} >= {} THEN {} END".format(column, window, least, expr)
    return "SELECT *, {} AS r FROM t{} ORDER BY n {}".format(expr, where, direction)


def sorted_by_n(d):
    return d.sort_values("n")


def column_of(frame, name, make):
    return frame.assign(**{name: make(frame)})


TRANSFORMS = [
    Case(
        "transform sum of a float by k is 0 for an all-NULL group, NULL where k is NULL",
        lambda d, o: d.assign(m=d.groupby("k")["v"].transform("sum")),
        transform_sql("sum", "v", "k"),
    ),
    Case(
        "transform mean by k",
        lambda d, o: d.assign(m=d.groupby("k")["v"].transform("mean")),
        transform_sql("mean", "v", "k"),
    ),
    Case(
        "transform min by k",
        lambda d, o: d.assign(m=d.groupby("k")["v"].transform("min")),
        transform_sql("min", "v", "k"),
    ),
    Case(
        "transform max by k",
        lambda d, o: d.assign(m=d.groupby("k")["v"].transform("max")),
        transform_sql("max", "v", "k"),
    ),
    Case(
        "transform count by k",
        lambda d, o: d.assign(m=d.groupby("k")["v"].transform("count")),
        transform_sql("count", "v", "k"),
    ),
    Case(
        "transform sum of an int by a string key",
        lambda d, o: d.assign(m=d.groupby("s")["k"].transform("sum")),
        transform_sql("sum", "k", "s", cast="BIGINT"),
    ),
    Case(
        "transform max of an int by a bool key",
        lambda d, o: d.assign(m=d.groupby("flag")["k"].transform("max")),
        transform_sql("max", "k", "flag"),
    ),
    Case(
        "transform mean of an int by two keys",
        lambda d, o: d.assign(m=d.groupby(["flag", "s"])["k"].transform("mean")),
        per_row("AVG(k) OVER (PARTITION BY flag, s)", "flag", "s"),
    ),
    Case(
        "transform sum with dropna=False computes the NULL group",
        lambda d, o: d.assign(m=d.groupby("k", dropna=False)["v"].transform("sum")),
        transform_sql("sum", "v", "k", dropna=False),
    ),
    Case(
        "transform count with dropna=False counts the NULL group",
        lambda d, o: d.assign(m=d.groupby("k", dropna=False)["v"].transform("count")),
        transform_sql("count", "v", "k", dropna=False),
    ),
    Case(
        "transform mean with dropna=False gives the NULL group its mean",
        lambda d, o: d.assign(m=d.groupby("k", dropna=False)["v"].transform("mean")),
        transform_sql("mean", "v", "k", dropna=False),
    ),
    Case(
        "transform as a new column keeps the sorted frame's order",
        lambda d, o: on(d.sort_values("n"), lambda s: s.assign(m=s.groupby("k")["v"].transform("max"))),
        transform_sql("max", "v", "k").replace("FROM t", "FROM t ORDER BY n"),
        ("n",),
    ),
    Case(
        "transform replacing a column in place",
        lambda d, o: d.assign(v=d.groupby("k")["v"].transform("min")),
        "SELECT * REPLACE (CASE WHEN k IS NOT NULL THEN MIN(v) OVER (PARTITION BY k) END AS v) FROM t",
    ),
    Case(
        "transform assigned by subscript",
        lambda d, o: on(d, subscript_transform),
        transform_sql("count", "v", "k"),
    ),
]


def subscript_transform(d):
    d["m"] = d.groupby("k")["v"].transform("count")
    return d


CUMULATIVES = [
    Case(
        "cumsum down a frame sorted with its missing keys first",
        lambda d, o: column_of(d.sort_values(["k", "n"], na_position="first"), "c", lambda s: s["v"].cumsum()),
        "SELECT *, CASE WHEN v IS NOT NULL THEN SUM(v) OVER (ORDER BY k ASC NULLS FIRST, n ASC NULLS FIRST {}) END "
        "AS c FROM t ORDER BY k ASC NULLS FIRST, n ASC NULLS FIRST".format(RUNNING),
        ("k", "n"),
    ),
    Case(
        "cumsum of a float down the frame sorted by n",
        lambda d, o: column_of(sorted_by_n(d), "c", lambda s: s["v"].cumsum()),
        cum_sql("SUM", "v"),
        ("n",),
    ),
    Case(
        "cummin of a float down the frame sorted by n",
        lambda d, o: column_of(sorted_by_n(d), "c", lambda s: s["v"].cummin()),
        cum_sql("MIN", "v"),
        ("n",),
    ),
    Case(
        "cummax of a float down the frame sorted by n",
        lambda d, o: column_of(sorted_by_n(d), "c", lambda s: s["v"].cummax()),
        cum_sql("MAX", "v"),
        ("n",),
    ),
    Case(
        "cumsum of an int stays NULL where the int is NULL",
        lambda d, o: column_of(sorted_by_n(d), "c", lambda s: s["k"].cumsum()),
        cum_sql("SUM", "k", cast="BIGINT"),
        ("n",),
    ),
    Case(
        "cummin of an int",
        lambda d, o: column_of(sorted_by_n(d), "c", lambda s: s["k"].cummin()),
        cum_sql("MIN", "k"),
        ("n",),
    ),
    Case(
        "cummax of an int",
        lambda d, o: column_of(sorted_by_n(d), "c", lambda s: s["k"].cummax()),
        cum_sql("MAX", "k"),
        ("n",),
    ),
    Case(
        "cumsum down the frame sorted by n descending",
        lambda d, o: column_of(d.sort_values("n", ascending=False), "c", lambda s: s["v"].cumsum()),
        cum_sql("SUM", "v", direction="DESC"),
        ("n",),
    ),
    Case(
        "cummax down the frame sorted by n descending",
        lambda d, o: column_of(d.sort_values("n", ascending=False), "c", lambda s: s["k"].cummax()),
        cum_sql("MAX", "k", direction="DESC"),
        ("n",),
    ),
    Case(
        "cumsum of a float within each k",
        lambda d, o: column_of(sorted_by_n(d), "c", lambda s: s.groupby("k")["v"].cumsum()),
        cum_sql("SUM", "v", "k"),
        ("n",),
    ),
    Case(
        "cummin of an int within each string",
        lambda d, o: column_of(sorted_by_n(d), "c", lambda s: s.groupby("s")["k"].cummin()),
        cum_sql("MIN", "k", "s"),
        ("n",),
    ),
    Case(
        "cummax of a float within each bool",
        lambda d, o: column_of(sorted_by_n(d), "c", lambda s: s.groupby("flag")["v"].cummax()),
        cum_sql("MAX", "v", "flag"),
        ("n",),
    ),
    Case(
        "cumsum of an int within each bool, descending",
        lambda d, o: column_of(d.sort_values("n", ascending=False), "c", lambda s: s.groupby("flag")["k"].cumsum()),
        cum_sql("SUM", "k", "flag", direction="DESC", cast="BIGINT"),
        ("n",),
    ),
    Case(
        "cumsum after a filter runs over the rows left",
        lambda d, o: column_of(sorted_by_n(d[d["k"] > 0]), "c", lambda s: s["v"].cumsum()),
        cum_sql("SUM", "v").replace("FROM t", "FROM t WHERE k > 0"),
        ("n",),
    ),
]

RANKS = [
    Case(
        "rank min of an int ascending, NULL for a NULL",
        lambda d, o: d.assign(r=d["k"].rank(method="min")),
        rank_sql("RANK", "k"),
    ),
    Case(
        "rank dense of an int ascending",
        lambda d, o: d.assign(r=d["k"].rank(method="dense")),
        rank_sql("DENSE_RANK", "k"),
    ),
    Case(
        "rank min of a float descending",
        lambda d, o: d.assign(r=d["v"].rank(method="min", ascending=False)),
        rank_sql("RANK", "v", "DESC"),
    ),
    Case(
        "rank dense of a float descending",
        lambda d, o: d.assign(r=d["v"].rank(method="dense", ascending=False)),
        rank_sql("DENSE_RANK", "v", "DESC"),
    ),
    Case(
        "rank min with na_option bottom ranks the NULLs after every value, tied",
        lambda d, o: d.assign(r=d["k"].rank(method="min", na_option="bottom")),
        rank_sql("RANK", "k", bottom=True),
    ),
    Case(
        "rank min with na_option top ranks the NULLs before every value, tied at 1",
        lambda d, o: d.assign(r=d["k"].rank(method="min", na_option="top")),
        "SELECT *, CAST(RANK() OVER (ORDER BY k ASC NULLS FIRST) AS DOUBLE) AS r FROM t",
    ),
    Case(
        "rank dense with na_option top, descending",
        lambda d, o: d.assign(r=d["v"].rank(method="dense", ascending=False, na_option="top")),
        "SELECT *, CAST(DENSE_RANK() OVER (ORDER BY v DESC NULLS FIRST) AS DOUBLE) AS r FROM t",
    ),
    Case(
        "rank dense with na_option bottom, descending",
        lambda d, o: d.assign(r=d["v"].rank(method="dense", ascending=False, na_option="bottom")),
        rank_sql("DENSE_RANK", "v", "DESC", bottom=True),
    ),
    Case(
        "rank min within each bool",
        lambda d, o: d.assign(r=d.groupby("flag")["v"].rank(method="min")),
        rank_sql("RANK", "v", keys="flag"),
    ),
    Case(
        "rank dense within each k, descending",
        lambda d, o: d.assign(r=d.groupby("k")["v"].rank(method="dense", ascending=False)),
        rank_sql("DENSE_RANK", "v", "DESC", keys="k"),
    ),
    Case(
        "rank min of the unique n within each bool, na_option bottom",
        lambda d, o: d.assign(r=d.groupby("flag")["n"].rank(method="min", na_option="bottom")),
        rank_sql("RANK", "n", keys="flag", bottom=True),
    ),
    Case(
        "rank of a column of a sorted frame keeps the frame's order",
        lambda d, o: column_of(d.sort_values("n"), "r", lambda s: s["v"].rank(method="min")),
        rank_sql("RANK", "v").replace("FROM t", "FROM t ORDER BY n"),
        ("n",),
    ),
]

ROLLINGS = [
    Case(
        "rolling 3 sum, NULL until three rows hold a value",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(3).sum()),
        rolling_sql("SUM", "v", 3, 3),
        ("n",),
    ),
    Case(
        "rolling 3 mean",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(3).mean()),
        rolling_sql("AVG", "v", 3, 3),
        ("n",),
    ),
    Case(
        "rolling 3 min",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(3).min()),
        rolling_sql("MIN", "v", 3, 3),
        ("n",),
    ),
    Case(
        "rolling 3 max",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(3).max()),
        rolling_sql("MAX", "v", 3, 3),
        ("n",),
    ),
    Case(
        "rolling 3 sum with min_periods 1 answers from the first row",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(3, min_periods=1).sum()),
        rolling_sql("SUM", "v", 3, 1),
        ("n",),
    ),
    Case(
        "rolling 3 mean with min_periods 1",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(3, min_periods=1).mean()),
        rolling_sql("AVG", "v", 3, 1),
        ("n",),
    ),
    Case(
        "rolling 3 max with min_periods 2",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(3, min_periods=2).max()),
        rolling_sql("MAX", "v", 3, 2),
        ("n",),
    ),
    Case(
        "rolling 3 min with min_periods 2",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(3, min_periods=2).min()),
        rolling_sql("MIN", "v", 3, 2),
        ("n",),
    ),
    Case(
        "rolling 2 sum with min_periods 2 equals the default",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(2, min_periods=2).sum()),
        rolling_sql("SUM", "v", 2, 2),
        ("n",),
    ),
    Case(
        "rolling 1 is the value itself as a float",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].rolling(1).sum()),
        rolling_sql("SUM", "v", 1, 1),
        ("n",),
    ),
    Case(
        "rolling 3 mean of an int is a float",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["k"].rolling(3, min_periods=2).mean()),
        rolling_sql("AVG", "k", 3, 2),
        ("n",),
    ),
    Case(
        "rolling 2 sum of an int on the frame sorted descending",
        lambda d, o: column_of(d.sort_values("n", ascending=False), "r", lambda s: s["k"].rolling(2, min_periods=1).sum()),
        rolling_sql("SUM", "k", 2, 1, direction="DESC"),
        ("n",),
    ),
    Case(
        "rolling after a filter runs over the rows left",
        lambda d, o: column_of(sorted_by_n(d[d["k"] > 0]), "r", lambda s: s["v"].rolling(3, min_periods=1).mean()),
        rolling_sql("AVG", "v", 3, 1, where=" WHERE k > 0"),
        ("n",),
    ),
]

def offset_sql(expr, direction="ASC", where=""):
    """`SELECT *, expr AS r FROM t`, the rows in the order of n."""
    return "SELECT *, {} AS r FROM t{} ORDER BY n {}".format(expr, where, direction)


SHIFTS = [
    Case(
        "shift 1 of an int column with NULLs is LAG, NULL on the first row",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["k"].shift(1)),
        offset_sql("LAG(k) OVER (ORDER BY n)"),
        ("n",),
    ),
    Case(
        "shift -1 is LEAD, NULL on the last row",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["k"].shift(-1)),
        offset_sql("LEAD(k) OVER (ORDER BY n)"),
        ("n",),
    ),
    Case(
        "shift 3 of a float column with NULLs",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].shift(3)),
        offset_sql("LAG(v, 3) OVER (ORDER BY n)"),
        ("n",),
    ),
    Case(
        "shift 2 of a string column",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["s"].shift(2)),
        offset_sql("LAG(s, 2) OVER (ORDER BY n)"),
        ("n",),
    ),
    Case(
        "shift 0 is the column",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["k"].shift(0)),
        offset_sql("k"),
        ("n",),
    ),
    Case(
        "shift 1 down the frame sorted by n descending",
        lambda d, o: column_of(d.sort_values("n", ascending=False), "r", lambda s: s["k"].shift(1)),
        offset_sql("LAG(k) OVER (ORDER BY n DESC)", "DESC"),
        ("n",),
    ),
    Case(
        "diff of an int column is the change from the row before as a double",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["k"].diff()),
        offset_sql("CAST(k - LAG(k) OVER (ORDER BY n) AS DOUBLE)"),
        ("n",),
    ),
    Case(
        "diff -2 of a float column is the change to the row two after",
        lambda d, o: column_of(sorted_by_n(d), "r", lambda s: s["v"].diff(-2)),
        offset_sql("v - LEAD(v, 2) OVER (ORDER BY n)"),
        ("n",),
    ),
    Case(
        "pct_change of a float column where no previous value is 0",
        lambda d, o: on(sorted_by_n(d), lambda s: s[s["v"] != 0].assign(r=lambda f: f["v"].pct_change())),
        "SELECT *, v / LAG(v) OVER (ORDER BY n) - 1 AS r FROM t WHERE v <> 0 ORDER BY n",
        ("n",),
    ),
    Case(
        "a filter by diff keeps the rows that rose",
        lambda d, o: on(sorted_by_n(d), lambda s: s[s["k"].diff() > 0]),
        "SELECT k, v, s, flag, n FROM (SELECT *, k - LAG(k) OVER (ORDER BY n) AS dk FROM t) WHERE dk > 0 ORDER BY n",
        ("n",),
    ),
]


IN_EXPRESSIONS = [
    Case(
        "a value minus its group's mean",
        lambda d, o: d.assign(dev=d["v"] - d.groupby("k")["v"].transform("mean")),
        "SELECT *, v - CASE WHEN k IS NOT NULL THEN AVG(v) OVER (PARTITION BY k) END AS dev FROM t",
    ),
    Case(
        "a group's range from two windows in one expression",
        lambda d, o: d.assign(spread=d.groupby("k")["v"].transform("max") - d.groupby("k")["v"].transform("min")),
        "SELECT *, CASE WHEN k IS NOT NULL THEN MAX(v) OVER (PARTITION BY k) END "
        "- CASE WHEN k IS NOT NULL THEN MIN(v) OVER (PARTITION BY k) END AS spread FROM t",
    ),
    Case(
        "a window against a literal",
        lambda d, o: d.assign(big=d.groupby("k")["v"].transform("count") > 2),
        "SELECT *, CASE WHEN k IS NOT NULL THEN COUNT(v) OVER (PARTITION BY k) END > 2 AS big FROM t",
    ),
    Case(
        "rows ranked in the lowest five, NULLs ranked last",
        lambda d, o: d[d["k"].rank(method="min", na_option="bottom") <= 5],
        "SELECT k, v, s, flag, n FROM (SELECT *, CAST(RANK() OVER (ORDER BY k ASC NULLS LAST) AS DOUBLE) AS r FROM t) "
        "WHERE r <= 5",
    ),
    Case(
        "rows of a group with more than two rows, the NULL group counted",
        lambda d, o: d[d.groupby("k", dropna=False)["v"].transform("count") > 2],
        "SELECT k, v, s, flag, n FROM (SELECT *, COUNT(v) OVER (PARTITION BY k) AS m FROM t) WHERE m > 2",
    ),
    Case(
        "rows whose rolling sum of three, from one value, exceeds one, in the frame's order",
        lambda d, o: on(sorted_by_n(d), lambda s: s[s["v"].rolling(3, min_periods=1).sum() > 1.0]),
        "SELECT k, v, s, flag, n FROM (SELECT *, CAST(SUM(v) OVER (ORDER BY n ROWS BETWEEN 2 PRECEDING AND CURRENT ROW) "
        "AS DOUBLE) AS r FROM t) WHERE r > 1.0 ORDER BY n",
        ("n",),
    ),
    Case(
        "two windows in one assign",
        lambda d, o: d.assign(hi=d.groupby("k")["v"].transform("max"), lo=d.groupby("k")["v"].transform("min")),
        "SELECT *, CASE WHEN k IS NOT NULL THEN MAX(v) OVER (PARTITION BY k) END AS hi, "
        "CASE WHEN k IS NOT NULL THEN MIN(v) OVER (PARTITION BY k) END AS lo FROM t",
    ),
    Case(
        "a window and a column of the same assign",
        lambda d, o: d.assign(m=d.groupby("k")["v"].transform("count"), dbl=d["n"] * 2),
        "SELECT *, CASE WHEN k IS NOT NULL THEN COUNT(v) OVER (PARTITION BY k) END AS m, n * 2 AS dbl FROM t",
    ),
    Case(
        "a running sum and a rank of the sorted frame in one assign",
        lambda d, o: on(
            d.sort_values("n"), lambda s: s.assign(c=s["v"].cumsum(), r=s["k"].rank(method="dense"))
        ),
        "SELECT *, CASE WHEN v IS NOT NULL THEN SUM(v) OVER (ORDER BY n {}) END AS c, "
        "CASE WHEN k IS NOT NULL THEN CAST(DENSE_RANK() OVER (ORDER BY k ASC NULLS LAST) AS DOUBLE) END AS r "
        "FROM t ORDER BY n".format(RUNNING),
        ("n",),
    ),
    Case(
        "a window of a window's column",
        lambda d, o: on(
            d.assign(m=d.groupby("k")["v"].transform("count")), lambda f: f.assign(r=f["m"].rank(method="min"))
        ),
        "SELECT *, CASE WHEN m IS NOT NULL THEN CAST(RANK() OVER (ORDER BY m ASC NULLS LAST) AS DOUBLE) END AS r "
        "FROM (SELECT *, CASE WHEN k IS NOT NULL THEN COUNT(v) OVER (PARTITION BY k) END AS m FROM t)",
    ),
]

# Filters whose predicate reads a window under a CASE (a window of a group with
# dropna=True, or of a column that keeps its NULLs): komira projects the
# predicate as a column and filters by that column, since the engine's filter
# takes no CASE in its predicate.
CASE_FILTERS = [
    Case(
        "rows above their group's mean",
        lambda d, o: d[d["v"] > d.groupby("k")["v"].transform("mean")],
        "SELECT k, v, s, flag, n FROM (SELECT *, CASE WHEN k IS NOT NULL THEN AVG(v) OVER (PARTITION BY k) END AS m "
        "FROM t) WHERE v > m",
    ),
    Case(
        "rows of a group with more than two rows",
        lambda d, o: d[d.groupby("k")["v"].transform("count") > 2],
        "SELECT k, v, s, flag, n FROM (SELECT *, CASE WHEN k IS NOT NULL THEN COUNT(v) OVER (PARTITION BY k) END AS m "
        "FROM t) WHERE m > 2",
    ),
    Case(
        "a filter by a window keeps the frame's sort order",
        lambda d, o: on(d.sort_values("n"), lambda s: s[s["v"] > s.groupby("k")["v"].transform("mean")]),
        "SELECT k, v, s, flag, n FROM (SELECT *, CASE WHEN k IS NOT NULL THEN AVG(v) OVER (PARTITION BY k) END AS m "
        "FROM t) WHERE v > m ORDER BY n",
        ("n",),
    ),
    Case(
        "a filter by a window of a filtered frame",
        lambda d, o: on(d[d["n"] > 10], lambda f: f[f["v"] < f.groupby("k")["v"].transform("max")]),
        "SELECT k, v, s, flag, n FROM (SELECT *, CASE WHEN k IS NOT NULL THEN MAX(v) OVER (PARTITION BY k) END AS m "
        "FROM t WHERE n > 10) WHERE v < m",
    ),
    Case(
        "a filter by a running maximum",
        lambda d, o: on(sorted_by_n(d), lambda s: s[s["v"].cummax() == s["v"]]),
        "SELECT k, v, s, flag, n FROM (SELECT *, CASE WHEN v IS NOT NULL THEN MAX(v) OVER (ORDER BY n {}) END AS m "
        "FROM t) WHERE m = v ORDER BY n".format(RUNNING),
        ("n",),
    ),
]


# ---- the tests that run frames -----------------------------------------------


def test_merges_equal_duckdb_joins(left, right):
    run_programs(left, right, MERGES)


def test_null_keys_match_nothing_as_in_sql_equality(left, right):
    run_programs(left, right, NULL_KEYS)


def test_an_outer_merge_holds_each_null_key_row_once_unpaired(left, right):
    lv, rv = base.column_values(), right_values()
    with komira.Session() as session:
        d = komira.read_parquet(left, session=session)
        o = komira.read_parquet(right, session=session)
        names, _, rows = base.answer_of(d.merge(o, on="k", how="outer").materialize().to_arrow())
    assert names == ["k", "v_x", "s_x", "flag", "n", "v_y", "s_y", "w"], names
    missing = [r for r in rows if r[0] is None]
    assert len(missing) == lv["k"].count(None) + rv["k"].count(None), missing
    from_left = [r for r in missing if r[3] is not None or r[4] is not None]
    from_right = [r for r in missing if r[3] is None and r[4] is None]
    assert len(from_left) == lv["k"].count(None) and len(from_right) == rv["k"].count(None)
    assert all(r[6] is None and r[7] is None and r[5] is None for r in from_left), "a left NULL key met a right row"
    assert all(r[1] is None and r[2] is None for r in from_right), "a right NULL key met a left row"


def test_isin_of_a_series_equals_exists_and_not_exists(left, right):
    run_programs(left, right, SEMI_ANTI)


def test_transform_equals_duckdb_window_aggregates(left, right):
    run_programs(left, right, TRANSFORMS)


def test_cumulative_windows_equal_duckdb_running_frames(left, right):
    run_programs(left, right, CUMULATIVES)


def test_rank_equals_duckdb_rank_and_dense_rank(left, right):
    run_programs(left, right, RANKS)


def test_rolling_equals_duckdb_row_frames(left, right):
    run_programs(left, right, ROLLINGS)


def test_shift_diff_and_pct_change_equal_duckdb_lag_and_lead(left, right):
    run_programs(left, right, SHIFTS)


# The rows of the pandas oracle, written out of order: t, then i (int64, no
# NULL, with zeros: pandas keeps a numpy int64 and its diff is float64), f
# (float64 with NULL, NaN, zeros and negatives). In the order of t the
# previous value is 0 before a positive, a negative, a 0 and a NaN value.
ORACLE_ROWS = [
    (5, -2, None),
    (1, 3, 2.0),
    (12, 3, 0.0),
    (4, 4, 1.5),
    (2, 0, 0.0),
    (13, 4, float("nan")),
    (6, 0, -0.5),
    (3, 0, 0.0),
    (8, 5, -2.5),
    (7, -6, 0.0),
    (11, 2, 3.0),
    (9, 9, float("nan")),
    (10, 1, 0.0),
]


def oracle_columns(frame):
    """The columns the oracle compares, of a frame sorted by t: each verb of
    the pandas-shaped frame and of pandas itself."""
    return {
        "s1": frame["i"].shift(1),
        "sm1": frame["i"].shift(-1),
        "sf2": frame["f"].shift(2),
        "d": frame["i"].diff(),
        "dm1": frame["i"].diff(-1),
        "df2": frame["f"].diff(2),
        "p": frame["i"].pct_change(),
        "pf": frame["f"].pct_change(),
        "pfm1": frame["f"].pct_change(-1),
        "pi3": frame["i"].pct_change(3),
    }


def test_shift_diff_and_pct_change_equal_pandas_own(left, right):
    """pandas itself is the oracle: over the rows above, sorted by t, every
    column equals pandas' own shift, diff and pct_change, a previous value of
    0 giving inf, -inf or NaN as pandas divides."""
    import pandas as pd
    import pyarrow as pa
    import pyarrow.parquet as pq

    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "oracle.parquet")
        t, i, f = zip(*ORACLE_ROWS)
        pq.write_table(
            pa.table({"t": pa.array(t, pa.int32()), "i": pa.array(i, pa.int64()), "f": pa.array(f, pa.float64())}),
            path,
        )
        want = pq.read_table(path).to_pandas().sort_values("t").reset_index(drop=True)
        assert str(want["i"].dtype) == "int64" and str(want["f"].dtype) == "float64"
        want = want.assign(**oracle_columns(want))
        with komira.Session() as session:
            ordered = komira.read_parquet(path, session=session).sort_values("t")
            got = ordered.assign(**oracle_columns(ordered)).materialize().to_pandas()
    assert list(got.columns) == list(want.columns), list(got.columns)
    for name in ("d", "dm1", "df2", "p", "pf", "pfm1", "pi3"):
        assert str(got[name].dtype) == "float64", (name, got[name].dtype)
    pd.testing.assert_frame_equal(got, want, check_dtype=True)
    # The cases the oracle relies on are in the rows: a previous 0 before a
    # positive, a negative, a 0 and a NaN value.
    p = want["p"].tolist()
    assert float("inf") in p and float("-inf") in p and any(x != x for x in p[1:])
    assert want["pf"].isna().sum() > want["f"].isna().sum()


def test_windows_inside_expressions_and_filters_equal_duckdb(left, right):
    run_programs(left, right, IN_EXPRESSIONS)


def test_the_files_have_the_nulls_duplicates_and_missing_keys_the_cases_rely_on(left, right):
    import pyarrow.parquet as pq

    lv, rv = base.column_values(), right_values()
    assert all(len(v) == RIGHT_ROWS for v in rv.values())
    lk, rk = lv["k"], rv["k"]
    assert lk.count(None) == 4 and rk.count(None) == 2, "both files have NULL keys"
    present = [x for x in rk if x is not None]
    assert len(set(present)) < len(present), "the right key has duplicates"
    assert {1, 2, 3, 0, -4, 100} <= set(lk), "the right keys the left has"
    assert {50, 999} & set(lk) == set() and {50, 999} <= set(present), "right keys absent from the left"
    assert any(x not in rk for x in lk if x is not None), "left keys absent from the right"
    assert None in rv["v"] and None in rv["s"] and None in rv["w"]
    assert set(rv) - set(lv) == {"w"} and set(rv) & set(lv) == {"k", "v", "s"}
    pairs = {(a, b) for a, b in zip(lk, lv["s"])} & {(a, b) for a, b in zip(rk, rv["s"])}
    assert {(1, "alpha"), (-4, "alpha"), (100, "alpha")} <= pairs, "two-key matches"
    ints = {(a, a + 2) for a in lk if a is not None} & set(zip(rk, rv["w"]))
    assert {(1, 3), (2, 4), (3, 5), (0, 2), (100, 102)} <= ints, "matches of k with j = k + 2 and w"
    assert set(lk) & set(rv["w"]), "w holds left keys"
    assert rv["v"].count(-2.0) == 1 and rk[rv["v"].index(-2.0)] is None, "one right row with a NULL key and v -2.0"
    table = pq.read_table(right)
    assert [str(t) for t in table.schema.types] == ["int64", "double", "string", "int64"], table.schema
    assert table.to_pydict() == rv
    assert list(pq.read_table(left).column_names) == list(base.FILE_COLUMNS)


def test_a_program_the_engine_refuses_is_named_with_its_step(left, right):
    case = Case("an int32 window", lambda d, o: d, "SELECT * FROM t")
    error = komira.KomiraError("refused", step="LOWERING")
    assert refused_by_the_engine(case, error) == "an int32 window: the engine refused the program at step LOWERING: refused"


def test_filters_by_a_window_under_a_case_equal_duckdb(left, right):
    run_programs(left, right, CASE_FILTERS)


# ---- the tests of the runner, on plain lists ---------------------------------

ANSWER = (["k", "x"], ["int64", "double"], [(1, 0.5), (2, None), (None, 1.5)])


def test_check_case_accepts_an_equal_answer_and_names_a_different_one():
    case = Case("two rows", None, "", ("k",))
    assert check_case(case, ANSWER, ANSWER) is None
    moved = (ANSWER[0], ANSWER[1], [(None, 1.5), (1, 0.5), (2, None)])
    assert check_case(case, moved, ANSWER) == (
        "two rows: komira's answer is not DuckDB's (rows are not in the order of ['k']: run 0 has key (None,), "
        "expected (1,))"
    )
    assert check_case(Case("multiset", None, ""), moved, ANSWER) is None
    other = (ANSWER[0], ANSWER[1], [(1, 0.5), (2, 9.0), (None, 1.5)])
    assert check_case(Case("cell", None, ""), other, ANSWER) == (
        "cell: komira's answer is not DuckDB's (row 2 is (2, 9.0), expected (2, None))"
    )


def test_check_case_skips_the_type_of_an_untyped_column_only():
    retyped = (ANSWER[0], ["int32", "double"], ANSWER[2])
    assert check_case(Case("typed", None, ""), retyped, ANSWER) == (
        "typed: komira's answer is not DuckDB's (column 'k' has type int32 but int64 was expected)"
    )
    assert check_case(Case("untyped", None, "", None, False, ("k",)), retyped, ANSWER) is None


def test_report_raises_once_naming_every_problem_and_passes_none():
    report([])
    try:
        report(["a: differs", "b: refused"])
    except AssertionError as e:
        assert str(e) == "2 programs differ from DuckDB:\na: differs\nb: refused"
    else:
        raise AssertionError("report accepted problems")


# ---- main --------------------------------------------------------------------

WITH_FILES = [
    test_the_files_have_the_nulls_duplicates_and_missing_keys_the_cases_rely_on,
    test_a_program_the_engine_refuses_is_named_with_its_step,
    test_merges_equal_duckdb_joins,
    test_null_keys_match_nothing_as_in_sql_equality,
    test_an_outer_merge_holds_each_null_key_row_once_unpaired,
    test_isin_of_a_series_equals_exists_and_not_exists,
    test_transform_equals_duckdb_window_aggregates,
    test_cumulative_windows_equal_duckdb_running_frames,
    test_rank_equals_duckdb_rank_and_dense_rank,
    test_rolling_equals_duckdb_row_frames,
    test_shift_diff_and_pct_change_equal_duckdb_lag_and_lead,
    test_shift_diff_and_pct_change_equal_pandas_own,
    test_windows_inside_expressions_and_filters_equal_duckdb,
    test_filters_by_a_window_under_a_case_equal_duckdb,
]

PURE = [
    test_check_case_accepts_an_equal_answer_and_names_a_different_one,
    test_check_case_skips_the_type_of_an_untyped_column_only,
    test_report_raises_once_naming_every_problem_and_passes_none,
]

ALL_CASES = (
    MERGES, NULL_KEYS, SEMI_ANTI, TRANSFORMS, CUMULATIVES, RANKS, ROLLINGS, SHIFTS, IN_EXPRESSIONS, CASE_FILTERS
)


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    for test in PURE:
        test()
    # The library is loaded before pyarrow and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    with tempfile.TemporaryDirectory() as work:
        left = base.write_data(os.path.join(work, "left.parquet"))
        right = write_right(os.path.join(work, "right.parquet"))
        for test in WITH_FILES:
            test(left, right)
    print(
        "frame join window duckdb: {} programs equal DuckDB's answer over libkomira {}".format(
            sum(len(c) for c in ALL_CASES), komira.abi_version()
        )
    )


if __name__ == "__main__":
    main(sys.argv[1:])
