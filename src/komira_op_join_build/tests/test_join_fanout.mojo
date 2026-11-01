# =============================================================================
# test_join_fanout -- `HashJoinBuilder.avg_chain_length` estimates the fan-out
# of a many-to-many join, and the chunked probe returns every pair of one.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_join_build.join import HashJoinBuilder


def _make_int64_arr(values: List[Int]) -> PrimitiveArray[DType.int64]:
    """Helper: create PrimitiveArray from a list of ints."""
    var n = len(values)
    var arr = PrimitiveArray[DType.int64].allocate(n)
    var p = arr._typed_ptr_mut()
    for i in range(n):
        (p + i)[] = Scalar[DType.int64](values[i])
    return arr^


# =============================================================================
# avg_chain_length tests
# =============================================================================


def test_avg_chain_length_unique_keys() raises:
    """1:1 keys: avg chain length should be 1."""
    var build_vals: List[Int] = [1, 2, 3, 4, 5]
    var build_keys = _make_int64_arr(build_vals)
    var builder = HashJoinBuilder.build(build_keys)
    assert_equal(builder.avg_chain_length(), 1)
    print("PASS: test_avg_chain_length_unique_keys")


def test_avg_chain_length_all_same_key() raises:
    """All same key: avg chain length == N (all rows in one bucket)."""
    var build_vals: List[Int] = [42, 42, 42, 42, 42, 42, 42, 42, 42, 42]
    var build_keys = _make_int64_arr(build_vals)
    var builder = HashJoinBuilder.build(build_keys)
    # 10 rows, 1 occupied bucket -> chain length = 10
    assert_equal(builder.avg_chain_length(), 10)
    print("PASS: test_avg_chain_length_all_same_key")


def test_avg_chain_length_moderate_dups() raises:
    """5 values repeated 4x each: avg chain length = 4."""
    var build_vals = List[Int]()
    for key in range(5):
        for _ in range(4):
            build_vals.append(key)
    var build_keys = _make_int64_arr(build_vals)
    var builder = HashJoinBuilder.build(build_keys)
    # 20 rows, 5 occupied buckets -> 20/5 = 4
    assert_equal(builder.avg_chain_length(), 4)
    print("PASS: test_avg_chain_length_moderate_dups")


def test_avg_chain_length_empty() raises:
    """Empty build side: chain length = 1 (sentinel)."""
    var build_vals = List[Int]()
    var build_keys = _make_int64_arr(build_vals)
    var builder = HashJoinBuilder.build(build_keys)
    assert_equal(builder.avg_chain_length(), 1)
    print("PASS: test_avg_chain_length_empty")


# =============================================================================
# Correctness: many-to-many inner join (exercises the chunked dispatch path)
# =============================================================================


def test_many_to_many_inner_correctness() raises:
    """Many-to-many join: 100 unique keys, 10 duplicates per key on build side.
    Build = 1000 rows (10 per key), probe = 100 rows (1 per key).
    Expected output: 100 probe rows * 10 build matches = 1000 result rows.

    This exercises the fan-out detection (avg_chain_length = 10 >= 4)
    which routes to the chunked path.
    """
    var build_vals = List[Int]()
    for key in range(100):
        for _ in range(10):
            build_vals.append(key)
    var probe_vals = List[Int]()
    for key in range(100):
        probe_vals.append(key)

    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)

    # Verify fan-out estimate
    assert_equal(builder.avg_chain_length(), 10)

    # Inner join
    var result = builder.probe_inner(probe_keys)
    var build_idx = result[0].copy()
    var probe_idx = result[1].copy()

    # 100 probe rows * 10 matches each = 1000 pairs
    assert_equal(len(build_idx), 1000)
    assert_equal(len(probe_idx), 1000)

    # Verify every match is correct
    for i in range(len(build_idx)):
        var bi = build_idx[i]
        var pi = probe_idx[i]
        # build_vals[bi] should equal probe_vals[pi]
        assert_equal(build_vals[bi], probe_vals[pi])

    print("PASS: test_many_to_many_inner_correctness")


def test_many_to_many_inner_large_fanout() raises:
    """High fan-out: 10 unique keys, 100 duplicates per key.
    Build = 1000 rows, probe = 10 rows -> 1000 output rows.
    avg_chain_length = 100, well above the threshold.
    """
    var build_vals = List[Int]()
    for key in range(10):
        for _ in range(100):
            build_vals.append(key)
    var probe_vals = List[Int]()
    for key in range(10):
        probe_vals.append(key)

    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)

    assert_equal(builder.avg_chain_length(), 100)

    var result = builder.probe_inner(probe_keys)
    var build_idx = result[0].copy()
    var probe_idx = result[1].copy()

    assert_equal(len(build_idx), 1000)
    assert_equal(len(probe_idx), 1000)

    # Verify correctness
    for i in range(len(build_idx)):
        var bi = build_idx[i]
        var pi = probe_idx[i]
        assert_equal(build_vals[bi], probe_vals[pi])

    print("PASS: test_many_to_many_inner_large_fanout")


def test_many_to_many_probe_into() raises:
    """Test probe_inner_into (output parameter variant) with fan-out.
    This is the variant used by the chunked dispatch path.
    """
    var build_vals = List[Int]()
    for key in range(5):
        for _ in range(20):
            build_vals.append(key)
    var probe_vals = List[Int]()
    for key in range(5):
        probe_vals.append(key)

    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)

    assert_equal(builder.avg_chain_length(), 20)

    var build_matches = List[Int](capacity=100)
    var probe_matches = List[Int](capacity=100)
    builder.probe_inner_into(probe_keys, build_matches, probe_matches)

    # 5 probe rows * 20 matches each = 100
    assert_equal(len(build_matches), 100)
    assert_equal(len(probe_matches), 100)

    for i in range(len(build_matches)):
        assert_equal(build_vals[build_matches[i]], probe_vals[probe_matches[i]])

    print("PASS: test_many_to_many_probe_into")


# =============================================================================
# Edge cases
# =============================================================================


def test_single_key_high_fanout() raises:
    """Single key repeated N times: extreme fan-out case."""
    var n = 50
    var build_vals = List[Int]()
    for _ in range(n):
        build_vals.append(7)
    var probe_vals: List[Int] = [7, 7, 99]

    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)
    assert_equal(builder.avg_chain_length(), 50)

    var result = builder.probe_inner(probe_keys)
    var build_idx = result[0].copy()
    var probe_idx = result[1].copy()

    # probe[0]=7 matches all 50 build rows, probe[1]=7 matches 50, probe[2]=99 matches 0
    assert_equal(len(build_idx), 100)

    print("PASS: test_single_key_high_fanout")


def test_no_match_high_fanout_build() raises:
    """High fan-out build side but no probe matches."""
    var build_vals = List[Int]()
    for key in range(5):
        for _ in range(10):
            build_vals.append(key)
    var probe_vals: List[Int] = [100, 200, 300]

    var build_keys = _make_int64_arr(build_vals)
    var probe_keys = _make_int64_arr(probe_vals)

    var builder = HashJoinBuilder.build(build_keys)
    assert_equal(builder.avg_chain_length(), 10)

    var result = builder.probe_inner(probe_keys)
    var build_idx = result[0].copy()
    assert_equal(len(build_idx), 0)

    print("PASS: test_no_match_high_fanout_build")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
