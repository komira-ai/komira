# =============================================================================
# broker_scan_kind — the broker topic as an EXECUTABLE scan kind (tier 2).
# =============================================================================
#
# `broker_scan_binding.mojo` made a topic a plan SOURCE: a binding that can be
# built, typed, explained, cloned and cache-keyed without any broker type
# reaching core. This file makes it EXECUTABLE: `BrokerScanRuntime` conforms to
# `komira_scan_resolver`'s `ScanMorselResolver`, so the execution-time resolve
# pass can resolve a `komira.broker.topic` leaf's LIVE token and drain it into
# resident batches.
#
# ---------------------------------------------------------------------------
# WHAT ONE EXECUTION READS
# ---------------------------------------------------------------------------
#
# For every partition the binding names (ONE scan over the list, not one
# plan per partition; every row carries `__partition`):
#
#   upper   = the high-watermark (HWM). For a SINGLE-partition binding it is
#             the binding's own LIVE token, which `resolve_snapshot` set to
#             `ConsumeCore.next_offset()`, so the rows returned are exactly the
#             snapshot the caller was told about even if a produce lands in
#             between. ⚠ A MULTI-partition binding cannot name N watermarks in
#             one `UInt64` token: its token is the SUM of the partitions'
#             HWMs (monotone, so it still moves on every produce), and
#             `open_scan` reads each partition's HWM ONCE and REPORTS exactly
#             what it used in the side channel (`resolved`), which is the
#             authority a frontend reads. So a produce landing
#             between resolve and open IS returned, and `high_watermark.<p>`
#             says so. This is the one stated exception to `ScanRequest`'s
#             "must not re-resolve" (carved out on `ScanRequest` itself);
#             pinned by `test_broker_scan_kind_budget.mojo`
#             `test_multi_partition_reads_its_own_snapshot_and_reports_it`.
#   LSO     = the last stable offset: the base offset of the first chunk whose
#             transaction is still UNDECIDED (Ongoing / PrepareCommit /
#             PrepareAbort) in the PINNED transaction snapshot, else `upper`.
#   rows    = `read_uncommitted`: every data chunk below `upper`.
#             `read_committed`: every VISIBLE data chunk below `min(upper,
#             LSO)` — an aborted (or epoch-fenced) transaction's chunks are
#             removed and named in `aborted.<p>`.
#
# THE PINNED SNAPSHOT (read_committed.mojo). Transaction states are
# read ONCE per execution, across EVERY partition, before any partition is
# resolved — never per partition — so a commit flipping mid-scan cannot yield
# partition 0 committed and partition 1 not.
#
# THE LIVE TIER, INCLUDING LOG-COMPACTED CHUNKS. A LOG-COMPACTED chunk
# (`log_compaction.mojo`) keeps its manifest offset span but holds only
# survivor rows; its preserved absolute offsets are read off the chunk body's
# sidecar, so a start offset inside a compacted chunk skips exactly the
# survivors below it.
#
# ⛔ THE COMPACTED (PARQUET) TIER IS NOT READ, AND IS REFUSED BY NAME. The
# compacted tier (`compacted_index.mojo`, written by
# `komira_broker_compaction`) holds a prefix of the log as Parquet objects,
# and the compaction worker then ADVANCES the live `log_start` past that
# prefix. Clamping the start to `log_start` would silently return only the
# live suffix and report the moved `log_start` as if retention had deleted
# the prefix. So a scan whose range `[start, HWM)` reaches a compaction-index
# entry refuses with `BROKER_SCAN_COMPACTED_TIER_UNREAD`. Decoding that tier
# needs the parquet reader, which this leaf may not depend on: reading it is
# tracked follow-up work, and it is what the exit criterion "topic scan
# covers the live and compacted tiers" still needs.
#
# THE STORED BYTES ARE DECODED WITH THE TOPIC'S DURABLE SCHEMA. `open_scan`
# checks the binding's topic columns against the topic's durable config (what
# `build_binding` read) before decoding: name, Arrow type, nullability and
# decimal precision/scale per column, in order (the structural identity
# `komira_core/arrow/schema_identity.mojo` folds). A mismatch is refused with
# `BROKER_SCAN_SCHEMA_MISMATCH`. Past the check, every segment is decoded, and
# every output batch built, with the CONFIG's schema (plus `__partition`), not
# the binding's, so what the check does not compare (timezone, field metadata)
# is the topic's too: a stale plan-cached binding or one decoded off the wire
# never chooses how segment bytes are read.
#
# THE BYTE BUDGET. `max_bytes` (whole scan) and
# `partition_max_bytes` (each partition), measured in segment bytes. KIP-74:
# the FIRST segment the scan returns is returned whole even when it exceeds
# either budget, so a consumer can never be wedged behind one large batch.
# After it, a segment that would exceed the partition budget ends that
# partition, and one that would exceed the total ends the scan.
# `next_offset.<p>` reports where each partition stopped.
#
# ---------------------------------------------------------------------------
# SEGMENT DECODE WITHOUT THE ENGINE
# ---------------------------------------------------------------------------
#
# A segment is `Schema, RecordBatch*, EOS` written by `BrokerCore` with
# `komira_core`'s IPC encoder (no dictionary batches). The broker leaf may not
# import the engine's stream reader (`komira_engine_operators`), so this file
# decodes the RecordBatch frames with `komira_core`'s
# `decode_record_batch_message` against the topic config's schema (the
# binding's topic columns, CHECKED against that config first — see above) —
# schema-directed, the same shape the core decoder already has. A dictionary
# frame is refused by name.
#
# ---------------------------------------------------------------------------
# ENCAPSULATION
# ---------------------------------------------------------------------------
#
# No `UnsafePointer` anywhere in this file, no wildcard origin, no
# `unsafe_from_address`. `ConsumeCore` (Movable, heap-owning) is never stored
# in a container — gap6: one is constructed per partition per pass, on the
# stack, and dropped. The per-partition facts it yields are Copyable values.
# =============================================================================

from std.memory import ArcPointer

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.column import Column
from komira_core.arrow.ipc_decoder_dispatch import decode_record_batch_message
from komira_core.arrow.ipc_flatbuf import (
    flatbuf_reader_over,
    read_message,
    MESSAGE_HEADER_DICTIONARY_BATCH,
    MESSAGE_HEADER_RECORD_BATCH,
    MESSAGE_HEADER_SCHEMA,
)
from komira_core.arrow.primitive_array import PrimitiveArray
from komira_core.arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.arrow.shared_aligned_buffer import SharedAlignedBuffer
from komira_core.arrow_helpers.batch_slice import _slice_batch_range
from komira_core.collections.slab import Slab
from komira_core.io.heap_region import HeapRegion
from komira_core.source.scan_binding import ScanBinding, SCAN_EPOCH_NONE
from komira_core.source.scan_kind_registry import ScanKindDescriptor
from komira_core.source.scan_params import ScanParams

from komira_scan_resolver.scan_morsel_resolver import (
    ErasedScanMorselResolver,
    ScanMorselResolver,
    ScanOpened,
    ScanRequest,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from .broker_core import BrokerTopicConfig, _manifest_prefix, _topic_config_key
from .compacted_index import CompactionIndex
from .broker_scan_binding import (
    BROKER_ISOLATION_READ_COMMITTED,
    BROKER_PARAM_ISOLATION,
    BROKER_PARAM_MAX_BYTES,
    BROKER_PARAM_PARTITION_MAX_BYTES,
    BROKER_PARAM_PARTITIONS,
    BROKER_PARAM_START_OFFSET,
    BROKER_PARAM_START_OFFSETS,
    BROKER_PARAM_TOPIC,
    BROKER_PARTITION_COLUMN,
    BROKER_SCAN_BAD_PARAM,
    BROKER_SCAN_KIND_NAME,
    broker_join_i64,
    broker_parse_i64_list,
    broker_scan_descriptor,
    broker_scan_kind_id,
    broker_topic_binding,
)
from .consume_core import ChunkTagAt, ConsumeCore, SegmentRef
from .log_compaction import (
    decode_compacted_survivor_offsets,
    is_chunk_compacted,
)
from .read_committed import ChunkTxnTag, TxnSnapshot, chunk_is_visible
from .txn_control import (
    TxnControlStore,
    TXN_STATE_ONGOING,
    TXN_STATE_PREPARE_ABORT,
    TXN_STATE_PREPARE_COMMIT,
)


# =============================================================================
# The side channel's keys. Per partition: `<key>.<partition id>`.
# =============================================================================

comptime BROKER_RESOLVED_HIGH_WATERMARK: String = "high_watermark"
"""The exclusive upper bound this execution read below (read_uncommitted)."""
comptime BROKER_RESOLVED_LAST_STABLE_OFFSET: String = "last_stable_offset"
"""The first offset of the earliest undecided transaction, else the HWM."""
comptime BROKER_RESOLVED_LOG_START_OFFSET: String = "log_start_offset"
"""The first still-readable offset (retention)."""
comptime BROKER_RESOLVED_ABORTED: String = "aborted"
"""`txn_id@first_offset` for every aborted transaction below the bound,
`;`-joined, in offset order. Empty = none."""
comptime BROKER_RESOLVED_NEXT_OFFSET: String = "next_offset"
"""The first offset this execution did NOT return for the partition: where a
byte-budgeted fetch resumes."""

comptime BROKER_SCAN_NOT_EXECUTABLE_BINDING: StaticString = (
    "BROKER_SCAN_NOT_EXECUTABLE_BINDING"
)
"""NAMED ERROR — `open_scan` got a binding whose schema does not end in the
`__partition` INT64 column, i.e. one `build_binding` did not produce (the
plan-level convenience `broker_scan_binding` declares a caller's schema)."""

comptime BROKER_SCAN_COMPACTED_CHUNK_MISMATCH: StaticString = (
    "BROKER_SCAN_COMPACTED_CHUNK_MISMATCH"
)
"""NAMED ERROR — a log-compacted chunk whose `.seg` does not hold exactly one
row per survivor offset in its sidecar. The production cleaner
(`ProductionLogCleaner`) rewrites the `.seg` and the body together; a chunk
whose body was swapped without its segment cannot be numbered, so it is
refused rather than read with invented offsets."""

comptime BROKER_SCAN_COMPACTED_TIER_UNREAD: StaticString = (
    "BROKER_SCAN_COMPACTED_TIER_UNREAD"
)
"""NAMED ERROR — the requested range reaches offsets held in the COMPACTED
(Parquet) tier (`CompactionIndex`), which this kind does not read yet.
Refused rather than clamped to the live `log_start`,
which the compaction worker advanced past that prefix: a clamp would drop
the prefix with no error and report it as retention."""

comptime BROKER_SCAN_SCHEMA_MISMATCH: StaticString = (
    "BROKER_SCAN_SCHEMA_MISMATCH"
)
"""NAMED ERROR — the binding's topic columns (names or types) disagree with
the topic's durable config. The binding (plan-cached, or decoded off the
wire) is not the authority on how stored segment bytes decode; the config
is."""

comptime BROKER_SCAN_DICTIONARY_SEGMENT: StaticString = (
    "BROKER_SCAN_DICTIONARY_SEGMENT"
)
"""NAMED ERROR — a segment carried a DictionaryBatch frame. `BrokerCore` never
writes one; the schema-directed decoder refuses rather than mis-decode."""


def broker_resolved_key(key: String, partition: Int64) -> String:
    """`("high_watermark", 3)` -> `"high_watermark.3"`."""
    return key + String(".") + String(partition)


# =============================================================================
# The scan spec a binding carries, parsed once.
# =============================================================================


@fieldwise_init
struct _BrokerScanSpec(Copyable, Movable, Deinitable):
    var topic: String
    var partitions: List[Int64]
    var start_offsets: List[Int64]
    var read_committed: Bool
    var max_bytes: Int64
    var partition_max_bytes: Int64

    @staticmethod
    def from_binding(b: ScanBinding) raises -> _BrokerScanSpec:
        var parts = broker_parse_i64_list(
            b.params.get_str(String(BROKER_PARAM_PARTITIONS)),
            String(BROKER_PARAM_PARTITIONS),
        )
        if len(parts) == 0:
            raise Error(
                String(BROKER_SCAN_BAD_PARAM)
                + String(": binding '")
                + b.name
                + String("' names no partition")
            )
        var default_start = b.params.get_i64(
            String(BROKER_PARAM_START_OFFSET), Int64(0)
        )
        var starts = List[Int64]()
        if b.params.has(String(BROKER_PARAM_START_OFFSETS)):
            starts = broker_parse_i64_list(
                b.params.get_str(String(BROKER_PARAM_START_OFFSETS)),
                String(BROKER_PARAM_START_OFFSETS),
            )
            if len(starts) != len(parts):
                raise Error(
                    String(BROKER_SCAN_BAD_PARAM)
                    + String(": 'start_offsets' is not aligned with 'partitions'")
                )
        else:
            for _ in range(len(parts)):
                starts.append(default_start)
        return _BrokerScanSpec(
            topic=b.params.get_str(String(BROKER_PARAM_TOPIC)),
            partitions=parts^,
            start_offsets=starts^,
            read_committed=(
                b.params.get_str(String(BROKER_PARAM_ISOLATION))
                == String(BROKER_ISOLATION_READ_COMMITTED)
            ),
            max_bytes=b.params.get_i64(String(BROKER_PARAM_MAX_BYTES), Int64(-1)),
            partition_max_bytes=b.params.get_i64(
                String(BROKER_PARAM_PARTITION_MAX_BYTES), Int64(-1)
            ),
        )


@fieldwise_init
struct _PartitionFacts(Copyable, Movable, Deinitable):
    """What pass 1 learns about one partition. Copyable values only — the
    `ConsumeCore` that produced them is already gone (gap6)."""

    var partition: Int64
    var high_watermark: Int64
    var log_start_offset: Int64
    var index: List[SegmentRef]
    var tags: List[ChunkTagAt]


# =============================================================================
# BrokerScanRuntime
# =============================================================================


struct BrokerScanRuntime[Storage: CloneableConditionalWriteStore](
    ScanMorselResolver, Movable, Deinitable
):
    """`komira.broker.topic`, executable. Holds the cluster's store (a CLONE
    shares the underlying data, so every per-partition `ConsumeCore` it builds
    reads the same log) and the cluster name the topic prefixes hang off.

    THE OWNERSHIP RULE applies: this runtime must outlive every
    execution that resolves against it. It holds NO registry slots — its
    bindings are UNBOUND and their payload is produced per execution — so
    `epoch` is `SCAN_EPOCH_NONE` and `is_bound` is always False, and a binding
    carrying a handle is refused by core's `check_binding` by name.
    """

    var _store: Self.Storage
    var _cluster: String

    def __init__(out self, var store: Self.Storage, var cluster: String):
        self._store = store^
        self._cluster = cluster^

    # ---- tier 1 ---------------------------------------------------------------

    def epoch(self) -> UInt64:
        return SCAN_EPOCH_NONE

    def is_bound(self, kind_id: UInt32, handle: Int) -> Bool:
        return False

    def resolve_snapshot(self, binding: ScanBinding) raises -> UInt64:
        """The LIVE token: `ConsumeCore.next_offset()` (the high-watermark) of
        the one partition, or the SUM over several (see the module header).
        Called once per scan leaf per EXECUTION, on the driver thread."""
        self._refuse_foreign(binding, String("resolve"))
        var spec = _BrokerScanSpec.from_binding(binding)
        var total = Int64(0)
        for i in range(len(spec.partitions)):
            var core = self._core(spec.topic, spec.partitions[i])
            total += core.next_offset()
        return UInt64(total)

    # ---- tier 2 ---------------------------------------------------------------

    def descriptor(self) -> ScanKindDescriptor:
        return broker_scan_descriptor()

    def build_binding(self, params: ScanParams) raises -> ScanBinding:
        """Schema and partition set come from the topic's durable config
        (`<cluster>/_meta/topics/<topic>/config.json`); the kind appends
        `__partition`. `partitions` defaults to every partition of the topic;
        a partition the topic does not have is refused by name."""
        var topic = params.get_str(String(BROKER_PARAM_TOPIC))
        if topic == String(""):
            raise Error(
                String(BROKER_SCAN_BAD_PARAM)
                + String(": required param 'topic' is missing")
            )
        var cfg = BrokerTopicConfig.decode(
            self._store.get(Path.parse(_topic_config_key(self._cluster, topic)))
        )
        var p = params.copy()
        if not p.has(String(BROKER_PARAM_PARTITIONS)):
            var every = List[Int64]()
            for i in range(cfg.num_partitions):
                every.append(Int64(i))
            p.put_str(String(BROKER_PARAM_PARTITIONS), broker_join_i64(every))
        var named = broker_parse_i64_list(
            p.get_str(String(BROKER_PARAM_PARTITIONS)),
            String(BROKER_PARAM_PARTITIONS),
        )
        for i in range(len(named)):
            if named[i] >= Int64(cfg.num_partitions):
                raise Error(
                    String(BROKER_SCAN_BAD_PARAM)
                    + String(": topic '")
                    + topic
                    + String("' has ")
                    + String(cfg.num_partitions)
                    + String(" partitions; there is no partition ")
                    + String(named[i])
                )
        var sb = SchemaBuilder()
        for i in range(cfg.schema.num_columns()):
            var f = cfg.schema.field_at(i)
            if f.name == String(BROKER_PARTITION_COLUMN):
                raise Error(
                    String(BROKER_SCAN_BAD_PARAM)
                    + String(": topic '")
                    + topic
                    + String("' declares a column named '")
                    + String(BROKER_PARTITION_COLUMN)
                    + String("', which the scan appends")
                )
            sb.add_field(f)
        sb.add_field(
            Field(String(BROKER_PARTITION_COLUMN), ArrowType.INT64, nullable=False)
        )
        return broker_topic_binding(p, sb.build())

    def open_scan(self, req: ScanRequest) raises -> ScanOpened:
        """Drain the partitions `req.binding` names at the snapshot it names.
        `projection`, `predicate` and `limit` are hints this kind ignores (the
        engine re-applies the whole filter and re-projects)."""
        ref b = req.binding
        self._refuse_foreign(b, String("open"))
        var spec = _BrokerScanSpec.from_binding(b)
        # The CONFIG's schema, once the binding's topic columns match it: the
        # binding never decides how stored bytes decode.
        var topic_schema = self._check_topic_schema(
            spec.topic, _topic_schema_of(b), b.name
        )

        # ---- pass 1: per-partition facts, and the ONE pinned txn snapshot ----
        var facts = List[_PartitionFacts]()
        var txn_ids = List[String]()
        for i in range(len(spec.partitions)):
            var p = spec.partitions[i]
            var core = self._core(spec.topic, p)
            var hwm = core.next_offset()
            # ORDERING INVARIANT -- read `log_start` and the live index BEFORE
            # the compaction-index LIST. The compaction worker commits the
            # `CompactedEntry` (its step 6) BEFORE it advances `log_start`
            # (step 8), and `resolve_index` itself reads `log_start`. So any
            # read here that sees a moved `log_start` happened after the entry
            # was committed, and the LIST that follows every such read must see
            # that entry and refuse. LISTing first let steps 6-8 land between
            # an empty LIST and the `log_start` read, and pass 2 then clamped
            # `start` to the moved `log_start`: the live suffix, no error, the
            # prefix reported as retention.
            var log_start = core.log_start_offset()
            var index = core.resolve_index()
            var tags = core.chunk_txn_tags()
            self._refuse_compacted_tier(spec.topic, p, spec.start_offsets[i], hwm)
            for t in range(len(tags)):
                ref id = tags[t].txn_id
                if id != String("") and not _contains(txn_ids, id):
                    txn_ids.append(String(id))
            facts.append(
                _PartitionFacts(
                    partition=p,
                    high_watermark=hwm,
                    log_start_offset=log_start,
                    index=index^,
                    tags=tags^,
                )
            )
        if len(spec.partitions) == 1:
            # The single-partition token IS the HWM `resolve_snapshot` read:
            # read exactly that snapshot, never a later produce.
            var token = Int64(b.snapshot_token)
            if token < facts[0].high_watermark:
                facts[0].high_watermark = token
        var snap = TxnSnapshot()
        if len(txn_ids) > 0:
            var ctl = TxnControlStore[Self.Storage](
                self._store.clone(), String(self._cluster)
            )
            for i in range(len(txn_ids)):
                var c = ctl.read(txn_ids[i])
                if c:
                    snap.put(String(txn_ids[i]), c.value().state, c.value().epoch)

        # ---- pass 2: read, under the byte budget ------------------------------
        var batches = Slab[RecordBatch]()
        var resolved = ScanParams()
        var total_bytes = Int64(0)
        var returned_any = False
        var scan_full = False
        for i in range(len(facts)):
            ref f = facts[i]
            var p = f.partition
            var upper = f.high_watermark
            var lso = upper
            var aborted = String("")
            var aborted_seen = List[String]()
            for s in range(len(f.index)):
                ref seg = f.index[s]
                if seg.base_offset >= upper:
                    break
                var tag = _tag_of(f.tags, seg.chunk_seq)
                if not tag.is_transactional():
                    continue
                var st = snap.state_of(tag.txn_id)
                if (
                    st == TXN_STATE_ONGOING
                    or st == TXN_STATE_PREPARE_COMMIT
                    or st == TXN_STATE_PREPARE_ABORT
                ):
                    if seg.base_offset < lso:
                        lso = seg.base_offset
                elif not chunk_is_visible(tag, snap):
                    if not _contains(aborted_seen, tag.txn_id):
                        aborted_seen.append(String(tag.txn_id))
                        if aborted != String(""):
                            aborted += String(";")
                        aborted += tag.txn_id + String("@") + String(seg.base_offset)
            var bound = lso if spec.read_committed else upper
            var start = spec.start_offsets[i]
            if start < f.log_start_offset:
                start = f.log_start_offset
            var next_offset = bound if start < bound else start
            var part_bytes = Int64(0)
            if not scan_full:
                var core = self._core(spec.topic, p)
                for s in range(len(f.index)):
                    ref seg = f.index[s]
                    if seg.base_offset >= bound:
                        break
                    if seg.last_offset < start:
                        continue
                    if spec.read_committed and not chunk_is_visible(
                        _tag_of(f.tags, seg.chunk_seq), snap
                    ):
                        continue
                    var read = core.read_segment(seg.copy())
                    var stream = read^.take_stream_bytes()
                    var sz = Int64(len(stream))
                    if returned_any:
                        if spec.max_bytes >= Int64(0) and (
                            total_bytes + sz > spec.max_bytes
                        ):
                            next_offset = seg.base_offset if seg.base_offset > start else start
                            scan_full = True
                            break
                        if spec.partition_max_bytes >= Int64(0) and (
                            part_bytes + sz > spec.partition_max_bytes
                        ):
                            next_offset = seg.base_offset if seg.base_offset > start else start
                            break
                    var body = core.read_chunk_body(seg.chunk_seq)
                    var emitted = _emit_segment(
                        batches,
                        stream^,
                        topic_schema,
                        is_chunk_compacted(body),
                        decode_compacted_survivor_offsets(body),
                        seg.base_offset,
                        start,
                        p,
                    )
                    total_bytes += sz
                    part_bytes += sz
                    if emitted > 0:
                        returned_any = True
            else:
                next_offset = start
            resolved.put_i64(
                broker_resolved_key(String(BROKER_RESOLVED_HIGH_WATERMARK), p),
                upper,
            )
            resolved.put_i64(
                broker_resolved_key(String(BROKER_RESOLVED_LAST_STABLE_OFFSET), p),
                lso,
            )
            resolved.put_i64(
                broker_resolved_key(String(BROKER_RESOLVED_LOG_START_OFFSET), p),
                f.log_start_offset,
            )
            resolved.put_str(
                broker_resolved_key(String(BROKER_RESOLVED_ABORTED), p), aborted^
            )
            resolved.put_i64(
                broker_resolved_key(String(BROKER_RESOLVED_NEXT_OFFSET), p),
                next_offset,
            )
        return ScanOpened(ArcPointer(batches^), resolved^)

    # ---- internals ------------------------------------------------------------

    def _core(self, topic: String, partition: Int64) -> ConsumeCore[Self.Storage]:
        var manifest = CasManifestStore[Self.Storage](
            store=self._store.clone(),
            prefix=_manifest_prefix(self._cluster, topic, partition),
            retry=RetryPolicy.default(),
        )
        return ConsumeCore[Self.Storage](
            segment_store=self._store.clone(),
            manifest=manifest^,
            cluster=String(self._cluster),
            topic=String(topic),
            partition=partition,
        )

    def _check_topic_schema(
        self, topic: String, topic_schema: Schema, binding_name: String
    ) raises -> Schema:
        """Refuse a binding whose topic columns are not the topic's durable
        config schema (name, type, nullability, decimal precision and scale,
        in order), and return the CONFIG's schema, which is what decodes."""
        var cfg = BrokerTopicConfig.decode(
            self._store.get(Path.parse(_topic_config_key(self._cluster, topic)))
        )
        var n = cfg.schema.num_columns()
        if topic_schema.num_columns() != n:
            raise Error(
                String(BROKER_SCAN_SCHEMA_MISMATCH)
                + String(": binding '")
                + binding_name
                + String("' declares ")
                + String(topic_schema.num_columns())
                + String(" topic columns; topic '")
                + topic
                + String("' has ")
                + String(n)
            )
        for i in range(n):
            if (
                topic_schema.field_name(i) != cfg.schema.field_name(i)
                or topic_schema.field_arrow_type(i)
                != cfg.schema.field_arrow_type(i)
                or topic_schema.field_nullable(i) != cfg.schema.field_nullable(i)
                or topic_schema.field_decimal_precision(i)
                != cfg.schema.field_decimal_precision(i)
                or topic_schema.field_decimal_scale(i)
                != cfg.schema.field_decimal_scale(i)
            ):
                raise Error(
                    String(BROKER_SCAN_SCHEMA_MISMATCH)
                    + String(": binding '")
                    + binding_name
                    + String("' column ")
                    + String(i)
                    + String(" ('")
                    + topic_schema.field_name(i)
                    + String("') does not match topic '")
                    + topic
                    + String("' column '")
                    + cfg.schema.field_name(i)
                    + String("' in name, type, nullability or decimal")
                    + String(" precision/scale")
                )
        return cfg.schema.copy()

    def _refuse_compacted_tier(
        self, topic: String, partition: Int64, start: Int64, hwm: Int64
    ) raises:
        """Refuse a range `[start, hwm)` that reaches a compaction-index entry
        (the Parquet tier). One authoritative LIST of the compacted lineage
        per partition per execution; an empty lineage costs no GET."""
        var cidx = CompactionIndex[Self.Storage].build(
            self._store.clone(), _manifest_prefix(self._cluster, topic, partition)
        )
        var entries = cidx.resolve_compacted()
        for e in range(len(entries)):
            ref ent = entries[e]
            if ent.last_offset >= start and ent.base_offset < hwm:
                raise Error(
                    String(BROKER_SCAN_COMPACTED_TIER_UNREAD)
                    + String(": topic '")
                    + topic
                    + String("' partition ")
                    + String(partition)
                    + String(" offsets ")
                    + String(ent.base_offset)
                    + String("..")
                    + String(ent.last_offset)
                    + String(" are in the compacted (Parquet) tier, which this")
                    + String(" scan does not read; start at or after ")
                    + String(ent.last_offset + Int64(1))
                )

    def _refuse_foreign(self, binding: ScanBinding, verb: String) raises:
        if binding.kind_id != broker_scan_kind_id():
            raise Error(
                String("BrokerScanRuntime: refusing to ")
                + verb
                + String(" foreign kind '")
                + binding.kind_name
                + String("' (serves ")
                + String(BROKER_SCAN_KIND_NAME)
                + String(")")
            )


def broker_scan_runtime[
    S: CloneableConditionalWriteStore
](var store: S, var cluster: String) -> ErasedScanMorselResolver:
    """The product resolver for `komira.broker.topic`, erased for
    `ScanMorselResolvers.register` / `EngineContext.register_scan_kind`."""
    return ErasedScanMorselResolver.erase(
        BrokerScanRuntime[S](store^, cluster^)
    )


# =============================================================================
# helpers
# =============================================================================


def _contains(xs: List[String], x: String) -> Bool:
    for i in range(len(xs)):
        if xs[i] == x:
            return True
    return False


def _tag_of(tags: List[ChunkTagAt], chunk_seq: Int64) -> ChunkTxnTag:
    """The transaction tag of data chunk `chunk_seq`; a chunk with no tag entry
    (reaped mid-walk) is non-transactional."""
    for i in range(len(tags)):
        if tags[i].chunk_seq == chunk_seq:
            return ChunkTxnTag(
                tags[i].marker_type, String(tags[i].txn_id), tags[i].producer_epoch
            )
    return ChunkTxnTag(Int64(0), String(""), Int64(0))


def _topic_schema_of(b: ScanBinding) raises -> Schema:
    """The binding's schema minus its trailing `__partition` column. Refuses a
    binding whose schema does not end in it."""
    var n = b.schema.num_columns()
    if (
        n < 1
        or b.schema.field_name(n - 1) != String(BROKER_PARTITION_COLUMN)
        or b.schema.field_arrow_type(n - 1) != ArrowType.INT64
    ):
        raise Error(
            String(BROKER_SCAN_NOT_EXECUTABLE_BINDING)
            + String(": binding '")
            + b.name
            + String("' does not end in the ")
            + String(BROKER_PARTITION_COLUMN)
            + String(" INT64 column; build it with BrokerScanRuntime.build_binding")
        )
    var sb = SchemaBuilder()
    for i in range(n - 1):
        sb.add_field(b.schema.field_at(i))
    return sb.build()


def _partition_column(partition: Int64, rows: Int) raises -> Column[HeapRegion]:
    var arr = PrimitiveArray[DType.int64].allocate(rows)
    for i in range(rows):
        arr.set(i, partition)
    return Column.from_primitive[DType.int64](arr^)


def _emit_segment(
    mut out: Slab[RecordBatch],
    var stream: List[UInt8],
    topic_schema: Schema,
    compacted: Bool,
    survivors: List[Int64],
    base_offset: Int64,
    start: Int64,
    partition: Int64,
) raises -> Int:
    """Decode one segment and append its rows at offsets `>= start`, each with
    the `__partition` column. A log-compacted chunk's row `r` is at
    `survivors[r]` (a zero-survivor chunk is compacted with an EMPTY sidecar,
    which is why `compacted` is its own flag); an ordinary chunk's at
    `base_offset + r`. Returns the rows appended."""
    var decoded = _decode_segment_stream(stream^, topic_schema)
    if compacted:
        var physical = 0
        for i in range(len(decoded)):
            physical += decoded[i].num_rows()
        if physical != len(survivors):
            raise Error(
                String(BROKER_SCAN_COMPACTED_CHUNK_MISMATCH)
                + String(": compacted chunk at base offset ")
                + String(base_offset)
                + String(" holds ")
                + String(physical)
                + String(" rows for ")
                + String(len(survivors))
                + String(" survivor offsets")
            )
    var row = 0
    var emitted = 0
    while len(decoded) > 0:
        var batch = decoded.take_at(0)
        var n = batch.num_rows()
        # First row of this frame whose absolute offset reaches `start`.
        var skip = 0
        while skip < n:
            var off = (
                survivors[row + skip] if compacted else base_offset
                + Int64(row + skip)
            )
            if off >= start:
                break
            skip += 1
        row += n
        if skip >= n:
            continue
        var kept: RecordBatch
        if skip == 0:
            kept = batch^
        else:
            kept = _slice_batch_range(batch, skip, n - skip)
        var kn = kept.num_rows()
        kept.append_column(
            Field(String(BROKER_PARTITION_COLUMN), ArrowType.INT64, nullable=False),
            _partition_column(partition, kn),
        )
        out.append(kept^)
        emitted += kn
    return emitted


def _decode_segment_stream(
    var bytes: List[UInt8], topic_schema: Schema
) raises -> Slab[RecordBatch]:
    """Schema-directed decode of one segment's Arrow IPC stream
    (`Schema, RecordBatch*, EOS`) with `komira_core`'s record-batch decoder.
    The Schema frame is skipped: `topic_schema` is the topic's durable config
    schema (`_check_topic_schema` returns it), which is the authority, and a
    frame whose column count disagrees with it is refused by the core decoder's
    own bounds checks."""
    var types = List[ArrowType]()
    for i in range(topic_schema.num_columns()):
        types.append(topic_schema.field_arrow_type(i))
    var n = len(bytes)
    var src = SharedAlignedBuffer[HeapRegion].heap_owned(n)
    src.copy_from_bytes_list(bytes^)
    var out = Slab[RecordBatch]()
    var cursor = 0
    var saw_eos = False
    while cursor + 8 <= n:
        var cont = src.read_u32_le_at(cursor)
        var size_u32 = src.read_u32_le_at(cursor + 4)
        if cont != UInt32(0xFFFFFFFF):
            raise Error(
                String("broker segment decode: no continuation marker at byte ")
                + String(cursor)
            )
        if size_u32 == UInt32(0):
            saw_eos = True
            break
        var meta_size = Int(size_u32)
        if cursor + 8 + meta_size > n:
            raise Error(
                String("broker segment decode: metadata past end at byte ")
                + String(cursor)
            )
        var fb = SharedAlignedBuffer[HeapRegion].heap_owned(meta_size)
        fb.copy_from_view_at(0, src.view_range_ro(cursor + 8, meta_size))
        fb.set_length(meta_size)
        var reader = flatbuf_reader_over(fb)
        var msg = read_message(reader, reader.read_root_offset())
        var body = Int(msg.body_length)
        var frame_size = 8 + meta_size + body
        if body < 0 or cursor + frame_size > n:
            raise Error(
                String("broker segment decode: frame past end at byte ")
                + String(cursor)
            )
        if msg.header_tag == MESSAGE_HEADER_SCHEMA:
            cursor += frame_size
            continue
        if msg.header_tag == MESSAGE_HEADER_DICTIONARY_BATCH:
            raise Error(
                String(BROKER_SCAN_DICTIONARY_SEGMENT)
                + String(": a broker segment carried a DictionaryBatch frame")
            )
        if msg.header_tag != MESSAGE_HEADER_RECORD_BATCH:
            raise Error(
                String("broker segment decode: unexpected message tag ")
                + String(Int(msg.header_tag))
            )
        var frame = SharedAlignedBuffer[HeapRegion].heap_owned(frame_size)
        frame.copy_from_view_at(0, src.view_range_ro(cursor, frame_size))
        frame.set_length(frame_size)
        var cols = decode_record_batch_message(frame^, types)
        var builder = RecordBatchBuilder.with_capacity(len(cols))
        var nc = len(cols)
        for c in range(nc):
            builder.add_column(cols.take_slot_unchecked(c))
        cols.set_len_unchecked(0)
        _ = cols^
        out.append(builder.build(topic_schema.copy()))
        cursor += frame_size
    if not saw_eos:
        raise Error(String("broker segment decode: stream ended without EOS"))
    return out^
