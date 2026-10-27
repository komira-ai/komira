# =============================================================================
# test_spsc_ring_bench.mojo -- the spsc_ring benchmark runs and prints its lines
# =============================================================================
#
# The benchmark is run for real on a few records, through the same function the
# program calls. It proves the shape of what comes out and that the three
# measurements complete (push_pop's consumer stops only after it has popped
# every record, so a ring that lost one would never return and the test would
# be stopped by the hang limit); it asserts nothing about a time. Cases:
#   - three lines, in the order push_only, push_pop, drop_push, each with the
#     capacity it was run at and a value after `ns_per_op=` (some text);
#   - with the times hidden the three lines are exactly the expected text;
#   - a capacity larger than the number of records still measures (push_only
#     runs one round: `total_ops // cap` must not reach zero, which would make
#     the value `nan`).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_bench.harness import BenchArgs
from komira_bench.spsc_ring_bench import bench_lines, default_caps


def _args(total_ops: Int, hide: Bool) -> BenchArgs:
    var a = BenchArgs(total_ops, default_caps())
    a.hide_times = hide
    return a^


def test_three_lines_with_a_value() raises:
    var lines = bench_lines(64, _args(2048, False))
    assert_equal(len(lines), 3)
    var ops = List[String]()
    ops.append("push_only")
    ops.append("push_pop")
    ops.append("drop_push")
    for i in range(3):
        var prefix = "RESULT " + ops[i] + " cap=64 ns_per_op="
        assert_true(lines[i].startswith(prefix), lines[i])
        assert_true(lines[i].byte_length() > prefix.byte_length(), lines[i])


def test_hidden_times_are_exact() raises:
    var lines = bench_lines(64, _args(2048, True))
    assert_equal(len(lines), 3)
    assert_equal(lines[0], "RESULT push_only cap=64 ns_per_op=-")
    assert_equal(lines[1], "RESULT push_pop cap=64 ns_per_op=-")
    assert_equal(lines[2], "RESULT drop_push cap=64 ns_per_op=-")


def test_capacity_above_the_record_count() raises:
    var lines = bench_lines(4096, _args(100, True))
    assert_equal(len(lines), 3)
    assert_equal(lines[0], "RESULT push_only cap=4096 ns_per_op=-")
    assert_equal(lines[1], "RESULT push_pop cap=4096 ns_per_op=-")
    assert_equal(lines[2], "RESULT drop_push cap=4096 ns_per_op=-")
    # With the values shown none is `nan` or `inf`: push_only with no round
    # would divide zero by zero. (No value is compared with a time.)
    var shown = bench_lines(4096, _args(100, False))
    for i in range(3):
        assert_true("nan" not in shown[i], shown[i])
        assert_true("inf" not in shown[i], shown[i])


def main() raises:
    test_three_lines_with_a_value()
    test_hidden_times_are_exact()
    test_capacity_above_the_record_count()
    print("ALL TESTS PASS")
