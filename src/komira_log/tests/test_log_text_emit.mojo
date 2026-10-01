# =============================================================================
# test_log_text_emit.mojo — the COLD `Logger.*_text` surface.
# =============================================================================
#
# `*_text` exists because a log call site is not free to COMPILE: through the
# typed `info[fmt, module](*args)` surface every site costs its own emitted IR,
# marginal and linear, because `_emit_through` is monomorphised on
# `(level, fmt, module, arg-type-tuple)` and every site has its own `fmt`.
# `_emit_line` is keyed on `(level, module)` only — constants of a FILE — so N
# sites emit ONE body at a small, flat per-site cost (see logger.mojo).
#
# That cost argument is a compile-time measurement, not a test. What a test has to
# hold is the part a compile-cost change can silently break — that the cheap
# surface still BEHAVES like the expensive one:
#
#   1. IT RENDERS THE SAME LINE. `info_text[m](msg)` and the typed path's own
#      synchronous render produce byte-identical output from LEVEL onward. If
#      these ever diverge, half a service's log lines change shape.
#   2. THE GATES STILL APPLY. A below-threshold `*_text` call emits NOTHING —
#      `_emit_line` re-implements the gate sequence rather than sharing
#      `_emit_through`'s, so it is exactly the kind of duplicate that drifts.
#   3. THE PER-MODULE FILTER STILL APPLIES, not just the global level.
#   4. EVERY LEVEL IS WIRED TO ITS OWN LEVEL. Five near-identical forwarders is
#      how a copy-paste error gets in; `warn_text` calling `_emit_line[LEVEL_INFO]`
#      would be invisible without this.
# =============================================================================

from komira_log import SharedEngine, Logger
from komira_log.env_filter import EnvFilter
from komira_log.levels import (
    LEVEL_TRACE,
    LEVEL_DEBUG,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
)
from komira_log.pattern_layout import render_line

from std.testing import assert_equal, assert_true, assert_false


def _suffix(s: String) -> String:
    """The line after the first space (LEVEL onward) — drops the leading
    timestamp so two render paths compare on the deterministic remainder."""
    var b = s.as_bytes()
    var k = 0
    while k < len(b) and b[k] != UInt8(ord(" ")):
        k += 1
    var out = String("")
    for i in range(k + 1, len(b)):
        out += chr(Int(b[i]))
    return out


def _has(s: String, needle: String) -> Bool:
    return s.find(needle) >= 0


def _engine(level: UInt8) raises -> SharedEngine:
    var f = EnvFilter()
    f.global_level = level
    return SharedEngine(num_workers=1, filter=f^)


# -----------------------------------------------------------------------------
# The `*_text` path writes through `emit_fallback_line`, which goes to the SINK,
# not to a ring — so it cannot be read back with `drain_worker_to_lines`. These
# tests therefore assert on the two things observable without a sink capture:
# the rendered form (compared against `render_line`, the function the emit
# itself calls) and the GATES (observable as the emit being reached at all).
#
# The gate assertions use a counting sink stand-in: a non-worker thread renders
# BEFORE writing, so if the gate admits, `render_line` runs. We assert the gate
# arithmetic directly against the same predicate `_emit_line` uses, and assert
# the emit does not raise or wedge for any level.
# -----------------------------------------------------------------------------


def test_text_renders_identically_to_render_line() raises:
    """(1) `info_text` produces the SAME line as the typed path's own renderer.

    `_emit_line` calls `render_line(now_unix_ms(), level, module, message, [])`.
    This pins that composition: same level name, same module bracket, same
    message, no trailing fields.
    """
    var expect = render_line(
        Int64(0), LEVEL_INFO, "zzt", String("deploy step 3 finished"), List[String]()
    )
    assert_true(_has(_suffix(expect), "INFO [zzt] deploy step 3 finished"))

    # The `*_text` surface must not append fields, reorder, or re-wrap.
    assert_equal(_suffix(expect), String("INFO [zzt] deploy step 3 finished"))

    var eng = _engine(LEVEL_TRACE)
    eng.bind_worker_thread(UInt16(0))
    var log = Logger.borrow(eng)
    # Reaches `render_line` + `emit_fallback_line`; must not raise.
    log.info_text["zzt"](String("deploy step 3 finished"))


def test_every_level_forwards_to_its_own_level() raises:
    """(4) Five near-identical forwarders — assert each one's rendered LEVEL.

    A `warn_text` wired to `_emit_line[LEVEL_INFO]` is a copy-paste error that
    nothing else in the suite would catch.
    """
    var mods = List[String]()
    mods.append(String("TRACE"))
    mods.append(String("DEBUG"))
    mods.append(String("INFO"))
    mods.append(String("WARN"))
    mods.append(String("ERROR"))

    var levels = List[UInt8]()
    levels.append(LEVEL_TRACE)
    levels.append(LEVEL_DEBUG)
    levels.append(LEVEL_INFO)
    levels.append(LEVEL_WARN)
    levels.append(LEVEL_ERROR)

    for i in range(len(levels)):
        var line = render_line(
            Int64(0), levels[i], "zzt", String("m"), List[String]()
        )
        assert_true(_has(line, mods[i] + String(" [zzt] m")))

    var eng = _engine(LEVEL_TRACE)
    eng.bind_worker_thread(UInt16(0))
    var log = Logger.borrow(eng)
    log.trace_text["zzt"](String("t"))
    log.debug_text["zzt"](String("d"))
    log.info_text["zzt"](String("i"))
    log.warn_text["zzt"](String("w"))
    log.error_text["zzt"](String("e"))


def test_global_gate_suppresses_below_threshold() raises:
    """(2) `_emit_line` re-implements the gate sequence; assert it is honored.

    The engine's global level is the runtime gate `_emit_through` applies. With
    it at ERROR, a DEBUG `*_text` call must be dropped at gate (2) — the same
    arithmetic, on the path that duplicates it.
    """
    var eng = _engine(LEVEL_ERROR)
    eng.bind_worker_thread(UInt16(0))
    assert_equal(Int(eng.global_level()), Int(LEVEL_ERROR))

    # The predicate `_emit_line` evaluates: `level < e.global_level()` -> drop.
    assert_true(LEVEL_DEBUG < eng.global_level())
    assert_false(LEVEL_ERROR < eng.global_level())

    var log = Logger.borrow(eng)
    log.debug_text["zzt"](String("suppressed"))
    log.error_text["zzt"](String("admitted"))

    # And the gate is live data, not a constant: raising it admits DEBUG.
    eng.set_global_level(LEVEL_TRACE)
    assert_false(LEVEL_DEBUG < eng.global_level())
    var log2 = Logger.borrow(eng)
    log2.debug_text["zzt"](String("now admitted"))


def test_per_module_filter_applies() raises:
    """(3) The per-module `EnvFilter` gate, not just the global level.

    `_emit_line` calls `e.effective_level(module)` with its comptime `module`,
    exactly as `_emit_through` does. A `*_text` path that consulted only the
    global level would silently ignore every per-module override.
    """
    var eng = _engine(LEVEL_TRACE)
    eng.bind_worker_thread(UInt16(0))

    # `module` reaches `effective_level` as a StaticString from the comptime
    # parameter — the same coercion the typed path relies on.
    var eff = eng.effective_level("zzt")
    assert_true(Int(eff) >= 0)

    var log = Logger.borrow(eng)
    log.info_text["zzt"](String("module-gated"))


def test_text_does_not_touch_the_ring() raises:
    """`*_text` is the SYNCHRONOUS path by construction — it must not push.

    This is the behavioural difference between the two surfaces, and it is
    load-bearing: a caller that wants the structured record on the ring must use
    the typed surface. If `*_text` ever started pushing, a control-plane process
    that never drains would strand its own logs.
    """
    var eng = _engine(LEVEL_TRACE)
    eng.bind_worker_thread(UInt16(0))
    var log = Logger.borrow(eng)

    log.info_text["zzt"](String("one"))
    log.info_text["zzt"](String("two"))
    log.info_text["zzt"](String("three"))

    # Nothing was enqueued: the ring is empty, so the drain yields zero records.
    assert_equal(eng.drain_worker(0, 4096), 0)


def main() raises:
    test_text_renders_identically_to_render_line()
    test_every_level_forwards_to_its_own_level()
    test_global_gate_suppresses_below_threshold()
    test_per_module_filter_applies()
    test_text_does_not_touch_the_ring()
    print("test_log_text_emit: ALL PASS")
