# =============================================================================
# komira_broker/partition_merge_driver.mojo
#   Dynamic partition scaling, scale-IN DRIVER — the OPPORTUNISTIC merge
#   MAINTENANCE SCAN: the production caller that AUTONOMOUSLY detects sustained-
#   cold adjacent ranges + fires the merge. The scale-IN counterpart to the SDK
#   producer's `_maybe_propose_split` write-path driver.
# =============================================================================
#
# The merge trigger is a CAS on the partition map by whoever notices, with
# hysteresis and a conservative merge band. A low-load topic may have producers
# too quiet to run a flush-path check, so merges ride a piggybacked maintenance
# pass — run opportunistically by any producer on topic-open, by the Kafka
# server's metadata refresh, or by a periodic job in the deployment (NOT an
# always-on service). Merges are non-urgent, so a slow cadence is fine.
#
# -----------------------------------------------------------------------------
# THE INVOCATION-POINT DECISION (why a SCAN, not the flush path)
# -----------------------------------------------------------------------------
# Split is driven on the WRITE PATH (the SDK producer's `_maybe_propose_split`
# after each flush): a HOT partition is, by definition, the one being written to,
# so the producer that just flushed it is exactly the actor positioned to notice
# + propose the split. Merge is the DUAL but its trigger condition is the
# OPPOSITE: a COLD partition is one NOT being written to, so a flush-path check
# would never run for it (no flush => no check). Therefore merge cannot ride the
# flush path; it must be an OPPORTUNISTIC SCAN over the live partition set, run:
#   * at topic-OPEN (any producer/consumer that opens the topic runs one scan —
#     the SDK producer wires this in `init_sink`), and/or
#   * as a deployment maintenance entrypoint (a CronJob calling
#     `run_merge_maintenance_scan` on a slow cadence — NOT an always-on daemon).
#
# The partition_map CAS is the coordinator (exactly as for split): no leader
# election, no scaler service. Many openers may scan concurrently; exactly one
# wins each merge's If-Match CAS (`merge_topic_if_eligible`); the losers see the
# pair already retired and treat it as a clean no-op. CONSERVATIVE by design
# (`evaluate_merge` gates on BOTH ranges cold + the min-partitions floor + the
# anti-flap recently-split guard) so a scan does not flap a topic.
#
# -----------------------------------------------------------------------------
# THE COLD SIGNAL — MANIFEST-DERIVED, NOT a `_loadstat` sidecar
# -----------------------------------------------------------------------------
# Mirrors the split trigger (`partition_trigger.mojo`): the load signal is the
# partition manifest's `next_offset` (its committed record count since its
# lineage base), read straight off `CasManifestStore.read_head()`. A cold
# partition has a SMALL `next_offset` (below the merge `T_low` band). No
# `_loadstat` PUT is needed — the manifest already carries the count. The scan
# reads each candidate partition's head once (a metadata GET, on the cold
# maintenance path — not a hot loop). A never-created child manifest reads as
# `ManifestHead.empty()` (next_offset == 0 == maximally cold).
#
# -----------------------------------------------------------------------------
# THE ANTI-FLAP "recently split" SIGNAL
# -----------------------------------------------------------------------------
# A range that is ITSELF a recent split child still carries its split back-edge
# (`HashRange.parent_split_offset != NO_PARENT_BASE`). With the default policy
# (`allow_recently_split == False`), `evaluate_merge` SKIPS any pair where either
# range is a recent split child, so a split-then-immediately-merge flap cannot
# happen. The driver derives `a_recently_split`/`b_recently_split` from each live
# range's split back-edge and passes them to `evaluate_merge`.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature — the surface is value / POD / List.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * The scan reads the map + per-partition heads (value/POD) and returns a POD
#     result struct; it never holds or passes a raw pointer.
#   * Every type here is a stack value, never a byte-slab element.
# =============================================================================

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.store import CloneableConditionalWriteStore

from .broker_core import _manifest_prefix
from .partition_map import (
    PartitionMap,
    HashRange,
    NO_PARENT_BASE,
    PARTITION_MODE_AUTO,
    read_partition_map,
)
from .partition_merge import (
    MergeResult,
    merge_topic_if_eligible,
)
from .partition_trigger import (
    AutoMergePolicy,
    MergeDecision,
    evaluate_merge,
    MERGE_DECISION_PROPOSE,
)


# =============================================================================
# MergeScanResult — what one opportunistic maintenance scan accomplished. POD.
# =============================================================================


@fieldwise_init
struct MergeScanResult(Copyable, Movable, Deinitable):
    """The outcome of one `run_merge_maintenance_scan` pass over a topic. POD.

    Field layout:
      var pairs_examined: Int   — number of adjacent live pairs the scan
                                  inspected (read each side's cold signal +
                                  ran `evaluate_merge`).
      var merges_proposed: Int  — number of pairs `evaluate_merge` returned
                                  PROPOSE for (the scan then called
                                  `merge_topic_if_eligible` for each).
      var merges_landed: Int    — number of merges this scan's proposal LANDED
                                  (won the If-Match CAS). A concurrent scan/merge
                                  that won first makes our proposal a clean no-op
                                  (counted in proposed, not landed).
      var final_version: Int    — the partition map version after the scan (==
                                  starting version + merges_landed).
      var final_live_count: Int — the live partition count after the scan (drops
                                  by `merges_landed`).
    """

    var pairs_examined: Int
    var merges_proposed: Int
    var merges_landed: Int
    var final_version: Int
    var final_live_count: Int


# =============================================================================
# _range_is_recently_split — the anti-flap signal.
# =============================================================================


@always_inline
def _range_is_recently_split(r: HashRange) -> Bool:
    """True iff this live range is ITSELF a recent split child — it still carries
    a split back-edge (`parent_split_offset != NO_PARENT_BASE`). The anti-
    flap signal: with the default merge policy, a recently-split range is NOT
    merge-eligible, so a split-then-immediately-merge flap cannot happen. A
    merged child (no split back-edge) or an original range reads False."""
    return r.parent_split_offset != NO_PARENT_BASE


# =============================================================================
# _partition_record_count — the cold signal (manifest-derived).
# =============================================================================


def _partition_record_count[
    Store: CloneableConditionalWriteStore
](store: Store, cluster: String, topic: String, pid: Int) raises -> Int64:
    """Read partition `pid`'s committed record count == its manifest
    `read_head().next_offset` (its `next_offset` since its lineage base). This is
    the COLD signal `evaluate_merge` bands against `T_low` — manifest-derived,
    no `_loadstat` sidecar (mirrors the split trigger). A never-created child
    manifest reads `ManifestHead.empty()` (next_offset == 0 == maximally cold).

    `store` is cloned for the manifest handle (the clone shares the same
    underlying S3 bucket / in-memory map) so the caller's `store` stays usable."""
    var prefix = _manifest_prefix(cluster, topic, Int64(pid))
    var manifest = CasManifestStore[Store](
        store=store.clone(),
        prefix=prefix^,
        retry=RetryPolicy.default(),
    )
    # A correctness consumer of the tail: read_head() prefers the stale-low
    # local cache, so this must LIST the authoritative
    # tail. This scan builds a FRESH `CasManifestStore` per candidate (empty local
    # `_HEAD` cache, cold by construction), so `read_head()` would read the DURABLE
    # `_HEAD` whose advance is deferred off the warm-append ack path (lags by up to
    # `_HEAD_ADVANCE_DEFER_CADENCE` records). A stale-low `next_offset` UNDER-reports
    # the partition's record count -> the merge-IN trigger would wrongly band a busy
    # partition as cold (or suppress a genuinely-cold merge). Suppression is benign
    # (conservative), but read the LIST-recovered authoritative tail for a correct,
    # consistent cold signal.
    var head = manifest.read_head_authoritative()
    _ = manifest^
    return head.next_offset


# =============================================================================
# run_merge_maintenance_scan — the OPPORTUNISTIC scale-IN DRIVER (the keystone).
# =============================================================================


def run_merge_maintenance_scan[
    Store: CloneableConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    policy: AutoMergePolicy,
    max_merges_per_scan: Int = 4,
) raises -> MergeScanResult:
    """The OPPORTUNISTIC scale-IN maintenance scan — the PRODUCTION caller that
    AUTONOMOUSLY detects sustained-cold adjacent ranges + fires the merge (the
    dual of the producer write-path split driver `_maybe_propose_split`).

    Mechanics:
      1. Read the live partition map (a metadata GET — the cold maintenance
         path, not a hot loop). If the map is `fixed` (a Kafka topic NEVER
         merges) or has < 2 live partitions (nothing to merge),
         return a no-op result.
      2. Walk adjacent live pairs (i, i+1) — the ranges list is kept in ascending
         `hash_lo` order, so consecutive indices ARE adjacent ranges (A the lower
         neighbor of B). For each pair:
         a. Read each side's COLD signal (`_partition_record_count` ==
            manifest `next_offset`) + each side's anti-flap
            `recently_split` flag.
         b. `evaluate_merge(policy, a_records, b_records, live_count, ...)` — the
            PURE conservative decision (BOTH cold, above the min-partitions floor,
            neither recently split unless `allow_recently_split`).
         c. On PROPOSE, build the two predecessor manifests + call
            `merge_topic_if_eligible(A, B)` — the IDEMPOTENT If-Match CAS. On a
            landed merge, the live map CHANGED (ranges shrank by one, indices
            shifted): RE-READ the map + restart the adjacent-pair walk from the
            top (so the post-merge ranges are re-evaluated against the now-lower
            live count). Bounded by `max_merges_per_scan` so one scan cannot
            collapse a topic in a single pass (conservative cadence — a topic
            that should shrink further does so on the NEXT scan).
      3. A `merge_topic_if_eligible` that returns `None` (the pair was already
         retired by a concurrent scan/merge between our read + our CAS) is a
         clean no-op (counted in proposed, not landed) — the "whoever notices
         proposes" model means many openers may scan concurrently; exactly one
         wins each merge's CAS.

    NO always-on daemon: this is called OPPORTUNISTICALLY — by a producer/consumer
    at topic-OPEN, or by a deployment maintenance CronJob on a slow cadence. The
    partition_map CAS is the coordinator (same as split); no leader election.

    `store` is cloned (`Store: CloneableConditionalWriteStore` — its `clone()`
    shares the same underlying bucket / in-memory map) for each manifest/merge
    op, since each `CasManifestStore` + each `merge_topic_if_eligible` consumes
    its store; the caller's `store` stays usable. No raw connection handle is
    aliased across ops.

    Returns a `MergeScanResult` (pairs examined, merges proposed/landed, final
    map version + live count). Raises only on a genuine error (a non-idempotent
    merge failure: persistent CAS contention) — a `fixed`-mode topic or a
    too-small topic is a clean no-op result, not an error."""
    var pairs_examined = 0
    var merges_proposed = 0
    var merges_landed = 0

    # Step 1: read the live map.
    var map = read_partition_map[Store](store.clone(), cluster, topic)

    # A fixed (Kafka) topic never merges; a < 2-partition topic has nothing to
    # merge. Either way: a clean no-op scan.
    if map.mode != PARTITION_MODE_AUTO or map.num_partitions() < 2:
        return MergeScanResult(
            pairs_examined=0,
            merges_proposed=0,
            merges_landed=0,
            final_version=map.version,
            final_live_count=map.num_partitions(),
        )

    # Step 2: walk adjacent live pairs; on a landed merge, re-read + restart.
    var scan_again = True
    while scan_again:
        scan_again = False
        var n = map.num_partitions()
        var i = 0
        while i + 1 < n:
            # The pair (i, i+1): A the lower neighbor, B the upper neighbor.
            # Snapshot the per-range fields into locals up front (the `ref`
            # borrows must NOT span the `map` reassignment that a landed merge
            # below performs — copy out, then drop the borrows).
            var pid_a = map.ranges[i].pid
            var pid_b = map.ranges[i + 1].pid
            var a_recently = _range_is_recently_split(map.ranges[i])
            var b_recently = _range_is_recently_split(map.ranges[i + 1])
            pairs_examined += 1

            # Step 2a: the cold signal (manifest-derived) for each side.
            var a_records = _partition_record_count[Store](
                store.clone(), cluster, topic, pid_a
            )
            var b_records = _partition_record_count[Store](
                store.clone(), cluster, topic, pid_b
            )

            # Step 2b: the PURE conservative decision.
            var decision = evaluate_merge(
                policy,
                a_records,
                b_records,
                n,
                a_recently,
                b_recently,
            )
            if decision.kind != MERGE_DECISION_PROPOSE:
                i += 1
                continue

            # Step 2c: PROPOSE via the idempotent If-Match CAS.
            merges_proposed += 1
            var manifest_a = CasManifestStore[Store](
                store=store.clone(),
                prefix=_manifest_prefix(cluster, topic, Int64(pid_a)),
                retry=RetryPolicy.default(),
            )
            var manifest_b = CasManifestStore[Store](
                store=store.clone(),
                prefix=_manifest_prefix(cluster, topic, Int64(pid_b)),
                retry=RetryPolicy.default(),
            )
            var res = merge_topic_if_eligible[Store](
                store.clone(),
                cluster,
                topic,
                manifest_a^,
                manifest_b^,
                pid_a,
                pid_b,
            )
            if res:
                merges_landed += 1
                # The map changed (A,B retired, fresh child C). Re-read + restart
                # the adjacent walk so post-merge ranges re-evaluate against the
                # now-lower live count. Bounded by max_merges_per_scan.
                map = read_partition_map[Store](
                    store.clone(), cluster, topic
                )
                if merges_landed < max_merges_per_scan:
                    scan_again = True
                break  # restart the outer while with the fresh map.
            # res is None: a concurrent scan/merge already merged this pair — a
            # clean no-op. Advance past it (its old indices are gone next read,
            # but this scan's local map still has them; skip forward).
            i += 1

    return MergeScanResult(
        pairs_examined=pairs_examined,
        merges_proposed=merges_proposed,
        merges_landed=merges_landed,
        final_version=map.version,
        final_live_count=map.num_partitions(),
    )
