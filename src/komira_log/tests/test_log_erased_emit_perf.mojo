# =============================================================================
# test_log_erased_emit_perf.mojo — what the ERASURE COSTS AT RUNTIME.
# =============================================================================
#
# `emit_erased` buys compiler peak by moving `fmt` and the arg types from
# compile time to run time. That is a TRADE, and a lane that reports only the
# compile-time saving is selling half a result. This measures the other half.
#
# WHAT MOVED, and therefore what this is looking for:
#   * the tag table becomes a runtime branch per arg instead of a `comptime for`
#     unroll,
#   * `site_id` becomes an FNV-1a over the fmt bytes instead of a literal,
#   * the body is an ordinary CALL instead of an inline expansion.
#
# THREE PAIRS, INTERLEAVED — never one arm then the other. A machine that warms
# or throttles mid-run moves the second arm relative to the first, and the whole
# claim here is a RATIO between two arms:
#
#   1. ENABLED   the admitted emit — gates pass, record encoded, ring pushed.
#   2. SUPPRESSED the gated-off emit. ⚠ THIS IS THE PAIR THAT COULD SURPRISE:
#      both paths construct their args at the CALL SITE, before any gate, but
#      the specialised body is inlined so the compiler can see the gate reject
#      and may delete the construction; the erased body is behind a call and it
#      cannot. If erasure has a runtime tax anywhere, it is here.
#   3. ZERO-ARG  the no-argument site, where the erased path's variadic is
#      empty and the specialised path's pack is empty — the floor of both.
#
# The reported statistic is the MEDIAN of R rounds per arm, with min/max shown,
# because a single round on a shared machine measures the neighbours.
#
# The assertions are deliberately loose ceilings: this file's JOB is to print
# comparable numbers, and a tight threshold on a shared runner would fail for
# reasons that have nothing to do with the logger.
# =============================================================================

from komira_log import SharedEngine, Logger
from komira_log.logger_erased import emit_erased
from komira_log.log_value import LogValue as LV
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE, LEVEL_DEBUG, LEVEL_INFO, LEVEL_WARN
from komira_log.log_arg import ArgI64

from std.testing import assert_true
from std.time import perf_counter_ns


comptime CHUNK = 256
comptime ROUNDS = 7
comptime PER_ROUND = 102_400  # 400 chunks


def _filter_at(level: UInt8) -> EnvFilter:
    var f = EnvFilter()
    f.global_level = level
    return f^


# -----------------------------------------------------------------------------
# The four timed inner loops. Each takes `mut eng` and constructs whatever handle
# it needs INSIDE, so the borrow ends at return and the caller can drain — a
# `Logger` borrow held across a `drain_worker` is an aliasing error, which is the
# reason these are separate functions rather than one loop with a flag.
# -----------------------------------------------------------------------------


def _chunk_spec(mut eng: SharedEngine, chunk: Int) -> Int64:
    var log = Logger.borrow(eng)
    var t0 = Int64(perf_counter_ns())
    for i in range(chunk):
        log.info["erased perf bench {}", "erase_perf"](ArgI64(Int64(i)))
    return Int64(perf_counter_ns()) - t0


def _chunk_erased(mut eng: SharedEngine, chunk: Int) -> Int64:
    var t0 = Int64(perf_counter_ns())
    for i in range(chunk):
        emit_erased[LEVEL_INFO, "erase_perf"](
            eng, "erased perf bench {}", LV.i64(Int64(i))
        )
    return Int64(perf_counter_ns()) - t0


def _chunk_spec_zero(mut eng: SharedEngine, chunk: Int) -> Int64:
    var log = Logger.borrow(eng)
    var t0 = Int64(perf_counter_ns())
    for _ in range(chunk):
        log.info["erased perf zero-arg", "erase_perf"]()
    return Int64(perf_counter_ns()) - t0


def _chunk_erased_zero(mut eng: SharedEngine, chunk: Int) -> Int64:
    var t0 = Int64(perf_counter_ns())
    for _ in range(chunk):
        emit_erased[LEVEL_INFO, "erase_perf"](eng, "erased perf zero-arg")
    return Int64(perf_counter_ns()) - t0


# The SUPPRESSED pair. `LEVEL_DEBUG` against a `LEVEL_WARN` engine, so the
# global gate rejects every call and nothing reaches the ring.


def _chunk_spec_off(mut eng: SharedEngine, chunk: Int) -> Int64:
    var log = Logger.borrow(eng)
    var t0 = Int64(perf_counter_ns())
    for i in range(chunk):
        log.debug["erased perf suppressed {}", "erase_perf"](ArgI64(Int64(i)))
    return Int64(perf_counter_ns()) - t0


def _chunk_erased_off(mut eng: SharedEngine, chunk: Int) -> Int64:
    var t0 = Int64(perf_counter_ns())
    for i in range(chunk):
        emit_erased[LEVEL_DEBUG, "erase_perf"](
            eng, "erased perf suppressed {}", LV.i64(Int64(i))
        )
    return Int64(perf_counter_ns()) - t0


# -----------------------------------------------------------------------------
# Reporting.
# -----------------------------------------------------------------------------


def _median(var v: List[Float64]) -> Float64:
    for i in range(len(v)):
        for j in range(i + 1, len(v)):
            if v[j] < v[i]:
                var t = v[i]
                v[i] = v[j]
                v[j] = t
    return v[len(v) // 2]


def _report(name: String, var v: List[Float64]) -> Float64:
    var lo = v[0]
    var hi = v[0]
    for i in range(len(v)):
        if v[i] < lo:
            lo = v[i]
        if v[i] > hi:
            hi = v[i]
    var med = _median(v^)
    print(
        name,
        "median",
        med,
        "ns/emit   min",
        lo,
        "  max",
        hi,
        "  n",
        ROUNDS,
    )
    return med


def main() raises:
    # ---------------------------------------------------------------------
    # PAIR 1 + 3 — the ENABLED arms, on a TRACE engine so nothing is gated.
    # ---------------------------------------------------------------------
    var eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_TRACE))
    eng.bind_worker_thread(UInt16(0))

    # Warm-up: register both sites (the first emit per site appends to the
    # dictionary), prime the ring and the TLS lookup, so the timed rounds are
    # steady state and the one-off registration is not in them.
    for _ in range(8):
        _ = _chunk_spec(eng, CHUNK)
        _ = eng.drain_worker(0, 1 << 16)
        _ = _chunk_erased(eng, CHUNK)
        _ = eng.drain_worker(0, 1 << 16)
        _ = _chunk_spec_zero(eng, CHUNK)
        _ = eng.drain_worker(0, 1 << 16)
        _ = _chunk_erased_zero(eng, CHUNK)
        _ = eng.drain_worker(0, 1 << 16)

    var spec = List[Float64]()
    var erased = List[Float64]()
    var spec0 = List[Float64]()
    var erased0 = List[Float64]()

    for _ in range(ROUNDS):
        # INTERLEAVED: the two arms of a pair are adjacent in time.
        var a: Int64 = 0
        var b: Int64 = 0
        var c: Int64 = 0
        var d: Int64 = 0
        var n = 0
        while n < PER_ROUND:
            a += _chunk_spec(eng, CHUNK)
            _ = eng.drain_worker(0, 1 << 16)
            b += _chunk_erased(eng, CHUNK)
            _ = eng.drain_worker(0, 1 << 16)
            c += _chunk_spec_zero(eng, CHUNK)
            _ = eng.drain_worker(0, 1 << 16)
            d += _chunk_erased_zero(eng, CHUNK)
            _ = eng.drain_worker(0, 1 << 16)
            n += CHUNK
        spec.append(Float64(Int(a)) / Float64(n))
        erased.append(Float64(Int(b)) / Float64(n))
        spec0.append(Float64(Int(c)) / Float64(n))
        erased0.append(Float64(Int(d)) / Float64(n))

    # ---------------------------------------------------------------------
    # PAIR 2 — the SUPPRESSED arms, on a WARN engine so DEBUG is rejected.
    # ---------------------------------------------------------------------
    var off_eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_WARN))
    off_eng.bind_worker_thread(UInt16(0))
    for _ in range(8):
        _ = _chunk_spec_off(off_eng, CHUNK)
        _ = _chunk_erased_off(off_eng, CHUNK)

    var spec_off = List[Float64]()
    var erased_off = List[Float64]()
    for _ in range(ROUNDS):
        var a: Int64 = 0
        var b: Int64 = 0
        var n = 0
        while n < PER_ROUND:
            a += _chunk_spec_off(off_eng, CHUNK)
            b += _chunk_erased_off(off_eng, CHUNK)
            n += CHUNK
        spec_off.append(Float64(Int(a)) / Float64(n))
        erased_off.append(Float64(Int(b)) / Float64(n))
    # Nothing should have reached the ring on the suppressed arms.
    assert_true(len(off_eng.drain_worker_to_lines(0, 16)) == 0)

    print("=== erased-vs-specialised emit cost (interleaved) ===")
    var m_spec = _report(String("ENABLED   1-arg  specialised"), spec^)
    var m_er = _report(String("ENABLED   1-arg  ERASED     "), erased^)
    var m_spec0 = _report(String("ENABLED   0-arg  specialised"), spec0^)
    var m_er0 = _report(String("ENABLED   0-arg  ERASED     "), erased0^)
    var m_soff = _report(String("SUPPRESSED       specialised"), spec_off^)
    var m_eoff = _report(String("SUPPRESSED       ERASED     "), erased_off^)
    print("delta enabled 1-arg (erased - specialised) ns:", m_er - m_spec)
    print("delta enabled 0-arg (erased - specialised) ns:", m_er0 - m_spec0)
    print("delta suppressed    (erased - specialised) ns:", m_eoff - m_soff)

    # Loose ceilings — a gross regression only. The printed numbers are the
    # deliverable; a tight bound on a shared runner would fail for unrelated
    # reasons and teach everyone to ignore this file.
    assert_true(m_er < 5000.0)
    assert_true(m_eoff < 5000.0)
    print("test_log_erased_emit_perf: DONE")
