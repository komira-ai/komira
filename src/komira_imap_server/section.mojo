# The section of a `BODY[<section>]<partial>` FETCH item (RFC 3501 section
# 6.4.5), and where its bytes are.
#
# `parse_body_item` reads the item text. A section is a path of part numbers
# (`1.2.3`) and then HEADER, HEADER.FIELDS (list), HEADER.FIELDS.NOT (list),
# TEXT or MIME; the path may be empty (the whole message, or its HEADER and
# TEXT); MIME needs a path. A partial is `<origin.length>`, the length at
# least 1: `<0.0>` is not IMAP and is refused (BAD) with any other malformed
# item.
#
# `locate` finds the bytes: the whole stored message and its header and text
# are slices of the stored bytes and need no MIME parse (so they work on mail
# a parser would refuse), a header-field subset is built, and a numbered part
# goes through `komira_mail_message.Message.part_by_section`. A path that
# crosses a `message/rfc822` opens it with `Message.open_rfc822` under the
# parent's shared limits; HEADER, HEADER.FIELDS and TEXT of a part exist only
# for a `message/rfc822` (they are the nested message's), MIME is the part's
# own header block. A section that does not exist is NIL. The parse and the
# opening can raise (`Syntax`, `Limit`, `InvalidValue`): the caller answers
# `NO [UNAVAILABLE]` for that FETCH.
#
# The result is a `Located`: which bytes (a window into the stored bytes, a
# part's header or body of a parsed message, or bytes built here), so the
# reply copies them once, into the reply queue, from a borrowed view.

from komira_mail_message import Message, parse_message

from .headers import header_len, select_fields

comptime SEC_NONE: Int = 0
comptime SEC_HEADER: Int = 1
comptime SEC_FIELDS: Int = 2
comptime SEC_FIELDS_NOT: Int = 3
comptime SEC_TEXT: Int = 4
comptime SEC_MIME: Int = 5

# Where the bytes of a `Located` are.
comptime LOC_NIL: Int = 0
comptime LOC_RAW: Int = 1  # the stored bytes
comptime LOC_HEADER: Int = 2  # header_bytes(part) of messages[src]
comptime LOC_BODY: Int = 3  # body_bytes(part) of messages[src]
comptime LOC_OWNED: Int = 4  # `owned`


struct SectionSpec(Copyable, Movable):
    """A parsed `BODY[...]<...>` item."""

    var ok: Bool
    var path: List[Int]
    var suffix: Int
    var names: List[String]
    var has_partial: Bool
    var origin: Int
    var length: Int

    def __init__(out self):
        self.ok = False
        self.path = List[Int]()
        self.suffix = SEC_NONE
        self.names = List[String]()
        self.has_partial = False
        self.origin = 0
        self.length = 0


def _is_digit(c: UInt8) -> Bool:
    return c >= 0x30 and c <= 0x39


def _upper(b: Span[UInt8, _]) -> String:
    var out = List[UInt8](capacity=len(b))
    for i in range(len(b)):
        var c = b[i]
        if c >= 0x61 and c <= 0x7A:
            c -= 32
        out.append(c)
    return String(unsafe_from_utf8=Span(out))


def _parse_names(b: Span[UInt8, _], mut names: List[String]) -> Bool:
    """` (a b "c")`: a space, then a parenthesised list of one or more
    header field names, atoms or quoted strings."""
    var n = len(b)
    if n < 4 or b[0] != 0x20 or b[1] != 0x28 or b[n - 1] != 0x29:
        return False
    var i = 2
    var end = n - 1
    while i < end:
        while i < end and b[i] == 0x20:
            i += 1
        if i >= end:
            break
        var name = List[UInt8]()
        if b[i] == 0x22:
            i += 1
            while i < end and b[i] != 0x22:
                if b[i] == 0x5C and i + 1 < end:
                    i += 1
                name.append(b[i])
                i += 1
            if i >= end:
                return False
            i += 1
            if i < end and b[i] != 0x20:
                return False
        else:
            while i < end and b[i] != 0x20:
                if b[i] == 0x22 or b[i] == 0x28 or b[i] == 0x29:
                    return False
                name.append(b[i])
                i += 1
        if len(name) == 0:
            return False
        for k in range(len(name)):
            if name[k] <= 0x20 or name[k] > 0x7E or name[k] == 0x3A:
                return False
        names.append(String(unsafe_from_utf8=Span(name)))
    return len(names) > 0


def _parse_partial(b: Span[UInt8, _], mut spec: SectionSpec) -> Bool:
    """`<origin.length>`."""
    var n = len(b)
    if n < 5 or b[0] != 0x3C or b[n - 1] != 0x3E:
        return False
    var i = 1
    var origin = 0
    var digits = 0
    while i < n - 1 and _is_digit(b[i]):
        origin = origin * 10 + Int(b[i] - 0x30)
        digits += 1
        i += 1
        if digits > 10:
            return False
    if digits == 0 or i >= n - 1 or b[i] != 0x2E:
        return False
    i += 1
    var length = 0
    digits = 0
    while i < n - 1 and _is_digit(b[i]):
        length = length * 10 + Int(b[i] - 0x30)
        digits += 1
        i += 1
        if digits > 10:
            return False
    if digits == 0 or i != n - 1 or length == 0:
        return False
    spec.has_partial = True
    spec.origin = origin
    spec.length = length
    return True


def parse_body_item(text: String) -> SectionSpec:
    """The section of an item `BODY[...]`, `BODY.PEEK[...]` or either with a
    partial. `ok` is False for anything malformed."""
    var spec = SectionSpec()
    var b = text.as_bytes()
    var n = len(b)
    var lb = -1
    for i in range(n):
        if b[i] == 0x5B:
            lb = i
            break
    if lb < 0:
        return spec^
    var rb = -1
    for i in range(lb + 1, n):
        if b[i] == 0x5D:
            rb = i
            break
    if rb < 0:
        return spec^
    if rb + 1 < n:
        if not _parse_partial(b[rb + 1 : n], spec):
            return spec^
    var c = b[lb + 1 : rb]
    var m = len(c)
    var i = 0
    var dot_pending = False
    while i < m and _is_digit(c[i]):
        var value = 0
        var digits = 0
        var first = c[i]
        while i < m and _is_digit(c[i]):
            value = value * 10 + Int(c[i] - 0x30)
            digits += 1
            i += 1
            if digits > 9:
                return spec^
        if value == 0 or (digits > 1 and first == 0x30):
            return spec^
        spec.path.append(value)
        dot_pending = False
        if i < m and c[i] == 0x2E:
            i += 1
            dot_pending = True
            if i < m and _is_digit(c[i]):
                continue
        break
    var rest = c[i:m]
    if len(rest) == 0:
        if dot_pending:
            return spec^
        spec.ok = True
        return spec^
    if len(spec.path) > 0 and not dot_pending:
        return spec^
    var up = _upper(rest)
    if up == "HEADER":
        spec.suffix = SEC_HEADER
    elif up == "TEXT":
        spec.suffix = SEC_TEXT
    elif up == "MIME":
        if len(spec.path) == 0:
            return spec^
        spec.suffix = SEC_MIME
    elif up.startswith("HEADER.FIELDS.NOT"):
        spec.suffix = SEC_FIELDS_NOT
        if not _parse_names(rest[17 : len(rest)], spec.names):
            return spec^
    elif up.startswith("HEADER.FIELDS"):
        spec.suffix = SEC_FIELDS
        if not _parse_names(rest[13 : len(rest)], spec.names):
            return spec^
    else:
        return spec^
    spec.ok = True
    return spec^


def render_section(spec: SectionSpec) -> String:
    """The section as a reply names it: numbers joined by dots, then the
    keyword in capitals (field names as the client wrote them)."""
    var out = String("")
    for i in range(len(spec.path)):
        if i > 0:
            out += "."
        out += String(spec.path[i])
    if spec.suffix == SEC_NONE:
        return out^
    if len(spec.path) > 0:
        out += "."
    if spec.suffix == SEC_HEADER:
        out += "HEADER"
    elif spec.suffix == SEC_TEXT:
        out += "TEXT"
    elif spec.suffix == SEC_MIME:
        out += "MIME"
    else:
        if spec.suffix == SEC_FIELDS:
            out += "HEADER.FIELDS ("
        else:
            out += "HEADER.FIELDS.NOT ("
        for i in range(len(spec.names)):
            if i > 0:
                out += " "
            out += spec.names[i]
        out += ")"
    return out^


struct Located(Copyable, Movable):
    """The bytes of a section: a window `off`, `length` into the base named
    by `mode` (see `LOC_*`)."""

    var mode: Int
    var src: Int
    var part: Int
    var off: Int
    var length: Int
    var owned: List[UInt8]

    def __init__(out self):
        self.mode = LOC_NIL
        self.src = 0
        self.part = 0
        self.off = 0
        self.length = 0
        self.owned = List[UInt8]()


def ensure_top(
    bytes: List[UInt8], mut messages: List[Message], mut links: List[Int]
) raises:
    """`messages[0]` is the parse of `bytes`; `links[i]` says where
    `messages[i]` came from: `parent * 2^32 + part` for a nested message
    (see `nested`), -1 for the top one."""
    if len(messages) == 0:
        messages.append(parse_message(Span(bytes)))
        links.append(-1)


def nested(
    mut messages: List[Message], mut links: List[Int], parent: Int, part: Int
) raises -> Int:
    """The index in `messages` of the `message/rfc822` `part` of
    `messages[parent]`, opened on the first ask and found again after, so a
    FETCH of many items opens (copies and parses) each nested message once."""
    var key = parent * 4_294_967_296 + part
    for i in range(1, len(links)):
        if links[i] == key:
            return i
    var opened = messages[parent].open_rfc822(part)
    messages.append(opened^)
    links.append(key)
    return len(messages) - 1


def _walk(
    spec: SectionSpec,
    bytes: List[UInt8],
    mut messages: List[Message],
    mut links: List[Int],
    mut m: Int,
    mut p: Int,
) raises -> Bool:
    """Follow the numbers of the path; `m` is the message the last number
    ended in and `p` the part. False when the path names no part."""
    ensure_top(bytes, messages, links)
    m = 0
    var seg = String("")
    p = 0
    var k = len(spec.path)
    for i in range(k):
        if seg.byte_length() > 0:
            seg += "."
        seg += String(spec.path[i])
        var found = messages[m].part_by_section(seg)
        if not found:
            return False
        p = found.value()
        if i < k - 1 and messages[m].part(p).media_type() == "message/rfc822":
            m = nested(messages, links, m, p)
            seg = String("")
    return True


def locate(
    spec: SectionSpec,
    bytes: List[UInt8],
    mut messages: List[Message],
    mut links: List[Int],
) raises -> Located:
    """Where the section's bytes are, before the partial. `messages[0]`, once
    present, is the parse of `bytes`; nested messages are appended after it,
    each once (`links`)."""
    var loc = Located()
    var n = len(bytes)
    if len(spec.path) == 0:
        var hl = header_len(Span(bytes))
        loc.mode = LOC_RAW
        if spec.suffix == SEC_NONE:
            loc.off = 0
            loc.length = n
        elif spec.suffix == SEC_HEADER:
            loc.length = hl
        elif spec.suffix == SEC_TEXT:
            loc.off = hl
            loc.length = n - hl
        else:
            loc.mode = LOC_OWNED
            loc.owned = select_fields(
                Span(bytes)[0:hl], spec.names, spec.suffix == SEC_FIELDS_NOT
            )
            loc.length = len(loc.owned)
        return loc^
    var m = 0
    var p = 0
    if not _walk(spec, bytes, messages, links, m, p):
        return loc^
    if spec.suffix == SEC_NONE or spec.suffix == SEC_MIME:
        loc.mode = LOC_BODY if spec.suffix == SEC_NONE else LOC_HEADER
        loc.src = m
        loc.part = p
        if spec.suffix == SEC_NONE:
            loc.length = messages[m].body_bytes(p).len()
        else:
            loc.length = messages[m].header_bytes(p).len()
        return loc^
    if messages[m].part(p).media_type() != "message/rfc822":
        return loc^
    var q = nested(messages, links, m, p)
    loc.src = q
    loc.part = 0
    if spec.suffix == SEC_HEADER:
        loc.mode = LOC_HEADER
        loc.length = messages[q].header_bytes(0).len()
    elif spec.suffix == SEC_TEXT:
        loc.mode = LOC_BODY
        loc.length = messages[q].body_bytes(0).len()
    else:
        loc.mode = LOC_OWNED
        loc.owned = select_fields(
            messages[q].header_bytes(0).into_span(),
            spec.names,
            spec.suffix == SEC_FIELDS_NOT,
        )
        loc.length = len(loc.owned)
    return loc^


def apply_partial(mut loc: Located, spec: SectionSpec):
    """Narrow the window to `<origin.length>`: truncated at the end of the
    section, empty when the origin is at or past it."""
    if loc.mode == LOC_NIL or not spec.has_partial:
        return
    var start = spec.origin
    if start > loc.length:
        start = loc.length
    var length = loc.length - start
    if length > spec.length:
        length = spec.length
    loc.off += start
    loc.length = length
