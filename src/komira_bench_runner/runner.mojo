# The run: for each query, DuckDB's answer, the komira arm's answer, the check
# between them, and only then the timing.
#
#   1. DuckDB runs the query in JSON mode: the reference rows.
#   2. The arm runs it with rows materialized. Refused, failed to bind or
#      failed to execute: the cell records that and nothing is timed.
#   3. The rows are compared by signature (exact for integers and text, a
#      relative tolerance for floats) and, for a query with ORDER BY, checked
#      for order. A mismatch is a cell that failed, with the cause named, and
#      nothing is timed.
#   4. Only a verified query is timed: warm (sweeps of reps) and, when the host
#      can drop its file cache, cold (the cache dropped before every rep). Both
#      engines run at the thread count and memory limit of the settings. Every
#      run is recorded with its time and its page faults, the first of each
#      sweep included; the report package says what the cell's first-run and
#      steady-state figures are made of (`STEADY_STATE_DEFINITION`).
#
# Warm and cold are two results because the result model holds one number of
# reps per run and no temperature; each is a `BenchResult` of its own.

from komira_bench_data import DatasetManifest
from komira_bench_duckdb import (
    BenchClock,
    DuckDbSession,
    DuckDbTransport,
    FairnessSettings,
    ResultSignature,
    check_order,
    compare_signatures,
    signature_of,
)
from komira_bench_report import (
    BenchResult,
    Cell as ReportCell,
    Environment,
    RunInfo,
    STATISTIC_MIN_OF_SWEEP_MEDIAN,
    Side,
    StageOutcome,
    ValueVerdict as ReportVerdict,
    validate_result,
)

from .arm import ARM_BIND_FAIL, ARM_EXEC_FAIL, ARM_REFUSED, ArmAnswer, EngineArm
from .cache import CacheDropper
from .measure import Sweeps, measure
from .query import QuerySpec
from .settings import HostFacts, RunInputs, RunSettings
from .tables import TableBinding, scale_of, tables_of

comptime CAUSE_NOT_RUN: String = "komira did not run"
comptime CAUSE_WRONG_ANSWER: String = "answer differs from duckdb"
comptime CAUSE_WRONG_ORDER: String = "rows not in ORDER BY order"


struct QueryOutcome(Copyable, Movable):
    """What happened to one query, for the console: its key, the digest of its
    text, how the arm ended (`stage`, as the result writes it), whether the
    values matched, and `note`: the construct of a refusal, the engine's
    message of a failure, or the first reason of a mismatch."""

    var key: String
    var sha256: String
    var stage: String
    var value: String
    var timed: Bool
    var note: String

    def __init__(
        out self,
        var key: String,
        var sha256: String,
        var stage: String,
        var value: String,
        timed: Bool,
        var note: String,
    ):
        self.key = key^
        self.sha256 = sha256^
        self.stage = stage^
        self.value = value^
        self.timed = timed
        self.note = note^


struct RunOutput(Copyable, Movable):
    """Everything a run produced: the warm result, the cold result when cold
    was measured (else `cold_note` says why not), one outcome per query in
    order, and what DuckDB read back of the shared settings."""

    var warm: BenchResult
    var cold: Optional[BenchResult]
    var cold_note: String
    var outcomes: List[QueryOutcome]
    var fairness: FairnessSettings
    var queries: List[QuerySpec]

    def __init__(
        out self,
        var warm: BenchResult,
        var cold: Optional[BenchResult],
        var cold_note: String,
        var outcomes: List[QueryOutcome],
        var fairness: FairnessSettings,
        var queries: List[QuerySpec],
    ):
        self.warm = warm^
        self.cold = cold^
        self.cold_note = cold_note^
        self.outcomes = outcomes^
        self.fairness = fairness^
        self.queries = queries^


def _single_quoted(text: String) -> String:
    return String("'") + text.replace(String("'"), String("''")) + String("'")


def _double_quoted(text: String) -> String:
    return String('"') + text.replace(String('"'), String('""')) + String('"')


def register_duckdb[T: DuckDbTransport](mut session: DuckDbSession[T], tables: List[TableBinding]) raises:
    """One view per table over its Parquet file."""
    for i in range(len(tables)):
        var sql = (
            String("CREATE OR REPLACE VIEW ")
            + _double_quoted(tables[i].name)
            + String(" AS SELECT * FROM read_parquet(")
            + _single_quoted(tables[i].path)
            + String(")")
        )
        var t = session.run_timed(sql)
        if not t.ok():
            raise Error("duckdb cannot register " + tables[i].name + ": " + t.error)


def _validate_queries(queries: List[QuerySpec], manifest: DatasetManifest) raises:
    if len(queries) == 0:
        raise Error("a run needs at least one query")
    for i in range(len(queries)):
        queries[i].validate()
        if queries[i].dataset != manifest.name:
            raise Error(
                "query " + queries[i].key() + " reads dataset " + queries[i].dataset
                + ", the run's dataset is " + manifest.name
            )
        for j in range(i):
            if queries[j].key() == queries[i].key():
                raise Error("query " + queries[i].key() + " is listed twice")


struct _Checked(Copyable, Movable):
    """The result of the check step for one query."""

    var stage: StageOutcome
    var verdict: ReportVerdict
    var rows: Int64
    var verified: Bool
    var note: String

    def __init__(
        out self,
        var stage: StageOutcome,
        var verdict: ReportVerdict,
        rows: Int64,
        verified: Bool,
        var note: String,
    ):
        self.stage = stage^
        self.verdict = verdict^
        self.rows = rows
        self.verified = verified
        self.note = note^


def _checked(query: QuerySpec, answer: ArmAnswer, reference: ResultSignature) raises -> _Checked:
    if answer.kind == ARM_REFUSED:
        return _Checked(
            StageOutcome.unsupported(answer.detail.copy()),
            ReportVerdict.unverified(String(CAUSE_NOT_RUN)),
            Int64(0),
            False,
            answer.detail.copy(),
        )
    if answer.kind == ARM_BIND_FAIL:
        return _Checked(
            StageOutcome.bind_fail(),
            ReportVerdict.unverified(String(CAUSE_NOT_RUN)),
            Int64(0),
            False,
            answer.detail.copy(),
        )
    if answer.kind == ARM_EXEC_FAIL:
        return _Checked(
            StageOutcome.exec_fail(),
            ReportVerdict.unverified(String(CAUSE_NOT_RUN)),
            Int64(0),
            False,
            answer.detail.copy(),
        )
    var got = signature_of(answer.rows)
    var verdict = compare_signatures(got, reference)
    if not verdict.identical:
        return _Checked(
            StageOutcome.exec_fail(),
            ReportVerdict.unverified(String(CAUSE_WRONG_ANSWER)),
            Int64(0),
            False,
            verdict.reasons[0].copy(),
        )
    if len(query.order_keys) > 0:
        var order = check_order(answer.rows, query.order_keys)
        if not order.ok:
            return _Checked(
                StageOutcome.exec_fail(),
                ReportVerdict.unverified(String(CAUSE_WRONG_ORDER)),
                Int64(0),
                False,
                order.label(),
            )
    return _Checked(
        StageOutcome.exec_ok(),
        ReportVerdict.identical(),
        Int64(answer.rows.row_count()),
        True,
        String(""),
    )


def _run_info(
    settings: RunSettings, scale_kind: String, scale_value: Int64, sweeps: Int, reps: Int
) -> RunInfo:
    return RunInfo(
        String("both"),
        scale_kind.copy(),
        scale_value,
        sweeps,
        reps,
        String(STATISTIC_MIN_OF_SWEEP_MEDIAN),
        Int64(settings.threads),
        settings.pass_max,
    )


def _environment(inputs: RunInputs) -> Environment:
    return Environment(
        inputs.host.hostclass.copy(),
        inputs.host.cpu_model.copy(),
        inputs.host.cores,
        inputs.host.mem_total_bytes,
        inputs.host.os.copy(),
        inputs.host.komira_version.copy(),
        inputs.duckdb.copy(),
        inputs.lock_sha256.copy(),
    )


def _untimed_cell(query: QuerySpec, checked: _Checked, reps: Int, pass_max: Float64) raises -> ReportCell:
    return ReportCell.build(
        query.key(),
        query.suite.copy(),
        reps,
        checked.stage.copy(),
        Optional[Side](),
        Optional[Side](),
        checked.verdict.copy(),
        pass_max,
    )


def _timed_cell(
    query: QuerySpec, rows: Int64, sweeps: Sweeps, reps: Int, pass_max: Float64
) raises -> ReportCell:
    return ReportCell.build(
        query.key(),
        query.suite.copy(),
        reps,
        StageOutcome.exec_ok(),
        Optional[Side](
            Side.from_sweeps(rows, sweeps.komira.ms.copy(), sweeps.komira.minor.copy(), sweeps.komira.major.copy())
        ),
        Optional[Side](
            Side.from_sweeps(rows, sweeps.duckdb.ms.copy(), sweeps.duckdb.minor.copy(), sweeps.duckdb.major.copy())
        ),
        ReportVerdict.identical(),
        pass_max,
    )


def run_queries[
    T: DuckDbTransport, A: EngineArm, D: CacheDropper
](
    mut session: DuckDbSession[T],
    mut arm: A,
    mut dropper: D,
    clock: BenchClock,
    queries: List[QuerySpec],
    inputs: RunInputs,
    settings: RunSettings,
) raises -> RunOutput:
    """Run `queries` as described at the top of this file. The session is
    started here with the settings' thread count and memory limit, the dataset
    is registered in DuckDB as one view per table and handed to the arm, and
    the arm is asked for the same two numbers. `clock` times the arm; the
    session has its own. The caller closes the session and the arm.

    Raises on a fault of the run (an unusable setting, a DuckDB that cannot
    answer a query, an arm that cannot be prepared, a time too short to
    measure). A query the arm refuses or answers wrongly is a cell, not a
    raise."""
    settings.validate()
    inputs.manifest.validate()
    _validate_queries(queries, inputs.manifest)
    var tables = tables_of(inputs.manifest, inputs.cache_dir)
    var files = List[String]()
    for i in range(len(tables)):
        files.append(tables[i].path.copy())
    var scale = scale_of(inputs.manifest)

    var fairness = session.start(settings.threads, settings.memory_limit_bytes)
    register_duckdb(session, tables)
    arm.prepare(tables, settings.threads, settings.memory_limit_bytes)

    var cold_on = settings.cold_sweeps > 0
    var cold_note = String("")
    if cold_on:
        if not dropper.can_drop():
            cold_on = False
            cold_note = String("the host has no way to drop its file cache")
        else:
            try:
                dropper.drop(files)
            except e:
                cold_on = False
                cold_note = String("dropping the file cache failed: ") + String(e)

    var warm_cells = List[ReportCell]()
    var cold_cells = List[ReportCell]()
    var outcomes = List[QueryOutcome]()
    for i in range(len(queries)):
        ref q = queries[i]
        var reference = session.fetch(q.text)
        if not reference.ok():
            raise Error("duckdb failed on " + q.key() + ": " + reference.error)
        var answer = arm.run(q, True)
        var checked = _checked(q, answer, signature_of(reference.rows))
        if checked.verified:
            var w = measure(
                session, arm, dropper, clock, q, files,
                tables, settings.threads, settings.memory_limit_bytes, checked.rows,
                settings.warm_sweeps, settings.warm_reps, False,
            )
            warm_cells.append(_timed_cell(q, checked.rows, w, settings.warm_reps, settings.pass_max))
            if cold_on:
                var c = measure(
                    session, arm, dropper, clock, q, files,
                    tables, settings.threads, settings.memory_limit_bytes, checked.rows,
                    settings.cold_sweeps, settings.cold_reps, True,
                )
                cold_cells.append(_timed_cell(q, checked.rows, c, settings.cold_reps, settings.pass_max))
        else:
            warm_cells.append(_untimed_cell(q, checked, settings.warm_reps, settings.pass_max))
            if cold_on:
                cold_cells.append(_untimed_cell(q, checked, settings.cold_reps, settings.pass_max))
        outcomes.append(
            QueryOutcome(
                q.key(), q.sha256(), checked.stage.text(), checked.verdict.text(), checked.verified, checked.note.copy()
            )
        )

    var warm = BenchResult(
        _run_info(settings, scale.kind, scale.value, settings.warm_sweeps, settings.warm_reps),
        _environment(inputs),
        warm_cells^,
    )
    validate_result(warm)
    var cold = Optional[BenchResult]()
    if cold_on:
        var r = BenchResult(
            _run_info(settings, scale.kind, scale.value, settings.cold_sweeps, settings.cold_reps),
            _environment(inputs),
            cold_cells^,
        )
        validate_result(r)
        cold = Optional[BenchResult](r^)
    return RunOutput(warm^, cold^, cold_note^, outcomes^, fairness^, queries.copy())
