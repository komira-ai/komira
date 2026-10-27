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
    DuckDbPin,
    Environment,
    RunInfo,
    STATISTIC_MIN_OF_SWEEP_MEDIAN,
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


def test_table_of_the_sample() raises:
    var want = (
        String("komira-bench  tpch,clickbench SF10  threads=20  duckdb v1.5.6 (PINNED)  komira 1.2.3  dataset a1b2c3d4\n")
        + String(" cell            komira ms  duckdb ms   ratio       rows  values  verdict\n")
        + String(" tpch/q01             3.00       2.00   1.500          4  IDENT   FAIL(1.05)\n")
        + String(" tpch/q02             2.00       2.00   1.000         10  IDENT   PASS\n")
        + String(" tpch/q03             1.00       4.00       -          7  DIVERG  NO_RATIO(DIVERGENT)\n")
        + String(" clickbench/q01          -       8.00       -        100  UNVER   NO_RATIO(UNSUPPORTED:window frame)\n")
        + String(" clickbench/q02       1.00       2.00   0.500         43  IDENT   PASS\n")
        + String(" tpch: PASS 1/3 at <= 1.05x vs duckdb v1.5.6 (PINNED) | geomean 1.22x over 2/3 value-verified | median 1.25x\n")
        + String(" clickbench: PASS 1/2 at <= 1.05x vs duckdb v1.5.6 (PINNED) | geomean 0.50x over 1/2 value-verified | median 0.50x\n")
        + String(" all: PASS 2/5 at <= 1.05x vs duckdb v1.5.6 (PINNED) | geomean 0.91x over 3/5 value-verified | median 1.00x\n")
    )
    assert_equal(render_table(_sample()), want)


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
    assert_equal(format_fixed(123456789012.5, 2), String("123456789012.50"))


def main() raises:
    var failed = String("")
    try:
        test_table_of_the_sample()
    except e:
        failed += "\n  test_table_of_the_sample: " + String(e)
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
