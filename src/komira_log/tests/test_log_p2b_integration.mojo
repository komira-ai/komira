# =============================================================================
# test_log_p2b_integration.mojo — komira_log P2b facade→engine integration.
# =============================================================================
#
# P2b wires the P2a engine CORE into the facade + the ambient reach. These tests
# exercise the wired path WITHOUT spawning the full runtime (the worker-loop
# drain + the engine/SDK e2e gates cover that). They prove:
#
#   1. THE FACADE ROUTES THROUGH THE ENGINE. With a SharedEngine installed and
#      the calling thread bound as worker `wid`, `log.info[fmt](args)` lands a
#      binary record in `ring(wid)`; draining + decoding it reproduces the SAME
#      rendered text the P1 synchronous path produces (byte-identical from LEVEL
#      onward — the timestamp differs because P2 raw-tick-converts).
#   2. THE AMBIENT TLS PATH. After `bind_worker_thread(wid)`, the facade's
#      ambient `current_worker_id()` resolves to `wid` and the record routes to
#      `ring(wid)` (not the fallback). A non-worker thread (TLS unset) would
#      route to the synchronous fallback (covered by the worker_id branch).
#   3. THE GATE IS HONORED through the engine path (a below-threshold call emits
#      nothing into the ring).
#   4. STRUCTURED FIELDS round-trip through the binary encode (positional `{}`
#      args + trailing key=value `Field`).
#
# The site dictionary is built BY THE FACADE (it registers each site at emit
# time), so the drain decodes the exact fmt/module the call used — keys match by
# construction.
# =============================================================================

import komira_log as log
from komira_log import SharedEngine
from komira_log.engine.log_manager import LogManager
from komira_log.env_filter import EnvFilter
from komira_log.levels import (
    LEVEL_TRACE,
    LEVEL_INFO,
    LEVEL_WARN,
    LEVEL_ERROR,
    level_name,
)
from komira_log.log_arg import ArgI64, ArgStr, ArgF64, ArgBool, Field
from komira_log.pattern_layout import interpolate, render_line
from komira_log.engine.worker_id_tls import WORKER_ID_UNSET

from std.testing import assert_equal, assert_true, assert_false


def _suffix(s: String) -> String:
    """Return the line after the first space (LEVEL onward) — strips the
    non-deterministic leading timestamp so two render paths compare on the
    deterministic remainder."""
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


# A filter that admits everything (global level TRACE) so the gate tests are
# explicit (we set the global level by hand where it matters).
def _all_filter() -> EnvFilter:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    return f^


def _install_test_engine(num_workers: Int) raises -> SharedEngine:
    """Build + install a SharedEngine for the test process. Returns it BY VALUE
    so the caller OWNS it for the test's duration (the forever-root contract:
    the installed handle borrows its address). Caller must keep it alive and
    `LogManager._test_reset()` before it drops."""
    var eng = SharedEngine(num_workers=num_workers, filter=_all_filter())
    return eng^


def test_facade_routes_through_engine() raises:
    """log.info[fmt](args) on a bound worker thread lands a record in ring(wid);
    decoding it reproduces the P1 render (byte-identical from LEVEL onward)."""
    var eng = _install_test_engine(2)
    # SAFETY: `eng` is owned by this frame for the whole test; install borrows
    # its address (forever-root contract). uninstall before it drops.
    LogManager._test_install_borrow(eng)
    assert_true(LogManager.is_installed())

    # Bind THIS thread as worker 0 → the ambient reach routes to ring(0).
    eng.bind_worker_thread(UInt16(0))
    assert_equal(Int(eng.current_worker_id()), 0)

    # Emit through the STABLE facade — the call site is byte-identical to P1.
    log.info["query finished in {} ms", "komira_engine"](ArgI64(42))

    # The record landed in ring(0). Drain + decode it.
    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(lines), 1)

    # The P1 synchronous render of the SAME site (epoch_ms is irrelevant — we
    # compare the suffix from LEVEL onward, which both paths produce identically).
    var positionals = List[String]()
    positionals.append(String("42"))
    var fields = List[String]()
    var message = interpolate(
        String("query finished in {} ms"), positionals
    )
    var p1_line = render_line(
        Int64(0), LEVEL_INFO, "komira_engine", message, fields
    )

    assert_equal(_suffix(lines[0]), _suffix(p1_line))
    # Spot-check the rendered content directly too.
    assert_true(_has(lines[0], "INFO [komira_engine] query finished in 42 ms"))

    LogManager._test_reset()
    assert_false(LogManager.is_installed())


def test_structured_fields_round_trip() raises:
    """Positional args + a trailing key=value Field round-trip through the
    binary encode and render identically to P1."""
    var eng = _install_test_engine(1)
    LogManager._test_install_borrow(eng)
    eng.bind_worker_thread(UInt16(0))

    log.error["retry {}", "komira_agent"](
        ArgI64(3), Field("fatal", ArgBool(False))
    )

    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(lines), 1)
    assert_true(_has(lines[0], "ERROR [komira_agent] retry 3 fatal=false"))

    LogManager._test_reset()


def test_gate_suppresses_below_threshold() raises:
    """A below-global-threshold call emits NOTHING into the ring (the gate runs
    through the engine path, same as P1)."""
    var eng = _install_test_engine(1)
    LogManager._test_install_borrow(eng)
    eng.bind_worker_thread(UInt16(0))

    # Raise the global threshold to WARN — a TRACE/INFO call must be dropped
    # BEFORE the ring push.
    eng.set_global_level(LEVEL_WARN)

    log.trace["noisy trace {}", "komira_engine"](ArgI64(1))
    log.info["chatty info {}", "komira_engine"](ArgI64(2))
    var below = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(below), 0)

    # A WARN call IS admitted.
    log.warn["real warning {}", "komira_engine"](ArgI64(99))
    var admitted = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(admitted), 1)
    assert_true(_has(admitted[0], "WARN [komira_engine] real warning 99"))

    LogManager._test_reset()


def test_multi_worker_ring_isolation() raises:
    """Records routed to ring(0) and ring(1) (via re-binding TLS) stay isolated —
    the per-core SPSC invariant the worker loop relies on."""
    var eng = _install_test_engine(2)
    LogManager._test_install_borrow(eng)

    # Bind to worker 0, emit one record.
    eng.bind_worker_thread(UInt16(0))
    log.info["on worker {}", "komira_engine"](ArgI64(0))

    # Re-bind THIS thread to worker 1, emit a different record. (In production
    # each pthread binds once; here we re-bind to simulate two producers.)
    eng.bind_worker_thread(UInt16(1))
    log.info["on worker {}", "komira_engine"](ArgI64(1))

    var l0 = eng.drain_worker_to_lines(0, 64)
    var l1 = eng.drain_worker_to_lines(1, 64)
    assert_equal(len(l0), 1)
    assert_equal(len(l1), 1)
    assert_true(_has(l0[0], "on worker 0"))
    assert_true(_has(l1[0], "on worker 1"))
    # No cross-contamination.
    assert_false(_has(l0[0], "on worker 1"))
    assert_false(_has(l1[0], "on worker 0"))

    LogManager._test_reset()


def test_fallback_when_no_engine_installed() raises:
    """With NO engine installed, the facade falls back to the P1 sync path and
    does not crash (the early-init / no-runtime path). We can't assert on stderr
    here, but the call must complete without raising and `is_installed()` stays
    False."""
    # Ensure clean slate (a prior test may have left it uninstalled already).
    LogManager._test_reset()
    assert_false(LogManager.is_installed())
    # This routes to the P1 synchronous stderr fallback — must not crash.
    log.info["no engine installed {}", "komira_engine"](ArgI64(7))
    assert_false(LogManager.is_installed())


def test_long_string_spills_to_arena() raises:
    """A string arg longer than the inline 48-byte blob drives the
    ArgBlobWriter past ARG_INLINE_BYTES → the overflow tail → the ring arena
    spill path. Decoding it must reproduce the full string (the FLAG_HAS_ARG_-
    OVERFLOW path), byte-identical to the P1 render. Guards the
    direct-into-record encode's rare overflow branch."""
    var eng = _install_test_engine(1)
    LogManager._test_install_borrow(eng)
    eng.bind_worker_thread(UInt16(0))

    # A 120-char string — far beyond the 48-byte inline blob (so the encoded
    # tag + u16-len + bytes overflow and the writer spills the full blob to the
    # arena). Use a deterministic, recognizable payload.
    var big = String("")
    for _ in range(12):
        big += String("0123456789")  # 120 chars total
    assert_equal(big.byte_length(), 120)

    log.info["payload={}", "komira_engine"](ArgStr(big))

    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(lines), 1)

    # The full 120-char payload must round-trip through the arena spill.
    var positionals = List[String]()
    positionals.append(big)
    var fields = List[String]()
    var message = interpolate(String("payload={}"), positionals)
    var p1_line = render_line(
        Int64(0), LEVEL_INFO, "komira_engine", message, fields
    )
    assert_equal(_suffix(lines[0]), _suffix(p1_line))
    assert_true(_has(lines[0], big))

    LogManager._test_reset()


def test_inline_boundary_args_round_trip() raises:
    """Args whose encoded blob exactly fills (or nearly fills) the 48-byte
    inline capacity stay on the zero-alloc inline path and still decode
    correctly — guards the inline/overflow boundary of the direct encode."""
    var eng = _install_test_engine(1)
    LogManager._test_install_borrow(eng)
    eng.bind_worker_thread(UInt16(0))

    # Five i64 args: 5 tag bytes + 5*8 = 45 bytes encoded → fits inline (<=48).
    log.info["five {} {} {} {} {}", "komira_engine"](
        ArgI64(11), ArgI64(22), ArgI64(33), ArgI64(44), ArgI64(55)
    )
    var lines = eng.drain_worker_to_lines(0, 64)
    assert_equal(len(lines), 1)
    assert_true(_has(lines[0], "five 11 22 33 44 55"))

    LogManager._test_reset()


def test_explicit_flush_drains_all_rings() raises:
    """The engine's drain-to-lines twin drains every record across the budget —
    the shape the EngineContext.flush_log_engine teardown uses."""
    var eng = _install_test_engine(1)
    LogManager._test_install_borrow(eng)
    eng.bind_worker_thread(UInt16(0))

    for i in range(5):
        log.info["flush record {}", "komira_engine"](ArgI64(Int64(i)))

    var lines = eng.drain_worker_to_lines(0, 1 << 20)
    assert_equal(len(lines), 5)
    assert_true(_has(lines[0], "flush record 0"))
    assert_true(_has(lines[4], "flush record 4"))

    LogManager._test_reset()


def main() raises:
    test_facade_routes_through_engine()
    test_structured_fields_round_trip()
    test_gate_suppresses_below_threshold()
    test_multi_worker_ring_isolation()
    test_fallback_when_no_engine_installed()
    test_long_string_spills_to_arena()
    test_inline_boundary_args_round_trip()
    test_explicit_flush_drains_all_rings()
    print("test_log_p2b_integration: ALL PASS")
