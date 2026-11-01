# =============================================================================
# xml_writer.mojo — a streaming XML writer over one `List[UInt8]`.
# =============================================================================
#
# One output buffer, appended to; no intermediate `String` per element and no
# string concatenation in the element loop. `start_element` leaves the tag
# OPEN so attributes can be written after it; the tag is closed lazily by the
# first `text` / nested `start_element` / `end_element`. An element that is
# closed while still open and childless is emitted `<x/>`, which is what the
# rest-xml conformance corpus expects for an empty structure.
#
# ATTRIBUTES ARE FIRST-CLASS HERE and that is deliberate: they are the one
# thing the JSON codec has no analogue for, and rest-xml uses them
# (`xmlAttribute`, `xmlNamespace` -> `xmlns`).
#
# `text` and `attr` refuse a VALUE holding a character outside XML 1.0 [2]
# Char that a `String` can carry: a C0 control other than TAB, LF and CR, or
# U+FFFE / U+FFFF. XML has no way to write one, not even as a reference, so a
# document carrying one could not be read back. Element and attribute NAMES
# are written as given and are not checked; the caller owns them.
#
# Encapsulation: no `UnsafePointer` in any signature.
# =============================================================================

from .xml_escape import append_escaped_attr, append_escaped_text


def _refuse_non_xml_chars(s: StringSlice, what: StringSlice) raises:
    """Raise if `s` holds a character outside [2] Char. A valid UTF-8 string
    cannot hold a surrogate, so the cases are a byte below 0x20 other than
    TAB, LF or CR (always a whole character), and U+FFFE / U+FFFF
    (EF BF BE / EF BF BF)."""
    var b = s.as_bytes()
    var n = len(b)
    for i in range(n):
        var c = b[i]
        var cp = -1
        if c < 0x20 and c != 0x09 and c != 0x0A and c != 0x0D:
            cp = Int(c)
        elif (
            c == 0xEF
            and i + 2 < n
            and b[i + 1] == 0xBF
            and (b[i + 2] == 0xBE or b[i + 2] == 0xBF)
        ):
            cp = 0xFFFE if b[i + 2] == 0xBE else 0xFFFF
        if cp >= 0:
            raise Error(
                "xml writer: " + String(what) + " holds character (code point "
                + String(cp) + "), which XML cannot represent"
            )


struct XmlWriter(Movable):
    """A streaming XML writer accumulating into an owned byte buffer."""

    var buf: List[UInt8]
    var _stack: List[String]
    # True while the innermost start tag is written but not yet terminated,
    # i.e. `<name` has been emitted and neither `>` nor `/>` has.
    var _open: Bool

    def __init__(out self):
        self.buf = List[UInt8]()
        self._stack = List[String]()
        self._open = False

    def _raw(mut self, lit: StringSlice):
        var b = lit.as_bytes()
        for i in range(len(b)):
            self.buf.append(b[i])

    def _close_open_tag(mut self):
        if self._open:
            self.buf.append(0x3E)  # '>'
            self._open = False

    def start_element(mut self, name: StringSlice):
        """Open `<name`; the tag stays open for attributes."""
        self._close_open_tag()
        self.buf.append(0x3C)  # '<'
        self._raw(name)
        self._stack.append(String(name))
        self._open = True

    def attr(mut self, name: StringSlice, value: StringSlice) raises:
        """Write ` name="value"` on the currently-open start tag."""
        if not self._open:
            raise Error("xml writer: attribute after the start tag was closed")
        _refuse_non_xml_chars(value, "an attribute value")
        self.buf.append(0x20)  # ' '
        self._raw(name)
        self.buf.append(0x3D)  # '='
        self.buf.append(0x22)  # '"'
        append_escaped_attr(self.buf, value)
        self.buf.append(0x22)

    def text(mut self, s: StringSlice) raises:
        """Write escaped element text content."""
        _refuse_non_xml_chars(s, "element text")
        self._close_open_tag()
        append_escaped_text(self.buf, s)

    def raw_text(mut self, s: StringSlice):
        """Write content VERBATIM — no escaping. For a payload member whose
        shape is a blob or a pre-serialised document."""
        self._close_open_tag()
        self._raw(s)

    def end_element(mut self) raises:
        """Close the innermost element; `<x/>` if it is still childless."""
        if len(self._stack) == 0:
            raise Error("xml writer: end_element with no open element")
        var name = self._stack.pop()
        if self._open:
            self._raw("/>")
            self._open = False
        else:
            self._raw("</")
            self._raw(name)
            self.buf.append(0x3E)

    def depth(self) -> Int:
        return len(self._stack)

    def finish(mut self) raises -> String:
        """The accumulated document. Raises if an element is still open."""
        if len(self._stack) != 0:
            raise Error("xml writer: " + String(len(self._stack)) + " element(s) left open")
        return String(unsafe_from_utf8=Span(self.buf))

    def is_empty(self) -> Bool:
        return len(self.buf) == 0
