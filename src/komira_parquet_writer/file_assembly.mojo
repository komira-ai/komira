# =============================================================================
# File assembly: the bytes around a file's column chunks
# =============================================================================
#
# The pieces every file writer in this package shares:
#
#   [PAR1] [column chunks ...] [Thrift FileMetaData] [footer length: u32 LE] [PAR1]
#
# `column_chunk_for_page` turns one `ColumnPage` placed at a file offset into
# the footer's ColumnChunk; `finish_file` appends the footer, its length and
# the closing magic. The writers build a file in memory and return its bytes:
# this package opens no file, so where the bytes go (a local file, an object
# store, a staging directory a caller owns) is the caller's decision.
# =============================================================================

from komira_parquet_api.metadata import (
    ColumnChunk,
    ColumnMetaData,
    FileMetaData,
    KeyValue,
    RowGroup,
    SchemaElement,
)

from .column_page import ColumnPage, _append_bytes
from .thrift_writer import serialize_file_metadata

comptime PARQUET_CREATED_BY: String = "komira-parquet-writer"
"""The `created_by` every file written here carries."""

comptime _FOOTER_LEN_MAX: Int = 0x7FFFFFFF


def append_magic(mut file_bytes: List[UInt8]):
    """Append the 4-byte `PAR1` magic."""
    file_bytes.append(UInt8(0x50))
    file_bytes.append(UInt8(0x41))
    file_bytes.append(UInt8(0x52))
    file_bytes.append(UInt8(0x31))


def column_chunk_for_page(page: ColumnPage, page_offset: Int) -> ColumnChunk:
    """The footer entry of `page`'s column chunk, written at `page_offset`.

    `total_compressed_size` is the chunk's bytes on disk (headers and
    bodies); `total_uncompressed_size` is its headers plus the bodies before
    compression, so the two differ exactly by what the codec saved. When the
    chunk starts with a dictionary page, `dictionary_page_offset` is the
    chunk start and `data_page_offset` is the data page after it.

    PERF-CRITICAL: the two sizes must stay distinct; a reader sizes its I/O
    from `total_compressed_size` and its decompression buffer from
    `total_uncompressed_size`.
    """
    var path_in_schema = List[String]()
    path_in_schema.append(page.column_name)
    var dict_page_off = Optional[Int](None)
    var data_page_off = page_offset
    if page.dict_page_size > 0:
        dict_page_off = page_offset
        data_page_off = page_offset + page.dict_page_size
    var hdr_size = len(page.data) - page.compressed_size
    var meta = ColumnMetaData(
        type=page.parquet_type,
        encodings=page.encodings.copy(),
        path_in_schema=path_in_schema^,
        codec=page.codec,
        num_values=page.num_values,
        total_uncompressed_size=hdr_size + page.uncompressed_size,
        total_compressed_size=len(page.data),
        data_page_offset=data_page_off,
        dictionary_page_offset=dict_page_off,
        statistics=page.statistics.copy(),
    )
    return ColumnChunk(file_offset=page_offset, meta_data=meta^)


def finish_file(
    mut file_bytes: List[UInt8],
    schema: List[SchemaElement],
    num_rows: Int,
    var row_groups: List[RowGroup],
) raises:
    """Append the footer, its length and the closing magic to `file_bytes`
    (which holds the opening magic and every column chunk).

    Raises:
        Error: the footer does not fit the format's 31-bit length (the
            Parquet footer length is read as a signed 32-bit integer), or
            its statistics are malformed.
    """
    var kv = List[KeyValue]()
    kv.append(KeyValue(String("writer"), String(PARQUET_CREATED_BY)))
    var metadata = FileMetaData(
        version=2,
        schema=schema.copy(),
        num_rows=num_rows,
        row_groups=row_groups^,
        key_value_metadata=kv^,
        created_by=String(PARQUET_CREATED_BY),
    )
    var footer = serialize_file_metadata(metadata)
    var n = len(footer)
    if n > _FOOTER_LEN_MAX:
        raise Error(
            "parquet: footer is " + String(n) + " bytes, over the format's"
            " 2147483647-byte limit"
        )
    _append_bytes(file_bytes, footer)
    file_bytes.append(UInt8(n & 0xFF))
    file_bytes.append(UInt8((n >> 8) & 0xFF))
    file_bytes.append(UInt8((n >> 16) & 0xFF))
    file_bytes.append(UInt8((n >> 24) & 0xFF))
    append_magic(file_bytes)
