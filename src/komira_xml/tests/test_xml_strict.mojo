# =============================================================================
# test_xml_strict.mojo — well-formedness and namespace well-formedness.
# =============================================================================
#
# Each row cites the XML 1.0 (Fifth Edition) or Namespaces in XML 1.0 (Third
# Edition) rule it checks, or the rest-xml / S3 response shape it stands for.
# The parser is fed network bodies, so a document that breaks a
# well-formedness constraint must RAISE: a plausible tree built from a
# malformed body is silently wrong data. The refusal rows name the text the
# error must carry, so a refusal for the wrong reason does not pass.
#
# Only the API that predates the hardening is used here (`parse_xml`,
# `XmlReader`, `XmlWriter`), so every row can be run against both.
# =============================================================================

from komira_xml import (
    XML_EOF,
    XmlReader,
    XmlWriter,
    canonical_xml,
    parse_xml,
)


comptime _XML_NS = "http://www.w3.org/XML/1998/namespace"
comptime _S3_NS = "http://s3.amazonaws.com/doc/2006-03-01/"


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


def _drain(var src: List[UInt8]) raises:
    var rd = XmlReader(src^)
    while True:
        var ev = rd.next_event()
        if ev.kind == XML_EOF:
            return


def _bytes(prefix: String, mid: List[UInt8], suffix: String) -> List[UInt8]:
    var out = List[UInt8]()
    var p = prefix.as_bytes()
    for i in range(len(p)):
        out.append(p[i])
    for i in range(len(mid)):
        out.append(mid[i])
    var q = suffix.as_bytes()
    for i in range(len(q)):
        out.append(q[i])
    return out^


def _seq(*vals: Int) -> List[UInt8]:
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _bytes_refused(var src: List[UInt8], needle: String, what: String) -> Int:
    """The reader raises over `src`, mentioning `needle`."""
    try:
        _drain(src^)
    except e:
        var msg = String(e)
        if msg.find(needle) < 0:
            print("FAIL " + what + ": raised for another reason: " + msg)
            return 1
        return 0
    print("FAIL " + what + ": accepted")
    return 1


def _nest(depth: Int) -> String:
    var s = String()
    for _ in range(depth):
        s += "<a>"
    for _ in range(depth):
        s += "</a>"
    return s^


# -- XML 1.0 §3 [WFC: Element Type Match] --------------------------------------


def test_end_tag_matches_start_tag() raises -> Int:
    var f = 0
    f += _refused("<a><b></a></b>", "does not match", "crossed nesting")
    f += _refused("<a></b>", "does not match", "end tag names another element")
    f += _refused(
        '<p:a xmlns:p="urn:p" xmlns:q="urn:p"></q:a>',
        "does not match",
        "the QName must match, not the expanded name",
    )
    f += _refused("<ab></a>", "does not match", "end tag is a prefix of the start")
    f += _refused("<a></ab>", "does not match", "start tag is a prefix of the end")
    f += _refused("<a></a x>", "end tag", "an end tag carries no attributes")
    f += _refused("<a></a", "unterminated", "end tag cut off")
    # [42] ETag ::= '</' Name S? '>': whitespace before '>' is allowed.
    f += _eq(parse_xml("<a>v</a \n>").text, String("v"), "S? before '>' in an end tag")
    # The reader enforces it too, for callers that never build a tree.
    var mid = List[UInt8]()
    f += _bytes_refused(
        _bytes("<a><b></c></a>", mid, ""), "does not match", "reader: crossed tags"
    )
    return f


# -- Documents: one root, nothing but markup and whitespace outside it ---------


def test_document_shape() raises -> Int:
    var f = 0
    # [1] document ::= prolog element Misc*; Misc is comments, PIs and S.
    f += _refused("x<a/>", "outside the root", "text before the root")
    f += _refused("<a/>x", "outside the root", "text after the root")
    f += _refused("<a/><![CDATA[x]]>", "outside the root", "CDATA after the root")
    f += _refused("<a/><b/>", "root", "two root elements")
    f += _refused("<a><b/>", "unterminated", "EOF inside an element")
    f += _eq(
        parse_xml('\n<?xml-stylesheet href="s"?>\n<!-- c -->\n<a/>\n<!-- d -->\n').local,
        String("a"),
        "comments, PIs and whitespace around the root",
    )
    # [23] XMLDecl is only legal as the very first thing in the document, and
    # [17] PITarget excludes any case variant of 'xml'.
    f += _refused(' <?xml version="1.0"?><a/>', "declaration", "XMLDecl after S")
    f += _refused('<a/><?xml version="1.0"?>', "declaration", "XMLDecl after the root")
    f += _refused("<a><?XmL x?></a>", "declaration", "PI target 'xml' in any case")
    f += _eq(parse_xml("<a><?xml-ish x?></a>").local, String("a"), "PI target starting 'xml'")
    # §4.3.3: a UTF-8 byte order mark may precede the document.
    f += _eq(
        parse_xml(chr(0xFEFF) + '<?xml version="1.0" encoding="UTF-8"?><a>v</a>').text,
        String("v"),
        "UTF-8 BOM before the declaration",
    )
    # [15] Comment: '--' may not occur inside one, nor may it end in '-'.
    f += _refused("<a><!-- x -- y --></a>", "comment", "'--' inside a comment")
    f += _refused("<a><!-- x ---></a>", "comment", "comment ending '--->'")
    f += _refused("< a/>", "start tag", "whitespace after '<'")
    f += _refused("<a/ >", "self-closing", "whitespace inside '/>'")
    return f


# -- XML 1.0 §2.8: a DTD is refused, which is the XXE / entity-expansion defence


def test_dtd_refused() raises -> Int:
    var f = 0
    f += _refused(
        '<!DOCTYPE a [<!ENTITY x SYSTEM "file:///etc/passwd">]><a>&x;</a>',
        "DTD",
        "external entity (XXE)",
    )
    f += _refused(
        '<!DOCTYPE a SYSTEM "http://example.invalid/a.dtd"><a/>',
        "DTD",
        "external DTD subset",
    )
    var lol = String('<!DOCTYPE a [<!ENTITY l0 "lol">')
    for i in range(1, 10):
        lol += "<!ENTITY l" + String(i) + ' "'
        for _ in range(10):
            lol += "&l" + String(i - 1) + ";"
        lol += '">'
    lol += "]><a>&l9;</a>"
    f += _refused(lol, "DTD", "entity expansion (billion laughs)")
    f += _refused("<!DOCTYPE a><a/>", "DTD", "a bare DOCTYPE")
    f += _refused("<a><!DOCTYPE a></a>", "DTD", "DOCTYPE inside the root")
    f += _refused('<a><!ENTITY x "y"></a>', "markup declaration", "stray markup declaration")
    return f


# -- XML 1.0 §4.1, §4.6: references --------------------------------------------


def test_references() raises -> Int:
    var f = 0
    f += _eq(
        parse_xml("<a>&lt;&gt;&amp;&quot;&apos;</a>").text,
        String("<>&\"'"),
        "the five predefined entities",
    )
    f += _eq(parse_xml("<a>&#38;amp;</a>").text, String("&amp;"), "a reference is decoded once")
    f += _eq(parse_xml("<a>&#x1F600;</a>").text, chr(0x1F600), "supplementary-plane reference")
    f += _eq(parse_xml("<a>&#9;&#xA;</a>").text, String("\t\n"), "TAB and LF by reference")
    # [WFC: Entity Declared]: with no DTD only the five predefined exist.
    f += _refused("<a>&nbsp;</a>", "reference", "undeclared entity")
    f += _refused("<a>&foo;</a>", "reference", "undeclared entity, made-up name")
    f += _refused("<a>a & b</a>", "reference", "bare '&'")
    f += _refused("<a>&amp</a>", "reference", "reference without ';'")
    f += _refused("<a>&#;</a>", "reference", "empty decimal reference")
    f += _refused("<a>&#x;</a>", "reference", "empty hex reference")
    f += _refused("<a>&#12a;</a>", "reference", "non-digit in a decimal reference")
    # [WFC: Legal Character]: the referenced value must match [2] Char.
    f += _refused("<a>&#0;</a>", "character", "NUL by reference")
    f += _refused("<a>&#8;</a>", "character", "C0 control by reference")
    f += _refused("<a>&#xD800;</a>", "character", "surrogate by reference")
    f += _refused("<a>&#xFFFE;</a>", "character", "U+FFFE by reference")
    f += _refused("<a>&#x110000;</a>", "character", "beyond U+10FFFF by reference")
    f += _refused('<a x="&bogus;"/>', "reference", "undeclared entity in an attribute")
    return f


# -- XML 1.0 §2.7: CDATA sections ----------------------------------------------


def test_cdata() raises -> Int:
    var f = 0
    f += _eq(parse_xml("<a><![CDATA[<&>]]></a>").text, String("<&>"), "CDATA is literal")
    f += _eq(parse_xml("<a>x<![CDATA[y]]>z</a>").text, String("xyz"), "CDATA joins text")
    f += _eq(parse_xml("<a><![CDATA[]]></a>").text, String(""), "empty CDATA")
    f += _eq(parse_xml("<a><![CDATA[&amp;]]></a>").text, String("&amp;"), "no decoding in CDATA")
    # [14] CharData may not contain ']]>'.
    f += _refused("<a>x]]>y</a>", "]]>", "']]>' in character data")
    f += _eq(parse_xml("<a>]]</a>").text, String("]]"), "']]' alone is character data")
    return f


# -- XML 1.0 §2.11 line ends, §3.3.3 attribute-value normalisation -------------


def test_whitespace() raises -> Int:
    var f = 0
    f += _eq(parse_xml("<a>x\r\ny\rz</a>").text, String("x\ny\nz"), "CRLF and CR become LF")
    f += _eq(parse_xml("<a><![CDATA[x\r\ny]]></a>").text, String("x\ny"), "line ends in CDATA")
    f += _eq(parse_xml("<a>x&#13;y</a>").text, String("x\ry"), "CR by reference survives")
    # Text is kept as written: a reader that trims has to say so.
    f += _eq(parse_xml("<a>\n  v \n</a>").text, String("\n  v \n"), "text is not trimmed")
    var a = parse_xml('<a x="t\tu\nv\r\nw" y="l1&#10;l2&#9;&#13;"/>')
    f += _eq(a.attr("x"), String("t u v w"), "literal whitespace in a value becomes space")
    f += _eq(a.attr("y"), String("l1\nl2\t\r"), "whitespace by reference is kept")
    # The writer escapes whitespace in values so a round trip keeps it.
    var w = XmlWriter()
    w.start_element("a")
    w.attr("x", "p\tq\nr\rs")
    w.text("m\rn")
    w.end_element()
    var back = parse_xml(w.finish())
    f += _eq(back.attr("x"), String("p\tq\nr\rs"), "attribute whitespace round trip")
    f += _eq(back.text, String("m\rn"), "text CR round trip")
    # botocore compares with ET.canonicalize(strip_text=True): pretty-printing
    # is not semantic.
    f += _eq(
        canonical_xml("<a>\n  <b>1</b>\n</a>"),
        canonical_xml("<a><b>1</b></a>"),
        "indentation canonicalises away",
    )
    return f


# -- XML 1.0 §3.1: attributes and empty elements -------------------------------


def test_attributes_and_empty_elements() raises -> Int:
    var f = 0
    # [WFC: Unique Att Spec]
    f += _refused('<a x="1" x="2"/>', "duplicate attribute", "same attribute twice")
    f += _refused('<a xmlns="u" xmlns="v"/>', "duplicate attribute", "xmlns twice")
    # [40] STag requires S between attributes.
    f += _refused('<a x="1"y="2"/>', "attribute", "no whitespace between attributes")
    # [WFC: No < in Attribute Values]
    f += _refused('<a x="<"/>', "'<'", "'<' in an attribute value")
    f += _eq(
        parse_xml("<a x='say \"hi\" &amp; &apos;bye&apos;'/>").attr("x"),
        String("say \"hi\" & 'bye'"),
        "single-quoted value with references",
    )
    f += _eq(parse_xml('<a x=""/>').attr("x"), String(""), "empty attribute value")
    f += _eq(parse_xml('<a x = "1"/>').attr("x"), String("1"), "S around '='")
    # [44] EmptyElemTag and an empty start/end pair are the same element.
    var e1 = parse_xml("<a/>")
    var e2 = parse_xml("<a></a>")
    f += _true(e1.text == "" and e1.child_count() == 0, "<a/> is empty")
    f += _true(e2.text == "" and e2.child_count() == 0, "<a></a> is empty")
    f += _eq(canonical_xml("<a/>"), canonical_xml("<a></a>"), "the two spellings agree")
    f += _eq(
        parse_xml("<r><Prefix/><Marker></Marker></r>").children[0].text,
        String(""),
        "an empty element reads as the empty string",
    )
    return f


# -- Namespaces in XML 1.0 -----------------------------------------------------


def test_namespaces() raises -> Int:
    var f = 0
    # The S3 shape: a default namespace declared on the root, inherited.
    var t = parse_xml(
        '<ListBucketResult xmlns="' + _S3_NS + '"><Name>b</Name>'
        + "<Contents><Key>k</Key></Contents></ListBucketResult>"
    )
    f += _eq(t.ns, String(_S3_NS), "default namespace on the root")
    f += _eq(t.children[1].children[0].ns, String(_S3_NS), "inherited two levels down")
    # §6.2: xmlns="" undeclares the default for that subtree.
    var u = parse_xml('<r xmlns="urn:d"><c xmlns=""><g/></c><h/></r>')
    f += _eq(u.children[0].ns, String(""), "xmlns='' undeclares")
    f += _eq(u.children[0].children[0].ns, String(""), "undeclared for descendants")
    f += _eq(u.children[1].ns, String("urn:d"), "the default resumes after the subtree")
    # §6.1: an inner declaration shadows an outer one, for its subtree only.
    var s = parse_xml('<p:r xmlns:p="urn:1"><p:c xmlns:p="urn:2"/><p:d/></p:r>')
    f += _eq(s.children[0].ns, String("urn:2"), "inner binding shadows")
    f += _eq(s.children[1].ns, String("urn:1"), "outer binding resumes")
    # [NSC: Prefix Declared]
    f += _refused("<p:a/>", "prefix", "undeclared element prefix")
    f += _refused('<a p:x="1"/>', "prefix", "undeclared attribute prefix")
    f += _refused('<r><p:a xmlns:p="urn:p"/><p:b/></r>', "prefix", "prefix out of scope")
    # §3: 'xml' is bound by definition; it may be redeclared only to its URI.
    var x = parse_xml('<a xml:lang="en"/>')
    f += _eq(x.attr_ns[0], String(_XML_NS), "the xml prefix needs no declaration")
    f += _eq(
        parse_xml('<a xmlns:xml="' + _XML_NS + '" xml:space="preserve"/>').attr("space"),
        String("preserve"),
        "redeclaring xml to its own URI",
    )
    f += _refused('<a xmlns:xml="urn:x"/>', "xml", "xml bound to another URI")
    f += _refused('<a xmlns:p="' + _XML_NS + '"/>', "xml", "another prefix bound to the xml URI")
    f += _refused('<a xmlns:xmlns="urn:x"/>', "xmlns", "declaring the xmlns prefix")
    f += _refused("<xmlns:a/>", "xmlns", "an element in the xmlns prefix")
    # [NSC: No Prefix Undeclaring] (Namespaces 1.0; 1.1 allows it).
    f += _refused('<a xmlns:p=""/>', "empty", "xmlns:p=''")
    # [7] QName: at most one colon, never at either end.
    f += _refused('<p:a:b xmlns:p="urn:p"/>', "name", "two colons in a name")
    f += _refused("<a:/>", "name", "empty local part")
    f += _refused('<a :x="1"/>', "name", "empty prefix on an attribute")
    # §6.3: attribute uniqueness is on the EXPANDED name too.
    f += _refused(
        '<a xmlns:p="urn:u" xmlns:q="urn:u" p:x="1" q:x="2"/>',
        "duplicate attribute",
        "two prefixes for one URI on the same local name",
    )
    f += _eq(
        String(len(parse_xml('<a xmlns:p="urn:u" x="1" p:x="2"/>').attr_local)),
        String("2"),
        "unprefixed and prefixed x are distinct",
    )
    return f


# -- XML 1.0 §2.2 Char, §4.3.3 encoding ----------------------------------------


def test_characters_and_encoding() raises -> Int:
    var f = 0
    f += _refused(String("<a>x") + chr(1) + "</a>", "character", "C0 control in text")
    f += _refused(String('<a x="') + chr(0x1F) + '"/>', "character", "C0 control in a value")
    f += _refused(String("<a>") + chr(0xFFFF) + "</a>", "character", "U+FFFF literally")
    f += _eq(parse_xml("<a>\tx\n</a>").text, String("\tx\n"), "TAB and LF are Chars")
    var bad = List[List[UInt8]]()
    bad.append(_seq(0xFF))  # never valid in UTF-8
    bad.append(_seq(0xC3))  # truncated sequence
    bad.append(_seq(0xC0, 0x80))  # overlong NUL
    bad.append(_seq(0xE0, 0x80, 0x80))  # overlong
    bad.append(_seq(0xED, 0xA0, 0x80))  # encoded surrogate U+D800
    bad.append(_seq(0xF4, 0x90, 0x80, 0x80))  # U+110000
    bad.append(_seq(0x80))  # lone continuation byte
    for i in range(len(bad)):
        f += _bytes_refused(
            _bytes("<a>", bad[i], "</a>"), "UTF-8", "invalid UTF-8 row " + String(i)
        )
    var good = _seq(0xF0, 0x9F, 0x98, 0x80)
    try:
        _drain(_bytes("<a>", good, "</a>"))
    except e:
        f += _true(False, "4-byte UTF-8 refused: " + String(e))
    return f


# -- Nesting depth: the bound that protects a recursive walk or destructor -----


def test_depth_limit() raises -> Int:
    var f = 0
    var ok = parse_xml(_nest(512))
    f += _eq(ok.local, String("a"), "512 levels parse")
    f += _refused(_nest(513), "deeper than 512", "513 levels")
    f += _refused(_nest(100000), "deeper than 512", "100000 levels")
    var mid = List[UInt8]()
    f += _bytes_refused(
        _bytes(_nest(600), mid, ""), "deeper than 512", "the reader enforces it"
    )
    return f


# -- The writer never emits what the parser must refuse ------------------------


def _writer_text_raises(s: String) -> Bool:
    var w = XmlWriter()
    w.start_element("a")
    try:
        w.text(s)
    except:
        return True
    return False


def _writer_attr_raises(s: String) -> Bool:
    var w = XmlWriter()
    w.start_element("a")
    try:
        w.attr("k", s)
    except:
        return True
    return False


def test_writer_refuses_illegal_characters() raises -> Int:
    var f = 0
    f += _true(_writer_text_raises(String("a") + chr(0) + "b"), "writer: NUL in text")
    f += _true(_writer_text_raises(String("a") + chr(0x1B) + "b"), "writer: ESC in text")
    f += _true(_writer_attr_raises(String("a") + chr(1)), "writer: C0 in a value")
    f += _true(not _writer_text_raises("tab\tlf\ncr\r"), "writer: TAB LF CR are fine")
    f += _true(not _writer_attr_raises("tab\tlf\ncr\r"), "writer: TAB LF CR in a value")
    return f


def main() raises:
    var failures = 0
    failures += test_end_tag_matches_start_tag()
    failures += test_document_shape()
    failures += test_dtd_refused()
    failures += test_references()
    failures += test_cdata()
    failures += test_whitespace()
    failures += test_attributes_and_empty_elements()
    failures += test_namespaces()
    failures += test_characters_and_encoding()
    failures += test_writer_refuses_illegal_characters()
    # Last: on a parser with no depth bound, the deep rows crash the process.
    failures += test_depth_limit()
    if failures != 0:
        raise Error(String(failures) + " xml strictness assertion(s) failed")
    print("OK — xml strictness tests pass")
