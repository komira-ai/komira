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
# NOTHING HERE ASSERTS A TIME. The ns/emit figures are printed and nothing else:
# a threshold on them depends on the machine and fails on a loaded one for
# reasons that have nothing to do with the logger. What the file ASSERTS is the
# set of properties a per-emit cost regression would break, counted exactly:
#
#   * every ENABLED emit reached the ring: the records drained after each arm
#     equal the emits made, and no ring dropped a record. An emit that reached
#     the ring returned before the cold render block (the one place that builds
#     Strings and Lists); the counts show there was no synchronous fallback and
#     no lost record. They do not count allocations: an emit that pushed its
#     record and also built a String first would still pass (a known gap).
#   * site registration does not repeat: after the warm-up the SiteDictionary
#     holds exactly the sites the arms use, and its length is the same after
#     every measured round. A registration that re-runs per emit appends (and
#     allocates a String) each time, so the length would grow.
#   * a SUPPRESSED emit does no work behind the gate: no record reached the
#     ring, nothing was dropped, and no site was registered (registration sits
#     after the gates), however many emits ran.
#
# There is no process-wide allocation counter in the toolchain, so allocation is
# not counted directly: the three properties above are what is observable.
# =============================================================================

from komira_log import SharedEngine, Logger
from komira_log.logger_erased import emit_erased
from komira_log.log_value import LogValue as LV
from komira_log.env_filter import EnvFilter
from komira_log.levels import LEVEL_TRACE, LEVEL_DEBUG, LEVEL_INFO, LEVEL_WARN
from komira_log.log_arg import ArgI64

from std.testing import assert_equal, assert_true
from std.time import perf_counter_ns


comptime CHUNK = 256
comptime ROUNDS = 7
comptime PER_ROUND = 102_400  # 400 chunks
comptime WARMUP_CHUNKS = 8


def _filter_at(level: UInt8) -> EnvFilter:
    var f = EnvFilter()
    f.global_level = level
    return f^


# Drain one worker's ring and return how many records came out. This is the
# engine's inspectable drain, NOT `drain_worker`: `drain_worker` writes every
# record to the engine's log sink, and this test drains about 2.9 million
# records, which as sink output was ~500 MB of test log and made the CI log
# unreadable. The records are decoded the same way and counted the same way;
# only the delivery differs, and the lines are dropped here instead of printed.
def _drain(mut eng: SharedEngine) -> Int:
    return len(eng.drain_worker_to_lines(0, 1 << 16))


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
    var warm_drained = 0
    for _ in range(WARMUP_CHUNKS):
        _ = _chunk_spec(eng, CHUNK)
        warm_drained += _drain(eng)
        _ = _chunk_erased(eng, CHUNK)
        warm_drained += _drain(eng)
        _ = _chunk_spec_zero(eng, CHUNK)
        warm_drained += _drain(eng)
        _ = _chunk_erased_zero(eng, CHUNK)
        warm_drained += _drain(eng)
    assert_equal(
        warm_drained,
        4 * WARMUP_CHUNKS * CHUNK,
        "warm-up: every enabled emit of the four arms reached the ring",
    )
    # The two arms of a pair share one fmt, so registration made exactly two
    # sites: the 1-arg fmt and the 0-arg fmt.
    var sites_after_warmup = eng.site_dict_len()
    assert_equal(
        sites_after_warmup,
        2,
        "warm-up: one dictionary entry per distinct fmt, not one per emit",
    )

    var spec = List[Float64]()
    var erased = List[Float64]()
    var spec0 = List[Float64]()
    var erased0 = List[Float64]()

    # Records drained after each arm's chunks, summed over every measured round.
    var spec_drained = 0
    var erased_drained = 0
    var spec0_drained = 0
    var erased0_drained = 0
    var emitted = 0

    for _ in range(ROUNDS):
        # INTERLEAVED: the two arms of a pair are adjacent in time.
        var a: Int64 = 0
        var b: Int64 = 0
        var c: Int64 = 0
        var d: Int64 = 0
        var n = 0
        while n < PER_ROUND:
            a += _chunk_spec(eng, CHUNK)
            spec_drained += _drain(eng)
            b += _chunk_erased(eng, CHUNK)
            erased_drained += _drain(eng)
            c += _chunk_spec_zero(eng, CHUNK)
            spec0_drained += _drain(eng)
            d += _chunk_erased_zero(eng, CHUNK)
            erased0_drained += _drain(eng)
            n += CHUNK
            emitted += CHUNK
        spec.append(Float64(Int(a)) / Float64(n))
        erased.append(Float64(Int(b)) / Float64(n))
        spec0.append(Float64(Int(c)) / Float64(n))
        erased0.append(Float64(Int(d)) / Float64(n))

    # ---------------------------------------------------------------------
    # PAIR 2 — the SUPPRESSED arms, on a WARN engine so DEBUG is rejected.
    # ---------------------------------------------------------------------
    var off_eng = SharedEngine(num_workers=1, filter=_filter_at(LEVEL_WARN))
    off_eng.bind_worker_thread(UInt16(0))
    for _ in range(WARMUP_CHUNKS):
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
    # ---------------------------------------------------------------------
    # THE COUNTED PROPERTIES (no time is asserted anywhere below).
    # ---------------------------------------------------------------------
    # Every enabled emit of every arm reached the ring and was drained: none
    # went through the synchronous fallback, none was dropped, none was lost.
    assert_equal(emitted, ROUNDS * PER_ROUND, "the loops made the emits")
    assert_equal(spec_drained, emitted, "specialised 1-arg: every emit drained")
    assert_equal(erased_drained, emitted, "ERASED 1-arg: every emit drained")
    assert_equal(spec0_drained, emitted, "specialised 0-arg: every emit drained")
    assert_equal(erased0_drained, emitted, "ERASED 0-arg: every emit drained")
    assert_equal(eng.overflow_dropped_count(), Int64(0), "no ring dropped")
    assert_equal(eng.unknown_kind_dropped_count(), Int64(0), "no refused kind")
    # Registration did not repeat: the dictionary is what the warm-up made it.
    assert_equal(
        eng.site_dict_len(),
        sites_after_warmup,
        "no site was re-registered across the measured rounds",
    )

    # The suppressed arms did nothing behind the gate: nothing in the ring,
    # nothing dropped, nothing registered, across the warm-up and every round.
    assert_true(
        not off_eng.worker_ring_nonempty(0),
        "suppressed emits pushed no record",
    )
    assert_equal(off_eng.overflow_dropped_count(), Int64(0), "nothing dropped")
    assert_equal(
        off_eng.site_dict_len(),
        0,
        "a suppressed emit registers no site (registration is behind the gates)",
    )
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

    # The printed numbers are the deliverable, and are information only.
    print("test_log_erased_emit_perf: DONE")
