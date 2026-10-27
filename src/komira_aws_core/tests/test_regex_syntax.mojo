# =============================================================================
# komira_aws_core/tests/test_regex_syntax.mojo
# =============================================================================
#
# The regular-expression matcher (_regex.mojo) on the syntax the endpoint
# rules' tables do not use, each expected value Python `re.match`'s for the
# same pattern and input (ASCII classes, as the module header states), and
# each refusal the module header lists; then the partition table's load
# refusals (partitions.json version 1.1's shape).
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_aws_core import AwsPartitionSet
from komira_aws_core._regex import Regex


def _m(pattern: String, text: String) raises -> Bool:
    return Regex(pattern).matches(text)


def _refused(pattern: String, want: String) raises:
    try:
        _ = Regex(pattern)
    except e:
        assert_true(String(e).find(want) >= 0, String(e))
        return
    raise Error("regex not refused: " + pattern)


def test_space_and_negated_classes() raises:
    # \s is [ \t\n\v\f\r]: each of the six, and no other byte.
    for c in [0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D]:
        assert_true(_m("^\\s$", chr(c)), "\\s misses " + String(c))
    assert_false(_m("^\\s$", "a"))
    assert_false(_m("^\\s$", chr(0x08)))
    assert_false(_m("^\\s$", chr(0x0E)))
    # \D, \W, \S: the complement, at the atom level.
    assert_true(_m("^\\D$", "a"))
    assert_false(_m("^\\D$", "5"))
    assert_true(_m("^\\W$", "-"))
    assert_false(_m("^\\W$", "_"))
    assert_false(_m("^\\W$", "Z"))
    assert_true(_m("^\\S$", "x"))
    assert_false(_m("^\\S$", " "))
    assert_false(_m("^\\S$", "\t"))
    # \n \t \r stand for LF, TAB, CR.
    assert_true(_m("^a\\nb\\tc\\rd$", "a\nb\tc\rd"))
    assert_false(_m("^\\n$", "n"))
    assert_false(_m("^\\t$", "t"))
    assert_false(_m("^\\r$", "r"))


def test_class_escapes_and_ranges() raises:
    # A class escape inside a class adds its whole set.
    assert_true(_m("^[\\d.]+$", "1.25"))
    assert_false(_m("^[\\d.]+$", "1,25"))
    assert_true(_m("^[\\s,]+$", " ,\t"))
    assert_true(_m("^[\\D]$", "x"))
    assert_false(_m("^[\\D]$", "7"))
    # A range whose end is an escaped byte: [\--\/] is '-', '.', '/'.
    assert_true(_m("^[\\--\\/]+$", "-./"))
    assert_false(_m("^[\\--\\/]$", ","))
    assert_false(_m("^[\\--\\/]$", "0"))
    # A brace that is not a quantifier is a literal, as in Python.
    assert_true(_m("^a{x}$", "a{x}"))
    assert_true(_m("^a{2x$", "a{2x"))
    assert_true(_m("^a{2,x$", "a{2,x"))
    assert_false(_m("^a{2x$", "aa"))
    # The repeat cap is inclusive.
    assert_true(_m("^a{0,1000}$", "aaa"))


def test_refusals() raises:
    _refused("a{1001}", "a repeat count above 1000")
    _refused("a{0,1001}", "a repeat count above 1000")
    _refused("a\\", "a trailing backslash")
    _refused("[a\\", "a trailing backslash")
    _refused("\\q", "an unsupported escape")
    _refused("[\\q]", "an unsupported escape")
    _refused("\\" + chr(0xE9), "an unsupported escape")
    _refused("[[:alpha:]]", "a POSIX class")
    _refused("[[=a=]]", "a POSIX class")
    _refused("[[.a.]]", "a POSIX class")
    _refused("[a-\\d]", "a class escape as a range end")
    _refused("[z-a]", "a reversed range")
    _refused("[\\z-a]", "an unsupported escape")
    # '[' not before ':', '=' or '.' is a literal inside a class.
    assert_true(_m("^[[a]$", "["))
    assert_true(_m("^[[a]$", "a"))


def _part_refused(doc: String, want: String) raises:
    try:
        _ = AwsPartitionSet(doc)
    except e:
        assert_true(String(e).find(want) >= 0, String(e))
        return
    raise Error("partitions document accepted: " + doc)


comptime _P = (
    '{"id": "p", "regionRegex": "^x\\\\-\\\\d+$", "regions": {"named": {}},'
    ' "outputs": {"name": "ignored", "dnsSuffix": "example"}}'
)


def test_partition_table() raises:
    var t = AwsPartitionSet(
        '{"version": "1.1", "partitions": [' + _P + ', {"id": "q",'
        ' "regionRegex": "^q$", "regions": {}, "outputs": {}}]}'
    )
    assert_equal(t.__len__(), 2)
    var ids = t.partition_ids()
    assert_equal(len(ids), 2)
    assert_equal(ids[0], "p")
    assert_equal(ids[1], "q")
    assert_equal(t.lookup("q").get("name").as_string(), "q")
    assert_equal(t.lookup("x-1").get("name").as_string(), "p")
    _part_refused("[]", "partitions.json: the document is not an object")
    _part_refused('{"version": 1.1, "partitions": []}', "'version' has the wrong JSON kind")
    _part_refused('{"version": "1.1"}', "partitions.json: no 'partitions'")
    _part_refused(
        '{"version": "1.1", "partitions": [1]}',
        "partitions.json: partitions[0] is not an object",
    )
    _part_refused(
        '{"version": "1.1", "partitions": [' + _P + ', "x"]}',
        "partitions.json: partitions[1] is not an object",
    )
    _part_refused(
        '{"version": "1.1", "partitions": [{"id": "p", "regionRegex": "x",'
        ' "regions": [], "outputs": {}}]}',
        "partitions[0]: 'regions' has the wrong JSON kind",
    )
    _part_refused(
        '{"version": "1.1", "partitions": [{"id": "p", "regions": {},'
        ' "outputs": {}}]}',
        "partitions[0]: no 'regionRegex'",
    )
    _part_refused('{"version": "1.1", "partitions": []}', "partitions.json: no partitions")


def main() raises:
    var failed = 0
    try:
        test_space_and_negated_classes()
    except e:
        print("FAIL test_space_and_negated_classes:", e)
        failed += 1
    try:
        test_class_escapes_and_ranges()
    except e:
        print("FAIL test_class_escapes_and_ranges:", e)
        failed += 1
    try:
        test_refusals()
    except e:
        print("FAIL test_refusals:", e)
        failed += 1
    try:
        test_partition_table()
    except e:
        print("FAIL test_partition_table:", e)
        failed += 1
    if failed > 0:
        raise Error(String(failed) + " test(s) failed")
    print("OK")
