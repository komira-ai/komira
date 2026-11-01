# =============================================================================
# komira_anomaly.detector — THE STATE MACHINE.
# =============================================================================
#
# ★ FOUR STATES. THREE ARE THE SERIES' HEALTH; THE FOURTH IS THE INSTRUMENT
# REFUSING TO REPORT.
#
#   ACCUMULATING — too few points to test. NOT green, and it never becomes
#                  green by waiting quietly: it reports (n/min) every time it
#                  is asked, so 'the detector said nothing' can never be read
#                  as 'the detector found nothing'.
#   NORMAL       — enough points, tested, no change point at the configured
#                  significance and no cumulative drift.
#   ANOMALY      — a change point at p < significance, or a CUSUM crossing.
#   UNCALIBRATED — the instrument could not run on this input.
#
# ⛔ WHY UNCALIBRATED IS NOT AN OPTIONAL FOURTH. Every other outcome would have
# to be spelled NORMAL, and NORMAL from a detector that never ran is the
# fail-quiet gate: an empty result is
# indistinguishable from compliance. A refusal that names its reason is the
# only honest thing to return when the data cannot be computed on.
#
# ── ⭐ THE LATCH: AN ANOMALY DOES NOT SELF-CLEAR ─────────────────────────────
#
# Once ANOMALY, this detector STAYS ANOMALY until a human calls `acknowledge`
# or `dismiss`. It would be easy — and wrong — to refit on every new point and
# quietly return to NORMAL when the fit weakens.
#
# The reason is what the detector is FOR. A detection opens an issue, and an
# issue has an owner and a closure that is a record. A state that un-fires on
# its own gives the issue a subject that no longer exists, so the issue is closed
# as 'could not reproduce' and the next one is believed a little less. That is
# the exact decay that muted the threshold detector this replaces.
#
# So the two exits are EXPLICIT and they mean different things:
#
#   * `acknowledge()` — the change is REAL and is the new normal. The baseline
#     moves to the change point, the pre-change history leaves the window, and
#     the series re-enters ACCUMULATING on its new level. It must earn NORMAL
#     again on the new regime rather than inheriting it from the old one.
#   * `dismiss()`     — the change is NOT real. The window is unchanged, but a
#     refit landing on that same ordinal will not fire again. Without this the
#     next evaluation re-finds the identical change point and re-files the
#     identical issue, forever.
#
# ⚠ UNCALIBRATED OVERRIDES THE LATCH, DELIBERATELY. If the window later holds
# an unreadable point, the verdict becomes UNCALIBRATED even from ANOMALY: the
# detector cannot keep asserting a finding about data it can no longer read.
# Nothing is lost by this — UNCALIBRATED is a refusal, not a green — and the
# alternative is a detector reporting a state it cannot currently verify.
#
# ── THE THREE ARMS, WHAT EACH IS FOR, AND WHICH ONES ARM THE VERDICT ────────
#
#   E-DIVISIVE (primary)  finds STEPS. It is the arm carrying the verdict:
#                         0 false alarms on the 82-cell known zero, 74 of 82
#                         caught at +10%. Costs O(n^2 * P), so on the per-point
#                         path it runs on a cadence and the verdict SAYS when
#                         it did not.
#   RUNNING BOUNDS        rule on ONE point against the accumulated history, in
#                         O(1). This is what makes a posted point answerable
#                         immediately. ⛔ It is a POINT test: measured, a
#                         SUSTAINED +10% step is caught on 2 of 6 real series,
#                         because the arm folds each point into the scale that
#                         judges the next. Steps are the primary's job.
#   CUSUM (advisory)      finds DRIFT — the 2%-per-commit ramp with no step in
#                         it anywhere. ⛔ ADVISORY BY DEFAULT:
#                         measured on real order-preserving known-zero data it
#                         fires on 3 of 6 series. It still runs and is still
#                         REPORTED; it does not by itself set ANOMALY. See
#                         `DEFAULT_CUSUM_ARMS_VERDICT`.
#
# Each is reported separately in the verdict, so a reader can always see WHICH
# one fired — and `arms_ruled` says how many produced a ruling at all, because a
# verdict reached with every arm silent is a finding about the instrument, not
# about the series, and `evaluate_with` returns UNCALIBRATED for it.
#
# ── ⚠ THE SIGNIFICANCE LEVEL IS A CORPUS-WIDE BUDGET, NOT A PER-TEST TASTE ──
#
# `DEFAULT_SIGNIFICANCE` is 0.0122, not 0.05, and the difference is measured
# rather than argued. Evaluating N series per run means N chances to fire, so
# the per-series level has to be the run-wide budget divided by N. At the 82
# cells of the calibration corpus, a budget of at most one false firing per run is
# 1/82 = 0.0122.
#
# On ten sweeps of ONE binary with no code change — a strong known-zero — the
# measured firing counts are:
#
#     alpha = 0.05    ->  2 of 82 cells fire     (over budget)
#     alpha = 0.0122  ->  0 of 82 cells fire     (in budget)
#
# and the detector still catches a real 10% shift on 74 of the same 82 cells
# (90.2%). The 0.05 row is 2 — `sdk/d1_agg_spill` and `tpch/q4_order_priority`
# — and `tests/test_known_zero_corpus.mojo` asserts every one of these counts by
# EQUALITY (an assertion such as `fired > 1` would hold for 2 and 3 alike), so
# none of them can drift away from the data.
#
# Encapsulation: value types only, ZERO UnsafePointer, no wildcard origins.
# =============================================================================

from komira_anomaly.bounds import (
    BOUNDS_DECLINED_NONE,
    BOUNDS_DECLINED_TOO_FEW_PRIOR,
    BOUNDS_DECLINED_ZERO_SCALE,
    BOUNDS_MIN_PRIOR,
    BoundSignal,
    bounds_decline_name,
)
from komira_anomaly.cusum import (
    CUSUM_DECLINED_NONE,
    CUSUM_MIN_REFERENCE,
    CusumResult,
    DEFAULT_SLACK_SIGMAS,
    DEFAULT_THRESHOLD_SIGMAS,
    cusum_decline_name,
    run_cusum,
)
from komira_anomaly.edivisive import (
    ChangePointFit,
    DEFAULT_MIN_SEGMENT,
    DEFAULT_PERMUTATIONS,
    MIN_SEGMENT_FLOOR,
    fit_change_point,
    seed_for_key,
)
from komira_anomaly.series import (
    SERIES_OK,
    Series,
    series_reject_reason_name,
)


comptime STATE_ACCUMULATING: Int = 0
comptime STATE_NORMAL: Int = 1
comptime STATE_ANOMALY: Int = 2
comptime STATE_UNCALIBRATED: Int = 3

# The activation precondition: below this many points the detector has no
# verdict to give and says so.
comptime DEFAULT_MIN_POINTS: Int = 10

# One false firing per 82-cell corpus run. See the module header.
comptime DEFAULT_SIGNIFICANCE: Float64 = 0.0122

# ⛔ THE SECONDARY ARM IS ADVISORY BY DEFAULT, AND THE DEFAULT IS A MEASUREMENT.
#
# Its `CUSUM_MIN_REFERENCE = 20` guard makes it inert on a 10-point series. Six
# real series long enough to exercise it — recorded benchmark launches, 320
# points of ONE binary relaunched, order preserved, no code change — and the arm
# fires on THREE OF SIX of them, against a budget of at most one firing per
# corpus run.
#
# Two of the three firings are explained and are not noise: those series are
# BIMODAL (a launch-time placement lottery puts each run in one of two regimes,
# 15.4 ms or 18.1 ms), and a median/MAD scale taken from a 20-point prefix
# measures the WITHIN-mode spread — 0.235 ms — while the gap between the modes
# is 2.663 ms, i.e. ELEVEN of those sigmas. Every point of the other mode is
# then an 11-sigma event and the chart is arithmetically certain to signal. The
# third firing is a real ~0.5% drift amplified by a very small MAD.
#
# So the chart still RUNS and its finding is still REPORTED — the evidence is
# worth having, and `Verdict.cusum_signalled` carries it — but it does not by
# itself set ANOMALY unless a caller turns it on, having recalibrated it for the
# data it is being pointed at. Turning it on with `cusum_arms_verdict=True` is
# the supported way to get the old behaviour back.
#
# `tests/test_real_launch_series.mojo` re-derives the 3-of-6 from the recorded
# numbers, so this default cannot outlive the measurement that justifies it.
comptime DEFAULT_CUSUM_ARMS_VERDICT: Bool = False

# UNCALIBRATED's third reason. Not a property of the SERIES — the two in
# `series.mojo` are — but of the INSTRUMENT: every arm was silent, so there is
# nothing to report but the silence.
comptime NO_ARM_RULED: String = "NO_ARM_RULED"


def state_name(state: Int) -> StaticString:
    """⚠ `StaticString`, NOT `String` — `scripts/lint_literal_return_ladder.py`."""
    if state == STATE_ACCUMULATING:
        return "ACCUMULATING"
    if state == STATE_NORMAL:
        return "NORMAL"
    if state == STATE_ANOMALY:
        return "ANOMALY"
    if state == STATE_UNCALIBRATED:
        return "UNCALIBRATED"
    return "UNKNOWN_STATE"


struct DetectorConfig(Copyable, Movable, Deinitable):
    """Every knob, validated at construction.

    ⛔ CONSTRUCTION RAISES ON AN IMPOSSIBLE CONFIG rather than clamping into
    something that runs. A `min_points` below `2*min_segment` can never admit a
    split, so such a detector would sit in NORMAL forever having tested
    nothing — a green light wired to no sensor. Refusing at construction puts
    the error where the value was written.
    """

    var min_points: Int
    var min_segment: Int
    var permutations: Int
    var significance: Float64
    var cusum_slack_sigmas: Float64
    var cusum_threshold_sigmas: Float64
    var cusum_arms_verdict: Bool

    def __init__(
        out self,
        min_points: Int = DEFAULT_MIN_POINTS,
        min_segment: Int = DEFAULT_MIN_SEGMENT,
        permutations: Int = DEFAULT_PERMUTATIONS,
        significance: Float64 = DEFAULT_SIGNIFICANCE,
        cusum_slack_sigmas: Float64 = DEFAULT_SLACK_SIGMAS,
        cusum_threshold_sigmas: Float64 = DEFAULT_THRESHOLD_SIGMAS,
        cusum_arms_verdict: Bool = DEFAULT_CUSUM_ARMS_VERDICT,
    ) raises:
        if min_segment < MIN_SEGMENT_FLOOR:
            raise Error(
                String("komira_anomaly: min_segment must be >= ")
                + String(MIN_SEGMENT_FLOOR)
                + String(" (the within-segment term divides by k*(k-1)); got ")
                + String(min_segment)
            )
        if min_points < 2 * min_segment:
            raise Error(
                String("komira_anomaly: min_points (")
                + String(min_points)
                + String(") is below 2*min_segment (")
                + String(2 * min_segment)
                + String("), so no split could ever be admissible and the")
                + String(" detector would report NORMAL having tested nothing")
            )
        if permutations < 1:
            raise Error(
                String("komira_anomaly: permutations must be >= 1; got ")
                + String(permutations)
            )
        if significance <= 0.0 or significance >= 1.0:
            raise Error(
                String("komira_anomaly: significance must be in (0,1); got ")
                + String(significance)
            )
        if cusum_slack_sigmas < 0.0 or cusum_threshold_sigmas <= 0.0:
            raise Error(
                String("komira_anomaly: cusum slack must be >= 0 and")
                + String(" threshold > 0")
            )
        self.min_points = min_points
        self.min_segment = min_segment
        self.permutations = permutations
        self.significance = significance
        self.cusum_slack_sigmas = cusum_slack_sigmas
        self.cusum_threshold_sigmas = cusum_threshold_sigmas
        self.cusum_arms_verdict = cusum_arms_verdict


struct Verdict(Copyable, Movable, Deinitable):
    """One evaluation's full result — the state AND the evidence for it.

    Every field an issue would need to state its subject is here, because
    an issue citing 'series X regressed' with no change point, no magnitude and
    no p-value is unactionable and unclosable.
    """

    var state: Int
    var series_key: String
    var n_points: Int
    var min_points: Int
    var change_index: Int
    var change_ordinal: Int64
    var p_value: Float64
    var statistic: Float64
    var before_mean: Float64
    var after_mean: Float64
    var relative_shift: Float64
    var cusum_signalled: Bool
    var cusum_direction: Int
    # The RUNNING-BOUNDS arm's ruling on the newest point. `bound_armed` is
    # false both when no bound was available and on the batch path, where no
    # point is 'newest'; `bound_breached` is meaningless unless it is true.
    var bound_armed: Bool
    var bound_breached: Bool
    var bound_z: Float64
    var bound_direction: Int
    # The ordinal of the NEWEST point in the evaluated window — the point the
    # bounds arm ruled on. It is where a bounds-only ANOMALY's new regime
    # begins, and `acknowledge` needs it for exactly that.
    var bound_ordinal: Int64
    # ⭐ DID THE CHANGE-POINT ARM *FIRE*, or did it merely RUN? The distinction
    # is not cosmetic: a fit that ran and found nothing still populates
    # `change_index`, `change_ordinal` and `relative_shift` with the best
    # non-significant split it could find, and an `acknowledge()` that moved
    # the baseline to that ordinal would discard real history at a
    # boundary the detector had explicitly declined to assert. Measured: a
    # bounds-only ANOMALY on a 13-point series carried at_ordinal=3, p=0.763,
    # and acknowledging it threw away three points and kept ten straddling the
    # actual step.
    var changepoint_fired: Bool
    # ⭐ HOW MANY ARMS ACTUALLY PRODUCED A RULING. Zero is the number that
    # matters: a verdict reached with every arm silent is not a finding about
    # the series, it is a finding about the instrument, and `evaluate_with`
    # turns that case into UNCALIBRATED rather than NORMAL.
    var arms_ruled: Int
    var detail: String

    def __init__(
        out self,
        state: Int,
        series_key: String,
        n_points: Int,
        min_points: Int,
        detail: String,
    ):
        self.state = state
        self.series_key = series_key
        self.n_points = n_points
        self.min_points = min_points
        self.change_index = -1
        self.change_ordinal = Int64(0)
        self.p_value = Float64(1.0)
        self.statistic = Float64(0.0)
        self.before_mean = Float64(0.0)
        self.after_mean = Float64(0.0)
        self.relative_shift = Float64(0.0)
        self.cusum_signalled = False
        self.cusum_direction = 0
        self.bound_armed = False
        self.bound_breached = False
        self.bound_z = Float64(0.0)
        self.bound_direction = 0
        self.bound_ordinal = Int64(0)
        self.changepoint_fired = False
        self.arms_ruled = 0
        self.detail = detail

    def state_name(self) -> String:
        return state_name(self.state)

    def is_green(self) -> Bool:
        """NORMAL is the ONLY green. ACCUMULATING and UNCALIBRATED are not
        failures, but they are not passes either, and a caller that treats
        'not ANOMALY' as a pass has re-created the vacuous gate."""
        return self.state == STATE_NORMAL

    def render(self) -> String:
        """One line, stable enough to grep and complete enough to act on."""
        var head = self.state_name() + String(" series=") + self.series_key
        if self.state == STATE_ACCUMULATING:
            return (
                head
                + String(" (")
                + String(self.n_points)
                + String("/")
                + String(self.min_points)
                + String(")")
            )
        if self.state == STATE_UNCALIBRATED:
            return head + String(" reason=") + self.detail
        var body = head + String(" n=") + String(self.n_points)
        # ⚠ `p=` IS PRINTED ONLY WHEN A FIT PRODUCED ONE. An unfitted
        # `ChangePointFit` carries p = 1.0, and printing that on a line where
        # the primary arm never ran reads as 'tested, no evidence' — the
        # strongest possible statement of a thing that was not measured.
        if self.change_index >= 0:
            body = body + String(" p=") + String(self.p_value)
        if self.bound_armed:
            body = body + String(" z=") + String(self.bound_z)
        body = body + String(" arms=") + String(self.arms_ruled)
        if self.state == STATE_ANOMALY:
            # ⛔ ONLY WHEN THE ARM FIRED. Printing `at_ordinal=` from a fit
            # that ran and found nothing puts a boundary the detector declined
            # to assert onto the line an issue is written from.
            if self.changepoint_fired:
                body = (
                    body
                    + String(" at_ordinal=")
                    + String(self.change_ordinal)
                    + String(" shift=")
                    + String(self.relative_shift)
                )
            if self.bound_breached:
                body = (
                    body
                    + String(" bound=")
                    + String(self.bound_z)
                    + String("sigma dir=")
                    + String(self.bound_direction)
                )
            body = body + String(" cusum=") + String(self.cusum_signalled)
        # ⚠ THE DETAIL RIDES ON *NORMAL* TOO, AND THAT IS THE POINT. A NORMAL
        # reached only because an operator dismissed a change point, or one
        # whose secondary arm declined to run, is a different fact from a
        # NORMAL where both arms ran and found nothing — and a reader who
        # cannot tell them apart has been handed the weaker of the two dressed
        # as the stronger.
        if self.detail.byte_length() > 0:
            body = body + String(" ") + self.detail
        return body


struct SeriesDetector(Copyable, Movable, Deinitable):
    """The per-series state machine. One instance per series key.

    Holds STATE, not DATA: the window is expressed as a baseline ordinal, so
    every `evaluate` reads whatever the source now holds and a refit always
    sees the full history rather than a cached copy that could drift from it.
    """

    var config: DetectorConfig
    var key: String
    var state: Int
    var baseline_ordinal: Int64
    var has_dismissed: Bool
    var dismissed_ordinal: Int64
    var last: Verdict

    def __init__(out self, key: String, config: DetectorConfig):
        self.config = config.copy()
        self.key = key
        self.state = STATE_ACCUMULATING
        # Int64.MIN: no point can precede it, so the initial window is the
        # whole series without needing an 'unset' flag.
        self.baseline_ordinal = Int64.MIN
        self.has_dismissed = False
        self.dismissed_ordinal = Int64(0)
        self.last = Verdict(
            STATE_ACCUMULATING, key, 0, config.min_points, String("")
        )

    def evaluate(mut self, series: Series) raises -> Verdict:
        """The BATCH entry point: re-read the whole series, rule on it.

        Runs the change-point arm and passes NO bound signal — there is no
        'newest point' on this path. Unchanged in behaviour from before the
        online reshape, which `tests/test_online_api.mojo` pins by driving the
        same points through both paths and comparing the verdicts.
        """
        return self.evaluate_with(series, True, BoundSignal())

    def evaluate_with(
        mut self,
        series: Series,
        run_changepoint: Bool,
        bound: BoundSignal,
    ) raises -> Verdict:
        """THE ONE STATE MACHINE. Both the batch path and the post-a-point path
        reach a verdict through here, so the latch, the dismissal suppression
        and the activation boundary exist exactly once.

        `run_changepoint` is False when the caller is on the per-point path and
        this point is not a refit point — the primary arm is O(n^2 * P) and
        cannot run on every posted point. THE VERDICT SAYS SO when it does not
        run; see `arms_ruled`.

        `bound` is the running-bounds arm's ruling on the newest point, or a
        default-constructed (unarmed) signal on the batch path.

        ⚠ THE KEY MUST MATCH. A detector carries one series' latch, baseline
        and dismissal; handing it a different series would apply all three to
        data they were never about. Raising is the only safe answer — there is
        no sensible way to guess which of the two identities was meant.
        """
        if series.key != self.key:
            raise Error(
                String("komira_anomaly: detector for series '")
                + self.key
                + String("' was handed series '")
                + series.key
                + String("'; a detector's latch, baseline and dismissal are")
                + String(" about ONE series and cannot transfer")
            )

        var window = series.since(self.baseline_ordinal)
        var reject = window.validate()
        if reject != SERIES_OK:
            # Overrides the latch — see the module header.
            self.state = STATE_UNCALIBRATED
            self.last = Verdict(
                STATE_UNCALIBRATED,
                self.key,
                window.count(),
                self.config.min_points,
                series_reject_reason_name(reject),
            )
            return self.last.copy()

        if self.state == STATE_ANOMALY:
            # LATCHED. Refresh only the point count, so the report stays
            # current about size while its SUBJECT — the change point, its
            # p-value and its magnitude — stays exactly what was found.
            self.last.n_points = window.count()
            return self.last.copy()

        var n = window.count()
        if n < self.config.min_points:
            self.state = STATE_ACCUMULATING
            self.last = Verdict(
                STATE_ACCUMULATING,
                self.key,
                n,
                self.config.min_points,
                String(""),
            )
            return self.last.copy()

        var vals = window.values()
        var fit = ChangePointFit(
            -1, Float64(0.0), Float64(1.0), self.config.permutations,
            Float64(0.0), Float64(0.0),
        )
        if run_changepoint:
            fit = fit_change_point(
                vals,
                self.config.min_segment,
                self.config.permutations,
                seed_for_key(self.key),
            )
        # ⚠ THE CHART'S REFERENCE IS NOT `min_points`. `min_points` is the
        # PRIMARY's activation threshold; the chart needs its own, longer one,
        # because a scale estimated from ten points false-alarms on 13 of the
        # 82 real known-zero cells (`cusum.mojo`'s header carries the
        # measurement). Taking the larger of the two keeps a caller who raises
        # `min_points` from silently shortening the chart's reference.
        var cusum_reference = self.config.min_points
        if cusum_reference < CUSUM_MIN_REFERENCE:
            cusum_reference = CUSUM_MIN_REFERENCE
        var cus = run_cusum(
            vals,
            cusum_reference,
            self.config.cusum_slack_sigmas,
            self.config.cusum_threshold_sigmas,
        )

        var cp_fired = fit.is_fitted() and fit.p_value < self.config.significance
        var suppressed = False
        var change_ordinal = Int64(0)
        if fit.is_fitted():
            change_ordinal = window.points[fit.index].ordinal
            if self.has_dismissed and change_ordinal == self.dismissed_ordinal:
                cp_fired = False
                suppressed = True

        # ⛔ THE CHART SIGNALLING IS NOT THE SAME QUESTION AS THE CHART ARMING
        # THE VERDICT. Measured on real data it false-alarms on 3 of 6
        # known-zero series, so by default its finding is REPORTED and does not
        # by itself set ANOMALY — see `DEFAULT_CUSUM_ARMS_VERDICT`.
        var cusum_fired = cus.signalled and self.config.cusum_arms_verdict

        # ── ⭐ HOW MANY ARMS ACTUALLY RULED ───────────────────────────────
        # An arm counts only if it produced a ruling on THIS evaluation. A
        # declined chart, a skipped refit and an unarmed bound each count zero,
        # which is what makes 'nothing fired' distinguishable from 'nothing
        # ran'.
        var arms = 0
        if run_changepoint and fit.is_fitted():
            arms += 1
        if cus.declined == CUSUM_DECLINED_NONE and self.config.cusum_arms_verdict:
            arms += 1
        if bound.armed:
            arms += 1

        var detail = String("")
        if cp_fired:
            detail = String("arm=changepoint")
        if bound.breached:
            if detail.byte_length() > 0:
                detail = detail + String("+bounds")
            else:
                detail = String("arm=bounds")
        if cusum_fired:
            if detail.byte_length() > 0:
                detail = detail + String("+cusum")
            else:
                detail = String("arm=cusum")
        if detail.byte_length() == 0 and suppressed:
            detail = String("changepoint_dismissed_at_ordinal")
        if cus.signalled and not self.config.cusum_arms_verdict:
            # The chart's finding, kept visible while it is advisory. Dropping
            # it would make an advisory arm and an absent arm the same bytes.
            detail = detail + String(" cusum_advisory=signalled")
        if cus.declined != CUSUM_DECLINED_NONE:
            # ★ SAID OUT LOUD, ALWAYS. A secondary arm that quietly did not run
            # is indistinguishable in the record from one that ran and found
            # nothing, and the difference is the whole of what the verdict is
            # worth.
            detail = (
                detail
                + String(" cusum_declined=")
                + cusum_decline_name(cus.declined)
            )
        if not run_changepoint:
            detail = detail + String(" changepoint_not_run=refit_cadence")
        if not bound.armed:
            detail = (
                detail
                + String(" bounds_declined=")
                + bounds_decline_name(self._bounds_decline_of(bound))
            )

        var new_state = STATE_NORMAL
        if cp_fired or cusum_fired or bound.breached:
            new_state = STATE_ANOMALY
        elif arms == 0:
            # ⛔ NORMAL IS A RULING AND THERE WAS NO RULING TO MAKE. Every arm
            # was silent: the primary did not run, the chart declined or is
            # advisory, and the bound had no scale. Reporting NORMAL here is
            # precisely the fail-quiet gate this module refuses elsewhere — an
            # empty result read as compliance — so it is UNCALIBRATED, which is
            # not green either.
            new_state = STATE_UNCALIBRATED
            detail = String(NO_ARM_RULED) + String(" ") + detail

        var v = Verdict(
            new_state, self.key, n, self.config.min_points, detail
        )
        v.change_index = fit.index
        v.change_ordinal = change_ordinal
        v.p_value = fit.p_value
        v.statistic = fit.statistic
        v.before_mean = fit.before_mean
        v.after_mean = fit.after_mean
        v.relative_shift = fit.relative_shift()
        v.cusum_signalled = cus.signalled
        v.cusum_direction = cus.direction
        v.bound_armed = bound.armed
        v.bound_breached = bound.breached
        v.bound_z = bound.z
        v.bound_direction = bound.direction
        v.bound_ordinal = window.points[n - 1].ordinal
        v.changepoint_fired = cp_fired
        v.arms_ruled = arms

        self.state = new_state
        self.last = v.copy()
        return v^

    def _bounds_decline_of(self, bound: BoundSignal) -> Int:
        """Which decline word an unarmed bound earns — READ, not re-derived.

        ⛔ THE REASON IS NOT RECONSTRUCTED FROM `n_prior` AGAINST THE
        MODULE-DEFAULT `BOUNDS_MIN_PRIOR`: THAT IS WRONG FOR EVERY CALLER WHO
        CONFIGURED ANOTHER THRESHOLD. A monitor built with
        `bound_min_prior = 1000`, 59 points in, would be reported `zero_scale`:
        a specific, false claim about a series whose scale is fine, in the exact
        record an issue is written from. The arm that declined knows which
        threshold it declined against; it says so on the signal.
        """
        if bound.armed:
            return BOUNDS_DECLINED_NONE
        return bound.declined


    def acknowledge(mut self) raises:
        """The change is real and is the new normal.

        Moves the baseline to the change point, so the pre-change history
        leaves the window, and returns the series to ACCUMULATING on its new
        level — it must earn NORMAL on the new regime, not inherit it.
        """
        if self.state != STATE_ANOMALY:
            raise Error(
                String("komira_anomaly: acknowledge() on a detector in state ")
                + state_name(self.state)
                + String(" — only an ANOMALY can be acknowledged")
            )
        # ── ⭐ WHICH ORDINAL IS 'WHERE THE NEW REGIME BEGINS'? ────────────
        #
        # ⛔ IT IS NOT `change_ordinal` UNLESS THE CHANGE-POINT ARM FIRED. A fit
        # that ran and found nothing still reports its best non-significant
        # split; moving the baseline there would discard history at a boundary
        # the detector had explicitly declined to assert.
        # `test_acknowledge_resets_the_running_bounds` pins this with a
        # bounds-only ANOMALY carrying at_ordinal=3
        # and p=0.763 on a series whose real step was at ordinal 12.
        #
        # The three cases, and each one's honest answer:
        if self.last.changepoint_fired:
            # A change point WAS asserted. Its ordinal is the boundary.
            self.baseline_ordinal = self.last.change_ordinal
        elif self.last.bound_breached:
            # The RUNNING BOUNDS fired on the newest point. There is no fitted
            # boundary, but there is a meaningful one: the breaching point is
            # where the operator has just decided the new level begins.
            self.baseline_ordinal = self.last.bound_ordinal
        else:
            # A chart-only ANOMALY. The CUSUM signal index names where the
            # EVIDENCE became sufficient, not where the level changed, and
            # those are different points by construction — the chart integrates.
            # Moving the baseline there would be a guess, and the alternative
            # default of ordinal 0 silently discards the entire series.
            raise Error(
                String("komira_anomaly: this ANOMALY has no fitted change")
                + String(" point and no bound breach (chart-only); there is no")
                + String(" ordinal that means 'the new regime starts here' —")
                + String(" use dismiss() or reset()")
            )
        self.has_dismissed = False
        self.state = STATE_ACCUMULATING
        self.last = Verdict(
            STATE_ACCUMULATING,
            self.key,
            0,
            self.config.min_points,
            String("acknowledged_new_baseline"),
        )

    def dismiss(mut self) raises:
        """The change is not real. The window is unchanged; a refit landing on
        the SAME ordinal will not fire again."""
        if self.state != STATE_ANOMALY:
            raise Error(
                String("komira_anomaly: dismiss() on a detector in state ")
                + state_name(self.state)
                + String(" — only an ANOMALY can be dismissed")
            )
        if self.last.change_index >= 0:
            self.has_dismissed = True
            self.dismissed_ordinal = self.last.change_ordinal
        self.state = STATE_NORMAL
        self.last = Verdict(
            STATE_NORMAL,
            self.key,
            self.last.n_points,
            self.config.min_points,
            String("dismissed"),
        )

    def reset(mut self):
        """Back to a detector that has seen nothing. The whole series is in
        window again and no dismissal is retained."""
        self.state = STATE_ACCUMULATING
        self.baseline_ordinal = Int64.MIN
        self.has_dismissed = False
        self.dismissed_ordinal = Int64(0)
        self.last = Verdict(
            STATE_ACCUMULATING, self.key, 0, self.config.min_points, String("")
        )
