# =============================================================================
# The grouped COUNT(DISTINCT) group table is sized from GROUPS, not rows
# =============================================================================
#
# `agg_cd_group_ht_sizing` gives each worker's group table its first size from
# an upper bound on the number of groups (the product of the key columns'
# dictionary sizes, each plus one for NULL, capped at the row count; unknown
# for a key with no dictionary), instead of from the rows a worker holds.
#
# What each test proves:
#   * the bound: `+1` per key for NULL, an INT key (no dictionary) makes it
#     unknown, an empty dictionary (all-NULL key) is one group, zero keys is
#     one group, and the product saturates at the row
#     count instead of overflowing;
#   * the first capacity: a power of two from the per-worker group bound,
#     the floor for few groups or an unknown bound, and clamped at
#     `CD_GROUP_HT_MAX_INITIAL_CAP` (growth past it is the worker's).
#
# The allocation witnesses (slots allocated and resizes, per run) through the
# driver are tested with the driver.
# =============================================================================

from std.collections import Dict, List
from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import (
    Field, RecordBatch, RecordBatchBuilder, SchemaBuilder,
)
from komira_arrow.string_array import StringArray

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_MOCK
from komira_async.runtime.runtime import PLACEMENT_FIXED, PerCoreAsyncRuntime

from komira_op_agg_distinct.agg_cd_group_ht_sizing import (
    CD_GROUP_HT_MAX_INITIAL_CAP,
    CD_GROUP_HT_MIN_CAP,
    cd_group_ht_initial_cap,
    cd_group_ht_resizes_count,
    cd_group_ht_slots_count,
    cd_groups_upper_bound,
    reset_cd_group_ht_counters,
)


comptime _WORKERS: Int = 4


def _noop_sink_factory() -> NoopSink:
    return NoopSink(_placeholder=UInt8(0))


# =============================================================================
# 1. THE SIZING RULE, stated directly
# =============================================================================


def test_the_bound_is_the_product_of_dictionary_sizes_capped_at_rows() raises:
    """`+1` per key is NULL slack; an INT key (negative entry) makes the bound
    unknown; zero keys is one group; the product saturates at the row count."""
    var one: List[Int] = [165]
    assert_equal(cd_groups_upper_bound(one, 5_563_212), 166, "one 165-entry key")
    var two: List[Int] = [10, 20]
    assert_equal(cd_groups_upper_bound(two, 1_000_000), 11 * 21, "two keys")
    var mixed: List[Int] = [165, -1]
    assert_equal(
        cd_groups_upper_bound(mixed, 5_563_212), -1,
        "an INT key has no dictionary, so there is no bound",
    )
    var empty_dict: List[Int] = [0]
    assert_equal(
        cd_groups_upper_bound(empty_dict, 1_000), 1,
        "an empty dictionary (an all-NULL key) is a known bound: one NULL group",
    )
    var nokeys = List[Int]()
    assert_equal(cd_groups_upper_bound(nokeys, 70_000), 1, "ungrouped")
    var huge: List[Int] = [1_000_000, 1_000_000]
    assert_equal(
        cd_groups_upper_bound(huge, 5_000_000), 5_000_000,
        "saturates at the row count, never overflows",
    )


def test_the_first_capacity_is_a_function_of_groups_not_rows() raises:
    """Two shapes, derived by hand:
    a 166-group bound over K=20 -> 9 per worker -> the 4,096 floor.
    a 6,019,103-group bound over K=20 -> 300,956 (+1/8 +64 = 338,639) ->
    2x = 677,278 -> 1,048,576, the same first size as before (and now
    allocated by the worker, not the driver)."""
    assert_equal(cd_group_ht_initial_cap(166, 20), CD_GROUP_HT_MIN_CAP, "small bound")
    assert_equal(cd_group_ht_initial_cap(6_019_103, 20), 1_048_576, "large bound")
    assert_equal(
        cd_group_ht_initial_cap(-1, 20), CD_GROUP_HT_MIN_CAP,
        "unknown bound: start small, the worker grows it",
    )
    assert_equal(
        cd_group_ht_initial_cap(1 << 40, 1), CD_GROUP_HT_MAX_INITIAL_CAP,
        "the FIRST size is clamped; growth past it is the worker's",
    )
    var c = cd_group_ht_initial_cap(30_001, 4)
    assert_equal(c, 32_768, "30,001 groups over 4 workers")
    assert_true((c & (c - 1)) == 0, "a power of two")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
