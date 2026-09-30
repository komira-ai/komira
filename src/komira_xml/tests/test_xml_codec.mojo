# =============================================================================
# test_xml_codec.mojo — the general XML codec, independent of any AWS binding.
# =============================================================================
#
# The rest-xml conformance corpus proves the PROTOCOL. This proves the CODEC:
# the constructs botocore's corpus happens not to contain (CDATA, comments,
# processing instructions, numeric character references, single-quoted
# attributes, non-ASCII text) and the refusal paths (malformed input must
# RAISE, not silently produce a plausible tree).
#
# ★ It also carries the regression for a real defect class, per-byte entity
#   decoding of non-ASCII text — see `test_non_ascii`.
#
# Assertions return their failure COUNT rather than mutating a module-level
# tally: Mojo has no mutable module-scope binding, and a test that cannot
# count its own failures reports the last one only.
# =============================================================================

from komira_xml import (
    XML_END,
    XML_EOF,
    XML_START,
    XML_TEXT,
    XmlReader,
    XmlWriter,
    canonical_xml,
    parse_xml,
    xml_escape_attr,
    xml_escape_text,
    xml_unescape,
)


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


def test_escape() raises -> Int:
    var f = 0
    f += _eq(xml_escape_text("a<b>&c"), String("a&lt;b&gt;&amp;c"), "escape text")
    f += _eq(
        xml_escape_attr('he said "hi" & <x>'),
        String("he said &quot;hi&quot; &amp; &lt;x&gt;"),
        "escape attr",
    )
    f += _eq(
        xml_unescape("&lt;a&gt;&amp;&quot;&apos;"),
        String("<a>&\"'"),
        "unescape the five predefined entities",
    )
    f += _eq(xml_unescape("&#65;&#x42;&#x43;"), String("ABC"), "numeric refs")
    f += _eq(xml_unescape("&#x20AC;"), String("€"), "numeric ref, 3-byte UTF-8")
    # A bare `&` that begins nothing recognised is passed through, not eaten.
    f += _eq(xml_unescape("a & b"), String("a & b"), "bare ampersand survives")
    f += _eq(
        xml_unescape("&notanentity;"),
        String("&notanentity;"),
        "unknown entity passes through",
    )
    return f


def test_non_ascii() raises -> Int:
    """★ REGRESSION for a per-byte entity decoder.

    A decoder that builds its result with `out += chr(Int(c))` PER BYTE is
    wrong. For any byte >= 0x80 — i.e. every byte of every multi-byte UTF-8
    sequence — `chr` yields the codepoint whose NUMBER is that byte, which
    `String` then re-encodes as TWO bytes. A UTF-8 object key therefore
    comes back with each of its bytes doubled: `é` (C3 A9) becomes
    C3 83 C2 A9, which renders as `Ã©`.

    With such a decoder every S3 object key containing a non-ASCII character
    is affected, and it is silent — no raise, no truncation, just a wrong
    key. This codec scans and appends BYTES, so a multi-byte sequence is
    copied through untouched.
    """
    var f = 0
    f += _eq(xml_unescape("café"), String("café"), "non-ASCII passes through")
    f += _eq(
        xml_unescape("a&amp;é&lt;"),
        String("a&é<"),
        "non-ASCII around decoded entities",
    )
    var t = parse_xml("<Key>naïve/日本語.parquet</Key>")
    f += _eq(t.text, String("naïve/日本語.parquet"), "non-ASCII element text")
    return f


def test_reader_events() raises -> Int:
    var f = 0
    var rd = XmlReader.from_string(
        '<?xml version="1.0"?><!-- c --><a x="1" y=\'2\'><b/>t<![CDATA[<raw>]]></a>'
    )
    var kinds = List[Int]()
    var names = List[String]()
    var texts = List[String]()
    var nattr = 0
    while True:
        var ev = rd.next_event()
        if ev.kind == XML_EOF:
            break
        kinds.append(ev.kind)
        if ev.kind == XML_START:
            names.append(rd.name_of(ev))
            if rd.name_of(ev) == "a":
                nattr = ev.attr_count
                f += _eq(rd.attr_value(0), String("1"), "double-quoted attr")
                f += _eq(rd.attr_value(1), String("2"), "single-quoted attr")
        elif ev.kind == XML_END:
            names.append(String("/") + rd.name_of(ev))
        else:
            texts.append(rd.text_of(ev))
    f += _true(nattr == 2, "two attributes on <a>")
    # start a, start b, end b, text "t", text CDATA, end a
    f += _eq(String(len(kinds)), String("6"), "event count")
    f += _eq(names[0], String("a"), "first start")
    f += _eq(names[1], String("b"), "self-closing start")
    f += _eq(names[2], String("/b"), "self-closing synthesises an end")
    f += _eq(texts[0], String("t"), "text run")
    f += _eq(texts[1], String("<raw>"), "CDATA is NOT entity-decoded")
    return f


def test_writer() raises -> Int:
    var f = 0
    var w = XmlWriter()
    w.start_element("Root")
    w.attr("ns", 'a"b&c')
    w.start_element("Empty")
    w.end_element()
    w.start_element("T")
    w.text("<hi>")
    w.end_element()
    w.end_element()
    f += _eq(
        w.finish(),
        String('<Root ns="a&quot;b&amp;c"><Empty/><T>&lt;hi&gt;</T></Root>'),
        "writer output",
    )

    # An attribute after the tag closed is a bug in the CALLER, and it raises
    # rather than emitting `k="v"` into the element's content.
    var w2 = XmlWriter()
    w2.start_element("a")
    w2.text("x")
    var raised = False
    try:
        w2.attr("k", "v")
    except:
        raised = True
    f += _true(raised, "attribute after content raises")

    # An unbalanced document must not be handed out as a String.
    var w3 = XmlWriter()
    w3.start_element("a")
    var raised2 = False
    try:
        _ = w3.finish()
    except:
        raised2 = True
    f += _true(raised2, "finish() with an element still open raises")
    return f


def test_tree_and_namespaces() raises -> Int:
    var f = 0
    var t = parse_xml(
        '<r xmlns="urn:d" xmlns:p="urn:p"><p:k a="1">v</p:k><k>w</k></r>'
    )
    f += _eq(t.local, String("r"), "root local name")
    f += _eq(t.ns, String("urn:d"), "default namespace on the root")
    f += _eq(t.children[0].local, String("k"), "prefixed child local name")
    f += _eq(t.children[0].ns, String("urn:p"), "prefixed child namespace")
    f += _eq(t.children[1].ns, String("urn:d"), "unprefixed child inherits default")
    # An UNPREFIXED attribute is in no namespace (Namespaces in XML §6.2).
    f += _eq(t.children[0].attr_ns[0], String(""), "unprefixed attr has no ns")

    # Canonicalisation: prefix spelling is not semantic, the URI is.
    f += _eq(
        canonical_xml('<p:a xmlns:p="urn:x"><p:b>1</p:b></p:a>'),
        canonical_xml('<q:a xmlns:q="urn:x"><q:b>1</q:b></q:a>'),
        "prefix spelling canonicalises away",
    )
    f += _true(
        canonical_xml('<p:a xmlns:p="urn:x"/>')
        != canonical_xml('<p:a xmlns:p="urn:y"/>'),
        "a different namespace URI does NOT canonicalise away",
    )
    # Attribute ORDER is not semantic; attribute VALUE is.
    f += _eq(
        canonical_xml('<a x="1" y="2"/>'),
        canonical_xml('<a y="2" x="1"/>'),
        "attribute order canonicalises away",
    )
    f += _true(
        canonical_xml('<a x="1"/>') != canonical_xml('<a x="2"/>'),
        "a different attribute value does NOT canonicalise away",
    )
    return f


def test_malformed_raises() raises -> Int:
    """Hostile input must RAISE. A parser that returns a plausible tree for
    malformed bytes turns a protocol error into silently-wrong data."""
    var f = 0
    var bad = List[String]()
    bad.append(String("<a>"))  # unterminated element
    bad.append(String("</a>"))  # end tag with nothing open
    bad.append(String("<a><b></a>"))  # mismatched nesting leaves <b> open
    bad.append(String("<a x=1/>"))  # unquoted attribute value
    bad.append(String("<a x/>"))  # attribute without a value
    bad.append(String("<!-- unterminated"))  # unterminated comment
    bad.append(String("<a><![CDATA[oops</a>"))  # unterminated CDATA
    bad.append(String(""))  # no root element
    bad.append(String("   "))  # whitespace only
    bad.append(String("<a/><b/>"))  # two roots
    for i in range(len(bad)):
        var raised = False
        try:
            _ = parse_xml(bad[i])
        except:
            raised = True
        f += _true(raised, "malformed input must raise: '" + bad[i] + "'")
    return f


def test_round_trip() raises -> Int:
    var f = 0
    var w = XmlWriter()
    w.start_element("Contents")
    w.start_element("Key")
    w.text('dir/a&b<c>"d".parquet')
    w.end_element()
    w.start_element("ETag")
    w.text('"abc123"')
    w.end_element()
    w.end_element()
    var doc = w.finish()
    var t = parse_xml(doc)
    f += _eq(
        t.first_child("Key").text,
        String('dir/a&b<c>"d".parquet'),
        "round trip through escaping",
    )
    f += _eq(t.first_child("ETag").text, String('"abc123"'), "round trip quotes")
    return f


def main() raises:
    var failures = 0
    failures += test_escape()
    failures += test_non_ascii()
    failures += test_reader_events()
    failures += test_writer()
    failures += test_tree_and_namespaces()
    failures += test_malformed_raises()
    failures += test_round_trip()
    if failures != 0:
        raise Error(String(failures) + " xml codec assertion(s) failed")
    print("OK — xml codec unit tests pass")
