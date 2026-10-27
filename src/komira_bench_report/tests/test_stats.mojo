# The statistics of a cell on fixed inputs, with exact expected numbers.
#
# What each case catches:
# - test_median: the middle of an odd count, the mean of the middle two of an
#   even count, an unsorted input, one value; an input that is not sorted
#   first, or an even count that takes one middle value, gives another number.
# - test_median_refuses: no values and a NaN are errors, not a number.
# - test_drop_first_rep: only index 0 goes; a sweep (100, 1, 2, 3) has median 2
#   once the warm-up is gone and 2.5 if it is kept; a one-rep sweep is refused.
# - test_min_of_sweep_medians: the least of the per-sweep medians: sweeps
#   (50,10,12,11), (50,9,30,10), (50,20,20,20) give 10, not the least rep (9),
#   not the mean of the medians, not the median of all reps.
# - test_geomean: exact on powers of two, and zero, negative, infinite and
#   empty inputs are refused (a log of zero must not become a ratio).
# - test_spread_and_ratio: spread in percent of the least, the ratio komira
#   over duckdb, and a non-positive time refused.

from std.math import inf, nan
from std.testing import assert_almost_equal, assert_equal, assert_true

from komira_bench_report import (
    drop_first_rep,
    geomean,
    median,
    min_of_sweep_medians,
    ratio_of,
    spread_pct,
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


def test_drop_first_rep() raises:
    var kept = drop_first_rep(_l(100.0, 1.0, 2.0, 3.0))
    assert_equal(len(kept), 3)
    assert_equal(kept[0], 1.0)
    assert_equal(sweep_median(_l(100.0, 1.0, 2.0, 3.0)), 2.0)
    var one = List[Float64]()
    one.append(5.0)
    var raised = False
    try:
        _ = drop_first_rep(one)
    except:
        raised = True
    assert_true(raised)


def test_min_of_sweep_medians() raises:
    var sweeps = List[List[Float64]]()
    sweeps.append(_l(50.0, 10.0, 12.0, 11.0))
    sweeps.append(_l(50.0, 9.0, 30.0, 10.0))
    sweeps.append(_l(50.0, 20.0, 20.0, 20.0))
    assert_equal(min_of_sweep_medians(sweeps), 10.0)


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
        test_drop_first_rep()
    except e:
        failed += "\n  test_drop_first_rep: " + String(e)
    try:
        test_min_of_sweep_medians()
    except e:
        failed += "\n  test_min_of_sweep_medians: " + String(e)
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
