"""Files, byte buffers and the few string helpers the tools share."""


def read_file(path: String) raises -> List[UInt8]:
    """Every byte of the file at `path`."""
    with open(path, "r") as f:
        return f.read_bytes()


def slice_string(b: List[UInt8], start: Int, end: Int) -> String:
    """Bytes [start, end) of `b` as a string (invalid UTF-8 becomes U+FFFD)."""
    var sub = List[UInt8](capacity=max(end - start, 0))
    for i in range(start, end):
        sub.append(b[i])
    return String(from_utf8_lossy=sub)


def to_string(b: List[UInt8]) -> String:
    return slice_string(b, 0, len(b))


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


def is_space(c: Int) -> Bool:
    """Python's ASCII whitespace for str.split() and the regex `\\s`."""
    return c == 32 or (c >= 9 and c <= 13) or (c >= 28 and c <= 31)


def is_word(c: Int) -> Bool:
    """The regex `\\w` over ASCII; every non-ASCII byte counts as a letter."""
    return (
        (c >= 48 and c <= 57)
        or (c >= 65 and c <= 90)
        or (c >= 97 and c <= 122)
        or c == 95
        or c >= 128
    )


def split_words(s: String) -> List[String]:
    """Python's str.split() with no argument."""
    var out = List[String]()
    var n = s.byte_length()
    var i = 0
    while i < n:
        while i < n and is_space(byte_at(s, i)):
            i += 1
        var start = i
        while i < n and not is_space(byte_at(s, i)):
            i += 1
        if i > start:
            out.append(substr(s, start, i))
    return out^


def join(items: List[String], sep: String) -> String:
    var out = String()
    for i in range(len(items)):
        if i > 0:
            out += sep
        out += items[i]
    return out^


def bytes_less(a: String, b: String) -> Bool:
    """Byte order, which for UTF-8 is also code point order (Python's)."""
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


def sorted_unique(xs: List[String]) -> List[String]:
    var s = xs.copy()
    sort_strings(s)
    var out = List[String]()
    for i in range(len(s)):
        if i == 0 or s[i] != s[i - 1]:
            out.append(s[i])
    return out^


def dirname(p: String) -> String:
    """Python's os.path.dirname."""
    var i = p.rfind("/")
    if i < 0:
        return String("")
    var head = substr(p, 0, i + 1)
    # Strip trailing slashes unless the head is all slashes.
    var all_slash = True
    for k in range(head.byte_length()):
        if byte_at(head, k) != 47:
            all_slash = False
    if all_slash:
        return head^
    var end = head.byte_length()
    while end > 0 and byte_at(head, end - 1) == 47:
        end -= 1
    return substr(head, 0, end)


def path_join(a: String, b: String) -> String:
    """Python's os.path.join of two components."""
    if b.startswith("/"):
        return b
    if a.byte_length() == 0 or a.endswith("/"):
        return a + b
    return a + "/" + b


def normpath(p: String) -> String:
    """Python's os.path.normpath (POSIX)."""
    if p.byte_length() == 0:
        return String(".")
    var initial = 0
    if p.startswith("/"):
        initial = 1
        if p.startswith("//") and not p.startswith("///"):
            initial = 2
    var comps = List[String]()
    var parts = p.split("/")
    for i in range(len(parts)):
        var c = String(parts[i])
        if c.byte_length() == 0 or c == ".":
            continue
        if c != ".." or (initial == 0 and len(comps) == 0) or (
            len(comps) > 0 and comps[len(comps) - 1] == ".."
        ):
            comps.append(c)
        elif len(comps) > 0:
            _ = comps.pop()
    var out = join(comps, "/")
    if initial == 1:
        out = "/" + out
    elif initial == 2:
        out = "//" + out
    if out.byte_length() == 0:
        return String(".")
    return out^


def hex_byte(v: Int) -> String:
    var digits = String("0123456789abcdef")
    return substr(digits, (v >> 4) & 15, ((v >> 4) & 15) + 1) + substr(
        digits, v & 15, (v & 15) + 1
    )


def octal(v: Int) -> String:
    if v == 0:
        return String("0")
    var out = String()
    var x = v
    while x > 0:
        out = String(x % 8) + out
        x = x // 8
    return out^
