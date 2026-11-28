"""Session.register_csv and Session.register_json on the real libkomira, read
back with Session.sql as pyarrow:

- a CSV file (people.csv: `id`, `name`, `score`, an empty `name` and an empty
  `score`) and a newline-delimited JSON file (events.jsonl: the same columns,
  a `null` name and a record with no `score`) register under the name given
  and answer with the names, types and rows the engine infers, NULL where the
  file has no value, and with the schema and rows of `read_csv` and
  `read_json` over the same file;
- each dialect argument is the one the file is read with: `delimiter="|"`
  reads people_pipe.csv as the same rows, `all_varchar=True` makes every
  column a string, and a table registered with `header=False` is refused when
  a query reads it, naming `header=false`: an UnsupportedOperation at step
  "lower" with code LOWERING_UNCUTTABLE_NODE;
- a `pathlib.Path`, a relative path and a path under `~` are resolved when
  the call is made, so the table still answers after the working directory
  and HOME change back;
- a missing file and an empty file raise BindError (step "bind"), status
  -3, with the engine's message (its last error), which names the absolute
  path, and register nothing; a name the session already has, from either
  call or from register_parquet and in another case, raises BindError with
  code TABLE_ALREADY_REGISTERED word for word, and the first table keeps
  answering with its rows;
- a glob pattern registers every file it matches as one table: `peo?le.csv`
  and `**/events.jsonl` (no folder below) each read their one file's rows,
  as SQL's `read_csv` of the same pattern does; `people*.csv` matches
  people.csv and people_pipe.csv, whose columns differ, and raises BindError
  with code CSV_FILES_SCHEMA_MISMATCH naming both files; a pattern matching
  nothing raises BindError with code CSV_GLOB_NO_MATCH or JSON_GLOB_NO_MATCH
  and the absolute pattern word for word; none of the refused ones registers;
- arguments of the wrong type or value raise TypeError or ValueError before
  the library is called, and a closed session raises KomiraError.

    test_register_text.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`; `<dir>/people.csv`,
`<dir>/people_pipe.csv`, `<dir>/events.jsonl` and `<dir>/empty.txt` are the
fixtures of python/tests/fixtures, and `<dir>/two_columns.parquet` a Parquet
file.
"""

import os
import pathlib
import sys

import pyarrow as pa

import komira
from komira import KomiraError
from komira import _native

# people.csv and people_pipe.csv, in the order of `id`.
PEOPLE = [
    {"id": 1, "name": "ann", "score": 10.5},
    {"id": 2, "name": None, "score": 20.0},
    {"id": 3, "name": "cy", "score": None},
]

# events.jsonl, in the order of `id`: the same rows.
EVENTS = PEOPLE


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def is_text(t):
    return pa.types.is_string(t) or pa.types.is_large_string(t) or pa.types.is_string_view(t)


def rows(s, table):
    """Every row of `table`, in the order of `id`, and the answer's schema."""
    t = s.sql("SELECT * FROM {} ORDER BY id".format(table)).to_arrow()
    return t.to_pylist(), t.schema


def fields(schema):
    return [(f.name, f.type) for f in schema]


def check_people_schema(schema):
    """`id` BIGINT, `name` a string and `score` DOUBLE, in the file's order."""
    assert schema.names == ["id", "name", "score"], schema
    assert schema.field("id").type == pa.int64(), schema
    assert is_text(schema.field("name").type), schema
    assert schema.field("score").type == pa.float64(), schema


def check_refused(s, call, path):
    """`call` registers nothing and raises the engine's BindError, at step
    "bind", which names the absolute `path`."""
    e = raised(call)
    assert type(e) is komira.BindError and e.status == -3 and e.step == "bind", repr(e)
    assert str(e) == _native.load().last_error(s._ctx), str(e)
    assert "'{}'".format(path) in str(e), str(e)


def main(args):
    # Absolute, since the paths the rule passes are relative to where the
    # action started.
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() >= 1005, komira.abi_version()
    people = os.path.join(lib_dir, "people.csv")
    pipe = os.path.join(lib_dir, "people_pipe.csv")
    events = os.path.join(lib_dir, "events.jsonl")
    empty = os.path.join(lib_dir, "empty.txt")
    parquet = os.path.join(lib_dir, "two_columns.parquet")

    with komira.Session() as s:
        # A CSV file: the names, types and rows the engine infers, with NULL
        # for an empty field of a string and of a number column.
        assert s.register_csv("people", people) is None
        got, schema = rows(s, "people")
        check_people_schema(schema)
        assert got == PEOPLE, got
        # The registered table is read_csv of the same file.
        want = s.sql("SELECT * FROM read_csv('{}') ORDER BY id".format(people)).to_arrow()
        assert fields(want.schema) == fields(schema), (want.schema, schema)
        assert want.to_pylist() == got, want.to_pylist()

        # A JSON file: a null value and a missing key are both NULL.
        assert s.register_json("events", events) is None
        got, schema = rows(s, "events")
        check_people_schema(schema)
        assert got == EVENTS, got
        want = s.sql("SELECT * FROM read_json('{}') ORDER BY id".format(events)).to_arrow()
        assert fields(want.schema) == fields(schema), (want.schema, schema)
        assert want.to_pylist() == got, want.to_pylist()

        # A table is found by its name in any case.
        n = s.sql("SELECT count(*) AS n FROM PEOPLE").to_arrow().to_pylist()
        assert n == [{"n": 3}], n

        # The dialect arguments.
        assert s.register_csv("piped", pipe, delimiter="|") is None
        got, schema = rows(s, "piped")
        check_people_schema(schema)
        assert got == PEOPLE, got
        assert s.register_csv("strings", people, all_varchar=True) is None
        t = s.sql("SELECT id FROM strings ORDER BY id").to_arrow()
        assert t.to_pylist() == [{"id": "1"}, {"id": "2"}, {"id": "3"}], t.to_pylist()
        t = s.sql("SELECT * FROM strings").to_arrow()
        assert t.schema.names == ["id", "name", "score"], t.schema
        assert all(is_text(f.type) for f in t.schema), t.schema
        assert s.register_csv("headless", people, header=False) is None
        e = raised(lambda: s.sql("SELECT * FROM headless"))
        assert type(e) is komira.UnsupportedOperation and e.status == -3, repr(e)
        assert (e.step, e.code) == ("lower", "LOWERING_UNCUTTABLE_NODE"), (e.step, e.code)
        assert str(e).startswith("lower: ") and "header=false" in str(e), str(e)

        # A pathlib.Path, a relative path and a path under `~`, resolved
        # when the call is made: each table still answers once the working
        # directory and HOME are put back (the runner writes its result to a
        # path relative to where the action started).
        assert s.register_csv("by_path", pathlib.Path(people)) is None
        assert s.register_json("by_path_j", pathlib.Path(events)) is None
        cwd, home = os.getcwd(), os.environ.get("HOME")
        try:
            os.chdir(lib_dir)
            assert s.register_csv("rel", "people.csv") is None
            assert s.register_json("rel_j", "events.jsonl") is None
            os.environ["HOME"] = lib_dir
            assert s.register_csv("home", "~/people.csv") is None
            assert s.register_json("home_j", "~/events.jsonl") is None
        finally:
            os.chdir(cwd)
            if home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = home
        for table in ("by_path", "by_path_j", "rel", "rel_j", "home", "home_j"):
            got, _ = rows(s, table)
            assert got == PEOPLE, (table, got)

        # A missing file, given as a relative path, and an empty file: the
        # engine's message names the absolute path, and nothing is
        # registered under the name.
        gone = os.path.join(cwd, "no_such_file.csv")
        check_refused(s, lambda: s.register_csv("gone", "no_such_file.csv"), gone)
        check_refused(s, lambda: s.register_json("gone_j", "no_such_file.csv"), gone)
        check_refused(s, lambda: s.register_csv("empty", empty), empty)
        check_refused(s, lambda: s.register_json("empty_j", empty), empty)
        for table in ("gone", "gone_j", "empty", "empty_j"):
            e = raised(lambda: s.sql("SELECT * FROM {}".format(table)))
            assert type(e) is komira.BindError and e.status == -3, (table, repr(e))
            assert (e.step, e.code) == ("bind", "SQL_BIND_ERROR"), (table, e.step, e.code)
        # A refused call leaves the session usable: the name is still free.
        assert s.register_csv("gone", people) is None
        got, _ = rows(s, "gone")
        assert got == PEOPLE, got

        # A name the session already has, from either call, from
        # register_parquet, or in another case, is refused word for word and
        # the first table keeps its rows.
        assert s.register_parquet("pq", parquet) is None
        taken = "TABLE_ALREADY_REGISTERED: the session already has a table named '{}'"
        for call, name in (
            (lambda: s.register_csv("people", events), "people"),
            (lambda: s.register_json("PEOPLE", events), "PEOPLE"),
            (lambda: s.register_csv("Events", people), "Events"),
            (lambda: s.register_json("events", events), "events"),
            (lambda: s.register_csv("pq", people), "pq"),
            (lambda: s.register_json("pq", events), "pq"),
        ):
            e = raised(call)
            assert type(e) is komira.BindError and e.status == -3, repr(e)
            assert (e.step, e.code) == ("bind", "TABLE_ALREADY_REGISTERED"), (e.step, e.code)
            assert str(e) == taken.format(name), str(e)
        got, _ = rows(s, "people")
        assert got == PEOPLE, got
        got, _ = rows(s, "events")
        assert got == EVENTS, got

        # A glob pattern: every file it matches, as one table.
        assert s.register_csv("one_of", os.path.join(lib_dir, "peo?le.csv")) is None
        got, _ = rows(s, "one_of")
        assert got == PEOPLE, got
        pattern = os.path.join(lib_dir, "peo?le.csv")
        want = s.sql("SELECT * FROM read_csv('{}') ORDER BY id".format(pattern)).to_arrow()
        assert want.to_pylist() == PEOPLE, want.to_pylist()
        assert s.register_json("deep_j", os.path.join(lib_dir, "**", "events.jsonl")) is None
        got, _ = rows(s, "deep_j")
        assert got == EVENTS, got
        both = os.path.join(lib_dir, "people*.csv")
        e = raised(lambda: s.register_csv("both", both))
        assert type(e) is komira.BindError and e.status == -3, repr(e)
        assert (e.step, e.code) == ("bind", "CSV_FILES_SCHEMA_MISMATCH"), (e.step, e.code)
        assert str(e).startswith("CSV_FILES_SCHEMA_MISMATCH: '{}' differs from '{}': ".format(pipe, people)), str(e)
        none_csv = os.path.join(lib_dir, "nomatch_*.csv")
        none_json = os.path.join(lib_dir, "nomatch_*.jsonl")
        for call, code, pat in (
            (lambda: s.register_csv("none", none_csv), "CSV_GLOB_NO_MATCH", none_csv),
            (lambda: s.register_json("none_j", none_json), "JSON_GLOB_NO_MATCH", none_json),
        ):
            e = raised(call)
            assert type(e) is komira.BindError and e.status == -3, repr(e)
            assert (e.step, e.code) == ("bind", code), (e.step, e.code)
            assert str(e) == "{}: no file matches '{}'".format(code, pat), str(e)
        for table in ("both", "none", "none_j"):
            e = raised(lambda: s.sql("SELECT * FROM {}".format(table)))
            assert type(e) is komira.BindError and e.status == -3, (table, repr(e))

        # Arguments are checked before the library is called.
        for call in (s.register_csv, s.register_json):
            e = raised(lambda: call(b"t", people))
            assert type(e) is TypeError and str(e) == "name must be a str, not bytes", repr(e)
            e = raised(lambda: call("", people))
            assert type(e) is ValueError and str(e) == "name is empty", repr(e)
            e = raised(lambda: call("t\0u", people))
            assert type(e) is ValueError and str(e) == "name holds a NUL byte", repr(e)
            e = raised(lambda: call("t", 3))
            assert type(e) is TypeError and str(e) == "path must be a str or os.PathLike[str], not int", repr(e)
            e = raised(lambda: call("t", people.encode()))
            assert type(e) is TypeError and str(e) == "path must be a str or os.PathLike[str], not bytes", repr(e)
            e = raised(lambda: call("t", people + "\0"))
            assert type(e) is ValueError and str(e) == "path holds a NUL byte", repr(e)
        for delimiter in ("", ",,", "é"):
            e = raised(lambda: s.register_csv("t", people, delimiter=delimiter))
            want = "delimiter must be one ASCII character, not {!r}".format(delimiter)
            assert type(e) is ValueError and str(e) == want, repr(e)
        e = raised(lambda: s.register_csv("t", people, delimiter=b","))
        assert type(e) is TypeError and str(e) == "delimiter must be a str, not bytes", repr(e)
        e = raised(lambda: s.register_csv("t", people, header=1))
        assert type(e) is TypeError and str(e) == "header must be a bool, not int", repr(e)
        e = raised(lambda: s.register_csv("t", people, all_varchar="yes"))
        assert type(e) is TypeError and str(e) == "all_varchar must be a bool, not str", repr(e)
        e = raised(lambda: s.register_csv("t", people, ","))
        assert type(e) is TypeError, repr(e)
        # None of them registered "t".
        e = raised(lambda: s.sql("SELECT * FROM t"))
        assert type(e) is komira.BindError and e.status == -3, repr(e)

    # A closed session refuses both calls.
    assert s.closed
    for call in (lambda: s.register_csv("t", people), lambda: s.register_json("t", events)):
        e = raised(call)
        assert type(e) is KomiraError and str(e) == "the session is closed" and e.status is None, repr(e)
    print("register_text: libkomira {} registers CSV and JSON files and patterns".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
