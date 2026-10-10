# =============================================================================
# Selection gather — page collect + one-pass gather along SelectionInterval list
# =============================================================================
#
#   - `decode_column_with_selection` — top-level dispatch: walks the column
#      chunk page-by-page, decompresses ONLY the pages that the page_mask
#      marks as selected, then gathers the selected rows across all pages
#      in a single pass using the sorted (skip, select) interval list.
#   - `_gather_plain_fixed_width` — inner loop for PLAIN fixed-width
#      (Int32/Int64/Float32/Float64). One memcpy per (page, interval) phase.
#
# Handled: flat columns (max_def_level 0 or 1) of INT32, INT64, FLOAT,
# DOUBLE and BYTE_ARRAY whose selected data pages are all PLAIN, or all
# dictionary-encoded, on V1 pages and on V2 pages without level bytes.
# Known limitation: a nullable column's V2 page with no level bytes is
# read as a V1 page (def levels decoded from the front of its values).
# Anything else — nested (max_def_level > 1), FIXED_LEN_BYTE_ARRAY,
# DECIMAL, DELTA_*, BYTE_STREAM_SPLIT, mixed encodings, V2 pages with
# levels, dictionary-encoded pages with `preserve_dict` — returns `None`
# from `decode_column_with_selection`, and the caller must handle that
# `None`.
#
# Design points:
#   * Page-collect-then-gather: decompress every SELECTED page into its OWN
#     buffer up front. The gather pass is a simple walk of sorted
#     intervals. We do NOT re-decompress per interval (quadratic) and we do
#     NOT merge pages into one giant buffer (double memcpy).
#   * Parallel arrays: `_PageExtent` carries `(num_values, encoding)` for
#     each decompressed page buffer, in the SAME order as the
#     `Slab[SharedAlignedBuffer[HeapRegion]]` of decompressed bytes. Index i of one
#     corresponds to index i of the other.
#   * `page_mask[i]` is over ONLY data pages (dictionary page is not counted).
#     When `page_mask[i] == False`, the page is skipped entirely — NEVER
#     decompressed. This is the whole point of this path.
#   * Gather walk iterates the
#     intervals directly; each interval's `skip` moves a row cursor forward,
#     `select` emits that many rows via memcpy from the current page.
#   * Each selected page keeps its own buffer because the gather pass reads
#     from ALL page buffers in interleaved fashion. A single shared buffer
#     would be incorrect (later pages would overwrite earlier ones).
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_collections.slab import Slab
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion

from komira_parquet_api.types import (
    PageType,
    Encoding,
    CompressionCodec,
    ParquetType,
)
from komira_parquet_codec.compression import decompress
from .page_header_parser import _parse_page_header
from .rle import decode_def_levels_u8
from .selection_vector import SelectionInterval

# The common gather types and helpers live in `gather_common.mojo` so
# `gather_byte_array.mojo` and `gather_dict.mojo` can import them without
# a cycle through this module; the tests import `_PageExtent` and
# `_PageDefLevels` from `komira_parquet.gather`.
from .gather_common import (
    _PageExtent,
    _PageDefLevels,
    _build_value_index,
    _check_num_selected,
)
from .decode_helpers import (
    _relabel_int_logical_type,
    _narrow_int_logical_type,
    _relabel_timestamp_logical_type,
    _relabel_byte_array_binary,
)
from .gather_byte_array import (
    _gather_plain_byte_array,
    _gather_plain_byte_array_nullable,
)
from .gather_dict import (
    _gather_dict_encoded,
    _gather_dict_encoded_nullable,
)
from .dictionary import DictionaryDecoder


@no_inline
def _raise_gather_short_walk(
    who: String, written: Int, num_selected: Int
) raises:
    """The intervals asked for rows past the last page."""
    raise Error(
        who
        + ": selection intervals overrun the column's pages: "
        + String(written)
        + " of "
        + String(num_selected)
        + " selected rows exist"
    )


# ---------------------------------------------------------------------------
# _gather_plain_fixed_width — inner gather loop (exposed for unit tests)
# ---------------------------------------------------------------------------


def _gather_plain_fixed_width[
    dtype: DType
](
    page_buffers: Slab[SharedAlignedBuffer[HeapRegion]],
    page_extents: Span[_PageExtent, _],
    intervals: Span[SelectionInterval, _],
    num_selected: Int,
) raises -> PrimitiveArray[dtype]:
    """Gather selected rows across PLAIN fixed-width page buffers.

    One memcpy per (page, interval) phase: the output buffer receives exactly
    `num_selected * elem_size` bytes.

    Parameters:
        dtype: Arrow element type (int32/int64/float32/float64).

    Args:
        page_buffers: Decompressed page buffers, one per SELECTED page, in
            file order. Buffer `i` holds `page_extents[i].num_values` rows
            of PLAIN-encoded `dtype` values (byte-identical to Arrow layout).
        page_extents: Parallel metadata (num_values, encoding) for each
            `page_buffers[i]`. Must have same length as `page_buffers`.
        intervals: Sorted, non-overlapping `(skip, select)` intervals in the
            decoded-pages row coordinate space (i.e. absolute row positions
            within the concatenation of all selected page buffers).
        num_selected: Total selected rows — must equal `sum(i.select for
            i in intervals)`. Used to pre-size the output buffer.

    Returns:
        A non-nullable `PrimitiveArray[dtype]` of length `num_selected`.

    Raises:
        Error if the interval walk would read past a page's end, if
        `page_buffers` / `page_extents` disagree in length, if
        `num_selected` is not the intervals' total, or if the intervals
        select rows past the last page.
    """
    if len(page_buffers) != len(page_extents):
        raise Error(
            "gather: page_buffers and page_extents length mismatch: "
            + String(len(page_buffers))
            + " vs "
            + String(len(page_extents))
        )
    _check_num_selected("gather", intervals, num_selected)

    comptime elem_size = size_of[Scalar[dtype]]()

    # Pre-size output buffer for exactly num_selected values.
    # Dest pointer obtained via origin-tied `view_mut` on
    # the OwnedAlignedBuffer. The view
    # holds the borrow across the interval-walk loop below.
    var out = OwnedAlignedBuffer(max(num_selected * elem_size, 1))
    var out_view = out.view_mut()
    var out_ptr = out_view._unsafe_ptr()
    var out_offset = 0  # bytes written so far

    # Walk interval list. `pos` = absolute row position in decoded-pages
    # coordinate space. `page_idx` advances monotonically.
    var pos: Int = 0
    var page_idx: Int = 0

    # Maintain a running (page_start, page_end) for the current page_idx to
    # avoid recomputing row_cursor every interval. Initialize from page 0.
    var page_start: Int = 0
    var page_end: Int
    if len(page_extents) > 0:
        page_end = page_extents[0].num_values
    else:
        page_end = 0

    for ivl_i in range(len(intervals)):
        ref interval = intervals[ivl_i]
        # Skip phase: advance pos past interval.skip rows.
        pos += Int(interval.skip)

        var remaining_select = Int(interval.select)
        while remaining_select > 0 and page_idx < len(page_extents):
            # Advance page_idx past any fully-skipped pages.
            if pos >= page_end:
                page_idx += 1
                if page_idx >= len(page_extents):
                    break
                page_start = page_end
                page_end = page_start + page_extents[page_idx].num_values
                continue

            var row_in_page = pos - page_start
            var available_in_page = page_end - pos
            var take = (
                remaining_select
                if remaining_select < available_in_page
                else available_in_page
            )

            var byte_start = row_in_page * elem_size
            var byte_end = byte_start + take * elem_size

            # Bounds check: page buffer must hold at least `byte_end` bytes.
            var page_buf_len = page_buffers[page_idx].len()
            if byte_end > page_buf_len:
                raise Error(
                    "gather: interval walk would read past page end "
                    + String(byte_end)
                    + " > "
                    + String(page_buf_len)
                    + " (page "
                    + String(page_idx)
                    + ")"
                )

            # Source via origin-tied `view_range_ro` on the
            # current page buffer (re-derived per iter; @always_inline).
            var src_view = page_buffers[page_idx].view_range_ro(
                byte_start, take * elem_size
            )
            # SAFETY: bounded by take*elem_size; view alive for memcpy.
            unsafe_memcpy(
                dest=out_ptr + out_offset,
                src=src_view._unsafe_ptr(),
                count=take * elem_size,
            )
            out_offset += take * elem_size

            pos += take
            remaining_select -= take

            if pos >= page_end:
                page_idx += 1
                if page_idx < len(page_extents):
                    page_start = page_end
                    page_end = page_start + page_extents[page_idx].num_values

    if out_offset != num_selected * elem_size:
        _raise_gather_short_walk("gather", out_offset // elem_size, num_selected)
    out.set_length(Int64(num_selected * elem_size))

    return PrimitiveArray[dtype](out^, num_selected, None, 0, 0)


# ---------------------------------------------------------------------------
# Dispatcher: ptype -> dtype-parametric gather
# ---------------------------------------------------------------------------


def _gather_plain_fixed_width_dispatch(
    ptype: ParquetType,
    page_buffers: Slab[SharedAlignedBuffer[HeapRegion]],
    page_extents: Span[_PageExtent, _],
    intervals: Span[SelectionInterval, _],
    num_selected: Int,
) raises -> Column[HeapRegion]:
    """Dispatch `_gather_plain_fixed_width` over the four fixed-width Parquet
    physical types and wrap the result in a `Column`.

    Supports: Int32, Int64, Float, Double. FIXED_LEN_BYTE_ARRAY is
    not supported (it needs a `type_length`-parametric copy).
    """
    if ptype == ParquetType.INT32:
        var arr = _gather_plain_fixed_width[DType.int32](
            page_buffers, page_extents, intervals, num_selected,
        )
        return Column.from_primitive[DType.int32](arr)
    elif ptype == ParquetType.INT64:
        var arr = _gather_plain_fixed_width[DType.int64](
            page_buffers, page_extents, intervals, num_selected,
        )
        return Column.from_primitive[DType.int64](arr)
    elif ptype == ParquetType.FLOAT:
        var arr = _gather_plain_fixed_width[DType.float32](
            page_buffers, page_extents, intervals, num_selected,
        )
        return Column.from_primitive[DType.float32](arr)
    elif ptype == ParquetType.DOUBLE:
        var arr = _gather_plain_fixed_width[DType.float64](
            page_buffers, page_extents, intervals, num_selected,
        )
        return Column.from_primitive[DType.float64](arr)
    else:
        raise Error(
            "gather: unsupported fixed-width physical type "
            + String(ptype)
        )


# ---------------------------------------------------------------------------
# _gather_plain_fixed_width_nullable — inner gather for nullable fixed-width
# ---------------------------------------------------------------------------


def _gather_plain_fixed_width_nullable[
    dtype: DType
](
    page_buffers: Slab[SharedAlignedBuffer[HeapRegion]],
    page_extents: Span[_PageExtent, _],
    page_def_levels: Slab[_PageDefLevels],
    intervals: Span[SelectionInterval, _],
    num_selected: Int,
) raises -> PrimitiveArray[dtype]:
    """Gather selected rows across PLAIN fixed-width page buffers with nulls.

    Rank-mapping semantics:
      - page_buffers[i] holds only the `num_non_null` non-null values in
        PLAIN layout (def levels have already been stripped by the top-
        level dispatcher); no null placeholder bytes are present.
      - For each selected row r in a page:
          if def_levels[r] == 0:  emit null (validity bit cleared, output
              bytes remain zero-initialized)
          else:                   val_idx = value_index[r]; copy
              elem_size bytes from `page + val_idx*elem_size` to output.
      - Output validity starts all-valid (1), we clear bits on null.

    Parameters:
        dtype: Arrow element type (int32/int64/float32/float64).

    Args:
        page_buffers: Decompressed & def-level-stripped value streams.
        page_extents: Parallel metadata (num_values, encoding) per page;
            `num_values` includes nulls (= rank table length).
        page_def_levels: Parallel def-level records per page. Must have
            same length as `page_buffers` and `page_extents`.
        intervals: Sorted (skip, select) intervals in the decoded-pages
            row coordinate space.
        num_selected: Total selected rows.

    Returns:
        A `PrimitiveArray[dtype]` of length `num_selected`. It carries a
        validity bitmap only when a selected row is null; otherwise
        validity is None and null_count is 0.

    Raises:
        Error on buffer/extent/def-levels length mismatch or out-of-
        bounds reads past a page's stripped value-stream, when
        `num_selected` is not the intervals' total, when a page carries
        fewer def levels than the rows the walk reads, or when the
        intervals select rows past the last page.
    """
    if len(page_buffers) != len(page_extents):
        raise Error(
            "gather nullable: page_buffers/page_extents length mismatch: "
            + String(len(page_buffers))
            + " vs "
            + String(len(page_extents))
        )
    if len(page_buffers) != len(page_def_levels):
        raise Error(
            "gather nullable: page_buffers/page_def_levels length mismatch: "
            + String(len(page_buffers))
            + " vs "
            + String(len(page_def_levels))
        )
    _check_num_selected("gather nullable", intervals, num_selected)

    comptime elem_size = size_of[Scalar[dtype]]()

    # Pre-size output buffer, zero-initialized so null slots read as 0.
    # Dest pointer obtained via origin-tied `view_mut`.
    var out = OwnedAlignedBuffer(max(num_selected * elem_size, 1))
    out.zero()
    var out_view = out.view_mut()
    var out_ptr = out_view._unsafe_ptr()

    # Validity bitmap: start all-valid, clear bits for null rows.
    var validity = Bitmap.create_all_valid(max(num_selected, 1))
    var null_count: Int = 0
    var has_any_null: Bool = False

    # Build per-page value_index rank tables. List[List[UInt32]] parallels
    # page_buffers / page_extents / page_def_levels.
    var value_indices = List[List[UInt32]]()
    for i in range(len(page_def_levels)):
        ref defs_rec = page_def_levels[i]
        # All-non-null fast path per-page: if num_non_null == num_values,
        # the rank table is just the identity (value_index[r] == r). Skip
        # the allocation and signal via an empty list; the gather loop
        # detects `len(value_index[page_idx]) == 0` and uses `r` directly.
        # This is the `all_non_null` fast path at the page level
        # (when no selected page holds a null, `decode_column_with_selection`
        # takes the non-null `_gather_plain_fixed_width` instead).
        if defs_rec.num_non_null == page_extents[i].num_values:
            value_indices.append(List[UInt32]())
        else:
            value_indices.append(
                _build_value_index(Span(defs_rec.defs))
            )

    # Walk interval list. `pos` = absolute row position in decoded-pages
    # coordinate space (same as non-nullable gather).
    var pos: Int = 0
    var page_idx: Int = 0
    var out_pos: Int = 0  # number of rows written to output so far

    var page_start: Int = 0
    var page_end: Int
    if len(page_extents) > 0:
        page_end = page_extents[0].num_values
    else:
        page_end = 0

    for ivl_i in range(len(intervals)):
        ref interval = intervals[ivl_i]
        pos += Int(interval.skip)

        var remaining_select = Int(interval.select)
        while remaining_select > 0 and page_idx < len(page_extents):
            if pos >= page_end:
                page_idx += 1
                if page_idx >= len(page_extents):
                    break
                page_start = page_end
                page_end = page_start + page_extents[page_idx].num_values
                continue

            var row_in_page = pos - page_start
            var available_in_page = page_end - pos
            var take = (
                remaining_select
                if remaining_select < available_in_page
                else available_in_page
            )

            ref defs_rec = page_def_levels[page_idx]
            if row_in_page + take > len(defs_rec.defs):
                raise Error(
                    "gather nullable: page "
                    + String(page_idx)
                    + " carries "
                    + String(len(defs_rec.defs))
                    + " def levels, the walk needs row "
                    + String(row_in_page + take - 1)
                )
            ref vidx = value_indices[page_idx]
            var vidx_empty = len(vidx) == 0  # page-level all-non-null fast path
            var page_buf_len = page_buffers[page_idx].len()
            # Source via origin-tied view on the page buffer.
            var page_view = page_buffers[page_idx].view_ro()
            var page_ptr = page_view._unsafe_ptr()

            # NOT-VECTORIZABLE: Per-row def-level check + fixed elem_size memcpy +
            # value-index indirection. Could SIMD the def-level comparison to build
            # a selection bitmap, but the gather body is too complex for SIMD.
            for r in range(row_in_page, row_in_page + take):
                if defs_rec.defs[r] != 0:
                    # Non-null: resolve value index and memcpy elem_size bytes.
                    var val_idx: Int
                    if vidx_empty:
                        val_idx = r
                    else:
                        val_idx = Int(vidx[r])
                    var byte_start = val_idx * elem_size
                    var byte_end = byte_start + elem_size
                    if byte_end > page_buf_len:
                        raise Error(
                            "gather nullable: value stream read OOB "
                            + String(byte_end)
                            + " > "
                            + String(page_buf_len)
                            + " (page "
                            + String(page_idx)
                            + ")"
                        )
                    unsafe_memcpy(
                        dest=out_ptr + out_pos * elem_size,
                        src=page_ptr + byte_start,
                        count=elem_size,
                    )
                    # validity bit already set to 1 by create_all_valid.
                else:
                    # Null row: out bytes already zero; clear validity bit.
                    validity.clear(out_pos)
                    null_count += 1
                    has_any_null = True
                out_pos += 1

            pos += take
            remaining_select -= take

            if pos >= page_end:
                page_idx += 1
                if page_idx < len(page_extents):
                    page_start = page_end
                    page_end = page_start + page_extents[page_idx].num_values

    if out_pos != num_selected:
        _raise_gather_short_walk("gather nullable", out_pos, num_selected)
    out.set_length(Int64(num_selected * elem_size))


    # If no nulls were emitted, drop the validity buffer per Arrow
    # convention (null_count==0 + validity=None is the standard
    # non-nullable shape).
    if has_any_null:
        return PrimitiveArray[dtype](out^, num_selected, validity^, null_count, 0)
    else:
        _ = validity^
        return PrimitiveArray[dtype](out^, num_selected, None, 0, 0)


def _gather_plain_fixed_width_nullable_dispatch(
    ptype: ParquetType,
    page_buffers: Slab[SharedAlignedBuffer[HeapRegion]],
    page_extents: Span[_PageExtent, _],
    page_def_levels: Slab[_PageDefLevels],
    intervals: Span[SelectionInterval, _],
    num_selected: Int,
) raises -> Column[HeapRegion]:
    """Nullable-variant ptype dispatcher — mirrors the non-null sibling."""
    if ptype == ParquetType.INT32:
        var arr = _gather_plain_fixed_width_nullable[DType.int32](
            page_buffers, page_extents, page_def_levels, intervals, num_selected,
        )
        return Column.from_primitive[DType.int32](arr)
    elif ptype == ParquetType.INT64:
        var arr = _gather_plain_fixed_width_nullable[DType.int64](
            page_buffers, page_extents, page_def_levels, intervals, num_selected,
        )
        return Column.from_primitive[DType.int64](arr)
    elif ptype == ParquetType.FLOAT:
        var arr = _gather_plain_fixed_width_nullable[DType.float32](
            page_buffers, page_extents, page_def_levels, intervals, num_selected,
        )
        return Column.from_primitive[DType.float32](arr)
    elif ptype == ParquetType.DOUBLE:
        var arr = _gather_plain_fixed_width_nullable[DType.float64](
            page_buffers, page_extents, page_def_levels, intervals, num_selected,
        )
        return Column.from_primitive[DType.float64](arr)
    else:
        raise Error(
            "gather nullable: unsupported fixed-width physical type "
            + String(ptype)
        )


# ---------------------------------------------------------------------------
# decode_column_with_selection — top-level dispatch
# ---------------------------------------------------------------------------


def decode_column_with_selection[
    data_origin: MutOrigin
](
    data: Span[UInt8, data_origin],
    ptype: ParquetType,
    codec: CompressionCodec,
    num_values_in_selected_pages: Int,
    max_def_level: Int,
    type_length: Int,
    converted_type: Int,
    scale: Int,
    preserve_dict: Bool,
    page_mask: Span[Bool, _],
    selection_intervals: Span[SelectionInterval, _],
    num_selected: Int,
    timestamp_unit: Int = -1,
) raises -> Optional[Column[HeapRegion]]:
    """Decode a column chunk with page-level skip + row-level gather.

    Walks the column chunk page-by-page. A DICTIONARY_PAGE loads the
    `DictionaryDecoder` that later PLAIN_DICTIONARY / RLE_DICTIONARY data
    pages resolve against.

    For each DATA_PAGE / DATA_PAGE_V2:
      - If `page_mask[data_page_idx]` is False, skip decompression entirely.
      - Otherwise, decompress the full page into its own buffer,
        record its num_values + encoding in a parallel `_PageExtent` list.
        A V2 page whose header says its values are not compressed is
        copied, whatever the column's codec.

    After the collect pass, the selected pages go to the gather for their
    shape: PLAIN fixed-width, PLAIN BYTE_ARRAY or dictionary-encoded,
    non-null or nullable (a nullable column whose selected pages hold no
    null takes the non-null gather). Any other shape, and some malformed
    chunks, return None, which the caller must handle.

    Args:
        data: Column chunk bytes (the pages, each a Thrift page header and
            its body). Borrowed `Span` whose origin ties the bytes'
            lifetime to the caller's backing buffer.
        ptype: Parquet physical type.
        codec: Compression codec for the column chunk.
        num_values_in_selected_pages: Total value count across only the pages
            that `page_mask` marks True.
        max_def_level: 0 for flat non-null columns, 1 for flat nullable,
            >1 for nested (returns None).
        type_length: FIXED_LEN_BYTE_ARRAY width (unused: FLBA returns None).
        converted_type: The Thrift ConvertedType: DECIMAL returns None; the
            integer, date and BYTE_ARRAY annotations re-stamp the result's
            Arrow type.
        scale: DECIMAL scale (unused: DECIMAL returns None).
        preserve_dict: Whether to preserve dictionary encoding in output
            (dict-encoded pages with True return None).
        page_mask: Per-DATA-page include decision. Length == number of data
            pages in the column chunk (NOT including the dictionary page).
        selection_intervals: Sorted (skip, select) intervals in the
            decoded-pages coordinate space.
        num_selected: Sum of `select` across `selection_intervals`.
        timestamp_unit: The LogicalType TIMESTAMP unit of an INT64 column,
            or -1 for none.

    Returns:
        `Some(Column)` if the gather handled the decode entirely; `None`
        for a shape it does not gather or a malformed chunk it does not
        decode (the caller must decode that chunk some other way).

    Raises:
        Error from the page header parser, the codec and the dictionary
        decoder on a malformed page, and from the gathers (see each).
    """
    var data_len = len(data)
    if max_def_level > 1:
        return None  # Nested schema — not handled here.
    var nullable = max_def_level > 0  # Flat nullable is handled.
    # BYTE_ARRAY (variable-width) routes to the ByteArray
    # gather. FIXED_LEN_BYTE_ARRAY is not handled (needs type_length-
    # parametric copy and would emit a FixedSizeBinary, not a String).
    var is_byte_array = (ptype == ParquetType.BYTE_ARRAY)
    if ptype == ParquetType.FIXED_LEN_BYTE_ARRAY:
        return None  # Not handled: needs type_length-parametric copy.
    # DECIMAL-annotated columns (INT32/INT64-backed) must surface as
    # Decimal128, which the selection gather does not produce,
    # so they return None.
    # CONVERTED_TYPE_DECIMAL == 5 (Parquet Thrift ConvertedType).
    if converted_type == 5:
        return None
    # Only Int32 / Int64 / Float / Double / BYTE_ARRAY are gathered.
    if not (
        ptype == ParquetType.INT32
        or ptype == ParquetType.INT64
        or ptype == ParquetType.FLOAT
        or ptype == ParquetType.DOUBLE
        or is_byte_array
    ):
        return None

    # `type_length` and `scale` are unused (FIXED_LEN_BYTE_ARRAY and
    # DECIMAL return None above); `preserve_dict` is read below.
    # `converted_type` is consumed by the DECIMAL check above and by
    # `_relabel_gathered` at every return.
    _ = type_length
    _ = scale
    _ = preserve_dict

    var page_buffers = Slab[SharedAlignedBuffer[HeapRegion]]()
    var page_extents = List[_PageExtent]()
    # Parallel to page_buffers/page_extents for nullable columns. Empty
    # when !nullable (non-null path does not need def levels).
    # `Slab` because `_PageDefLevels` is Movable-only (owns a
    # `List[UInt8]` of arbitrary size — we don't want it Copyable to
    # avoid silent O(n) bitmap clones).
    var page_def_levels = Slab[_PageDefLevels]()
    # Whole-column optimization flag (`all_non_null`):
    # if nullable but every page has all non-null
    # rows, the value stream has a 1:1 row-to-value mapping — take
    # the non-null gather directly and emit a non-nullable Column.
    var all_non_null: Bool = True

    var offset: Int = 0
    var data_page_idx: Int = 0
    var total_collected: Int = 0

    # Dictionary-encoded path. We init a DictionaryDecoder lazily
    # when we encounter the DICTIONARY_PAGE; its `dict_values_*` Optional
    # fields tell us at gather time which physical-type arm was loaded.
    # If a dict-encoded data page is seen WITHOUT a preceding dict page,
    # that's a malformed column chunk — return None.
    var dict_decoder = DictionaryDecoder()
    var has_dict: Bool = False

    while offset < data_len and total_collected < num_values_in_selected_pages:
        # Parse Thrift page header.
        var hdr_result = _parse_page_header(data[offset:])
        offset += hdr_result.bytes_consumed

        ref hdr = hdr_result.header
        # The page header parser refuses a negative page size or value
        # count, so neither is checked again here.
        var compressed_size = hdr.compressed_page_size
        if compressed_size > data_len - offset:
            return None

        if hdr.type == PageType.DICTIONARY_PAGE:
            # Decompress the dict page into its OWN buffer and
            # initialize the DictionaryDecoder for the column's ptype. The
            # decoder copies values out of `dict_buf` (init_dict_* memcpys
            # for fixed-width, length-prefixed walk for BYTE_ARRAY), so
            # `dict_buf` can be reclaimed at the end of this branch.
            var dict_page_data = data[offset : offset + compressed_size]
            var dict_uncompressed = hdr.uncompressed_page_size
            var dict_buf: OwnedAlignedBuffer
            if codec == CompressionCodec.UNCOMPRESSED:
                dict_buf = OwnedAlignedBuffer(max(compressed_size, 1))
                if compressed_size > 0:
                    # Dest via origin-tied `view_range_mut`.
                    var dst_view = dict_buf.view_range_mut(0, compressed_size)
                    # SAFETY: both ranges hold `compressed_size` bytes.
                    unsafe_memcpy(
                        dest=dst_view._unsafe_ptr(),
                        src=dict_page_data.unsafe_ptr(),
                        count=compressed_size,
                    )
                dict_buf.set_length(Int64(compressed_size))

            else:
                dict_buf = OwnedAlignedBuffer(max(dict_uncompressed, 1))
                # The output is a span over the origin-tied `view_mut()`,
                # cut to the page's uncompressed size. NLL releases the
                # &mut borrow at the `decompress` call's last use before the
                # trailing `dict_buf.set_length(dwritten)` &mut call.
                var dst_view = dict_buf.view_mut()
                var dwritten = decompress(
                    codec,
                    dict_page_data,
                    dst_view.into_span()[:dict_uncompressed],
                )
                dict_buf.set_length(Int64(dwritten))


            var dict_num_values = hdr.num_values
            # A fixed-width dictionary page that declares more values than
            # its decoded bytes hold is corrupt: return None. The resulting
            # `dict_size` would be the bound that `gather_dict.mojo`'s
            # `idx < dict_size` check trusts. Checked once per dictionary
            # page.
            var _dict_decoded_len = dict_buf.len()
            var _dict_width = 0
            if ptype == ParquetType.INT32 or ptype == ParquetType.FLOAT:
                _dict_width = 4
            elif ptype == ParquetType.INT64 or ptype == ParquetType.DOUBLE:
                _dict_width = 8
            if (
                _dict_width > 0
                and dict_num_values * _dict_width > _dict_decoded_len
            ):
                _ = dict_buf^
                return None  # Corrupt dictionary page.
            # Dict-init source: a span over the origin-tied `view_ro`,
            # `_dict_decoded_len` bytes long.
            var dict_bytes = dict_buf.view_ro().into_span()
            if ptype == ParquetType.INT32:
                dict_decoder.init_dict_int32(dict_bytes, dict_num_values)
            elif ptype == ParquetType.INT64:
                dict_decoder.init_dict_int64(dict_bytes, dict_num_values)
            elif ptype == ParquetType.FLOAT:
                dict_decoder.init_dict_float32(dict_bytes, dict_num_values)
            elif ptype == ParquetType.DOUBLE:
                dict_decoder.init_dict_float64(dict_bytes, dict_num_values)
            else:
                # BYTE_ARRAY: the only type left after the gate above.
                dict_decoder.init_dict_byte_array(dict_bytes, dict_num_values)
            has_dict = True
            _ = dict_buf^  # decoder has copied its values out
            offset += compressed_size

        elif (
            hdr.type == PageType.DATA_PAGE
            or hdr.type == PageType.DATA_PAGE_V2
        ):
            var page_data = data[offset : offset + compressed_size]
            var should_decode = (
                data_page_idx < len(page_mask)
                and page_mask[data_page_idx]
            )
            data_page_idx += 1

            if not should_decode:
                offset += compressed_size
                continue

            var page_num_values = hdr.num_values
            var page_encoding = hdr.encoding

            # PLAIN, PLAIN_DICTIONARY and
            # RLE_DICTIONARY (resolved via the DictionaryDecoder loaded from
            # the DICTIONARY_PAGE) are handled. Anything else (DELTA_*,
            # BYTE_STREAM_SPLIT) returns None.
            var is_dict_encoded = (
                page_encoding == Encoding.PLAIN_DICTIONARY
                or page_encoding == Encoding.RLE_DICTIONARY
            )
            if page_encoding != Encoding.PLAIN and not is_dict_encoded:
                return None
            if is_dict_encoded and not has_dict:
                # Dict-encoded data page without a preceding dict page —
                # malformed column chunk; return None.
                return None

            # V2 pages carry uncompressed rep/def levels BEFORE the values.
            # V2-with-levels is not handled (needs separate
            # decompression scope for the values region): return None.
            # V1 nullable carries def levels at the FRONT of the
            # decompressed page; strip them after decompression.
            var rep_levels_len = 0
            var def_levels_len = 0
            if hdr.type == PageType.DATA_PAGE_V2:
                rep_levels_len = hdr.rep_levels_byte_length
                def_levels_len = hdr.def_levels_byte_length
                # Reject V2 with ANY level bytes. Known limitation: a
                # nullable column's V2 page with none is read as a V1 page.
                if rep_levels_len != 0 or def_levels_len != 0:
                    return None

            # Decompress the page into its own OwnedAlignedBuffer.
            # SAFETY: each decompressed buffer is owned by page_buffers and
            # lives until the gather pass completes (function return).
            var uncompressed_size = hdr.uncompressed_page_size
            var page_buf: OwnedAlignedBuffer
            # A V2 page says in its header whether its values are
            # compressed (parquet.thrift DataPageHeaderV2.is_compressed);
            # one that is not is copied, whatever the column's codec.
            if codec == CompressionCodec.UNCOMPRESSED or (
                hdr.type == PageType.DATA_PAGE_V2 and not hdr.is_compressed
            ):
                page_buf = OwnedAlignedBuffer(max(compressed_size, 1))
                if compressed_size > 0:
                    # Dest via origin-tied `view_range_mut`.
                    var dst_view = page_buf.view_range_mut(0, compressed_size)
                    # SAFETY: both ranges hold `compressed_size` bytes.
                    unsafe_memcpy(
                        dest=dst_view._unsafe_ptr(),
                        src=page_data.unsafe_ptr(),
                        count=compressed_size,
                    )
                page_buf.set_length(Int64(compressed_size))

            else:
                page_buf = OwnedAlignedBuffer(max(uncompressed_size, 1))
                # The output is a span over the origin-tied `view_mut()`,
                # cut to the page's uncompressed size. NLL releases the
                # &mut borrow at the `decompress` call's last use before the
                # trailing `page_buf.set_length(written)` &mut call.
                var pg_view = page_buf.view_mut()
                var written = decompress(
                    codec,
                    page_data,
                    pg_view.into_span()[:uncompressed_size],
                )
                page_buf.set_length(Int64(written))


            # Nullable (V1, level-free V2): decode def levels from the front of the
            # decompressed page, then strip them so the stored page buffer
            # holds ONLY the PLAIN value stream (one elem_size-sized
            # record per non-null row).
            if nullable:
                # Parse the 4-byte LE length prefix to compute how many
                # bytes the def-level section occupies.
                var pb_len = page_buf.len()
                if pb_len < 4:
                    return None  # Malformed nullable page.
                # Read the length prefix through a span over the
                # origin-tied `view_ro`; the span holds the borrow across
                # the def-level decode.
                var pb = page_buf.view_ro().into_span()
                var encoded_len = (
                    Int(pb[0])
                    | (Int(pb[1]) << 8)
                    | (Int(pb[2]) << 16)
                    | (Int(pb[3]) << 24)
                )
                # Four bytes read as unsigned, so `consumed` is at least 4.
                var consumed = 4 + encoded_len
                if consumed > pb_len:
                    return None

                # Decode def levels to u8 (length == page_num_values).
                var defs = decode_def_levels_u8(pb, page_num_values)

                var num_non_null = 0
                for i in range(len(defs)):
                    if defs[i] != 0:
                        num_non_null += 1
                if num_non_null != page_num_values:
                    all_non_null = False

                # Strip def levels — as a WINDOW SHARE, not a copy.
                #
                # `SharedAlignedBuffer.share_range_as` returns a buffer that
                # IS the sub-window (`len() == values_len`, `_ptr` already
                # advanced), so every consumer keeps reading from offset 0
                # and every `page_buf_len` bound stays correct. Refcount++ on
                # the region pins the decompressed page; no byte moves.
                #
                # ⚠ The window starts at `4 + encoded_len`, an ARBITRARY byte
                # offset, so the returned buffer is NOT 64-byte aligned. Every
                # consumer of `page_buffers` reads it through `view_ro` /
                # `view_range_ro` + `memcpy` at byte offsets — alignment-
                # agnostic by construction. Do not add an aligned SIMD load over
                # a page buffer without re-checking this.
                var values_len = pb_len - consumed
                var page_shared = SharedAlignedBuffer.from_owned(page_buf^)
                page_buffers.append(
                    page_shared.share_range_as[HeapRegion](
                        consumed, values_len
                    )
                )
                # The window share holds the region alive; this local drop is
                # a refcount--, not a free.
                _ = page_shared^
                page_def_levels.append(_PageDefLevels(defs^, num_non_null))
            else:
                page_buffers.append(SharedAlignedBuffer.from_owned(page_buf^))

            page_extents.append(_PageExtent(page_num_values, page_encoding))
            total_collected += page_num_values
            offset += compressed_size

        else:
            # INDEX_PAGE or future page type — skip without advancing
            # data_page_idx (not a data page).
            offset += compressed_size

    # If the page walk yielded no selected pages but num_selected > 0, the
    # caller's invariants are violated — return None rather than produce
    # garbage.
    if num_selected > 0 and len(page_buffers) == 0:
        return None

    # Mixed encodings across selected pages (e.g. one PLAIN + one
    # RLE_DICTIONARY) — return None (the `all_same_encoding` guard).
    var first_encoding = page_extents[0].encoding if len(page_extents) > 0 else Encoding.PLAIN
    var all_same_encoding = True
    for i in range(1, len(page_extents)):
        if page_extents[i].encoding != first_encoding:
            all_same_encoding = False
            break
    if not all_same_encoding:
        return None

    var is_dict = (
        first_encoding == Encoding.PLAIN_DICTIONARY
        or first_encoding == Encoding.RLE_DICTIONARY
    )
    # The dict gather only handles `preserve_dict=False` (resolve
    # to flat values). The `preserve_dict=True` keys-only DictionaryArray
    # passthrough is not handled — return None.
    if is_dict and preserve_dict:
        return None

    # Fast path: nullable but NO actual nulls exist.
    # Row-to-value mapping is 1:1, identical to non-nullable
    # (the `!nullable || all_non_null` branch).
    if (not nullable) or all_non_null:
        if is_dict:
            var col = _gather_dict_encoded(
                ptype,
                dict_decoder,
                page_buffers,
                Span(page_extents),
                selection_intervals,
                num_selected,
                preserve_dict,
            )
            return Optional[Column[HeapRegion]](
                _relabel_gathered(col^, ptype, converted_type, timestamp_unit)
            )
        if is_byte_array:
            var col = _gather_plain_byte_array(
                page_buffers,
                Span(page_extents),
                selection_intervals,
                num_selected,
            )
            return Optional[Column[HeapRegion]](
                _relabel_gathered(col^, ptype, converted_type, timestamp_unit)
            )
        var col = _gather_plain_fixed_width_dispatch(
            ptype,
            page_buffers,
            Span(page_extents),
            selection_intervals,
            num_selected,
        )
        return Optional[Column[HeapRegion]](
            _relabel_gathered(col^, ptype, converted_type, timestamp_unit)
        )

    # Slow path: nullable with actual nulls — use rank-mapping gather.
    if is_dict:
        var col = _gather_dict_encoded_nullable(
            ptype,
            dict_decoder,
            page_buffers,
            Span(page_extents),
            page_def_levels,
            selection_intervals,
            num_selected,
            preserve_dict,
        )
        return Optional[Column[HeapRegion]](
            _relabel_gathered(col^, ptype, converted_type, timestamp_unit)
        )
    if is_byte_array:
        var col = _gather_plain_byte_array_nullable(
            page_buffers,
            Span(page_extents),
            page_def_levels,
            selection_intervals,
            num_selected,
        )
        return Optional[Column[HeapRegion]](
            _relabel_gathered(col^, ptype, converted_type, timestamp_unit)
        )
    var col = _gather_plain_fixed_width_nullable_dispatch(
        ptype,
        page_buffers,
        Span(page_extents),
        page_def_levels,
        selection_intervals,
        num_selected,
    )
    return Optional[Column[HeapRegion]](
        _relabel_gathered(col^, ptype, converted_type, timestamp_unit)
    )


def _relabel_gathered(
    var col: Column[HeapRegion],
    ptype: ParquetType,
    converted_type: Int,
    timestamp_unit: Int,
) raises -> Column[HeapRegion]:
    """Re-stamp a gathered column's Arrow type from its annotations.

    Every gather builds the bare physical Arrow type (signed INT32/INT64,
    FLOAT, DOUBLE, STRING); a dictionary-encoded column gathers to the same
    types as a PLAIN one. Each step below fires only on its physical type
    and the bare tag, so the chain is applied to every gathered column:
      - UINT_32 / UINT_64 / DATE re-stamp the same-width type, so a
        FILTERED unsigned column is not silently sign-corrupted;
      - INT_8 / INT_16 / UINT_8 / UINT_16 narrow an INT32 column;
      - a LogicalType TIMESTAMP INT64 column becomes the unit-correct
        Arrow type;
      - an UNANNOTATED BYTE_ARRAY is raw BINARY, not text. Pure tag swap;
        same buffers.
    """
    var rl = _relabel_int_logical_type(col^, ptype, converted_type)
    var nr = _narrow_int_logical_type(rl^, ptype, converted_type)
    var ts_g = _relabel_timestamp_logical_type(nr^, ptype, timestamp_unit)
    return _relabel_byte_array_binary(ts_g^, ptype, converted_type)
