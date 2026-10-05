# =============================================================================
# tests/test_online_api.mojo
#   ⭐ POST A POINT, GET A VERDICT — and the properties that make it the SAME
#   detector rather than a second one.
#
#   The claims under test, in the order they matter:
#
#     1. EQUIVALENCE. Points posted one at a time reach the SAME verdict — the
#        same state, the same change point, the same p-value, the same rendered
#        line — as the batch path over the same points. If this ever drifts,
#        there are two detectors and they will disagree in production.
#     2. THE CALLER HOLDS NO HISTORY. Two interleaved series, one object, and
#        neither one's state reaches the other.
#     3. A REJECTED POINT MUTATES NOTHING. Posting a `nan` must leave the
#        accumulation byte-identical, because a poisoned Welford state makes
#        every later comparison false and nothing anywhere says so.
#     4. THE REFIT CADENCE IS VISIBLE, AND A VERDICT WITH NO ARM IS NOT NORMAL.
#     5. THE LATCH SURVIVES THE RESHAPE, and `acknowledge` resets the bounds.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_anomaly import (
    AnomalyMonitor,
    BOUNDS_MIN_PRIOR,
    DEFAULT_MIN_POINTS,
    DEFAULT_REFIT_EVERY,
    DEFAULT_WINDOW_CAPACITY,
    DetectorConfig,
    NO_ARM_RULED,
    OnlineConfig,
    STATE_ACCUMULATING,
    STATE_ANOMALY,
    STATE_NORMAL,
    STATE_UNCALIBRATED,
    Series,
    SeriesDetector,
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


def _values(before: Int, after: Int, factor: Float64) -> List[Float64]:
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var out = List[Float64]()
    for i in range(before):
        out.append(100.0 + pattern[i % 5])
    for i in range(after):
        out.append((100.0 + pattern[i % 5]) * factor)
    return out^


def _batch_verdict(key: String, v: List[Float64], var config: DetectorConfig) raises -> String:
    var s = Series(key)
    for i in range(len(v)):
        s.append(Int64(i), v[i])
    var det = SeriesDetector(key, config^)
    return det.evaluate(s).render()


def test_the_online_path_reaches_the_same_verdict_as_the_batch_path() raises:
    """⭐ 1. ONE STATE MACHINE, PROVED BY COMPARING THE TWO ENTRY POINTS.

    `refit_every = 1` so the change-point arm runs on every posted point, which
    is the only configuration in which the two paths are answering the same
    question. `bound_min_prior` is set above the run length so the bounds arm
    stays unarmed on both sides — otherwise the online verdict would carry an
    extra arm the batch one cannot have, and this would be comparing two
    different things while looking like it was not.

    The comparison is on `render()`, i.e. every field a reader sees.

    ⚠ THE CONTROL IS THE ANOMALY. If both paths returned NORMAL on a series
    with nothing in it, this test would pass on any two detectors that both do
    nothing. The series carries a real step and both sides must FIND it.
    """
    var v = _values(12, 8, Float64(1.25))
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var m = AnomalyMonitor(cfg^)

    # ⚠ THE COMPARISON RUNS AT EVERY POINT AND STOPS AT THE FIRST ANOMALY, AND
    # BOTH HALVES OF THAT ARE LOAD-BEARING. Comparing only the FINAL verdict
    # would be wrong in a way that looks right: once the online detector
    # latches it keeps its first finding, while a batch fit over all 20 points
    # produces a different (later, stronger) one. Those two SHOULD differ —
    # that is the latch — so a final-verdict comparison measures the latch, not
    # the equivalence. Comparing prefix by prefix measures the equivalence.
    var compared = 0
    var fired_at = -1
    for i in range(len(v)):
        var online = m.observe(String("k"), Int64(i), v[i])
        var prefix = List[Float64]()
        for j in range(i + 1):
            prefix.append(v[j])
        var batch = _batch_verdict(String("k"), prefix, DetectorConfig())
        assert_equal(
            online.render(),
            batch,
            String("the post-a-point path and the batch path must render the")
            + String(" IDENTICAL verdict at every prefix. Diverged at point ")
            + String(i)
            + String(".\n  online: ")
            + online.render()
            + String("\n  batch : ")
            + batch,
        )
        compared += 1
        if online.state == STATE_ANOMALY:
            fired_at = i
            break

    assert_true(
        fired_at >= 0,
        String("CONTROL: the series must actually FIRE somewhere, or this")
        + String(" compared two detectors that both did nothing across ")
        + String(compared)
        + String(" prefixes"),
    )
    assert_true(
        compared >= DEFAULT_MIN_POINTS,
        String("CONTROL: and the comparison must reach past the activation")
        + String(" threshold, or every prefix compared was ACCUMULATING and")
        + String(" the equality is trivially true. Compared ")
        + String(compared),
    )
    print(
        String("online == batch at all ")
        + String(compared)
        + String(" prefixes; first ANOMALY at point ")
        + String(fired_at)
    )


def test_equivalence_also_holds_where_the_answer_is_normal() raises:
    """The same claim on the other outcome, because a step is an easy case.

    A detector that latched on anything at all would pass the test above and
    fail this one.
    """
    var v = _values(20, 0, Float64(1.0))
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var m = AnomalyMonitor(cfg^)
    var online = String("")
    for i in range(len(v)):
        online = m.observe(String("q"), Int64(i), v[i]).render()
    var batch = _batch_verdict(String("q"), v, DetectorConfig())
    assert_true(
        _contains(online, String("NORMAL")),
        String("CONTROL: this series must be NORMAL; got ") + online,
    )
    assert_equal(online, batch, "and both paths must say so identically")


def test_the_caller_holds_no_history_and_series_do_not_leak() raises:
    """⭐ 2. ONE OBJECT, MANY SERIES, NO CROSS-TALK.

    Two series interleaved into one monitor. One of them steps; the other does
    not. The stepping one must fire and the flat one must not — and neither
    caller ever handed the monitor a window.
    """
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var m = AnomalyMonitor(cfg^)
    var stepped = _values(12, 8, Float64(1.25))
    var flat = _values(20, 0, Float64(1.0))
    for i in range(20):
        _ = m.observe(String("hot"), Int64(i), stepped[i])
        _ = m.observe(String("cold"), Int64(i), flat[i])
    assert_equal(m.series_count(), 2, "two series were created on first sight")
    assert_equal(
        m.verdict_for(String("hot")).state,
        STATE_ANOMALY,
        "the stepped series fired",
    )
    assert_equal(
        m.verdict_for(String("cold")).state,
        STATE_NORMAL,
        "and the flat one did not — a latch that leaked would fire here",
    )
    assert_equal(m.observed_count(String("hot")), 20, "20 points accepted")
    assert_equal(m.observed_count(String("cold")), 20, "and 20 on the other")

    var raised = False
    try:
        _ = m.verdict_for(String("never-posted"))
    except e:
        raised = True
    assert_true(
        raised,
        "asking about a key that was never posted must RAISE — a default"
        " ACCUMULATING verdict would make a typo read as a young series",
    )


def test_a_rejected_point_mutates_nothing() raises:
    """⭐ 3. THE STATE IS NOT TOUCHED BY A POINT THAT WAS REFUSED.

    A `nan` folded into Welford poisons the mean and the variance permanently:
    every subsequent comparison against the bound is FALSE and the detector has
    silently stopped detecting. So the refusal has to happen BEFORE the
    accumulation, and this asserts the accumulation is byte-identical across it.
    """
    var m = AnomalyMonitor()
    for i in range(BOUNDS_MIN_PRIOR + 2):
        _ = m.observe(String("s"), Int64(i), 100.0 + Float64(i % 3))
    var before = m.bounds_of(String("s"))
    var accepted_before = m.observed_count(String("s"))

    var nan = Float64(0.0) / Float64(0.0)
    var v = m.observe(String("s"), Int64(999), nan)
    assert_equal(
        v.state, STATE_UNCALIBRATED, "a non-finite value is UNCALIBRATED"
    )
    assert_equal(
        v.detail, String("NONFINITE_VALUE"), "and names its reason"
    )

    var after = m.bounds_of(String("s"))
    assert_equal(
        after.n_prior, before.n_prior, "the point count did not move"
    )
    assert_equal(after.mean_prior, before.mean_prior, "nor the mean, to the bit")
    assert_equal(
        after.sigma_prior, before.sigma_prior, "nor the scale, to the bit"
    )
    assert_true(
        after.sigma_prior > 0.0,
        "and the scale is still a real number, not nan — which is what a"
        " poisoned Welford would leave behind",
    )
    assert_equal(
        m.observed_count(String("s")),
        accepted_before,
        "the rejected point is not counted as accepted",
    )
    assert_equal(
        m.rejected_count(String("s")), 1, "but it IS counted as rejected —"
        " a series refusing everything must not look idle"
    )

    # And a REPEATED ordinal, the other refusal.
    var v2 = m.observe(String("s"), Int64(0), 100.0)
    assert_equal(v2.state, STATE_UNCALIBRATED, "a stale ordinal is refused")
    assert_equal(
        v2.detail,
        String("ORDINALS_NOT_STRICTLY_INCREASING"),
        "and names that reason instead",
    )
    assert_equal(m.rejected_count(String("s")), 2, "two refusals now")
    var after2 = m.bounds_of(String("s"))
    assert_equal(
        after2.mean_prior, before.mean_prior, "still byte-identical"
    )


def test_a_verdict_with_no_arm_is_uncalibrated_not_normal() raises:
    """⭐ 4. THE FAIL-QUIET GATE, REFUSED.

    `refit_every = 0` (never refit) and a bounds warm-up longer than the run,
    so past the activation threshold EVERY arm is silent: the primary did not
    run, the chart declines, the bound has no ruling. NORMAL here would be a
    green light wired to no sensor.
    """
    var cfg = OnlineConfig(DetectorConfig(), 64, 0, Float64(5.0), 10000)
    var m = AnomalyMonitor(cfg^)
    var v = m.observe(String("z"), Int64(0), 100.0)
    for i in range(1, DEFAULT_MIN_POINTS + 3):
        v = m.observe(String("z"), Int64(i), 100.0 + Float64(i % 3))
    assert_equal(v.arms_ruled, 0, "no arm produced a ruling")
    assert_equal(
        v.state,
        STATE_UNCALIBRATED,
        String("with every arm silent the state must be UNCALIBRATED, never")
        + String(" NORMAL. Got ")
        + v.render(),
    )
    assert_true(
        _contains(v.detail, NO_ARM_RULED),
        String("and it must say which refusal this is; got ") + v.detail,
    )
    assert_false(v.is_green(), "and UNCALIBRATED is not green")


def test_the_refit_cadence_is_visible_in_the_verdict() raises:
    """4b. A POINT THAT DID NOT GET THE PRIMARY ARM SAYS SO.

    With `refit_every = 8`, seven of every eight verdicts are reached without
    the change-point arm. That is a legitimate design — the arm is O(n^2 * P) —
    but a reader who cannot tell those verdicts apart from fully-armed ones has
    been handed the weaker dressed as the stronger.
    """
    var cfg = OnlineConfig(DetectorConfig(), 64, 8, Float64(5.0), 22)
    var m = AnomalyMonitor(cfg^)
    var with_primary = 0
    var without = 0
    for i in range(32):
        var v = m.observe(String("c"), Int64(i), 100.0 + Float64(i % 5))
        if v.state == STATE_ACCUMULATING:
            continue
        if _contains(v.detail, String("changepoint_not_run=refit_cadence")):
            without += 1
        else:
            with_primary += 1
    assert_true(
        with_primary > 0, "some points DID get the primary arm"
    )
    assert_true(
        without > with_primary,
        String("and most did not, at a cadence of 8: ")
        + String(without)
        + String(" without vs ")
        + String(with_primary)
        + String(" with"),
    )
    # And the explicit escape hatch runs it regardless of cadence.
    var forced = m.refit(String("c"))
    assert_false(
        _contains(forced.detail, String("changepoint_not_run")),
        String("an explicit refit() must run the primary arm; got ")
        + forced.detail,
    )
    assert_true(forced.change_index >= 0, "and it produced a fit")


def test_the_latch_survives_the_reshape() raises:
    """⭐ 5. ONE LATCH, REACHED THROUGH THE NEW DOOR.

    Fire on a step, then post twenty stable points at the ORIGINAL level. A
    control monitor fed only those stable points reports NORMAL; the latched
    one must not.
    """
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var m = AnomalyMonitor(cfg^)
    var v = _values(12, 8, Float64(1.25))
    for i in range(len(v)):
        _ = m.observe(String("k"), Int64(i), v[i])
    assert_equal(
        m.verdict_for(String("k")).state, STATE_ANOMALY, "fires"
    )

    var cfg2 = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var control = AnomalyMonitor(cfg2^)
    var tail = _values(20, 0, Float64(1.0))
    for i in range(len(tail)):
        _ = control.observe(String("k"), Int64(100 + i), tail[i])
    assert_equal(
        control.verdict_for(String("k")).state,
        STATE_NORMAL,
        "CONTROL: a monitor that never latched calls these points NORMAL —"
        " without this the assertion below is vacuous",
    )

    var last = m.observe(String("k"), Int64(100), tail[0])
    for i in range(1, len(tail)):
        last = m.observe(String("k"), Int64(100 + i), tail[i])
    assert_equal(
        last.state,
        STATE_ANOMALY,
        String("STILL LATCHED on the online path; got ") + last.render(),
    )


def test_acknowledge_resets_the_running_bounds() raises:
    """⭐ 5b. ACKNOWLEDGING A LEVEL CHANGE MUST MOVE THE BOUNDS TOO.

    Bounds accumulated ACROSS a step describe a bimodal history that the
    operator has just declared over. Keeping them would leave the series with a
    mean between its two levels and a variance inflated by the step — deaf on
    the new regime for as long as the old points dominate.
    """
    # `bound_min_prior` above the run length, so the ANOMALY here is the
    # CHANGE-POINT arm's and the baseline moves to a FITTED ordinal. The
    # bounds-only case is the next test, and it is a different code path.
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var m = AnomalyMonitor(cfg^)
    var v = _values(12, 8, Float64(1.25))
    for i in range(len(v)):
        _ = m.observe(String("k"), Int64(i), v[i])
    var fired = m.verdict_for(String("k"))
    assert_equal(fired.state, STATE_ANOMALY, "fires")
    assert_true(
        fired.changepoint_fired,
        String("CONTROL: this must be the CHANGE-POINT arm's finding, not the")
        + String(" bounds arm's, or the baseline below moves for a different")
        + String(" reason than this test claims. Got ")
        + fired.render(),
    )

    var straddling = m.bounds_of(String("k"))
    assert_true(
        straddling.mean_prior > 105.0 and straddling.mean_prior < 120.0,
        String("CONTROL: before acknowledging, the mean sits BETWEEN the two")
        + String(" levels (100 and 125) — that is the state being repaired.")
        + String(" Got ")
        + String(straddling.mean_prior),
    )

    m.acknowledge(String("k"))
    var after = m.bounds_of(String("k"))
    assert_equal(
        after.n_prior,
        8,
        String("the retained window is the POST-change segment only — the 8")
        + String(" points at or after ordinal 12. Got ")
        + String(after.n_prior),
    )
    assert_true(
        after.mean_prior > 120.0,
        String("after acknowledging, the accumulation must describe the NEW")
        + String(" level (~125) only; got ")
        + String(after.mean_prior),
    )
    assert_true(
        after.sigma_prior > 0.0 and after.sigma_prior < straddling.sigma_prior,
        String("and the scale must be a real, SMALLER number — the step is no")
        + String(" longer inside it: was ")
        + String(straddling.sigma_prior)
        + String(", now ")
        + String(after.sigma_prior),
    )
    assert_equal(
        m.verdict_for(String("k")).state,
        STATE_ACCUMULATING,
        "and the series re-enters ACCUMULATING on its new level",
    )


def test_acknowledging_a_bounds_only_anomaly_uses_the_breaching_point() raises:
    """⭐ REGRESSION. A FIT THAT RAN IS NOT A FIT THAT FIRED.

    ── THE DEFECT THIS PINS.

    A 13-point series (12 stable, then one point 25% higher) reaches ANOMALY
    through the RUNNING-BOUNDS arm at z = 15.3. The change-point arm ran on the
    same evaluation and found NOTHING — p = 0.763 — but a non-significant fit
    still populates `change_index` and `change_ordinal` with its best split,
    which here is **ordinal 3**. An `acknowledge()` that moved the baseline to
    that ordinal would throw away three real points and keep ten that straddle
    the actual step, leaving the 'new baseline' describing the OLD level plus
    the outlier: a mean of 102.25 where the new level is 122.5.

    ⛔ THE POINT IS NOT THE ARITHMETIC, IT IS THAT NOTHING WOULD SAY SO. A
    verdict rendering `at_ordinal=3` on a boundary the detector had explicitly
    declined to assert at p = 0.763 would put the wrong commit in any issue
    written from that line.

    The fix is `Verdict.changepoint_fired`: `acknowledge` uses the fitted
    ordinal ONLY when the arm fired, the breaching point when the bounds arm
    fired, and RAISES for a chart-only anomaly where no ordinal means 'the new
    regime starts here'.
    """
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 5)
    var m = AnomalyMonitor(cfg^)
    var v = _values(12, 8, Float64(1.25))
    var fired_at = -1
    for i in range(len(v)):
        var r = m.observe(String("b"), Int64(i), v[i])
        if r.state == STATE_ANOMALY:
            fired_at = i
            break
    assert_equal(
        fired_at,
        12,
        "the bounds arm fires on the first post-change point",
    )
    var verdict = m.verdict_for(String("b"))
    assert_true(verdict.bound_breached, "and it is the BOUNDS arm that fired")
    assert_false(
        verdict.changepoint_fired,
        String("CONTROL: the change-point arm must NOT have fired here — the")
        + String(" whole defect is that its unfired fit was used anyway. Got ")
        + verdict.render(),
    )
    assert_true(
        verdict.change_index >= 0,
        String("CONTROL: and it must still have RUN and produced a split —")
        + String(" that stale ordinal is the trap. change_index=")
        + String(verdict.change_index),
    )
    assert_false(
        _contains(verdict.render(), String("at_ordinal=")),
        String("the rendered line must NOT cite a change point the detector")
        + String(" declined to assert; got ")
        + verdict.render(),
    )

    m.acknowledge(String("b"))
    var after = m.bounds_of(String("b"))
    assert_equal(
        after.n_prior,
        1,
        String("the new baseline is the BREACHING point (ordinal 12), so")
        + String(" exactly one point is retained, not ten straddling the")
        + String(" step. Got ")
        + String(after.n_prior),
    )
    assert_true(
        after.mean_prior > 120.0,
        String("and the accumulation now describes the NEW level. Before the")
        + String(" fix this was 102.25 — the old level plus the outlier. Got ")
        + String(after.mean_prior),
    )


def test_an_unknown_key_cannot_be_acknowledged_into_existence() raises:
    """Acknowledging a key nobody posted is a typo, and creating it would make
    the typo permanent and silent."""
    var m = AnomalyMonitor()
    var raised = False
    try:
        m.acknowledge(String("typo"))
    except e:
        raised = True
    assert_true(raised, "acknowledge on an unknown key raises")
    assert_equal(m.series_count(), 0, "and creates nothing")


def test_a_window_smaller_than_the_activation_threshold_is_refused() raises:
    """A detector that can never activate is a progress bar wired to nothing.

    ⛔ REFUSED AT CONSTRUCTION rather than clamped, so the error lands where the
    number was written.
    """
    var raised = False
    try:
        var cfg = OnlineConfig(DetectorConfig(), DEFAULT_MIN_POINTS - 1, 1)
        var m = AnomalyMonitor(cfg^)
        _ = m.observe(String("x"), Int64(0), 1.0)
    except e:
        raised = True
    assert_true(
        raised,
        String("window_capacity below min_points must be refused"),
    )



# =============================================================================
# ⛔ THE SHIPPED DEFAULTS, EXERCISED BY A MONITOR THAT WAS HANDED NONE.
#
# Every other test in this file passes `refit_every` and `window_capacity`
# explicitly, so without this section NOTHING here would drive
# `AnomalyMonitor()` — the constructor a caller actually uses. Two mutations
# show the gap: setting `DEFAULT_REFIT_EVERY` to 0 makes the PRIMARY arm never
# run on `observe()` at all, and `DEFAULT_WINDOW_CAPACITY` could be anything,
# because the trim it guards would be executed by no test in the suite.
#
# ⚠ THE CONFIGS BELOW ARE DELIBERATELY DEFAULT-CONSTRUCTED. A test that spells
# the number it is pinning cannot detect that the shipped number moved.
# =============================================================================


def test_the_default_cadence_actually_runs_the_primary_arm() raises:
    """⛔ THE POST-A-POINT PATH'S PRIMARY ARM, ON THE SHIPPED DEFAULT.

    `AnomalyMonitor()` — no config, the way the API is meant to be called. Over
    40 posted points the change-point arm must run on a KNOWN cadence, and both
    halves of that are load-bearing:

      * it must run AT ALL. At `refit_every = 0` it never does: `do_refit` is
        never set, `cp_fired` is permanently False, and from the 21st point on
        the armed bound alone keeps `arms_ruled == 1`, so the series reads
        NORMAL and `is_green()` forever with the primary detector never having
        executed. That is a green light wired to one sensor out of two.
      * it must run on a CADENCE rather than every point. The arm is
        O(W^2 * P); at `refit_every = 1` `observe` becomes the slowest call in
        a hot ingest path, which is the cost the cadence exists to avoid.

    The counts are derived, not chosen: refits land at observed = 8, 16, 24, 32
    and 40, of which the first is still below `min_points` and reports
    ACCUMULATING, so 4 of the 31 post-activation verdicts carry the primary arm
    and 27 say they did not get it.
    """
    var m = AnomalyMonitor()
    var with_primary = 0
    var without = 0
    var accumulating = 0
    for i in range(40):
        var v = m.observe(String("d"), Int64(i), 100.0 + Float64(i % 5))
        if v.state == STATE_ACCUMULATING:
            accumulating += 1
            continue
        if _contains(v.detail, String("changepoint_not_run=refit_cadence")):
            without += 1
        else:
            with_primary += 1
    assert_equal(
        accumulating,
        DEFAULT_MIN_POINTS - 1,
        String("CONTROL: the activation boundary is where it always was, so")
        + String(" the two counts below are over the same 31 verdicts. Got ")
        + String(accumulating),
    )
    assert_true(
        with_primary > 0,
        String("⛔ THE PRIMARY ARM MUST RUN ON THE SHIPPED DEFAULT. At")
        + String(" refit_every=0 it never runs and every verdict is reached")
        + String(" by the bounds arm alone while still reporting NORMAL. Got ")
        + String(with_primary)
        + String(" of 31 post-activation verdicts carrying it."),
    )
    assert_equal(
        with_primary,
        4,
        String("and it must run on the SHIPPED CADENCE of ")
        + String(DEFAULT_REFIT_EVERY)
        + String(": over 40 posted points that is refits at 8/16/24/32/40, of")
        + String(" which 4 are past the activation threshold. Got ")
        + String(with_primary)
        + String(" with / ")
        + String(without)
        + String(" without."),
    )
    assert_equal(
        without,
        27,
        String("and the other 27 must SAY the primary arm did not run — a")
        + String(" reader who cannot tell a cadence-skipped verdict from a")
        + String(" fully-armed one has been handed the weaker dressed as the")
        + String(" stronger. Got ")
        + String(without),
    )
    assert_equal(
        DEFAULT_REFIT_EVERY,
        8,
        String("and the cadence the counts above were derived from is the one")
        + String(" the module ships; got ")
        + String(DEFAULT_REFIT_EVERY),
    )


def test_the_retained_window_is_bounded_and_the_bound_is_enforced() raises:
    """⛔ THE TRIM IS EXECUTED HERE, AND NOWHERE ELSE IN THIS SUITE.

    `online.mojo`'s header calls this bound "a real limit" and the reason the
    online and batch paths may legitimately diverge — and every other monitor
    in this suite is built with capacity 64 and driven with at most 40 points,
    so `while len(self.window) > self.config.window_capacity: pop(0)` never
    ran. Three mutations of it (`while False`, `>` -> `>=`, and shrinking the
    default so the trim actually fires) all left the suite green.

    ⭐ THE ASSERTION IS AN EQUALITY, BOTH SIDES OF IT. `observed_count` says
    the points really were posted — without that a monitor that dropped
    everything would pass — and `n_points` says the window did not grow with
    them.
    """
    # ── half 1: an EXPLICIT capacity, so the trim is on the path ──
    var cfg = OnlineConfig(DetectorConfig(), 24, 1, Float64(5.0), 1000)
    var m = AnomalyMonitor(cfg^)
    var v = m.observe(String("w"), Int64(0), 100.0)
    for i in range(1, 60):
        v = m.observe(String("w"), Int64(i), 100.0 + Float64(i % 7) * 0.5)
    assert_equal(
        m.observed_count(String("w")),
        60,
        String("CONTROL: all 60 points were accepted, so the window count")
        + String(" below is a TRIM and not a refusal. Got ")
        + String(m.observed_count(String("w"))),
    )
    assert_equal(
        v.n_points,
        24,
        String("⛔ THE RETAINED WINDOW IS CAPPED AT window_capacity. 60 points")
        + String(" posted, 24 retained. An unbounded window is unbounded")
        + String(" per-series memory and a change-point arm whose stated")
        + String(" O(W^2*P) cost becomes unbounded in the series length. Got ")
        + String(v.n_points),
    )

    # ⭐ AND IT IS THE *LAST* 24, NOT MERELY 24 OF THEM. A cap that kept the
    # OLDEST points would satisfy the count above and would be a detector
    # frozen on the series' first minute. Proved by rendering the same window
    # through the batch path: with the bounds arm held unarmed on both sides,
    # the two renders are comparable field by field.
    var tail = List[Float64]()
    for i in range(36, 60):
        tail.append(100.0 + Float64(i % 7) * 0.5)
    assert_equal(
        v.render(),
        _batch_verdict(String("w"), tail, DetectorConfig()),
        String("the retained window must BE the last 24 posted points.\n")
        + String("  online: ")
        + v.render()
        + String("\n  batch(last 24): ")
        + _batch_verdict(String("w"), tail, DetectorConfig()),
    )
    var early = List[Float64]()
    for i in range(0, 24):
        early.append(100.0 + Float64(i % 7) * 0.5)
    assert_true(
        v.render() != _batch_verdict(String("w"), early, DetectorConfig()),
        String("CONTROL: and it is NOT the first 24, or the assertion above")
        + String(" would hold for a window that never slid at all"),
    )

    # ── half 2: the SHIPPED default capacity, which no test drove ──
    var m2 = AnomalyMonitor()
    var v2 = m2.observe(String("dw"), Int64(0), 100.0)
    for i in range(1, 100):
        v2 = m2.observe(String("dw"), Int64(i), 100.0 + Float64(i % 5))
    assert_equal(
        m2.observed_count(String("dw")),
        100,
        String("CONTROL: 100 points accepted on the default monitor"),
    )
    assert_equal(
        v2.n_points,
        DEFAULT_WINDOW_CAPACITY,
        String("and the DEFAULT monitor retains exactly")
        + String(" DEFAULT_WINDOW_CAPACITY points out of 100 posted. Got ")
        + String(v2.n_points)
        + String(" against a default of ")
        + String(DEFAULT_WINDOW_CAPACITY),
    )
    assert_equal(
        DEFAULT_WINDOW_CAPACITY,
        64,
        String("and the shipped capacity is 64 — the number the header's")
        + String(" O(W) and O(W^2*P) cost statements are written about; got ")
        + String(DEFAULT_WINDOW_CAPACITY),
    )



# =============================================================================
# ⛔ WHAT `arms_ruled` COUNTS, AND WHAT AN ARM SAYS WHEN IT DECLINES.
#
# `arms_ruled` is the field that decides UNCALIBRATED-vs-NORMAL — the whole
# fail-quiet guard this module is built around — and covering only its
# `arms == 0` case, on a path where the chart declined, exercises NEITHER of
# its two non-trivial rules. Both could be broken with the suite green:
# counting the chart while it is only ADVISORY (over-count) or dropping the
# armed bound (under-count). This section covers both.
#
# The same gap covered the BOUNDS side of the decline vocabulary. `bounds.mojo`
# states the rule and `detector.mojo` implements it, and all of it could be
# deleted at 9/9 green — the exact "an arm that quietly did not run and an arm
# that ran and found nothing must not be the same bytes" defect that the CUSUM
# side already had a test for.
# =============================================================================


def test_arms_ruled_counts_only_the_arms_that_actually_ruled() raises:
    """⭐ BOTH NON-TRIVIAL RULES, ON ONE VERDICT WHERE EACH IS DECISIVE.

    `refit_every = 0` so the primary arm does not run; 30 points so the bound
    IS armed and the chart HAS a reference. That makes the expected count
    exactly ONE, and it is one only if both rules hold:

      * the ADVISORY chart is not counted. It ran and it declined nothing —
        the controls below prove that — so a rule that forgot to consult
        `cusum_arms_verdict` would count it and render `arms=2`.
      * the ARMED bound IS counted. Drop that and the count is 0, which turns
        this NORMAL into UNCALIBRATED.

    ⚠ THE CONTROLS ARE WHAT PUT BOTH RULES ON THE PATH. Without
    `not cusum_declined` the chart might simply have declined, and without
    `bound_armed` the bound might simply have been unarmed; in either case the
    count would be 1 for a reason that has nothing to do with the rule.
    """
    var cfg = OnlineConfig(DetectorConfig(), 64, 0, Float64(5.0), BOUNDS_MIN_PRIOR)
    var m = AnomalyMonitor(cfg^)
    var v = m.observe(String("a"), Int64(0), 100.0)
    for i in range(1, 30):
        v = m.observe(String("a"), Int64(i), 100.0 + Float64(i % 5))

    assert_true(
        v.bound_armed,
        String("CONTROL: the bound must be ARMED, or the rule that counts it")
        + String(" is not on this path at all. Got ")
        + v.render(),
    )
    assert_false(
        _contains(v.detail, String("cusum_declined=")),
        String("CONTROL: the chart must have RUN and declined nothing, or the")
        + String(" advisory rule is not on this path either. Got ")
        + v.detail,
    )
    assert_true(
        _contains(v.detail, String("changepoint_not_run=refit_cadence")),
        String("CONTROL: and the primary arm did not run. Got ") + v.detail,
    )
    assert_equal(
        v.arms_ruled,
        1,
        String("EXACTLY ONE arm ruled: the bound. The chart RAN but is")
        + String(" ADVISORY, so it counts zero; counting it here is a verdict")
        + String(" claiming two independent rulings where there is one. Got ")
        + v.render(),
    )
    assert_equal(
        v.state,
        STATE_NORMAL,
        String("and one arm is enough for a ruling; got ") + v.render(),
    )

    # ── the other side of the flag: ARM the chart and the count moves ──
    var cfg2 = OnlineConfig(
        DetectorConfig(10, 5, 999, 0.0122, 0.5, 5.0, True),
        64, 0, Float64(5.0), BOUNDS_MIN_PRIOR,
    )
    var m2 = AnomalyMonitor(cfg2^)
    var v2 = m2.observe(String("b"), Int64(0), 100.0)
    for i in range(1, 30):
        v2 = m2.observe(String("b"), Int64(i), 100.0 + Float64(i % 5))
    assert_equal(
        v2.arms_ruled,
        2,
        String("with `cusum_arms_verdict = True` the SAME points give TWO")
        + String(" ruling arms — which is what makes the count above a")
        + String(" property of the flag and not of the data. Got ")
        + v2.render(),
    )


def test_the_bounds_arm_says_which_refusal_it_made() raises:
    """⛔ TWO DIFFERENT SILENCES, TWO DIFFERENT WORDS.

    'the bound had too few points to have a scale' and 'the bound had a scale
    of zero' are different facts about the instrument, and a record that spells
    them the same way has thrown away the difference. The whole vocabulary —
    the record in `detector.mojo` and the word chosen in `bounds.mojo` — could
    be deleted or collapsed onto one constant with all nine tests green.
    """
    # ── TOO FEW PRIOR POINTS ──
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), BOUNDS_MIN_PRIOR)
    var m = AnomalyMonitor(cfg^)
    var v = m.observe(String("few"), Int64(0), 100.0)
    for i in range(1, 12):
        v = m.observe(String("few"), Int64(i), 100.0 + Float64(i % 5))
    assert_false(v.bound_armed, "eleven priors is below the warm-up")
    assert_true(
        _contains(v.detail, String("bounds_declined=too_few_prior_points")),
        String("an unarmed bound must SAY it did not rule, and why. Got ")
        + v.render(),
    )

    # ── A SCALE OF ZERO, past the warm-up ──
    var cfg2 = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), BOUNDS_MIN_PRIOR)
    var m2 = AnomalyMonitor(cfg2^)
    var v2 = m2.observe(String("flat"), Int64(0), 42.0)
    for i in range(1, 30):
        v2 = m2.observe(String("flat"), Int64(i), 42.0)
    assert_false(v2.bound_armed, "a constant history has no scale")
    assert_true(
        v2.bound_z == 0.0,
        String("and no z was computed; got ") + String(v2.bound_z),
    )
    assert_true(
        _contains(v2.detail, String("bounds_declined=zero_scale")),
        String("⛔ AND IT IS THE *OTHER* WORD. 29 priors is well past the")
        + String(" warm-up, so reporting `too_few_prior_points` here would be")
        + String(" a false statement about why the arm is silent. Got ")
        + v2.render(),
    )
    assert_false(
        _contains(v2.detail, String("too_few_prior_points")),
        String("the two refusals must not collapse onto one word; got ")
        + v2.detail,
    )


def test_bounds_of_reports_unarmed_when_the_arm_would_not_rule() raises:
    """⛔ `bounds_of` IS AN INSTRUMENT READING, NOT A REASSURANCE.

    `test_store_seam` asserts `a.armed` as an anti-vacuous CONTROL on a
    comparison of two accumulations — and hardcoding `armed = True` here left
    that control permanently green while making it meaningless. A control that
    cannot fail is not a control, so the NEGATIVE cases are pinned here.
    """
    # too few priors
    var m = AnomalyMonitor()
    for i in range(5):
        _ = m.observe(String("s"), Int64(i), 100.0 + Float64(i))
    var few = m.bounds_of(String("s"))
    assert_equal(few.n_prior, 5, "five points in")
    assert_false(
        few.armed,
        String("⛔ five priors is below the warm-up, so this bound would rule")
        + String(" on nothing and must not report itself ARMED"),
    )

    # a scale of zero
    var m2 = AnomalyMonitor()
    for i in range(30):
        _ = m2.observe(String("f"), Int64(i), 7.0)
    var flat = m2.bounds_of(String("f"))
    assert_equal(flat.n_prior, 30, "thirty points in")
    assert_true(flat.sigma_prior == 0.0, "and no dispersion at all")
    assert_false(
        flat.armed,
        String("a bound with no scale would make every last-digit flicker")
        + String(" infinitely many sigmas; it must not report itself ARMED"),
    )

    # ⭐ THE POSITIVE CONTROL. Without it the two assertions above would hold
    # for a `bounds_of` that reported UNARMED unconditionally.
    var m3 = AnomalyMonitor()
    for i in range(30):
        _ = m3.observe(String("v"), Int64(i), 100.0 + Float64(i % 5))
    var live = m3.bounds_of(String("v"))
    assert_true(
        live.armed,
        String("CONTROL: 30 real points with dispersion DO arm the bound, or")
        + String(" the two refusals above prove nothing"),
    )
    assert_true(
        live.lower() < live.mean_prior and live.upper() > live.mean_prior,
        String("and the limits bracket the mean; got ")
        + String(live.lower())
        + String(" .. ")
        + String(live.upper()),
    )


def test_refit_resets_the_cadence_counter() raises:
    """`refit()` says it resets the cadence, "so an explicit refit is not
    immediately followed by an automatic one". Nothing tested that sentence.

    12 points leaves the counter at 4 of 8. An explicit refit must put it back
    to 0, so the next four points are all cadence-skipped — and the four AFTER
    those must reach the cadence again, which is the control proving the
    counter is live rather than stuck.
    """
    var cfg = OnlineConfig(DetectorConfig(), 64, 8, Float64(5.0), 1000)
    var m = AnomalyMonitor(cfg^)
    var v = m.observe(String("r"), Int64(0), 100.0)
    for i in range(1, 12):
        v = m.observe(String("r"), Int64(i), 100.0 + Float64(i % 5))
    _ = m.refit(String("r"))
    for i in range(12, 16):
        v = m.observe(String("r"), Int64(i), 100.0 + Float64(i % 5))
    assert_true(
        _contains(v.detail, String("changepoint_not_run=refit_cadence")),
        String("four points after an explicit refit is 4 of 8, so the primary")
        + String(" arm must NOT have run. If refit() left the counter at 4")
        + String(" this is the 8th and it runs. Got ")
        + v.render(),
    )
    for i in range(16, 20):
        v = m.observe(String("r"), Int64(i), 100.0 + Float64(i % 5))
    assert_false(
        _contains(v.detail, String("changepoint_not_run")),
        String("CONTROL: and four more DOES reach the cadence, or the")
        + String(" assertion above holds for a counter that never advances.")
        + String(" Got ")
        + v.render(),
    )


def test_dismiss_refreshes_the_cached_verdict() raises:
    """A dismissal that does not reach `verdict_for` is a dismissal the caller
    cannot see. The state machine moves to NORMAL; the cached verdict the
    façade hands out must move with it, or the next reader is told ANOMALY
    about a finding an operator has already closed."""
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var m = AnomalyMonitor(cfg^)
    var v = _values(12, 8, Float64(1.25))
    for i in range(len(v)):
        _ = m.observe(String("k"), Int64(i), v[i])
    assert_equal(
        m.verdict_for(String("k")).state,
        STATE_ANOMALY,
        "CONTROL: it fired, or there is nothing to dismiss",
    )
    m.dismiss(String("k"))
    assert_equal(
        m.verdict_for(String("k")).state,
        STATE_NORMAL,
        String("⛔ `verdict_for` must not keep returning the dismissed")
        + String(" ANOMALY; got ")
        + m.verdict_for(String("k")).render(),
    )


def test_reset_series_resets_the_running_bounds_too() raises:
    """"Back to a detector that has seen nothing at all" — including the
    accumulation. Bounds that survive a reset describe a history the caller has
    just declared gone, and the arm would judge the new regime against it."""
    var m = AnomalyMonitor()
    for i in range(30):
        _ = m.observe(String("q"), Int64(i), 100.0 + Float64(i % 5))
    assert_true(
        m.bounds_of(String("q")).armed,
        "CONTROL: armed before the reset, or the reset proves nothing",
    )
    m.reset_series(String("q"))
    assert_equal(
        m.observed_count(String("q")), 0, "no points"
    )
    assert_equal(
        m.bounds_of(String("q")).n_prior,
        0,
        String("⛔ AND NO ACCUMULATION. Bounds surviving a reset would judge")
        + String(" the new regime against a history the caller declared over.")
        + String(" Got n_prior=")
        + String(m.bounds_of(String("q")).n_prior),
    )
    assert_false(
        m.bounds_of(String("q")).armed, "and therefore unarmed again"
    )


def test_an_anomaly_line_always_reports_the_chart() raises:
    """The ANOMALY line carries `cusum=` whether or not the chart fired.

    ⚠ THAT IS THE POINT: the chart is ADVISORY by default, so a reader of a
    change-point ANOMALY needs to see whether the secondary arm agreed. A line
    that omits it makes 'the chart was quiet' and 'the chart was not reported'
    the same bytes.
    """
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var m = AnomalyMonitor(cfg^)
    var v = _values(12, 8, Float64(1.25))
    var last = m.observe(String("k"), Int64(0), v[0])
    for i in range(1, len(v)):
        last = m.observe(String("k"), Int64(i), v[i])
    assert_equal(
        last.state, STATE_ANOMALY, "CONTROL: it fired"
    )
    assert_true(
        _contains(last.render(), String(" cusum=")),
        String("every ANOMALY line reports the secondary arm's finding; got ")
        + last.render(),
    )


def test_an_empty_series_key_is_refused() raises:
    """A key that addresses nothing cannot carry a latch, an acknowledgement or
    a dismissal — every one of those is 'about' a series. Creating a slot for
    it would make the caller's bug permanent and silent."""
    var m = AnomalyMonitor()
    var raised = False
    var msg = String("")
    try:
        _ = m.observe(String(""), Int64(0), 1.0)
    except e:
        raised = True
        msg = String(e)
    assert_true(raised, "observe() with an empty key must raise")
    assert_true(
        _contains(msg, String("empty series key")),
        String("and say so; got ") + msg,
    )
    assert_equal(m.series_count(), 0, "and create nothing")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
