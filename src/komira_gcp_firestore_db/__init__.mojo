# =============================================================================
# komira_gcp_firestore_db — the `komira_db.Database` conformer over Google Cloud
#   Firestore, and the in-process Firestore double that falsifies it.
# =============================================================================
#
#   * `FirestoreDatabase[C: Connector, S: GcpTokenSource]` — a
#     conformer of the backend-NEUTRAL `komira_db.Database` trait (the tx verbs
#     + the STRUCTURED ops) realized on Firestore DOCUMENT primitives, NOT SQL.
#     Because every `[DB: Database]`-generic store touches ONLY those ops,
#     `Store[FirestoreDatabase[C]]` runs the same store source as
#     `Store[SqliteDatabase]` / `Store[PgDatabase]`.
#
#   * `MockFirestore` — the ATOMIC in-process Firestore double (create-if-absent,
#     updateTime-CAS, a structuredQuery WHERE evaluator) at the HTTP boundary,
#     behind a `MockFirestoreConnector`; ZERO network, ZERO GCP. It is the
#     substrate every Firestore-backed store test drives, so it ships IN the
#     package rather than in one test file.
#
#   * The composite-index guard (`firestore_index_guard`): a driver refuses a
#     query shape Firestore cannot serve without an index nobody declared.
#
# CONSUME:
#     from komira_gcp_firestore_db import FirestoreDatabase
#     from komira_gcp_firestore_db import MockFirestore, MockFirestoreConnector
# =============================================================================

# The neutral `Database` conformer + the Firestore BatchWrite server cap the
# multi-doc ops chunk against.
from komira_gcp_firestore_db.firestore_database import (
    FirestoreDatabase,
    FS_DB_BATCH_MAX,
    TableKeys,
)

# THE UNDECLARED-COMPOSITE-INDEX GUARD. A `FirestoreDatabase` carries the set of
# composite indexes it has been TOLD exist, and refuses to build a structuredQuery
# whose shape Firestore will not serve off automatic single-field indexes unless
# that set covers it. Constructing a driver WITHOUT one gives it an EMPTY set,
# which refuses every such shape — the default is "prove it", not "assume it".
from komira_gcp_firestore_db.firestore_index_guard import (
    DeclaredIndexSet,
    DeclaredIndex,
    DeclaredIndexField,
    QueryIndexShape,
    query_index_shape,
    needs_composite_index,
    declared_set_serves,
    require_declared_index,
)

# The ATOMIC in-process Firestore DOUBLE, and the connector a client over it
# takes.
from komira_gcp_firestore_db.mock_firestore import (
    MockFirestore,
    MockFirestoreConnector,
)
