# =============================================================================
# test_stats: median and quartiles of a few integer samples
# =============================================================================
#
# What each test proves, and the defect it would catch:
#   * test_median_and_quartiles_of_five_samples: the sorted samples
#     {1, 2, 3, 4, 100} have median 3 and quartiles 2 and 4 whatever order they
#     arrive in. Catches a median taken of the unsorted list or an outlier
#     moving the quartiles.
#   * test_quartiles_interpolate_between_ranks: {10, 20, 30, 40} has q1 17.5 and
#     q3 32.5. Catches a rank rounded instead of interpolated.
#   * test_no_samples_and_one_sample: no samples give 0, one gives itself.

from std.testing import TestSuite, assert_equal

from komira_bench_sum_emit.stats import maximum, median, minimum, quantile


def _list(a: Int, b: Int, c: Int, d: Int, e: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    out.append(c)
    out.append(d)
    out.append(e)
    return out^


def test_median_and_quartiles_of_five_samples() raises:
    var xs = _list(100, 3, 1, 4, 2)
    assert_equal(median(xs), 3.0)
    assert_equal(quantile(xs, 0.25), 2.0)
    assert_equal(quantile(xs, 0.75), 4.0)
    assert_equal(minimum(xs), 1)
    assert_equal(maximum(xs), 100)


def test_quartiles_interpolate_between_ranks() raises:
    var xs = List[Int]()
    xs.append(40)
    xs.append(10)
    xs.append(30)
    xs.append(20)
    assert_equal(quantile(xs, 0.25), 17.5)
    assert_equal(quantile(xs, 0.75), 32.5)


def test_no_samples_and_one_sample() raises:
    var none = List[Int]()
    assert_equal(median(none), 0.0)
    var one = List[Int]()
    one.append(7)
    assert_equal(median(one), 7.0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
