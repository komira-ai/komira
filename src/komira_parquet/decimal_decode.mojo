# =============================================================================
# Parquet DECIMAL -> Arrow Decimal128 decode
# =============================================================================
#
# Parquet's DECIMAL logical type can ride on four physical encodings:
#   - INT32                (precision <= 9)  — 2's-complement int, on-wire LE
#   - INT64                (precision <= 18) — 2's-complement int, on-wire LE
#   - FIXED_LEN_BYTE_ARRAY (any precision)   — 2's-complement, BIG-ENDIAN bytes
#   - BYTE_ARRAY           (any precision)   — 2's-complement, BIG-ENDIAN bytes
#
# Arrow stores Decimal128 as a 16-byte LITTLE-ENDIAN 2's-complement
# i128 (one `SIMD[DType.int128, 1]` per element — see `SharedAlignedBuffer.
# read/write_i128_le_at`). So:
#   - FLBA / BYTE_ARRAY  : reverse the N bytes (BE -> LE) AND sign-extend the
#     N-byte magnitude up to a full 16-byte i128 (replicate the sign bit).
#   - INT32 / INT64      : the wire integer is already LE; sign-extend the
#     i32/i64 2's-complement value to i128.
#
# The scale (and precision) come from the SchemaElement's DECIMAL annotation,
# NOT from the encoding. These decoders never look at scale themselves — they
# only produce the unscaled i128 — but they DO carry (precision, scale) onto
# the resulting `Decimal128Array` so the Column layer / `Schema.Field` stay
# consistent.
#
# References:
#   - Apache Parquet format spec — DECIMAL logical type, 2's-complement
#     big-endian byte arrays / native-endian INT32 / INT64.
#   - arrow-rs `parquet/src/arrow/buffer/bit_util.rs::sign_extend_be`
#     + `parquet/src/arrow/array_reader/fixed_len_byte_array.rs` — the
#     reference reader byte-reverses the FLBA and sign-extends.
# =============================================================================

from std.memory import UnsafePointer

from komira_arrow.decimal_array import Decimal128Array, DECIMAL128_BYTE_WIDTH
from komira_buffer.heap_region import HeapRegion
from .plain import _require_plain_extent


comptime _I128 = SIMD[DType.int128, 1]


# =============================================================================
# Max-precision for a backing width (used when the schema omits an explicit
# DECIMAL precision — rare, but spec-legal). These are the largest precisions
# the byte width can represent: floor(log10(2^(bits-1) - 1)).
# =============================================================================


@always_inline
def _max_precision_for_byte_width(n_bytes: Int) -> Int:
    """Largest DECIMAL precision a `n_bytes`-byte 2's-complement int can hold."""
    if n_bytes <= 1:
        return 2  # int8  : max 127
    elif n_bytes == 2:
        return 4  # int16 : max 32767
    elif n_bytes == 3:
        return 6  # int24
    elif n_bytes == 4:
        return 9  # int32 : max 2147483647
    elif n_bytes == 5:
        return 11
    elif n_bytes == 6:
        return 14
    elif n_bytes == 7:
        return 16
    elif n_bytes == 8:
        return 18  # int64 : max 9223372036854775807
    elif n_bytes <= 12:
        return 28
    else:
        return 38  # int128 : max 170141183460469231731687303715884105727


@always_inline
def _resolve_precision(declared: Int, backing_bytes: Int) -> Int:
    """Use the schema-declared DECIMAL precision when present (>=1), else fall
    back to the max precision the backing width can represent (always >=1)."""
    if declared >= 1:
        return declared
    return _max_precision_for_byte_width(backing_bytes)


# =============================================================================
# FLBA / BYTE_ARRAY: big-endian 2's-complement bytes -> i128
# =============================================================================


@always_inline
def _flba_bytes_to_i128[
    o: Origin
](data: UnsafePointer[UInt8, o], type_length: Int) -> _I128:
    """Decode `type_length` big-endian 2's-complement bytes at `data` into a
    sign-extended native i128.

    For `type_length <= 16` this builds the unsigned big-endian magnitude in a
    128-bit accumulator, then arithmetically sign-extends from bit
    `type_length*8 - 1` (`(v << shift) >> shift` with a signed `>>`). For
    `type_length > 16` (leading bytes are sign-extension) only the low 16
    bytes are used; if the true magnitude needs >16 bytes the value is out of
    Decimal128 range and is silently truncated to the low 16 bytes (mirrors the
    pre-existing FLBA-to-int64 leniency — real files never hit this).
    """
    if type_length <= 0:
        return _I128(0)
    var n = type_length if type_length <= 16 else 16
    # The first relevant byte for a wider-than-16 width is data + (type_length
    # - 16); it carries the sign bit of the low-16-byte window. For n <= 16
    # the first byte is data[0].
    var first = type_length - n
    var acc = _I128(0)
    var eight = _I128(8)
    for i in range(n):
        # SAFETY: `data` covers `type_length >= n` bytes (the caller passes a
        # buffer sized num_values*type_length); `first + i < type_length`.
        var b = Int((data + first + i)[])
        acc = (acc << eight) | _I128(Int64(b))
    if n < 16:
        # Sign-extend from bit n*8 - 1.  Arithmetic right-shift on a signed
        # SIMD int128 replicates the sign bit.
        var shift = _I128(Int64(128 - n * 8))
        acc = (acc << shift) >> shift
    return acc


# =============================================================================
# Public: PLAIN FLBA DECIMAL -> Decimal128Array
# =============================================================================


def decode_plain_flba_decimal_to_i128(
    data: Span[UInt8, _],
    num_values: Int,
    type_length: Int,
    scale: Int,
    precision: Int = 0,
) raises -> Decimal128Array[HeapRegion]:
    """Decode PLAIN FIXED_LEN_BYTE_ARRAY DECIMAL values into a Decimal128Array.

    Each value is a `type_length`-byte big-endian 2's-complement signed
    integer (the unscaled value); the logical decimal = that integer / 10^scale.
    The bytes are reversed (BE -> LE) and sign-extended to 16 bytes per Arrow's
    Decimal128 layout.

    Args:
        data: The page: the PLAIN-encoded FLBA bytes. A page shorter than
            `num_values * type_length` bytes is refused.
        num_values: Number of values to decode.
        type_length: Byte width of each FLBA value.
        scale: DECIMAL scale (carried onto the array; not applied here).
        precision: DECIMAL precision; if <1, the max for `type_length` is used.

    Returns:
        A non-nullable Decimal128Array of `num_values` elements.

    Raises:
        Error if `type_length` is not positive or the page cannot hold
        `num_values` values.
    """
    # A zero width is refused: it reads no bytes, so the page bounds no
    # count, and the array below is `num_values * 16` bytes, which wraps for
    # a header-supplied count.
    if type_length <= 0:
        raise Error(
            "parquet: corrupt FLBA DECIMAL column: non-positive type_length "
            + String(type_length)
        )
    _require_plain_extent(
        "PLAIN FLBA DECIMAL", num_values, type_length, len(data)
    )
    var src = data.unsafe_ptr()
    var p = _resolve_precision(precision, type_length)
    var arr = Decimal128Array.allocate(num_values, p, scale)
    for i in range(num_values):
        # SAFETY: extent checked directly above (data covers
        # num_values*type_length bytes); arr.data covers num_values*16
        # bytes.  No pointer escapes this function.
        var v = _flba_bytes_to_i128(src + i * type_length, type_length)
        arr.data.write_i128_le_at(i * DECIMAL128_BYTE_WIDTH, v)
    return arr^


# =============================================================================
# Public: INT32 / INT64-backed DECIMAL -> Decimal128Array
# =============================================================================


def decode_int32_buf_to_decimal128(
    data: Span[UInt8, _],
    num_values: Int,
    scale: Int,
    precision: Int = 0,
) raises -> Decimal128Array[HeapRegion]:
    """Promote a buffer of `num_values` little-endian Int32s (the unscaled
    DECIMAL values) into a Decimal128Array by sign-extending each i32 to i128.
    A buffer shorter than `num_values * 4` bytes is refused.
    """
    # The `# SAFETY:` line below rests on this check: `data` covers
    # num_values*4 bytes.
    _require_plain_extent("PLAIN DECIMAL INT32", num_values, 4, len(data))
    var src = data.unsafe_ptr()
    var p = _resolve_precision(precision, 4)
    var arr = Decimal128Array.allocate(num_values, p, scale)
    for i in range(num_values):
        # SAFETY: extent checked directly above; alignment-1 load handles
        # unaligned Parquet INT32 data.
        var v32 = (
            (src + i * 4).bitcast[Scalar[DType.int32]]().load[alignment=1]()
        )
        var v128 = SIMD[DType.int128, 1](Int64(v32))
        arr.data.write_i128_le_at(i * DECIMAL128_BYTE_WIDTH, v128)
    return arr^


def decode_int64_buf_to_decimal128(
    data: Span[UInt8, _],
    num_values: Int,
    scale: Int,
    precision: Int = 0,
) raises -> Decimal128Array[HeapRegion]:
    """Promote a buffer of `num_values` little-endian Int64s (the unscaled
    DECIMAL values) into a Decimal128Array by sign-extending each i64 to i128.
    A buffer shorter than `num_values * 8` bytes is refused.
    """
    _require_plain_extent("PLAIN DECIMAL INT64", num_values, 8, len(data))
    var src = data.unsafe_ptr()
    var p = _resolve_precision(precision, 8)
    var arr = Decimal128Array.allocate(num_values, p, scale)
    for i in range(num_values):
        # SAFETY: extent checked directly above; alignment-1 load handles
        # unaligned Parquet INT64 data.
        var v64 = (
            (src + i * 8).bitcast[Scalar[DType.int64]]().load[alignment=1]()
        )
        var v128 = SIMD[DType.int128, 1](Int64(v64))
        arr.data.write_i128_le_at(i * DECIMAL128_BYTE_WIDTH, v128)
    return arr^


# =============================================================================
# Promote already-decoded dense int arrays (dict-resolved path) to i128.
# =============================================================================


def sign_extend_int_to_i128(v: Int64) -> _I128:
    """Sign-extend a 64-bit (or narrower) 2's-complement integer to i128."""
    return SIMD[DType.int128, 1](v)
