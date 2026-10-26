# =============================================================================
# test_cosine.mojo -- the cosine score of two vectors.
# =============================================================================
#
#   identities  equal vectors score 1.0 (and never above it: the quotient for
#               [1,1,1] rounds to 1.0000000000000002 before the clamp), opposite vectors -1.0, orthogonal
#               vectors 0.0; scaling a vector does not change the score.
#   zero        a zero vector, an empty vector and a pair of them score exactly
#               0.0, and the score is never NaN.
#   non-finite  a NaN or infinite component, and squares that overflow f64, score
#               0.0 rather than NaN.
#   width       the SIMD body and the scalar tail agree with a plain scalar
#               reference for every length 1 to 40 and for 1536 (the default
#               dimension), 1537 and 1535.
#   prefix      vectors of different lengths are compared over the shorter one.
# No test reads a clock or the environment.
# =============================================================================

from std.math import inf, nan, sqrt
from std.testing import TestSuite, assert_equal, assert_true

from komira_kg_format import DEFAULT_EMBEDDING_DIM, cosine


def _ramp(n: Int, seed: Int) -> List[Float64]:
    """A deterministic non-trivial vector: no two components alike, mixed sign."""
    var v = List[Float64](capacity=n)
    for i in range(n):
        var x = Float64((i * 7 + seed * 13) % 23) - 11.0
        v.append(x * 0.37 + Float64(i % 5) * 0.11 + 0.05)
    return v^


def _reference(a: List[Float64], b: List[Float64]) -> Float64:
    var dot = 0.0
    var na = 0.0
    var nb = 0.0
    for i in range(min(len(a), len(b))):
        dot += a[i] * b[i]
        na += a[i] * a[i]
        nb += b[i] * b[i]
    return dot / (sqrt(na) * sqrt(nb))


def test_equal_vectors_score_one() raises:
    var a: List[Float64] = [0.3, -1.5, 2.0, 0.0, 7.25]
    var s = cosine(a, a)
    assert_true(s <= 1.0 and 1.0 - s < 1.0e-15)
    var unit: List[Float64] = [0.0, 1.0, 0.0]
    assert_equal(cosine(unit, unit), 1.0)


def test_equal_vectors_never_exceed_one() raises:
    # sqrt(3) * sqrt(3) rounds to 2.9999999999999996, so 3 / that is above 1.
    var a: List[Float64] = [1.0, 1.0, 1.0]
    assert_equal(cosine(a, a), 1.0)
    var b: List[Float64] = [1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
    assert_true(cosine(b, b) <= 1.0, "seven ones")
    for n in range(1, 60):
        var v = _ramp(n, n)
        var s = cosine(v, v)
        assert_true(s <= 1.0 and s >= 0.999999999, "length " + String(n))


def test_opposite_vectors_score_minus_one() raises:
    var a: List[Float64] = [1.0, 1.0, 1.0]
    var b: List[Float64] = [-1.0, -1.0, -1.0]
    assert_equal(cosine(a, b), -1.0)


def test_orthogonal_vectors_score_zero() raises:
    var a: List[Float64] = [1.0, 0.0, 0.0, 0.0]
    var b: List[Float64] = [0.0, 1.0, 0.0, 0.0]
    assert_equal(cosine(a, b), 0.0)
    var c: List[Float64] = [1.0, 1.0]
    var d: List[Float64] = [1.0, -1.0]
    assert_equal(cosine(c, d), 0.0)


def test_scale_does_not_change_the_score() raises:
    var a: List[Float64] = [1.0, 2.0, 3.0, 4.0, 5.0]
    var b: List[Float64] = [5.0, 4.0, 3.0, 2.0, 1.0]
    var scaled = List[Float64]()
    for i in range(len(a)):
        scaled.append(a[i] * 1000.0)
    assert_true(abs(cosine(a, b) - cosine(scaled, b)) < 1.0e-12)
    # 35 / 55 by hand: dot = 5+8+9+8+5, each norm squared = 55.
    assert_true(abs(cosine(a, b) - 35.0 / 55.0) < 1.0e-12)


def test_zero_vector_scores_zero() raises:
    var z: List[Float64] = [0.0, 0.0, 0.0, 0.0]
    var a: List[Float64] = [1.0, 2.0, 3.0, 4.0]
    assert_equal(cosine(z, a), 0.0)
    assert_equal(cosine(a, z), 0.0)
    assert_equal(cosine(z, z), 0.0)


def test_empty_vector_scores_zero() raises:
    var e = List[Float64]()
    var a: List[Float64] = [1.0, 2.0]
    assert_equal(cosine(e, a), 0.0)
    assert_equal(cosine(a, e), 0.0)
    assert_equal(cosine(e, e), 0.0)


def test_nan_and_infinity_score_zero() raises:
    var a: List[Float64] = [1.0, 2.0, 3.0]
    var with_nan: List[Float64] = [1.0, nan[DType.float64](), 3.0]
    var with_inf: List[Float64] = [1.0, inf[DType.float64](), 3.0]
    var s_nan = cosine(a, with_nan)
    var s_inf = cosine(a, with_inf)
    assert_true(s_nan == s_nan, "a NaN component does not leak a NaN")
    assert_equal(s_nan, 0.0)
    assert_equal(s_inf, 0.0)
    assert_equal(cosine(with_nan, with_nan), 0.0)


def test_overflowing_squares_score_zero() raises:
    var big: List[Float64] = [1.0e200, 1.0e200]
    var s = cosine(big, big)
    assert_true(s == s, "overflow does not leak a NaN")
    assert_equal(s, 0.0)


def test_simd_body_and_tail_match_the_scalar_reference() raises:
    for n in range(1, 41):
        var a = _ramp(n, 1)
        var b = _ramp(n, 2)
        assert_true(
            abs(cosine(a, b) - _reference(a, b)) < 1.0e-12,
            "length " + String(n),
        )


def test_default_dimension_and_neighbours() raises:
    var dims: List[Int] = [
        DEFAULT_EMBEDDING_DIM - 1,
        DEFAULT_EMBEDDING_DIM,
        DEFAULT_EMBEDDING_DIM + 1,
    ]
    for d in range(len(dims)):
        var a = _ramp(dims[d], 3)
        var b = _ramp(dims[d], 4)
        assert_true(
            abs(cosine(a, b) - _reference(a, b)) < 1.0e-12,
            "dimension " + String(dims[d]),
        )


def test_different_lengths_compare_the_shared_prefix() raises:
    var a: List[Float64] = [1.0, 0.0, 9.0, 9.0]
    var b: List[Float64] = [1.0, 0.0]
    assert_equal(cosine(a, b), 1.0)
    assert_equal(cosine(b, a), 1.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
