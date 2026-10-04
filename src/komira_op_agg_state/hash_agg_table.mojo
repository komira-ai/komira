# =============================================================================
# hash_agg_table.mojo — Single-key HashAggTable stage primitive
# =============================================================================
#
# Originally a WSC PHASE-B deliverable (WSC-SPIKE-Q1 1.001× hand-fused gold)
# that backed the single-Int64-key group-by hot path with a fixed-16
# `InlineArray[Slot, MAX_GROUPS=16]` probe table.
#
# DENSE-HASH-AGG Phase 1 (per
# an internal doc §6.2) replaced the fixed-16
# storage with a single GROWING DENSE open-addressing directory
# (`_DenseAggDirectory` in `dense_hash_agg_table.mojo`). This closes the
# `MAX_GROUPS=16` SILENT-SATURATION correctness bug: >16 distinct keys used to
# fall through the bounded probe loop and `return 0`, folding every excess key
# into bucket 0 and producing WRONG group-by answers with no error. The dense
# table grows on load-factor and assigns a STABLE dense `group_id` per group.
#
# The trait/method surface is UNCHANGED (RFC §6.1), so every consumer
# (`runtime_breaker_state.mojo` single-i64-key feed/drain) compiles against the
# same methods. The only domain change: `lookup_or_insert` now returns a dense
# `group_id` in `0..n_groups` (a strictly-larger compatible superset of the old
# 0..15 slot domain), and `capacity()` is runtime. A NEW `size()` method
# returns the dense group count for the drain sweep (the drain sweeps
# `0..size()` instead of the old `0..MAX_GROUPS`).
#
# Architecture: each of the four per-DType tables OWNS a `_DenseAggDirectory`
# (the value-type-agnostic salt-packed directory + dense Int64 key column) plus
# its OWN typed `List[AggOp.StateTy]` agg-state side array, indexed by the dense
# `group_id`. The directory hands back a group_id; the table grows its parallel
# state list in lockstep and scatter-updates state[group_id]. This is the
# typed-state, trampoline-free shape (RFC §5.2 — NO byte-erased fn-ptr).
#
# Encapsulation invariants (the internal development notes hard ban #1, #3, #7, #8, #11):
#   - NO `UnsafePointer` in any public method signature.
#   - NO wildcard origins.
#   - `List[POD]` storage (RFC §7.1 — NOT MmapAlignedBuffer; gap6-safe).
#   - StateTy is parametric over AggOp.StateTy (POD); each conformer picks its
#     own concrete state representation.
#   - `Movable` only (no ArcPointer; single-owner).
#
# Cross-references:
#   - dense_hash_agg_table.mojo — `_DenseAggDirectory` + Knuth hash + probe.
#   - composite_hash_table.mojo — `_CompositeHashTableF64` (the List-storage,
#     open-addressing in-tree template the dense directory mirrors).
#   - komira_eval/agg_op_traits.mojo — HashAggOpF64/I64/I32/F32 traits.
#   - komira_op_agg_state/agg_state_slab.mojo — AggOp conformers.
# =============================================================================

from komira_agg.agg_op_traits import (
    HashAggOpF32,
    HashAggOpF64,
    HashAggOpI32,
    HashAggOpI64,
)

from komira_op_agg_state.dense_hash_agg_table import (
    DENSE_INITIAL_CAPACITY,
    _DenseAggDirectory,
)


# =============================================================================
# §1 — Constants
# =============================================================================

comptime MAX_GROUPS: Int = 16
"""DEPRECATED for the agg tables (DENSE-HASH-AGG Phase 1). Kept ONLY as the
re-exported alias the `HashSetI64` distinct primitive
(`runtime_breaker_state.mojo`) still uses for its bounded-set cap, and as the
historical reference for the bug this module fixed. The four agg tables below
are now GROWING and unbounded-in-group-count (RFC §6.2)."""

comptime EMPTY_KEY: Int64 = -1
"""Legacy empty-slot sentinel from the fixed-16 InlineArray era. The dense
tables no longer use a key sentinel (the salt-packed directory distinguishes
empty slots), so a real key of -1 is now stored correctly. Kept as a
re-exported alias for the `HashSetI64` distinct primitive + legacy drain
call sites that compare `key_at(s) != EMPTY_KEY` — with a dense table every
swept slot `0..size()` is a real group, so that gate is always True."""


# =============================================================================
# §2 — HashAggTableF64 — Float64-state dense hash table
# =============================================================================
#
# Specialized for Float64 per-bucket state (covers SumF64 / CountF64 /
# MinF64 / MaxF64 / MedianF64 — the v0.4 GA Float64 aggs). Owns a
# `_DenseAggDirectory` (salt-packed directory + dense Int64 key column) plus a
# dense `List[StateTy]` agg-state side array indexed by group_id.
# =============================================================================


struct HashAggTableF64[AggOp: HashAggOpF64](Copyable, Movable):
    """Growing dense open-addressing hash table over Int64 keys + Float64 state.

    Per-bucket state init / update / finalize through the parametric `AggOp`
    trait conformer; Mojo's monomorphizer inlines AggOp.init / update_scalar /
    finalize into the call sites (the Q1 spike validated 0 `bl` in the inner
    loop). The directory probe is a salt-gated, odd-stride open-addressing
    scan with grow-on-load-factor (DENSE-HASH-AGG Phase 1) — no longer capped
    at 16 groups.
    """

    var dir: _DenseAggDirectory
    var slabs: List[Self.AggOp.StateTy]

    def __init__(out self):
        """Construct empty growing table at the dense initial capacity."""
        self.dir = _DenseAggDirectory.new(DENSE_INITIAL_CAPACITY)
        self.slabs = List[Self.AggOp.StateTy]()

    @always_inline
    def reset(mut self):
        """Reset table for re-use (e.g. between partitions)."""
        self.dir.reset()
        self.slabs.clear()

    @always_inline
    def lookup_or_insert(mut self, key: Int64) -> Int:
        """Probe-or-insert; returns the dense group_id (0..n_groups). On insert
        the parallel agg-state slab is extended with a fresh `AggOp.init()` so
        `slabs[group_id]` is always valid."""
        var group_id = self.dir.lookup_or_insert(key)
        if group_id == len(self.slabs):
            self.slabs.append(Self.AggOp.init())
        return group_id

    @always_inline
    def update_scalar(mut self, key: Int64, value: Float64):
        """Per-row hot path: lookup or insert group, then update its slab."""
        var slot = self.lookup_or_insert(key)
        Self.AggOp.update_scalar(self.slabs[slot], value)

    @always_inline
    def merge_partial(mut self, key: Int64, partial: Self.AggOp.StateTy):
        """Q1-OPT-5 — merge a per-worker partial agg state
        into the running master table. Looks up or inserts the group, then
        FOLDS via AggOp.combine (Sum -> add, Count -> add counts, Min ->
        keep smaller, Max -> keep larger). This is the post-fork-join merge
        primitive for parallel hash-agg drivers.

        Distinct from update_scalar (which feeds a raw input value through
        the agg's update rule). For Count specifically:
            update_scalar(k, v) -> +1 regardless of v
            merge_partial(k, n) -> +n (correct for merging partial counts)

        `partial` is `AggOp.StateTy` (parametric — Float64 for
        Sum/Count/Min/Max F64; SIMD[float64, 2] for Avg). The caller
        extracts the partial state via `raw_state_at(slot)` on the
        per-worker table.
        """
        var slot = self.lookup_or_insert(key)
        Self.AggOp.combine(self.slabs[slot], partial)

    @always_inline
    def update_chunk[W: Int](
        mut self,
        keys: SIMD[DType.int64, W],
        values: SIMD[DType.float64, W],
        mask: SIMD[DType.bool, W],
    ):
        """Per-SIMD-chunk hot path. Necessarily scalar per-lane (two lanes
        might map to the same group — scatter conflict). DuckDB and Spark also
        unroll scalar here per WSC-SPIKE-Q1 verdict §1.2."""
        for j in range(W):
            if mask[j]:
                self.update_scalar(keys[j], values[j])

    @always_inline
    def finalize_at(self, slot: Int) -> Float64:
        """Read finalized value at a dense group_id (0..size())."""
        return Self.AggOp.finalize(self.slabs[slot])

    @always_inline
    def raw_state_at(self, slot: Int) -> Self.AggOp.StateTy:
        """Q1-OPT-5 — read the RAW per-slot state (NOT
        finalized). For Sum/Count/Min/Max F64 this is the running Float64
        directly; for AvgF64 it's a SIMD[float64, 2] (sum, count) pair.
        Returns the parametric `StateTy` so the caller can pass it back
        through `merge_partial`. Uses explicit `.copy()` to bridge the
        trait's Copyable-but-not-ImplicitlyCopyable bound.
        """
        return self.slabs[slot].copy()

    @always_inline
    def key_at(self, slot: Int) -> Int64:
        """Read key at a dense group_id (0..size())."""
        return self.dir.key_at(slot)

    @always_inline
    def size(self) -> Int:
        """Number of distinct groups (dense drain sweep bound)."""
        return self.dir.size()

    @always_inline
    def capacity(self) -> Int:
        """Runtime directory slot count (power-of-2)."""
        return self.dir.capacity_of()


# =============================================================================
# §3 — HashAggTableI64 — Int64-state dense hash table mirror
# =============================================================================


struct HashAggTableI64[AggOp: HashAggOpI64](Copyable, Movable):
    """Int64-state mirror of HashAggTableF64. Same growing-dense directory,
    different state type (Int64 instead of Float64).

    Covers SumI64 / CountI64 / MinI64 / MaxI64 from agg_state_slab.mojo.
    """

    var dir: _DenseAggDirectory
    var slabs: List[Self.AggOp.StateTy]

    def __init__(out self):
        self.dir = _DenseAggDirectory.new(DENSE_INITIAL_CAPACITY)
        self.slabs = List[Self.AggOp.StateTy]()

    @always_inline
    def reset(mut self):
        self.dir.reset()
        self.slabs.clear()

    @always_inline
    def lookup_or_insert(mut self, key: Int64) -> Int:
        var group_id = self.dir.lookup_or_insert(key)
        if group_id == len(self.slabs):
            self.slabs.append(Self.AggOp.init())
        return group_id

    @always_inline
    def update_scalar(mut self, key: Int64, value: Int64):
        var slot = self.lookup_or_insert(key)
        Self.AggOp.update_scalar(self.slabs[slot], value)

    @always_inline
    def update_chunk[W: Int](
        mut self,
        keys: SIMD[DType.int64, W],
        values: SIMD[DType.int64, W],
        mask: SIMD[DType.bool, W],
    ):
        for j in range(W):
            if mask[j]:
                self.update_scalar(keys[j], values[j])

    @always_inline
    def finalize_at(self, slot: Int) -> Int64:
        return Self.AggOp.finalize(self.slabs[slot])

    @always_inline
    def key_at(self, slot: Int) -> Int64:
        return self.dir.key_at(slot)

    @always_inline
    def size(self) -> Int:
        return self.dir.size()

    @always_inline
    def capacity(self) -> Int:
        return self.dir.capacity_of()


# =============================================================================
# §4 — HashAggTableI32 — Int32-state dense hash table over Int64 keys
# =============================================================================
#
# Mirror of HashAggTableI64 with Int32 value type. Key is still Int64.
# =============================================================================


struct HashAggTableI32[AggOp: HashAggOpI32](Copyable, Movable):
    """Int32-value mirror of HashAggTableI64. Growing-dense directory with
    Int32 instead of Int64 for `update_scalar` value type + `finalize_at`
    return type. Keys remain Int64.

    Covers SumI32 / CountI32 / MinI32 / MaxI32 from agg_state_slab.mojo.
    """

    var dir: _DenseAggDirectory
    var slabs: List[Self.AggOp.StateTy]

    def __init__(out self):
        self.dir = _DenseAggDirectory.new(DENSE_INITIAL_CAPACITY)
        self.slabs = List[Self.AggOp.StateTy]()

    @always_inline
    def reset(mut self):
        self.dir.reset()
        self.slabs.clear()

    @always_inline
    def lookup_or_insert(mut self, key: Int64) -> Int:
        var group_id = self.dir.lookup_or_insert(key)
        if group_id == len(self.slabs):
            self.slabs.append(Self.AggOp.init())
        return group_id

    @always_inline
    def update_scalar(mut self, key: Int64, value: Int32):
        var slot = self.lookup_or_insert(key)
        Self.AggOp.update_scalar(self.slabs[slot], value)

    @always_inline
    def update_chunk[W: Int](
        mut self,
        keys: SIMD[DType.int64, W],
        values: SIMD[DType.int32, W],
        mask: SIMD[DType.bool, W],
    ):
        for j in range(W):
            if mask[j]:
                self.update_scalar(keys[j], values[j])

    @always_inline
    def finalize_at(self, slot: Int) -> Int32:
        return Self.AggOp.finalize(self.slabs[slot])

    @always_inline
    def key_at(self, slot: Int) -> Int64:
        return self.dir.key_at(slot)

    @always_inline
    def size(self) -> Int:
        return self.dir.size()

    @always_inline
    def capacity(self) -> Int:
        return self.dir.capacity_of()


# =============================================================================
# §5 — HashAggTableF32 — Float32-state dense hash table over Int64 keys
# =============================================================================
#
# Mirror of HashAggTableF64 with Float32 value type. Covers SumF32 /
# CountF32 / MinF32 / MaxF32 from agg_state_slab.mojo §4.
# =============================================================================


struct HashAggTableF32[AggOp: HashAggOpF32](Copyable, Movable):
    """Float32-value mirror of HashAggTableF64. Int64 keys + Float32 state."""

    var dir: _DenseAggDirectory
    var slabs: List[Self.AggOp.StateTy]

    def __init__(out self):
        self.dir = _DenseAggDirectory.new(DENSE_INITIAL_CAPACITY)
        self.slabs = List[Self.AggOp.StateTy]()

    @always_inline
    def reset(mut self):
        self.dir.reset()
        self.slabs.clear()

    @always_inline
    def lookup_or_insert(mut self, key: Int64) -> Int:
        var group_id = self.dir.lookup_or_insert(key)
        if group_id == len(self.slabs):
            self.slabs.append(Self.AggOp.init())
        return group_id

    @always_inline
    def update_scalar(mut self, key: Int64, value: Float32):
        var slot = self.lookup_or_insert(key)
        Self.AggOp.update_scalar(self.slabs[slot], value)

    @always_inline
    def update_chunk[W: Int](
        mut self,
        keys: SIMD[DType.int64, W],
        values: SIMD[DType.float32, W],
        mask: SIMD[DType.bool, W],
    ):
        for j in range(W):
            if mask[j]:
                self.update_scalar(keys[j], values[j])

    @always_inline
    def finalize_at(self, slot: Int) -> Float32:
        return Self.AggOp.finalize(self.slabs[slot])

    @always_inline
    def key_at(self, slot: Int) -> Int64:
        return self.dir.key_at(slot)

    @always_inline
    def size(self) -> Int:
        return self.dir.size()

    @always_inline
    def capacity(self) -> Int:
        return self.dir.capacity_of()
