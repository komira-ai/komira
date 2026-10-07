# =============================================================================
# BYTE_STREAM_SPLIT Encoding — optimal for floating-point columns
# =============================================================================
#
# BYTE_STREAM_SPLIT stores values by transposing their bytes into separate
# streams: all byte-0s of every value, then all byte-1s, etc. This clusters
# similar bytes together, dramatically improving compression ratio for
# floating-point data (similar exponent bytes, similar mantissa bytes).
#
# Input layout (for N values of W bytes each):
#   [byte0 of val0, byte0 of val1, ..., byte0 of valN-1]
#   [byte1 of val0, byte1 of val1, ..., byte1 of valN-1]
#   ...
#   [byteW-1 of val0, byteW-1 of val1, ..., byteW-1 of valN-1]
#
# Decode = transpose back to interleaved values. This module is the decode
# half; the encode half (interleaved to stream-split) belongs to the writer.
#
# Decode fast path: SIMD 16-value zip interleave via stdlib
# `shuffle[*mask: Int]`. The comptime mask compiles to NEON `zip1/zip2`
# (ARM) or `punpckl*/punpckh*` (x86) with zero FFI dispatch overhead.
#
# Scalar decode reference: block-transposition for L1
# cache locality (64 values per block = 512 bytes for f64, well within
# L1).
#
# Reference: parquet-format Encodings.md, BYTE_STREAM_SPLIT (9)
#
# SAFETY: every public function takes the encoded streams as a
# `Span[UInt8]` and checks that they hold `num_values * W` bytes, and an
# `_into` destination as a `ByteView` whose length it checks, before any
# byte is read or written. The private transpose kernels take the raw
# pointers derived from them: the transpose requires precise byte-offset
# arithmetic across interleaved streams.
# =============================================================================

from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.byte_view import ByteView


# Pure-Mojo SIMD decode via stdlib `shuffle[*mask: Int]`: the stdlib
# comptime shuffle compiles to the NEON zip1/zip2 sequence a C kernel would
# use, with zero external_call dispatch overhead.


# Block size for cache-friendly transposition (scalar fallback path).
# 64 values * 8 bytes = 512 bytes, well within L1 cache.
comptime BLOCK_SIZE = 64


# =============================================================================
# Decode — runtime type_size parameter (scalar block-transpose reference)
# =============================================================================


@always_inline
def _decode_byte_stream_split_impl[
    _mut: Bool, o_data: Origin[mut=_mut], //, o_out: Origin[mut=True]
](
    data: UnsafePointer[UInt8, o_data],
    num_values: Int,
    type_size: Int,
    output: UnsafePointer[UInt8, o_out],
):
    """Decode BYTE_STREAM_SPLIT using block transposition for cache locality.

    Processes BLOCK_SIZE values at a time. Each block reads consecutive bytes
    from each of type_size streams, producing interleaved output.

    Kept as the scalar reference path and as the oracle for the
    correctness tests in tests/test_neon_bss_decode.mojo. The public
    decode entry points route through `_simd_decode_f32/f64` below.

    Args:
        data: Pointer to the encoded byte streams.
        num_values: Number of values to decode.
        type_size: Byte width of each value (4 for f32, 8 for f64).
        output: Pointer to output buffer (must hold num_values * type_size bytes).
    """
    var stride = num_values
    var num_full_blocks = num_values // BLOCK_SIZE
    var remainder = num_values % BLOCK_SIZE

    # 4x manual unroll provides some ILP on the scalar byte transpose.
    for block in range(num_full_blocks):
        var block_start = block * BLOCK_SIZE
        var out_block = output + block_start * type_size
        for stream in range(type_size):
            var src = data + stream * stride + block_start
            # Unroll inner loop 4x for ILP.
            var full_iters = BLOCK_SIZE >> 2
            for q in range(full_iters):
                var base = q * 4
                (out_block + base * type_size + stream)[] = (src + base)[]
                (out_block + (base + 1) * type_size + stream)[] = (src + base + 1)[]
                (out_block + (base + 2) * type_size + stream)[] = (src + base + 2)[]
                (out_block + (base + 3) * type_size + stream)[] = (src + base + 3)[]

    # Process remainder (last partial block).
    if remainder > 0:
        var block_start = num_full_blocks * BLOCK_SIZE
        var out_block = output + block_start * type_size
        for stream in range(type_size):
            var src = data + stream * stride + block_start
            for i in range(remainder):
                (out_block + i * type_size + stream)[] = (src + i)[]


# =============================================================================
# SIMD decode fast path -- pure-Mojo shuffle-based zip interleave
# =============================================================================


@always_inline
def _simd_decode_f32[
    _mut: Bool, o_data: Origin[mut=_mut], //, o_dst: Origin[mut=True]
](
    data: UnsafePointer[UInt8, o_data],
    num_values: Int,
    dst: UnsafePointer[UInt8, o_dst],
):
    """f32 BSS decode via stdlib comptime shuffle.

    Processes 16 values (64 output bytes) per iteration via two rounds
    of zip interleave. Falls back to a byte-at-a-time tail for the
    remaining 0..15 values.

    PERF-CRITICAL: stdlib `shuffle[*mask: Int]` with a comptime mask
    lowers to `llvm.aarch64.neon.zip1/zip2` on ARM and `punpckl*/punpckh*`
    on x86. No FFI dispatch.

    SAFETY: caller guarantees `data` points to at least `num_values * 4`
    readable bytes arranged as 4 contiguous streams of `num_values`
    bytes each, and `dst` has at least `num_values * 4` writable bytes.
    """
    var n = num_values
    var i = 0
    while i + 16 <= n:
        # Load 16 bytes from each of the 4 streams.
        var b0 = (data + i).load[width=16](0)
        var b1 = (data + n + i).load[width=16](0)
        var b2 = (data + 2 * n + i).load[width=16](0)
        var b3 = (data + 3 * n + i).load[width=16](0)

        # Round 1: byte-pair zip (interleave b0 with b1, b2 with b3).
        # zip_lo_01 = [b0[0], b1[0], b0[1], b1[1], ..., b0[7], b1[7]]
        var zip_lo_01 = b0.shuffle[
            0, 16, 1, 17, 2, 18, 3, 19,
            4, 20, 5, 21, 6, 22, 7, 23,
        ](b1)
        var zip_hi_01 = b0.shuffle[
            8, 24, 9, 25, 10, 26, 11, 27,
            12, 28, 13, 29, 14, 30, 15, 31,
        ](b1)
        var zip_lo_23 = b2.shuffle[
            0, 16, 1, 17, 2, 18, 3, 19,
            4, 20, 5, 21, 6, 22, 7, 23,
        ](b3)
        var zip_hi_23 = b2.shuffle[
            8, 24, 9, 25, 10, 26, 11, 27,
            12, 28, 13, 29, 14, 30, 15, 31,
        ](b3)

        # Round 2: byte-quad zip -> final 4-byte f32 words.
        # Pattern: 2 bytes from zip_*_01 then 2 bytes from zip_*_23.
        var out0 = zip_lo_01.shuffle[
            0, 1, 16, 17, 2, 3, 18, 19,
            4, 5, 20, 21, 6, 7, 22, 23,
        ](zip_lo_23)
        var out1 = zip_lo_01.shuffle[
            8, 9, 24, 25, 10, 11, 26, 27,
            12, 13, 28, 29, 14, 15, 30, 31,
        ](zip_lo_23)
        var out2 = zip_hi_01.shuffle[
            0, 1, 16, 17, 2, 3, 18, 19,
            4, 5, 20, 21, 6, 7, 22, 23,
        ](zip_hi_23)
        var out3 = zip_hi_01.shuffle[
            8, 9, 24, 25, 10, 11, 26, 27,
            12, 13, 28, 29, 14, 15, 30, 31,
        ](zip_hi_23)

        (dst + i * 4).store(0, out0)
        (dst + i * 4 + 16).store(0, out1)
        (dst + i * 4 + 32).store(0, out2)
        (dst + i * 4 + 48).store(0, out3)

        i += 16

    # Scalar tail (0..15 remaining values).
    while i < n:
        dst[i * 4 + 0] = (data + i)[]
        dst[i * 4 + 1] = (data + n + i)[]
        dst[i * 4 + 2] = (data + 2 * n + i)[]
        dst[i * 4 + 3] = (data + 3 * n + i)[]
        i += 1


@always_inline
def _simd_decode_f64[
    _mut: Bool, o_data: Origin[mut=_mut], //, o_dst: Origin[mut=True]
](
    data: UnsafePointer[UInt8, o_data],
    num_values: Int,
    dst: UnsafePointer[UInt8, o_dst],
):
    """f64 BSS decode via stdlib comptime shuffle.

    Processes 16 values (128 output bytes) per iteration across 8
    streams using three rounds of zip interleave.

    PERF-CRITICAL: same rationale as _simd_decode_f32.

    SAFETY: caller guarantees `data` points to at least `num_values * 8`
    readable bytes arranged as 8 contiguous streams of `num_values`
    bytes each, and `dst` has at least `num_values * 8` writable bytes.
    """
    var n = num_values
    var i = 0
    while i + 16 <= n:
        # Load 16 bytes from each of the 8 streams.
        var b0 = (data + 0 * n + i).load[width=16](0)
        var b1 = (data + 1 * n + i).load[width=16](0)
        var b2 = (data + 2 * n + i).load[width=16](0)
        var b3 = (data + 3 * n + i).load[width=16](0)
        var b4 = (data + 4 * n + i).load[width=16](0)
        var b5 = (data + 5 * n + i).load[width=16](0)
        var b6 = (data + 6 * n + i).load[width=16](0)
        var b7 = (data + 7 * n + i).load[width=16](0)

        # Round 1: byte-pair zip.
        var z01_lo = b0.shuffle[
            0, 16, 1, 17, 2, 18, 3, 19,
            4, 20, 5, 21, 6, 22, 7, 23,
        ](b1)
        var z01_hi = b0.shuffle[
            8, 24, 9, 25, 10, 26, 11, 27,
            12, 28, 13, 29, 14, 30, 15, 31,
        ](b1)
        var z23_lo = b2.shuffle[
            0, 16, 1, 17, 2, 18, 3, 19,
            4, 20, 5, 21, 6, 22, 7, 23,
        ](b3)
        var z23_hi = b2.shuffle[
            8, 24, 9, 25, 10, 26, 11, 27,
            12, 28, 13, 29, 14, 30, 15, 31,
        ](b3)
        var z45_lo = b4.shuffle[
            0, 16, 1, 17, 2, 18, 3, 19,
            4, 20, 5, 21, 6, 22, 7, 23,
        ](b5)
        var z45_hi = b4.shuffle[
            8, 24, 9, 25, 10, 26, 11, 27,
            12, 28, 13, 29, 14, 30, 15, 31,
        ](b5)
        var z67_lo = b6.shuffle[
            0, 16, 1, 17, 2, 18, 3, 19,
            4, 20, 5, 21, 6, 22, 7, 23,
        ](b7)
        var z67_hi = b6.shuffle[
            8, 24, 9, 25, 10, 26, 11, 27,
            12, 28, 13, 29, 14, 30, 15, 31,
        ](b7)

        # Round 2: byte-quad zip -> 4-byte groups.
        var q0123_0 = z01_lo.shuffle[
            0, 1, 16, 17, 2, 3, 18, 19,
            4, 5, 20, 21, 6, 7, 22, 23,
        ](z23_lo)
        var q0123_1 = z01_lo.shuffle[
            8, 9, 24, 25, 10, 11, 26, 27,
            12, 13, 28, 29, 14, 15, 30, 31,
        ](z23_lo)
        var q0123_2 = z01_hi.shuffle[
            0, 1, 16, 17, 2, 3, 18, 19,
            4, 5, 20, 21, 6, 7, 22, 23,
        ](z23_hi)
        var q0123_3 = z01_hi.shuffle[
            8, 9, 24, 25, 10, 11, 26, 27,
            12, 13, 28, 29, 14, 15, 30, 31,
        ](z23_hi)
        var q4567_0 = z45_lo.shuffle[
            0, 1, 16, 17, 2, 3, 18, 19,
            4, 5, 20, 21, 6, 7, 22, 23,
        ](z67_lo)
        var q4567_1 = z45_lo.shuffle[
            8, 9, 24, 25, 10, 11, 26, 27,
            12, 13, 28, 29, 14, 15, 30, 31,
        ](z67_lo)
        var q4567_2 = z45_hi.shuffle[
            0, 1, 16, 17, 2, 3, 18, 19,
            4, 5, 20, 21, 6, 7, 22, 23,
        ](z67_hi)
        var q4567_3 = z45_hi.shuffle[
            8, 9, 24, 25, 10, 11, 26, 27,
            12, 13, 28, 29, 14, 15, 30, 31,
        ](z67_hi)

        # Round 3: byte-octet zip -> 8-byte f64 words.
        var o0 = q0123_0.shuffle[
            0, 1, 2, 3, 16, 17, 18, 19,
            4, 5, 6, 7, 20, 21, 22, 23,
        ](q4567_0)
        var o1 = q0123_0.shuffle[
            8, 9, 10, 11, 24, 25, 26, 27,
            12, 13, 14, 15, 28, 29, 30, 31,
        ](q4567_0)
        var o2 = q0123_1.shuffle[
            0, 1, 2, 3, 16, 17, 18, 19,
            4, 5, 6, 7, 20, 21, 22, 23,
        ](q4567_1)
        var o3 = q0123_1.shuffle[
            8, 9, 10, 11, 24, 25, 26, 27,
            12, 13, 14, 15, 28, 29, 30, 31,
        ](q4567_1)
        var o4 = q0123_2.shuffle[
            0, 1, 2, 3, 16, 17, 18, 19,
            4, 5, 6, 7, 20, 21, 22, 23,
        ](q4567_2)
        var o5 = q0123_2.shuffle[
            8, 9, 10, 11, 24, 25, 26, 27,
            12, 13, 14, 15, 28, 29, 30, 31,
        ](q4567_2)
        var o6 = q0123_3.shuffle[
            0, 1, 2, 3, 16, 17, 18, 19,
            4, 5, 6, 7, 20, 21, 22, 23,
        ](q4567_3)
        var o7 = q0123_3.shuffle[
            8, 9, 10, 11, 24, 25, 26, 27,
            12, 13, 14, 15, 28, 29, 30, 31,
        ](q4567_3)

        (dst + i * 8 +   0).store(0, o0)
        (dst + i * 8 +  16).store(0, o1)
        (dst + i * 8 +  32).store(0, o2)
        (dst + i * 8 +  48).store(0, o3)
        (dst + i * 8 +  64).store(0, o4)
        (dst + i * 8 +  80).store(0, o5)
        (dst + i * 8 +  96).store(0, o6)
        (dst + i * 8 + 112).store(0, o7)

        i += 16

    # Scalar tail (0..15 remaining values).
    while i < n:
        dst[i * 8 + 0] = (data + 0 * n + i)[]
        dst[i * 8 + 1] = (data + 1 * n + i)[]
        dst[i * 8 + 2] = (data + 2 * n + i)[]
        dst[i * 8 + 3] = (data + 3 * n + i)[]
        dst[i * 8 + 4] = (data + 4 * n + i)[]
        dst[i * 8 + 5] = (data + 5 * n + i)[]
        dst[i * 8 + 6] = (data + 6 * n + i)[]
        dst[i * 8 + 7] = (data + 7 * n + i)[]
        i += 1


# =============================================================================
# The page-extent gate — ONE statement of it, every caller
# =============================================================================


@always_inline
def _require_bss_page_extent[
    type_name: StaticString, elem_size: Int
](
    num_values: Int,
    data_len: Int,
) raises -> Int:
    """Refuse a page that cannot hold `num_values` encoded values.

    `num_values` comes off the page header and `_simd_decode_f32/f64` then walk
    the byte-streams by RAW POINTER OFFSET, reading `num_values * W` bytes with
    nothing in between — the four/eight streams are not a bounds-checked view.
    Without this gate a header declaring a million values over a 16-byte page
    reads megabytes past the page.

    ⚠ THE GATE BELONGS TO THE DECODE, NOT TO THE ALLOCATION. The `_into`
    variants have no allocation of their own to bound them, so every entry
    point states the gate by CALLING this function.

    ONE compare per page. It rejects nothing a conforming writer emits:
    BYTE_STREAM_SPLIT is exactly `num_values * W` bytes, so the bound is an
    EQUALITY on every real page.

    The count is compared with `data_len // elem_size` BEFORE anything is
    multiplied: `num_values * elem_size` wraps for a count near 2^64 / W (a
    count of 2^62 + 16 Float32s is 64 bytes after the wrap), and a gate on the
    wrapped product would let the kernel walk 2^62 values past a 64-byte page.

    Parameters:
        type_name: "float32" or "float64", for the error message only.
        elem_size: Bytes per encoded value (4 or 8).

    Returns:
        `num_values * elem_size`, the page's byte count; it cannot wrap,
        because it is at most `data_len`.
    """
    if num_values < 0 or num_values > data_len // elem_size:
        raise Error(
            "parquet: corrupt BYTE_STREAM_SPLIT page: declares "
            + String(num_values)
            + " "
            + String(type_name)
            + " values of "
            + String(elem_size)
            + " bytes but the page body holds only "
            + String(data_len)
            + " bytes"
        )
    return num_values * elem_size


@always_inline
def _require_bss_dst_extent(
    byte_count: Int,
    dst_len: Int,
) raises:
    """The DESTINATION half of the gate.

    `decode_byte_stream_split_*` allocate their own destination, so its size is
    true by construction. An `_into` decode is handed a bounded `ByteView`, so
    it can say NO — and this is the only place in the BSS path that can.
    """
    if byte_count > dst_len:
        raise Error(
            "parquet: BYTE_STREAM_SPLIT destination too small: the page"
            " decodes to "
            + String(byte_count)
            + " bytes but the destination window holds only "
            + String(dst_len)
            + " bytes"
        )


# =============================================================================
# Public API — Float32 / Float64 decode
# =============================================================================


def decode_byte_stream_split_float32(
    data: Span[UInt8, _],
    num_values: Int,
) raises -> PrimitiveArray[DType.float32]:
    """Decode BYTE_STREAM_SPLIT encoded Float32 values via pure-Mojo SIMD.

    Input layout: [all byte0s][all byte1s][all byte2s][all byte3s]
    Output: interleaved Float32 values.

    PERF-CRITICAL: uses stdlib `shuffle[*mask: Int]` which compiles to
    NEON zip1/zip2 (or SSE punpckl*/punpckh*), with zero external_call
    dispatch overhead.

    Args:
        data: The encoded byte streams (at least num_values * 4 bytes).
        num_values: Number of Float32 values to decode.

    Returns:
        A non-nullable PrimitiveArray[DType.float32] containing the decoded values.

    Raises:
        Error if the page cannot hold `num_values` encoded floats.
    """
    if num_values == 0:
        return PrimitiveArray[DType.float32].allocate(0)

    comptime elem_size = size_of[Scalar[DType.float32]]()
    var byte_count = _require_bss_page_extent["float32", elem_size](
        num_values, len(data)
    )
    var buf = OwnedAlignedBuffer(byte_count)

    # Dest via origin-tied `view_range_mut`; `_simd_decode_f32`
    # is origin-polymorphic.
    # SAFETY: `data` holds at least `byte_count` bytes (checked above) and
    # the view `byte_count` writable ones.
    var buf_view = buf.view_range_mut(0, byte_count)
    _simd_decode_f32(data.unsafe_ptr(), num_values, buf_view._unsafe_ptr())
    buf.set_length(Int64(byte_count))

    return PrimitiveArray[DType.float32](buf^, num_values, None, 0, 0)


def decode_byte_stream_split_float64(
    data: Span[UInt8, _],
    num_values: Int,
) raises -> PrimitiveArray[DType.float64]:
    """Decode BYTE_STREAM_SPLIT encoded Float64 values via pure-Mojo SIMD.

    Input layout: [all byte0s][all byte1s]...[all byte7s]
    Output: interleaved Float64 values.

    PERF-CRITICAL: same rationale as the f32 variant. Three rounds of
    zip interleave collapse 8 streams into interleaved 8-byte f64
    words.

    Args:
        data: The encoded byte streams (at least num_values * 8 bytes).
        num_values: Number of Float64 values to decode.

    Returns:
        A non-nullable PrimitiveArray[DType.float64] containing the decoded values.

    Raises:
        Error if the page cannot hold `num_values` encoded doubles.
    """
    if num_values == 0:
        return PrimitiveArray[DType.float64].allocate(0)

    comptime elem_size = size_of[Scalar[DType.float64]]()
    var byte_count = _require_bss_page_extent["float64", elem_size](
        num_values, len(data)
    )
    var buf = OwnedAlignedBuffer(byte_count)

    # Dest via origin-tied `view_range_mut`.
    # SAFETY: as in the Float32 variant.
    var buf_view = buf.view_range_mut(0, byte_count)
    _simd_decode_f64(data.unsafe_ptr(), num_values, buf_view._unsafe_ptr())
    buf.set_length(Int64(byte_count))

    return PrimitiveArray[DType.float64](buf^, num_values, None, 0, 0)


# =============================================================================
# Public API — decode STRAIGHT INTO a caller-owned destination
# =============================================================================
#
# The two wrappers above allocate `num_values * W` bytes, transpose into them,
# and hand back a `PrimitiveArray`; a page decoder that writes a column chunk
# into one buffer would then copy that array into its own buffer and drop it:
# allocate -> transpose -> copy -> free, once per PAGE. These two entry points
# are the wrapper body with that allocation removed and the destination
# supplied by the caller.
#
# WHY A `ByteView` AND NOT A POINTER: the destination is the ONE thing this
# function cannot validate for itself, and a raw pointer carries no length to
# validate against. `ByteView` does, so `_require_bss_dst_extent` can refuse a
# page that would run past the caller's buffer.
#
# ALIGNMENT: the kernel's SIMD stores are 16 bytes wide and a destination
# offset need not be 16-aligned. That is safe because the kernel is unaligned
# on both sides: its source loads are `(data + k * n + i).load[width=16](0)`
# at arbitrary byte offsets for arbitrary `n`, and Mojo's `UnsafePointer`
# load/store default to element alignment (1 for `UInt8`) on CPU targets.


def decode_byte_stream_split_float32_into[
    o_dst: Origin[mut=True]
](
    data: Span[UInt8, _],
    num_values: Int,
    dst: ByteView[o_dst],
) raises:
    """Decode a BYTE_STREAM_SPLIT Float32 page DIRECTLY into `dst`.

    Byte-for-byte the same output as `decode_byte_stream_split_float32`, minus
    the intermediate `PrimitiveArray` — see the block comment above.

    Args:
        data: The encoded byte streams (at least num_values * 4 bytes).
        num_values: Number of Float32 values to decode.
        dst: Destination window. Must hold at least `num_values * 4` bytes;
            exactly `num_values * 4` of them are written.

    Raises:
        Error if the page cannot hold `num_values` encoded floats, or if `dst`
        is too small to receive them.
    """
    if num_values == 0:
        return

    comptime elem_size = size_of[Scalar[DType.float32]]()
    var byte_count = _require_bss_page_extent["float32", elem_size](
        num_values, len(data)
    )
    _require_bss_dst_extent(byte_count, dst.len())

    # SAFETY: both extents are checked immediately above — `data` holds at
    # least `byte_count` readable bytes and `dst` at least `byte_count`
    # writable ones. `dst._unsafe_ptr()` is origin-tied to `o_dst` (no wildcard
    # origin, no address rebuilt from an integer) and does not escape this call;
    # `_simd_decode_f32` is origin-polymorphic on both sides.
    _simd_decode_f32(data.unsafe_ptr(), num_values, dst._unsafe_ptr())


def decode_byte_stream_split_float64_into[
    o_dst: Origin[mut=True]
](
    data: Span[UInt8, _],
    num_values: Int,
    dst: ByteView[o_dst],
) raises:
    """Decode a BYTE_STREAM_SPLIT Float64 page DIRECTLY into `dst`.

    The f64 twin of `decode_byte_stream_split_float32_into`. Same contract.

    Args:
        data: The encoded byte streams (at least num_values * 8 bytes).
        num_values: Number of Float64 values to decode.
        dst: Destination window. Must hold at least `num_values * 8` bytes;
            exactly `num_values * 8` of them are written.

    Raises:
        Error if the page cannot hold `num_values` encoded doubles, or if `dst`
        is too small to receive them.
    """
    if num_values == 0:
        return

    comptime elem_size = size_of[Scalar[DType.float64]]()
    var byte_count = _require_bss_page_extent["float64", elem_size](
        num_values, len(data)
    )
    _require_bss_dst_extent(byte_count, dst.len())

    # SAFETY: see `decode_byte_stream_split_float32_into`.
    _simd_decode_f64(data.unsafe_ptr(), num_values, dst._unsafe_ptr())
