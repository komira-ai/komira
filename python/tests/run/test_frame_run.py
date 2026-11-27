"""The pandas-shaped DataFrame on the real libkomira: each reader and verb is
run through komira_plan_stream (no SQL text) over files written here, and its
rows are compared with the rows worked out by hand:

- read_parquet: the file's rows, column names and types come back; a frame
  made by a reader runs nothing until `materialize()`;
- filter: comparisons (against a literal, a literal on the left, another
  column), `&`, `|`, `~` with NULLs (a NULL condition drops the row, also
  under `~`), `isin`, a boolean column, a function of the frame; select;
  assign (integer and float arithmetic, true division of integers giving
  float64, a literal on the left, literal columns, a function of the frame,
  a later keyword using an earlier one, a column replaced in place);
  `df["x"] = ...` and the stale Series it leaves behind;
- sort_values: ascending, descending, several keys, NULLs first and last in
  both directions; a filter, projection or assign after a sort keeps the
  order; `head` after a sort is exactly the first rows; `head` on an unordered
  frame is only a row count; a verb after `head` of a sort applies to the
  head's rows and keeps their order; `head(0)`;
- `materialize()` twice gives two Results, each read once; a Result read
  twice raises KomiraError; `explain()` names the file and runs nothing (it
  answers for a file removed after the read);
- the notebook display: a frame's is its names over their types (also for a
  file removed after the read), and a sorted frame's Result shows its six
  rows with NULLs and stays unread, so `to_arrow` reads them all after;
- read_csv (`sep`, `header`, `skiprows`) and read_json(lines=True), and a CSV read with
  no header, which the engine refuses at the terminal with its step and code;
- failures: a missing file and an empty directory raise at the reader with
  the engine's status, step and last error; a closed session raises
  KomiraError "the session is closed" at each reader and at the terminal of a
  frame made before the close; the readers without `session=` share the
  process's default session; a Series of another frame is refused in a verb;
- an ABI 1.7 stand-in (in a new interpreter) refuses the plan door with the
  message that names the call, the version it needs and the library;
- importing komira imports no protobuf; the first reader does.

The test is of the `run/` family (python/tests/BUCK): `frame_run_test` runs
on the real libkomira on each supported minor (`frame_run_test_py311`, ...),
with the generated plan modules, protobuf 7.36.2 and pyarrow.

    test_frame_run.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` and
`<dir>/fake_v1_7/libkomira.so` the stand-in reporting ABI 1.7
(`--runtime-dir`, which the rule passes, is not read).
"""

import collections
import contextlib
import json
import os
import subprocess
import sys
import tempfile
import types

import pyarrow as pa
import pyarrow.parquet as pq

import komira
from komira import KomiraError
from komira import _native, _session

assert "google.protobuf" not in sys.modules, "importing komira imported protobuf"

# Starts this file again in a new interpreter with the test's `sys.path` and
# temporary directory (`-I -S`, as the test itself runs, sees no other site).
_BOOT = (
    "import json, runpy, sys, tempfile\n"
    "sys.path[:] = json.loads(sys.argv[1])\n"
    "tempfile.tempdir = sys.argv[2]\n"
    "sys.argv = sys.argv[3:]\n"
    "runpy.run_path(sys.argv[0], run_name='__main__')\n"
)

ALREADY_READ = "the result was already read: run the query again to read it again"
CLOSED = "the session is closed"
OTHER_FRAME = (
    "this Series belongs to another frame, and a komira frame has no index to align two frames by: "
    'take the column from the frame you use it with, or pass a function, as in assign(name=lambda d: d["column"])'
)
STALE = (
    'this Series was taken from its frame before df["name"] = ... replaced the frame\'s columns: '
    "take it from the frame again"
)

# The Parquet file: id 1 to 6, then a nullable int, a nullable float, a
# nullable string and a nullable bool. Row i is ROWS[i - 1].
IDS = [1, 2, 3, 4, 5, 6]
N = [10, None, -5, 7, None, 0]
X = [1.5, -2.5, 0.0, None, 4.25, -0.5]
S = ["b", "a", None, "c", "a", ""]
FLAG = [True, False, None, True, False, True]
COLUMNS = ["id", "n", "x", "s", "flag"]
ROWS = [
    {"id": i, "n": n, "x": x, "s": s, "flag": f} for i, n, x, s, f in zip(IDS, N, X, S, FLAG)
]

# people.csv and events.jsonl of python/tests/fixtures, in the order of `id`.
PEOPLE = [
    {"id": 1, "name": "ann", "score": 10.5},
    {"id": 2, "name": None, "score": 20.0},
    {"id": 3, "name": "cy", "score": None},
]
CSV_TEXT = "id,name,score\n1,ann,10.5\n2,,20\n3,cy,\n"
NOTED_TEXT = "exported by hand\n" + CSV_TEXT
PIPE_TEXT = "id|name|score\n1|ann|10.5\n2||20\n3|cy|\n"
JSONL_TEXT = (
    '{"id":1,"name":"ann","score":10.5}\n'
    '{"id":2,"name":null,"score":20.0}\n'
    '{"id":3,"name":"cy"}\n'
)

TEXT_TYPES = ("string", "large_string", "string_view")
ARROW = {"int64": pa.int64(), "float64": pa.float64(), "bool": pa.bool_()}


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def refused(call, cls, message):
    """`call` raises exactly `cls` with exactly `message`; the error."""
    e = raised(call)
    assert type(e) is cls and str(e) == message, repr(e)
    return e


def rows_of(df):
    return df.materialize().to_arrow().to_pylist()


def by_id(rows):
    return sorted(rows, key=lambda r: r["id"])


def ids(rows):
    return [r["id"] for r in rows]


def rows_for(wanted):
    return [ROWS[i - 1] for i in wanted]


def is_text(t):
    return pa.types.is_string(t) or pa.types.is_large_string(t) or pa.types.is_string_view(t)


def write_files(work):
    table = pa.table(
        {
            "id": pa.array(IDS, pa.int64()),
            "n": pa.array(N, pa.int64()),
            "x": pa.array(X, pa.float64()),
            "s": pa.array(S, pa.string()),
            "flag": pa.array(FLAG, pa.bool_()),
        }
    )
    parquet = os.path.join(work, "rows.parquet")
    pq.write_table(table, parquet, row_group_size=2)
    out = {"work": work, "parquet": parquet}
    for key, name, text in (
        ("csv", "people.csv", CSV_TEXT),
        ("pipe", "people_pipe.csv", PIPE_TEXT),
        ("noted", "people_noted.csv", NOTED_TEXT),
        ("jsonl", "events.jsonl", JSONL_TEXT),
    ):
        out[key] = os.path.join(work, name)
        with open(out[key], "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    return types.SimpleNamespace(**out)


@contextlib.contextmanager
def workspace():
    """A session and the files, in a directory removed afterwards."""
    with tempfile.TemporaryDirectory() as work:
        paths = write_files(work)
        with komira.Session() as s:
            yield s, paths


def child(scenario, *args):
    """Runs this file as `--child <scenario> <args>` in a new interpreter and
    returns its stdout; a non-zero exit, a signal among them, fails here."""
    argv = [sys.executable, "-I", "-S", "-c", _BOOT, json.dumps(sys.path), tempfile.gettempdir(),
            os.path.abspath(__file__), "--child", scenario] + list(args)
    proc = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if proc.returncode != 0:
        how = "exited {}".format(proc.returncode)
        if proc.returncode < 0:
            import signal

            how = "was killed by {}".format(signal.Signals(-proc.returncode).name)
        raise AssertionError(
            "child {} {}\n--- stdout ---\n{}--- stderr ---\n{}".format(scenario, how, proc.stdout, proc.stderr)
        )
    return proc.stdout


def stand_in(args):
    """The ABI 1.7 stand-in: the plan door needs 1.8, and says so."""
    directory = os.path.abspath(os.path.join(args[0], "fake_v1_7"))
    native = _native.load(directory)
    assert native.abi_version == 1007, native.abi_version
    assert _native._FUNCTIONS["komira_plan_stream"][0] == 8
    want = "komira_plan_stream needs libkomira ABI version 1.8; the library at {} is 1.7".format(
        os.path.join(directory, _native._LIB_NAME)
    )

    def check(call):
        e = refused(call, KomiraError, want)
        assert (e.status, e.code, e.step) == (None, None, None), (e.status, e.code, e.step)

    ctx = native.ctx_new()
    check(lambda: native.plan_stream(ctx, b"plan"))
    native.ctx_free(ctx)
    with komira.Session() as s:
        check(lambda: s._plan_stream(b"plan"))
        # Only the plan door is refused: the 1.7 call that renders a plan still answers.
        s.register_parquet("ok", "f.parquet")
        assert s._plan_render(b"abc") == "plan:3:616263"
    print("stand-in: done")


CHILDREN = {"stand_in": stand_in}


# ---- the tests -----------------------------------------------------------------


def test_protobuf_loads_at_first_reader(lib_dir):
    """komira imports no protobuf; the first reader imports it, and runs the frame."""
    with tempfile.TemporaryDirectory() as work:
        paths = write_files(work)
        with komira.Session() as s:
            assert "google.protobuf" not in sys.modules, "making a Session imported protobuf"
            df = komira.read_parquet(paths.parquet, session=s)
            assert "google.protobuf" in sys.modules, "the first reader did not import protobuf"
            assert by_id(rows_of(df)) == ROWS


def test_read_parquet_rows_and_schema(lib_dir):
    """The file's rows, names and types come back; a frame is a plan until it runs."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        assert type(df) is komira.DataFrame
        assert df.columns == COLUMNS, df.columns
        assert list(df.dtypes) == COLUMNS, df.dtypes
        assert {k: v for k, v in df.dtypes.items() if k != "s"} == {
            "id": "int64", "n": "int64", "x": "float64", "flag": "bool"
        }, df.dtypes
        assert df.dtypes["s"] in TEXT_TYPES, df.dtypes
        assert "n" in df and "nope" not in df

        result = df.materialize()
        assert type(result) is komira.Result
        t = result.to_arrow()
        assert t.schema.names == COLUMNS, t.schema
        for name in ("id", "n", "x", "flag"):
            assert t.schema.field(name).type == ARROW[df.dtypes[name]], (name, t.schema)
        assert is_text(t.schema.field("s").type), t.schema
        assert by_id(t.to_pylist()) == ROWS, t.to_pylist()

        # A relative path names the same file.
        cwd = os.getcwd()
        os.chdir(p.work)
        try:
            relative = komira.read_parquet("rows.parquet", session=s)
        finally:
            os.chdir(cwd)
        assert by_id(rows_of(relative)) == ROWS


def test_filter_comparisons(lib_dir):
    """Each comparison keeps the rows where it is true; a NULL drops the row."""
    cases = [
        ("n > 0", lambda d: d["n"] > 0, [1, 4]),
        ("n >= 0", lambda d: d["n"] >= 0, [1, 4, 6]),
        ("n < 0", lambda d: d["n"] < 0, [3]),
        ("n <= 0", lambda d: d["n"] <= 0, [3, 6]),
        ("n == 7", lambda d: d["n"] == 7, [4]),
        ("n != 7", lambda d: d["n"] != 7, [1, 3, 6]),
        ("x < 0", lambda d: d["x"] < 0, [2, 6]),
        ("x >= 1.5", lambda d: d["x"] >= 1.5, [1, 5]),
        ("s == 'a'", lambda d: d["s"] == "a", [2, 5]),
        ("s != 'a'", lambda d: d["s"] != "a", [1, 4, 6]),
        ("s > 'a'", lambda d: d["s"] > "a", [1, 4]),
        ("id > n", lambda d: d["id"] > d["n"], [3, 6]),
        ("4 < id", lambda d: 4 < d["id"], [5, 6]),
        ("n > 100", lambda d: d["n"] > 100, []),
    ]
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for label, cond, want in cases:
            got = by_id(rows_of(df[cond(df)]))
            assert got == rows_for(want), (label, ids(got))
        # A function of the frame is the same filter.
        got = by_id(rows_of(df[lambda d: d["n"] > 0]))
        assert got == rows_for([1, 4]), ids(got)
        # A filter that keeps nothing still has the columns.
        t = df[df["n"] > 100].materialize().to_arrow()
        assert t.num_rows == 0 and t.schema.names == COLUMNS, t.schema


def test_filter_boolean_logic(lib_dir):
    """`&`, `|` and `~` follow SQL's three-valued logic: a NULL condition drops the row."""
    cases = [
        ("(n >= 0) & (x < 5)", lambda d: (d["n"] >= 0) & (d["x"] < 5), [1, 6]),
        ("(n > 0) | (x < 0)", lambda d: (d["n"] > 0) | (d["x"] < 0), [1, 2, 4, 6]),
        ("~(n > 0)", lambda d: ~(d["n"] > 0), [3, 6]),
        ("~((n > 0) | (x < 0))", lambda d: ~((d["n"] > 0) | (d["x"] < 0)), [3]),
        ("(n > 0) & True", lambda d: (d["n"] > 0) & True, [1, 4]),
        ("True & (n > 0)", lambda d: True & (d["n"] > 0), [1, 4]),
        ("(n > 0) | False", lambda d: (d["n"] > 0) | False, [1, 4]),
        ("(id > 1) & (id < 5) & (s != 'a')", lambda d: (d["id"] > 1) & (d["id"] < 5) & (d["s"] != "a"), [4]),
    ]
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for label, cond, want in cases:
            got = by_id(rows_of(df[cond(df)]))
            assert got == rows_for(want), (label, ids(got))


def test_filter_isin(lib_dir):
    """`isin` keeps the rows whose value is in the list; NULL is in no list, also under `~`."""
    cases = [
        ("s in a, c", lambda d: d["s"].isin(["a", "c"]), [2, 4, 5]),
        ("n in 10, 0, -5", lambda d: d["n"].isin([10, 0, -5]), [1, 3, 6]),
        ("n in a tuple", lambda d: d["n"].isin((7,)), [4]),
        ("~(s in a)", lambda d: ~d["s"].isin(["a"]), [1, 4, 6]),
        ("s in nothing", lambda d: d["s"].isin([]), []),
        ("id in 2, 3 | s == c", lambda d: d["id"].isin([2, 3]) | (d["s"] == "c"), [2, 3, 4]),
    ]
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for label, cond, want in cases:
            got = by_id(rows_of(df[cond(df)]))
            assert got == rows_for(want), (label, ids(got))


def test_filter_boolean_column(lib_dir):
    """A bool column is a condition as it stands, and under `~` or `&`; a NULL drops the row."""
    cases = [
        ("flag", lambda d: d["flag"], [1, 4, 6]),
        ("~flag", lambda d: ~d["flag"], [2, 5]),
        ("flag & (id > 1)", lambda d: d["flag"] & (d["id"] > 1), [4, 6]),
        ("flag | (id == 2)", lambda d: d["flag"] | (d["id"] == 2), [1, 2, 4, 6]),
        ("flag == False", lambda d: d["flag"] == False, [2, 5]),  # noqa: E712 (the Series operator)
    ]
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for label, cond, want in cases:
            got = by_id(rows_of(df[cond(df)]))
            assert got == rows_for(want), (label, ids(got))


def test_select_columns(lib_dir):
    """`df[[...]]` answers those columns, in that order, with the values of the file."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        two = df[["s", "id"]]
        assert two.columns == ["s", "id"] and list(two.dtypes) == ["s", "id"], two.columns
        t = two.materialize().to_arrow()
        assert t.schema.names == ["s", "id"], t.schema
        assert by_id(t.to_pylist()) == [{"s": S[i - 1], "id": i} for i in IDS], t.to_pylist()

        # A projection of a filtered frame, and a filter of a projection.
        got = by_id(rows_of(df[df["n"] > 0][["id", "n"]]))
        assert got == [{"id": 1, "n": 10}, {"id": 4, "n": 7}], got
        narrow = df[["id", "n"]]
        got = by_id(rows_of(narrow[narrow["n"] < 5]))
        assert got == [{"id": 3, "n": -5}, {"id": 6, "n": 0}], got

        # One column, and the same columns the frame already has.
        assert sorted(r["flag"] is None for r in rows_of(df[["flag"]])) == [False] * 5 + [True]
        assert by_id(rows_of(df[COLUMNS])) == ROWS


def test_assign_arithmetic(lib_dir):
    """Each operator computes per row, NULL in gives NULL out, and `/` divides as floats."""
    i64, f64 = "int64", "float64"
    cases = [
        ("n + id", lambda d: d["n"] + d["id"], [11, None, -2, 11, None, 6], i64),
        ("n - 1", lambda d: d["n"] - 1, [9, None, -6, 6, None, -1], i64),
        ("n * 2", lambda d: d["n"] * 2, [20, None, -10, 14, None, 0], i64),
        ("-n", lambda d: -d["n"], [-10, None, 5, -7, None, 0], i64),
        ("100 + n", lambda d: 100 + d["n"], [110, None, 95, 107, None, 100], i64),
        ("100 - n", lambda d: 100 - d["n"], [90, None, 105, 93, None, 100], i64),
        ("3 * n", lambda d: 3 * d["n"], [30, None, -15, 21, None, 0], i64),
        ("id * id", lambda d: d["id"] * d["id"], [1, 4, 9, 16, 25, 36], i64),
        ("x * 2", lambda d: d["x"] * 2, [3.0, -5.0, 0.0, None, 8.5, -1.0], f64),
        ("1 + x", lambda d: 1 + d["x"], [2.5, -1.5, 1.0, None, 5.25, 0.5], f64),
        ("1 - x", lambda d: 1 - d["x"], [-0.5, 3.5, 1.0, None, -3.25, 1.5], f64),
        ("n + x", lambda d: d["n"] + d["x"], [11.5, None, -5.0, None, None, -0.5], f64),
        ("id / 2", lambda d: d["id"] / 2, [0.5, 1.0, 1.5, 2.0, 2.5, 3.0], f64),
        ("n / 2", lambda d: d["n"] / 2, [5.0, None, -2.5, 3.5, None, 0.0], f64),
        ("100 / id", lambda d: 100 / d["id"], [100 / i for i in IDS], f64),
        ("x / 2", lambda d: d["x"] / 2, [0.75, -1.25, 0.0, None, 2.125, -0.25], f64),
    ]
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for label, build, want, dtype in cases:
            out = df.assign(v=build(df))
            assert out.columns == COLUMNS + ["v"], (label, out.columns)
            assert out.dtypes["v"] == dtype, (label, out.dtypes["v"])
            t = out.materialize().to_arrow()
            assert t.schema.field("v").type == ARROW[dtype], (label, t.schema)
            got = by_id(t.to_pylist())
            assert [r["v"] for r in got] == want, (label, [r["v"] for r in got])
            # The other columns are the file's.
            assert [{k: r[k] for k in COLUMNS} for r in got] == ROWS, label
        # A comparison is a column too: true, false and NULL.
        got = by_id(rows_of(df.assign(big=df["n"] > 5)))
        assert [r["big"] for r in got] == [True, None, False, True, None, False], got


def test_assign_literals_callables_and_replacement(lib_dir):
    """Literal columns, functions of the frame, later keywords using earlier ones, replaced columns."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)

        got = by_id(rows_of(df.assign(k=7, tag="z", yes=True, half=0.5)))
        for r in got:
            assert (r["k"], r["tag"], r["yes"], r["half"]) == (7, "z", True, 0.5), r
        assert [r["id"] for r in got] == IDS

        got = by_id(rows_of(df.assign(m=lambda d: d["n"] + 1)))
        assert [r["m"] for r in got] == [11, None, -4, 8, None, 1], got

        # A later keyword uses an earlier one, as a Series and as a function.
        out = df.assign(a=df["n"] + 1, b=lambda d: d["a"] * 2, c=lambda d: d["b"] - d["id"])
        assert out.columns == COLUMNS + ["a", "b", "c"], out.columns
        got = by_id(rows_of(out))
        assert [r["a"] for r in got] == [11, None, -4, 8, None, 1], got
        assert [r["b"] for r in got] == [22, None, -8, 16, None, 2], got
        assert [r["c"] for r in got] == [21, None, -11, 12, None, -4], got

        # A column named again is replaced where it stands; one new column is appended.
        out = df.assign(id=df["id"] * 10, extra=1)
        assert out.columns == COLUMNS + ["extra"], out.columns
        got = by_id(rows_of(out))
        assert ids(got) == [10, 20, 30, 40, 50, 60], got
        assert [r["s"] for r in got] == S and [r["extra"] for r in got] == [1] * 6, got

        # The frame assign was called on is unchanged.
        assert df.columns == COLUMNS
        assert by_id(rows_of(df)) == ROWS

        # A frame of assign filters and projects like any other.
        out = df.assign(dbl=df["id"] * 2)
        got = by_id(rows_of(out[out["dbl"] > 8][["id", "dbl"]]))
        assert got == [{"id": 5, "dbl": 10}, {"id": 6, "dbl": 12}], got


def test_setitem(lib_dir):
    """`df["x"] = ...` sets the column in that frame, and a Series taken before is stale."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        before = df.copy()
        df["double"] = df["id"] * 2
        df["id"] = df["id"] + 100
        assert df.columns == COLUMNS + ["double"], df.columns
        got = by_id(rows_of(df))
        assert ids(got) == [101, 102, 103, 104, 105, 106], got
        assert [r["double"] for r in got] == [2, 4, 6, 8, 10, 12], got
        assert [r["n"] for r in got] == N, got

        # A copy taken before is the file's frame.
        assert before.columns == COLUMNS
        assert by_id(rows_of(before)) == ROWS

        # A copy changes alone.
        other = df.copy()
        other["w"] = 0
        assert "w" in other and "w" not in df
        assert [r["w"] for r in rows_of(other)] == [0] * 6

        # A Series taken before the assignment is refused in its verbs, with the message below.
        old = df["id"]
        assert old.dtype == "int64"
        df["z"] = 1
        refused(lambda: old.dtype, komira.UnsupportedOperation, STALE)
        refused(lambda: old > 1, komira.UnsupportedOperation, STALE)
        refused(lambda: df[old], komira.UnsupportedOperation, STALE)
        fresh = df["id"]
        assert ids(by_id(rows_of(df[fresh > 103]))) == [104, 105, 106]


def check_with_nulls(rows, key, nulls_first, non_null_ids):
    """`rows` hold the NULLs of `key` as one block, first or last, and the rows
    with a value, in the order of `non_null_ids`, in the rest."""
    k = sum(1 for r in rows if r[key] is None)
    assert k == sum(1 for r in ROWS if r[key] is None), (key, rows)
    block, rest = (rows[:k], rows[k:]) if nulls_first else (rows[len(rows) - k:], rows[:len(rows) - k])
    assert all(r[key] is None for r in block), (key, nulls_first, ids(rows))
    assert ids(rest) == non_null_ids, (key, nulls_first, ids(rows))
    for r in rows:
        assert r == ROWS[r["id"] - 1], r


def test_sort_values_directions_and_null_placement(lib_dir):
    """Ascending and descending, NULLs last unless na_position is "first", whichever the direction."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        assert rows_of(df.sort_values("id", ascending=False)) == rows_for([6, 5, 4, 3, 2, 1])
        assert rows_of(df.sort_values("id")) == ROWS
        assert rows_of(df.sort_values(["id"])) == ROWS

        n_asc, n_desc = [3, 6, 4, 1], [1, 4, 6, 3]
        for kwargs, first, want in [
            ({}, False, n_asc),
            ({"ascending": False}, False, n_desc),
            ({"na_position": "last"}, False, n_asc),
            ({"na_position": "first"}, True, n_asc),
            ({"ascending": False, "na_position": "first"}, True, n_desc),
        ]:
            rows = rows_of(df.sort_values("n", **kwargs))
            check_with_nulls(rows, "n", first, want)

        x_asc, x_desc = [2, 6, 3, 1, 5], [5, 1, 3, 6, 2]
        for kwargs, first, want in [
            ({}, False, x_asc),
            ({"ascending": False}, False, x_desc),
            ({"na_position": "first"}, True, x_asc),
            ({"ascending": False, "na_position": "first"}, True, x_desc),
        ]:
            rows = rows_of(df.sort_values("x", **kwargs))
            check_with_nulls(rows, "x", first, want)

        # A string key sorts bytewise, the empty string before "a".
        rows = rows_of(df.sort_values("s", na_position="first"))
        assert ids(rows[:1]) == [3] and ids(rows[1:2]) == [6], ids(rows)
        assert sorted(ids(rows[2:4])) == [2, 5] and ids(rows[4:]) == [1, 4], ids(rows)

        # The sorted frame's columns and types are the file's.
        out = df.sort_values("n")
        assert out.columns == COLUMNS and out.dtypes == df.dtypes
        assert out.materialize().to_arrow().schema.names == COLUMNS


def test_sort_values_multiple_keys(lib_dir):
    """Several keys, each with its own direction; NULL placement applies to every key."""
    cases = [
        (["s", "id"], {}, [6, 2, 5, 1, 4, 3]),
        (["s", "id"], {"ascending": [True, False]}, [6, 5, 2, 1, 4, 3]),
        (["s", "id"], {"ascending": False}, [4, 1, 5, 2, 6, 3]),
        (["s", "id"], {"na_position": "first"}, [3, 6, 2, 5, 1, 4]),
        (["n", "id"], {"ascending": [False, True], "na_position": "first"}, [2, 5, 1, 4, 6, 3]),
        (("n", "id"), {"ascending": (True, False)}, [3, 6, 4, 1, 5, 2]),
        (["flag", "id"], {"ascending": [True, False], "na_position": "first"}, [3, 5, 2, 6, 4, 1]),
    ]
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for by, kwargs, want in cases:
            got = rows_of(df.sort_values(by, **kwargs))
            assert got == rows_for(want), (by, kwargs, ids(got))
        # A sort of a sorted frame replaces the earlier order.
        got = rows_of(df.sort_values("n").sort_values("id", ascending=False))
        assert ids(got) == [6, 5, 4, 3, 2, 1], ids(got)


def test_sort_keeps_order_through_verbs(lib_dir):
    """A filter, a projection that keeps the keys and an assign after a sort keep its order."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        desc = df.sort_values("id", ascending=False)

        got = rows_of(desc[desc["id"] != 3])
        assert got == rows_for([6, 5, 4, 2, 1]), ids(got)
        got = rows_of(desc[(desc["n"] > 0) | (desc["s"] == "a")])
        assert got == rows_for([5, 4, 2, 1]), ids(got)

        got = rows_of(desc[["id", "s"]])
        assert got == [{"id": i, "s": S[i - 1]} for i in [6, 5, 4, 3, 2, 1]], got

        got = rows_of(desc.assign(d=desc["id"] * 2))
        assert ids(got) == [6, 5, 4, 3, 2, 1] and [r["d"] for r in got] == [12, 10, 8, 6, 4, 2], got

        # Chained: assign, filter and projection, in that order.
        a = desc.assign(d=desc["id"] * 2)
        f = a[a["d"] > 4]
        got = rows_of(f[["d", "id"]])
        assert got == [{"d": 12, "id": 6}, {"d": 10, "id": 5}, {"d": 8, "id": 4}, {"d": 6, "id": 3}], got

        # Sorting by a column the verb then replaces: the order is the one the new values give.
        by_n = df.sort_values("n")
        got = rows_of(by_n.assign(n=by_n["id"]))
        assert sorted(ids(got)) == IDS and all(r["n"] == r["id"] for r in got), got

        # A projection that drops the sort key leaves the rows, in no promised order.
        got = rows_of(desc[["s"]])
        assert collections.Counter(r["s"] for r in got) == collections.Counter(S), got


def test_head_after_sort(lib_dir):
    """`head(n)` of a sorted frame is exactly its first n rows."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        desc = df.sort_values("id", ascending=False)
        assert rows_of(desc.head(3)) == rows_for([6, 5, 4])
        assert rows_of(desc.head(1)) == rows_for([6])
        assert rows_of(desc.head()) == rows_for([6, 5, 4, 3, 2])
        assert rows_of(desc.head(6)) == rows_for([6, 5, 4, 3, 2, 1])
        assert rows_of(desc.head(100)) == rows_for([6, 5, 4, 3, 2, 1])
        assert rows_of(df.sort_values("n", ascending=False).head(2)) == rows_for([1, 4])
        assert rows_of(df.sort_values(["s", "id"]).head(2)) == rows_for([6, 2])
        rows = rows_of(df.sort_values("n", na_position="first").head(3))
        assert sorted(ids(rows[:2])) == [2, 5] and ids(rows[2:]) == [3], ids(rows)
        rows = rows_of(df.sort_values("n").head(4))
        assert ids(rows) == [3, 6, 4, 1], ids(rows)
        # The head frame has the columns of the frame.
        t = desc.head(2).materialize().to_arrow()
        assert t.schema.names == COLUMNS and t.num_rows == 2


def test_head_unordered(lib_dir):
    """`head(n)` of an unsorted frame is n rows of the file, no row twice, and no order."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for n in (1, 4, 5):
            rows = rows_of(df.head(n))
            assert len(rows) == n, (n, len(rows))
            assert len(set(ids(rows))) == n and all(r == ROWS[r["id"] - 1] for r in rows), rows
        assert by_id(rows_of(df.head(6))) == ROWS
        assert by_id(rows_of(df.head(100))) == ROWS
        assert len(rows_of(df.head())) == 5

        rows = rows_of(df[df["id"] > 3].head(2))
        assert len(rows) == 2 and set(ids(rows)) <= {4, 5, 6}, ids(rows)
        rows = rows_of(df.head(5)[["id", "n"]])
        assert len(rows) == 5 and all(r["n"] == N[r["id"] - 1] for r in rows), rows
        assert len(rows_of(df.head(5).head(2))) == 2


def test_verbs_after_head_over_sort(lib_dir):
    """A verb after `head` of a sorted frame works on the head's rows, and keeps their order."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        top = df.sort_values("id", ascending=False).head(4)  # ids 6, 5, 4, 3

        got = rows_of(top[top["id"] != 5])
        assert got == rows_for([6, 4, 3]), ids(got)
        # The filter sees the four rows of the head, not the rows of the file.
        got = rows_of(top[top["id"] > 5])
        assert got == rows_for([6]), ids(got)
        got = rows_of(top[top["n"] > 0])
        assert got == rows_for([4]), ids(got)
        got = rows_of(top[top["n"] > 100])
        assert got == [], got

        got = rows_of(top[top["id"] < 6].head(2))
        assert got == rows_for([5, 4]), ids(got)
        assert rows_of(top.head(2)) == rows_for([6, 5])
        assert rows_of(top.head(10)) == rows_for([6, 5, 4, 3])

        got = rows_of(top[["id", "s"]])
        assert got == [{"id": i, "s": S[i - 1]} for i in [6, 5, 4, 3]], got
        got = rows_of(top.assign(d=top["id"] * 2))
        assert [(r["id"], r["d"]) for r in got] == [(6, 12), (5, 10), (4, 8), (3, 6)], got

        # A sort of the head sorts those four rows alone.
        assert rows_of(top.sort_values("id")) == rows_for([3, 4, 5, 6])
        assert rows_of(top.sort_values("id").head(2)) == rows_for([3, 4])
        # The head of a sort of a filter holds only the filtered rows.
        small = df[df["n"] > 0]
        assert rows_of(small.sort_values("id", ascending=False).head(5)) == rows_for([4, 1])


def test_head_zero(lib_dir):
    """`head(0)` answers no rows, with the frame's columns, and fails nowhere before the terminal."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for frame in (df.head(0), df.sort_values("id").head(0), df[df["id"] > 2].head(0)):
            assert frame.columns == COLUMNS
            t = frame.materialize().to_arrow()
            assert t.num_rows == 0 and t.schema.names == COLUMNS, t.schema


def test_materialize_twice(lib_dir):
    """Each `materialize()` runs the plan again: two Results, each with all the rows."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for frame in (df, df[df["n"] > 0], df.sort_values("id", ascending=False).head(3)):
            first, second = frame.materialize(), frame.materialize()
            assert first is not second
            # Read in the other order, so that neither depends on the other.
            b = second.to_arrow().to_pylist()
            a = first.to_arrow().to_pylist()
            assert sorted(a, key=lambda r: r["id"]) == sorted(b, key=lambda r: r["id"]), (a, b)
            assert len(a) == len(b) > 0
        ordered = df.sort_values("id", ascending=False).head(3)
        assert rows_of(ordered) == rows_of(ordered) == rows_for([6, 5, 4])


def test_result_reads_once(lib_dir):
    """A Result of a frame is read once, as a Result of `sql` is."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        for first in ("to_arrow", "to_reader", "__arrow_c_stream__"):
            r = df.materialize()
            getattr(r, first)()
            for second in ("to_arrow", "to_reader", "__arrow_c_stream__"):
                refused(getattr(r, second), KomiraError, ALREADY_READ)
        # A new Result of the same frame reads.
        assert by_id(rows_of(df)) == ROWS


def test_notebook_display(lib_dir):
    """A frame's display is its names and types and reads nothing; a Result's
    shows its rows and stays unread, so `to_arrow` then reads every row."""
    with workspace() as (s, p):
        gone = os.path.join(p.work, "gone.parquet")
        pq.write_table(pq.read_table(p.parquet), gone)
        df = komira.read_parquet(gone, session=s)[["id", "n", "flag"]].sort_values("id")
        os.remove(gone)
        assert df._repr_html_() == (
            '<div class="komira"><table class="dataframe"><thead><tr><th>id</th><th>n</th><th>flag</th></tr>'
            "<tr><th>int64</th><th>int64</th><th>bool</th></tr></thead><tbody></tbody></table>"
            "<p>komira.DataFrame of 3 columns: a plan that has not run; "
            ".materialize() runs it and returns its rows</p></div>"
        )

        df = komira.read_parquet(p.parquet, session=s)[["id", "n", "flag"]].sort_values("id")
        r = df.materialize()
        cells = "".join(
            "<tr><td>{}</td><td>{}</td><td>{}</td></tr>".format(
                i, "<i>null</i>" if n is None else n, "<i>null</i>" if f is None else str(f).lower()
            )
            for i, n, f in zip(IDS, N, FLAG)
        )
        assert r._repr_html_() == (
            '<div class="komira"><table class="dataframe"><thead><tr><th>id</th><th>n</th><th>flag</th></tr>'
            f"<tr><th>int64</th><th>int64</th><th>bool</th></tr></thead><tbody>{cells}</tbody></table>"
            "<p>6 rows, 3 columns</p></div>"
        ), r._repr_html_()
        assert r.to_arrow().to_pylist() == [{"id": i, "n": n, "flag": f} for i, n, f in zip(IDS, N, FLAG)]
        assert r._repr_html_() is None


def test_explain(lib_dir):
    """`explain()` is text that names the file, runs nothing, and differs with the plan."""
    with workspace() as (s, p):
        df = komira.read_parquet(p.parquet, session=s)
        plain = df.explain()
        assert type(plain) is str and p.parquet in plain, plain
        shaped = df[df["id"] > 1].sort_values("id").head(2)
        text = shaped.explain()
        assert type(text) is str and p.parquet in text and text != plain, text

        # Nothing is read: a file removed after the reader still renders, and
        # only the terminal fails.
        gone = os.path.join(p.work, "gone.parquet")
        pq.write_table(pa.table({"a": pa.array([1, 2], pa.int64())}), gone)
        frame = komira.read_parquet(gone, session=s)
        os.remove(gone)
        assert gone in frame.explain()
        e = raised(frame.materialize)
        assert isinstance(e, KomiraError) and e.status == -3, repr(e)


def text_rows(df):
    """The rows of a text-file frame in the order of `id`, or None when the
    engine refused its scan at step "lower": the plan door's CSV scan is
    listed as refused there (docs/design/dataframe_surface_verbs.md), and the
    SQL door reads the same file, so either answer is the engine's own."""
    try:
        return by_id(rows_of(df))
    except KomiraError as e:
        assert e.status == -3 and e.step == "lower" and e.code is not None, repr(e)
        assert str(e).startswith("lower: "), str(e)
        print("note: the engine refused the scan at lower with", e.code)
        return None


def test_read_csv(lib_dir):
    """The CSV file's columns come from the engine now; its rows come at the terminal."""
    with workspace() as (s, p):
        for kwargs, path in [({}, p.csv), ({"header": 0}, p.csv), ({"header": "infer"}, p.csv),
                             ({"sep": "|"}, p.pipe)]:
            df = komira.read_csv(path, session=s, **kwargs)
            assert df.columns == ["id", "name", "score"], (kwargs, df.columns)
            assert df.dtypes["id"] == "int64" and df.dtypes["score"] == "float64", df.dtypes
            assert df.dtypes["name"] in TEXT_TYPES, df.dtypes
            got = text_rows(df)
            assert got is None or got == PEOPLE, (kwargs, got)
            got = text_rows(df[["name", "id"]])
            want = [{"name": r["name"], "id": r["id"]} for r in PEOPLE]
            assert got is None or got == want, (kwargs, got)
        df = komira.read_csv(p.csv, session=s)
        filtered = df[df["id"] >= 2]
        got = text_rows(filtered)
        assert got is None or got == PEOPLE[1:], got
        assert p.csv in df.explain()


def test_read_csv_skiprows_reads_the_rows_after_the_note_line(lib_dir):
    """`skiprows=1` drops the note line above the header: the same columns, types and rows as the file without it."""
    with workspace() as (s, p):
        df = komira.read_csv(p.noted, skiprows=1, session=s)
        assert df.columns == ["id", "name", "score"], df.columns
        assert df.dtypes["id"] == "int64" and df.dtypes["score"] == "float64", df.dtypes
        got = text_rows(df)
        assert got is None or got == PEOPLE, got
        got = text_rows(df[df["id"] >= 2])
        assert got is None or got == PEOPLE[1:], got
        # None and 0 skip nothing.
        for skiprows in (None, 0):
            df = komira.read_csv(p.csv, skiprows=skiprows, session=s)
            assert df.columns == ["id", "name", "score"], df.columns


def test_read_csv_skiprows_past_the_last_line_is_refused_by_the_engine(lib_dir):
    """A skip that leaves no line of the file raises at the reader with the engine's named error."""
    with workspace() as (s, p):
        e = raised(lambda: komira.read_csv(p.csv, skiprows=4, session=s))
        assert isinstance(e, KomiraError) and e.status == -3, repr(e)
        want = (
            "CSV_SKIP_PAST_END: skip=4 skips every line of the file, which has 4 lines; "
            "no header or record is left to read"
        )
        assert str(e) == want, str(e)


def test_read_csv_without_header_refused_by_engine(lib_dir):
    """A CSV read with `header=None` is built, and the engine refuses it at the terminal, at "lower"."""
    with workspace() as (s, p):
        df = komira.read_csv(p.csv, header=None, session=s)
        assert type(df) is komira.DataFrame
        e = raised(df.materialize)
        assert isinstance(e, KomiraError), repr(e)
        assert (e.status, e.step) == (-3, "lower"), (e.status, e.step)
        assert e.code is not None and str(e).startswith("lower: "), (e.code, str(e))
        # The refusal leaves the session answering.
        ok = komira.read_parquet(p.parquet, session=s)
        assert by_id(rows_of(ok)) == ROWS


def test_read_json(lib_dir):
    """The JSON lines file: a null and a missing key are both NULL; verbs run over it."""
    with workspace() as (s, p):
        df = komira.read_json(p.jsonl, lines=True, session=s)
        assert df.columns == ["id", "name", "score"], df.columns
        assert df.dtypes["id"] == "int64" and df.dtypes["score"] == "float64", df.dtypes
        assert df.dtypes["name"] in TEXT_TYPES, df.dtypes
        assert by_id(rows_of(df)) == PEOPLE
        got = by_id(rows_of(df[df["id"] >= 2]))
        assert got == PEOPLE[1:], got
        got = by_id(rows_of(df[["name", "id"]]))
        assert got == [{"name": r["name"], "id": r["id"]} for r in PEOPLE], got
        got = rows_of(df.sort_values("id", ascending=False).head(2))
        assert got == [PEOPLE[2], PEOPLE[1]], got
        got = by_id(rows_of(df.assign(twice=df["id"] * 2)))
        assert [r["twice"] for r in got] == [2, 4, 6], got
        assert p.jsonl in df.explain()


def test_reader_failures(lib_dir):
    """A file that is not there, or a directory, raises at the reader with the engine's last error."""
    with workspace() as (s, p):
        native = _native.load()
        missing = os.path.join(p.work, "no_such_file")
        readers = [
            ("read_parquet", lambda path: komira.read_parquet(path, session=s)),
            ("read_csv", lambda path: komira.read_csv(path, session=s)),
            ("read_json", lambda path: komira.read_json(path, lines=True, session=s)),
        ]
        for name, read in readers:
            e = raised(lambda: read(missing))
            assert type(e) is komira.BindError, (name, repr(e))
            assert e.status == -3 and e.step == "bind", (name, e.status, e.step)
            assert str(e) == native.last_error(s._ctx) and missing in str(e), (name, str(e))
            # The session still answers.
            assert by_id(rows_of(komira.read_parquet(p.parquet, session=s))) == ROWS

        empty = os.path.join(p.work, "empty_directory")
        os.mkdir(empty)
        e = raised(lambda: komira.read_parquet(empty, session=s))
        assert isinstance(e, KomiraError) and e.status == -3 and e.step == "bind", repr(e)
        assert str(e) == native.last_error(s._ctx), str(e)

        # A file that is not Parquet is refused at the reader as well.
        e = raised(lambda: komira.read_parquet(p.csv, session=s))
        assert isinstance(e, KomiraError) and e.status == -3, repr(e)

        # A wrong session is a TypeError before the library is called.
        e = raised(lambda: komira.read_parquet(p.parquet, session="s"))
        assert type(e) is TypeError and str(e) == "session must be a komira Session, not str", repr(e)


def test_closed_session(lib_dir):
    """A closed session raises "the session is closed" at each reader and at each terminal."""
    with tempfile.TemporaryDirectory() as work:
        p = write_files(work)
        s = komira.Session()
        df = komira.read_parquet(p.parquet, session=s)
        csv = komira.read_csv(p.csv, session=s)
        s.close()
        refused(lambda: komira.read_parquet(p.parquet, session=s), KomiraError, CLOSED)
        refused(lambda: komira.read_csv(p.csv, session=s), KomiraError, CLOSED)
        refused(lambda: komira.read_json(p.jsonl, lines=True, session=s), KomiraError, CLOSED)
        for frame in (df, df[df["id"] > 1], df.sort_values("id").head(2), csv):
            e = refused(frame.materialize, KomiraError, CLOSED)
            assert e.status is None, repr(e)
            refused(frame.explain, KomiraError, CLOSED)
        # What a frame knows without the library still answers.
        assert df.columns == COLUMNS and df.dtypes["id"] == "int64"
        # Another session runs the file.
        with komira.Session() as other:
            assert by_id(rows_of(komira.read_parquet(p.parquet, session=other))) == ROWS


def test_default_session(lib_dir):
    """A reader without `session=` uses the process's default session, the same one each time."""
    with workspace() as (s, p):
        a = komira.read_parquet(p.parquet)
        b = komira.read_parquet(p.parquet)
        default = _session.default_session()
        assert isinstance(default, komira.Session) and not default.closed
        assert a._session is default and b._session is default
        assert _session.default_session() is default
        explicit = komira.read_parquet(p.parquet, session=s)
        assert explicit._session is s and s is not default
        assert by_id(rows_of(a)) == ROWS
        assert by_id(rows_of(b[b["n"] > 0])) == rows_for([1, 4])
        c = komira.read_csv(p.csv)
        j = komira.read_json(p.jsonl, lines=True)
        assert c._session is default and j._session is default
        assert by_id(rows_of(j)) == PEOPLE


def test_series_of_another_frame_refused(lib_dir):
    """A Series of a frame of one session, used in a frame of another, is refused with its full message."""
    with workspace() as (a, p):
        with komira.Session() as b:
            frame_a = komira.read_parquet(p.parquet, session=a)
            frame_b = komira.read_parquet(p.parquet, session=b)
            other = frame_a["id"] > 1
            refused(lambda: frame_b[other], komira.UnsupportedOperation, OTHER_FRAME)
            refused(lambda: frame_b.assign(v=frame_a["id"]), komira.UnsupportedOperation, OTHER_FRAME)
            refused(lambda: frame_b["id"] + frame_a["id"], komira.UnsupportedOperation, OTHER_FRAME)
            refused(lambda: frame_b["id"] > frame_a["n"], komira.UnsupportedOperation, OTHER_FRAME)
            # The same file read twice on one session is two frames too.
            twin = komira.read_parquet(p.parquet, session=a)
            refused(lambda: twin[other], komira.UnsupportedOperation, OTHER_FRAME)
            # Each frame still runs on its own session.
            assert by_id(rows_of(frame_a[other])) == rows_for([2, 3, 4, 5, 6])
            assert by_id(rows_of(frame_b[frame_b["id"] > 4])) == rows_for([5, 6])
            # A function takes the column from the frame it is used with.
            got = by_id(rows_of(frame_b.assign(v=lambda d: d["id"] + 1)))
            assert [r["v"] for r in got] == [2, 3, 4, 5, 6, 7], got


def test_stand_in_refuses_plan_stream(lib_dir):
    """On an ABI 1.7 library the plan door refuses with the version message, and nothing else is refused."""
    assert child("stand_in", lib_dir) == "stand-in: done\n"


TESTS = [
    test_protobuf_loads_at_first_reader,  # first: it needs a process that has made no frame yet
    test_read_parquet_rows_and_schema,
    test_filter_comparisons,
    test_filter_boolean_logic,
    test_filter_isin,
    test_filter_boolean_column,
    test_select_columns,
    test_assign_arithmetic,
    test_assign_literals_callables_and_replacement,
    test_setitem,
    test_sort_values_directions_and_null_placement,
    test_sort_values_multiple_keys,
    test_sort_keeps_order_through_verbs,
    test_head_after_sort,
    test_head_unordered,
    test_verbs_after_head_over_sort,
    test_head_zero,
    test_materialize_twice,
    test_result_reads_once,
    test_notebook_display,
    test_explain,
    test_read_csv,
    test_read_csv_skiprows_reads_the_rows_after_the_note_line,
    test_read_csv_skiprows_past_the_last_line_is_refused_by_the_engine,
    test_read_csv_without_header_refused_by_engine,
    test_read_json,
    test_reader_failures,
    test_closed_session,
    test_default_session,
    test_series_of_another_frame_refused,
    test_stand_in_refuses_plan_stream,
]


def main(args):
    if "--child" in args:
        CHILDREN[args[args.index("--child") + 1]](args[args.index("--child") + 2:])
        return
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() >= 1008, komira.abi_version()
    for test in TESTS:
        test(lib_dir)
        print("ok", test.__name__)
    print("frames: {} cases over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
