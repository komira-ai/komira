# =============================================================================
# Selection gather — dict-encoded (PLAIN_DICTIONARY / RLE_DICTIONARY) variants
# =============================================================================
#
#   * `_gather_dict_encoded`           — non-null
#   * `_gather_dict_encoded_nullable`  — nullable
#
# Dict-encoded data pages carry RLE/bit-pack-hybrid INT32 indices into the
# DICTIONARY_PAGE values. The caller decompresses the dict page once and
# initializes a `DictionaryDecoder`; data pages are then decompressed in file
# order. This file provides the gather pass that, for each selected interval,
# resolves each row's dict index to the matching value. Only
# `preserve_dict=False` is supported (a keys-only DictionaryArray passthrough
# is refused).
#
# Reuses existing infrastructure — does NOT re-implement RLE:
#   - `DictionaryDecoder.decode_indices_into` — RLE -> Int32 buffer (one
#     byte bit_width prefix + bit-packed groups).
#   - `_build_value_index` from `gather_common` — exclusive rank table for
#     def-level rank-mapping (nullable path).
#
# Shape:
#   * We return `Column` directly; a dispatcher that may decline wraps it in
#     `Optional[Column]`.
#   * We accept a `ref DictionaryDecoder` (already initialized for the
#     column's physical type) and dispatch on `ParquetType` like our other
#     gather sites.
#   * For BYTE_ARRAY we use `dict.dict_values_bytes` directly (StringArray
#     of unique values) and emit a flat StringArray with our own
#     length-prefixed offsets buffer (matches `_gather_plain_byte_array`).
#
# SAFETY: all `page_buffers` AlignedBuffers must outlive this call. The dict
# decoder owns the dict values (cloned out of its own decompress buffer at
# `init_dict_*` time), so the dict page bytes can be reclaimed before the
# gather. Each per-page key buffer is allocated via `OwnedAlignedBuffer`
# and released on function return.
# =============================================================================

from std.memory import unsafe_memcpy
from std.sys import size_of

from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.aligned_buffer_trait import AlignedBufferTrait
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab

from .dictionary import DictionaryDecoder
from .gather_common import (
    _PageExtent,
    _PageDefLevels,
    _build_value_index,
    _check_num_selected,
)
from .selection_vector import SelectionInterval
from komira_parquet_api.types import ParquetType


# ---------------------------------------------------------------------------
# _PageDictKeys — per-page decoded-Int32-index slab (parallel to page_buffers)
# ---------------------------------------------------------------------------


@fieldwise_init
struct _PageDictKeys(Movable):
    """Decoded dictionary indices for one data page.

    Fields:
        keys: Owned Int32 buffer of length == page_num_values (non-null path)
            or == num_non_null (nullable path). Each entry is an index into
            the column's dictionary.
        length: Number of valid Int32 entries in `keys`.
    """

    var keys: OwnedAlignedBuffer
    var length: Int


@no_inline
def _raise_gather_dict_short_walk(written: Int, num_selected: Int) raises:
    """The intervals asked for rows past the last page."""
    raise Error(
        "gather dict: selection intervals overrun the column's pages: "
        + String(written)
        + " of "
        + String(num_selected)
        + " selected rows exist"
    )


def _decode_page_keys[
    B_page: AlignedBufferTrait,
](
    dict: DictionaryDecoder,
    page_buf: B_page,
    num_keys: Int,
) raises -> _PageDictKeys:
    """Decode one data page's RLE/bit-pack hybrid dict indices into Int32.

    Wraps `DictionaryDecoder.decode_indices_into` with output-buffer
    allocation. `num_keys` must equal the count of indices actually present
    on the wire (page.num_values for non-null pages; num_non_null for
    nullable pages, since the key stream skips null rows).
    """
    if num_keys < 0:
        raise Error(
            "gather dict: a page declares a negative value count "
            + String(num_keys)
        )
    comptime int32_size = size_of[Scalar[DType.int32]]()
    var buf = OwnedAlignedBuffer(max(num_keys * int32_size, 1))
    if num_keys > 0:
        # The page is read through its origin-tied `view_ro` span, the keys
        # are written through a span over the origin-tied `view_mut`; both
        # views live across the call.
        var buf_view = buf.view_mut()
        var page_view = page_buf.view_ro()
        # SAFETY: `buf` holds at least `num_keys * 4` bytes (allocated just
        # above); `buf_view` keeps it borrowed for the call.
        var dest = Span[Int32, buf_view.origin](
            unsafe_ptr=buf_view._unsafe_ptr().bitcast[Int32](),
            length=num_keys,
        )
        dict.decode_indices_into(page_view.into_span(), num_keys, dest)
    buf.set_length(Int64(num_keys * int32_size))

    return _PageDictKeys(buf^, num_keys)


# ---------------------------------------------------------------------------
# Materialize-by-dict-lookup helpers, parametric over fixed-width DType
# ---------------------------------------------------------------------------


def _materialize_fixed_width[
    dtype: DType,
    B_keys: AlignedBufferTrait,
    B_dict: AlignedBufferTrait,
](
    var selected_keys: B_keys,
    num_selected: Int,
    dict_buf: B_dict,
    dict_size: Int,
    var validity: Optional[Bitmap[HeapRegion]],
    null_count: Int,
) raises -> PrimitiveArray[dtype]:
    """Look up `selected_keys[i]` in the dict and copy the value into output.

    Out-of-range keys produce 0.

    Args:
        dict_buf: Buffer holding the dictionary values (tightly
            packed Scalar[dtype] entries). Borrowed immutably across the
            gather; compiler tracks liveness against the enclosing
            DictionaryDecoder.
    """
    comptime elem_size = size_of[Scalar[dtype]]()
    var out = OwnedAlignedBuffer(max(num_selected * elem_size, 1))
    # The output is written via `set_typed[Scalar[dtype]]`; keys are read
    # via `get_typed[Int32]` on the origin-tied selected_keys view.
    var keys_view = selected_keys.view_ro()
    for i in range(num_selected):
        var idx = Int(keys_view.get_typed[Int32](i))
        if 0 <= idx and idx < dict_size:
            # SAFETY: idx is bounds-checked against `dict_size` and the dict
            # buffer is sized to hold `dict_size` Scalar[dtype] entries.
            out.set_typed[Scalar[dtype]](
                i, dict_buf.get_typed[Scalar[dtype]](idx)
            )
        else:
            out.set_typed[Scalar[dtype]](i, Scalar[dtype](0))
    out.set_length(Int64(num_selected * elem_size))

    return PrimitiveArray[dtype](out^, num_selected, validity^, null_count, 0)


def _materialize_byte_array[
    B_keys: AlignedBufferTrait,
](
    var selected_keys: B_keys,
    num_selected: Int,
    dict_strings: StringArray[HeapRegion],
    var validity: Optional[Bitmap[HeapRegion]],
    null_count: Int,
) raises -> StringArray[HeapRegion]:
    """Look up each key in the BYTE_ARRAY dict and concatenate value bytes.

    Builds offsets[num_selected+1] and a flat data buffer holding the
    concatenation of dict values. Out-of-range keys produce an empty value.

    Raises:
        Error if the selected values' bytes pass the Int32 offset limit; the
        sum is checked before the data buffer is allocated.
    """
    comptime int32_size = size_of[Int32]()
    var offsets_buf = OwnedAlignedBuffer(
        max((num_selected + 1) * int32_size, 1)
    )
    # Writers via origin-tied views.
    var offsets_view = offsets_buf.view_mut()
    var offsets_ptr = offsets_view._unsafe_ptr().bitcast[Int32]()
    offsets_ptr[0] = Int32(0)

    var dict_size = dict_strings.length
    var dict_offsets_view = dict_strings.offsets.view_ro()
    var dict_data_view = dict_strings.data.view_ro()
    var dict_offsets_ptr = (
        dict_offsets_view._unsafe_ptr().bitcast[Int32]()
    )
    var dict_data_ptr = dict_data_view._unsafe_ptr()

    # First pass: compute total bytes so we can size the data buffer once.
    var keys_view = selected_keys.view_ro()
    var keys_ptr = keys_view._unsafe_ptr().bitcast[Int32]()
    var total_bytes = 0
    for i in range(num_selected):
        var idx = Int(keys_ptr[i])
        if 0 <= idx and idx < dict_size:
            var s = Int(dict_offsets_ptr[idx])
            var e = Int(dict_offsets_ptr[idx + 1])
            total_bytes += (e - s)
    if total_bytes > Int(Int32.MAX):
        raise Error(
            "gather dict: selected values total "
            + String(total_bytes)
            + " bytes, past the Int32 StringArray offset limit"
        )

    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    var data_dest_view = data_buf.view_range_mut(0, max(total_bytes, 1))
    var data_dest = data_dest_view._unsafe_ptr()
    var current_offset: Int32 = 0
    for i in range(num_selected):
        var idx = Int(keys_ptr[i])
        if 0 <= idx and idx < dict_size:
            var s = Int(dict_offsets_ptr[idx])
            var e = Int(dict_offsets_ptr[idx + 1])
            var n = e - s
            if n > 0:
                unsafe_memcpy(
                    dest=data_dest + Int(current_offset),
                    src=dict_data_ptr + s,
                    count=n,
                )
            current_offset += Int32(n)
        # else: empty value, no copy; offset unchanged.
        offsets_ptr[i + 1] = current_offset

    offsets_buf.set_length(Int64((num_selected + 1) * int32_size))

    data_buf.set_length(Int64(total_bytes))


    return StringArray[HeapRegion](
        offsets=offsets_buf^,
        data=data_buf^,
        validity=validity^,
        length=num_selected,
        data_length=total_bytes,
        null_count=null_count,
    )


# ---------------------------------------------------------------------------
# _gather_dict_encoded — non-null variant
# ---------------------------------------------------------------------------


def _gather_dict_encoded(
    ptype: ParquetType,
    dict: DictionaryDecoder,
    page_buffers: Slab[SharedAlignedBuffer[HeapRegion]],
    page_extents: Span[_PageExtent, _],
    intervals: Span[SelectionInterval, _],
    num_selected: Int,
    preserve_dict: Bool,
) raises -> Column[HeapRegion]:
    """Gather selected rows across dict-encoded pages (non-null).

    Three steps: per-page RLE-decode of the full key stream, then
    interval-walk emitting selected keys, then dict lookup to materialize
    values.

    Only `preserve_dict=False` (resolve to flat values) is supported. The
    `preserve_dict=True` path (StringDictionaryArray passthrough for keys)
    raises Error — callers must pass False.

    Raises:
        Error on `preserve_dict=True`, a length mismatch, a `num_selected`
        that is not the intervals' total, intervals that select rows past
        the last page, a negative page value count, a dictionary not loaded
        for `ptype`, or an unsupported `ptype`.
    """
    if preserve_dict:
        raise Error(
            "_gather_dict_encoded: preserve_dict=True is not supported"
        )
    if len(page_buffers) != len(page_extents):
        raise Error(
            "gather dict: page_buffers/page_extents length mismatch: "
            + String(len(page_buffers))
            + " vs "
            + String(len(page_extents))
        )
    _check_num_selected("gather dict", intervals, num_selected)

    # Pass 1: decode each page's key stream into its own Int32 buffer.
    var page_keys = Slab[_PageDictKeys]()
    for i in range(len(page_buffers)):
        page_keys.append(
            _decode_page_keys(
                dict, page_buffers[i], page_extents[i].num_values
            )
        )

    # Pass 2: walk intervals, gathering selected keys into `selected_keys`.
    # Writers/readers via origin-tied views.
    comptime int32_size = size_of[Scalar[DType.int32]]()
    var selected_keys = OwnedAlignedBuffer(
        max(num_selected * int32_size, 1)
    )
    var sel_view = selected_keys.view_mut()
    var sel_ptr = sel_view._unsafe_ptr().bitcast[Int32]()
    var written: Int = 0

    var pos: Int = 0
    var page_idx: Int = 0
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

            ref keys_rec = page_keys[page_idx]
            # Keys source via origin-tied view (per-iter, inlined).
            var keys_view = keys_rec.keys.view_ro()
            var keys_ptr = keys_view._unsafe_ptr().bitcast[Int32]()
            # The page decoded `num_values` keys and `r` stays below the
            # page's `num_values`, so every `keys_ptr[r]` is a decoded key.
            for r in range(row_in_page, row_in_page + take):
                sel_ptr[written] = keys_ptr[r]
                written += 1

            pos += take
            remaining_select -= take

            if pos >= page_end:
                page_idx += 1
                if page_idx < len(page_extents):
                    page_start = page_end
                    page_end = page_start + page_extents[page_idx].num_values

    if written != num_selected:
        _raise_gather_dict_short_walk(written, num_selected)
    selected_keys.set_length(Int64(num_selected * int32_size))


    # Pass 3: materialize via dict lookup. Non-null path: validity=None.
    if ptype == ParquetType.INT32:
        if not dict.dict_values_int32:
            raise Error(
                "_gather_dict_encoded: INT32 dict not initialized"
            )
        var arr = _materialize_fixed_width[DType.int32](
            selected_keys^, num_selected,
            dict.dict_values_int32.value().data, dict.dict_size, None, 0,
        )
        return Column.from_primitive[DType.int32](arr)
    elif ptype == ParquetType.INT64:
        if not dict.dict_values_int64:
            raise Error(
                "_gather_dict_encoded: INT64 dict not initialized"
            )
        var arr = _materialize_fixed_width[DType.int64](
            selected_keys^, num_selected,
            dict.dict_values_int64.value().data, dict.dict_size, None, 0,
        )
        return Column.from_primitive[DType.int64](arr)
    elif ptype == ParquetType.FLOAT:
        if not dict.dict_values_float32:
            raise Error(
                "_gather_dict_encoded: FLOAT dict not initialized"
            )
        var arr = _materialize_fixed_width[DType.float32](
            selected_keys^, num_selected,
            dict.dict_values_float32.value().data, dict.dict_size, None, 0,
        )
        return Column.from_primitive[DType.float32](arr)
    elif ptype == ParquetType.DOUBLE:
        if not dict.dict_values_float64:
            raise Error(
                "_gather_dict_encoded: DOUBLE dict not initialized"
            )
        var arr = _materialize_fixed_width[DType.float64](
            selected_keys^, num_selected,
            dict.dict_values_float64.value().data, dict.dict_size, None, 0,
        )
        return Column.from_primitive[DType.float64](arr)
    elif ptype == ParquetType.BYTE_ARRAY:
        if not dict.dict_values_bytes:
            raise Error(
                "_gather_dict_encoded: BYTE_ARRAY dict not initialized"
            )
        ref dict_strings = dict.dict_values_bytes.value()
        var arr = _materialize_byte_array(
            selected_keys^, num_selected, dict_strings, None, 0,
        )
        return Column.from_string(arr)
    else:
        raise Error(
            "_gather_dict_encoded: unsupported physical type " + String(ptype)
        )


# ---------------------------------------------------------------------------
# _gather_dict_encoded_nullable — rank-mapped variant
# ---------------------------------------------------------------------------


def _gather_dict_encoded_nullable(
    ptype: ParquetType,
    dict: DictionaryDecoder,
    page_buffers: Slab[SharedAlignedBuffer[HeapRegion]],
    page_extents: Span[_PageExtent, _],
    page_def_levels: Slab[_PageDefLevels],
    intervals: Span[SelectionInterval, _],
    num_selected: Int,
    preserve_dict: Bool,
) raises -> Column[HeapRegion]:
    """Gather selected dict-encoded rows with nullable rank-mapped semantics.

    Per-page key stream contains only `num_non_null` entries. For each
    selected row r in a page:
      - if def_levels[r] != 0: val_idx = value_index[r] (rank), key =
        keys[val_idx], emit dict[key].
      - else: emit zero placeholder + clear validity bit.

    Raises:
        Error as `_gather_dict_encoded` does, and when a page carries fewer
        def levels than the rows the walk reads.
    """
    if preserve_dict:
        raise Error(
            "_gather_dict_encoded_nullable: preserve_dict=True is not "
            "supported"
        )
    if len(page_buffers) != len(page_extents):
        raise Error(
            "gather dict nullable: page_buffers/page_extents length mismatch: "
            + String(len(page_buffers))
            + " vs "
            + String(len(page_extents))
        )
    if len(page_buffers) != len(page_def_levels):
        raise Error(
            "gather dict nullable: page_buffers/page_def_levels length mismatch: "
            + String(len(page_buffers))
            + " vs "
            + String(len(page_def_levels))
        )
    _check_num_selected("gather dict nullable", intervals, num_selected)

    # Pass 1: per-page key stream (length == num_non_null) + rank tables.
    var page_keys = Slab[_PageDictKeys]()
    var value_indices = List[List[UInt32]]()
    for i in range(len(page_buffers)):
        ref defs_rec = page_def_levels[i]
        page_keys.append(
            _decode_page_keys(dict, page_buffers[i], defs_rec.num_non_null)
        )
        value_indices.append(_build_value_index(Span(defs_rec.defs)))

    # Pass 2: walk intervals, gathering selected keys + validity bits.
    # Writers via origin-tied views.
    comptime int32_size = size_of[Scalar[DType.int32]]()
    var selected_keys = OwnedAlignedBuffer(
        max(num_selected * int32_size, 1)
    )
    var sel_view = selected_keys.view_mut()
    var sel_ptr = sel_view._unsafe_ptr().bitcast[Int32]()
    var validity = Bitmap.create_all_valid(max(num_selected, 1))
    var null_count: Int = 0
    var has_any_null: Bool = False

    var written: Int = 0
    var pos: Int = 0
    var page_idx: Int = 0
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
                    "gather dict nullable: page "
                    + String(page_idx)
                    + " carries "
                    + String(len(defs_rec.defs))
                    + " def levels, the walk needs row "
                    + String(row_in_page + take - 1)
                )
            ref vidx = value_indices[page_idx]
            ref keys_rec = page_keys[page_idx]
            # Keys source via origin-tied view.
            var keys_view = keys_rec.keys.view_ro()
            var keys_ptr = keys_view._unsafe_ptr().bitcast[Int32]()
            var keys_len = keys_rec.length

            for r in range(row_in_page, row_in_page + take):
                if defs_rec.defs[r] != 0:
                    var val_idx = Int(vidx[r])
                    if val_idx < keys_len:
                        sel_ptr[written] = keys_ptr[val_idx]
                    else:
                        sel_ptr[written] = Int32(0)
                    # validity bit already 1 by create_all_valid.
                else:
                    sel_ptr[written] = Int32(0)  # placeholder
                    validity.clear(written)
                    null_count += 1
                    has_any_null = True
                written += 1

            pos += take
            remaining_select -= take

            if pos >= page_end:
                page_idx += 1
                if page_idx < len(page_extents):
                    page_start = page_end
                    page_end = page_start + page_extents[page_idx].num_values

    if written != num_selected:
        _raise_gather_dict_short_walk(written, num_selected)
    selected_keys.set_length(Int64(num_selected * int32_size))


    var validity_opt: Optional[Bitmap[HeapRegion]]
    if has_any_null:
        validity_opt = Optional[Bitmap[HeapRegion]](validity^)
    else:
        _ = validity^
        validity_opt = Optional[Bitmap[HeapRegion]](None)

    # Pass 3: materialize via dict lookup.
    if ptype == ParquetType.INT32:
        if not dict.dict_values_int32:
            raise Error(
                "_gather_dict_encoded_nullable: INT32 dict not initialized"
            )
        var arr = _materialize_fixed_width[DType.int32](
            selected_keys^, num_selected,
            dict.dict_values_int32.value().data, dict.dict_size,
            validity_opt^, null_count,
        )
        return Column.from_primitive[DType.int32](arr)
    elif ptype == ParquetType.INT64:
        if not dict.dict_values_int64:
            raise Error(
                "_gather_dict_encoded_nullable: INT64 dict not initialized"
            )
        var arr = _materialize_fixed_width[DType.int64](
            selected_keys^, num_selected,
            dict.dict_values_int64.value().data, dict.dict_size,
            validity_opt^, null_count,
        )
        return Column.from_primitive[DType.int64](arr)
    elif ptype == ParquetType.FLOAT:
        if not dict.dict_values_float32:
            raise Error(
                "_gather_dict_encoded_nullable: FLOAT dict not initialized"
            )
        var arr = _materialize_fixed_width[DType.float32](
            selected_keys^, num_selected,
            dict.dict_values_float32.value().data, dict.dict_size,
            validity_opt^, null_count,
        )
        return Column.from_primitive[DType.float32](arr)
    elif ptype == ParquetType.DOUBLE:
        if not dict.dict_values_float64:
            raise Error(
                "_gather_dict_encoded_nullable: DOUBLE dict not initialized"
            )
        var arr = _materialize_fixed_width[DType.float64](
            selected_keys^, num_selected,
            dict.dict_values_float64.value().data, dict.dict_size,
            validity_opt^, null_count,
        )
        return Column.from_primitive[DType.float64](arr)
    elif ptype == ParquetType.BYTE_ARRAY:
        if not dict.dict_values_bytes:
            raise Error(
                "_gather_dict_encoded_nullable: BYTE_ARRAY dict not initialized"
            )
        ref dict_strings = dict.dict_values_bytes.value()
        var arr = _materialize_byte_array(
            selected_keys^, num_selected, dict_strings, validity_opt^, null_count,
        )
        return Column.from_string(arr)
    else:
        raise Error(
            "_gather_dict_encoded_nullable: unsupported physical type "
            + String(ptype)
        )
