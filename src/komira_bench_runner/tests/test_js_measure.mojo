# The optional summary line (`--js-measure-result`), from a result value; no
# process is started and no time is measured: every number is one the test put
# in the cell.
#
# What each test proves:
# - test_a_pass_cell_gives_the_line_in_its_exact_shape: a timed cell whose
#   komira steady state is 1.5 ms, first run 12.25 ms and DuckDB steady state
#   2.5 ms (ratio 0.6, verdict PASS) gives exactly
#   `js-measure-result {"steady_ms":1.5,"first_run_ms":12.25,"duckdb_steady_ms":2.5,"verdict":"PASS"}`,
#   one line, and the JSON after the prefix parses.
# - test_a_value_the_run_did_not_produce_is_null_never_zero: a refused query
#   has null for komira's steady state and first run and DuckDB's time as
#   measured, verdict NO_RATIO; a timed cell without a first run has null
#   there only; a wrong answer is not timed, so its check run is not given as
#   a first run and all three times are null.
# - test_a_timed_cell_gives_its_first_run_not_a_check_run: a timed cell that
#   also carries check runs gives komira's `first_run.ms` as `first_run_ms`.
# - test_a_failing_line_does_not_hide_the_report: with the flag and a result
#   of two queries (no single line), the console text is still the report,
#   followed by one `error: js-measure-result` line, and no line with the
#   prefix.
# - test_the_flag_is_read_and_given_once: the flag takes no value, is off by
#   default, and does not swallow the flag after it; given twice it is an error.
# - test_without_the_flag_the_console_text_is_the_report_alone: the text is
#   exactly the report, with no summary line anywhere in it.
# - test_with_the_flag_the_line_is_the_last_line_of_the_console_text: the
#   report comes first unchanged, the summary line is the final line and no
#   other line starts with the prefix, so nothing follows it once printed.
# - test_the_line_is_under_8_kib: the line of a cell is far under the limit.
# - test_the_dataset_scale_and_query_ids_of_the_example_are_known: the dataset
#   `tpch` at scale `sf1` has a manifest, the scale spelled `1` does not, and
#   `tpch/q6` is a query of the corpus on the dataset `tpch`.

from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_bench_corpus import find_query
from komira_bench_data import find_manifest
from komira_bench_duckdb import FairnessSettings, OrderKey
from komira_bench_report import (
    BenchResult,
    Cell,
    CheckRuns,
    DuckDbPin,
    Environment,
    FirstRun,
    RunInfo,
    STATISTIC_MIN_OF_SWEEP_MEDIAN,
    Side,
    StageOutcome,
    ValueVerdict,
)
from komira_json import parse_json_value

from komira_bench_runner import (
    JS_MEASURE_MAX_BYTES,
    JS_MEASURE_PREFIX,
    QueryOutcome,
    QuerySpec,
    RunFlags,
    RunOutput,
    console_text,
    format_run,
    js_measure_line,
    js_measure_line_of,
    parse_flags,
)

comptime _SHA = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"


def _side(ms: Float64, first: Optional[Float64]) raises -> Side:
    var reps = List[Float64]()
    reps.append(ms)
    reps.append(ms)
    reps.append(ms)
    var sweeps = List[List[Float64]]()
    sweeps.append(reps^)
    return Side.from_sweeps(Int64(1), sweeps^, first)


def _timed(komira_first: Optional[Float64]) raises -> Cell:
    return Cell.build(
        String("q6"),
        String("tpch"),
        3,
        StageOutcome(String("EXEC_OK"), String("")),
        Optional[Side](_side(1.5, komira_first)),
        Optional[Side](_side(2.5, Optional[Float64](20.5))),
        ValueVerdict.identical(),
        1.0,
    )


def _unserved() raises -> Cell:
    return Cell.build(
        String("q6"),
        String("tpch"),
        3,
        StageOutcome(String("UNSUPPORTED"), String("joins")),
        Optional[Side](),
        Optional[Side](_side(2.5, Optional[Float64](20.5))),
        ValueVerdict.unverified(String("komira did not run")),
        1.0,
    )


def _wrong_answer() raises -> Cell:
    return Cell.build(
        String("q6"),
        String("tpch"),
        3,
        StageOutcome(String("EXEC_FAIL"), String("")),
        Optional[Side](),
        Optional[Side](),
        ValueVerdict.divergent(),
        1.0,
        Optional[CheckRuns](
            CheckRuns(
                Optional[FirstRun](FirstRun(40.5, Optional[Int64](), Optional[Int64]())),
                Optional[FirstRun](FirstRun(30.25, Optional[Int64](), Optional[Int64]())),
            )
        ),
    )


def _result(var cell: Cell) raises -> BenchResult:
    var cells = List[Cell]()
    cells.append(cell^)
    return BenchResult(
        RunInfo(String("both"), String("sf"), Int64(1), 1, 3, String(STATISTIC_MIN_OF_SWEEP_MEDIAN), Int64(4), 1.0),
        Environment(
            String("test-class"),
            String("test cpu"),
            Int64(4),
            Int64(17179869184),
            String("linux"),
            String("0.0.0-test"),
            DuckDbPin(String("1.5.6"), String(_SHA), String("PINNED")),
            String(_SHA),
        ),
        cells^,
    )


def _output(var cell: Cell) raises -> RunOutput:
    var fairness = FairnessSettings(4, 16384)
    fairness.threads_readback = String("4")
    fairness.memory_limit_readback = String("16.0 KiB")
    fairness.version = String("v1.5.6")
    var queries = List[QuerySpec]()
    queries.append(QuerySpec(String("tpch"), String("q6"), String("tpch"), String("select 1"), List[OrderKey]()))
    return RunOutput(
        _result(cell^), Optional[BenchResult](), String(""), List[QueryOutcome](), fairness^, queries^
    )


def _lines(text: String) -> List[String]:
    var out = List[String]()
    for line in text.split("\n"):
        out.append(String(line))
    return out^


def test_a_pass_cell_gives_the_line_in_its_exact_shape() raises:
    var cell = _timed(Optional[Float64](12.25))
    assert_equal(cell.verdict, String("PASS"))
    var line = js_measure_line(cell)
    assert_equal(
        line,
        String('js-measure-result {"steady_ms":1.5,"first_run_ms":12.25,"duckdb_steady_ms":2.5,"verdict":"PASS"}'),
    )
    assert_equal(line, js_measure_line_of(_result(cell.copy())))
    assert_false(line.find(String("\n")) >= 0)
    var json = parse_json_value(String(line[byte = JS_MEASURE_PREFIX.byte_length() : line.byte_length()]))
    assert_true(json.is_object())


def test_a_value_the_run_did_not_produce_is_null_never_zero() raises:
    assert_equal(
        js_measure_line(_unserved()),
        String('js-measure-result {"steady_ms":null,"first_run_ms":null,"duckdb_steady_ms":2.5,"verdict":"NO_RATIO"}'),
    )
    var no_first = js_measure_line(_timed(Optional[Float64]()))
    assert_true(no_first.find(String('"steady_ms":1.5,"first_run_ms":null,"duckdb_steady_ms":2.5')) >= 0)
    assert_equal(
        js_measure_line(_wrong_answer()),
        String('js-measure-result {"steady_ms":null,"first_run_ms":null,"duckdb_steady_ms":null,"verdict":"NO_RATIO"}'),
    )
    assert_false(js_measure_line(_unserved()).find(String(":0,")) >= 0)
    assert_false(js_measure_line(_wrong_answer()).find(String(":0,")) >= 0)


def test_a_timed_cell_gives_its_first_run_not_a_check_run() raises:
    var cell = Cell.build(
        String("q6"),
        String("tpch"),
        3,
        StageOutcome(String("EXEC_OK"), String("")),
        Optional[Side](_side(1.5, Optional[Float64](12.25))),
        Optional[Side](_side(2.5, Optional[Float64](20.5))),
        ValueVerdict.identical(),
        1.0,
        Optional[CheckRuns](
            CheckRuns(
                Optional[FirstRun](FirstRun(40.5, Optional[Int64](), Optional[Int64]())),
                Optional[FirstRun](FirstRun(30.25, Optional[Int64](), Optional[Int64]())),
            )
        ),
    )
    assert_equal(
        js_measure_line(cell),
        String('js-measure-result {"steady_ms":1.5,"first_run_ms":12.25,"duckdb_steady_ms":2.5,"verdict":"PASS"}'),
    )


def _base_args() -> List[String]:
    var a = List[String]()
    for s in [
        "--duckdb", "/d", "--cache-dir", "/c", "--out-dir", "/o", "--dataset", "tpch", "--scale", "sf1",
        "--suite", "tpch", "--query", "q6", "--sql-file", "/q.sql", "--hostclass", "h", "--cpu-model", "m",
        "--os", "linux", "--komira-version", "v", "--cores", "4", "--mem-bytes", "17179869184",
    ]:
        a.append(String(s))
    return a^


def test_the_flag_is_read_and_given_once() raises:
    assert_false(parse_flags(_base_args()).js_measure_result)
    var first = _base_args()
    first.insert(0, String("--js-measure-result"))
    assert_true(parse_flags(first).js_measure_result)
    var middle = _base_args()
    middle.insert(4, String("--js-measure-result"))
    var f = parse_flags(middle)
    assert_true(f.js_measure_result)
    assert_equal(f.cache_dir, String("/c"))
    assert_equal(f.out_dir, String("/o"))
    var last = _base_args()
    last.append(String("--js-measure-result"))
    assert_true(parse_flags(last).js_measure_result)
    var twice = _base_args()
    twice.append(String("--js-measure-result"))
    twice.append(String("--js-measure-result"))
    with assert_raises(contains="given twice"):
        _ = parse_flags(twice)


def test_without_the_flag_the_console_text_is_the_report_alone() raises:
    var out = _output(_timed(Optional[Float64](12.25)))
    var text = console_text(out, False)
    assert_equal(text, format_run(out))
    assert_false(text.find(String("js-measure-result")) >= 0)


def test_with_the_flag_the_line_is_the_last_line_of_the_console_text() raises:
    var out = _output(_timed(Optional[Float64](12.25)))
    var report = format_run(out)
    var text = console_text(out, True)
    assert_true(text.startswith(report))
    var printed = text + String("\n")  # what print writes
    var lines = _lines(printed)
    assert_equal(lines[len(lines) - 1], String(""))
    var last = lines[len(lines) - 2].copy()
    assert_equal(last, js_measure_line_of(out.warm))
    var count = 0
    for i in range(len(lines)):
        if lines[i].startswith(JS_MEASURE_PREFIX):
            count += 1
    assert_equal(count, 1)
    assert_true(printed.as_bytes()[printed.byte_length() - 1] == 0x0A)


def test_a_failing_line_does_not_hide_the_report() raises:
    var out = _output(_timed(Optional[Float64](12.25)))
    var cells = List[Cell]()
    cells.append(_timed(Optional[Float64](12.25)))
    cells.append(_timed(Optional[Float64](12.25)))
    var two = _result(_timed(Optional[Float64](12.25)))
    two.cells = cells^
    out.warm = two^
    var report = format_run(out)
    var text = console_text(out, True)
    assert_true(text.startswith(report))
    assert_true(text.find(String("\nerror: js-measure-result")) >= 0)
    assert_true(text.find(String("exactly one query")) >= 0)
    for line in _lines(text):
        assert_false(line.startswith(JS_MEASURE_PREFIX))


def test_the_line_is_under_8_kib() raises:
    assert_true(js_measure_line(_timed(Optional[Float64](12.25))).byte_length() < JS_MEASURE_MAX_BYTES)
    assert_equal(JS_MEASURE_MAX_BYTES, 8192)


def test_the_dataset_scale_and_query_ids_of_the_example_are_known() raises:
    var manifest = find_manifest(String("tpch"), String("sf1"))
    assert_equal(manifest.name, String("tpch"))
    with assert_raises(contains="no dataset tpch/1"):
        _ = find_manifest(String("tpch"), String("1"))
    var q = find_query(String("tpch/q6"))
    assert_equal(q.dataset, manifest.name)
    assert_equal(q.key(), String("tpch/q6"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
