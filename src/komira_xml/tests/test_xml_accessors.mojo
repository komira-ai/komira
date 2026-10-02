# =============================================================================
# test_xml_accessors.mojo — borrowed child lookup and the text accessors.
# =============================================================================
#
# A rest-xml response decoder walks the tree by name: S3's ListObjectsV2
# repeats `<Contents>` once per key, and STS nests the credentials three
# levels down. `first_child` returns a COPY of the whole subtree;
# `child_index` and `children_named` give positions to borrow through
# (`node.children[i]`), and `child_text` copies only the text.
# =============================================================================

from komira_xml import XML_MAX_DEPTH, XmlNode, parse_xml


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


comptime _LIST = """<?xml version="1.0" encoding="UTF-8"?>
<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Name>bucket</Name>
    <Contents>
        <Key>a.parquet</Key>
        <Size>10</Size>
    </Contents>
    <IsTruncated>false</IsTruncated>
    <Contents>
        <Key> spaced key </Key>
        <Size>20</Size>
    </Contents>
</ListBucketResult>
"""


def test_child() raises -> Int:
    var f = 0
    var t = parse_xml(_LIST)
    f += _eq(String(t.child_index("Name")), String("0"), "child_index by local name")
    f += _eq(String(t.child_index("Contents")), String("1"), "the FIRST match")
    f += _eq(String(t.child_index("Missing")), String("-1"), "absent is -1")
    f += _eq(
        t.children[t.child_index("Contents")].child_text("Key"),
        String("a.parquet"),
        "borrow by position, then child_text",
    )
    var raised = False
    try:
        _ = t.child_text("Missing")
    except e:
        raised = String(e).find("<Missing>") >= 0
    f += _true(raised, "child_text of an absent child raises, naming it")
    return f


def test_children_named() raises -> Int:
    var f = 0
    var t = parse_xml(_LIST)
    var at = t.children_named("Contents")
    f += _eq(String(len(at)), String("2"), "two <Contents>")
    f += _eq(String(at[0]) + "," + String(at[1]), String("1,3"), "their positions")
    f += _eq(
        t.children[at[1]].child_text("Key"),
        String(" spaced key "),
        "child_text keeps the text as written",
    )
    f += _eq(String(len(t.children_named("Nope"))), String("0"), "no match, empty")
    return f


def test_text_accessors() raises -> Int:
    var f = 0
    var t = parse_xml(_LIST)
    # `text` is every direct text run, so an element with children carries
    # the indentation between them.
    f += _true(t.text.byte_length() > 0, "an indented parent has whitespace text")
    f += _eq(t.trimmed_text(), String(""), "trimmed_text of an indented parent")
    ref second = t.children[t.children_named("Contents")[1]]
    var k = second.children[second.child_index("Key")].trimmed_text()
    f += _eq(k, String("spaced key"), "trimmed_text strips XML whitespace only")
    f += _eq(
        parse_xml(String("<a>\t\r\n x") + chr(0xA0) + "\n</a>").trimmed_text(),
        String("x") + chr(0xA0),
        "NBSP is not XML whitespace",
    )
    f += _eq(t.child_text("IsTruncated"), String("false"), "child_text")
    return f


def test_depth_constant() raises -> Int:
    return _true(XML_MAX_DEPTH == 512, "XML_MAX_DEPTH is the documented 512")


def main() raises:
    var failures = 0
    failures += test_child()
    failures += test_children_named()
    failures += test_text_accessors()
    failures += test_depth_constant()
    if failures != 0:
        raise Error(String(failures) + " xml accessor assertion(s) failed")
    print("OK — xml accessor tests pass")
