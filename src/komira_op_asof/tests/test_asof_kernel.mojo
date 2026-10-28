# =============================================================================
# test_asof_kernel -- the ASOF search kernels (komira_op_asof.asof_kernel)
# =============================================================================
#
# The bounds with and without a hint, `_find_best_asof` for every strategy on
# INT32, INT64 and FLOAT64, the tolerance (inclusive), the NEAREST tie rule,
# and the float order and distance (NaN equal to NaN and above +inf, NaN never
# nearer than a number) and the INT64 distance past Int64's range.
# =============================================================================

from std.math import nan
from std.testing import TestSuite, assert_equal, assert_true, assert_false

from komira_plan_ir.logical_plan import (
    AsofTolerance,
    ASOF_BACKWARD,
    ASOF_FORWARD,
    ASOF_NEAREST,
)
from komira_op_asof.asof_kernel import (
    AsofValue,
    ASOF_VAL_INT32,
    ASOF_VAL_INT64,
    ASOF_VAL_FLOAT64,
    equi_keys_equal_int64,
    _partition_point,
    _partition_point_with_hint,
    _find_best_asof,
)


# =============================================================================
# Helpers -- a List of typed values from a list literal
# =============================================================================


def _arr_i32(vs: List[Int]) -> List[Scalar[DType.int32]]:
    var a = List[Scalar[DType.int32]]()
    for i in range(len(vs)):
        a.append(Scalar[DType.int32](vs[i]))
    return a^


def _arr_i64(vs: List[Int]) -> List[Int64]:
    var a = List[Int64]()
    for i in range(len(vs)):
        a.append(Int64(vs[i]))
    return a^


def _arr_f64(vs: List[Float64]) -> List[Float64]:
    return vs.copy()


# =============================================================================
# AsofValue -- basic construction + abs_diff_f64 per tag
# =============================================================================


def test_asof_value_int32_abs_diff() raises:
    var a = AsofValue.int32(Int32(7))
    var b = AsofValue.int32(Int32(3))
    assert_equal(a.tag, ASOF_VAL_INT32, "int32 tag")
    assert_equal(Int(a.abs_diff_f64(b)), 4, "|7 - 3| = 4")
    assert_equal(Int(b.abs_diff_f64(a)), 4, "|3 - 7| = 4 (symmetric)")


def test_asof_value_int64_abs_diff() raises:
    var a = AsofValue.int64(Int64(1_000_000))
    var b = AsofValue.int64(Int64(999_900))
    assert_equal(a.tag, ASOF_VAL_INT64, "int64 tag")
    assert_equal(Int(a.abs_diff_f64(b)), 100, "|1e6 - 999_900| = 100")


def test_asof_value_float64_abs_diff() raises:
    var a = AsofValue.float64(Float64(1.5))
    var b = AsofValue.float64(Float64(0.25))
    assert_equal(a.tag, ASOF_VAL_FLOAT64, "float64 tag")
    # 1.25 within tiny epsilon
    var d = a.abs_diff_f64(b)
    assert_true(d > Float64(1.24) and d < Float64(1.26), "|1.5 - 0.25| ~ 1.25")


# =============================================================================
# equi_keys_equal_int64 -- single-column primitive
# =============================================================================


def test_equi_keys_equal_int64_basic() raises:
    var left = _arr_i64([1, 2, 3, 2])
    var right = _arr_i64([9, 2, 5])
    assert_true(
        equi_keys_equal_int64(left, 1, right, 1),
        "left[1]=2 == right[1]=2",
    )
    assert_false(
        equi_keys_equal_int64(left, 0, right, 0),
        "left[0]=1 != right[0]=9",
    )
    assert_true(
        equi_keys_equal_int64(left, 3, right, 1),
        "left[3]=2 == right[1]=2",
    )
    _ = left^
    _ = right^


# =============================================================================
# _partition_point (no hint) -- exhaustive on small ascending runs
# =============================================================================


def test_partition_point_empty() raises:
    var a = _arr_i64(List[Int]())
    assert_equal(
        _partition_point[DType.int64](a, 0, Int64(5)), 0,
        "empty -> 0",
    )
    _ = a^


def test_partition_point_basic_int64() raises:
    # Array: [1, 3, 5, 7, 9]
    var a = _arr_i64([1, 3, 5, 7, 9])
    ref p = a
    # target < min -> 0
    assert_equal(_partition_point[DType.int64](p, 5, Int64(0)), 0, "< min")
    # target == element -> index of FIRST strictly greater = index of that elem + 1
    assert_equal(_partition_point[DType.int64](p, 5, Int64(5)), 3, "= 5 -> 3")
    # target between elements
    assert_equal(_partition_point[DType.int64](p, 5, Int64(6)), 3, "= 6 -> 3")
    # target > max -> len
    assert_equal(_partition_point[DType.int64](p, 5, Int64(100)), 5, "> max")
    # target == min
    assert_equal(_partition_point[DType.int64](p, 5, Int64(1)), 1, "= min")
    _ = a^


def test_partition_point_with_duplicates() raises:
    # Array: [2, 2, 2, 5, 5]
    var a = _arr_i64([2, 2, 2, 5, 5])
    ref p = a
    # partition_point(2) -> first index > 2 = 3
    assert_equal(_partition_point[DType.int64](p, 5, Int64(2)), 3, "dup 2 -> 3")
    # partition_point(5) -> first index > 5 = 5
    assert_equal(_partition_point[DType.int64](p, 5, Int64(5)), 5, "dup 5 -> 5")
    # partition_point(3) -> first index > 3 = 3
    assert_equal(_partition_point[DType.int64](p, 5, Int64(3)), 3, "gap -> 3")
    _ = a^


# =============================================================================
# _partition_point_with_hint -- must match _partition_point for any hint
# =============================================================================


def test_partition_point_hint_agrees_with_no_hint() raises:
    # Check that every (target, hint) pair gives the same answer as the
    # hint-less form. This is the hint invariant the kernel relies on.
    var a = _arr_i64([1, 3, 5, 7, 9, 11, 13])
    ref p = a
    var n = 7
    var targets = [-5, 0, 1, 2, 5, 6, 13, 14, 100]
    for ti in range(len(targets)):
        var t = Int64(targets[ti])
        var gold = _partition_point[DType.int64](p, n, t)
        # Try every hint including boundaries and out-of-range.
        for h in range(-2, n + 3):
            var got = _partition_point_with_hint[DType.int64](p, n, t, h)
            assert_equal(got, gold,
                "hint=" + String(h) + " target=" + String(Int(t)))
    _ = a^


# =============================================================================
# _find_best_asof -- BACKWARD on all 3 dtypes
# =============================================================================


def test_find_best_backward_int64_basic() raises:
    # right group ts: [10, 20, 30, 40]
    var a = _arr_i64([10, 20, 30, 40])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0

    # left_ts = 25 -> backward = 20 (idx 1)
    _find_best_asof[ASOF_BACKWARD, DType.int64](
        Int64(25), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, 1, "backward 25 -> idx 1 (ts=20)")

    # left_ts = 40 (exact match on last) -> idx 3
    _find_best_asof[ASOF_BACKWARD, DType.int64](
        Int64(40), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, 3, "backward 40 -> idx 3 (ts=40)")

    # left_ts = 9 -> no match (below range)
    lo_hint = 0
    _find_best_asof[ASOF_BACKWARD, DType.int64](
        Int64(9), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, -1, "backward 9 -> -1 (below range)")

    # left_ts = 100 -> last idx 3
    lo_hint = 0
    _find_best_asof[ASOF_BACKWARD, DType.int64](
        Int64(100), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, 3, "backward 100 -> idx 3 (last)")
    _ = a^


def test_find_best_backward_int32() raises:
    var a = _arr_i32([100, 200, 300])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_BACKWARD, DType.int32](
        Scalar[DType.int32](250), p, 3, tol, lo_hint, best,
    )
    assert_equal(best, 1, "backward i32 250 -> idx 1 (200)")
    _ = a^


def test_find_best_backward_float64() raises:
    var a = _arr_f64([1.0, 2.5, 3.5, 5.0])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_BACKWARD, DType.float64](
        Scalar[DType.float64](3.0), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, 1, "backward f64 3.0 -> idx 1 (2.5)")
    _ = a^


# =============================================================================
# _find_best_asof -- FORWARD on all 3 dtypes
# =============================================================================


def test_find_best_forward_int64_basic() raises:
    # right group ts: [10, 20, 30, 40]
    var a = _arr_i64([10, 20, 30, 40])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0

    # left_ts = 25 -> forward = 30 (idx 2)
    _find_best_asof[ASOF_FORWARD, DType.int64](
        Int64(25), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, 2, "forward 25 -> idx 2 (ts=30)")

    # left_ts = 20 (exact) -> idx 1
    lo_hint = 0
    _find_best_asof[ASOF_FORWARD, DType.int64](
        Int64(20), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, 1, "forward 20 -> idx 1 (ts=20)")

    # left_ts = 5 (below) -> first (idx 0)
    lo_hint = 0
    _find_best_asof[ASOF_FORWARD, DType.int64](
        Int64(5), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, 0, "forward 5 -> idx 0 (ts=10)")

    # left_ts = 50 (above max) -> -1
    lo_hint = 0
    _find_best_asof[ASOF_FORWARD, DType.int64](
        Int64(50), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, -1, "forward 50 -> -1")
    _ = a^


def test_find_best_forward_multi_right_same_ts() raises:
    # Right group: [20, 20, 20, 30]. FORWARD @ 20 -> first 20 = idx 0.
    # FORWARD picks the first value at or after (DuckDB `left.t <= right.t`).
    var a = _arr_i64([20, 20, 20, 30])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_FORWARD, DType.int64](
        Int64(20), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, 0, "forward @ duplicated 20 -> first (idx 0)")
    _ = a^


def test_find_best_backward_multi_right_same_ts() raises:
    # Right group: [20, 20, 20, 30]. BACKWARD @ 20 -> last 20 = idx 2.
    var a = _arr_i64([20, 20, 20, 30])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_BACKWARD, DType.int64](
        Int64(20), p, 4, tol, lo_hint, best,
    )
    assert_equal(best, 2, "backward @ duplicated 20 -> last (idx 2)")
    _ = a^


def test_find_best_forward_float64() raises:
    var a = _arr_f64([0.5, 1.5, 2.5])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_FORWARD, DType.float64](
        Scalar[DType.float64](1.0), p, 3, tol, lo_hint, best,
    )
    assert_equal(best, 1, "forward f64 1.0 -> idx 1 (1.5)")
    _ = a^


# =============================================================================
# _find_best_asof -- NEAREST incl. tie rule
# =============================================================================


def test_find_best_nearest_int64_prefers_closer() raises:
    # Group: [10, 20]. left = 12 -> |12-10|=2 < |20-12|=8 -> idx 0.
    var a = _arr_i64([10, 20])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_NEAREST, DType.int64](
        Int64(12), p, 2, tol, lo_hint, best,
    )
    assert_equal(best, 0, "nearest 12 -> idx 0")

    # left = 18 -> |18-10|=8 > |20-18|=2 -> idx 1.
    lo_hint = 0
    _find_best_asof[ASOF_NEAREST, DType.int64](
        Int64(18), p, 2, tol, lo_hint, best,
    )
    assert_equal(best, 1, "nearest 18 -> idx 1")
    _ = a^


def test_find_best_nearest_tie_prefers_backward() raises:
    # Group: [10, 20]. left = 15 -> both diffs = 5 -> tie -> BACKWARD wins
    # (the engine's NEAREST rule).
    var a = _arr_i64([10, 20])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_NEAREST, DType.int64](
        Int64(15), p, 2, tol, lo_hint, best,
    )
    assert_equal(best, 0, "nearest tie 15 -> idx 0 (backward wins)")
    _ = a^


def test_find_best_nearest_below_range() raises:
    # left < min -> only forward candidate (idx 0).
    var a = _arr_i64([10, 20, 30])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_NEAREST, DType.int64](
        Int64(5), p, 3, tol, lo_hint, best,
    )
    assert_equal(best, 0, "nearest below -> idx 0")
    _ = a^


def test_find_best_nearest_above_range() raises:
    # left > max -> only backward candidate (last).
    var a = _arr_i64([10, 20, 30])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_NEAREST, DType.int64](
        Int64(50), p, 3, tol, lo_hint, best,
    )
    assert_equal(best, 2, "nearest above -> idx 2")
    _ = a^


def test_find_best_nearest_int32() raises:
    var a = _arr_i32([100, 200])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    # left = 120 -> |120-100|=20 < |200-120|=80 -> idx 0.
    _find_best_asof[ASOF_NEAREST, DType.int32](
        Scalar[DType.int32](120), p, 2, tol, lo_hint, best,
    )
    assert_equal(best, 0, "nearest i32 -> idx 0")
    _ = a^


def test_find_best_nearest_float64() raises:
    var a = _arr_f64([1.0, 3.0])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0
    # left = 2.0 -> tie (1.0 and 1.0) -> backward wins -> idx 0.
    _find_best_asof[ASOF_NEAREST, DType.float64](
        Scalar[DType.float64](2.0), p, 2, tol, lo_hint, best,
    )
    assert_equal(best, 0, "nearest f64 tie -> idx 0")

    # left = 2.1 -> closer to 3.0 (0.9 < 1.1) -> idx 1.
    lo_hint = 0
    _find_best_asof[ASOF_NEAREST, DType.float64](
        Scalar[DType.float64](2.1), p, 2, tol, lo_hint, best,
    )
    assert_equal(best, 1, "nearest f64 2.1 -> idx 1 (3.0)")
    _ = a^


# =============================================================================
# Tolerance -- inclusive <= tol matches; > tol rejects
# =============================================================================


def test_backward_tolerance_inclusive_boundary() raises:
    # Group: [10, 20, 30]. left = 25, tol = 5 -> |25-20|=5 == tol -> match.
    var a = _arr_i64([10, 20, 30])
    ref p = a
    var lo_hint = 0
    var best = 0
    var tol5 = AsofTolerance.int64(Int64(5))
    _find_best_asof[ASOF_BACKWARD, DType.int64](
        Int64(25), p, 3, tol5, lo_hint, best,
    )
    assert_equal(best, 1, "backward 25 tol=5 boundary -> idx 1")
    # left = 26, tol = 5 -> |26-20|=6 > 5 -> reject.
    lo_hint = 0
    _find_best_asof[ASOF_BACKWARD, DType.int64](
        Int64(26), p, 3, tol5, lo_hint, best,
    )
    assert_equal(best, -1, "backward 26 tol=5 -> reject")
    _ = a^


def test_forward_tolerance_rejects_when_exceeds() raises:
    var a = _arr_i64([10, 100])
    ref p = a
    var lo_hint = 0
    var best = 0
    var tol10 = AsofTolerance.int64(Int64(10))
    # left = 50 -> forward = 100, |100-50|=50 > 10 -> reject.
    _find_best_asof[ASOF_FORWARD, DType.int64](
        Int64(50), p, 2, tol10, lo_hint, best,
    )
    assert_equal(best, -1, "forward 50 tol=10 -> reject")
    _ = a^


def test_nearest_tolerance_float64() raises:
    var a = _arr_f64([0.0, 10.0])
    ref p = a
    var lo_hint = 0
    var best = 0
    var tol_half = AsofTolerance.float64(Float64(0.5))
    # left = 0.25 -> nearest = 0.0, diff = 0.25 < 0.5 -> idx 0.
    _find_best_asof[ASOF_NEAREST, DType.float64](
        Scalar[DType.float64](0.25), p, 2, tol_half, lo_hint, best,
    )
    assert_equal(best, 0, "nearest f64 0.25 tol=0.5 -> idx 0")
    # left = 5.0 -> nearest tie, backward = 0.0, |5.0-0.0|=5.0 > 0.5 -> reject.
    lo_hint = 0
    _find_best_asof[ASOF_NEAREST, DType.float64](
        Scalar[DType.float64](5.0), p, 2, tol_half, lo_hint, best,
    )
    assert_equal(best, -1, "nearest f64 5.0 tol=0.5 -> reject")
    _ = a^


# =============================================================================
# Hint monotonicity -- walking left_ts ascending within a group
# =============================================================================


def test_backward_hint_walk_matches_no_hint() raises:
    """Walking a monotonically increasing sequence of left_ts with the
    hint carried across calls must give identical results to calling
    with hint=0 each time (the hint contract)."""
    var a = _arr_i64([5, 10, 15, 20, 25, 30, 35, 40, 45, 50])
    ref p = a
    var tol = AsofTolerance.none()
    var n = 10
    var left_ts_seq = [4, 5, 12, 12, 20, 25, 26, 30, 48, 60]

    var hint_walk = 0
    for i in range(len(left_ts_seq)):
        var t = Int64(left_ts_seq[i])
        var hot = hint_walk
        var hinted = 0
        _find_best_asof[ASOF_BACKWARD, DType.int64](
            t, p, n, tol, hot, hinted,
        )
        hint_walk = hot
        var cold = 0
        var cold_ignored = 0
        _find_best_asof[ASOF_BACKWARD, DType.int64](
            t, p, n, tol, cold_ignored, cold,
        )
        assert_equal(hinted, cold,
            "hint-walk @ t=" + String(left_ts_seq[i]) + " agrees with cold")
    _ = a^


# =============================================================================
# Empty group -- -1 regardless of strategy
# =============================================================================


def test_find_best_empty_group_int64() raises:
    # right_group_len = 0 -> -1 for all strategies.
    var a = _arr_i64([1])
    ref p = a
    var tol = AsofTolerance.none()
    var lo_hint = 0
    var best = 0

    _find_best_asof[ASOF_BACKWARD, DType.int64](Int64(5), p, 0, tol, lo_hint, best)
    assert_equal(best, -1, "empty BACKWARD -> -1")
    _find_best_asof[ASOF_FORWARD, DType.int64](Int64(5), p, 0, tol, lo_hint, best)
    assert_equal(best, -1, "empty FORWARD -> -1")
    _find_best_asof[ASOF_NEAREST, DType.int64](Int64(5), p, 0, tol, lo_hint, best)
    assert_equal(best, -1, "empty NEAREST -> -1")
    _ = a^


# =============================================================================
# The float order (DuckDB's): NaN equals NaN and sorts above +inf
# =============================================================================
#
# The right group arrives sorted by `sort_key_lt`, so a NaN sits at its end.
# A kernel comparing with the IEEE operators sees `NaN <= NaN` as false and
# loses the NaN rows DuckDB matches.


def test_float_nan_probe_backward_matches_nan() raises:
    """DuckDB `left.t >= right.t` with left NaN: every right value qualifies
    (NaN is the largest) and the last, the NaN, is the match."""
    var a = _arr_f64([1.0, nan[DType.float64]()])
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_BACKWARD, DType.float64](
        nan[DType.float64](), a, 2, AsofTolerance.none(), lo_hint, best
    )
    assert_equal(best, 1, "BACKWARD NaN -> the NaN row")


def test_float_nan_probe_forward_matches_nan() raises:
    """DuckDB `left.t <= right.t` with left NaN: only a NaN qualifies, not
    1.0 (1.0 >= NaN is false there)."""
    var a = _arr_f64([1.0, nan[DType.float64]()])
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_FORWARD, DType.float64](
        nan[DType.float64](), a, 2, AsofTolerance.none(), lo_hint, best
    )
    assert_equal(best, 1, "FORWARD NaN -> the NaN row, not 1.0")


def test_float_nan_probe_forward_without_nan_misses() raises:
    """No NaN on the right: a NaN probe has nothing at or after it."""
    var a = _arr_f64([1.0, 2.0])
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_FORWARD, DType.float64](
        nan[DType.float64](), a, 2, AsofTolerance.none(), lo_hint, best
    )
    assert_equal(best, -1, "FORWARD NaN over numbers -> no match")


def test_float_forward_reaches_nan_above_numbers() raises:
    """A number's FORWARD match may be a NaN (NaN sorts above +inf)."""
    var a = _arr_f64([1.0, nan[DType.float64]()])
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_FORWARD, DType.float64](
        Float64(5.0), a, 2, AsofTolerance.none(), lo_hint, best
    )
    assert_equal(best, 1, "FORWARD 5.0 -> NaN")


def test_float_negative_zero_equals_zero() raises:
    """-0.0 equals +0.0: an exact match both ways."""
    var a = _arr_f64([-0.0, 1.0])
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_BACKWARD, DType.float64](
        Float64(0.0), a, 2, AsofTolerance.none(), lo_hint, best
    )
    assert_equal(best, 0, "BACKWARD +0.0 -> -0.0")
    lo_hint = 0
    _find_best_asof[ASOF_FORWARD, DType.float64](
        Float64(0.0), a, 2, AsofTolerance.none(), lo_hint, best
    )
    assert_equal(best, 0, "FORWARD +0.0 -> -0.0")


def test_nearest_prefers_number_over_nan() raises:
    """NEAREST of 5.0 between 1.0 and a NaN: the NaN is infinitely far."""
    var a = _arr_f64([1.0, nan[DType.float64]()])
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_NEAREST, DType.float64](
        Float64(5.0), a, 2, AsofTolerance.none(), lo_hint, best
    )
    assert_equal(best, 0, "NEAREST 5.0 -> 1.0, not NaN")


def test_tolerance_rejects_nan_against_number() raises:
    """FORWARD 1.0 reaches a NaN, which no finite tolerance admits."""
    var a = _arr_f64([nan[DType.float64]()])
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_FORWARD, DType.float64](
        Float64(1.0), a, 1, AsofTolerance.float64(Float64(100.0)), lo_hint, best
    )
    assert_equal(best, -1, "NaN is not within 100 of 1.0")


def test_partition_point_with_nan_tail() raises:
    """The upper bound of NaN in [1, 2, NaN, NaN] is the end; of 2.0, the
    first NaN."""
    var a = _arr_f64([1.0, 2.0, nan[DType.float64](), nan[DType.float64]()])
    assert_equal(_partition_point[DType.float64](a, 4, nan[DType.float64]()), 4)
    assert_equal(_partition_point[DType.float64](a, 4, Float64(2.0)), 2)
    for h in range(-1, 6):
        assert_equal(
            _partition_point_with_hint[DType.float64](
                a, 4, nan[DType.float64](), h
            ),
            4,
            "hint " + String(h),
        )


# =============================================================================
# The INT64 distance does not wrap
# =============================================================================


def test_nearest_int64_distance_past_int64_range() raises:
    """NEAREST of 0 between Int64.MIN (distance 2^63) and Int64.MAX - 1
    (distance 2^63 - 2): the second is nearer. A signed difference wraps
    0 - Int64.MIN back to Int64.MIN, a negative distance that wins."""
    var a: List[Int64] = [Int64.MIN, Int64.MAX - 1]
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_NEAREST, DType.int64](
        Int64(0), a, 2, AsofTolerance.none(), lo_hint, best
    )
    assert_equal(best, 1, "NEAREST 0 -> Int64.MAX - 1")


def test_tolerance_int64_distance_past_int64_range() raises:
    """BACKWARD of Int64.MAX reaches Int64.MIN at distance 2^64 - 1, far
    past a tolerance of 10. A signed difference wraps to -1, then 1."""
    var a: List[Int64] = [Int64.MIN]
    var lo_hint = 0
    var best = 0
    _find_best_asof[ASOF_BACKWARD, DType.int64](
        Int64.MAX, a, 1, AsofTolerance.int64(Int64(10)), lo_hint, best
    )
    assert_equal(best, -1, "Int64.MIN is not within 10 of Int64.MAX")


def test_equi_keys_equal_int64_extremes() raises:
    var l: List[Int64] = [Int64.MIN, Int64.MAX]
    var r: List[Int64] = [Int64.MAX, Int64.MIN]
    assert_true(equi_keys_equal_int64(l, 0, r, 1))
    assert_false(equi_keys_equal_int64(l, 0, r, 0))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
