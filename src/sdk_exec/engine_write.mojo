# =============================================================================
# engine_write -- write a query's result as a local Parquet, CSV or JSON file
# =============================================================================
#
# `COPY <table or (query)> TO '<path>' (FORMAT ..., ...)` runs its query like
# any other, then `write_copy_result` encodes the result batch (Parquet with
# `parquet_writer`, CSV and newline-delimited JSON with `engine_write_text`,
# compressed whole for gzip or zstd) and writes it with
# `fs.atomic_write.write_file_atomic`: a
# temporary file in the destination's directory, synced and renamed over the
# destination. A failure leaves no temporary file and the destination as it
# was, so `COPY (SELECT * FROM 'a.parquet') TO 'a.parquet'` replaces the file
# it reads only once the new file is whole. The statement answers what DuckDB
# answers, one row with one BIGINT column `Count`: the rows written
# (`count_result`).
#
# Refused by name before any file is touched:
#   STORAGE_URL_REFUSED          a destination URL (`s3://...`): local paths
#                                only (step `bind`)
#   COPY_COMPRESSION_UNSUPPORTED CSV or JSON with COMPRESSION lz4, which
#                                DuckDB does not write either (step `bind`)
#   COPY_TYPE_UNSUPPORTED        a column the writer has no annotated Parquet
#                                type for (times, durations, intervals,
#                                DATE64, binary, nested), or, for CSV and
#                                JSON, a time, duration, interval, DATE64,
#                                binary or nested column, or, for CSV with a
#                                TIMESTAMPFORMAT, a TIMESTAMP_MS or a zoned
#                                TIMESTAMP_S or _NS (step `execute`)
#   CSV_DIALECT_INVALID,         a DATEFORMAT or TIMESTAMPFORMAT a column
#   CSV_DIALECT_UNSUPPORTED      uses that DuckDB refuses, or `%n`
#                                (`csv.csv_temporal_format`, step `execute`)
#   COPY_DUPLICATE_COLUMN        CSV or JSON of a result with two columns of
#                                one name, which DuckDB would have renamed
#                                (step `execute`)
#
# A CSV or JSON file holds the bytes DuckDB's COPY writes for the same
# result (`engine_write_text` says which), a CSV file in the delimiter,
# quoting, NULL text, header and date formats the COPY's CSV options give
# (`csv.csv_write_dialect`); COMPRESSION gzip (level 6) or zstd
# (level 3), or a `.gz` or `.zst` destination with no COMPRESSION, compresses
# the whole file.
#
# What a Parquet file is: one row group per 122,880 rows (`DEFAULT_MAX_ROWS_PER_RG`);
# column names and order are the result's; a nullable column is OPTIONAL and a
# NOT NULL one REQUIRED; DECIMAL is FIXED_LEN_BYTE_ARRAY(16) with its precision
# and scale; DATE is INT32 annotated DATE; strings are UTF8; TINYINT, SMALLINT
# and the unsigned integers carry DuckDB's INT_8 .. UINT_64 annotations; a
# timestamp is INT64 with the LogicalType TIMESTAMP of its unit (TIMESTAMP_S
# as microseconds, as DuckDB writes it) and isAdjustedToUTC only when its field
# carries a time zone; komira's own timestamps carry none (a TIMESTAMPTZ
# literal binds to zone-less UTC microseconds), so they are written zone-less
# (`parquet_writer.record_batch_schema` lists each annotation). An empty result
# is a file with the schema and no rows. COMPRESSION is snappy (the default),
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
    WFMT_CSV,
    WFMT_PARQUET,
    write_format_name,
)
from column_kernels.compiler_helpers import materialize_selection_if_present
from csv.csv_write_dialect import CsvWriteDialect
from fs.atomic_write import write_file_atomic
from parquet_api.types import CompressionCodec
from parquet_writer.record_batch_writer import write_record_batch_to_parquet_bytes

from .engine_write_text import (
    compress_text,
    encode_csv,
    encode_ndjson,
    formatted_timestamp,
    text_writable,
)

comptime COPY_COMPRESSION_UNSUPPORTED = "COPY_COMPRESSION_UNSUPPORTED"
"""Refusal (step `bind`): a COPY to CSV or JSON with COMPRESSION lz4."""

comptime COPY_DUPLICATE_COLUMN = "COPY_DUPLICATE_COLUMN"
"""Refusal (step `execute`, before any file is touched): a COPY to CSV or
JSON of a result two of whose columns have one name."""

comptime STORAGE_URL_REFUSED = "STORAGE_URL_REFUSED"
"""Refusal (step `bind`): a COPY destination that is a URL; only a local path
is written."""

comptime COPY_TYPE_UNSUPPORTED = "COPY_TYPE_UNSUPPORTED"
"""Refusal (step `execute`, before any file is touched): a result column whose
type the file's writer cannot write (for Parquet, with its annotation)."""

comptime COPY_COUNT_COLUMN = "Count"
"""The name of the one column a COPY answers, as DuckDB names it."""


def check_copy_target(dest: String, fmt: UInt8, codec: UInt8) raises:
    """Refuse a COPY this engine does not write: a destination URL
    (`STORAGE_URL_REFUSED`), or CSV or JSON with the WCOMP_* `codec` lz4
    (`COPY_COMPRESSION_UNSUPPORTED`)."""
    if dest.find("://") >= 0:
        raise Error(
            String(STORAGE_URL_REFUSED) + ": COPY ... TO '" + dest
            + "': only a local file path is written"
        )
    if fmt != WFMT_PARQUET and codec == WCOMP_LZ4:
        raise Error(
            String(COPY_COMPRESSION_UNSUPPORTED) + ": COPY ... TO '" + dest
            + "' (FORMAT " + String(write_format_name(fmt))
            + ", COMPRESSION lz4): CSV and JSON are written uncompressed, with"
            " gzip or with zstd"
        )


def _writable(at: ArrowType) -> Bool:
    """True for a type the writer gives its full Parquet annotation."""
    return (
        at == ArrowType.BOOL
        or at == ArrowType.INT8
        or at == ArrowType.INT16
        or at == ArrowType.INT32
        or at == ArrowType.INT64
        or at == ArrowType.UINT8
        or at == ArrowType.UINT16
        or at == ArrowType.UINT32
        or at == ArrowType.UINT64
        or at.is_timestamp()
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


def _unformatted_reason(at: ArrowType, zoned: Bool) -> String:
    """Why TIMESTAMPFORMAT cannot be applied to a column of type `at`, which
    is not a microsecond timestamp."""
    if zoned:
        return (
            " with a time zone, which DuckDB holds only at microseconds; cast"
            " it to TIMESTAMPTZ"
        )
    return (
        ", which DuckDB formats when it read it from Parquet (as a TIMESTAMP)"
        " and writes in its own text when it is a TIMESTAMP_MS; cast it to"
        " TIMESTAMP"
    )


def write_text_result(
    var batch: RecordBatch,
    dest: String,
    fmt: UInt8,
    codec: UInt8,
    dialect: CsvWriteDialect = CsvWriteDialect(),
) raises -> Int:
    """Write `batch` to the local file `dest` as CSV in `dialect` (`fmt`
    WFMT_CSV) or newline-delimited JSON (any other `fmt`), compressed by the
    WCOMP_* `codec` (`compress_text`), all or nothing, and return the rows
    written.

    Raises:
        `COPY_TYPE_UNSUPPORTED` naming the first column of a type that is not
        written (for CSV with a TIMESTAMPFORMAT, also a TIMESTAMP_MS, whose
        DuckDB type depends on where it was read from, and a zoned
        TIMESTAMP_S or _NS, which DuckDB has no type for), or
        `COPY_DUPLICATE_COLUMN`
        naming a name two columns have, or `csv_temporal_format`'s refusal of
        a DATEFORMAT or TIMESTAMPFORMAT a column uses, before any file is
        touched; `STORAGE_NOT_FOUND` or `STORAGE_IO` from `write_file_atomic`,
        with `dest` unchanged.
    """
    var name = String("CSV") if fmt == WFMT_CSV else String("JSON")
    for c in range(batch.num_columns()):
        var at = batch.schema.field_arrow_type(c)
        if not text_writable(at):
            raise Error(
                String(COPY_TYPE_UNSUPPORTED) + ": COPY ... TO '" + dest
                + "': column '" + batch.schema.field_name(c) + "' has type "
                + String(at) + ", which is not written to " + name + " yet"
            )
        if (
            fmt == WFMT_CSV
            and dialect.timestamp_format
            and at.is_timestamp()
            and not formatted_timestamp(at)
            and (at == ArrowType.TIMESTAMP_MS or batch.schema.field_tz(c) != "")
        ):
            raise Error(
                String(COPY_TYPE_UNSUPPORTED) + ": COPY ... TO '" + dest
                + "' (TIMESTAMPFORMAT): column '" + batch.schema.field_name(c)
                + "' has type " + String(at)
                + _unformatted_reason(at, batch.schema.field_tz(c) != "")
            )
        for p in range(c):
            if batch.schema.field_name(p) == batch.schema.field_name(c):
                raise Error(
                    String(COPY_DUPLICATE_COLUMN) + ": COPY ... TO '" + dest
                    + "': the result has two columns named '"
                    + batch.schema.field_name(c) + "'; give each column of a "
                    + name + " file its own name (AS)"
                )
    var rows = materialize_selection_if_present(batch^)
    var bytes: List[UInt8]
    if fmt == WFMT_CSV:
        bytes = encode_csv(rows, dialect)
    else:
        bytes = encode_ndjson(rows)
    var file = compress_text(bytes^, codec)
    write_file_atomic(dest, Span(file))
    return rows.num_rows()


def write_copy_result(
    var batch: RecordBatch,
    dest: String,
    fmt: UInt8,
    codec: UInt8,
    dialect: CsvWriteDialect = CsvWriteDialect(),
) raises -> Int:
    """Write `batch` to the local file `dest` in the WFMT_* format `fmt`
    with the WCOMP_* compression `codec` (`write_parquet_result` or
    `write_text_result`, a CSV file in `dialect`), all or nothing, and return
    the rows written."""
    if fmt == WFMT_PARQUET:
        return write_parquet_result(batch^, dest, codec)
    return write_text_result(batch^, dest, fmt, codec, dialect)


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
