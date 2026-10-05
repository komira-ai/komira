# =============================================================================
# komira_anomaly.online — POST A POINT, GET A VERDICT. STATE PERSISTS HERE.
# =============================================================================
#
# ★ THE SHAPE: post data and get whether it is an anomaly, with the metrics
# store underneath, and running bounds that detect an anomaly quickly using
# the existing data and the new point.
#
#     var v = monitor.observe(key, ordinal, value)
#     if v.state == STATE_ANOMALY: ...
#
# The caller holds NO history. It does not load a window, it does not know how
# many points there have been, and it does not own a detector per series. It
# posts one number and reads one verdict.
#
# ── ⛔ THIS IS A RESHAPE, NOT A SECOND DETECTOR ─────────────────────────────
#
# Every verdict on this path is produced by `SeriesDetector.evaluate_with` —
# the SAME state machine the batch path uses, with the same latch, the same
# dismissal suppression and the same activation boundary. There is exactly one
# implementation of 'what state is this series in', and if there were two they
# would disagree within a month. `tests/test_online_api.mojo` drives identical
# points through both entry points and asserts the verdicts MATCH, field by
# field, which is the only way that claim stays true.
#
# ── ⭐ WHAT IS O(1) PER POINT AND WHAT IS NOT — SAID PLAINLY ────────────────
#
# `observe` always does, per point:
#
#   * the RUNNING-BOUNDS arm: Welford update + one comparison.   O(1)
#   * the CUSUM chart: two accumulator updates.                  O(1)
#   * retained-window maintenance + materialising it as a
#     `Series` for the state machine.                            O(W)
#
# ⚠ THE THIRD LINE IS O(W), NOT O(1), AND SAYING OTHERWISE WOULD BE THE KIND OF
# UNCHECKED CLAIM THIS PACKAGE KEEPS FINDING IN ITS OWN COMMENTS. `List.pop(0)`
# shifts the window and `_window_series` copies it, both W-proportional. W is
# BOUNDED — 64 by default — so the per-point cost is a constant, and the
# property that actually matters holds: it is independent of how long the series
# is and it never touches the store. A ring buffer would make it genuinely O(1)
# and is worth doing if W ever needs to be large; at 64 it is not the cost that
# decides anything.
#
# The O(1) arms are what 'quickly' names. The CHANGE-POINT arm is
# O(W^2 * P) — at W=64 and P=999 that is roughly four million distance terms —
# so it CANNOT run on every posted point, and pretending otherwise would make
# `observe` quietly the slowest call in a hot ingest path.
#
# ⛔ SO IT IS ON A CADENCE, AND THE CADENCE IS VISIBLE IN THE VERDICT. When a
# point is not a refit point the verdict carries `changepoint_not_run=refit_
# cadence` and does not count that arm in `arms_ruled`. A point whose every arm
# was silent comes back UNCALIBRATED, never NORMAL — see `detector.mojo`. The
# default `refit_every` is 8: frequent enough that a step is found within a
# handful of points, cheap enough that the amortised per-point cost stays small.
#
# ── ⚠ THE RETAINED WINDOW IS BOUNDED, AND THAT BOUND IS A REAL LIMIT ───────
#
# The change-point arm needs the actual values, so `observe` keeps the last
# `window_capacity` points (default 64) and drops the oldest. A change point
# older than that window cannot be found on this path — it is the price of not
# reading the store per point. The BOUNDS arm is unaffected: Welford carries the
# whole history in three scalars.
#
# ⚠ AND THE WINDOW IS WHY THE TWO PATHS CAN DIVERGE. Once more than
# `window_capacity` points have been posted, `observe` and a batch `evaluate`
# over the full series are ruling on DIFFERENT DATA and may legitimately differ.
# The equivalence test therefore stays inside the window on purpose, and says so.
#
# Encapsulation: value types only, ZERO UnsafePointer, no wildcard origins.
# =============================================================================

from std.collections.dict import Dict
from std.math import isfinite

from komira_anomaly.bounds import (
    BOUNDS_MIN_PRIOR,
    BoundSignal,
    DEFAULT_BOUND_SIGMAS,
    RunningBounds,
)
from komira_anomaly.cusum import CUSUM_MIN_REFERENCE
from komira_anomaly.detector import (
    DetectorConfig,
    STATE_ACCUMULATING,
    STATE_ANOMALY,
    STATE_NORMAL,
    STATE_UNCALIBRATED,
    SeriesDetector,
    Verdict,
)
from komira_anomaly.series import (
    SERIES_REJECT_NONFINITE,
    SERIES_REJECT_UNORDERED,
    Series,
    SeriesPoint,
    series_reject_reason_name,
)
from komira_anomaly.store import MeasurementStore

comptime DEFAULT_WINDOW_CAPACITY: Int = 64
comptime DEFAULT_REFIT_EVERY: Int = 8


struct OnlineConfig(Copyable, Movable, Deinitable):
    """The per-point path's knobs, validated at construction.

    Holds a `DetectorConfig` rather than restating its fields: the two paths
    must not be able to drift to different significance levels.
    """

    var detector: DetectorConfig
    var window_capacity: Int
    var refit_every: Int
    var bound_sigmas: Float64
    var bound_min_prior: Int
    var chart_reference: Int

    def __init__(out self) raises:
        """Every default. Spelled as its own overload because Mojo forbids a
        RAISING call in a default argument, and `DetectorConfig()` validates."""
        self = OnlineConfig(DetectorConfig())

    def __init__(
        out self,
        var detector: DetectorConfig,
        window_capacity: Int = DEFAULT_WINDOW_CAPACITY,
        refit_every: Int = DEFAULT_REFIT_EVERY,
        bound_sigmas: Float64 = DEFAULT_BOUND_SIGMAS,
        bound_min_prior: Int = BOUNDS_MIN_PRIOR,
        chart_reference: Int = CUSUM_MIN_REFERENCE,
    ) raises:
        if window_capacity < detector.min_points:
            # ⛔ A WINDOW SMALLER THAN THE ACTIVATION THRESHOLD IS A DETECTOR
            # THAT CAN NEVER ACTIVATE. It would sit in ACCUMULATING forever
            # while reporting a point count that never reaches its own minimum
            # — a progress bar wired to nothing. Refusing at construction puts
            # the error where the number was written.
            raise Error(
                String("komira_anomaly: window_capacity (")
                + String(window_capacity)
                + String(") is below min_points (")
                + String(detector.min_points)
                + String("), so the retained window could never reach the")
                + String(" activation threshold")
            )
        if refit_every < 0:
            raise Error(
                String("komira_anomaly: refit_every must be >= 0 (0 means")
                + String(" never refit automatically); got ")
                + String(refit_every)
            )
        self.detector = detector^
        self.window_capacity = window_capacity
        self.refit_every = refit_every
        self.bound_sigmas = bound_sigmas
        self.bound_min_prior = bound_min_prior
        self.chart_reference = chart_reference


struct OnlineSeriesDetector(Copyable, Movable, Deinitable):
    """One series' accumulated state, and the post-a-point entry point.

    Holds a `SeriesDetector` — the existing state machine — plus the running
    bounds and the bounded retained window. Nothing here re-implements a
    verdict.
    """

    var key: String
    var config: OnlineConfig
    var inner: SeriesDetector
    var bounds: RunningBounds
    var window: List[SeriesPoint]
    var observed: Int
    var rejected: Int
    var since_refit: Int
    var last_ordinal: Int64
    var has_last_ordinal: Bool
    var last: Verdict

    def __init__(out self, key: String, config: OnlineConfig) raises:
        self.key = key
        self.config = config.copy()
        self.inner = SeriesDetector(key, config.detector)
        self.bounds = RunningBounds(
            config.bound_sigmas,
            config.bound_min_prior,
            config.chart_reference,
            config.detector.cusum_slack_sigmas,
            config.detector.cusum_threshold_sigmas,
        )
        self.window = []
        self.observed = 0
        self.rejected = 0
        self.since_refit = 0
        self.last_ordinal = Int64(0)
        self.has_last_ordinal = False
        self.last = Verdict(
            STATE_ACCUMULATING,
            key,
            0,
            config.detector.min_points,
            String(""),
        )

    def _window_series(self) -> Series:
        var s = Series(self.key)
        for i in range(len(self.window)):
            s.points.append(self.window[i].copy())
        return s^

    def observe(mut self, ordinal: Int64, value: Float64) raises -> Verdict:
        """Judge one posted point against everything accumulated, then keep it.

        ⛔ A REJECTED POINT MUTATES NOTHING. A non-finite value or an ordinal
        that does not advance is refused BEFORE the bounds are updated, because
        folding a `nan` into Welford poisons the mean and the variance
        permanently — every subsequent comparison against the bound is then
        false, and the detector has silently stopped detecting with no state
        that says so. The verdict is UNCALIBRATED and the accumulation is
        exactly what it was.
        """
        if not isfinite(value):
            self.rejected += 1
            self.last = Verdict(
                STATE_UNCALIBRATED,
                self.key,
                len(self.window),
                self.config.detector.min_points,
                series_reject_reason_name(SERIES_REJECT_NONFINITE),
            )
            return self.last.copy()
        if self.has_last_ordinal and ordinal <= self.last_ordinal:
            # Same refusal, same reason, as `Series.validate` — two points at
            # one position on the X axis are either a pooled key or a double
            # ingest, and neither is repairable by guessing an order.
            self.rejected += 1
            self.last = Verdict(
                STATE_UNCALIBRATED,
                self.key,
                len(self.window),
                self.config.detector.min_points,
                series_reject_reason_name(SERIES_REJECT_UNORDERED),
            )
            return self.last.copy()

        # ── the O(1) arms, on the state that PRECEDES this point ───────────
        var bound = self.bounds.observe(value)

        # ── the bounded retained window ────────────────────────────────────
        self.window.append(SeriesPoint(ordinal, value))
        while len(self.window) > self.config.window_capacity:
            _ = self.window.pop(0)
        self.last_ordinal = ordinal
        self.has_last_ordinal = True
        self.observed += 1
        self.since_refit += 1

        var do_refit = False
        if self.config.refit_every > 0:
            if self.since_refit >= self.config.refit_every:
                do_refit = True
        if do_refit:
            self.since_refit = 0

        self.last = self.inner.evaluate_with(
            self._window_series(), do_refit, bound
        )
        return self.last.copy()

    def refit(mut self) raises -> Verdict:
        """Run the change-point arm NOW over the retained window, off cadence.

        The escape hatch for a caller that has just been told something looks
        wrong and wants the expensive arm's opinion immediately. Resets the
        cadence counter, so an explicit refit is not immediately followed by an
        automatic one.
        """
        self.since_refit = 0
        self.last = self.inner.evaluate_with(
            self._window_series(), True, BoundSignal()
        )
        return self.last.copy()

    def acknowledge(mut self) raises:
        """The change is real and is the new normal.

        ⭐ THE RUNNING BOUNDS ARE RESET TOO, AND THAT IS THE WHOLE POINT OF
        ACKNOWLEDGING. Bounds accumulated across a level change describe a
        bimodal history that no longer exists; keeping them would leave the
        series with a mean between its old level and its new one and a variance
        inflated by the step, so the arm would be deaf on the new regime for as
        long as the old points dominate. Acknowledging says the old regime is
        over, and the accumulation has to agree.
        """
        self.inner.acknowledge()
        self.bounds.reset()
        var keep = List[SeriesPoint]()
        for i in range(len(self.window)):
            if self.window[i].ordinal >= self.inner.baseline_ordinal:
                keep.append(self.window[i].copy())
        self.window = keep^
        for i in range(len(self.window)):
            _ = self.bounds.observe(self.window[i].value)
        self.since_refit = 0
        self.last = self.inner.last.copy()

    def dismiss(mut self) raises:
        """The change is not real. Bounds and window are UNCHANGED — dismissing
        says the data is fine, so the accumulation over it is fine too."""
        self.inner.dismiss()
        self.last = self.inner.last.copy()

    def reset(mut self) raises:
        """Back to a detector that has seen nothing at all."""
        self.inner.reset()
        self.bounds.reset()
        self.window = []
        self.observed = 0
        self.rejected = 0
        self.since_refit = 0
        self.has_last_ordinal = False
        self.last = self.inner.last.copy()


struct AnomalyMonitor(Movable, Deinitable):
    """MANY SERIES, ONE OBJECT. The post-a-point façade.

    A key it has not seen is not an error — it is a new series, and creating it
    on first sight is what lets a caller post points without first declaring
    what it is going to post.
    """

    var config: OnlineConfig
    var _index: Dict[String, Int]
    var _dets: List[OnlineSeriesDetector]

    def __init__(out self) raises:
        """Default config. Its own overload for the same reason `OnlineConfig`
        has one — a raising call cannot be a default argument."""
        self = AnomalyMonitor(OnlineConfig())

    def __init__(out self, var config: OnlineConfig):
        self.config = config^
        self._index = Dict[String, Int]()
        self._dets = []

    def series_count(self) -> Int:
        return len(self._dets)

    def _slot(mut self, key: String) raises -> Int:
        if key in self._index:
            return self._index[key]
        if key.byte_length() == 0:
            raise Error(
                String("komira_anomaly: observe() with an empty series key —")
                + String(" a key that addresses nothing cannot carry a latch")
            )
        var at = len(self._dets)
        self._index[key] = at
        self._dets.append(OnlineSeriesDetector(key, self.config))
        return at

    def observe(
        mut self, key: String, ordinal: Int64, value: Float64
    ) raises -> Verdict:
        """POST A POINT, GET A VERDICT. The whole API.

        State for `key` is created on first sight and persists across calls.
        """
        var at = self._slot(key)
        return self._dets[at].observe(ordinal, value)

    def observe_and_store[
        S: MeasurementStore
    ](
        mut self, mut store: S, key: String, ordinal: Int64, value: Float64
    ) raises -> Verdict:
        """Record the point, THEN judge it. The ordering is the contract.

        ⛔ IF THE STORE RAISES, NOTHING IS JUDGED AND NO STATE MOVES. A point
        that reached the detector but not the record would make the live
        accumulation unreproducible from the stored data forever — and 'why did
        this fire' becomes unanswerable at exactly the moment someone asks.
        The exception propagates unchanged; there is no swallow and no partial.
        """
        store.append_point(key, ordinal, value)
        return self.observe(key, ordinal, value)

    def verdict_for(mut self, key: String) raises -> Verdict:
        """The last verdict for `key`, without posting anything.

        RAISES for a key never seen: returning a default ACCUMULATING verdict
        would be indistinguishable from a series that really is accumulating,
        and a typo in a key would then read as a young series forever.
        """
        if key not in self._index:
            raise Error(
                String("komira_anomaly: no series '")
                + key
                + String("' has been observed by this monitor")
            )
        return self._dets[self._index[key]].last.copy()

    def _slot_of(mut self, key: String) raises -> Int:
        """The slot for a key that MUST already exist.

        ⛔ SEPARATE FROM `_slot`, WHICH CREATES. Acknowledging, dismissing or
        refitting a key that was never observed is a typo, and creating an empty
        series for it would make the typo permanent and silent — the operator
        would acknowledge nothing and be told it worked.
        """
        if key not in self._index:
            raise Error(
                String("komira_anomaly: no series '")
                + key
                + String("' has been observed by this monitor")
            )
        return self._index[key]

    def acknowledge(mut self, key: String) raises:
        """This series' change is real and is the new normal."""
        var at = self._slot_of(key)
        self._dets[at].acknowledge()

    def dismiss(mut self, key: String) raises:
        """This series' change is not real."""
        var at = self._slot_of(key)
        self._dets[at].dismiss()

    def refit(mut self, key: String) raises -> Verdict:
        """Run the change-point arm on this series NOW, off cadence."""
        var at = self._slot_of(key)
        return self._dets[at].refit()

    def reset_series(mut self, key: String) raises:
        """Back to a series that has been seen but holds nothing."""
        var at = self._slot_of(key)
        self._dets[at].reset()

    def observed_count(mut self, key: String) raises -> Int:
        """How many points this series has ACCEPTED. Rejected points are not
        counted here — read `rejected_count` for those, because a series that
        is refusing everything it is posted must not look idle."""
        var at = self._slot_of(key)
        return self._dets[at].observed

    def rejected_count(mut self, key: String) raises -> Int:
        var at = self._slot_of(key)
        return self._dets[at].rejected

    def bounds_of(mut self, key: String) raises -> BoundSignal:
        """The bound this series WOULD apply to a point posted right now.

        Reports the accumulation without disturbing it: the returned signal is
        never `breached` (no point was judged) and its `lower`/`upper` are the
        current limits in the series' own units.
        """
        var at = self._slot_of(key)
        var sig = BoundSignal()
        sig.n_prior = self._dets[at].bounds.stats.count
        sig.mean_prior = self._dets[at].bounds.stats.mean
        sig.sigma_prior = self._dets[at].bounds.stats.stddev()
        sig.limit_sigmas = self._dets[at].bounds.limit_sigmas
        sig.armed = (
            sig.n_prior >= self._dets[at].bounds.min_prior
            and sig.sigma_prior > 0.0
        )
        return sig^


def rehydrate[
    S: MeasurementStore
](mut store: S, mut monitor: AnomalyMonitor) raises -> Int:
    """Rebuild a monitor's state by replaying everything the store holds.

    ★ THIS IS THE RESTART PATH, AND IT IS THE REASON THE SEAM HAS A WRITE HALF.
    Running bounds are accumulated state that lives in memory; after a restart
    the ONLY way to get them back is to replay the durable record through the
    identical code path that built them the first time — which is exactly what
    this does, point by point through `observe`.

    Returns the number of points replayed. ⚠ READ IT. A store with retention
    legitimately returns fewer points than were appended, and bounds rebuilt
    from a truncated replay are bounds over a shorter history. A caller that
    ignores the count cannot tell a full rehydration from a partial one.
    """
    var replayed = 0
    var count = store.series_count()
    for i in range(count):
        var key = store.series_key_at(i)
        var series = store.load_series(key)
        for j in range(series.count()):
            _ = monitor.observe(
                key, series.points[j].ordinal, series.points[j].value
            )
            replayed += 1
    return replayed
