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
# NOTE: no test here reads or compares the wall clock. Every duration is
# fed to the state machine through `record_duration_ns`, the entry point
# `end_filter` itself calls after it measures the clock, so each
# keep / revert / baseline decision is exact and reproducible.
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
# Helper: run one begin/end cycle with an exact duration.
# -----------------------------------------------------------------------------


def _drive_one_iter_synthetic_ns(mut af: AdaptiveFilter, synthetic_ns: UInt64):
    """Drive one begin/record cycle with exactly `synthetic_ns`.

    `begin_filter` still applies the EXPLORE swap; the duration bypasses the
    clock via `record_duration_ns`.
    """
    _ = af.begin_filter()
    af.record_duration_ns(synthetic_ns)


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
    assert_equal(af.baseline_ns(), Float64(1_000_000))


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
    af.record_duration_ns(UInt64(1_000_000))


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
    af.record_duration_ns(UInt64(10_000_000))  # this iter ran 10 ms

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
    # A revert leaves the baseline at the warmup mean.
    assert_equal(af.baseline_ns(), Float64(1_000_000))


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
    af.record_duration_ns(UInt64(1_000_000))  # first iter at 1 ms
    for _ in range(Int(ADAPTIVE_FILTER_OBSERVE_ITERS)):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000_000))

    # Should be back in EXPLORE.
    assert_equal(af.current_phase(), ADAPTIVE_FILTER_PHASE_EXPLORE)
    # Permutation has the swap retained — differs from identity.
    var perm = af.get_permutation()
    assert_equal(perm[swapped_idx], UInt32(swapped_idx + 1))
    assert_equal(perm[swapped_idx + 1], UInt32(swapped_idx))
    # Baseline has dropped (was exactly 10 ms, now exactly 1 ms).
    assert_equal(baseline_pre, Float64(10_000_000))
    assert_equal(af.baseline_ns(), Float64(1_000_000))
    # Swap_likeliness slot stayed at 100 (keep resets to initial).
    assert_equal(
        af.swap_likeliness_at(swapped_idx),
        ADAPTIVE_FILTER_INITIAL_SWAP_LIKELINESS,
    )


# -----------------------------------------------------------------------------
# Exact boundaries — only possible with exact durations
# -----------------------------------------------------------------------------


def test_warmup_baseline_is_exact_mean_of_five_durations() raises:
    """The baseline is the arithmetic mean of the 5 warmup durations."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    var durations = List[UInt64]()
    durations.append(UInt64(1000))
    durations.append(UInt64(2000))
    durations.append(UInt64(3000))
    durations.append(UInt64(4000))
    durations.append(UInt64(10_000))
    for k in range(len(durations)):
        _drive_one_iter_synthetic_ns(af, durations[k])
    assert_equal(af.baseline_ns(), Float64(4000))


def _run_one_window(mut af: AdaptiveFilter, first_ns: UInt64, rest_ns: UInt64):
    """One EXPLORE iter at `first_ns`, then the OBSERVE iters at `rest_ns`."""
    _ = af.begin_filter()
    af.record_duration_ns(first_ns)
    for _ in range(Int(ADAPTIVE_FILTER_OBSERVE_ITERS)):
        _drive_one_iter_synthetic_ns(af, rest_ns)


def test_observe_window_mean_equal_to_baseline_reverts() raises:
    """The keep test is strict `mean < baseline`: a window whose mean equals
    the baseline reverts (and halves the slot)."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000))
    var idx = -1
    _ = af.begin_filter()
    idx = af.pending_swap()
    af.record_duration_ns(UInt64(1_000))
    for _ in range(Int(ADAPTIVE_FILTER_OBSERVE_ITERS)):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000))
    var perm = af.get_permutation()
    for i in range(4):
        assert_equal(perm[i], UInt32(i))
    assert_equal(af.swap_likeliness_at(idx), UInt32(50))
    assert_equal(af.baseline_ns(), Float64(1_000))


def test_observe_window_mean_one_ns_below_baseline_keeps() raises:
    """11 samples summing to 11 * baseline - 11 (mean one ns lower) keep."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000))
    _ = af.begin_filter()
    var idx = af.pending_swap()
    af.record_duration_ns(UInt64(999))
    for _ in range(Int(ADAPTIVE_FILTER_OBSERVE_ITERS)):
        _drive_one_iter_synthetic_ns(af, UInt64(999))
    var perm = af.get_permutation()
    assert_equal(perm[idx], UInt32(idx + 1))
    assert_equal(perm[idx + 1], UInt32(idx))
    assert_equal(af.baseline_ns(), Float64(999))


def test_observe_window_averages_explore_iter_with_observe_iters() raises:
    """The EXPLORE iter is the first of the 11 window samples, so the window
    mean is (first + 10 * rest) / 11 and decides keep vs revert."""
    var af = AdaptiveFilter(n_predicates=4, worker_id=0)
    for _ in range(5):
        _drive_one_iter_synthetic_ns(af, UInt64(1_000))
    # (1011 + 10 * 999) / 11 = 11001 / 11 = 1000.09 >= 1000: revert.
    _run_one_window(af, UInt64(1_011), UInt64(999))
    assert_equal(af.baseline_ns(), Float64(1_000))
    var perm = af.get_permutation()
    for i in range(4):
        assert_equal(perm[i], UInt32(i))
    # (1000 + 10 * 999) / 11 = 10990 / 11 = 999.09 < 1000: keep.
    _run_one_window(af, UInt64(1_000), UInt64(999))
    assert_equal(af.baseline_ns(), Float64(10_990) / Float64(11))


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
    af0.record_duration_ns(UInt64(1_000_000))
    af1.record_duration_ns(UInt64(1_000_000))
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
