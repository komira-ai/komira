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
# A document that is not namespace-well-formed (Namespaces in XML 1.0) is
# refused: a name with more than one colon or an empty part, a prefix that is
# not declared in scope, `xmlns:p=""`, a misuse of the reserved `xml` and
# `xmlns` prefixes or their namespace names, and two attributes with the same
# expanded name. The `xml` prefix is bound to its namespace without a
# declaration.
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
    XML_MAX_DEPTH,
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

    def child_index(self, local: StringSlice) -> Int:
        """The position in `children` of the first direct child with this
        local name, or -1. `node.children[node.child_index("Key")]` borrows
        that child where `first_child` copies it. (A method returning the
        reference itself cannot be written over a `List` field: the element
        origin it would need has no syntax.)"""
        for i in range(len(self.children)):
            if self.children[i].local == local:
                return i
        return -1

    def children_named(self, local: StringSlice) -> List[Int]:
        """The positions in `children` of every direct child with this local
        name, in document order. Empty when there is none."""
        var at = List[Int]()
        for i in range(len(self.children)):
            if self.children[i].local == local:
                at.append(i)
        return at^

    def child_text(self, local: StringSlice) raises -> String:
        """The direct text of the first child with this local name, as
        written; only that string is copied. Raises if there is no such
        child, naming it."""
        var i = self.child_index(local)
        if i < 0:
            raise Error("xml: no child <" + String(local) + ">")
        return self.children[i].text.copy()

    def trimmed_text(self) -> String:
        """`text` without leading and trailing XML whitespace (SP, TAB, CR,
        LF). `text` itself is every direct text run, as written, so an
        element with indented children carries the indentation."""
        return _strip(self.text)

    def first_child(self, local: StringSlice) raises -> XmlNode:
        """A COPY of the first direct child with this local name, subtree
        included. Raises if absent. `child_index` gives a position to borrow
        through instead."""
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


def parse_xml(doc: StringSlice) raises -> XmlNode:
    """Parse `doc` into a namespace-resolved tree. Raises on any input that
    is not a well-formed (XML 1.0) and namespace-well-formed document, and on
    any DTD; see `xml_reader.mojo` for the list."""
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
                    var du = rd.attr_value(i)
                    if du == _XML_NS or du == _XMLNS_NS:
                        raise Error(
                            "xml: the default namespace cannot be the xml or "
                            + "xmlns namespace name"
                        )
                    ns_prefix.append(String(""))
                    ns_uri.append(du^)
                elif an.startswith("xmlns:"):
                    var p = _split_qname(an)[1]
                    var u = rd.attr_value(i)
                    _check_binding(p, u)
                    ns_prefix.append(p^)
                    ns_uri.append(u^)
            # Pass 2: the ordinary attributes.
            for i in range(ev.attr_count):
                var an2 = rd.attr_name(i)
                if an2 == "xmlns" or an2.startswith("xmlns:"):
                    continue
                var parts = _split_qname(an2)
                # An UNPREFIXED attribute is in NO namespace — the default
                # xmlns does not apply to attributes (Namespaces in XML §6.2).
                var ans = String("")
                if parts[0] != "":
                    ans = _resolve(ns_prefix, ns_uri, parts[0])
                # §6.3: no two attributes with the same expanded name.
                for k in range(len(node.attr_local)):
                    if node.attr_local[k] == parts[1] and node.attr_ns[k] == ans:
                        raise Error(
                            "xml: duplicate attribute "
                            + _qualified(ans, parts[1]) + " after namespace "
                            + "resolution"
                        )
                node.attr_local.append(parts[1])
                node.attr_ns.append(ans^)
                node.attr_value.append(rd.attr_value(i))
            var qn = rd.name_of(ev)
            var eparts = _split_qname(qn)
            if eparts[0] == "xmlns":
                raise Error("xml: element <" + qn + "> uses the reserved xmlns prefix")
            node.local = eparts[1]
            node.ns = _resolve(ns_prefix, ns_uri, eparts[0])
            stack.append(node^)
            continue
        # XML_END
        if len(stack) == 0:
            raise Error("xml: end tag with no open element")  # cov: unreachable reader ENDs only what it opened
        var done = stack.pop()
        var mark = ns_mark.pop()
        while len(ns_prefix) > mark:
            _ = ns_prefix.pop()
            _ = ns_uri.pop()
        if len(stack) == 0:
            if have_root:
                raise Error("xml: more than one root element")  # cov: unreachable reader refuses a 2nd root
            root = done^
            have_root = True
        else:
            stack[len(stack) - 1].children.append(done^)

    if len(stack) != 0:
        raise Error("xml: unterminated element")  # cov: unreachable reader raises first
    if not have_root:
        raise Error("xml: no root element")  # cov: unreachable reader raises first
    return root^


comptime _XML_NS = "http://www.w3.org/XML/1998/namespace"
comptime _XMLNS_NS = "http://www.w3.org/2000/xmlns/"


def _split_qname(qname: StringSlice) raises -> Tuple[String, String]:
    """(prefix, local) of a Namespaces in XML [7] QName: at most one colon,
    and never an empty part."""
    var b = qname.as_bytes()
    var colon = -1
    for i in range(len(b)):
        if b[i] == 0x3A:
            if colon >= 0:
                raise Error("xml: name '" + String(qname) + "' has more than one colon")
            colon = i
    if colon < 0:
        return (String(""), String(qname))
    if colon == 0 or colon == len(b) - 1:
        raise Error("xml: name '" + String(qname) + "' has an empty prefix or local part")
    return (
        String(unsafe_from_utf8=b[0:colon]),
        String(unsafe_from_utf8=b[colon + 1 :]),
    )


def _check_binding(prefix: StringSlice, uri: StringSlice) raises:
    """Namespaces in XML 1.0 §3 and [NSC: No Prefix Undeclaring]."""
    if prefix == "xmlns":
        raise Error("xml: the xmlns prefix cannot be declared")
    if prefix == "xml":
        if String(uri) != _XML_NS:
            raise Error("xml: the xml prefix can only be bound to " + _XML_NS)
        return
    if String(uri) == _XML_NS:
        raise Error("xml: only the xml prefix can be bound to " + _XML_NS)
    if String(uri) == _XMLNS_NS:
        raise Error("xml: no prefix can be bound to the xmlns namespace name")
    if uri.byte_length() == 0:
        raise Error(
            "xml: xmlns:" + String(prefix) + " has an empty value; Namespaces "
            + "in XML 1.0 cannot undeclare a prefix"
        )


def _resolve(
    prefixes: List[String], uris: List[String], pfx: StringSlice
) raises -> String:
    """The namespace name `pfx` is bound to in scope. The empty prefix is the
    default namespace, or none; any other prefix must be declared."""
    var i = len(prefixes) - 1
    while i >= 0:
        if prefixes[i] == pfx:
            return uris[i]
        i -= 1
    if pfx.byte_length() == 0:
        return String("")
    if pfx == "xml":
        return String(_XML_NS)
    raise Error("xml: undeclared namespace prefix '" + String(pfx) + "'")


def _qualified(ns: StringSlice, local: StringSlice) -> String:
    if ns.byte_length() == 0:
        return String(local)
    return String("{") + String(ns) + String("}") + String(local)


def _canon_into(node: XmlNode, mut out: String, depth: Int) raises:
    # A DEPTH BOUND, not decoration. `parse_xml` is iterative and will
    # happily build a 100k-deep tree from 100k bytes of `<a>`; a
    # recursive walk over it would exhaust the stack. Refusing is the
    # only safe answer for a codec fed untrusted network bodies.
    if depth > XML_MAX_DEPTH:
        raise Error("xml: element nesting deeper than " + String(XML_MAX_DEPTH))
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
