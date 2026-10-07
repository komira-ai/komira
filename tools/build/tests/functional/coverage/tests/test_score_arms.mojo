# Test 47: some arms of classify_score, never "invalid" (its counter stays
# 0 in the profile of the branch coverage run).
from branchlib import classify_score
from std.testing import assert_equal


def main() raises:
    assert_equal(classify_score(95, True), "top", "top")
    assert_equal(classify_score(95, False), "high", "high")
    assert_equal(classify_score(50, False), "pass", "pass")
    assert_equal(classify_score(70, True), "pass", "pass with bonus")
