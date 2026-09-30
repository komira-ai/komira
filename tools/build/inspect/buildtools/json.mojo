"""JSON, read two ways, neither of which builds a tree.

`flatten`: one line per leaf, `<key>\\t<key>...\\t<value>`, the path from the
root (object keys, array indices) and the value; strings are decoded, with
`\\`, tab, newline and carriage return written as `\\\\`, `\\t`, `\\n`, `\\r`
so every line stays one line with a fixed field layout. An empty object or
array is a leaf written `{}` or `[]`, so emptiness is visible.

`canonical`: the bytes Python's `json.dumps(v, sort_keys=True,
separators=(",", ":"))` gives for the document: keys in code point order,
non-ASCII escaped as `\\uXXXX`. Numbers keep their source spelling.
"""

from buildtools.bytes import byte_at, bytes_less, hex_byte, slice_string


def escape_field(s: String) -> String:
    """A string as one tab-separated field: `\\`, tab, LF and CR escaped."""
    var out = String()
    var n = s.byte_length()
    var start = 0
    for i in range(n):
        var c = byte_at(s, i)
        if c == 92 or c == 9 or c == 10 or c == 13:
            out += String(s[byte=start:i])
            if c == 92:
                out += "\\\\"
            elif c == 9:
                out += "\\t"
            elif c == 10:
                out += "\\n"
            else:
                out += "\\r"
            start = i + 1
    out += String(s[byte=start:n])
    return out^


def _utf8(mut out: List[UInt8], cp: Int):
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


def _u4(cp: Int) -> String:
    return "\\u" + hex_byte(cp >> 8) + hex_byte(cp & 0xFF)


def _ascii_escape(cps: List[Int]) -> String:
    """Python's json encoder string form with ensure_ascii."""
    var out = String('"')
    for i in range(len(cps)):
        var c = cps[i]
        if c == 34:
            out += '\\"'
        elif c == 92:
            out += "\\\\"
        elif c == 10:
            out += "\\n"
        elif c == 13:
            out += "\\r"
        elif c == 9:
            out += "\\t"
        elif c == 8:
            out += "\\b"
        elif c == 12:
            out += "\\f"
        elif c < 0x20 or (c >= 0x7F and c < 0x10000):
            out += _u4(c)
        elif c >= 0x10000:
            var v = c - 0x10000
            out += _u4(0xD800 | (v >> 10))
            out += _u4(0xDC00 | (v & 0x3FF))
        else:
            out += chr(c)
    out += '"'
    return out^


struct JsonReader(Movable):
    var b: List[UInt8]
    var i: Int

    def __init__(out self, var data: List[UInt8]):
        self.b = data^
        self.i = 0

    def _fail(self, what: String) raises:
        raise Error("json: " + what + " at byte " + String(self.i))

    def ws(mut self):
        while self.i < len(self.b):
            var c = Int(self.b[self.i])
            if c == 32 or c == 9 or c == 10 or c == 13:
                self.i += 1
            else:
                return

    def at_end(mut self) -> Bool:
        self.ws()
        return self.i >= len(self.b)

    def peek(mut self) raises -> Int:
        self.ws()
        if self.i >= len(self.b):
            self._fail("unexpected end")
        return Int(self.b[self.i])

    def expect(mut self, c: Int) raises:
        if self.peek() != c:
            self._fail("expected '" + chr(c) + "'")
        self.i += 1

    def _hex4(mut self) raises -> Int:
        if self.i + 4 > len(self.b):
            self._fail("short \\u escape")
        var v = 0
        for _ in range(4):
            var c = Int(self.b[self.i])
            self.i += 1
            if c >= 48 and c <= 57:
                v = v * 16 + c - 48
            elif c >= 97 and c <= 102:
                v = v * 16 + c - 87
            elif c >= 65 and c <= 70:
                v = v * 16 + c - 55
            else:
                self._fail("bad \\u escape")
        return v

    def code_points(mut self) raises -> List[Int]:
        """The decoded code points of the string starting here."""
        self.expect(34)
        var out = List[Int]()
        while True:
            if self.i >= len(self.b):
                self._fail("unterminated string")
            var c = Int(self.b[self.i])
            self.i += 1
            if c == 34:
                return out^
            if c == 92:
                if self.i >= len(self.b):
                    self._fail("unterminated escape")
                var e = Int(self.b[self.i])
                self.i += 1
                if e == 34 or e == 92 or e == 47:
                    out.append(e)
                elif e == 98:
                    out.append(8)
                elif e == 102:
                    out.append(12)
                elif e == 110:
                    out.append(10)
                elif e == 114:
                    out.append(13)
                elif e == 116:
                    out.append(9)
                elif e == 117:
                    var v = self._hex4()
                    if v >= 0xD800 and v < 0xDC00 and self.i + 6 <= len(self.b) and Int(self.b[self.i]) == 92 and Int(self.b[self.i + 1]) == 117:
                        var save = self.i
                        self.i += 2
                        var lo = self._hex4()
                        if lo >= 0xDC00 and lo < 0xE000:
                            v = 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00)
                        else:
                            self.i = save
                    out.append(v)
                else:
                    self._fail("bad escape")
            elif c < 0x80:
                out.append(c)
            else:
                # A UTF-8 sequence.
                var extra = 0
                var v = 0
                if c >= 0xF0:
                    extra = 3
                    v = c & 0x07
                elif c >= 0xE0:
                    extra = 2
                    v = c & 0x0F
                elif c >= 0xC0:
                    extra = 1
                    v = c & 0x1F
                else:
                    self._fail("bad UTF-8")
                for _ in range(extra):
                    if self.i >= len(self.b):
                        self._fail("truncated UTF-8")
                    v = (v << 6) | (Int(self.b[self.i]) & 0x3F)
                    self.i += 1
                out.append(v)

    def string(mut self) raises -> String:
        var cps = self.code_points()
        var buf = List[UInt8]()
        for k in range(len(cps)):
            _utf8(buf, cps[k])
        return slice_string(buf, 0, len(buf))

    def scalar(mut self) raises -> String:
        """A number, true, false or null, as spelled."""
        self.ws()
        var start = self.i
        while self.i < len(self.b):
            var c = Int(self.b[self.i])
            if c == 44 or c == 93 or c == 125 or c == 32 or c == 9 or c == 10 or c == 13:
                break
            self.i += 1
        if self.i == start:
            self._fail("expected a value")
        var s = slice_string(self.b, start, self.i)
        if s != "true" and s != "false" and s != "null":
            var ok = True
            for k in range(s.byte_length()):
                var c = byte_at(s, k)
                if not ((c >= 48 and c <= 57) or c == 45 or c == 43 or c == 46 or c == 101 or c == 69):
                    ok = False
            if not ok:
                self.i = start
                self._fail("bad literal '" + s + "'")
        return s^

    def flatten(mut self, prefix: String, mut out: String) raises:
        """Appends the leaves of the value starting here to `out`."""
        var c = self.peek()
        if c == 123:
            self.i += 1
            if self.peek() == 125:
                self.i += 1
                out += prefix + "{}\n"
                return
            while True:
                var key = self.string()
                self.expect(58)
                self.flatten(prefix + escape_field(key) + "\t", out)
                if self.peek() == 44:
                    self.i += 1
                    continue
                self.expect(125)
                return
        elif c == 91:
            self.i += 1
            if self.peek() == 93:
                self.i += 1
                out += prefix + "[]\n"
                return
            var n = 0
            while True:
                self.flatten(prefix + String(n) + "\t", out)
                n += 1
                if self.peek() == 44:
                    self.i += 1
                    continue
                self.expect(93)
                return
        elif c == 34:
            out += prefix + escape_field(self.string()) + "\n"
        else:
            out += prefix + self.scalar() + "\n"

    def canonical(mut self) raises -> String:
        """Python's compact, sorted-key serialization of the value here."""
        var c = self.peek()
        if c == 123:
            self.i += 1
            var keys = List[String]()
            var enc = List[String]()
            var vals = List[String]()
            if self.peek() == 125:
                self.i += 1
                return String("{}")
            while True:
                var cps = self.code_points()
                var buf = List[UInt8]()
                for k in range(len(cps)):
                    _utf8(buf, cps[k])
                keys.append(slice_string(buf, 0, len(buf)))
                enc.append(_ascii_escape(cps))
                self.expect(58)
                vals.append(self.canonical())
                if self.peek() == 44:
                    self.i += 1
                    continue
                self.expect(125)
                break
            # Insertion sort of indices by key; a later duplicate key wins,
            # as in Python's json.loads.
            var order = List[Int]()
            for k in range(len(keys)):
                var dup = -1
                for m in range(len(order)):
                    if keys[order[m]] == keys[k]:
                        dup = m
                if dup >= 0:
                    order[dup] = k
                    continue
                var pos = len(order)
                while pos > 0 and bytes_less(keys[k], keys[order[pos - 1]]):
                    pos -= 1
                order.insert(pos, k)
            var out = String("{")
            for m in range(len(order)):
                if m > 0:
                    out += ","
                out += enc[order[m]] + ":" + vals[order[m]]
            return out + "}"
        elif c == 91:
            self.i += 1
            if self.peek() == 93:
                self.i += 1
                return String("[]")
            var out = String("[")
            var first = True
            while True:
                if not first:
                    out += ","
                first = False
                out += self.canonical()
                if self.peek() == 44:
                    self.i += 1
                    continue
                self.expect(93)
                break
            return out + "]"
        elif c == 34:
            return _ascii_escape(self.code_points())
        return self.scalar()


def flatten_document(var data: List[UInt8], prefix: String, mut out: String) raises:
    """Flattens one JSON document; refuses trailing bytes."""
    var r = JsonReader(data^)
    r.flatten(prefix, out)
    if not r.at_end():
        r._fail("trailing data")


def canonical_document(var data: List[UInt8]) raises -> String:
    var r = JsonReader(data^)
    var s = r.canonical()
    if not r.at_end():
        r._fail("trailing data")
    return s^
