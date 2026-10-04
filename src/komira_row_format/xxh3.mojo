# =============================================================================
# xxh3.mojo — xxh3-64 scalar reference hash for RowBlock keys
# =============================================================================
#
# Ports the xxh3-64 scalar reference variant from upstream xxHash
# (https://github.com/Cyan4973/xxHash, file `xxhash.h`). Single-header
# C reference; BSD-2-Clause licensed (see attribution block below).
#
# The hash behind `_hash_row_bytes` in `row_block.mojo` (consumers:
# RowHashAggTable / RowJoinBuildTable / RowJoinProbeState).
#
# Cross-version stability constraint:
#   * SCALAR REFERENCE variant ONLY. No SIMD-staged variants in this file.
#     SIMD (AVX2/AVX-512/NEON) emit different intermediate bytes on some
#     length buckets, breaking cross-architecture spill-restore +
#     cross-segment wire format. A SIMD-accelerated path would need to be
#     gated by a runtime CPU-feature check, with a reference-impl boundary
#     check at the spill/wire side.
#   * Determinism + reproducibility holds for inputs 0..240 bytes on any
#     little-endian architecture (Linux x86_64 + macOS arm64 are both LE).
#
# Scope:
#   * `_xxh3_64_dispatch(base, len, seed)` — internal entry consumed by
#     `row_block.mojo:_hash_row_bytes`. Takes a concrete-origin
#     `UnsafePointer[UInt8, o]`; pointer arithmetic stays inside this
#     module and the immediate sibling `row_block.mojo` (both private
#     `_`-prefixed names; raw pointers never cross a PUBLIC API).
#   * `xxh3_64_scalar_bytes(bytes: List[UInt8])` — public test/microbench
#     entry; takes a safe `List[UInt8]`, derives the byte pointer
#     internally. Used by `test_xxh3.mojo`.
#   * Length cap: 240 bytes. Row-format keys are bounded by composite-key
#     arity × column width; composite-30-I64 = 240 bytes is the practical
#     upper bound. The dispatcher itself does NOT raise on overrun (it
#     would silently route into the 129..240 path); the public entries
#     gate. The streaming long-key path (XXH3_hashLong_64b) would be
#     needed if STRING/BINARY row-keys exceed 240B.
#   * Seed: 0 (matches FNV-1a's constant-offset semantics; no per-session
#     seed reseeding).
#
# Algorithmic correspondence with upstream `xxhash.h`:
#
#     | Mojo function              | Upstream C function          |
#     | -------------------------- | ---------------------------- |
#     | `_xxh3_len_0`              | `XXH3_len_0to16_64b` (len=0) |
#     | `_xxh3_len_1to3`           | `XXH3_len_1to3_64b`          |
#     | `_xxh3_len_4to8`           | `XXH3_len_4to8_64b`          |
#     | `_xxh3_len_9to16`          | `XXH3_len_9to16_64b`         |
#     | `_xxh3_len_17to128`        | `XXH3_len_17to128_64b`       |
#     | `_xxh3_len_129to240`       | `XXH3_len_129to240_64b`      |
#     | `_xxh64_avalanche`         | `XXH64_avalanche`            |
#     | `_xxh3_avalanche`          | `XXH3_avalanche`             |
#     | `_xxh3_rrmxmx`             | `XXH3_rrmxmx`                |
#     | `_xxh3_mul128_fold64`      | `XXH3_mul128_fold64`         |
#     | `_xxh3_mix16b`             | `XXH3_mix16B`                |
#     | `_xxh3_k_secret`           | `XXH3_kSecret`               |
#
# Encapsulation invariants:
#   * Zero `UnsafePointer` in any PUBLIC function signature. The single
#     public entry `xxh3_64_scalar_bytes` accepts `List[UInt8]` (safe);
#     pointer arithmetic is confined to private (`_`-prefixed) helpers
#     including `_xxh3_64_dispatch`, which is consumed only by sibling
#     intra-package callers (`row_block.mojo:_hash_row_bytes` — itself
#     a `_`-prefixed private name).
#   * Zero wildcard origin. All UnsafePointers carry concrete origin `o`
#     propagated either from `_row_base_ptr_ro` (RowBlock path) or from
#     `List.unsafe_ptr()` (test path); both yield concrete origins.
#   * Zero `unsafe_from_address=Int(...)`.
#   * Zero ArcPointer.
#   * Every `UnsafePointer` carries a `# SAFETY:` comment.
#
# -----------------------------------------------------------------------------
# Upstream attribution:
#
#   xxHash - Extremely Fast Hash algorithm
#   Header File
#   Copyright (C) 2012-2023 Yann Collet
#
#   BSD 2-Clause License (https://www.opensource.org/licenses/bsd-license.php)
#
#   Redistribution and use in source and binary forms, with or without
#   modification, are permitted provided that the following conditions are
#   met:
#
#       * Redistributions of source code must retain the above copyright
#         notice, this list of conditions and the following disclaimer.
#       * Redistributions in binary form must reproduce the above
#         copyright notice, this list of conditions and the following
#         disclaimer in the documentation and/or other materials provided
#         with the distribution.
#
#   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
#   "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
#   LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
#   A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
#   OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
#   SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
#   LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
#   DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
#   THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
#   (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
#   OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
#   You can contact the author at:
#     - xxHash homepage: https://www.xxhash.com
#     - xxHash source repository: https://github.com/Cyan4973/xxHash
# -----------------------------------------------------------------------------

# Pure-byte primitive module — no imports of sibling row_format
# modules. This is the layering invariant: `row_block.mojo` calls into
# `xxh3.mojo`; `xxh3.mojo` operates only on raw byte spans (with
# concrete origin) and stdlib types. This avoids a circular import
# (`row_block.mojo` → `xxh3.mojo` → `row_block.mojo`) and keeps the
# hash kernel reusable for non-RowBlock byte sources (e.g. STRING
# inline payloads, future spill restore boundaries).


# =============================================================================
# Constants (verbatim from upstream `xxhash.h`)
# =============================================================================

# XXH3 64-bit primes (xxhash.h:4413 and the `XXH_PRIME64_*` family).
comptime _XXH_PRIME64_1: UInt64 = 0x9E3779B185EBCA87
comptime _XXH_PRIME64_2: UInt64 = 0xC2B2AE3D27D4EB4F
comptime _XXH_PRIME64_3: UInt64 = 0x165667B19E3779F9
comptime _XXH_PRIME64_4: UInt64 = 0x85EBCA77C2B2AE63
comptime _XXH_PRIME64_5: UInt64 = 0x27D4EB2F165667C5

# PRIME_MX1 / PRIME_MX2 — used in XXH3_avalanche and XXH3_rrmxmx
# (xxhash.h:4413-4414).
comptime _XXH_PRIME_MX1: UInt64 = 0x165667919E3779F9
comptime _XXH_PRIME_MX2: UInt64 = 0x9FB21C651E98DF25

# Length cap for the scalar reference port. xxh3 reference itself does
# not cap; we cap here because row-format keys are bounded well
# below this. There is no streaming long-key path.
comptime XXH3_MAX_KEY_LEN: Int = 240


# Precomputed little-endian u64 reads from XXH3_kSecret at the byte
# offsets the algorithm references. Each is the LE u64 of
# `XXH3_kSecret[off..off+8]` computed once at module-load time.
# Hot-path callers (`_read_le64_secret(off)`) dispatch to these via
# if/elif on `off`; for the runtime-computed offsets in the
# 129-240 mid-loop (`16*(i-8) + XXH3_MIDSIZE_STARTOFFSET = {3, 19, 35,
# 51, 67, 83, 99}`) the constants below cover all visited values.
#
# Bytes verified via Python:
#   python3 -c "import struct; secret = bytes([...]);
#       u64 = int.from_bytes(secret[off:off+8], 'little')"
# against the kSecret table at `_xxh3_k_secret`.
comptime _XXH3_SECRET_U64_0: UInt64 = 0xBE4BA423396CFEB8
comptime _XXH3_SECRET_U64_3: UInt64 = 0x81017CBE4BA42339
comptime _XXH3_SECRET_U64_8: UInt64 = 0x1CAD21F72C81017C
comptime _XXH3_SECRET_U64_16: UInt64 = 0xDB979083E96DD4DE
comptime _XXH3_SECRET_U64_19: UInt64 = 0xA44072DB979083E9
comptime _XXH3_SECRET_U64_24: UInt64 = 0x1F67B3B7A4A44072
comptime _XXH3_SECRET_U64_32: UInt64 = 0x78E5C0CC4EE679CB
comptime _XXH3_SECRET_U64_35: UInt64 = 0xD05A8278E5C0CC4E
comptime _XXH3_SECRET_U64_40: UInt64 = 0x2172FFCC7DD05A82
comptime _XXH3_SECRET_U64_48: UInt64 = 0x8E2443F7744608B8
comptime _XXH3_SECRET_U64_51: UInt64 = 0x9035E08E2443F774
comptime _XXH3_SECRET_U64_56: UInt64 = 0x4C263A81E69035E0
comptime _XXH3_SECRET_U64_64: UInt64 = 0xCB00C391BB52283C
comptime _XXH3_SECRET_U64_67: UInt64 = 0x65D088CB00C391BB
comptime _XXH3_SECRET_U64_72: UInt64 = 0xA32E531B8B65D088
comptime _XXH3_SECRET_U64_80: UInt64 = 0x4EF90DA297486471
comptime _XXH3_SECRET_U64_83: UInt64 = 0xEF19384EF90DA297
comptime _XXH3_SECRET_U64_88: UInt64 = 0xD8ACDEA946EF1938
comptime _XXH3_SECRET_U64_96: UInt64 = 0x3F349CE33F76FAA8
comptime _XXH3_SECRET_U64_99: UInt64 = 0xBBDCF93F349CE33F
comptime _XXH3_SECRET_U64_104: UInt64 = 0x1D4F0BC7C7BBDCF9
comptime _XXH3_SECRET_U64_112: UInt64 = 0x3159B4CD4BE0518A
comptime _XXH3_SECRET_U64_119: UInt64 = 0x7378D9C97E9FC831
# u32 reads at 0 and 4 are needed only by len_1to3.
comptime _XXH3_SECRET_U32_0: UInt32 = 0x396CFEB8
comptime _XXH3_SECRET_U32_4: UInt32 = 0xBE4BA423


# XXH3_kSecret — the 192-byte pseudorandom secret table (xxhash.h:4398-4411).
# This vector is a PUBLIC published constant; its bytes are load-bearing
# for cross-version reproducibility. Sourced verbatim from upstream.
def _xxh3_k_secret(i: Int) -> UInt8:
    """Return byte `i` of the published 192-byte XXH3_kSecret table.

    The byte layout MUST match `XXH3_kSecret` in upstream `xxhash.h`
    byte for byte. KAT tests assert this.

    Implementation note (Mojo 1.0.0b1): InlineArray's positional-literal
    constructor isn't available in this compiler version; we initialize
    via `fill=0` and explicitly assign each of the 192 bytes. The
    repetition is the price of compile-time correctness — the alternative
    (a 192-arm if/elif chain) is hot-path read-only and identical in
    behavior. LLVM constant-folds the InlineArray writes when `i` is a
    comptime constant; the per-byte writes amortize across hot-path calls
    once the function inlines.

    SAFETY: caller bounds `i ∈ [0, 192)`. Out-of-range indices return 0
    via the final fallthrough; production callers (`_xxh3_64_dispatch`'s
    per-bucket paths) never overrun.
    """
    var t = Array[UInt8, 192](fill=UInt8(0))
    # Row 0 — bytes 0..15
    t[0] = UInt8(0xB8); t[1] = UInt8(0xFE); t[2] = UInt8(0x6C); t[3] = UInt8(0x39)
    t[4] = UInt8(0x23); t[5] = UInt8(0xA4); t[6] = UInt8(0x4B); t[7] = UInt8(0xBE)
    t[8] = UInt8(0x7C); t[9] = UInt8(0x01); t[10] = UInt8(0x81); t[11] = UInt8(0x2C)
    t[12] = UInt8(0xF7); t[13] = UInt8(0x21); t[14] = UInt8(0xAD); t[15] = UInt8(0x1C)
    # Row 1 — bytes 16..31
    t[16] = UInt8(0xDE); t[17] = UInt8(0xD4); t[18] = UInt8(0x6D); t[19] = UInt8(0xE9)
    t[20] = UInt8(0x83); t[21] = UInt8(0x90); t[22] = UInt8(0x97); t[23] = UInt8(0xDB)
    t[24] = UInt8(0x72); t[25] = UInt8(0x40); t[26] = UInt8(0xA4); t[27] = UInt8(0xA4)
    t[28] = UInt8(0xB7); t[29] = UInt8(0xB3); t[30] = UInt8(0x67); t[31] = UInt8(0x1F)
    # Row 2 — bytes 32..47
    t[32] = UInt8(0xCB); t[33] = UInt8(0x79); t[34] = UInt8(0xE6); t[35] = UInt8(0x4E)
    t[36] = UInt8(0xCC); t[37] = UInt8(0xC0); t[38] = UInt8(0xE5); t[39] = UInt8(0x78)
    t[40] = UInt8(0x82); t[41] = UInt8(0x5A); t[42] = UInt8(0xD0); t[43] = UInt8(0x7D)
    t[44] = UInt8(0xCC); t[45] = UInt8(0xFF); t[46] = UInt8(0x72); t[47] = UInt8(0x21)
    # Row 3 — bytes 48..63
    t[48] = UInt8(0xB8); t[49] = UInt8(0x08); t[50] = UInt8(0x46); t[51] = UInt8(0x74)
    t[52] = UInt8(0xF7); t[53] = UInt8(0x43); t[54] = UInt8(0x24); t[55] = UInt8(0x8E)
    t[56] = UInt8(0xE0); t[57] = UInt8(0x35); t[58] = UInt8(0x90); t[59] = UInt8(0xE6)
    t[60] = UInt8(0x81); t[61] = UInt8(0x3A); t[62] = UInt8(0x26); t[63] = UInt8(0x4C)
    # Row 4 — bytes 64..79
    t[64] = UInt8(0x3C); t[65] = UInt8(0x28); t[66] = UInt8(0x52); t[67] = UInt8(0xBB)
    t[68] = UInt8(0x91); t[69] = UInt8(0xC3); t[70] = UInt8(0x00); t[71] = UInt8(0xCB)
    t[72] = UInt8(0x88); t[73] = UInt8(0xD0); t[74] = UInt8(0x65); t[75] = UInt8(0x8B)
    t[76] = UInt8(0x1B); t[77] = UInt8(0x53); t[78] = UInt8(0x2E); t[79] = UInt8(0xA3)
    # Row 5 — bytes 80..95
    t[80] = UInt8(0x71); t[81] = UInt8(0x64); t[82] = UInt8(0x48); t[83] = UInt8(0x97)
    t[84] = UInt8(0xA2); t[85] = UInt8(0x0D); t[86] = UInt8(0xF9); t[87] = UInt8(0x4E)
    t[88] = UInt8(0x38); t[89] = UInt8(0x19); t[90] = UInt8(0xEF); t[91] = UInt8(0x46)
    t[92] = UInt8(0xA9); t[93] = UInt8(0xDE); t[94] = UInt8(0xAC); t[95] = UInt8(0xD8)
    # Row 6 — bytes 96..111
    t[96] = UInt8(0xA8); t[97] = UInt8(0xFA); t[98] = UInt8(0x76); t[99] = UInt8(0x3F)
    t[100] = UInt8(0xE3); t[101] = UInt8(0x9C); t[102] = UInt8(0x34); t[103] = UInt8(0x3F)
    t[104] = UInt8(0xF9); t[105] = UInt8(0xDC); t[106] = UInt8(0xBB); t[107] = UInt8(0xC7)
    t[108] = UInt8(0xC7); t[109] = UInt8(0x0B); t[110] = UInt8(0x4F); t[111] = UInt8(0x1D)
    # Row 7 — bytes 112..127
    t[112] = UInt8(0x8A); t[113] = UInt8(0x51); t[114] = UInt8(0xE0); t[115] = UInt8(0x4B)
    t[116] = UInt8(0xCD); t[117] = UInt8(0xB4); t[118] = UInt8(0x59); t[119] = UInt8(0x31)
    t[120] = UInt8(0xC8); t[121] = UInt8(0x9F); t[122] = UInt8(0x7E); t[123] = UInt8(0xC9)
    t[124] = UInt8(0xD9); t[125] = UInt8(0x78); t[126] = UInt8(0x73); t[127] = UInt8(0x64)
    # Row 8 — bytes 128..143
    t[128] = UInt8(0xEA); t[129] = UInt8(0xC5); t[130] = UInt8(0xAC); t[131] = UInt8(0x83)
    t[132] = UInt8(0x34); t[133] = UInt8(0xD3); t[134] = UInt8(0xEB); t[135] = UInt8(0xC3)
    t[136] = UInt8(0xC5); t[137] = UInt8(0x81); t[138] = UInt8(0xA0); t[139] = UInt8(0xFF)
    t[140] = UInt8(0xFA); t[141] = UInt8(0x13); t[142] = UInt8(0x63); t[143] = UInt8(0xEB)
    # Row 9 — bytes 144..159
    t[144] = UInt8(0x17); t[145] = UInt8(0x0D); t[146] = UInt8(0xDD); t[147] = UInt8(0x51)
    t[148] = UInt8(0xB7); t[149] = UInt8(0xF0); t[150] = UInt8(0xDA); t[151] = UInt8(0x49)
    t[152] = UInt8(0xD3); t[153] = UInt8(0x16); t[154] = UInt8(0x55); t[155] = UInt8(0x26)
    t[156] = UInt8(0x29); t[157] = UInt8(0xD4); t[158] = UInt8(0x68); t[159] = UInt8(0x9E)
    # Row 10 — bytes 160..175
    t[160] = UInt8(0x2B); t[161] = UInt8(0x16); t[162] = UInt8(0xBE); t[163] = UInt8(0x58)
    t[164] = UInt8(0x7D); t[165] = UInt8(0x47); t[166] = UInt8(0xA1); t[167] = UInt8(0xFC)
    t[168] = UInt8(0x8F); t[169] = UInt8(0xF8); t[170] = UInt8(0xB8); t[171] = UInt8(0xD1)
    t[172] = UInt8(0x7A); t[173] = UInt8(0xD0); t[174] = UInt8(0x31); t[175] = UInt8(0xCE)
    # Row 11 — bytes 176..191
    t[176] = UInt8(0x45); t[177] = UInt8(0xCB); t[178] = UInt8(0x3A); t[179] = UInt8(0x8F)
    t[180] = UInt8(0x95); t[181] = UInt8(0x16); t[182] = UInt8(0x04); t[183] = UInt8(0x28)
    t[184] = UInt8(0xAF); t[185] = UInt8(0xD7); t[186] = UInt8(0xFB); t[187] = UInt8(0xCA)
    t[188] = UInt8(0xBB); t[189] = UInt8(0x4B); t[190] = UInt8(0x40); t[191] = UInt8(0x7E)

    if i < 0 or i >= 192:
        return UInt8(0)
    return t[i]


# =============================================================================
# Scalar primitive helpers
# =============================================================================

@always_inline
def _rotl64(x: UInt64, r: Int) -> UInt64:
    """64-bit rotate-left by `r` (r ∈ [0, 64))."""
    # SAFETY: pure arithmetic; no pointers. `r=0` and `r=64` would both
    # invoke UB on the C side (`x >> (64 - 0) == x >> 64`); we never call
    # with those values from the xxh3 paths below.
    return (x << UInt64(r)) | (x >> UInt64(64 - r))


@always_inline
def _swap64(x: UInt64) -> UInt64:
    """Byte-swap a UInt64 (big↔little endian)."""
    # SAFETY: pure arithmetic over bit-shifts and masks.
    return (
        ((x & UInt64(0xFF00000000000000)) >> UInt64(56))
        | ((x & UInt64(0x00FF000000000000)) >> UInt64(40))
        | ((x & UInt64(0x0000FF0000000000)) >> UInt64(24))
        | ((x & UInt64(0x000000FF00000000)) >> UInt64(8))
        | ((x & UInt64(0x00000000FF000000)) << UInt64(8))
        | ((x & UInt64(0x0000000000FF0000)) << UInt64(24))
        | ((x & UInt64(0x000000000000FF00)) << UInt64(40))
        | ((x & UInt64(0x00000000000000FF)) << UInt64(56))
    )


@always_inline
def _swap32(x: UInt32) -> UInt32:
    """Byte-swap a UInt32."""
    return (
        ((x & UInt32(0xFF000000)) >> UInt32(24))
        | ((x & UInt32(0x00FF0000)) >> UInt32(8))
        | ((x & UInt32(0x0000FF00)) << UInt32(8))
        | ((x & UInt32(0x000000FF)) << UInt32(24))
    )


@always_inline
def _read_le32[
    _mut: Bool, o: Origin[mut=_mut], //,
](base: UnsafePointer[UInt8, o], off: Int) -> UInt32:
    """Little-endian 32-bit load from `base + off`.

    Production targets (Linux x86_64 + macOS arm64) are both LE, so
    this is a direct 4-byte load.
    """
    # SAFETY: caller bounds `off + 4 <= len`. The pointer's origin `o` is
    # the receiver-poly origin from `_row_base_ptr_ro`; valid for the
    # life of the borrow.
    var b0 = UInt32(Int(base[off + 0]))
    var b1 = UInt32(Int(base[off + 1])) << UInt32(8)
    var b2 = UInt32(Int(base[off + 2])) << UInt32(16)
    var b3 = UInt32(Int(base[off + 3])) << UInt32(24)
    return b0 | b1 | b2 | b3


@always_inline
def _read_le64[
    _mut: Bool, o: Origin[mut=_mut], //,
](base: UnsafePointer[UInt8, o], off: Int) -> UInt64:
    """Little-endian 64-bit load from `base + off`."""
    # SAFETY: caller bounds `off + 8 <= len`. Origin tracking matches `_read_le32`.
    var lo = UInt64(Int(_read_le32(base, off)))
    var hi = UInt64(Int(_read_le32(base, off + 4))) << UInt64(32)
    return lo | hi


@always_inline
def _read_le32_secret(off: Int) -> UInt32:
    """Little-endian 32-bit load from XXH3_kSecret at byte `off`.

    Dispatches to precomputed `_XXH3_SECRET_U32_*` aliases for the two
    offsets actually consumed by the algorithm (0 and 4 — used in
    len_1to3). Other offsets fall back to a byte-by-byte read from the
    `_xxh3_k_secret` table; in production that fallback is never hit
    (verified by walking the call graph).
    """
    if off == 0:
        return _XXH3_SECRET_U32_0
    if off == 4:
        return _XXH3_SECRET_U32_4
    # Fallback path (cold; not exercised by production callers).
    # SAFETY: caller bounds `off + 4 <= 192`.
    var b0 = UInt32(Int(_xxh3_k_secret(off + 0)))
    var b1 = UInt32(Int(_xxh3_k_secret(off + 1))) << UInt32(8)
    var b2 = UInt32(Int(_xxh3_k_secret(off + 2))) << UInt32(16)
    var b3 = UInt32(Int(_xxh3_k_secret(off + 3))) << UInt32(24)
    return b0 | b1 | b2 | b3


@always_inline
def _read_le64_secret(off: Int) -> UInt64:
    """Little-endian 64-bit load from XXH3_kSecret at byte `off`.

    Dispatches to precomputed `_XXH3_SECRET_U64_*` aliases for the 23
    offsets actually consumed by the algorithm. The hot-path
    (`_xxh3_len_*` + `_xxh3_mix16b`) hits these constants directly;
    LLVM folds the if/elif chain into a switch table or a sequence of
    cmp/cmov.

    Offsets covered: {0, 3, 8, 16, 19, 24, 32, 35, 40, 48, 51, 56, 64,
    67, 72, 80, 83, 88, 96, 99, 104, 112, 119}. These are the union of
    fixed offsets in the 0..128 paths PLUS the runtime offsets visited
    by the 129..240 mid-loop (`16*(i-8) + 3` for i ∈ [8, 14] → {3, 19,
    35, 51, 67, 83, 99}) PLUS the tail-block offset for the 129..240
    path (`XXH3_SECRET_SIZE_MIN - XXH3_MIDSIZE_LASTOFFSET = 136 - 17 = 119`).
    """
    if off == 0:
        return _XXH3_SECRET_U64_0
    if off == 8:
        return _XXH3_SECRET_U64_8
    if off == 16:
        return _XXH3_SECRET_U64_16
    if off == 24:
        return _XXH3_SECRET_U64_24
    if off == 32:
        return _XXH3_SECRET_U64_32
    if off == 40:
        return _XXH3_SECRET_U64_40
    if off == 48:
        return _XXH3_SECRET_U64_48
    if off == 56:
        return _XXH3_SECRET_U64_56
    if off == 64:
        return _XXH3_SECRET_U64_64
    if off == 72:
        return _XXH3_SECRET_U64_72
    if off == 80:
        return _XXH3_SECRET_U64_80
    if off == 88:
        return _XXH3_SECRET_U64_88
    if off == 96:
        return _XXH3_SECRET_U64_96
    if off == 104:
        return _XXH3_SECRET_U64_104
    if off == 112:
        return _XXH3_SECRET_U64_112
    if off == 119:
        return _XXH3_SECRET_U64_119
    if off == 3:
        return _XXH3_SECRET_U64_3
    if off == 19:
        return _XXH3_SECRET_U64_19
    if off == 35:
        return _XXH3_SECRET_U64_35
    if off == 51:
        return _XXH3_SECRET_U64_51
    if off == 67:
        return _XXH3_SECRET_U64_67
    if off == 83:
        return _XXH3_SECRET_U64_83
    if off == 99:
        return _XXH3_SECRET_U64_99
    # Fallback path (cold; only hit by the kSecret integrity test):
    # SAFETY: caller bounds `off + 8 <= 192`.
    var lo = UInt64(Int(_read_le32_secret(off)))
    var hi = UInt64(Int(_read_le32_secret(off + 4))) << UInt64(32)
    return lo | hi


@always_inline
def _mul128_fold64(lhs: UInt64, rhs: UInt64) -> UInt64:
    """128-bit multiply, fold high^low.

    Implements upstream `XXH3_mul128_fold64` (xxhash.h:4598-4603) via
    Mojo's native 128-bit `UInt128` arithmetic. The fold is `lo XOR hi`.
    """
    # SAFETY: pure arithmetic over UInt128.
    var prod: UInt128 = UInt128(lhs) * UInt128(rhs)
    var lo64: UInt64 = UInt64(prod & UInt128(0xFFFFFFFFFFFFFFFF))
    var hi64: UInt64 = UInt64((prod >> UInt128(64)) & UInt128(0xFFFFFFFFFFFFFFFF))
    return lo64 ^ hi64


@always_inline
def _xxh64_avalanche(h: UInt64) -> UInt64:
    """XXH64 finalization mix (xxhash.h:3518-3526)."""
    # SAFETY: pure arithmetic.
    var x = h
    x = x ^ (x >> UInt64(33))
    x = x * _XXH_PRIME64_2
    x = x ^ (x >> UInt64(29))
    x = x * _XXH_PRIME64_3
    x = x ^ (x >> UInt64(32))
    return x


@always_inline
def _xxh3_avalanche(h: UInt64) -> UInt64:
    """XXH3 finalization mix (xxhash.h:4616-4622).

    Faster than XXH64_avalanche; suitable when input bits are already
    partially mixed by the per-bucket path.
    """
    # SAFETY: pure arithmetic.
    var x = h
    x = x ^ (x >> UInt64(37))
    x = x * _XXH_PRIME_MX1
    x = x ^ (x >> UInt64(32))
    return x


@always_inline
def _xxh3_rrmxmx(h: UInt64, len_: UInt64) -> UInt64:
    """Stronger avalanche (xxhash.h:4629-4637).

    Used by the 4-8 byte path where the keyed input is not as mixed.
    """
    # SAFETY: pure arithmetic.
    var x = h
    x = x ^ (_rotl64(x, 49) ^ _rotl64(x, 24))
    x = x * _XXH_PRIME_MX2
    x = x ^ ((x >> UInt64(35)) + len_)
    x = x * _XXH_PRIME_MX2
    x = x ^ (x >> UInt64(28))
    return x


# =============================================================================
# Per-length-bucket hash bodies
# =============================================================================

@always_inline
def _xxh3_len_0(seed: UInt64) -> UInt64:
    """xxh3-64 for empty input.

    From xxhash.h:4735:
        return XXH64_avalanche(seed ^ (readLE64(secret+56) ^ readLE64(secret+64)));
    """
    # SAFETY: pure arithmetic.
    var k1 = _read_le64_secret(56)
    var k2 = _read_le64_secret(64)
    return _xxh64_avalanche(seed ^ (k1 ^ k2))


@always_inline
def _xxh3_len_1to3[
    _mut: Bool, o: Origin[mut=_mut], //,
](base: UnsafePointer[UInt8, o], off: Int, len_: Int, seed: UInt64) -> UInt64:
    """xxh3-64 for inputs of 1..3 bytes (xxhash.h:4674-4693)."""
    # SAFETY: caller bounds `off + len_ <= row_stride` and `1 <= len_ <= 3`.
    var c1 = UInt32(Int(base[off + 0]))
    var c2 = UInt32(Int(base[off + (len_ >> 1)]))
    var c3 = UInt32(Int(base[off + (len_ - 1)]))
    var combined: UInt32 = (
        (c1 << UInt32(16))
        | (c2 << UInt32(24))
        | (c3 << UInt32(0))
        | (UInt32(len_) << UInt32(8))
    )
    var bitflip: UInt64 = (
        UInt64(Int(_read_le32_secret(0))) ^ UInt64(Int(_read_le32_secret(4)))
    ) + seed
    var keyed: UInt64 = UInt64(Int(combined)) ^ bitflip
    return _xxh64_avalanche(keyed)


@always_inline
def _xxh3_len_4to8[
    _mut: Bool, o: Origin[mut=_mut], //,
](base: UnsafePointer[UInt8, o], off: Int, len_: Int, seed: UInt64) -> UInt64:
    """xxh3-64 for inputs of 4..8 bytes (xxhash.h:4695-4709)."""
    # SAFETY: caller bounds `off + len_ <= row_stride` and `4 <= len_ <= 8`.
    var seed_mixed: UInt64 = seed ^ (
        UInt64(Int(_swap32(UInt32(Int(seed & UInt64(0xFFFFFFFF)))))) << UInt64(32)
    )
    var input1: UInt32 = _read_le32(base, off)
    var input2: UInt32 = _read_le32(base, off + len_ - 4)
    var bitflip: UInt64 = (
        _read_le64_secret(8) ^ _read_le64_secret(16)
    ) - seed_mixed
    var input64: UInt64 = (
        UInt64(Int(input2)) + (UInt64(Int(input1)) << UInt64(32))
    )
    var keyed: UInt64 = input64 ^ bitflip
    return _xxh3_rrmxmx(keyed, UInt64(len_))


@always_inline
def _xxh3_len_9to16[
    _mut: Bool, o: Origin[mut=_mut], //,
](base: UnsafePointer[UInt8, o], off: Int, len_: Int, seed: UInt64) -> UInt64:
    """xxh3-64 for inputs of 9..16 bytes (xxhash.h:4711-4726)."""
    # SAFETY: caller bounds `off + len_ <= row_stride` and `9 <= len_ <= 16`.
    var bitflip1: UInt64 = (
        _read_le64_secret(24) ^ _read_le64_secret(32)
    ) + seed
    var bitflip2: UInt64 = (
        _read_le64_secret(40) ^ _read_le64_secret(48)
    ) - seed
    var input_lo: UInt64 = _read_le64(base, off) ^ bitflip1
    var input_hi: UInt64 = _read_le64(base, off + len_ - 8) ^ bitflip2
    var acc: UInt64 = (
        UInt64(len_) + _swap64(input_lo) + input_hi
        + _mul128_fold64(input_lo, input_hi)
    )
    return _xxh3_avalanche(acc)


@always_inline
def _xxh3_mix16b[
    _mut: Bool, o: Origin[mut=_mut], //,
](
    base: UnsafePointer[UInt8, o],
    input_off: Int,
    secret_off: Int,
    seed: UInt64,
) -> UInt64:
    """16-byte secret-keyed mix block (xxhash.h:4765-4795)."""
    # SAFETY: caller bounds `input_off + 16 <= row_stride` and
    # `secret_off + 16 <= 192`.
    var input_lo: UInt64 = _read_le64(base, input_off)
    var input_hi: UInt64 = _read_le64(base, input_off + 8)
    var k_lo: UInt64 = _read_le64_secret(secret_off) + seed
    var k_hi: UInt64 = _read_le64_secret(secret_off + 8) - seed
    return _mul128_fold64(input_lo ^ k_lo, input_hi ^ k_hi)


def _xxh3_len_17to128[
    _mut: Bool, o: Origin[mut=_mut], //,
](base: UnsafePointer[UInt8, o], off: Int, len_: Int, seed: UInt64) -> UInt64:
    """xxh3-64 for inputs of 17..128 bytes (xxhash.h:4798-4832)."""
    # SAFETY: caller bounds `off + len_ <= row_stride` and `17 <= len_ <= 128`.
    var acc: UInt64 = UInt64(len_) * _XXH_PRIME64_1
    if len_ > 32:
        if len_ > 64:
            if len_ > 96:
                acc = acc + _xxh3_mix16b(base, off + 48, 96, seed)
                acc = acc + _xxh3_mix16b(base, off + len_ - 64, 112, seed)
            acc = acc + _xxh3_mix16b(base, off + 32, 64, seed)
            acc = acc + _xxh3_mix16b(base, off + len_ - 48, 80, seed)
        acc = acc + _xxh3_mix16b(base, off + 16, 32, seed)
        acc = acc + _xxh3_mix16b(base, off + len_ - 32, 48, seed)
    acc = acc + _xxh3_mix16b(base, off + 0, 0, seed)
    acc = acc + _xxh3_mix16b(base, off + len_ - 16, 16, seed)
    return _xxh3_avalanche(acc)


def _xxh3_len_129to240[
    _mut: Bool, o: Origin[mut=_mut], //,
](base: UnsafePointer[UInt8, o], off: Int, len_: Int, seed: UInt64) -> UInt64:
    """xxh3-64 for inputs of 129..240 bytes (xxhash.h:4834-4891).

    XXH3_MIDSIZE_STARTOFFSET = 3, XXH3_MIDSIZE_LASTOFFSET = 17,
    XXH3_SECRET_SIZE_MIN = 136 (xxhash.h:331).
    """
    # SAFETY: caller bounds `off + len_ <= row_stride` and
    # `129 <= len_ <= 240`.
    comptime XXH3_MIDSIZE_STARTOFFSET: Int = 3
    comptime XXH3_MIDSIZE_LASTOFFSET: Int = 17
    comptime XXH3_SECRET_SIZE_MIN: Int = 136

    var acc: UInt64 = UInt64(len_) * _XXH_PRIME64_1
    var nb_rounds: Int = len_ // 16

    # First 8 mix16B blocks at fixed secret offsets [0, 16, 32, ..., 112].
    for i in range(8):
        acc = acc + _xxh3_mix16b(base, off + 16 * i, 16 * i, seed)

    # Tail mix block at len-16 with secret offset 136-17 = 119.
    var acc_end: UInt64 = _xxh3_mix16b(
        base, off + len_ - 16,
        XXH3_SECRET_SIZE_MIN - XXH3_MIDSIZE_LASTOFFSET, seed,
    )
    acc = _xxh3_avalanche(acc)

    # Remaining rounds 8..nb_rounds-1 with secret offset
    # (16*(i-8) + XXH3_MIDSIZE_STARTOFFSET).
    var i = 8
    while i < nb_rounds:
        acc_end = acc_end + _xxh3_mix16b(
            base,
            off + 16 * i,
            16 * (i - 8) + XXH3_MIDSIZE_STARTOFFSET,
            seed,
        )
        i = i + 1

    return _xxh3_avalanche(acc + acc_end)


# =============================================================================
# Internal byte-pointer dispatcher
# =============================================================================
#
# This is the kernel entry called by `row_block.mojo:_hash_row_bytes` after
# it has derived the row-base byte pointer via `_row_base_ptr_ro` (the
# concrete-origin RowBlock accessor). Encapsulation rule: `_hash_row_bytes`
# is itself a private free function inside `row_block.mojo`, so the raw
# pointer never crosses a PUBLIC API boundary — it's a private intra-package
# pass between two `_`-prefixed identifiers.
#
# The signature accepts `UnsafePointer[UInt8, o]` with concrete origin `o`
# inferred from the caller's RowBlock borrow. No wildcard origin; the
# pointer lifetime is tracked back to the RowBlock's `_fixed_storage`.

@always_inline
def _xxh3_64_dispatch[
    _mut: Bool, o: Origin[mut=_mut], //,
](base: UnsafePointer[UInt8, o], len_: Int, seed: UInt64) -> UInt64:
    """xxh3-64 scalar reference dispatcher over `len_` bytes from `base`.

    SAFETY: caller bounds `base[0..len_]` is valid for the borrow.
    Production callsite (`row_block.mojo:_hash_row_bytes`) derives `base`
    via `keys._row_base_ptr_ro(row)` with the row precondition enforced
    by the upsert/probe inner loop.

    Length cap: 240 bytes (XXH3_MAX_KEY_LEN). This is enforced by the
    caller in `row_block.mojo:_hash_row_bytes` (the row's `key_stride`
    is bounded by the schema, and the schema-validation gate at table
    construction can refuse strides > 240 if a future shape lands them).
    Internal dispatch does NOT raise on overrun — it routes any len > 128
    into the 129..240 path. Going beyond 240 silently produces an
    incorrect result; callers MUST gate.
    """
    if len_ == 0:
        return _xxh3_len_0(seed)
    if len_ <= 3:
        return _xxh3_len_1to3(base, 0, len_, seed)
    if len_ <= 8:
        return _xxh3_len_4to8(base, 0, len_, seed)
    if len_ <= 16:
        return _xxh3_len_9to16(base, 0, len_, seed)
    if len_ <= 128:
        return _xxh3_len_17to128(base, 0, len_, seed)
    return _xxh3_len_129to240(base, 0, len_, seed)


@always_inline
def xxh3_64_scalar_bytes(
    imm bytes: List[UInt8],
) raises -> UInt64:
    """Public test-friendly entry: xxh3-64 over a byte list.

    Public signature takes `List[UInt8]` (safe type — no `UnsafePointer`
    crosses the boundary). Internal pointer derivation via
    `bytes.unsafe_ptr()` yields a concrete-origin pointer tied to the
    borrow of `bytes`; the per-bucket helpers consume it without
    widening to any wildcard origin.

    Used by:
      * `test_xxh3.mojo` — KATs, determinism, cross-platform
        stability checks.
      * Future callers that need to hash an in-memory byte span (e.g.
        a Bloom hash family, spill restore boundary).

    Length cap: 240 bytes; raises on overrun (consumers gate at construction).

    SAFETY: pointer derivation is bounded by `len(bytes)`; all per-bucket
    dispatch arms read at most `len_` bytes from offset 0.
    """
    var len_: Int = len(bytes)
    if len_ > XXH3_MAX_KEY_LEN:
        raise Error(
            "xxh3_64_scalar_bytes: len " + String(len_)
            + " exceeds " + String(XXH3_MAX_KEY_LEN)
        )
    # SAFETY: `bytes.unsafe_ptr()` is valid for the life of the `read`-mode
    # borrow on `bytes`; we read exactly `len_` bytes starting at offset 0
    # via the dispatcher. The pointer carries the inferred receiver origin
    # from `unsafe_ptr` (concrete, not wildcard).
    var base = bytes.unsafe_ptr()
    return _xxh3_64_dispatch(base, len_, UInt64(0))


@always_inline
def xxh3_64_scalar_span(
    bytes: Span[UInt8, _],
) raises -> UInt64:
    """Public ALLOCATION-FREE entry: xxh3-64 over a byte `Span`.

    Identical algorithm + identical result to `xxh3_64_scalar_bytes`, but
    takes a borrowed `Span[UInt8, _]` (origin-poly safe view) instead of a
    `List[UInt8]`. The caller can pass a zero-copy view over a contiguous
    buffer it already owns (e.g. an `InlineArray[UInt8, N]` stack block via
    `Span(self.bytes)`) — NO heap allocation, NO per-element copy.

    This is the hot-path entry for fixed-width composite-key hashing
    (`CompositeKey.hash64`): the key bytes live contiguously in a stack
    `InlineArray`, so a `List` materialization per probe row is pure
    allocation overhead. Hashing the `Span` directly is what the column-
    format hot loop does (`row_block.mojo:_hash_row_bytes` over the row
    base pointer).

    Public signature takes `Span[UInt8, _]` (safe type — no `UnsafePointer`
    crosses the boundary). Internal pointer derivation via
    `bytes.unsafe_ptr()` yields a concrete-origin pointer tied to the
    borrow of `bytes`; the per-bucket helpers consume it without widening
    to any wildcard origin.

    Length cap: 240 bytes; raises on overrun (consumers gate at construction).

    SAFETY: pointer derivation is bounded by `len(bytes)`; all per-bucket
    dispatch arms read at most `len_` bytes from offset 0. The span's origin
    keeps the backing buffer alive for the borrow.
    """
    var len_: Int = len(bytes)
    if len_ > XXH3_MAX_KEY_LEN:
        raise Error(
            "xxh3_64_scalar_span: len " + String(len_)
            + " exceeds " + String(XXH3_MAX_KEY_LEN)
        )
    # SAFETY: `bytes.unsafe_ptr()` is valid for the life of the borrow on
    # `bytes`; we read exactly `len_` bytes starting at offset 0 via the
    # dispatcher. The pointer carries the span's concrete origin (not
    # wildcard).
    var base = bytes.unsafe_ptr()
    return _xxh3_64_dispatch(base, len_, UInt64(0))
