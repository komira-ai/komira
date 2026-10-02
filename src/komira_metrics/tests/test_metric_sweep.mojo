# =============================================================================
# test_metric_sweep.mojo — ⭐ ONE RECORD PER SERIES PER INTERVAL, AND THE CURSOR
# =============================================================================
#
# ⭐ THE ONE INVARIANT THIS FILE EXISTS FOR:
#
#     The ring is the EXPORT path, never the RECORD path. One ring record per
#     (series, interval), never per observation. Without it a counter
#     incremented 10^6/s produces 10^6 ring records/s.
#
# `test_ONE_MILLION_observations_produce_EXACTLY_ONE_record` is that sentence,
# executed.
#
# ⛔ AND IT NEEDS A CONTROL, BECAUSE A SWEEP THAT EMITS NOTHING PASSES THE NAIVE
# FORM. `assert emitted != 1_000_000` is satisfied by 0, and 0 is what a sweep
# whose deadline never fires, whose reduction refuses everything, or whose skip
# arm swallows the point produces. Every one-record case below therefore
# asserts the EXACT count AND the reduced VALUE, and
# `test_the_control_a_sweep_with_no_observations_emits_ZERO` pins the other end
# so the "1" is a measurement and not a constant.
#
# THE OTHER FOUR PROPERTIES, each silent when wrong:
#
#   * THE CURSOR DOES NOT ADVANCE ON BACKPRESSURE. A `try_accept` of
#     False must re-offer the SAME point next tick. If the cursor advanced, DROP
#     would be data loss instead of export latency — and the loss would be
#     invisible, because the source slot was already reset at collect time.
#
#   * A GENERATION FINISHES BEFORE THE NEXT ONE STARTS. Collecting on top of an
#     in-flight generation interleaves two intervals with two different
#     `start_time_unix_ns`, which no consumer can untangle.
#
#   * DELTA MEANS RESET. Two intervals of 10 observations are two records of 10,
#     not 10 then 20. A missing reset makes every counter look cumulative while
#     its flags say DELTA.
#
#   * A GAUGE IS NOT A COUNTER. Not summed across workers (the sum of 64
#     workers' readings of a queue depth is not a queue depth), not reset (a
#     level that stops being written is still the level), and not skipped when
#     unchanged (a level that stops being reported is a GAP on a dashboard).
#
# Encapsulation: the two sinks below own a `List[MetricPoint]` and
# nothing else. No `UnsafePointer` anywhere in this file.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_metrics.metric_point import (
    METRIC_COUNTER,
    METRIC_GAUGE,
    METRIC_UPDOWNCOUNTER,
    MetricPoint,
)
from komira_metrics.metric_sweep import (
    DEFAULT_METRIC_INTERVAL_NS,
    METRIC_EXPORT_BATCH,
    MetricPointSink,
    MetricSweep,
    MetricTimeAnchor,
)
from komira_metrics.metrics_set import MAX_WORKERS
from komira_metrics.histogram import (
    HISTOGRAM_BOUNDS,
    HISTOGRAM_BUCKETS,
    HistogramPoint,
    HistogramTables,
)
from komira_metrics.series_table import SeriesTables


comptime SCOPE: UInt32 = UInt32(0x5C09E)
comptime INTERVAL: UInt64 = UInt64(1_000_000_000)  # 1 s, so a test can step it


# -----------------------------------------------------------------------------
# The two test sinks. `MetricPointSink` is the seam a record encoder plugs
# into; these are the scripted fakes on the other side of it.
# -----------------------------------------------------------------------------


struct CapturingSink(MetricPointSink, Movable, Deinitable):
    """Takes everything. The `accept_after` field is what makes a
    BACKPRESSURING sink out of the same struct: once `taken` reaches `capacity`
    it starts returning False, which is a FULL TRANSPORT, not a rejection."""

    var points: List[MetricPoint]
    var hist_points: List[HistogramPoint]
    var capacity: Int
    var refusals: Int

    def __init__(out self, capacity: Int = -1):
        self.points = List[MetricPoint]()
        self.hist_points = List[HistogramPoint]()
        self.capacity = capacity
        self.refusals = 0

    def _full(self) -> Bool:
        return self.capacity >= 0 and self.total() >= self.capacity

    def try_accept(mut self, point: MetricPoint) -> Bool:
        if self._full():
            self.refusals += 1
            return False
        self.points.append(point.copy())
        return True

    def try_accept_histogram(mut self, point: HistogramPoint) -> Bool:
        if self._full():
            self.refusals += 1
            return False
        self.hist_points.append(point.copy())
        return True

    def count(self) -> Int:
        return len(self.points)

    def hist_count(self) -> Int:
        return len(self.hist_points)

    def total(self) -> Int:
        return len(self.points) + len(self.hist_points)

    def open_up(mut self, capacity: Int):
        self.capacity = capacity


def _observe(
    mut t: SeriesTables, n: Int, worker: Int = 0, name: UInt32 = UInt32(42)
):
    for _ in range(n):
        _ = t.add(worker, name, SCOPE, UInt32(0), METRIC_COUNTER, Int64(1))


# =============================================================================
# ⭐ AMENDMENT 2
# =============================================================================


def test_ONE_MILLION_observations_produce_EXACTLY_ONE_record() raises -> None:
    """⭐ THE HEADLINE INVARIANT.

    "A counter incremented 10^6/s produces 10^6 ring records/s" is the failure
    the sweep exists to prevent."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()

    _observe(tables, 1_000_000)

    # The observations alone produced NOTHING. There is no path from an
    # observation to a record: it is structural, not a convention.
    assert_equal(sink.count(), 0, "1,000,000 observations emit nothing at all")
    assert_equal(sweep.generations(), 0, "and no generation has been collected")

    var n = sweep.tick(tables, hists, sink, INTERVAL)

    assert_equal(n, 1, "the sweep emits exactly ONE point")
    assert_equal(
        sink.count(),
        1,
        "1,000,000 observations -> 1 record. NOT 1,000,000, and NOT 0 --"
        " see the value assertion below, which is what rules 0 out",
    )
    assert_equal(sweep.generations(), 1, "one interval, one generation")
    # ⛔ THE CONTROL. Without this, a sweep that emitted nothing would satisfy
    # everything above except the `== 1`, and a sweep that emitted one EMPTY
    # point would satisfy that too.
    assert_equal(
        Int(sink.points[0].as_int()),
        1_000_000,
        "and the ONE record carries all 1,000,000 observations",
    )
    assert_equal(
        Int(sink.points[0].kind),
        Int(METRIC_COUNTER),
        "as a COUNTER",
    )
    assert_true(sink.points[0].is_monotonic(), "monotonic")
    assert_false(
        sink.points[0].is_cumulative(),
        "and DELTA, because the source slot was reset by the collect",
    )


def test_the_control_a_sweep_with_no_observations_emits_ZERO() raises -> None:
    """The other end of the one-record assertion. If this emitted 1, the
    "exactly one record" above would be a constant rather than a count."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    var n = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(n, 0, "no observations, no points")
    assert_equal(sink.count(), 0, "and nothing reached the sink")
    assert_equal(
        sweep.generations(),
        1,
        "but the generation DID run -- this is an empty sweep, not a sweep"
        " that never fired",
    )


def test_the_record_count_is_the_SERIES_count_not_the_worker_count() raises -> None:
    """3 series observed by all 64 workers, 100 times each = 19,200
    observations spread over 192 per-worker slots -> THREE records."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    for w in range(MAX_WORKERS):
        for s in range(3):
            _observe(tables, 100, w, UInt32(700 + s))
    assert_equal(
        tables.live_series(),
        3 * MAX_WORKERS,
        "192 occupied SLOTS before the sweep",
    )
    var n = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(n, 3, "192 slots, 19,200 observations -> THREE records")
    for i in range(3):
        assert_equal(
            Int(sink.points[i].as_int()),
            100 * MAX_WORKERS,
            "each record carries every worker's contribution",
        )


# =============================================================================
# THE DEADLINE
# =============================================================================


def test_a_tick_before_the_deadline_does_nothing() raises -> None:
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _observe(tables, 5)
    assert_equal(
        sweep.tick(tables, hists, sink, INTERVAL - UInt64(1)),
        0,
        "one nanosecond before the deadline: nothing",
    )
    assert_equal(sweep.generations(), 0, "and no generation was collected")
    assert_equal(
        sweep.tick(tables, hists, sink, INTERVAL),
        1,
        "at the deadline: the point goes",
    )


def test_the_deadline_advances_so_intervals_do_not_overlap() raises -> None:
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _observe(tables, 3)
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(
        Int(sweep.next_deadline_mono_ns()),
        2 * Int(INTERVAL),
        "the next deadline is one interval past the sweep, not past 0",
    )
    _observe(tables, 4)
    assert_equal(
        sweep.tick(tables, hists, sink, INTERVAL + UInt64(1)),
        0,
        "a tick just after the last sweep is inside the new interval",
    )
    assert_equal(sweep.tick(tables, hists, sink, 2 * INTERVAL), 1, "and then it fires")


def test_force_tick_and_final_flush_ignore_the_deadline() raises -> None:
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(DEFAULT_METRIC_INTERVAL_NS, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _observe(tables, 7)
    assert_equal(
        sweep.tick(tables, hists, sink, UInt64(1)),
        0,
        "the 60 s default deadline has not passed",
    )
    assert_equal(
        sweep.force_tick(tables, hists, sink, UInt64(1)), 1, "force_tick fires anyway"
    )
    _observe(tables, 9)
    assert_equal(
        sweep.final_flush(tables, hists, sink, UInt64(2)),
        1,
        "and final_flush -- the exit path, the reason an idle process is"
        " LATE rather than silent",
    )
    assert_equal(Int(sink.points[1].as_int()), 9, "with the last interval's 9")


# =============================================================================
# DELTA TEMPORALITY
# =============================================================================


def test_two_intervals_of_ten_are_TEN_and_TEN_not_ten_and_twenty() raises -> None:
    """The reset. A missing one makes every counter cumulative while its flags
    say DELTA -- a dashboard would show a monotonically rising line for a rate
    that never changed."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _observe(tables, 10)
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    _observe(tables, 10)
    _ = sweep.tick(tables, hists, sink, 2 * INTERVAL)
    assert_equal(sink.count(), 2, "two intervals, two records")
    assert_equal(Int(sink.points[0].as_int()), 10, "interval 1 delta is 10")
    assert_equal(
        Int(sink.points[1].as_int()),
        10,
        "interval 2 delta is 10 -- NOT 20",
    )


def test_an_idle_interval_emits_nothing_and_the_skip_is_COUNTED() raises -> None:
    """A zero delta is a DESIGNED skip: at the 4096-series ceiling, emitting
    every idle series every interval is a full ring per interval, which is the
    OVERFLOW_DROP storm the sweep exists to prevent. The COUNTER is what
    keeps it from being indistinguishable from a broken sweep."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _observe(tables, 6)
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(sink.count(), 1, "the busy interval emits")
    assert_equal(sweep.skipped_zero_delta(), 0, "and skips nothing")

    _ = sweep.tick(tables, hists, sink, 2 * INTERVAL)
    assert_equal(sink.count(), 1, "the IDLE interval emits nothing")
    assert_equal(
        sweep.skipped_zero_delta(),
        1,
        "and says so -- the skip is a number, not an absence",
    )
    assert_equal(sweep.generations(), 2, "both generations ran")

    _observe(tables, 2)
    _ = sweep.tick(tables, hists, sink, 3 * INTERVAL)
    assert_equal(sink.count(), 2, "and the series resumes without re-inserting")
    assert_equal(Int(sink.points[1].as_int()), 2, "with the new delta")


def test_the_intervals_TILE_start_of_one_is_end_of_the_last() raises -> None:
    """`start_time_unix_ns` of interval N+1 must be `time_unix_ns` of interval
    N, or a consumer summing deltas either double-counts an overlap or loses a
    gap."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var anchor = MetricTimeAnchor(UInt64(0), UInt64(1_700_000_000_000_000_000))
    var sweep = MetricSweep(INTERVAL, UInt64(0), anchor)
    var sink = CapturingSink()
    _observe(tables, 1)
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    _observe(tables, 1)
    _ = sweep.tick(tables, hists, sink, 2 * INTERVAL)
    assert_equal(
        Int(sink.points[0].start_time_unix_ns),
        1_700_000_000_000_000_000,
        "interval 1 starts at the anchor (process start)",
    )
    assert_equal(
        Int(sink.points[0].time_unix_ns),
        1_700_000_001_000_000_000,
        "and ends one interval later, in EPOCH ns via the anchor",
    )
    assert_equal(
        Int(sink.points[1].start_time_unix_ns),
        Int(sink.points[0].time_unix_ns),
        "interval 2 STARTS where interval 1 ENDED -- no gap, no overlap",
    )


def test_an_updowncounter_keeps_its_non_monotonic_flag_through_the_sweep() raises -> None:
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _ = tables.add(0, UInt32(1), SCOPE, UInt32(0), METRIC_UPDOWNCOUNTER, Int64(7))
    _ = tables.add(0, UInt32(1), SCOPE, UInt32(0), METRIC_UPDOWNCOUNTER, Int64(-2))
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(sink.count(), 1, "one series, one record")
    assert_equal(Int(sink.points[0].as_int()), 5, "7 - 2 = 5, and it can go down")
    assert_equal(
        Int(sink.points[0].kind),
        Int(METRIC_UPDOWNCOUNTER),
        "the kind survives the reduction",
    )
    assert_false(
        sink.points[0].is_monotonic(),
        "an UPDOWNCOUNTER is NOT monotonic -- it lowers to a different OTLP arm",
    )


def test_an_updowncounter_that_NETS_to_zero_is_skipped_and_that_is_stated() raises -> None:
    """The honest cost of the zero-delta skip, from the file header: an
    UPDOWNCOUNTER whose increments and decrements cancel is indistinguishable
    from an idle one. Correct arithmetic under delta temporality; a loss of
    LIVENESS. Pinned here so it is a decision, not a surprise."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _ = tables.add(0, UInt32(1), SCOPE, UInt32(0), METRIC_UPDOWNCOUNTER, Int64(5))
    _ = tables.add(0, UInt32(1), SCOPE, UInt32(0), METRIC_UPDOWNCOUNTER, Int64(-5))
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(sink.count(), 0, "a net-zero interval emits nothing")
    assert_equal(sweep.skipped_zero_delta(), 1, "and it is counted, not silent")


# =============================================================================
# GAUGES
# =============================================================================


def test_a_gauge_is_a_LEVEL_not_summed_not_reset_not_skipped() raises -> None:
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _ = tables.set_gauge(0, UInt32(3), SCOPE, UInt32(0), Int64(40))
    _ = tables.set_gauge(1, UInt32(3), SCOPE, UInt32(0), Int64(70))
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(sink.count(), 1, "one series, one record")
    assert_equal(
        Int(sink.points[0].as_int()),
        70,
        "the LAST worker's reading -- 110 would be the sum of two queue"
        " depths, which is not a queue depth",
    )
    assert_equal(Int(sink.points[0].kind), Int(METRIC_GAUGE), "a GAUGE")
    assert_equal(
        Int(sink.points[0].start_time_unix_ns),
        Int(sink.points[0].time_unix_ns),
        "a gauge has no interval, so start == time (a zero-width window, not a"
        " window back to the epoch)",
    )

    # And the next interval, with NO new writes, emits it AGAIN.
    _ = sweep.tick(tables, hists, sink, 2 * INTERVAL)
    assert_equal(
        sink.count(),
        2,
        "an unchanged level is RE-REPORTED -- a level that stops being"
        " reported is a GAP on a dashboard, not 'unchanged'",
    )
    assert_equal(Int(sink.points[1].as_int()), 70, "still 70: not reset")
    assert_equal(
        sweep.skipped_zero_delta(), 0, "and the zero-delta skip never applies"
    )


def test_a_gauge_of_ZERO_is_a_real_level_and_still_emits() raises -> None:
    """The case the zero-delta skip would eat if gauges were not exempt."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _ = tables.set_gauge(0, UInt32(3), SCOPE, UInt32(0), Int64(0))
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(sink.count(), 1, "a gauge reading of 0 is a reading")
    assert_equal(Int(sink.points[0].as_int()), 0, "and its value is 0")


# =============================================================================
# ★ THE CURSOR
# =============================================================================


def test_backpressure_does_NOT_advance_the_cursor_and_nothing_is_lost() raises -> None:
    """★ The cursor does not advance on a refused push.

    In full: "A `try_push` that returns False does not advance the cursor, so a
    dropped record is re-swept on the next tick: DROP is converted from data
    loss into export latency."

    ⛔ THIS IS THE ONE THAT CANNOT BE RECOVERED IF IT IS WRONG. The source slots
    were already reset at collect time, so a cursor that advanced past a refused
    point loses it with no counter anywhere."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    # A sink that takes exactly 2 and then reports a full transport.
    var sink = CapturingSink(2)
    for s in range(5):
        _observe(tables, s + 1, 0, UInt32(900 + s))

    var n = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(n, 2, "the sink took 2 before going full")
    assert_equal(sweep.backpressured(), 1, "and the refusal is counted")
    assert_equal(
        sweep.pending_count(), 3, "THREE points are still pending, not lost"
    )
    assert_true(sweep.generation_in_flight(), "the generation is in flight")

    # A tick with the sink still full re-offers and is refused again -- and
    # still does not advance.
    assert_equal(sweep.tick(tables, hists, sink, 5 * INTERVAL), 0, "still refused")
    assert_equal(sweep.pending_count(), 3, "still three pending")
    assert_equal(
        sweep.generations(),
        1,
        "⛔ AND NO SECOND GENERATION WAS COLLECTED, even though the deadline"
        " passed four times over -- interleaving two intervals' records is"
        " untanglable downstream",
    )

    sink.open_up(-1)
    assert_equal(sweep.tick(tables, hists, sink, 5 * INTERVAL), 3, "the rest go")
    assert_equal(sink.count(), 5, "all five series arrived, none lost")
    assert_false(sweep.generation_in_flight(), "and the generation is done")

    # The five deltas are 1..5 and every one of them survived.
    var total = 0
    for i in range(5):
        total += Int(sink.points[i].as_int())
    assert_equal(total, 15, "1+2+3+4+5 -- the backpressured three are intact")


def test_the_batch_ceiling_is_512_and_a_full_sweep_takes_more_ticks() raises -> None:
    """`METRIC_EXPORT_BATCH` = 4096/8. "Metrics occupy <= 1/8 of a ring at
    any instant, so a metric burst can never starve the logs that share it. A
    worst-case full sweep takes 8 ticks"."""
    assert_equal(METRIC_EXPORT_BATCH, 512, "the derived batch")
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    for s in range(800):
        _observe(tables, 1, 0, UInt32(2000 + s))

    assert_equal(
        sweep.tick(tables, hists, sink, INTERVAL),
        512,
        "the first tick emits EXACTLY the batch ceiling, not all 800",
    )
    assert_equal(sweep.pending_count(), 288, "288 held over")
    assert_equal(
        sweep.generations(), 1, "one generation, spread over several ticks"
    )
    assert_equal(sweep.tick(tables, hists, sink, 9 * INTERVAL), 288, "the remainder")
    assert_equal(sink.count(), 800, "800 series, 800 records, one generation")
    assert_equal(
        sweep.generations(),
        1,
        "and STILL one generation -- the ticks that finished it did not"
        " collect a second interval on top",
    )


def test_final_flush_does_not_spin_on_a_permanently_full_sink() raises -> None:
    """A sink that will not take a point now will not take it inside a tight
    loop either; spinning here would hang shutdown."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink(0)
    _observe(tables, 3)
    assert_equal(
        sweep.final_flush(tables, hists, sink, INTERVAL),
        0,
        "nothing got out, and the call RETURNED",
    )
    assert_equal(sweep.pending_count(), 1, "the point is still pending")


# =============================================================================
# THE ANCHOR
# =============================================================================


def test_the_anchor_converts_monotonic_to_epoch_both_directions() raises -> None:
    var a = MetricTimeAnchor(UInt64(1_000_000), UInt64(1_700_000_000_000_000_000))
    assert_equal(
        Int(a.to_unix_ns(UInt64(1_000_000))),
        1_700_000_000_000_000_000,
        "at the anchor, the identity",
    )
    assert_equal(
        Int(a.to_unix_ns(UInt64(2_000_000))),
        1_700_000_000_001_000_000,
        "one ms later",
    )
    assert_equal(
        Int(a.to_unix_ns(UInt64(0))),
        1_699_999_999_999_000_000,
        "and a reading from BEFORE the anchor converts backwards, not to an"
        " astronomical epoch time -- an unsigned delta would wrap here",
    )


# =============================================================================
# HISTOGRAMS — the same generation, the same deadline, the same batch ceiling
# =============================================================================


def test_ONE_MILLION_histogram_observations_produce_EXACTLY_ONE_point() raises -> None:
    """⭐ AMENDMENT 2 FOR THE HISTOGRAM ARM. Same invariant, same number, and
    the same control: the exact point count AND the reduced `count`, because a
    sweep that emitted one EMPTY histogram would pass the count assertion."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()

    for i in range(1_000_000):
        _ = hists.record(0, UInt32(5), SCOPE, UInt32(0), Int64(i % 2000))

    assert_equal(
        sink.total(), 0, "1,000,000 observations emit nothing at all"
    )

    var n = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(n, 1, "the sweep emits exactly ONE point")
    assert_equal(sink.hist_count(), 1, "and it is a HISTOGRAM point")
    assert_equal(sink.count(), 0, "no scalar point was invented")
    assert_equal(
        Int(sink.hist_points[0].count),
        1_000_000,
        "and the ONE point carries all 1,000,000 observations",
    )
    # The buckets sum to the count: every observation landed in exactly one.
    var total = UInt64(0)
    for i in range(HISTOGRAM_BUCKETS):
        total += sink.hist_points[0].bucket(i)
    assert_equal(Int(total), 1_000_000, "and the buckets account for all of it")


def test_a_histogram_reduces_across_workers_into_ONE_point() raises -> None:
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    for w in range(MAX_WORKERS):
        for _ in range(10):
            _ = hists.record(w, UInt32(5), SCOPE, UInt32(0), Int64(w))
    assert_equal(
        hists.live_series(), MAX_WORKERS, "64 occupied slots before the sweep"
    )
    assert_equal(sweep.tick(tables, hists, sink, INTERVAL), 1, "ONE point")
    assert_equal(
        Int(sink.hist_points[0].count), 640, "640 observations in it"
    )
    assert_equal(Int(sink.hist_points[0].min), 0, "min across all 64 workers")
    assert_equal(Int(sink.hist_points[0].max), 63, "and max")


def test_a_histogram_is_DELTA_two_intervals_are_ten_and_ten() raises -> None:
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    for _ in range(10):
        _ = hists.record(0, UInt32(5), SCOPE, UInt32(0), Int64(7))
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    for _ in range(10):
        _ = hists.record(0, UInt32(5), SCOPE, UInt32(0), Int64(7))
    _ = sweep.tick(tables, hists, sink, 2 * INTERVAL)
    assert_equal(sink.hist_count(), 2, "two intervals, two points")
    assert_equal(Int(sink.hist_points[0].count), 10, "interval 1")
    assert_equal(
        Int(sink.hist_points[1].count), 10, "interval 2 -- NOT 20"
    )
    assert_equal(
        Int(sink.hist_points[1].bucket(2)),
        10,
        "and the BUCKETS were reset too, not just the count",
    )


def test_an_idle_histogram_interval_emits_nothing_and_is_COUNTED() raises -> None:
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    _ = hists.record(0, UInt32(5), SCOPE, UInt32(0), Int64(7))
    _ = sweep.tick(tables, hists, sink, INTERVAL)
    assert_equal(sink.hist_count(), 1, "the busy interval emits")
    _ = sweep.tick(tables, hists, sink, 2 * INTERVAL)
    assert_equal(sink.hist_count(), 1, "the idle one does not")
    assert_equal(
        sweep.skipped_zero_delta(),
        1,
        "and the skip is a number -- the same DESIGNED skip as a zero scalar"
        " delta, for the same reason",
    )


def test_the_batch_CEILING_IS_SHARED_between_the_two_shapes() raises -> None:
    """Two independent budgets would let a histogram burst push metrics past
    the '<= 1/8 of a ring at any instant' rule, which is the whole reason the
    ceiling is derived from the ring in the first place."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink()
    for s in range(400):
        _observe(tables, 1, 0, UInt32(3000 + s))
    for s in range(200):
        _ = hists.record(0, UInt32(4000 + s), SCOPE, UInt32(0), Int64(1))

    assert_equal(
        sweep.tick(tables, hists, sink, INTERVAL),
        METRIC_EXPORT_BATCH,
        "600 points, and the first tick emits EXACTLY 512 -- not 512 of each",
    )
    assert_equal(sink.count(), 400, "all 400 scalars went first")
    assert_equal(
        sink.hist_count(), 112, "and 112 histograms filled the remaining budget"
    )
    assert_equal(sweep.pending_count(), 88, "88 held over, BOTH shapes counted")
    assert_equal(sweep.tick(tables, hists, sink, 9 * INTERVAL), 88, "the rest")
    assert_equal(sink.total(), 600, "600 series, 600 points")
    assert_equal(sweep.generations(), 1, "in ONE generation")


def test_backpressure_on_the_HISTOGRAM_arm_holds_the_cursor_too() raises -> None:
    """The scalar arm's cursor rule, on the second arm. A histogram lost here
    is unrecoverable for exactly the same reason: the source distribution was
    already reset at collect time."""
    var tables = SeriesTables()
    var hists = HistogramTables()
    var sweep = MetricSweep(INTERVAL, UInt64(0), MetricTimeAnchor())
    var sink = CapturingSink(2)
    for s in range(4):
        _ = hists.record(0, UInt32(5000 + s), SCOPE, UInt32(0), Int64(s + 1))

    assert_equal(sweep.tick(tables, hists, sink, INTERVAL), 2, "two got out")
    assert_equal(sweep.backpressured(), 1, "the refusal is counted")
    assert_equal(sweep.pending_count(), 2, "TWO still pending, not lost")
    sink.open_up(-1)
    assert_equal(sweep.tick(tables, hists, sink, 5 * INTERVAL), 2, "the rest")
    assert_equal(sink.hist_count(), 4, "all four arrived")
    var total = 0
    for i in range(4):
        total += Int(sink.hist_points[i].sum)
    assert_equal(total, 10, "1+2+3+4 -- the backpressured two are intact")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
