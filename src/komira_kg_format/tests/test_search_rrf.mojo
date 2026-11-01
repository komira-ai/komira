# =============================================================================
# test_search_rrf.mojo -- reciprocal-rank fusion of two ranked lists (pure
#   arithmetic; no store, no clock).
# =============================================================================
#
#   scores     on stated ranks each id scores the sum of 1 / (k_const + rank) over
#              the lists it is in, and the result is ordered by that score.
#   rank       only the position in a list counts; the Hit.score fed in is ignored.
#   ties       equal fused scores order by lower id first, whichever list an id is
#              in and whichever order the lists are given in.
#   shapes     an empty list, two empty lists, identical lists, disjoint lists
#              and an id repeated inside one list.
#   k_const    zero is allowed; negative, NaN and infinite are refused.
# =============================================================================

from std.math import inf, nan
from std.testing import TestSuite, assert_equal, assert_raises, assert_true

from komira_kg_format import Hit, rrf_fuse


def _list(ids: List[Int]) -> List[Hit]:
    """Hits in the order given, with scores that disagree with that order."""
    var out = List[Hit]()
    for i in range(len(ids)):
        out.append(Hit(ids[i], Float64(i)))
    return out^


def _close(a: Float64, b: Float64) -> Bool:
    return abs(a - b) < 1.0e-15


def test_fusion_on_stated_ranks() raises:
    var a = _list([10, 20, 30])
    var b = _list([20, 40, 10])
    var fused = rrf_fuse(a, b, 60.0)
    assert_equal(len(fused), 4)
    # 20: rank 2 and rank 1; 10: rank 1 and rank 3; 40: rank 2 of b; 30: rank 3 of a.
    assert_equal(fused[0].row, 20)
    assert_equal(fused[1].row, 10)
    assert_equal(fused[2].row, 40)
    assert_equal(fused[3].row, 30)
    assert_true(_close(fused[0].score, 1.0 / 62.0 + 1.0 / 61.0))
    assert_true(_close(fused[1].score, 1.0 / 61.0 + 1.0 / 63.0))
    assert_true(_close(fused[2].score, 1.0 / 62.0))
    assert_true(_close(fused[3].score, 1.0 / 63.0))


def test_the_constant_changes_the_scores_and_can_change_the_order() raises:
    # 1 and 3 are first in one list each; 2 and 9 are in both, at ranks 3 and 2.
    var a = _list([1, 9, 2])
    var b = _list([3, 2, 9])
    var flat = rrf_fuse(a, b, 0.0)  # 1/rank: the two firsts score 1.0 each
    assert_equal(flat[0].row, 1)
    assert_equal(flat[1].row, 3)
    assert_equal(flat[2].row, 2)
    assert_equal(flat[3].row, 9)
    assert_true(_close(flat[0].score, 1.0))
    assert_true(_close(flat[2].score, 0.5 + 1.0 / 3.0))
    # A large constant flattens the ranks, so being in both lists wins.
    var damped = rrf_fuse(a, b, 60.0)
    assert_equal(damped[0].row, 2)
    assert_equal(damped[1].row, 9)
    assert_equal(damped[2].row, 1)
    assert_equal(damped[3].row, 3)
    assert_true(_close(damped[0].score, 1.0 / 63.0 + 1.0 / 62.0))


def test_the_input_scores_are_ignored() raises:
    var a = List[Hit]()
    a.append(Hit(7, -5.0))
    a.append(Hit(8, 1000.0))
    var fused = rrf_fuse(a, List[Hit](), 60.0)
    assert_equal(fused[0].row, 7)
    assert_equal(fused[1].row, 8)
    assert_true(_close(fused[0].score, 1.0 / 61.0))
    assert_true(_close(fused[1].score, 1.0 / 62.0))


def test_ties_order_by_lower_id() raises:
    # 3 and 5 hold swapped ranks: the same two shares, so the same fused score.
    var swapped = rrf_fuse(_list([5, 3]), _list([3, 5]), 60.0)
    assert_equal(swapped[0].row, 3)
    assert_equal(swapped[1].row, 5)
    assert_equal(swapped[0].score, swapped[1].score)
    # The same with the lists given the other way round.
    var other = rrf_fuse(_list([3, 5]), _list([5, 3]), 60.0)
    assert_equal(other[0].row, 3)
    assert_equal(other[1].row, 5)
    # First of each list: one share each, 7 is in the first list and 2 in the second.
    var firsts = rrf_fuse(_list([7]), _list([2]), 60.0)
    assert_equal(firsts[0].row, 2)
    assert_equal(firsts[1].row, 7)
    assert_equal(firsts[0].score, firsts[1].score)


def test_many_ties_come_back_in_id_order() raises:
    var fused = rrf_fuse(_list([9, 4, 6]), _list([6, 9, 4]), 60.0)
    # 9: ranks 1 and 2; 6: ranks 3 and 1; 4: ranks 2 and 3 -> 9 beats 6 beats 4.
    assert_equal(fused[0].row, 9)
    assert_equal(fused[1].row, 6)
    assert_equal(fused[2].row, 4)
    var tied = rrf_fuse(_list([30, 10, 20]), List[Hit](), 60.0)
    assert_equal(tied[0].row, 30)  # distinct ranks: rank order, not id order
    assert_equal(tied[1].row, 10)
    assert_equal(tied[2].row, 20)


def test_empty_lists() raises:
    assert_equal(len(rrf_fuse(List[Hit](), List[Hit](), 60.0)), 0)
    var only_b = rrf_fuse(List[Hit](), _list([4, 2]), 60.0)
    assert_equal(len(only_b), 2)
    assert_equal(only_b[0].row, 4)
    assert_equal(only_b[1].row, 2)


def test_identical_and_disjoint_lists() raises:
    var same = rrf_fuse(_list([1, 2, 3]), _list([1, 2, 3]), 60.0)
    assert_equal(len(same), 3)
    assert_equal(same[0].row, 1)
    assert_true(_close(same[0].score, 2.0 / 61.0))
    var disjoint = rrf_fuse(_list([1, 2]), _list([3, 4]), 60.0)
    assert_equal(len(disjoint), 4)
    assert_equal(disjoint[0].row, 1)  # tie with 3 on one share: lower id first
    assert_equal(disjoint[1].row, 3)
    assert_equal(disjoint[2].row, 2)
    assert_equal(disjoint[3].row, 4)


def test_an_id_repeated_in_one_list_counts_at_each_position() raises:
    var fused = rrf_fuse(_list([1, 2, 1]), List[Hit](), 60.0)
    assert_equal(len(fused), 2)
    assert_equal(fused[0].row, 1)
    assert_true(_close(fused[0].score, 1.0 / 61.0 + 1.0 / 63.0))
    assert_equal(fused[1].row, 2)


def test_a_bad_constant_is_refused() raises:
    var a = _list([1])
    with assert_raises(contains="k_const"):
        _ = rrf_fuse(a, a, -1.0)
    with assert_raises(contains="k_const"):
        _ = rrf_fuse(a, a, -0.5)
    with assert_raises(contains="k_const"):
        _ = rrf_fuse(a, a, nan[DType.float64]())
    with assert_raises(contains="k_const"):
        _ = rrf_fuse(a, a, inf[DType.float64]())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
