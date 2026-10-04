# =============================================================================
# komira_broker/producer_registry.mojo
#   The idempotent-producer registry (exactly-once: the producer fence).
# =============================================================================
#
# The producer registry is the zombie-producer fence: it allocates a
# producer_id + a STRICTLY-MONOTONIC producer_epoch, persisted in the object
# store (so the fence survives broker restarts and is shared across all
# brokers — no in-memory coordinator). One object per producer:
#
#   <cluster>/_meta/producers/<producer_id>.json
#
# (a "json" suffix to match the consumer-group state convention; the body is a
# small hand-rolled binary blob, NOT JSON — keeping this a zero-extra-dep leaf
# like manifest_body.)
#
# -----------------------------------------------------------------------------
# MONOTONIC EPOCH (the most load-bearing invariant)
# -----------------------------------------------------------------------------
# `init_producer_id` is the InitProducerId RPC backend. For a brand-new
# producer it CREATEs the registry object via `If-None-Match: *` (epoch 0).
# A re-InitProducerId for the SAME producer_id BUMPS the epoch via an
# `If-Match` CAS on the current etag — `new_epoch = old_epoch + 1`. The epoch
# is NEVER reset, NEVER recycled to a lower-or-equal value: a concurrent
# bump race resolves to exactly one winner (the loser re-reads and bumps
# again, so its epoch is strictly higher than the winner's). This fences the
# prior incarnation — a produce carrying `epoch < registered_epoch` is a
# zombie and is rejected (the caller maps that to INVALID_PRODUCER_EPOCH).
#
# Producer ids are allocated monotonically from a single counter object
# (`<cluster>/_meta/producers/_id_counter`), also CAS-advanced. The
# transactional-id → producer_id binding (so a producer restart reuses its id
# and bumps the SAME epoch) lives in txn_registry and builds on this substrate
# (registry object + monotonic epoch CAS).
#
# -----------------------------------------------------------------------------
# Encapsulation
# -----------------------------------------------------------------------------
# Generic over `ConditionalWriteStore` (the SAME trait the manifest + segment
# stores use). ZERO UnsafePointer in any signature — bytes flow as owned
# `List[UInt8]`, the precondition is a value POD, the returned ObjectMeta
# carries the etag by value. POD-ish struct (Int64 fields + one owned String
# etag); not a byte-slab element. This module is a komira_broker
# LEAF (objectstore-only dep) — both the data plane and transactions
# import it without a cycle.
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition


# =============================================================================
# §1 — little-endian i64 codec (the registry body is 2 i64s).
# =============================================================================


@always_inline
def _pr_put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


@always_inline
def _pr_get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("producer_registry: truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


# =============================================================================
# §2 — error-class probes (classify the trait's Error message).
# =============================================================================


@always_inline
def _pr_is_not_found(msg: String) -> Bool:
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )


@always_inline
def _pr_is_precondition(msg: String) -> Bool:
    return (
        msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("412") >= 0
        or msg.find("PreconditionFailed") >= 0
    )


# =============================================================================
# §3 — keys.
# =============================================================================


def producer_key(cluster: String, producer_id: Int64) raises -> Path:
    """The registry object key for `producer_id`."""
    return Path.parse(
        cluster
        + "/_meta/producers/"
        + String(producer_id)
        + ".json"
    )


def producer_id_counter_key(cluster: String) raises -> Path:
    """The monotone producer-id allocator object key."""
    return Path.parse(cluster + "/_meta/producers/_id_counter")


# =============================================================================
# §4 — ProducerEntry — decoded registry body.
# =============================================================================


@fieldwise_init
struct ProducerEntry(Copyable, Movable, Deinitable):
    """One decoded producer-registry entry.

    Field layout:
      var producer_id: Int64    — the allocated producer id.
      var epoch: Int64          — the STRICTLY-MONOTONIC current epoch.
      var etag: String          — the registry object's etag (for the next
                                  `If-Match` CAS bump); empty if not read with
                                  a head.

    POD-ish (Int64 + one owned String). Not a byte-slab element.
    """

    var producer_id: Int64
    var epoch: Int64
    var etag: String

    def encode(self) -> List[UInt8]:
        """Encode the body (producer_id + epoch). The etag is NOT in the body
        — it is the object's server-assigned version, read separately."""
        var out = List[UInt8]()
        _pr_put_i64_le(out, self.producer_id)
        _pr_put_i64_le(out, self.epoch)
        return out^

    @staticmethod
    def decode(bytes: List[UInt8], etag: String) raises -> ProducerEntry:
        var producer_id = _pr_get_i64_le(bytes, 0)
        var epoch = _pr_get_i64_le(bytes, 8)
        return ProducerEntry(producer_id, epoch, etag)


# =============================================================================
# §5 — ProducerRegistry[Store] — the monotonic-epoch fence.
# =============================================================================


struct ProducerRegistry[Store: ConditionalWriteStore](
    Movable, Deinitable
):
    """The idempotent-producer registry over any `ConditionalWriteStore`.

    Owns its backend `Store` by value + the cluster prefix. `init_producer_id`
    allocates a producer_id + a monotonic epoch (the InitProducerId RPC
    backend); `registered_epoch` reads the current epoch (the produce-path
    fence). The epoch is persisted in S3 and advanced via If-Match CAS, so the
    fence is durable + shared across brokers (pure-S3 EOS, no in-memory
    coordinator).

    Fields:
      var _store: Store     — the backend (S3 / in-memory).
      var _cluster: String  — the cluster prefix (`<cluster>/_meta/producers`).
    """

    var _store: Self.Store
    var _cluster: String

    def __init__(out self, var store: Self.Store, var cluster: String):
        self._store = store^
        self._cluster = cluster^

    @always_inline
    def cluster(self) -> String:
        return self._cluster

    # ---- producer-id allocation (monotone counter, CAS-advanced) ----

    def _alloc_producer_id(mut self) raises -> Int64:
        """Allocate the next producer_id from the monotone counter object via
        an If-Match CAS (create-if-absent on the first allocation). Retries on
        a 412 (another broker won the slot)."""
        var ck = producer_id_counter_key(self._cluster)
        var attempt = 0
        while True:
            attempt += 1
            var current = Int64(-1)
            var etag = String("")
            var present = True
            try:
                var raw = self._store.get(ck)
                var meta = self._store.head(ck)
                current = _pr_get_i64_le(raw, 0)
                etag = String(meta.etag)
            except e:
                if _pr_is_not_found(String(e)):
                    present = False
                else:
                    raise e^
            var next_id = current + Int64(1)
            var body = List[UInt8]()
            _pr_put_i64_le(body, next_id)
            try:
                if present:
                    _ = self._store.conditional_put(
                        ck, body^, WritePrecondition.if_match(etag)
                    )
                else:
                    _ = self._store.conditional_put(
                        ck, body^, WritePrecondition.if_none_match_star()
                    )
                return next_id
            except e2:
                if not _pr_is_precondition(String(e2)):
                    raise e2^
                if attempt > 64:
                    raise Error(
                        "ProducerRegistry._alloc_producer_id: exhausted 64"
                        " CAS retries under contention (retryable)"
                    )
                # Lost the CAS — re-read + retry.
                continue

    # ---- InitProducerId (the RPC backend) ----

    def init_producer_id(mut self) raises -> ProducerEntry:
        """Allocate a NEW producer_id with epoch 0 (a fresh idempotent
        producer). Equivalent to InitProducerId with no transactional-id.
        Returns the entry with the freshly-created etag."""
        var pid = self._alloc_producer_id()
        var entry = ProducerEntry(pid, Int64(0), String(""))
        var pk = producer_key(self._cluster, pid)
        # CREATE the registry object via If-None-Match (a fresh pid never
        # collides; if it somehow does, that is a corrupt counter — fail loud).
        var meta = self._store.conditional_put(
            pk, entry.encode(), WritePrecondition.if_none_match_star()
        )
        return ProducerEntry(pid, Int64(0), String(meta.etag))

    def bump_epoch(mut self, producer_id: Int64) raises -> ProducerEntry:
        """Bump the epoch of an EXISTING producer (re-InitProducerId for the
        same producer_id — fences the prior incarnation). STRICTLY monotonic
        via If-Match CAS: `new_epoch = old_epoch + 1`, never reset, never
        recycled. A concurrent bump race resolves to one winner; the loser
        re-reads (seeing the winner's higher epoch) and bumps AGAIN, so its
        epoch is strictly higher. Retries on a 412."""
        var pk = producer_key(self._cluster, producer_id)
        var attempt = 0
        while True:
            attempt += 1
            var raw = self._store.get(pk)
            var meta = self._store.head(pk)
            var cur = ProducerEntry.decode(raw, String(meta.etag))
            var bumped = ProducerEntry(
                producer_id, cur.epoch + Int64(1), String("")
            )
            try:
                var nm = self._store.conditional_put(
                    pk, bumped.encode(), WritePrecondition.if_match(cur.etag)
                )
                return ProducerEntry(
                    producer_id, cur.epoch + Int64(1), String(nm.etag)
                )
            except e:
                if not _pr_is_precondition(String(e)):
                    raise e^
                if attempt > 64:
                    raise Error(
                        "ProducerRegistry.bump_epoch: exhausted 64 CAS"
                        " retries under contention (retryable)"
                    )
                continue

    # ---- the produce-path fence read ----

    def registered_epoch(self, producer_id: Int64) raises -> Int64:
        """The current registered epoch for `producer_id`, or -1 if the
        producer was never registered (an InitProducerId is required before
        idempotent produce). The produce path fences a produce whose epoch is
        below this value (a zombie)."""
        var pk = producer_key(self._cluster, producer_id)
        try:
            var raw = self._store.get(pk)
            var e = ProducerEntry.decode(raw, String(""))
            return e.epoch
        except err:
            if _pr_is_not_found(String(err)):
                return Int64(-1)
            raise err^

    def read_entry(self, producer_id: Int64) raises -> ProducerEntry:
        """Read the full registry entry (with etag) for `producer_id`. Raises
        not_found if the producer was never registered."""
        var pk = producer_key(self._cluster, producer_id)
        var raw = self._store.get(pk)
        var meta = self._store.head(pk)
        return ProducerEntry.decode(raw, String(meta.etag))
