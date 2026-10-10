"""An oracle: pyarrow writes a timestamp column as ORC.

    orc_timestamps.py <output directory> <data directory>

Writes `ts.orc` under the output directory: one `timestamp[us]` column (whole
seconds, microseconds, a null) in instants of 2027. ORC's writer takes its
zone, `GMT`, from `TZDIR`, so the write needs the zone database the rule
gives every run; the file is read back and must hold the same values. Then
it asserts that setup itself (so a worker that has /usr/share/zoneinfo
cannot hide a missing one): `TZ` is `UTC0`, and `TZDIR` is the `zoneinfo`
directory of the importable tzdata wheel and `zoneinfo`'s only path. The
oracle builds only if its two runs wrote the same bytes.
"""

import datetime
import os
import sys
import zoneinfo

import pyarrow as pa
import pyarrow.orc as orc

out = sys.argv[1]
values = [
    datetime.datetime(2027, 3, 14, 6, 59, 59),
    datetime.datetime(2027, 3, 14, 7, 0, 0, 123456),
    None,
    datetime.datetime(2027, 11, 7, 5, 30, 0, 1),
]
table = pa.table({"ts": pa.array(values, type=pa.timestamp("us"))})
path = os.path.join(out, "ts.orc")
orc.write_table(table, path)
back = orc.read_table(path)
assert back.column("ts").cast(pa.timestamp("us")).to_pylist() == values, "ORC read back {!r}, want {!r}".format(back.column("ts").to_pylist(), values)

import tzdata  # noqa: E402 - located only to name the directory TZDIR must be

want = os.path.join(os.path.dirname(os.path.abspath(tzdata.__file__)), "zoneinfo")
assert os.environ.get("TZ") == "UTC0", "TZ is {!r}, want 'UTC0'".format(os.environ.get("TZ"))
assert os.environ.get("TZDIR") == want, "TZDIR is {!r}, want the tzdata wheel's {!r}".format(os.environ.get("TZDIR"), want)
assert zoneinfo.TZPATH == (want,), "zoneinfo.TZPATH is {!r}, want ({!r},)".format(zoneinfo.TZPATH, want)
