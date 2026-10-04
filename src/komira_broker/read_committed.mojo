# =============================================================================
# komira_broker/read_committed.mojo
#   read_committed visibility filter + the PINNED-SNAPSHOT resolution.
#   Exactly-once: transactions.
# =============================================================================
#
# This module is the LOAD-BEARING correctness crux of transactions: the
# `read_committed` isolation filter and — above it — the PINNED-SNAPSHOT
# multi-partition resolution. It is deliberately a set of PURE value functions
# over POD inputs so the torn-commit hazard (a Complete-flip mid-Fetch yielding
# a partial-commit view) is a deterministic offline property test, independent
# of any object-store plumbing.
#
# -----------------------------------------------------------------------------
# THE PINNED-SNAPSHOT INVARIANT (the subtle correctness crux)
# -----------------------------------------------------------------------------
# A multi-partition Fetch under `read_committed` MUST resolve against ONE
# control-object snapshot taken at Fetch-entry. The flow:
#
#   1. At Fetch-entry, collect the set of distinct transactional-ids referenced
#      by ANY chunk in ANY of the requested partitions' manifests (each chunk's
#      txn trailer carries `txn_id` + `producer_epoch`).
#   2. Do ONE strongly-consistent GET of each referenced control object →
#      build an immutable `TxnSnapshot` map `txn_id -> (state, control_epoch)`.
#   3. Resolve ALL requested partitions against THAT ONE frozen snapshot.
#      NEVER re-GET a control object mid-resolution.
#
# WHY: if the control object flips to Complete BETWEEN what would be two
# per-partition reads, a per-partition re-read would see partition P1 committed
# and partition P2 still uncommitted (or vice-versa) — a TORN partial-commit
# view. A single snapshot, taken once, forces every
# partition to resolve against the SAME committed-or-not decision → all-or-
# nothing AS OBSERVED.
#
# -----------------------------------------------------------------------------
# THE VISIBILITY PREDICATE (the epoch-equality fence)
# -----------------------------------------------------------------------------
# A chunk is visible to a `read_committed` consumer iff:
#   * it is NON-transactional (`txn_id == ""`); OR
#   * its txn's snapshot state is `Complete` AND `chunk.epoch ==
#     snapshot.control_epoch`.
# A txn-open chunk whose txn is Ongoing / PrepareCommit / Abort, or whose epoch
# differs from the control epoch (a stale marker from an aborted-then-re-
# committed transactional-id under a new epoch), is FILTERED. Monotonic epochs
# (from the producer registry, never reused) make the epoch-equality a TOTAL fence.
#
# `read_uncommitted` (Kafka's default isolation) skips this filter entirely —
# every chunk (txn-open or not) is visible.
#
# Encapsulation: pure value functions + POD result/snapshot structs. ZERO
# pointers, ZERO wildcard origins. The snapshot map is a plain struct with
# parallel `List`s (a Fetch references few txns) — not a slab.
# =============================================================================

from .txn_control import (
    TXN_STATE_COMPLETE,
    TXN_STATE_ABORT,
    txn_state_name,
)
from .manifest_body import MARKER_NONE, MARKER_COMMIT, MARKER_ABORT


# =============================================================================
# §1 — ChunkTxnTag — the per-chunk transaction metadata the filter reads.
# =============================================================================


@fieldwise_init
struct ChunkTxnTag(Copyable, Movable, Deinitable):
    """The transaction tag of one manifest chunk (the subset of ManifestBody
    the read_committed filter needs). POD-ish (Int64s + one owned String).

    Field layout:
      var marker_type: Int64 — MARKER_NONE / MARKER_COMMIT / MARKER_ABORT.
      var txn_id: String     — the transactional-id ("" == non-transactional).
      var epoch: Int64       — the producer epoch the chunk was written under
                               (the epoch-equality fence input;
                               == ManifestBody.producer_epoch).
    """

    var marker_type: Int64
    var txn_id: String
    var epoch: Int64

    @always_inline
    def is_marker(self) -> Bool:
        return self.marker_type != MARKER_NONE

    @always_inline
    def is_transactional(self) -> Bool:
        return self.txn_id.byte_length() != 0


# =============================================================================
# §2 — TxnSnapshot — the PINNED control-object snapshot (taken once at entry).
# =============================================================================


struct TxnSnapshot(Movable, Deinitable):
    """The immutable, pinned snapshot of every referenced txn control object,
    taken ONCE at Fetch-entry. The whole multi-partition resolution reads ONLY
    this — never re-GETs a control object — which is what makes a concurrent
    Complete-flip invisible to the in-flight Fetch (the all-or-nothing
    guarantee).

    Parallel-list map (`txn_id -> (state, control_epoch)`); a Fetch references
    few txns so a linear probe is fine. A plain struct value, NEVER a byte-slab
    element.

    Fields:
      var _ids: List[String]      — referenced transactional-ids.
      var _states: List[UInt8]    — each id's snapshotted state.
      var _epochs: List[Int64]    — each id's snapshotted control epoch.
    """

    var _ids: List[String]
    var _states: List[UInt8]
    var _epochs: List[Int64]

    def __init__(out self):
        self._ids = List[String]()
        self._states = List[UInt8]()
        self._epochs = List[Int64]()

    def put(mut self, var txn_id: String, state: UInt8, control_epoch: Int64):
        """Record one txn's snapshotted (state, control_epoch). Last-writer-wins
        on a duplicate id (a snapshot is built once, so duplicates should not
        occur — this is defensive)."""
        for i in range(len(self._ids)):
            if self._ids[i] == txn_id:
                self._states[i] = state
                self._epochs[i] = control_epoch
                return
        self._ids.append(txn_id^)
        self._states.append(state)
        self._epochs.append(control_epoch)

    def contains(self, txn_id: String) -> Bool:
        for i in range(len(self._ids)):
            if self._ids[i] == txn_id:
                return True
        return False

    def state_of(self, txn_id: String) -> UInt8:
        """The snapshotted state of `txn_id`, or TXN_STATE_ABORT if the txn is
        not in the snapshot. Treating an UNKNOWN txn as Abort is the SAFE
        default: a chunk tagged with a txn whose control object does not exist
        (or was not collected) must NOT be visible (it cannot be proven
        committed). This makes an absent/never-created control object behave
        exactly like an aborted one for the filter."""
        for i in range(len(self._ids)):
            if self._ids[i] == txn_id:
                return self._states[i]
        return TXN_STATE_ABORT

    def epoch_of(self, txn_id: String) -> Int64:
        """The snapshotted control epoch of `txn_id`, or -1 if absent."""
        for i in range(len(self._ids)):
            if self._ids[i] == txn_id:
                return self._epochs[i]
        return Int64(-1)

    @always_inline
    def size(self) -> Int:
        return len(self._ids)


# =============================================================================
# §3 — the visibility predicate (epoch-equality fence).
# =============================================================================


def chunk_is_visible(tag: ChunkTxnTag, snapshot: TxnSnapshot) -> Bool:
    """Is a chunk with transaction `tag` visible to a `read_committed` consumer
    against the PINNED `snapshot`?

    The predicate:
      * a marker chunk (COMMIT/ABORT) is NEVER itself "visible" as data — it
        carries no records and is consumed only as a close-boundary / filter
        signal. Returns False for any marker.
      * a NON-transactional data chunk (`txn_id == ""`) is always visible.
      * a transactional data chunk is visible iff its txn's snapshot state is
        `Complete` AND `tag.epoch == snapshot.control_epoch` (the epoch-equality
        fence: a stale marker/chunk from an aborted-then-re-committed
        transactional-id carries the OLD epoch and is filtered).

    An unknown txn (not in the snapshot) resolves to state Abort → not visible
    (the safe default — an unprovable commit is hidden)."""
    # A marker chunk is never visible as data.
    if tag.is_marker():
        return False
    # Non-transactional → always visible.
    if not tag.is_transactional():
        return True
    # Transactional data chunk → Complete + epoch-equality.
    var state = snapshot.state_of(tag.txn_id)
    if state != TXN_STATE_COMPLETE:
        return False
    var control_epoch = snapshot.epoch_of(tag.txn_id)
    return tag.epoch == control_epoch


@always_inline
def chunk_is_offset_bearing(tag: ChunkTxnTag) -> Bool:
    """Does this chunk occupy an offset range in the partition's offset space?

    Marker chunks (COMMIT/ABORT) carry ZERO records and do NOT consume an
    offset — they occupy a manifest SLOT but advance the offset range by 0.
    Offset resolution skips them (their `record_count` is 0 anyway, so this is
    belt-and-suspenders: a marker never widens the offset space). Data chunks
    (marker_type == MARKER_NONE) are offset-bearing whether or not they are
    transactional (a txn-open chunk DOES occupy offsets; it is merely hidden
    from read_committed until its txn completes)."""
    return tag.marker_type == MARKER_NONE


# =============================================================================
# §4 — referenced-txn collection (step 1 of the pinned-snapshot flow).
# =============================================================================


def collect_referenced_txn_ids(tags: List[ChunkTxnTag]) -> List[String]:
    """Collect the DISTINCT transactional-ids referenced by any chunk in
    `tags` (the per-partition chunk tags, possibly concatenated across all
    requested partitions). This is step 1 of the pinned-snapshot flow: the
    caller does ONE control-object GET per returned id to build the snapshot.
    Empty/non-transactional tags are skipped. Order-preserving + deduped."""
    var out = List[String]()
    for i in range(len(tags)):
        if not tags[i].is_transactional():
            continue
        var seen = False
        for j in range(len(out)):
            if out[j] == tags[i].txn_id:
                seen = True
                break
        if not seen:
            out.append(String(tags[i].txn_id))
    return out^
