# =============================================================================
# komira_log_index.object_store_metric_sink — `ObjectStoreMetricSink`, the
#   at-rest store for metrics.
# =============================================================================
#
# Metric points can be recorded, reduced and drained into a buffer, and then
# they stop. This sink takes them to an object store: `MetricPoint`s in,
# time-partitioned `(series_id, ts)`-sorted Parquet plus a catalog entry out,
# through `komira_telemetry_store`'s metric writer.
#
# The sink has no thread, no timer, no cadence and no ceiling on how long it
# holds points. It publishes when it is called. A process that is CPU-throttled
# between requests cannot evaluate a wall-clock ceiling except when a request
# arrives, so the caller decides when to flush: per serve iteration, and once at
# shutdown. A second flush mechanism would be a second place to get that wrong.
#
# What is reused from komira_telemetry_store, and is most of the module:
#
#   the key layout          `keys`
#   the catalog entry       `TelemetrySegmentEntry` (one body type, both datasets)
#   the CAS sub-lineage     `open_partition_manifest`, `_HEAD`, tombstones
#   the publish ordering    PUT the object, THEN append the entry
#   the day-split rule      no object straddles a partition boundary
#
# The writer, not this sink, owns the ordering: `publish_batches` writes the
# Parquet object and only then appends its entry to the manifest. A crash
# between the two leaves an unreferenced object, never an entry naming a missing
# one. This sink must not reorder that, and its tests record the store's verbs
# to hold it to that.
#
# What is not reused: the log path's in-flight byte gate. A `MetricPoint` is 48
# bytes of POD with no heap tail, and the drain that produces it is already
# bounded, so a second byte gate would cap the same thing twice with two
# different numbers. The buffer here is a plain `List[MetricPoint]` with its own
# stated ceiling.
#
# The input is a `List[MetricPoint]`, not an engine: a caller writes
# `sink.offer_points(engine.take_metric_points(0))` and this struct never
# imports the engine. The sink is testable with hand-built points.
#
# Call order at shutdown: take the engine's last points and `offer_points` them
# first, then `final_flush`. `final_flush` takes no argument and only publishes
# what the sink already holds, so a final flush that runs before the last take
# drops the trailing points.
#
# No bucket, no environment variable. The `Storage` and the telemetry root are
# handed in, so where metrics go is a property of the deployment, not of this
# library. The key layout is already prefix-separated by dataset
# (`telemetry/logs/...` and `telemetry/metrics/...`), so per-prefix expiry is a
# storage-side policy and nothing here requires a separate bucket.
#
# Single-threaded: one sink per producing worker, not one shared sink.
#
# Encapsulation: no pointer in any signature. `MetricPoint` is POD and crosses by
# value; the writer is Movable, so this struct is Movable and can live in an
# `Optional` at serve-loop scope.
# =============================================================================

from komira_collections.slab import Slab

from komira_arrow.record_batch import RecordBatch

from komira_objectstore.cas_manifest import RetryPolicy
from komira_objectstore.store import CloneableConditionalWriteStore

from komira_metrics.metric_point import MetricPoint

from komira_parquet_api.types import CompressionCodec

from komira_telemetry_store.keys import TELEMETRY_ROOT
from komira_telemetry_store.metric_writer import (
    TELEMETRY_METRIC_ROWS_PER_ROW_GROUP,
    TelemetryMetricSegmentWriter,
)
from komira_telemetry_store.log_writer import TELEMETRY_DEFAULT_CODEC

from komira_log_index.metric_transpose import metric_points_to_record_batch


comptime DEFAULT_METRIC_BUFFER_MAX: Int = 65_536
"""Ceiling on points held between flushes.

It is a second ceiling; the first one is the real defence. The engine's own
drain buffer already bounds retention per worker and counts what it drops. This
one exists because a caller can `offer_points` without ever flushing, and an
unbounded `List` under that mistake grows until the process dies, with an
out-of-memory kill and no metrics as the only symptom.

An overflow is counted, not silent (`points_dropped()`). It also drops the
oldest, not the newest: for a time series the newest points are the ones a
dashboard is asking for, and dropping them would make the sink degrade exactly
where it is being watched. Equal to one row group, so the buffer's natural size
is the encoder's natural size."""


struct ObjectStoreMetricSink[Storage: CloneableConditionalWriteStore](
    Movable, Deinitable
):
    """The at-rest store for metrics: `MetricPoint`s in, time-partitioned
    `(series_id, ts)`-sorted Parquet + a catalog entry out.

    Configure by construction (`Storage` = where the metrics go), `offer_points`
    what a drain handed you, `flush_pending_now()` per serve iteration,
    `final_flush()` on the way out.

    The input is a `List[MetricPoint]`, not an engine, and that is a seam
    decision. `SharedEngine.take_metric_points(worker_id)` returns exactly this
    list, so the caller writes `sink.offer_points(engine.take_metric_points(0))`
    and this struct never imports the engine. Two things fall out: the sink is
    testable with hand-built points and no installed log manager at all, and the
    way points reach the buffer can change without touching the store."""

    var _writer: TelemetryMetricSegmentWriter[Self.Storage]
    var _buf: List[MetricPoint]
    var _buf_max: Int
    var _segments_published: Int64
    var _points_published: Int64
    var _points_dropped: Int64
    var _publish_failures: Int64
    var _flush_publishes: Int64

    def __init__(
        out self,
        var store: Self.Storage,
        var writer_id: String,
        var telemetry_root: String = TELEMETRY_ROOT,
        codec: CompressionCodec = TELEMETRY_DEFAULT_CODEC,
        rows_per_row_group: Int = TELEMETRY_METRIC_ROWS_PER_ROW_GROUP,
        retry: RetryPolicy = RetryPolicy.default(),
        worker_disc: UInt8 = UInt8(0),
        buffer_max: Int = DEFAULT_METRIC_BUFFER_MAX,
        nonce: Int64 = Int64(-1),
    ) raises:
        """Build the sink publishing this node's `metrics` dataset into `store`.

        `writer_id` names the sub-lineage, so a multi-instance deploy keeps each
        instance's shard distinct — two instances sharing one id share a lineage
        and their publishes contend on one `_HEAD`. Pass the same string the log
        writer uses: the dataset segment sits ABOVE the lineage in the key, so
        there is no collision, and one identity across both datasets is what lets
        an operator who found a shard's logs find that shard's metrics.

        `telemetry_root` is a parameter for the same reason `Storage` is — WHERE
        is a property of the deployment — and this library reads no environment
        variable to decide it.

        `nonce` seeds the segment-uuid namespace and defaults to the wall clock.
        It is a parameter only so a test can force a collision; a shipped caller
        must never pass one."""
        if buffer_max <= 0:
            raise Error(
                "ObjectStoreMetricSink: buffer_max="
                + String(buffer_max)
                + " — a zero ceiling drops every point on offer and reports"
                " success, which is indistinguishable from a service that emits"
                " no metrics"
            )
        self._writer = TelemetryMetricSegmentWriter[Self.Storage](
            store^,
            writer_id^,
            telemetry_root^,
            codec,
            rows_per_row_group,
            retry,
            worker_disc,
            nonce,
        )
        self._buf = List[MetricPoint]()
        self._buf_max = buffer_max
        self._segments_published = Int64(0)
        self._points_published = Int64(0)
        self._points_dropped = Int64(0)
        self._publish_failures = Int64(0)
        self._flush_publishes = Int64(0)

    # -------------------------------------------------------------------------
    # PRODUCER
    # -------------------------------------------------------------------------

    def offer_points(mut self, var points: List[MetricPoint]) -> Int:
        """Accept a drain's owned points into the pending buffer. Returns the
        number ACCEPTED (which is `len(points)` unless the ceiling bit).

        Does not raise and does not publish: an offer is a hand-off, and a
        producer on the serve thread must not be able to take an encoder error.
        The publish is `flush_pending_now`.

        An empty offer is a no-op returning 0 — the engine's drain returns an
        empty list on every idle iteration, which is the common case."""
        var n = len(points)
        if n == 0:
            _ = points^
            return 0
        for i in range(n):
            self._buf.append(points[i].copy())
        _ = points^
        # Overflow drops the oldest. See DEFAULT_METRIC_BUFFER_MAX.
        var over = len(self._buf) - self._buf_max
        if over > 0:
            var keep = List[MetricPoint](capacity=self._buf_max)
            for i in range(over, len(self._buf)):
                keep.append(self._buf[i].copy())
            self._buf = keep^
            self._points_dropped += Int64(over)
        return n

    # -------------------------------------------------------------------------
    # THE FLUSH
    # -------------------------------------------------------------------------

    def _publish_buffer(mut self) raises -> Int:
        """The one flush body. Transpose the pending points, publish the
        `metrics` base artifact(s), clear the buffer. Returns the number of
        points published.

        One body, not two copies. `flush_pending_now` and `final_flush` differ
        only in what they are called for, and the ordering inside is the thing
        this module exists to get right — a second copy is a second place for it
        to be resequenced.

        An empty buffer publishes nothing and touches the store zero times.
        Not an empty object, not a manifest append, not a `_HEAD` read. This is
        the load-bearing property of the whole cost model (a PUT
        costs far more than the bytes it carries), and it is why
        the check is HERE, before the transpose, as well as inside the writer —
        an empty 0-row batch would otherwise be built and concatenated on every
        idle serve iteration.

        The buffer is cleared only after the publish returns. A publish that
        raises leaves the points pending, so the next flush retries them rather
        than dropping them — for a counter that is the difference between a gap
        and a wrong rate."""
        var n = len(self._buf)
        if n == 0:
            return 0
        var batch = metric_points_to_record_batch(self._buf)
        var slab = Slab[RecordBatch](capacity=1)
        slab.append(batch^)
        var entries = self._writer.publish_batches(slab^)
        # Cleared here — AFTER the publish returned without raising.
        self._buf = List[MetricPoint]()
        var published = Int64(0)
        for k in range(len(entries)):
            self._segments_published += Int64(1)
            published += entries[k].row_count
        self._points_published += published
        if len(entries) > 0:
            self._flush_publishes += Int64(1)
        return Int(published)

    def flush_pending_now(mut self) raises -> Int:
        """THE PER-ITERATION FLUSH. Publish everything buffered, synchronously,
        on the calling thread. Returns the number of points published (0 ==
        nothing was pending).

        This is the flush-before-freeze point: the instance can be frozen the
        moment the response is written, so the serve loop publishes while it
        still holds the CPU."""
        return self._publish_buffer()

    def final_flush(mut self) raises -> Int:
        """The shutdown flush. Publish the last partial buffer within
        the shutdown grace period. Idempotent — a no-op when nothing
        is pending. Returns the number of points published.

        It does not drain the engine. This sink does not own an
        engine (see the struct docstring), so it cannot take the trailing points
        for you: the caller must `offer_points(engine.take_metric_points(...))`
        first. Calling this alone publishes what it holds, and the points
        emitted since the last offer stay in the engine's buffer."""
        return self._publish_buffer()

    def try_flush_pending_now(mut self) -> Int:
        """`flush_pending_now`, with a publish failure COUNTED instead of raised.

        For a serve loop that must not take a telemetry error: a failed
        flush is counted, not raised. Returns points published; 0 with
        `publish_failures()` advanced means the flush failed and the points are
        STILL PENDING for the next attempt.

        Not the default, and not offered as one. A caller that swallows every
        publish error and never reads `publish_failures()` has a metrics pipeline
        that is indistinguishable from a working one while writing nothing —
        which is the failure this sink exists to prevent. The raising
        form is the default so the choice to swallow is explicit at the call
        site."""
        try:
            return self._publish_buffer()
        except e:
            self._publish_failures += Int64(1)
            print(
                "ERROR ObjectStoreMetricSink: the metrics segment could not be"
                " published; the points remain pending for the next flush:",
                String(e),
            )
            return 0

    # -------------------------------------------------------------------------
    # OBSERVABILITY. A metrics sink that cannot say whether it wrote anything is
    # the thing it was built to replace.
    # -------------------------------------------------------------------------

    @always_inline
    def buffered_points(self) -> Int:
        """Points accepted and not yet published."""
        return len(self._buf)

    @always_inline
    def buffer_max(self) -> Int:
        return self._buf_max

    @always_inline
    def segments_published(self) -> Int64:
        """Parquet objects published — the artifact a time-range read opens."""
        return self._segments_published

    @always_inline
    def points_published(self) -> Int64:
        """Metric points landed in the store. The number that answers "did any
        of this actually land"."""
        return self._points_published

    @always_inline
    def points_dropped(self) -> Int64:
        """Points LOST to the pending-buffer ceiling, cumulative. NON-ZERO means
        this service's metrics went missing and it is never cosmetic — see
        `DEFAULT_METRIC_BUFFER_MAX` for the only way it can happen."""
        return self._points_dropped

    @always_inline
    def publish_failures(self) -> Int64:
        """Publishes that failed under `try_flush_pending_now`. NON-ZERO means a
        flush did not land; the points were retained, so this is a latency
        symptom until it stops being one."""
        return self._publish_failures

    @always_inline
    def flush_publishes(self) -> Int64:
        """Flushes that actually published a segment — the proxy a serve loop or
        a test asserts is advancing. Distinct from `flush_pending_now` CALL
        count, which is dominated by idle iterations that publish nothing."""
        return self._flush_publishes
