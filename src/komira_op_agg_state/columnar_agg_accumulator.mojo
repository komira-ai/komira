# =============================================================================
# ColumnarAccumulator — tagged-union accumulator for ColumnarAggMap (Slice 3a)
# =============================================================================
#
# Ports v0.3 `ColumnarAccumulatorEnum` from
# `komira-engine/src/aggregate/columnar_map.rs`. Variable-width accumulators
# (MinUtf8, MaxUtf8) and fixed-width accumulators co-located next to them
# (SumInt64, CountInt64) live here as a tagged struct rather than a true
# Mojo sum type (Mojo has no enum-with-data).
#
# Slice 3a scope (per agg_v03_port_playbook.md Section 4 Step 3):
#   - Variants: MinUtf8, MaxUtf8, SumInt64, CountInt64
#   - No sink integration yet (that's Slice 3d)
#   - No partition-flush serialization yet (that's Slice 3c)
#   - Percentile/CountDistinct/UDAF variants deferred (out of scope for Step 3)
#
# Storage layout (split by tag — only the relevant List is populated):
#   - MinUtf8/MaxUtf8: `utf8_values: List[Optional[String]]`
#     None == group has not yet seen a value. Updates do `<=`/`>=` compare.
#   - SumInt64:       `int64_values: List[Int64]`  (0 init == additive identity)
#   - CountInt64:     `int64_values: List[Int64]`  (0 init == count zero)
#
# Group IDs are dense indices: caller invokes `ensure_capacity(num_groups)` to
# grow the backing List, then `update(gid, ...)`. Mirrors v0.3's invariant that
# `ArenaGroupStore` and each `ColumnarAccumulatorEnum` column grow in lockstep.
#
# Movable-only (owns List). Do NOT add Copyable — that would silently alias
# inner string buffers and break merge semantics.
# =============================================================================

from std.sys import simd_width_of
from komira_plan_expr.agg_expr import AGG_SUM, AGG_COUNT, AGG_MIN, AGG_MAX


# Accumulator variant tags. Intentionally distinct from AccTypeTag in the sink —
# these are the *physical* layout tags for ColumnarAggMap, not the logical
# AggExpr kinds. A logical MIN on a string column maps to ACC_MIN_UTF8 here;
# MIN on an Int64 would map to a fixed-width path handled by FlatHashAggregator
# (not by this struct).
comptime ACC_MIN_UTF8: UInt8 = 0
comptime ACC_MAX_UTF8: UInt8 = 1
comptime ACC_SUM_INT64: UInt8 = 2
comptime ACC_COUNT_INT64: UInt8 = 3
# Phase 0d follow-up: typed-Int64 MIN/MAX tags for the AccumulatorEnum SoA
# path. These do NOT live in this legacy AoS `ColumnarAccumulator` (which
# only carries the original 4 variants); they exist purely so AccumulatorEnum
# can route SIMD `merge_aligned` for MinI64Acc / MaxI64Acc kernels declared
# in `columnar_acc_typed.mojo`. Co-located with the other tags so all
# physical-layout discriminants live in one file (single source of truth).
comptime ACC_MIN_INT64: UInt8 = 4
comptime ACC_MAX_INT64: UInt8 = 5
# Phase 0e.2: PercentileAcc lives ONLY in AccumulatorEnum (no AoS counterpart in
# this legacy struct). Tag is 6 (next free after the 0d MIN/MAX_INT64 tags) so
# all physical-layout discriminants stay in this single source of truth file.
# Reserve tag 7 for 0e.1 Kahan (parallel landing — coordinate via this comment).
comptime ACC_PERCENTILE_F64: UInt8 = 6
# Phase 1B Stage 1C: 5 new dispatch tags consumed by Stage 2 variant ports
# on ColumnarAggMap's tag-dispatch table. Tag values 7-11 follow the
# existing sequential numbering. Each tag maps to a single concrete
# accumulator kernel:
#   ACC_SUM_F64    -> SumF64KahanAcc      (columnar_acc_typed.mojo)
#   ACC_COUNT_STAR -> CountStarAcc        (columnar_acc_typed_extra.mojo)
#   ACC_MIN_F64    -> MinF64Acc           (columnar_acc_typed_extra.mojo)
#   ACC_MAX_F64    -> MaxF64Acc           (columnar_acc_typed_extra.mojo)
#   ACC_AVG        -> AvgAcc              (columnar_acc_typed_extra.mojo)
#
# Note on namespace: the same prefix `ACC_*` is used in agg_layout.mojo for
# FlatHashAggregator slot-width tags (a different dispatch axis, distinct
# value space, comptime UInt8). Both modules are never imported together;
# the names are unambiguous because each importer reaches into exactly one
# tag namespace at a time. See agg_layout.mojo header for the slot-width
# dispatch axis.
comptime ACC_SUM_F64: UInt8 = 7
comptime ACC_COUNT_STAR: UInt8 = 8
comptime ACC_MIN_F64: UInt8 = 9
comptime ACC_MAX_F64: UInt8 = 10
comptime ACC_AVG: UInt8 = 11


struct ColumnarAccumulator(Movable):
    """Tagged-union accumulator column indexed by dense group ID.

    One instance = one aggregate function's state across all groups.
    Slice 3a supports MinUtf8, MaxUtf8, SumInt64, CountInt64.
    """

    var tag: UInt8
    # Populated iff tag in {ACC_MIN_UTF8, ACC_MAX_UTF8}. None == group unseen.
    var utf8_values: List[Optional[String]]
    # Populated iff tag in {ACC_SUM_INT64, ACC_COUNT_INT64}. Zero-initialized.
    var int64_values: List[Int64]

    def __init__(out self, tag: UInt8):
        """Private base constructor. Prefer the `new_*` factory functions."""
        self.tag = tag
        self.utf8_values = List[Optional[String]]()
        self.int64_values = List[Int64]()

    # ------------------------------------------------------------------
    # Factory constructors (match v0.3's ColumnarAccumulatorEnum::new_*)
    # ------------------------------------------------------------------

    @staticmethod
    def new_min_utf8() -> Self:
        return Self(ACC_MIN_UTF8)

    @staticmethod
    def new_max_utf8() -> Self:
        return Self(ACC_MAX_UTF8)

    @staticmethod
    def new_sum_int64() -> Self:
        return Self(ACC_SUM_INT64)

    @staticmethod
    def new_count_int64() -> Self:
        return Self(ACC_COUNT_INT64)

    # ------------------------------------------------------------------
    # Capacity management
    # ------------------------------------------------------------------

    def ensure_capacity(mut self, num_groups: Int):
        """Grow backing List so that indices [0, num_groups) are addressable.

        Mirrors the invariant in v0.3 `columnar_map.rs` where the accumulator
        column is resized in lockstep with `ArenaGroupStore::num_groups()`.
        New slots are identity-initialized (None for utf8, 0 for int64).
        """
        # PERF-CRITICAL: called once per incoming morsel after probe_or_insert
        # grows the group count; single-pass extend is O(delta), not O(N).
        if self.tag == ACC_MIN_UTF8 or self.tag == ACC_MAX_UTF8:
            while len(self.utf8_values) < num_groups:
                self.utf8_values.append(Optional[String](None))
        else:
            while len(self.int64_values) < num_groups:
                self.int64_values.append(Int64(0))

    # ------------------------------------------------------------------
    # Typed update methods
    #
    # Slice 3a exposes typed entry points rather than a ColumnValue variant
    # because (a) Mojo has no tagged sum type with data, (b) the call
    # site in the sink already knows the physical tag, so typed dispatch is
    # zero-overhead. Slice 3d will wire consume() to call the right method
    # per acc based on `self.tag`.
    # ------------------------------------------------------------------

    def update_utf8(mut self, gid: Int, value: String):
        """Update a MinUtf8/MaxUtf8 accumulator at `gid` with `value`.

        Caller must ensure the variant is a UTF8 variant; a no-op on others
        keeps this safe (no panic) but indicates a dispatch bug upstream.
        """
        if self.tag == ACC_MIN_UTF8:
            # PERF-CRITICAL: Optional comparison costs a branch per row; the
            # first-seen path is taken exactly once per group.
            ref slot = self.utf8_values[gid]
            if not slot:
                slot = Optional[String](value)
            else:
                if value < slot.value():
                    slot = Optional[String](value)
        elif self.tag == ACC_MAX_UTF8:
            ref slot = self.utf8_values[gid]
            if not slot:
                slot = Optional[String](value)
            else:
                if value > slot.value():
                    slot = Optional[String](value)
        # else: tag mismatch — dispatcher bug; drop on the floor in release
        # (Slice 3d will add a debug-only assert once the sink is wired).

    def update_int64(mut self, gid: Int, value: Int64):
        """Update a SumInt64/CountInt64 accumulator at `gid`.

        CountInt64 treats `value` as the increment (typically 1 per non-null
        row, but the caller may pass batch contributions).
        """
        if self.tag == ACC_SUM_INT64:
            self.int64_values[gid] = self.int64_values[gid] + value
        elif self.tag == ACC_COUNT_INT64:
            self.int64_values[gid] = self.int64_values[gid] + value
        # else: tag mismatch — see update_utf8.

    # ------------------------------------------------------------------
    # Single-group merge (used by ColumnarAggMap.merge_from to fold one
    # source gid's value into a destination gid under tag-appropriate
    # semantics). Tags MUST match.
    # ------------------------------------------------------------------

    def merge_at(
        mut self,
        dest_gid: Int,
        imm src: Self,
        src_gid: Int,
    ) raises:
        """Fold `src[src_gid]` into `self[dest_gid]`.

        - MinUtf8 / MaxUtf8: if src has a value at src_gid, apply it via
          `update_utf8` (preserves min/max semantics); no-op if unseen.
        - SumInt64 / CountInt64: additively combine.

        PRECONDITION: caller has already called
        `self.ensure_capacity(dest_gid + 1)` so the slot exists.
        """
        if self.tag != src.tag:
            raise Error("ColumnarAccumulator.merge_at: tag mismatch")

        if self.tag == ACC_MIN_UTF8 or self.tag == ACC_MAX_UTF8:
            if src_gid < len(src.utf8_values):
                ref src_slot = src.utf8_values[src_gid]
                if src_slot:
                    self.update_utf8(dest_gid, src_slot.value())
        else:
            if src_gid < len(src.int64_values):
                self.int64_values[dest_gid] = (
                    self.int64_values[dest_gid] + src.int64_values[src_gid]
                )

    # ------------------------------------------------------------------
    # Cross-accumulator merge (same tag required)
    # ------------------------------------------------------------------

    def merge(mut self, imm other: Self) raises:
        """Fold `other` into `self` element-wise at aligned group IDs.

        PRECONDITION: `other` was built over the same `ArenaGroupStore` gid
        space as `self` (e.g. after remap at combine time) AND has matching
        tag. Otherwise raises.

        Used by the combine() path (Slice 3c+) to fold per-worker or
        per-partition accumulator columns. Mirrors v0.3's
        `ColumnarAccumulatorEnum::merge_other()`.
        """
        if self.tag != other.tag:
            raise Error("ColumnarAccumulator.merge: tag mismatch")

        if self.tag == ACC_MIN_UTF8 or self.tag == ACC_MAX_UTF8:
            var n = len(other.utf8_values)
            self.ensure_capacity(n)
            for i in range(n):
                ref src = other.utf8_values[i]
                if src:
                    # Re-use typed update to preserve min/max semantics.
                    self.update_utf8(i, src.value())
        else:
            var n = len(other.int64_values)
            self.ensure_capacity(n)
            # PERF-CRITICAL: SIMD aligned merge — 4.7x speedup on aligned
            # int64 addition (canonical vectorizable pattern). Replaces
            # scalar self.int64_values[i] += other.int64_values[i].
            comptime W = simd_width_of[DType.int64]()
            var dst_ptr = self.int64_values.unsafe_ptr()
            var src_ptr = other.int64_values.unsafe_ptr()
            var simd_end = (n // W) * W
            var i = 0
            while i < simd_end:
                var d = dst_ptr.load[width=W](i)
                var s = src_ptr.load[width=W](i)
                dst_ptr.store[width=W](i, d + s)
                i += W
            while i < n:
                self.int64_values[i] = (
                    self.int64_values[i] + other.int64_values[i]
                )
                i += 1

    # ------------------------------------------------------------------
    # Finalization
    # ------------------------------------------------------------------

    def finalize_utf8(self, gid: Int) -> Optional[String]:
        """Extract final MinUtf8/MaxUtf8 value. None == group never updated."""
        if gid >= len(self.utf8_values):
            return Optional[String](None)
        return self.utf8_values[gid]

    def finalize_int64(self, gid: Int) -> Int64:
        """Extract final SumInt64/CountInt64 value. 0 for unseen groups."""
        if gid >= len(self.int64_values):
            return Int64(0)
        return self.int64_values[gid]

    def num_groups(self) -> Int:
        """Number of addressable groups (size of backing List)."""
        if self.tag == ACC_MIN_UTF8 or self.tag == ACC_MAX_UTF8:
            return len(self.utf8_values)
        return len(self.int64_values)
