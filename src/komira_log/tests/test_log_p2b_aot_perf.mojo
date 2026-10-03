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
# toolchain the production binary uses. It prints ns/emit; the
# assert is a generous ceiling that only fails on a gross regression (so the
# number is informational + the gate is the printed value, which the report
# captures).
# =============================================================================

import komira_log as log
from komira_log import SharedEngine
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

    # The measured loop: emit a fixed-arg site, draining every CHUNK emits so the
    # ring stays well below capacity. The drain cost is EXCLUDED from the timed
    # window (it runs between timed chunks).
    comptime TOTAL = 200_000
    comptime CHUNK = 256
    var total_ns: Int64 = 0
    var emitted = 0

    while emitted < TOTAL:
        var t0 = Int64(perf_counter_ns())
        for i in range(CHUNK):
            log.info["aot emit bench {}", "komira_engine"](ArgI64(Int64(i)))
        var t1 = Int64(perf_counter_ns())
        total_ns += t1 - t0
        emitted += CHUNK
        # Drain OUTSIDE the timed window — keep the ring from filling.
        _ = eng.drain_worker(0, 1 << 16)

    var ns_per_emit = Float64(Int(total_ns)) / Float64(emitted)
    print("=== P2b AOT hot-path perf ===")
    print("emits:", emitted)
    print("total_ns:", total_ns)
    print("ns/emit:", ns_per_emit)

    # Generous ceiling — only fails on a gross regression. The REPORTED number
    # is what a reader compares (anything around 100ns+ deserves a look).
    assert_true(ns_per_emit < 5000.0)

    LogManager._test_reset()
    print("test_log_p2b_aot_perf: DONE")
