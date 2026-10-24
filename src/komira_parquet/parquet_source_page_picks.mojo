# =============================================================================
# parquet_source_page_picks — a row group read through only its chosen pages
# =============================================================================
#
# After `page_pruner` has chosen, per filter column, the pages that may hold
# a match, a Parquet source reads only those pages. Pages of different
# columns are joined by row: a page covers the rows [first_row, end) its
# OffsetIndex gives (the last page ends at the row group's row count).
#
#   * `_intersect_pred_row_ranges_via_cache`: the rows every filter column
#     keeps (the intersection of each column's chosen pages' rows);
#   * `_picks_per_col_from_row_ranges`: per column to read (filter or
#     payload), the pages that cover any of those rows;
#   * `_decode_columns_with_per_col_picks`: each column's chosen pages
#     decoded (`page_index.read_selected_pages_via_runs`); the columns must
#     cover the same rows, which holds when their page boundaries agree on
#     those rows. When they do not, it raises rather than return columns
#     whose rows do not line up, and the caller reads whole chunks;
#   * `_decode_predicate_cols_with_picks`: one pick list read from every
#     column (columns written with the same page boundaries).
#
# The batch holds the chosen pages' rows only, in row order: a superset of
# the matching rows, which the filter then evaluates.
# =============================================================================

from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import SchemaBuilder
from komira_fs.file_system import FileSystem
from komira_parquet_api.metadata import ColumnChunk, FileMetaData

from .decode_helpers import field_from_schema_element
from .file_reader import ParquetFileReader
from .page_index import OffsetIndex, coalesce_pages, read_selected_pages_via_runs
from .page_index_cache import ParquetPageIndexCache, get_or_parse_indexes_copy


def _absolute_row_ranges_for_picks(
    oi: OffsetIndex, picks: List[Int], chunk_rows: Int
) -> List[Int]:
    """The rows of the picked pages as flat [start, end) pairs, in pick
    order (an out-of-range pick is ignored)."""
    var out = List[Int]()
    for i in range(len(picks)):
        var p = picks[i]
        if p < 0 or p >= oi.num_pages:
            continue
        out.append(oi.first_row_indices[p])
        out.append(oi.page_end_row(p, chunk_rows))
    return out^


def _intersect_row_ranges(a_flat: List[Int], b_flat: List[Int]) -> List[Int]:
    """The intersection of two ascending, non-overlapping [start, end)
    range lists, as one."""
    var out = List[Int]()
    var i = 0
    var j = 0
    while i < len(a_flat) // 2 and j < len(b_flat) // 2:
        var a_s = a_flat[2 * i]
        var a_e = a_flat[2 * i + 1]
        var b_s = b_flat[2 * j]
        var b_e = b_flat[2 * j + 1]
        var lo = max(a_s, b_s)
        var hi = min(a_e, b_e)
        if lo < hi:
            out.append(lo)
            out.append(hi)
        if a_e <= b_e:
            i += 1
        else:
            j += 1
    return out^


def _picks_overlapping_row_ranges(
    oi: OffsetIndex, ranges_flat: List[Int], chunk_rows: Int
) -> List[Int]:
    """The pages (ascending) whose rows meet any of `ranges_flat`."""
    var picks = List[Int]()
    for p in range(oi.num_pages):
        var ps = oi.first_row_indices[p]
        var pe = oi.page_end_row(p, chunk_rows)
        for r in range(len(ranges_flat) // 2):
            if pe > ranges_flat[2 * r] and ps < ranges_flat[2 * r + 1]:
                picks.append(p)
                break
    return picks^


def _require_page_index(chunk: ColumnChunk, what: String, rg_idx: Int, col_idx: Int) raises:
    if (
        not chunk.column_index_offset
        or not chunk.column_index_length
        or not chunk.offset_index_offset
        or not chunk.offset_index_length
    ):
        raise Error(
            what
            + ": rg "
            + String(rg_idx)
            + " col "
            + String(col_idx)
            + " has no page index"
        )


def _offset_index_of[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    reader: ParquetFileReader[FS],
    path: String,
    meta: FileMetaData,
    rg_idx: Int,
    col_idx: Int,
    what: String,
) raises -> OffsetIndex:
    """Column `col_idx`'s OffsetIndex in row group `rg_idx`, through the
    cache."""
    if rg_idx < 0 or rg_idx >= len(meta.row_groups):
        raise Error(what + ": row group " + String(rg_idx) + " is out of range")
    ref rg = meta.row_groups[rg_idx]
    if col_idx < 0 or col_idx >= len(rg.columns) or col_idx + 1 >= len(meta.schema):
        raise Error(what + ": column " + String(col_idx) + " is not a leaf")
    ref chunk = rg.columns[col_idx]
    _require_page_index(chunk, what, rg_idx, col_idx)
    var parsed = get_or_parse_indexes_copy(
        cache,
        reader,
        path,
        rg_idx,
        col_idx,
        chunk.column_index_offset.value(),
        chunk.column_index_length.value(),
        chunk.offset_index_offset.value(),
        chunk.offset_index_length.value(),
    )
    return parsed.take_offset_index()


def _intersect_pred_row_ranges_via_cache[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    reader: ParquetFileReader[FS],
    path: String,
    meta: FileMetaData,
    rg_idx: Int,
    pred_col_indices: List[Int],
    pred_picks_per_col: List[List[Int]],
) raises -> List[Int]:
    """The rows every filter column keeps, as ascending flat [start, end)
    pairs; empty when there is no filter column or no common row."""
    comptime what = "page picks"
    if len(pred_col_indices) == 0:
        return List[Int]()
    if len(pred_picks_per_col) != len(pred_col_indices):
        raise Error(what + ": one pick list per filter column is required")
    var rows = meta.row_groups[rg_idx].num_rows if rg_idx >= 0 and rg_idx < len(
        meta.row_groups
    ) else 0
    var oi0 = _offset_index_of(cache, reader, path, meta, rg_idx, pred_col_indices[0], what)
    var current = _absolute_row_ranges_for_picks(oi0, pred_picks_per_col[0], rows)
    for i in range(1, len(pred_col_indices)):
        var oi = _offset_index_of(cache, reader, path, meta, rg_idx, pred_col_indices[i], what)
        var ranges = _absolute_row_ranges_for_picks(oi, pred_picks_per_col[i], rows)
        current = _intersect_row_ranges(current, ranges)
        if len(current) == 0:
            break
    return current^


def _picks_per_col_from_row_ranges[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    reader: ParquetFileReader[FS],
    path: String,
    meta: FileMetaData,
    rg_idx: Int,
    col_indices: List[Int],
    ranges_flat: List[Int],
) raises -> List[List[Int]]:
    """Per listed column, the pages that cover any row of `ranges_flat`."""
    var out = List[List[Int]]()
    for i in range(len(col_indices)):
        var oi = _offset_index_of(
            cache, reader, path, meta, rg_idx, col_indices[i], "page picks"
        )
        out.append(
            _picks_overlapping_row_ranges(
                oi, ranges_flat, meta.row_groups[rg_idx].num_rows
            )
        )
    return out^


def _rows_of_runs(oi: OffsetIndex, picks: List[Int], chunk_rows: Int) -> List[Int]:
    """The picked pages' rows as merged ascending [start, end) pairs."""
    var flat = _absolute_row_ranges_for_picks(oi, picks, chunk_rows)
    var out = List[Int]()
    for k in range(len(flat) // 2):
        var s = flat[2 * k]
        var e = flat[2 * k + 1]
        if len(out) > 0 and out[len(out) - 1] == s:
            out[len(out) - 1] = e
        else:
            out.append(s)
            out.append(e)
    return out^


def _decode_columns_with_per_col_picks[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    reader: ParquetFileReader[FS],
    path: String,
    meta: FileMetaData,
    rg_idx: Int,
    col_indices: List[Int],
    picks_per_col: List[List[Int]],
    preserve_dict: Bool,
) raises -> RecordBatch:
    """Each listed column's picked pages, decoded, as one batch.

    Raises:
        Error if a column has no page index, a pick is out of range, the
        columns' picked pages do not cover the same rows (their page
        boundaries differ there), or a page does not decode.
    """
    comptime what = "page picks"
    if len(picks_per_col) != len(col_indices):
        raise Error(what + ": one pick list per column is required")
    var rows = 0
    var sb = SchemaBuilder()
    var ois = List[OffsetIndex]()
    for i in range(len(col_indices)):
        ois.append(
            _offset_index_of(cache, reader, path, meta, rg_idx, col_indices[i], what)
        )
        sb.add_field(field_from_schema_element(meta.schema[col_indices[i] + 1]))
    var out_schema = sb.build()
    ref rg = meta.row_groups[rg_idx]
    rows = rg.num_rows
    var covered = List[Int]()
    for i in range(len(col_indices)):
        var c = _rows_of_runs(ois[i], picks_per_col[i], rows)
        if i == 0:
            covered = c^
        elif c != covered:
            raise Error(
                what
                + ": column "
                + String(col_indices[i])
                + "'s picked pages cover other rows than column "
                + String(col_indices[0])
                + "'s (their page boundaries differ); read the whole chunks"
            )
    var builder = RecordBatchBuilder.with_capacity(len(col_indices))
    for i in range(len(col_indices)):
        var c = col_indices[i]
        var runs = coalesce_pages(ois[i], picks_per_col[i], rows)
        builder.add_column(
            read_selected_pages_via_runs(
                reader, rg.columns[c], meta.schema[c + 1], runs, preserve_dict
            )
        )
    return builder.build(out_schema^)


def _decode_predicate_cols_with_picks[FS: FileSystem](
    mut cache: ParquetPageIndexCache,
    reader: ParquetFileReader[FS],
    path: String,
    meta: FileMetaData,
    rg_idx: Int,
    col_indices: List[Int],
    var picks: List[Int],
    pred_col_idx: Int,
    preserve_dict: Bool,
) raises -> RecordBatch:
    """The pages `picks` (chosen on filter column `pred_col_idx`) of every
    listed column: `_decode_columns_with_per_col_picks` with one pick list
    for all. The filter column must have a page index.

    Raises:
        As `_decode_columns_with_per_col_picks`.
    """
    _ = _offset_index_of(
        cache, reader, path, meta, rg_idx, pred_col_idx, "page picks"
    )
    var per_col = List[List[Int]]()
    for _ in range(len(col_indices)):
        per_col.append(picks.copy())
    return _decode_columns_with_per_col_picks(
        cache, reader, path, meta, rg_idx, col_indices, per_col, preserve_dict
    )
