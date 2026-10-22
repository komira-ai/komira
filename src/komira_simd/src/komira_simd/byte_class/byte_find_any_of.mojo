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
#   2. `byte_find_in_set_u8x16 / _u8x32` (nibble-LUT)
#      — runtime needle set (any set within 8 high-nibble rows or
#      8 low-nibble columns) classified via two 16-byte LUTs.  ~5
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
# Nibble-LUT find-in-set — runtime needle set.
# =============================================================================
#
# When the needle set is data-dependent OR > 4 bytes, the comptime-arity
# functions above lose their edge — the OR-chain grows and so does the
# per-chunk insn count.  The nibble-LUT shape (Highway / simdjson) does
# the lookup in 2 `pshufb` + 1 `and`, irrespective of needle count.
#
# Caller pre-computes the two 16-byte LUTs that encode needle membership
# per low/high nibble.  See `build_byte_set_nibble_luts` (below) for
# the LUT construction and which sets it accepts.

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
# Build the two 16-byte LUTs encoding exact membership for a byte set.
# The lookup is `lo_lut[low_nibble(b)] & hi_lut[high_nibble(b)]`, so a
# needle is found only if its two entries share a bit, and a non-needle
# is rejected only if its two entries share none.
#
# The builder groups needles by one nibble side and gives each distinct
# nibble on that side its own bit (at most 8, one per bit of a LUT byte).
# Grouping by high nibble, with `rank(h)` the bit of high nibble `h`:
#
#   hi_lut[h] = 1 << rank(h)                    (only that bit)
#   lo_lut[l] has bit rank(h) iff (h << 4 | l) is a needle
#
# so `lo_lut[l] & hi_lut[h]` is non-zero iff `(h << 4 | l)` is a needle.
# Grouping by low nibble is the mirror image. This builder does not
# encode a set with more than 8 distinct high nibbles AND more than 8
# distinct low nibbles, and raises. That is a limit of this builder, not
# of the LUT format: some such sets have an exact encoding (all 256
# bytes, or any 9x9 block of high by low nibbles), others do not (the
# 9-byte diagonal 0x00, 0x11, ..., 0x88).


def _nibble_ranks(
    needles: List[UInt8], shift: UInt8
) -> Tuple[SIMD[DType.uint8, 16], Int]:
    """For the nibble `(c >> shift) & 0xF` of each needle: lane n holds
    the bit index of nibble n (its rank among the distinct nibbles, in
    ascending order), and the second value is the distinct count."""
    var used = SIMD[DType.uint8, 16](0)
    for i in range(len(needles)):
        used[Int((needles[i] >> shift) & UInt8(0x0F))] = UInt8(1)
    var ranks = SIMD[DType.uint8, 16](0)
    var n = 0
    for nib in range(16):
        if used[nib] != 0:
            ranks[nib] = UInt8(n)
            n += 1
    return Tuple[SIMD[DType.uint8, 16], Int](ranks, n)


def build_byte_set_nibble_luts(
    needles: List[UInt8],
) raises -> Tuple[SIMD[DType.uint8, 16], SIMD[DType.uint8, 16]]:
    """Build (lo_lut, hi_lut) for `byte_find_in_set_*` from a set of
    needle bytes.

    With these LUTs, `byte_find_in_set_*` gives a non-zero lane iff the
    lane's byte is one of `needles`: no misses and no false positives.
    Duplicate needles are allowed; an empty set matches nothing.

    Raises if the needles span more than 8 distinct high nibbles and
    more than 8 distinct low nibbles: this builder does not encode such
    a set, although some of them (e.g. all 256 bytes) have an exact
    encoding.
    Any set of at most 8 bytes is accepted, as is any set confined to 8
    high-nibble rows (e.g. ASCII 0x00-0x7F) or to 8 low-nibble columns.
    """
    var hi_ranks = _nibble_ranks(needles, UInt8(4))
    var lo_ranks = _nibble_ranks(needles, UInt8(0))
    var by_high = hi_ranks[1] <= 8
    if not by_high and lo_ranks[1] > 8:
        raise Error(
            "build_byte_set_nibble_luts: needles use more than 8 distinct"
            " high nibbles and more than 8 distinct low nibbles"
        )
    var lo = SIMD[DType.uint8, 16](0)
    var hi = SIMD[DType.uint8, 16](0)
    for i in range(len(needles)):
        var c = needles[i]
        var ln = Int(c & UInt8(0x0F))
        var hn = Int((c >> UInt8(4)) & UInt8(0x0F))
        if by_high:
            # Bit owned by the high nibble; rank < 8, so the shift is exact.
            var bit = UInt8(1) << hi_ranks[0][hn]
            hi[hn] = bit
            lo[ln] = lo[ln] | bit
        else:
            var bit = UInt8(1) << lo_ranks[0][ln]
            lo[ln] = bit
            hi[hn] = hi[hn] | bit
    return Tuple[SIMD[DType.uint8, 16], SIMD[DType.uint8, 16]](lo, hi)
