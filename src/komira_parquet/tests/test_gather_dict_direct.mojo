# Direct tests of `gather_dict.mojo`: the selection gathers of dict-encoded
# (RLE_DICTIONARY) pages, non-null and nullable, for every physical type they
# take (INT32, INT64, FLOAT, DOUBLE, BYTE_ARRAY). Pages are encoded here from
# parquet-format's Encodings.md: a dictionary page is PLAIN values, a data
# page is one bit-width byte then a bit-packed run of the codes. Expected
# values come from the definition of the gather: walk the (skip, select)
# intervals over the concatenated pages; a selected row's value is
# dictionary[code] (0, or an empty string, for a code outside the
# dictionary); a nullable row with definition level 0 is null, and the codes
# of a nullable page are those of its non-null rows only, in order.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.bitmap import Bitmap
from komira_arrow.column import Column
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_buffer.owned_aligned_buffer import OwnedAlignedBuffer
from komira_buffer.shared_aligned_buffer import SharedAlignedBuffer
from komira_collections.slab import Slab
from komira_parquet_api.types import Encoding, ParquetType

from komira_parquet.dictionary import DictionaryDecoder
from komira_parquet.gather_common import _PageDefLevels, _PageExtent
from komira_parquet.gather_dict import (
    _decode_page_keys,
    _gather_dict_encoded,
    _gather_dict_encoded_nullable,
    _materialize_byte_array,
    _materialize_fixed_width,
)
from komira_parquet.selection_vector import SelectionInterval


# --- encoders ----------------------------------------------------------------


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _uleb(mut out: List[UInt8], v: Int):
    var x = v
    while True:
        var b = x & 0x7F
        x >>= 7
        if x != 0:
            out.append(UInt8(b | 0x80))
        else:
            out.append(UInt8(b))
            return


def _index_page(codes: List[Int], bw: Int) -> List[UInt8]:
    """One bit-width byte, then one bit-packed run of `codes` (padded with
    zeros to a multiple of 8), LSB-first."""
    var page: List[UInt8] = [UInt8(bw)]
    if len(codes) == 0:
        return page^
    var groups = (len(codes) + 7) // 8
    _uleb(page, (groups << 1) | 1)
    var mask = (1 << bw) - 1
    var acc = 0
    var nbits = 0
    for i in range(groups * 8):
        var v = (codes[i] & mask) if i < len(codes) else 0
        acc |= v << nbits
        nbits += bw
        while nbits >= 8:
            page.append(UInt8(acc & 0xFF))
            acc >>= 8
            nbits -= 8
    if nbits > 0:
        page.append(UInt8(acc & 0xFF))
    return page^


def _buf(bytes: List[UInt8]) -> SharedAlignedBuffer[HeapRegion]:
    var n = len(bytes)
    var buf = OwnedAlignedBuffer(max(n, 1))
    for i in range(n):
        buf.set_typed[UInt8](i, bytes[i])
    buf.set_length(Int64(n))
    return SharedAlignedBuffer.from_owned(buf^)


def _dict_values(n: Int) -> List[Int]:
    """Distinct values, none of them 0 (a 0 in the output is a fallback)."""
    var out = List[Int]()
    for i in range(n):
        out.append(i * 37 + 11)
    return out^


def _decoder(ptype: ParquetType, values: List[Int]) raises -> DictionaryDecoder:
    var page = List[UInt8]()
    var d = DictionaryDecoder()
    if ptype == ParquetType.INT32:
        for i in range(len(values)):
            _le(page, values[i], 4)
        d.init_dict_int32(Span(page), len(values))
    elif ptype == ParquetType.INT64:
        for i in range(len(values)):
            _le(page, values[i] << 33, 8)
        d.init_dict_int64(Span(page), len(values))
    elif ptype == ParquetType.FLOAT:
        for i in range(len(values)):
            _le(page, Int(Float32(values[i]).to_bits()), 4)
        d.init_dict_float32(Span(page), len(values))
    elif ptype == ParquetType.DOUBLE:
        for i in range(len(values)):
            _le(page, Int(Float64(values[i]).to_bits()), 8)
        d.init_dict_float64(Span(page), len(values))
    else:
        for i in range(len(values)):
            var s = _str(values[i])
            _le(page, s.byte_length(), 4)
            var b = s.as_bytes()
            for k in range(len(b)):
                page.append(b[k])
        d.init_dict_byte_array(Span(page), len(values))
    return d^


def _str(v: Int) -> String:
    """The BYTE_ARRAY dictionary entry for value `v`: lengths 0 to 4 and one
    past 64 bytes, so the copy sees empty and long values."""
    if v % 5 == 1:
        return String("")
    var out = String("s") + String(v)
    if v % 7 == 3:
        for _ in range(70):
            out += "x"
    return out^


# --- the reference gather ------------------------------------------------------


@fieldwise_init
struct _Row(Copyable, Movable):
    var is_null: Bool
    var code: Int


def _reference(
    rows: List[_Row], intervals: List[SelectionInterval]
) -> List[_Row]:
    var out = List[_Row]()
    var pos = 0
    for i in range(len(intervals)):
        pos += Int(intervals[i].skip)
        for _ in range(Int(intervals[i].select)):
            out.append(rows[pos].copy())
            pos += 1
    return out^


def _check(
    ptype: ParquetType,
    col: Column[HeapRegion],
    want: List[_Row],
    values: List[Int],
) raises:
    """`col` holds dictionary[code] (or the fallback) or null, row by row."""
    var n = len(want)
    var nulls = 0
    for i in range(n):
        if want[i].is_null:
            nulls += 1
    assert_equal(col.length(), n)
    for i in range(n):
        assert_equal(col.is_null_at(i), want[i].is_null, "row " + String(i))
        if want[i].is_null:
            # A null row's slot holds a placeholder; only its bit is defined.
            continue
        var c = want[i].code
        var hit = c >= 0 and c < len(values)
        var v = values[c] if hit else 0
        if ptype == ParquetType.INT32:
            var a = col.as_primitive[DType.int32]()
            assert_equal(a.null_count, nulls)
            assert_equal(Int(a.get(i)), v, "row " + String(i))
        elif ptype == ParquetType.INT64:
            var a = col.as_primitive[DType.int64]()
            assert_equal(a.null_count, nulls)
            assert_equal(Int(a.get(i)), v << 33, "row " + String(i))
        elif ptype == ParquetType.FLOAT:
            var a = col.as_primitive[DType.float32]()
            assert_equal(a.null_count, nulls)
            assert_equal(a.get(i), Float32(v), "row " + String(i))
        elif ptype == ParquetType.DOUBLE:
            var a = col.as_primitive[DType.float64]()
            assert_equal(a.null_count, nulls)
            assert_equal(a.get(i), Float64(v), "row " + String(i))
        else:
            var a = col.as_string()
            assert_equal(a.null_count, nulls)
            var s = _str(v) if hit else String("")
            assert_equal(a.get(i), s, "row " + String(i))
    if nulls == 0:
        # No null selected: the column carries no validity bitmap.
        if ptype == ParquetType.BYTE_ARRAY:
            assert_false(Bool(col.as_string().validity))
        elif ptype == ParquetType.INT32:
            assert_false(Bool(col.as_primitive[DType.int32]().validity))


def _types() -> List[ParquetType]:
    return [
        ParquetType.INT32,
        ParquetType.INT64,
        ParquetType.FLOAT,
        ParquetType.DOUBLE,
        ParquetType.BYTE_ARRAY,
    ]


def _ivls(pairs: List[Int]) -> List[SelectionInterval]:
    var out = List[SelectionInterval]()
    for i in range(0, len(pairs), 2):
        out.append(SelectionInterval(UInt32(pairs[i]), UInt32(pairs[i + 1])))
    return out^


def _total(intervals: List[SelectionInterval]) -> Int:
    var t = 0
    for i in range(len(intervals)):
        t += Int(intervals[i].select)
    return t


# --- non-null ------------------------------------------------------------------


def _non_null_case(
    ptype: ParquetType,
    page_rows: List[Int],
    dict_n: Int,
    bw: Int,
    intervals: List[SelectionInterval],
) raises:
    var values = _dict_values(dict_n)
    var d = _decoder(ptype, values)
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    var extents = List[_PageExtent]()
    var rows = List[_Row]()
    var r = 0
    for p in range(len(page_rows)):
        var codes = List[Int]()
        for _ in range(page_rows[p]):
            # Codes 0 .. dict_n + 1: the last two are outside the dictionary
            # whenever the bit width can say them.
            var c = (r * 3 + p) % (dict_n + 2)
            if c >= (1 << bw):
                c = c % dict_n
            codes.append(c)
            rows.append(_Row(False, c))
            r += 1
        pages.append(_buf(_index_page(codes, bw)))
        extents.append(_PageExtent(page_rows[p], Encoding.RLE_DICTIONARY))
    var want = _reference(rows, intervals)
    var col = _gather_dict_encoded(
        ptype, d, pages, Span(extents), Span(intervals), _total(intervals), False
    )
    _check(ptype, col, want, values)


def test_non_null_every_type_every_walk_shape() raises:
    """Pages of 5, 0, 4 and 6 rows. The walks: a select inside the first page;
    a skip across the end of the first page and the empty one (the walk
    advances page by page at the top of its loop); a select that crosses into
    the last page; a select that ends exactly at the end of the last page (the
    walk steps past the last page); a whole-column select; a select of only the
    last page; and no interval at all. Codes include two past a 6-entry
    dictionary, which gather as 0 / an empty string."""
    var page_rows: List[Int] = [5, 0, 4, 6]
    var shapes = List[List[Int]]()
    shapes.append([1, 2, 4, 3, 2, 3])
    shapes.append([0, 15])
    shapes.append([9, 6])
    shapes.append([5, 1])
    shapes.append(List[Int]())
    var types = _types()
    for t in range(len(types)):
        for s in range(len(shapes)):
            _non_null_case(types[t], page_rows, 6, 3, _ivls(shapes[s]))


def test_non_null_wide_codes_and_a_single_entry_dictionary() raises:
    """A 300-entry dictionary at bit width 9 over 3 pages of 70 rows (a
    selection of every row but one in each run), and a one-entry dictionary
    at bit width 0, where every code is 0 whatever the page holds."""
    var types = _types()
    for t in range(len(types)):
        _non_null_case(
            types[t], [70, 70, 70], 300, 9, _ivls([0, 69, 1, 69, 1, 69])
        )
        _non_null_case(types[t], [8, 3], 1, 0, _ivls([2, 7, 1, 1]))


def test_no_pages_and_no_selection_is_empty() raises:
    """No page and no interval: an empty column of each type."""
    var types = _types()
    for t in range(len(types)):
        var d = _decoder(types[t], _dict_values(3))
        var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
        var extents = List[_PageExtent]()
        var intervals = List[SelectionInterval]()
        var col = _gather_dict_encoded(
            types[t], d, pages, Span(extents), Span(intervals), 0, False
        )
        assert_equal(col.length(), 0)
        var dl = Slab[_PageDefLevels]()
        var col2 = _gather_dict_encoded_nullable(
            types[t], d, pages, Span(extents), dl, Span(intervals), 0, False
        )
        assert_equal(col2.length(), 0)


# --- nullable ------------------------------------------------------------------


def _nullable_case(
    ptype: ParquetType,
    page_rows: List[Int],
    null_every: Int,
    intervals: List[SelectionInterval],
) raises:
    """Row r is null when `null_every > 0` and r % null_every == 1."""
    var dict_n = 6
    var bw = 3
    var values = _dict_values(dict_n)
    var d = _decoder(ptype, values)
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    var extents = List[_PageExtent]()
    var dl = Slab[_PageDefLevels]()
    var rows = List[_Row]()
    var r = 0
    for p in range(len(page_rows)):
        var codes = List[Int]()
        var defs = List[UInt8]()
        for _ in range(page_rows[p]):
            if null_every > 0 and r % null_every == 1:
                defs.append(UInt8(0))
                rows.append(_Row(True, 0))
            else:
                var c = (r * 5 + 1) % (dict_n + 2)
                codes.append(c)
                defs.append(UInt8(1))
                rows.append(_Row(False, c))
            r += 1
        var nn = len(codes)
        pages.append(_buf(_index_page(codes, bw)))
        extents.append(_PageExtent(page_rows[p], Encoding.RLE_DICTIONARY))
        dl.append(_PageDefLevels(defs^, nn))
    var want = _reference(rows, intervals)
    var col = _gather_dict_encoded_nullable(
        ptype, d, pages, Span(extents), dl, Span(intervals), _total(intervals),
        False,
    )
    _check(ptype, col, want, values)


def test_nullable_every_type_every_walk_shape() raises:
    """The non-null walks over pages of 5, 0, 4 and 6 rows, with every third
    row null (so a selected null's slot, the value rank past a null, and
    codes outside the dictionary all occur), and with no null at all (no
    validity bitmap)."""
    var page_rows: List[Int] = [5, 0, 4, 6]
    var shapes = List[List[Int]]()
    shapes.append([1, 2, 4, 3, 2, 3])
    shapes.append([0, 15])
    shapes.append([9, 6])
    shapes.append([5, 1])
    var types = _types()
    for t in range(len(types)):
        for s in range(len(shapes)):
            _nullable_case(types[t], page_rows, 3, _ivls(shapes[s]))
            _nullable_case(types[t], page_rows, 0, _ivls(shapes[s]))


def test_nullable_selection_of_only_nulls_and_only_values() raises:
    """Selecting exactly the null rows gives an all-null column; selecting
    around them gives a column with no validity bitmap even though the pages
    hold nulls."""
    var types = _types()
    for t in range(len(types)):
        # Rows 1, 4, 7 are null (null_every = 3).
        _nullable_case(types[t], [9], 3, _ivls([1, 1, 2, 1, 2, 1]))
        _nullable_case(types[t], [9], 3, _ivls([0, 1, 1, 2, 1, 2]))


def test_nullable_rank_past_the_decoded_codes_reads_code_zero() raises:
    """A page whose record says fewer non-null values than its def levels
    set decodes only that many codes; a set row whose rank is past them
    gathers code 0 (dictionary[0])."""
    var values = _dict_values(4)
    var d = _decoder(ParquetType.INT32, values)
    var pages = Slab[SharedAlignedBuffer[HeapRegion]]()
    pages.append(_buf(_index_page([2, 3], 2)))
    var extents: List[_PageExtent] = [_PageExtent(3, Encoding.RLE_DICTIONARY)]
    var dl = Slab[_PageDefLevels]()
    dl.append(_PageDefLevels([UInt8(1), UInt8(1), UInt8(1)], 2))
    var intervals = _ivls([0, 3])
    var col = _gather_dict_encoded_nullable(
        ParquetType.INT32, d, pages, Span(extents), dl, Span(intervals), 3,
        False,
    )
    var a = col.as_primitive[DType.int32]()
    assert_equal(Int(a.get(0)), values[2])
    assert_equal(Int(a.get(1)), values[3])
    assert_equal(Int(a.get(2)), values[0])
    assert_equal(a.null_count, 0)


# --- the helpers ---------------------------------------------------------------


def test_decode_page_keys_counts() raises:
    """`_decode_page_keys` decodes exactly `num_keys` codes (a page may encode
    more), decodes none for a count of 0, and refuses a negative count."""
    var d = _decoder(ParquetType.INT32, _dict_values(8))
    var page = _buf(_index_page([7, 1, 6, 2, 5, 3, 4, 0], 3))
    var keys = _decode_page_keys(d, page, 5)
    assert_equal(keys.length, 5)
    assert_equal(keys.keys.len(), 20)
    var want: List[Int] = [7, 1, 6, 2, 5]
    for i in range(5):
        assert_equal(Int(keys.keys.get_typed[Int32](i)), want[i])
    var none = _decode_page_keys(d, page, 0)
    assert_equal(none.length, 0)
    assert_equal(none.keys.len(), 0)
    var raised = False
    try:
        _ = _decode_page_keys(d, page, -1)
    except e:
        raised = True
        assert_true("negative value count -1" in String(e), String(e))
    assert_true(raised)


def _keys(codes: List[Int]) -> OwnedAlignedBuffer:
    var buf = OwnedAlignedBuffer(max(len(codes) * 4, 1))
    for i in range(len(codes)):
        buf.set_typed[Int32](i, Int32(codes[i]))
    buf.set_length(Int64(len(codes) * 4))
    return buf^


def test_materialize_fixed_width_out_of_range_codes_are_zero() raises:
    """A negative code, a code equal to the dictionary size and one past it
    gather 0; codes inside gather dictionary[code]; the validity and null
    count passed in are the array's. The buffer holds two sentinel entries
    past the 4 the dictionary size admits, so reading entry 4 or 5 shows."""
    var dict_buf = OwnedAlignedBuffer(24)
    for i in range(6):
        dict_buf.set_typed[Int32](i, Int32(100 + i) if i < 4 else Int32(-777))
    dict_buf.set_length(24)
    var validity = Bitmap.create_all_valid(6)
    validity.clear(5)
    var arr = _materialize_fixed_width[DType.int32](
        _keys([3, -1, 4, 0, 5, 2]), 6, dict_buf, 4,
        Optional[Bitmap[HeapRegion]](validity^), 1,
    )
    var want: List[Int] = [103, 0, 0, 100, 0, 102]
    for i in range(6):
        assert_equal(Int(arr.get(i)), want[i], "row " + String(i))
    assert_equal(arr.null_count, 1)
    assert_true(arr.is_null(5))


def test_materialize_byte_array_out_of_range_and_empty_values() raises:
    """Out-of-range codes and empty dictionary entries give empty values
    (nothing copied); the offsets are the running byte totals. The buffers
    hold a fourth entry past the dictionary's length of 3, so reading it
    shows."""
    var strings: List[String] = ["abc", "", "defgh", "SENTINEL"]
    var dict_strings = StringArray.from_strings(strings)
    dict_strings.length = 3
    var arr = _materialize_byte_array(
        _keys([2, 1, -5, 0, 3, 2]), 6, dict_strings,
        Optional[Bitmap[HeapRegion]](None), 0,
    )
    var want: List[String] = ["defgh", "", "", "abc", "", "defgh"]
    for i in range(6):
        assert_equal(arr.get(i), want[i], "row " + String(i))
    assert_equal(arr.data_length, 13)
    assert_equal(arr.null_count, 0)


def test_materialize_byte_array_refuses_bytes_past_int32_offsets() raises:
    """2,049 selections of a 1 MiB dictionary value total 2,049 MiB, past the
    Int32 offsets (2,048 MiB - 1): refused before the data buffer exists. One
    fewer selection (2,048 MiB - 1 MiB) would fit and is not built here."""
    var big = String("")
    for _ in range(1 << 14):
        big += "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    assert_equal(big.byte_length(), 1 << 20)
    var dict_strings = StringArray.from_strings([big])
    var codes = List[Int]()
    for _ in range(2049):
        codes.append(0)
    var raised = False
    try:
        _ = _materialize_byte_array(
            _keys(codes), 2049, dict_strings,
            Optional[Bitmap[HeapRegion]](None), 0,
        )
    except e:
        raised = True
        assert_true(
            "selected values total 2148532224 bytes, past the Int32" in String(e),
            String(e),
        )
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
