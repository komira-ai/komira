# =============================================================================
# test_percentile_accumulator_nan_total_order — THE FOURTH ORDER-STATISTIC SITE
# =============================================================================
#
# ⚠⚠ THE PREMISE THIS FILE WAS OPENED ON IS FALSE, AND THE CORRECTION MATTERS
#    MORE THAN THE TEST. records `PercentileAccumulator`
#    as carrying "the identical NaN barrier" to `PercentileAcc`. MEASURED
#    2026-09-15 by reading both:
#
#      • `PercentileAcc`          — komira_op_agg_state/columnar_acc_agg.mojo:86
#        EXCLUDES NaN at update (`if v == v:` in `update_batch`, with an
#        explicit `# NaN EXCLUSION` block). Interpolated: `pos = q*(n-1)`,
#        floor, linear interpolation.
#
#      • `PercentileAccumulator`  — komira_op_agg_state/statistical_accumulators.mojo:78
#        ⛔ DOES **NOT** EXCLUDE NaN. `insert` appends unconditionally; there is
#        no `v == v` test anywhere in the struct. And it is NOT the same
#        function: `result()` is NEAREST-RANK (`idx = ceil(p*n) - 1`, clamped)
#        with NO interpolation, so it is a `quantile_disc`, not an
#        interpolated percentile and not DuckDB `quantile_cont`.
#        `percentile(0.5)` of [1,2,3,4] is 2.0 here and 2.5 in DuckDB.
#
#    ⇒ THE TWO STRUCTS SHARE NEITHER THE NaN POLICY NOR THE PERCENTILE
#      DEFINITION. They are not two copies of one kernel; do not "unify" them
#      on the strength of the name.
#
# ⚠ AND `PercentileAccumulator` IS OFF EVERY ROUTE. Measured 2026-09-15: its
#   only occurrence outside its own file and its own tests is a bare re-export
#   in `komira_op_agg_state/aggregate.mojo:25`. Nothing instantiates it.
#   So this file pins a LATENT defect; it does not repair a shipped one.
#
# ---------------------------------------------------------------------------
# WHAT IS ACTUALLY WRONG HERE, AND IT IS A REAL DEFECT
# ---------------------------------------------------------------------------
# `result()` insertion-sorts with the raw predicate `sorted[j] > key`, which is
# FALSE for every comparison involving NaN. So a NaN key never shifts, and a
# NaN that lands at `sorted[0]` stops every later insertion at `j == 0` and
# makes the whole sort a NO-OP. The answer becomes an artifact of INSERTION
# ORDER — the same mechanism, byte for byte, as the two capped AGG_MEDIAN
# finalize bodies fixed alongside this file. It is a bug under ANY percentile
# definition, nearest-rank included.
#
# ⛔ THE FIX HERE DELIBERATELY DOES **NOT** REDEFINE THE FUNCTION. Nearest-rank
#    is asserted on purpose by `komira_sdk/tests/test_display_stats.mojo`
#    ("P25 with nearest-rank: ceil(0.25 * 8) = 2, so index 1 -> value 2"), so
#    switching to interpolation here would be a silent semantic change to a
#    documented contract, not a bug fix. What changes is ONLY that NaN is
#    ORDERED (last, and counted) instead of scrambling the sort. Whether this
#    struct should exist at all — it is OFF the AGG_MEDIAN route and off every
#    plan route, reachable only from `komira_op_agg_state.aggregate` and
#    its own tests — is recorded in
#    an internal doc §5.
#
# THE ORDER: NaN is the LARGEST value (DuckDB's total order), so the sorted
# array is [<k non-NaN ascending>, <n-k NaNs>] and the nearest-rank index is
# taken against the FULL n. Index < k -> that non-NaN value; index >= k -> NaN.
#
# Test cases:
#   P1 — {1,2,3,4,NaN,NaN} @ 0.5: all 720 orderings give 3.0 (idx=2 < k=4).
#   P2 — {1,2,3,4,NaN,NaN} @ 0.9: all 720 orderings give NaN (idx=5 >= k=4).
#   P3 — {1,2,3,NaN} @ 0.5: all 24 orderings give 2.0 (idx=1 < k=3).
#   P4 — all-NaN group -> NaN.
#   P5 — NaN-FREE regression: the four contracts test_display_stats asserts.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_state.statistical_accumulators import (
    PercentileAccumulator,
)


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _is_nan(x: Float64) -> Bool:
    return x != x


def _abs(x: Float64) -> Float64:
    if x < Float64(0.0):
        return -x
    return x


def _close(a: Float64, b: Float64) -> Bool:
    return _abs(a - b) <= Float64(1e-12)


def _next_permutation(mut idx: List[Int]) -> Bool:
    var n = len(idx)
    if n < 2:
        return False
    var i = n - 2
    while i >= 0 and idx[i] >= idx[i + 1]:
        i -= 1
    if i < 0:
        return False
    var j = n - 1
    while idx[j] <= idx[i]:
        j -= 1
    var t = idx[i]
    idx[i] = idx[j]
    idx[j] = t
    var lo = i + 1
    var hi = n - 1
    while lo < hi:
        var tmp = idx[lo]
        idx[lo] = idx[hi]
        idx[hi] = tmp
        lo += 1
        hi -= 1
    return True


def _pct_of(imm vals: List[Float64], p: Float64) raises -> Float64:
    var acc = PercentileAccumulator.create(p)
    for i in range(len(vals)):
        acc.insert(vals[i])
    return acc.result()


def _sweep(
    imm base: List[Float64],
    p: Float64,
    expect_nan: Bool,
    expect: Float64,
    label: String,
) raises:
    var n = len(base)
    var idx = List[Int]()
    for i in range(n):
        idx.append(i)
    var factorial = 1
    for i in range(2, n + 1):
        factorial *= i
    var visited = 0
    while True:
        var v = List[Float64]()
        for i in range(n):
            v.append(base[idx[i]])
        var got = _pct_of(v, p)
        if expect_nan:
            if not _is_nan(got):
                raise Error(
                    String(label) + ": ordering #" + String(visited)
                    + " gave " + String(got) + ", expected NaN"
                )
        else:
            if not _close(got, expect):
                raise Error(
                    String(label) + ": ordering #" + String(visited)
                    + " gave " + String(got) + ", expected " + String(expect)
                    + " (a percentile is a function of the MULTISET, not of"
                    + " insertion order)"
                )
        visited += 1
        if not _next_permutation(idx):
            break
    assert_equal(visited, factorial, String(label) + ": permutation count")


def _four_two_nans() -> List[Float64]:
    var v = List[Float64]()
    v.append(Float64(1.0))
    v.append(Float64(2.0))
    v.append(Float64(3.0))
    v.append(Float64(4.0))
    v.append(_nan())
    v.append(_nan())
    return v^


def test_P1_median_index_inside_the_non_nan_prefix() raises:
    """n=6, p=0.5 -> idx = ceil(3.0) - 1 = 2; k = 4 so 2 < k and the answer is
    the 3rd smallest non-NaN = 3.0, in every one of the 720 orderings."""
    _sweep(_four_two_nans(), Float64(0.5), False, Float64(3.0), "pct@0.5{1,2,3,4,NaN,NaN}")


def test_P2_index_past_the_prefix_is_nan() raises:
    """n=6, p=0.9 -> idx = ceil(5.4) - 1 = 5; k = 4 so 5 >= k and the order
    statistic IS a NaN. Correct, and it must be correct in every ordering."""
    _sweep(_four_two_nans(), Float64(0.9), True, Float64(0.0), "pct@0.9{1,2,3,4,NaN,NaN}")


def test_P3_single_nan_odd_prefix() raises:
    """n=4, p=0.5 -> idx = ceil(2.0) - 1 = 1; k = 3 -> 2nd smallest = 2.0."""
    var v = List[Float64]()
    v.append(Float64(1.0))
    v.append(Float64(2.0))
    v.append(Float64(3.0))
    v.append(_nan())
    _sweep(v, Float64(0.5), False, Float64(2.0), "pct@0.5{1,2,3,NaN}")


def test_P4_all_nan_group_is_nan() raises:
    var v = List[Float64]()
    v.append(_nan())
    v.append(_nan())
    v.append(_nan())
    assert_true(_is_nan(_pct_of(v, Float64(0.5))), "all-NaN -> NaN")


def test_P5_nan_free_contracts_unchanged() raises:
    """The four NaN-free contracts `test_display_stats.mojo` pins. With zero
    NaNs the compaction is the identity, so the nearest-rank answer must be
    bit-identical to before."""
    var a = List[Float64]()
    a.append(Float64(1.0))
    a.append(Float64(2.0))
    a.append(Float64(3.0))
    a.append(Float64(4.0))
    a.append(Float64(5.0))
    assert_true(_close(_pct_of(a, Float64(0.5)), Float64(3.0)), "median[1..5]==3.0")

    var b = List[Float64]()
    for i in range(1, 9):
        b.append(Float64(i))
    assert_true(_close(_pct_of(b, Float64(0.25)), Float64(2.0)), "p25[1..8]==2.0")
    assert_true(_close(_pct_of(b, Float64(0.75)), Float64(6.0)), "p75[1..8]==6.0")
    assert_true(_close(_pct_of(b, Float64(0.0)), Float64(1.0)), "p0[1..8]==1.0")
    assert_true(_close(_pct_of(b, Float64(1.0)), Float64(8.0)), "p100[1..8]==8.0")

    var c = List[Float64]()
    c.append(Float64(42.0))
    assert_true(_close(_pct_of(c, Float64(0.99)), Float64(42.0)), "single value")


def test_P6_nearest_rank_is_not_interpolated() raises:
    """⛔ A PIN ON THE DIVERGENCE, NOT AN ENDORSEMENT OF IT.

    `PercentileAccumulator` is nearest-rank: median[1,2,3,4] == 2.0. DuckDB
    `quantile_cont`/`median` answers 2.5 (the interpolated order statistic,
    which is what `PercentileAcc` computes).
    This assertion exists so that anyone who wires this struct to a
    user-facing PERCENTILE / MEDIAN name trips here first.
    """
    var v = List[Float64]()
    v.append(Float64(1.0))
    v.append(Float64(2.0))
    v.append(Float64(3.0))
    v.append(Float64(4.0))
    assert_true(
        _close(_pct_of(v, Float64(0.5)), Float64(2.0)),
        "nearest-rank median[1,2,3,4] is 2.0 -- DuckDB says 2.5",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
