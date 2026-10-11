# =============================================================================
# FlatHashAggregator -- probe / find_or_create implementations
# =============================================================================
#
# The `find_or_create_*` probe loops and `batch_find_or_create_1`, as free
# functions taking the aggregator as their first argument; the methods in
# `flat_hash_agg.mojo` forward to them. They are package-private (their
# names start with `_`); any change to the probe semantics lands here.
#
# Each probe holds the `mut agg` borrow for its whole run. A new entry is
# claimed with `agg._claim_new_entry_for_slot(slot)` (which updates
# `_slot_to_idx[slot]`), its tag, hash, keys and accumulators are written,
# and `agg._num_groups` is bumped AFTER the writes. Each returned
# EntryHandle carries both the slot and the entry index, so the caller's
# `agg._entry_ptr_by_idx(handle._entry_idx)` skips the slot directory.
# =============================================================================

from std.memory import UnsafePointer
from std.sys.intrinsics import prefetch, PrefetchOptions

from .flat_hash_agg import (
    EntryHandle,
    FlatHashAggregator,
)
from .flat_hash_agg_accumulator import _init_all_agg_slots_impl
from .flat_hash_agg_hash import (
    _EMPTY_HASH,
    _fib_hash_1,
    _fib_hash_2,
    _fib_hash_n,
)


# -----------------------------------------------------------------------------
# Single-key insert (specialized for the common 1-key case)
# -----------------------------------------------------------------------------

@always_inline
def _find_or_create_1_impl(mut agg: FlatHashAggregator, key: Int64) -> EntryHandle:
    """Find or create an entry for a single Int64 key.

    See `FlatHashAggregator.find_or_create_1` for the contract. The
    returned `EntryHandle` is invalidated by any subsequent call that
    triggers `_resize()`.
    """
    if agg._num_groups > agg._resize_threshold:
        agg._resize()

    var mask = agg._capacity - 1
    var h = _fib_hash_1(key)
    var slot = Int(h) & mask

    # PERF-CRITICAL: Probe _tags array (8B stride) — tag fits in L2 at
    # 100K groups even when entry data does not.
    while True:
        var tag = agg._tag_at(slot)
        if tag == UInt64(_EMPTY_HASH):
            # Claim a new entry; capture entry_idx before the claim (the
            # new entry is appended at `_num_groups`, not yet bumped).
            var entry_idx = agg._num_groups
            var entry = agg._claim_new_entry_for_slot(slot)
            agg._set_tag(slot, h)
            FlatHashAggregator._set_hash(entry, h)
            FlatHashAggregator._key_ptr(entry)[] = key
            _init_all_agg_slots_impl(agg._layout, agg._aggs_offset, entry)
            agg._num_groups += 1
            return EntryHandle(slot, entry_idx)
        elif tag == h and FlatHashAggregator._keys_match_1(agg._entry_ptr(slot), key):
            # Hit: read entry_idx from the slot directory (`_entry_ptr`
            # loaded it for the key match, so it is hot in cache).
            var entry_idx = Int((agg._slot_to_idx_mut_ptr() + slot)[])
            return EntryHandle(slot, entry_idx)
        else:
            slot = (slot + 1) & mask


@always_inline
def _find_or_create_1_prehashed_impl(
    mut agg: FlatHashAggregator, key: Int64, h: UInt64
) -> EntryHandle:
    """Find or create using a caller-provided hash.

    PERF-CRITICAL: Used by radix / streaming paths that hash once for both
    partition routing and HT probing, so the hash never gets recomputed at
    probe time.  The hash must be non-zero (_fib_hash_* guarantee).
    """
    if agg._num_groups > agg._resize_threshold:
        agg._resize()

    var mask = agg._capacity - 1
    var slot = Int(h) & mask

    # PERF-CRITICAL: Probe _tags array (8B stride). On collision, fall
    # through to `_entry_ptr(slot)` only AFTER a tag match.
    while True:
        var tag = agg._tag_at(slot)
        if tag == UInt64(_EMPTY_HASH):
            # Claim a new entry; capture entry_idx before the claim.
            var entry_idx = agg._num_groups
            var entry = agg._claim_new_entry_for_slot(slot)
            agg._set_tag(slot, h)
            FlatHashAggregator._set_hash(entry, h)
            FlatHashAggregator._key_ptr(entry)[] = key
            _init_all_agg_slots_impl(agg._layout, agg._aggs_offset, entry)
            agg._num_groups += 1
            return EntryHandle(slot, entry_idx)
        elif tag == h and FlatHashAggregator._keys_match_1(agg._entry_ptr(slot), key):
            var entry_idx = Int((agg._slot_to_idx_mut_ptr() + slot)[])
            return EntryHandle(slot, entry_idx)
        else:
            slot = (slot + 1) & mask


# -----------------------------------------------------------------------------
# Two-key insert
# -----------------------------------------------------------------------------

@always_inline
def _find_or_create_2_impl(
    mut agg: FlatHashAggregator, k0: Int64, k1: Int64
) -> EntryHandle:
    """Find or create for two Int64 keys using `_fib_hash_2`.

    PERF-CORRECTNESS-CRITICAL: `_fib_hash_2` is bit-identical to
    `_fib_hash_n(&[k0,k1], 2)` -- see the big warning in
    flat_hash_agg_hash.mojo above `_fib_hash_2`.  Entries inserted here
    must interoperate with N-key merges.
    """
    if agg._num_groups > agg._resize_threshold:
        agg._resize()
    var h = _fib_hash_2(k0, k1)
    var mask = agg._capacity - 1
    var slot = Int(h) & mask

    # PERF-CRITICAL: Probe _tags array (8B stride).
    while True:
        var tag = agg._tag_at(slot)
        if tag == UInt64(_EMPTY_HASH):
            # Claim a new entry; capture entry_idx before the claim.
            var entry_idx = agg._num_groups
            var entry = agg._claim_new_entry_for_slot(slot)
            agg._set_tag(slot, h)
            FlatHashAggregator._set_hash(entry, h)
            var kp = FlatHashAggregator._key_ptr(entry)
            kp[] = k0
            (kp + 1)[] = k1
            _init_all_agg_slots_impl(agg._layout, agg._aggs_offset, entry)
            agg._num_groups += 1
            return EntryHandle(slot, entry_idx)
        elif tag == h and FlatHashAggregator._keys_match_2(agg._entry_ptr(slot), k0, k1):
            var entry_idx = Int((agg._slot_to_idx_mut_ptr() + slot)[])
            return EntryHandle(slot, entry_idx)
        else:
            slot = (slot + 1) & mask


@always_inline
def _find_or_create_2_prehashed_impl(
    mut agg: FlatHashAggregator, k0: Int64, k1: Int64, h: UInt64
) -> EntryHandle:
    """Two-key find_or_create with pre-computed hash (radix path)."""
    if agg._num_groups > agg._resize_threshold:
        agg._resize()

    var mask = agg._capacity - 1
    var slot = Int(h) & mask

    # PERF-CRITICAL: Probe _tags array (8B stride).
    while True:
        var tag = agg._tag_at(slot)
        if tag == UInt64(_EMPTY_HASH):
            # Claim a new entry; capture entry_idx before the claim.
            var entry_idx = agg._num_groups
            var entry = agg._claim_new_entry_for_slot(slot)
            agg._set_tag(slot, h)
            FlatHashAggregator._set_hash(entry, h)
            var kp = FlatHashAggregator._key_ptr(entry)
            kp[] = k0
            (kp + 1)[] = k1
            _init_all_agg_slots_impl(agg._layout, agg._aggs_offset, entry)
            agg._num_groups += 1
            return EntryHandle(slot, entry_idx)
        elif tag == h and FlatHashAggregator._keys_match_2(agg._entry_ptr(slot), k0, k1):
            var entry_idx = Int((agg._slot_to_idx_mut_ptr() + slot)[])
            return EntryHandle(slot, entry_idx)
        else:
            slot = (slot + 1) & mask


# -----------------------------------------------------------------------------
# N-key insert (general)
# -----------------------------------------------------------------------------

def _find_or_create_n_impl[
    key_origin: Origin
](
    mut agg: FlatHashAggregator,
    keys: UnsafePointer[Int64, key_origin],
    num_keys: Int,
) -> EntryHandle:
    """Find or create for N Int64 keys (general path).

    `keys` must point at `num_keys` consecutive Int64 values in a buffer
    that outlives this call.  `num_keys` should match `agg._num_keys`.
    """
    if agg._num_groups > agg._resize_threshold:
        agg._resize()

    # Hash all keys: bitcast Int64* to UInt8* for the hash function (the
    # keys' origin flows through the bitcast).
    var h = _fib_hash_n(
        keys.bitcast[UInt8](),
        num_keys,
    )

    var mask = agg._capacity - 1
    var slot = Int(h) & mask

    # PERF-CRITICAL: Probe _tags array (8B stride).
    while True:
        var tag = agg._tag_at(slot)
        if tag == UInt64(_EMPTY_HASH):
            # Claim a new entry; capture entry_idx before the claim.
            var entry_idx = agg._num_groups
            var entry = agg._claim_new_entry_for_slot(slot)
            agg._set_tag(slot, h)
            FlatHashAggregator._set_hash(entry, h)
            var kp = FlatHashAggregator._key_ptr(entry)
            for i in range(num_keys):
                (kp + i)[] = (keys + i)[]
            _init_all_agg_slots_impl(agg._layout, agg._aggs_offset, entry)
            agg._num_groups += 1
            return EntryHandle(slot, entry_idx)
        elif tag == h and FlatHashAggregator._keys_match_n(agg._entry_ptr(slot), keys, num_keys):
            var entry_idx = Int((agg._slot_to_idx_mut_ptr() + slot)[])
            return EntryHandle(slot, entry_idx)
        else:
            slot = (slot + 1) & mask


def _find_or_create_n_prehashed_impl[
    key_origin: Origin
](
    mut agg: FlatHashAggregator,
    keys: UnsafePointer[Int64, key_origin],
    num_keys: Int,
    h: UInt64,
) -> EntryHandle:
    """N-key find_or_create with pre-computed hash (radix / merge path).

    `h` MUST be the same value `_fib_hash_n(keys.bitcast[UInt8](), num_keys)`
    would produce -- the merge correctness invariant in flat_hash_agg_hash
    depends on this.
    """
    if agg._num_groups > agg._resize_threshold:
        agg._resize()

    var mask = agg._capacity - 1
    var slot = Int(h) & mask

    # PERF-CRITICAL: Probe _tags array (8B stride).
    while True:
        var tag = agg._tag_at(slot)
        if tag == UInt64(_EMPTY_HASH):
            # Claim a new entry; capture entry_idx before the claim.
            var entry_idx = agg._num_groups
            var entry = agg._claim_new_entry_for_slot(slot)
            agg._set_tag(slot, h)
            FlatHashAggregator._set_hash(entry, h)
            var kp = FlatHashAggregator._key_ptr(entry)
            for i in range(num_keys):
                (kp + i)[] = (keys + i)[]
            _init_all_agg_slots_impl(agg._layout, agg._aggs_offset, entry)
            agg._num_groups += 1
            return EntryHandle(slot, entry_idx)
        elif tag == h and FlatHashAggregator._keys_match_n(agg._entry_ptr(slot), keys, num_keys):
            var entry_idx = Int((agg._slot_to_idx_mut_ptr() + slot)[])
            return EntryHandle(slot, entry_idx)
        else:
            slot = (slot + 1) & mask


# -----------------------------------------------------------------------------
# Batch insert with prefetch
# -----------------------------------------------------------------------------

def _batch_find_or_create_1_impl[
    keys_origin: Origin,
    out_origin: Origin[mut=True],
](
    mut agg: FlatHashAggregator,
    keys_ptr: UnsafePointer[Scalar[DType.int64], keys_origin],
    num_rows: Int,
    out_entries: UnsafePointer[EntryHandle, out_origin],
):
    """Batch find-or-create for single-key agg with an 8-wide prefetch
    window: compute hash and slot for the next 8 rows, prefetch the
    `_tags` slot of each, then probe each row.

    PERF-CRITICAL: prefetch targets the compact `_tags` array (8B stride),
    not `_entries` (_entry_stride 48B+).

    SAFETY: `keys_ptr` points at `num_rows` readable keys and
    `out_entries` at `num_rows` writable handles; the public
    `FlatHashAggregator.batch_find_or_create_1` forms both from spans.
    """
    comptime BATCH = 8
    var mask = agg._capacity - 1
    var tags_ptr = agg._tags_mut_ptr()

    var row = 0

    # Process in batches of 8 with prefetch
    while row + BATCH <= num_rows:
        # Ensure capacity for up to BATCH new groups before the batch.
        if agg._num_groups + BATCH > agg._resize_threshold:
            agg._resize()
            mask = agg._capacity - 1
            tags_ptr = agg._tags_mut_ptr()

        # PERF-CRITICAL: Prefetch _tags slots (8B stride) not _entries.
        for b in range(BATCH):
            var key = Int64((keys_ptr + row + b)[])
            var h = _fib_hash_1(key)
            var slot = Int(h) & mask
            # Prefetch the tag at the computed slot.
            prefetch[params = PrefetchOptions().for_read().high_locality()](
                (tags_ptr + slot).bitcast[Scalar[DType.int64]]()
            )

        # Phase 3: actual probe (slots should now be in L1/L2 cache).
        for b in range(BATCH):
            var key = Int64((keys_ptr + row + b)[])
            (out_entries + row + b)[] = _find_or_create_1_impl(agg, key)

        row += BATCH

    # Process remaining rows (< BATCH) without prefetch
    while row < num_rows:
        if agg._num_groups > agg._resize_threshold:
            agg._resize()
        var key = Int64((keys_ptr + row)[])
        (out_entries + row)[] = _find_or_create_1_impl(agg, key)
        row += 1
