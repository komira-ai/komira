# =============================================================================
# test_xml_edges.mojo — the edges the other tests leave unexercised.
# =============================================================================
#
# Each row names the rule or the code path it holds. Refusal rows name the
# text (and, where two refusals share a message, the byte offset) the error
# must carry, so a refusal for another reason does not pass:
#   - `xml_unescape`: lower-case hex digits, two-byte UTF-8 output, a value
#     past U+10FFFF with enough digits to overflow a 64-bit accumulator, a
#     surrogate (U+D800..U+DFFF, which has no UTF-8 form) and the scalar
#     values either side of it, and a reference with no digits, each passed
#     through or decoded exactly;
#   - the reader: lower-case hex in a checked reference, a lone `-` in a
#     comment, a document cut inside a UTF-8 sequence, a four-byte name
#     character, every malformed shape of the XML declaration, an unterminated
#     or malformed processing instruction, and start tags or attribute values
#     cut off at the end of input;
#   - the tree: the xml and xmlns namespace names refused as the default or a
#     prefix binding, `canonical_node`, and the accessors' absent cases;
#   - the writer: `end_element` with nothing open, `raw_text`, `depth`,
#     `is_empty`; the reader's `local_name_of`, `attr_local_name` and
#     `slice_text`.
# =============================================================================

from komira_xml import (
    XML_EOF,
    XML_START,
    XmlReader,
    XmlWriter,
    canonical_node,
    parse_xml,
    xml_unescape,
)


comptime _XML_NS = "http://www.w3.org/XML/1998/namespace"
comptime _XMLNS_NS = "http://www.w3.org/2000/xmlns/"


def _eq(got: String, want: String, what: String) -> Int:
    if got != want:
        print("FAIL " + what + "\n  got : " + got + "\n  want: " + want)
        return 1
    return 0


def _true(cond: Bool, what: String) -> Int:
    if not cond:
        print("FAIL " + what)
        return 1
    return 0


def _refused(doc: String, needle: String, what: String) -> Int:
    """`parse_xml(doc)` raises, and the error mentions `needle`."""
    try:
        _ = parse_xml(doc)
    except e:
        var msg = String(e)
        if msg.find(needle) < 0:
            print("FAIL " + what + ": raised for another reason: " + msg)
            return 1
        return 0
    print("FAIL " + what + ": accepted " + doc)
    return 1


def _accepted(doc: String, what: String) -> Int:
    try:
        _ = parse_xml(doc)
    except e:
        print("FAIL " + what + ": refused: " + String(e))
        return 1
    return 0


# -- xml_unescape --------------------------------------------------------------


def test_unescape_edges() raises -> Int:
    var f = 0
    # Lower-case hex digits, and a code point that takes two UTF-8 bytes.
    f += _eq(xml_unescape("&#xe9;"), String("é"), "lower-case hex, 2-byte UTF-8")
    f += _eq(xml_unescape("&#xfc;&#xFC;"), String("üü"), "lower and upper hex agree")
    f += _eq(xml_unescape("&#x7ff;"), chr(0x7FF), "largest 2-byte code point")
    f += _eq(xml_unescape("&#x80;"), chr(0x80), "smallest 2-byte code point")
    # Past U+10FFFF: passed through. Seventeen hex digits would wrap a 64-bit
    # accumulator to 0x41 ('A') if the scan did not stop at the bound.
    f += _eq(
        xml_unescape("&#x10000000000000041;"),
        String("&#x10000000000000041;"),
        "hex reference that would wrap 64 bits",
    )
    f += _eq(xml_unescape("&#x110000;"), String("&#x110000;"), "U+110000 passed through")
    # U+D800..U+DFFF are not Unicode scalar values and have no UTF-8 form:
    # a reference to one is passed through like one past U+10FFFF, so the
    # returned String stays UTF-8. The scalar values either side decode.
    f += _eq(xml_unescape("&#xD800;"), String("&#xD800;"), "U+D800 passed through")
    f += _eq(xml_unescape("&#57343;"), String("&#57343;"), "U+DFFF passed through")
    f += _eq(xml_unescape("&#xdc00;x"), String("&#xdc00;x"), "low surrogate passed through")
    f += _eq(xml_unescape("&#xD7FF;"), chr(0xD7FF), "U+D7FF decodes")
    f += _eq(xml_unescape("&#xE000;"), chr(0xE000), "U+E000 decodes")
    # No digits, or no ';': the '&' is passed through verbatim.
    f += _eq(xml_unescape("&#x;"), String("&#x;"), "hex reference with no digits")
    f += _eq(xml_unescape("&#;x"), String("&#;x"), "decimal reference with no digits")
    f += _eq(xml_unescape("&#65"), String("&#65"), "reference with no ';'")
    return f


# -- the reader ------------------------------------------------------------------


def test_reader_references_and_comments() raises -> Int:
    var f = 0
    # XML 1.0 [66]: '&#x' [0-9a-fA-F]+ ';' — lower-case digits are legal.
    f += _eq(parse_xml("<a>&#xe9;</a>").text, String("é"), "lower-case hex reference")
    f += _eq(parse_xml("<a>&#xfffd;</a>").text, chr(0xFFFD), "&#xfffd; is a Char")
    f += _refused("<a>&#xfffe;</a>", "illegal character", "&#xfffe; is not a Char")
    f += _eq(parse_xml('<a k="&#xe9;"/>').attr("k"), String("é"), "lower-case hex in a value")
    # [15]: a single '-' inside a comment is allowed.
    f += _eq(parse_xml("<a>x<!-- a-b -c- -->y</a>").text, String("xy"), "lone '-' in a comment")
    return f


def test_reader_utf8_and_names() raises -> Int:
    var f = 0
    # A document cut inside a multi-byte sequence.
    var cut = List[UInt8]()
    var head = String("<a/>").as_bytes()
    for i in range(len(head)):
        cut.append(head[i])
    cut.append(0xC3)
    var rd = XmlReader(cut^)
    try:
        while rd.next_event().kind != XML_EOF:
            pass
        f += _true(False, "UTF-8 cut at the end: accepted")
    except e:
        f += _true(String(e).find("truncated") >= 0, "UTF-8 cut at the end: " + String(e))
    # [4] NameStartChar includes [#x10000-#xEFFFF] (four UTF-8 bytes).
    var name4 = chr(0x10000) + "b" + chr(0xEFFFF)
    var root = parse_xml("<" + name4 + ' k="v"/>')
    f += _eq(root.local, name4, "four-byte name characters")
    f += _eq(root.attr("k"), String("v"), "attribute after a four-byte name")
    f += _refused("<a" + chr(0xF0000) + "/>", "invalid character in a name", "U+F0000 in a name")
    return f


def test_xml_declaration_shapes() raises -> Int:
    var f = 0
    # [25] Eq ::= S? '=' S?
    f += _accepted('<?xml version = "1.0" encoding =\t"UTF-8" ?><a/>', "S around '='")
    f += _accepted("<?xml version='1.1'?><a/>", "single-quoted version 1.1")
    # Byte offsets: '<?xml version' ends at 13.
    f += _refused("<?xml version?><a/>", "XML declaration at byte 13", "pseudo-attribute without '='")
    f += _refused('<?xml version!"1.0"?><a/>', "XML declaration at byte 13", "'!' for '='")
    f += _refused("<?xml version=1.0?><a/>", "XML declaration at byte 14", "unquoted version")
    f += _refused('<?xml version="1.0?><a/>', "XML declaration at byte 15", "unterminated version")
    f += _refused('<?xml version="1.0\'?><a/>', "XML declaration at byte 15", "mismatched quotes")
    f += _refused('<?xml version="1.0" foo="x"?><a/>', "XML declaration at byte 20", "unknown pseudo-attribute")
    f += _refused(
        '<?xml version="1.0" standalone="no" encoding="UTF-8"?><a/>',
        "XML declaration",
        "encoding after standalone",
    )
    # Each pseudo-attribute at most once ([23] XMLDecl). Byte offsets:
    # '<?xml version="1.0" ' ends at 20; '... encoding="UTF-8" ' at 37;
    # '... standalone="no" ' at 36.
    f += _refused('<?xml version="1.0" version="1.0"?><a/>', "XML declaration at byte 20", "version twice")
    f += _refused(
        '<?xml version="1.0" encoding="UTF-8" encoding="UTF-8"?><a/>',
        "XML declaration at byte 37",
        "encoding twice",
    )
    f += _refused(
        '<?xml version="1.0" standalone="no" standalone="no"?><a/>',
        "XML declaration at byte 36",
        "standalone twice",
    )
    f += _refused("<?xml?><a/>", "must start with the version", "empty XML declaration")
    f += _refused("<?xml ?><a/>", "must start with the version", "XML declaration of spaces")
    return f


def test_pi_and_tags_cut_off() raises -> Int:
    var f = 0
    f += _refused("<a><?pi data</a>", "unterminated processing instruction", "PI with no '?>'")
    f += _refused("<a><?pi/x?></a>", "malformed processing instruction target", "'/' after a PI target")
    f += _accepted("<a><?pi\tdata?></a>", "PI target, TAB, data")
    f += _refused("<a", "unterminated start tag", "start tag cut after the name")
    f += _refused('<a k="v"  ', "unterminated start tag", "start tag cut after an attribute")
    f += _refused('<a "x"/>', "malformed attribute name", "value with no name")
    f += _refused("<a k=", "unterminated attribute value", "cut after '='")
    f += _refused("<a k= ", "unterminated attribute value", "cut after '=' and S")
    f += _refused('<a k="v', "unterminated attribute value", "cut inside a value")
    f += _refused("<a k='v\"/>", "unterminated attribute value", "value closed by the other quote")
    return f


def test_reader_accessors() raises -> Int:
    var f = 0
    var rd = XmlReader.from_string(
        '<p:a xmlns:p="u" p:k="1" k2="&amp;"><b/></p:a>'
    )
    var ev = rd.next_event()
    f += _true(ev.kind == XML_START, "first event is START")
    f += _eq(rd.name_of(ev), String("p:a"), "qualified name")
    f += _eq(rd.local_name_of(ev), String("a"), "local name after the prefix")
    f += _eq(rd.attr_name(0), String("xmlns:p"), "attr 0 qualified name")
    f += _eq(rd.attr_local_name(0), String("p"), "attr 0 local name")
    f += _eq(rd.attr_local_name(1), String("k"), "attr 1 local name")
    f += _eq(rd.attr_local_name(2), String("k2"), "unprefixed attr local name")
    f += _eq(rd.slice_text(29, 34), String("&"), "slice_text decodes a value's bytes")
    f += _eq(rd.slice_text(0, 5), String("<p:a "), "slice_text over markup")
    var ev2 = rd.next_event()
    f += _eq(rd.local_name_of(ev2), String("b"), "local name with no prefix")
    return f


# -- the tree ----------------------------------------------------------------------


def test_reserved_namespace_names() raises -> Int:
    var f = 0
    # Namespaces in XML 1.0 §3: neither reserved name may be the default.
    f += _refused('<a xmlns="' + _XML_NS + '"/>', "default namespace cannot be", "xml ns as default")
    f += _refused('<a xmlns="' + _XMLNS_NS + '"/>', "default namespace cannot be", "xmlns ns as default")
    # ... nor bound to any prefix but xml.
    f += _refused(
        '<a xmlns:p="' + _XMLNS_NS + '"/>',
        "no prefix can be bound to the xmlns namespace name",
        "xmlns ns bound to a prefix",
    )
    return f


def test_canonical_node() raises -> Int:
    var f = 0
    # A parsed node in canonical form: attributes sorted by expanded name,
    # text stripped, a child below the root (depth 1) written in full.
    var root = parse_xml('<r xmlns:p="u" p:z="3" b="2" a="1"> t <x/></r>')
    f += _eq(
        canonical_node(root),
        String('<r a="1" b="2" {u}z="3">t<x></x></r>'),
        "canonical_node of a parsed tree",
    )
    return f


def test_tree_accessors_absent() raises -> Int:
    var f = 0
    var root = parse_xml('<r k="v"><x/><y/></r>')
    f += _true(root.has_child("y"), "has_child present")
    f += _true(not root.has_child("z"), "has_child absent")
    f += _true(root.has_attr("k"), "has_attr present")
    f += _true(not root.has_attr("q"), "has_attr absent")
    f += _eq(root.attr("q"), String(""), "attr absent is empty")
    f += _eq(root.first_child("y").local, String("y"), "first_child present")
    try:
        _ = root.first_child("z")
        f += _true(False, "first_child absent: no raise")
    except e:
        f += _eq(String(e), String("xml: no child <z>"), "first_child absent")
    return f


# -- the writer ----------------------------------------------------------------------


def test_writer_edges() raises -> Int:
    var f = 0
    var w = XmlWriter()
    f += _true(w.is_empty(), "fresh writer is empty")
    f += _true(w.depth() == 0, "fresh writer depth 0")
    try:
        w.end_element()
        f += _true(False, "end_element with nothing open: no raise")
    except e:
        f += _true(String(e).find("no open element") >= 0, "end_element: " + String(e))
    f += _true(w.is_empty(), "a refused end_element writes nothing")
    w.start_element("a")
    f += _true(not w.is_empty(), "not empty after a start tag")
    f += _true(w.depth() == 1, "depth 1")
    w.raw_text("<b/>&")
    w.start_element("c")
    f += _true(w.depth() == 2, "depth 2")
    w.end_element()
    f += _true(w.depth() == 1, "depth back to 1")
    w.end_element()
    f += _eq(w.finish(), String("<a><b/>&<c/></a>"), "raw_text is verbatim and closes the tag")
    return f


def main() raises:
    var failures = 0
    failures += test_unescape_edges()
    failures += test_reader_references_and_comments()
    failures += test_reader_utf8_and_names()
    failures += test_xml_declaration_shapes()
    failures += test_pi_and_tags_cut_off()
    failures += test_reader_accessors()
    failures += test_reserved_namespace_names()
    failures += test_canonical_node()
    failures += test_tree_accessors_absent()
    failures += test_writer_edges()
    if failures != 0:
        raise Error(String(failures) + " xml edge assertion(s) failed")
    print("OK — xml edge tests pass")
