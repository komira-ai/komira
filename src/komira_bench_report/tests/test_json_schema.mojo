# The schema of result.json: what the writer writes, what the reader accepts,
# and each way the reader refuses a document.
#
# What each case proves:
# - test_round_trip: write, read, write gives the same text, and every field
#   comes back (a refused cell keeps its stage and has no komira side, a
#   divergent cell has no ratio, the DuckDB pin and dataset lock survive).
# - test_text_shape: one line, the schema string first, the scale as a
#   one-member object.
# - test_runs_and_faults_round_trip: every run of every sweep is in the file
#   with rep 0 first (`runs_ms`), the minor and major page faults of each run
#   are beside them where they were measured and null where they were not, a
#   cell carries its first-run ratio, and all of it reads back unchanged.
# - test_reader_reads_schema_1: a document of schema `komira-bench-result/1`
#   (no runs, no faults, no first-run ratio, a summary without first-run
#   figures and with "geomean"/"median" in the headline) is read: its
#   steady-state times and ratios are as written, its sides have no runs and
#   its cells no first-run ratio. The writer does not rewrite it: a side
#   without its runs is refused, so a result read from schema 1 is never
#   written as schema 2. A schema 2 document that lacks `runs_ms`, and a
#   schema 1 document that has it, are refused.
# - test_reader_refuses_runs_and_faults_that_do_not_fit: runs that are not
#   the run's sweeps by reps, runs whose medians are not `ms_per_sweep`, a
#   negative fault count, faults of the wrong shape, minor faults without major
#   ones, and a first-run ratio that is not the first runs' ratio are each
#   refused.
# - test_writer_refuses_runs_that_do_not_fit: the same checks when the result
#   is written: a side with fewer runs than the run's reps, faults of the
#   wrong shape and a negative fault count are not written.
# - test_reader_refuses: a wrong schema string, an unknown member, a missing
#   member, a member named twice, a ratio on a cell that has none, a verdict
#   that does not follow from the ratio, a summary that is not the cells'
#   summary, an id outside its suite, a float where an integer is required,
#   text that is not JSON and text after the document; each altered text is
#   checked to differ from the original, so an edit that matches nothing fails.
# - test_writer_refuses: a result the schema forbids is not written: a path
#   or a host-like name in the fingerprint, a PINNED duckdb without a digest, an
#   UNPINNED one without a reason, a repeated cell id, a komira side on a cell
#   whose run was refused, a side whose time is not the least of its sweeps,
#   a comparison with no DuckDB side or with unequal row counts, a mode that
#   disagrees with the sides present, a control character in a cell id, and a
#   path or an address in any free-text field of the fingerprint.
# - test_reader_tolerates_the_last_digits_of_the_geomean: a geomean that
#   differs from the recomputed one by far less than 1e-9 is read, a larger
#   difference is refused, and so is a headline whose geomean figure belongs
#   to neither value.
# - test_reader_compares_the_rest_of_the_headline: a stored headline whose
#   PASS count differs from the cells' is refused although its geomean figure
#   is right.
# - test_compared_cells_need_a_run_of_mode_both: a run of mode duckdb refuses
#   a cell whose values were compared and accepts the same cell unverified.
# - test_control_characters_are_refused_in_free_text: a control character in
#   the operating system text or in the detail of an UNSUPPORTED or an
#   UNVERIFIED cell is refused.
# - test_environment_accepts_the_spaced_at_of_cpuinfo: the CPU model strings
#   /proc/cpuinfo writes for Intel parts ("... CPU E5-4669 v4 @ 2.20GHz") and
#   one with no at sign are written, in cpu_model and in os, and read back.
# - test_environment_refuses_addresses_paths_and_controls: an at sign that is
#   not spaced on both sides (user@host, a@b.c, at either end, a space on one
#   side only), a slash, a backslash and a control character are refused in
#   cpu_model and in os, by the writer and by the reader; a spaced at sign
#   next to one of those is still refused.
# - test_details_refuse_paths: the construct of UNSUPPORTED and the cause of
#   UNVERIFIED are text about the cell, never a place on a machine.

from std.testing import assert_equal, assert_true

from komira_json import JsonValue, parse_json_value

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
    summarize,
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


# The same, with the first run of the first sweep `first` instead of 99.
def _side_first(rows: Int64, first: Float64, m1: Float64, m2: Float64) raises -> Optional[Side]:
    return Optional[Side](
        Side.from_sweeps(rows, _sweeps(first, m1, m1, m1, 99.0, m2, m2, m2))
    )


# Two sweeps of four counts, rep 0 first.
def _counts(
    a0: Int64, a1: Int64, a2: Int64, a3: Int64,
    b0: Int64, b1: Int64, b2: Int64, b3: Int64,
) -> List[List[Int64]]:
    var first = List[Int64]()
    first.append(a0)
    first.append(a1)
    first.append(a2)
    first.append(a3)
    var second = List[Int64]()
    second.append(b0)
    second.append(b1)
    second.append(b2)
    second.append(b3)
    var out = List[List[Int64]]()
    out.append(first^)
    out.append(second^)
    return out^


# The page faults of a side's eight runs: a first run that faults a great deal,
# then a few hundred.
def _minor() -> List[List[Int64]]:
    return _counts(5000, 900, 900, 900, 800, 800, 800, 800)


def _major() -> List[List[Int64]]:
    return _counts(2, 0, 0, 0, 0, 0, 0, 0)


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
    # komira sweeps (99,4,6,5) and (99,3,3,3): medians 5 and 3, time 3; its
    # first run is 99 against DuckDB's 33, and it has page faults per run.
    var q01k = Side.from_sweeps(
        4, _sweeps(99.0, 4.0, 6.0, 5.0, 99.0, 3.0, 3.0, 3.0), _minor(), _major()
    )
    cells.append(_cell(String("tpch/q01"), String("tpch"), StageOutcome.exec_ok(),
        Optional[Side](q01k^), _side_first(4, 33.0, 2.0, 4.0), ValueVerdict.identical()))
    # DuckDB has page faults per run here, komira does not.
    var q02d = Side.from_sweeps(
        10, _sweeps(99.0, 2.0, 2.0, 2.0, 99.0, 2.0, 2.0, 2.0), _minor(), _major()
    )
    cells.append(_cell(String("tpch/q02"), String("tpch"), StageOutcome.exec_ok(),
        _side(10, 2.0, 2.0), Optional[Side](q02d^), ValueVerdict.identical()))
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
    assert_true(text.find(String("warmup_runs")) < 0)
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
    assert_true(text.startswith(String('{"schema":"komira-bench-result/2","run":')))
    assert_true(text.find(String('"scale":{"sf":10}')) >= 0)
    assert_true(text.find(String('"summary":{')) >= 0)


def test_runs_and_faults_round_trip() raises:
    var text = write_result_json(_sample())
    var back = parse_result_json(text)
    assert_equal(write_result_json(back), text)
    ref k = back.cells[0].komira.value()
    # every run of every sweep, rep 0 first, is kept
    assert_equal(len(k.runs_ms), 2)
    assert_equal(len(k.runs_ms[0]), 4)
    assert_equal(len(k.runs_ms[1]), 4)
    assert_equal(k.runs_ms[0][0], 99.0)
    assert_equal(k.runs_ms[0][1], 4.0)
    assert_equal(k.runs_ms[0][3], 5.0)
    assert_equal(k.runs_ms[1][0], 99.0)
    assert_equal(k.first_ms().value(), 99.0)
    # the faults of each run
    assert_equal(len(k.minor_faults), 2)
    assert_equal(k.minor_faults[0][0], Int64(5000))
    assert_equal(k.minor_faults[0][1], Int64(900))
    assert_equal(k.minor_faults[1][3], Int64(800))
    assert_equal(k.major_faults[0][0], Int64(2))
    assert_equal(k.major_faults[1][0], Int64(0))
    # a side measured without counters says so
    assert_equal(len(back.cells[0].duckdb.value().minor_faults), 0)
    assert_equal(len(back.cells[0].duckdb.value().major_faults), 0)
    assert_equal(len(back.cells[1].duckdb.value().minor_faults), 2)
    assert_true(text.find(String('"minor_faults":null,"major_faults":null')) >= 0)
    # the first-run ratio of each cell, beside its steady-state ratio
    assert_equal(back.cells[0].ratio.value(), 1.5)
    assert_equal(back.cells[0].first_ratio.value(), 3.0)
    assert_equal(back.cells[1].first_ratio.value(), 1.0)
    assert_true(not Bool(back.cells[2].first_ratio))
    assert_true(not Bool(back.cells[3].first_ratio))
    assert_true(text.find(String('"first_ratio":null')) >= 0)
    assert_true(text.find(String('"geomean_first_run":')) >= 0)
    assert_true(text.find(String("steady-state geomean")) >= 0)
    assert_true(text.find(String("first-run geomean")) >= 0)


def _value_end(text: String, at: Int) -> Int:
    """The index just past the JSON value that starts at `at`: an array to its
    matching bracket, anything else to the next comma or closing brace."""
    var b = text.as_bytes()
    var i = at
    if b[i] == 0x5B:
        var depth = 0
        while True:
            if b[i] == 0x5B:
                depth += 1
            elif b[i] == 0x5D:
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
    while b[i] != 0x2C and b[i] != 0x7D:
        i += 1
    return i


def _nth_member(text: String, key: String, nth: Int) raises -> Int:
    """The index of the `nth` (from 0) `"key":` in `text`."""
    var needle = String('"') + key + String('":')
    var at = -1
    for _ in range(nth + 1):
        at = text.find(needle, at + 1)
        assert_true(at >= 0)
    return at


def _set_member(text: String, key: String, nth: Int, value: String) raises -> String:
    """`text` with the value of the `nth` member named `key` replaced."""
    var at = _nth_member(text, key, nth) + key.byte_length() + 3
    var out = (
        String(text[byte=0:at]) + value
        + String(text[byte = _value_end(text, at) : text.byte_length()])
    )
    assert_true(out != text)
    return out^


def _cut_all(text: String, key: String) raises -> String:
    """`text` without every member named `key` (each preceded by a comma)."""
    var needle = String(',"') + key + String('":')
    var out = text.copy()
    var at = out.find(needle)
    assert_true(at >= 0)
    while at >= 0:
        var end = _value_end(out, at + needle.byte_length())
        out = String(out[byte=0:at]) + String(out[byte = end : out.byte_length()])
        at = out.find(needle)
    return out^


def _as_schema_1(text: String) raises -> String:
    """The document schema 1 would have written for the same result: no runs,
    no faults, no first-run ratio or figures, and the headline's geomean and
    median not called steady-state."""
    var t = _altered(text, String("komira-bench-result/2"), String("komira-bench-result/1"))
    t = _cut_all(t, String("runs_ms"))
    t = _cut_all(t, String("minor_faults"))
    t = _cut_all(t, String("major_faults"))
    t = _cut_all(t, String("first_ratio"))
    t = _cut_all(t, String("n_first_ratio"))
    t = _cut_all(t, String("geomean_first_run"))
    t = _cut_all(t, String("median_first_run"))
    t = t.replace(String("steady-state geomean"), String("geomean"))
    t = t.replace(String("steady-state median"), String("median"))
    var from_at = t.find(String(" | first-run geomean"))
    assert_true(from_at >= 0)
    while from_at >= 0:
        var to_at = t.find(String('"'), from_at)
        t = String(t[byte=0:from_at]) + String(t[byte = to_at : t.byte_length()])
        from_at = t.find(String(" | first-run geomean"))
    return t^


def test_reader_reads_schema_1() raises:
    var good = write_result_json(_sample())
    var old = _as_schema_1(good)
    assert_true(old.find(String("runs_ms")) < 0)
    assert_true(old.find(String("first")) < 0)
    var back = parse_result_json(old)
    assert_equal(back.cells[0].id, String("tpch/q01"))
    assert_equal(back.cells[0].komira.value().ms, 3.0)
    assert_equal(back.cells[0].duckdb.value().ms, 2.0)
    assert_equal(back.cells[0].ratio.value(), 1.5)
    assert_equal(back.cells[0].verdict, String("FAIL"))
    assert_equal(back.cells[0].komira.value().ms_per_sweep[0], 5.0)
    assert_equal(len(back.cells[0].komira.value().runs_ms), 0)
    assert_equal(len(back.cells[0].komira.value().minor_faults), 0)
    assert_true(not Bool(back.cells[0].komira.value().first_ms()))
    assert_true(not Bool(back.cells[0].first_ratio))
    assert_true(not Bool(back.cells[1].first_ratio))
    assert_true(not Bool(summarize(back).overall.geomean_first))
    assert_equal(back.run.pass_max, 1.05)
    # it is not rewritten as schema 2: its sides have no runs to write
    assert_true(_write_refused(back))
    # a schema 2 document without the runs, and a schema 1 document with them
    assert_true(_refused(_cut_all(good, String("runs_ms"))))
    assert_true(_refused(_altered(good, String("komira-bench-result/2"), String("komira-bench-result/1"))))
    assert_true(_refused(_altered(old, String("komira-bench-result/1"), String("komira-bench-result/0"))))


def test_reader_refuses_runs_and_faults_that_do_not_fit() raises:
    var good = write_result_json(_sample())
    # one sweep of runs where the run has two
    assert_true(_refused(_set_member(good, String("runs_ms"), 0, String("[[99.0,4.0,6.0,5.0]]"))))
    # a sweep with three runs where the run has four reps
    assert_true(_refused(_set_member(good, String("runs_ms"), 0, String("[[99.0,4.0,6.0],[99.0,3.0,3.0,3.0]]"))))
    # runs whose medians are not ms_per_sweep (50 and 3 against 5 and 3)
    assert_true(_refused(_set_member(good, String("runs_ms"), 0, String("[[99.0,40.0,60.0,50.0],[99.0,3.0,3.0,3.0]]"))))
    # a negative count, a count of the wrong shape, minor without major
    assert_true(_refused(_set_member(good, String("minor_faults"), 0, String("[[-1,0,0,0],[0,0,0,0]]"))))
    assert_true(_refused(_set_member(good, String("major_faults"), 0, String("[[2,0,0],[0,0,0,0]]"))))
    assert_true(_refused(_set_member(good, String("major_faults"), 0, String("null"))))
    assert_true(_refused(_set_member(good, String("minor_faults"), 0, String('[[1.5,0,0,0],[0,0,0,0]]'))))
    # a first-run ratio that is not komira's first run over DuckDB's
    assert_true(_refused(_set_member(good, String("first_ratio"), 0, String("7.5"))))
    assert_true(_refused(_set_member(good, String("first_ratio"), 0, String("null"))))
    assert_true(not _refused(good))


def test_writer_refuses_runs_that_do_not_fit() raises:
    assert_true(not _write_refused(_sample()))
    # the run says five reps, the sides hold four runs per sweep
    var r = _sample()
    r.run.reps = 5
    for i in range(len(r.cells)):
        r.cells[i].reps = 5
    assert_true(_write_refused(r))
    # faults of the wrong shape, a negative count, minor faults without major
    var sweeps = _sweeps(99.0, 4.0, 6.0, 5.0, 99.0, 3.0, 3.0, 3.0)
    var short = List[List[Int64]]()
    short.append(_minor()[0].copy())
    r = _sample()
    r.cells[0].komira = Optional[Side](Side.from_sweeps(4, sweeps.copy(), short^, _major()))
    assert_true(_write_refused(r))
    r = _sample()
    r.cells[0].komira = Optional[Side](
        Side.from_sweeps(4, sweeps.copy(), _counts(5000, 900, 900, 900, 800, 800, -3, 800), _major())
    )
    assert_true(_write_refused(r))
    r = _sample()
    r.cells[0].komira = Optional[Side](Side.from_sweeps(4, sweeps.copy(), _minor()))
    assert_true(_write_refused(r))
    # the same side, shaped right, is written
    r = _sample()
    r.cells[0].komira = Optional[Side](Side.from_sweeps(4, sweeps.copy(), _minor(), _major()))
    assert_true(not _write_refused(r))
    # a side with no runs at all (the shape schema 1 held) is not written
    var medians = List[Float64]()
    medians.append(1.0)
    medians.append(1.0)
    r = _sample()
    r.cells[4] = _cell(String("clickbench/q02"), String("clickbench"), StageOutcome.exec_ok(),
        Optional[Side](Side(43, 1.0, medians^, 0.0)), _side(43, 2.0, 2.0), ValueVerdict.identical())
    assert_true(_write_refused(r))


def test_reader_refuses() raises:
    var good = write_result_json(_sample())
    assert_true(not _refused(good))
    assert_true(_refused(_altered(good, String("komira-bench-result/2"), String("komira-bench-result/3"))))
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


def _no_ref_cell(value: ValueVerdict) raises -> Cell:
    return _cell(String("tpch/q09"), String("tpch"), StageOutcome.exec_ok(),
        _side(5, 1.0, 1.0), Optional[Side](), value)


def test_writer_refuses_contradictory_cells() raises:
    var r = _sample()
    r.cells[1] = _no_ref_cell(ValueVerdict.identical())
    r.cells[1].id = String("tpch/q02")
    assert_true(_write_refused(r))
    r = _sample()
    r.cells[1] = _no_ref_cell(ValueVerdict.divergent())
    r.cells[1].id = String("tpch/q02")
    assert_true(_write_refused(r))
    r = _sample()
    r.cells[1] = _cell(String("tpch/q02"), String("tpch"), StageOutcome.exec_ok(),
        _side(10, 2.0, 2.0), _side(11, 2.0, 2.0), ValueVerdict.identical())
    assert_true(_write_refused(r))
    r = _sample()
    r.cells[1] = _cell(String("tpch/q02"), String("tpch"), StageOutcome.exec_ok(),
        _side(10, 2.0, 2.0), _side(11, 2.0, 2.0), ValueVerdict.divergent())
    assert_true(not _write_refused(r))
    # mode both: a cell komira ran needs the reference side.
    r = _sample()
    r.cells[1] = _no_ref_cell(ValueVerdict.unverified(String("no reference")))
    r.cells[1].id = String("tpch/q02")
    assert_true(_write_refused(r))
    # mode komira: no DuckDB side anywhere and nothing compared is allowed.
    r = _sample()
    r.run.mode = String("komira")
    assert_true(_write_refused(r))
    var cells = List[Cell]()
    cells.append(_no_ref_cell(ValueVerdict.unverified(String("komira only"))))
    r.cells = cells^
    assert_true(not _write_refused(r))
    r.cells[0].duckdb = _side(5, 1.0, 1.0)
    assert_true(_write_refused(r))
    r = _sample()
    r.cells[1].id = String("tpch/q\n02")
    assert_true(_write_refused(r))


def test_writer_refuses_host_identifying_text() raises:
    var r = _sample()
    r.env.hostclass = String("buildbox7.corp.example.com")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.hostclass = String("192.0.2.7")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.hostclass = String("c7i-4xlarge")
    assert_true(not _write_refused(r))
    r = _sample()
    r.env.cpu_model = String("user@host Example CPU")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.os = String("Linux /usr/lib")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.os = String("Linux box@lab 6.1")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.komira_version = String("1.2.3 at /srv")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.duckdb.version = String("v1.5.6 \\build")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.duckdb.pin = String("UNPINNED:built in /opt")
    r.env.duckdb.sha256 = String("")
    assert_true(_write_refused(r))


def _cpu_written(cpu: String) raises -> Bool:
    var r = _sample()
    r.env.cpu_model = cpu
    return not _write_refused(r)


def _os_written(os: String) raises -> Bool:
    var r = _sample()
    r.env.os = os
    return not _write_refused(r)


def _cpu_read(cpu: String) raises -> Bool:
    var good = write_result_json(_sample())
    return not _refused(_altered(good, String("Example CPU 2.4GHz"), cpu))


def test_environment_accepts_the_spaced_at_of_cpuinfo() raises:
    var intel = String("Intel(R) Xeon(R) CPU E5-4669 v4 @ 2.20GHz")
    var platinum = String("Intel(R) Xeon(R) Platinum 8375C CPU @ 2.90GHz")
    var amd = String("AMD EPYC 7R13 48-Core Processor")
    assert_true(_cpu_written(intel))
    assert_true(_cpu_written(platinum))
    assert_true(_cpu_written(amd))
    assert_true(_os_written(intel))
    assert_true(_cpu_read(intel))
    assert_true(_cpu_read(platinum))
    assert_true(_cpu_read(amd))
    # The text survives the round trip unchanged.
    var r = _sample()
    r.env.cpu_model = intel
    var back = parse_result_json(write_result_json(r))
    assert_equal(back.env.cpu_model, intel)


def test_environment_refuses_addresses_paths_and_controls() raises:
    var bad = List[String]()
    bad.append(String("user@node"))
    bad.append(String("user@example.com"))
    bad.append(String("@host"))
    bad.append(String("@ host"))
    bad.append(String("cpu @"))
    bad.append(String("cpu@"))
    bad.append(String("a @b"))
    bad.append(String("a@ b"))
    bad.append(String("a @@ b"))
    bad.append(String("a @ b@c"))
    bad.append(String("a @ /proc/cpuinfo"))
    bad.append(String("a @ b\\c"))
    bad.append(String("/proc/cpuinfo"))
    bad.append(String("C:\\cpu"))
    bad.append(String("cpu\tmodel"))
    bad.append(String("cpu\nmodel"))
    for i in range(len(bad)):
        assert_true(not _cpu_written(bad[i]))
        assert_true(not _os_written(bad[i]))
    # The reader, through the text of a document: JSON-safe cases only.
    assert_true(not _cpu_read(String("user@node")))
    assert_true(not _cpu_read(String("a @b")))
    assert_true(not _cpu_read(String("cpu @")))
    assert_true(not _cpu_read(String("a @ /proc/cpuinfo")))


def test_details_refuse_paths() raises:
    var raised = False
    try:
        _ = StageOutcome.unsupported(String("window at /src/x.cc:3"))
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = ValueVerdict.unverified(String("read C:\\data\\x"))
    except:
        raised = True
    assert_true(raised)
    assert_equal(
        StageOutcome.unsupported(String("window frame")).text(),
        String("UNSUPPORTED:window frame"),
    )


def _with_number(text: String, key: String, start_at: Int, new: Float64) raises -> String:
    """`text` with the number after the first `key` at or past `start_at`
    replaced by `new`."""
    var at = text.find(key, start_at)
    assert_true(at >= 0)
    var from_at = at + key.byte_length()
    var to_at = from_at
    var b = text.as_bytes()
    while b[to_at] != 0x2C and b[to_at] != 0x7D:
        to_at += 1
    return (
        String(text[byte=0:from_at])
        + JsonValue.from_f64(new).serialize()
        + String(text[byte=to_at : text.byte_length()])
    )


def test_reader_tolerates_the_last_digits_of_the_geomean() raises:
    var good = write_result_json(_sample())
    var key = String('"geomean_ratio_verified":')
    var summary_at = good.find(String('"summary":{'))
    var at = good.find(key, summary_at) + key.byte_length()
    var to_at = at
    var b = good.as_bytes()
    while b[to_at] != 0x2C:
        to_at += 1
    var g = parse_json_value(String(good[byte=at:to_at])).as_float64()
    assert_true(not _refused(_with_number(good, key, summary_at, g * (1.0 + 1e-12))))
    assert_true(_refused(_with_number(good, key, summary_at, g * 1.01)))
    # The headline shows the geomean to two places: 0.91 is the figure.
    assert_true(_refused(_altered(good, String("steady-state geomean 0.91x"), String("steady-state geomean 0.92x"))))


def test_reader_compares_the_rest_of_the_headline() raises:
    var good = write_result_json(_sample())
    assert_true(not _refused(good))
    assert_true(_refused(_altered(good, String("PASS 2/5"), String("PASS 3/5"))))
    assert_true(_refused(_altered(good, String("<= 1.05x"), String("<= 1.50x"))))


def test_compared_cells_need_a_run_of_mode_both() raises:
    var r = _sample()
    r.run.mode = String("duckdb")
    var cells = List[Cell]()
    cells.append(_cell(String("tpch/q02"), String("tpch"), StageOutcome.exec_ok(),
        _side(10, 2.0, 2.0), _side(10, 2.0, 2.0), ValueVerdict.identical()))
    r.cells = cells^
    assert_true(_write_refused(r))
    r.cells[0] = _cell(String("tpch/q02"), String("tpch"), StageOutcome.exec_ok(),
        _side(10, 2.0, 2.0), _side(10, 2.0, 2.0), ValueVerdict.divergent())
    assert_true(_write_refused(r))
    r.cells[0] = _cell(String("tpch/q02"), String("tpch"), StageOutcome.exec_ok(),
        _side(10, 2.0, 2.0), _side(10, 2.0, 2.0), ValueVerdict.unverified(String("not compared")))
    assert_true(not _write_refused(r))


def test_control_characters_are_refused_in_free_text() raises:
    var r = _sample()
    r.env.os = String("Linux\n6.1")
    assert_true(_write_refused(r))
    r = _sample()
    r.env.cpu_model = String("Example\tCPU")
    assert_true(_write_refused(r))
    var raised = False
    try:
        _ = StageOutcome.unsupported(String("window\nframe"))
    except:
        raised = True
    assert_true(raised)
    raised = False
    try:
        _ = ValueVerdict.unverified(String("no\treference"))
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
        test_runs_and_faults_round_trip()
    except e:
        failed += "\n  test_runs_and_faults_round_trip: " + String(e)
    try:
        test_reader_reads_schema_1()
    except e:
        failed += "\n  test_reader_reads_schema_1: " + String(e)
    try:
        test_reader_refuses_runs_and_faults_that_do_not_fit()
    except e:
        failed += "\n  test_reader_refuses_runs_and_faults_that_do_not_fit: " + String(e)
    try:
        test_writer_refuses_runs_that_do_not_fit()
    except e:
        failed += "\n  test_writer_refuses_runs_that_do_not_fit: " + String(e)
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
    try:
        test_writer_refuses_contradictory_cells()
    except e:
        failed += "\n  test_writer_refuses_contradictory_cells: " + String(e)
    try:
        test_writer_refuses_host_identifying_text()
    except e:
        failed += "\n  test_writer_refuses_host_identifying_text: " + String(e)
    try:
        test_environment_accepts_the_spaced_at_of_cpuinfo()
    except e:
        failed += "\n  test_environment_accepts_the_spaced_at_of_cpuinfo: " + String(e)
    try:
        test_environment_refuses_addresses_paths_and_controls()
    except e:
        failed += "\n  test_environment_refuses_addresses_paths_and_controls: " + String(e)
    try:
        test_details_refuse_paths()
    except e:
        failed += "\n  test_details_refuse_paths: " + String(e)
    try:
        test_reader_tolerates_the_last_digits_of_the_geomean()
    except e:
        failed += "\n  test_reader_tolerates_the_last_digits_of_the_geomean: " + String(e)
    try:
        test_reader_compares_the_rest_of_the_headline()
    except e:
        failed += "\n  test_reader_compares_the_rest_of_the_headline: " + String(e)
    try:
        test_compared_cells_need_a_run_of_mode_both()
    except e:
        failed += "\n  test_compared_cells_need_a_run_of_mode_both: " + String(e)
    try:
        test_control_characters_are_refused_in_free_text()
    except e:
        failed += "\n  test_control_characters_are_refused_in_free_text: " + String(e)
    if failed.byte_length() > 0:
        raise Error("test_json_schema: FAILED" + failed)
    print("test_json_schema: OK")
