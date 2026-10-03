# =============================================================================
# SelectivityTracker -- adaptive pause/resume for dynamic-filter pushdown
# =============================================================================
#
# After processing `check_window` batches (default 6), if the cumulative
# pass rate is at or above `threshold`, the filter is paused for
# `pause_multiplier * BACKOFF_BASE` batches. Each successive pause doubles
# the backoff (saturated at 64x). On re-check, if selectivity improved,
# the filter resumes; otherwise it pauses again with increased backoff.
#
# Fast path: if the very first batch shows 100% pass rate (zero pruning),
# pause immediately with extended backoff. Critical for multi-join queries
# where most BFs are unselective.
#
# Pointer rules:
#   - No UnsafePointer; pure inline state.
#   - Public API exposes typed values only (Bool / Int / Float64).
#   - SelectivityTracker is Movable; works inside a Slab[...] without
#     a stale-pointer hazard (no heap-owning inner fields).
# =============================================================================

# Base number of batches per pause level.
comptime BACKOFF_BASE: Int = 10

# pause_multiplier saturation.
comptime PAUSE_MULTIPLIER_MAX: Int = 64

# Default SelectivityTracker.check_window.
comptime CHECK_WINDOW_DEFAULT: Int = 6


# =============================================================================
# Selectivity threshold constants
# =============================================================================
# Default per-tier thresholds:
#   - BloomFilter:  pause if pass_rate >= 0.50  (paused below selectivity 50%)
#   - InListFilter: pause if pass_rate >= 0.90  (only if very unselective)
#   - RangeFilter:  pause if pass_rate >= 0.90  (only if very unselective)
# =============================================================================
comptime BLOOM_SELECTIVITY_THRESHOLD: Float64 = 0.50
comptime IN_LIST_SELECTIVITY_THRESHOLD: Float64 = 0.90
comptime RANGE_SELECTIVITY_THRESHOLD: Float64 = 0.90


# =============================================================================
# SelectivityTracker -- per-tier adaptive pause/resume
# =============================================================================


struct SelectivityTracker(Copyable, Movable):
    """Tracks per-tier selectivity and pauses when not cost-effective.

    Fields:
        threshold: Selectivity threshold (pass_rate >= threshold -> pause).
        check_window: Number of batches per observation window.
        pause_multiplier: Current backoff multiplier (doubles each pause,
            saturated at 64).
        batches_in_window: Batches processed in the current window.
        window_passed: Total rows passed in the current window.
        window_input: Total rows input in the current window.
        pause_remaining: Batches remaining in the current pause period.
        paused: Whether currently paused.
    """

    var threshold: Float64
    var check_window: Int
    var pause_multiplier: Int
    var batches_in_window: Int
    var window_passed: Int
    var window_input: Int
    var pause_remaining: Int
    var paused: Bool

    def __init__(out self, threshold: Float64):
        """Create a new tracker with the given selectivity threshold.

        Args:
            threshold: Pause if pass_rate >= this. Use
                BLOOM_SELECTIVITY_THRESHOLD (0.50) for bloom,
                IN_LIST_SELECTIVITY_THRESHOLD (0.90) for in-list,
                RANGE_SELECTIVITY_THRESHOLD (0.90) for range.
        """
        self.threshold = threshold
        self.check_window = CHECK_WINDOW_DEFAULT
        self.pause_multiplier = 1
        self.batches_in_window = 0
        self.window_passed = 0
        self.window_input = 0
        self.pause_remaining = 0
        self.paused = False

    @always_inline
    def should_apply(mut self) -> Bool:
        """Should this filter be applied to the current batch?

        If paused, decrements the pause counter and returns False. When the
        pause expires, returns True and begins a new observation window.

        Returns:
            True if the caller should run the filter; False to skip this batch.
        """
        if self.paused:
            if self.pause_remaining > 0:
                self.pause_remaining -= 1
                return False
            # Pause expired: resume for a new observation window.
            self.paused = False
            self.batches_in_window = 0
            self.window_passed = 0
            self.window_input = 0
        return True

    @always_inline
    def record(mut self, input_rows: Int, output_rows: Int) -> None:
        """Record the result of applying the filter to one batch.

        Args:
            input_rows: Batch size before filtering.
            output_rows: Number of rows that passed the filter.

        Fast path: if the first batch in a window shows 0% pruning
        (output == input), skip the rest of the window and pause
        immediately with extended backoff.

        After `check_window` batches, evaluates cumulative selectivity
        and may pause the filter.
        """
        self.window_input += input_rows
        self.window_passed += output_rows
        self.batches_in_window += 1

        # Fast path: first-batch 100% pass -> immediate pause.
        if (
            self.batches_in_window == 1
            and output_rows == input_rows
            and input_rows > 0
        ):
            self.paused = True
            self.pause_remaining = self.pause_multiplier * BACKOFF_BASE
            self.pause_multiplier = min(self.pause_multiplier * 2, PAUSE_MULTIPLIER_MAX)
            self.batches_in_window = 0
            self.window_passed = 0
            self.window_input = 0
            return

        # Window evaluation.
        if self.batches_in_window >= self.check_window:
            var pass_rate: Float64
            if self.window_input > 0:
                pass_rate = Float64(self.window_passed) / Float64(self.window_input)
            else:
                pass_rate = 1.0

            if pass_rate >= self.threshold:
                # Filter is not selective enough -- pause.
                self.paused = True
                self.pause_remaining = self.pause_multiplier * BACKOFF_BASE
                self.pause_multiplier = min(
                    self.pause_multiplier * 2, PAUSE_MULTIPLIER_MAX
                )
            else:
                # Filter is effective -- reset backoff.
                self.pause_multiplier = 1

            # Reset window counters for next observation.
            self.batches_in_window = 0
            self.window_passed = 0
            self.window_input = 0

    @always_inline
    def is_paused(self) -> Bool:
        """Report whether tracking is paused."""
        return self.paused
