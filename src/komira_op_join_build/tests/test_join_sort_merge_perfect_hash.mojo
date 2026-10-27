# =============================================================================
# test_join_sort_merge_perfect_hash -- the sort-merge INNER join, the
# perfect-hash join and the CROSS join's index pairs, against hand oracles
# =============================================================================
#
# What each test catches:
#   * `test_sort_merge_runs_and_nulls`: a run of equal keys on both sides must
#     emit the full cross product of the two runs; a NULL key (whose value is
#     the DType zero) must match nothing, not the real key 0 on the other side.
#   * `test_perfect_hash_declines`: the table refuses an empty build, a build
#     with a NULL key, duplicate keys and a key range above the cap, so the
#     caller falls back to the chained build.
#   * `test_perfect_hash_probe_skips_null_probe_keys`: an unguarded probe maps
#     a NULL probe row onto slot `0 - min_key` and emits a wrong extra row.
#   * `test_cross_join_indices`: the M x N pairs, row-major.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_build.join_perfect_hash import PERFECT_RANGE_CAP, PerfectHashJoin
from komira_op_join_build.join_sort_merge import (
    cross_join_indices,
    sort_merge_join_inner,
    sort_merge_join_inner_into,
)


def _keys(values: List[Int]) -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate(len(values))
    for i in range(len(values)):
        arr.store[1](i, SIMD[DType.int64, 1](Int64(values[i])))
    return arr^


def _nullable_keys(
    values: List[Int], nulls: List[Bool]
) raises -> PrimitiveArray[DType.int64]:
    var arr = PrimitiveArray[DType.int64].allocate_nullable(len(values))
    for i in range(len(values)):
        arr.set(i, Int64(values[i]))
        if nulls[i]:
            arr._set_null(i)
    return arr^


def test_sort_merge_runs_and_nulls() raises:
    # Left [0, 1, 3, 3], right [0, 3, 3, 3, 5]: key 0 once each, key 3 a 2x3 run.
    var res = sort_merge_join_inner(_keys([0, 1, 3, 3]), _keys([0, 3, 3, 3, 5]))
    var lm = res[0].copy()
    var rm = res[1].copy()
    assert_equal(len(lm), 1 + 2 * 3)
    var want_l: List[Int] = [0, 2, 2, 2, 3, 3, 3]
    var want_r: List[Int] = [0, 1, 2, 3, 1, 2, 3]
    for i in range(len(want_l)):
        assert_equal(lm[i], want_l[i], "left " + String(i))
        assert_equal(rm[i], want_r[i], "right " + String(i))

    # The same keys with left row 0 and right row 0 NULL (value bits 0): the
    # key-0 pair disappears, the run of 3s is untouched.
    var lnull: List[Bool] = [True, False, False, False]
    var rnull: List[Bool] = [True, False, False, False, False]
    var lm2 = List[Int]()
    var rm2 = List[Int]()
    sort_merge_join_inner_into(
        _keys([0, 1, 3, 3]), _keys([0, 3, 3, 3, 5]), lm2, rm2, lnull^, rnull^
    )
    assert_equal(len(lm2), 6, "NULL never matches, not even NULL")
    for i in range(6):
        assert_equal(lm2[i], want_l[i + 1])
        assert_equal(rm2[i], want_r[i + 1])


def test_perfect_hash_declines() raises:
    assert_true(not PerfectHashJoin.try_build(_keys(List[Int]())), "empty")
    var nk = _nullable_keys([1, 2, 3], [False, True, False])
    assert_true(not PerfectHashJoin.try_build(nk), "a NULL build key")
    assert_true(not PerfectHashJoin.try_build(_keys([4, 5, 4])), "duplicates")
    assert_true(
        not PerfectHashJoin.try_build(_keys([0, PERFECT_RANGE_CAP])),
        "range above the cap",
    )
    assert_true(
        Bool(PerfectHashJoin.try_build(_keys([0, PERFECT_RANGE_CAP - 1]))),
        "range exactly at the cap",
    )


def test_perfect_hash_probe_skips_null_probe_keys() raises:
    # Build keys -2..2 (min_key -2): build row 2 holds key 0.
    var opt = PerfectHashJoin.try_build(_keys([-2, -1, 0, 1, 2]))
    assert_true(Bool(opt))
    var t = opt.take()
    var pk = _nullable_keys([0, 7, 2, 0], [False, False, False, True])
    var res = t.probe_inner(pk)
    var bm = res[0].copy()
    var pm = res[1].copy()
    assert_equal(len(bm), 2, "probe 0 -> build 2, probe 2 -> build 4; NULL none")
    assert_equal(bm[0], 2)
    assert_equal(pm[0], 0)
    assert_equal(bm[1], 4)
    assert_equal(pm[1], 2)


def test_cross_join_indices() raises:
    var res = cross_join_indices(2, 3)
    var l = res[0].copy()
    var r = res[1].copy()
    assert_equal(len(l), 6)
    var want_l: List[Int] = [0, 0, 0, 1, 1, 1]
    var want_r: List[Int] = [0, 1, 2, 0, 1, 2]
    for i in range(6):
        assert_equal(l[i], want_l[i])
        assert_equal(r[i], want_r[i])
    var empty = cross_join_indices(0, 5)
    assert_equal(len(empty[0]), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
