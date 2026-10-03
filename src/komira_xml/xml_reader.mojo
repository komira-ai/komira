# =============================================================================
# xml_reader.mojo — a zero-allocation-per-event XML pull parser.
# =============================================================================
#
# THE SHAPE: `XmlReader` owns the input bytes once and yields `XmlEvent`s that
# carry BYTE RANGES into that buffer, never copies. Attribute storage lives on
# the READER and is reused across events, so a document of N elements with no
# attributes performs N range computations and ZERO heap allocations in the
# parser. A caller that needs an owned `String` asks for one explicitly
# (`text_of` / `name_of` / `attr_value`), which is the only point a copy or an
# entity-decode happens.
#
# This is the property a hand-written scanner does not have. One that finds
# each field with a fresh search for `"<Tag>"` — a full O(n) scan from the
# START of the document per field — costs O(K*F*n) byte comparisons on a
# ListObjectsV2 response with K objects x F fields, and allocates a `String`
# for every tag literal it searches for. A single forward pass is O(n).
#
# WHAT IT ACCEPTS: elements, attributes (single- or double-quoted),
# self-closing elements, text, CDATA sections, comments, the XML declaration,
# and DOCTYPE (skipped). Namespace PREFIXES are preserved on names; resolution
# is a separate concern (`xml_tree.mojo`), because the rest-xml binding keys
# on local names and would pay for resolution it never reads.
#
# Encapsulation: no `UnsafePointer` in any signature. The buffer is
# an owned `List[UInt8]`; ranges are plain `Int`s.
# =============================================================================

from .xml_escape import append_unescaped


comptime XML_EOF: Int = 0
comptime XML_START: Int = 1
comptime XML_END: Int = 2
comptime XML_TEXT: Int = 3


@fieldwise_init
struct XmlEvent(Copyable, Movable, ImplicitlyCopyable):
    """One pull-parser event — byte ranges into the reader's buffer.

    `kind` is one of `XML_EOF` / `XML_START` / `XML_END` / `XML_TEXT`.
    For START/END, `[name_lo, name_hi)` is the qualified element name.
    For TEXT, `[text_lo, text_hi)` is the raw (still-escaped) content and
    `raw` is True when it came from a CDATA section (no entity decoding).
    For START, `attr_count` attributes are readable off the reader.
    """

    var kind: Int
    var name_lo: Int
    var name_hi: Int
    var text_lo: Int
    var text_hi: Int
    var attr_count: Int
    var raw: Bool
    var self_closing: Bool

    @staticmethod
    def eof() -> XmlEvent:
        return XmlEvent(XML_EOF, 0, 0, 0, 0, 0, False, False)


def _is_space(c: UInt8) -> Bool:
    return c == 0x20 or c == 0x09 or c == 0x0A or c == 0x0D


def _is_name_start(c: UInt8) -> Bool:
    return (
        (c >= 0x41 and c <= 0x5A)
        or (c >= 0x61 and c <= 0x7A)
        or c == 0x5F  # _
        or c == 0x3A  # :
        or c >= 0x80  # any UTF-8 lead/continuation byte
    )


def _is_name_char(c: UInt8) -> Bool:
    return (
        _is_name_start(c)
        or (c >= 0x30 and c <= 0x39)
        or c == 0x2D  # -
        or c == 0x2E  # .
    )


struct XmlReader(Movable):
    """A forward-only XML pull parser over an owned byte buffer."""

    var src: List[UInt8]
    var pos: Int
    # Attribute storage, REUSED across events (cleared at each start tag).
    var _an_lo: List[Int]
    var _an_hi: List[Int]
    var _av_lo: List[Int]
    var _av_hi: List[Int]
    # A self-closing `<x/>` yields START then a synthetic END; this holds the
    # name range of the END that is owed.
    var _owed_end_lo: Int
    var _owed_end_hi: Int
    var _owe_end: Bool

    def __init__(out self, var src: List[UInt8]):
        self.src = src^
        self.pos = 0
        self._an_lo = List[Int]()
        self._an_hi = List[Int]()
        self._av_lo = List[Int]()
        self._av_hi = List[Int]()
        self._owed_end_lo = 0
        self._owed_end_hi = 0
        self._owe_end = False

    @staticmethod
    def from_string(s: StringSlice) -> XmlReader:
        """Build a reader over a copy of `s`'s bytes."""
        var b = s.as_bytes()
        var buf = List[UInt8]()
        for i in range(len(b)):
            buf.append(b[i])
        return XmlReader(buf^)

    # -- slice accessors ---------------------------------------------------

    def slice_raw(self, lo: Int, hi: Int) -> String:
        """`src[lo:hi]` as an owned String, no entity decoding."""
        var a = lo if lo >= 0 else 0
        var b = hi if hi <= len(self.src) else len(self.src)
        if b < a:
            b = a
        return String(unsafe_from_utf8=Span(self.src)[a:b])

    def slice_text(self, lo: Int, hi: Int) -> String:
        """`src[lo:hi]` with XML entity references decoded."""
        var out = List[UInt8]()
        append_unescaped(out, Span(self.src), lo, hi)
        return String(unsafe_from_utf8=Span(out))

    def name_of(self, ev: XmlEvent) -> String:
        """The element's QUALIFIED name (prefix included)."""
        return self.slice_raw(ev.name_lo, ev.name_hi)

    def local_name_of(self, ev: XmlEvent) -> String:
        """The element's LOCAL name — everything after the last `:`."""
        var lo = ev.name_lo
        for i in range(ev.name_lo, ev.name_hi):
            if self.src[i] == 0x3A:
                lo = i + 1
        return self.slice_raw(lo, ev.name_hi)

    def text_of(self, ev: XmlEvent) -> String:
        """A TEXT event's content, entity-decoded unless it was CDATA."""
        if ev.raw:
            return self.slice_raw(ev.text_lo, ev.text_hi)
        return self.slice_text(ev.text_lo, ev.text_hi)

    def attr_name(self, i: Int) -> String:
        return self.slice_raw(self._an_lo[i], self._an_hi[i])

    def attr_local_name(self, i: Int) -> String:
        var lo = self._an_lo[i]
        for k in range(self._an_lo[i], self._an_hi[i]):
            if self.src[k] == 0x3A:
                lo = k + 1
        return self.slice_raw(lo, self._an_hi[i])

    def attr_value(self, i: Int) -> String:
        return self.slice_text(self._av_lo[i], self._av_hi[i])

    # -- the scanner -------------------------------------------------------

    def _skip_space(mut self):
        while self.pos < len(self.src) and _is_space(self.src[self.pos]):
            self.pos += 1

    def _starts_with(self, pos: Int, lit: StringSlice) -> Bool:
        var l = lit.as_bytes()
        if pos + len(l) > len(self.src):
            return False
        for i in range(len(l)):
            if self.src[pos + i] != l[i]:
                return False
        return True

    def _find(self, needle: StringSlice, start: Int) -> Int:
        """Byte offset of `needle` at-or-after `start`, else -1."""
        var l = needle.as_bytes()
        var n = len(l)
        var end = len(self.src) - n
        var i = start
        while i <= end:
            if self.src[i] == l[0]:
                var ok = True
                for j in range(1, n):
                    if self.src[i + j] != l[j]:
                        ok = False
                        break
                if ok:
                    return i
            i += 1
        return -1

    def next_event(mut self) raises -> XmlEvent:
        """Advance and return the next event, or `XmlEvent.eof()`."""
        if self._owe_end:
            self._owe_end = False
            return XmlEvent(
                XML_END, self._owed_end_lo, self._owed_end_hi, 0, 0, 0,
                False, True,
            )
        var n = len(self.src)
        while True:
            if self.pos >= n:
                return XmlEvent.eof()
            if self.src[self.pos] != 0x3C:  # not '<'  -> text run
                var lo = self.pos
                while self.pos < n and self.src[self.pos] != 0x3C:
                    self.pos += 1
                return XmlEvent(XML_TEXT, 0, 0, lo, self.pos, 0, False, False)

            # '<' — decide which construct.
            if self._starts_with(self.pos, "<!--"):
                var e = self._find("-->", self.pos + 4)
                if e < 0:
                    raise Error("xml: unterminated comment")
                self.pos = e + 3
                continue
            if self._starts_with(self.pos, "<![CDATA["):
                var lo2 = self.pos + 9
                var e2 = self._find("]]>", lo2)
                if e2 < 0:
                    raise Error("xml: unterminated CDATA")
                self.pos = e2 + 3
                return XmlEvent(XML_TEXT, 0, 0, lo2, e2, 0, True, False)
            if self._starts_with(self.pos, "<?"):
                var e3 = self._find("?>", self.pos + 2)
                if e3 < 0:
                    raise Error("xml: unterminated processing instruction")
                self.pos = e3 + 2
                continue
            if self._starts_with(self.pos, "<!"):
                # DOCTYPE or other declaration — skip to the matching '>',
                # tracking one level of internal subset brackets.
                var i = self.pos + 2
                var depth = 0
                while i < n:
                    var c = self.src[i]
                    if c == 0x5B:  # [
                        depth += 1
                    elif c == 0x5D:  # ]
                        depth -= 1
                    elif c == 0x3E and depth <= 0:  # >
                        break
                    i += 1
                if i >= n:
                    raise Error("xml: unterminated declaration")
                self.pos = i + 1
                continue
            if self._starts_with(self.pos, "</"):
                var i2 = self.pos + 2
                var nl = i2
                while i2 < n and _is_name_char(self.src[i2]):
                    i2 += 1
                var nh = i2
                while i2 < n and self.src[i2] != 0x3E:
                    i2 += 1
                if i2 >= n:
                    raise Error("xml: unterminated end tag")
                self.pos = i2 + 1
                return XmlEvent(XML_END, nl, nh, 0, 0, 0, False, False)

            # A start tag.
            var i3 = self.pos + 1
            if i3 >= n or not _is_name_start(self.src[i3]):
                raise Error("xml: malformed start tag")
            var snl = i3
            while i3 < n and _is_name_char(self.src[i3]):
                i3 += 1
            var snh = i3
            self._an_lo.clear()
            self._an_hi.clear()
            self._av_lo.clear()
            self._av_hi.clear()
            # attributes
            while True:
                while i3 < n and _is_space(self.src[i3]):
                    i3 += 1
                if i3 >= n:
                    raise Error("xml: unterminated start tag")
                var c2 = self.src[i3]
                if c2 == 0x3E:  # '>'
                    self.pos = i3 + 1
                    return XmlEvent(
                        XML_START, snl, snh, 0, 0, len(self._an_lo), False,
                        False,
                    )
                if c2 == 0x2F:  # '/'
                    if i3 + 1 >= n or self.src[i3 + 1] != 0x3E:
                        raise Error("xml: malformed self-closing tag")
                    self.pos = i3 + 2
                    self._owed_end_lo = snl
                    self._owed_end_hi = snh
                    self._owe_end = True
                    return XmlEvent(
                        XML_START, snl, snh, 0, 0, len(self._an_lo), False,
                        True,
                    )
                if not _is_name_start(c2):
                    raise Error("xml: malformed attribute name")
                var al = i3
                while i3 < n and _is_name_char(self.src[i3]):
                    i3 += 1
                var ah = i3
                while i3 < n and _is_space(self.src[i3]):
                    i3 += 1
                if i3 >= n or self.src[i3] != 0x3D:  # '='
                    raise Error("xml: attribute without a value")
                i3 += 1
                while i3 < n and _is_space(self.src[i3]):
                    i3 += 1
                if i3 >= n:
                    raise Error("xml: unterminated attribute value")
                var q = self.src[i3]
                if q != 0x22 and q != 0x27:
                    raise Error("xml: unquoted attribute value")
                i3 += 1
                var vl = i3
                while i3 < n and self.src[i3] != q:
                    i3 += 1
                if i3 >= n:
                    raise Error("xml: unterminated attribute value")
                var vh = i3
                i3 += 1
                self._an_lo.append(al)
                self._an_hi.append(ah)
                self._av_lo.append(vl)
                self._av_hi.append(vh)
