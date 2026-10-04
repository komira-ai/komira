# =============================================================================
# komira_table_store/partitioned_table_store.mojo
#   WS-2 — the shard-aware ROUTER + per-shard commit (the RELAXED §10 scope).
#   (heap Model-2 sharding campaign).
# =============================================================================
#
# Source of truth:
#   the heap key-space partition design
#     §1.5  — the router shell: PartitionedTableStore WRAPS, does NOT edit,
#             TableStore.commit (additively, in a new type).
#     §5    — the single-shard fast path: a write collapsing to ONE shard runs
#             that shard's `TableStore.commit()` UNCHANGED (one create-CAS).
#     §10   — THE BUILD TARGET: the relaxed-semantics (DynamoDB-shaped) variant.
#     §10.3 — what this DROPS vs full-transparent: §2.4 topology-epoch closure,
#             §2.3 HASH k-way ordered merge, §2.5 falsifier-as-gate.
#     §1.4  — the ADR §4 constraint: routing policy (hash%K / route / route_range)
#             is CALLER policy here in the table store, NOT in the neutral kernel.
#
# WHAT THIS IS — a SIDECAR router the common case never touches.
# ---------------------------------------------------------------------------
# A table is heap-partitioned ONLY when an operator flags it (`partition_spec !=
# NONE`). For the >99% of tables that are NONE, the SQL executor holds a plain
# `TableStore[Store]` exactly as today and this type is NEVER constructed
# (zero-overhead-at-1). When a table IS flagged, `PartitionedTableStore` owns N
# `TableStore[Store]` instances (one per shard sub-lineage, bound via the WS-1
# `ShardedLineage.shard_store`) behind a router. The commit core is NOT modified;
# N instances of it are fanned out behind `route()`.
#
# THE RELAXED §10 SCOPE (what WS-2 builds, and what it deliberately does NOT).
# ---------------------------------------------------------------------------
#  * BUILDS: the router + per-shard OCC↔create-CAS (each shard's unchanged
#    `TableStore.commit`), the single-shard fast path (§5), the NONE-table
#    byte-identical default, and the cross-shard UNORDERED read = per-shard scan
#    + CONCAT (live `enumerate_live_shards`).
#  * DROPS (per §10.3 / §10.7): the §2.4 pinned-topology-epoch ordered-scan
#    closure, the §2.3 HASH k-way ordered merge, the §2.5 falsifier-as-gate.
#    Cross-shard analytical/range scans go to the columnar tier (out of scope).
#  * DEFERS: cross-shard ATOMIC multi-shard DML → WS-3 (2PC). v1 single-shard
#    DML is the fast path; a write that would span shards in one txn is REJECTED
#    with a clear "cross-shard txn not supported in v1 (WS-3)" Error — NEVER a
#    silent partial non-atomic apply that corrupts (§10.2 G1 / §10.7 WS-3 split).
#  * DEFERS: cross-partition global UNIQUE → WS-5 (the un-partitioned global-
#    guard lineage, §10.8). This file does NOT build the guard lineage.
#
# THE HARD COLLISION BOUNDARY (wrap-not-edit).
# ---------------------------------------------------------------------------
# This module WRAPS `TableStore`. It does NOT edit `TableStore.commit` /
# `_occ_check` / `try_append_at_seq` / `cas_manifest.mojo`. The per-shard OCC
# coupling (the §8 snapshot↔create-CAS arbiter) is the SHIPPED, unchanged
# `TableStore.commit`; a same-shard conflict aborts with the shard's own 40001
# exactly as today. WS-2 only adds the routing layer above.
#
# Encapsulation / stale-reuse (the repository pointer rules).
# ---------------------------------------------------------------------------
#   * ZERO UnsafePointer in ANY signature (public or private).
#   * ZERO wildcard origins (MutAnyOrigin / ImmutAnyOrigin / MutExternalOrigin).
#   * ZERO unsafe_from_address, ZERO take_pointee.
#   * `[Store: CloneableConditionalWriteStore]` is the comptime backend selector
#     (NOT a raw cross-boundary handle); each shard's store is a `clone()` of the
#     shared store so all N reach the SAME logical bucket (one bucket, N
#     `_lineage/<shard>` prefixes). Raw key arithmetic stays INSIDE the substrate
#     (`CasManifestStore`) and the WS-1 path builders — never crossing a boundary.
#   * stale-reuse: the N `TableStore[Store]` instances are held in
#     `Slab[OwnedPointer[TableStore[Store]]]` — the EXACT SI-1 correction
#     (`_idx_indexes: Slab[OwnedPointer[KeyIndex]]`, table_store.mojo:561). The
#     Slab stores the POD 8-byte OwnedPointer HANDLE by value in concrete-origin
#     byte storage (origin tied to `self`, NO wildcard cast); each TableStore
#     (Movable, with its own heap-owning `CasManifestStore` + `KeyIndex` +
#     `Slab` fields) lives BEHIND the OwnedPointer, NOT inside the slab bytes —
#     so there is NO byte-slab + heap-owning-inner-field trap (NOT a stale-reuse byte-
#     slab element). A by-value List of TableStore is impossible anyway
#     (`List[T]` needs `T: Copyable`; TableStore is Movable-only). The OwnedPointer
#     box ALSO gives each TableStore a STABLE heap address across slab grows
#     (a held ref into a shard is not invalidated by a later shard append).
#   * `_shard_ids: List[String]` and `_range_boundaries: List[List[UInt8]]` are
#     plain owned-`String` / owned-byte `List`s held by value (NOT slab elements).
# =============================================================================

from std.memory import OwnedPointer

from komira_collections.slab import Slab

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.sharded_lineage import ShardedLineage
from komira_objectstore.store import CloneableConditionalWriteStore

from komira_table_store.key_index import KeyValue
from komira_table_store.table_store_codec import WriteOp, bytes_cmp
from komira_table_store.table_store import (
    CommitResult,
    TableStore,
    Txn,
    _TXN_SHARD_UNBOUND,
)


# =============================================================================
# Partition-spec kinds (the per-table catalog axis, §1.1).
# =============================================================================

comptime PART_SPEC_NONE: UInt8 = 0
"""NONE (default, every table) — single-lineage, the shipped path, byte-identical
to today. A NONE table NEVER constructs a `PartitionedTableStore` (the SQL
executor holds a plain `TableStore`). The kind is kept here only so a caller can
ask `is_partitioned()` and short-circuit."""

comptime PART_SPEC_RANGE: UInt8 = 1
"""RANGE(boundaries[]) — K shards by ordered key-range split points. The
recommended default for partitioned tables (range locality → ordered scans touch
few adjacent shards; §1.1). `route` = binary_search(boundaries, key) over the
`bytes_cmp` total order."""

comptime PART_SPEC_HASH: UInt8 = 2
"""HASH(K) — K shards, shard = hash_shard_to_id(key_bytes) % K. For a single
non-splittable hot key (the max(id)++ insert storm) where RANGE pins the whole
tail to one shard and only hashing spreads it (§1.1). Point-lookup-dominated."""


# =============================================================================
# The cross-shard-txn rejection token (WS-3 deferral, §10.2 G1 / §10.7).
# =============================================================================
#
# A DML whose WriteOps route to P > 1 shards is the DynamoDB `TransactWriteItems`
# analog — deferred to WS-3 (cross-shard 2PC). In v1 it is REJECTED with this
# discriminable token rather than partial-applied (which would land one shard's
# rows at one commit_lsn and the other's at another, silently re-opening the torn
# cross-keyspace read invariant #3 protects). The token mirrors the TableStore
# OCC/UNIQUE taxonomy (message-prefix discriminable).
comptime CROSS_SHARD_UNSUPPORTED_TOKEN: String = "CROSS_SHARD_TXN_UNSUPPORTED_V1"


@always_inline
def is_cross_shard_unsupported(msg: String) -> Bool:
    """True iff `msg` is the v1 cross-shard-DML rejection (WS-3 deferral). A
    caller that genuinely needs cross-shard atomicity must wait for WS-3's
    `HeapTxnControlStore`; v1 keeps single-shard DML as the whole write guarantee
    (§10.7 v1 floor) and rejects a spanning DML LOUDLY rather than corrupting."""
    return msg.find(CROSS_SHARD_UNSUPPORTED_TOKEN) >= 0


# =============================================================================
# Routing primitives — CALLER policy (ADR §4 / §1.4: NOT in the neutral kernel).
# =============================================================================
#
# These are the genuine net-new of WS-2: the per-KEY map (a heap keyspace
# partition), as opposed to the kernel's per-WRITER identity (`make_shard_id`).
# They live HERE in the table store — never reaching down into `komira_objectstore` —
# so the kernel stays routing-policy-agnostic (it does not bake hash%K OR
# replicate-all, which would pre-empt the §8 decision).


@always_inline
def hash_shard_to_id(key_bytes: List[UInt8], k: Int) -> Int:
    """The central net-new routing primitive (confirmed ABSENT on main): map the
    encoded memcomparable KEY bytes to a shard ordinal in `[0, k)` for a HASH
    spec. Deterministic FNV-1a over the key bytes, then `% k`.

    CODEC-STABLE: hashes the ENCODED memcomparable key bytes (the same bytes the
    store sorts on), so routing is stable across runs and independent of the
    in-RAM representation — NO FP, NO PRNG, NO process/thread/wall-clock input
    (the determinism contract: two callers hashing the same key get the same
    shard). A monotone-increasing key (the `max(id)++` hotspot) spreads across
    all K shards because FNV-1a diffuses adjacent inputs — which is exactly why
    HASH exists (RANGE would pin the whole tail to one shard).

    `k <= 1` collapses to shard 0 (a 1-shard HASH table is a single lineage)."""
    if k <= 1:
        return 0
    # FNV-1a 64-bit (offset basis 14695981039346656037, prime 1099511628211).
    var h = UInt64(14695981039346656037)
    for i in range(len(key_bytes)):
        h = h ^ UInt64(Int(key_bytes[i]))
        h = h * UInt64(1099511628211)
    return Int(h % UInt64(k))


# =============================================================================
# PartitionSpec — the per-table partition policy (a value struct).
# =============================================================================


struct PartitionSpec(Copyable, Movable, Deinitable):
    """The per-table partition policy (§1.1). A plain value struct — POD `kind`
    + `k` (Int) + owned-byte `range_boundaries: List[List[UInt8]]` held by value
    (NOT a slab element; reuse-safe (no heap fields)). Boundaries are the K-1 ascending split keys
    for a RANGE spec (`boundaries[i]` is the EXCLUSIVE upper bound of shard i, so
    shard i owns `[boundaries[i-1], boundaries[i])`; shard 0 owns `(-inf,
    boundaries[0])`, shard K-1 owns `[boundaries[K-2], +inf)`). Empty for NONE /
    HASH.

    Field layout:
      var kind: UInt8                       — PART_SPEC_NONE | _RANGE | _HASH.
      var k: Int                            — the shard count (1 for NONE).
      var range_boundaries: List[List[UInt8]] — K-1 ascending split keys (RANGE).
    """

    var kind: UInt8
    var k: Int
    var range_boundaries: List[List[UInt8]]

    def __init__(
        out self,
        kind: UInt8,
        k: Int,
        var range_boundaries: List[List[UInt8]],
    ):
        self.kind = kind
        self.k = k
        self.range_boundaries = range_boundaries^

    @staticmethod
    def none() -> PartitionSpec:
        """The default single-lineage spec. `is_partitioned()` is False."""
        return PartitionSpec(PART_SPEC_NONE, 1, List[List[UInt8]]())

    @staticmethod
    def hash(k: Int) -> PartitionSpec:
        """A HASH spec over `k` shards. `route` = hash_shard_to_id(key) % k."""
        return PartitionSpec(PART_SPEC_HASH, k, List[List[UInt8]]())

    @staticmethod
    def range(var boundaries: List[List[UInt8]]) -> PartitionSpec:
        """A RANGE spec with `len(boundaries) + 1` shards. `boundaries` MUST be
        ascending by `bytes_cmp`; `boundaries[i]` is the exclusive upper bound of
        shard i. The caller (catalog) supplies the split points."""
        var k = len(boundaries) + 1
        return PartitionSpec(PART_SPEC_RANGE, k, boundaries^)

    @always_inline
    def is_partitioned(self) -> Bool:
        """True iff this is a genuinely-partitioned table (RANGE or HASH with
        K > 1). A NONE spec — or a degenerate K=1 spec — is single-lineage."""
        return self.kind != PART_SPEC_NONE and self.k > 1


# =============================================================================
# PartitionedTableStore — the shard-aware router (WS-2, relaxed §10 scope).
# =============================================================================


struct PartitionedTableStore[Store: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """The shard-aware router over N per-shard `TableStore[Store]` instances —
    the first user-visible partitioning slice (§1.5). Owns one `TableStore` per
    shard (bound to its sub-lineage prefix via the WS-1 `ShardedLineage`), routes
    each write by `route(pk)` to its shard's WAL, and serves cross-shard
    unordered reads by per-shard scan + concat. WRAPS — never edits —
    `TableStore.commit` (the per-shard §8 OCC↔create-CAS arbiter is unchanged).

    Fields:
      var _shards: Slab[OwnedPointer[TableStore[Store]]]
                                  — the N per-shard MVCC stores, boxed in
                                    OwnedPointers for stable addresses (the SI-1
                                    stale-reuse pattern). Slot i is shard
                                    `_shard_ids[i]`. NIT (review LOW): this Slab is
                                    built ONCE in `open` with exactly K shards and
                                    is NEVER grown afterward (K is fixed for the
                                    router's lifetime — a re-split is a new
                                    `open`), so the held `shard_store_ref` ref is
                                    stable for the executor call's scope on that
                                    ground ALONE; the OwnedPointer box additionally
                                    keeps each TableStore at a stable heap address
                                    independent of any (here, non-occurring) slab
                                    grow.
      var _shard_ids: List[String] — the per-slot shard id (the sub-lineage
                                    segment under `<part>/_lineage/`). Parallel to
                                    `_shards`.
      var _spec: PartitionSpec    — the routing policy (RANGE / HASH / NONE).
      var _part: String           — the table prefix (the bucket-relative root of
                                    `<part>/_lineage/<shard_id>/...`).
      var _store: Store           — a clone() of the shared store (same logical
                                    bucket) RETAINED for live-shard discovery (a
                                    fresh `ShardedLineage` view). Held BY VALUE
                                    (reuse-safe (no heap fields) — a plain owned Store, NOT a slab
                                    element, NOT a raw cross-boundary handle); it
                                    NEVER crosses a boundary as a raw pointer.
    """

    var _shards: Slab[OwnedPointer[TableStore[Self.Store]]]
    var _shard_ids: List[String]
    var _spec: PartitionSpec
    var _part: String
    var _store: Self.Store

    # ---- construction --------------------------------------------------------

    @staticmethod
    def open(
        var store: Self.Store,
        var part: String,
        var spec: PartitionSpec,
    ) raises -> Self:
        """Construct + open N per-shard `TableStore`s under `<part>/_lineage/`.

        The CALLER (which holds the concrete cloneable `Store`) hands in the
        store + the table prefix + the spec; this builder derives the K shard
        ids (`p0`, `p1`, … — stable dense ordinals, the partition-ordinal naming
        distinct from the WS-1 per-WRITER `make_shard_id`), binds a
        `CasManifestStore` to each shard's sub-lineage prefix via the WS-1
        `ShardedLineage.shard_store`, and `TableStore.open`s each (replaying its
        own WAL tail — recovery composes per shard with NO kernel change, §1.2).

        A NON-partitioned spec (NONE or K<=1) is still legal here (it builds a
        1-shard router whose single shard is the WHOLE keyspace) — but the
        zero-overhead-at-1 contract is that the SQL executor does NOT construct
        this type for a NONE table at all (it holds a plain `TableStore`). The
        1-shard form exists for the byte-identical-equivalence proof."""
        var lineage = ShardedLineage[Self.Store](store.clone(), part)
        var shards = Slab[OwnedPointer[TableStore[Self.Store]]]()
        var shard_ids = List[String]()
        var n = spec.k
        if n < 1:
            n = 1
        for i in range(n):
            var sid = _partition_shard_id(i)
            # WS-1 kernel: a fresh CasManifestStore bound to this shard's
            # sub-lineage prefix, backed by a clone() of the shared store.
            var wal = lineage.shard_store(sid)
            var ts = TableStore[Self.Store].open(wal^)
            shards.append(OwnedPointer(ts^))
            shard_ids.append(sid)
        # FAIL-LOUD reopen-with-smaller-K guard (review MED-2). Probe the DURABLE
        # topology: a live shard sub-lineage with ordinal >= n means this table
        # was previously opened with a LARGER K and has committed data in shard
        # p{ord} that the current (smaller-K) routing set would never reach —
        # silently ORPHANING those rows (a key that hashed to p{ord} under the
        # old K now routes to a slot < n and reads the wrong shard's data). Raise
        # rather than silently lose data. This is ALSO the only consumer of
        # `enumerate_live_shards` at open-time (it is the durability probe; the
        # cross-shard READ fan-out uses the DECLARED `_shard_ids` instead).
        var live = lineage.enumerate_live_shards()
        for i in range(len(live)):
            var ord_i = _partition_ordinal_of(live[i])
            if ord_i >= n:
                raise Error(
                    "reopen-with-smaller-K: durable partition shard "
                    + live[i]
                    + " exists (ordinal "
                    + String(ord_i)
                    + ") but spec.k="
                    + String(n)
                    + "; shrinking K would orphan that shard's committed rows."
                    " Reopen with K >= "
                    + String(ord_i + 1)
                    + " (the durable shard count), or migrate the data first."
                )
        _ = lineage^
        # Retain a clone() of the store for live-shard discovery (same bucket).
        return Self(shards^, shard_ids^, spec^, part^, store^)

    def __init__(
        out self,
        var shards: Slab[OwnedPointer[TableStore[Self.Store]]],
        var shard_ids: List[String],
        var spec: PartitionSpec,
        var part: String,
        var store: Self.Store,
    ):
        self._shards = shards^
        self._shard_ids = shard_ids^
        self._spec = spec^
        self._part = part^
        self._store = store^

    # ---- introspection -------------------------------------------------------

    @always_inline
    def is_partitioned(self) -> Bool:
        """True iff this is a genuinely partitioned table (K > 1)."""
        return self._spec.is_partitioned()

    @always_inline
    def shard_count(self) -> Int:
        """The number of shard sub-lineages this router fans out across."""
        return len(self._shard_ids)

    @always_inline
    def shard_id_at(self, i: Int) -> String:
        """The shard id (sub-lineage segment) of slot `i`."""
        return self._shard_ids[i]

    # ---- shard TableStore access (the WS-4 Leg C driver-seam bridge) ----------

    def shard_store_ref(
        mut self, slot: Int
    ) -> ref [origin_of(self._shards[slot][])] TableStore[Self.Store]:
        """A MUTABLE REFERENCE to shard `slot`'s `TableStore` (the WS-4 Leg C
        seam). The partition-aware SQL driver threads THIS ref into the FROZEN
        `execute_sql` / `execute_sql_dual` executor (`mut store: TableStore[Store]`)
        so a partitioned table's statement runs against the ONE routed shard's
        WAL — WITHOUT editing the executor signature. Encapsulation: a `ref` with
        the CONCRETE `self._shards` origin (NOT a raw UnsafePointer, NOT a
        wildcard) — the Slab's byte storage owns the OwnedPointer-boxed TableStore
        at a STABLE address, so the ref stays valid for the executor call's
        scope. The caller (driver) routes the key first, then asks for that
        slot's store; the router stays the SOLE owner of the N shard stores."""
        return self._shards[slot][]

    # ---- routing (caller policy, §1.4) ---------------------------------------

    @always_inline
    def route(self, key: List[UInt8]) -> Int:
        """Route a single KEY to its shard SLOT in `[0, shard_count())`.
          * HASH: `hash_shard_to_id(key, k)` — spreads a monotone hotspot
            (the `% k` is internal to `hash_shard_to_id`; NO redundant outer
            modulo here).
          * RANGE: `_range_route(key)` = binary search over the ascending split
            boundaries (the covering shard for an exact key).
          * NONE / K<=1: slot 0 (the whole keyspace lives in one lineage).
        Routes over the FULL encoded memcomparable key bytes (v1: the partition
        key is the whole key; a composite-prefix partition key is a future
        catalog refinement, §4)."""
        if not self._spec.is_partitioned():
            return 0
        if self._spec.kind == PART_SPEC_HASH:
            # NIT-1: hash_shard_to_id already does `% k` internally — no outer
            # `% self._spec.k` here (that would be a redundant double-modulo).
            return hash_shard_to_id(key, self._spec.k)
        # RANGE
        return self._range_route(key)

    @always_inline
    def _range_route(self, key: List[UInt8]) -> Int:
        """Binary search the ascending RANGE boundaries: return the FIRST shard i
        whose exclusive upper bound `boundaries[i]` is > key (i.e. key <
        boundaries[i]); the last shard if key >= every boundary. Shard i owns
        `[boundaries[i-1], boundaries[i])`."""
        ref bounds = self._spec.range_boundaries
        var lo = 0
        var hi = len(bounds)  # number of boundaries == K-1
        # Find the smallest i in [0, K-1] with key < bounds[i]; if none, i = K-1.
        while lo < hi:
            var mid = (lo + hi) // 2
            if bytes_cmp(key, bounds[mid]) < 0:
                hi = mid
            else:
                lo = mid + 1
        return lo

    def route_range(
        self,
        lo: List[UInt8],
        hi: List[UInt8],
        has_lo: Bool,
        has_hi: Bool,
    ) -> List[Int]:
        """The covering shard SLOTS for a range scan over `[lo, hi]` (INCLUSIVE
        bounds — the predicate `lo_incl`/`hi_incl` only affect ROW filtering
        WITHIN a shard, not which shards the band covers, so a closed band is the
        safe covering superset for any bound-inclusivity).
          * RANGE: the contiguous covering set `[route(lo) .. route(hi)]` — a
            range query touches few adjacent shards (the RANGE locality win, §4).
            An UNBOUNDED side is SATURATED, not routed: `has_lo == False` (the
            `pk <= hi` / `pk < hi` shape) covers `[0 .. route(hi)]`; `has_hi ==
            False` (the `pk >= lo` / `pk > lo` shape) covers `[route(lo) ..
            shard_count()-1]`. Routing an EMPTY missing-side key would land it on
            shard 0 (an empty key sorts below every boundary) and collapse the
            band to `[lo_slot .. 0]` — an EMPTY band whenever `lo_slot > 0`, the
            unbounded-upper bug (a `WHERE pk >= <above-the-top-split>` would
            return ZERO rows). Saturating the missing side is the fix.
          * HASH / NONE: ALL shards (HASH destroys range locality — the honest
            cost the operator accepted; §4). For NONE this is the single shard.
        Returns slot ordinals in ascending order, de-duplicated."""
        var out = List[Int]()
        if not self._spec.is_partitioned() or self._spec.kind == PART_SPEC_HASH:
            for i in range(self.shard_count()):
                out.append(i)
            return out^
        # RANGE: the covering contiguous band. SATURATE an unbounded side rather
        # than routing an empty key (which would mis-collapse the band).
        var lo_slot = self._range_route(lo) if has_lo else 0
        var hi_slot = self._range_route(hi) if has_hi else (
            self.shard_count() - 1
        )
        var i = lo_slot
        while i <= hi_slot and i < self.shard_count():
            out.append(i)
            i += 1
        return out^

    # ---- single-shard commit (the §5 fast path; multi-shard → WS-3 reject) ---

    def commit(mut self, var txn: Txn) raises -> CommitResult:
        """Commit `txn` via the SINGLE-SHARD fast path (§5).

        1. Route EVERY WriteOp's key. If they collapse to ONE shard → that
           shard's existing `TableStore.commit()` runs UNCHANGED (one chunk, one
           create-CAS, one commit_lsn → atomic by construction, no 2PC, no cross-
           shard MVCC filter). Per-shard throughput = today's single-lineage
           throughput; N shards = N independent `_HEAD` slots.
        2. If the WriteOps span P > 1 shards → REJECT with the discriminable
           `CROSS_SHARD_TXN_UNSUPPORTED_V1` Error (WS-3 deferral, §10.7). This is
           the SAFE choice (§10.2 G1): a clear loud rejection, NEVER a partial
           non-atomic apply that lands rows at uncoordinated commit_lsns and
           silently re-opens the torn cross-keyspace read (invariant #3).
        3. A read-only txn (empty write-set) routes to shard 0 and commits there
           (a no-op create-CAS-free read-only result, same as today).

        WS-4 LEG A — the begin==commit-shard invariant is now STRUCTURALLY
        ENFORCED (replaces WS-2's docstring-only precondition).
        `txn` MUST have been begun (`begin_on` / `begin_for_key`) on the SAME
        shard its write-set routes to. The txn carries a per-shard snapshot (that
        shard's head); committing a txn begun on shard X but whose keys route to
        shard Y would run shard Y's create-CAS against a snapshot pinned to shard
        X's head — a silent OCC-arbiter mismatch (the §8 coupling validates the
        OCC window against shard Y's head while the snapshot came from shard X, so
        a concurrent shard-Y committer between the two heads is INVISIBLE to the
        OCC scan = an isolation hole). The router's `begin_on` / `begin_for_key`
        now STAMP `Txn.shard_slot` with the begin shard; here we re-route the
        write-set and ASSERT the routed target slot == `txn.shard_slot`. A
        mismatch RAISES the discriminable `CROSS_SHARD_TXN_UNSUPPORTED_V1` token
        (a cross-shard txn — a write begun on one shard whose keys land on
        another is exactly the multi-shard atomicity case WS-3 owns; in v1 it is
        a LOUD reject, never a silent shard-Y create-CAS on a shard-X snapshot).
        A txn whose `shard_slot` is `_TXN_SHARD_UNBOUND` (a raw
        `TableStore.begin()` handed in directly, NOT through the router's
        begin verbs) is tolerated — the routed target is authoritative — so a
        legacy direct-begin caller keeps working, but every router-begun txn is
        now structurally checked.

        WRAP-NOT-EDIT: the per-shard OCC↔create-CAS coupling (the §8 arbiter) is
        the SHIPPED, byte-unchanged `TableStore.commit`; a same-shard conflict
        aborts with that shard's own 40001. WS-2 adds routing above + WS-4 adds
        the begin==commit assertion; neither edits the commit core."""
        var target = self._route_write_set(txn.write_set)
        # target == -1 means an empty write-set (read-only); route to shard 0.
        if target < 0:
            target = 0
        # WS-4 LEG A: STRUCTURAL begin==commit-shard enforcement. A router-begun
        # txn carries the begin shard on `shard_slot` (>= 0); a mismatch with the
        # routed target is a cross-shard txn -> LOUD reject (never a silent
        # snapshot/head mismatch). `_TXN_SHARD_UNBOUND` (-1, a raw direct begin)
        # is tolerated (the routed target stands).
        if txn.shard_slot != _TXN_SHARD_UNBOUND and txn.shard_slot != target:
            raise Error(
                CROSS_SHARD_UNSUPPORTED_TOKEN
                + ": txn begun on shard slot "
                + String(txn.shard_slot)
                + " but its write-set routes to shard slot "
                + String(target)
                + " (begin-shard != commit-shard). A txn's snapshot is pinned to"
                " ONE shard's head; committing it against a DIFFERENT shard would"
                " run that shard's create-CAS against the wrong snapshot (a silent"
                " OCC-arbiter mismatch / isolation hole). Begin the txn on the"
                " shard its keys route to (`begin_for_key`), or wait for WS-3's"
                " cross-shard 2PC."
            )
        return self._shards[target][].commit(txn^)

    @always_inline
    def _route_write_set(self, write_set: List[WriteOp]) raises -> Int:
        """Route the whole write-set: return the single target shard slot, or
        raise if the keys span P > 1 shards. Returns -1 for an empty write-set
        (read-only). The single-shard collapse check of §5 step 1."""
        var n = len(write_set)
        if n == 0:
            return -1
        var first = self.route(write_set[0].key)
        for i in range(1, n):
            var s = self.route(write_set[i].key)
            if s != first:
                raise Error(
                    CROSS_SHARD_UNSUPPORTED_TOKEN
                    + ": this DML's keys route to >1 partition shard (slots "
                    + String(first)
                    + " and "
                    + String(s)
                    + "); cross-shard atomic writes are deferred to WS-3 (the"
                    " cross-shard 2PC). v1 supports single-shard DML only —"
                    " choose a partition key that keeps the DML single-shard,"
                    " or wait for WS-3."
                )
        return first

    # ---- per-shard txn lifecycle (the per-shard SI snapshot, §10.3) ----------

    def begin_on(mut self, shard_slot: Int) raises -> Txn:
        """Begin a txn pinned to ONE shard's snapshot (the per-shard SI head, the
        component §10.3 KEEPS). The write path buffers into the returned Txn and
        commits via `commit` (which re-routes + single-shard-collapses). A caller
        that knows the target shard (point lookup / single-shard DML) begins
        directly on it; a write whose keys all land on `shard_slot` commits with
        no cross-shard work. The snapshot is that shard's `TableStore.begin()`.

        WS-4 LEG A: STAMP the begin shard onto the returned `Txn.shard_slot` so
        `commit` can structurally enforce begin==commit (a mismatched commit
        raises). The shard's own `begin()` returns an UNBOUND txn; we bind it
        here."""
        var t = self._shards[shard_slot][].begin()
        t.shard_slot = shard_slot
        return t^

    def begin_for_key(mut self, key: List[UInt8]) raises -> Txn:
        """Begin a txn on the shard that `key` routes to (the common single-key
        DML / point-lookup entry). Equivalent to `begin_on(route(key))`.

        WS-4 LEG A: STAMP the routed begin shard onto `Txn.shard_slot` (the
        begin==commit-shard binding) so a later commit whose keys route elsewhere
        is caught structurally."""
        var slot = self.route(key)
        var t = self._shards[slot][].begin()
        t.shard_slot = slot
        return t^

    def abort_on(self, shard_slot: Int, var txn: Txn):
        """Abort a txn begun on `shard_slot` (drops the in-RAM buffer; no store
        interaction). Routes to that shard's unchanged `TableStore.abort`."""
        self._shards[shard_slot][].abort(txn^)

    # ---- point lookup: prune to ONE shard (§4 / §10.3 the marquee read) ------

    def get(mut self, txn: Txn, key: List[UInt8]) raises -> Optional[List[UInt8]]:
        """Point lookup `WHERE pk = key`: route to the ONE shard the key lives on
        and probe ONLY that shard's `TableStore.get` (one-shard cost, NO scatter).
        Strongly consistent, single-shard — the relaxation does NOT touch this
        (point lookups stay the marquee fast path, §10.2). `txn` MUST have been
        begun on the SAME shard (`begin_for_key`/`begin_on(route(key))`) so the
        snapshot is that shard's head."""
        var slot = self.route(key)
        return self._shards[slot][].get(txn, key)

    # ---- cross-shard UNORDERED scan = per-shard scan + CONCAT (§10.3) ---------
    #
    # The relaxed-§10 read: a cross-shard scan returns the UNION of all shards'
    # rows, per-shard order preserved WITHIN a shard, shards concatenated in slot
    # order. NO global k-way ordered merge (DROPPED, §10.3), NO LWW dedup (a
    # disjoint heap partition has NO cross-shard duplicates — a key lives in
    # exactly one shard, §2.1). This is the DynamoDB-shaped Scan contract: SQL-
    # legal-for-free since SQL leaves result order unspecified absent ORDER BY.
    # A genuinely ordered scan (ORDER BY pk over the whole table) is NOT served
    # here — it goes to the columnar tier or pays §2's machinery (out of WS-2).

    def scan_all_concat(
        mut self, lo: List[UInt8], hi: List[UInt8]
    ) raises -> List[KeyValue]:
        """Cross-shard UNORDERED range scan `[lo, hi)`: per-shard scan + CONCAT
        over the COVERING shards (RANGE prunes to adjacent shards; HASH/NONE
        scatter to all). Each shard is scanned at ITS OWN fresh snapshot
        (`begin()` per shard — a cross-shard autocommit read is NOT a single
        global cut; §10.2 / F3, which is the table store default + SQL-legal). Rows
        are concatenated in shard-slot order, NO global merge, NO dedup. Returns
        the union of all covering shards' visible rows.

        RELAXED CONTRACT: the inter-shard order is unspecified (per-shard order
        preserved within a shard). A correct Postgres app cannot depend on result
        order without ORDER BY — so this is the DynamoDB Scan contract rendered on
        pgwire, SQL-legal-for-free (§10.5 F1)."""
        # Both bounds present (an explicit `[lo, hi)` bounded scan) -> has_lo /
        # has_hi True (no saturation; route both ends of the covering band).
        var slots = self.route_range(lo, hi, True, True)
        var out = List[KeyValue]()
        for j in range(len(slots)):
            var slot = slots[j]
            var t = self._shards[slot][].begin()
            var part_rows = self._shards[slot][].scan(t, lo, hi)
            for r in range(len(part_rows)):
                out.append(part_rows[r].copy())
        return out^

    def scan_all_from_concat(
        mut self, lo: List[UInt8]
    ) raises -> List[KeyValue]:
        """Cross-shard UNORDERED scan `[lo, +inf)` (unbounded upper): per-shard
        `scan_from` + CONCAT over ALL shards (an unbounded scan cannot prune a
        covering set — it touches every shard). Same relaxed contract as
        `scan_all_concat`: union of all shards, per-shard order within a shard,
        concatenated in slot order, NO merge / NO dedup."""
        var out = List[KeyValue]()
        for slot in range(self.shard_count()):
            var t = self._shards[slot][].begin()
            var part_rows = self._shards[slot][].scan_from(t, lo)
            for r in range(len(part_rows)):
                out.append(part_rows[r].copy())
        return out^

    # ---- live-shard discovery (the OPEN-time durability probe, NOT read fan-out)

    def enumerate_live_shards(self) raises -> List[String]:
        """The LIST-delimiter-safe live-shard discovery (the WS-1 kernel's
        `ShardedLineage.enumerate_live_shards`, unions `common_prefixes` +
        `objects`).

        READ FAN-OUT vs. DURABILITY PROBE (review MED-1 — read this plainly).
        WS-2 cross-shard READS (`route_range` / `scan_all_concat` /
        `scan_all_from_concat`) fan out over the DECLARED routing set
        `self._shard_ids` (the K slots this router was opened with) — they do
        NOT call `enumerate_live_shards`. The declared set is authoritative for
        routing: a key always lives on the slot `route(key)` lands it on, even
        before that shard has a single committed chunk, so the read set must be
        the declared slots, not whatever happens to have durable data yet.

        `enumerate_live_shards` is instead the OPEN-TIME DURABILITY PROBE: it
        reports which declared slots have durable committed data, and `open` uses
        it to FAIL LOUD on a reopen-with-smaller-K (a live shard ordinal >= K =
        orphaned rows). It discovers topology LIVE (NOT a snapshot-pinned epoch —
        the §2.4 topology-epoch pin is DROPPED, §10.3) and tolerates the brief
        duplicate-or-missing window of racing a split; a shard with NO committed
        chunk yet does not appear here. It remains exposed for operational
        introspection (which shards hold data), but it is NOT on the read path."""
        var lineage = ShardedLineage[Self.Store](self._store.clone(), self._part)
        var live = lineage.enumerate_live_shards()
        _ = lineage^
        return live^

    # The cross-partition UNIQUE arbiter builders (`uguard_for` / `heap_control`,
    # the un-partitioned `<part>/_uguard/...` + `<part>/_htxn/...` lineages) were
    # REMOVED (a design decision: match Postgres). A UNIQUE/PK on a K>1
    # table must include the shard key (enforced at DDL), so uniqueness is enforced
    # entirely WITHIN one shard's `_lineage` — no cross-partition guard lineage is
    # needed.

    @always_inline
    def table_prefix(self) -> String:
        """The table key prefix (`<part>`) — the bucket-relative root of
        `<part>/_lineage/<shard_id>/...`."""
        return self._part

    # ---- per-shard COLD-TIER catalog (the agg-routing seam) ---
    #
    # A per-shard `ColumnarCatalog` over shard `slot`'s WAL sub-lineage. The
    # partitioned-table analytical-agg path (route -> per-shard dual-tier fold ->
    # cross-shard combine) builds ONE per the shard it folds, then merges the
    # cold heap splits + the hot WAL tail (LWW + tombstone-suppress) before the
    # agg fold. This is a CALLER-side ON-DEMAND builder (a fresh handle over a
    # `clone()` of the shared store) — NOT a
    # new owned field on this struct: the catalog is a thin `CasManifestStore`
    # handle over `<part>/_lineage/<shard_id>/_columnar`, the SAME sibling
    # manifest the un-partitioned SQL driver's `with_columnar` path opens, so a
    # row columnarized for shard `slot` is read back exactly. Building per-call
    # keeps the reuse-safe struct unchanged (no new slab/field) and keeps the
    # zero-overhead-at-NONE contract (a NONE table never reaches this).

    def shard_columnar(
        self, slot: Int
    ) raises -> CasManifestStore[Self.Store]:
        """The `CasManifestStore` for shard `slot`'s COLUMNAR catalog lineage:
        `<part>/_lineage/<shard_id>/_columnar`. The caller wraps it in a
        `ColumnarCatalog` (the adapter type lives in the columnar adapter package,
        which depends on THIS leaf — so the leaf returns the raw lineage store and
        the driver constructs the `ColumnarCatalog`, keeping the cycle-free
        direction). Backed by a `clone()` of the shared store (same bucket)."""
        var shard_wal_prefix = (
            self._part + "/_lineage/" + self._shard_ids[slot]
        )
        return CasManifestStore[Self.Store](
            store=self._store.clone(),
            prefix=shard_wal_prefix + "/_columnar",
            retry=RetryPolicy.default(),
        )


# =============================================================================
# Free-function helpers.
# =============================================================================


@always_inline
def _partition_shard_id(ordinal: Int) -> String:
    """The stable dense partition-ordinal shard id (`p0`, `p1`, …). DISTINCT from
    the WS-1 per-WRITER `make_shard_id` (node/pid/worker identity): a heap
    keyspace partition is a per-KEY map, so its shards are DENSE ORDINALS the
    catalog records, NOT writer identities. Never the reserved `_base` (the `p`
    prefix keeps the partition shards disjoint from the compactor's `_base`
    fold-target). Stable for the table's lifetime so `route(key) % k` lands the
    same shard across runs."""
    return String("p") + String(ordinal)


def _partition_ordinal_of(shard_id: String) -> Int:
    """Parse the dense ordinal out of a partition shard id (`p7` -> 7). Returns
    -1 if `shard_id` is NOT a `p<digits>` partition id (e.g. the compactor's
    reserved `_base`, or a foreign WS-1 per-writer id) — such ids are not this
    router's declared partition shards and the open-assert ignores them. The
    inverse of `_partition_shard_id`. Parses over the raw ASCII bytes (the
    established char-level idiom; String indexing yields slices, not chars)."""
    var bs = shard_id.as_bytes()
    var n = len(bs)
    if n < 2 or Int(bs[0]) != ord("p"):
        return -1
    var acc = 0
    var zero = ord("0")
    var nine = ord("9")
    for i in range(1, n):
        var c = Int(bs[i])
        if c < zero or c > nine:
            return -1
        acc = acc * 10 + (c - zero)
    return acc
