# =============================================================================
# metric_sweep.mojo — `MetricSweep`, the EXPORT driver
# =============================================================================
#
# ⭐ THE RING IS THE EXPORT PATH, NEVER THE RECORD PATH: ONE record per
# **(series, interval)**, never per observation. A counter
# incremented 10^6/s must not produce 10^6 ring records — it produces ONE, whose
# value is 10^6 x interval. Everything below exists to make that structurally
# true rather than a convention someone can forget:
#
#   * observations land in the SERIES TABLE (`series_table.mojo`), which is
#     a per-worker `(name_id, attrset_id) -> Int64` slot. N observations mutate
#     ONE slot. There is no path from an observation to a record.
#   * a record can be produced ONLY here, ONLY from a reduced slot, and ONLY
#     when a wall-clock deadline has passed.
#
# -----------------------------------------------------------------------------
# THE SHAPE, and why the reduction gets its OWN table
# -----------------------------------------------------------------------------
# A series lives in up to 64 per-worker tables. The same key hashes to the same
# HOME slot in every one of them, but linear probing displaces it differently
# per worker (each worker's collision history is its own), so slot `i` of worker
# 0 and slot `i` of worker 5 are not the same series. Three ways out were
# available:
#
#   (a) walk worker 0 and LOOK UP each key in the other 63. Misses every series
#       worker 0 never touched — wrong, not merely slow.
#   (b) keep a shared directory of every key ever seen. That is a cross-worker
#       write on the hot path, i.e. the atomic the series table exists to avoid.
#   (c) reduce every worker's occupied slots into ONE scratch table, then emit
#       from that.
#
# **(c)**, and the scratch table is a `SeriesTable` — the same struct, the same
# probe, the same conflict rule. Reusing it is not thrift: a reduction with its
# own probing code is a second place for the key layout to be wrong.
#
# The scratch is sized like one worker's table (4096), which is the process
# ceiling: the entire series set of a process fits in ONE ring-full, so the
# export can never need more buffer than the transport has. A union that
# exceeds it is REFUSED and COUNTED (`num_unreducible()`), never silently
# merged.
#
# -----------------------------------------------------------------------------
# ★ THE EXPORT IS CURSORED, AND THE CURSOR IS WHAT MAKES DROP SURVIVABLE
# -----------------------------------------------------------------------------
# At most `METRIC_EXPORT_BATCH` = 512 records leave per tick — one eighth of a
# 4096-slot ring — so a metric burst can never starve the logs sharing it. A
# `try_accept` that returns False **does not advance the cursor**: the record is
# re-offered next tick. DROP becomes export LATENCY.
#
# ⛔ AND A GENERATION IS FINISHED BEFORE THE NEXT ONE STARTS. `tick` re-checks
# the deadline ONLY when the pending buffer is drained. Collecting on top of an
# in-flight generation would interleave two intervals' records with two
# different `start_time_unix_ns`, which no consumer can untangle.
#
# -----------------------------------------------------------------------------
# ⭐ TWO REDUCTIONS, NOT ONE — and the spec does not say this outright
# -----------------------------------------------------------------------------
#   DELTA kinds (COUNTER, UPDOWNCOUNTER) SUM across workers and RESET the source
#   slot. `metric_point.mojo` states the reason: "a per-worker table that is
#   reduced and reset each export sweep produces deltas naturally".
#
#   A GAUGE is a LEVEL. It is NOT summed (the sum of 64 workers' readings of a
#   queue depth is not a queue depth) and it is NOT reset (a level that stops
#   being written is still the level). Ascending worker order, so the
#   highest-numbered worker holding the series wins — arbitrary among concurrent
#   writers, which is exactly what OTel's synchronous gauge specifies, and what
#   `MetricsSet.Gauge` already assumes with its relaxed atomic store.
#
# -----------------------------------------------------------------------------
# ⭐ A ZERO DELTA IS SKIPPED. A GAUGE IS NOT.
# -----------------------------------------------------------------------------
# A series that saw no observation this interval reduces to a delta of 0.
# Emitting it would burn a ring slot per idle series per interval — at the 4096
# ceiling that is a full ring every interval, which is precisely the
# `OVERFLOW_DROP` storm this file exists to prevent — and adds nothing: under
# DELTA temporality a point of 0 changes no downstream aggregate.
#
# ⚠ THE HONEST COST, stated rather than discovered later: an UPDOWNCOUNTER whose
# increments and decrements NET to zero over an interval is indistinguishable
# from one that was idle, and is skipped. Under delta temporality that is
# correct arithmetic; it is a loss of LIVENESS, not of value.
#
# A GAUGE is exempt and emits while its slot is occupied. A level that stops
# being re-reported reads as a GAP on a dashboard, not as "unchanged".
#
# -----------------------------------------------------------------------------
# ⚠ THE ANCHOR IS OURS, NOT `komira_log`'s
# -----------------------------------------------------------------------------
# `komira_log`'s engine has a `CalibrationAnchor` doing exactly this
# arithmetic, and this file may not use it: `komira_log` depends on
# `komira_metrics`, so importing it would invert the dependency and create a
# cycle. Two scalars
# duplicated is the correct price of a leaf package.
#
# -----------------------------------------------------------------------------
# ⛔ WHAT THIS FILE IS NOT
# -----------------------------------------------------------------------------
# It does NOT know about the ring or any record encoding — an encoder plugs in
# HERE, at `MetricPointSink`. It does not know about OTLP either; a metric
# exporter consumes BATCHES of points downstream of this and is a different
# seam.
#
# -----------------------------------------------------------------------------
# ⭐ EVERY MECHANISM HERE IS PINNED BY ITS OWN TEST
# -----------------------------------------------------------------------------
# `tests/test_metric_sweep.mojo`. Each break below, applied on its own, reds a
# case, which is what makes these independent coverage rather than one test
# failing five ways:
#
#   mechanism            the break                 failing assertion
#   ------------------   -----------------------   --------------------------
#   the ACCUMULATION     `value += n` -> `= n`     the ONE record's value.
#   (value half)                                   ⭐ THE COUNT STAYS 1 --
#                                                  so "exactly one record"
#                                                  ALONE would pass over a
#                                                  record carrying one
#                                                  observation out of 10^6.
#                                                  That is why every case here
#                                                  asserts the VALUE too.
#   the REDUCTION        key XORed with the        "the record count is the
#   (count half)         worker id, i.e. one       SERIES count"
#                        record per (series,
#                        WORKER)
#   the CURSOR           `_cursor += 1` on a       pending after backpressure
#                        refusal                   (the refused record is LOST)
#   the IN-FLIGHT        the `generation_in_       a second collect DESTROYS
#   GENERATION guard     flight()` early return    the pending generation
#                        deleted from `tick`
#   the GAUGE arm        gauge reduced by SUM      "the LAST worker's reading"
#                        and reset like a delta
#   the HISTOGRAM        `HistogramTable.take_     interval 2's count
#   DELTA reset          slot_delta` returns
#                        without `reset()`
#   the SHARED batch     the histogram arm given   the first tick emitted
#   ceiling              its own budget
#
# Encapsulation: a `Slab[SeriesTable]` and a `List[MetricPoint]`, both
# heap-owning and both `Movable`. No `UnsafePointer` in any signature, no
# wildcard origin, no field holding a caller's stack pointer — `tick` takes the
# tables and the sink as PARAMETERS, so the compiler tracks both lifetimes.
# =============================================================================

from komira_collections.slab import Slab

from komira_metrics.metric_point import (
    counter_point,
    gauge_point,
    METRIC_COUNTER,
    METRIC_GAUGE,
    METRIC_UPDOWNCOUNTER,
    MetricPoint,
    updown_counter_point,
)
from komira_metrics.histogram import (
    histogram_point,
    HistogramPoint,
    HistogramTable,
    HistogramTables,
)
from komira_metrics.metrics_set import MAX_WORKERS
from komira_metrics.series_table import (
    MAX_SERIES_PER_WORKER,
    SERIES_SLOT_NONE,
    SeriesTable,
    SeriesTables,
    series_key_attrset_id,
    series_key_name_id,
)


# DERIVED, not picked: `= DEFAULT_RING_CAPACITY / 8`. Metrics occupy <= 1/8
# of a ring at any instant, so a metric burst can never starve the logs that
# share it. A worst-case full sweep takes 8 ticks.
comptime METRIC_EXPORT_BATCH: Int = 512

# OTel's own default export interval (`OTEL_METRIC_EXPORT_INTERVAL`, 60000 ms).
# ⚠ NOT derived from anything in this tree — it is the OTel default, adopted so
# a Komira process and a stock OTel SDK produce comparably-spaced series.
comptime DEFAULT_METRIC_INTERVAL_NS: UInt64 = UInt64(60_000_000_000)


struct MetricTimeAnchor(Copyable, Movable, Deinitable):
    """`(mono0, unix0)` — converts a monotonic reading to epoch nanoseconds.

    Deliberately a duplicate of `komira_log`'s `CalibrationAnchor` shape; see
    the file header for why it cannot be an import.

    A SIGNED delta, so a reading captured slightly BEFORE the anchor still
    converts sanely rather than wrapping to an astronomical epoch time — the
    same care `CalibrationAnchor.tick_to_wall_ns` takes."""

    var mono0_ns: UInt64
    var unix0_ns: UInt64

    def __init__(out self, mono0_ns: UInt64 = UInt64(0), unix0_ns: UInt64 = UInt64(0)):
        self.mono0_ns = mono0_ns
        self.unix0_ns = unix0_ns

    def to_unix_ns(self, mono_ns: UInt64) -> UInt64:
        var delta = Int64(mono_ns) - Int64(self.mono0_ns)
        var out = Int64(self.unix0_ns) + delta
        if out < Int64(0):
            return UInt64(0)
        return UInt64(out)


trait MetricPointSink(Movable, Deinitable):
    """Where a swept point goes. THE SEAM A RECORD ENCODER PLUGS INTO.

    ⭐ `False` MEANS BACKPRESSURE, NOT FAILURE, and the distinction is the whole
    contract: the sweep does NOT advance its cursor on a False, so the point is
    re-offered on the next tick. A sink that returns False for a MALFORMED point
    would therefore livelock the export. Refuse nothing here; a sink's only
    legitimate False is "my transport is full right now"."""

    def try_accept(mut self, point: MetricPoint) -> Bool:
        ...

    def try_accept_histogram(mut self, point: HistogramPoint) -> Bool:
        """⭐ A SECOND METHOD, BECAUSE `MetricPoint` CANNOT CARRY A HISTOGRAM.
        One `value_bits` field, and a histogram data point is count + sum + min
        + max + 12 buckets; an on-ring histogram record has a
        different `arg_blob` shape that spills to the ring arena. See
        `histogram.mojo`'s header, including the Prometheus-style
        `le=<bound>`-per-bucket lowering that was considered and rejected.

        Same contract as `try_accept`: False is BACKPRESSURE, never a
        rejection."""
        ...


struct MetricSweep(Movable, Deinitable):
    """The producer-owned wall-clock export deadline.

    ⚠ THE INTERVAL IS OWNED HERE AND NOT BY ANY SERVE LOOP. A serve loop's
    pump is not an interval — it may pump every serve iteration, or only
    `if served > 0`. `tick` is meant to be
    called from BOTH the drain tick and the instrument write path; it is cheap
    and idempotent before the deadline (one comparison, no allocation).

    ⚠ THE RESIDUAL IS REAL AND IS NOT FIXED HERE: a process that is both idle
    and has no serve loop calls `tick` never and exports nothing until
    `final_flush`. That is stated openly rather than worked around."""

    var interval_ns: UInt64
    var anchor: MetricTimeAnchor
    # The monotonic instant the current interval STARTED — i.e. when the last
    # generation was collected, or process start.
    var _last_sweep_mono_ns: UInt64
    # The generation being emitted. Survives across ticks so a backpressured
    # record is never lost; the source slots were already reset at collect time.
    var _pending: List[MetricPoint]
    var _cursor: Int
    # The histogram half of the same generation. A SEPARATE list because the
    # point types differ; ONE generation, ONE deadline, ONE batch ceiling shared
    # across both -- two independent sweeps would let a scalar interval and a
    # histogram interval straddle each other.
    var _pending_hist: List[HistogramPoint]
    var _hist_cursor: Int
    # The cross-worker reduction scratch. One `SeriesTable`, heap-owned so a
    # `MetricSweep` on a stack does not carry 84 KiB of `InlineArray`.
    var _reduction: Slab[SeriesTable]
    var _hist_reduction: Slab[HistogramTable]
    var _generations: Int64
    var _emitted: Int64
    var _backpressured: Int64
    var _unreducible: Int64
    var _skipped_zero_delta: Int64

    def __init__(
        out self,
        interval_ns: UInt64 = DEFAULT_METRIC_INTERVAL_NS,
        start_mono_ns: UInt64 = UInt64(0),
        anchor: MetricTimeAnchor = MetricTimeAnchor(),
    ):
        self.interval_ns = interval_ns
        self.anchor = anchor.copy()
        self._last_sweep_mono_ns = start_mono_ns
        self._pending = List[MetricPoint]()
        self._cursor = 0
        self._pending_hist = List[HistogramPoint]()
        self._hist_cursor = 0
        self._reduction = Slab[SeriesTable].create_prefilled(1)
        self._hist_reduction = Slab[HistogramTable].create_prefilled(1)
        self._generations = Int64(0)
        self._emitted = Int64(0)
        self._backpressured = Int64(0)
        self._unreducible = Int64(0)
        self._skipped_zero_delta = Int64(0)

    # -------------------------------------------------------------------------
    # Observability of the sweep itself. Every one of these is a number a
    # dashboard can carry; a refusal nothing counts is indistinguishable from a
    # code path that never ran (the reason `dropped_registrations` exists on
    # `MetricsSet`, and the pattern to copy).
    # -------------------------------------------------------------------------

    @always_inline
    def generations(self) -> Int:
        """Completed COLLECTs. Amendment 2's denominator: records-per-generation
        is what "one record per (series, interval)" is a statement about."""
        return Int(self._generations)

    @always_inline
    def emitted(self) -> Int:
        return Int(self._emitted)

    @always_inline
    def backpressured(self) -> Int:
        """Ticks that ended on a sink refusal. NOT a loss — the cursor did not
        advance, so the record is re-offered. Non-zero means export LATENCY."""
        return Int(self._backpressured)

    @always_inline
    def num_unreducible(self) -> Int:
        """Series the reduction scratch REFUSED — the union across workers
        exceeded the process ceiling, or two workers hold one series under
        different kinds. NON-ZERO MEANS SERIES WERE LOST."""
        return Int(self._unreducible)

    @always_inline
    def skipped_zero_delta(self) -> Int:
        """Series that reduced to a delta of 0 and were not emitted. This is a
        DESIGNED skip, not a loss (see the header) — the number exists so an
        operator can tell "nothing happened" from "the sweep is broken"."""
        return Int(self._skipped_zero_delta)

    @always_inline
    def pending_count(self) -> Int:
        """Points of BOTH shapes still to be handed to the sink."""
        return (len(self._pending) - self._cursor) + (
            len(self._pending_hist) - self._hist_cursor
        )

    @always_inline
    def generation_in_flight(self) -> Bool:
        return self.pending_count() > 0

    @always_inline
    def next_deadline_mono_ns(self) -> UInt64:
        return self._last_sweep_mono_ns + self.interval_ns

    # -------------------------------------------------------------------------
    # COLLECT — the reduction. Runs on ONE thread: worker-disjointness is a
    # property of the WRITE, never of the export.
    # -------------------------------------------------------------------------

    def _collect(
        mut self,
        mut tables: SeriesTables,
        mut hists: HistogramTables,
        now_mono_ns: UInt64,
    ):
        self._reduction[0].clear()
        self._hist_reduction[0].clear()

        for w in range(MAX_WORKERS):
            var idx = tables.next_occupied(w, 0)
            while idx != SERIES_SLOT_NONE:
                var key = tables.slot_key(w, idx)
                var name_id = series_key_name_id(key)
                var attrset_id = series_key_attrset_id(key)
                var scope_id = tables.slot_scope(w, idx)
                var kind = tables.slot_kind(w, idx)
                if kind == METRIC_GAUGE:
                    # A LEVEL: read, do NOT reset. Ascending worker order means
                    # the highest-numbered worker holding it wins.
                    if not self._reduction[0].set_gauge(
                        name_id, scope_id, attrset_id, tables.slot_value(w, idx)
                    ):
                        self._unreducible += Int64(1)
                else:
                    # A DELTA: take AND zero. This is the only place a worker
                    # slot is reset, and it happens BEFORE any record reaches a
                    # sink — so a backpressured generation cannot double-count.
                    if not self._reduction[0].add(
                        name_id,
                        scope_id,
                        attrset_id,
                        kind,
                        tables.take_slot_delta(w, idx),
                    ):
                        self._unreducible += Int64(1)
                idx = tables.next_occupied(w, idx + 1)

        # The histogram half of the reduction. Bucket counts are ADDITIVE,
        # which is the whole reason a histogram reduces correctly across 64
        # tables at all -- a percentile is not.
        for w in range(MAX_WORKERS):
            var hidx = hists.next_occupied(w, 0)
            while hidx != -1:
                var hkey = hists.slot_key(w, hidx)
                if not self._hist_reduction[0].merge_into_slot(
                    series_key_name_id(hkey),
                    hists.slot_scope(w, hidx),
                    series_key_attrset_id(hkey),
                    hists.take_slot_delta(w, hidx),
                ):
                    self._unreducible += Int64(1)
                hidx = hists.next_occupied(w, hidx + 1)

        var start_unix_ns = self.anchor.to_unix_ns(self._last_sweep_mono_ns)
        var end_unix_ns = self.anchor.to_unix_ns(now_mono_ns)

        self._pending.clear()
        self._cursor = 0
        self._pending_hist.clear()
        self._hist_cursor = 0

        var ridx = self._reduction[0].next_occupied(0)
        while ridx != SERIES_SLOT_NONE:
            var key = self._reduction[0].slot_key(ridx)
            var name_id = series_key_name_id(key)
            var attrset_id = series_key_attrset_id(key)
            var scope_id = self._reduction[0].slot_scope(ridx)
            var kind = self._reduction[0].slot_kind(ridx)
            var value = self._reduction[0].slot_value(ridx)
            if kind == METRIC_GAUGE:
                self._pending.append(
                    gauge_point(
                        name_id, scope_id, attrset_id, value, end_unix_ns
                    )
                )
            elif value == Int64(0):
                # See the header: a zero delta is a DESIGNED skip.
                self._skipped_zero_delta += Int64(1)
            elif kind == METRIC_UPDOWNCOUNTER:
                self._pending.append(
                    updown_counter_point(
                        name_id,
                        scope_id,
                        attrset_id,
                        value,
                        start_unix_ns,
                        end_unix_ns,
                    )
                )
            else:
                self._pending.append(
                    counter_point(
                        name_id,
                        scope_id,
                        attrset_id,
                        value,
                        start_unix_ns,
                        end_unix_ns,
                    )
                )
            ridx = self._reduction[0].next_occupied(ridx + 1)

        var hridx = self._hist_reduction[0].next_occupied(0)
        while hridx != -1:
            var hkey = self._hist_reduction[0].slot_key(hridx)
            var hval = self._hist_reduction[0].slot_value(hridx)
            if hval.count == UInt64(0):
                # The same DESIGNED skip as a zero scalar delta, for the same
                # reason: an idle series must not burn a ring slot per interval.
                self._skipped_zero_delta += Int64(1)
            else:
                self._pending_hist.append(
                    histogram_point(
                        series_key_name_id(hkey),
                        self._hist_reduction[0].slot_scope(hridx),
                        series_key_attrset_id(hkey),
                        hval,
                        start_unix_ns,
                        end_unix_ns,
                    )
                )
            hridx = self._hist_reduction[0].next_occupied(hridx + 1)

        self._last_sweep_mono_ns = now_mono_ns
        self._generations += Int64(1)

    # -------------------------------------------------------------------------
    # DRAIN — cursored, at most `METRIC_EXPORT_BATCH` per call.
    # -------------------------------------------------------------------------

    def _drain[S: MetricPointSink](mut self, mut sink: S) -> Int:
        var n = 0
        while self._cursor < len(self._pending) and n < METRIC_EXPORT_BATCH:
            if not sink.try_accept(self._pending[self._cursor]):
                # ⛔ THE CURSOR DOES NOT ADVANCE. A dropped record is
                # re-swept next tick, converting DROP into export LATENCY.
                self._backpressured += Int64(1)
                return n
            self._cursor += 1
            self._emitted += Int64(1)
            n += 1
        # ⚠ THE SCALARS GO FIRST AND THE CEILING IS SHARED. Two independent
        # batch budgets would let a histogram burst push metrics past
        # "<= 1/8 of a ring at any instant".
        while (
            self._hist_cursor < len(self._pending_hist)
            and n < METRIC_EXPORT_BATCH
        ):
            if not sink.try_accept_histogram(
                self._pending_hist[self._hist_cursor]
            ):
                self._backpressured += Int64(1)
                return n
            self._hist_cursor += 1
            self._emitted += Int64(1)
            n += 1
        return n

    # -------------------------------------------------------------------------
    # TICK — the entry point. Cheap before the deadline: one comparison.
    # -------------------------------------------------------------------------

    def tick[
        S: MetricPointSink
    ](
        mut self,
        mut tables: SeriesTables,
        mut hists: HistogramTables,
        mut sink: S,
        now_mono_ns: UInt64,
    ) -> Int:
        """Advance the export. Returns the number of points the sink took.

        ⛔ FINISHES AN IN-FLIGHT GENERATION BEFORE STARTING A NEW ONE — see the
        header. A tick before the deadline with nothing pending does nothing and
        allocates nothing, which is what makes it safe to call from the
        instrument write path."""
        if self.generation_in_flight():
            return self._drain(sink)
        if now_mono_ns < self.next_deadline_mono_ns():
            return 0
        self._collect(tables, hists, now_mono_ns)
        return self._drain(sink)

    def force_tick[
        S: MetricPointSink
    ](
        mut self,
        mut tables: SeriesTables,
        mut hists: HistogramTables,
        mut sink: S,
        now_mono_ns: UInt64,
    ) -> Int:
        """`tick` with the deadline IGNORED. One batch only — still cursored.

        For tests and for a caller that knows an interval boundary out of band.
        It is NOT the shutdown path; that is `final_flush`."""
        if self.generation_in_flight():
            return self._drain(sink)
        self._collect(tables, hists, now_mono_ns)
        return self._drain(sink)

    def final_flush[
        S: MetricPointSink
    ](
        mut self,
        mut tables: SeriesTables,
        mut hists: HistogramTables,
        mut sink: S,
        now_mono_ns: UInt64,
    ) -> Int:
        """Drain EVERYTHING, deadline ignored, batch ceiling ignored.

        The exit path, and the reason an idle serve-loop-less process is
        merely LATE rather than silent: `final_flush` at exit does export,
        whereas a scrape that never happened loses the lifetime entirely.

        Stops early if the sink backpressures — a sink that will not take a
        point now will not take it on the next iteration of a tight loop
        either, and spinning here would hang shutdown."""
        if not self.generation_in_flight():
            self._collect(tables, hists, now_mono_ns)
        var total = 0
        while self.generation_in_flight():
            var n = self._drain(sink)
            if n == 0:
                break
            total += n
        return total
