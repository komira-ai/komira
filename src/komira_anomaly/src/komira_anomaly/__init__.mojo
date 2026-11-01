"""`komira_anomaly` — REGRESSION DETECTION OVER AN ABSTRACT SERIES.

★ WHAT THIS PACKAGE IS. The detector that decides whether a measured series
has changed. It needs no storage, no metrics system and no service — only a
sequence of ordered numbers — so it can be built, tested and validated on its
own, before any producer of the data exists.

★ WHAT IT DELIBERATELY IS NOT, AND WHY THAT IS THE POINT. It does not define a
measurement data model, a storage format, a table, a bucket or a query engine.
A detector that named any of them would have to be redesigned when they
change. Everything here is stated over `Int64`, `Float64` and an opaque
`String` key — see `series.mojo`'s `SeriesSource`, which is the entire
contract with whatever produces the data.

⛔ THERE IS NO SERVICE HERE, ON PURPOSE. The library and its falsifiers are the
whole package; the job that runs it belongs with the data it reads.

── WHAT IS IN IT ────────────────────────────────────────────────────────────

  * `series`    — `SeriesPoint` / `Series`, and the `SeriesSource` SEAM.
                  Validation refuses non-finite values and non-strictly-
                  increasing ordinals rather than repairing them.
  * `edivisive` — the PRIMARY detector. Distribution-free change point
                  detection by energy statistic with a permutation test,
                  seeded so a verdict is a pure function of (data, seed).
  * `cusum`     — the SECONDARY detector. Tabular CUSUM on a robust
                  (median/MAD) scale, for drift that has no step in it.
  * `sweep`     — `evaluate_source`, generic over the seam: what drives the
                  detector across every series a producer holds.
  * `detector`  — the STATE MACHINE: ACCUMULATING / NORMAL / ANOMALY, plus
                  UNCALIBRATED for an input it cannot compute on. An ANOMALY
                  latches until acknowledged or dismissed.
  * `bounds`    — THE RUNNING BOUNDS. Welford mean/variance over the whole
                  history plus an incremental chart from a BOUNDED Phase-I
                  prefix, both O(1) per point. A new point is judged against
                  the state that PRECEDES it, then folded in.
  * `online`    — ⭐ POST A POINT, GET A VERDICT. `AnomalyMonitor.observe(key,
                  ordinal, value)`; the caller holds no history. Every verdict
                  comes from `SeriesDetector.evaluate_with`, the same state
                  machine the batch path uses.
  * `store`     — THE STORE SEAM. `MeasurementStore` is a `SeriesSource` that
                  also accepts points, so a written series replays through the
                  read path with no adapter, and `rehydrate` rebuilds a
                  monitor's bounds after a restart.

── ⭐ THE SHAPE ──────────────────────────────────────────────────────────────

    var monitor = AnomalyMonitor()
    var verdict = monitor.observe_and_store(store, key, ordinal, value)
    if verdict.state == STATE_ANOMALY:
        ...

Post a point and get whether it is an anomaly, with the store underneath and
running bounds that judge the new point against the existing data. Nothing
re-reads a window; the O(1) arms rule on every point and the O(n^2)
change-point arm runs on a stated cadence that the verdict names when it did
not run.

⛔ AND WHAT `observe` DELIBERATELY DOES NOT PROMISE. The running-bounds arm is a
POINT test. Measured on real known-zero data, a SUSTAINED +10% step is caught on
2 of 6 series, because the arm folds each new point into the very scale that
judges the next one. Sustained shifts belong to the change-point arm. A caller
reading a green bounds verdict as "this series has not regressed" has read a
point test as a trend test — `tests/test_real_launch_series.mojo` asserts that
limit rather than leaving it to be discovered.

── THE MEASURED CASE FOR IT ─────────────────────────────────────────────────

Ten recorded benchmark sweeps of ONE binary with no code change between them
are a strong known-zero: every firing on that data is by construction a false
one. Measured over its 82 scored cells:

    this detector, alpha = 0.0122        0 firings
    1.10x vs a fixed baseline           10 firings across 7 distinct cells
    1.10x vs the previous sweep         12 firings across 10 distinct cells

The second and third rows are the two fixed-ratio rules this detector is
compared against. And the zero is not achieved by being deaf — on the same
series, with five post-change points, a real 10% shift is detected on 74 of 82
cells (90.2%) and a 20% shift on 82 of 82 (100%).

`tests/test_known_zero_corpus.mojo` asserts EVERY number on this page by
equality — 0, 0, 2, 74, 82, 82, 10/7 and 12/10 — so none of them can be a claim
this file merely repeats. A budget such as `hit10 >= 65` against a measured 74
would let a large regression stay green, which is why none is used.

⛔ AND A NUMBER THIS PAGE DOES NOT CARRY. The detector's SECONDARY arm is inert
on a 10-point series (`CUSUM_MIN_REFERENCE = 20`). On six real
order-preserving known-zero series (320 points of ONE binary relaunched) the
arm fires on THREE OF SIX of them. It is therefore ADVISORY by default —
reported, never verdict-setting — and `tests/test_real_launch_series.mojo`
re-derives the 3-of-6.

── STORAGE ──────────────────────────────────────────────────────────────────

Whatever stores the measurements (an object store laid out for time-series
queries, a table, a file), nothing in THIS package is affected: no module here
names a storage format at all.
"""

from komira_anomaly.bounds import (
    BOUNDS_DECLINED_NONE,
    BOUNDS_DECLINED_TOO_FEW_PRIOR,
    BOUNDS_DECLINED_ZERO_SCALE,
    BOUNDS_MIN_PRIOR,
    BoundSignal,
    DEFAULT_BOUND_SIGMAS,
    RunningBounds,
    RunningStats,
    bounds_decline_name,
)
from komira_anomaly.cusum import (
    CUSUM_DECLINED_NONE,
    CUSUM_DECLINED_NO_POINTS_AFTER_REFERENCE,
    CUSUM_DECLINED_REFERENCE_TOO_SHORT,
    CUSUM_DECLINED_ZERO_SCALE,
    CUSUM_MIN_REFERENCE,
    CusumResult,
    DEFAULT_SLACK_SIGMAS,
    DEFAULT_THRESHOLD_SIGMAS,
    MAD_TO_SIGMA,
    cusum_decline_name,
    estimate_scale,
    median_of,
    run_cusum,
)
from komira_anomaly.detector import (
    DEFAULT_CUSUM_ARMS_VERDICT,
    DEFAULT_MIN_POINTS,
    DEFAULT_SIGNIFICANCE,
    NO_ARM_RULED,
    DetectorConfig,
    STATE_ACCUMULATING,
    STATE_ANOMALY,
    STATE_NORMAL,
    STATE_UNCALIBRATED,
    SeriesDetector,
    Verdict,
    state_name,
)
from komira_anomaly.edivisive import (
    ChangePointFit,
    DEFAULT_MIN_SEGMENT,
    DEFAULT_PERMUTATIONS,
    MIN_SEGMENT_FLOOR,
    Split,
    SplitMix64,
    best_split,
    fit_change_point,
    seed_for_key,
)
from komira_anomaly.online import (
    AnomalyMonitor,
    DEFAULT_REFIT_EVERY,
    DEFAULT_WINDOW_CAPACITY,
    OnlineConfig,
    OnlineSeriesDetector,
    rehydrate,
)
from komira_anomaly.store import InMemoryPointStore, MeasurementStore
from komira_anomaly.sweep import SweepReport, evaluate_source
from komira_anomaly.series import (
    SERIES_OK,
    SERIES_REJECT_EMPTY_KEY,
    SERIES_REJECT_NONFINITE,
    SERIES_REJECT_UNORDERED,
    Series,
    SeriesPoint,
    SeriesSource,
    series_reject_reason_name,
)
