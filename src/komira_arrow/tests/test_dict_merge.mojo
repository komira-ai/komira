# Unit test: merge_dict_columns helper.
#
# Builds synthetic StringDictionaryArrays (no Parquet), wraps them as
# DICTIONARY Columns, and verifies the union + remap.

from komira_arrow.arrow_types import ArrowType
from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.string_array import StringArray
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.dictionary_merge import merge_dict_columns
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_collections.slab import Slab
from std.memory import unsafe_memcpy
from std.sys import size_of
from komira_buffer.heap_region import HeapRegion


def _mk_string_array(values: List[String]) raises -> StringArray[HeapRegion]:
    """Build a StringArray[HeapRegion] from a Mojo List[String]."""
    comptime int32_size = size_of[Int32]()
    var n = len(values)
    var offs = OwnedAlignedBuffer((n + 1) * int32_size)
    var offs_ptr = offs.view_typed_ro[DType.int32]()
    (offs_ptr + 0)[] = Int32(0)
    var total = 0
    for i in range(n):
        total += values[i].byte_length()
        (offs_ptr + i + 1)[] = Int32(total)
    offs.set_length(Int64((n + 1) * int32_size))


    var data = OwnedAlignedBuffer(max(total, 1))
    var w = 0
    for i in range(n):
        var s = values[i]
        var slen = s.byte_length()
        if slen > 0:
            unsafe_memcpy(
                dest=data.view_typed_mut[DType.uint8]() + w,
                src=UnsafePointer[UInt8, MutUntrackedOrigin](
                    unsafe_from_address=Int(s.unsafe_ptr())
                ),
                count=slen,
            )
        w += slen
    data.set_length(Int64(total))

    return StringArray[HeapRegion](offs^, data^, None, n, total, 0)


def _mk_dict_column(dict_values: List[String], indices: List[Int32]) raises -> Column[HeapRegion]:
    """Build a DICTIONARY Column[HeapRegion] from a dict and raw indices."""
    comptime int32_size = size_of[Int32]()
    var dict_arr = _mk_string_array(dict_values)
    var n = len(indices)
    var idx_buf = OwnedAlignedBuffer(max(n * int32_size, 1))
    var idx_ptr = idx_buf.view_typed_ro[DType.int32]()
    for i in range(n):
        (idx_ptr + i)[] = indices[i]
    idx_buf.set_length(Int64(n * int32_size))

    var idx_arr = PrimitiveArray[DType.int32](idx_buf^, n, None, 0, 0)
    var sda = StringDictionaryArray(idx_arr^, dict_arr^, n)
    return Column.from_dictionary(sda)


def _resolve_dict_column(c: Column[HeapRegion]) raises -> List[String]:
    """Resolve a DICTIONARY Column[HeapRegion] to a List[String] for comparisons."""
    var out = List[String]()
    var n = c._length
    var offs = c._offsets.value().view_typed_ro[DType.int32]()
    var data = c._dict_data.value().view_typed_ro[DType.uint8]()
    var idx_ptr = c._data.view_typed_ro[DType.int32]()
    for i in range(n):
        var di = Int((idx_ptr + i)[])
        var s = Int((offs + di)[])
        var e = Int((offs + di + 1)[])
        var slen = e - s
        if slen == 0:
            out.append(String(""))
        else:
            var tmp = UnsafePointer[UInt8, MutUntrackedOrigin](
                unsafe_from_address=Int(data) + s
            )
            var buf = List[UInt8](capacity=slen + 1)
            for b in range(slen):
                buf.append((tmp + b)[])
            buf.append(UInt8(0))
            out.append(String(unsafe_from_utf8_ptr=buf.unsafe_ptr()))
    return out^


def test_merge_dict_columns_disjoint() raises:
    # RG0 dict = ["alpha", "bravo"], indices [0,1,0]
    # RG1 dict = ["charlie"], indices [0,0]
    # RG2 dict = ["bravo", "delta"], indices [1,0]
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_mk_dict_column(
        [String("alpha"), String("bravo")],
        [Int32(0), Int32(1), Int32(0)],
    ))
    cols.append(_mk_dict_column(
        [String("charlie")],
        [Int32(0), Int32(0)],
    ))
    cols.append(_mk_dict_column(
        [String("bravo"), String("delta")],
        [Int32(1), Int32(0)],
    ))

    var merged = merge_dict_columns(cols)
    if merged.arrow_type != ArrowType.DICTIONARY:
        raise Error("merged column arrow_type is not DICTIONARY")
    if merged._length != 7:
        raise Error("merged length != 7: " + String(merged._length))
    # Merged dict must cover {alpha, bravo, charlie, delta} -- order defined
    # by first-seen insertion.
    if merged._dict_size != 4:
        raise Error("merged dict_size != 4: " + String(merged._dict_size))

    var resolved = _resolve_dict_column(merged)
    var expect = [
        String("alpha"), String("bravo"), String("alpha"),
        String("charlie"), String("charlie"),
        String("delta"), String("bravo"),
    ]
    if len(resolved) != len(expect):
        raise Error("resolved length mismatch")
    for i in range(len(expect)):
        if resolved[i] != expect[i]:
            raise Error(
                "row " + String(i) + " expected '"
                + expect[i] + "' got '" + resolved[i] + "'"
            )
    print("test_merge_dict_columns_disjoint PASS")


def test_merge_dict_columns_single() raises:
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_mk_dict_column(
        [String("foo"), String("bar")],
        [Int32(1), Int32(0), Int32(1)],
    ))
    var merged = merge_dict_columns(cols)
    if merged._length != 3 or merged._dict_size != 2:
        raise Error("single-column fast path: unexpected shape")
    var resolved = _resolve_dict_column(merged)
    if resolved[0] != String("bar") or resolved[1] != String("foo") or resolved[2] != String("bar"):
        raise Error("single-column fast path: wrong resolution")
    print("test_merge_dict_columns_single PASS")


def test_merge_dict_columns_identical() raises:
    # Both inputs share the same dictionary bytes -- fast path.
    var cols = Slab[Column[HeapRegion]]()
    cols.append(_mk_dict_column(
        [String("x"), String("y")],
        [Int32(0), Int32(1)],
    ))
    cols.append(_mk_dict_column(
        [String("x"), String("y")],
        [Int32(1), Int32(0)],
    ))
    var merged = merge_dict_columns(cols)
    if merged._length != 4 or merged._dict_size != 2:
        raise Error("identical-dict fast path: unexpected shape")
    var resolved = _resolve_dict_column(merged)
    var expect = [String("x"), String("y"), String("y"), String("x")]
    for i in range(4):
        if resolved[i] != expect[i]:
            raise Error("identical-dict fast path row " + String(i))
    print("test_merge_dict_columns_identical PASS")


def main() raises:
    test_merge_dict_columns_single()
    test_merge_dict_columns_identical()
    test_merge_dict_columns_disjoint()
    print("ALL PASS")
