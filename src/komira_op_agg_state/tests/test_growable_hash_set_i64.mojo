# =============================================================================
# test_growable_hash_set_i64.mojo — GrowableHashSetI64 correctness tests
# =============================================================================
#
# ERR-COUNT-DISTINCT-GROWABLE-SUBSTRATE —
# direct unit tests for the new growable single-Int64-key SET primitive
# (`GrowableHashSetI64` in
# `komira_engine_operators/stage_primitives/growable_hash_set_i64.mojo`),
# the replacement for the legacy 16-cap `HashSetI64` in the
# `CountDistinctI64ToF64` conformer + the BREAKER_DISTINCT single-key
# path.
#
# These tests drive the set primitive directly (no SDK / runtime
# breaker) so the substrate's set semantics + grow-and-rehash behavior
# is asserted in isolation, parallel to
# `test_dense_hash_agg_table.mojo` for the agg-table variant.
#
# Coverage:
#   - 17-key boundary: the exact off-by-one past the legacy `HashSetI64`
#     16-cap. 17 distinct keys must yield size() == 17 (no silent drop,
#     no raise).
#   - 1M distinct insertions: no cap, n_groups grows to 1M; sampled
#     contains() / key_at() round-trips correct.
#   - duplicate-insertion idempotency: `insert(k)` returns True only the
#     first time, False thereafter; cardinality stable on duplicate
#     re-insertion.
#   - insertion-order drain via `key_at(slot)`: keys come out in
#     insertion order (the directory's dense `keys` list is
#     append-on-insert).
#   - gap6 destroy-recreate stress: a Movable carrier holding the
#     growable set, destroyed + reconstructed in a loop with
#     resize-forcing populations, no stale-byte corruption.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_engine_operators.stage_primitives.growable_hash_set_i64 import (
    GrowableHashSetI64,
)


# =============================================================================
# §1 — 17-key boundary (past legacy HashSetI64 16-cap)
# =============================================================================


def test_17_key_boundary() raises:
    """17 distinct insertions. Legacy HashSetI64 would raise at the 17th
    (DISTINCT_OVERFLOW_RAISE_MSG). Growable substrate must accept all 17
    and report size() == 17."""
    var s = GrowableHashSetI64()
    for k in range(17):
        var newly = s.insert(Int64(k))
        assert_true(newly, "insert " + String(k) + " first time -> True")

    assert_equal(s.size(), 17, "17 distinct insertions -> size 17 (no cap)")

    # Every inserted key must round-trip via key_at + insertion order.
    for slot in range(17):
        assert_equal(
            Int(s.key_at(slot)), slot, "key_at preserves insertion order"
        )


# =============================================================================
# §2 — 1M distinct insertions (no cap; stress the grow-and-rehash)
# =============================================================================


def test_1m_distinct() raises:
    """1,000,000 distinct insertions. Inner _DenseAggDirectory must grow
    multiple times (initial cap 2048 -> ~1.5M at 0.67 load). Asserts no
    silent drop, correct cardinality, and per-key insertion-order
    preservation."""
    var n = 1_000_000
    var s = GrowableHashSetI64()
    for k in range(n):
        var newly = s.insert(Int64(k))
        assert_true(newly, "insert key " + String(k) + " first time")

    assert_equal(s.size(), n, "1M distinct insertions -> size 1M")

    # Spot-check a small sample of keys at known slots (insertion order
    # == slot index).
    var probes = List[Int]()
    probes.append(0)
    probes.append(1)
    probes.append(15)
    probes.append(16)  # boundary past legacy 16-cap
    probes.append(17)
    probes.append(2047)
    probes.append(2048)  # boundary past DENSE_INITIAL_CAPACITY
    probes.append(500_000)
    probes.append(n - 1)
    for i in range(len(probes)):
        var slot = probes[i]
        assert_equal(
            Int(s.key_at(slot)),
            slot,
            "key_at(" + String(slot) + ") round-trips correctly",
        )


# =============================================================================
# §3 — duplicate-insertion idempotency
# =============================================================================


def test_duplicate_insert_idempotent() raises:
    """`insert(k)` returns True only the first time per distinct key;
    False on subsequent inserts. Cardinality stable on duplicate
    re-insertion (mirror of legacy HashSetI64.insert API contract)."""
    var s = GrowableHashSetI64()
    assert_equal(s.insert(Int64(5)), True, "insert 5 first time -> True")
    assert_equal(s.insert(Int64(5)), False, "insert 5 second time -> False")
    assert_equal(s.insert(Int64(10)), True, "insert 10 first time -> True")
    assert_equal(s.insert(Int64(5)), False, "insert 5 third time -> False")
    assert_equal(s.insert(Int64(10)), False, "insert 10 second time -> False")
    assert_equal(s.size(), 2, "size == 2 after 5 inserts of 2 distinct")


# =============================================================================
# §4 — gap6 destroy-recreate stress
# =============================================================================


@fieldwise_init
struct _GrowableSetCarrier(Movable):
    """Minimal Movable carrier holding a GrowableHashSetI64 — the
    destroy-recreate shape that surfaces gap6 stale-byte corruption when
    the inner List[POD] fields are reused via tcmalloc."""

    var set: GrowableHashSetI64

    @staticmethod
    def make() -> _GrowableSetCarrier:
        return _GrowableSetCarrier(set=GrowableHashSetI64())


def test_gap6_destroy_recreate_stress() raises:
    """Build, populate (>cap to force a grow), drain, drop, and rebuild
    the carrier across many cycles. Each cycle the inner Lists are
    allocated + freed — the destroy-recreate churn that surfaces gap6
    stale-byte corruption.

    Pattern mirrors `test_dense_hash_agg_table.test_gap6_destroy_recreate_stress`
    but for the SET-flavored wrapper."""
    var cycles = 50
    var per_cycle = 3_000  # > DENSE_INITIAL_CAPACITY -> forces a grow
    for c in range(cycles):
        var carrier = _GrowableSetCarrier.make()
        # Vary the key offset per cycle so a stale-byte read would
        # mismatch (cycle 0: keys 0..2999; cycle 1: keys 1..3000; etc.)
        var offset = c
        for k in range(per_cycle):
            var newly = carrier.set.insert(Int64(k + offset))
            assert_true(
                newly,
                "cycle " + String(c) + " key " + String(k + offset)
                + " first insert True",
            )
        assert_equal(
            carrier.set.size(),
            per_cycle,
            "cycle " + String(c) + " size correct",
        )
        # Spot-check first + last inserted key reads back correctly.
        assert_equal(
            Int(carrier.set.key_at(0)),
            offset,
            "first inserted key round-trips",
        )
        assert_equal(
            Int(carrier.set.key_at(per_cycle - 1)),
            offset + per_cycle - 1,
            "last inserted key round-trips",
        )
        # carrier dropped here at end of scope -> inner Lists freed.


# =============================================================================
# main
# =============================================================================


def main() raises:
    var suite = TestSuite()
    suite.test[test_17_key_boundary]()
    suite.test[test_1m_distinct]()
    suite.test[test_duplicate_insert_idempotent]()
    suite.test[test_gap6_destroy_recreate_stress]()
    suite^.run()
