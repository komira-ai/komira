# =============================================================================
# DELTA_BINARY_PACKED encoder for INT32 / INT64
# =============================================================================
#
# parquet-format Encodings.md, DELTA_BINARY_PACKED (5):
#   Header:    <block size in values> <miniblocks per block> <total value
#              count> <first value>       (ULEB128, ULEB128, ULEB128, zigzag)
#   Per block: <min delta> (zigzag) <one bit-width byte per miniblock>
#              <miniblocks>, each packed LSB first at its bit width.
#
# The block parameters are 2048 values in 8 miniblocks of 256. Only
# miniblocks holding at least one real delta are emitted; a trailing
# miniblock with no value has width 0 and no bytes.
#
# Deltas are taken in the column type's own wrapping arithmetic (32-bit for
# INT32, 64-bit for INT64), and `delta - min_delta` is taken UNSIGNED: the
# spec's "the subtraction is done with wrapping arithmetic" means a block
# whose deltas span more than the signed range still packs exactly, at
# width up to 32 (INT32) or 64 (INT64). A reader rejects an INT32 miniblock
# wider than 32 bits.
# =============================================================================

from std.bit import count_leading_zeros
from std.memory import UnsafePointer

from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_api.metadata import Statistics
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType
from komira_simd.width_policy import komira_simd_width_delta

from .column_page import (
    ColumnPage,
    _assemble_data_page,
    _require_no_nulls_when_required,
)
from .writer_bitpack import _pack_count_bytes, _pack_fixed_width_into
from komira_buffer.byte_buffer import write_uleb128, write_uleb128_u64
from .writer_encode import _def_levels
from .writer_helpers import make_int32_statistics, make_int64_statistics


comptime DBP_BLOCK_SIZE = 2048
comptime DBP_NUM_MINIBLOCKS = 8
comptime DBP_VALUES_PER_MINIBLOCK = DBP_BLOCK_SIZE // DBP_NUM_MINIBLOCKS


@always_inline
def _simd_delta_subtract_into[
    o_src: Origin[mut=False], o_dst: Origin[mut=True]
](
    values: UnsafePointer[Int64, o_src],
    n: Int,
    deltas: UnsafePointer[Int64, o_dst],
):
    """`deltas[i] = values[i + 1] - values[i]`, wrapping, for i in [0, n-1).

    PERF-CRITICAL: the autovectorizer does not fire on the unit-stride
    shifted subtract; this hand-staged form loads two overlapping windows
    and subtracts lane-wise. Wrapping subtraction has no carry between
    lanes, so each lane equals the scalar result.

    SAFETY: `values` points to `n` readable Int64s and `deltas` to `n - 1`
    writable ones; both are module-internal (the public encoders take and
    return Lists).
    """
    var num_deltas = n - 1
    if num_deltas <= 0:
        return
    comptime W = komira_simd_width_delta[DType.uint64]()
    var up = values.bitcast[UInt64]()
    var dp = deltas.bitcast[UInt64]()
    var simd_end = (num_deltas // W) * W
    var i = 0
    while i < simd_end:
        dp.store[width=W](i, up.load[width=W](i + 1) - up.load[width=W](i))
        i += W
    while i < num_deltas:
        dp[i] = up[i + 1] - up[i]
        i += 1


@always_inline
def _zigzag64(value: Int64) -> UInt64:
    return (UInt64(value) << 1) ^ UInt64(value >> 63)


def _write_zigzag64(mut buf: List[UInt8], value: Int64):
    write_uleb128_u64(_zigzag64(value), buf)


@always_inline
def _bit_width_u64(v: UInt64) -> Int:
    """Bits needed for `v` as an unsigned value (0 for 0)."""
    return 64 - Int(count_leading_zeros(v))


def _encode_delta_blocks(mut out: List[UInt8], deltas: List[Int64]):
    """Every block after the header. `deltas` are already in the column
    type's wrapping arithmetic (sign-extended to Int64 for INT32)."""
    var num_deltas = len(deltas)
    var adjusted = List[Int64](length=DBP_VALUES_PER_MINIBLOCK, fill=Int64(0))
    var widths = List[UInt8](length=DBP_NUM_MINIBLOCKS, fill=UInt8(0))
    var di = 0
    while di < num_deltas:
        var block_count = min(DBP_BLOCK_SIZE, num_deltas - di)
        var min_delta = deltas[di]
        for k in range(1, block_count):
            if deltas[di + k] < min_delta:
                min_delta = deltas[di + k]
        var umin = UInt64(min_delta)

        var active = (block_count + DBP_VALUES_PER_MINIBLOCK - 1) // DBP_VALUES_PER_MINIBLOCK
        for mb in range(DBP_NUM_MINIBLOCKS):
            widths[mb] = UInt8(0)
        for mb in range(active):
            var start = di + mb * DBP_VALUES_PER_MINIBLOCK
            var real = min(DBP_VALUES_PER_MINIBLOCK, di + block_count - start)
            var acc = UInt64(0)
            for k in range(real):
                acc |= UInt64(deltas[start + k]) - umin
            widths[mb] = UInt8(_bit_width_u64(acc))

        _write_zigzag64(out, min_delta)
        for mb in range(DBP_NUM_MINIBLOCKS):
            out.append(widths[mb])

        for mb in range(active):
            var bw = Int(widths[mb])
            if bw == 0:
                continue
            var start = di + mb * DBP_VALUES_PER_MINIBLOCK
            var real = min(DBP_VALUES_PER_MINIBLOCK, di + block_count - start)
            for k in range(DBP_VALUES_PER_MINIBLOCK):
                if k < real:
                    adjusted[k] = Int64(UInt64(deltas[start + k]) - umin)
                else:
                    adjusted[k] = Int64(0)
            var nbytes = _pack_count_bytes(DBP_VALUES_PER_MINIBLOCK, bw)
            var cur = len(out)
            out.resize(cur + nbytes, UInt8(0))
            # SAFETY: `out` has `nbytes` writable bytes from `cur`; `adjusted`
            # holds DBP_VALUES_PER_MINIBLOCK Int64s. Both alive for the call.
            _pack_fixed_width_into(
                adjusted.unsafe_ptr(),
                DBP_VALUES_PER_MINIBLOCK,
                bw,
                out.unsafe_ptr() + cur,
            )
        di += block_count


def _encode_dbp[bits: Int](values: List[Int64]) raises -> List[UInt8]:
    """DELTA_BINARY_PACKED body of `values` (sign-extended when bits == 32)."""
    var n = len(values)
    var out = List[UInt8]()
    write_uleb128(DBP_BLOCK_SIZE, out)
    write_uleb128(DBP_NUM_MINIBLOCKS, out)
    write_uleb128(n, out)
    _write_zigzag64(out, values[0] if n > 0 else Int64(0))
    if n <= 1:
        return out^
    var deltas = List[Int64](length=n - 1, fill=Int64(0))
    # SAFETY: `values` holds `n` Int64s and `deltas` `n - 1`; both alive.
    _simd_delta_subtract_into(values.unsafe_ptr(), n, deltas.unsafe_ptr())
    comptime if bits == 32:
        # INT32 arithmetic wraps at 32 bits: narrow, then sign-extend back.
        for i in range(n - 1):
            deltas[i] = Int64(Int32(deltas[i]))
    _encode_delta_blocks(out, deltas)
    return out^


def encode_delta_binary_packed_i64(values: List[Int64]) raises -> List[UInt8]:
    """DELTA_BINARY_PACKED body of INT64 values (no page header, no levels)."""
    return _encode_dbp[64](values)


def encode_delta_binary_packed_i32(values: List[Int32]) raises -> List[UInt8]:
    """DELTA_BINARY_PACKED body of INT32 values, with 32-bit wrapping deltas
    (so no miniblock is wider than 32 bits)."""
    var wide = List[Int64](capacity=max(len(values), 1))
    for i in range(len(values)):
        wide.append(Int64(values[i]))
    return _encode_dbp[32](wide)


def _collect_values_i64[dtype: DType](
    array: PrimitiveArray[dtype], skip_nulls: Bool
) -> List[Int64]:
    """The values a page encodes, sign-extended: every row, or (with
    `skip_nulls`) the non-null rows. Offset-aware."""
    var n = array.length
    var out = List[Int64](capacity=max(n, 1))
    var p = array._typed_ptr_ro()
    if not (skip_nulls and array.null_count > 0 and Bool(array.validity)):
        for i in range(n):
            out.append(Int64(p[i]))
        return out^
    ref bm = array.validity.value()
    for i in range(n):
        if bm.test(array.offset + i):
            out.append(Int64(p[i]))
    return out^


def _minmax_i64(values: List[Int64]) -> Tuple[Int64, Int64]:
    """Signed min/max of a non-empty list.

    PERF-CRITICAL: hand-staged SIMD (the scalar compare loop does not
    vectorize). SAFETY: a read-only scan of `values`' own buffer, bounded by
    its length; the pointer stays in this function.
    """
    var n = len(values)
    var p = values.unsafe_ptr()
    var lo = p[0]
    var hi = p[0]
    comptime W = komira_simd_width_delta[DType.int64]()
    var simd_end = (n // W) * W
    var i = 0
    if simd_end >= W:
        var vmin = p.load[width=W](0)
        var vmax = vmin
        i = W
        while i < simd_end:
            var chunk = p.load[width=W](i)
            vmin = vmin.lt(chunk).select(vmin, chunk)
            vmax = vmax.gt(chunk).select(vmax, chunk)
            i += W
        lo = vmin.reduce_min()
        hi = vmax.reduce_max()
    while i < n:
        if p[i] < lo:
            lo = p[i]
        if p[i] > hi:
            hi = p[i]
        i += 1
    return (lo, hi)


def encode_dbp_column_page[dtype: DType](
    column_index: Int,
    array: PrimitiveArray[dtype],
    column_name: String,
    nullable: Bool = False,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> ColumnPage:
    """An INT32/INT64 column as one DELTA_BINARY_PACKED data page.

    Statistics are min/max over the encoded (non-null) values and the null
    count; no HLL sketch (this is the high-cardinality arm, where a 4 KiB
    register set per chunk would dominate the footer).

    Raises:
        Error: a REQUIRED column holding a null, or a page over the i32
            PageHeader ceiling.
    """
    comptime assert dtype == DType.int32 or dtype == DType.int64, (
        "encode_dbp_column_page supports INT32 and INT64"
    )
    _require_no_nulls_when_required(
        "encode_dbp_column_page", column_name, nullable, array.null_count
    )
    var values = _collect_values_i64[dtype](array, skip_nulls=nullable)
    var null_count = array.null_count if nullable else 0
    var stats = Statistics(null_count=null_count)
    if len(values) > 0:
        var mm = _minmax_i64(values)
        comptime if dtype == DType.int32:
            stats = make_int32_statistics(Int32(mm[0]), Int32(mm[1]), null_count=null_count)
        else:
            stats = make_int64_statistics(mm[0], mm[1], null_count=null_count)

    var body: List[UInt8]
    var ptype: ParquetType
    comptime if dtype == DType.int32:
        body = _encode_dbp[32](values)
        ptype = ParquetType.INT32
    else:
        body = _encode_dbp[64](values)
        ptype = ParquetType.INT64

    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _def_levels(array.validity, array.offset, array.length, array.null_count)
    return _assemble_data_page(
        column_index,
        array.length,
        def_levels,
        body,
        ptype,
        column_name,
        Encoding.DELTA_BINARY_PACKED,
        nullable,
        codec,
        Optional[Statistics](stats^),
    )
