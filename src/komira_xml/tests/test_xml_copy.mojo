# =============================================================================
# test_xml_copy.mojo — an XmlNode survives being copied as a list element.
# =============================================================================
#
# Measured on Mojo 1.0.0: for some structs with an explicit `__deinit__`,
# `List.copy()` copies the elements without running a deep copy, so the copy
# shares its heap buffers with the original; dropping the copy frees them
# under the original, and a later same-size allocation reuses them. Throwaway
# structs whose fields were all Optional (three `Optional[String]` and one
# `Optional[Bool]`) corrupted that way, as a flat list and when the list was
# a field copied along with its owner. A user `copy()` method did not prevent
# it; an explicit `__init__(out self, *, copy: Self)` did. The same Optional
# fields next to a String, a List[String] or a `List[Self]` did not corrupt,
# and neither did XmlNode with those fields added. Which feature of a layout
# decides it is not known, which is why this test exists.
#
# XmlNode has an explicit `__deinit__`, String and List fields and a
# `List[XmlNode]` of children, and a copy of a node copies its children
# through `List[XmlNode].copy()`. It passes today. No XmlNode-shaped type has
# been made to fail here, so the cases are guards against a compiler change,
# not reproductions.
#
# Every String below is longer than the inline capacity, so it owns a heap
# buffer. Each case: copy, drop the copy, allocate Strings of several widths
# to reuse any freed buffer, then read the original back. Failures are
# counted so one corrupted field does not hide the other cases.
# =============================================================================

from komira_xml import XmlNode, parse_xml

comptime _N = 8
comptime _CHURN = 512


def _eq(got: String, want: String, what: String) -> Int:
    if got != want:
        print("FAIL " + what + "\n  got : " + got + "\n  want: " + want)
        return 1
    return 0


def _len(got: Int, want: Int, what: String) -> Int:
    if got != want:
        print("FAIL " + what + ": len " + String(got) + ", want " + String(want))
        return 1
    return 0


def _pad(s: String, width: Int = 48) -> String:
    var out = s
    while out.byte_length() < width:
        out += "."
    return out


def _churn() -> List[String]:
    # Several widths, so a freed buffer is reused whichever allocator size
    # class it falls in (a parsed String's capacity need not match `_pad`'s).
    var widths: List[Int] = [48, 64, 96, 128]
    var out = List[String]()
    for i in range(_CHURN):
        out.append(_pad(String("CHURN") + String(i), widths[i % 4]))
    return out^


def _leaf(tag: String, i: Int) -> XmlNode:
    var n = XmlNode()
    n.local = _pad(tag + "-local-" + String(i))
    n.ns = _pad(tag + "-ns-" + String(i))
    n.text = _pad(tag + "-text-" + String(i))
    n.attr_local.append(_pad(tag + "-al-" + String(i)))
    n.attr_ns.append(_pad(tag + "-an-" + String(i)))
    n.attr_value.append(_pad(tag + "-av-" + String(i)))
    return n^


def _node(i: Int) -> XmlNode:
    var n = _leaf(String("n"), i)
    n.children.append(_leaf(String("c0"), i))
    n.children.append(_leaf(String("c1"), i))
    n.children[1].children.append(_leaf(String("g"), i))
    return n^


def _check_leaf(n: XmlNode, tag: String, i: Int, what: String) -> Int:
    var w = what + " " + tag + String(i)
    var f = 0
    f += _eq(n.local, _pad(tag + "-local-" + String(i)), w + " local")
    f += _eq(n.ns, _pad(tag + "-ns-" + String(i)), w + " ns")
    f += _eq(n.text, _pad(tag + "-text-" + String(i)), w + " text")
    var lens = 0
    lens += _len(len(n.attr_local), 1, w + " attr_local")
    lens += _len(len(n.attr_ns), 1, w + " attr_ns")
    lens += _len(len(n.attr_value), 1, w + " attr_value")
    if lens != 0:
        return f + lens
    f += _eq(n.attr_local[0], _pad(tag + "-al-" + String(i)), w + " attr_local")
    f += _eq(n.attr_ns[0], _pad(tag + "-an-" + String(i)), w + " attr_ns")
    f += _eq(n.attr_value[0], _pad(tag + "-av-" + String(i)), w + " attr_value")
    return f


def _check_node(n: XmlNode, i: Int, what: String) -> Int:
    var f = _check_leaf(n, String("n"), i, what)
    if _len(len(n.children), 2, what + " children") != 0:
        return f + 1
    f += _check_leaf(n.children[0], String("c0"), i, what)
    f += _check_leaf(n.children[1], String("c1"), i, what)
    if _len(len(n.children[1].children), 1, what + " grandchildren") != 0:
        return f + 1
    f += _check_leaf(n.children[1].children[0], String("g"), i, what)
    return f


def _build() -> List[XmlNode]:
    var items = List[XmlNode]()
    for i in range(_N):
        items.append(_node(i))
    return items^


def test_list_copy() -> Int:
    var items = _build()
    var a = items.copy()
    _ = a^
    var junk = _churn()
    var f = _len(len(junk), _CHURN, "churn")
    for i in range(_N):
        f += _check_node(items[i], i, "List.copy()")
    return f


def test_list_copy_ctor() -> Int:
    var items = _build()
    var a = List[XmlNode](copy=items)
    _ = a^
    var junk = _churn()
    var f = _len(len(junk), _CHURN, "churn")
    for i in range(_N):
        f += _check_node(items[i], i, "List(copy=)")
    return f


def test_node_copy() -> Int:
    # A node's copy copies its children through `List[XmlNode].copy()`.
    var n = _node(3)
    var c = n.copy()
    _ = c^
    var junk = _churn()
    return _len(len(junk), _CHURN, "churn") + _check_node(n, 3, "copy()")


def test_node_copy_ctor() -> Int:
    var n = _node(5)
    var c = XmlNode(copy=n)
    _ = c^
    var junk = _churn()
    return _len(len(junk), _CHURN, "churn") + _check_node(n, 5, "XmlNode(copy=)")


def test_parsed_first_child() raises -> Int:
    # `first_child` returns a copy of a parsed subtree.
    var long = _pad(String("value"))
    var t = parse_xml(
        String("<r><k a=\"") + long + "\"><v>" + long + "</v><v>" + long
        + "</v></k></r>"
    )
    var c = t.first_child("k")
    _ = c^
    var junk = _churn()
    var f = _len(len(junk), _CHURN, "churn")
    if _len(len(t.children), 1, "parsed root children") != 0:
        return f + 1
    ref k = t.children[0]
    f += _eq(k.attr("a"), long, "parsed attr")
    if _len(len(k.children), 2, "parsed k children") != 0:
        return f + 1
    f += _eq(k.children[0].text, long, "parsed text 0")
    f += _eq(k.children[1].text, long, "parsed text 1")
    return f


def main() raises:
    var failures = 0
    failures += test_list_copy()
    failures += test_list_copy_ctor()
    failures += test_node_copy()
    failures += test_node_copy_ctor()
    failures += test_parsed_first_child()
    if failures != 0:
        raise Error(String(failures) + " xml copy assertion(s) failed")
    print("OK — xml copy tests pass")
