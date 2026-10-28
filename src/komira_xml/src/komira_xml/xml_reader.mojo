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
# self-closing elements, text, CDATA sections, comments, processing
# instructions and the XML declaration. Namespace PREFIXES are preserved on
# names; resolution is a separate concern (`xml_tree.mojo`), because the
# rest-xml binding keys on local names and would pay for resolution it never
# reads.
#
# WHAT IT REFUSES: anything that is not a well-formed XML 1.0 document, and
# any DTD. The input is a network body, so every refusal is an error raised by
# `next_event`, never a guess:
#   - input that is not UTF-8, or holds a code point outside [2] Char;
#   - a DOCTYPE, which could declare entities, external ones included (XXE)
#     or ones that expand exponentially. Without a DTD the only entities are
#     the five predefined ones, so any other `&name;` is refused too;
#   - an end tag that does not match the open element, a second root, text
#     outside the root, and an element left open at the end of input;
#   - a duplicate attribute, `<` in an attribute value, `]]>` in text, `--`
#     in a comment, a name outside [4] / [4a], a processing instruction with
#     no target, and an XML declaration anywhere but at the start, or one
#     that names a version other than 1.x or an encoding other than UTF-8;
#   - nesting deeper than `XML_MAX_DEPTH`, which bounds every recursive walk
#     over a tree built from the events (and the tree's own destructor).
#
# Text and attribute values are decoded as XML 1.0 specifies: line ends are
# normalised to LF (§2.11), and in an attribute value each literal TAB, CR or
# LF becomes a space (§3.3.3). A character written as a reference is kept.
#
# Encapsulation: no `UnsafePointer` in any signature. The buffer is
# an owned `List[UInt8]`; ranges are plain `Int`s.
# =============================================================================

from .xml_escape import append_unescaped


comptime XML_EOF: Int = 0
comptime XML_START: Int = 1
comptime XML_END: Int = 2
comptime XML_TEXT: Int = 3

# The deepest element nesting the reader accepts; the root is depth 1.
comptime XML_MAX_DEPTH: Int = 512


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


def _is_xml_char(cp: Int) -> Bool:
    """XML 1.0 [2] Char."""
    return (
        cp == 0x09
        or cp == 0x0A
        or cp == 0x0D
        or (cp >= 0x20 and cp <= 0xD7FF)
        or (cp >= 0xE000 and cp <= 0xFFFD)
        or (cp >= 0x10000 and cp <= 0x10FFFF)
    )


def _is_name_start_cp(cp: Int) -> Bool:
    """XML 1.0 [4] NameStartChar."""
    return (
        (cp >= 0x41 and cp <= 0x5A)
        or (cp >= 0x61 and cp <= 0x7A)
        or cp == 0x5F
        or cp == 0x3A
        or (cp >= 0xC0 and cp <= 0xD6)
        or (cp >= 0xD8 and cp <= 0xF6)
        or (cp >= 0xF8 and cp <= 0x2FF)
        or (cp >= 0x370 and cp <= 0x37D)
        or (cp >= 0x37F and cp <= 0x1FFF)
        or (cp >= 0x200C and cp <= 0x200D)
        or (cp >= 0x2070 and cp <= 0x218F)
        or (cp >= 0x2C00 and cp <= 0x2FEF)
        or (cp >= 0x3001 and cp <= 0xD7FF)
        or (cp >= 0xF900 and cp <= 0xFDCF)
        or (cp >= 0xFDF0 and cp <= 0xFFFD)
        or (cp >= 0x10000 and cp <= 0xEFFFF)
    )


def _is_name_char_cp(cp: Int) -> Bool:
    """XML 1.0 [4a] NameChar."""
    return (
        _is_name_start_cp(cp)
        or cp == 0x2D
        or cp == 0x2E
        or (cp >= 0x30 and cp <= 0x39)
        or cp == 0xB7
        or (cp >= 0x300 and cp <= 0x36F)
        or (cp >= 0x203F and cp <= 0x2040)
    )


# The byte-level tests below decide where a name ENDS. A byte >= 0x80 is
# taken as part of the name there; `XmlReader._check_name` then decodes the
# name and holds every code point to [4] / [4a].
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
    # Name ranges of the open elements, innermost last.
    var _open_lo: List[Int]
    var _open_hi: List[Int]
    var _seen_root: Bool
    # Where the document starts: 3 after a UTF-8 byte order mark, else 0.
    var _doc_start: Int
    var _checked: Bool

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
        self._open_lo = List[Int]()
        self._open_hi = List[Int]()
        self._seen_root = False
        self._doc_start = 0
        self._checked = False

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
        """`src[lo:hi]` with XML entity references decoded LENIENTLY, as
        `xml_unescape` does: an unknown `&` passes through and line ends are
        kept as written. A raw helper over any byte range; for an event's
        decoded text use `text_of` / `attr_value`."""
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
        """A TEXT event's content: line ends normalised to LF, and references
        decoded unless it was CDATA."""
        return self._decode(ev.text_lo, ev.text_hi, ev.raw, False)

    def attr_name(self, i: Int) -> String:
        return self.slice_raw(self._an_lo[i], self._an_hi[i])

    def attr_local_name(self, i: Int) -> String:
        var lo = self._an_lo[i]
        for k in range(self._an_lo[i], self._an_hi[i]):
            if self.src[k] == 0x3A:
                lo = k + 1
        return self.slice_raw(lo, self._an_hi[i])

    def attr_value(self, i: Int) -> String:
        """Attribute `i`'s value, normalised as XML 1.0 §3.3.3 says for an
        attribute with no DTD declaration: each literal TAB, CR, LF or CRLF
        becomes one space; references are decoded, and a whitespace character
        written as a reference is kept as that character."""
        return self._decode(self._av_lo[i], self._av_hi[i], False, True)

    def _decode(self, lo: Int, hi: Int, raw: Bool, attr: Bool) -> String:
        # `next_event` has already checked every reference in [lo, hi), so
        # each `&` here starts a well-formed one that ends at the next `;`.
        var out = List[UInt8]()
        var i = lo
        while i < hi:
            var c = self.src[i]
            if c == 0x0D:  # CR, or the CR of CRLF
                out.append(UInt8(0x20) if attr else UInt8(0x0A))
                i += 2 if (i + 1 < hi and self.src[i + 1] == 0x0A) else 1
                continue
            if attr and (c == 0x0A or c == 0x09):
                out.append(0x20)
                i += 1
                continue
            if c == 0x26 and not raw:  # '&'
                var j = i + 1
                while self.src[j] != 0x3B:  # ';'
                    j += 1
                append_unescaped(out, Span(self.src), i, j + 1)
                i = j + 1
                continue
            out.append(c)
            i += 1
        return String(unsafe_from_utf8=Span(out))

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

    def _at(self, pos: Int) -> String:
        return " at byte " + String(pos)

    def _validate(mut self) raises:
        """Refuse input that is not UTF-8 or holds a code point outside
        XML 1.0 [2] Char, and step over a leading byte order mark (§4.3.3).
        One pass, before the first event."""
        var n = len(self.src)
        var i = 0
        if (
            n >= 3
            and self.src[0] == 0xEF
            and self.src[1] == 0xBB
            and self.src[2] == 0xBF
        ):
            i = 3
        self._doc_start = i
        self.pos = i
        while i < n:
            var c = Int(self.src[i])
            var cp = 0
            var w = 0
            if c < 0x80:
                cp = c
                w = 1
            elif c >= 0xC2 and c <= 0xDF:
                cp = c & 0x1F
                w = 2
            elif c >= 0xE0 and c <= 0xEF:
                cp = c & 0x0F
                w = 3
            elif c >= 0xF0 and c <= 0xF4:
                cp = c & 0x07
                w = 4
            else:
                raise Error("xml: invalid UTF-8" + self._at(i))
            if i + w > n:
                raise Error("xml: invalid UTF-8 (truncated)" + self._at(i))
            for k in range(1, w):
                var cc = Int(self.src[i + k])
                if (cc & 0xC0) != 0x80:
                    raise Error("xml: invalid UTF-8" + self._at(i))
                cp = (cp << 6) | (cc & 0x3F)
            # Overlong forms, encoded surrogates and values past U+10FFFF.
            if (
                (w == 3 and cp < 0x800)
                or (w == 4 and (cp < 0x10000 or cp > 0x10FFFF))
                or (cp >= 0xD800 and cp <= 0xDFFF)
            ):
                raise Error("xml: invalid UTF-8" + self._at(i))
            if not _is_xml_char(cp):
                raise Error(
                    "xml: illegal character (code point " + String(cp) + ")"
                    + self._at(i)
                )
            i += w

    def _check_reference(self, amp: Int, hi: Int) raises -> Int:
        """Check the reference starting at `src[amp] == '&'` and ending
        before `hi`; return the offset just past its `;`.

        With no DTD the only entities are the five predefined ones
        ([WFC: Entity Declared]), and a character reference must name a
        [2] Char ([WFC: Legal Character])."""
        if self._starts_with(amp, "&amp;"):
            return amp + 5
        if self._starts_with(amp, "&lt;") or self._starts_with(amp, "&gt;"):
            return amp + 4
        if self._starts_with(amp, "&quot;") or self._starts_with(amp, "&apos;"):
            return amp + 6
        if amp + 1 < hi and self.src[amp + 1] == 0x23:  # '#'
            var j = amp + 2
            var hexmode = False
            if j < hi and self.src[j] == 0x78:  # 'x'
                hexmode = True
                j += 1
            var cp = 0
            var digits = 0
            while j < hi:
                var d = self.src[j]
                var v = -1
                if d >= 0x30 and d <= 0x39:
                    v = Int(d) - 0x30
                elif hexmode and d >= 0x61 and d <= 0x66:
                    v = Int(d) - 0x61 + 10
                elif hexmode and d >= 0x41 and d <= 0x46:
                    v = Int(d) - 0x41 + 10
                if v < 0:
                    break
                if cp <= 0x10FFFF:
                    cp = cp * (16 if hexmode else 10) + v
                digits += 1
                j += 1
            if digits == 0 or j >= hi or self.src[j] != 0x3B:
                raise Error("xml: malformed character reference" + self._at(amp))
            if not _is_xml_char(cp):
                raise Error(
                    "xml: character reference to an illegal character"
                    + self._at(amp)
                )
            return j + 1
        raise Error(
            "xml: undeclared entity or malformed reference (only &amp; &lt; "
            + "&gt; &quot; &apos; and character references exist without a "
            + "DTD)" + self._at(amp)
        )

    def _check_text(self, lo: Int, hi: Int) raises:
        """[14] CharData: no `]]>`, and every `&` begins a reference."""
        var i = lo
        while i < hi:
            var c = self.src[i]
            if c == 0x26:
                i = self._check_reference(i, hi)
                continue
            if c == 0x5D and self._starts_with(i, "]]>"):
                raise Error("xml: ']]>' in character data" + self._at(i))
            i += 1

    def _check_name(self, lo: Int, hi: Int) raises:
        """[5] Name over `src[lo:hi]`: the first code point a NameStartChar,
        the rest NameChars. `_validate` has already proved the bytes UTF-8."""
        var i = lo
        var first = True
        while i < hi:
            var c = Int(self.src[i])
            var cp = c
            var w = 1
            if c >= 0xF0:
                cp = c & 0x07
                w = 4
            elif c >= 0xE0:
                cp = c & 0x0F
                w = 3
            elif c >= 0xC0:
                cp = c & 0x1F
                w = 2
            if i + w > hi:
                raise Error("xml: invalid character in a name" + self._at(i))  # cov: unreachable names end at ASCII; UTF-8 checked
            for k in range(1, w):
                cp = (cp << 6) | (Int(self.src[i + k]) & 0x3F)
            var ok = _is_name_start_cp(cp) if first else _is_name_char_cp(cp)
            if not ok:
                raise Error(
                    "xml: invalid character in a name (code point "
                    + String(cp) + ")" + self._at(i)
                )
            first = False
            i += w

    def _lit_at(self, lo: Int, hi: Int, lit: StringSlice, fold: Bool) -> Bool:
        """`src[lo:hi]` equals `lit`; with `fold`, ASCII letters in any case."""
        var l = lit.as_bytes()
        if hi - lo != len(l):
            return False
        for k in range(len(l)):
            var a = self.src[lo + k]
            var b = l[k]
            if fold and a >= 0x41 and a <= 0x5A:
                a |= 0x20
            if fold and b >= 0x41 and b <= 0x5A:
                b |= 0x20
            if a != b:
                return False
        return True

    def _check_xml_decl(self, lo: Int, hi: Int) raises:
        """[23] XMLDecl between `<?xml` (ending at `lo`) and `?>` (at `hi`):
        S VersionInfo, then optionally S EncodingDecl, then optionally S
        SDDecl, then S?. The version must be 1.x, and a declared encoding
        must be UTF-8, the only one this parser reads (§4.3.3)."""
        var i = lo
        var stage = 0  # 0: version next; 1: encoding or standalone; 2: standalone; 3: done
        while True:
            var s0 = i
            while i < hi and _is_space(self.src[i]):
                i += 1
            if i >= hi:
                break
            if i == s0 or stage == 3:
                raise Error("xml: malformed XML declaration" + self._at(i))
            var nl = i
            while i < hi and _is_name_char(self.src[i]):
                i += 1
            var nh = i
            while i < hi and _is_space(self.src[i]):
                i += 1
            if i >= hi or self.src[i] != 0x3D:  # '='
                raise Error("xml: malformed XML declaration" + self._at(i))
            i += 1
            while i < hi and _is_space(self.src[i]):
                i += 1
            if i >= hi or (self.src[i] != 0x22 and self.src[i] != 0x27):
                raise Error("xml: malformed XML declaration" + self._at(i))
            var q = self.src[i]
            i += 1
            var vl = i
            while i < hi and self.src[i] != q:
                i += 1
            if i >= hi:
                raise Error("xml: malformed XML declaration" + self._at(vl))
            var vh = i
            i += 1
            if stage == 0:
                if not self._lit_at(nl, nh, "version", False):
                    raise Error(
                        "xml: malformed XML declaration: it must start with"
                        + " the version" + self._at(nl)
                    )
                # [26] VersionNum ::= '1.' [0-9]+
                var ok = (
                    vh - vl >= 3
                    and self.src[vl] == 0x31
                    and self.src[vl + 1] == 0x2E
                )
                for k in range(vl + 2, vh):
                    if self.src[k] < 0x30 or self.src[k] > 0x39:
                        ok = False
                if not ok:
                    raise Error(
                        "xml: unsupported XML version '"
                        + self.slice_raw(vl, vh) + "'"
                    )
                stage = 1
            elif stage == 1 and self._lit_at(nl, nh, "encoding", False):
                if not self._lit_at(vl, vh, "utf-8", True):
                    raise Error(
                        "xml: declared encoding '" + self.slice_raw(vl, vh)
                        + "' is not UTF-8, the only encoding this parser reads"
                    )
                stage = 2
            elif stage <= 2 and self._lit_at(nl, nh, "standalone", False):
                if not (
                    self._lit_at(vl, vh, "yes", False)
                    or self._lit_at(vl, vh, "no", False)
                ):
                    raise Error(
                        "xml: malformed XML declaration: standalone must be"
                        + " 'yes' or 'no'" + self._at(vl)
                    )
                stage = 3
            else:
                raise Error("xml: malformed XML declaration" + self._at(nl))
        if stage == 0:
            raise Error(
                "xml: malformed XML declaration: it must start with the version"
                + self._at(lo)
            )

    def _is_space_run(self, lo: Int, hi: Int) -> Bool:
        for i in range(lo, hi):
            if not _is_space(self.src[i]):
                return False
        return True

    def _same_name(self, alo: Int, ahi: Int, blo: Int, bhi: Int) -> Bool:
        if ahi - alo != bhi - blo:
            return False
        for k in range(ahi - alo):
            if self.src[alo + k] != self.src[blo + k]:
                return False
        return True

    def next_event(mut self) raises -> XmlEvent:
        """Advance and return the next event, or `XmlEvent.eof()`. Raises on
        the first well-formedness violation; see the module header."""
        if not self._checked:
            self._validate()
            self._checked = True
        if self._owe_end:
            self._owe_end = False
            if len(self._open_lo) == 0:
                self._seen_root = True
            return XmlEvent(
                XML_END, self._owed_end_lo, self._owed_end_hi, 0, 0, 0,
                False, True,
            )
        var n = len(self.src)
        while True:
            if self.pos >= n:
                if len(self._open_lo) > 0:
                    var top = len(self._open_lo) - 1
                    raise Error(
                        "xml: unterminated element <"
                        + self.slice_raw(self._open_lo[top], self._open_hi[top])
                        + ">"
                    )
                if not self._seen_root:
                    raise Error("xml: no root element")
                return XmlEvent.eof()
            if self.src[self.pos] != 0x3C:  # not '<'  -> text run
                var lo = self.pos
                while self.pos < n and self.src[self.pos] != 0x3C:
                    self.pos += 1
                if len(self._open_lo) == 0 and not self._is_space_run(
                    lo, self.pos
                ):
                    raise Error("xml: text outside the root element" + self._at(lo))
                self._check_text(lo, self.pos)
                return XmlEvent(XML_TEXT, 0, 0, lo, self.pos, 0, False, False)

            # '<' — decide which construct.
            if self._starts_with(self.pos, "<!--"):
                # [15] Comment: '--' only as part of the closing '-->'.
                var e = self._find("--", self.pos + 4)
                if e < 0:
                    raise Error("xml: unterminated comment")
                if e + 2 >= n or self.src[e + 2] != 0x3E:
                    raise Error("xml: '--' inside a comment" + self._at(e))
                self.pos = e + 3
                continue
            if self._starts_with(self.pos, "<![CDATA["):
                if len(self._open_lo) == 0:
                    raise Error(
                        "xml: CDATA section outside the root element"
                        + self._at(self.pos)
                    )
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
                # [16] PI ::= '<?' PITarget (S ...)? '?>'. [17] PITarget:
                # any case variant of 'xml' is reserved for the XML
                # declaration, which [22] allows only first, spelled 'xml'.
                var tl = self.pos + 2
                var t = tl
                while t < e3 and _is_name_char(self.src[t]):
                    t += 1
                if t == tl or not _is_name_start(self.src[tl]):
                    raise Error(
                        "xml: processing instruction without a target"
                        + self._at(self.pos)
                    )
                if t < e3 and not _is_space(self.src[t]):
                    raise Error(
                        "xml: malformed processing instruction target"
                        + self._at(t)
                    )
                self._check_name(tl, t)
                if self._lit_at(tl, t, "xml", True):
                    if self.pos != self._doc_start:
                        raise Error(
                            "xml: an XML declaration is only allowed at the "
                            + "start of the document" + self._at(self.pos)
                        )
                    if not self._lit_at(tl, t, "xml", False):
                        raise Error(
                            "xml: processing instruction target '"
                            + self.slice_raw(tl, t)
                            + "' is reserved; the XML declaration is spelled"
                            + " 'xml'" + self._at(self.pos)
                        )
                    self._check_xml_decl(t, e3)
                self.pos = e3 + 2
                continue
            if self._starts_with(self.pos, "<!DOCTYPE"):
                raise Error(
                    "xml: DTD refused: a document type declaration can declare"
                    + " entities, external ones included, and this parser does"
                    + " not process DTDs" + self._at(self.pos)
                )
            if self._starts_with(self.pos, "<!"):
                raise Error(
                    "xml: markup declaration outside a DTD" + self._at(self.pos)
                )
            if self._starts_with(self.pos, "</"):
                var i2 = self.pos + 2
                var nl = i2
                while i2 < n and _is_name_char(self.src[i2]):
                    i2 += 1
                var nh = i2
                while i2 < n and _is_space(self.src[i2]):
                    i2 += 1
                if i2 >= n:
                    raise Error("xml: unterminated end tag")
                if self.src[i2] != 0x3E or nh == nl:
                    raise Error("xml: malformed end tag" + self._at(self.pos))
                self._check_name(nl, nh)
                if len(self._open_lo) == 0:
                    raise Error(
                        "xml: end tag </" + self.slice_raw(nl, nh)
                        + "> with no open element"
                    )
                var top2 = len(self._open_lo) - 1
                if not self._same_name(
                    self._open_lo[top2], self._open_hi[top2], nl, nh
                ):
                    raise Error(
                        "xml: end tag </" + self.slice_raw(nl, nh)
                        + "> does not match start tag <"
                        + self.slice_raw(self._open_lo[top2], self._open_hi[top2])
                        + ">"
                    )
                _ = self._open_lo.pop()
                _ = self._open_hi.pop()
                if len(self._open_lo) == 0:
                    self._seen_root = True
                self.pos = i2 + 1
                return XmlEvent(XML_END, nl, nh, 0, 0, 0, False, False)

            # A start tag.
            if self._seen_root:
                raise Error("xml: more than one root element" + self._at(self.pos))
            if len(self._open_lo) >= XML_MAX_DEPTH:
                raise Error(
                    "xml: element nesting deeper than "
                    + String(XML_MAX_DEPTH)
                )
            var i3 = self.pos + 1
            if i3 >= n or not _is_name_start(self.src[i3]):
                raise Error("xml: malformed start tag" + self._at(self.pos))
            var snl = i3
            while i3 < n and _is_name_char(self.src[i3]):
                i3 += 1
            var snh = i3
            self._check_name(snl, snh)
            self._an_lo.clear()
            self._an_hi.clear()
            self._av_lo.clear()
            self._av_hi.clear()
            # attributes
            while True:
                var spaced = False
                while i3 < n and _is_space(self.src[i3]):
                    i3 += 1
                    spaced = True
                if i3 >= n:
                    raise Error("xml: unterminated start tag")
                var c2 = self.src[i3]
                if c2 == 0x3E:  # '>'
                    self.pos = i3 + 1
                    self._open_lo.append(snl)
                    self._open_hi.append(snh)
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
                    raise Error("xml: malformed attribute name" + self._at(i3))
                if not spaced:
                    # [40] STag: S before every attribute.
                    raise Error(
                        "xml: missing whitespace before an attribute"
                        + self._at(i3)
                    )
                var al = i3
                while i3 < n and _is_name_char(self.src[i3]):
                    i3 += 1
                var ah = i3
                self._check_name(al, ah)
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
                    if self.src[i3] == 0x3C:
                        raise Error("xml: '<' in an attribute value" + self._at(i3))
                    if self.src[i3] == 0x26:
                        i3 = self._check_reference(i3, n)
                        continue
                    i3 += 1
                if i3 >= n:
                    raise Error("xml: unterminated attribute value")
                var vh = i3
                i3 += 1
                # [WFC: Unique Att Spec]
                for k in range(len(self._an_lo)):
                    if self._same_name(self._an_lo[k], self._an_hi[k], al, ah):
                        raise Error(
                            "xml: duplicate attribute " + self.slice_raw(al, ah)
                        )
                self._an_lo.append(al)
                self._an_hi.append(ah)
                self._av_lo.append(vl)
                self._av_hi.append(vh)
