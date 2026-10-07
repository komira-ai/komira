# Test 47: some arms of classify_score, never "invalid" (its counter stays
# 0 in the profile of the branch coverage run), and of the decisions of
# shapes.mojo, both arms of strings.mojo's `first`, the loops of loops.mojo
# (each a known number of iterations and ends), a Dict subscript that finds
# its key and one that raises, and mask.mojo's `if`s, never true.
from branchlib import (
    any_positive,
    classify_score,
    first,
    letters,
    lookup,
    roomy,
    shapes,
    total,
)
from std.testing import assert_equal


def main() raises:
    assert_equal(classify_score(95, True), "top", "top")
    assert_equal(classify_score(95, False), "high", "high")
    assert_equal(classify_score(50, False), "pass", "pass")
    assert_equal(classify_score(70, True), "pass", "pass with bonus")
    assert_equal(shapes(3, True), 3 + 1 + 3, "three turns, flag, pick 3")
    assert_equal(shapes(0, False), 0 + 2 + 4, "no turn, no flag, pick 4")
    assert_equal(any_positive(0, 0, 1), 1, "the last decides")
    assert_equal(any_positive(1, 0, 0), 1, "the first decides")
    assert_equal(first(String("abc"), True), 1, "the flag returns 1")
    assert_equal(first(String("abcd"), False), 4, "no flag: the length")
    assert_equal(total([1, 2, 3]), 6, "three iterations, one end")
    assert_equal(total(List[Int]()), 0, "no iteration, one end")
    assert_equal(letters(), 4, "two iterations, one end")
    var d = Dict[String, Int]()
    d["a"] = 7
    assert_equal(lookup(d, "a"), 7, "the key is there")
    var raised = False
    try:
        _ = lookup(d, "b")
    except:
        raised = True
    assert_equal(raised, True, "a missing key raises")
    assert_equal(roomy(List[Int](), List[Int](), 5), 5, "no capacity has bit 62")
