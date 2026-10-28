# =============================================================================
# parquet_file — small flat Parquet files, written byte by byte, for tests
# =============================================================================
#
# `parquet_file_bytes(columns, layout)` returns a whole Parquet file: the
# `PAR1` magic, each row group's column chunks, the optional page index
# (every ColumnIndex, then every OffsetIndex), the Thrift Compact
# FileMetaData, its length and the closing magic. The encoder is written
# here from parquet.thrift and the Parquet encodings spec, not taken from a
# reader, so a reader test that decodes these files checks the reader
# against an independent writer.
#
# What a file can hold:
#   - flat columns of INT32, INT64, DOUBLE or BYTE_ARRAY (UTF8 by default),
#     REQUIRED, or OPTIONAL with any rows null;
#   - PLAIN data pages (DataPage V1, uncompressed), or a PLAIN dictionary
#     page followed by RLE_DICTIONARY data pages; a PLAIN chunk may store a
#     dictionary_page_offset of 0; an INT64 column may carry a TIMESTAMP
#     LogicalType;
#   - any number of row groups (none for a file of no rows, unless the
#     layout names them), and data pages of at most `page_rows` rows (per
#     column, when a column sets its own);
#   - per-chunk Statistics (null_count, min_value, max_value) and, with
#     `page_index`, a ColumnIndex (per-page min/max, null pages, null
#     counts, boundary order UNORDERED) and an OffsetIndex per chunk.
#
# Definition levels are RLE runs with the 4-byte length prefix of DataPage
# V1; dictionary codes are RLE runs of one code each at the narrowest bit
# width that holds the largest code.
# =============================================================================

from std.memory import bitcast

comptime PT_INT32 = 1
comptime PT_INT64 = 2
comptime PT_DOUBLE = 5
comptime PT_BYTE_ARRAY = 6

comptime _CT_UTF8 = 0
comptime _ENC_PLAIN = 0
comptime _ENC_RLE = 3
comptime _ENC_RLE_DICTIONARY = 8

# Thrift Compact wire types.
comptime _T_TRUE = 1
comptime _T_FALSE = 2
comptime _T_I32 = 5
comptime _T_I64 = 6
comptime _T_BINARY = 8
comptime _T_LIST = 9
comptime _T_STRUCT = 12


struct TestColumn(Copyable, Movable):
    """One flat column and its values, one per row.

    `ints` holds INT32 and INT64 values, `doubles` DOUBLE values and
    `strings` BYTE_ARRAY values; a null row's slot is present and ignored.
    `nulls` is empty (no nulls) or one flag per row, True for null.
    """

    var name: String
    var ptype: Int
    var optional: Bool
    var dictionary: Bool
    var zero_dict_offset: Bool
    var timestamp_unit: Int
    var converted_type: Int
    var page_rows: Int
    var ints: List[Int]
    var doubles: List[Float64]
    var strings: List[String]
    var nulls: List[Bool]

    def __init__(out self, name: String, ptype: Int, converted_type: Int):
        self.name = name
        self.ptype = ptype
        self.optional = False
        self.dictionary = False
        self.zero_dict_offset = False
        self.timestamp_unit = 0
        self.converted_type = converted_type
        self.page_rows = 0
        self.ints = List[Int]()
        self.doubles = List[Float64]()
        self.strings = List[String]()
        self.nulls = List[Bool]()

    @staticmethod
    def int32(name: String, var values: List[Int]) -> TestColumn:
        var c = TestColumn(name, PT_INT32, -1)
        c.ints = values^
        return c^

    @staticmethod
    def int64(name: String, var values: List[Int]) -> TestColumn:
        var c = TestColumn(name, PT_INT64, -1)
        c.ints = values^
        return c^

    @staticmethod
    def float64(name: String, var values: List[Float64]) -> TestColumn:
        var c = TestColumn(name, PT_DOUBLE, -1)
        c.doubles = values^
        return c^

    @staticmethod
    def string(name: String, var values: List[String]) -> TestColumn:
        """A BYTE_ARRAY column annotated UTF8."""
        var c = TestColumn(name, PT_BYTE_ARRAY, _CT_UTF8)
        c.strings = values^
        return c^

    def with_nulls(var self, var nulls: List[Bool]) -> TestColumn:
        """This column, OPTIONAL, with `nulls[r]` True for each null row."""
        self.optional = True
        self.nulls = nulls^
        return self^

    def as_optional(var self) -> TestColumn:
        """This column, OPTIONAL, with no null row."""
        self.optional = True
        return self^

    def dict_encoded(var self) -> TestColumn:
        """This column, written as a dictionary page and RLE_DICTIONARY
        data pages."""
        self.dictionary = True
        return self^

    def with_zero_dictionary_offset(var self) -> TestColumn:
        """This column's chunks, which must be PLAIN, carrying a stored
        dictionary_page_offset of 0 (some writers store 0 for a chunk with no
        dictionary page)."""
        self.zero_dict_offset = True
        return self^

    def with_timestamp_logical_type(var self, unit: Int) -> TestColumn:
        """This INT64 column annotated, by the LogicalType union alone (no
        ConvertedType), as a TIMESTAMP adjusted to UTC; `unit` is 1 (millis),
        2 (micros) or 3 (nanos)."""
        self.timestamp_unit = unit
        return self^

    def with_page_rows(var self, page_rows: Int) -> TestColumn:
        """This column, cut into data pages of at most `page_rows` rows
        whatever the layout says (columns may then have different page
        boundaries)."""
        self.page_rows = page_rows
        return self^

    def num_rows(self) -> Int:
        if self.ptype == PT_DOUBLE:
            return len(self.doubles)
        if self.ptype == PT_BYTE_ARRAY:
            return len(self.strings)
        return len(self.ints)

    def is_null(self, row: Int) -> Bool:
        return len(self.nulls) > 0 and self.nulls[row]


@fieldwise_init
struct TestFileLayout(Copyable, Movable):
    """How the rows are cut: `row_group_rows` (empty: one row group of
    every row, or none when there are no rows), at most `page_rows` rows
    per data page (0: one page per chunk), and whether a page index is
    written."""

    var row_group_rows: List[Int]
    var page_rows: Int
    var page_index: Bool

    @staticmethod
    def single() -> TestFileLayout:
        return TestFileLayout(List[Int](), 0, False)


# -----------------------------------------------------------------------------
# Thrift Compact writer
# -----------------------------------------------------------------------------


struct _Thrift(Movable):
    var out: List[UInt8]
    var _last: List[Int]

    def __init__(out self):
        self.out = List[UInt8]()
        self._last = [0]

    def uleb(mut self, v: Int):
        var x = UInt64(v)
        while x >= 0x80:
            self.out.append(UInt8((x & 0x7F) | 0x80))
            x >>= 7
        self.out.append(UInt8(x))

    def zigzag(mut self, v: Int):
        self.uleb((v << 1) ^ (v >> 63))

    def field(mut self, id: Int, wire_type: Int):
        var delta = id - self._last[len(self._last) - 1]
        if delta > 0 and delta <= 15:
            self.out.append(UInt8((delta << 4) | wire_type))
        else:
            self.out.append(UInt8(wire_type))
            self.zigzag(id)
        self._last[len(self._last) - 1] = id

    def i32(mut self, id: Int, v: Int):
        self.field(id, _T_I32)
        self.zigzag(v)

    def i64(mut self, id: Int, v: Int):
        self.field(id, _T_I64)
        self.zigzag(v)

    def raw_binary(mut self, b: List[UInt8]):
        self.uleb(len(b))
        self.out.extend(Span(b))

    def binary(mut self, id: Int, b: List[UInt8]):
        self.field(id, _T_BINARY)
        self.raw_binary(b)

    def list_header(mut self, id: Int, elem_type: Int, n: Int):
        self.field(id, _T_LIST)
        if n < 15:
            self.out.append(UInt8((n << 4) | elem_type))
        else:
            self.out.append(UInt8(0xF0 | elem_type))
            self.uleb(n)

    def begin_struct(mut self, id: Int):
        """A struct-valued field."""
        self.field(id, _T_STRUCT)
        self._last.append(0)

    def begin_element(mut self):
        """A struct that is a list element (no field header)."""
        self._last.append(0)

    def end_struct(mut self):
        self.out.append(0)
        _ = self._last.pop()


# -----------------------------------------------------------------------------
# Values
# -----------------------------------------------------------------------------


def _le(mut out: List[UInt8], v: Int, width: Int):
    for k in range(width):
        out.append(UInt8((v >> (8 * k)) & 0xFF))


def _plain_value(c: TestColumn, row: Int, mut out: List[UInt8]):
    """Row `row`'s value, PLAIN-encoded."""
    if c.ptype == PT_INT32:
        _le(out, c.ints[row], 4)
    elif c.ptype == PT_INT64:
        _le(out, c.ints[row], 8)
    elif c.ptype == PT_DOUBLE:
        _le(out, Int(bitcast[DType.int64](c.doubles[row])), 8)
    else:
        var s = c.strings[row].as_bytes()
        _le(out, len(s), 4)
        out.extend(s)


def _stat_bytes(c: TestColumn, row: Int) -> List[UInt8]:
    """Row `row`'s value as a Statistics / ColumnIndex bound: PLAIN bytes,
    without the length prefix for BYTE_ARRAY."""
    var out = List[UInt8]()
    if c.ptype == PT_BYTE_ARRAY:
        out.extend(c.strings[row].as_bytes())
    else:
        _plain_value(c, row, out)
    return out^


def _less(c: TestColumn, a: Int, b: Int) -> Bool:
    """Row `a`'s value orders before row `b`'s (signed, numeric, or
    bytewise)."""
    if c.ptype == PT_DOUBLE:
        return c.doubles[a] < c.doubles[b]
    if c.ptype == PT_BYTE_ARRAY:
        return c.strings[a] < c.strings[b]
    return c.ints[a] < c.ints[b]


def _same(c: TestColumn, a: Int, b: Int) -> Bool:
    if c.ptype == PT_DOUBLE:
        return c.doubles[a] == c.doubles[b]
    if c.ptype == PT_BYTE_ARRAY:
        return c.strings[a] == c.strings[b]
    return c.ints[a] == c.ints[b]


struct _Bounds(Copyable, Movable):
    """The min row, max row and null count of a row range (min/max -1 when
    every row is null)."""

    var min_row: Int
    var max_row: Int
    var nulls: Int

    def __init__(out self, c: TestColumn, lo: Int, hi: Int):
        self.min_row = -1
        self.max_row = -1
        self.nulls = 0
        for r in range(lo, hi):
            if c.is_null(r):
                self.nulls += 1
                continue
            if self.min_row < 0 or _less(c, r, self.min_row):
                self.min_row = r
            if self.max_row < 0 or _less(c, self.max_row, r):
                self.max_row = r


def _bit_width(max_code: Int) -> Int:
    var bw = 1
    while (1 << bw) <= max_code:
        bw += 1
    return bw


def _rle_runs(mut out: List[UInt8], values: List[Int], bit_width: Int):
    """`values` as RLE runs (one run per stretch of equal values)."""
    var bytes = (bit_width + 7) // 8
    var i = 0
    while i < len(values):
        var j = i
        while j < len(values) and values[j] == values[i]:
            j += 1
        var hdr = _Thrift()
        hdr.uleb((j - i) << 1)
        out.extend(Span(hdr.out))
        _le(out, values[i], bytes)
        i = j


# -----------------------------------------------------------------------------
# Pages and chunks
# -----------------------------------------------------------------------------


struct _PageLoc(Copyable, Movable):
    var offset: Int
    var size: Int
    var first_row: Int
    var lo: Int
    var hi: Int

    def __init__(out self, offset: Int, size: Int, first_row: Int, lo: Int, hi: Int):
        self.offset = offset
        self.size = size
        self.first_row = first_row
        self.lo = lo
        self.hi = hi


def _page(
    mut out: List[UInt8],
    page_type: Int,
    num_values: Int,
    encoding: Int,
    body: List[UInt8],
):
    """A page header (DataPage V1 or dictionary page) and its body."""
    var h = _Thrift()
    h.i32(1, page_type)
    h.i32(2, len(body))
    h.i32(3, len(body))
    if page_type == 2:
        h.begin_struct(7)
    else:
        h.begin_struct(5)
    h.i32(1, num_values)
    h.i32(2, encoding)
    if page_type != 2:
        h.i32(3, _ENC_RLE)
        h.i32(4, _ENC_RLE)
    h.end_struct()
    h.end_struct()
    out.extend(Span(h.out))
    out.extend(Span(body))


struct _Dict(Copyable, Movable):
    """A column's distinct non-null values in first-seen order (as rows)
    and each row's code (-1 for a null row)."""

    var entries: List[Int]
    var codes: List[Int]

    def __init__(out self, c: TestColumn):
        self.entries = List[Int]()
        self.codes = List[Int]()
        for r in range(c.num_rows()):
            if c.is_null(r):
                self.codes.append(-1)
                continue
            var code = -1
            for k in range(len(self.entries)):
                if _same(c, self.entries[k], r):
                    code = k
                    break
            if code < 0:
                code = len(self.entries)
                self.entries.append(r)
            self.codes.append(code)


struct _Chunk(Copyable, Movable):
    var start: Int
    var size: Int
    var data_page_offset: Int
    var dict_page_offset: Int
    var pages: List[_PageLoc]
    var ci_offset: Int
    var ci_length: Int
    var oi_offset: Int
    var oi_length: Int

    def __init__(out self):
        self.start = 0
        self.size = 0
        self.data_page_offset = 0
        self.dict_page_offset = -1
        self.pages = List[_PageLoc]()
        self.ci_offset = 0
        self.ci_length = 0
        self.oi_offset = 0
        self.oi_length = 0


def _write_chunk(
    mut out: List[UInt8],
    c: TestColumn,
    d: _Dict,
    lo: Int,
    hi: Int,
    page_rows: Int,
) -> _Chunk:
    var ch = _Chunk()
    ch.start = len(out)
    var bw = _bit_width(max(len(d.entries) - 1, 0))
    if c.dictionary:
        ch.dict_page_offset = len(out)
        var dict_body = List[UInt8]()
        for k in range(len(d.entries)):
            _plain_value(c, d.entries[k], dict_body)
        _page(out, 2, len(d.entries), _ENC_PLAIN, dict_body)
    ch.data_page_offset = len(out)
    var rows_per_page = c.page_rows if c.page_rows > 0 else page_rows
    var step = rows_per_page if rows_per_page > 0 else max(hi - lo, 1)
    var p = lo
    while p < hi or (p == lo and hi == lo):
        var q = min(p + step, hi)
        var body = List[UInt8]()
        if c.optional:
            var levels = List[Int]()
            for r in range(p, q):
                levels.append(0 if c.is_null(r) else 1)
            var lv = List[UInt8]()
            _rle_runs(lv, levels, 1)
            _le(body, len(lv), 4)
            body.extend(Span(lv))
        if c.dictionary:
            body.append(UInt8(bw))
            var codes = List[Int]()
            for r in range(p, q):
                if not c.is_null(r):
                    codes.append(d.codes[r])
            _rle_runs(body, codes, bw)
        else:
            for r in range(p, q):
                if not c.is_null(r):
                    _plain_value(c, r, body)
        var page_start = len(out)
        _page(
            out,
            0,
            q - p,
            _ENC_RLE_DICTIONARY if c.dictionary else _ENC_PLAIN,
            body,
        )
        ch.pages.append(_PageLoc(page_start, len(out) - page_start, p - lo, p, q))
        if q == hi:
            break
        p = q
    ch.size = len(out) - ch.start
    return ch^


def _column_index(c: TestColumn, ch: _Chunk) -> List[UInt8]:
    var t = _Thrift()
    var n = len(ch.pages)
    t.list_header(1, _T_TRUE, n)
    var bounds = List[_Bounds]()
    for i in range(n):
        bounds.append(_Bounds(c, ch.pages[i].lo, ch.pages[i].hi))
        t.out.append(UInt8(_T_TRUE if bounds[i].min_row < 0 else _T_FALSE))
    t.list_header(2, _T_BINARY, n)
    for i in range(n):
        if bounds[i].min_row < 0:
            t.raw_binary(List[UInt8]())
        else:
            t.raw_binary(_stat_bytes(c, bounds[i].min_row))
    t.list_header(3, _T_BINARY, n)
    for i in range(n):
        if bounds[i].max_row < 0:
            t.raw_binary(List[UInt8]())
        else:
            t.raw_binary(_stat_bytes(c, bounds[i].max_row))
    t.i32(4, 0)
    t.list_header(5, _T_I64, n)
    for i in range(n):
        t.zigzag(bounds[i].nulls)
    t.out.append(0)
    return t.out.copy()


def _offset_index(ch: _Chunk) -> List[UInt8]:
    var t = _Thrift()
    t.list_header(1, _T_STRUCT, len(ch.pages))
    for i in range(len(ch.pages)):
        t.begin_element()
        t.i64(1, ch.pages[i].offset)
        t.i32(2, ch.pages[i].size)
        t.i64(3, ch.pages[i].first_row)
        t.end_struct()
    t.out.append(0)
    return t.out.copy()


def _column_chunk(mut t: _Thrift, c: TestColumn, ch: _Chunk, lo: Int, hi: Int, page_index: Bool):
    t.begin_element()
    t.i64(2, ch.start)
    t.begin_struct(3)
    t.i32(1, c.ptype)
    var encs = List[Int]()
    encs.append(_ENC_PLAIN)
    encs.append(_ENC_RLE)
    if c.dictionary:
        encs.append(_ENC_RLE_DICTIONARY)
    t.list_header(2, _T_I32, len(encs))
    for i in range(len(encs)):
        t.zigzag(encs[i])
    t.list_header(3, _T_BINARY, 1)
    var name = List[UInt8]()
    name.extend(c.name.as_bytes())
    t.raw_binary(name)
    t.i32(4, 0)
    t.i64(5, hi - lo)
    t.i64(6, ch.size)
    t.i64(7, ch.size)
    t.i64(9, ch.data_page_offset)
    if ch.dict_page_offset >= 0:
        t.i64(11, ch.dict_page_offset)
    elif c.zero_dict_offset:
        t.i64(11, 0)
    var b = _Bounds(c, lo, hi)
    t.begin_struct(12)
    t.i64(3, b.nulls)
    if b.min_row >= 0:
        t.binary(5, _stat_bytes(c, b.max_row))
        t.binary(6, _stat_bytes(c, b.min_row))
    t.end_struct()
    t.end_struct()
    if page_index:
        t.i64(4, ch.oi_offset)
        t.i32(5, ch.oi_length)
        t.i64(6, ch.ci_offset)
        t.i32(7, ch.ci_length)
    t.end_struct()


def parquet_file_bytes(
    columns: List[TestColumn], layout: TestFileLayout
) raises -> List[UInt8]:
    """The whole Parquet file holding `columns`, cut as `layout` says.

    Raises:
        Error if the columns have different row counts, a null flag list
        is not one per row, or the row-group sizes do not add up to the
        row count.
    """
    if len(columns) == 0:
        raise Error("parquet_file_bytes: no columns")
    var rows = columns[0].num_rows()
    for i in range(len(columns)):
        if columns[i].num_rows() != rows:
            raise Error("parquet_file_bytes: columns differ in row count")
        if len(columns[i].nulls) != 0 and len(columns[i].nulls) != rows:
            raise Error("parquet_file_bytes: nulls is not one flag per row")
    var rg_rows = layout.row_group_rows.copy()
    if len(rg_rows) == 0 and rows > 0:
        rg_rows.append(rows)
    var total = 0
    for i in range(len(rg_rows)):
        total += rg_rows[i]
    if total != rows:
        raise Error("parquet_file_bytes: row groups do not add up to the rows")

    var dicts = List[_Dict]()
    for i in range(len(columns)):
        dicts.append(_Dict(columns[i]))

    var out: List[UInt8] = [0x50, 0x41, 0x52, 0x31]
    var chunks = List[List[_Chunk]]()
    var lo = 0
    for g in range(len(rg_rows)):
        var hi = lo + rg_rows[g]
        var row = List[_Chunk]()
        for i in range(len(columns)):
            row.append(_write_chunk(out, columns[i], dicts[i], lo, hi, layout.page_rows))
        chunks.append(row^)
        lo = hi
    if layout.page_index:
        for g in range(len(chunks)):
            for i in range(len(columns)):
                var ci = _column_index(columns[i], chunks[g][i])
                chunks[g][i].ci_offset = len(out)
                chunks[g][i].ci_length = len(ci)
                out.extend(Span(ci))
        for g in range(len(chunks)):
            for i in range(len(columns)):
                var oi = _offset_index(chunks[g][i])
                chunks[g][i].oi_offset = len(out)
                chunks[g][i].oi_length = len(oi)
                out.extend(Span(oi))

    var t = _Thrift()
    t.i32(1, 1)
    t.list_header(2, _T_STRUCT, len(columns) + 1)
    t.begin_element()
    var root = List[UInt8]()
    root.extend(String("schema").as_bytes())
    t.binary(4, root)
    t.i32(5, len(columns))
    t.end_struct()
    for i in range(len(columns)):
        ref c = columns[i]
        t.begin_element()
        t.i32(1, c.ptype)
        t.i32(3, 1 if c.optional else 0)
        var name = List[UInt8]()
        name.extend(c.name.as_bytes())
        t.binary(4, name)
        if c.converted_type >= 0:
            t.i32(6, c.converted_type)
        if c.timestamp_unit > 0:
            t.begin_struct(10)  # LogicalType
            t.begin_struct(8)  # TIMESTAMP
            t.field(1, _T_TRUE)  # isAdjustedToUTC
            t.begin_struct(2)  # unit
            t.begin_struct(c.timestamp_unit)  # MILLIS / MICROS / NANOS
            t.end_struct()
            t.end_struct()
            t.end_struct()
            t.end_struct()
        t.end_struct()
    t.i64(3, rows)
    t.list_header(4, _T_STRUCT, len(rg_rows))
    lo = 0
    for g in range(len(rg_rows)):
        var hi = lo + rg_rows[g]
        t.begin_element()
        t.list_header(1, _T_STRUCT, len(columns))
        var bytes = 0
        for i in range(len(columns)):
            _column_chunk(t, columns[i], chunks[g][i], lo, hi, layout.page_index)
            bytes += chunks[g][i].size
        t.i64(2, bytes)
        t.i64(3, rg_rows[g])
        t.end_struct()
        lo = hi
    t.out.append(0)
    out.extend(Span(t.out))
    _le(out, len(t.out), 4)
    for b in [0x50, 0x41, 0x52, 0x31]:
        out.append(UInt8(b))
    return out^


def write_parquet_file(
    path: String, columns: List[TestColumn], layout: TestFileLayout
) raises:
    """Write `parquet_file_bytes(columns, layout)` to `path`."""
    var b = parquet_file_bytes(columns, layout)
    var fh = open(path, "w")
    fh.write_bytes(Span(b))
    fh.close()
