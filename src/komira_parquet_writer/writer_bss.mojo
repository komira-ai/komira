# =============================================================================
# BYTE_STREAM_SPLIT encoder and page for FLOAT / DOUBLE
# =============================================================================
#
# parquet-format Encodings.md, BYTE_STREAM_SPLIT (9): N values of K bytes
# are written as K streams of N bytes, stream k holding byte k of every
# value: [byte0 of v0..vN-1][byte1 of v0..vN-1]...[byteK-1 of v0..vN-1].
#
# The transpose takes 16 values per step through comptime byte shuffles
# (the inverse of the reader's zip network) and a byte-at-a-time tail.
# =============================================================================

from std.memory import UnsafePointer

from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_api.metadata import Statistics
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType

from .column_page import (
    ColumnPage,
    _assemble_data_page,
    _require_no_nulls_when_required,
)
from .writer_encode import _def_levels, encode_plain_values
from .writer_float_stats import float_column_statistics


@always_inline
def _simd_encode_f32[
    o_out: Origin[mut=True]
](
    data: UnsafePointer[UInt8, _],
    num_values: Int,
    output: UnsafePointer[UInt8, o_out],
):
    """f32 transpose: two rounds of byte unzip per 16 values.

    PERF-CRITICAL: a byte-at-a-time strided scatter here was ~1% of an
    uncompressed write; the shuffles lower to unzip/unpack instructions.

    SAFETY: `data` has `num_values * 4` readable bytes; `output` has
    `num_values * 4` writable bytes (4 streams of `num_values`).
    """
    var n = num_values
    var i = 0
    while i + 16 <= n:
        var in0 = (data + i * 4 + 0).load[width=16](0)
        var in1 = (data + i * 4 + 16).load[width=16](0)
        var in2 = (data + i * 4 + 32).load[width=16](0)
        var in3 = (data + i * 4 + 48).load[width=16](0)
        var zl01 = in0.shuffle[0, 1, 4, 5, 8, 9, 12, 13, 16, 17, 20, 21, 24, 25, 28, 29](in1)
        var zl23 = in0.shuffle[2, 3, 6, 7, 10, 11, 14, 15, 18, 19, 22, 23, 26, 27, 30, 31](in1)
        var zh01 = in2.shuffle[0, 1, 4, 5, 8, 9, 12, 13, 16, 17, 20, 21, 24, 25, 28, 29](in3)
        var zh23 = in2.shuffle[2, 3, 6, 7, 10, 11, 14, 15, 18, 19, 22, 23, 26, 27, 30, 31](in3)
        var b0 = zl01.shuffle[0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30](zh01)
        var b1 = zl01.shuffle[1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31](zh01)
        var b2 = zl23.shuffle[0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30](zh23)
        var b3 = zl23.shuffle[1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31](zh23)
        (output + 0 * n + i).store(0, b0)
        (output + 1 * n + i).store(0, b1)
        (output + 2 * n + i).store(0, b2)
        (output + 3 * n + i).store(0, b3)
        i += 16
    while i < n:
        for k in range(4):
            (output + k * n + i)[] = (data + i * 4 + k)[]
        i += 1


@always_inline
def _simd_encode_f64[
    o_out: Origin[mut=True]
](
    data: UnsafePointer[UInt8, _],
    num_values: Int,
    output: UnsafePointer[UInt8, o_out],
):
    """f64 transpose: three rounds of byte unzip per 16 values.

    PERF-CRITICAL: see `_simd_encode_f32`.

    SAFETY: `data` has `num_values * 8` readable bytes; `output` has
    `num_values * 8` writable bytes (8 streams of `num_values`).
    """
    var n = num_values
    var i = 0
    while i + 16 <= n:
        var o0 = (data + i * 8 + 0).load[width=16](0)
        var o1 = (data + i * 8 + 16).load[width=16](0)
        var o2 = (data + i * 8 + 32).load[width=16](0)
        var o3 = (data + i * 8 + 48).load[width=16](0)
        var o4 = (data + i * 8 + 64).load[width=16](0)
        var o5 = (data + i * 8 + 80).load[width=16](0)
        var o6 = (data + i * 8 + 96).load[width=16](0)
        var o7 = (data + i * 8 + 112).load[width=16](0)
        # Round 1: 4-byte groups.
        var q0123_0 = o0.shuffle[0, 1, 2, 3, 8, 9, 10, 11, 16, 17, 18, 19, 24, 25, 26, 27](o1)
        var q4567_0 = o0.shuffle[4, 5, 6, 7, 12, 13, 14, 15, 20, 21, 22, 23, 28, 29, 30, 31](o1)
        var q0123_1 = o2.shuffle[0, 1, 2, 3, 8, 9, 10, 11, 16, 17, 18, 19, 24, 25, 26, 27](o3)
        var q4567_1 = o2.shuffle[4, 5, 6, 7, 12, 13, 14, 15, 20, 21, 22, 23, 28, 29, 30, 31](o3)
        var q0123_2 = o4.shuffle[0, 1, 2, 3, 8, 9, 10, 11, 16, 17, 18, 19, 24, 25, 26, 27](o5)
        var q4567_2 = o4.shuffle[4, 5, 6, 7, 12, 13, 14, 15, 20, 21, 22, 23, 28, 29, 30, 31](o5)
        var q0123_3 = o6.shuffle[0, 1, 2, 3, 8, 9, 10, 11, 16, 17, 18, 19, 24, 25, 26, 27](o7)
        var q4567_3 = o6.shuffle[4, 5, 6, 7, 12, 13, 14, 15, 20, 21, 22, 23, 28, 29, 30, 31](o7)
        # Round 2: 2-byte groups.
        var z01_lo = q0123_0.shuffle[0, 1, 4, 5, 8, 9, 12, 13, 16, 17, 20, 21, 24, 25, 28, 29](q0123_1)
        var z23_lo = q0123_0.shuffle[2, 3, 6, 7, 10, 11, 14, 15, 18, 19, 22, 23, 26, 27, 30, 31](q0123_1)
        var z01_hi = q0123_2.shuffle[0, 1, 4, 5, 8, 9, 12, 13, 16, 17, 20, 21, 24, 25, 28, 29](q0123_3)
        var z23_hi = q0123_2.shuffle[2, 3, 6, 7, 10, 11, 14, 15, 18, 19, 22, 23, 26, 27, 30, 31](q0123_3)
        var z45_lo = q4567_0.shuffle[0, 1, 4, 5, 8, 9, 12, 13, 16, 17, 20, 21, 24, 25, 28, 29](q4567_1)
        var z67_lo = q4567_0.shuffle[2, 3, 6, 7, 10, 11, 14, 15, 18, 19, 22, 23, 26, 27, 30, 31](q4567_1)
        var z45_hi = q4567_2.shuffle[0, 1, 4, 5, 8, 9, 12, 13, 16, 17, 20, 21, 24, 25, 28, 29](q4567_3)
        var z67_hi = q4567_2.shuffle[2, 3, 6, 7, 10, 11, 14, 15, 18, 19, 22, 23, 26, 27, 30, 31](q4567_3)
        # Round 3: single bytes, the 8 streams.
        var b0 = z01_lo.shuffle[0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30](z01_hi)
        var b1 = z01_lo.shuffle[1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31](z01_hi)
        var b2 = z23_lo.shuffle[0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30](z23_hi)
        var b3 = z23_lo.shuffle[1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31](z23_hi)
        var b4 = z45_lo.shuffle[0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30](z45_hi)
        var b5 = z45_lo.shuffle[1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31](z45_hi)
        var b6 = z67_lo.shuffle[0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30](z67_hi)
        var b7 = z67_lo.shuffle[1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 21, 23, 25, 27, 29, 31](z67_hi)
        (output + 0 * n + i).store(0, b0)
        (output + 1 * n + i).store(0, b1)
        (output + 2 * n + i).store(0, b2)
        (output + 3 * n + i).store(0, b3)
        (output + 4 * n + i).store(0, b4)
        (output + 5 * n + i).store(0, b5)
        (output + 6 * n + i).store(0, b6)
        (output + 7 * n + i).store(0, b7)
        i += 16
    while i < n:
        for k in range(8):
            (output + k * n + i)[] = (data + i * 8 + k)[]
        i += 1


def encode_byte_stream_split[dtype: DType](plain: List[UInt8]) raises -> List[UInt8]:
    """Transpose PLAIN FLOAT (`dtype` float32) or DOUBLE (float64) value
    bytes into the BYTE_STREAM_SPLIT layout.

    Raises:
        Error: `len(plain)` is not a whole number of values.
    """
    comptime assert dtype == DType.float32 or dtype == DType.float64, (
        "BYTE_STREAM_SPLIT is written for FLOAT and DOUBLE"
    )
    comptime K = 4 if dtype == DType.float32 else 8
    if len(plain) % K != 0:
        raise Error(
            "encode_byte_stream_split: "
            + String(len(plain))
            + " bytes is not a whole number of "
            + String(K)
            + "-byte values"
        )
    var n = len(plain) // K
    var out = List[UInt8](length=len(plain), fill=UInt8(0))
    if n == 0:
        return out^
    # SAFETY: `plain` holds n*K readable bytes, `out` n*K writable bytes;
    # both Lists are alive for the call.
    comptime if K == 4:
        _simd_encode_f32(plain.unsafe_ptr(), n, out.unsafe_ptr())
    else:
        _simd_encode_f64(plain.unsafe_ptr(), n, out.unsafe_ptr())
    return out^


def encode_bss_column_page[dtype: DType](
    column_index: Int,
    array: PrimitiveArray[dtype],
    column_name: String,
    nullable: Bool = False,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """A FLOAT/DOUBLE column as one BYTE_STREAM_SPLIT data page, with
    statistics by parquet.thrift's floating-point rules over the encoded
    (non-null) values.

    Raises:
        Error: a REQUIRED column holding a null, or a page over the i32
            PageHeader ceiling.
    """
    comptime assert dtype == DType.float32 or dtype == DType.float64, (
        "encode_bss_column_page supports FLOAT and DOUBLE"
    )
    _require_no_nulls_when_required(
        "encode_bss_column_page", column_name, nullable, array.null_count
    )
    var null_count = array.null_count if nullable else 0
    var stats = float_column_statistics[dtype](
        array, skip_nulls=nullable, null_count=null_count
    )
    var body = encode_byte_stream_split[dtype](
        encode_plain_values[dtype](array, skip_nulls=nullable)
    )
    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _def_levels(array.validity, array.offset, array.length, array.null_count)
    var ptype = ParquetType.FLOAT if dtype == DType.float32 else ParquetType.DOUBLE
    return _assemble_data_page(
        column_index,
        array.length,
        def_levels,
        body,
        ptype,
        column_name,
        Encoding.BYTE_STREAM_SPLIT,
        nullable,
        codec,
        Optional[Statistics](stats^),
    )
