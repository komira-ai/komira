"""The oracle's DuckDB connection pins its calendar and zone, loads no extension and reads nothing but its tables.

    test_connect.py

On the connection gen_expected.connect() returns (the one :expected runs
every case on), in a process of its own:

0. The process runs under a locale whose calendar is not Gregorian and a
   time zone that is not UTC: `LC_ALL=th_TH.UTF-8` and `TZ=Asia/Kathmandu`
   are set in the environment before duckdb is imported, so ICU reads
   them when the first database loads it (ICU computes its default locale
   and zone once, from LC_ALL and TZ; no glibc locale need be installed).
   On the oracle's connection `date_part('year', ...)` and
   `date_part('hour', ...)` of the TIMESTAMPTZ `2026-10-01 00:00:00+00`
   are 2026 and 0, through run_query() as a case runs. A connection of the
   test's own that pins neither must answer 2569 (the Buddhist year) and 5
   (+05:45), or the environment did not reach ICU and the probe proves
   nothing: that is a failure too. Catches `Calendar` dropped from CONFIG
   and `SET TimeZone` dropped from connect(): the oracle's answers would
   then follow the worker's locale and zone.
1. The settings are what CONFIG and connect() say: autoload_known_extensions,
   autoinstall_known_extensions and enable_external_access are all false,
   Calendar is `gregorian` and TimeZone `UTC`. Catches any one of them
   dropped from CONFIG or left at DuckDB's default (autoinstall alone has
   no other witness here: with autoload off, no query reaches the install;
   under 0's environment the Calendar and TimeZone defaults are `buddhist`
   and `Asia/Kathmandu`, so a dropped pin is seen here as well).
2. A case that calls a function of an extension DuckDB 1.5.6 would
   autoload but the wheel does not hold (inet's `html_escape`), through
   run_query() as gen_expected.py runs a case, fails as a catalog error
   ("is not in the catalog"), not as a failed attempt to load the extension; the
   connection's functions and types afterwards are the ones before (no
   extension loaded; duckdb_extensions() lists the extension directory,
   which this connection may not read), and so are the extensions a
   connection of the test's own lists as installed (none downloaded).
   Catches autoload turned back on: DuckDB then tries to load inet and
   the error is an autoload failure (or, with the download allowed and
   reachable, inet loads and the loaded list changes). `st_area`
   (spatial) is held to the same: spatial is not on DuckDB's autoload
   list, so it is a catalog error whatever the settings, and only pins
   that a function DuckDB names but cannot autoload stays one.
3. Reading a file fails with a permission error (`read_text` on this
   test's own source, run directly: sql_discipline.py would refuse it
   first). Catches enable_external_access left on.
4. `SET enable_external_access = true` is refused while the database runs,
   so no later statement can undo it.
5. The registered tables are readable through run_query(): external
   access off does not stop the oracle reading what it registered.
"""

import os

# Before duckdb is imported: ICU reads these once, when it first loads.
os.environ["LC_ALL"] = "th_TH.UTF-8"
os.environ["TZ"] = "Asia/Kathmandu"

import duckdb  # noqa: E402

import gen_expected  # noqa: E402

FAILURES = []


def fail(msg):
    FAILURES.append(msg)


def catalog(con):
    """Every function and type name the connection's catalog holds.

    duckdb_extensions() lists the extension directory, which this
    connection may not read; an extension loading adds its functions and
    types here, so an unchanged catalog is an unchanged set of loaded
    extensions."""
    funcs = con.execute("SELECT DISTINCT function_name FROM duckdb_functions()").fetchall()
    types = con.execute("SELECT DISTINCT type_name FROM duckdb_types()").fetchall()
    return sorted(r[0] for r in funcs), sorted(r[0] for r in types)


def installed():
    """The extensions installed on this worker, read by a connection of its
    own that may read the extension directory (and autoloads nothing)."""
    side = duckdb.connect(config={"autoload_known_extensions": False, "autoinstall_known_extensions": False})
    rows = side.execute("SELECT extension_name FROM duckdb_extensions() WHERE installed").fetchall()
    side.close()
    return sorted(r[0] for r in rows)


def check_settings(con):
    for name, want in [
        ("autoload_known_extensions", False),
        ("autoinstall_known_extensions", False),
        ("enable_external_access", False),
        ("threads", 1),
        ("Calendar", "gregorian"),
        ("TimeZone", "UTC"),
    ]:
        got = con.execute("SELECT current_setting(CAST(? AS VARCHAR))", [name]).fetchone()[0]
        if got != want:
            fail("setting %s is %r, want %r" % (name, got, want))


# ICU's date_part of one instant: its year in the session's Calendar, its
# hour in the session's TimeZone.
_YEAR_HOUR = (
    "SELECT date_part(CAST('year' AS VARCHAR), CAST('2026-10-01 00:00:00+00' AS TIMESTAMPTZ)) AS y, "
    "date_part(CAST('hour' AS VARCHAR), CAST('2026-10-01 00:00:00+00' AS TIMESTAMPTZ)) AS h"
)


def check_calendar_zone(con):
    """The oracle's connection answers in the Gregorian calendar and UTC
    under a Thai locale and a +05:45 zone; a connection pinning neither
    must not, or the environment did not reach ICU."""
    got = gen_expected.run_query(con, _YEAR_HOUR).to_pylist()
    if got != [{"y": 2026, "h": 0}]:
        fail("date_part on the oracle's connection is %s, want year 2026 and hour 0 (Gregorian, UTC)" % got)
    side = duckdb.connect(config={"autoload_known_extensions": False, "autoinstall_known_extensions": False})
    raw = side.execute(_YEAR_HOUR).fetchall()
    settings = side.execute("SELECT current_setting(CAST('Calendar' AS VARCHAR)), "
                            "current_setting(CAST('TimeZone' AS VARCHAR))").fetchall()
    side.close()
    if raw != [(2569, 5)]:
        fail("date_part on an unpinned connection under LC_ALL=th_TH.UTF-8, TZ=Asia/Kathmandu is %s "
             "(Calendar, TimeZone %s), want (2569, 5): the environment did not reach ICU, so the probe "
             "proves nothing" % (raw, settings))


def check_no_autoload(con):
    before = catalog(con)
    installed_before = installed()
    if "html_escape" in before[0]:
        fail("html_escape is in the catalog before any query; the probe proves nothing")
    for fn, sql in [
        ("html_escape", "SELECT html_escape(CAST('a' AS VARCHAR)) AS v"),
        ("st_area", "SELECT st_area(CAST('a' AS VARCHAR)) AS v"),
    ]:
        try:
            gen_expected.run_query(con, sql)
        except duckdb.CatalogException as e:
            if "is not in the catalog" not in str(e):
                fail("%s: a catalog error, but not a missing function: %s" % (fn, e))
        except Exception as e:
            fail("%s: want a catalog error (function not in the catalog), got %s: %s" % (fn, type(e).__name__, e))
        else:
            fail("%s: ran; want a catalog error, the extension unloaded" % fn)
    after = catalog(con)
    for i, kind in enumerate(["functions", "types"]):
        added = sorted(set(after[i]) - set(before[i]))
        if added:
            fail("the probes added %s %s to the catalog: an extension loaded" % (kind, added[:10]))
    if installed() != installed_before:
        fail("installed extensions %s, before the probes %s" % (installed(), installed_before))


def check_no_file_read(con):
    try:
        con.execute("SELECT content FROM read_text(CAST(? AS VARCHAR))", [os.path.abspath(__file__)]).fetchall()
    except duckdb.PermissionException:
        pass
    except Exception as e:
        fail("read_text: want a permission error, got %s: %s" % (type(e).__name__, e))
    else:
        fail("read_text read this test's source; want a permission error")
    try:
        con.execute("SET enable_external_access = true")
    except duckdb.Error:
        pass
    else:
        fail("SET enable_external_access = true was accepted on the running database")


def check_tables(con):
    for name in gen_expected.TABLES:
        got = gen_expected.run_query(con, "SELECT count(*) AS n FROM %s" % name)
        if got.num_rows != 1 or got.column(0)[0].as_py() < 1:
            fail("table %s: count %s, want one row of at least 1" % (name, got.to_pydict()))


con = gen_expected.connect()
check_settings(con)
check_calendar_zone(con)
check_no_autoload(con)
check_no_file_read(con)
check_tables(con)
if FAILURES:
    for f in FAILURES:
        print("FAIL", f)
    raise SystemExit("test_connect: %d failures" % len(FAILURES))
print("test_connect: all passed")
