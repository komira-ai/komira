# =============================================================================
# Tests for FlatHashAggregator -- the split-index aggregation hash table
# =============================================================================
#
# Verifies:
# 1. Basic single-key insert and lookup
# 2. Multi-key insert and lookup (2-key, N-key)
# 3. Accumulator correctness: SUM, COUNT, MIN, MAX, AVG
# 4. Resize at load factor boundary
# 5. Multi-agg per group (probe once, update many)
# 6. Edge cases: empty table, single group, all-same-key
# 7. High cardinality (100K groups)
# =============================================================================

from std.testing import assert_equal, assert_true
from std.memory import UnsafePointer, alloc
from komira_op_agg_hash.flat_hash_agg import FlatHashAggregator


def test_basic_single_key() raises:
    """Single key, single agg: 3 groups, verify SUM/COUNT/MIN/MAX."""
    print("test_basic_single_key...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=16)
    assert_equal(agg.num_groups(), 0)

    # Group key=10: values 1.0, 2.0, 3.0 -> sum=6, count=3, min=1, max=3
    var e1 = agg.find_or_create_1(Int64(10))
    agg._update_agg(e1, 0, 1.0)
    var e1b = agg.find_or_create_1(Int64(10))
    agg._update_agg(e1b, 0, 2.0)
    var e1c = agg.find_or_create_1(Int64(10))
    agg._update_agg(e1c, 0, 3.0)

    # Group key=20: values 10.0, 20.0 -> sum=30, count=2, min=10, max=20
    var e2 = agg.find_or_create_1(Int64(20))
    agg._update_agg(e2, 0, 10.0)
    var e2b = agg.find_or_create_1(Int64(20))
    agg._update_agg(e2b, 0, 20.0)

    # Group key=30: value 100.0 -> sum=100, count=1, min=100, max=100
    var e3 = agg.find_or_create_1(Int64(30))
    agg._update_agg(e3, 0, 100.0)

    assert_equal(agg.num_groups(), 3)

    # Verify group 10
    var g10 = agg.find_or_create_1(Int64(10))
    assert_equal(agg.get_sum(g10, 0), 6.0)
    assert_equal(agg.get_count(g10, 0), 3)
    assert_equal(agg.get_min(g10, 0), 1.0)
    assert_equal(agg.get_max(g10, 0), 3.0)
    assert_equal(agg.get_avg(g10, 0), 2.0)

    # Verify group 20
    var g20 = agg.find_or_create_1(Int64(20))
    assert_equal(agg.get_sum(g20, 0), 30.0)
    assert_equal(agg.get_count(g20, 0), 2)
    assert_equal(agg.get_min(g20, 0), 10.0)
    assert_equal(agg.get_max(g20, 0), 20.0)

    # Verify group 30
    var g30 = agg.find_or_create_1(Int64(30))
    assert_equal(agg.get_sum(g30, 0), 100.0)
    assert_equal(agg.get_count(g30, 0), 1)

    # Still 3 groups (find_or_create doesn't add new ones for existing keys)
    assert_equal(agg.num_groups(), 3)

    _ = agg  # keepalive
    print("  PASS")


def test_multi_agg_single_key() raises:
    """Single key, 3 aggs per group: SUM, COUNT_ONLY, SUM."""
    print("test_multi_agg_single_key...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=3)

    # Row: key=1, values=[10.0, count_only, 5.0]
    var e = agg.find_or_create_1(Int64(1))
    agg._update_agg(e, 0, 10.0)
    agg._update_count_only(e, 1)
    agg._update_agg(e, 2, 5.0)

    # Second row same key
    var e2 = agg.find_or_create_1(Int64(1))
    agg._update_agg(e2, 0, 20.0)
    agg._update_count_only(e2, 1)
    agg._update_agg(e2, 2, 15.0)

    assert_equal(agg.num_groups(), 1)

    var g = agg.find_or_create_1(Int64(1))
    # agg slot 0: sum=30
    assert_equal(agg.get_sum(g, 0), 30.0)
    assert_equal(agg.get_count(g, 0), 2)
    # agg slot 1: count_only -> count=2, sum=0
    assert_equal(agg.get_count(g, 1), 2)
    assert_equal(agg.get_sum(g, 1), 0.0)
    # agg slot 2: sum=20
    assert_equal(agg.get_sum(g, 2), 20.0)
    assert_equal(agg.get_count(g, 2), 2)
    assert_equal(agg.get_min(g, 2), 5.0)
    assert_equal(agg.get_max(g, 2), 15.0)

    _ = agg
    print("  PASS")


def test_two_key() raises:
    """Two-key GROUP BY: (k0, k1) -> agg."""
    print("test_two_key...")
    var agg = FlatHashAggregator(num_keys=2, num_aggs=1, initial_capacity=16)

    # Group (1, 2): values 10, 20
    var e = agg.find_or_create_2(Int64(1), Int64(2))
    agg._update_agg(e, 0, 10.0)
    var e2 = agg.find_or_create_2(Int64(1), Int64(2))
    agg._update_agg(e2, 0, 20.0)

    # Group (1, 3): value 100
    var e3 = agg.find_or_create_2(Int64(1), Int64(3))
    agg._update_agg(e3, 0, 100.0)

    # Group (2, 2): value 50
    var e4 = agg.find_or_create_2(Int64(2), Int64(2))
    agg._update_agg(e4, 0, 50.0)

    assert_equal(agg.num_groups(), 3)

    # Verify (1, 2)
    var g12 = agg.find_or_create_2(Int64(1), Int64(2))
    assert_equal(agg.get_sum(g12, 0), 30.0)
    assert_equal(agg.get_count(g12, 0), 2)

    # Verify (1, 3)
    var g13 = agg.find_or_create_2(Int64(1), Int64(3))
    assert_equal(agg.get_sum(g13, 0), 100.0)
    assert_equal(agg.get_count(g13, 0), 1)

    # Verify (2, 2)
    var g22 = agg.find_or_create_2(Int64(2), Int64(2))
    assert_equal(agg.get_sum(g22, 0), 50.0)

    _ = agg
    print("  PASS")


def test_n_key() raises:
    """N-key GROUP BY with 4 keys."""
    print("test_n_key...")
    var agg = FlatHashAggregator(num_keys=4, num_aggs=2, initial_capacity=16)

    # SAFETY: Heap-allocated key buffer for passing to find_or_create_n
    var keys_buf = alloc[Int64](4)

    # Group (1, 2, 3, 4): value slots [10.0, 5.0]
    keys_buf[] = Int64(1)
    (keys_buf + 1)[] = Int64(2)
    (keys_buf + 2)[] = Int64(3)
    (keys_buf + 3)[] = Int64(4)
    var e = agg._find_or_create_n(keys_buf, 4)
    agg._update_agg(e, 0, 10.0)
    agg._update_agg(e, 1, 5.0)

    # Same group again
    var e2 = agg._find_or_create_n(keys_buf, 4)
    agg._update_agg(e2, 0, 20.0)
    agg._update_agg(e2, 1, 15.0)

    # Different group: (1, 2, 3, 5)
    (keys_buf + 3)[] = Int64(5)
    var e3 = agg._find_or_create_n(keys_buf, 4)
    agg._update_agg(e3, 0, 100.0)
    agg._update_agg(e3, 1, 200.0)

    assert_equal(agg.num_groups(), 2)

    # Verify (1, 2, 3, 4)
    (keys_buf + 3)[] = Int64(4)
    var g1 = agg._find_or_create_n(keys_buf, 4)
    assert_equal(agg.get_sum(g1, 0), 30.0)
    assert_equal(agg.get_count(g1, 0), 2)
    assert_equal(agg.get_sum(g1, 1), 20.0)

    # Verify key extraction
    assert_equal(agg.get_key(g1, 0), Int64(1))
    assert_equal(agg.get_key(g1, 1), Int64(2))
    assert_equal(agg.get_key(g1, 2), Int64(3))
    assert_equal(agg.get_key(g1, 3), Int64(4))

    keys_buf.free()
    _ = agg
    print("  PASS")


def test_resize() raises:
    """Resize at load factor boundary."""
    print("test_resize...")
    # Start with capacity 8 (70% = 5 groups triggers resize)
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=8)

    # Insert 10 groups -- forces at least one resize
    for i in range(10):
        var e = agg.find_or_create_1(Int64(i * 100))
        agg._update_agg(e, 0, Float64(i))

    assert_equal(agg.num_groups(), 10)

    # Verify all groups are still correct after resize
    for i in range(10):
        var e = agg.find_or_create_1(Int64(i * 100))
        assert_equal(agg.get_sum(e, 0), Float64(i))
        assert_equal(agg.get_count(e, 0), 1)

    # No new groups should have been created
    assert_equal(agg.num_groups(), 10)

    _ = agg
    print("  PASS")


def test_empty_table() raises:
    """Empty table: zero groups, iter_entries returns empty."""
    print("test_empty_table...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1)
    assert_equal(agg.num_groups(), 0)
    var entries = agg.iter_entries()
    assert_equal(len(entries), 0)
    _ = agg
    print("  PASS")


def test_single_group() raises:
    """All rows map to the same group."""
    print("test_single_group...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1)

    for i in range(1000):
        var e = agg.find_or_create_1(Int64(42))
        agg._update_agg(e, 0, Float64(i))

    assert_equal(agg.num_groups(), 1)

    var g = agg.find_or_create_1(Int64(42))
    # sum = 0 + 1 + ... + 999 = 999 * 1000 / 2 = 499500
    assert_equal(agg.get_sum(g, 0), 499500.0)
    assert_equal(agg.get_count(g, 0), 1000)
    assert_equal(agg.get_min(g, 0), 0.0)
    assert_equal(agg.get_max(g, 0), 999.0)

    _ = agg
    print("  PASS")


def test_high_cardinality() raises:
    """Verify 100K groups: correctness at scale."""
    print("test_high_cardinality (100K groups)...")
    var num_groups_target = 100_000
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=1024)

    # Insert 100K distinct keys, each with one value equal to the key
    for i in range(num_groups_target):
        var e = agg.find_or_create_1(Int64(i))
        agg._update_agg(e, 0, Float64(i))

    assert_equal(agg.num_groups(), num_groups_target)

    # Spot-check a few groups
    var g0 = agg.find_or_create_1(Int64(0))
    assert_equal(agg.get_sum(g0, 0), 0.0)

    var g999 = agg.find_or_create_1(Int64(999))
    assert_equal(agg.get_sum(g999, 0), 999.0)

    var g_last = agg.find_or_create_1(Int64(num_groups_target - 1))
    assert_equal(agg.get_sum(g_last, 0), Float64(num_groups_target - 1))

    # iter_entries should return exactly 100K entries
    var entries = agg.iter_entries()
    assert_equal(len(entries), num_groups_target)

    assert_equal(agg.num_groups(), num_groups_target)

    _ = agg
    print("  PASS")


def test_iter_entries() raises:
    """Iter_entries returns all occupied entries with correct data."""
    print("test_iter_entries...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1)

    for i in range(5):
        var e = agg.find_or_create_1(Int64(i * 10))
        agg._update_agg(e, 0, Float64(i * 10))

    var entries = agg.iter_entries()
    assert_equal(len(entries), 5)

    # Collect all keys from entries
    var found_keys = List[Int64]()
    for i in range(len(entries)):
        found_keys.append(agg.get_key(entries[i], 0))

    # All 5 keys should be present (order not guaranteed due to hashing)
    for target in range(5):
        var key = Int64(target * 10)
        var found = False
        for i in range(len(found_keys)):
            if found_keys[i] == key:
                found = True
                break
        assert_true(found, "Key " + String(Int(key)) + " not found in iter_entries")

    _ = agg
    print("  PASS")


def test_negative_keys() raises:
    """Negative key values hash correctly."""
    print("test_negative_keys...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1)

    var e_neg = agg.find_or_create_1(Int64(-42))
    agg._update_agg(e_neg, 0, 1.0)

    var e_zero = agg.find_or_create_1(Int64(0))
    agg._update_agg(e_zero, 0, 2.0)

    var e_pos = agg.find_or_create_1(Int64(42))
    agg._update_agg(e_pos, 0, 3.0)

    assert_equal(agg.num_groups(), 3)

    var g = agg.find_or_create_1(Int64(-42))
    assert_equal(agg.get_sum(g, 0), 1.0)

    _ = agg
    print("  PASS")


def test_two_key_many_groups() raises:
    """Two-key with 1000 groups to exercise resize."""
    print("test_two_key_many_groups...")
    var agg = FlatHashAggregator(num_keys=2, num_aggs=1, initial_capacity=16)

    for i in range(100):
        for j in range(10):
            var e = agg.find_or_create_2(Int64(i), Int64(j))
            agg._update_agg(e, 0, Float64(i * 10 + j))

    assert_equal(agg.num_groups(), 1000)

    # Spot-check
    var g = agg.find_or_create_2(Int64(50), Int64(7))
    assert_equal(agg.get_sum(g, 0), 507.0)
    assert_equal(agg.get_count(g, 0), 1)

    _ = agg
    print("  PASS")


def test_two_key_hash_matches_n_key() raises:
    """REGRESSION: find_or_create_2 must produce the same group ID as
    _find_or_create_n([k0, k1], 2).

    It catches a find_or_create_2 whose 2-key hash mismatches
    _fib_hash_n, which duplicates groups on cross-path merges.
    """
    print("test_two_key_hash_matches_n_key...")
    var agg = FlatHashAggregator(num_keys=2, num_aggs=1, initial_capacity=64)

    # SAFETY: heap key buffer for _find_or_create_n.
    var keys_buf = alloc[Int64](2)

    # Insert 50 distinct (k0, k1) pairs via find_or_create_2.
    for i in range(50):
        var k0 = Int64(i)
        var k1 = Int64(i * 7 + 3)
        var e = agg.find_or_create_2(k0, k1)
        agg._update_agg(e, 0, Float64(i))

    assert_equal(agg.num_groups(), 50)

    # Now look up every pair via _find_or_create_n.  If the two insert
    # paths use different hash functions, _find_or_create_n will start
    # its probe at a different slot and fail to find the existing
    # entry, silently creating a new one.  That would push num_groups
    # above 50.
    for i in range(50):
        keys_buf[] = Int64(i)
        (keys_buf + 1)[] = Int64(i * 7 + 3)
        var e = agg._find_or_create_n(keys_buf, 2)
        # The retrieved entry must match what find_or_create_2 inserted.
        assert_equal(agg.get_sum(e, 0), Float64(i))
        assert_equal(agg.get_count(e, 0), 1)

    # Crucial invariant: no new groups should have been created.
    assert_equal(agg.num_groups(), 50)

    # And the reverse direction: insert via N-key, look up via 2-key.
    var agg2 = FlatHashAggregator(num_keys=2, num_aggs=1, initial_capacity=64)
    for i in range(50):
        keys_buf[] = Int64(100 + i)
        (keys_buf + 1)[] = Int64(200 + i * 3)
        var e = agg2._find_or_create_n(keys_buf, 2)
        agg2._update_agg(e, 0, Float64(i * 2))

    assert_equal(agg2.num_groups(), 50)

    for i in range(50):
        var e = agg2.find_or_create_2(Int64(100 + i), Int64(200 + i * 3))
        assert_equal(agg2.get_sum(e, 0), Float64(i * 2))
        assert_equal(agg2.get_count(e, 0), 1)

    assert_equal(agg2.num_groups(), 50)

    keys_buf.free()
    _ = agg
    _ = agg2
    print("  PASS")


def test_count_only_agg() raises:
    """COUNT(*) only updates count, sum stays 0."""
    print("test_count_only_agg...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1)

    for _ in range(100):
        var e = agg.find_or_create_1(Int64(1))
        agg._update_count_only(e, 0)

    var g = agg.find_or_create_1(Int64(1))
    assert_equal(agg.get_count(g, 0), 100)
    assert_equal(agg.get_sum(g, 0), 0.0)

    _ = agg
    print("  PASS")


def test_ensure_merge_capacity_grows_once() raises:
    """Pre-reserve for a bulk-merge: HT jumps to >= target once."""
    print("test_ensure_merge_capacity_grows_once...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=16)
    assert_equal(agg.capacity(), 16)

    agg.ensure_merge_capacity(500)
    # ceil(500 * 10/7) = 715 -> next pow2 = 1024.
    assert_true(agg.capacity() >= 1024)
    assert_equal(agg.num_groups(), 0)

    # Subsequent inserts should not trigger another resize.
    var cap_before = agg.capacity()
    for i in range(500):
        var e = agg.find_or_create_1(Int64(i))
        agg._update_agg(e, 0, Float64(1.0))
    assert_equal(agg.num_groups(), 500)
    assert_equal(agg.capacity(), cap_before)

    _ = agg
    print("  PASS")


def test_ensure_merge_capacity_preserves_entries() raises:
    """Live entries survive the pre-grow rehash bit-for-bit."""
    print("test_ensure_merge_capacity_preserves_entries...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=16)

    for i in range(10):
        var e = agg.find_or_create_1(Int64(i))
        agg._update_agg(e, 0, Float64(i * 10))

    agg.ensure_merge_capacity(2000)
    # ceil(2010 * 10/7) = 2872 -> next pow2 = 4096.
    assert_true(agg.capacity() >= 4096)

    # Re-probe original keys; values must match.
    for i in range(10):
        var e = agg.find_or_create_1(Int64(i))
        assert_equal(agg.get_sum(e, 0), Float64(i * 10))
        assert_equal(agg.get_count(e, 0), 1)

    _ = agg
    print("  PASS")


def test_pre_grow_absolute() raises:
    """pre_grow(target) sizes to an absolute target; monotonic."""
    print("test_pre_grow_absolute...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=16)
    agg.pre_grow(1000)
    # ceil(1000 * 10/7) = 1429 -> next pow2 = 2048.
    assert_true(agg.capacity() >= 2048)
    var cap_first = agg.capacity()
    agg.pre_grow(50)  # no-op
    assert_equal(agg.capacity(), cap_first)
    _ = agg
    print("  PASS")


def test_entries_capacity_first_touch_pre_sized() raises:
    """The first _grow_entries_capacity sizes to >= 8192 entries. Guards
    against lowering _ENTRY_BLOCK_SIZE back to 2048, which costs 3
    reallocs per partition fill on large-cardinality partitioned
    aggregations."""
    print("test_entries_capacity_first_touch_pre_sized...")
    var agg = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=16)
    # Initial state: no allocation.
    assert_equal(agg.entries_capacity(), 0)
    # First insert triggers _grow_entries_capacity from 0.
    var e0 = agg.find_or_create_1(Int64(0))
    agg._update_agg(e0, 0, 1.0)
    # Post first-touch: capacity must be >= 8192 entry slots.
    assert_true(agg.entries_capacity() >= 8192)
    # Subsequent inserts inside the pre-sized capacity must NOT re-grow.
    var cap_after_first = agg.entries_capacity()
    for i in range(1, 8000):
        var e = agg.find_or_create_1(Int64(i))
        agg._update_agg(e, 0, Float64(i))
    assert_equal(agg.entries_capacity(), cap_after_first)
    _ = agg
    print("  PASS")


def main() raises:
    test_basic_single_key()
    test_multi_agg_single_key()
    test_two_key()
    test_n_key()
    test_resize()
    test_empty_table()
    test_single_group()
    test_high_cardinality()
    test_iter_entries()
    test_negative_keys()
    test_two_key_many_groups()
    test_two_key_hash_matches_n_key()
    test_count_only_agg()
    test_ensure_merge_capacity_grows_once()
    test_ensure_merge_capacity_preserves_entries()
    test_pre_grow_absolute()
    test_entries_capacity_first_touch_pre_sized()
    print()
    print("ALL 17 tests PASSED")
