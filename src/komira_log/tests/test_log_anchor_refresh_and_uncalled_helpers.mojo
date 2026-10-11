# =============================================================================
# test_log_anchor_refresh_and_uncalled_helpers.mojo — five functions of the
# library that no other suite calls, so no test binary held a line of them:
#
#   * `SharedEngine.maybe_refresh_anchor`: re-anchors when the last anchor is
#     at least `_ANCHOR_REFRESH_MS` old, and leaves anchor and timestamp alone
#     when it is not;
#   * `SharedEngine.refresh_anchor`: replaces both, unconditionally;
#   * `SiteDictionary._register_site`: idempotent on the site id, whichever
#     entry the id already holds;
#   * `SpanContextSlot.__init__`: every field zero, the same value as the
#     zero-filled slot the engine allocates;
#   * `StructuredLogLine.emit`: `render()` plus one newline on fd 1 (fd 1 is
#     pointed at a scratch file for the call and restored before any check).
#
# The anchor tests plant a sentinel anchor first, so "replaced" and "left
# alone" are told apart by value, not by a clock read that could match by
# chance.
# =============================================================================

from std.ffi import external_call
from std.io import FileHandle
from std.os import remove
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_clock import now_unix_ms
from komira_runtime_paths import test_tmpdir
from komira_trace.tracer import MAX_SPAN_DEPTH

from komira_log import SharedEngine
from komira_log.env_filter import EnvFilter
from komira_log.structured_log import StructuredLogLine
from komira_log.engine.calibration import CalibrationAnchor, capture_anchor
from komira_log.engine.site_dictionary import SiteDictionary
from komira_log.engine.span_context import SpanContextSlot


comptime _O_WRONLY: Int32 = 1
# A value `capture_anchor` cannot produce: tick_hz 3 is neither the Linux
# 1e9 nor a real counter rate.
comptime _SENTINEL_TICK0: UInt64 = UInt64(11)
comptime _SENTINEL_WALL0: UInt64 = UInt64(22)
comptime _SENTINEL_HZ: UInt64 = UInt64(3)


@always_inline
def _at_fdcwd() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(-2)
    else:
        return Int32(-100)


@always_inline
def _o_creat() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0x0200)
    else:
        return Int32(0x0040)


@always_inline
def _o_trunc() -> Int32:
    comptime if CompilationTarget.is_macos():
        return Int32(0x0400)
    else:
        return Int32(0x0200)


def _engine() raises -> SharedEngine:
    var f = EnvFilter()
    return SharedEngine(num_workers=1, filter=f^)


def _plant_sentinel(mut eng: SharedEngine, last_ms: Int64):
    eng._anchor[] = CalibrationAnchor(
        _SENTINEL_TICK0, _SENTINEL_WALL0, _SENTINEL_HZ
    )
    eng._last_anchor_ms = last_ms


def _assert_is_sentinel(eng: SharedEngine, what: String) raises:
    var a = eng.anchor()
    assert_equal(a.tick0, _SENTINEL_TICK0, what + ": tick0")
    assert_equal(a.wall0_ns, _SENTINEL_WALL0, what + ": wall0_ns")
    assert_equal(a.tick_hz, _SENTINEL_HZ, what + ": tick_hz")


def _assert_fresh(
    eng: SharedEngine, before_ms: Int64, after_ms: Int64, what: String
) raises:
    """The anchor is a fresh capture taken between the two clock reads."""
    var a = eng.anchor()
    var real_hz = capture_anchor().tick_hz
    assert_equal(a.tick_hz, real_hz, what + ": tick_hz is the real rate")
    assert_true(
        a.wall0_ns >= UInt64(before_ms) * UInt64(1_000_000),
        what + ": wall0_ns not before the call",
    )
    assert_true(
        a.wall0_ns <= UInt64(after_ms + 1) * UInt64(1_000_000),
        what + ": wall0_ns not after the call",
    )
    assert_true(
        eng.last_anchor_ms() >= before_ms and eng.last_anchor_ms() <= after_ms,
        what + ": last_anchor_ms is the call's own clock read",
    )


def test_maybe_refresh_anchor_reanchors_once_the_interval_has_passed() raises:
    var eng = _engine()

    # Exactly the interval (1000 ms) ago, or more by the time it reads the
    # clock: due.
    var before = now_unix_ms()
    _plant_sentinel(eng, before - Int64(1000))
    assert_true(eng.maybe_refresh_anchor(), "1000 ms old: re-anchors")
    var after = now_unix_ms()
    _assert_fresh(eng, before, after, "1000 ms old")

    # Long ago (the epoch): due.
    before = now_unix_ms()
    _plant_sentinel(eng, Int64(0))
    assert_true(eng.maybe_refresh_anchor(), "epoch-old: re-anchors")
    after = now_unix_ms()
    _assert_fresh(eng, before, after, "epoch-old")


def test_maybe_refresh_anchor_leaves_a_recent_anchor_alone() raises:
    var eng = _engine()

    # Half the interval ago: not due (only a 500 ms stall between the two
    # clock reads could make it due).
    var half = now_unix_ms() - Int64(500)
    _plant_sentinel(eng, half)
    assert_false(eng.maybe_refresh_anchor(), "500 ms old: no re-anchor")
    _assert_is_sentinel(eng, "500 ms old")
    assert_equal(eng.last_anchor_ms(), half, "500 ms old: timestamp kept")

    # Stamped ahead of the clock (a wall clock stepped back): the elapsed
    # time is negative, not due.
    var ahead = now_unix_ms() + Int64(60_000)
    _plant_sentinel(eng, ahead)
    assert_false(eng.maybe_refresh_anchor(), "stamped ahead: no re-anchor")
    _assert_is_sentinel(eng, "stamped ahead")
    assert_equal(eng.last_anchor_ms(), ahead, "stamped ahead: timestamp kept")


def test_refresh_anchor_replaces_anchor_and_timestamp_unconditionally() raises:
    var eng = _engine()

    # Stamped ahead of the clock, where `maybe_refresh_anchor` declines:
    # `refresh_anchor` re-anchors anyway.
    _plant_sentinel(eng, now_unix_ms() + Int64(60_000))
    var before = now_unix_ms()
    eng.refresh_anchor()
    var after = now_unix_ms()
    _assert_fresh(eng, before, after, "refresh_anchor")


def test_register_site_is_idempotent_on_the_site_id() raises:
    var d = SiteDictionary()
    d._register_site(UInt32(7), String("first {}"))
    d._register_site(UInt32(9), String("second {}"))
    d._register_site(UInt32(12), String("third {}"))
    assert_equal(len(d.sites), 3, "three ids, three entries")

    # The id at the first, middle and last entry: none is added again, and
    # the fmt registered first is kept.
    d._register_site(UInt32(7), String("other 7"))
    d._register_site(UInt32(9), String("other 9"))
    d._register_site(UInt32(12), String("other 12"))
    assert_equal(len(d.sites), 3, "a known id adds no entry")
    assert_equal(d.lookup_fmt(UInt32(7)).value(), String("first {}"))
    assert_equal(d.lookup_fmt(UInt32(9)).value(), String("second {}"))
    assert_equal(d.lookup_fmt(UInt32(12)).value(), String("third {}"))

    # A new id after the repeats is still added, at the end.
    d._register_site(UInt32(8), String("fourth {}"))
    assert_equal(len(d.sites), 4, "a new id adds one entry")
    assert_equal(d.sites[3].site_id, UInt32(8), "appended last")
    assert_equal(d.lookup_fmt(UInt32(8)).value(), String("fourth {}"))
    # It registers sites only.
    assert_equal(len(d.modules), 0, "no module entry")


def test_span_context_slot_default_is_the_zero_slot() raises:
    var s = SpanContextSlot()
    assert_equal(s.depth, UInt32(0), "depth")
    for i in range(MAX_SPAN_DEPTH):
        assert_equal(s.stack[i], UInt64(0), "stack[" + String(i) + "]")
    assert_equal(s.span_counter, UInt64(0), "span_counter")
    assert_equal(s.trace_lo, UInt64(0), "trace_lo")
    assert_equal(s.trace_hi, UInt64(0), "trace_hi")
    assert_equal(s.trace_counter, UInt64(0), "trace_counter")
    for i in range(32):
        assert_equal(s._pad[i], UInt8(0), "_pad[" + String(i) + "]")
    assert_equal(s.current_parent(), UInt64(0), "no span open: no parent")


def test_structured_log_line_emit_writes_render_and_one_newline_to_fd1() raises:
    var line = StructuredLogLine("WARNING", String('say "hi"'))
    line.with_str("route", String("/v1/items"))
    line.with_int("status", 503)
    var expected = line.render() + String("\n")
    assert_true(
        expected.startswith(String('{"severity":"WARNING","message":"say ')),
        "the rendered line is the JSON object",
    )

    var path = test_tmpdir() + String("/komira_log_emit_fd1.txt")
    var p = path
    # SAFETY: the NUL-terminated view is owned by `p`, held alive across the
    # syscall; the kernel copies the path and the pointer does not escape.
    var fd = external_call["komira_openat_creat", Int32](
        _at_fdcwd(),
        p.as_c_string_slice().unsafe_ptr(),
        _O_WRONLY | _o_creat() | _o_trunc(),
        Int32(0o644),
    )
    assert_true(Int(fd) >= 0, "opened the capture file")
    var saved = external_call["dup", Int32](Int32(1))
    _ = external_call["dup2", Int32](fd, Int32(1))
    line.emit()
    _ = external_call["dup2", Int32](saved, Int32(1))
    _ = external_call["close", Int32](saved)
    _ = external_call["close", Int32](fd)

    var f = FileHandle(path, "r")
    var got = String(f.read())
    f.close()
    try:
        remove(path)
    except:
        pass
    assert_equal(got, expected, "fd 1 holds render() and one newline")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
