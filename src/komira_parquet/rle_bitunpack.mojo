# =============================================================================
# RLE / Bit-Packing Hybrid: the bit-unpack kernels
# =============================================================================
#
# The bit-packed runs of the RLE / Bit-Packing Hybrid encoding (`rle.mojo`
# holds the decoder that calls these). A run packs 8-value groups at a fixed
# bit width, least significant bit first; each kernel unpacks up to
# `max_values` values into an Int32 output and returns how many it wrote.
#
# Every function here is private to the package: `RleDecoder` derives the
# pointers from its owned ByteBuffer and from the caller's output Span.
# =============================================================================

from std.sys import simd_width_of


# =============================================================================
# Bit-unpacking helpers
# =============================================================================
#
# These take UnsafePointer for both input (pack_data) and output because:
# 1. Input: they receive a slice pointer obtained from an origin-tied
#    `ByteBuffer.current_view()` + `ByteView._unsafe_ptr()` — the ByteBuffer
#    holds the bounds-checked state; the view's lifetime is borrow-tracked.
# 2. Output: they write into caller-allocated Int32 buffers (decode output).
#
# SAFETY: All pointer accesses are bounded by pack_len / max_values. The
# calling code (RleDecoder.decode_int32) ensures pack_data points within
# the ByteBuffer's valid range and output is pre-allocated to num_values.
# =============================================================================


@always_inline
def _unpack_bitwidth1[
    o_in: Origin[mut=True], o_out: Origin[mut=True]
](
    pack_data: UnsafePointer[UInt8, o_in],
    pack_len: Int,
    output: UnsafePointer[Int32, o_out],
    out_offset: Int,
    max_values: Int,
) -> Int:
    """Unpack bit_width=1 data. 8 values per byte. Returns values written.

    PERF-CRITICAL: SIMD per-byte broadcast +
    SIMD shift+mask emit for 8 output Int32s per byte. Mirrors the
    bw=8 SIMD shape. Scalar emit chain is replaced
    by a 1-load / 1-broadcast / 1-shift / 1-mask / 1-store-of-8 sequence.

    LLVM lowers `SIMD[i32, 8](b32) >> SHIFTS_8` to NEON `ushl.4s` chain
    or AVX2 `vpsrlvd ymm` / AVX-512 `vpsrlvd zmm`; the `& 1` mask is
    `vpand`. Per-byte work drops from ~16 dependent scalar ops to ~4
    SIMD ops.

    Hot on TPC-H Q3/Q6/Q14 def-level decode (every nullable column
    uses bit_width=1) and any boolean-encoded column.
    """
    var count = min(max_values, pack_len * 8)
    # SIMD path: process whole bytes that fully fit into max_values.
    # `full_byte_count` is the number of bytes whose 8 outputs all fit.
    var full_byte_count = min(pack_len, max_values // 8)
    var dest = output + out_offset
    # SHIFTS_8: comptime per-lane right-shift amounts [0,1,2,3,4,5,6,7]
    # applied to a broadcast i32(byte). Lane k gets (byte >> k) & 1.
    comptime SHIFTS_8: SIMD[DType.int32, 8] = SIMD[DType.int32, 8](
        0, 1, 2, 3, 4, 5, 6, 7
    )
    comptime ONE_8: SIMD[DType.int32, 8] = SIMD[DType.int32, 8](1)

    var byte_idx = 0
    while byte_idx < full_byte_count:
        # SAFETY: byte_idx < full_byte_count <= pack_len, so the byte
        # is in-bounds. dest + byte_idx*8 + 7 is the last write target;
        # written + 8 <= max_values by `byte_idx < max_values // 8`.
        var b = Int32((pack_data + byte_idx)[])
        var b_vec = SIMD[DType.int32, 8](b)
        var lanes = (b_vec >> SHIFTS_8) & ONE_8
        (dest + byte_idx * 8).store[width=8](lanes)
        byte_idx += 1

    var written = byte_idx * 8
    # Scalar tail: partial-byte (max_values not a multiple of 8) OR
    # truncated input (pack_len exhausted before max_values reached).
    while written < count and byte_idx < pack_len:
        var byte_val = Int((pack_data + byte_idx)[])
        var bits_left = min(8, count - written)
        for bit in range(bits_left):
            (dest + written)[] = Int32((byte_val >> bit) & 1)
            written += 1
        byte_idx += 1
    return written


@always_inline
def _unpack_bitwidth2[
    o_in: Origin[mut=True], o_out: Origin[mut=True]
](
    pack_data: UnsafePointer[UInt8, o_in],
    pack_len: Int,
    output: UnsafePointer[Int32, o_out],
    out_offset: Int,
    max_values: Int,
) -> Int:
    """Unpack bit_width=2 data. 4 values per byte. Returns values written.

    PERF-CRITICAL: SIMD per-byte broadcast +
    SIMD shift+mask emit for 4 output Int32s per byte. Mirrors the bw=8
    SIMD shape and the bw=1 SIMD shape above.

    LLVM lowers `SIMD[i32, 4](b32) >> SHIFTS_4` to NEON `ushl.4s` or
    AVX2 `vpsrlvd xmm`; the `& 0x03` mask is `vpand`. Per-byte work
    drops from ~8 dependent scalar ops to ~4 SIMD ops.
    """
    var count = min(max_values, pack_len * 4)
    var full_byte_count = min(pack_len, max_values // 4)
    var dest = output + out_offset
    # SHIFTS_4: per-lane shift amounts [0, 2, 4, 6] applied to a broadcast
    # i32(byte). Lane k gets (byte >> (k*2)) & 0x03.
    comptime SHIFTS_4: SIMD[DType.int32, 4] = SIMD[DType.int32, 4](0, 2, 4, 6)
    comptime MASK_4: SIMD[DType.int32, 4] = SIMD[DType.int32, 4](0x03)

    var byte_idx = 0
    while byte_idx < full_byte_count:
        # SAFETY: byte_idx < full_byte_count <= pack_len; written + 4 <=
        # max_values by `byte_idx < max_values // 4`.
        var b = Int32((pack_data + byte_idx)[])
        var b_vec = SIMD[DType.int32, 4](b)
        var lanes = (b_vec >> SHIFTS_4) & MASK_4
        (dest + byte_idx * 4).store[width=4](lanes)
        byte_idx += 1

    var written = byte_idx * 4
    # Scalar tail: partial-byte (max_values not a multiple of 4) OR
    # truncated input.
    while written < count and byte_idx < pack_len:
        var byte_val = Int((pack_data + byte_idx)[])
        var vals_left = min(4, count - written)
        for j in range(vals_left):
            (dest + written)[] = Int32((byte_val >> (j * 2)) & 0x03)
            written += 1
        byte_idx += 1
    return written


@always_inline
def _unpack_bitwidth4[
    o_in: Origin[mut=True], o_out: Origin[mut=True]
](
    pack_data: UnsafePointer[UInt8, o_in],
    pack_len: Int,
    output: UnsafePointer[Int32, o_out],
    out_offset: Int,
    max_values: Int,
) -> Int:
    """Unpack bit_width=4 data. 2 values per byte. Returns values written.

    PERF-CRITICAL: SIMD multi-byte
    interleave path. Loads 8 packed bytes (16 nibbles), splits into
    low+high nibble streams, casts to Int32, interleaves to restore
    [byte0_lo, byte0_hi, byte1_lo, byte1_hi, ...] order, stores 16
    contiguous Int32s. Mirrors the bw=8 SIMD shape but
    operates at half the byte rate (16 outputs per 8 input bytes).

    LLVM lowers:
      - `(bytes & 0x0F).cast[i32]()` → `vpand` + `vpmovzxbd`
      - `((bytes >> 4) & 0x0F).cast[i32]()` → `vpsrlw` + `vpand` + `vpmovzxbd`
      - `lo.interleave(hi)` → `vpunpckl/h` (x86) or `zip1/zip2` (NEON)
      - `store[width=16]` → `vmovdqu`/`vmovups`

    Per 8-byte iteration: ~6 SIMD ops vs 16 dependent scalar ops in the
    old loop. Hottest TPC-H column path: l_returnflag (3 distinct
    values, bw=2 actual but Parquet rounds dictionary widths up; in
    practice many lineitem dict columns land at bw=4 — l_shipinstruct
    (4 vals), l_shipmode (7 vals), l_linestatus (2 vals) all dictionary-
    encode at bw=4 in the SF=1 fixture).
    """
    var count = min(max_values, pack_len * 2)
    var full_byte_count = min(pack_len, max_values // 2)
    var dest = output + out_offset

    # SIMD body: process W=8 input bytes (= 16 output nibbles) per
    # iteration. We need full_byte_count >= 8 AND the 16-lane store
    # at `dest + byte_idx*2` must not run off the end.
    comptime W_BYTES: Int = 8
    comptime W_VALS: Int = 16  # 2 nibbles per byte
    comptime LO_MASK: SIMD[DType.uint8, W_BYTES] = SIMD[DType.uint8, W_BYTES](
        0x0F
    )
    var simd_end_bytes = (full_byte_count // W_BYTES) * W_BYTES
    var byte_idx = 0
    while byte_idx < simd_end_bytes:
        # SAFETY: byte_idx + W_BYTES <= full_byte_count <= pack_len.
        # dest + byte_idx*2 + W_VALS - 1 < max_values by
        # `simd_end_bytes <= max_values // 2`.
        var bytes_u8 = (pack_data + byte_idx).load[width=W_BYTES]()
        # Low nibbles: byte_k & 0x0F, then widen u8 -> i32.
        var lo_u8 = bytes_u8 & LO_MASK
        var lo_i32 = lo_u8.cast[DType.int32]()
        # High nibbles: (byte_k >> 4) & 0x0F (shift implicitly clears
        # high bits since u8). Widen u8 -> i32.
        var hi_u8 = bytes_u8 >> 4
        var hi_i32 = hi_u8.cast[DType.int32]()
        # Interleave restores per-byte ordering [lo0, hi0, lo1, hi1, ...].
        var out_vec = lo_i32.interleave(hi_i32)
        (dest + byte_idx * 2).store[width=W_VALS](out_vec)
        byte_idx += W_BYTES

    var written = byte_idx * 2
    # Scalar tail: handles 0..7 remaining whole bytes plus the
    # partial-byte case (max_values is odd) and truncated input.
    while written < count and byte_idx < pack_len:
        var byte_val = Int((pack_data + byte_idx)[])
        if written < count:
            (dest + written)[] = Int32(byte_val & 0x0F)
            written += 1
        if written < count:
            (dest + written)[] = Int32((byte_val >> 4) & 0x0F)
            written += 1
        byte_idx += 1
    return written


@always_inline
def _unpack_bitwidth8[
    o_in: Origin[mut=True], o_out: Origin[mut=True]
](
    pack_data: UnsafePointer[UInt8, o_in],
    pack_len: Int,
    output: UnsafePointer[Int32, o_out],
    out_offset: Int,
    max_values: Int,
) -> Int:
    """Unpack bit_width=8 data. 1 value per byte. Returns values written.

    Each byte becomes a 32-bit integer. We widen byte-by-byte since the
    source is u8 and the dest is i32 (no memcpy possible).
    """
    var count = min(max_values, pack_len)
    var dest = output + out_offset
    # PERF-CRITICAL: SIMD u8->i32 widening via .cast.
    # Mojo SIMD[DType.uint8, N].cast[DType.int32]() generates NEON
    # `uxtl` (unsigned extend long) chains: ldr q0, [x1], #16 / uxtl
    # v1.8h, v0.8b / uxtl.4s v2, v1.4h / ... producing 16 Int32s per
    # iteration. 4-8x faster than the old 4x-unrolled scalar loop.
    comptime W: Int = 16  # process 16 bytes at a time (NEON ldr q)
    var simd_end = (count // W) * W
    var i = 0
    while i < simd_end:
        var u8_vec = (pack_data + i).load[width=W]()
        var i32_vec = u8_vec.cast[DType.int32]()
        (dest + i).store[width=W](i32_vec)
        i += W
    # Scalar tail.
    while i < count:
        (dest + i)[] = Int32((pack_data + i)[])
        i += 1
    return count


@always_inline
def _simd_lanes_for_bw[BW: Int]() -> Int:
    """Comptime: choose the SIMD lane count for a given bit width.

    Constraint: all W*BW bits must fit inside a single u64 word AFTER the
    worst-case bit_offset of 7. So `7 + W*BW <= 64` → `W <= (64-7)/BW`.

    We cap by `simd_width_of[DType.int32]()` (typically 8 on AVX2 / 4 on
    NEON) and pick the largest power-of-2 that fits.
    """
    comptime W_NATIVE: Int = simd_width_of[DType.int32]()
    # Max lanes we can emit from a single u64 word at the worst-case
    # bit_offset = 7.
    comptime W_MAX: Int = (64 - 7) // BW
    # Pick the largest power-of-2 ≤ min(W_NATIVE, W_MAX).
    comptime W_RAW: Int = W_NATIVE if W_NATIVE < W_MAX else W_MAX
    # Round-down to power of two.
    comptime if W_RAW >= 16:
        return 16
    elif W_RAW >= 8:
        return 8
    elif W_RAW >= 4:
        return 4
    elif W_RAW >= 2:
        return 2
    else:
        return 1


@always_inline
def _build_shift_amounts[BW: Int, W: Int]() -> SIMD[DType.uint64, W]:
    """Comptime: build the lane shift-amount vector
    [0, BW, 2*BW, ..., (W-1)*BW]."""
    var v = SIMD[DType.uint64, W](0)
    comptime for i in range(W):
        v[i] = UInt64(i * BW)
    return v


@always_inline
def _unpack_generic_simd[
    BW: Int, o_in: Origin[mut=True], o_out: Origin[mut=True]
](
    pack_data: UnsafePointer[UInt8, o_in],
    pack_len: Int,
    output: UnsafePointer[Int32, o_out],
    out_offset: Int,
    max_values: Int,
) -> Int:
    """Comptime-specialized SIMD bit-unpacker for `bit_width = BW`.

    Vectorizes the inner shift+mask emit loop in `_unpack_generic`. The
    scalar path emits one Int32 per iteration:
        for _ in range(to_extract):
            output[written] = Int32(shifted & umask)
            shifted >>= BW
    This kernel emits W=`_simd_lanes_for_bw[BW]()` Int32s per iteration via
    a SIMD shift+mask:
        lane_i = (shifted >> (i * BW)) & umask     for i in 0..W
        store W contiguous lanes
        shifted >>= W * BW                          (scalar bookkeeping)

    The lane shift_amounts vector is comptime-known (depends only on BW).
    LLVM lowers `(SIMD[u64,W](shifted) >> shift_amounts) & umask_vec` to
    AVX2 vpsrlvq + vpand, or NEON ushl + and — no per-iteration scalar
    address arithmetic.

    Returns values written.
    """
    comptime W: Int = _simd_lanes_for_bw[BW]()
    comptime UMASK64: UInt64 = (UInt64(1) << UInt64(BW)) - UInt64(1) if BW < 64 else ~UInt64(0)
    comptime MASK_VEC: SIMD[DType.uint64, W] = SIMD[DType.uint64, W](UMASK64)
    comptime SHIFTS: SIMD[DType.uint64, W] = _build_shift_amounts[BW, W]()
    comptime W_BITS: Int = W * BW

    var mask32 = Int32(UMASK64 & UInt64(0xFFFFFFFF))
    var written = 0
    var bit_pos = 0

    # `safe_byte_limit = pack_len - 7` — `byte_idx + 8 <= pack_len`
    # required for the u64 load.
    var safe_byte_limit = pack_len - 7

    # -------- Fast path: SIMD shift+mask over W lanes per iteration ------
    #
    # The gate is `W >= 4`, not `W >= 2`. The W=2 SIMD path (BW ∈
    # {15, 16, 20, 24}) carries higher per-iteration overhead — broadcast
    # + lane-shift + mask + cast + store-2 — than the comptime-BW
    # word-extract scalar fallback below, which LLVM specializes the
    # `>> BW` and `(64 - bit_offset) // BW` arithmetic on. Inherent
    # AVX2 / AVX512 vector setup latency dominates W=2 work; W=4 (and
    # W=8 for narrow BWs) amortizes the setup. Comptime gate, so for
    # W < 4 the entire SIMD branch is dead-code-eliminated and the
    # function behaves identically to a comptime-BW version of
    # `_unpack_generic_runtime`. The common dictionary bit widths
    # (6, 10, 12, 14) all have W>=4, so they keep the SIMD path, and a
    # dictionary whose cardinality lands in the {15..16, 20, 24}
    # bit_width range avoids the W=2 overhead.
    comptime if W >= 4:
        while written + W <= max_values:
            var byte_idx = bit_pos >> 3
            if byte_idx >= safe_byte_limit:
                break
            var bit_offset = bit_pos & 7

            # SAFETY: byte_idx + 8 <= pack_len by the safe_byte_limit
            # guard. `pack_data` is bounded by the caller (module
            # docstring). Cast preserves origin.
            var word = (pack_data + byte_idx).bitcast[UInt64]().load[width=1]()

            # Verify all W lanes are inside this word's available bits:
            # we need `bit_offset + W*BW <= 64`. By construction of W
            # (see _simd_lanes_for_bw), this holds when
            # `bit_offset <= 64 - W*BW`. For most BWs this is always
            # true (W chosen to give slack at bit_offset=7). For tight
            # widths (W*BW > 57) we gate.
            comptime if W_BITS > 57:
                if bit_offset + W_BITS > 64:
                    break

            var shifted: UInt64 = word >> UInt64(bit_offset)
            # Broadcast `shifted` to W u64 lanes, lane-shift by SHIFTS,
            # mask, cast to Int32, store W contiguous Int32s.
            var lanes_u64 = SIMD[DType.uint64, W](shifted) >> SHIFTS
            var masked_u64 = lanes_u64 & MASK_VEC
            var lanes_i32 = masked_u64.cast[DType.int32]()
            (output + out_offset + written).store[width=W](lanes_i32)
            written += W
            bit_pos += W_BITS

    # -------- Slow path A: word-aligned scalar emit (one value at a time)
    # Used after the SIMD batch when 1 ≤ remaining < W and we still have
    # 8 safe bytes left in the input. This mirrors the original
    # word-extract loop and keeps the per-WORD I/O efficiency.
    while written < max_values:
        var byte_idx = bit_pos >> 3
        if byte_idx >= safe_byte_limit:
            break
        var bit_offset = bit_pos & 7

        # SAFETY: same as above.
        var word = (pack_data + byte_idx).bitcast[UInt64]().load[width=1]()

        var avail = (64 - bit_offset) // BW
        var to_extract = min(avail, max_values - written)

        var shifted = word >> UInt64(bit_offset)
        var umask = UMASK64
        for _ in range(to_extract):
            (output + out_offset + written)[] = Int32(Int(shifted & umask))
            shifted = shifted >> UInt64(BW)
            written += 1
        bit_pos += to_extract * BW

    # -------- Tail: per-value 5-byte LE assembly (preserves correctness)
    while written < max_values:
        var byte_idx = bit_pos >> 3
        var bit_offset = bit_pos & 7

        if byte_idx >= pack_len:
            break

        var val = 0
        var bytes_needed = ((bit_offset + BW) + 7) >> 3
        for b in range(min(bytes_needed, 5)):
            if byte_idx + b < pack_len:
                val = val | (Int((pack_data + byte_idx + b)[]) << (b * 8))

        val = val >> bit_offset
        (output + out_offset + written)[] = Int32(val) & mask32
        written += 1
        bit_pos += BW

    return written


@always_inline
def _unpack_generic_runtime[
    o_in: Origin[mut=True], o_out: Origin[mut=True]
](
    pack_data: UnsafePointer[UInt8, o_in],
    pack_len: Int,
    bit_width: Int,
    output: UnsafePointer[Int32, o_out],
    out_offset: Int,
    max_values: Int,
) -> Int:
    """Original (pre-SIMD) generic bit-unpacker — runtime bit_width path.

    Used as the FALLBACK kernel when `bit_width` is not in the comptime-
    specialized fast-path set. Keeping it here ensures correctness for
    arbitrary bit widths even if a producer emits an unusual width.

    Algorithm:
      1. Fast path: while `byte_idx + 8 <= pack_len`, load a u64 at
         pack_data[byte_idx..byte_idx+8], shift right by `bit_offset`,
         and emit `(64 - bit_offset) / bit_width` values via repeated
         shift+mask.
      2. Tail: per-value up-to-5-byte LE assembly.
    """
    var mask = Int32((1 << bit_width) - 1) if bit_width < 32 else Int32(-1)
    var written = 0
    var bit_pos = 0

    var safe_byte_limit = pack_len - 7
    while written < max_values:
        var byte_idx = bit_pos >> 3
        if byte_idx >= safe_byte_limit:
            break
        var bit_offset = bit_pos & 7

        # SAFETY: byte_idx + 8 <= pack_len by the safe_byte_limit guard.
        var word = (pack_data + byte_idx).bitcast[UInt64]().load[width=1]()

        var avail = (64 - bit_offset) // bit_width
        var to_extract = min(avail, max_values - written)

        var shifted = word >> UInt64(bit_offset)
        var umask = UInt64(Int(mask) & 0xFFFFFFFF)
        for _ in range(to_extract):
            (output + out_offset + written)[] = Int32(Int(shifted & umask))
            shifted = shifted >> UInt64(bit_width)
            written += 1
        bit_pos += to_extract * bit_width

    while written < max_values:
        var byte_idx = bit_pos >> 3
        var bit_offset = bit_pos & 7

        if byte_idx >= pack_len:
            break

        var val = 0
        var bytes_needed = ((bit_offset + bit_width) + 7) >> 3
        for b in range(min(bytes_needed, 5)):
            if byte_idx + b < pack_len:
                val = val | (Int((pack_data + byte_idx + b)[]) << (b * 8))

        val = val >> bit_offset
        (output + out_offset + written)[] = Int32(val) & mask
        written += 1
        bit_pos += bit_width

    return written


@always_inline
def _unpack_generic[
    o_in: Origin[mut=True], o_out: Origin[mut=True]
](
    pack_data: UnsafePointer[UInt8, o_in],
    pack_len: Int,
    bit_width: Int,
    output: UnsafePointer[Int32, o_out],
    out_offset: Int,
    max_values: Int,
) -> Int:
    """Generic bit-unpacker for arbitrary bit widths (1..32).

    The dispatcher: for the common parquet RLE
    bit widths {3, 5, 6, 7, 9..16, 20, 24, 32} we dispatch to a
    comptime-specialized SIMD kernel `_unpack_generic_simd[BW]` that
    vectorizes the inner shift+mask emit loop. Bit widths {1, 2, 4, 8}
    have their own dedicated u8-byte fast paths (`_unpack_bitwidth*`)
    higher up in this file and are not reached through this function.

    Reference impl: DuckDB's `extension/parquet/parquet_decoder.cpp`
    `BitUnpacker<W>` template. arrow-rs `parquet/src/encodings/rle.rs:
    unpack32_generic` relies on LLVM auto-vectorization; we hand-stage
    because Mojo does not autovectorize unit-stride emit loops.

    `RleDecoder.decode_int32` is one of the hottest symbols of a dictionary
    or nullable column decode.

    Returns values written.
    """
    # Dispatch on the runtime bit_width to a comptime-specialized SIMD
    # kernel. Each branch is `@always_inline` so the dispatcher inlines
    # into one of the specialized kernels; LLVM peels the dead branches.
    if bit_width == 3:
        return _unpack_generic_simd[3](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 5:
        return _unpack_generic_simd[5](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 6:
        return _unpack_generic_simd[6](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 7:
        return _unpack_generic_simd[7](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 9:
        return _unpack_generic_simd[9](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 10:
        return _unpack_generic_simd[10](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 11:
        return _unpack_generic_simd[11](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 12:
        return _unpack_generic_simd[12](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 13:
        return _unpack_generic_simd[13](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 14:
        return _unpack_generic_simd[14](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 15:
        return _unpack_generic_simd[15](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 16:
        return _unpack_generic_simd[16](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 20:
        return _unpack_generic_simd[20](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 24:
        return _unpack_generic_simd[24](
            pack_data, pack_len, output, out_offset, max_values
        )
    elif bit_width == 32:
        return _unpack_generic_simd[32](
            pack_data, pack_len, output, out_offset, max_values
        )
    else:
        # Fallback for unusual widths {17..19, 21..23, 25..31, etc}.
        # Correctness-only path.
        return _unpack_generic_runtime(
            pack_data, pack_len, bit_width, output, out_offset, max_values
        )
