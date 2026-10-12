# =============================================================================
# Float keys sort in DuckDB's total order: NaN above +inf
# =============================================================================
#
# DuckDB orders a DOUBLE column with every NaN greater than +inf and all NaNs
# equal, so `ORDER BY x` ends `+inf, NaN` and `ORDER BY x DESC` starts with
# the NaNs. The engine must return the same rows in the same order.
#
# The oracle here is independent of the kernels: each value maps to a rank
# pair (0, v) for a number and (1, 0) for NaN, and a plain stable insertion
# sort over those pairs gives the expected permutation (stable, so equal keys
# keep input order). The kernels are checked against it for:
#   * the merge sort (inputs above the 32-row insertion threshold, so both
#     the insertion and the merge paths run), ASC and DESC;
#   * the top-K heap, ASC and DESC, with the cut inside the NaN block;
#   * -0.0 and +0.0 comparing equal (input order kept).
#
# Defect it catches: comparing floats with the bare IEEE `<`. NaN is then
# neither less nor greater than anything, the merge sort's comparisons are
# not transitive, and the permutation is not sorted (NaNs strand in the
# middle; the top-K heap never admits a NaN on DESC). Planted mutant:
# `sort_key_lt` reduced to `return a < b` turns every test below red.
#
# Also: `gather_by_indices_*` refuses an index outside the data instead of
# reading past the buffer.
# =============================================================================

from std.math import inf, isnan
from std.testing import TestSuite, assert_equal, assert_true, assert_raises

from komira_arrow.primitive_array import PrimitiveArray
from komira_op_sort.sort import (
    gather_by_indices_float64,
    gather_by_indices_int64,
    sort_indices_float64,
    sort_key_lt,
)
from komira_op_sort.sort_topn import topn_indices_float64


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _oracle_before(a: Float64, b: Float64, descending: Bool) -> Bool:
    """Reference order, written without `sort_key_lt`."""
    var ra = 1 if isnan(a) else 0
    var rb = 1 if isnan(b) else 0
    var lt: Bool
    var gt: Bool
    if ra != rb:
        lt = ra < rb
        gt = ra > rb
    elif ra == 1:
        lt = False
        gt = False
    else:
        lt = a < b
        gt = a > b
    return gt if descending else lt


def _oracle_perm(vals: List[Float64], descending: Bool) -> List[Int]:
    var perm = List[Int]()
    for i in range(len(vals)):
        perm.append(i)
    for i in range(1, len(perm)):
        var cur = perm[i]
        var j = i
        while j > 0 and _oracle_before(vals[cur], vals[perm[j - 1]], descending):
            perm[j] = perm[j - 1]
            j -= 1
        perm[j] = cur
    return perm^


def _mixed_values(n: Int) -> List[Float64]:
    """`n` values: numbers from an LCG, with NaN, +inf, -inf, 0.0 and -0.0
    sprinkled in at fixed positions."""
    var out = List[Float64]()
    var s = UInt64(0x9E3779B97F4A7C15)
    for i in range(n):
        s = s * 6364136223846793005 + 1442695040888963407
        var v = Float64(Int((s >> 33) % 2001)) - 1000.0
        if i % 7 == 3:
            v = _nan()
        elif i % 11 == 5:
            v = inf[DType.float64]()
        elif i % 13 == 6:
            v = -inf[DType.float64]()
        elif i % 17 == 8:
            v = -0.0
        out.append(v)
    return out^


def _assert_perm(
    got: PrimitiveArray[DType.int32], expect: List[Int], label: String
) raises:
    assert_equal(got.length, len(expect), label + ": length")
    for i in range(len(expect)):
        if Int(got.get(i)) != expect[i]:
            raise Error(
                label + ": position " + String(i) + " holds row "
                + String(Int(got.get(i))) + ", expected row "
                + String(expect[i])
            )


def test_merge_sort_nan_last_ascending() raises:
    var vals = _mixed_values(200)
    var got = sort_indices_float64(PrimitiveArray[DType.float64].from_list(vals))
    _assert_perm(got, _oracle_perm(vals, False), "ASC")
    # And the plain reading of it: the last rows are the NaNs.
    assert_true(isnan(vals[Int(got.get(199))]))
    assert_true(not isnan(vals[Int(got.get(0))]))


def test_merge_sort_nan_first_descending() raises:
    var vals = _mixed_values(200)
    var got = sort_indices_float64(
        PrimitiveArray[DType.float64].from_list(vals), descending=True
    )
    _assert_perm(got, _oracle_perm(vals, True), "DESC")
    assert_true(isnan(vals[Int(got.get(0))]))


def test_insertion_path_small_input() raises:
    # Five rows: below the insertion threshold, so only that path runs.
    var vals: List[Float64] = [
        _nan(), 2.0, inf[DType.float64](), -1.0, _nan()
    ]
    var asc = sort_indices_float64(PrimitiveArray[DType.float64].from_list(vals))
    _assert_perm(asc, [3, 1, 2, 0, 4], "small ASC")
    var desc = sort_indices_float64(
        PrimitiveArray[DType.float64].from_list(vals), descending=True
    )
    _assert_perm(desc, [0, 4, 2, 1, 3], "small DESC")


def test_signed_zeros_compare_equal() raises:
    var vals: List[Float64] = [0.0, -0.0, 0.0, -0.0]
    var got = sort_indices_float64(PrimitiveArray[DType.float64].from_list(vals))
    _assert_perm(got, [0, 1, 2, 3], "zeros keep input order")
    assert_true(not sort_key_lt(Float64(-0.0), Float64(0.0)))


def test_topn_descending_takes_nans_first() raises:
    var vals = _mixed_values(300)
    var expect_all = _oracle_perm(vals, True)
    var got = topn_indices_float64(
        PrimitiveArray[DType.float64].from_list(vals), 10, descending=True
    )
    assert_equal(got.length, 10)
    # 300 rows hold 43 NaNs (i % 7 == 3), so the top 10 are all NaN. Which
    # NaNs survive the cut is the heap's choice (ties); that they are NaN is
    # not.
    for i in range(10):
        assert_true(isnan(vals[Int(got.get(i))]), "DESC top-10 row is NaN")
    # Cut below the NaN block: the rows after the NaNs are +inf.
    var got50 = topn_indices_float64(
        PrimitiveArray[DType.float64].from_list(vals), 50, descending=True
    )
    for i in range(50):
        var want = vals[expect_all[i]]
        var have = vals[Int(got50.get(i))]
        assert_true(
            (isnan(want) and isnan(have)) or want == have,
            "DESC top-50 key at " + String(i),
        )


def test_topn_ascending_never_takes_nan() raises:
    var vals = _mixed_values(300)
    var expect_all = _oracle_perm(vals, False)
    var got = topn_indices_float64(
        PrimitiveArray[DType.float64].from_list(vals), 20
    )
    assert_equal(got.length, 20)
    for i in range(20):
        assert_equal(vals[Int(got.get(i))], vals[expect_all[i]])


def test_gather_refuses_out_of_range_index() raises:
    var data = PrimitiveArray[DType.int64].from_list([Int64(1), 2, 3])
    var idx = PrimitiveArray[DType.int32].from_list([Int32(0), 3])
    with assert_raises(contains="outside [0, 3)"):
        _ = gather_by_indices_int64(data, idx)
    var fdata = PrimitiveArray[DType.float64].from_list([1.0, 2.0])
    var neg = PrimitiveArray[DType.int32].from_list([Int32(-1)])
    with assert_raises(contains="outside [0, 2)"):
        _ = gather_by_indices_float64(fdata, neg)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
