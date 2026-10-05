# =============================================================================
# komira_anomaly.cusum — THE SECONDARY DETECTOR: TABULAR CUSUM FOR SLOW DRIFT.
# =============================================================================
#
# ★ WHY A SECOND DETECTOR AT ALL. E-divisive tests for a STEP: a point where
# the distribution changes. A regression that arrives as 2% per commit for ten
# commits has no step anywhere in it — every adjacent pair is well inside the
# noise — and yet the series has moved 22%. The primary can miss that
# indefinitely; a cumulative-sum chart cannot, because it integrates the
# deviation instead of testing it pointwise.
#
# ── THE CHART ────────────────────────────────────────────────────────────────
#
#   C+_i = max(0, C+_{i-1} + (x_i - mu) - k)
#   C-_i = max(0, C-_{i-1} - (x_i - mu) - k)
#
# signalling when either exceeds h. `k` is the SLACK — the per-point drift the
# chart is willing to absorb without accumulating — and `h` is the DECISION
# INTERVAL. Both are expressed in units of the estimated scale, so the chart is
# scale-free and no per-series constant has to be configured: `k = 0.5*sigma`
# and `h = 5*sigma` are the textbook pair, tuned to catch a sustained 1-sigma
# shift in around 10 points while running long between false alarms.
#
# ── ⭐ THE SCALE ESTIMATE IS ROBUST, AND THAT IS LOAD-BEARING ───────────────
#
# `sigma` is estimated as 1.4826 * MAD (median absolute deviation), NOT as the
# standard deviation. On a reference window drawn from real measurement data
# this is not a refinement, it is the difference between working and not: a
# single slow outlier — one sweep that hit a noisy neighbour — inflates the
# standard deviation enough to make the chart blind for the rest of the run,
# because k and h are both proportional to it. The MAD ignores it. The 1.4826
# is the constant that makes 1.4826*MAD estimate the same quantity as the
# standard deviation when the data really is Gaussian, so the textbook k and h
# keep their textbook meaning.
#
# ⛔ AND IT DECLINES RATHER THAN DIVIDING BY ZERO. A reference window whose
# points are all identical has MAD 0, and every subsequent point is then
# infinitely many sigmas away. That is not a detection, it is a chart with no
# scale: `estimate_scale` returns 0.0 and `run_cusum` reports
# `CUSUM_DECLINED_ZERO_SCALE` and signals NOTHING. The primary still rules on
# such a series — a step in a zero-variance series is exactly what E-divisive
# finds most easily — so declining here loses no coverage, and the verdict says
# out loud that the secondary did not run.
#
# ── ⭐ AND IT DECLINES ON A SHORT REFERENCE, WHICH WAS MEASURED, NOT ASSUMED ─
#
# `CUSUM_MIN_REFERENCE` is 20, and the number that put it there is this: on the
# 82 real cells of a recorded benchmark campaign — ten sweeps of ONE binary,
# so a known zero — a chart parameterised from a 10-POINT reference fires on
# 13 OF 82. That is a 16% false-alarm rate on data in which nothing changed,
# against a budget of at most one firing per corpus run.
#
# The cause is not the chart, it is the scale estimate feeding it. Measured over
# those same 82 cells, the observed range is more than 5x the 10-point MAD
# estimate on 28 OF THEM, where a Gaussian sample of 10 would put that ratio
# near 3.1. Real measurement noise here is heavy-tailed, so a MAD taken from ten
# points comes in low, and `h = 5*sigma` built on a low sigma is a threshold set
# far too tight. Both k and h scale with the same underestimate, so the error
# does not cancel — it compounds.
#
# Twenty is the low end of the usual Phase-I recommendation for a control chart,
# and it is a REFUSAL rather than a smaller multiplier on purpose: raising `h`
# until this corpus went quiet would be tuning the instrument to the one dataset
# it was supposed to be tested against.
#
# ── ⛔ THE FALSE-ALARM RATE AT A SUFFICIENT REFERENCE LENGTH: MEASURED, AND
# ── THE ARM FAILS IT
#
# The same campaign recorded per-LAUNCH records — one
# JSON row per launch, keyed `"i": 0..n-1`, so the measurement ORDER is
# preserved — of one query relaunched 30 to 100 times against ONE binary. Six
# such series, 320 points, every one longer than the reference. On them:
#
#     the CUSUM arm            fires on  3 of 6   <- 50%, budget is <=1/run
#     the change-point arm     fires on  0 of 6
#     the running-bounds arm   fires on  0 of 6
#
# ⚠ AND THE FIRINGS ARE EXPLAINED, WHICH IS WHY THIS IS A VERDICT ON THE ARM
# RATHER THAN ON THE DATA. Two of the three series are BIMODAL — a launch-time
# placement lottery puts each run in one of two regimes, 15.4 ms or 18.1 ms —
# and the reference MAD measures the spread WITHIN whichever mode dominated the
# prefix (0.235 ms) while the gap BETWEEN the modes is 2.663 ms, i.e. ELEVEN of
# those sigmas. Every point of the other mode is then an 11-sigma event and the
# chart is arithmetically certain to signal. The third firing is a real ~0.5%
# drift amplified by a very small MAD. None of them is a code change; nothing
# could be, because it is the same executable relaunched.
#
# ⛔ SO THE ARM IS ADVISORY BY DEFAULT. `DEFAULT_CUSUM_ARMS_VERDICT` is False:
# the chart still runs, and `Verdict.cusum_signalled` still carries what it
# found, but it does not by itself set ANOMALY. Turning it on
# (`cusum_arms_verdict=True`) is supported and is the right thing to do once it
# has been recalibrated for the data it is being pointed at — a robust scale
# that survives multimodality is the open question, and it is a real one, not a
# constant to be raised until this corpus goes quiet.
#
# ⛔ AND THE SOURCE THAT LOOKS RIGHT AND IS NOT. The sweeps' warm-rep arrays
# (5 warm reps x 10 sweeps = 50 points per cell) are the obvious way to build a
# long series, and they are unusable: the sweep driver records them
# as `sorted(...)`, and 840 of 840 recorded arrays are ascending. The
# measurement order is gone, so a concatenation ramps upward inside every
# 5-point block by construction — precisely the shape this chart detects. It
# would have manufactured the drift it then reported.
#
# Falsifier for every number above: `tests/test_real_launch_series.mojo`.
#
# ⚠ THE REFERENCE WINDOW IS EXCLUDED FROM THE CHART IT PARAMETERISES. The
# window defines mu and sigma; running the chart back over it would test those
# points against statistics computed from themselves. The chart starts at the
# first point AFTER the window.
#
# Encapsulation: value types only, ZERO UnsafePointer, no wildcard origins.
# =============================================================================

from std.math import isfinite

# 1 / Phi^-1(3/4). Makes 1.4826*MAD a consistent estimator of the standard
# deviation under normality, so the textbook k and h keep their meaning.
comptime MAD_TO_SIGMA: Float64 = 1.4826

comptime DEFAULT_SLACK_SIGMAS: Float64 = 0.5
comptime DEFAULT_THRESHOLD_SIGMAS: Float64 = 5.0

# The shortest Phase-I reference from which a usable scale can be estimated.
# See the module header: at 10 the chart false-alarms on 13 of 82 known-zero
# cells, because a 10-point MAD underestimates this data's dispersion.
comptime CUSUM_MIN_REFERENCE: Int = 20

# Why the chart did not run. `CUSUM_DECLINED_NONE` means it did.
comptime CUSUM_DECLINED_NONE: Int = 0
comptime CUSUM_DECLINED_REFERENCE_TOO_SHORT: Int = 1
comptime CUSUM_DECLINED_NO_POINTS_AFTER_REFERENCE: Int = 2
comptime CUSUM_DECLINED_ZERO_SCALE: Int = 3


def cusum_decline_name(reason: Int) -> StaticString:
    """The decline reason as a word, so a verdict says which arm was silent and
    why — a secondary that quietly did not run is indistinguishable from a
    secondary that ran and found nothing.

    ⚠ `StaticString`, NOT `String` — `scripts/lint_literal_return_ladder.py`."""
    if reason == CUSUM_DECLINED_NONE:
        return "ran"
    if reason == CUSUM_DECLINED_REFERENCE_TOO_SHORT:
        return "reference_shorter_than_20"
    if reason == CUSUM_DECLINED_NO_POINTS_AFTER_REFERENCE:
        return "no_points_after_reference"
    if reason == CUSUM_DECLINED_ZERO_SCALE:
        return "zero_scale"
    return "unknown"


def _sorted_copy(v: List[Float64]) -> List[Float64]:
    """Insertion sort of a copy. n is a few hundred at most, and this is
    deterministic and allocation-light — the cost is invisible beside one
    permutation test."""
    var out = v.copy()
    for i in range(1, len(out)):
        var x = out[i]
        var j = i - 1
        while j >= 0 and out[j] > x:
            out[j + 1] = out[j]
            j -= 1
        out[j + 1] = x
    return out^


def median_of(v: List[Float64]) -> Float64:
    """The median. 0.0 for an empty input — callers guard on length first."""
    var n = len(v)
    if n == 0:
        return Float64(0.0)
    var s = _sorted_copy(v)
    if n % 2 == 1:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2.0


def estimate_scale(v: List[Float64]) -> Float64:
    """1.4826 * MAD. Returns 0.0 when the sample has no dispersion.

    A zero return is a REFUSAL, not a measurement of zero spread — see the
    module header. Callers must branch on it rather than dividing by it.
    """
    if len(v) == 0:
        return Float64(0.0)
    var med = median_of(v)
    var dev = List[Float64]()
    for i in range(len(v)):
        dev.append(abs(v[i] - med))
    return MAD_TO_SIGMA * median_of(dev)


struct CusumResult(Copyable, Movable, Deinitable):
    """The chart's outcome over one series.

    `signal_index` is the index of the point at which a limit was first
    crossed, or -1. `direction` is +1 for an upward drift (the regression
    direction for a latency series), -1 for downward, 0 for no signal.
    """

    var signalled: Bool
    var signal_index: Int
    var direction: Int
    var peak_high: Float64
    var peak_low: Float64
    var mu: Float64
    var sigma: Float64
    var declined: Int

    def __init__(
        out self,
        signalled: Bool,
        signal_index: Int,
        direction: Int,
        peak_high: Float64,
        peak_low: Float64,
        mu: Float64,
        sigma: Float64,
        declined: Int,
    ):
        self.signalled = signalled
        self.signal_index = signal_index
        self.direction = direction
        self.peak_high = peak_high
        self.peak_low = peak_low
        self.mu = mu
        self.sigma = sigma
        self.declined = declined

    def ran(self) -> Bool:
        return self.declined == CUSUM_DECLINED_NONE


def run_cusum(
    v: List[Float64],
    reference_len: Int,
    slack_sigmas: Float64,
    threshold_sigmas: Float64,
) -> CusumResult:
    """Two-sided tabular CUSUM over v, parameterised by v[0:reference_len).

    The chart runs from `reference_len` forward. It DECLINES — signalling
    nothing and saying which case it hit — when the reference is shorter than
    `CUSUM_MIN_REFERENCE`, when no points follow the reference, or when the
    reference has no dispersion to estimate a scale from.
    """
    var n = len(v)
    if reference_len < CUSUM_MIN_REFERENCE:
        return CusumResult(
            False, -1, 0, Float64(0.0), Float64(0.0),
            Float64(0.0), Float64(0.0),
            CUSUM_DECLINED_REFERENCE_TOO_SHORT,
        )
    if n <= reference_len:
        return CusumResult(
            False, -1, 0, Float64(0.0), Float64(0.0),
            Float64(0.0), Float64(0.0),
            CUSUM_DECLINED_NO_POINTS_AFTER_REFERENCE,
        )

    # NOT named `ref` -- that is a Mojo argument-convention keyword.
    var window = List[Float64]()
    for i in range(reference_len):
        window.append(v[i])
    var mu = median_of(window)
    var sigma = estimate_scale(window)

    if sigma <= 0.0 or not isfinite(sigma):
        return CusumResult(
            False, -1, 0, Float64(0.0), Float64(0.0), mu, Float64(0.0),
            CUSUM_DECLINED_ZERO_SCALE,
        )

    var k = slack_sigmas * sigma
    var h = threshold_sigmas * sigma
    var c_hi = Float64(0.0)
    var c_lo = Float64(0.0)
    var peak_hi = Float64(0.0)
    var peak_lo = Float64(0.0)
    var sig_idx = -1
    var direction = 0

    for i in range(reference_len, n):
        var d = v[i] - mu
        c_hi = c_hi + d - k
        if c_hi < 0.0:
            c_hi = Float64(0.0)
        c_lo = c_lo - d - k
        if c_lo < 0.0:
            c_lo = Float64(0.0)
        if c_hi > peak_hi:
            peak_hi = c_hi
        if c_lo > peak_lo:
            peak_lo = c_lo
        if sig_idx < 0:
            # ⚠ The FIRST crossing is retained, not the last. The chart keeps
            # accumulating afterwards so the peaks stay informative, but the
            # index a report cites must be where the evidence first became
            # sufficient, not where the run happened to stop.
            if c_hi > h:
                sig_idx = i
                direction = 1
            elif c_lo > h:
                sig_idx = i
                direction = -1

    return CusumResult(
        sig_idx >= 0, sig_idx, direction, peak_hi, peak_lo, mu, sigma,
        CUSUM_DECLINED_NONE,
    )
