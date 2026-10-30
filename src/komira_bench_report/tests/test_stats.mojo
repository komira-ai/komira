# The statistics of a cell on fixed inputs, with exact expected numbers.
#
# What each case proves:
# - test_median: the middle of an odd count, the mean of the middle two of an
#   even count, an unsorted input, one value; an input that is not sorted
#   first, or an even count that takes one middle value, gives another number.
# - test_median_refuses: no values and a NaN are errors, not a number.
# - test_sweep_median_takes_every_rep: nothing is left out of a sweep's median:
#   (100, 1, 2, 3) has median 2.5, a one-rep sweep is its own median, no reps
#   is an error.
# - test_min_of_sweep_medians: the least of the per-sweep medians over all reps:
#   sweeps (50,10,12,11), (50,9,30,10), (50,20,20,20) give 11.5, not the least
#   rep (9), not the mean of the medians, not the median of all reps.
# - test_steady_state: the steady-state time is the least over the sweeps of the
#   median of all the sweep's reps: it is 11.5 for sweeps (50,10,12,11),
#   (40,9,30,10), (20,20,20,20); a sweep's first rep is part of its median
#   (7 gives 10.5, where leaving it out would give 11); a one-rep sweep has a
#   steady state; no sweeps is refused.
# - test_geomean: exact on powers of two, and zero, negative, infinite and
#   empty inputs are refused (a log of zero must not become a ratio).
# - test_spread_and_ratio: spread in percent of the least, the ratio komira
#   over duckdb, and a non-positive time refused.

from std.math import inf, nan
from std.testing import assert_almost_equal, assert_equal, assert_true

from komira_bench_report import (
    geomean,
    median,
    min_of_sweep_medians,
    ratio_of,
    spread_pct,
    steady_state_ms,
    sweep_median,
)


def _l(a: Float64, b: Float64, c: Float64, d: Float64) -> List[Float64]:
    var out = List[Float64]()
    out.append(a)
    out.append(b)
    out.append(c)
    out.append(d)
    return out^


def _l3(a: Float64, b: Float64, c: Float64) -> List[Float64]:
    var out = List[Float64]()
    out.append(a)
    out.append(b)
    out.append(c)
    return out^


def test_median() raises:
    assert_equal(median(_l3(3.0, 1.0, 2.0)), 2.0)
    assert_equal(median(_l(4.0, 1.0, 3.0, 2.0)), 2.5)
    var one = List[Float64]()
    one.append(7.0)
    assert_equal(median(one), 7.0)


def test_median_refuses() raises:
    var raised = False
    try:
        _ = median(List[Float64]())
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = median(_l3(1.0, nan[DType.float64](), 2.0))
    except:
        raised = True
    assert_true(raised)


def test_sweep_median_takes_every_rep() raises:
    # nothing is left out: (100, 1, 2, 3) has median 2.5, not 2 (without the 100)
    assert_equal(sweep_median(_l(100.0, 1.0, 2.0, 3.0)), 2.5)
    assert_equal(sweep_median(_l3(100.0, 1.0, 2.0)), 2.0)
    # a sweep of one rep is its own median
    var one = List[Float64]()
    one.append(5.0)
    assert_equal(sweep_median(one), 5.0)
    var raised = False
    try:
        _ = sweep_median(List[Float64]())
    except:
        raised = True
    assert_true(raised)


def test_min_of_sweep_medians() raises:
    var sweeps = List[List[Float64]]()
    sweeps.append(_l(50.0, 10.0, 12.0, 11.0))
    sweeps.append(_l(50.0, 9.0, 30.0, 10.0))
    sweeps.append(_l(50.0, 20.0, 20.0, 20.0))
    # medians of all four reps: 11.5, 20, 20
    assert_equal(min_of_sweep_medians(sweeps), 11.5)


def test_steady_state() raises:
    var sweeps = List[List[Float64]]()
    sweeps.append(_l(50.0, 10.0, 12.0, 11.0))
    sweeps.append(_l(40.0, 9.0, 30.0, 10.0))
    sweeps.append(_l(20.0, 20.0, 20.0, 20.0))
    assert_equal(steady_state_ms(sweeps), 11.5)
    # the first rep of a sweep is part of its median: 7 pulls the first sweep
    # down to 10.5, and 900 does not move the second past 11.5
    var other = List[List[Float64]]()
    other.append(_l(7.0, 10.0, 12.0, 11.0))
    other.append(_l(900.0, 10.0, 12.0, 11.0))
    assert_equal(steady_state_ms(other), 10.5)
    # a sweep of one rep has a steady state
    var short = List[List[Float64]]()
    var one = List[Float64]()
    one.append(5.0)
    short.append(one^)
    assert_equal(steady_state_ms(short), 5.0)
    var raised = False
    try:
        _ = steady_state_ms(List[List[Float64]]())
    except:
        raised = True
    assert_true(raised)


def test_geomean() raises:
    assert_almost_equal(geomean(_l3(1.0, 4.0, 16.0)), 4.0, atol=1e-12)
    var two = List[Float64]()
    two.append(2.0)
    two.append(8.0)
    assert_almost_equal(geomean(two), 4.0, atol=1e-12)
    var bad = List[List[Float64]]()
    bad.append(_l3(1.0, 0.0, 2.0))
    bad.append(_l3(1.0, -1.0, 2.0))
    bad.append(_l3(1.0, inf[DType.float64](), 2.0))
    bad.append(List[Float64]())
    for i in range(len(bad)):
        var raised = False
        try:
            _ = geomean(bad[i])
        except:
            raised = True
        assert_true(raised)


def test_spread_and_ratio() raises:
    var two = List[Float64]()
    two.append(2.0)
    two.append(3.0)
    assert_equal(spread_pct(two), 50.0)
    assert_equal(ratio_of(3.0, 2.0), 1.5)
    var raised = False
    try:
        _ = ratio_of(1.0, 0.0)
    except:
        raised = True
    assert_true(raised)


def main() raises:
    var failed = String("")
    try:
        test_median()
    except e:
        failed += "\n  test_median: " + String(e)
    try:
        test_median_refuses()
    except e:
        failed += "\n  test_median_refuses: " + String(e)
    try:
        test_sweep_median_takes_every_rep()
    except e:
        failed += "\n  test_sweep_median_takes_every_rep: " + String(e)
    try:
        test_min_of_sweep_medians()
    except e:
        failed += "\n  test_min_of_sweep_medians: " + String(e)
    try:
        test_steady_state()
    except e:
        failed += "\n  test_steady_state: " + String(e)
    try:
        test_geomean()
    except e:
        failed += "\n  test_geomean: " + String(e)
    try:
        test_spread_and_ratio()
    except e:
        failed += "\n  test_spread_and_ratio: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_stats: FAILED" + failed)
    print("test_stats: OK")
