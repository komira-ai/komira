# The schema of result.json: what the writer writes, what the reader accepts,
# and each way the reader refuses a document.
#
# What each case catches:
# - test_round_trip: write, read, write gives the same text, and every field
#   comes back (a refused cell keeps its stage and has no komira side, a
#   divergent cell has no ratio, the DuckDB pin and dataset lock survive).
# - test_text_shape: one line, the schema string first, the scale as a
#   one-member object.
# - test_reader_refuses: a wrong schema string, an unknown member, a missing
#   member, a member named twice, a ratio on a cell that has none, a verdict
#   that does not follow from the ratio, a summary that is not the cells'
#   summary, an id outside its suite, a float where an integer is required,
#   text that is not JSON and text after the document; each altered text is
#   checked to differ from the original, so an edit that matches nothing fails.
# - test_writer_refuses: a result the schema forbids is not written: a path
#   or a host-like name in the fingerprint, a PINNED duckdb without a digest, an
#   UNPINNED one without a reason, a repeated cell id, a komira side on a cell
#   whose run was refused, a side whose time is not the least of its sweeps.

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
    parse_result_json,
    write_result_json,
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


def _refused(text: String) -> Bool:
    try:
        _ = parse_result_json(text)
    except:
        return True
    return False


def _altered(good: String, old: String, new: String) raises -> String:
    var bad = good.replace(old, new)
    assert_true(bad != good)
    return bad^


def _write_refused(r: BenchResult) -> Bool:
    try:
        _ = write_result_json(r)
    except:
        return True
    return False


def test_round_trip() raises:
    var text = write_result_json(_sample())
    var back = parse_result_json(text)
    assert_equal(write_result_json(back), text)
    assert_equal(len(back.cells), 5)
    assert_equal(back.cells[0].id, String("tpch/q01"))
    assert_equal(back.cells[0].ratio.value(), 1.5)
    assert_equal(back.cells[0].komira.value().ms, 3.0)
    assert_equal(back.cells[0].komira.value().ms_per_sweep[0], 5.0)
    assert_equal(back.cells[0].duckdb.value().ms, 2.0)
    assert_true(not Bool(back.cells[2].ratio))
    assert_equal(back.cells[2].value.text(), String("DIVERGENT"))
    assert_equal(back.cells[3].stage.text(), String("UNSUPPORTED:window frame"))
    assert_true(not Bool(back.cells[3].komira))
    assert_equal(back.cells[3].value.text(), String("UNVERIFIED:not run"))
    assert_equal(back.run.pass_max, 1.05)
    assert_equal(back.run.scale_kind, String("sf"))
    assert_equal(back.run.scale_value, 10)
    assert_equal(back.env.hostclass, String("bench-class-a"))
    assert_equal(back.env.duckdb.pin, String("PINNED"))
    assert_equal(back.env.duckdb.sha256, _hex(String("ab")))
    assert_equal(back.env.dataset_lock_sha256, _hex(String("a1b2c3d4")))
    assert_equal(back.env.mem_total_bytes, 137438953472)


def test_text_shape() raises:
    var text = write_result_json(_sample())
    assert_true(text.find(String("\n")) < 0)
    assert_true(text.startswith(String('{"schema":"komira-bench-result/1","run":')))
    assert_true(text.find(String('"scale":{"sf":10}')) >= 0)
    assert_true(text.find(String('"summary":{')) >= 0)


def test_reader_refuses() raises:
    var good = write_result_json(_sample())
    assert_true(not _refused(good))
    assert_true(_refused(_altered(good, String("komira-bench-result/1"), String("komira-bench-result/2"))))
    assert_true(_refused(_altered(good, String('"threads":20'), String('"threads":20,"extra":1'))))
    assert_true(_refused(_altered(good, String('"threads":20,'), String(""))))
    assert_true(_refused(_altered(good, String('"reps":4,"statistic"'), String('"reps":4,"reps":4,"statistic"'))))
    assert_true(_refused(_altered(good, String('"verdict":"FAIL"'), String('"verdict":"PASS"'))))
    assert_true(_refused(_altered(good, String('"n_pass":2'), String('"n_pass":3'))))
    assert_true(_refused(_altered(good, String('"id":"tpch/q02"'), String('"id":"q02"'))))
    assert_true(_refused(_altered(good, String('"threads":20'), String('"threads":20.0'))))
    assert_true(_refused(_altered(good, String("bench-class-a"), String("node/7"))))
    assert_true(_refused(String("{")))
    assert_true(_refused(good + String("x")))


def test_reader_refuses_a_ratio_on_an_unverified_cell() raises:
    var r = _sample()
    # The divergent cell of the sample, given the ratio its times would make.
    r.cells[2].ratio = Optional[Float64](0.25)
    r.cells[2].verdict = String("PASS")
    assert_true(_write_refused(r))
    var good = write_result_json(_sample())
    var old = String('"ratio":null,"verdict":"NO_RATIO"')
    var at = good.find(old)
    assert_true(at >= 0)
    var tampered = (
        String(good[byte=0:at])
        + String('"ratio":0.25,"verdict":"PASS"')
        + String(good[byte = at + old.byte_length() : good.byte_length()])
    )
    assert_true(tampered != good)
    assert_true(_refused(tampered))


def test_writer_refuses() raises:
    assert_true(not _write_refused(_sample()))
    var r = _sample()
    r.env.cpu_model = String("cpu at /proc/cpuinfo")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.hostclass = String("Node-01.example")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.duckdb.sha256 = String("abc")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.duckdb.pin = String("UNPINNED:")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.duckdb.pin = String("UNPINNED:local build")
    r.env.duckdb.sha256 = String("")
    assert_true(not _write_refused(r))
    r = _sample()
    r.cells[1].id = r.cells[0].id.copy()
    assert_true(_write_refused(r))
    r = _sample()
    r.cells[3].komira = _side(100, 8.0, 8.0)
    assert_true(_write_refused(r))
    var raised = False
    try:
        var sweeps = List[Float64]()
        sweeps.append(5.0)
        sweeps.append(3.0)
        _ = Side(1, 5.0, sweeps^, 66.66666666666666)
    except:
        raised = True
    assert_true(raised)


def main() raises:
    var failed = String("")
    try:
        test_round_trip()
    except e:
        failed += "\n  test_round_trip: " + String(e)
    try:
        test_text_shape()
    except e:
        failed += "\n  test_text_shape: " + String(e)
    try:
        test_reader_refuses()
    except e:
        failed += "\n  test_reader_refuses: " + String(e)
    try:
        test_reader_refuses_a_ratio_on_an_unverified_cell()
    except e:
        failed += "\n  test_reader_refuses_a_ratio_on_an_unverified_cell: " + String(e)
    try:
        test_writer_refuses()
    except e:
        failed += "\n  test_writer_refuses: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_json_schema: FAILED" + failed)
    print("test_json_schema: OK")
