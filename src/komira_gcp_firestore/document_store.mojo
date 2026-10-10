# =============================================================================
# komira_gcp_firestore/document_store.mojo — the minimal document/KV seam +
#   the Firestore-backed conformer.
# =============================================================================
#
# WHAT THIS IS + WHY A NEW SEAM. A NoSQL document store does NOT fit the SQL
# `komira_db.Database` trait — that trait's surface is `execute/query(sql: String, params: List[DbValue])` +
# `placeholder(i)` + `now_expr()`, i.e. it is fundamentally a SQL-string executor
# with per-dialect placeholder rendering. Firestore has no SQL, no placeholders,
# no rows-and-columns — it is a collection/document/field key-value store. Forcing
# a Firestore driver onto `Database` would mean either (a) inventing a fake SQL
# dialect over documents, or (b) leaving 8 of the trait's 11 methods unimplemented
# (a lie about conformance). Both are worse than a right-sized seam.
#
# `komira_db` has no KV / document store trait to conform to, so this defines the
# MINIMAL document/KV seam a caller needs to use Firestore (or any document
# store) as its storage, matching HOW pgstore/sqlite conform to the SQL path (a
# narrow trait + a concrete conformer), but shaped for documents, not rows.
#
# SCOPE OF THE SEAM (deliberately minimal — grow it when a 2nd backend appears).
#   * get(collection, key)      -> Optional[document fields]  (None iff absent)
#   * put(collection, key, doc) -> upsert the whole document  (create-or-replace)
#   * delete(collection, key)   -> remove (idempotent — deleting an absent key is
#                                  a no-op, NOT an error, the KV contract)
#   * query(collection, structured_query_json) -> List[(key, fields)]
# The value type is `FsValue` (an FS_T_MAP of typed fields) — the SAME type the
# document client + the CDC value model use, so a stored document is byte-identically
# the thing the CDC listener later captures (ZERO conversion at any layer).
#
# WHERE THE SEAM LIVES. In the Firestore package (beside its only conformer today),
# NOT in `komira_db` — a caller uses Firestore-as-storage directly, and a
# shared cross-package seam is a larger decision to make once a SECOND document
# backend (e.g. Cosmos) needs it. Lifting the trait to `komira_db` when that
# happens is a mechanical move (the trait names no Firestore type — only FsValue,
# which is already the shared CDC value type).
#
# ENCAPSULATION. ZERO UnsafePointer in any signature; ZERO wildcard
# origins; ZERO unsafe_from_address. `def`-based, Mojo 1.0.0b2.
# =============================================================================

from .firestore_value import FsValue
from komira_http_core.transport.io_stream import Connector
from komira_gcp_core import GcpTokenSource

from .firestore_client import FirestoreClient, FixedBearer, is_not_found_error


# =============================================================================
# §0 — DocumentEntry — one (key, fields) pair a query returns.
# =============================================================================


struct DocumentEntry(Copyable, Movable, Deinitable):
    """One document a query yields: its key (the last path segment, the document
    id) and its typed `fields` (an FS_T_MAP FsValue).

    Layout: a plain owned-field struct (String + the plain-List-backed FsValue), no
    pointer field, no wildcard origin."""

    var key: String
    var fields: FsValue

    def __init__(out self, var key: String, var fields: FsValue):
        self.key = key^
        self.fields = fields^

    def copy(self) -> Self:
        return Self(String(self.key), self.fields.copy())


# =============================================================================
# §1 — DocumentStore — the minimal document/KV seam.
# =============================================================================


trait DocumentStore(Movable, Deinitable):
    """The document/KV store seam a caller uses for document storage. A
    narrow get/put/delete/query surface over collections of documents whose values
    are typed `FsValue` field-maps. Conformed by `FirestoreDocumentStore` today; a
    second backend (Cosmos, etc.) conforms the SAME seam later.

    No UnsafePointer crosses any boundary — String keys + FsValue field-maps in,
    Optional[FsValue] / List[DocumentEntry] out."""

    def get(mut self, collection: String, key: String) raises -> Optional[FsValue]:
        """Read one document's `fields` by key. Returns `None` iff the document
        does not exist (a not-found is NOT an error at the KV seam — it is the
        absent case). RAISES on a real failure (transport / permission)."""
        ...

    def put(
        mut self, collection: String, key: String, fields: FsValue
    ) raises:
        """Upsert (create-or-replace) the whole document at `key` with `fields`."""
        ...

    def delete(mut self, collection: String, key: String) raises:
        """Remove the document at `key`. IDEMPOTENT — deleting an absent key is a
        no-op (NOT an error), the KV-delete contract. RAISES on a real failure."""
        ...

    def query(
        mut self, collection: String, structured_query_json: String
    ) raises -> List[DocumentEntry]:
        """Run a structured query over `collection`; return the matching
        (key, fields) entries."""
        ...


# =============================================================================
# §2 — FirestoreDocumentStore[T] — the Firestore-backed conformer.
# =============================================================================


struct FirestoreDocumentStore[
    C: Connector, S: GcpTokenSource = FixedBearer
](
    DocumentStore, Movable, Deinitable
):
    """A `DocumentStore` backed by Firestore. Wraps a `FirestoreClient[C, S]` and
    maps the KV verbs onto its document ops:
      get    -> FirestoreClient.get_document (a typed not-found -> None)
      put    -> FirestoreClient.patch_document (a whole-document create-or-replace)
      delete -> FirestoreClient.delete_document (a typed not-found swallowed -> the
                idempotent KV-delete contract)
      query  -> FirestoreClient.run_query (the returned docs' last path segment is
                the key).

    Best-effort conditional writes: `put` is a full-document upsert; this seam
    does NOT expose Firestore preconditions (currentDocument.exists) — the
    atomic conditional surface is `FirestoreClient`'s precondition commit
    (and `FirestoreConditionalStore` over it).

    Layout: wraps a `FirestoreClient[C, S]` value (the generated client, its
    connector and String config). No wildcard-origin field, no UnsafePointer
    field."""

    var _client: FirestoreClient[Self.C, Self.S]

    def __init__(
        out self,
        var connector: Self.C,
        var project: String,
        var database: String,
        var tokens: Self.S,
    ):
        self._client = FirestoreClient[Self.C, Self.S](
            connector^, project^, database^, tokens^
        )

    @staticmethod
    def wrap(
        var client: FirestoreClient[Self.C, Self.S],
    ) -> FirestoreDocumentStore[Self.C, Self.S]:
        """Wrap an already-built FirestoreClient as a DocumentStore."""
        var s = FirestoreDocumentStore[Self.C, Self.S]._uninit(client^)
        return s^

    @staticmethod
    def _uninit(
        var client: FirestoreClient[Self.C, Self.S],
    ) -> FirestoreDocumentStore[Self.C, Self.S]:
        return FirestoreDocumentStore[Self.C, Self.S](_client=client^)

    def __init__(out self, var _client: FirestoreClient[Self.C, Self.S]):
        self._client = _client^

    # ----- client inspection (test seam) ------------------------------------
    def client_ref(ref self) -> ref [self._client] FirestoreClient[Self.C, Self.S]:
        """Borrow the wrapped client (a test reads its token source through it
        AFTER a flow). A reference rooted at `self._client`, never a raw
        pointer."""
        return self._client

    # ----- DocumentStore trait ----------------------------------------------
    def get(mut self, collection: String, key: String) raises -> Optional[FsValue]:
        """Read one document's `fields`. A typed not-found (404) -> None (the
        absent case); any OTHER error propagates."""
        try:
            var doc = self._client.get_document(collection, key)
            return Optional[FsValue](doc.fields.copy())
        except e:
            if is_not_found_error(String(e)):
                return None
            raise e^

    def put(mut self, collection: String, key: String, fields: FsValue) raises:
        """Upsert the whole document (a commit with no precondition: create-or-replace)."""
        var _doc = self._client.patch_document(collection, key, fields)

    def delete(mut self, collection: String, key: String) raises:
        """Remove the document. A typed not-found (404) is SWALLOWED (idempotent
        KV-delete); any OTHER error propagates."""
        try:
            self._client.delete_document(collection, key)
        except e:
            if is_not_found_error(String(e)):
                return  # deleting an absent key is a no-op (KV contract)
            raise e^

    def query(
        mut self, collection: String, structured_query_json: String
    ) raises -> List[DocumentEntry]:
        """Run a structured query; return (key, fields) entries. The key is the
        last `/`-segment of each returned document's resource name."""
        var docs = self._client.run_query(structured_query_json)
        var out = List[DocumentEntry]()
        for i in range(len(docs)):
            var key = _last_path_segment(docs[i].name)
            out.append(DocumentEntry(key^, docs[i].fields.copy()))
        return out^


# =============================================================================
# §3 — helpers.
# =============================================================================


def _last_path_segment(resource_name: String) -> String:
    """The last `/`-separated segment of a resource name
    `projects/p/databases/db/documents/collection/{id}` -> `{id}` (the document
    key). An empty name -> empty key."""
    var sb = resource_name.as_bytes()
    var last_slash = -1
    for i in range(len(sb)):
        if sb[i] == UInt8(ord("/")):
            last_slash = i
    if last_slash < 0:
        return String(resource_name)
    # `/` is ASCII, so the cut is a char boundary: the id's UTF-8 bytes as they are.
    return String(resource_name[byte=last_slash + 1 : len(sb)])
