# The sample statistics of the probe.
#
# What each test proves, and the defect it would catch:
# - test_odd_sample: [5, 1, 4, 2, 3] has median 3, quartiles 2 and 4, range
#   1 to 5 (the input out of order). Catches a median taken before sorting.
# - test_even_sample_interpolates: [10, 20, 30, 40] has median 25, q1 17.5,
#   q3 32.5. Catches a quartile that picks a rank instead of interpolating.
# - test_one_and_no_samples: one sample is its own median and quartiles; no
#   samples give 0. Catches an index out of range.
# - test_sorting_leaves_the_input_alone: `sorted_copy` returns a sorted copy
#   and the argument keeps its order.

from std.testing import TestSuite, assert_equal

from komira_bench_q6_phases.stats import (
    maximum,
    median,
    minimum,
    quantile,
    sorted_copy,
)


def _list(*xs: Int) -> List[Int]:
    var out = List[Int]()
    for x in xs:
        out.append(x)
    return out^


def test_odd_sample() raises:
    var xs = _list(5, 1, 4, 2, 3)
    assert_equal(median(xs), 3.0)
    assert_equal(quantile(xs, 0.25), 2.0)
    assert_equal(quantile(xs, 0.75), 4.0)
    assert_equal(minimum(xs), 1)
    assert_equal(maximum(xs), 5)


def test_even_sample_interpolates() raises:
    var xs = _list(40, 10, 30, 20)
    assert_equal(median(xs), 25.0)
    assert_equal(quantile(xs, 0.25), 17.5)
    assert_equal(quantile(xs, 0.75), 32.5)


def test_one_and_no_samples() raises:
    var one = _list(7)
    assert_equal(median(one), 7.0)
    assert_equal(quantile(one, 0.25), 7.0)
    var none = List[Int]()
    assert_equal(median(none), 0.0)
    assert_equal(minimum(none), 0)
    assert_equal(maximum(none), 0)


def test_sorting_leaves_the_input_alone() raises:
    var xs = _list(3, 1, 2)
    var s = sorted_copy(xs)
    assert_equal(s[0], 1)
    assert_equal(s[1], 2)
    assert_equal(s[2], 3)
    assert_equal(xs[0], 3)
    assert_equal(xs[1], 1)
    assert_equal(xs[2], 2)


def main() raises:
    var suite = TestSuite()
    suite.test[test_odd_sample]()
    suite.test[test_even_sample_interpolates]()
    suite.test[test_one_and_no_samples]()
    suite.test[test_sorting_leaves_the_input_alone]()
    suite^.run()
