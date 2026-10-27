# =============================================================================
# test_compaction_policy.mojo -- when a delta chain is worth folding.
# =============================================================================
#
#   count leg     a chain folds at delta_count_max deltas and not one below; a
#                 very large maximum turns the leg off.
#   size leg      the chain folds when delta_bytes * den >= base_bytes * num, at
#                 the boundary and not one byte below it; a denominator of zero
#                 or less turns the leg off; large byte counts compare exactly.
#   either        each leg alone is enough, and neither tripping is no fold.
#   no deltas     a chain with no deltas never folds, whatever the thresholds.
#   default       the default is 32 deltas or half the base's bytes.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_kg_format import CompactionPolicy


def test_the_count_leg_trips_at_the_maximum_and_not_below() raises:
    var p = CompactionPolicy(5, Int64(0), Int64(0))  # size leg off
    assert_false(p.should_compact(4, Int64(1000), Int64(1)))
    assert_true(p.should_compact(5, Int64(0), Int64(1)))
    assert_true(p.should_compact(6, Int64(0), Int64(1)))
    var off = CompactionPolicy(1000000, Int64(0), Int64(0))
    assert_false(off.should_compact(999999, Int64(1), Int64(1)))


def test_the_size_leg_trips_at_the_boundary_and_not_below() raises:
    var p = CompactionPolicy(1000000, Int64(1), Int64(2))  # half the base
    assert_false(p.should_compact(3, Int64(49), Int64(100)))
    assert_true(p.should_compact(3, Int64(50), Int64(100)))
    assert_true(p.should_compact(3, Int64(51), Int64(100)))
    # Odd base: 2 * 50 = 100 >= 101 is false, 2 * 51 = 102 >= 101 is true.
    assert_false(p.should_compact(3, Int64(50), Int64(101)))
    assert_true(p.should_compact(3, Int64(51), Int64(101)))
    var thirds = CompactionPolicy(1000000, Int64(2), Int64(3))
    assert_false(thirds.should_compact(1, Int64(66), Int64(100)))  # 198 vs 200
    assert_true(thirds.should_compact(1, Int64(67), Int64(100)))  # 201 vs 200


def test_a_denominator_of_zero_or_less_turns_the_size_leg_off() raises:
    var zero = CompactionPolicy(1000000, Int64(1), Int64(0))
    assert_false(zero.should_compact(3, Int64(1000000), Int64(1)))
    var negative = CompactionPolicy(1000000, Int64(1), Int64(-2))
    assert_false(negative.should_compact(3, Int64(1000000), Int64(1)))


def test_byte_counts_beyond_32_bits_compare_exactly() raises:
    var p = CompactionPolicy(1000000, Int64(1), Int64(2))
    var base = Int64(10_000_000_000)  # 10 GB
    assert_false(p.should_compact(3, Int64(4_999_999_999), base))
    assert_true(p.should_compact(3, Int64(5_000_000_000), base))


def test_either_leg_alone_is_enough() raises:
    var p = CompactionPolicy(4, Int64(1), Int64(2))
    assert_true(p.should_compact(4, Int64(1), Int64(1000)))  # count only
    assert_true(p.should_compact(2, Int64(500), Int64(1000)))  # size only
    assert_false(p.should_compact(3, Int64(499), Int64(1000)))  # neither


def test_a_chain_with_no_deltas_never_folds() raises:
    assert_false(CompactionPolicy.default().should_compact(0, Int64(0), Int64(0)))
    # Count maximum of zero and a zero numerator would otherwise fold forever.
    assert_false(CompactionPolicy(0, Int64(0), Int64(1)).should_compact(
        0, Int64(0), Int64(100)
    ))
    assert_false(CompactionPolicy(0, Int64(0), Int64(1)).should_compact(
        -1, Int64(0), Int64(100)
    ))
    assert_true(CompactionPolicy(1, Int64(0), Int64(0)).should_compact(
        1, Int64(0), Int64(100)
    ))


def test_the_default_is_32_deltas_or_half_the_base() raises:
    var p = CompactionPolicy.default()
    assert_equal(p.delta_count_max, 32)
    assert_equal(p.bytes_fraction_num, 1)
    assert_equal(p.bytes_fraction_den, 2)
    assert_false(p.should_compact(31, Int64(10), Int64(1000)))
    assert_true(p.should_compact(32, Int64(10), Int64(1000)))
    assert_true(p.should_compact(1, Int64(500), Int64(1000)))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
