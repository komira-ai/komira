# =============================================================================
# komira_mail_message/header.mojo -- splitting a header block into fields.
# =============================================================================
#
# `split_header_fields` reads RFC 5322 section 2.2 header fields from the
# start of a message (or of a MIME part) up to the empty line that ends them.
# A line ends with CRLF or a bare LF (mail stored on disk often has LF only).
# A line starting with a space or tab continues the field before it (a fold).
# Every other line must hold `name:` with a name of `ftext` (white space
# between the name and the colon, the obsolete form of RFC 5322 section
# 4.5, is accepted and dropped). A line without a colon, a name with another
# byte, or a fold before the first field is refused as `Syntax`. Without an
# empty line the whole input is header and the body is empty.
#
# Each `HeaderField` keeps the field's bytes as written (`raw`: name, colon
# and value with its folds, without the final line break), the name as
# written, and the unfolded value (`value`: each line break before white
# space removed, RFC 5322 section 2.2.3, and the white space around the value
# trimmed). Values are bytes: an 8-bit header is kept, not refused.
# =============================================================================

from .chars import (
    COLON,
    CR,
    LF,
    append_range,
    equals_ignore_case,
    is_ftext,
    is_wsp,
    lossy_string,
    range_bytes,
)
from .encoded_word import decode_header_text
from .errors import SYNTAX, message_error


struct HeaderField(Copyable, Movable):
    """One header field; see the module header."""

    var _name: String
    var _raw: List[UInt8]
    var _value: List[UInt8]

    def __init__(out self, name: String, var raw: List[UInt8], var value: List[UInt8]):
        self._name = name
        self._raw = raw^
        self._value = value^

    def name(self) -> String:
        """The field name as written (`ftext`, so ASCII)."""
        return self._name

    def is_named(self, name: String) -> Bool:
        """The field's name equals `name`, without regard to ASCII case."""
        return equals_ignore_case(self._name.as_bytes(), name.as_bytes())

    def raw(self) -> List[UInt8]:
        """The field as written, folds included, without its final line
        break."""
        return self._raw.copy()

    def value(self) -> List[UInt8]:
        """The unfolded, trimmed field body as bytes."""
        return self._value.copy()

    def text(self) raises -> String:
        """The unfolded field body with RFC 2047 encoded words decoded, for
        an unstructured field (`Subject`, `Comments`); ill-formed UTF-8
        becomes U+FFFD."""
        return decode_header_text(Span(self._value))


struct HeaderBlock(Copyable, Movable):
    """The fields of a header block and where the body after it starts."""

    var fields: List[HeaderField]
    var body_start: Int

    def __init__(out self, var fields: List[HeaderField], body_start: Int):
        self.fields = fields^
        self.body_start = body_start


def _line_end(data: Span[UInt8, _], i: Int, end: Int) -> Int:
    """The index of the LF ending the line at `i`, or `end`."""
    var k = i
    while k < end and data[k] != LF:
        k += 1
    return k


def _content_end(data: Span[UInt8, _], start: Int, lf: Int) -> Int:
    """The end of a line's content: before its CR LF, its LF, or at `lf`."""
    if lf > start and data[lf - 1] == CR:
        return lf - 1
    return lf


def _unfold(data: Span[UInt8, _], start: Int, end: Int) -> List[UInt8]:
    """`data[start:end]` without its line breaks (a fold's CRLF or LF), and
    without white space at either end."""
    var out = List[UInt8](capacity=end - start)
    for k in range(start, end):
        var c = data[k]
        if c == LF:
            continue
        if c == CR and k + 1 < end and data[k + 1] == LF:
            continue
        out.append(c)
    var lo = 0
    var hi = len(out)
    while lo < hi and is_wsp(out[lo]):
        lo += 1
    while hi > lo and is_wsp(out[hi - 1]):
        hi -= 1
    return range_bytes(Span(out), lo, hi)


def split_header_fields_at(
    data: Span[UInt8, _], start: Int, end: Int, function: StaticString
) raises -> HeaderBlock:
    """The header fields of `data[start:end]`; positions in errors and in
    `body_start` are indexes of `data`."""
    var fields = List[HeaderField]()
    var i = start
    while i < end:
        var lf = _line_end(data, i, end)
        var content_end = _content_end(data, i, lf)
        if content_end == i:
            return HeaderBlock(fields^, min(lf + 1, end))
        if is_wsp(data[i]):
            raise message_error(
                SYNTAX, function, "a folded line before the first header field", i
            )
        var colon = i
        while colon < content_end and data[colon] != COLON:
            colon += 1
        if colon == content_end:
            raise message_error(SYNTAX, function, "a header line without ':'", i)
        var name_end = colon
        while name_end > i and is_wsp(data[name_end - 1]):
            name_end -= 1
        if name_end == i:
            raise message_error(SYNTAX, function, "an empty header field name", i)
        for k in range(i, name_end):
            if not is_ftext(data[k]):
                raise message_error(
                    SYNTAX, function, "a byte not allowed in a header field name", k
                )
        # The field runs over every following line that starts with WSP.
        var field_end = content_end
        var next = min(lf + 1, end)
        while next < end and is_wsp(data[next]):
            var lf2 = _line_end(data, next, end)
            field_end = _content_end(data, next, lf2)
            next = min(lf2 + 1, end)
        var name_bytes = range_bytes(data, i, name_end)
        var name = lossy_string(Span(name_bytes))
        fields.append(
            HeaderField(
                name,
                range_bytes(data, i, field_end),
                _unfold(data, colon + 1, field_end),
            )
        )
        i = next
    return HeaderBlock(fields^, end)


def split_header_fields(data: Span[UInt8, _]) raises -> HeaderBlock:
    """The header fields of a message and where its body starts; see the
    module header."""
    return split_header_fields_at(data, 0, len(data), "split_header_fields")
