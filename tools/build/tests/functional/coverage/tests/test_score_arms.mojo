# Test 47: some arms of classify_score, never "invalid" (its counter stays
# 0 in the profile of the branch coverage run), and of the decisions of
# shapes.mojo.
from branchlib import any_positive, classify_score, shapes
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
