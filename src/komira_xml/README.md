# komira_xml

An XML 1.0 codec with no dependencies, in four layers: `parse_xml` builds an
owned tree of `XmlNode`s with namespace-resolved names; `XmlReader` is a
forward-only pull parser for documents you would rather not hold in memory;
`XmlWriter` streams a document into a buffer, escaping as it goes; and the
escape functions (`xml_escape_text`, `xml_escape_attr`, `xml_unescape`) stand
alone. Input is read strictly: a document that is not well-formed (or not
namespace-well-formed) is refused, and so is every DTD, so no entity beyond the
five predefined ones is ever expanded.

## Examples

Parse a document and read it as a tree:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_xml import parse_xml

var root = parse_xml("""<order id="7">
  <item sku="a1">pen</item>
  <item sku="b2">ink &amp; nib</item>
  <note>gift</note>
</order>""")
assert_equal(root.local, "order")
assert_equal(root.attr("id"), "7")
assert_equal(root.child_text("note"), "gift")
var items = root.children_named("item")
assert_equal(len(items), 2)
assert_equal(root.children[items[1]].text, "ink & nib")
assert_equal(root.children[items[1]].attr("sku"), "b2")
```

Write a document; text and attribute values are escaped, and an empty element
closes as `<x/>`:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_xml import XmlWriter

var w = XmlWriter()
w.start_element("greeting")
w.attr("lang", 'say "hi"')
w.text("fish & chips")
w.start_element("br")
w.end_element()
w.end_element()
assert_equal(w.finish(), '<greeting lang="say &quot;hi&quot;">fish &amp; chips<br/></greeting>')
```

Pull events one at a time:

<!-- mojo-hidden from std.testing import assert_equal -->
```mojo
from komira_xml import XML_END, XML_EOF, XML_START, XML_TEXT, XmlReader

var reader = XmlReader.from_string("<a><b>hi</b></a>")
var seen = String()
while True:
    var ev = reader.next_event()
    if ev.kind == XML_EOF:
        break
    elif ev.kind == XML_START:
        seen += "<" + reader.name_of(ev) + ">"
    elif ev.kind == XML_END:
        seen += "</" + reader.name_of(ev) + ">"
    elif ev.kind == XML_TEXT:
        seen += "[" + reader.text_of(ev) + "]"
assert_equal(seen, "<a><b>[hi]</b></a>")
```

A DTD is refused, never processed:

<!-- mojo-hidden from std.testing import assert_true -->
```mojo
from komira_xml import parse_xml

var message = String()
try:
    _ = parse_xml('<!DOCTYPE a [<!ENTITY x "boom">]><a>&x;</a>')
except e:
    message = String(e)
assert_true(message.startswith("xml: DTD refused"))
```
