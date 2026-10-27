# =============================================================================
# parquet_reader_prune — the page-index-pruned decodes of `ParquetReader`
# =============================================================================
#
# A row group's page indexes (ColumnIndex min/max per page, OffsetIndex rows
# per page) can show that a filter keeps no row of some pages. These decodes
# consult them before reading:
#
#   * every compared column's pages pruned -> None (no row of the row group
#     can match; the caller emits nothing for it);
#   * the caller allows a partial read, some page is pruned, and every
#     compared and decoded column carries a page index -> the surviving rows
#     (the intersection, in row-group row space, of each compared column's
#     surviving page ranges) are read through the pages that cover them, for
#     every decoded column, so the columns stay row aligned;
#   * anything else -> the whole-column read.
#
# The result is either the whole-column decode or exactly its rows inside the
# surviving pages, so evaluating the filter on it gives the rows the whole
# read would.
# =============================================================================

from komira_arrow.record_batch import RecordBatch
from komira_fs.file_system import FileSystem
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.page_index_cache import ParquetPageIndexCache
from komira_parquet.page_pruner import select_pages_for_unit
from komira_parquet.parquet_source_helpers import _decode_columns_subset_per_chunk
from komira_parquet.parquet_source_page_picks import (
    _decode_columns_with_per_col_picks,
    _intersect_pred_row_ranges_via_cache,
    _picks_per_col_from_row_ranges,
)
from komira_parquet_api.metadata import FileMetaData, RowGroup
from komira_plan_expr.expr import Expr


def _has_page_index(rg: RowGroup, col_indices: List[Int]) -> Bool:
    """Every column of `col_indices` is a column of `rg` with both a
    ColumnIndex and an OffsetIndex."""
    for i in range(len(col_indices)):
        var ci = col_indices[i]
        if ci < 0 or ci >= len(rg.columns):
            return False
        ref cc = rg.columns[ci]
        if (
            not cc.column_index_offset
            or not cc.column_index_length
            or not cc.offset_index_offset
            or not cc.offset_index_length
        ):
            return False
    return True


struct PrunedRanges(Movable):
    """The outcome of the page selection for one row group.

    Fields:
        empty: no row of the row group can match.
        partial: `ranges` holds the surviving rows (flat `(start, end)`
            pairs, row-group row space); when False, read whole columns.
        ranges: see `partial`.
    """

    var empty: Bool
    var partial: Bool
    var ranges: List[Int]

    def __init__(out self, empty: Bool, partial: Bool, var ranges: List[Int]):
        self.empty = empty
        self.partial = partial
        self.ranges = ranges^


def pruned_row_ranges[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    file: ParquetFileReader[FS],
    meta: FileMetaData,
    unit_in_file: Int,
    filter: Expr,
    decode_cols: List[Int],
    allow_partial_prune: Bool,
) raises -> PrunedRanges:
    """Decide how to read `decode_cols` of row group `unit_in_file` under
    `filter` (see the module header)."""
    var path = file.file_path
    var sel = select_pages_for_unit(cache, file, path, meta, unit_in_file, filter)
    if sel.is_pruned_empty:
        return PrunedRanges(True, False, List[Int]())
    if not allow_partial_prune or len(sel.entries) == 0:
        return PrunedRanges(False, False, List[Int]())
    var pred_cols = List[Int]()
    var pred_picks = List[List[Int]]()
    var all_pred_cols = List[Int]()
    for i in range(len(sel.entries)):
        ref e = sel.entries[i]
        all_pred_cols.append(e.col_idx)
        if e.is_all_pass:
            continue
        pred_cols.append(e.col_idx)
        pred_picks.append(e.picks.copy())
    if len(pred_cols) == 0:
        return PrunedRanges(False, False, List[Int]())
    ref rg = meta.row_groups[unit_in_file]
    if not _has_page_index(rg, all_pred_cols) or not _has_page_index(rg, decode_cols):
        return PrunedRanges(False, False, List[Int]())
    var ranges = _intersect_pred_row_ranges_via_cache(cache, file, path, meta, unit_in_file, pred_cols, pred_picks)
    if len(ranges) == 0:
        return PrunedRanges(True, False, List[Int]())
    return PrunedRanges(False, True, ranges^)


def decode_ranges[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    file: ParquetFileReader[FS],
    meta: FileMetaData,
    unit_in_file: Int,
    col_indices: List[Int],
    ranges: List[Int],
    preserve_dict: Bool,
) raises -> RecordBatch:
    """`col_indices` read through the pages that cover `ranges`."""
    var path = file.file_path
    var picks = _picks_per_col_from_row_ranges(cache, file, path, meta, unit_in_file, col_indices, ranges)
    return _decode_columns_with_per_col_picks(
        cache, file, path, meta, unit_in_file, col_indices, picks^, preserve_dict
    )


def decode_whole[FS: FileSystem](
    file: ParquetFileReader[FS],
    meta: FileMetaData,
    unit_in_file: Int,
    col_indices: List[Int],
    preserve_dict: Bool,
    numeric_dict_vec: Bool,
) raises -> RecordBatch:
    """`col_indices` of the row group, whole columns."""
    return _decode_columns_subset_per_chunk(
        file, meta.row_groups[unit_in_file], meta.schema, col_indices, preserve_dict, numeric_dict_vec
    )
