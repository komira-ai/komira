# =============================================================================
# DictInterner — insertion-ordered byte-string interner for dictionary merges
# =============================================================================
#
# THE DEFECT THIS EXISTS TO REMOVE.
#
# The naive merge of the per-row-group dictionaries of a DICTIONARY column is
# a LINEAR SCAN over a `List[String]`:
#
#     for j in range(len(merged_strings)):
#         if merged_strings[j] == b_str:
#
# — assuming the merged cardinality K is "small … typically << 10^4". That
# premise is FALSE for common writers that emit a dictionary PER ROW GROUP: a
# large table carries dozens of distinct dictionaries per column, and a
# free-text column interns millions of distinct values. The scan is O(d) per
# probe inside an O(N) fold ⇒ Σ k·d² string comparisons, which for such a
# column never finishes.
#
# WHAT THIS PRIMITIVE IS
# ----------------------
# An append-only bytes arena + Int32 offsets + an open-addressing index from
# hash(bytes) -> entry ordinal. Equality is a byte-range compare against the
# arena; no `String` is ever materialized, so the merge pays neither the O(d)
# scan nor a one-heap-allocation-per-entry rebuild at every step of the fold.
#
# ⚠ INSERTION ORDER IS PART OF THE CONTRACT, NOT AN IMPLEMENTATION DETAIL.
# The merged dictionary's entry order must remain "first seen" — byte-equivalence
# oracles compare merged buffers byte-for-byte, and a hash-ordered dictionary
# would red every one of them for a semantically CORRECT merge. `seed_append` +
# `find_or_insert` below reproduce the linear fold's ordering exactly,
# duplicates included (see `seed_append`).
#
# THE PROBE COUNTER
# -----------------
# `probes()` counts every OCCUPIED SLOT EXAMINED — the honest analogue of one
# iteration of the linear scan. Call sites flush it ONCE per merge into a
# process-global counter (`dict_merge_probe_add`), so the always-on cost is one
# atomic per merge, not one per probe. That counter is what makes the falsifier
# `test_dict_concat_probe_bound` a DETERMINISTIC assertion (probes <= C·Σd)
# rather than a wall-clock threshold, which would be flaky.
# =============================================================================

from komira_atomic_alias import AtomicI64
from std.ffi import _Global
from std.memory import OwnedPointer, UnsafePointer, alloc

from komira_buffer.byte_view import ByteView


# =============================================================================
# FNV-1a over a ByteView — 8 bytes at a time, byte tail
# =============================================================================

comptime _DICT_FNV_OFFSET: UInt64 = 14695981039346656037
comptime _DICT_FNV_PRIME: UInt64 = 1099511628211


@always_inline
def _fnv1a_view(v: ByteView[_]) -> UInt64:
    """Fold `v`'s bytes into an FNV-1a-shaped 64-bit hash.

    Chunked 8-at-a-time via `read_u64_le_at` so hashing a 5.7M-entry dictionary
    is a few hundred MB/s rather than a per-byte multiply chain. The chunked and
    byte tails are folded with the same prime; the value is used ONLY as a hash
    (never persisted, never compared across processes), so the chunking is free
    to differ from canonical byte-wise FNV-1a.
    """
    var h = _DICT_FNV_OFFSET
    var n = v.len()
    var i = 0
    while i + 8 <= n:
        h = (h ^ v.read_u64_le_at(i)) * _DICT_FNV_PRIME
        i += 8
    while i < n:
        h = (h ^ UInt64(v.read_u8_at(i))) * _DICT_FNV_PRIME
        i += 1
    # Final avalanche so the low bits (which select the slot) depend on the
    # whole hash — FNV-1a's low bits are weak for short, similar keys, which is
    # exactly the shape of a parquet dictionary.
    h ^= h >> 33
    h *= 0xFF51AFD7ED558CCD
    h ^= h >> 33
    return h


# =============================================================================
# DictInterner
# =============================================================================


struct DictInterner(Movable):
    """Insertion-ordered interner over byte strings, backed by an arena.

    Entries are addressed by their ordinal (0-based, in first-seen order),
    which is exactly the index a merged DICTIONARY column's index buffer must
    carry. `bytes()` / `offsets()` hand back the arena in the layout the Arrow
    dictionary buffers want (`offsets` has `size() + 1` entries, `offsets[0]`
    is 0), so a caller can build the merged column with two bulk memcpys.

    SAFETY: every field is an owning stdlib `List`. No `UnsafePointer` field,
    no wildcard origin, and nothing raw crosses this module's boundary — the
    only pointer arithmetic is inside `List`/`ByteView`, both of which are
    origin-tracked.
    """

    var _bytes: List[UInt8]
    var _offs: List[Int32]
    var _hashes: List[UInt64]
    var _slots: List[Int32]
    var _mask: Int
    var _count: Int
    var _probes: Int

    def __init__(out self, expected_entries: Int = 0):
        """Build an empty interner sized for `expected_entries` (a hint only).

        The slot table is a power of two held at <= 50% load, so the hint just
        avoids the first few rehashes.
        """
        self._bytes = List[UInt8]()
        self._offs = List[Int32]()
        self._offs.append(Int32(0))
        self._hashes = List[UInt64]()
        # ⚠ The hint is CAPPED. Callers derive it from input cardinalities
        # (`first_dict_size * len(cols)`), which for a 49-row-group lineitem is
        # ~5.7M and would preallocate a 16M-slot / 64 MB table up front — and a
        # pathological caller could ask for far more. Start bounded and let the
        # doubling growth find the real size; four extra rehashes are O(n) each
        # and invisible next to the merge itself.
        comptime max_hinted_slots = 1 << 20
        var cap = 16
        var want = expected_entries * 2 + 1
        if want > max_hinted_slots:
            want = max_hinted_slots
        while cap < want:
            cap <<= 1
        self._slots = List[Int32](capacity=cap)
        var i = 0
        while i < cap:
            self._slots.append(Int32(-1))
            i += 1
        self._mask = cap - 1
        self._count = 0
        self._probes = 0

    @always_inline
    def size(self) -> Int:
        """Number of interned entries (== the merged dictionary cardinality)."""
        return self._count

    @always_inline
    def total_bytes(self) -> Int:
        """Total byte length of the concatenated entry payloads."""
        return len(self._bytes)

    @always_inline
    def probes(self) -> Int:
        """Occupied slots examined since construction.

        One increment per candidate byte-compare — the same unit of work one
        iteration of the retired linear scan represented. Flush it into the
        process-global counter with `dict_merge_probe_add(self.probes())`.
        """
        return self._probes

    @always_inline
    def bytes(self) -> ref [self._bytes] List[UInt8]:
        """The arena: every entry's payload, concatenated in ordinal order."""
        return self._bytes

    @always_inline
    def offsets(self) -> ref [self._offs] List[Int32]:
        """`size() + 1` cumulative byte offsets into `bytes()`."""
        return self._offs

    def seed_append(mut self, key: ByteView[_]) -> Int32:
        """Append `key` unconditionally, registering it only if new.

        ⚠ THIS IS NOT `find_or_insert`, AND THE DIFFERENCE IS LOAD-BEARING.
        It seeds the merge from the FIRST input's dictionary, whose indices the
        callers copy through UNCHANGED — so entry `i` of that dictionary must
        land at ordinal `i` even when the dictionary contains DUPLICATES (a
        parquet dictionary page is not required to be distinct). Interning the
        seed through `find_or_insert` would dedupe it and silently shift every
        one of the first input's indices by the number of duplicates seen so
        far, producing WRONG VALUES with no crash.

        Lookups still resolve to the FIRST occurrence, which is what the
        retired `for j in range(len(merged_strings)): … break` did.
        """
        var h = _fnv1a_view(key)
        var idx = self._append_payload(key, h)
        # Register only if this value is not already indexed: first wins.
        var slot = Int(h & UInt64(self._mask))
        var already = False
        while True:
            var e = self._slots[slot]
            if e < 0:
                break
            self._probes += 1
            if self._hashes[Int(e)] == h and self._equals(Int(e), key):
                already = True
                break
            slot = (slot + 1) & self._mask
        if not already:
            self._slots[slot] = Int32(idx)
        self._maybe_grow()
        return Int32(idx)

    def find_or_insert(mut self, key: ByteView[_]) -> Int32:
        """Return `key`'s ordinal, appending it at the end if it is new."""
        var h = _fnv1a_view(key)
        var slot = Int(h & UInt64(self._mask))
        while True:
            var e = self._slots[slot]
            if e < 0:
                var idx = self._append_payload(key, h)
                self._slots[slot] = Int32(idx)
                self._maybe_grow()
                return Int32(idx)
            self._probes += 1
            if self._hashes[Int(e)] == h and self._equals(Int(e), key):
                return e
            slot = (slot + 1) & self._mask

    # -------------------------------------------------------------------------
    # internals
    # -------------------------------------------------------------------------

    @always_inline
    def _append_payload(mut self, key: ByteView[_], h: UInt64) -> Int:
        """Copy `key`'s bytes onto the arena and return the new ordinal."""
        # Bulk-append via `Span`, not a per-byte loop: the pair-wise fold
        # re-seeds from the accumulated left dictionary at every step, so this
        # function moves ~3.7 GB over a 49-row-group lineitem column and a
        # per-byte `append` would be the dominant remaining constant.
        #
        # ⚠ Deliberately NO `reserve(len + n)` either. `List.reserve` grows to
        # the requested size, so calling it once per entry would size the arena
        # EXACTLY on every append and defeat the geometric growth `extend`
        # already performs — reintroducing a quadratic in the very function that
        # exists to remove one.
        self._bytes.extend(key.into_span())
        self._offs.append(Int32(len(self._bytes)))
        self._hashes.append(h)
        var idx = self._count
        self._count += 1
        return idx

    @always_inline
    def _equals(self, idx: Int, key: ByteView[_]) -> Bool:
        var s = Int(self._offs[idx])
        var e = Int(self._offs[idx + 1])
        var n = e - s
        if n != key.len():
            return False
        var i = 0
        while i < n:
            if self._bytes[s + i] != key.read_u8_at(i):
                return False
            i += 1
        return True

    @always_inline
    def _maybe_grow(mut self):
        if (self._count * 2) > (self._mask + 1):
            self._rehash()

    def _rehash(mut self):
        """Double the slot table, moving only the ordinals the OLD TABLE held.

        Walking the old slots rather than the ordinal range 0..count is what
        preserves `seed_append`'s FIRST-wins registration: a duplicate seed
        entry was never registered, so it is never re-introduced here. Rehashing
        by ordinal range would register the duplicate and change which ordinal a
        later lookup resolves to — a silent value bug in the merged output.

        No byte comparison happens here (slots are either empty or taken), so
        rehashing contributes nothing to `probes()`.
        """
        var new_cap = (self._mask + 1) * 2
        var new_mask = new_cap - 1
        var new_slots = List[Int32](capacity=new_cap)
        var i = 0
        while i < new_cap:
            new_slots.append(Int32(-1))
            i += 1
        var s = 0
        var old_cap = self._mask + 1
        while s < old_cap:
            var e = self._slots[s]
            if e >= 0:
                var slot = Int(self._hashes[Int(e)] & UInt64(new_mask))
                while new_slots[slot] >= 0:
                    slot = (slot + 1) & new_mask
                new_slots[slot] = e
            s += 1
        self._slots = new_slots^
        self._mask = new_mask


# =============================================================================
# Process-global dictionary-merge probe counter
# =============================================================================
#
# Same `_Global` idiom as the `komira_parquet` dictionary counter (a name-keyed,
# init-once, cross-compile-unit `Atomic[int64]`): no env var, no
# `unsafe_from_address` laundering. ONE atomic per merge, because call sites
# flush `DictInterner.probes()` in bulk.
# =============================================================================


def _init_dict_merge_probe_counter() -> OwnedPointer[AtomicI64]:
    """`_Global` init_fn (non-raising): allocate the counter once per process."""
    var raw = alloc[AtomicI64](1)
    raw.unsafe_bitcast[Scalar[DType.int64]]().unsafe_write(Scalar[DType.int64](0))
    return OwnedPointer[AtomicI64](unsafe_from_raw_pointer=raw)


comptime _DICT_MERGE_PROBE_COUNTER = _Global[
    "komira_arrow_dict_merge_probes", _init_dict_merge_probe_counter
]


def dict_merge_probe_add(n: Int) raises:
    """Add `n` candidate comparisons to the process-wide dictionary-merge tally.

    `raises` only to propagate the stdlib `_Global.get_or_create_ptr` signature;
    it never raises at runtime.
    """
    if n == 0:
        return
    # SAFETY: FFI carve-out. `get_or_create_ptr` targets KGEN-runtime-managed
    # static storage (process-lifetime); `MutUntrackedOrigin` is the stdlib
    # `_Global` API's own return type, confined to this helper.
    var gp = _DICT_MERGE_PROBE_COUNTER.get_or_create_ptr()
    _ = gp[][].fetch_add(Int64(n))


def dict_merge_probe_count() raises -> Int:
    """Read the process-wide dictionary-merge candidate-comparison count."""
    # SAFETY: see `dict_merge_probe_add`.
    var gp = _DICT_MERGE_PROBE_COUNTER.get_or_create_ptr()
    return Int(gp[][].load())


def reset_dict_merge_probe_count() raises:
    """Reset the process-wide count to 0 (test setup)."""
    # SAFETY: see `dict_merge_probe_add`.
    var gp = _DICT_MERGE_PROBE_COUNTER.get_or_create_ptr()
    gp[][].store(Scalar[DType.int64](0))
