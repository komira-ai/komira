"""The pandas-shaped `Series.str.strip`, `lstrip` and `rstrip` on the real
libkomira, held to Python's `str.strip`, `str.lstrip` and `str.rstrip`, which
pandas applies to each value, and to DuckDB's `trim(s, chars)`, `ltrim` and
`rtrim`, over one Parquet file pyarrow writes here; the SQL `trim(s, chars)` of
a komira `Session` is held to DuckDB's too (`str_strip_duckdb_test`, CPython 3.13).

The file's `s` holds spaces, a tab, a newline, a vertical tab, a form feed, a
carriage return, a non-breaking space, an ideographic space, U+001C and U+001F
(whitespace to Python), a zero-width space (whitespace to no one), a string of
whitespace only, an empty string, a NULL, the set `xy` at both ends and
inside, and two-byte characters beside characters that share their first byte.
Covered:

- `strip()`, `lstrip()` and `rstrip()` with no argument remove every
  character Python's `str.strip()` does from their side, and only from it; a
  string of whitespace only becomes ''; NULL stays NULL;
- `to_strip="xy"` removes any of `x` and `y`, a set and not a prefix; of a
  two-byte character it removes that character and no other with its first
  byte; `to_strip=""` removes nothing;
- the same programs as DuckDB `trim(s, chars)`, `ltrim` and `rtrim` give the same
  answers, so the plan's trim is DuckDB's;
- SQL: `trim(s, 'xy')`, `ltrim(s, 'xy')` and `rtrim(s, 'xy')` of a komira
  session equal DuckDB's, and `trim(s)` still removes spaces only, as DuckDB's
  does.

    test_str_strip_duckdb.py --lib-dir <dir> --runtime-dir <dir>
"""

import os
import sys
import tempfile

import komira
from komira import _native

S = [
    "  pad  ",
    "\thi\n",
    "\v\f\rcr\r",
    "\xa0nbsp\xa0",
    "　ideo　",
    "\x1cfs\x1f",
    "​zw​",
    " \t\n\xa0　 ",
    "",
    None,
    "xyxhixy",
    "yx in xy side xy",
    "a b",
    "éhié",
    "èé",
    "é è",
]

# to_strip values, each with the SQL literal of the same set
SETS = [(None, None), ("xy", "xy"), (" ", " "), ("é", "é"), ("", "")]
WHITESPACE = "".join(chr(c) for c in range(sys.maxunicode + 1) if chr(c).isspace())
SIDES = (("strip", "trim"), ("lstrip", "ltrim"), ("rstrip", "rtrim"))


def write_data(path):
    import pyarrow as pa
    import pyarrow.parquet as pq

    pq.write_table(pa.table({"n": pa.array(range(len(S)), pa.int64()), "s": pa.array(S, pa.string())}), path)
    return path


def sql_text(text):
    return "'" + text.replace("'", "''") + "'"


def komira_column(session, path, verb, to_strip):
    frame = komira.read_parquet(path, session=session)
    method = getattr(frame["s"].str, verb)
    frame["r"] = method() if to_strip is None else method(to_strip)
    rows = frame[["n", "r"]].sort_values("n").materialize().to_arrow().to_pylist()
    return [row["r"] for row in rows]


def python_column(verb, to_strip):
    return [None if v is None else getattr(v, verb)(to_strip) for v in S]


def duckdb_column(con, fn, chars):
    rows = con.execute("SELECT {}(s, {}) FROM t ORDER BY n".format(fn, sql_text(chars))).fetchall()
    return [row[0] for row in rows]


def test_the_file_holds_the_strings_the_cases_need():
    assert None in S and "" in S
    assert any(v is not None and v != "" and v.strip() == "" for v in S), "a string of whitespace only"
    for c in ("\t", "\n", "\xa0", "　", "\x1c"):
        assert any(v is not None and v.startswith(c) or v is not None and v.endswith(c) for v in S), repr(c)
    assert not "​".isspace()


def test_strip_lstrip_and_rstrip_equal_python_and_duckdb(path):
    import duckdb

    con = duckdb.connect()
    con.execute("CREATE VIEW t AS SELECT * FROM read_parquet({})".format(sql_text(path)))
    failed = []
    count = 0
    with komira.Session() as session:
        for verb, fn in SIDES:
            for to_strip, chars in SETS:
                count += 1
                got = komira_column(session, path, verb, to_strip)
                python = python_column(verb, to_strip)
                sql = duckdb_column(con, fn, WHITESPACE if chars is None else chars)
                if got != python or python != sql:
                    failed.append("{}({!r}): komira {!r}, Python {!r}, DuckDB {!r}".format(verb, to_strip, got, python, sql))
    assert not failed, "\n".join(failed)
    # the cases the rules name, read from the answers above
    assert python_column("strip", None)[1:4] == ["hi", "cr", "nbsp"]
    assert python_column("lstrip", None)[1] == "hi\n" and python_column("rstrip", None)[1] == "\thi"
    assert python_column("strip", None)[7] == "" and python_column("strip", None)[9] is None
    assert python_column("strip", "xy")[10:12] == ["hi", " in xy side "]
    assert python_column("rstrip", "é")[14] == "è"
    print("str strip duckdb: {} programs equal Python's and DuckDB's answers".format(count))


def test_sql_trim_of_a_set_equals_duckdb_and_trim_of_one_argument_is_spaces_only(path):
    import duckdb

    con = duckdb.connect()
    con.execute("CREATE VIEW t AS SELECT * FROM read_parquet({})".format(sql_text(path)))
    query = (
        "SELECT n, trim(s) AS a, trim(s, 'xy') AS b, ltrim(s, 'xy') AS c, rtrim(s, 'xy') AS d, "
        "trim(s, ' é') AS e, ltrim(s) AS f, rtrim(s) AS g FROM t ORDER BY n"
    )
    want = [tuple(row) for row in con.execute(query).fetchall()]
    with komira.Session() as session:
        session.register_parquet("t", path)
        got = [tuple(row.values()) for row in session.sql(query).to_arrow().to_pylist()]
    assert got == want, (got, want)
    assert want[1][1] == "\thi\n", "trim(s) of one argument removes spaces only"


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    test_the_file_holds_the_strings_the_cases_need()
    # The library is loaded before pyarrow and DuckDB are imported.
    _native.load(os.path.join(lib_dir, "libkomira"))
    with tempfile.TemporaryDirectory() as work:
        path = write_data(os.path.join(work, "strings.parquet"))
        test_strip_lstrip_and_rstrip_equal_python_and_duckdb(path)
        test_sql_trim_of_a_set_equals_duckdb_and_trim_of_one_argument_is_spaces_only(path)


if __name__ == "__main__":
    main(sys.argv[1:])
