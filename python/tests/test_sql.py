"""Session.sql on the real libkomira, read as pyarrow:

- `SELECT 1 AS n` is one row, `n` INT32 holding 1;
- a GROUP BY over a checked-in Parquet file (labels.parquet: 3000 rows in six
  row groups, `id` INT64 0 to 2999 and `label` cycling alpha, bravo,
  charlie, delta, echo) is five groups of 600 with their lowest and highest
  id; an aggregate over readings.parquet (`id` 1 to 5, `value` 10.5 to 50.5)
  is its one row; a filter that keeps nothing is no rows with the column's
  type;
- each terminal reads it: to_arrow, to_reader and the PyCapsule interface;
- an unknown table raises BindError, a syntax error ParseError and a construct
  refused by name (the bitwise OR operator, an unknown function)
  UnsupportedOperation, each with the engine's message, its last error, status
  -3, and its code and step ("bind"/SQL_BIND_ERROR, "parse"/SQL_SYNTAX_ERROR,
  SQL_NOT_SUPPORTED at "parse" and at "bind"), and the session answers the
  next query after each;
- a result reads after its session was closed, after its session was
  collected without a close, and half read before the close; results never
  read are dropped after their session was freed, and one is left for the
  interpreter's exit, all without a crash.

    test_sql.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/libkomira/` is `//src/so:libkomira[runnable]`, `<dir>/labels.parquet`
and `<dir>/readings.parquet` the two Parquet files.
"""

import gc
import os
import sys

import pyarrow as pa

import komira
from komira import _native

# A result left unread for the interpreter's exit to release.
_LEFT_AT_EXIT = []

ONE = [{"n": 1}]

LABELS = "SELECT label, count(*) AS n, min(id) AS lo, max(id) AS hi FROM labels GROUP BY label ORDER BY label"

LABEL_ROWS = [
    {"label": name, "n": 600, "lo": i, "hi": 2995 + i}
    for i, name in enumerate(["alpha", "bravo", "charlie", "delta", "echo"])
]

READINGS = "SELECT count(*) AS n, sum(value) AS total, min(id) AS lo, max(id) AS hi FROM readings"

READING_ROWS = [{"n": 5, "total": 152.5, "lo": 1, "hi": 5}]


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    assert komira.abi_version() >= 1007, komira.abi_version()
    labels = os.path.join(lib_dir, "labels.parquet")
    readings = os.path.join(lib_dir, "readings.parquet")

    def session():
        s = komira.Session()
        s.register_parquet("labels", labels)
        s.register_parquet("readings", readings)
        return s

    with session() as s:
        # SELECT with no FROM.
        t = s.sql("SELECT 1 AS n").to_arrow()
        assert isinstance(t, pa.Table)
        assert t.schema.names == ["n"] and t.schema.field("n").type == pa.int32(), t.schema
        assert t.to_pylist() == ONE, t.to_pylist()

        # GROUP BY over the checked-in file.
        t = s.sql(LABELS).to_arrow()
        assert t.schema.names == ["label", "n", "lo", "hi"], t.schema
        label = t.schema.field("label").type
        assert pa.types.is_string(label) or pa.types.is_large_string(label) or pa.types.is_string_view(label), label
        assert [t.schema.field(c).type for c in ("n", "lo", "hi")] == [pa.int64()] * 3, t.schema
        assert t.to_pylist() == LABEL_ROWS, t.to_pylist()

        # An aggregate, and a filter that keeps no row.
        t = s.sql(READINGS).to_arrow()
        assert t.schema.field("total").type == pa.float64(), t.schema
        assert t.to_pylist() == READING_ROWS, t.to_pylist()
        t = s.sql("SELECT id FROM readings WHERE id > 5").to_arrow()
        assert t.num_rows == 0 and t.schema.names == ["id"] and t.schema.field("id").type == pa.int64(), t

        # The other terminals.
        reader = s.sql(LABELS).to_reader()
        assert isinstance(reader, pa.RecordBatchReader) and reader.schema.names == ["label", "n", "lo", "hi"]
        assert pa.Table.from_batches(list(reader), reader.schema).to_pylist() == LABEL_ROWS
        assert pa.RecordBatchReader.from_stream(s.sql(READINGS)).read_all().to_pylist() == READING_ROWS
        assert pa.table(s.sql("SELECT 1 AS n")).to_pylist() == ONE

        # Refusals: the engine's message, which is its last error, with its
        # code and step, as the class the table gives; the session answers
        # the next query after each.
        e = raised(lambda: s.sql("SELECT * FROM nosuch"))
        assert type(e) is komira.BindError, repr(e)
        assert (e.status, e.step, e.code) == (-3, "bind", "SQL_BIND_ERROR"), (e.status, e.step, e.code)
        assert str(e) == "bind: SQL bind error: unknown table 'nosuch'", str(e)
        assert str(e) == _native.load().last_error(s._ctx), str(e)
        assert s.sql("SELECT 1 AS n").to_arrow().to_pylist() == ONE

        e = raised(lambda: s.sql("SELEC 1"))
        assert type(e) is komira.ParseError, repr(e)
        assert (e.status, e.step, e.code) == (-3, "parse", "SQL_SYNTAX_ERROR"), (e.status, e.step, e.code)
        assert str(e).startswith("parse: SQL syntax error: "), str(e)
        assert str(e) == _native.load().last_error(s._ctx), str(e)
        assert s.sql("SELECT 1 AS n").to_arrow().to_pylist() == ONE

        # A construct refused by name is an UnsupportedOperation, whichever
        # step refuses it: the bitwise OR operator at the parse step, an
        # unknown scalar function at the bind step.
        e = raised(lambda: s.sql("SELECT 5 | 3 AS k"))
        assert type(e) is komira.UnsupportedOperation, repr(e)
        assert (e.status, e.step, e.code) == (-3, "parse", "SQL_NOT_SUPPORTED"), (e.status, e.step, e.code)
        assert str(e).startswith("parse: SQL not supported: the bitwise OR operator `|`"), str(e)
        assert s.sql("SELECT 1 AS n").to_arrow().to_pylist() == ONE
        e = raised(lambda: s.sql("SELECT nosuchfn(1) AS k"))
        assert type(e) is komira.UnsupportedOperation, repr(e)
        assert (e.status, e.step, e.code) == (-3, "bind", "SQL_NOT_SUPPORTED"), (e.status, e.step, e.code)
        assert str(e).startswith("bind: SQL not supported: scalar function 'nosuchfn'."), str(e)
        assert s.sql("SELECT 1 AS n").to_arrow().to_pylist() == ONE

    # A result read after its session was closed: the stream needs neither the
    # session nor its context.
    s = session()
    after_close = s.sql(LABELS)
    half = s.sql(LABELS).to_reader()
    first = half.read_next_batch()
    never_read = s.sql(READINGS)
    s.close()
    assert after_close.to_arrow().to_pylist() == LABEL_ROWS
    rest = [first] + list(half)
    assert pa.Table.from_batches(rest, half.schema).to_pylist() == LABEL_ROWS
    del half, rest, first, never_read
    gc.collect()

    # A result read after its session was collected without a close.
    s = session()
    free = s._free
    collected = s.sql(READINGS)
    unread = s.sql(LABELS)
    del s
    gc.collect()
    assert not free.alive
    assert collected.to_arrow().to_pylist() == READING_ROWS
    del unread
    gc.collect()

    # A new session after all that runs, and one result stays unread for the
    # interpreter's exit, its session closed.
    with session() as s:
        assert s.sql(LABELS).to_arrow().to_pylist() == LABEL_ROWS
        _LEFT_AT_EXIT.append(s.sql(LABELS))
    print("sql: libkomira {} runs SQL and its results outlive the session".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
