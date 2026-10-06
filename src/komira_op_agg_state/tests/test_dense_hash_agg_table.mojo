# =============================================================================
# test_dense_hash_agg_table.mojo — DENSE-HASH-AGG Phase 1 correctness tests
# =============================================================================
#
# Direct unit tests for the growing dense single-I64-key hash-agg table
# (`HashAggTableI64` / `HashAggTableF64` over the `_DenseAggDirectory`) that
# replaced the fixed-16 `MAX_GROUPS=16` table — the silent-saturation
# correctness bug (RFC an internal doc §1.1).
#
# These tests drive the table internals directly (no SDK / parquet) so the
# saturation / resize / index-stability behavior is asserted in isolation,
# without the lowering-path noise. The SDK e2e gate lives in
# `test_cb_correctness_regression.mojo` / the lower_untyped agg e2e tests.
#
# Coverage (RFC §9.1):
#   - 17-group boundary: the exact off-by-one that used to corrupt at the
#     old 16-cap -> 17 distinct keys must yield 17 correct groups.
#   - 1M distinct groups: no saturation; n_groups == 1M; each group exact.
#   - resize-correctness: groups stable across multiple grow boundaries with
#     interleaved re-updates to the same keys (the §7.4 index-stability
#     invariant).
#   - multi-agg routing parity: SUM vs COUNT on the same 5000-key set route to
#     the correct typed state array.
#   - gap6 destroy-recreate stress: a Movable carrier holding the dense table,
#     destroyed + reconstructed in a loop, no stale-byte corruption.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_state.hash_agg_table import (
    HashAggTableF64,
    HashAggTableI64,
)
from komira_op_agg_state.dense_hash_agg_table import (
    DENSE_INITIAL_CAPACITY,
)
from komira_op_agg_state.agg_state_slab import (
    CountI64,
    MaxI64,
    MinI64,
    SumF64,
    SumI64,
)


# =============================================================================
# §1 — 17-group boundary (the exact off-by-one past the old 16-cap)
# =============================================================================


def test_17_group_boundary() raises:
    """17 distinct keys, SUM(value=key). Before the dense fix this saturated to
    16 groups and folded the 17th key into bucket 0. Must now yield 17
    distinct groups, each summing exactly its own key once."""
    var table = HashAggTableI64[SumI64]()
    for k in range(17):
        # Feed each distinct key once with value == key.
        table.update_scalar(Int64(k), Int64(k))

    assert_equal(table.size(), 17, "17 distinct keys -> 17 dense groups")

    # Every group's SUM must equal its own key (each fed exactly once); no
    # group may carry another key's contribution (the saturation symptom).
    var seen = List[Bool]()
    for _ in range(17):
        seen.append(False)
    for g in range(table.size()):
        var key = Int(table.key_at(g))
        var s = Int(table.finalize_at(g))
        assert_true(key >= 0 and key < 17, "key in domain")
        assert_equal(s, key, "group SUM == its own key (no fold)")
        assert_true(not seen[key], "no duplicate group for the same key")
        seen[key] = True
    for k in range(17):
        assert_true(seen[k], "every key 0..16 present exactly once")


# =============================================================================
# §2 — 1M distinct groups (no saturation; the b2/h7 stress shape)
# =============================================================================


def test_1m_distinct_groups() raises:
    """1,000,000 distinct keys, COUNT per group, each key fed 3 times. Asserts
    n_groups == 1M and a sampled set of groups each have COUNT == 3 with the
    correct key. Guards saturation forever."""
    var n = 1_000_000
    var table = HashAggTableI64[CountI64]()
    for k in range(n):
        # CountI64 ignores value; feed each key 3 times.
        table.update_scalar(Int64(k), Int64(0))
        table.update_scalar(Int64(k), Int64(0))
        table.update_scalar(Int64(k), Int64(0))

    assert_equal(table.size(), n, "1M distinct keys -> 1M dense groups")

    # Re-probe a sample of keys: each must resolve to a group with COUNT == 3.
    var probe_keys = List[Int]()
    probe_keys.append(0)
    probe_keys.append(1)
    probe_keys.append(15)
    probe_keys.append(16)
    probe_keys.append(17)
    probe_keys.append(2047)
    probe_keys.append(2048)
    probe_keys.append(500_000)
    probe_keys.append(n - 1)
    for i in range(len(probe_keys)):
        var key = probe_keys[i]
        var g = table.lookup_or_insert(Int64(key))
        assert_equal(
            table.size(), n, "lookup of an existing key must not insert"
        )
        assert_equal(Int(table.key_at(g)), key, "group key round-trips")
        assert_equal(Int(table.finalize_at(g)), 3, "each key counted 3x")


# =============================================================================
# §3 — resize-correctness across multiple grow boundaries (index-stability)
# =============================================================================


def test_resize_index_stability() raises:
    """Insert keys spanning several grow boundaries (2048 -> 4096 -> ...),
    then re-update every key a second time. Group_ids must stay stable across
    resizes (RFC §7.4) so the second-pass updates land on the same group as
    the first — assert each group's SUM == 2*key."""
    var n = 10_000  # forces multiple doublings past the 2048 initial cap.
    var table = HashAggTableI64[SumI64]()

    # First pass: insert each key with value == key.
    for k in range(n):
        table.update_scalar(Int64(k), Int64(k))
    assert_equal(table.size(), n, "n distinct groups after first pass")
    assert_true(
        table.capacity() > DENSE_INITIAL_CAPACITY,
        "directory must have grown past the initial capacity",
    )

    # Capture each key's group_id; re-update; the group_id must be identical
    # (positional stability), and the SUM must double.
    for k in range(n):
        var g_before = table.lookup_or_insert(Int64(k))
        table.update_scalar(Int64(k), Int64(k))
        var g_after = table.lookup_or_insert(Int64(k))
        assert_equal(g_before, g_after, "group_id stable across re-probe")

    assert_equal(table.size(), n, "no new groups from the second pass")
    for g in range(table.size()):
        var key = Int(table.key_at(g))
        assert_equal(
            Int(table.finalize_at(g)), 2 * key, "SUM == 2*key after two passes"
        )


# =============================================================================
# §4 — multi-agg routing parity (SUM vs COUNT on the same key set)
# =============================================================================


def test_multi_agg_routing_parity() raises:
    """Two parallel typed tables (SUM and COUNT) fed the SAME 5000-key set,
    each key appearing twice with value == key. The SUM table must scatter to
    its Int64 sum state; the COUNT table to its count state; neither may
    mis-route (RFC §5.2). Both tables must agree on the group set."""
    var n = 5_000
    var sum_table = HashAggTableI64[SumI64]()
    var count_table = HashAggTableI64[CountI64]()
    for k in range(n):
        sum_table.update_scalar(Int64(k), Int64(k))
        sum_table.update_scalar(Int64(k), Int64(k))
        count_table.update_scalar(Int64(k), Int64(k))
        count_table.update_scalar(Int64(k), Int64(k))

    assert_equal(sum_table.size(), n, "sum table sees n groups")
    assert_equal(count_table.size(), n, "count table sees n groups")

    for k in range(n):
        var gs = sum_table.lookup_or_insert(Int64(k))
        var gc = count_table.lookup_or_insert(Int64(k))
        assert_equal(Int(sum_table.finalize_at(gs)), 2 * k, "SUM == 2*key")
        assert_equal(Int(count_table.finalize_at(gc)), 2, "COUNT == 2")


# =============================================================================
# §5 — MIN / MAX correctness past the old cap
# =============================================================================


def test_min_max_past_cap() raises:
    """MIN and MAX over 1000 groups, each fed a descending then ascending
    value, must report the true extrema (not a folded bucket-0 value)."""
    var n = 1_000
    var min_table = HashAggTableI64[MinI64]()
    var max_table = HashAggTableI64[MaxI64]()
    for k in range(n):
        # Feed values key*10 and key*10 + 5 for each key.
        min_table.update_scalar(Int64(k), Int64(k * 10 + 5))
        min_table.update_scalar(Int64(k), Int64(k * 10))
        max_table.update_scalar(Int64(k), Int64(k * 10))
        max_table.update_scalar(Int64(k), Int64(k * 10 + 5))

    assert_equal(min_table.size(), n, "min table n groups")
    assert_equal(max_table.size(), n, "max table n groups")
    for k in range(n):
        var gmin = min_table.lookup_or_insert(Int64(k))
        var gmax = max_table.lookup_or_insert(Int64(k))
        assert_equal(Int(min_table.finalize_at(gmin)), k * 10, "MIN == k*10")
        assert_equal(
            Int(max_table.finalize_at(gmax)), k * 10 + 5, "MAX == k*10+5"
        )


# =============================================================================
# §6 — F64-state table over many groups (the Float64-agg single-key path)
# =============================================================================


def test_f64_agg_many_groups() raises:
    """SumF64 over 3000 groups; assert each group's running float sum is
    exact (the Float64-state dense table, used by the F64 single-key path)."""
    var n = 3_000
    var table = HashAggTableF64[SumF64]()
    for k in range(n):
        table.update_scalar(Int64(k), Float64(k) + 0.5)
        table.update_scalar(Int64(k), Float64(k) + 0.25)
    assert_equal(table.size(), n, "n F64 groups")
    for k in range(n):
        var g = table.lookup_or_insert(Int64(k))
        var expected = (Float64(k) + 0.5) + (Float64(k) + 0.25)
        assert_true(
            table.finalize_at(g) == expected, "F64 SUM exact per group"
        )


# =============================================================================
# §7 — reset clears all groups
# =============================================================================


def test_reset_clears() raises:
    """`reset` must clear the dense directory + side arrays so the table is
    re-usable with a fresh group space."""
    var table = HashAggTableI64[SumI64]()
    for k in range(100):
        table.update_scalar(Int64(k), Int64(k))
    assert_equal(table.size(), 100, "100 groups before reset")

    table.reset()
    assert_equal(table.size(), 0, "0 groups after reset")

    # Re-use: a fresh key set must start group_ids at 0 again.
    var g = table.lookup_or_insert(Int64(42))
    assert_equal(g, 0, "first post-reset insert -> group_id 0")
    table.update_scalar(Int64(42), Int64(7))
    assert_equal(Int(table.finalize_at(g)), 7, "post-reset SUM correct")


# =============================================================================
# §8 — gap6 destroy-recreate stress
# =============================================================================
#
# A Movable carrier holds the dense table (the shape RuntimeBreakerState /
# Stage.state use). Destroy + reconstruct it in a loop; if any wildcard-origin
# / stale-byte hazard existed in the dense storage, a destroy-recreate cycle
# would reinterpret freed bytes (gap6). All-List[POD] storage is gap6-clean by
# construction (RFC §7.1 / §7.3); this test exercises that under churn.
# =============================================================================


@fieldwise_init
struct _DenseTableCarrier(Movable):
    """Minimal Movable carrier holding the dense table — mirrors the
    RuntimeBreakerState / Stage.state ownership shape."""

    var table: HashAggTableI64[SumI64]

    @staticmethod
    def make() -> _DenseTableCarrier:
        return _DenseTableCarrier(table=HashAggTableI64[SumI64]())


def test_gap6_destroy_recreate_stress() raises:
    """Build, populate, drain, drop, and rebuild the carrier across many
    cycles. Each cycle loads >cap groups (forces a resize) so the heap-owning
    Lists are allocated + freed every iteration — the destroy-recreate churn
    that surfaces gap6 stale-byte corruption."""
    var cycles = 50
    var per_cycle = 3_000  # > DENSE_INITIAL_CAPACITY => forces a grow
    for c in range(cycles):
        var carrier = _DenseTableCarrier.make()
        for k in range(per_cycle):
            # Vary the values per cycle so a stale-byte read would mismatch.
            carrier.table.update_scalar(Int64(k), Int64(k + c))
        assert_equal(
            carrier.table.size(), per_cycle, "groups correct each cycle"
        )
        # Drain-shaped sweep + spot check.
        var g0 = carrier.table.lookup_or_insert(Int64(0))
        var glast = carrier.table.lookup_or_insert(Int64(per_cycle - 1))
        assert_equal(Int(carrier.table.key_at(g0)), 0, "key 0 round-trips")
        assert_equal(Int(carrier.table.finalize_at(g0)), c, "SUM(key0) == c")
        assert_equal(
            Int(carrier.table.finalize_at(glast)),
            (per_cycle - 1) + c,
            "SUM(last key) == key + c",
        )
        # carrier dropped here at end of scope -> Lists freed.


# =============================================================================
# main
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_17_group_boundary]()
    suite.test[test_1m_distinct_groups]()
    suite.test[test_resize_index_stability]()
    suite.test[test_multi_agg_routing_parity]()
    suite.test[test_min_max_past_cap]()
    suite.test[test_f64_agg_many_groups]()
    suite.test[test_reset_clears]()
    suite.test[test_gap6_destroy_recreate_stress]()
    suite^.run()
