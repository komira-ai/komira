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
#     4. the estimator's three branches: 100 registers at 1 and the rest
#        empty is linear counting, round(4096 * ln(4096 / 3996)) = 101;
#        every register at 1 is pure HLL, round(2 * a_m * 4096) = 5907; one
#        register empty and the rest at 3 is pure HLL too, because the raw
#        estimate 23589 is above 5/2 * m, round(a_m * m^2 / 512.875) = 23589
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
#   Determinism:
#    10. the same input gives the same registers in two sketches
# =============================================================================

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


def test_estimator_linear_counting_known_answer() raises:
    var hll = HyperLogLog()
    for i in range(100):
        hll.set_register(i, UInt8(1))
    # 4096 * ln(4096 / 3996) = 101.24...
    assert_equal(hll.estimate(), 101)


def test_estimator_pure_hll_known_answer() raises:
    var hll = HyperLogLog()
    for i in range(HLL_NUM_REGISTERS):
        hll.set_register(i, UInt8(1))
    # No empty register: a_m * m^2 / (m / 2) = 2 * a_m * m = 5907.33...
    assert_equal(hll.estimate(), 5907)


def test_estimator_empty_register_above_threshold_known_answer() raises:
    var hll = HyperLogLog()
    for i in range(1, HLL_NUM_REGISTERS):
        hll.set_register(i, UInt8(3))
    # One empty register, but the raw estimate is above 5/2 * m = 10240:
    # sum = 1 + 4095 / 8 = 512.875, a_m * m^2 / sum = 23589.02..., so the
    # estimator stays pure HLL. Linear counting would give
    # round(4096 * ln(4096)) = 34070.
    assert_equal(hll.estimate(), 23589)


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
