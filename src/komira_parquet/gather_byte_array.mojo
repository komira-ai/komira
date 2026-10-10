# =============================================================================
# Selection gather — PLAIN ByteArray (variable-width string) gather
# =============================================================================
#
#   * `_gather_plain_byte_array`          — non-null
#   * `_gather_plain_byte_array_nullable` — nullable
#
# PLAIN ByteArray on-the-wire layout per Parquet spec:
#     [4-byte LE length][bytes][4-byte LE length][bytes]...
#
# Random access is impossible (value k's position depends on every earlier
# length), so the gather WALKS the length prefixes of every row up to the last
# selected one: it steps over the prefix and body of each row between two
# selected ones, and reads the selected row. What a selection saves is not the
# walk; it is the BODY COPY of every row it does not keep.
#
# ONE walk over the length prefixes (no offset table) records each selected
# value's source offset; then ONE exact allocation and one `fast_copy_bytes`
# per selected value. The walk raises with the SAME three messages as the full
# PLAIN decode (`plain.mojo`), so a corrupt page cannot decode differently on
# the two paths.
#
# Pointer discipline: every `UnsafePointer` below is a module-internal byte
# cursor derived from an origin-tied `view_ro()`/`view_mut()` that is alive for
# the whole loop that uses it; none crosses a function boundary.
# =============================================================================

from std.sys import size_of

from komira_arrow.string_array import StringArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_buffer.heap_region import HeapRegion
from komira_collections.slab import Slab
from komira_simd.fast_copy import fast_copy_bytes

from .gather_common import _PageExtent, _PageDefLevels, _check_num_selected
from .plain import (
    _raise_plain_ba_negative_length,
    _raise_plain_ba_overruns_page,
    _raise_plain_ba_truncated_prefix,
)
from .selection_vector import SelectionInterval


comptime _INT32_MAX: Int = 2147483647


@no_inline
def _raise_gather_ba_offsets_overflow(total_bytes: Int) raises:
    """The selected values' bytes no longer fit the Int32 Arrow offsets."""
    raise Error(
        "gather byte_array: selected values total "
        + String(total_bytes)
        + " bytes, past the Int32 StringArray offset limit"
    )


@no_inline
def _raise_gather_ba_short_walk(written: Int, num_selected: Int) raises:
    """The intervals asked for rows past the last page."""
    raise Error(
        "gather byte_array: selection intervals overrun the column's pages: "
        + String(written)
        + " of "
        + String(num_selected)
        + " selected rows exist"
    )


# ---------------------------------------------------------------------------
# _gather_plain_byte_array — non-null variant
# ---------------------------------------------------------------------------


def _gather_plain_byte_array(
    page_buffers: Slab[SharedAlignedBuffer[HeapRegion]],
    page_extents: Span[_PageExtent, _],
    intervals: Span[SelectionInterval, _],
    num_selected: Int,
) raises -> Column[HeapRegion]:
    """Gather selected variable-width values across PLAIN ByteArray pages.

    Two passes, neither of which touches an unselected value's BODY:
      1. WALK — step the length prefixes in row order (`skip` rows are stepped
         over, `select` rows record their body's source offset) and write the
         output Int32 offsets. Every prefix read is validated exactly as the
         full decode validates it.
      2. COPY — allocate the data buffer at its exact size and copy each
         selected body with one `fast_copy_bytes`.

    Args:
        page_buffers: Decompressed PLAIN ByteArray page buffers, one per
            SELECTED page, in file order.
        page_extents: Parallel `(num_values, encoding)` metadata. Length
            must equal `len(page_buffers)`.
        intervals: Sorted `(skip, select)` intervals in the decoded-pages
            row coordinate space.
        num_selected: Total selected rows.

    Returns:
        A `Column` wrapping a non-nullable Arrow StringArray.

    Raises:
        Error on length mismatch, a `num_selected` that is not the intervals'
        total, interval overrun, a malformed length prefix, or selected bytes
        past the Int32 offset limit.
    """
    if len(page_buffers) != len(page_extents):
        raise Error(
            "gather byte_array: page_buffers/page_extents length mismatch: "
            + String(len(page_buffers))
            + " vs "
            + String(len(page_extents))
        )
    _check_num_selected("gather byte_array", intervals, num_selected)
    var npages = len(page_extents)

    comptime int32_size = size_of[Int32]()
    var str_offsets_buf = OwnedAlignedBuffer(
        max((num_selected + 1) * int32_size, 1)
    )
    var str_offsets_view = str_offsets_buf.view_mut()
    var str_offsets_ptr = str_offsets_view._unsafe_ptr().bitcast[Int32]()
    str_offsets_ptr[0] = Int32(0)

    # Source byte offset of each selected body, and the selected-row index at
    # which each page's run ends (pages are walked in order, so selected row
    # `k` lives in the first page `p` with `k < page_sel_end[p]`).
    var src_off = List[Int](capacity=max(num_selected, 1))
    var page_sel_end = List[Int](length=npages, fill=0)
    var total_bytes: Int = 0
    var written: Int = 0

    var pos: Int = 0
    var page_idx: Int = 0
    var page_start: Int = 0
    var page_end: Int = page_extents[0].num_values if npages > 0 else 0
    # Byte cursor into the CURRENT page, and the row it points at.
    var cur_row: Int = 0
    var byte_pos: Int = 0

    for ivl_i in range(len(intervals)):
        ref interval = intervals[ivl_i]
        pos += Int(interval.skip)

        var remaining_select = Int(interval.select)
        while remaining_select > 0 and page_idx < npages:
            if pos >= page_end:
                page_sel_end[page_idx] = written
                page_idx += 1
                if page_idx >= npages:
                    break
                page_start = page_end
                page_end = page_start + page_extents[page_idx].num_values
                cur_row = 0
                byte_pos = 0
                continue

            var row_in_page = pos - page_start
            var available_in_page = page_end - pos
            var take = (
                remaining_select
                if remaining_select < available_in_page
                else available_in_page
            )

            var page_len = page_buffers[page_idx].len()
            var page_view = page_buffers[page_idx].view_ro()
            # SAFETY: byte cursor into the page `page_view` borrows; every
            # dereference below is preceded by a bound check against
            # `page_len`, and the pointer dies with this loop iteration.
            var page_ptr = page_view._unsafe_ptr()

            # SKIP: step over the unselected rows' prefixes + bodies.
            while cur_row < row_in_page:
                if byte_pos + 4 > page_len:
                    _raise_plain_ba_truncated_prefix(cur_row, byte_pos, page_len)
                var n_skip = Int((page_ptr + byte_pos).bitcast[Int32]()[])
                if n_skip < 0:
                    _raise_plain_ba_negative_length(cur_row, n_skip)
                if n_skip > page_len - byte_pos - 4:
                    _raise_plain_ba_overruns_page(
                        cur_row, n_skip, page_len - byte_pos - 4
                    )
                byte_pos += 4 + n_skip
                cur_row += 1

            # SELECT: record each body's source offset + output offset.
            for _ in range(take):
                if byte_pos + 4 > page_len:
                    _raise_plain_ba_truncated_prefix(cur_row, byte_pos, page_len)
                var n = Int((page_ptr + byte_pos).bitcast[Int32]()[])
                if n < 0:
                    _raise_plain_ba_negative_length(cur_row, n)
                if n > page_len - byte_pos - 4:
                    _raise_plain_ba_overruns_page(
                        cur_row, n, page_len - byte_pos - 4
                    )
                src_off.append(byte_pos + 4)
                total_bytes += n
                if total_bytes > _INT32_MAX:
                    _raise_gather_ba_offsets_overflow(total_bytes)
                str_offsets_ptr[written + 1] = Int32(total_bytes)
                written += 1
                byte_pos += 4 + n
                cur_row += 1

            pos += take
            remaining_select -= take

            if pos >= page_end:
                page_sel_end[page_idx] = written
                page_idx += 1
                if page_idx < npages:
                    page_start = page_end
                    page_end = page_start + page_extents[page_idx].num_values
                    cur_row = 0
                    byte_pos = 0

    if written != num_selected:
        _raise_gather_ba_short_walk(written, num_selected)
    for p in range(page_idx, npages):
        page_sel_end[p] = written
    str_offsets_buf.set_length(Int64((num_selected + 1) * int32_size))

    var data_buf = _copy_selected_bodies(
        page_buffers, page_sel_end, src_off, str_offsets_buf, total_bytes,
    )

    var arr = StringArray(
        offsets=str_offsets_buf^,
        data=data_buf^,
        validity=None,
        length=num_selected,
        data_length=total_bytes,
        null_count=0,
    )
    return Column.from_string(arr)


def _copy_selected_bodies(
    page_buffers: Slab[SharedAlignedBuffer[HeapRegion]],
    page_sel_end: List[Int],
    src_off: List[Int],
    str_offsets: OwnedAlignedBuffer,
    total_bytes: Int,
) raises -> OwnedAlignedBuffer:
    """Pass 2 of both gathers: allocate the exact data buffer and copy each
    selected body from its page. A NULL row carries length 0 and copies
    nothing. `str_offsets` is the finished Int32 offsets buffer the walk
    wrote (`len(src_off) + 1` entries)."""
    var data_buf = OwnedAlignedBuffer(max(total_bytes, 1))
    if total_bytes > 0:
        var off_view = str_offsets.view_ro()
        # SAFETY: read cursor over the finished offsets buffer; `off_view`
        # holds the borrow for the loop, indices are `< len(src_off) + 1`.
        var off_ptr = off_view._unsafe_ptr().bitcast[Int32]()
        var data_view = data_buf.view_range_mut(0, total_bytes)
        # SAFETY: destination cursor into `data_buf` (exactly `total_bytes`
        # long, the sum of every selected length); `data_view` holds the
        # borrow for the whole copy loop.
        var data_ptr = data_view._unsafe_ptr()
        var k: Int = 0
        for p in range(len(page_sel_end)):
            var end_k = page_sel_end[p]
            if k >= end_k:
                continue
            var page_view = page_buffers[p].view_ro()
            # SAFETY: every (src_off[k], length) pair was bound-checked against
            # this page by the walk that recorded it.
            var page_ptr = page_view._unsafe_ptr()
            while k < end_k:
                var d0 = Int(off_ptr[k])
                var n = Int(off_ptr[k + 1]) - d0
                if n > 0:
                    fast_copy_bytes(
                        Span[UInt8, data_view.origin](
                            unsafe_ptr=data_ptr + d0, length=n
                        ),
                        Span[UInt8, page_view.origin](
                            unsafe_ptr=page_ptr + src_off[k], length=n
                        ),
                    )
                k += 1
    data_buf.set_length(Int64(total_bytes))
    return data_buf^


# ---------------------------------------------------------------------------
# _gather_plain_byte_array_nullable — def-level-driven variant
# ---------------------------------------------------------------------------


def _gather_plain_byte_array_nullable(
    page_buffers: Slab[SharedAlignedBuffer[HeapRegion]],
    page_extents: Span[_PageExtent, _],
    page_def_levels: Slab[_PageDefLevels],
    intervals: Span[SelectionInterval, _],
    num_selected: Int,
) raises -> Column[HeapRegion]:
    """Gather selected ByteArray rows of a nullable column.

    Each page's value stream holds only its NON-NULL values (def levels were
    stripped by the caller). The walk advances the byte
    cursor once per row whose def level is non-zero — skipped or selected —
    so no rank table is needed. A selected NULL row emits a zero-length slot
    and clears its validity bit.
    """
    if len(page_buffers) != len(page_extents):
        raise Error(
            "gather byte_array nullable: page_buffers/page_extents mismatch: "
            + String(len(page_buffers))
            + " vs "
            + String(len(page_extents))
        )
    if len(page_buffers) != len(page_def_levels):
        raise Error(
            "gather byte_array nullable: page_buffers/page_def_levels mismatch: "
            + String(len(page_buffers))
            + " vs "
            + String(len(page_def_levels))
        )
    _check_num_selected("gather byte_array nullable", intervals, num_selected)
    var npages = len(page_extents)

    comptime int32_size = size_of[Int32]()
    var str_offsets_buf = OwnedAlignedBuffer(
        max((num_selected + 1) * int32_size, 1)
    )
    var str_offsets_view = str_offsets_buf.view_mut()
    var str_offsets_ptr = str_offsets_view._unsafe_ptr().bitcast[Int32]()
    str_offsets_ptr[0] = Int32(0)

    var src_off = List[Int](capacity=max(num_selected, 1))
    var page_sel_end = List[Int](length=npages, fill=0)
    var total_bytes: Int = 0
    var written: Int = 0

    var validity = Bitmap.create_all_valid(max(num_selected, 1))
    var null_count: Int = 0

    var pos: Int = 0
    var page_idx: Int = 0
    var page_start: Int = 0
    var page_end: Int = page_extents[0].num_values if npages > 0 else 0
    var cur_row: Int = 0
    var cur_val: Int = 0  # value-stream index the byte cursor points at
    var byte_pos: Int = 0

    for ivl_i in range(len(intervals)):
        ref interval = intervals[ivl_i]
        pos += Int(interval.skip)

        var remaining_select = Int(interval.select)
        while remaining_select > 0 and page_idx < npages:
            if pos >= page_end:
                page_sel_end[page_idx] = written
                page_idx += 1
                if page_idx >= npages:
                    break
                page_start = page_end
                page_end = page_start + page_extents[page_idx].num_values
                cur_row = 0
                cur_val = 0
                byte_pos = 0
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
                    "gather byte_array nullable: page "
                    + String(page_idx)
                    + " carries "
                    + String(len(defs_rec.defs))
                    + " def levels, the walk needs row "
                    + String(row_in_page + take - 1)
                )
            var page_len = page_buffers[page_idx].len()
            var page_view = page_buffers[page_idx].view_ro()
            # SAFETY: as in `_gather_plain_byte_array`.
            var page_ptr = page_view._unsafe_ptr()

            while cur_row < row_in_page:
                if defs_rec.defs[cur_row] != 0:
                    if byte_pos + 4 > page_len:
                        _raise_plain_ba_truncated_prefix(
                            cur_val, byte_pos, page_len
                        )
                    var n_skip = Int((page_ptr + byte_pos).bitcast[Int32]()[])
                    if n_skip < 0:
                        _raise_plain_ba_negative_length(cur_val, n_skip)
                    if n_skip > page_len - byte_pos - 4:
                        _raise_plain_ba_overruns_page(
                            cur_val, n_skip, page_len - byte_pos - 4
                        )
                    byte_pos += 4 + n_skip
                    cur_val += 1
                cur_row += 1

            for _ in range(take):
                if defs_rec.defs[cur_row] != 0:
                    if byte_pos + 4 > page_len:
                        _raise_plain_ba_truncated_prefix(
                            cur_val, byte_pos, page_len
                        )
                    var n = Int((page_ptr + byte_pos).bitcast[Int32]()[])
                    if n < 0:
                        _raise_plain_ba_negative_length(cur_val, n)
                    if n > page_len - byte_pos - 4:
                        _raise_plain_ba_overruns_page(
                            cur_val, n, page_len - byte_pos - 4
                        )
                    src_off.append(byte_pos + 4)
                    total_bytes += n
                    if total_bytes > _INT32_MAX:
                        _raise_gather_ba_offsets_overflow(total_bytes)
                    byte_pos += 4 + n
                    cur_val += 1
                else:
                    # NULL row: zero-length slot, validity bit cleared.
                    src_off.append(0)
                    validity.clear(written)
                    null_count += 1
                str_offsets_ptr[written + 1] = Int32(total_bytes)
                written += 1
                cur_row += 1

            pos += take
            remaining_select -= take

            if pos >= page_end:
                page_sel_end[page_idx] = written
                page_idx += 1
                if page_idx < npages:
                    page_start = page_end
                    page_end = page_start + page_extents[page_idx].num_values
                    cur_row = 0
                    cur_val = 0
                    byte_pos = 0

    if written != num_selected:
        _raise_gather_ba_short_walk(written, num_selected)
    for p in range(page_idx, npages):
        page_sel_end[p] = written
    str_offsets_buf.set_length(Int64((num_selected + 1) * int32_size))

    var data_buf = _copy_selected_bodies(
        page_buffers, page_sel_end, src_off, str_offsets_buf, total_bytes,
    )

    var validity_opt: Optional[Bitmap[HeapRegion]]
    if null_count > 0:
        validity_opt = Optional[Bitmap[HeapRegion]](validity^)
    else:
        _ = validity^
        validity_opt = Optional[Bitmap[HeapRegion]](None)

    var arr = StringArray(
        offsets=str_offsets_buf^,
        data=data_buf^,
        validity=validity_opt^,
        length=num_selected,
        data_length=total_bytes,
        null_count=null_count,
    )
    return Column.from_string(arr)
