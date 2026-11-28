"""`drop_duplicates(subset=...)` and `duplicated()` of the pandas-shaped
DataFrame on the real libkomira, held to DuckDB over the same Parquet file
(`frame_duplicates_duckdb_test`, CPython 3.13). Each frame program runs
through komira's plan door (`komira_plan_stream`, no SQL).

A plan has no row order, so for keep="first" and keep="last" the row kept of a
value is any one of its rows (docs/design/dataframe_surface.md, section 7).
Those answers are checked for what they promise:

- one row for each value of the subset: the subset's values of the answer, as
  a multiset, are DuckDB's `SELECT DISTINCT <subset>`, each once, NULL a value
  of its own;
- whole rows: every column of the frame, and each answer row is a row of the
  file (the answer is a sub-multiset of the file's rows).

The answers that do not depend on a choice are equal to DuckDB's as
multisets: keep=False (the rows whose subset value no other row has,
`COUNT(*) OVER (PARTITION BY <subset>) = 1`), `duplicated(keep=False)`
assigned as a column (`COUNT(*) OVER (...) > 1`), and a subset naming every
column (`SELECT DISTINCT *`, as plain drop_duplicates()).

- the file: 14 rows built in code, no randomness. `id` int64, unique; `name`
  string with NULLs and repeats; `city` string with NULLs; `score` float64
  with NULLs and repeats (no NaN); `flag` bool with NULLs; `n` int32 with
  repeats: one key of each type the engine's window serves;
- drop_duplicates over one key of each type, two keys, keep "first", "last"
  and False, a sorted frame, a sort and head after it;
- duplicated: keep=False assigned, keep="first" assigned (exactly one false
  row per value, every row kept), and `df[~df.duplicated(...)]` and
  `df[df.duplicated(...)]` splitting the rows.

Every case runs even when an earlier one fails, and the test then fails
naming each failing case and why.

    test_frame_duplicates_duckdb.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which the
rule passes, is not read).
"""

import collections
import os
import sys
import tempfile

import komira
from komira import _native

COLUMNS = ("id", "name", "city", "score", "flag", "n")
DATA = {
    "id": list(range(14)),
    "name": ["Ana", "Bo", "Ana", None, "Cy", "Bo", "Ana", None, "Dee", "Bo", "Eve", "Ana", "Cy", "Fay"],
    "city": ["Oslo", "Rome", "Oslo", "Lima", "Oslo", "Rome", "Lima", None, "Kyiv", "Rome", "Oslo", "Oslo", None, "Rome"],
    "score": [1.5, None, 1.5, 2.0, 0.25, None, 3.0, 2.0, None, -1.0, 4.5, 1.5, 0.25, 8.0],
    "flag": [True, False, True, None, True, False, None, False, True, True, False, True, True, None],
    "n": [1, 2, 1, 4, 5, 2, 7, 4, 9, 2, 11, 1, 5, 14],
}


def write_data(path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    types = {"id": pa.int64(), "name": pa.string(), "city": pa.string(), "score": pa.float64(),
             "flag": pa.bool_(), "n": pa.int32()}
    pq.write_table(pa.table({c: pa.array(DATA[c], types[c]) for c in COLUMNS}), path, row_group_size=5)
    return path


def duckdb_for(path):
    import duckdb

    con = duckdb.connect()
    con.execute("CREATE VIEW t AS SELECT * FROM read_parquet('{}')".format(path.replace("'", "''")))
    return con


def duckdb_rows(con, sql):
    return [tuple(r) for r in con.execute(sql).fetchall()]


def rows_of(frame):
    table = frame.materialize().to_arrow()
    names = list(table.column_names)
    return names, [tuple(r[n] for n in names) for r in table.to_pylist()]


def multiset(rows):
    return collections.Counter(rows)


def sql_list(subset):
    return ", ".join(subset)


# The cases that failed, each with why.
FAILED = []


def check(name, step):
    try:
        step()
    except (AssertionError, komira.KomiraError) as e:
        FAILED.append("{}: {}: {}".format(name, type(e).__name__, e))


# ---- what a keep="first" or "last" answer promises -----------------------------------


def one_row_per_value(con, file_rows, subset, names, got):
    """`got` holds one whole row of each value of `subset`, each a row of the file."""
    assert names == list(COLUMNS), names
    at = [names.index(c) for c in subset]
    values = multiset(tuple(r[i] for i in at) for r in got)
    want = multiset(duckdb_rows(con, "SELECT DISTINCT {} FROM t".format(sql_list(subset))))
    assert values == want, "the subset's values are {}, DuckDB's DISTINCT {}".format(sorted(values.items(), key=repr),
                                                                                    sorted(want.items(), key=repr))
    extra = multiset(got) - multiset(file_rows)
    assert not extra, "rows that are not rows of the file: {}".format(sorted(extra, key=repr))


def unique_values_sql(subset):
    return ("SELECT {cols} FROM (SELECT *, COUNT(*) OVER (PARTITION BY {keys}) AS c FROM t) WHERE c = 1"
            .format(cols=sql_list(COLUMNS), keys=sql_list(subset)))


def test_drop_duplicates_keeps_one_whole_row_of_each_subset_value(con, session, path):
    df = komira.read_parquet(path, session=session)
    file_rows = duckdb_rows(con, "SELECT {} FROM t".format(sql_list(COLUMNS)))
    for subset in (["name"], ["city"], ["flag"], ["score"], ["n"], ["name", "city"], ["city", "flag"]):
        for keep in ("first", "last"):
            def step(subset=subset, keep=keep):
                names, got = rows_of(df.drop_duplicates(subset=subset, keep=keep))
                one_row_per_value(con, file_rows, subset, names, got)
            check("drop_duplicates(subset={}, keep={!r})".format(subset, keep), step)

    def sorted_first():
        names, got = rows_of(df.sort_values("id").drop_duplicates("name"))
        one_row_per_value(con, file_rows, ["name"], names, got)
    check("drop_duplicates of a sorted frame", sorted_first)

    def sorted_after():
        names, got = rows_of(df.drop_duplicates(["name"]).sort_values("id"))
        one_row_per_value(con, file_rows, ["name"], names, got)
        ids = [r[0] for r in got]
        assert ids == sorted(ids), "not in the order of id: {}".format(ids)
        # A second run may keep other rows of a value: the head is held to
        # what it promises, three rows of three values, in the order of id.
        names, top = rows_of(df.drop_duplicates(["name"]).sort_values("id").head(3))
        assert len(top) == 3 and len({r[1] for r in top}) == 3, top
        assert [r[0] for r in top] == sorted(r[0] for r in top), top
        assert not multiset(top) - multiset(file_rows), top
    check("drop_duplicates then a sort and a head", sorted_after)


def test_drop_duplicates_keep_false_equals_duckdb_rows_of_a_count_of_1(con, session, path):
    df = komira.read_parquet(path, session=session)
    for subset in (["name"], ["city"], ["score"], ["n"], ["flag", "city"], ["name", "city"]):
        def step(subset=subset):
            names, got = rows_of(df.drop_duplicates(subset=subset, keep=False))
            assert names == list(COLUMNS), names
            want = duckdb_rows(con, unique_values_sql(subset))
            assert want, "DuckDB's answer is empty: the case tests nothing"
            assert multiset(got) == multiset(want), "komira {}, DuckDB {}".format(sorted(got), sorted(want))
        check("drop_duplicates(subset={}, keep=False)".format(subset), step)


def test_a_subset_naming_every_column_equals_plain_drop_duplicates(con, session, path):
    df = komira.read_parquet(path, session=session)[["name", "city"]]

    def step():
        _, got = rows_of(df.drop_duplicates(subset=["city", "name"]))
        _, plain = rows_of(df.drop_duplicates())
        want = duckdb_rows(con, "SELECT DISTINCT name, city FROM t")
        assert multiset(got) == multiset(plain) == multiset(want), (got, plain, want)
    check("drop_duplicates with a subset of every column", step)


def test_duplicated_equals_duckdb_counts_and_splits_the_rows(con, session, path):
    df = komira.read_parquet(path, session=session)
    file_rows = duckdb_rows(con, "SELECT {} FROM t".format(sql_list(COLUMNS)))
    for subset in (["name"], ["name", "city"], ["flag"]):
        def every(subset=subset):
            names, got = rows_of(df.assign(dup=df.duplicated(subset, keep=False)))
            assert names == list(COLUMNS) + ["dup"], names
            want = duckdb_rows(con, "SELECT {}, COUNT(*) OVER (PARTITION BY {}) > 1 AS dup FROM t".format(
                sql_list(COLUMNS), sql_list(subset)))
            assert multiset(got) == multiset(want), "komira {}, DuckDB {}".format(sorted(got, key=repr),
                                                                                 sorted(want, key=repr))
        check("duplicated({}, keep=False) assigned".format(subset), every)

        def first(subset=subset):
            names, got = rows_of(df.assign(dup=df.duplicated(subset)))
            at = [names.index(c) for c in subset]
            assert multiset(r[:-1] for r in got) == multiset(file_rows), "assign changed the rows"
            unmarked = multiset(tuple(r[i] for i in at) for r in got if r[-1] is False)
            want = multiset(duckdb_rows(con, "SELECT DISTINCT {} FROM t".format(sql_list(subset))))
            assert unmarked == want, "the rows left false are {}, not one of each value {}".format(
                sorted(unmarked.items(), key=repr), sorted(want.items(), key=repr))
            assert all(r[-1] in (True, False) for r in got), "a duplicated value is missing"
        check("duplicated({}) assigned".format(subset), first)

        def split(subset=subset):
            names, kept = rows_of(df[~df.duplicated(subset)])
            one_row_per_value(con, file_rows, subset, names, kept)
            _, dropped = rows_of(df[df.duplicated(subset)])
            # Two plans, each with its own choice of row: only the counts add up.
            assert len(kept) + len(dropped) == len(file_rows), (len(kept), len(dropped))
        check("df[~duplicated({})] and df[duplicated({})]".format(subset, subset), split)


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    # The library is loaded before pyarrow and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    tests = (
        test_drop_duplicates_keeps_one_whole_row_of_each_subset_value,
        test_drop_duplicates_keep_false_equals_duckdb_rows_of_a_count_of_1,
        test_a_subset_naming_every_column_equals_plain_drop_duplicates,
        test_duplicated_equals_duckdb_counts_and_splits_the_rows,
    )
    with tempfile.TemporaryDirectory() as work:
        path = write_data(os.path.join(work, "frame.parquet"))
        con = duckdb_for(path)
        with komira.Session() as session:
            for test in tests:
                test(con, session, path)
    assert not FAILED, "{} cases failed:\n".format(len(FAILED)) + "\n".join(FAILED)
    print("frame duplicates duckdb: {} tests".format(len(tests)))


if __name__ == "__main__":
    main(sys.argv[1:])
