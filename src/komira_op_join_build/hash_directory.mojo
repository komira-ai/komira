# =============================================================================
# hash_directory -- the packed open-addressing directory of the engine's
# untyped hash tables (join build, grouped aggregation, DISTINCT)
# =============================================================================
#
# Open addressing with linear probe; a 16-bit salt fingerprint and a 32-bit
# slot index per bucket, packed into ONE 8-byte word; amortised doubling at
# load factor 0.5. Same shape as DuckDB's `ht_entry_t`. The directory maps a
# hash to a SLOT of the owner's `ColumnFormatStorage`; the owner keeps the keys
# and rehashes from them (or from stored hashes) when the directory doubles.
#
# Encapsulation: `_entries` is a private `OwnedAlignedBuffer` under typed
# accessors; `SLOT_EMPTY` (-1) is encoded as 0xFFFFFFFF. No pointer crosses
# the public surface; the two entry views below are `ByteView`s.
# =============================================================================

from std.sys.intrinsics import prefetch, PrefetchOptions

from komira_buffer.byte_view import ByteView
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer


# Sentinel: bucket is empty.
comptime SLOT_EMPTY: Int32 = -1


comptime _ENTRY_EMPTY: UInt64 = 0x0000_0000_FFFF_FFFF
"""PROBE-PACK: the packed empty-bucket sentinel.

Low 32 bits = `SLOT_EMPTY` (0xFFFFFFFF); salt bits (48..63) = 0. Identical
semantics to the old pair (`slots[b] == -1`, `salts[b] == 0`) — the salt of an
empty bucket is never read, because every probe tests the slot first and
short-circuits.

⛔ **DO NOT MOVE THIS SENTINEL TO ZERO. IT WAS TRIED, AND IT IS A MEASURED
NET LOSS.** an earlier change (ZEROEMPTY) re-encoded the low half as a
slot CODE — `slot + 1`, with 0 meaning EMPTY — so that `__init__` and
`reset_doubled` could clear with ONE `memset` instead of a scalar 8-byte-store
loop. It was reverted after a FOUR-ARM factorial measured on
the benchmark host, `[A R F T T F R A] x 3`, K=6/arm, all
84 corpus cells, 2016/2016 `VALUE_IDENTICAL`:

  * **The `+ 1` / `- 1` costs the PROBE.** It adds one DEPENDENT ALU op to the
    address chain `cand -> cand * stride -> load key`, and that costs wall
    exactly where the chain is NOT already stalled on memory — i.e. on the
    L1-resident directories that grouped aggregation actually builds (64
    partitions x N workers, so most directories are KB-scale, not MB-scale).
    Corpus-wide the encode alone (arm A - arm F, both clearing with one
    `memset`) is **+38.5 ms**.
  * **The `memset` clear buys NOTHING.** Holding the encode fixed and moving
    only the clear (arm F - arm R) is **+3.7 ms, sign MIXED 2/3 blocks** — a
    null, and if anything the wrong way, because a `memset` CALL per directory
    loses to an inlinable store loop on a 512-byte directory and there are
    ~1,280 of those per query. On `hc/hc1` the scalar loop executes **+1.19 G
    MORE instructions** and **FEWER cycles**: the clear is fault- and
    memory-bound, so deleting its stores does not delete its time. The
    commit's own caveat ("this re-times faults, it does not delete them") is
    correct and is the reason there was no win to collect — page-fault counts
    are identical across all three arms to within 1%.
  * **Whole commit, corpus-wide: A - R = +47.9 ms**, with **8 DISJOINT-LOSS
    cells against 1 trivial DISJOINT-WIN**, and every one of the 8 is a
    GROUP-BY or a HASH-JOIN — the operators that touch this struct — while no
    scan, sort or window moved. Reverting also recovers **2 FAIL->PASS**
    (`clickbench/cb12_age_sex_groupby`, `tpch/q4_order_priority`) with zero
    PASS->FAIL.
  * **There was no compensating win at large directory sizes.** On
    `hc1`/`hc2`/`hc3` the whole-commit contrast is -9.24 ms against a
    byte-identical-twin floor of 27.90 ms on the same three cells, and the
    twin reproduces the sign — i.e. inside the noise, not a win.

If a future change wants the vector clear anyway, it does NOT need the
sentinel to move: `memset(ptr, 0xFF, n)` writes an all-0xFF word whose low 32
bits are already `SLOT_EMPTY`, and the salt half of an untouched bucket is
never read. That variant IS arm F above, and it was measured — it is the
`+3.7 ms` null. So the vector clear is available at zero encoding cost and is
still not worth taking."""


struct HashDirectory(Movable, Deinitable):
    """PACKED hash directory for Column UNTYPED hash-agg / join-build /
    distinct.

    Packed layout (PROBE-PACK):
      - ONE 8-byte entry per bucket: `salt << 48 | slot`
          bits [0,32)  : 32-bit slot index (0xFFFFFFFF == SLOT_EMPTY)
          bits [48,64) : 16-bit salt fingerprint (`_salt_of`)
      - Empty bucket sentinel: the whole entry == `_ENTRY_EMPTY`
      - Linear probe on collision: bucket = (bucket + 1) & capacity_mask
      - Capacity power-of-2; grow at load factor 0.5

    WHY PACKED, AND WHAT IT IS COPIED FROM. This was an SoA pair (a 4-byte
    `_slots` array and a 2-byte `_salts` array) and EVERY probe step read BOTH,
    at the same bucket index, from two arrays that are never adjacent in memory:
    two loads on two cache lines per step.

    DuckDB's `ht_entry_t` (`src/include/duckdb/execution/ht_entry.hpp`) packs the
    salt into the upper 16 bits of the same 8-byte word as the pointer, so their
    probe step is ONE load on ONE line. On a directory that has left L2 — which
    is every high-cardinality group-by in the corpus — the SoA pair doubles the
    probe's cache-line traffic for no benefit: the two fields are ALWAYS read
    together and are never scanned independently.

    Cost of the pack: 8 bytes per bucket instead of 6, i.e. +33% directory bytes
    against a 2x cut in lines touched per probe step. Which of those wins is a
    MEASUREMENT, not an argument — see the A/B this landed with.

    BYTE-IDENTICAL by construction: probe order, mask, `_salt_of`, slot values
    and insert order are all unchanged. Only the physical placement of the two
    fields moved.

    Encapsulation: `_entries` is a private OwnedAlignedBuffer under typed
    read/write accessors. No pointer in any public signature.
    """

    # Single-owner heap storage. PROBE-PACK merged the `_salts` + `_slots`
    # pair into ONE `_entries` buffer; the accessor surface (`read_slot_at` /
    # `read_salt_at` / `set_slot_at` / `insert_raw` / `next_bucket` /
    # `bucket_of` / `prefetch_for_hash`) did not change.
    var _entries: OwnedAlignedBuffer
    """One 8-byte packed entry per bucket: `salt << 48 | slot`."""

    var capacity_mask: Int
    """Capacity - 1 (power-of-2)."""

    var n_used: Int
    """Current number of occupied buckets."""

    var grow_threshold: Int
    """`n_used` > this -> grow (= capacity / 2)."""

    def __init__(out self, initial_capacity: Int) raises:
        """Build a HashDirectory with `initial_capacity` buckets.

        Args:
            initial_capacity: Initial bucket count. Rounded up to a
                power of 2; minimum 16.
        """
        var cap = 16
        while cap < initial_capacity:
            cap = cap * 2

        # PROBE-PACK: ONE 8-byte entry per bucket.
        self._entries = OwnedAlignedBuffer(cap * 8)
        # Mark all buckets empty: slot = 0xFFFFFFFF, salt = 0.
        for i in range(cap):
            self._entries.write_u64_le_at(i * 8, _ENTRY_EMPTY)
        self._entries.set_length(Int64(cap * 8))
        self.capacity_mask = cap - 1
        self.n_used = 0
        self.grow_threshold = cap // 2

    @always_inline
    def capacity(self) -> Int:
        """Bucket count (power-of-2)."""
        return self.capacity_mask + 1

    @staticmethod
    @always_inline
    def _salt_of(hash: UInt64) -> UInt16:
        """Derive 16-bit salt fingerprint from upper hash bits."""
        return UInt16(Int((hash >> 48) & UInt64(0xFFFF)))

    @always_inline
    def _read_slot(self, bucket: Int) raises -> Int32:
        """Read the 32-bit slot at `bucket` as signed Int32.

        SLOT_EMPTY (-1) is encoded as 0xFFFFFFFF; we read the unsigned
        wire value and detect empty via the sentinel directly.
        Other values are guaranteed in [0, 0x7FFFFFFF] by the caller's
        contract (slot indices are non-negative Int32).
        """
        var e = self._entries.read_u64_le_at(bucket * 8)
        var u = UInt32(Int(e & UInt64(0xFFFF_FFFF)))
        if u == UInt32(0xFFFFFFFF):
            return Int32(-1)
        return Int32(Int(u))

    @always_inline
    def _write_slot(mut self, bucket: Int, slot: Int32) raises:
        """Write a slot, PRESERVING the bucket's salt bits. SLOT_EMPTY encodes
        as 0xFFFFFFFF; positive slot indices encode as themselves."""
        var e = self._entries.read_u64_le_at(bucket * 8)
        var keep = e & UInt64(0xFFFF_0000_0000_0000)
        var lo: UInt64
        if Int(slot) == Int(SLOT_EMPTY):
            lo = UInt64(0xFFFF_FFFF)
        else:
            lo = UInt64(Int(slot))
        self._entries.write_u64_le_at(bucket * 8, keep | lo)

    @always_inline
    def read_salt_at(self, bucket: Int) raises -> UInt16:
        """Read the salt fingerprint at `bucket`. Caller uses this to
        verify a probe-side match candidate without re-loading.

        PROBE-PACK: this reads the SAME 8-byte word `read_slot_at` just read, so
        the second read is an L1 hit by construction — that is the whole point
        of the pack, and it is why the two accessors kept their signatures.
        """
        var e = self._entries.read_u64_le_at(bucket * 8)
        return UInt16(Int((e >> 48) & UInt64(0xFFFF)))

    @always_inline
    def read_slot_at(self, bucket: Int) raises -> Int32:
        """Read the slot index at `bucket` (-1 = SLOT_EMPTY)."""
        return self._read_slot(bucket)

    @always_inline
    def set_slot_at(mut self, bucket: Int, slot: Int32) raises:
        """Overwrite an OCCUPIED bucket's slot index in place WITHOUT
        touching the salt or `n_used`. Used by the Phase C-G.5 build-side
        chain walker to promote a freshly-allocated duplicate-key slot to
        the new chain head. Caller guarantees `bucket` is already occupied
        (its salt is unchanged and the bucket count does not move)."""
        self._write_slot(bucket, slot)

    @always_inline
    def bucket_of(self, hash: UInt64) -> Int:
        """Initial bucket for `hash` (without probing)."""
        return Int(hash) & self.capacity_mask

    @always_inline
    def prefetch_for_hash(self, hash: UInt64):
        """HASHAGG-VEC (perf spike): software-prefetch the ENTRY cache
        line at `hash`'s initial bucket, hiding the DRAM latency of a probe on a
        large (past-L2) directory. A pure read hint — OOB addresses are silently
        ignored, so no bounds check needed. Mirrors `agg_hash.mojo`'s pre-hashed
        probe-loop prefetch. Read-only (encapsulation-safe: no pointer escapes).

        PROBE-PACK: one prefetch now covers BOTH the slot and the salt, because
        they are the same word. Before the pack this hint touched only `_slots`
        and left the `_salts` load exposed — so the prefetch was, by
        construction, hiding at most half of the probe's memory latency."""
        var bucket = Int(hash) & self.capacity_mask
        # SAFETY: read-only prefetch hint over the owned `_entries` buffer; the
        # ByteView pins the borrow for the call and no pointer escapes.
        var p = self._entries.view_ro()._unsafe_ptr()
        prefetch[params = PrefetchOptions().for_read().high_locality()](
            (p + bucket * 8)
        )

    @always_inline
    def next_bucket(self, bucket: Int) -> Int:
        """Linear-probe successor."""
        return (bucket + 1) & self.capacity_mask

    def insert_raw(mut self, hash: UInt64, slot: Int32) raises -> Int:
        """Insert (`hash`, `slot`) at the first empty bucket on the
        probe chain.

        Caller is responsible for:
          1. Calling probe() FIRST if duplicates should merge.
          2. Allocating the `slot` value out-of-band (slot indexes into
             the parent `ColumnFormatStorage`).

        Note: this method does NOT grow the directory; callers that
        need amortized-doubling growth must call `would_grow_on_insert()`
        + the parent's `grow_with_rehash` first.

        Returns:
            The bucket assigned.
        """
        var salt = Self._salt_of(hash)
        var bucket = Int(hash) & self.capacity_mask
        while True:
            var s = self._read_slot(bucket)
            if Int(s) == Int(SLOT_EMPTY):
                # PROBE-PACK: salt and slot are ONE store, not two.
                self._entries.write_u64_le_at(
                    bucket * 8,
                    (UInt64(Int(salt)) << 48) | UInt64(Int(slot)),
                )
                self.n_used += 1
                return bucket
            bucket = (bucket + 1) & self.capacity_mask

    @always_inline
    def insert_at_known_empty(
        mut self, bucket: Int, hash: UInt64, slot: Int32
    ) raises:
        """`insert_raw`'s STORE, for a caller that has ALREADY walked to the
        empty bucket.

        ⭐ WHY THIS EXISTS: `insert_raw` re-walks the probe chain from
        `bucket_of(hash)`, and its callers on the combine path have JUST walked
        that same chain with the same predicate to discover the miss. The
        second walk is a duplicate — measured as ~25 instructions on every MISS
        of every source group, which on `hc/hc2` is 34.9 M misses per query
       .

        ⛔ THE PRECONDITION IS THE WHOLE CONTRACT, AND IT IS NOT "the bucket is
        free". It is: `bucket` is the FIRST empty bucket on `hash`'s chain,
        i.e. exactly the bucket `insert_raw(hash, slot)` would have chosen.
        Writing at any OTHER empty bucket produces a directory a later probe
        cannot search — the probe stops at the first empty bucket, so an entry
        placed past one is UNREACHABLE and its group silently duplicates. A
        caller may use this ONLY when it walked the chain itself, from
        `bucket_of(hash)`, stepping `next_bucket`, and stopped on
        `read_slot_at(bucket) == SLOT_EMPTY` — and only when NOTHING has
        touched the directory since.

        The `debug_assert` below catches the free-but-wrong-bucket half of that
        in a checked build; the "first on the chain" half is a property of the
        caller's loop and cannot be checked here without redoing the walk this
        function exists to avoid. That is stated rather than papered over.
        """
        debug_assert(
            Int(self._read_slot(bucket)) == Int(SLOT_EMPTY),
            "HashDirectory.insert_at_known_empty: bucket is not empty",
        )
        # PROBE-PACK: salt and slot are ONE store, not two — byte-for-byte the
        # store `insert_raw` performs once it has finished its own walk.
        self._entries.write_u64_le_at(
            bucket * 8,
            (UInt64(Int(Self._salt_of(hash))) << 48) | UInt64(Int(slot)),
        )
        self.n_used += 1

    # ─────────────────────────────────────────────────────────────────────
    # PROBEVEC — THE PACKED-ENTRY ARRAY AS A VIEW, FOR A CALLER
    # THAT HAS PROVEN ITS BLOCK CANNOT GROW.
    #
    # ⛔ THE PRECONDITION IS THE WHOLE CONTRACT AND IT IS NOT "be careful".
    # `reset_doubled` FREES `_entries` and allocates a new one, so a view taken
    # before a rehash and used after it addresses freed memory. A caller may
    # hold one of these across a region ONLY when it has proven no rehash can
    # occur inside that region — i.e. it has read `n_used` and `grow_threshold`
    # and bounded its own insert count by `grow_threshold - n_used`, and the
    # SAME argument covers `capacity_mask`, which a rehash also changes.
    #
    # ⚠ WHY A VIEW AND NOT AN ACCESSOR PAIR. `read_slot_at` / `read_salt_at`
    # are already `@always_inline` and already read ONE word (PROBE-PACK), so
    # the load is not what this removes. What it removes is the RELOAD of
    # `_entries._ptr`: the probe loop STORES (it inserts), Mojo has no
    # `noalias`, and LLVM therefore cannot keep the base in a register across
    # an iteration — the mechanism `combine_key_plan.mojo`'s header records
    # from disassembly for `col_buffers`. Handing the base out as a VALUE is
    # the only thing that removes it.
    #
    # ⚠ `ByteView`, NOT `UnsafePointer`. The view is the safe origin-tied slice
    # type (the pointer rules's encapsulation rule: no `UnsafePointer` in a public
    # signature); it carries `_entries`'s length, so a `read_u64_le_at` on it
    # is bounds-asserted in a checked build. Byte offsets are `bucket * 8`.
    # ─────────────────────────────────────────────────────────────────────

    @always_inline
    def entries_view_ro[
        _mut: Bool, o: Origin[mut=_mut], //,
    ](ref [o] self) -> ByteView[o]:
        """PROBEVEC: the packed entry array as an immutable byte view. See the
        block above — the caller owns the no-rehash proof."""
        var v = self._entries.view_ro()
        # SAFETY: the view is re-tied from the FIELD's origin to the OWNING
        # struct's. `_entries` lives inside `self`, so `o` outlives it by
        # construction and the widening can only SHORTEN the tracked liveness,
        # never extend it past the storage. This is the identical cast
        # `OwnedAlignedBuffer.view_ro` performs on `_ptr`, one level out.
        return ByteView[o](v._unsafe_ptr().unsafe_origin_cast[o](), v.len())

    @always_inline
    def entries_view_mut[
        o: Origin[mut=True], //,
    ](ref [o] self) -> ByteView[o]:
        """PROBEVEC: the packed entry array as a MUTABLE byte view, for a
        caller inserting through `note_entry_written` below. See the block
        above — the caller owns the no-rehash proof."""
        var v = self._entries.view_mut()
        # SAFETY: as `entries_view_ro` above — a field-origin to
        # owning-struct-origin re-tie, mutable on both sides.
        return ByteView[o](v._unsafe_ptr().unsafe_origin_cast[o](), v.len())

    @always_inline
    def note_entry_written(mut self):
        """PROBEVEC: account ONE bucket a caller has just claimed by writing
        `salt << 48 | slot` through `entries_view_mut`.

        ⛔ THIS IS THE OTHER HALF OF `insert_at_known_empty` AND BOTH HALVES
        ARE MANDATORY. That function performs the store AND the `n_used` bump;
        a caller doing its own store must do its own bump, or the load factor
        under-counts, `would_grow_on_insert` stops firing, and the directory
        fills to 100% — a probe that never terminates on a full table. The
        caller's block bound is computed FROM `n_used`, so an un-bumped insert
        also silently invalidates the no-rehash proof this view rests on."""
        self.n_used += 1

    @always_inline
    def would_grow_on_insert(self) -> Bool:
        """True iff the next insert would exceed the grow threshold.
        Caller pairs this with `parent.grow_with_rehash` to grow before
        the insert."""
        return self.n_used + 1 > self.grow_threshold

    def reset_doubled(mut self) raises:
        """Discard ALL entries + double capacity. Caller is responsible
        for re-inserting (via parent's stored keys). This is the
        primitive the parent's `grow_with_rehash` builds on.
        """
        var old_cap = self.capacity()
        var new_cap = old_cap * 2

        # Re-allocate empty. PROBE-PACK: one buffer, one fill loop.
        self._entries = OwnedAlignedBuffer(new_cap * 8)
        for i in range(new_cap):
            self._entries.write_u64_le_at(i * 8, _ENTRY_EMPTY)
        self._entries.set_length(Int64(new_cap * 8))
        self.capacity_mask = new_cap - 1
        self.n_used = 0
        self.grow_threshold = new_cap // 2
