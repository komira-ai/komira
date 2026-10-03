# =============================================================================
# byte_find_any_of.mojo — find-first-of-N-needles in a byte chunk.
# =============================================================================
#
# The CSV scanner's central scan primitive: given a 16/32/64-byte
# chunk and a small set of needle bytes (typical: `{',', '\n', '\r',
# '"'}` for RFC-4180, or `{',', '\n', '"', '\\'}` for Excel-style),
# return a byte-mask where lane k is 0xFF iff `chunk[k]` matches ANY
# of the needles.
#
# Two implementation shapes are exposed (the caller picks based on
# whether the needle set is fixed at comptime or runtime):
#
#   1. `byte_find_eq_2 / _3 / _4 / _5_*`
#      — fixed-arity comptime needle set; each call site monomorphizes
#      to N `cmeq.16b` + (N-1) `orr.16b` chains.  ~2N cycles.
#
#   2. `byte_find_in_set_16` (nibble-LUT)
#      — runtime needle set (up to 16 bytes, where each is from a
#      bounded character class) classified via two 16-byte LUTs.  ~5
#      cycles regardless of N.  Used when needle-set is data-dependent
#      or > 4 elements.
#
# Each output is a 0xFF/0x00 byte-mask (Highway `Mask<uint8>` shape);
# `movemask_to_uint_*` converts to a UInt16/32/64 bitset.
#
# Encapsulation: SIMD-in / SIMD-out; no pointers.
# =============================================================================

from komira_simd.byte_class.byte_mask_ops import bytemask_or
from komira_simd.byte_class.movemask import byte_eq_to_bytemask_u8x16, byte_eq_to_bytemask_u8x32, byte_eq_to_bytemask_u8x64
from komira_simd.byte_class.table_lookup import nibble_lut_classify_u8x16, nibble_lut_classify_u8x32


# =============================================================================
# Comptime-arity multi-needle find.
# =============================================================================
#
# Each function: AND-NOT mode via byte_eq + OR chain.

@always_inline
def byte_find_eq_2_u8x16(
    chunk: SIMD[DType.uint8, 16],
    n0: UInt8, n1: UInt8,
) -> SIMD[DType.uint8, 16]:
    """16-byte chunk → 0xFF/0x00 byte-mask of "matches n0 OR n1".

    Lowers to 2 `cmeq.16b` + 1 `orr.16b` on NEON (~3 cycles).  Same
    shape on x86 SSE2 `pcmpeqb` + `por`.
    """
    var m0 = byte_eq_to_bytemask_u8x16(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x16(chunk, n1)
    return bytemask_or[16](m0, m1)


@always_inline
def byte_find_eq_3_u8x16(
    chunk: SIMD[DType.uint8, 16],
    n0: UInt8, n1: UInt8, n2: UInt8,
) -> SIMD[DType.uint8, 16]:
    """16-byte 3-needle find — RFC-4180 CSV (without ESCAPE) common form."""
    var m0 = byte_eq_to_bytemask_u8x16(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x16(chunk, n1)
    var m2 = byte_eq_to_bytemask_u8x16(chunk, n2)
    return bytemask_or[16](bytemask_or[16](m0, m1), m2)


@always_inline
def byte_find_eq_4_u8x16(
    chunk: SIMD[DType.uint8, 16],
    n0: UInt8, n1: UInt8, n2: UInt8, n3: UInt8,
) -> SIMD[DType.uint8, 16]:
    """16-byte 4-needle find — RFC-4180 CSV (with QUOTE) canonical."""
    var m0 = byte_eq_to_bytemask_u8x16(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x16(chunk, n1)
    var m2 = byte_eq_to_bytemask_u8x16(chunk, n2)
    var m3 = byte_eq_to_bytemask_u8x16(chunk, n3)
    return bytemask_or[16](
        bytemask_or[16](m0, m1),
        bytemask_or[16](m2, m3),
    )


@always_inline
def byte_find_eq_5_u8x16(
    chunk: SIMD[DType.uint8, 16],
    n0: UInt8, n1: UInt8, n2: UInt8, n3: UInt8, n4: UInt8,
) -> SIMD[DType.uint8, 16]:
    """16-byte 5-needle find — Excel-style CSV (with ESCAPE = '\\')."""
    var m0 = byte_eq_to_bytemask_u8x16(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x16(chunk, n1)
    var m2 = byte_eq_to_bytemask_u8x16(chunk, n2)
    var m3 = byte_eq_to_bytemask_u8x16(chunk, n3)
    var m4 = byte_eq_to_bytemask_u8x16(chunk, n4)
    return bytemask_or[16](
        bytemask_or[16](bytemask_or[16](m0, m1), bytemask_or[16](m2, m3)),
        m4,
    )


# =============================================================================
# 32-byte variants (AVX2-class width).
# =============================================================================

@always_inline
def byte_find_eq_2_u8x32(
    chunk: SIMD[DType.uint8, 32],
    n0: UInt8, n1: UInt8,
) -> SIMD[DType.uint8, 32]:
    """32-byte 2-needle find."""
    var m0 = byte_eq_to_bytemask_u8x32(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x32(chunk, n1)
    return bytemask_or[32](m0, m1)


@always_inline
def byte_find_eq_3_u8x32(
    chunk: SIMD[DType.uint8, 32],
    n0: UInt8, n1: UInt8, n2: UInt8,
) -> SIMD[DType.uint8, 32]:
    """32-byte 3-needle find."""
    var m0 = byte_eq_to_bytemask_u8x32(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x32(chunk, n1)
    var m2 = byte_eq_to_bytemask_u8x32(chunk, n2)
    return bytemask_or[32](bytemask_or[32](m0, m1), m2)


@always_inline
def byte_find_eq_4_u8x32(
    chunk: SIMD[DType.uint8, 32],
    n0: UInt8, n1: UInt8, n2: UInt8, n3: UInt8,
) -> SIMD[DType.uint8, 32]:
    """32-byte 4-needle find — the canonical CSV form at AVX2 width."""
    var m0 = byte_eq_to_bytemask_u8x32(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x32(chunk, n1)
    var m2 = byte_eq_to_bytemask_u8x32(chunk, n2)
    var m3 = byte_eq_to_bytemask_u8x32(chunk, n3)
    return bytemask_or[32](
        bytemask_or[32](m0, m1),
        bytemask_or[32](m2, m3),
    )


@always_inline
def byte_find_eq_5_u8x32(
    chunk: SIMD[DType.uint8, 32],
    n0: UInt8, n1: UInt8, n2: UInt8, n3: UInt8, n4: UInt8,
) -> SIMD[DType.uint8, 32]:
    """32-byte 5-needle find."""
    var m0 = byte_eq_to_bytemask_u8x32(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x32(chunk, n1)
    var m2 = byte_eq_to_bytemask_u8x32(chunk, n2)
    var m3 = byte_eq_to_bytemask_u8x32(chunk, n3)
    var m4 = byte_eq_to_bytemask_u8x32(chunk, n4)
    return bytemask_or[32](
        bytemask_or[32](bytemask_or[32](m0, m1), bytemask_or[32](m2, m3)),
        m4,
    )


# =============================================================================
# 64-byte variants (AVX-512 BW width).
# =============================================================================

@always_inline
def byte_find_eq_2_u8x64(
    chunk: SIMD[DType.uint8, 64],
    n0: UInt8, n1: UInt8,
) -> SIMD[DType.uint8, 64]:
    """64-byte 2-needle find."""
    var m0 = byte_eq_to_bytemask_u8x64(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x64(chunk, n1)
    return bytemask_or[64](m0, m1)


@always_inline
def byte_find_eq_4_u8x64(
    chunk: SIMD[DType.uint8, 64],
    n0: UInt8, n1: UInt8, n2: UInt8, n3: UInt8,
) -> SIMD[DType.uint8, 64]:
    """64-byte 4-needle find — the canonical CSV form at AVX-512 BW width."""
    var m0 = byte_eq_to_bytemask_u8x64(chunk, n0)
    var m1 = byte_eq_to_bytemask_u8x64(chunk, n1)
    var m2 = byte_eq_to_bytemask_u8x64(chunk, n2)
    var m3 = byte_eq_to_bytemask_u8x64(chunk, n3)
    return bytemask_or[64](
        bytemask_or[64](m0, m1),
        bytemask_or[64](m2, m3),
    )


# =============================================================================
# Nibble-LUT find-in-set — runtime needle set (up to 16 bytes per nibble).
# =============================================================================
#
# When the needle set is data-dependent OR > 4 bytes, the comptime-arity
# functions above lose their edge — the OR-chain grows and so does the
# per-chunk insn count.  The nibble-LUT shape (Highway / simdjson) does
# the lookup in 2 `pshufb` + 1 `and`, irrespective of needle count
# (up to 16 in each nibble class).
#
# Caller pre-computes the two 16-byte LUTs that encode needle membership
# per low/high nibble.  See `byte_classify_lut_from_set` (below) for
# the LUT construction.

@always_inline
def byte_find_in_set_u8x16(
    lo_lut: SIMD[DType.uint8, 16],
    hi_lut: SIMD[DType.uint8, 16],
    chunk: SIMD[DType.uint8, 16],
) -> SIMD[DType.uint8, 16]:
    """16-byte find-in-set via nibble-LUT.  Result byte k is non-zero
    iff `chunk[k]` is in the needle set encoded by `(lo_lut, hi_lut)`.

    NOTE: result is NOT strictly 0xFF/0x00; it's whatever AND of the
    LUT entries produces.  If the LUTs encode "1 = in set, 0 = not",
    then result is 1 / 0; threshold to 0xFF/0x00 via `> 0` for the
    standard byte-mask shape.

    Lowers to 2 `tbl.16b` + 1 `and.16b` on NEON / 2 `pshufb` + `vpand`
    on x86 SSSE3.  ~5 cycles total.
    """
    return nibble_lut_classify_u8x16(lo_lut, hi_lut, chunk)


@always_inline
def byte_find_in_set_u8x32(
    lo_lut: SIMD[DType.uint8, 16],
    hi_lut: SIMD[DType.uint8, 16],
    chunk: SIMD[DType.uint8, 32],
) -> SIMD[DType.uint8, 32]:
    """32-byte find-in-set via nibble-LUT (AVX2 width)."""
    return nibble_lut_classify_u8x32(lo_lut, hi_lut, chunk)


# =============================================================================
# Nibble-LUT construction helper.
# =============================================================================
#
# Build the two 16-byte LUTs encoding membership for an arbitrary byte
# set.  Each LUT entry at index `n` is a 1-bit class membership marker:
#
#   lo_lut[n] has bit b set iff there is a needle byte `c` in the set
#   where `(c & 0xF) == n` AND `((c >> 4) & 0xF) == b`.
#
# Then `lo_lut[low_nibble(byte)] & hi_lut[high_nibble(byte)]` is
# non-zero iff `byte` is in the set.  This works for needle sets where
# each byte's nibble-pair is unique (the common case for ASCII-class
# sets).

def build_byte_set_nibble_luts(
    needles: List[UInt8],
) -> Tuple[SIMD[DType.uint8, 16], SIMD[DType.uint8, 16]]:
    """Build (lo_lut, hi_lut) for `byte_find_in_set_*` from a set of
    needle bytes.

    Each needle byte `c` contributes a 1-bit at:
      - `lo_lut[c & 0xF]` bit position `(c >> 4) & 0xF`
      - `hi_lut[(c >> 4) & 0xF]` bit position `c & 0xF`

    After lookup, the AND yields a non-zero byte iff some needle byte
    matches in BOTH nibble positions — i.e. the input byte IS the
    needle.

    Caller is responsible for ensuring the needle-byte-set has no
    nibble-pair COLLISIONS — for sets with collisions, the nibble-LUT
    can produce false-positives (two needles sharing nibbles can
    falsely match a third byte).  For CSV's 5-byte standard set
    (`,` `\n` `\r` `"` `\\`) there are no collisions.
    """
    var lo = SIMD[DType.uint8, 16](0)
    var hi = SIMD[DType.uint8, 16](0)
    for i in range(len(needles)):
        var c = needles[i]
        var ln = Int(c & UInt8(0x0F))
        var hn = Int((c >> UInt8(4)) & UInt8(0x0F))
        # Set bit `hn` in lo[ln] and bit `ln` in hi[hn]. Note that for
        # the LUT scheme to work right with the AND, both LUTs must
        # have the SAME bit set at the matching needle position; the
        # AND then yields a non-zero result iff both nibbles match.
        # Convention: use bit position equal to the OTHER nibble.
        var lo_byte = lo[ln]
        var hi_byte = hi[hn]
        lo[ln] = lo_byte | (UInt8(1) << UInt8(hn))
        hi[hn] = hi_byte | (UInt8(1) << UInt8(ln))
    return Tuple[SIMD[DType.uint8, 16], SIMD[DType.uint8, 16]](lo, hi)
