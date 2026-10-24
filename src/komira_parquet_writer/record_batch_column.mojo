# =============================================================================
# One RecordBatch column -> one column chunk
# =============================================================================
#
# `_encode_column_to_page` picks the encoding of a column by its Arrow type,
# the way a size-minded writer does:
#
#   INT32 / INT64 and the temporal types stored as them
#       numeric dictionary when the column has at most
#       NUMERIC_DICT_MAX_CARDINALITY distinct values, else
#       DELTA_BINARY_PACKED;
#   FLOAT32 / FLOAT64
#       numeric dictionary, else BYTE_STREAM_SPLIT (which clusters the
#       exponent and mantissa bytes into runs a codec compresses well);
#   STRING / LARGE_STRING / DICTIONARY
#       string dictionary under the cardinality threshold, else PLAIN
#       BYTE_ARRAY (a DICTIONARY column is first decoded to dense strings,
#       resolving every row through its index validity: a null row's stale
#       ordinal must not name a dictionary entry);
#   BOOL                      PLAIN, one bit per value;
#   DECIMAL128                PLAIN FIXED_LEN_BYTE_ARRAY(16).
#
# Whether the chunk carries definition levels is the schema element's
# repetition type (OPTIONAL: always, even with no null, because a reader of an
# OPTIONAL column reads levels first). The codec reaches every encoder, so
# string and numeric pages compress alike.
#
# LARGE_STRING has its own arm and reads the column through the Int64-offset
# accessor: the narrow accessor refuses the layout, and the wide encoder
# writes the same bytes as the narrow one for the same values (Parquet has one
# variable-length type).
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.record_batch import RecordBatch
from komira_parquet_api.metadata import SchemaElement
from komira_parquet_api.types import CompressionCodec, FieldRepetitionType

from .column_page import ColumnPage
from .decimal_encode import encode_decimal128_column_page
from .writer_bss import encode_bss_column_page
from .writer_delta import encode_dbp_column_page
from .writer_dict import (
    encode_dict_large_string_column_page,
    encode_dict_string_column_page,
)
from .writer_dict_numeric import encode_dict_numeric_column_page
from .writer_encode import (
    encode_boolean_column_page,
    encode_large_string_column_page,
    encode_string_column_page,
)


def _is_optional(element: SchemaElement) -> Bool:
    if element.repetition_type:
        return element.repetition_type.value() == FieldRepetitionType.OPTIONAL
    return False


def _encode_int_page[
    dtype: DType
](
    batch: RecordBatch,
    col_idx: Int,
    name: String,
    nullable: Bool,
    codec: CompressionCodec,
) raises -> ColumnPage:
    var arr = batch.column_at(col_idx).as_primitive[dtype]()
    var d = encode_dict_numeric_column_page[dtype](
        col_idx, arr, name, nullable=nullable, codec=codec
    )
    if d:
        return d.take()
    return encode_dbp_column_page[dtype](
        col_idx, arr, name, nullable=nullable, codec=codec
    )


def _encode_float_page[
    dtype: DType
](
    batch: RecordBatch,
    col_idx: Int,
    name: String,
    nullable: Bool,
    codec: CompressionCodec,
) raises -> ColumnPage:
    var arr = batch.column_at(col_idx).as_primitive[dtype]()
    var d = encode_dict_numeric_column_page[dtype](
        col_idx, arr, name, nullable=nullable, codec=codec
    )
    if d:
        return d.take()
    return encode_bss_column_page[dtype](
        col_idx, arr, name, nullable=nullable, codec=codec
    )


def _encode_column_to_page(
    batch: RecordBatch,
    col_idx: Int,
    schema_elements: List[SchemaElement],
    codec: CompressionCodec,
) raises -> ColumnPage:
    """Encode column `col_idx` of `batch` as one chunk, its repetition type
    taken from `schema_elements[col_idx + 1]`.

    Raises:
        Error: a REQUIRED column holding a null, an Arrow type with no
            encoder, or a page over the i32 PageHeader ceiling.
    """
    var at = batch.column_at(col_idx).arrow_type
    var element = schema_elements[col_idx + 1].copy()
    var name = element.name
    var nullable = _is_optional(element)

    if at == ArrowType.DECIMAL128:
        return encode_decimal128_column_page(
            col_idx,
            batch.column_at(col_idx).as_decimal128(),
            name,
            nullable,
            codec,
        )
    if (
        at == ArrowType.INT32
        or at == ArrowType.DATE32
        or at == ArrowType.TIME32_S
        or at == ArrowType.TIME32_MS
    ):
        # `as_primitive` reads the INT32-backed temporal types as INT32.
        return _encode_int_page[DType.int32](
            batch, col_idx, name, nullable, codec
        )
    if (
        at == ArrowType.INT64
        or at == ArrowType.DATE64
        or at == ArrowType.TIME64_US
        or at == ArrowType.TIME64_NS
        or at.is_timestamp()
        or at.is_duration()
    ):
        return _encode_int_page[DType.int64](
            batch, col_idx, name, nullable, codec
        )
    if at == ArrowType.FLOAT32:
        return _encode_float_page[DType.float32](
            batch, col_idx, name, nullable, codec
        )
    if at == ArrowType.FLOAT64:
        return _encode_float_page[DType.float64](
            batch, col_idx, name, nullable, codec
        )
    if at == ArrowType.LARGE_STRING:
        var wide = batch.column_as_large_string(col_idx)
        var wide_dict = encode_dict_large_string_column_page(
            col_idx, wide, name, nullable=nullable, codec=codec
        )
        if wide_dict:
            return wide_dict.take()
        return encode_large_string_column_page(
            col_idx, wide, name, nullable=nullable, codec=codec
        )
    if at == ArrowType.STRING or at == ArrowType.DICTIONARY:
        # `column_as_string` decodes a DICTIONARY column to dense strings
        # through its indices' validity; `Column.as_string` refuses the tag.
        var strings = (
            batch.column_as_string(col_idx)
            if at == ArrowType.DICTIONARY
            else batch.column_at(col_idx).as_string()
        )
        var dict_page = encode_dict_string_column_page(
            col_idx, strings, name, nullable=nullable, codec=codec
        )
        if dict_page:
            return dict_page.take()
        return encode_string_column_page(
            col_idx, strings, name, nullable=nullable, codec=codec
        )
    if at == ArrowType.BOOL:
        return encode_boolean_column_page(
            col_idx,
            batch.column_at(col_idx).as_boolean(),
            name,
            nullable=nullable,
            codec=codec,
        )
    raise Error(
        "write_record_batch_to_parquet: unsupported column type "
        + String(at)
        + " for column '"
        + name
        + "'"
    )
