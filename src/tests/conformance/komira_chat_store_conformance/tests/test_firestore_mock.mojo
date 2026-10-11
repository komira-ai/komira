# =============================================================================
# test_firestore_mock.mojo -- komira_chat_store over komira_gcp_firestore_db's
#   FirestoreDatabase and its in-process MockFirestore.
# =============================================================================
#
# Each check gets a new mock. The database declares the store's document
# keys and composite indexes from `CHAT_DOCUMENT_KEYS` and
# `CHAT_DOCUMENT_INDEXES`, nothing else, so a query shape the store issues
# without declaring its index is refused by the driver's index guard and
# fails the check. `second()` is another client over `MockFirestore.share()`,
# the same documents.
#
# FirestoreDatabase is checked against the mock's model of Firestore, not
# Firestore itself.
# =============================================================================

from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore_db import (
    DeclaredIndexSet,
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
    TableKeys,
)

from komira_chat_store import CHAT_DOCUMENT_INDEXES, CHAT_DOCUMENT_KEYS
from komira_chat_store_conformance import ChatTarget, run_chat_suite

comptime _FsDb = FirestoreDatabase[MockFirestoreConnector]


def _keys() raises -> TableKeys:
    var keys = TableKeys()
    for line in String(CHAT_DOCUMENT_KEYS).split(String("\n")):
        var row = String(line)
        if row.byte_length() == 0:
            continue
        var parts = row.split(String("|"))
        if len(parts) != 2:
            raise Error(String("malformed CHAT_DOCUMENT_KEYS line: ") + row)
        keys.declare(String(parts[0]), String(parts[1]))
    return keys^


def _db(transport: MockFirestore) raises -> _FsDb:
    var client = FirestoreClient[MockFirestoreConnector](
        transport.connector(),
        String("chat-project"),
        String("(default)"),
        String("chat-bearer"),
    )
    return _FsDb(
        client^,
        DeclaredIndexSet.parse_table(String(CHAT_DOCUMENT_INDEXES)),
        _keys(),
    )


struct FirestoreMockChat(ChatTarget):
    comptime DB = _FsDb
    var _transport: Optional[MockFirestore]

    def __init__(out self):
        self._transport = Optional[MockFirestore]()

    def name(self) -> String:
        return String("komira_chat_store over komira_gcp_firestore_db (mock)")

    def fresh(mut self) raises -> _FsDb:
        self._transport = Optional[MockFirestore](MockFirestore())
        return _db(self._transport.value())

    def second(mut self) raises -> _FsDb:
        return _db(self._transport.value().share())


def main() raises:
    var t = FirestoreMockChat()
    run_chat_suite(t)
    print("PASS komira_chat_store_conformance komira_gcp_firestore_db")
