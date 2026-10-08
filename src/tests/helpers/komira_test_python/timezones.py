"""Time zones come from the pinned tzdata wheel, never from the worker.

Fails unless:

- `TZDIR` is the `tzdata/zoneinfo` directory of the pinned tzdata wheel
  (under the action), `zoneinfo.TZPATH` is that directory alone, and `TZ` is
  `UTC0` (a POSIX rule, so the C library reads no zone file for local time);
- every file Python opens while it resolves a zone (an audit hook records
  each `open`) is under the action, and `America/New_York` is read from
  `TZDIR`;
- pyarrow's ORC writer and reader round-trip a timestamp column exactly
  (ORC reads its writer's zone, `GMT`, from `TZDIR`), and with `TZDIR` naming
  an empty directory the writer raises `pyarrow.lib.ArrowException` whose
  whole message is `Unknown error: Time zone file <dir>/GMT does not exist.
  Please install IANA time zone database and set TZDIR env.`, so ORC takes the zone from
  `TZDIR` and from no fixed path;
- a zoned pyarrow array's `to_pylist()` gives the exact local times, offsets
  and folds of `America/New_York` around the spring-forward gap and the
  fall-back fold of 2027.
"""

import datetime
import importlib.util
import os
import sys
import tempfile
import time
import zoneinfo

ROOT = os.getcwd() + os.sep
OPENED = []


def _audit(event, args):
    if event == "open" and args and isinstance(args[0], (str, bytes)):
        OPENED.append(os.fsdecode(args[0]))


sys.addaudithook(_audit)

import pyarrow as pa  # noqa: E402
import pyarrow.orc as orc  # noqa: E402


def wheel_tzdir():
    spec = importlib.util.find_spec("tzdata")
    assert spec is not None and spec.submodule_search_locations, "the tzdata wheel is not importable"
    return os.path.join(list(spec.submodule_search_locations)[0], "zoneinfo")


def environment():
    want = wheel_tzdir()
    got = os.environ.get("TZDIR")
    assert got == want, "TZDIR is {!r}, want the tzdata wheel's {!r}".format(got, want)
    assert want.startswith(ROOT), "the tzdata wheel {} is outside the action".format(want)
    assert zoneinfo.TZPATH == (want,), "zoneinfo.TZPATH is {!r}, want ({!r},)".format(zoneinfo.TZPATH, want)
    assert os.environ.get("TZ") == "UTC0", "TZ is {!r}, want 'UTC0'".format(os.environ.get("TZ"))
    assert time.timezone == 0 and time.tzname[0] == "UTC", "local time is {!r} {}".format(time.tzname, time.timezone)
    print("TZDIR:", os.path.relpath(want, ROOT))


def orc_round_trip():
    ts = [
        datetime.datetime(1969, 12, 31, 23, 59, 59, 999999),
        datetime.datetime(1970, 1, 1),
        datetime.datetime(2027, 3, 14, 2, 30, 0, 123456),
        datetime.datetime(2262, 4, 11, 23, 47, 16),
        None,
    ]
    table = pa.table({"t": pa.array(ts, type=pa.timestamp("us")).cast(pa.timestamp("ns"))})
    path = os.path.join(tempfile.gettempdir(), "t.orc")
    orc.write_table(table, path)
    back = orc.read_table(path)
    assert back.schema == table.schema, "ORC read schema {} != {}".format(back.schema, table.schema)
    assert back.equals(table), "ORC round trip {} != {}".format(back.column("t").to_pylist(), ts)
    assert back.column("t").to_pylist() == ts, back.column("t").to_pylist()
    print("ORC timestamp round trip:", len(ts), "rows")

    empty = tempfile.mkdtemp()
    os.environ["TZDIR"] = empty
    try:
        orc.write_table(table, os.path.join(empty, "x.orc"))
    except Exception as e:  # noqa: BLE001 - the type and message are what is checked
        got = (type(e).__module__ + "." + type(e).__qualname__, str(e))
    else:
        got = None
    finally:
        os.environ["TZDIR"] = wheel_tzdir()
    want = (
        "pyarrow.lib.ArrowException",
        "Unknown error: Time zone file {}/GMT does not exist. "
        "Please install IANA time zone database and set TZDIR env.".format(empty),
    )
    assert got == want, "ORC with an empty TZDIR: got {!r}, want {!r}".format(got, want)
    print("ORC follows TZDIR:", want[1].replace(empty, "<empty>"))


def zoned_to_pylist():
    tz = "America/New_York"
    utc = [
        "2027-03-14T06:59:59",  # the last second of EST
        "2027-03-14T07:00:00",  # 02:00 local is skipped: 03:00 EDT
        "2027-11-07T05:30:00",  # 01:30 EDT, the first of the two
        "2027-11-07T06:30:00",  # 01:30 EST, the repeated one (fold 1)
        "2027-07-01T12:00:00",
    ]
    want = [
        ("2027-03-14T01:59:59-05:00", 0),
        ("2027-03-14T03:00:00-04:00", 0),
        ("2027-11-07T01:30:00-04:00", 0),
        ("2027-11-07T01:30:00-05:00", 1),
        ("2027-07-01T08:00:00-04:00", 0),
    ]
    seconds = [int(datetime.datetime.fromisoformat(u + "+00:00").timestamp()) for u in utc]
    del OPENED[:]
    got = pa.array(seconds, type=pa.timestamp("s", tz=tz)).to_pylist()
    pairs = [(d.isoformat(), d.fold) for d in got]
    assert pairs == want, "to_pylist in {}: {!r}, want {!r}".format(tz, pairs, want)
    assert all(isinstance(d.tzinfo, zoneinfo.ZoneInfo) and d.tzinfo.key == tz for d in got), [d.tzinfo for d in got]
    outside = [p for p in OPENED if not os.path.abspath(p).startswith(ROOT)]
    assert not outside, "files opened outside the action: {}".format(outside)
    zone = os.path.join(os.environ["TZDIR"], tz)
    assert any(os.path.abspath(p) == zone for p in OPENED), "{} was not read from TZDIR ({})".format(tz, OPENED)
    print("to_pylist in", tz + ":", [p[0] for p in pairs])


environment()
orc_round_trip()
zoned_to_pylist()
