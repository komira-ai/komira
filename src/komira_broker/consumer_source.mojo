# =============================================================================
# komira_broker/consumer_source.mojo
#   MessageBrokerConsumer: the native Arrow Source edge (consume side)
# =============================================================================
#
# The READ-side edge over the concrete `ConsumeCore`.
# `MessageBrokerConsumer` is the in-pipeline Source: it reads the manifest +
# segments directly from the object store (via `ConsumeCore`) and yields
# `RecordBatch`es.
#
# NATIVE ARROW ONLY. The native broker source/sink path has no `[Format]` type
# parameter. Arrow is the internal substrate; a native pipeline produces /
# consumes RecordBatches, never a "Kafka-format" record on the native side.
# The Kafka wire convention lives entirely at the server-side compatibility
# shim (`komira_kafka_server`), which transcodes Kafka <-> the envelope
# RecordBatch at RUNTIME (api_key dispatch). This locks in "Arrow is the
# internal substrate; Kafka is a server-side skin" structurally: the native
# cores + edges monomorphize ONLY over `Storage`.
#
# -----------------------------------------------------------------------------
# SCOPE + the build-DAG constraint + the Copyable wall
# -----------------------------------------------------------------------------
#
# A pipeline source conforms to TWO traits:
#   (1) `SourceLike`        (the core packages) — plan-side identity:
#       schema / estimate_rows / fingerprint / supports_filter_pushdown.
#   (2) `MorselSourceImpl`  (komira_morsel) — runtime `next_morsel`.
#
# THE COPYABLE WALL (why neither conformance lives on this struct):
# `SourceLike` (and `MorselSourceImpl`) require `Copyable`. The consumer holds
# `ConsumeCore[Storage]` BY VALUE, and `ConsumeCore` is Movable-ONLY — it owns
# a `CasManifestStore[Storage]` (Movable-only) + a network-backed `Storage`.
# Making the consumer Copyable would force a `ConsumeCore.copy()` that
# DUPLICATES a network store handle on every plan-cache copy — semantically
# wrong, and the substrate is not Copyable. The clean resolution is a Copyable
# backend HANDLE in the SDK plan-cache layer (a cheap identity token the plan
# builder copies, the heavy network substrate constructed at execute time).
# So:
#
# `MessageBrokerConsumer[Storage]` is the CONCRETE consume EDGE — a thin
# Movable driver over `ConsumeCore` that provides the plan-side identity
# methods (schema / estimate_rows / fingerprint, matching the SourceLike
# SHAPE) + the consume drain driver — but does NOT carry the `SourceLike` /
# `MorselSourceImpl` trait BOUND (the Copyable contract). The SDK wraps this
# edge in a Copyable SourceVariant adapter, where the
# `decode_arrow_ipc_stream` + `BatchMorselSource` deps already live (placing
# them here would invert the build DAG: broker -> {core, objectstore, async,
# obs} only — exactly why `ArrowSource.to_dataframe` lives in the SDK and NOT
# on the core packages source struct).
#
# The consume loop drives `ConsumeCore` directly via this edge's
# `drain_streams()` — byte-faithful, mid-offset, and tail.
#
# -----------------------------------------------------------------------------
# Arrow is the native record convention — no `Format` axis.
# -----------------------------------------------------------------------------
#
# Storage is always Arrow-IPC and the native record convention IS Arrow: the
# stored records ARE RecordBatches, consume = zero transcode. There is no
# comptime record-convention axis on the native path. The Kafka
# (key,value,headers,ts) <-> RecordBatch mapping lives at the server shim
# (`komira_kafka_server`), dispatched at RUNTIME by api_key — never as a native
# comptime `Format` param. So the former `BrokerFormat` trait + `Arrow` /
# `KafkaStub` marker conformers have been RETIRED; the native edge is
# Arrow-only and monomorphizes over `Storage` alone.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any public signature.
#   * ZERO wildcard origins / `unsafe_from_address`.
#   * `_core: ConsumeCore[Storage]` held BY VALUE (encapsulates its own
#     substrate). The consumer is a stack value, not a byte-slab element.
# =============================================================================

from komira_arrow.schema import Schema
from komira_collections.slab import Slab
from komira_plan_expr.expr import Expr

from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.store import ConditionalWriteStore

from .consume_core import ConsumeCore, ConsumeSegment


# =============================================================================
# FNV-1a hash helpers — local copy (mirrors arrow_source.mojo; avoids a
# the core packages dep for the fingerprint).
# =============================================================================


@always_inline
def _consumer_fnv1a_offset_basis() -> UInt64:
    return UInt64(14695981039346656037)


@always_inline
def _consumer_fnv1a_prime() -> UInt64:
    return UInt64(1099511628211)


def _consumer_hash_string(s: String) -> UInt64:
    var h: UInt64 = _consumer_fnv1a_offset_basis()
    var prime: UInt64 = _consumer_fnv1a_prime()
    var b = s.as_bytes()
    for i in range(len(b)):
        h = (h ^ UInt64(b[i])) * prime
    return h


def _consumer_hash_combine(a: UInt64, b: UInt64) -> UInt64:
    return (a ^ b) * _consumer_fnv1a_prime()


# =============================================================================
# MessageBrokerConsumer — the native Arrow Source edge (SourceLike conformance).
# =============================================================================


struct MessageBrokerConsumer[Storage: ConditionalWriteStore](
    Movable, Deinitable
):
    """The in-pipeline broker Source EDGE over `ConsumeCore` (read
    edge). Provides the plan-side identity methods (schema / estimate_rows /
    fingerprint, matching the `SourceLike` SHAPE) + the consume drain driver.

    Does NOT carry the `SourceLike` / `MorselSourceImpl` trait bound (the
    Copyable contract) — see the module header's COPYABLE WALL. The SDK
    wraps this edge in a Copyable SourceVariant adapter.

    `[Partition]` = RUNTIME: partition is a `_partition: Int64`
    field, NOT a type param. The ONLY type param is `Storage` (the backend
    selector) — the native edge is Arrow-only (no `Format` axis).

    Ownership:
      * `_core: ConsumeCore[Storage]` — owned by value (encapsulates the
        segment store + the manifest index). The consume driver.
      * `_topic` / `_partition` / `_cluster` / `_start_offset` — the runtime
        binding (the identity coordinates).
      * `_schema_cached` — the topic's resolved Arrow schema (for the plan-
        side `schema()`); cached at construction (the caller supplies it,
        having read the first segment's IPC Schema message, or it is filled
        lazily via `resolve_schema`).

    Fields:
      var _core: ConsumeCore[Storage]
      var _cluster: String
      var _topic: String
      var _partition: Int64
      var _start_offset: Int64
      var _schema_cached: Schema
      var _estimated_rows: Int
    """

    var _core: ConsumeCore[Self.Storage]
    var _cluster: String
    var _topic: String
    var _partition: Int64
    var _start_offset: Int64
    var _schema_cached: Schema
    var _estimated_rows: Int

    def __init__(
        out self,
        var core: ConsumeCore[Self.Storage],
        var cluster: String,
        var topic: String,
        partition: Int64,
        start_offset: Int64,
        var schema: Schema = Schema(),
        estimated_rows: Int = -1,
    ):
        """Construct a broker consumer Source.

        `core` is the read-side `ConsumeCore` (already bound to the partition's
        manifest prefix + segment store). `start_offset` is the offset to begin
        the read from (0 = full sequential drain). `schema` is the topic's
        resolved Arrow schema for the plan side; if empty, call
        `resolve_schema` before plan build to fill it from the first segment.
        """
        self._core = core^
        self._cluster = cluster^
        self._topic = topic^
        self._partition = partition
        self._start_offset = start_offset
        self._schema_cached = schema^
        self._estimated_rows = estimated_rows

    # =========================================================================
    # Plan-side identity methods (the SourceLike SHAPE; trait bound deferred)
    # =========================================================================

    def schema(self) -> Schema:
        """The topic's resolved Arrow schema (cached). This is the stored native
        schema (read from the first segment's IPC Schema message). Eager: a pure
        copy of cached state, no I/O."""
        return self._schema_cached.copy()

    def estimate_rows(self) -> Int:
        """Row-count hint: `next_offset - start_offset` if known, else -1.
        The caller fills `_estimated_rows` via `resolve_estimate` (a cheap
        manifest-head read) before plan build; -1 = unknown is valid."""
        return self._estimated_rows

    def fingerprint(self) -> UInt64:
        """Stable identity hash over (cluster, topic, partition, start_offset).
        CSE-COLLISION CLASS: MUST be unique per
        (topic, partition, start_offset) so two consumers of different
        topics/offsets never collide in the plan cache / CSE structural hash
        (the documented 'structural-hash collision -> silently wrong' class).
        The native edge is Arrow-only, so there is no `Format` term to fold.
        """
        var h = _consumer_hash_string(self._cluster)
        h = _consumer_hash_combine(h, _consumer_hash_string(self._topic))
        h = _consumer_hash_combine(h, UInt64(self._partition))
        h = _consumer_hash_combine(h, UInt64(self._start_offset))
        return h

    def supports_filter_pushdown(self, predicate: Expr) -> Bool:
        """No decode-time pruning for a broker segment stream (no zonemap /
        dictionary-filter at the segment level). Predicates stay as `Filter`
        nodes above the scan. Default-safe `False`."""
        return False

    # =========================================================================
    # Consume driver — drives ConsumeCore directly (the read loop).
    # =========================================================================

    def resolve_estimate(mut self) raises:
        """Fill `_estimated_rows` from a cheap manifest-head read:
        `next_offset - start_offset`. Call before plan build."""
        var next_off = self._core.next_offset()
        var est = next_off - self._start_offset
        self._estimated_rows = Int(est) if est >= Int64(0) else 0

    def drain_streams(mut self) raises -> Slab[ConsumeSegment]:
        """Drive `ConsumeCore.read_from(start_offset)` — resolve the manifest
        index, find the covering segments, GET + footer-slice each one, and
        return the ordered `ConsumeSegment`s (Arrow-IPC stream bytes + offset
        range), in produce order.

        The CALLER decodes each `ConsumeSegment.stream_bytes` with
        `decode_arrow_ipc_stream` (the SDK-side edge / the round-trip test) —
        the broker library stays SDK-agnostic.

        Sequential drain (`start_offset == 0`) returns all segments; a
        mid-offset read returns the covering suffix (the first segment may
        straddle `start_offset` — the caller skips leading rows < start).
        """
        return self._core.read_from(self._start_offset)

    def poll_tail(mut self, drained_chunks: Int64) raises -> Slab[ConsumeSegment]:
        """TAIL / live-consume mode: a consumer that has already drained the
        first `drained_chunks` manifest chunks re-polls for new ones. Returns
        the segments for chunks `[drained_chunks, num_chunks)` — the new tail
        appended since the last drain. Empty slab = no new segments yet.
        `drained_chunks` counts manifest chunks, not segments: a chunk that
        owns no segment (a txn COMMIT/ABORT marker) yields no entry, so the
        caller resumes after the last returned `chunk_seq` (or the polled
        chunk count), never after `len(result)`.

        `Slab[ConsumeSegment]` (Movable-only container) — see `drain_streams`.
        Read-only re-poll: no CAS contention (the gate does not bind consume).
        """
        var total = self._core.num_chunks()
        var out = Slab[ConsumeSegment]()
        var seq = drained_chunks
        while seq < total:
            var seg = self._core.read_chunk_segment(seq)
            if seg:
                out.append(seg.take())
            seq += Int64(1)
        return out^

    @always_inline
    def start_offset(self) -> Int64:
        return self._start_offset

    @always_inline
    def topic(self) -> String:
        return self._topic
