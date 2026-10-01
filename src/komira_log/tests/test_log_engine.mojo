# =============================================================================
# test_log_engine.mojo — komira_log P2a engine core round-trip tests.
# =============================================================================
#
# The deliverable: the binary event-pipeline core, driven by a DIRECT
# round-trip test (no runtime wiring — that's P2b). Covers:
#
#   * The core round-trip — emit several distinct sites (different fmt / level /
#     module / arg arity / arg types) into a per-core ring → drain → decode →
#     assert each renders the EXPECTED text line (wall-time from the anchor +
#     level + module + interpolated args). This is the encode/decode round-trip, through the ring.
#   * Per-core isolation — emit into ring[0] and ring[1] from "two producers" →
#     drain each → assert NO cross-contamination (the SPSC invariant).
#   * Backpressure — fill a DROP-policy ring → assert overflow is counted and
#     the policy behaves; a BLOCK-policy ring never drops.
#   * Timestamp conversion — a record's raw tick → wall-time via the anchor
#     renders a plausible (post-epoch) time.
#   * POD invariant — the record is fixed-stride and round-trips through a Slab.
#   * Arena spill — a long string arg spills to the ring arena and decodes.
#   * Microbench — emit N records into a pre-allocated ring (informational).
#
# The site dictionary is built from the SAME comptime fmt/module literals the
# emit path uses, so the digests match by construction.
# =============================================================================

from std.time import perf_counter_ns

from std.testing import assert_equal, assert_true, assert_false

from komira_log.levels import LEVEL_INFO, LEVEL_WARN, LEVEL_ERROR, LEVEL_DEBUG
from komira_log.log_arg import ArgI64, ArgU64, ArgF64, ArgStr, ArgBool, Field

from komira_obs.ring_buffer import OVERFLOW_BLOCK, OVERFLOW_DROP

from komira_log.engine.log_event_record import (
    LogEventRecord,
    REC_LOG,
    ARG_INLINE_BYTES,
)
from komira_log.engine.record_ring import LogRecordRing
from komira_log.engine.site_dictionary import SiteDictionary, fnv1a_32
from komira_log.engine.calibration import (
    CalibrationAnchor,
    capture_anchor,
    read_raw_ticks,
    read_realtime_ns,
)
from komira_log.engine.emit import emit_record
from komira_log.engine.drain import drain_to_lines


# A fixed, deterministic anchor so the round-trip renders a STABLE wall-time
# regardless of when the test runs. tick0=0, wall0=a known epoch-ms*1e6,
# tick_hz=1e9 (1 tick == 1 ns), so a record with timestamp == T ns renders at
# (wall0_ns + T) → ms. We emit records and then OVERRIDE their timestamps to a
# known value so the rendered ts is deterministic.
def _suffix(s: String) -> String:
    """Return the line after the first space (LEVEL onward) — strips the
    non-deterministic leading timestamp for assertion."""
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


def _fixed_anchor() -> CalibrationAnchor:
    # 2026-10-01T00:00:00.000Z == 1790812800 s since epoch.
    var wall0_ns = UInt64(1_790_812_800) * UInt64(1_000_000_000)
    return CalibrationAnchor(tick0=UInt64(0), wall0_ns=wall0_ns, tick_hz=UInt64(1_000_000_000))


def _build_dict() raises -> SiteDictionary:
    var d = SiteDictionary()
    d.register["query finished in {} ms", "komira_engine"]()
    d.register["scanned {} rows, {} bytes", "komira_engine"]()
    d.register["opened file {}", "komira_parquet"]()
    d.register["ratio {} over baseline {}", "komira_bench"]()
    d.register["no args here", "komira_core"]()
    d.register["t={} name={} f={}", "komira_engine"]()
    d.register["retry {}", "komira_agent"]()
    return d^


def test_core_round_trip() raises:
    """Emit distinct sites into one ring, drain, assert each rendered line."""
    var dict = _build_dict()
    var anchor = _fixed_anchor()
    var ring = LogRecordRing(capacity=64, overflow_policy=OVERFLOW_BLOCK)

    # Emit several distinct sites. corr_id=0 (no trace correlation in P2a).
    _ = emit_record["query finished in {} ms", "komira_engine"](
        ring, LEVEL_INFO, UInt64(0), ArgI64(42)
    )
    _ = emit_record["scanned {} rows, {} bytes", "komira_engine"](
        ring, LEVEL_INFO, UInt64(0), ArgI64(6001215), ArgI64(298000000)
    )
    _ = emit_record["opened file {}", "komira_parquet"](
        ring, LEVEL_DEBUG, UInt64(0), ArgStr(String("lineitem.parquet"))
    )
    _ = emit_record["ratio {} over baseline {}", "komira_bench"](
        ring, LEVEL_INFO, UInt64(0), ArgF64(0.988), ArgF64(1.0)
    )
    _ = emit_record["no args here", "komira_core"](
        ring, LEVEL_WARN, UInt64(0)
    )
    _ = emit_record["t={} name={} f={}", "komira_engine"](
        ring, LEVEL_INFO, UInt64(0), ArgI64(7), ArgStr(String("q1")), ArgF64(3.5)
    )
    # A site with a trailing key=value Field.
    _ = emit_record["retry {}", "komira_agent"](
        ring, LEVEL_ERROR, UInt64(0), ArgI64(3), Field("fatal", ArgBool(False))
    )

    var lines = drain_to_lines(ring, dict, anchor)
    assert_equal(len(lines), 7)

    # The message + level + module portions are deterministic; the timestamp is
    # derived from a real raw tick (we did NOT override it here), so we assert
    # on the suffix after the first space (LEVEL onward).
    assert_equal(
        _suffix(lines[0]), String("INFO [komira_engine] query finished in 42 ms")
    )
    assert_equal(
        _suffix(lines[1]),
        String("INFO [komira_engine] scanned 6001215 rows, 298000000 bytes"),
    )
    assert_equal(
        _suffix(lines[2]),
        String("DEBUG [komira_parquet] opened file lineitem.parquet"),
    )
    assert_equal(
        _suffix(lines[3]),
        String("INFO [komira_bench] ratio 0.988 over baseline 1.0"),
    )
    assert_equal(_suffix(lines[4]), String("WARN [komira_core] no args here"))
    assert_equal(
        _suffix(lines[5]),
        String("INFO [komira_engine] t=7 name=q1 f=3.5"),
    )
    assert_equal(
        _suffix(lines[6]),
        String("ERROR [komira_agent] retry 3 fatal=false"),
    )


def test_per_core_isolation() raises:
    """Two producers write disjoint rings; each drains only its own records."""
    var dict = _build_dict()
    var anchor = _fixed_anchor()
    var ring0 = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)
    var ring1 = LogRecordRing(capacity=16, overflow_policy=OVERFLOW_BLOCK)

    # Producer 0 → ring0; producer 1 → ring1.
    _ = emit_record["retry {}", "komira_agent"](ring0, LEVEL_INFO, UInt64(0), ArgI64(100))
    _ = emit_record["retry {}", "komira_agent"](ring0, LEVEL_INFO, UInt64(0), ArgI64(101))
    _ = emit_record["retry {}", "komira_agent"](ring1, LEVEL_INFO, UInt64(0), ArgI64(900))

    var l0 = drain_to_lines(ring0, dict, anchor)
    var l1 = drain_to_lines(ring1, dict, anchor)

    assert_equal(len(l0), 2)
    assert_equal(len(l1), 1)

    assert_true(_has(l0[0], String("retry 100")))
    assert_true(_has(l0[1], String("retry 101")))
    assert_true(_has(l1[0], String("retry 900")))
    # No cross-contamination: ring1's line is NOT in ring0's output.
    assert_false(_has(l0[0], String("retry 900")))
    assert_false(_has(l0[1], String("retry 900")))


def test_backpressure_drop() raises:
    """A DROP-policy ring at capacity drops + counts; never blocks."""
    var ring = LogRecordRing(capacity=4, overflow_policy=OVERFLOW_DROP)
    # capacity rounds up to 4; push 4 OK then 2 dropped.
    var ok0 = emit_record["retry {}", "komira_agent"](ring, LEVEL_INFO, UInt64(0), ArgI64(0))
    var ok1 = emit_record["retry {}", "komira_agent"](ring, LEVEL_INFO, UInt64(0), ArgI64(1))
    var ok2 = emit_record["retry {}", "komira_agent"](ring, LEVEL_INFO, UInt64(0), ArgI64(2))
    var ok3 = emit_record["retry {}", "komira_agent"](ring, LEVEL_INFO, UInt64(0), ArgI64(3))
    var ok4 = emit_record["retry {}", "komira_agent"](ring, LEVEL_INFO, UInt64(0), ArgI64(4))
    var ok5 = emit_record["retry {}", "komira_agent"](ring, LEVEL_INFO, UInt64(0), ArgI64(5))

    assert_true(ok0)
    assert_true(ok1)
    assert_true(ok2)
    assert_true(ok3)
    assert_false(ok4)  # full → dropped
    assert_false(ok5)  # full → dropped
    assert_equal(Int(ring.overflow_dropped_count()), 2)
    assert_equal(Int(ring.approximate_size()), 4)


def test_backpressure_block_no_drop() raises:
    """A BLOCK-policy ring with room never reports a drop."""
    var ring = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)
    for i in range(8):
        var ok = emit_record["retry {}", "komira_agent"](
            ring, LEVEL_INFO, UInt64(0), ArgI64(Int64(i))
        )
        assert_true(ok)
    assert_equal(Int(ring.overflow_dropped_count()), 0)


def test_timestamp_conversion() raises:
    """A raw tick → wall-time MS via the anchor renders a plausible time."""
    # With tick_hz=1e9 (1 tick == 1 ns) and tick0=0, a record timestamp of
    # 500_000_000 ticks == 500 ms after wall0. wall0 = 2026-10-01T00:00:00.000Z.
    var anchor = _fixed_anchor()
    var wall_ms = anchor.tick_to_wall_ms(UInt64(500_000_000))
    # 1790812800 s * 1000 + 500 ms.
    assert_equal(Int(wall_ms), 1_790_812_800_000 + 500)

    # A real captured anchor converts a near-now tick to a recent wall time.
    var live = capture_anchor()
    var now_tick = read_raw_ticks()
    var live_ms = live.tick_to_wall_ms(now_tick)
    # Sanity: after the start of 2020 (1577836800000 ms) and before year 2100.
    assert_true(Int(live_ms) > 1_577_836_800_000)
    assert_true(Int(live_ms) < 4_102_444_800_000)


def test_record_pod_through_slab() raises:
    """The POD record round-trips through the ring's Slab unchanged."""
    var ring = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)
    _ = emit_record["scanned {} rows, {} bytes", "komira_engine"](
        ring, LEVEL_INFO, UInt64(12345), ArgI64(7), ArgI64(8)
    )
    var rec_opt = ring.try_pop()
    assert_true(Bool(rec_opt))
    var rec = rec_opt.value().copy()
    assert_equal(Int(rec.kind), Int(REC_LOG))
    assert_equal(Int(rec.level), Int(LEVEL_INFO))
    assert_equal(Int(rec.n_args), 2)
    assert_equal(Int(rec.corr_id), 12345)
    assert_equal(Int(rec.site_id), Int(fnv1a_32("scanned {} rows, {} bytes")))
    assert_false(rec.has_arg_overflow())  # 2 int args fit inline


def test_arena_spill_long_string() raises:
    """A string arg longer than the inline blob spills to the arena + decodes."""
    var dict = SiteDictionary()
    dict.register["msg {}", "komira_engine"]()
    var anchor = _fixed_anchor()
    var ring = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)

    # A string longer than ARG_INLINE_BYTES (48) forces the spill path.
    var long = String("")
    for _ in range(100):
        long += "x"
    _ = emit_record["msg {}", "komira_engine"](
        ring, LEVEL_INFO, UInt64(0), ArgStr(long)
    )

    # Inspect the record: it should carry the overflow flag.
    var rec_opt = ring.try_pop()
    assert_true(Bool(rec_opt))
    var rec = rec_opt.value().copy()
    assert_true(rec.has_arg_overflow())
    # Put it back is not possible; re-emit + drain to assert the decode.
    var ring2 = LogRecordRing(capacity=8, overflow_policy=OVERFLOW_BLOCK)
    var long2 = String("")
    for _ in range(100):
        long2 += "x"
    _ = emit_record["msg {}", "komira_engine"](
        ring2, LEVEL_INFO, UInt64(0), ArgStr(long2)
    )
    var lines = drain_to_lines(ring2, dict, anchor)
    assert_equal(len(lines), 1)
    assert_true(lines[0].find(String("msg ")) >= 0)
    # The 100-x payload survived the spill round-trip.
    var xs = String("")
    for _ in range(100):
        xs += "x"
    assert_true(lines[0].find(xs) >= 0)


def test_microbench_emit() raises:
    """Informational: emit N records into a pre-allocated ring. Not a gate."""
    var ring = LogRecordRing(capacity=4096, overflow_policy=OVERFLOW_DROP)
    var N = 100000
    # Warm.
    for i in range(1000):
        _ = emit_record["retry {}", "komira_agent"](
            ring, LEVEL_INFO, UInt64(0), ArgI64(Int64(i))
        )
        _ = ring.try_pop()
    var t0 = perf_counter_ns()
    for i in range(N):
        _ = emit_record["retry {}", "komira_agent"](
            ring, LEVEL_INFO, UInt64(0), ArgI64(Int64(i))
        )
        _ = ring.try_pop()  # keep the ring from filling under DROP
    var t1 = perf_counter_ns()
    var ns_each = Float64(Int(t1 - t0)) / Float64(N)
    print("  BENCH  emit+pop (1xInt, reused ring):", ns_each, "ns/record over", N)
    # Not a correctness gate — just assert it ran.
    assert_true(ns_each > 0.0)


def main() raises:
    test_core_round_trip()
    test_per_core_isolation()
    test_backpressure_drop()
    test_backpressure_block_no_drop()
    test_timestamp_conversion()
    test_record_pod_through_slab()
    test_arena_spill_long_string()
    test_microbench_emit()
    print("OK: test_log_engine (P2a core round-trip)")
