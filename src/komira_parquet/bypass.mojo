# =============================================================================
# PERF-CRITICAL: raw column chunk read for the pass-through (bypass) write
# =============================================================================
# Regression if removed: every filter-free projection pipeline that copies a
#                        column from an input Parquet file to an output file
#                        decodes it to Arrow and encodes it again.
# What it saves:         the read half of the bypass: a column chunk's bytes
#                        (its page headers and encoded, compressed pages) are
#                        read as they are, so a writer can copy them into the
#                        output file with no decode and no re-encode. The
#                        output chunk keeps the input's encoding and codec.
# DuckDB equivalent:     none at this granularity.
# Do NOT delete without: a projection-only benchmark, and a round trip that
#                        shows the output chunk's bytes equal the input's.
# =============================================================================
#
# This module is the read half: `RawColumnChunk` and `read_raw_column_chunk`.
# Turning a RawColumnChunk into a writer page, and deciding which columns are
# passed through, belong to the writer.
# =============================================================================

from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_api.metadata import FileMetaData
from komira_fs.file_system import FileSystem
from komira_parquet.file_reader import ParquetFileReader


struct RawColumnChunk(Movable, Copyable):
    """The bytes of one Parquet column chunk, as stored.

    Fields:
        raw_bytes: The chunk's bytes: an optional dictionary page and the
            data pages, each with its page header, compressed as stored.
        column_index: 0-based leaf column index.
        column_name: The leaf column's name.
        num_values: Values in the chunk (ColumnMetaData.num_values).
        uncompressed_size: ColumnMetaData.total_uncompressed_size.
        compressed_size: ColumnMetaData.total_compressed_size, which is
            `len(raw_bytes)`.
        parquet_type: Physical type.
        codec: Compression codec of the pages.
    """

    var raw_bytes: List[UInt8]
    var column_index: Int
    var column_name: String
    var num_values: Int
    var uncompressed_size: Int
    var compressed_size: Int
    var parquet_type: ParquetType
    var codec: CompressionCodec

    def __init__(
        out self,
        var raw_bytes: List[UInt8],
        column_index: Int,
        var column_name: String,
        num_values: Int,
        uncompressed_size: Int,
        compressed_size: Int,
        parquet_type: ParquetType,
        codec: CompressionCodec,
    ):
        self.raw_bytes = raw_bytes^
        self.column_index = column_index
        self.column_name = column_name^
        self.num_values = num_values
        self.uncompressed_size = uncompressed_size
        self.compressed_size = compressed_size
        self.parquet_type = parquet_type
        self.codec = codec


def _leaf_name(metadata: FileMetaData, col_index: Int) -> String:
    """The name of leaf column `col_index`: the `col_index`-th schema
    element with no children, after the root. A group element has no column
    chunk, so leaf order is not schema order once the schema has a group."""
    var leaf = 0
    for i in range(1, len(metadata.schema)):
        if metadata.schema[i].num_children == 0:
            if leaf == col_index:
                return metadata.schema[i].name
            leaf += 1
    return String("")


def read_raw_column_chunk[fs_o: FileSystem](
    reader: ParquetFileReader[fs_o],
    metadata: FileMetaData,
    rg_index: Int,
    col_index: Int,
) raises -> RawColumnChunk:
    """Read column chunk `col_index` of row group `rg_index` as stored.

    The chunk starts at its dictionary page when it has one before the
    first data page, else at its first data page, and is
    `total_compressed_size` bytes long.

    Raises:
        Error if an index is out of range, the chunk's offset or size is
        negative, or the range runs past the file.
    """
    if rg_index < 0 or rg_index >= len(metadata.row_groups):
        raise Error(
            "bypass: rg_index "
            + String(rg_index)
            + " out of range (file has "
            + String(len(metadata.row_groups))
            + " row groups)"
        )
    ref rg = metadata.row_groups[rg_index]
    if col_index < 0 or col_index >= len(rg.columns):
        raise Error(
            "bypass: col_index "
            + String(col_index)
            + " out of range (row group has "
            + String(len(rg.columns))
            + " columns)"
        )

    ref meta = rg.columns[col_index].meta_data
    var start_offset = meta.data_page_offset
    if meta.dictionary_page_offset:
        var dict_offset = meta.dictionary_page_offset.value()
        if dict_offset < start_offset:
            start_offset = dict_offset
    var total_size = meta.total_compressed_size
    if start_offset < 0 or total_size < 0:
        raise Error(
            "bypass: column chunk has offset "
            + String(start_offset)
            + " and size "
            + String(total_size)
        )

    # read_bytes refuses a range past the end of the file.
    var raw = reader.read_bytes(start_offset, total_size)
    var raw_list = List[UInt8](capacity=raw.len())
    if raw.len() > 0:
        raw_list.extend(raw.view_range_ro(0, raw.len()).into_span())

    return RawColumnChunk(
        raw_list^,
        col_index,
        _leaf_name(metadata, col_index),
        meta.num_values,
        meta.total_uncompressed_size,
        meta.total_compressed_size,
        meta.type,
        meta.codec,
    )
