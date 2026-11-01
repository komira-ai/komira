# =============================================================================
# Tests -- SlabStorage's composite-key table
# =============================================================================
#
# Every case inserts a known set of distinct keys, checks the group count,
# then re-probes each key and checks it finds its own group (was_new False,
# the same entry id):
#
#   1. one Int64 column (stride 8, the one-Int64 compare);
#   2. two Int64 columns (stride 16, the two-Int64 compare);
#   3. Int32 x Int64 (stride 12, the byte compare);
#   4. three Int64 columns (stride 24);
#   5. (0, 1) / (1, 0) and (42, 99) / (99, 42) are four groups: catches a
#      symmetric hash combiner (`h0 ^ h1`), which would make them two;
#   6. 500 keys from capacity 16: every key survives five rehashes;
#   7. two storages merged with `combine_donor_keys_with_struct` (50 keys
#      only in A, 25 in both, 50 only in B): A ends with 125 groups and every
#      count is the sum of both sides. 100 would mean the merge dropped
#      donor-only keys; 150 would mean it inserted overlapping keys twice;
#   8. one Float64 column: equal bit patterns are one group;
#   9. a key span or an output span of the wrong length raises instead of
#      reading or writing past its end.
# =============================================================================

from std.memory import UnsafePointer
from std.testing import TestSuite, assert_equal, assert_true

from std.collections.optional import Optional

from komira_op_agg_slab.slab_storage import SlabStorage
from komira_op_agg_state.aggregators_struct_builtin import CountAggregator


# -----------------------------------------------------------------------------
# Test 1 — single-col Int64 (1-key equivalence through byte-slab path)
# -----------------------------------------------------------------------------


def test_ck_single_col_int64_1k_groups() raises:
    """Insert 1000 distinct Int64 keys through `init_multi_key_mode` and
    `probe_or_insert_multi_key`; each re-probe finds its own group."""
    comptime N = 1000

    var s = SlabStorage(
        num_keys=1, num_aggs=0, initial_capacity=2048
    )
    var schema = List[DType]()
    schema.append(DType.int64)
    s.init_multi_key_mode(schema^)

    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=8)
    for i in range(N):
        (buf.unsafe_ptr().bitcast[Int64]())[] = Int64(i)
        var pair = s.probe_or_insert_multi_key(Span(buf))
        assert_equal(pair[1], True)  # was_new
        assert_equal(Int(pair[0]._entry_idx), i)

    assert_equal(s.num_groups(), N)

    # Re-probe: every key must map to the same eid with was_new=False.
    for i in range(N):
        (buf.unsafe_ptr().bitcast[Int64]())[] = Int64(i)
        var pair = s.probe_or_insert_multi_key(Span(buf))
        assert_equal(pair[1], False)
        assert_equal(Int(pair[0]._entry_idx), i)

    assert_equal(s.num_groups(), N)


# -----------------------------------------------------------------------------
# Test 2 — 2-key Int64xInt64
# -----------------------------------------------------------------------------


def test_ck_two_int64_keys_10k_groups_parity() raises:
    """10K distinct (k0, k1) pairs in [0,100) x [0,100) over a 16-byte
    stride; re-inserting every pair adds no group."""
    comptime K = 100
    comptime N_GROUPS = K * K  # 10_000

    var s = SlabStorage(
        num_keys=2, num_aggs=0, initial_capacity=16384
    )
    var schema = List[DType]()
    schema.append(DType.int64)
    schema.append(DType.int64)
    s.init_multi_key_mode(schema^)

    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=16)
    var ptr_i64 = buf.unsafe_ptr().bitcast[Int64]()
    for k0 in range(K):
        for k1 in range(K):
            ptr_i64[] = Int64(k0)
            (ptr_i64 + 1)[] = Int64(k1)
            var pair = s.probe_or_insert_multi_key(Span(buf))
            assert_equal(pair[1], True)

    assert_equal(s.num_groups(), N_GROUPS)

    # Re-insert duplicates: num_groups must NOT change.
    for k0 in range(K):
        for k1 in range(K):
            ptr_i64[] = Int64(k0)
            (ptr_i64 + 1)[] = Int64(k1)
            var pair = s.probe_or_insert_multi_key(Span(buf))
            assert_equal(pair[1], False)

    assert_equal(s.num_groups(), N_GROUPS)


# -----------------------------------------------------------------------------
# Test 3 — mixed-width Int32xInt64 (12-byte stride)
# -----------------------------------------------------------------------------


def test_ck_mixed_int32_int64_200_groups() raises:
    """200 distinct (Int32, Int64) pairs in [0,20) x [0,10) over a
    12-byte stride. Validates that the byte-slab key path correctly
    packs unequal-width columns at the per-column offsets recorded by
    `init_multi_key_mode`."""
    var s = SlabStorage(
        num_keys=2, num_aggs=0, initial_capacity=512
    )
    var schema = List[DType]()
    schema.append(DType.int32)
    schema.append(DType.int64)
    s.init_multi_key_mode(schema^)

    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=12)

    var inserted = 0
    for k0 in range(20):
        for k1 in range(10):
            (buf.unsafe_ptr().bitcast[Int32]())[] = Int32(k0)
            ((buf.unsafe_ptr() + 4).bitcast[Int64]())[] = Int64(k1)
            var pair = s.probe_or_insert_multi_key(Span(buf))
            assert_equal(pair[1], True)
            inserted += 1

    assert_equal(inserted, 200)
    assert_equal(s.num_groups(), 200)

    # Duplicate insertion: num_groups unchanged.
    for k0 in range(20):
        for k1 in range(10):
            (buf.unsafe_ptr().bitcast[Int32]())[] = Int32(k0)
            ((buf.unsafe_ptr() + 4).bitcast[Int64]())[] = Int64(k1)
            var pair = s.probe_or_insert_multi_key(Span(buf))
            assert_equal(pair[1], False)

    assert_equal(s.num_groups(), 200)


# -----------------------------------------------------------------------------
# Test 4 — 3-key Int64xInt64xInt64 (24-byte stride)
# -----------------------------------------------------------------------------


def test_ck_three_int64_keys_125_groups() raises:
    """125 distinct (k0, k1, k2) triples in [0,5) x [0,5) x [0,5) over a
    24-byte stride (more than two key columns)."""
    var s = SlabStorage(
        num_keys=3, num_aggs=0, initial_capacity=512
    )
    var schema = List[DType]()
    schema.append(DType.int64)
    schema.append(DType.int64)
    schema.append(DType.int64)
    s.init_multi_key_mode(schema^)

    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=24)
    var ptr_i64 = buf.unsafe_ptr().bitcast[Int64]()

    for k0 in range(5):
        for k1 in range(5):
            for k2 in range(5):
                ptr_i64[] = Int64(k0)
                (ptr_i64 + 1)[] = Int64(k1)
                (ptr_i64 + 2)[] = Int64(k2)
                var pair = s.probe_or_insert_multi_key(Span(buf))
                assert_equal(pair[1], True)

    assert_equal(s.num_groups(), 125)

    # Re-probe each triple: was_new=False everywhere, count unchanged.
    for k0 in range(5):
        for k1 in range(5):
            for k2 in range(5):
                ptr_i64[] = Int64(k0)
                (ptr_i64 + 1)[] = Int64(k1)
                (ptr_i64 + 2)[] = Int64(k2)
                var pair = s.probe_or_insert_multi_key(Span(buf))
                assert_equal(pair[1], False)

    assert_equal(s.num_groups(), 125)


# -----------------------------------------------------------------------------
# Test 5 — asymmetry across key order
# -----------------------------------------------------------------------------


def test_ck_asymmetry_across_key_order() raises:
    """`(0, 1)`, `(1, 0)`, `(42, 99)`, `(99, 42)` MUST all be distinct
    groups under the composite hash combiner. A symmetric combiner
    (e.g. `h0 ^ h1`) would silently collapse `(0,1)`/`(1,0)` and
    `(42,99)`/`(99,42)` to 2 groups instead of 4. Guard against any
    future regression that introduces one."""
    var s = SlabStorage(
        num_keys=2, num_aggs=0, initial_capacity=64
    )
    var schema = List[DType]()
    schema.append(DType.int64)
    schema.append(DType.int64)
    s.init_multi_key_mode(schema^)

    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=16)
    var ptr_i64 = buf.unsafe_ptr().bitcast[Int64]()

    # (0, 1)
    ptr_i64[] = Int64(0)
    (ptr_i64 + 1)[] = Int64(1)
    var p_01 = s.probe_or_insert_multi_key(Span(buf))
    assert_equal(p_01[1], True)
    var eid_01 = Int(p_01[0]._entry_idx)

    # (1, 0)
    ptr_i64[] = Int64(1)
    (ptr_i64 + 1)[] = Int64(0)
    var p_10 = s.probe_or_insert_multi_key(Span(buf))
    assert_equal(p_10[1], True)
    var eid_10 = Int(p_10[0]._entry_idx)

    # (42, 99)
    ptr_i64[] = Int64(42)
    (ptr_i64 + 1)[] = Int64(99)
    var p_4299 = s.probe_or_insert_multi_key(Span(buf))
    assert_equal(p_4299[1], True)
    var eid_4299 = Int(p_4299[0]._entry_idx)

    # (99, 42)
    ptr_i64[] = Int64(99)
    (ptr_i64 + 1)[] = Int64(42)
    var p_9942 = s.probe_or_insert_multi_key(Span(buf))
    assert_equal(p_9942[1], True)
    var eid_9942 = Int(p_9942[0]._entry_idx)

    assert_true(eid_01 != eid_10)
    assert_true(eid_4299 != eid_9942)
    assert_true(eid_01 != eid_4299)
    assert_true(eid_10 != eid_9942)
    assert_equal(s.num_groups(), 4)


# -----------------------------------------------------------------------------
# Test 6 — forced multi-rehash (initial_capacity=16, 500 inserts)
# -----------------------------------------------------------------------------


def test_ck_forced_multi_rehash_500_inserts() raises:
    """Start at the smallest valid initial_capacity (16). Insert 500
    distinct Int64 keys. The 0.7 load factor trips at ~12 inserts, so
    the byte-slab rehash path must run at least ~5 times (16 → 32 → 64
    → 128 → 256 → 512). Every key must remain retrievable post-rehash
    with a stable entry_id."""
    comptime N = 500
    var s = SlabStorage(
        num_keys=1, num_aggs=0, initial_capacity=16
    )
    var schema = List[DType]()
    schema.append(DType.int64)
    s.init_multi_key_mode(schema^)

    var inserted_eids = List[Int](capacity=N)
    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=8)

    for i in range(N):
        # Deterministic but non-trivial key; avoid k=i which we already
        # exercised in Test 1.
        (buf.unsafe_ptr().bitcast[Int64]())[] = Int64(i * 17 + 1)
        var pair = s.probe_or_insert_multi_key(Span(buf))
        assert_equal(pair[1], True)
        inserted_eids.append(Int(pair[0]._entry_idx))

    assert_equal(s.num_groups(), N)
    # Capacity must have grown well past 16.
    assert_true(s.capacity() >= 512)

    # Re-probe each key: same eid, was_new=False.
    for i in range(N):
        (buf.unsafe_ptr().bitcast[Int64]())[] = Int64(i * 17 + 1)
        var pair = s.probe_or_insert_multi_key(Span(buf))
        assert_equal(pair[1], False)
        assert_equal(Int(pair[0]._entry_idx), inserted_eids[i])


# -----------------------------------------------------------------------------
# Test 7 — combine_donor_keys_with_struct 2-worker merge with overlap
# -----------------------------------------------------------------------------


def _count_storage() raises -> SlabStorage:
    """A 2 x Int64-keyed storage with one CountAggregator."""
    var strides = List[Int]()
    strides.append(CountAggregator.STATE_BYTES)
    var s = SlabStorage(
        num_keys=2,
        num_aggs=1,
        initial_capacity=256,
        agg_state_strides_in=Optional[List[Int]](strides^),
    )
    var schema = List[DType]()
    schema.append(DType.int64)
    schema.append(DType.int64)
    s.init_multi_key_mode(schema^)
    return s^


def _count_key(
    mut s: SlabStorage, mut buf: List[UInt8], k0: Int, k1: Int, times: Int
) raises:
    """Count the key (k0, k1) `times` times into `s`."""
    var ptr_i64 = buf.unsafe_ptr().bitcast[Int64]()
    ptr_i64[] = Int64(k0)
    (ptr_i64 + 1)[] = Int64(k1)
    var pair = s.probe_or_insert_multi_key(Span(buf))
    if pair[1]:
        s.init_state_with_struct[0, CountAggregator](pair[0])
    var eids = List[Int32](length=times, fill=pair[0]._entry_idx)
    var vals = List[Int64](length=times, fill=1)
    var vbytes = Span[UInt8, origin_of(vals)](
        unsafe_ptr=vals.unsafe_ptr().bitcast[UInt8](), length=times * 8
    )
    s.commit_aggregator_with_struct[0, CountAggregator](
        Span(eids), vbytes, times
    )


def test_ck_combine_donor_keys_2worker_overlap() raises:
    """A holds 50 A-only keys (count 1 each) and 25 shared keys (count 2);
    B holds the 25 shared keys (count 3) and 50 B-only keys (count 4).
    After `A.combine_donor_keys_with_struct[CountAggregator](B)`, A holds
    125 groups: A-only count 1, shared count 5, B-only count 4."""
    var a = _count_storage()
    var b = _count_storage()
    var buf = List[UInt8](length=16, fill=0)
    for i in range(50):
        _count_key(a, buf, i, 1000, 1)
    for i in range(100, 125):
        _count_key(a, buf, i, 2000, 2)
        _count_key(b, buf, i, 2000, 3)
    for i in range(200, 250):
        _count_key(b, buf, i, 3000, 4)
    assert_equal(a.num_groups(), 75)
    assert_equal(b.num_groups(), 75)

    a.combine_donor_keys_with_struct[CountAggregator](b)
    assert_equal(a.num_groups(), 125)

    var n = a.num_groups()
    var counts = List[Int64](length=n, fill=0)
    var counts_bytes = Span[UInt8, origin_of(counts)](
        unsafe_ptr=counts.unsafe_ptr().bitcast[UInt8](), length=n * 8
    )
    a.finalize_aggregator_with_struct[0, CountAggregator](counts_bytes)
    var k0s = List[Int64](length=n, fill=0)
    var k1s = List[Int64](length=n, fill=0)
    var k0_bytes = Span[UInt8, origin_of(k0s)](
        unsafe_ptr=k0s.unsafe_ptr().bitcast[UInt8](), length=n * 8
    )
    var k1_bytes = Span[UInt8, origin_of(k1s)](
        unsafe_ptr=k1s.unsafe_ptr().bitcast[UInt8](), length=n * 8
    )
    a.finalize_keys_multi_2col(k0_bytes, k1_bytes)
    var seen = 0
    for g in range(n):
        var want: Int64 = 0
        if k1s[g] == 1000:
            want = 1
        elif k1s[g] == 2000:
            want = 5
        elif k1s[g] == 3000:
            want = 4
        assert_equal(counts[g], want)
        seen += 1
    assert_equal(seen, 125)

    # Every key, from either side, now resolves to an existing group.
    for i in range(50):
        _count_key(a, buf, i, 1000, 0)
    for i in range(100, 125):
        _count_key(a, buf, i, 2000, 0)
    for i in range(200, 250):
        _count_key(a, buf, i, 3000, 0)
    assert_equal(a.num_groups(), 125)


# -----------------------------------------------------------------------------
# Test 8 — Float64 key column (bit-identical hash)
# -----------------------------------------------------------------------------


def test_ck_float64_single_col_100_groups() raises:
    """Insert 100 distinct Float64 values via the byte-slab path. Same
    bit pattern means same group; the byte-slab path's `_ck_memcmp_keys`
    checks exact byte equality so two Float64s with the same bits hash
    to the same slot AND match on probe.

    NaN is not exercised here. NaN's behavior under bitwise byte-equality
    is implementation-defined: two NaNs with the same bit pattern would
    map to the same group (correct under the byte-slab model), but two
    NaNs with different payload bits would not — that is correct under
    the byte-equality contract but surprising under IEEE-754 semantics.
    The struct sinks key on Int64 columns only, so no query reaches
    this path with a float key today."""
    comptime N = 100
    var s = SlabStorage(
        num_keys=1, num_aggs=0, initial_capacity=512
    )
    var schema = List[DType]()
    schema.append(DType.float64)
    s.init_multi_key_mode(schema^)

    var buf = List[UInt8]()
    buf.resize(unsafe_uninit_length=8)
    var ptr_f64 = buf.unsafe_ptr().bitcast[Float64]()

    for i in range(N):
        # Choose values whose bit patterns differ across i. `Float64(i) +
        # 0.5` generates 100 distinct finite floats.
        ptr_f64[] = Float64(i) + 0.5
        var pair = s.probe_or_insert_multi_key(Span(buf))
        assert_equal(pair[1], True)

    assert_equal(s.num_groups(), N)

    # Re-probe each value: same group, was_new=False.
    for i in range(N):
        ptr_f64[] = Float64(i) + 0.5
        var pair = s.probe_or_insert_multi_key(Span(buf))
        assert_equal(pair[1], False)

    assert_equal(s.num_groups(), N)


# -----------------------------------------------------------------------------
# Test 9 — spans of the wrong length raise
# -----------------------------------------------------------------------------


def test_ck_wrong_length_spans_raise() raises:
    """The key and output spans are checked against the key stride and the
    group count: a 12-byte key for a 16-byte stride, or an 8-byte output
    for two groups, raises rather than reading or writing past the span."""
    var s = SlabStorage(num_keys=2, num_aggs=0, initial_capacity=64)
    var short_key = List[UInt8](length=12, fill=0)
    var raised = False
    try:
        _ = s.probe_or_insert_multi_key(Span(short_key))
    except:
        raised = True
    assert_true(raised, "a 12-byte key for a 16-byte stride must raise")
    raised = False
    try:
        _ = s.probe_or_insert_multi_key_with_hash(UInt64(7), Span(short_key))
    except:
        raised = True
    assert_true(raised, "the hashed probe must check the key length too")
    assert_equal(s.num_groups(), 0)

    var one = SlabStorage(num_keys=1, num_aggs=0, initial_capacity=64)
    var key = List[UInt8](length=8, fill=0)
    _ = one.probe_or_insert_multi_key(Span(key))
    key[0] = 1
    _ = one.probe_or_insert_multi_key(Span(key))
    assert_equal(one.num_groups(), 2)
    var out = List[UInt8](length=8, fill=0)
    raised = False
    try:
        one.finalize_keys_int64(Span(out))
    except:
        raised = True
    assert_true(raised, "an 8-byte output for two keys must raise")


def main() raises:
    var suite = TestSuite()
    suite.test[test_ck_single_col_int64_1k_groups]()
    suite.test[test_ck_two_int64_keys_10k_groups_parity]()
    suite.test[test_ck_mixed_int32_int64_200_groups]()
    suite.test[test_ck_three_int64_keys_125_groups]()
    suite.test[test_ck_asymmetry_across_key_order]()
    suite.test[test_ck_forced_multi_rehash_500_inserts]()
    suite.test[test_ck_combine_donor_keys_2worker_overlap]()
    suite.test[test_ck_wrong_length_spans_raise]()
    suite.test[test_ck_float64_single_col_100_groups]()
    suite^.run()
