# =============================================================================
# AggCommitPlan -- the loop-transposed batch commits
# =============================================================================
#
# The bodies of `AggCommitPlan.commit_batch`, `commit_batch_partitioned` and
# `commit_batch_indexed`, as package-private free functions taking the plan
# as their first argument; the methods in `agg_commit.mojo` take spans and
# forward here.
#
# PERF-CRITICAL: the outer loop runs over accumulators and the inner loop
# over rows, so each inner loop is a tight gather-scatter with no per-row
# type dispatch: it reads the value column sequentially and updates the agg
# slot inside each row's entry (strided by `_entry_stride`). This keeps one
# accumulator's memory hot for the whole inner loop and lets the compiler
# vectorize; `commit_row`, which walks every aggregate for ONE row, cannot.
#
# Chunk-major: the rows are walked in chunks of COMMIT_CHUNK. Phase 2a
# resolves each row's entry pointer ONCE into a stack array (one dependent
# load, by entry index); phase 2b runs the per-aggregate loops over that
# array, so the random-scatter resolution is paid once per row instead of
# once per row per aggregate (the shape of DuckDB's `UpdateStates`, which
# resolves addresses once and reuses them for every aggregate). Phase 2b's
# writes hit the cache lines phase 2a just loaded.
#
# Per-slot devirtualization: for the dominant tags (COUNT_STAR /
# COUNT_NONNULL / SUM_F64 / SUM_COUNT_F64 / SUM_COUNT_MIN_MAX_F64) the inner
# loop calls an `@always_inline` slot write directly instead of the stored
# row thunk, an indirect call the compiler cannot inline; the tag check is
# hoisted out of the row loop. The thunk remains the fallback for rare tags.
#
# Without `bind_layout` the commits fall back to per-row tag dispatch
# through the aggregator (`_update_agg` / `_update_count_only`), which is
# correct for any layout.
# =============================================================================

from std.collections import Array
from std.memory import UnsafePointer

from komira_udf.float_quotient_order import float_max_fold_f64, float_min_fold_f64
from komira_agg_api.agg_layout import (
    ACC_COUNT_STAR,
    ACC_COUNT_NONNULL,
    ACC_SUM_F64,
    ACC_SUM_COUNT_F64,
    ACC_SUM_COUNT_MIN_MAX_F64,
)

from .agg_commit import AggCommitPlan, COMMIT_CHUNK, _thunk_call
from .flat_hash_agg import FlatHashAggregator, EntryHandle
from .partitioned_flat_hash_agg import PartitionedFlatHashAggregator


# =============================================================================
# Inlined slot writes for the dominant tags
# =============================================================================
# The same slot write as the corresponding row thunk of
# `komira_op_agg_state.accumulator_set`, as a DIRECT call the compiler
# inlines into the row loop (restoring vectorization and branch-free code).
# The math matches the thunks: the same load-add-store and bitcasts, and the
# float min/max fold of `komira_udf.float_quotient_order`.
#
# SAFETY (all four): `entry_ptr + slot_off` lies inside an entry of the
# aggregator's `_entries` buffer, resolved by the caller with that buffer's
# origin and no resize in the commit window; the bitcasts address the slot's
# fields.


@always_inline
def _inline_count_star[
    o: Origin[mut=True]
](entry_ptr: UnsafePointer[UInt8, o], slot_off: Int) -> None:
    """ACC_COUNT_STAR / ACC_COUNT_NONNULL (8B count slot): `count += 1`.
    COUNT(*) ignores the value."""
    var count_p = (entry_ptr + slot_off).bitcast[Int64]()
    count_p[] = count_p[] + Int64(1)


@always_inline
def _inline_sum_f64[
    o: Origin[mut=True]
](entry_ptr: UnsafePointer[UInt8, o], slot_off: Int, value: Float64) -> None:
    """ACC_SUM_F64 (8B sum slot): `sum += value`."""
    var sum_p = (entry_ptr + slot_off).bitcast[Float64]()
    sum_p[] = sum_p[] + value


@always_inline
def _inline_sum_count_f64[
    o: Origin[mut=True]
](entry_ptr: UnsafePointer[UInt8, o], slot_off: Int, value: Float64) -> None:
    """ACC_SUM_COUNT_F64 (16B [sum:f64][count:i64] slot):
    `sum += value; count += 1`."""
    var ap = entry_ptr + slot_off
    var sum_p = ap.bitcast[Float64]()
    sum_p[] = sum_p[] + value
    var count_p = (ap + 8).bitcast[Int64]()
    count_p[] = count_p[] + Int64(1)


@always_inline
def _inline_sum_count_min_max_f64[
    o: Origin[mut=True]
](entry_ptr: UnsafePointer[UInt8, o], slot_off: Int, value: Float64) -> None:
    """ACC_SUM_COUNT_MIN_MAX_F64 (32B quartet slot): sum += value,
    count += 1, min and max folded with the NaN-aware float order."""
    var ap = entry_ptr + slot_off
    var sum_p = ap.bitcast[Float64]()
    sum_p[] = sum_p[] + value
    var count_p = (ap + 8).bitcast[Int64]()
    count_p[] = count_p[] + Int64(1)
    var min_p = (ap + 16).bitcast[Float64]()
    var cur_min = min_p[]
    min_p[] = float_min_fold_f64(cur_min, value)
    var max_p = (ap + 24).bitcast[Float64]()
    var cur_max = max_p[]
    max_p[] = float_max_fold_f64(cur_max, value)


def _commit_batch_impl[
    batch_origin: ImmOrigin, o_entries: Origin
](
    plan: AggCommitPlan[batch_origin],
    mut agg: FlatHashAggregator,
    entries: UnsafePointer[EntryHandle, o_entries],
    num_rows: Int,
):
    """Body of `AggCommitPlan.commit_batch`: outer loop over
    accumulators, inner loop over rows.

    SAFETY: `entries` points at `num_rows` handles that the caller formed
    from a span; each was produced by a find_or_create_* call on `agg`
    with no resize since.
    """
    if num_rows <= 0:
        return

    # The plan's view pointers carry the origins of its own buffers.
    var count_idxs = plan._int_view_ptr(0)
    var f64_idxs = plan._int_view_ptr(1)
    var f64_offs = plan._int_view_ptr(2)
    var i64_idxs = plan._int_view_ptr(3)
    var i64_offs = plan._int_view_ptr(4)
    var i32_idxs = plan._int_view_ptr(5)
    var i32_offs = plan._int_view_ptr(6)
    var f64_ptrs = plan._f64_ptrs()
    var i64_ptrs = plan._i64_ptrs()
    var i32_ptrs = plan._i32_ptrs()

    if not plan._layout_bound:
        # Correctness-safe fallback (no `bind_layout`): per-row tag
        # dispatch via `_update_agg` / `_update_count_only`, as in
        # `commit_row`. NOT the perf path.
        for j in range(plan.n_count):
            var agg_idx = (count_idxs + j)[]
            for row in range(num_rows):
                agg._update_count_only((entries + row)[], agg_idx)
        for j in range(plan.n_f64):
            var agg_idx = (f64_idxs + j)[]
            var ptr = (f64_ptrs + j)[]
            var offset = (f64_offs + j)[]
            for row in range(num_rows):
                var val = (ptr + offset + row)[]
                agg._update_agg((entries + row)[], agg_idx, val)
        for j in range(plan.n_i64):
            var agg_idx = (i64_idxs + j)[]
            var ptr = (i64_ptrs + j)[]
            var offset = (i64_offs + j)[]
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                agg._update_agg(
                    (entries + row)[], agg_idx, Float64(Int(raw))
                )
        for j in range(plan.n_i32):
            var agg_idx = (i32_idxs + j)[]
            var ptr = (i32_ptrs + j)[]
            var offset = (i32_offs + j)[]
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                agg._update_agg(
                    (entries + row)[], agg_idx, Float64(Int(raw))
                )
        # Validity-aware count(col).
        for j in range(plan.n_count_validity):
            var agg_idx = plan.count_validity_idxs[j]
            var v_ptr = plan.count_validity_ptrs[j]
            var v_off = plan.count_validity_bit_offsets[j]
            for row in range(num_rows):
                var bit_idx = v_off + row
                var byte_v = (v_ptr + (bit_idx >> 3))[]
                if (byte_v >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1):
                    agg._update_count_only((entries + row)[], agg_idx)
        return

    # Chunk-major fast path (see the module header): phase 2a gathers
    # entry pointers ONCE per row, phase 2b runs per-agg tight loops over
    # the gathered array.
    #
    # `agg` is borrowed mutably for the whole call, so `agg._entries`
    # stays live; the gathered pointers carry its origin, and the buffer
    # does not grow inside this function.
    #
    # `uninitialized=True` skips the 2KB zero-fill: phase 2a writes every
    # slot phase 2b reads (the same chunk_n bound), and the partitioned
    # consumer calls this once per partition per morsel.
    var entry_stride = agg._entry_stride
    var entry_ptrs = Array[
        UnsafePointer[UInt8, origin_of(agg._entries)], COMMIT_CHUNK
    ](uninitialized=True)

    var row_base = 0
    while row_base < num_rows:
        var chunk_n = COMMIT_CHUNK
        if row_base + chunk_n > num_rows:
            chunk_n = num_rows - row_base

        # Phase 2a: gather entry_ptrs ONCE per row in this chunk, by
        # entry index (one dependent load). The `entries` walk is
        # sequential.
        for bi in range(chunk_n):
            var row = row_base + bi
            entry_ptrs[bi] = agg._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))

        # Phase 2b: per-agg outer loop, per-row inner loop over the
        # gathered ptrs. The per-SLOT tag check is loop-invariant and
        # hoisted out: the dominant tags run a fully-inlined inner loop
        # (auto-vectorizable, no indirect call); rare tags fall back to
        # the stored row thunk.

        # count-only bucket -- COUNT(*). Dominant tag is COUNT_STAR /
        # COUNT_NONNULL (8B count slot, `count += 1`, value ignored).
        for j in range(plan.n_count):
            var slot_off = plan.count_slot_offsets[j]
            var tag = plan.count_tags[j]
            if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
                for bi in range(chunk_n):
                    _inline_count_star(entry_ptrs[bi], slot_off)
            else:
                var thunk = plan.count_thunks[j]
                for bi in range(chunk_n):
                    _thunk_call(thunk, entry_ptrs[bi], entry_stride, slot_off, Float64(0.0))

        # f64 bucket -- value column read is sequential.
        for j in range(plan.n_f64):
            var slot_off = plan.f64_slot_offsets[j]
            var tag = plan.f64_tags[j]
            var ptr = (f64_ptrs + j)[]
            var offset = (f64_offs + j)[]
            if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                for bi in range(chunk_n):
                    var val = (ptr + offset + row_base + bi)[]
                    _inline_sum_count_min_max_f64(
                        entry_ptrs[bi], slot_off, val
                    )
            elif tag == ACC_SUM_COUNT_F64:
                for bi in range(chunk_n):
                    var val = (ptr + offset + row_base + bi)[]
                    _inline_sum_count_f64(entry_ptrs[bi], slot_off, val)
            elif tag == ACC_SUM_F64:
                for bi in range(chunk_n):
                    var val = (ptr + offset + row_base + bi)[]
                    _inline_sum_f64(entry_ptrs[bi], slot_off, val)
            else:
                var thunk = plan.f64_thunks[j]
                for bi in range(chunk_n):
                    var val = (ptr + offset + row_base + bi)[]
                    _thunk_call(thunk, entry_ptrs[bi], entry_stride, slot_off, val)

        # i64 bucket -- widen Int64 -> Float64 at the call site.
        for j in range(plan.n_i64):
            var slot_off = plan.i64_slot_offsets[j]
            var tag = plan.i64_tags[j]
            var ptr = (i64_ptrs + j)[]
            var offset = (i64_offs + j)[]
            if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                for bi in range(chunk_n):
                    var raw = (ptr + offset + row_base + bi)[]
                    _inline_sum_count_min_max_f64(
                        entry_ptrs[bi], slot_off, Float64(Int(raw))
                    )
            elif tag == ACC_SUM_COUNT_F64:
                for bi in range(chunk_n):
                    var raw = (ptr + offset + row_base + bi)[]
                    _inline_sum_count_f64(
                        entry_ptrs[bi], slot_off, Float64(Int(raw))
                    )
            elif tag == ACC_SUM_F64:
                for bi in range(chunk_n):
                    var raw = (ptr + offset + row_base + bi)[]
                    _inline_sum_f64(
                        entry_ptrs[bi], slot_off, Float64(Int(raw))
                    )
            else:
                var thunk = plan.i64_thunks[j]
                for bi in range(chunk_n):
                    var raw = (ptr + offset + row_base + bi)[]
                    _thunk_call(thunk, entry_ptrs[bi], entry_stride, slot_off, Float64(Int(raw)))

        # i32 bucket -- widen Int32 -> Float64 at the call site.
        for j in range(plan.n_i32):
            var slot_off = plan.i32_slot_offsets[j]
            var tag = plan.i32_tags[j]
            var ptr = (i32_ptrs + j)[]
            var offset = (i32_offs + j)[]
            if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                for bi in range(chunk_n):
                    var raw = (ptr + offset + row_base + bi)[]
                    _inline_sum_count_min_max_f64(
                        entry_ptrs[bi], slot_off, Float64(Int(raw))
                    )
            elif tag == ACC_SUM_COUNT_F64:
                for bi in range(chunk_n):
                    var raw = (ptr + offset + row_base + bi)[]
                    _inline_sum_count_f64(
                        entry_ptrs[bi], slot_off, Float64(Int(raw))
                    )
            elif tag == ACC_SUM_F64:
                for bi in range(chunk_n):
                    var raw = (ptr + offset + row_base + bi)[]
                    _inline_sum_f64(
                        entry_ptrs[bi], slot_off, Float64(Int(raw))
                    )
            else:
                var thunk = plan.i32_thunks[j]
                for bi in range(chunk_n):
                    var raw = (ptr + offset + row_base + bi)[]
                    _thunk_call(thunk, entry_ptrs[bi], entry_stride, slot_off, Float64(Int(raw)))

        # Validity-aware count(col): byte load + bit test; on set, the
        # resolved thunk does the slot-shape-specific increment.
        for j in range(plan.n_count_validity):
            var thunk = plan.count_validity_thunks[j]
            var slot_off = plan.count_validity_slot_offsets[j]
            var v_ptr = plan.count_validity_ptrs[j]
            var v_off = plan.count_validity_bit_offsets[j]
            for bi in range(chunk_n):
                var row = row_base + bi
                var bit_idx = v_off + row
                var byte_v = (v_ptr + (bit_idx >> 3))[]
                if (byte_v >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1):
                    _thunk_call(thunk, entry_ptrs[bi], entry_stride, slot_off, Float64(0.0))

        row_base += chunk_n

# =========================================================================
# commit_batch_partitioned -- the PartitionedFlatHashAggregator form
# =========================================================================
# Same loop-transposed shape as `commit_batch`, but each row's entry lives
# in a different sub-table (selected by `partition_ids[row]`). All sub-
# tables share one AggLayout, so the per-slot thunk and offset are the same
# across partitions; only the entry pointer resolution differs.
#
# SAFETY: no resize may fire on ANY sub-table between the find_or_create
# that produced entries[row] / partition_ids[row] and this call (the
# caller pre-sizes the sub-tables first).
# =========================================================================

def _commit_batch_partitioned_impl[
    batch_origin: ImmOrigin, o_ids: Origin, o_entries: Origin
](
    plan: AggCommitPlan[batch_origin],
    mut pagg: PartitionedFlatHashAggregator,
    partition_ids: UnsafePointer[UInt8, o_ids],
    entries: UnsafePointer[EntryHandle, o_entries],
    num_rows: Int,
):
    """Body of `AggCommitPlan.commit_batch_partitioned`.

    SAFETY: `partition_ids` and `entries` point at `num_rows` elements
    each, formed by the caller from spans.
    """
    if num_rows <= 0:
        return

    var count_idxs = plan._int_view_ptr(0)
    var f64_idxs = plan._int_view_ptr(1)
    var f64_offs = plan._int_view_ptr(2)
    var i64_idxs = plan._int_view_ptr(3)
    var i64_offs = plan._int_view_ptr(4)
    var i32_idxs = plan._int_view_ptr(5)
    var i32_offs = plan._int_view_ptr(6)
    var f64_ptrs = plan._f64_ptrs()
    var i64_ptrs = plan._i64_ptrs()
    var i32_ptrs = plan._i32_ptrs()

    if not plan._layout_bound:
        # Correctness-safe fallback: per-row tag dispatch.
        for j in range(plan.n_count):
            var agg_idx = (count_idxs + j)[]
            for row in range(num_rows):
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                sub._update_count_only((entries + row)[], agg_idx)
        for j in range(plan.n_f64):
            var agg_idx = (f64_idxs + j)[]
            var ptr = (f64_ptrs + j)[]
            var offset = (f64_offs + j)[]
            for row in range(num_rows):
                var val = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                sub._update_agg((entries + row)[], agg_idx, val)
        for j in range(plan.n_i64):
            var agg_idx = (i64_idxs + j)[]
            var ptr = (i64_ptrs + j)[]
            var offset = (i64_offs + j)[]
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                sub._update_agg(
                    (entries + row)[], agg_idx, Float64(Int(raw))
                )
        for j in range(plan.n_i32):
            var agg_idx = (i32_idxs + j)[]
            var ptr = (i32_ptrs + j)[]
            var offset = (i32_offs + j)[]
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                sub._update_agg(
                    (entries + row)[], agg_idx, Float64(Int(raw))
                )
        # Validity-aware count(col).
        for j in range(plan.n_count_validity):
            var agg_idx = plan.count_validity_idxs[j]
            var v_ptr = plan.count_validity_ptrs[j]
            var v_off = plan.count_validity_bit_offsets[j]
            for row in range(num_rows):
                var bit_idx = v_off + row
                var byte_v = (v_ptr + (bit_idx >> 3))[]
                if (byte_v >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1):
                    var p = Int((partition_ids + row)[])
                    ref sub = pagg.partition(p)
                    sub._update_count_only((entries + row)[], agg_idx)
        return

    # Fast path: as commit_batch, but each entry pointer is resolved (by
    # entry index) against the row's own sub-table, interleaved per row;
    # the dominant tags still run the inlined accumulator write.
    for j in range(plan.n_count):
        var slot_off = plan.count_slot_offsets[j]
        var tag = plan.count_tags[j]
        if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
            for row in range(num_rows):
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_count_star(entry_ptr, slot_off)
        else:
            var thunk = plan.count_thunks[j]
            for row in range(num_rows):
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _thunk_call(thunk, entry_ptr, sub._entry_stride, slot_off, Float64(0.0))

    for j in range(plan.n_f64):
        var slot_off = plan.f64_slot_offsets[j]
        var tag = plan.f64_tags[j]
        var ptr = (f64_ptrs + j)[]
        var offset = (f64_offs + j)[]
        if tag == ACC_SUM_COUNT_MIN_MAX_F64:
            for row in range(num_rows):
                var val = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_sum_count_min_max_f64(entry_ptr, slot_off, val)
        elif tag == ACC_SUM_COUNT_F64:
            for row in range(num_rows):
                var val = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_sum_count_f64(entry_ptr, slot_off, val)
        elif tag == ACC_SUM_F64:
            for row in range(num_rows):
                var val = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_sum_f64(entry_ptr, slot_off, val)
        else:
            var thunk = plan.f64_thunks[j]
            for row in range(num_rows):
                var val = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _thunk_call(thunk, entry_ptr, sub._entry_stride, slot_off, val)

    for j in range(plan.n_i64):
        var slot_off = plan.i64_slot_offsets[j]
        var tag = plan.i64_tags[j]
        var ptr = (i64_ptrs + j)[]
        var offset = (i64_offs + j)[]
        if tag == ACC_SUM_COUNT_MIN_MAX_F64:
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_sum_count_min_max_f64(entry_ptr, slot_off, Float64(Int(raw)))
        elif tag == ACC_SUM_COUNT_F64:
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_sum_count_f64(entry_ptr, slot_off, Float64(Int(raw)))
        elif tag == ACC_SUM_F64:
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_sum_f64(entry_ptr, slot_off, Float64(Int(raw)))
        else:
            var thunk = plan.i64_thunks[j]
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _thunk_call(thunk, entry_ptr, sub._entry_stride, slot_off, Float64(Int(raw)))

    for j in range(plan.n_i32):
        var slot_off = plan.i32_slot_offsets[j]
        var tag = plan.i32_tags[j]
        var ptr = (i32_ptrs + j)[]
        var offset = (i32_offs + j)[]
        if tag == ACC_SUM_COUNT_MIN_MAX_F64:
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_sum_count_min_max_f64(entry_ptr, slot_off, Float64(Int(raw)))
        elif tag == ACC_SUM_COUNT_F64:
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_sum_count_f64(entry_ptr, slot_off, Float64(Int(raw)))
        elif tag == ACC_SUM_F64:
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _inline_sum_f64(entry_ptr, slot_off, Float64(Int(raw)))
        else:
            var thunk = plan.i32_thunks[j]
            for row in range(num_rows):
                var raw = (ptr + offset + row)[]
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))
                _thunk_call(thunk, entry_ptr, sub._entry_stride, slot_off, Float64(Int(raw)))

    # Validity-aware count(col): on a set bit, resolve the row's sub-table
    # entry and dispatch the resolved thunk.
    for j in range(plan.n_count_validity):
        var thunk = plan.count_validity_thunks[j]
        var slot_off = plan.count_validity_slot_offsets[j]
        var v_ptr = plan.count_validity_ptrs[j]
        var v_off = plan.count_validity_bit_offsets[j]
        for row in range(num_rows):
            var bit_idx = v_off + row
            var byte_v = (v_ptr + (bit_idx >> 3))[]
            if (byte_v >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1):
                var p = Int((partition_ids + row)[])
                ref sub = pagg.partition(p)
                var entry_ptr = sub._entry_ptr_by_idx(
                    Int((entries + row)[]._entry_idx)
                )
                _thunk_call(thunk, entry_ptr, sub._entry_stride, slot_off, Float64(0.0))

# =========================================================================
# commit_batch_indexed -- partition-bucketized batch commit
# =========================================================================
# PERF-CRITICAL: the column-major shape of `commit_batch`, driven by an
# explicit `row_indices` array; each index selects a row of the input
# batch and its `entries[row]` handle.
#
# The caller bucketizes the probe phase's entries by partition once per
# morsel, then calls this ONCE per non-empty partition with:
#   - `agg` = that partition's sub-table (loop-invariant for the call, so
#     there is no per-row sub-table lookup);
#   - `entries` = the probe phase's per-row handles;
#   - `row_indices` = the bucket's row indices.
#
# Per-row cost is a typed scalar load and an inlined slot write (or an
# indirect call into a monomorphic thunk for rare tags), against ~74 cycles
# for the row-major `commit_row` per row.
#
# SAFETY: as `commit_batch`: no resize on `agg` between the find_or_create
# that produced the entries and this call (the caller pre-grows each
# sub-table by its bucket size).
# =========================================================================

def _commit_batch_indexed_impl[
    batch_origin: ImmOrigin, o_entries: Origin, o_rows: Origin
](
    plan: AggCommitPlan[batch_origin],
    mut agg: FlatHashAggregator,
    entries: UnsafePointer[EntryHandle, o_entries],
    row_indices: UnsafePointer[Int32, o_rows],
    num_indexed_rows: Int,
):
    """Body of `AggCommitPlan.commit_batch_indexed`.

    SAFETY: `row_indices` points at `num_indexed_rows` indices and
    `entries` at a handle for every row they name, both formed by the
    caller from spans.
    """
    if num_indexed_rows <= 0:
        return

    # The plan's view pointers carry the origins of its own buffers.
    var count_idxs = plan._int_view_ptr(0)
    var f64_idxs = plan._int_view_ptr(1)
    var f64_offs = plan._int_view_ptr(2)
    var i64_idxs = plan._int_view_ptr(3)
    var i64_offs = plan._int_view_ptr(4)
    var i32_idxs = plan._int_view_ptr(5)
    var i32_offs = plan._int_view_ptr(6)
    var f64_ptrs = plan._f64_ptrs()
    var i64_ptrs = plan._i64_ptrs()
    var i32_ptrs = plan._i32_ptrs()

    if not plan._layout_bound:
        # Correctness-safe fallback: per-row tag dispatch.
        for j in range(plan.n_count):
            var agg_idx = (count_idxs + j)[]
            for bi in range(num_indexed_rows):
                var row = Int((row_indices + bi)[])
                agg._update_count_only((entries + row)[], agg_idx)
        for j in range(plan.n_f64):
            var agg_idx = (f64_idxs + j)[]
            var ptr = (f64_ptrs + j)[]
            var offset = (f64_offs + j)[]
            for bi in range(num_indexed_rows):
                var row = Int((row_indices + bi)[])
                var val = (ptr + offset + row)[]
                agg._update_agg((entries + row)[], agg_idx, val)
        for j in range(plan.n_i64):
            var agg_idx = (i64_idxs + j)[]
            var ptr = (i64_ptrs + j)[]
            var offset = (i64_offs + j)[]
            for bi in range(num_indexed_rows):
                var row = Int((row_indices + bi)[])
                var raw = (ptr + offset + row)[]
                agg._update_agg(
                    (entries + row)[], agg_idx, Float64(Int(raw))
                )
        for j in range(plan.n_i32):
            var agg_idx = (i32_idxs + j)[]
            var ptr = (i32_ptrs + j)[]
            var offset = (i32_offs + j)[]
            for bi in range(num_indexed_rows):
                var row = Int((row_indices + bi)[])
                var raw = (ptr + offset + row)[]
                agg._update_agg(
                    (entries + row)[], agg_idx, Float64(Int(raw))
                )
        # Validity-aware count(col).
        for j in range(plan.n_count_validity):
            var agg_idx = plan.count_validity_idxs[j]
            var v_ptr = plan.count_validity_ptrs[j]
            var v_off = plan.count_validity_bit_offsets[j]
            for bi in range(num_indexed_rows):
                var row = Int((row_indices + bi)[])
                var bit_idx = v_off + row
                var byte_v = (v_ptr + (bit_idx >> 3))[]
                if (byte_v >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1):
                    agg._update_count_only((entries + row)[], agg_idx)
        return

    # Chunk-major fast path: phase 2a gathers each row's index and entry
    # pointer ONCE, phase 2b runs per-agg tight loops over the gathered
    # parallel arrays. Stack budget: COMMIT_CHUNK * (8 + 8) bytes = 4 KB.
    # `uninitialized=True` skips the zero-fill: phase 2a writes every slot
    # phase 2b reads.
    var entry_stride = agg._entry_stride
    var entry_ptrs = Array[
        UnsafePointer[UInt8, origin_of(agg._entries)], COMMIT_CHUNK
    ](uninitialized=True)
    var row_in = Array[Int, COMMIT_CHUNK](uninitialized=True)

    var bi_base = 0
    while bi_base < num_indexed_rows:
        var chunk_n = COMMIT_CHUNK
        if bi_base + chunk_n > num_indexed_rows:
            chunk_n = num_indexed_rows - bi_base

        # Phase 2a: resolve the row index and gather the entry pointer
        # (by entry index, one dependent load) in one pass, keeping both
        # cache-hot together.
        for b in range(chunk_n):
            var row = Int((row_indices + bi_base + b)[])
            row_in[b] = row
            entry_ptrs[b] = agg._entry_ptr_by_idx(Int((entries + row)[]._entry_idx))

        # Phase 2b: per-agg outer loop, per-row inner loop over the
        # gathered ptrs and rows, with the per-SLOT tag check hoisted out
        # (see commit_batch).
        for j in range(plan.n_count):
            var slot_off = plan.count_slot_offsets[j]
            var tag = plan.count_tags[j]
            if tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
                for b in range(chunk_n):
                    _inline_count_star(entry_ptrs[b], slot_off)
            else:
                var thunk = plan.count_thunks[j]
                for b in range(chunk_n):
                    _thunk_call(thunk, entry_ptrs[b], entry_stride, slot_off, Float64(0.0))

        for j in range(plan.n_f64):
            var slot_off = plan.f64_slot_offsets[j]
            var tag = plan.f64_tags[j]
            var ptr = (f64_ptrs + j)[]
            var offset = (f64_offs + j)[]
            if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                for b in range(chunk_n):
                    var val = (ptr + offset + row_in[b])[]
                    _inline_sum_count_min_max_f64(
                        entry_ptrs[b], slot_off, val
                    )
            elif tag == ACC_SUM_COUNT_F64:
                for b in range(chunk_n):
                    var val = (ptr + offset + row_in[b])[]
                    _inline_sum_count_f64(entry_ptrs[b], slot_off, val)
            elif tag == ACC_SUM_F64:
                for b in range(chunk_n):
                    var val = (ptr + offset + row_in[b])[]
                    _inline_sum_f64(entry_ptrs[b], slot_off, val)
            else:
                var thunk = plan.f64_thunks[j]
                for b in range(chunk_n):
                    var val = (ptr + offset + row_in[b])[]
                    _thunk_call(thunk, entry_ptrs[b], entry_stride, slot_off, val)

        for j in range(plan.n_i64):
            var slot_off = plan.i64_slot_offsets[j]
            var tag = plan.i64_tags[j]
            var ptr = (i64_ptrs + j)[]
            var offset = (i64_offs + j)[]
            if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                for b in range(chunk_n):
                    var raw = (ptr + offset + row_in[b])[]
                    _inline_sum_count_min_max_f64(
                        entry_ptrs[b], slot_off, Float64(Int(raw))
                    )
            elif tag == ACC_SUM_COUNT_F64:
                for b in range(chunk_n):
                    var raw = (ptr + offset + row_in[b])[]
                    _inline_sum_count_f64(
                        entry_ptrs[b], slot_off, Float64(Int(raw))
                    )
            elif tag == ACC_SUM_F64:
                for b in range(chunk_n):
                    var raw = (ptr + offset + row_in[b])[]
                    _inline_sum_f64(
                        entry_ptrs[b], slot_off, Float64(Int(raw))
                    )
            else:
                var thunk = plan.i64_thunks[j]
                for b in range(chunk_n):
                    var raw = (ptr + offset + row_in[b])[]
                    _thunk_call(thunk, entry_ptrs[b], entry_stride, slot_off, Float64(Int(raw)))

        for j in range(plan.n_i32):
            var slot_off = plan.i32_slot_offsets[j]
            var tag = plan.i32_tags[j]
            var ptr = (i32_ptrs + j)[]
            var offset = (i32_offs + j)[]
            if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                for b in range(chunk_n):
                    var raw = (ptr + offset + row_in[b])[]
                    _inline_sum_count_min_max_f64(
                        entry_ptrs[b], slot_off, Float64(Int(raw))
                    )
            elif tag == ACC_SUM_COUNT_F64:
                for b in range(chunk_n):
                    var raw = (ptr + offset + row_in[b])[]
                    _inline_sum_count_f64(
                        entry_ptrs[b], slot_off, Float64(Int(raw))
                    )
            elif tag == ACC_SUM_F64:
                for b in range(chunk_n):
                    var raw = (ptr + offset + row_in[b])[]
                    _inline_sum_f64(
                        entry_ptrs[b], slot_off, Float64(Int(raw))
                    )
            else:
                var thunk = plan.i32_thunks[j]
                for b in range(chunk_n):
                    var raw = (ptr + offset + row_in[b])[]
                    _thunk_call(thunk, entry_ptrs[b], entry_stride, slot_off, Float64(Int(raw)))

        # Validity-aware count(col): dispatch the resolved thunk only
        # when the row's validity bit is set.
        for j in range(plan.n_count_validity):
            var thunk = plan.count_validity_thunks[j]
            var slot_off = plan.count_validity_slot_offsets[j]
            var v_ptr = plan.count_validity_ptrs[j]
            var v_off = plan.count_validity_bit_offsets[j]
            for b in range(chunk_n):
                var bit_idx = v_off + row_in[b]
                var byte_v = (v_ptr + (bit_idx >> 3))[]
                if (byte_v >> UInt8(bit_idx & 7)) & UInt8(1) == UInt8(1):
                    _thunk_call(thunk, entry_ptrs[b], entry_stride, slot_off, Float64(0.0))

        bi_base += chunk_n

