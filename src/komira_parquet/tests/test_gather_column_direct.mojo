# Direct tests of `decode_column_with_selection` (gather.mojo), the column
# chunk page walk in front of the selection gathers, on chunks that decode:
# PLAIN and dictionary-encoded pages of INT32, INT64, FLOAT, DOUBLE and
# BYTE_ARRAY, non-null and nullable, uncompressed and SNAPPY, V1 and V2 pages,
# masked pages, an index page, and the Arrow type each annotation re-stamps.
# Chunks are encoded here from parquet-format (parquet.thrift for the Thrift
# Compact page headers, Encodings.md for PLAIN, the RLE / Bit-Packing Hybrid
# levels and the dictionary codes). Expected values come from the definition
# of the gather: walk the (skip, select) intervals over the rows of the
# selected data pages, in order; a row's value is its PLAIN value or
# dictionary[code], or null where its definition level is 0.
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.gather import decode_column_with_selection
from komira_parquet.selection_vector import SelectionInterval

comptime _DATA_PAGE = 0
comptime _INDEX_PAGE = 1
comptime _DICTIONARY_PAGE = 2
comptime _DATA_PAGE_V2 = 3
comptime _PLAIN = 0
comptime _PLAIN_DICTIONARY = 2
comptime _RLE_DICTIONARY = 8
comptime _NONE = -1
comptime _UTF8 = 0
comptime _DATE = 6
comptime _UINT_32 = 13
comptime _UINT_64 = 14
comptime _INT_8 = 15
comptime _TS_MILLIS = 1
comptime _TS_MICROS = 2


# --- encoders (parquet-format: parquet.thrift and Encodings.md) ----------------


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


def _i32_field(mut out: List[UInt8], delta: Int, v: Int):
    """A Thrift Compact i32 field (type 5) with a short-form id delta and a
    zigzag varint value."""
    out.append(UInt8((delta << 4) | 5))
    _uleb(out, (v << 1) ^ (v >> 63))


def _page_header(
    page_type: Int,
    uncompressed: Int,
    compressed: Int,
    num_values: Int,
    encoding: Int,
    def_len: Int,
    rep_len: Int,
    is_compressed: Bool,
) -> List[UInt8]:
    """A PageHeader: fields 1 (type), 2 (uncompressed_page_size), 3
    (compressed_page_size), then the type's header struct: 5
    DataPageHeader, 7 DictionaryPageHeader or 8 DataPageHeaderV2 (an
    INDEX_PAGE has none)."""
    var h = List[UInt8]()
    _i32_field(h, 1, page_type)
    _i32_field(h, 1, uncompressed)
    _i32_field(h, 1, compressed)
    if page_type == 0:
        h.append(UInt8((2 << 4) | 12))
        _i32_field(h, 1, num_values)
        _i32_field(h, 1, encoding)
        _i32_field(h, 1, 3)  # definition_level_encoding: RLE
        _i32_field(h, 1, 3)  # repetition_level_encoding: RLE
        h.append(UInt8(0))
    elif page_type == 2:
        h.append(UInt8((4 << 4) | 12))
        _i32_field(h, 1, num_values)
        _i32_field(h, 1, encoding)
        h.append(UInt8(0))
    elif page_type == 3:
        h.append(UInt8((5 << 4) | 12))
        _i32_field(h, 1, num_values)
        _i32_field(h, 1, 0)  # num_nulls
        _i32_field(h, 1, num_values)  # num_rows
        _i32_field(h, 1, encoding)
        _i32_field(h, 1, def_len)
        _i32_field(h, 1, rep_len)
        # is_compressed: a bool field's value is its type, 1 true, 2 false.
        h.append(UInt8((1 << 4) | (1 if is_compressed else 2)))
        h.append(UInt8(0))
    h.append(UInt8(0))
    return h^


def _value(r: Int) -> Int:
    """Row r's value: distinct and never 0 (a 0 would hide an unwritten slot)."""
    return r * 7 + 3


def _str(v: Int) -> String:
    """The BYTE_ARRAY value for `v`: empty for some, past 64 bytes for some."""
    if v % 5 == 1:
        return String("")
    var out = String("s") + String(v)
    if v % 9 == 4:
        for _ in range(70):
            out += "x"
    return out^


def _encode(ptype: ParquetType, v: Int, mut out: List[UInt8]):
    """PLAIN encoding of value `v` for `ptype` (INT64 in its high bits)."""
    if ptype == ParquetType.INT32:
        _le(out, v, 4)
    elif ptype == ParquetType.INT64:
        _le(out, v << 33, 8)
    elif ptype == ParquetType.FLOAT:
        _le(out, Int(Float32(v).to_bits()), 4)
    elif ptype == ParquetType.DOUBLE:
        _le(out, Int(Float64(v).to_bits()), 8)
    else:
        var s = _str(v)
        _le(out, s.byte_length(), 4)
        var b = s.as_bytes()
        for k in range(len(b)):
            out.append(b[k])


def _levels(levels: List[Int]) -> List[UInt8]:
    """V1 definition levels at bit width 1: a 4-byte length, then one
    bit-packed run (LSB first)."""
    var run = List[UInt8]()
    var groups = (len(levels) + 7) // 8
    _uleb(run, (groups << 1) | 1)
    for g in range(groups):
        var byte = 0
        for b in range(8):
            var i = g * 8 + b
            if i < len(levels) and levels[i] != 0:
                byte |= 1 << b
        run.append(UInt8(byte))
    var out = List[UInt8]()
    _le(out, len(run), 4)
    out.extend(run^)
    return out^


def _codes(codes: List[Int], bw: Int) -> List[UInt8]:
    """A dictionary-index page body: one bit-width byte, then one bit-packed
    run of `codes` (padded with zeros to a multiple of 8), LSB first."""
    var page: List[UInt8] = [UInt8(bw)]
    if len(codes) == 0:
        return page^
    var groups = (len(codes) + 7) // 8
    _uleb(page, (groups << 1) | 1)
    var acc = 0
    var nbits = 0
    for i in range(groups * 8):
        var v = codes[i] if i < len(codes) else 0
        acc |= v << nbits
        nbits += bw
        while nbits >= 8:
            page.append(UInt8(acc & 0xFF))
            acc >>= 8
            nbits -= 8
    if nbits > 0:
        page.append(UInt8(acc & 0xFF))
    return page^


@fieldwise_init
struct _Row(Copyable, Movable):
    var is_null: Bool
    var value: Int


def _body(
    ptype: ParquetType, rows: List[_Row], nullable: Bool, dict_bw: Int
) -> List[UInt8]:
    """A data page body: the def levels when nullable, then the non-null
    rows' values, PLAIN (dict_bw < 0) or as dictionary codes (a value
    `_value(k)` is code k)."""
    var out = List[UInt8]()
    if nullable:
        var levels = List[Int]()
        for i in range(len(rows)):
            levels.append(0 if rows[i].is_null else 1)
        out.extend(_levels(levels))
    if dict_bw < 0:
        for i in range(len(rows)):
            if not rows[i].is_null:
                _encode(ptype, rows[i].value, out)
    else:
        var codes = List[Int]()
        for i in range(len(rows)):
            if not rows[i].is_null:
                codes.append((rows[i].value - 3) // 7)
        out.extend(_codes(codes, dict_bw))
    return out^


def _dict_body(ptype: ParquetType, n: Int) -> List[UInt8]:
    """A dictionary page body: entries `_value(0)` to `_value(n - 1)`, PLAIN."""
    var out = List[UInt8]()
    for k in range(n):
        _encode(ptype, _value(k), out)
    return out^


def _compressed(codec: CompressionCodec, body: List[UInt8]) raises -> List[UInt8]:
    var out = List[UInt8]()
    out.resize(compress_bound(codec, len(body)), UInt8(0))
    var n = compress(codec, Span(body), Span(out))
    out.resize(n, UInt8(0))
    return out^


def _add_page(
    mut chunk: List[UInt8],
    page_type: Int,
    body: List[UInt8],
    num_values: Int,
    encoding: Int,
    codec: CompressionCodec,
    is_compressed: Bool = True,
    def_len: Int = 0,
    rep_len: Int = 0,
) raises:
    """Append one page: its header, then its body, compressed with `codec`
    unless the codec is UNCOMPRESSED or a V2 page says it is not."""
    var payload: List[UInt8]
    if codec == CompressionCodec.UNCOMPRESSED or not is_compressed:
        payload = body.copy()
    else:
        payload = _compressed(codec, body)
    chunk.extend(
        _page_header(
            page_type,
            len(body),
            len(payload),
            num_values,
            encoding,
            def_len,
            rep_len,
            is_compressed,
        )
    )
    chunk.extend(payload^)


def _rows(first: Int, n: Int, null_every: Int) -> List[_Row]:
    """Rows `first` to `first + n - 1`; with null_every > 0, row r is null
    when r % null_every == 0."""
    var out = List[_Row]()
    for r in range(first, first + n):
        if null_every > 0 and r % null_every == 0:
            out.append(_Row(True, 0))
        else:
            out.append(_Row(False, _value(r)))
    return out^


def _dict_rows(first: Int, n: Int, dict_n: Int, null_every: Int) -> List[_Row]:
    """Rows whose values are dictionary entries: row r holds code
    (r * 5 + 1) % dict_n."""
    var out = List[_Row]()
    for r in range(first, first + n):
        if null_every > 0 and r % null_every == 0:
            out.append(_Row(True, 0))
        else:
            out.append(_Row(False, _value((r * 5 + 1) % dict_n)))
    return out^


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


def _decode(
    chunk: List[UInt8],
    ptype: ParquetType,
    codec: CompressionCodec,
    num_values: Int,
    max_def_level: Int,
    converted_type: Int,
    preserve_dict: Bool,
    mask: List[Bool],
    intervals: List[SelectionInterval],
    num_selected: Int,
    timestamp_unit: Int = -1,
) raises -> Optional[Column[HeapRegion]]:
    var data = chunk.copy()
    return decode_column_with_selection(
        Span(data),
        ptype,
        codec,
        num_values,
        max_def_level,
        0,
        converted_type,
        0,
        preserve_dict,
        Span(mask),
        Span(intervals),
        num_selected,
        timestamp_unit,
    )


# --- checks --------------------------------------------------------------------


def _check(ptype: ParquetType, col: Column[HeapRegion], want: List[_Row]) raises:
    """`col` holds each wanted row's value or null, and a validity bitmap
    only when a null was selected."""
    var n = len(want)
    var nulls = 0
    for i in range(n):
        if want[i].is_null:
            nulls += 1
    assert_equal(col.length(), n)
    for i in range(n):
        assert_equal(col.is_null_at(i), want[i].is_null, "row " + String(i))
    if ptype == ParquetType.INT32:
        var a = col.as_primitive[DType.int32]()
        assert_equal(a.null_count, nulls)
        assert_equal(Bool(a.validity), nulls > 0)
        for i in range(n):
            if not want[i].is_null:
                assert_equal(Int(a.get(i)), want[i].value, "row " + String(i))
    elif ptype == ParquetType.INT64:
        var a = col.as_primitive[DType.int64]()
        assert_equal(a.null_count, nulls)
        assert_equal(Bool(a.validity), nulls > 0)
        for i in range(n):
            if not want[i].is_null:
                assert_equal(Int(a.get(i)), want[i].value << 33)
    elif ptype == ParquetType.FLOAT:
        var a = col.as_primitive[DType.float32]()
        assert_equal(a.null_count, nulls)
        assert_equal(Bool(a.validity), nulls > 0)
        for i in range(n):
            if not want[i].is_null:
                assert_equal(a.get(i), Float32(want[i].value))
    elif ptype == ParquetType.DOUBLE:
        var a = col.as_primitive[DType.float64]()
        assert_equal(a.null_count, nulls)
        assert_equal(Bool(a.validity), nulls > 0)
        for i in range(n):
            if not want[i].is_null:
                assert_equal(a.get(i), Float64(want[i].value))
    else:
        assert_equal(col.arrow_type, ArrowType.STRING)
        var a = col.as_string()
        assert_equal(a.null_count, nulls)
        assert_equal(Bool(a.validity), nulls > 0)
        for i in range(n):
            if not want[i].is_null:
                assert_equal(a.get(i), _str(want[i].value), "row " + String(i))


def _types() -> List[ParquetType]:
    return [
        ParquetType.INT32,
        ParquetType.INT64,
        ParquetType.FLOAT,
        ParquetType.DOUBLE,
        ParquetType.BYTE_ARRAY,
    ]


def _codecs() -> List[CompressionCodec]:
    return [CompressionCodec.UNCOMPRESSED, CompressionCodec.SNAPPY]


def _annotation(ptype: ParquetType) -> Int:
    """UTF8 on BYTE_ARRAY, so the column stays STRING; none elsewhere."""
    return _UTF8 if ptype == ParquetType.BYTE_ARRAY else _NONE


def _concat(a: List[_Row], b: List[_Row]) -> List[_Row]:
    var out = a.copy()
    for i in range(len(b)):
        out.append(b[i].copy())
    return out^


# --- PLAIN ---------------------------------------------------------------------


def test_plain_every_type_and_codec_skips_a_masked_page() raises:
    """Catches: a masked page decoded (its rows would shift every later
    row), a data page counted twice, a compressed page not decompressed or
    decompressed into the wrong size, and the V1 and V2 page kinds."""
    var types = _types()
    var codecs = _codecs()
    for v2 in range(2):
        var kind = _DATA_PAGE_V2 if v2 == 1 else _DATA_PAGE
        for c in range(len(codecs)):
            for t in range(len(types)):
                var p0 = _rows(0, 4, 0)
                var p1 = _rows(4, 3, 0)
                var p2 = _rows(7, 5, 0)
                var chunk = List[UInt8]()
                _add_page(chunk, kind, _body(types[t], p0, False, -1), 4, _PLAIN, codecs[c])
                _add_page(chunk, kind, _body(types[t], p1, False, -1), 3, _PLAIN, codecs[c])
                _add_page(chunk, kind, _body(types[t], p2, False, -1), 5, _PLAIN, codecs[c])
                var ivls = _ivls([1, 2, 3, 3])
                var got = _decode(
                    chunk, types[t], codecs[c], 9, 0, _annotation(types[t]),
                    False, [True, False, True], ivls, _total(ivls),
                )
                assert_true(Bool(got))
                _check(types[t], got.value(), _reference(_concat(p0, p2), ivls))


def test_v2_page_whose_values_are_not_compressed() raises:
    """Catches: a V2 page whose header says its values are not compressed
    run through the column's codec (here SNAPPY), which decoded raw PLAIN
    bytes as a SNAPPY stream. The second page is compressed, so the flag is
    read per page."""
    var types = _types()
    for t in range(len(types)):
        var p0 = _rows(0, 6, 0)
        var p1 = _rows(6, 4, 0)
        var chunk = List[UInt8]()
        _add_page(
            chunk, _DATA_PAGE_V2, _body(types[t], p0, False, -1), 6, _PLAIN,
            CompressionCodec.SNAPPY, is_compressed=False,
        )
        _add_page(
            chunk, _DATA_PAGE_V2, _body(types[t], p1, False, -1), 4, _PLAIN,
            CompressionCodec.SNAPPY,
        )
        var ivls = _ivls([2, 5, 1, 2])
        var got = _decode(
            chunk, types[t], CompressionCodec.SNAPPY, 10, 0,
            _annotation(types[t]), False, [True, True], ivls, _total(ivls),
        )
        assert_true(Bool(got))
        _check(types[t], got.value(), _reference(_concat(p0, p1), ivls))


def test_an_index_page_is_not_a_data_page() raises:
    """Catches: an INDEX_PAGE counted against the data-page mask (the mask
    would then pick the masked page), or its body read as a page header."""
    var p0 = _rows(0, 3, 0)
    var p1 = _rows(3, 4, 0)
    var p2 = _rows(7, 2, 0)
    var chunk = List[UInt8]()
    var ptype = ParquetType.INT64
    _add_page(chunk, _DATA_PAGE, _body(ptype, p0, False, -1), 3, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _add_page(chunk, _INDEX_PAGE, [UInt8(0xFF), UInt8(0x00), UInt8(0x15)], 0, 0, CompressionCodec.UNCOMPRESSED)
    _add_page(chunk, _DATA_PAGE, _body(ptype, p1, False, -1), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _add_page(chunk, _DATA_PAGE, _body(ptype, p2, False, -1), 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var ivls = _ivls([0, 5])
    var got = _decode(
        chunk, ptype, CompressionCodec.UNCOMPRESSED, 5, 0, _NONE, False,
        [True, False, True], ivls, 5,
    )
    assert_true(Bool(got))
    _check(ptype, got.value(), _reference(_concat(p0, p2), ivls))


def test_a_data_page_past_the_mask_is_skipped() raises:
    """Catches: a data page past the end of page_mask decoded. The second
    page is DELTA_BINARY_PACKED, which the gather does not take, so decoding
    it would return None."""
    var p0 = _rows(0, 4, 0)
    var chunk = List[UInt8]()
    var ptype = ParquetType.INT32
    _add_page(chunk, _DATA_PAGE, _body(ptype, p0, False, -1), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _add_page(chunk, _DATA_PAGE, [UInt8(0)], 1, 5, CompressionCodec.UNCOMPRESSED)
    var ivls = _ivls([0, 4])
    # A value count past every page, so the walk reaches the second page.
    var got = _decode(
        chunk, ptype, CompressionCodec.UNCOMPRESSED, 100, 0, _NONE, False,
        [True], ivls, 4,
    )
    assert_true(Bool(got))
    _check(ptype, got.value(), _reference(p0, ivls))


def test_the_walk_stops_after_the_selected_values() raises:
    """Catches: the walk not stopping once the selected pages' values are
    collected. What follows is a page header whose body runs past the chunk,
    which returns None when read."""
    var p0 = _rows(0, 4, 0)
    var chunk = List[UInt8]()
    var ptype = ParquetType.FLOAT
    _add_page(chunk, _DATA_PAGE, _body(ptype, p0, False, -1), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
    chunk.extend(_page_header(_DATA_PAGE, 1000, 1000, 4, _PLAIN, 0, 0, True))
    var ivls = _ivls([1, 3])
    var got = _decode(
        chunk, ptype, CompressionCodec.UNCOMPRESSED, 4, 0, _NONE, False,
        [True, True], ivls, 3,
    )
    assert_true(Bool(got))
    _check(ptype, got.value(), _reference(p0, ivls))


def test_nothing_selected_is_an_empty_column() raises:
    """Catches: an empty selection over no collected page not returned as an
    empty column of the column's type."""
    var types = _types()
    for t in range(len(types)):
        var chunk = List[UInt8]()
        _add_page(chunk, _DATA_PAGE, _body(types[t], _rows(0, 3, 0), False, -1), 3, _PLAIN, CompressionCodec.UNCOMPRESSED)
        var got = _decode(
            chunk, types[t], CompressionCodec.UNCOMPRESSED, 0, 0,
            _annotation(types[t]), False, [False], List[SelectionInterval](), 0,
        )
        assert_true(Bool(got))
        _check(types[t], got.value(), List[_Row]())


def test_pages_with_an_empty_body_are_collected() raises:
    """Catches: an empty uncompressed page (no body byte) copied or refused:
    a PLAIN data page of no row before one of three, and a dictionary page of
    no entry before a dictionary-encoded page of no row."""
    var p1 = _rows(0, 3, 0)
    var chunk = List[UInt8]()
    _add_page(chunk, _DATA_PAGE, List[UInt8](), 0, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _add_page(chunk, _DATA_PAGE, _body(ParquetType.INT32, p1, False, -1), 3, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var ivls = _ivls([1, 2])
    var got = _decode(
        chunk, ParquetType.INT32, CompressionCodec.UNCOMPRESSED, 3, 0, _NONE,
        False, [True, True], ivls, 2,
    )
    assert_true(Bool(got))
    _check(ParquetType.INT32, got.value(), _reference(p1, ivls))
    var dchunk = List[UInt8]()
    _add_page(dchunk, _DICTIONARY_PAGE, List[UInt8](), 0, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _add_page(dchunk, _DATA_PAGE, [UInt8(0)], 0, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    # A value count past every page, so the walk reads both.
    var empty = _decode(
        dchunk, ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 1, 0,
        _UTF8, False, [True], List[SelectionInterval](), 0,
    )
    assert_true(Bool(empty))
    _check(ParquetType.BYTE_ARRAY, empty.value(), List[_Row]())


# --- nullable ------------------------------------------------------------------


def test_nullable_plain_every_type_and_codec() raises:
    """Catches: def levels left at the front of the value stream, a null row
    not marked, and a value read at its row instead of its rank."""
    var types = _types()
    var codecs = _codecs()
    for c in range(len(codecs)):
        for t in range(len(types)):
            var p0 = _rows(0, 6, 3)
            var p1 = _rows(6, 5, 3)
            var chunk = List[UInt8]()
            _add_page(chunk, _DATA_PAGE, _body(types[t], p0, True, -1), 6, _PLAIN, codecs[c])
            _add_page(chunk, _DATA_PAGE, _body(types[t], p1, True, -1), 5, _PLAIN, codecs[c])
            var ivls = _ivls([0, 4, 1, 6])
            var got = _decode(
                chunk, types[t], codecs[c], 11, 1, _annotation(types[t]),
                False, [True, True], ivls, _total(ivls),
            )
            assert_true(Bool(got))
            _check(types[t], got.value(), _reference(_concat(p0, p1), ivls))


def test_nullable_column_without_a_null() raises:
    """Catches: a nullable column whose pages hold no null returned with a
    validity bitmap, PLAIN and dictionary-encoded."""
    var types = _types()
    for t in range(len(types)):
        for use_dict in range(2):
            var chunk = List[UInt8]()
            var p0: List[_Row]
            if use_dict == 1:
                _add_page(chunk, _DICTIONARY_PAGE, _dict_body(types[t], 9), 9, _PLAIN, CompressionCodec.UNCOMPRESSED)
                p0 = _dict_rows(0, 7, 9, 0)
                _add_page(chunk, _DATA_PAGE, _body(types[t], p0, True, 4), 7, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
            else:
                p0 = _rows(0, 7, 0)
                _add_page(chunk, _DATA_PAGE, _body(types[t], p0, True, -1), 7, _PLAIN, CompressionCodec.UNCOMPRESSED)
            var ivls = _ivls([1, 5])
            var got = _decode(
                chunk, types[t], CompressionCodec.UNCOMPRESSED, 7, 1,
                _annotation(types[t]), False, [True], ivls, 5,
            )
            assert_true(Bool(got))
            _check(types[t], got.value(), _reference(p0, ivls))


# --- dictionary ----------------------------------------------------------------


def test_dictionary_every_type_codec_and_nullability() raises:
    """Catches: the dictionary page not loaded for the column's type, a
    compressed dictionary page not decompressed, codes resolved against the
    wrong entries, PLAIN_DICTIONARY not taken as dictionary-encoded, and
    the nullable key stream (codes of non-null rows only) misread."""
    var types = _types()
    var codecs = _codecs()
    for c in range(len(codecs)):
        for t in range(len(types)):
            for nullable in range(2):
                var enc = _PLAIN_DICTIONARY if (t + nullable) % 2 == 0 else _RLE_DICTIONARY
                var every = 3 if nullable == 1 else 0
                var p0 = _dict_rows(0, 6, 12, every)
                var p1 = _dict_rows(6, 5, 12, every)
                var chunk = List[UInt8]()
                _add_page(chunk, _DICTIONARY_PAGE, _dict_body(types[t], 12), 12, _PLAIN, codecs[c])
                _add_page(chunk, _DATA_PAGE, _body(types[t], p0, nullable == 1, 4), 6, enc, codecs[c])
                _add_page(chunk, _DATA_PAGE, _body(types[t], p1, nullable == 1, 4), 5, enc, codecs[c])
                var ivls = _ivls([1, 3, 2, 4])
                var got = _decode(
                    chunk, types[t], codecs[c], 11, nullable,
                    _annotation(types[t]), False, [True, True], ivls,
                    _total(ivls),
                )
                assert_true(Bool(got))
                _check(types[t], got.value(), _reference(_concat(p0, p1), ivls))


# --- annotations ---------------------------------------------------------------


def _layout_chunk(
    ptype: ParquetType, layout: Int, mut rows: List[_Row]
) raises -> List[UInt8]:
    """Layout 0: PLAIN; 1: PLAIN, nullable with nulls; 2: dictionary;
    3: dictionary, nullable with nulls. Six rows, one page."""
    var chunk = List[UInt8]()
    var nullable = layout == 1 or layout == 3
    var every = 4 if nullable else 0
    if layout >= 2:
        _add_page(chunk, _DICTIONARY_PAGE, _dict_body(ptype, 8), 8, _PLAIN, CompressionCodec.UNCOMPRESSED)
        rows = _dict_rows(0, 6, 8, every)
        _add_page(chunk, _DATA_PAGE, _body(ptype, rows, nullable, 3), 6, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    else:
        rows = _rows(0, 6, every)
        _add_page(chunk, _DATA_PAGE, _body(ptype, rows, nullable, -1), 6, _PLAIN, CompressionCodec.UNCOMPRESSED)
    return chunk^


@fieldwise_init
struct _Annotated(Copyable, Movable):
    var ptype: ParquetType
    var converted_type: Int
    var timestamp_unit: Int
    var want: ArrowType


def test_annotations_restamp_every_gathered_column() raises:
    """Catches: an annotation applied on the PLAIN fixed-width path only.
    A dictionary-encoded UINT_32, DATE, INT_8, UINT_64 or TIMESTAMP column
    came back as its bare signed type, and an unannotated BYTE_ARRAY column
    (PLAIN or dictionary) as STRING instead of BINARY."""
    var cases: List[_Annotated] = [
        _Annotated(ParquetType.INT32, _UINT_32, -1, ArrowType.UINT32),
        _Annotated(ParquetType.INT32, _DATE, -1, ArrowType.DATE32),
        _Annotated(ParquetType.INT32, _INT_8, -1, ArrowType.INT8),
        _Annotated(ParquetType.INT32, _NONE, -1, ArrowType.INT32),
        _Annotated(ParquetType.INT64, _UINT_64, -1, ArrowType.UINT64),
        _Annotated(ParquetType.INT64, _NONE, _TS_MICROS, ArrowType.TIMESTAMP_US),
        _Annotated(ParquetType.INT64, _NONE, _TS_MILLIS, ArrowType.TIMESTAMP_MS),
        _Annotated(ParquetType.BYTE_ARRAY, _NONE, -1, ArrowType.BINARY),
        _Annotated(ParquetType.BYTE_ARRAY, _UTF8, -1, ArrowType.STRING),
    ]
    for i in range(len(cases)):
        ref k = cases[i]
        for layout in range(4):
            var rows = List[_Row]()
            var chunk = _layout_chunk(k.ptype, layout, rows)
            var ivls = _ivls([1, 4])
            var got = _decode(
                chunk, k.ptype, CompressionCodec.UNCOMPRESSED, 6,
                1 if layout % 2 == 1 else 0, k.converted_type, False, [True],
                ivls, 4, k.timestamp_unit,
            )
            assert_true(Bool(got))
            ref col = got.value()
            assert_equal(
                col.arrow_type,
                k.want,
                "case " + String(i) + " layout " + String(layout),
            )
            var want = _reference(rows, ivls)
            assert_equal(col.length(), 4)
            for r in range(4):
                assert_equal(col.is_null_at(r), want[r].is_null)
            if k.want == ArrowType.INT8:
                # INT_8 narrows the storage: each value is the INT32's low byte.
                var a = col.as_primitive[DType.int8]()
                for r in range(4):
                    if not want[r].is_null:
                        assert_equal(Int(a.get(r)), want[r].value)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
