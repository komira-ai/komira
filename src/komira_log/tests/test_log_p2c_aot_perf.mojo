# =============================================================================
# test_log_p2c_aot_perf.mojo — AOT A/B: typed `ctx.logger.info` vs ambient.
# =============================================================================
#
# ⚠⚠ READ "THE ASSERTIONS" IN `main()` FIRST. The comparison this test was
# built around (`typed < ambient`) is REPORT-ONLY: on real hardware both arms
# land in the same range and the two populations overlap, so a verdict on it is
# a coin flip. The hypothesis below is kept because it is what the measurement
# is FOR — it states what a working concrete-origin dispatch would show.
#
# THE P2c PERF COMPARISON. Measures, compiled ahead of time (not under a JIT),
# one enabled emit through BOTH reaches on the SAME engine / site / args / drain
# cadence:
#
#   (A) THE TYPED PATH — `Logger.borrow(eng).info[fmt](args)`. This is exactly
#       what `ctx.logger.info` lowers to: a `Logger[origin]` carrying a CONCRETE-
#       origin `Pointer[SharedEngine, origin]` borrow, through which the
#       gate/encode/push dispatch INLINES.
#
#   (B) THE AMBIENT PATH — the bare module-level `log.info[fmt](args)`. Reaches
#       the engine through the process-global holder → an
#       `UnsafePointer[SharedEngine]` with an UNTRACKED origin. The compiler
#       cannot prove non-aliasing across it, so the dispatch need not inline.
#
# Both paths emit a fixed-arg site, draining every CHUNK emits (drain EXCLUDED
# from the timed window) so the bounded DROP ring never fills — we measure the
# EMIT cost, not the drop-counter path.
#
# THE DECOMPOSITION the report wants: (ambient - typed) ≈ the untracked-origin
# dispatch penalty. A large positive gap would say the concrete origin survived
# to the dispatch and the holder's cost is gone on the typed path.
#
# Why a bare `SharedEngine` + `Logger.borrow` instead of a full EngineContext:
# `Logger.borrow(eng)` produces the IDENTICAL concrete-origin Logger that
# `ctx.logger()` returns (both call `Logger.borrow` on a `ref [origin]
# SharedEngine` field). A full EngineContext spawns pthreads + a runtime, which
# would add noise to the per-emit measurement; the borrow shape is the thing
# under test, and it is the same primitive both wrap.
# =============================================================================

import komira_log as log
from komira_log import SharedEngine, Logger
from komira_log.engine.log_manager import LogManager
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE
from komira_log.log_arg import ArgI64

from std.testing import assert_true
from std.time import perf_counter_ns


def _all_filter() -> EnvFilter:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    return f^


def _measure_typed(
    mut eng: SharedEngine, total: Int, chunk: Int, mut drained: Int
) -> Float64:
    """Time `total` emits through the TYPED concrete-origin Logger.borrow path
    (== what `ctx.logger.info` lowers to). Drains every `chunk` OUTSIDE the
    timed window.

    `drained` accumulates the records the engine actually handed back. It is an
    OUT PARAMETER rather than a discarded `_` because it is the only thing here
    that can distinguish "the emit ran" from "the emit was filtered, folded or
    optimised away" — and a timing of a loop that emitted nothing is a number,
    not a measurement. See main()'s "THE ASSERTIONS"."""
    var total_ns: Int64 = 0
    var emitted = 0
    while emitted < total:
        var t0 = Int64(perf_counter_ns())
        for i in range(chunk):
            # The typed reach: a fresh concrete-origin borrow per emit (a pointer
            # copy — the same the accessor returns), then the inlined dispatch.
            var logger = Logger.borrow(eng)
            logger.info["p2c typed emit {}", "komira_engine"](ArgI64(Int64(i)))
        var t1 = Int64(perf_counter_ns())
        total_ns += t1 - t0
        emitted += chunk
        drained += eng.drain_worker(0, 1 << 16)
    return Float64(Int(total_ns)) / Float64(emitted)


def _measure_ambient(
    mut eng: SharedEngine, total: Int, chunk: Int, mut drained: Int
) -> Float64:
    """Time `total` emits through the AMBIENT wildcard-handle path (bare
    module-level `log.info`). Drains every `chunk` OUTSIDE the timed window.

    `drained` accumulates as in `_measure_typed` — same reason."""
    var total_ns: Int64 = 0
    var emitted = 0
    while emitted < total:
        var t0 = Int64(perf_counter_ns())
        for i in range(chunk):
            log.info["p2c ambient emit {}", "komira_engine"](ArgI64(Int64(i)))
        var t1 = Int64(perf_counter_ns())
        total_ns += t1 - t0
        emitted += chunk
        drained += eng.drain_worker(0, 1 << 16)
    return Float64(Int(total_ns)) / Float64(emitted)


def main() raises:
    var eng = SharedEngine(num_workers=1, filter=_all_filter())
    # SAFETY: `eng` owned by main for the whole measurement; install borrows its
    # address (forever-root contract) so the AMBIENT path resolves it. uninstall
    # before it drops. The TYPED path reaches `eng` directly via Logger.borrow.
    LogManager._test_install_borrow(eng)
    eng.bind_worker_thread(UInt16(0))

    # Warm-up: register both sites + prime the ring + TLS so we measure steady
    # state (first emit per site appends to the dict).
    for i in range(1000):
        var logger = Logger.borrow(eng)
        logger.info["p2c typed emit {}", "komira_engine"](ArgI64(Int64(i)))
        log.info["p2c ambient emit {}", "komira_engine"](ArgI64(Int64(i)))
        _ = eng.drain_worker(0, 1 << 16)

    comptime TOTAL = 200_000
    comptime CHUNK = 256

    # Interleave the two measurements (run each twice, alternating) to even out
    # any thermal / scheduler drift across the run.
    var typed_drained = 0
    var ambient_drained = 0
    var typed_a = _measure_typed(eng, TOTAL, CHUNK, typed_drained)
    var ambient_a = _measure_ambient(eng, TOTAL, CHUNK, ambient_drained)
    var typed_b = _measure_typed(eng, TOTAL, CHUNK, typed_drained)
    var ambient_b = _measure_ambient(eng, TOTAL, CHUNK, ambient_drained)

    var typed = (typed_a + typed_b) / 2.0
    var ambient = (ambient_a + ambient_b) / 2.0

    print("=== P2c AOT typed-vs-ambient ===")
    print("typed   ns/emit (ctx.logger.info path):", typed)
    print("ambient ns/emit (bare log.info path)  :", ambient)
    print("wildcard-dispatch penalty (ambient - typed):", ambient - typed)
    print("speedup (ambient / typed):", ambient / typed)
    print("records drained — typed:", typed_drained, " ambient:", ambient_drained)

    # =========================================================================
    # THE ASSERTIONS — ⛔ NOT `typed < ambient`. READ BEFORE RE-ADDING IT.
    #
    # `assert_true(typed < ambient)` is a COIN FLIP: across repeated runs the
    # two arms' ns/emit populations OVERLAP COMPLETELY and the mean separation
    # is a few percent of an emit — smaller than one standard deviation of
    # either arm.
    #
    # ⚠ A MARGIN IS NOT AVAILABLE, WHICH IS THE POINT. The obvious repair —
    # "require typed to be at least N% faster" — makes it fail MORE OFTEN, not
    # less. There is no threshold that both passes and means anything. And a
    # known-failing hold cannot carry it either: a hold asserts the test FAILS,
    # and a test that fails some of the time breaks the hold the rest of the
    # time.
    #
    # ⚠ THE HYPOTHESIS IN THE HEADER IS NOT WHAT THE NUMBERS SHOW, and that is a
    # finding, not a reason to hide the test. Whatever dominates an emit, it is
    # not the untracked-origin dispatch. Note also that an unoptimised build
    # need not enable the inlining the hypothesis rests on.
    #
    # WHAT REPLACES IT: an assertion that is DETERMINISTIC and that falsifies
    # the thing which would silently void the numbers above — that the emits
    # happened at all. A filter change, a folded site or a dead-code-eliminated
    # loop makes both arms ~0ns, and `typed < ambient` stays a 50/50 coin flip
    # over noise while measuring NOTHING. A drained count cannot.
    # =========================================================================
    # ⚠ `>= 2 * TOTAL`, NOT `> 0`. Each measure fn is called TWICE and emits
    # TOTAL each time, so this asserts EVERY emit was captured, not merely that
    # some were — `> 0` is satisfied by a path that drops 99.99% of its records,
    # which would invalidate the ns/emit above while reading green. The count is
    # exactly 2*TOTAL plus what the warm-up swept, with zero drops and no
    # run-to-run variation: a DETERMINISTIC arm, which is the property the
    # comparison lacks. If it ever fails, the log engine is dropping records — a
    # real defect, and one that silently voids every number this test prints.
    assert_true(typed_drained >= 2 * TOTAL)
    assert_true(ambient_drained >= 2 * TOTAL)
    # Generous absolute ceilings — only fail on gross regression (an emit costs
    # on the order of 100-200ns, so this is a wide margin). Both arms, not just
    # typed, so a regression confined to the ambient path is caught too.
    assert_true(typed < 5000.0)
    assert_true(ambient < 5000.0)

    LogManager._test_reset()
    print("test_log_p2c_aot_perf: DONE")
