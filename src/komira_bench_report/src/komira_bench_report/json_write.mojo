# The writer of result.json (schema `komira-bench-result/2`). It writes the
# result as one compact line of JSON with the members in a fixed order, after
# `validate_result` has accepted it, and writes the summary the reader will
# recompute and compare. Every run of every side is written (`runs_ms`, with
# the page faults of each run beside it, and `first_run`: the check run executed
# before the sweeps, with its time and faults), so a side without its runs is not
# written: a result read from schema 1, which held no runs, is never rewritten
# as schema 2.

from komira_json import JsonValue

from .model import (
    BenchResult,
    Cell,
    DuckDbPin,
    Environment,
    RESULT_SCHEMA,
    FirstRun,
    RunInfo,
    Side,
    validate_result,
)
from .summary import Summary, SuiteSummary, summarize, summary_line


def _s(x: String) -> JsonValue:
    return JsonValue.from_string(x.copy())


def _i(x: Int64) -> JsonValue:
    return JsonValue.from_i64(x)


def _opt_f64(x: Optional[Float64]) -> JsonValue:
    if x:
        return JsonValue.from_f64(x.value())
    return JsonValue.null()


def _counts_json(counts: List[List[Int64]]) raises -> JsonValue:
    """The counts of each sweep as an array of arrays, or null when they were
    not measured (an empty list)."""
    if len(counts) == 0:
        return JsonValue.null()
    var sweeps = JsonValue.empty_array()
    for i in range(len(counts)):
        var one = JsonValue.empty_array()
        for j in range(len(counts[i])):
            one.push(_i(counts[i][j]))
        sweeps.push(one^)
    return sweeps^


def _side_json(side: Optional[Side]) raises -> JsonValue:
    if not side:
        return JsonValue.null()
    var o = JsonValue.empty_object()
    o.set_member(String("rows"), _i(side.value().rows))
    o.set_member(String("ms"), JsonValue.from_f64(side.value().ms))
    var sweeps = JsonValue.empty_array()
    for i in range(len(side.value().ms_per_sweep)):
        sweeps.push(JsonValue.from_f64(side.value().ms_per_sweep[i]))
    o.set_member(String("ms_per_sweep"), sweeps^)
    o.set_member(
        String("spread_pct"), JsonValue.from_f64(side.value().spread_pct)
    )
    var runs = JsonValue.empty_array()
    for i in range(len(side.value().runs_ms)):
        var one = JsonValue.empty_array()
        for j in range(len(side.value().runs_ms[i])):
            one.push(JsonValue.from_f64(side.value().runs_ms[i][j]))
        runs.push(one^)
    o.set_member(String("runs_ms"), runs^)
    o.set_member(String("minor_faults"), _counts_json(side.value().minor_faults))
    o.set_member(String("major_faults"), _counts_json(side.value().major_faults))
    var first = JsonValue.empty_object()
    first.set_member(String("ms"), JsonValue.from_f64(side.value().first.value()))
    if side.value().first_minor:
        first.set_member(String("minor_faults"), _i(side.value().first_minor.value()))
        first.set_member(String("major_faults"), _i(side.value().first_major.value()))
    else:
        first.set_member(String("minor_faults"), JsonValue.null())
        first.set_member(String("major_faults"), JsonValue.null())
    o.set_member(String("first_run"), first^)
    return o^


def _first_run_json(run: Optional[FirstRun]) raises -> JsonValue:
    if not run:
        return JsonValue.null()
    var o = JsonValue.empty_object()
    o.set_member(String("ms"), JsonValue.from_f64(run.value().ms))
    if run.value().minor:
        o.set_member(String("minor_faults"), _i(run.value().minor.value()))
        o.set_member(String("major_faults"), _i(run.value().major.value()))
    else:
        o.set_member(String("minor_faults"), JsonValue.null())
        o.set_member(String("major_faults"), JsonValue.null())
    return o^


def _check_runs_json(c: Cell) raises -> JsonValue:
    if not c.check_runs:
        return JsonValue.null()
    var o = JsonValue.empty_object()
    o.set_member(String("komira"), _first_run_json(c.check_runs.value().komira))
    o.set_member(String("duckdb"), _first_run_json(c.check_runs.value().duckdb))
    return o^


def _cell_json(c: Cell) raises -> JsonValue:
    var o = JsonValue.empty_object()
    o.set_member(String("id"), _s(c.id))
    o.set_member(String("suite"), _s(c.suite))
    o.set_member(String("reps"), _i(Int64(c.reps)))
    o.set_member(String("stage"), _s(c.stage.text()))
    o.set_member(String("komira"), _side_json(c.komira))
    o.set_member(String("duckdb"), _side_json(c.duckdb))
    o.set_member(String("value"), _s(c.value.text()))
    o.set_member(String("ratio"), _opt_f64(c.ratio))
    o.set_member(String("verdict"), _s(c.verdict))
    o.set_member(String("first_ratio"), _opt_f64(c.first_ratio))
    o.set_member(String("check_runs"), _check_runs_json(c))
    return o^


def _run_json(run: RunInfo) raises -> JsonValue:
    var o = JsonValue.empty_object()
    o.set_member(String("mode"), _s(run.mode))
    var scale = JsonValue.empty_object()
    scale.set_member(run.scale_kind.copy(), _i(run.scale_value))
    o.set_member(String("scale"), scale^)
    o.set_member(String("sweeps"), _i(Int64(run.sweeps)))
    o.set_member(String("reps"), _i(Int64(run.reps)))
    o.set_member(String("statistic"), _s(run.statistic))
    o.set_member(String("threads"), _i(run.threads))
    o.set_member(String("pass_max"), JsonValue.from_f64(run.pass_max))
    return o^


def _env_json(env: Environment) raises -> JsonValue:
    var o = JsonValue.empty_object()
    o.set_member(String("hostclass"), _s(env.hostclass))
    o.set_member(String("cpu_model"), _s(env.cpu_model))
    o.set_member(String("cores"), _i(env.cores))
    o.set_member(String("mem_total_bytes"), _i(env.mem_total_bytes))
    o.set_member(String("os"), _s(env.os))
    o.set_member(String("komira_version"), _s(env.komira_version))
    var d = JsonValue.empty_object()
    d.set_member(String("version"), _s(env.duckdb.version))
    d.set_member(String("sha256"), _s(env.duckdb.sha256))
    d.set_member(String("pin"), _s(env.duckdb.pin))
    o.set_member(String("duckdb"), d^)
    o.set_member(String("dataset_lock_sha256"), _s(env.dataset_lock_sha256))
    return o^


def _suite_summary_json(s: SuiteSummary, version: Int) raises -> JsonValue:
    var o = JsonValue.empty_object()
    o.set_member(String("suite"), _s(s.suite))
    o.set_member(String("n_cells"), _i(Int64(s.n_cells)))
    o.set_member(String("n_ran"), _i(Int64(s.n_ran)))
    o.set_member(String("n_value_identical"), _i(Int64(s.n_verified)))
    o.set_member(String("n_ratio"), _i(Int64(s.n_ratio)))
    o.set_member(String("n_pass"), _i(Int64(s.n_pass)))
    o.set_member(String("n_fail"), _i(Int64(s.n_fail)))
    o.set_member(String("n_departure"), _i(Int64(s.n_departure)))
    o.set_member(String("geomean_ratio_verified"), _opt_f64(s.geomean))
    o.set_member(String("median_ratio"), _opt_f64(s.median_ratio))
    if version >= 3:
        o.set_member(String("n_first_ratio"), _i(Int64(s.n_first_ratio)))
        o.set_member(String("geomean_first_run"), _opt_f64(s.geomean_first))
        o.set_member(String("median_first_run"), _opt_f64(s.median_first))
    return o^


def summary_json(result: BenchResult, version: Int = 3) raises -> JsonValue:
    """The `summary` member of `result`, recomputed from its cells: the
    overall counts, a line for each suite, and the headline. With `version` 2
    it is the summary that schema wrote: no first-run figures and a headline
    whose geomean and median are not called steady-state. The reader compares
    it with the summary of a schema 2 document."""
    var summary = summarize(result)
    var o = _suite_summary_json(summary.overall, version)
    var per_suite = JsonValue.empty_array()
    for i in range(len(summary.suites)):
        per_suite.push(_suite_summary_json(summary.suites[i], version))
    o.set_member(String("per_suite"), per_suite^)
    o.set_member(
        String("headline"),
        _s(summary_line(summary.overall, result.run.pass_max, result.env.duckdb, version >= 3)),
    )
    return o^


def result_json(result: BenchResult) raises -> JsonValue:
    """`result` as a JSON value. Raises if the schema does not allow it, or if
    a side has no runs to write."""
    validate_result(result)
    for i in range(len(result.cells)):
        ref c = result.cells[i]
        if (c.komira and not c.komira.value().has_runs()) or (c.duckdb and not c.duckdb.value().has_runs()):
            raise Error(
                "cell " + c.id + ": a side without its runs cannot be written; schema 2 holds every run"
                " (a result read from schema 1 has none)"
            )
    var doc = JsonValue.empty_object()
    doc.set_member(String("schema"), _s(String(RESULT_SCHEMA)))
    doc.set_member(String("run"), _run_json(result.run))
    doc.set_member(String("env"), _env_json(result.env))
    var cells = JsonValue.empty_array()
    for i in range(len(result.cells)):
        cells.push(_cell_json(result.cells[i]))
    doc.set_member(String("cells"), cells^)
    doc.set_member(String("summary"), summary_json(result))
    return doc^


def write_result_json(result: BenchResult) raises -> String:
    """The text of result.json for `result`: one line of compact JSON."""
    return result_json(result).serialize()
