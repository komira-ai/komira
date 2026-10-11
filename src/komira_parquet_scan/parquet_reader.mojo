# =============================================================================
# parquet_reader — the scan's per-file Parquet reader (`Reader` conformer)
# =============================================================================
#
# One `ParquetReader` per (worker, file). It holds the file handle, the
# parsed footer (shared by every worker's reader of the file, behind an
# `ArcPointer`: the footer is read-only for the whole scan), a page-index
# cache and a reusable decode context (both per worker), and the footer's
# `ARROW:schema` hint, decoded once.
#
# Every batch it hands out passes through `_hint_refined`, which applies the
# footer's offset widths (`arrow_hint_refine`). A method returning
# `Optional[RecordBatch]` returns None to mean "the caller falls back" or
# "nothing in this row group matches", never an empty batch.
#
# Switches are constructor arguments, not environment reads:
#   numeric_dict_vec: under `preserve_dict`, a non-null INT32 / INT64
#       dictionary chunk decodes to a numeric dictionary column;
#   recycle_codes: the reader's own decode context recycles its dictionary
#       codes buffer across the row groups it decodes.
# =============================================================================

from std.memory import ArcPointer
from std.sys import size_of

from komira_arrow.arrow_types import ArrowType
from komira_arrow.boolean_array import BooleanArray
from komira_arrow.column import Column
from komira_arrow.copy_column_ref import copy_column_ref
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.record_batch import RecordBatch
from komira_arrow.schema import Schema
from komira_batch_eval.predicate_numeric_dict import (
    count_numeric_dict_predicate,
    survivors_numeric_dict_predicate,
)
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_fs.byte_range import ByteRange
from komira_fs.file_system import FileSystem
from komira_morsel.hash_agg_decoded import fib_hash_key, fingerprint_for_hash, partition_for_hash
from komira_parquet.arrow_schema_hint import ArrowSchemaHint, arrow_schema_hint_from_metadata
from komira_parquet.bloom_pruner import can_prune_row_group_by_bloom
from komira_parquet.bloom_reader import detect_hash_family_optional
from komira_parquet.bytes_decode import row_group_byte_range
from komira_parquet.column_decode_context import ColumnDecodeContext
from komira_parquet.file_reader import ParquetFileReader
from komira_parquet.page_index_cache import ParquetPageIndexCache
from komira_parquet.parquet_source_helpers import (
    _build_schema_from_meta,
    _decode_columns_by_name_remap,
    _decode_columns_subset_per_chunk_with_ctx,
    _decode_numeric_dict_codes_one_col,
    _name_to_file_col_idx,
    _remap_is_positional_identity,
    _resolve_result_names_to_file_indices,
)
from komira_parquet.rg_pruner import can_prune_row_group, rg_all_match_row_group
from komira_parquet_api.metadata import FileMetaData
from komira_parquet_api.types import Encoding, ParquetType
from komira_plan_expr.expr import Expr
from komira_scan_planning.reader_factory import (
    FilterPayloadResultLike,
    HashAggDecodedLike,
    Reader,
    SELECTION_DECLINES,
    SELECTION_FIXED_WIDTH,
    SELECTION_VAR_WIDTH,
)

from .arrow_hint_refine import refine_batch_by_arrow_hint
from .parquet_codes_feed import RowGroupCodesFeed, decode_rowgroup_codes_feed
from .parquet_reader_prune import decode_ranges, decode_whole, pruned_row_ranges
from .payload_sel_decode import decode_columns_subset_selected_per_chunk
from .prefetch import advise_prefetch_columns


comptime _CONVERTED_TYPE_DECIMAL: Int = 5


struct FilterPayloadBatches(FilterPayloadResultLike):
    """The two row-aligned batches of `decode_filter_and_payload`: the
    filter columns and the payload columns, each taken once."""

    var filter_batch: Optional[RecordBatch]
    var payload_batch: Optional[RecordBatch]

    def __init__(out self, var filter_batch: RecordBatch, var payload_batch: RecordBatch):
        self.filter_batch = Optional[RecordBatch](filter_batch^)
        self.payload_batch = Optional[RecordBatch](payload_batch^)

    def take_filter(mut self) -> RecordBatch:
        """Move out the filter batch (once)."""
        return self.filter_batch.take()

    def take_payload(mut self) -> RecordBatch:
        """Move out the payload batch (once)."""
        return self.payload_batch.take()


struct ParquetHashAggDecoded(HashAggDecodedLike):
    """One row group decoded for a single-INT64-key hash aggregate: the key
    column, its per-row hash, fingerprint and partition id (the agg sink's
    `fib_hash_key` / `fingerprint_for_hash` / `partition_for_hash`, bit for
    bit), and the aggregate input columns. Each piece is moved in once and
    taken once."""

    var key_array: Optional[PrimitiveArray[DType.int64]]
    var hashes: Optional[SharedAlignedBuffer[HeapRegion]]
    var fingerprints: Optional[SharedAlignedBuffer[HeapRegion]]
    var partition_ids: Optional[List[UInt8]]
    var agg_input_columns: Optional[Slab[Column[HeapRegion]]]
    var _num_rows: Int

    def __init__(
        out self,
        var key_array: PrimitiveArray[DType.int64],
        var hashes: SharedAlignedBuffer[HeapRegion],
        var fingerprints: SharedAlignedBuffer[HeapRegion],
        var partition_ids: List[UInt8],
        var agg_input_columns: Slab[Column[HeapRegion]],
        num_rows: Int,
    ):
        self.key_array = Optional[PrimitiveArray[DType.int64]](key_array^)
        self.hashes = Optional[SharedAlignedBuffer[HeapRegion]](hashes^)
        self.fingerprints = Optional[SharedAlignedBuffer[HeapRegion]](fingerprints^)
        self.partition_ids = Optional[List[UInt8]](partition_ids^)
        self.agg_input_columns = Optional[Slab[Column[HeapRegion]]](agg_input_columns^)
        self._num_rows = num_rows

    def take_key_array(mut self) -> PrimitiveArray[DType.int64]:
        return self.key_array.take()

    def take_hashes(mut self) -> SharedAlignedBuffer[HeapRegion]:
        return self.hashes.take()

    def take_fingerprints(mut self) -> SharedAlignedBuffer[HeapRegion]:
        return self.fingerprints.take()

    def take_partition_ids(mut self) -> List[UInt8]:
        return self.partition_ids.take()

    def take_agg_input_columns(mut self) -> Slab[Column[HeapRegion]]:
        return self.agg_input_columns.take()

    def num_rows(self) -> Int:
        return self._num_rows


struct ParquetReader[FS: FileSystem](Reader, Movable, Deinitable):
    """The per-(worker, file) Parquet reader of a scan.

    Fields:
        _file: The file handle and the footer bytes (and, on a mapped file
            system, the mapping, shared between workers).
        _meta: The parsed footer, shared between workers.
        _page_index_cache: This worker's page indexes, read on first use.
        _decode_ctx: This worker's reusable decode buffers.
        _arrow_hint: The footer's `ARROW:schema` hint (often empty).
        _numeric_dict_vec: See the module header.
    """

    comptime HashAggDecoded = ParquetHashAggDecoded
    comptime FilterPayloadResult = FilterPayloadBatches

    var _file: ParquetFileReader[Self.FS]
    var _meta: ArcPointer[FileMetaData]
    var _page_index_cache: ParquetPageIndexCache
    var _decode_ctx: ColumnDecodeContext
    var _arrow_hint: ArrowSchemaHint
    var _numeric_dict_vec: Bool

    def __init__(
        out self,
        var _file: ParquetFileReader[Self.FS],
        var _meta: ArcPointer[FileMetaData],
        numeric_dict_vec: Bool = False,
        recycle_codes: Bool = False,
    ):
        """A reader over an open file and its parsed footer, with an empty
        page-index cache and decode context."""
        self._file = _file^
        self._meta = _meta^
        self._page_index_cache = ParquetPageIndexCache()
        self._decode_ctx = ColumnDecodeContext(numeric_dict_vec, recycle_codes)
        self._arrow_hint = arrow_schema_hint_from_metadata(self._meta[])
        self._numeric_dict_vec = numeric_dict_vec

    def clone_for_worker(self) raises -> ParquetReader[Self.FS]:
        """This file's reader for another worker, opening nothing: the
        mapping, the footer and its bytes are shared; the file system handle,
        the page-index cache and the decode context are fresh."""
        return ParquetReader[Self.FS](
            _file=self._file.clone_sharing_mmap(),
            _meta=ArcPointer[FileMetaData](copy=self._meta),
            numeric_dict_vec=self._numeric_dict_vec,
            recycle_codes=self._decode_ctx.recycle_codes_enabled,
        )

    def mmap_share_count(self) -> Int:
        """How many live handles share this reader's file mapping (0 when
        there is none)."""
        return self._file.mmap_share_count()

    # -------------------------------------------------------------------------
    # Footer facts (no I/O)
    # -------------------------------------------------------------------------

    @always_inline
    def unit_count_for_file(self) -> Int:
        """The file's row group count."""
        return len(self._meta[].row_groups)

    @always_inline
    def unit_num_rows(self, unit_in_file: Int) -> Int:
        """Rows in row group `unit_in_file`."""
        return Int(self._meta[].row_groups[unit_in_file].num_rows)

    @always_inline
    def unit_num_columns(self, unit_in_file: Int) -> Int:
        """Leaf columns in row group `unit_in_file`."""
        return len(self._meta[].row_groups[unit_in_file].columns)

    def unit_column_selection_class(self, unit_in_file: Int, col_idx: Int, preserve_dict: Bool) -> Int:
        """The selection gather's verdict on leaf `col_idx` of row group
        `unit_in_file`, from the footer alone: it declines every physical
        type but INT32 / INT64 / FLOAT / DOUBLE / BYTE_ARRAY, a DECIMAL,
        DELTA_* and BYTE_STREAM_SPLIT pages, and a dictionary chunk under
        `preserve_dict`. A V2 page with levels, which the footer cannot show,
        is still declined by the gather returning None."""
        ref rg = self._meta[].row_groups[unit_in_file]
        if col_idx < 0 or col_idx >= len(rg.columns):
            return SELECTION_DECLINES
        ref md = rg.columns[col_idx].meta_data
        var t = md.type
        var is_ba = t == ParquetType.BYTE_ARRAY
        if not (
            is_ba or t == ParquetType.INT32 or t == ParquetType.INT64 or t == ParquetType.FLOAT
            or t == ParquetType.DOUBLE
        ):
            return SELECTION_DECLINES
        ref schema = self._meta[].schema
        if col_idx + 1 < len(schema):
            ref se = schema[col_idx + 1]
            if se.converted_type and se.converted_type.value() == _CONVERTED_TYPE_DECIMAL:
                return SELECTION_DECLINES
        var has_dict = Bool(md.dictionary_page_offset)
        for i in range(len(md.encodings)):
            var e = md.encodings[i]
            if e == Encoding.PLAIN_DICTIONARY or e == Encoding.RLE_DICTIONARY:
                has_dict = True
            elif (
                e == Encoding.DELTA_BINARY_PACKED or e == Encoding.DELTA_LENGTH_BYTE_ARRAY
                or e == Encoding.DELTA_BYTE_ARRAY or e == Encoding.BYTE_STREAM_SPLIT
            ):
                return SELECTION_DECLINES
        if has_dict and preserve_dict:
            return SELECTION_DECLINES
        return SELECTION_VAR_WIDTH if is_ba else SELECTION_FIXED_WIDTH

    def unit_byte_range(self, unit_in_file: Int) raises -> ByteRange:
        """The bytes every column chunk of row group `unit_in_file` spans."""
        var pq = row_group_byte_range(self._meta[].row_groups[unit_in_file])
        var length = Int64(pq.end) - Int64(pq.start)
        if length < 0:
            length = 0
        return ByteRange(offset=Int64(pq.start), length=length)

    def can_prune_unit(self, unit_in_file: Int, expr: Expr) raises -> Bool:
        """True iff the row group's statistics prove `expr` keeps no row."""
        return can_prune_row_group(self._meta[].row_groups[unit_in_file], self._meta[], expr)

    def unit_all_match(self, unit_in_file: Int, expr: Expr) raises -> Bool:
        """True iff the row group's statistics prove `expr` keeps every row
        (False on any doubt: missing statistics, nulls, a shape the pruner
        does not reason about)."""
        return rg_all_match_row_group(self._meta[].row_groups[unit_in_file], self._meta[], expr)

    def can_prune_unit_by_bloom(self, unit_in_file: Int, expr: Expr) raises -> Bool:
        """True iff the row group's bloom filters prove `expr`'s equality
        leaves match no row. The hash family follows the footer's
        `created_by` (xxHash64 unless the writer used another)."""
        var hash_family = detect_hash_family_optional(self._meta[].created_by)
        return can_prune_row_group_by_bloom(
            self._file, self._meta[].row_groups[unit_in_file], self._meta[], expr, hash_family
        )

    def build_arrow_schema_for_file(self) raises -> Schema:
        """The file's Arrow schema, from the footer."""
        return _build_schema_from_meta(self._meta[])

    def column_name_to_idx_for_file(self, name: String) raises -> Int:
        """The leaf index of column `name`, or -1."""
        return _name_to_file_col_idx(self._meta[], name)

    def advise_prefetch_next(self, next_unit_in_file: Int, col_indices: List[Int], mode: Int) raises -> None:
        """A read-ahead hint for the chunks of `col_indices` in row group
        `next_unit_in_file` (`prefetch.advise_prefetch_columns`)."""
        advise_prefetch_columns(self._file, self._meta[], next_unit_in_file, col_indices, mode)

    def read_unit_bulk_bytes(self, offset: Int, length: Int) raises -> SharedAlignedBuffer[HeapRegion]:
        """`length` bytes of the file from `offset`."""
        return self._file.read_bytes(offset, length)

    # -------------------------------------------------------------------------
    # Decodes
    # -------------------------------------------------------------------------

    @always_inline
    def _hint_refined(self, var batch: RecordBatch) raises -> RecordBatch:
        return refine_batch_by_arrow_hint(batch^, self._arrow_hint)

    def decode_columns_subset(self, unit_in_file: Int, col_indices: List[Int], preserve_dict: Bool) raises -> RecordBatch:
        """`col_indices` of row group `unit_in_file`, in that order, each
        chunk with a fresh decode context."""
        return self._hint_refined(
            decode_whole(self._file, self._meta[], unit_in_file, col_indices, preserve_dict, self._numeric_dict_vec)
        )

    def decode_columns_subset_with_ctx(
        self,
        unit_in_file: Int,
        col_indices: List[Int],
        preserve_dict: Bool,
        mut decode_ctx: ColumnDecodeContext,
    ) raises -> RecordBatch:
        """`decode_columns_subset` through a caller's reusable context: the
        same batch, with the context's buffers reused."""
        ref meta = self._meta[]
        return self._hint_refined(
            _decode_columns_subset_per_chunk_with_ctx(
                self._file, meta.row_groups[unit_in_file], meta.schema, col_indices, preserve_dict, decode_ctx
            )
        )

    def decode_columns_subset_arena(
        mut self, unit_in_file: Int, col_indices: List[Int], preserve_dict: Bool
    ) raises -> RecordBatch:
        """`decode_columns_subset` through this reader's own context, so its
        decompression scratch (and, with `recycle_codes`, the dictionary codes
        buffer) is reused across the row groups this worker decodes."""
        ref meta = self._meta[]
        return self._hint_refined(
            _decode_columns_subset_per_chunk_with_ctx(
                self._file, meta.row_groups[unit_in_file], meta.schema, col_indices, preserve_dict,
                self._decode_ctx,
            )
        )

    def decode_columns_subset_selected(
        self,
        unit_in_file: Int,
        col_indices: List[Int],
        preserve_dict: Bool,
        mask: BooleanArray,
    ) raises -> Optional[RecordBatch]:
        """`col_indices` for only the rows `mask` keeps, or None when the
        selection gather declines a column (the caller decodes in full and
        gathers)."""
        ref meta = self._meta[]
        var out = decode_columns_subset_selected_per_chunk(
            self._file, meta.row_groups[unit_in_file], meta.schema, col_indices, preserve_dict, mask
        )
        if not out:
            return None
        return Optional[RecordBatch](self._hint_refined(out.take()))

    def fused_dict_count(self, unit_in_file: Int, col_idx: Int, op: UInt8, threshold: Int64) raises -> Optional[Int]:
        """`count(*) WHERE col <op> threshold` for an INT32 / INT64
        dictionary chunk, from its codes and dictionary (no per-row value
        built); None for any other chunk (the caller decodes and evaluates).
        A null row has no code and never satisfies a comparison."""
        ref meta = self._meta[]
        var codes_opt = _decode_numeric_dict_codes_one_col(
            self._file, meta.row_groups[unit_in_file], meta.schema, col_idx
        )
        if not codes_opt:
            return None
        var ndc = codes_opt.take()
        return count_numeric_dict_predicate(ndc.codes, ndc.dict_values, op, threshold)

    def fused_dict_survivors(
        self, unit_in_file: Int, col_idx: Int, op: UInt8, threshold: Int64
    ) raises -> Optional[List[Int]]:
        """The row indices where `col <op> threshold` holds, for an INT32 /
        INT64 dictionary chunk with no null in this row group; None otherwise
        (a null drops out of the codes, so the codes would not be row
        aligned)."""
        ref meta = self._meta[]
        ref rg = meta.row_groups[unit_in_file]
        var codes_opt = _decode_numeric_dict_codes_one_col(self._file, rg, meta.schema, col_idx)
        if not codes_opt:
            return None
        var ndc = codes_opt.take()
        if ndc.codes.length != Int(rg.num_rows):
            return None
        return survivors_numeric_dict_predicate(ndc.codes, ndc.dict_values, op, threshold)

    def decode_rowgroup_codes_feed(
        self, unit_in_file: Int, key_col_indices: List[Int], value_col_indices: List[Int]
    ) raises -> RowGroupCodesFeed:
        """Row group `unit_in_file` as the codes feed of a grouped aggregate
        (`parquet_codes_feed`)."""
        ref meta = self._meta[]
        return decode_rowgroup_codes_feed(
            self._file, meta.row_groups[unit_in_file], meta.schema, key_col_indices, value_col_indices
        )

    def decode_columns_by_name_remap(
        self,
        unit_in_file: Int,
        result_names: List[String],
        result_types: List[ArrowType],
        preserve_dict: Bool,
    ) raises -> RecordBatch:
        """Row group `unit_in_file` in the RESULT schema's column order,
        each result column resolved by name in this file (a column the file
        lacks comes back as typed nulls). When the resolution is the
        identity, a positional decode of every column."""
        ref meta = self._meta[]
        ref rg = meta.row_groups[unit_in_file]
        var remap = _resolve_result_names_to_file_indices(meta, result_names)
        var total_cols = len(rg.columns)
        if _remap_is_positional_identity(remap, total_cols):
            var ident = List[Int](capacity=total_cols)
            for c in range(total_cols):
                ident.append(c)
            return self.decode_columns_subset(unit_in_file, ident, preserve_dict)
        return self._hint_refined(
            _decode_columns_by_name_remap(
                self._file, rg, meta.schema, remap, result_names, result_types, Int(rg.num_rows),
                preserve_dict, self._numeric_dict_vec,
            )
        )

    def decode_for_hash_agg(
        self,
        unit_in_file: Int,
        key_col_idx: Int,
        agg_input_col_indices: List[Int],
        preserve_dict: Bool,
    ) raises -> Optional[ParquetHashAggDecoded]:
        """Row group `unit_in_file` decoded for a single-INT64-key hash
        aggregate, with the key's hashes computed while its bytes are hot;
        None for an empty row group.

        Raises:
            If the key column is not INT64, or a chunk does not decode.
        """
        var col_indices = List[Int]()
        col_indices.append(key_col_idx)
        for i in range(len(agg_input_col_indices)):
            col_indices.append(agg_input_col_indices[i])
        var batch = self.decode_columns_subset(unit_in_file, col_indices^, preserve_dict)
        var num_rows = batch.num_rows()
        if num_rows == 0:
            return None
        var key_array = batch.column_as_primitive_int64(0)
        comptime u64_sz = size_of[UInt64]()
        var hashes = OwnedAlignedBuffer(num_rows * u64_sz)
        hashes.set_length(Int64(num_rows * u64_sz))
        var fingerprints = OwnedAlignedBuffer(num_rows)
        fingerprints.set_length(Int64(num_rows))
        var partition_ids = List[UInt8](capacity=num_rows)
        for r in range(num_rows):
            var h = fib_hash_key(key_array.get_typed[Int64](r))
            hashes.set_typed[UInt64](r, h)
            fingerprints.set_typed[UInt8](r, fingerprint_for_hash(h))
            partition_ids.append(UInt8(partition_for_hash(h)))
        var agg_input_columns = Slab[Column[HeapRegion]].create(len(agg_input_col_indices))
        for i in range(len(agg_input_col_indices)):
            agg_input_columns.append(copy_column_ref(batch.column_at(i + 1), num_rows))
        return Optional[ParquetHashAggDecoded](
            ParquetHashAggDecoded(
                key_array^,
                SharedAlignedBuffer.from_owned(hashes^),
                SharedAlignedBuffer.from_owned(fingerprints^),
                partition_ids^,
                agg_input_columns^,
                num_rows,
            )
        )

    def decode_columns_subset_with_filter(
        mut self,
        unit_in_file: Int,
        col_indices: List[Int],
        preserve_dict: Bool,
        ref filter: Expr,
        allow_partial_prune: Bool = False,
    ) raises -> Optional[RecordBatch]:
        """`decode_columns_subset` after a page-index prune under `filter`
        (`parquet_reader_prune`): None when no row can match; the rows of
        the surviving pages when `allow_partial_prune` and the page indexes
        allow it (the caller's filter is evaluated on them); else every row.
        Set `allow_partial_prune` only when no other column must stay row
        aligned with these."""
        var p = pruned_row_ranges(
            self._page_index_cache, self._file, self._meta[], unit_in_file, filter, col_indices,
            allow_partial_prune,
        )
        if p.empty:
            return None
        if p.partial:
            return Optional[RecordBatch](
                self._hint_refined(
                    decode_ranges(
                        self._page_index_cache, self._file, self._meta[], unit_in_file, col_indices, p.ranges,
                        preserve_dict,
                    )
                )
            )
        return Optional[RecordBatch](self.decode_columns_subset(unit_in_file, col_indices, preserve_dict))

    def decode_filter_and_payload(
        mut self,
        unit_in_file: Int,
        filter_cols: List[Int],
        payload_cols: List[Int],
        preserve_dict: Bool,
        ref filter: Expr,
        allow_partial_prune: Bool = False,
    ) raises -> Optional[FilterPayloadBatches]:
        """The filter columns and the payload columns of row group
        `unit_in_file`, row aligned, from ONE page selection: None when no
        row can match; the surviving pages' rows of both when
        `allow_partial_prune` and the page indexes allow it; else every row.
        An empty `payload_cols` gives a payload batch with no column and the
        filter batch's row count."""
        var all_cols = filter_cols.copy()
        for i in range(len(payload_cols)):
            all_cols.append(payload_cols[i])
        var p = pruned_row_ranges(
            self._page_index_cache, self._file, self._meta[], unit_in_file, filter, all_cols,
            allow_partial_prune,
        )
        if p.empty:
            return None
        var fb: RecordBatch
        var pb: RecordBatch
        if p.partial:
            fb = decode_ranges(
                self._page_index_cache, self._file, self._meta[], unit_in_file, filter_cols, p.ranges,
                preserve_dict,
            )
            if len(payload_cols) == 0:
                pb = RecordBatch.count_only(fb.num_rows())
            else:
                pb = self._hint_refined(
                    decode_ranges(
                        self._page_index_cache, self._file, self._meta[], unit_in_file, payload_cols, p.ranges,
                        preserve_dict,
                    )
                )
        else:
            fb = decode_whole(self._file, self._meta[], unit_in_file, filter_cols, preserve_dict, self._numeric_dict_vec)
            if len(payload_cols) == 0:
                pb = RecordBatch.count_only(fb.num_rows())
            else:
                pb = self.decode_columns_subset(unit_in_file, payload_cols, preserve_dict)
        return Optional[FilterPayloadBatches](FilterPayloadBatches(self._hint_refined(fb^), pb^))

    # -------------------------------------------------------------------------
    # Diagnostics and cold accessors
    # -------------------------------------------------------------------------

    def page_index_cache_size(self) -> Int:
        """Cached (row group, column) page-index entries."""
        return self._page_index_cache.size()

    def page_index_cache_miss_count(self) -> Int:
        """Page-index reads this reader's cache has made."""
        return self._page_index_cache.miss_count()

    def meta_copy(self) -> FileMetaData:
        """A copy of the parsed footer."""
        return self._meta[].copy()

    def file_path(self) -> String:
        """The file's path."""
        return self._file.file_path
