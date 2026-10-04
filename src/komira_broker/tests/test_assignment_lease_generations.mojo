# =============================================================================
# tests/test_assignment_lease_generations.mojo
#   WRITER-LEASE-EPOCH FENCE — coordinator + codec gate.
# =============================================================================
#
# The writer-lease-epoch fence's per-partition lease-GENERATION
# source-of-truth living on the EXISTING `Assignment` blob. This gate proves the
# two load-bearing properties of that source-of-truth:
#
#   (A) `assign_partitions()` BUMPS generations[pid] monotonically when owners[pid]
#       CHANGES vs the prior assignment (the lease-acquire), and keeps it STABLE
#       when the owner is unchanged (the sticky-keep). This is what makes a
#       displaced owner's last-seen generation STRICTLY LESS than the live one —
#       the precondition the manifest append fence rejects.
#
#   (B) the BINARY codec (`encode_binary` / `decode_binary`) and the zero-copy
#       `AssignmentView` round-trip generations exactly, AND a LEGACY (v1, no-
#       generations-trailer) body decodes as all-zero generations (back-compat).
#
# These are pure-value tests (no store, no network) — the lease generation
# logic lives on the `Assignment` type + the `assign_partitions` pass.
# =============================================================================

from std.testing import assert_equal, assert_true

from komira_broker import (
    Assignment,
    AssignmentView,
    assign_partitions,
    REBALANCE_INITIAL,
    REBALANCE_NEW_NODE,
    REBALANCE_STALE_NODE,
)


def _strs(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(x)
    return out^


# =============================================================================
# (A) assign_partitions bump-on-transfer.
# =============================================================================
def test_initial_pass_seeds_generation_one() raises:
    """The INITIAL pass (no prior) acquires every partition: each assigned pid
    gets generation 1 (0 reserved for never-owned / legacy / unsupplied)."""
    var a = assign_partitions(
        _strs(String("a"), String("b"), String("c")),
        6,
        Optional[Assignment](),
        REBALANCE_INITIAL,
    )
    assert_equal(len(a.generations), 6, "generations co-sized with P")
    for pid in range(6):
        assert_equal(
            a.generation_of(pid),
            Int64(1),
            "initial generation == 1 for pid " + String(pid),
        )
    print("  test_initial_pass_seeds_generation_one: PASS")


def test_unchanged_owner_keeps_generation() raises:
    """A second pass with the SAME live set + same P -> REBALANCE_NONE / sticky:
    every owner is unchanged, so EVERY generation is STABLE (no bump)."""
    var first = assign_partitions(
        _strs(String("a"), String("b"), String("c")),
        6,
        Optional[Assignment](),
        REBALANCE_INITIAL,
    )
    var second = assign_partitions(
        _strs(String("a"), String("b"), String("c")),
        6,
        Optional[Assignment](first.copy()),
        REBALANCE_NEW_NODE,
    )
    for pid in range(6):
        # Same owner -> same generation (still 1).
        assert_equal(
            second.owner_of(pid), first.owner_of(pid), "owner stable pid " + String(pid)
        )
        assert_equal(
            second.generation_of(pid),
            first.generation_of(pid),
            "generation stable for unchanged owner pid " + String(pid),
        )
        assert_equal(second.generation_of(pid), Int64(1), "still gen 1")
    print("  test_unchanged_owner_keeps_generation: PASS")


def test_owner_change_bumps_generation_monotonically() raises:
    """A TRANSFER (owner changes for a pid) bumps THAT pid's generation by exactly
    one; unchanged pids keep their generation. Drive a node death so a subset of
    partitions move and prove the moved ones bump while the stayed ones do not."""
    # Initial: 3 nodes, 6 partitions (a:[0,3], b:[1,4], c:[2,5]).
    var first = assign_partitions(
        _strs(String("a"), String("b"), String("c")),
        6,
        Optional[Assignment](),
        REBALANCE_INITIAL,
    )
    # Node "c" dies — its partitions (2, 5) must move to a/b; a/b keep theirs.
    var after = assign_partitions(
        _strs(String("a"), String("b")),
        6,
        Optional[Assignment](first.copy()),
        REBALANCE_STALE_NODE,
    )
    var bumped = 0
    var stable = 0
    for pid in range(6):
        if after.owner_of(pid) == first.owner_of(pid):
            # Unchanged owner -> generation must be stable.
            assert_equal(
                after.generation_of(pid),
                first.generation_of(pid),
                "stable gen for unchanged pid " + String(pid),
            )
            stable += 1
        else:
            # Transferred -> generation bumped by exactly 1 (monotone).
            assert_equal(
                after.generation_of(pid),
                first.generation_of(pid) + Int64(1),
                "bumped gen for transferred pid " + String(pid),
            )
            bumped += 1
    assert_true(bumped >= 2, "c's 2 partitions transferred (bumped)")
    assert_true(stable >= 1, "a/b kept some partitions (stable)")
    print("  test_owner_change_bumps_generation_monotonically: PASS")


def test_generations_never_decrease_across_churn() raises:
    """Drive several churn rounds (membership changes) and assert that for every
    partition the generation is MONOTONE NON-DECREASING across rounds (it never
    resets / never drops). This is the global invariant the fence depends on."""
    var prior = Optional[Assignment]()
    var last_gen = List[Int64]()
    for _ in range(6):
        last_gen.append(Int64(-1))
    # Round 0: a,b,c. Round 1: a,b (c dies). Round 2: a,b,c,d (c back + d joins).
    # Round 3: b,c,d (a dies). Each round generations[pid] >= last round.
    var rounds = List[List[String]]()
    rounds.append(_strs(String("a"), String("b"), String("c")))
    rounds.append(_strs(String("a"), String("b")))
    rounds.append(_strs(String("a"), String("b"), String("c"), String("d")))
    rounds.append(_strs(String("b"), String("c"), String("d")))
    for r in range(len(rounds)):
        var asg = assign_partitions(
            rounds[r].copy(), 6, prior^, REBALANCE_NEW_NODE
        )
        for pid in range(6):
            assert_true(
                asg.generation_of(pid) >= last_gen[pid],
                "generation monotone non-decreasing pid "
                + String(pid)
                + " round "
                + String(r),
            )
            last_gen[pid] = asg.generation_of(pid)
        prior = Optional[Assignment](asg.copy())
    print("  test_generations_never_decrease_across_churn: PASS")


def test_generations_for_node_parallel_to_partitions_for() raises:
    """`generations_for(node)` is POSITIONALLY PARALLEL to `partitions_for(node)`
    — the (pid, generation) lease pairs the heartbeat delivers to the owner."""
    var asg = assign_partitions(
        _strs(String("a"), String("b"), String("c")),
        6,
        Optional[Assignment](),
        REBALANCE_INITIAL,
    )
    for ni in range(3):
        var node = asg.node_ids[ni]
        var pids = asg.partitions_for(node)
        var gens = asg.generations_for(node)
        assert_equal(
            len(pids), len(gens), "parallel lengths for node " + node
        )
        for i in range(len(pids)):
            assert_equal(
                gens[i],
                asg.generation_of(Int(pids[i])),
                "generations_for[i] == generation_of(partitions_for[i])",
            )
    print("  test_generations_for_node_parallel_to_partitions_for: PASS")


# =============================================================================
# (B) codec + view round-trip generations; legacy decodes as zeros.
# =============================================================================
def test_binary_roundtrip_preserves_generations() raises:
    """encode_binary -> decode_binary preserves the generations array exactly."""
    var gens = List[Int64]()
    gens.append(Int64(1))
    gens.append(Int64(5))
    gens.append(Int64(2))
    gens.append(Int64(9))
    var a = Assignment(
        num_partitions=4,
        owners=_strs(String("a"), String("b"), String("a"), String("b")),
        node_ids=_strs(String("a"), String("b")),
        reason=REBALANCE_NEW_NODE,
        generations=gens^,
    )
    var body = a.encode_binary()
    var b = Assignment.decode_binary(body)
    assert_equal(len(b.generations), 4, "decoded generations len")
    assert_equal(b.generation_of(0), Int64(1), "gen[0]")
    assert_equal(b.generation_of(1), Int64(5), "gen[1]")
    assert_equal(b.generation_of(2), Int64(2), "gen[2]")
    assert_equal(b.generation_of(3), Int64(9), "gen[3]")
    print("  test_binary_roundtrip_preserves_generations: PASS")


def test_view_reads_generations_zero_copy() raises:
    """The zero-copy AssignmentView reads per-pid generations DIRECTLY from the
    v2 trailer (same values the owned decode produces)."""
    var gens = List[Int64]()
    gens.append(Int64(3))
    gens.append(Int64(8))
    gens.append(Int64(3))
    var a = Assignment(
        num_partitions=3,
        owners=_strs(String("x"), String("y"), String("x")),
        node_ids=_strs(String("x"), String("y")),
        reason=REBALANCE_NEW_NODE,
        generations=gens^,
    )
    var body = a.encode_binary()
    var view = AssignmentView(Span[UInt8](body))
    assert_equal(view.generation(0), Int64(3), "view gen[0]")
    assert_equal(view.generation(1), Int64(8), "view gen[1]")
    assert_equal(view.generation(2), Int64(3), "view gen[2]")
    print("  test_view_reads_generations_zero_copy: PASS")


def test_legacy_v1_body_decodes_generations_as_zero() raises:
    """A LEGACY v1 body (no generations trailer) decodes as ALL-ZERO generations
    (the back-compat contract). We hand-build a v1 body (the exact shape the prior
    encoder emitted: header + node table + owners array, NO trailer) and assert
    decode yields zero generations + the owned + zero-copy paths agree."""
    # v1 body: magic | ver=1 | reserved | P=2 i32 | reason i32 | node_count=2 u32 |
    #          [len u16 | "a"] [len u16 | "b"] | owners_count=2 u32 | owner u16 x2
    var body = List[UInt8]()
    # magic 0x42415353 LE
    body.append(UInt8(0x53)); body.append(UInt8(0x53))
    body.append(UInt8(0x41)); body.append(UInt8(0x42))
    # version 1 LE (legacy — no generations trailer)
    body.append(UInt8(1)); body.append(UInt8(0))
    # reserved 0
    body.append(UInt8(0)); body.append(UInt8(0))
    # P = 2 (i32 LE)
    body.append(UInt8(2)); body.append(UInt8(0)); body.append(UInt8(0)); body.append(UInt8(0))
    # reason = 1 (i32 LE)
    body.append(UInt8(1)); body.append(UInt8(0)); body.append(UInt8(0)); body.append(UInt8(0))
    # node_count = 2 (u32 LE)
    body.append(UInt8(2)); body.append(UInt8(0)); body.append(UInt8(0)); body.append(UInt8(0))
    # node[0]: len=1, "a"
    body.append(UInt8(1)); body.append(UInt8(0)); body.append(UInt8(ord("a")))
    # node[1]: len=1, "b"
    body.append(UInt8(1)); body.append(UInt8(0)); body.append(UInt8(ord("b")))
    # owners_count = 2 (u32 LE)
    body.append(UInt8(2)); body.append(UInt8(0)); body.append(UInt8(0)); body.append(UInt8(0))
    # owner[0] = 0 (u16 LE), owner[1] = 1 (u16 LE)  -- the v1 body ENDS HERE
    body.append(UInt8(0)); body.append(UInt8(0))
    body.append(UInt8(1)); body.append(UInt8(0))

    var decoded = Assignment.decode_binary(body)
    assert_equal(decoded.num_partitions, 2, "P decoded")
    assert_equal(decoded.owner_of(0), String("a"), "owner[0]")
    assert_equal(decoded.owner_of(1), String("b"), "owner[1]")
    assert_equal(len(decoded.generations), 2, "generations padded to P")
    assert_equal(decoded.generation_of(0), Int64(0), "legacy gen[0] == 0")
    assert_equal(decoded.generation_of(1), Int64(0), "legacy gen[1] == 0")

    # The zero-copy view of the SAME v1 body also reads generation 0.
    var view = AssignmentView(Span[UInt8](body))
    assert_equal(view.generation(0), Int64(0), "view legacy gen[0] == 0")
    assert_equal(view.generation(1), Int64(0), "view legacy gen[1] == 0")
    print("  test_legacy_v1_body_decodes_generations_as_zero: PASS")


def test_json_roundtrip_preserves_generations() raises:
    """The JSON encode/decode also carries generations (for consistency with the
    binary codec); a legacy JSON with no "gens" field decodes as zeros."""
    var gens = List[Int64]()
    gens.append(Int64(4))
    gens.append(Int64(1))
    var a = Assignment(
        num_partitions=2,
        owners=_strs(String("a"), String("b")),
        node_ids=_strs(String("a"), String("b")),
        reason=REBALANCE_NEW_NODE,
        generations=gens^,
    )
    var text = a.encode()
    var b = Assignment.decode(text)
    assert_equal(b.generation_of(0), Int64(4), "json gen[0]")
    assert_equal(b.generation_of(1), Int64(1), "json gen[1]")

    # A legacy JSON (no "gens") decodes as zeros.
    var legacy = String(
        '{"p":2,"reason":1,"nodes":["a","b"],"owners":["a","b"]}'
    )
    var c = Assignment.decode(legacy)
    assert_equal(len(c.generations), 2, "legacy json generations padded")
    assert_equal(c.generation_of(0), Int64(0), "legacy json gen[0] == 0")
    assert_equal(c.generation_of(1), Int64(0), "legacy json gen[1] == 0")
    print("  test_json_roundtrip_preserves_generations: PASS")


def main() raises:
    test_initial_pass_seeds_generation_one()
    test_unchanged_owner_keeps_generation()
    test_owner_change_bumps_generation_monotonically()
    test_generations_never_decrease_across_churn()
    test_generations_for_node_parallel_to_partitions_for()
    test_binary_roundtrip_preserves_generations()
    test_view_reads_generations_zero_copy()
    test_legacy_v1_body_decodes_generations_as_zero()
    test_json_roundtrip_preserves_generations()
    print("test_assignment_lease_generations: ALL PASS")
