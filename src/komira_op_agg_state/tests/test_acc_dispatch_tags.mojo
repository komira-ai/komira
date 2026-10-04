# =============================================================================
# Tests for Phase 1B Stage 1C dispatch tags
# =============================================================================
#
# Verifies the 5 new ACC_* dispatch tags added in Stage 1C have:
#   1. Stable, distinct values (no accidental collision with existing tags).
#   2. Distinct from each other (each maps to a unique kernel).
#
# Tag values are part of the dispatch byte contract -- changing them would
# require a coordinated update across columnar_agg_map.mojo (the dispatch
# table) + accumulator_factory.mojo (make_single_dyn_acc) + any spilled
# state on disk. Locking the values via this test prevents accidental
# renumbering.
#
# Stage 2 will land full vtable wiring (_fin_*, _merge_at_*, _vtable_*,
# Accumulator trait conformance) and the dispatch test will tighten to
# "make_single_dyn_acc(tag).tag == tag" round-trip.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_not_equal

from komira_op_agg_state.columnar_agg_accumulator import (
    ACC_MIN_UTF8,
    ACC_MAX_UTF8,
    ACC_SUM_INT64,
    ACC_COUNT_INT64,
    ACC_MIN_INT64,
    ACC_MAX_INT64,
    ACC_PERCENTILE_F64,
    ACC_SUM_F64,
    ACC_COUNT_STAR,
    ACC_MIN_F64,
    ACC_MAX_F64,
    ACC_AVG,
)


# =============================================================================
# Stable values -- bytes round-trip across the spill / merge contract.
# Re-numbering any of these requires a coordinated update; the test locks
# the current values so a casual edit fails CI.
# =============================================================================

def test_existing_tags_stable() raises:
    assert_equal(Int(ACC_MIN_UTF8), 0)
    assert_equal(Int(ACC_MAX_UTF8), 1)
    assert_equal(Int(ACC_SUM_INT64), 2)
    assert_equal(Int(ACC_COUNT_INT64), 3)
    assert_equal(Int(ACC_MIN_INT64), 4)
    assert_equal(Int(ACC_MAX_INT64), 5)
    assert_equal(Int(ACC_PERCENTILE_F64), 6)


def test_new_tags_stable() raises:
    """The 5 new Stage 1C tags use sequential values 7-11."""
    assert_equal(Int(ACC_SUM_F64), 7)
    assert_equal(Int(ACC_COUNT_STAR), 8)
    assert_equal(Int(ACC_MIN_F64), 9)
    assert_equal(Int(ACC_MAX_F64), 10)
    assert_equal(Int(ACC_AVG), 11)


# =============================================================================
# Distinct values -- no two tags share the same byte. Anti-collision check.
# =============================================================================

def test_all_tags_distinct() raises:
    """Every tag is distinct from every other tag (no accidental collision)."""
    var tags = List[UInt8]()
    tags.append(ACC_MIN_UTF8)
    tags.append(ACC_MAX_UTF8)
    tags.append(ACC_SUM_INT64)
    tags.append(ACC_COUNT_INT64)
    tags.append(ACC_MIN_INT64)
    tags.append(ACC_MAX_INT64)
    tags.append(ACC_PERCENTILE_F64)
    tags.append(ACC_SUM_F64)
    tags.append(ACC_COUNT_STAR)
    tags.append(ACC_MIN_F64)
    tags.append(ACC_MAX_F64)
    tags.append(ACC_AVG)
    var n = len(tags)
    for i in range(n):
        for j in range(i + 1, n):
            assert_not_equal(Int(tags[i]), Int(tags[j]))


def test_new_tags_pairwise_distinct() raises:
    """Stage 1C focused: the 5 NEW tags are pairwise distinct."""
    assert_not_equal(Int(ACC_SUM_F64), Int(ACC_COUNT_STAR))
    assert_not_equal(Int(ACC_SUM_F64), Int(ACC_MIN_F64))
    assert_not_equal(Int(ACC_SUM_F64), Int(ACC_MAX_F64))
    assert_not_equal(Int(ACC_SUM_F64), Int(ACC_AVG))
    assert_not_equal(Int(ACC_COUNT_STAR), Int(ACC_MIN_F64))
    assert_not_equal(Int(ACC_COUNT_STAR), Int(ACC_MAX_F64))
    assert_not_equal(Int(ACC_COUNT_STAR), Int(ACC_AVG))
    assert_not_equal(Int(ACC_MIN_F64), Int(ACC_MAX_F64))
    assert_not_equal(Int(ACC_MIN_F64), Int(ACC_AVG))
    assert_not_equal(Int(ACC_MAX_F64), Int(ACC_AVG))


# =============================================================================
# Test driver
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
