"""komira.read_parquet and komira.pl.scan_parquet of a glob or a directory,
on the real libkomira: the engine resolves the path into its files
(`komira_parquet_source`), as `Session.register_parquet` does, and the frame
runs through komira_plan_stream.

- a glob reads every file it matches and no other, their rows as one frame,
  and the scan lists the files in byte-wise sorted order whatever order they
  were written in; `**` matches files in folders below;
- a directory reads its `.parquet` files below it (not a file of another
  extension, not one under a folder whose name starts with `.`), with the
  `key=value` folders as columns after the files' own, ordered by key name,
  typed BIGINT or VARCHAR as the engine types them; a filter and a projection
  on a key column run;
- scan_parquet's `hive_partitioning`: None reads the keys of a directory and
  not of a glob; True reads them of a glob too, and refuses files whose keys
  differ (HIVE_PARTITION_LAYOUT_MISMATCH); False reads none; a value that is
  not a bool or None is a TypeError before the library is called;
  read_parquet reads the keys of a glob when every file has the same ones,
  and none when they differ;
- refusals at the reader, a BindError with the engine's message word for word:
  a glob that matches nothing names the pattern (PARQUET_GLOB_NO_MATCH), as
  does a directory with no `.parquet` file; files whose schemas differ name
  both files (PARQUET_FILES_SCHEMA_MISMATCH);
- `?`, `{a,b}` and `[...]` are glob characters too; a file that exists keeps
  the one-file route even when its name holds one (`part[1].parquet`): its
  schema through komira_parquet_schema, a source of that one path;
- one file is read as before: through komira_parquet_schema, never
  komira_parquet_source, with the same one-path source, and its folders'
  `key=value` names are not columns; a source that is not bytes is a
  TypeError;
- two komira.pl frames that read one path two ways are refused by join and
  concat, by name, rather than one frame's source standing in for the other's.

The test is of the `run/` family (python/tests/BUCK): `read_many_parquet_test`
runs on the real libkomira on each supported minor, with the generated plan
modules, protobuf 7.36.2 and pyarrow.

    test_read_many_parquet.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` (`--runtime-dir`, which
the rule passes, is not read).
"""

import contextlib
import os
import sys
import tempfile

import pyarrow as pa
import pyarrow.parquet as pq

import komira
import komira.pl as kpl
from komira import _native


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


class Spy:
    """The library's calls, recording the name of each one made."""

    def __init__(self, native):
        self.native = native
        self.calls = []

    def __getattr__(self, name):
        self.calls.append(name)
        return getattr(self.native, name)


def write(path, ids, names=None):
    """A Parquet file at `path` of `id` int64 and `name` string."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    names = names if names is not None else [f"n{i}" for i in ids]
    pq.write_table(pa.table({"id": pa.array(ids, pa.int64()), "name": pa.array(names, pa.string())}), path)
    return path


def rows(frame):
    """The rows of a komira or komira.pl frame, sorted by id."""
    result = frame.materialize() if isinstance(frame, komira.DataFrame) else frame.collect()
    return sorted(result.to_arrow().to_pylist(), key=lambda r: r["id"])


def paths_of(frame, path):
    """The files the scan of `path` in `frame` reads, in the order it lists them."""
    return list(frame._sources[path].parquet.paths)


def dtypes(frame):
    return dict(frame.dtypes) if isinstance(frame, komira.DataFrame) else {k: str(v) for k, v in frame.schema.items()}


@contextlib.contextmanager
def work():
    """A session and a directory removed afterwards."""
    with tempfile.TemporaryDirectory() as d:
        with komira.Session() as s:
            yield s, os.path.realpath(d)


def sales(d):
    """Three month files written out of order, and two files the pattern
    `sales_*.parquet` does not match."""
    files = {
        "mar": write(os.path.join(d, "sales_mar.parquet"), [4, 5]),
        "jan": write(os.path.join(d, "sales_jan.parquet"), [1, 2]),
        "feb": write(os.path.join(d, "sales_feb.parquet"), [3]),
    }
    write(os.path.join(d, "notes.parquet"), [9])
    with open(os.path.join(d, "sales_apr.csv"), "w") as f:
        f.write("id,name\n8,x\n")
    return files


ALL = [{"id": i, "name": f"n{i}"} for i in (1, 2, 3, 4, 5)]


def hive(d):
    """year=/month= folders, two files, and two that a directory read skips."""
    write(os.path.join(d, "year=2026", "month=jan", "a.parquet"), [1, 2])
    write(os.path.join(d, "year=2027", "month=feb", "b.parquet"), [3])
    write(os.path.join(d, ".hidden", "year=2028", "month=mar", "c.parquet"), [7])
    with open(os.path.join(d, "year=2026", "month=jan", "readme.txt"), "w") as f:
        f.write("not parquet")


KEYED = [
    {"id": 1, "name": "n1", "month": "jan", "year": 2026},
    {"id": 2, "name": "n2", "month": "jan", "year": 2026},
    {"id": 3, "name": "n3", "month": "feb", "year": 2027},
]


# ---- the tests -----------------------------------------------------------------


def test_a_glob_reads_every_match_as_one_frame_in_sorted_order():
    with work() as (s, d):
        files = sales(d)
        pattern = os.path.join(d, "sales_*.parquet")
        want = [files["feb"], files["jan"], files["mar"]]
        df = komira.read_parquet(pattern, session=s)
        assert df.columns == ["id", "name"], df.columns
        assert paths_of(df, pattern) == want, paths_of(df, pattern)
        assert rows(df) == ALL, rows(df)
        lf = kpl.scan_parquet(pattern, session=s)
        assert paths_of(lf, pattern) == want, paths_of(lf, pattern)
        assert rows(lf) == ALL, rows(lf)
        # Verbs run over the many files as over one.
        assert rows(df[df["id"] > 2]) == ALL[2:]
        assert lf.select(kpl.col("id").sum()).collect().to_arrow().to_pylist() == [{"id": 15}]


def test_a_relative_glob_is_resolved_against_the_working_directory():
    with work() as (s, d):
        sales(d)
        here = os.getcwd()
        os.chdir(d)
        try:
            df = komira.read_parquet("sales_*.parquet", session=s)
        finally:
            os.chdir(here)
        assert rows(df) == ALL, rows(df)


def test_a_double_star_glob_matches_files_in_folders_below():
    with work() as (s, d):
        write(os.path.join(d, "a", "x.parquet"), [1])
        write(os.path.join(d, "a", "b", "y.parquet"), [2])
        pattern = os.path.join(d, "**", "*.parquet")
        assert [r["id"] for r in rows(komira.read_parquet(pattern, session=s))] == [1, 2]
        assert [r["id"] for r in rows(kpl.scan_parquet(pattern, session=s))] == [1, 2]


def test_a_directory_reads_its_files_with_the_keys_as_columns():
    with work() as (s, d):
        hive(d)
        df = komira.read_parquet(d, session=s)
        assert df.columns == ["id", "name", "month", "year"], df.columns
        assert dtypes(df)["year"] == "int64" and dtypes(df)["id"] == "int64", dtypes(df)
        assert rows(df) == KEYED, rows(df)
        assert rows(df[df["year"] == 2026][["id", "year"]]) == [{"id": 1, "year": 2026}, {"id": 2, "year": 2026}]
        lf = kpl.scan_parquet(d, session=s)
        assert list(lf.schema) == ["id", "name", "month", "year"], lf.schema
        assert rows(lf) == KEYED, rows(lf)
        assert rows(lf.filter(kpl.col("month") == "feb").select("id", "month")) == [{"id": 3, "month": "feb"}]
        want = [
            os.path.join(d, "year=2026", "month=jan", "a.parquet"),
            os.path.join(d, "year=2027", "month=feb", "b.parquet"),
        ]
        assert paths_of(lf, d) == want, paths_of(lf, d)


def test_scan_parquet_hive_partitioning():
    with work() as (s, d):
        hive(d)
        pattern = os.path.join(d, "year=*", "month=*", "*.parquet")
        plain = [{"id": r["id"], "name": r["name"]} for r in KEYED]
        # None: the keys of a directory, not of a glob.
        assert rows(kpl.scan_parquet(pattern, session=s)) == plain
        assert rows(kpl.scan_parquet(pattern, hive_partitioning=True, session=s)) == KEYED
        assert rows(kpl.scan_parquet(d, hive_partitioning=True, session=s)) == KEYED
        assert rows(kpl.scan_parquet(d, hive_partitioning=False, session=s)) == plain
        assert rows(kpl.scan_parquet(pattern, hive_partitioning=False, session=s)) == plain
        # read_parquet reads the keys of a glob whose files all have them.
        assert rows(komira.read_parquet(pattern, session=s)) == KEYED
        e = raised(lambda: kpl.scan_parquet(d, hive_partitioning="yes", session=s))
        assert type(e) is TypeError and str(e) == "hive_partitioning must be a bool or None, not str", repr(e)
        e = raised(lambda: kpl.scan_parquet(d, hive_partitioning=1, session=s))
        assert type(e) is TypeError and str(e) == "hive_partitioning must be a bool or None, not int", repr(e)


def test_files_whose_keys_differ():
    with work() as (s, d):
        write(os.path.join(d, "year=2026", "a.parquet"), [1])
        write(os.path.join(d, "region=emea", "b.parquet"), [2])
        # Keys that differ are no columns where the keys are read when there.
        assert komira.read_parquet(d, session=s).columns == ["id", "name"]
        assert list(kpl.scan_parquet(d, session=s).schema) == ["id", "name"]
        # And refused where the keys are asked for.
        e = raised(lambda: kpl.scan_parquet(d, hive_partitioning=True, session=s))
        assert type(e) is komira.BindError and e.step == "bind", repr(e)
        assert str(e).startswith("HIVE_PARTITION_LAYOUT_MISMATCH: "), str(e)
        assert e.code == "HIVE_PARTITION_LAYOUT_MISMATCH", e.code


def test_a_glob_that_matches_nothing_is_refused_naming_it():
    with work() as (s, d):
        sales(d)
        pattern = os.path.join(d, "sales_*.json")
        message = f"PARQUET_GLOB_NO_MATCH: no file matches '{pattern}'"
        for read in (komira.read_parquet, kpl.scan_parquet):
            e = refused(lambda: read(pattern, session=s), komira.BindError, message)
            assert (e.status, e.step, e.code) == (-3, "bind", "PARQUET_GLOB_NO_MATCH"), (e.status, e.step, e.code)
        empty = os.path.join(d, "empty")
        os.mkdir(empty)
        message = f"PARQUET_GLOB_NO_MATCH: the directory '{empty}' holds no .parquet file"
        refused(lambda: komira.read_parquet(empty, session=s), komira.BindError, message)
        refused(lambda: kpl.scan_parquet(empty, session=s), komira.BindError, message)
        # The session still answers.
        assert rows(komira.read_parquet(os.path.join(d, "sales_*.parquet"), session=s)) == ALL


def test_files_of_two_schemas_are_refused_naming_both():
    with work() as (s, d):
        first = write(os.path.join(d, "a.parquet"), [1])
        other = os.path.join(d, "b.parquet")
        pq.write_table(pa.table({"id": pa.array([2], pa.int32()), "name": pa.array(["x"])}), other)
        for read in (komira.read_parquet, kpl.scan_parquet):
            e = raised(lambda: read(os.path.join(d, "*.parquet"), session=s))
            assert type(e) is komira.BindError, repr(e)
            assert str(e).startswith(f"PARQUET_FILES_SCHEMA_MISMATCH: '{other}' differs from '{first}': "), str(e)


def test_one_file_reads_as_before():
    with work() as (s, d):
        f = write(os.path.join(d, "year=2026", "one.parquet"), [1, 2])
        spy = Spy(s._native)
        s._native = spy
        df = komira.read_parquet(f, session=s)
        lf = kpl.scan_parquet(f, session=s)
        assert spy.calls == ["parquet_schema", "parquet_schema"], spy.calls
        from komira import _plan

        want = _plan.parquet_source(f, spy.native.parquet_schema(s._ctx, f))
        assert df._sources[f] == want and lf._sources[f] == want
        # The folder's `key=value` name is not a column of one file.
        assert df.columns == ["id", "name"] and list(lf.schema) == ["id", "name"]
        assert rows(df) == [{"id": 1, "name": "n1"}, {"id": 2, "name": "n2"}]
        # hive_partitioning=True asks for the keys of one file's folders too.
        spy.calls.clear()
        keyed = kpl.scan_parquet(f, hive_partitioning=True, session=s)
        assert spy.calls == ["parquet_source"], spy.calls
        assert rows(keyed) == [{"id": 1, "name": "n1", "year": 2026}, {"id": 2, "name": "n2", "year": 2026}]


def test_two_frames_that_read_one_path_two_ways_are_refused():
    with work() as (s, d):
        hive(d)
        keyed = kpl.scan_parquet(d, session=s)
        plain = kpl.scan_parquet(d, hive_partitioning=False, session=s)
        refused(
            lambda: keyed.join(plain, on="id"),
            komira.UnsupportedOperation,
            f"join: the two frames read {d!r} in two ways (other reader options, or files that changed "
            "between the reads): read it once, and take both frames from that one",
        )
        flat = os.path.join(d, "flat")
        write(os.path.join(flat, "a.parquet"), [1])
        pattern = os.path.join(flat, "*.parquet")
        before = kpl.scan_parquet(pattern, session=s)
        write(os.path.join(flat, "b.parquet"), [2, 3, 4])
        after = kpl.scan_parquet(pattern, session=s)
        refused(
            lambda: kpl.concat([before, after]),
            komira.UnsupportedOperation,
            f"concat: two frames read {pattern!r} in two ways (other reader options, or files that changed "
            "between the reads): read it once, and take both frames from that one",
        )
        # One frame read once joins and concatenates with itself.
        assert len(rows(kpl.concat([after, after]))) == 8
        assert len(rows(keyed.join(keyed, on="id"))) == 3


def test_the_other_glob_characters_and_a_file_named_with_one():
    with work() as (s, d):
        sales(d)
        q = os.path.join(d, "sales_?a?.parquet")
        assert [r["id"] for r in rows(komira.read_parquet(q, session=s))] == [1, 2, 4, 5]
        braces = os.path.join(d, "sales_{jan,feb}.parquet")
        assert [r["id"] for r in rows(kpl.scan_parquet(braces, session=s))] == [1, 2, 3]
        brackets = os.path.join(d, "sales_[fm]*.parquet")
        assert [r["id"] for r in rows(komira.read_parquet(brackets, session=s))] == [3, 4, 5]
        # A file that exists keeps the one-file reader route, whatever its
        # name holds: its schema through komira_parquet_schema and a source
        # of that one path, as before komira_parquet_source existed.
        literal = write(os.path.join(d, "part[1].parquet"), [6])
        write(os.path.join(d, "part1.parquet"), [7])
        spy = Spy(s._native)
        s._native = spy
        df = komira.read_parquet(literal, session=s)
        lf = kpl.scan_parquet(literal, session=s)
        assert spy.calls == ["parquet_schema", "parquet_schema"], spy.calls
        assert paths_of(df, literal) == [literal] and paths_of(lf, literal) == [literal]


def test_a_source_is_bytes_of_the_library():
    from komira import _plan

    e = raised(lambda: _plan.parquet_files_source("paths"))
    assert type(e) is TypeError and str(e) == "source must be bytes, not str", repr(e)


TESTS = [
    test_a_glob_reads_every_match_as_one_frame_in_sorted_order,
    test_a_relative_glob_is_resolved_against_the_working_directory,
    test_a_double_star_glob_matches_files_in_folders_below,
    test_a_directory_reads_its_files_with_the_keys_as_columns,
    test_scan_parquet_hive_partitioning,
    test_files_whose_keys_differ,
    test_a_glob_that_matches_nothing_is_refused_naming_it,
    test_files_of_two_schemas_are_refused_naming_both,
    test_one_file_reads_as_before,
    test_two_frames_that_read_one_path_two_ways_are_refused,
    test_the_other_glob_characters_and_a_file_named_with_one,
    test_a_source_is_bytes_of_the_library,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() >= 1011, komira.abi_version()
    for test in TESTS:
        test()
        print("ok", test.__name__)
    print("read many parquet: {} cases over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
