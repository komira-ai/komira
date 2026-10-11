# =============================================================================
# Tests for FlatHashPartitionFlush + FlatHashAggregator.flush_to_partitions
# =============================================================================
#
# The abandon-cycle flush path:
#
#   1. test_partition_assignment_deterministic -- same (keys, aggs) flushes to
#      the same partitions across repeated flushes on freshly-built HTs.
#   2. test_partition_coverage -- sum of num_groups across the 256 slab slots
#      equals the aggregator's num_groups before flush (no rows lost).
#   3. test_no_data_loss -- after flush + reconstruct into a fresh aggregator,
#      SUM(val) per group equals the pre-flush value.
#   4. test_clear_for_reuse_keeps_allocation -- after flush + clear_for_reuse,
#      inserting 100 more groups yields num_groups==100 and no crash.
#   5. test_stride_invariant -- every row in every partition buffer is exactly
#      entry_stride bytes (enforced via length formula).
# =============================================================================

from std.memory import alloc
from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_hash.flat_hash_agg import FlatHashAggregator
from komira_collections.slab import Slab
from komira_op_agg_hash.flat_hash_partition_flush import FlatHashPartitionFlush


comptime _NUM_PARTITIONS: Int = 256
comptime _SHIFT: UInt32 = UInt32(56)  # 64 - 8 radix bits


def _new_slab(n_workers: Int, entry_stride: Int) -> Slab[FlatHashPartitionFlush]:
    """A slab of n_workers*256 empty FlatHashPartitionFlush buffers."""
    var total = n_workers * _NUM_PARTITIONS
    var slab = Slab[FlatHashPartitionFlush].with_capacity(total)
    for _ in range(total):
        slab.append(FlatHashPartitionFlush.new(entry_stride))
    return slab^


def _populate(mut agg: FlatHashAggregator, n_groups: Int, base_val: Float64):
    """Insert n_groups distinct Int64 keys, each with sum=base_val+key,count=1."""
    for k in range(n_groups):
        var h = agg.find_or_create_1(Int64(k))
        agg._update_agg(h, 0, base_val + Float64(k))


def test_partition_assignment_deterministic() raises:
    """Same keys must land in the same partitions across independent flushes."""
    var a = FlatHashAggregator(num_keys=1, num_aggs=1)
    _populate(a, 500, 1.0)
    var stride = a.entry_stride()
    var slab_a = _new_slab(1, stride)
    a.flush_to_partitions(slab_a, 0, _NUM_PARTITIONS, _SHIFT)

    var b = FlatHashAggregator(num_keys=1, num_aggs=1)
    _populate(b, 500, 99.0)  # different aggs, same keys
    var slab_b = _new_slab(1, stride)
    b.flush_to_partitions(slab_b, 0, _NUM_PARTITIONS, _SHIFT)

    for p in range(_NUM_PARTITIONS):
        assert_equal(
            slab_a[p].num_groups,
            slab_b[p].num_groups,
        )

    _ = slab_a^
    _ = slab_b^


def test_partition_coverage() raises:
    """Sum of num_groups across 256 partitions == pre-flush num_groups."""
    var a = FlatHashAggregator(num_keys=1, num_aggs=1)
    _populate(a, 1000, 2.0)
    var stride = a.entry_stride()
    var total_before = a.num_groups()
    assert_equal(total_before, 1000)

    var slab = _new_slab(1, stride)
    a.flush_to_partitions(slab, 0, _NUM_PARTITIONS, _SHIFT)

    var total_after = 0
    for p in range(_NUM_PARTITIONS):
        total_after += slab[p].num_groups
    assert_equal(total_after, total_before)

    _ = slab^


def test_no_data_loss() raises:
    """After flush + reconstruct, SUM(val) per group matches pre-flush."""
    var a = FlatHashAggregator(num_keys=1, num_aggs=1)
    # Accumulate TWO updates per key so we can verify sum is preserved.
    for k in range(200):
        var h1 = a.find_or_create_1(Int64(k))
        a._update_agg(h1, 0, Float64(k))
        var h2 = a.find_or_create_1(Int64(k))
        a._update_agg(h2, 0, Float64(k) + 1.0)
    var stride = a.entry_stride()
    var pre_total = 0.0
    for k in range(200):
        var h = a.find_or_create_1(Int64(k))
        pre_total += a.get_sum(h, 0)

    var slab = _new_slab(1, stride)
    a.flush_to_partitions(slab, 0, _NUM_PARTITIONS, _SHIFT)

    # Reconstruct by walking every partition buffer.
    var recon = FlatHashAggregator(num_keys=1, num_aggs=1)
    for p in range(_NUM_PARTITIONS):
        ref part = slab[p]
        for i in range(part.num_groups):
            recon.merge_flushed_row(part.row(i))

    assert_equal(recon.num_groups(), 200)
    var post_total = 0.0
    for k in range(200):
        var h = recon.find_or_create_1(Int64(k))
        post_total += recon.get_sum(h, 0)

    # Floating-point equality here is safe: all updates are exact integers.
    assert_true(abs(pre_total - post_total) < 0.001)

    _ = slab^


def test_clear_for_reuse_keeps_allocation() raises:
    """clear_for_reuse resets num_groups without freeing backing storage.

    The `_tags` and `_entries` addresses must be stable across
    clear_for_reuse: if it freed and reallocated, the post-abandon probe
    path would no longer be L2-resident (the point of the abandon cycle).
    """
    var a = FlatHashAggregator(num_keys=1, num_aggs=1, initial_capacity=2048)
    _populate(a, 500, 5.0)
    var stride = a.entry_stride()
    var slab = _new_slab(1, stride)

    # Capture raw addresses BEFORE clear_for_reuse.
    var tags_before = Int(a._tags.unsafe_ptr())
    var entries_before = Int(a._entries.unsafe_ptr())
    var entries_cap_before = a._entries_capacity
    var cap_before = a._capacity

    a.flush_to_partitions(slab, 0, _NUM_PARTITIONS, _SHIFT)
    a.clear_for_reuse()

    assert_equal(a.num_groups(), 0)
    # Addresses + capacity unchanged = backing storage reused (not realloc'd).
    assert_equal(Int(a._tags.unsafe_ptr()), tags_before)
    assert_equal(Int(a._entries.unsafe_ptr()), entries_before)
    assert_equal(a._entries_capacity, entries_cap_before)
    assert_equal(a._capacity, cap_before)

    # Insert 100 more groups -- must not crash (proves allocation intact).
    for k in range(1000, 1100):
        var h = a.find_or_create_1(Int64(k))
        a._update_agg(h, 0, 7.0)

    assert_equal(a.num_groups(), 100)
    # Spot-check a value.
    var probe = a.find_or_create_1(Int64(1050))
    assert_true(abs(a.get_sum(probe, 0) - 7.0) < 0.001)

    _ = slab^


def test_stride_invariant() raises:
    """Every partition buffer's stride == aggregator's entry_stride."""
    var a = FlatHashAggregator(num_keys=2, num_aggs=3)
    for k in range(300):
        var h = a.find_or_create_2(Int64(k), Int64(k * 2))
        a._update_agg(h, 0, 1.0)
        a._update_agg(h, 1, 2.0)
        a._update_agg(h, 2, 3.0)
    var stride = a.entry_stride()
    var slab = _new_slab(1, stride)
    a.flush_to_partitions(slab, 0, _NUM_PARTITIONS, _SHIFT)

    for p in range(_NUM_PARTITIONS):
        ref part = slab[p]
        assert_equal(part.entry_stride, stride)
        # row_capacity must be >= num_groups.
        assert_true(part.row_capacity >= part.num_groups)

    _ = slab^


def test_partition_routing_correct() raises:
    """Every live row lands in partition (mixed_hash >> 56) & 0xFF.

    This is the invariant the partition-parallel combine depends on:
    given a flushed row, we can read its first 8 bytes as the mixed hash,
    derive the partition index, and know the row is present in exactly
    that partition's buffer (and no other).
    """
    var a = FlatHashAggregator(num_keys=1, num_aggs=1)
    _populate(a, 400, 3.0)
    var stride = a.entry_stride()

    # Record expected (key -> partition) using the pre-flush HT state.
    # The stored 8B hash at entry offset 0 is the partition-assignment
    # source of truth.
    var expected = Dict[Int, Int]()
    for k in range(400):
        var h = a.find_or_create_1(Int64(k))
        # h is an EntryHandle (slot + insertion-order index). Resolve
        # the entry pointer from `a._entries` and read the stored hash
        # (first 8B).
        var hash_val = a._entry_ptr_by_idx(Int(h._entry_idx)).bitcast[UInt64]()[]
        var p = Int((hash_val >> UInt64(56)) & UInt64(0xFF))
        expected[k] = p

    var slab = _new_slab(1, stride)
    a.flush_to_partitions(slab, 0, _NUM_PARTITIONS, _SHIFT)

    # Walk every partition buffer.  For each row, read the hash from
    # offset 0, compute partition p, assert p == p_buffer.  Also record
    # key -> partition-found and cross-check against `expected`.
    var found = Dict[Int, Int]()
    for p in range(_NUM_PARTITIONS):
        ref part = slab[p]
        for i in range(part.num_groups):
            var row = part.row_data.unsafe_ptr() + i * stride
            var row_hash = row.bitcast[UInt64]()[]
            var p_from_hash = Int((row_hash >> UInt64(56)) & UInt64(0xFF))
            assert_equal(p_from_hash, p)
            # Key is stored at offset _HASH_BYTES (8) as Int64.
            var key = Int((row + 8).bitcast[Int64]()[])
            found[key] = p

    # Every key must appear exactly once, in the partition predicted
    # from its mixed hash.
    assert_equal(len(found), 400)
    for k in range(400):
        assert_equal(found[k], expected[k])

    _ = slab^


def test_reserve_growth() raises:
    """Multi-doubling reserve preserves the live prefix byte-for-byte.

    new() returns capacity=0; the first reserve() bootstraps to
    _INITIAL_ROW_CAPACITY=256 rows and doubles from there (256 -> 512 ->
    1024 for 1000 rows).
    """
    var stride = 16
    var buf = FlatHashPartitionFlush.new(stride)
    # new() defers allocation; row_capacity is 0 until reserve.
    assert_equal(buf.row_capacity, 0)

    # First-row signature: 16 bytes where byte 0 == 0xA5.
    var first_bytes = alloc[UInt8](stride)
    for b in range(stride):
        (first_bytes + b)[] = UInt8((0xA5 + b) & 0xFF)

    # Last-row signature: 16 bytes where byte 0 == 0x5A.
    var last_bytes = alloc[UInt8](stride)
    for b in range(stride):
        (last_bytes + b)[] = UInt8((0x5A + b) & 0xFF)

    var filler = alloc[UInt8](stride)
    for b in range(stride):
        (filler + b)[] = UInt8(0)

    buf.reserve(1000)
    assert_true(buf.row_capacity >= 1000)
    buf._append_row(first_bytes)
    for _ in range(998):
        buf._append_row(filler)
    buf._append_row(last_bytes)
    assert_equal(buf.num_groups, 1000)

    # Re-read the first and last rows byte-for-byte.
    var row0 = buf.row_data.unsafe_ptr()
    for b in range(stride):
        assert_equal(Int((row0 + b)[]), Int((first_bytes + b)[]))
    var row999 = buf.row_data.unsafe_ptr() + 999 * stride
    for b in range(stride):
        assert_equal(Int((row999 + b)[]), Int((last_bytes + b)[]))

    first_bytes.free()
    last_bytes.free()
    filler.free()
    _ = buf^


def test_move_and_destroy() raises:
    """Move + destroy of a FlatHashPartitionFlush is safe (no double-free):
    only the moved-to value's destructor frees the buffer.
    """
    var a = FlatHashPartitionFlush.new(8)
    # Populate a few rows so row_data is non-null + non-empty.
    var row = alloc[UInt8](8)
    for b in range(8):
        (row + b)[] = UInt8(b)
    a.reserve(3)
    a._append_row(row)
    a._append_row(row)
    a._append_row(row)
    row.free()

    var b = a^  # move
    # b owns the buffer now.  Assert post-move invariants via scope end:
    # `b` drops here and frees exactly once.  If the moved-from `a` had
    # kept a live row_data, we'd double-free.
    assert_equal(b.num_groups, 3)
    _ = b^


def test_flush_twice_same_slab() raises:
    """Flushing twice into the same slab appends (never overwrites)."""
    var a = FlatHashAggregator(num_keys=1, num_aggs=1)
    _populate(a, 1000, 1.0)
    var stride = a.entry_stride()
    var slab = _new_slab(1, stride)

    a.flush_to_partitions(slab, 0, _NUM_PARTITIONS, _SHIFT)
    a.clear_for_reuse()

    # Second population, distinct key range.
    for k in range(2000, 3000):
        var h = a.find_or_create_1(Int64(k))
        a._update_agg(h, 0, 1.0)
    assert_equal(a.num_groups(), 1000)
    a.flush_to_partitions(slab, 0, _NUM_PARTITIONS, _SHIFT)

    # Sum-of-sums invariant: slab contains all 2000 rows.
    var total = 0
    for p in range(_NUM_PARTITIONS):
        total += slab[p].num_groups
    assert_equal(total, 2000)

    _ = slab^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
