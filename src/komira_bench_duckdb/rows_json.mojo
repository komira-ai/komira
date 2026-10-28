# DuckDB's JSON output mode (`.mode json`) as a result set: one array of
# objects, one object per row, keys in column order, numbers unquoted, texts
# quoted, `null` for NULL. Booleans become the integers 1 and 0. A nested value
# (a list or a struct) is refused: the benchmark queries return scalars.
#
# An integer that does not fit 64 bits (above 9223372036854775807 or below
# -9223372036854775808) becomes a double. The bare words NaN, Infinity and
# -Infinity (and nan, inf, -inf) are doubles; a quoted one is a text. A number
# that is not written as JSON writes it (`1.2.3`, `12x`, `1e`) is refused. An
# empty output (no rows) is an empty result set with no column names.

from std.math import inf, nan

from .cells import Cell, ResultSet


struct _Reader(Movable):
    var data: List[UInt8]
    var pos: Int

    def __init__(out self, text: String):
        self.data = List[UInt8]()
        for b in text.as_bytes():
            self.data.append(b)
        self.pos = 0

    def skip_space(mut self):
        while self.pos < len(self.data) and (
            self.data[self.pos] == UInt8(32)
            or self.data[self.pos] == UInt8(10)
            or self.data[self.pos] == UInt8(13)
            or self.data[self.pos] == UInt8(9)
        ):
            self.pos += 1

    def at_end(self) -> Bool:
        return self.pos >= len(self.data)

    def peek(self) -> Int:
        if self.pos >= len(self.data):
            return -1
        return Int(self.data[self.pos])

    def expect(mut self, c: Int) raises:
        self.skip_space()
        if self.peek() != c:
            raise Error(String("JSON output: expected '") + chr(c) + String("' at byte ") + String(self.pos))
        self.pos += 1


def _hex4(mut r: _Reader) raises -> Int:
    if r.pos + 4 > len(r.data):
        raise Error("JSON output: a short \\u escape")
    var v = 0
    for _ in range(4):
        var c = Int(r.data[r.pos])
        r.pos += 1
        var d: Int
        if c >= 48 and c <= 57:
            d = c - 48
        elif c >= 97 and c <= 102:
            d = c - 87
        elif c >= 65 and c <= 70:
            d = c - 55
        else:
            raise Error("JSON output: a bad \\u escape")
        v = v * 16 + d
    return v


def _push_utf8(mut out: List[UInt8], cp: Int):
    if cp < 0x80:
        out.append(UInt8(cp))
    elif cp < 0x800:
        out.append(UInt8(0xC0 | (cp >> 6)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    elif cp < 0x10000:
        out.append(UInt8(0xE0 | (cp >> 12)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))
    else:
        out.append(UInt8(0xF0 | (cp >> 18)))
        out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (cp & 0x3F)))


def _read_string(mut r: _Reader) raises -> String:
    r.expect(34)
    var out = List[UInt8]()
    while True:
        if r.at_end():
            raise Error("JSON output: an unterminated string")
        var c = Int(r.data[r.pos])
        r.pos += 1
        if c == 34:
            break
        if c != 92:
            out.append(UInt8(c))
            continue
        if r.at_end():
            raise Error("JSON output: an unterminated escape")
        var e = Int(r.data[r.pos])
        r.pos += 1
        if e == 110:
            out.append(UInt8(10))
        elif e == 116:
            out.append(UInt8(9))
        elif e == 114:
            out.append(UInt8(13))
        elif e == 98:
            out.append(UInt8(8))
        elif e == 102:
            out.append(UInt8(12))
        elif e == 34 or e == 92 or e == 47:
            out.append(UInt8(e))
        elif e == 117:
            var cp = _hex4(r)
            if cp >= 0xD800 and cp < 0xDC00:
                if r.pos + 2 <= len(r.data) and r.data[r.pos] == UInt8(92) and r.data[r.pos + 1] == UInt8(117):
                    r.pos += 2
                    var lo = _hex4(r)
                    if lo < 0xDC00 or lo > 0xDFFF:
                        raise Error("JSON output: a bad surrogate pair")
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                else:
                    raise Error("JSON output: a lone surrogate")
            _push_utf8(out, cp)
        else:
            raise Error("JSON output: an unknown escape")
    return String(unsafe_from_utf8=Span[UInt8](out))


def _read_word(mut r: _Reader) -> String:
    var out = List[UInt8]()
    while r.pos < len(r.data):
        var c = r.data[r.pos]
        var stop = (
            c == UInt8(44) or c == UInt8(125) or c == UInt8(93)
            or c == UInt8(32) or c == UInt8(10) or c == UInt8(13) or c == UInt8(9)
        )
        if stop:
            break
        out.append(c)
        r.pos += 1
    return String(unsafe_from_utf8=Span[UInt8](out))


def _digit_run(b: Span[UInt8, _], mut i: Int) -> Int:
    """Skip decimal digits from `i`; return how many there were."""
    var n = 0
    while i < len(b) and b[i] >= UInt8(48) and b[i] <= UInt8(57):
        i += 1
        n += 1
    return n


def _is_json_number(w: String) -> Bool:
    """Whether `w` is written as a JSON number: an optional minus, digits, an
    optional fraction and an optional exponent."""
    var b = w.as_bytes()
    var i = 0
    if i < len(b) and b[i] == UInt8(45):
        i += 1
    if _digit_run(b, i) == 0:
        return False
    if i < len(b) and b[i] == UInt8(46):
        i += 1
        if _digit_run(b, i) == 0:
            return False
    if i < len(b) and (b[i] == UInt8(101) or b[i] == UInt8(69)):
        i += 1
        if i < len(b) and (b[i] == UInt8(43) or b[i] == UInt8(45)):
            i += 1
        if _digit_run(b, i) == 0:
            return False
    return i == len(b)


def _integer_cell(w: String) raises -> Cell:
    """An integer written as digits: an `Int64` when it fits, else a double."""
    var b = w.as_bytes()
    var neg = b[0] == UInt8(45)
    # 2^63 is the magnitude limit of a negative value, 2^63 - 1 of a positive.
    var limit = UInt64(9223372036854775807)
    if neg:
        limit += UInt64(1)
    var mag = UInt64(0)
    var fits = True
    var as_double = Float64(0)
    for k in range(1 if neg else 0, len(b)):
        var d = UInt64(Int(b[k]) - 48)
        as_double = as_double * Float64(10) + Float64(Int(d))
        if fits:
            if mag > (limit - d) // UInt64(10):
                fits = False
            else:
                mag = mag * UInt64(10) + d
    if not fits:
        return Cell.real(-as_double if neg else as_double)
    if neg:
        if mag == limit:
            return Cell.integer(Int64(-9223372036854775807) - Int64(1))
        return Cell.integer(-Int64(mag))
    return Cell.integer(Int64(mag))


def _read_value(mut r: _Reader) raises -> Cell:
    r.skip_space()
    var c = r.peek()
    if c == 34:
        return Cell.text(_read_string(r))
    if c == 91 or c == 123:
        raise Error("JSON output: a list or struct value is not supported")
    var w = _read_word(r)
    if w == "null":
        return Cell.null()
    if w == "true":
        return Cell.integer(Int64(1))
    if w == "false":
        return Cell.integer(Int64(0))
    if w.byte_length() == 0:
        raise Error(String("JSON output: a value is missing at byte ") + String(r.pos))
    if w == "NaN" or w == "nan":
        return Cell.real(nan[DType.float64]())
    if w == "Infinity" or w == "inf":
        return Cell.real(inf[DType.float64]())
    if w == "-Infinity" or w == "-inf":
        return Cell.real(-inf[DType.float64]())
    if not _is_json_number(w):
        raise Error(String("JSON output: not a number: ") + w)
    var is_float = False
    for b in w.as_bytes():
        if b == UInt8(46) or b == UInt8(101) or b == UInt8(69):
            is_float = True
    if not is_float:
        return _integer_cell(w)
    return Cell.real(atof(w))


def parse_json_rows(text: String) raises -> ResultSet:
    """The rows of DuckDB's JSON output. The column names are the keys of the
    first row; every later row must have the same keys in the same order."""
    var rs = ResultSet()
    var r = _Reader(text)
    r.skip_space()
    if r.at_end():
        return rs^
    r.expect(91)
    r.skip_space()
    if r.peek() == 93:
        return rs^
    var first = True
    while True:
        r.expect(123)
        var row = List[Cell]()
        var col = 0
        r.skip_space()
        if r.peek() == 125:
            raise Error("JSON output: a row with no columns")
        while True:
            r.skip_space()
            var key = _read_string(r)
            r.expect(58)
            if first:
                rs.names.append(key)
            elif col >= len(rs.names) or rs.names[col] != key:
                raise Error(String("JSON output: row ") + String(rs.row_count()) + String(" has a different column at position ") + String(col))
            row.append(_read_value(r))
            col += 1
            r.skip_space()
            if r.peek() == 44:
                r.pos += 1
                continue
            r.expect(125)
            break
        if col != len(rs.names):
            raise Error(String("JSON output: row ") + String(rs.row_count()) + String(" has too few columns"))
        rs.add_row(row^)
        first = False
        r.skip_space()
        if r.peek() == 44:
            r.pos += 1
            continue
        r.expect(93)
        break
    r.skip_space()
    if not r.at_end():
        raise Error("JSON output: text after the closing bracket")
    return rs^
