"""Bytes, decimal numbers, byte-order sorting and file I/O the readers share."""


def read_bytes(path: String) raises -> List[UInt8]:
    """Every byte of the file at `path`."""
    with open(path, "r") as f:
        return f.read_bytes()


def read_text(path: String) raises -> String:
    """The file at `path` as text (invalid UTF-8 becomes U+FFFD)."""
    return String(from_utf8_lossy=read_bytes(path))


def write_text(path: String, text: String) raises:
    with open(path, "w") as f:
        f.write(text)


def byte_at(s: String, i: Int) -> Int:
    return Int(s.as_bytes()[i])


def substr(s: String, start: Int, end: Int) -> String:
    """Bytes [start, end) of `s`, clamped to the string."""
    var n = s.byte_length()
    var a = min(max(start, 0), n)
    var z = min(max(end, a), n)
    return String(s[byte=a:z])


def suffix(s: String, start: Int) -> String:
    return substr(s, start, s.byte_length())


def bytes_to_string(b: List[UInt8], start: Int, end: Int) -> String:
    """Bytes [start, end) of `b` as a string (invalid UTF-8 becomes U+FFFD)."""
    var sub = List[UInt8](capacity=max(end - start, 0))
    for i in range(start, end):
        sub.append(b[i])
    return String(from_utf8_lossy=sub)


def split_lines(text: String) -> List[String]:
    """`text` split at LF. A final LF ends the last line; it does not start
    an empty one."""
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == UInt8(10):
            out.append(String(text[byte=start:i]))
            start = i + 1
    if start < len(b):
        out.append(String(text[byte=start : len(b)]))
    return out^


def split_on(s: String, sep: Int) -> List[String]:
    """`s` split at every byte `sep` (empty fields kept)."""
    var out = List[String]()
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b)):
        if Int(b[i]) == sep:
            out.append(String(s[byte=start:i]))
            start = i + 1
    out.append(String(s[byte=start : len(b)]))
    return out^


def has_byte(s: String, c: Int) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        if Int(b[i]) == c:
            return True
    return False


comptime MAX_DIGITS: Int = 18

# The largest line number a reader accepts. Sort keys pad line numbers to 12
# digits, so a larger number would break the path-then-line order.
comptime MAX_LINE: Int = 1_000_000_000


def parse_count(s: String) -> Int:
    """`s` as a decimal integer >= 0, or -1 when it is not one: empty, a
    sign, any non-digit, or more than 18 digits."""
    var b = s.as_bytes()
    if len(b) == 0 or len(b) > MAX_DIGITS:
        return -1
    var v = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            return -1
        v = v * 10 + (c - 48)
    return v


def saturating_add(a: Int, b: Int) -> Int:
    """`a + b` for two counts, held below 10^18 so a sum of hit counts from
    many reports cannot wrap."""
    comptime CAP: Int = 999_999_999_999_999_999
    if a >= CAP - b:
        return CAP
    return a + b


def is_hex(c: Int) -> Bool:
    return (c >= 48 and c <= 57) or (c >= 97 and c <= 102) or (c >= 65 and c <= 70)


def bytes_less(a: String, b: String) -> Bool:
    """Byte order (for UTF-8, code point order)."""
    var ab = a.as_bytes()
    var bb = b.as_bytes()
    var n = min(len(ab), len(bb))
    for i in range(n):
        if ab[i] != bb[i]:
            return Int(ab[i]) < Int(bb[i])
    return len(ab) < len(bb)


def sort_strings(mut xs: List[String]):
    """Sorts in byte order (a stable merge sort)."""
    var n = len(xs)
    if n < 2:
        return
    var tmp = xs.copy()
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if bytes_less(xs[j], xs[i]):
                    tmp[k] = xs[j]
                    j += 1
                else:
                    tmp[k] = xs[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = xs[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = xs[j]
                j += 1
                k += 1
            lo = hi
        xs = tmp.copy()
        width *= 2


def sort_ints(mut xs: List[Int]):
    """Sorts ascending (a merge sort)."""
    var n = len(xs)
    if n < 2:
        return
    var tmp = xs.copy()
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if xs[j] < xs[i]:
                    tmp[k] = xs[j]
                    j += 1
                else:
                    tmp[k] = xs[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = xs[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = xs[j]
                j += 1
                k += 1
            lo = hi
        xs = tmp.copy()
        width *= 2


def dirname(p: String) -> String:
    """Everything before the last `/` of `p`, or the empty string."""
    var i = p.rfind("/")
    if i < 0:
        return String("")
    return substr(p, 0, i)


def first_segment(p: String) -> String:
    """Everything before the first `/` of `p` (all of `p` when it has none)."""
    var i = p.find("/")
    if i < 0:
        return p
    return substr(p, 0, i)


def render_bp(bp: Int) -> String:
    """Basis points as a percentage with two decimals: 6666 -> `66.66%`."""
    var frac = bp % 100
    var pad = String("0") if frac < 10 else String("")
    return String(bp // 100) + String(".") + pad + String(frac) + String("%")


def basis_points(hit: Int, found: Int) -> Int:
    """`hit / found` in basis points, rounded down; -1 when `found` is 0."""
    if found <= 0:
        return -1
    return hit * 10000 // found


def sort_by_keys(keys: List[String]) -> List[Int]:
    """The indices of `keys` in byte order of their keys; equal keys keep
    their order (a stable merge sort)."""
    var idx = List[Int](capacity=len(keys))
    for i in range(len(keys)):
        idx.append(i)
    var n = len(idx)
    if n < 2:
        return idx^
    var tmp = idx.copy()
    var width = 1
    while width < n:
        var lo = 0
        while lo < n:
            var mid = min(lo + width, n)
            var hi = min(lo + 2 * width, n)
            var i = lo
            var j = mid
            var k = lo
            while i < mid and j < hi:
                if bytes_less(keys[idx[j]], keys[idx[i]]):
                    tmp[k] = idx[j]
                    j += 1
                else:
                    tmp[k] = idx[i]
                    i += 1
                k += 1
            while i < mid:
                tmp[k] = idx[i]
                i += 1
                k += 1
            while j < hi:
                tmp[k] = idx[j]
                j += 1
                k += 1
            lo = hi
        idx = tmp.copy()
        width *= 2
    return idx^


def pad_int(v: Int, width: Int) -> String:
    """`v` (>= 0) in decimal, zero-padded on the left to `width` digits, so
    that byte order of the text is numeric order."""
    var s = String(v)
    var out = String("")
    for _ in range(width - s.byte_length()):
        out += String("0")
    return out + s


def line_key(path: String, line: Int) -> String:
    """A sort key ordering by path (byte order), then by line."""
    return path + String("\x00") + pad_int(line, 12)


def trim(s: String) -> String:
    """`s` without leading or trailing spaces and tabs."""
    var b = s.as_bytes()
    var a = 0
    var z = len(b)
    while a < z and (b[a] == UInt8(32) or b[a] == UInt8(9)):
        a += 1
    while z > a and (b[z - 1] == UInt8(32) or b[z - 1] == UInt8(9)):
        z -= 1
    return String(s[byte=a:z])


def join(parts: List[String], sep: String) -> String:
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += sep
        out += parts[i]
    return out^


def render_bp_or_na(bp: Int) -> String:
    """`render_bp`, or `n/a` for -1."""
    if bp < 0:
        return String("n/a")
    return render_bp(bp)


def truncate_utf8(s: String, limit: Int) -> String:
    """`s` cut to at most `limit` bytes, never inside a UTF-8 sequence."""
    var n = s.byte_length()
    if n <= limit:
        return s
    var b = s.as_bytes()
    var cut = limit
    while cut > 0 and (Int(b[cut]) & 0xC0) == 0x80:
        cut -= 1
    return String(s[byte=0:cut])
