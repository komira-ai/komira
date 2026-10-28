# =============================================================================
# test_morsel_join_ported -- inner, semi and anti joins through
# `HashJoinBuilder` over dimension-and-fact shaped fixtures: build is the
# dimension table, probe the fact table, and SEMI / ANTI return PROBE rows.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_build.join import HashJoinBuilder


def _make_int64_arr(values: List[Int]) -> PrimitiveArray[DType.int64]:
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = Scalar[DType.int64](values[i])
    return arr^


def _contains(values: List[Int], target: Int) -> Bool:
    for i in range(len(values)):
        if values[i] == target:
            return True
    return False


# -----------------------------------------------------------------------------
# Port: test_left_join -- every probe row must appear, with -1 for non-matches.
# -----------------------------------------------------------------------------


def test_left_join_matched_and_unmatched() raises:
    """Left join: every probe row appears at least once. Build=[1,2,3],
    Probe=[1,5,2,6] -> 4 output rows (2 matched, 2 unmatched)."""
    var build_vals: List[Int] = [1, 2, 3]
    var probe_vals: List[Int] = [1, 5, 2, 6]
    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)
    var result = builder.probe_left(probe_keys)
    # result[0] = build_indices (-1 for unmatched), result[1] = probe_indices
    assert_equal(len(result[0]), 4)
    assert_equal(len(result[1]), 4)

    # Probe rows 0 and 2 (keys 1, 2) match. Rows 1 and 3 (keys 5, 6) don't.
    var num_matched = 0
    var num_unmatched = 0
    for i in range(4):
        if result[0][i] == -1:
            num_unmatched += 1
        else:
            num_matched += 1
    assert_equal(num_matched, 2)
    assert_equal(num_unmatched, 2)


def test_left_join_no_matches() raises:
    """Left join: zero matches still produces all probe rows with -1 build."""
    var build_vals: List[Int] = [10, 20, 30]
    var probe_vals: List[Int] = [1, 2, 3, 4]
    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)
    var result = builder.probe_left(probe_keys)
    assert_equal(len(result[0]), 4)
    for i in range(4):
        assert_equal(result[0][i], -1)


def test_left_join_all_matches() raises:
    """Left join: every probe row matches exactly one build row."""
    var build_vals: List[Int] = [1, 2, 3]
    var probe_vals: List[Int] = [1, 2, 3]
    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)
    var result = builder.probe_left(probe_keys)
    assert_equal(len(result[0]), 3)
    for i in range(3):
        assert_true(result[0][i] != -1, "every probe row should match")


# -----------------------------------------------------------------------------
# Port: test_inner_join_empty_build -- must return 0 rows, not crash.
# -----------------------------------------------------------------------------


def test_inner_join_empty_build_side() raises:
    """Inner join with an empty build side must return 0 rows."""
    var build_arr = PrimitiveArray[DType.int64].allocate(0)
    var probe_vals: List[Int] = [1, 2, 3]
    var probe_arr = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_arr)
    var result = builder.probe_inner(probe_arr)
    assert_equal(len(result[0]), 0)
    assert_equal(len(result[1]), 0)


def test_left_join_empty_build_side() raises:
    """Left join with empty build side: every probe row -> -1 (no match)."""
    var build_arr = PrimitiveArray[DType.int64].allocate(0)
    var probe_vals: List[Int] = [1, 2, 3, 4]
    var probe_arr = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_arr)
    var result = builder.probe_left(probe_arr)
    assert_equal(len(result[0]), 4)
    for i in range(4):
        assert_equal(result[0][i], -1)


# -----------------------------------------------------------------------------
# Port: test_inner_join_multi_worker -- large 1:1 inner join.
# Mojo tests are single-threaded but we still want correctness at scale.
# -----------------------------------------------------------------------------


def test_inner_join_large_one_to_one() raises:
    """500-row build vs 2000-row probe: every probe row matches exactly
    one build row when probe = build * (1..4)."""
    var n_build = 500
    var n_probe = 2000

    var build_arr = PrimitiveArray[DType.int64].allocate(n_build)
    var bp = build_arr._typed_ptr_mut()
    for i in range(n_build):
        (bp + i)[] = Scalar[DType.int64](i + 1)  # 1..500

    var probe_arr = PrimitiveArray[DType.int64].allocate(n_probe)
    var pp = probe_arr._typed_ptr_mut()
    for i in range(n_probe):
        # Cycle: probe key = (i % 500) + 1 -> each build row matches 4 times
        (pp + i)[] = Scalar[DType.int64]((i % 500) + 1)

    var builder = HashJoinBuilder.build(build_arr)
    var result = builder.probe_inner(probe_arr)
    # 2000 probe rows, each matches exactly 1 build row -> 2000 result rows
    assert_equal(len(result[0]), 2000)
    assert_equal(len(result[1]), 2000)
    _ = build_arr
    _ = probe_arr


# -----------------------------------------------------------------------------
# Port: test_anti_join_duplicate_build_keys -- duplicates on build side.
# probe_anti returns probe rows with NO match. Build dups
# don't affect the probe result, but we want to ensure no crash with dup keys.
# -----------------------------------------------------------------------------


def test_anti_join_with_duplicate_build_keys() raises:
    """Build side has duplicate keys; anti-join must still return only the
    probe rows with no match."""
    var build_vals: List[Int] = [1, 1, 2, 2, 3, 3]
    var probe_vals: List[Int] = [1, 2, 4, 5]
    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)
    var result = builder.probe_anti(probe_keys)
    # Probe rows that DON'T match: keys 4 and 5 -> probe indices 2 and 3
    assert_equal(len(result), 2)
    assert_true(_contains(result, 2))
    assert_true(_contains(result, 3))


def test_semi_join_with_duplicate_build_keys() raises:
    """Build side has duplicate keys; semi-join returns each matching probe
    row exactly once."""
    var build_vals: List[Int] = [1, 1, 2, 2, 3, 3]
    var probe_vals: List[Int] = [1, 2, 4, 5]
    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)
    var result = builder.probe_semi(probe_keys)
    # Probe rows that DO match: keys 1 and 2 -> probe indices 0 and 1
    assert_equal(len(result), 2)
    assert_true(_contains(result, 0))
    assert_true(_contains(result, 1))


# -----------------------------------------------------------------------------
# Port: test_inner_join_many_to_many -- duplicates on BOTH sides.
# -----------------------------------------------------------------------------


def test_inner_join_many_to_many() raises:
    """Build=[1,1,2], Probe=[1,1,2,3]:
    - key 1: 2 build * 2 probe = 4 pairs
    - key 2: 1 build * 1 probe = 1 pair
    - key 3: 0 matches
    Total: 5 pairs."""
    var build_vals: List[Int] = [1, 1, 2]
    var probe_vals: List[Int] = [1, 1, 2, 3]
    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)
    var result = builder.probe_inner(probe_keys)
    assert_equal(len(result[0]), 5)
    assert_equal(len(result[1]), 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
