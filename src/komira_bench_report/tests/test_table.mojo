# The human table of a fixed result, byte for byte, and the number formatting
# under it.
#
# What each case proves:
# - test_table_of_the_sample: the banner (suites, scale, threads, DuckDB version
#   and pin, komira version, the first eight digits of the dataset lock), a row
#   per cell, a dash for the ratio of a divergent cell and of a refused cell
#   (which keep their row), the threshold in FAIL(...), the reason in NO_RATIO,
#   and a footer per suite and for the run that carries the PASS count with
#   its denominator, the threshold and the pin.
#   Each cell shows its first run (komira, DuckDB, and their ratio), its
#   steady-state time (the same three) and the spread of the sweep medians of
#   each engine, in separate columns; a dash stands where a side has no first
#   run (komira refused) or no spread, and where a ratio does not exist.
#   Beneath the rows a legend, and the definition of "first" and "steady" as
#   `STEADY_STATE_DEFINITION` states it, appear once. The summary lines call the
#   geomean and median steady-state and state the first-run ones beside them.
# - test_a_cell_read_from_an_older_result_shows_dashes_for_its_first_run: a cell
#   whose sides have no runs prints dashes in the three first-run columns and
#   still prints its steady-state columns and ratio.
# - test_an_unverified_cell_shows_the_time_of_its_check_runs: a cell that was not
#   timed shows the time of its check runs in the first-run columns (komira and
#   DuckDB), dashes everywhere else, and no ratio.
# - test_ratio_is_shown_to_three_places: a ratio just above the threshold is
#   not rounded onto it: 1.504 against 1.5 reads FAIL, and shows 1.504.
# - test_table_of_an_unpinned_scale_in_rows: a rows scale and an unpinned DuckDB
#   print as such.
# - test_format_fixed: rounding half up, zero padding, no minus sign on a
#   negative that rounds to zero, no decimals.

from std.testing import assert_equal, assert_true

from komira_bench_report import (
    BenchResult,
    Cell,
    CheckRuns,
    FirstRun,
    DuckDbPin,
    Environment,
    RunInfo,
    STATISTIC_MIN_OF_SWEEP_MEDIAN,
    STEADY_STATE_DEFINITION,
    Side,
    StageOutcome,
    ValueVerdict,
    format_fixed,
    render_table,
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
        Side.from_sweeps(rows, _sweeps(99.0, m1, m1, m1, 99.0, m2, m2, m2), Optional[Float64](99.0))
    )


# The same, with the first run (the check run, before the sweeps) `first` instead of 99.
def _side_first(rows: Int64, first: Float64, m1: Float64, m2: Float64) raises -> Optional[Side]:
    return Optional[Side](
        Side.from_sweeps(rows, _sweeps(99.0, m1, m1, m1, 99.0, m2, m2, m2), Optional[Float64](first))
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
    # komira sweeps (99,4,6,5) and (99,3,3,3): medians 5.5 and 3, time 3; its
    # first run is 99 against DuckDB's 33.
    var q01k = Side.from_sweeps(4, _sweeps(99.0, 4.0, 6.0, 5.0, 99.0, 3.0, 3.0, 3.0), Optional[Float64](99.0))
    cells.append(_cell(String("tpch/q01"), String("tpch"), StageOutcome.exec_ok(),
        Optional[Side](q01k^), _side_first(4, 33.0, 2.0, 4.0), ValueVerdict.identical()))
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


def test_table_of_the_sample() raises:
    var want = (
        String("komira-bench  tpch,clickbench SF10  threads=20  duckdb v1.5.6 (PINNED)  komira 1.2.3  dataset a1b2c3d4\n")
        + String(" cell            first k  first d  first x steady k steady d steady x  spr k %  spr d %       rows  values  verdict\n")
        + String(" tpch/q01          99.00    33.00    3.000     3.00     2.00    1.500     83.3    100.0          4  IDENT   FAIL(1.05)\n")
        + String(" tpch/q02          99.00    99.00    1.000     2.00     2.00    1.000      0.0      0.0         10  IDENT   PASS\n")
        + String(" tpch/q03          99.00    99.00        -     1.00     4.00        -      0.0      0.0          7  DIVERG  NO_RATIO(DIVERGENT)\n")
        + String(" clickbench/q01        -    99.00        -        -     8.00        -        -      0.0        100  UNVER   NO_RATIO(UNSUPPORTED:window frame)\n")
        + String(" clickbench/q02    99.00    99.00    1.000     1.00     2.00    0.500      0.0      0.0         43  IDENT   PASS\n")
        + String(" k = komira, d = duckdb, x = komira over duckdb, spr = spread of the sweep medians in percent of the least\n")
        + String(" ") + String(STEADY_STATE_DEFINITION) + String("\n")
        + String(" tpch: PASS 1/3 at <= 1.05x vs duckdb v1.5.6 (PINNED) | steady-state geomean 1.22x over 2/3 value-verified | steady-state median 1.25x | first-run geomean 1.73x median 2.00x\n")
        + String(" clickbench: PASS 1/2 at <= 1.05x vs duckdb v1.5.6 (PINNED) | steady-state geomean 0.50x over 1/2 value-verified | steady-state median 0.50x | first-run geomean 1.00x median 1.00x\n")
        + String(" all: PASS 2/5 at <= 1.05x vs duckdb v1.5.6 (PINNED) | steady-state geomean 0.91x over 3/5 value-verified | steady-state median 1.00x | first-run geomean 1.44x median 1.00x\n")
    )
    assert_equal(render_table(_sample()), want)


def test_a_cell_read_from_an_older_result_shows_dashes_for_its_first_run() raises:
    var r = _sample()
    var medians = List[Float64]()
    medians.append(3.0)
    medians.append(3.0)
    var duck = List[Float64]()
    duck.append(2.0)
    duck.append(2.0)
    var k = Optional[Side](Side(4, 3.0, medians^, 0.0))
    var d = Optional[Side](Side(4, 2.0, duck^, 0.0))
    var cells = List[Cell]()
    cells.append(_cell(String("tpch/q01"), String("tpch"), StageOutcome.exec_ok(), k^, d^, ValueVerdict.identical()))
    r.cells = cells^
    var text = render_table(r)
    assert_true(text.find(String(" tpch/q01        -        -        -     3.00     2.00    1.500      0.0      0.0          4  IDENT   FAIL(1.05)\n")) >= 0)
    # no first-run figure is stated for it
    assert_true(text.find(String("first-run geomean")) < 0)


def test_an_unverified_cell_shows_the_time_of_its_check_runs() raises:
    var r = _sample()
    var runs = CheckRuns(
        Optional[FirstRun](FirstRun(50.0, Optional[Int64](7000), Optional[Int64](4))),
        Optional[FirstRun](FirstRun(40.0, Optional[Int64](60000), Optional[Int64](6))),
    )
    var cells = List[Cell]()
    cells.append(Cell.build(
        String("tpch/q09"), String("tpch"), 4, StageOutcome.exec_fail(), Optional[Side](), Optional[Side](),
        ValueVerdict.unverified(String("answer differs from duckdb")), 1.05, Optional[CheckRuns](runs^),
    ))
    r.cells = cells^
    var text = render_table(r)
    # first k and first d show the check runs; no ratio of either kind, no steady time
    assert_true(text.find(String(" tpch/q09    50.00    40.00        -        -        -        -        -        -          -  UNVER   NO_RATIO(EXEC_FAIL)\n")) >= 0)


def test_ratio_is_shown_to_three_places() raises:
    var r = _sample()
    var cells = List[Cell]()
    cells.append(_cell(String("tpch/q01"), String("tpch"), StageOutcome.exec_ok(),
        _side(4, 1.504, 1.504), _side(4, 1.0, 1.0), ValueVerdict.identical()))
    r.cells = cells^
    r.run.pass_max = 1.5
    r.cells[0] = Cell.build(String("tpch/q01"), String("tpch"), 4, StageOutcome.exec_ok(),
        _side(4, 1.504, 1.504), _side(4, 1.0, 1.0), ValueVerdict.identical(), 1.5)
    var text = render_table(r)
    assert_true(text.find(String(" 1.504 ")) >= 0)
    assert_true(text.find(String("FAIL(1.5)")) >= 0)


def test_table_of_an_unpinned_scale_in_rows() raises:
    var r = _sample()
    r.run.scale_kind = String("rows")
    r.run.scale_value = 99997497
    r.env.duckdb.pin = String("UNPINNED:local build")
    var text = render_table(r)
    var banner = String(text[byte=0:text.find(String("\n"))])
    assert_equal(
        banner,
        String("komira-bench  tpch,clickbench 99997497 rows  threads=20  duckdb v1.5.6 (UNPINNED:local build)  komira 1.2.3  dataset a1b2c3d4"),
    )


def test_format_fixed() raises:
    assert_equal(format_fixed(1.5, 2), String("1.50"))
    assert_equal(format_fixed(0.0, 2), String("0.00"))
    assert_equal(format_fixed(12.345, 1), String("12.3"))
    assert_equal(format_fixed(2.0, 0), String("2"))
    assert_equal(format_fixed(-0.001, 2), String("0.00"))
    assert_equal(format_fixed(-1.25, 1), String("-1.3"))
    assert_equal(format_fixed(9.999, 2), String("10.00"))
    assert_equal(format_fixed(0.05, 2), String("0.05"))
    # Beyond what an integer can hold the text saturates instead of wrapping.
    assert_equal(format_fixed(1e300, 2), String(">=1e15"))
    assert_equal(format_fixed(-1e300, 2), String("<=-1e15"))
    assert_equal(format_fixed(1e15, 0), String(">=1e15"))
    assert_equal(format_fixed(-1e15, 0), String("<=-1e15"))
    assert_equal(format_fixed(999999999999999.0, 0), String("999999999999999"))
    assert_equal(format_fixed(123456789012.5, 2), String("123456789012.50"))


def main() raises:
    var failed = String("")
    try:
        test_table_of_the_sample()
    except e:
        failed += "\n  test_table_of_the_sample: " + String(e)
    try:
        test_a_cell_read_from_an_older_result_shows_dashes_for_its_first_run()
    except e:
        failed += "\n  test_a_cell_read_from_an_older_result_shows_dashes_for_its_first_run: " + String(e)
    try:
        test_an_unverified_cell_shows_the_time_of_its_check_runs()
    except e:
        failed += "\n  test_an_unverified_cell_shows_the_time_of_its_check_runs: " + String(e)
    try:
        test_ratio_is_shown_to_three_places()
    except e:
        failed += "\n  test_ratio_is_shown_to_three_places: " + String(e)
    try:
        test_table_of_an_unpinned_scale_in_rows()
    except e:
        failed += "\n  test_table_of_an_unpinned_scale_in_rows: " + String(e)
    try:
        test_format_fixed()
    except e:
        failed += "\n  test_format_fixed: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_table: FAILED" + failed)
    print("test_table: OK")
