# =============================================================================
# Split Block Bloom Filter (SBBF) — generic probabilistic membership test
# =============================================================================
#
# A pure data structure with no Parquet dependencies (it uses only
# MmapAlignedBuffer). Used by Parquet predicate pushdown and by the engine's
# semi-join bloom filtering.
#
# A probabilistic data structure that can definitively say "not present"
# but may return false positives for "possibly present". Used to skip
# entire row groups during predicate pushdown.
#
# The Parquet SBBF spec:
#   - Filter is divided into 256-bit (32-byte) blocks, each containing
#     8 x 32-bit words.
#   - 8 salt constants derive 8 bit positions per insert/check.
#   - Hash function: xxHash64 seed 0 (parquet-format spec mandate).
#   - Block selection: upper 32 bits of hash.
#   - Bit positions: multiply lower 32 bits by salt, take top 5 bits.
#
# Hash family support:
#   - `HashFamily.XXHASH64` is the DEFAULT and spec-canonical hash. All
#     newly-written blooms use xxHash64. Cross-impl interop with DuckDB,
#     pyarrow, parquet-rs, arrow-cpp, Spark, etc.
#   - `HashFamily.FNV1A` is a LEGACY fallback for files written by an older
#     version of this project's Parquet writer, which hashed with FNV-1a.
#     Read-side dispatch detects this via `created_by` prefix-version.
#
# xxHash64 spec: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
# Parquet spec: https://github.com/apache/parquet-format/blob/master/BloomFilter.md
#
# SAFETY: The public byte-input functions (xxhash64, from_bytes, hash_bytes,
# insert_bytes, might_contain_bytes) take a `Span[UInt8, _]`; no public
# function takes or returns a pointer. Raw pointers appear only inside
# function bodies and in the private `_read_u64_le` / `_read_u32_le`
# helpers, each derived from a borrowed Span and never escaping the call.
# =============================================================================


from komira_atomic_alias import AtomicU32
from std.memory import unsafe_memcpy, unsafe_memset, alloc
from std.sys import simd_width_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.byte_view import ByteView


# SBBF salt constants per the Parquet spec.
comptime SALT_0: UInt32 = 0x47B6137B
comptime SALT_1: UInt32 = 0x44974D91
comptime SALT_2: UInt32 = 0x8824AD5B
comptime SALT_3: UInt32 = 0xA2B7289D
comptime SALT_4: UInt32 = 0x705495C7
comptime SALT_5: UInt32 = 0x2DF1424B
comptime SALT_6: UInt32 = 0x9EFC4947
comptime SALT_7: UInt32 = 0x5C6BFB31

# Minimum bitset size in bytes (one block = 32 bytes).
comptime BITSET_MIN_BYTES: Int = 32

# Maximum bitset size: 128 MiB.
comptime BITSET_MAX_BYTES: Int = 128 * 1024 * 1024

# Block size: 8 x 32-bit words = 32 bytes = 256 bits.
comptime BLOCK_SIZE_BYTES: Int = 32

# Number of words per block.
comptime WORDS_PER_BLOCK: Int = 8


# =============================================================================
# HashFamily — selects the hash function used to map values to SBBF positions
# =============================================================================
# Parquet-format spec mandates xxHash64. An older version of this writer
# used FNV-1a; current writers use xxHash64 for cross-tool bloom interop.
# Read-side detects the hash family from FileMetaData.created_by (the writer
# version prefix); write-side defaults to XXHASH64.
# =============================================================================


struct HashFamily(Movable, Copyable, ImplicitlyCopyable, TrivialRegisterPassable):
    """SBBF hash family discriminator. Trivial enum-shaped wrapper around
    an Int8 tag — comptime cascades use `tag == HashFamily.XXHASH64`."""

    comptime _XXHASH64_TAG: Int8 = 0
    comptime _FNV1A_TAG: Int8 = 1
    # FIBONACCI_JOIN (tag 2): the in-memory hash-join bloom hash. The bloom
    # bits are written with the SAME Fibonacci multiply-xor-fold the join
    # probe already computes for the hash-table bucket (`_join_fib_hash` ==
    # `join._hash_join_key`), so the probe reuses ONE hash for both the bloom
    # pre-check and the HT slot — killing the redundant xxHash64. This family
    # is NEVER written to a Parquet file (parquet blooms are spec-mandated
    # xxHash64); it exists only for engine-internal join blooms. See
    # `might_contain_join_key` / `insert_join_key`.
    comptime _FIBONACCI_JOIN_TAG: Int8 = 2

    var tag: Int8

    @always_inline
    def __init__(out self, tag: Int8):
        self.tag = tag

    @staticmethod
    @always_inline
    def xxhash64() -> Self:
        return HashFamily(HashFamily._XXHASH64_TAG)

    @staticmethod
    @always_inline
    def fnv1a() -> Self:
        return HashFamily(HashFamily._FNV1A_TAG)

    @staticmethod
    @always_inline
    def fibonacci_join() -> Self:
        return HashFamily(HashFamily._FIBONACCI_JOIN_TAG)

    @always_inline
    def is_xxhash64(self) -> Bool:
        return self.tag == HashFamily._XXHASH64_TAG

    @always_inline
    def is_fnv1a(self) -> Bool:
        return self.tag == HashFamily._FNV1A_TAG

    @always_inline
    def is_fibonacci_join(self) -> Bool:
        return self.tag == HashFamily._FIBONACCI_JOIN_TAG

    @always_inline
    def __eq__(self, other: Self) -> Bool:
        return self.tag == other.tag

    @always_inline
    def __ne__(self, other: Self) -> Bool:
        return self.tag != other.tag


# =============================================================================
# xxHash64 (spec-canonical Parquet bloom hash)
# =============================================================================
# Reference: https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md
#
# Algorithm summary (seed 0; little-endian read):
#   1. If len >= 32: init 4 accumulators (v1,v2,v3,v4) at seed+P1+P2,
#      seed+P2, seed, seed-P1. Loop in 32-byte stripes; each lane runs
#      a round (acc = rotl64(acc + (block * P2), 31) * P1). At the end
#      of the 32B loop, combine via rotl-merge.
#   2. Else: single accumulator (seed + P5).
#   3. Mix in length, then drain the tail (8-byte / 4-byte / 1-byte
#      lanes), applying finalization avalanche at the end.
#
# Per parquet-format BloomFilter.md, the bloom uses xxHash64(value, seed=0).
# =============================================================================

comptime _XXH_P1: UInt64 = 0x9E3779B185EBCA87
comptime _XXH_P2: UInt64 = 0xC2B2AE3D27D4EB4F
comptime _XXH_P3: UInt64 = 0x165667B19E3779F9
comptime _XXH_P4: UInt64 = 0x85EBCA77C2B2AE63
comptime _XXH_P5: UInt64 = 0x27D4EB2F165667C5


@always_inline
def _rotl64(x: UInt64, r: Int) -> UInt64:
    """64-bit left-rotate by r bits (0 < r < 64)."""
    return (x << UInt64(r)) | (x >> UInt64(64 - r))


@always_inline
def _xxh_round(acc: UInt64, input: UInt64) -> UInt64:
    """One xxHash64 accumulator round."""
    var a = acc + (input * _XXH_P2)
    a = _rotl64(a, 31)
    return a * _XXH_P1


@always_inline
def _xxh_merge_round(acc: UInt64, val: UInt64) -> UInt64:
    """Merge a lane accumulator into the final hash state."""
    var v = _xxh_round(0, val)
    var a = acc ^ v
    return a * _XXH_P1 + _XXH_P4


@always_inline
def _xxh_avalanche(h: UInt64) -> UInt64:
    """Final xxHash64 avalanche mix."""
    var x = h
    x = x ^ (x >> 33)
    x = x * _XXH_P2
    x = x ^ (x >> 29)
    x = x * _XXH_P3
    x = x ^ (x >> 32)
    return x


@always_inline
def _read_u64_le(data: UnsafePointer[UInt8, _], offset: Int) -> UInt64:
    """Read an 8-byte little-endian u64. Unaligned-safe (byte-wise OR)."""
    # SAFETY: caller asserts offset+8 <= length. Bytewise OR avoids
    # alignment / aliasing assumptions; LLVM constant-folds + vectorizes.
    var p = data + offset
    return (
        UInt64(p[0])
        | (UInt64(p[1]) << 8)
        | (UInt64(p[2]) << 16)
        | (UInt64(p[3]) << 24)
        | (UInt64(p[4]) << 32)
        | (UInt64(p[5]) << 40)
        | (UInt64(p[6]) << 48)
        | (UInt64(p[7]) << 56)
    )


@always_inline
def _read_u32_le(data: UnsafePointer[UInt8, _], offset: Int) -> UInt32:
    """Read a 4-byte little-endian u32. Unaligned-safe."""
    # SAFETY: caller asserts offset+4 <= length; bytewise reads, no escape.
    var p = data + offset
    return (
        UInt32(p[0])
        | (UInt32(p[1]) << 8)
        | (UInt32(p[2]) << 16)
        | (UInt32(p[3]) << 24)
    )


@always_inline
def xxhash64(data: Span[UInt8, _]) -> UInt64:
    """Compute xxHash64(seed=0) of the bytes of `data`.

    Spec-compliant per
    https://github.com/Cyan4973/xxHash/blob/dev/doc/xxhash_spec.md.

    Args:
        data: The input bytes.

    Returns:
        64-bit hash; deterministic; matches the reference C
        implementation byte-for-byte at seed=0.
    """
    var length = len(data)
    # SAFETY: `p` is the start of the borrowed `data`, alive for this call;
    # every read below is at an offset `pos` with `pos + width <= length`
    # (the loop guards), and `p` does not escape.
    var p = data.unsafe_ptr()
    var hash: UInt64
    var pos = 0

    if length >= 32:
        # 32-byte stripe loop with 4 lane accumulators.
        var v1 = _XXH_P1 + _XXH_P2
        var v2 = _XXH_P2
        var v3 = UInt64(0)
        var v4 = UInt64(0) - _XXH_P1
        while pos + 32 <= length:
            v1 = _xxh_round(v1, _read_u64_le(p, pos))
            v2 = _xxh_round(v2, _read_u64_le(p, pos + 8))
            v3 = _xxh_round(v3, _read_u64_le(p, pos + 16))
            v4 = _xxh_round(v4, _read_u64_le(p, pos + 24))
            pos = pos + 32
        # Combine lanes.
        hash = (
            _rotl64(v1, 1)
            + _rotl64(v2, 7)
            + _rotl64(v3, 12)
            + _rotl64(v4, 18)
        )
        hash = _xxh_merge_round(hash, v1)
        hash = _xxh_merge_round(hash, v2)
        hash = _xxh_merge_round(hash, v3)
        hash = _xxh_merge_round(hash, v4)
    else:
        # Short-input path: single accumulator seeded with P5.
        hash = _XXH_P5

    # Mix in length (always done after stripe loop / short-path init).
    hash = hash + UInt64(length)

    # Tail: drain 8-byte, 4-byte, 1-byte lanes.
    while pos + 8 <= length:
        var k1 = _xxh_round(0, _read_u64_le(p, pos))
        hash = hash ^ k1
        hash = _rotl64(hash, 27) * _XXH_P1 + _XXH_P4
        pos = pos + 8

    if pos + 4 <= length:
        hash = hash ^ (UInt64(_read_u32_le(p, pos)) * _XXH_P1)
        hash = _rotl64(hash, 23) * _XXH_P2 + _XXH_P3
        pos = pos + 4

    while pos < length:
        hash = hash ^ (UInt64((p + pos)[]) * _XXH_P5)
        hash = _rotl64(hash, 11) * _XXH_P1
        pos = pos + 1

    return _xxh_avalanche(hash)


@always_inline
def xxhash64_int64(value: Int64) -> UInt64:
    """Compute xxHash64(seed=0) of an Int64 value serialized as 8 little-endian
    bytes. Equivalent to laying out `value` into an 8-byte buffer (LE)
    and calling `xxhash64(Span(buf))`.

    Args:
        value: 64-bit signed integer.

    Returns:
        64-bit hash; matches the reference impl's output for the same
        8 LE bytes.
    """
    # Hot path: short-input (8 bytes) skips the stripe loop. Inline the
    # 8-byte tail directly to avoid pointer alloc + memcpy overhead.
    var hash = _XXH_P5 + UInt64(8)
    var k1 = _xxh_round(0, UInt64(value))
    hash = hash ^ k1
    hash = _rotl64(hash, 27) * _XXH_P1 + _XXH_P4
    return _xxh_avalanche(hash)


# =============================================================================
# FNV-1a hash — LEGACY (older writer versions; current writers use xxHash64)
# =============================================================================
# Kept for backward compatibility with Parquet files written by an older
# version of this project's writer. New files always use xxHash64. Detection
# on the read side is via FileMetaData.created_by (writer version prefix in
# `bloom_reader.detect_hash_family`).
# =============================================================================


@always_inline
def _fnv1a_hash(data: Span[UInt8, _]) -> UInt64:
    """FNV-1a 64-bit hash. LEGACY — use xxhash64 for new code.

    Args:
        data: The bytes to hash.

    Returns:
        64-bit hash value.
    """
    var hash = UInt64(0xCBF29CE484222325)
    comptime fnv_prime = UInt64(0x00000100000001B3)
    for i in range(len(data)):
        hash = hash ^ UInt64(data[i])
        hash = hash * fnv_prime
    return hash


@always_inline
def _fnv1a_hash_int64(value: Int64) -> UInt64:
    """FNV-1a hash of a single Int64 value (little-endian bytes). LEGACY.

    Args:
        value: The Int64 value to hash.

    Returns:
        64-bit hash value.
    """
    var hash = UInt64(0xCBF29CE484222325)
    comptime fnv_prime = UInt64(0x00000100000001B3)
    var v = UInt64(value)
    for _ in range(8):
        hash = hash ^ (v & 0xFF)
        hash = hash * fnv_prime
        v = v >> 8
    return hash


# =============================================================================
# Fibonacci join hash (engine-internal hash-join bloom, HashFamily.FIBONACCI_JOIN)
# =============================================================================
# The in-memory hash-join probe already computes a Fibonacci multiply-xor-fold
# of the Int64 key to derive the hash-table bucket. Building the semi-join
# bloom from the SAME hash lets the probe reuse ONE hash for both the bloom
# pre-check (`check_hash`) and the HT slot — killing a redundant xxHash64 per
# probe row. `_join_fib_hash` MUST stay byte-identical to
# `komira_engine_operators.join._hash_join_key` (and its siblings in
# hash_index / row_hash_agg), which all share `_JOIN_FIB_HASH_CONST`; the
# `insert_int64` / `check_hash` byte-equivalence is guarded by the join
# semi/anti byte-identity tests and the FIBONACCI_JOIN no-false-negative unit
# test. This hash is NEVER serialized to a Parquet file.
# =============================================================================

comptime _JOIN_FIB_HASH_CONST: UInt64 = 0x9E3779B97F4A7C15


@always_inline
def _join_fib_hash(value: Int64) -> UInt64:
    """Fibonacci multiply-xor-fold hash of an Int64 join key.

    Byte-identical to `join._hash_join_key`: multiply by the 64-bit golden
    ratio constant, then fold the high half into the low half. Used by the
    HashFamily.FIBONACCI_JOIN bloom family.

    Args:
        value: The Int64 join key.

    Returns:
        64-bit hash. Upper 32 bits select the SBBF block; lower 32 bits drive
        the 8 probe bit positions (via the per-salt multiply in `_block_mask_simd`).
    """
    var h = UInt64(value) * _JOIN_FIB_HASH_CONST
    h = h ^ (h >> 32)
    return h


# =============================================================================
# Block operations — compute mask, insert, check
# =============================================================================
# A Block is 8 x u32 words (256 bits). For each operation, we compute
# a mask where each of the 8 words has exactly one bit set, determined
# by multiplying the lower 32 bits of the hash with the corresponding
# salt and taking the top 5 bits as the bit index.
# =============================================================================


@always_inline
def _block_mask_word(x: UInt32, salt: UInt32) -> UInt32:
    """Compute one mask word: set the bit at position (x * salt) >> 27.

    Args:
        x: Lower 32 bits of the hash.
        salt: The salt constant for this word position.

    Returns:
        A UInt32 with exactly one bit set.
    """
    var y = x * salt
    return UInt32(1) << (y >> 27)


@always_inline
def _block_mask_simd(x: UInt32) -> SIMD[DType.uint32, WORDS_PER_BLOCK]:
    """Compute the 8-lane SIMD mask vector: lane i = `1 << ((x * SALT_i) >> 27)`.

    Returns the per-word probe mask for all 8 SBBF salts as one SIMD vector.
    Each lane has exactly one bit set. SIMD-parallel form of `_block_mask_word`
    invoked across SALT_0..SALT_7. The 8 salts are encoded as a comptime
    SIMD vector below; LLVM constant-folds the broadcast / construction so
    the per-call cost is the multiply, the shift-right-by-27, and a
    `1 << shift` (all SIMD-vectorized).

    Args:
        x: Lower 32 bits of the hash (broadcast to all 8 lanes).

    Returns:
        SIMD[uint32, 8] where lane i = `_block_mask_word(x, SALT_i)`.
    """
    # Per-lane salt vector. Per-lane assignment compiles to a SIMD literal
    # the optimizer can hoist and constant-fold (see `comptime` salts above).
    var salts = SIMD[DType.uint32, WORDS_PER_BLOCK](0)
    salts[0] = SALT_0
    salts[1] = SALT_1
    salts[2] = SALT_2
    salts[3] = SALT_3
    salts[4] = SALT_4
    salts[5] = SALT_5
    salts[6] = SALT_6
    salts[7] = SALT_7
    var x_vec = SIMD[DType.uint32, WORDS_PER_BLOCK](x)
    var y_vec = x_vec * salts            # 8 multiplies in one SIMD op
    var shift_vec = y_vec >> 27          # 8 shifts in one SIMD op
    var one_vec = SIMD[DType.uint32, WORDS_PER_BLOCK](1)
    return one_vec << shift_vec          # 8 left-shifts in one SIMD op


@always_inline
def _block_insert[
    origin: Origin[mut=True], //,
](block_view: ByteView[mut=True, origin], x: UInt32):
    """Set all bits identified by the 8-salt mask in this block.

    SIMD form: the block is 32 bytes = 8 x UInt32 — load it
    as one `SIMD[uint32, 8]`, OR in the 8-lane salt-mask vector, store it back.
    This is the write-side mirror of `_block_check`'s `load_simd` / `_block_mask_simd`
    / reduce shape: 8 scalar load + 8 scalar OR + 8 scalar store → 1 wide load +
    1 wide OR + 1 wide store. `@always_inline` keeps the SIMD lanes off the
    function-call boundary so the OR fuses into the load/store pair.
    """
    var block_vec = block_view.load_simd[DType.uint32, WORDS_PER_BLOCK](0)
    var mask_vec = _block_mask_simd(x)
    block_view.store_simd[DType.uint32, WORDS_PER_BLOCK](0, block_vec | mask_vec)


@always_inline
def _block_insert_atomic[
    origin: Origin[mut=True], //,
](block_view: ByteView[mut=True, origin], x: UInt32):
    """CONCURRENCY-SAFE `_block_insert`: set the same 8-salt mask bits, but with
    ONE lock-free compare-exchange PER 32-BIT WORD instead of a wide
    load / OR / store.

    ⚠ WHY THIS EXISTS, AND WHY `_block_insert` MUST NOT BE USED CONCURRENTLY.
    `_block_insert`'s load-OR-store is a read-modify-write of 32 bytes. Two
    threads inserting into the SAME block interleave as a classic lost update:
    B's store, computed from a block image read before A's store, ERASES A's
    bits. A lost bloom bit is a FALSE NEGATIVE, and a false negative in a join
    bloom is a probe row that skips a chain walk it should have taken — i.e. a
    SILENTLY DROPPED MATCH, no crash, no assertion, a plausible-looking answer.
    The whole point of an SBBF is that it is false-positive-only; a concurrent
    `_block_insert` breaks exactly that property.

    Per-word CAS restores it. Bloom insertion is a pure monotone OR, and OR is
    associative + commutative + idempotent, so the resulting bitset is
    INDEPENDENT of the interleaving and byte-identical to any serial insertion
    order of the same hash set. (`or_range_from` above relies on the same
    algebra for its OR-reduce.)

    32-BIT WORDS, NOT 64 — deliberately. The SBBF block is defined as 8 x u32
    and the salt masks are per-u32-word; pairing lanes into u64 would bake in a
    LITTLE-ENDIAN assumption about which u32 lane is the low half. Word-at-a-time
    CAS has no endianness dependency at all.

    The `new == old` early-out is not an optimisation detail — it is the common
    case once the filter has warmed (every bit of this row's mask already set by
    an earlier row), and it makes the hot path a plain load with no bus lock.
    """
    var mask_vec = _block_mask_simd(x)
    # SAFETY: `block_view` spans exactly `BLOCK_SIZE_BYTES` (== 8 * 4) bytes of
    # the filter's own buffer, which `insert_hash_atomic` sized and range-checked;
    # the pointer is consumed inside this function and never escapes. The buffer
    # is 64-byte aligned by `OwnedAlignedBuffer`, so each u32 word is naturally
    # aligned and its CAS is a single uncontended-fast-path atomic on every
    # supported target.
    var wp = block_view._unsafe_ptr().bitcast[Scalar[DType.uint32]]()
    for w in range(WORDS_PER_BLOCK):
        var m = mask_vec[w]
        while True:
            var old = (wp + w)[]
            var new = old | m
            if new == old:
                break
            if AtomicU32.compare_exchange(wp + w, old, new):
                break


@always_inline
def _block_check[
    _mut: Bool, origin: Origin[mut=_mut], //,
](block_view: ByteView[origin], x: UInt32) -> Bool:
    """Check that all bits identified by the 8-salt mask are set.

    SIMD bulk 8-hash probe: the block (32 bytes = 8 x UInt32) loads as one
    `SIMD[uint32, 8]`; the 8-lane mask vector is `_block_mask_simd(x)`.
    Probe passes iff every lane of `block AND mask` is non-zero. Trades
    a scalar cascade's early-exit behavior on misses for SIMD ALU throughput
    (one wide AND + one reduce-min == 0 vs up to 8 dependent loads + ANDs
    + branches), which wins when the bloom hit rate is non-trivial.

    Args:
        block_view: View over the block's 8 x UInt32 words (32 bytes).
        x: Lower 32 bits of the hash.

    Returns:
        True if all 8 probe bits are set (possibly present).
        False if any probe bit is not set (definitely not present).
    """
    # SAFETY: ByteView.load_simd uses `alignment=1` (unaligned load), so
    # the 32-byte block does not need natural alignment — modern x86/ARM
    # handle unaligned 32-byte loads at full throughput. The block is in
    # fact 32-byte aligned by construction (BLOCK_SIZE_BYTES=32 and the
    # underlying MmapAlignedBuffer is 64-byte aligned), but we don't depend
    # on that here.
    var block_vec = block_view.load_simd[DType.uint32, WORDS_PER_BLOCK](0)
    var mask_vec = _block_mask_simd(x)
    var anded = block_vec & mask_vec
    # Probe passes iff every lane is non-zero. `reduce_min() == 0` <=>
    # at least one lane is zero <=> at least one probe bit was missing.
    return anded.reduce_min() != 0


# =============================================================================
# BloomFilter
# =============================================================================


struct BloomFilter(Movable):
    """Split Block Bloom Filter for Parquet predicate pushdown.

    A probabilistic data structure used for predicate pushdown: if the
    filter says a value is definitely NOT in a row group, we can skip
    reading that row group entirely. False positives are possible (filter
    says "maybe present" when it isn't), but false negatives are not
    (if a value was inserted, might_contain always returns True).

    The filter is divided into 256-bit (32-byte) blocks. Each block
    contains 8 x 32-bit words. Insert/check operations hash the value,
    select a block using the upper 32 bits, then set/check 8 bit
    positions using 8 salt constants.

    Fields:
        data: The filter bitset stored in an aligned buffer. Each 32-byte
            chunk is one block (8 x UInt32 words in little-endian order).
        num_blocks: Number of 32-byte blocks in the filter.
        num_bytes: Total size of the bitset in bytes.
        hash_family: Which hash function maps values to SBBF positions.
            Default: XXHASH64 (parquet-format spec-canonical). FNV1A is
            the LEGACY mode used by files from older writer versions;
            read-side detects via `created_by` version prefix.
    """

    var data: OwnedAlignedBuffer
    var num_blocks: Int
    var num_bytes: Int
    var hash_family: HashFamily

    def __init__(out self):
        """Create an empty, zero-sized bloom filter (default xxHash64)."""
        self.data = OwnedAlignedBuffer(0)
        self.num_blocks = 0
        self.num_bytes = 0
        self.hash_family = HashFamily.xxhash64()

    def copy(self) -> Self:
        """Explicit deep copy: clone the bitset bytes into a fresh buffer.

        Used for static blooms over a column's distinct values that are
        refcount-shared via `ArcPointer[BloomFilter]`.
        BloomFilter remains `Movable`-only (no `Copyable` trait) — this
        method is the ExplicitlyCopyable-style escape hatch.
        """
        var bf = BloomFilter()
        bf.hash_family = self.hash_family
        if self.num_bytes > 0:
            var buf = OwnedAlignedBuffer(self.num_bytes)
            buf.copy_from_view(self.data.view_range_ro(0, self.num_bytes))
            buf.set_length(Int64(self.num_bytes))

            bf.data = buf^
            bf.num_bytes = self.num_bytes
            bf.num_blocks = self.num_blocks
        return bf^

    @staticmethod
    def create(
        num_bytes: Int,
        hash_family: HashFamily = HashFamily.xxhash64(),
    ) -> BloomFilter:
        """Create a new bloom filter with the given number of bytes.

        The actual size is rounded up to the next power of two,
        clamped to [32, 128 MiB], and must be a multiple of 32.

        Args:
            num_bytes: Requested size in bytes.
            hash_family: Hash function (default xxHash64, spec-canonical).

        Returns:
            A new zero-initialized BloomFilter.
        """
        var actual = _optimal_num_bytes(num_bytes)
        var buf = OwnedAlignedBuffer(actual)
        # `MmapAlignedBuffer.zero()` is a memset with no raw pointer
        # escape. `zero()` sets length to capacity; we overwrite with
        # `actual` below.
        buf.zero()
        buf.set_length(Int64(actual))

        var bf = BloomFilter()
        bf.data = buf^
        bf.num_bytes = actual
        bf.num_blocks = actual // BLOCK_SIZE_BYTES
        bf.hash_family = hash_family
        return bf^

    @staticmethod
    def with_ndv_fpp(
        ndv: Int,
        fpp: Float64,
        hash_family: HashFamily = HashFamily.xxhash64(),
    ) -> BloomFilter:
        """Create a filter sized for the given NDV and false positive probability.

        Uses the formula: m = -k * n / ln(1 - fpp^(1/k)) where k = 8.

        Args:
            ndv: Expected number of distinct values.
            fpp: Target false positive probability (0.0 < fpp < 1.0).
            hash_family: Hash function (default xxHash64).

        Returns:
            A new BloomFilter sized appropriately.
        """
        from std.math import log, pow

        var k = 8.0
        var num_bits = -k * Float64(ndv) / log(1.0 - pow(fpp, 1.0 / k))
        var num_bytes = Int(num_bits) // 8
        return BloomFilter.create(num_bytes, hash_family)

    @staticmethod
    def from_bytes(
        raw: Span[UInt8, _],
        hash_family: HashFamily = HashFamily.xxhash64(),
    ) -> BloomFilter:
        """Construct from raw bloom filter bytes read from a Parquet file.

        The bytes are the raw little-endian bitset (no Thrift header).
        Each 32-byte chunk is one block.

        Args:
            raw: The raw bitset bytes; its length is the bitset size.
            hash_family: Hash function used by the writer (default xxHash64).

        Returns:
            A BloomFilter wrapping the provided data.
        """
        var num_bytes = len(raw)
        var actual = max(num_bytes, BITSET_MIN_BYTES)
        # Round up to next multiple of 32.
        actual = ((actual + BLOCK_SIZE_BYTES - 1) // BLOCK_SIZE_BYTES) * BLOCK_SIZE_BYTES
        var buf = OwnedAlignedBuffer(actual)
        # komira_buffer has no ByteView over a Span, so the copy is a
        # memcpy between the two views' start pointers.
        if num_bytes > 0:
            var copy_n = min(num_bytes, actual)
            # SAFETY: `buf` outlives this call and `copy_n <= actual` is
            # its length; `raw` is a borrowed Span of `num_bytes >= copy_n`
            # bytes, alive for this call, and cannot alias the fresh `buf`.
            # Neither pointer escapes.
            unsafe_memcpy(
                dest=buf.view_range_mut(0, copy_n)._unsafe_ptr(),
                src=raw.unsafe_ptr(),
                count=copy_n,
            )
        # Zero any padding using fill.
        if actual > num_bytes:
            buf.view_range_mut(num_bytes, actual - num_bytes).fill(0)
        buf.set_length(Int64(actual))

        var bf = BloomFilter()
        bf.data = buf^
        bf.num_bytes = actual
        bf.num_blocks = actual // BLOCK_SIZE_BYTES
        bf.hash_family = hash_family
        return bf^

    @always_inline
    def hash_int64(self, value: Int64) -> UInt64:
        """Hash an Int64 value using this filter's `hash_family`.

        Args:
            value: The value to hash.

        Returns:
            64-bit hash.
        """
        if self.hash_family.is_fibonacci_join():
            return _join_fib_hash(value)
        if self.hash_family.is_xxhash64():
            return xxhash64_int64(value)
        return _fnv1a_hash_int64(value)

    @always_inline
    def hash_bytes(self, data: Span[UInt8, _]) -> UInt64:
        """Hash a byte array using this filter's `hash_family`.

        Args:
            data: The bytes to hash.

        Returns:
            64-bit hash.
        """
        if self.hash_family.is_xxhash64():
            return xxhash64(data)
        return _fnv1a_hash(data)

    @always_inline
    def insert_hash(mut self, hash: UInt64):
        """Insert a pre-computed hash into the filter.

        Args:
            hash: 64-bit hash value. Upper 32 bits select the block,
                lower 32 bits determine the 8 probe positions.
        """
        var block_idx = self._hash_to_block_index(hash)
        # 32-byte block view (8 x UInt32) over MmapAlignedBuffer.
        var block_view = self.data.view_range_mut(
            block_idx * BLOCK_SIZE_BYTES, BLOCK_SIZE_BYTES
        )
        _block_insert(block_view, UInt32(hash & 0xFFFFFFFF))

    @always_inline
    def insert_hash_atomic(mut self, hash: UInt64):
        """`insert_hash`, safe to call CONCURRENTLY on one filter.

        Same block index (`_hash_to_block_index`) and same 8-salt mask
        (`_block_mask_simd`) as `insert_hash` — this method differs ONLY in HOW
        the mask reaches memory (`_block_insert_atomic`'s per-word
        compare-exchange instead of `_block_insert`'s wide load / OR / store).
        Sharing both derivations rather than re-deriving them is deliberate: a
        bloom whose writer computes a different block index or a different mask
        than `check_hash` reads is a false negative, and a false negative here
        is a silently dropped join match. The two paths are pinned byte-equal by
        a test.

        The bits written are a monotone OR, so the final bitset does not depend
        on the interleaving: inserting a set of hashes through this method from
        N threads yields the SAME bytes as inserting them through `insert_hash`
        one at a time, in any order.

        Args:
            hash: 64-bit hash value. Upper 32 bits select the block,
                lower 32 bits determine the 8 probe positions.
        """
        var block_idx = self._hash_to_block_index(hash)
        var block_view = self.data.view_range_mut(
            block_idx * BLOCK_SIZE_BYTES, BLOCK_SIZE_BYTES
        )
        _block_insert_atomic(block_view, UInt32(hash & 0xFFFFFFFF))

    def insert_int64(mut self, value: Int64):
        """Insert an Int64 value into the filter.

        Hash function dispatches on `self.hash_family` — XXHASH64 by
        default (spec), FNV1A for legacy files from older writers.

        Args:
            value: The value to insert.
        """
        self.insert_hash(self.hash_int64(value))

    @always_inline
    def insert_join_key(mut self, value: Int64, fib_hash: UInt64):
        """Insert a join key, reusing the caller's precomputed Fibonacci hash.

        Build-side mirror of `might_contain_join_key`. When this filter is a
        HashFamily.FIBONACCI_JOIN bloom, the caller has already computed
        `fib_hash = _hash_join_key(value)` for the hash-table bucket, so we
        write the bloom bits directly from it (no re-hash). For any other
        family we fall back to `insert_int64(value)`, which dispatches to the
        family's own hash — so a caller may pass this on either the ON
        (FIBONACCI_JOIN) or OFF (xxHash64) kill-switch path and stay correct.

        Args:
            value: The Int64 join key.
            fib_hash: `_join_fib_hash(value)` precomputed by the caller. Ignored
                unless the family is FIBONACCI_JOIN.
        """
        if self.hash_family.is_fibonacci_join():
            self.insert_hash(fib_hash)
        else:
            self.insert_int64(value)

    def insert_bytes(mut self, data: Span[UInt8, _]):
        """Insert a byte array value into the filter.

        Hash function dispatches on `self.hash_family`.

        Args:
            data: The bytes to insert.
        """
        self.insert_hash(self.hash_bytes(data))

    @always_inline
    def check_hash(self, hash: UInt64) -> Bool:
        """Check whether a pre-computed hash is possibly present.

        Args:
            hash: 64-bit hash value.

        Returns:
            False if the value is definitely not present.
            True if the value is possibly present (may be false positive).
        """
        var block_idx = self._hash_to_block_index(hash)
        # 32-byte block view (8 x UInt32) over MmapAlignedBuffer.
        var block_view = self.data.view_range_ro(
            block_idx * BLOCK_SIZE_BYTES, BLOCK_SIZE_BYTES
        )
        return _block_check(block_view, UInt32(hash & 0xFFFFFFFF))

    def might_contain_int64(self, value: Int64) -> Bool:
        """Check if an Int64 value MIGHT be in the set.

        False means definitely not present. True means possibly present
        (may be a false positive). Hash function dispatches on
        `self.hash_family` — must match the writer's hash family
        (xxHash64 for current files; FNV-1a for legacy files).

        Args:
            value: The value to check.

        Returns:
            False = definitely not present. True = possibly present.
        """
        return self.check_hash(self.hash_int64(value))

    @always_inline
    def might_contain_join_key(self, value: Int64, fib_hash: UInt64) -> Bool:
        """Membership check for a join key, reusing the precomputed Fibonacci hash.

        Probe-side mirror of `insert_join_key`. When this filter is a
        HashFamily.FIBONACCI_JOIN bloom, the probe has already computed
        `fib_hash = _hash_join_key(value)` for the hash-table bucket, so we
        check the bloom directly from it via `check_hash` — reusing that one
        hash and killing the xxHash64 `might_contain_int64` would otherwise
        recompute. For any other family we fall back to `might_contain_int64`,
        which re-hashes with the family's own hash. Correct on both the ON
        (FIBONACCI_JOIN) and OFF (xxHash64) kill-switch paths because the
        dispatch is on THIS bloom's own `hash_family` — build and probe can
        never disagree.

        Args:
            value: The Int64 join key.
            fib_hash: `_join_fib_hash(value)` precomputed by the caller. Ignored
                unless the family is FIBONACCI_JOIN.

        Returns:
            False = definitely not present. True = possibly present.
        """
        if self.hash_family.is_fibonacci_join():
            return self.check_hash(fib_hash)
        return self.might_contain_int64(value)

    def might_contain_bytes(self, data: Span[UInt8, _]) -> Bool:
        """Check if a byte array value MIGHT be in the set.

        Hash function dispatches on `self.hash_family`.

        Args:
            data: The bytes to check.

        Returns:
            False = definitely not present. True = possibly present.
        """
        return self.check_hash(self.hash_bytes(data))

    def merge_or_range[
        _mut: Bool, o_other: Origin[mut=_mut], //,
    ](
        mut self,
        ref [o_other] other: BloomFilter,
        byte_start: Int,
        byte_len: Int,
    ):
        """OR a byte range of `other.data` into `self.data` in place.

        Primitive for
        the parallel OR-reduce phase of `HashBuildSink.combine`'s
        per-worker shadow blooms. Each reducer task is assigned a disjoint
        `[byte_start, byte_start+byte_len)` window of the global filter
        and ORs every other worker's shadow into worker 0's slot.

        SAFETY: `self.num_bytes == other.num_bytes` is required (both
        sized by the same `with_ndv_fpp(n, fpp)` call). `byte_start +
        byte_len <= num_bytes`. Byte-OR is associative + commutative +
        idempotent, so concurrent OR-reduce tasks operating on disjoint
        byte windows produce a deterministic result independent of
        task ordering.

        Args:
            other: The source bloom filter (per-worker shadow).
            byte_start: Starting byte offset in this filter.
            byte_len: Number of bytes to OR.
        """
        # Bulk OR over the byte range. SIMD-vectorize the u64 stride so
        # each iteration ORs `width` u64 lanes at once (~4 lanes on AVX2,
        # ~8 on AVX-512, ~2 on NEON). The 32-byte block alignment
        # guarantees natural 8-byte alignment for any block-aligned
        # `byte_start`; the SIMD load/store paths use unaligned ops
        # (alignment=1) so larger SIMD-width alignment is not required.
        # Same shape as `_simd_sum`, with `|`
        # in place of `+`. The scalar tail handles `u64_count % width`
        # leftover u64s; the byte-tail handles `byte_len % 8` leftover
        # bytes (unreachable in practice — block size is 32 — kept for
        # safety against future block-size changes).
        comptime W = simd_width_of[DType.uint64]()
        # Origin-tied via function-scope view locals on `self.data` (mut)
        # and `other.data` (ro); NLL releases both borrows at end-of-function
        # before the implicit return.
        var dst_view = self.data.view_mut()
        var src_view = other.data.view_ro()
        var dst_u64 = dst_view._unsafe_ptr().bitcast[Scalar[DType.uint64]]()
        var src_u64 = src_view._unsafe_ptr().bitcast[Scalar[DType.uint64]]()
        var u64_start = byte_start // 8
        var u64_count = byte_len // 8
        var simd_end = (u64_count // W) * W
        var i = 0
        while i < simd_end:
            # SAFETY: `u64_start + i + W <= u64_start + u64_count`, which
            # is `(byte_start + byte_len) // 8 <= num_bytes // 8`. Both
            # sides have the same `num_bytes` per the docstring's SAFETY
            # invariant. Unaligned 64-bit lane loads/stores at full
            # throughput on x86 and ARM.
            var d_vec = (dst_u64 + u64_start + i).load[width=W](0)
            var s_vec = (src_u64 + u64_start + i).load[width=W](0)
            (dst_u64 + u64_start + i).store[width=W](0, d_vec | s_vec)
            i += W
        # Scalar tail: u64s past `simd_end` (count = u64_count % W).
        while i < u64_count:
            (dst_u64 + u64_start + i)[] = (
                (dst_u64 + u64_start + i)[] | (src_u64 + u64_start + i)[]
            )
            i += 1
        # Tail bytes (if byte_len is not 8-aligned). Block size is 32
        # bytes so this is unreachable in practice; keep the loop for
        # safety against future block-size changes.
        var tail_start = byte_start + u64_count * 8
        var tail_end = byte_start + byte_len
        # Same view locals reused — re-bitcast to uint8 for byte-tail.
        var dst_u8 = dst_view._unsafe_ptr()
        var src_u8 = src_view._unsafe_ptr()
        for j in range(tail_start, tail_end):
            (dst_u8 + j)[] = (dst_u8 + j)[] | (src_u8 + j)[]

    @always_inline
    def _hash_to_block_index(self, hash: UInt64) -> Int:
        """Map a 64-bit hash to a block index.

        Uses the upper 32 bits to select the block:
        index = ((hash >> 32) * num_blocks) >> 32

        This avoids modulo and distributes evenly across blocks.

        Args:
            hash: 64-bit hash value.

        Returns:
            Block index in [0, num_blocks).
        """
        var upper = hash >> 32
        return Int((upper * UInt64(self.num_blocks)) >> 32)


# =============================================================================
# Sizing helpers
# =============================================================================


def _optimal_num_bytes(num_bytes: Int) -> Int:
    """Round to next power of two, clamped to [32, 128 MiB].

    Args:
        num_bytes: Requested number of bytes.

    Returns:
        The optimal buffer size.
    """
    var n = max(num_bytes, BITSET_MIN_BYTES)
    n = min(n, BITSET_MAX_BYTES)
    # Round up to next power of two.
    var result = BITSET_MIN_BYTES
    while result < n:
        result = result * 2
    return result
