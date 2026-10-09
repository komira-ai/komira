# =============================================================================
# test_sqlite.mojo -- komira_calendar_store over komira_db_sqlite's
#   SqliteDatabase.
# =============================================================================
#
# Each check gets a new database file under the test's temporary directory
# with the migration chain applied; `reopen()` opens another connection to
# the same file, as a restarted server process would.
#
# One more check, SQL only: the tables the migration chain creates are exactly
# CALENDAR_TABLES (a table created and never erased, or listed and never
# created, fails it).
# =============================================================================

from std.os import getenv
from std.testing import assert_equal

from komira_db import DbValue
from komira_db.blocking import db_blocking_query
from komira_db_sqlite import SqliteDatabase

from komira_calendar_store import calendar_tables, migrate
from komira_calendar_store_conformance import CalendarTarget, Rt, new_rt, run_calendar_suite


struct SqliteCalendar(CalendarTarget):
    comptime DB = SqliteDatabase
    var _dir: String
    var _n: Int
    var _path: String

    def __init__(out self) raises:
        var base = getenv("TEST_TMPDIR")
        if base.byte_length() == 0:
            base = getenv("TMPDIR")
        if base.byte_length() == 0:
            raise Error("neither TEST_TMPDIR nor TMPDIR is set")
        self._dir = base
        self._n = 0
        self._path = String()

    def name(self) -> String:
        return String("komira_calendar_store over komira_db_sqlite")

    def fresh(mut self) raises -> SqliteDatabase:
        self._n += 1
        self._path = self._dir + "/calendar_" + String(self._n) + ".db"
        var rt = new_rt()
        ref reactor = rt.reactor()
        return migrate[Rt, SqliteDatabase](SqliteDatabase(self._path), reactor)

    def reopen(mut self) raises -> SqliteDatabase:
        return SqliteDatabase(self._path)


def check_tables_are_declared(mut t: SqliteCalendar) raises:
    var db = t.fresh()
    var rows = db_blocking_query(
        db,
        String(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            " AND name != '_komira_calendar_migrations' ORDER BY name"
        ),
        List[DbValue](),
    )
    var created = String()
    for i in range(rows.__len__()):
        created += rows.row(i).get_text(0) + "\n"
    var declared = calendar_tables()
    var listed = String()
    for i in range(len(declared)):
        listed += declared[i] + "\n"
    assert_equal(created, listed, "the migration chain creates exactly CALENDAR_TABLES")


def main() raises:
    var t = SqliteCalendar()
    var failures = String()
    try:
        check_tables_are_declared(t)
    except e:
        failures += "FAIL tables_are_declared: " + String(e) + "\n"
    try:
        run_calendar_suite(t)
    except e:
        failures += String(e)
    assert_equal(failures, String(), "komira_calendar_store over komira_db_sqlite")
    print("PASS komira_calendar_store_conformance komira_db_sqlite")
