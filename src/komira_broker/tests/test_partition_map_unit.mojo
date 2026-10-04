# =============================================================================
# tests/test_partition_map_unit.mojo
#   PartitionMap unit tests (OFFLINE, fast)
# =============================================================================
#
# The real gate for the partition-map abstraction.
# OFFLINE: no object store, no network. Uses `InMemoryConditionalStore` for the
# create-if-absent + read persistence path. Asserts:
#   1. `PartitionMap.fixed(N)` for N in {1,2,3,4,7,16}: ranges are gap-free,
#      non-overlapping, cover [0, 2^64), widths within +/- one quantum (last
#      absorbs the remainder), pid == i.
#   2. `range_containing_pid` round-trips every range's lo / hi-1 / midpoint to
#      the right pid (total + deterministic).
#   3. Uniform-hash distribution -> roughly balanced pid counts (sanity).
#   4. encode -> decode round-trip identity.
#   5. Persistence: create-if-absent + read via InMemoryConditionalStore;
#      a second create-if-absent is a no-op (the loser does not clobber).
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_broker.partition_map import (
    HashRange,
    PartitionMap,
    PARTITION_MODE_FIXED,
    PARTITION_MODE_AUTO,
    NO_PARENT_PID,
    NO_PARENT_BASE,
    partition_map_key,
    persist_create_if_absent,
    read_partition_map,
    read_partition_map_with_etag,
    try_persist_update,
)
from komira_broker.partition_split import (
    build_lineage_read_order,
    LineageReadStep,
)


def _pos_of(order: List[LineageReadStep], pid: Int) -> Int:
    for i in range(len(order)):
        if order[i].pid == pid:
            return i
    return -1

from komira_objectstore.in_memory_conditional_store import (
    InMemoryConditionalStore,
)


# =============================================================================
# 1. fixed(N) — gap-free / non-overlapping / full-space / widths.
# =============================================================================


def _assert_fixed_invariants(num_partitions: Int) raises:
    var map = PartitionMap.fixed(num_partitions)
    # validate() asserts: first lo == 0, contiguous, last hi == MAX.
    map.validate()
    assert_equal(
        map.num_partitions(),
        num_partitions,
        "fixed(N) must have N ranges (N=" + String(num_partitions) + ")",
    )
    assert_equal(
        Int(map.mode),
        Int(PARTITION_MODE_FIXED),
        "fixed(N) must be FIXED mode",
    )
    assert_equal(map.version, 1, "a fresh fixed map is version 1")

    # pid == i for the fixed map; ranges ordered ascending by lo.
    var u64_max = UInt64.MAX
    var quantum = u64_max / UInt64(num_partitions) if num_partitions >= 2 else u64_max
    var prev_hi = UInt64(0)
    for i in range(num_partitions):
        ref r = map.ranges[i]
        assert_equal(r.pid, i, "fixed(N) range i has pid i")
        if i == 0:
            assert_true(r.hash_lo == UInt64(0), "range 0 lo == 0")
        else:
            assert_true(
                r.hash_lo == prev_hi,
                "range i lo == range i-1 hi (gap-free, N="
                + String(num_partitions)
                + ", i="
                + String(i)
                + ")",
            )
        if i == num_partitions - 1:
            assert_true(
                r.hash_hi == u64_max,
                "last range hi == UInt64.MAX (covers 2^64)",
            )
        else:
            assert_true(
                r.hash_lo < r.hash_hi, "range i has positive width"
            )
        prev_hi = r.hash_hi

    # Width check: every non-last range is exactly `quantum` wide; the last
    # range is >= quantum (absorbs the remainder), within +/- one quantum.
    if num_partitions >= 2:
        for i in range(num_partitions - 1):
            ref r = map.ranges[i]
            var width = r.hash_hi - r.hash_lo
            assert_true(
                width == quantum,
                "non-last range width == quantum (N="
                + String(num_partitions)
                + ", i="
                + String(i)
                + ")",
            )


def test_fixed_invariants() raises:
    _assert_fixed_invariants(1)
    _assert_fixed_invariants(2)
    _assert_fixed_invariants(3)
    _assert_fixed_invariants(4)
    _assert_fixed_invariants(7)
    _assert_fixed_invariants(16)
    print("  [1] fixed(N) invariants OK for N in {1,2,3,4,7,16}")


# =============================================================================
# 2. range_containing_pid round-trips lo / hi-1 / midpoint.
# =============================================================================


def _assert_routing_roundtrip(num_partitions: Int) raises:
    var map = PartitionMap.fixed(num_partitions)
    for i in range(num_partitions):
        ref r = map.ranges[i]
        var lo = r.hash_lo
        # lo -> pid i.
        assert_equal(
            map.range_containing_pid(lo),
            i,
            "lo of range i routes to pid i (N="
            + String(num_partitions)
            + ", i="
            + String(i)
            + ")",
        )
        # midpoint -> pid i. For the last range hi is MAX (inclusive); compute a
        # safe midpoint via lo + (hi - lo)/2.
        var mid = lo + (r.hash_hi - lo) / UInt64(2)
        assert_equal(
            map.range_containing_pid(mid),
            i,
            "midpoint of range i routes to pid i (i=" + String(i) + ")",
        )
        # hi - 1 -> pid i (the last cell of the range). For the last range hi is
        # MAX (inclusive), so hi itself routes to i; for non-last, hi-1.
        if i == num_partitions - 1:
            assert_equal(
                map.range_containing_pid(r.hash_hi),
                i,
                "MAX routes to the last pid",
            )
        else:
            assert_equal(
                map.range_containing_pid(r.hash_hi - UInt64(1)),
                i,
                "hi-1 of range i routes to pid i (i=" + String(i) + ")",
            )
    # Boundary: the very first hash (0) and the very last (MAX).
    assert_equal(map.range_containing_pid(UInt64(0)), 0, "hash 0 -> pid 0")
    assert_equal(
        map.range_containing_pid(UInt64.MAX),
        num_partitions - 1,
        "hash MAX -> last pid",
    )


def test_routing_roundtrip() raises:
    _assert_routing_roundtrip(1)
    _assert_routing_roundtrip(2)
    _assert_routing_roundtrip(3)
    _assert_routing_roundtrip(4)
    _assert_routing_roundtrip(7)
    _assert_routing_roundtrip(16)
    print("  [2] range_containing_pid round-trips lo/mid/hi-1 OK")


# =============================================================================
# 3. Uniform-hash distribution -> roughly balanced pid counts (sanity).
# =============================================================================


def test_uniform_distribution_balanced() raises:
    var num_partitions = 8
    var map = PartitionMap.fixed(num_partitions)
    var counts = List[Int]()
    for _ in range(num_partitions):
        counts.append(0)
    # Sweep uniformly across the u64 space (stride steps). 8000 samples.
    var n_samples = 8000
    var stride = UInt64.MAX / UInt64(n_samples)
    var h = UInt64(0)
    var produced = 0
    for _ in range(n_samples):
        var pid = map.range_containing_pid(h)
        counts[pid] += 1
        produced += 1
        # Saturating step: stop adding once near MAX to avoid wrap.
        if h > UInt64.MAX - stride:
            break
        h += stride
    # Each of 8 partitions should get ~ n/8 = 1000. Allow a generous +/-30%
    # band (this is a SANITY check, not a strict statistical test).
    var expected = produced // num_partitions
    var lo_band = expected - (expected * 30) // 100
    var hi_band = expected + (expected * 30) // 100
    for p in range(num_partitions):
        assert_true(
            counts[p] >= lo_band and counts[p] <= hi_band,
            "partition "
            + String(p)
            + " count "
            + String(counts[p])
            + " outside balance band ["
            + String(lo_band)
            + ", "
            + String(hi_band)
            + "]",
        )
    print(
        "  [3] uniform-hash distribution balanced across",
        num_partitions,
        "partitions (~",
        expected,
        "each)",
    )


# =============================================================================
# 4. encode -> decode round-trip identity.
# =============================================================================


def _assert_encode_decode_identity(num_partitions: Int) raises:
    var map = PartitionMap.fixed(num_partitions)
    var bytes = map.encode()
    var decoded = PartitionMap.decode(bytes)
    decoded.validate()
    assert_equal(decoded.version, map.version, "version round-trips")
    assert_equal(Int(decoded.mode), Int(map.mode), "mode round-trips")
    assert_equal(
        decoded.num_partitions(),
        map.num_partitions(),
        "range count round-trips",
    )
    for i in range(map.num_partitions()):
        assert_true(
            decoded.ranges[i].hash_lo == map.ranges[i].hash_lo,
            "range i lo round-trips (i=" + String(i) + ")",
        )
        assert_true(
            decoded.ranges[i].hash_hi == map.ranges[i].hash_hi,
            "range i hi round-trips (i=" + String(i) + ")",
        )
        assert_equal(
            decoded.ranges[i].pid,
            map.ranges[i].pid,
            "range i pid round-trips (i=" + String(i) + ")",
        )


def test_encode_decode_identity() raises:
    _assert_encode_decode_identity(1)
    _assert_encode_decode_identity(4)
    _assert_encode_decode_identity(7)
    _assert_encode_decode_identity(16)
    # An AUTO-mode map's mode round-trips too (recorded, even if not functional
    # in this MVP). Build a 1-range full-space map by hand + flip the mode.
    var ranges = List[HashRange]()
    ranges.append(HashRange.original(UInt64(0), UInt64.MAX, 0))
    var auto_map = PartitionMap(
        version=1, mode=PARTITION_MODE_AUTO, ranges=ranges^
    )
    var decoded = PartitionMap.decode(auto_map.encode())
    assert_equal(
        Int(decoded.mode),
        Int(PARTITION_MODE_AUTO),
        "auto mode round-trips",
    )
    print("  [4] encode->decode identity OK (fixed N + auto mode flag)")


# =============================================================================
# 5. S3 persistence: create-if-absent + read (InMemoryConditionalStore).
# =============================================================================


def test_persistence_create_if_absent_and_read() raises:
    var store = InMemoryConditionalStore()
    var cluster = String("test-cluster")
    var topic = String("test-topic")
    var map = PartitionMap.fixed(4)

    # First create-if-absent: writes the map.
    persist_create_if_absent[InMemoryConditionalStore](
        store, cluster, topic, map
    )

    # Read it back: identical.
    var read1 = read_partition_map[InMemoryConditionalStore](
        store, cluster, topic
    )
    read1.validate()
    assert_equal(read1.num_partitions(), 4, "read map has 4 ranges")
    assert_equal(read1.version, 1, "read map version 1")
    assert_equal(Int(read1.mode), Int(PARTITION_MODE_FIXED), "read map fixed")

    # Second create-if-absent with a DIFFERENT map (8 partitions): the 412
    # precondition conflict is swallowed (the loser does not clobber). The
    # existing 4-partition map stays authoritative.
    var map8 = PartitionMap.fixed(8)
    persist_create_if_absent[InMemoryConditionalStore](
        store, cluster, topic, map8
    )
    var read2 = read_partition_map[InMemoryConditionalStore](
        store, cluster, topic
    )
    assert_equal(
        read2.num_partitions(),
        4,
        "create-if-absent loser must NOT clobber (still 4 ranges, not 8)",
    )

    # The key is the documented sibling-of-config.json path.
    assert_equal(
        partition_map_key(cluster, topic),
        String("test-cluster/_meta/topics/test-topic/partition_map.json"),
        "partition_map_key layout",
    )
    print(
        "  [5] S3 persistence (create-if-absent + read + no-clobber) OK via"
        " InMemoryConditionalStore"
    )


# =============================================================================
# 6. Edge: fixed(0) raises; range pids enumerate correctly.
# =============================================================================


def test_edge_cases() raises:
    var raised = False
    try:
        _ = PartitionMap.fixed(0)
    except:
        raised = True
    assert_true(raised, "fixed(0) must raise (num_partitions >= 1)")

    # pids() enumerates 0..N-1 for a fixed map.
    var map = PartitionMap.fixed(5)
    var pids = map.pids()
    assert_equal(len(pids), 5, "pids() has N entries")
    for i in range(5):
        assert_equal(pids[i], i, "fixed map pid i == i")
    print("  [6] edge cases OK (fixed(0) raises; pids enumerate)")


# =============================================================================
# 7. split(pid) — parent -> 2 gap-free children, fresh pids, version++, lineage.
# =============================================================================


def test_split_metadata() raises:
    # An auto seed: 1 full-space range, pid 0, next_pid 1.
    var seed = PartitionMap.auto_seed()
    seed.validate()
    assert_equal(seed.num_partitions(), 1, "auto seed has 1 range")
    assert_equal(seed.next_pid, 1, "auto seed next_pid == 1")
    assert_equal(Int(seed.mode), Int(PARTITION_MODE_AUTO), "seed is auto")
    assert_equal(seed.ranges[0].parent_pid, NO_PARENT_PID, "seed range no parent")

    # Split pid 0 at freeze offset X=41.
    var X = Int64(41)
    var m1 = seed.split_at(0, X)
    m1.validate()
    assert_equal(m1.version, 2, "split bumps version 1 -> 2")
    assert_equal(m1.num_partitions(), 2, "split -> 2 live ranges")
    assert_equal(m1.next_pid, 3, "next_pid advances by 2 (1 -> 3)")
    assert_equal(len(m1.retired), 1, "parent tombstoned in retired")

    # Children: fresh pids 1 and 2 (NEVER the parent's 0).
    ref a = m1.ranges[0]
    ref b = m1.ranges[1]
    assert_equal(a.pid, 1, "child_a fresh pid 1")
    assert_equal(b.pid, 2, "child_b fresh pid 2")
    assert_true(a.pid != 0 and b.pid != 0, "children never reuse parent pid 0")

    # Gap-free children covering exactly [0, 2^64): a=[0,mid), b=[mid,MAX].
    var mid = UInt64(0) + (UInt64.MAX - UInt64(0)) / UInt64(2)
    assert_true(a.hash_lo == UInt64(0), "child_a lo == 0")
    assert_true(a.hash_hi == mid, "child_a hi == midpoint")
    assert_true(b.hash_lo == mid, "child_b lo == midpoint (gap-free)")
    assert_true(b.hash_hi == UInt64.MAX, "child_b hi == MAX (full-space)")

    # Lineage on both children: parent_pid 0, parent_split_offset X.
    assert_equal(a.parent_pid, 0, "child_a parent_pid == 0")
    assert_equal(b.parent_pid, 0, "child_b parent_pid == 0")
    assert_equal(a.parent_split_offset, X, "child_a split_offset == X")
    assert_equal(b.parent_split_offset, X, "child_b split_offset == X")

    # The retired tombstone records X + both child pids + full parent range.
    ref t = m1.retired[0]
    assert_equal(t.pid, 0, "retired parent pid 0")
    assert_equal(t.frozen_at_offset, X, "retired frozen_at_offset == X")
    assert_equal(t.child_a_pid, 1, "retired child_a == 1")
    assert_equal(t.child_b_pid, 2, "retired child_b == 2")
    assert_true(t.hash_lo == UInt64(0) and t.hash_hi == UInt64.MAX,
        "retired parent covers full range")

    # Routing: a hash in [0,mid) routes to child_a (1); in [mid,MAX] to b (2).
    assert_equal(m1.range_containing_pid(UInt64(0)), 1, "lo -> child_a")
    assert_equal(m1.range_containing_pid(mid - UInt64(1)), 1, "mid-1 -> child_a")
    assert_equal(m1.range_containing_pid(mid), 2, "mid -> child_b")
    assert_equal(m1.range_containing_pid(UInt64.MAX), 2, "MAX -> child_b")
    print("  [7] split(pid): 2 gap-free children, fresh pids, v++, lineage OK")


# =============================================================================
# 8. Multi-level split — split a child again; tree stays gap-free + total.
# =============================================================================


def test_multi_level_split() raises:
    var seed = PartitionMap.auto_seed()
    var m1 = seed.split_at(0, Int64(10))  # 0 -> {1, 2}
    # Split child_b (pid 2) again at X=25.
    var m2 = m1.split_at(2, Int64(25))  # 2 -> {3, 4}
    m2.validate()
    assert_equal(m2.version, 3, "second split -> version 3")
    assert_equal(m2.num_partitions(), 3, "now 3 live leaves: {1, 3, 4}")
    assert_equal(m2.next_pid, 5, "next_pid 3 -> 5")
    assert_equal(len(m2.retired), 2, "two retired parents: 0 and 2")

    # Live leaves are pids 1, 3, 4 (2 retired).
    var pids = m2.pids()
    assert_equal(len(pids), 3, "3 live pids")
    assert_equal(pids[0], 1, "leaf 0 == pid 1")
    assert_equal(pids[1], 3, "leaf 1 == pid 3 (child_a of 2)")
    assert_equal(pids[2], 4, "leaf 2 == pid 4 (child_b of 2)")

    # Lineage of pid 3/4: parent_pid == 2, split_offset == 25.
    assert_equal(m2.ranges[1].parent_pid, 2, "pid 3 parent == 2")
    assert_equal(m2.ranges[1].parent_split_offset, Int64(25), "pid 3 X == 25")
    assert_equal(m2.ranges[2].parent_pid, 2, "pid 4 parent == 2")

    # validate() already asserted gap-free + last==MAX. Sanity: full coverage.
    assert_true(m2.ranges[0].hash_lo == UInt64(0), "first leaf lo == 0")
    assert_true(
        m2.ranges[2].hash_hi == UInt64.MAX, "last leaf hi == MAX (total)"
    )
    print("  [8] multi-level split: tree gap-free + total over [0,2^64) OK")


# =============================================================================
# 9. Reject split when mode == fixed (a Kafka topic never splits).
# =============================================================================


def test_split_rejected_for_fixed() raises:
    var fixed = PartitionMap.fixed(4)
    var raised = False
    try:
        _ = fixed.split_at(0, Int64(0))
    except:
        raised = True
    assert_true(raised, "fixed-mode map must REJECT split")

    # Also reject splitting a non-live (retired / nonexistent) pid on an auto map.
    var seed = PartitionMap.auto_seed()
    var m1 = seed.split_at(0, Int64(5))  # 0 retired now
    var raised2 = False
    try:
        _ = m1.split_at(0, Int64(5))  # pid 0 is retired
    except:
        raised2 = True
    assert_true(raised2, "splitting a retired pid must raise (not live)")
    print("  [9] split rejected for fixed mode + retired/nonexistent pid OK")


# =============================================================================
# 10. If-Match CAS: a stale-version split loses the CAS (over InMemory store).
# =============================================================================


def test_split_if_match_cas() raises:
    var store = InMemoryConditionalStore()
    var cluster = String("c")
    var topic = String("t")
    # Create an auto seed map.
    var seed = PartitionMap.auto_seed()
    persist_create_if_absent[InMemoryConditionalStore](
        store, cluster, topic, seed
    )

    # Reader 1 + Reader 2 both read the SAME etag (v1).
    var r1 = read_partition_map_with_etag[InMemoryConditionalStore](
        store, cluster, topic
    )
    var r2 = read_partition_map_with_etag[InMemoryConditionalStore](
        store, cluster, topic
    )
    assert_equal(r1.etag, r2.etag, "both readers see the same etag")

    # Reader 1 splits + commits via If-Match on r1.etag -> WINS.
    var split1 = r1.map.split_at(0, Int64(7))
    var ok1 = try_persist_update[InMemoryConditionalStore](
        store, cluster, topic, split1, r1.etag
    )
    assert_true(ok1, "reader 1's If-Match CAS wins (etag current)")

    # Reader 2 splits + commits via If-Match on the now-STALE r2.etag -> LOSES.
    var split2 = r2.map.split_at(0, Int64(9))
    var ok2 = try_persist_update[InMemoryConditionalStore](
        store, cluster, topic, split2, r2.etag
    )
    assert_true(not ok2, "reader 2's If-Match CAS LOSES (stale etag)")

    # The persisted map is reader 1's: 2 children (pids 1,2), version 2.
    var final = read_partition_map[InMemoryConditionalStore](
        store, cluster, topic
    )
    final.validate()
    assert_equal(final.version, 2, "persisted map is the winner (v2)")
    assert_equal(final.num_partitions(), 2, "winner has 2 children")
    assert_equal(final.retired[0].frozen_at_offset, Int64(7), "winner's X == 7")
    print("  [10] If-Match CAS: stale-version split loses, winner persists OK")


# =============================================================================
# 11. build_lineage_read_order — topological (parents before children).
# =============================================================================


def test_lineage_read_order() raises:
    # Forest: 0 -> {1, 2}; 2 -> {3, 4}; 1 -> {5, 6}.
    var seed = PartitionMap.auto_seed()
    var m1 = seed.split_at(0, Int64(10))  # 0 -> {1,2}
    var m2 = m1.split_at(2, Int64(20))  # 2 -> {3,4}
    var m3 = m2.split_at(1, Int64(30))  # 1 -> {5,6}
    m3.validate()
    # Live leaves: {3, 4, 5, 6}; retired: {0, 2, 1}.
    var order = build_lineage_read_order(m3)
    # Total forest pids = 4 leaves + 3 retired = 7.
    assert_equal(len(order), 7, "read order covers all 7 forest pids")

    # Assert every parent precedes its children (topological order).
    var p0 = _pos_of(order, 0)
    var p1 = _pos_of(order, 1)
    var p2 = _pos_of(order, 2)
    var p3 = _pos_of(order, 3)
    var p4 = _pos_of(order, 4)
    var p5 = _pos_of(order, 5)
    var p6 = _pos_of(order, 6)
    for pp in [p0, p1, p2, p3, p4, p5, p6]:
        assert_true(pp >= 0, "every forest pid present in read order")
    # 0 before 1,2; 2 before 3,4; 1 before 5,6.
    assert_true(p0 < p1 and p0 < p2, "parent 0 before children 1,2")
    assert_true(p2 < p3 and p2 < p4, "parent 2 before children 3,4")
    assert_true(p1 < p5 and p1 < p6, "parent 1 before children 5,6")
    # Depth check: 0 depth 0; 1,2 depth 1; 3,4,5,6 depth 2.
    assert_equal(order[p0].depth, 0, "root depth 0")
    assert_equal(order[p1].depth, 1, "pid 1 depth 1")
    assert_equal(order[p3].depth, 2, "pid 3 depth 2")
    assert_true(order[p0].is_retired, "pid 0 is retired (a parent)")
    assert_true(not order[p3].is_retired, "pid 3 is a live leaf")
    print("  [11] lineage read order: parents-before-children topological OK")


def main() raises:
    print("=== PartitionMap unit tests (offline) ===")
    test_fixed_invariants()
    test_routing_roundtrip()
    test_uniform_distribution_balanced()
    test_encode_decode_identity()
    test_persistence_create_if_absent_and_read()
    test_edge_cases()
    test_split_metadata()
    test_multi_level_split()
    test_split_rejected_for_fixed()
    test_split_if_match_cas()
    test_lineage_read_order()
    print("=== ALL PartitionMap unit tests PASS ===")
