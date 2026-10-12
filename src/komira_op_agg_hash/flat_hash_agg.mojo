# =============================================================================
# FlatHashAggregator -- split-index hash table for aggregation
# =============================================================================
#
# PERF-CRITICAL: split-index design. Probing walks a SEPARATE compact tag
# array (`_tags`, 8 B per slot) instead of the full entry buffer at
# `_entry_stride` (48 B and more per slot). At 100K groups over 262K slots
# the tag array is 2 MB (fits in L2) against 12 MB of entries (thrashes L2).
# A co-located layout probed 1.8x slower in CPU time at 100K groups.
#
# Layout:
#   _tags:        [hash0: 8B][hash1: 8B]...  indexed by slot, 0 = empty
#   _slot_to_idx: [idx0: 4B][idx1: 4B]...    indexed by slot, -1 = empty
#   _entries:     [hash: 8B][key0: 8B]...[keyN: 8B][agg0]...[aggM]
#                 indexed by insertion order (`entry_idx * _entry_stride`)
#
# Probe sequence: check `_tags[slot]` (8 B stride). On a hash match, follow
# `_slot_to_idx[slot]` to the entry and compare keys. On an empty slot,
# insert there. Entries never move when the slot directory is rehashed
# (`_resize`, `pre_grow`): only `_tags` and `_slot_to_idx` are rebuilt, and
# the entry buffer grows by doubling with one copy of the live entries.
#
# Pointers: every raw pointer this module and its helper modules form is
# derived from a field of the aggregator (`_tags`, `_slot_to_idx`,
# `_entries`) and carries that field's origin, so the compiler keeps the
# aggregator alive across each use. A pointer is valid until the next call
# that may grow the field it points into (`find_or_create_*`, `_resize`,
# `pre_grow`, `ensure_merge_capacity`).
# =============================================================================

from std.memory import unsafe_memset, UnsafePointer

from komira_collections.slab import Slab

from .flat_hash_partition_flush import (
    FlatHashPartitionFlush,
    _scatter_flush,
)

# Hash helpers and layout constants live in flat_hash_agg_hash.mojo; they are
# imported here so `from komira_op_agg_hash.flat_hash_agg import _fib_hash_1`
# (and the constants) also resolves.
from .flat_hash_agg_hash import (
    _EMPTY_HASH,
    _FIB_HASH_CONST,
    _LOAD_FACTOR_NUM,
    _LOAD_FACTOR_DEN,
    _AGG_SUM_OFF,
    _AGG_COUNT_OFF,
    _AGG_MIN_OFF,
    _AGG_MAX_OFF,
    _HASH_BYTES,
    _F64_MIN_SEED_BITS,
    _F64_MAX_SEED_BITS,
    _PRIME_0,
    _PRIME_1,
    _PRIME_2,
    _PRIME_3,
    _PRIME_4,
    _PRIME_5,
    _PRIME_6,
    _PRIME_7,
    _ENTRY_BLOCK_SIZE,
    _SLOT_EMPTY_IDX,
    _fib_hash_1,
    _fib_hash_2,
    _fib_hash_n,
)
from komira_counters.keyeq_census import keyeq_record, KEYEQ_FLATHASH_KEYS_N
from komira_agg_api.agg_layout import AggLayout

# `commit_row` takes an AggCommitPlan, and agg_commit.mojo imports this
# module: the two modules form one cycle, which Mojo resolves inside a
# package.
from .agg_commit import AggCommitPlan


# =============================================================================
# EntryHandle -- a register-passable handle to a FlatHashAggregator entry
# =============================================================================
#
# The handle carries the entry's slot index and its insertion-order index,
# not a pointer: every method that takes a handle resolves the entry pointer
# afresh from the aggregator it is called on, with the aggregator borrowed
# for the call, so the compiler cannot destroy `_entries` while a write
# through the pointer is pending. Both indices are `Int32`, so the handle is
# 8 bytes: the capacity is a power of two well below 2^31, and the group
# count is bounded by `_slot_to_idx`'s `Int32` elements.
#
# A handle is valid only for the aggregator that produced it, and only until
# the next `find_or_create_*` call (a resize rebuilds the slot directory; the
# entry index survives it, but do not rely on that).

struct EntryHandle(TrivialRegisterPassable, ImplicitlyCopyable):
    """Opaque handle to a FlatHashAggregator entry.

    Carries the HT slot index (`_slot`) and the entry's insertion-order
    index (`_entry_idx`) inside the owning aggregator's `_entries` buffer.
    Hot paths resolve the entry with `agg._entry_ptr_by_idx(entry_idx)`,
    one load; `_entry_ptr(slot)` costs a second load through
    `_slot_to_idx[slot]` and serves code that only has a slot
    (`iter_entries` walks `_tags` slot by slot).

    The handle is INVALIDATED by any subsequent `find_or_create_*` call
    that triggers `_resize()`.
    """

    var _slot: Int32
    var _entry_idx: Int32

    @always_inline
    def __init__(out self, slot: Int, entry_idx: Int):
        """Construct with both slot and insertion-order entry index."""
        self._slot = Int32(slot)
        self._entry_idx = Int32(entry_idx)

    @always_inline
    def slot(self) -> Int:
        """The slot index this handle refers to inside the owning
        aggregator's `_tags` / `_slot_to_idx` directory."""
        return Int(self._slot)

    @always_inline
    def entry_idx(self) -> Int:
        """The insertion-order index this handle refers to inside the
        owning aggregator's `_entries` buffer."""
        return Int(self._entry_idx)


struct FlatHashAggregator(Movable, Deinitable):
    """Hash table for GROUP BY aggregation with insertion-order entry storage.

    Group state (hash, keys, accumulators) is stored in a flat
    insertion-order-indexed entry buffer (`_entries`). Slot identity
    (`slot`) and entry identity (`entry_idx`) are decoupled: the slot
    directory `_tags` plus the parallel `_slot_to_idx[slot] -> entry_idx`
    map indirect to the entry data. Open addressing + linear probing on
    `_tags`.

    Entry layout (contiguous bytes at `entry_idx * _entry_stride` inside
    `_entries`):
        [hash: 8B][key0: 8B]...[keyN: 8B][agg0]...[aggM]

    Each agg slot's width and offset follow `_layout` (`AggLayout`); the
    default is the 32 B quartet [sum: 8B][count: 8B][min: 8B][max: 8B].

    Empty slots are identified by `_tags[slot] == 0` (every computed hash
    is non-zero, by `_fib_hash_*`).

    Fields:
        _entries: Flat insertion-order-indexed entry buffer. Entry `i`
            lives at `_entries[i * _entry_stride .. (i+1) * _entry_stride]`.
            Grows by doubling via `_grow_entries_capacity`; slot-directory
            resizes never relocate entries.
        _entries_capacity: Number of entry slots currently allocated.
        _tags: Compact slot directory (8B per slot, 0 = empty).
        _slot_to_idx: Parallel to _tags: the `entry_idx` of the entry in
            that slot, or `_SLOT_EMPTY_IDX` (= -1).
        _capacity: Number of HT slots (power of 2).
        _num_groups: Number of occupied slots == next free `entry_idx`.
        _entry_stride: Bytes per entry.
        _num_keys: Number of Int64 key columns.
        _num_aggs: Number of aggregation slots per group.
        _keys_offset: Byte offset to first key within an entry (always 8).
        _aggs_offset: Byte offset to first agg slot within an entry.
    """

    var _entries: List[UInt8]
    var _entries_capacity: Int
    var _tags: List[UInt64]
    var _slot_to_idx: List[Int32]
    var _capacity: Int
    var _num_groups: Int
    var _entry_stride: Int
    var _num_keys: Int
    var _num_aggs: Int
    var _keys_offset: Int
    var _aggs_offset: Int
    var _resize_threshold: Int  # Precomputed: capacity * LOAD_FACTOR_NUM / LOAD_FACTOR_DEN
    var _layout: AggLayout
    var _keys: Slab[UInt8]
    var _agg_slabs: Slab[Slab[UInt8]]

    def __init__(out self, num_keys: Int, num_aggs: Int, initial_capacity: Int = 1024):
        """Create a new FlatHashAggregator.

        Args:
            num_keys: Number of Int64 group-by key columns.
            num_aggs: Number of aggregation expressions per group.
            initial_capacity: Initial hash table capacity (rounded up to power of 2).
                Pass `0` to build a DEFERRED-ALLOCATION aggregator whose
                `_entries` / `_tags` buffers are empty Lists. Callers must
                then invoke `_worker_first_touch(target_cap)` on the worker
                thread that will OWN this aggregator before any
                `find_or_create_*` call, so the buffers are allocated (and
                later freed) by the thread that grows them.
        """
        self._num_keys = num_keys
        self._num_aggs = num_aggs
        self._keys_offset = _HASH_BYTES
        self._aggs_offset = _HASH_BYTES + num_keys * 8
        self._layout = AggLayout.default_quartet(num_aggs)
        self._entry_stride = self._aggs_offset + self._layout.total_width
        self._num_groups = 0

        if initial_capacity <= 0:
            self._capacity = 0
            self._resize_threshold = 0
            self._entries = List[UInt8]()
            self._entries_capacity = 0
            self._tags = List[UInt64]()
            self._slot_to_idx = List[Int32]()
            self._keys = Slab[UInt8]()
            self._agg_slabs = Slab[Slab[UInt8]]()
            return

        var cap = 1
        while cap < initial_capacity:
            cap *= 2

        self._capacity = cap
        self._resize_threshold = cap * _LOAD_FACTOR_NUM // _LOAD_FACTOR_DEN

        self._entries = List[UInt8]()
        self._entries_capacity = 0
        self._tags = List[UInt64](capacity=cap)
        self._tags.resize(unsafe_uninit_length=cap)
        unsafe_memset(self._tags.unsafe_ptr().bitcast[UInt8](), 0, cap * 8)
        self._slot_to_idx = List[Int32](capacity=cap)
        self._slot_to_idx.resize(unsafe_uninit_length=cap)
        unsafe_memset(self._slot_to_idx.unsafe_ptr().bitcast[UInt8](), 0xFF, cap * 4)
        self._keys = Slab[UInt8]()
        self._agg_slabs = Slab[Slab[UInt8]]()


    @staticmethod
    def with_layout(
        num_keys: Int,
        var layout: AggLayout,
        initial_capacity: Int = 1024,
    ) -> FlatHashAggregator:
        """Build a FlatHashAggregator whose slot widths follow `layout`.

        Args:
            num_keys: Number of Int64 group-by key columns.
            layout: Per-slot width tags + offsets; consumed (moved).
            initial_capacity: Initial HT capacity (rounded up to pow2).

        Returns:
            A new FlatHashAggregator wired with the caller's layout.
        """
        var agg = FlatHashAggregator(
            num_keys=num_keys,
            num_aggs=layout.num_aggs,
            initial_capacity=initial_capacity,
        )
        var new_stride = agg._aggs_offset + layout.total_width
        if new_stride != agg._entry_stride:
            if agg._entries_capacity > 0:
                agg._entries = List[UInt8]()
                agg._entries_capacity = 0
            agg._entry_stride = new_stride
        agg._layout = layout^
        return agg^

    def _worker_first_touch(mut self, target_cap: Int):
        """Idempotent worker-thread lazy initialization of `_entries` / `_tags`.

        First call allocates the HT buffers at `next_pow2(target_cap)`
        (minimum 16 slots). Subsequent calls on the same aggregator
        no-op. Must be called on the worker thread that will own the
        aggregator's consume loop.
        """
        from .flat_hash_agg_dispatch import _worker_first_touch_impl
        _worker_first_touch_impl(self, target_cap)

    # -------------------------------------------------------------------------
    # Accessors (inline for hot-path use)
    # -------------------------------------------------------------------------

    @always_inline
    def num_groups(self) -> Int:
        return self._num_groups

    @always_inline
    def num_keys(self) -> Int:
        return self._num_keys

    @always_inline
    def num_aggs(self) -> Int:
        return self._num_aggs

    @always_inline
    def capacity(self) -> Int:
        """Number of HT slots (power of 2)."""
        return self._capacity

    @always_inline
    def entries_capacity(self) -> Int:
        """Number of entry slots currently allocated in `_entries`.

        The first growth allocates at least `_ENTRY_BLOCK_SIZE` (8192)
        entries.
        """
        return self._entries_capacity

    @always_inline
    def entry_stride(self) -> Int:
        """Bytes per entry (hash + keys + agg slots).

        Every FlatHashPartitionFlush for this aggregator must be
        constructed with this exact stride so row bytes round-trip
        byte-for-byte.
        """
        return self._entry_stride

    # -------------------------------------------------------------------------
    # Abandon cycle: clear_for_reuse + flush_to_partitions
    # -------------------------------------------------------------------------

    # PERF-CRITICAL: clear_for_reuse MUST NOT free _tags, _slot_to_idx or
    # _entries: the backing storage stays L2-resident across abandon cycles,
    # so the next round probes into the same cache-warm memory.
    def clear_for_reuse(mut self):
        """Reset the table to empty WITHOUT freeing backing storage.

        Zeroes `_tags` (every slot marked empty via the 0 sentinel) and
        resets `_num_groups` to zero. `_slot_to_idx` is NOT cleared (the
        probe path reads it only when `_tags[slot] != 0`). `_entries`
        capacity is left intact; the next round overwrites the front of
        the buffer as `_num_groups` increments from zero.
        """
        if self._capacity > 0:
            unsafe_memset(self._tags_mut_ptr().bitcast[UInt8](), 0, self._capacity * 8)
        self._num_groups = 0

    # PERF-CRITICAL: called each time a worker's table reaches its
    # L2-resident cap. The partition index is
    # `Int((mixed_hash >> shift) & (num_partitions - 1))` from the stored
    # mixed hash (NOT re-hashed from the key).
    def flush_to_partitions(
        self,
        mut flushes: Slab[FlatHashPartitionFlush],
        first: Int,
        num_partitions: Int,
        shift: UInt32,
    ) raises:
        """Scatter every live entry into
        `flushes[first .. first + num_partitions]`.

        Raises when `num_partitions` exceeds 256 or the slab holds fewer
        than `first + num_partitions` buffers.
        """
        _scatter_flush(
            self._tags_mut_ptr(),
            self._slot_to_idx_mut_ptr(),
            self._entries_mut_ptr(),
            self._capacity,
            self._entry_stride,
            flushes,
            first,
            num_partitions,
            shift,
        )

    # =========================================================================
    # Field pointers
    # =========================================================================
    # Each accessor returns the base pointer of one buffer field with that
    # field's origin: mutable when the receiver is borrowed mutably,
    # immutable otherwise. A writer therefore takes `mut self` (or a `mut`
    # aggregator argument).

    @always_inline
    def _tags_mut_ptr(ref self) -> UnsafePointer[UInt64, origin_of(self._tags)]:
        # SAFETY: the base of `_tags`, valid until `_tags` is replaced
        # (`_resize` / `pre_grow`, which take `mut self`).
        return self._tags.unsafe_ptr()

    @always_inline
    def _slot_to_idx_mut_ptr(
        ref self,
    ) -> UnsafePointer[Int32, origin_of(self._slot_to_idx)]:
        # SAFETY: as `_tags_mut_ptr`.
        return self._slot_to_idx.unsafe_ptr()

    @always_inline
    def _entries_mut_ptr(ref self) -> UnsafePointer[UInt8, origin_of(self._entries)]:
        """Pointer to the base of the insertion-order entry buffer.

        Stable until the next `_grow_entries_capacity` call.
        """
        # SAFETY: the base of `_entries`, valid until it grows.
        return self._entries.unsafe_ptr()

    @always_inline
    def _entry_ptr_by_idx(
        ref self, entry_idx: Int
    ) -> UnsafePointer[UInt8, origin_of(self._entries)]:
        """Pointer to the start of the entry at insertion-order index
        `entry_idx`."""
        return self._entries_mut_ptr() + entry_idx * self._entry_stride

    @always_inline
    def _entry_ptr(
        ref self, slot: Int
    ) -> UnsafePointer[UInt8, origin_of(self._entries)]:
        """Pointer to the start of the entry occupying HT slot `slot`.

        Two loads: `_slot_to_idx[slot]`, then the entry. CONTRACT: the
        caller has verified `_tags[slot] != 0`; on an empty slot the
        index is -1 and the pointer is out of range.
        """
        var entry_idx = Int((self._slot_to_idx_mut_ptr() + slot)[])
        return self._entry_ptr_by_idx(entry_idx)

    @always_inline
    def _tag_at(self, slot: Int) -> UInt64:
        """Read the tag (hash) for a slot from the compact tag array.

        PERF-CRITICAL: reads `_tags` (8B stride), not `_entries`.
        """
        return (self._tags_mut_ptr() + slot)[]

    @always_inline
    def _set_tag(mut self, slot: Int, h: UInt64):
        """Write the tag (hash) for a slot in the compact tag array."""
        (self._tags_mut_ptr() + slot)[] = h

    # Claim a new entry for an empty slot: take `entry_idx = _num_groups`,
    # grow `_entries` if it is full, write `_slot_to_idx[slot] = entry_idx`
    # and return the entry's pointer. The caller writes the tag, the hash,
    # keys and initial agg state, then bumps `_num_groups` (which stays the
    # live count). The entry bytes are not initialized here; the caller's
    # `_init_all_agg_slots` writes every accumulator byte before any read.
    def _claim_new_entry_for_slot(
        mut self, slot: Int
    ) -> UnsafePointer[UInt8, origin_of(self._entries)]:
        """Allocate a new entry index for an empty slot, growing the entry
        storage if needed. Returns the pointer to the new entry's storage.
        """
        var entry_idx = self._num_groups
        if entry_idx >= self._entries_capacity:
            self._grow_entries_capacity()
        (self._slot_to_idx_mut_ptr() + slot)[] = Int32(entry_idx)
        return self._entry_ptr_by_idx(entry_idx)

    def _grow_entries_capacity(mut self):
        """Double `_entries_capacity` (or allocate the initial block).

        Called from `_claim_new_entry_for_slot` when the next insertion
        would exceed the current allocation.
        """
        var new_cap = self._entries_capacity * 2
        if new_cap < _ENTRY_BLOCK_SIZE:
            new_cap = _ENTRY_BLOCK_SIZE
        var new_byte_len = new_cap * self._entry_stride
        var old_byte_len = self._num_groups * self._entry_stride
        # List.resize copies the live bytes to the new allocation; the
        # grown tail is zeroed so a fresh entry's init starts from zero.
        self._entries.resize(unsafe_uninit_length=new_byte_len)
        var tail_ptr = self._entries.unsafe_ptr() + old_byte_len
        unsafe_memset(tail_ptr, 0, new_byte_len - old_byte_len)
        self._entries_capacity = new_cap

    # The entry-pointer helpers below are static: a call that passed the
    # aggregator together with a mutable pointer into its own entry buffer
    # would alias (the exclusivity check rejects it).

    @staticmethod
    @always_inline
    def _hash_at[
        o_entry: Origin
    ](entry: UnsafePointer[UInt8, o_entry]) -> UInt64:
        """Read the hash value from an entry's data buffer.

        For probing, prefer `_tag_at(slot)`, which is more cache-friendly.
        """
        return entry.bitcast[UInt64]()[]

    @staticmethod
    @always_inline
    def _set_hash[
        o_entry: Origin[mut=True]
    ](entry: UnsafePointer[UInt8, o_entry], h: UInt64):
        """Write the hash value to an entry's data buffer."""
        entry.bitcast[UInt64]()[] = h

    @always_inline
    def _tag_ptr_for_prefetch(
        ref self, slot: Int
    ) -> UnsafePointer[UInt64, origin_of(self._tags)]:
        """Pointer into `_tags` for software prefetch.

        PERF-CRITICAL: prefetch this rather than `_entry_ptr(slot)`; the tag
        array has an 8B stride against the entry buffer's 48B and more.
        """
        return self._tags_mut_ptr() + slot

    @staticmethod
    @always_inline
    def _key_ptr[
        o_entry: Origin
    ](entry: UnsafePointer[UInt8, o_entry]) -> UnsafePointer[Int64, o_entry]:
        """Pointer to the first key in an entry (the keys follow the hash,
        at `_HASH_BYTES`, which is every aggregator's `_keys_offset`)."""
        return (entry + _HASH_BYTES).bitcast[Int64]()

    @always_inline
    def _agg_off(self, agg_idx: Int) -> Int:
        """Byte offset of agg slot `agg_idx` within an entry
        (`_aggs_offset + _layout.offsets[agg_idx]`). Writers add it to an
        entry pointer rather than calling `_agg_ptr`, which would pass the
        aggregator together with a pointer into its own buffer."""
        return self._aggs_offset + self._layout.offsets[agg_idx]

    @always_inline
    def _agg_ptr[
        o_entry: Origin
    ](self, entry: UnsafePointer[UInt8, o_entry], agg_idx: Int) -> UnsafePointer[UInt8, o_entry]:
        """Pointer to the start of agg slot agg_idx within an entry.

        PERF-CRITICAL: layout-aware offset from `self._layout.offsets`, so
        narrow-layout queries (ACC_SUM_COUNT_F64: 16B per slot) read and
        write at the right byte offsets. `_layout.offsets` is an
        `InlineArray[Int, MAX_AGGS]`: stack-backed and move-stable.
        """
        return entry + self._agg_off(agg_idx)

    # -------------------------------------------------------------------------
    # Key comparison
    # -------------------------------------------------------------------------

    @staticmethod
    @always_inline
    def _keys_match_1[
        o_entry: Origin
    ](entry: UnsafePointer[UInt8, o_entry], k0: Int64) -> Bool:
        """Fast path: compare 1 key."""
        return FlatHashAggregator._key_ptr(entry)[] == k0

    @staticmethod
    @always_inline
    def _keys_match_2[
        o_entry: Origin
    ](entry: UnsafePointer[UInt8, o_entry], k0: Int64, k1: Int64) -> Bool:
        """Fast path: compare 2 keys."""
        var kp = FlatHashAggregator._key_ptr(entry)
        return kp[] == k0 and (kp + 1)[] == k1

    @staticmethod
    @always_inline
    def _keys_match_n[
        o_entry: Origin, o_keys: Origin
    ](entry: UnsafePointer[UInt8, o_entry], keys: UnsafePointer[Int64, o_keys], n: Int) -> Bool:
        """General: compare N keys."""
        var kp = FlatHashAggregator._key_ptr(entry)
        var _i = 0
        var _eq = True
        while _i < n:
            if (kp + _i)[] != (keys + _i)[]:
                _eq = False
                break
            _i += 1
        # WIDTH IS IN BYTES on purpose: this loop steps Int64 WORDS, so the
        # memcmp-eligibility question is about `n * 8`, not `n`. Reporting `n`
        # would put every multi-key agg in the sub-16-byte regression bucket.
        keyeq_record(KEYEQ_FLATHASH_KEYS_N, n * 8, _i * 8, _eq)
        return _eq

    # -------------------------------------------------------------------------
    # Accumulator helpers: the bodies are in flat_hash_agg_accumulator.mojo
    # (a new entry's slots are initialized there by `_init_all_agg_slots_impl`,
    # which takes the layout rather than the aggregator).
    # -------------------------------------------------------------------------

    @always_inline
    def _update_agg(mut self, entry: EntryHandle, agg_idx: Int, value: Float64):
        """Update sum/count/min/max for one agg slot."""
        from .flat_hash_agg_accumulator import _update_agg_impl
        _update_agg_impl(self, entry, agg_idx, value)

    @always_inline
    def _merge_quartet_prehashed(
        mut self,
        entry: EntryHandle,
        agg_idx: Int,
        sum_in: Float64,
        count_in: Int,
        min_in: Float64,
        max_in: Float64,
    ):
        """Merge one pre-aggregated quartet (sum/count/min/max) into the
        slot at `agg_idx` (the spill-restore primitive).

        On a fresh entry (count == 0) the slot's identity values are
        replaced with the inputs; on an existing entry they are folded by
        per-op semantics (sum: add, count: add, min: min, max: max).
        ASSUMES the quartet layout (`ACC_SUM_COUNT_MIN_MAX_F64`).
        """
        from .flat_hash_agg_accumulator import _merge_quartet_prehashed_impl
        _merge_quartet_prehashed_impl(self, entry, agg_idx, sum_in, count_in, min_in, max_in)

    @always_inline
    def _update_count_only(mut self, entry: EntryHandle, agg_idx: Int):
        """Increment only the count for COUNT(*) agg."""
        from .flat_hash_agg_accumulator import _update_count_only_impl
        _update_count_only_impl(self, entry, agg_idx)

    # PERF-CRITICAL: bulk add for the COUNT(*) ungrouped fast path: one
    # `count += n` write instead of n per-row updates.
    @always_inline
    def _add_count_bulk(mut self, entry: EntryHandle, agg_idx: Int, n: Int):
        """Add `n` to the count slot in one shot (COUNT(*) fast path)."""
        from .flat_hash_agg_accumulator import _add_count_bulk_impl
        _add_count_bulk_impl(self, entry, agg_idx, n)

    @always_inline
    def get_sum(self, entry: EntryHandle, agg_idx: Int) -> Float64:
        """Read sum from an agg slot."""
        from .flat_hash_agg_accumulator import _get_sum_impl
        return _get_sum_impl(self, entry, agg_idx)

    @always_inline
    def get_count(self, entry: EntryHandle, agg_idx: Int) -> Int:
        """Read count from an agg slot."""
        from .flat_hash_agg_accumulator import _get_count_impl
        return _get_count_impl(self, entry, agg_idx)

    @always_inline
    def get_min(self, entry: EntryHandle, agg_idx: Int) -> Float64:
        """Read min from an agg slot."""
        from .flat_hash_agg_accumulator import _get_min_impl
        return _get_min_impl(self, entry, agg_idx)

    @always_inline
    def get_max(self, entry: EntryHandle, agg_idx: Int) -> Float64:
        """Read max from an agg slot."""
        from .flat_hash_agg_accumulator import _get_max_impl
        return _get_max_impl(self, entry, agg_idx)

    @always_inline
    def get_avg(self, entry: EntryHandle, agg_idx: Int) -> Float64:
        """Compute average from an agg slot."""
        from .flat_hash_agg_accumulator import _get_avg_impl
        return _get_avg_impl(self, entry, agg_idx)

    @always_inline
    def get_key(self, entry: EntryHandle, key_idx: Int) -> Int64:
        """Read a key value from an entry (resolved by entry index, one
        load)."""
        return (
            FlatHashAggregator._key_ptr(self._entry_ptr_by_idx(Int(entry._entry_idx)))
            + key_idx
        )[]

    # -------------------------------------------------------------------------
    # Pre-grow / resize: the bulk-grow and rehash loops are in
    # flat_hash_agg_dispatch.mojo.
    # -------------------------------------------------------------------------

    def ensure_merge_capacity(mut self, additional_groups: Int):
        """Pre-reserve HT slots for a bulk merge of `additional_groups`
        more groups. Idempotent: a target at or below current capacity is
        a no-op.
        """
        from .flat_hash_agg_dispatch import _ensure_merge_capacity_impl
        _ensure_merge_capacity_impl(self, additional_groups)

    def pre_grow(mut self, target_groups: Int):
        """Pre-reserve capacity for an absolute target group count.

        Equivalent to `ensure_merge_capacity(target_groups - num_groups())`
        when `target_groups` exceeds current num_groups; no-op otherwise.
        """
        from .flat_hash_agg_dispatch import _pre_grow_impl
        _pre_grow_impl(self, target_groups)

    def _pre_grow_to(mut self, target_groups: Int):
        """Shared worker for ensure_merge_capacity / pre_grow."""
        from .flat_hash_agg_dispatch import _pre_grow_to_impl
        _pre_grow_to_impl(self, target_groups)

    def _resize(mut self):
        """Double capacity and rehash all entries."""
        from .flat_hash_agg_dispatch import _resize_impl
        _resize_impl(self)

    # -------------------------------------------------------------------------
    # find_or_create_*: the probe loops are in flat_hash_agg_probe.mojo.
    # -------------------------------------------------------------------------

    @always_inline
    def find_or_create_1(mut self, key: Int64) -> EntryHandle:
        """Find or create an entry for a single Int64 key.

        Returns an EntryHandle; the caller updates accumulators with
        `_update_agg(handle, ...)`, so a multi-agg query probes ONCE and
        updates N agg slots.

        CRITICAL: the returned handle is invalidated by `_resize()`. Do not
        call find_or_create again before finishing all updates to this
        entry.
        """
        from .flat_hash_agg_probe import _find_or_create_1_impl
        return _find_or_create_1_impl(self, key)

    @always_inline
    def find_or_create_1_prehashed(mut self, key: Int64, h: UInt64) -> EntryHandle:
        """Find or create an entry using a pre-computed hash.

        Same as find_or_create_1 but skips hash computation. Used by
        radix-partitioned aggregation, which computes the hash once for
        both partition selection and table lookup.

        Args:
            key: The Int64 key value.
            h: Pre-computed hash (must be non-zero, as guaranteed by _fib_hash_1).

        Returns:
            EntryHandle for the entry. Invalidated by `_resize()`.
        """
        from .flat_hash_agg_probe import _find_or_create_1_prehashed_impl
        return _find_or_create_1_prehashed_impl(self, key, h)

    @always_inline
    def find_or_create_2(mut self, k0: Int64, k1: Int64) -> EntryHandle:
        """Find or create an entry for two Int64 keys. Uses `_fib_hash_2`,
        which is bit-identical to `_fib_hash_n(&[k0,k1], 2)`, so entries
        inserted here interoperate with the N-key paths."""
        from .flat_hash_agg_probe import _find_or_create_2_impl
        return _find_or_create_2_impl(self, k0, k1)

    @always_inline
    def find_or_create_2_prehashed(mut self, k0: Int64, k1: Int64, h: UInt64) -> EntryHandle:
        """Find or create an entry for two Int64 keys using a pre-computed hash.

        Args:
            k0: First key value.
            k1: Second key value.
            h: Pre-computed hash (must be non-zero).

        Returns:
            EntryHandle for the entry. Invalidated by `_resize()`.
        """
        from .flat_hash_agg_probe import _find_or_create_2_prehashed_impl
        return _find_or_create_2_prehashed_impl(self, k0, k1, h)

    def _find_or_create_n[key_origin: Origin](mut self, keys: UnsafePointer[Int64, key_origin], num_keys: Int) -> EntryHandle:
        """Find or create an entry for N Int64 keys.

        Args:
            keys: Pointer to num_keys consecutive Int64 values.
            num_keys: Number of keys (must match self._num_keys).
        """
        from .flat_hash_agg_probe import _find_or_create_n_impl
        return _find_or_create_n_impl(self, keys, num_keys)

    def _find_or_create_n_prehashed[key_origin: Origin](mut self, keys: UnsafePointer[Int64, key_origin], num_keys: Int, h: UInt64) -> EntryHandle:
        """Find or create an entry for N Int64 keys using a pre-computed hash.

        Args:
            keys: Pointer to num_keys consecutive Int64 values.
            num_keys: Number of keys (must match self._num_keys).
            h: Pre-computed hash (must be non-zero).

        Returns:
            EntryHandle for the entry. Invalidated by `_resize()`.
        """
        from .flat_hash_agg_probe import _find_or_create_n_prehashed_impl
        return _find_or_create_n_prehashed_impl(self, keys, num_keys, h)

    # -------------------------------------------------------------------------
    # Iteration over occupied entries
    # -------------------------------------------------------------------------

    def iter_entries(self) -> List[EntryHandle]:
        """Return a list of handles for all occupied entries.

        Used for result extraction. The handles stay valid while the
        aggregator is alive and no `_resize` / rehash fires.
        """
        from .flat_hash_agg_dispatch import _iter_entries_impl
        return _iter_entries_impl(self)

    # -------------------------------------------------------------------------
    # Batch insert with prefetch (for high-cardinality aggregation)
    # -------------------------------------------------------------------------

    def batch_find_or_create_1[
        o_keys: Origin, o_out: Origin[mut=True]
    ](
        mut self,
        keys: Span[Int64, o_keys],
        out_entries: Span[EntryHandle, o_out],
    ):
        """Batch find-or-create for single-key aggregation with prefetch.

        Processes rows in groups of 8: computes the hashes and target slots,
        prefetches those slots, then probes each row. This hides L3 latency
        when the table exceeds L2 (>100K groups).

        Args:
            keys: One Int64 key per row.
            out_entries: Receives one EntryHandle per row; must hold at
                least `len(keys)` handles.
        """
        debug_assert(
            len(out_entries) >= len(keys),
            "batch_find_or_create_1: out_entries is shorter than keys",
        )
        from .flat_hash_agg_probe import _batch_find_or_create_1_impl
        _batch_find_or_create_1_impl(
            self, keys.unsafe_ptr(), len(keys), out_entries.unsafe_ptr()
        )

    # -------------------------------------------------------------------------
    # Merge (for parallel aggregation: merge per-worker tables into one)
    # -------------------------------------------------------------------------

    def merge(mut self, other: FlatHashAggregator):
        """Merge another FlatHashAggregator into this one.

        For each occupied entry in `other`, finds or creates the group in
        `self` and combines the accumulators (sum: add, count: add, min:
        min, max: max), in two passes with prefetch.

        Args:
            other: The aggregator to merge from (read-only).
        """
        from .flat_hash_agg_dispatch import _merge_impl
        _merge_impl(self, other)

    # PERF-CRITICAL: re-inserts rows that the abandon cycle scattered into
    # FlatHashPartitionFlush buffers. A flushed row has the layout of an
    # entry: hash at offset 0, keys at `_keys_offset`, agg slots at
    # `_aggs_offset`.
    def merge_flushed_row[
        o_row: Origin
    ](
        mut self,
        row: Span[UInt8, o_row],
    ):
        """Re-insert a flushed entry row (hash + keys + aggs, exactly
        `entry_stride()` bytes): find-or-create on the key portion, then
        merge the accumulator state like `merge`.
        """
        debug_assert(
            len(row) >= self._entry_stride,
            "merge_flushed_row: row is shorter than the entry stride",
        )
        from .flat_hash_agg_accumulator import _merge_flushed_row_impl
        _merge_flushed_row_impl(self, row.unsafe_ptr())

    @always_inline
    def _merge_one_entry(
        mut self,
        other: FlatHashAggregator,
        other_entry: EntryHandle,
    ):
        """Merge a single occupied entry from another aggregator into self.

        `other` is passed explicitly so the entry pointer is resolved
        against the owning aggregator's origin.
        """
        from .flat_hash_agg_accumulator import _merge_one_entry_impl
        _merge_one_entry_impl(self, other, other_entry)

    # =========================================================================
    # Per-row probe and commit for the sinks
    # =========================================================================

    @always_inline
    def probe_or_insert_row(
        mut self,
        hash: UInt64,
        key: Int64,
    ) -> EntryHandle:
        """Per-row probe-or-insert for a single Int64 key.

        Forwards to the `find_or_create_1_prehashed` body.

        Args:
            hash: Pre-computed hash (must be non-zero per `_fib_hash_1`).
            key: Single-Int64 group-by key. Multi-key shapes use
                `find_or_create_2_prehashed` / `_find_or_create_n_prehashed`.

        Returns:
            EntryHandle for the entry. Invalidated by `_resize()`.
        """
        from .flat_hash_agg_probe import _find_or_create_1_prehashed_impl
        return _find_or_create_1_prehashed_impl(self, key, hash)

    @always_inline
    def commit_row[
        plan_origin: ImmOrigin, batch_origin: ImmOrigin
    ](
        mut self,
        ref [plan_origin] commit_plan: AggCommitPlan[batch_origin],
        handle: EntryHandle,
        row: Int,
    ):
        """Per-row commit: fold row `row` of the plan's batch into the
        entry `handle` names. Forwards to
        `commit_plan.commit_row(self, handle, row)`; `@always_inline`
        collapses the shim at the call site.

        Args:
            commit_plan: Borrowed AggCommitPlan; layout-bound by the caller
                via `bind_layout(agg._layout, agg._aggs_offset)` BEFORE
                the per-row loop.
            handle: EntryHandle from `probe_or_insert_row` (or a batched probe).
            row: Per-batch row index.
        """
        commit_plan.commit_row(self, handle, row)
