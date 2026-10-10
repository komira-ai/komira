# Direct tests of `decode_column_with_selection` (gather.mojo) on chunks it
# hands back to the caller: the column and page shapes it does not gather
# and the malformed chunks it does not decode (None, which the caller must
# handle), the malformed headers it raises on, and the gathers' refusals,
# which it passes on. Chunks are encoded here from
# parquet-format (parquet.thrift for the Thrift Compact page headers,
# Encodings.md for PLAIN, the RLE / Bit-Packing Hybrid levels and the
# dictionary codes).
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_arrow.column import Column
from komira_buffer.heap_region import HeapRegion
from komira_parquet_api.types import CompressionCodec, ParquetType
from komira_parquet_codec.compression import compress, compress_bound

from komira_parquet.gather import decode_column_with_selection
from komira_parquet.selection_vector import SelectionInterval

comptime _DATA_PAGE = 0
comptime _DICTIONARY_PAGE = 2
comptime _DATA_PAGE_V2 = 3
comptime _PLAIN = 0
comptime _RLE_DICTIONARY = 8
comptime _NONE = -1
comptime _DECIMAL = 5


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


def _plain_chunk(ptype: ParquetType, n: Int) raises -> List[UInt8]:
    var chunk = List[UInt8]()
    _add_page(chunk, _DATA_PAGE, _body(ptype, _rows(0, n, 0), False, -1), n, _PLAIN, CompressionCodec.UNCOMPRESSED)
    return chunk^


def _none(
    chunk: List[UInt8],
    ptype: ParquetType,
    num_values: Int,
    max_def_level: Int,
    converted_type: Int,
    mask: List[Bool],
    intervals: List[SelectionInterval],
    why: String,
    preserve_dict: Bool = False,
) raises:
    var got = _decode(
        chunk, ptype, CompressionCodec.UNCOMPRESSED, num_values,
        max_def_level, converted_type, preserve_dict, mask, intervals,
        _total(intervals),
    )
    assert_false(Bool(got), why)


def _raises_with(
    chunk: List[UInt8],
    ptype: ParquetType,
    num_values: Int,
    max_def_level: Int,
    intervals: List[SelectionInterval],
    num_selected: Int,
    needle: String,
) raises:
    var raised = False
    try:
        _ = _decode(
            chunk, ptype, CompressionCodec.UNCOMPRESSED, num_values,
            max_def_level, _NONE, False, [True, True, True], intervals,
            num_selected,
        )
    except e:
        raised = True
        assert_true(String(e).find(needle) >= 0, String(e))
    assert_true(raised, "no error; wanted: " + needle)


# --- columns the gather does not take ------------------------------------------


def test_unsupported_columns_return_none() raises:
    """Catches: a gate removed. A nested column (max_def_level 2), a DECIMAL
    INT32 or INT64 column (it must surface as Decimal128), BOOLEAN and INT96
    (no gather) would be gathered or refused instead of handed back.
    FIXED_LEN_BYTE_ARRAY is handed back by its own gate and by the type list
    after it."""
    var ivls = _ivls([0, 2])
    var chunk = _plain_chunk(ParquetType.INT32, 4)
    _none(chunk, ParquetType.INT32, 4, 2, _NONE, [True], ivls, "nested")
    _none(chunk, ParquetType.INT32, 4, 0, _DECIMAL, [True], ivls, "DECIMAL INT32")
    _none(chunk, ParquetType.INT32, 4, 1, _DECIMAL, [True], ivls, "DECIMAL nullable")
    var c64 = _plain_chunk(ParquetType.INT64, 4)
    _none(c64, ParquetType.INT64, 4, 0, _DECIMAL, [True], ivls, "DECIMAL INT64")
    _none(chunk, ParquetType.BOOLEAN, 4, 0, _NONE, [True], ivls, "BOOLEAN")
    _none(chunk, ParquetType.INT96, 4, 0, _NONE, [True], ivls, "INT96")
    _none(chunk, ParquetType.FIXED_LEN_BYTE_ARRAY, 4, 0, _NONE, [True], ivls, "FLBA")


def test_unsupported_encodings_return_none() raises:
    """Catches: a selected DELTA_BINARY_PACKED (5), DELTA_LENGTH_BYTE_ARRAY
    (6) or BYTE_STREAM_SPLIT (9) page gathered as PLAIN."""
    var encodings: List[Int] = [5, 6, 9]
    for i in range(len(encodings)):
        var chunk = List[UInt8]()
        var body = _body(ParquetType.INT32, _rows(0, 4, 0), False, -1)
        _add_page(chunk, _DATA_PAGE, body, 4, encodings[i], CompressionCodec.UNCOMPRESSED)
        _none(chunk, ParquetType.INT32, 4, 0, _NONE, [True], _ivls([0, 4]), "encoding " + String(encodings[i]))


def test_v2_page_with_levels_returns_none() raises:
    """Catches: a V2 page with definition or repetition level bytes gathered
    with its levels read as values."""
    for which in range(2):
        var chunk = List[UInt8]()
        var body: List[UInt8] = [UInt8(0), UInt8(0)]
        body.extend(_body(ParquetType.INT32, _rows(0, 4, 0), False, -1))
        _add_page(
            chunk, _DATA_PAGE_V2, body, 4, _PLAIN,
            CompressionCodec.UNCOMPRESSED,
            def_len=2 if which == 0 else 0, rep_len=2 if which == 1 else 0,
        )
        _none(chunk, ParquetType.INT32, 4, 0, _NONE, [True], _ivls([0, 4]), "V2 levels " + String(which))


def test_mixed_encodings_and_kept_dictionaries_return_none() raises:
    """Catches: selected pages of two encodings gathered by the first one's
    gather, and preserve_dict on a dictionary-encoded column ignored. A PLAIN
    column with preserve_dict is still gathered."""
    var chunk = List[UInt8]()
    var ptype = ParquetType.INT64
    _add_page(chunk, _DICTIONARY_PAGE, _dict_body(ptype, 4), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _add_page(chunk, _DATA_PAGE, _body(ptype, _dict_rows(0, 3, 4, 0), False, 2), 3, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    _add_page(chunk, _DATA_PAGE, _body(ptype, _rows(3, 3, 0), False, -1), 3, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _none(chunk, ptype, 6, 0, _NONE, [True, True], _ivls([0, 6]), "mixed")
    # Masking the PLAIN page leaves one encoding.
    var one = _decode(
        chunk, ptype, CompressionCodec.UNCOMPRESSED, 3, 0, _NONE, False,
        [True, False], _ivls([0, 3]), 3,
    )
    assert_true(Bool(one))
    _none(chunk, ptype, 3, 0, _NONE, [True, False], _ivls([0, 3]), "preserve_dict", preserve_dict=True)
    var plain = _plain_chunk(ptype, 3)
    var kept = _decode(
        plain, ptype, CompressionCodec.UNCOMPRESSED, 3, 0, _NONE, True,
        [True], _ivls([0, 3]), 3,
    )
    assert_true(Bool(kept))
    assert_equal(kept.value().length(), 3)


# --- malformed chunks ----------------------------------------------------------


def test_a_page_past_the_chunk_end_returns_none() raises:
    """Catches: a page whose declared size runs past the chunk read past it,
    a data page and a dictionary page."""
    for kind in range(2):
        var chunk = List[UInt8]()
        var page_type = _DATA_PAGE if kind == 0 else _DICTIONARY_PAGE
        var body = _body(ParquetType.INT32, _rows(0, 4, 0), False, -1)
        chunk.extend(_page_header(page_type, 17, 17, 4, _PLAIN, 0, 0, True))
        chunk.extend(body^)
        _none(chunk, ParquetType.INT32, 4, 0, _NONE, [True], _ivls([0, 4]), "kind " + String(kind))


def test_dictionary_codes_without_a_dictionary_page_return_none() raises:
    """Catches: a dictionary-encoded page gathered with no dictionary loaded."""
    var chunk = List[UInt8]()
    _add_page(chunk, _DATA_PAGE, _body(ParquetType.INT32, _dict_rows(0, 4, 4, 0), False, 2), 4, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    _none(chunk, ParquetType.INT32, 4, 0, _NONE, [True], _ivls([0, 4]), "no dictionary")


def test_short_fixed_width_dictionary_page_returns_none() raises:
    """Catches: the dictionary page count check removed or a type given the
    wrong width: a page declaring one entry more than its bytes hold is
    handed back (an INT64 page checked at width 4 would pass the check and
    reach the decoder). A BYTE_ARRAY page has no fixed width; its decoder
    refuses the same mistake."""
    var types: List[ParquetType] = [
        ParquetType.INT32, ParquetType.INT64, ParquetType.FLOAT, ParquetType.DOUBLE,
    ]
    for t in range(len(types)):
        var chunk = List[UInt8]()
        _add_page(chunk, _DICTIONARY_PAGE, _dict_body(types[t], 3), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
        _add_page(chunk, _DATA_PAGE, _body(types[t], _dict_rows(0, 4, 3, 0), False, 2), 4, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
        _none(chunk, types[t], 4, 0, _NONE, [True], _ivls([0, 4]), "short dictionary " + String(t))
    var chunk = List[UInt8]()
    _add_page(chunk, _DICTIONARY_PAGE, _dict_body(ParquetType.BYTE_ARRAY, 3), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _add_page(chunk, _DATA_PAGE, _body(ParquetType.BYTE_ARRAY, _dict_rows(0, 4, 3, 0), False, 2), 4, _RLE_DICTIONARY, CompressionCodec.UNCOMPRESSED)
    var raised = False
    try:
        _ = _decode(
            chunk, ParquetType.BYTE_ARRAY, CompressionCodec.UNCOMPRESSED, 4,
            0, 0, False, [True], _ivls([0, 4]), 4,
        )
    except:
        raised = True
    assert_true(raised)


def test_nullable_page_shorter_than_its_levels_returns_none() raises:
    """Catches: a nullable page under 4 bytes, or one whose level length runs
    past the page, read as levels."""
    var short = List[UInt8]()
    _add_page(short, _DATA_PAGE, [UInt8(2), UInt8(0), UInt8(0)], 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _none(short, ParquetType.INT32, 2, 1, _NONE, [True], _ivls([0, 2]), "under 4 bytes")
    var over = List[UInt8]()
    var body = List[UInt8]()
    _le(body, 100, 4)
    for _ in range(10):
        body.append(UInt8(0))
    _add_page(over, _DATA_PAGE, body, 2, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _none(over, ParquetType.INT32, 2, 1, _NONE, [True], _ivls([0, 2]), "levels past the page")


def test_nullable_page_of_only_nulls_is_gathered() raises:
    """Catches: a page whose levels end exactly at the page end (no value
    follows: every row null) handed back as malformed."""
    var chunk = List[UInt8]()
    var rows = _rows(0, 5, 1)
    _add_page(chunk, _DATA_PAGE, _body(ParquetType.DOUBLE, rows, True, -1), 5, _PLAIN, CompressionCodec.UNCOMPRESSED)
    var got = _decode(
        chunk, ParquetType.DOUBLE, CompressionCodec.UNCOMPRESSED, 5, 1,
        _NONE, False, [True], _ivls([1, 3]), 3,
    )
    assert_true(Bool(got))
    ref col = got.value()
    assert_equal(col.length(), 3)
    for i in range(3):
        assert_true(col.is_null_at(i))


def test_selected_rows_without_a_collected_page_return_none() raises:
    """Catches: rows selected from a chunk whose pages are all masked
    gathered (into a refusal) instead of handed back."""
    var chunk = _plain_chunk(ParquetType.INT32, 4)
    _none(chunk, ParquetType.INT32, 0, 0, _NONE, [False], _ivls([0, 2]), "nothing collected")


def test_malformed_header_and_gather_refusals_are_raised() raises:
    """Catches: an error swallowed on the way out: a page header cut short
    (the parser's), num_selected that is not the intervals' total and
    intervals past the last page (the gather's)."""
    _raises_with([UInt8(0x15)], ParquetType.INT32, 4, 0, _ivls([0, 1]), 1, "")
    var chunk = _plain_chunk(ParquetType.INT32, 4)
    _raises_with(chunk, ParquetType.INT32, 4, 0, _ivls([0, 2]), 3, "select 2 rows, not num_selected = 3")
    _raises_with(chunk, ParquetType.INT32, 4, 0, _ivls([2, 4]), 4, "2 of 4 selected rows exist")
    var nullable = List[UInt8]()
    _add_page(nullable, _DATA_PAGE, _body(ParquetType.INT32, _rows(0, 4, 2), True, -1), 4, _PLAIN, CompressionCodec.UNCOMPRESSED)
    _raises_with(nullable, ParquetType.INT32, 4, 1, _ivls([2, 4]), 4, "2 of 4 selected rows exist")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
