# =============================================================================
# RecordBatch -> Parquet file bytes
# =============================================================================
#
# `write_record_batch_to_parquet_bytes` and
# `write_record_batches_to_parquet_bytes` turn Arrow batches into the bytes of
# a Parquet file: the schema derived from the batches (`record_batch_schema`),
# each column encoded by its Arrow type (`record_batch_column`), the file laid
# out by `ParquetFileWriter` (one row group) or `AdvancedParquetWriter`
# (several, with a page index). They open no file: the caller decides where the
# bytes go.
#
#   * One batch with at most `max_rows_per_rg` rows is one row group.
#   * A larger batch is cut into row groups of `max_rows_per_rg` rows (the
#     default is DuckDB's 122,880), each encoded on its own so dictionaries
#     are per row group and readers can scan row groups in parallel; the page
#     index is written for them.
#   * Several batches that fit in one row group, and whose every column is
#     eligible, are encoded without concatenation (`record_batch_multi`);
#     any other mix is concatenated first (`concat_record_batches_nway`) and
#     takes the single-batch path.
#
# Nullability: for one batch a column is OPTIONAL when its Arrow field is
# nullable; for several batches, when some batch has a validity buffer or a
# null in it.
# =============================================================================

from komira_arrow.concat import concat_record_batches_nway
from komira_arrow.record_batch import RecordBatch
from komira_collections.slab import Slab
from komira_column_kernels.batch_slice import _slice_batch_range
from komira_parquet_api.metadata import SchemaElement
from komira_parquet_api.types import CompressionCodec

from .record_batch_column import _encode_column_to_page
from .record_batch_multi import (
    _column_has_nulls,
    _column_is_fast_path_eligible,
    _encode_fast_path_column,
)
from .record_batch_schema import schema_elements_for
from .writer import ParquetFileWriter
from .writer_advanced import AdvancedParquetWriter, WriterConfig

comptime DEFAULT_MAX_ROWS_PER_RG: Int = 122_880
"""Rows per row group when the caller does not say (DuckDB's default)."""


def _require_positive_row_group_size(who: String, max_rows_per_rg: Int) raises:
    if max_rows_per_rg <= 0:
        raise Error(
            who
            + ": max_rows_per_rg must be positive, got "
            + String(max_rows_per_rg)
        )


def write_record_batch_to_parquet_bytes(
    batch: RecordBatch,
    codec: CompressionCodec = CompressionCodec.SNAPPY,
    max_rows_per_rg: Int = DEFAULT_MAX_ROWS_PER_RG,
) raises -> List[UInt8]:
    """The bytes of a Parquet file holding `batch`, cut into row groups of at
    most `max_rows_per_rg` rows.

    Raises:
        Error: the batch has no columns, `max_rows_per_rg` is not positive, a
            column's Arrow type has no encoder, or a REQUIRED column holds a
            null.
    """
    _require_positive_row_group_size(
        "write_record_batch_to_parquet_bytes", max_rows_per_rg
    )
    var num_cols = batch.num_columns()
    if num_cols == 0:
        raise Error("write_record_batch_to_parquet_bytes: batch has no columns")
    var nullable = List[Bool]()
    for c in range(num_cols):
        nullable.append(batch.schema.field_nullable(c))
    var elements = schema_elements_for(batch.schema, nullable)
    return _write_single_batch_bytes(batch, elements, codec, max_rows_per_rg)


def write_record_batches_to_parquet_bytes(
    var batches: Slab[RecordBatch],
    codec: CompressionCodec = CompressionCodec.SNAPPY,
    max_rows_per_rg: Int = DEFAULT_MAX_ROWS_PER_RG,
) raises -> List[UInt8]:
    """The bytes of a Parquet file holding `batches` (consumed; all must have
    the same schema), as one row group when they fit in `max_rows_per_rg` rows
    and cut into row groups of that size otherwise.

    Raises:
        Error: no batch, a batch with no columns or a different column count,
            `max_rows_per_rg` not positive, a column's Arrow type with no
            encoder, or a REQUIRED column holding a null.
    """
    var who = String("write_record_batches_to_parquet_bytes")
    _require_positive_row_group_size(who, max_rows_per_rg)
    var n_batches = len(batches)
    if n_batches == 0:
        raise Error(who + ": no batches")
    var num_cols = batches[0].num_columns()
    if num_cols == 0:
        raise Error(who + ": batch 0 has no columns")
    var total_rows = 0
    for i in range(n_batches):
        if batches[i].num_columns() != num_cols:
            raise Error(
                who
                + ": schema mismatch at batch "
                + String(i)
                + " (has "
                + String(batches[i].num_columns())
                + " columns, expected "
                + String(num_cols)
                + ")"
            )
        total_rows += batches[i].num_rows()

    var nullable = List[Bool]()
    for c in range(num_cols):
        nullable.append(_column_has_nulls(batches, n_batches, c))
    var elements = schema_elements_for(batches[0].schema, nullable)

    var fast = n_batches >= 2 and total_rows <= max_rows_per_rg
    if fast:
        for c in range(num_cols):
            if not _column_is_fast_path_eligible(batches, n_batches, c):
                fast = False
                break
    if fast:
        var writer = ParquetFileWriter.create(elements.copy(), codec)
        for c in range(num_cols):
            writer.write_column_page(
                _encode_fast_path_column(
                    batches,
                    n_batches,
                    c,
                    elements[c + 1].name,
                    nullable[c],
                    codec,
                )
            )
        return writer.close_to_bytes()

    var one = concat_record_batches_nway(batches^)
    return _write_single_batch_bytes(one, elements, codec, max_rows_per_rg)


def _write_single_batch_bytes(
    batch: RecordBatch,
    elements: List[SchemaElement],
    codec: CompressionCodec,
    max_rows_per_rg: Int,
) raises -> List[UInt8]:
    """One batch as a file: one row group through `ParquetFileWriter`, or
    row groups of `max_rows_per_rg` rows, with the page index, through
    `AdvancedParquetWriter`."""
    var num_cols = batch.num_columns()
    var total_rows = batch.num_rows()
    if total_rows <= max_rows_per_rg:
        var writer = ParquetFileWriter.create(elements.copy(), codec)
        for c in range(num_cols):
            writer.write_column_page(
                _encode_column_to_page(batch, c, elements, codec)
            )
        return writer.close_to_bytes()

    var writer = AdvancedParquetWriter.create(
        elements.copy(), WriterConfig(enable_page_index=True)
    )
    var offset = 0
    while offset < total_rows:
        var n = min(max_rows_per_rg, total_rows - offset)
        var chunk = _slice_batch_range(batch, offset, n)
        for c in range(num_cols):
            writer.add_column_page_simple(
                _encode_column_to_page(chunk, c, elements, codec)
            )
        offset += n
        if offset < total_rows:
            writer.flush_row_group()
    return writer.close_to_bytes()
