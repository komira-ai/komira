# =============================================================================
# FlatHashAggregator -- hash helpers + layout constants
# =============================================================================
#
# This module owns the module-level hash functions (`_fib_hash_1`,
# `_fib_hash_2`, `_fib_hash_n`) and the layout-shape constants shared by the
# FlatHashAggregator core, partition-flush, and external callers (agg_radix,
# streaming_agg_consumer, flat_hash_agg_merge).
#
# Kept apart from `flat_hash_agg.mojo` so the core aggregator file stays
# under 1,000 lines; `flat_hash_agg.mojo` imports every symbol below, so
# `from komira_op_agg_hash.flat_hash_agg import _fib_hash_1, ...` resolves
# too.
# =============================================================================

from std.memory import UnsafePointer


# Sentinel: an entry slot is empty if its hash field is this value.
# Zero is never a valid hash output (we ensure hash != 0 in _hash_key).
comptime _EMPTY_HASH: UInt64 = 0

# Fibonacci hashing constant for 64-bit: 2^64 / phi
comptime _FIB_HASH_CONST: UInt64 = 0x9E3779B97F4A7C15

# Max load factor: resize when num_groups > capacity * 7 / 10
comptime _LOAD_FACTOR_NUM: Int = 7
comptime _LOAD_FACTOR_DEN: Int = 10

# Per-agg accumulator slot internal-offset constants (relative to the
# slot base). Apply to the legacy 32B quartet layout
# [sum:8B][count:8B][min:8B][max:8B] AND to any narrow-quartet-shape
# slots (ACC_SUM_COUNT_F64 reuses sum at +0, count at +8). The
# slot widths are driven per-agg by `AggLayout.widths[agg_idx]` (see
# `komira_agg_api.agg_layout`). The literal 32
# survives in `flat_hash_agg_perfect.mojo` as `_QUARTET_SLOT_BYTES` for
# the LLVM-const-fold fast path inside `if self._layout_is_quartet:`.
comptime _AGG_SUM_OFF: Int = 0
comptime _AGG_COUNT_OFF: Int = 8
comptime _AGG_MIN_OFF: Int = 16
comptime _AGG_MAX_OFF: Int = 24

# Entry header: hash is always the first 8 bytes
comptime _HASH_BYTES: Int = 8

# Float64 sentinel values for min/max init
# MIN's identity is the canonical NaN, which every value orders below under
# the NaN-greatest float order (komira_udf.float_quotient_order); MAX's
# identity is -inf, below every value including the most negative finite.
comptime _F64_MIN_SEED_BITS: UInt64 = 0x7FF8000000000000
comptime _F64_MAX_SEED_BITS: UInt64 = 0xFFF0000000000000

# Insertion-order entry storage parameters.
#
# Entries are stored in a flat `_entries: List[UInt8]` indexed by
# INSERTION ORDER (`entry_idx`), not by HT slot. Existing entries
# NEVER move when the HT grows: only the slot directory (`_tags` +
# `_slot_to_idx`) is rehashed. The `_entries` buffer grows by doubling
# whenever `_num_groups` exceeds `_entries_capacity`.
#
# Initial entry capacity (in entries): the first `_grow_entries_capacity`
# allocates `_ENTRY_BLOCK_SIZE` entry slots. 2048 (DuckDB's chunk
# granularity) took three doublings per partition at 1M groups over 256
# partitions (~3,900 keys each); 8192 takes none, at ~640 KB for an 80 B
# stride.
comptime _ENTRY_BLOCK_SIZE: Int = 8192

# Slot-directory sentinel: `_slot_to_idx[slot] == _SLOT_EMPTY_IDX` marks
# an empty slot. This is redundant with `_tags[slot] == _EMPTY_HASH` but
# useful for asserting in debug builds; the probe path checks `_tags`
# only.
comptime _SLOT_EMPTY_IDX: Int32 = -1

# Fibonacci-derived primes for multi-key hashing
comptime _PRIME_0: UInt64 = 0x9E3779B97F4A7C15
comptime _PRIME_1: UInt64 = 0x517CC1B727220A95
comptime _PRIME_2: UInt64 = 0x6C62272E07BB0142
comptime _PRIME_3: UInt64 = 0xE9170A1B3F6C8D2D
comptime _PRIME_4: UInt64 = 0xB4F0A22C3E5D1987
comptime _PRIME_5: UInt64 = 0xD83C6F45A1B2E3A7
comptime _PRIME_6: UInt64 = 0xA59F1E72B4C6D803
comptime _PRIME_7: UInt64 = 0x7B2E5C8F19A3D641


@always_inline
def _fib_hash_1(k: Int64) -> UInt64:
    """Hash a single Int64 key. Guarantees result != 0."""
    var h = UInt64(k) * _FIB_HASH_CONST
    h = h ^ (h >> 32)
    # Ensure non-zero (zero is our empty sentinel)
    if h == 0:
        h = 1
    return h


# =============================================================================
# PERF-CORRECTNESS-CRITICAL: _fib_hash_2 MUST match _fib_hash_n bit-for-bit
# =============================================================================
# Why it's critical:
#   Radix aggregation runs a cross-path merge: a sub-table built by the
#   2-key fast path (find_or_create_2) is later merged into an N-key table
#   built by _find_or_create_n. Both paths look up the SAME row by hashing
#   its keys. If the two hash functions ever disagree on the same (k0,k1)
#   input, the merge silently creates two separate group entries for
#   what is really the same group. Aggregate results become WRONG -- not
#   slower, WRONG. The user sees duplicated groups with split sums.
#
#   This is not a future-proofing concern: an earlier `_fib_hash_2` mixed
#   the two primes differently from the `_fib_hash_n` unroll, and the
#   merge produced duplicate groups.
#
# Do NOT:
#   - Change the constants in one without changing the other.
#   - "Optimize" _fib_hash_2 (e.g. skip the final avalanche) even if it
#     looks redundant. It is load-bearing for merge correctness.
#   - Add _fib_hash_3 / _fib_hash_4 fast paths without the same guarantee.
#
# If you change either function, update BOTH and add a randomized
# correctness test that asserts for many random
# (k0, k1) pairs:  _fib_hash_2(k0, k1) == _fib_hash_n(&[k0, k1], 2).
# =============================================================================
@always_inline
def _fib_hash_2(k0: Int64, k1: Int64) -> UInt64:
    """Hash two Int64 keys. Bit-identical to `_fib_hash_n(&[k0,k1], 2)`.
    Must stay in lockstep with `_fib_hash_n` (see the block above)."""
    var h = (UInt64(k0) * _PRIME_0) ^ (UInt64(k1) * _PRIME_1)
    h = h ^ (h >> 33)
    h = h * UInt64(0xFF51AFD7ED558CCD)
    h = h ^ (h >> 33)
    if h == 0:
        h = 1
    return h


# PERF-CORRECTNESS-CRITICAL: see the block above _fib_hash_2 -- both
# functions MUST agree bit-for-bit on (k0, k1) inputs.
@always_inline
def _fib_hash_n[o: Origin](keys_ptr: UnsafePointer[UInt8, o], num_keys: Int) -> UInt64:
    """Hash N Int64 keys stored contiguously. Guarantees result != 0."""
    # SAFETY: keys_ptr points into the row buffer at offset _HASH_BYTES,
    # containing num_keys consecutive Int64 values. We cast to read them.
    var kp = keys_ptr.bitcast[Int64]()
    var h = UInt64(0)
    # Unrolled for first 8 keys using distinct primes
    if num_keys > 0:
        h = h ^ (UInt64(kp[]) * _PRIME_0)
    if num_keys > 1:
        h = h ^ (UInt64((kp + 1)[]) * _PRIME_1)
    if num_keys > 2:
        h = h ^ (UInt64((kp + 2)[]) * _PRIME_2)
    if num_keys > 3:
        h = h ^ (UInt64((kp + 3)[]) * _PRIME_3)
    if num_keys > 4:
        h = h ^ (UInt64((kp + 4)[]) * _PRIME_4)
    if num_keys > 5:
        h = h ^ (UInt64((kp + 5)[]) * _PRIME_5)
    if num_keys > 6:
        h = h ^ (UInt64((kp + 6)[]) * _PRIME_6)
    if num_keys > 7:
        h = h ^ (UInt64((kp + 7)[]) * _PRIME_7)
    # Fallback for > 8 keys (rare)
    for i in range(8, num_keys):
        h = h ^ (UInt64((kp + i)[]) * (UInt64(i) * _FIB_HASH_CONST))
    # Final avalanche mix
    h = h ^ (h >> 33)
    h = h * UInt64(0xFF51AFD7ED558CCD)
    h = h ^ (h >> 33)
    if h == 0:
        h = 1
    return h
