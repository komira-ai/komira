# =============================================================================
# tests/test_edivisive.mojo
#   The PRIMARY detector: the energy statistic, the split scan, the permutation
#   test, and the determinism the whole design rests on.
#
#   ⭐ THE ASSERTION THAT MATTERS MOST HERE IS THE BORING ONE: the same input
#   and the same seed produce the SAME verdict. A change-point detector whose
#   answer moves between runs is one nobody will act on. Determinism is asserted
#   three ways below — the raw PRNG stream against golden values, the seed
#   derivation, and a full fit repeated.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_anomaly import (
    MIN_SEGMENT_FLOOR,
    SplitMix64,
    best_split,
    fit_change_point,
    seed_for_key,
)


def test_splitmix64_stream_matches_golden_values() raises:
    """The PRNG is pinned to golden values, not merely 'random enough'.

    These four came from an INDEPENDENT implementation of SplitMix64 written
    against the published algorithm. If this ever drifts, every verdict this
    package has issued changes meaning, and the permutation test stops being
    reproducible across machines — so the constants are worth pinning
    literally rather than describing.
    """
    var rng = SplitMix64(0x9E3779B97F4A7C15)
    assert_true(
        rng.next_u64() == UInt64(7960286522194355700), "draw 1"
    )
    assert_true(
        rng.next_u64() == UInt64(487617019471545679), "draw 2"
    )
    assert_true(
        rng.next_u64() == UInt64(17909611376780542444), "draw 3"
    )
    assert_true(
        rng.next_u64() == UInt64(1961750202426094747), "draw 4"
    )

def test_seed_for_key_is_stable_distinct_and_never_zero() raises:
    """The seed is a pure function of the key — so one series' verdict cannot
    depend on how many other series were evaluated before it."""
    var a = seed_for_key(String("tpch/q12"))
    var b = seed_for_key(String("tpch/q12"))
    assert_equal(Int(a), Int(b), "the same key must give the same seed")
    assert_true(
        seed_for_key(String("tpch/q12")) != seed_for_key(String("tpch/q13")),
        "distinct keys must not share a shuffle stream",
    )
    # ORed with 1 at the end of the hash: never zero, for any key at all.
    assert_true(
        (seed_for_key(String("")) % 2) == 1
        and (seed_for_key(String("a")) % 2) == 1,
        "the seed is forced odd, so it is never zero",
    )


def test_best_split_finds_the_exact_boundary_of_a_clean_step() raises:
    var v: List[Float64] = [
        1.0, 1.1, 0.9, 1.0, 1.05, 5.0, 5.1, 4.9, 5.0, 5.05
    ]
    var s = best_split(v, 3)
    assert_true(s.is_admissible(), "a 10-point series admits a split")
    assert_equal(
        s.index, 5, "the split must land exactly on the true boundary"
    )
    assert_true(s.statistic > 0.0, "a real separation scores positive")


def test_best_split_refuses_a_segment_with_nowhere_to_put_a_change() raises:
    """THE BOUNDARY, BOTH SIDES. `2*min_segment` is the shortest series that
    admits a split; one point shorter admits none.

    ⚠ AND THE REFUSAL IS `index == -1`, NOT `statistic == 0.0`. A zero
    statistic would be indistinguishable from 'a split was evaluated and
    separated nothing', which is a completely different fact.
    """
    var five: List[Float64] = [1.0, 2.0, 3.0, 4.0, 5.0]
    assert_false(
        best_split(five, 3).is_admissible(),
        "5 points cannot be split with 3 required on each side",
    )
    var six: List[Float64] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0]
    assert_true(
        best_split(six, 3).is_admissible(),
        "6 points is exactly 2*min_segment and must admit a split",
    )
    assert_equal(
        best_split(five, 3).index, -1, "refusal is spelled -1, not 0"
    )


def test_best_split_refuses_a_min_segment_below_the_arithmetic_floor() raises:
    """Below `MIN_SEGMENT_FLOOR` the within-segment term divides by k*(k-1),
    which is zero at k=1. The scan refuses rather than producing an infinity."""
    var v: List[Float64] = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
    assert_false(
        best_split(v, MIN_SEGMENT_FLOOR - 1).is_admissible(),
        "a min_segment of 1 is arithmetically undefined and must be refused",
    )
    assert_true(
        best_split(v, MIN_SEGMENT_FLOOR).is_admissible(),
        "the floor itself is admissible",
    )


def test_a_fit_is_reproducible() raises:
    """THE DETERMINISM CLAIM, END TO END."""
    var v: List[Float64] = [
        1.0, 1.1, 0.9, 1.02, 1.05, 0.98, 3.0, 3.1, 2.9, 3.02, 3.05, 2.98
    ]
    var seed = seed_for_key(String("determinism/case"))
    var a = fit_change_point(v, 3, 199, seed)
    var b = fit_change_point(v, 3, 199, seed)
    assert_equal(a.index, b.index, "same index")
    assert_equal(a.p_value, b.p_value, "same p-value, to the bit")
    assert_equal(a.statistic, b.statistic, "same statistic, to the bit")


def test_p_value_is_exactly_one_over_one_plus_p_at_the_floor() raises:
    """⭐ (1+ge)/(1+P), NOT ge/P — PINNED BY AN EXACT VALUE, AT ge = 0.

    ── ⛔ WHY THIS TEST IS NOT THE ONE IT REPLACES.

    The previous version used [1.0 x5, 100.0 x5] with P=99 and asserted only
    `p >= 1/(1+P)` and `p > 0`. It passed under the ge/P formula its own
    docstring forbids, and the reason is TIED VALUES: the statistic depends
    only on WHICH values land on each side of the split, not on their order
    within a side, so any shuffle that happens to put all five 1.0s on one side
    reproduces the observed statistic exactly. With ten points that happens
    with probability 2/C(10,5) = 0.0079 per shuffle, so over 99 shuffles
    `ge >= 1` is likely — measured on that exact input and seed, ge = 1, and
    the forbidden ge/P returns 1/99 = 0.0101, which clears both of the old
    assertions. A test of the p-value floor whose input CANNOT reach the floor
    was testing nothing.

    ── ⭐ HOW THIS ONE CANNOT DO THAT.

    Twenty DISTINCT values, ten clustered near 10 and ten near 20, so the only
    shuffle that can tie the observed statistic is one that reproduces the
    exact 10/10 partition — probability 2/C(20,10) = 1.08e-5 per shuffle, about
    one chance in a hundred over the whole 999-shuffle run. Measured on this
    input and this seed: ge = 0. So the valid formula must return EXACTLY
    1/(1+999), and the assertion is an EQUALITY against that value computed the
    same way the implementation computes it.

    Under ge/P this line returns 0.0 and fails. Under (1+ge)/P it returns
    1/999 = 0.001001... and fails. The denominator is pinned as tightly as the
    numerator, and neither can be pinned by an inequality.
    """
    var v: List[Float64] = [
        10.0, 10.4, 10.1, 10.6, 10.2, 10.5, 10.3, 10.7, 10.8, 10.9,
        20.1, 20.5, 20.2, 20.7, 20.3, 20.6, 20.4, 20.8, 20.9, 21.0,
    ]
    comptime P: Int = 999
    var f = fit_change_point(v, 3, P, seed_for_key(String("pfloor")))
    assert_true(f.is_fitted(), "a clean 10 -> 20 step must fit")
    assert_equal(f.index, 10, "and the boundary is where the step is")
    assert_equal(
        f.p_value,
        Float64(1) / Float64(1 + P),
        String("p must be EXACTLY the floor 1/(1+P). ge/P would give 0.0 and")
        + String(" (1+ge)/P would give ")
        + String(Float64(1) / Float64(P))
        + String("; got ")
        + String(f.p_value),
    )
    assert_true(f.p_value > 0.0, "and a permutation test can never say zero")


def test_p_value_carries_the_plus_one_when_ge_is_nonzero() raises:
    """⭐ THE OTHER HALF: THE FLOOR CASE ALONE CANNOT PIN THE NUMERATOR.

    A wrong implementation that special-cased ge == 0 to 1/(1+P) would pass the
    test above and still be ge/P everywhere else. So this one uses an input
    whose ties GUARANTEE a nonzero ge — the very [1.0 x5, 100.0 x5] series that
    made the old test vacuous, kept here because that property is now the point
    rather than the flaw.

    Measured on this input and seed, ge = 1, so the valid formula returns
    exactly 2/100 and the forbidden one exactly 1/99. Those differ, and the
    assertion is again an equality.
    """
    var v: List[Float64] = [
        1.0, 1.0, 1.0, 1.0, 1.0, 100.0, 100.0, 100.0, 100.0, 100.0
    ]
    comptime P: Int = 99
    var f = fit_change_point(v, 3, P, seed_for_key(String("extreme")))
    assert_true(f.is_fitted(), "an enormous step must fit")
    assert_equal(
        f.p_value,
        Float64(2) / Float64(1 + P),
        String("with ge = 1 the valid p is (1+1)/(1+99) = 0.02; ge/P would")
        + String(" give ")
        + String(Float64(1) / Float64(P))
        + String("; got ")
        + String(f.p_value),
    )


def test_an_unfittable_series_reports_no_evidence() raises:
    """Too short to split: index -1 and p = 1.0, the strongest statement of
    'no evidence' available."""
    var v: List[Float64] = [1.0, 2.0, 3.0, 4.0]
    var f = fit_change_point(v, 3, 99, seed_for_key(String("short")))
    assert_false(f.is_fitted(), "no split is admissible")
    assert_equal(f.p_value, Float64(1.0), "and p is 1.0, not 0.0")
    assert_equal(
        f.relative_shift(), Float64(0.0), "an unfitted shift is 0.0"
    )


def test_a_series_with_no_change_yields_weak_evidence() raises:
    """Alternating values have no step anywhere; p must be nowhere near any
    sane significance level."""
    var v: List[Float64] = [
        1.0, 1.02, 1.0, 1.02, 1.0, 1.02, 1.0, 1.02, 1.0, 1.02, 1.0, 1.02
    ]
    var f = fit_change_point(v, 3, 299, seed_for_key(String("alternating")))
    assert_true(
        f.p_value > 0.05,
        String("a series with no change must not look significant; p=")
        + String(f.p_value),
    )


def test_relative_shift_reports_direction_and_magnitude() raises:
    """The p-value says how sure; `relative_shift` says how big. An alert needs
    both — on a long series a 0.5% move can be arbitrarily significant."""
    var up: List[Float64] = [
        10.0, 10.0, 10.0, 10.0, 10.0, 11.0, 11.0, 11.0, 11.0, 11.0
    ]
    var f = fit_change_point(up, 3, 99, seed_for_key(String("up")))
    assert_equal(f.index, 5, "boundary at 5")
    assert_true(
        f.relative_shift() > 0.099 and f.relative_shift() < 0.101,
        String("a 10 -> 11 step is +10%; got ") + String(f.relative_shift()),
    )
    var down: List[Float64] = [
        11.0, 11.0, 11.0, 11.0, 11.0, 10.0, 10.0, 10.0, 10.0, 10.0
    ]
    var g = fit_change_point(down, 3, 99, seed_for_key(String("down")))
    assert_true(
        g.relative_shift() < 0.0, "an improvement reports a NEGATIVE shift"
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
