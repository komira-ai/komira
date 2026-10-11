# =============================================================================
# test_sqlite.mojo -- komira_contacts' store on komira_db_sqlite.
# =============================================================================
#
# Every check gets a new in-memory database (":memory:") with the store's
# tables created by komira_contacts.sqlite_schema(), so no check sees
# another's rows and nothing touches the filesystem. Each write runs in a
# real SQLite transaction (BEGIN IMMEDIATE), so a refused write is rolled
# back.
# =============================================================================

from komira_db import DbValue
from komira_db.blocking import db_blocking_execute
from komira_db_sqlite import SqliteDatabase

from komira_contacts import sqlite_schema

from komira_contacts_store_conformance import ContactsTarget, run_contacts_suite


struct SqliteContacts(ContactsTarget):
    comptime DB = SqliteDatabase

    def __init__(out self):
        pass

    def name(self) -> String:
        return String("komira_db_sqlite")

    def fresh(mut self) raises -> SqliteDatabase:
        var db = SqliteDatabase(String(":memory:"))
        var ddl = sqlite_schema()
        for i in range(len(ddl)):
            _ = db_blocking_execute(db, ddl[i], List[DbValue]())
        return db^


def main() raises:
    var target = SqliteContacts()
    run_contacts_suite(target)
    print("PASS komira_contacts_store_conformance komira_db_sqlite")
