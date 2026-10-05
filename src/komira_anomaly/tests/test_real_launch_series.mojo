# =============================================================================
# tests/test_real_launch_series.mojo
#   ⭐ THE SECONDARY ARM, MEASURED ON REAL DATA FOR THE FIRST TIME — AND IT
#   FAILS ITS OWN BUDGET.
#
# ── WHY THIS FILE EXISTS ─────────────────────────────────────────────────────
#
# The secondary arm is INERT on any series shorter than 21 points, so a corpus
# of 10-point series cannot measure its false-alarm rate on REAL data at a
# sufficient reference length. Per-LAUNCH records can: one query run 30 to 100
# times in a row, recorded alongside the ten sweeps the corpus test uses.
#
# ── ⛔ THE TRAP IN THE OBVIOUS SOURCE ───────────────────────────────────────
#
# The obvious idea is to use the sweeps' warm-rep arrays: 5 warm reps x 10
# sweeps = 50 points per cell. IT IS WRONG: the sweep driver SORTS the reps
# before recording them,
#
#       tw = sorted(ms for (rep, ms) in rec.get("warm", []) if rep > 0)
#
# and measured over all 840 recorded rows (84 data ids x 10 sweeps), 840 of
# 840 warm-rep arrays are ascending — the measurement ORDER is gone.
# Concatenating them would build a series in which every 5-point block ramps
# upward by construction, which is precisely the shape a cumulative-sum chart
# exists to detect. It would have manufactured the drift it then reported.
#
# ── ⭐ WHAT THIS DATA IS INSTEAD ────────────────────────────────────────────
#
#   source  four per-launch record files
#   shape   one JSON row per LAUNCH, keyed `"i": 0..n-1` — the index IS the
#           order, and `reps_ms` is UNSORTED (verified: 320 of 320 rows).
#   value   median of `reps_ms[1:]` — the warm reps, dropping the cold first
#           one, which is the same statistic the sweep harness reports.
#   null    ONE binary, ONE query, ONE arm, ONE host, relaunched. No code
#           change is possible between two launches of the same executable, so
#           every firing here is false WITH RESPECT TO CODE.
#
# ⚠ AND THE SCOPE OF THAT NULL, STATED HONESTLY. These launches are seconds
# apart, not commits apart. A firing here is not necessarily "noise" — the
# MACHINE may really have moved. What it is guaranteed not to be is a code
# regression, which is the only thing this detector is for. A detector that
# cannot stay quiet across 100 launches of an unchanged binary cannot be
# pointed at a commit series.
#
# ── WHAT IS ASSERTED ─────────────────────────────────────────────────────────
#
#   (1) the CUSUM arm fires on 3 of these 6 series. It is not inert here, and
#       it is over budget by a factor of three.
#   (2) the CHANGE-POINT arm fires on 0 of 6 — so (1) is a property of the
#       chart, not of the data being genuinely non-stationary.
#   (3) the RUNNING-BOUNDS arm fires on 0 of 6, and the largest |z| it ever
#       computes is 2.433, which is what puts the default bound at 5.
#   (4) two of the three chart firings are explained: those series are BIMODAL
#       and the gap between the modes is 11.3 and 5.4 reference sigmas.
#   (5) the bounds arm is NOT a shift detector, measured — a sustained +10%
#       step is caught on 2 of 6. Asserted so nobody reads a green bound as
#       "this series has not regressed".
# =============================================================================

from std.math import sqrt

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_anomaly import (
    CUSUM_DECLINED_NONE,
    STATE_NORMAL,
    CUSUM_MIN_REFERENCE,
    DEFAULT_BOUND_SIGMAS,
    DEFAULT_SLACK_SIGMAS,
    DEFAULT_THRESHOLD_SIGMAS,
    DEFAULT_SIGNIFICANCE,
    DetectorConfig,
    RunningBounds,
    RunningStats,
    STATE_ANOMALY,
    Series,
    SeriesDetector,
    estimate_scale,
    median_of,
    fit_change_point,
    run_cusum,
    seed_for_key,
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


struct LaunchSeries(Copyable, Movable, Deinitable):
    var key: String
    var seed: UInt64
    var values: List[Float64]

    def __init__(
        out self, key: String, seed: UInt64, var values: List[Float64]
    ):
        self.key = key
        self.seed = seed
        self.values = values^


def _lcell(
    mut out: List[LaunchSeries],
    key: String,
    seed: UInt64,
    var values: List[Float64],
):
    out.append(LaunchSeries(key, seed, values^))


def real_launch_series() -> List[LaunchSeries]:
    """Six real order-preserving known-zero series. See the file header."""
    var out = List[LaunchSeries]()
    # Each permutation-test seed is a fixed constant, not derived from the key.
    _lcell(out, String("launch/engine_q04_base_n100"), UInt64(0x5C7FCA1CAB49BB7F), [
    18.164, 15.459, 15.337, 15.542, 15.315, 15.654, 15.305, 15.478,
    15.357, 15.408, 18.231, 15.444, 15.505, 18.222, 18.182, 15.601,
    15.481, 18.044, 15.319, 18.384, 15.762, 18.534, 18.294, 15.495,
    18.232, 15.457, 15.355, 18.004, 18.009, 15.69, 18.105, 18.082,
    17.973, 15.453, 18.032, 17.854, 17.892, 15.549, 18.755, 15.476,
    15.352, 15.384, 15.49, 15.322, 18.135, 15.413, 15.51, 17.704, 17.899,
    15.313, 18.363, 18.584, 15.559, 15.442, 18.284, 18.045, 15.653,
    15.531, 15.334, 15.43, 17.877, 15.161, 15.433, 15.595, 15.595,
    18.134, 18.16, 15.503, 15.544, 18.006, 18.18, 15.283, 15.196, 17.879,
    15.469, 15.41, 18.219, 15.43, 15.523, 15.478, 18.048, 15.437, 15.486,
    15.359, 18.437, 15.327, 15.595, 15.517, 17.88, 18.103, 18.157,
    15.592, 15.512, 15.357, 15.73, 15.506, 15.426, 15.434, 18.121,
    15.491,
    ])
    _lcell(out, String("launch/duck_q04_base_n100"), UInt64(0x51ADFCE8834A1597), [
    12.0481, 11.6997, 11.5977, 11.6261, 11.6534, 11.7912, 11.6625,
    11.5963, 11.7316, 11.6047, 11.7635, 11.726, 11.6276, 11.7246,
    11.6472, 11.6437, 11.6865, 11.7824, 11.6604, 11.798, 11.7217,
    11.6393, 11.8011, 11.6081, 11.7823, 11.6791, 11.5011, 11.6885,
    11.9412, 11.6467, 11.592, 11.7733, 11.7563, 11.7504, 11.6834,
    11.7445, 11.7117, 11.619, 11.735, 11.851, 11.6656, 11.6816, 11.5764,
    11.8061, 11.6478, 11.8131, 11.6328, 11.6783, 11.6549, 11.7745,
    11.7146, 11.6904, 11.7575, 11.6694, 11.639, 11.816, 11.6396, 11.7449,
    11.5801, 11.8143, 11.592, 11.7225, 11.7427, 11.7089, 11.6114,
    11.6894, 11.6133, 11.8033, 11.7708, 11.7123, 11.8294, 11.7097,
    11.6919, 11.7589, 11.7943, 11.7794, 11.7585, 11.8456, 11.6534,
    11.6125, 11.7395, 11.7737, 11.6989, 11.7103, 11.573, 11.657, 11.7361,
    11.6699, 11.8121, 11.697, 11.7564, 11.7018, 11.6781, 11.6608,
    11.7267, 11.6878, 11.8643, 11.7066, 11.7775, 11.6676,
    ])
    _lcell(out, String("launch/engine_cb10_base_n30"), UInt64(0x7132ED5EE6E9CA93), [
    493.234, 478.473, 496.47, 490.518, 492.579, 486.229, 492.107,
    489.333, 490.424, 488.91, 485.983, 485.431, 504.416, 482.846,
    487.777, 483.868, 485.665, 483.383, 492.24, 491.459, 487.884,
    483.606, 487.943, 487.087, 487.159, 500.575, 487.978, 501.054,
    480.533, 488.334,
    ])
    _lcell(out, String("launch/engine_q04_c4base_n30"), UInt64(0x42EE7E78B0BC23DB), [
    18.049, 18.252, 18.204, 15.513, 15.428, 15.367, 15.592, 15.602,
    18.079, 15.334, 18.014, 15.419, 15.292, 18.198, 15.492, 18.019,
    15.68, 18.234, 17.844, 15.519, 15.437, 15.304, 15.355, 15.335,
    15.412, 15.528, 18.048, 17.865, 15.764, 18.087,
    ])
    _lcell(out, String("launch/engine_q04_node0_n30"), UInt64(0x96AACCEC9ECE8953), [
    20.041, 21.185, 21.682, 22.878, 21.062, 21.59, 21.312, 19.846,
    20.099, 21.501, 22.007, 19.717, 19.841, 20.741, 20.817, 21.042,
    21.56, 21.669, 21.512, 21.736, 19.885, 21.179, 20.727, 20.007, 21.06,
    19.931, 21.711, 20.872, 21.338, 20.903,
    ])
    _lcell(out, String("launch/engine_q04_node1_n30"), UInt64(0xEB8DFAD4BE090AB1), [
    20.893, 19.967, 20.759, 21.211, 19.824, 21.054, 21.81, 19.891,
    20.725, 20.022, 20.034, 19.993, 21.648, 20.675, 19.881, 20.009,
    20.05, 21.014, 21.542, 20.627, 20.486, 21.02, 21.122, 20.827, 21.281,
    19.678, 19.837, 19.724, 19.869, 20.133,
    ])
    return out^


def test_the_fixture_is_what_the_header_says_it_is() raises:
    """PROVENANCE, FIRST. Every claim below is about THESE numbers.

    ⚠ AND `n >= 21` IS THE LOAD-BEARING ONE. The whole point of this file is
    that these series are long enough to run the chart at all; a fixture that
    quietly shortened would make every 'the arm fires on 3 of 6' result below a
    statement about an arm that declined.
    """
    var s = real_launch_series()
    assert_equal(len(s), 6, "six series were extracted")
    var total = 0
    for i in range(len(s)):
        assert_true(
            len(s[i].values) > CUSUM_MIN_REFERENCE,
            String("series ")
            + s[i].key
            + String(" must be longer than the chart's reference (")
            + String(CUSUM_MIN_REFERENCE)
            + String(") or the chart DECLINES and nothing here is measured;")
            + String(" got ")
            + String(len(s[i].values)),
        )
        total += len(s[i].values)
    assert_equal(total, 320, "320 recorded launches in all")


def test_cusum_arm_fires_on_half_the_real_known_zero_series() raises:
    """⭐ (1) THE MEASUREMENT THAT MAKES THE ARM ADVISORY.

    Three of six. The budget is at most one firing per corpus run. Every one of
    these is false with respect to code, because the binary did not change
    between two launches of itself.
    """
    var s = real_launch_series()
    var fired = 0
    var declined = 0
    var names = String("")
    for i in range(len(s)):
        # ⚠ THE SHIPPED CONSTANTS, NOT LITERALS. The claim is about the arm
        # this package actually ships; parameterising it with 0.5/5.0 written
        # out here would leave the measurement standing while somebody changed
        # the defaults underneath it.
        var cus = run_cusum(
            s[i].values,
            CUSUM_MIN_REFERENCE,
            DEFAULT_SLACK_SIGMAS,
            DEFAULT_THRESHOLD_SIGMAS,
        )
        if cus.declined != CUSUM_DECLINED_NONE:
            declined += 1
        if cus.signalled:
            fired += 1
            names = (
                names
                + String(" ")
                + s[i].key
                + String("@")
                + String(cus.signal_index)
            )
    assert_equal(
        declined,
        0,
        String("the chart must actually RUN on all six — a decline here would")
        + String(" make this file measure nothing. Got ")
        + String(declined)
        + String(" declines"),
    )
    assert_equal(
        fired,
        3,
        String("the CUSUM arm fires on exactly 3 of the 6 real known-zero")
        + String(" series. This is the measurement behind")
        + String(" DEFAULT_CUSUM_ARMS_VERDICT = False. Got ")
        + String(fired)
        + String(":")
        + names,
    )
    print(
        String("CUSUM arm on 6 real known-zero series: ")
        + String(fired)
        + String("/6 fire (budget <=1):")
        + names
    )


def test_the_changepoint_arm_is_quiet_on_the_same_six() raises:
    """⭐ (2) THE ANTI-VACUOUS ARM FOR (1).

    If these series were simply non-stationary, EVERY arm would fire on them
    and 3-of-6 would say nothing about the chart. The primary arm — the one
    carrying the verdict — fires on ZERO of the same six.
    """
    var s = real_launch_series()
    var config = DetectorConfig()
    var fired = 0
    var names = String("")
    for i in range(len(s)):
        var series = Series(s[i].key)
        for j in range(len(s[i].values)):
            series.append(Int64(j), s[i].values[j])
        var det = SeriesDetector(s[i].key, config)
        var v = det.evaluate(series)
        if v.state == STATE_ANOMALY:
            fired += 1
            names = names + String(" ") + s[i].key
    assert_equal(
        fired,
        0,
        String("the change-point arm fires on NONE of the six — that is what")
        + String(" makes the chart's 3-of-6 a fact about the chart. Got ")
        + String(fired)
        + String(":")
        + names,
    )

    # ── THE SAME ARM UNDER THE FIXED SEEDS. The detector derives its seed from
    # the key; this loop runs the identical fit under each series' fixed seed
    # constant, so the measurement does not depend on how a key is spelled.
    var pinned_fired = 0
    for i in range(len(s)):
        var fit = fit_change_point(
            s[i].values, config.min_segment, config.permutations, s[i].seed
        )
        if fit.is_fitted() and fit.p_value < config.significance:
            pinned_fired += 1
    assert_equal(
        pinned_fired,
        0,
        String("under the fixed seeds the change-point arm also fires on NONE")
        + String(" of the six. Got ")
        + String(pinned_fired),
    )


def test_the_fixed_seed_constants_are_fnv_1a_of_a_key() raises:
    """The fixed seeds were produced by the same FNV-1a as `seed_for_key`.
    The one series whose key is unchanged checks the method."""
    var s = real_launch_series()
    var checked = 0
    for i in range(len(s)):
        if s[i].key == String("launch/duck_q04_base_n100"):
            assert_equal(s[i].seed, seed_for_key(s[i].key), "same FNV-1a")
            checked += 1
    assert_equal(checked, 1, "the unchanged key is in the fixture")


def test_an_advisory_chart_finding_is_reported_and_does_not_set_anomaly() raises:
    """⭐ 'ADVISORY' MEANS REPORTED, NOT SILENT — AND THE FLAG IS LOAD-BEARING.

    ⛔ THIS TEST EXISTS BECAUSE ITS ABSENCE WAS MEASURED. Deleting the line that
    appends `cusum_advisory=signalled` to the verdict left the whole nine-target
    suite GREEN. An arm that quietly did not count and an arm that quietly found
    nothing were the same bytes in the record — which is the exact defect
    `cusum.mojo`'s decline vocabulary was written to prevent, reappearing one
    level up.

    Both halves are asserted on the SAME three real series:

      * with the arm ADVISORY (the default) the state stays NORMAL and the
        verdict SAYS the chart signalled;
      * with `cusum_arms_verdict=True` those same three become ANOMALY.

    The second half is the anti-vacuous control: without it, a detector whose
    chart never signalled at all would pass the first half.
    """
    var s = real_launch_series()
    var advisory_but_reported = 0
    var armed_and_fired = 0
    for i in range(len(s)):
        var series = Series(s[i].key)
        for j in range(len(s[i].values)):
            series.append(Int64(j), s[i].values[j])

        var det = SeriesDetector(s[i].key, DetectorConfig())
        var v = det.evaluate(series)
        if not v.cusum_signalled:
            continue
        advisory_but_reported += 1
        assert_equal(
            v.state,
            STATE_NORMAL,
            String("'")
            + s[i].key
            + String("': the chart signalled but is ADVISORY, so the state")
            + String(" must stay NORMAL. Got ")
            + v.render(),
        )
        assert_true(
            _contains(v.detail, String("cusum_advisory=signalled")),
            String("'")
            + s[i].key
            + String("': and the verdict must SAY the chart found something.")
            + String(" A NORMAL that hides an advisory finding is")
            + String(" indistinguishable from one where nothing was found.")
            + String(" Got detail: ")
            + v.detail,
        )

        # ── THE CONTROL: the same series, the same chart, arm turned ON. ──
        var armed_cfg = DetectorConfig(cusum_arms_verdict=True)
        var det2 = SeriesDetector(s[i].key, armed_cfg^)
        var v2 = det2.evaluate(series)
        assert_equal(
            v2.state,
            STATE_ANOMALY,
            String("'")
            + s[i].key
            + String("': with cusum_arms_verdict=True the SAME chart finding")
            + String(" must set ANOMALY — otherwise the NORMAL above is not")
            + String(" the flag's doing and this test proves nothing. Got ")
            + v2.render(),
        )
        armed_and_fired += 1

        # ⛔ AND IT CANNOT BE ACKNOWLEDGED. This ANOMALY has no fitted change
        # point and no bound breach: the chart's signal index names where the
        # EVIDENCE became sufficient, not where the level changed, and those
        # are different points by construction because the chart integrates.
        # The alternative default — baselining at ordinal 0 — silently
        # discards the entire series and reports success.
        var ack_raised = False
        var ack_msg = String("")
        try:
            det2.acknowledge()
        except e:
            ack_raised = True
            ack_msg = String(e)
        assert_true(
            ack_raised,
            String("'")
            + s[i].key
            + String("': a chart-only ANOMALY has no ordinal that means 'the")
            + String(" new regime starts here', so acknowledge() must REFUSE")
            + String(" rather than guess one"),
        )
        assert_true(
            _contains(ack_msg, String("chart-only")),
            String("and the refusal must name the case it is refusing; got ")
            + ack_msg,
        )
        assert_false(
            v2.changepoint_fired,
            String("CONTROL: chart-only means the primary arm did NOT fire,")
            + String(" or the refusal above is about a different case"),
        )
        assert_false(
            v2.bound_breached,
            String("CONTROL: and the bound did not breach either"),
        )

    assert_equal(
        advisory_but_reported,
        3,
        String("exactly 3 of the 6 series have a chart finding to report —")
        + String(" the same 3 counted above. Got ")
        + String(advisory_but_reported),
    )
    assert_equal(
        armed_and_fired,
        3,
        "and all 3 become ANOMALY once the arm is allowed to rule",
    )
    print(
        String("advisory chart findings: ")
        + String(advisory_but_reported)
        + String("/6 reported without setting ANOMALY; all ")
        + String(armed_and_fired)
        + String(" fire when cusum_arms_verdict=True")
    )


def test_running_bounds_are_quiet_and_the_worst_real_z_is_2_433() raises:
    """⭐ (3) WHERE THE DEFAULT BOUND COMES FROM.

    Not from a distributional argument — from the largest |z| this arm actually
    computes on 200 armed tests over real data, which is 2.433. The default of
    5 sigmas is that number with a 2.05x margin, and this test is where the
    number lives.
    """
    var s = real_launch_series()
    var fired = 0
    var armed_tests = 0
    var worst = Float64(0.0)
    var worst_key = String("")
    for i in range(len(s)):
        var b = RunningBounds()
        for j in range(len(s[i].values)):
            var sig = b.observe(s[i].values[j])
            if sig.armed:
                armed_tests += 1
                var az = sig.z
                if az < 0.0:
                    az = -az
                if az > worst:
                    worst = az
                    worst_key = s[i].key
                if sig.breached:
                    fired += 1
    assert_equal(
        armed_tests,
        200,
        String("200 of the 320 points are judged (the first 20 of each series")
        + String(" are the warm-up). A different number means the arming rule")
        + String(" moved. Got ")
        + String(armed_tests),
    )
    assert_equal(
        fired,
        0,
        String("the running-bounds arm must be silent on all six. Got ")
        + String(fired),
    )
    assert_true(
        worst > 2.43 and worst < 2.44,
        String("the largest |z| over real known-zero data is 2.433 (")
        + worst_key
        + String("); the default bound of ")
        + String(DEFAULT_BOUND_SIGMAS)
        + String(" sigmas is chosen as a margin over exactly this. Got ")
        + String(worst),
    )
    assert_true(
        DEFAULT_BOUND_SIGMAS > worst * 2.0,
        String("and the default bound must keep at least a 2x margin over the")
        + String(" worst measured |z|; ")
        + String(DEFAULT_BOUND_SIGMAS)
        + String(" vs ")
        + String(worst),
    )
    print(
        String("running bounds on 6 real known-zero series: 0/6 fire over ")
        + String(armed_tests)
        + String(" armed tests; worst |z| = ")
        + String(worst)
        + String(" (")
        + worst_key
        + String(")")
    )


def test_two_of_the_three_chart_firings_are_bimodality_not_drift() raises:
    """⭐ (4) THE CHART'S FIRINGS ARE EXPLAINED, NOT JUST COUNTED.

    A launch-time placement lottery puts each run of `q04` in one of two
    regimes. The chart's scale is a MAD over the first 20 points, which measures
    the spread WITHIN whichever mode dominated that prefix; the gap BETWEEN the
    modes is many of those sigmas, so every point of the other mode is a huge
    deviation and the chart is arithmetically certain to signal.

    Asserting the ratio — not just 'it fired' — is what makes the diagnosis
    falsifiable. A future dataset where the arm fires for some other reason will
    fail HERE rather than quietly inheriting this explanation.
    """
    var s = real_launch_series()
    var checked = 0
    for i in range(len(s)):
        var v = s[i].values.copy()
        if (
            s[i].key != String("launch/engine_q04_base_n100")
            and s[i].key != String("launch/engine_q04_c4base_n30")
        ):
            continue
        checked += 1
        var lo = v[0]
        var hi = v[0]
        for j in range(len(v)):
            if v[j] < lo:
                lo = v[j]
            if v[j] > hi:
                hi = v[j]
        var mid = (lo + hi) / 2.0
        var low_mode = List[Float64]()
        var high_mode = List[Float64]()
        for j in range(len(v)):
            if v[j] < mid:
                low_mode.append(v[j])
            else:
                high_mode.append(v[j])
        assert_true(
            len(low_mode) >= 10 and len(high_mode) >= 10,
            String("both modes must be populated for '")
            + s[i].key
            + String("' to be bimodal at all; got ")
            + String(len(low_mode))
            + String("/")
            + String(len(high_mode)),
        )
        var reference = List[Float64]()
        for j in range(CUSUM_MIN_REFERENCE):
            reference.append(v[j])
        var sigma = estimate_scale(reference)
        assert_true(sigma > 0.0, "the reference has a scale")
        var gap = median_of(high_mode) - median_of(low_mode)
        var gap_sigmas = gap / sigma
        assert_true(
            gap_sigmas > 5.0,
            String("'")
            + s[i].key
            + String("' fires because its two modes are ")
            + String(gap_sigmas)
            + String(" reference sigmas apart; below ~5 this explanation does")
            + String(" not hold and the firing needs a different one"),
        )
    assert_equal(checked, 2, "both named series are in the fixture")


def test_the_bounds_arm_is_not_a_shift_detector_and_this_is_measured() raises:
    """⛔ (5) THE LIMITATION, ASSERTED SO IT CANNOT BE FORGOTTEN.

    A per-point bound over a RUNNING scale folds each new point into the very
    statistic that judges the next one, so a shift that PERSISTS inflates the
    bound that would have caught it. Measured on these six series with a step
    applied from the 25th point on: +10% is caught on 2 of 6.

    ⚠ THIS IS AN UPPER BOUND ON WHAT THE ARM CAN PROMISE, AND IT IS ASSERTED AS
    ONE. A reader who takes a green bounds verdict as 'this series has not
    regressed' has read a point test as a trend test — that coverage is the
    change-point arm's, which finds a 10% shift on 74 of 82 corpus cells.
    """
    var s = real_launch_series()
    var caught10 = 0
    var caught30 = 0
    for i in range(len(s)):
        var b10 = RunningBounds()
        var b30 = RunningBounds()
        var hit10 = False
        var hit30 = False
        for j in range(len(s[i].values)):
            var x = s[i].values[j]
            var f10 = x
            var f30 = x
            if j >= 25:
                f10 = x * 1.10
                f30 = x * 1.30
            if b10.observe(f10).breached and j >= 25:
                hit10 = True
            if b30.observe(f30).breached and j >= 25:
                hit30 = True
        if hit10:
            caught10 += 1
        if hit30:
            caught30 += 1
    assert_equal(
        caught10,
        2,
        String("a sustained +10% step is caught by the BOUNDS arm on exactly")
        + String(" 2 of 6 series. If this ever reads 6 the arm has become")
        + String(" something else and the claim above needs rewriting. Got ")
        + String(caught10),
    )
    assert_true(
        caught30 > caught10,
        String("and a bigger step must at least do better than a smaller one;")
        + String(" +30% caught ")
        + String(caught30)
        + String(" vs +10% caught ")
        + String(caught10),
    )
    print(
        String("bounds arm vs a SUSTAINED step on the same six: +10% -> ")
        + String(caught10)
        + String("/6, +30% -> ")
        + String(caught30)
        + String("/6  (this arm is a POINT test, not a trend test)")
    )



def _fires_at_k(s: List[LaunchSeries], k: Float64) raises -> Int:
    """How many of the six series the bounds arm fires on at limit `k`."""
    var n = 0
    for i in range(len(s)):
        var b = RunningBounds(k)
        var hit = False
        for j in range(len(s[i].values)):
            if b.observe(s[i].values[j]).breached:
                hit = True
        if hit:
            n += 1
    return n


def _spike_caught_at(
    s: List[LaunchSeries], k: Float64, factor: Float64
) raises -> Int:
    """How many of the six the arm catches a SINGLE spiked point on.

    One point — index 25 — multiplied by `factor`, everything else untouched.
    A single spike is the shape this arm is actually for, as against the
    SUSTAINED step measured in `test_the_bounds_arm_is_not_a_shift_detector`.
    """
    var n = 0
    for i in range(len(s)):
        var b = RunningBounds(k)
        var hit = False
        for j in range(len(s[i].values)):
            var x = s[i].values[j]
            if j == 25:
                x = x * factor
            var sig = b.observe(x)
            if sig.breached and j == 25:
                hit = True
        if hit:
            n += 1
    return n


def test_the_published_calibration_tables_are_re_derived_here() raises:
    """⭐ (6) THE TWO TABLES IN `bounds.mojo`'s HEADER, COMPUTED.

    ⛔ THAT HEADER CLAIMED THIS FILE ALREADY DID THIS — "re-derives every row of
    both tables from the recorded numbers, including the rows that are bad
    news" — AND NO TEST COMPUTED EITHER TABLE. The numbers turned out to be
    right; the sentence asserting they were checked was not. The measured
    consequence was a ONE-SIDED pin on the default: `DEFAULT_BOUND_SIGMAS`
    could be raised 5 -> 6, 7 or 8 — a 60% loss of sensitivity — with the whole
    suite green, because the only two constraints on it were a LOWER bound
    (`> worst*2.0`, satisfied from k=4.87) and a spike count that happened to
    hold for every k in [4, 9].

    ⭐ THE CHOSEN ROW IS COMPUTED AT `DEFAULT_BOUND_SIGMAS`, NOT AT A LITERAL
    5.0. That is what makes this a pin on the shipped value rather than a
    restatement of the header.
    """
    var s = real_launch_series()

    # ── the anchor both tables are quoted against ──
    var worst = Float64(0.0)
    for i in range(len(s)):
        var b = RunningBounds()
        for j in range(len(s[i].values)):
            var sig = b.observe(s[i].values[j])
            if sig.armed:
                var az = sig.z
                if az < 0.0:
                    az = -az
                if az > worst:
                    worst = az
    assert_true(
        worst > 2.433 and worst < 2.434,
        String("the worst real |z| is 2.433; got ") + String(worst),
    )

    # ── TABLE 1: the MARGIN table. Every k is quiet; what differs is margin.
    var ks: List[Float64] = [3.0, 4.0, 5.0, 8.0]
    var margins: List[Float64] = [1.23, 1.64, 2.05, 3.29]
    for r in range(len(ks)):
        assert_equal(
            _fires_at_k(s, ks[r]),
            0,
            String("k=")
            + String(ks[r])
            + String(" must fire on 0 of 6 — the whole table is quiet, which")
            + String(" is why choosing k is a question of MARGIN and not of")
            + String(" false alarms. Got ")
            + String(_fires_at_k(s, ks[r])),
        )
        var m = ks[r] / worst
        assert_true(
            m > margins[r] - 0.01 and m < margins[r] + 0.01,
            String("k=")
            + String(ks[r])
            + String(" is published as a ")
            + String(margins[r])
            + String("x margin over the worst real |z|; computed ")
            + String(m),
        )
    assert_equal(
        DEFAULT_BOUND_SIGMAS,
        ks[2],
        String("⛔ AND THE ROW MARKED <- CHOSEN IS THE ONE THIS MODULE SHIPS.")
        + String(" A table whose chosen row is not the default describes a")
        + String(" detector nobody is running. Got ")
        + String(DEFAULT_BOUND_SIGMAS),
    )

    # ── TABLE 2: the PRICE of the margin, against a single spiked point. ──
    #     k = 4   4/6   6/6   6/6
    #     k = 5   3/6   5/6   6/6   <- CHOSEN, computed at DEFAULT_BOUND_SIGMAS
    #     k = 8   2/6   4/6   6/6
    var factors: List[Float64] = [1.25, 1.50, 2.00]
    var row4: List[Int] = [4, 6, 6]
    var row_chosen: List[Int] = [3, 5, 6]
    var row8: List[Int] = [2, 4, 6]
    for c in range(len(factors)):
        assert_equal(
            _spike_caught_at(s, 4.0, factors[c]),
            row4[c],
            String("k=4 at x")
            + String(factors[c])
            + String(" catches ")
            + String(row4[c])
            + String(" of 6; got ")
            + String(_spike_caught_at(s, 4.0, factors[c])),
        )
        assert_equal(
            _spike_caught_at(s, DEFAULT_BOUND_SIGMAS, factors[c]),
            row_chosen[c],
            String("⛔ THE SHIPPED BOUND'S OWN ROW. At x")
            + String(factors[c])
            + String(" the published table says ")
            + String(row_chosen[c])
            + String(" of 6 are caught. Raising the default to 8 makes this")
            + String(" row read 2/4/6 — a 60% loss of sensitivity that used")
            + String(" to pass green — and lowering it to 4 makes it 4/6/6.")
            + String(" Got ")
            + String(_spike_caught_at(s, DEFAULT_BOUND_SIGMAS, factors[c]))
            + String(" at k=")
            + String(DEFAULT_BOUND_SIGMAS),
        )
        assert_equal(
            _spike_caught_at(s, 8.0, factors[c]),
            row8[c],
            String("k=8 at x")
            + String(factors[c])
            + String(" catches ")
            + String(row8[c])
            + String(" of 6; got ")
            + String(_spike_caught_at(s, 8.0, factors[c])),
        )
    # ⚠ AND THE TABLE MUST BE MONOTONE, which is the property that makes it a
    # trade-off at all: a deafer bound cannot catch MORE.
    for c in range(len(factors)):
        assert_true(
            row4[c] >= row_chosen[c] and row_chosen[c] >= row8[c],
            "a larger k cannot catch more than a smaller one",
        )
    print(
        String("bounds calibration re-derived: worst |z| = ")
        + String(worst)
        + String("; k=3/4/5/8 all fire 0/6; single-spike catch at k=")
        + String(DEFAULT_BOUND_SIGMAS)
        + String(" is 3/6, 5/6, 6/6 for x1.25/x1.50/x2.00")
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
