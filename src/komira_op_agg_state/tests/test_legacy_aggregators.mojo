# =============================================================================
# test_legacy_aggregators.mojo — the Int64-keyed, dictionary-keyed and
# integer-tuple-keyed GROUP BY aggregators of aggregate.mojo, and the
# accumulators they hold
# =============================================================================
#
# Each aggregator starts from a 2-slot table and takes 50 distinct keys, so
# every one resizes several times and probes through collisions. The oracle is
# computed in the test from the inputs alone:
#
#   - every key is found again (no duplicate group after a resize), so the
#     group count is exactly the number of distinct keys;
#   - SUM / COUNT / MIN / MAX per group match a hand fold, with all-negative
#     values in some groups so MAX must start below every negative value;
#   - insert_count touches only the count of its slot;
#   - tuple keys that differ in ONE component are different groups (the
#     equality must compare every component, the 9th of a 9-key tuple too).
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_agg_state.accumulators import (
    AggAccumulator, CountDistinctAccumulator, MultiAggAccumulator,
)
from komira_op_agg_state.aggregate import (
    HashAggregator,
    HashMultiAggregator,
    DictAwareAggregator,
    IntPairKeyAggregator,
    IntTripleKeyAggregator,
    IntNKeyAggregator,
)


comptime N_KEYS = 50


def _val(k: Int, rep: Int) -> Float64:
    """Value of key k in repetition rep: keys divisible by 3 are all-negative."""
    if k % 3 == 0:
        return Float64(-(k + 1) * 10 - rep)
    return Float64(k * 10 + rep)


def test_agg_accumulator_and_count_distinct() raises:
    var a = AggAccumulator.create()
    a.update(-5.0)
    a.update(-3.0)
    assert_equal(a.sum, Float64(-8.0))
    assert_equal(a.count, 2)
    assert_equal(a.min_val, Float64(-5.0))
    assert_equal(a.max_val, Float64(-3.0))
    var d = CountDistinctAccumulator.create()
    assert_equal(d.result(), 0)
    for v in [4, 7, 4, -1, 7, 4]:
        d.insert(v)
    assert_equal(d.result(), 3)
    var m = MultiAggAccumulator.create(2)
    m.update(1, -2.0)
    m.update_count_only(0)
    assert_equal(m.avg(1), Float64(-2.0))
    assert_equal(m.avg(0), Float64(0.0))


def test_hash_aggregator_insert_batch_and_results() raises:
    var agg = HashAggregator.create(initial_capacity=2)
    var keys = PrimitiveArray[DType.int64].allocate(N_KEYS * 3)
    var vals = PrimitiveArray[DType.float64].allocate(N_KEYS * 3)
    var row = 0
    for rep in range(3):
        for k in range(N_KEYS):
            keys.set(row, Int64(k * 7919 - 100000))
            vals.set(row, _val(k, rep))
            row += 1
    agg.insert_batch(keys, vals)
    assert_equal(agg.num_groups, N_KEYS)
    assert_true(agg.capacity >= 64)
    var r = agg.get_results()
    for g in range(N_KEYS):
        # Groups are numbered in first-seen order.
        assert_equal(r[0][g], Int64(g * 7919 - 100000))
        assert_equal(r[1][g], _val(g, 0) + _val(g, 1) + _val(g, 2))
        assert_equal(r[2][g], 3)
        var lo = min(min(_val(g, 0), _val(g, 1)), _val(g, 2))
        var hi = max(max(_val(g, 0), _val(g, 1)), _val(g, 2))
        assert_equal(r[3][g], lo)
        assert_equal(r[4][g], hi)


def test_hash_multi_aggregator() raises:
    var agg = HashMultiAggregator.create(num_aggs=2, initial_capacity=2)
    for rep in range(2):
        for k in range(N_KEYS):
            agg.insert(Int64(k) * 1000003, 0, _val(k, rep))
            agg.insert_count(Int64(k) * 1000003, 1)
    assert_equal(agg.num_groups, N_KEYS)
    for g in range(N_KEYS):
        assert_equal(agg.keys[g], Int64(g) * 1000003)
        assert_equal(agg.accumulators[g].sums[0], _val(g, 0) + _val(g, 1))
        assert_equal(agg.accumulators[g].maxs[0], max(_val(g, 0), _val(g, 1)))
        assert_equal(agg.accumulators[g].counts[1], 2)
        assert_equal(agg.accumulators[g].counts[0], 2)
        assert_equal(agg.accumulators[g].sums[1], Float64(0.0))


def test_dict_aware_aggregator() raises:
    var agg = DictAwareAggregator.create(dict_size=5)
    agg.insert(Int32(4), -1.0)
    var idx = PrimitiveArray[DType.int32].allocate(4)
    var vals = PrimitiveArray[DType.float64].allocate(4)
    var ii: List[Int32] = [Int32(1), Int32(4), Int32(1), Int32(4)]
    var vv: List[Float64] = [Float64(2.0), Float64(-7.0), Float64(6.0), Float64(-3.0)]
    for i in range(4):
        idx.set(i, ii[i])
        vals.set(i, vv[i])
    agg.insert_batch(idx, vals)
    assert_equal(agg.active_groups(), 2)
    var r = agg.get_results()
    assert_equal(len(r[0]), 2)
    assert_equal(r[0][0], 1)
    assert_equal(r[1][0], Float64(8.0))
    assert_equal(r[2][0], 2)
    assert_equal(r[3][0], Float64(2.0))
    assert_equal(r[4][0], Float64(6.0))
    assert_equal(r[0][1], 4)
    assert_equal(r[1][1], Float64(-11.0))
    assert_equal(r[2][1], 3)
    assert_equal(r[3][1], Float64(-7.0))
    assert_equal(r[4][1], Float64(-1.0))


def test_int_pair_key_aggregator() raises:
    var agg = IntPairKeyAggregator.create(num_aggs=2, initial_capacity=2)
    for rep in range(2):
        for k in range(N_KEYS):
            # (k // 5, k % 5): pairs share a first or a second component.
            agg.insert(Int64(k // 5), Int64(k % 5), 0, _val(k, rep))
            agg.insert_count(Int64(k // 5), Int64(k % 5), 1)
    assert_equal(agg.num_groups, N_KEYS)
    for g in range(N_KEYS):
        assert_equal(agg.keys_a[g], Int64(g // 5))
        assert_equal(agg.keys_b[g], Int64(g % 5))
        assert_equal(agg.accumulators[g].sums[0], _val(g, 0) + _val(g, 1))
        assert_equal(agg.accumulators[g].mins[0], min(_val(g, 0), _val(g, 1)))
        assert_equal(agg.accumulators[g].counts[1], 2)


def test_int_triple_key_aggregator() raises:
    var agg = IntTripleKeyAggregator.create(num_aggs=1, initial_capacity=2)
    for rep in range(2):
        for k in range(N_KEYS):
            agg.insert(Int64(k % 2), Int64(k // 2 % 5), Int64(k // 10), 0, _val(k, rep))
    for k in range(N_KEYS):
        agg.insert_count(Int64(k % 2), Int64(k // 2 % 5), Int64(k // 10), 0)
    assert_equal(agg.num_groups, N_KEYS)
    for g in range(N_KEYS):
        assert_equal(agg.keys_a[g], Int64(g % 2))
        assert_equal(agg.keys_b[g], Int64(g // 2 % 5))
        assert_equal(agg.keys_c[g], Int64(g // 10))
        assert_equal(agg.accumulators[g].sums[0], _val(g, 0) + _val(g, 1))
        assert_equal(agg.accumulators[g].counts[0], 3)


def test_tuple_keys_differing_only_in_the_last_component() raises:
    """200 keys that share every component but the last: any probe that walks
    past another group's slot meets the same leading components, so equality
    must read the last one too."""
    var p = IntPairKeyAggregator.create(num_aggs=1, initial_capacity=2)
    var t = IntTripleKeyAggregator.create(num_aggs=1, initial_capacity=2)
    for rep in range(2):
        for c in range(200):
            p.insert(Int64(5), Int64(c), 0, Float64(c))
            t.insert(Int64(7), Int64(-3), Int64(c), 0, Float64(c))
    assert_equal(p.num_groups, 200)
    assert_equal(t.num_groups, 200)
    for g in range(200):
        assert_equal(p.accumulators[g].sums[0], Float64(2 * g))
        assert_equal(t.accumulators[g].sums[0], Float64(2 * g))
        assert_equal(t.keys_c[g], Int64(g))


def _nkey(k: Int, n: Int) -> List[Int64]:
    """An n-component key; components 0..n-2 are 0 and the last carries k,
    so two keys differ only in their LAST component."""
    var out = List[Int64]()
    for _ in range(n - 1):
        out.append(Int64(0))
    out.append(Int64(k))
    return out^


def test_int_n_key_aggregator_every_component_counts() raises:
    for n in [4, 9]:
        var agg = IntNKeyAggregator.create(num_keys=n, num_aggs=2, initial_capacity=2)
        for rep in range(2):
            for k in range(N_KEYS):
                agg.insert(_nkey(k, n), 0, _val(k, rep))
                agg.insert_count(_nkey(k, n), 1)
        assert_equal(agg.num_groups, N_KEYS, "num_keys=" + String(n))
        for g in range(N_KEYS):
            var keys = agg.get_group_keys(g)
            assert_equal(len(keys), n)
            assert_equal(keys[n - 1], Int64(g))
            assert_equal(keys[0], Int64(0))
            assert_equal(agg.accumulators[g].sums[0], _val(g, 0) + _val(g, 1))
            assert_equal(agg.accumulators[g].counts[1], 2)


def test_int_n_key_aggregator_hashes_each_of_eight_positions() raises:
    """A key with a nonzero value in position p (p = 0..7) is a different
    group from the all-zero key and from the same value in another position."""
    var agg = IntNKeyAggregator.create(num_keys=8, num_aggs=1, initial_capacity=2)
    var zero = List[Int64]()
    for _ in range(8):
        zero.append(Int64(0))
    agg.insert(zero, 0, 1.0)
    for p in range(8):
        var k = zero.copy()
        k[p] = Int64(3)
        agg.insert(k, 0, Float64(p + 10))
        agg.insert(k, 0, Float64(p + 10))
    assert_equal(agg.num_groups, 9)
    for p in range(8):
        assert_equal(agg.accumulators[p + 1].sums[0], Float64(2 * (p + 10)))
        assert_equal(agg.get_group_keys(p + 1)[p], Int64(3))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
