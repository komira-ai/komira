# =============================================================================
# komira_broker/cluster_assignment_store.mojo
#   The object-store CAS, BINARY assignment store — the DB-free
#   partition-assignment persistence over a CloneableConditionalWriteStore.
# =============================================================================
#
# The broker COORDINATOR persists the partition assignment on the object
# store, so a broker deployment needs NO database: compute and storage stay
# fully decoupled.
#
# WHY OBJECT-STORE CAS: the broker already runs on the object store (segments +
# manifests + the consumer-group state.json all live on the SAME
# CloneableConditionalWriteStore), so the assignment uses the same store and
# the same CAS pattern as the consumer-group coordinator: head+get to read,
# If-None-Match create, If-Match (compare_and_swap) update,
# loser-re-reads-on-412.
#
# KEY (PER-TOPIC): `<cluster>/_meta/cluster/<topic>/assignment.bin`. The
#   assignment is CAS'd as a WHOLE blob (a partial assignment is never valid —
#   one body + one etag is the unit of atomicity).
#
# VERSION = ETAG: the store's opaque ETag is the CAS token. `read_assignment`
# returns the etag; `store_assignment` takes it (empty etag => If-None-Match
# create, else If-Match update). A lost CAS surfaces as a 412 the caller
# re-reads + retries.
#
# NO DDL / NO BOOTSTRAP: an absent assignment is a 404 on the first read (->
# None -> the initial pass). There is nothing to create up front — the first
# write creates the object (If-None-Match).
#
# SYNC VERBS (no [RT] / Reactor): the store's conditional_put / compare_and_swap
# / head / get are SYNC (komira_objectstore ConditionalWriteStore). With the
# coordinator's coalesce cache above, only a membership change touches the
# store, so a single sync write per rebalance is absorbed. The parkable async
# reassign op (`clone_store` / `key_for` below) is the non-blocking path.
#
# ENCAPSULATION: String / List[UInt8] / StoredAssignment value in +
# out — ZERO UnsafePointer crosses any boundary. The binary FORMAT lives on the
# Assignment type (encode_binary / decode_binary in partition_assignment.mojo);
# this layer only moves bytes + an etag. StoredAssignment is a plain
# owned value (String topic + List[UInt8] body + String etag), never a byte-slab
# element accessed through a wildcard cast. The `[Storage]` generic is
# comptime-monomorphized.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.types import WritePrecondition

from .partition_assignment import AssignmentView


# =============================================================================
# StoredAssignment — one persisted assignment object (the binary body + etag).
# =============================================================================


@fieldwise_init
struct StoredAssignment(Movable, Copyable, Deinitable):
    """A persisted partition-assignment object: the serialized BINARY body + its
    CAS etag. The body is opaque to this layer (the broker's
    `Assignment.encode_binary()`); the coordinator decodes it via
    `Assignment.decode_binary`.

    Field layout:
      var topic: String       — the topic name (the per-topic key component).
      var body: List[UInt8]   — the serialized assignment (binary).
      var etag: String        — the store's opaque CAS token (the If-Match
                                value a subsequent `store_assignment` carries).
    """

    var topic: String
    var body: List[UInt8]
    var etag: String

    # -------------------------------------------------------------------------
    # view — the ZERO-COPY read over the stored body. The body
    # bytes were already brought over the wire (they must be owned SOMEWHERE — the
    # store returns the owned StoredAssignment); the zero-copy win is that the
    # transient hot read views these bytes IN PLACE — `AssignmentView` reads P /
    # reason / owners / node strings DIRECTLY from `self.body` with NO List
    # allocation and NO re-parse (the owned `Assignment.decode_binary`, by
    # contrast, materializes a P-deep List[String] of node-id copies). The view
    # BORROWS `self.body` (origin-tied via `origin_of`); it must not outlive this
    # StoredAssignment — the compiler enforces that via the origin.
    # -------------------------------------------------------------------------
    def view(ref self) raises -> AssignmentView[origin_of(self.body)]:
        """A zero-copy `AssignmentView` over the stored binary body (the hot read
        path). Validates the header; raises on a malformed body. No allocation."""
        return AssignmentView[origin_of(self.body)](Span[UInt8](self.body))


# =============================================================================
# ClusterAssignmentStore[Storage] — the typed persistence over the object store.
# =============================================================================


struct ClusterAssignmentStore[
    Storage: CloneableConditionalWriteStore = SharedInMemoryConditionalStore
](Movable, Deinitable):
    """The partition-assignment data-access layer over a
    `CloneableConditionalWriteStore` — the SAME store type the broker's data
    plane (segments / manifests / consumer-group state.json) uses (in-memory twin
    by default, or `S3ConditionalStore[C]` for durability). Two methods: read the
    current assignment (with its etag) and CAS-write a new assignment.

    The store NEVER interprets the body — it persists the opaque serialized
    assignment + carries the etag. The ETag CAS is the concurrency guard (the
    object-store CAS): two coordinators racing to write
    converge because exactly one wins the If-Match; the loser re-reads + retries.
    There is NO database, NO DDL, NO bootstrap — an absent assignment is a 404
    on the first read; the first write creates the object (If-None-Match)."""

    var _store: Self.Storage
    var _cluster: String

    def __init__(out self, var store: Self.Storage, var cluster: String):
        self._store = store^
        self._cluster = cluster^

    def store_ref(ref self) -> ref [self._store] Self.Storage:
        """Borrow the underlying store (test inspection / shared setup)."""
        return self._store

    def clone_store(self) -> Self.Storage:
        """A fresh handle on the SAME underlying store (Arc-
        shared core/map), for the parkable async reassign op (which owns its own
        store clone so it can drive a poll-shaped CAS round-trip on the serve
        reactor without re-borrowing this layer). Infallible (the clone shares
        the Arc-backed data; for S3 it mints a fresh per-handle transport Arc)."""
        return self._store.clone()

    def key_for(self, topic: String) -> String:
        """The per-topic assignment object key (public form of
        `_key`), so the async reassign op can address the same object the sync
        verbs do."""
        return self._key(topic)

    # -------------------------------------------------------------------------
    # _key — the PER-TOPIC assignment object key.
    # -------------------------------------------------------------------------
    def _key(imm self, topic: String) -> String:
        """`<cluster>/_meta/cluster/<topic>/assignment.bin` (PER-TOPIC). The
        `_meta/cluster/` prefix keeps the assignment tree disjoint from the
        consumer-group tree (`_meta/groups/`) and the segment/manifest tree."""
        return (
            self._cluster
            + String("/_meta/cluster/")
            + topic
            + String("/assignment.bin")
        )

    # -------------------------------------------------------------------------
    # read_assignment — current assignment for `topic`, or None (404).
    # -------------------------------------------------------------------------
    def read_assignment(
        mut self, topic: String
    ) raises -> Optional[StoredAssignment]:
        """Read the current assignment for `topic`. head+get; a 404 (no
        assignment ever written) returns None — the coordinator treats that as
        'no prior' and runs the initial pass. The returned etag is the CAS token
        a subsequent `store_assignment` compares against (If-Match).

        Cloned from group_coordinator._load (the 404 -> None discipline)."""
        var path = Path.parse(self._key(topic))
        try:
            var meta = self._store.head(path)
            var body = self._store.get(path)
            return Optional[StoredAssignment](
                StoredAssignment(
                    topic=String(topic),
                    body=body^,
                    etag=meta.etag.copy(),
                )
            )
        except e:
            var msg = String(e)
            if msg.find("not_found") >= 0 or msg.find("404") >= 0:
                return Optional[StoredAssignment](None)
            raise Error(msg)

    # -------------------------------------------------------------------------
    # store_assignment — CAS-write the binary body (create OR If-Match update).
    # -------------------------------------------------------------------------
    def store_assignment(
        mut self, topic: String, var body: List[UInt8], expected_etag: String
    ) raises -> String:
        """Persist `body` for `topic` with the right precondition: an EMPTY
        `expected_etag` (the assignment was absent) creates via If-None-Match;
        a non-empty etag updates via If-Match (compare_and_swap) on that etag.
        Returns the NEW etag (the CAS token for the next write).

        A lost CAS (a concurrent coordinator won) surfaces as a 412 / precondition
        Error from the store — the caller re-reads + recomputes + retries. Cloned
        from group_coordinator._cas_store."""
        var path = Path.parse(self._key(topic))
        if expected_etag.byte_length() == 0:
            var meta = self._store.conditional_put(
                path, body^, WritePrecondition.if_none_match_star()
            )
            return meta.etag.copy()
        var meta = self._store.compare_and_swap(path, body^, expected_etag)
        return meta.etag.copy()

    # -------------------------------------------------------------------------
    # _is_precondition_failure — a lost CAS surfaces as a 412 / precondition.
    # -------------------------------------------------------------------------
    @staticmethod
    def is_precondition_failure(msg: String) -> Bool:
        """A lost CAS surfaces as a 412 / precondition Error from the store. The
        coordinator's retry loop uses this to distinguish a CAS race (re-read +
        retry) from a real I/O error (propagate). Cloned from
        group_coordinator._is_precondition_failure."""
        return (
            msg.find("412") >= 0
            or msg.find("precondition") >= 0
            or msg.find("If-Match") >= 0
            or msg.find("If-None-Match") >= 0
        )
