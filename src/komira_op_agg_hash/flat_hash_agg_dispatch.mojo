# =============================================================================
# FlatHashAggregator -- worker first touch / resize / pre-grow / iter / merge
# =============================================================================
#
# The bulk-grow, rehash, occupied-slot iteration and cross-aggregator merge
# helpers of `FlatHashAggregator`, as free functions taking the aggregator as
# their first argument; the methods in `flat_hash_agg.mojo` forward to them
# (the same pattern as `flat_hash_agg_probe.mojo` and
# `flat_hash_agg_accumulator.mojo`). They are package-private (their names
# start with `_`); any change to the resize / merge / iteration semantics
# lands here.
# =============================================================================

from std.collections import Array
from std.memory import unsafe_memcpy, unsafe_memset, UnsafePointer

from komira_udf.float_quotient_order import float_max_fold_f64, float_min_fold_f64

from .flat_hash_agg import EntryHandle, FlatHashAggregator
from .flat_hash_agg_hash import (
    _EMPTY_HASH,
    _LOAD_FACTOR_NUM,
    _LOAD_FACTOR_DEN,
)
from komira_agg_api.agg_layout import (
    ACC_SUM_F64,
    ACC_SUM_COUNT_F64,
    ACC_COUNT_STAR,
    ACC_COUNT_NONNULL,
    ACC_SUM_COUNT_MIN_MAX_F64,
)


@always_inline
def _null_ptr[T: AnyType, o: Origin]() -> UnsafePointer[T, o]:
    """A NULL typed pointer with the given origin, to fill the inactive
    slots of the chunk arrays of `_merge_impl`.

    # SAFETY: `Optional[UnsafePointer[...]]` is layout-compatible with the
    # bare pointer; `None` is the all-zero NULL bit pattern. Every slot is
    # overwritten before use within the chunk loop.
    """
    var none: Optional[UnsafePointer[T, o]] = None
    return UnsafePointer(to=none).bitcast[UnsafePointer[T, o]]()[]


# -----------------------------------------------------------------------------
# Worker-thread lazy initialization
# -----------------------------------------------------------------------------
#
# PERF-CRITICAL / SAFETY: a per-worker aggregator pre-sized on the main
# thread and then grown by its worker frees main-thread allocations on the
# worker thread, which corrupts a per-thread allocator's freelist. So
# construction has two phases:
#   1. main thread: construct with `initial_capacity=0` (no heap allocation
#      for `_entries` / `_tags`);
#   2. worker thread (first consume): `_worker_first_touch(target_cap)`
#      allocates the slot directory at the pre-size target, so every later
#      `_resize` by this worker frees worker-allocated buffers.
#
# Idempotent: a second call on an initialized aggregator is a no-op, so it
# is safe at the top of every `consume()`.

def _worker_first_touch_impl(mut agg: FlatHashAggregator, target_cap: Int):
    """Idempotent worker-thread lazy init of the slot directory.

    Only `_tags` and `_slot_to_idx` are allocated here; the entry buffer
    grows on demand in `_claim_new_entry_for_slot`.
    """
    if agg._capacity > 0:
        # Already initialized (either via `initial_capacity > 0` at
        # construction, or by a prior `_worker_first_touch` call).
        return
    var floor = target_cap
    if floor < 16:
        floor = 16
    var cap = 1
    while cap < floor:
        cap *= 2
    agg._capacity = cap
    agg._resize_threshold = cap * _LOAD_FACTOR_NUM // _LOAD_FACTOR_DEN
    agg._tags = List[UInt64](capacity=cap)
    agg._tags.resize(unsafe_uninit_length=cap)
    unsafe_memset(agg._tags.unsafe_ptr().bitcast[UInt8](), 0, cap * 8)
    # Fill `_slot_to_idx` with `_SLOT_EMPTY_IDX` (= -1): 0xFF * 4 bytes
    # is -1 in two's-complement Int32.
    agg._slot_to_idx = List[Int32](capacity=cap)
    agg._slot_to_idx.resize(unsafe_uninit_length=cap)
    unsafe_memset(agg._slot_to_idx.unsafe_ptr().bitcast[UInt8](), 0xFF, cap * 4)


# -----------------------------------------------------------------------------
# Resize -- double capacity and rehash the slot directory only
# -----------------------------------------------------------------------------
#
# Entries are stored in insertion order and never move, so a resize
# rebuilds only `_tags` (8B/slot) and `_slot_to_idx` (4B/slot); no entry
# bytes are copied.

def _resize_impl(mut agg: FlatHashAggregator):
    """Double capacity and rehash the slot directory.

    Rebuilds `_tags` and `_slot_to_idx` at 2x capacity. Entry-data
    blocks stay put — entries are indexed by insertion order and
    never move. PERF-CRITICAL: no entry-data memcpy.
    """
    var new_cap = agg._capacity * 2
    var new_tags = List[UInt64](capacity=new_cap)
    new_tags.resize(unsafe_uninit_length=new_cap)
    unsafe_memset(new_tags.unsafe_ptr().bitcast[UInt8](), 0, new_cap * 8)
    var new_slot_to_idx = List[Int32](capacity=new_cap)
    new_slot_to_idx.resize(unsafe_uninit_length=new_cap)
    # 0xFF * 4 bytes = Int32(-1).
    unsafe_memset(new_slot_to_idx.unsafe_ptr().bitcast[UInt8](), 0xFF, new_cap * 4)
    var new_mask = new_cap - 1

    # PERF-CRITICAL: extract raw pointers for the rehash loop. The inner
    # loop is pure pointer arithmetic — load tag + idx from old slot,
    # linear-probe new tag table, write tag + idx into new slot.
    var old_tags_ptr = agg._tags.unsafe_ptr()
    var old_idx_ptr = agg._slot_to_idx.unsafe_ptr()
    var new_tags_ptr = new_tags.unsafe_ptr()
    var new_idx_ptr = new_slot_to_idx.unsafe_ptr()

    for i in range(agg._capacity):
        var h = (old_tags_ptr + i)[]
        if h != UInt64(_EMPTY_HASH):
            var entry_idx = (old_idx_ptr + i)[]
            # Find slot in new table using new_tags.
            var slot = Int(h) & new_mask
            while True:
                if (new_tags_ptr + slot)[] == UInt64(_EMPTY_HASH):
                    (new_tags_ptr + slot)[] = h
                    (new_idx_ptr + slot)[] = entry_idx
                    break
                slot = (slot + 1) & new_mask

    agg._tags = new_tags^
    agg._slot_to_idx = new_slot_to_idx^
    agg._capacity = new_cap
    agg._resize_threshold = new_cap * _LOAD_FACTOR_NUM // _LOAD_FACTOR_DEN


# -----------------------------------------------------------------------------
# Pre-grow: a caller that knows how many groups it is about to merge sizes
# the table up front instead of paying lazy resizes during a bulk merge.
# Same rehash as `_resize()`, but it may jump several doublings at once.
# -----------------------------------------------------------------------------

def _ensure_merge_capacity_impl(mut agg: FlatHashAggregator, additional_groups: Int):
    """Pre-reserve HT slots for a bulk merge.

    Idempotent: a target at or below current capacity is a no-op.
    Entries are preserved bit-for-bit across the rehash (the same
    contract as `_resize()`).
    """
    if additional_groups <= 0:
        return
    _pre_grow_to_impl(agg, agg._num_groups + additional_groups)


def _pre_grow_impl(mut agg: FlatHashAggregator, target_groups: Int):
    """Pre-reserve capacity for an absolute target group count.

    Equivalent to `ensure_merge_capacity(target_groups - num_groups())`
    when `target_groups` exceeds current num_groups; no-op otherwise.
    """
    if target_groups <= agg._num_groups:
        return
    _pre_grow_to_impl(agg, target_groups)


def _pre_grow_to_impl(mut agg: FlatHashAggregator, target_groups: Int):
    """Shared worker for ensure_merge_capacity / pre_grow.

    Rebuilds only `_tags` and `_slot_to_idx` at the new capacity;
    entries keep their `entry_idx` positions.
    """
    var needed_slots = (
        target_groups * _LOAD_FACTOR_DEN + _LOAD_FACTOR_NUM - 1
    ) // _LOAD_FACTOR_NUM
    if needed_slots < 16:
        needed_slots = 16
    var new_cap = 1
    while new_cap < needed_slots:
        new_cap = new_cap << 1
    if new_cap <= agg._capacity:
        return

    # Allocate fresh slot directory at `new_cap`. Same shape as
    # `_resize()` but not limited to a single doubling.
    var new_tags = List[UInt64](capacity=new_cap)
    new_tags.resize(unsafe_uninit_length=new_cap)
    unsafe_memset(new_tags.unsafe_ptr().bitcast[UInt8](), 0, new_cap * 8)
    var new_slot_to_idx = List[Int32](capacity=new_cap)
    new_slot_to_idx.resize(unsafe_uninit_length=new_cap)
    # 0xFF * 4 bytes = Int32(-1).
    unsafe_memset(new_slot_to_idx.unsafe_ptr().bitcast[UInt8](), 0xFF, new_cap * 4)
    var new_mask = new_cap - 1

    # PERF-CRITICAL: rehash the old slot directory into the new one. No
    # entry bytes move.
    var old_tags_ptr = agg._tags.unsafe_ptr()
    var old_idx_ptr = agg._slot_to_idx.unsafe_ptr()
    var new_tags_ptr = new_tags.unsafe_ptr()
    var new_idx_ptr = new_slot_to_idx.unsafe_ptr()

    for i in range(agg._capacity):
        var h = (old_tags_ptr + i)[]
        if h != UInt64(_EMPTY_HASH):
            var entry_idx = (old_idx_ptr + i)[]
            var slot = Int(h) & new_mask
            while True:
                if (new_tags_ptr + slot)[] == UInt64(_EMPTY_HASH):
                    (new_tags_ptr + slot)[] = h
                    (new_idx_ptr + slot)[] = entry_idx
                    break
                slot = (slot + 1) & new_mask

    agg._tags = new_tags^
    agg._slot_to_idx = new_slot_to_idx^
    agg._capacity = new_cap
    agg._resize_threshold = (
        new_cap * _LOAD_FACTOR_NUM // _LOAD_FACTOR_DEN
    )


# -----------------------------------------------------------------------------
# Iteration over occupied entries
# -----------------------------------------------------------------------------

def _iter_entries_impl(agg: FlatHashAggregator) -> List[EntryHandle]:
    """Return a list of handles for all occupied entries.

    Used for result extraction. The handles are valid as long as the
    FlatHashAggregator is alive and no mutations occur. Each handle
    carries both the slot and the entry index (one extra load per
    entry, off the hot path).
    """
    var result = List[EntryHandle](capacity=agg._num_groups)
    var slot_to_idx_ptr = agg._slot_to_idx_mut_ptr()
    for i in range(agg._capacity):
        # PERF-CRITICAL: Check _tags (compact, 8B stride) not _entries
        # (_entry_stride).  For 100K groups / 262K capacity, this scans
        # 2MB instead of 12MB.
        if agg._tag_at(i) != UInt64(_EMPTY_HASH):
            var entry_idx = Int((slot_to_idx_ptr + i)[])
            result.append(EntryHandle(i, entry_idx))
    return result^


# -----------------------------------------------------------------------------
# Merge -- fold another FlatHashAggregator into self (chunk-major)
# -----------------------------------------------------------------------------
#
# For each occupied entry in `other`, find or create the group in `agg` and
# combine the accumulators (sum: add, count: add, min: min, max: max).
#
# PERF-CRITICAL: chunk-major, the shape of DuckDB's
# `RowOperations::CombineStates`. Up to MERGE_CHUNK source entries are
# probed into `agg` first (phase 1); then, per aggregate, the slot tag is
# switched on ONCE and a tag-specialized loop folds the whole chunk
# (phase 2). The tag dispatch count drops from `entries * aggs` to
# `(entries / MERGE_CHUNK) * aggs`.
#
# A find-or-create may grow `agg._entries`, invalidating any `agg` entry
# pointer taken before it, so phase 1 records entry INDICES (stable across
# growth) and the pointers are derived only after the chunk's probes. The
# source is read-only for the merge and is walked by insertion-order index
# in [0, other._num_groups), with no slot scan.


# Chunk size for the column-major fold: 256 entries of one aggregate are
# 8 KB at 32B per slot, which fits in L1. The chunk arrays are on the stack.
comptime MERGE_CHUNK: Int = 256


@always_inline
def _fold_quartet_chunk[
    o_self: Origin[mut=True],
    o_src: Origin,
    o_self_outer: Origin,
    o_src_outer: Origin,
](
    self_aps: UnsafePointer[UnsafePointer[UInt8, o_self], o_self_outer],
    src_aps: UnsafePointer[UnsafePointer[UInt8, o_src], o_src_outer],
    n: Int,
):
    """Tight typed inner loop for ACC_SUM_COUNT_MIN_MAX_F64 (32B quartet)
    over `n` (self_ap, src_ap) pointer pairs. PERF-CRITICAL: no per-row
    tag check; the caller hoisted the dispatch outside this loop.
    """
    for i in range(n):
        var self_ap = self_aps[i]
        var src_ap = src_aps[i]
        var self_sum = self_ap.bitcast[Float64]()
        self_sum[] = self_sum[] + src_ap.bitcast[Float64]()[]
        var self_count = (self_ap + 8).bitcast[Int64]()
        self_count[] = self_count[] + (src_ap + 8).bitcast[Int64]()[]
        var self_min = (self_ap + 16).bitcast[Float64]()
        var src_min = (src_ap + 16).bitcast[Float64]()[]
        self_min[] = float_min_fold_f64(self_min[], src_min)
        var self_max = (self_ap + 24).bitcast[Float64]()
        var src_max = (src_ap + 24).bitcast[Float64]()[]
        self_max[] = float_max_fold_f64(self_max[], src_max)


@always_inline
def _fold_sum_count_chunk[
    o_self: Origin[mut=True],
    o_src: Origin,
    o_self_outer: Origin,
    o_src_outer: Origin,
](
    self_aps: UnsafePointer[UnsafePointer[UInt8, o_self], o_self_outer],
    src_aps: UnsafePointer[UnsafePointer[UInt8, o_src], o_src_outer],
    n: Int,
):
    """Tight typed inner loop for ACC_SUM_COUNT_F64 (16B sum+count)."""
    for i in range(n):
        var self_ap = self_aps[i]
        var src_ap = src_aps[i]
        var self_sum = self_ap.bitcast[Float64]()
        self_sum[] = self_sum[] + src_ap.bitcast[Float64]()[]
        var self_count = (self_ap + 8).bitcast[Int64]()
        self_count[] = self_count[] + (src_ap + 8).bitcast[Int64]()[]


@always_inline
def _fold_sum_chunk[
    o_self: Origin[mut=True],
    o_src: Origin,
    o_self_outer: Origin,
    o_src_outer: Origin,
](
    self_aps: UnsafePointer[UnsafePointer[UInt8, o_self], o_self_outer],
    src_aps: UnsafePointer[UnsafePointer[UInt8, o_src], o_src_outer],
    n: Int,
):
    """Tight typed inner loop for ACC_SUM_F64 (8B sum)."""
    for i in range(n):
        var self_sum = self_aps[i].bitcast[Float64]()
        self_sum[] = self_sum[] + src_aps[i].bitcast[Float64]()[]


@always_inline
def _fold_count_chunk[
    o_self: Origin[mut=True],
    o_src: Origin,
    o_self_outer: Origin,
    o_src_outer: Origin,
](
    self_aps: UnsafePointer[UnsafePointer[UInt8, o_self], o_self_outer],
    src_aps: UnsafePointer[UnsafePointer[UInt8, o_src], o_src_outer],
    n: Int,
):
    """Tight typed inner loop for ACC_COUNT_STAR/ACC_COUNT_NONNULL (8B count)."""
    for i in range(n):
        var self_count = self_aps[i].bitcast[Int64]()
        self_count[] = self_count[] + src_aps[i].bitcast[Int64]()[]


def _merge_impl(mut agg: FlatHashAggregator, other: FlatHashAggregator):
    """Merge another FlatHashAggregator into `agg` (chunk-major).

    Combines per-worker aggregation results into one. See the block
    above for the chunk-major shape.
    """
    var num_other = other._num_groups
    if num_other == 0:
        return

    var num_aggs = agg._num_aggs
    var num_keys = agg._num_keys
    var aggs_offset = agg._aggs_offset

    # Stack-allocated chunk state: target entry INDICES from phase 1a
    # (stable across a growth of agg._entries), then the target and source
    # entry pointers re-derived in phase 1b, then the per-aggregate slot
    # pointer arrays of phase 2. Each pointer carries the origin of the
    # entry buffer it points into.
    var self_idxs = Array[Int, MERGE_CHUNK](fill=0)
    var src_ptrs = Array[
        UnsafePointer[UInt8, origin_of(other._entries)], MERGE_CHUNK
    ](fill=_null_ptr[UInt8, origin_of(other._entries)]())
    var self_ptrs = Array[
        UnsafePointer[UInt8, origin_of(agg._entries)], MERGE_CHUNK
    ](fill=_null_ptr[UInt8, origin_of(agg._entries)]())
    var self_aps = Array[
        UnsafePointer[UInt8, origin_of(agg._entries)], MERGE_CHUNK
    ](fill=_null_ptr[UInt8, origin_of(agg._entries)]())
    var src_aps = Array[
        UnsafePointer[UInt8, origin_of(other._entries)], MERGE_CHUNK
    ](fill=_null_ptr[UInt8, origin_of(other._entries)]())

    # Walk `other`'s entries in insertion order: no allocation, no slot
    # scan.
    var idx = 0
    while idx < num_other:
        var chunk_n = MERGE_CHUNK
        if idx + chunk_n > num_other:
            chunk_n = num_other - idx

        # Phase 1a: read each source entry's keys and hash, find-or-create
        # in `agg`. A find-or-create may grow `agg`'s entry buffer, so only
        # entry indices are kept here, NOT pointers.
        for b in range(chunk_n):
            var other_entry_idx = idx + b
            var src_ptr = other._entry_ptr_by_idx(other_entry_idx)
            var oh = FlatHashAggregator._hash_at(src_ptr)
            var self_handle: EntryHandle
            if num_keys == 1:
                var key = FlatHashAggregator._key_ptr(src_ptr)[]
                self_handle = agg.probe_or_insert_row(oh, key)
            elif num_keys == 2:
                var kp = FlatHashAggregator._key_ptr(src_ptr)
                self_handle = agg.find_or_create_2_prehashed(kp[], (kp + 1)[], oh)
            else:
                self_handle = agg._find_or_create_n_prehashed(
                    FlatHashAggregator._key_ptr(src_ptr), num_keys, oh
                )
            self_idxs[b] = Int(self_handle._entry_idx)

        # Phase 1b: derive both entry pointers AFTER all of the chunk's
        # probes (`agg._entries` may have grown during them).
        for b in range(chunk_n):
            var other_entry_idx = idx + b
            src_ptrs[b] = other._entry_ptr_by_idx(other_entry_idx)
            self_ptrs[b] = agg._entry_ptr_by_idx(self_idxs[b])

        # Phase 2: outer-agg, inner-row. For each agg index `a`, switch
        # ONCE on `tags[a]`, then run the tag-specialized loop over the
        # chunk's (self_ptr+offset, src_ptr+offset) pairs.
        # PERF-CRITICAL: the tag dispatch happens once per agg per chunk,
        # not once per entry per agg.
        for a in range(num_aggs):
            var tag = agg._layout.tags[a]
            var off = aggs_offset + agg._layout.offsets[a]
            for i in range(chunk_n):
                self_aps[i] = self_ptrs[i] + off
                src_aps[i] = src_ptrs[i] + off

            if tag == ACC_SUM_COUNT_MIN_MAX_F64:
                _fold_quartet_chunk(
                    self_aps.unsafe_ptr(),
                    src_aps.unsafe_ptr(),
                    chunk_n,
                )
            elif tag == ACC_SUM_COUNT_F64:
                _fold_sum_count_chunk(
                    self_aps.unsafe_ptr(),
                    src_aps.unsafe_ptr(),
                    chunk_n,
                )
            elif tag == ACC_SUM_F64:
                _fold_sum_chunk(
                    self_aps.unsafe_ptr(),
                    src_aps.unsafe_ptr(),
                    chunk_n,
                )
            elif tag == ACC_COUNT_STAR or tag == ACC_COUNT_NONNULL:
                _fold_count_chunk(
                    self_aps.unsafe_ptr(),
                    src_aps.unsafe_ptr(),
                    chunk_n,
                )
            else:
                # Defensive default: quartet shape.
                _fold_quartet_chunk(
                    self_aps.unsafe_ptr(),
                    src_aps.unsafe_ptr(),
                    chunk_n,
                )

        idx += chunk_n
