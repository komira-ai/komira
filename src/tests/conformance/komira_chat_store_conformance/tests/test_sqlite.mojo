# =============================================================================
# test_sqlite.mojo -- komira_chat_store over komira_db_sqlite's SqliteDatabase.
# =============================================================================
#
# Each check gets a new database file under the test's temporary directory,
# opened in WAL mode with a busy timeout (`arm_for_concurrent_use`), set up by
# `prepare_sql_connection`, with the chat schema from `chat_migrations()`.
# `second()` opens another connection to the same file, so a write through
# one is a commit the other reads, as between two server processes.
#
# It also checks that the migration chain re-runs as a no-op and that every
# connection has secure_delete on.
# =============================================================================

from std.os import getenv
from std.testing import assert_equal

from komira_db import DbValue, MigrationRunner
from komira_db.blocking import db_blocking_query
from komira_db_sqlite import SqliteDatabase

from komira_chat_store import (
    CHAT_MIGRATION_LEDGER,
    chat_migrations,
    prepare_sql_connection,
)
from komira_chat_store_conformance import ChatTarget, Rt, new_rt, run_chat_suite


def _open(path: String) raises -> SqliteDatabase:
    var db = SqliteDatabase(path)
    var rt = new_rt()
    ref reactor = rt.reactor()
    db.arm_for_concurrent_use[Rt](reactor, 5000)
    prepare_sql_connection[Rt, SqliteDatabase](db, reactor)
    return db^


struct SqliteChat(ChatTarget):
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
        return String("komira_chat_store over komira_db_sqlite")

    def fresh(mut self) raises -> SqliteDatabase:
        self._n += 1
        self._path = self._dir + String("/chat_") + String(self._n) + String(".db")
        var db = _open(self._path)
        var rt = new_rt()
        ref reactor = rt.reactor()
        var runner = MigrationRunner[SqliteDatabase](
            db^, String(CHAT_MIGRATION_LEDGER)
        )
        var steps = chat_migrations()
        assert_equal(runner.run[Rt](reactor, steps), len(steps))
        assert_equal(runner.run[Rt](reactor, steps), 0, "a re-run applies nothing")
        return runner^.into_db()

    def second(mut self) raises -> SqliteDatabase:
        var db = _open(self._path)
        var rows = db_blocking_query(
            db, String("PRAGMA secure_delete"), List[DbValue]()
        )
        assert_equal(rows.row(0).get_int8(0), Int64(1), "secure_delete is on")
        return db^


def main() raises:
    var t = SqliteChat()
    run_chat_suite(t)
    print("PASS komira_chat_store_conformance komira_db_sqlite")
