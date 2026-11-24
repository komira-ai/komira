"""Session.sql and Result on the stand-in's Arrow C stream (fake_libkomira.c,
ABI 1.3), which counts every stream, schema and batch it makes and releases:

- a result reads once, by to_arrow, to_reader or __arrow_c_stream__, and a
  second read of any kind raises KomiraError;
- sql hands the stream to pyarrow and reads its schema before it returns;
- a stream is released exactly once whoever ends it: pyarrow after reading
  it, or when a result never read is collected, or when a capsule handed out
  and never consumed is collected; every schema and batch pyarrow took is
  released once its table is gone;
- a requested schema raises UnsupportedOperation and leaves the result unread;
- an engine refusal (-3) and a text too long (-5) raise KomiraError with the
  library's message and status, and make no stream;
- a get_schema that fails (EINVAL) raises KomiraError from sql, and a get_next
  that fails (EIO) raises KomiraError from to_arrow and pyarrow's OSError from
  a reader, each with the stream's own error text, and the stream is still
  released once;
- a query that is not a str, holds a NUL or is not UTF-8, and any call on a
  closed session, raise before the library is called;
- importing komira imports no pyarrow; results and a capsule still unread at
  interpreter exit are released there without a crash (this process must exit
  0 after main returns).

    test_sql_fake.py --lib-dir <dir> --runtime-dir <dir>

`<dir>/fake_v1_3/libkomira.so` is the stand-in reporting version 1.3
(`--runtime-dir`, which the rule passes, is not read).
"""

import ctypes
import gc
import os
import sys

import komira
from komira import KomiraError, Result, UnsupportedOperation
from komira import _native

assert "pyarrow" not in sys.modules, "importing komira imported pyarrow"

import pyarrow as pa  # noqa: E402

# Results and a capsule left unread for the interpreter's exit to release.
_LEFT_AT_EXIT = []


def raised(call):
    try:
        call()
    except Exception as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


class Counts:
    """The stand-in's counters, read with komira_fake_stream_counts."""

    def __init__(self, lib):
        self._fn = lib.komira_fake_stream_counts
        self._fn.restype = None
        self._fn.argtypes = [ctypes.POINTER(ctypes.c_int64)]

    def __call__(self):
        out = (ctypes.c_int64 * 6)()
        self._fn(out)
        return dict(zip(("streams", "streams_released", "schemas", "schemas_released", "batches", "batches_released"), out))

    def since(self, before):
        now = self()
        return {k: now[k] - before[k] for k in now}


def zero(**changes):
    out = dict.fromkeys(("streams", "streams_released", "schemas", "schemas_released", "batches", "batches_released"), 0)
    out.update(changes)
    return out


ROWS_READ = zero(streams=1, streams_released=1, schemas=1, schemas_released=1, batches=2, batches_released=2)

# A result just returned: its stream made and its schema read.
OPENED = zero(streams=1, schemas=1, schemas_released=1)


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    directory = os.path.join(lib_dir, "fake_v1_3")
    native = _native.load(directory)
    assert native.abi_version == 1003, native.abi_version
    counts = Counts(ctypes.CDLL(os.path.join(directory, "libkomira.so")))
    schema = pa.schema([pa.field("n", pa.int32())])

    with komira.Session() as s:
        # to_arrow: the whole answer, then every struct released once the
        # table is gone.
        before = counts()
        r = s.sql("rows")
        assert type(r) is Result
        assert counts.since(before) == OPENED, counts.since(before)
        t = r.to_arrow()
        assert t.schema == schema, t.schema
        assert t.to_pylist() == [{"n": 1}, {"n": 2}, {"n": 3}], t.to_pylist()
        assert t.column("n").num_chunks == 2
        del t
        gc.collect()
        assert counts.since(before) == ROWS_READ, counts.since(before)

        # Read once: every terminal refuses a second read, and nothing is
        # called for it.
        before = counts()
        for second in (r.to_arrow, r.to_reader, r.__arrow_c_stream__):
            e = raised(second)
            assert type(e) is KomiraError, repr(e)
            assert str(e) == "the result was already read: run the query again to read it again", str(e)
            assert e.status is None
        assert counts.since(before) == zero()

        # to_reader: the batches as they are asked for.
        before = counts()
        reader = s.sql("rows").to_reader()
        assert isinstance(reader, pa.RecordBatchReader) and reader.schema == schema
        assert counts.since(before) == OPENED
        assert [b.to_pylist() for b in reader] == [[{"n": 1}, {"n": 2}], [{"n": 3}]]
        del reader
        gc.collect()
        assert counts.since(before) == ROWS_READ, counts.since(before)

        # No rows: the schema and an empty table.
        before = counts()
        t = s.sql("no_rows").to_arrow()
        assert t.schema == schema and t.num_rows == 0, t
        del t
        gc.collect()
        assert counts.since(before) == zero(streams=1, streams_released=1, schemas=1, schemas_released=1)

        # A result never read releases its stream when it is collected, and
        # only then.
        before = counts()
        r = s.sql("rows")
        gc.collect()
        assert counts.since(before) == OPENED
        del r
        gc.collect()
        assert counts.since(before) == OPENED | {"streams_released": 1}, counts.since(before)

        # The PyCapsule interface: the capsule is named for a stream, and the
        # result is read once it is handed out.
        before = counts()
        r = s.sql("rows")
        capsule = r.__arrow_c_stream__()
        is_valid = ctypes.pythonapi.PyCapsule_IsValid
        is_valid.restype = ctypes.c_int
        is_valid.argtypes = [ctypes.py_object, ctypes.c_char_p]
        assert type(capsule).__name__ == "PyCapsule" and is_valid(capsule, b"arrow_array_stream") == 1
        assert type(raised(r.to_arrow)) is KomiraError
        # A capsule nobody consumes releases the stream when it is collected.
        del capsule
        gc.collect()
        assert counts.since(before) == OPENED | {"streams_released": 1}, counts.since(before)

        # A consumer of the interface takes the stream, and it is released
        # once.
        before = counts()
        t = pa.RecordBatchReader.from_stream(s.sql("rows")).read_all()
        assert t.to_pylist() == [{"n": 1}, {"n": 2}, {"n": 3}]
        t2 = pa.table(s.sql("rows"))
        assert t2.equals(t)
        del t, t2
        gc.collect()
        twice = {k: 2 * v for k, v in ROWS_READ.items()}
        assert counts.since(before) == twice, counts.since(before)

        # A requested schema is refused, and the result stays unread.
        before = counts()
        r = s.sql("rows")
        e = raised(lambda: r.__arrow_c_stream__(schema.__arrow_c_schema__()))
        assert type(e) is UnsupportedOperation and isinstance(e, KomiraError), repr(e)
        assert str(e) == (
            "komira does not cast a result to a requested schema: read it with requested_schema=None "
            "and cast the Arrow data"
        ), str(e)
        e = raised(lambda: pa.RecordBatchReader.from_stream(r, schema=schema))
        assert type(e) is UnsupportedOperation, repr(e)
        assert r.to_arrow().num_rows == 3
        gc.collect()
        assert counts.since(before) == ROWS_READ, counts.since(before)

        # Refusals: the library's message and status, and no stream.
        before = counts()
        e = raised(lambda: s.sql("SELECT * FROM café"))
        assert type(e) is KomiraError and e.status == -3, repr(e)
        assert str(e) == "bind: the stand-in runs no query SELECT * FROM café", str(e)
        e = raised(lambda: s.sql("too_large"))
        assert type(e) is KomiraError and e.status == -5, repr(e)
        assert str(e) == "komira_sql_stream: the stand-in takes no text this long", str(e)
        assert counts.since(before) == zero()

        # A stream whose schema cannot be read: KomiraError from sql itself,
        # with the stream's own message, and the stream released.
        before = counts()
        e = raised(lambda: s.sql("schema_fails"))
        assert type(e) is KomiraError and e.status is None, repr(e)
        assert "lower: the stand-in has no schema" in str(e), str(e)
        assert isinstance(e.__cause__, pa.ArrowException), repr(e.__cause__)
        del e
        gc.collect()
        assert counts.since(before) == zero(streams=1, streams_released=1), counts.since(before)

        # A stream that fails at its second batch (EIO): KomiraError from
        # to_arrow, and the first batch and the stream released.
        before = counts()
        e = raised(lambda: s.sql("next_fails").to_arrow())
        assert type(e) is KomiraError and e.status is None, repr(e)
        assert "execute: the stand-in fails at batch 2" in str(e), str(e)
        assert isinstance(e.__cause__, OSError), repr(e.__cause__)
        del e
        gc.collect()
        failed = zero(streams=1, streams_released=1, schemas=1, schemas_released=1, batches=1, batches_released=1)
        assert counts.since(before) == failed, counts.since(before)

        # The same through a reader: the first batch, then pyarrow's error.
        before = counts()
        reader = s.sql("next_fails").to_reader()
        assert reader.read_next_batch().to_pylist() == [{"n": 1}, {"n": 2}]
        e = raised(reader.read_next_batch)
        assert isinstance(e, OSError) and "execute: the stand-in fails at batch 2" in str(e), repr(e)
        del reader, e
        gc.collect()
        assert counts.since(before) == failed, counts.since(before)

        # Arguments are checked before the library is called.
        before = counts()
        e = raised(lambda: s.sql(b"rows"))
        assert type(e) is TypeError and str(e) == "query must be a str, not bytes", repr(e)
        e = raised(lambda: s.sql(None))
        assert type(e) is TypeError and str(e) == "query must be a str, not NoneType", repr(e)
        e = raised(lambda: s.sql("ro\0ws"))
        assert type(e) is ValueError and str(e) == "query holds a NUL byte", repr(e)
        e = raised(lambda: s.sql("rows\ud800"))
        assert type(e) is ValueError and str(e) == "query is not valid UTF-8", repr(e)
        assert counts.since(before) == zero()

        # Left unread for the interpreter's exit: a result and a capsule of
        # this session, which is closed below.
        _LEFT_AT_EXIT.append(s.sql("rows"))
        _LEFT_AT_EXIT.append(s.sql("rows").__arrow_c_stream__())
        unread = s.sql("rows")

    # A closed session refuses before the library is called; a result of it
    # still reads.
    before = counts()
    e = raised(lambda: s.sql("rows"))
    assert type(e) is KomiraError and str(e) == "the session is closed" and e.status is None, repr(e)
    e = raised(lambda: s.sql(3))
    assert type(e) is TypeError, repr(e)
    assert counts.since(before) == zero()
    assert unread.to_arrow().to_pylist() == [{"n": 1}, {"n": 2}, {"n": 3}]
    print("sql_fake: libkomira {} streams read once and released once".format(komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
