# The counts and aggregates of a result, on cells whose numbers are fixed by
# hand: five cells in two suites (komira 3 ms / duckdb 2 ms, 2/2, 1/4 with
# divergent values, a refused one, 1/2).
#
# What each case proves:
# - test_ratio_only_for_verified_cells: a divergent cell and a cell komira
#   refused have no ratio, though both have times; the three verified ones do.
# - test_threshold_is_a_parameter: the same 1.5 ratio is PASS at 1.5 (the
#   boundary counts) and at 2.0, and FAIL at 1.49.
# - test_denominators: refused and divergent cells stay in every suite's cell
#   count, so PASS 1 of 3 and not 1 of 2.
# - test_geomean_and_median: the geomean and median over the ratios only, whole
#   and per suite.
# - test_summary_line: the PASS count is printed with its threshold and the
#   DuckDB pin; an unpinned DuckDB prints its reason; a run with no ratio prints
#   n/a, not a number.
# - test_exit_code: 0 only when every cell ran and was verified; a cell over the
#   threshold does not change it.

from std.testing import assert_almost_equal, assert_equal, assert_true

from komira_bench_report import (
    BenchResult,
    Cell,
    DuckDbPin,
    Environment,
    RunInfo,
    STATISTIC_MIN_OF_SWEEP_MEDIAN,
    Side,
    StageOutcome,
    ValueVerdict,
    exit_code,
    summarize,
    summary_line,
)

def _hex(lead: String) -> String:
    var s = lead.copy()
    while s.byte_length() < 64:
        s += String("0")
    return s^


def _sweeps(
    a0: Float64, a1: Float64, a2: Float64, a3: Float64,
    b0: Float64, b1: Float64, b2: Float64, b3: Float64,
) -> List[List[Float64]]:
    var first = List[Float64]()
    first.append(a0)
    first.append(a1)
    first.append(a2)
    first.append(a3)
    var second = List[Float64]()
    second.append(b0)
    second.append(b1)
    second.append(b2)
    second.append(b3)
    var out = List[List[Float64]]()
    out.append(first^)
    out.append(second^)
    return out^


# A side whose two sweeps (rep 0 first) reduce to the medians `m1` and `m2`.
def _side(rows: Int64, m1: Float64, m2: Float64) raises -> Optional[Side]:
    return Optional[Side](
        Side.from_sweeps(rows, _sweeps(99.0, m1, m1, m1, 99.0, m2, m2, m2))
    )


def _cell(
    id: String,
    suite: String,
    stage: StageOutcome,
    komira: Optional[Side],
    duckdb: Optional[Side],
    value: ValueVerdict,
) raises -> Cell:
    return Cell.build(
        id.copy(), suite.copy(), 4, stage.copy(), komira.copy(), duckdb.copy(), value.copy(), 1.05
    )


def _sample() raises -> BenchResult:
    var cells = List[Cell]()
    # komira sweeps (99,4,6,5) and (99,3,3,3): medians 5 and 3, time 3.
    var q01k = Side.from_sweeps(4, _sweeps(99.0, 4.0, 6.0, 5.0, 99.0, 3.0, 3.0, 3.0))
    cells.append(_cell(String("tpch/q01"), String("tpch"), StageOutcome.exec_ok(),
        Optional[Side](q01k^), _side(4, 2.0, 4.0), ValueVerdict.identical()))
    cells.append(_cell(String("tpch/q02"), String("tpch"), StageOutcome.exec_ok(),
        _side(10, 2.0, 2.0), _side(10, 2.0, 2.0), ValueVerdict.identical()))
    cells.append(_cell(String("tpch/q03"), String("tpch"), StageOutcome.exec_ok(),
        _side(7, 1.0, 1.0), _side(7, 4.0, 4.0), ValueVerdict.divergent()))
    cells.append(_cell(String("clickbench/q01"), String("clickbench"),
        StageOutcome.unsupported(String("window frame")), Optional[Side](),
        _side(100, 8.0, 8.0), ValueVerdict.unverified(String("not run"))))
    cells.append(_cell(String("clickbench/q02"), String("clickbench"), StageOutcome.exec_ok(),
        _side(43, 1.0, 1.0), _side(43, 2.0, 2.0), ValueVerdict.identical()))
    var run = RunInfo(String("both"), String("sf"), 10, 2, 4,
        String(STATISTIC_MIN_OF_SWEEP_MEDIAN), 20, 1.05)
    var env = Environment(
        String("bench-class-a"), String("Example CPU 2.4GHz"), 44, 137438953472,
        String("Linux 6.1"), String("1.2.3"),
        DuckDbPin(String("v1.5.6"), _hex(String("ab")), String("PINNED")),
        _hex(String("a1b2c3d4")),
    )
    return BenchResult(run^, env^, cells^)


def test_ratio_only_for_verified_cells() raises:
    var r = _sample()
    assert_true(Bool(r.cells[0].ratio))
    assert_equal(r.cells[0].ratio.value(), 1.5)
    assert_true(Bool(r.cells[1].ratio))
    assert_true(not Bool(r.cells[2].ratio))
    assert_true(Bool(r.cells[2].komira))
    assert_true(not Bool(r.cells[3].ratio))
    assert_true(Bool(r.cells[4].ratio))
    assert_equal(r.cells[4].ratio.value(), 0.5)
    assert_equal(r.cells[2].verdict, String("NO_RATIO"))


def test_threshold_is_a_parameter() raises:
    var limits = List[Float64]()
    limits.append(1.5)
    limits.append(2.0)
    limits.append(1.49)
    var want = List[String]()
    want.append(String("PASS"))
    want.append(String("PASS"))
    want.append(String("FAIL"))
    for i in range(len(limits)):
        var c = Cell.build(
            String("tpch/q01"), String("tpch"), 4, StageOutcome.exec_ok(),
            _side(1, 3.0, 3.0), _side(1, 2.0, 2.0), ValueVerdict.identical(),
            limits[i],
        )
        assert_equal(c.verdict, want[i])


def test_denominators() raises:
    var s = summarize(_sample())
    assert_equal(s.overall.n_cells, 5)
    assert_equal(s.overall.n_ran, 4)
    assert_equal(s.overall.n_verified, 3)
    assert_equal(s.overall.n_ratio, 3)
    assert_equal(s.overall.n_pass, 2)
    assert_equal(s.overall.n_fail, 1)
    assert_equal(len(s.suites), 2)
    assert_equal(s.suites[0].suite, String("tpch"))
    assert_equal(s.suites[0].n_cells, 3)
    assert_equal(s.suites[0].n_ran, 3)
    assert_equal(s.suites[0].n_verified, 2)
    assert_equal(s.suites[0].n_pass, 1)
    assert_equal(s.suites[0].n_fail, 1)
    assert_equal(s.suites[1].suite, String("clickbench"))
    assert_equal(s.suites[1].n_cells, 2)
    assert_equal(s.suites[1].n_ran, 1)
    assert_equal(s.suites[1].n_pass, 1)
    assert_equal(s.suites[1].n_fail, 0)


def test_geomean_and_median() raises:
    var s = summarize(_sample())
    assert_almost_equal(s.overall.geomean.value(), 0.9085602964160698, atol=1e-12)
    assert_equal(s.overall.median_ratio.value(), 1.0)
    assert_almost_equal(s.suites[0].geomean.value(), 1.224744871391589, atol=1e-12)
    assert_equal(s.suites[0].median_ratio.value(), 1.25)
    assert_almost_equal(s.suites[1].geomean.value(), 0.5, atol=1e-12)


def test_summary_line() raises:
    var r = _sample()
    var s = summarize(r)
    assert_equal(
        summary_line(s.overall, r.run.pass_max, r.env.duckdb),
        String(
            "PASS 2/5 at <= 1.05x vs duckdb v1.5.6 (PINNED) | geomean 0.91x"
            " over 3/5 value-verified | median 1.00x"
        ),
    )
    var unpinned = DuckDbPin(String("v1.5.6"), String(""), String("UNPINNED:local build"))
    assert_equal(
        summary_line(s.suites[1], 2.0, unpinned),
        String(
            "PASS 1/2 at <= 2.0x vs duckdb v1.5.6 (UNPINNED:local build) |"
            " geomean 0.50x over 1/2 value-verified | median 0.50x"
        ),
    )
    var only = List[Cell]()
    only.append(r.cells[3].copy())
    var none = BenchResult(r.run.copy(), r.env.copy(), only^)
    assert_equal(
        summary_line(summarize(none).overall, none.run.pass_max, none.env.duckdb),
        String(
            "PASS 0/1 at <= 1.05x vs duckdb v1.5.6 (PINNED) | geomean n/a"
            " (0/1 cells have a ratio)"
        ),
    )


def test_exit_code() raises:
    var r = _sample()
    assert_equal(exit_code(summarize(r)), 1)
    var ok = List[Cell]()
    ok.append(r.cells[0].copy())
    ok.append(r.cells[1].copy())
    ok.append(r.cells[4].copy())
    var all_verified = BenchResult(r.run.copy(), r.env.copy(), ok^)
    assert_equal(exit_code(summarize(all_verified)), 0)


def main() raises:
    var failed = String("")
    try:
        test_ratio_only_for_verified_cells()
    except e:
        failed += "\n  test_ratio_only_for_verified_cells: " + String(e)
    try:
        test_threshold_is_a_parameter()
    except e:
        failed += "\n  test_threshold_is_a_parameter: " + String(e)
    try:
        test_denominators()
    except e:
        failed += "\n  test_denominators: " + String(e)
    try:
        test_geomean_and_median()
    except e:
        failed += "\n  test_geomean_and_median: " + String(e)
    try:
        test_summary_line()
    except e:
        failed += "\n  test_summary_line: " + String(e)
    try:
        test_exit_code()
    except e:
        failed += "\n  test_exit_code: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_summary: FAILED" + failed)
    print("test_summary: OK")
