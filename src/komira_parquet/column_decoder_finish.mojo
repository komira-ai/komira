# =============================================================================
# column_decoder_finish — the column of a chunk with no dictionary codes
# =============================================================================
#
# The last step of `_assemble` (column_decoder_assemble), for a chunk whose
# values went to the fixed-width or BOOLEAN accumulator, or to none:
#
#   * fixed-width values (INT32, INT64, INT96 as Int64 nanoseconds, FLOAT,
#     DOUBLE): with `decode_move`, a non-null non-DECIMAL chunk's buffer
#     becomes the column with no copy; otherwise an array, DECIMAL to
#     Decimal128, spread over the nulls;
#   * FIXED_LEN_BYTE_ARRAY: Decimal128 for DECIMAL, else binary;
#   * BOOLEAN: the packed bits, spread over the nulls;
#   * no value at all: a chunk whose definition bits are all clear is an
#     all-null column of its declared length and type (a dictionary-encoded
#     all-null chunk has a dictionary page of no entries and pages of no
#     codes, so no accumulator fires); any other is an empty column of its
#     type.
# =============================================================================

from std.memory import UnsafePointer

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import ParquetType

from .column_decoder_state import _ChunkAcc
from .column_decoder_strings import _empty_string_array, _expand_binary_with_nulls
from .decimal_decode import (
    decode_int32_buf_to_decimal128,
    decode_int64_buf_to_decimal128,
    decode_plain_flba_decimal_to_i128,
)
from .decode_helpers import _schema_element_to_arrow_type
from .null_expand import (
    _all_null_binary,
    _all_null_primitive,
    _def_bit_is_set,
    _expand_with_nulls_boolean,
    _expand_with_nulls_decimal128,
    _expand_with_nulls_float32,
    _expand_with_nulls_float64,
    _expand_with_nulls_int32,
    _expand_with_nulls_int64,
    _expand_with_nulls_string,
)
from .plain_flba import decode_plain_fixed_len_byte_array


def _finish_decimal(
    mut acc: _ChunkAcc, var dec: Decimal128Array[HeapRegion]
) raises -> Column[HeapRegion]:
    if acc.has_nulls():
        var dv = acc.def_level_buf.value().view_mut()
        return Column.from_decimal128(
            _expand_with_nulls_decimal128(
                dec, dv._unsafe_ptr(), acc.def_level_count
            )
        )
    return Column.from_decimal128(dec)


def _finish_values(
    mut acc: _ChunkAcc,
    converted_type: Int,
    scale: Int,
    precision: Int,
    decode_move: Bool,
) raises -> Column[HeapRegion]:
    """The column of a chunk with no dictionary codes; see the module
    header."""
    var ptype = acc.ptype
    var has_nulls = acc.has_nulls()
    var n = acc.plain_elem_count

    if (
        ptype == ParquetType.INT32
        or ptype == ParquetType.INT64
        or ptype == ParquetType.INT96
        or ptype == ParquetType.FLOAT
        or ptype == ParquetType.DOUBLE
    ) and acc.plain_buf:
        var buf = acc.plain_buf.take()
        buf.set_length(Int64(acc.plain_write_offset))
        if decode_move and not acc.is_decimal and not has_nulls:
            # PERF-CRITICAL: the accumulated bytes are the Arrow data buffer
            # (little-endian PLAIN fixed-width is the Arrow layout); move it
            # into the column instead of copying it.
            var dt = DType.int32
            if ptype == ParquetType.INT64 or ptype == ParquetType.INT96:
                dt = DType.int64
            elif ptype == ParquetType.FLOAT:
                dt = DType.float32
            elif ptype == ParquetType.DOUBLE:
                dt = DType.float64
            return Column[HeapRegion](
                ArrowType.from_dtype(dt), buf^, None, None, n, 0, 0
            )
        if ptype == ParquetType.INT32:
            if acc.is_decimal:
                var dec = decode_int32_buf_to_decimal128(
                    buf.view_ro().into_span(), n, scale, precision
                )
                return _finish_decimal(acc, dec^)
            var arr = PrimitiveArray[DType.int32](buf^, n, None, 0, 0)
            if has_nulls:
                var dv = acc.def_level_buf.value().view_mut()
                return Column.from_primitive[DType.int32](
                    _expand_with_nulls_int32(
                        arr, dv._unsafe_ptr(), acc.def_level_count
                    )
                )
            return Column.from_primitive[DType.int32](arr)
        if ptype == ParquetType.INT64 or ptype == ParquetType.INT96:
            if acc.is_decimal:
                var dec = decode_int64_buf_to_decimal128(
                    buf.view_ro().into_span(), n, scale, precision
                )
                return _finish_decimal(acc, dec^)
            var arr = PrimitiveArray[DType.int64](buf^, n, None, 0, 0)
            if has_nulls:
                var dv = acc.def_level_buf.value().view_mut()
                return Column.from_primitive[DType.int64](
                    _expand_with_nulls_int64(
                        arr, dv._unsafe_ptr(), acc.def_level_count
                    )
                )
            return Column.from_primitive[DType.int64](arr)
        if ptype == ParquetType.FLOAT:
            var arr = PrimitiveArray[DType.float32](buf^, n, None, 0, 0)
            if has_nulls:
                var dv = acc.def_level_buf.value().view_mut()
                return Column.from_primitive[DType.float32](
                    _expand_with_nulls_float32(
                        arr, dv._unsafe_ptr(), acc.def_level_count
                    )
                )
            return Column.from_primitive[DType.float32](arr)
        var arr = PrimitiveArray[DType.float64](buf^, n, None, 0, 0)
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            return Column.from_primitive[DType.float64](
                _expand_with_nulls_float64(
                    arr, dv._unsafe_ptr(), acc.def_level_count
                )
            )
        return Column.from_primitive[DType.float64](arr)

    if ptype == ParquetType.FIXED_LEN_BYTE_ARRAY and acc.plain_buf:
        var buf = acc.plain_buf.take()
        buf.set_length(Int64(acc.plain_write_offset))
        var bytes = buf.view_ro().into_span()
        if acc.flba_is_decimal:
            var dec = decode_plain_flba_decimal_to_i128(
                bytes, n, acc.type_length, scale, precision
            )
            return _finish_decimal(acc, dec^)
        var bin = decode_plain_fixed_len_byte_array(bytes, n, acc.type_length)
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            return Column.from_binary(
                _expand_binary_with_nulls(
                    bin, dv._unsafe_ptr(), acc.def_level_count
                )
            )
        return Column.from_binary(bin)

    if ptype == ParquetType.BOOLEAN and acc.bool_buf:
        var count = acc.bool_write_offset
        var nbytes = (count + 7) >> 3
        var dense = Bitmap.create(max(count, 1))
        if nbytes > 0:
            dense.buffer.copy_from_view_at(
                0, acc.bool_buf.value().view_range_ro(0, nbytes)
            )
        dense.buffer.set_length(nbytes)
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            return Column.from_boolean(
                _expand_with_nulls_boolean(
                    dense, count, dv._unsafe_ptr(), acc.def_level_count
                )
            )
        return Column.from_boolean(BooleanArray.from_bitmap(dense^))

    if has_nulls:
        var dv = acc.def_level_buf.value().view_mut()
        var bits = dv._unsafe_ptr()
        var live = 0
        for i in range(acc.def_level_count):
            if _def_bit_is_set(bits, i):
                live += 1
        if live == 0:
            var all_null = _all_null_column(
                ptype, converted_type, scale, precision, bits, acc.def_level_count
            )
            if all_null:
                return all_null.take()
    return _empty_column(ptype, converted_type, scale, precision)


def _all_null_column[
    o: Origin[mut=True]
](
    ptype: ParquetType,
    converted_type: Int,
    scale: Int,
    precision: Int,
    bits: UnsafePointer[UInt8, o],
    total: Int,
) raises -> Optional[Column[HeapRegion]]:
    """`total` null rows of the chunk's type, with every validity bit clear;
    None for a type with no arm here."""
    var t = _schema_element_to_arrow_type(ptype, converted_type)
    if t == ArrowType.DECIMAL128:
        var p = precision if precision >= 1 else 38
        return Column.from_decimal128(
            _expand_with_nulls_decimal128(
                Decimal128Array.allocate(0, p, scale), bits, total
            )
        )
    if t == ArrowType.INT32:
        return Column.from_primitive[DType.int32](
            _expand_with_nulls_int32(
                PrimitiveArray[DType.int32].allocate(0), bits, total
            )
        )
    if t == ArrowType.UINT32 or t == ArrowType.DATE32:
        return Column.from_primitive_with_arrow_type[DType.int32](
            _expand_with_nulls_int32(
                PrimitiveArray[DType.int32].allocate(0), bits, total
            ),
            t,
        )
    if t == ArrowType.INT8:
        return Column.from_primitive_with_arrow_type[DType.int8](
            _all_null_primitive[DType.int8](total), t
        )
    if t == ArrowType.INT16:
        return Column.from_primitive_with_arrow_type[DType.int16](
            _all_null_primitive[DType.int16](total), t
        )
    if t == ArrowType.UINT8:
        return Column.from_primitive_with_arrow_type[DType.uint8](
            _all_null_primitive[DType.uint8](total), t
        )
    if t == ArrowType.UINT16:
        return Column.from_primitive_with_arrow_type[DType.uint16](
            _all_null_primitive[DType.uint16](total), t
        )
    if t == ArrowType.INT64:
        return Column.from_primitive[DType.int64](
            _expand_with_nulls_int64(
                PrimitiveArray[DType.int64].allocate(0), bits, total
            )
        )
    if t == ArrowType.UINT64:
        return Column.from_primitive_with_arrow_type[DType.int64](
            _expand_with_nulls_int64(
                PrimitiveArray[DType.int64].allocate(0), bits, total
            ),
            t,
        )
    if t == ArrowType.FLOAT32:
        return Column.from_primitive[DType.float32](
            _expand_with_nulls_float32(
                PrimitiveArray[DType.float32].allocate(0), bits, total
            )
        )
    if t == ArrowType.FLOAT64:
        return Column.from_primitive[DType.float64](
            _expand_with_nulls_float64(
                PrimitiveArray[DType.float64].allocate(0), bits, total
            )
        )
    if t == ArrowType.STRING:
        return Column.from_string(
            _expand_with_nulls_string(_empty_string_array(), bits, total)
        )
    if t == ArrowType.BINARY:
        return Column.from_binary(_all_null_binary(total))
    if t == ArrowType.BOOL:
        return Column.from_boolean(
            _expand_with_nulls_boolean(Bitmap.create(1), 0, bits, total)
        )
    return None


def _empty_column(
    ptype: ParquetType, converted_type: Int, scale: Int, precision: Int
) raises -> Column[HeapRegion]:
    """A zero-row column of the chunk's type."""
    var t = _schema_element_to_arrow_type(ptype, converted_type)
    if t == ArrowType.DECIMAL128:
        var p = precision if precision >= 1 else 38
        return Column.from_decimal128(Decimal128Array.allocate(0, p, scale))
    if t == ArrowType.INT32:
        return Column.from_primitive[DType.int32](
            PrimitiveArray[DType.int32].allocate(0)
        )
    if t == ArrowType.UINT32 or t == ArrowType.DATE32:
        return Column.from_primitive_with_arrow_type[DType.int32](
            PrimitiveArray[DType.int32].allocate(0), t
        )
    if t == ArrowType.INT8:
        return Column.from_primitive_with_arrow_type[DType.int8](
            PrimitiveArray[DType.int8].allocate(0), t
        )
    if t == ArrowType.INT16:
        return Column.from_primitive_with_arrow_type[DType.int16](
            PrimitiveArray[DType.int16].allocate(0), t
        )
    if t == ArrowType.UINT8:
        return Column.from_primitive_with_arrow_type[DType.uint8](
            PrimitiveArray[DType.uint8].allocate(0), t
        )
    if t == ArrowType.UINT16:
        return Column.from_primitive_with_arrow_type[DType.uint16](
            PrimitiveArray[DType.uint16].allocate(0), t
        )
    if t == ArrowType.INT64:
        return Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].allocate(0)
        )
    if t == ArrowType.UINT64:
        return Column.from_primitive_with_arrow_type[DType.int64](
            PrimitiveArray[DType.int64].allocate(0), t
        )
    if t == ArrowType.FLOAT32:
        return Column.from_primitive[DType.float32](
            PrimitiveArray[DType.float32].allocate(0)
        )
    if t == ArrowType.FLOAT64:
        return Column.from_primitive[DType.float64](
            PrimitiveArray[DType.float64].allocate(0)
        )
    if t == ArrowType.STRING:
        return Column.from_string(_empty_string_array())
    if t == ArrowType.BINARY:
        return Column.from_binary(_all_null_binary(0))
    if t == ArrowType.BOOL:
        return Column.from_boolean(BooleanArray.allocate(0))
    raise Error(
        "parquet: no empty column for physical type " + String(ptype)
    )
