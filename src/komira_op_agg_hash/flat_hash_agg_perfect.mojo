# =============================================================================
# PerfectHashAggregator -- flat array for small-domain aggregation
# =============================================================================
#
# For single-key aggregation where the key domain is small (at most
# `_MAX_PERFECT_HASH_DOMAIN` values), a flat array indexed by
# (key + key_offset): no hashing, no probing, no resize.
#
# Each slot holds one accumulator per agg expression, laid out by the
# aggregator's `AggLayout` (the default is the 32 B quartet
# [sum: 8B][count: 8B][min: 8B][max: 8B]); a group exists when its count is
# non-zero.
#
# Contract with `flat_hash_agg.mojo`: the same per-slot layout (see
# `_QUARTET_SLOT_BYTES` / `AggLayout.default_quartet`), so a commit path and
# spill read either aggregator through one offset scheme, and the same
# `_F64_MIN_SEED_BITS` / `_F64_MAX_SEED_BITS` seeds for min/max.
# =============================================================================

from std.memory import unsafe_memset, UnsafePointer
from std.math import max
from komira_udf.float_quotient_order import float_max_fold_f64, float_min_fold_f64

from komira_agg_api.agg_layout import (
    AggLayout,
    ACC_SUM_COUNT_MIN_MAX_F64,
    ACC_SUM_COUNT_F64,
    ACC_SUM_F64,
    ACC_COUNT_STAR,
    ACC_COUNT_NONNULL,
    agg_layout_is_quartet,
)


# --- Layout constants (mirrored from flat_hash_agg_hash.mojo) ---------------
# Private re-declarations, so this module has no compile-time dependency on
# the hash table. Both files must stay in lockstep: a change to the slot
# layout or the seeds here MUST also change `flat_hash_agg_hash.mojo`.

# PERF-CRITICAL: per-agg quartet stride = 32 bytes
# ([sum:8B][count:8B][min:8B][max:8B]). Used ONLY by the quartet fast paths
# in `_agg_ptr` / `update` / `update_count_only` behind the
# `if self._layout_is_quartet:` predicate; the narrow-layout path reads
# `self._layout.offsets[agg_idx]`. The literal lets LLVM const-fold the
# offset multiplication and skip the InlineArray load (about 0.7 ms per
# aggregate over 6M rows).
comptime _QUARTET_SLOT_BYTES: Int = 32

# Min/max seeds (must match flat_hash_agg_hash.mojo): MIN's identity is the
# canonical NaN (every value orders below it under the NaN-greatest float
# order), MAX's is -inf.
comptime _F64_MIN_SEED_BITS: UInt64 = 0x7FF8000000000000
comptime _F64_MAX_SEED_BITS: UInt64 = 0xFFF0000000000000


# Maximum domain size for PerfectHash selection: 65,536 keys.
#
# A wider cap captures more key domains (a ~150K-key customer id, for one),
# but widening needs bench evidence that no regression occurs between the
# old and new cap. Keep it below ~524,288 in any case: above that the
# per-worker slab (16 MB) exceeds L3 on many cores and loses to radix
# aggregation, which keeps its sub-tables L1-resident. The value is pinned
# by tests/test_max_perfect_hash_domain.mojo, so a change is deliberate.
comptime _MAX_PERFECT_HASH_DOMAIN: Int = 65_536


struct PerfectHashAggregator(Movable):
    """Flat-array aggregator for small integer key domains.

    Instead of hashing keys, uses (key - key_offset) as a direct array index.
    Each slot stores [sum: 8B][count: 8B][min: 8B][max: 8B] per agg expression.

    Fields:
        _accum: Flat accumulator buffer. Layout per slot:
                [agg0: 32B][agg1: 32B]...[aggN: 32B].
        _domain_size: Number of slots in the flat array.
        _key_offset: Value subtracted from keys to get the array index.
                     For unsigned types: 0. For signed: -min_value.
        _num_aggs: Number of agg expressions per group.
        _slot_stride: Bytes per slot (`_layout.total_width`; for the
                      default quartet layout this is `_num_aggs * 32`).
        _num_groups: Number of slots that have been touched (count > 0).
    """

    var _accum: List[UInt8]
    var _domain_size: Int
    var _key_offset: Int64
    var _num_aggs: Int
    var _slot_stride: Int
    var _num_groups: Int
    # Per-query AggLayout, so a SUM+COUNT-only query can use narrow slots
    # (ACC_SUM_COUNT_F64, 16B), matching FlatHashAggregator's layout
    # contract. The default is the quartet.
    var _layout: AggLayout
    # PERF-CRITICAL: per-row tag dispatch (`self._layout.tags[agg_idx]`) in
    # `update` / `update_count_only` / `_agg_ptr` costs ~0.7 ms over 6M
    # rows of one SUM. LLVM cannot const-fold the InlineArray load because
    # `self` is a mutable reference and the compiler conservatively
    # assumes other callers might mutate `_layout`. Cache the "all
    # slots are the 32B quartet" predicate at construction time and
    # check THAT in the hot path -- LLVM promotes this Bool to an SSA
    # value and hoists it out of the inner row loop.
    #
    # Why this is safe: `_layout` is set ONCE at `__init__` /
    # `with_layout` and never mutated thereafter (no API in this
    # struct writes to `_layout.tags`). `_layout_is_quartet` is
    # derived from `_layout` at construction and stays in lockstep.
    var _layout_is_quartet: Bool

    def __init__(out self, domain_size: Int, key_offset: Int64, num_aggs: Int):
        """Create a PerfectHashAggregator with the default 32B quartet layout.

        Args:
            domain_size: Number of possible key values.
            key_offset: Offset to add to key before indexing.
            num_aggs: Number of aggregation expressions.
        """
        self._domain_size = domain_size
        self._key_offset = key_offset
        self._num_aggs = num_aggs
        self._layout = AggLayout.default_quartet(num_aggs)
        self._slot_stride = self._layout.total_width
        self._num_groups = 0
        # Default quartet -- always True on this code path.
        self._layout_is_quartet = True

        # List[UInt8] owns the accumulator buffer; zero-fill for initial state.
        var total_bytes = max(domain_size * self._slot_stride, 1)
        self._accum = List[UInt8](capacity=total_bytes)
        self._accum.resize(unsafe_uninit_length=total_bytes)
        unsafe_memset(self._accum.unsafe_ptr(), 0, total_bytes)

        # Seed min/max for all slots. Only quartet slots store min/max;
        # narrow slots (via with_layout) are skipped.
        var accum_ptr = self._accum.unsafe_ptr()
        for slot in range(domain_size):
            var slot_base = accum_ptr + slot * self._slot_stride
            for a in range(num_aggs):
                var ap = slot_base + self._layout.offsets[a]
                var tag = self._layout.tags[a]
                if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                    # sum = 0.0 (already zero from memset)
                    # count = 0 (already zero from memset)
                    (ap + 16).bitcast[UInt64]()[] = _F64_MIN_SEED_BITS
                    (ap + 24).bitcast[UInt64]()[] = _F64_MAX_SEED_BITS
                # Narrow layouts (ACC_SUM_COUNT_F64, etc.) init to zero.

    @staticmethod
    def with_layout(
        domain_size: Int,
        key_offset: Int64,
        var layout: AggLayout,
    ) -> PerfectHashAggregator:
        """Build a PerfectHashAggregator with the caller-supplied layout.

        Matches FlatHashAggregator.with_layout, so the sink can pick
        narrow slots (ACC_SUM_COUNT_F64, 16B per slot) for SUM+COUNT
        queries. For `default_quartet(n)` the result is byte-identical to
        `__init__(domain_size, key_offset, n)`.

        Args:
            domain_size: Number of possible key values.
            key_offset: Offset to add to key before indexing.
            layout: Per-slot width tags. Consumed.
        """
        var num_aggs = layout.num_aggs
        var agg = PerfectHashAggregator(
            domain_size=domain_size,
            key_offset=key_offset,
            num_aggs=num_aggs,
        )
        # If the caller asked for a narrower layout, rebuild the backing
        # buffer at the new stride. `__init__` installed the default
        # quartet; refresh everything consistent with `layout`.
        var new_stride = layout.total_width
        if new_stride != agg._slot_stride:
            var new_bytes = max(domain_size * new_stride, 1)
            agg._accum = List[UInt8](capacity=new_bytes)
            agg._accum.resize(unsafe_uninit_length=new_bytes)
            unsafe_memset(agg._accum.unsafe_ptr(), 0, new_bytes)
            agg._slot_stride = new_stride
        agg._layout = layout^
        # PERF-CRITICAL: recompute quartet predicate after layout swap.
        # When the caller passes `default_quartet(n)` this stays True and
        # the hot path skips per-row tag dispatch entirely. When the
        # caller passes a narrow layout (SUM_COUNT_F64 etc.) this is
        # False and the hot path falls into the tag-dispatch branch.
        agg._layout_is_quartet = agg_layout_is_quartet(agg._layout)
        # Re-init sentinels under the new layout (only quartet slots
        # carry min/max).
        var accum_ptr = agg._accum.unsafe_ptr()
        for slot in range(domain_size):
            var slot_base = accum_ptr + slot * agg._slot_stride
            for a in range(num_aggs):
                var ap = slot_base + agg._layout.offsets[a]
                var tag = agg._layout.tags[a]
                if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                    (ap + 16).bitcast[UInt64]()[] = _F64_MIN_SEED_BITS
                    (ap + 24).bitcast[UInt64]()[] = _F64_MAX_SEED_BITS
        return agg^

    @always_inline
    def num_groups(self) -> Int:
        """Return the number of groups that have been touched."""
        return self._num_groups

    @always_inline
    def _accum_mut_ptr(ref self) -> UnsafePointer[UInt8, origin_of(self._accum)]:
        """Pointer to the accumulator buffer, with the buffer's origin
        (mutable when the receiver is borrowed mutably)."""
        # SAFETY: the base of `_accum`, which is never reallocated after
        # construction.
        return self._accum.unsafe_ptr()

    @always_inline
    def _slot_ptr(
        ref self, index: Int
    ) -> UnsafePointer[UInt8, origin_of(self._accum)]:
        """Pointer to the accumulator slot for the given array index."""
        return self._accum_mut_ptr() + index * self._slot_stride

    @always_inline
    def _agg_ptr[
        o_slot: Origin
    ](self, slot: UnsafePointer[UInt8, o_slot], agg_idx: Int) -> UnsafePointer[UInt8, o_slot]:
        """Pointer to agg slot within an accumulator slot.

        PERF-CRITICAL: for the 32B quartet layout the offset is the
        constant multiple `agg_idx * 32`, skipping the `_layout.offsets[]`
        InlineArray load (see `_layout_is_quartet`). A narrow layout (via
        `with_layout`) reads the per-slot byte offset from `_layout`.
        """
        return slot + self._agg_off(agg_idx)

    @always_inline
    def _agg_off(self, agg_idx: Int) -> Int:
        """Byte offset of agg `agg_idx` within an accumulator slot (the
        quartet fast path of `_agg_ptr`). Writers add it to a slot pointer
        rather than calling `_agg_ptr`, which would pass the aggregator
        together with a pointer into its own buffer."""
        if self._layout_is_quartet:
            return agg_idx * _QUARTET_SLOT_BYTES
        return self._layout.offsets[agg_idx]

    @always_inline
    def update(mut self, key: Int64, agg_idx: Int, value: Float64):
        """Update fields present in this slot based on its layout tag.

        PERF-CRITICAL: fast path for the 32B quartet shape. LLVM hoists
        `self._layout_is_quartet` out of the row loop, reducing the hot
        body to four stores. The narrow-layout branch serves callers that
        opt in via `with_layout(..., sum_count_f64(n))`.

        Args:
            key: The raw key value.
            agg_idx: Which agg expression to update.
            value: The value to accumulate.
        """
        var idx = Int(key + self._key_offset)
        if self._layout_is_quartet:
            # PERF-CRITICAL: quartet path -- 4 stores/row with
            # compile-time-known offsets.
            var ap = self._slot_ptr(idx) + agg_idx * _QUARTET_SLOT_BYTES
            var sum_p = ap.bitcast[Float64]()
            var count_p = (ap + 8).bitcast[Int64]()
            var min_p = (ap + 16).bitcast[Float64]()
            var max_p = (ap + 24).bitcast[Float64]()
            sum_p[] = sum_p[] + value
            count_p[] = count_p[] + 1
            min_p[] = float_min_fold_f64(min_p[], value)
            max_p[] = float_max_fold_f64(max_p[], value)
            return
        # Narrow-layout path: per-row tag dispatch, taken only by an
        # aggregator built with a narrow `with_layout`.
        var ap = self._slot_ptr(idx) + self._layout.offsets[agg_idx]
        var tag = self._layout.tags[agg_idx]
        if tag == ACC_SUM_COUNT_F64:
            var sum_p = ap.bitcast[Float64]()
            var count_p = (ap + 8).bitcast[Int64]()
            sum_p[] = sum_p[] + value
            count_p[] = count_p[] + 1
        elif tag == ACC_SUM_F64:
            var sum_p = ap.bitcast[Float64]()
            sum_p[] = sum_p[] + value
        elif tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
            var count_p = ap.bitcast[Int64]()
            count_p[] = count_p[] + 1
        else:
            # Unknown / ACC_SUM_COUNT_MIN_MAX_F64 fallback (safe quartet
            # body). Kept for completeness -- the predicate check above
            # already routes default_quartet to the fast path.
            var sum_p = ap.bitcast[Float64]()
            var count_p = (ap + 8).bitcast[Int64]()
            var min_p = (ap + 16).bitcast[Float64]()
            var max_p = (ap + 24).bitcast[Float64]()
            sum_p[] = sum_p[] + value
            count_p[] = count_p[] + 1
            min_p[] = float_min_fold_f64(min_p[], value)
            max_p[] = float_max_fold_f64(max_p[], value)

    @always_inline
    def update_count_only(mut self, key: Int64, agg_idx: Int):
        """Increment count for COUNT(*) at the given key.

        PERF-CRITICAL: fast-path the quartet layout (count at +8) so the
        per-row hot path is a single InlineArray-free load+store. Narrow
        count-only layouts (ACC_COUNT_STAR at +0) take the else branch.
        """
        var idx = Int(key + self._key_offset)
        if self._layout_is_quartet:
            var count_p = (self._slot_ptr(idx) + agg_idx * _QUARTET_SLOT_BYTES + 8).bitcast[Int64]()
            count_p[] = count_p[] + 1
            return
        var ap = self._slot_ptr(idx) + self._layout.offsets[agg_idx]
        var tag = self._layout.tags[agg_idx]
        if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
            var count_p = ap.bitcast[Int64]()
            count_p[] = count_p[] + 1
        else:
            var count_p = (ap + 8).bitcast[Int64]()
            count_p[] = count_p[] + 1

    # -----------------------------------------------------------------------
    # SLOT-RESOLVED, SUM+COUNT-ONLY fold entries.
    #
    # These exist so `PerfectHashAggUntyped`'s two-pass agg-major fold can do
    # its per-row store WITHOUT re-deriving the slot from the key and WITHOUT
    # touching the min/max cells. They live HERE, not in the adapter, because
    # the accumulator buffer lives here: the project pointer rule is that
    # `UnsafePointer` may be used inside the struct that owns the allocation
    # and must never cross a module boundary, so the alternative — handing the
    # adapter `_accum`'s base pointer — is banned outright.
    #
    # THEY DIFFER FROM `update` IN EXACTLY TWO WAYS, both stated so a reviewer
    # can check the byte-equivalence claim without reading the caller:
    #
    #   1. The argument is the resolved SLOT INDEX, not the raw key. `update`
    #      computes `Int(key + self._key_offset)`; the caller's pass 1 has already
    #      computed that exact expression once per row and recorded it, so
    #      recomputing it per (row, agg) is the work this removes.
    #   2. The min/max cells are NOT written. That is output-equivalent for a
    #      SUM / AVG / COUNT spec and ONLY for those, because those cells are
    #      unreachable from the drain for such a spec:
    #        * `PerfectHashAggUntyped.read_agg_f64` reads `get_min`/`get_max`
    #          only for `AGG_MIN_F64` / `AGG_MAX_F64`;
    #        * `agg_is_null` reads the COUNT cell — which IS written here —
    #          for every non-COUNT op;
    #        * `_build_occupied` reads `_slot_touched`, not the quartet.
    #      A MIN/MAX spec must therefore keep taking `update`, and the caller's
    #      envelope declines those ops. `merge` still folds min/max, and folding
    #      an untouched sentinel is a no-op for the arm that reads them (none).
    #
    # The sum/count arithmetic is otherwise LINE-FOR-LINE `update`'s quartet
    # arm — same order (sum then count), same types, same `+`.
    # -----------------------------------------------------------------------

    @always_inline
    def update_sum_count_at(mut self, index: Int, agg_idx: Int, value: Float64):
        """Fold `value` into the sum+count cells of (slot `index`, agg
        `agg_idx`). See the block above for why min/max are skipped and
        when that is legal.

        Args:
            index: The resolved slot index (`key + key_offset`, already added).
            agg_idx: Which agg expression to update.
            value: The value to accumulate.
        """
        if self._layout_is_quartet:
            var ap = self._slot_ptr(index) + agg_idx * _QUARTET_SLOT_BYTES
            var sum_p = ap.bitcast[Float64]()
            var count_p = (ap + 8).bitcast[Int64]()
            sum_p[] = sum_p[] + value
            count_p[] = count_p[] + 1
            return
        # Narrow-layout fallback. Dormant on the col-untyped adapter (which
        # always constructs the default quartet), retained so this entry is
        # total rather than silently wrong if a caller opts in via
        # `with_layout`. Delegates to the full `update` body by re-deriving the
        # key, so the narrow tags keep their existing semantics exactly.
        var ap2 = self._slot_ptr(index) + self._layout.offsets[agg_idx]
        var tag = self._layout.tags[agg_idx]
        if tag == ACC_SUM_COUNT_F64:
            var sum_p = ap2.bitcast[Float64]()
            var count_p = (ap2 + 8).bitcast[Int64]()
            sum_p[] = sum_p[] + value
            count_p[] = count_p[] + 1
        elif tag == ACC_SUM_F64:
            var sum_p = ap2.bitcast[Float64]()
            sum_p[] = sum_p[] + value
        elif tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
            var count_p = ap2.bitcast[Int64]()
            count_p[] = count_p[] + 1
        else:
            var sum_p = ap2.bitcast[Float64]()
            var count_p = (ap2 + 8).bitcast[Int64]()
            var min_p = (ap2 + 16).bitcast[Float64]()
            var max_p = (ap2 + 24).bitcast[Float64]()
            sum_p[] = sum_p[] + value
            count_p[] = count_p[] + 1
            min_p[] = float_min_fold_f64(min_p[], value)
            max_p[] = float_max_fold_f64(max_p[], value)

    @always_inline
    def update_count_only_at(mut self, index: Int, agg_idx: Int):
        """`update_count_only` taking the resolved SLOT INDEX instead of the
        raw key. Byte-for-byte the same cell write."""
        if self._layout_is_quartet:
            var count_p = (self._slot_ptr(index) + agg_idx * _QUARTET_SLOT_BYTES + 8).bitcast[Int64]()
            count_p[] = count_p[] + 1
            return
        var ap = self._slot_ptr(index) + self._layout.offsets[agg_idx]
        var tag = self._layout.tags[agg_idx]
        if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
            var count_p = ap.bitcast[Int64]()
            count_p[] = count_p[] + 1
        else:
            var count_p = (ap + 8).bitcast[Int64]()
            count_p[] = count_p[] + 1

    @always_inline
    def layout_is_quartet(self) -> Bool:
        """Expose the layout PREDICATE the hot path branches on, so a caller's
        envelope can state which cell layout it is reasoning about rather than
        assuming the default."""
        return self._layout_is_quartet

    def get_sum(self, slot_index: Int, agg_idx: Int) -> Float64:
        """Read sum from an agg slot.

        Layout-aware: returns 0.0 for slots that don't store a sum
        (ACC_COUNT_STAR / ACC_COUNT_NONNULL).
        """
        var tag = self._layout.tags[agg_idx]
        if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
            return 0.0
        return self._agg_ptr(self._slot_ptr(slot_index), agg_idx).bitcast[Float64]()[]

    def get_count(self, slot_index: Int, agg_idx: Int) -> Int:
        """Read count from an agg slot.

        Layout-aware: count at +0 for 8B count-only, +8 otherwise.
        """
        var ap = self._agg_ptr(self._slot_ptr(slot_index), agg_idx)
        var tag = self._layout.tags[agg_idx]
        if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
            return Int(ap.bitcast[Int64]()[])
        if tag == ACC_SUM_F64:
            return 0
        return Int((ap + 8).bitcast[Int64]()[])

    def get_min(self, slot_index: Int, agg_idx: Int) -> Float64:
        """Read min from an agg slot.

        Only the 32B quartet stores min. Other layouts return the init
        sentinel so downstream consumers that didn't request MIN get a
        harmless value.
        """
        var tag = self._layout.tags[agg_idx]
        if tag != ACC_SUM_COUNT_MIN_MAX_F64:
            var scratch: UInt64 = _F64_MIN_SEED_BITS
            return UnsafePointer(to=scratch).bitcast[Float64]()[]
        return (self._agg_ptr(self._slot_ptr(slot_index), agg_idx) + 16).bitcast[Float64]()[]

    def get_max(self, slot_index: Int, agg_idx: Int) -> Float64:
        """Read max from an agg slot. See `get_min` for the non-quartet
        seed semantics.
        """
        var tag = self._layout.tags[agg_idx]
        if tag != ACC_SUM_COUNT_MIN_MAX_F64:
            var scratch: UInt64 = _F64_MAX_SEED_BITS
            return UnsafePointer(to=scratch).bitcast[Float64]()[]
        return (self._agg_ptr(self._slot_ptr(slot_index), agg_idx) + 24).bitcast[Float64]()[]

    def get_avg(self, slot_index: Int, agg_idx: Int) -> Float64:
        """Compute average from an agg slot.

        Requires both sum + count (quartet or sum_count_f64). Returns
        0.0 for slots that lack one.
        """
        var tag = self._layout.tags[agg_idx]
        if tag != ACC_SUM_COUNT_MIN_MAX_F64 and tag != ACC_SUM_COUNT_F64:
            return 0.0
        var ap = self._agg_ptr(self._slot_ptr(slot_index), agg_idx)
        var s = ap.bitcast[Float64]()[]
        var c = (ap + 8).bitcast[Int64]()[]
        if c > 0:
            return s / Float64(Int(c))
        return 0.0

    def merge(mut self, other: PerfectHashAggregator):
        """Merge another PerfectHashAggregator into this one.

        Both aggregators must share the same layout (sibling aggs from
        the same plan). Combines accumulators slot-by-slot per
        layout.tags[a].
        """
        for slot in range(self._domain_size):
            for a in range(self._num_aggs):
                var self_ap = self._slot_ptr(slot) + self._agg_off(a)
                var other_ap = other._agg_ptr(other._slot_ptr(slot), a)
                var tag = self._layout.tags[a]
                # Determine "occupied" marker per tag:
                #   - count-bearing slots: check count > 0
                #   - sum-only slots: no per-row count; skip the
                #     "num_groups +=" bookkeeping and always fold.
                var other_has_data: Bool
                var other_count_val: Int64 = 0
                # `count_offset_in_slot` is the byte offset at which the
                # count field lives within the slot. -1 means "no count
                # field" (ACC_SUM_F64). Avoids a local-var pointer with
                # a hard-to-express origin (the pointer is origin-tied
                # to `self._accum`, which we'd have to plumb here); the
                # offset makes every write go through `self_ap` directly.
                var count_offset_in_slot: Int = -1
                if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
                    other_count_val = other_ap.bitcast[Int64]()[]
                    count_offset_in_slot = 0
                    other_has_data = other_count_val != 0
                elif tag == ACC_SUM_F64:
                    # No count to key on; treat any non-zero sum as
                    # "has data" for group tracking (best-effort).
                    other_has_data = other_ap.bitcast[Float64]()[] != 0.0
                else:
                    # quartet or sum+count: count at +8
                    other_count_val = (other_ap + 8).bitcast[Int64]()[]
                    count_offset_in_slot = 8
                    other_has_data = other_count_val != 0

                if not other_has_data:
                    continue
                if tag != ACC_SUM_F64:
                    var self_count_p = (self_ap + count_offset_in_slot).bitcast[Int64]()
                    if self_count_p[] == 0:
                        self._num_groups += 1

                if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                    # Fold sum + count + min + max.
                    var self_sum = self_ap.bitcast[Float64]()
                    self_sum[] = self_sum[] + other_ap.bitcast[Float64]()[]
                    var self_count_p = (self_ap + 8).bitcast[Int64]()
                    self_count_p[] = self_count_p[] + other_count_val
                    var self_min = (self_ap + 16).bitcast[Float64]()
                    var other_min = (other_ap + 16).bitcast[Float64]()[]
                    self_min[] = float_min_fold_f64(self_min[], other_min)
                    var self_max = (self_ap + 24).bitcast[Float64]()
                    var other_max = (other_ap + 24).bitcast[Float64]()[]
                    self_max[] = float_max_fold_f64(self_max[], other_max)
                elif tag == ACC_SUM_COUNT_F64:
                    # Fold sum + count.
                    var self_sum = self_ap.bitcast[Float64]()
                    self_sum[] = self_sum[] + other_ap.bitcast[Float64]()[]
                    var self_count_p = (self_ap + 8).bitcast[Int64]()
                    self_count_p[] = self_count_p[] + other_count_val
                elif tag == ACC_SUM_F64:
                    # Fold sum only. No count in this slot.
                    var self_sum = self_ap.bitcast[Float64]()
                    self_sum[] = self_sum[] + other_ap.bitcast[Float64]()[]
                elif tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
                    # Fold count only; count at +0 in this slot.
                    var self_count_p = self_ap.bitcast[Int64]()
                    self_count_p[] = self_count_p[] + other_count_val
                else:
                    # Defensive: quartet fold for unknown tags.
                    var self_sum = self_ap.bitcast[Float64]()
                    self_sum[] = self_sum[] + other_ap.bitcast[Float64]()[]
                    var self_count_p = (self_ap + 8).bitcast[Int64]()
                    self_count_p[] = self_count_p[] + other_count_val
                    var self_min = (self_ap + 16).bitcast[Float64]()
                    var other_min = (other_ap + 16).bitcast[Float64]()[]
                    self_min[] = float_min_fold_f64(self_min[], other_min)
                    var self_max = (self_ap + 24).bitcast[Float64]()
                    var other_max = (other_ap + 24).bitcast[Float64]()[]
                    self_max[] = float_max_fold_f64(self_max[], other_max)
