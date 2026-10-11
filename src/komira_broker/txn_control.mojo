# =============================================================================
# komira_broker/txn_control.mojo
#   The transaction control object — the SOLE linearization point of an
#   exactly-once transaction.
# =============================================================================
#
# The transaction control object is the SINGLE LINEARIZATION POINT of a Kafka-
# style multi-partition transaction on an object-store commit log. There is exactly
# ONE control object per transactional-id:
#
#   <cluster>/_meta/txn/<transactional-id>.json
#
# (a "json" suffix to match the producer-registry / consumer-group convention;
# the body is a small hand-rolled little-endian binary blob, NOT JSON — keeping
# this a zero-extra-dep leaf like producer_registry / manifest_body.)
#
# -----------------------------------------------------------------------------
# WHY THE CONTROL OBJECT (not the markers) IS THE LINEARIZATION POINT
# -----------------------------------------------------------------------------
# A commit spans N partitions. Each partition gets a COMMIT control-batch
# MARKER appended to its manifest (an If-None-Match append, identical to a
# segment commit). Those markers are DURABLE but they are NOT the ordering
# edge — a marker is a RECORD-LOCATOR ("this partition's txn chunks end here"),
# not the commit decision. The commit becomes visible — atomically, all-or-
# nothing AS OBSERVED — only when the control object flips to `Complete` via a
# single `If-Match` CAS. A `read_committed` consumer treats a partition's txn
# records as visible iff (a) the partition's marker is present AND (b) the
# control object reads `Complete` AND (c) the chunk's epoch equals the control
# object's epoch (the epoch-equality fence — see below).
#
# This is what makes a broker death mid-commit ABORTABLE rather than torn: a
# broker that wrote some markers but died before the `Complete` flip leaves the
# control object at `PrepareCommit`; the markers are durable but invisible
# (the object is not `Complete`), and a txn-timeout reaper (or the next
# `InitProducerId` epoch-bump) CAS-transitions the object to `Abort`. No torn
# commit is ever observable.
#
# -----------------------------------------------------------------------------
# THE STATE MACHINE (every transition is an If-Match CAS)
# -----------------------------------------------------------------------------
#   Empty ──AddPartitions──▶ Ongoing ──EndTxn(commit) step1──▶ PrepareCommit
#                                │                                   │
#                                │                          all markers durable
#                                │                                   ▼
#                                │                              Complete  (terminal)
#                                │
#                                └──EndTxn(abort) / reaper / epoch-bump──▶ Abort (terminal)
#                          (PrepareCommit ──reaper / epoch-bump──▶ Abort  also legal:
#                           a broker death after some markers but before Complete.)
#
# `Empty` is the implicit pre-creation state (the object does not exist yet);
# the first `AddPartitionsToTxn` CREATEs the object directly at `Ongoing` via
# If-None-Match. Every subsequent transition is an If-Match CAS on the etag.
#
# -----------------------------------------------------------------------------
# THE EPOCH-EQUALITY FENCE (the soundness keystone)
# -----------------------------------------------------------------------------
# The control object carries the producer `epoch` (from the monotonic-epoch
# registry — `bump_epoch` is strictly monotonic, never reset, never recycled).
# A txn's markers/chunks are tagged with the epoch under which they were
# written. The read filter requires chunk-epoch == control-epoch. This fences a
# STALE marker from an aborted-then-re-committed transactional-id: txn epoch E1
# aborts (its E1 markers stay durable), the producer re-inits to E2 and commits;
# the control object now reads (Complete, E2). The E1 markers carry epoch E1 ≠
# E2 → filtered. Only the E2 commit is visible. Monotonicity makes this a TOTAL
# fence (no epoch is ever reused, so equality admits exactly one incarnation).
#
# -----------------------------------------------------------------------------
# Encapsulation
# -----------------------------------------------------------------------------
# Generic over `ConditionalWriteStore` (the SAME trait the manifest + registry
# use). ZERO UnsafePointer in any signature — bytes flow as owned `List[UInt8]`,
# the precondition is a value POD, the returned etag rides by value. The
# `TxnControl` decoded struct is POD-ish (Int64 scalars + a `List[(String,
# Int64)]` of participating (topic, partition) pairs + one owned String etag);
# it is a stack value, NEVER a byte-slab element. This module is a
# komira_broker LEAF (objectstore-only dep) — both the produce path and the
# consume path import it without a cycle.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition


# =============================================================================
# §1 — transaction states (u8, persisted in the control body).
# =============================================================================

comptime TXN_STATE_EMPTY: UInt8 = 0  # implicit pre-creation (object absent)
comptime TXN_STATE_ONGOING: UInt8 = 1  # AddPartitions seen, txn open
comptime TXN_STATE_PREPARE_COMMIT: UInt8 = 2  # EndTxn(commit) step1, markers pending
comptime TXN_STATE_COMPLETE: UInt8 = 3  # markers durable + flip done (terminal, COMMITTED)
comptime TXN_STATE_PREPARE_ABORT: UInt8 = 4  # EndTxn(abort) step1, abort markers pending
comptime TXN_STATE_ABORT: UInt8 = 5  # aborted (terminal, NOT visible)


@always_inline
def _write_txn_state_name[W: Writer](mut writer: W, state: UInt8):
    """WRITE what `txn_state_name` returns. ⚠ THIS WRITES; IT DOES NOT RETURN.

    The arms live here so no string constant is ever SELECTED and
    returned. A literal-returning ladder lowers to two parallel
    (pointer, length) constant arrays whose two call-site references
    an `--emit shared-lib` link can bind INDEPENDENTLY — and a pair bound
    CROSSED reads the wrong string, or out of bounds."""
    if state == TXN_STATE_EMPTY:
        writer.write(String("Empty"))
        return
    if state == TXN_STATE_ONGOING:
        writer.write(String("Ongoing"))
        return
    if state == TXN_STATE_PREPARE_COMMIT:
        writer.write(String("PrepareCommit"))
        return
    if state == TXN_STATE_COMPLETE:
        writer.write(String("Complete"))
        return
    if state == TXN_STATE_PREPARE_ABORT:
        writer.write(String("PrepareAbort"))
        return
    if state == TXN_STATE_ABORT:
        writer.write(String("Abort"))
        return
    writer.write(String("Unknown"))
    return


@always_inline
def txn_state_name(state: UInt8) -> String:
    var out = String()
    _write_txn_state_name(out, state)
    return out^


@always_inline
def txn_state_is_terminal(state: UInt8) -> Bool:
    """A terminal state (Complete / Abort) is not transition-able further."""
    return state == TXN_STATE_COMPLETE or state == TXN_STATE_ABORT


# =============================================================================
# §2 — little-endian codecs (the control body is i64s + a (topic,part) list).
# =============================================================================


@always_inline
def _tc_put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


@always_inline
def _tc_get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("txn_control: truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


# =============================================================================
# §3 — error-class probes (classify the trait's Error message).
# =============================================================================


@always_inline
def _tc_is_not_found(msg: String) -> Bool:
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )


@always_inline
def _tc_is_precondition(msg: String) -> Bool:
    return (
        msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("412") >= 0
        or msg.find("PreconditionFailed") >= 0
    )


# =============================================================================
# §4 — keys.
# =============================================================================


def txn_control_key(cluster: String, transactional_id: String) raises -> Path:
    """The control object key for a transactional-id (the sole LP object)."""
    return Path.parse(
        cluster + "/_meta/txn/" + transactional_id + ".json"
    )


# =============================================================================
# §5 — TxnPartition — one participating (topic, partition).
# =============================================================================


@fieldwise_init
struct TxnPartition(Copyable, Movable, Deinitable):
    """A participating (topic, partition) in a transaction. POD-ish (one owned
    String + Int64). Not a byte-slab element."""

    var topic: String
    var partition: Int64


# =============================================================================
# §5b — TxnPendingOffset — one STAGED consumer-group offset.
# =============================================================================
#
# read-process-write EOS: a TxnOffsetCommit STAGES a consumer offset against the
# OPEN control object (it does NOT write the live group offset store). The staged
# offsets ride the SAME If-Match CAS as the txn state, so they land atomically on
# the Complete flip and are dropped on Abort. The control object remains the SOLE
# linearization point for BOTH the produced records AND the consumed offsets.
# =============================================================================


@fieldwise_init
struct TxnPendingOffset(Copyable, Movable, Deinitable):
    """One staged consumer-group offset commit for an open transaction. The
    `(group, topic, partition)` is the offset key; `offset` is the next-to-read
    offset the read-process-write loop wants to commit; `metadata` is the
    optional client metadata. POD-ish (3 owned Strings + 2 Int64); not a
    byte-slab element (a stack value held in a `List` on the
    decoded TxnControl)."""

    var group: String
    var topic: String
    var partition: Int64
    var offset: Int64
    var metadata: String


# =============================================================================
# §6 — TxnControl — the decoded control-object body.
# =============================================================================


struct TxnControl(Movable, Deinitable):
    """One decoded transaction control object — the SOLE linearization point.

    Body wire layout (little-endian):
      [ producer_id: i64 ][ epoch: i64 ][ state: i64 (u8 widened) ]
      [ complete_version: i64 ][ n_partitions: i64 ]
      ( [ topic_len: i64 ][ topic bytes... ][ partition: i64 ] ) * n_partitions
      [ n_pending_offsets: i64 ]
      ( [ group_len: i64 ][ group bytes... ]
        [ topic_len: i64 ][ topic bytes... ]
        [ partition: i64 ][ offset: i64 ]
        [ meta_len: i64 ][ meta bytes... ] ) * n_pending_offsets

    `complete_version` is a monotone version stamp bumped on every transition —
    a tie-breaker / audit field (the etag is the real CAS token; this version
    is for human/debug observability and lets a consumer detect "the object
    changed" without comparing the opaque etag). `epoch` is the monotonic
    producer epoch under which this txn runs (the epoch-equality
    fence reads it). `etag` is the control object's server-assigned version for
    the next If-Match CAS (empty if not read with a head).

    `pending_offsets` are the STAGED consumer-group offset commits
    of an open read-process-write transaction: a TxnOffsetCommit appends to this
    list against the OPEN object via the same If-Match CAS that drives the state,
    so the staged offsets land ATOMICALLY on the Complete flip (materialized into
    the live group offset store) and are DROPPED on Abort. The control object
    stays the SOLE linearization point for BOTH records AND offsets — there is no
    second LP. The wire field is appended AFTER the partitions block so an older
    decoder that stops at the partitions block still reads a valid (offset-less)
    object; a missing trailing block decodes to an empty pending-offsets list.

    Movable-only (it owns a `List[TxnPartition]` + `List[TxnPendingOffset]` of
    owned Strings). A stack / struct value, NEVER a byte-slab element."""

    var producer_id: Int64
    var epoch: Int64
    var state: UInt8
    var complete_version: Int64
    var partitions: List[TxnPartition]
    var pending_offsets: List[TxnPendingOffset]
    var etag: String

    def __init__(
        out self,
        producer_id: Int64,
        epoch: Int64,
        state: UInt8,
        complete_version: Int64,
        var partitions: List[TxnPartition],
        var pending_offsets: List[TxnPendingOffset],
        var etag: String,
    ):
        self.producer_id = producer_id
        self.epoch = epoch
        self.state = state
        self.complete_version = complete_version
        self.partitions = partitions^
        self.pending_offsets = pending_offsets^
        self.etag = etag^

    def copy(self) -> Self:
        var parts = List[TxnPartition]()
        for i in range(len(self.partitions)):
            parts.append(self.partitions[i].copy())
        var offs = List[TxnPendingOffset]()
        for i in range(len(self.pending_offsets)):
            offs.append(self.pending_offsets[i].copy())
        return TxnControl(
            self.producer_id,
            self.epoch,
            self.state,
            self.complete_version,
            parts^,
            offs^,
            String(self.etag),
        )

    def has_partition(self, topic: String, partition: Int64) -> Bool:
        for i in range(len(self.partitions)):
            if (
                self.partitions[i].topic == topic
                and self.partitions[i].partition == partition
            ):
                return True
        return False

    def copy_pending_offsets(self) -> List[TxnPendingOffset]:
        """A deep copy of the staged pending-offset list (used by the CAS
        transition helpers, which must carry the staged offsets forward across
        every state flip until they are materialized on Complete or dropped on
        Abort)."""
        var offs = List[TxnPendingOffset]()
        for i in range(len(self.pending_offsets)):
            offs.append(self.pending_offsets[i].copy())
        return offs^

    def upsert_pending_offset(
        mut self,
        group: String,
        topic: String,
        partition: Int64,
        offset: Int64,
        metadata: String,
    ):
        """Stage (or overwrite) one consumer offset for `(group, topic,
        partition)` on this open transaction. Last-writer-wins per key (a
        re-commit of the same key within the txn replaces the staged value),
        matching the group offset store's last-write-wins per-partition
        semantic."""
        for i in range(len(self.pending_offsets)):
            ref po = self.pending_offsets[i]
            if (
                po.group == group
                and po.topic == topic
                and po.partition == partition
            ):
                po.offset = offset
                po.metadata = String(metadata)
                return
        self.pending_offsets.append(
            TxnPendingOffset(
                String(group),
                String(topic),
                partition,
                offset,
                String(metadata),
            )
        )

    def encode(self) -> List[UInt8]:
        """Encode the control body. The etag is NOT in the body (it is the
        object's server-assigned version, read separately)."""
        var out = List[UInt8]()
        _tc_put_i64_le(out, self.producer_id)
        _tc_put_i64_le(out, self.epoch)
        _tc_put_i64_le(out, Int64(Int(self.state)))
        _tc_put_i64_le(out, self.complete_version)
        _tc_put_i64_le(out, Int64(len(self.partitions)))
        for i in range(len(self.partitions)):
            var tb = self.partitions[i].topic.as_bytes()
            _tc_put_i64_le(out, Int64(len(tb)))
            for j in range(len(tb)):
                out.append(tb[j])
            _tc_put_i64_le(out, self.partitions[i].partition)
        # Staged pending consumer-offset commits (trailing block).
        _tc_put_i64_le(out, Int64(len(self.pending_offsets)))
        for i in range(len(self.pending_offsets)):
            ref po = self.pending_offsets[i]
            var gb = po.group.as_bytes()
            _tc_put_i64_le(out, Int64(len(gb)))
            for j in range(len(gb)):
                out.append(gb[j])
            var tb2 = po.topic.as_bytes()
            _tc_put_i64_le(out, Int64(len(tb2)))
            for j in range(len(tb2)):
                out.append(tb2[j])
            _tc_put_i64_le(out, po.partition)
            _tc_put_i64_le(out, po.offset)
            var mb = po.metadata.as_bytes()
            _tc_put_i64_le(out, Int64(len(mb)))
            for j in range(len(mb)):
                out.append(mb[j])
        return out^

    @staticmethod
    def decode(bytes: List[UInt8], var etag: String) raises -> TxnControl:
        var producer_id = _tc_get_i64_le(bytes, 0)
        var epoch = _tc_get_i64_le(bytes, 8)
        var state = UInt8(Int(_tc_get_i64_le(bytes, 16)) & 0xFF)
        var complete_version = _tc_get_i64_le(bytes, 24)
        var n_parts = Int(_tc_get_i64_le(bytes, 32))
        var parts = List[TxnPartition]()
        var off = 40
        for _ in range(n_parts):
            var tlen = Int(_tc_get_i64_le(bytes, off))
            off += 8
            if off + tlen > len(bytes):
                raise Error("TxnControl.decode: truncated topic name")
            var topic = String("")
            for k in range(tlen):
                topic += chr(Int(bytes[off + k]))
            off += tlen
            var part = _tc_get_i64_le(bytes, off)
            off += 8
            parts.append(TxnPartition(topic^, part))
        # Staged pending consumer-offset commits (trailing block).
        # A control body written by an older encoder has no trailing block; in
        # that case `off` is at end-of-bytes and the list decodes empty.
        var offs = List[TxnPendingOffset]()
        if off + 8 <= len(bytes):
            var n_off = Int(_tc_get_i64_le(bytes, off))
            off += 8
            for _ in range(n_off):
                var glen = Int(_tc_get_i64_le(bytes, off))
                off += 8
                if off + glen > len(bytes):
                    raise Error("TxnControl.decode: truncated offset group")
                var group = String("")
                for k in range(glen):
                    group += chr(Int(bytes[off + k]))
                off += glen
                var otlen = Int(_tc_get_i64_le(bytes, off))
                off += 8
                if off + otlen > len(bytes):
                    raise Error("TxnControl.decode: truncated offset topic")
                var otopic = String("")
                for k in range(otlen):
                    otopic += chr(Int(bytes[off + k]))
                off += otlen
                var opart = _tc_get_i64_le(bytes, off)
                off += 8
                var ooffset = _tc_get_i64_le(bytes, off)
                off += 8
                var mlen = Int(_tc_get_i64_le(bytes, off))
                off += 8
                if off + mlen > len(bytes):
                    raise Error("TxnControl.decode: truncated offset metadata")
                var meta = String("")
                for k in range(mlen):
                    meta += chr(Int(bytes[off + k]))
                off += mlen
                offs.append(
                    TxnPendingOffset(group^, otopic^, opart, ooffset, meta^)
                )
        return TxnControl(
            producer_id, epoch, state, complete_version, parts^, offs^, etag^
        )


# =============================================================================
# §7 — TxnControlStore[Store] — the control-object CAS state machine.
# =============================================================================


struct TxnControlStore[Store: ConditionalWriteStore](
    Movable, Deinitable
):
    """The transaction control-object state machine over any
    `ConditionalWriteStore` (S3 / in-memory). Owns its backend `Store` by value
    + the cluster prefix. Every state transition is an `If-Match` CAS on the
    control object's etag (or `If-None-Match` create for the first transition),
    so the control object is the durable, broker-shared SOLE linearization
    point — pure-S3 EOS, no in-memory coordinator.

    Fields:
      var _store: Store     — the backend (S3 / in-memory).
      var _cluster: String  — the cluster prefix (`<cluster>/_meta/txn`)."""

    var _store: Self.Store
    var _cluster: String

    def __init__(out self, var store: Self.Store, var cluster: String):
        self._store = store^
        self._cluster = cluster^

    @always_inline
    def cluster(self) -> String:
        return self._cluster

    # ---- read the current control object ----

    def read(self, transactional_id: String) raises -> Optional[TxnControl]:
        """Read the control object for `transactional_id`, or `None` if it does
        not exist yet (the implicit `Empty` state). The returned `TxnControl`
        carries the etag for the next `If-Match` CAS. This is the strongly-
        consistent GET the consumer's pinned snapshot is built from (S3 is
        read-after-write consistent)."""
        var key = txn_control_key(self._cluster, transactional_id)
        try:
            var raw = self._store.get(key)
            var meta = self._store.head(key)
            return Optional(TxnControl.decode(raw, String(meta.etag)))
        except e:
            if _tc_is_not_found(String(e)):
                return Optional[TxnControl](None)
            raise e^

    # ---- begin (the first AddPartitionsToTxn CREATE) ----

    def begin(
        mut self,
        transactional_id: String,
        producer_id: Int64,
        epoch: Int64,
    ) raises -> TxnControl:
        """Open a transaction: CREATE the control object at `Ongoing` with an
        empty participating set via `If-None-Match` (the Empty → Ongoing edge).
        If the object already exists for this id (a prior txn's terminal
        object), it is RESET to a fresh Ongoing under the (possibly bumped)
        epoch via `If-Match` CAS — a re-used transactional-id starts a new
        transaction. Raises `precondition` only on a genuine concurrent race
        (caller retries by re-reading)."""
        var existing = self.read(transactional_id)
        if not existing:
            # Fresh id — CREATE at Ongoing (no participating partitions, no
            # staged offsets yet).
            var tc = TxnControl(
                producer_id,
                epoch,
                TXN_STATE_ONGOING,
                Int64(1),
                List[TxnPartition](),
                List[TxnPendingOffset](),
                String(""),
            )
            var key = txn_control_key(self._cluster, transactional_id)
            var meta = self._store.conditional_put(
                key, tc.encode(), WritePrecondition.if_none_match_star()
            )
            return TxnControl(
                producer_id,
                epoch,
                TXN_STATE_ONGOING,
                Int64(1),
                List[TxnPartition](),
                List[TxnPendingOffset](),
                String(meta.etag),
            )
        # Re-used id — CAS-reset a terminal/prior object to a new Ongoing. The
        # epoch carried here must be >= the existing epoch (the registry's
        # monotonic bump guarantees it). Bumps complete_version.
        ref prev = existing.value()
        var next_ver = prev.complete_version + Int64(1)
        var key2 = txn_control_key(self._cluster, transactional_id)
        var fresh = TxnControl(
            producer_id,
            epoch,
            TXN_STATE_ONGOING,
            next_ver,
            List[TxnPartition](),
            List[TxnPendingOffset](),
            String(""),
        )
        var meta2 = self._store.conditional_put(
            key2, fresh.encode(), WritePrecondition.if_match(prev.etag)
        )
        return TxnControl(
            producer_id,
            epoch,
            TXN_STATE_ONGOING,
            next_ver,
            List[TxnPartition](),
            List[TxnPendingOffset](),
            String(meta2.etag),
        )

    # ---- add participating partitions (Ongoing, idempotent union) ----

    def add_partitions(
        mut self,
        transactional_id: String,
        var new_partitions: List[TxnPartition],
    ) raises -> TxnControl:
        """Union `new_partitions` into the Ongoing transaction's participating
        set via an `If-Match` CAS. Idempotent (re-adding a partition is a
        no-op). Raises if the txn is not Ongoing (you cannot add a partition to
        a terminal/preparing txn). Retries on a 412 (concurrent CAS)."""
        var attempt = 0
        while True:
            attempt += 1
            var cur_opt = self.read(transactional_id)
            if not cur_opt:
                raise Error(
                    "TxnControlStore.add_partitions: no open transaction for '"
                    + transactional_id
                    + "'"
                )
            ref cur = cur_opt.value()
            if cur.state != TXN_STATE_ONGOING:
                raise Error(
                    "TxnControlStore.add_partitions: txn '"
                    + transactional_id
                    + "' is "
                    + txn_state_name(cur.state)
                    + " (not Ongoing)"
                )
            var merged = List[TxnPartition]()
            for i in range(len(cur.partitions)):
                merged.append(cur.partitions[i].copy())
            for j in range(len(new_partitions)):
                if not cur.has_partition(
                    new_partitions[j].topic, new_partitions[j].partition
                ):
                    merged.append(new_partitions[j].copy())
            var next_ver = cur.complete_version + Int64(1)
            # Carry the staged pending-offset list forward unchanged.
            var carried_offs = cur.copy_pending_offsets()
            var updated = TxnControl(
                cur.producer_id,
                cur.epoch,
                TXN_STATE_ONGOING,
                next_ver,
                merged^,
                carried_offs^,
                String(""),
            )
            var key = txn_control_key(self._cluster, transactional_id)
            try:
                var meta = self._store.conditional_put(
                    key, updated.encode(), WritePrecondition.if_match(cur.etag)
                )
                # Re-read to return the full merged state with the new etag.
                var out = self.read(transactional_id)
                if out:
                    return out.value().copy()
                # Should not happen (we just wrote it): return what was
                # written (the merged partitions and the carried offsets).
                updated.etag = String(meta.etag)
                return updated^
            except e:
                if not _tc_is_precondition(String(e)):
                    raise e^
                if attempt > 32:
                    raise Error(
                        "TxnControlStore.add_partitions: exhausted CAS retries"
                    )
                continue

    # ---- stage a consumer-group offset (Ongoing) ----

    def stage_offset(
        mut self,
        transactional_id: String,
        group: String,
        topic: String,
        partition: Int64,
        offset: Int64,
        metadata: String,
    ) raises -> TxnControl:
        """STAGE one consumer-group offset for `(group, topic, partition)` on the
        Ongoing transaction via an `If-Match` CAS (the TxnOffsetCommit edge of a
        read-process-write loop). The offset rides the control body, so it lands
        ATOMICALLY on the Complete flip (materialized into the live group offset
        store) and is DROPPED on Abort. Last-writer-wins per key within the txn.

        Raises if the txn is not Ongoing (you cannot stage an offset onto a
        terminal/preparing txn). Retries on a 412 (concurrent CAS). The
        control object remains the SOLE linearization point — no second LP."""
        var attempt = 0
        while True:
            attempt += 1
            var cur_opt = self.read(transactional_id)
            if not cur_opt:
                raise Error(
                    "TxnControlStore.stage_offset: no open transaction for '"
                    + transactional_id
                    + "'"
                )
            ref cur = cur_opt.value()
            if cur.state != TXN_STATE_ONGOING:
                raise Error(
                    "TxnControlStore.stage_offset: txn '"
                    + transactional_id
                    + "' is "
                    + txn_state_name(cur.state)
                    + " (not Ongoing)"
                )
            var next_ver = cur.complete_version + Int64(1)
            var carried_parts = List[TxnPartition]()
            for i in range(len(cur.partitions)):
                carried_parts.append(cur.partitions[i].copy())
            var carried_offs = cur.copy_pending_offsets()
            var updated = TxnControl(
                cur.producer_id,
                cur.epoch,
                TXN_STATE_ONGOING,
                next_ver,
                carried_parts^,
                carried_offs^,
                String(""),
            )
            updated.upsert_pending_offset(
                group, topic, partition, offset, metadata
            )
            var key = txn_control_key(self._cluster, transactional_id)
            try:
                var meta = self._store.conditional_put(
                    key, updated.encode(), WritePrecondition.if_match(cur.etag)
                )
                # Re-read to return the full staged state with the new etag.
                var out = self.read(transactional_id)
                if out:
                    return out.value().copy()
                # Should not happen (we just wrote it) — synthesize from updated.
                var rparts = List[TxnPartition]()
                for i in range(len(updated.partitions)):
                    rparts.append(updated.partitions[i].copy())
                var roffs = updated.copy_pending_offsets()
                return TxnControl(
                    updated.producer_id,
                    updated.epoch,
                    TXN_STATE_ONGOING,
                    next_ver,
                    rparts^,
                    roffs^,
                    String(meta.etag),
                )
            except e:
                if not _tc_is_precondition(String(e)):
                    raise e^
                if attempt > 32:
                    raise Error(
                        "TxnControlStore.stage_offset: exhausted CAS retries"
                    )
                continue

    # ---- transition: Ongoing -> PrepareCommit (EndTxn(commit) step 1) ----

    def prepare_commit(
        mut self, transactional_id: String
    ) raises -> TxnControl:
        """CAS the txn from `Ongoing` to `PrepareCommit` (EndTxn(commit) step 1
        — BEFORE the markers are appended). Returns the updated control object.
        Raises if the txn is not Ongoing."""
        return self._cas_transition(
            transactional_id,
            TXN_STATE_ONGOING,
            TXN_STATE_PREPARE_COMMIT,
        )

    # ---- transition: PrepareCommit -> Complete (the LINEARIZATION POINT) ----

    def complete_commit(
        mut self, transactional_id: String
    ) raises -> TxnControl:
        """CAS the txn from `PrepareCommit` to `Complete` — THE single
        linearization point. Call this ONLY after EVERY participating
        partition's COMMIT marker is durable. The instant this CAS succeeds,
        the whole multi-partition commit becomes visible atomically to
        `read_committed` consumers. Raises if the txn is not PrepareCommit."""
        return self._cas_transition(
            transactional_id,
            TXN_STATE_PREPARE_COMMIT,
            TXN_STATE_COMPLETE,
        )

    # ---- transition: Ongoing -> PrepareAbort (EndTxn(abort) step 1) ----

    def prepare_abort(
        mut self, transactional_id: String
    ) raises -> TxnControl:
        """CAS the txn from `Ongoing` to `PrepareAbort` (EndTxn(abort) step 1)."""
        return self._cas_transition(
            transactional_id,
            TXN_STATE_ONGOING,
            TXN_STATE_PREPARE_ABORT,
        )

    # ---- transition: -> Abort (the abortable-recovery edge) ----

    def abort(self, transactional_id: String) raises -> TxnControl:
        """Transition the txn to `Abort` from ANY non-terminal state via an
        `If-Match` CAS. This is the broker-death-recovery + reaper + EndTxn
        (abort) edge: a txn left at Ongoing / PrepareCommit / PrepareAbort by a
        broker that died mid-transaction is resolved to Abort here (the markers
        it may have written stay durable but are filtered by state==Abort +
        epoch mismatch — never a torn commit). Idempotent on an already-Abort
        object (returns it unchanged). Raises if the txn is already Complete (a
        completed commit cannot be aborted — that would be a torn commit)."""
        var attempt = 0
        while True:
            attempt += 1
            var cur_opt = self.read(transactional_id)
            if not cur_opt:
                raise Error(
                    "TxnControlStore.abort: no transaction for '"
                    + transactional_id
                    + "'"
                )
            ref cur = cur_opt.value()
            if cur.state == TXN_STATE_ABORT:
                return cur.copy()  # idempotent
            if cur.state == TXN_STATE_COMPLETE:
                raise Error(
                    "TxnControlStore.abort: txn '"
                    + transactional_id
                    + "' is Complete (a committed txn cannot be aborted)"
                )
            var next_ver = cur.complete_version + Int64(1)
            var parts = List[TxnPartition]()
            for i in range(len(cur.partitions)):
                parts.append(cur.partitions[i].copy())
            # Carry the staged offsets forward into the Abort object. They are
            # NEVER materialized (only a Complete flip materializes them — see
            # the data-plane txn_end), so on Abort the consumer offset is left
            # un-advanced and a restart reprocesses (correct read-process-write
            # EOS). Keeping them in the body is harmless + aids diagnostics.
            var aborted_offs = cur.copy_pending_offsets()
            var aborted = TxnControl(
                cur.producer_id,
                cur.epoch,
                TXN_STATE_ABORT,
                next_ver,
                parts^,
                aborted_offs^,
                String(""),
            )
            var key = txn_control_key(self._cluster, transactional_id)
            try:
                var meta = self._store.conditional_put(
                    key, aborted.encode(), WritePrecondition.if_match(cur.etag)
                )
                var rparts = List[TxnPartition]()
                for i in range(len(cur.partitions)):
                    rparts.append(cur.partitions[i].copy())
                var roffs = cur.copy_pending_offsets()
                return TxnControl(
                    cur.producer_id,
                    cur.epoch,
                    TXN_STATE_ABORT,
                    next_ver,
                    rparts^,
                    roffs^,
                    String(meta.etag),
                )
            except e:
                if not _tc_is_precondition(String(e)):
                    raise e^
                if attempt > 32:
                    raise Error("TxnControlStore.abort: exhausted CAS retries")
                continue

    # ---- the shared If-Match CAS transition helper ----

    def _cas_transition(
        self,
        transactional_id: String,
        expected_state: UInt8,
        new_state: UInt8,
    ) raises -> TxnControl:
        var attempt = 0
        while True:
            attempt += 1
            var cur_opt = self.read(transactional_id)
            if not cur_opt:
                raise Error(
                    "TxnControlStore: no transaction for '"
                    + transactional_id
                    + "' (expected "
                    + txn_state_name(expected_state)
                    + ")"
                )
            ref cur = cur_opt.value()
            if cur.state != expected_state:
                raise Error(
                    "TxnControlStore: txn '"
                    + transactional_id
                    + "' is "
                    + txn_state_name(cur.state)
                    + ", expected "
                    + txn_state_name(expected_state)
                    + " for transition to "
                    + txn_state_name(new_state)
                )
            var next_ver = cur.complete_version + Int64(1)
            var parts = List[TxnPartition]()
            for i in range(len(cur.partitions)):
                parts.append(cur.partitions[i].copy())
            # Carry the staged pending-offset list forward across the state flip
            # (PrepareCommit -> Complete must still carry them so the Complete
            # object can materialize them — the load-bearing atomicity edge).
            var carried_offs = cur.copy_pending_offsets()
            var updated = TxnControl(
                cur.producer_id,
                cur.epoch,
                new_state,
                next_ver,
                parts^,
                carried_offs^,
                String(""),
            )
            var key = txn_control_key(self._cluster, transactional_id)
            try:
                var meta = self._store.conditional_put(
                    key, updated.encode(), WritePrecondition.if_match(cur.etag)
                )
                var rparts = List[TxnPartition]()
                for i in range(len(cur.partitions)):
                    rparts.append(cur.partitions[i].copy())
                var roffs = cur.copy_pending_offsets()
                return TxnControl(
                    cur.producer_id,
                    cur.epoch,
                    new_state,
                    next_ver,
                    rparts^,
                    roffs^,
                    String(meta.etag),
                )
            except e:
                if not _tc_is_precondition(String(e)):
                    raise e^
                if attempt > 32:
                    raise Error(
                        "TxnControlStore._cas_transition: exhausted CAS retries"
                    )
                continue
