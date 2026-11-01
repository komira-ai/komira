# =============================================================================
# column_decoder_assemble — the column of a chunk whose values are dictionary
#                           codes, in whole or in part
# =============================================================================
#
# After the last page `decode_column_pages` (column_decoder) builds the
# column from the chunk's accumulators (column_decoder_state). `_assemble`
# takes, in this order, the first shape that holds:
#
#   1. codes in the context's reused buffer (`recycle_codes_enabled`): a
#      non-null chunk with no PLAIN pages becomes a numeric dictionary column
#      copied out of that buffer; any other chunk copies the codes into a
#      buffer of its own and goes on;
#   2. a BYTE_ARRAY chunk that is not all dictionary pages: its string runs
#      (dictionary pages already resolved to runs) joined, spread over its
#      nulls;
#   3. a numeric chunk whose dictionary pages are followed by PLAIN pages:
#      the codes resolved, the PLAIN values appended, spread over the nulls;
#   4. a chunk of dictionary codes: kept as codes for the fused count
#      (`count_fuse_enabled`, INT32 / INT64), as a dictionary column
#      (BYTE_ARRAY with `preserve_dict`; INT32 / INT64 with `preserve_dict`
#      and `numeric_dict_vec_enabled`, non-null and non-DECIMAL), or resolved
#      to values (DECIMAL to Decimal128);
#   5. anything else: column_decoder_finish.
#
# Every nullable shape spreads the present values over the chunk's
# definition bits, so a column always has one row per value the chunk
# declares, nulls included.
# =============================================================================

from std.sys import size_of

from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.primitive_array import PrimitiveArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_parquet_api.types import ParquetType

from .column_decode_context import ColumnDecodeContext
from .column_decoder_finish import _finish_values
from .column_decoder_state import _ChunkAcc
from .column_decoder_strings import (
    _concat_string_arrays,
    _concat_two_primitive,
    _dict_to_string_array,
    _expand_binary_with_nulls,
)
from .decimal_decode import (
    decode_int32_buf_to_decimal128,
    decode_int64_buf_to_decimal128,
    decode_plain_flba_decimal_to_i128,
)
from .dictionary_resolve import _validate_dict_indices
from .null_expand import (
    _expand_with_nulls_decimal128,
    _expand_with_nulls_float32,
    _expand_with_nulls_float64,
    _expand_with_nulls_int32,
    _expand_with_nulls_int64,
    _expand_with_nulls_string,
)
from .scan_copy_trace import (
    dict_resolve_move_enabled,
    incr_dict_resolve_copy,
    incr_dict_resolve_move,
    incr_string_copy,
    incr_string_share,
    string_share_enabled,
)


struct NumericDictCodes(Movable):
    """An INT32 / INT64 dictionary chunk kept as codes for the fused filter
    and count: the predicate is evaluated once per dictionary entry and the
    count summed over the codes, so the per-row values are never built.

    Fields:
        codes: The present rows' dictionary codes, in order, each checked to
            lie in `dict_values`. A null row has no code (a null never
            satisfies a comparison, so the count is exact).
        dict_values: The dictionary's entries widened to Int64, in
            dictionary order: code `c` is `dict_values[c]`.
    """

    var codes: PrimitiveArray[DType.int32]
    var dict_values: List[Int64]

    def __init__(
        out self,
        var codes: PrimitiveArray[DType.int32],
        var dict_values: List[Int64],
    ):
        self.codes = codes^
        self.dict_values = dict_values^


struct NumericDictCodesHolder(Movable):
    """Where `decode_column_pages` leaves a `NumericDictCodes` when the fused
    count asked for one and the chunk has the shape (`out` stays None
    otherwise, and the column returned is the decoded one)."""

    var out: Optional[NumericDictCodes]

    def __init__(out self):
        self.out = Optional[NumericDictCodes](None)


def _assemble(
    mut acc: _ChunkAcc,
    mut decode_ctx: ColumnDecodeContext,
    count_fuse_enabled: Bool,
    mut count_fuse_out: NumericDictCodesHolder,
    converted_type: Int,
    scale: Int,
    precision: Int,
    preserve_dict: Bool,
    decode_move: Bool,
) raises -> Column[HeapRegion]:
    """Build the chunk's column from its accumulators; see the module
    header for the order of the shapes."""
    comptime i32sz = size_of[Int32]()
    var ptype = acc.ptype

    # 1. Codes in the context's reused buffer.
    if acc.use_recycled_codes and acc.has_dict and acc.dict_idx_count > 0:
        var nbytes = acc.dict_idx_count * i32sz
        if not acc.has_nulls() and not acc.numeric_fallback:
            var view = decode_ctx.codes_ref().view_range_ro(0, nbytes)
            var entries = acc.dict_decoder.dict_entries_as_int64()
            if ptype == ParquetType.INT32:
                return Column.from_numeric_dict_codes_view[
                    DType.int32, DType.int32
                ](view, acc.dict_idx_count, entries^)
            return Column.from_numeric_dict_codes_view[
                DType.int32, DType.int64
            ](view, acc.dict_idx_count, entries^)
        var own = OwnedAlignedBuffer(max(nbytes, 1))
        own.copy_from_view(decode_ctx.codes_ref().view_range_ro(0, nbytes))
        acc.dict_idx_buf = own^

    # 2. A BYTE_ARRAY chunk of string runs.
    if acc.string_pages_mode and ptype == ParquetType.BYTE_ARRAY:
        # No codes are pending here: in string-run mode every page of codes
        # was resolved to a run when it was decoded (column_decoder_values),
        # so the runs already hold every row in page order.
        var joined = _concat_string_arrays(acc.string_pages)
        if acc.has_nulls():
            var dv = acc.def_level_buf.value().view_mut()
            var spread = _expand_with_nulls_string(
                joined, dv._unsafe_ptr(), acc.def_level_count
            )
            joined = spread^
        if string_share_enabled():
            incr_string_share()
            return Column.from_string_shared(joined^)
        incr_string_copy()
        return Column.from_string(joined^)

    if not (acc.has_dict and acc.dict_idx_buf and acc.dict_idx_count > 0):
        return _finish_values(
            acc, converted_type, scale, precision, decode_move
        )

    var idx_buf = acc.dict_idx_buf.take()
    idx_buf.set_length(Int64(acc.dict_idx_count * i32sz))
    var indices = PrimitiveArray[DType.int32](
        idx_buf^, acc.dict_idx_count, None, 0, 0
    )

    # 3. Dictionary pages, then PLAIN pages, in a numeric chunk.
    if acc.numeric_fallback:
        return _assemble_numeric_fallback(acc, indices)

    # 4. A chunk of dictionary codes.
    if (
        count_fuse_enabled
        and not acc.is_decimal
        and (ptype == ParquetType.INT32 or ptype == ParquetType.INT64)
    ):
        var entries = acc.dict_decoder.dict_entries_as_int64()
        # The consumer reads `dict_values[code]` with no check of its own.
        _validate_dict_indices(indices, len(entries), "NumericDictCodes")
        count_fuse_out.out = Optional[NumericDictCodes](
            NumericDictCodes(indices^, entries^)
        )
        # A placeholder: the caller reads `count_fuse_out`.
        return Column.from_primitive[DType.int64](
            PrimitiveArray[DType.int64].allocate(0)
        )

    var has_nulls = acc.has_nulls()
    if ptype == ParquetType.BYTE_ARRAY:
        if preserve_dict:
            if has_nulls:
                # The codes of the present rows, spread over the nulls: a
                # dictionary column's nulls live in its indices' validity.
                var dv = acc.def_level_buf.value().view_mut()
                var spread = _expand_with_nulls_int32(
                    indices, dv._unsafe_ptr(), acc.def_level_count
                )
                indices = spread^
            return Column.from_dictionary(
                acc.dict_decoder.resolve_as_string_dict(indices)
            )
        var dense = _dict_to_string_array(
            acc.dict_decoder.resolve_as_string_dict(indices)
        )
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            var spread = _expand_with_nulls_string(
                dense, dv._unsafe_ptr(), acc.def_level_count
            )
            dense = spread^
        return Column.from_string(dense^)

    if ptype == ParquetType.INT32 or ptype == ParquetType.INT64:
        if (
            decode_ctx.numeric_dict_vec_enabled
            and preserve_dict
            and not acc.is_decimal
            and not has_nulls
        ):
            var entries = acc.dict_decoder.dict_entries_as_int64()
            if ptype == ParquetType.INT32:
                return Column.from_numeric_dict[DType.int32, DType.int32](
                    indices^, entries^
                )
            return Column.from_numeric_dict[DType.int32, DType.int64](
                indices^, entries^
            )
        if ptype == ParquetType.INT32:
            var resolved = acc.dict_decoder.resolve_int32(indices)
            if acc.is_decimal:
                var dec = decode_int32_buf_to_decimal128(
                    resolved.view_ro().into_span(),
                    resolved.length,
                    scale,
                    precision,
                )
                return _decimal_column(acc, dec^)
            if has_nulls:
                var dv = acc.def_level_buf.value().view_mut()
                incr_dict_resolve_copy()
                return Column.from_primitive[DType.int32](
                    _expand_with_nulls_int32(
                        resolved, dv._unsafe_ptr(), acc.def_level_count
                    )
                )
            if dict_resolve_move_enabled():
                incr_dict_resolve_move()
                return Column.from_primitive_shared[DType.int32](resolved^)
            incr_dict_resolve_copy()
            return Column.from_primitive[DType.int32](resolved)
        var resolved = acc.dict_decoder.resolve_int64(indices)
        if acc.is_decimal:
            var dec = decode_int64_buf_to_decimal128(
                resolved.view_ro().into_span(),
                resolved.length,
                scale,
                precision,
            )
            return _decimal_column(acc, dec^)
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            incr_dict_resolve_copy()
            return Column.from_primitive[DType.int64](
                _expand_with_nulls_int64(
                    resolved, dv._unsafe_ptr(), acc.def_level_count
                )
            )
        if dict_resolve_move_enabled():
            incr_dict_resolve_move()
            return Column.from_primitive_shared[DType.int64](resolved^)
        incr_dict_resolve_copy()
        return Column.from_primitive[DType.int64](resolved)

    if ptype == ParquetType.FLOAT:
        var resolved = acc.dict_decoder.resolve_float32(indices)
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            incr_dict_resolve_copy()
            return Column.from_primitive[DType.float32](
                _expand_with_nulls_float32(
                    resolved, dv._unsafe_ptr(), acc.def_level_count
                )
            )
        if dict_resolve_move_enabled():
            incr_dict_resolve_move()
            return Column.from_primitive_shared[DType.float32](resolved^)
        incr_dict_resolve_copy()
        return Column.from_primitive[DType.float32](resolved)

    if ptype == ParquetType.DOUBLE:
        var resolved = acc.dict_decoder.resolve_float64(indices)
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            incr_dict_resolve_copy()
            return Column.from_primitive[DType.float64](
                _expand_with_nulls_float64(
                    resolved, dv._unsafe_ptr(), acc.def_level_count
                )
            )
        if dict_resolve_move_enabled():
            incr_dict_resolve_move()
            return Column.from_primitive_shared[DType.float64](resolved^)
        incr_dict_resolve_copy()
        return Column.from_primitive[DType.float64](resolved)

    if ptype == ParquetType.FIXED_LEN_BYTE_ARRAY:
        var bin = acc.dict_decoder.resolve_flba_as_binary(indices)
        if acc.flba_is_decimal:
            var dec = decode_plain_flba_decimal_to_i128(
                bin.data.view_ro().into_span(),
                bin.length,
                acc.type_length,
                scale,
                precision,
            )
            return _decimal_column(acc, dec^)
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            var spread = _expand_binary_with_nulls(
                bin, dv._unsafe_ptr(), acc.def_level_count
            )
            return Column.from_binary(spread)
        return Column.from_binary(bin)

    raise Error("parquet: no dictionary decoding for physical type " + String(ptype))


def _decimal_column(
    mut acc: _ChunkAcc, var dec: Decimal128Array[HeapRegion]
) raises -> Column[HeapRegion]:
    """A Decimal128 column of the present values, spread over the nulls."""
    if acc.has_nulls():
        var dv = acc.def_level_buf.value().view_mut()
        return Column.from_decimal128(
            _expand_with_nulls_decimal128(
                dec, dv._unsafe_ptr(), acc.def_level_count
            )
        )
    return Column.from_decimal128(dec)


def _assemble_numeric_fallback(
    mut acc: _ChunkAcc, indices: PrimitiveArray[DType.int32]
) raises -> Column[HeapRegion]:
    """A numeric chunk whose dictionary pages are followed by PLAIN (or
    DELTA / BYTE_STREAM_SPLIT) pages: the codes resolved, then the other
    pages' values, in page order, spread over the nulls."""
    var pbuf = acc.plain_buf.take()
    pbuf.set_length(Int64(acc.plain_write_offset))
    var n = acc.plain_elem_count
    var has_nulls = acc.has_nulls()
    var ptype = acc.ptype
    if ptype == ParquetType.INT32:
        var all = _concat_two_primitive[DType.int32](
            acc.dict_decoder.resolve_int32(indices),
            PrimitiveArray[DType.int32](pbuf^, n, None, 0, 0),
        )
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            return Column.from_primitive[DType.int32](
                _expand_with_nulls_int32(all, dv._unsafe_ptr(), acc.def_level_count)
            )
        return Column.from_primitive[DType.int32](all)
    if ptype == ParquetType.INT64:
        var all = _concat_two_primitive[DType.int64](
            acc.dict_decoder.resolve_int64(indices),
            PrimitiveArray[DType.int64](pbuf^, n, None, 0, 0),
        )
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            return Column.from_primitive[DType.int64](
                _expand_with_nulls_int64(all, dv._unsafe_ptr(), acc.def_level_count)
            )
        return Column.from_primitive[DType.int64](all)
    if ptype == ParquetType.FLOAT:
        var all = _concat_two_primitive[DType.float32](
            acc.dict_decoder.resolve_float32(indices),
            PrimitiveArray[DType.float32](pbuf^, n, None, 0, 0),
        )
        if has_nulls:
            var dv = acc.def_level_buf.value().view_mut()
            return Column.from_primitive[DType.float32](
                _expand_with_nulls_float32(all, dv._unsafe_ptr(), acc.def_level_count)
            )
        return Column.from_primitive[DType.float32](all)
    var all = _concat_two_primitive[DType.float64](
        acc.dict_decoder.resolve_float64(indices),
        PrimitiveArray[DType.float64](pbuf^, n, None, 0, 0),
    )
    if has_nulls:
        var dv = acc.def_level_buf.value().view_mut()
        return Column.from_primitive[DType.float64](
            _expand_with_nulls_float64(all, dv._unsafe_ptr(), acc.def_level_count)
        )
    return Column.from_primitive[DType.float64](all)
