# =============================================================================
# Every page of Parquet files pyarrow wrote, through the codec dispatch
# =============================================================================
#
# The fixtures are in tests/fixtures/parquet (staged at parquet/), written by
# pyarrow's parquet-cpp writer; gen_pyarrow_fixtures.py beside them is their
# provenance and SHA256SUMS pins their bytes. Each file's created_by names the
# writer: "parquet-cpp-arrow version 24.0.0" for all but
# pyarrow_page_crc_zstd_v2.parquet ("... 25.0.0").
#
# The file structure is walked here, by a compact-Thrift reader written in
# this file (parquet.thrift's FileMetaData, RowGroup, ColumnChunk,
# ColumnMetaData and PageHeader fields, by field id), not by komira: komira
# has no Parquet footer parser to cross-check against (komira_parquet_api
# holds the metadata structs and decodes no byte). Only the page bodies go
# through komira, by `decompress`, the codec dispatch.
#
# Asserted for every file (`_walk`):
#   - "PAR1" at both ends; the 4-byte footer length points at a FileMetaData
#     that ends exactly at the length word.
#   - The row groups' rows add up to num_rows; each row group has one column
#     chunk per leaf of the schema, none in an external file.
#   - The column chunks tile the file: the first starts after the leading
#     magic, each starts where the previous ended, the last ends where the
#     footer starts (pyarrow writes no page index or bloom filter by default).
#   - Each chunk's pages tile it (its total_compressed_size); the sum of
#     header + uncompressed_page_size over its pages is its
#     total_uncompressed_size; a dictionary page comes first and only at
#     dictionary_page_offset, the first data page sits at data_page_offset;
#     the data pages' num_values add up to the chunk's num_values, which is
#     the row group's row count (every column here is flat).
#   - Each page body, decompressed by the dispatch into a buffer of exactly
#     uncompressed_page_size bytes, fills it exactly. A DATA_PAGE_V2 body's
#     level bytes are not compressed and are copied; an uncompressed page's
#     two sizes agree.
#   - A page whose header carries a crc (field 4) matches the CRC-32 of its
#     body as written. Parquet's page checksum is the standard CRC-32 of gzip
#     and zlib (parquet.thrift, PageHeader.crc), so it is computed with libz's
#     crc32 (komira_zlib), not komira_parquet_codec's crc32c.
#
# Asserted per file, from the generator's data and the Parquet encodings
# (expected values are never komira's own output):
#   - pyarrow_gzip_plain: GZIP, two PLAIN v1 data pages; the decoded values
#     are id 1..5 and value 10.5..50.5.
#   - pyarrow_int96_ts: the INT96 physical type, three 12-byte values
#     (nanoseconds of the day, then the Julian day) for 0 ns, one day and one
#     second after the epoch.
#   - pyarrow_multi_dict_page: SNAPPY, 6 row groups, each chunk opening with
#     its own dictionary page; the dictionaries are the row group's ids and
#     the five labels.
#   - pyarrow_zero_row: no rows, a row group whose chunks hold no page, and
#     a footer right after the leading magic.
#   - pyarrow_page_crc_zstd_v2: ZSTD, DATA_PAGE_V2, every page carrying a
#     crc; the PLAIN id pages decode to the row numbers in order. A body with
#     one byte flipped fails the check (the check is not vacuous).
#   - lineitem_pyarrow_500 (SNAPPY, row groups of 200/200/100) against
#     lineitem_pyarrow_500_uncompressed (one row group of 500): same columns;
#     the row groups do not line up, so pages are not compared one to one.
#     What is compared is the first row group's dictionary page of every
#     column: decompressed, it is a byte prefix of the uncompressed file's
#     dictionary page, and equal to it when the two hold as many values.
#     parquet-cpp's dictionary encoder numbers values in the order it first
#     meets them and a PLAIN dictionary page lists them in that order, so the
#     first 200 rows' dictionary is the first entries of the 500 rows'.
#
# Not covered: BROTLI. The codec decision for Brotli pages is still open,
# so no Brotli fixture is committed and no Brotli page is read here.
# =============================================================================

from std.memory import bitcast
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_parquet_api import CompressionCodec, PageType
from komira_parquet_codec.compression import decompress
from komira_zlib import zlib_crc32

comptime _DIR = "parquet/"
comptime _ARROW_24 = "parquet-cpp-arrow version 24.0.0"
comptime _ARROW_25 = "parquet-cpp-arrow version 25.0.0"

# Thrift compact protocol type ids.
comptime _CT_STOP = 0
comptime _CT_TRUE = 1
comptime _CT_FALSE = 2
comptime _CT_BYTE = 3
comptime _CT_I16 = 4
comptime _CT_I32 = 5
comptime _CT_I64 = 6
comptime _CT_DOUBLE = 7
comptime _CT_BINARY = 8
comptime _CT_LIST = 9
comptime _CT_SET = 10
comptime _CT_MAP = 11
comptime _CT_STRUCT = 12

comptime _MAX_DEPTH = 32


# ---- compact Thrift ---------------------------------------------------------


def _need(b: Span[UInt8, _], pos: Int, n: Int, what: String) raises:
    if n < 0 or pos < 0 or pos + n > len(b):
        raise Error(
            what + ": " + String(n) + " bytes at " + String(pos)
            + " run past the " + String(len(b)) + "-byte file"
        )


def _varint(b: Span[UInt8, _], mut pos: Int) raises -> UInt64:
    var v: UInt64 = 0
    var shift = 0
    while True:
        _need(b, pos, 1, "varint")
        if shift > 63:
            raise Error("varint longer than 10 bytes at " + String(pos))
        var x = b[pos]
        pos += 1
        v |= UInt64(x & 0x7F) << UInt64(shift)
        if x < 0x80:
            return v
        shift += 7


def _zigzag(v: UInt64) -> Int:
    return Int(v >> 1) ^ -Int(v & 1)


def _int(b: Span[UInt8, _], mut pos: Int, t: Int) raises -> Int:
    if t == _CT_BYTE:
        _need(b, pos, 1, "byte")
        var x = Int(b[pos])
        pos += 1
        return x - 256 if x >= 128 else x
    if t == _CT_I16 or t == _CT_I32 or t == _CT_I64:
        return _zigzag(_varint(b, pos))
    raise Error("field of type " + String(t) + " where an integer belongs")


def _field(b: Span[UInt8, _], mut pos: Int, mut fid: Int) raises -> Int:
    """Reads a field header; returns its type (`_CT_STOP` at the end)."""
    _need(b, pos, 1, "field header")
    var h = Int(b[pos])
    pos += 1
    var t = h & 0x0F
    if t == _CT_STOP:
        if h != 0:
            raise Error("stop byte " + String(h) + " is not 0")
        return _CT_STOP
    if h >> 4 != 0:
        fid += h >> 4
    else:
        fid = _zigzag(_varint(b, pos))
    return t


def _list(b: Span[UInt8, _], mut pos: Int, mut elem: Int) raises -> Int:
    """Reads a list or set header; returns its size, sets its element type."""
    _need(b, pos, 1, "list header")
    var h = Int(b[pos])
    pos += 1
    elem = h & 0x0F
    var n = h >> 4
    if n == 15:
        n = Int(_varint(b, pos))
    return n


def _binary(b: Span[UInt8, _], mut pos: Int) raises -> Int:
    """Skips a binary value; returns where its bytes start (they end at pos).
    """
    var n = Int(_varint(b, pos))
    _need(b, pos, n, "binary")
    var start = pos
    pos += n
    return start


def _skip_elem(b: Span[UInt8, _], mut pos: Int, t: Int, depth: Int) raises:
    # In a container a bool is one byte, not folded into a field header.
    if t == _CT_TRUE or t == _CT_FALSE:
        _need(b, pos, 1, "bool")
        pos += 1
    else:
        _skip(b, pos, t, depth)


def _skip(b: Span[UInt8, _], mut pos: Int, t: Int, depth: Int) raises:
    if depth > _MAX_DEPTH:
        raise Error("Thrift nesting deeper than " + String(_MAX_DEPTH))
    if t == _CT_TRUE or t == _CT_FALSE:
        return
    elif t == _CT_BYTE or t == _CT_I16 or t == _CT_I32 or t == _CT_I64:
        _ = _int(b, pos, t)
    elif t == _CT_DOUBLE:
        _need(b, pos, 8, "double")
        pos += 8
    elif t == _CT_BINARY:
        _ = _binary(b, pos)
    elif t == _CT_LIST or t == _CT_SET:
        var et = 0
        var n = _list(b, pos, et)
        for _ in range(n):
            _skip_elem(b, pos, et, depth + 1)
    elif t == _CT_MAP:
        var n = Int(_varint(b, pos))
        if n > 0:
            _need(b, pos, 1, "map types")
            var kv = Int(b[pos])
            pos += 1
            for _ in range(n):
                _skip_elem(b, pos, kv >> 4, depth + 1)
                _skip_elem(b, pos, kv & 0x0F, depth + 1)
    elif t == _CT_STRUCT:
        var fid = 0
        while True:
            var ft = _field(b, pos, fid)
            if ft == _CT_STOP:
                return
            _skip(b, pos, ft, depth + 1)
    else:
        raise Error("unknown compact type " + String(t) + " at " + String(pos))


def _ascii(b: Span[UInt8, _]) -> String:
    var s = String("")
    for i in range(len(b)):
        var x = Int(b[i])
        if x >= 0x20 and x < 0x7F:
            s += String(chr(x))
        else:
            s += "?"
    return s


def _le_u32(b: Span[UInt8, _], at: Int) raises -> Int:
    _need(b, at, 4, "u32")
    return (
        Int(b[at]) | (Int(b[at + 1]) << 8) | (Int(b[at + 2]) << 16)
        | (Int(b[at + 3]) << 24)
    )


def _le_u64(b: Span[UInt8, _], at: Int) raises -> UInt64:
    _need(b, at, 8, "u64")
    var v: UInt64 = 0
    for i in range(8):
        v |= UInt64(b[at + i]) << UInt64(8 * i)
    return v


# ---- the footer -------------------------------------------------------------


@fieldwise_init
struct _Chunk(Copyable, Movable):
    var rg: Int
    var physical_type: Int
    var codec: Int
    var num_values: Int
    var total_unc: Int
    var total_comp: Int
    var data_off: Int
    var dict_off: Int  # -1: the field is absent
    var path: String


@fieldwise_init
struct _Page(Copyable, Movable):
    var chunk: Int  # index into _Meta.chunks
    var offset: Int  # of the header, in the file
    var header_len: Int
    var type: Int
    var unc: Int
    var comp: Int
    var has_crc: Bool
    var crc: UInt32
    var num_values: Int
    var levels: Int  # DATA_PAGE_V2: rep + def level bytes, stored raw
    var v2_compressed: Bool


@fieldwise_init
struct _Meta(Movable):
    var num_rows: Int
    var created_by: String
    var leaves: Int
    var footer_start: Int
    var rg_rows: List[Int]
    var chunks: List[_Chunk]


def _column_meta(b: Span[UInt8, _], mut pos: Int, rg: Int) raises -> _Chunk:
    var c = _Chunk(rg, -1, -1, -1, -1, -1, -1, -1, String(""))
    var fid = 0
    while True:
        var t = _field(b, pos, fid)
        if t == _CT_STOP:
            break
        if fid == 1 and t == _CT_I32:
            c.physical_type = _int(b, pos, t)
        elif fid == 3 and t == _CT_LIST:
            var et = 0
            var n = _list(b, pos, et)
            for k in range(n):
                var s = _binary(b, pos)
                if k > 0:
                    c.path += "."
                c.path += _ascii(b[s:pos])
        elif fid == 4 and t == _CT_I32:
            c.codec = _int(b, pos, t)
        elif fid == 5 and t == _CT_I64:
            c.num_values = _int(b, pos, t)
        elif fid == 6 and t == _CT_I64:
            c.total_unc = _int(b, pos, t)
        elif fid == 7 and t == _CT_I64:
            c.total_comp = _int(b, pos, t)
        elif fid == 9 and t == _CT_I64:
            c.data_off = _int(b, pos, t)
        elif fid == 11 and t == _CT_I64:
            c.dict_off = _int(b, pos, t)
        else:
            _skip(b, pos, t, 1)
    if c.codec < 0 or c.total_comp < 0 or c.data_off < 0 or c.num_values < 0:
        raise Error("ColumnMetaData without a required field: " + c.path)
    return c^


def _row_group(b: Span[UInt8, _], mut pos: Int, rg: Int, mut m: _Meta) raises:
    var fid = 0
    var rows = -1
    while True:
        var t = _field(b, pos, fid)
        if t == _CT_STOP:
            break
        if fid == 1 and t == _CT_LIST:
            var et = 0
            var n = _list(b, pos, et)
            for _ in range(n):
                var cfid = 0
                var found = False
                while True:
                    var ct = _field(b, pos, cfid)
                    if ct == _CT_STOP:
                        break
                    if cfid == 1:
                        raise Error("a column chunk in an external file")
                    if cfid == 3 and ct == _CT_STRUCT:
                        m.chunks.append(_column_meta(b, pos, rg))
                        found = True
                    else:
                        _skip(b, pos, ct, 1)
                if not found:
                    raise Error("a column chunk without meta_data")
        elif fid == 3 and t == _CT_I64:
            rows = _int(b, pos, t)
        else:
            _skip(b, pos, t, 1)
    if rows < 0:
        raise Error("row group " + String(rg) + " without num_rows")
    m.rg_rows.append(rows)


def _assert_magic(b: Span[UInt8, _], at: Int) raises:
    assert_true(
        b[at] == 0x50 and b[at + 1] == 0x41 and b[at + 2] == 0x52
        and b[at + 3] == 0x31,
        "no PAR1 at " + String(at),
    )


def _file_meta(b: Span[UInt8, _]) raises -> _Meta:
    var n = len(b)
    _need(b, 0, 12, "magic + footer length + magic")
    _assert_magic(b, 0)
    _assert_magic(b, n - 4)
    var flen = _le_u32(b, n - 8)
    var start = n - 8 - flen
    assert_true(start >= 4, "footer length " + String(flen) + " too long")
    var m = _Meta(-1, String(""), 0, start, List[Int](), List[_Chunk]())
    var pos = start
    var fid = 0
    while True:
        var t = _field(b, pos, fid)
        if t == _CT_STOP:
            break
        if fid == 2 and t == _CT_LIST:
            var et = 0
            var k = _list(b, pos, et)
            for _ in range(k):
                var sfid = 0
                while True:
                    var st = _field(b, pos, sfid)
                    if st == _CT_STOP:
                        break
                    if sfid == 1:  # a physical type: a leaf
                        m.leaves += 1
                    _skip(b, pos, st, 1)
        elif fid == 3 and t == _CT_I64:
            m.num_rows = _int(b, pos, t)
        elif fid == 4 and t == _CT_LIST:
            var et = 0
            var k = _list(b, pos, et)
            for rg in range(k):
                _row_group(b, pos, rg, m)
        elif fid == 6 and t == _CT_BINARY:
            var s = _binary(b, pos)
            m.created_by = _ascii(b[s:pos])
        else:
            _skip(b, pos, t, 1)
    assert_equal(pos, n - 8, "FileMetaData's end against the footer length")
    assert_true(m.num_rows >= 0, "FileMetaData without num_rows")
    return m^


# ---- pages ------------------------------------------------------------------


def _sub_header(
    b: Span[UInt8, _], mut pos: Int, mut p: _Page, v2: Bool
) raises:
    var fid = 0
    var def_len = -1
    var rep_len = -1
    while True:
        var t = _field(b, pos, fid)
        if t == _CT_STOP:
            break
        if fid == 1 and t == _CT_I32:
            p.num_values = _int(b, pos, t)
        elif v2 and fid == 5 and t == _CT_I32:
            def_len = _int(b, pos, t)
        elif v2 and fid == 6 and t == _CT_I32:
            rep_len = _int(b, pos, t)
        elif v2 and fid == 7 and (t == _CT_TRUE or t == _CT_FALSE):
            p.v2_compressed = t == _CT_TRUE
        else:
            _skip(b, pos, t, 2)
    if v2:
        if def_len < 0 or rep_len < 0:
            raise Error("DataPageHeaderV2 without its level lengths")
        p.levels = def_len + rep_len


def _page_header(b: Span[UInt8, _], chunk: Int, offset: Int) raises -> _Page:
    var p = _Page(chunk, offset, 0, -1, -1, -1, False, 0, -1, 0, True)
    var pos = offset
    var fid = 0
    while True:
        var t = _field(b, pos, fid)
        if t == _CT_STOP:
            break
        if fid == 1 and t == _CT_I32:
            p.type = _int(b, pos, t)
        elif fid == 2 and t == _CT_I32:
            p.unc = _int(b, pos, t)
        elif fid == 3 and t == _CT_I32:
            p.comp = _int(b, pos, t)
        elif fid == 4 and t == _CT_I32:
            p.has_crc = True
            p.crc = UInt32(_int(b, pos, t) & 0xFFFFFFFF)
        elif (fid == 5 or fid == 7) and t == _CT_STRUCT:
            _sub_header(b, pos, p, False)
        elif fid == 8 and t == _CT_STRUCT:
            _sub_header(b, pos, p, True)
        else:
            _skip(b, pos, t, 1)
    p.header_len = pos - offset
    if p.type < 0 or p.unc < 0 or p.comp < 0 or p.num_values < 0:
        raise Error("page header at " + String(offset) + " lacks a field")
    return p^


def _body_at(b: Span[UInt8, _], p: _Page) raises -> Int:
    var at = p.offset + p.header_len
    _need(b, at, p.comp, "page body")
    return at


def _filled(n: Int, x: UInt8) -> List[UInt8]:
    var out = List[UInt8](capacity=n)
    for _ in range(n):
        out.append(x)
    return out^


def _payload(b: Span[UInt8, _], codec: Int, p: _Page) raises -> List[UInt8]:
    """The page's bytes as they were before compression."""
    var at = _body_at(b, p)
    var body = b[at : at + p.comp]
    var out = _filled(p.unc, 0)
    var lv = p.levels
    assert_true(lv <= p.comp and lv <= p.unc, "level bytes past the page")
    for i in range(lv):
        out[i] = body[i]
    var v2_raw = (
        p.type == Int(PageType.DATA_PAGE_V2.value) and not p.v2_compressed
    )
    if codec == Int(CompressionCodec.UNCOMPRESSED.value) or v2_raw:
        assert_equal(p.comp, p.unc, "an uncompressed page's two sizes")
    if v2_raw:
        for i in range(lv, p.unc):
            out[i] = body[i]
    else:
        var n = decompress(CompressionCodec(codec), body[lv:], Span(out)[lv:])
        assert_equal(lv + n, p.unc, "decompressed bytes against the header")
    return out^


def _crc_matches(b: Span[UInt8, _], p: _Page) raises -> Bool:
    var at = _body_at(b, p)
    return zlib_crc32(b[at : at + p.comp]) == p.crc


struct _Walk(Movable):
    var name: String
    var bytes: List[UInt8]
    var meta: _Meta
    var pages: List[_Page]
    var crc_pages: Int

    def __init__(out self, name: String) raises:
        var bytes = Path(_DIR + name).read_bytes()
        var meta = _file_meta(Span(bytes))
        self.name = name
        self.bytes = bytes^
        self.meta = meta^
        self.pages = List[_Page]()
        self.crc_pages = 0

    def payload(self, p: _Page) raises -> List[UInt8]:
        return _payload(Span(self.bytes), self.meta.chunks[p.chunk].codec, p)

    def chunk_pages(self, chunk: Int) -> List[_Page]:
        var out = List[_Page]()
        for i in range(len(self.pages)):
            if self.pages[i].chunk == chunk:
                out.append(self.pages[i].copy())
        return out^


def _walk_chunk(
    b: Span[UInt8, _],
    name: String,
    c: _Chunk,
    ci: Int,
    rows: Int,
    mut next_start: Int,
    mut pages: List[_Page],
    mut crc_pages: Int,
) raises:
    var at = name + " " + c.path + " rg " + String(c.rg)
    assert_equal(c.num_values, rows, at + ": num_values against rows")
    if c.total_comp == 0:
        assert_equal(c.num_values, 0, at + ": an empty chunk with values")
        return
    var start = c.data_off
    if c.dict_off >= 0:
        assert_true(c.dict_off < c.data_off, at + ": dictionary after data")
        start = c.dict_off
    assert_equal(start, next_start, at + ": chunk start")
    var end = start + c.total_comp
    _need(b, start, c.total_comp, at)
    var pos = start
    var unc = 0
    var values = 0
    var k = 0
    while pos < end:
        var p = _page_header(b, ci, pos)
        var pat = at + " page " + String(k) + " at " + String(pos)
        assert_true(pos + p.header_len + p.comp <= end, pat + ": past chunk")
        if p.type == Int(PageType.DICTIONARY_PAGE.value):
            assert_equal(k, 0, pat + ": a dictionary page not first")
            assert_equal(pos, c.dict_off, pat + ": dictionary_page_offset")
        else:
            assert_true(
                p.type == Int(PageType.DATA_PAGE.value)
                or p.type == Int(PageType.DATA_PAGE_V2.value),
                pat + ": page type " + String(p.type),
            )
            if values == 0:
                assert_equal(pos, c.data_off, pat + ": data_page_offset")
            values += p.num_values
        var got = _payload(b, c.codec, p)
        assert_equal(len(got), p.unc, pat)
        if p.has_crc:
            assert_true(_crc_matches(b, p), pat + ": CRC-32 mismatch")
            crc_pages += 1
        unc += p.header_len + p.unc
        pos += p.header_len + p.comp
        pages.append(p^)
        k += 1
    assert_equal(pos, end, at + ": pages against total_compressed_size")
    assert_equal(unc, c.total_unc, at + ": total_uncompressed_size")
    assert_equal(values, c.num_values, at + ": data pages' num_values")
    next_start = end


def _walk(name: String) raises -> _Walk:
    var w = _Walk(name)
    var total = 0
    for i in range(len(w.meta.rg_rows)):
        total += w.meta.rg_rows[i]
    assert_equal(total, w.meta.num_rows, name + ": row groups' rows")
    assert_equal(
        len(w.meta.chunks),
        len(w.meta.rg_rows) * w.meta.leaves,
        name + ": chunks against row groups x leaves",
    )
    var next_start = 4
    var pages = List[_Page]()
    var crc_pages = 0
    for ci in range(len(w.meta.chunks)):
        _walk_chunk(
            Span(w.bytes),
            name,
            w.meta.chunks[ci],
            ci,
            w.meta.rg_rows[w.meta.chunks[ci].rg],
            next_start,
            pages,
            crc_pages,
        )
    w.pages = pages^
    w.crc_pages = crc_pages
    assert_equal(next_start, w.meta.footer_start, name + ": last chunk end")
    return w^


# ---- expected values --------------------------------------------------------


def _assert_tail_u64(
    got: List[UInt8], want: List[UInt64], what: String
) raises:
    """`got` ends with `want`, little-endian, after the v1 level prefix."""
    var at = len(got) - 8 * len(want)
    assert_true(at >= 0, what + ": page too short")
    for i in range(len(want)):
        assert_equal(_le_u64(Span(got), at + 8 * i), want[i], what + " #" + String(i))


def _v1_values_start(page: List[UInt8]) raises -> Int:
    """A v1 data page of an OPTIONAL column: 4-byte length, RLE levels."""
    return 4 + _le_u32(Span(page), 0)


def _plain_strings(values: List[String]) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(values)):
        var s = values[i].as_bytes()
        var n = len(s)
        for k in range(4):
            out.append(UInt8((n >> (8 * k)) & 0xFF))
        for k in range(n):
            out.append(s[k])
    return out^


def _assert_bytes(got: List[UInt8], want: List[UInt8], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(Int(got[i]), Int(want[i]), what + ": byte " + String(i))


def _codecs(w: _Walk, want: Int) raises:
    for i in range(len(w.meta.chunks)):
        assert_equal(w.meta.chunks[i].codec, want, w.name + ": codec")


# ---- the files --------------------------------------------------------------


def test_gzip_plain() raises:
    var w = _walk("pyarrow_gzip_plain.parquet")
    assert_equal(w.meta.created_by, _ARROW_24)
    assert_equal(w.meta.num_rows, 5)
    assert_equal(len(w.meta.chunks), 2)
    _codecs(w, Int(CompressionCodec.GZIP.value))
    assert_equal(len(w.pages), 2, "one data page per column, no dictionary")
    var ids = List[UInt64]()
    var vals = List[UInt64]()
    for i in range(5):
        ids.append(UInt64(i + 1))
        vals.append(bitcast[DType.uint64](Float64(10.5 + 10.0 * Float64(i))))
    var id_page = w.payload(w.pages[0])
    var val_page = w.payload(w.pages[1])
    assert_equal(_v1_values_start(id_page) + 40, len(id_page), "id layout")
    assert_equal(_v1_values_start(val_page) + 40, len(val_page), "value layout")
    _assert_tail_u64(id_page, ids, "id")
    _assert_tail_u64(val_page, vals, "value")


def test_int96_timestamps() raises:
    var w = _walk("pyarrow_int96_ts.parquet")
    assert_equal(w.meta.created_by, _ARROW_24)
    assert_equal(w.meta.num_rows, 3)
    assert_equal(w.meta.chunks[0].physical_type, 3, "INT96")
    _codecs(w, Int(CompressionCodec.UNCOMPRESSED.value))
    assert_equal(len(w.pages), 1)
    var page = w.payload(w.pages[0])
    var at = _v1_values_start(page)
    assert_equal(at + 36, len(page), "three 12-byte values")
    # The epoch is Julian day 2440588; the value is 8 bytes of nanoseconds
    # within the day, then the 4-byte day, little-endian.
    var nanos: List[UInt64] = [0, 0, 1_000_000_000]
    var days: List[Int] = [2440588, 2440589, 2440588]
    for i in range(3):
        assert_equal(_le_u64(Span(page), at + 12 * i), nanos[i], "nanos")
        assert_equal(_le_u32(Span(page), at + 12 * i + 8), days[i], "day")


def test_multi_dict_page() raises:
    var w = _walk("pyarrow_multi_dict_page.parquet")
    assert_equal(w.meta.created_by, _ARROW_24)
    assert_equal(w.meta.num_rows, 3000)
    assert_equal(len(w.meta.rg_rows), 6)
    _codecs(w, Int(CompressionCodec.SNAPPY.value))
    var labels: List[String] = ["alpha", "bravo", "charlie", "delta", "echo"]
    var want_labels = _plain_strings(labels)
    var dicts = 0
    for ci in range(len(w.meta.chunks)):
        ref c = w.meta.chunks[ci]
        assert_true(c.dict_off >= 0, "every chunk has a dictionary")
        var pages = w.chunk_pages(ci)
        assert_equal(pages[0].type, Int(PageType.DICTIONARY_PAGE.value))
        var d = w.payload(pages[0])
        if c.path == "id":
            assert_equal(pages[0].num_values, 500)
            var ids = List[UInt64]()
            for r in range(500):
                ids.append(UInt64(500 * c.rg + r))
            assert_equal(len(d), 4000, "id dictionary size")
            _assert_tail_u64(d, ids, "id dictionary rg " + String(c.rg))
        else:
            assert_equal(c.path, "label")
            assert_equal(pages[0].num_values, 5)
            _assert_bytes(d, want_labels, "label dictionary rg " + String(c.rg))
        dicts += 1
    assert_equal(dicts, 12, "6 row groups x 2 columns")


def test_zero_row() raises:
    var w = _walk("pyarrow_zero_row.parquet")
    assert_equal(w.meta.created_by, _ARROW_24)
    assert_equal(w.meta.num_rows, 0)
    assert_equal(len(w.meta.rg_rows), 1)
    assert_equal(len(w.meta.chunks), 2)
    assert_equal(len(w.pages), 0)
    assert_equal(w.meta.footer_start, 4, "the footer follows the magic")


def test_page_crc_zstd_v2() raises:
    var w = _walk("pyarrow_page_crc_zstd_v2.parquet")
    assert_equal(w.meta.created_by, _ARROW_25)
    assert_equal(w.meta.num_rows, 1200)
    assert_equal(len(w.meta.rg_rows), 2)
    _codecs(w, Int(CompressionCodec.ZSTD.value))
    assert_true(len(w.pages) > 4, "several pages")
    assert_equal(w.crc_pages, len(w.pages), "write_page_checksum: every page")
    var next_id = 0
    var id_pages = 0
    for i in range(len(w.pages)):
        ref p = w.pages[i]
        ref c = w.meta.chunks[p.chunk]
        if p.type != Int(PageType.DICTIONARY_PAGE.value):
            assert_equal(p.type, Int(PageType.DATA_PAGE_V2.value))
            assert_true(p.v2_compressed)
        if c.path != "id":
            continue
        # id: PLAIN int64, no nulls; the values follow the level bytes.
        assert_equal(p.type, Int(PageType.DATA_PAGE_V2.value), "id: no dict")
        var page = w.payload(p)
        assert_equal(p.levels + 8 * p.num_values, len(page), "id page layout")
        var want = List[UInt64]()
        for _ in range(p.num_values):
            want.append(UInt64(next_id))
            next_id += 1
        _assert_tail_u64(page, want, "id page " + String(id_pages))
        id_pages += 1
    assert_equal(next_id, 1200, "every id, in order")
    assert_true(id_pages > 2, "the id chunks are cut into several pages")
    # The first label dictionary: "k" + str(row % 13) for the non-NULL rows
    # (row % 7 != 0), in the order first met: rows 1..13, row 7 NULL, so k7
    # comes last (row 20).
    var order: List[Int] = [1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 0, 7]
    var labels = List[String]()
    for i in range(len(order)):
        labels.append("k" + String(order[i]))
    for ci in range(len(w.meta.chunks)):
        if w.meta.chunks[ci].path == "label" and w.meta.chunks[ci].rg == 0:
            var pages = w.chunk_pages(ci)
            assert_equal(pages[0].type, Int(PageType.DICTIONARY_PAGE.value))
            _assert_bytes(w.payload(pages[0]), _plain_strings(labels), "k dict")


def test_crc_check_refuses_a_flipped_byte() raises:
    var w = _walk("pyarrow_page_crc_zstd_v2.parquet")
    for i in range(len(w.pages)):
        var p = w.pages[i].copy()
        var copy = w.bytes.copy()
        var at = p.offset + p.header_len + p.comp // 2
        copy[at] = copy[at] ^ 0x01
        assert_true(_crc_matches(Span(w.bytes), p), "the true body matches")
        assert_false(_crc_matches(Span(copy), p), "a flipped byte matches")


def test_lineitem_dictionaries_agree() raises:
    var c = _walk("lineitem_pyarrow_500.parquet")
    var u = _walk("lineitem_pyarrow_500_uncompressed.parquet")
    assert_equal(c.meta.created_by, _ARROW_24)
    assert_equal(u.meta.created_by, _ARROW_24)
    assert_equal(c.meta.num_rows, 500)
    assert_equal(u.meta.num_rows, 500)
    assert_equal(len(c.meta.rg_rows), 3)
    assert_equal(c.meta.rg_rows[0], 200)
    assert_equal(c.meta.rg_rows[1], 200)
    assert_equal(c.meta.rg_rows[2], 100)
    assert_equal(len(u.meta.rg_rows), 1)
    assert_equal(c.meta.leaves, 21)
    assert_equal(u.meta.leaves, 21)
    _codecs(c, Int(CompressionCodec.SNAPPY.value))
    _codecs(u, Int(CompressionCodec.UNCOMPRESSED.value))
    var equal = 0
    var prefix = 0
    for col in range(21):
        ref cc = c.meta.chunks[col]  # row group 0
        ref uc = u.meta.chunks[col]
        assert_equal(cc.path, uc.path)
        assert_equal(cc.physical_type, uc.physical_type, cc.path)
        var cp = c.chunk_pages(col)
        var up = u.chunk_pages(col)
        assert_equal(cp[0].type, Int(PageType.DICTIONARY_PAGE.value), cc.path)
        assert_equal(up[0].type, Int(PageType.DICTIONARY_PAGE.value), uc.path)
        var cd = c.payload(cp[0])
        var ud = u.payload(up[0])
        assert_true(cp[0].num_values <= up[0].num_values, cc.path)
        assert_true(len(cd) <= len(ud), cc.path + ": dictionary sizes")
        for i in range(len(cd)):
            assert_equal(
                Int(cd[i]), Int(ud[i]), cc.path + ": dictionary byte " + String(i)
            )
        if cp[0].num_values == up[0].num_values:
            assert_equal(len(cd), len(ud), cc.path + ": same entries, sizes")
            equal += 1
        else:
            prefix += 1
    # Both cases occur, so neither branch is vacuous.
    assert_true(equal > 0 and prefix > 0, String(equal) + "/" + String(prefix))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
