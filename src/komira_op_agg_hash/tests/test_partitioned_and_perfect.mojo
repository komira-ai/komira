# =============================================================================
# Tests -- PartitionedFlatHashAggregator, PerfectHashAggregator and the
# flush window check
# =============================================================================
#
# Every value below is an exact small integer in Float64, so each sum,
# count, min and max is compared bit-exactly against a scalar oracle.
#
#   1. test_partitioned_inserts -- insert_1 / insert_2 / insert_n route each
#      key to one sub-table; per-key sums read back through `partition(p)`
#      match the oracle, and num_groups sums the sub-tables. Catches a
#      routing that splits one key over two sub-tables (a duplicated group)
#      or an insert_n that reads its keys from the wrong place. Two- and
#      N-key groups are read back by key tuple: (g % 5, g // 5) needs every
#      key column to tell the 50 groups apart.
#   1b. test_partition_is_hash_top_bits -- each group sits in the sub-table
#      named by the top 8 bits of its hash, 1- and 2-key, under skewed input;
#      the hot group's sum and count are exact.
#   2. test_perfect_hash_update_merge -- update / update_count_only / get_*
#      on a quartet layout, then merge of two halves equals one aggregator
#      fed everything. Catches a wrong slot or agg offset, a min/max fold
#      that drops a value, and a merge that double-counts.
#   3. test_flush_rejects_short_slab -- flush_to_partitions raises, and
#      writes nothing, when the slab holds fewer buffers than
#      `first + num_partitions`; a window that fits scatters every group.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_collections.slab import Slab
from komira_op_agg_hash.flat_hash_agg import FlatHashAggregator, _fib_hash_1
from komira_op_agg_hash.flat_hash_agg_hash import _fib_hash_2
from komira_op_agg_hash.flat_hash_agg_perfect import PerfectHashAggregator
from komira_op_agg_hash.flat_hash_partition_flush import FlatHashPartitionFlush
from komira_op_agg_hash.partitioned_flat_hash_agg import PartitionedFlatHashAggregator


def _value(r: Int) -> Float64:
    return Float64((r * 13) % 97) - 40.0


def test_partitioned_inserts() raises:
    var pagg = PartitionedFlatHashAggregator(num_keys=1, num_aggs=1)
    var num_keys = 300
    for r in range(3 * num_keys):
        pagg.insert_1(Int64(r % num_keys), _value(r))
    assert_equal(pagg.num_groups(), num_keys)
    for k in range(num_keys):
        var oracle = Float64(0.0)
        for r in range(3 * num_keys):
            if r % num_keys == k:
                oracle += _value(r)
        var h = _fib_hash_1(Int64(k))
        var hit = pagg.find_or_create_1_prehashed(Int64(k), h)
        ref sub = pagg.partition(hit[0])
        assert_equal(sub.get_sum(hit[1], 0), oracle)
        assert_equal(sub.get_count(hit[1], 0), 3)
    assert_equal(pagg.num_groups(), num_keys)

    # Two keys, and N keys through a span: 50 groups, each inserted twice.
    # The N-key tuples are (g % 5, g // 5, 7): no single key column tells
    # the 50 groups apart (column 0 has 5 values, column 1 has 10, column 2
    # one), so an insert_n that read fewer than all keys would merge groups.
    var pagg2 = PartitionedFlatHashAggregator(num_keys=2, num_aggs=1)
    var pagg3 = PartitionedFlatHashAggregator(num_keys=3, num_aggs=1)
    var keys3 = List[Int64]()
    keys3.append(0)
    keys3.append(0)
    keys3.append(7)
    for r in range(100):
        var g = r % 50
        pagg2.insert_2(Int64(g % 5), Int64(g // 5), Float64(g))
        keys3[0] = Int64(g % 5)
        keys3[1] = Int64(g // 5)
        pagg3.insert_n(Span(keys3), Float64(g))
    assert_equal(pagg2.num_groups(), 50)
    assert_equal(pagg3.num_groups(), 50)
    # Read every group back from its sub-table: the key tuple names the
    # group, and its sum and count are those of exactly that group's rows.
    var seen2 = List[Bool](length=50, fill=False)
    var seen3 = List[Bool](length=50, fill=False)
    for p in range(pagg2.num_partitions()):
        ref sub2 = pagg2.partition(p)
        for h in sub2.iter_entries():
            var k0 = sub2.get_key(h, 0)
            var k1 = sub2.get_key(h, 1)
            var g = Int(k1) * 5 + Int(k0)
            assert_true(k0 >= 0 and k0 < 5 and k1 >= 0 and k1 < 10)
            assert_true(not seen2[g])
            seen2[g] = True
            assert_equal(sub2.get_sum(h, 0), Float64(2 * g))
            assert_equal(sub2.get_count(h, 0), 2)
        ref sub3 = pagg3.partition(p)
        for h in sub3.iter_entries():
            var k0 = sub3.get_key(h, 0)
            var k1 = sub3.get_key(h, 1)
            assert_equal(sub3.get_key(h, 2), 7)
            var g = Int(k1) * 5 + Int(k0)
            assert_true(k0 >= 0 and k0 < 5 and k1 >= 0 and k1 < 10)
            assert_true(not seen3[g])
            seen3[g] = True
            assert_equal(sub3.get_sum(h, 0), Float64(2 * g))
            assert_equal(sub3.get_count(h, 0), 2)
    for g in range(50):
        assert_true(seen2[g] and seen3[g])


def test_partition_is_hash_top_bits() raises:
    # Every group lives in the sub-table named by the top RADIX_BITS of its
    # hash, under skewed input (90% of the rows on key 0), and the skewed
    # group's sum and count are exact. Catches routing by low bits, by a
    # different shift, or by the raw key.
    var pagg = PartitionedFlatHashAggregator(num_keys=1, num_aggs=1)
    var pagg2 = PartitionedFlatHashAggregator(num_keys=2, num_aggs=1)
    var num_rows = 10_000
    var hot_rows = 0
    for r in range(num_rows):
        var k = Int64(0) if r % 10 != 0 else Int64(r)
        if k == 0:
            hot_rows += 1
        pagg.insert_1(k, 1.0)
        pagg2.insert_2(k, k + 3, 1.0)
    assert_equal(pagg.num_groups(), 1 + num_rows // 10 - 1)
    assert_equal(pagg.shift(), 64 - 8)
    var used = 0
    for p in range(pagg.num_partitions()):
        ref sub = pagg.partition(p)
        if sub.num_groups() > 0:
            used += 1
        for h in sub.iter_entries():
            var k = sub.get_key(h, 0)
            assert_equal(Int(_fib_hash_1(k) >> UInt64(pagg.shift())), p)
            if k == 0:
                assert_equal(sub.get_count(h, 0), hot_rows)
                assert_equal(sub.get_sum(h, 0), Float64(hot_rows))
        ref sub2 = pagg2.partition(p)
        for h in sub2.iter_entries():
            var k0 = sub2.get_key(h, 0)
            var k1 = sub2.get_key(h, 1)
            assert_equal(k1, k0 + 3)
            assert_equal(Int(_fib_hash_2(k0, k1) >> UInt64(pagg2.shift())), p)
    # 1,000 keys over 256 partitions: a router that sent everything to a
    # handful of sub-tables would leave most of them empty.
    assert_true(used > 200)


def test_perfect_hash_update_merge() raises:
    var domain = 64
    var whole = PerfectHashAggregator(domain_size=domain, key_offset=0, num_aggs=2)
    var half_a = PerfectHashAggregator(domain_size=domain, key_offset=0, num_aggs=2)
    var half_b = PerfectHashAggregator(domain_size=domain, key_offset=0, num_aggs=2)
    var num_rows = 2_000
    for r in range(num_rows):
        var key = Int64(r % 49)
        whole.update(key, 0, _value(r))
        whole.update_count_only(key, 1)
        if r % 2 == 0:
            half_a.update(key, 0, _value(r))
            half_a.update_count_only(key, 1)
        else:
            half_b.update(key, 0, _value(r))
            half_b.update_count_only(key, 1)
    # 49 groups: a key's rows alternate between the halves, so the merge
    # combines two non-empty slots for every key.
    half_a.merge(half_b)
    for k in range(49):
        var osum = Float64(0.0)
        var ocount = 0
        var omin = Float64(1.0e30)
        var omax = Float64(-1.0e30)
        for r in range(num_rows):
            if r % 49 == k:
                var v = _value(r)
                osum += v
                ocount += 1
                omin = min(omin, v)
                omax = max(omax, v)
        assert_equal(whole.get_sum(k, 0), osum)
        assert_equal(whole.get_count(k, 0), ocount)
        assert_equal(whole.get_min(k, 0), omin)
        assert_equal(whole.get_max(k, 0), omax)
        assert_equal(whole.get_count(k, 1), ocount)
        assert_equal(half_a.get_sum(k, 0), osum)
        assert_equal(half_a.get_count(k, 0), ocount)
        assert_equal(half_a.get_min(k, 0), omin)
        assert_equal(half_a.get_max(k, 0), omax)
        assert_equal(half_a.get_count(k, 1), ocount)
    # Keys 49..63 were never touched.
    for k in range(49, domain):
        assert_equal(half_a.get_count(k, 0), 0)


def test_flush_rejects_short_slab() raises:
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1)
    for k in range(100):
        var h = agg.find_or_create_1(Int64(k))
        agg._update_agg(h, 0, 1.0)
    var slab = Slab[FlatHashPartitionFlush].with_capacity(16)
    for _ in range(16):
        slab.append(FlatHashPartitionFlush.new(agg.entry_stride()))
    var raised = False
    try:
        agg.flush_to_partitions(slab, 0, 256, UInt32(56))
    except:
        raised = True
    assert_true(raised)
    # Nothing was scattered before the refusal.
    for p in range(16):
        assert_equal(slab[p].num_groups, 0)
    # A fitting window succeeds: 16 partitions at shift 60.
    agg.flush_to_partitions(slab, 0, 16, UInt32(60))
    var total = 0
    for p in range(16):
        total += slab[p].num_groups
    assert_equal(total, 100)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
