# =============================================================================
# test_log_p4b_ambient_span.mojo — the AMBIENT span reach + ctx.tracer (P4b).
# =============================================================================
#
# P4b switches the PRODUCTION span consumers (the morsel executor + the no-`ctx`
# compiler path) off the obs `Tracer` onto the unified engine. The two reaches:
#
#   1. AMBIENT (`log.span_open[name](wid)` / `log.span_close(sid, wid)`) — the
#      no-`ctx` reach. Resolves the process-global engine via the same
#      `engine_handle` borrow the ambient `log.info(...)` uses. These tests prove:
#        a. With an engine installed → the span lands on the unified ring →
#           drains to OTLP (correct name / span_id / parent edge).
#        b. With NO engine installed → `span_open` returns 0, `span_close` is a
#           no-op (the harmless-silent standalone-compile contract).
#   2. TYPED (`ctx.tracer()`) — exercised by the SDK obs tests; here we prove the
#      ambient + typed reaches both land on the SAME installed engine (a span
#      opened typed-then-closed-ambient, and a nested query/segment pair shaped
#      exactly like the morsel executor's, both round-trip).
#
# Standalone: builds + installs a SharedEngine directly (the P2b test pattern).
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

import komira_log as log
from komira_log import (
    SharedEngine,
    Tracer,
)
from komira_log.engine.log_manager import LogManager
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE


# -----------------------------------------------------------------------------
# Tiny flat-OTLP-JSON field extractors (same shape as the P4a test).
# -----------------------------------------------------------------------------


def _field_int(json: String, key: String) -> Int:
    var needle = String("\"") + key + String("\":")
    var pos = json.find(needle)
    if pos < 0:
        return -1
    var b = json.as_bytes()
    var i = pos + len(needle.as_bytes())
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


def _all_filter() -> EnvFilter:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    return f^


# -----------------------------------------------------------------------------
# Test 1 — ambient span_open/span_close land on the installed engine → OTLP.
# -----------------------------------------------------------------------------


def test_ambient_span_round_trip() raises:
    var eng = SharedEngine(num_workers=2, filter=_all_filter())
    # SAFETY: `eng` is owned by this frame; install borrows its address
    # (forever-root contract). uninstall before it drops.
    LogManager._test_install_borrow(eng)
    assert_true(LogManager.is_installed())
    eng.bind_worker_thread(UInt16(0))

    # The no-`ctx` reach: open a query span, a nested segment span (exactly the
    # morsel-executor shape — fixed worker_id=0, parent derived from the stack),
    # close both.
    var query_sid = log.span_open["query.execute", "komira_engine"](
        worker_id=0
    )
    assert_true(query_sid != 0)
    var seg_sid = log.span_open["segment.execute", "komira_engine"](
        worker_id=0
    )
    assert_true(seg_sid != 0)
    log.span_close(seg_sid, worker_id=0)
    log.span_close(query_sid, worker_id=0)

    var res = eng.drain_worker_unified(0)
    assert_equal(len(res.span_lines), 2)
    assert_equal(eng.pending_span_count(), 0)

    # CLOSE order is inner-first → span_lines[0] is the segment span.
    var seg_json = res.span_lines[0]
    var query_json = res.span_lines[1]
    assert_equal(_field_str(seg_json, "name"), String("segment.execute"))
    assert_equal(_field_str(query_json, "name"), String("query.execute"))

    # The nested edge: the segment span's parent_id == the query span_id.
    assert_equal(_field_int(seg_json, "parent_id"), Int(query_sid))
    assert_equal(_field_int(query_json, "parent_id"), 0)
    assert_equal(_field_int(seg_json, "span_id"), Int(seg_sid))
    assert_equal(_field_int(query_json, "span_id"), Int(query_sid))
    # Same trace across the nested tree.
    assert_equal(
        _field_str(seg_json, "trace_id"), _field_str(query_json, "trace_id")
    )

    LogManager._test_reset()
    assert_false(LogManager.is_installed())


# -----------------------------------------------------------------------------
# Test 2 — NO engine installed → ambient span is a pure no-op (silent).
# -----------------------------------------------------------------------------


def test_ambient_span_noop_without_engine() raises:
    # No engine installed in this process at this point.
    assert_false(LogManager.is_installed())
    # span_open returns 0 (no engine to open against); span_close is a no-op.
    var sid = log.span_open["orphan.span", "komira_engine"](worker_id=0)
    assert_equal(Int(sid), 0)
    # Closing the 0 id must not crash (early-return on span_id==0).
    log.span_close(sid, worker_id=0)
    # Closing an arbitrary non-zero id with no engine must also be a no-op.
    log.span_close(UInt64(123), worker_id=0)


# -----------------------------------------------------------------------------
# Test 3 — typed ctx.tracer-shaped borrow + ambient reach the SAME engine.
# -----------------------------------------------------------------------------


def test_typed_and_ambient_same_engine() raises:
    var eng = SharedEngine(num_workers=1, filter=_all_filter())
    LogManager._test_install_borrow(eng)
    eng.bind_worker_thread(UInt16(0))

    # The typed reach (the shape `ctx.tracer()` returns): open via the typed
    # borrow, close via the ambient reach — both hit the SAME installed engine,
    # so the span completes.
    var tracer = Tracer.borrow(eng)
    var sid = tracer.start_span["typed.then.ambient", "komira_engine"](0)
    assert_true(sid != 0)
    log.span_close(sid, worker_id=0)

    var res = eng.drain_worker_unified(0)
    assert_equal(len(res.span_lines), 1)
    assert_equal(
        _field_str(res.span_lines[0], "name"), String("typed.then.ambient")
    )
    assert_equal(_field_int(res.span_lines[0], "span_id"), Int(sid))

    LogManager._test_reset()


def main() raises:
    test_ambient_span_round_trip()
    test_ambient_span_noop_without_engine()
    test_typed_and_ambient_same_engine()
    print("test_log_p4b_ambient_span: ALL PASS")
