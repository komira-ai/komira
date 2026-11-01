# =============================================================================
# Two-layer plan-compile cache
# =============================================================================
#
# The cache machinery (insert / lookup / LRU eviction) WITHOUT the
# pass-1/pass-2 compilation pipeline. The contract is narrow: the shapes and
# traits, with the real wiring left as hooks called by the materialize path.
#
# Two-layer model:
#
#   Layer 1 -- factory cache (source-agnostic, cardinality-independent):
#     Slab[OptimizedLogicalPlan] keyed by structural_hash(LogicalPlan).
#     Universal participation: any plan caches here.
#
#   Layer 2 -- resolved cache (carries a compiled-plan placeholder + LRU clock):
#     Slab[ResolvedCacheEntry] keyed by hash_combine(factory_hash, stats_hash).
#     Capped at RESOLVED_CACHE_CAP (64) entries with LRU eviction.
#     Pin-counted via ref_count for in-flight paginated results.
#
# Prior art:
#   * DuckDB plan cache (`client_context.cpp`, the always_require_rebind
#     path): a prepared statement re-binds on every execution but caches the
#     optimized logical plan.
#   * DataFusion has no plan cache (every execution re-plans).
#   * `Slab[T] + Dict[key, idx]` is the pattern the engine context already uses
#     for its serial-access, context-scoped caches (the parquet stats cache).
#
# Concurrency: NOT thread-safe. Mutated only from the EngineContext-
# owning thread (plan-compile path is SERIAL by EngineContext invariant).
# =============================================================================

from std.collections import Dict
from std.memory import OwnedPointer
from std.testing import assert_true

from komira_collections.slab import Slab
from komira_plan_ir.logical_plan import (
    LogicalPlan,
    PLAN_SCAN,
    PLAN_FILTER,
    PLAN_PROJECT,
    PLAN_AGGREGATE,
    PLAN_JOIN,
    PLAN_SORT,
    PLAN_LIMIT,
    PLAN_DISTINCT,
    PLAN_TOPN,
    PLAN_PARTITION_BY,
    PLAN_PARTITION_TOPN,
    PLAN_ASOF_JOIN,
    PLAN_CAST_TO_VARCHAR,
)
# THE TAGS, AND DELIBERATELY NOT `sink_variant`. This module names sixteen
# `UInt8` arm-lookup integers to widen a cache key; it names no sink TYPE, opens
# no file and writes nothing. Importing them from the sink variant module would
# put the file sink, the arrow codec/format vocabulary, the dispatcher, the
# cancellation token and the no-op sink into this translation unit, and through
# them the parquet reader, the filesystem ladder and the engine runtime.
#
# DO NOT "SIMPLIFY" THIS BACK TO `sink_variant`. It compiles either way and the
# sixteen values are identical, so nothing would go red on that edit.
from .sink_variant_tags import (
    SINK_VARIANT_FILE_PARQUET_SNAPPY,
    SINK_VARIANT_FILE_PARQUET_ZSTD,
    SINK_VARIANT_FILE_PARQUET_UNCOMPRESSED,
    SINK_VARIANT_FILE_PARQUET_GZIP,
    SINK_VARIANT_FILE_PARQUET_LZ4,
    SINK_VARIANT_FILE_CSV,
    SINK_VARIANT_FILE_CSV_GZIP,
    SINK_VARIANT_FILE_CSV_ZSTD,
    SINK_VARIANT_FILE_CSV_LZ4,
    SINK_VARIANT_FILE_JSONL,
    SINK_VARIANT_FILE_JSONL_GZIP,
    SINK_VARIANT_FILE_JSONL_ZSTD,
    SINK_VARIANT_FILE_JSONL_LZ4,
    SINK_VARIANT_FILE_ARROW_UNCOMPRESSED,
    SINK_VARIANT_FILE_ARROW_LZ4_FRAME,
    SINK_VARIANT_FILE_ARROW_ZSTD,
)


# -----------------------------------------------------------------------------
# Cap on Layer 2 resolved cache (LRU eviction kicks in past this)
# -----------------------------------------------------------------------------

comptime RESOLVED_CACHE_CAP: Int = 64
"""Maximum number of resolved entries kept in Layer 2 cache.

Rationale: notebook / bench workloads exercise <16 distinct
plan-shape × stats-shape combos in practice. 64 provides 4x headroom and
keeps the LRU scan O(64) — negligible against the cost of a cache hit
(which avoids the entire optimize → plan_compile → engine_dispatch
build path).
"""


# -----------------------------------------------------------------------------
# hash_combine — Layer 2 key derivation
# -----------------------------------------------------------------------------
#
# 64-bit hash mix taken from boost::hash_combine, mirroring the FNV-1a prime
# already used by `LogicalPlan.structural_hash`.


@always_inline
def hash_combine(a: UInt64, b: UInt64) -> UInt64:
    """Combine two 64-bit hashes into one (boost::hash_combine analog).

    Used to derive the Layer 2 cache key from (factory_hash, stats_hash).
    The FNV-1a prime keeps the mix avalanching for the small-input case
    (two 64-bit fingerprints).
    """
    return (a ^ b) * 0x100000001B3


# -----------------------------------------------------------------------------
# OptimizedLogicalPlan — Layer 1 entry
# -----------------------------------------------------------------------------


struct OptimizedLogicalPlan(Movable, Deinitable):
    """Post-pass-1 LogicalPlan: stats-independent optimizations applied.

    This struct carries only the optimized plan: it is a thin wrapper that
    lets the Layer 1 cache be exercised. The full pass-1 pipeline (constant
    folding, predicate canonicalization, source-set capture) is not part of
    it. A `source_set: List[SourceVariant]` field would let Layer 2
    invalidation compare source identities without re-walking the plan.

    Movable-only; explicit `copy()` mirrors `LogicalPlan` (plan types are
    Movable + explicit clone, never auto-Copyable).
    """

    var plan: LogicalPlan

    def __init__(out self, var plan: LogicalPlan):
        self.plan = plan^

    def copy(self) -> Self:
        return OptimizedLogicalPlan(self.plan.copy())


# -----------------------------------------------------------------------------
# ResolvedCacheEntry — Layer 2 entry
# -----------------------------------------------------------------------------


struct ResolvedCacheEntry(Movable, Deinitable):
    """Layer 2 cache entry: factory_hash + stats_hash → resolved plan.

    Contract:
      * `compiled_placeholder: String` stands in for a compiled physical
        plan, which this module does not build.
      * `last_access: UInt64` is the LRU clock value sampled on every
        cache hit / insert.
      * `ref_count: UInt32` is the pin counter that `pin_resolved` and
        `unpin_resolved` move.

    Layer 2 invariant: an entry with `ref_count > 0` MUST NOT be evicted
    (eviction would invalidate an in-flight streaming consumer). The LRU
    helper enforces this by skipping pinned entries; if all entries are
    pinned the helper raises.
    """

    var factory_hash: UInt64
    var stats_hash: UInt64
    var compiled_placeholder: String
    var last_access: UInt64
    var ref_count: UInt32

    def __init__(
        out self,
        factory_hash: UInt64,
        stats_hash: UInt64,
        var placeholder: String,
        last_access: UInt64,
    ):
        self.factory_hash = factory_hash
        self.stats_hash = stats_hash
        self.compiled_placeholder = placeholder^
        self.last_access = last_access
        self.ref_count = UInt32(0)


# -----------------------------------------------------------------------------
# PlanCompileCache — composite Layer 1 + Layer 2 store
# -----------------------------------------------------------------------------


struct PlanCompileCache(Movable, Deinitable):
    """Composite Layer 1 (factory) + Layer 2 (resolved) cache.

    Carved out of EngineContext to keep the session context file small and to
    keep the cache machinery testable in isolation. EngineContext holds one
    instance and exposes `plan_compile_cache_mut()` for the materialize path.

    Storage shape:
      * `_factory_slab: Slab[OptimizedLogicalPlan]` — owns the entries.
      * `_factory_keys: Dict[UInt64, Int]` — structural_hash → slab idx.
      * `_resolved_slab: Slab[ResolvedCacheEntry]` — owns the entries.
      * `_resolved_keys: Dict[UInt64, Int]` — hash_combine(factory, stats) → idx.
      * `_resolved_clock: UInt64` — monotonic LRU clock.

    Concurrency: NOT thread-safe (matches EngineContext SERIAL invariant).
    """

    var _factory_slab: Slab[OptimizedLogicalPlan]
    var _factory_keys: Dict[UInt64, Int]

    var _resolved_slab: Slab[ResolvedCacheEntry]
    var _resolved_keys: Dict[UInt64, Int]
    var _resolved_clock: UInt64

    # -------------------------------------------------------------------------
    # Construction
    # -------------------------------------------------------------------------

    def __init__(out self):
        """Construct an empty two-layer cache."""
        self._factory_slab = Slab[OptimizedLogicalPlan]()
        self._factory_keys = Dict[UInt64, Int]()
        self._resolved_slab = Slab[ResolvedCacheEntry]()
        self._resolved_keys = Dict[UInt64, Int]()
        self._resolved_clock = UInt64(0)

    # -------------------------------------------------------------------------
    # Size accessors (test surface)
    # -------------------------------------------------------------------------

    @always_inline
    def factory_len(self) -> Int:
        return len(self._factory_slab)

    @always_inline
    def resolved_len(self) -> Int:
        return len(self._resolved_slab)

    @always_inline
    def resolved_clock(self) -> UInt64:
        return self._resolved_clock

    # -------------------------------------------------------------------------
    # Layer 1 (factory) — lookup / insert
    # -------------------------------------------------------------------------

    def factory_lookup(self, structural_hash: UInt64) raises -> Optional[Int]:
        """Return the slab idx of the cached OptimizedLogicalPlan if any.

        Layer 1 has no LRU — entries live as long as the EngineContext
        (factory plans are small + stats-independent, so the working set
        is bounded by plan-shape diversity, not by execution count).

        Mojo 1.0.0b1: `Dict.__getitem__` is `raises` (key-missing throws),
        so this `def` must opt-in to `raises ->` even though we `in`-check
        first.
        """
        if structural_hash in self._factory_keys:
            return Optional[Int](self._factory_keys[structural_hash])
        return Optional[Int](None)

    def factory_insert(
        mut self, structural_hash: UInt64, var entry: OptimizedLogicalPlan
    ):
        """Insert an OptimizedLogicalPlan into Layer 1.

        Caller must have already checked `factory_lookup` returned None;
        duplicate inserts at the same key overwrite the index (the old
        slab slot leaks until EngineContext drop — acceptable for the
        small Layer 1 working set).
        """
        self._factory_slab.append(entry^)
        var idx = self._factory_slab.len() - 1
        self._factory_keys[structural_hash] = idx

    def clear_factory(mut self):
        """Drop every Layer-1 entry. THE EVICTION VERB LAYER 1 NEVER HAD.

        ⚠ `factory_lookup`'s docstring justifies the missing LRU with "factory
        plans are SMALL + stats-independent, so the working set is bounded by
        plan-shape diversity, not by execution count". The second half is true.
        The FIRST half is a property of the plans this cache was written for,
        not of `LogicalPlan`: a plan whose scan leaf is an `InMemorySource`
        owns its payload through `SourceVariant._in_memory`, and
        `LogicalPlan.copy()` FORWARDS that `ArcPointer` — so `factory_insert`
        takes a retaining reference to the whole batch and Layer 1, having no
        eviction, holds it for the life of the `EngineContext`.

        That is not hypothetical: the H1 row->column demote decodes a whole CSV
        into one `InMemorySource` batch, and one such plan measured 8.4 GiB
        resident on `csv_row_agg_lineitem`.

        This verb exists so the retention can be MEASURED (drop, re-read RSS)
        and so a long-lived context has a way to reclaim. It is NOT the policy
        fix — see `EngineContext._prepare_plan`'s insert site, which now
        DECLINES to cache a payload-owning plan at all.
        """
        self._factory_slab = Slab[OptimizedLogicalPlan]()
        self._factory_keys = Dict[UInt64, Int]()

    def factory_clone_plan(self, idx: Int) -> LogicalPlan:
        """Clone the cached optimized LogicalPlan at slab idx `idx`.

        Hot path: materialize() calls this after a Layer 1 HIT
        to retrieve an executable LogicalPlan without re-running
        `optimize()`. Returns a deep clone (LogicalPlan is Movable-only;
        the original stays in the cache for subsequent hits).
        """
        return self._factory_slab[idx].plan.copy()

    # -------------------------------------------------------------------------
    # Layer 2 (resolved) — lookup / insert / LRU
    # -------------------------------------------------------------------------

    def resolved_lookup(
        mut self, factory_hash: UInt64, stats_hash: UInt64
    ) raises -> Optional[Int]:
        """Return the slab idx of the cached ResolvedCacheEntry if any.

        On a HIT, bumps `last_access` to the current clock value. This
        is the LRU touch — the entry moves to MRU position by virtue of
        carrying the largest clock value.
        """
        var key = hash_combine(factory_hash, stats_hash)
        if key in self._resolved_keys:
            var idx = self._resolved_keys[key]
            self._resolved_clock += UInt64(1)
            # Mutate last_access through the Slab ref-borrow. Slab's
            # `__getitem__` returns `ref [self._bytes] ResolvedCacheEntry`
            # which is mutable when `self` is `mut` — direct field
            # assignment is the canonical idiom.
            self._resolved_slab[idx].last_access = self._resolved_clock
            return Optional[Int](idx)
        return Optional[Int](None)

    def resolved_insert(
        mut self,
        factory_hash: UInt64,
        stats_hash: UInt64,
        var entry: ResolvedCacheEntry,
    ) raises:
        """Insert a ResolvedCacheEntry into Layer 2; evict if at cap.

        Raises if all entries at cap are pinned (ref_count > 0).

        Stamps `entry.last_access` with a fresh clock value before
        insertion so subsequent LRU comparisons see a coherent ordering.
        """
        if len(self._resolved_keys) >= RESOLVED_CACHE_CAP:
            self._evict_lru_unpinned()
        self._resolved_clock += UInt64(1)
        entry.last_access = self._resolved_clock
        self._resolved_slab.append(entry^)
        var idx = self._resolved_slab.len() - 1
        var key = hash_combine(factory_hash, stats_hash)
        self._resolved_keys[key] = idx

    def _evict_lru_unpinned(mut self) raises:
        """Evict the entry with smallest last_access AND ref_count == 0.

        Linear scan over `_resolved_slab`. Picks the un-pinned entry
        with the smallest `last_access`. Removes from `_resolved_keys`
        (by rebuilding the dict — Mojo 1.0.0b1 has no `Dict.pop()`-by-
        value) and from `_resolved_slab` via `take_at(idx)`.

        Raises if every entry is pinned.
        """
        var n = self._resolved_slab.len()
        var best_idx = -1
        var best_clock = UInt64(0)
        for i in range(n):
            var entry_clock = self._resolved_slab[i].last_access
            var entry_pinned = self._resolved_slab[i].ref_count > UInt32(0)
            if entry_pinned:
                continue
            if best_idx < 0 or entry_clock < best_clock:
                best_idx = i
                best_clock = entry_clock
        if best_idx < 0:
            raise Error(
                "PlanCompileCache: all "
                + String(n)
                + " resolved entries are pinned; cannot evict"
            )
        # Find the dict key whose value == best_idx and remove it; then
        # shift dict idx values > best_idx down by 1 to mirror
        # Slab.take_at's left-shift.
        var victim_key: UInt64 = UInt64(0)
        var found_key = False
        for entry_kv in self._resolved_keys.items():
            if entry_kv.value == best_idx:
                victim_key = entry_kv.key
                found_key = True
                break
        if found_key:
            _ = self._resolved_keys.pop(victim_key)
        # Re-pack idx mappings post-take_at.
        var new_keys = Dict[UInt64, Int]()
        for entry_kv in self._resolved_keys.items():
            var new_idx = entry_kv.value
            if new_idx > best_idx:
                new_idx -= 1
            new_keys[entry_kv.key] = new_idx
        self._resolved_keys = new_keys^
        _ = self._resolved_slab.take_at(best_idx)

    # -------------------------------------------------------------------------
    # Pin / unpin (the hook an in-flight paginated result holds)
    # -------------------------------------------------------------------------

    def pin_resolved(mut self, idx: Int):
        """Increment ref_count on the resolved entry at `idx`.

        Called by the context while a paginated result is open, so the
        entry cannot be evicted under it.
        """
        self._resolved_slab[idx].ref_count += UInt32(1)

    def unpin_resolved(mut self, idx: Int):
        """Decrement ref_count on the resolved entry at `idx`."""
        if self._resolved_slab[idx].ref_count > UInt32(0):
            self._resolved_slab[idx].ref_count -= UInt32(1)

    @always_inline
    def is_pinned(self, idx: Int) -> Bool:
        return self._resolved_slab[idx].ref_count > UInt32(0)

    # -------------------------------------------------------------------------
    # Borrowing accessors (read-only field reach for tests)
    # -------------------------------------------------------------------------

    @always_inline
    def resolved_factory_hash(self, idx: Int) -> UInt64:
        return self._resolved_slab[idx].factory_hash

    @always_inline
    def resolved_stats_hash(self, idx: Int) -> UInt64:
        return self._resolved_slab[idx].stats_hash

    @always_inline
    def resolved_last_access(self, idx: Int) -> UInt64:
        return self._resolved_slab[idx].last_access

    @always_inline
    def resolved_placeholder(self, idx: Int) -> String:
        return self._resolved_slab[idx].compiled_placeholder


# -----------------------------------------------------------------------------
# Stats-hash bucketing
# -----------------------------------------------------------------------------
#
# A "stats hash" for Layer 2 cache keying is the bucketed
# cardinality fingerprint of the plan's inputs. The bucketing function is
# `floor(log2(row_count))` per leaf scan — bucket boundaries at powers of two
# (1, 2, 4, 8, ...). Two plans whose scans land in the same log2 buckets
# share a stats_hash; a plan whose largest scan jumps from 1K to 1M rows
# falls into a different bucket and triggers a re-specialization.
#
# Why log2 bucketing: re-optimizing a plan when the row-count changes by 1
# is wasteful (the plan is identical); re-optimizing when the row-count
# changes by 1000x is essential (different join order, different build side,
# different aggregate hashtable sizing). Log2 bucketing strikes the balance.
#
# Estimate-rows fallback: when `source.estimate_rows() == -1` (e.g. a
# ParquetSource whose footer hasn't been parsed yet, or any future source
# that can't cheaply estimate rows), the bucket is `UInt64(0)` — coincides
# with the "1 row" bucket so unknown-cardinality plans cache like
# small-cardinality plans. This is conservative: a cache miss is cheap, a
# stale specialized plan is not.


@always_inline
def _floor_log2(x: UInt64) -> UInt64:
    """Bit-width-based `floor(log2(x))`. Returns 0 for x == 0 (so the
    "unknown rows" path collapses to bucket 0 with row=1).

    Mojo 1.0.0b1 doesn't expose a stdlib `bit_length` on UInt64; we
    walk the bits explicitly. Cost is O(64) worst case — negligible
    against any cache-hit / cache-miss path.
    """
    if x == UInt64(0):
        return UInt64(0)
    var v = x
    var b: UInt64 = UInt64(0)
    while v > UInt64(1):
        v = v >> UInt64(1)
        b += UInt64(1)
    return b


def _stats_hash_walk(plan: LogicalPlan) raises -> UInt64:
    """Recursively walk the plan tree, folding each PLAN_SCAN's
    `floor(log2(estimate_rows))` bucket into a running hash.

    Bucket derivation per leaf: `_floor_log2(scan.source.estimate_rows())`.
    Combine via `hash_combine` so the order in which scans appear (tree
    walk order) is captured — two plans with the same scans in different
    positions produce different stats_hashes (e.g. swapped JoinData
    left/right after a reorder pass).

    `estimate_rows() == -1` (unknown) is treated as bucket 0 (see above).
    """
    if plan.tag == PLAN_SCAN:
        ref scan = plan.scan_data_ref()
        var n = scan.source.estimate_rows()
        var rows_u: UInt64
        if n < 0:
            rows_u = UInt64(0)
        else:
            rows_u = UInt64(n)
        return _floor_log2(rows_u) + UInt64(1)  # +1 so bucket 0 (== "unknown" or "1 row")
                                                # still folds as non-zero salt.
    elif plan.tag == PLAN_FILTER:
        var h = _stats_hash_walk(plan._filter.value()[].child[])
        return hash_combine(h, UInt64(0x01))
    elif plan.tag == PLAN_PROJECT:
        var h = _stats_hash_walk(plan._project.value()[].child[])
        return hash_combine(h, UInt64(0x02))
    elif plan.tag == PLAN_AGGREGATE:
        var h = _stats_hash_walk(plan._aggregate.value()[].child[])
        return hash_combine(h, UInt64(0x03))
    elif plan.tag == PLAN_JOIN:
        var l = _stats_hash_walk(plan._join.value()[].left[])
        var r = _stats_hash_walk(plan._join.value()[].right[])
        # Distinguish left vs right by hashing-in side salts BEFORE combining
        # so a `(big LEFT JOIN small)` and a `(small LEFT JOIN big)` (post-
        # reorder) produce different stats_hashes — they specialize differently
        # (build-side selection, hash-table sizing).
        return hash_combine(
            hash_combine(l, UInt64(0xA1)),
            hash_combine(r, UInt64(0xA2)),
        )
    elif plan.tag == PLAN_SORT:
        var h = _stats_hash_walk(plan._sort.value()[].child[])
        return hash_combine(h, UInt64(0x05))
    elif plan.tag == PLAN_LIMIT:
        var h = _stats_hash_walk(plan._limit.value()[].child[])
        return hash_combine(h, UInt64(0x06))
    elif plan.tag == PLAN_DISTINCT:
        var h = _stats_hash_walk(plan._distinct.value()[].child[])
        return hash_combine(h, UInt64(0x07))
    elif plan.tag == PLAN_TOPN:
        var h = _stats_hash_walk(plan._topn.value()[].child[])
        return hash_combine(h, UInt64(0x08))
    elif plan.tag == PLAN_PARTITION_BY:
        var h = _stats_hash_walk(plan._partition_by.value()[].child[])
        return hash_combine(h, UInt64(0x09))
    elif plan.tag == PLAN_PARTITION_TOPN:
        var h = _stats_hash_walk(plan._partition_topn.value()[].child[])
        return hash_combine(h, UInt64(0x0A))
    elif plan.tag == PLAN_ASOF_JOIN:
        var l = _stats_hash_walk(plan._asof_join.value()[].left[])
        var r = _stats_hash_walk(plan._asof_join.value()[].right[])
        return hash_combine(
            hash_combine(l, UInt64(0xB1)),
            hash_combine(r, UInt64(0xB2)),
        )
    elif plan.tag == PLAN_CAST_TO_VARCHAR:
        # cast_to_varchar: passthrough cardinality (the cast
        # does not change row count). Salt with 0x0B so a cast-wrapped plan
        # gets a distinct stats_hash from the unwrapped sibling.
        var h = _stats_hash_walk(plan._cast_to_varchar.value()[].child[])
        return hash_combine(h, UInt64(0x0B))
    return UInt64(0)


def compute_stats_hash(plan: LogicalPlan) raises -> UInt64:
    """Compute the log2-bucketed cardinality fingerprint of `plan`.

    Public Layer 2 cache-key derivation. The hash is
    stable under `plan.copy()` (the walker only reads `estimate_rows()`,
    which is stable through the SourceVariant deep-clone contract) and
    discriminates plans whose leaf scans land in different log2 buckets.
    """
    return _stats_hash_walk(plan)


# -----------------------------------------------------------------------------
# Sink config hash — cache-key extension
# -----------------------------------------------------------------------------
#
# The plan-compile cache key folds the
# feeding sink's SHAPE (format family + codec) so two ctx.run calls with
# different sink kinds do NOT alias to the same cache entry. The path is
# EXCLUDED from the hash so `write_csv("/a")` and `write_csv("/b")` share
# the same Layer 2 cache entry (the only difference is the output filename;
# the compiled plan is identical).
#
# Today's SinkVariant carries no per-instance options beyond the (tag,
# path); per-codec options (compression level, CSV delimiter, JSONL
# pretty-print) are baked into the tag itself (one tag per (format,
# codec) pair). So this hash currently maps SinkVariant tags 1:1 to
# salt UInt64 values. Per-call delimiter / quote / header_emit options
# would have to be folded in here as well.

@always_inline
def _sink_variant_config_hash(sink_kind: UInt8) -> UInt64:
    """Per-SinkVariant config fingerprint (excludes path).

    The salt UInt64 for each known SinkVariant tag is a per-tag constant
    plus a coarse family-class top byte (0xCA for CSV, 0xCD for JSONL,
    0xPA for Parquet, 0xAA for Arrow IPC) so unrelated formats produce
    far-apart hashes. UNKNOWN tags fall back to 0 so cache-key derivation
    stays well-defined for sink types that haven't been wired through
    this helper yet (future Sink trait implementors).
    """
    if sink_kind == SINK_VARIANT_FILE_PARQUET_SNAPPY:
        return UInt64(0xA001)
    elif sink_kind == SINK_VARIANT_FILE_PARQUET_ZSTD:
        return UInt64(0xA002)
    elif sink_kind == SINK_VARIANT_FILE_PARQUET_UNCOMPRESSED:
        return UInt64(0xA003)
    elif sink_kind == SINK_VARIANT_FILE_PARQUET_GZIP:
        return UInt64(0xA004)
    elif sink_kind == SINK_VARIANT_FILE_PARQUET_LZ4:
        # The 5th Parquet codec (LZ4_RAW).
        return UInt64(0xA005)
    elif sink_kind == SINK_VARIANT_FILE_CSV:
        return UInt64(0xCA01)
    elif sink_kind == SINK_VARIANT_FILE_CSV_GZIP:
        return UInt64(0xCA02)
    elif sink_kind == SINK_VARIANT_FILE_CSV_ZSTD:
        return UInt64(0xCA03)
    elif sink_kind == SINK_VARIANT_FILE_CSV_LZ4:
        return UInt64(0xCA04)
    elif sink_kind == SINK_VARIANT_FILE_JSONL:
        return UInt64(0xCD01)
    elif sink_kind == SINK_VARIANT_FILE_JSONL_GZIP:
        return UInt64(0xCD02)
    elif sink_kind == SINK_VARIANT_FILE_JSONL_ZSTD:
        return UInt64(0xCD03)
    elif sink_kind == SINK_VARIANT_FILE_JSONL_LZ4:
        return UInt64(0xCD04)
    elif sink_kind == SINK_VARIANT_FILE_ARROW_UNCOMPRESSED:
        return UInt64(0xAA01)
    elif sink_kind == SINK_VARIANT_FILE_ARROW_LZ4_FRAME:
        return UInt64(0xAA02)
    elif sink_kind == SINK_VARIANT_FILE_ARROW_ZSTD:
        return UInt64(0xAA03)
    return UInt64(0)


def compose_full_cache_key(
    structural_hash: UInt64,
    stats_hash: UInt64,
    sink_kind: UInt8,
) -> UInt64:
    """Compose the Layer 2 cache key from (structural_hash, stats_hash,
    sink_kind).

    Three-way `hash_combine` over the structural plan fingerprint, the
    log2-bucketed cardinality fingerprint, and the per-SinkVariant
    config salt. Path is excluded — two `write_csv` calls with different
    paths share the same Layer 2 key.
    """
    var sink_h = _sink_variant_config_hash(sink_kind)
    return hash_combine(structural_hash, hash_combine(stats_hash, sink_h))
