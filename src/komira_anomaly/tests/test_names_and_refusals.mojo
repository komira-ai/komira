# =============================================================================
# tests/test_names_and_refusals.mojo
#   The words a verdict is rendered with, the constructor refusals, and the
#   empty-input answers of the small numeric helpers.
#
#   Each test pins one contract a docstring states:
#     * every decline / reject ordinal renders as its own word, and an ordinal
#       outside the vocabulary renders as an explicit "unknown" word rather
#       than as one of the real ones;
#     * `DetectorConfig`, `OnlineConfig` and `RunningBounds` refuse the
#       parameters their docstrings call impossible, and accept the boundary
#       value on the other side;
#     * `estimate_scale([])`, `_mean_of` on an empty range and
#       `relative_shift` with a zero "before" mean answer 0.0 rather than a
#       NaN or an infinity;
#     * `InMemoryPointStore.series_key_at` refuses an index outside 0..count.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_anomaly import (
    BOUNDS_DECLINED_NONE,
    BOUNDS_DECLINED_TOO_FEW_PRIOR,
    BOUNDS_DECLINED_ZERO_SCALE,
    BOUNDS_MIN_PRIOR,
    CUSUM_DECLINED_NONE,
    CUSUM_DECLINED_NO_POINTS_AFTER_REFERENCE,
    CUSUM_DECLINED_REFERENCE_TOO_SHORT,
    CUSUM_DECLINED_ZERO_SCALE,
    CUSUM_MIN_REFERENCE,
    ChangePointFit,
    DEFAULT_BOUND_SIGMAS,
    DetectorConfig,
    InMemoryPointStore,
    OnlineConfig,
    RunningBounds,
    SERIES_OK,
    SERIES_REJECT_EMPTY_KEY,
    SERIES_REJECT_NONFINITE,
    SERIES_REJECT_UNORDERED,
    bounds_decline_name,
    cusum_decline_name,
    estimate_scale,
    fit_change_point,
    seed_for_key,
    series_reject_reason_name,
)
from komira_anomaly.edivisive import _mean_of


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


def _detector_config_error(slack: Float64, threshold: Float64) -> String:
    """The refusal message, or "" when the config was accepted."""
    try:
        var _c = DetectorConfig(
            cusum_slack_sigmas=slack, cusum_threshold_sigmas=threshold
        )
    except e:
        return String(e)
    return String("")


def _bounds_error(limit: Float64, min_prior: Int) -> String:
    try:
        var _b = RunningBounds(limit, min_prior, CUSUM_MIN_REFERENCE)
    except e:
        return String(e)
    return String("")


# ── the vocabulary ─────────────────────────────────────────────────────────


def test_bounds_decline_names_every_ordinal() raises:
    assert_equal(String(bounds_decline_name(BOUNDS_DECLINED_NONE)), "ran")
    assert_equal(
        String(bounds_decline_name(BOUNDS_DECLINED_TOO_FEW_PRIOR)),
        "too_few_prior_points",
    )
    assert_equal(
        String(bounds_decline_name(BOUNDS_DECLINED_ZERO_SCALE)), "zero_scale"
    )
    assert_equal(
        String(bounds_decline_name(99)),
        "unknown",
        "an ordinal outside the vocabulary must not borrow a real word",
    )


def test_cusum_decline_names_every_ordinal() raises:
    assert_equal(String(cusum_decline_name(CUSUM_DECLINED_NONE)), "ran")
    assert_equal(
        String(cusum_decline_name(CUSUM_DECLINED_REFERENCE_TOO_SHORT)),
        "reference_shorter_than_20",
    )
    assert_equal(
        String(cusum_decline_name(CUSUM_DECLINED_NO_POINTS_AFTER_REFERENCE)),
        "no_points_after_reference",
    )
    assert_equal(
        String(cusum_decline_name(CUSUM_DECLINED_ZERO_SCALE)), "zero_scale"
    )
    assert_equal(
        String(cusum_decline_name(-1)),
        "unknown",
        "an ordinal outside the vocabulary must not borrow a real word",
    )
    # The word names the floor; the floor is a constant, not a parameter.
    assert_equal(CUSUM_MIN_REFERENCE, 20, "the word and the floor agree")


def test_series_reject_names_every_ordinal() raises:
    assert_equal(String(series_reject_reason_name(SERIES_OK)), "OK")
    assert_equal(
        String(series_reject_reason_name(SERIES_REJECT_NONFINITE)),
        "NONFINITE_VALUE",
    )
    assert_equal(
        String(series_reject_reason_name(SERIES_REJECT_UNORDERED)),
        "ORDINALS_NOT_STRICTLY_INCREASING",
    )
    assert_equal(
        String(series_reject_reason_name(SERIES_REJECT_EMPTY_KEY)),
        "EMPTY_SERIES_KEY",
    )
    assert_equal(
        String(series_reject_reason_name(42)),
        "UNKNOWN_REJECT_REASON",
        "an ordinal outside the vocabulary must not borrow a real word",
    )


# ── constructor refusals, both sides of each boundary ──────────────────────


def test_detector_config_refuses_a_negative_slack_or_nonpositive_threshold() raises:
    var neg_slack = _detector_config_error(Float64(-0.5), Float64(5.0))
    assert_true(
        _contains(neg_slack, String("cusum slack must be >= 0")),
        String("a negative slack must be refused; got '") + neg_slack + "'",
    )
    var zero_threshold = _detector_config_error(Float64(0.5), Float64(0.0))
    assert_true(
        _contains(zero_threshold, String("threshold > 0")),
        String("a zero threshold must be refused; got '")
        + zero_threshold
        + "'",
    )
    var neg_threshold = _detector_config_error(Float64(0.5), Float64(-1.0))
    assert_true(
        neg_threshold.byte_length() > 0, "a negative threshold must be refused"
    )
    var ok = _detector_config_error(Float64(0.0), Float64(1e-9))
    assert_equal(
        ok,
        String(""),
        "slack exactly 0 and any positive threshold are accepted",
    )


def test_online_config_refuses_a_negative_refit_cadence() raises:
    var msg = String("")
    try:
        var _c = OnlineConfig(DetectorConfig(), refit_every=-1)
    except e:
        msg = String(e)
    assert_true(
        _contains(msg, String("refit_every must be >= 0"))
        and _contains(msg, String("got -1")),
        String("refit_every=-1 must be refused, naming the value; got '")
        + msg
        + "'",
    )
    var ok = True
    try:
        var _c = OnlineConfig(DetectorConfig(), refit_every=0)
    except e:
        ok = False
    assert_true(ok, "refit_every=0 (never refit automatically) is accepted")


def test_running_bounds_refuses_a_nonpositive_limit() raises:
    var zero = _bounds_error(Float64(0.0), BOUNDS_MIN_PRIOR)
    assert_true(
        _contains(zero, String("bound limit must be > 0; got 0")),
        String("limit 0 must be refused; got '") + zero + "'",
    )
    var neg = _bounds_error(Float64(-1.0), BOUNDS_MIN_PRIOR)
    assert_true(
        _contains(neg, String("bound limit must be > 0")),
        String("a negative limit must be refused; got '") + neg + "'",
    )
    assert_equal(
        _bounds_error(Float64(1e-9), BOUNDS_MIN_PRIOR),
        String(""),
        "any positive limit is accepted",
    )


def test_running_bounds_refuses_fewer_than_two_prior_points() raises:
    var one = _bounds_error(DEFAULT_BOUND_SIGMAS, 1)
    assert_true(
        _contains(one, String("at least 2 prior points"))
        and _contains(one, String("got 1")),
        String("min_prior 1 has no scale and must be refused; got '")
        + one
        + "'",
    )
    assert_equal(
        _bounds_error(DEFAULT_BOUND_SIGMAS, 2),
        String(""),
        "min_prior exactly 2 is accepted",
    )


# ── the empty-input answers ─────────────────────────────────────────────────


def test_estimate_scale_of_nothing_is_zero() raises:
    var empty = List[Float64]()
    assert_equal(
        estimate_scale(empty),
        Float64(0.0),
        "an empty sample has no scale: 0.0, the refusal value, not a crash",
    )


def test_mean_of_an_empty_range_is_zero_not_nan() raises:
    var v: List[Float64] = [1.0, 2.0, 3.0, 4.0]
    assert_equal(_mean_of(v, 2, 2), Float64(0.0), "hi == lo: 0.0, not 0/0")
    assert_equal(_mean_of(v, 3, 1), Float64(0.0), "hi < lo: 0.0")
    assert_equal(_mean_of(v, 1, 3), Float64(2.5), "a real range is its mean")


def test_relative_shift_from_a_zero_before_mean_is_zero() raises:
    """A shift relative to 0 is undefined; the docstring says 0.0, which is
    what a reader can tell apart from a real percentage only by the means the
    verdict also carries. Infinity would poison every aggregate it entered."""
    var f = ChangePointFit(
        5, Float64(1.0), Float64(0.01), 99, Float64(0.0), Float64(3.0)
    )
    assert_true(f.is_fitted(), "a fitted change point")
    assert_equal(f.relative_shift(), Float64(0.0), "before == 0: 0.0")

    # And through the fit itself: zeros, then ones.
    var v: List[Float64] = [
        0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 1.0
    ]
    var g = fit_change_point(v, 3, 99, seed_for_key(String("zero-before")))
    assert_equal(g.index, 5, "boundary at 5")
    assert_equal(g.before_mean, Float64(0.0), "before mean is exactly 0")
    assert_equal(g.after_mean, Float64(1.0), "after mean is exactly 1")
    assert_equal(g.relative_shift(), Float64(0.0), "and the shift is 0.0")


# ── the store seam's index refusal ─────────────────────────────────────────


def test_store_series_key_at_refuses_an_index_outside_the_range() raises:
    var store = InMemoryPointStore()
    store.append_point(String("a"), Int64(1), Float64(1.0))
    store.append_point(String("b"), Int64(1), Float64(2.0))
    assert_equal(store.series_key_at(1), String("b"), "the last index is fine")

    var past = String("")
    try:
        _ = store.series_key_at(2)
    except e:
        past = String(e)
    assert_true(
        _contains(past, String("series index 2 out of range 0..2")),
        String("index == count must be refused; got '") + past + "'",
    )
    var neg = String("")
    try:
        _ = store.series_key_at(-1)
    except e:
        neg = String(e)
    assert_true(
        _contains(neg, String("series index -1 out of range")),
        String("a negative index must be refused; got '") + neg + "'",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
