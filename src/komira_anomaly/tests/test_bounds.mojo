# =============================================================================
# tests/test_bounds.mojo
#   THE RUNNING BOUNDS: the accumulation that judges the next posted point.
#
#   Four properties, each of which a plausible implementation gets wrong:
#
#     1. WELFORD, NOT SUM/SUMSQ — proved by running BOTH over the same real
#        data and showing the naive one returns a NEGATIVE variance.
#     2. THE POINT IS JUDGED AGAINST THE STATE THAT PRECEDES IT — proved by an
#        input on which judging-after-update measurably does not fire.
#     3. THE PHASE-I PREFIX IS BOUNDED, EXACT, AND RELEASED — the incremental
#        chart must agree with the batch chart TO THE BIT, and the buffer must
#        be empty afterwards.
#     4. UNARMED IS NOT UNBREACHED — an arm that did not run must not be
#        readable as an arm that ran and found nothing.
# =============================================================================

from std.math import isfinite, sqrt

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_anomaly import (
    BOUNDS_DECLINED_NONE,
    BOUNDS_DECLINED_TOO_FEW_PRIOR,
    BOUNDS_DECLINED_ZERO_SCALE,
    BOUNDS_MIN_PRIOR,
    BoundSignal,
    CUSUM_DECLINED_NONE,
    CUSUM_DECLINED_ZERO_SCALE,
    CUSUM_MIN_REFERENCE,
    DEFAULT_BOUND_SIGMAS,
    RunningBounds,
    RunningStats,
    bounds_decline_name,
    estimate_scale,
    median_of,
    run_cusum,
)


def _duck_q04_launches() -> List[Float64]:
    """The first 40 of the 100 real `duck_q04_base` launches.

    Real recorded numbers, not synthetic ones — see
    `tests/test_real_launch_series.mojo` for the provenance. Used here because
    the naive variance's failure has to be shown on data somebody actually
    measured, not on numbers chosen to make it fail.
    """
    return [
        12.048, 11.7, 11.598, 11.626, 11.653, 11.791, 11.662, 11.596,
        11.732, 11.605, 11.764, 11.726, 11.628, 11.725, 11.647, 11.644,
        11.687, 11.782, 11.66, 11.798, 11.722, 11.639, 11.801, 11.608,
        11.782, 11.679, 11.501, 11.688, 11.941, 11.647, 11.592, 11.773,
        11.756, 11.75, 11.683, 11.745, 11.712, 11.619, 11.735, 11.851,
    ]


def _naive_variance(v: List[Float64]) -> Float64:
    """The estimator this module refuses: SUM(x) and SUM(x^2), then subtract.

    Written out HERE, in the test, so the comparison below is between two
    things that both exist rather than between one thing and a claim about
    another.
    """
    var n = 0
    var s = Float64(0.0)
    var ss = Float64(0.0)
    for i in range(len(v)):
        n += 1
        s += v[i]
        ss += v[i] * v[i]
    if n < 2:
        return Float64(0.0)
    return (ss - s * s / Float64(n)) / Float64(n - 1)


def test_welford_beats_the_naive_estimator_on_real_data_with_an_offset() raises:
    """⭐ 1. THE REASON THE RECURRENCE IS SPELLED THIS WAY.

    Same real series, same arithmetic, one constant added to every value. At
    offset 0 both estimators agree to eleven digits. At +1e9 the naive one
    returns a NEGATIVE variance and `sqrt` of it is `nan` — after which every
    comparison against a bound is FALSE and the detector has silently stopped
    detecting.

    ⚠ THE OFFSET IS NOT A CONTRIVANCE. A cumulative counter, a byte offset, an
    epoch-based gauge — anything carrying a large constant baseline — looks
    exactly like this, and the seam takes a bare `Float64` from a producer this
    package will never see.
    """
    var base = _duck_q04_launches()

    # ── control: with no offset the two agree, so the failure below is about
    # ── the OFFSET and not about one of them simply being broken. ──
    var w0 = RunningStats()
    for i in range(len(base)):
        w0.update(base[i])
    var n0 = _naive_variance(base)
    assert_true(
        n0 > 0.0,
        String("CONTROL: at offset 0 the naive estimator must still work, or")
        + String(" the comparison below shows nothing; got ")
        + String(n0),
    )
    var rel0 = (w0.variance() - n0) / w0.variance()
    if rel0 < 0.0:
        rel0 = -rel0
    assert_true(
        rel0 < 1e-6,
        String("CONTROL: at offset 0 both estimators must agree; welford=")
        + String(w0.variance())
        + String(" naive=")
        + String(n0),
    )

    # ── the measurement ──
    var shifted = List[Float64]()
    for i in range(len(base)):
        shifted.append(base[i] + 1.0e9)
    var w1 = RunningStats()
    for i in range(len(shifted)):
        w1.update(shifted[i])
    var n1 = _naive_variance(shifted)

    # ⛔ THE ASSERTION IS ON THE MAGNITUDE, NOT ON THE SIGN, AND THE REASON IS
    # ARITHMETIC. The true `m2` here is ~0.39 while `SUM(x^2)` is ~4e19, whose
    # ulp is 8192 — so the naive residual IS one ulp of the accumulator, and
    # its SIGN is decided by which way a single rounding went. Measured on this
    # fixture: a plain left-to-right loop (the shape of the .mojo code) gives
    # -8192, and `math.fsum` over the identical inputs gives +8192. Asserting
    # `n1 < 0.0` therefore carried a false-RED risk under ANY change to the
    # summation, for a property that was never the point. The point is that the
    # answer is wrong by four orders of magnitude, which is sign-free.
    var err1 = n1 - w1.variance()
    if err1 < 0.0:
        err1 = -err1
    assert_true(
        err1 > 1.0e3 * w1.variance(),
        String("the naive estimator's answer at +1e9 must be wrong by orders")
        + String(" of magnitude — that is the failure this module exists to")
        + String(" avoid, and if it does not happen this test is proving")
        + String(" nothing. naive=")
        + String(n1)
        + String(" welford=")
        + String(w1.variance()),
    )
    assert_true(
        n1 < 0.0 or n1 > 1.0,
        String("and it is not merely imprecise — it is unusable AS a variance;")
        + String(" got ")
        + String(n1),
    )
    # ⚠ RECORDED, NOT ASSERTED: on this fixture the residual lands NEGATIVE, so
    # `sqrt` of it is `nan` and every later comparison against the bound is
    # silently FALSE. That is the worst case and it is the reason for Welford —
    # but see above for why its sign is not a thing to gate on.
    if n1 < 0.0:
        assert_true(
            not isfinite(sqrt(n1)),
            "sqrt of a negative variance is not finite — the silent failure",
        )
    assert_true(
        w1.variance() > 0.0,
        String("Welford must stay positive under the same offset; got ")
        + String(w1.variance()),
    )
    var rel1 = (w1.variance() - w0.variance()) / w0.variance()
    if rel1 < 0.0:
        rel1 = -rel1
    assert_true(
        rel1 < 1e-6,
        String("and it must still be the SAME variance — a constant offset")
        + String(" does not change dispersion. unshifted=")
        + String(w0.variance())
        + String(" shifted=")
        + String(w1.variance()),
    )
    print(
        String("naive vs welford at +1e9 on 40 real launches: naive=")
        + String(n1)
        + String("  welford=")
        + String(w1.variance())
        + String("  (true ")
        + String(w0.variance())
        + String(")")
    )


def test_welford_matches_a_two_pass_variance_exactly_enough() raises:
    """The recurrence is not merely stable, it is RIGHT.

    ⚠ THE SECOND `delta` MUST USE THE UPDATED MEAN. Using the old one — the
    classic transcription error — makes `m2` accumulate `delta*delta`, which
    over-estimates. This asserts against an independently computed two-pass
    variance, so that error is caught by a number rather than by review.
    """
    var v = _duck_q04_launches()
    var w = RunningStats()
    for i in range(len(v)):
        w.update(v[i])
    assert_equal(w.count, len(v), "every point folded in")

    var mean = Float64(0.0)
    for i in range(len(v)):
        mean += v[i]
    mean = mean / Float64(len(v))
    var ss = Float64(0.0)
    for i in range(len(v)):
        ss += (v[i] - mean) * (v[i] - mean)
    var two_pass = ss / Float64(len(v) - 1)

    var rel = (w.variance() - two_pass) / two_pass
    if rel < 0.0:
        rel = -rel
    assert_true(
        rel < 1e-12,
        String("Welford must match a two-pass variance to ~1e-12; two_pass=")
        + String(two_pass)
        + String(" welford=")
        + String(w.variance())
        + String(" rel=")
        + String(rel),
    )


def test_a_point_is_judged_against_the_state_that_precedes_it() raises:
    """⭐ 2. THE ORDERING, PROVED BY AN INPUT ON WHICH IT DECIDES THE ANSWER.

    Twenty tight points, then one enormous one. Judged against the PRIOR state
    the outlier is ~200 sigmas out and breaches. Folded in FIRST — the natural
    way to write it — it drags the mean up and inflates the scale enough that
    it comes in at ~4.4 sigmas and does NOT breach at the default bound of 5.

    Both numbers are asserted, so this test fails whichever way the ordering is
    got wrong: too small a z means the point was folded in first, and the
    control below proves the 'after' figure really is under the limit.
    """
    var b = RunningBounds()
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    for i in range(BOUNDS_MIN_PRIOR):
        _ = b.observe(100.0 + pattern[i % 5])
    var sig = b.observe(400.0)
    assert_true(sig.armed, "20 prior points, so the arm is armed")
    assert_true(
        sig.z > 100.0,
        String("judged against the 20 points that PRECEDE it, 400 is far")
        + String(" beyond a hundred sigmas; got ")
        + String(sig.z),
    )
    assert_true(sig.breached, "and it breaches")
    assert_equal(sig.direction, 1, "upward")

    # ── THE CONTROL: what the 'fold it in first' spelling would have said. ──
    var after = RunningStats()
    for i in range(BOUNDS_MIN_PRIOR):
        after.update(100.0 + pattern[i % 5])
    after.update(400.0)
    var z_after = (400.0 - after.mean) / after.stddev()
    assert_true(
        z_after < DEFAULT_BOUND_SIGMAS,
        String("CONTROL: judging the point against statistics that already")
        + String(" contain it puts it at ")
        + String(z_after)
        + String(" sigmas, UNDER the limit of ")
        + String(DEFAULT_BOUND_SIGMAS)
        + String(" — so the ordering above is what makes the detection")
        + String(" happen. If this is not under the limit, the test above")
        + String(" would pass either way and proves nothing."),
    )
    print(
        String("outlier judged BEFORE folding in: z=")
        + String(sig.z)
        + String(" (breaches); AFTER folding in: z=")
        + String(z_after)
        + String(" (does not)")
    )


def test_the_incremental_chart_matches_the_batch_chart_to_the_bit() raises:
    """⭐ 3. THE ONLINE CHART IS THE SAME CHART.

    `RunningBounds` advances the CUSUM incrementally, one point at a time, from
    a frozen Phase-I prefix. `run_cusum` computes it in a batch. Same input,
    same parameters — so they must reach the same mu, the same sigma, the same
    signal and the same signal index. Anything less and the online path is a
    second, differently-calibrated detector wearing the same name.
    """
    var v: List[Float64] = []
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    for i in range(CUSUM_MIN_REFERENCE):
        v.append(50.0 + pattern[i % 5])
    for i in range(20):
        # A sustained upward shift after the reference: something the chart
        # must actually FIND, or this compares two silences.
        v.append(54.0 + pattern[i % 5])

    var batch = run_cusum(v, CUSUM_MIN_REFERENCE, Float64(0.5), Float64(5.0))
    assert_equal(
        batch.declined,
        CUSUM_DECLINED_NONE,
        "the batch chart must actually run",
    )
    assert_true(
        batch.signalled,
        "and must SIGNAL, or this test compares two silent charts",
    )

    var b = RunningBounds()
    for i in range(len(v)):
        _ = b.observe(v[i])

    assert_equal(b.mu, batch.mu, "same reference median, to the bit")
    assert_equal(b.sigma, batch.sigma, "same reference scale, to the bit")
    assert_equal(b.chart_signalled, batch.signalled, "same verdict")
    assert_equal(
        b.chart_signal_index,
        batch.signal_index,
        "and the same index — a card cites this number",
    )
    assert_equal(b.chart_direction, batch.direction, "same direction")


def test_the_phase_one_prefix_is_bounded_and_released() raises:
    """⭐ 3b. THE ONE THING THAT IS NOT O(1) SPACE STOPS GROWING.

    The prefix buffer must be exactly `CUSUM_MIN_REFERENCE` long at the moment
    it freezes and EMPTY immediately after, no matter how many points follow.
    A buffer that kept growing would make the per-series cost O(n) — the whole
    reason this module refuses to keep history.
    """
    var b = RunningBounds()
    for i in range(CUSUM_MIN_REFERENCE - 1):
        _ = b.observe(10.0 + Float64(i % 3))
        assert_false(
            b.frozen,
            String("not frozen yet at ") + String(i + 1) + String(" points"),
        )
        assert_equal(
            len(b.reference), i + 1, "the prefix is still accumulating"
        )
    _ = b.observe(11.0)
    assert_true(b.frozen, "frozen at exactly the reference length")
    assert_equal(
        len(b.reference),
        0,
        "and the buffer is RELEASED — a prefix that is kept is O(n) memory",
    )
    for i in range(500):
        _ = b.observe(10.0 + Float64(i % 3))
    assert_equal(
        len(b.reference),
        0,
        "and it stays released across 500 further points",
    )
    assert_equal(b.observed, CUSUM_MIN_REFERENCE + 500, "all points seen")


def test_the_frozen_statistics_are_the_exact_batch_ones() raises:
    """The prefix is BOUNDED, so its median and MAD are EXACT — not a streaming
    approximation. Asserted against the batch functions on the same 20 values.
    """
    var prefix = List[Float64]()
    var b = RunningBounds()
    for i in range(CUSUM_MIN_REFERENCE):
        var x = 7.0 + Float64((i * 13) % 11) * 0.25
        prefix.append(x)
        _ = b.observe(x)
    assert_true(b.frozen, "frozen")
    assert_equal(b.mu, median_of(prefix), "exact median, not an estimate")
    assert_equal(b.sigma, estimate_scale(prefix), "exact MAD scale")


def test_unarmed_is_not_unbreached() raises:
    """⭐ 4. THE FAIL-QUIET SHAPE THIS MODULE REFUSES.

    Below the warm-up the arm has produced NO RULING, and it says so with a
    reason word. A caller reading `breached == False` as 'the point is fine'
    would be reading an instrument that did not run as a pass.
    """
    var b = RunningBounds()
    # ⚠ `BOUNDS_MIN_PRIOR` OBSERVATIONS, NOT `- 1`. The rule is about the
    # points that PRECEDE the one being judged, so the 20th observation still
    # has only 19 priors and is unarmed; the 21st is the first with a ruling.
    # Getting this off by one is exactly how an activation boundary ends up
    # asserted on the wrong side.
    for i in range(BOUNDS_MIN_PRIOR):
        var sig = b.observe(100.0 + Float64(i % 3))
        assert_false(sig.armed, "no ruling below the warm-up")
        assert_false(sig.breached, "and therefore no breach")
        assert_equal(
            b.declined,
            BOUNDS_DECLINED_TOO_FEW_PRIOR,
            "and the reason is recorded, not left blank",
        )
        assert_equal(
            bounds_decline_name(b.declined),
            String("too_few_prior_points"),
            "as a word a human reads",
        )
        # ⭐ AND THE SIGNAL CARRIES IT TOO, not just the accumulator. A
        # consumer holding only the `BoundSignal` — which is every consumer on
        # the detector side — must be able to say WHY without re-deriving it
        # against a threshold it cannot see.
        assert_equal(
            sig.declined,
            BOUNDS_DECLINED_TOO_FEW_PRIOR,
            "the reason travels with the ruling, not only with the arm",
        )
    var armed = b.observe(100.0)
    assert_true(
        armed.armed,
        String("and at exactly ")
        + String(BOUNDS_MIN_PRIOR)
        + String(" prior points it arms — the boundary, from both sides"),
    )
    assert_equal(b.declined, BOUNDS_DECLINED_NONE, "it ran")


def test_a_constant_history_declines_rather_than_firing_on_everything() raises:
    """A series with no dispersion has no scale to express a bound in.

    ⛔ THE ALTERNATIVE IS WORSE THAN IT LOOKS. Dividing by a zero scale makes
    every point that differs in the last digit infinitely many sigmas out, so a
    perfectly stable series becomes a detector that fires on its first flicker.
    Declining is the honest answer and the reason is recorded.
    """
    var b = RunningBounds()
    for _i in range(BOUNDS_MIN_PRIOR + 5):
        var sig = b.observe(42.0)
        assert_false(sig.breached, "a constant series never breaches")
    assert_equal(
        b.declined,
        BOUNDS_DECLINED_ZERO_SCALE,
        "and the decline reason is ZERO_SCALE, not TOO_FEW_PRIOR",
    )
    var sig2 = b.observe(42.000001)
    assert_false(
        sig2.armed,
        "a flicker on a flat history still produces no ruling — not an"
        " infinite-sigma detection",
    )


def test_the_online_reference_cannot_be_shortened_below_the_measured_floor() raises:
    """The refusal `cusum.mojo` makes, made again here.

    A ten-point reference false-alarmed on 13 of 82 real known-zero cells. The
    online path must not be a way around that number.
    """
    var raised = False
    try:
        var bad = RunningBounds(
            DEFAULT_BOUND_SIGMAS, BOUNDS_MIN_PRIOR, CUSUM_MIN_REFERENCE - 1
        )
        _ = bad.observe(1.0)
    except e:
        raised = True
    assert_true(
        raised,
        String("a reference below ")
        + String(CUSUM_MIN_REFERENCE)
        + String(" must be REFUSED at construction, not silently accepted"),
    )
    var ok = True
    try:
        var b2 = RunningBounds(
            DEFAULT_BOUND_SIGMAS, BOUNDS_MIN_PRIOR, CUSUM_MIN_REFERENCE
        )
        _ = b2.observe(1.0)
    except e:
        ok = False
    assert_true(
        ok, "and exactly the floor is accepted — the boundary, both sides"
    )


def test_reset_discards_the_frozen_reference_too() raises:
    """`reset` means the regime is over, and the frozen reference describes a
    regime. Keeping it would leave the chart parameterised by data the caller
    has just declared irrelevant."""
    var b = RunningBounds()
    for i in range(CUSUM_MIN_REFERENCE + 5):
        _ = b.observe(100.0 + Float64(i % 4))
    assert_true(b.frozen, "frozen before the reset")
    assert_true(b.stats.count > 0, "and accumulated")
    b.reset()
    assert_false(b.frozen, "not frozen after")
    assert_equal(b.stats.count, 0, "and nothing accumulated")
    assert_equal(b.mu, Float64(0.0), "the reference median is gone")
    assert_equal(b.sigma, Float64(0.0), "and its scale")
    assert_equal(b.observed, 0, "and the point count")



def test_a_constant_phase_one_prefix_freezes_to_a_DECLINED_chart() raises:
    """⛔ THE CHART MUST REFUSE A REFERENCE WITH NO SCALE, AND SAY SO.

    `_freeze_reference` computes mu and sigma once and releases the buffer.
    If the prefix was constant the MAD is zero, and a chart run on sigma = 0
    has k = h = 0: the cumulative sum crosses a threshold of zero on the FIRST
    positive deviation, so a series that was perfectly stable for its whole
    warm-up signals on its next flicker. That is the loudest possible detector
    built out of the quietest possible data.

    Removing the ZERO_SCALE branch left all nine tests green. The control is
    the varying prefix: without it, a `_freeze_reference` that declined
    UNCONDITIONALLY would pass the first half.
    """
    var b = RunningBounds()
    for _i in range(CUSUM_MIN_REFERENCE):
        _ = b.observe(42.0)
    assert_true(b.frozen, "the prefix completed and was frozen")
    assert_true(b.sigma == 0.0, "and a constant prefix has no scale")
    assert_equal(
        b.chart_declined,
        CUSUM_DECLINED_ZERO_SCALE,
        String("⛔ the chart must record that it CANNOT run, not run with")
        + String(" k = h = 0. Got ")
        + String(b.chart_declined),
    )
    # and it stays off: a large deviation afterwards must not signal.
    for i in range(20):
        _ = b.observe(42.0 + Float64(i))
    assert_false(
        b.chart_signalled,
        String("a declined chart does not signal — at sigma=0 every")
        + String(" deviation is above a threshold of zero, so this would fire")
        + String(" on the first one"),
    )

    # ── CONTROL: the same prefix length WITH dispersion does arm the chart ──
    var c = RunningBounds()
    for i in range(CUSUM_MIN_REFERENCE):
        _ = c.observe(100.0 + Float64(i % 5))
    assert_true(c.frozen, "frozen")
    assert_true(c.sigma > 0.0, "and this one has a scale")
    assert_equal(
        c.chart_declined,
        CUSUM_DECLINED_NONE,
        String("CONTROL: a reference with dispersion RUNS, or the decline")
        + String(" above is unconditional and proves nothing"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
