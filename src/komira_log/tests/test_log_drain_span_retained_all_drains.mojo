# =============================================================================
# test_log_drain_span_retained_all_drains.mojo
#   A COMPLETED SPAN SURVIVES EVERY DRAIN — INCLUDING THE TWO THAT RETURN.
# =============================================================================
#
# `OpenSpanTable.ingest_close` RETURNS the completed OTLP span line — the whole
# span, correlated across batches and rendered. Every drain must keep it:
#
#     _ = self._open_spans.ingest_close(rec, anchor)     <- NEVER, in any drain
#
# Two of the engine's three drains RETURN log text / log views
# (`List[String]` / `List[LogRecordView]`), which have nowhere to put a span, so
# a discarded return value is the easy mistake there; `drain_worker` — the
# third drain, the one that writes to a sink rather than returning — keeps it
# naturally. That asymmetry is what these tests pin. `drain_worker_to_records`
# is the indexing path (`komira_log_index`'s `ServiceLogSink.pump`), so the
# moment tracing is enabled on a service that flushes, a discarding drain would
# destroy every span it produces, silently, with no counter moving.
#
# ⛔ THE FALSIFIER, AND ITS METHODOLOGY. Reverting the WHOLE change would make
# these compile-error, not fail — `spans_dropped_count` / `span_buf_max` would
# not exist — and a compile error proves nothing about an assertion. So revert
# ONLY the two drain ARMS back to `_ = ingest_close(...)`, keep every counter
# and accessor, and every failure is an assertion at a named line:
#
#   drain_worker_to_lines     "the completed span was RETAINED"
#   drain_worker_to_records   "the completed span was RETAINED"
#   capture-off counting      "the unretainable spans were COUNTED"
#   retention ceiling         "retention stopped at the ceiling"
#
# ⚠ THAT REVERT IS `shared_engine.mojo` ONLY, WHICH IS WHY CASE 7 STAYS GREEN
# UNDER IT. The free-fn span counting lives in `drain.mojo` and is a DIFFERENT
# property (a counted skip, not a kept return value); conflating the two would
# make a red unreadable. Case 7 has its own falsifier against `drain.mojo`:
# "both skipped span RECORDS were counted".
#
# ★ AND THE CASES THAT STAY GREEN UNDER THE REVERT ARE THE POINT, NOT A
# SHORTFALL. `test_drain_worker_retains_the_completed_span` is the
# DISCRIMINATING CONTROL: it drives the identical harness — same engine, same
# `start_span`/`end_span`, same `take_span_lines` assertion — through the ONE
# drain the revert does not touch. If it went red, the red would be the harness
# failing to produce a span at all, and the other reds would mean nothing. A
# suite where everything fails before and passes after cannot tell "the fix
# worked" from "the test was always broken".
#
# Encapsulation: pure value flow — a local engine, comptime span names,
# `List[String]` out. No `UnsafePointer`, no wildcard origin.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_spsc_ring.spsc_ring import OVERFLOW_BLOCK

from komira_log import SharedEngine
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_INFO
from komira_log.engine.drain import drain_to_lines, drain_to_views
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    REC_SPAN_OPEN,
    REC_SPAN_CLOSE,
)
from komira_log.engine.site_dictionary import SiteDictionary, fnv1a_32
from komira_log.engine.calibration import CalibrationAnchor


comptime _SPAN = "retained.span"
comptime _MODULE = "komira_span_test"
comptime _FMT = "span test log {}"


def _engine() raises -> SharedEngine:
    """An engine with the retained span collector ON — which is what a trace
    consumer sets (`EngineContext.drain_traces_to_jsonl`). With it OFF the
    returning drains have nowhere to put a span BY DESIGN, which is the
    separate case `test_capture_off_...` covers."""
    var f = EnvFilter()
    var eng = SharedEngine(num_workers=1, filter=f^)
    eng.set_capture_spans(True)
    return eng^


def _emit_one_span(mut eng: SharedEngine) raises:
    """One complete span on ring(0): a SPAN_OPEN and its matching SPAN_CLOSE.
    Both go through the engine's own public emit surface, so the record layout,
    the span-id allocation and the site registration are the real ones — a
    hand-built record could pair with nothing and would prove nothing."""
    var sid = eng.start_span[_SPAN, _MODULE](0)
    assert_true(sid != UInt64(0), "a span id was allocated")
    eng.end_span(sid, 0)


def _log_record() raises -> LogEventRecord:
    """A well-formed REC_LOG record for `_FMT` — the same hand-built shape
    `test_log_drain_unknown_kind_closed_default` uses. The engine has no
    `emit[...]`; the facade owns that surface and would drag the ambient
    global into a unit test of the drain."""
    var rec = LogEventRecord()
    rec.kind = REC_LOG
    rec.level = LEVEL_INFO
    rec.site_id = fnv1a_32(_FMT)
    rec.module_id = fnv1a_32(_MODULE)
    return rec^


def _assert_is_a_span_line(line: String) raises:
    """The retained line is the OTLP span JSON `ingest_close` renders, not some
    other string that happened to land in the buffer."""
    assert_true(line.find("\"name\":\"" + String(_SPAN) + "\"") >= 0, line)
    assert_true(line.find("\"span_id\"") >= 0, line)
    assert_true(line.find("\"end_ns\"") >= 0, line)


# -----------------------------------------------------------------------------
# 1-2. THE TWO BROKEN DRAINS.
# -----------------------------------------------------------------------------


def test_drain_worker_to_lines_retains_the_completed_span() raises -> None:
    var eng = _engine()
    _emit_one_span(eng)

    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(
        len(lines),
        0,
        (
            "no LOG line: a span must NOT be interleaved into the log text this"
            " drain returns"
        ),
    )
    assert_equal(Int(eng.pending_span_count()), 0, "the span completed")

    var spans = eng.take_span_lines(0)
    assert_equal(len(spans), 1, "the completed span was RETAINED")
    _assert_is_a_span_line(spans[0])
    assert_equal(
        Int(eng.spans_dropped_count()), 0, "and nothing was dropped to get it"
    )


def test_drain_worker_to_records_retains_the_completed_span() raises -> None:
    """THE DEPLOYED INDEXING PATH. `ServiceLogSink.pump` reaches exactly this
    drain, so this is the arm on which silent span destruction would have
    shipped."""
    var eng = _engine()
    _emit_one_span(eng)

    var views = eng.drain_worker_to_records(0, 64)
    assert_equal(
        len(views),
        0,
        "no LOG view: a span must NOT become a row in the log index",
    )
    assert_equal(Int(eng.pending_span_count()), 0, "the span completed")

    var spans = eng.take_span_lines(0)
    assert_equal(len(spans), 1, "the completed span was RETAINED")
    _assert_is_a_span_line(spans[0])
    assert_equal(
        Int(eng.spans_dropped_count()), 0, "and nothing was dropped to get it"
    )


# -----------------------------------------------------------------------------
# 3. ⛔ THE DISCRIMINATING CONTROL. Passes BEFORE and AFTER — read the header.
# -----------------------------------------------------------------------------


def test_drain_worker_retains_the_completed_span() raises -> None:
    """The drain the defect never touched, driven through the IDENTICAL harness
    as the two above. It passed with the arms reverted and it passes now; that
    is what makes the other two reds mean "this drain drops spans" rather than
    "this test cannot produce a span"."""
    var eng = _engine()
    _emit_one_span(eng)

    var n = eng.drain_worker(0, 64)
    assert_equal(n, 2, "both span records were consumed off the ring")

    var spans = eng.take_span_lines(0)
    assert_equal(len(spans), 1, "the completed span was RETAINED")
    _assert_is_a_span_line(spans[0])
    assert_equal(Int(eng.spans_dropped_count()), 0, "nothing dropped")


# -----------------------------------------------------------------------------
# 4. The second control: the LOG half of both fixed drains is unchanged.
# -----------------------------------------------------------------------------


def test_fixed_drains_still_return_their_log_records() raises -> None:
    """THE SECOND CONTROL, and like the first it passes BEFORE and AFTER.
    Without it the suite above is satisfied by a drain that retains spans and
    has stopped returning logs — a passing test over a broken logger. It runs a
    log record and a span through BOTH fixed drains on ONE MIXED RING, so it
    also pins that the fix did not start leaking span JSON into the log output
    the callers of these two drains actually asked for. It asserts NOTHING
    about retention; that is tests 1-2's job, and an assertion here would cost
    the suite its control."""
    var eng = _engine()
    eng.register_site[_FMT, _MODULE]()

    _emit_one_span(eng)
    assert_true(eng.ring(0).try_push(_log_record()), "log record pushed")
    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(lines), 1, "the LOG record still renders")
    assert_true(
        lines[0].find("<unknown site") < 0,
        "and renders as a real line, not a site miss",
    )
    assert_true(lines[0].find("span_id") < 0, "with no span JSON in it")

    _emit_one_span(eng)
    assert_true(eng.ring(0).try_push(_log_record()), "log record pushed")
    var views = eng.drain_worker_to_records(0, 64)
    assert_equal(len(views), 1, "the LOG record still becomes a view")


# -----------------------------------------------------------------------------
# 5. Capture OFF: the returning drains have no sink, so the span is lost —
#    but LOST COUNTED, which is the whole difference from the defect.
# -----------------------------------------------------------------------------


def test_capture_off_counts_the_spans_the_returning_drains_cannot_keep(
) raises -> None:
    var f = EnvFilter()
    var eng = SharedEngine(num_workers=1, filter=f^)
    # capture is OFF by default — a pure logging engine retains nothing.
    assert_true(not eng.capture_spans(), "capture starts OFF")

    _emit_one_span(eng)
    _ = eng.drain_worker_to_lines(0, 64)
    _emit_one_span(eng)
    _ = eng.drain_worker_to_records(0, 64)

    assert_equal(len(eng.take_span_lines(0)), 0, "capture OFF retains nothing")
    assert_equal(
        Int(eng.spans_dropped_count()),
        2,
        (
            "the unretainable spans were COUNTED -- a silent loss and a process"
            " that emits no spans are indistinguishable from outside"
        ),
    )


# -----------------------------------------------------------------------------
# 6. The retention ceiling degrades to a counted drop, not to unbounded growth.
# -----------------------------------------------------------------------------


def test_retained_buffer_is_bounded_and_the_overflow_is_counted() raises -> None:
    var eng = _engine()
    eng.set_span_buf_max(2)
    assert_equal(eng.span_buf_max(), 2, "the ceiling took")

    for _ in range(5):
        _emit_one_span(eng)
        _ = eng.drain_worker_to_lines(0, 64)

    assert_equal(eng.span_buf_len(0), 2, "retention stopped at the ceiling")
    assert_equal(
        Int(eng.spans_dropped_count()), 3, "and the excess was COUNTED"
    )


# -----------------------------------------------------------------------------
# 7. The bare free-fn drains still skip spans — but no longer silently.
# -----------------------------------------------------------------------------


def test_free_fn_drains_count_the_span_records_they_skip() raises -> None:
    """`drain_to_lines` / `drain_to_views` take a bare ring and have NO
    `OpenSpanTable`, so they cannot pair an OPEN with a CLOSE and skip both
    records. That skip is correct — but it must be counted, or a process whose
    spans all landed here looks exactly like one that emitted none.
    `drain_to_views` is the free fn a deployed service reaches."""
    var d = SiteDictionary()
    d.register[_FMT, _MODULE]()
    var anchor = CalibrationAnchor(
        tick0=UInt64(0),
        wall0_ns=UInt64(1_780_272_000) * UInt64(1_000_000_000),
        tick_hz=UInt64(1_000_000_000),
    )

    var ring = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    var op = LogEventRecord()
    op.kind = REC_SPAN_OPEN
    op.site_id = fnv1a_32(_SPAN)
    var cl = LogEventRecord()
    cl.kind = REC_SPAN_CLOSE
    cl.corr_id = UInt64(7)
    assert_true(ring.try_push(op^), "open pushed")
    assert_true(ring.try_push(cl^), "close pushed")

    var lines = drain_to_lines(ring, d, anchor)
    assert_equal(len(lines), 0, "neither span record rendered as text")
    assert_equal(
        Int(ring.span_record_dropped_count()),
        2,
        "both skipped span RECORDS were counted",
    )
    assert_equal(
        Int(ring.unknown_kind_dropped_count()),
        0,
        "a span is a known kind: skipped, NOT counted as unknown",
    )

    var ring2 = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    var op2 = LogEventRecord()
    op2.kind = REC_SPAN_OPEN
    var log2 = LogEventRecord()
    log2.kind = REC_LOG
    log2.level = LEVEL_INFO
    log2.site_id = fnv1a_32(_FMT)
    log2.module_id = fnv1a_32(_MODULE)
    assert_true(ring2.try_push(op2^), "open pushed")
    assert_true(ring2.try_push(log2^), "log pushed")

    var views = drain_to_views(ring2, d, anchor)
    assert_equal(len(views), 1, "ONLY the log record became a view")
    assert_equal(
        Int(ring2.span_record_dropped_count()),
        1,
        "the skipped span record was counted",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
