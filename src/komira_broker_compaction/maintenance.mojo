# =============================================================================
# maintenance.mojo: the run-once maintenance library
# =============================================================================
#
# The library a scheduled maintenance program calls once per scheduler tick. It
# enumerates the cluster's topics, reads each topic's durable config, and
# dispatches the per-partition and per-topic maintenance drivers by policy:
#
#   cleanup.policy=delete (0)         -> RetentionPass.run            (per partition)
#   cleanup.policy=compact (1)        -> ProductionLogCleaner.run_once (per partition)
#   cleanup.policy=compact,delete (2) -> BOTH                          (per partition)
#   auto-mode topic (partition_map)   -> run_merge_maintenance_scan    (per topic)
#
# compact,delete topics: `ProductionLogCleaner.run_once` gates on
# `config.compacts()` only and has no delete arm. For a `compact,delete` topic
# the composition that matches Kafka semantics (compaction keeps the latest
# record per key, then retention reaps old chunks) is for THIS orchestrator to
# call both the cleaner and RetentionPass for that topic's partitions, rather
# than to add a delete arm inside `run_once`. That keeps `run_once` responsible
# for compaction only and `RetentionPass.run` for time and size GC only.
#
# -----------------------------------------------------------------------------
# A RUN-ONCE LIBRARY, NOT A DAEMON
# -----------------------------------------------------------------------------
# Maintenance is a run-once function an external scheduler invokes; the caller
# runs one pass and exits. There is no `while True` or sleep loop here. Any
# node or job can run maintenance through compare-and-swap on the object store;
# nothing stateful stays resident. Each driver is stateless over the manifest
# (a fresh snapshot per run), idempotent and safe to run concurrently (the
# per-partition manifest CAS and the partition_map CAS arbitrate races: a
# loser sees the work already done and treats it as a no-op).
#
# -----------------------------------------------------------------------------
# TOPIC ENUMERATION: BACKEND-AGNOSTIC
# -----------------------------------------------------------------------------
# Topics are discovered via `ObjectStore.list_with_delimiter(<cluster>/_meta/
# topics/)` (on the base trait every CloneableConditionalWriteStore provides).
# A topic's existence is marked by its config object at
# `<cluster>/_meta/topics/<topic>/config.json`.
#
# The two backends populate the listing differently, so a backend-agnostic
# enumeration must fold the topic set from BOTH return fields:
#   * On an S3-style store (which honors the `delimiter`) the topic comes back
#     as a `common_prefixes` entry (`<cluster>/_meta/topics/<topic>/`) and the
#     config.json is below the delimiter, so it is not in `objects`.
#   * The in-memory store ignores the delimiter (it returns all keys flat in
#     `objects`, with empty common_prefixes), so the config.json is in
#     `objects`.
# So both are unioned: each `common_prefixes` entry is folded (strip the
# trailing `/` to recover `<topic>`) and `objects` is scanned for `config.json`
# keys, de-duplicated. This is the same union shape as
# `sublineage_base_fold.enumerate_live_shards`. An `objects`-only enumeration
# finds zero topics on an S3-style store, so maintenance would silently not run
# against a durable bucket while the in-memory store's flat listing hid the
# bug.
#
# No UnsafePointer in any signature: the surface is values, String and List;
# the store is taken by value (generic over the store trait) and cloned for
# each per-partition and per-topic driver (CloneableConditionalWriteStore). No
# wildcard origins, no `unsafe_from_address`, no `take_pointee`.
# =============================================================================

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore

# The broker cores, retention and merge driver (`komira_broker`).
from komira_broker.broker_core import (
    BrokerTopicConfig,
    _topic_config_key,
    _manifest_prefix,
)
from komira_broker.consume_core import ConsumeCore
from komira_broker.log_compaction import (
    CompactionConfig,
    cleanup_policy_compacts,
    cleanup_policy_deletes,
)
from komira_broker.partition_merge_driver import run_merge_maintenance_scan
from komira_broker.partition_trigger import AutoMergePolicy
from komira_broker.retention import (
    RetentionPass,
    RetentionPolicy,
    RetentionResult,
)

# The sub-lineage fold and the sub-lineage-aware (contiguity-audited)
# retention. The maintenance pass drives them so that an enabled partition's
# per-shard tails fold into `_base` and the number of live-tail shards stays
# bounded. The rollout-metrics holder is the canary signal surface.
from komira_broker.sublineage_rollout_metrics import SubLineageRolloutMetrics
from komira_broker.sublineage_segment_fold import (
    SegmentBaseFold,
    SegmentFoldStats,
)
from komira_objectstore.sublineage_base_fold import (
    BASE_SHARD_ID,
    sublineage_prefix,
)

# The log-cleaner driver that re-encodes survivors lives in this package.
from .log_cleaner_driver import (
    ProductionLogCleaner,
    ProductionCleanResult,
)


# =============================================================================
# TopicMaintenanceResult — what one topic's maintenance accomplished. POD.
# =============================================================================


@fieldwise_init
struct TopicMaintenanceResult(Copyable, Movable, Deinitable):
    """The outcome of maintaining ONE topic. POD (all Int64 + String + a flat
    nested POD struct). Carried back to the caller for the summary log.

    Field layout:
      var topic: String                  — the topic name.
      var cleanup_policy: Int64          — the topic's cleanup.policy (0/1/2).
      var num_partitions: Int            — partition count from the config.
      var compaction_ran_partitions: Int — partitions the cleaner actually
                                           compacted (res.ran == True).
      var records_dropped: Int64         — total superseded/grace-dropped records
                                           across all compacted partitions.
      var retention_tombstoned: Int64    — total chunks retention tombstoned
                                           across all delete-arm partitions.
      var merge_examined: Int            — adjacent pairs the merge scan examined
                                           (0 for a non-auto topic).
      var merge_landed: Int              — merges this pass's scan landed.
    """

    var topic: String
    var cleanup_policy: Int64
    var num_partitions: Int
    var compaction_ran_partitions: Int
    var records_dropped: Int64
    var retention_tombstoned: Int64
    var merge_examined: Int
    var merge_landed: Int


# =============================================================================
# MaintenanceSummary — the whole-pass roll-up the caller logs.
# =============================================================================


struct MaintenanceSummary(Movable, Deinitable):
    """The aggregate result of ONE run-once maintenance pass over a cluster.

    Field layout:
      var topics_scanned: Int                 — topics the pass enumerated.
      var per_topic: List[TopicMaintenanceResult] — one entry per topic.
      var errors: List[String]                — per-topic soft errors (a topic
                                                whose maintenance raised is
                                                logged + SKIPPED so one bad
                                                topic never aborts the whole
                                                cluster pass; only a failure of the
                                                enumeration itself raises).
    """

    var topics_scanned: Int
    var per_topic: List[TopicMaintenanceResult]
    var errors: List[String]

    def __init__(out self):
        self.topics_scanned = 0
        self.per_topic = List[TopicMaintenanceResult]()
        self.errors = List[String]()

    @always_inline
    def total_records_dropped(self) -> Int64:
        var t = Int64(0)
        for i in range(len(self.per_topic)):
            t += self.per_topic[i].records_dropped
        return t

    @always_inline
    def total_retention_tombstoned(self) -> Int64:
        var t = Int64(0)
        for i in range(len(self.per_topic)):
            t += self.per_topic[i].retention_tombstoned
        return t

    @always_inline
    def total_merges_landed(self) -> Int:
        var t = 0
        for i in range(len(self.per_topic)):
            t += self.per_topic[i].merge_landed
        return t


# =============================================================================
# enumerate_topics — discover the cluster's topic names from the store.
# =============================================================================


def _topics_prefix(cluster: String) -> String:
    """The metadata prefix every topic's config + manifests live under:
    `<cluster>/_meta/topics/`."""
    return cluster + "/_meta/topics/"


def _topic_name_from_config_key(key: String, prefix: String) -> String:
    """Given a config-object key `<cluster>/_meta/topics/<topic>/config.json`
    and the `<cluster>/_meta/topics/` prefix, extract `<topic>` (the path
    segment between the prefix and the next `/`). Returns "" if `key` is not a
    config.json under `prefix` (so the caller can skip non-config objects —
    partition_map.json, per-partition manifests, etc.)."""
    var suffix = String("/config.json")
    # Must start with the prefix AND end with /config.json.
    if not key.startswith(prefix):
        return String("")
    if not key.endswith(suffix):
        return String("")
    # The topic name is everything between `prefix` and the trailing
    # `/config.json`. Since a config key is `<prefix><topic>/config.json` and a
    # topic name carries no `/`, the middle is exactly the topic.
    var start = prefix.byte_length()
    var end = key.byte_length() - suffix.byte_length()
    if end <= start:
        return String("")
    var key_bytes = key.as_bytes()
    var mid = String(StringSlice(unsafe_from_utf8=key_bytes[start:end]))
    # Defensive: a well-formed config key has no `/` in the topic segment.
    if mid.find(String("/")) >= 0:
        return String("")
    return mid^


def _topic_name_from_common_prefix(cp: String, prefix: String) -> String:
    """Given a store-provided common-prefix `<cluster>/_meta/topics/<topic>/` and
    the `<cluster>/_meta/topics/` prefix, return `<topic>` (the segment up to the
    next `/`, which also strips the trailing `/`). Returns "" if `cp` does not
    start with `prefix` or has no topic segment. Mirrors
    `sublineage_base_fold._shard_from_common_prefix`."""
    if not cp.startswith(prefix):
        return String("")
    var start = prefix.byte_length()
    var cp_bytes = cp.as_bytes()
    var out = String("")
    var i = start
    while i < len(cp_bytes):
        var c = cp_bytes[i]
        if c == UInt8(47):  # '/'
            break
        out += chr(Int(c))
        i += 1
    return out^


def enumerate_topics[
    Store: CloneableConditionalWriteStore
](store: Store, cluster: String) raises -> List[String]:
    """Enumerate the cluster's topic names by listing `<cluster>/_meta/topics/`
    and folding the topic set from the listing.

    BACKEND-AGNOSTIC: UNIONS BOTH return fields, because the two backends
    populate the listing differently —
      * an S3-style store (delimiter honored) returns the topic as a
        `common_prefixes` entry (`<cluster>/_meta/topics/<topic>/`); its
        config.json is below the delimiter and is not in `objects`;
      * the in-memory store ignores the delimiter (all keys flat in `objects`,
        empty common_prefixes), so the config.json IS in `objects`.
    Folding `common_prefixes` (strip the trailing `/`) AND scanning `objects`
    for `config.json` keys resolves IDENTICALLY on both backends. (The earlier
    `objects`-only form found 0 topics on an S3-style store, silently
    disabling maintenance.) De-duplicated by membership (a config.json AND
    its common-prefix can both name the same topic); first-seen order. This is
    the same union shape as `sublineage_base_fold.enumerate_live_shards`."""
    var prefix = _topics_prefix(cluster)
    var listed = store.list_with_delimiter(Path.parse(prefix))
    var topics = List[String]()
    # (a) the common_prefixes branch — the S3-style path (delimiter honored).
    for i in range(len(listed.common_prefixes)):
        var name = _topic_name_from_common_prefix(
            listed.common_prefixes[i], prefix
        )
        if name.byte_length() == 0:
            continue
        _append_unique_topic(topics, name)
    # (b) the objects branch — the in-memory path (flat listing) + an S3 page
    # that happens to surface a config.json directly.
    for i in range(len(listed.objects)):
        var name = _topic_name_from_config_key(
            listed.objects[i].location, prefix
        )
        if name.byte_length() == 0:
            continue
        _append_unique_topic(topics, name)
    return topics^


def _append_unique_topic(mut topics: List[String], name: String):
    """Append `name` to `topics` iff not already present (membership de-dup —
    a topic can be named by BOTH its common-prefix and its config.json key)."""
    for j in range(len(topics)):
        if topics[j] == name:
            return
    topics.append(name)


# =============================================================================
# maintain_topic — the per-topic dispatcher (the policy switch).
# =============================================================================


def maintain_topic[
    Store: CloneableConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    now_ms: Int64,
    merge_policy: AutoMergePolicy,
) raises -> TopicMaintenanceResult:
    """Run the policy-appropriate maintenance for ONE topic:

      1. Read the topic config (cleanup.policy + retention + partition count).
      2. For each partition `0..num_partitions-1`:
         * cleanup.policy compacts (1 or 2) -> ProductionLogCleaner.run_once.
         * cleanup.policy deletes  (0 or 2) -> RetentionPass.run.
         (policy=delete runs only retention; policy=compact runs only the
          cleaner; policy=compact,delete runs BOTH; the orchestrate-both
          choice.)
      3. ALWAYS attempt the opportunistic merge scan (it is a clean no-op for a
         `fixed` / non-auto topic, or one with no partition_map). The merge scan
         reads the partition_map itself; a topic that never had a map raises
         inside `read_partition_map` -> we catch that as a clean no-op (most
         delete/compact topics have no partition_map).

    Each driver gets its OWN cloned store handle + freshly-bound CasManifestStore
    (CloneableConditionalWriteStore.clone() shares the same underlying bucket /
    map). All stateless + idempotent — safe to re-run + safe under concurrency."""
    var cfg_bytes = store.get(
        Path.parse(_topic_config_key(cluster, topic))
    )
    var cfg = BrokerTopicConfig.decode(cfg_bytes)
    var policy = cfg.cleanup_policy
    var np = cfg.num_partitions

    var compaction_ran = 0
    var records_dropped = Int64(0)
    var retention_tombstoned = Int64(0)

    var do_compact = cleanup_policy_compacts(policy)
    var do_delete = cleanup_policy_deletes(policy)

    var pid = 0
    while pid < np:
        var partition = Int64(pid)

        # --- compaction arm (cleanup.policy compact / compact,delete) ---
        if do_compact:
            var res = _run_compaction_for_partition[Store](
                store,
                cluster,
                topic,
                partition,
                cfg.delete_retention_ms,
                now_ms,
            )
            if res.ran:
                compaction_ran += 1
            records_dropped += res.dropped

        # --- retention arm (cleanup.policy delete / compact,delete) ---
        if do_delete:
            var rres = _run_retention_for_partition[Store](
                store,
                cluster,
                topic,
                partition,
                cfg.retention_ms,
                cfg.retention_bytes,
                now_ms,
            )
            retention_tombstoned += rres.tombstoned_count

        pid += 1

    # --- merge scan (auto-mode topic; clean no-op otherwise) ---
    var merge_examined = 0
    var merge_landed = 0
    try:
        var mres = run_merge_maintenance_scan[Store](
            store.clone(), cluster, topic, merge_policy
        )
        merge_examined = mres.pairs_examined
        merge_landed = mres.merges_landed
    except e:
        # A topic with no partition_map (most delete/compact topics never had
        # one) raises inside read_partition_map — a clean no-op for merge.
        # Re-raise only if it was NOT an absent-map / not-found (a genuine
        # transport / CAS error should surface).
        var msg = String(e)
        var is_absent = (
            msg.find("not_found") >= 0
            or msg.find("NotFound") >= 0
            or msg.find("404") >= 0
            or msg.find("NoSuchKey") >= 0
        )
        if not is_absent:
            raise e^

    return TopicMaintenanceResult(
        topic=topic,
        cleanup_policy=policy,
        num_partitions=np,
        compaction_ran_partitions=compaction_ran,
        records_dropped=records_dropped,
        retention_tombstoned=retention_tombstoned,
        merge_examined=merge_examined,
        merge_landed=merge_landed,
    )


def _run_compaction_for_partition[
    Store: CloneableConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    partition: Int64,
    delete_retention_ms: Int64,
    now_ms: Int64,
) raises -> ProductionCleanResult:
    """Build a ProductionLogCleaner for one partition + run a single tick. The
    cleaner needs a ConsumeCore (live read) + a segment store + a manifest, all
    from cloned store handles bound to the partition's manifest prefix."""
    var prefix = _manifest_prefix(cluster, topic, partition)
    var consume_manifest = CasManifestStore[Store](
        store=store.clone(), prefix=prefix, retry=RetryPolicy.default()
    )
    var consume = ConsumeCore[Store](
        segment_store=store.clone(),
        manifest=consume_manifest^,
        cluster=cluster,
        topic=topic,
        partition=partition,
    )
    var cleaner_manifest = CasManifestStore[Store](
        store=store.clone(), prefix=prefix, retry=RetryPolicy.default()
    )
    var cleaner = ProductionLogCleaner[Store](
        consume=consume^,
        segment_store=store.clone(),
        manifest=cleaner_manifest^,
        config=CompactionConfig.compact(delete_retention_ms),
        cluster=cluster,
        topic=topic,
        partition=partition,
        key_col=0,
        value_col=1,
    )
    var res = cleaner.run_once(now_ms)
    _ = cleaner^
    return res^


def _run_retention_for_partition[
    Store: CloneableConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    partition: Int64,
    retention_ms: Int64,
    retention_bytes: Int64,
    now_ms: Int64,
) raises -> RetentionResult:
    """Build a RetentionPass for one partition + run a single pass. The pass
    takes a `mut CasManifestStore` bound to the partition's manifest prefix."""
    var prefix = _manifest_prefix(cluster, topic, partition)
    var manifest = CasManifestStore[Store](
        store=store.clone(), prefix=prefix, retry=RetryPolicy.default()
    )
    var retention_pass = RetentionPass[Store](
        RetentionPolicy(retention_ms, retention_bytes)
    )
    var res = retention_pass.run(manifest, now_ms)
    _ = manifest^
    _ = retention_pass^
    return res^


# =============================================================================
# run_maintenance_pass: the run-once orchestrator (the library entry point).
# =============================================================================


def run_maintenance_pass[
    Store: CloneableConditionalWriteStore
](
    store: Store,
    cluster: String,
    now_ms: Int64,
    merge_policy: AutoMergePolicy = AutoMergePolicy.default(),
) raises -> MaintenanceSummary:
    """RUN ONCE: enumerate the cluster's topics + dispatch each topic's
    policy-appropriate maintenance, returning the aggregate summary. This is the
    function the caller invokes once per scheduler tick; there is no loop here.

    Per-topic isolation: a topic whose maintenance raises is logged into
    `summary.errors` + SKIPPED (one corrupt / mid-migration topic must never
    abort the whole cluster's maintenance). Only a failure of the topic
    ENUMERATION itself (a store-level transport error) propagates as a raise —
    that is a hard error for the caller.

    STATELESS + IDEMPOTENT + concurrency-safe: every driver reads a fresh
    manifest snapshot + arbitrates via CAS, so two schedulers (or a retry of a
    crashed pass) converge — a loser sees the work already done."""
    var summary = MaintenanceSummary()
    var topics = enumerate_topics[Store](store.clone(), cluster)
    summary.topics_scanned = len(topics)
    for i in range(len(topics)):
        ref topic = topics[i]
        try:
            var tres = maintain_topic[Store](
                store.clone(), cluster, topic, now_ms, merge_policy
            )
            summary.per_topic.append(tres^)
        except e:
            summary.errors.append(
                String("topic '") + topic + String("': ") + String(e)
            )
    return summary^


# =============================================================================
# The sub-lineage fold and sub-lineage-aware retention, wired into the
# run-once maintenance.
# =============================================================================
#
# WHAT THIS DOES.
# ---------------------------------------------------------------------------
# With sub-lineage mode on, an enabled (topic, partition) writes its records
# into per-shard sub-lineages (`<part>/_lineage/<shard>/`). Something has to
# fold those per-shard tails into the `_base` manifest; without a fold trigger
# the live-tail shard count grows without bound, and the consume-side LIST and
# merge fan-out climbs. This section drives the production `SegmentBaseFold`
# and the sub-lineage-aware `RetentionPass` (`run_with_rollout_audit`, the
# contiguity-audited retention), once per scheduler tick, over every enabled
# (topic, partition).
#
# OPT-IN.
# ---------------------------------------------------------------------------
# This pass runs only when the caller invokes `run_sublineage_maintenance_pass`
# (the caller gates it on the server-level sub-lineage flag). When the flag is
# off the caller runs only `run_maintenance_pass`, unchanged. Even when on, a partition with no
# `<part>/_lineage/` (a legacy or not-yet-migrated partition) enumerates zero
# source shards: `run_once` is a self-gating no-op (no `_base` written,
# `records_folded == 0`) and the `_base` retention sees an empty manifest, so it
# is a clean no-op. The pass is therefore safe to run over a cluster whose
# partitions are a mix of legacy and sub-lineage-enabled; it folds only the
# partitions that have sub-lineage data.
#
# IDEMPOTENT AND CRASH-SAFE.
# ---------------------------------------------------------------------------
# `SegmentBaseFold.run_once` is idempotent: each round folds only the live
# un-folded tail `[folded_count .. snap_total)`, materializes via single-writer
# If-None-Match CAS, and the `_base` contiguity check raises on a torn fold. A
# re-run after a crash re-derives `folded_count` from the durable source
# `_LOG_START` and folds only what is still un-folded (a no-op if the prior run
# completed). The `_base` retention `run_with_rollout_audit` is the same
# snapshot, evaluate, tombstone, advance (If-Match CAS) state machine the legacy
# retention uses (a re-run sees the already-advanced log_start and the
# already-tombstoned chunks, so it is a no-op). The whole maintenance
# invocation is therefore a no-op on a re-run after a crash.
#
# ENUMERATION.
# ---------------------------------------------------------------------------
# Topics are enumerated via `enumerate_topics`: it lists
# `<cluster>/_meta/topics/` and unions the `common_prefixes` entries (S3-style
# stores) and the `config.json` keys (the in-memory store) into the distinct
# `<topic>` set, so it finds runtime-created topics, not just static config.
# The `common_prefixes` branch is needed because on an S3-style store the
# config.json is below the delimiter; without it the pass enumerates zero
# topics and never runs. Per-partition fan-out comes from each topic's
# persisted `BrokerTopicConfig.num_partitions`.
# =============================================================================


@fieldwise_init
struct SubLineageTopicResult(Copyable, Movable, Deinitable):
    """The outcome of one topic's sub-lineage maintenance. POD.

    Field layout:
      var topic: String                  — the topic name.
      var num_partitions: Int            — partition count from the config.
      var folded_partitions: Int         — partitions that actually folded
                                           (records_folded > 0 this run).
      var records_folded: Int64          — total records folded into `_base`
                                           across all partitions this run.
      var source_chunks_retired: Int     — source chunks tombstoned this run.
      var base_retention_tombstoned: Int64 — `_base` chunks the sub-lineage-aware
                                           retention tombstoned across partitions.
    """

    var topic: String
    var num_partitions: Int
    var folded_partitions: Int
    var records_folded: Int64
    var source_chunks_retired: Int
    var base_retention_tombstoned: Int64


struct SubLineageMaintenanceSummary(Movable, Deinitable):
    """The aggregate result of ONE sub-lineage maintenance pass over a cluster.

    Field layout:
      var topics_scanned: Int                       — topics enumerated.
      var per_topic: List[SubLineageTopicResult]    — one entry per topic.
      var errors: List[String]                      — per-topic soft errors (a
                                                      topic whose sub-lineage
                                                      maintenance raised is logged
                                                      + SKIPPED — one bad topic
                                                      never aborts the pass).
    """

    var topics_scanned: Int
    var per_topic: List[SubLineageTopicResult]
    var errors: List[String]

    def __init__(out self):
        self.topics_scanned = 0
        self.per_topic = List[SubLineageTopicResult]()
        self.errors = List[String]()

    @always_inline
    def total_records_folded(self) -> Int64:
        var t = Int64(0)
        for i in range(len(self.per_topic)):
            t += self.per_topic[i].records_folded
        return t

    @always_inline
    def total_source_chunks_retired(self) -> Int:
        var t = 0
        for i in range(len(self.per_topic)):
            t += self.per_topic[i].source_chunks_retired
        return t

    @always_inline
    def total_base_retention_tombstoned(self) -> Int64:
        var t = Int64(0)
        for i in range(len(self.per_topic)):
            t += self.per_topic[i].base_retention_tombstoned
        return t


def maintain_topic_sublineage[
    Store: CloneableConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    now_ms: Int64,
    mut rollout: SubLineageRolloutMetrics,
) raises -> SubLineageTopicResult:
    """Run the sub-lineage maintenance for ONE topic's partitions:

      1. Read the topic config (num_partitions + retention).
      2. For each partition `0..num_partitions-1`:
         a. `SegmentBaseFold.run_once(now_ms)` — fold the per-shard
            `<part>/_lineage/<shard>/` tails into `<part>/_lineage/_base`,
            retire the folded sources, advance each source `_LOG_START`.
            (Self-gating: a partition with no `<part>/_lineage/` enumerates
             zero source shards -> a clean no-op.)
         b. Sub-lineage-aware retention over the folded `_base`:
            `RetentionPass.run_with_rollout_audit` (the contiguity-audited
            variant) bound to `<part>/_lineage/_base`, so the contiguity audit
            + the reap apply to the folded `_base` rather than the (now-retired)
            legacy single manifest.

    Each driver gets its OWN cloned store handle (CloneableConditionalWriteStore
    .clone() shares the same underlying bucket / map). All stateless +
    idempotent — safe to re-run + safe under concurrency."""
    var cfg_bytes = store.get(Path.parse(_topic_config_key(cluster, topic)))
    var cfg = BrokerTopicConfig.decode(cfg_bytes)
    var np = cfg.num_partitions

    var folded_partitions = 0
    var records_folded = Int64(0)
    var source_chunks_retired = 0
    var base_retention_tombstoned = Int64(0)

    var pid = 0
    while pid < np:
        var partition = Int64(pid)
        var base_prefix = _manifest_prefix(cluster, topic, partition)

        # (a) FOLD the per-shard tails into `_base`. Self-no-op for a legacy /
        # not-yet-migrated partition (zero `_lineage/` shards).
        var fres = _run_sublineage_fold_for_partition[Store](
            store, base_prefix, now_ms
        )
        if fres.records_folded > Int64(0):
            folded_partitions += 1
        records_folded += fres.records_folded
        source_chunks_retired += fres.source_chunks_retired

        # (b) Sub-lineage-aware retention over the folded `_base` (the
        # contiguity-audited canary variant). A partition that never folded has
        # an empty `_base` manifest -> a clean no-op (vacuously contiguous).
        var rres = _run_sublineage_base_retention_for_partition[Store](
            store,
            base_prefix,
            cfg.retention_ms,
            cfg.retention_bytes,
            now_ms,
            rollout,
        )
        base_retention_tombstoned += rres.tombstoned_count

        pid += 1

    return SubLineageTopicResult(
        topic=topic,
        num_partitions=np,
        folded_partitions=folded_partitions,
        records_folded=records_folded,
        source_chunks_retired=source_chunks_retired,
        base_retention_tombstoned=base_retention_tombstoned,
    )


def _run_sublineage_fold_for_partition[
    Store: CloneableConditionalWriteStore
](
    store: Store,
    base_prefix: String,
    now_ms: Int64,
) raises -> SegmentFoldStats:
    """Build a `SegmentBaseFold` for one partition + run ONE fold round. The
    fold is bound to the partition's base prefix
    (`<cluster>/_meta/topics/<topic>/<partition>`); it enumerates the live
    source sub-lineages under `<base>/_lineage/<shard>`, materializes their
    un-folded tails into `<base>/_lineage/_base` (reusing the source `.seg`
    objects), retires the folded sources + advances each source `_LOG_START`.
    A partition with no `<base>/_lineage/` enumerates zero shards -> a no-op."""
    var fold = SegmentBaseFold[Store](store.clone(), String(base_prefix))
    var res = fold.run_once(now_ms)
    _ = fold^
    return res^


def _run_sublineage_base_retention_for_partition[
    Store: CloneableConditionalWriteStore
](
    store: Store,
    base_prefix: String,
    retention_ms: Int64,
    retention_bytes: Int64,
    now_ms: Int64,
    mut rollout: SubLineageRolloutMetrics,
) raises -> RetentionResult:
    """Run the SUB-LINEAGE-AWARE retention pass over a partition's folded `_base`
    manifest (`<base>/_lineage/_base`). Uses `run_with_rollout_audit` (the
    contiguity-audited canary variant), so the live offset-contiguity audit +
    the reap apply to the folded `_base` — the same surface a sub-lineage-
    enabled partition's canary watches. Identical retire/advance/contiguity-
    fail-loud semantics as the legacy `run`; emits the audit signal into the
    live `rollout` holder."""
    var base_manifest = CasManifestStore[Store](
        store=store.clone(),
        prefix=sublineage_prefix(base_prefix, BASE_SHARD_ID),
        retry=RetryPolicy.default(),
    )
    var retention_pass = RetentionPass[Store](
        RetentionPolicy(retention_ms, retention_bytes)
    )
    var res = retention_pass.run_with_rollout_audit(
        base_manifest, now_ms, rollout
    )
    _ = base_manifest^
    _ = retention_pass^
    return res^


def run_sublineage_maintenance_pass[
    Store: CloneableConditionalWriteStore
](
    store: Store,
    cluster: String,
    now_ms: Int64,
) raises -> SubLineageMaintenanceSummary:
    """RUN ONCE (sub-lineage arm): enumerate the cluster's topics + for each
    sub-lineage-bearing (topic, partition) FOLD the per-shard tails into `_base`
    + run the sub-lineage-aware (contiguity-audited) retention over the folded
    `_base`. This is the function the caller invokes once per scheduler tick when
    sub-lineage mode is enabled, in addition to `run_maintenance_pass`; there is
    no loop here.

    Opt-in: the caller invokes this only when the server-level sub-lineage flag
    is set; otherwise it runs only `run_maintenance_pass`. Even when enabled, a partition with no
    `<part>/_lineage/` is a clean no-op (the fold enumerates zero shards, the
    `_base` retention sees an empty manifest).

    Per-topic isolation: a topic whose sub-lineage maintenance raises is logged
    into `summary.errors` + SKIPPED (one corrupt / mid-migration topic must
    never abort the whole cluster's fold). Only a failure of the topic
    ENUMERATION itself (a store-level transport error) propagates as a raise.

    STATELESS + IDEMPOTENT + concurrency-safe: every driver reads a fresh
    manifest snapshot + arbitrates via CAS, so two schedulers (or a retry of a
    crashed pass) converge — a loser sees the work already folded/retired."""
    var summary = SubLineageMaintenanceSummary()
    # The LIVE rollout-metrics canary holder for this pass — the fold L/F + the
    # `_base` contiguity audit emit into it (the operator's watch surface). One
    # holder per pass (maintenance is a run-once job; the holder's MetricsSet is
    # dropped at pass end). Constructing it is the only sub-lineage-specific
    # allocation; the legacy pass constructs nothing.
    var rollout = SubLineageRolloutMetrics()
    var topics = enumerate_topics[Store](store.clone(), cluster)
    summary.topics_scanned = len(topics)
    for i in range(len(topics)):
        ref topic = topics[i]
        try:
            var tres = maintain_topic_sublineage[Store](
                store.clone(), cluster, topic, now_ms, rollout
            )
            summary.per_topic.append(tres^)
        except e:
            summary.errors.append(
                String("topic '") + topic + String("': ") + String(e)
            )
    _ = rollout^
    return summary^
