# =============================================================================
# komira_objectstore/sharded_lineage.mojo
#   The NEUTRAL, domain-agnostic SHARDED-LINEAGE RUNTIME KERNEL
# =============================================================================
#
# The broker/search `ShardedLineage` machinery, POLICY-AGNOSTIC: the heap
# partition router (route/route_range/hash_shard_to_id) sits ABOVE this kernel
# as table-store caller policy. The kernel is shared by the index axis (replica
# policy) and the heap axis (partition policy) — a shared substrate with split
# policy.
#
# WHAT THIS IS — the SHARD LAYER.
# ---------------------------------------------------------------------------
# The broker's runtime sharded-lineage machinery (claim a writer shard, discover
# live shards, pin an authoritative cross-shard snapshot, and run the SOLE
# canonical dense-offset assignment that BOTH the fold and the consume resolver
# call — the SERVE==FOLD moat) is the SAME machinery a heap-partitioned table
# needs (writer-per-shard claim, shard discovery, per-shard head pin, the
# canonical merge for read-side ordering). The DOMAIN-NEUTRAL SHARD LAYER lives
# in THIS struct, apart from the broker's i64-`_base` materialize/fold/resolve
# body (`SubLineageBaseFold`), so BOTH axes share ONE kernel:
#
#   * the BROKER axis (Kafka dense-offset fold)  — replica/segment `_base` policy;
#   * the HEAP-PARTITION axis                     — partition routing policy.
#
# THE DELIBERATE NON-SCOPE (this is ONLY the kernel foundation).
# ---------------------------------------------------------------------------
# This module carries ZERO routing/OCC/2PC/heap-partition logic. There is NO
# `hash_shard_to_id`, NO `route` / `route_range`, NO `replicate-all`, NO
# `hash % K`, NO i64-payload `_base` codec, NO segment `_base` codec here. Those
# are CALLER policy that sits ABOVE this kernel (the kernel stays
# routing-policy-agnostic). The i64/segment `_base` materialize+retire fold body
# stays where it lives (`SubLineageBaseFold` / the broker `SegmentBaseFold`); this
# kernel exposes only the policy-free shard primitives those folds DRIVE.
#
# THE SERVE==FOLD STRUCTURAL MOAT (load-bearing — do NOT fork it).
# ---------------------------------------------------------------------------
# `plan_tail_assignment` re-exports the SOLE assignment authority `plan_assignment`
# (from sublineage_base_fold) VERBATIM — it is NOT re-implemented here. Both the
# fold (fold-persist) and the consume resolver (serve-assign) call THIS one
# function with the SAME canonical-sorted snapshot + the SAME folded_counts + the
# SAME dense_hw start, so serve == fold byte-for-byte (no torn offset). A second
# assignment path WOULD break the moat; re-export keeps exactly one.
#   * `make_writer_shard_id` -> the SOLE shard-id mint (`make_shard_id`).
#   * `enumerate_live_shards` -> the SOLE LIST-delimiter-safe shard discovery.
#   * `snapshot` -> the SOLE authoritative cross-shard head pin.
#   * `plan_tail_assignment` -> the SOLE dense-offset assignment.
#   * canonical sort (`_canonical_shard_less` / `sort_shard_ids`) -> the SOLE order.
#
# DEPENDENCY DIRECTION (cycle-free).
# ---------------------------------------------------------------------------
# `komira_objectstore`'s deps never
# reach back into komira_search_s3 / komira_pgsql / komira_table_store and its adapters /
# komira_broker. This module imports ONLY peers within `komira_objectstore`
# (`sublineage_shard_keys`, `sublineage_base_fold`, `cas_manifest`, `store`,
# `path`, `types`). So the kernel sits at the BOTTOM of the graph; every consumer
# ABOVE it (broker, heap-partition router) imports DOWN into it. No inversion.
#
# REUSE of the shard-key kernel.
# ---------------------------------------------------------------------------
# The writer-identity mint (`make_shard_id`), the reserved-`_base` guard
# (`is_reserved_shard_id` / `LINEAGE_BASE_SHARD`), and the LIST-delimiter-safe
# discovery primitive (`_discover_shard_ids`) already live in the neutral
# `sublineage_shard_keys.mojo`. This kernel REUSES them as-is
# (that file is SHARED with the columnar index-sharding axis); it
# adds the RUNTIME orchestration layer (snapshot pin + the canonical-merge plan
# + the cadence) on top.
#
# Encapsulation / heap-reuse.
# ---------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY signature (public or private).
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * `[Store: CloneableConditionalWriteStore]` is the comptime backend selector;
#     the store is held BY VALUE (`_store: Self.Store`), cloned per shard handle
#     so each reaches the SAME logical bucket — it NEVER crosses a boundary as a
#     raw handle. Raw key arithmetic stays INSIDE the substrate (`CasManifestStore`)
#     and the path builders.
# * heap-reuse N/A: every field is a plain owned `Store` (held by value) + owned
#     `String` + `List[...]` value structs — NOT a byte-slab element, no Movable
#     struct with a heap-owning field stored in a byte-backed slab under a
#     wildcard cast. The snapshot/assignment lists are transient stack values.
# =============================================================================

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
)
from komira_objectstore.path import Path
from komira_objectstore.store import CloneableConditionalWriteStore
from komira_objectstore.types import ListResult

# REUSE the neutral shard-key kernel (claim + reserved guard).
# (sublineage_shard_keys.mojo is SHARED with the columnar index-sharding axis —
# imported, NEVER edited.)
from komira_objectstore.sublineage_shard_keys import (
    LINEAGE_BASE_SHARD,
    is_reserved_shard_id,
    make_shard_id,
)

# RE-EXPORT the SOLE canonical-merge authority + its value structs from
# sublineage_base_fold (the SERVE==FOLD moat — exactly one `plan_assignment`,
# exactly one comparator, exactly one snapshot value type). NOT re-implemented.
from komira_objectstore.sublineage_base_fold import (
    BASE_SHARD_ID,
    FoldBlockAssignment,
    ShardFoldedWatermark,
    ShardSnapshot,
    _canonical_shard_less,
    _sort_shard_ids,
    plan_assignment,
    sublineage_prefix,
)


# =============================================================================
# Public re-exports — the kernel's canonical-merge surface. A heap-partition or
# broker caller imports THESE names from `sharded_lineage` so there is ONE
# import surface for the whole shard layer (the value structs + the SOLE
# assignment authority live next door in sublineage_base_fold; re-exported here
# so the kernel is self-describing as the shard-layer entry point).
# =============================================================================


@always_inline
def shard_lineage_prefix(part: String, shard_id: String) -> String:
    """The CAS-manifest lineage prefix for `shard_id` under partition `part`:
    `<part>/_lineage/<shard_id>`. A thin alias of the SOLE path builder
    (`sublineage_prefix`) so a caller importing only `sharded_lineage` has the
    full shard-layer surface. Byte-identical to the broker's live keyspace —
    a writer shard and the reserved `_base` differ ONLY by the shard_id segment,
    both plain disjoint `CasManifestStore` prefixes."""
    return sublineage_prefix(part, shard_id)


@always_inline
def sort_shard_ids(var ids: List[String]) -> List[String]:
    """The SOLE canonical shard-id sort (shard_id byte-wise lexicographic) — a
    thin alias of `_sort_shard_ids` so the canonical order has a public name on
    the kernel surface. No FP / hash / PID / wall-clock — the entire determinism
    contract. Two callers sorting the same set get byte-identical order."""
    return _sort_shard_ids(ids^)


@always_inline
def canonical_shard_less(a: String, b: String) -> Bool:
    """The SOLE canonical comparator (shard_id byte-wise lexicographic `<`) — a
    public alias of `_canonical_shard_less`."""
    return _canonical_shard_less(a, b)


def plan_tail_assignment(
    sorted_snap: List[ShardSnapshot],
    folded_counts: List[ShardFoldedWatermark],
    dense_hw_start: Int64,
) -> List[FoldBlockAssignment]:
    """The SOLE canonical dense-offset assignment — RE-EXPORTS `plan_assignment`
    VERBATIM (the SERVE==FOLD moat). Walk `sorted_snap` (already canonical-sorted
    by shard_id) in order; for each shard, assign the un-folded tail
    `[already .. snap_record_total)` CONTIGUOUS dense offsets starting at
    `dense_hw_start`. A PURE function of (canonical-sorted snapshot, per-shard
    already-folded counts, dense_hw start) — NO FP, NO hash, NO process/thread/
    wall-clock, NO source-record content.

    Both the fold (fold-persist) and the consume resolver (serve-assign) call
    THIS — identical inputs -> identical output -> serve == fold byte-for-byte.
    The kernel does NOT introduce a second assignment path: it re-exports the ONE
    authority so both axes (broker fold + future heap-partition read-merge) bind
    to the SAME function. The caller canonical-sorts `sorted_snap` first
    (`sort_shard_ids`)."""
    return plan_assignment(sorted_snap, folded_counts, dense_hw_start)


# =============================================================================
# ShardedLineage — the NEUTRAL shard-layer runtime struct (the kernel).
# =============================================================================
#
# Generic over `[Store: CloneableConditionalWriteStore]` (the broker sub-lineage
# pattern): one store handle is `clone()`d per shard access, so all reach the
# SAME logical bucket (one S3 bucket, N `_lineage/<shard>` prefixes). The struct
# is STATELESS beyond `(store, part)` — every operation is a fresh read of the
# durable bucket (shard discovery + authoritative head pin), so two independent
# `ShardedLineage` views over the same partition observe the same committed
# universe identically. The DOMAIN-SPECIFIC `_base` fold state (the i64/segment
# materialize+retire index + watermarks) lives in the CALLER's fold struct, NOT
# here — this kernel is policy-agnostic.
# -----------------------------------------------------------------------------


struct ShardedLineage[Store: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """The neutral shard-layer runtime kernel: claim a writer shard, discover
    live shards, pin an authoritative cross-shard snapshot, and run the SOLE
    canonical dense-offset assignment. POLICY-AGNOSTIC — no routing, no OCC, no
    2PC, no `_base` codec. Both the broker fold and the future heap-partition
    router DRIVE this kernel; neither's domain policy lives in it."""

    var _store: Self.Store
    var _part: String

    def __init__(out self, var store: Self.Store, var part: String):
        self._store = store^
        self._part = part^

    def clone_view(self) raises -> Self:
        """A SECOND `ShardedLineage` view over the SAME logical bucket + the SAME
        partition (a `clone()` of the shared store). Both views observe the SAME
        committed universe — shard discovery + the authoritative head pin read the
        durable bucket, so two views agree on the live-shard set + the canonical
        snapshot. Used where a caller needs a fresh handle (e.g. a per-pthread
        transport rebuild) without re-deriving the partition."""
        return Self(self._store.clone(), self._part)

    # ---- store fan-out (one CasManifestStore per sub-lineage shard) ----

    def shard_store(
        self, shard_id: String
    ) raises -> CasManifestStore[Self.Store]:
        """A fresh `CasManifestStore` bound to `shard_id`'s sub-lineage prefix,
        backed by a `clone()` of the shared store (same logical bucket). The
        store fan-out primitive: a writer appends to ITS shard's manifest; the
        snapshot pins each shard's head; both go through THIS handle — raw
        per-shard key arithmetic stays inside `CasManifestStore`, never crossing
        a boundary as a raw pointer."""
        return CasManifestStore[Self.Store](
            self._store.clone(),
            sublineage_prefix(self._part, shard_id),
            RetryPolicy.fast_test(),
        )

    # ---- CLAIM: mint a writer's collision-free shard_id (policy-agnostic) ----

    @staticmethod
    def claim_writer_shard(
        node_id: String, worker_idx: Int, role: String = String("")
    ) raises -> String:
        """CLAIM a writer's collision-free `shard_id`
        = "<node_id>-<pid>-<role><worker_idx>" via the SOLE mint (`make_shard_id`).
        Computed ONCE per dispatcher at construction (stable for its lifetime) so
        all of a writer's appends accrete into ONE shard lineage. The `role`
        prefix keeps disjoint writer roles (e.g. "drain" vs "srv") in disjoint
        sub-lineages (avoids the cross-role `_HEAD` collision). A writer can NEVER
        mint the reserved `_base` fold-target (`make_shard_id` enforces). This is
        POLICY-FREE writer IDENTITY — it does NOT route a KEY to a shard (that is
        the heap-partition caller's `hash_shard_to_id` / `route`, which lives
        ABOVE this kernel)."""
        return make_shard_id(node_id, worker_idx, role)

    @staticmethod
    @always_inline
    def is_reserved(shard_id: String) -> Bool:
        """True iff `shard_id` is the COMPACTOR-RESERVED fold-target lineage
        (`_base`). A writer must NEVER claim it. Delegates to the SOLE guard."""
        return is_reserved_shard_id(shard_id)

    # ---- SHARD DISCOVERY: LIST-delimiter-safe enumeration of live shards ----

    def enumerate_live_shards(self) raises -> List[String]:
        """DISCOVER the live writer sub-lineage shard_ids by LISTing
        `<part>/_lineage/` and deriving each distinct `<shard_id>` segment.

        REAL-S3 LIST-DELIMITER TRAP (the load-bearing detail). The in-memory test
        backends IGNORE the delimiter and return ALL matching keys flat in
        `objects` with EMPTY `common_prefixes`, while real S3/GCS honor the
        delimiter and return each `<shard_id>/` as a `common_prefix`. To work
        IDENTICALLY on both — and to never depend on a delimiter being honored —
        we take the UNION of (a) the shard_id derived from each flat OBJECT key
        and (b) each backend-returned `common_prefix`, de-duplicating. An
        enumeration that folded ONLY `objects` (or ONLY `common_prefixes`) would
        SILENTLY return empty on the other backend class (the documented
        real-S3 LIST-delimiter trap that hit the broker rollout three times).

        The reserved `_base` shard is EXCLUDED (it is the fold's own OUTPUT, not
        a writer input). The result is CANONICAL-SORTED so the snapshot + the
        assignment are order-stable (two enumerations of the same committed
        universe return byte-identical lists)."""
        var enum_prefix = self._part + "/_lineage/"
        var listing: ListResult
        try:
            listing = self._store.list_with_delimiter(Path.parse(enum_prefix))
        except e:
            # An empty / absent prefix may surface as not-found on some backends —
            # treat as "no live shards" (a legacy single-manifest partition).
            if _sharded_is_not_found(String(e)):
                return List[String]()
            raise e^
        var seen = List[String]()
        # (a) UNION arm 1 — the backend-returned common_prefixes (S3 delimiter
        #     fast path). Each is `<enum_prefix><shard_id>/`.
        for i in range(len(listing.common_prefixes)):
            var seg = shard_id_from_listing_entry(
                listing.common_prefixes[i], enum_prefix
            )
            if seg.byte_length() > 0 and seg != BASE_SHARD_ID:
                _append_unique(seen, seg)
        # (b) UNION arm 2 — the flat OBJECT keys (the in-memory path + a
        #     belt-and-suspenders for any S3 page that returned objects too).
        for i in range(len(listing.objects)):
            var seg = shard_id_from_listing_entry(
                listing.objects[i].location, enum_prefix
            )
            if seg.byte_length() > 0 and seg != BASE_SHARD_ID:
                _append_unique(seen, seg)
        return _sort_shard_ids(seen^)

    # ---- FAN-OUT / SNAPSHOT: pin every live shard's authoritative head ----

    def snapshot(self) raises -> List[ShardSnapshot]:
        """FAN-OUT: pin every LIVE shard's AUTHORITATIVE head into a snapshot set
        at a consistent commit boundary. Uses `read_head_authoritative` (LIST-
        recovers the TRUE tail, bypassing the best-effort `_HEAD` cache — the
        stale-low-cache fix), so the boundary is the true highest-committed chunk.
        Iterates in CANONICAL order so the snapshot is order-stable (two snapshots
        of the same committed universe are identical lists). A shard whose chunks
        are ALL already folded+reaped pins an empty tail; an error reading a
        shard's head raises.
        Records appended AFTER the boundary fold in a LATER plan (additivity)."""
        var ids = self.enumerate_live_shards()
        var out = List[ShardSnapshot]()
        for i in range(len(ids)):
            var sid = ids[i]
            var s = self.shard_store(sid)
            # An absent or fully reaped shard reads as an empty tail (it does
            # not raise); a read error raises rather than drop a live shard.
            var head = s.read_head_authoritative()
            out.append(ShardSnapshot(sid, head.chunk_seq, head.next_offset))
            _ = s^
        return out^

    @always_inline
    def sort_snapshot(
        self, snap: List[ShardSnapshot]
    ) -> List[ShardSnapshot]:
        """Canonical-sort a snapshot by shard_id (the SOLE order). The caller
        sorts ONCE before `plan_tail_assignment` so the assignment is order-
        stable. Insertion sort by the SOLE comparator — deterministic, no PRNG."""
        var out = snap.copy()
        var n = len(out)
        for i in range(1, n):
            var j = i
            while j > 0 and _canonical_shard_less(
                out[j].shard_id, out[j - 1].shard_id
            ):
                var tmp = out[j].copy()
                out[j] = out[j - 1].copy()
                out[j - 1] = tmp^
                j -= 1
        return out^

    # ---- BASE-FOLD ORCHESTRATION (policy-agnostic): the canonical plan ----

    def plan_tail(
        self,
        snap: List[ShardSnapshot],
        folded_counts: List[ShardFoldedWatermark],
        dense_hw_start: Int64,
    ) -> List[FoldBlockAssignment]:
        """Run the SOLE canonical dense-offset assignment over a CALLER-PINNED
        snapshot. Canonical-sorts then calls the ONE authority (`plan_assignment`).
        The DOMAIN-SPECIFIC `folded_counts` (per-shard already-folded cursor) +
        `dense_hw_start` (the caller's `_base` next dense offset) are SUPPLIED by
        the caller's fold struct — this kernel does NOT own the `_base` format.
        Identical (snapshot, folded_counts, dense_hw) -> identical plan ->
        serve == fold. This is the orchestration entry point a broker fold AND a
        heap-partition read-merge both drive."""
        var sorted_snap = self.sort_snapshot(snap)
        return plan_assignment(sorted_snap, folded_counts, dense_hw_start)

    # ---- CADENCE: should a fold fire now? (policy-agnostic trigger) ----

    def should_fold(
        self,
        live_shard_threshold: Int,
        ms_since_last_fold: Int64,
        timer_interval_ms: Int64,
    ) raises -> Bool:
        """Cadence trigger: fold when the live-shard count exceeds
        `live_shard_threshold` (target a few tens per hot partition) OR the timer
        elapsed (`ms_since_last_fold >= timer_interval_ms`). Bounds the live-shard
        width so the read-side fan-out stays small. Threshold-OR-timer keeps a
        low-traffic partition's tail folded too (the timer floor). Returns False
        on an empty partition. POLICY-AGNOSTIC: it counts live shards; it does NOT
        decide WHAT to fold (the caller's fold body does)."""
        var live = len(self.enumerate_live_shards())
        if live > live_shard_threshold:
            return True
        if timer_interval_ms > Int64(0) and ms_since_last_fold >= timer_interval_ms:
            return live > 0
        return False

    @always_inline
    def live_shard_count(self) raises -> Int:
        """The number of live writer sub-lineages at this instant (the read-side
        fan-out width / the cadence knob input)."""
        return len(self.enumerate_live_shards())


# =============================================================================
# Free-function helpers — shard-segment extraction, list dedup, not-found.
# =============================================================================


@always_inline
def _sharded_is_not_found(msg: String) -> Bool:
    """Self-contained not-found classifier (the neutral kernel must not reach UP
    for one). Tolerates an empty / absent enum prefix surfaced as not-found."""
    return (
        msg.find("not_found") >= 0
        or msg.find("NotFound") >= 0
        or msg.find("404") >= 0
        or msg.find("NoSuchKey") >= 0
    )


def shard_id_from_listing_entry(s: String, enum_prefix: String) -> String:
    """Given a LIST entry — EITHER a flat object key `<enum_prefix><shard_id>/...`
    OR a common-prefix `<enum_prefix><shard_id>/` — and the enum prefix, return
    `<shard_id>` (the segment from the prefix up to the next `/`, or end-of-
    string). Empty if `s` does not start with `enum_prefix` or has no shard
    segment.

    THIS is the convergence point of the REAL-S3 LIST-DELIMITER-TRAP union: ONE
    helper serves BOTH arms, so the in-mem path (flat objects, `/manifest/...`
    suffix) and the real-S3 path (common-prefix, trailing `/`) derive the
    BYTE-IDENTICAL shard_id from the same writer shard — both stop at the same
    first `/` after the enum prefix. A discovery that handled only one shape
    would silently disagree across backend classes. Built byte-wise to avoid
    String-slice gaps. Public so the trap's correctness is directly testable
    without a backend that fabricates common_prefixes."""
    var sb = s.as_bytes()
    var pb = enum_prefix.as_bytes()
    var plen = len(pb)
    if len(sb) <= plen:
        return String("")
    for i in range(plen):
        if sb[i] != pb[i]:
            return String("")
    var seg = List[UInt8]()
    var i = plen
    while i < len(sb):
        if sb[i] == UInt8(47):  # '/'
            break
        seg.append(sb[i])
        i += 1
    if len(seg) == 0:
        return String("")
    return String(StringSlice(unsafe_from_utf8=Span(seg)))


def _append_unique(mut xs: List[String], v: String):
    for i in range(len(xs)):
        if xs[i] == v:
            return
    xs.append(v)
