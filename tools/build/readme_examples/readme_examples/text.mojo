"""Byte-level string helpers of the Markdown reader. Pure: no I/O.

They are local to this package rather than imported from `buildtools`
(tools/build/inspect), because `buildtools.doc_links` imports this package.
"""


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
    """Python's ASCII whitespace for str.split()."""
    return c == 32 or (c >= 9 and c <= 13) or (c >= 28 and c <= 31)


def indent_of(line: String) -> Int:
    """The number of leading whitespace bytes."""
    var i = 0
    var n = line.byte_length()
    while i < n and is_space(byte_at(line, i)):
        i += 1
    return i


def strip(s: String) -> String:
    var n = s.byte_length()
    var a = 0
    while a < n and is_space(byte_at(s, a)):
        a += 1
    var z = n
    while z > a and is_space(byte_at(s, z - 1)):
        z -= 1
    return substr(s, a, z)


def is_blank(s: String) -> Bool:
    return indent_of(s) == s.byte_length()


def lower_ascii(s: String) -> String:
    var out = List[UInt8]()
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 65 and c <= 90:
            out.append(UInt8(c + 32))
        else:
            out.append(b[i])
    return String(from_utf8_lossy=out)


def split_lines(text: String) -> List[String]:
    """Lines without their newline (and without a CR before it)."""
    var out = List[String]()
    var n = text.byte_length()
    var start = 0
    for i in range(n + 1):
        if i == n or byte_at(text, i) == 10:
            if i == n and start == n:
                break
            var end = i
            if end > start and byte_at(text, end - 1) == 13:
                end -= 1
            out.append(substr(text, start, end))
            start = i + 1
    return out^


def mojo_string_literal(s: String) -> String:
    """`s` as a double-quoted Mojo string literal."""
    var out = String("\"")
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b)):
        var c = Int(b[i])
        if c == 34 or c == 92:
            out += substr(s, start, i) + "\\" + chr(c)
            start = i + 1
        elif c == 10:
            out += substr(s, start, i) + "\\n"
            start = i + 1
    out += suffix(s, start)
    return out + "\""
