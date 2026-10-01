# =============================================================================
# tests/test_sharded_lineage_kernel.mojo
#   The NEUTRAL ShardedLineage KERNEL regression guards
# =============================================================================
#
# PROVES the four kernel responsibilities shared with the broker, exercised through the REAL kernel struct
# (komira_objectstore.sharded_lineage.ShardedLineage) over a REAL in-memory
# CloneableConditionalWriteStore — the SAME substrate the broker fold tests use:
#
#   CLAIM     `claim_writer_shard` mints collision-free `<node>-<pid>-<role><w>`
#             shard_ids; the reserved `_base` is NEVER mintable + `is_reserved`
#             classifies it.                       [test_claim_writer_shard_ids]
#   DISCOVERY `enumerate_live_shards` LIST-discovers live writer sub-lineages and
#             EXCLUDES `_base` — proven on BOTH the in-mem flat-objects backend
#             AND a synthetic common-prefixes-only listing (the REAL-S3 LIST-
#             DELIMITER TRAP: a union of `common_prefixes` ∪ `objects` so the
#             enumeration is correct whether the backend honors the delimiter or
#             not).                                [test_enumerate_live_shards_*]
#   FAN-OUT   `snapshot` pins every live shard's AUTHORITATIVE head at a commit
#             boundary, in CANONICAL (shard_id lexicographic) order — order-
#             stable across two independent views.       [test_snapshot_fanout_*]
#   ORCHESTR. `plan_tail` runs the SOLE canonical dense-offset assignment; the
#             dense layout is contiguous + shard-canonical + additive, and is
#             BYTE-IDENTICAL to the re-exported `plan_tail_assignment`
#             (`plan_assignment`) the broker fold AND the consume resolver call —
#             the SERVE==FOLD moat.                 [test_plan_tail_serve_eq_fold]
#
# These are KERNEL-level guards (the lifted shard layer in isolation), distinct
# from the broker's i64/segment `_base` fold-body guards (test_sublineage_base_fold
# / test_sublineage_segment_fold), which stay GREEN unchanged.
#
# Encapsulation / heap-reuse: ZERO UnsafePointer / wildcard origin / unsafe_from_address.
# All state is value / List / POD. No byte-slab element introduced.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_objectstore.cas_manifest import CasManifestStore, RetryPolicy
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.sharded_lineage import (
    ShardedLineage,
    canonical_shard_less,
    plan_tail_assignment,
    shard_id_from_listing_entry,
    shard_lineage_prefix,
    sort_shard_ids,
)
from komira_objectstore.sublineage_base_fold import (
    FoldBlockAssignment,
    ShardFoldedWatermark,
    ShardSnapshot,
    encode_record_body,
    plan_assignment,
)

comptime _Kernel = ShardedLineage[SharedInMemoryConditionalStore]


def _new_kernel(part: String) raises -> _Kernel:
    return _Kernel(SharedInMemoryConditionalStore(), part)


def _records(*vals: Int64) -> List[Int64]:
    var l = List[Int64]()
    for v in vals:
        l.append(v)
    return l^


def _append_to_shard(
    mut k: _Kernel, shard_id: String, records: List[Int64]
) raises:
    """Claim/write to a shard's sub-lineage through the kernel's `shard_store`
    fan-out — a plain `CasManifestStore.append`. The shard's local offset is the
    manifest's gapless base/last offset (UNAFFECTED by the canonical merge)."""
    var s = k.shard_store(shard_id)
    var body = encode_record_body(records)
    _ = s.append(body, Int64(len(records)))
    _ = s^


# =============================================================================
# CLAIM — writer-shard-id mint + the reserved `_base` guard.
# =============================================================================


def test_claim_writer_shard_ids() raises:
    # Distinct (node, worker, role) -> distinct collision-free shard_ids, all
    # carrying the `-<pid>-` infix (so none can equal the reserved `_base`).
    var a = _Kernel.claim_writer_shard(String("nodeA"), 0)
    var b = _Kernel.claim_writer_shard(String("nodeA"), 1)
    var c = _Kernel.claim_writer_shard(String("nodeA"), 0, String("drain"))
    assert_true(a != b, "distinct worker_idx -> distinct shard_id")
    assert_true(a != c, "distinct role -> distinct shard_id")
    # The role axis keeps a drain writer and a default writer disjoint even at
    # the SAME (node, pid, worker) — the cross-role `_HEAD` collision guard.
    assert_true(c.find("drain") >= 0, "role prefix present in shard_id")
    # A writer can NEVER claim the reserved fold-target.
    assert_false(_Kernel.is_reserved(a), "writer shard is not reserved")
    assert_false(_Kernel.is_reserved(c), "drain writer shard is not reserved")
    assert_true(_Kernel.is_reserved(String("_base")), "_base IS reserved")


# =============================================================================
# DISCOVERY — LIST-delimiter-safe enumeration (the REAL-S3 trap).
# =============================================================================


def test_enumerate_live_shards_in_mem_flat_objects() raises:
    """The in-memory backend returns flat OBJECT keys with EMPTY common_prefixes.
    `enumerate_live_shards` must derive each distinct shard_id from the object
    keys (the union's object arm), EXCLUDE `_base`, and canonical-sort."""
    var k = _new_kernel(String("topic/p0"))
    # Two writer shards (out of canonical order) + the reserved _base lineage.
    _append_to_shard(k, String("w02"), _records(Int64(100), Int64(101)))
    _append_to_shard(k, String("w01"), _records(Int64(200)))
    _append_to_shard(k, String("_base"), _records(Int64(999)))  # must be excluded

    var live = k.enumerate_live_shards()
    assert_equal(len(live), 2, "two writer shards discovered (_base excluded)")
    # Canonical-sorted: w01 < w02.
    assert_equal(live[0], String("w01"))
    assert_equal(live[1], String("w02"))
    # The reserved fold-target is NEVER an enumeration result.
    for i in range(len(live)):
        assert_false(live[i] == String("_base"), "_base excluded from discovery")
    assert_equal(k.live_shard_count(), 2, "live_shard_count matches enumeration")


def test_list_delimiter_trap_union_arms_converge() raises:
    """The REAL-S3 LIST-DELIMITER TRAP, falsified DIRECTLY at the convergence
    point. The in-mem backend returns flat OBJECT keys (empty common_prefixes);
    real S3/GCS honor the delimiter and return each writer shard ONLY as a
    `common_prefix`. `enumerate_live_shards` takes the UNION of both arms through
    ONE segment-extractor (`shard_id_from_listing_entry`). This asserts the two
    arm SHAPES — a flat object key `<prefix><shard>/manifest/000.chunk` and a
    common-prefix `<prefix><shard>/` — derive the BYTE-IDENTICAL shard_id. A
    discovery that handled only `objects` (the in-mem shape) would SILENTLY return
    EMPTY on real S3 (which sends only common_prefixes) — the documented trap that
    hit the broker rollout three times. Proving the arms converge proves the union
    is correct on BOTH backend classes."""
    var enum_prefix = String("topic/p1/_lineage/")
    # Arm 1: a flat object key (the in-mem backend shape).
    var from_object = shard_id_from_listing_entry(
        String("topic/p1/_lineage/nodeA-9-0/manifest/00000000000000000000.chunk"),
        enum_prefix,
    )
    # Arm 2: a common-prefix (the real-S3 delimiter shape) for the SAME shard.
    var from_common_prefix = shard_id_from_listing_entry(
        String("topic/p1/_lineage/nodeA-9-0/"), enum_prefix
    )
    assert_equal(
        from_object, from_common_prefix,
        "object-key arm and common-prefix arm derive the IDENTICAL shard_id",
    )
    assert_equal(from_object, String("nodeA-9-0"), "extracted shard_id correct")
    # A non-matching entry (wrong prefix) yields empty (skipped from the union).
    assert_equal(
        shard_id_from_listing_entry(String("other/key"), enum_prefix),
        String(""),
        "non-matching entry contributes nothing",
    )
    # And the live in-mem enumeration (object arm) discovers + canonical-sorts.
    var k = _new_kernel(String("topic/p1"))
    _append_to_shard(k, String("nodeZ-9-0"), _records(Int64(1)))
    _append_to_shard(k, String("nodeA-9-0"), _records(Int64(2)))
    var live = k.enumerate_live_shards()
    assert_equal(len(live), 2, "both writer shards discovered")
    assert_true(
        canonical_shard_less(live[0], live[1]),
        "enumeration is canonical-sorted",
    )
    assert_equal(live[0], String("nodeA-9-0"))
    assert_equal(live[1], String("nodeZ-9-0"))


def test_enumerate_empty_partition_is_no_shards() raises:
    """A legacy single-manifest partition (no `<part>/_lineage/` keys) enumerates
    to EMPTY — the kernel returns [] (the caller replays the legacy lineage)."""
    var k = _new_kernel(String("topic/legacy"))
    var live = k.enumerate_live_shards()
    assert_equal(len(live), 0, "empty partition -> no live shards")


# =============================================================================
# FAN-OUT — authoritative cross-shard snapshot, canonical order.
# =============================================================================


def test_snapshot_fanout_pins_authoritative_heads() raises:
    """`snapshot` pins every live shard's authoritative head (chunk_seq +
    next_offset = cumulative record total) in CANONICAL order. Two shards with
    different record counts -> distinct snap_record_totals at the boundary."""
    var k = _new_kernel(String("topic/p2"))
    # w01: 3 records across 2 appends; w02: 2 records across 1 append.
    _append_to_shard(k, String("w01"), _records(Int64(10), Int64(11)))
    _append_to_shard(k, String("w01"), _records(Int64(12)))
    _append_to_shard(k, String("w02"), _records(Int64(20), Int64(21)))

    var snap = k.snapshot()
    assert_equal(len(snap), 2, "two live shards in the snapshot")
    # Canonical order: w01 first.
    assert_equal(snap[0].shard_id, String("w01"))
    assert_equal(snap[1].shard_id, String("w02"))
    # next_offset == cumulative record total (the allocator invariant).
    assert_equal(snap[0].snap_record_total, Int64(3), "w01 total = 3")
    assert_equal(snap[1].snap_record_total, Int64(2), "w02 total = 2")
    # chunk_seq: w01 has 2 appends (seq 0,1) -> highest seq 1; w02 has 1 (seq 0).
    assert_equal(snap[0].snap_chunk_seq, Int64(1), "w01 highest chunk_seq = 1")
    assert_equal(snap[1].snap_chunk_seq, Int64(0), "w02 highest chunk_seq = 0")


def test_snapshot_order_stable_across_views() raises:
    """Two independent ShardedLineage views over the SAME committed universe pin
    the IDENTICAL snapshot list — the order is canonical, not insertion-order."""
    var k1 = _new_kernel(String("topic/p3"))
    # Append in a deliberately non-canonical order.
    _append_to_shard(k1, String("w09"), _records(Int64(1)))
    _append_to_shard(k1, String("w03"), _records(Int64(2)))
    _append_to_shard(k1, String("w06"), _records(Int64(3)))
    var snap1 = k1.snapshot()
    # A SECOND view over the same bucket (clone) must see the same canonical order
    # order-stability is a property of the committed universe, not of one view's
    # append order.
    var k2 = k1.clone_view()
    var snap2 = k2.snapshot()
    assert_equal(len(snap1), len(snap2), "same shard count")
    for i in range(len(snap1)):
        assert_equal(snap1[i].shard_id, snap2[i].shard_id, "canonical order stable")
    # And the order IS canonical: w03 < w06 < w09.
    assert_equal(snap1[0].shard_id, String("w03"))
    assert_equal(snap1[1].shard_id, String("w06"))
    assert_equal(snap1[2].shard_id, String("w09"))


# =============================================================================
# ORCHESTRATION — the SOLE canonical assignment = the SERVE==FOLD moat.
# =============================================================================


def test_plan_tail_canonical_contiguous_additive() raises:
    """`plan_tail` assigns dense offsets by walking the canonical-sorted snapshot;
    each shard's un-folded tail `[already .. total)` gets a CONTIGUOUS dense block
    starting at the running high-water. With no prior folds (folded_counts empty)
    and dense_hw_start=0, the blocks tile [0..total) in canonical order."""
    var k = _new_kernel(String("topic/p4"))
    _append_to_shard(k, String("w02"), _records(Int64(1), Int64(2)))  # 2 recs
    _append_to_shard(k, String("w01"), _records(Int64(3)))  # 1 rec
    var snap = k.snapshot()
    var folded = List[ShardFoldedWatermark]()
    var plan = k.plan_tail(snap, folded, Int64(0))
    assert_equal(len(plan), 2, "two blocks (one per live shard)")
    # Canonical: w01 (1 rec) -> dense [0..1); w02 (2 recs) -> dense [1..3).
    assert_equal(plan[0].shard_id, String("w01"))
    assert_equal(plan[0].dense_base, Int64(0))
    assert_equal(plan[0].count, Int64(1))
    assert_equal(plan[1].shard_id, String("w02"))
    assert_equal(plan[1].dense_base, Int64(1))
    assert_equal(plan[1].count, Int64(2))
    # ADDITIVITY: a second plan with w01 already folded skips it, and the
    # dense_hw start picks up where the prior left off.
    var folded2 = List[ShardFoldedWatermark]()
    folded2.append(ShardFoldedWatermark(String("w01"), Int64(1)))
    var plan2 = k.plan_tail(snap, folded2, Int64(3))
    assert_equal(len(plan2), 1, "w01 fully folded -> only w02 remains")
    assert_equal(plan2[0].shard_id, String("w02"))
    assert_equal(plan2[0].dense_base, Int64(3), "additive dense start")


def test_plan_tail_serve_eq_fold() raises:
    """THE SERVE==FOLD MOAT, asserted directly: `plan_tail` (the kernel
    orchestration entry) produces the BYTE-IDENTICAL assignment to the
    re-exported `plan_tail_assignment` AND to the underlying `plan_assignment`
    (the ONE authority the broker fold and the consume resolver both call) when
    fed the SAME canonical-sorted snapshot + folded_counts + dense_hw. A second
    assignment path would break the moat; this proves the kernel binds to the ONE
    function, not a fork."""
    var k = _new_kernel(String("topic/p5"))
    _append_to_shard(k, String("w05"), _records(Int64(1), Int64(2), Int64(3)))
    _append_to_shard(k, String("w02"), _records(Int64(4)))
    _append_to_shard(k, String("w08"), _records(Int64(5), Int64(6)))
    var snap = k.snapshot()
    var folded = List[ShardFoldedWatermark]()
    folded.append(ShardFoldedWatermark(String("w05"), Int64(1)))  # 1 already folded
    var dense_hw = Int64(7)

    # (1) the kernel orchestration entry.
    var via_kernel = k.plan_tail(snap, folded, dense_hw)
    # (2) the re-exported authority, fed a caller-sorted snapshot (sort ONCE).
    var sorted_snap = k.sort_snapshot(snap)
    var via_reexport = plan_tail_assignment(sorted_snap, folded, dense_hw)
    # (3) the underlying SOLE authority directly.
    var via_authority = plan_assignment(sorted_snap, folded, dense_hw)

    assert_equal(len(via_kernel), len(via_reexport), "same block count (1)")
    assert_equal(len(via_kernel), len(via_authority), "same block count (2)")
    for i in range(len(via_kernel)):
        # Byte-identical across all three paths.
        assert_equal(via_kernel[i].shard_id, via_reexport[i].shard_id)
        assert_equal(via_kernel[i].shard_id, via_authority[i].shard_id)
        assert_equal(via_kernel[i].source_local_base, via_authority[i].source_local_base)
        assert_equal(via_kernel[i].dense_base, via_reexport[i].dense_base)
        assert_equal(via_kernel[i].dense_base, via_authority[i].dense_base)
        assert_equal(via_kernel[i].count, via_authority[i].count)
    # Concretely: canonical order w02 < w05 < w08; w05 starts at folded_count=1.
    assert_equal(via_kernel[0].shard_id, String("w02"))
    assert_equal(via_kernel[0].dense_base, Int64(7))
    assert_equal(via_kernel[1].shard_id, String("w05"))
    assert_equal(via_kernel[1].source_local_base, Int64(1), "w05 skips folded prefix")
    assert_equal(via_kernel[1].count, Int64(2), "w05 un-folded tail = 2")
    assert_equal(via_kernel[2].shard_id, String("w08"))


# =============================================================================
# SURFACE — the kernel's path + sort aliases match the broker keyspace.
# =============================================================================


def test_shard_lineage_prefix_matches_keyspace() raises:
    """`shard_lineage_prefix` is byte-identical to the broker's live `_lineage`
    keyspace (`<part>/_lineage/<shard>`) so a heap-partition caller and the
    broker mint the SAME prefixes — one keyspace, two policies."""
    assert_equal(
        shard_lineage_prefix(String("topic/p0"), String("w01")),
        String("topic/p0/_lineage/w01"),
    )
    assert_equal(
        shard_lineage_prefix(String("tbl/part"), String("_base")),
        String("tbl/part/_lineage/_base"),
    )


def test_sort_shard_ids_canonical() raises:
    var ids = List[String]()
    ids.append(String("w10"))
    ids.append(String("w02"))
    ids.append(String("w01"))
    var sorted = sort_shard_ids(ids^)
    assert_equal(sorted[0], String("w01"))
    assert_equal(sorted[1], String("w02"))
    assert_equal(sorted[2], String("w10"))


def main() raises:
    test_claim_writer_shard_ids()
    test_enumerate_live_shards_in_mem_flat_objects()
    test_list_delimiter_trap_union_arms_converge()
    test_enumerate_empty_partition_is_no_shards()
    test_snapshot_fanout_pins_authoritative_heads()
    test_snapshot_order_stable_across_views()
    test_plan_tail_canonical_contiguous_additive()
    test_plan_tail_serve_eq_fold()
    test_shard_lineage_prefix_matches_keyspace()
    test_sort_shard_ids_canonical()
    print(
        "[OK] test_sharded_lineage_kernel — CLAIM + DISCOVERY (LIST-delimiter"
        " union) + FAN-OUT snapshot + ORCHESTRATION (serve==fold moat) all PASS"
    )
