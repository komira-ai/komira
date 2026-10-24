# =============================================================================
# page_index — a column chunk's page index, and reads of only some pages
# =============================================================================
#
# A Parquet writer may write, per column chunk, a ColumnIndex (each data
# page's min and max, whether it is all null, its null count, the boundary
# order) and an OffsetIndex (each data page's file offset, compressed size
# and first row). With them a reader skips the pages whose values cannot
# match a filter. This module holds the two indexes as parsed values and
# reads a chunk's chosen pages:
#
#   * `ColumnIndex`: per-page min/max as Int64 (the pruner serves INT64
#     columns), with a per-page flag saying whether the page's bounds were
#     written (a writer may leave a page's min/max empty; such a page can
#     never be skipped on its bounds);
#   * `OffsetIndex`: per-page location; `page_rows(i, chunk_rows)` is the
#     exact row count of page `i` (the last page's ends at the chunk's row
#     count, which the OffsetIndex does not record);
#   * `coalesce_pages(oi, picks, chunk_rows)`: adjacent chosen pages merged
#     into byte runs, one read each;
#   * `read_selected_pages_via_runs(reader, chunk, elem, runs)`: the runs'
#     pages decoded as one column. A dictionary-encoded chunk's dictionary
#     page, which the OffsetIndex does not list, is read and decoded first.
# =============================================================================

from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_counters.parquet_read_counter import (
    parquet_note_column_chunk_decoded,
)
from komira_fs.file_system import FileSystem
from komira_parquet_api.metadata import ColumnChunk, SchemaElement
from komira_parquet_api.types import BoundaryOrder, FieldRepetitionType

from .column_decode_context import ColumnDecodeContext
from .column_decoder import NumericDictCodesHolder, decode_column_pages
from .decode_helpers import flba_schema_info
from .file_reader import ParquetFileReader
from .morsel_reader import restamp_decoded_column


struct ColumnIndex(Copyable, Movable):
    """Per-page statistics of one column chunk, min/max read as Int64.

    `has_bounds[i]` is False when page `i`'s min or max was not written
    as an 8-byte value: its `min_values_int64[i]` / `max_values_int64[i]`
    are 0 placeholders, not bounds.
    """

    var null_pages: List[Bool]
    var min_values_int64: List[Int64]
    var max_values_int64: List[Int64]
    var has_bounds: List[Bool]
    var num_pages: Int
    var boundary_order: BoundaryOrder
    var null_counts: Optional[List[Int]]

    def __init__(
        out self,
        var null_pages: List[Bool],
        var min_values_int64: List[Int64],
        var max_values_int64: List[Int64],
        num_pages: Int,
        boundary_order: BoundaryOrder = BoundaryOrder.UNORDERED,
        var null_counts: Optional[List[Int]] = None,
        var has_bounds: Optional[List[Bool]] = None,
    ):
        """Per-page statistics; without `has_bounds` every page's min/max
        are taken as written bounds."""
        self.null_pages = null_pages^
        self.min_values_int64 = min_values_int64^
        self.max_values_int64 = max_values_int64^
        self.num_pages = num_pages
        self.boundary_order = boundary_order
        self.null_counts = null_counts^
        if has_bounds:
            self.has_bounds = has_bounds.take()
        else:
            self.has_bounds = List[Bool](capacity=num_pages)
            for _ in range(num_pages):
                self.has_bounds.append(True)

    def page_has_bounds(self, i: Int) -> Bool:
        """Page `i`'s min and max were written."""
        return self.has_bounds[i]

    def has_int64_stats(self) -> Bool:
        """At least one page's min and max were written."""
        for i in range(len(self.has_bounds)):
            if self.has_bounds[i]:
                return True
        return False


struct OffsetIndex(Copyable, Movable):
    """Per-page file offset (of the page header), compressed size (header
    included) and first row, of one column chunk."""

    var offsets: List[Int]
    var compressed_sizes: List[Int]
    var first_row_indices: List[Int]
    var num_pages: Int

    def __init__(
        out self,
        var offsets: List[Int],
        var compressed_sizes: List[Int],
        var first_row_indices: List[Int],
        num_pages: Int,
    ):
        self.offsets = offsets^
        self.compressed_sizes = compressed_sizes^
        self.first_row_indices = first_row_indices^
        self.num_pages = num_pages

    def page_end_row(self, i: Int, chunk_rows: Int) -> Int:
        """One past page `i`'s last row: the next page's first row, or
        `chunk_rows` for the last page."""
        if i + 1 < self.num_pages:
            return self.first_row_indices[i + 1]
        return chunk_rows

    def page_rows(self, i: Int, chunk_rows: Int) -> Int:
        """Page `i`'s row count, in a chunk of `chunk_rows` rows."""
        return self.page_end_row(i, chunk_rows) - self.first_row_indices[i]


@fieldwise_init
struct PageByteRun(Copyable, Movable):
    """Adjacent chosen pages [start_pick, end_pick_excl) as one byte run:
    `byte_length` bytes from `byte_offset`, holding `num_rows` rows from
    row `first_row_idx` of the chunk."""

    var start_pick: Int
    var end_pick_excl: Int
    var byte_offset: Int
    var byte_length: Int
    var first_row_idx: Int
    var num_rows: Int

    def num_pages(self) -> Int:
        return self.end_pick_excl - self.start_pick


def coalesce_pages(
    offset_index: OffsetIndex, picks: List[Int], chunk_rows: Int
) raises -> List[PageByteRun]:
    """Adjacent picks merged into byte runs (one read per run).

    Args:
        offset_index: The chunk's OffsetIndex.
        picks: Chosen page indices, strictly ascending.
        chunk_rows: The chunk's row count (the row group's), which ends
            the last page.

    Raises:
        Error if a pick is out of range or the picks are not strictly
        ascending, or adjacent pages are not adjacent in the file.
    """
    var out = List[PageByteRun]()
    if len(picks) == 0:
        return out^
    var n = offset_index.num_pages
    var prev = -1
    for i in range(len(picks)):
        var p = picks[i]
        if p < 0 or p >= n:
            raise Error(
                "coalesce_pages: pick "
                + String(p)
                + " out of range [0, "
                + String(n)
                + ")"
            )
        if p <= prev:
            raise Error(
                "coalesce_pages: picks not strictly ascending at index "
                + String(i)
            )
        prev = p

    var start = picks[0]
    var end = start + 1
    for i in range(1, len(picks) + 1):
        var extends = i < len(picks) and picks[i] == end
        if extends:
            var p = picks[i]
            # A run is read as one range: the page must start where the
            # previous one ended.
            if (
                offset_index.offsets[p]
                != offset_index.offsets[p - 1] + offset_index.compressed_sizes[p - 1]
            ):
                raise Error(
                    "coalesce_pages: page "
                    + String(p)
                    + " does not start where page "
                    + String(p - 1)
                    + " ends"
                )
            end = p + 1
            continue
        var first_row = offset_index.first_row_indices[start]
        var bytes = 0
        for p in range(start, end):
            bytes += offset_index.compressed_sizes[p]
        out.append(
            PageByteRun(
                start_pick=start,
                end_pick_excl=end,
                byte_offset=offset_index.offsets[start],
                byte_length=bytes,
                first_row_idx=first_row,
                num_rows=offset_index.page_end_row(end - 1, chunk_rows) - first_row,
            )
        )
        if i < len(picks):
            start = picks[i]
            end = start + 1
    return out^


def read_selected_pages_via_runs[FS: FileSystem](
    reader: ParquetFileReader[FS],
    chunk: ColumnChunk,
    schema_elem: SchemaElement,
    runs: List[PageByteRun],
    preserve_dict: Bool = False,
) raises -> Column[HeapRegion]:
    """The rows of `runs`' pages of one flat column chunk, as one Column.

    Each run is read once and the runs are spliced, after the chunk's
    dictionary page when it has one (the OffsetIndex lists data pages only,
    and a dictionary-encoded page decodes against it), then decoded and
    type-stamped as a whole chunk would be. The column has the runs' rows,
    in file order; no runs give an empty column.

    Raises:
        Error if a run is outside the file, or the pages do not decode.
    """
    ref meta = chunk.meta_data
    var dict_len = 0
    var dict_off = 0
    if meta.dictionary_page_offset:
        dict_off = meta.dictionary_page_offset.value()
        if dict_off < meta.data_page_offset:
            dict_len = meta.data_page_offset - dict_off
    var total_bytes = 0
    var total_rows = 0
    for i in range(len(runs)):
        if runs[i].byte_length < 0 or runs[i].num_rows < 0:
            raise Error("read_selected_pages_via_runs: a run of negative size")
        total_bytes += runs[i].byte_length
        total_rows += runs[i].num_rows
    if total_rows == 0:
        # No rows: decode no page (not even the dictionary).
        dict_len = 0
        total_bytes = 0
    var merged = OwnedAlignedBuffer(max(dict_len + total_bytes, 1))
    merged.set_length(Int64(dict_len + total_bytes))
    var at = 0
    if dict_len > 0:
        var d = reader.read_bytes(dict_off, dict_len)
        merged.copy_from_view_at(0, d.view_range_ro(0, dict_len))
        at = dict_len
    if total_rows > 0:
        for i in range(len(runs)):
            ref r = runs[i]
            if r.byte_length == 0:
                continue
            var buf = reader.read_bytes(r.byte_offset, r.byte_length)
            merged.copy_from_view_at(at, buf.view_range_ro(0, r.byte_length))
            at += r.byte_length
    parquet_note_column_chunk_decoded(dict_len + total_bytes)

    var nullable = True
    if schema_elem.repetition_type:
        if schema_elem.repetition_type.value() == FieldRepetitionType.REQUIRED:
            nullable = False
    var info = flba_schema_info(schema_elem)
    var ts_unit = -1
    if schema_elem.logical_timestamp_unit:
        ts_unit = schema_elem.logical_timestamp_unit.value()
    var no_fuse = NumericDictCodesHolder()
    var ctx = ColumnDecodeContext()
    var col = decode_column_pages(
        merged.view_range_ro(0, dict_len + total_bytes).into_span(),
        meta.type,
        meta.codec,
        total_rows,
        nullable,
        False,
        no_fuse,
        ctx,
        info[0],
        info[1],
        info[2],
        preserve_dict,
        info[3],
    )
    return restamp_decoded_column(col^, meta.type, info[1], ts_unit)
