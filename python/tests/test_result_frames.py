"""Result.to_pandas and Result.to_polars, on the real libkomira and on the
stand-in's counted Arrow stream (fake_libkomira.c):

- values and dtypes: a Parquet file pyarrow writes here, with every integer
  width at its lowest and highest value, nullable integers, a float, strings
  (empty, non-ASCII, null), a bool, two decimals, timestamps in ms, us and ns
  and one in UTC, and a date, each column with nulls but the non-null
  integers, is answered by `SELECT *` with the file's own Arrow types, and
  to_pandas and to_polars equal pyarrow's `Table.to_pandas()` and polars'
  `from_arrow` of that table, values and dtypes, with the dtypes also named
  one by one;
- a large answer: two million rows over sixteen row groups read by
  to_pandas and to_polars equal the file's table;
- an answer of no rows is an empty frame with the same dtypes;
- each frame terminal reads once: after it every terminal raises
  KomiraError, and after any other terminal it raises; a result read after
  its session was closed;
- the load-order case: a new interpreter that imports komira and loads the
  library before pyarrow, pandas or polars is imported, then converts an
  engine string column with to_pandas (and to_polars), exits 0 with the
  values; so does a pure pyarrow string conversion after the library is
  loaded. A crash is reported with its signal;
- on the stand-in, in a new interpreter: a frame terminal reads the two
  batches and every stream, schema and batch is released once; a batch that
  fails raises KomiraError from to_pandas and to_polars with the stream's
  error and releases all; pandas or polars that cannot be imported raises
  ImportError with its full message, before the stream is taken, so the
  result then still reads with to_arrow.

    test_result_frames.py --lib-dir <dir> --runtime-dir <dir> [--polars]

`<dir>/libkomira/` is `//src/so:libkomira[runnable]` and
`<dir>/fake_v1_3/libkomira.so` the stand-in reporting ABI 1.3 (`--runtime-dir`,
which the rule passes, is not read). `--polars` says
polars is installed for this interpreter; without it, to_polars must raise the
ImportError that names it, and the polars cases are that check. The target
runs on CPython 3.13 and 3.14, the minors with a pinned pandas, and passes
`--polars` on 3.13 alone, the one minor with a pinned polars; 3.11 and 3.12,
which pin neither, are held by test_sql.py's `to_arrow`.
"""

import ctypes
import datetime
import decimal
import gc
import json
import os
import subprocess
import sys
import tempfile

import komira
from komira import KomiraError, Result
from komira import _native

assert "pyarrow" not in sys.modules, "importing komira imported pyarrow"

# Starts this file again in a new interpreter with the test's `sys.path` and
# temporary directory (`-I -S`, as the test itself runs, sees no other site).
_BOOT = (
    "import json, runpy, sys, tempfile\n"
    "sys.path[:] = json.loads(sys.argv[1])\n"
    "tempfile.tempdir = sys.argv[2]\n"
    "sys.argv = sys.argv[3:]\n"
    "runpy.run_path(sys.argv[0], run_name='__main__')\n"
)

PANDAS_MISSING = "Result.to_pandas() needs pandas, which could not be imported: install it with `pip install pandas`"
POLARS_MISSING = "Result.to_polars() needs polars, which could not be imported: install it with `pip install polars`"
ALREADY_READ = "the result was already read: run the query again to read it again"

STRINGS = ["alpha", "", "été 日本", None, "echo"]

BIG_ROWS = 2_000_000


def raised(call):
    try:
        call()
    except BaseException as e:  # each caller checks the exact type
        return e
    raise AssertionError("the call raised nothing")


# ---- the files ---------------------------------------------------------------


def typed_table():
    """Five rows: `id` 0 to 4, then one column per type. The non-null
    integer columns hold their type's lowest and highest value."""
    import pyarrow as pa

    def ints(t, lo, hi):
        return pa.array([lo, hi, 0, 1, lo + 1], t)

    us = datetime.datetime
    return pa.table(
        {
            "id": pa.array(range(5), pa.int64()),
            "i8": ints(pa.int8(), -(2**7), 2**7 - 1),
            "i16": ints(pa.int16(), -(2**15), 2**15 - 1),
            "i32": ints(pa.int32(), -(2**31), 2**31 - 1),
            "i64": ints(pa.int64(), -(2**63), 2**63 - 1),
            "u8": ints(pa.uint8(), 0, 2**8 - 1),
            "u16": ints(pa.uint16(), 0, 2**16 - 1),
            "u32": ints(pa.uint32(), 0, 2**32 - 1),
            "u64": ints(pa.uint64(), 0, 2**64 - 1),
            "n32": pa.array([7, None, -7, None, 0], pa.int32()),
            "n64": pa.array([None, 2**53, None, -1, 3], pa.int64()),
            "f64": pa.array([1.5, None, -0.0, 1e300, -2.25], pa.float64()),
            "s": pa.array(STRINGS, pa.string()),
            "b": pa.array([True, False, None, True, False], pa.bool_()),
            "d12": pa.array(
                [decimal.Decimal("1234567890.12"), decimal.Decimal("-0.01"), None, decimal.Decimal("0.00"),
                 decimal.Decimal("-9999999999.99")],
                pa.decimal128(12, 2),
            ),
            "d38": pa.array(
                [decimal.Decimal("1234567890123456789012345678.0123456789"), None,
                 decimal.Decimal("-0.0000000001"), decimal.Decimal("0E-10"), decimal.Decimal("42.5000000000")],
                pa.decimal128(38, 10),
            ),
            "ts_ms": pa.array(
                [us(1970, 1, 1), us(1969, 12, 31, 23, 59, 59, 999000), None, us(2262, 4, 11), us(2026, 11, 24, 8, 30, 1, 5000)],
                pa.timestamp("ms"),
            ),
            "ts_us": pa.array(
                [us(2026, 11, 24, 8, 30, 1, 123456), None, us(1900, 1, 1), us(1970, 1, 1, 0, 0, 0, 1), us(9999, 12, 31, 23, 59, 59, 999999)],
                pa.timestamp("us"),
            ),
            "ts_ns": pa.array([0, -1, None, 1_700_000_000_123_456_789, 2**63 - 1], pa.timestamp("ns")),
            "ts_utc": pa.array(
                [us(2026, 11, 24, 8, 30, 1, 123456, tzinfo=datetime.timezone.utc), None,
                 us(1970, 1, 1, tzinfo=datetime.timezone.utc), us(1999, 12, 31, 23, 59, 59, tzinfo=datetime.timezone.utc),
                 us(2000, 2, 29, 12, tzinfo=datetime.timezone.utc)],
                pa.timestamp("us", tz="UTC"),
            ),
            "day": pa.array(
                [datetime.date(2026, 11, 24), None, datetime.date(1970, 1, 1), datetime.date(1, 1, 1), datetime.date(9999, 12, 31)],
                pa.date32(),
            ),
        }
    )


def big_table():
    """`BIG_ROWS` rows: `id` in order, `v` id / 4, `label` one of 1000
    strings, and `n` null on every seventh row."""
    import pyarrow as pa

    return pa.table(
        {
            "id": pa.array(range(BIG_ROWS), pa.int64()),
            "v": pa.array([i / 4 for i in range(BIG_ROWS)], pa.float64()),
            "label": pa.array(["label-{:03d}".format(i % 1000) for i in range(BIG_ROWS)], pa.string()),
            "n": pa.array([None if i % 7 == 0 else i * 3 for i in range(BIG_ROWS)], pa.int64()),
        }
    )


def write(table, path, row_group_size):
    import pyarrow.parquet as pq

    pq.write_table(table, path, row_group_size=row_group_size)
    return path


# ---- the children ----------------------------------------------------------


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


def cold_frames(args):
    """Nothing of Arrow imported before the library is loaded; then an
    engine string column through to_pandas, and through to_polars."""
    lib_dir, path, with_polars = args[0], args[1], args[2] == "polars"
    for name in ("pyarrow", "pandas", "polars", "numpy"):
        assert name not in sys.modules, name
    _native.load(os.path.join(lib_dir, "libkomira"))
    with komira.Session() as s:
        s.register_parquet("t", path)
        query = "SELECT s FROM t ORDER BY id"
        out = {"pandas": strings(s.sql(query).to_pandas()["s"])}
        if with_polars:
            frame = s.sql(query).to_polars()
            out["polars"] = frame["s"].to_list()
            out["polars_to_pandas"] = strings(frame.to_pandas()["s"])
    print(json.dumps(out, sort_keys=True))


def strings(column):
    """A pandas string column's values, a missing one as None."""
    return [None if column.isna()[i] else column[i] for i in range(len(column))]


def cold_pyarrow(args):
    """The library loaded first, then pyarrow imported and a pure pyarrow
    string array converted to pandas."""
    lib_dir = args[0]
    for name in ("pyarrow", "pandas", "numpy"):
        assert name not in sys.modules, name
    _native.load(os.path.join(lib_dir, "libkomira"))
    komira.Session().close()
    import pyarrow as pa

    print(json.dumps(pa.array(["A", "N", "R"], pa.string()).to_pandas().tolist()))


class Counts:
    """The stand-in's counters, read with komira_fake_stream_counts."""

    NAMES = ("streams", "streams_released", "schemas", "schemas_released", "batches", "batches_released")

    def __init__(self, lib):
        self._fn = lib.komira_fake_stream_counts
        self._fn.restype = None
        self._fn.argtypes = [ctypes.POINTER(ctypes.c_int64)]

    def __call__(self):
        out = (ctypes.c_int64 * 6)()
        self._fn(out)
        return dict(zip(self.NAMES, out))

    def since(self, before):
        now = self()
        return {k: now[k] - before[k] for k in now}


def zero(**changes):
    out = dict.fromkeys(Counts.NAMES, 0)
    out.update(changes)
    return out


def fake(args):
    """The frame terminals on the stand-in's stream: `rows` is int32 `n`
    [1, 2] then [3], and `next_fails` [1, 2] then EIO."""
    lib_dir, with_polars = args[0], args[1] == "polars"
    directory = os.path.join(lib_dir, "fake_v1_3")
    assert _native.load(directory).abi_version == 1003
    counts = Counts(ctypes.CDLL(os.path.join(directory, "libkomira.so")))
    read = zero(streams=1, streams_released=1, schemas=1, schemas_released=1, batches=2, batches_released=2)
    failed = zero(streams=1, streams_released=1, schemas=1, schemas_released=1, batches=1, batches_released=1)
    opened = zero(streams=1, schemas=1, schemas_released=1)

    def frames():
        out = [("to_pandas", lambda f: f["n"].tolist(), lambda f: str(f["n"].dtype) == "int32")]
        if with_polars:
            import polars as pl

            out.append(("to_polars", lambda f: f["n"].to_list(), lambda f: f.schema["n"] == pl.Int32))
        return out

    with komira.Session() as s:
        for terminal, values, dtype in frames():
            # The whole answer, then everything released once the frame is gone.
            before = counts()
            frame = getattr(s.sql("rows"), terminal)()
            assert values(frame) == [1, 2, 3] and dtype(frame), (terminal, frame)
            del frame
            gc.collect()
            assert counts.since(before) == read, (terminal, counts.since(before))

            # A batch that fails: KomiraError with the stream's error, and
            # the stream and the batch it made released.
            before = counts()
            r = s.sql("next_fails")
            e = raised(getattr(r, terminal))
            assert type(e) is KomiraError and e.status is None, (terminal, repr(e))
            assert "execute: the stand-in fails at batch 2" in str(e), (terminal, str(e))
            assert isinstance(e.__cause__, OSError), (terminal, repr(e.__cause__))
            e2 = raised(getattr(r, terminal))
            assert type(e2) is KomiraError and str(e2) == ALREADY_READ, (terminal, repr(e2))
            del r, e, e2
            gc.collect()
            assert counts.since(before) == failed, (terminal, counts.since(before))

        # pandas, and polars, that cannot be imported: the ImportError with
        # its full message, raised before the stream is taken, so the result
        # still reads.
        missing = [("pandas", "to_pandas", PANDAS_MISSING), ("polars", "to_polars", POLARS_MISSING)]
        for module, terminal, message in missing:
            saved = sys.modules.get(module, False)
            sys.modules[module] = None  # makes `import <module>` raise ImportError
            try:
                before = counts()
                r = s.sql("rows")
                e = raised(getattr(r, terminal))
                assert type(e) is ImportError and str(e) == message and e.name == module, (terminal, repr(e))
                assert isinstance(e.__cause__, ImportError), (terminal, repr(e.__cause__))
                assert counts.since(before) == opened, (terminal, counts.since(before))
                assert r.to_arrow().column("n").to_pylist() == [1, 2, 3]
                del r, e
                gc.collect()
                assert counts.since(before) == read, (terminal, counts.since(before))
            finally:
                if saved is False:
                    del sys.modules[module]
                else:
                    sys.modules[module] = saved
    print("fake: done")


CHILDREN = {"cold_frames": cold_frames, "cold_pyarrow": cold_pyarrow, "fake": fake}


# ---- the test ----------------------------------------------------------------


def check_typed(s, source, with_polars):
    import pandas as pd
    import pandas.testing as pdt

    query = "SELECT * FROM typed ORDER BY id"

    # The Arrow answer has the file's own types and values.
    t = s.sql(query).to_arrow()
    assert t.schema.names == source.schema.names, t.schema
    assert [f.type for f in t.schema] == [f.type for f in source.schema], (t.schema, source.schema)
    assert t.to_pylist() == source.to_pylist(), t.to_pylist()

    # pandas: equal to pyarrow's own conversion of the same table, values and
    # dtypes, and the dtypes named.
    df = s.sql(query).to_pandas()
    assert type(df) is pd.DataFrame
    pdt.assert_frame_equal(df, source.to_pandas(), check_dtype=True, check_exact=True)
    dtypes = {c: str(df[c].dtype) for c in df.columns}
    want = {
        "id": "int64", "i8": "int8", "i16": "int16", "i32": "int32", "i64": "int64",
        "u8": "uint8", "u16": "uint16", "u32": "uint32", "u64": "uint64",
        # An integer column with nulls is float64 with NaN, pyarrow's default.
        "n32": "float64", "n64": "float64", "f64": "float64",
        "b": "object", "d12": "object", "d38": "object",
        "ts_ms": "datetime64[ms]", "ts_us": "datetime64[us]", "ts_ns": "datetime64[ns]",
        "day": "object",
    }
    for c, d in want.items():
        assert dtypes[c] == d, (c, dtypes[c], d)
    assert df["ts_utc"].dtype == pd.DatetimeTZDtype("us", "UTC"), dtypes["ts_utc"]
    assert pd.api.types.is_string_dtype(df["s"]), dtypes["s"]
    assert df["i64"].tolist() == [-(2**63), 2**63 - 1, 0, 1, -(2**63) + 1]
    assert df["u64"].tolist() == [0, 2**64 - 1, 0, 1, 1]
    assert df["n64"].isna().tolist() == [True, False, True, False, False]
    assert strings(df["s"]) == STRINGS
    assert df["d12"].tolist()[:2] == [decimal.Decimal("1234567890.12"), decimal.Decimal("-0.01")]
    assert df["d38"][0] == decimal.Decimal("1234567890123456789012345678.0123456789")
    assert df["ts_ns"][3] == pd.Timestamp(1_700_000_000_123_456_789, unit="ns")
    assert df["ts_utc"][0] == pd.Timestamp("2026-11-24 08:30:01.123456", tz="UTC")
    assert df["day"][3] == datetime.date(1, 1, 1)

    # No rows: an empty frame with the same dtypes.
    empty = s.sql("SELECT * FROM typed WHERE id < 0").to_pandas()
    assert len(empty) == 0
    pdt.assert_frame_equal(empty, source.slice(0, 0).to_pandas(), check_dtype=True)

    if not with_polars:
        return
    import polars as pl
    import polars.testing as plt

    frame = s.sql(query).to_polars()
    assert type(frame) is pl.DataFrame
    plt.assert_frame_equal(frame, pl.from_arrow(source), check_dtypes=True, check_exact=True)
    assert dict(frame.schema) == {
        "id": pl.Int64, "i8": pl.Int8, "i16": pl.Int16, "i32": pl.Int32, "i64": pl.Int64,
        "u8": pl.UInt8, "u16": pl.UInt16, "u32": pl.UInt32, "u64": pl.UInt64,
        "n32": pl.Int32, "n64": pl.Int64, "f64": pl.Float64, "s": pl.String, "b": pl.Boolean,
        "d12": pl.Decimal(12, 2), "d38": pl.Decimal(38, 10),
        "ts_ms": pl.Datetime("ms"), "ts_us": pl.Datetime("us"), "ts_ns": pl.Datetime("ns"),
        "ts_utc": pl.Datetime("us", "UTC"), "day": pl.Date,
    }, frame.schema
    # polars keeps an integer column with nulls as integers.
    assert frame["n64"].to_list() == [None, 2**53, None, -1, 3]
    assert frame["s"].to_list() == STRINGS
    assert frame["u64"].to_list() == [0, 2**64 - 1, 0, 1, 1]
    assert frame.null_count().row(0, named=True) == {c: source.column(c).null_count for c in source.schema.names}

    empty = s.sql("SELECT * FROM typed WHERE id < 0").to_polars()
    assert empty.height == 0 and empty.schema == frame.schema, empty.schema


def check_big(s, big, with_polars):
    import pandas.testing as pdt

    # No ORDER BY: the frame is put in id order here, so the engine's row
    # order is not what is checked.
    df = s.sql("SELECT * FROM big").to_pandas()
    assert len(df) == BIG_ROWS, len(df)
    df = df.sort_values("id", ignore_index=True)
    pdt.assert_frame_equal(df, big.to_pandas(), check_dtype=True, check_exact=True)
    del df
    if with_polars:
        import polars as pl
        import polars.testing as plt

        frame = s.sql("SELECT * FROM big").to_polars().sort("id")
        assert frame.height == BIG_ROWS
        plt.assert_frame_equal(frame, pl.from_arrow(big), check_dtypes=True, check_exact=True)


def check_read_once(s, with_polars):
    terminals = ["to_arrow", "to_reader", "to_pandas", "__arrow_c_stream__"] + (["to_polars"] if with_polars else [])
    frames = ["to_pandas"] + (["to_polars"] if with_polars else [])
    for first in terminals:
        for second in terminals:
            if first not in frames and second not in frames:
                continue  # test_sql_fake.py holds those pairs
            r = s.sql("SELECT s FROM typed")
            getattr(r, first)()
            e = raised(getattr(r, second))
            assert type(e) is KomiraError and str(e) == ALREADY_READ, (first, second, repr(e))


def main(args):
    if "--child" in args:
        scenario = args[args.index("--child") + 1]
        CHILDREN[scenario](args[args.index("--child") + 2:])
        return
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    with_polars = "--polars" in args
    with tempfile.TemporaryDirectory() as work:
        run(lib_dir, with_polars, work)


def run(lib_dir, with_polars, work):
    polars_arg = "polars" if with_polars else "no-polars"
    # The children first, before this process loads anything: the files they
    # read are written by pyarrow here, in this process only.
    source = typed_table()
    typed = write(source, os.path.join(work, "typed.parquet"), row_group_size=2)
    out = json.loads(child("cold_frames", lib_dir, typed, polars_arg))
    want = {"pandas": STRINGS}
    if with_polars:
        want["polars"] = STRINGS
        want["polars_to_pandas"] = STRINGS
    assert out == want, out
    assert json.loads(child("cold_pyarrow", lib_dir)) == ["A", "N", "R"]
    assert child("fake", lib_dir, polars_arg) == "fake: done\n"

    big = big_table()
    big_path = write(big, os.path.join(work, "big.parquet"), row_group_size=BIG_ROWS // 16)

    _native.load(os.path.join(lib_dir, "libkomira"))
    with komira.Session() as s:
        s.register_parquet("typed", typed)
        s.register_parquet("big", big_path)
        check_typed(s, source, with_polars)
        check_big(s, big, with_polars)
        check_read_once(s, with_polars)
        if not with_polars:
            # polars is not installed for this interpreter: to_polars says so.
            r = s.sql("SELECT 1 AS n")
            e = raised(r.to_polars)
            assert type(e) is ImportError and str(e) == POLARS_MISSING, repr(e)
            assert r.to_arrow().to_pylist() == [{"n": 1}]

        # A result read after its session was closed.
        late = s.sql("SELECT s FROM typed ORDER BY id")
    assert type(late) is Result
    assert strings(late.to_pandas()["s"]) == STRINGS
    print("result frames: to_pandas{} over libkomira {}".format(
        " and to_polars" if with_polars else "", komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
