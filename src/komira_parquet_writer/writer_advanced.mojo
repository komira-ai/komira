# =============================================================================
# AdvancedParquetWriter: row groups, page index, bloom filters, page CRC
# =============================================================================
#
# What `ParquetFileWriter` does not: any number of row groups, and per column
# chunk a ColumnIndex and OffsetIndex (page-level pruning), a bloom filter,
# and a CRC-32 in the data page header.
#
# File layout:
#   [PAR1]
#   [row group 1: column chunks] [row group 1: bloom filters (optional)]
#   [row group 2: ...]
#   [ColumnIndex blobs] [OffsetIndex blobs]
#   [Thrift FileMetaData] [footer length: u32 LE] [PAR1]
#
# A row group is built by `add_column_page` calls, exactly one chunk per leaf
# column, all with the same row count; `flush_row_group` closes it and starts
# the next. Chunks go to the footer in schema order whatever order they were
# added in. The writer returns the file's bytes (`close_to_bytes`); it opens
# no file.
#
# The page index describes data pages. A chunk here is one data page (after
# a dictionary page, when the chunk has one), so each column contributes one
# location per row group, pointing at the data page and not at the chunk's
# dictionary page. A ColumnIndex needs a min and a max for every page; a chunk
# added without them (and not entirely null) gets an OffsetIndex only.
# =============================================================================

from komira_dynamic_filter.bloom_filter import BloomFilter
from komira_parquet_api.metadata import (
    ColumnChunk,
    RowGroup,
    SchemaElement,
)
from komira_parquet_api.types import ParquetType

from .column_page import ColumnPage, _append_bytes
from .file_assembly import (
    append_magic,
    column_chunk_for_page,
    finish_file,
    row_group_for_chunks,
)
from .page_crc import page_with_crc
from .writer_bloom import serialize_bloom_filter
from .writer_page_index import (
    ColumnPageTracker,
    serialize_column_index,
    serialize_offset_index,
)


struct SerializedBloomFilter(Copyable, Movable):
    """A bloom filter already serialized for one column (a `BloomFilter` is
    move-only, so a list of them holds these bytes instead).

    Fields:
        column_index: 0-based leaf column index.
        header_bytes: The Thrift BloomFilterHeader.
        bitset_bytes: The raw bitset.
    """

    var column_index: Int
    var header_bytes: List[UInt8]
    var bitset_bytes: List[UInt8]

    def __init__(
        out self,
        column_index: Int,
        var header_bytes: List[UInt8],
        var bitset_bytes: List[UInt8],
    ):
        self.column_index = column_index
        self.header_bytes = header_bytes^
        self.bitset_bytes = bitset_bytes^


struct RowGroupState(Copyable, Movable):
    """One row group while it is being filled.

    Fields:
        pages: The column chunks added, in the order added.
        num_rows: The row count every chunk must have (set by the first).
        page_trackers: One per leaf column, holding its page boundary.
        index_usable: Per column, whether its ColumnIndex can be written
            (every page had a min and a max, or was entirely null).
        bloom_data: The bloom filters set for this row group.
    """

    var pages: List[ColumnPage]
    var num_rows: Int
    var page_trackers: List[ColumnPageTracker]
    var index_usable: List[Bool]
    var bloom_data: List[SerializedBloomFilter]

    def __init__(out self, physical_types: List[ParquetType]):
        self.pages = List[ColumnPage]()
        self.num_rows = 0
        self.page_trackers = List[ColumnPageTracker]()
        self.index_usable = List[Bool]()
        self.bloom_data = List[SerializedBloomFilter]()
        for i in range(len(physical_types)):
            self.page_trackers.append(ColumnPageTracker(physical_types[i]))
            self.index_usable.append(True)


struct WriterConfig(Copyable, Movable):
    """What the advanced writer emits.

    Fields:
        enable_page_index: Write a ColumnIndex and OffsetIndex per chunk.
        enable_bloom_filters: Write the bloom filters given to
            `set_bloom_filter`; without it `set_bloom_filter` refuses, so a
            filter is never silently dropped.
        enable_crc: Put the CRC-32 of the stored body in each data page's
            header (see `page_crc` for the chunks this covers).
    """

    var enable_page_index: Bool
    var enable_bloom_filters: Bool
    var enable_crc: Bool

    def __init__(
        out self,
        enable_page_index: Bool = True,
        enable_bloom_filters: Bool = False,
        enable_crc: Bool = False,
    ):
        self.enable_page_index = enable_page_index
        self.enable_bloom_filters = enable_bloom_filters
        self.enable_crc = enable_crc


struct AdvancedParquetWriter(Movable):
    """A multi-row-group Parquet writer with page index, bloom filters and
    page CRCs.

    Usage:
        var writer = AdvancedParquetWriter.create(schema, WriterConfig())
        writer.add_column_page_simple(page_for_column_0)
        writer.add_column_page_simple(page_for_column_1)
        writer.flush_row_group()      # row group 1 is closed
        ...
        var file = writer.close_to_bytes()

    Fields:
        schema_elements: The flattened schema (root, then one per leaf).
        config: What to emit.
        row_group_states: The closed row groups.
        current_rg: The row group being filled.
        num_columns: The number of leaf columns.
        total_num_rows: Rows in the closed row groups.
        closed: True after `close_to_bytes`.
    """

    var schema_elements: List[SchemaElement]
    var config: WriterConfig
    var row_group_states: List[RowGroupState]
    var current_rg: RowGroupState
    var num_columns: Int
    var total_num_rows: Int
    var closed: Bool

    @staticmethod
    def create(
        var schema_elements: List[SchemaElement],
        var config: WriterConfig,
    ) raises -> AdvancedParquetWriter:
        """A writer over `schema_elements` (root first, then flat leaves).

        Raises:
            Error: the schema is empty or a leaf has no physical type.
        """
        var leaves = len(schema_elements) - 1
        if leaves < 0:
            raise Error("AdvancedParquetWriter: the schema has no root element")
        var types = List[ParquetType]()
        for i in range(leaves):
            if not schema_elements[i + 1].type:
                raise Error(
                    "AdvancedParquetWriter: schema leaf '"
                    + schema_elements[i + 1].name
                    + "' has no physical type (nested schemas are not written)"
                )
            types.append(schema_elements[i + 1].type.value())
        return AdvancedParquetWriter(
            schema_elements^,
            config^,
            List[RowGroupState](),
            RowGroupState(types),
            leaves,
            0,
            False,
        )

    def __init__(
        out self,
        var schema_elements: List[SchemaElement],
        var config: WriterConfig,
        var row_group_states: List[RowGroupState],
        var current_rg: RowGroupState,
        num_columns: Int,
        total_num_rows: Int,
        closed: Bool,
    ):
        self.schema_elements = schema_elements^
        self.config = config^
        self.row_group_states = row_group_states^
        self.current_rg = current_rg^
        self.num_columns = num_columns
        self.total_num_rows = total_num_rows
        self.closed = closed

    def _physical_types(self) -> List[ParquetType]:
        var types = List[ParquetType]()
        for i in range(self.num_columns):
            types.append(self.schema_elements[i + 1].type.value())
        return types^

    def add_column_page(
        mut self,
        var page: ColumnPage,
        var min_value: List[UInt8],
        var max_value: List[UInt8],
        null_count: Int = 0,
        is_null_page: Bool = False,
    ) raises:
        """Add a column's chunk to the current row group, with the page's
        min and max (PLAIN bytes: little-endian for numbers) for the
        ColumnIndex.

        Raises:
            Error: the writer is closed, the column index is out of range,
                the row group already holds a chunk for the column, or the
                chunk's row count differs from the row group's.
        """
        if self.closed:
            raise Error("AdvancedParquetWriter: writer is already closed")
        var col = page.column_index
        if col < 0 or col >= self.num_columns:
            raise Error(
                "AdvancedParquetWriter: column_index "
                + String(col)
                + " out of range (schema has "
                + String(self.num_columns)
                + " leaf columns)"
            )
        for i in range(len(self.current_rg.pages)):
            if self.current_rg.pages[i].column_index == col:
                raise Error(
                    "AdvancedParquetWriter: column "
                    + String(col)
                    + " already has a chunk in this row group;"
                    " flush_row_group starts the next one"
                )
        if len(self.current_rg.pages) == 0:
            self.current_rg.num_rows = page.num_values
        elif page.num_values != self.current_rg.num_rows:
            raise Error(
                "AdvancedParquetWriter: column "
                + String(col)
                + " has "
                + String(page.num_values)
                + " rows, expected "
                + String(self.current_rg.num_rows)
            )
        if self.config.enable_page_index:
            if not is_null_page and (len(min_value) == 0 or len(max_value) == 0):
                self.current_rg.index_usable[col] = False
            # The offset and size are the data page's, set when the file is
            # laid out.
            self.current_rg.page_trackers[col].add_page(
                offset=0,
                compressed_page_size=0,
                first_row_index=0,
                min_value=min_value^,
                max_value=max_value^,
                null_count=null_count,
                is_null_page=is_null_page,
            )
        self.current_rg.pages.append(page^)

    def add_column_page_simple(mut self, var page: ColumnPage) raises:
        """`add_column_page` with the min, max and null count taken from the
        page's own statistics. A page without a min and a max (an encoder
        that computes none) is indexed by OffsetIndex only; an entirely null
        page is a null page.
        """
        var min_value = List[UInt8]()
        var max_value = List[UInt8]()
        var null_count = 0
        var is_null_page = False
        if page.statistics:
            ref s = page.statistics.value()
            if s.null_count:
                null_count = s.null_count.value()
            if Bool(s.min_value) and Bool(s.max_value):
                min_value = s.min_value.value().copy()
                max_value = s.max_value.value().copy()
            elif s.null_count and page.num_values > 0:
                is_null_page = s.null_count.value() == page.num_values
        self.add_column_page(
            page^, min_value^, max_value^, null_count, is_null_page
        )

    def set_bloom_filter(
        mut self, column_index: Int, var bf: BloomFilter
    ) raises:
        """Attach `bf` to a column of the current row group. It is
        serialized now.

        Raises:
            Error: bloom filters are not enabled, the column index is out of
                range, the column already has one in this row group, or the
                filter does not use xxHash64.
        """
        if self.closed:
            raise Error("AdvancedParquetWriter: writer is already closed")
        if not self.config.enable_bloom_filters:
            raise Error(
                "AdvancedParquetWriter: set_bloom_filter needs"
                " WriterConfig(enable_bloom_filters=True)"
            )
        if column_index < 0 or column_index >= self.num_columns:
            raise Error(
                "AdvancedParquetWriter: column_index "
                + String(column_index)
                + " out of range"
            )
        for i in range(len(self.current_rg.bloom_data)):
            if self.current_rg.bloom_data[i].column_index == column_index:
                raise Error(
                    "AdvancedParquetWriter: column "
                    + String(column_index)
                    + " already has a bloom filter in this row group"
                )
        var header = List[UInt8]()
        var bitset = List[UInt8]()
        serialize_bloom_filter(bf, header, bitset)
        self.current_rg.bloom_data.append(
            SerializedBloomFilter(column_index, header^, bitset^)
        )

    def _check_current_row_group(self) raises:
        if len(self.current_rg.pages) != self.num_columns:
            raise Error(
                "AdvancedParquetWriter: the row group has "
                + String(len(self.current_rg.pages))
                + " of "
                + String(self.num_columns)
                + " columns"
            )
        for i in range(len(self.current_rg.bloom_data)):
            var found = False
            for p in range(len(self.current_rg.pages)):
                if (
                    self.current_rg.pages[p].column_index
                    == self.current_rg.bloom_data[i].column_index
                ):
                    found = True
            if not found:
                raise Error(
                    "AdvancedParquetWriter: a bloom filter is set for column "
                    + String(self.current_rg.bloom_data[i].column_index)
                    + ", which has no chunk in the row group"
                )

    def flush_row_group(mut self) raises:
        """Close the current row group and start the next. An empty row
        group is skipped.

        Raises:
            Error: the row group does not hold one chunk for every column.
        """
        if len(self.current_rg.pages) == 0:
            return
        self._check_current_row_group()
        var types = self._physical_types()
        self.total_num_rows += self.current_rg.num_rows
        self.row_group_states.append(self.current_rg^)
        self.current_rg = RowGroupState(types)

    def close_to_bytes(mut self) raises -> List[UInt8]:
        """Close the current row group and return the file's bytes. Ends the
        writer.

        Raises:
            Error: the writer is already closed, the last row group is
                incomplete, or the footer cannot be serialized.
        """
        if self.closed:
            raise Error("AdvancedParquetWriter: writer is already closed")
        self.flush_row_group()
        self.closed = True

        var file_bytes = List[UInt8]()
        append_magic(file_bytes)
        var row_groups = List[RowGroup]()
        # Page index blobs, [row group][column], written after every row
        # group.
        var ci_blobs = List[List[List[UInt8]]]()
        var oi_blobs = List[List[List[UInt8]]]()
        for rg_idx in range(len(self.row_group_states)):
            var ci = List[List[UInt8]]()
            var oi = List[List[UInt8]]()
            var rg = _write_row_group(
                self.config,
                self.num_columns,
                self.row_group_states[rg_idx],
                file_bytes,
                ci,
                oi,
            )
            row_groups.append(rg^)
            ci_blobs.append(ci^)
            oi_blobs.append(oi^)
        if self.config.enable_page_index:
            # ColumnIndexes first, then OffsetIndexes, each blob's offset
            # and length recorded on its column chunk.
            for rg_idx in range(len(row_groups)):
                for col in range(self.num_columns):
                    if len(ci_blobs[rg_idx][col]) > 0:
                        row_groups[rg_idx].columns[col].column_index_offset = len(
                            file_bytes
                        )
                        row_groups[rg_idx].columns[col].column_index_length = len(
                            ci_blobs[rg_idx][col]
                        )
                        _append_bytes(file_bytes, ci_blobs[rg_idx][col])
            for rg_idx in range(len(row_groups)):
                for col in range(self.num_columns):
                    if len(oi_blobs[rg_idx][col]) > 0:
                        row_groups[rg_idx].columns[col].offset_index_offset = len(
                            file_bytes
                        )
                        row_groups[rg_idx].columns[col].offset_index_length = len(
                            oi_blobs[rg_idx][col]
                        )
                        _append_bytes(file_bytes, oi_blobs[rg_idx][col])
        finish_file(
            file_bytes, self.schema_elements, self.total_num_rows, row_groups^
        )
        return file_bytes^


def _write_row_group(
    config: WriterConfig,
    num_columns: Int,
    mut state: RowGroupState,
    mut file_bytes: List[UInt8],
    mut ci: List[List[UInt8]],
    mut oi: List[List[UInt8]],
) raises -> RowGroup:
    """Append one row group's chunks and bloom filters to `file_bytes`,
    fill `ci` and `oi` with the per-column page index blobs (empty when
    there is none), and return its footer entry (chunks in schema
    order)."""
    var chunks = List[Optional[ColumnChunk]]()
    for _ in range(num_columns):
        chunks.append(None)
    for i in range(len(state.pages)):
        var page = state.pages[i].copy()
        if config.enable_crc:
            page = page_with_crc(page^)
        var col = page.column_index
        var offset = len(file_bytes)
        _append_bytes(file_bytes, page.data)
        if config.enable_page_index:
            # The page index locates data pages: in a dictionary chunk
            # the data page follows the dictionary page.
            ref pb = state.page_trackers[col].pages[0]
            pb.offset = offset + page.dict_page_size
            pb.compressed_page_size = len(page.data) - page.dict_page_size
        chunks[col] = column_chunk_for_page(page, offset)
    if config.enable_bloom_filters:
        for i in range(len(state.bloom_data)):
            ref bd = state.bloom_data[i]
            var bf_offset = len(file_bytes)
            _append_bytes(file_bytes, bd.header_bytes)
            _append_bytes(file_bytes, bd.bitset_bytes)
            ref meta = chunks[bd.column_index].value().meta_data
            meta.bloom_filter_offset = bf_offset
            meta.bloom_filter_length = len(bd.header_bytes) + len(
                bd.bitset_bytes
            )
    for col in range(num_columns):
        if config.enable_page_index:
            if state.index_usable[col]:
                ci.append(serialize_column_index(state.page_trackers[col]))
            else:
                ci.append(List[UInt8]())
            oi.append(serialize_offset_index(state.page_trackers[col]))
        else:
            ci.append(List[UInt8]())
            oi.append(List[UInt8]())
    var ordered = List[ColumnChunk]()
    for col in range(num_columns):
        ordered.append(chunks[col].take())
    return row_group_for_chunks(ordered^, state.num_rows)
