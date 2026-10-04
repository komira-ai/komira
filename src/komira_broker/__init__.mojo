"""`komira_broker` — the Komira message broker core, stored entirely in an
object store.

The produce path:
  * BrokerCore[Storage] — the concrete, non-generic broker core. It has no
    `Protocol` parameter, so protocol codecs never multiply its compile-time
    instantiations. It is parametrized only over the storage backend
    `Storage: ConditionalWriteStore`, and owns the segment store and the
    partition's CasManifestStore (the offset allocator) by value. The
    produce path buffers RecordBatches, flushes at 8 MiB / 250 ms, encodes an
    Arrow-IPC segment plus footer, PUTs it to the object store, commits the
    offset range via the manifest append, and acks only after both land.
  * Segment format: SegmentFooter + encode_segment / encode_manifest_body
    (Arrow-IPC stream + a fixed 40-byte footer; the manifest chunk body).
  * ProduceResult — the durable ack (manifest-assigned offset range +
    segment key + chunk_seq).

Protocol front ends (for example the Kafka wire server) sit above this one
core as thin edge structs and do not change its surface.

Dependencies (cycle-free): komira_core (RecordBatch / Schema / Column and the
Arrow-IPC encoder), komira_objectstore (ConditionalWriteStore +
CasManifestStore), komira_async and komira_metrics. The concrete cloud store is
injected by whichever program instantiates the core.
"""

from .broker_core import (
    BrokerCore,
    BrokerTopicConfig,
    ProduceResult,
    SegmentFooter,
    encode_segment,
    assemble_segment_from_frames,
    encode_record_batch_frame_bytes,
    FLUSH_BYTES,
    FLUSH_MS,
    SEGMENT_FOOTER_LEN,
)

# The broker PRODUCE path on the CoalescingWindow primitive (the parkable
# path). The three broker conformers (BrokerHeadReader / BrokerSegCodec /
# BrokerBatchAppender) and the per-partition driver BrokerCoalescingProduce
# express the producer/txn/lease variants as STATE on one codec and one
# mode-correct parkable appender.
from .broker_coalescing_produce import (
    BrokerCoalescingProduce,
    BrokerProduceItem,
    BrokerProduceOutcome,
    BrokerSegCodec,
    BrokerHeadReader,
    BrokerBatchAppender,
    BrokerProduceSpineFactory,
    BrokerHead,
    BROKER_APPEND_MODE_ESCALATING,
    BROKER_APPEND_MODE_IDEMPOTENT_SINGLETON,
    BPO_AT_LEAST_ONCE,
    BPO_EOS_COMMITTED,
    BPO_EOS_DUPLICATE,
    BPO_EOS_FENCED,
    BPO_EOS_LEASE_FENCED,
    BPO_EOS_RETRYABLE,
)

# ManifestBody + encode_manifest_body live in the LEAF module manifest_body.mojo
# (so retention.mojo imports them without a cycle); re-exported here. The
# transaction marker types (MARKER_NONE / MARKER_COMMIT / MARKER_ABORT) ride in
# the same trailer.
from .manifest_body import (
    ManifestBody,
    encode_manifest_body,
    MARKER_NONE,
    MARKER_COMMIT,
    MARKER_ABORT,
)

# Retention — time/size policy, the pure decision, the pass orchestrator, and
# the grace-gated reaper.
from .retention import (
    ReapWorker,
    RetentionPass,
    RetentionPolicy,
    RetentionResult,
    evaluate_retention,
    DEFAULT_GRACE_PERIOD_MS,
)

# Key-based log compaction (Kafka cleanup.policy=compact): keep only the latest
# value per KEY in the cleanable range; a null-value record is a TOMBSTONE that
# deletes a key and is retained `delete.retention.ms` then dropped. PRESERVES
# surviving offsets (the compacted chunk stays SPARSE within its unchanged span
# — gaps, never renumber). DISTINCT from komira_broker_compaction (tier
# compaction, keeps all rows) and partition_compaction (split-lineage collapse).
from .log_compaction import (
    CleanRecord,
    CleanResult,
    CompactionConfig,
    CompactionPlan,
    LogCleaner,
    compact_records,
    extract_clean_records,
    encode_compacted_chunk_body,
    decode_compacted_survivor_offsets,
    cleanup_policy_name,
    cleanup_policy_from_name,
    cleanup_policy_compacts,
    cleanup_policy_deletes,
    CLEANUP_POLICY_DELETE,
    CLEANUP_POLICY_COMPACT,
    CLEANUP_POLICY_COMPACT_DELETE,
)

# Consume side — the read-side dual of BrokerCore (ConsumeCore) + the Source
# edge (MessageBrokerConsumer). Native Arrow only: the cores and edges
# monomorphize over `Storage` alone; the Kafka wire convention lives at the
# server shim (runtime api_key dispatch), not as a comptime `Format` parameter.
from .consume_core import (
    ConsumeCore,
    ConsumeReadResult,
    ConsumeSegment,
    SegmentRef,
    ChunkTagAt,
)

from .consumer_source import (
    MessageBrokerConsumer,
)

# Dynamic partition scaling — the partition-map abstraction. The versioned
# `partition_map.json` object that mediates ROUTING (high-bits range, not % N)
# + partition-set enumeration, between config.json and the per-partition
# manifests.
from .partition_map import (
    HashRange,
    PartitionMap,
    RetiredRange,
    MapWithEtag,
    PARTITION_MODE_AUTO,
    PARTITION_MODE_FIXED,
    PARTITION_MAP_HASH_ID,
    NO_PARENT_PID,
    NO_PARENT_BASE,
    NO_MERGE_PID,
    partition_map_key,
    prefix_gen_manifest_prefix,
    persist_create_if_absent,
    read_partition_map,
    read_partition_map_with_etag,
    persist_update,
    try_persist_update,
    mode_name,
    mode_from_name,
)

# Dynamic partition scaling — the SPLIT mechanism + the consumer lineage-forest
# read order. `split_topic` freezes the parent at offset X and CAS-forks two
# children; `build_lineage_read_order` gives the whole-topic consumer's
# topological (parents-before-children) read order so every record is read
# exactly once. The auto-trigger (WHEN to split) is in partition_trigger.
from .partition_split import (
    SplitResult,
    LineageReadStep,
    split_topic,
    split_topic_if_live,
    build_lineage_read_order,
)

# Dynamic partition scaling — the MERGE (scale-IN) mechanism (the DUAL of
# split): `merge_topic` freezes two ADJACENT parents at their tails Xa/Xb and
# CAS-folds them into ONE fresh child C; `merge_topic_if_eligible` is the
# idempotent proposal (clean no-op if A/B already merged/split — no double-
# merge). The merged child's lineage (two range-pure predecessors) is read by
# `build_lineage_read_order` (whose `_depth_of` walks the merge fan-in edge).
# The merge trigger (WHEN to merge — conservative hysteresis) is
# `evaluate_merge` in partition_trigger.
from .partition_merge import (
    MergeResult,
    merge_topic,
    merge_topic_if_eligible,
)

# Dynamic partition scaling — the lineage-collapse COMPACTION tick: re-route a
# frozen SPLIT parent's rows into its range-pure children + CAS-collapse the
# parent's lineage edge so the child read no longer walks the parent prefix
# (relief for the lineage depth cap). A read-correctness-equivalent
# optimization; the parent's orphaned segments are left for retention to reap.
from .partition_compaction import (
    CompactionResult,
    GenCompactionResult,
    compact_split_parent,
    compact_split_parent_gen,
    fnv1a_int64_key,
)

# Dynamic partition scaling — the AUTO-SPLIT TRIGGER (load detection: WHEN to
# split). Object-store-native, NO always-on scaler service: after a flush the
# producer checks the just-written partition's manifest-derived load
# (records_since_base + segment_count, both on the ProduceResult — zero extra
# object-store I/O) against an `AutoSplitPolicy` and, if the threshold is
# crossed (and under the max_partitions cap, past the fresh-child floor),
# PROPOSES a split via the If-Match CAS. The WRITE PATH drives scaling.
# `evaluate_split` is the pure decision; the producer owns the store calls +
# the hot-key warning.
from .partition_trigger import (
    AutoSplitPolicy,
    SplitDecision,
    evaluate_split,
    split_decision_name,
    SPLIT_DECISION_PROPOSE,
    SPLIT_DECISION_SKIP_BELOW_THRESHOLD,
    SPLIT_DECISION_SKIP_FRESH_FLOOR,
    SPLIT_DECISION_SKIP_AT_CAP,
    SPLIT_DECISION_SKIP_DEPTH_CAP,
    DEFAULT_SPLIT_THRESHOLD_RECORDS,
    DEFAULT_MAX_PARTITIONS,
    DEFAULT_MIN_SEGMENTS_BEFORE_SPLIT,
    DEFAULT_MAX_LINEAGE_DEPTH,
    # The MERGE (scale-IN) trigger: conservative hysteresis (both adjacent
    # ranges sustainedly cold, anti-flap on recently-split, min-partitions floor).
    AutoMergePolicy,
    MergeDecision,
    evaluate_merge,
    merge_decision_name,
    MERGE_DECISION_PROPOSE,
    MERGE_DECISION_SKIP_NOT_COLD,
    MERGE_DECISION_SKIP_RECENTLY_SPLIT,
    MERGE_DECISION_SKIP_AT_FLOOR,
    DEFAULT_MERGE_THRESHOLD_RECORDS,
    DEFAULT_MIN_PARTITIONS,
)

# Multi-node placement — the PURE partition->NODE assignment pass: even-spread
# + sticky/minimal-move over the live node set, node-liveness/stale tracking,
# and the rebalance-trigger decision. Store-agnostic (no DB/object-store dep) so
# the unit tests run it offline; the caller persists the result. Distinct from
# partition_map/partition_split (which decide partition COUNT, not placement).
from .partition_assignment import (
    LiveNode,
    Assignment,
    AssignmentView,
    assign_partitions,
    rebalance_reason_for,
    rebalance_reason_name,
    is_node_live,
    live_node_ids,
    REBALANCE_NONE,
    REBALANCE_NEW_NODE,
    REBALANCE_STALE_NODE,
    REBALANCE_PARTITION_COUNT,
    REBALANCE_OPERATOR,
    REBALANCE_INITIAL,
)

# The DB-free partition-assignment store over a
# CloneableConditionalWriteStore (pure object-store CAS). The binary FORMAT
# lives on the Assignment type (encode_binary / decode_binary); this is the
# store layer (read_assignment / store_assignment, etag-CAS, per-topic key).
from .cluster_assignment_store import (
    ClusterAssignmentStore,
    StoredAssignment,
)

# Multi-node placement — the in-process agent->broker relay: the co-located
# node's owned-partition set + apply_assignment(assigned[]) -> the START/STOP
# ReconcileDelta the integration caller applies to the Kafka server's
# per-partition leader map. Pure value (no DB/object-store/RPC); the agent holds
# a borrowed ref riding the per-dispatch heartbeat value.
from .broker_node_state import (
    BrokerNodeState,
    ReconcileDelta,
)

# Tier compaction (leaf side) — the compacted tier's offset->Parquet-object
# index (a SEPARATE CAS lineage under `<partition-prefix>/compacted`), the
# dual-tier (compacted+live) offset resolution, and the SLO back-pressure
# decision. The concat / transcode / CompactionWorker that need the SDK and
# Parquet live in the `komira_broker_compaction` adapter package ABOVE this
# leaf (keeping the broker a LEAF: no broker->parquet/sdk dep).
from .compacted_index import (
    CompactedEntry,
    CompactionIndex,
    TierRef,
    SloDecision,
    evaluate_slo_backpressure,
    dual_tier_resolve,
    compacted_prefix,
)

# Exactly-once: the idempotent producer. The producer registry
# (monotonic-epoch zombie fence, persisted in the object store) + the pure
# dedupe sequence FSM. The sequence state itself rides inside the manifest body
# (encode_manifest_body's producer trailer) so it commits atomically with the
# segment. Transactions build on the SAME registry + sequence substrate.
from .producer_registry import (
    ProducerRegistry,
    ProducerEntry,
    producer_key,
    producer_id_counter_key,
)
from .producer_dedupe import (
    SequenceDecision,
    decide_sequence,
    dedupe_outcome_name,
    DEDUPE_ACCEPT,
    DEDUPE_DUPLICATE,
    DEDUPE_OUT_OF_ORDER,
    DEDUPE_FENCED,
)

# Exactly-once: transactions. The object-store transaction control object (the
# SOLE linearization point: Empty -> Ongoing -> PrepareCommit -> Complete |
# Abort via If-Match CAS), the transactional-id -> producer_id binding (a
# producer restart reuses its pid + bumps the SAME monotonic epoch — the zombie
# fence), and the read_committed visibility filter with the PINNED-SNAPSHOT
# multi-partition resolution + the epoch-equality fence.
from .txn_control import (
    TxnControl,
    TxnControlStore,
    TxnPartition,
    txn_control_key,
    txn_state_name,
    txn_state_is_terminal,
    TXN_STATE_EMPTY,
    TXN_STATE_ONGOING,
    TXN_STATE_PREPARE_COMMIT,
    TXN_STATE_COMPLETE,
    TXN_STATE_PREPARE_ABORT,
    TXN_STATE_ABORT,
)
from .txn_registry import (
    TxnIdRegistry,
    txn_id_bind_key,
    txn_pid_reverse_key,
)
from .read_committed import (
    ChunkTxnTag,
    TxnSnapshot,
    chunk_is_visible,
    chunk_is_offset_bearing,
    collect_referenced_txn_ids,
)
