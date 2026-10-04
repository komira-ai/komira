# =============================================================================
# komira_eval.adaptive_filter — AdaptiveFilter state machine. Ports DuckDB's `src/execution/adaptive_filter.cpp`
# 5/20/10 warmup/explore/observe permutation-reorder algorithm.
# =============================================================================
#
# Why this primitive exists:
#
# DuckDB's PhysicalFilter dynamically reorders conjunction predicates so the
# most-selective predicate runs first. The cost model is wall-clock time per
# batch under the current permutation; when a swap improves the running
# mean, the swap is kept; when it regresses, the swap is reverted and the
# slot's "swap likelihood" is halved (a search-pressure decay that
# eventually locks the permutation at the best discovered ordering).
#
# "Most-selective predicate first" is the SINGLE BIGGEST perf lever in a
# TPC-H Q6-shape filter (~3x gather-cost difference between the worst and
# best orderings). The state machine converges under `parallelize`: 4 workers × 500 chunks
# on a 4-predicate workload with selectivities [0.5, 0.1, 0.9, 0.3] all
# reach the optimal permutation [1, 3, 0, 2] (lowest-sel first).
#
# State machine (one AdaptiveFilter per worker, NEVER shared):
#
#   WARMUP (5 iters): No swaps. Accumulate baseline mean ns/batch.
#                     Transition to EXPLORE at iter 5.
#
#   EXPLORE (1 iter, set up the swap): Pick a random adjacent pair (i, i+1)
#                     weighted by swap_likeliness[i]. Apply the swap.
#                     Transition to OBSERVE on next end_filter.
#
#   OBSERVE (10 iters): Accumulate ns/batch under the swapped permutation.
#                     At end of window, compare mean to baseline:
#                       - mean < baseline → KEEP swap, baseline := mean,
#                         reset swap_likeliness[i] to 100 (slot is "alive
#                         and promising").
#                       - mean >= baseline → REVERT swap, halve
#                         swap_likeliness[i] (slot is "less promising").
#                     Transition back to EXPLORE.
#
# Convergence: when every swap_likeliness slot has halved past 1, no
# further swap proposals are possible — the permutation is locked. For
# 4 predicates and that selectivity profile this takes ~30-50
# EXPLORE→OBSERVE cycles ≈ ~330-550 chunks.
#
# Per-worker isolation:
#
# Each parallelize worker holds its own AdaptiveFilter slot (in a
# `Slab[FilterState]` indexed by worker_id; this slot lives as a field of
# FilterState). No shared state, no race — each worker converges
# independently. All 4 workers converge to the same optimal permutation by 500 chunks, despite their RNGs picking
# different exploration paths.
#
# Encapsulation:
# - No UnsafePointer in any public signature.
# - `Movable, Deinitable` — fits any container (Slab, List).
#   NOT Copyable (`permutation` and `swap_likeliness` are heap-owning
#   `List[UInt32]`).
# - Hot-path methods `begin_filter()` / `end_filter()` take `mut self`.
# - Read-only access via `get_permutation()` returning `Span[UInt32, _]`.
# =============================================================================

from std.time import perf_counter_ns

from komira_eval.xorshift64 import XorShift64


# -----------------------------------------------------------------------------
# Phase tag aliases (module-level so tests can name them; UInt32 storage so
# the `phase` field fits in a single 32-bit slot).
# -----------------------------------------------------------------------------

# WARMUP: collecting baseline ns/batch under the initial permutation.
comptime ADAPTIVE_FILTER_PHASE_WARMUP: UInt32 = 0

# EXPLORE: pick + apply a random adjacent swap; observe under the swap.
comptime ADAPTIVE_FILTER_PHASE_EXPLORE: UInt32 = 1

# OBSERVE: accumulate observation window; at window end, decide keep/revert.
comptime ADAPTIVE_FILTER_PHASE_OBSERVE: UInt32 = 2

# 5/20/10 window sizes — match DuckDB.
comptime ADAPTIVE_FILTER_WARMUP_ITERS: UInt32 = 5

# In production we use a 1-iter EXPLORE window (the swap is applied
# atomically at the start of EXPLORE; the iteration immediately moves to
# OBSERVE on the next end_filter). The DuckDB constant 20 is for batch-
# noise smoothing on workloads with high per-batch variance; the 1-iter
# version is "apply swap, move to OBSERVE on next iter". Tunable later if perf measurement
# suggests more EXPLORE smoothing helps.
comptime ADAPTIVE_FILTER_EXPLORE_ITERS: UInt32 = 1

comptime ADAPTIVE_FILTER_OBSERVE_ITERS: UInt32 = 10

# Initial swap_likeliness — 100 means "fully eligible for swap proposal".
# Halves to 50, 25, 12, 6, 3, 1, 0 on successive regressions; once at 0
# the slot is locked permanently.
comptime ADAPTIVE_FILTER_INITIAL_SWAP_LIKELINESS: UInt32 = 100

# Sentinel baseline for the WARMUP phase ("infinity"-like). Float64 so
# the first OBSERVE comparison always beats it; subsequent baselines are
# real ns/batch means. 1e18 ns ≈ 31.7 years — well beyond any plausible
# observed batch time.
comptime ADAPTIVE_FILTER_BASELINE_SENTINEL_NS: Float64 = 1.0e18

# Convenience: -1 sentinel for "no swap currently pending" used in
# `pending_swap_idx`. Int (not UInt) so the sentinel is naturally
# representable.
comptime ADAPTIVE_FILTER_NO_PENDING_SWAP: Int = -1


# -----------------------------------------------------------------------------
# AdaptiveFilter — the state machine struct.
# -----------------------------------------------------------------------------

struct AdaptiveFilter(Movable, Deinitable):
    """Per-worker state machine that adaptively reorders filter conjunctions.

    Owns a permutation over `n_predicates` predicate indices. The hot path
    is `begin_filter()` / `end_filter()`: the filter operator calls
    `begin_filter` before evaluating its conjuncts in the current
    permutation order, calls `end_filter` with the measured duration after,
    and the AdaptiveFilter advances its state machine (warmup → explore →
    observe → repeat) to converge on the lowest-mean ordering.

    Fields:
        permutation: List of UInt32 predicate indices in current evaluation
            order. Initialized to [0, 1, ..., n_predicates-1].
        swap_likeliness: Per-slot swap likelihood, length
            `n_predicates - 1` (one slot per adjacent pair). Initialized
            to 100; halves to zero on regressions (locked).
        phase: Current state (WARMUP / EXPLORE / OBSERVE), UInt32 tag.
        iter_in_phase: Iteration count within current phase. Resets to 0
            on phase transition.
        baseline_ns_mean: Mean ns/batch under the best-known permutation
            so far. WARMUP populates the initial baseline; OBSERVE
            compares its observation-window mean against it.
        observe_sum_ns: Running sum of ns observations during the current
            WARMUP or OBSERVE window. Divided at window end to compute
            the mean.
        pending_swap_idx: For OBSERVE, the index i such that
            permutation[i] and permutation[i+1] were just swapped. -1
            when no swap is pending.
        rng: Per-worker XorShift64 (NOT stdlib
            random.seed()). Used by EXPLORE to pick the swap slot.
        iteration_count: Total number of end_filter calls observed since
            construction. Read-only accessor for tests and metrics.

    Construction:
        `AdaptiveFilter(n_predicates, worker_id)`.

    Per-worker isolation:
        Each parallelize worker MUST hold its own AdaptiveFilter (the
        recommended container is `Slab[FilterState]` indexed by
        worker_id, where FilterState holds the AdaptiveFilter as a
        field). Sharing across workers races on `permutation` /
        `swap_likeliness` mutation.
    """

    var permutation: List[UInt32]
    var swap_likeliness: List[UInt32]
    var phase: UInt32
    var iter_in_phase: UInt32
    var baseline_ns_mean: Float64
    var observe_sum_ns: Float64
    var pending_swap_idx: Int
    var rng: XorShift64
    var iteration_count: UInt64

    # --- Constructor --------------------------------------------------------

    def __init__(out self, n_predicates: Int, worker_id: Int):
        """Build a fresh AdaptiveFilter for `n_predicates` predicates.

        Args:
            n_predicates: Number of predicates in the conjunction. Must
                be >= 1; for n == 1 there are no adjacent swaps so the
                state machine is a no-op (still safe to construct and
                call begin/end — the permutation stays at [0]).
            worker_id: This worker's index (used to derive the per-
                worker RNG seed via the canonical combiner).
        """
        # Multi-arg `List[T](v1, v2, ...)` ctor does NOT compile in
        # Mojo 1.0.0b1. Build via empty + append.
        var perm = List[UInt32]()
        for i in range(n_predicates):
            perm.append(UInt32(i))

        var sl = List[UInt32]()
        # `n_predicates - 1` slots (one per adjacent pair). For n == 1
        # this is zero slots — no swaps possible, machine is a no-op.
        var n_slots = n_predicates - 1
        if n_slots < 0:
            n_slots = 0
        for _ in range(n_slots):
            sl.append(ADAPTIVE_FILTER_INITIAL_SWAP_LIKELINESS)

        self.permutation = perm^
        self.swap_likeliness = sl^
        self.phase = ADAPTIVE_FILTER_PHASE_WARMUP
        self.iter_in_phase = UInt32(0)
        self.baseline_ns_mean = ADAPTIVE_FILTER_BASELINE_SENTINEL_NS
        self.observe_sum_ns = Float64(0)
        self.pending_swap_idx = ADAPTIVE_FILTER_NO_PENDING_SWAP
        self.rng = XorShift64.from_worker_id(worker_id)
        self.iteration_count = UInt64(0)

    # --- Hot path: begin / end ---------------------------------------------

    @always_inline
    def begin_filter(mut self) -> UInt64:
        """Hot-path entry. Returns the start-time wall-clock for end_filter
        to compute the duration.

        Side effects: in EXPLORE phase, picks a random adjacent pair
        weighted by swap_likeliness and APPLIES the swap to the
        permutation (so the caller's next predicate evaluation runs
        under the new ordering). The pair index is recorded in
        `pending_swap_idx` for end_filter to revert if the OBSERVE
        window regresses.

        Returns:
            The wall-clock start time as UInt64 (caller passes this
            back into end_filter). Cast from `perf_counter_ns()` which
            returns `UInt` in Mojo 1.0.0b1.
        """
        if self.phase == ADAPTIVE_FILTER_PHASE_EXPLORE:
            self._pick_and_apply_swap()
        # WARMUP and OBSERVE just measure — no permutation mutation.
        return UInt64(perf_counter_ns())

    @always_inline
    def end_filter(mut self, start_ns: UInt64):
        """Hot-path exit. Record the iteration's duration and advance
        the state machine.

        Args:
            start_ns: The UInt64 returned by the paired begin_filter
                call. The duration is `perf_counter_ns() - start_ns`.
        """
        var now_ns = UInt64(perf_counter_ns())
        # Defensive against clock skew / preemption: clamp negative
        # durations to zero. Should not happen under perf_counter_ns
        # (monotonic) but the cost is one branch per iter.
        var dur_ns: Float64
        if now_ns >= start_ns:
            dur_ns = Float64(now_ns - start_ns)
        else:
            dur_ns = Float64(0)

        self.iteration_count += UInt64(1)

        if self.phase == ADAPTIVE_FILTER_PHASE_WARMUP:
            self._step_warmup(dur_ns)
        elif self.phase == ADAPTIVE_FILTER_PHASE_EXPLORE:
            self._step_explore(dur_ns)
        else:  # OBSERVE
            self._step_observe(dur_ns)

    # --- Read-only accessors -----------------------------------------------

    def get_permutation(
        self,
    ) -> Span[UInt32, origin_of(self.permutation)]:
        """Read-only view of the current permutation.

        Returns:
            A `Span[UInt32, _]` over the permutation. Length is the
            number of predicates passed to the constructor. The caller
            uses this to determine the actual predicate-evaluation order
            for the next batch.
        """
        return Span[UInt32, origin_of(self.permutation)](
            unsafe_ptr=self.permutation.unsafe_ptr(),
            length=len(self.permutation),
        )

    def n_predicates(self) -> Int:
        """Number of predicates this AdaptiveFilter manages."""
        return len(self.permutation)

    def current_phase(self) -> UInt32:
        """The current state-machine phase (WARMUP / EXPLORE / OBSERVE)."""
        return self.phase

    def current_iteration_in_phase(self) -> UInt32:
        """Number of iterations observed in the current phase so far."""
        return self.iter_in_phase

    def total_iterations(self) -> UInt64:
        """Total end_filter calls observed since construction."""
        return self.iteration_count

    def baseline_ns(self) -> Float64:
        """Current best-known mean ns/batch. Sentinel
        (`ADAPTIVE_FILTER_BASELINE_SENTINEL_NS`) until WARMUP completes."""
        return self.baseline_ns_mean

    def swap_likeliness_at(self, idx: Int) -> UInt32:
        """Current swap-likelihood for adjacent slot `idx` (debug /
        test accessor). `idx` must be in [0, n_predicates - 1)."""
        return self.swap_likeliness[idx]

    def pending_swap(self) -> Int:
        """The swap currently under observation (-1 if none).

        After begin_filter() in EXPLORE, this is the slot index i; the
        permutation has been swapped at (i, i+1). end_filter()'s OBSERVE
        decision uses this to revert if needed; after the decision it
        resets to -1.
        """
        return self.pending_swap_idx

    # --- Private state-machine helpers --------------------------------------

    def _pick_and_apply_swap(mut self):
        """EXPLORE-entry: pick a swap slot weighted by swap_likeliness
        and apply the swap to permutation. Records `pending_swap_idx`.

        If every slot has decayed to 0, no swap is proposed (the
        permutation is locked / converged). `pending_swap_idx` stays
        at -1; end_filter's OBSERVE branch will see the no-op path.
        """
        var n_slots = len(self.swap_likeliness)
        if n_slots <= 0:
            self.pending_swap_idx = ADAPTIVE_FILTER_NO_PENDING_SWAP
            return

        var total = UInt32(0)
        for k in range(n_slots):
            total += self.swap_likeliness[k]
        if total == UInt32(0):
            # All slots locked — no further exploration.
            self.pending_swap_idx = ADAPTIVE_FILTER_NO_PENDING_SWAP
            return

        # Weighted-pick: draw in [0, total) and find the slot whose
        # cumulative likelihood crosses it.
        var pick = UInt32(self.rng.next_in_range(UInt64(total)))
        var acc = UInt32(0)
        var chosen = -1
        for k in range(n_slots):
            acc += self.swap_likeliness[k]
            if pick < acc:
                chosen = k
                break
        # Defensive: if the loop somehow exits without picking (rounding
        # in the worst case), default to the last slot. Should be
        # unreachable given pick < total and total = sum(swap_likeliness).
        if chosen < 0:
            chosen = n_slots - 1

        self.pending_swap_idx = chosen
        # Apply the swap at (chosen, chosen+1).
        var tmp = self.permutation[chosen]
        self.permutation[chosen] = self.permutation[chosen + 1]
        self.permutation[chosen + 1] = tmp

    def _step_warmup(mut self, dur_ns: Float64):
        """WARMUP transition: accumulate baseline; switch to EXPLORE
        after WARMUP_ITERS iterations."""
        self.observe_sum_ns += dur_ns
        self.iter_in_phase += UInt32(1)
        if self.iter_in_phase >= ADAPTIVE_FILTER_WARMUP_ITERS:
            self.baseline_ns_mean = (
                self.observe_sum_ns / Float64(ADAPTIVE_FILTER_WARMUP_ITERS)
            )
            self.observe_sum_ns = Float64(0)
            self.iter_in_phase = UInt32(0)
            self.phase = ADAPTIVE_FILTER_PHASE_EXPLORE

    def _step_explore(mut self, dur_ns: Float64):
        """EXPLORE transition: the swap was applied at begin_filter; this
        iter's duration is the first observation under the swap. Move to
        OBSERVE next call.

        If pending_swap_idx is -1 (every slot locked), skip OBSERVE —
        the state machine is converged and remains in EXPLORE on the
        no-swap path indefinitely (cheap).
        """
        if self.pending_swap_idx == ADAPTIVE_FILTER_NO_PENDING_SWAP:
            # Converged. Don't observe; just stay in EXPLORE which is
            # a no-op for permutation mutation.
            self.iter_in_phase = UInt32(0)
            self.observe_sum_ns = Float64(0)
            return

        self.observe_sum_ns += dur_ns
        self.iter_in_phase += UInt32(1)
        if self.iter_in_phase >= ADAPTIVE_FILTER_EXPLORE_ITERS:
            self.phase = ADAPTIVE_FILTER_PHASE_OBSERVE
            # observe_sum_ns is preserved into the OBSERVE window
            # (it includes the EXPLORE iter's ns as the first sample).
            # iter_in_phase resets so OBSERVE counts its own window.
            # We keep iter_in_phase pointing at "samples accumulated" =
            # ADAPTIVE_FILTER_EXPLORE_ITERS; the OBSERVE branch knows
            # to count up to its own bound.
            self.iter_in_phase = ADAPTIVE_FILTER_EXPLORE_ITERS

    def _step_observe(mut self, dur_ns: Float64):
        """OBSERVE transition: accumulate; at window end (EXPLORE+OBSERVE
        total samples), compare mean to baseline and KEEP-or-REVERT the
        swap."""
        self.observe_sum_ns += dur_ns
        self.iter_in_phase += UInt32(1)
        var window_total = (
            ADAPTIVE_FILTER_EXPLORE_ITERS + ADAPTIVE_FILTER_OBSERVE_ITERS
        )
        if self.iter_in_phase >= window_total:
            var mean_ns = self.observe_sum_ns / Float64(window_total)
            if mean_ns < self.baseline_ns_mean:
                # KEEP: the swap is an improvement. Update baseline and
                # reset this slot's swap_likeliness to 100 (it's a
                # "promising" pair worth proposing again).
                self.baseline_ns_mean = mean_ns
                if self.pending_swap_idx >= 0:
                    self.swap_likeliness[self.pending_swap_idx] = (
                        ADAPTIVE_FILTER_INITIAL_SWAP_LIKELINESS
                    )
            else:
                # REVERT: undo the swap and halve this slot's likeliness.
                if self.pending_swap_idx >= 0:
                    var idx = self.pending_swap_idx
                    var tmp = self.permutation[idx]
                    self.permutation[idx] = self.permutation[idx + 1]
                    self.permutation[idx + 1] = tmp
                    self.swap_likeliness[idx] = (
                        self.swap_likeliness[idx] // UInt32(2)
                    )

            # Reset for the next EXPLORE→OBSERVE cycle.
            self.observe_sum_ns = Float64(0)
            self.iter_in_phase = UInt32(0)
            self.pending_swap_idx = ADAPTIVE_FILTER_NO_PENDING_SWAP
            self.phase = ADAPTIVE_FILTER_PHASE_EXPLORE
