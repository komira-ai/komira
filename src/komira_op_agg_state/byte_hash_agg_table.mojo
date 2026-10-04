# =============================================================================
# byte_hash_agg_table.mojo — Byte-keyed dense growing HashAggTable family
#   (Sub-A4.1 of A.4 STRING-key AGG substrate per
#   an internal doc §6.2 Phase-4)
# =============================================================================
#
# Sibling primitive of `hash_agg_table.mojo` for STRING / Bytes keys. While
# the Int64-key family stores the dense key column as `List[Int64]`, this
# byte-keyed family stores keys as a flat byte slab (`List[UInt8]`) with
# offsets (`List[UInt32]`) so variable-width key payloads can be addressed
# via (`offset`, `length`) tuples.
#
# Backs Sub-A4.1 scope: single STRING key + single agg (SUM/COUNT/MIN/MAX),
# Float64 or Int64 agg state. Multi-agg + composite STRING are Sub-A4.2 /
# Sub-A4.3 follow-ups.
#
# Architecture mirrors `dense_hash_agg_table.mojo` exactly:
#   - `_DenseByteAggDirectory` owns the value-type-AGNOSTIC half: salt-packed
#     directory + key slab + offsets + cached_hash side array.
#   - Four typed wrappers `ByteHashAggTable{F64,I64,I32,F32}[AggOp]` each
#     OWN a `_DenseByteAggDirectory` + their own typed `List[AggOp.StateTy]`.
#   - `lookup_or_insert(Span[UInt8, ImmO])` returns a dense `group_id` in
#     `0..n_groups` — STABLE across resize (RFC §7.4).
#
# # POC anchor
#
# Mojo-expert validation at
# an internal agent note
# (GREEN verdict). The encapsulation pattern (Span-based public sig +
# `# SAFETY:`-gated internal memcmp) mirrors three live in-tree primitives:
# `byte_hashset.mojo`, `byte_join_build_table.mojo`,
# `byte_asof_join_build_table.mojo`. All three are gap6-safe by precedent —
# `List[UInt8]` / `List[UInt32]` / `List[UInt64]` storage is POD-only with
# no wildcard origins and no heap-owning Movable inner fields.
#
# # Encapsulation invariants (the internal development notes hard bans)
#
#   - NO `UnsafePointer` in any public method signature. Probe accepts
#     `Span[UInt8, ImmO]`; the internal `memcmp` is gated with `# SAFETY:`.
#   - NO wildcard origins. Concrete `Origin[mut=False]` parameter on the
#     Span-based public API; internal `unsafe_ptr()` arithmetic resolves
#     through `self.keys_data: List[UInt8]` (concrete owning origin).
#   - `List[POD]` storage only — `List[UInt8]`, `List[UInt32]`, `List[UInt64]`
#     — gap6-clean (RFC §7.1).
#   - `Movable` only (no ArcPointer; single-owner).
#   - StateTy: associated AnyType per `HashAggOp*` trait — inherited from
#     `agg_op_traits.mojo` traits.
#
# # Gap6 audit (the destroy-recreate cycle)
#
# `ByteHashAggTable*` instances live as `Optional[ByteHashAggTable*]` fields
# in `RuntimeBreakerState`. Across a `EngineContext` destroy-recreate cycle:
#   - Storage = POD numeric Lists (matches `ByteHashSet` precedent).
#   - No wildcard origins.
#   - The agg-state side array (`List[AggOp.StateTy]`) is the same shape as
#     `HashAggTableF64.slabs` — POD per RFC §7.3 for all v0.4 GA states.
#   - Drain extraction via `Optional.take()` is partial-move-clean
#     (the internal development notes hard ban #11; mojo-mcp `owned_state_destructure.mojo`).
# All three preconditions for the gap6 trap (Movable struct in byte-slab +
# wildcard origin + heap-owning inner field) are ABSENT by construction.
# =============================================================================

from std.memory import unsafe_memcmp

from komira_agg.agg_op_traits import (
    HashAggOpF32,
    HashAggOpF64,
    HashAggOpI32,
    HashAggOpI64,
)


# =============================================================================
# §1 — Constants
# =============================================================================

comptime BYTE_DENSE_INITIAL_CAPACITY: Int = 2048
"""Initial directory slot count (mirrors `DENSE_INITIAL_CAPACITY` in
`dense_hash_agg_table.mojo`). Power-of-2; 16 KB directory."""

comptime BYTE_KEY_SLAB_AVG_WIDTH: Int = 16
"""Heuristic average byte-key width for `keys_data` capacity reservation
on `new()`. The slab grows freely via List.append; this is a sizing hint."""

comptime _BYTE_EMPTY_SLOT: UInt64 = 0
"""Empty-slot sentinel: salt==0 AND group_id==0. A real group_id of 0 carries
a nonzero salt, so it is distinguishable from empty."""

comptime _BYTE_SALT_SHIFT: Int = 48
"""group_id occupies bits [47:0]; salt occupies bits [63:48]."""

comptime _BYTE_GROUP_ID_MASK: UInt64 = (UInt64(1) << 48) - 1
"""Low-48-bit mask to extract group_id from a packed directory word."""

comptime BYTE_KEY_OFFSET_MAX: Int = 0xFFFFFFFF
"""Largest END offset a `keys_offsets` entry can hold: 4_294_967_295.

⭐ VARHEAP-OFFSET-CEILING's sibling (). `keys_offsets` is a
`List[UInt32]` of cumulative END offsets into `keys_data`, whose length is a
64-bit `Int`. The append used to compute `prev_end + UInt32(key_len)` -- a
UInt32 add that WRAPS SILENTLY -- so a slab past 4 GiB recorded an end offset
BELOW its predecessor, and `_key_length` / `_key_equal_at` then named another
group's bytes. Nothing downstream could tell: the group count is right and
every read stays inside the slab. Same defect class as `ColumnFormatStorage`'s
`VAR_DESC_OFFSET_MAX` (UNSIGNED 32 bits); ⛔ NOT Arrow's signed 2**31-1.

⚠ REACHABILITY (2026-09-23): neither this table nor `ByteJoinBuildTable3I64Pay`
has a PRODUCTION caller -- `git grep` finds only their own unit tests -- so no
query has answered wrong through it. The refusal is here so that a future
caller inherits it instead of the wrap."""


@no_inline
def _raise_byte_key_offset_ceiling(prev_end: Int, key_len: Int) raises:
    """Cold: an append whose end offset would not fit `keys_offsets`."""
    raise Error(
        "byte-keyed table: key append would put the key slab's end offset"
        " at "
        + String(prev_end + key_len)
        + " bytes, past the "
        + String(BYTE_KEY_OFFSET_MAX)
        + "-byte ceiling of its 32-bit `keys_offsets` field (prev_end="
        + String(prev_end)
        + ", key_len="
        + String(key_len)
        + "). Refused rather than wrapped: a wrapped end offset would silently"
        " name ANOTHER GROUP'S BYTES."
    )


@always_inline
def byte_key_end_offset(prev_end: UInt32, key_len: Int) raises -> UInt32:
    """THE end-offset computation for one appended key: `prev_end + key_len`,
    done in 64-bit `Int` and REFUSED if it does not fit the 32-bit field.

    Called BEFORE any byte of the key is appended, so a refused insert leaves
    the table exactly as it found it. Shared with
    `byte_join_build_table_3i64pay.mojo`, whose `keys_offsets` is the same
    field with the same append -- one implementation, so the two cannot
    disagree on the ceiling."""
    var end = Int(prev_end) + key_len
    if end > BYTE_KEY_OFFSET_MAX:
        _raise_byte_key_offset_ceiling(Int(prev_end), key_len)
    return UInt32(end)


# FNV-1a 64-bit constants. Matches `composite_key.mojo:282-289`.
comptime _BYTE_FNV_OFFSET: UInt64 = 14695981039346656037
comptime _BYTE_FNV_PRIME: UInt64 = 1099511628211


# =============================================================================
# §2 — Hash + salt + stride helpers
# =============================================================================


@always_inline
def _hash_key_bytes[
    ImmO: Origin[mut=False],
](imm key: Span[UInt8, ImmO]) -> UInt64:
    """FNV-1a 64-bit hash over a byte sequence (matches `composite_key.mojo`).

    Scalar byte-by-byte fold. Phase-4+ perf lever: a SWAR or SIMD fast-path
    for ≥8-byte keys (mirror of memcmp_avx2). Correctness-first scope.
    """
    var s = _BYTE_FNV_OFFSET
    var n = len(key)
    var i = 0
    while i < n:
        s = (s ^ UInt64(key[i])) * _BYTE_FNV_PRIME
        i = i + 1
    return s


@always_inline
def _byte_salt_of(h: UInt64) -> UInt64:
    """High-16-bit salt, forced nonzero so it never collides with the empty
    sentinel."""
    var s = h >> UInt64(_BYTE_SALT_SHIFT)
    return s | (UInt64(1) << 15)


@always_inline
def _byte_salt_stride(salt: UInt64, mask: UInt64) -> UInt64:
    """Odd probe stride derived from the salt (mirror of dense_hash_agg_table)."""
    return (salt & mask) | 1


# =============================================================================
# §3 — _DenseByteAggDirectory — value-type-agnostic salt-packed directory
# =============================================================================
#
# Owns the open-addressing directory + the dense byte-key column +
# the dense cached_hash side array. `lookup_or_insert(Span[UInt8]) -> group_id`
# returns a dense, stable group_id (0..n_groups). Grow+rehash touches ONLY
# the directory (re-probed off cached_hash); the dense key slab is never
# moved -> group_id stability (RFC §7.4).
# =============================================================================


@fieldwise_init
struct _DenseByteAggDirectory(Copyable, Movable):
    """Salt-packed open-addressing directory for variable-width byte keys.

    Storage (all `List[POD]`, gap6-clean):
      - directory:    List[UInt64]  one packed (salt | group_id) word per slot.
      - keys_data:    List[UInt8]   flat byte slab (the "key heap").
      - keys_offsets: List[UInt32]  n_groups + 1 entries; group g key bytes
                                    span `keys_data[keys_offsets[g] :
                                    keys_offsets[g+1]]`.
      - cached_hash:  List[UInt64]  full 64-bit hash per group (resize re-probe).
      - capacity:     Int           power-of-2 directory slot count.
      - n_groups:     Int           number of distinct groups (== dense length).
    """

    var directory: List[UInt64]
    var keys_data: List[UInt8]
    var keys_offsets: List[UInt32]
    var cached_hash: List[UInt64]
    var capacity: Int
    var n_groups: Int

    @staticmethod
    def new(
        initial_capacity: Int = BYTE_DENSE_INITIAL_CAPACITY,
    ) -> _DenseByteAggDirectory:
        """Construct an empty directory with at-least `initial_capacity` slots
        (rounded up to power-of-2). The directory is sentinel-filled; the dense
        side arrays start empty and grow with n_groups."""
        var cap = 1
        while cap < initial_capacity:
            cap = cap * 2

        var dir = List[UInt64](capacity=cap)
        for _ in range(cap):
            dir.append(_BYTE_EMPTY_SLOT)

        var offsets = List[UInt32](capacity=initial_capacity + 1)
        offsets.append(UInt32(0))

        return _DenseByteAggDirectory(
            directory=dir^,
            keys_data=List[UInt8](
                capacity=initial_capacity * BYTE_KEY_SLAB_AVG_WIDTH
            ),
            keys_offsets=offsets^,
            cached_hash=List[UInt64](capacity=initial_capacity),
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
    def _key_offset(self, group_id: Int) -> Int:
        return Int(self.keys_offsets[group_id])

    @always_inline
    def _key_length(self, group_id: Int) -> Int:
        return Int(self.keys_offsets[group_id + 1]) - Int(
            self.keys_offsets[group_id]
        )

    def key_at(self, group_id: Int) -> List[UInt8]:
        """Return a COPY of the byte key at dense group_id (0..n_groups).

        The copy keeps the public API encapsulation-clean (no Span / origin
        gymnastics, no UnsafePointer in the surface). A future polish slot
        can swap in a borrowed-Span accessor for the drain hot path."""
        var start = self._key_offset(group_id)
        var n = self._key_length(group_id)
        var out = List[UInt8](capacity=n)
        var k = 0
        while k < n:
            out.append(self.keys_data[start + k])
            k = k + 1
        return out^

    def _key_equal_at[
        ImmO: Origin[mut=False],
    ](self, group_id: Int, imm probe: Span[UInt8, ImmO]) -> Bool:
        """Compare row group_id's stored bytes against probe bytes.

        # SAFETY: `keys_data.unsafe_ptr() + start` is in-bounds for the
        # `[start, start + n)` range — start comes from
        # `keys_offsets[group_id]`, `n = keys_offsets[group_id+1] -
        # keys_offsets[group_id]`, and `keys_offsets[n_groups]
        # == keys_data.size()` by construction. probe.unsafe_ptr() is a
        # Span-borrowed ptr; its lifetime is tracked via `ImmO`. Both ptrs
        # are READ-ONLY for the memcmp call. No realloc inside this fn.
        """
        var start = self._key_offset(group_id)
        var n = self._key_length(group_id)
        if n != len(probe):
            return False
        var slab_ptr = self.keys_data.unsafe_ptr() + start
        var probe_ptr = probe.unsafe_ptr()
        return unsafe_memcmp(slab_ptr, probe_ptr, n) == 0

    def reset(mut self):
        """Clear the directory + truncate the dense side arrays for re-use."""
        for i in range(self.capacity):
            self.directory[i] = _BYTE_EMPTY_SLOT
        self.keys_data.clear()
        self.keys_offsets.clear()
        self.keys_offsets.append(UInt32(0))
        self.cached_hash.clear()
        self.n_groups = 0

    @always_inline
    def _insert_into_directory(
        mut self, slot_start: Int, salt: UInt64, group_id: Int
    ):
        """Probe from `slot_start` with the salt-stride; write the packed word
        into the first empty directory slot. Used by both insert and rehash."""
        var mask = UInt64(self.capacity - 1)
        var stride = _byte_salt_stride(salt, mask)
        var slot = UInt64(slot_start) & mask
        var packed = (salt << UInt64(_BYTE_SALT_SHIFT)) | UInt64(group_id)
        while True:
            if self.directory[Int(slot)] == _BYTE_EMPTY_SLOT:
                self.directory[Int(slot)] = packed
                return
            slot = (slot + stride) & mask

    def _grow(mut self):
        """Double the directory capacity + rehash directory-only off the dense
        `cached_hash` side array. The dense key slab is NEVER moved, so every
        group_id stays stable (§7.4)."""
        var new_cap = self.capacity * 2
        var new_dir = List[UInt64](capacity=new_cap)
        for _ in range(new_cap):
            new_dir.append(_BYTE_EMPTY_SLOT)
        self.directory = new_dir^
        self.capacity = new_cap
        var mask = UInt64(new_cap - 1)
        for g in range(self.n_groups):
            var h = self.cached_hash[g]
            var salt = _byte_salt_of(h)
            var slot_start = Int(h & mask)
            self._insert_into_directory(slot_start, salt, g)

    def lookup_or_insert[
        ImmO: Origin[mut=False],
    ](mut self, imm key: Span[UInt8, ImmO]) raises -> Int:
        """Find the dense group_id for `key`, inserting it if not present.

        Returns a dense `group_id` in `0..n_groups`. On insert the key slab +
        keys_offsets + cached_hash arrays are extended; the caller grows its
        parallel agg-state array in lockstep (group_id == the prior n_groups
        on insert).

        Raises:
            On an insert whose key-slab END offset would pass
            `BYTE_KEY_OFFSET_MAX` -- refused before anything is appended.
        """
        # Grow BEFORE insert if at ~0.67 load threshold.
        if self.n_groups >= (self.capacity * 2) // 3:
            self._grow()

        var h = _hash_key_bytes[ImmO](key)
        var salt = _byte_salt_of(h)
        var mask = UInt64(self.capacity - 1)
        var stride = _byte_salt_stride(salt, mask)
        var slot = h & mask
        while True:
            var word = self.directory[Int(slot)]
            if word == _BYTE_EMPTY_SLOT:
                # Insert: assign next dense group_id, append key bytes,
                # extend offsets/cached_hash, write packed directory word.
                var group_id = self.n_groups
                var key_len = len(key)
                #: the end offset is computed -- and refused if it
                # does not fit its UInt32 field -- BEFORE any byte lands.
                var new_end = byte_key_end_offset(
                    self.keys_offsets[self.n_groups], key_len
                )
                var k = 0
                while k < key_len:
                    self.keys_data.append(key[k])
                    k = k + 1
                self.keys_offsets.append(new_end)
                self.cached_hash.append(h)
                self.n_groups = self.n_groups + 1
                self.directory[Int(slot)] = (
                    salt << UInt64(_BYTE_SALT_SHIFT)
                ) | UInt64(group_id)
                return group_id
            # Salt-compare gate before key fetch.
            if (word >> UInt64(_BYTE_SALT_SHIFT)) == salt:
                var group_id = Int(word & _BYTE_GROUP_ID_MASK)
                if self._key_equal_at[ImmO](group_id, key):
                    return group_id
            slot = (slot + stride) & mask


# =============================================================================
# §4 — ByteHashAggTableF64 — Float64-state byte-keyed dense hash table
# =============================================================================


struct ByteHashAggTableF64[AggOp: HashAggOpF64](Copyable, Movable):
    """Byte-keyed growing dense hash table over Float64 per-bucket state.

    Specialized for Float64 agg state (Sum/Count/Min/Max F64). Owns a
    `_DenseByteAggDirectory` (variable-width byte keys + salt-packed
    directory) plus a dense `List[StateTy]` agg-state side array indexed
    by group_id.

    The byte-key probe is scalar (per-byte FNV-1a + memcmp) — variable-width
    keys do not lane-gather, so the SIMD chunk fast-path of the Int64-key
    family (`hash_agg_table.mojo` `update_chunk[W]`) does not apply. The
    typed agg-state update is the same shape — `AggOp.update_scalar`
    monomorphizes into the per-row hot loop.
    """

    var dir: _DenseByteAggDirectory
    var slabs: List[Self.AggOp.StateTy]

    def __init__(out self):
        """Construct empty growing table at the dense initial capacity."""
        self.dir = _DenseByteAggDirectory.new(BYTE_DENSE_INITIAL_CAPACITY)
        self.slabs = List[Self.AggOp.StateTy]()

    @always_inline
    def reset(mut self):
        """Reset table for re-use (e.g. between partitions)."""
        self.dir.reset()
        self.slabs.clear()

    def lookup_or_insert[
        ImmO: Origin[mut=False],
    ](mut self, imm key: Span[UInt8, ImmO]) raises -> Int:
        """Probe-or-insert; returns the dense group_id (0..n_groups). On
        insert extends the parallel agg-state slab with `AggOp.init()`."""
        var group_id = self.dir.lookup_or_insert[ImmO](key)
        if group_id == len(self.slabs):
            self.slabs.append(Self.AggOp.init())
        return group_id

    def update_scalar[
        ImmO: Origin[mut=False],
    ](mut self, imm key: Span[UInt8, ImmO], value: Float64) raises:
        """Per-row hot path: lookup or insert group, then update slab."""
        var slot = self.lookup_or_insert[ImmO](key)
        Self.AggOp.update_scalar(self.slabs[slot], value)

    @always_inline
    def finalize_at(self, slot: Int) -> Float64:
        """Read finalized value at a dense group_id (0..size())."""
        return Self.AggOp.finalize(self.slabs[slot])

    def key_at(self, slot: Int) -> List[UInt8]:
        """Return a COPY of the byte key at dense group_id (0..size())."""
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
# §5 — ByteHashAggTableI64 — Int64-state byte-keyed dense hash table
# =============================================================================


struct ByteHashAggTableI64[AggOp: HashAggOpI64](Copyable, Movable):
    """Int64-state mirror of ByteHashAggTableF64. Same byte-keyed growing-
    dense directory, different state type (Int64 instead of Float64).

    Covers SumI64 / CountI64 / MinI64 / MaxI64 from agg_state_slab.mojo.
    """

    var dir: _DenseByteAggDirectory
    var slabs: List[Self.AggOp.StateTy]

    def __init__(out self):
        self.dir = _DenseByteAggDirectory.new(BYTE_DENSE_INITIAL_CAPACITY)
        self.slabs = List[Self.AggOp.StateTy]()

    @always_inline
    def reset(mut self):
        self.dir.reset()
        self.slabs.clear()

    def lookup_or_insert[
        ImmO: Origin[mut=False],
    ](mut self, imm key: Span[UInt8, ImmO]) raises -> Int:
        var group_id = self.dir.lookup_or_insert[ImmO](key)
        if group_id == len(self.slabs):
            self.slabs.append(Self.AggOp.init())
        return group_id

    def update_scalar[
        ImmO: Origin[mut=False],
    ](mut self, imm key: Span[UInt8, ImmO], value: Int64) raises:
        var slot = self.lookup_or_insert[ImmO](key)
        Self.AggOp.update_scalar(self.slabs[slot], value)

    @always_inline
    def finalize_at(self, slot: Int) -> Int64:
        return Self.AggOp.finalize(self.slabs[slot])

    def key_at(self, slot: Int) -> List[UInt8]:
        return self.dir.key_at(slot)

    @always_inline
    def size(self) -> Int:
        return self.dir.size()

    @always_inline
    def capacity(self) -> Int:
        return self.dir.capacity_of()


# =============================================================================
# §6 — ByteHashAggTableI32 — Int32-state byte-keyed dense hash table
# =============================================================================


struct ByteHashAggTableI32[AggOp: HashAggOpI32](Copyable, Movable):
    """Int32-value mirror of ByteHashAggTableI64. Byte keys + Int32 state."""

    var dir: _DenseByteAggDirectory
    var slabs: List[Self.AggOp.StateTy]

    def __init__(out self):
        self.dir = _DenseByteAggDirectory.new(BYTE_DENSE_INITIAL_CAPACITY)
        self.slabs = List[Self.AggOp.StateTy]()

    @always_inline
    def reset(mut self):
        self.dir.reset()
        self.slabs.clear()

    def lookup_or_insert[
        ImmO: Origin[mut=False],
    ](mut self, imm key: Span[UInt8, ImmO]) raises -> Int:
        var group_id = self.dir.lookup_or_insert[ImmO](key)
        if group_id == len(self.slabs):
            self.slabs.append(Self.AggOp.init())
        return group_id

    def update_scalar[
        ImmO: Origin[mut=False],
    ](mut self, imm key: Span[UInt8, ImmO], value: Int32) raises:
        var slot = self.lookup_or_insert[ImmO](key)
        Self.AggOp.update_scalar(self.slabs[slot], value)

    @always_inline
    def finalize_at(self, slot: Int) -> Int32:
        return Self.AggOp.finalize(self.slabs[slot])

    def key_at(self, slot: Int) -> List[UInt8]:
        return self.dir.key_at(slot)

    @always_inline
    def size(self) -> Int:
        return self.dir.size()

    @always_inline
    def capacity(self) -> Int:
        return self.dir.capacity_of()


# =============================================================================
# §7 — ByteHashAggTableF32 — Float32-state byte-keyed dense hash table
# =============================================================================


struct ByteHashAggTableF32[AggOp: HashAggOpF32](Copyable, Movable):
    """Float32-value mirror of ByteHashAggTableF64. Byte keys + Float32 state."""

    var dir: _DenseByteAggDirectory
    var slabs: List[Self.AggOp.StateTy]

    def __init__(out self):
        self.dir = _DenseByteAggDirectory.new(BYTE_DENSE_INITIAL_CAPACITY)
        self.slabs = List[Self.AggOp.StateTy]()

    @always_inline
    def reset(mut self):
        self.dir.reset()
        self.slabs.clear()

    def lookup_or_insert[
        ImmO: Origin[mut=False],
    ](mut self, imm key: Span[UInt8, ImmO]) raises -> Int:
        var group_id = self.dir.lookup_or_insert[ImmO](key)
        if group_id == len(self.slabs):
            self.slabs.append(Self.AggOp.init())
        return group_id

    def update_scalar[
        ImmO: Origin[mut=False],
    ](mut self, imm key: Span[UInt8, ImmO], value: Float32) raises:
        var slot = self.lookup_or_insert[ImmO](key)
        Self.AggOp.update_scalar(self.slabs[slot], value)

    @always_inline
    def finalize_at(self, slot: Int) -> Float32:
        return Self.AggOp.finalize(self.slabs[slot])

    def key_at(self, slot: Int) -> List[UInt8]:
        return self.dir.key_at(slot)

    @always_inline
    def size(self) -> Int:
        return self.dir.size()

    @always_inline
    def capacity(self) -> Int:
        return self.dir.capacity_of()
