# =============================================================================
# komira_broker/partition_split.mojo
#   Dynamic partition scaling — the SPLIT mechanism + the consumer
#   lineage-forest read order.
# =============================================================================
#
# The partition_map range structure, the split mechanism (freeze the parent at
# offset X + fork two children), the lineage, and the consumer lineage-follow
# model.
#
# This module is the split PRIMITIVE (explicitly invoked) + correct
# read-across-split. The automatic load-detection TRIGGER (deciding WHEN to
# split) is `partition_trigger`.
#
# -----------------------------------------------------------------------------
# WHAT THIS MODULE PROVIDES
# -----------------------------------------------------------------------------
#   1. `split_topic` — the data-plane SPLIT orchestration: read the parent
#      partition's manifest HEAD -> the freeze offset X (the parent's current
#      `next_offset`); CAS the topic's `partition_map.json` via `If-Match`
#      (`map.split_at(pid, X)`); on a CAS miss re-read + re-evaluate (a
#      concurrent split won). The parent manifest is NOT touched (it just stops
#      receiving routes because the new map no longer routes to it); the two
#      child partitions get FRESH manifest prefixes by virtue of their FRESH
#      pids. The parent's pre-split data `[0, X)` STAYS in the parent manifest —
#      it is NOT copied/rewritten (cheap split: lineage by reference, O(1) in
#      data).
#
#   2. `build_lineage_read_order` — the consumer's LINEAGE-FOREST read order:
#      given a map (live leaf ranges + retired parents), produce the list of
#      pids to read, in TOPOLOGICAL order (every PARENT before its CHILDREN).
#      A whole-topic consumer reads EACH pid's manifest FULLY, exactly once, in
#      this order. See "the exactly-once argument" below.
#
# -----------------------------------------------------------------------------
# THE EXACTLY-ONCE ARGUMENT (the correctness keystone — read this)
# -----------------------------------------------------------------------------
# A record lives in EXACTLY ONE partition manifest:
#   * Before pid P splits, every record routed to P's hash-range `[lo, hi)`
#     lands in P's manifest (offsets `[0, X)`).
#   * At the split, P is frozen (the new map routes `[lo, hi)` to children A/B,
#     NEVER to P). So P's manifest holds the COMPLETE pre-split history for
#     `[lo, hi)` and grows no further.
#   * After the split, a record in `[lo, mid)` routes to A's manifest, a record
#     in `[mid, hi)` routes to B's manifest. A record NEVER lands in both.
#
# Therefore a WHOLE-TOPIC drain that reads EVERY manifest in the lineage forest
# (every retired parent + every live leaf) FULLY, with NO row filtering, yields
# every record EXACTLY ONCE — no loss (every manifest is read), no duplication
# (each record is in exactly one manifest), no gap (each manifest is read
# fully). This is simpler + stronger than "re-filter the parent
# prefix to the child subrange" — that filtering is needed only by a SINGLE-
# CHILD consumer (which wants ONLY its subrange of the shared parent); a
# whole-topic consumer reads the parent ONCE (unfiltered) and both children, so
# the parent's records are emitted exactly once with no filtering at all.
#
# ORDERING across the parent->child boundary: we read every
# PARENT before its CHILDREN (topological order). For any key `k` in `[lo,mid)`,
# `k`'s records appear as: P's records for `k` (read first, from P's manifest)
# then A's records for `k` (read after, from A's manifest). Within each manifest
# append order is preserved. So `k`'s total order is P-prefix-then-A-suffix —
# exactly produce order. `k` never appears in B. No interleave ambiguity.
#
# THE STRADDLE-THE-FREEZE-OFFSET SUBTLETY: the freeze offset X
# recorded in the map is a LOWER BOUND. A producer mid-flush to P when the map
# flips may land a record at P's manifest tail X' >= X. Because we read P's
# manifest to its ACTUAL `read_head().next_offset` (NOT to the map's X), that
# in-flight record is STILL read (it is in P's manifest), exactly once, before
# the child records. The map's X is a hint/audit value; the manifest is
# authoritative — the SAME "manifest is authoritative, footer/hint is advisory"
# discipline the produce path already uses for pre-commit offsets. So NO record
# straddles or is lost at the boundary: a record is in P's manifest XOR a
# child's manifest, and we read both fully.
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
    HashRange,
    PartitionMap,
    RetiredRange,
    NO_PARENT_BASE,
    read_partition_map_with_etag,
    try_persist_update,
)


# =============================================================================
# SplitResult — what a split returns (the freeze offset + child pids).
# =============================================================================


@fieldwise_init
struct SplitResult(Copyable, Movable, Deinitable):
    """The result of a successful `split_topic`. POD.

    Field layout:
      var parent_pid: Int        — the (now retired/frozen) parent pid.
      var child_a_pid: Int       — the lower-subrange child pid (`[lo, mid)`).
      var child_b_pid: Int       — the upper-subrange child pid (`[mid, hi)`).
      var frozen_at_offset: Int64 — the freeze offset X (parent's `next_offset`
                                    at split time). A lower bound on the parent
                                    tail.
      var new_version: Int       — the map version after the split (== old + 1).
      var cas_attempts: Int      — how many CAS attempts the split took (1 == no
                                   contention; >1 == lost the CAS to a concurrent
                                   split + retried).
    """

    var parent_pid: Int
    var child_a_pid: Int
    var child_b_pid: Int
    var frozen_at_offset: Int64
    var new_version: Int
    var cas_attempts: Int


# =============================================================================
# split_topic — the data-plane SPLIT orchestration (freeze parent at X + CAS).
# =============================================================================


def split_topic[
    Store: ConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    var parent_manifest: CasManifestStore[Store],
    pid: Int,
    max_cas_attempts: Int = 8,
) raises -> SplitResult:
    """Explicitly split the LIVE partition `pid` of `topic` into two children at
    the hash-space midpoint (the explicitly-invoked split primitive).

    Steps:
      1. Read the parent partition's manifest HEAD -> the freeze offset
         `X = head.next_offset` (the parent's current committed offset count).
         This is the offset at which the parent FREEZES: it holds `[0, X)`; the
         children hold offsets from X onward. The parent manifest is NOT
         written — freezing is achieved by the map no longer routing to `pid`.
      2. Read the topic's partition map + its ETag.
      3. Compute `map.split_at(pid, X)` (replace pid's range with two children
         at the midpoint, fresh child pids, lineage recorded, version++, parent
         tombstoned in `retired`).
      4. CAS-persist the new map via `If-Match` on the ETag. On a CAS MISS
         (a concurrent split won), re-read the map+ETag and re-evaluate (up to
         `max_cas_attempts`). The parent's manifest is unchanged — its pre-split
         data `[0, X)` stays exactly where it is (cheap split: no data movement).

    `parent_manifest` is the parent partition's `CasManifestStore` (already
    bound to the parent's manifest prefix by the caller — the SAME prefix the
    producer's `BrokerCore` used for `pid`). It is consumed (moved in) because
    we only need to read its head once; the caller rebuilds it if it needs it
    again.

    Raises if `pid` is not a live partition, if the map is `fixed` (a Kafka
    topic NEVER splits), if the range is too narrow to split (the
    hot-key ceiling), or if the CAS loses `max_cas_attempts` times
    (persistent contention — surface rather than spin forever).
    """
    # Step 1: read the parent manifest head -> the freeze offset X.
    # A correctness consumer of the tail: read_head() prefers the
    # stale-low local cache, so this must LIST the authoritative
    # tail. The split runs from a maintenance/cold-cache instance (the
    # `parent_manifest` is rebuilt by the caller for this op, so its local `_HEAD`
    # cache is empty), so `read_head()` would read the DURABLE `_HEAD` whose advance
    # is deferred off the warm-append ack path (lags by up to
    # `_HEAD_ADVANCE_DEFER_CADENCE` records). The freeze offset X MUST be the
    # parent's TRUE tail (`next_offset`): a stale-low X freezes the parent below its
    # real committed tail, so records in `[stale_X, true_X)` straddle the boundary
    # (torn offsets at the split). The manifest is authoritative; the
    # LIST-recovered authoritative tail enforces exactly that contract.
    var head = parent_manifest.read_head_authoritative()
    var frozen_at = head.next_offset
    _ = parent_manifest^

    # Steps 2-4: read-modify-CAS the map, retrying on CAS miss.
    var attempt = 0
    while attempt < max_cas_attempts:
        attempt += 1
        var cur = read_partition_map_with_etag[Store](store, cluster, topic)
        var new_map = cur.map.split_at(pid, frozen_at)
        # Capture the child pids the split allocated (from the new map's last
        # retired entry — `split_at` appends exactly one).
        var rn = len(new_map.retired)
        ref t = new_map.retired[rn - 1]
        var child_a = t.child_a_pid
        var child_b = t.child_b_pid
        var new_version = new_map.version
        var ok = try_persist_update[Store](
            store, cluster, topic, new_map, cur.etag
        )
        if ok:
            return SplitResult(
                parent_pid=pid,
                child_a_pid=child_a,
                child_b_pid=child_b,
                frozen_at_offset=frozen_at,
                new_version=new_version,
                cas_attempts=attempt,
            )
        # CAS miss: a concurrent split moved the map. Re-read + re-evaluate. The
        # freeze offset X is re-usable (the parent never grew once frozen); but
        # if the concurrent split already retired `pid`, `split_at` raises
        # "not a LIVE partition" on the next loop — which is correct (someone
        # else split it; the caller's intent is satisfied).
    raise Error(
        "split_topic: CAS lost "
        + String(max_cas_attempts)
        + " times for pid "
        + String(pid)
        + " (persistent partition-map contention)"
    )


# =============================================================================
# split_topic_if_live — the IDEMPOTENT split proposal (increment 2's trigger).
# =============================================================================


def split_topic_if_live[
    Store: ConditionalWriteStore
](
    store: Store,
    cluster: String,
    topic: String,
    var parent_manifest: CasManifestStore[Store],
    pid: Int,
    max_cas_attempts: Int = 8,
) raises -> Optional[SplitResult]:
    """Propose a split of `pid`, returning `None` (instead of raising) if `pid`
    is ALREADY RETIRED — i.e. a concurrent producer's proposal already split it.
    This is the increment-2 auto-trigger's entry point: the "whoever's hot
    proposes" model means MANY producers may propose the same split; exactly one
    wins the If-Match CAS, and the losers must treat "pid no longer live" as a
    clean no-op (no double-split), NOT an error.

    Mechanics: the FIRST read of the map decides liveness. If `pid` is not a
    live range at proposal time (a concurrent split already retired it), return
    `None` immediately — the split the caller wanted has effectively happened.
    Otherwise delegate to `split_topic` (which itself re-reads + re-CASes on a
    CAS miss); if `split_topic` ultimately raises because the pid got retired
    mid-retry (a concurrent split won between our liveness read and our CAS),
    that too is a clean `None` (the intent is satisfied). A NON-liveness error
    (e.g. fixed-mode, too-narrow hot-key range, persistent CAS contention)
    propagates — those are real conditions the caller must see.

    The "too narrow to split" (hot-key ceiling) and "fixed-mode"
    errors are NOT swallowed: they are surfaced so the producer can emit the
    hot-key warning + stop re-proposing this range. Only the
    "pid-already-retired" race is treated as a no-op.
    """
    # Liveness pre-check: read the map; if pid is no longer a live range, a
    # concurrent split already retired it — clean no-op (no double-split).
    var cur = read_partition_map_with_etag[Store](store, cluster, topic)
    if cur.map._range_index_for_pid(pid) < 0:
        _ = parent_manifest^
        return Optional[SplitResult](None)

    # The pid is live as of our read; attempt the split. A concurrent split that
    # retires `pid` between here and our CAS makes `split_topic`'s retry loop hit
    # "not a LIVE partition" — catch that one race as a clean no-op; re-raise
    # every other error (fixed-mode, too-narrow hot-key, persistent contention).
    try:
        var res = split_topic[Store](
            store, cluster, topic, parent_manifest^, pid, max_cas_attempts
        )
        return Optional[SplitResult](res^)
    except e:
        if _is_already_retired_error(String(e)):
            return Optional[SplitResult](None)
        raise e^


def _is_already_retired_error(msg: String) -> Bool:
    """True iff a `split_at` Error is the "pid is not a LIVE partition" race
    (a concurrent split already retired the pid) — the ONLY split error the
    idempotent proposal swallows as a no-op. The "too narrow" (hot-key) +
    "fixed-mode" + "CAS lost N times" errors do NOT match (they are surfaced)."""
    return (
        msg.find("not a LIVE partition") >= 0
        or msg.find("already retired") >= 0
    )


# =============================================================================
# LineageReadStep — one pid to read, in the consumer's forest read order.
# =============================================================================


@fieldwise_init
struct LineageReadStep(Copyable, Movable, Deinitable):
    """One step in a whole-topic consumer's lineage-forest read: read the FULL
    manifest of `pid` (its LIVE generation, OR — when `is_prefix_gen` — its
    compacted PREFIX GENERATION), in this order (every parent before its
    children; for one child, its prefix generation strictly before its live
    generation). POD.

    Field layout:
      var pid: Int        — the partition manifest to read fully.
      var is_retired: Bool — True if this is a frozen/retired PARENT (read its
                            pre-split prefix), False if a live LEAF. Advisory:
                            both are read identically (full manifest); the flag
                            lets a consumer log/skip-if-empty.
      var depth: Int      — split generation (0 == an original root, 1 == a
                            first-level child, ...). Parents have strictly lower
                            depth than their children, so a stable sort by depth
                            (then pid) IS a valid topological order.
      var is_prefix_gen: Bool — True iff this step reads the child's PREFIX
                            GENERATION manifest (the gen-model compacted parent
                            rows), read
                            STRICTLY BEFORE the same pid's LIVE generation. A live
                            child carrying a `prefix_gen_seq` emits TWO steps: the
                            prefix-gen step (this flag True, gen_rank 0) BEFORE the
                            live step (False, gen_rank 1).
      var prefix_gen_seq: Int64 — the prefix-generation token (the manifest prefix
                            is derived from `(pid, prefix_gen_seq)` via
                            `prefix_gen_manifest_prefix`). `NO_PARENT_BASE` (-1)
                            on a LIVE / retired step (read the plain `<pid>`
                            prefix). Only meaningful when `is_prefix_gen`.
    """

    var pid: Int
    var is_retired: Bool
    var depth: Int
    var is_prefix_gen: Bool
    var prefix_gen_seq: Int64


# =============================================================================
# build_lineage_read_order — the topological (parents-before-children) order.
# =============================================================================


def build_lineage_read_order(map: PartitionMap) -> List[LineageReadStep]:
    """Build the whole-topic consumer's read order over the lineage FOREST:
    every pid that ever existed (every retired PARENT + every live LEAF), in
    TOPOLOGICAL order (every parent strictly before its children). A whole-topic
    consumer reads each step's manifest FULLY, exactly once, in this order, to
    yield every record exactly once in per-key produce order (see the module
    header's exactly-once + ordering argument).

    Implementation: the lineage is a forest of binary splits. Each retired
    parent `r` has edges `r.pid -> r.child_a_pid` and `r.pid -> r.child_b_pid`.
    We compute each pid's DEPTH (= number of ancestors) by walking child->parent
    edges (a child's `parent_pid` is on its live HashRange OR, for an
    intermediate retired node, recoverable from the retired edges). A stable
    sort by (depth, pid) is a valid topological order because a parent's depth
    is strictly less than its child's depth.

    No store access — pure metadata over the map. O(P^2) worst case in the
    number of partitions (tiny — a topic has a handful of partitions); not a
    hot path.
    """
    # Collect every pid in the forest: live leaves + retired parents. Track each
    # live leaf's prefix_gen_seq (NO_PARENT_BASE == no prefix generation); a
    # retired parent never carries one.
    var all_pids = List[Int]()
    var is_retired = List[Bool]()
    var prefix_gen = List[Int64]()
    for i in range(len(map.ranges)):
        all_pids.append(map.ranges[i].pid)
        is_retired.append(False)
        prefix_gen.append(map.ranges[i].prefix_gen_seq)
    for i in range(len(map.retired)):
        all_pids.append(map.retired[i].pid)
        is_retired.append(True)
        prefix_gen.append(NO_PARENT_BASE)

    # Build a child_pid -> parent_pid lookup from the retired edges (the
    # authoritative parent->child record). Every non-root pid is some retired
    # parent's child_a or child_b.
    var depth = List[Int]()
    for i in range(len(all_pids)):
        depth.append(_depth_of(all_pids[i], map.retired))

    # Stable sort by (depth, pid): selection-sort (P is tiny). Parents (lower
    # depth) come before children; ties broken by pid for determinism.
    var n = len(all_pids)
    var order = List[Int]()  # indices into all_pids, sorted.
    for i in range(n):
        order.append(i)
    for i in range(n):
        var best = i
        for j in range(i + 1, n):
            var dj = depth[order[j]]
            var db = depth[order[best]]
            if dj < db or (dj == db and all_pids[order[j]] < all_pids[order[best]]):
                best = j
        if best != i:
            var tmp = order[i]
            order[i] = order[best]
            order[best] = tmp

    var steps = List[LineageReadStep]()
    for i in range(n):
        var k = order[i]
        # GEN-MODEL: a live leaf carrying a prefix_gen_seq emits its PREFIX
        # GENERATION step (gen_rank 0) STRICTLY BEFORE its live step (gen_rank
        # 1). The migrated parent rows live in the prefix generation and so are
        # read first (per-key order). Retired parents never carry one.
        if (not is_retired[k]) and prefix_gen[k] != NO_PARENT_BASE:
            steps.append(
                LineageReadStep(
                    pid=all_pids[k],
                    is_retired=False,
                    depth=depth[k],
                    is_prefix_gen=True,
                    prefix_gen_seq=prefix_gen[k],
                )
            )
        steps.append(
            LineageReadStep(
                pid=all_pids[k],
                is_retired=is_retired[k],
                depth=depth[k],
                is_prefix_gen=False,
                prefix_gen_seq=NO_PARENT_BASE,
            )
        )
    return steps^


def _depth_of(pid: Int, retired: List[RetiredRange]) -> Int:
    """The lineage-generation depth of `pid` == the LONGEST ancestor chain (0 for
    an original root). Handles BOTH lineage shapes (recursively):
      * SPLIT child: a retired SPLIT-parent whose `child_a_pid`/`child_b_pid`
        == `pid` is `pid`'s parent. Depth = parent's depth + 1.
      * MERGE child: a merged child C has TWO predecessors — the retired MERGE
        tombstones whose `merged_into_pid == C`. Depth = max(predA depth, predB
        depth) + 1. (A merge fans IN two ancestors, so the child must sort AFTER
        the deeper of its two predecessors — taking the max keeps the
        topological order valid: every predecessor strictly precedes the child.)

    A split-then-merge / merge-then-split lineage composes because the recursion
    follows whichever edge(s) reach `pid`. Memo-free recursion bounded by the
    forest height (tiny — a topic has a handful of partitions); the cycle guard
    caps the recursion depth at `len(retired)+1` (a valid lineage is acyclic)."""
    return _depth_of_guarded(pid, retired, len(retired) + 1)


def _depth_of_guarded(pid: Int, retired: List[RetiredRange], guard: Int) -> Int:
    """`_depth_of` with an explicit recursion-depth guard (decremented per hop).
    Returns 0 once the guard is exhausted (defensive against a malformed cyclic
    lineage that cannot occur for a valid forest)."""
    if guard <= 0:
        return 0
    # SPLIT edge: is `pid` a child of a retired split parent?
    for i in range(len(retired)):
        if not retired[i].is_merge():
            if retired[i].child_a_pid == pid or retired[i].child_b_pid == pid:
                return _depth_of_guarded(retired[i].pid, retired, guard - 1) + 1
    # MERGE edge: is `pid` the merged child of two retired predecessors?
    var found_merge = False
    var best = 0
    for i in range(len(retired)):
        if retired[i].is_merge() and retired[i].merged_into_pid == pid:
            var d = _depth_of_guarded(retired[i].pid, retired, guard - 1)
            if not found_merge or d > best:
                best = d
            found_merge = True
    if found_merge:
        return best + 1
    return 0  # reached a root (no parent / predecessor edge).
