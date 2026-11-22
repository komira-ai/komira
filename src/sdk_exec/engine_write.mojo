# =============================================================================
# engine_write -- write a query's result as a local Parquet file
# =============================================================================
#
# `COPY <table or (query)> TO '<path>' (FORMAT parquet, ...)` runs its query
# like any other, then `write_parquet_result` encodes the result batch with
# `parquet_writer` and writes it with `fs.atomic_write.write_file_atomic`: a
# temporary file in the destination's directory, synced and renamed over the
# destination. A failure leaves no temporary file and the destination as it
# was, so `COPY (SELECT * FROM 'a.parquet') TO 'a.parquet'` replaces the file
# it reads only once the new file is whole. The statement answers what DuckDB
# answers, one row with one BIGINT column `Count`: the rows written
# (`count_result`).
#
# Refused by name before any file is touched:
#   COPY_FORMAT_UNSUPPORTED  FORMAT csv or json (only Parquet is written yet)
#   STORAGE_URL_REFUSED      a destination URL (`s3://...`): local paths only
#   COPY_TYPE_UNSUPPORTED    a column the writer has no annotated Parquet type
#                            for (timestamps, times, durations, DATE64, the
#                            unsigned and narrow integers, binary, nested)
#
# What the file is: one row group per 122,880 rows (`DEFAULT_MAX_ROWS_PER_RG`);
# column names and order are the result's; a nullable column is OPTIONAL and a
# NOT NULL one REQUIRED; DECIMAL is FIXED_LEN_BYTE_ARRAY(16) with its precision
# and scale; DATE is INT32 annotated DATE; strings are UTF8. An empty result is
# a file with the schema and no rows. COMPRESSION is snappy (the default),
# uncompressed, zstd (level 3), gzip (level 6) or lz4_raw, as the parser
# admits them.

from arrow.arrow_types import ArrowType
from arrow.column import Column
from arrow.primitive_array import PrimitiveArray
from arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from arrow.write_target import (
    WCOMP_GZIP,
    WCOMP_LZ4,
    WCOMP_UNCOMPRESSED,
    WCOMP_ZSTD,
    WFMT_PARQUET,
    write_format_name,
)
from column_kernels.compiler_helpers import materialize_selection_if_present
from fs.atomic_write import write_file_atomic
from parquet_api.types import CompressionCodec
from parquet_writer.record_batch_writer import write_record_batch_to_parquet_bytes

comptime COPY_FORMAT_UNSUPPORTED = "COPY_FORMAT_UNSUPPORTED"
"""Refusal (step `bind`): a COPY to CSV or JSON, which is not written yet."""

comptime STORAGE_URL_REFUSED = "STORAGE_URL_REFUSED"
"""Refusal (step `bind`): a COPY destination that is a URL; only a local path
is written."""

comptime COPY_TYPE_UNSUPPORTED = "COPY_TYPE_UNSUPPORTED"
"""Refusal (step `execute`, before any file is touched): a result column whose
type the Parquet writer cannot write with its annotation."""

comptime COPY_COUNT_COLUMN = "Count"
"""The name of the one column a COPY answers, as DuckDB names it."""


def check_copy_target(dest: String, fmt: UInt8) raises:
    """Refuse a COPY this engine does not write: a destination URL
    (`STORAGE_URL_REFUSED`) or a format other than Parquet
    (`COPY_FORMAT_UNSUPPORTED`)."""
    if dest.find("://") >= 0:
        raise Error(
            String(STORAGE_URL_REFUSED) + ": COPY ... TO '" + dest
            + "': only a local file path is written"
        )
    if fmt != WFMT_PARQUET:
        raise Error(
            String(COPY_FORMAT_UNSUPPORTED) + ": COPY ... TO '" + dest
            + "' (FORMAT " + String(write_format_name(fmt))
            + "): only FORMAT parquet is written"
        )


def _writable(at: ArrowType) -> Bool:
    """True for a type the writer gives its full Parquet annotation."""
    return (
        at == ArrowType.BOOL
        or at == ArrowType.INT32
        or at == ArrowType.INT64
        or at == ArrowType.FLOAT32
        or at == ArrowType.FLOAT64
        or at == ArrowType.STRING
        or at == ArrowType.LARGE_STRING
        or at == ArrowType.DICTIONARY
        or at == ArrowType.DATE32
        or at == ArrowType.DECIMAL128
    )


def _parquet_codec(codec: UInt8) -> CompressionCodec:
    """The Parquet page codec of a WCOMP_* code (lz4 is LZ4_RAW, the codec
    DuckDB writes for `lz4`)."""
    if codec == WCOMP_UNCOMPRESSED:
        return CompressionCodec.UNCOMPRESSED
    if codec == WCOMP_ZSTD:
        return CompressionCodec.ZSTD
    if codec == WCOMP_GZIP:
        return CompressionCodec.GZIP
    if codec == WCOMP_LZ4:
        return CompressionCodec.LZ4_RAW
    return CompressionCodec.SNAPPY


def write_parquet_result(
    var batch: RecordBatch, dest: String, codec: UInt8
) raises -> Int:
    """Write `batch` to the local file `dest` as Parquet with the WCOMP_*
    page codec `codec`, all or nothing, and return the rows written.

    Raises:
        `COPY_TYPE_UNSUPPORTED` naming the first column the writer cannot
        write, before any file is touched; `STORAGE_NOT_FOUND` or `STORAGE_IO`
        from `write_file_atomic`, with `dest` unchanged; the writer's own error
        for a result it refuses.
    """
    for c in range(batch.num_columns()):
        var at = batch.schema.field_arrow_type(c)
        if not _writable(at):
            raise Error(
                String(COPY_TYPE_UNSUPPORTED) + ": COPY ... TO '" + dest
                + "': column '" + batch.schema.field_name(c) + "' has type "
                + String(at) + ", which is not written to Parquet yet"
            )
    var rows = materialize_selection_if_present(batch^)
    var bytes = write_record_batch_to_parquet_bytes(rows, _parquet_codec(codec))
    write_file_atomic(dest, Span(bytes))
    return rows.num_rows()


def count_result(rows: Int) raises -> RecordBatch:
    """The answer of a COPY: one row, one NOT NULL BIGINT column `Count`
    holding `rows`."""
    var sb = SchemaBuilder()
    sb.add_field(Field(String(COPY_COUNT_COLUMN), ArrowType.INT64, False))
    var arr = PrimitiveArray[DType.int64].allocate(1)
    arr.set(0, Scalar[DType.int64](rows))
    var rbb = RecordBatchBuilder()
    rbb.add_column(Column.from_primitive[DType.int64](arr^))
    return rbb.build(sb.build())
