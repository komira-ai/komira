# =============================================================================
# PLAIN FIXED_LEN_BYTE_ARRAY decoders — the raw bytes and the DECIMAL to
# Float64 conversion. The other PLAIN decoders are in `plain`.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of, simd_width_of

from komira_arrow.binary_array import BinaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from .plain import _require_plain_extent

# =============================================================================
# FIXED_LEN_BYTE_ARRAY (FLBA) decode
# =============================================================================
#
# PLAIN encoding of FIXED_LEN_BYTE_ARRAY stores N bytes per value, back-to-back,
# with NO length prefix (unlike BYTE_ARRAY). The byte width N is fixed per
# column and is carried in the schema element (type_length).
#
# The raw decoder produces a BinaryArray for generic use. The DECIMAL
# specialisation produces a Float64 array by interpreting each N-byte value
# as a big-endian signed integer and dividing by 10^scale.
#
# Reference: Parquet spec — FIXED_LEN_BYTE_ARRAY PLAIN encoding,
#            DECIMAL logical type (big-endian two's-complement).
# =============================================================================


def decode_plain_fixed_len_byte_array(
    data: Span[UInt8, _],
    num_values: Int,
    type_length: Int,
) raises -> BinaryArray[HeapRegion]:
    """Decode PLAIN-encoded FIXED_LEN_BYTE_ARRAY values into a BinaryArray.

    Parquet PLAIN FIXED_LEN_BYTE_ARRAY format: `type_length` bytes per value,
    packed back-to-back with no length prefix. The returned BinaryArray has
    one logical element per value, each of width `type_length`.

    Args:
        data: The page: the PLAIN-encoded FLBA bytes. The final memcpy reads
            `num_values * type_length` bytes and refuses a shorter page;
            BOTH factors come off attacker-controlled metadata (`num_values`
            from the page header, `type_length` from the schema element).
        num_values: Number of values to decode.
        type_length: Byte width of each value (the N in FLBA(N)).

    Returns:
        A non-nullable BinaryArray with offsets [0, N, 2N, ..., num_values*N].

    Raises:
        Error if the page body cannot hold `num_values` values of
        `type_length` bytes, if `type_length` is negative, or if the values
        take more bytes than Int32 offsets can address.
    """
    if type_length < 0:
        raise Error(
            "parquet: corrupt FIXED_LEN_BYTE_ARRAY column: negative"
            " type_length " + String(type_length)
        )
    _require_plain_extent("PLAIN FLBA", num_values, type_length, len(data))
    # The offsets are Int32: past 2^31 - 1 bytes of values the last offsets
    # would wrap negative. A Parquet page size is an Int32, so no page does.
    if num_values * type_length > 2147483647:
        raise Error(
            "parquet: PLAIN FLBA page of "
            + String(num_values)
            + " values of "
            + String(type_length)
            + " bytes is past the 2147483647 bytes Int32 offsets can address"
        )
    # Empty array: single zero offset, no data.
    if num_values == 0 or type_length == 0:
        # Write via `set_typed[Int32]`.
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer(int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))
        offsets_buf.set_length(Int64(int32_size))

        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(Int64(0))

        return BinaryArray[HeapRegion](offsets_buf^, data_buf^, None, 0, 0, 0)

    # Allocate offsets buffer (N+1 Int32 entries, evenly spaced by type_length).
    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer((num_values + 1) * int32_size)
    var total_bytes = num_values * type_length
    # PERF-CRITICAL: SIMD-iota for FLBA offsets.
    # offsets[i] = i * type_length is a stride-K linear sequence. The
    # compiler does NOT auto-vectorize the scalar Int32(i * type_length)
    # store loop. We build a base vector [0,1,...,W-1]*K and bump by
    # W*K each stride — the shape of komira_simd's iota helper
    # but with a custom stride. On ARM NEON (W=4 for int32) this fires
    # `stp q0, q1, [x0], #32` pairs instead of scalar `str w9, [x0,#N]`.
    #
    # SIMD store via `OwnedAlignedBuffer.store_simd[DType.int32, W]`,
    # byte-offset addressed. Same NEON `stp q0, q1` codegen.
    var total_offsets = num_values + 1
    comptime W: Int = simd_width_of[DType.int32]()
    var stride = Int32(type_length)
    var lane_offsets = SIMD[DType.int32, W](0)
    comptime for j in range(W):
        lane_offsets[j] = Int32(j) * stride
    var simd_base = lane_offsets  # [0, K, 2K, ..., (W-1)K]
    var simd_stride_vec = SIMD[DType.int32, W](Int32(W) * stride)
    var simd_end = (total_offsets // W) * W
    var i = 0
    while i < simd_end:
        offsets_buf.store_simd[DType.int32, W](
            i * int32_size, simd_base
        )
        simd_base += simd_stride_vec
        i += W
    # Scalar tail (<W iterations).
    while i < total_offsets:
        offsets_buf.set_typed[Int32](i, Int32(i) * stride)
        i += 1
    offsets_buf.set_length(Int64((num_values + 1) * int32_size))


    # Single memcpy for the contiguous data — PLAIN FLBA is already packed.
    # Dest via origin-tied `view_range_mut`.
    var data_buf = OwnedAlignedBuffer(total_bytes)
    var data_dst_view = data_buf.view_range_mut(0, total_bytes)
    unsafe_memcpy(
        dest=data_dst_view._unsafe_ptr(), src=data.unsafe_ptr(), count=total_bytes
    )
    data_buf.set_length(Int64(total_bytes))


    return BinaryArray[HeapRegion](
        offsets_buf^, data_buf^, None, num_values, total_bytes, 0
    )


# =============================================================================
# PERF-CRITICAL: Cross-row SIMD bswap for FLBA decimal decode
# =============================================================================
# Regression if removed: FLBA decimal decode dominates the decode of a
# TPC-H lineitem table written with FLBA decimals (TPC-H Q1 wall +10-15%).
#
# The hot loop scalar shape is an 8-iteration big-endian byte unpack per row,
# followed by Int64->Float64 cast and a multiply by inv_divisor. LLVM
# does NOT autovectorize this -- the byte-level unpack defeats it. The
# replacement is a CROSS-ROW SIMD body: W rows
# in parallel where W = simd_width_of[Float64] (NEON 2 / AVX2 4 / AVX-512 8).
#
# Each lane:
#   1. Scalar load 8 BE bytes from value[k]: lane k <- *(uint64*)(data + base[k])
#      The bytes are BIG-ENDIAN on disk; the load reinterprets little-endian
#      so we must bswap to recover the native Int64 bit pattern.
#   2. SIMD bswap via shift+OR+AND (LLVM lowers to `rev64.16b` on NEON,
#      `bswap r64` / `vpshufb` on x86).
#   3. Cast to int64 (no-op bit-cast).
#   4. Cast int64 -> float64 (`scvtf` NEON / `vcvtqq2pd` AVX-512;
#      AVX2 emulates via 2 scalar f64 conversions, still beats per-row
#      scalar by 2-3x).
#   5. SIMD multiply by inv_divisor broadcast.
#   6. Store W float64 values.
#
# Tail handling: scalar fallback (existing _flba_value_to_int64_be call site
# pattern) for n % W rows.
# =============================================================================


@always_inline
def _simd_bswap_u64[W: Int](v: SIMD[DType.uint64, W]) -> SIMD[DType.uint64, W]:
    """Per-lane byte-swap (BE <-> LE) on a SIMD[uint64, W] vector.

    Built from SIMD shift+OR+AND. Mojo does not surface a portable
    `byte_swap` SIMD primitive, but LLVM pattern-matches the canonical
    8-shift-OR shape into `rev64.16b` (NEON) / `bswap r64` (x86) / a single
    `vpshufb` (AVX-512 with comptime mask).

    Parameters:
        W: SIMD lane count.

    Args:
        v: SIMD lanes holding values in their native (LE) bit pattern.

    Returns:
        SIMD lanes with each lane's 8 bytes reversed.
    """
    var mask_ff = SIMD[DType.uint64, W](0x00000000000000FF)
    var mask_ff00 = SIMD[DType.uint64, W](0x000000000000FF00)
    var mask_ff0000 = SIMD[DType.uint64, W](0x0000000000FF0000)
    var mask_ff000000 = SIMD[DType.uint64, W](0x00000000FF000000)

    # Reverse the 8 bytes within each lane:
    #   out[7] = in[0], out[6] = in[1], ..., out[0] = in[7]
    var b7 = (v & mask_ff) << UInt64(56)
    var b6 = (v & mask_ff00) << UInt64(40)
    var b5 = (v & mask_ff0000) << UInt64(24)
    var b4 = (v & mask_ff000000) << UInt64(8)
    var b3 = (v >> UInt64(8)) & mask_ff000000
    var b2 = (v >> UInt64(24)) & mask_ff0000
    var b1 = (v >> UInt64(40)) & mask_ff00
    var b0 = (v >> UInt64(56)) & mask_ff
    return b7 | b6 | b5 | b4 | b3 | b2 | b1 | b0


@always_inline
def _decode_flba16_simd_chunk[
    W: Int, o_data: Origin, o_out: Origin[mut=True]
](
    data: UnsafePointer[UInt8, o_data],
    out_ptr: UnsafePointer[Scalar[DType.float64], o_out],
    base_row: Int,
    inv_divisor: Float64,
):
    """Decode W FLBA(16) DECIMAL values into Float64 lanes (cross-row SIMD).

    The FLBA(16) value at row k starts at byte offset (base_row + k)*16. The
    low 8 BE bytes (bytes [8..15]) hold the signed two's-complement int64;
    the upper 8 bytes are sign extension when the magnitude fits in Int64
    (true for every TPC-H DECIMAL column, max precision 15).

    Parameters:
        W: SIMD lane count (= simd_width_of[DType.float64]()).
        o_data: origin of the input FLBA buffer.
        o_out: mutable origin of the float64 output buffer.

    Args:
        data: pointer to the start of the FLBA(16)-packed buffer.
        out_ptr: float64 output buffer typed pointer.
        base_row: starting row index for this chunk (multiple of W).
        inv_divisor: 1 / 10^scale, broadcast across lanes.

    SAFETY:
        Caller must guarantee that data points to at least
        (base_row + W) * 16 bytes, and out_ptr to at least base_row + W
        float64 slots.
    """
    var raw = SIMD[DType.uint64, W](0)
    comptime for k in range(W):
        var lane_ptr = data + (base_row + k) * 16 + 8
        # SAFETY: 8 bytes in-bounds per the caller's chunk-end guarantee.
        raw[k] = lane_ptr.bitcast[Scalar[DType.uint64]]().load[width=1]()
    var be_swapped = _simd_bswap_u64[W](raw)
    var as_i64 = be_swapped.cast[DType.int64]()
    var as_f64 = as_i64.cast[DType.float64]() * SIMD[DType.float64, W](inv_divisor)
    out_ptr.store[width=W](base_row, as_f64)


@always_inline
def _decode_flba8_simd_chunk[
    W: Int, o_data: Origin, o_out: Origin[mut=True]
](
    data: UnsafePointer[UInt8, o_data],
    out_ptr: UnsafePointer[Scalar[DType.float64], o_out],
    base_row: Int,
    inv_divisor: Float64,
):
    """Decode W FLBA(8) DECIMAL values into Float64 lanes (cross-row SIMD).

    The FLBA(8) value at row k starts at byte offset (base_row + k)*8 and
    is the full 8-BE-byte signed int64. No sign-extend needed — the int64
    fully represents any DECIMAL with precision <= 18.

    Parameters:
        W: SIMD lane count.
        o_data: origin of the input FLBA buffer.
        o_out: mutable origin of the float64 output buffer.

    Args:
        data: pointer to the start of the FLBA(8)-packed buffer.
        out_ptr: float64 output buffer typed pointer.
        base_row: starting row index for this chunk (multiple of W).
        inv_divisor: 1 / 10^scale, broadcast across lanes.

    SAFETY:
        Caller must guarantee that data points to at least
        (base_row + W) * 8 bytes, and out_ptr to at least base_row + W
        float64 slots.
    """
    var raw = SIMD[DType.uint64, W](0)
    comptime for k in range(W):
        var lane_ptr = data + (base_row + k) * 8
        raw[k] = lane_ptr.bitcast[Scalar[DType.uint64]]().load[width=1]()
    var be_swapped = _simd_bswap_u64[W](raw)
    var as_i64 = be_swapped.cast[DType.int64]()
    var as_f64 = as_i64.cast[DType.float64]() * SIMD[DType.float64, W](inv_divisor)
    out_ptr.store[width=W](base_row, as_f64)


@always_inline
def _flba_value_to_int64_be[
    mut: Bool, //, o: Origin[mut=mut]
](
    data: UnsafePointer[UInt8, o],
    type_length: Int,
) -> Int64:
    """Decode one FLBA value as a big-endian signed integer into Int64.

    Interprets the N bytes at `data` as a two's-complement big-endian signed
    integer. For `type_length <= 8` this is lossless. For larger widths
    (DECIMAL with precision > 18, e.g. FLBA(16)) only the low 8 bytes are
    used and the result is sign-extended from the MSB bit of the first byte.
    This is sufficient for DECIMAL columns whose actual magnitudes fit in
    63 bits (precision <= 18), which covers all TPC-H DECIMAL columns
    (max precision = 15). Values that overflow Int64 are silently truncated.

    Args:
        data: Pointer to the first byte of the FLBA value (big-endian).
        type_length: Byte width of the value.

    Returns:
        The decoded signed Int64.
    """
    if type_length <= 0:
        return Int64(0)

    # Sign bit lives in the top bit of the first (most significant) byte.
    var sign_byte = Int(data[])
    var is_negative = (sign_byte & 0x80) != 0

    if type_length >= 8:
        # Take the low 8 bytes (bytes[type_length-8 .. type_length-1]) as
        # big-endian and reinterpret as Int64. For negative values with
        # precision <= 18 the upper bytes are sign-extension (0xFF...), so
        # the low 8 bytes are already the correct two's-complement encoding.
        var base = data + (type_length - 8)
        var result = UInt64(0)
        for i in range(8):
            result = (result << 8) | UInt64(Int((base + i)[]))
        return Int64(result)

    # type_length < 8: read big-endian then sign-extend.
    var result_u = UInt64(0)
    for i in range(type_length):
        result_u = (result_u << 8) | UInt64(Int((data + i)[]))

    if is_negative:
        # Set all high bits to 1 above the value's significant bits.
        var shift = UInt64(type_length * 8)
        var mask = UInt64(0xFFFFFFFFFFFFFFFF) << shift
        result_u = result_u | mask

    return Int64(result_u)


def decode_plain_flba_decimal_to_float64(
    data: Span[UInt8, _],
    num_values: Int,
    type_length: Int,
    scale: Int,
) raises -> PrimitiveArray[DType.float64]:
    """Decode PLAIN FIXED_LEN_BYTE_ARRAY DECIMAL values to Float64.

    Each value is a `type_length`-byte big-endian two's-complement signed
    integer. The logical Float64 value is that integer divided by 10^scale.

    For DECIMAL columns written by DuckDB as FLBA(16) (Int128 representation),
    this path truncates to Int64. All TPC-H DECIMAL columns have precision
    <= 15 so no precision is lost in practice; see `_flba_value_to_int64_be`.

    Args:
        data: The page: the PLAIN-encoded FLBA bytes. A page shorter than
            `num_values * type_length` bytes is refused.
        num_values: Number of values to decode.
        type_length: Byte width of each value (the N in FLBA(N)).
        scale: DECIMAL scale (number of fractional digits).

    Returns:
        A non-nullable PrimitiveArray[DType.float64].

    Raises:
        Error if `type_length` is not positive or the page cannot hold
        `num_values` values.
    """
    if num_values == 0:
        return PrimitiveArray[DType.float64].allocate(0)

    # The DECIMAL twins of the FLBA gate above. A zero width is refused too:
    # it reads no bytes, so the page bounds no count, and the output buffer
    # below is `num_values * 8` bytes, which wraps for a header-supplied
    # count (2^61 values is 0 bytes).
    if type_length <= 0:
        raise Error(
            "parquet: corrupt FLBA DECIMAL column: non-positive type_length "
            + String(type_length)
        )
    _require_plain_extent(
        "PLAIN FLBA DECIMAL", num_values, type_length, len(data)
    )
    var src = data.unsafe_ptr()

    comptime f64_size = size_of[Scalar[DType.float64]]()
    var byte_count = num_values * f64_size
    var buf = OwnedAlignedBuffer(byte_count)
    buf.set_length(Int64(byte_count))


    # Precompute divisor: 10^scale as Float64. For scale==0 this is 1.0.
    var divisor = Float64(1.0)
    for _ in range(scale):
        divisor = divisor * Float64(10.0)
    var inv_divisor = Float64(1.0) / divisor

    # PERF-CRITICAL: cross-row SIMD fast-path for
    # the two FLBA widths that cover ~100% of TPC-H DECIMAL traffic.
    #   - FLBA(16) -- DuckDB's representation for DECIMAL(P>=19, _) -- every
    #     TPC-H lineitem decimal column (l_extendedprice / l_discount / l_tax
    #     etc.) when DuckDB writes the fixture.
    #   - FLBA(8)  -- DECIMAL(P<=18, _) when the writer chose 8-byte FLBA
    #     instead of INT64.
    # Other type_lengths (4, 12, generic N) fall through to the scalar loop;
    # they need a different SIMD shape (sign extension + non-power-of-2
    # strides) and are rare on the hot path.
    #
    # The output pointer comes from an
    # arm-scope `out_view = buf.view_mut()` + bitcast pattern. The view's
    # &mut borrow on `buf` is narrowed to the SIMD loop in each FLBA-width
    # arm (must release before the scalar tail's `buf.set_typed[Float64]`
    # &mut call — NLL releases the view's borrow at last-use of `out_ptr`
    # which fires at the end of the SIMD while loop, BEFORE the scalar
    # tail's `buf.set_typed` reacquires its own &mut borrow).
    if type_length == 16:
        comptime W: Int = simd_width_of[DType.float64]()
        var simd_end = (num_values // W) * W
        var i = 0
        var out_view = buf.view_mut()
        var out_ptr = out_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
        while i < simd_end:
            _decode_flba16_simd_chunk[W](src, out_ptr, i, inv_divisor)
            i += W
        # Scalar tail (< W rows). `out_view`/`out_ptr` released by NLL here.
        while i < num_values:
            var value_ptr = src + i * 16
            var as_int = _flba_value_to_int64_be(value_ptr, 16)
            buf.set_typed[Float64](i, Float64(as_int) * inv_divisor)
            i += 1
        return PrimitiveArray[DType.float64](buf^, num_values, None, 0, 0)

    if type_length == 8:
        comptime W: Int = simd_width_of[DType.float64]()
        var simd_end = (num_values // W) * W
        var i = 0
        var out_view = buf.view_mut()
        var out_ptr = out_view._unsafe_ptr().bitcast[Scalar[DType.float64]]()
        while i < simd_end:
            _decode_flba8_simd_chunk[W](src, out_ptr, i, inv_divisor)
            i += W
        # Scalar tail (< W rows). `out_view`/`out_ptr` released by NLL here.
        while i < num_values:
            var value_ptr = src + i * 8
            var as_int = _flba_value_to_int64_be(value_ptr, 8)
            buf.set_typed[Float64](i, Float64(as_int) * inv_divisor)
            i += 1
        return PrimitiveArray[DType.float64](buf^, num_values, None, 0, 0)

    # Generic scalar fallback for type_length not in {8, 16}. Includes the
    # FLBA(4) sign-extend path (rare; needs a different SIMD shape).
    # Per-element write via `set_typed[Float64]`.
    for i in range(num_values):
        var value_ptr = src + i * type_length
        var as_int = _flba_value_to_int64_be(value_ptr, type_length)
        var as_float = Float64(as_int) * inv_divisor
        buf.set_typed[Float64](i, as_float)

    return PrimitiveArray[DType.float64](buf^, num_values, None, 0, 0)
