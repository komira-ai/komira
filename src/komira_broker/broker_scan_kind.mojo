# =============================================================================
# broker_scan_kind — the broker topic as an EXECUTABLE scan kind (tier 2).
# =============================================================================
#
# `broker_scan_binding.mojo` made a topic a plan SOURCE: a binding that can be
# built, typed, explained, cloned and cache-keyed without any broker type
# reaching core. This file makes it EXECUTABLE: `BrokerScanRuntime` conforms to
# `komira_scan_resolver`'s `ScanSourceResolver`. It resolves a
# `komira.broker.topic` leaf's LIVE token, plans one split per partition, and
# opens a `BrokerSplitReader` (`broker_split_reader.mojo`) per split.
# `drain_scan` reads such a plan into resident batches.
#
# ---------------------------------------------------------------------------
# THE PLAN: WHAT ONE EXECUTION READS
# ---------------------------------------------------------------------------
#
# `plan_splits` is the execution's one read of the topic's metadata. For every
# partition the binding names (ONE scan over the list, not one plan per
# partition; every row carries `__partition`) it plans one split, keyed
# `<topic>/<partition>`:
#
#   upper   = the high-watermark (HWM). For a SINGLE-partition binding it is
#             the binding's own LIVE token, which `resolve_snapshot` set to
#             `ConsumeCore.next_offset()`, so the rows returned are exactly the
#             snapshot the caller was told about even if a produce lands in
#             between. A MULTI-partition binding's token is the SUM of the
#             partitions' HWMs (monotone, so it still moves on every produce);
#             one `UInt64` cannot name N watermarks. Its plan reads each
#             partition's HWM ONCE, so a produce landing between resolve and
#             plan IS read, and `high_watermark.<p>` says exactly where. This
#             is not an exception to the resolver contract; it is the
#             contract (`ScanSplitPlan`): the plan's stops are the authority on
#             what was read, and the token is freshness and identity only.
#   LSO     = the last stable offset: the base offset of the first chunk whose
#             transaction is still UNDECIDED (Ongoing / PrepareCommit /
#             PrepareAbort) in the PINNED transaction snapshot, else `upper`.
#   start   = the requested offset (`start_offsets`, else `start_offset`),
#             raised to the partition's `log_start` (retention).
#   stop    = `min(upper, LSO)` for `read_committed`, `upper` otherwise. Exact.
#   skip    = for `read_committed`, the data chunks below the stop that are not
#             visible (an aborted or epoch-fenced transaction's, markers),
#             decided once against the pinned snapshot and carried in every
#             position of the split (`broker_split_reader.mojo`). Aborted
#             transactions are named in `aborted.<p>`.
#
# THE PINNED SNAPSHOT (read_committed.mojo). Transaction states are read ONCE
# per execution, across EVERY partition, before any split is planned — never
# per partition — so a commit flipping mid-plan cannot yield partition 0
# committed and partition 1 not.
#
# WHERE A READ STOPPED. `resolve_drained` writes `next_offset.<p>`: the first
# offset of partition `p` the read did NOT return, from where the drain left
# that split. A split the drain never opened reports its start; one a budget
# cut reports the offset after its last returned frame.
#
# FOLLOWING A TOPIC. Every split this kind plans has a stop, and the plan is
# complete. Discovering partitions for a read that follows the topic
# (`discover_splits`) is refused by name until a plan can say it is such a
# read and an engine can follow a split.
#
# ---------------------------------------------------------------------------
# THE LIVE TIER, AND THE COMPACTED TIER
# ---------------------------------------------------------------------------
#
# A LOG-COMPACTED chunk (`log_compaction.mojo`) keeps its manifest offset span
# but holds only survivor rows; its preserved absolute offsets are read off the
# chunk body's sidecar, so a start offset inside a compacted chunk skips
# exactly the survivors below it.
#
# ⛔ THE COMPACTED (PARQUET) TIER IS NOT READ, AND IS REFUSED BY NAME, by the
# plan and again by every reader at open (`refuse_compacted_tier`). The
# compacted tier (`compacted_index.mojo`, written by
# `komira_broker_compaction`) holds a prefix of the log as Parquet objects,
# and the compaction worker then ADVANCES the live `log_start` past that
# prefix. Clamping the start to `log_start` would silently return only the
# live suffix and report the moved `log_start` as if retention had deleted
# the prefix. Decoding that tier needs the parquet reader, which this leaf may
# not depend on: reading it is tracked follow-up work.
#
# THE STORED BYTES ARE DECODED WITH THE TOPIC'S DURABLE SCHEMA. The plan and
# every reader check the binding's topic columns against the topic's durable
# config (`check_topic_schema`), and every segment is decoded, and every output
# batch built, with the CONFIG's schema (plus `__partition`), not the
# binding's: a stale plan-cached binding or one decoded off the wire never
# chooses how segment bytes are read.
#
# ---------------------------------------------------------------------------
# THE BYTE BUDGETS
# ---------------------------------------------------------------------------
#
# `partition_max_bytes` (a binding param) is the reader's: KIP-74 per split,
# see `broker_split_reader.mojo`. The scan-wide budget is NOT a binding param:
# it is `drain_scan(max_bytes=)`, applied between polls across every split, and
# a binding naming `max_bytes` is refused by name (`broker_scan_binding.mojo`).
# The drain's cut overshoots by at most one segment, and `next_offset.<p>`
# always says exactly where each partition stopped.
#
# ---------------------------------------------------------------------------
# ENCAPSULATION
# ---------------------------------------------------------------------------
#
# No `UnsafePointer` anywhere in this file, no wildcard origin, no
# `unsafe_from_address`. The plan builds one `ConsumeCore` per partition on the
# stack and drops it; the per-partition facts it yields are Copyable values. A
# reader owns its own `ConsumeCore` by value.
# =============================================================================

from komira_core.arrow.arrow_types import ArrowType
from komira_core.arrow.schema import Field, Schema, SchemaBuilder
from komira_core.source.scan_binding import ScanBinding, SCAN_EPOCH_NONE
from komira_core.source.scan_kind_registry import ScanKindDescriptor
from komira_core.source.scan_params import ScanParams

from komira_scan_resolver.scan_source_resolver import (
    ErasedScanSourceResolver,
    ScanRequest,
    ScanSourceResolver,
)
from komira_scan_resolver.scan_split import (
    DrainedSplit,
    ScanSplit,
    ScanSplitPlan,
    SplitDelta,
)

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

from .broker_core import BrokerTopicConfig, _manifest_prefix, _topic_config_key
from .broker_scan_binding import (
    BROKER_ISOLATION_READ_COMMITTED,
    BROKER_PARAM_ISOLATION,
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
from .broker_split_reader import (
    BROKER_POSITION_VERSION,
    BrokerSplitReader,
    broker_position_offset,
    broker_position_skip,
    broker_split_position,
    check_topic_schema,
    refuse_compacted_tier,
)
from .consume_core import ChunkTagAt, ConsumeCore, SegmentRef
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
budget-cut read resumes."""

comptime BROKER_SCAN_NOT_EXECUTABLE_BINDING: StaticString = (
    "BROKER_SCAN_NOT_EXECUTABLE_BINDING"
)
"""NAMED ERROR — a plan or a reader got a binding whose schema does not end in
the `__partition` INT64 column, i.e. one `build_binding` did not produce (the
plan-level convenience `broker_scan_binding` declares a caller's schema)."""

comptime BROKER_SCAN_TAIL_NOT_EXECUTABLE: StaticString = (
    "BROKER_SCAN_TAIL_NOT_EXECUTABLE"
)
"""NAMED ERROR — a read that follows a topic past its snapshot: discovering
partitions (`discover_splits`), or opening a split with no stop. A broker scan
is planned at a snapshot (every split stops at its LSO or HWM) until a plan
can say it follows the topic and an engine can follow a split."""


def broker_resolved_key(key: String, partition: Int64) -> String:
    """`("high_watermark", 3)` -> `"high_watermark.3"`."""
    return key + String(".") + String(partition)


def broker_split_key(topic: String, partition: Int64) -> String:
    """`("orders", 3)` -> `"orders/3"`: the split key of one partition."""
    return topic + String("/") + String(partition)


def _partition_of_split_key(key: String) raises -> Int64:
    """The partition id after the LAST `/` of a split key (a topic name may
    itself hold a `/`)."""
    var at = key.rfind("/")
    if at < 0:
        raise Error(
            String(BROKER_SCAN_BAD_PARAM)
            + String(": split key '")
            + key
            + String("' names no partition")
        )
    return Int64(atol(String(key[byte = at + 1 : key.byte_length()])))


# =============================================================================
# The scan spec a binding carries, parsed once.
# =============================================================================


@fieldwise_init
struct _BrokerScanSpec(Copyable, Movable, Deinitable):
    var topic: String
    var partitions: List[Int64]
    var start_offsets: List[Int64]
    var read_committed: Bool
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
            partition_max_bytes=b.params.get_i64(
                String(BROKER_PARAM_PARTITION_MAX_BYTES), Int64(-1)
            ),
        )

    def index_of(self, partition: Int64) -> Int:
        for i in range(len(self.partitions)):
            if self.partitions[i] == partition:
                return i
        return -1


@fieldwise_init
struct _PartitionFacts(Copyable, Movable, Deinitable):
    """What the plan learns about one partition. Copyable values only — the
    `ConsumeCore` that produced them is already gone."""

    var partition: Int64
    var high_watermark: Int64
    var log_start_offset: Int64
    var index: List[SegmentRef]
    var tags: List[ChunkTagAt]


# =============================================================================
# BrokerScanRuntime
# =============================================================================


struct BrokerScanRuntime[Storage: CloneableConditionalWriteStore](
    ScanSourceResolver, Movable, Deinitable
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

    comptime Reader = BrokerSplitReader[Self.Storage]

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

    def position_version(self) -> UInt8:
        return BROKER_POSITION_VERSION

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

    def plan_splits(self, req: ScanRequest) raises -> ScanSplitPlan:
        """One split per partition `req.binding` names, at the snapshot it
        names (module header). `projection`, `predicate` and `limit` are hints
        this kind ignores (the engine re-applies the whole filter and
        re-projects; the row limit is the drain's)."""
        ref b = req.binding
        self._refuse_foreign(b, String("plan"))
        var spec = _BrokerScanSpec.from_binding(b)
        # Refused here, before any partition is read, and again by every
        # reader at open.
        _ = check_topic_schema(
            self._store, self._cluster, spec.topic, _topic_schema_of(b), b.name
        )

        # ---- per-partition facts, and the ONE pinned txn snapshot ------------
        var facts = List[_PartitionFacts]()
        var txn_ids = List[String]()
        for i in range(len(spec.partitions)):
            var p = spec.partitions[i]
            var core = self._core(spec.topic, p)
            var hwm = core.next_offset()
            # ORDERING INVARIANT: `log_start` and the live index BEFORE the
            # compaction-index LIST (`refuse_compacted_tier`).
            var log_start = core.log_start_offset()
            var index = core.resolve_index()
            var tags = core.chunk_txn_tags()
            refuse_compacted_tier(
                self._store, self._cluster, spec.topic, p, spec.start_offsets[i], hwm
            )
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

        # ---- one split per partition -----------------------------------------
        var splits = List[ScanSplit]()
        var resolved = ScanParams()
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
            var skip = List[Int64]()
            if spec.read_committed:
                for s in range(len(f.index)):
                    ref seg = f.index[s]
                    if seg.base_offset >= bound:
                        break
                    if not chunk_is_visible(_tag_of(f.tags, seg.chunk_seq), snap):
                        skip.append(seg.chunk_seq)
            var start = spec.start_offsets[i]
            if start < f.log_start_offset:
                start = f.log_start_offset
            var est = bound - start if start < bound else Int64(0)
            splits.append(
                ScanSplit(
                    broker_split_key(spec.topic, p),
                    broker_split_position(start, skip),
                    Optional(broker_split_position(bound, skip)),
                    est_rows=est,
                )
            )
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
        return ScanSplitPlan(splits^, True, resolved^)

    def discover_splits(
        self, req: ScanRequest, known: List[String]
    ) raises -> SplitDelta:
        """Refused by name (`BROKER_SCAN_TAIL_NOT_EXECUTABLE`): every plan this
        kind makes is complete (module header)."""
        raise Error(
            String(BROKER_SCAN_TAIL_NOT_EXECUTABLE)
            + String(": scan '")
            + req.binding.name
            + String("' of ")
            + String(BROKER_SCAN_KIND_NAME)
            + String(" is planned at a snapshot; following the topic for new")
            + String(" partitions waits for a plan that can say it follows one")
        )

    def open_split(
        self, req: ScanRequest, split: ScanSplit
    ) raises -> BrokerSplitReader[Self.Storage]:
        """A reader of one partition from `split.start` to `split.stop`. It
        re-checks the topic schema and the live tier's extent before it reads
        (`BrokerSplitReader.open`)."""
        ref b = req.binding
        self._refuse_foreign(b, String("open"))
        var spec = _BrokerScanSpec.from_binding(b)
        var p = _partition_of_split_key(split.split_key)
        if (
            spec.index_of(p) < 0
            or split.split_key != broker_split_key(spec.topic, p)
        ):
            raise Error(
                String(BROKER_SCAN_BAD_PARAM)
                + String(": split '")
                + split.split_key
                + String("' is not a partition of scan '")
                + b.name
                + String("'")
            )
        if not split.stop:
            raise Error(
                String(BROKER_SCAN_TAIL_NOT_EXECUTABLE)
                + String(": split '")
                + split.split_key
                + String("' has no stop; a broker split is read to its LSO or HWM")
            )
        var what = String("start of '") + split.split_key + String("'")
        var start = broker_position_offset(split.start, what)
        var skip = broker_position_skip(split.start, what)
        var bound = broker_position_offset(
            split.stop.value(), String("stop of '") + split.split_key + String("'")
        )
        var topic_schema = check_topic_schema(
            self._store, self._cluster, spec.topic, _topic_schema_of(b), b.name
        )
        return BrokerSplitReader[Self.Storage].open(
            self._core(spec.topic, p),
            self._store.clone(),
            String(self._cluster),
            String(spec.topic),
            p,
            topic_schema^,
            start,
            bound,
            skip^,
            spec.partition_max_bytes,
        )

    def resolve_drained(
        self,
        req: ScanRequest,
        var resolved: ScanParams,
        stopped: List[DrainedSplit],
    ) raises -> ScanParams:
        """The plan's side channel plus `next_offset.<p>`: where the drain left
        each partition (module header)."""
        for i in range(len(stopped)):
            ref d = stopped[i]
            var p = _partition_of_split_key(d.split_key)
            resolved.put_i64(
                broker_resolved_key(String(BROKER_RESOLVED_NEXT_OFFSET), p),
                broker_position_offset(
                    d.position, String("drained '") + d.split_key + String("'")
                ),
            )
        return resolved^

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
](var store: S, var cluster: String) -> ErasedScanSourceResolver:
    """The product resolver for `komira.broker.topic`, erased for
    `ScanSourceResolvers.register` / `EngineContext.register_scan_kind`."""
    return ErasedScanSourceResolver(BrokerScanRuntime[S](store^, cluster^))


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
