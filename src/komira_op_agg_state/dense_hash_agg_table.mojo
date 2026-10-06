# =============================================================================
# dense_hash_agg_table.mojo — Dense, growing single-I64-key directory
#   (DENSE-HASH-AGG Phase 1 per an internal doc)
# =============================================================================
#
# The Phase-1 fix for the `MAX_GROUPS=16` silent-saturation correctness bug
# (`hash_agg_table.mojo:54`). Replaces the fixed-16 InlineArray probe with a
# single growing dense open-addressing directory, built as the single-I64-key
# sibling of `_CompositeHashTableF64` (`composite_hash_table.mojo`).
#
# This module owns the value-type-AGNOSTIC half: the salt-packed directory,
# the Knuth-multiplicative hash, the salt-derived odd-stride probe, the dense
# key column, and grow+rehash-directory-only. The four public single-key agg
# tables (`HashAggTableF64/I64/I32/F32` in `hash_agg_table.mojo`) each OWN a
# `_DenseAggDirectory` plus their own typed `List[AggOp.StateTy]` side array
# (indexed by the dense `group_id`), and supply the value-typed
# update/finalize. The directory mechanics are written ONCE here.
#
# RFC decisions realized (§ refs into an internal doc):
#   - §2.2 directory = ONE packed word (salt | group_id), one cache line per
#     probe hit; scalar salt-compare gate before the key fetch.
#   - §2.1 salt-derived odd-stride probe (SaltIncrementAndWrap), not bare +1.
#   - §2.3 Knuth-multiplicative hash for the single-I64 key (multiply-mix).
#   - §2.4 group_id indirection: directory carries (salt | group_id); the key
#     column + (caller-owned) agg state are dense, indexed by group_id, and
#     NEVER move on resize -> group_id is stable for the table lifetime
#     (§7.4 index-stability invariant). group_id is table-local (Phase-2
#     per-partition forward-compat).
#   - §3 initial capacity 2048, ~0.67 load (grow when n_groups > cap*2/3),
#     power-of-2 + mask, geometric doubling, rehash directory-only off the
#     dense cached_hash side array.
#
# Encapsulation invariants:
#   - Storage = `List[UInt64]` / `List[Int64]` POD (RFC §7.1) — NOT
#     MmapAlignedBuffer (wildcard-origin gap6 hazard). gap6-clean by construction.
#   - NO `UnsafePointer` in any public method signature; no wildcard origins.
#   - `Movable` only (no ArcPointer — single-owner; RFC §7.7).
#   - Owned directly by the caller's table (which is owned by the
#     BreakerState / Stage.state, NOT byte-slab) so heap-owning Lists are
#     gap6-safe (RFC §7.3).
#
# Memory ceiling (RFC §7.6): this table is unbounded-in-RAM and WILL OOM above
# some group cardinality — there is NO spill in Phase 1 (spill depends on
# Phase-2 radix partitioning). `reserve_memory` is the no-op seam a future
# memory manager wires into without an API change.
# =============================================================================


# =============================================================================
# §1 — Constants
# =============================================================================

comptime DENSE_INITIAL_CAPACITY: Int = 2048
"""Initial directory slot count (RFC §3 — covers TPC-H Q1's 4 groups, h1's
~100, and the medium-card cases with no resize). Power-of-2; 16 KB directory."""

comptime _EMPTY_SLOT: UInt64 = 0
"""Empty-slot sentinel: salt==0 AND group_id==0. A real group_id of 0 carries
a nonzero salt, so it is distinguishable from empty (RFC §2.2)."""

comptime _SALT_SHIFT: Int = 48
"""group_id occupies bits [47:0]; salt occupies bits [63:48]."""

comptime _GROUP_ID_MASK: UInt64 = (UInt64(1) << 48) - 1
"""Low-48-bit mask to extract group_id from a packed directory word."""

comptime _DENSE_PRESIZE_MAX_SLOTS: Int = 1 << 21
"""LEVER CDP ceiling on `_DenseAggDirectory.new_presized`: 2,097,152 slots =
16 MiB of directory. A pre-size hint is an UPPER bound on distinct cardinality
(callers pass the input VALUE count), so an all-duplicates input would otherwise
allocate a directory proportional to the row count. The clamp bounds that waste;
a table whose true cardinality exceeds the clamp simply grows the old way from
here. Sized well above the radix dedup's cache-resident partition target
(`_CD_RADIX_TARGET_PART_VALUES` / `_CD_GROUPED_TARGET_CELL_VALUES` = 65536), so
the intended callers never reach it."""


@always_inline
def _hash_key_int64(key: Int64) -> UInt64:
    """Knuth multiplicative mix for a single Int64 key (RFC §2.3).

    Multiply-mix (NOT XOR-fold) — avalanches a single integer well. The
    directory salt and slot are extracted from this 64-bit mixed hash.
    """
    # 0x9E3779B97F4A7C15 = 2^64 / golden ratio (Knuth multiplicative constant).
    var h = UInt64(Scalar[DType.int64](key).cast[DType.uint64]())
    h = h * 0x9E3779B97F4A7C15
    # A second mix stage (xorshift on the high bits) to spread entropy into
    # the low slot bits as well as the high salt bits.
    h = h ^ (h >> 29)
    h = h * 0xBF58476D1CE4E5B9
    h = h ^ (h >> 32)
    return h


@always_inline
def _salt_of(h: UInt64) -> UInt64:
    """High-16-bit salt, forced nonzero so it never collides with the empty
    sentinel (RFC §2.2 — `| 1` into the top bit if the high 16 are all-zero)."""
    var s = h >> UInt64(_SALT_SHIFT)
    # Force nonzero: an all-zero high-16 would make a real word look empty.
    return s | (UInt64(1) << 15)


@always_inline
def _salt_stride(salt: UInt64, mask: UInt64) -> UInt64:
    """Odd probe stride derived from the salt (RFC §2.1 SaltIncrementAndWrap).

    An ODD stride is coprime with the power-of-2 capacity, so the probe visits
    every slot before repeating. `| 1` guarantees odd. Confined to the
    capacity by `& mask` then re-forced odd so it never degenerates to 0.
    """
    var stride = (salt & mask) | 1
    return stride


# =============================================================================
# §2 — _DenseAggDirectory — value-type-agnostic salt-packed directory
# =============================================================================
#
# Owns the open-addressing directory + the dense single-I64 key column +
# the dense cached_hash side array. `lookup_or_insert(key) -> group_id`
# returns a dense, stable group_id (0..n_groups). Grow+rehash touches ONLY
# the directory (re-probed off cached_hash); the dense key column is never
# moved -> group_id stability (RFC §7.4).
#
# The caller's agg-state side array (`List[AggOp.StateTy]`) is grown in
# lockstep via the `inserted_new` return signal from `lookup_or_insert` (the
# caller appends a fresh state when group_id == old n_groups). This keeps the
# state type off the directory (no byte-erase, RFC §5.2) while keeping the
# directory logic written once.
# =============================================================================


@fieldwise_init
struct _DenseAggDirectory(Copyable, Movable):
    """Salt-packed open-addressing directory for a single Int64 key.

    Storage (RFC §2.2 / §7.1 — all `List[POD]`, gap6-clean):
      - directory:   List[UInt64]  one packed (salt | group_id) word per slot.
      - keys:        List[Int64]   dense key column, indexed by group_id.
      - cached_hash: List[UInt64]  full 64-bit hash per group (resize re-probe).
      - capacity:    Int           power-of-2 directory slot count.
      - n_groups:    Int           number of distinct groups (== dense length).
    """

    var directory: List[UInt64]
    var keys: List[Int64]
    var cached_hash: List[UInt64]
    var capacity: Int
    var n_groups: Int

    @staticmethod
    def new(initial_capacity: Int = DENSE_INITIAL_CAPACITY) -> _DenseAggDirectory:
        """Construct an empty directory with at-least `initial_capacity` slots
        (rounded up to power-of-2). The directory is sentinel-filled; the dense
        side arrays start empty and grow with n_groups."""
        var cap = 1
        while cap < initial_capacity:
            cap = cap * 2

        var dir = List[UInt64](capacity=cap)
        for _ in range(cap):
            dir.append(_EMPTY_SLOT)

        return _DenseAggDirectory(
            directory=dir^,
            keys=List[Int64](),
            cached_hash=List[UInt64](),
            capacity=cap,
            n_groups=0,
        )

    @staticmethod
    def new_presized(n_expected: Int) -> _DenseAggDirectory:
        """LEVER CDP — construct a directory already large enough to hold
        `n_expected` groups WITHOUT ever crossing the ~0.67 grow threshold,
        plus dense side arrays reserved to the same bound.

        WHY (the cost this removes). `new()` always starts at
        `DENSE_INITIAL_CAPACITY` (2048) and reaches its working size by
        geometric doubling. Every doubling in `_grow` (a) allocates + sentinel-
        fills a directory twice the previous size and (b) RE-PROBES every
        live group off `cached_hash` into it. Growing from 2048 to C slots
        therefore performs ~C extra slot writes AND ~n_groups extra random
        directory probes summed over the doublings — for an open-addressing
        table that ends at C slots the rehash work is ~1x the useful insert
        work, i.e. the table does roughly 2x the probes it needs. On top of
        that `keys` / `cached_hash` pay their own `List` doubling reallocs.
        Starting at the right size does ZERO of that.

        RESULT IS IDENTICAL. Neither the returned dense `group_id`s nor
        `size()` nor the insertion-ordered `keys` depend on the directory
        capacity: `lookup_or_insert` assigns `group_id = n_groups` on every
        miss in probe-arrival order, and the dense key column is append-only
        and never moved (RFC §7.4 index stability). Capacity changes only
        WHICH slot a group lands in — an internal detail no caller observes.
        `new_presized(n)` for any `n <= 0` is byte-for-byte
        `new(DENSE_INITIAL_CAPACITY)` (same capacity, same empty side arrays),
        which is what makes the OFF arm of the caller-side gate identical to
        the pre-lever path.

        BOUND. The requested slot count is clamped to
        `_DENSE_PRESIZE_MAX_SLOTS` so a hint far larger than the true distinct
        cardinality cannot balloon RSS; above the clamp the table simply grows
        the old way from the clamped floor. The dense-array reserve is likewise
        clamped to the directory's own load bound.

        Args:
            n_expected: expected number of DISTINCT keys (an upper bound is
                fine — e.g. the input value count). `<= 0` means "no hint".
        """
        # need capacity*2/3 > n_expected  =>  capacity > 1.5 * n_expected.
        var want = DENSE_INITIAL_CAPACITY
        if n_expected > 0:
            var need = n_expected + (n_expected >> 1) + 1
            if need > want:
                want = need
            if want > _DENSE_PRESIZE_MAX_SLOTS:
                want = _DENSE_PRESIZE_MAX_SLOTS

        var cap = 1
        while cap < want:
            cap = cap * 2

        var dir = List[UInt64](capacity=cap)
        for _ in range(cap):
            dir.append(_EMPTY_SLOT)

        # Dense side arrays: reserve to the directory's own load bound so the
        # append-driven `List` doubling reallocs never fire either.
        var dense_hint = n_expected
        var dense_bound = (cap * 2) // 3
        if dense_hint > dense_bound:
            dense_hint = dense_bound
        var keys = List[Int64]()
        var chash = List[UInt64]()
        if dense_hint > 0:
            keys.reserve(dense_hint)
            chash.reserve(dense_hint)

        return _DenseAggDirectory(
            directory=dir^,
            keys=keys^,
            cached_hash=chash^,
            capacity=cap,
            n_groups=0,
        )

    @always_inline
    def size(self) -> Int:
        """Number of distinct groups (dense side-array length)."""
        return self.n_groups

    @always_inline
    def capacity_of(self) -> Int:
        """Directory slot count (power-of-2)."""
        return self.capacity

    @always_inline
    def key_at(self, group_id: Int) -> Int64:
        """Reconstruct the key for a dense group_id (0..n_groups)."""
        return self.keys[group_id]

    def audit_displacement(self) -> Int:
        """DIAGNOSTIC (read-only, O(n_groups * mean displacement)).

        Sum, over every live group, of the number of EXTRA stride steps
        between that group's HOME slot (`hash & mask`) and the slot it
        actually occupies. `1 + audit_displacement() / n_groups` is therefore
        the mean number of DIRECTORY SLOT LOADS a steady-state lookup of a
        present key performs — the exact quantity that prices an `insert`
        against a `List.append`'s single sequential store, COUNTED rather
        than estimated from a load-factor formula.

        Not on any hot path. Uses the same `_salt_of` / `_salt_stride` /
        packed-word spelling as `lookup_or_insert`, so it walks the identical
        probe sequence; `(salt << _SALT_SHIFT) | group_id` is unique per
        group, so the walk stops on the exact slot, not on a salt alias.
        """
        var mask = UInt64(self.capacity - 1)
        var total = 0
        for g in range(self.n_groups):
            var h = self.cached_hash[g]
            var salt = _salt_of(h)
            var stride = _salt_stride(salt, mask)
            var packed = (salt << UInt64(_SALT_SHIFT)) | UInt64(g)
            var slot = h & mask
            var steps = 0
            while self.directory[Int(slot)] != packed:
                slot = (slot + stride) & mask
                steps += 1
                if steps > self.capacity:
                    # Unreachable for a consistent directory; bail rather than
                    # spin if the diagnostic ever meets a corrupted table.
                    break
            total += steps
        return total

    @always_inline
    def reset(mut self):
        """Clear the directory + truncate the dense side arrays for re-use."""
        for i in range(self.capacity):
            self.directory[i] = _EMPTY_SLOT
        self.keys.clear()
        self.cached_hash.clear()
        self.n_groups = 0

    @always_inline
    def _insert_into_directory(
        mut self, slot_start: Int, salt: UInt64, group_id: Int
    ):
        """Probe from `slot_start` with the salt-stride; write the packed word
        into the first empty directory slot. Used by both insert and rehash.
        """
        var mask = UInt64(self.capacity - 1)
        var stride = _salt_stride(salt, mask)
        var slot = UInt64(slot_start) & mask
        var packed = (salt << UInt64(_SALT_SHIFT)) | UInt64(group_id)
        while True:
            if self.directory[Int(slot)] == _EMPTY_SLOT:
                self.directory[Int(slot)] = packed
                return
            slot = (slot + stride) & mask

    def _grow(mut self):
        """Double the directory capacity + rehash directory-only off the dense
        `cached_hash` side array (RFC §3). The dense key column is NEVER moved,
        so every group_id stays stable (§7.4)."""
        var new_cap = self.capacity * 2
        var new_dir = List[UInt64](capacity=new_cap)
        for _ in range(new_cap):
            new_dir.append(_EMPTY_SLOT)
        # Swap in the larger directory, then re-probe each group's cached hash.
        self.directory = new_dir^
        self.capacity = new_cap
        var mask = UInt64(new_cap - 1)
        for g in range(self.n_groups):
            var h = self.cached_hash[g]
            var salt = _salt_of(h)
            var slot_start = Int(h & mask)
            self._insert_into_directory(slot_start, salt, g)

    @always_inline
    def lookup_or_insert(mut self, key: Int64) -> Int:
        """Find the dense group_id for `key`, inserting it if not present.

        Returns a dense `group_id` in `0..n_groups` (strictly-larger,
        compatible superset of the old 0..15 slot domain). On insert the key +
        cached_hash dense arrays are extended; the caller grows its parallel
        agg-state array in lockstep (group_id == the prior n_groups on insert).

        Probe (RFC §2.2):
          1. salt-compare gate (scalar, no key fetch) on each occupied slot;
          2. fetch the key only on salt match; advance by the odd salt-stride.
        """
        # Grow BEFORE insert if we are at the ~0.67 load threshold so the new
        # group lands in the larger directory (RFC §3: grow when
        # n_groups > capacity * 2 / 3).
        if self.n_groups >= (self.capacity * 2) // 3:
            self._grow()

        var h = _hash_key_int64(key)
        var salt = _salt_of(h)
        var mask = UInt64(self.capacity - 1)
        var stride = _salt_stride(salt, mask)
        var slot = h & mask
        while True:
            var word = self.directory[Int(slot)]
            if word == _EMPTY_SLOT:
                # Insert: assign the next dense group_id, extend dense arrays,
                # write the packed directory word.
                var group_id = self.n_groups
                self.keys.append(key)
                self.cached_hash.append(h)
                self.n_groups = self.n_groups + 1
                self.directory[Int(slot)] = (salt << UInt64(_SALT_SHIFT)) | UInt64(
                    group_id
                )
                return group_id
            # Salt-compare gate before the key fetch (the bulk of the win).
            if (word >> UInt64(_SALT_SHIFT)) == salt:
                var group_id = Int(word & _GROUP_ID_MASK)
                if self.keys[group_id] == key:
                    return group_id
            slot = (slot + stride) & mask


# =============================================================================
# §3 — reserve_memory seam (RFC §7.6 — no-op in Phase 1)
# =============================================================================


@always_inline
def dense_reserve_memory(bytes: Int) -> Bool:
    """Memory-reservation hook seam (RFC §7.6). Phase 1 ships it as a no-op
    returning True so a future memory manager can be wired in without an API
    change. The Phase-1 dense table is unbounded-in-RAM and WILL OOM above some
    group cardinality — there is no spill until Phase 2 (radix partitioning)."""
    return True
