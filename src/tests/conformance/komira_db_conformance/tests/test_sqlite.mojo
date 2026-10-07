# =============================================================================
# test_sqlite.mojo -- komira_db_sqlite's SqliteDatabase against both suites.
# =============================================================================
#
# Every check gets a new in-memory database (":memory:"), so no check sees
# another's rows and nothing touches the filesystem. The neutral tables are
# created with the SQLite column types protoc-gen-mojo-db emits for their
# logical types. Error texts are libsqlite3's own messages.
#
# Known gaps (each must still fail exactly so; see report.mojo):
#   type_bytes_len16  the driver renders every 16-byte BLOB as a UUID, so a
#                     16-byte BYTES value reads back as its 36-character
#                     hyphenated text. UUID and BYTES are both BLOB columns
#                     in the generated DDL, so the driver cannot tell them
#                     apart on the schema-unknown query path.
# =============================================================================

from komira_db.blocking import db_blocking_execute
from komira_db import DbValue
from komira_db_sqlite import SqliteDatabase

from komira_db_conformance import (
    ERR_NO_TABLE,
    ERR_NOT_NULL,
    ERR_SYNTAX,
    ERR_UNIQUE,
    KnownGap,
    NeutralTarget,
    SqlTarget,
    run_neutral_suite,
    run_sql_suite,
)


def _ddl(mut db: SqliteDatabase, sql: StaticString) raises:
    _ = db_blocking_execute(db, String(sql), List[DbValue]())


struct SqliteNeutral(NeutralTarget):
    comptime DB = SqliteDatabase

    def __init__(out self):
        pass

    def name(self) -> String:
        return String("komira_db_sqlite")

    def fresh(mut self) raises -> SqliteDatabase:
        var db = SqliteDatabase(String(":memory:"))
        _ddl(
            db,
            "CREATE TABLE conf_items (id TEXT PRIMARY KEY, owner TEXT NOT NULL,"
            " phase TEXT NOT NULL, version INTEGER NOT NULL, note TEXT,"
            " created_at INTEGER NOT NULL, updated_at INTEGER)",
        )
        _ddl(
            db,
            "CREATE TABLE conf_types (id TEXT PRIMARY KEY, t_text TEXT,"
            " t_int4 INTEGER, t_int8 INTEGER, t_float8 REAL, t_float4 REAL,"
            " t_bool INTEGER, t_bytes BLOB, t_uuid BLOB, t_ts INTEGER,"
            " t_jsonb TEXT, t_text_array TEXT)",
        )
        _ddl(
            db,
            "CREATE TABLE conf_pairs (a TEXT NOT NULL, b TEXT NOT NULL,"
            " v INTEGER, UNIQUE (a, b))",
        )
        return db^


struct SqliteSql(SqlTarget):
    comptime DB = SqliteDatabase

    def __init__(out self):
        pass

    def name(self) -> String:
        return String("komira_db_sqlite")

    def fresh(mut self) raises -> SqliteDatabase:
        return SqliteDatabase(String(":memory:"))

    def error_text(self, kind: Int) -> String:
        if kind == ERR_SYNTAX:
            return String("syntax error")
        if kind == ERR_UNIQUE:
            return String("UNIQUE constraint failed")
        if kind == ERR_NOT_NULL:
            return String("NOT NULL constraint failed")
        if kind == ERR_NO_TABLE:
            return String("no such table")
        return String("<unknown error kind>")


def main() raises:
    var gaps = List[KnownGap]()
    gaps.append(
        KnownGap(
            String("type_bytes_len16"),
            # The hex of "00010203": the value's hyphenated UUID text.
            String("36:3030303130323033"),
            String("a 16-byte BLOB is read back as a UUID"),
        )
    )
    # Both suites run before either verdict, so one log names every failure.
    var failures = String()
    var neutral = SqliteNeutral()
    try:
        run_neutral_suite(neutral, gaps)
    except e:
        failures += String(e) + String("\n")
    var sql = SqliteSql()
    try:
        run_sql_suite(sql, List[KnownGap]())
    except e:
        failures += String(e)
    if failures.byte_length() > 0:
        raise Error(failures)
    print("PASS komira_db_conformance komira_db_sqlite")
