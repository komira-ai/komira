# =============================================================================
# byte_hashset.mojo — Option D byte-erased HashSet tail (Phase 1)
# =============================================================================
#
# **Byte-erased fallback** for the Option D HashSet family per
# an internal doc §3.
#
# Backs every shape that does NOT route to a `HashSetN[K0..KN-1]`
# parametric instantiation:
#   - `arity > 8` (no parametric struct for that arity).
#   - Exotic DType combos that do not justify a parametric instantiation
#     per OQ1 (e.g. `(String, Decimal128, Date32, Int64)` mixed).
#   - String / Bytes keys (variable-width — `Scalar[DType]` doesn't cover).
#
# # Storage shape
#
#   - `payload_slab: List[UInt8]` — flat concatenation of every row's bytes.
#   - `row_starts: List[Int]` — n_used + 1 entries; row i occupies bytes
#     `payload_slab[row_starts[i] : row_starts[i+1]]`. Last entry is the
#     sentinel `payload_slab.size()`.
#   - `hashes: List[UInt64]` — n_used entries; per-row precomputed hash
#     for the hash filter (probe skips bytes-compare on hash-mismatch).
#   - `n_used: Int`.
#
# Caller (SDK lowering or driver) emits per-row typed serializer that
# writes the row's bytes into a stack-allocated `InlineArray[UInt8, ROW_WIDTH]`
# (fixed-width keys) or a heap `List[UInt8]` (variable-width keys), then
# calls `insert_serialized(hash, row_bytes_span)` / `contains_serialized(...)`.
#
# # Public API — Span-based
#
# `insert_serialized` / `contains_serialized` accept `Span[UInt8, ...]`
# (NOT `UnsafePointer[UInt8]`) because no UnsafePointer
# appears in a public signature. The Span carries the origin; ByteHashSet borrow-checks
# the input through Span.
#
# # Encapsulation invariants
#
#   - NO UnsafePointer in any public method signature.
#   - NO wildcard origins.
#   - Internal `memcmp` on `self.payload_slab.unsafe_ptr() + start` is
#     gated with a `# SAFETY:` block.
#   - `List[UInt8]` is gap6-safe (POD numeric; no Movable struct fields
#     with heap-owning inner fields).
#
# # POC anchor
#
# Body validated by the poc_byte_erased_hashset probe at 2.00× insert /
# 2.01× probe tax vs hardcoded `HashSetI64I64I64` (the acceptable long-tail
# bound). Mixed-DType arity-3 (I64, String, F64) round-trip correctness
# GREEN.
#
# # Cross-references
#
#   - Design doc: an internal doc §3.
#   - Sibling: `hashset_parametric.mojo` (typed parametric family).
#   - POC: the poc_byte_erased_hashset probe.
# =============================================================================

from std.memory import unsafe_memcmp


# =============================================================================
# §1 — Constants
# =============================================================================


comptime BYTE_HASHSET_DEFAULT_CAPACITY: Int = 16
"""Initial hint for the per-row `row_starts` + `hashes` Lists. The
`payload_slab` reserves capacity*16 bytes (heuristic for ~16-byte
average row width); the slab grows via `List.append` on insert."""


comptime BYTE_HASHSET_AVG_ROW_WIDTH: Int = 16
"""Heuristic average row width in bytes for the payload_slab capacity
reservation. Fixed-width arity-3 I64 keys are 24 bytes/row; mixed-DType
shapes vary. The slab grows freely; this is purely a sizing hint."""


# =============================================================================
# §2 — ByteHashSet
# =============================================================================


struct ByteHashSet(Movable):
    """Byte-erased HashSet over packed composite key rows.

    Caller-side typed serializer (in the SDK lowering arm or feed driver)
    emits the per-row byte representation; `ByteHashSet` is unaware of
    the row's typed shape. Linear-scan probe with per-row hash filter;
    bytewise `memcmp` on hash-match.

    Storage:
      - `payload_slab`: List[UInt8] packed-row bytes.
      - `row_starts`: List[Int], n_used + 1 entries.
      - `hashes`: List[UInt64], n_used entries.

    Encapsulation: `insert_serialized` / `contains_serialized` accept
    `Span[UInt8, ...]` rather than `UnsafePointer[UInt8]`. The internal
    `_row_equal` helper uses `memcmp` via `unsafe_ptr() + offset` and is
    gated with a SAFETY block.

    Gap6 audit: `List[UInt8]` is a POD numeric List; gap6-safe.
    """

    var payload_slab: List[UInt8]
    var row_starts: List[Int]
    var hashes: List[UInt64]
    var n_used: Int

    def __init__(out self, capacity: Int = BYTE_HASHSET_DEFAULT_CAPACITY):
        self.payload_slab = List[UInt8](
            capacity=capacity * BYTE_HASHSET_AVG_ROW_WIDTH
        )
        self.row_starts = List[Int](capacity=capacity + 1)
        self.row_starts.append(0)  # sentinel for row 0 start
        self.hashes = List[UInt64](capacity=capacity)
        self.n_used = 0

    @always_inline
    def _row_len(self, i: Int) -> Int:
        """Length of row i in bytes. Computed from the row_starts
        offset table."""
        return self.row_starts[i + 1] - self.row_starts[i]

    def _row_equal[
        ImmO: Origin[mut=False],
    ](self, i: Int, imm probe: Span[UInt8, ImmO]) -> Bool:
        """Compare row i's bytes against probe's bytes. Length-first
        check, then bytewise memcmp on equal-length rows.

        # SAFETY:
        # `self.payload_slab.unsafe_ptr() + start` is in-bounds for the
        # `[start, start + n)` range — start comes from `row_starts[i]`,
        # `n = row_starts[i+1] - row_starts[i]`, and `row_starts[n_used]
        # == payload_slab.size()` by construction. The ptr stays alive
        # for the duration of this call (no realloc inside `_row_equal`).
        # `probe.unsafe_ptr()` is a Span-borrowed ptr; its lifetime is
        # the caller's, tracked via the `ImmO` origin. Both ptrs are
        # READ-ONLY for the memcmp.
        """
        var start = self.row_starts[i]
        var n = self._row_len(i)
        if n != len(probe):
            return False
        var slab_ptr = self.payload_slab.unsafe_ptr() + start
        var probe_ptr = probe.unsafe_ptr()
        return unsafe_memcmp(slab_ptr, probe_ptr, n) == 0

    def insert_serialized[
        ImmO: Origin[mut=False],
    ](mut self, hash: UInt64, imm row_bytes: Span[UInt8, ImmO]) -> Bool:
        """Insert pre-serialized typed key. Returns True if new, False
        if duplicate. Linear-scan probe with hash filter.

        `row_bytes` is the caller's serialized representation of the
        composite key. ByteHashSet treats it as opaque bytes; the
        deserializer at finalize/drain time is the SDK's responsibility.
        """
        var i = 0
        var n = self.n_used
        while i < n:
            if self.hashes[i] == hash:
                if self._row_equal[ImmO](i, row_bytes):
                    return False
            i = i + 1
        # Append payload bytes + row_starts entry + hash.
        var byte_len = len(row_bytes)
        var k = 0
        while k < byte_len:
            self.payload_slab.append(row_bytes[k])
            k = k + 1
        self.row_starts.append(self.row_starts[n] + byte_len)
        self.hashes.append(hash)
        self.n_used = n + 1
        return True

    def contains_serialized[
        ImmO: Origin[mut=False],
    ](self, hash: UInt64, imm row_bytes: Span[UInt8, ImmO]) -> Bool:
        """Probe for pre-serialized typed key. Returns True if present."""
        var i = 0
        var n = self.n_used
        while i < n:
            if self.hashes[i] == hash:
                if self._row_equal[ImmO](i, row_bytes):
                    return True
            i = i + 1
        return False

    @always_inline
    def size(self) -> Int:
        """Number of distinct rows inserted."""
        return self.n_used

    @always_inline
    def row_byte_len(self, i: Int) -> Int:
        """Byte length of row i (for the SDK-emitted deserializer at
        finalize/drain time)."""
        return self._row_len(i)

    def row_bytes(self, i: Int) -> List[UInt8]:
        """Return a COPY of row i's bytes for the SDK-emitted deserializer
        at finalize/drain time. Returns a new `List[UInt8]` (the copy
        keeps the public API encapsulation-clean — no Span / origin
        gymnastics, no UnsafePointer in the surface).

        Phase 1 correctness-first: the copy adds an O(row_width) cost
        per finalize call. A future polish slot can swap in a borrowed-
        Span accessor (Phase 2 SDK wiring) for the hot path.
        """
        var start = self.row_starts[i]
        var n = self._row_len(i)
        var out = List[UInt8](capacity=n)
        var k = 0
        while k < n:
            out.append(self.payload_slab[start + k])
            k = k + 1
        return out^
