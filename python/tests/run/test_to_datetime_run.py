"""`komira.to_datetime(series, unit=...)` on the real libkomira: a CSV of Unix
counts is read with `komira.read_csv`, each count column is turned into a
timestamp column, and the rows come back through komira_plan_stream (no SQL
text). Checked against values worked out by hand (pandas'
`to_datetime(..., unit=...)` gives the same instants):

- unit "s", "ms" and "us" answer `timestamp[us]` with the instant of the
  count, before 1970, after 2038 and at the epoch, and a missing count is a
  missing timestamp;
- unit "ns" answers `timestamp[ns]` holding the count unchanged;
- a count of seconds too large for a microsecond timestamp raises the
  engine's overflow error at the terminal instead of wrapping.

The test is of the `run/` family (python/tests/BUCK).

    test_to_datetime_run.py --lib-dir <dir> --runtime-dir <dir>
"""

import datetime
import os
import sys
import tempfile

import pyarrow as pa

import komira
from komira import KomiraError
from komira import _native

# Seconds, milliseconds and microseconds of the same instants; row 3 has no count.
CSV_TEXT = (
    "id,unix_s,unix_ms,unix_us\n"
    "1,1788220800,1788220800123,1788220800123456\n"
    "2,-1,-1,-1\n"
    "3,,,\n"
    "4,4102444800,4102444800000,4102444800000000\n"
    "5,0,0,0\n"
)
D = datetime.datetime
WANT = {
    "s": [D(2026, 9, 1), D(1969, 12, 31, 23, 59, 59), None, D(2100, 1, 1), D(1970, 1, 1)],
    "ms": [D(2026, 9, 1, 0, 0, 0, 123000), D(1969, 12, 31, 23, 59, 59, 999000), None, D(2100, 1, 1), D(1970, 1, 1)],
    "us": [D(2026, 9, 1, 0, 0, 0, 123456), D(1969, 12, 31, 23, 59, 59, 999999), None, D(2100, 1, 1), D(1970, 1, 1)],
}


def write_csv(work, text):
    path = os.path.join(work, "events.csv")
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    return path


def sorted_table(df):
    t = df.materialize().to_arrow()
    return t.sort_by("id")


def test_seconds_milliseconds_and_microseconds():
    with tempfile.TemporaryDirectory() as work, komira.Session() as s:
        df = komira.read_csv(write_csv(work, CSV_TEXT), session=s)
        df["ts_s"] = komira.to_datetime(df["unix_s"], unit="s")
        df["ts_ms"] = komira.to_datetime(df["unix_ms"], unit="ms")
        df["ts_us"] = komira.to_datetime(df["unix_us"], unit="us")
        assert [df.dtypes[c] for c in ("ts_s", "ts_ms", "ts_us")] == ["timestamp_us"] * 3, df.dtypes
        t = sorted_table(df)
        for unit in ("s", "ms", "us"):
            column = t.column("ts_" + unit)
            assert column.type == pa.timestamp("us"), (unit, column.type)
            assert column.to_pylist() == WANT[unit], (unit, column.to_pylist())


def test_nanoseconds_keep_the_count():
    with tempfile.TemporaryDirectory() as work, komira.Session() as s:
        df = komira.read_csv(write_csv(work, CSV_TEXT), session=s)
        df["ts"] = komira.to_datetime(df["unix_us"] * 1000, unit="ns")
        t = sorted_table(df)
        column = t.column("ts")
        assert column.type == pa.timestamp("ns"), column.type
        want = [1788220800123456000, -1000, None, 4102444800000000000, 0]
        assert column.cast(pa.int64()).to_pylist() == want, column.cast(pa.int64()).to_pylist()


def test_a_second_count_too_large_raises_at_the_terminal():
    with tempfile.TemporaryDirectory() as work, komira.Session() as s:
        df = komira.read_csv(write_csv(work, "id,unix_s\n1,9223372036855\n"), session=s)
        df["ts"] = komira.to_datetime(df["unix_s"], unit="s")
        try:
            df.materialize().to_arrow()
        except KomiraError as e:
            assert "Overflow in multiplication of INT64" in str(e), str(e)
        else:
            raise AssertionError("an out-of-range count did not raise")


TESTS = [
    test_seconds_milliseconds_and_microseconds,
    test_nanoseconds_keep_the_count,
    test_a_second_count_too_large_raises_at_the_terminal,
]


def main(args):
    lib_dir = os.path.abspath(args[args.index("--lib-dir") + 1])
    _native.load(os.path.join(lib_dir, "libkomira"))
    for test in TESTS:
        test()
        print("ok", test.__name__)
    print("to_datetime: {} cases over libkomira {}".format(len(TESTS), komira.abi_version()))


if __name__ == "__main__":
    main(sys.argv[1:])
