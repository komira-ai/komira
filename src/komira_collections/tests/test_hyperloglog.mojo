# =============================================================================
# Unit tests for HyperLogLog
# =============================================================================
#
# Coverage:
#   Known answers (exact, no tolerance):
#     1. constants: p = 12, m = 4096, 52 tail bits
#     2. empty sketch estimates 0; one value estimates 1; one value added
#        1000 times estimates 1
#     3. the register update: top 12 bits pick the register, rho of the
#        52-bit tail (leading 1 at bit 51 -> 1, tail 1 -> 52, tail 0 -> 53),
#        and a register keeps its maximum
#     4. the estimator (Ertl's improved raw estimator) on fixed register
#        states: 100 registers at 1 and the rest empty is 101; every
#        register at 1 is 5909; one register empty and the rest at 3 is
#        23597; every register at the maximum 53, or an estimate above
#        Int.MAX, saturates at Int.MAX; a register set above 53 counts as 53
#     5. the hashes: FNV-1a-64 of "a" is the published 0xaf63dc4c8601ec8c,
#        and string, bytes and integer hashing agree on it; the hash of
#        UInt64 0 is the reference SplitMix64 output for state 0, so a
#        sketch built by one build merges with another's
#   Merge:
#     6. merge(A, B) has exactly the registers of the sketch of A union B
#     7. merge is commutative and idempotent
#     8. disjoint and overlapping merges estimate the union, not the sum
#   Accuracy (standard error 1.04 / sqrt(4096) ~= 1.6%; 5% tolerance):
#     9. 1k, 100k and 1M distinct values; duplicates do not inflate;
#        Float64 and String inputs; a batch add equals one-by-one adds
#   Accuracy across the small-range hand-over:
#    10. n = 5,000 .. 20,000 step 1,000 over 64 independent hash streams:
#        |mean relative error| <= 0.75% and rms <= 2.0% at every n
#   Determinism:
#    11. the same input gives the same registers in two sketches
# =============================================================================

from std.math import sqrt
from std.testing import TestSuite, assert_equal, assert_true

from komira_collections.hyperloglog import (
    HyperLogLog,
    HLL_PRECISION,
    HLL_NUM_REGISTERS,
    HLL_HASH_REM_BITS,
    hll_hash_int64,
    hll_hash_uint64,
    hll_hash_float64,
    hll_hash_bytes,
    hll_hash_string,
)


comptime HLL_TOLERANCE_PCT: Float64 = 0.05


def _within_tolerance(estimate: Int, expected: Int, tol: Float64) -> Bool:
    """True iff |estimate - expected| / expected <= tol."""
    if expected == 0:
        return estimate == 0
    var diff = Float64(estimate - expected)
    if diff < 0.0:
        diff = -diff
    return diff / Float64(expected) <= tol


def _assert_same_registers(a: HyperLogLog, b: HyperLogLog) raises:
    for i in range(HLL_NUM_REGISTERS):
        assert_equal(
            a.register(i),
            b.register(i),
            "register " + String(i) + " differs",
        )


def _hash_at(register: Int, tail: UInt64) -> UInt64:
    """A hash whose top 12 bits are `register` and whose low 52 are `tail`."""
    return (UInt64(register) << UInt64(HLL_HASH_REM_BITS)) | tail


# -----------------------------------------------------------------------------
# Known answers
# -----------------------------------------------------------------------------


def test_constants() raises:
    assert_equal(HLL_PRECISION, 12)
    assert_equal(HLL_NUM_REGISTERS, 4096)
    assert_equal(HLL_HASH_REM_BITS, 52)
    var hll = HyperLogLog()
    for i in range(HLL_NUM_REGISTERS):
        assert_equal(hll.register(i), UInt8(0))


def test_empty_estimate_is_zero() raises:
    var hll = HyperLogLog()
    assert_equal(hll.estimate(), 0)


def test_single_value_estimates_one() raises:
    var hll = HyperLogLog()
    hll.add_int64(Int64(42))
    assert_equal(hll.estimate(), 1)


def test_duplicates_do_not_inflate() raises:
    var hll = HyperLogLog()
    for _ in range(1000):
        hll.add_int64(Int64(7))
    assert_equal(hll.estimate(), 1)


def test_register_update() raises:
    var hll = HyperLogLog()
    # Leading 1 at the top tail bit: rho = 1.
    hll.add_hash(_hash_at(5, UInt64(1) << UInt64(51)))
    assert_equal(hll.register(5), UInt8(1))
    # Tail 1: 51 zeros then a 1, rho = 52.
    hll.add_hash(_hash_at(6, UInt64(1)))
    assert_equal(hll.register(6), UInt8(52))
    # Tail 0: rho = 52 + 1.
    hll.add_hash(_hash_at(4095, UInt64(0)))
    assert_equal(hll.register(4095), UInt8(53))
    # A smaller rho does not lower a register; a larger one raises it.
    hll.add_hash(_hash_at(6, UInt64(1) << UInt64(51)))
    assert_equal(hll.register(6), UInt8(52))
    hll.add_hash(_hash_at(5, UInt64(1) << UInt64(49)))
    assert_equal(hll.register(5), UInt8(3))
    # No other register moved.
    var touched = 0
    for i in range(HLL_NUM_REGISTERS):
        if hll.register(i) != UInt8(0):
            touched += 1
    assert_equal(touched, 3)


# The known answers below are Ertl's estimator (arXiv:1702.01284,
# Algorithm 6) evaluated in Float64 on the stated register histogram:
# E = m^2 / (2 ln 2) / z, z = m * tau(1 - C[53] / m), then z = (z + C[k]) / 2
# for k = 52 .. 1, then z += m * sigma(C[0] / m).


def test_estimator_mostly_empty_known_answer() raises:
    var hll = HyperLogLog()
    for i in range(100):
        hll.set_register(i, UInt8(1))
    # C[0] = 3996, C[1] = 100: E = 101.226... Linear counting,
    # 4096 * ln(4096 / 3996) = 101.24..., rounds to the same 101.
    assert_equal(hll.estimate(), 101)


def test_estimator_all_ones_known_answer() raises:
    var hll = HyperLogLog()
    for i in range(HLL_NUM_REGISTERS):
        hll.set_register(i, UInt8(1))
    # C[1] = 4096: z = 4096 / 2, E = 4096 / ln 2 = 5909.278...
    # (the a_m-based raw estimate, 2 * a_m * 4096, was 5907).
    assert_equal(hll.estimate(), 5909)


def test_estimator_one_empty_rest_three_known_answer() raises:
    var hll = HyperLogLog()
    for i in range(1, HLL_NUM_REGISTERS):
        hll.set_register(i, UInt8(3))
    # C[0] = 1, C[3] = 4095: z = 4095 / 8 + 4096 * sigma(1 / 4096),
    # E = 23596.777... (the a_m-based raw estimate was 23589).
    assert_equal(hll.estimate(), 23597)


def test_estimator_saturated_is_unbounded() raises:
    var hll = HyperLogLog()
    for i in range(HLL_NUM_REGISTERS):
        hll.set_register(i, UInt8(53))
    assert_equal(hll.estimate(), Int.MAX)
    # One register at 52: E = 1.53e20, above Int.MAX, so it saturates too.
    hll.set_register(0, UInt8(52))
    assert_equal(hll.estimate(), Int.MAX)
    # Every register at 40: z = 4096 / 2^40, E = 4096 * 2^40 / (2 ln 2)
    # = 3248660424278399.4, in range. Above 2^52 one Float64 ulp is 1 or 2,
    # so the pin allows 4.
    for i in range(HLL_NUM_REGISTERS):
        hll.set_register(i, UInt8(40))
    assert_true(abs(hll.estimate() - 3248660424278399) <= 4)


def test_estimator_tau_term_known_answer() raises:
    # 2048 registers at 53 and 2048 at 40: z = 4096 * tau(1/2) + 2048 / 2^40,
    # E = 6496845229059777.x. Without the tau term E would be
    # 6497320848556798, about 4.8e11 away, so this pins tau.
    var hll = HyperLogLog()
    for i in range(HLL_NUM_REGISTERS):
        hll.set_register(i, UInt8(53) if i < 2048 else UInt8(40))
    assert_true(abs(hll.estimate() - 6496845229059777) <= 4)


def test_estimator_clamps_registers_above_maximum() raises:
    var at_max = HyperLogLog()
    var above = HyperLogLog()
    for i in range(10):
        at_max.set_register(i, UInt8(53))
        above.set_register(i, UInt8(200))
    # C[0] = 4086, C[53] = 10: E = 10.012...
    assert_equal(at_max.estimate(), 10)
    assert_equal(above.estimate(), at_max.estimate())


def test_hash_known_answers() raises:
    # FNV-1a-64("a") = 0xaf63dc4c8601ec8c, then the splitmix64 finalizer.
    var expected = hll_hash_uint64(UInt64(0xAF63DC4C8601EC8C))
    assert_equal(hll_hash_string(String("a")), expected)
    var a_bytes: List[UInt8] = [UInt8(0x61)]
    assert_equal(hll_hash_bytes(a_bytes), expected)
    # Empty input hashes the FNV-1a offset basis.
    var empty: List[UInt8] = []
    assert_equal(hll_hash_bytes(empty), hll_hash_uint64(UInt64(0xCBF29CE484222325)))
    assert_equal(hll_hash_string(String("")), hll_hash_bytes(empty))
    # Int64 hashing is the UInt64 hash of the same bit pattern.
    assert_equal(hll_hash_int64(Int64(-1)), hll_hash_uint64(UInt64(0xFFFFFFFFFFFFFFFF)))
    # Float64 hashing is the UInt64 hash of the IEEE-754 bits.
    assert_equal(hll_hash_float64(1.0), hll_hash_uint64(UInt64(0x3FF0000000000000)))
    assert_true(hll_hash_float64(0.0) != hll_hash_float64(-0.0))
    # The reference SplitMix64 output for state 0 (state + 0x9E3779B97F4A7C15,
    # then the 30/27/31 mix). A change here makes sketches built by
    # different builds unmergeable.
    assert_equal(hll_hash_uint64(UInt64(0)), UInt64(0x4B2275ECE0140B05))


# -----------------------------------------------------------------------------
# Merge
# -----------------------------------------------------------------------------


def test_merge_equals_sketch_of_union() raises:
    var a = HyperLogLog()
    var b = HyperLogLog()
    var union = HyperLogLog()
    for i in range(3000):
        a.add_int64(Int64(i))
        union.add_int64(Int64(i))
    for i in range(2000, 9000):
        b.add_int64(Int64(i))
        union.add_int64(Int64(i))
    a.merge(b)
    _assert_same_registers(a, union)
    assert_equal(a.estimate(), union.estimate())


def test_merge_commutative_and_idempotent() raises:
    var a = HyperLogLog()
    var b = HyperLogLog()
    for i in range(500):
        a.add_int64(Int64(i))
    for i in range(300, 1200):
        b.add_int64(Int64(i))
    var ab = a.copy()
    ab.merge(b)
    var ba = b.copy()
    ba.merge(a)
    _assert_same_registers(ab, ba)
    var again = ab.copy()
    again.merge(b)
    again.merge(ab)
    _assert_same_registers(again, ab)
    # Merging an empty sketch changes nothing.
    var with_empty = ab.copy()
    with_empty.merge(HyperLogLog())
    _assert_same_registers(with_empty, ab)


def test_merge_disjoint_estimates_union() raises:
    var a = HyperLogLog()
    var b = HyperLogLog()
    for i in range(1000):
        a.add_int64(Int64(i))
    for i in range(1000, 2000):
        b.add_int64(Int64(i))
    a.merge(b)
    var est = a.estimate()
    assert_true(
        _within_tolerance(est, 2000, HLL_TOLERANCE_PCT),
        "merged disjoint: estimate=" + String(est) + " not within 5% of 2000",
    )


def test_merge_overlapping_estimates_union() raises:
    var a = HyperLogLog()
    var b = HyperLogLog()
    for i in range(1500):
        a.add_int64(Int64(i))
    for i in range(500, 2000):
        b.add_int64(Int64(i))
    a.merge(b)
    var est = a.estimate()
    assert_true(
        _within_tolerance(est, 2000, HLL_TOLERANCE_PCT),
        "merged overlapping: estimate=" + String(est) + " not within 5% of 2000",
    )


# -----------------------------------------------------------------------------
# Accuracy
# -----------------------------------------------------------------------------


def test_accuracy_1k_distinct() raises:
    var hll = HyperLogLog()
    for i in range(1000):
        hll.add_int64(Int64(i))
    var est = hll.estimate()
    assert_true(
        _within_tolerance(est, 1000, HLL_TOLERANCE_PCT),
        "1k distinct: estimate=" + String(est) + " not within 5% of 1000",
    )


def test_accuracy_with_duplicates() raises:
    var hll = HyperLogLog()
    for _ in range(10):
        for i in range(1000):
            hll.add_int64(Int64(i))
    var est = hll.estimate()
    assert_true(
        _within_tolerance(est, 1000, HLL_TOLERANCE_PCT),
        "duplicates: estimate=" + String(est) + " not within 5% of 1000",
    )


def test_accuracy_100k_distinct() raises:
    var hll = HyperLogLog()
    for i in range(100_000):
        hll.add_uint64(UInt64(i) * UInt64(0x9E3779B97F4A7C15))
    var est = hll.estimate()
    assert_true(
        _within_tolerance(est, 100_000, HLL_TOLERANCE_PCT),
        "100k distinct: estimate=" + String(est) + " not within 5% of 100000",
    )


def test_accuracy_1m_distinct() raises:
    var hll = HyperLogLog()
    for i in range(1_000_000):
        hll.add_uint64(UInt64(i))
    var est = hll.estimate()
    assert_true(
        _within_tolerance(est, 1_000_000, HLL_TOLERANCE_PCT),
        "1M distinct: estimate=" + String(est) + " not within 5% of 1000000",
    )


def test_float64_distinct() raises:
    var hll = HyperLogLog()
    for i in range(1000):
        hll.add_float64(Float64(i) * 1.5)
    var est = hll.estimate()
    assert_true(
        _within_tolerance(est, 1000, HLL_TOLERANCE_PCT),
        "1k float distinct: estimate=" + String(est) + " not within 5% of 1000",
    )


def test_string_distinct() raises:
    var hll = HyperLogLog()
    for i in range(100):
        hll.add_hash(hll_hash_string(String("value_") + String(i)))
    var est = hll.estimate()
    assert_true(
        _within_tolerance(est, 100, HLL_TOLERANCE_PCT),
        "100 string distinct: estimate=" + String(est) + " not within 5% of 100",
    )


def test_batch_add_equals_single_adds() raises:
    var batch = HyperLogLog()
    var single = HyperLogLog()
    var hashes = List[UInt64]()
    for i in range(5000):
        var h = hll_hash_int64(Int64(i))
        hashes.append(h)
        single.add_hash(h)
    batch.add_hashes(hashes)
    _assert_same_registers(batch, single)


def test_bytes_and_string_agree() raises:
    var from_bytes = HyperLogLog()
    var from_string = HyperLogLog()
    for i in range(200):
        var s = String("k") + String(i)
        var bytes = List[UInt8]()
        for b in s.as_bytes():
            bytes.append(b)
        from_bytes.add_bytes(bytes)
        from_string.add_hash(hll_hash_string(s))
    _assert_same_registers(from_bytes, from_string)


# -----------------------------------------------------------------------------
# Accuracy across the small-range hand-over
# -----------------------------------------------------------------------------

# 64 independent streams: stream s ingests the values (s << 32) | i for
# i = 0, 1, 2, ..., which the splitmix64 finalizer turns into 64 unrelated
# hash sequences. Each stream is estimated at every grid point it passes.
comptime HANDOVER_STREAMS: Int = 64
comptime HANDOVER_GRID_LO: Int = 5000
comptime HANDOVER_GRID_HI: Int = 20000
comptime HANDOVER_GRID_STEP: Int = 1000
comptime HANDOVER_GRID_POINTS: Int = (
    HANDOVER_GRID_HI - HANDOVER_GRID_LO
) // HANDOVER_GRID_STEP + 1
# The standard error is 1.04 / sqrt(4096) ~= 1.63%. The rms over 64 streams
# has a sampling spread of about 1.63% / sqrt(2 * 64) ~= 0.14%, so 2.0% is
# more than two spreads above it; the mean has a spread of about
# 1.63% / sqrt(64) ~= 0.2%, so 0.75% is more than three.
comptime HANDOVER_RMS_BOUND: Float64 = 0.020
comptime HANDOVER_MEAN_BOUND: Float64 = 0.0075


def test_accuracy_across_small_range_handover() raises:
    """Relative error stays unbiased and near the standard error for every n
    from 5,000 to 20,000: the range around m * 5/2 = 10,240 where an
    estimator that switches from linear counting to the raw HLL estimate
    hands over."""
    var sum_err = List[Float64](capacity=HANDOVER_GRID_POINTS)
    var sum_sq = List[Float64](capacity=HANDOVER_GRID_POINTS)
    for _ in range(HANDOVER_GRID_POINTS):
        sum_err.append(0.0)
        sum_sq.append(0.0)
    for s in range(HANDOVER_STREAMS):
        var hll = HyperLogLog()
        var added = 0
        for g in range(HANDOVER_GRID_POINTS):
            var n = HANDOVER_GRID_LO + g * HANDOVER_GRID_STEP
            while added < n:
                hll.add_uint64((UInt64(s) << UInt64(32)) | UInt64(added))
                added += 1
            var err = Float64(hll.estimate() - n) / Float64(n)
            sum_err[g] += err
            sum_sq[g] += err * err
    var failures = String()
    for g in range(HANDOVER_GRID_POINTS):
        var n = HANDOVER_GRID_LO + g * HANDOVER_GRID_STEP
        var mean = sum_err[g] / Float64(HANDOVER_STREAMS)
        var rms = sqrt(sum_sq[g] / Float64(HANDOVER_STREAMS))
        if rms > HANDOVER_RMS_BOUND or abs(mean) > HANDOVER_MEAN_BOUND:
            failures += (
                " n="
                + String(n)
                + " mean="
                + String(mean * 100.0)
                + "% rms="
                + String(rms * 100.0)
                + "%;"
            )
    assert_equal(
        failures,
        String(),
        "relative error out of bounds (|mean| <= 0.75%, rms <= 2.0%):"
        + failures,
    )


# -----------------------------------------------------------------------------
# Determinism
# -----------------------------------------------------------------------------


def test_same_input_same_registers() raises:
    var a = HyperLogLog()
    var b = HyperLogLog()
    for i in range(5000):
        a.add_int64(Int64(i))
        b.add_int64(Int64(i))
    _assert_same_registers(a, b)
    assert_equal(a.estimate(), b.estimate())


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
