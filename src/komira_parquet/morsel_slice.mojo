# =============================================================================
# morsel_slice — a window of a decoded column's rows, as its own column
# =============================================================================
#
# `ParquetMorselReader.next_morsel` decodes a whole row group, then yields it
# a morsel at a time. `slice_column_rows(col, start, length)` makes each
# morsel's column: rows [start, start + length) of `col` in a new Column at
# offset 0, with its validity rebased to bit 0 and the window's null count.
#
#   | layout                     | how the window is made                   |
#   |----------------------------|------------------------------------------|
#   | fixed-width (numeric,      | the window's bytes copied                |
#   | temporal, DECIMAL128)      |                                          |
#   | STRING / BINARY            | the window's bytes copied, its Int32     |
#   |                            | offsets rebased to start at 0            |
#   | BOOL                       | the window's bits copied to bit 0        |
#   | DICTIONARY                 | the window's codes copied; the           |
#   |                            | dictionary shared with `col`             |
#
# Any other layout (LARGE_STRING, nested, ...) is refused: the morsel reader
# decodes flat columns only, and an unknown layout copied as opaque bytes
# would be a wrong column, not an error.
# =============================================================================

from std.sys import simd_width_of, size_of

from komira_arrow.arrow_types import ArrowType, arrow_fixed_byte_width
from komira_arrow.bitmap import Bitmap, copy_bits_aligned_buffer
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import bridge_oab_to_sab


def _window_validity(
    col: Column[HeapRegion], abs_start: Int, length: Int, mut nulls: Int
) raises -> Optional[Bitmap[HeapRegion]]:
    """The window's validity rebased to bit 0 (None when `col` has none)."""
    nulls = 0
    if not col._validity:
        return None
    var bm = Bitmap.copy_slice_from(col._validity.value(), abs_start, length)
    nulls = bm.null_count()
    return bm^


def slice_column_rows(
    col: Column[HeapRegion], start: Int, length: Int
) raises -> Column[HeapRegion]:
    """Rows [start, start + length) of `col` as a new Column at offset 0.

    Args:
        col: The source column (its own `_offset` is honored).
        start: The first row of the window, relative to `col`.
        length: The number of rows.

    Raises:
        Error if the window is outside `col`, or `col`'s layout is not one
        the table in this module's header names.
    """
    if start < 0 or length < 0 or start + length > col._length:
        raise Error(
            "slice_column_rows: rows ["
            + String(start)
            + ", "
            + String(start + length)
            + ") are outside a column of "
            + String(col._length)
            + " rows"
        )
    var at = col.arrow_type
    var abs_start = col._offset + start
    if at == ArrowType.STRING or at == ArrowType.BINARY:
        return _slice_string(col, abs_start, length)
    if at == ArrowType.BOOL:
        return _slice_bool(col, abs_start, length)
    if at == ArrowType.DICTIONARY:
        return _slice_dict(col, abs_start, length)
    return _slice_fixed(col, abs_start, length)


def _slice_fixed(
    col: Column[HeapRegion], abs_start: Int, length: Int
) raises -> Column[HeapRegion]:
    # `arrow_fixed_byte_width` raises for every layout that is not one
    # fixed byte width per row.
    var width = arrow_fixed_byte_width(col.arrow_type)
    var byte_len = length * width
    var data = OwnedAlignedBuffer(max(byte_len, 1))
    if byte_len > 0:
        data.copy_from_view(col._data.view_range_ro(abs_start * width, byte_len))
    data.set_length(Int64(byte_len))
    var nulls = 0
    var validity = _window_validity(col, abs_start, length, nulls)
    var out = Column[HeapRegion](
        arrow_type=col.arrow_type,
        data=data^,
        offsets=None,
        validity=validity^,
        length=length,
        null_count=nulls,
        offset=0,
    )
    out._decimal_p = col._decimal_p
    out._decimal_s = col._decimal_s
    return out^


def _slice_string(
    col: Column[HeapRegion], abs_start: Int, length: Int
) raises -> Column[HeapRegion]:
    comptime I32 = size_of[Int32]()
    if not col._offsets:
        raise Error("slice_column_rows: a string column without offsets")
    ref src_off = col._offsets.value()
    var src_view = src_off.view_ro()
    var data_start = Int(src_view.get_typed[Int32](abs_start))
    var data_end = Int(src_view.get_typed[Int32](abs_start + length))
    var data_len = data_end - data_start
    if data_len < 0:
        raise Error("slice_column_rows: string offsets run backwards")

    var data = OwnedAlignedBuffer(max(data_len, 1))
    if data_len > 0:
        data.copy_from_view(col._data.view_range_ro(data_start, data_len))
    data.set_length(Int64(data_len))

    # PERF-CRITICAL: SIMD offset rebase. Broadcast the window's first offset
    # and subtract it W lanes at a time; this runs once per string column
    # per morsel. A stride-1 scalar loop is not auto-vectorized.
    var n = length + 1
    var off_bytes = n * I32
    var offsets = OwnedAlignedBuffer(off_bytes)
    offsets.set_length(Int64(off_bytes))
    var base = Int32(data_start)
    comptime W = simd_width_of[DType.int32]()
    var base_vec = SIMD[DType.int32, W](base)
    var src_byte = abs_start * I32
    var simd_end = (n // W) * W
    var i = 0
    while i < simd_end:
        var v = src_off.load_simd[DType.int32, W](src_byte + i * I32)
        offsets.store_simd[DType.int32, W](i * I32, v - base_vec)
        i += W
    while i < n:
        offsets.set_typed[Int32](i, src_view.get_typed[Int32](abs_start + i) - base)
        i += 1

    var nulls = 0
    var validity = _window_validity(col, abs_start, length, nulls)
    return Column[HeapRegion](
        arrow_type=col.arrow_type,
        data=data^,
        offsets=offsets^,
        validity=validity^,
        length=length,
        null_count=nulls,
        offset=0,
    )


def _slice_bool(
    col: Column[HeapRegion], abs_start: Int, length: Int
) raises -> Column[HeapRegion]:
    var bytes = (length + 7) >> 3
    var data = OwnedAlignedBuffer(max(bytes, 1))
    data.set_length(Int64(bytes))
    if bytes > 0:
        data.view_range_mut(0, bytes).fill(UInt8(0))
        copy_bits_aligned_buffer(data, 0, col._data, abs_start, length)
    var nulls = 0
    var validity = _window_validity(col, abs_start, length, nulls)
    return Column[HeapRegion](
        arrow_type=ArrowType.BOOL,
        data=data^,
        offsets=None,
        validity=validity^,
        length=length,
        null_count=nulls,
        offset=0,
    )


def _slice_dict(
    col: Column[HeapRegion], abs_start: Int, length: Int
) raises -> Column[HeapRegion]:
    """The window's codes, copied at the column's index width; the
    dictionary (values, offsets, size, value type) shared with `col`."""
    var width = col._dict_index_byte_width
    var byte_len = length * width
    var codes = OwnedAlignedBuffer(max(byte_len, 1))
    if byte_len > 0:
        codes.copy_from_view(col._data.view_range_ro(abs_start * width, byte_len))
    codes.set_length(Int64(byte_len))
    var nulls = 0
    var validity = _window_validity(col, abs_start, length, nulls)
    var out = col.share()
    out._data = bridge_oab_to_sab[HeapRegion](codes^)
    out._validity = validity^
    out._length = length
    out._null_count = nulls
    out._offset = 0
    return out^
