# =============================================================================
# test_firestore_mock.mojo -- komira_contacts' store on FirestoreDatabase over
#   MockFirestore.
# =============================================================================
#
# MockFirestore is an in-memory Firestore answered at the HTTP boundary, so the
# store runs the real generated Firestore client with no network. Every check
# gets a new mock. The database is told exactly the composite indexes
# komira_contacts.composite_indexes() lists: FirestoreDatabase refuses any
# query shape that needs an index nobody declared, so a query the store adds
# without listing its index fails here before it fails on Firestore.
# =============================================================================

from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore_db import (
    DeclaredIndex,
    DeclaredIndexField,
    DeclaredIndexSet,
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
)

from komira_contacts import composite_indexes

from komira_contacts_store_conformance import ContactsTarget, run_contacts_suite

comptime _FsDb = FirestoreDatabase[MockFirestoreConnector]


def _declared() -> DeclaredIndexSet:
    var out = DeclaredIndexSet()
    var wanted = composite_indexes()
    for i in range(len(wanted)):
        var fields = List[DeclaredIndexField]()
        for j in range(len(wanted[i].cols)):
            fields.append(DeclaredIndexField(String(wanted[i].cols[j]), False, False))
        out.declare(DeclaredIndex(String(wanted[i].table), fields^))
    return out^


struct FirestoreMockContacts(ContactsTarget):
    comptime DB = _FsDb

    def __init__(out self):
        pass

    def name(self) -> String:
        return String("komira_gcp_firestore_db over MockFirestore")

    def fresh(mut self) raises -> _FsDb:
        var transport = MockFirestore()
        var client = FirestoreClient[MockFirestoreConnector](
            transport.connector(),
            String("contacts-project"),
            String("(default)"),
            String("contacts-bearer"),
        )
        return _FsDb(client^, _declared())


def main() raises:
    var target = FirestoreMockContacts()
    run_contacts_suite(target)
    print("PASS komira_contacts_store_conformance komira_gcp_firestore_db")
