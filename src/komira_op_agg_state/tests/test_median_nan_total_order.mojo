# =============================================================================
# test_median_nan_total_order — THE TWO CAPPED AGG_MEDIAN FINALIZE BODIES MUST
# BE A FUNCTION OF THE MULTISET, NOT OF ARRIVAL ORDER.
# =============================================================================
#
# ⭐⭐ WHAT THIS TEST EXISTS TO STOP: A WRONG ANSWER THAT CHANGES RUN TO RUN.
#
# ⚠⚠ AND WHAT IT IS **NOT**: A REGRESSION TEST FOR A SHIPPED DEFECT. MEASURED
# 2026-09-15, neither body under test is reachable from any plan route —
# outside their defining files and their own unit tests, every occurrence of
# `MedianAggregator` and `MedianF64` in `src/` is a COMMENT or a docstring.
# The LIVE `AGG_MEDIAN` arms are `agg_extended_grouped._ext_median_inplace` and
# `MedianOp[dt].finalize` (`komira_eval/hash_agg_op_dt.mojo`), both NaN-last
# Now and both covered elsewhere. The campaign brief that opened
# this work said the capped bodies were "a LIVE wrong answer on BOTH doors";
# the MECHANISM was exactly as described, the LIVENESS was not. This file
# pins a LATENT defect so that re-wiring `MedianState` — still the state shape
# `agg_expr.mojo:985` documents as AGG_MEDIAN's semantics — cannot ship it.
#
# `MedianAggregator.finalize` (aggregators_struct_builtin.mojo) and
# `MedianF64.finalize` (agg/agg_state_slab.mojo) are two separate bodies over
# ONE shared `MedianState`, and both insertion-sorted the reservoir with the
# raw predicate `buf[j] > key`. That predicate is FALSE for every comparison
# involving NaN, so:
#
#   • a NaN `key` never shifts anything — it is pinned where it arrived, and
#   • a NaN sitting at buf[0] stops EVERY later insertion at j == 0, which
#     makes the remaining sort a COMPLETE NO-OP.
#
# The returned "median" is then whatever landed on the middle index, i.e. an
# artifact of INSERTION ORDER. MEASURED over the 720 permutations of the
# multiset {1,2,3,4,NaN,NaN} against a byte-faithful model of that loop
# (360 distinct orderings; the two NaNs are indistinguishable, so each answer
# below is doubled in the 720-count):
#
#     NaN  432 (60%)   2.5  88   3.5  80   1.5  80   3.0  20   2.0  20
#
# SIX DISTINCT ANSWERS FOR ONE MULTISET, with the plurality being a NaN that
# the group does not entitle anyone to. In a parallel engine the row order
# within a group is whatever the partition hands over, so this is
# NON-REPRODUCIBLE: the same query over the same file can answer differently
# on two runs of the same binary.
#
# ---------------------------------------------------------------------------
# THE CONTRACT THIS FILE PINS — DuckDB's TOTAL ORDER, NaN LAST AND COUNTED.
# ---------------------------------------------------------------------------
# DuckDB makes NaN self-equal and greater than everything (including +inf), so
# a group's values form a genuine total order with the NaNs at the end, and
# `median` is the ordinary mean-interpolated order statistic under it.
#
# MEASURED `pixi run duckdb` v1.5.3 (Variegata), 2026-09-15 — the oracle rows
# this file asserts:
#
#     median{1,2,3,4,NaN,NaN}  ->  3.5      quantile_cont(...,0.5) -> 3.5
#     median{1,2,3,NaN,NaN}    ->  3.0
#     median{1,2,NaN,NaN}      ->  NaN
#     median{1,2,3,NaN}        ->  2.5
#
# This is ALSO the order the two UNCAPPED medians in this tree already
# implement — `agg_extended_grouped._ext_median_inplace` and the typed
# `MedianOp.finalize`'s `_finalize_nan_last` (`komira_eval/hash_agg_op_dt.mojo`)
# — so the fix this file gates makes FOUR median bodies agree instead of two.
#
# ⛔ WHAT THIS FILE DELIBERATELY DOES **NOT** ASSERT, AND WHY IT IS NOT A
#    WEAKENED ASSERTION: DuckDB parity ABOVE 64 CONTRIBUTING VALUES.
# `MedianState` is a FIXED-capacity 520-byte POD (Int32 count + Int32 pad +
# InlineArray[Float64, 64]) and both bodies drop everything after the first 64
# (FIRST-64 retention). Past 64 the answer is the median of an arbitrary
# 64-row SAMPLE, which no NaN rule can repair — the missing primitive is
# VARIABLE-CAPACITY PER-GROUP STATE IN A POD BYTE-SLAB, the same gap6
# constraint that hardwired `AGG_LARGEST_K`'s K to 2. T20/T21 below therefore
# assert the CAP's behaviour EXACTLY (deterministic truncation) rather than a
# DuckDB number these bodies cannot produce, and say so. Closing it is
# `AGG_PERCENTILE` over the unbounded `PercentileAcc`, which is a different
# slice — see an internal doc.
#
# Test cases:
#   T1  — MedianAggregator: the single NaN-first ordering that returned NaN.
#   T2  — MedianAggregator: ALL 720 permutations of {1,2,3,4,NaN,NaN} == 3.5.
#   T3  — MedianAggregator: ALL 120 permutations of {1,2,3,NaN,NaN}   == 3.0.
#   T4  — MedianAggregator: {1,2,NaN,NaN} -> NaN in every ordering.
#   T5  — MedianAggregator: {1,2,3,NaN} -> 2.5 in every ordering.
#   T6  — MedianAggregator: all-NaN group -> NaN.
#   T7  — MedianAggregator: NaN-FREE groups are byte-unchanged (no regression).
#   T10..T16 — the identical seven over `MedianF64`.
#   T20 — BOTH bodies: 64 contributing values incl. NaN == the DuckDB answer.
#   T21 — BOTH bodies: 65 contributing values — FIRST-64 truncation, asserted
#         as truncation, NOT as parity. This is the documented divergence.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_true

from komira_op_agg_state.aggregators_struct_builtin import (
    MAX_MEDIAN_VALUES,
    MedianAggregator,
    MedianState,
)
from komira_op_agg_state.agg_state_slab import MedianF64


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _is_nan(x: Float64) -> Bool:
    return x != x


def _abs(x: Float64) -> Float64:
    if x < Float64(0.0):
        return -x
    return x


def _approx_equal(a: Float64, b: Float64, tol: Float64 = 1e-12) -> Bool:
    return _abs(a - b) <= tol


def _next_permutation(mut idx: List[Int]) -> Bool:
    """Lexicographic next permutation over `idx`. False when it was the last.

    Standard three-step: find the rightmost ascent `i`, swap `idx[i]` with the
    rightmost element greater than it, reverse the suffix. Over a list that
    starts sorted ascending this enumerates every permutation exactly once,
    which is what makes T2/T3 an EXHAUSTIVE order sweep rather than a sample.
    """
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


def _agg_median_of(imm vals: List[Float64]) -> Float64:
    var s = MedianAggregator.init()
    for i in range(len(vals)):
        MedianAggregator.update(s, Float64(vals[i]))
    return Float64(MedianAggregator.finalize(s))


def _f64_median_of(imm vals: List[Float64]) -> Float64:
    var s = MedianF64.init()
    for i in range(len(vals)):
        MedianF64.update_scalar(s, vals[i])
    return MedianF64.finalize(s)


def _sweep_all_orderings_expect_value(
    imm base: List[Float64], expect: Float64, use_f64: Bool, label: String
) raises:
    """Every permutation of `base` must produce EXACTLY `expect`.

    The count of permutations visited is asserted too: a `_next_permutation`
    that returned False early would otherwise turn this into a one-ordering
    test that silently passes.
    """
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
        var got = _f64_median_of(v) if use_f64 else _agg_median_of(v)
        if not _approx_equal(got, expect):
            raise Error(
                String(label)
                + ": ordering #"
                + String(visited)
                + " gave "
                + String(got)
                + ", expected "
                + String(expect)
                + " (median is a function of the MULTISET, not of arrival order)"
            )
        visited += 1
        if not _next_permutation(idx):
            break
    assert_equal(visited, factorial, String(label) + ": permutation count")


def _sweep_all_orderings_expect_nan(
    imm base: List[Float64], use_f64: Bool, label: String
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
        var got = _f64_median_of(v) if use_f64 else _agg_median_of(v)
        if not _is_nan(got):
            raise Error(
                String(label)
                + ": ordering #"
                + String(visited)
                + " gave "
                + String(got)
                + ", expected NaN"
            )
        visited += 1
        if not _next_permutation(idx):
            break
    assert_equal(visited, factorial, String(label) + ": permutation count")


def _four_and_two_nans() -> List[Float64]:
    var v = List[Float64]()
    v.append(Float64(1.0))
    v.append(Float64(2.0))
    v.append(Float64(3.0))
    v.append(Float64(4.0))
    v.append(_nan())
    v.append(_nan())
    return v^


def _three_and_two_nans() -> List[Float64]:
    var v = List[Float64]()
    v.append(Float64(1.0))
    v.append(Float64(2.0))
    v.append(Float64(3.0))
    v.append(_nan())
    v.append(_nan())
    return v^


def _two_and_two_nans() -> List[Float64]:
    var v = List[Float64]()
    v.append(Float64(1.0))
    v.append(Float64(2.0))
    v.append(_nan())
    v.append(_nan())
    return v^


def _three_and_one_nan() -> List[Float64]:
    var v = List[Float64]()
    v.append(Float64(1.0))
    v.append(Float64(2.0))
    v.append(Float64(3.0))
    v.append(_nan())
    return v^


# -----------------------------------------------------------------------------
# T1 — the single ordering the defect report named
# -----------------------------------------------------------------------------


def test_T1_median_agg_nan_first_is_not_nan() raises:
    """[NaN, NaN, 1, 2, 3, 4] -> 3.5, not NaN.

    This is the 60%-plurality arm of the old behaviour: a NaN at buf[0] makes
    every later insertion stop at j == 0, so nothing moves and buf[2]/buf[3]
    are still `1.0`/`2.0`... except that with TWO leading NaNs the middle pair
    is (1.0, 2.0) -> 1.5 or NaN depending on placement. Either way it is not
    an order statistic of anything.
    """
    var v = List[Float64]()
    v.append(_nan())
    v.append(_nan())
    v.append(Float64(1.0))
    v.append(Float64(2.0))
    v.append(Float64(3.0))
    v.append(Float64(4.0))
    var got = _agg_median_of(v)
    assert_true(
        not _is_nan(got),
        "median{1,2,3,4,NaN,NaN} must not be NaN — only 2 of 6 values are NaN",
    )
    assert_true(_approx_equal(got, Float64(3.5)), "DuckDB v1.5.3 says 3.5")


# -----------------------------------------------------------------------------
# T2..T7 — MedianAggregator
# -----------------------------------------------------------------------------


def test_T2_median_agg_all_720_orderings_agree() raises:
    _sweep_all_orderings_expect_value(
        _four_and_two_nans(), Float64(3.5), False, "MedianAggregator{1,2,3,4,NaN,NaN}"
    )


def test_T3_median_agg_odd_with_two_nans() raises:
    _sweep_all_orderings_expect_value(
        _three_and_two_nans(), Float64(3.0), False, "MedianAggregator{1,2,3,NaN,NaN}"
    )


def test_T4_median_agg_nan_reaches_the_middle_pair() raises:
    """{1,2,NaN,NaN}: sorted under the total order is [1,2,NaN,NaN]; the middle
    pair is (2, NaN) so the mean is NaN. DuckDB v1.5.3 agrees. A NaN answer
    here is CORRECT — the point is that it must not depend on arrival order."""
    _sweep_all_orderings_expect_nan(
        _two_and_two_nans(), False, "MedianAggregator{1,2,NaN,NaN}"
    )


def test_T5_median_agg_single_nan_even_n() raises:
    _sweep_all_orderings_expect_value(
        _three_and_one_nan(), Float64(2.5), False, "MedianAggregator{1,2,3,NaN}"
    )


def test_T6_median_agg_all_nan_group_is_nan() raises:
    var v = List[Float64]()
    v.append(_nan())
    v.append(_nan())
    v.append(_nan())
    assert_true(_is_nan(_agg_median_of(v)), "all-NaN group -> NaN")


def test_T7_median_agg_nan_free_groups_unchanged() raises:
    """The NaN-last fix must be a NO-OP on every NaN-free group: with zero
    NaNs the compaction is the identity and the same order statistic comes
    back. Guards against a fix that changes answers it had no business
    touching."""
    var a = List[Float64]()
    a.append(Float64(1.0))
    a.append(Float64(2.0))
    a.append(Float64(3.0))
    a.append(Float64(4.0))
    assert_true(_approx_equal(_agg_median_of(a), Float64(2.5)), "median[1,2,3,4]")

    var b = List[Float64]()
    b.append(Float64(10.0))
    b.append(Float64(2.0))
    b.append(Float64(8.0))
    b.append(Float64(4.0))
    b.append(Float64(6.0))
    b.append(Float64(12.0))
    assert_true(_approx_equal(_agg_median_of(b), Float64(7.0)), "median[2,4,6,8,10,12]")

    var c = List[Float64]()
    c.append(Float64(5.0))
    c.append(Float64(1.0))
    c.append(Float64(9.0))
    assert_true(_approx_equal(_agg_median_of(c), Float64(5.0)), "median[1,5,9]")

    # -0.0 / +0.0 mix: any correct algorithm may return either bit pattern;
    # assert the VALUE, which is 0.0 under ==.
    var d = List[Float64]()
    d.append(Float64(-0.0))
    d.append(Float64(0.0))
    assert_true(_approx_equal(_agg_median_of(d), Float64(0.0)), "median[-0.0,0.0]")


# -----------------------------------------------------------------------------
# T10..T16 — MedianF64 (the SECOND body over the SAME state)
# -----------------------------------------------------------------------------


def test_T10_median_f64_nan_first_is_not_nan() raises:
    var v = List[Float64]()
    v.append(_nan())
    v.append(_nan())
    v.append(Float64(1.0))
    v.append(Float64(2.0))
    v.append(Float64(3.0))
    v.append(Float64(4.0))
    var got = _f64_median_of(v)
    assert_true(not _is_nan(got), "MedianF64: must not be NaN")
    assert_true(_approx_equal(got, Float64(3.5)), "MedianF64: DuckDB says 3.5")


def test_T11_median_f64_all_720_orderings_agree() raises:
    _sweep_all_orderings_expect_value(
        _four_and_two_nans(), Float64(3.5), True, "MedianF64{1,2,3,4,NaN,NaN}"
    )


def test_T12_median_f64_odd_with_two_nans() raises:
    _sweep_all_orderings_expect_value(
        _three_and_two_nans(), Float64(3.0), True, "MedianF64{1,2,3,NaN,NaN}"
    )


def test_T13_median_f64_nan_reaches_the_middle_pair() raises:
    _sweep_all_orderings_expect_nan(
        _two_and_two_nans(), True, "MedianF64{1,2,NaN,NaN}"
    )


def test_T14_median_f64_single_nan_even_n() raises:
    _sweep_all_orderings_expect_value(
        _three_and_one_nan(), Float64(2.5), True, "MedianF64{1,2,3,NaN}"
    )


def test_T15_median_f64_all_nan_group_is_nan() raises:
    var v = List[Float64]()
    v.append(_nan())
    v.append(_nan())
    v.append(_nan())
    assert_true(_is_nan(_f64_median_of(v)), "MedianF64 all-NaN group -> NaN")


def test_T16_median_f64_nan_free_groups_unchanged() raises:
    var a = List[Float64]()
    a.append(Float64(1.0))
    a.append(Float64(2.0))
    a.append(Float64(3.0))
    a.append(Float64(4.0))
    assert_true(_approx_equal(_f64_median_of(a), Float64(2.5)), "MedianF64[1,2,3,4]")

    var c = List[Float64]()
    c.append(Float64(5.0))
    c.append(Float64(1.0))
    c.append(Float64(9.0))
    assert_true(_approx_equal(_f64_median_of(c), Float64(5.0)), "MedianF64[1,5,9]")


# -----------------------------------------------------------------------------
# T17 — the two bodies must AGREE. They are separate code over one state.
# -----------------------------------------------------------------------------


def test_T17_both_bodies_agree_on_every_nan_bearing_ordering() raises:
    """`MedianAggregator` and `MedianF64` are two hand-written finalize bodies
    over the same `MedianState`; nothing in the type system makes them agree.
    Sweep the 720 orderings and assert they return the same bits."""
    var base = _four_and_two_nans()
    var idx = List[Int]()
    for i in range(len(base)):
        idx.append(i)
    var visited = 0
    while True:
        var v = List[Float64]()
        for i in range(len(base)):
            v.append(base[idx[i]])
        var a = _agg_median_of(v)
        var b = _f64_median_of(v)
        if _is_nan(a) or _is_nan(b):
            assert_true(
                _is_nan(a) and _is_nan(b),
                "bodies disagree on NaN-ness at ordering #" + String(visited),
            )
        else:
            assert_true(
                _approx_equal(a, b),
                "bodies disagree at ordering #" + String(visited),
            )
        visited += 1
        if not _next_permutation(idx):
            break
    assert_equal(visited, 720, "permutation count")


# -----------------------------------------------------------------------------
# T20 / T21 — BOTH SIDES OF THE 64-VALUE CAP
# -----------------------------------------------------------------------------


def test_T20_exactly_64_values_with_nans_matches_duckdb() raises:
    """At EXACTLY the cap nothing is dropped, so DuckDB parity must hold.

    60 values 0.0..59.0 plus 4 NaNs, fed NaN-FIRST (the arrival order that
    used to make the whole sort a no-op). Under the total order the sorted
    array is [0..59, NaN, NaN, NaN, NaN]; n == 64, the middle pair is indices
    31 and 32, both inside the 60-value non-NaN prefix, so the answer is
    (31 + 32) / 2 == 31.5.
    """
    var v = List[Float64]()
    for _ in range(4):
        v.append(_nan())
    for i in range(60):
        v.append(Float64(i))
    assert_equal(len(v), MAX_MEDIAN_VALUES, "fixture is exactly at the cap")
    assert_true(_approx_equal(_agg_median_of(v), Float64(31.5)), "MedianAggregator@64")
    assert_true(_approx_equal(_f64_median_of(v), Float64(31.5)), "MedianF64@64")


def test_T21_sixty_five_values_truncates_and_that_is_the_known_divergence() raises:
    """⛔ ABOVE THE CAP THIS IS **NOT** DuckDB PARITY AND THIS TEST DOES NOT
    PRETEND IT IS.

    65 values are fed; `update` drops the 65th (FIRST-64 retention), so the
    answer is the median of the FIRST 64 — a deterministic function of arrival
    order, which for a parallel group partition means it is still not a
    function of the multiset. What this test pins is that the truncation is
    EXACT and has not silently become something else; the wrong-answer class
    itself is refused by name, with the missing primitive stated, in the ADR
    an internal doc.

    Fixture: 0.0..63.0 then 1000.0. Retained = [0..63], n == 64, middle pair
    (31, 32) -> 31.5. DuckDB over all 65 rows answers 32.0, and the gap
    between 31.5 and 32.0 IS the defect this test refuses to paper over.
    """
    var v = List[Float64]()
    for i in range(64):
        v.append(Float64(i))
    v.append(Float64(1000.0))
    assert_equal(len(v), MAX_MEDIAN_VALUES + 1, "fixture is one past the cap")

    var s = MedianAggregator.init()
    for i in range(len(v)):
        MedianAggregator.update(s, Float64(v[i]))
    assert_equal(s.count, Int32(MAX_MEDIAN_VALUES), "count clamps at the cap")
    assert_true(
        _approx_equal(Float64(MedianAggregator.finalize(s)), Float64(31.5)),
        "MedianAggregator truncates to the FIRST 64 (DuckDB over all 65: 32.0)",
    )
    assert_true(
        _approx_equal(_f64_median_of(v), Float64(31.5)),
        "MedianF64 truncates to the FIRST 64 (DuckDB over all 65: 32.0)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
