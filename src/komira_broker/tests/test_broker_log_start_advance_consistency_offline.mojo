# =============================================================================
# tests/test_broker_log_start_advance_consistency_offline.mojo
#   Concurrent log_start advance consistency
# =============================================================================
#
# `_advance_log_start_cas` has an "already past target -> no-op" fast path
# (retention.mojo, and the compaction worker in komira_broker_compaction).
# Checking ONLY `cur.log_start_seq >= new_seq` there is not enough: it must
# also validate that the concurrently-won `log_start_offset` is consistent
# with this pass's intended target. When retention + compaction advance the
# SAME `_LOG_START` concurrently and reach a DIVERGENT view of the contiguous
# offset log (a renumber / torn advance), the loser must not SILENTLY no-op
# past an inconsistent state.
#
# The invariant: `log_start_seq` and `log_start_offset` advance TOGETHER and
# monotonically (each advance moves both to the base of the first still-live
# chunk). So a won `log_start_seq >= new_seq` MUST carry a won `log_start_offset
# >= new_offset`. The already-advanced path validates that and raises
# fail-loud if the won offset is BEHIND this pass's target (an inconsistent
# concurrent advance), instead of silently no-oping.
#
# The cases: pre-write `_LOG_START` to an INCONSISTENT state (seq advanced
# PAST the target but offset BEHIND it), then drive `_advance_log_start_cas`:
# it must raise (a seq-only check would silently return True). The
# CONSISTENT case (won offset >= target) still no-ops cleanly.
#
# Hard-rule audit: no UnsafePointer in any signature, no wildcard origins,
# no unsafe_from_address / take_pointee.
# =============================================================================

from std.testing import assert_true, assert_false

from komira_broker.retention import RetentionPass, RetentionPolicy

from komira_objectstore.cas_manifest import (
    CasManifestStore,
    RetryPolicy,
    LogStart,
    encode_log_start,
    log_start_key,
)
from komira_objectstore.path import Path
from komira_objectstore.shared_in_memory_conditional_store import (
    SharedInMemoryConditionalStore,
)
from komira_objectstore.types import WritePrecondition


comptime _Store = SharedInMemoryConditionalStore


def _make_manifest(
    store: _Store, prefix: String
) raises -> CasManifestStore[_Store]:
    return CasManifestStore[_Store](
        store=store.clone(), prefix=prefix, retry=RetryPolicy.fast_test()
    )


def _force_write_log_start(
    store: _Store, prefix: String, offset: Int64, seq: Int64
) raises:
    """Directly PUT a `_LOG_START` object at (offset, seq) — used to seed an
    arbitrary (incl. INCONSISTENT) concurrent-pass-won state. This bypasses
    `advance_log_start`'s monotonicity guard to construct the divergent view
    that the already-advanced no-op path must catch."""
    var lk = log_start_key(prefix)
    var body = encode_log_start(LogStart(offset, seq, String("")))
    # Overwrite-or-create (unconditional) so the test can seed any state.
    _ = store.conditional_put(lk, body, WritePrecondition.none())


# =============================================================================
# (1) INCONSISTENT concurrent advance: won seq PAST target but won offset
#     BEHIND target → RAISES (a seq-only check would silently no-op).
# =============================================================================


def test_inconsistent_concurrent_advance_raises() raises:
    print("[test_inconsistent_concurrent_advance_raises] starting...")
    var store = _Store()
    var prefix = String("c1/_meta/topics/t/0")

    # A concurrent pass won the CAS and advanced seq to 5, offset to 100.
    _force_write_log_start(store, prefix, Int64(100), Int64(5))

    var manifest = _make_manifest(store, prefix)
    var rp = RetentionPass[_Store](RetentionPolicy.disabled())

    # This pass intended (seq=4, offset=150): a DIVERGENT view — its seq is
    # BEHIND the won seq (so the old no-op fires) but its offset is AHEAD of the
    # won offset (the inconsistency). The fix must REFUSE to silently no-op.
    var raised = False
    try:
        _ = rp._advance_log_start_cas(manifest, Int64(4), Int64(150))
    except e:
        raised = True
        assert_true(
            String(e).find("INCONSISTENT") >= 0,
            "raise names the inconsistent concurrent advance",
        )
    assert_true(
        raised,
        "advance_log_start_cas RAISES on an inconsistent concurrent advance"
        " (it must not silently no-op)",
    )
    print("[test_inconsistent_concurrent_advance_raises] PASS")


# =============================================================================
# (2) CONSISTENT concurrent advance: won seq AND offset both at/past target →
#     clean no-op (returns True, no raise). Guards against over-strictness.
# =============================================================================


def test_consistent_concurrent_advance_noops() raises:
    print("[test_consistent_concurrent_advance_noops] starting...")
    var store = _Store()
    var prefix = String("c2/_meta/topics/t/0")

    # A concurrent pass advanced to seq 5, offset 100 — CONSISTENT (both ahead).
    _force_write_log_start(store, prefix, Int64(100), Int64(5))

    var manifest = _make_manifest(store, prefix)
    var rp = RetentionPass[_Store](RetentionPolicy.disabled())

    # This pass intended a LOWER, consistent target (seq=4, offset=80): the won
    # state already satisfies it (offset 100 >= 80) → clean no-op, no raise.
    var ok = rp._advance_log_start_cas(manifest, Int64(4), Int64(80))
    assert_true(ok, "consistent already-advanced state no-ops cleanly (True)")
    print("[test_consistent_concurrent_advance_noops] PASS")


# =============================================================================
# (3) Exact-equal won state (seq == target seq, offset == target offset) →
#     clean no-op (the boundary: >= holds for both).
# =============================================================================


def test_exact_equal_advance_noops() raises:
    print("[test_exact_equal_advance_noops] starting...")
    var store = _Store()
    var prefix = String("c3/_meta/topics/t/0")
    _force_write_log_start(store, prefix, Int64(64), Int64(8))

    var manifest = _make_manifest(store, prefix)
    var rp = RetentionPass[_Store](RetentionPolicy.disabled())

    var ok = rp._advance_log_start_cas(manifest, Int64(8), Int64(64))
    assert_true(ok, "exact-equal won state no-ops cleanly (True)")
    print("[test_exact_equal_advance_noops] PASS")


def main() raises:
    test_inconsistent_concurrent_advance_raises()
    test_consistent_concurrent_advance_noops()
    test_exact_equal_advance_noops()
    print("ALL test_broker_log_start_advance_consistency_offline TESTS PASSED")
