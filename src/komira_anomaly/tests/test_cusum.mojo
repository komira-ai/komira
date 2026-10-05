# =============================================================================
# tests/test_cusum.mojo
#   The SECONDARY detector: the robust scale estimate, the three refusals, and
#   the drift the primary is blind to.
#
#   ⚠ WHAT THIS FILE DOES AND DOES NOT ESTABLISH. It pins the chart's
#   MECHANISM on constructed input. It is NOT a false-alarm rate for the chart
#   on real data — that needs real series of ~25 points, which
#   `test_real_launch_series.mojo` measures. The one
#   real-data measurement about this arm is that a 10-point reference produced
#   13 false alarms across 82 known-zero cells, which is why
#   `CUSUM_MIN_REFERENCE` exists and why the fourth test below asserts the
#   guard is live rather than decorative.
#
#   Every series here is built from a fixed repeating pattern rather than a
#   sampled one, so each assertion is exactly reproducible.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_anomaly import (
    CUSUM_DECLINED_NONE,
    CUSUM_DECLINED_NO_POINTS_AFTER_REFERENCE,
    CUSUM_DECLINED_REFERENCE_TOO_SHORT,
    CUSUM_DECLINED_ZERO_SCALE,
    CUSUM_MIN_REFERENCE,
    DEFAULT_SLACK_SIGMAS,
    DEFAULT_THRESHOLD_SIGMAS,
    MAD_TO_SIGMA,
    estimate_scale,
    median_of,
    run_cusum,
)


def _reference(n: Int) -> List[Float64]:
    """`n` points around 100.0 with a fixed +/-2 sawtooth.

    Deviations from the median are 2,1,0,1,2 repeating, so the MAD is exactly
    1.0 and the estimated scale is exactly MAD_TO_SIGMA. Every threshold in
    this file is therefore an exact number rather than an approximation.
    """
    var out = List[Float64]()
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    for i in range(n):
        out.append(100.0 + pattern[i % 5])
    return out^


def test_median_handles_both_parities() raises:
    var odd: List[Float64] = [3.0, 1.0, 2.0]
    assert_equal(median_of(odd), Float64(2.0), "odd-length median")
    var even: List[Float64] = [4.0, 1.0, 3.0, 2.0]
    assert_equal(median_of(even), Float64(2.5), "even-length median averages")
    var empty = List[Float64]()
    assert_equal(median_of(empty), Float64(0.0), "empty is 0.0, not a crash")


def test_scale_is_mad_based_and_ignores_a_lone_outlier() raises:
    """⭐ THE PROPERTY THE WHOLE CHART DEPENDS ON.

    Both k and h scale with sigma, so a single inflated estimate makes the
    chart blind for the rest of the run. A standard deviation would move a long
    way on the outlier below; the MAD does not move at all.
    """
    var clean = _reference(20)
    var s_clean = estimate_scale(clean)
    assert_true(
        s_clean > MAD_TO_SIGMA - 1e-12 and s_clean < MAD_TO_SIGMA + 1e-12,
        String("the sawtooth's MAD is exactly 1.0, so the scale is exactly")
        + String(" MAD_TO_SIGMA; got ")
        + String(s_clean),
    )
    var dirty = clean.copy()
    dirty.append(100000.0)
    var s_dirty = estimate_scale(dirty)
    assert_true(
        s_dirty > MAD_TO_SIGMA - 1e-9 and s_dirty < MAD_TO_SIGMA * 1.6,
        String("one absurd outlier must barely move a MAD scale; got ")
        + String(s_dirty),
    )


def test_scale_declines_on_a_sample_with_no_dispersion() raises:
    """A zero return is a REFUSAL, not a measurement of zero spread."""
    var flat: List[Float64] = [7.0, 7.0, 7.0, 7.0, 7.0, 7.0]
    assert_equal(
        estimate_scale(flat), Float64(0.0), "identical points have no scale"
    )


def test_chart_refuses_a_reference_shorter_than_the_minimum() raises:
    """⭐ THE GUARD WHOSE NECESSITY WAS MEASURED, ASSERTED TO BE LIVE.

    A chart parameterised from 10 points false-alarmed on 13 of 82 real
    known-zero cells. This asserts the refusal actually fires at the boundary
    and stops firing one point above it — a constant that no code path consults
    is not a guard.
    """
    var short = _reference(CUSUM_MIN_REFERENCE - 1)
    for _i in range(6):
        short.append(100.0)
    var r = run_cusum(
        short,
        CUSUM_MIN_REFERENCE - 1,
        DEFAULT_SLACK_SIGMAS,
        DEFAULT_THRESHOLD_SIGMAS,
    )
    assert_equal(
        r.declined,
        CUSUM_DECLINED_REFERENCE_TOO_SHORT,
        "one point below the minimum, the chart must decline",
    )
    assert_false(r.signalled, "and it must signal nothing while declining")

    var ok = _reference(CUSUM_MIN_REFERENCE)
    for _i in range(6):
        ok.append(100.0)
    assert_equal(
        run_cusum(
            ok,
            CUSUM_MIN_REFERENCE,
            DEFAULT_SLACK_SIGMAS,
            DEFAULT_THRESHOLD_SIGMAS,
        ).declined,
        CUSUM_DECLINED_NONE,
        "at exactly the minimum the chart runs",
    )


def test_chart_declines_when_nothing_follows_the_reference() raises:
    var exact = _reference(CUSUM_MIN_REFERENCE)
    assert_equal(
        run_cusum(
            exact,
            CUSUM_MIN_REFERENCE,
            DEFAULT_SLACK_SIGMAS,
            DEFAULT_THRESHOLD_SIGMAS,
        ).declined,
        CUSUM_DECLINED_NO_POINTS_AFTER_REFERENCE,
        "a reference with no points after it has nothing to chart",
    )


def test_chart_declines_on_a_degenerate_scale_rather_than_dividing() raises:
    """Every point after an all-identical reference is infinitely many sigmas
    away. That is a chart with no scale, not a detection on every point."""
    var v = List[Float64]()
    for _i in range(CUSUM_MIN_REFERENCE):
        v.append(50.0)
    for _i in range(5):
        v.append(50.5)
    var r = run_cusum(
        v, CUSUM_MIN_REFERENCE, DEFAULT_SLACK_SIGMAS, DEFAULT_THRESHOLD_SIGMAS
    )
    assert_equal(
        r.declined, CUSUM_DECLINED_ZERO_SCALE, "no scale, so no chart"
    )
    assert_false(
        r.signalled,
        "and emphatically NOT a signal on a series that moved by 1%",
    )


def test_chart_catches_a_sustained_upward_drift() raises:
    """The shape the PRIMARY is blind to: no single step large enough to be a
    change point, but a level that has moved and stays moved."""
    var v = _reference(CUSUM_MIN_REFERENCE)
    for _i in range(8):
        v.append(103.0)
    var r = run_cusum(
        v, CUSUM_MIN_REFERENCE, DEFAULT_SLACK_SIGMAS, DEFAULT_THRESHOLD_SIGMAS
    )
    assert_true(r.ran(), "the chart must actually run here")
    assert_true(r.signalled, "a sustained +3 on a 1.48 scale must signal")
    assert_equal(r.direction, 1, "upward")
    assert_true(
        r.signal_index >= CUSUM_MIN_REFERENCE,
        "the signal can only come from a point after the reference",
    )


def test_chart_reports_direction_for_a_downward_drift() raises:
    """An improvement is still a change. The direction is what tells a reader
    which it was, and a detector that only reported 'changed' would file the
    same card for a 20% win and a 20% regression."""
    var v = _reference(CUSUM_MIN_REFERENCE)
    for _i in range(8):
        v.append(97.0)
    var r = run_cusum(
        v, CUSUM_MIN_REFERENCE, DEFAULT_SLACK_SIGMAS, DEFAULT_THRESHOLD_SIGMAS
    )
    assert_true(r.signalled, "a sustained -3 must signal")
    assert_equal(r.direction, -1, "downward")


def test_chart_stays_quiet_on_a_stable_series() raises:
    """The reference pattern continued. Nothing has changed, so nothing fires
    — including on the reference points themselves, which are excluded from the
    chart they parameterise."""
    var v = _reference(CUSUM_MIN_REFERENCE + 20)
    var r = run_cusum(
        v, CUSUM_MIN_REFERENCE, DEFAULT_SLACK_SIGMAS, DEFAULT_THRESHOLD_SIGMAS
    )
    assert_true(r.ran(), "it ran")
    assert_false(
        r.signalled,
        String("a continuing stable series must not signal; peaks were ")
        + String(r.peak_high)
        + String(" / ")
        + String(r.peak_low),
    )


def test_chart_retains_the_first_crossing_not_the_last() raises:
    """A card must cite where the evidence first became sufficient. The chart
    keeps accumulating after that so the peaks stay informative, but the index
    must not slide forward with it."""
    var v = _reference(CUSUM_MIN_REFERENCE)
    for _i in range(20):
        v.append(110.0)
    var r = run_cusum(
        v, CUSUM_MIN_REFERENCE, DEFAULT_SLACK_SIGMAS, DEFAULT_THRESHOLD_SIGMAS
    )
    assert_true(r.signalled, "an enormous sustained shift signals")
    assert_true(
        r.signal_index < CUSUM_MIN_REFERENCE + 4,
        String("a +10 shift on a 1.48 scale crosses 5 sigma within a couple")
        + String(" of points; got index ")
        + String(r.signal_index),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
