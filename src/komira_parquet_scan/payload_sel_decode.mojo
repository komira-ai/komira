# =============================================================================
# payload_sel_decode — decode a row group's columns for the selected rows only
# =============================================================================
#
# When a pushed filter keeps few rows of a row group, decoding the other
# columns in full and gathering the survivors materialises every value the
# filter already threw away. `decode_columns_subset_selected_per_chunk` walks
# each requested column chunk page by page and gathers only the rows a mask
# keeps (`komira_parquet.gather.decode_column_with_selection`).
#
# It is all or nothing: if any requested column's shape is one the gather does
# not take (a nested or FIXED_LEN_BYTE_ARRAY column, a DECIMAL, DELTA or
# BYTE_STREAM_SPLIT pages, a dictionary chunk under `preserve_dict`), it
# returns None and the caller decodes in full and gathers. It reads one chunk
# at a time, so the read-ahead hint a mapped read issues covers only the
# requested columns.
# =============================================================================

from komira_arrow.boolean_array import BooleanArray
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder
from komira_counters.parquet_read_counter import parquet_note_column_chunk_decoded
from komira_fs.file_system import FileSystem
from komira_parquet.bytes_decode import _chunk_lo
from komira_parquet.data_page_count import all_pages_mask
from komira_parquet.decode_helpers import field_from_schema_element, flba_schema_info
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.gather import decode_column_with_selection
from komira_parquet.selection_vector import SelectionInterval, intervals_total_selected
from komira_parquet_api.metadata import RowGroup, SchemaElement
from komira_parquet_api.types import FieldRepetitionType

from .flat_schema import schema_is_flat


def decode_columns_subset_selected_per_chunk[FS: FileSystem](
    reader: ParquetFileReader[FS],
    rg: RowGroup,
    schema: List[SchemaElement],
    col_indices: List[Int],
    preserve_dict: Bool,
    mask: BooleanArray,
) raises -> Optional[RecordBatch]:
    """`col_indices` of `rg`, in that order, with only the rows `mask` keeps.

    Returns a batch of `mask.true_count()` rows when the gather took every
    requested column; None when any column declined, or when the file system
    is not mapped (a non-mapped read pays the same transfer either way), in
    which case the caller decodes in full and gathers.

    Args:
        reader: The file's reader. Its reads are positional, so several
            workers may call this at once.
        rg: The row group's footer entry.
        schema: The footer's flattened schema.
        col_indices: 0-based leaf indices.
        preserve_dict: A dictionary chunk declines (the gather does not
            produce a dictionary column).
        mask: The survivors, one bit per row of `rg`.

    Raises:
        If an index is not a leaf of `rg`, or a page of a chunk does not
        decode.
    """
    comptime if not FS.IS_MMAP_BACKED:
        return None
    else:
        if not schema_is_flat(schema):
            return None
        var intervals = SelectionInterval.from_bool_mask(mask)
        var num_selected = Int(intervals_total_selected(Span(intervals)))
        var sb = SchemaBuilder()
        for i in range(len(col_indices)):
            var c = col_indices[i]
            if c < 0 or c >= len(rg.columns) or c + 1 >= len(schema):
                raise Error(
                    "parquet scan: column " + String(c) + " is not a leaf of a row group of "
                    + String(len(rg.columns)) + " columns"
                )
            sb.add_field(field_from_schema_element(schema[c + 1]))
        var out_schema = sb.build()
        var builder = RecordBatchBuilder.with_capacity(len(col_indices))
        for i in range(len(col_indices)):
            var c = col_indices[i]
            ref chunk = rg.columns[c]
            ref meta = chunk.meta_data
            var raw = reader.read_bytes(_chunk_lo(chunk), meta.total_compressed_size)
            parquet_note_column_chunk_decoded(meta.total_compressed_size)
            var data = raw.view_range_mut(0, raw.len()).into_span()
            ref elem = schema[c + 1]
            var max_def_level = 0
            if elem.repetition_type:
                if elem.repetition_type.value() != FieldRepetitionType.REQUIRED:
                    max_def_level = 1
            var info = flba_schema_info(elem)
            var ts_unit = -1
            if elem.logical_timestamp_unit:
                ts_unit = elem.logical_timestamp_unit.value()
            var page_mask = all_pages_mask(data)
            var col_opt = decode_column_with_selection(
                data,
                meta.type,
                meta.codec,
                meta.num_values,
                max_def_level,
                info[0],
                info[1],
                info[2],
                preserve_dict,
                Span(page_mask),
                Span(intervals),
                num_selected,
                ts_unit,
            )
            if not col_opt:
                return None
            builder.add_column(col_opt.take())
        return Optional[RecordBatch](builder.build(out_schema^))
