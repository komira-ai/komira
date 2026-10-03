# =============================================================================
# komira_shuffle/radix.mojo
#   THE one canonical cross-layer hash->partition reduction for the shuffle.
# =============================================================================
#
# # The decision: ONE canonical reduction = the engine HIGH-bits
#   radix.
#
# A hash `h: UInt64` reduces to a partition in `[0, R)` (R a power of two,
# R = 2^k) by taking the TOP `k` bits:
#
#     radix_partition(h, k) = Int((h >> (64 - k)) & ((1 << k) - 1))
#
# This is the reduction used on BOTH sides of the objectstore<->engine layering
# boundary so a key routes to the SAME partition everywhere:
#
#   * The engine's in-process radix partitioner is exactly this scheme:
#     `_partition_for_hash(h, shift, mask) = (h >> shift) & mask` in
#     `komira_engine_operators.unified.agg.flat_hash_agg_scatter`,
#     with `shift = 64 - log2(num_partitions)` and `mask = num_partitions - 1`.
#     `radix_partition(h, k)` IS `_partition_for_hash(h, 64-k, 2^k-1)`.
#     Adopting it as the shuffle reduction means ZERO engine-side change.
#
#   * The broker's routing primitive `PartitionMap.range_containing_pid(h)`
#     (`komira_broker.partition_map`) routes `h` to the pid of the
#     ordered hash-range that contains it. `radix_partition(h, k)` is the
#     SPECIAL CASE of that primitive for the equal-width 2^k-range map whose
#     boundaries fall on exact multiples of `2^(64-k)` (range i =
#     `[i * 2^(64-k), (i+1) * 2^(64-k))`, last range absorbing the inclusive
#     `2^64` top). So the same key resolves identically to a broker
# `PartitionMap` AND to the engine sub-tables. The cross-check
#     test pins all three.
#
# # Why the HIGH-bits radix and NOT `% R`
#
# A LOW-bits `fnv1a_64(key) % R` reduction and the engine scatter's HIGH-bits
# `(h >> shift) & mask` partition the SAME hash into DIFFERENT partition-id
# spaces: a key in shuffle bucket `h % R` here would land in engine sub-table
# `(h >> shift) & mask` there. A self-contained shuffle (sink + source both on
# `% R`) does not misroute, but once the engine's radix sub-tables feed the
# shuffle sink, the two spaces MUST
# be ONE scheme or rows silently misroute. We pick the engine's HIGH-bits radix
# as the canonical scheme because (a) it is the engine's native scheme — zero
# engine change — and (b) it is a special case of the broker's range routing,
# so it reconciles to BOTH the engine sub-tables AND the broker PartitionMap.
# Modulo is the odd-one-out and is the side that changes (it lives nowhere in
# the engine or broker reductions).
#
# # The engine's two internal radix configs, and how the shuffle R folds onto
#   them (the "concat in partition order is a pointer walk" bridge)
#
# The engine itself runs TWO radix configurations on its in-process partition
# fan-out (this is an engine-internal disagreement, NOT a shuffle concern):
#   * the scatter kernel is wired at 64-way (RADIX_BITS=6, shift=58) —
#     the flat-hash-agg scatter,
#   * the partitioned aggregator (PFA) is 256-way (RADIX_BITS=8, shift=56) —
#     the partitioned flat-hash aggregator + `_NUM_PARTITIONS_FLATHASH=256`
#     in the flat-hash-agg state.
# Both are the SAME high-bits radix family — they differ only in how many top
# bits they consume. The shuffle reduce-partition count `R` is PLAN-FIXED and
# DECOUPLED from whatever the in-process `NUM_PARTITIONS` happens to be:
#
#   * When `R == NUM_PARTITIONS`, the shuffle bucket == the engine sub-table
#     index 1:1 (same `k` bits). A producer's engine sub-table `p` feeds shuffle
#     bucket `p` with no regrouping.
#
#   * When they differ (say engine `NUM_PARTITIONS = 2^B`, shuffle `R = 2^k`
#     with `k <= B`), the shuffle bucket is the TOP `k` bits of the hash — a
#     high-bit PREFIX of the engine's `B`-bit sub-table index. Each shuffle
#     bucket is therefore exactly the union of `2^(B - k)` CONTIGUOUS engine
#     sub-tables (the ones sharing the same top-`k`-bit prefix):
#
#         shuffle_bucket(p_engine) = p_engine >> (B - k)
#
#     So "concat the engine sub-tables in partition order into shuffle bucket b"
#     is a POINTER WALK over the contiguous sub-table block
#     `[b * 2^(B-k), (b+1) * 2^(B-k))` — NOT a re-partition. The high-bit
#     prefix relationship is what makes the concat a pointer walk rather than a
#     full re-scatter, and it is the bridge that lets the engine feed
#     sub-tables straight into the shuffle sink. (k > B — more shuffle buckets
#     than engine sub-tables — would require splitting a sub-table across
#     buckets and is out of scope; the precondition that R is a
#     power of two keeps this a clean bit-prefix relationship.)
#
# # Layering (why this lives in objectstore and the FNV constants stay local)
#
# `komira_shuffle` builds on `komira_objectstore` and nothing above it. It does
# NOT — and MUST NOT — depend on `komira_engine_runtime`, `komira_engine_operators`,
# or `komira_broker` (the shuffle is foundational; the engine + broker consume
# it, not the reverse). What is SHARED across the boundary is the *reduction
# contract* (this exact arithmetic) and the FNV-1a-64 *wire contract* (the
# constants + fold) — NOT function identity. The FNV constants are reproduced
# by value in `partitioner.mojo` (see its LAYERING NOTE); the cross-check
# test pins that the by-value reproduction has not drifted from the engine's
# canonical `fnv1a_64_over`. This mirrors `codec`'s decision to define
# module-local LE primitives rather than import cas_manifest's `_`-private
# helpers: the wire/reduction format is the contract, not the symbol.
#
# # Pointer discipline
#
# ZERO UnsafePointer. Pure UInt64/Int arithmetic free functions. No fields, no
# slab elements, no origins — heap-reuse is N/A.
# =============================================================================


@always_inline
def is_pow2(r: Int) -> Bool:
    """True iff `r` is a power of two and `r >= 1` (`r & (r-1) == 0`)."""
    return r >= 1 and (r & (r - 1)) == 0


@always_inline
def log2_floor_pow2(r: Int) -> Int:
    """`log2(r)` for a power-of-two `r >= 1` (the number of top bits the radix
    consumes). For non-power-of-two input this returns `floor(log2(r))`, which
    is NOT a valid radix width — callers MUST gate on `is_pow2(r)` first (see
    `radix_partition`'s precondition). `r <= 0` returns 0."""
    if r <= 0:
        return 0
    var k = 0
    var v = r
    while v > 1:
        v >>= 1
        k += 1
    return k


@always_inline
def radix_partition(h: UInt64, log2_r: Int) -> Int:
    """THE one canonical cross-layer reduction: partition id in `[0, 2^log2_r)`
    for hash `h`, taking the TOP `log2_r` bits.

        radix_partition(h, k) = Int((h >> (64 - k)) & ((1 << k) - 1))

    Byte-identical to the engine's `_partition_for_hash(h, 64-k, 2^k-1)` and to
    the broker's `range_containing_pid` over the radix-aligned equal-width
    2^k-range map. See the module header for the full reconciliation.

    `log2_r == 0` (R == 1) is the single-partition degenerate: everything maps
    to partition 0 (the shift would be 64, which is UB for a 64-bit value, so we
    special-case it). `log2_r` in `[1, 64]` is the valid range; the caller is
    responsible for `log2_r == log2_floor_pow2(R)` over a power-of-two R."""
    if log2_r <= 0:
        return 0
    var shift = UInt64(64 - log2_r)
    var mask = UInt64((1 << log2_r) - 1)
    return Int((h >> shift) & mask)
