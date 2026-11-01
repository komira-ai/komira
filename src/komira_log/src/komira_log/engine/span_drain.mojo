# =============================================================================
# komira_log.engine.span_drain — SPAN records → OTLP-shaped JSON (P4a).
# =============================================================================
#
# The trace half of the unified drain. The log drain (`drain.mojo`) routes on
# the record's `kind`: REC_LOG → a text line; REC_SPAN_OPEN / REC_SPAN_CLOSE →
# this module. A complete span is an OPEN + a CLOSE record with the same
# span_id; this drain CORRELATES the pair and emits ONE OTLP-shaped JSON span.
#
# # The OTLP JSON shape (rendered by komira_trace.exporter.format_span_json_line)
#
# This is the trace exporter's schema, rendered by the very function it uses (the analyzer already
# ingests it):
#   {"trace_id":"<hex>","span_id":N,"parent_id":N,"name":"foo",
#    "start_ns":N,"end_ns":N,"worker_id":N,"flags":N}
# The trace_id is rendered as a 32-hex-char (16-byte) lowercase string; span_id
# / parent_id are decimal. start_ns / end_ns are wall-clock epoch-nanoseconds
# from the raw-tick → wall conversion via the calibration anchor. (The obs
# `links` array is omitted in P4a — the unified span surface does not yet carry
# cross-thread happens-before links; that rides in when the obs consumers
# migrate in P4b. The shape is otherwise identical.)
#
# # OPEN/CLOSE pairing across drain batches (the open-span table)
#
# A span is NOT complete until its CLOSE is observed, and OPEN+CLOSE can land in
# DIFFERENT drain batches (the OPEN drained on one idle window, the CLOSE on a
# later one). The drain therefore maintains an `OpenSpanTable`: an OPEN inserts
# a pending entry; a CLOSE finds the pending entry by span_id, fills end_ns, and
# EMITS the completed OTLP span (removing it from the table). Entries with no
# CLOSE yet stay pending across batches. This is the SAME OPEN+CLOSE-join the
# obs `_join_packets_to_records` does, made incremental so a long-lived span
# whose OPEN/CLOSE straddle batches still completes correctly.
#
# Encapsulation: pure value/ref flow. `PendingSpan` is POD-of-scalars +
# a small `String` name (the name is resolved from the site dict at OPEN time,
# so the table doesn't need the dict at CLOSE time). The table is a plain owned
# `List[PendingSpan]` — heap-owned by the List, never byte-slab-stored. No
# `UnsafePointer`, no wildcard origin.
# =============================================================================

from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    REC_SPAN_OPEN,
    REC_SPAN_CLOSE,
    REC_METRIC,
)
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.engine.calibration import CalibrationAnchor
from komira_log.engine.span_emit import (
    span_open_parent_id,
    span_open_trace_lo,
    span_open_trace_hi,
)
from komira_log.engine.drain import decode_one
from komira_log.engine.metric_emit import (
    decode_metric_point,
    metric_record_is_decodable,
)

from komira_metrics.metric_point import MetricPoint
from komira_trace.span_record import SPAN_FLAG_ROOT
from komira_trace.exporter import (
    format_span_json_line,
    json_escape,
    trace_id_hex_128,
)


# -----------------------------------------------------------------------------
# JSON helper — the escape is komira_trace's, kept here under its old name.
# -----------------------------------------------------------------------------


def _json_escape(imm s: String) -> String:
    """Minimal JSON string escape: `komira_trace.exporter.json_escape`, the
    single copy. Kept as a named wrapper so `test_log_bytes_non_ascii`'s
    falsifier 8 still reaches the escape through this module: restoring
    `chr(Int(c))` in the trace escape fails that test through this wrapper."""
    return json_escape(s)


# -----------------------------------------------------------------------------
# PendingSpan — an OPEN observed but not yet CLOSEd (or just completed). POD-of-
# scalars + the resolved name String (resolved at OPEN time from the site dict).
# -----------------------------------------------------------------------------


@fieldwise_init
struct PendingSpan(Copyable, Movable):
    var span_id: UInt64
    var parent_id: UInt64
    var trace_lo: UInt64
    var trace_hi: UInt64
    var start_ns: Int64
    var end_ns: Int64  # 0 until the CLOSE lands
    var worker_id: UInt32
    var flags: UInt32
    var closed: Bool
    var name: String


def _format_span_otlp(span: PendingSpan) -> String:
    """Render one completed span as an OTLP-shaped JSON line: the trace
    exporter's span-line formatter (`format_span_json_line`), minus the
    v0.4-unused links."""
    return format_span_json_line(
        trace_id_hex_128(span.trace_hi, span.trace_lo),
        Int(span.span_id),
        Int(span.parent_id),
        span.name,
        Int(span.start_ns),
        Int(span.end_ns),
        Int(span.worker_id),
        Int(span.flags),
    )


# -----------------------------------------------------------------------------
# OpenSpanTable — the cross-batch OPEN/CLOSE correlator. An OPEN inserts a
# pending entry; a CLOSE completes the matching entry and the caller emits it.
# Entries with no CLOSE yet survive across `ingest` calls (drain batches).
# -----------------------------------------------------------------------------


struct OpenSpanTable(Movable):
    """Maintains pending (OPEN-without-CLOSE) spans across drain batches.

    `ingest_open` adds a pending span (parsed from a SPAN_OPEN record, name
    resolved from the dict). `ingest_close` finds the matching pending span by
    span_id, fills end_ns, and returns the completed OTLP JSON line (or None if
    the CLOSE has no matching OPEN — a dropped/never-opened span). The owned
    `List[PendingSpan]` is heap-owned by the List (no stale pointer)."""

    var _pending: List[PendingSpan]

    def __init__(out self):
        self._pending = List[PendingSpan]()

    def pending_count(self) -> Int:
        var n = 0
        for i in range(len(self._pending)):
            if not self._pending[i].closed:
                n += 1
        return n

    def ingest_open(
        mut self,
        rec: LogEventRecord,
        worker_id: Int,
        dict: SiteDictionary,
        anchor: CalibrationAnchor,
    ):
        """Record a SPAN_OPEN as a pending span. The wall-time start is the
        raw-tick → ns conversion via the anchor; the name comes from the site
        dict (the same comptime digest the emit side registered). `worker_id`
        is the per-core ring this record drained from (spans are emitted into
        `ring(worker_id)`), recorded on the OTLP span."""
        var parent_id = span_open_parent_id(rec)
        var trace_lo = span_open_trace_lo(rec)
        var trace_hi = span_open_trace_hi(rec)
        var start_ns = anchor.tick_to_wall_ns(rec.timestamp)

        var name_opt = dict.lookup_fmt(rec.site_id)
        var name: String
        if name_opt:
            name = name_opt.value()
        else:
            name = String("__id_") + String(Int(rec.site_id))

        var flags = UInt32(0)
        if parent_id == UInt64(0):
            flags = flags | SPAN_FLAG_ROOT

        self._pending.append(
            PendingSpan(
                rec.corr_id,
                parent_id,
                trace_lo,
                trace_hi,
                start_ns,
                Int64(0),
                UInt32(worker_id),
                flags,
                False,
                name^,
            )
        )

    def ingest_close(
        mut self, rec: LogEventRecord, anchor: CalibrationAnchor
    ) -> Optional[String]:
        """Complete the pending span matching this SPAN_CLOSE's span_id. Returns
        the completed OTLP JSON line, or None if no matching OPEN is pending
        (a CLOSE whose OPEN was dropped/never seen)."""
        var end_ns = anchor.tick_to_wall_ns(rec.timestamp)
        for i in range(len(self._pending)):
            if (
                self._pending[i].span_id == rec.corr_id
                and not self._pending[i].closed
            ):
                self._pending[i].end_ns = end_ns
                self._pending[i].closed = True
                return Optional[String](_format_span_otlp(self._pending[i]))
        return Optional[String]()

    def drop_completed(mut self):
        """Compact the table: drop entries already emitted (closed). Keeps the
        pending (still-open) spans across batches. Called by the drain after a
        batch so the table doesn't grow unbounded."""
        var kept = List[PendingSpan]()
        for i in range(len(self._pending)):
            if not self._pending[i].closed:
                kept.append(self._pending[i].copy())
        self._pending = kept^


# -----------------------------------------------------------------------------
# A drain-result split: log text lines + OTLP span JSON lines, in the order the
# records were observed (interleaved logs+spans on one ring → one drain → two
# output streams). This is the unified-pipeline shape the test asserts.
# -----------------------------------------------------------------------------


@fieldwise_init
struct UnifiedDrainResult(Movable):
    """Every output stream one ring produces, one field per record kind.

    ★ `metric_points` IS THE THIRD STREAM, AND IT RIDES THIS STRUCT RATHER
    THAN THE ENGINE'S `_metric_buf` BECAUSE THAT IS WHAT THIS DRAIN ALREADY DOES
    WITH SPANS. `drain_worker_unified` does not put `span_lines` into
    `_span_buf` either; the unified drain's whole contract is "one ring in,
    every decoded stream out, by value". Routing metrics here and spans there
    would give this one drain two egress mechanisms, which is precisely the
    split the single span channel avoids. The engine's three OTHER drains cannot do this — their
    return types are log text and log views — which is why they retain into
    `_metric_buf` instead.

    ⛔ AND `metric_points` IS `List[MetricPoint]`, NOT `List[String]`. A span's
    egress form is a rendered OTLP line, so `span_lines` is text; a metric's is
    POD all the way to the exporter. Pre-rendering here is a dead end. The channel shape is shared; the payload
    type is not."""

    var log_lines: List[String]
    var span_lines: List[String]
    var metric_points: List[MetricPoint]


def drain_unified(
    mut ring: LogRecordRing,
    worker_id: Int,
    dict: SiteDictionary,
    anchor: CalibrationAnchor,
    mut open_spans: OpenSpanTable,
) -> UnifiedDrainResult:
    """Drain a ring fully, routing each record by `kind`:
       * REC_LOG        → a decoded text line (drain.decode_one),
       * REC_SPAN_OPEN  → a pending entry in `open_spans`,
       * REC_SPAN_CLOSE → completes the matching pending span → an OTLP line,
       * REC_METRIC     → a decoded `MetricPoint`.
    Spans whose OPEN/CLOSE straddle drain batches stay pending in `open_spans`
    across calls. After the pass, completed pending entries are compacted out.
    A metric needs no such pairing — one record IS one point — which is why this
    arm is four lines where the span arms are two functions.
    """
    var log_lines = List[String]()
    var span_lines = List[String]()
    var metric_points = List[MetricPoint]()
    while True:
        var rec_opt = ring.try_pop()
        if not rec_opt:
            break
        var rec = rec_opt.value().copy()
        if rec.kind == REC_SPAN_OPEN:
            open_spans.ingest_open(rec, worker_id, dict, anchor)
        elif rec.kind == REC_SPAN_CLOSE:
            var line = open_spans.ingest_close(rec, anchor)
            if line:
                span_lines.append(line.value())
        elif rec.kind == REC_METRIC:
            # Refused-and-counted rather than half-decoded when the record
            # is not decodable — an arena-spilled histogram payload (the codec encodes
            # `MetricPoint` only; `HistogramPoint` has no ring codec yet) or a
            # truncated header.
            # `metric_record_is_decodable` is the ONE shared guard; every
            # consumer that can produce a point calls it rather than
            # re-deriving the condition.
            if metric_record_is_decodable(rec):
                metric_points.append(decode_metric_point(rec, anchor))
            else:
                ring.note_metric_record_dropped()
        elif rec.kind == REC_LOG:
            # REC_LOG — the text decode path. EXPLICIT rather than the open
            # `else`, which would decode every unrecognised kind as a log
            # record; the `else` below refuses what no arm claims.
            log_lines.append(decode_one(rec, ring, dict, anchor))
        else:
            # THE CLOSED DEFAULT — counted and refused.
            ring.note_unknown_kind()
    open_spans.drop_completed()
    ring.reset_arena()
    return UnifiedDrainResult(log_lines^, span_lines^, metric_points^)
