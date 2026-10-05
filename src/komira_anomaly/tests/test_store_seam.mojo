# =============================================================================
# tests/test_store_seam.mojo
#   THE STORE SEAM: what a posted point does on its way to rest, and what has
#   to be true for a restarted monitor to be the same monitor.
#
#   ⛔ THE PROPERTY THIS FILE EXISTS FOR: REPLAY REBUILDS THE SAME STATE.
#   Running bounds are accumulated in memory. If the accumulation and the
#   durable record can disagree, then after any restart the detector's idea of
#   normal is a thing no stored data supports, and nobody can ever reconstruct
#   why an alert was raised. Everything else here is in service of that.
#
#   THREE CONFORMERS, not one. A trait proved implementable by a single type
#   is a trait proved implementable by that type. `InMemoryPointStore` ships in
#   the library; `RefusingStore` and `RetentionStore` are written here because
#   each expresses a behaviour the seam explicitly ALLOWS and the monitor has
#   to survive — a store that rejects a write, and a store that returns fewer
#   points than it was given.
# =============================================================================

from std.collections.dict import Dict

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_anomaly import (
    AnomalyMonitor,
    BOUNDS_MIN_PRIOR,
    DetectorConfig,
    InMemoryPointStore,
    MeasurementStore,
    OnlineConfig,
    STATE_ANOMALY,
    Series,
    SeriesSource,
    evaluate_source,
    rehydrate,
)


struct RefusingStore(MeasurementStore):
    """A store that accepts `limit` points and then REFUSES.

    Not a fault injector for its own sake: a real store rejects writes — a
    quota, a closed partition, a permissions change on the bucket — and the
    seam's contract says an append that cannot happen must RAISE rather than
    silently drop. This is what proves the monitor honours the other half of
    that contract: nothing is judged when nothing was stored.
    """

    var inner: InMemoryPointStore
    var limit: Int
    var attempts: Int

    def __init__(out self, limit: Int):
        self.inner = InMemoryPointStore()
        self.limit = limit
        self.attempts = 0

    def append_point(
        mut self, key: String, ordinal: Int64, value: Float64
    ) raises:
        self.attempts += 1
        if self.attempts > self.limit:
            raise Error(
                String("RefusingStore: quota exhausted at ")
                + String(self.limit)
                + String(" points")
            )
        self.inner.append_point(key, ordinal, value)

    def series_count(mut self) raises -> Int:
        return self.inner.series_count()

    def series_key_at(mut self, index: Int) raises -> String:
        return self.inner.series_key_at(index)

    def load_series(mut self, key: String) raises -> Series:
        return self.inner.load_series(key)


struct RetentionStore(MeasurementStore):
    """A store that KEEPS everything but RETURNS only the newest `keep`.

    ⚠ THIS IS LEGAL AND THE SEAM SAYS SO. A partitioned store ages data out; a
    replay then legitimately sees fewer points than were written. The monitor
    must not treat that as an error, and `rehydrate` must REPORT the smaller
    number so a caller can tell a full rehydration from a partial one instead
    of assuming.
    """

    var inner: InMemoryPointStore
    var keep: Int

    def __init__(out self, keep: Int):
        self.inner = InMemoryPointStore()
        self.keep = keep

    def append_point(
        mut self, key: String, ordinal: Int64, value: Float64
    ) raises:
        self.inner.append_point(key, ordinal, value)

    def series_count(mut self) raises -> Int:
        return self.inner.series_count()

    def series_key_at(mut self, index: Int) raises -> String:
        return self.inner.series_key_at(index)

    def load_series(mut self, key: String) raises -> Series:
        var full = self.inner.load_series(key)
        var out = Series(key)
        var start = full.count() - self.keep
        if start < 0:
            start = 0
        for i in range(start, full.count()):
            out.points.append(full.points[i].copy())
        return out^


def _values(n: Int, step_at: Int, factor: Float64) -> List[Float64]:
    var pattern: List[Float64] = [-2.0, -1.0, 0.0, 1.0, 2.0]
    var out = List[Float64]()
    for i in range(n):
        var x = 100.0 + pattern[i % 5]
        if step_at >= 0 and i >= step_at:
            x = x * factor
        out.append(x)
    return out^


def test_append_then_replay_returns_exactly_what_went_in() raises:
    """The round trip, in ordinal order, value for value."""
    var store = InMemoryPointStore()
    var v = _values(12, -1, Float64(1.0))
    for i in range(len(v)):
        store.append_point(String("a/b"), Int64(i * 7), v[i])
    assert_equal(store.appended, 12, "twelve appends")
    assert_equal(store.series_count(), 1, "one series")
    assert_equal(store.series_key_at(0), String("a/b"), "under its own key")

    var back = store.load_series(String("a/b"))
    assert_equal(back.count(), 12, "twelve points come back")
    for i in range(12):
        assert_equal(
            back.points[i].ordinal, Int64(i * 7), "ordinals survive exactly"
        )
        assert_equal(back.points[i].value, v[i], "values survive to the bit")


def test_a_measurement_store_is_a_series_source() raises:
    """⭐ THE SEAM COMPOSES, PROVED BY THE EXISTING GENERIC SWEEP.

    `MeasurementStore` inherits `SeriesSource`, so anything written to a store
    can be driven through `evaluate_source` — the function that already existed
    — with no adapter. A write seam that needed a shim to reach the read path
    would be a second data model.
    """
    var store = InMemoryPointStore()
    var flat = _values(14, -1, Float64(1.0))
    var stepped = _values(20, 12, Float64(1.25))
    for i in range(len(flat)):
        store.append_point(String("flat"), Int64(i), flat[i])
    for i in range(len(stepped)):
        store.append_point(String("stepped"), Int64(i), stepped[i])

    var report = evaluate_source(store, DetectorConfig())
    assert_equal(report.total, 2, "both series were swept")
    assert_equal(report.load_failures, 0, "and neither failed to load")
    assert_equal(
        report.anomaly, 1, "the stepped one fired and the flat one did not"
    )
    assert_equal(report.normal, 1, "so exactly one is NORMAL")
    print(String("sweep over a MeasurementStore: ") + report.render())


def test_replay_rebuilds_the_same_state_as_the_live_path() raises:
    """⭐ THE RESTART PROPERTY. THE WHOLE REASON THE SEAM HAS A WRITE HALF.

    One monitor is fed live through `observe_and_store`; a second, fresh one is
    rebuilt from the store alone. Their accumulated bounds must agree TO THE
    BIT and their verdicts must render identically. Anything less means a
    restarted detector holds a different idea of normal from the one that raised
    the last alert, and no reader can tell.
    """
    var store = InMemoryPointStore()
    var cfg = OnlineConfig(DetectorConfig(), 64, 4, Float64(5.0), 25)
    var live = AnomalyMonitor(cfg^)
    var v = _values(40, -1, Float64(1.0))
    for i in range(len(v)):
        _ = live.observe_and_store(store, String("s"), Int64(i), v[i])

    var cfg2 = OnlineConfig(DetectorConfig(), 64, 4, Float64(5.0), 25)
    var rebuilt = AnomalyMonitor(cfg2^)
    var replayed = rehydrate(store, rebuilt)
    assert_equal(replayed, 40, "every stored point was replayed")

    var a = live.bounds_of(String("s"))
    var b = rebuilt.bounds_of(String("s"))
    assert_true(
        a.armed,
        "CONTROL: the live bounds must be ARMED, or this compares two empty"
        " accumulations and proves nothing",
    )
    assert_equal(a.n_prior, b.n_prior, "same point count")
    assert_equal(a.mean_prior, b.mean_prior, "same mean, to the bit")
    assert_equal(a.sigma_prior, b.sigma_prior, "same scale, to the bit")
    assert_equal(
        live.verdict_for(String("s")).render(),
        rebuilt.verdict_for(String("s")).render(),
        "and the same rendered verdict",
    )
    print(
        String("rehydrated 40 points: mean=")
        + String(b.mean_prior)
        + String(" sigma=")
        + String(b.sigma_prior)
        + String(" — identical to the live path")
    )


def test_replay_rebuilds_a_latched_anomaly_too() raises:
    """The same property where the answer is ANOMALY.

    A monitor that rebuilt bounds correctly but lost the latch would pass the
    test above and page nobody about a live regression after a restart.
    """
    var store = InMemoryPointStore()
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var live = AnomalyMonitor(cfg^)
    var v = _values(20, 12, Float64(1.25))
    for i in range(len(v)):
        _ = live.observe_and_store(store, String("s"), Int64(i), v[i])
    assert_equal(
        live.verdict_for(String("s")).state, STATE_ANOMALY, "CONTROL: fires"
    )

    var cfg2 = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 1000)
    var rebuilt = AnomalyMonitor(cfg2^)
    _ = rehydrate(store, rebuilt)
    assert_equal(
        rebuilt.verdict_for(String("s")).render(),
        live.verdict_for(String("s")).render(),
        "the rebuilt monitor is latched on the identical finding",
    )


def test_nothing_is_judged_when_the_store_refuses() raises:
    """⛔ STORE FIRST, THEN JUDGE — PROVED BY A STORE THAT SAYS NO.

    A point that reached the detector but not the record would make the live
    accumulation unreproducible from the stored data forever. So when the
    append raises, the exception propagates and the monitor's state is exactly
    what it was.
    """
    var store = RefusingStore(10)
    var cfg = OnlineConfig(DetectorConfig(), 64, 1, Float64(5.0), 5)
    var m = AnomalyMonitor(cfg^)
    var v = _values(20, -1, Float64(1.0))
    for i in range(10):
        _ = m.observe_and_store(store, String("s"), Int64(i), v[i])
    var before = m.bounds_of(String("s"))
    assert_equal(m.observed_count(String("s")), 10, "ten points accepted")

    var raised = False
    try:
        _ = m.observe_and_store(store, String("s"), Int64(10), v[10])
    except e:
        raised = True
    assert_true(
        raised, "the store's refusal must propagate, not be swallowed"
    )
    assert_equal(
        m.observed_count(String("s")),
        10,
        "and the eleventh point was NOT judged — still ten",
    )
    var after = m.bounds_of(String("s"))
    assert_equal(after.n_prior, before.n_prior, "the accumulation did not move")
    assert_equal(after.mean_prior, before.mean_prior, "nor the mean, to the bit")
    assert_equal(
        m.rejected_count(String("s")),
        0,
        "and it is not a REJECTION either — the detector never saw it",
    )


def test_a_truncating_store_reports_a_shorter_replay() raises:
    """⚠ RETENTION IS LEGAL, AND `rehydrate` SAYS HOW MUCH CAME BACK.

    A caller that ignores the returned count cannot tell a full rehydration
    from a partial one, and bounds rebuilt from a truncated replay are bounds
    over a shorter history. The number is the only thing that makes the
    difference visible.
    """
    var store = RetentionStore(12)
    var cfg = OnlineConfig(DetectorConfig(), 64, 4, Float64(5.0), 5)
    var live = AnomalyMonitor(cfg^)
    var v = _values(40, -1, Float64(1.0))
    for i in range(len(v)):
        _ = live.observe_and_store(store, String("s"), Int64(i), v[i])

    var cfg2 = OnlineConfig(DetectorConfig(), 64, 4, Float64(5.0), 5)
    var rebuilt = AnomalyMonitor(cfg2^)
    var replayed = rehydrate(store, rebuilt)
    assert_equal(
        replayed,
        12,
        String("only the retained 12 points came back, and rehydrate must SAY")
        + String(" 12 rather than 40. Got ")
        + String(replayed),
    )
    assert_equal(
        rebuilt.observed_count(String("s")),
        12,
        "and the rebuilt monitor holds exactly those",
    )
    assert_true(
        live.bounds_of(String("s")).n_prior
        > rebuilt.bounds_of(String("s")).n_prior,
        "so its bounds are over a demonstrably shorter history than the live"
        " monitor's — which is the fact the count exists to expose",
    )


def test_an_out_of_order_append_is_refused_on_the_way_in() raises:
    """⛔ ORDER IS THE SEAM'S PROMISE, SO IT IS CHECKED AT THE WRITE.

    A store that accepted an out-of-order append would have to sort on read —
    hiding a producer bug forever — or break `load_series`'s promise.
    """
    var store = InMemoryPointStore()
    store.append_point(String("k"), Int64(5), 1.0)
    store.append_point(String("k"), Int64(6), 1.0)
    var raised = False
    try:
        store.append_point(String("k"), Int64(6), 1.0)
    except e:
        raised = True
    assert_true(raised, "a repeated ordinal is refused")
    var raised2 = False
    try:
        store.append_point(String("k"), Int64(3), 1.0)
    except e:
        raised2 = True
    assert_true(raised2, "and so is a backwards one")
    assert_equal(store.appended, 2, "and neither was counted as stored")


def test_an_unknown_key_raises_rather_than_returning_an_empty_series() raises:
    """An empty series is a real answer for a key that EXISTS. For one that does
    not it is a lie the caller cannot detect."""
    var store = InMemoryPointStore()
    store.append_point(String("real"), Int64(0), 1.0)
    var raised = False
    try:
        _ = store.load_series(String("imaginary"))
    except e:
        raised = True
    assert_true(raised, "an unknown key raises")

    var raised2 = False
    try:
        store.append_point(String(""), Int64(0), 1.0)
    except e:
        raised2 = True
    assert_true(
        raised2,
        "and an empty key is refused at the write — there is nowhere for the"
        " point to go and inventing a place is worse than refusing",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
