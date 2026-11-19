# =============================================================================
# bloom_filter.mojo — ORC classic Bloom filter (hash kernels + bitset).
# =============================================================================
#
# ORC uses a HYBRID hash family (not "Murmur3 only"). This module implements
# it exactly so probes match what an ORC writer (orc-cpp / orc-java / Hive)
# produced:
#
#   - bytes / strings / binary : Murmur3-64           (orc-cpp BloomFilter.cc:118)
#   - int8 / int16 / int32 / int64 : Thomas Wang 64-bit int hash
#                                                      (orc-cpp BloomFilter.hh:194-207)
#   - float / double : reinterpret bit-pattern as int64, then Wang64
#                                                      (orc-cpp BloomFilter.cc:202-203)
#
# The single 64-bit hashcode then feeds the Kirsch-Mitzenmacher "Less Hashing,
# Same Performance" double-hashing combiner (orc-cpp BloomFilter.cc:212-248):
#   hash1 = low-32 of the 64-bit hash
#   hash2 = high-32 of the 64-bit hash (unsigned shift)
#   for i in 1..k: combinedHash = hash1 + i*hash2; if < 0, ~combinedHash;
#                  pos = combinedHash % numBits; set/test bit pos.
#
# The on-disk bitset is `utf8bitset`: a little-endian uint64[] serialized as
# raw bytes (8 bytes per word, LSB first). numBits = len(words) * 64.
#
# Encapsulation: the public surface (OrcBloomFilter) takes/returns typed values
# (Int64 / Span[UInt8] / List[UInt8]) only. Internal byte<->word packing uses
# plain index arithmetic on List[UInt8]; no UnsafePointer crosses the module
# boundary, no wildcard origins. Hash kernels are pure scalar arithmetic.
#
# Substrate note: Parquet's SBBF (XXH64 + 256-bit blocks) is wire-incompatible
# with ORC classic bloom (different hash families + flat-bitset geometry). This
# is a from-scratch impl, NOT a reuse of the Parquet bloom filter. Only the
# *concept* of a hash kernel is shared.
# =============================================================================

from std.memory import bitcast


# =============================================================================
# Reinterpret a 32-bit two's-complement word as signed, WITHOUT a same-width
# signed cast.
# =============================================================================
#
# ⛔ DO NOT "SIMPLIFY" THIS BACK TO `Int64(Int32(<uint32 value>))`.
#
# On Mojo 1.0.0b2 `WIDEN(IntW(<UIntW value>))` silently drops the sign
# extension — the compiler folds sext(trunc(zext(x))) to zext(x) at EVERY
# optimization level, JIT and AOT. The Kirsch-Mitzenmacher combiner below is a
# VERBATIM port of orc-cpp `BloomFilter.cc:212-248`, whose whole point is that
# `hash1`/`hash2` are SIGNED 32-bit ints so that `combinedHash < 0` can fire and
# flip via `~combinedHash`. With the fold, `hash1`/`hash2` are always in
# [0, 2^32) and THE NEGATIVE-FLIP BRANCH IS UNREACHABLE, so the filter computes
# different bit positions than orc-cpp/orc-java for ~half of all hashes.
#
# A write->read round trip within this package stays self-consistent under
# that defect (both `_add_hash` and `_test_hash` would carry it), so no
# round-trip test can catch it. The broken contract is CROSS-TOOL: reading a
# bloom filter written by any other ORC implementation would produce FALSE
# NEGATIVES, and a false negative in a bloom filter is a SILENTLY DROPPED ROW
# during predicate pushdown.
#
# Pure Int64 arithmetic below — no narrow cast, so there is no trunc/ext pair to
# fold.
#
# ⚠ THE SIGN IS HALF THE CONTRACT. Sign-reinterpreting `hash1`/`hash2` makes
# the negative-flip branch REACHABLE, but the combiner's ARITHMETIC WIDTH must
# match too: orc-cpp and orc-java accumulate `hash1 + i*hash2` in a 32-bit
# signed int, which WRAPS; an Int64 accumulator does not, and puts the bits in
# different places for most keys — the same false-negative / silently-dropped-
# row consequence, invisible to round-trip tests. `orc_wrap_to_i32` below
# closes it; this package's bloom golden-vector test makes the claim
# checkable rather than self-referential.


@always_inline
def orc_sext_u32_to_i64(u: UInt32) -> Int64:
    """Reinterpret a 32-bit two's-complement word as a signed Int64.

    Equivalent to C++ `static_cast<int64_t>(static_cast<int32_t>(u))`, which is
    what orc-cpp's `(int) hash64` does.
    """
    var v = Int64(u)
    if v >= 0x8000_0000:
        return v - 0x1_0000_0000
    return v


@always_inline
def orc_wrap_to_i32(v: Int64) -> Int64:
    """Reduce an Int64 to what a C++ `int32_t` holding the same value would be.

    ⚠ WHY THIS EXISTS — THE SECOND HALF OF THE CROSS-TOOL CONTRACT.

    Getting the SIGN of `hash1`/`hash2` right is not enough. The combiner's
    ARITHMETIC WIDTH must match as well: orc-cpp and orc-java both compute the Kirsch-Mitzenmacher term in a 32-bit signed accumulator —

        int32_t combinedHash = hash1 + i * hash2;   // orc-cpp BloomFilter.cc
        int combinedHash = hash1 + ((i + 1) * hash2);  // Hive BloomFilter.java

    — which WRAPS. `hash1 + Int64(i) * hash2` in Int64 does not. `hash2` is a full-range signed 32-bit value, so `i * hash2`
    leaves int32 range for most hashes even at i = 1.

    Against an independent reimplementation of orc-cpp's algorithm (wang64
    over keys 0..1999, k = 7, numBits = 1024), the two spellings put the bits
    in DIFFERENT PLACES for most keys, and for many of them the divergence is
    already present at i = 1 alone — the exact term
    `test_orc_bloom_sext_combiner` probes, so that test alone cannot catch
    this. Key 0 diverges.

    Same consequence as the sign defect: a write->read round trip stays
    self-consistent (both `_add_hash` and `_test_hash` would carry it), while
    reading a bloom filter written by ANY other ORC implementation would
    produce FALSE NEGATIVES — and a false negative in a bloom filter is a
    SILENTLY DROPPED ROW in predicate pushdown. The bloom golden-vector test
    makes this checkable instead of self-referential.

    Implemented as a mask + explicit compare on Int64, NOT as
    `Int64(Int32(...))`. There is no trunc/ext pair here for the b2
    `sext(trunc(zext(x)))` fold to eat.
    """
    var low = v & 0xFFFF_FFFF
    if low >= 0x8000_0000:
        return low - 0x1_0000_0000
    return low


# =============================================================================
# Thomas Wang's 64-bit integer hash (orc-cpp BloomFilter.hh:194-207, verbatim).
# =============================================================================
#
#   uint64_t key = static_cast<uint64_t>(value);
#   key = (~key) + (key << 21);   // key = (key << 21) - key - 1;
#   key = key ^ (key >> 24);
#   key = (key + (key << 3)) + (key << 8);  // key * 265
#   key = key ^ (key >> 14);
#   key = (key + (key << 2)) + (key << 4);  // key * 21
#   key = key ^ (key >> 28);
#   key = key + (key << 31);
#   return static_cast<int64_t>(key);
#
# All arithmetic is unsigned 64-bit (wrapping). We compute in UInt64 and the
# combiner reinterprets the bits as needed.


@always_inline
def wang64_hash(value: Int64) -> UInt64:
    """Thomas Wang's 64-bit integer hash. Used by ORC for int8/16/32/64 and
    (via reinterpret) float/double."""
    var key = bitcast[DType.uint64, 1](value)
    key = (~key) + (key << 21)
    key = key ^ (key >> 24)
    key = (key + (key << 3)) + (key << 8)
    key = key ^ (key >> 14)
    key = (key + (key << 2)) + (key << 4)
    key = key ^ (key >> 28)
    key = key + (key << 31)
    return key


@always_inline
def wang64_hash_double(value: Float64) -> UInt64:
    """ORC's addDouble/testDouble: reinterpret the IEEE-754 bit pattern as
    int64, then Wang64 (orc-cpp BloomFilter.cc:202-203)."""
    var bits = bitcast[DType.int64, 1](value)
    return wang64_hash(bits)


# =============================================================================
# Murmur3 x64 64-bit hash (orc-cpp Murmur3.cc, the hash64 entry point).
# =============================================================================
#
# ORC's Murmur3::hash64 is the low 64 bits of the x64_128 algorithm with the
# default seed (DEFAULT_SEED = 104729). The orc-cpp implementation:
#
#   const uint64_t C1 = 0x87c37b91114253d5ULL;
#   const uint64_t C2 = 0x4cf5ad432745937fULL;
#   const int R1 = 31, R2 = 27, M = 5, N1 = 0x52dce729;
#   uint64_t h1 = seed;
#   process 8-byte blocks: k1 *= C1; k1 = rotl(k1, R1); k1 *= C2;
#       h1 ^= k1; h1 = rotl(h1, R2); h1 = h1*M + N1;
#   tail: k1 accumulated from remaining bytes (big-endian shift), *=C1, rotl R1,
#       *=C2, h1 ^= k1;
#   h1 ^= len; h1 = fmix64(h1); return h1;
#
# fmix64(h): h ^= h>>33; h *= 0xff51afd7ed558ccd; h ^= h>>33;
#            h *= 0xc4ceb9fe1a85ec53; h ^= h>>33;

comptime MURMUR3_DEFAULT_SEED: UInt64 = 104729


@always_inline
def _rotl64(x: UInt64, r: Int) -> UInt64:
    return (x << UInt64(r)) | (x >> UInt64(64 - r))


@always_inline
def _fmix64(h_in: UInt64) -> UInt64:
    var h = h_in
    h = h ^ (h >> 33)
    h = h * 0xFF51AFD7ED558CCD
    h = h ^ (h >> 33)
    h = h * 0xC4CEB9FE1A85EC53
    h = h ^ (h >> 33)
    return h


def murmur3_hash64(data: Span[UInt8, _]) -> UInt64:
    """Murmur3 x64 64-bit hash with ORC's default seed (104729). Used by ORC for
    string / binary keys (orc-cpp BloomFilter.cc:118)."""
    comptime C1: UInt64 = 0x87C37B91114253D5
    comptime C2: UInt64 = 0x4CF5AD432745937F
    comptime R1: Int = 31
    comptime R2: Int = 27
    comptime M: UInt64 = 5
    comptime N1: UInt64 = 0x52DCE729

    var length = len(data)
    var h1: UInt64 = MURMUR3_DEFAULT_SEED
    var nblocks = length // 8

    # Body: process 8-byte little-endian blocks.
    for i in range(nblocks):
        var base = i * 8
        var k1: UInt64 = 0
        for j in range(8):
            k1 |= UInt64(data[base + j]) << UInt64(8 * j)
        k1 = k1 * C1
        k1 = _rotl64(k1, R1)
        k1 = k1 * C2
        h1 = h1 ^ k1
        h1 = _rotl64(h1, R2)
        h1 = h1 * M + N1

    # Tail: remaining (length % 8) bytes, big-endian byte placement per orc-cpp.
    var tail_start = nblocks * 8
    var rem = length - tail_start
    var k1t: UInt64 = 0
    # orc-cpp: switch falls through from high byte to low, shifting each into
    # position (tail[n] << 8*n). Equivalent to little-endian accumulation.
    for j in range(rem):
        k1t |= UInt64(data[tail_start + j]) << UInt64(8 * j)
    if rem > 0:
        k1t = k1t * C1
        k1t = _rotl64(k1t, R1)
        k1t = k1t * C2
        h1 = h1 ^ k1t

    # Finalization.
    h1 = h1 ^ UInt64(length)
    h1 = _fmix64(h1)
    return h1


# =============================================================================
# OrcBloomFilter — classic flat-bitset Bloom with Kirsch-Mitzenmacher probing.
# =============================================================================
#
# Storage is a `List[UInt8]` of `numWords * 8` bytes (little-endian uint64
# words) = the on-disk `utf8bitset`. numBits = numWords * 64. The public API
# offers add/test for the three ORC key flavors (long / double / bytes) plus a
# bitset/byte accessor for round-trip + wire emission.


struct OrcBloomFilter(Copyable, Movable):
    """A classic ORC bloom filter (Murmur3/Wang + flat bitset + double-hashing).
    """

    var num_hash_functions: Int
    var bitset: List[UInt8]  # numWords*8 bytes, little-endian uint64 words

    def __init__(out self, num_hash_functions: Int, num_words: Int):
        """Construct an EMPTY bloom with `num_words` 64-bit words (all-zero)."""
        self.num_hash_functions = num_hash_functions
        self.bitset = List[UInt8]()
        for _i in range(num_words * 8):
            self.bitset.append(0)

    def __init__(
        out self, num_hash_functions: Int, var bitset: List[UInt8]
    ):
        """Construct from an existing little-endian uint64[] byte buffer (the
        on-disk `utf8bitset`). `len(bitset)` must be a multiple of 8."""
        self.num_hash_functions = num_hash_functions
        self.bitset = bitset^

    def copy(self) -> Self:
        return OrcBloomFilter(self.num_hash_functions, self.bitset.copy())

    @always_inline
    def num_bits(self) -> Int:
        return len(self.bitset) * 8

    # --- bit get/set on the little-endian word buffer ---

    @always_inline
    def _set_bit(mut self, pos: Int):
        # bit `pos` lives in word `pos // 64`, bit `pos % 64`. In the LE byte
        # layout that is byte `pos // 8`, bit `pos % 8`.
        var byte_idx = pos >> 3
        var bit_in_byte = pos & 7
        self.bitset[byte_idx] = self.bitset[byte_idx] | (UInt8(1) << UInt8(bit_in_byte))

    @always_inline
    def _get_bit(self, pos: Int) -> Bool:
        var byte_idx = pos >> 3
        var bit_in_byte = pos & 7
        return (self.bitset[byte_idx] >> UInt8(bit_in_byte)) & UInt8(1) != 0

    # --- Kirsch-Mitzenmacher combiner (orc-cpp BloomFilter.cc:212-248) ---
    #
    # hash1 = (int) hash64  (low 32 bits, sign-extended to int in orc-cpp)
    # hash2 = (int)(hash64 >>> 32)  (high 32 bits)
    # for i in 1..k:
    #   combinedHash = hash1 + i*hash2
    #   if combinedHash < 0: combinedHash = ~combinedHash
    #   pos = combinedHash % numBits

    def _add_hash(mut self, hash64: UInt64):
        var n = self.num_bits()
        if n == 0:
            return
        # Reinterpret low/high 32-bit halves as SIGNED 32-bit, then widen to a
        # signed 64-bit accumulator (matches orc-cpp's int hash1/hash2 + the
        # negative-flip semantics). This must go through
        # `orc_sext_u32_to_i64` — `Int64(Int32(<uint32>))` is miscompiled and
        # made the `combined < 0` branch below unreachable.
        var hash1 = orc_sext_u32_to_i64(UInt32(hash64 & 0xFFFFFFFF))
        var hash2 = orc_sext_u32_to_i64(UInt32((hash64 >> 32) & 0xFFFFFFFF))
        for i in range(1, self.num_hash_functions + 1):
            # `orc_wrap_to_i32` is LOAD-BEARING: orc-cpp/orc-java accumulate
            # this term in a 32-bit signed int, which WRAPS. Without it the bit
            # positions diverge for most keys. See that function's
            # docstring and the bloom golden-vector test.
            var combined = orc_wrap_to_i32(hash1 + Int64(i) * hash2)
            if combined < 0:
                combined = ~combined
            var pos = Int(combined % Int64(n))
            self._set_bit(pos)

    def _test_hash(self, hash64: UInt64) -> Bool:
        var n = self.num_bits()
        if n == 0:
            return True  # conservative: empty bloom can't disprove membership
        # Mirrors `_add_hash` exactly — see the banner.
        var hash1 = orc_sext_u32_to_i64(UInt32(hash64 & 0xFFFFFFFF))
        var hash2 = orc_sext_u32_to_i64(UInt32((hash64 >> 32) & 0xFFFFFFFF))
        for i in range(1, self.num_hash_functions + 1):
            # MUST mirror `_add_hash` exactly, INCLUDING the int32 wrap.
            var combined = orc_wrap_to_i32(hash1 + Int64(i) * hash2)
            if combined < 0:
                combined = ~combined
            var pos = Int(combined % Int64(n))
            if not self._get_bit(pos):
                return False
        return True

    # --- public add/test ---

    def add_long(mut self, value: Int64):
        self._add_hash(wang64_hash(value))

    def test_long(self, value: Int64) -> Bool:
        """True if `value` MIGHT be present (false positives possible). A False
        return is a PROOF of absence."""
        return self._test_hash(wang64_hash(value))

    def add_double(mut self, value: Float64):
        self._add_hash(wang64_hash_double(value))

    def test_double(self, value: Float64) -> Bool:
        return self._test_hash(wang64_hash_double(value))

    def add_bytes(mut self, data: Span[UInt8, _]):
        self._add_hash(murmur3_hash64(data))

    def test_bytes(self, data: Span[UInt8, _]) -> Bool:
        return self._test_hash(murmur3_hash64(data))

    def add_string(mut self, value: String):
        self.add_bytes(value.as_bytes())

    def test_string(self, value: String) -> Bool:
        return self.test_bytes(value.as_bytes())


# =============================================================================
# Sizing — orc-cpp BloomFilterImpl: numBits/numHashFunctions from (n, fpp).
# =============================================================================
#
# orc-cpp BloomFilter.cc:
#   optimalNumOfBits(n, fpp) = (int)(-n * ln(fpp) / (ln2)^2)
#   optimalNumOfHashFunctions(n, m) = max(1, round((m/n) * ln2))
# Then numBits is rounded UP to a multiple of 64 (whole uint64 words).


def _ln(x: Float64) -> Float64:
    """Natural log via the stdlib math intrinsic."""
    from std.math import log

    return log(x)


def bloom_optimal_num_bits(n: Int, fpp: Float64) -> Int:
    """Optimal bit count for `n` entries at false-positive rate `fpp`, rounded
    up to a whole uint64 word (multiple of 64)."""
    if n <= 0:
        return 64
    var ln2 = 0.6931471805599453
    var bits = -Float64(n) * _ln(fpp) / (ln2 * ln2)
    var nbits = Int(bits)
    if nbits < 64:
        nbits = 64
    # Round up to a multiple of 64.
    var rem = nbits % 64
    if rem != 0:
        nbits += 64 - rem
    return nbits


def bloom_optimal_num_hash_functions(n: Int, num_bits: Int) -> Int:
    """Optimal k for `n` entries in `num_bits` bits (orc-cpp)."""
    if n <= 0:
        return 1
    var ln2 = 0.6931471805599453
    var k = Int(round((Float64(num_bits) / Float64(n)) * ln2))
    if k < 1:
        k = 1
    # Clamp to the ceiling the READER enforces on BloomFilter.numHashFunctions
    # (footer.mojo) so the writer can never emit a file this
    # codebase then refuses. k is ~7 at the standard 1% FPP and ~30 at 1e-9; a
    # caller would have to ask for an absurd FPP to reach 64.
    if k > 64:
        k = 64
    return k


def make_orc_bloom_filter(expected_entries: Int, fpp: Float64) -> OrcBloomFilter:
    """Allocate an empty bloom sized for `expected_entries` at `fpp`."""
    var num_bits = bloom_optimal_num_bits(expected_entries, fpp)
    var k = bloom_optimal_num_hash_functions(expected_entries, num_bits)
    var num_words = num_bits // 64
    return OrcBloomFilter(k, num_words)
