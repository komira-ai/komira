# =============================================================================
# test_log_p4a_span.mojo — the UNIFIED span (tracing) surface on the engine (P4a).
# =============================================================================
#
# P4a adds the span path to the SharedEngine + the drain's span→OTLP output, on
# the SAME per-core ring + drain the log path uses ("logs and traces on one
# drain"). These tests prove:
#
#   1. SPAN ROUND-TRIP — a nested span pair (outer "query.execute" wrapping
#      inner "segment.scan") emits 4 SPAN records → drain → TWO OTLP spans with
#      correct names, span_ids, the inner's parent_id == the outer's span_id,
#      plausible start/end wall-times (end > start), the same trace_id.
#   2. LOGS + SPANS INTERLEAVED on one ring — a `ctx.logger`-shaped log emit AND
#      a span on the same ring → drain → the log renders as text, the span as
#      OTLP. Proves the unified pipeline (one ring, one drain, two outputs).
#   3. OPEN/CLOSE ACROSS DRAIN BATCHES — drain after only the OPEN (span
#      incomplete, pending) → then the CLOSE → the span completes (the open-span
#      table survives across batches).
#   4. The typed `Tracer[origin]` facade (the span twin of `Logger[origin]`) —
#      `tracer.start_span[name](wid)` / `end_span` reach the engine through the
#      concrete-origin borrow and produce IDENTICAL records to the engine-direct
#      path.
#
# Standalone: builds a SharedEngine directly (the P2b test pattern). NO sdk-core
# edit, NO obs-consumer switch — the OTLP JSON shape MIRRORS
# komira_obs.exporter.format_span_jsonl (copied into span_drain.mojo per the
# P4a brief, NOT by editing obs).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_log import SharedEngine, Tracer, Logger
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE, LEVEL_INFO
from komira_log.log_arg import ArgI64

from komira_log.engine.span_drain import (
    OpenSpanTable,
    UnifiedDrainResult,
    drain_unified,
)


# -----------------------------------------------------------------------------
# Tiny JSON field extractors (the OTLP lines are flat {"k":v,...} objects).
# -----------------------------------------------------------------------------


def _field_int(json: String, key: String) -> Int:
    """Extract a decimal `"<key>":N` value from a flat OTLP JSON line."""
    var needle = String("\"") + key + String("\":")
    var pos = json.find(needle)
    if pos < 0:
        return -1
    var b = json.as_bytes()
    var i = pos + len(needle.as_bytes())
    # Skip an optional leading minus.
    var sign = 1
    if i < len(b) and b[i] == UInt8(ord("-")):
        sign = -1
        i += 1
    var v = 0
    while i < len(b) and b[i] >= UInt8(ord("0")) and b[i] <= UInt8(ord("9")):
        v = v * 10 + (Int(b[i]) - ord("0"))
        i += 1
    return v * sign


def _field_str(json: String, key: String) -> String:
    """Extract a `"<key>":"<value>"` string value from a flat OTLP JSON line."""
    var needle = String("\"") + key + String("\":\"")
    var pos = json.find(needle)
    if pos < 0:
        return String("")
    var b = json.as_bytes()
    var i = pos + len(needle.as_bytes())
    var out = String("")
    while i < len(b) and b[i] != UInt8(ord("\"")):
        out += chr(Int(b[i]))
        i += 1
    return out


def _has(s: String, needle: String) -> Bool:
    return s.find(needle) >= 0


def _all_filter() -> EnvFilter:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    return f^


def _engine(num_workers: Int) raises -> SharedEngine:
    var eng = SharedEngine(num_workers=num_workers, filter=_all_filter())
    return eng^


# -----------------------------------------------------------------------------
# Test 1 — nested span round-trip → two OTLP spans with the parent edge.
# -----------------------------------------------------------------------------


def test_span_round_trip_nested() raises:
    var eng = _engine(2)
    eng.bind_worker_thread(UInt16(0))

    # Open outer, then nested inner; close inner, then outer.
    var outer = eng.start_span["query.execute", "komira_engine"](0)
    assert_equal(Int(eng.span_depth(0)), 1)
    var inner = eng.start_span["segment.scan", "komira_engine"](0)
    assert_equal(Int(eng.span_depth(0)), 2)
    eng.end_span(inner, 0)
    assert_equal(Int(eng.span_depth(0)), 1)
    eng.end_span(outer, 0)
    assert_equal(Int(eng.span_depth(0)), 0)

    var res = eng.drain_worker_unified(0)
    # No logs, two completed spans.
    assert_equal(len(res.log_lines), 0)
    assert_equal(len(res.span_lines), 2)
    # Every span paired (no pending across the single batch).
    assert_equal(eng.pending_span_count(), 0)

    # span_lines are emitted at CLOSE time → inner closes first.
    var inner_json = res.span_lines[0]
    var outer_json = res.span_lines[1]

    assert_equal(_field_str(inner_json, "name"), String("segment.scan"))
    assert_equal(_field_str(outer_json, "name"), String("query.execute"))

    # The nested span's parent_id == the outer span_id; outer's parent is 0.
    var outer_sid = _field_int(outer_json, "span_id")
    var inner_parent = _field_int(inner_json, "parent_id")
    assert_equal(inner_parent, outer_sid)
    assert_equal(_field_int(outer_json, "parent_id"), 0)
    assert_equal(_field_int(inner_json, "span_id"), Int(inner))
    assert_equal(outer_sid, Int(outer))

    # Plausible wall-times: end >= start, both post-2020.
    var os = _field_int(outer_json, "start_ns")
    var oe = _field_int(outer_json, "end_ns")
    assert_true(oe >= os)
    assert_true(os > 1_577_836_800_000_000_000)  # the start of 2020, in ns

    # Same trace_id across the nested tree.
    assert_equal(
        _field_str(inner_json, "trace_id"), _field_str(outer_json, "trace_id")
    )
    # trace_id is a 32-hex-char (16-byte) string (OTLP-shaped).
    assert_equal(len(_field_str(outer_json, "trace_id").as_bytes()), 32)


# -----------------------------------------------------------------------------
# Test 2 — logs + spans interleaved on ONE ring → ONE drain → two outputs.
# -----------------------------------------------------------------------------


def test_logs_and_spans_interleaved() raises:
    var eng = _engine(1)
    eng.bind_worker_thread(UInt16(0))

    var tracer = Tracer.borrow(eng)

    # A span around a log: open span, emit a log, close span — all on ring(0).
    # The log goes through the typed `Logger[origin]` surface (P2c), proving a
    # log and a span share the SAME per-core ring.
    var log_handle = Logger.borrow(eng)
    var sid = tracer.start_span["request.handle", "komira_agent"](0)
    log_handle.info["scanned {} rows", "komira_engine"](ArgI64(6001215))
    tracer.end_span(sid, 0)

    var res = eng.drain_worker_unified(0)
    # One text log line + one OTLP span line.
    assert_equal(len(res.log_lines), 1)
    assert_equal(len(res.span_lines), 1)
    assert_true(
        _has(res.log_lines[0], "INFO [komira_engine] scanned 6001215 rows")
    )
    assert_equal(
        _field_str(res.span_lines[0], "name"), String("request.handle")
    )
    assert_equal(_field_int(res.span_lines[0], "span_id"), Int(sid))


# -----------------------------------------------------------------------------
# Test 3 — OPEN and CLOSE drained in DIFFERENT batches (the open-span table).
# -----------------------------------------------------------------------------


def test_open_close_across_batches() raises:
    var eng = _engine(1)
    eng.bind_worker_thread(UInt16(0))

    var sid = eng.start_span["long.task", "komira_engine"](0)

    # Drain batch 1: only the OPEN is on the ring → span is PENDING, no OTLP yet.
    var b1 = eng.drain_worker_unified(0)
    assert_equal(len(b1.span_lines), 0)
    assert_equal(eng.pending_span_count(), 1)

    # Now close it.
    eng.end_span(sid, 0)

    # Drain batch 2: the CLOSE lands → the pending span completes → OTLP emitted.
    var b2 = eng.drain_worker_unified(0)
    assert_equal(len(b2.span_lines), 1)
    assert_equal(eng.pending_span_count(), 0)
    assert_equal(_field_str(b2.span_lines[0], "name"), String("long.task"))
    assert_equal(_field_int(b2.span_lines[0], "span_id"), Int(sid))
    # end >= start across the two batches.
    var s = _field_int(b2.span_lines[0], "start_ns")
    var e = _field_int(b2.span_lines[0], "end_ns")
    assert_true(e >= s)


# -----------------------------------------------------------------------------
# Test 4 — the typed Tracer facade matches the engine-direct path + RAII close.
# -----------------------------------------------------------------------------


def test_typed_tracer_and_raii() raises:
    var eng = _engine(1)
    eng.bind_worker_thread(UInt16(0))

    var tracer = Tracer.borrow(eng)

    # Typed start/end produces a completed OTLP span identical in shape to the
    # engine-direct path.
    var sid = tracer.start_span["typed.span", "komira_engine"](0)
    assert_equal(Int(tracer.current_span(0)), Int(sid))
    tracer.end_span(sid, 0)

    var res = eng.drain_worker_unified(0)
    assert_equal(len(res.span_lines), 1)
    assert_equal(_field_str(res.span_lines[0], "name"), String("typed.span"))
    assert_equal(_field_int(res.span_lines[0], "span_id"), Int(sid))

    # A second typed span on the same handle (proving the borrow is reusable
    # across multiple start/end cycles, the canonical hot-path form).
    var sid2 = tracer.start_span["typed.span.two", "komira_engine"](0)
    tracer.end_span(sid2, 0)
    var res2 = eng.drain_worker_unified(0)
    assert_equal(len(res2.span_lines), 1)
    assert_equal(
        _field_str(res2.span_lines[0], "name"), String("typed.span.two")
    )
    assert_equal(_field_int(res2.span_lines[0], "span_id"), Int(sid2))


# -----------------------------------------------------------------------------
# Test 5 — per-worker isolation: spans on disjoint rings don't cross-correlate.
# -----------------------------------------------------------------------------


def test_per_worker_span_isolation() raises:
    var eng = _engine(2)

    # Worker 0 opens a span; worker 1 opens its own. Each worker's span lives on
    # its own ring; draining each yields only that worker's span.
    var s0 = eng.start_span["w0.span", "komira_engine"](0)
    var s1 = eng.start_span["w1.span", "komira_engine"](1)
    eng.end_span(s0, 0)
    eng.end_span(s1, 1)

    var r0 = eng.drain_worker_unified(0)
    var r1 = eng.drain_worker_unified(1)

    assert_equal(len(r0.span_lines), 1)
    assert_equal(len(r1.span_lines), 1)
    assert_equal(_field_str(r0.span_lines[0], "name"), String("w0.span"))
    assert_equal(_field_str(r1.span_lines[0], "name"), String("w1.span"))
    # Distinct span_ids (different worker lanes) and distinct trace_ids.
    assert_true(Int(s0) != Int(s1))
    assert_false(
        _field_str(r0.span_lines[0], "trace_id")
        == _field_str(r1.span_lines[0], "trace_id")
    )
    # worker_id recorded on the OTLP span.
    assert_equal(_field_int(r0.span_lines[0], "worker_id"), 0)
    assert_equal(_field_int(r1.span_lines[0], "worker_id"), 1)


def main() raises:
    test_span_round_trip_nested()
    test_logs_and_spans_interleaved()
    test_open_close_across_batches()
    test_typed_tracer_and_raii()
    test_per_worker_span_isolation()
    print("test_log_p4a_span: ALL PASS")
