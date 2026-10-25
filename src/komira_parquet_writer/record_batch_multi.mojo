# =============================================================================
# Concat-free column chunks across several RecordBatches
# =============================================================================
#
# A writer handed N batches that fit in one row group would, naively,
# concatenate them into one batch and encode that: a second copy of every
# column. For fixed-width numerics and strings these functions encode the N
# batches' columns one after another into one PLAIN data page instead.
#
# Eligible columns (`_column_is_fast_path_eligible`): INT32, INT64, FLOAT32,
# FLOAT64, STRING and LARGE_STRING, with the same Arrow type in every batch
# (the COLUMN's type, not the schema's: it is the column that owns the
# buffer). Anything else (DICTIONARY, BOOL, DECIMAL128, the temporal types,
# which pick a better encoding than PLAIN) takes the concat-and-encode path.
#
# Nullability here is the DATA's: a column is OPTIONAL iff some batch carries a
# validity buffer or a null. An OPTIONAL page is [definition levels over all N
# batches][the non-null values]. Statistics are the ones the single-array
# encoder gives the concatenation (`_compute_stats_across_batches`).
#
# Each batch's column is read through the typed accessors (`as_primitive`,
# `as_string`, `as_large_string`), which for a nullable or string column copy
# that one batch's column before it is encoded; the copy is freed before the
# next batch is read, so the peak stays one batch above the output, not a
# whole concatenation.
# =============================================================================

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.record_batch import RecordBatch
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_parquet_api.types import CompressionCodec, Encoding, ParquetType

from .column_page import (
    ColumnPage,
    _append_bytes,
    _assemble_data_page,
    dtype_to_parquet_type,
)
from .writer_encode import (
    _def_level_frame,
    encode_plain_byte_array_data,
    encode_plain_byte_array_data_large,
    encode_plain_values,
)
from .writer_multi_batch import _append_validity_bits
from .writer_multi_batch_stats import _compute_stats_across_batches


def _column_has_nulls(
    ref batches: Slab[RecordBatch], n_batches: Int, col: Int
) raises -> Bool:
    """True iff some batch's column `col` has a validity buffer or a null."""
    for i in range(n_batches):
        ref c = batches[i].column_at(col)
        if c.has_validity_buffer() or c.null_count() != 0:
            return True
    return False


def _column_is_fast_path_eligible(
    ref batches: Slab[RecordBatch], n_batches: Int, col: Int
) raises -> Bool:
    """True iff column `col` can be encoded across all `n_batches` without a
    concat: one of the eligible Arrow types, the same in every batch."""
    var first = batches[0].column_at(col).arrow_type
    if not (
        first == ArrowType.INT32
        or first == ArrowType.INT64
        or first == ArrowType.FLOAT32
        or first == ArrowType.FLOAT64
        or first == ArrowType.STRING
        or first == ArrowType.LARGE_STRING
    ):
        return False
    for i in range(1, n_batches):
        if batches[i].column_at(col).arrow_type != first:
            return False
    return True


def _finish_levels(var bits: List[UInt8], rows: Int) raises -> List[UInt8]:
    """The definition-level run over `rows` rows whose validity bits are
    `bits`."""
    var out = _def_level_frame(rows)
    _append_bytes(out, bits)
    return out^


def _encode_n_batches_primitive[
    dtype: DType
](
    ref batches: Slab[RecordBatch],
    n_batches: Int,
    col: Int,
    name: String,
    nullable: Bool,
    codec: CompressionCodec,
) raises -> ColumnPage:
    """One PLAIN data page over column `col` of `n_batches` batches."""
    var values = List[UInt8]()
    var bits = List[UInt8]()
    var rows = 0
    for i in range(n_batches):
        var arr = batches[i].column_at(col).as_primitive[dtype]()
        if nullable:
            _append_validity_bits(
                bits, rows, arr.validity, arr.offset, arr.length, arr.null_count
            )
        _append_bytes(values, encode_plain_values[dtype](arr, skip_nulls=nullable))
        rows += arr.length
    var levels = List[UInt8]()
    if nullable:
        levels = _finish_levels(bits^, rows)
    return _assemble_data_page(
        col,
        rows,
        levels,
        values,
        dtype_to_parquet_type[dtype](),
        name,
        Encoding.PLAIN,
        nullable,
        codec,
        _compute_stats_across_batches[dtype](batches, n_batches, col),
    )


def _encode_n_batches_string(
    ref batches: Slab[RecordBatch],
    n_batches: Int,
    col: Int,
    name: String,
    nullable: Bool,
    codec: CompressionCodec,
) raises -> ColumnPage:
    """One PLAIN BYTE_ARRAY data page over a STRING or LARGE_STRING column of
    `n_batches` batches. The offset width is the column's own: an Int32
    reader over Int64 offsets would write wrong values under a correct row
    count (the typed accessors read each layout at its own width)."""
    var wide = batches[0].column_at(col).arrow_type == ArrowType.LARGE_STRING
    var values = List[UInt8]()
    var bits = List[UInt8]()
    var rows = 0
    for i in range(n_batches):
        if wide:
            var arr = batches[i].column_at(col).as_large_string()
            if nullable:
                _append_validity_bits(
                    bits, rows, arr.validity, 0, arr.length, arr.null_count
                )
            _append_bytes(
                values,
                encode_plain_byte_array_data_large(arr, skip_nulls=nullable),
            )
            rows += arr.length
        else:
            var arr = batches[i].column_at(col).as_string()
            if nullable:
                _append_validity_bits(
                    bits, rows, arr.validity, 0, arr.length, arr.null_count
                )
            _append_bytes(
                values,
                encode_plain_byte_array_data(arr, skip_nulls=nullable),
            )
            rows += arr.length
    var levels = List[UInt8]()
    if nullable:
        levels = _finish_levels(bits^, rows)
    return _assemble_data_page(
        col,
        rows,
        levels,
        values,
        ParquetType.BYTE_ARRAY,
        name,
        Encoding.PLAIN,
        nullable,
        codec,
        None,
    )


def _encode_fast_path_column(
    ref batches: Slab[RecordBatch],
    n_batches: Int,
    col: Int,
    name: String,
    nullable: Bool,
    codec: CompressionCodec,
) raises -> ColumnPage:
    """The page of an eligible column, by its Arrow type."""
    var at = batches[0].column_at(col).arrow_type
    if at == ArrowType.INT32:
        return _encode_n_batches_primitive[DType.int32](
            batches, n_batches, col, name, nullable, codec
        )
    if at == ArrowType.INT64:
        return _encode_n_batches_primitive[DType.int64](
            batches, n_batches, col, name, nullable, codec
        )
    if at == ArrowType.FLOAT32:
        return _encode_n_batches_primitive[DType.float32](
            batches, n_batches, col, name, nullable, codec
        )
    if at == ArrowType.FLOAT64:
        return _encode_n_batches_primitive[DType.float64](
            batches, n_batches, col, name, nullable, codec
        )
    if at == ArrowType.STRING or at == ArrowType.LARGE_STRING:
        return _encode_n_batches_string(
            batches, n_batches, col, name, nullable, codec
        )
    raise Error(  # cov: unreachable the caller admits only columns `_column_is_fast_path_eligible` accepted, and every accepted type has an arm above
        "parquet writer: column "
        + String(col)
        + " of Arrow type "
        + String(at)
        + " is not eligible for the multi-batch fast path"
    )
