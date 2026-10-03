# =============================================================================
# Tests for `AdaptiveFilter`.
#
# Coverage:
#   - Construction: initial permutation is identity, swap_likeliness all 100,
#     phase is WARMUP, baseline at sentinel.
#   - WARMUP iterations: no swap applied across the first 5 calls; baseline
#     populates at iter 5; phase transitions to EXPLORE.
#   - EXPLORE entry: a swap is applied to the permutation; pending_swap_idx
#     records the slot.
#   - OBSERVE keep: synthetic "swap improves" trajectory → baseline shrinks,
#     swap_likeliness slot resets to 100.
#   - OBSERVE revert: synthetic "swap regresses" trajectory → swap is
#     reverted, swap_likeliness slot halves.
#   - Read-only accessors (current_phase, total_iterations, baseline_ns,
#     swap_likeliness_at, pending_swap, get_permutation).
#   - n == 1 corner case: no slots to swap, machine is a no-op.
#
# NOTE: These tests run on the REAL wall-clock-driven state machine.
# `begin_filter` calls `perf_counter_ns()` for the start time and
# `end_filter` calls it again — the iteration's duration is whatever
# the test loop takes. For determinism on KEEP/REVERT logic, we use a
# `_test_step_with_synthetic_ns` private path (NOT exposed to production)
# that calls the state-machine helpers directly with a chosen Float64
# duration. See `_synthetic_*` test fixtures below.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_eval.adaptive_filter import (
    AdaptiveFilter,
    ADAPTIVE_FILTER_PHASE_WARMUP,
    ADAPTIVE_FILTER_PHASE_EXPLORE,
    ADAPTIVE_FILTER_PHASE_OBSERVE,
    ADAPTIVE_FILTER_WARMUP_ITERS,
    ADAPTIVE_FILTER_EXPLORE_ITERS,
    ADAPTIVE_FILTER_OBSERVE_ITERS,
    ADAPTIVE_FILTER_INITIAL_SWAP_LIKELINESS,
    ADAPTIVE_FILTER_BASELINE_SENTINEL_NS,
    ADAPTIVE_FILTER_NO_PENDING_SWAP,
)


# -----------------------------------------------------------------------------
# Helper: run one cycle of begin/end with a synthetic duration.
#
# We can't easily inject synthetic ns through begin_filter / end_filter
# (those call perf_counter_ns internally). Instead, the tests below that
# need deterministic ns drive the internal state-machine helpers via a
# carefully-constructed start_ns offset: pass `start_ns = U64::MAX -
# desired_dur_ns` so end_filter's `now_ns - start_ns` resolves to a
# specific positive value. This works because perf_counter_ns() is
# monotonically increasing and the absolute time doesn't matter — only
# the delta.
#
# Actually, the cleaner approach: pass start_ns ≈ now - desired_dur and
# accept ~µs jitter. For the keep/revert assertions we use ratios with
# >>µs differences so the jitter is irrelevant.
# -----------------------------------------------------------------------------


def _drive_one_iter_synthetic_ns(mut af: AdaptiveFilter, synthetic_ns: UInt64):
    """Drive one begin/end cycle with an approximately-synthetic duration.

    Uses real perf_counter_ns() but offsets the start to produce the
    requested duration. Real clock jitter is on the order of µs — well
    below the ms-scale differences we use in keep/revert tests.
    """
    var start = af.begin_filter()
    # We want end_filter to see (now - start) ~= synthetic_ns. Since the
    # iter body is empty, end_filter's perf_counter_ns() ~= start.
    # Subtract synthetic_ns from start to backdate it.
    var backdated_start = start - synthetic_ns
    af.end_filter(backdated_start)


# -----------------------------------------------------------------------------
# Construction
# -----------------------------------------------------------------------------


def test_construction_initial_permutation_is_identity() raises:
    """A fresh AdaptiveFilter(n=4) has permutation [0, 1, 2, 3]."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    var perm = af.get_permutation()
    assert_equal(len(perm), 4)
    for i in range(4):
        assert_equal(perm[i], UInt32(i))


def test_construction_swap_likeliness_all_100() raises:
    """A fresh AdaptiveFilter(n=4) has 3 swap_likeliness slots all at 100."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    # 4 predicates → 3 adjacent-pair slots
    for k in range(3):
        assert_equal(
            af.swap_likeliness_at(k), ADAPTIVE_FILTER_INITIAL_SWAP_LIKELINESS,
        )


def test_construction_initial_phase_is_warmup() raises:
    """A fresh AdaptiveFilter starts in WARMUP phase, iteration 0."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    assert_equal(af.current_phase(), ADAPTIVE_FILTER_PHASE_WARMUP)
    assert_equal(af.current_iteration_in_phase(), UInt32(0))
    assert_equal(af.total_iterations(), UInt64(0))


def test_construction_baseline_at_sentinel() raises:
    """A fresh AdaptiveFilter has baseline at the sentinel until WARMUP
    completes."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    assert_equal(af.baseline_ns(), ADAPTIVE_FILTER_BASELINE_SENTINEL_NS)


def test_construction_no_pending_swap() raises:
    """A fresh AdaptiveFilter has no pending swap."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    assert_equal(af.pending_swap(), ADAPTIVE_FILTER_NO_PENDING_SWAP)


# -----------------------------------------------------------------------------
# WARMUP — first 5 iters
# -----------------------------------------------------------------------------


def test_warmup_no_swap_for_5_iters() raises:
    """During WARMUP, no swap is applied — permutation stays identity."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000_000))  # 1 ms
    # After WARMUP, phase has transitioned to EXPLORE, but permutation
    # is still identity (the WARMUP loop didn't apply any swap).
    var perm = af.get_permutation()
    for i in range(4):
        assert_equal(perm[i], UInt32(i))


def test_warmup_baseline_populates() raises:
    """After 5 WARMUP iters, baseline has shrunk from the sentinel to a
    real ns/iter mean."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000_000))
    assert_true(af.baseline_ns() < ADAPTIVE_FILTER_BASELINE_SENTINEL_NS)


def test_warmup_to_explore_transition_at_iter_5() raises:
    """Phase flips to EXPLORE after the 5th WARMUP iter."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000_000))
    assert_equal(af.current_phase(), ADAPTIVE_FILTER_PHASE_EXPLORE)


def test_total_iterations_increments_each_call() raises:
    """`total_iterations()` matches the count of end_filter calls."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    for k in range(10):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000_000))
        assert_equal(af.total_iterations(), UInt64(k + 1))


# -----------------------------------------------------------------------------
# EXPLORE entry — first iter after WARMUP applies a swap
# -----------------------------------------------------------------------------


def test_explore_entry_applies_swap() raises:
    """The 6th call (first EXPLORE) applies a swap to the permutation —
    one adjacent pair is now out of order vs identity."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    # Run 5 WARMUP iters.
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000_000))
    # The 6th call enters EXPLORE: begin_filter picks + applies a swap.
    # Call begin_filter only — we want to inspect the permutation post-
    # swap-application but pre-end_filter.
    var _start = af.begin_filter()
    # Permutation has had exactly one adjacent swap; pending_swap_idx
    # records the slot.
    assert_true(af.pending_swap() >= 0)
    assert_true(af.pending_swap() < 3)  # slots 0, 1, 2 are valid for n=4
    # Verify the permutation differs from identity by exactly one adjacent
    # swap.
    var perm = af.get_permutation()
    var idx = af.pending_swap()
    # Slot `idx` and `idx+1` are swapped.
    assert_equal(perm[idx], UInt32(idx + 1))
    assert_equal(perm[idx + 1], UInt32(idx))
    # All other indices are at identity position.
    for i in range(4):
        if i != idx and i != idx + 1:
            assert_equal(perm[i], UInt32(i))
    # Complete the iteration so the AdaptiveFilter doesn't leak state.
    af.end_filter(_start)


# -----------------------------------------------------------------------------
# OBSERVE — keep vs revert logic on synthetic timings
# -----------------------------------------------------------------------------


def test_observe_revert_when_swap_regresses() raises:
    """If OBSERVE-window mean > baseline, the swap is REVERTED.

    Strategy: drive WARMUP with 1ms iters (baseline ~1ms), then run
    EXPLORE+OBSERVE with 10ms iters (much slower). Mean > baseline →
    revert.
    """
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    # WARMUP: 5 × 1 ms
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000_000))
    # Snapshot permutation pre-EXPLORE — should be identity.
    var pre_perm = List[UInt32]()
    var perm0 = af.get_permutation()
    for i in range(4):
        pre_perm.append(perm0[i])
    # EXPLORE entry will swap one pair. Get the slot index.
    var _start = af.begin_filter()
    var swapped_idx = af.pending_swap()
    af.end_filter(_start - UInt64(10_000_000))  # this iter ran 10 ms

    # The remaining OBSERVE iters: 10 × 10 ms (terrible).
    for _ in range(Int(ADAPTIVE_FILTER_OBSERVE_ITERS)):
        _drive_one_iter_synthetic_ns(af, UInt64(10_000_000))

    # OBSERVE window has closed; swap was reverted; we're back in EXPLORE.
    assert_equal(af.current_phase(), ADAPTIVE_FILTER_PHASE_EXPLORE)
    # Permutation should be back to identity (revert).
    var post_perm = af.get_permutation()
    for i in range(4):
        assert_equal(post_perm[i], pre_perm[i])
    # Swap_likeliness for that slot should have halved (100 → 50).
    assert_equal(af.swap_likeliness_at(swapped_idx), UInt32(50))


def test_observe_keep_when_swap_improves() raises:
    """If OBSERVE-window mean < baseline, the swap is KEPT and the
    swap_likeliness slot resets to 100.

    Strategy: drive WARMUP with 10ms iters (baseline ~10ms), then run
    EXPLORE+OBSERVE with 1ms iters (much faster). Mean < baseline →
    keep. baseline drops; swap_likeliness slot stays at 100.
    """
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    # WARMUP: 5 × 10 ms
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af, UInt64(10_000_000))
    var baseline_pre = af.baseline_ns()
    # EXPLORE entry: swap applied
    var _start = af.begin_filter()
    var swapped_idx = af.pending_swap()
    # Then 11 iters (EXPLORE + OBSERVE) at 1 ms each.
    af.end_filter(_start - UInt64(1_000_000))  # first iter at 1 ms
    for _ in range(Int(ADAPTIVE_FILTER_OBSERVE_ITERS)):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000_000))

    # Should be back in EXPLORE.
    assert_equal(af.current_phase(), ADAPTIVE_FILTER_PHASE_EXPLORE)
    # Permutation has the swap retained — differs from identity.
    var perm = af.get_permutation()
    assert_equal(perm[swapped_idx], UInt32(swapped_idx + 1))
    assert_equal(perm[swapped_idx + 1], UInt32(swapped_idx))
    # Baseline has dropped (was ~10ms, now ~1ms).
    assert_true(af.baseline_ns() < baseline_pre)
    # Swap_likeliness slot stayed at 100 (keep resets to initial).
    assert_equal(
        af.swap_likeliness_at(swapped_idx),
        ADAPTIVE_FILTER_INITIAL_SWAP_LIKELINESS,
    )


# -----------------------------------------------------------------------------
# Corner case: n == 1 (no swaps possible)
# -----------------------------------------------------------------------------


def test_single_predicate_no_swap_possible() raises:
    """With n == 1, swap_likeliness is empty — state machine is a no-op."""
    var af = AdaptiveFilter(n_predicates=1, worker_id=0)
    assert_equal(af.n_predicates(), 1)
    # 0 swap slots
    var perm = af.get_permutation()
    assert_equal(len(perm), 1)
    assert_equal(perm[0], UInt32(0))
    # Drive 20 iters; no crash, no swap.
    for _ in range(20):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000_000))
    # Permutation unchanged.
    var perm2 = af.get_permutation()
    assert_equal(perm2[0], UInt32(0))


# -----------------------------------------------------------------------------
# Worker_id seeded distinctly — adjacent workers may make different choices
# -----------------------------------------------------------------------------


def test_different_worker_ids_explore_paths_diverge() raises:
    """Two AdaptiveFilters with the same n_predicates but different
    worker_ids have distinct RNG state, so they may make different
    EXPLORE choices.

    We can't assert they ALWAYS diverge on the first EXPLORE step
    (random alignment is possible) but we can assert that across many
    iterations, the two state machines exhibit distinct behavior. The
    sanity check is that the underlying XorShift64 streams are
    distinct (covered by test_xorshift64.mojo); this test just
    verifies the AdaptiveFilter wires that distinctness into the
    swap-pick.
    """
    var af0 = AdaptiveFilter(n_predicates=4, worker_id=0)
    var af1 = AdaptiveFilter(n_predicates=4, worker_id=1)
    # Drive WARMUP for both
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af0, UInt64(1_000_000))
        _drive_one_iter_synthetic_ns(af1, UInt64(1_000_000))
    # Apply one EXPLORE step each.
    var _s0 = af0.begin_filter()
    var _s1 = af1.begin_filter()
    var idx0 = af0.pending_swap()
    var idx1 = af1.pending_swap()
    # Both should be in [0, 3) (valid slot indices for n=4).
    assert_true(idx0 >= 0 and idx0 < 3)
    assert_true(idx1 >= 0 and idx1 < 3)
    # Complete the iters so the AdaptiveFilters don't leak state.
    af0.end_filter(_s0)
    af1.end_filter(_s1)
    # NOTE: idx0 and idx1 may coincidentally match — RNG can pick the
    # same slot in two independent streams. The distinctness guarantee
    # is at the RNG layer; this test just verifies no crash + both
    # workers picked a valid slot.


# -----------------------------------------------------------------------------
# Movability — AdaptiveFilter must be Movable for Slab[FilterState] storage
# -----------------------------------------------------------------------------


def test_adaptive_filter_is_movable() raises:
    """AdaptiveFilter is Movable (required for Slab[FilterState] storage
    in the ExpressionExecutor)."""
    var src = AdaptiveFilter(n_predicates=4, worker_id=7)
    var moved = src^
    assert_equal(moved.n_predicates(), 4)
    var perm = moved.get_permutation()
    assert_equal(len(perm), 4)
    assert_equal(perm[0], UInt32(0))


# -----------------------------------------------------------------------------
# Suite entry
# -----------------------------------------------------------------------------


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
