# =============================================================================
# test_log_p2b_aot_perf.mojo — AOT hot-path perf gate for the P2b emit path.
# =============================================================================
#
# THE REQUIRED P2b PERF DELIVERABLE. Measures the cost of ONE enabled
# `log.info[fmt](args)` emit through the FULL production ambient reach,
# compiled ahead of time (NOT under a JIT):
#
#   handle resolve (engine_installed + engine_ref)
#   → enabled + global-gate + per-module-gate
#   → register_site (idempotent linear-scan no-op after first)
#   → raw-counter timestamp (read_raw_ticks)
#   → comptime arg-tag + encode_into (binary, no format)
#   → TLS worker_id lookup (pthread_getspecific)
#   → ring push (try_push into the per-core SPSC ring)
#
# A JIT-warm microbench reads a few hundred ns/record. The question: is the AOT
# number in the ~10–30ns NanoLog-class band, or is that a real cost (not just
# JIT)?
# We drain periodically so the ring (bounded + DROP) never fills — we measure
# the EMIT cost, not the drop-counter path.
#
# This is a TEST target (not a bench suite) so it builds AOT with the same
# toolchain the production binary uses. It prints ns/emit as information only;
# NO TIME IS ASSERTED (a threshold on ns/emit depends on the machine and fails
# on a loaded one). What it asserts is counted exactly, and is what a per-emit
# cost regression on this path would break:
#
#   * every emit reached the ring and was drained: records drained over the
#     measured loop == emits made, and no ring dropped one. An emit that reached
#     the ring returned before the cold render block (the only place that builds
#     Strings and Lists), so the steady-state emit builds no String and boxes no
#     argument. A drop, or the synchronous fallback arm, changes the count.
#   * site registration does not repeat: the SiteDictionary has one entry for
#     the one site, and its length is the same after the measured loop as after
#     the warm-up. A registration that re-ran per emit would grow it (and
#     allocate a String each time).
#
# The toolchain has no process-wide allocation counter, so allocation is not
# counted directly; these two are the observable effects of an allocating emit.
# =============================================================================

import komira_log as log
from komira_log import SharedEngine
from komira_log.engine.log_manager import LogManager
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE
from komira_log.log_arg import ArgI64

from std.testing import assert_equal
from std.time import perf_counter_ns


def _all_filter() -> EnvFilter:
    var f = EnvFilter()
    f.global_level = LEVEL_TRACE
    return f^


def main() raises:
    var eng = SharedEngine(num_workers=1, filter=_all_filter())
    # SAFETY: `eng` owned by main for the whole measurement; install borrows its
    # address (forever-root contract). uninstall before it drops.
    LogManager._test_install_borrow(eng)
    eng.bind_worker_thread(UInt16(0))

    # Warm-up: register the site (first emit appends to the dict) + prime the
    # ring + the TLS path so we measure steady state.
    for _ in range(1000):
        log.info["aot emit bench {}", "komira_engine"](ArgI64(0))
        # Drain so the bounded ring never fills (measure emit, not drop).
        _ = eng.drain_worker(0, 1 << 16)
    var sites_after_warmup = eng.site_dict_len()
    assert_equal(sites_after_warmup, 1, "warm-up registered the one site once")

    # The measured loop: emit a fixed-arg site, draining every CHUNK emits so the
    # ring stays well below capacity. The drain cost is EXCLUDED from the timed
    # window (it runs between timed chunks).
    comptime TOTAL = 200_000
    comptime CHUNK = 256
    var total_ns: Int64 = 0
    var emitted = 0
    var drained = 0

    while emitted < TOTAL:
        var t0 = Int64(perf_counter_ns())
        for i in range(CHUNK):
            log.info["aot emit bench {}", "komira_engine"](ArgI64(Int64(i)))
        var t1 = Int64(perf_counter_ns())
        total_ns += t1 - t0
        emitted += CHUNK
        # Drain OUTSIDE the timed window — keep the ring from filling.
        drained += eng.drain_worker(0, 1 << 16)

    var ns_per_emit = Float64(Int(total_ns)) / Float64(emitted)
    print("=== P2b AOT hot-path perf ===")
    print("emits:", emitted)
    print("total_ns:", total_ns)
    print("ns/emit:", ns_per_emit)

    print("records drained:", drained)

    # THE COUNTED PROPERTIES. The ns/emit above is information only.
    assert_equal(drained, emitted, "every emit reached the ring and drained")
    assert_equal(eng.overflow_dropped_count(), Int64(0), "no ring dropped")
    assert_equal(eng.unknown_kind_dropped_count(), Int64(0), "no refused kind")
    assert_equal(
        eng.site_dict_len(),
        sites_after_warmup,
        "no site was re-registered over the measured loop",
    )

    LogManager._test_reset()
    print("test_log_p2b_aot_perf: DONE")
