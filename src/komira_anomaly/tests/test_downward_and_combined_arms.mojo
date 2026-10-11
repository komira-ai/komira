# =============================================================================
# tests/test_downward_and_combined_arms.mojo
#   The mirror-image and composite cases of the arms:
#     * the running bound breaching DOWNWARD (direction -1, negative z);
#     * the incremental chart signalling DOWNWARD, at the index of the point
#       that crossed;
#     * more than one arm firing on one evaluation: the detail names every
#       arm that fired, in order, joined by '+', never only the last one;
#     * an armed bound earning the "ran" word, read from the arm;
#     * a sweep counting an UNCALIBRATED series in its own bucket.
#
#   Every series is a fixed sawtooth (deviations 2,1,0,1,2 around 100), so
#   each number asserted below is exact.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_anomaly import (
    BOUNDS_DECLINED_NONE,
    BOUNDS_DECLINED_TOO_FEW_PRIOR,
    BoundSignal,
    DEFAULT_BOUND_SIGMAS,
    DetectorConfig,
    InMemoryPointStore,
    RunningBounds,
    STATE_ANOMALY,
    Series,
    SeriesDetector,
    evaluate_source,
)


def _contains(haystack: String, needle: String) -> Bool:
    var h = haystack.as_bytes()
    var n = needle.as_bytes()
    if len(n) == 0 or len(n) > len(h):
        return len(n) == 0
    for i in range(len(h) - len(n) + 1):
        var hit = True
        for j in range(len(n)):
            if h[i + j] != n[j]:
                hit = False
                break
        if hit:
            return True
    return False


def _saw(i: Int) -> Float64:
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    return 100.0 + pattern[i % 5]


def _warmed_bounds(n: Int) raises -> RunningBounds:
    """Default bounds after `n` sawtooth points."""
    var b = RunningBounds()
    for i in range(n):
        _ = b.observe(_saw(i))
    return b^


def _stepped(key: String, before: Int, after: Int, factor: Float64) -> Series:
    var s = Series(key)
    for i in range(before):
        s.append(Int64(i), _saw(i))
    for i in range(after):
        s.append(Int64(before + i), _saw(i) * factor)
    return s^


def test_bound_breaches_downward_with_negative_direction() raises:
    var b = _warmed_bounds(20)
    var sig = b.observe(50.0)
    assert_true(sig.armed, "20 prior points arm the default bound")
    assert_true(
        sig.z < -DEFAULT_BOUND_SIGMAS,
        String("a drop of ~50 sigma is far below the limit; z=") + String(sig.z),
    )
    assert_true(sig.breached, "a point below the lower bound breaches")
    assert_equal(sig.direction, -1, "and the breach points DOWN")
    assert_true(50.0 < sig.lower(), "the point is below the reported bound")


def test_bound_inside_the_limit_on_the_low_side_is_not_breached() raises:
    """The other side of the same comparison: a low point within the limit."""
    var b = _warmed_bounds(20)
    var sig = b.observe(99.0)
    assert_true(sig.armed, "armed")
    assert_true(sig.z < 0.0, "below the mean")
    assert_false(sig.breached, "but inside the limit")
    assert_equal(sig.direction, 0, "so no direction")


def test_incremental_chart_signals_downward_at_the_crossing_point() raises:
    var b = _warmed_bounds(20)
    assert_true(b.frozen, "the 20-point reference is frozen")
    assert_false(b.chart_signalled, "nothing yet")
    _ = b.observe(50.0)
    assert_true(b.chart_signalled, "a 50-unit drop crosses h at once")
    assert_equal(b.chart_direction, -1, "and the chart says DOWN")
    assert_equal(
        b.chart_signal_index, 20, "at the 0-based index of the dropped point"
    )
    assert_equal(b.c_hi, Float64(0.0), "the upper sum stays clamped at 0")
    # Later points must not move the retained first crossing.
    _ = b.observe(40.0)
    assert_equal(b.chart_signal_index, 20, "the FIRST crossing is retained")
    assert_equal(b.chart_direction, -1, "and its direction")


def test_every_fired_arm_is_named_in_order() raises:
    """Change point, bounds and chart all fire on one evaluation; the detail
    must name all three. A detail naming only the last arm would hide that
    the strongest evidence (the change point) fired at all."""
    var config = DetectorConfig(cusum_arms_verdict=True)
    var det = SeriesDetector(String("k"), config)
    var bound = BoundSignal()
    bound.armed = True
    bound.breached = True
    bound.direction = 1
    bound.declined = BOUNDS_DECLINED_NONE
    var v = det.evaluate_with(_stepped(String("k"), 30, 20, 1.5), True, bound)
    assert_equal(v.state, STATE_ANOMALY, "three arms fired")
    assert_true(v.changepoint_fired, "the change point fired")
    assert_true(v.cusum_signalled, "the chart signalled")
    assert_equal(v.arms_ruled, 3, "and all three ruled")
    assert_equal(v.detail, String("arm=changepoint+bounds+cusum"))


def test_changepoint_and_chart_without_the_bound() raises:
    """The batch path: no bound, so the chart's name follows the change
    point's directly, and the unarmed bound says why it did not rule."""
    var config = DetectorConfig(cusum_arms_verdict=True)
    var det = SeriesDetector(String("k"), config)
    var v = det.evaluate(_stepped(String("k"), 30, 20, 1.5))
    assert_equal(v.state, STATE_ANOMALY, "two arms fired")
    assert_equal(
        v.detail,
        String("arm=changepoint+cusum bounds_declined=too_few_prior_points"),
    )


def test_an_armed_bound_reports_the_ran_decline() raises:
    """`_bounds_decline_of` reads the reason from the arm; an arm that ruled
    has no decline, whatever it carries."""
    var det = SeriesDetector(String("k"), DetectorConfig())
    var b = _warmed_bounds(20)
    var armed = b.observe(101.0)
    assert_true(armed.armed, "a real armed signal")
    assert_equal(det._bounds_decline_of(armed), BOUNDS_DECLINED_NONE)
    var unarmed = BoundSignal()
    assert_equal(
        det._bounds_decline_of(unarmed),
        BOUNDS_DECLINED_TOO_FEW_PRIOR,
        "an unarmed signal's own reason is passed through",
    )


def test_sweep_counts_an_uncalibrated_series_in_its_own_bucket() raises:
    """A stored NaN makes its series UNCALIBRATED; the census must count it
    there, not in NORMAL and not nowhere."""
    var store = InMemoryPointStore()
    for i in range(12):
        store.append_point(String("good"), Int64(i), _saw(i))
    store.append_point(String("bad"), Int64(0), Float64(1.0))
    store.append_point(String("bad"), Int64(1), Float64(0.0) / Float64(0.0))
    var report = evaluate_source(store, DetectorConfig())
    assert_equal(report.total, 2, "both series evaluated")
    assert_equal(report.uncalibrated, 1, "the NaN series is UNCALIBRATED")
    assert_equal(report.normal, 1, "the stable series is NORMAL")
    assert_equal(report.load_failures, 0, "nothing failed to load")
    assert_true(
        _contains(report.render(), String("uncalibrated=1")),
        String("the bucket is in the census line; got ") + report.render(),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
