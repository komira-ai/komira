# =============================================================================
# Dictionary pages for fixed-width numeric columns (INT32 / INT64 / FLOAT /
# DOUBLE)
# =============================================================================
#
# The numeric twin of the string arm in `writer_dict`: the dictionary page
# body is the distinct values as PLAIN little-endian scalars, the data page
# is the shared RLE_DICTIONARY index stream. The dictionary is built by
# `dict_encoder_numeric.encode_numeric_dict_column` (exact-bits keys, so
# -0.0 and +0.0, and distinct NaN payloads, are distinct entries).
#
# Statistics are computed from the dictionary values, which are exactly the
# chunk's distinct non-null values: INT32/INT64 min/max with an HLL distinct
# count (an HLL sketch is duplicate-insensitive, so the distinct values give
# the same registers as every row would), FLOAT/DOUBLE by parquet.thrift's
# floating-point rules (no nan_count: a dictionary cannot count NaN rows).
# =============================================================================

from std.memory import memcpy
from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_parquet_api.metadata import Statistics
from komira_parquet_api.types import CompressionCodec

from .column_page import ColumnPage, _require_no_nulls_when_required, dtype_to_parquet_type
from .dict_encoder_numeric import encode_numeric_dict_column
from .stats import compute_statistics_int32, compute_statistics_int64
from .writer_dict import _dense_indices, _dictionary_chunk
from .writer_encode import _def_levels
from .writer_float_stats import float_minmax_from_values, make_float_statistics


def encode_dict_values_plain_numeric[dtype: DType](
    dict_values: List[Scalar[dtype]],
) -> List[UInt8]:
    """The DICTIONARY_PAGE body of a numeric dictionary: the values as
    PLAIN little-endian scalars, in dictionary order."""
    comptime elem_size = size_of[Scalar[dtype]]()
    var total = len(dict_values) * elem_size
    var out = List[UInt8](length=total, fill=UInt8(0))
    if total > 0:
        # SAFETY: `out` holds `total` bytes and `dict_values` `total` bytes
        # of scalars; both alive for the copy.
        memcpy(
            dest=out.unsafe_ptr(),
            src=dict_values.unsafe_ptr().bitcast[UInt8](),
            count=total,
        )
    return out^


def _dict_statistics[dtype: DType](
    dict_values: List[Scalar[dtype]], null_count: Int
) -> Optional[Statistics]:
    comptime if dtype == DType.int64 or dtype == DType.int32:
        var arr = PrimitiveArray[dtype].from_list(dict_values)
        var stats: Statistics
        comptime if dtype == DType.int64:
            stats = compute_statistics_int64(rebind[PrimitiveArray[DType.int64]](arr))
        else:
            stats = compute_statistics_int32(rebind[PrimitiveArray[DType.int32]](arr))
        stats.null_count = null_count
        return stats^
    else:
        return make_float_statistics[dtype](
            float_minmax_from_values[dtype](dict_values), null_count=null_count
        )


def encode_dict_numeric_column_page[dtype: DType](
    column_index: Int,
    array: PrimitiveArray[dtype],
    column_name: String,
    nullable: Bool = False,
    codec: CompressionCodec = CompressionCodec.UNCOMPRESSED,
) raises -> Optional[ColumnPage]:
    """A numeric column as a dictionary chunk, or None when the column is
    empty, all null, or has more than `NUMERIC_DICT_MAX_CARDINALITY`
    distinct values (the caller writes another encoding instead).

    Raises:
        Error: a REQUIRED column holding a null, or a page over the i32
            PageHeader ceiling. A failure is never turned into None.
    """
    comptime assert (
        dtype == DType.int32
        or dtype == DType.int64
        or dtype == DType.float32
        or dtype == DType.float64
    ), "encode_dict_numeric_column_page supports INT32, INT64, FLOAT, DOUBLE"
    _require_no_nulls_when_required(
        "encode_dict_numeric_column_page", column_name, nullable, array.null_count
    )
    var num_values = array.length
    if num_values == 0:
        return None
    var result = encode_numeric_dict_column[dtype](array)
    if not result.success:
        return None
    var cardinality = len(result.dict_values)
    if cardinality == 0:
        return None

    var dense = _dense_indices(
        result.indices, num_values, array.validity, array.offset, array.null_count
    )
    var def_levels = List[UInt8]()
    if nullable:
        def_levels = _def_levels(array.validity, array.offset, num_values, array.null_count)
    var stats = _dict_statistics[dtype](result.dict_values, array.null_count)
    return _dictionary_chunk(
        column_index,
        encode_dict_values_plain_numeric[dtype](result.dict_values),
        cardinality,
        dense,
        num_values,
        def_levels,
        dtype_to_parquet_type[dtype](),
        column_name,
        nullable,
        codec,
        stats^,
    )
