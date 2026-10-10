# =============================================================================
# komira_mail_message/parse.mojo -- reading a message and its MIME parts.
# =============================================================================
#
# `parse_message` reads an RFC 5322 message over bytes into a `Message`: its
# header fields and a list of parts in depth-first order, part 0 being the
# message itself. A part whose media type is `multipart/*` (RFC 2046 section
# 5.1) is split at its delimiter lines into child parts; every other part is a
# leaf (`message/rfc822` included: it is not opened). Bodies are never
# converted: `raw_body` is the octets as written, `decoded_body` undoes the
# `Content-Transfer-Encoding`, and a body in any charset or none is returned
# as bytes.
#
# RFC 2045 section 5.2: a missing or unreadable `Content-Type` is
# `text/plain` (inside a `multipart/digest` too, where RFC 2046 section
# 5.1.5 would make it `message/rfc822`). A multipart needs a `boundary`
# parameter of 1 to 70 RFC 2046 `bchars`, not ending in a space. A
# delimiter line is `--boundary` (the close delimiter `--boundary--`) at
# the start of a line, then only white space;
# the line break before it belongs to it. The preamble and the epilogue are
# dropped. A multipart with no delimiter line is refused as `Syntax`; one
# whose close delimiter is missing ends its last part at the end of its body.
#
# Limits: a part deeper than `max_depth` multiparts (part 0 is at depth 0)
# or a part beyond `max_parts` is refused as `Limit` before it is read, so
# work and memory stay bounded by the input size.
#
# Views: `text_part` and `html_part` are the first leaf (depth first) of
# media type `text/plain` and `text/html` whose disposition is not
# `attachment`; `attachments` is every other leaf.
# =============================================================================

from komira_encoding import base64_decode

from .chars import (
    CR,
    HYPHEN,
    LF,
    append_range,
    equals_ignore_case,
    is_alpha,
    is_digit,
    is_wsp,
    lower_ascii_string,
    range_bytes,
)
from .errors import ENCODING, LIMIT, SYNTAX, message_error
from .header import HeaderField, split_header_fields_at
from .params import MediaHeader, Param, parse_media_header
from .quoted_printable import quoted_printable_decode
from .encoded_word import decode_header_text

comptime MAX_DEPTH = 8
"""The default deepest multipart nesting `parse_message` reads."""

comptime MAX_PARTS = 128
"""The default largest number of parts `parse_message` reads."""

comptime _FN: StaticString = "parse_message"


def _first(headers: List[HeaderField], name: StaticString) -> Optional[Int]:
    for i in range(len(headers)):
        if equals_ignore_case(headers[i].name().as_bytes(), name.as_bytes()):
            return i
    return None


struct Part(Copyable, Movable):
    """One MIME entity of a message; see the module header."""

    var _headers: List[HeaderField]
    var _content_type: MediaHeader
    var _disposition: MediaHeader
    var _encoding: String
    var _body_start: Int
    var _body_end: Int
    var _depth: Int
    var _parent: Int
    var _children: List[Int]

    def __init__(
        out self,
        var headers: List[HeaderField],
        body_start: Int,
        body_end: Int,
        depth: Int,
        parent: Int,
    ) raises:
        var ct = _first(headers, "Content-Type")
        if ct:
            self._content_type = parse_media_header(Span(headers[ct.value()]._value))
        else:
            self._content_type = MediaHeader(String(""), List[Param]())
        var cd = _first(headers, "Content-Disposition")
        if cd:
            self._disposition = parse_media_header(Span(headers[cd.value()]._value))
        else:
            self._disposition = MediaHeader(String(""), List[Param]())
        var cte = _first(headers, "Content-Transfer-Encoding")
        if cte:
            var v = headers[cte.value()]._value.copy()
            self._encoding = lower_ascii_string(Span(v), 0, len(v))
        else:
            self._encoding = String("7bit")
        self._headers = headers^
        self._body_start = body_start
        self._body_end = body_end
        self._depth = depth
        self._parent = parent
        self._children = List[Int]()

    def headers(self) -> List[HeaderField]:
        return self._headers.copy()

    def header(self, name: String) -> Optional[HeaderField]:
        """The first field named `name` (any case)."""
        for i in range(len(self._headers)):
            if self._headers[i].is_named(name):
                return Optional[HeaderField](self._headers[i].copy())
        return None

    def media_type(self) -> String:
        """`type/subtype` in lower case; `text/plain` when the part has no
        readable `Content-Type`."""
        var v = self._content_type.value()
        if v.find("/") < 0:
            return String("text/plain")
        return v

    def is_multipart(self) -> Bool:
        return self.media_type().startswith("multipart/")

    def param(self, name: String) -> Optional[String]:
        """A `Content-Type` parameter (lower-case name), decoded."""
        return self._content_type.param(name)

    def charset(self) -> String:
        """The `charset` parameter in lower case, or empty."""
        var c = self._content_type.param(String("charset"))
        if not c:
            return String("")
        return c.value().lower()

    def disposition(self) -> String:
        """`inline`, `attachment`, ... in lower case, or empty."""
        return self._disposition.value()

    def filename(self) raises -> Optional[String]:
        """The `Content-Disposition` `filename`, else the `Content-Type`
        `name`; RFC 2231 forms decoded, and RFC 2047 encoded words in a plain
        (not RFC 2231) value decoded too (written by some mailers, RFC 2231
        section 1)."""
        var f = self._disposition.param(String("filename"))
        var extended = self._disposition.param_is_extended(String("filename"))
        if not f:
            f = self._content_type.param(String("name"))
            extended = self._content_type.param_is_extended(String("name"))
        if not f:
            return None
        if extended:
            return f
        return Optional[String](decode_header_text(f.value()))

    def transfer_encoding(self) -> String:
        """The `Content-Transfer-Encoding` in lower case; `7bit` when
        absent."""
        return self._encoding

    def depth(self) -> Int:
        return self._depth

    def parent(self) -> Int:
        """The index of the enclosing multipart, or -1 for the message."""
        return self._parent

    def children(self) -> List[Int]:
        return self._children.copy()


def _is_bchar_nospace(c: UInt8) -> Bool:
    """RFC 2046 `bcharsnospace`: letters, digits and `'()+_,-./:=?`."""
    return (
        is_alpha(c)
        or is_digit(c)
        or c == 39
        or c == 40
        or c == 41
        or c == 43
        or c == 95
        or c == 44
        or c == 45
        or c == 46
        or c == 47
        or c == 58
        or c == 61
        or c == 63
    )


def _check_boundary(boundary: Span[UInt8, _], position: Int) raises:
    var n = len(boundary)
    if n == 0 or n > 70 or boundary[n - 1] == 32:
        raise message_error(SYNTAX, _FN, "an invalid multipart boundary", position)
    for i in range(n):
        if boundary[i] != 32 and not _is_bchar_nospace(boundary[i]):
            raise message_error(
                SYNTAX, _FN, "an invalid multipart boundary", position
            )


def _before_break(data: Span[UInt8, _], part_start: Int, line: Int) -> Int:
    """The end of a part's content: before the line break that precedes the
    delimiter line starting at `line`."""
    var e = line
    if e > part_start and data[e - 1] == LF:
        e -= 1
        if e > part_start and data[e - 1] == CR:
            e -= 1
    return e


def _split_multipart(
    data: Span[UInt8, _], start: Int, end: Int, boundary: Span[UInt8, _]
) raises -> List[Int]:
    """The `[start, end)` pairs, flattened, of the parts of the multipart
    body `data[start:end]`."""
    var m = len(boundary)
    var ranges = List[Int]()
    var part_start = -1
    var found = False
    var i = start
    while i < end:
        var lf = i
        while lf < end and data[lf] != LF:
            lf += 1
        var content_end = lf
        if lf > i and data[lf - 1] == CR:
            content_end = lf - 1
        var is_delimiter = content_end - i >= m + 2 and data[i] == HYPHEN and data[i + 1] == HYPHEN
        if is_delimiter:
            for k in range(m):
                if data[i + 2 + k] != boundary[k]:
                    is_delimiter = False
                    break
        var close = False
        if is_delimiter:
            var after = i + 2 + m
            if after + 2 <= content_end and data[after] == HYPHEN and data[after + 1] == HYPHEN:
                close = True
                after += 2
            for k in range(after, content_end):
                if not is_wsp(data[k]):
                    is_delimiter = False
                    break
        if is_delimiter:
            if part_start >= 0:
                ranges.append(part_start)
                ranges.append(_before_break(data, part_start, i))
            found = True
            if close:
                return ranges^
            part_start = min(lf + 1, end)
        i = lf + 1
    if not found:
        raise message_error(
            SYNTAX, _FN, "a multipart body without a delimiter line", start
        )
    if part_start >= 0:
        ranges.append(part_start)
        ranges.append(end)
    return ranges^


def _parse_entity(
    data: Span[UInt8, _],
    start: Int,
    end: Int,
    depth: Int,
    parent: Int,
    mut parts: List[Part],
    max_depth: Int,
    max_parts: Int,
) raises:
    if depth > max_depth:
        raise message_error(
            LIMIT, _FN, "parts nested deeper than the limit", start
        )
    if len(parts) >= max_parts:
        raise message_error(LIMIT, _FN, "more parts than the limit", start)
    var block = split_header_fields_at(data, start, end, _FN)
    var body_start = block.body_start
    var index = len(parts)
    parts.append(Part(block.fields.copy(), body_start, end, depth, parent))
    if parent >= 0:
        parts[parent]._children.append(index)
    if not parts[index].is_multipart():
        return
    var boundary = parts[index].param(String("boundary"))
    if not boundary:
        raise message_error(
            SYNTAX, _FN, "a multipart without a boundary parameter", start
        )
    var b = boundary.value()
    _check_boundary(b.as_bytes(), start)
    var ranges = _split_multipart(data, body_start, end, b.as_bytes())
    for k in range(0, len(ranges), 2):
        _parse_entity(
            data, ranges[k], ranges[k + 1], depth + 1, index, parts, max_depth, max_parts
        )


struct Message(Copyable, Movable):
    """A parsed message: its bytes and its parts (part 0 is the message)."""

    var _raw: List[UInt8]
    var _parts: List[Part]

    def __init__(out self, var raw: List[UInt8], var parts: List[Part]):
        self._raw = raw^
        self._parts = parts^

    def headers(self) -> List[HeaderField]:
        """The message's header fields, in order."""
        return self._parts[0].headers()

    def header(self, name: String) -> Optional[HeaderField]:
        """The first message header field named `name` (any case)."""
        return self._parts[0].header(name)

    def header_all(self, name: String) -> List[HeaderField]:
        """Every message header field named `name`, in order."""
        var out = List[HeaderField]()
        for i in range(len(self._parts[0]._headers)):
            if self._parts[0]._headers[i].is_named(name):
                out.append(self._parts[0]._headers[i].copy())
        return out^

    def subject(self) raises -> Optional[String]:
        """The `Subject`, RFC 2047 encoded words decoded."""
        var s = self.header(String("Subject"))
        if not s:
            return None
        return Optional[String](s.value().text())

    def body_start(self) -> Int:
        """The index of the first body octet (after the empty line)."""
        return self._parts[0]._body_start

    def part_count(self) -> Int:
        return len(self._parts)

    def part(self, index: Int) -> Part:
        return self._parts[index].copy()

    def raw_body(self, index: Int) -> List[UInt8]:
        """Part `index`'s body as written (for a multipart: its preamble,
        delimiters, parts and epilogue)."""
        var p = Span(self._raw)
        return range_bytes(p, self._parts[index]._body_start, self._parts[index]._body_end)

    def decoded_body(self, index: Int) raises -> List[UInt8]:
        """Part `index`'s body with its `Content-Transfer-Encoding` undone:
        `7bit`, `8bit` and `binary` as written, `quoted-printable` and
        `base64` decoded (characters outside the base64 alphabet are
        dropped first, RFC 2045 section 6.8)."""
        var raw = self.raw_body(index)
        var cte = self._parts[index]._encoding
        if cte == "7bit" or cte == "8bit" or cte == "binary" or cte == "":
            return raw^
        if cte == "quoted-printable":
            return quoted_printable_decode(Span(raw))
        if cte == "base64":
            var alphabet = List[UInt8](capacity=len(raw))
            for i in range(len(raw)):
                var c = raw[i]
                if is_alpha(c) or is_digit(c) or c == 43 or c == 47 or c == 61:
                    alphabet.append(c)
            try:
                return base64_decode(Span(alphabet))
            except:
                raise message_error(
                    ENCODING, "decoded_body", "base64 that does not decode"
                )
        raise message_error(
            ENCODING, "decoded_body", "an unknown Content-Transfer-Encoding"
        )

    def _first_body(self, media: StaticString) -> Optional[Int]:
        for i in range(len(self._parts)):
            if self._parts[i].is_multipart():
                continue
            if self._parts[i].disposition() == "attachment":
                continue
            if self._parts[i].media_type() == media:
                return i
        return None

    def text_part(self) -> Optional[Int]:
        """The index of the message's plain text, if it has one."""
        return self._first_body("text/plain")

    def html_part(self) -> Optional[Int]:
        """The index of the message's HTML, if it has one."""
        return self._first_body("text/html")

    def attachments(self) -> List[Int]:
        """The indexes of every leaf part that is not `text_part` or
        `html_part`."""
        var text = self.text_part()
        var html = self.html_part()
        var out = List[Int]()
        for i in range(len(self._parts)):
            if self._parts[i].is_multipart():
                continue
            if text and text.value() == i:
                continue
            if html and html.value() == i:
                continue
            out.append(i)
        return out^


def parse_message(
    data: Span[UInt8, _], max_depth: Int = MAX_DEPTH, max_parts: Int = MAX_PARTS
) raises -> Message:
    """`data` as a message; see the module header."""
    var parts = List[Part]()
    _parse_entity(data, 0, len(data), 0, -1, parts, max_depth, max_parts)
    return Message(range_bytes(data, 0, len(data)), parts^)
