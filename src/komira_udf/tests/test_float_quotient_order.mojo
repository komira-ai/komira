# =============================================================================
# Tests for float_quotient_order.mojo: the float equality and ordering model.
#
# The oracle is standard SQL float semantics (PostgreSQL's, which the module
# header names): every NaN equals every other NaN and sorts above every
# number, `+inf` included; `-0.0` equals `+0.0`; every other pair compares as
# IEEE does. Each expected value below is worked out by hand from that rule,
# not read back from the code.
#
# What each test proves (and the defect it catches):
#   - canonicalize: every NaN payload and sign maps to the one canonical NaN,
#     `-0.0` maps to `+0.0`'s bits, and an ordinary value (inf included) keeps
#     its bits. Catches a dropped NaN arm or a zero arm that keeps the sign.
#   - eq / lt / gt / cmp: every arm of each, then a pairwise sweep over a value
#     set holding both NaN kinds, both zeros, both infinities and subnormals:
#     for every pair, lt, gt, eq and cmp agree with one another and with the
#     rank each value has in the SQL order. Catches a swapped NaN arm, a `<`
#     written `<=`, a three-way compare that disagrees with the predicates.
#   - order bits / key: the unsigned image and the signed key are monotone in
#     the order over the same set (equal images exactly for equal values), with
#     the fixed points `+0.0 -> 1 << 63`, `-inf -> ~0xFFF0...` and key(+0) = 0.
#   - identities and folds: MIN's seed is the canonical NaN (the top), MAX's is
#     `-inf` (the bottom); a fold over a list with a NaN gives NaN for MAX (SQL
#     MAX over a column with NaN is NaN) and the least number for MIN.
# =============================================================================

from std.memory import bitcast
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_udf.float_quotient_order import (
    CANONICAL_NAN_BITS_F32,
    CANONICAL_NAN_BITS_F64,
    FLOAT_MAX_SEED_BITS_F64,
    FLOAT_MIN_SEED_BITS_F64,
    canonical_bits_f32,
    canonical_bits_f64,
    canonical_nan_f32,
    canonical_nan_f64,
    canonicalize_f32,
    canonicalize_f64,
    float_max_fold_f64,
    float_max_identity_f64,
    float_min_fold_f64,
    float_min_identity_f64,
    float_quotient_cmp_f32,
    float_quotient_cmp_f64,
    float_quotient_eq_f32,
    float_quotient_eq_f64,
    float_quotient_gt_f32,
    float_quotient_gt_f64,
    float_quotient_lt_f32,
    float_quotient_lt_f64,
    float_quotient_order_bits_f32,
    float_quotient_order_bits_f64,
    float_quotient_order_key_f64,
)


# -----------------------------------------------------------------------------
# Values, spelled by their bits so no arithmetic folds them.
# -----------------------------------------------------------------------------


def _f64(bits: UInt64) -> Float64:
    return bitcast[DType.float64](bits)


def _f32(bits: UInt32) -> Float32:
    return bitcast[DType.float32](bits)


def _b64(v: Float64) -> UInt64:
    return bitcast[DType.uint64](v)


def _b32(v: Float32) -> UInt32:
    return bitcast[DType.uint32](v)


comptime POS_ZERO_64: UInt64 = 0x0000000000000000
comptime NEG_ZERO_64: UInt64 = 0x8000000000000000
comptime POS_INF_64: UInt64 = 0x7FF0000000000000
comptime NEG_INF_64: UInt64 = 0xFFF0000000000000
comptime MIN_SUB_64: UInt64 = 0x0000000000000001
comptime NAN_PAYLOAD_64: UInt64 = 0x7FF0000000000001  # signalling, payload 1
comptime NAN_NEG_64: UInt64 = 0xFFF8000000000000  # quiet, sign set

comptime POS_ZERO_32: UInt32 = 0x00000000
comptime NEG_ZERO_32: UInt32 = 0x80000000
comptime POS_INF_32: UInt32 = 0x7F800000
comptime NEG_INF_32: UInt32 = 0xFF800000
comptime MIN_SUB_32: UInt32 = 0x00000001
comptime NAN_PAYLOAD_32: UInt32 = 0x7F800001
comptime NAN_NEG_32: UInt32 = 0xFFC00000


def _ranked_f64(mut vals: List[Float64], mut ranks: List[Int]):
    """The value set in SQL order with each value's rank: equal values share
    a rank (both zeros; all three NaNs)."""
    vals = [
        _f64(NEG_INF_64), -1.0e300, -1.0, -_f64(MIN_SUB_64),
        _f64(NEG_ZERO_64), _f64(POS_ZERO_64), _f64(MIN_SUB_64), 1.0,
        1.0e300, _f64(POS_INF_64),
        _f64(NAN_PAYLOAD_64), _f64(NAN_NEG_64), canonical_nan_f64(),
    ]
    ranks = [0, 1, 2, 3, 4, 4, 5, 6, 7, 8, 9, 9, 9]


def _ranked_f32(mut vals: List[Float32], mut ranks: List[Int]):
    vals = [
        _f32(NEG_INF_32), -1.0e30, -1.0, -_f32(MIN_SUB_32),
        _f32(NEG_ZERO_32), _f32(POS_ZERO_32), _f32(MIN_SUB_32), 1.0,
        1.0e30, _f32(POS_INF_32),
        _f32(NAN_PAYLOAD_32), _f32(NAN_NEG_32), canonical_nan_f32(),
    ]
    ranks = [0, 1, 2, 3, 4, 4, 5, 6, 7, 8, 9, 9, 9]


# -----------------------------------------------------------------------------
# canonical form
# -----------------------------------------------------------------------------


def test_canonical_nan_bits() raises:
    assert_equal(_b64(canonical_nan_f64()), UInt64(0x7FF8000000000000))
    assert_equal(_b32(canonical_nan_f32()), UInt32(0x7FC00000))
    assert_equal(CANONICAL_NAN_BITS_F64, UInt64(0x7FF8000000000000))
    assert_equal(CANONICAL_NAN_BITS_F32, UInt32(0x7FC00000))


def test_canonicalize_f64() raises:
    # Every NaN, whatever its payload or sign, becomes the canonical NaN.
    assert_equal(_b64(canonicalize_f64(_f64(NAN_PAYLOAD_64))), CANONICAL_NAN_BITS_F64)
    assert_equal(_b64(canonicalize_f64(_f64(NAN_NEG_64))), CANONICAL_NAN_BITS_F64)
    # -0.0 loses its sign; +0.0 stays.
    assert_equal(_b64(canonicalize_f64(_f64(NEG_ZERO_64))), POS_ZERO_64)
    assert_equal(_b64(canonicalize_f64(_f64(POS_ZERO_64))), POS_ZERO_64)
    # Anything else keeps its exact bits.
    assert_equal(_b64(canonicalize_f64(-1.5)), _b64(-1.5))
    assert_equal(_b64(canonicalize_f64(_f64(NEG_INF_64))), NEG_INF_64)
    assert_equal(_b64(canonicalize_f64(_f64(MIN_SUB_64))), MIN_SUB_64)
    assert_equal(canonical_bits_f64(_f64(NEG_ZERO_64)), canonical_bits_f64(0.0))
    assert_equal(
        canonical_bits_f64(_f64(NAN_NEG_64)),
        canonical_bits_f64(_f64(NAN_PAYLOAD_64)),
    )
    assert_true(canonical_bits_f64(1.0) != canonical_bits_f64(-1.0))


def test_canonicalize_f32() raises:
    assert_equal(_b32(canonicalize_f32(_f32(NAN_PAYLOAD_32))), CANONICAL_NAN_BITS_F32)
    assert_equal(_b32(canonicalize_f32(_f32(NAN_NEG_32))), CANONICAL_NAN_BITS_F32)
    assert_equal(_b32(canonicalize_f32(_f32(NEG_ZERO_32))), POS_ZERO_32)
    assert_equal(_b32(canonicalize_f32(_f32(POS_ZERO_32))), POS_ZERO_32)
    assert_equal(_b32(canonicalize_f32(Float32(-1.5))), _b32(Float32(-1.5)))
    assert_equal(_b32(canonicalize_f32(_f32(NEG_INF_32))), NEG_INF_32)
    assert_equal(_b32(canonicalize_f32(_f32(MIN_SUB_32))), MIN_SUB_32)
    assert_equal(canonical_bits_f32(_f32(NEG_ZERO_32)), canonical_bits_f32(0.0))
    assert_equal(
        canonical_bits_f32(_f32(NAN_NEG_32)),
        canonical_bits_f32(_f32(NAN_PAYLOAD_32)),
    )
    assert_true(canonical_bits_f32(1.0) != canonical_bits_f32(-1.0))


# -----------------------------------------------------------------------------
# eq / lt / gt / cmp: each arm by hand
# -----------------------------------------------------------------------------


def test_predicates_f64_arms() raises:
    var nan = _f64(NAN_PAYLOAD_64)
    var nan2 = _f64(NAN_NEG_64)
    var inf = _f64(POS_INF_64)
    var nz = _f64(NEG_ZERO_64)
    # eq
    assert_true(float_quotient_eq_f64(nan, nan2))
    assert_false(float_quotient_eq_f64(nan, 1.0))
    assert_false(float_quotient_eq_f64(1.0, nan))
    assert_true(float_quotient_eq_f64(nz, 0.0))
    assert_true(float_quotient_eq_f64(2.0, 2.0))
    assert_false(float_quotient_eq_f64(1.0, 2.0))
    # lt: NaN is the top
    assert_false(float_quotient_lt_f64(nan, 1.0))
    assert_false(float_quotient_lt_f64(nan, nan2))
    assert_true(float_quotient_lt_f64(inf, nan))
    assert_true(float_quotient_lt_f64(1.0, 2.0))
    assert_false(float_quotient_lt_f64(2.0, 1.0))
    assert_false(float_quotient_lt_f64(nz, 0.0))
    # gt
    assert_true(float_quotient_gt_f64(nan, inf))
    assert_false(float_quotient_gt_f64(nan, nan2))
    assert_false(float_quotient_gt_f64(inf, nan))
    assert_true(float_quotient_gt_f64(2.0, 1.0))
    assert_false(float_quotient_gt_f64(1.0, 2.0))
    assert_false(float_quotient_gt_f64(0.0, nz))
    # cmp
    assert_equal(float_quotient_cmp_f64(nan, nan2), 0)
    assert_equal(float_quotient_cmp_f64(nan, inf), 1)
    assert_equal(float_quotient_cmp_f64(inf, nan), -1)
    assert_equal(float_quotient_cmp_f64(1.0, 2.0), -1)
    assert_equal(float_quotient_cmp_f64(2.0, 1.0), 1)
    assert_equal(float_quotient_cmp_f64(nz, 0.0), 0)


def test_predicates_f32_arms() raises:
    var nan = _f32(NAN_PAYLOAD_32)
    var nan2 = _f32(NAN_NEG_32)
    var inf = _f32(POS_INF_32)
    var nz = _f32(NEG_ZERO_32)
    assert_true(float_quotient_eq_f32(nan, nan2))
    assert_false(float_quotient_eq_f32(nan, 1.0))
    assert_false(float_quotient_eq_f32(1.0, nan))
    assert_true(float_quotient_eq_f32(nz, 0.0))
    assert_true(float_quotient_eq_f32(2.0, 2.0))
    assert_false(float_quotient_eq_f32(1.0, 2.0))
    assert_false(float_quotient_lt_f32(nan, 1.0))
    assert_false(float_quotient_lt_f32(nan, nan2))
    assert_true(float_quotient_lt_f32(inf, nan))
    assert_true(float_quotient_lt_f32(1.0, 2.0))
    assert_false(float_quotient_lt_f32(2.0, 1.0))
    assert_false(float_quotient_lt_f32(nz, 0.0))
    assert_true(float_quotient_gt_f32(nan, inf))
    assert_false(float_quotient_gt_f32(nan, nan2))
    assert_false(float_quotient_gt_f32(inf, nan))
    assert_true(float_quotient_gt_f32(2.0, 1.0))
    assert_false(float_quotient_gt_f32(1.0, 2.0))
    assert_false(float_quotient_gt_f32(0.0, nz))
    assert_equal(float_quotient_cmp_f32(nan, nan2), 0)
    assert_equal(float_quotient_cmp_f32(nan, inf), 1)
    assert_equal(float_quotient_cmp_f32(inf, nan), -1)
    assert_equal(float_quotient_cmp_f32(1.0, 2.0), -1)
    assert_equal(float_quotient_cmp_f32(2.0, 1.0), 1)
    assert_equal(float_quotient_cmp_f32(nz, 0.0), 0)


# -----------------------------------------------------------------------------
# Pairwise sweep: the predicates, cmp and the images agree with SQL rank.
# -----------------------------------------------------------------------------


def _sign(x: Int) -> Int:
    if x < 0:
        return -1
    if x > 0:
        return 1
    return 0


def test_pairwise_f64_matches_sql_rank() raises:
    var vals = List[Float64]()
    var ranks = List[Int]()
    _ranked_f64(vals, ranks)
    for i in range(len(vals)):
        for j in range(len(vals)):
            var want = _sign(ranks[i] - ranks[j])
            var a = vals[i]
            var b = vals[j]
            var where = String("f64 pair ") + String(i) + "," + String(j)
            assert_equal(float_quotient_cmp_f64(a, b), want, where + " cmp")
            assert_equal(float_quotient_lt_f64(a, b), want < 0, where + " lt")
            assert_equal(float_quotient_gt_f64(a, b), want > 0, where + " gt")
            assert_equal(float_quotient_eq_f64(a, b), want == 0, where + " eq")
            var ba = float_quotient_order_bits_f64(a)
            var bb = float_quotient_order_bits_f64(b)
            assert_equal(_sign(1 if ba > bb else (-1 if ba < bb else 0)), want, where + " bits")
            var ka = float_quotient_order_key_f64(a)
            var kb = float_quotient_order_key_f64(b)
            assert_equal(1 if ka > kb else (-1 if ka < kb else 0), want, where + " key")
            assert_equal(
                canonical_bits_f64(a) == canonical_bits_f64(b),
                want == 0,
                where + " canonical bits",
            )


def test_pairwise_f32_matches_sql_rank() raises:
    var vals = List[Float32]()
    var ranks = List[Int]()
    _ranked_f32(vals, ranks)
    for i in range(len(vals)):
        for j in range(len(vals)):
            var want = _sign(ranks[i] - ranks[j])
            var a = vals[i]
            var b = vals[j]
            var where = String("f32 pair ") + String(i) + "," + String(j)
            assert_equal(float_quotient_cmp_f32(a, b), want, where + " cmp")
            assert_equal(float_quotient_lt_f32(a, b), want < 0, where + " lt")
            assert_equal(float_quotient_gt_f32(a, b), want > 0, where + " gt")
            assert_equal(float_quotient_eq_f32(a, b), want == 0, where + " eq")
            var ba = float_quotient_order_bits_f32(a)
            var bb = float_quotient_order_bits_f32(b)
            assert_equal(1 if ba > bb else (-1 if ba < bb else 0), want, where + " bits")
            assert_equal(
                canonical_bits_f32(a) == canonical_bits_f32(b),
                want == 0,
                where + " canonical bits",
            )


def test_order_images_fixed_points() raises:
    # A non-negative value sets the top bit; a negative one is inverted.
    assert_equal(float_quotient_order_bits_f64(0.0), UInt64(1) << 63)
    assert_equal(float_quotient_order_bits_f64(_f64(NEG_ZERO_64)), UInt64(1) << 63)
    assert_equal(float_quotient_order_bits_f64(_f64(NEG_INF_64)), UInt64(0x000FFFFFFFFFFFFF))
    assert_equal(
        float_quotient_order_bits_f64(_f64(NAN_NEG_64)),
        UInt64(0x7FF8000000000000) | (UInt64(1) << 63),
    )
    assert_equal(float_quotient_order_bits_f32(0.0), UInt32(1) << 31)
    assert_equal(float_quotient_order_bits_f32(_f32(NEG_ZERO_32)), UInt32(1) << 31)
    assert_equal(float_quotient_order_bits_f32(_f32(NEG_INF_32)), UInt32(0x007FFFFF))
    assert_equal(
        float_quotient_order_bits_f32(_f32(NAN_NEG_32)),
        UInt32(0x7FC00000) | (UInt32(1) << 31),
    )
    # The signed key is the unsigned image with its top bit flipped.
    assert_equal(float_quotient_order_key_f64(0.0), Int64(0))
    assert_equal(float_quotient_order_key_f64(1.0), Int64(0x3FF0000000000000))
    assert_true(float_quotient_order_key_f64(-1.0) < Int64(0))


# -----------------------------------------------------------------------------
# MIN / MAX seeds and folds
# -----------------------------------------------------------------------------


def test_identities() raises:
    assert_equal(_b64(float_min_identity_f64()), CANONICAL_NAN_BITS_F64)
    assert_equal(FLOAT_MIN_SEED_BITS_F64, CANONICAL_NAN_BITS_F64)
    assert_equal(_b64(float_max_identity_f64()), NEG_INF_64)
    assert_equal(FLOAT_MAX_SEED_BITS_F64, NEG_INF_64)
    # Each seed is the identity of its fold for every value of the set.
    var vals = List[Float64]()
    var ranks = List[Int]()
    _ranked_f64(vals, ranks)
    for i in range(len(vals)):
        var v = vals[i]
        assert_true(
            float_quotient_eq_f64(float_min_fold_f64(float_min_identity_f64(), v), v),
            String("min seed is identity for value ") + String(i),
        )
        assert_true(
            float_quotient_eq_f64(float_max_fold_f64(float_max_identity_f64(), v), v),
            String("max seed is identity for value ") + String(i),
        )


def _min_of(xs: List[Float64]) -> Float64:
    var acc = float_min_identity_f64()
    for x in xs:
        acc = float_min_fold_f64(acc, x)
    return acc


def _max_of(xs: List[Float64]) -> Float64:
    var acc = float_max_identity_f64()
    for x in xs:
        acc = float_max_fold_f64(acc, x)
    return acc


def test_folds_follow_sql_min_max() raises:
    var nan = _f64(NAN_PAYLOAD_64)
    var with_nan: List[Float64] = [3.0, nan, -1.0, 2.0]
    assert_equal(_min_of(with_nan), -1.0)
    var m = _max_of(with_nan)
    assert_true(m != m, "MAX over a list holding NaN is NaN")
    var plain: List[Float64] = [3.0, -7.5, 2.0]
    assert_equal(_min_of(plain), -7.5)
    assert_equal(_max_of(plain), 3.0)
    var only_nan: List[Float64] = [nan, _f64(NAN_NEG_64)]
    var mn = _min_of(only_nan)
    assert_true(mn != mn, "MIN over NaNs only is NaN")
    var zeros: List[Float64] = [_f64(NEG_ZERO_64), 0.0]
    assert_equal(_min_of(zeros), 0.0)
    assert_equal(_max_of(zeros), 0.0)
    var infs: List[Float64] = [_f64(POS_INF_64), _f64(NEG_INF_64)]
    assert_equal(_b64(_min_of(infs)), NEG_INF_64)
    assert_equal(_b64(_max_of(infs)), POS_INF_64)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
