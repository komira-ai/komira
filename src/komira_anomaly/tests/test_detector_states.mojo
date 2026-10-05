# =============================================================================
# tests/test_detector_states.mojo
#   THE STATE MACHINE: every state, every transition between them, and the
#   boundary on each side of the activation threshold.
#
#   The transitions asserted here, by name:
#
#     start                     -> ACCUMULATING
#     ACCUMULATING              -> ACCUMULATING      (still below min_points)
#     ACCUMULATING              -> NORMAL            (at exactly min_points)
#     ACCUMULATING              -> ANOMALY           (change already in window)
#     ACCUMULATING              -> UNCALIBRATED
#     NORMAL                    -> NORMAL
#     NORMAL                    -> ANOMALY
#     NORMAL                    -> UNCALIBRATED
#     ANOMALY                   -> ANOMALY           (LATCHED, not self-clearing)
#     ANOMALY                   -> UNCALIBRATED      (override of the latch)
#     ANOMALY --acknowledge()-> ACCUMULATING         (new baseline)
#     ANOMALY --dismiss()---->  NORMAL               (and does not re-fire)
#     UNCALIBRATED              -> NORMAL            (recovery)
#     any        --reset()---->  ACCUMULATING
#
#   ⚠ THE ONE ASSERTION MOST WORTH READING is `test_anomaly_is_latched...`. It
#   would be easy to write a detector that refits every time and quietly
#   returns to NORMAL when the evidence weakens, and every card it filed would
#   then have a subject that no longer exists.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_anomaly import (
    DEFAULT_MIN_POINTS,
    DetectorConfig,
    SERIES_OK,
    SERIES_REJECT_EMPTY_KEY,
    SERIES_REJECT_NONFINITE,
    SERIES_REJECT_UNORDERED,
    STATE_ACCUMULATING,
    STATE_ANOMALY,
    STATE_NORMAL,
    STATE_UNCALIBRATED,
    Series,
    SeriesDetector,
    state_name,
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


def _stable(key: String, n: Int) -> Series:
    """`n` points around 100.0 with a fixed sawtooth — no change anywhere."""
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var s = Series(key)
    for i in range(n):
        s.append(Int64(i), 100.0 + pattern[i % 5])
    return s^


def _stable_from(key: String, start_ordinal: Int, n: Int) -> Series:
    """`n` stable points whose ordinals begin at `start_ordinal`.

    Used to express a window that has ROLLED FORWARD past a change point — the
    ordinary shape for a source with retention, and the case in which a
    refitting detector would quietly return to NORMAL.
    """
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var s = Series(key)
    for i in range(n):
        s.append(Int64(start_ordinal + i), 100.0 + pattern[i % 5])
    return s^


def _stepped(key: String, before: Int, after: Int, factor: Float64) -> Series:
    """`before` stable points, then `after` points at `factor` times the level.
    """
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var s = Series(key)
    for i in range(before):
        s.append(Int64(i), 100.0 + pattern[i % 5])
    for i in range(after):
        s.append(
            Int64(before + i), (100.0 + pattern[i % 5]) * factor
        )
    return s^


def test_a_new_detector_starts_accumulating_and_is_not_green() raises:
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    assert_equal(det.state, STATE_ACCUMULATING, "starts ACCUMULATING")
    assert_false(
        det.last.is_green(),
        "ACCUMULATING is NOT green — 'the detector said nothing' must never"
        " read as 'the detector found nothing'",
    )


def test_accumulating_reports_progress_and_stays_below_the_threshold() raises:
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    var v = det.evaluate(_stable(String("k"), 4))
    assert_equal(v.state, STATE_ACCUMULATING, "4 < 10")
    assert_equal(v.n_points, 4, "and it says how far along it is")
    assert_true(
        _contains(v.render(), String("(4/10)")),
        String("the render must carry (n/min); got ") + v.render(),
    )
    var v2 = det.evaluate(_stable(String("k"), 7))
    assert_equal(
        v2.state, STATE_ACCUMULATING, "ACCUMULATING -> ACCUMULATING"
    )
    assert_equal(v2.n_points, 7, "progress advanced")


def test_the_activation_boundary_on_both_sides() raises:
    """⭐ THE BOUNDARY. One point below min_points there is no verdict; at
    exactly min_points there is."""
    var config = DetectorConfig()
    var below = SeriesDetector(String("b"), config)
    assert_equal(
        below.evaluate(_stable(String("b"), DEFAULT_MIN_POINTS - 1)).state,
        STATE_ACCUMULATING,
        "min_points-1 must still be ACCUMULATING",
    )
    var at = SeriesDetector(String("a"), config)
    assert_equal(
        at.evaluate(_stable(String("a"), DEFAULT_MIN_POINTS)).state,
        STATE_NORMAL,
        "at exactly min_points the detector activates",
    )


def test_accumulating_to_normal_then_normal_to_normal() raises:
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    assert_equal(
        det.evaluate(_stable(String("k"), 5)).state, STATE_ACCUMULATING, "1"
    )
    var v = det.evaluate(_stable(String("k"), 12))
    assert_equal(v.state, STATE_NORMAL, "ACCUMULATING -> NORMAL")
    assert_true(v.is_green(), "NORMAL is the only green state")
    assert_equal(
        det.evaluate(_stable(String("k"), 16)).state,
        STATE_NORMAL,
        "NORMAL -> NORMAL",
    )


def test_accumulating_straight_to_anomaly() raises:
    """A regression that landed DURING accumulation. The first verdict the
    detector is ever able to give is already ANOMALY — it must not have to pass
    through NORMAL first."""
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    assert_equal(
        det.evaluate(_stable(String("k"), 6)).state, STATE_ACCUMULATING, "pre"
    )
    var v = det.evaluate(_stepped(String("k"), 6, 6, Float64(1.30)))
    assert_equal(v.state, STATE_ANOMALY, "ACCUMULATING -> ANOMALY")
    assert_equal(v.change_ordinal, Int64(6), "at the true boundary")


def test_normal_to_anomaly_carries_the_full_evidence() raises:
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    assert_equal(
        det.evaluate(_stable(String("k"), 12)).state, STATE_NORMAL, "pre"
    )
    var v = det.evaluate(_stepped(String("k"), 12, 8, Float64(1.25)))
    assert_equal(v.state, STATE_ANOMALY, "NORMAL -> ANOMALY")
    assert_equal(v.change_ordinal, Int64(12), "the change point's ordinal")
    assert_true(v.p_value < config.significance, "below the budget")
    assert_true(
        v.relative_shift > 0.20 and v.relative_shift < 0.30,
        String("a 25% step must report ~+25%; got ")
        + String(v.relative_shift),
    )
    assert_true(
        _contains(v.detail, String("arm=")),
        String("the verdict must name WHICH arm fired; got ") + v.detail,
    )
    assert_false(v.is_green(), "ANOMALY is not green")


def test_anomaly_is_latched_and_does_not_self_clear() raises:
    """⭐ THE PROPERTY THAT MAKES A CARD WORTH FILING.

    Re-evaluating must not quietly walk back to NORMAL, and the retained
    verdict must keep naming the SAME change point — a card whose subject
    drifts between readings cannot be closed.

    ── ⛔ WHY THIS TEST LOOKS THE WAY IT DOES: THE VERSION BEFORE IT DID NOT
    ── TEST THE LATCH AT ALL.

    The first version fired on a step, then re-evaluated a LONGER series that
    still contained the same step, and asserted the state was still ANOMALY. It
    passed. It also passed with the latch DELETED OUTRIGHT — measured, by
    replacing `if self.state == STATE_ANOMALY:` in `detector.mojo` with
    `if False and ...` and running the suite: 5 of 5 green. Of course it did: a
    refit of a series that still contains a 25% step finds the same change
    point, at the same ordinal, with the same p-value floor. Every assertion in
    it was true of a detector with no latch whatsoever.

    ⭐ THE FIX IS THE CONTROL DETECTOR. The second window is one whose evidence
    has genuinely WEAKENED — the retained window has rolled forward past the
    change point, which is what an ordinary store with retention does — and a
    SECOND detector that has never latched is fed the identical window and must
    report NORMAL. The test then asserts the two detectors DISAGREE. That
    disagreement is the latch, and it is a thing no latch-less detector can
    produce: with the latch deleted, `det` refits exactly as `control` does,
    reaches exactly NORMAL, and the assertion fails by name.

    The control assertion also keeps THIS test from silently rotting back into
    the vacuous shape: if a future change ever made the weakened window fire on
    its own, the control goes red first and says so.
    """
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    var first = det.evaluate(_stepped(String("k"), 12, 8, Float64(1.25)))
    assert_equal(first.state, STATE_ANOMALY, "fires")
    assert_true(first.change_index >= 0, "and it fitted a change point")

    # The window has rolled forward: ordinals 20..49, all at the ORIGINAL
    # level, with the step no longer inside it.
    var weakened = _stable_from(String("k"), 20, 30)

    # ── THE CONTROL. Without this the assertion below is unfalsifiable. ──
    var control = SeriesDetector(String("k"), config)
    var c = control.evaluate(weakened)
    assert_equal(
        c.state,
        STATE_NORMAL,
        String("CONTROL: a detector that never latched must call this exact")
        + String(" window NORMAL — if it does not, the latch assertion below")
        + String(" is vacuous and proves nothing. Got ")
        + c.render(),
    )

    var again = det.evaluate(weakened)
    assert_equal(
        again.state,
        STATE_ANOMALY,
        String("LATCHED: the same window the control just called NORMAL must")
        + String(" still be ANOMALY here. A detector without the latch reaches")
        + String(" NORMAL on this line. Got ")
        + again.render(),
    )
    assert_equal(
        again.change_ordinal,
        first.change_ordinal,
        "and the subject has not moved",
    )
    assert_equal(again.p_value, first.p_value, "nor has the evidence")
    assert_equal(
        again.statistic, first.statistic, "nor the statistic behind it"
    )
    assert_equal(
        again.relative_shift,
        first.relative_shift,
        "nor the magnitude the card would quote",
    )
    assert_equal(again.n_points, 30, "only the point count is refreshed")


def test_the_latch_survives_a_window_that_lost_the_change_point() raises:
    """⭐ THE SAME PROPERTY, STATED AS A DISAGREEMENT THAT WIDENS.

    A latched detector re-evaluated three times over progressively weaker
    windows must stay ANOMALY every time, while a fresh control on each of
    those windows reports NORMAL every time. Three independent chances for a
    latch-less detector to be caught, not one.
    """
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    assert_equal(
        det.evaluate(_stepped(String("k"), 12, 8, Float64(1.25))).state,
        STATE_ANOMALY,
        "fires",
    )
    var lengths: List[Int] = [20, 30, 40]
    for i in range(len(lengths)):
        var w = _stable_from(String("k"), 20, lengths[i])
        var control = SeriesDetector(String("k"), config)
        assert_equal(
            control.evaluate(w).state,
            STATE_NORMAL,
            String("CONTROL at n=")
            + String(lengths[i])
            + String(" must be NORMAL or the next assertion is vacuous"),
        )
        var v = det.evaluate(w)
        assert_equal(
            v.state,
            STATE_ANOMALY,
            String("still latched at n=")
            + String(lengths[i])
            + String("; got ")
            + v.render(),
        )
        assert_equal(
            v.change_ordinal, Int64(12), "and still about ordinal 12"
        )


def test_acknowledge_moves_the_baseline_and_reaccumulates() raises:
    """ANOMALY --acknowledge()-> ACCUMULATING. The new level must EARN normal
    rather than inherit it."""
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    var series = _stepped(String("k"), 12, 5, Float64(1.25))
    assert_equal(det.evaluate(series).state, STATE_ANOMALY, "fires")

    det.acknowledge()
    assert_equal(
        det.state, STATE_ACCUMULATING, "ANOMALY -> ACCUMULATING on acknowledge"
    )
    assert_equal(
        det.baseline_ordinal, Int64(12), "baseline moved to the change point"
    )
    var v = det.evaluate(series)
    assert_equal(
        v.state,
        STATE_ACCUMULATING,
        "only 5 post-change points, so still accumulating",
    )
    assert_equal(v.n_points, 5, "the pre-change history has left the window")


def test_acknowledge_then_enough_new_points_reaches_normal() raises:
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    assert_equal(
        det.evaluate(_stepped(String("k"), 12, 5, Float64(1.25))).state,
        STATE_ANOMALY,
        "fires",
    )
    det.acknowledge()
    var v = det.evaluate(_stepped(String("k"), 12, 14, Float64(1.25)))
    assert_equal(
        v.state, STATE_NORMAL, "the new regime, tested on its own points"
    )
    assert_equal(v.n_points, 14, "window is the post-change segment only")


def test_dismiss_returns_to_normal_and_suppresses_a_repeat() raises:
    """⭐ WITHOUT THE SUPPRESSION THIS IS AN INFINITE CARD LOOP. The next
    evaluation re-finds the identical change point and re-files the identical
    card, forever."""
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    var series = _stepped(String("k"), 12, 8, Float64(1.25))
    assert_equal(det.evaluate(series).state, STATE_ANOMALY, "fires")

    det.dismiss()
    assert_equal(det.state, STATE_NORMAL, "ANOMALY -> NORMAL on dismiss")

    var v = det.evaluate(series)
    assert_equal(
        v.state, STATE_NORMAL, "the same change point must NOT re-fire"
    )
    assert_true(
        _contains(v.detail, String("dismissed")),
        String("and the verdict must say it was suppressed; got ") + v.detail,
    )
    assert_true(
        _contains(v.render(), String("dismissed")),
        String("and it must survive into the RENDERED line — a NORMAL reached")
        + String(" only because someone dismissed a change point is not the")
        + String(" same fact as a NORMAL where nothing was found; got ")
        + v.render(),
    )
    assert_equal(
        det.baseline_ordinal,
        Int64.MIN,
        "dismiss does NOT move the baseline — the history is still in window",
    )


def test_a_dismissal_does_not_suppress_a_different_change_point() raises:
    """The suppression is pinned to ONE ordinal. A later, genuinely different
    regression must still fire."""
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    assert_equal(
        det.evaluate(_stepped(String("k"), 12, 8, Float64(1.25))).state,
        STATE_ANOMALY,
        "first fires",
    )
    det.dismiss()

    # A second, much larger step further along.
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var s = Series(String("k"))
    for i in range(20):
        s.append(Int64(i), 100.0 + pattern[i % 5])
    for i in range(10):
        s.append(Int64(20 + i), (100.0 + pattern[i % 5]) * 2.5)
    var v = det.evaluate(s)
    assert_equal(v.state, STATE_ANOMALY, "a DIFFERENT change point must fire")
    assert_true(
        v.change_ordinal != Int64(12),
        "and it must not be the dismissed one",
    )


def test_uncalibrated_on_a_nonfinite_value_and_recovery() raises:
    """ACCUMULATING/NORMAL -> UNCALIBRATED, and back once the data is readable.
    """
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    assert_equal(
        det.evaluate(_stable(String("k"), 12)).state, STATE_NORMAL, "pre"
    )

    var bad = _stable(String("k"), 12)
    bad.append(Int64(12), Float64(0.0) / Float64(0.0))
    var v = det.evaluate(bad)
    assert_equal(v.state, STATE_UNCALIBRATED, "NORMAL -> UNCALIBRATED")
    assert_false(v.is_green(), "a refusal is not a pass")
    assert_true(
        _contains(v.render(), String("NONFINITE_VALUE")),
        String("and it names the reason; got ") + v.render(),
    )

    assert_equal(
        det.evaluate(_stable(String("k"), 14)).state,
        STATE_NORMAL,
        "UNCALIBRATED -> NORMAL once the input is readable again",
    )


def test_uncalibrated_on_repeated_or_reversed_ordinals() raises:
    """Two points at one ordinal means the series key is under-specified or the
    same reading was ingested twice. Neither is repairable by guessing."""
    var config = DetectorConfig()
    var dup = Series(String("k"))
    for i in range(12):
        dup.append(Int64(i), 100.0)
    dup.append(Int64(11), 100.0)
    assert_equal(
        dup.validate(),
        SERIES_REJECT_UNORDERED,
        "a repeated ordinal is refused, not averaged",
    )
    var det = SeriesDetector(String("k"), config)
    assert_equal(
        det.evaluate(dup).state, STATE_UNCALIBRATED, "and the detector says so"
    )


def test_uncalibrated_overrides_the_latch() raises:
    """⚠ DELIBERATE. A detector cannot keep asserting a finding about data it
    can no longer read. Nothing is lost — UNCALIBRATED is a refusal, not a
    green."""
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    assert_equal(
        det.evaluate(_stepped(String("k"), 12, 8, Float64(1.25))).state,
        STATE_ANOMALY,
        "latched",
    )
    var bad = _stepped(String("k"), 12, 8, Float64(1.25))
    bad.append(Int64(99), Float64(1.0) / Float64(0.0))
    assert_equal(
        det.evaluate(bad).state,
        STATE_UNCALIBRATED,
        "ANOMALY -> UNCALIBRATED when the input stops being readable",
    )


def test_reset_returns_to_a_detector_that_has_seen_nothing() raises:
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    var series = _stepped(String("k"), 12, 8, Float64(1.25))
    assert_equal(det.evaluate(series).state, STATE_ANOMALY, "fires")
    det.acknowledge()
    det.reset()
    assert_equal(det.state, STATE_ACCUMULATING, "reset -> ACCUMULATING")
    assert_equal(
        det.baseline_ordinal, Int64.MIN, "and the whole series is in window"
    )
    assert_equal(
        det.evaluate(series).state,
        STATE_ANOMALY,
        "so the same change point is found again",
    )


def test_acknowledge_and_dismiss_refuse_outside_anomaly() raises:
    """Both are answers to a detection. Called otherwise there is nothing to
    answer, and silently doing nothing would hide a caller's bug."""
    var config = DetectorConfig()
    var det = SeriesDetector(String("k"), config)
    var _v = det.evaluate(_stable(String("k"), 12))
    var ack_raised = False
    var ack_msg = String("")
    try:
        det.acknowledge()
    except e:
        ack_raised = True
        ack_msg = String(e)
    assert_true(ack_raised, "acknowledge() on NORMAL must raise")
    # ⛔ AND IT MUST RAISE FOR THE RIGHT REASON, NAMING THE STATE. Deleting the
    # state guard entirely still ends in a raise — a NORMAL verdict has no
    # fitted change point and no bound breach, so it falls through to the
    # chart-only refusal — and a test asserting only 'it raised' cannot tell
    # the two apart. The operator then reads 'this ANOMALY is chart-only' about
    # a detector that is not in ANOMALY at all.
    assert_true(
        _contains(ack_msg, String("only an ANOMALY can be acknowledged")),
        String("the refusal must name the state it refused, not a different")
        + String(" case that happens to raise too; got ")
        + ack_msg,
    )
    assert_true(
        _contains(ack_msg, String("NORMAL")),
        String("and say which state the detector was in; got ") + ack_msg,
    )
    var dis_raised = False
    var dis_msg = String("")
    try:
        det.dismiss()
    except e:
        dis_raised = True
        dis_msg = String(e)
    assert_true(dis_raised, "dismiss() on NORMAL must raise")
    assert_true(
        _contains(dis_msg, String("only an ANOMALY can be dismissed")),
        String("same for dismiss(); got ") + dis_msg,
    )


def test_a_detector_refuses_a_series_that_is_not_its_own() raises:
    """A detector carries ONE series' latch, baseline and dismissal. Applying
    them to another series' data is not something to guess at."""
    var config = DetectorConfig()
    var det = SeriesDetector(String("mine"), config)
    var raised = False
    var msg = String("")
    try:
        var _v = det.evaluate(_stable(String("yours"), 12))
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "a key mismatch must raise")
    assert_true(
        _contains(msg, String("mine")) and _contains(msg, String("yours")),
        String("and the message must name BOTH keys; got ") + msg,
    )


def test_series_validation_covers_its_three_refusals() raises:
    var ok = _stable(String("k"), 3)
    assert_equal(ok.validate(), SERIES_OK, "a clean series passes")
    assert_equal(ok.count(), 3, "count is the number of points")

    var nameless = Series(String(""))
    nameless.append(Int64(0), 1.0)
    assert_equal(
        nameless.validate(),
        SERIES_REJECT_EMPTY_KEY,
        "an unidentified series is refused",
    )

    var nan = Series(String("k"))
    nan.append(Int64(0), Float64(0.0) / Float64(0.0))
    assert_equal(nan.validate(), SERIES_REJECT_NONFINITE, "NaN is refused")

    var backwards = Series(String("k"))
    backwards.append(Int64(5), 1.0)
    backwards.append(Int64(4), 1.0)
    assert_equal(
        backwards.validate(),
        SERIES_REJECT_UNORDERED,
        "a reversed ordinal is refused",
    )


def test_since_narrows_the_window_and_keeps_the_key() raises:
    var s = _stable(String("k"), 10)
    var narrowed = s.since(Int64(6))
    assert_equal(narrowed.count(), 4, "ordinals 6,7,8,9")
    assert_equal(narrowed.key, String("k"), "the identity is preserved")
    assert_equal(s.count(), 10, "and the original is untouched")


def test_config_refuses_an_impossible_detector() raises:
    """⛔ A `min_points` below `2*min_segment` can never admit a split, so such
    a detector would report NORMAL forever having tested nothing — a green
    light wired to no sensor."""
    var raised = False
    try:
        var _c = DetectorConfig(min_points=4, min_segment=3)
    except e:
        raised = True
    assert_true(raised, "min_points < 2*min_segment must raise")

    var floor_raised = False
    try:
        var _c = DetectorConfig(min_segment=1)
    except e:
        floor_raised = True
    assert_true(floor_raised, "a min_segment below the floor must raise")

    var sig_raised = False
    try:
        var _c = DetectorConfig(significance=Float64(0.0))
    except e:
        sig_raised = True
    assert_true(sig_raised, "a significance outside (0,1) must raise")

    var perm_raised = False
    try:
        var _c = DetectorConfig(permutations=0)
    except e:
        perm_raised = True
    assert_true(perm_raised, "zero permutations must raise")


def test_state_names_round_trip() raises:
    assert_equal(state_name(STATE_ACCUMULATING), String("ACCUMULATING"), "1")
    assert_equal(state_name(STATE_NORMAL), String("NORMAL"), "2")
    assert_equal(state_name(STATE_ANOMALY), String("ANOMALY"), "3")
    assert_equal(state_name(STATE_UNCALIBRATED), String("UNCALIBRATED"), "4")
    assert_equal(state_name(99), String("UNKNOWN_STATE"), "unknown is named")


def test_a_normal_verdict_admits_when_its_secondary_arm_did_not_run() raises:
    """⚠ THE QUIET FAILURE THIS CLOSES. At n=12 the CUSUM chart declines, so
    the NORMAL comes from ONE arm. If the rendered line did not say so, a
    single-arm NORMAL would be indistinguishable from a both-arms NORMAL, and
    the weaker verdict would be read as the stronger one."""
    var config = DetectorConfig()
    var det = SeriesDetector(String("short"), config)
    var v = det.evaluate(_stable(String("short"), 12))
    assert_equal(v.state, STATE_NORMAL, "a short stable series is NORMAL")
    assert_true(
        _contains(v.render(), String("cusum_declined=")),
        String("the rendered NORMAL must admit the chart did not run; got ")
        + v.render(),
    )


def test_the_chart_runs_on_a_long_enough_stable_series() raises:
    """A long stable series must reach NORMAL with the secondary arm having
    ACTUALLY RUN — otherwise every NORMAL in this suite would be a verdict from
    one arm with the other silently declining."""
    var config = DetectorConfig()
    var det = SeriesDetector(String("long"), config)
    var v = det.evaluate(_stable(String("long"), 34))
    assert_equal(v.state, STATE_NORMAL, "a stable long series is NORMAL")
    assert_false(
        _contains(v.detail, String("cusum_declined")),
        String("at n=34 the chart must RUN, not decline; detail was '")
        + v.detail
        + String("'"),
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
