# =============================================================================
# flight_broker_data.mojo: the Flight broker data plane.
# =============================================================================
#
# The server-side holder that drives the broker cores for the Flight DoGet /
# DoPut / GetFlightInfo handlers. It is Arrow-native: Flight payloads are
# Arrow RecordBatches, so there is no protocol envelope to bridge. The
# RecordBatch flows straight into `BrokerCore.produce` (DoPut) and back out of
# `ConsumeCore` (DoGet) with no transcode.
#
# It owns a clone-shared in-memory `ConditionalWriteStore` and one persistent
# `BrokerCore` per partition per topic (the write buffer must survive across
# produce calls until a flush), and keeps one `ConsumeCore` per partition for
# DoGet.
#
# The cores stay free of Flight vocabulary: this holder bridges the Flight wire
# and RecordBatch above them.
#
# Each topic holds `cores: Slab[BrokerCore]` and `consume_cores:
# Slab[ConsumeCore]`, one produce and one consume core per partition, built in
# a loop by `add_topic`. `produce`, `read_batches` and `high_watermark` take a
# `partition` argument, bounds-checked against `num_partitions` and routed
# through `_topics[idx].cores[partition]`. Each partition's cores `.clone()` the
# shared store and bind a partition-distinct manifest prefix, so partitions are
# disjoint keyspaces in one store.
#
# `add_topic(name)` defaults to 1 partition and `produce`, `read_batches` and
# `high_watermark` default to partition 0, so a single-partition topic needs no
# partition argument anywhere.
#
# No pointer type appears in any signature. The store is owned by value (it
# keeps its ArcPointer internals to itself); the per-topic brokers live in a
# `Slab[_FlightTopic]` and each topic's per-partition cores in
# `Slab[BrokerCore]` / `Slab[ConsumeCore]`. BrokerCore and ConsumeCore are
# Movable-only, so a `List` of them would fail `T: Copyable`, and a Slab does
# not store them in a byte slab behind a wildcard origin.
# =============================================================================

from komira_broker.broker_core import (
    BrokerCore,
    ProduceResult,
    _manifest_prefix,
)
from komira_broker.consume_core import ConsumeCore, ConsumeSegment

from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)

from komira_op_sources.arrow_stream_reader import decode_arrow_ipc_stream


comptime _Store = SharedInMemoryConditionalStore

# The ceiling on `add_topic`'s per-partition core construction. Deliberately one
# above `flight_service.MAX_TOPIC_PARTITIONS` (1024), because the DoPut
# auto-registration asks for `put_partition + 1` partitions to make the supplied
# INDEX legal, so the largest legitimate request this module can receive from
# that path is exactly 1025.
comptime MAX_ADD_TOPIC_PARTITIONS: Int = 1025


# =============================================================================
# _FlightTopic — one topic's per-partition broker cores + its registered schema.
# =============================================================================


struct _FlightTopic(Movable, Deinitable):
    """One Flight topic: `num_partitions` produce cores + `num_partitions`
    consume cores (one each per partition, the read dual), and the topic's Arrow
    schema (established by the first DoPut, surfaced by GetFlightInfo).

    The per-partition cores live in `Slab[BrokerCore]` / `Slab[ConsumeCore]`
    (the Movable-only container: BrokerCore / ConsumeCore are not Copyable, so
    a `List` would fail `T: Copyable`). Partition `p` routes to `cores[p]` /
    `consume_cores[p]`."""

    var name: String
    var num_partitions: Int
    var cores: Slab[BrokerCore[_Store]]
    var consume_cores: Slab[ConsumeCore[_Store]]
    var schema: Schema
    var has_schema: Bool

    def __init__(
        out self,
        var name: String,
        num_partitions: Int,
        var cores: Slab[BrokerCore[_Store]],
        var consume_cores: Slab[ConsumeCore[_Store]],
    ):
        self.name = name^
        self.num_partitions = num_partitions
        self.cores = cores^
        self.consume_cores = consume_cores^
        self.schema = Schema()
        self.has_schema = False


# =============================================================================
# FlightBrokerData — N topics, each an Arrow-native N-partition broker.
# =============================================================================


struct FlightBrokerData(Movable, Deinitable):
    """The Arrow-native Flight data plane: one `_FlightTopic` per registered
    topic, looked up by name. Each topic fans out to `num_partitions` produce +
    consume cores."""

    var _store: _Store
    var _cluster: String
    var _topics: Slab[_FlightTopic]

    def __init__(out self, var cluster: String) raises:
        self._store = _Store()
        self._cluster = cluster^
        self._topics = Slab[_FlightTopic]()

    def _index_of(imm self, name: String) -> Int:
        for i in range(len(self._topics)):
            if self._topics[i].name == name:
                return i
        return -1

    def has_topic(imm self, name: String) -> Bool:
        return self._index_of(name) >= 0

    def num_partitions(imm self, name: String) raises -> Int:
        """The partition count of a registered topic. Used by GetFlightInfo to
        fan out one FlightEndpoint per partition."""
        var idx = self._index_of(name)
        if idx < 0:
            raise Error(
                "FlightBrokerData.num_partitions: unknown topic '" + name + "'"
            )
        return self._topics[idx].num_partitions

    def add_topic(mut self, var name: String, num_partitions: Int = 1) raises:
        """Register a topic (idempotent). Builds ONE produce core + ONE consume
        core per partition. `num_partitions` defaults to 1 (the
        single-partition shape)."""
        if self._index_of(name) >= 0:
            return
        if num_partitions < 1:
            raise Error(
                "FlightBrokerData.add_topic: num_partitions must be >= 1 (got "
                + String(num_partitions)
                + ")"
            )
        # The upper bound. The loop below constructs a BrokerCore AND a
        # ConsumeCore per partition, each cloning the store and building a
        # CasManifestStore, so `num_partitions` is a work multiplier, and on
        # the Flight DoPut path it arrives from an unauthenticated
        # FlightDescriptor path segment. Checked here, at the site that does
        # the allocating, so every caller is covered and not just
        # `flight_service._do_put` (which also rejects it earlier, with a gRPC
        # INVALID_ARGUMENT, so a client sees a status rather than an internal
        # error).
        if num_partitions > MAX_ADD_TOPIC_PARTITIONS:
            raise Error(
                "FlightBrokerData.add_topic: num_partitions "
                + String(num_partitions)
                + " exceeds the maximum of "
                + String(MAX_ADD_TOPIC_PARTITIONS)
                + " (each partition costs one produce core + one consume core)"
            )
        # One persistent produce core + one persistent consume core per
        # partition (each shares the store via clone, bound to a
        # partition-distinct manifest prefix: disjoint keyspaces in one store).
        var cores = Slab[BrokerCore[_Store]]()
        var consume_cores = Slab[ConsumeCore[_Store]]()
        for p in range(num_partitions):
            cores.append(self._make_broker_core(name, Int64(p)))
            consume_cores.append(self._make_consume_core(name, Int64(p)))
        self._topics.append(
            _FlightTopic(name^, num_partitions, cores^, consume_cores^)
        )

    def _make_broker_core(
        self, name: String, partition: Int64
    ) raises -> BrokerCore[_Store]:
        var seg_store = self._store.clone()
        var manifest_store = self._store.clone()
        var prefix = _manifest_prefix(self._cluster, name, partition)
        var manifest = CasManifestStore[_Store](
            store=manifest_store^,
            prefix=prefix^,
            retry=RetryPolicy.fast_test(),
        )
        return BrokerCore[_Store](
            segment_store=seg_store^,
            manifest=manifest^,
            cluster=self._cluster.copy(),
            topic=name.copy(),
            partition=partition,
            broker_id=String("flight-broker"),
        )

    def _make_consume_core(
        self, name: String, partition: Int64
    ) raises -> ConsumeCore[_Store]:
        var seg_store = self._store.clone()
        var manifest_store = self._store.clone()
        var prefix = _manifest_prefix(self._cluster, name, partition)
        var manifest = CasManifestStore[_Store](
            store=manifest_store^,
            prefix=prefix^,
            retry=RetryPolicy.fast_test(),
        )
        return ConsumeCore[_Store](
            segment_store=seg_store^,
            manifest=manifest^,
            cluster=self._cluster.copy(),
            topic=name.copy(),
            partition=partition,
        )

    def _check_partition(imm self, idx: Int, partition: Int) raises:
        """Bounds-check `partition` against the topic's partition count:
        `partition < 0 or partition >= num_partitions` raises."""
        var np = self._topics[idx].num_partitions
        if partition < 0 or partition >= np:
            raise Error(
                "FlightBrokerData: partition "
                + String(partition)
                + " out of range [0, "
                + String(np)
                + ")"
            )

    # -------------------------------------------------------------------------
    # SCHEMA: establish (from the DoPut schema message) + surface (GetFlightInfo).
    # -------------------------------------------------------------------------

    def set_schema(mut self, name: String, var schema: Schema) raises:
        """Record the topic's Arrow schema (from the first DoPut FlightData /
        the schema message). Topic-level (not per-partition — every partition of
        a topic shares one Arrow schema)."""
        var idx = self._index_of(name)
        if idx < 0:
            raise Error("FlightBrokerData.set_schema: unknown topic '" + name + "'")
        self._topics[idx].schema = schema^
        self._topics[idx].has_schema = True

    def has_schema(imm self, name: String) -> Bool:
        var idx = self._index_of(name)
        if idx < 0:
            return False
        return self._topics[idx].has_schema

    def schema_copy(imm self, name: String) raises -> Schema:
        var idx = self._index_of(name)
        if idx < 0:
            raise Error("FlightBrokerData.schema_copy: unknown topic '" + name + "'")
        if not self._topics[idx].has_schema:
            raise Error(
                "FlightBrokerData.schema_copy: topic '" + name
                + "' has no schema yet (no DoPut has landed)"
            )
        return self._topics[idx].schema.copy()

    # -------------------------------------------------------------------------
    # PRODUCE (DoPut) — RecordBatch -> BrokerCore.produce + immediate flush.
    # -------------------------------------------------------------------------

    def produce(
        mut self, name: String, partition: Int, var batch: RecordBatch, now_ms: Int64
    ) raises -> Int64:
        """Produce one RecordBatch to the topic's `partition` + FORCE a flush so
        the records are durable before we ack (Flight do_put returns when the
        server has the data). Returns the committed base offset of the flushed
        segment. `partition` is bounds-checked against the topic's partition
        count and routes to `cores[partition]`."""
        var idx = self._index_of(name)
        if idx < 0:
            raise Error("FlightBrokerData.produce: unknown topic '" + name + "'")
        self._check_partition(idx, partition)
        # `produce` flushes by itself when the batch reaches the size trigger.
        # That flush is the acknowledgement; forcing another would find an
        # empty buffer and report no result for a write that is already durable.
        var flushed = self._topics[idx].cores[partition].produce(batch^, now_ms)
        if not flushed:
            flushed = self._topics[idx].cores[partition].flush_if_buffered(now_ms)
        if not flushed:
            raise Error(
                "FlightBrokerData.produce: flush produced no result"
            )
        return flushed.value().base_offset

    # -------------------------------------------------------------------------
    # CONSUME (DoGet) — ConsumeCore.read_from(offset) -> RecordBatch list.
    # -------------------------------------------------------------------------

    def read_batches(
        mut self, name: String, partition: Int, start_offset: Int64
    ) raises -> Slab[RecordBatch]:
        """Read all RecordBatches at/after `start_offset` from the topic's
        `partition`. Each segment's Arrow-IPC stream is decoded back to a
        RecordBatch (zero transcode — the broker stores Arrow-IPC, DoGet ships
        Arrow). Segments straddling the start are returned whole (reads are
        per segment; row-level offset trimming is not done, and DoGet from
        offset 0 is the common case). `partition` routes to
        `consume_cores[partition]`."""
        var idx = self._index_of(name)
        if idx < 0:
            raise Error("FlightBrokerData.read_batches: unknown topic '" + name + "'")
        self._check_partition(idx, partition)
        var segments = self._topics[idx].consume_cores[partition].read_from(
            start_offset
        )
        var out = Slab[RecordBatch]()
        for i in range(len(segments)):
            ref seg = segments[i]
            var stream = seg.stream_bytes.copy()
            var batch = decode_arrow_ipc_stream(stream^)
            out.append(batch^)
        _ = segments^
        return out^

    def high_watermark(mut self, name: String, partition: Int) raises -> Int64:
        """The next offset that will be produced to the topic's `partition`
        (== count of committed records in that partition). The FlightInfo
        total_records upper bound (summed across partitions by the caller, or
        per-partition for a per-partition endpoint)."""
        var idx = self._index_of(name)
        if idx < 0:
            raise Error("FlightBrokerData.high_watermark: unknown topic '" + name + "'")
        self._check_partition(idx, partition)
        return self._topics[idx].consume_cores[partition].next_offset()
