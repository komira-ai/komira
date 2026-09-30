# =============================================================================
# xml_tree.mojo — an owned XML tree, plus a namespace-aware canonical form.
# =============================================================================
#
# The tree is what a DECODER wants: random access to a child by name, and the
# ability to ask "how many `<Contents>` children are there" without a second
# scan. It is built by ONE forward pass of `XmlReader`, so it costs one
# allocation per element rather than the O(fields x document) rescans the
# hand-written scanners pay.
#
# NAMESPACES ARE RESOLVED HERE, not in the reader. `xmlns` / `xmlns:p`
# attributes are consumed into a scope stack and every element and attribute
# gets its namespace URI recorded; the declarations themselves do not survive
# as attributes. That makes `canonical()` a genuine namespace-aware equality:
# two documents that differ only in prefix spelling canonicalise identically,
# and two that differ in the URI a name resolves to do not.
#
# `canonical()` is the ORACLE the rest-xml conformance harness compares with.
# It mirrors botocore's own comparison, which is
# `xml.etree.ElementTree.canonicalize(body, strip_text=True)` — see
# `_assert_xml_bodies` in botocore's protocol tests. Byte equality is the
# WRONG oracle for that corpus: the expected request bodies are pretty-printed
# with newlines and four-space indentation.
#
# Encapsulation: no `UnsafePointer` in any signature.
# =============================================================================

from .xml_escape import xml_escape_attr, xml_escape_text
from .xml_reader import (
    XML_END,
    XML_EOF,
    XML_START,
    XML_TEXT,
    XmlEvent,
    XmlReader,
)


struct XmlNode(Copyable, Movable):
    """One element: its resolved name, attributes, direct text and children."""

    var local: String
    var ns: String
    var attr_local: List[String]
    var attr_ns: List[String]
    var attr_value: List[String]
    var text: String
    var children: List[XmlNode]

    def __init__(out self):
        self.local = String("")
        self.ns = String("")
        self.attr_local = List[String]()
        self.attr_ns = List[String]()
        self.attr_value = List[String]()
        self.text = String("")
        self.children = List[XmlNode]()

    def copy(self) -> Self:
        var o = XmlNode()
        o.local = self.local.copy()
        o.ns = self.ns.copy()
        o.attr_local = self.attr_local.copy()
        o.attr_ns = self.attr_ns.copy()
        o.attr_value = self.attr_value.copy()
        o.text = self.text.copy()
        o.children = self.children.copy()
        return o^

    def child_count(self) -> Int:
        return len(self.children)

    def has_child(self, local: StringSlice) -> Bool:
        for i in range(len(self.children)):
            if self.children[i].local == local:
                return True
        return False

    def first_child(self, local: StringSlice) raises -> XmlNode:
        """The first direct child with this local name. Raises if absent —
        callers guard with `has_child`."""
        for i in range(len(self.children)):
            if self.children[i].local == local:
                return self.children[i].copy()
        raise Error("xml: no child <" + String(local) + ">")

    def attr(self, local: StringSlice) -> String:
        for i in range(len(self.attr_local)):
            if self.attr_local[i] == local:
                return self.attr_value[i]
        return String("")

    def has_attr(self, local: StringSlice) -> Bool:
        for i in range(len(self.attr_local)):
            if self.attr_local[i] == local:
                return True
        return False

    # PORT(1.0.0): explicit destructor breaks the non-co-inductive
    # Deinitable check on this struct's recursive self-reference.
    # Field destructors still run (verified); ownership unchanged.
    def __deinit__(deinit self):
        pass


def _strip(s: StringSlice) -> String:
    var b = s.as_bytes()
    var lo = 0
    var hi = len(b)
    while lo < hi and (
        b[lo] == 0x20 or b[lo] == 0x09 or b[lo] == 0x0A or b[lo] == 0x0D
    ):
        lo += 1
    while hi > lo and (
        b[hi - 1] == 0x20
        or b[hi - 1] == 0x09
        or b[hi - 1] == 0x0A
        or b[hi - 1] == 0x0D
    ):
        hi -= 1
    return String(unsafe_from_utf8=b[lo:hi])


def _local_of(qname: StringSlice) -> String:
    var b = qname.as_bytes()
    var lo = 0
    for i in range(len(b)):
        if b[i] == 0x3A:
            lo = i + 1
    return String(unsafe_from_utf8=b[lo:])


def _prefix_of(qname: StringSlice) -> String:
    var b = qname.as_bytes()
    for i in range(len(b)):
        if b[i] == 0x3A:
            return String(unsafe_from_utf8=b[0:i])
    return String("")


def parse_xml(doc: StringSlice) raises -> XmlNode:
    """Parse `doc` into a namespace-resolved tree. Raises on malformed input
    or on a document with no root element."""
    var rd = XmlReader.from_string(doc)
    # An explicit stack of (node, ns-scope-marker). Mojo has no recursion-free
    # tree builder in stdlib, so we keep partially-built nodes in a stack and
    # attach each to its parent on the matching END.
    var stack = List[XmlNode]()
    # Namespace scope: parallel lists of prefix -> uri, with a per-depth count
    # so a pop truncates exactly what this element declared.
    var ns_prefix = List[String]()
    var ns_uri = List[String]()
    var ns_mark = List[Int]()
    var root = XmlNode()
    var have_root = False

    while True:
        var ev = rd.next_event()
        if ev.kind == XML_EOF:
            break
        if ev.kind == XML_TEXT:
            if len(stack) > 0:
                stack[len(stack) - 1].text += rd.text_of(ev)
            continue
        if ev.kind == XML_START:
            ns_mark.append(len(ns_prefix))
            var node = XmlNode()
            # Pass 1: consume namespace declarations so a prefix declared on
            # THIS element is visible to its own name and attributes.
            for i in range(ev.attr_count):
                var an = rd.attr_name(i)
                if an == "xmlns":
                    ns_prefix.append(String(""))
                    ns_uri.append(rd.attr_value(i))
                elif an.startswith("xmlns:"):
                    ns_prefix.append(
                        String(unsafe_from_utf8=an.as_bytes()[6:])
                    )
                    ns_uri.append(rd.attr_value(i))
            # Pass 2: the ordinary attributes.
            for i in range(ev.attr_count):
                var an2 = rd.attr_name(i)
                if an2 == "xmlns" or an2.startswith("xmlns:"):
                    continue
                var pfx = _prefix_of(an2)
                node.attr_local.append(_local_of(an2))
                # An UNPREFIXED attribute is in NO namespace — the default
                # xmlns does not apply to attributes (Namespaces in XML §6.2).
                node.attr_ns.append(
                    _lookup_ns(ns_prefix, ns_uri, pfx) if pfx != "" else String("")
                )
                node.attr_value.append(rd.attr_value(i))
            var qn = rd.name_of(ev)
            node.local = _local_of(qn)
            node.ns = _lookup_ns(ns_prefix, ns_uri, _prefix_of(qn))
            stack.append(node^)
            continue
        # XML_END
        if len(stack) == 0:
            raise Error("xml: end tag with no open element")
        var done = stack.pop()
        var mark = ns_mark.pop()
        while len(ns_prefix) > mark:
            _ = ns_prefix.pop()
            _ = ns_uri.pop()
        if len(stack) == 0:
            if have_root:
                raise Error("xml: more than one root element")
            root = done^
            have_root = True
        else:
            stack[len(stack) - 1].children.append(done^)

    if len(stack) != 0:
        raise Error("xml: unterminated element")
    if not have_root:
        raise Error("xml: no root element")
    return root^


def _lookup_ns(
    prefixes: List[String], uris: List[String], pfx: StringSlice
) -> String:
    var i = len(prefixes) - 1
    while i >= 0:
        if prefixes[i] == pfx:
            return uris[i]
        i -= 1
    return String("")


def _qualified(ns: StringSlice, local: StringSlice) -> String:
    if ns.byte_length() == 0:
        return String(local)
    return String("{") + String(ns) + String("}") + String(local)


def _canon_into(node: XmlNode, mut out: String, depth: Int) raises:
    # A DEPTH BOUND, not decoration. `parse_xml` is iterative and will
    # happily build a 100k-deep tree from 100k bytes of `<a>`; a
    # recursive walk over it would exhaust the stack. Refusing is the
    # only safe answer for a codec fed untrusted network bodies.
    if depth > 512:
        raise Error("xml: element nesting deeper than 512")
    out += "<"
    out += _qualified(node.ns, node.local)
    # Attributes in a stable order: sorted by (namespace, local name).
    var order = List[Int]()
    for i in range(len(node.attr_local)):
        order.append(i)
    for a in range(len(order)):
        for b in range(a + 1, len(order)):
            var ka = _qualified(node.attr_ns[order[a]], node.attr_local[order[a]])
            var kb = _qualified(node.attr_ns[order[b]], node.attr_local[order[b]])
            if kb < ka:
                var t = order[a]
                order[a] = order[b]
                order[b] = t
    for k in range(len(order)):
        var i2 = order[k]
        out += " "
        out += _qualified(node.attr_ns[i2], node.attr_local[i2])
        out += '="'
        out += xml_escape_attr(node.attr_value[i2])
        out += '"'
    out += ">"
    out += xml_escape_text(_strip(node.text))
    _canon_children(node, out, depth)
    out += "</"
    out += _qualified(node.ns, node.local)
    out += ">"


def _canon_children(node: XmlNode, mut out: String, depth: Int) raises:
    """Split from `_canon_into` so the recursion is MUTUAL rather than direct
    — a directly self-recursive `def` trips a compiler warning here."""
    for c in range(len(node.children)):
        _canon_into(node.children[c], out, depth + 1)


def canonical_xml(doc: StringSlice) raises -> String:
    """`doc` in a namespace-resolved canonical form with text stripped.

    Mirrors botocore's own body comparison (`ET.canonicalize(strip_text=True)`),
    which is what makes the rest-xml corpus's pretty-printed expected bodies
    comparable to a compact serialiser's output.
    """
    var root = parse_xml(doc)
    var out = String()
    _canon_into(root, out, 0)
    return out^


def canonical_node(node: XmlNode) raises -> String:
    var out = String()
    _canon_into(node, out, 0)
    return out^
