# Command-line parsing: the tag, the command word, and arguments that are
# atoms or quoted strings. Everything here works on a line that was checked to
# be printable ASCII (`is_printable_ascii`), so a `String` made from it is
# valid text.

comptime SP: UInt8 = 0x20
comptime DQUOTE: UInt8 = 0x22
comptime BACKSLASH: UInt8 = 0x5C


def is_printable_ascii(line: Span[UInt8, _]) -> Bool:
    """Every byte is 0x20 to 0x7E. RFC 3501 command lines (without literals)
    are 7-bit text; anything else (a control byte, a byte over 0x7F) is
    refused before it reaches a parser."""
    for i in range(len(line)):
        var c = line[i]
        if c < 0x20 or c > 0x7E:
            return False
    return True


def ascii_slice(bs: Span[UInt8, _], start: Int, end: Int) -> String:
    """`bs[start:end]` as a String. The bytes are known to be ASCII."""
    return String(unsafe_from_utf8=bs[start:end])


def upper_ascii(s: String) -> String:
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs))
    for i in range(len(bs)):
        var c = bs[i]
        if c >= 0x61 and c <= 0x7A:
            c -= 32
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def lower_ascii(s: String) -> String:
    var bs = s.as_bytes()
    var out = List[UInt8](capacity=len(bs))
    for i in range(len(bs)):
        var c = bs[i]
        if c >= 0x41 and c <= 0x5A:
            c += 32
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def eq_ci(a: String, b: String) -> Bool:
    """ASCII case-insensitive equality."""
    return lower_ascii(a) == lower_ascii(b)


def valid_tag(tag: String) -> Bool:
    """A tag is one or more ASTRING-CHARs other than `+` (RFC 3501 section 9:
    any printable ASCII except `( ) { SP % * " \\` and `+`; `]` is allowed),
    at most 64 bytes. The server echoes it, so it must not be able to carry
    anything else."""
    var bs = tag.as_bytes()
    if len(bs) == 0 or len(bs) > 64:
        return False
    for i in range(len(bs)):
        var c = bs[i]
        if c < 0x21 or c > 0x7E:
            return False
        if (
            c == 0x28
            or c == 0x29
            or c == 0x7B
            or c == 0x25
            or c == 0x2A
            or c == DQUOTE
            or c == BACKSLASH
            or c == 0x2B
        ):
            return False
    return True


def literal_tail(line: Span[UInt8, _]) -> Int:
    """Does the line end in a literal announcement? -1: no. 0: `{n}`, the
    client waits for a `+` before it sends the n bytes. 1: `{n+}`, the n bytes
    follow at once (RFC 7888). Neither is supported; the caller answers BAD,
    and closes for the second, since its bytes are already on the way."""
    var n = len(line)
    if n < 3 or line[n - 1] != 0x7D:
        return -1
    var j = n - 2
    var plus = False
    if line[j] == 0x2B:
        plus = True
        j -= 1
    var digits = 0
    while j >= 0 and line[j] >= 0x30 and line[j] <= 0x39:
        digits += 1
        j -= 1
    if digits == 0 or j < 0 or line[j] != 0x7B:
        return -1
    if plus:
        return 1
    return 0


struct CommandLine(Movable):
    """A line split into its tag, its command word (upper case) and the rest
    (arguments, with no leading or trailing spaces)."""

    var tag: String
    var cmd: String
    var args: String

    def __init__(out self):
        self.tag = String("")
        self.cmd = String("")
        self.args = String("")


def split_command(line: String) -> CommandLine:
    var bs = line.as_bytes()
    var n = len(bs)
    var out = CommandLine()
    var i = 0
    while i < n and bs[i] != SP:
        i += 1
    out.tag = ascii_slice(bs, 0, i)
    while i < n and bs[i] == SP:
        i += 1
    var c0 = i
    while i < n and bs[i] != SP:
        i += 1
    out.cmd = upper_ascii(ascii_slice(bs, c0, i))
    while i < n and bs[i] == SP:
        i += 1
    var e = n
    while e > i and bs[e - 1] == SP:
        e -= 1
    out.args = ascii_slice(bs, i, e)
    return out^


def _astring_char(c: UInt8, wildcards: Bool) -> Bool:
    """ASTRING-CHAR: printable ASCII except `( ) { SP % * " \\`; `]` is
    allowed. With `wildcards`, `%` and `*` are allowed too (LIST patterns)."""
    if c <= 0x20 or c > 0x7E:
        return False
    if c == 0x28 or c == 0x29 or c == 0x7B or c == DQUOTE or c == BACKSLASH:
        return False
    if (c == 0x25 or c == 0x2A) and not wildcards:
        return False
    return True


struct ArgCursor(Movable):
    """A reader over the arguments of a command: `next_astring` takes one
    atom or quoted string; `at_end` says nothing is left. `ok` turns False at
    the first malformed argument, and stays False."""

    var text: String
    var pos: Int
    var ok: Bool

    def __init__(out self, var text: String):
        self.text = text^
        self.pos = 0
        self.ok = True

    def at_end(self) -> Bool:
        return self.pos >= self.text.byte_length()

    def next_astring(mut self, wildcards: Bool = False) -> String:
        """One argument: an atom (ASTRING-CHARs up to a space) or a quoted
        string (`\\"` and `\\\\` are the only escapes). It must be followed by
        a space or the end. On any other shape `ok` becomes False and the
        result is empty."""
        if not self.ok:
            return String("")
        var bs = self.text.as_bytes()
        var n = len(bs)
        var p = self.pos
        while p < n and bs[p] == SP:
            p += 1
        if p >= n:
            self.ok = False
            return String("")
        var out = List[UInt8]()
        if bs[p] == DQUOTE:
            p += 1
            var closed = False
            while p < n:
                var c = bs[p]
                if c == BACKSLASH:
                    p += 1
                    if p >= n or (bs[p] != DQUOTE and bs[p] != BACKSLASH):
                        self.ok = False
                        return String("")
                    out.append(bs[p])
                    p += 1
                elif c == DQUOTE:
                    closed = True
                    p += 1
                    break
                else:
                    out.append(c)
                    p += 1
            if not closed:
                self.ok = False
                return String("")
        else:
            var start = p
            while p < n and bs[p] != SP:
                if not _astring_char(bs[p], wildcards):
                    self.ok = False
                    return String("")
                p += 1
            for i in range(start, p):
                out.append(bs[i])
        if p < n and bs[p] != SP:
            self.ok = False
            return String("")
        self.pos = p
        return String(unsafe_from_utf8=Span(out))

    def rest(self) -> String:
        """What is left after the arguments read so far, without leading
        spaces."""
        var bs = self.text.as_bytes()
        var n = len(bs)
        var p = self.pos
        while p < n and bs[p] == SP:
            p += 1
        return ascii_slice(bs, p, n)


struct Words(Movable):
    """`text` split at its first run of spaces."""

    var first: String
    var rest: String

    def __init__(out self):
        self.first = String("")
        self.rest = String("")


def split_word(text: String) -> Words:
    """The first space-separated word of `text`, and what follows it without
    leading or trailing spaces."""
    var bs = text.as_bytes()
    var n = len(bs)
    var out = Words()
    var i = 0
    while i < n and bs[i] == SP:
        i += 1
    var s = i
    while i < n and bs[i] != SP:
        i += 1
    out.first = ascii_slice(bs, s, i)
    while i < n and bs[i] == SP:
        i += 1
    var e = n
    while e > i and bs[e - 1] == SP:
        e -= 1
    out.rest = ascii_slice(bs, i, e)
    return out^
