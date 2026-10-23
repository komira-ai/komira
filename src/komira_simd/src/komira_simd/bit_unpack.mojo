# =============================================================================
# bit_unpack.mojo — width-generic MSB-first bit-packed integer unpack (SIMD).
# =============================================================================
#
# Decodes a contiguous run of fixed-width big-endian (MSB-first) bit-packed
# integers — the wire shape shared by ORC RLEv2 DIRECT/PATCHED_BASE/DELTA data
# streams, Parquet BIT_PACKED + RLE dictionary indices, and Avro fixed-width
# columns. The reference decoders (apache-orc `BitUnpackDefault`) hand-write
# SSE2 only for the BYTE-ALIGNED widths {4,8,16,24,32,40,48,56,64} and fall to
# a scalar virtual-call-per-byte loop (`plainUnpackLongs`) for everything else.
# These kernels hand-stage SIMD for both the byte-aligned widths (PSHUFB byte
# spread + lane byte-swap) and the cheap sub-byte widths (1/2/4 = shift+mask
# spread), so a caller can SIMD-cover widths the references leave scalar.
#
# Mojo does NOT autovectorize unit-stride numeric loops, so every lane step is
# explicit.
#
# Encapsulation: the PUBLIC API takes a borrowed `Span[UInt8, _]` source view
# and a mutable `Span[Int64, _]` destination view — NO raw UnsafePointer crosses
# this module boundary. The internal helpers use concrete-origin pointers
# obtained from those spans for SIMD load/store only (with # SAFETY: notes);
# they never escape.
#
# Each kernel is byte-identical to a scalar MSB-first bit-cursor; the ORC and
# Parquet decoders validate this against their scalar reference paths.
# =============================================================================

from std.memory import bitcast
from std.sys.info import simd_width_of, CompilationTarget

from komira_simd.byte_class.table_lookup import table_lookup_u8x16


# =============================================================================
# Byte-swap helpers (ORC/Parquet pack big-endian; x86/ARM are little-endian).
# =============================================================================


@always_inline
def _bswap32_lane[w: SIMDLength](v: SIMD[DType.uint32, w]) -> SIMD[DType.uint32, w]:
    """Byte-swap each 32-bit lane."""
    return (
        (v >> 24)
        | ((v >> 8) & 0x0000FF00)
        | ((v << 8) & 0x00FF0000)
        | (v << 24)
    )


@always_inline
def _bswap64_lane[w: SIMDLength](v: SIMD[DType.uint64, w]) -> SIMD[DType.uint64, w]:
    """Byte-swap each 64-bit lane."""
    var b0 = (v & 0x00000000000000FF) << 56
    var b1 = (v & 0x000000000000FF00) << 40
    var b2 = (v & 0x0000000000FF0000) << 24
    var b3 = (v & 0x00000000FF000000) << 8
    var b4 = (v & 0x000000FF00000000) >> 8
    var b5 = (v & 0x0000FF0000000000) >> 24
    var b6 = (v & 0x00FF000000000000) >> 40
    var b7 = (v & 0xFF00000000000000) >> 56
    return b0 | b1 | b2 | b3 | b4 | b5 | b6 | b7


# =============================================================================
# Byte-aligned widths (B = bits/8 bytes/value): B in {3,5,6,7,8}.
# Widths 1/2/4 byte (8/16/32 bit) have their own dedicated callers; this is the
# generic path for the byte-multiple widths 24/40/48/56/64 plus a fully-generic fallback for any byte-aligned width.
# =============================================================================
#
# Technique (PSHUFB byte-spread): the value's B big-endian bytes are scattered
# into a wider lane (uint32 for B<=4, uint64 for B<=8) via a comptime PSHUFB
# table, packed into the LOW B bytes of the lane in source (big-endian) order;
# one lane byte-swap then yields the little-endian value with the high
# (8-B) bytes zeroed (PSHUFB high-bit index = zero-fill). This mirrors
# apache-orc's `punpck`+`pshufb` SSE2 chains but is width-generic.


def _build_be_spread_table_u32[B: Int]() -> SIMD[DType.uint8, 16]:
    """Comptime PSHUFB index table: spread 4 values of B (<=4) big-endian bytes
    each from a 16-byte window into 4 uint32 lanes, placed at the lane's HIGH B
    bytes (so the zero-padding bytes are least-significant after the lane
    byte-swap). Unused positions index 0x80 -> PSHUFB zero-fill.

    For value v, src bytes [v*B, v*B+B) (MSB-first). Lane v spans output bytes
    [v*4, v*4+4). Put src byte (v*B + k) at output position v*4 + (4-B) + k.
    Reinterpreted little-endian then _bswap32, the value materializes with the
    high (4-B) bytes zeroed.
    """
    var t = SIMD[DType.uint8, 16](0x80)  # 0x80 high-bit -> zero on PSHUFB
    comptime for v in range(4):
        comptime for k in range(B):
            t[v * 4 + (4 - B) + k] = UInt8(v * B + k)
    return t


def _build_be_spread_table_u64[B: Int]() -> SIMD[DType.uint8, 16]:
    """Comptime PSHUFB index table: spread 2 values of B (<=8) big-endian bytes
    each from a 16-byte window into 2 uint64 lanes, placed at each lane's HIGH B
    bytes (zero-padding least-significant after _bswap64)."""
    var t = SIMD[DType.uint8, 16](0x80)
    comptime for v in range(2):
        comptime for k in range(B):
            t[v * 8 + (8 - B) + k] = UInt8(v * B + k)
    return t


def _unpack_byte_aligned_le4[
    so: Origin[mut=False], do: Origin[mut=True]
](
    src: UnsafePointer[UInt8, so],
    count: Int,
    dst: UnsafePointer[Int64, do],
    B: Int,
):
    """Byte-aligned unpack for B in {1,2,3,4} bytes/value via uint32-lane PSHUFB
    spread (4 values per 16-byte chunk).

    # SAFETY: `src` has >= B*count bytes, `dst` has >= count slots (callers
    # pre-validate / pre-size). SIMD load/store only; never escapes.
    """
    var i = 0
    # Build the spread table per B (comptime-specialized branch).
    var table: SIMD[DType.uint8, 16]
    if B == 1:
        table = _build_be_spread_table_u32[1]()
    elif B == 2:
        table = _build_be_spread_table_u32[2]()
    elif B == 3:
        table = _build_be_spread_table_u32[3]()
    else:
        table = _build_be_spread_table_u32[4]()
    var total_bytes = count * B
    # Process 4 values/iter; the 16-byte load at byte offset i*B must stay in
    # bounds (<= total_bytes), so stop while i*B + 16 <= total_bytes.
    while i + 4 <= count and (i * B + 16) <= total_bytes:
        var window = src.load[width=16](i * B)
        # PSHUFB semantics: out[k] = window[table[k]] (table holds byte-select
        # indices into the 16-byte window; index 0x80 high-bit -> zero-fill).
        var spread = table_lookup_u8x16(window, table)
        var u32 = bitcast[DType.uint32, 4](spread)
        var vals = _bswap32_lane(u32)
        dst.store[width=4](
            i, vals.cast[DType.uint64]().cast[DType.int64]()
        )
        i += 4
    # Scalar tail (and the final <16-byte window).
    while i < count:
        var v: UInt64 = 0
        for k in range(B):
            v = (v << 8) | UInt64(Int(src[i * B + k]))
        dst.store(i, Int64(v))
        i += 1


def _unpack_byte_aligned_le8[
    so: Origin[mut=False], do: Origin[mut=True]
](
    src: UnsafePointer[UInt8, so],
    count: Int,
    dst: UnsafePointer[Int64, do],
    B: Int,
):
    """Byte-aligned unpack for B in {5,6,7,8} bytes/value via uint64-lane PSHUFB
    spread (2 values per 16-byte chunk).

    # SAFETY: as `_unpack_byte_aligned_le4`.
    """
    var i = 0
    var table: SIMD[DType.uint8, 16]
    if B == 5:
        table = _build_be_spread_table_u64[5]()
    elif B == 6:
        table = _build_be_spread_table_u64[6]()
    elif B == 7:
        table = _build_be_spread_table_u64[7]()
    else:
        table = _build_be_spread_table_u64[8]()
    while i + 2 <= count and (i * B + 16) <= (count * B):
        var window = src.load[width=16](i * B)
        # PSHUFB semantics: out[k] = window[table[k]] (table holds byte-select
        # indices into the 16-byte window; index 0x80 high-bit -> zero-fill).
        var spread = table_lookup_u8x16(window, table)
        var u64 = bitcast[DType.uint64, 2](spread)
        var vals = _bswap64_lane(u64)
        dst.store[width=2](i, vals.cast[DType.int64]())
        i += 2
    while i < count:
        var v: UInt64 = 0
        for k in range(B):
            v = (v << 8) | UInt64(Int(src[i * B + k]))
        dst.store(i, Int64(v))
        i += 1


# =============================================================================
# Sub-byte widths 1 and 2 (MSB-first, several values per input byte).
# =============================================================================


def _unpack_w1[
    so: Origin[mut=False], do: Origin[mut=True]
](
    src: UnsafePointer[UInt8, so],
    count: Int,
    dst: UnsafePointer[Int64, do],
):
    """1-bit unpack: each byte = 8 values, MSB-first.

    # SAFETY: `src` has >= ceil(count/8) bytes; `dst` has >= count slots.
    """
    comptime W = simd_width_of[DType.uint8]()
    var n_bytes = count // 8
    var i = 0
    var limit = n_bytes - (n_bytes % W)
    # Process W input bytes -> 8*W output values per iteration.
    while i < limit:
        var raw = src.load[width=W](i)  # SIMD[uint8, W]
        comptime for bit in range(8):
            var lane = (raw >> UInt8(7 - bit)) & 1
            var ext = lane.cast[DType.uint64]().cast[DType.int64]()
            # Output value for byte b, bit position `bit` is at index b*8 + bit.
            comptime for b in range(W):
                dst.store(8 * (i + b) + bit, ext[b])
        i += W
    # Whole-byte scalar tail.
    while i < n_bytes:
        var byte = Int(src[i])
        comptime for bit in range(8):
            dst.store(8 * i + bit, Int64((byte >> (7 - bit)) & 1))
        i += 1
    # Final partial byte (count not a multiple of 8).
    var done = n_bytes * 8
    if done < count:
        var byte = Int(src[n_bytes])
        var rem = count - done
        for bit in range(rem):
            dst.store(done + bit, Int64((byte >> (7 - bit)) & 1))


def _unpack_w2[
    so: Origin[mut=False], do: Origin[mut=True]
](
    src: UnsafePointer[UInt8, so],
    count: Int,
    dst: UnsafePointer[Int64, do],
):
    """2-bit unpack: each byte = 4 values, MSB-first (bits [7:6],[5:4],[3:2],[1:0]).

    # SAFETY: `src` has >= ceil(count*2/8) bytes; `dst` has >= count slots.
    """
    comptime W = simd_width_of[DType.uint8]()
    var n_bytes = count // 4
    var i = 0
    var limit = n_bytes - (n_bytes % W)
    while i < limit:
        var raw = src.load[width=W](i)
        comptime for f in range(4):
            var shift = UInt8(6 - 2 * f)
            var lane = (raw >> shift) & 0x3
            var ext = lane.cast[DType.uint64]().cast[DType.int64]()
            comptime for b in range(W):
                dst.store(4 * (i + b) + f, ext[b])
        i += W
    while i < n_bytes:
        var byte = Int(src[i])
        comptime for f in range(4):
            dst.store(4 * i + f, Int64((byte >> (6 - 2 * f)) & 0x3))
        i += 1
    var done = n_bytes * 4
    if done < count:
        var byte = Int(src[n_bytes])
        var rem = count - done
        for f in range(rem):
            dst.store(done + f, Int64((byte >> (6 - 2 * f)) & 0x3))


# =============================================================================
# Public entry — width-generic dispatch over a Span source/destination.
# =============================================================================


def simd_unpack_bits[
    so: Origin[mut=False], do: Origin[mut=True]
](
    src: Span[UInt8, so],
    bits: Int,
    count: Int,
    mut dst: Span[Int64, do],
) -> Bool:
    """Unpack `count` MSB-first bit-packed values of `bits` width from `src`
    into `dst[0..count]`. Returns True if a SIMD kernel handled the width (the
    full `count` was written), False if the width is not covered here (caller
    should fall back to its scalar bit-cursor).

    Covers: 0, 1, 2, and all byte-aligned widths (8/16/24/32/40/48/56/64).
    Width 4 is not covered (returns False; ORC has a dedicated caller for it).
    ORC also has dedicated callers for 8/16/32; this is the shared path for
    the byte-multiple widths the references leave scalar.

    Encapsulation: `src`/`dst` are borrowed/mutable Span views; the internal
    concrete-origin pointers below are used for SIMD load/store only and never
    escape this function.
    """
    if count == 0:
        return True
    if bits == 0:
        # SAFETY: dst pre-sized to >= count by caller.
        var dp = dst.unsafe_ptr()
        for i in range(count):
            dp.store[width=1](i, Int64(0))
        return True

    # Validate input has enough bytes for the contiguous packed run.
    var n_bytes = (bits * count + 7) // 8
    if len(src) < n_bytes or len(dst) < count:
        return False

    # SAFETY: `sp` reads exactly `n_bytes` (validated) from the immutable span;
    # `dp` writes exactly `count` slots (validated). Read/store only; no escape.
    var sp = src.unsafe_ptr()
    var dp = dst.unsafe_ptr()

    if bits == 1:
        _unpack_w1(sp, count, dp)
        return True
    if bits == 2:
        _unpack_w2(sp, count, dp)
        return True
    if (bits % 8) == 0:
        var B = bits // 8
        if B <= 4:
            _unpack_byte_aligned_le4(sp, count, dp, B)
        else:  # 5..8
            _unpack_byte_aligned_le8(sp, count, dp, B)
        return True
    return False
