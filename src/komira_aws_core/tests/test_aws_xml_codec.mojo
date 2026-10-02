# The restXml body codec (aws_xml.mojo): each row is derived from the rule it
# cites, never copied from a corpus body.
#
#   [RX]  https://smithy.io/2.0/aws/protocols/aws-restxml-protocol.html
#         (XML shape serialization: lists, maps, timestamps, blobs, NaN)
#   [XT]  https://smithy.io/2.0/spec/protocol-traits.html (xmlName,
#         xmlAttribute, xmlFlattened, xmlNamespace, timestampFormat)
#   [NS]  Namespaces in XML 1.0 (third edition), section 3
#   [64]  RFC 4648 section 4 (base64)
#   [BC]  botocore's RestXMLParser (an empty element is "", an absent one is
#         no value; elements matched by local name)

from std.collections import Dict
from std.testing import assert_equal, assert_false, assert_true

from komira_xml import XmlNode, XmlWriter, canonical_xml, parse_xml

from komira_aws_core import (
    AWS_TS_ISO8601,
    AWS_TS_RFC822,
    AWS_TS_UNIX,
    AwsRequest,
    aws_xml_attr,
    aws_xml_blob_of,
    aws_xml_bool_of,
    aws_xml_child,
    aws_xml_end,
    aws_xml_entry_key,
    aws_xml_entry_value,
    aws_xml_f32_of,
    aws_xml_f64_of,
    aws_xml_get_attr,
    aws_xml_get_blob,
    aws_xml_get_bool,
    aws_xml_get_f64,
    aws_xml_get_int,
    aws_xml_get_string,
    aws_xml_get_string_list,
    aws_xml_get_string_map,
    aws_xml_get_struct,
    aws_xml_get_ts,
    aws_xml_int_of,
    aws_xml_list_end,
    aws_xml_list_items,
    aws_xml_list_start,
    aws_xml_map_end,
    aws_xml_map_entries,
    aws_xml_map_entry_start,
    aws_xml_map_start,
    aws_xml_namespace,
    aws_xml_parse,
    aws_xml_set_body,
    aws_xml_start,
    aws_xml_string_of,
    aws_xml_ts_of,
    aws_xml_write_blob,
    aws_xml_write_bool,
    aws_xml_write_f32,
    aws_xml_write_f64,
    aws_xml_write_int,
    aws_xml_write_string,
    aws_xml_write_string_list,
    aws_xml_write_string_map,
    aws_xml_write_ts,
)


# Tue, 15 Sep 2026 12:00:00 GMT.
comptime _INSTANT = 1789473600.0


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    out.extend(Span(s.as_bytes()))
    return out^


def _doc(s: String) raises -> XmlNode:
    return aws_xml_parse(_bytes(s))


def _same_xml(got: String, want: String) raises:
    """`got` and `want` are the same document, compared as botocore
    compares bodies: canonical form, text stripped."""
    assert_equal(canonical_xml(got), canonical_xml(want), got)


# -----------------------------------------------------------------------------
# Writing
# -----------------------------------------------------------------------------


def test_write_scalars() raises:
    # [RX] each scalar is an element named for its member, its text the
    # scalar's text form.
    var w = XmlWriter()
    aws_xml_start(w, "Input")
    aws_xml_write_string(w, "Str", "a<b&c")
    aws_xml_write_string(w, "Empty", "")
    aws_xml_write_bool(w, "T", True)
    aws_xml_write_bool(w, "F", False)
    aws_xml_write_int(w, "I", Int64(-42))
    aws_xml_write_int(w, "L", Int64(9007199254740993))
    aws_xml_write_f64(w, "D", 1.5)
    aws_xml_write_f32(w, "Fl", Float32(0.1))
    aws_xml_end(w)
    var got = w.finish()
    _same_xml(
        got,
        "<Input><Str>a&lt;b&amp;c</Str><Empty></Empty><T>true</T>"
        + "<F>false</F><I>-42</I><L>9007199254740993</L><D>1.5</D>"
        + "<Fl>0.1</Fl></Input>",
    )
    # The text is escaped on the wire, not merely canonically equal.
    assert_true(got.find("a&lt;b&amp;c") >= 0, got)


def test_write_special_floats() raises:
    # [RX] NaN, Infinity and -Infinity are written as those words.
    var z = Float64(0.0)
    var w = XmlWriter()
    aws_xml_start(w, "N")
    aws_xml_write_f64(w, "A", z / z)
    aws_xml_write_f64(w, "B", Float64(1.0) / z)
    aws_xml_write_f64(w, "C", Float64(-1.0) / z)
    aws_xml_write_f32(w, "E", Float32(-1.0) / Float32(0.0))
    aws_xml_end(w)
    _same_xml(
        w.finish(),
        "<N><A>NaN</A><B>Infinity</B><C>-Infinity</C><E>-Infinity</E></N>",
    )


def test_write_blob_and_timestamps() raises:
    # [64] "foo" is "Zm9v"; [RX] the body timestamp default is date-time;
    # [XT] http-date and epoch-seconds when the member says so.
    var w = XmlWriter()
    aws_xml_start(w, "S")
    var foo = _bytes("foo")
    aws_xml_write_blob(w, "Blob", Span(foo))
    var none = List[UInt8]()
    aws_xml_write_blob(w, "EmptyBlob", Span(none))
    aws_xml_write_ts(w, "Iso", _INSTANT, AWS_TS_ISO8601)
    aws_xml_write_ts(w, "IsoMs", _INSTANT + 0.25, AWS_TS_ISO8601)
    aws_xml_write_ts(w, "Http", _INSTANT, AWS_TS_RFC822)
    aws_xml_write_ts(w, "Epoch", _INSTANT, AWS_TS_UNIX)
    aws_xml_write_ts(w, "EpochMs", _INSTANT + 0.5, AWS_TS_UNIX)
    aws_xml_end(w)
    _same_xml(
        w.finish(),
        "<S><Blob>Zm9v</Blob><EmptyBlob></EmptyBlob>"
        + "<Iso>2026-09-15T12:00:00Z</Iso>"
        + "<IsoMs>2026-09-15T12:00:00.25Z</IsoMs>"
        + "<Http>Tue, 15 Sep 2026 12:00:00 GMT</Http>"
        + "<Epoch>1789473600</Epoch><EpochMs>1789473600.5</EpochMs></S>",
    )
    # A NaN timestamp has no text.
    var w2 = XmlWriter()
    aws_xml_start(w2, "S")
    var z = Float64(0.0)
    try:
        aws_xml_write_ts(w2, "T", z / z, AWS_TS_ISO8601)
        raise Error("a timestamp that is not a number was written")
    except e:
        assert_true(String(e).find("NaN") >= 0, String(e))


def test_write_lists() raises:
    # [RX] a wrapped list: the member element holding one element per item,
    # named by the list member's xmlName ("member" by default).
    var vals: List[String] = ["a", "b"]
    var w = XmlWriter()
    aws_xml_start(w, "Input")
    aws_xml_write_string_list(w, "Wrapped", "member", vals, False)
    aws_xml_write_string_list(w, "Named", "item", vals, False)
    # [XT] xmlFlattened: one element per item, each named for the member.
    aws_xml_write_string_list(w, "Flat", "ignored", vals, True)
    # An empty wrapped list is an empty wrapper; an empty flattened list is
    # nothing at all.
    var empty = List[String]()
    aws_xml_write_string_list(w, "NoneWrapped", "member", empty, False)
    aws_xml_write_string_list(w, "NoneFlat", "member", empty, True)
    # A list of structures, through the start/end helpers.
    aws_xml_list_start(w, "Parts", False)
    for n in range(1, 3):
        aws_xml_start(w, "Part")
        aws_xml_write_int(w, "PartNumber", Int64(n))
        aws_xml_end(w)
    aws_xml_list_end(w, False)
    aws_xml_list_start(w, "Part", True)
    aws_xml_start(w, "Part")
    aws_xml_write_int(w, "PartNumber", Int64(7))
    aws_xml_end(w)
    aws_xml_list_end(w, True)
    aws_xml_end(w)
    _same_xml(
        w.finish(),
        "<Input>"
        + "<Wrapped><member>a</member><member>b</member></Wrapped>"
        + "<Named><item>a</item><item>b</item></Named>"
        + "<Flat>a</Flat><Flat>b</Flat>"
        + "<NoneWrapped/>"
        + "<Parts><Part><PartNumber>1</PartNumber></Part>"
        + "<Part><PartNumber>2</PartNumber></Part></Parts>"
        + "<Part><PartNumber>7</PartNumber></Part>"
        + "</Input>",
    )


def test_write_maps() raises:
    # [RX] a wrapped map: <entry> per entry holding the key and the value
    # elements; key and value named by their xmlName ("key" / "value").
    var m = Dict[String, String]()
    m["k1"] = "v1"
    m["k2"] = "v2"
    var w = XmlWriter()
    aws_xml_start(w, "Input")
    aws_xml_write_string_map(w, "Map", "key", "value", m, False)
    aws_xml_write_string_map(w, "Named", "K", "V", m, False)
    # [XT] xmlFlattened: one element per entry, named for the member.
    aws_xml_write_string_map(w, "Flat", "key", "value", m, True)
    # A map of structures, through the start/end helpers.
    aws_xml_map_start(w, "Nested", False)
    aws_xml_map_entry_start(w, "Nested", False)
    aws_xml_write_string(w, "key", "x")
    aws_xml_start(w, "value")
    aws_xml_write_int(w, "N", Int64(1))
    aws_xml_end(w)
    aws_xml_end(w)
    aws_xml_map_end(w, False)
    aws_xml_end(w)
    _same_xml(
        w.finish(),
        "<Input>"
        + "<Map><entry><key>k1</key><value>v1</value></entry>"
        + "<entry><key>k2</key><value>v2</value></entry></Map>"
        + "<Named><entry><K>k1</K><V>v1</V></entry>"
        + "<entry><K>k2</K><V>v2</V></entry></Named>"
        + "<Flat><key>k1</key><value>v1</value></Flat>"
        + "<Flat><key>k2</key><value>v2</value></Flat>"
        + "<Nested><entry><key>x</key><value><N>1</N></value></entry></Nested>"
        + "</Input>",
    )


def test_write_namespaces_and_attributes() raises:
    # [XT] xmlNamespace: xmlns="uri" or xmlns:prefix="uri" on the element.
    var w = XmlWriter()
    aws_xml_start(w, "CreateBucketConfiguration")
    aws_xml_namespace(w, "", "http://s3.amazonaws.com/doc/2006-03-01/")
    aws_xml_write_string(w, "LocationConstraint", "eu-west-1")
    aws_xml_end(w)
    var got = w.finish()
    assert_equal(
        got,
        '<CreateBucketConfiguration xmlns="http://s3.amazonaws.com/doc/'
        + '2006-03-01/"><LocationConstraint>eu-west-1</LocationConstraint>'
        + "</CreateBucketConfiguration>",
    )
    # [XT] xmlAttribute with a prefixed name, its prefix declared.
    var w2 = XmlWriter()
    aws_xml_start(w2, "Grantee")
    aws_xml_namespace(w2, "xsi", "http://www.w3.org/2001/XMLSchema-instance")
    aws_xml_attr(w2, "xsi:type", "CanonicalUser")
    aws_xml_write_string(w2, "ID", "abc")
    aws_xml_end(w2)
    var g = w2.finish()
    _same_xml(
        g,
        '<Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" '
        + 'xsi:type="CanonicalUser"><ID>abc</ID></Grantee>',
    )
    # The attribute reads back by its model name.
    var back = parse_xml(g)
    assert_equal(aws_xml_get_attr(back, "xsi:type").value(), "CanonicalUser")
    # An attribute value is escaped.
    var w3 = XmlWriter()
    aws_xml_start(w3, "A")
    aws_xml_attr(w3, "v", 'x"<&')
    aws_xml_end(w3)
    assert_equal(aws_xml_get_attr(parse_xml(w3.finish()), "v").value(), 'x"<&')


def _ns_refused(prefix: String, uri: String) raises:
    var w = XmlWriter()
    aws_xml_start(w, "A")
    try:
        aws_xml_namespace(w, prefix, uri)
    except:
        return
    raise Error("namespace '" + prefix + "'='" + uri + "' was written")


def _name_refused(name: String) raises:
    var w = XmlWriter()
    try:
        aws_xml_start(w, name)
    except:
        return
    raise Error("element name '" + name + "' was written")


def test_write_refusals() raises:
    # [NS] no undeclaring, the reserved prefixes, one colon at most.
    _ns_refused("", "")
    _ns_refused("p", "")
    _ns_refused("xmlns", "urn:x")
    _ns_refused("xml", "urn:x")
    _ns_refused("a:b", "urn:x")
    # Names that would break the document.
    _name_refused("")
    _name_refused("a b")
    _name_refused("a<b")
    _name_refused("a/b")
    _name_refused('a"b')
    # A value XML cannot carry (a C0 control) is refused by the writer.
    var w = XmlWriter()
    aws_xml_start(w, "A")
    try:
        aws_xml_write_string(w, "B", "x" + chr(1) + "y")
        raise Error("a C0 control was written")
    except e:
        assert_true(String(e).find("XML cannot represent") >= 0, String(e))
    # The body refuses an element left open.
    var w2 = XmlWriter()
    aws_xml_start(w2, "A")
    var req = AwsRequest(String("PUT"), String("/"))
    try:
        aws_xml_set_body(req, w2)
        raise Error("a body with an open element was set")
    except e:
        assert_true(String(e).find("left open") >= 0, String(e))


def test_set_body() raises:
    var w = XmlWriter()
    aws_xml_start(w, "A")
    aws_xml_write_string(w, "B", "é")
    aws_xml_end(w)
    var req = AwsRequest(String("PUT"), String("/"))
    aws_xml_set_body(req, w)
    assert_equal(req.body_text(), "<A><B>é</B></A>")


# -----------------------------------------------------------------------------
# Reading
# -----------------------------------------------------------------------------


def test_read_scalars() raises:
    var d = _doc(
        "<Out><S>  spaced  </S><E></E><Self/><T>true</T><F> false\n</F>"
        + "<I>-7</I><Big>9223372036854775807</Big><D>2.5e3</D>"
        + "<N>NaN</N><P>Infinity</P><M>-Infinity</M>"
        + "<B>Zm9v</B><EB/><Ts>2026-09-15T12:00:00.5Z</Ts>"
        + "<Hd>Tue, 15 Sep 2026 12:00:00 GMT</Hd><Ep>1789473600</Ep>"
        + "<Ent>a&amp;b&#x41;</Ent><Cd><![CDATA[<raw>]]></Cd></Out>"
    )
    # [BC] a string is its text as written; an empty element is "".
    assert_equal(aws_xml_get_string(d, "S").value(), "  spaced  ")
    assert_equal(aws_xml_get_string(d, "E").value(), "")
    assert_equal(aws_xml_get_string(d, "Self").value(), "")
    assert_equal(aws_xml_get_string(d, "Ent").value(), "a&bA")
    assert_equal(aws_xml_get_string(d, "Cd").value(), "<raw>")
    # [BC] an absent element is no value.
    assert_false(Bool(aws_xml_get_string(d, "Missing")))
    assert_false(Bool(aws_xml_get_int(d, "Missing", 32)))
    # Non-string scalars are read trimmed of XML whitespace.
    assert_true(aws_xml_get_bool(d, "T").value())
    assert_false(aws_xml_get_bool(d, "F").value())
    assert_equal(aws_xml_get_int(d, "I", 32).value(), Int64(-7))
    assert_equal(
        aws_xml_get_int(d, "Big", 64).value(), Int64(9223372036854775807)
    )
    assert_equal(aws_xml_get_f64(d, "D").value(), 2500.0)
    # [RX] NaN and the infinities.
    var nan = aws_xml_get_f64(d, "N").value()
    assert_true(nan != nan)
    assert_true(aws_xml_get_f64(d, "P").value() > 1.0e308)
    assert_true(aws_xml_get_f64(d, "M").value() < -1.0e308)
    var nf = aws_xml_f32_of(d.children[aws_xml_child(d, "N")])
    assert_true(nf != nf)
    # [64] base64; an empty element is the empty blob.
    var blob = aws_xml_get_blob(d, "B").value().copy()
    assert_equal(len(blob), 3)
    assert_equal(blob[0], UInt8(0x66))
    assert_equal(len(aws_xml_get_blob(d, "EB").value()), 0)
    # [XT] each timestamp format.
    assert_equal(aws_xml_get_ts(d, "Ts", AWS_TS_ISO8601).value(), _INSTANT + 0.5)
    assert_equal(aws_xml_get_ts(d, "Hd", AWS_TS_RFC822).value(), _INSTANT)
    assert_equal(aws_xml_get_ts(d, "Ep", AWS_TS_UNIX).value(), _INSTANT)


def _scalar_refused(body: String, kind: String) raises:
    var kinds: List[String] = [
        "bool", "i32", "i8", "f64", "blob", "iso", "http", "string"
    ]
    var known = False
    for i in range(len(kinds)):
        if kinds[i] == kind:
            known = True
    if not known:
        raise Error("unknown kind " + kind)
    var d = _doc(body)
    var n = d.children[0].copy()
    try:
        if kind == "bool":
            _ = aws_xml_bool_of(n)
        elif kind == "i32":
            _ = aws_xml_int_of(n, 32)
        elif kind == "i8":
            _ = aws_xml_int_of(n, 8)
        elif kind == "f64":
            _ = aws_xml_f64_of(n)
        elif kind == "blob":
            _ = aws_xml_blob_of(n)
        elif kind == "iso":
            _ = aws_xml_ts_of(n, AWS_TS_ISO8601)
        elif kind == "http":
            _ = aws_xml_ts_of(n, AWS_TS_RFC822)
        elif kind == "string":
            _ = aws_xml_string_of(n)
        else:
            return
    except:
        return
    raise Error(kind + " read from " + body)


def test_read_refusals() raises:
    # Booleans are exactly true / false.
    _scalar_refused("<a><v>TRUE</v></a>", "bool")
    _scalar_refused("<a><v>1</v></a>", "bool")
    _scalar_refused("<a><v/></a>", "bool")
    # Integers: digits only, in range; an empty element is no integer.
    _scalar_refused("<a><v>1.0</v></a>", "i32")
    _scalar_refused("<a><v>2147483648</v></a>", "i32")
    _scalar_refused("<a><v>128</v></a>", "i8")
    _scalar_refused("<a><v></v></a>", "i32")
    _scalar_refused("<a><v>1 2</v></a>", "i32")
    # Numbers: a decimal number or the three words, nothing else.
    _scalar_refused("<a><v>nan</v></a>", "f64")
    _scalar_refused("<a><v>0x10</v></a>", "f64")
    _scalar_refused("<a><v/></a>", "f64")
    # [64] padded standard base64.
    _scalar_refused("<a><v>Zm9</v></a>", "blob")
    _scalar_refused("<a><v>Zm9v!</v></a>", "blob")
    # A timestamp in another format than the member's.
    _scalar_refused("<a><v>Tue, 15 Sep 2026 12:00:00 GMT</v></a>", "iso")
    _scalar_refused("<a><v>2026-09-15T12:00:00Z</v></a>", "http")
    # A scalar element holding elements.
    _scalar_refused("<a><v><x/></v></a>", "string")
    _scalar_refused("<a><v>1<x/></v></a>", "i32")


def test_read_structures() raises:
    var d = _doc(
        '<Out xmlns="urn:svc"><Nested><Inner>x</Inner></Nested>'
        + "<Dup>first</Dup><Dup>last</Dup><Unknown>u</Unknown></Out>"
    )
    # [BC] elements match by local name, whatever their namespace.
    var nested = aws_xml_get_struct(d, "Nested").value().copy()
    assert_equal(aws_xml_get_string(nested, "Inner").value(), "x")
    assert_false(Bool(aws_xml_get_struct(d, "Missing")))
    # A member that occurs twice takes its last occurrence.
    assert_equal(aws_xml_get_string(d, "Dup").value(), "last")
    assert_equal(aws_xml_child(d, "Dup"), 2)
    assert_equal(aws_xml_child(d, "Missing"), -1)


def test_read_lists() raises:
    var d = _doc(
        "<Out><W><member>a</member><member>b</member></W>"
        + "<Named><item>x</item><other>ignored</other><item>y</item></Named>"
        + "<EmptyW/>"
        + "<F>1</F><Mid/><F>2</F>"
        + "<Parts><Part><N>1</N></Part><Part><N>2</N></Part></Parts></Out>"
    )
    # [RX] wrapped: the member elements of the wrapper.
    var w = aws_xml_get_string_list(d, "W", "member", False).value().copy()
    assert_equal(len(w), 2)
    assert_equal(w[0], "a")
    assert_equal(w[1], "b")
    # A child of another name than the list member's is not an item.
    var n = aws_xml_get_string_list(d, "Named", "item", False).value().copy()
    assert_equal(len(n), 2)
    assert_equal(n[1], "y")
    # A present, empty wrapper is the empty list; no element is None.
    assert_equal(len(aws_xml_get_string_list(d, "EmptyW", "member", False).value()), 0)
    assert_false(Bool(aws_xml_get_string_list(d, "Absent", "member", False)))
    # [XT] flattened: every element named for the member, in order, even
    # when other members come between.
    var f = aws_xml_get_string_list(d, "F", "member", True).value().copy()
    assert_equal(len(f), 2)
    assert_equal(f[0], "1")
    assert_equal(f[1], "2")
    assert_false(Bool(aws_xml_get_string_list(d, "Absent", "member", True)))
    # A list of structures.
    var parts = aws_xml_list_items(d, "Parts", "Part", False).value().copy()
    assert_equal(len(parts), 2)
    assert_equal(aws_xml_get_int(parts[1], "N", 32).value(), Int64(2))


def test_read_maps() raises:
    var d = _doc(
        "<Out><M><entry><key>a</key><value>1</value></entry>"
        + "<entry><value>2</value><key>b</key></entry>"
        + "<entry><key>a</key><value>3</value></entry></M>"
        + "<Named><entry><K>k</K><V>v</V></entry></Named>"
        + "<Fl><key>x</key><value>X</value></Fl><Other/>"
        + "<Fl><key>y</key><value>Y</value></Fl>"
        + "<EmptyM/>"
        + "<Bad><entry><key>a</key><value>1</value><extra/></entry></Bad>"
        + "<NoValue><entry><key>a</key></entry></NoValue>"
        + "<S><entry><key>s</key><value><N>9</N></value></entry></S></Out>"
    )
    # [RX] wrapped: <entry> elements, key and value in either order; a
    # later entry for a key replaces the earlier one.
    var m = aws_xml_get_string_map(d, "M", "key", "value", False).value().copy()
    assert_equal(len(m), 2)
    assert_equal(m["a"], "3")
    assert_equal(m["b"], "2")
    var named = aws_xml_get_string_map(d, "Named", "K", "V", False).value().copy()
    assert_equal(named["k"], "v")
    # [XT] flattened.
    var fl = aws_xml_get_string_map(d, "Fl", "key", "value", True).value().copy()
    assert_equal(len(fl), 2)
    assert_equal(fl["y"], "Y")
    assert_equal(len(aws_xml_get_string_map(d, "EmptyM", "key", "value", False).value()), 0)
    assert_false(Bool(aws_xml_get_string_map(d, "Absent", "key", "value", False)))
    # [BC] an entry with a child that is neither key nor value is refused,
    # and so is one with no value.
    try:
        _ = aws_xml_get_string_map(d, "Bad", "key", "value", False)
        raise Error("an entry with an unknown child was read")
    except e:
        assert_true(String(e).find("neither its key nor") >= 0, String(e))
    try:
        _ = aws_xml_get_string_map(d, "NoValue", "key", "value", False)
        raise Error("an entry with no value was read")
    except e:
        assert_true(String(e).find("has no <value>") >= 0, String(e))
    # A map of structures, through the entry helpers.
    var entries = aws_xml_map_entries(d, "S", False).value().copy()
    assert_equal(len(entries), 1)
    assert_equal(aws_xml_entry_key(entries[0], "key", "value"), "s")
    var v = aws_xml_entry_value(entries[0], "key", "value")
    assert_equal(aws_xml_get_int(v, "N", 32).value(), Int64(9))


def test_read_attributes() raises:
    var d = _doc(
        '<G xmlns:x="http://www.w3.org/2001/XMLSchema-instance" '
        + 'x:type="Group" plain="p" />'
    )
    # [BC] a prefixed model name matches the local name in any namespace,
    # whatever prefix the document used; an unprefixed one, no namespace.
    assert_equal(aws_xml_get_attr(d, "xsi:type").value(), "Group")
    assert_false(Bool(aws_xml_get_attr(d, "type")))
    assert_equal(aws_xml_get_attr(d, "plain").value(), "p")
    assert_false(Bool(aws_xml_get_attr(d, "q:plain")))
    assert_false(Bool(aws_xml_get_attr(d, "missing")))


def test_parse_body() raises:
    # [BC] an empty body is an empty element: every member absent.
    var e = aws_xml_parse(List[UInt8]())
    assert_equal(e.local, "")
    assert_false(Bool(aws_xml_get_string(e, "Any")))
    # Not UTF-8, not XML: refused, quoting nothing of the body.
    var bad: List[UInt8] = [UInt8(0x3C), UInt8(0xFF), UInt8(0x3E)]
    try:
        _ = aws_xml_parse(bad)
        raise Error("an ill-formed body was parsed")
    except err:
        assert_true(String(err).find("UTF-8") >= 0, String(err))
    try:
        _ = aws_xml_parse(_bytes("<a><b></a>secret"))
        raise Error("a body that is not XML was parsed")
    except err:
        assert_true(String(err).find("not well-formed XML") >= 0, String(err))
        assert_equal(String(err).find("secret"), -1)


def test_round_trip() raises:
    # What the writers write, the readers read back.
    var z = Float64(0.0)
    var w = XmlWriter()
    aws_xml_start(w, "R")
    aws_xml_namespace(w, "", "urn:r")
    aws_xml_write_string(w, "S", " a <&> b ")
    aws_xml_write_int(w, "I", Int64(-2147483648))
    aws_xml_write_f64(w, "D", -0.125)
    aws_xml_write_f64(w, "Inf", Float64(1.0) / z)
    aws_xml_write_ts(w, "T", _INSTANT + 0.125, AWS_TS_ISO8601)
    var data: List[UInt8] = [UInt8(0), UInt8(0xFF), UInt8(0x10)]
    aws_xml_write_blob(w, "B", Span(data))
    aws_xml_write_bool(w, "Ok", True)
    aws_xml_end(w)
    var d = parse_xml(w.finish())
    assert_equal(d.ns, "urn:r")
    assert_equal(aws_xml_get_string(d, "S").value(), " a <&> b ")
    assert_equal(aws_xml_get_int(d, "I", 32).value(), Int64(-2147483648))
    assert_equal(aws_xml_get_f64(d, "D").value(), -0.125)
    assert_true(aws_xml_get_f64(d, "Inf").value() > 1.0e308)
    assert_equal(aws_xml_get_ts(d, "T", AWS_TS_ISO8601).value(), _INSTANT + 0.125)
    var b = aws_xml_get_blob(d, "B").value().copy()
    assert_equal(len(b), 3)
    assert_equal(b[1], UInt8(0xFF))
    assert_true(aws_xml_get_bool(d, "Ok").value())


def main() raises:
    test_write_scalars()
    test_write_special_floats()
    test_write_blob_and_timestamps()
    test_write_lists()
    test_write_maps()
    test_write_namespaces_and_attributes()
    test_write_refusals()
    test_set_body()
    test_read_scalars()
    test_read_refusals()
    test_read_structures()
    test_read_lists()
    test_read_maps()
    test_read_attributes()
    test_parse_body()
    test_round_trip()
    print("OK")
