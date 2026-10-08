# =============================================================================
# test_firestore_mock.mojo -- komira_gcp_firestore_db's FirestoreDatabase,
#   over its in-process MockFirestore, against the neutral `Database` suite.
# =============================================================================
#
# komira has no in-memory `komira_db` fake; MockFirestore is the in-memory
# store a `Database` runs on here (the real generated Firestore client end to
# end, answered at the HTTP boundary, no network). Every check gets a new
# mock. FirestoreDatabase is a `Database` only (no SQL string surface), so
# only the neutral suite runs. The one composite index the suite's queries
# need, (owner, created_at) on conf_items, is declared.
#
# Known gaps (each must still fail exactly so; see report.mojo):
#   query_rows_ne  query_rows refuses a PRED_NE predicate ("unsupported
#                  predicate op 9"); FirestoreDatabase evaluates PRED_NE only
#                  in a conditional_update guard.
# =============================================================================

from komira_gcp_firestore.firestore_client import FirestoreClient
from komira_gcp_firestore_db import (
    DeclaredIndexSet,
    FirestoreDatabase,
    MockFirestore,
    MockFirestoreConnector,
)

from komira_db_conformance import (
    ITEMS,
    KnownGap,
    NeutralTarget,
    run_neutral_suite,
)

comptime _FsDb = FirestoreDatabase[MockFirestoreConnector]


struct FirestoreMockNeutral(NeutralTarget):
    comptime DB = _FsDb

    def __init__(out self):
        pass

    def name(self) -> String:
        return String("komira_gcp_firestore_db over MockFirestore")

    def fresh(mut self) raises -> _FsDb:
        var transport = MockFirestore()
        var client = FirestoreClient[MockFirestoreConnector](
            transport.connector(),
            String("conformance-project"),
            String("(default)"),
            String("conformance-bearer"),
        )
        var indexes = DeclaredIndexSet()
        indexes.declare_asc(String(ITEMS), String("owner"), String("created_at"))
        return _FsDb(client^, indexes^)


def main() raises:
    var gaps = List[KnownGap]()
    gaps.append(
        KnownGap(
            String("query_rows_ne"),
            String("unsupported predicate op 9"),
            String("query_rows cannot evaluate PRED_NE"),
        )
    )
    var target = FirestoreMockNeutral()
    run_neutral_suite(target, gaps)
    print("PASS komira_db_conformance komira_gcp_firestore_db")
