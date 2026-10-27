# =============================================================================
# subrg_cursor_feed — open a resumable column cursor over one column chunk
# =============================================================================
#
# Reads one column chunk's bytes (from its dictionary page when that comes
# first) into an owned list and opens a `ResumableColumnCursor` over it, so
# the cursor outlives the reader's (possibly mapped) view. Every sub-row-group
# route opens its cursors here.
# =============================================================================

from std.memory import unsafe_memcpy

from komira_counters.parquet_read_counter import parquet_note_column_chunk_decoded
from komira_fs.file_system import FileSystem
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.subrg_column_cursor import ResumableColumnCursor
from komira_parquet_api.metadata import RowGroup, SchemaElement
from komira_parquet_api.types import (
    CONVERTED_TYPE_DATE,
    CONVERTED_TYPE_DECIMAL,
    CONVERTED_TYPE_INT_16,
    CONVERTED_TYPE_INT_8,
    CONVERTED_TYPE_UINT_16,
    CONVERTED_TYPE_UINT_32,
    CONVERTED_TYPE_UINT_64,
    CONVERTED_TYPE_UINT_8,
    FieldRepetitionType,
    ParquetType,
)

from .flat_schema import schema_is_flat


def _chunk_is_nullable(schema_elem: SchemaElement) -> Bool:
    """True unless the schema element is REQUIRED."""
    if schema_elem.repetition_type:
        if schema_elem.repetition_type.value() == FieldRepetitionType.REQUIRED:
            return False
    return True


def _annotation_relabels_the_type(schema_elem: SchemaElement) -> Bool:
    """True when the whole-row-group decode gives the column a type other than
    its physical one (an unsigned or narrow integer, a DATE, a DECIMAL): the
    cursor's values are the physical ones, and an unsigned dictionary entry
    would be sign-extended."""
    if not schema_elem.converted_type:
        return False
    var ct = schema_elem.converted_type.value()
    return (
        ct == CONVERTED_TYPE_UINT_8
        or ct == CONVERTED_TYPE_UINT_16
        or ct == CONVERTED_TYPE_UINT_32
        or ct == CONVERTED_TYPE_UINT_64
        or ct == CONVERTED_TYPE_INT_8
        or ct == CONVERTED_TYPE_INT_16
        or ct == CONVERTED_TYPE_DATE
        or ct == CONVERTED_TYPE_DECIMAL
    )


def read_column_chunk_bytes[FS: FileSystem](reader: ParquetFileReader[FS], rg: RowGroup, col_idx: Int) raises -> List[UInt8]:
    """Column `col_idx`'s compressed chunk (dictionary and data pages) as an
    owned list. Counts one chunk decode."""
    ref col_meta = rg.columns[col_idx].meta_data
    var start_offset = col_meta.data_page_offset
    if col_meta.dictionary_page_offset:
        var dpo = col_meta.dictionary_page_offset.value()
        if dpo < start_offset:
            start_offset = dpo
    var total_size = col_meta.total_compressed_size
    parquet_note_column_chunk_decoded(total_size)
    var raw = reader.read_bytes(start_offset, total_size)
    var view = raw.view_range_ro(0, total_size)
    var out = List[UInt8](capacity=total_size)
    if total_size > 0:
        # No zero fill: the copy below writes every byte of [0, total_size),
        # the list's whole length, before anything reads it.
        out.resize(unsafe_uninit_length=total_size)
        # SAFETY: `view` covers `total_size` bytes (the `read_bytes`
        # contract) and `out` holds exactly `total_size`; both pointers are
        # used only by this synchronous copy, while `raw` and `out` live.
        unsafe_memcpy(dest=out.unsafe_ptr(), src=view._unsafe_ptr(), count=total_size)
    _ = raw
    return out^


def open_subrg_cursor[FS: FileSystem](
    reader: ParquetFileReader[FS],
    rg: RowGroup,
    schema: List[SchemaElement],
    col_idx: Int,
) raises -> ResumableColumnCursor:
    """A cursor over column `col_idx` of `rg`, or a refused one
    (`supported() == False`) for a physical type the cursor does not take
    (it takes INT32, INT64, FLOAT, DOUBLE and dictionary BYTE_ARRAY;
    `try_open` refuses the encodings it does not). A refused cursor is also
    returned, before the chunk is read, for a footer that is not flat (leaf
    `col_idx` is then not `schema[col_idx + 1]`) and for a column whose
    annotation re-labels its type (see `_annotation_relabels_the_type`); the
    caller decodes those whole. The caller checks `supported()`."""
    if col_idx < 0 or col_idx + 1 >= len(schema) or not schema_is_flat(schema):
        return ResumableColumnCursor()
    if _annotation_relabels_the_type(schema[col_idx + 1]):
        return ResumableColumnCursor()
    ref col_meta = rg.columns[col_idx].meta_data
    var ptype = col_meta.type
    if (
        ptype != ParquetType.INT32
        and ptype != ParquetType.INT64
        and ptype != ParquetType.FLOAT
        and ptype != ParquetType.DOUBLE
        and ptype != ParquetType.BYTE_ARRAY
    ):
        return ResumableColumnCursor()
    var nullable = _chunk_is_nullable(schema[col_idx + 1])
    var chunk_bytes = read_column_chunk_bytes(reader, rg, col_idx)
    return ResumableColumnCursor.try_open(chunk_bytes^, ptype, col_meta.codec, col_meta.num_values, nullable)
