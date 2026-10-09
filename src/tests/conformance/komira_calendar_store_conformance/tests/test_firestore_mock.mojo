# =============================================================================
# test_firestore_mock.mojo -- komira_calendar_store over
#   komira_gcp_firestore_db's FirestoreDatabase and its in-process
#   MockFirestore.
# =============================================================================
#
# Each check gets a new mock. The database declares CALENDAR_DOCUMENT_INDEXES
# and nothing else, so a query shape the store issues without declaring its
# index is refused by the driver's index guard and fails the check.
# `reopen()` is another client over `MockFirestore.share()`, the same
# documents.
#
# One more check, document store only: with the window index line removed
# from the declaration, the window query is refused by the guard (so the line
# is what lets it run, not a shape Firestore serves without one).
#
# FirestoreDatabase is checked against the mock's model of Firestore, not
# Firestore itself.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_calendar_proto.calendar import Calendar
from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore_db import (
    DeclaredIndexSet,
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
    TableKeys,
)
from komira_proto_codec import decode_json

from komira_calendar_store import CALENDAR_DOCUMENT_INDEXES, CalendarStore
from komira_calendar_store_conformance import CalendarTarget, Rt, new_rt, run_calendar_suite, zones

comptime _FsDb = FirestoreDatabase[MockFirestoreConnector]
comptime WINDOW_INDEX = "calendar_events|calendar_id:A|deleted:A|first_start_utc:A|last_end_utc:A"
# The index guard's refusal of the window query when its index is not declared.
comptime WINDOW_REFUSAL = (
    "firestore: UNDECLARED COMPOSITE INDEX for collection 'calendar_events'. The query `FROM calendar_events"
    + " WHERE calendar_id == AND deleted == AND first_start_utc <range> AND last_end_utc <range>` cannot be"
    + " served by Firestore's automatic single-field indexes and no declared composite index covers it — this"
    + " is a 500 FAILED_PRECONDITION at run time. Declare calendar_events (calendar_id ASC, deleted ASC,"
    + " first_start_utc ASC, last_end_utc ASC) in the DeclaredIndexSet passed to FirestoreDatabase and create"
    + " the index in the database, or change the query shape."
)


def _db(transport: MockFirestore, indexes: String) raises -> _FsDb:
    var client = FirestoreClient[MockFirestoreConnector](
        transport.connector(), String("cal-project"), String("(default)"), String("cal-bearer")
    )
    return _FsDb(client^, DeclaredIndexSet.parse_table(indexes), TableKeys())


struct FirestoreMockCalendar(CalendarTarget):
    comptime DB = _FsDb
    var _transport: Optional[MockFirestore]

    def __init__(out self):
        self._transport = Optional[MockFirestore]()

    def name(self) -> String:
        return String("komira_calendar_store over komira_gcp_firestore_db (mock)")

    def fresh(mut self) raises -> _FsDb:
        self._transport = Optional[MockFirestore](MockFirestore())
        return _db(self._transport.value(), String(CALENDAR_DOCUMENT_INDEXES))

    def reopen(mut self) raises -> _FsDb:
        return _db(self._transport.value().share(), String(CALENDAR_DOCUMENT_INDEXES))


def check_window_needs_its_index() raises:
    var declared = String(CALENDAR_DOCUMENT_INDEXES)
    assert_true(WINDOW_INDEX in declared, "the window index is declared")
    var store = CalendarStore[_FsDb](_db(MockFirestore(), declared.replace(String(WINDOW_INDEX), String())))
    var rt = new_rt()
    ref reactor = rt.reactor()
    var c = store.create_calendar[Rt](
        reactor, "alice", decode_json[Calendar]('{"name":"Work","timeZone":"America/New_York"}'), zones(), Int64(0)
    )
    var got = String("ok")
    try:
        _ = store.events_in_window[Rt](reactor, c.id, 0, 86400)
    except e:
        got = String(e)
    assert_equal(got, String(WINDOW_REFUSAL))


def main() raises:
    var t = FirestoreMockCalendar()
    var failures = String()
    try:
        check_window_needs_its_index()
    except e:
        failures += "FAIL window_needs_its_index: " + String(e) + "\n"
    try:
        run_calendar_suite(t)
    except e:
        failures += String(e)
    assert_equal(failures, String(), "komira_calendar_store over komira_gcp_firestore_db (mock)")
    print("PASS komira_calendar_store_conformance komira_gcp_firestore_db")
