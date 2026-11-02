# `RadixPartitionedHashJoin`: INNER (1:1, duplicates fanning out, no match),
# SEMI, ANTI, LEFT and the size threshold, each pair's keys checked equal.

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_probe.radix_join import RadixPartitionedHashJoin, should_use_radix_join


def _make_keys(values: List[Int]) -> PrimitiveArray[DType.int64]:
    """Helper: create PrimitiveArray from a list of ints."""
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = Scalar[DType.int64](values[i])
    return arr^


def test_radix_join_inner_basic() raises:
    """Basic inner join: 1:1 matching keys."""
    var build_vals: List[Int] = [10, 20, 30, 40, 50]
    var probe_vals: List[Int] = [30, 10, 50, 99]

    var build_keys = _make_keys(build_vals)
    var probe_keys = _make_keys(probe_vals)

    var rj = RadixPartitionedHashJoin.build(build_keys)
    var result = rj.probe_inner(probe_keys)
    var build_idx = result[0].copy()
    var probe_idx = result[1].copy()

    assert_equal(len(build_idx), 3)
    assert_equal(len(probe_idx), 3)

    var matched = 0
    for i in range(len(build_idx)):
        var bi = build_idx[i]
        var pi = probe_idx[i]
        assert_equal(build_vals[bi], probe_vals[pi])
        matched += 1
    assert_equal(matched, 3)
    print("PASS: test_radix_join_inner_basic")


def test_radix_join_inner_duplicates() raises:
    """Inner join with duplicate build keys (1:N)."""
    var build_vals: List[Int] = [10, 20, 10, 30, 10]
    var probe_vals: List[Int] = [10, 30]

    var build_keys = _make_keys(build_vals)
    var probe_keys = _make_keys(probe_vals)

    var rj = RadixPartitionedHashJoin.build(build_keys)
    var result = rj.probe_inner(probe_keys)
    var build_idx = result[0].copy()
    var probe_idx = result[1].copy()

    assert_equal(len(build_idx), 4)

    var count_10 = 0
    for i in range(len(probe_idx)):
        if probe_idx[i] == 0:
            count_10 += 1
    assert_equal(count_10, 3)
    print("PASS: test_radix_join_inner_duplicates")


def test_radix_join_inner_no_matches() raises:
    """Inner join with no matching keys."""
    var build_vals: List[Int] = [1, 2, 3]
    var probe_vals: List[Int] = [4, 5, 6]

    var build_keys = _make_keys(build_vals)
    var probe_keys = _make_keys(probe_vals)

    var rj = RadixPartitionedHashJoin.build(build_keys)
    var result = rj.probe_inner(probe_keys)
    var b = result[0].copy()
    var p = result[1].copy()

    assert_equal(len(b), 0)
    assert_equal(len(p), 0)
    print("PASS: test_radix_join_inner_no_matches")


def test_radix_join_semi() raises:
    """Semi-join: returns probe indices with at least one match."""
    var build_vals: List[Int] = [10, 20, 30, 10]  # duplicate 10
    var probe_vals: List[Int] = [30, 99, 10, 50]

    var build_keys = _make_keys(build_vals)
    var probe_keys = _make_keys(probe_vals)

    var rj = RadixPartitionedHashJoin.build(build_keys)
    var indices = rj.probe_semi(probe_keys)

    assert_equal(len(indices), 2)
    sort(indices)
    assert_equal(indices[0], 0)  # probe idx 0 (key=30)
    assert_equal(indices[1], 2)  # probe idx 2 (key=10)
    print("PASS: test_radix_join_semi")


def test_radix_join_anti() raises:
    """Anti-join: returns probe indices with NO match."""
    var build_vals: List[Int] = [10, 20, 30]
    var probe_vals: List[Int] = [30, 99, 10, 50]

    var build_keys = _make_keys(build_vals)
    var probe_keys = _make_keys(probe_vals)

    var rj = RadixPartitionedHashJoin.build(build_keys)
    var indices = rj.probe_anti(probe_keys)

    assert_equal(len(indices), 2)
    sort(indices)
    assert_equal(indices[0], 1)  # probe idx 1 (key=99)
    assert_equal(indices[1], 3)  # probe idx 3 (key=50)
    print("PASS: test_radix_join_anti")


def test_radix_join_left() raises:
    """Left join: all probe rows appear, -1 for unmatched build."""
    var build_vals: List[Int] = [10, 20, 30]
    var probe_vals: List[Int] = [10, 99, 30]

    var build_keys = _make_keys(build_vals)
    var probe_keys = _make_keys(probe_vals)

    var rj = RadixPartitionedHashJoin.build(build_keys)
    var result = rj.probe_left(probe_keys)
    var build_idx = result[0].copy()
    var probe_idx = result[1].copy()

    assert_equal(len(build_idx), 3)

    var has_minus_one = False
    for i in range(len(build_idx)):
        if build_idx[i] == -1:
            has_minus_one = True
            assert_equal(probe_idx[i], 1)  # probe row 1 (key=99)
    assert_true(has_minus_one, "left join must have -1 for unmatched probe")
    print("PASS: test_radix_join_left")


def test_radix_join_large() raises:
    """Large join to exercise partitioning (100K build x 200K probe)."""
    var n_build = 100_000
    var n_probe = 200_000

    var build_keys = PrimitiveArray[DType.int64].allocate(n_build)
    var bp = build_keys._typed_ptr_mut()
    for i in range(n_build):
        (bp + i)[] = Scalar[DType.int64](i * 3)  # keys: 0, 3, 6, ...

    var probe_keys = PrimitiveArray[DType.int64].allocate(n_probe)
    var pp = probe_keys._typed_ptr_mut()
    for i in range(n_probe):
        (pp + i)[] = Scalar[DType.int64](i)  # keys: 0, 1, 2, ...

    var rj = RadixPartitionedHashJoin.build(build_keys)
    var result = rj.probe_inner(probe_keys)
    var build_idx = result[0].copy()
    var probe_idx = result[1].copy()

    var expected = (n_probe + 2) // 3  # 66667
    assert_equal(len(build_idx), expected)
    assert_equal(len(probe_idx), expected)

    var mismatch = 0
    for i in range(len(build_idx)):
        var bk = build_idx[i] * 3  # build key = build_idx * 3
        var pk = probe_idx[i]      # probe key = probe_idx
        if bk != pk:
            mismatch += 1
    assert_equal(mismatch, 0)
    print("PASS: test_radix_join_large (", n_build, "x", n_probe, ")")


def test_should_use_radix_join() raises:
    """Threshold function returns correct values."""
    assert_true(not should_use_radix_join(1000), "1K rows should not use radix")
    assert_true(not should_use_radix_join(50_000), "50K rows should not use radix")
    assert_true(should_use_radix_join(50_001), "50K+1 rows should use radix")
    assert_true(should_use_radix_join(100_000), "100K rows should use radix")
    print("PASS: test_should_use_radix_join")


def test_radix_join_zero_key() raises:
    """Regression test: key == 0 must match between build and probe."""
    var n_build = 60_000
    var build_keys = PrimitiveArray[DType.int64].allocate(n_build)
    var bp = build_keys._typed_ptr_mut()
    for i in range(n_build):
        (bp + i)[] = Scalar[DType.int64](i)

    var probe_vals: List[Int] = [0]
    var probe_keys = _make_keys(probe_vals)

    var rj = RadixPartitionedHashJoin.build(build_keys)
    var result = rj.probe_inner(probe_keys)
    var build_idx = result[0].copy()
    var probe_idx = result[1].copy()

    assert_equal(len(build_idx), 1)
    assert_equal(len(probe_idx), 1)
    assert_equal(build_idx[0], 0)
    assert_equal(probe_idx[0], 0)
    print("PASS: test_radix_join_zero_key")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
