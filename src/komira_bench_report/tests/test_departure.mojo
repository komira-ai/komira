# A cell whose values equal DuckDB's but whose declared type departs from it
# for a reason the arrow representation forces (HUGEINT as DECIMAL(38,0)). It
# is counted and shown apart from a pass, and keeps its ratio. Cells and
# results are built by hand: no engine, no clock.
#
# What each case proves, and the defect it catches:
# - test_a_departure_cell_keeps_its_ratio_and_is_never_a_pass: the value text
#   `DEPARTURE:<reason>` parses and prints back; a cell with it has the ratio
#   komira ms / duckdb ms and the verdict DEPARTURE, although the ratio is
#   under the threshold. Catches a departure that is dropped to NO_RATIO, one
#   that is called PASS, and one that loses its ratio.
# - test_the_summary_never_counts_a_departure_as_a_pass: next to a plain pass,
#   a departure leaves PASS at 1 of 2, is counted in `n_departure`, is not a
#   value-identical cell, and the line says `DEPARTURE 1/2`; with no departure
#   the line has no such clause. Catches a summary that adds departures to PASS.
# - test_the_table_shows_the_departure_and_its_reason: the row of the cell
#   says DEPART in the values column and DEPARTURE(<reason>) as its verdict,
#   with its ratio, never PASS.
# - test_the_exit_status_allows_a_departure: a run whose every cell ran and is
#   IDENTICAL or a DEPARTURE exits 0; a divergent cell still gives 1.
# - test_a_departure_round_trips_through_result_json: result.json written
#   and read back holds the same value text, verdict and summary.
# - test_a_departure_must_say_its_reason_and_follow_the_rules: a departure with
#   no reason, or a reason that looks like a path, is refused; a cell that
#   calls its departure PASS, or has a departure without a duckdb side, is
#   refused by validate_cell.

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
    exit_code,
    parse_result_json,
    render_table,
    summarize,
    summary_line,
    validate_cell,
    write_result_json,
)

comptime _REASON: String = "Arrow has no 128-bit integer: HUGEINT as DECIMAL(38,0)"


def _hex(lead: String) -> String:
    var s = lead.copy()
    while s.byte_length() < 64:
        s += String("0")
    return s^


def _side(rows: Int64, m: Float64) raises -> Optional[Side]:
    var sweeps = List[List[Float64]]()
    for _ in range(2):
        var one = List[Float64]()
        one.append(99.0)
        one.append(m)
        one.append(m)
        one.append(m)
        sweeps.append(one^)
    return Optional[Side](Side.from_sweeps(rows, sweeps.copy()))


def _departure() raises -> ValueVerdict:
    """The value verdict `DEPARTURE:<reason>` as a result.json would hold it."""
    var text = String("DEPARTURE:") + String(_REASON)
    var parsed = Optional[ValueVerdict]()
    var why = String("")
    try:
        parsed = Optional[ValueVerdict](ValueVerdict.parse(text))
    except e:
        why = String(e)
    assert_true(Bool(parsed), String("`") + text + String("` is a value verdict: ") + why)
    return parsed.take()


def _build(id: String, komira_ms: Float64, value: ValueVerdict) raises -> Cell:
    return Cell.build(
        id.copy(), String("tpch"), 4, StageOutcome.exec_ok(), _side(4, komira_ms), _side(4, 2.0), value.copy(), 1.05
    )


def _result(var cells: List[Cell]) raises -> BenchResult:
    var run = RunInfo(String("both"), String("sf"), 10, 2, 4, String(STATISTIC_MIN_OF_SWEEP_MEDIAN), 20, 1.05)
    var env = Environment(
        String("bench-class-a"), String("Example CPU 2.4GHz"), 44, 137438953472,
        String("Linux 6.1"), String("1.2.3"),
        DuckDbPin(String("v1.5.6"), _hex(String("ab")), String("PINNED")),
        _hex(String("a1b2c3d4")),
    )
    return BenchResult(run^, env^, cells^)


def _mixed() raises -> BenchResult:
    var cells = List[Cell]()
    cells.append(_build(String("tpch/q01"), 1.0, ValueVerdict.identical()))
    cells.append(_build(String("tpch/q02"), 1.0, _departure()))
    return _result(cells^)


def test_a_departure_cell_keeps_its_ratio_and_is_never_a_pass() raises:
    var v = _departure()
    assert_equal(v.text(), String("DEPARTURE:") + String(_REASON))
    assert_true(not v.is_identical())
    var c = _build(String("tpch/q02"), 1.0, v)
    assert_true(Bool(c.ratio))
    assert_equal(c.ratio.value(), 0.5)
    assert_equal(c.verdict, String("DEPARTURE"))
    assert_true(c.verdict != String("PASS"))
    var slow = _build(String("tpch/q03"), 6.0, v)
    assert_true(Bool(slow.ratio))
    assert_equal(slow.verdict, String("DEPARTURE"))


def test_the_summary_never_counts_a_departure_as_a_pass() raises:
    var r = _mixed()
    var s = summarize(r)
    assert_equal(s.overall.n_cells, 2)
    assert_equal(s.overall.n_pass, 1)
    assert_equal(s.overall.n_fail, 0)
    assert_equal(s.overall.n_departure, 1)
    assert_equal(s.overall.n_verified, 1)
    assert_equal(s.overall.n_ratio, 2)
    var line = summary_line(s.overall, 1.05, r.env.duckdb)
    assert_true(line.startswith(String("PASS 1/2 at <= 1.05x")), line)
    assert_true(line.find(String("DEPARTURE 1/2")) >= 0, line)
    var plain = List[Cell]()
    plain.append(_build(String("tpch/q01"), 1.0, ValueVerdict.identical()))
    var p = _result(plain^)
    var plain_line = summary_line(summarize(p).overall, 1.05, p.env.duckdb)
    assert_true(plain_line.find(String("DEPARTURE")) < 0, plain_line)


def test_the_table_shows_the_departure_and_its_reason() raises:
    var text = render_table(_mixed())
    var row = String("")
    for line in text.split(String("\n")):
        if String(line).find(String("tpch/q02")) >= 0:
            row = String(line)
    assert_true(row.byte_length() > 0, text)
    assert_true(row.find(String("DEPART")) >= 0, row)
    assert_true(row.find(String("DEPARTURE(") + String(_REASON) + String(")")) >= 0, row)
    assert_true(row.find(String("0.500")) >= 0, row)
    assert_true(row.find(String("PASS")) < 0, row)


def test_the_exit_status_allows_a_departure() raises:
    assert_equal(exit_code(summarize(_mixed())), 0)
    var cells = List[Cell]()
    cells.append(_build(String("tpch/q01"), 1.0, _departure()))
    cells.append(_build(String("tpch/q02"), 1.0, ValueVerdict.divergent()))
    assert_equal(exit_code(summarize(_result(cells^))), 1)


def test_a_departure_round_trips_through_result_json() raises:
    var r = _mixed()
    var text = write_result_json(r)
    assert_true(text.find(String('"DEPARTURE:') + String(_REASON)) >= 0, text)
    var back = parse_result_json(text)
    assert_equal(back.cells[1].value.text(), String("DEPARTURE:") + String(_REASON))
    assert_equal(back.cells[1].verdict, String("DEPARTURE"))
    assert_equal(summarize(back).overall.n_departure, 1)
    assert_true(text.find(String('"n_departure":1')) >= 0, text)
    assert_equal(write_result_json(back), text)


def _refuses_value(kind: String, detail: String) -> Bool:
    try:
        _ = ValueVerdict(kind.copy(), detail.copy())
    except:
        return True
    return False


def test_a_departure_must_say_its_reason_and_follow_the_rules() raises:
    assert_true(_refuses_value(String("DEPARTURE"), String("")))
    assert_true(_refuses_value(String("DEPARTURE"), String("see /etc/passwd")))
    var good = _build(String("tpch/q02"), 1.0, _departure())
    var run = _result(List[Cell]()).run.copy()
    validate_cell(good, run)
    var as_pass = good.copy()
    as_pass.verdict = String("PASS")
    var raised = False
    try:
        validate_cell(as_pass, run)
    except:
        raised = True
    assert_true(raised, "a departure called PASS is refused")
    var no_duckdb = good.copy()
    no_duckdb.duckdb = Optional[Side]()
    raised = False
    try:
        validate_cell(no_duckdb, run)
    except:
        raised = True
    assert_true(raised, "a departure needs a duckdb side")


def main() raises:
    var failed = String("")
    try:
        test_a_departure_cell_keeps_its_ratio_and_is_never_a_pass()
    except e:
        failed += "\n  test_a_departure_cell_keeps_its_ratio_and_is_never_a_pass: " + String(e)
    try:
        test_the_summary_never_counts_a_departure_as_a_pass()
    except e:
        failed += "\n  test_the_summary_never_counts_a_departure_as_a_pass: " + String(e)
    try:
        test_the_table_shows_the_departure_and_its_reason()
    except e:
        failed += "\n  test_the_table_shows_the_departure_and_its_reason: " + String(e)
    try:
        test_the_exit_status_allows_a_departure()
    except e:
        failed += "\n  test_the_exit_status_allows_a_departure: " + String(e)
    try:
        test_a_departure_round_trips_through_result_json()
    except e:
        failed += "\n  test_a_departure_round_trips_through_result_json: " + String(e)
    try:
        test_a_departure_must_say_its_reason_and_follow_the_rules()
    except e:
        failed += "\n  test_a_departure_must_say_its_reason_and_follow_the_rules: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_departure: FAILED" + failed)
    print("test_departure: OK")
