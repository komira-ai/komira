# =============================================================================
# morsel_reader — a local Parquet file read a row group, or a morsel, at a time
# =============================================================================
#
# `ParquetMorselReader` opens a local Parquet file, parses its footer once
# (or takes it from a session's `ParquetMetadataCache`), and decodes it:
#
#   * `next_morsel()` yields RecordBatches of at most `morsel_size` rows in
#     file order. It decodes one whole row group, then hands it out in
#     windows (`morsel_slice.slice_column_rows`); a row group that fits in
#     one morsel is handed out as decoded. The whole file is never resident.
#   * `decode_row_group_shared(rg)` and `decode_columns_for_rg(rg, cols)`
#     decode one row group (the projection, or the listed columns) without
#     touching the iterator state, so workers may call them concurrently on
#     distinct row groups: they read only the footer, the projection and the
#     file (by `pread`).
#   * `try_decode_column_with_selection(rg, col, intervals, n)` decodes only
#     the selected rows of one column chunk in one pass, or returns None
#     when the selection gather does not take the chunk's shape.
#   * `read_raw_chunks_for_rg(rg, cols)` reads column chunks as stored, for
#     a pass-through write.
#
# A column chunk becomes a Column through `column_decoder.decode_column_pages`
# and the type re-stamps of `decode_helpers` (unsigned and narrow integers,
# DATE, TIMESTAMP units, unannotated BYTE_ARRAY as BINARY). Every chunk it
# decodes is counted (`komira_counters.parquet_note_column_chunk_decoded`),
# so a test can see which columns a scan read.
#
# The projection and the dictionary choice are set before any worker
# decodes (`set_projection`, `set_preserve_dict`); both drop the row group
# `next_morsel` holds, so the next morsel decodes under the new setting.
# =============================================================================

from komira_arrow.column import Column
from komira_arrow.record_batch import RecordBatch, RecordBatchBuilder
from komira_arrow.schema import Field, Schema, SchemaBuilder
from komira_async.ops.waker_sink import NoopSink
from komira_buffer.constants import DEFAULT_MORSEL_ROWS
from komira_buffer.heap_region import HeapRegion
from komira_counters.parquet_read_counter import (
    parquet_note_column_chunk_decoded,
)
from komira_fs.local_fs import LocalFs
from komira_parquet_api.metadata import ColumnChunk, FileMetaData
from komira_parquet_api.types import FieldRepetitionType, ParquetType

from .bypass import RawColumnChunk, read_raw_column_chunk
from .column_decode_context import ColumnDecodeContext
from .column_decoder import NumericDictCodesHolder, decode_column_pages
from .data_page_count import all_pages_mask
from .decode_helpers import (
    _narrow_int_logical_type,
    _relabel_byte_array_binary,
    _relabel_int_logical_type,
    _relabel_timestamp_logical_type,
    field_from_schema_element,
    flba_schema_info,
)
from .file_reader import ParquetFileReader
from .gather import decode_column_with_selection
from .metadata_parser import parse_full_metadata
from .morsel_slice import slice_column_rows
from .runtime_footer_cache import ParquetMetadataCache
from .selection_vector import SelectionInterval


struct ColumnProjection(Copyable, Movable):
    """Which leaf columns a reader decodes: every column, or the listed
    0-based leaf indices in the order listed (the output batch's order)."""

    var project_all: Bool
    var _indices: List[Int]

    @staticmethod
    def all() -> ColumnProjection:
        """Every column."""
        return ColumnProjection(True, List[Int]())

    @staticmethod
    def columns(var indices: List[Int]) -> ColumnProjection:
        """The listed 0-based leaf indices, in this order."""
        return ColumnProjection(False, indices^)

    def __init__(out self, project_all: Bool, var indices: List[Int]):
        self.project_all = project_all
        self._indices = indices^

    def num_projected(self, total_cols: Int) -> Int:
        """The number of output columns for a file of `total_cols`."""
        if self.project_all:
            return total_cols
        return len(self._indices)

    def is_projected(self, col_idx: Int) -> Bool:
        """Whether leaf `col_idx` is decoded (a linear scan: projections
        are short)."""
        if self.project_all:
            return True
        for i in range(len(self._indices)):
            if self._indices[i] == col_idx:
                return True
        return False

    def projected_indices(self, total_cols: Int) -> List[Int]:
        """The leaf indices to decode, in output order."""
        if self.project_all:
            var result = List[Int](capacity=total_cols)
            for i in range(total_cols):
                result.append(i)
            return result^
        return self._indices.copy()


def _check_morsel_size(morsel_size: Int) raises:
    if morsel_size < 1:
        raise Error(
            "ParquetMorselReader: morsel_size must be at least 1, got "
            + String(morsel_size)
        )


def _check_projection(proj: ColumnProjection, total_cols: Int) raises:
    if proj.project_all:
        return
    for i in range(len(proj._indices)):
        var c = proj._indices[i]
        if c < 0 or c >= total_cols:
            raise Error(
                "ParquetMorselReader: projected column "
                + String(c)
                + " is not a leaf of a file with "
                + String(total_cols)
                + " columns"
            )


def _chunk_start(chunk: ColumnChunk) -> Int:
    """A chunk's first byte: its dictionary page when that comes first,
    else its first data page."""
    var start = chunk.meta_data.data_page_offset
    if chunk.meta_data.dictionary_page_offset:
        var d = chunk.meta_data.dictionary_page_offset.value()
        if d < start:
            start = d
    return start


struct ParquetMorselReader(Movable):
    """A local Parquet file, decoded a row group or a morsel at a time. See
    the module header for the iterator and the concurrent entry points."""

    var _reader: ParquetFileReader[LocalFs[NoopSink]]
    var _metadata: FileMetaData
    var _morsel_size: Int
    var _projection: ColumnProjection
    var _rg_index: Int
    var _row_offset: Int
    var _exhausted: Bool
    var _rg_batch: Optional[RecordBatch]
    var _rg_total_rows: Int
    # A BYTE_ARRAY dictionary chunk stays a DICTIONARY column (else it is
    # decoded to dense strings).
    var _preserve_dict: Bool

    @staticmethod
    def open(
        path: String, morsel_size: Int = DEFAULT_MORSEL_ROWS
    ) raises -> ParquetMorselReader:
        """Open `path`, parse its footer, and position at its first row.

        Raises:
            Error if `morsel_size < 1` or the file or footer do not parse.
        """
        return Self.open_projected(path, ColumnProjection.all(), morsel_size)

    @staticmethod
    def open_projected(
        path: String,
        var projection: ColumnProjection,
        morsel_size: Int = DEFAULT_MORSEL_ROWS,
    ) raises -> ParquetMorselReader:
        """`open`, decoding only the projected columns (the others are
        never read)."""
        _check_morsel_size(morsel_size)
        var reader = ParquetFileReader[LocalFs[NoopSink]].open(path)
        var metadata = parse_full_metadata(
            reader.metadata_bytes.view_range_ro(0, reader.metadata_length)
        )
        return ParquetMorselReader(reader^, metadata^, morsel_size, projection^)

    @staticmethod
    def open_with_cache(
        path: String,
        mut footer_cache: ParquetMetadataCache,
        morsel_size: Int = DEFAULT_MORSEL_ROWS,
    ) raises -> ParquetMorselReader:
        """`open`, taking the parsed footer from `footer_cache` (which
        parses and keeps it on a miss). The file is still opened: its
        trailer is read and checked, and the chunks are read from it."""
        _check_morsel_size(morsel_size)
        var reader = ParquetFileReader[LocalFs[NoopSink]].open(path)
        var metadata = footer_cache.get_or_parse(path)
        return ParquetMorselReader(
            reader^, metadata^, morsel_size, ColumnProjection.all()
        )

    def __init__(
        out self,
        var reader: ParquetFileReader[LocalFs[NoopSink]],
        var metadata: FileMetaData,
        morsel_size: Int,
        var projection: ColumnProjection,
    ) raises:
        _check_morsel_size(morsel_size)
        _check_projection(projection, max(len(metadata.schema) - 1, 0))
        var num_rgs = len(metadata.row_groups)
        self._reader = reader^
        self._metadata = metadata^
        self._morsel_size = morsel_size
        self._projection = projection^
        self._rg_index = 0
        self._row_offset = 0
        self._exhausted = num_rgs == 0
        self._rg_batch = None
        self._rg_total_rows = 0
        self._preserve_dict = False

    def set_preserve_dict(mut self, on: Bool):
        """Keep BYTE_ARRAY dictionary chunks as DICTIONARY columns. Drops
        the row group `next_morsel` holds."""
        self._preserve_dict = on
        self._rg_batch = None

    def set_projection(mut self, var projection: ColumnProjection) raises:
        """Replace the projection. Call it before any worker decodes; it
        drops the row group `next_morsel` holds.

        Raises:
            Error if a projected index is not a leaf of the file.
        """
        _check_projection(projection, self.num_columns())
        self._projection = projection^
        self._rg_batch = None

    def next_morsel(mut self) raises -> Optional[RecordBatch]:
        """The next batch of at most `morsel_size` rows, or None when every
        row group has been handed out. Row groups with no rows yield
        nothing."""
        var num_rgs = len(self._metadata.row_groups)
        while not self._exhausted:
            if not self._rg_batch:
                if self._rg_index >= num_rgs:
                    self._exhausted = True
                    return None
                var batch = self._decode_row_group(self._rg_index, True)
                self._rg_total_rows = batch.num_rows()
                self._rg_batch = batch^
                self._row_offset = 0
            var remaining = self._rg_total_rows - self._row_offset
            if remaining <= 0:
                self._advance_row_group()
                continue
            var rows = min(self._morsel_size, remaining)
            var batch = self._rg_batch.take()
            if self._row_offset == 0 and rows == self._rg_total_rows:
                self._advance_row_group()
                return batch^
            var out = _slice_batch(batch, self._row_offset, rows)
            self._row_offset += rows
            if self._row_offset >= self._rg_total_rows:
                self._advance_row_group()
            else:
                self._rg_batch = batch^
            return out^
        return None

    def _advance_row_group(mut self):
        self._rg_batch = None
        self._rg_index += 1
        self._row_offset = 0
        if self._rg_index >= len(self._metadata.row_groups):
            self._exhausted = True

    def num_row_groups(self) -> Int:
        """The file's row-group count."""
        return len(self._metadata.row_groups)

    def num_rows(self) -> Int:
        """The file's row count (its footer's)."""
        return self._metadata.num_rows

    def num_columns(self) -> Int:
        """The number of schema elements after the root (the leaf count
        of a flat file)."""
        return max(len(self._metadata.schema) - 1, 0)

    def is_exhausted(self) -> Bool:
        """Every morsel has been handed out."""
        return self._exhausted

    def metadata_ref(self) -> ref [self._metadata] FileMetaData:
        """The parsed footer (never mutated after open)."""
        return self._metadata

    def reset(mut self):
        """Go back to the first row of the file."""
        self._rg_index = 0
        self._row_offset = 0
        self._exhausted = len(self._metadata.row_groups) == 0
        self._rg_batch = None
        self._rg_total_rows = 0

    def decode_row_group_shared(
        self, rg_index: Int, decode_move: Bool = True
    ) raises -> RecordBatch:
        """Row group `rg_index`'s projected columns. Leaves the iterator
        state alone, so workers may call it concurrently on distinct row
        groups.

        Args:
            rg_index: The 0-based row group.
            decode_move: False decodes the fixed-width arms by copy instead
                of moving the decoded buffer (the reference the move is
                checked against); leave it defaulted otherwise.
        """
        return self._decode_row_group(rg_index, decode_move)

    def decode_columns_for_rg(
        self, rg_index: Int, col_indices: List[Int]
    ) raises -> RecordBatch:
        """The listed leaf columns of row group `rg_index`, in that order,
        whatever the projection. Concurrency as `decode_row_group_shared`."""
        _check_projection(
            ColumnProjection.columns(col_indices.copy()), self.num_columns()
        )
        return self._decode_columns(rg_index, col_indices, True)

    def read_raw_chunks_for_rg(
        self, rg_index: Int, col_indices: List[Int]
    ) raises -> List[RawColumnChunk]:
        """The listed column chunks of row group `rg_index`, as stored (no
        decompression, no decode)."""
        var out = List[RawColumnChunk](capacity=len(col_indices))
        for i in range(len(col_indices)):
            out.append(
                read_raw_column_chunk(
                    self._reader, self._metadata, rg_index, col_indices[i]
                )
            )
        return out^

    def try_decode_column_with_selection(
        self,
        rg_index: Int,
        col_idx: Int,
        intervals: Span[SelectionInterval, _],
        num_selected: Int,
    ) raises -> Optional[Column[HeapRegion]]:
        """The `num_selected` selected rows of leaf `col_idx` in row group
        `rg_index`, decoded in one pass; None when the selection gather
        does not take the chunk (the caller decodes the whole chunk and
        gathers). Concurrency as `decode_row_group_shared`."""
        self._check_rg(rg_index)
        _check_projection(ColumnProjection.columns([col_idx]), self.num_columns())
        ref chunk = self._metadata.row_groups[rg_index].columns[col_idx]
        ref meta = chunk.meta_data
        var raw = self._reader.read_bytes(
            _chunk_start(chunk), meta.total_compressed_size
        )
        parquet_note_column_chunk_decoded(meta.total_compressed_size)
        var data = raw.view_range_mut(0, raw.len()).into_span()
        ref elem = self._metadata.schema[col_idx + 1]
        var max_def_level = 0
        if elem.repetition_type:
            if elem.repetition_type.value() != FieldRepetitionType.REQUIRED:
                max_def_level = 1
        var info = flba_schema_info(elem)
        var ts_unit = -1
        if elem.logical_timestamp_unit:
            ts_unit = elem.logical_timestamp_unit.value()
        var page_mask = all_pages_mask(data)
        return decode_column_with_selection(
            data,
            meta.type,
            meta.codec,
            meta.num_values,
            max_def_level,
            info[0],
            info[1],
            info[2],
            self._preserve_dict,
            Span(page_mask),
            intervals,
            num_selected,
            ts_unit,
        )

    def _check_rg(self, rg_index: Int) raises:
        if rg_index < 0 or rg_index >= len(self._metadata.row_groups):
            raise Error(
                "ParquetMorselReader: row group "
                + String(rg_index)
                + " is out of range (the file has "
                + String(len(self._metadata.row_groups))
                + ")"
            )

    def _decode_row_group(
        self, rg_index: Int, decode_move: Bool
    ) raises -> RecordBatch:
        var indices = self._projection.projected_indices(self.num_columns())
        return self._decode_columns(rg_index, indices, decode_move)

    def _decode_columns(
        self, rg_index: Int, indices: List[Int], decode_move: Bool
    ) raises -> RecordBatch:
        self._check_rg(rg_index)
        var sb = SchemaBuilder()
        for i in range(len(indices)):
            sb.add_field(field_from_schema_element(self._metadata.schema[indices[i] + 1]))
        var schema = sb.build()
        var builder = RecordBatchBuilder.with_capacity(len(indices))
        for i in range(len(indices)):
            builder.add_column(
                self._read_column_chunk(rg_index, indices[i], decode_move)
            )
        return builder.build(schema^)

    def _read_column_chunk(
        self, rg_index: Int, col_idx: Int, decode_move: Bool
    ) raises -> Column[HeapRegion]:
        """Decode leaf `col_idx` of row group `rg_index` into one Column."""
        ref chunk = self._metadata.row_groups[rg_index].columns[col_idx]
        ref meta = chunk.meta_data
        parquet_note_column_chunk_decoded(meta.total_compressed_size)
        var raw = self._reader.read_bytes(
            _chunk_start(chunk), meta.total_compressed_size
        )
        ref elem = self._metadata.schema[col_idx + 1]
        # REQUIRED columns carry no definition levels; anything else does.
        var nullable = True
        if elem.repetition_type:
            if elem.repetition_type.value() == FieldRepetitionType.REQUIRED:
                nullable = False
        var info = flba_schema_info(elem)
        var no_fuse = NumericDictCodesHolder()
        var ctx = ColumnDecodeContext()
        var col = decode_column_pages(
            raw.view_range_ro(0, raw.len()).into_span(),
            meta.type,
            meta.codec,
            meta.num_values,
            nullable,
            False,
            no_fuse,
            ctx,
            info[0],
            info[1],
            info[2],
            self._preserve_dict,
            info[3],
            decode_move,
        )
        var ts_unit = -1
        if elem.logical_timestamp_unit:
            ts_unit = elem.logical_timestamp_unit.value()
        return restamp_decoded_column(col^, meta.type, info[1], ts_unit)


def restamp_decoded_column(
    var col: Column[HeapRegion],
    ptype: ParquetType,
    converted_type: Int,
    timestamp_unit: Int,
) raises -> Column[HeapRegion]:
    """The Arrow type a decoded chunk's annotations name, stamped on its
    buffers (no copy): UINT_32 / UINT_64 and DATE re-stamped, INT_8 / INT_16
    / UINT_8 / UINT_16 narrowed, a LogicalType TIMESTAMP given its unit, and
    an unannotated BYTE_ARRAY made BINARY."""
    var relabeled = _relabel_int_logical_type(col^, ptype, converted_type)
    var narrowed = _narrow_int_logical_type(relabeled^, ptype, converted_type)
    var stamped = _relabel_timestamp_logical_type(
        narrowed^, ptype, timestamp_unit
    )
    return _relabel_byte_array_binary(stamped^, ptype, converted_type)


def _slice_batch(
    batch: RecordBatch, start: Int, rows: Int
) raises -> RecordBatch:
    """Rows [start, start + rows) of every column of `batch`."""
    var n = batch.num_columns()
    var builder = RecordBatchBuilder.with_capacity(n)
    var sb = SchemaBuilder()
    for c in range(n):
        sb.add_field(batch.schema.field_at(c))
        builder.add_column(slice_column_rows(batch.column_at(c), start, rows))
    var schema = sb.build()
    return builder.build(schema^)
