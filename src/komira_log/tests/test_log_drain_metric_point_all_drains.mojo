# =============================================================================
# test_log_drain_metric_point_all_drains.mojo
#   `REC_METRIC = 3` — A METRIC POINT SURVIVES EVERY DRAIN THAT CAN CARRY ONE,
#   AND IS COUNTED BY EVERY DRAIN THAT CANNOT.
# =============================================================================
#
# A fourth record kind on the log ring, its builder/decoder (`metric_emit.mojo`),
# and an arm at EVERY ring consumer.
#
# ⚠ THERE ARE SIX DRAINS, NOT FOUR. A change scoped to the four engine-facing
# ones would ship two silent holes. Every consumer of `LogRecordRing.try_pop()`:
#
#   1. SharedEngine.drain_worker              -> Int                (sink)
#   2. SharedEngine.drain_worker_to_lines     -> List[String]
#   3. SharedEngine.drain_worker_to_records   -> List[LogRecordView]
#   4. span_drain.drain_unified               -> UnifiedDrainResult
#        (reached from SharedEngine.drain_worker_unified)
#   5. drain.drain_to_lines                   -> List[String]        free fn
#   6. drain.drain_to_views                   -> List[LogRecordView] free fn,
#        the one a deployed service reaches (e.g. through `komira_log_index`).
#
# EACH OF THE SIX GETS AN ARM, AND THE ARM IS NOT THE SAME AT ALL SIX, because
# what a drain can DO with a point is decided by its return type:
#
#   1-3  RETAIN into `_metric_buf[wid]`, read back by `take_metric_points`.
#        Their return types are a count, log text and log views; a point is none
#        of those, so it leaves out of band -- the span return channel's shape,
#        reused unchanged.
#   4    RETURN it in `UnifiedDrainResult.metric_points`. This drain already
#        returns its span stream by value (`drain_worker_unified` does NOT feed
#        `_span_buf`), so routing metrics through the engine buffer here would
#        give ONE drain two egress mechanisms.
#   5-6  SKIP AND COUNT. Bare free fns with no engine and no channel, the same
#        treatment they already give a span.
#
# ⛔ THE FALSIFIER, AND ITS METHODOLOGY: revert ARMS ONLY, never the whole
# change, so every failure is an assertion at a named line rather than a compile
# error that proves nothing. Reverting the THREE `elif rec.kind == REC_METRIC`
# arms in `shared_engine.mojo` (keeping every constant, counter, buffer,
# accessor, `metric_emit.mojo`, and the `drain.mojo` / `span_drain.mojo` arms)
# must turn exactly these red, each at its own named assertion:
#
#   drain_worker             "the point was RETAINED"
#   drain_worker_to_lines    "the point was RETAINED"
#   drain_worker_to_records  "the point was RETAINED"
#   capture-off counting     "the unretainable points were COUNTED"
#   retention ceiling        "retention stopped at the ceiling"
#   closed-default pairing   "the metric was retained"
#   undecodable refusal      "both refusals were COUNTED"
#
# ★ AND THE CASES THAT STAY GREEN UNDER THAT REVERT ARE THE POINT, NOT A
# SHORTFALL. `test_drain_worker_unified_returns_the_decoded_point` is the
# DISCRIMINATING CONTROL: same engine, same `build_metric_record`, same push
# onto ring(0), same field assertions -- through the ONE drain whose arm the
# revert does not touch (it lives in `span_drain.mojo`). If it went red, the red
# would be the harness failing to produce a decodable REC_METRIC at all, and the
# other reds would mean nothing. A suite where everything fails before and
# passes after cannot tell "the fix worked" from "the test was always broken".
# `test_free_fn_drains_count_the_metric_records_they_skip` and
# `test_the_log_half_of_every_drain_is_unchanged` are the second and third
# controls, on the same principle. The pure encode/decode cases (field
# assignment, timestamp round-trip, gauge round-trip) do not touch a drain at
# all, and their staying green is what says such a red is about ROUTING and not
# about the encoding.
#
# ⚠ NOTE WHICH HALF OF `test_closed_default_still_refuses_an_unknown_kind`
# GOES RED: its ENGINE half, at "the metric was retained". Its FREE-FN half —
# "the unknown-kind counter is EXACTLY 1" — holds either way, which is the
# closed default's own assertion. Making REC_METRIC a KNOWN kind must not move
# that number in either direction.
#
# ⚠ THIS FILE COVERS THE SCALAR HALF ONLY, because that is the half that
# exists. `MetricPoint` has a SIBLING — `HistogramPoint` — and it has NO
# ring encoding; case 11 pins that a record claiming the arena payload is
# REFUSED AND COUNTED rather than half-decoded, which is the fail-closed
# behaviour until the codec is written. Do not read a green run here as
# histogram coverage.
#
# Encapsulation: pure value flow — a local engine, POD `MetricPoint`s,
# `List[MetricPoint]` out. No `UnsafePointer`, no wildcard origin, and the new
# `_metric_buf` is a plain owned `List[List[MetricPoint]]` on a struct field,
# never inside a byte-backed slab.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK
from komira_metrics.metric_point import (
    MetricPoint,
    METRIC_COUNTER,
    METRIC_GAUGE,
    METRIC_KIND_UNKNOWN,
    counter_point,
    gauge_point,
)

from komira_log import SharedEngine
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_INFO
from komira_log.engine.drain import drain_to_lines, drain_to_views
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    REC_METRIC,
    FLAG_HAS_ARG_OVERFLOW,
)
from komira_log.engine.metric_emit import (
    build_metric_record,
    decode_metric_point,
    metric_record_is_decodable,
    metric_record_kind,
    METRIC_BLOB_BYTES,
)
from komira_log.engine.site_dictionary import SiteDictionary, fnv1a_32
from komira_log.engine.calibration import CalibrationAnchor, read_raw_ticks


comptime _NAME = "w7.requests"
comptime _MODULE = "komira_w7"
comptime _FMT = "w7 log {}"

# The values the round-trip pins. Chosen so no two are equal — a decoder that
# crosses two fields cannot pass by coincidence.
comptime _VALUE: Int64 = Int64(4242)
comptime _ATTRSET: UInt32 = UInt32(0xABCD1234)
comptime _EXEMPLAR: UInt64 = UInt64(0x00DEADBEEF00CAFE)


def _fixed_anchor() -> CalibrationAnchor:
    """tick_hz = 1e9 and tick0 = 0, so tick -> ns is the identity plus wall0.
    That is what makes the timestamp assertions EXACT rather than approximate:
    an anchored conversion asserted with a tolerance would pass for a decoder
    that read the wrong 8 bytes."""
    return CalibrationAnchor(
        tick0=UInt64(0),
        wall0_ns=UInt64(1_780_272_000) * UInt64(1_000_000_000),
        tick_hz=UInt64(1_000_000_000),
    )


def _a_point() raises -> MetricPoint:
    """A monotonic DELTA counter point built through `komira_metrics`'s own
    constructor — a hand-assembled `MetricPoint` could disagree with the
    kind/flag pairing the exporter relies on and would prove nothing."""
    var p = counter_point(
        name_id=fnv1a_32(_NAME),
        scope_id=fnv1a_32(_MODULE),
        attrset_id=_ATTRSET,
        value=_VALUE,
        start_time_unix_ns=UInt64(1_000_000_000),
        time_unix_ns=UInt64(3_500_000_000),
    )
    p.set_exemplar(_EXEMPLAR)
    return p^


def _a_metric_record() raises -> LogEventRecord:
    var rec_opt = build_metric_record(_a_point(), read_raw_ticks())
    assert_true(rec_opt.__bool__(), "the point encoded to a record")
    return rec_opt.value().copy()


def _engine() raises -> SharedEngine:
    var f = EnvFilter()
    var eng = SharedEngine(num_workers=1, filter=f^)
    eng.set_capture_metrics(True)
    return eng^


def _log_record() raises -> LogEventRecord:
    var rec = LogEventRecord()
    rec.kind = REC_LOG
    rec.level = LEVEL_INFO
    rec.site_id = fnv1a_32(_FMT)
    rec.module_id = fnv1a_32(_MODULE)
    return rec^


def _assert_is_our_point(p: MetricPoint) raises:
    """Every field the encoding assigns, checked. A decode that lands the right VALUE in
    the wrong field is the failure this file exists to catch."""
    assert_equal(Int(p.name_id), Int(fnv1a_32(_NAME)), "name_id (<- site_id)")
    assert_equal(
        Int(p.scope_id), Int(fnv1a_32(_MODULE)), "scope_id (<- module_id)"
    )
    assert_equal(Int(p.attrset_id), Int(_ATTRSET), "attrset_id (<- arg_blob)")
    assert_equal(Int(p.kind), Int(METRIC_COUNTER), "instrument kind (<- flags)")
    assert_true(p.is_monotonic(), "the monotonic flag survived")
    assert_true(not p.value_is_double(), "and value_is_double did not appear")
    assert_true(p.has_exemplar(), "the exemplar flag survived")
    assert_equal(
        Int(p.exemplar_span_id), Int(_EXEMPLAR), "exemplar (<- corr_id)"
    )
    assert_equal(Int(p.as_int()), Int(_VALUE), "the value")


# -----------------------------------------------------------------------------
# 1-3. THE THREE ENGINE DRAINS RETAIN THE POINT.
# -----------------------------------------------------------------------------


def test_drain_worker_retains_the_metric_point() raises -> None:
    """The sink-writing hot path. ⚠ Unlike a span, a metric has NO sink
    fallback — `drain_worker` must NOT render a point into the text sink — so
    this drain gets the retained buffer exactly like the two below."""
    var eng = _engine()
    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")

    var n = eng.drain_worker(0, 64)
    assert_equal(n, 1, "the metric record was consumed off the ring")

    var pts = eng.take_metric_points(0)
    assert_equal(len(pts), 1, "the point was RETAINED")
    _assert_is_our_point(pts[0])
    assert_equal(Int(eng.metrics_dropped_count()), 0, "nothing was dropped")
    assert_equal(
        Int(eng.unknown_kind_dropped_count()),
        0,
        "and REC_METRIC is a KNOWN kind now: not an unknown-kind refusal",
    )


def test_drain_worker_to_lines_retains_the_metric_point() raises -> None:
    var eng = _engine()
    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")

    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(
        len(lines),
        0,
        (
            "no LOG line: a metric must NOT be rendered into the log text this"
            " drain returns"
        ),
    )

    var pts = eng.take_metric_points(0)
    assert_equal(len(pts), 1, "the point was RETAINED")
    _assert_is_our_point(pts[0])
    assert_equal(Int(eng.metrics_dropped_count()), 0, "nothing was dropped")


def test_drain_worker_to_records_retains_the_metric_point() raises -> None:
    """THE INDEXING PATH (`komira_log_index`'s `ServiceLogSink.pump` drains
    through it). A metric point must never become a row in
    the log index — metrics get their own store."""
    var eng = _engine()
    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")

    var views = eng.drain_worker_to_records(0, 64)
    assert_equal(
        len(views), 0, "no LOG view: a metric must NOT become a log index row"
    )

    var pts = eng.take_metric_points(0)
    assert_equal(len(pts), 1, "the point was RETAINED")
    _assert_is_our_point(pts[0])
    assert_equal(Int(eng.metrics_dropped_count()), 0, "nothing was dropped")


# -----------------------------------------------------------------------------
# 4. ⛔ THE DISCRIMINATING CONTROL. Passes BEFORE and AFTER — read the header.
# -----------------------------------------------------------------------------


def test_drain_worker_unified_returns_the_decoded_point() raises -> None:
    """The unified drain returns every stream it decodes BY VALUE — it does
    that for spans today (`drain_worker_unified` does not feed `_span_buf`
    either), so `metric_points` rides `UnifiedDrainResult` beside `span_lines`
    rather than going through the engine buffer.

    ★ Its arm lives in `span_drain.mojo`, which the RED revert did not touch, so
    this case passed in BOTH columns. That is what makes the three reds above
    mean "these drains drop metrics" rather than "this harness cannot build a
    decodable metric record"."""
    var eng = _engine()
    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")

    var res = eng.drain_worker_unified(0)
    assert_equal(len(res.log_lines), 0, "no log line")
    assert_equal(len(res.span_lines), 0, "no span line")
    assert_equal(len(res.metric_points), 1, "the point came back BY VALUE")
    _assert_is_our_point(res.metric_points[0])
    assert_equal(Int(eng.metrics_dropped_count()), 0, "nothing was dropped")


# -----------------------------------------------------------------------------
# 5. The bare free-fn drains skip metrics — but not silently.
# -----------------------------------------------------------------------------


def test_free_fn_drains_count_the_metric_records_they_skip() raises -> None:
    """SECOND CONTROL (its arms are in `drain.mojo`, untouched by an engine-arm
    revert).
    `drain_to_lines` / `drain_to_views` return log text and log views; a
    `MetricPoint` is neither, and neither fn has an engine to retain into.
    `drain_to_views` is the one a deployed service reaches."""
    var d = SiteDictionary()
    d.register[_FMT, _MODULE]()
    var anchor = _fixed_anchor()

    var ring = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    assert_true(ring.try_push(_a_metric_record()), "metric pushed")
    var lines = drain_to_lines(ring, d, anchor)
    assert_equal(len(lines), 0, "the metric record did NOT render as text")
    assert_equal(
        Int(ring.metric_record_dropped_count()),
        1,
        "the skipped metric record was COUNTED",
    )
    assert_equal(
        Int(ring.unknown_kind_dropped_count()),
        0,
        "REC_METRIC is a known kind: skipped, NOT counted as unknown",
    )

    var ring2 = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    assert_true(ring2.try_push(_a_metric_record()), "metric pushed")
    assert_true(ring2.try_push(_log_record()), "log pushed")
    var views = drain_to_views(ring2, d, anchor)
    assert_equal(len(views), 1, "ONLY the log record became a view")
    assert_equal(
        Int(ring2.metric_record_dropped_count()),
        1,
        "the skipped metric record was COUNTED",
    )


# -----------------------------------------------------------------------------
# 6. THIRD CONTROL: the LOG half of every drain is untouched.
# -----------------------------------------------------------------------------


def test_the_log_half_of_every_drain_is_unchanged() raises -> None:
    """Without this the suite above is satisfied by a drain that retains metrics
    and has stopped returning logs — a passing test over a broken logger. It
    runs a log record and a metric through the engine's three drains on ONE
    MIXED RING, and asserts NOTHING about retention; an assertion here would
    cost the suite its control."""
    var eng = _engine()
    eng.register_site[_FMT, _MODULE]()

    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")
    assert_true(eng.ring(0).try_push(_log_record()), "log pushed")
    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(lines), 1, "the LOG record still renders")
    assert_true(
        lines[0].find("<unknown site") < 0,
        "and renders as a real line, not a site miss",
    )

    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")
    assert_true(eng.ring(0).try_push(_log_record()), "log pushed")
    var views = eng.drain_worker_to_records(0, 64)
    assert_equal(len(views), 1, "the LOG record still becomes a view")

    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")
    assert_true(eng.ring(0).try_push(_log_record()), "log pushed")
    var n = eng.drain_worker(0, 64)
    assert_equal(n, 2, "both records were consumed by the sink drain")


# -----------------------------------------------------------------------------
# 7. Capture OFF: there is NO sink fallback for a metric on ANY drain.
# -----------------------------------------------------------------------------


def test_capture_off_counts_the_points_no_drain_can_keep() raises -> None:
    """⚠ THE ONE PLACE METRICS DIVERGE FROM SPANS. With span capture off,
    `drain_worker` writes the span to its SINK, because a span's egress form is
    a rendered line. A `MetricPoint` is POD to the exporter, and rendering it
    into the log sink is both a dead end and — on the
    deployed indexing drain — metric rows written into a production LOG index.
    So all three engine drains drop, and all three count."""
    var f = EnvFilter()
    var eng = SharedEngine(num_workers=1, filter=f^)
    assert_true(not eng.capture_metrics(), "capture starts OFF")

    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")
    _ = eng.drain_worker(0, 64)
    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")
    _ = eng.drain_worker_to_lines(0, 64)
    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")
    _ = eng.drain_worker_to_records(0, 64)

    assert_equal(
        len(eng.take_metric_points(0)), 0, "capture OFF retains nothing"
    )
    assert_equal(
        Int(eng.metrics_dropped_count()),
        3,
        (
            "the unretainable points were COUNTED -- a metrics pipeline that"
            " drops silently is worse than one that is off, because the graph"
            " still draws"
        ),
    )


# -----------------------------------------------------------------------------
# 8. The retention ceiling degrades to a counted drop, not unbounded growth.
# -----------------------------------------------------------------------------


def test_retained_buffer_is_bounded_and_the_overflow_is_counted() raises -> None:
    """Metrics are PERIODIC, so an unbounded retained buffer leaks at a constant
    rate for as long as the process lives — a stronger reason for the bound than
    spans had."""
    var eng = _engine()
    eng.set_metric_buf_max(2)
    assert_equal(eng.metric_buf_max(), 2, "the ceiling took")

    for _ in range(4):
        assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")
        _ = eng.drain_worker_to_lines(0, 64)

    assert_equal(eng.metric_buf_len(0), 2, "retention stopped at the ceiling")
    assert_equal(
        Int(eng.metrics_dropped_count()), 2, "and the excess was COUNTED"
    )


# -----------------------------------------------------------------------------
# 9. ⛔ THE CLOSED DEFAULT IS NOT REGRESSED. Making REC_METRIC a KNOWN kind must not make an
#    UNKNOWN one decodable, and the two counters must not bleed into each other.
# -----------------------------------------------------------------------------


def test_closed_default_still_refuses_an_unknown_kind() raises -> None:
    """A ring carrying BOTH a `kind = 200` record and a REC_METRIC. The unknown
    counter must be EXACTLY 1 (the closed default's assertion) and the metric counter
    EXACTLY 1 — the discriminating pairing, because a single-record test cannot
    tell "the closed default still fires" from "the metric arm swallowed it"."""
    var d = SiteDictionary()
    d.register[_FMT, _MODULE]()

    var ring = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    var junk = LogEventRecord()
    junk.kind = UInt8(200)
    assert_true(ring.try_push(junk^), "kind=200 pushed")
    assert_true(ring.try_push(_a_metric_record()), "metric pushed")

    var lines = drain_to_lines(ring, d, _fixed_anchor())
    assert_equal(len(lines), 0, "neither record rendered as a line")
    assert_equal(
        Int(ring.unknown_kind_dropped_count()),
        1,
        (
            "the unknown-kind counter is EXACTLY 1 -- a fourth known kind did"
            " not make an unrecognised one decodable"
        ),
    )
    assert_equal(
        Int(ring.metric_record_dropped_count()),
        1,
        "and the metric skip was counted on its OWN instrument",
    )

    # The same pairing through an ENGINE drain, where the metric arm retains
    # rather than skips: the unknown record must still be refused.
    var eng = _engine()
    var junk2 = LogEventRecord()
    junk2.kind = UInt8(200)
    assert_true(eng.ring(0).try_push(junk2^), "kind=200 pushed")
    assert_true(eng.ring(0).try_push(_a_metric_record()), "metric pushed")
    var views = eng.drain_worker_to_records(0, 64)
    assert_equal(len(views), 0, "the unknown record produced NO view")
    assert_equal(len(eng.take_metric_points(0)), 1, "the metric was retained")
    assert_equal(
        Int(eng.unknown_kind_dropped_count()),
        1,
        "and the unknown kind was still counted and refused",
    )
    assert_equal(
        Int(eng.metrics_dropped_count()), 0, "with no metric dropped to get it"
    )


# -----------------------------------------------------------------------------
# 10. The encoding itself: the field assignment, round-tripped.
# -----------------------------------------------------------------------------


def test_the_record_carries_the_ratified_field_assignment() raises -> None:
    var rec = _a_metric_record()
    assert_equal(Int(rec.kind), Int(REC_METRIC), "kind = 3")
    assert_equal(
        Int(rec.level),
        0,
        (
            "level = 0 BY CONVENTION, enforced here because this builder is the"
            " only writer of the kind"
        ),
    )
    assert_equal(
        Int(rec.n_args),
        0,
        (
            "n_args = 0 -- belt and braces: a seventh drain written without the"
            " metric arm renders an arg-less line instead of walking 48 bytes"
            " of payload as an arg table"
        ),
    )
    assert_equal(
        Int(rec.site_id), Int(fnv1a_32(_NAME)), "site_id carries name_id"
    )
    assert_equal(
        Int(rec.module_id), Int(fnv1a_32(_MODULE)), "module_id carries scope_id"
    )
    assert_equal(
        Int(rec.corr_id), Int(_EXEMPLAR), "corr_id carries exemplar_span_id"
    )
    assert_equal(
        Int(rec.arg_inline_len),
        METRIC_BLOB_BYTES,
        "arg_inline_len is the ACTUAL payload length: value(8)+attrset(4)+delta(8)",
    )
    assert_equal(Int(rec.arg_off), 0, "arg_off unused on the inline path")
    assert_equal(Int(rec.arg_len), 0, "arg_len unused on the inline path")
    assert_true(not rec.has_arg_overflow(), "and the overflow bit is CLEAR")
    assert_equal(
        Int(metric_record_kind(rec)),
        Int(METRIC_COUNTER),
        "the instrument kind reads back out of flags without a full decode",
    )


def test_the_timestamp_round_trips_through_the_anchor() raises -> None:
    """`timestamp` is RAW TICKS and the blob carries `time - start` as a DELTA,
    so only one instant is anchored and the two cannot drift apart across an
    anchor refresh. With tick_hz = 1e9 and tick0 = 0 the conversion is exact."""
    var anchor = _fixed_anchor()
    var tick = UInt64(7_000_000_000)
    var rec_opt = build_metric_record(_a_point(), tick)
    assert_true(rec_opt.__bool__(), "encoded")
    var p = decode_metric_point(rec_opt.value(), anchor)

    var expect_time = anchor.wall0_ns + tick
    assert_equal(
        Int(p.time_unix_ns), Int(expect_time), "time_unix_ns is the anchored tick"
    )
    # The source point spanned 1.0s -> 3.5s, i.e. a 2.5s interval.
    assert_equal(
        Int(p.time_unix_ns - p.start_time_unix_ns),
        2_500_000_000,
        "and the interval width survived as a delta",
    )
    _assert_is_our_point(p)


def test_a_gauge_round_trips_with_a_zero_width_window() raises -> None:
    """A gauge has no interval — `gauge_point` sets start == time — so the delta
    is 0 and the decoded window must be zero-width, NOT a window back to the
    epoch. This is also the second instrument kind through the 2-bit field: a
    kind encoder that ignored its argument would pass case 10 and fail here."""
    var g = gauge_point(
        name_id=fnv1a_32(_NAME),
        scope_id=fnv1a_32(_MODULE),
        attrset_id=_ATTRSET,
        value=Int64(17),
        time_unix_ns=UInt64(9_000_000_000),
    )
    var rec_opt = build_metric_record(g, UInt64(1_000_000_000))
    assert_true(rec_opt.__bool__(), "encoded")
    var p = decode_metric_point(rec_opt.value(), _fixed_anchor())
    assert_equal(Int(p.kind), Int(METRIC_GAUGE), "the GAUGE kind survived")
    assert_true(not p.is_monotonic(), "a gauge is not monotonic")
    assert_true(not p.has_exemplar(), "and carries no exemplar")
    assert_equal(Int(p.as_int()), 17, "the value")
    assert_equal(
        Int(p.time_unix_ns),
        Int(p.start_time_unix_ns),
        "a zero-width window, not a window back to the epoch",
    )


# -----------------------------------------------------------------------------
# 11. The two shapes that have no decoded form are REFUSED, not half-decoded.
# -----------------------------------------------------------------------------


def test_an_undecodable_metric_record_is_refused_and_counted() raises -> None:
    """`HistogramPoint` carries count + sum + min + max + 12 buckets = 128 B,
    plus this header's attrset_id(4) + start_ns_delta(8) = 140 B, against
    `ARG_INLINE_BYTES` = 48 — so a histogram record ALWAYS takes the
    `FLAG_HAS_ARG_OVERFLOW` arena path.

    ⛔ THE RING CODEC IS SCALAR-ONLY, so there is no encoder and no decoder for
    that shape and it is refused and counted rather than half-decoded into a
    point whose `value_bits` would be a bucket bound. The refusal rests only on
    "the arena codec is unbuilt", which is a residual with a shape (see
    `metric_emit.mojo`'s header) rather than an impossibility.

    The guard is shared by the four consumers that can produce a point; the two
    bare free fns skip a REC_METRIC unconditionally.

    `build_metric_record` also refuses `METRIC_KIND_UNKNOWN`, because 255
    truncated into the two-bit kind field lands on METRIC_HISTOGRAM — a
    default-constructed point would ride the ring claiming to be a histogram."""
    var eng = _engine()

    var spilled = _a_metric_record()
    spilled.flags = spilled.flags | FLAG_HAS_ARG_OVERFLOW
    assert_true(
        not metric_record_is_decodable(spilled),
        "the arena-spilled shape is not decodable",
    )

    var truncated = _a_metric_record()
    truncated.arg_inline_len = UInt16(METRIC_BLOB_BYTES - 1)
    assert_true(
        not metric_record_is_decodable(truncated),
        "and neither is a truncated header",
    )

    assert_true(eng.ring(0).try_push(spilled^), "spilled pushed")
    assert_true(eng.ring(0).try_push(truncated^), "truncated pushed")
    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(lines), 0, "neither rendered as a log line")
    assert_equal(
        len(eng.take_metric_points(0)), 0, "and neither became a point"
    )
    assert_equal(
        Int(eng.metrics_dropped_count()), 2, "both refusals were COUNTED"
    )
    assert_equal(
        Int(eng.unknown_kind_dropped_count()),
        0,
        "they are REC_METRIC records, not unknown kinds",
    )

    var bad = MetricPoint()
    assert_equal(
        Int(bad.kind),
        Int(METRIC_KIND_UNKNOWN),
        "a default-constructed point has an UNKNOWN kind",
    )
    assert_true(
        not build_metric_record(bad, read_raw_ticks()).__bool__(),
        "and the builder REFUSES to encode it",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
