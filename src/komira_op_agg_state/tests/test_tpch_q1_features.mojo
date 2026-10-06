# =============================================================================
# Unit tests for TPC-H Q1 features:
#   1. MultiAggAccumulator -- multiple aggregations per group
#   2. CompositeKeyAggregator -- multi-column GROUP BY
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_state.aggregate import (
    MultiAggAccumulator,
    CompositeKeyAggregator,
    AggAccumulator,
)


# =============================================================================
# 1. MultiAggAccumulator unit tests
# =============================================================================

def test_multi_agg_create_zero_state() raises:
    """Create a MultiAggAccumulator with 3 slots, verify zero state."""
    var acc = MultiAggAccumulator.create(3)
    assert_equal(acc.num_aggs, 3)
    for i in range(3):
        assert_equal(acc.sums[i], 0.0)
        assert_equal(acc.counts[i], 0)


def test_multi_agg_update_single_slot() raises:
    """Update a single agg slot, verify only that slot changes."""
    var acc = MultiAggAccumulator.create(3)
    acc.update(0, 10.0)
    acc.update(0, 20.0)
    acc.update(0, 30.0)

    # Slot 0: sum=60, count=3, min=10, max=30
    assert_equal(acc.sums[0], 60.0)
    assert_equal(acc.counts[0], 3)
    assert_equal(acc.mins[0], 10.0)
    assert_equal(acc.maxs[0], 30.0)

    # Slots 1 and 2 should be untouched
    assert_equal(acc.sums[1], 0.0)
    assert_equal(acc.counts[1], 0)
    assert_equal(acc.sums[2], 0.0)
    assert_equal(acc.counts[2], 0)


def test_multi_agg_update_multiple_slots() raises:
    """Update multiple agg slots independently."""
    var acc = MultiAggAccumulator.create(2)
    # Slot 0: quantity
    acc.update(0, 5.0)
    acc.update(0, 15.0)
    # Slot 1: price
    acc.update(1, 100.0)
    acc.update(1, 200.0)

    assert_equal(acc.sums[0], 20.0)
    assert_equal(acc.counts[0], 2)
    assert_equal(acc.sums[1], 300.0)
    assert_equal(acc.counts[1], 2)


def test_multi_agg_avg() raises:
    """Test AVG computation (SUM / COUNT)."""
    var acc = MultiAggAccumulator.create(2)
    acc.update(0, 10.0)
    acc.update(0, 20.0)
    acc.update(0, 30.0)

    # AVG slot 0: 60 / 3 = 20.0
    assert_equal(acc.avg(0), 20.0)

    # AVG slot 1: 0 / 0 = 0.0 (no values)
    assert_equal(acc.avg(1), 0.0)


def test_multi_agg_count_only() raises:
    """Test COUNT(*) update (no value column)."""
    var acc = MultiAggAccumulator.create(1)
    acc.update_count_only(0)
    acc.update_count_only(0)
    acc.update_count_only(0)

    assert_equal(acc.counts[0], 3)
    assert_equal(acc.sums[0], 0.0)  # No values added


def test_multi_agg_min_max() raises:
    """Test MIN and MAX tracking across updates."""
    var acc = MultiAggAccumulator.create(1)
    acc.update(0, 50.0)
    acc.update(0, 10.0)
    acc.update(0, 90.0)
    acc.update(0, 30.0)

    assert_equal(acc.mins[0], 10.0)
    assert_equal(acc.maxs[0], 90.0)


def test_multi_agg_copy() raises:
    """Test that MultiAggAccumulator copy works correctly."""
    var acc = MultiAggAccumulator.create(2)
    acc.update(0, 10.0)
    acc.update(1, 20.0)

    var acc2 = acc.copy()
    assert_equal(acc2.sums[0], 10.0)
    assert_equal(acc2.sums[1], 20.0)

    # Modifying copy should not affect original
    acc2.update(0, 100.0)
    assert_equal(acc.sums[0], 10.0)
    assert_equal(acc2.sums[0], 110.0)


# =============================================================================
# 2. CompositeKeyAggregator unit tests
# =============================================================================

def test_composite_agg_two_string_keys() raises:
    """GROUP BY two string columns: (returnflag, linestatus)."""
    var agg = CompositeKeyAggregator.create(num_aggs=1)

    # Group ("A", "F"): values 10, 20
    var k1: List[String] = ["A", "F"]
    agg.insert(k1, 0, 10.0)
    var k1b: List[String] = ["A", "F"]
    agg.insert(k1b, 0, 20.0)

    # Group ("N", "O"): values 30, 40
    var k2: List[String] = ["N", "O"]
    agg.insert(k2, 0, 30.0)
    var k2b: List[String] = ["N", "O"]
    agg.insert(k2b, 0, 40.0)

    # Group ("R", "F"): value 50
    var k3: List[String] = ["R", "F"]
    agg.insert(k3, 0, 50.0)

    assert_equal(agg.num_groups, 3)

    # Verify sums per group
    var found_af = False
    var found_no = False
    var found_rf = False
    for g in range(agg.num_groups):
        var keys = agg.get_group_keys(g)
        if keys[0] == "A" and keys[1] == "F":
            assert_equal(agg.accumulators[g].sums[0], 30.0)
            assert_equal(agg.accumulators[g].counts[0], 2)
            found_af = True
        elif keys[0] == "N" and keys[1] == "O":
            assert_equal(agg.accumulators[g].sums[0], 70.0)
            assert_equal(agg.accumulators[g].counts[0], 2)
            found_no = True
        elif keys[0] == "R" and keys[1] == "F":
            assert_equal(agg.accumulators[g].sums[0], 50.0)
            assert_equal(agg.accumulators[g].counts[0], 1)
            found_rf = True

    assert_true(found_af, "Group (A, F) not found")
    assert_true(found_no, "Group (N, O) not found")
    assert_true(found_rf, "Group (R, F) not found")


def test_composite_agg_multi_agg_slots() raises:
    """Multi-column key with multiple aggregation slots."""
    var agg = CompositeKeyAggregator.create(num_aggs=3)

    # One group ("X", "Y"), three agg slots with different values
    var k: List[String] = ["X", "Y"]
    agg.insert(k, 0, 10.0)  # agg 0
    var k2: List[String] = ["X", "Y"]
    agg.insert(k2, 1, 20.0)  # agg 1
    var k3: List[String] = ["X", "Y"]
    agg.insert(k3, 2, 30.0)  # agg 2

    assert_equal(agg.num_groups, 1)
    assert_equal(agg.accumulators[0].sums[0], 10.0)
    assert_equal(agg.accumulators[0].sums[1], 20.0)
    assert_equal(agg.accumulators[0].sums[2], 30.0)


def test_composite_agg_insert_multi_agg() raises:
    """Test insert_multi_agg -- all agg slots updated in one call."""
    var agg = CompositeKeyAggregator.create(num_aggs=2)

    var k: List[String] = ["G1"]
    var vals: List[Float64] = [10.0, 20.0]
    agg.insert_multi_agg(k, vals)

    var k2: List[String] = ["G1"]
    var vals2: List[Float64] = [30.0, 40.0]
    agg.insert_multi_agg(k2, vals2)

    assert_equal(agg.num_groups, 1)
    assert_equal(agg.accumulators[0].sums[0], 40.0)  # 10 + 30
    assert_equal(agg.accumulators[0].sums[1], 60.0)  # 20 + 40
    assert_equal(agg.accumulators[0].counts[0], 2)
    assert_equal(agg.accumulators[0].counts[1], 2)


def test_composite_agg_insert_count() raises:
    """Test insert_count for COUNT(*) aggregation."""
    var agg = CompositeKeyAggregator.create(num_aggs=2)

    var k: List[String] = ["A", "B"]
    agg.insert(k, 0, 10.0)  # agg 0: SUM
    var k2: List[String] = ["A", "B"]
    agg.insert_count(k2, 1)  # agg 1: COUNT(*)
    var k3: List[String] = ["A", "B"]
    agg.insert(k3, 0, 20.0)  # agg 0: SUM
    var k4: List[String] = ["A", "B"]
    agg.insert_count(k4, 1)  # agg 1: COUNT(*)

    assert_equal(agg.num_groups, 1)
    assert_equal(agg.accumulators[0].sums[0], 30.0)
    assert_equal(agg.accumulators[0].counts[0], 2)
    assert_equal(agg.accumulators[0].counts[1], 2)
    assert_equal(agg.accumulators[0].sums[1], 0.0)  # COUNT only, no values


def test_composite_agg_resize() raises:
    """Test that the hash table resizes correctly with many groups."""
    var agg = CompositeKeyAggregator.create(num_aggs=1, initial_capacity=4)

    # Insert more than 70% of capacity (4 * 0.7 = 2.8) to trigger resize
    for i in range(10):
        var k: List[String] = ["group_" + String(i)]
        agg.insert(k, 0, Float64(i))

    assert_equal(agg.num_groups, 10)
    # Capacity should have grown past initial 4
    assert_true(agg.capacity > 4, "Expected capacity > 4 after resize")


def test_composite_agg_get_group_keys() raises:
    """Test that get_group_keys correctly deserializes composite keys."""
    var agg = CompositeKeyAggregator.create(num_aggs=1)

    var k: List[String] = ["alpha", "beta", "gamma"]
    agg.insert(k, 0, 1.0)

    var keys = agg.get_group_keys(0)
    assert_equal(len(keys), 3)
    assert_equal(keys[0], "alpha")
    assert_equal(keys[1], "beta")
    assert_equal(keys[2], "gamma")


def test_composite_agg_tpch_q1_pattern() raises:
    """TPC-H Q1 pattern: GROUP BY (returnflag, linestatus) with SUM + COUNT + AVG.

    Simulates 3 groups with 3 agg slots each:
      slot 0: SUM(quantity)
      slot 1: SUM(price)
      slot 2: COUNT(*)
    """
    var agg = CompositeKeyAggregator.create(num_aggs=3)

    # Row 1: ("A", "F"), qty=10, price=100
    var k1: List[String] = ["A", "F"]
    agg.insert(k1, 0, 10.0)
    var k1b: List[String] = ["A", "F"]
    agg.insert(k1b, 1, 100.0)
    var k1c: List[String] = ["A", "F"]
    agg.insert_count(k1c, 2)

    # Row 2: ("A", "F"), qty=20, price=200
    var k2: List[String] = ["A", "F"]
    agg.insert(k2, 0, 20.0)
    var k2b: List[String] = ["A", "F"]
    agg.insert(k2b, 1, 200.0)
    var k2c: List[String] = ["A", "F"]
    agg.insert_count(k2c, 2)

    # Row 3: ("N", "O"), qty=5, price=50
    var k3: List[String] = ["N", "O"]
    agg.insert(k3, 0, 5.0)
    var k3b: List[String] = ["N", "O"]
    agg.insert(k3b, 1, 50.0)
    var k3c: List[String] = ["N", "O"]
    agg.insert_count(k3c, 2)

    assert_equal(agg.num_groups, 2)

    # Verify group (A, F)
    for g in range(agg.num_groups):
        var keys = agg.get_group_keys(g)
        if keys[0] == "A" and keys[1] == "F":
            assert_equal(agg.accumulators[g].sums[0], 30.0)   # SUM(qty)
            assert_equal(agg.accumulators[g].sums[1], 300.0)   # SUM(price)
            assert_equal(agg.accumulators[g].counts[2], 2)      # COUNT(*)
            assert_equal(agg.accumulators[g].avg(0), 15.0)      # AVG(qty) = 30/2
        elif keys[0] == "N" and keys[1] == "O":
            assert_equal(agg.accumulators[g].sums[0], 5.0)
            assert_equal(agg.accumulators[g].sums[1], 50.0)
            assert_equal(agg.accumulators[g].counts[2], 1)


# =============================================================================
# Entry point
# =============================================================================

def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
