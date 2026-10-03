# =============================================================================
# test_xml_copy.mojo — an XmlNode survives being copied as a list element.
# =============================================================================
#
# Mojo 1.0.0 can treat a struct's synthesized copy constructor as trivial for
# some layouts of a struct with an explicit `__deinit__`; `List.copy()` then
# copies the elements with a memcpy, the copy shares its String and List
# buffers with the original, dropping the copy frees them under the original,
# and a same-size allocation reuses them. XmlNode has that shape (an explicit
# `__deinit__`, String and List fields, a `List[XmlNode]` of children), and a
# copy of a node copies its children through `List[XmlNode].copy()`.
#
# The layouts that corrupt on 1.0.0 have several Optional fields; XmlNode
# (String and List fields only) does not, and passes. The `copy()` method
# XmlNode defines does not protect it: where the synthesized constructor is
# trivial, `List.copy()` copies the elements without calling it. This test
# keeps that true across compiler versions.
#
# Every String below is longer than the inline capacity, so it owns a heap
# buffer. Each case: copy, drop the copy, allocate same-size Strings to reuse
# any freed buffer, then read the original back.
# =============================================================================

from komira_xml import XmlNode, parse_xml
from std.testing import assert_equal

comptime N = 8
comptime CHURN = 512


def pad(s: String) -> String:
    var out = s
    while out.byte_length() < 48:
        out += "."
    return out


def churn() -> List[String]:
    var out = List[String]()
    for i in range(CHURN):
        out.append(pad(String("CHURN") + String(i)))
    return out^


def leaf(tag: String, i: Int) -> XmlNode:
    var n = XmlNode()
    n.local = pad(tag + "-local-" + String(i))
    n.ns = pad(tag + "-ns-" + String(i))
    n.text = pad(tag + "-text-" + String(i))
    n.attr_local.append(pad(tag + "-al-" + String(i)))
    n.attr_ns.append(pad(tag + "-an-" + String(i)))
    n.attr_value.append(pad(tag + "-av-" + String(i)))
    return n^


def node(i: Int) -> XmlNode:
    var n = leaf(String("n"), i)
    n.children.append(leaf(String("c0"), i))
    n.children.append(leaf(String("c1"), i))
    n.children[1].children.append(leaf(String("g"), i))
    return n^


def check_leaf(n: XmlNode, tag: String, i: Int) raises:
    assert_equal(n.local, pad(tag + "-local-" + String(i)))
    assert_equal(n.ns, pad(tag + "-ns-" + String(i)))
    assert_equal(n.text, pad(tag + "-text-" + String(i)))
    assert_equal(len(n.attr_local), 1)
    assert_equal(n.attr_local[0], pad(tag + "-al-" + String(i)))
    assert_equal(n.attr_ns[0], pad(tag + "-an-" + String(i)))
    assert_equal(n.attr_value[0], pad(tag + "-av-" + String(i)))


def check_node(n: XmlNode, i: Int) raises:
    check_leaf(n, String("n"), i)
    assert_equal(len(n.children), 2)
    check_leaf(n.children[0], String("c0"), i)
    check_leaf(n.children[1], String("c1"), i)
    assert_equal(len(n.children[1].children), 1)
    check_leaf(n.children[1].children[0], String("g"), i)


def build() -> List[XmlNode]:
    var items = List[XmlNode]()
    for i in range(N):
        items.append(node(i))
    return items^


def drop_list_copy(items: List[XmlNode]):
    var a = items.copy()
    _ = a^


def test_list_copy() raises:
    var items = build()
    drop_list_copy(items)
    var junk = churn()
    for i in range(N):
        check_node(items[i], i)
    assert_equal(len(junk), CHURN)


def test_list_copy_ctor() raises:
    var items = build()
    var a = List[XmlNode](copy=items)
    _ = a^
    var junk = churn()
    for i in range(N):
        check_node(items[i], i)
    assert_equal(len(junk), CHURN)


def test_node_copy() raises:
    # A node's copy copies its children through `List[XmlNode].copy()`.
    var n = node(3)
    var c = n.copy()
    _ = c^
    var junk = churn()
    check_node(n, 3)
    assert_equal(len(junk), CHURN)


def test_node_copy_ctor() raises:
    var n = node(5)
    var c = XmlNode(copy=n)
    _ = c^
    var junk = churn()
    check_node(n, 5)
    assert_equal(len(junk), CHURN)


def test_parsed_first_child() raises:
    # `first_child` returns a copy of a parsed subtree.
    var long = pad(String("value"))
    var t = parse_xml(
        String("<r><k a=\"") + long + "\"><v>" + long + "</v><v>" + long
        + "</v></k></r>"
    )
    var c = t.first_child("k")
    _ = c^
    var junk = churn()
    ref k = t.children[0]
    assert_equal(k.attr("a"), long)
    assert_equal(len(k.children), 2)
    assert_equal(k.children[0].text, long)
    assert_equal(k.children[1].text, long)
    assert_equal(len(junk), CHURN)


def main() raises:
    test_list_copy()
    test_list_copy_ctor()
    test_node_copy()
    test_node_copy_ctor()
    test_parsed_first_child()
    print("OK — xml copy tests pass")
