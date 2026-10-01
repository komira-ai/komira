# =============================================================================
# komira_broker/txn_registry.mojo
#   The transactional-id -> producer_id binding (Kafka KIP-98 semantics).
# =============================================================================
#
# A transactional producer sends `InitProducerId` with its `transactional.id`.
# Unlike a plain idempotent producer (every InitProducerId allocates a
# FRESH producer_id), a transactional producer with the SAME `transactional.id`
# across restarts must reuse the SAME producer_id and BUMP the same monotonic
# epoch — that epoch bump is what FENCES the prior incarnation (a zombie from a
# crashed/partitioned old instance fails its produce/commit epoch check).
#
# This binding object stores the mapping:
#
#   <cluster>/_meta/txn-id/<transactional-id>.bind   ← body = producer_id (i64 LE)
#
# Created (If-None-Match) on the FIRST InitProducerId for a transactional-id;
# re-read on every subsequent InitProducerId for the same id (the producer_id
# is stable). The EPOCH is NOT stored here — it lives in the producer
# registry object (`<cluster>/_meta/producers/<pid>.json`), bumped via
# `ProducerRegistry.bump_epoch` (strictly monotonic). This object is the
# id->pid indirection; the registry is the epoch authority. Keeping them
# separate reuses the idempotent-producer monotonic-epoch fence verbatim for the txn case.
#
# Encapsulation: generic over `ConditionalWriteStore`; ZERO UnsafePointer in
# any signature; the body is a single i64. POD-ish (Int64 + one owned String
# etag); a stack value, NEVER a byte-slab element. A komira_broker
# LEAF (objectstore-only dep).
# =============================================================================

from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore
from komira_objectstore.types import WritePrecondition


@always_inline
def _tr_put_i64_le(mut out: List[UInt8], v: Int64):
    var u = UInt64(v)
    for i in range(8):
        out.append(UInt8(Int((u >> UInt64(8 * i)) & UInt64(0xFF))))


@always_inline
def _tr_get_i64_le(bytes: List[UInt8], off: Int) raises -> Int64:
    if off + 8 > len(bytes):
        raise Error("txn_registry: truncated i64 at " + String(off))
    var u = UInt64(0)
    for i in range(8):
        u |= UInt64(Int(bytes[off + i])) << UInt64(8 * i)
    return Int64(u)


@always_inline
def _tr_is_not_found(msg: String) -> Bool:
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )


@always_inline
def _tr_is_precondition(msg: String) -> Bool:
    return (
        msg.find("precondition") >= 0
        or msg.find("Precondition") >= 0
        or msg.find("412") >= 0
        or msg.find("PreconditionFailed") >= 0
    )


def txn_id_bind_key(cluster: String, transactional_id: String) raises -> Path:
    """The transactional-id -> producer_id binding object key."""
    return Path.parse(
        cluster + "/_meta/txn-id/" + transactional_id + ".bind"
    )


def txn_pid_reverse_key(cluster: String, producer_id: Int64) raises -> Path:
    """The producer_id -> transactional-id REVERSE binding key. Lets the Produce
    path (which carries only the producer_id, never the transactional-id) tag a
    transactional chunk with its txn_id for the read_committed filter."""
    return Path.parse(
        cluster + "/_meta/txn-pid/" + String(producer_id) + ".bind"
    )


struct TxnIdRegistry[Store: ConditionalWriteStore](
    Movable, Deinitable
):
    """The transactional-id -> producer_id binding registry.

    `bind_or_read` is the only operation: given a transactional-id and a
    freshly-allocated candidate producer_id, atomically CREATE the binding (and
    return the candidate) OR read back the existing binding (and return the
    stable producer_id, discarding the candidate). The caller then bumps the
    epoch on the returned (stable) producer_id via the idempotent-producer ProducerRegistry.

    Fields:
      var _store: Store
      var _cluster: String"""

    var _store: Self.Store
    var _cluster: String

    def __init__(out self, var store: Self.Store, var cluster: String):
        self._store = store^
        self._cluster = cluster^

    def lookup(self, transactional_id: String) raises -> Int64:
        """The bound producer_id for `transactional_id`, or -1 if no binding
        exists yet (a never-seen transactional producer)."""
        var key = txn_id_bind_key(self._cluster, transactional_id)
        try:
            var raw = self._store.get(key)
            return _tr_get_i64_le(raw, 0)
        except e:
            if _tr_is_not_found(String(e)):
                return Int64(-1)
            raise e^

    def bind_or_read(
        mut self, transactional_id: String, candidate_producer_id: Int64
    ) raises -> Int64:
        """Atomically bind `transactional_id -> candidate_producer_id` via an
        `If-None-Match` CREATE, returning `candidate_producer_id` if this caller
        won the create. If the binding already exists (this caller lost the race
        OR the producer is restarting), read it back and return the STABLE
        bound producer_id (the candidate is discarded — the caller should not
        leak it; producer-id allocation is cheap and monotone). This makes a
        re-`InitProducerId` for the same transactional-id reuse the same
        producer_id across restarts, which is what the monotonic epoch fence
        binds to."""
        var key = txn_id_bind_key(self._cluster, transactional_id)
        var body = List[UInt8]()
        _tr_put_i64_le(body, candidate_producer_id)
        try:
            _ = self._store.conditional_put(
                key, body^, WritePrecondition.if_none_match_star()
            )
            self._write_reverse(candidate_producer_id, transactional_id)
            return candidate_producer_id
        except e:
            if not _tr_is_precondition(String(e)):
                raise e^
            # Lost the create / already bound — read back the stable id.
            var existing = self.lookup(transactional_id)
            if existing < Int64(0):
                # Raced create then deleted? Extremely unlikely; surface.
                raise Error(
                    "TxnIdRegistry.bind_or_read: binding for '"
                    + transactional_id
                    + "' vanished after a precondition failure"
                )
            # Refresh the reverse binding too (idempotent, stable mapping).
            self._write_reverse(existing, transactional_id)
            return existing

    def _write_reverse(
        mut self, producer_id: Int64, transactional_id: String
    ) raises:
        """Persist the producer_id -> transactional_id reverse binding
        (last-writer-wins; the mapping is stable so this is idempotent)."""
        var rkey = txn_pid_reverse_key(self._cluster, producer_id)
        var rbody = transactional_id.as_bytes()
        var out = List[UInt8]()
        for i in range(len(rbody)):
            out.append(rbody[i])
        _ = self._store.put(rkey, out)

    def reverse_lookup(self, producer_id: Int64) raises -> String:
        """The transactional-id bound to `producer_id`, or "" if none. The
        Produce path uses this to tag a transactional chunk with its txn_id
        (the wire Produce request carries only the producer_id)."""
        var rkey = txn_pid_reverse_key(self._cluster, producer_id)
        try:
            var raw = self._store.get(rkey)
            var s = String("")
            for i in range(len(raw)):
                s += chr(Int(raw[i]))
            return s^
        except e:
            if _tr_is_not_found(String(e)):
                return String("")
            raise e^
