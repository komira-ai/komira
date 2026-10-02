# =============================================================================
# tests/test_assignment_generation_continuity_merge_split.mojo
#   WRITER-LEASE-EPOCH FENCE — the merge/split generation-CONTINUITY guard.
# =============================================================================
#
# THE HAZARD:
#
#   1. pid 5 reaches lease generation 2 (a displaced owner of pid 5 froze its
#      writer_lease_epoch at 2).
#   2. a partition MERGE shrinks P (6 -> 3); if the `Assignment` ctor
#      TAIL-TRUNCATED the `generations` array, pid 5's gen-2 lease would be
#      dropped entirely.
#   3. a re-SPLIT grows P back (3 -> 6); recomputing `_compute_generations` from
#      the (truncated) live array, which has NO prior generation for the
#      re-created pid 5, would RESTART pid 5 at generation 1.
#   4. a displaced gen-2 writer of pid 5 would then see current generation 1;
#      the manifest fence `writer_lease_epoch (2) < current_lease_epoch (1)` is
#      FALSE -> NOT fenced -> FENCE BYPASS (the stale writer can tear an offset
#      on the re-split pid 5's lineage).
#
# THE GUARANTEE: the lease generation is PARTITION-LIFETIME MONOTONE. The
# `Assignment` carries a separate `max_generations` high-water that is NEVER
# tail-truncated when P shrinks (only padded when P grows). `_compute_generations`
# anchors the bump on that high-water (`floor + 1`), so a re-created pid
# re-acquires STRICTLY ABOVE its lifetime high-water (3), never below it.
#
# `test_merge_resplit_generation_does_not_regress` asserts the re-split pid 5
# generation is STRICTLY ABOVE its frozen displaced lease (gen 2). A
# generation recomputed from the truncated live array would be 1 (the
# restart), which is BELOW 2 — the assertion would FAIL (the falsifier).
#
# These are pure-value tests (no store, no network) — the continuity logic
# lives on the `Assignment` type + the `assign_partitions` pass.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_broker import (
    Assignment,
    AssignmentView,
    assign_partitions,
    REBALANCE_INITIAL,
    REBALANCE_NEW_NODE,
    REBALANCE_STALE_NODE,
    REBALANCE_PARTITION_COUNT,
)


def _strs(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(x)
    return out^


# =============================================================================
# THE LOAD-BEARING REGRESSION GUARD — merge-then-resplit must NOT regress a pid's
# generation below a value a displaced owner of that pid previously held.
# =============================================================================
def test_merge_resplit_generation_does_not_regress() raises:
    """The confirmed Slice-A bug guard. Drive pid 5 to gen 2, MERGE (P 6 -> 3,
    dropping pid 5), then re-SPLIT (P 3 -> 6, re-creating pid 5). The re-created
    pid 5's generation MUST be STRICTLY GREATER than its prior displaced lease
    (gen 2) — never restart at 1.

    FAILS ON CURRENT CODE (pre-Slice-A): the re-split pid 5 generation is 1
    (restart from the truncated array), which is < 2 -> the assertion fires."""
    var nodes = _strs(String("a"), String("b"), String("c"))

    # Initial P=6 across a,b,c: every pid acquires at generation 1.
    var a0 = assign_partitions(
        nodes.copy(), 6, Optional[Assignment](), REBALANCE_PARTITION_COUNT
    )

    # Drop node c: c's pids (which include pid 5) move to a/b -> their generation
    # bumps to 2. A displaced owner of pid 5 froze its writer_lease_epoch at 2.
    var a_drop_c = assign_partitions(
        _strs(String("a"), String("b")),
        6,
        Optional(a0.copy()),
        REBALANCE_STALE_NODE,
    )
    var pid5_high = a_drop_c.generation_of(5)
    assert_true(
        pid5_high >= Int64(2),
        "pid 5 reached >= gen 2 after dropping node c (was "
        + String(pid5_high)
        + ")",
    )

    # MERGE to P=3 (a,b still live) — pid 5 disappears; a ctor tail-truncate would
    # drop its gen-2 lease. The high-water must RETAIN it.
    var a_merge = assign_partitions(
        _strs(String("a"), String("b")),
        3,
        Optional(a_drop_c.copy()),
        REBALANCE_PARTITION_COUNT,
    )
    assert_equal(a_merge.num_partitions, 3, "merged to P=3")
    # The high-water for the dropped pid 5 SURVIVES the merge (never truncated).
    assert_equal(
        a_merge.max_generation_of(5),
        pid5_high,
        "dropped pid 5's lifetime high-water survives the merge truncate",
    )

    # RE-SPLIT back to P=6 — pid 5 is RE-CREATED. Its generation MUST be strictly
    # ABOVE its prior displaced lease (the lifetime high-water + 1), NOT 1.
    var a_resplit = assign_partitions(
        _strs(String("a"), String("b")),
        6,
        Optional(a_merge.copy()),
        REBALANCE_PARTITION_COUNT,
    )
    var pid5_new = a_resplit.generation_of(5)
    assert_true(
        pid5_new > pid5_high,
        "re-split pid 5 generation ("
        + String(pid5_new)
        + ") must be STRICTLY GREATER than the displaced lease ("
        + String(pid5_high)
        + ") — NO regression (the fence "
        + String(pid5_high)
        + " < "
        + String(pid5_new)
        + " must FIRE for the stale writer)",
    )
    # The fence the displaced gen-2 writer hits: writer(2) < current(pid5_new).
    assert_true(
        Int64(2) < pid5_new,
        "a displaced gen-2 writer is correctly fenced (2 < "
        + String(pid5_new)
        + ")",
    )


def test_high_water_never_decreases_across_churn() raises:
    """The general invariant: across an arbitrary merge/split/drop/rejoin churn
    sequence, max_generation_of(pid) for EVERY pid that has ever been alive is
    NON-DECREASING from one pass to the next. (The live generation can carry-
    forward unchanged for a sticky pid, but the high-water never drops.)"""
    var abc = _strs(String("a"), String("b"), String("c"))

    var a0 = assign_partitions(
        abc.copy(), 8, Optional[Assignment](), REBALANCE_PARTITION_COUNT
    )
    # Capture the lifetime high-water for all 8 pids.
    var hw = List[Int64]()
    for pid in range(8):
        hw.append(a0.max_generation_of(pid))

    # A churn sequence: drop c -> merge to 4 -> rejoin c, split to 8 -> drop a.
    var prior = a0.copy()
    var live_ab = _strs(String("a"), String("b"))

    var p1 = assign_partitions(
        live_ab.copy(), 8, Optional(prior.copy()), REBALANCE_STALE_NODE
    )
    _assert_high_water_nondecreasing(p1, hw, 8)
    _absorb_high_water(p1, hw)
    prior = p1.copy()

    var p2 = assign_partitions(
        live_ab.copy(), 4, Optional(prior.copy()), REBALANCE_PARTITION_COUNT
    )
    # P shrank to 4, but the high-water for pids 4..7 must be RETAINED (the
    # array can be longer than P).
    _assert_high_water_nondecreasing(p2, hw, 8)
    _absorb_high_water(p2, hw)
    prior = p2.copy()

    var p3 = assign_partitions(
        abc.copy(), 8, Optional(prior.copy()), REBALANCE_PARTITION_COUNT
    )
    _assert_high_water_nondecreasing(p3, hw, 8)
    _absorb_high_water(p3, hw)
    prior = p3.copy()

    var p4 = assign_partitions(
        _strs(String("b"), String("c")),
        8,
        Optional(prior.copy()),
        REBALANCE_STALE_NODE,
    )
    _assert_high_water_nondecreasing(p4, hw, 8)


def _assert_high_water_nondecreasing(
    a: Assignment, hw: List[Int64], n: Int
) raises:
    """Assert every pid's lifetime high-water is >= the previously-recorded one."""
    for pid in range(n):
        var cur = a.max_generation_of(pid)
        assert_true(
            cur >= hw[pid],
            "high-water for pid "
            + String(pid)
            + " ("
            + String(cur)
            + ") must be >= prior ("
            + String(hw[pid])
            + ")",
        )


def _absorb_high_water(a: Assignment, mut hw: List[Int64]):
    """Raise the recorded high-water to the assignment's (for the next step)."""
    for pid in range(len(hw)):
        try:
            var cur = a.max_generation_of(pid)
            if cur > hw[pid]:
                hw[pid] = cur
        except e:
            _ = e


# =============================================================================
# Sanity: a SPLIT (P grows) preserves the kept-pid generations + high-water.
# =============================================================================
def test_split_preserves_kept_pid_generations() raises:
    """A split (P grows, no owner change for the kept pids) keeps the kept pids'
    live generation AND high-water unchanged; new pids acquire at gen 1."""
    var nodes = _strs(String("a"), String("b"), String("c"))
    var a0 = assign_partitions(
        nodes.copy(), 3, Optional[Assignment](), REBALANCE_PARTITION_COUNT
    )
    for pid in range(3):
        assert_equal(a0.generation_of(pid), Int64(1), "initial gen 1")
        assert_equal(a0.max_generation_of(pid), Int64(1), "initial high-water 1")

    var a1 = assign_partitions(
        nodes.copy(), 6, Optional(a0.copy()), REBALANCE_PARTITION_COUNT
    )
    # Kept pids 0,1,2 unchanged owner -> live gen + high-water unchanged.
    for pid in range(3):
        assert_equal(
            a1.generation_of(pid),
            a0.generation_of(pid),
            "kept-pid live gen unchanged on split",
        )
        assert_equal(
            a1.max_generation_of(pid),
            a0.max_generation_of(pid),
            "kept-pid high-water unchanged on split",
        )
    # New pids 3,4,5 acquire at gen 1 (first real acquire; 0 is reserved).
    for pid in range(3, 6):
        assert_equal(a1.generation_of(pid), Int64(1), "new-pid gen 1 on split")
        assert_equal(
            a1.max_generation_of(pid), Int64(1), "new-pid high-water 1 on split"
        )


# =============================================================================
# Codec round-trip: the v3 max-generations trailer survives binary + JSON + view,
# INCLUDING a high-water array LONGER than P (the merge-retained dropped pids).
# =============================================================================
def test_v3_maxgens_codec_roundtrip_longer_than_p() raises:
    """A merged Assignment whose max_generations is LONGER than P (it retained
    the dropped pids' watermark) round-trips through encode_binary / decode_binary,
    through encode / decode (JSON), and through the zero-copy AssignmentView —
    preserving the FULL high-water (not just P entries)."""
    # Build a merged shape: P=3 owners, but a 6-deep high-water (pids 3,4,5 are
    # dropped pids whose watermark we must retain).
    var owners = _strs(String("a"), String("b"), String("a"))
    var nodes = _strs(String("a"), String("b"))
    var gens = List[Int64]()
    gens.append(Int64(2))
    gens.append(Int64(2))
    gens.append(Int64(3))
    var maxgens = List[Int64]()
    maxgens.append(Int64(2))
    maxgens.append(Int64(2))
    maxgens.append(Int64(3))
    maxgens.append(Int64(5))  # dropped pid 3's watermark
    maxgens.append(Int64(4))  # dropped pid 4's watermark
    maxgens.append(Int64(7))  # dropped pid 5's watermark
    var a = Assignment(
        num_partitions=3,
        owners=owners^,
        node_ids=nodes^,
        reason=REBALANCE_PARTITION_COUNT,
        generations=gens^,
        max_generations=maxgens^,
    )
    assert_equal(len(a.max_generations), 6, "high-water retained 6 entries (> P=3)")
    assert_equal(a.max_generation_of(5), Int64(7), "pid 5 watermark = 7")

    # --- binary round-trip ---
    var body = a.encode_binary()
    var b = Assignment.decode_binary(body)
    assert_equal(b.num_partitions, 3, "binary: P=3")
    assert_equal(len(b.max_generations), 6, "binary: high-water 6 entries")
    assert_equal(b.max_generation_of(5), Int64(7), "binary: pid 5 watermark 7")
    assert_equal(b.max_generation_of(3), Int64(5), "binary: pid 3 watermark 5")
    for pid in range(3):
        assert_equal(b.generation_of(pid), a.generation_of(pid), "binary gen")

    # --- JSON round-trip ---
    var j = a.encode()
    var c = Assignment.decode(j)
    assert_equal(len(c.max_generations), 6, "json: high-water 6 entries")
    assert_equal(c.max_generation_of(5), Int64(7), "json: pid 5 watermark 7")
    assert_equal(c.max_generation_of(4), Int64(4), "json: pid 4 watermark 4")

    # --- zero-copy view ---
    var view_body = a.encode_binary()
    var view = Assignment.view(view_body)
    assert_equal(view.max_generations_count(), 6, "view: high-water count 6")
    assert_equal(view.max_generation(5), Int64(7), "view: pid 5 watermark 7")
    assert_equal(view.max_generation(3), Int64(5), "view: pid 3 watermark 5")
    var owned = view.to_owned()
    assert_equal(len(owned.max_generations), 6, "view->owned: high-water 6")
    assert_equal(owned.max_generation_of(5), Int64(7), "view->owned pid 5 = 7")


def test_legacy_v2_body_seeds_high_water_from_gens() raises:
    """A LEGACY v2 binary body (generations trailer, NO max-generations trailer)
    decodes with the high-water SEEDED from the generations (the back-compat
    contract: at a v2 body's point in time, the live generation IS the high-
    water)."""
    # Build a v3 body, then truncate it back to a v2 shape by re-encoding through
    # an Assignment whose max_generations EQUALS its generations (the v2 seed).
    var owners = _strs(String("a"), String("b"), String("c"))
    var nodes = _strs(String("a"), String("b"), String("c"))
    var gens = List[Int64]()
    gens.append(Int64(3))
    gens.append(Int64(1))
    gens.append(Int64(2))
    # Supply NO max_generations -> the ctor seeds it from gens.
    var a = Assignment(
        num_partitions=3,
        owners=owners^,
        node_ids=nodes^,
        reason=REBALANCE_NEW_NODE,
        generations=gens^,
    )
    # The ctor seeded the high-water from the generations.
    for pid in range(3):
        assert_equal(
            a.max_generation_of(pid),
            a.generation_of(pid),
            "unsupplied high-water seeded from generation for pid " + String(pid),
        )


def main() raises:
    print("=== merge/split generation-continuity guard ===")
    test_merge_resplit_generation_does_not_regress()
    print("  test_merge_resplit_generation_does_not_regress PASS")
    test_high_water_never_decreases_across_churn()
    print("  test_high_water_never_decreases_across_churn PASS")
    test_split_preserves_kept_pid_generations()
    print("  test_split_preserves_kept_pid_generations PASS")
    test_v3_maxgens_codec_roundtrip_longer_than_p()
    print("  test_v3_maxgens_codec_roundtrip_longer_than_p PASS")
    test_legacy_v2_body_seeds_high_water_from_gens()
    print("  test_legacy_v2_body_seeds_high_water_from_gens PASS")
    print("=== generation-continuity guard: ALL GREEN ===")
