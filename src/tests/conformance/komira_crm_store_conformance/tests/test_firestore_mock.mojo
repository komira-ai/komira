# =============================================================================
# test_firestore_mock.mojo -- komira_crm's store on FirestoreDatabase over
#   MockFirestore.
# =============================================================================
#
# MockFirestore is an in-memory Firestore answered at the HTTP boundary, so the
# store runs the real generated Firestore client with no network. Every check
# gets a new mock. The database is declared NO composite index:
# FirestoreDatabase refuses any query shape that needs one, so a query the
# store adds that needs an index fails here before it fails on Firestore.
# Each operation commits alone there, so the change feed is not checked.
# =============================================================================

from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore_db import DeclaredIndexSet, FirestoreDatabase, MockFirestore, MockFirestoreConnector

from komira_crm_store_conformance import CrmTarget, run_crm_suite

comptime _FsDb = FirestoreDatabase[MockFirestoreConnector]


struct FirestoreMockCrm(CrmTarget):
    comptime DB = _FsDb

    def __init__(out self):
        pass

    def name(self) -> String:
        return String("komira_gcp_firestore_db over MockFirestore")

    def transactional(self) -> Bool:
        return False

    def fresh(mut self) raises -> _FsDb:
        var transport = MockFirestore()
        var client = FirestoreClient[MockFirestoreConnector](
            transport.connector(),
            String("crm-project"),
            String("(default)"),
            String("crm-bearer"),
        )
        return _FsDb(client^, DeclaredIndexSet())


def main() raises:
    var target = FirestoreMockCrm()
    run_crm_suite(target)
    print("PASS komira_crm_store_conformance komira_gcp_firestore_db")
