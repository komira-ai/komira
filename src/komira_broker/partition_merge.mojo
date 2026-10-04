# =============================================================================
# komira_broker/partition_merge.mojo
#   Dynamic partition scaling — the MERGE (scale-IN) mechanism. The DUAL of
#   partition_split.mojo.
# =============================================================================
#
# Merge lineage, lineage depth and the compaction collapse. Split provides
# scale-OUT; THIS module provides scale-IN, which together with the
# lineage-collapse compaction completes the elastic story.
#
# -----------------------------------------------------------------------------
# WHAT THIS MODULE PROVIDES
# -----------------------------------------------------------------------------
#   1. `merge_topic` — the data-plane MERGE orchestration (DUAL of `split_topic`):
#      read BOTH adjacent parents' manifest HEADs -> their freeze offsets Xa, Xb;
#      CAS the topic's `partition_map.json` via `If-Match` (`map.merge_at(A, B,
#      Xa, Xb)`); on a CAS miss re-read + re-evaluate. Neither parent manifest is
#      touched (they just stop receiving routes because the new map routes
#      `[lo, hi)` to the single merged child C, never to A/B); C gets a FRESH pid
#      => a fresh manifest prefix. The parents' pre-merge data STAYS in their
#      manifests — it is NOT copied/rewritten (cheap merge: lineage by reference,
#      PURE METADATA).
#
#   2. `merge_topic_if_eligible` — the IDEMPOTENT merge proposal (the trigger's
#      entry point): returns `None` (no error) if A or B is ALREADY RETIRED — a
#      concurrent producer's proposal already merged them (no double-merge). Only
#      a genuine error (fixed-mode, non-adjacent, persistent CAS contention)
#      propagates.
#
#   3. `MergeResult` — what a merge returns (the freeze offsets + the child pid).
#
# The lineage READ ORDER over a merge is handled by `build_lineage_read_order`
# in `partition_split.mojo` (it already enumerates the lineage FOREST — live
# leaves + retired parents/predecessors — in topological order, parents-before-
# children; `_depth_of` takes the MERGE fan-in edge). A whole-
# topic consumer reads each forest manifest FULLY exactly once; the two merge
# predecessors A,B are RANGE-PURE (disjoint subranges) so they need NO per-row
# filter (unlike a split parent, which holds both children's rows).
#
# -----------------------------------------------------------------------------
# THE EXACTLY-ONCE ARGUMENT FOR MERGE (the correctness keystone — read this)
# -----------------------------------------------------------------------------
# A record lives in EXACTLY ONE partition manifest, across a merge:
#   * Before A,B merge, every record routed to A's subrange `[lo, mid)` lands in
#     A's manifest; every record routed to B's `[mid, hi)` lands in B's manifest.
#     A key is in exactly ONE of A/B (disjoint subranges) — never both.
#   * At the merge, A and B are frozen (the new map routes `[lo, hi)` to the
#     merged child C, NEVER to A or B). So A's manifest holds the complete
#     pre-merge history for `[lo, mid)`, B's for `[mid, hi)`; both grow no further.
#   * After the merge, a record anywhere in `[lo, hi)` routes to C's manifest. A
#     record NEVER lands in two manifests.
#
# Therefore a WHOLE-TOPIC drain that reads EVERY forest manifest (every retired
# predecessor + every live leaf) FULLY yields every record EXACTLY ONCE — no
# loss, no dup, no gap.
#
# ORDERING across the merge boundary: a key `k` was in exactly one
# of A/B (say A, hash `hk ∈ [lo, mid)`). `k`'s full ordered history is: A's
# records for `k` (read first, from A's manifest) then C's records for `k` (read
# after, from C's manifest). `k` never appears in B. So `k`'s total order is
# A-prefix-then-C-suffix — exactly produce order, NO cross-key interleave (A and
# B are disjoint, so a key from A never interleaves with a key from B at the
# boundary). The read-order builder reads BOTH predecessors before the child
# (both A,B have strictly lower lineage depth than C), so every predecessor's
# records precede the child's.
#
# THE STRADDLE-THE-FREEZE-OFFSET SUBTLETY: the recorded freeze
# offsets Xa, Xb are LOWER BOUNDS. A producer mid-flush to A when the map flips
# may land a record at A's manifest tail Xa' >= Xa. Because the drain reads A's
# manifest to its ACTUAL `read_head().next_offset` (NOT the map's Xa), that
# in-flight record is STILL read once, before C's records. The manifest is
# authoritative; the map's X is a hint.
#
# -----------------------------------------------------------------------------
# COMPACTION (lineage-collapse) — see
# partition_compaction.mojo. The merge predecessors are already range-pure, so
# only a SPLIT parent ever needs compaction; that lives in its own module
# (it needs the segment-decode seam). This file is metadata-only.
#
# -----------------------------------------------------------------------------
# Encapsulation discipline
# -----------------------------------------------------------------------------
#   * ZERO UnsafePointer in any signature — the surface is value / POD / List.
#   * ZERO wildcard origins / `unsafe_from_address` / `take_pointee`.
#   * The map + lineage + read-order are plain Movable+Copyable values.
#   * Every type here is a stack value (POD lists), never a byte-slab
#     element with a wildcard cast.
# =============================================================================

from komira_objectstore.cas_manifest import CasManifestStore
from komira_objectstore.store import ConditionalWriteStore

from .partition_map import (
    PartitionMap,
    RetiredRange,
    read_partition_map_with_etag,
    try_persist_update,
)


# =============================================================================
# MergeResult — what a merge returns (the freeze offsets + the child pid).
# =============================================================================


@fieldwise_init
struct MergeResult(Copyable, Movable, Deinitable):
    """The result of a successful `merge_topic`. POD.

    Field layout:
      var parent_a_pid: Int       — the (now retired/frozen) lower-subrange
                                    predecessor pid A (`[lo, mid)`).
      var parent_b_pid: Int       — the (now retired/frozen) upper-subrange
                                    predecessor pid B (`[mid, hi)`).
      var child_pid: Int          — the FRESH merged child pid C (`[lo, hi)`).
      var frozen_a_offset: Int64  — A's freeze offset Xa (A's `next_offset` at
                                    merge time). A LOWER BOUND on A's tail.
      var frozen_b_offset: Int64  — B's freeze offset Xb. A LOWER BOUND on B's
                                    tail.
      var new_version: Int        — the map version after the merge (== old + 1).
      var cas_attempts: Int       — how many CAS attempts the merge took (1 == no
                                    contention; >1 == lost the CAS + retried).
    """

    var parent_a_pid: Int
    var parent_b_pid: Int
    var child_pid: Int
    var frozen_a_offset: Int64
    var frozen_b_offset: Int64
    var new_version: Int
    var cas_attempts: Int


# =============================================================================
# merge_topic — the data-plane MERGE orchestration (freeze A,B at Xa,Xb + CAS).
# =============================================================================


def merge_topic[
    Store: ConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    var parent_a_manifest: CasManifestStore[Store],
    var parent_b_manifest: CasManifestStore[Store],
    pid_a: Int,
    pid_b: Int,
    max_cas_attempts: Int = 8,
) raises -> MergeResult:
    """Explicitly merge two ADJACENT live partitions A=`pid_a` + B=`pid_b` of
    `topic` into ONE child C (the DUAL of `split_topic`). A must be the LOWER
    neighbor of B (A=`[lo, mid)`, B=`[mid, hi)`).

    Steps:
      1. Read BOTH parents' manifest HEADs -> the freeze offsets
         `Xa = A.next_offset`, `Xb = B.next_offset` (each parent's committed
         offset count). The parents FREEZE here: A holds `[0, Xa)`, B holds
         `[0, Xb)`; the child C holds offsets from its own base 0 onward. Neither
         parent manifest is written — freezing is achieved by the map no longer
         routing to A/B.
      2. Read the topic's partition map + its ETag.
      3. Compute `map.merge_at(pid_a, pid_b, Xa, Xb)` (replace the A,B pair with
         a single child C carrying both merge back-edges, version++, BOTH parents
         tombstoned in `retired`).
      4. CAS-persist the new map via `If-Match` on the ETag. On a CAS MISS
         (a concurrent merge/split won), re-read the map+ETag and re-evaluate
         (up to `max_cas_attempts`). The parents' manifests are unchanged — their
         pre-merge data stays exactly where it is (cheap merge: no data movement).

    `parent_a_manifest` / `parent_b_manifest` are the parents' `CasManifestStore`s
    (already bound to each parent's manifest prefix by the caller). They are
    consumed (moved in) because we only read each head once.

    Raises if A or B is not a live partition, if the map is `fixed` (a Kafka
    topic NEVER merges), if A,B are not adjacent in (lower, upper)
    order, or if the CAS loses `max_cas_attempts` times (persistent contention —
    surface rather than spin forever)."""
    # Step 1: read both parents' manifest heads -> the freeze offsets Xa, Xb.
    # A correctness consumer of the tail: read_head() prefers the
    # stale-low local cache, so this must LIST the authoritative
    # tail. The merge runs from a maintenance/cold-cache instance (the parent
    # manifests are rebuilt by the caller for this op, so their local `_HEAD` caches
    # are empty), so `read_head()` would read each DURABLE `_HEAD` whose advance is
    # deferred off the warm-append ack path (lags by up to
    # `_HEAD_ADVANCE_DEFER_CADENCE` records). Each freeze offset MUST be that
    # parent's TRUE tail (`next_offset`): a stale-low Xa/Xb freezes a parent below
    # its real committed tail, straddling records at the merge boundary (torn
    # offsets). The manifest is authoritative; LIST-recover BOTH heads
    # to enforce that contract.
    var head_a = parent_a_manifest.read_head_authoritative()
    var frozen_a = head_a.next_offset
    _ = parent_a_manifest^
    var head_b = parent_b_manifest.read_head_authoritative()
    var frozen_b = head_b.next_offset
    _ = parent_b_manifest^

    # Steps 2-4: read-modify-CAS the map, retrying on CAS miss.
    var attempt = 0
    while attempt < max_cas_attempts:
        attempt += 1
        var cur = read_partition_map_with_etag[Store](store, cluster, topic)
        var new_map = cur.map.merge_at(pid_a, pid_b, frozen_a, frozen_b)
        # Capture the child pid the merge allocated (from the new map's last
        # retired entry — `merge_at` appends two predecessors, both with the same
        # merged_into_pid == the child).
        var rn = len(new_map.retired)
        ref t = new_map.retired[rn - 1]
        var child = t.merged_into_pid
        var new_version = new_map.version
        var ok = try_persist_update[Store](
            store, cluster, topic, new_map, cur.etag
        )
        if ok:
            return MergeResult(
                parent_a_pid=pid_a,
                parent_b_pid=pid_b,
                child_pid=child,
                frozen_a_offset=frozen_a,
                frozen_b_offset=frozen_b,
                new_version=new_version,
                cas_attempts=attempt,
            )
        # CAS miss: a concurrent scale event moved the map. Re-read + re-evaluate.
        # The freeze offsets are re-usable (the parents never grew once a
        # concurrent merge froze them); but if the concurrent event already
        # retired A or B, `merge_at` raises "not a LIVE partition" on the next
        # loop — which is correct (someone else merged them; intent satisfied).
    raise Error(
        "merge_topic: CAS lost "
        + String(max_cas_attempts)
        + " times for pids "
        + String(pid_a)
        + "+"
        + String(pid_b)
        + " (persistent partition-map contention)"
    )


# =============================================================================
# merge_topic_if_eligible — the IDEMPOTENT merge proposal (the trigger's entry).
# =============================================================================


def merge_topic_if_eligible[
    Store: ConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    var parent_a_manifest: CasManifestStore[Store],
    var parent_b_manifest: CasManifestStore[Store],
    pid_a: Int,
    pid_b: Int,
    max_cas_attempts: Int = 8,
) raises -> Optional[MergeResult]:
    """Propose a merge of A+B, returning `None` (instead of raising) if A or B is
    ALREADY RETIRED or NO LONGER ADJACENT — i.e. a concurrent scale event already
    merged/split them. This is the trigger's entry point: the "whoever notices
    proposes" model means many producers / a maintenance tick may propose the
    same merge; exactly one wins the If-Match CAS, and the losers must treat
    "A/B no longer a mergeable adjacent live pair" as a clean no-op (no double-
    merge), NOT an error.

    Mechanics: the FIRST read of the map decides eligibility. If A and B are not
    BOTH live + adjacent at proposal time, return `None` immediately. Otherwise
    delegate to `merge_topic` (which re-reads + re-CASes on a CAS miss); if
    `merge_topic` ultimately raises because A/B got retired mid-retry, that too
    is a clean `None`. A non-eligibility error (fixed-mode, persistent CAS
    contention) propagates — those are real conditions the caller must see."""
    # Eligibility pre-check: read the map; if A,B are not a live adjacent pair,
    # a concurrent event already changed them — clean no-op.
    var cur = read_partition_map_with_etag[Store](store, cluster, topic)
    if not _is_live_adjacent_pair(cur.map, pid_a, pid_b):
        _ = parent_a_manifest^
        _ = parent_b_manifest^
        return Optional[MergeResult](None)

    try:
        var res = merge_topic[Store](
            store,
            cluster,
            topic,
            parent_a_manifest^,
            parent_b_manifest^,
            pid_a,
            pid_b,
            max_cas_attempts,
        )
        return Optional[MergeResult](res^)
    except e:
        if _is_merge_noop_error(String(e)):
            return Optional[MergeResult](None)
        raise e^


def _is_live_adjacent_pair(map: PartitionMap, pid_a: Int, pid_b: Int) -> Bool:
    """True iff `pid_a` and `pid_b` are BOTH live ranges with A the immediate
    lower neighbor of B (consecutive ascending indices). The eligibility gate
    for an idempotent merge proposal."""
    var ia = map._range_index_for_pid(pid_a)
    var ib = map._range_index_for_pid(pid_b)
    return ia >= 0 and ib == ia + 1


def _is_merge_noop_error(msg: String) -> Bool:
    """True iff a `merge_at` Error is a "concurrent event already changed A/B"
    race (a concurrent merge/split retired or re-ordered the pair) — the ONLY
    merge errors the idempotent proposal swallows as a no-op. The "fixed-mode"
    + "CAS lost N times" errors do NOT match (they are surfaced)."""
    return (
        msg.find("not a LIVE partition") >= 0
        or msg.find("not ADJACENT") >= 0
        or msg.find("already retired") >= 0
        or msg.find("not contiguous") >= 0
    )
