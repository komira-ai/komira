# =============================================================================
# column_decoder_strings — the array builders of the column decoder: a string
#                          dictionary rebuilt dense, string pages joined, two
#                          numeric runs joined, a binary run spread over nulls
# =============================================================================
#
# `decode_column_pages` (column_decoder) accumulates a chunk page by page and
# builds its column at the end (column_decoder_assemble). These are the
# builders that copy bytes between arrays:
#
#   * `_dict_to_string_array`: a StringDictionaryArray as a dense StringArray,
#     each row's bytes copied out of the dictionary (counted by
#     dict_mat_counter);
#   * `_resolve_codes_to_strings`: a range of dictionary codes as a dense
#     StringArray, for a BYTE_ARRAY chunk whose dictionary pages are followed
#     by PLAIN or DELTA pages (pyarrow switches a chunk to PLAIN when its
#     dictionary outgrows the dictionary page limit);
#   * `_concat_string_arrays`: the string runs of such a chunk, in page order;
#   * `_concat_two_primitive`: a numeric chunk's resolved dictionary pages
#     followed by its PLAIN pages;
#   * `_expand_binary_with_nulls`: a dense BinaryArray spread over a chunk's
#     definition bits, the FIXED_LEN_BYTE_ARRAY twin of the `_expand_with_nulls_*`
#     helpers in null_expand.
#
# The inputs are arrays this package built, so their offsets are in range;
# dictionary codes are checked against the dictionary by
# `DictionaryDecoder.resolve_as_string_dict` before they reach a builder.
# =============================================================================

from std.memory import UnsafePointer
from std.sys import size_of

from komira_arrow.binary_array import BinaryArray
from komira_arrow.bitmap import Bitmap
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab

from .dict_mat_counter import dict_mat_counter_incr
from .dictionary import DictionaryDecoder
from .null_expand import _def_bit_is_set


def _empty_string_array() -> StringArray[HeapRegion]:
    """A zero-row StringArray: one zero offset, no bytes."""
    comptime i32sz = size_of[Int32]()
    var offsets = OwnedAlignedBuffer(i32sz)
    offsets.set_length(Int64(i32sz))
    offsets.set_typed[Int32](0, Int32(0))
    var data = OwnedAlignedBuffer(1)
    data.set_length(Int64(0))
    return StringArray[HeapRegion](offsets^, data^, None, 0, 0, 0)


def _dict_to_string_array(
    arr: StringDictionaryArray,
) raises -> StringArray[HeapRegion]:
    """Rebuild a string dictionary column as a dense StringArray.

    Each row's bytes are copied out of the dictionary; a null row (by the
    indices' validity) is an empty slot. The validity is carried over.
    Counted by `dict_mat_counter`, one add per call.
    """
    dict_mat_counter_incr()
    comptime i32sz = size_of[Int32]()
    var n = arr.length
    var dict_off = arr.dictionary.offsets.view_ro()
    var dict_data = arr.dictionary.data.view_ro()
    var codes = arr.indices.view_ro()
    var is_nullable = Bool(arr.indices.validity)

    # PERF-CRITICAL: pass 1, the output offsets, with the nullable check
    # hoisted out of the row loop so the common non-null walk tests no bitmap.
    var out_offsets = OwnedAlignedBuffer((n + 1) * i32sz)
    out_offsets.set_length(Int64((n + 1) * i32sz))
    out_offsets.set_typed[Int32](0, Int32(0))
    var total_bytes = 0
    if not is_nullable:
        for i in range(n):
            var di = Int(codes.read_i32_le_at(i * i32sz))
            total_bytes += Int(dict_off.read_i32_le_at((di + 1) * i32sz)) - Int(
                dict_off.read_i32_le_at(di * i32sz)
            )
            out_offsets.set_typed[Int32](i + 1, Int32(total_bytes))
    else:
        ref bm = arr.indices.validity.value()
        for i in range(n):
            if bm.test(i):
                var di = Int(codes.read_i32_le_at(i * i32sz))
                total_bytes += Int(
                    dict_off.read_i32_le_at((di + 1) * i32sz)
                ) - Int(dict_off.read_i32_le_at(di * i32sz))
            out_offsets.set_typed[Int32](i + 1, Int32(total_bytes))

    # Pass 2: the bytes, one copy per row.
    var out_data = OwnedAlignedBuffer(max(total_bytes, 1))
    var write = 0
    for i in range(n):
        if is_nullable and not arr.indices.validity.value().test(i):
            continue
        var di = Int(codes.read_i32_le_at(i * i32sz))
        var s = Int(dict_off.read_i32_le_at(di * i32sz))
        var e = Int(dict_off.read_i32_le_at((di + 1) * i32sz))
        if e > s:
            out_data.copy_from_view_at(write, dict_data.sub(s, e - s))
        write += e - s
    out_data.set_length(Int64(total_bytes))

    var validity = Optional[Bitmap[HeapRegion]](None)
    if is_nullable:
        validity = arr.indices.validity.value().share()
    return StringArray[HeapRegion](
        out_offsets^,
        out_data^,
        validity^,
        n,
        total_bytes,
        arr.indices.null_count,
    )


def _resolve_codes_to_strings(
    dict_decoder: DictionaryDecoder,
    codes: OwnedAlignedBuffer,
    start: Int,
    end: Int,
) raises -> StringArray[HeapRegion]:
    """The dictionary codes `[start, end)` of `codes` (Int32 elements) as a
    dense StringArray.

    Raises:
        Error if a code is outside the dictionary.
    """
    comptime i32sz = size_of[Int32]()
    var n = end - start
    if n <= 0:
        return _empty_string_array()
    var slice_buf = OwnedAlignedBuffer(n * i32sz)
    slice_buf.copy_from_view(codes.view_range_ro(start * i32sz, n * i32sz))
    var indices = PrimitiveArray[DType.int32](slice_buf^, n, None, 0, 0)
    var dict_arr = dict_decoder.resolve_as_string_dict(indices)
    return _dict_to_string_array(dict_arr)


def _concat_string_arrays(
    pages: Slab[StringArray[HeapRegion]],
) raises -> StringArray[HeapRegion]:
    """The non-null string runs of a chunk joined in order into one dense
    StringArray (no validity: the caller spreads it over the definition
    bits)."""
    comptime i32sz = size_of[Int32]()
    var total_len = 0
    var total_bytes = 0
    for i in range(len(pages)):
        total_len += pages[i].length
        total_bytes += pages[i].data_length

    var offsets = OwnedAlignedBuffer((total_len + 1) * i32sz)
    offsets.set_length(Int64((total_len + 1) * i32sz))
    offsets.set_typed[Int32](0, Int32(0))
    var data = OwnedAlignedBuffer(max(total_bytes, 1))
    var out_rows = 0
    var out_bytes = 0
    for i in range(len(pages)):
        ref pg = pages[i]
        var pg_off = pg.offsets.view_ro()
        var base = Int(pg_off.read_i32_le_at(0))
        var pg_end = Int(pg_off.read_i32_le_at(pg.length * i32sz))
        if pg_end > base:
            data.copy_from_view_at(
                out_bytes, pg.data.view_ro().sub(base, pg_end - base)
            )
        for k in range(pg.length):
            var rel = Int(pg_off.read_i32_le_at((k + 1) * i32sz)) - base
            offsets.set_typed[Int32](out_rows + k + 1, Int32(out_bytes + rel))
        out_rows += pg.length
        out_bytes += pg_end - base
    data.set_length(Int64(out_bytes))
    return StringArray[HeapRegion](
        offsets^, data^, None, total_len, out_bytes, 0
    )


def _concat_two_primitive[
    dt: DType
](head: PrimitiveArray[dt], tail: PrimitiveArray[dt]) raises -> PrimitiveArray[
    dt
]:
    """`head` then `tail`, both non-null, in one new array: a numeric chunk's
    resolved dictionary pages followed by its PLAIN pages."""
    comptime elem = size_of[Scalar[dt]]()
    var total = head.length + tail.length
    var buf = OwnedAlignedBuffer(max(total * elem, 1))
    buf.set_length(Int64(total * elem))
    if head.length > 0:
        buf.copy_from_view_at(0, head.view_ro())
    if tail.length > 0:
        buf.copy_from_view_at(head.length * elem, tail.view_ro())
    return PrimitiveArray[dt](buf^, total, None, 0, 0)


def _expand_binary_with_nulls[
    o: Origin[mut=True]
](
    dense: BinaryArray[HeapRegion],
    def_bits: UnsafePointer[UInt8, o],
    total: Int,
) raises -> BinaryArray[HeapRegion]:
    """Spread a dense BinaryArray over `total` rows by the definition bits:
    a set bit takes the next dense value, a clear bit is a null row with an
    empty slot. `def_bits` holds `total` bits and outlives the call."""
    comptime i32sz = size_of[Int32]()
    var src_off = dense.offsets.view_ro()
    var src_data = dense.data.view_ro().into_span()
    var offsets = List[Int32](capacity=total + 1)
    offsets.append(Int32(0))
    var bytes = List[UInt8](capacity=dense.data_length)
    var bm = Bitmap.create(total)
    var next = 0
    var nulls = 0
    for i in range(total):
        if _def_bit_is_set(def_bits, i) and next < dense.length:
            var s = Int(src_off.read_i32_le_at(next * i32sz))
            var e = Int(src_off.read_i32_le_at((next + 1) * i32sz))
            for b in range(s, e):
                bytes.append(src_data[b])
            bm.set(i)
            next += 1
        else:
            nulls += 1
        offsets.append(Int32(len(bytes)))
    return BinaryArray.from_buffers(
        offsets, bytes, Optional[Bitmap[HeapRegion]](bm^), nulls
    )
