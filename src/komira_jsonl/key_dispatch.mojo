# =============================================================================
# key_dispatch.mojo — schema-key → column-index lookup for Stage 2 walker
# =============================================================================
#
# The Stage 2 columnar materializer (`columnar_materializer.mojo`)
# walks Stage 1's structural-token tape and for each key it reads from the
# input, asks "which column does this key correspond to?". This module
# implements that lookup.
#
# Two implementations:
#
#   1. `KeyTable.memcmp_cascade` — linear cmp loop over a small key list
#      (K < 8). One scan; for each key, byte-by-byte compare. Cheap to build,
#      tiny memory footprint, wins for K < 8 (~3-7 fields is typical in
#      twitter.json shape).
#
#   2. **`KeyTable.hash_open_addressing`** —
#      FNV-1a 64-bit hash on the key bytes indexes into a power-of-2 open-
#      addressing table; collisions resolve via linear probe + length+memcmp
#      tiebreak. O(1) average per lookup. Wins at K >= 8 (a 16-column file
#      resolves 16 keys per row, which a cascade makes a large share of the
#      read wall).
#
# Selection rule: built automatically inside `KeyTable.from_field_names` —
# the cascade is preserved for K < `_HASH_THRESHOLD` (8), the hash table
# kicks in at K >= 8. Callers see a single uniform `lookup(key_bytes)` API.
#
# The hash table is built ONCE at table construction (cost: O(K)), then
# every per-row lookup is O(1) on average (single FNV-1a pass over the key
# bytes + 1 expected probe). Memory: 4× capacity × 8 bytes per slot stored
# as a UInt64 hash + UInt32 index packed-pair list (one cache line for K=16
# at capacity=32 = 256 bytes; comfortably fits L1).
#
# `lookup_or_insert_bytes`: a Span-keyed insert-or-lookup that the
# inferrer uses directly on its hot path, with no String allocation and no
# cascade walk per key.
#
# Encapsulation discipline:
#   - Public surface accepts `Span[UInt8, _]` (origin-poly view) + owned
#     `List[String]` for key inventories. No `UnsafePointer` in any
#     signature.
#   - Internal hash buckets stored as flat List[UInt64] + List[Int32] (no
#     pointer arithmetic; standard List ops).
#   - Internal byte-compare is a simple Python-shape loop over `Span`
#     indexing; no raw pointer arithmetic.
#
# Return convention:
#   `lookup(key_bytes) -> Int` returns the matching column index in
#   `[0, K)`. Returns `-1` for "key not in schema" — Stage 2's
#   skip-value routine consumes such a value without writing anywhere
#   (unknown keys are skipped).
# =============================================================================

# Hash-table activation threshold. K < this value uses the cmp cascade; K
# >= this value builds the open-addressing hash table. 8 is empirically
# the crossover point on a typical 4-7-char field-name distribution: at
# K=4 the cascade does ~2 cmp on average (good); at K=16 the cascade does
# ~8 cmp on average (bad). The hash table is ~constant cost (1.0-1.5
# probes) and pays for its build cost (~16 FNV passes + 16 slot writes)
# in <100 row lookups.
comptime _HASH_THRESHOLD: Int = 8

# Empty slot sentinel for the hash table's _bucket_to_idx list. Slot is
# empty IFF the stored value equals this sentinel. The on-disk valid
# column index range is [0, num_columns()), so any negative sentinel works;
# we use -1 to match the absent-key return convention of `lookup`.
comptime _EMPTY_BUCKET: Int32 = -1


@always_inline
def _fnv1a_64(bytes: Span[UInt8, _]) -> UInt64:
    """FNV-1a 64-bit hash over `bytes`. ~1.0 byte/cycle scalar throughput;
    the hot loop is short (typical JSON key 3-12 bytes) so SIMD speedup is
    minimal — keep scalar for codegen simplicity. Reference: Fowler/Noll/Vo
    1991, http://www.isthe.com/chongo/tech/comp/fnv/.

    FNV-1a was chosen over xxhash because:
      1. Tiny state (one UInt64) — no allocation, no SIMD ramp-up cost.
      2. Excellent dispersion for short ASCII keys (the JSON-key
         distribution).
      3. ~1.0 byte/cycle on Apple silicon — fast enough that the lookup
         total is dominated by the table probe, not the hash itself.
    """
    var h: UInt64 = UInt64(14695981039346656037)  # FNV offset basis
    var n = len(bytes)
    for i in range(n):
        h = h ^ UInt64(Int(bytes[i]))
        h = h * UInt64(1099511628211)             # FNV prime
    return h


@fieldwise_init
struct KeyTable(Copyable, Movable):
    """Schema-key → column-index lookup table.

    Built once from the schema field names; consulted O(1) per Stage 2
    key-read at K >= 8 (open-addressing hash), O(K) at K < 8 (cmp cascade).

    Fields:
        keys: ordered list of schema field names; index `i` maps to
              column index `i`. Owned (stable byte storage across the
              lifetime of the materializer/inferrer).
        _bucket_hashes: parallel list of FNV-1a hashes for occupied
              buckets (only meaningful when _use_hash=True). Length is
              `_bucket_cap` (a power of 2 >= 2*K).
        _bucket_to_idx: parallel list of column indices for occupied
              buckets. Empty slot = _EMPTY_BUCKET (-1). Length is
              `_bucket_cap`.
        _bucket_cap: capacity of the hash table (power of 2). 0 when
              cascade-mode (K < _HASH_THRESHOLD).
        _bucket_mask: `_bucket_cap - 1` precomputed for bit-masked
              modulo. 0 in cascade mode.
        _use_hash: True iff the hash arm is active.

    For K < 8 the cmp-cascade is faster than a hash hop (K is usually
    5-7 for real documents). For K >= 8 the hash arm wins (about 17% of
    read wall on a 16-column file, against the cascade).
    """

    var keys: List[String]
    var _bucket_hashes: List[UInt64]
    var _bucket_to_idx: List[Int32]
    var _bucket_cap: Int
    var _bucket_mask: Int
    var _use_hash: Bool

    @staticmethod
    def from_field_names(var field_names: List[String]) -> KeyTable:
        """Build a KeyTable from a schema's field names. Consumes the list.

        At K >= _HASH_THRESHOLD (8), builds an open-addressing hash table.
        Capacity = next power of 2 >= 2 * K (so load factor at build time
        is <0.5; collisions are rare). Hash builds via FNV-1a over each
        field name's bytes.
        """
        var k = len(field_names)
        if k < _HASH_THRESHOLD:
            # Cascade arm — no hash table.
            return KeyTable(
                keys=field_names^,
                _bucket_hashes=List[UInt64](),
                _bucket_to_idx=List[Int32](),
                _bucket_cap=0,
                _bucket_mask=0,
                _use_hash=False,
            )
        # Hash arm — capacity = next pow2 >= 2*K.
        var cap: Int = 1
        var min_cap = 2 * k
        while cap < min_cap:
            cap = cap * 2
        var mask = cap - 1
        var hashes = List[UInt64](capacity=cap)
        var slots = List[Int32](capacity=cap)
        for _ in range(cap):
            hashes.append(UInt64(0))
            slots.append(_EMPTY_BUCKET)
        # Populate buckets from field_names.
        for i in range(k):
            var name_bytes = field_names[i].as_bytes()
            var h = _fnv1a_64(name_bytes)
            var slot = Int(h) & mask
            # Linear probe to next empty slot.
            while slots[slot] != _EMPTY_BUCKET:
                slot = (slot + 1) & mask
            hashes[slot] = h
            slots[slot] = Int32(i)
        return KeyTable(
            keys=field_names^,
            _bucket_hashes=hashes^,
            _bucket_to_idx=slots^,
            _bucket_cap=cap,
            _bucket_mask=mask,
            _use_hash=True,
        )

    @always_inline
    def size(self) -> Int:
        return len(self.keys)

    def lookup(self, key_bytes: Span[UInt8, _]) -> Int:
        """Return the column index for `key_bytes`, or -1 if not in the schema.

        At K >= 8: O(1) FNV-1a hash + open-addressing probe.
        At K < 8:  O(K) byte-by-byte cmp cascade across `self.keys`.

        No case-folding, no unicode normalization — JSON keys are
        case-sensitive byte sequences per RFC 8259.
        """
        if self._use_hash:
            return self._lookup_hash(key_bytes)
        # Cascade fallback (K < 8).
        var n_keys = len(self.keys)
        var kn = len(key_bytes)
        for i in range(n_keys):
            var kb = self.keys[i].as_bytes()
            var n = len(kb)
            if n != kn:
                continue
            var matches = True
            for j in range(n):
                if kb[j] != key_bytes[j]:
                    matches = False
                    break
            if matches:
                return i
        return -1

    @always_inline
    def _lookup_hash(self, key_bytes: Span[UInt8, _]) -> Int:
        """Open-addressing hash lookup. Linear probe to first empty slot;
        on hash match, length+memcmp tiebreak against the stored key."""
        var h = _fnv1a_64(key_bytes)
        var mask = self._bucket_mask
        var slot = Int(h) & mask
        var kn = len(key_bytes)
        while True:
            var idx = self._bucket_to_idx[slot]
            if idx == _EMPTY_BUCKET:
                return -1
            if self._bucket_hashes[slot] == h:
                # Tiebreak: length + memcmp.
                var kb = self.keys[Int(idx)].as_bytes()
                if len(kb) == kn:
                    var matches = True
                    for j in range(kn):
                        if kb[j] != key_bytes[j]:
                            matches = False
                            break
                    if matches:
                        return Int(idx)
            slot = (slot + 1) & mask


# =============================================================================
# Builder — schema-inferrer-side dynamic-K key registry
# =============================================================================
#
# The schema inferrer doesn't know its key set up-front: it walks records
# and learns first-seen keys on the fly. Constructing a String key per
# call and linear-scanning `String ==` against the in-flight registry
# makes key lookup the largest read hotspot. This builder does the job on
# Span[UInt8] directly, with a hash table that grows as keys are inserted.
#
# Cost model: each insert is amortized O(1) (rehash doubles capacity
# every time load factor hits 0.5). Each lookup-hit is O(1) average
# (single FNV-1a + 1.0-1.5 probes). At 16 keys × 6M records = 96M
# lookups, build cost is negligible.
#
# Output: after the inferrer's walk, `into_key_table()` converts the
# builder into a KeyTable that the materializer consumes directly. The
# hash table is rebuilt (the builder's growth-tracking shape is different
# from the static KeyTable's shape; the rebuild is one O(K) pass).


struct KeyRegistryBuilder(Movable):
    """Dynamic-K key registry for the schema inferrer.

    Walks records, looking up keys by byte-span; inserts on first-seen.
    Returns the assigned column index for each key. The full key set is
    extracted later via `into_keys()` (consumes self).

    Internal shape: parallel List[UInt64] (hashes) + List[Int32] (column
    indices into `self._names`). Power-of-2 capacity; grows by 2× when
    load factor reaches 0.5.

    NOT for materializer hot-path use — that's `KeyTable`. This is
    inference-side only (insertion-heavy).
    """

    var _names: List[String]
    var _bucket_hashes: List[UInt64]
    var _bucket_to_idx: List[Int32]
    var _bucket_cap: Int
    var _bucket_mask: Int
    var _occupied: Int

    def __init__(out self):
        """Empty registry with capacity 16 (handles up to 8 keys without
        rehash — covers >99% of real JSON shapes without growing)."""
        self._names = List[String]()
        self._bucket_cap = 16
        self._bucket_mask = 15
        self._bucket_hashes = List[UInt64](capacity=16)
        self._bucket_to_idx = List[Int32](capacity=16)
        for _ in range(16):
            self._bucket_hashes.append(UInt64(0))
            self._bucket_to_idx.append(_EMPTY_BUCKET)
        self._occupied = 0

    def lookup_or_insert_bytes(
        mut self, key_bytes: Span[UInt8, _]
    ) -> Int:
        """Look up `key_bytes` in the registry; if absent, insert with a
        fresh column index. Returns the (existing or new) index.

        No String allocation on the lookup hit path — the FNV-1a hash is
        computed directly over the byte span. String allocation only
        happens on insert (we materialize a String from the bytes to own
        them in `_names`).
        """
        var h = _fnv1a_64(key_bytes)
        var mask = self._bucket_mask
        var slot = Int(h) & mask
        var kn = len(key_bytes)
        while True:
            var idx = self._bucket_to_idx[slot]
            if idx == _EMPTY_BUCKET:
                # Empty slot — insert here.
                var new_idx = len(self._names)
                # Materialize the bytes to an owned String.
                self._names.append(
                    String(unsafe_from_utf8=key_bytes)
                )
                self._bucket_hashes[slot] = h
                self._bucket_to_idx[slot] = Int32(new_idx)
                self._occupied = self._occupied + 1
                # Rehash if load factor > 0.5.
                if self._occupied * 2 > self._bucket_cap:
                    self._rehash(self._bucket_cap * 2)
                return new_idx
            if self._bucket_hashes[slot] == h:
                # Tiebreak: length + memcmp.
                var kb = self._names[Int(idx)].as_bytes()
                if len(kb) == kn:
                    var matches = True
                    for j in range(kn):
                        if kb[j] != key_bytes[j]:
                            matches = False
                            break
                    if matches:
                        return Int(idx)
            slot = (slot + 1) & mask

    def lookup_or_insert_owned(mut self, var key: String) -> Int:
        """Convenience overload when the caller already has an owned
        String. Used by `_merge_partial_into` in the parallel-inferrer
        merge step.
        """
        var key_bytes = key.as_bytes()
        var h = _fnv1a_64(key_bytes)
        var mask = self._bucket_mask
        var slot = Int(h) & mask
        var kn = len(key_bytes)
        while True:
            var idx = self._bucket_to_idx[slot]
            if idx == _EMPTY_BUCKET:
                var new_idx = len(self._names)
                self._names.append(key^)
                self._bucket_hashes[slot] = h
                self._bucket_to_idx[slot] = Int32(new_idx)
                self._occupied = self._occupied + 1
                if self._occupied * 2 > self._bucket_cap:
                    self._rehash(self._bucket_cap * 2)
                return new_idx
            if self._bucket_hashes[slot] == h:
                var kb = self._names[Int(idx)].as_bytes()
                if len(kb) == kn:
                    var matches = True
                    for j in range(kn):
                        if kb[j] != key_bytes[j]:
                            matches = False
                            break
                    if matches:
                        return Int(idx)
            slot = (slot + 1) & mask

    @always_inline
    def size(self) -> Int:
        """Number of distinct keys inserted so far."""
        return len(self._names)

    def name_at(self, idx: Int) -> String:
        """Return a COPY of the name at column index `idx`. For diagnostic
        message construction in the inferrer (e.g. heterogeneous-type
        error messages)."""
        return self._names[idx].copy()

    def into_names(var self) -> List[String]:
        """Consume self, return the ordered list of column names. Used at
        end-of-inference to feed into `SchemaBuilder`.

        Uses stdlib `swap` to extract the owned `_names` List without
        partial-move-via-take-pointee. The
        replaced empty List is what self's destructor sees on drop."""
        from std.builtin.swap import swap
        var out = List[String]()
        swap(self._names, out)
        return out^

    def _rehash(mut self, new_cap: Int):
        """Grow the bucket array to `new_cap` (must be a power of 2) and
        re-insert every occupied slot. Amortized O(K)."""
        var new_mask = new_cap - 1
        var new_hashes = List[UInt64](capacity=new_cap)
        var new_slots = List[Int32](capacity=new_cap)
        for _ in range(new_cap):
            new_hashes.append(UInt64(0))
            new_slots.append(_EMPTY_BUCKET)
        # Walk old buckets, re-insert occupied ones into new table.
        var old_cap = self._bucket_cap
        for i in range(old_cap):
            var idx = self._bucket_to_idx[i]
            if idx == _EMPTY_BUCKET:
                continue
            var h = self._bucket_hashes[i]
            var slot = Int(h) & new_mask
            while new_slots[slot] != _EMPTY_BUCKET:
                slot = (slot + 1) & new_mask
            new_hashes[slot] = h
            new_slots[slot] = idx
        self._bucket_hashes = new_hashes^
        self._bucket_to_idx = new_slots^
        self._bucket_cap = new_cap
        self._bucket_mask = new_mask
