# The writer of result.json (schema `komira-bench-result/1`). It writes the
# result as one compact line of JSON with the members in a fixed order, after
# `validate_result` has accepted it, and writes the summary the reader will
# recompute and compare.

from komira_json import JsonValue

from .model import (
    BenchResult,
    Cell,
    DuckDbPin,
    Environment,
    RESULT_SCHEMA,
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
    o.set_member(String("warmup_runs"), _i(Int64(run.warmup_runs)))
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


def _suite_summary_json(s: SuiteSummary) raises -> JsonValue:
    var o = JsonValue.empty_object()
    o.set_member(String("suite"), _s(s.suite))
    o.set_member(String("n_cells"), _i(Int64(s.n_cells)))
    o.set_member(String("n_ran"), _i(Int64(s.n_ran)))
    o.set_member(String("n_value_identical"), _i(Int64(s.n_verified)))
    o.set_member(String("n_ratio"), _i(Int64(s.n_ratio)))
    o.set_member(String("n_pass"), _i(Int64(s.n_pass)))
    o.set_member(String("n_fail"), _i(Int64(s.n_fail)))
    o.set_member(String("geomean_ratio_verified"), _opt_f64(s.geomean))
    o.set_member(String("median_ratio"), _opt_f64(s.median_ratio))
    return o^


def summary_json(result: BenchResult) raises -> JsonValue:
    """The `summary` member of `result`, recomputed from its cells: the
    overall counts, a line for each suite, and the headline."""
    var summary = summarize(result)
    var o = _suite_summary_json(summary.overall)
    var per_suite = JsonValue.empty_array()
    for i in range(len(summary.suites)):
        per_suite.push(_suite_summary_json(summary.suites[i]))
    o.set_member(String("per_suite"), per_suite^)
    o.set_member(
        String("headline"),
        _s(summary_line(summary.overall, result.run.pass_max, result.env.duckdb)),
    )
    return o^


def result_json(result: BenchResult) raises -> JsonValue:
    """`result` as a JSON value. Raises if the schema does not allow it."""
    validate_result(result)
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
