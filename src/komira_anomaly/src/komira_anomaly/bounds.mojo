# =============================================================================
# komira_anomaly.bounds — THE RUNNING BOUNDS: STATE THAT JUDGES THE NEXT POINT.
# =============================================================================
#
# ★ THE SHAPE THIS EXISTS TO SERVE: keep running bounds that detect an anomaly
# quickly, using the existing data and the new point. A point
# is posted; it is judged IMMEDIATELY against everything already accumulated;
# the accumulation is updated. Nothing re-reads a window, nothing goes back to
# the store, and the caller holds no history.
#
# Everything here is O(1) per point in TIME and O(1) in SPACE — with ONE bounded
# exception that is stated out loud below rather than hidden behind an
# approximation.
#
# ── ⭐ THE MEAN AND VARIANCE ARE WELFORD, NOT SUM/SUMSQ ─────────────────────
#
# The naive online variance keeps SUM(x) and SUM(x^2) and recovers the variance
# by subtracting two nearly equal large numbers. MEASURED on a recorded
# benchmark series (`duck_q04_base`, 100 real launches, true variance
# 0.006945167), in Float64, as a constant offset is added to every value:
#
#     offset      naive sum/sumsq        Welford         naive relative error
#     +0          0.006945167292         0.006945167292          6.4e-12
#     +1e6        0.006470959596         0.006945167292          6.8e-02
#     +1e9      **-496.4848485**         0.006945166414          7.1e+04
#     +2e12   **+1388272257.29**         0.006940996406          2.0e+11
#
# ⚠ THE +2e12 ROW IS ORDER-DEPENDENT. `math.fsum` returns **-694136128.6** on
# these inputs; a PLAIN LEFT-TO-RIGHT ACCUMULATION
# — which is the shape of the code this table is about — returns +1388272257.29
# on the identical inputs. The two differ by two ulps of `SUM(x^2)` (~4e22, ulp
# 8388608), so they are not two answers to the same question: the residual at
# this magnitude IS the rounding noise, and its SIGN is decided by summation
# order. ⛔ SO THE SIGN IS NOT A PROPERTY TO ASSERT ON — see the note in
# `tests/test_bounds.mojo`, which pins the MAGNITUDE of the error instead. The
# Welford column reproduces exactly on all four rows.
#
# ⚠ SO THE NAIVE FORM IS FINE ON RAW MILLISECOND WALLS AND CATASTROPHIC ON A
# LARGE BASELINE — and a large baseline is not exotic, it is what a cumulative
# counter, a byte offset, an epoch-based gauge or any value carrying a big
# constant looks like. At +1e9 the answer is NEGATIVE, and a negative variance
# is not a rounding error: `sqrt` returns `nan`, every subsequent comparison
# against the bound is FALSE, and the detector has silently stopped detecting
# with no state anywhere that says so. The seam here takes a bare `Float64` from
# a producer this package will never see, so the safe form is the only defensible
# one.
#
# Welford's recurrence never forms that difference:
#
#     n     += 1
#     delta  = x - mean
#     mean  += delta / n
#     m2    += delta * (x - mean)        <- the NEW mean, deliberately
#
# `m2` accumulates only same-signed contributions, so no cancellation occurs and
# the variance cannot come out negative. This is the standard result and it is
# the reason the fields are spelled this way; `test_bounds.mojo` pins it by
# running BOTH estimators over the +1e9 row above and asserting the naive one
# comes out negative while `RunningStats` does not — a comparison, not an
# assertion of taste.
#
# ── ⛔ WHAT CANNOT BE MAINTAINED ONLINE, SAID PLAINLY ───────────────────────
#
# AN EXACT QUANTILE — the median, and therefore the MAD — CANNOT be maintained
# in O(1) space over an unbounded stream. That is a theorem, not a gap in this
# implementation: any exact-median algorithm must be able to name a value it has
# seen, so it must retain O(n) of them.
#
# This module does NOT paper over that with a streaming approximation (P-square,
# t-digest, a reservoir). An approximate quantile whose error is not measured
# would put an unquantified error term underneath a THRESHOLD, and a detector
# calibrated on a false-alarm budget cannot absorb one.
#
# What is used instead, and why each is exact:
#
#   * the BOUNDS arm uses Welford mean/variance over the WHOLE history — O(1)
#     space, exact up to floating point, no quantile needed.
#   * the CHART arm needs a median and a MAD, so it takes them from a BOUNDED
#     PHASE-I PREFIX: the first `reference_len` points are buffered (20 Float64s
#     = 160 bytes per series, a fixed cost that does not grow), the median and
#     MAD are computed ONCE when that prefix completes, the buffer is released,
#     and the chart then runs incrementally forever after. The statistic is
#     EXACT for the window it claims to describe; what it is not is ADAPTIVE,
#     and that is the property `cusum.mojo`'s header now measures the cost of.
#
# ── ⚠ A POINT IS JUDGED AGAINST THE STATE THAT PRECEDES IT ─────────────────
#
# `observe` returns a `BoundSignal` computed from the accumulation BEFORE the
# point is folded in, then folds it in. Judging a point against statistics that
# already contain it is the classic self-referential test: one outlier drags the
# mean toward itself and inflates the scale, so the largest deviations are the
# ones most able to hide. The ordering here is not a detail.
#
# Encapsulation: value types only, ZERO UnsafePointer, no wildcard origins.
# =============================================================================

from std.math import isfinite, sqrt

from komira_anomaly.cusum import (
    CUSUM_DECLINED_NONE,
    CUSUM_DECLINED_REFERENCE_TOO_SHORT,
    CUSUM_DECLINED_ZERO_SCALE,
    CUSUM_MIN_REFERENCE,
    DEFAULT_SLACK_SIGMAS,
    DEFAULT_THRESHOLD_SIGMAS,
    estimate_scale,
    median_of,
)

# How many points must precede a point before the bounds arm will rule on it.
#
# ⚠ NOT A TASTE SETTING. With n prior points the sample standard deviation has
# roughly 1/sqrt(2(n-1)) relative error, so at n=10 the scale itself is +-24%
# and a "6 sigma" bound is somewhere between 4.5 and 8 real sigmas. At 20 it is
# +-16%. Twenty is the same Phase-I floor the chart uses, for the same reason,
# and the two are deliberately equal so a reader does not have to hold two
# numbers.
comptime BOUNDS_MIN_PRIOR: Int = 20

# The bound, in sample standard deviations of the accumulated history.
#
# ⭐ FIVE, AND THE NUMBER IS MEASURED, NOT CHOSEN FOR ROUNDNESS. On the six real
# order-preserving known-zero series of recorded benchmark launches — 320
# points of ONE binary relaunched, no code change anywhere in them, 200 of them
# armed — the LARGEST
# |z| this arm ever computes is **2.433** (`duck_q04_base` at i=28). So the
# false-alarm count is 0 of 6 at every k above about 2.5, and picking k is
# entirely a question of how much margin to leave over real measured noise:
#
#     k = 3   ->  0 of 6 series fire     margin over the worst real |z|: 1.23x
#     k = 4   ->  0 of 6 series fire     margin: 1.64x
#     k = 5   ->  0 of 6 series fire     margin: 2.05x   <- CHOSEN
#     k = 8   ->  0 of 6 series fire     margin: 3.29x, and measurably deafer
#
# and the price of the margin, against a SINGLE spiked point at i=25:
#
#            x1.25   x1.50   x2.00
#     k = 4   4/6     6/6     6/6
#     k = 5   3/6     5/6     6/6      <- CHOSEN
#     k = 8   2/6     4/6     6/6
#
# ⛔ AND THE LIMITATION THAT MATTERS MOST, MEASURED RATHER THAN GUESSED: THIS
# ARM IS NOT A SHIFT DETECTOR. A SUSTAINED step is caught on 4 of 6 series at
# +30% and on only 2 of 6 at +10% — because the arm folds every new point into
# the very scale it judges the next one against, so a shift that persists
# inflates the bound that would have caught it. That is inherent to a per-point
# bound over a running scale and no choice of k repairs it. Sustained shifts are
# the CHANGE-POINT arm's job (`edivisive.mojo`), which finds a 10% shift on 74
# of 82 corpus cells. A caller that reads a green bounds verdict as 'this series
# has not regressed' has read a point test as a trend test.
#
# ⭐ BOTH TABLES ARE RE-DERIVED BY
# `tests/test_real_launch_series.mojo::test_the_published_calibration_tables_
# are_re_derived_here`, from the recorded numbers, including the rows that are
# bad news — and the CHOSEN row is computed at `DEFAULT_BOUND_SIGMAS` rather
# than at a literal 5.0, which is what makes it a pin on the shipped value.
#
# ⚠ WHY BOTH TABLES, NOT ONE BOUND. A ONE-SIDED pin would let
# `DEFAULT_BOUND_SIGMAS` be raised 5 -> 6, 7 or 8 — a 60% loss of point
# sensitivity — with the whole suite green, if the only two constraints on it
# were a LOWER bound (`> worst*2.0`, satisfied from k=4.87) and a spike count
# that happens to hold for every k in [4, 9].
comptime DEFAULT_BOUND_SIGMAS: Float64 = 5.0


struct RunningStats(Copyable, Movable, Deinitable):
    """Welford's online mean and variance. O(1) time, O(1) space, exact.

    `count` is the number of points folded in; `mean` and `m2` are the
    recurrence's state. Nothing here retains a value it has seen.
    """

    var count: Int
    var mean: Float64
    var m2: Float64

    def __init__(out self):
        self.count = 0
        self.mean = Float64(0.0)
        self.m2 = Float64(0.0)

    def update(mut self, x: Float64):
        """Fold one point in. THE SECOND `delta` USES THE UPDATED MEAN — that is
        what makes the accumulation cancellation-free, and swapping it for the
        old mean silently turns this back into the naive estimator."""
        self.count += 1
        var delta = x - self.mean
        self.mean = self.mean + delta / Float64(self.count)
        self.m2 = self.m2 + delta * (x - self.mean)

    def variance(self) -> Float64:
        """The SAMPLE variance (n-1). 0.0 below two points.

        ⛔ CLAMPED AT ZERO, AND THE CLAMP IS A BACKSTOP, NOT A FIX. Welford's
        `m2` cannot go negative in exact arithmetic; if floating point ever put
        it a few ulps below zero, `sqrt` would return `nan` and every subsequent
        comparison against the bound would be FALSE — a detector that has
        silently stopped detecting. The clamp turns that into a zero scale,
        which `BoundSignal` reports as NOT ARMED rather than as no anomaly.
        """
        if self.count < 2:
            return Float64(0.0)
        if self.m2 <= 0.0:
            return Float64(0.0)
        return self.m2 / Float64(self.count - 1)

    def stddev(self) -> Float64:
        return sqrt(self.variance())


struct BoundSignal(Copyable, Movable, Deinitable):
    """One point's ruling from the running bounds — and whether there WAS one.

    ⛔ `armed` IS NOT `not breached`. A bound with too few prior points, or one
    whose prior history has no dispersion at all, has produced NO RULING; a
    caller that reads `breached == False` as 'the point is fine' has turned an
    instrument that did not run into a pass. Every consumer here branches on
    `armed` first.
    """

    var armed: Bool
    var breached: Bool
    var z: Float64
    var direction: Int
    var n_prior: Int
    var mean_prior: Float64
    var sigma_prior: Float64
    var limit_sigmas: Float64
    # ⭐ WHY THIS SIGNAL DID NOT RULE, RECORDED BY THE ARM THAT DECLINED.
    #
    # ⛔ IT IS NOT RE-DERIVABLE FROM `n_prior`. Reconstructing it by comparing
    # `n_prior` against the MODULE-DEFAULT `BOUNDS_MIN_PRIOR` is right only for
    # a caller who took the default: a monitor built with
    # `bound_min_prior = 1000` and 59 points behind it would be reported as
    # `zero_scale` — a false statement
    # about a series whose scale is perfectly good. The arm that declined is
    # the only party that knows which threshold it declined against, so it
    # says so here rather than leaving a consumer to guess.
    var declined: Int

    def __init__(out self):
        self.armed = False
        self.breached = False
        self.z = Float64(0.0)
        self.direction = 0
        self.n_prior = 0
        self.mean_prior = Float64(0.0)
        self.sigma_prior = Float64(0.0)
        self.limit_sigmas = Float64(0.0)
        # A default-constructed signal has ruled on nothing and has no priors,
        # which is exactly TOO_FEW_PRIOR. This is the value the BATCH path
        # carries, where there is no 'newest point' for an arm to rule on.
        self.declined = BOUNDS_DECLINED_TOO_FEW_PRIOR

    def lower(self) -> Float64:
        """The bound itself, in the series' own units. Meaningless unarmed."""
        return self.mean_prior - self.limit_sigmas * self.sigma_prior

    def upper(self) -> Float64:
        return self.mean_prior + self.limit_sigmas * self.sigma_prior


# Why the bounds arm did not rule. Mirrors `cusum.mojo`'s decline vocabulary,
# for the same reason: a silent arm and an arm that ruled 'fine' must never be
# the same bytes in the record.
comptime BOUNDS_DECLINED_NONE: Int = 0
comptime BOUNDS_DECLINED_TOO_FEW_PRIOR: Int = 1
comptime BOUNDS_DECLINED_ZERO_SCALE: Int = 2


def bounds_decline_name(reason: Int) -> StaticString:
    """⚠ `StaticString`, NOT `String` — `scripts/lint_literal_return_ladder.py`.
    A 3+-arm ladder RETURNING a `String` lowers into two independently-relocated
    (pointer, length) constant arrays that the linker can cross-bind."""
    if reason == BOUNDS_DECLINED_NONE:
        return "ran"
    if reason == BOUNDS_DECLINED_TOO_FEW_PRIOR:
        # ⚠ NOT `fewer_than_20_prior_points`. `min_prior` is configurable, so a
        # word naming the default
        # threshold is a false sentence for every caller who set another one.
        return "too_few_prior_points"
    if reason == BOUNDS_DECLINED_ZERO_SCALE:
        return "zero_scale"
    return "unknown"


struct RunningBounds(Copyable, Movable, Deinitable):
    """The whole per-series accumulation: bounds arm + incremental chart.

    ONE `observe` per posted point. Everything it touches is O(1) except the
    bounded Phase-I prefix, which stops growing at `reference_len` and is
    released the moment it has been used.
    """

    var stats: RunningStats
    var limit_sigmas: Float64
    var min_prior: Int
    var declined: Int

    # The chart's Phase-I prefix. RELEASED at freeze — see `_freeze_reference`.
    var reference: List[Float64]
    var reference_len: Int
    var frozen: Bool
    var mu: Float64
    var sigma: Float64
    var slack_sigmas: Float64
    var threshold_sigmas: Float64
    var chart_declined: Int

    # The chart's incremental state.
    var c_hi: Float64
    var c_lo: Float64
    var peak_hi: Float64
    var peak_lo: Float64
    var chart_points: Int
    var chart_signalled: Bool
    var chart_signal_index: Int
    var chart_direction: Int

    var observed: Int

    def __init__(
        out self,
        limit_sigmas: Float64 = DEFAULT_BOUND_SIGMAS,
        min_prior: Int = BOUNDS_MIN_PRIOR,
        reference_len: Int = CUSUM_MIN_REFERENCE,
        slack_sigmas: Float64 = DEFAULT_SLACK_SIGMAS,
        threshold_sigmas: Float64 = DEFAULT_THRESHOLD_SIGMAS,
    ) raises:
        if limit_sigmas <= 0.0:
            raise Error(
                String("komira_anomaly: bound limit must be > 0; got ")
                + String(limit_sigmas)
            )
        if min_prior < 2:
            raise Error(
                String("komira_anomaly: bounds need at least 2 prior points")
                + String(" to have a scale at all; got ")
                + String(min_prior)
            )
        if reference_len < CUSUM_MIN_REFERENCE:
            # ⚠ THE SAME REFUSAL THE BATCH CHART MAKES, AT THE SAME NUMBER. A
            # shorter reference is what made the chart false-alarm on 13 of 82
            # real cells; the online path must not be a way around it.
            raise Error(
                String("komira_anomaly: chart reference must be >= ")
                + String(CUSUM_MIN_REFERENCE)
                + String("; got ")
                + String(reference_len)
            )
        self.stats = RunningStats()
        self.limit_sigmas = limit_sigmas
        self.min_prior = min_prior
        self.declined = BOUNDS_DECLINED_TOO_FEW_PRIOR
        self.reference = []
        self.reference_len = reference_len
        self.frozen = False
        self.mu = Float64(0.0)
        self.sigma = Float64(0.0)
        self.slack_sigmas = slack_sigmas
        self.threshold_sigmas = threshold_sigmas
        self.chart_declined = CUSUM_DECLINED_REFERENCE_TOO_SHORT
        self.c_hi = Float64(0.0)
        self.c_lo = Float64(0.0)
        self.peak_hi = Float64(0.0)
        self.peak_lo = Float64(0.0)
        self.chart_points = 0
        self.chart_signalled = False
        self.chart_signal_index = -1
        self.chart_direction = 0
        self.observed = 0

    def _freeze_reference(mut self):
        """Compute mu and sigma from the completed prefix, then RELEASE it.

        The release is the point: after this call the per-series memory is a
        fixed handful of scalars no matter how many points arrive.
        """
        self.mu = median_of(self.reference)
        self.sigma = estimate_scale(self.reference)
        self.reference = []
        self.frozen = True
        if self.sigma <= 0.0 or not isfinite(self.sigma):
            self.chart_declined = CUSUM_DECLINED_ZERO_SCALE
        else:
            self.chart_declined = CUSUM_DECLINED_NONE

    def observe(mut self, x: Float64) -> BoundSignal:
        """Judge `x` against everything already accumulated, THEN accumulate it.

        Returns the ruling. The chart is advanced as a side effect; read it
        from `chart_signalled` / `chart_direction`.
        """
        var sig = BoundSignal()
        sig.n_prior = self.stats.count
        sig.mean_prior = self.stats.mean
        sig.sigma_prior = self.stats.stddev()
        sig.limit_sigmas = self.limit_sigmas

        if sig.n_prior < self.min_prior:
            self.declined = BOUNDS_DECLINED_TOO_FEW_PRIOR
        elif sig.sigma_prior <= 0.0 or not isfinite(sig.sigma_prior):
            # A series that has been perfectly constant for its whole history
            # has no scale to express a bound in. Refusing is right: the
            # alternative is treating any change at all as infinitely many
            # sigmas, which fires on the first point that differs in the last
            # digit.
            self.declined = BOUNDS_DECLINED_ZERO_SCALE
        else:
            self.declined = BOUNDS_DECLINED_NONE
            sig.armed = True
            sig.z = (x - sig.mean_prior) / sig.sigma_prior
            if sig.z > self.limit_sigmas:
                sig.breached = True
                sig.direction = 1
            elif sig.z < -self.limit_sigmas:
                sig.breached = True
                sig.direction = -1

        # THE REASON TRAVELS WITH THE RULING. A consumer that has only the
        # signal must not have to re-derive this against a threshold it cannot
        # see — see `BoundSignal.declined`.
        sig.declined = self.declined

        # ── the chart, incrementally ──────────────────────────────────────
        if not self.frozen:
            self.reference.append(x)
            if len(self.reference) >= self.reference_len:
                self._freeze_reference()
        elif self.chart_declined == CUSUM_DECLINED_NONE:
            var k = self.slack_sigmas * self.sigma
            var h = self.threshold_sigmas * self.sigma
            var d = x - self.mu
            self.c_hi = self.c_hi + d - k
            if self.c_hi < 0.0:
                self.c_hi = Float64(0.0)
            self.c_lo = self.c_lo - d - k
            if self.c_lo < 0.0:
                self.c_lo = Float64(0.0)
            if self.c_hi > self.peak_hi:
                self.peak_hi = self.c_hi
            if self.c_lo > self.peak_lo:
                self.peak_lo = self.c_lo
            if not self.chart_signalled:
                if self.c_hi > h:
                    self.chart_signalled = True
                    self.chart_signal_index = self.observed
                    self.chart_direction = 1
                elif self.c_lo > h:
                    self.chart_signalled = True
                    self.chart_signal_index = self.observed
                    self.chart_direction = -1
            self.chart_points += 1

        self.stats.update(x)
        self.observed += 1
        return sig^

    def reset(mut self):
        """Back to an accumulation that has seen nothing.

        ⚠ THIS DISCARDS THE FROZEN REFERENCE TOO, and that is correct: the
        reference describes a regime the caller has just declared over.
        """
        self.stats = RunningStats()
        self.declined = BOUNDS_DECLINED_TOO_FEW_PRIOR
        self.reference = []
        self.frozen = False
        self.mu = Float64(0.0)
        self.sigma = Float64(0.0)
        self.chart_declined = CUSUM_DECLINED_REFERENCE_TOO_SHORT
        self.c_hi = Float64(0.0)
        self.c_lo = Float64(0.0)
        self.peak_hi = Float64(0.0)
        self.peak_lo = Float64(0.0)
        self.chart_points = 0
        self.chart_signalled = False
        self.chart_signal_index = -1
        self.chart_direction = 0
        self.observed = 0
