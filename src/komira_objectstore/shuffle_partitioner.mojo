# =============================================================================
# komira_objectstore/shuffle_partitioner.mojo
#   The HashPartitioner: key bytes -> partition_id in [0, R).
# =============================================================================
#
# A `HashPartitioner` folds a key's bytes through FNV-1a-64 and reduces the hash
# to `partition_id in 0..R` via `radix_partition` (`shuffle_radix.mojo`) — the
# ONE canonical cross-layer reduction.
# This is the SAME reduction the engine scatter (`(h >> shift) & mask`) and the
# broker (`range_containing_pid` over a radix-aligned 2^k-range map) use, so a
# key routes to the same partition on both sides of the layering boundary.
# It is a HIGH-bits radix, NOT a `hash % R` (LOW-bits modulo): `% R` partitions
# the SAME hash into a DIFFERENT partition-id space than the engine sub-tables
# (a silent misroute once the engine radix sub-tables feed the shuffle sink).
#
# LAYERING NOTE (why FNV-1a-64 is implemented here, not imported from
# `komira_engine_runtime.spill.fnv1a`): `komira_objectstore`'s only
# FNV source is local. It does NOT — and must not —
# depend on `komira_engine_runtime` (objectstore is a foundational package
# that the engine consumes, not the reverse; an objectstore -> engine_runtime
# edge would invert the layering). The FNV-1a-64 *wire contract* (the
# well-known offset_basis + prime, the `h = (h ^ byte) * prime` fold) is the
# thing we share — not the function identity. We reproduce the exact constants
# and fold byte-for-byte so a key hashes identically here and in
# `fnv1a_64_over`. This mirrors step 1's `shuffle_codec` decision: it defines
# module-local LE primitives rather than importing cas_manifest's `_`-private
# helpers, because the wire format is the contract, not the symbol.
#
# Pointer discipline: ZERO UnsafePointer. The partitioner is a stateless POD
# (one Int64 R) operating on `List[UInt8]` / `Span[UInt8, _]` key bytes; it is
# never a byte-slab element, never a long-lived or wildcard-origin field, so
# heap-reuse is N/A.
# =============================================================================


from .shuffle_radix import radix_partition, log2_floor_pow2, is_pow2


# FNV-1a-64 well-known constants (the FNV reference) — byte-identical to
# `komira_engine_runtime.spill.fnv1a` so a key folds to the same hash on
# both sides of the layering boundary. See the LAYERING NOTE above.
comptime _FNV1A_64_OFFSET_BASIS: UInt64 = 0xCBF29CE484222325
comptime _FNV1A_64_PRIME: UInt64 = 0x00000100000001B3


@always_inline
def _fnv1a_64_over_list(bytes: List[UInt8]) -> UInt64:
    """FNV-1a-64 over a borrowed byte list (offset basis seeded internally).
    Byte-identical to `fnv1a_64_over` — empty input returns the offset basis
    (canonical FNV-1a-64 semantic)."""
    var h: UInt64 = _FNV1A_64_OFFSET_BASIS
    for i in range(len(bytes)):
        h = (h ^ UInt64(Int(bytes[i]))) * _FNV1A_64_PRIME
    return h


@always_inline
def _fnv1a_64_over_span(bytes: Span[UInt8, _]) -> UInt64:
    """FNV-1a-64 over a borrowed byte span — the Span overload (same fold)."""
    var h: UInt64 = _FNV1A_64_OFFSET_BASIS
    for i in range(len(bytes)):
        h = (h ^ UInt64(Int(bytes[i]))) * _FNV1A_64_PRIME
    return h


@fieldwise_init
struct HashPartitioner(Copyable, Movable, Deinitable):
    """Maps a key's bytes to a partition_id in `[0, R)`.

    Reduction: `radix_partition(fnv1a_64(key_bytes), log2(R))` — the canonical
    HIGH-bits radix (`(h >> (64 - log2(R))) & (R - 1)`, `shuffle_radix.mojo`).
    The hash is taken UNSIGNED (UInt64). This is byte-identical to the engine
    scatter's `(h >> shift) & mask` and a special case of the broker's
    `range_containing_pid`, so a key routes to the same partition on both sides
    of the objectstore<->engine layering boundary.

    PRECONDITION: R MUST be a power of two (the high-bits radix is only a clean
    `2^k`-equal-width bucketing for power-of-two R; R=4 qualifies). A
    non-power-of-two R raises at construction-check time via `r_checked` /
    `partition_for` (which assert `is_pow2(R)`). R<=0 is degenerate (clamps to
    partition 0 rather than computing a bogus shift).

    Field layout:
      var partition_count: Int64   — R (the fixed reduce-partition count, 2^k).
    """

    var partition_count: Int64

    @always_inline
    def r(self) -> Int:
        return Int(self.partition_count)

    @always_inline
    def r_checked(self) raises -> Int:
        """R with the power-of-two precondition enforced. Raises if R is not a
        power of two (R=4 passes; a non-2^k R is a programming error
        — the high-bits radix is not a valid bucketing for it)."""
        var r = self.r()
        if not is_pow2(r):
            raise Error(
                "HashPartitioner: R must be a power of two for the high-bits"
                " radix reduction (got R="
                + String(r)
                + "); see shuffle_radix.mojo"
            )
        return r

    @always_inline
    def partition_for(self, key_bytes: List[UInt8]) raises -> Int:
        """Partition id in `[0, R)` for `key_bytes` — `radix_partition(fnv1a_64,
        log2(R))`.

        Raises if R is not a power of two (precondition). R<=0 is the degenerate
        single-bucket clamp (returns 0)."""
        var r = self.r_checked()
        if r <= 1:
            return 0
        var h = _fnv1a_64_over_list(key_bytes)
        return radix_partition(h, log2_floor_pow2(r))

    @always_inline
    def partition_for_span(self, key_bytes: Span[UInt8, _]) raises -> Int:
        """Span overload of `partition_for` — for callers that already hold a
        borrowed view over the key bytes without materializing a List. Same
        canonical HIGH-bits radix reduction + power-of-two precondition."""
        var r = self.r_checked()
        if r <= 1:
            return 0
        var h = _fnv1a_64_over_span(key_bytes)
        return radix_partition(h, log2_floor_pow2(r))
