# =============================================================================
# Selective Decode — decode only rows that passed the filter
# =============================================================================
#
# Standard path: decode full column -> filter -> gather selected rows.
# Selective decode: given a SelectionVector (which rows passed the filter),
# decode ONLY those rows from the Parquet page data.
#
# For low-selectivity filters (1-8%), this avoids decoding 92-99% of the
# column data. The savings are most significant for string columns where
# decode involves length-prefixed byte array parsing.
#
# Supported decode modes:
#   - Fixed-width (INT32, INT64, FLOAT32, FLOAT64): direct offset indexing
#     into the PLAIN-encoded page buffer. O(selected_rows) memcpy.
#   - Strings (BYTE_ARRAY): sequential scan with skip for unselected rows.
#     Still O(total_rows) for offset parsing but O(selected_bytes) for data copy.
#   - Boolean: bit-level selective extraction.
#
# Limitation: only works for PLAIN-encoded, uncompressed pages (or pages
# that have already been decompressed). For RLE_DICTIONARY pages, the dict
# indices are fixed-width INT32, so the fixed-width path applies after
# dictionary page decode.
#
# =============================================================================

from std.memory import unsafe_memcpy, unsafe_memset
from std.sys import size_of

from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.boolean_array import BooleanArray
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_arrow.bitmap import Bitmap
from komira_buffer.byte_view import ByteView
from komira_buffer.heap_region import HeapRegion
from komira_arrow.selection_vector import SelectionVector


# =============================================================================
# Fixed-width selective decode
# =============================================================================


def selective_decode_fixed[dtype: DType](
    page_data: ByteView[_],
    total_rows: Int,
    selection: SelectionVector,
) -> PrimitiveArray[dtype]:
    """Decode only selected rows from a PLAIN-encoded fixed-width page.

    Instead of decoding all total_rows and then gathering, this reads only
    the selected row values by computing byte offsets directly. For a 1%
    selectivity filter on 6M rows, this reads 60K values instead of 6M.

    Args:
        page_data: View over PLAIN-encoded data (after any page header and
            def levels). Origin tied to the caller's source buffer.
        total_rows: Total rows in the page (used for bounds checking).
        selection: SelectionVector containing indices of rows to decode.

    Returns:
        A PrimitiveArray containing only the selected rows, in selection order.
    """
    # Reads and writes go through `get_typed` / `set_typed`.
    comptime elem_size = size_of[Scalar[dtype]]()
    var sel_count = selection.length()

    var result = PrimitiveArray[dtype].allocate(sel_count)

    for i in range(sel_count):
        var row_idx = Int(selection.indices.get_typed[Scalar[DType.int32]](i))
        # Typed element read via ByteView; bounds-checked, origin-tracked.
        result.set_typed[Scalar[dtype]](i, page_data.get_typed[Scalar[dtype]](row_idx))

    return result^


# =============================================================================
# String selective decode (BYTE_ARRAY PLAIN encoding)
# =============================================================================


def selective_decode_string(
    page_data: ByteView[_],
    total_rows: Int,
    selection: SelectionVector,
) raises -> StringArray[HeapRegion]:
    """Decode only selected strings from a PLAIN BYTE_ARRAY page.

    PLAIN BYTE_ARRAY format: each value is [4-byte LE length][bytes...].
    We must sequentially scan all rows to find offsets (variable-length),
    but only copy data bytes for selected rows.

    For low selectivity, the savings come from reduced data copies and
    reduced output buffer size, not from skipping the offset scan.

    Args:
        page_data: View over PLAIN BYTE_ARRAY encoded data. Origin tied to
            the caller's source buffer.
        total_rows: Total rows in the page.
        selection: SelectionVector of rows to decode.

    Returns:
        A StringArray containing only the selected strings.
    """
    var page_len = page_data.len()
    var sel_count = selection.length()
    if sel_count == 0:
        # Empty-selection sentinel — first offset is 0 (via set_typed).
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer(int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))
        offsets_buf.set_length(Int64(int32_size))

        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)

        return StringArray(offsets_buf^, data_buf^, None, 0, 0, 0)

    # Indices are read through `selection.indices.get_typed[Scalar[DType.int32]]`
    # (offset-aware, @always_inline, debug_assert-bounds-checked).

    # Build a set of selected row indices for O(1) lookup.
    # For small selections, a sorted scan is faster, but for simplicity
    # we use a bitmap approach (1 bit per row).
    var sel_bitmap_bytes = (total_rows + 7) >> 3
    var sel_bitmap = OwnedAlignedBuffer(max(sel_bitmap_bytes, 1))
    var sel_view = sel_bitmap.view_mut()
    sel_view.fill(0)
    for i in range(sel_count):
        var row = Int(selection.indices.get_typed[Scalar[DType.int32]](i))
        var byte_idx = row >> 3
        var bit_idx = row & 7
        var cur = sel_view.read_u8_at(byte_idx)
        sel_view.write_u8_at(byte_idx, cur | (UInt8(1) << UInt8(bit_idx)))

    # First pass: scan all rows to find byte offsets and total selected bytes.
    var row_offsets = List[Int](capacity=total_rows)
    var row_lengths = List[Int](capacity=total_rows)
    var total_selected_bytes = 0
    var offset = 0

    for row in range(total_rows):
        if offset + 4 > page_len:
            break
        # Read 4-byte LE length as a single 32-bit load via ByteView.
        var str_len = Int(page_data.read_i32_le_at(offset))
        offset += 4
        row_offsets.append(offset)
        row_lengths.append(str_len)

        # Check if this row is selected.
        var byte_idx = row >> 3
        var bit_idx = row & 7
        var is_selected = (sel_view.read_u8_at(byte_idx) >> UInt8(bit_idx)) & UInt8(1) != UInt8(0)
        if is_selected:
            total_selected_bytes += str_len

        offset += str_len

    # Second pass: copy selected string data and build offsets.
    comptime int32_size = size_of[Int32]()
    var out_offsets_bytes = (sel_count + 1) * int32_size
    var out_offsets = OwnedAlignedBuffer(out_offsets_bytes)
    var out_data = OwnedAlignedBuffer(max(total_selected_bytes, 1))
    # out_offsets writes via set_typed.
    var data_write_pos = 0

    out_offsets.set_typed[Int32](0, Int32(0))
    for i in range(sel_count):
        var row = Int(selection.indices.get_typed[Scalar[DType.int32]](i))
        if row < len(row_offsets):
            var str_start = row_offsets[row]
            var str_len = row_lengths[row]
            if str_len > 0 and str_start + str_len <= page_len:
                # Non-overlapping memcpy: source is in page_data, dest is
                # out_data (fresh MmapAlignedBuffer). Route through ByteView
                # for origin-tracked bulk copy.
                var dst_view = out_data.view_range_mut(data_write_pos, str_len)
                dst_view.copy_from_view_at(0, page_data.sub(str_start, str_len))
            data_write_pos += str_len
        out_offsets.set_typed[Int32](i + 1, Int32(data_write_pos))

    out_offsets.set_length(Int64(out_offsets_bytes))

    out_data.set_length(Int64(total_selected_bytes))


    _ = sel_bitmap^  # keepalive

    return StringArray(out_offsets^, out_data^, None, sel_count, 0, 0)


# =============================================================================
# Boolean selective decode
# =============================================================================


def selective_decode_boolean(
    page_data: ByteView[_],
    total_rows: Int,
    selection: SelectionVector,
) -> BooleanArray:
    """Decode only selected bits from a PLAIN boolean page.

    Boolean values are bit-packed (8 per byte, LSB-first). We extract
    only the bits at selected indices and pack them into a new bitmap.

    Args:
        page_data: View over bit-packed boolean data. Origin tied to the
            caller's source buffer.
        total_rows: Total rows in the page.
        selection: SelectionVector of rows to decode.

    Returns:
        A BooleanArray containing only the selected boolean values.
    """
    # Indices are read through `selection.indices.get_typed[Scalar[DType.int32]]`.
    var sel_count = selection.length()
    var bm = Bitmap.create(sel_count)
    var bm_view = bm.buffer.view_mut()

    # Zero-fill output bitmap.
    var out_bytes = (sel_count + 7) >> 3
    if out_bytes > 0:
        bm_view.sub(0, out_bytes).fill(0)

    for i in range(sel_count):
        var row = Int(selection.indices.get_typed[Scalar[DType.int32]](i))
        # Read source bit via ByteView.
        var src_byte = row >> 3
        var src_bit = row & 7
        var is_set = (page_data.read_u8_at(src_byte) >> UInt8(src_bit)) & UInt8(1) != UInt8(0)
        if is_set:
            var dst_byte = i >> 3
            var dst_bit = i & 7
            var cur = bm_view.read_u8_at(dst_byte)
            bm_view.write_u8_at(dst_byte, cur | (UInt8(1) << UInt8(dst_bit)))

    return BooleanArray.from_bitmap(bm^)


# =============================================================================
# Gather from decoded array using SelectionVector
# =============================================================================


def gather_strings(
    source: StringArray[HeapRegion],
    selection: SelectionVector,
) raises -> StringArray[HeapRegion]:
    """Gather selected rows from a StringArray using a SelectionVector.

    This is the post-decode gather path: when a column has already been
    decoded to a StringArray, gather only the selected rows. Useful when
    selective decode is not applicable (e.g., dictionary-encoded columns
    where the full column is decoded then filtered).

    Args:
        source: The decoded StringArray.
        selection: Indices of rows to gather.

    Returns:
        A new StringArray containing only the selected rows.
    """
    var sel_count = selection.length()
    # MmapAlignedBuffer offsets/data go through views + typed accessors, and
    # indices through `selection.indices.get_typed[Scalar[DType.int32]]`.
    if sel_count == 0:
        comptime int32_size = size_of[Int32]()
        var offsets_buf = OwnedAlignedBuffer(int32_size)
        offsets_buf.set_typed[Int32](0, Int32(0))
        offsets_buf.set_length(Int64(int32_size))

        var data_buf = OwnedAlignedBuffer(1)
        data_buf.set_length(0)

        return StringArray(offsets_buf^, data_buf^, None, 0, 0, 0)

    var src_off_view = source.offsets.view_ro()

    # Calculate total data bytes for selected strings.
    var total_bytes = 0
    for i in range(sel_count):
        var row = Int(selection.indices.get_typed[Scalar[DType.int32]](i))
        var start = Int(src_off_view.get_typed[Int32](row))
        var end = Int(src_off_view.get_typed[Int32](row + 1))
        total_bytes += end - start

    comptime int32_size = size_of[Int32]()
    var out_off_bytes = (sel_count + 1) * int32_size
    var out_offsets = OwnedAlignedBuffer(out_off_bytes)
    var out_data = OwnedAlignedBuffer(max(total_bytes, 1))
    var write_pos = 0

    out_offsets.set_typed[Int32](0, Int32(0))
    for i in range(sel_count):
        var row = Int(selection.indices.get_typed[Scalar[DType.int32]](i))
        var start = Int(src_off_view.get_typed[Int32](row))
        var end = Int(src_off_view.get_typed[Int32](row + 1))
        var str_len = end - start
        if str_len > 0:
            out_data.view_range_mut(write_pos, str_len).copy_from_view_at(
                0, source.data.view_range_ro(start, str_len)
            )
        write_pos += str_len
        out_offsets.set_typed[Int32](i + 1, Int32(write_pos))

    out_offsets.set_length(Int64(out_off_bytes))

    out_data.set_length(Int64(total_bytes))


    return StringArray(out_offsets^, out_data^, None, sel_count, 0, 0)
