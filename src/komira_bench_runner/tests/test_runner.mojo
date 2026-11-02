# The run end to end over fakes: a DuckDB transport that lives in this file
# (it prints marker lines and answers a query by looking its text up in a rule
# list, moving a manual clock a set amount while a query "runs"), a komira arm
# that answers from a script and moves the same clock, and a cache dropper
# that records. No process is started, no clock is read, nothing sleeps, and
# no test compares a duration the machine produced: every time is a number the
# fakes added to the manual clock.
#
# What each test proves:
# - test_a_matching_answer_is_timed_and_recorded: a query whose rows equal
#   DuckDB's is run once to check and then timed `sweeps x reps` times on each
#   engine; the cell is EXEC_OK and IDENTICAL, carries both times (komira 3 ms,
#   duckdb 2 ms), the ratio 1.5 and the verdict FAIL against 1.0; the arm and
#   DuckDB were both given the same threads and memory limit; the arm ran the
#   check with rows before any timed run.
# - test_every_run_is_recorded_rep_zero_of_every_sweep_included: with komira
#   runs of (30, 3, 3) and (9, 3, 3) ms and DuckDB runs of (10, 2, 2) and
#   (7, 2, 2) ms, the cell holds all twelve runs in order with rep 0 of both
#   sweeps; the first run is the check run, 50 ms against 40 ms (first-run ratio
#   1.25); the steady-state time is 3 ms against 2 ms (ratio 1.5, from the median
#   of all the reps of each sweep); the written result reads back to the same
#   text, and the console report states the steady-state and the first-run
#   figures.
# - test_the_check_run_is_the_first_run_with_its_time_for_both_engines: the run
#   that checks the answer (DuckDB's fetch, the arm's run with rows) is
#   executed before any sweep, so it is the first execution of the query: its
#   time (50 ms and 40 ms here) is the `first_run` of each side in the written
#   result, beside the sweeps' runs, which start at 30 ms and 10 ms.
# - test_steady_state_is_the_median_of_every_rep_of_each_sweep: komira sweeps
#   (10,4,6) and (8,5,7) ms give sweep medians 6 and 7 and a steady state of 6,
#   not 5 (what leaving each sweep's first rep out would give); the first reps
#   stay in the file.
# - test_the_check_runs_alternate_which_engine_goes_first: with three queries
#   DuckDB's check run goes first for the first and third, the arm's for the
#   second (by query position), so neither engine always pays the cold page
#   cache; all are timed and verified.
# - test_the_check_runs_of_unverified_cells_are_recorded: a wrong answer, which
#   is not timed and not verified, keeps both check runs with their time and
#   faults in `check_runs`; a refusal keeps DuckDB's and records none for the
#   arm, whose refusal a clock cannot resolve.
# - test_no_run_is_discarded_at_any_thread_count: at 1, 32 and 88 threads the
#   arm and DuckDB each run the query exactly once to check it and then
#   sweeps x reps times, all of which are recorded: nothing is run to be
#   thrown away.
# - test_page_faults_per_run_are_recorded_for_both_engines: counters that move
#   by 12000, 900, 880, 870, 860, 850 minor faults (3 major on the first run)
#   while the arm runs and by 54000, 1000, 900, 800, 700, 650 (5 and 1 major
#   on the first two runs) while DuckDB runs are recorded run by run, in the
#   shape of the runs, for each engine, and survive the written file; the check
#   run's own faults (7000 and 4 for the arm, 60000 and 6 for DuckDB) are the
#   `first_run` faults of each side, apart from the sweeps' counts.
# - test_runs_without_counters_say_not_measured: engines that cannot read
#   their counters still have every run recorded, and the faults of both
#   sides are absent, not zero.
# - test_a_cold_result_records_every_run: the cold result holds all its runs
#   (here 30 ms each) with the first run in place, like the warm one.
# - test_a_mismatching_answer_is_recorded_wrong_and_never_timed: rows that
#   differ in one value give EXEC_FAIL with the cause "answer differs from
#   duckdb", no time on either side, no ratio; the arm ran once and DuckDB ran
#   the query once, never in timed mode.
# - test_rows_in_the_wrong_order_are_recorded_wrong_and_never_timed: the same
#   rows in the wrong order pass the signature but fail the ORDER BY check
#   when the query has order keys, and are timed when it has none.
# - test_a_refusal_is_listed_by_name_and_nothing_is_timed: the refusal arm
#   gives UNSUPPORTED:no_engine_arm for each query, both are named under
#   "unserved" in the report, and DuckDB ran each query only for its answer.
# - test_a_failure_of_the_arm_is_recorded_as_its_stage: a bind failure and an
#   execution failure are BIND_FAIL and EXEC_FAIL, their messages are on the
#   outcome and not in the result.
# - test_cold_and_warm_runs_are_separate_results: warm and cold are two
#   results with their own sweeps and reps; the cache is dropped before every
#   cold rep of each engine and never before a warm rep; the same query is
#   3 ms warm and 30 ms cold.
# - test_a_timed_run_that_returns_other_rows_than_the_check_ends_the_run: an
#   arm whose timed runs return a different row count than its verified run
#   is not reported as identical; the run raises.
# - test_every_kind_of_difference_is_a_wrong_answer: an integer, a string, a
#   row count and a NULL that differ are each recorded wrong and not timed.
# - test_the_exit_status_follows_the_cells: 0 for a run whose every query
#   matched, 1 for a refusal or a wrong answer.
# - test_the_tolerance_is_printed_and_written: the comparison tolerance is on
#   the console and in comparison.txt.
# - test_cold_is_not_measured_when_the_cache_cannot_be_dropped: a dropper that
#   cannot, and one that fails, leave the warm result whole, no cold result,
#   and the reason in the report.
# - test_the_result_round_trips_and_the_files_are_written: the warm result
#   written by the report package reads back to the same text; the files of
#   a run are where output.mojo says, and the query digests file lists the
#   sha256 of each query text.
# - test_a_different_declared_type_is_a_wrong_answer_by_name: DuckDB's INTEGER
#   against the arm's BIGINT with the same value is recorded wrong, not timed,
#   and the note names "declared type" and both types; the same value with the
#   same declared type is timed.
# - test_hugeint_against_decimal_38_0_is_a_departure_that_is_timed_and_never_a_pass:
#   DuckDB's HUGEINT (a small and a 38-digit value) against the arm's
#   DECIMAL(38,0) with equal values is recorded EXEC_OK with the value
#   DEPARTURE:<reason>, is timed, keeps its ratio (1 ms against 2 ms, under the
#   threshold) and has the verdict DEPARTURE; next to two wrong answers (a value
#   a unit apart, and HUGEINT against the arm's BIGINT, which are not timed and
#   name the types) the console says PASS 0/3 and DEPARTURE 1/3 with the
#   reason, comparison.txt lists the allowed departure, the run exits 1 for the
#   wrong answers, and the departure cell alone exits 0 and round-trips through
#   result.json.
# - test_only_the_fetch_of_a_query_is_described: each query is described once,
#   by its fetch, and none of its timed runs is.
# - test_faults_end_the_run: a DuckDB error on the reference query, a time the
#   clock cannot resolve, an arm that stops completing after its check, a
#   query of another dataset, a query listed twice and no queries each raise.

from std.memory import ArcPointer
from std.os import makedirs
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_bench_data import find_manifest
from komira_bench_duckdb import (
    ABS_FLOOR,
    BenchClock,
    REL_TOL,
    Cell,
    DuckDbSession,
    DuckDbTransport,
    FaultCount,
    OrderKey,
    ResultSet,
    StdoutChunk,
    parse_json_rows,
)
from komira_bench_duckdb.cells import KIND_FLOAT, KIND_TEXT
from komira_bench_duckdb.text import slice_bytes
from komira_bench_report import (
    Cell as ReportCell,
    DuckDbPin,
    STEADY_STATE_DEFINITION,
    exit_code,
    parse_result_json,
    summarize,
    write_result_json,
)
from komira_json import parse_json_value
from komira_runtime_paths import test_tmpdir

from komira_bench_runner import (
    ARM_BIND_FAIL,
    ARM_EXEC_FAIL,
    ARM_ROWS,
    ArmAnswer,
    CacheDropper,
    EngineArm,
    HostFacts,
    NoCacheDropper,
    QuerySpec,
    RefusalArm,
    RunOutput,
    RunInputs,
    RunSettings,
    TableBinding,
    comparison_text,
    format_run,
    run_status,
    queries_file_text,
    run_queries,
    write_run,
)

comptime _SHA: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
comptime _MS: Int = 1_000_000


# --- the DuckDB stand-in --------------------------------------------------------


struct Rule(Copyable, Movable):
    var needle: String
    var json: String
    var error: String
    var cost: Int
    var types: String
    """What DuckDB answers for DESCRIBE of the query, as JSON; empty means the
    types are worked out from the first row of `json` (see `_describe_of`)."""
    var costs: List[Int]
    """The nanoseconds the n-th run of this rule takes (n from 0, the fetch of
    the answer first); a run past the list takes `cost`."""
    var minors: List[Int]
    """The minor page faults the n-th run adds to the process's total."""
    var majors: List[Int]

    def __init__(
        out self,
        needle: String,
        json: String,
        error: String,
        cost: Int,
        types: String = String(""),
        var costs: List[Int] = List[Int](),
        var minors: List[Int] = List[Int](),
        var majors: List[Int] = List[Int](),
    ):
        self.needle = needle
        self.json = json
        self.error = error
        self.cost = cost
        self.types = types
        self.costs = costs^
        self.minors = minors^
        self.majors = majors^

    def describe(self) -> String:
        if self.types.byte_length() > 0:
            return self.types.copy()
        try:
            return _describe_of(self.json)
        except:
            return String("")


def _declared_of_cell(c: Cell) -> String:
    if c.kind == KIND_FLOAT:
        return String("DOUBLE")
    if c.kind == KIND_TEXT:
        return String("VARCHAR")
    return String("BIGINT")


def _describe_of(json: String) raises -> String:
    """DuckDB's answer to DESCRIBE of a query whose rows print as `json`: a
    bare integer is a BIGINT, a bare number with a point a DOUBLE, a quoted
    text a VARCHAR, a NULL or an empty answer a BIGINT."""
    var rs = parse_json_rows(json)
    var out = String("[")
    for c in range(rs.column_count()):
        if c > 0:
            out += String(",\n")
        var ty = _declared_of_cell(rs.rows[0][c]) if rs.row_count() > 0 else String("BIGINT")
        out += (
            String('{"column_name":"') + rs.names[c] + String('","column_type":"') + ty
            + String('","null":"YES","key":null,"default":null,"extra":null}')
        )
    return out + String("]")


struct FakeDuckDb(DuckDbTransport):
    var clock: ArcPointer[Int]
    var sent: ArcPointer[List[String]]
    var rules: List[Rule]
    var chunks: List[String]
    var advances: List[Int]
    var at: Int
    var errors: String
    var statement: String
    var cost: Int
    var mode: String
    var rule_runs: List[Int]
    var counters: Bool
    var minor: Int64
    var major: Int64
    var order: ArcPointer[List[String]]
    """Which engine ran its check run when: "duckdb" is appended when the fetch
    of a query's answer runs."""

    def __init__(
        out self,
        clock: ArcPointer[Int],
        sent: ArcPointer[List[String]],
        var rules: List[Rule],
        counters: Bool = False,
        order: ArcPointer[List[String]] = ArcPointer[List[String]](List[String]()),
    ):
        self.order = order
        self.clock = clock
        self.sent = sent
        self.rules = rules^
        self.rule_runs = List[Int]()
        for _ in range(len(self.rules)):
            self.rule_runs.append(0)
        self.counters = counters
        self.minor = 700000
        self.major = 11
        self.chunks = List[String]()
        self.advances = List[Int]()
        self.at = 0
        self.errors = String("")
        self.statement = String("")
        self.cost = 0
        self.mode = String("")

    def emit(mut self, text: String, advance: Int):
        self.chunks.append(text)
        self.advances.append(advance)

    def run_statement(mut self):
        for i in range(len(self.rules)):
            if self.statement.find(self.rules[i].needle) >= 0:
                if self.statement.startswith(String("DESCRIBE ")):
                    if self.mode == "json" and self.rules[i].json.byte_length() > 0:
                        self.emit(self.rules[i].describe() + String("\n"), 0)
                    self.errors += self.rules[i].error
                    break
                if self.mode == "json" and self.rules[i].json.byte_length() > 0:
                    self.emit(self.rules[i].json + String("\n"), 0)
                    if self.rules[i].needle.startswith(String("revenue")):
                        self.order[].append(String("duckdb"))
                self.errors += self.rules[i].error
                var n = self.rule_runs[i]
                self.rule_runs[i] = n + 1
                self.cost = self.rules[i].cost
                if n < len(self.rules[i].costs):
                    self.cost = self.rules[i].costs[n]
                if n < len(self.rules[i].minors):
                    self.minor += Int64(self.rules[i].minors[n])
                if n < len(self.rules[i].majors):
                    self.major += Int64(self.rules[i].majors[n])
                break
        self.statement = String("")

    def send(mut self, text: String) raises:
        self.sent[].append(text)
        var rest = text
        while rest.byte_length() > 0:
            var nl = rest.find(String("\n"))
            var line = rest
            if nl >= 0:
                line = String(rest[byte=0:nl])
                rest = slice_bytes(rest, nl + 1, rest.byte_length())
            else:
                rest = String("")
            if line.startswith(String(".mode ")):
                self.mode = String(line[byte=6 : line.byte_length()])
            elif line.startswith(String(".print ")):
                var payload = String(line[byte=7 : line.byte_length()])
                if payload.startswith(String("@@E")):
                    self.emit(payload + String("\n"), self.cost)
                    self.cost = 0
                else:
                    self.emit(payload + String("\n"), 0)
            else:
                self.statement += line + String("\n")
                if line.endswith(String(";")):
                    self.run_statement()

    def read_stdout(mut self, max_wait_ms: Int) raises -> StdoutChunk:
        if self.at >= len(self.chunks):
            return StdoutChunk(String(""), True)
        self.clock[] = self.clock[] + self.advances[self.at]
        var t = self.chunks[self.at]
        self.at += 1
        return StdoutChunk(t^, False)

    def take_stderr(mut self) raises -> String:
        var e = self.errors
        self.errors = String("")
        return e^

    def kill(mut self) raises:
        self.sent[].append(String("<killed>"))

    def finish(mut self) raises -> Int:
        return 0

    def child_faults(self) -> Optional[FaultCount]:
        if not self.counters:
            return Optional[FaultCount]()
        return Optional[FaultCount](FaultCount(self.minor, self.major))


def _settings_rule(threads: Int = 4) -> Rule:
    return Rule(
        String("current_setting('threads')"),
        String('[{"threads":') + String(threads) + String(',"memory_limit":"16.0 KiB","version":"v1.5.6","source_id":"069cc9f9b5"}]'),
        String(""),
        0,
    )


# --- the komira stand-in --------------------------------------------------------


struct Script(Copyable, Movable):
    var key: String
    var kind: Int
    var detail: String
    var rows: ResultSet
    var cost_ns: Int

    def __init__(out self, key: String, kind: Int, detail: String, var rows: ResultSet, cost_ns: Int):
        self.key = key
        self.kind = kind
        self.detail = detail
        self.rows = rows^
        self.cost_ns = cost_ns


struct Shared(Copyable, Movable):
    """What the arm, the dropper and the test all see."""

    var log: List[String]
    var cold_next: Bool

    def __init__(out self):
        self.log = List[String]()
        self.cold_next = False


struct FakeArm(EngineArm):
    var clock: ArcPointer[Int]
    var shared: ArcPointer[Shared]
    var scripts: List[Script]
    var cold_penalty: Int
    var stop_after_check: Bool
    var wrong_count: Bool
    var costs: List[Int]
    """The nanoseconds the n-th run takes (n from 0, the check run first); a
    run past the list takes the script's cost."""
    var minors: List[Int]
    var majors: List[Int]
    var counters: Bool
    var runs_seen: Int
    var minor: Int64
    var major: Int64
    var order: Optional[ArcPointer[List[String]]]

    def __init__(
        out self,
        clock: ArcPointer[Int],
        shared: ArcPointer[Shared],
        var scripts: List[Script],
        cold_penalty: Int = 0,
        stop_after_check: Bool = False,
        wrong_count: Bool = False,
        var costs: List[Int] = List[Int](),
        counters: Bool = False,
        var minors: List[Int] = List[Int](),
        var majors: List[Int] = List[Int](),
        order: Optional[ArcPointer[List[String]]] = Optional[ArcPointer[List[String]]](),
    ):
        self.order = order.copy()
        self.costs = costs^
        self.minors = minors^
        self.majors = majors^
        self.counters = counters
        self.runs_seen = 0
        self.minor = 3000000
        self.major = 17
        self.wrong_count = wrong_count
        self.clock = clock
        self.shared = shared
        self.scripts = scripts^
        self.cold_penalty = cold_penalty
        self.stop_after_check = stop_after_check

    def label(self) -> String:
        return String("fake")

    def faults(self) -> Optional[FaultCount]:
        if not self.counters:
            return Optional[FaultCount]()
        return Optional[FaultCount](FaultCount(self.minor, self.major))

    def prepare(mut self, tables: List[TableBinding], threads: Int, memory_limit_bytes: Int) raises:
        self.shared[].log.append(
            String("prepare ") + String(len(tables)) + String(" ") + String(threads) + String(" ") + String(memory_limit_bytes)
        )

    def run(mut self, query: QuerySpec, materialize: Bool) raises -> ArmAnswer:
        self.shared[].log.append(String("run ") + (String("rows") if materialize else String("count")))
        if materialize and self.order:
            self.order.value()[].append(String("komira"))
        for i in range(len(self.scripts)):
            if self.scripts[i].key == query.key():
                ref s = self.scripts[i]
                if s.kind == ARM_BIND_FAIL:
                    return ArmAnswer.bind_failed(s.detail.copy())
                if s.kind == ARM_EXEC_FAIL:
                    return ArmAnswer.exec_failed(s.detail.copy())
                if s.kind != ARM_ROWS:
                    return ArmAnswer.refused(s.detail.copy())
                if not materialize and self.stop_after_check:
                    return ArmAnswer.exec_failed(String("stopped"))
                var cost = s.cost_ns
                var n = self.runs_seen
                self.runs_seen = n + 1
                if n < len(self.costs):
                    cost = self.costs[n]
                if n < len(self.minors):
                    self.minor += Int64(self.minors[n])
                if n < len(self.majors):
                    self.major += Int64(self.majors[n])
                if self.shared[].cold_next:
                    cost += self.cold_penalty
                    self.shared[].cold_next = False
                self.clock[] = self.clock[] + cost
                if materialize:
                    return ArmAnswer.with_rows(s.rows.copy())
                if self.wrong_count:
                    return ArmAnswer.counted(Int64(s.rows.row_count() + 1))
                return ArmAnswer.counted(Int64(s.rows.row_count()))
        raise Error("the fake arm has no script for " + query.key())

    def close(mut self) raises:
        self.shared[].log.append(String("close"))


struct FakeDropper(CacheDropper):
    var shared: ArcPointer[Shared]
    var fail: Bool

    def __init__(out self, shared: ArcPointer[Shared], fail: Bool = False):
        self.shared = shared
        self.fail = fail

    def can_drop(self) -> Bool:
        return True

    def drop(mut self, files: List[String]) raises:
        if self.fail:
            raise Error("not permitted")
        self.shared[].log.append(String("drop ") + String(len(files)))
        self.shared[].cold_next = True


# --- fixtures -------------------------------------------------------------------


def _rows_one(v: Float64) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("revenue"))
    rs.types.append(String("DOUBLE"))
    var r = List[Cell]()
    r.append(Cell.real(v))
    rs.add_row(r^)
    return rs^


def _rows_keys(a: Int64, b: Int64) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("k"))
    rs.types.append(String("BIGINT"))
    var r1 = List[Cell]()
    r1.append(Cell.integer(a))
    rs.add_row(r1^)
    var r2 = List[Cell]()
    r2.append(Cell.integer(b))
    rs.add_row(r2^)
    return rs^


def _inputs() raises -> RunInputs:
    return RunInputs(
        find_manifest(String("tpch"), String("sf1")),
        String("/cache"),
        String(_SHA),
        DuckDbPin(String("1.5.6"), String(_SHA), String("PINNED")),
        HostFacts(
            String("test-class"), String("test cpu"), Int64(4), Int64(17179869184), String("linux 6.1"), String("0.0.0-test")
        ),
    )


def _q(id: String, text: String, var keys: List[OrderKey] = List[OrderKey]()) -> QuerySpec:
    return QuerySpec(String("tpch"), id, String("tpch"), text, keys^)


struct Rig(Movable):
    var cell: ArcPointer[Int]
    var sent: ArcPointer[List[String]]
    var shared: ArcPointer[Shared]
    var order: ArcPointer[List[String]]

    def __init__(out self):
        self.cell = ArcPointer[Int](1000)
        self.sent = ArcPointer[List[String]](List[String]())
        self.shared = ArcPointer[Shared](Shared())
        self.order = ArcPointer[List[String]](List[String]())

    def duckdb(
        self, var rules: List[Rule], threads: Int = 4, counters: Bool = False
    ) -> DuckDbSession[FakeDuckDb]:
        rules.insert(0, _settings_rule(threads))
        return DuckDbSession[FakeDuckDb](
            FakeDuckDb(self.cell, self.sent, rules^, counters, self.order), BenchClock.manual(self.cell)
        )

    def sent_text(self) -> String:
        var out = String("")
        for i in range(len(self.sent[])):
            out += self.sent[][i]
        return out^

    def log_text(self) -> String:
        var out = String("")
        for i in range(len(self.shared[].log)):
            out += self.shared[].log[i] + String("|")
        return out^


def _runs(text: String, query: String) -> Int:
    """How many times `query` was run (its DESCRIBE is not a run)."""
    return _count(text, query) - _count(text, String("DESCRIBE ") + query)


def _count(text: String, needle: String) -> Int:
    var n = 0
    var at = 0
    while True:
        var f = text.find(needle, at)
        if f < 0:
            return n
        n += 1
        at = f + needle.byte_length()


def _settings(cold_sweeps: Int = 0) -> RunSettings:
    return RunSettings(4, 16384, 2, 3, cold_sweeps, 3, 1.0)


# --- tests ----------------------------------------------------------------------


def test_a_matching_answer_is_timed_and_recorded() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^)
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))

    var out = run_queries(session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    assert_equal(len(out.warm.cells), 1)
    ref c = out.warm.cells[0]
    assert_equal(c.id, String("tpch/q6"))
    assert_equal(c.stage.text(), String("EXEC_OK"))
    assert_equal(c.value.text(), String("IDENTICAL"))
    assert_equal(c.komira.value().ms, 3.0)
    assert_equal(c.duckdb.value().ms, 2.0)
    assert_equal(len(c.komira.value().ms_per_sweep), 2)
    assert_equal(c.komira.value().rows, Int64(1))
    assert_equal(c.duckdb.value().rows, Int64(1))
    assert_equal(c.ratio.value(), 1.5)
    assert_equal(c.verdict, String("FAIL"))
    assert_equal(out.warm.run.threads, Int64(4))
    assert_equal(out.warm.run.sweeps, 2)
    assert_equal(out.warm.run.reps, 3)
    assert_equal(out.warm.run.scale_kind, String("sf"))
    assert_equal(out.warm.run.scale_value, Int64(1))
    assert_equal(out.warm.env.dataset_lock_sha256, String(_SHA))
    assert_false(Bool(out.cold))
    assert_true(out.outcomes[0].timed)
    assert_equal(out.outcomes[0].sha256, queries[0].sha256())
    # the arm got what DuckDB got and checked with rows before any timed run
    assert_equal(
        rig.log_text(),
        String("prepare 8 4 16384|run rows|run count|run count|run count|run count|run count|run count|"),
    )
    var sent = rig.sent_text()
    assert_true(sent.find(String("SET threads=4")) >= 0)
    assert_true(sent.find(String("SET memory_limit='16KiB'")) >= 0)
    assert_equal(out.fairness.threads_readback, String("4"))
    # one fetch for the answer, six timed runs
    assert_equal(_runs(sent, String("SELECT revenue_q6")), 7)
    assert_equal(_count(sent, String("CREATE OR REPLACE VIEW")), 8)
    assert_true(sent.find(String("\"lineitem\" AS SELECT * FROM read_parquet('/cache/tpch/sf1/lineitem.parquet')")) >= 0)
    assert_true(format_run(out).find(String("PASS 0/1")) >= 0)
    assert_equal(run_status(out), 0)
    var header = format_run(out)
    assert_equal(_count(header, String("derived from TPC-H; not comparable to published TPC-H results")), 1)


def _ints(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int) -> List[Int]:
    var out = List[Int]()
    out.append(a)
    out.append(b)
    out.append(c)
    out.append(d)
    out.append(e)
    out.append(f)
    out.append(g)
    return out^


def _run_at(
    threads: Int,
    mut rig: Rig,
    var duck_rule: Rule,
    var arm_costs: List[Int] = List[Int](),
    counters: Bool = False,
    var arm_minors: List[Int] = List[Int](),
    var arm_majors: List[Int] = List[Int](),
) raises -> RunOutput:
    var rules = List[Rule]()
    rules.append(duck_rule^)
    var session = rig.duckdb(rules^, threads, counters)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
    var arm = FakeArm(
        rig.cell, rig.shared, scripts^, 0, False, False, arm_costs^, counters, arm_minors^, arm_majors^
    )
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))
    return run_queries(
        session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(),
        RunSettings(threads, 16384, 2, 3, 0, 3, 1.0),
    )


def _q6_rule(
    var costs: List[Int] = List[Int](), var minors: List[Int] = List[Int](), var majors: List[Int] = List[Int]()
) -> Rule:
    return Rule(
        String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS, String(""),
        costs^, minors^, majors^,
    )


def _arm_runs(log: String) -> Int:
    return _count(log, String("run count"))


def test_every_run_is_recorded_rep_zero_of_every_sweep_included() raises:
    var rig = Rig()
    # the check run (DuckDB's fetch of the answer, the arm's run with rows)
    # first, then two sweeps of three runs
    var duck = _q6_rule(_ints(40 * _MS, 10 * _MS, 2 * _MS, 2 * _MS, 7 * _MS, 2 * _MS, 2 * _MS))
    var out = _run_at(4, rig, duck^, _ints(50 * _MS, 30 * _MS, 3 * _MS, 3 * _MS, 9 * _MS, 3 * _MS, 3 * _MS))
    ref c = out.warm.cells[0]
    ref k = c.komira.value()
    ref d = c.duckdb.value()
    # every run, in order, rep 0 of each sweep included
    assert_equal(len(k.runs_ms), 2)
    assert_equal(len(k.runs_ms[0]), 3)
    assert_equal(len(k.runs_ms[1]), 3)
    assert_equal(k.runs_ms[0][0], 30.0)
    assert_equal(k.runs_ms[0][1], 3.0)
    assert_equal(k.runs_ms[0][2], 3.0)
    assert_equal(k.runs_ms[1][0], 9.0)
    assert_equal(k.runs_ms[1][1], 3.0)
    assert_equal(k.runs_ms[1][2], 3.0)
    assert_equal(len(d.runs_ms), 2)
    assert_equal(d.runs_ms[0][0], 10.0)
    assert_equal(d.runs_ms[0][2], 2.0)
    assert_equal(d.runs_ms[1][0], 7.0)
    assert_equal(d.runs_ms[1][2], 2.0)
    # the first run, which is what a first query pays, for both engines: the
    # check run (50 ms and 40 ms), executed before the sweeps, not the first
    # run of the first sweep (30 ms and 10 ms)
    assert_equal(k.first_ms().value(), 50.0)
    assert_equal(d.first_ms().value(), 40.0)
    assert_equal(c.first_ratio.value(), 1.25)
    # the steady-state time and ratio, from the median of all the reps of each sweep
    assert_equal(k.ms, 3.0)
    assert_equal(d.ms, 2.0)
    assert_equal(len(k.ms_per_sweep), 2)
    assert_equal(k.ms_per_sweep[1], 3.0)
    assert_equal(c.ratio.value(), 1.5)
    assert_equal(k.spread_pct, 0.0)
    # the written result keeps all of it
    var text = write_result_json(out.warm)
    var back = parse_result_json(text)
    assert_equal(write_result_json(back), text)
    assert_equal(back.cells[0].komira.value().runs_ms[1][0], 9.0)
    assert_equal(back.cells[0].duckdb.value().runs_ms[0][0], 10.0)
    assert_equal(back.cells[0].first_ratio.value(), 1.25)
    assert_equal(back.cells[0].komira.value().first_ms().value(), 50.0)
    assert_equal(back.cells[0].duckdb.value().first_ms().value(), 40.0)
    # the console states both, and what steady state means
    var report = format_run(out)
    assert_true(report.find(String("steady-state geomean")) >= 0)
    assert_true(report.find(String("first-run geomean 1.25x")) >= 0)
    assert_true(report.find(String(STEADY_STATE_DEFINITION)) >= 0)


def test_steady_state_is_the_median_of_every_rep_of_each_sweep() raises:
    var rig = Rig()
    var duck = _q6_rule()
    # komira sweeps (10, 4, 6) and (8, 5, 7) ms: every rep is in its sweep's
    # median, 6 and 7, so the steady state is 6 (leaving each sweep's first rep
    # out would give 5 and 6)
    var out = _run_at(4, rig, duck^, _ints(3 * _MS, 10 * _MS, 4 * _MS, 6 * _MS, 8 * _MS, 5 * _MS, 7 * _MS))
    ref k = out.warm.cells[0].komira.value()
    assert_equal(k.ms_per_sweep[0], 6.0)
    assert_equal(k.ms_per_sweep[1], 7.0)
    assert_equal(k.ms, 6.0)
    assert_equal(out.warm.cells[0].duckdb.value().ms, 2.0)
    assert_equal(out.warm.cells[0].ratio.value(), 3.0)
    # and every rep is still in the file
    assert_equal(k.runs_ms[0][0], 10.0)
    assert_equal(k.runs_ms[1][0], 8.0)


def test_the_check_runs_alternate_which_engine_goes_first() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    rules.append(Rule(String("revenue_q1"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    rules.append(Rule(String("revenue_q2"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
    scripts.append(Script(String("tpch/q1"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
    scripts.append(Script(String("tpch/q2"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^, order=Optional[ArcPointer[List[String]]](rig.order))
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))
    queries.append(_q(String("q1"), String("SELECT revenue_q1")))
    queries.append(_q(String("q2"), String("SELECT revenue_q2")))
    var out = run_queries(session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(), _settings())
    # by query position: the first query, the third, ... DuckDB first; the
    # second, ... the arm first, so neither engine always pays the cold page cache
    var want = List[String]()
    want.append(String("duckdb"))
    want.append(String("komira"))
    want.append(String("komira"))
    want.append(String("duckdb"))
    want.append(String("duckdb"))
    want.append(String("komira"))
    assert_equal(len(rig.order[]), 6)
    for i in range(6):
        assert_equal(rig.order[][i], want[i])
    # all three are timed and verified whichever went first
    for i in range(3):
        assert_true(out.outcomes[i].timed)
        assert_true(Bool(out.warm.cells[i].komira.value().first_ms()))
        assert_true(Bool(out.warm.cells[i].duckdb.value().first_ms()))


def test_the_check_runs_of_unverified_cells_are_recorded() raises:
    # a wrong answer: both engines ran their check run, nothing is timed, the
    # cell is not verified, and the check runs are kept with their faults
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(
        String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS, String(""),
        _ints(40 * _MS, 0, 0, 0, 0, 0, 0), _ints(60000, 0, 0, 0, 0, 0, 0), _ints(6, 0, 0, 0, 0, 0, 0),
    ))
    var session = rig.duckdb(rules^, 4, True)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.46), 3 * _MS))
    var arm = FakeArm(
        rig.cell, rig.shared, scripts^, 0, False, False, _ints(50 * _MS, 0, 0, 0, 0, 0, 0), True,
        _ints(7000, 0, 0, 0, 0, 0, 0), _ints(4, 0, 0, 0, 0, 0, 0),
    )
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))
    var out = run_queries(session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(), _settings())
    assert_false(out.outcomes[0].timed)
    assert_equal(out.warm.cells[0].value.text(), String("UNVERIFIED:answer differs from duckdb"))
    assert_false(Bool(out.warm.cells[0].komira))
    var doc = parse_json_value(write_result_json(out.warm))
    var c = doc.get(String("cells")).element_at(0).get(String("check_runs"))
    assert_equal(c.get(String("komira")).get(String("ms")).as_float64(), 50.0)
    assert_equal(c.get(String("komira")).get(String("minor_faults")).as_int64(), Int64(7000))
    assert_equal(c.get(String("komira")).get(String("major_faults")).as_int64(), Int64(4))
    assert_equal(c.get(String("duckdb")).get(String("ms")).as_float64(), 40.0)
    assert_equal(c.get(String("duckdb")).get(String("minor_faults")).as_int64(), Int64(60000))
    assert_equal(c.get(String("duckdb")).get(String("major_faults")).as_int64(), Int64(6))
    # a refusal: DuckDB's check run is recorded, the arm's, which did nothing a
    # clock can resolve, is not
    var rig2 = Rig()
    var rules2 = List[Rule]()
    rules2.append(Rule(String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS, String(""), _ints(40 * _MS, 0, 0, 0, 0, 0, 0)))
    var session2 = rig2.duckdb(rules2^)
    var refusal = RefusalArm()
    var none = NoCacheDropper()
    var out2 = run_queries(session2, refusal, none, BenchClock.manual(rig2.cell), queries, _inputs(), _settings())
    assert_false(out2.outcomes[0].timed)
    var doc2 = parse_json_value(write_result_json(out2.warm))
    var c2 = doc2.get(String("cells")).element_at(0).get(String("check_runs"))
    assert_equal(c2.get(String("duckdb")).get(String("ms")).as_float64(), 40.0)
    assert_true(c2.get(String("komira")).is_null())


def test_no_run_is_discarded_at_any_thread_count() raises:
    var threads = List[Int]()
    threads.append(1)
    threads.append(32)
    threads.append(88)
    for i in range(len(threads)):
        var rig = Rig()
        var out = _run_at(threads[i], rig, _q6_rule())
        assert_equal(out.warm.run.threads, Int64(threads[i]))
        assert_equal(out.outcomes[0].timed, True)
        # one checking run, then 2 sweeps x 3 reps, all of them recorded
        assert_equal(_arm_runs(rig.log_text()), 6)
        assert_equal(_runs(rig.sent_text(), String("SELECT revenue_q6")), 1 + 6)
        ref k = out.warm.cells[0].komira.value()
        ref d = out.warm.cells[0].duckdb.value()
        assert_equal(len(k.runs_ms), 2)
        assert_equal(len(k.runs_ms[0]) + len(k.runs_ms[1]), 6)
        assert_equal(len(d.runs_ms[0]) + len(d.runs_ms[1]), 6)


def test_page_faults_per_run_are_recorded_for_both_engines() raises:
    var rig = Rig()
    var duck = _q6_rule(
        List[Int](), _ints(60000, 54000, 1000, 900, 800, 700, 650), _ints(6, 5, 1, 0, 0, 0, 0)
    )
    var out = _run_at(
        4, rig, duck^, List[Int](), True,
        _ints(7000, 12000, 900, 880, 870, 860, 850), _ints(4, 3, 0, 0, 0, 0, 0),
    )
    _check_faults(out.warm.cells[0])
    # and the same after the file is written and read
    var text = write_result_json(out.warm)
    var back = parse_result_json(text)
    _check_faults(back.cells[0])
    # the check run, the first execution, has its own faults in the file: it is
    # not one of the sweeps' runs, and its counts are not theirs
    _check_first_run(text, String("komira"), 7000, 4)
    _check_first_run(text, String("duckdb"), 60000, 6)


def _check_first_run(text: String, engine: String, minor: Int, major: Int) raises:
    """The `first_run` member of `engine`'s side of the first cell, read from
    the written JSON."""
    var doc = parse_json_value(text)
    var side = doc.get(String("cells")).element_at(0).get(engine)
    assert_true(side.has(String("first_run")), "no first_run member in the " + engine + " side")
    var first = side.get(String("first_run"))
    assert_equal(first.get(String("minor_faults")).as_int64(), Int64(minor))
    assert_equal(first.get(String("major_faults")).as_int64(), Int64(major))


def test_the_check_run_is_the_first_run_with_its_time_for_both_engines() raises:
    var rig = Rig()
    var duck = _q6_rule(_ints(40 * _MS, 10 * _MS, 2 * _MS, 2 * _MS, 7 * _MS, 2 * _MS, 2 * _MS))
    var out = _run_at(4, rig, duck^, _ints(50 * _MS, 30 * _MS, 3 * _MS, 3 * _MS, 9 * _MS, 3 * _MS, 3 * _MS))
    var doc = parse_json_value(write_result_json(out.warm))
    var k = doc.get(String("cells")).element_at(0).get(String("komira"))
    var d = doc.get(String("cells")).element_at(0).get(String("duckdb"))
    assert_true(k.has(String("first_run")))
    assert_true(d.has(String("first_run")))
    assert_equal(k.get(String("first_run")).get(String("ms")).as_float64(), 50.0)
    assert_equal(d.get(String("first_run")).get(String("ms")).as_float64(), 40.0)
    # the sweeps are the timed runs only, and the first run is not among them
    assert_equal(k.get(String("runs_ms")).element_at(0).element_at(0).as_float64(), 30.0)


def _check_faults(c: ReportCell) raises:
    ref k = c.komira.value()
    ref d = c.duckdb.value()
    # one count per run, in the shape of the runs: the check run is not one
    # (it has its own, in `first_run`)
    assert_equal(len(k.minor_faults), 2)
    assert_equal(len(k.minor_faults[0]), 3)
    assert_equal(k.minor_faults[0][0], Int64(12000))
    assert_equal(k.minor_faults[0][1], Int64(900))
    assert_equal(k.minor_faults[0][2], Int64(880))
    assert_equal(k.minor_faults[1][0], Int64(870))
    assert_equal(k.minor_faults[1][2], Int64(850))
    assert_equal(k.major_faults[0][0], Int64(3))
    assert_equal(k.major_faults[0][1], Int64(0))
    assert_equal(k.major_faults[1][2], Int64(0))
    assert_equal(len(d.minor_faults), 2)
    assert_equal(d.minor_faults[0][0], Int64(54000))
    assert_equal(d.minor_faults[0][1], Int64(1000))
    assert_equal(d.minor_faults[0][2], Int64(900))
    assert_equal(d.minor_faults[1][0], Int64(800))
    assert_equal(d.minor_faults[1][2], Int64(650))
    assert_equal(d.major_faults[0][0], Int64(5))
    assert_equal(d.major_faults[0][1], Int64(1))
    assert_equal(d.major_faults[1][1], Int64(0))


def test_runs_without_counters_say_not_measured() raises:
    var rig = Rig()
    var out = _run_at(4, rig, _q6_rule())
    ref k = out.warm.cells[0].komira.value()
    ref d = out.warm.cells[0].duckdb.value()
    assert_equal(len(k.runs_ms[0]), 3)
    assert_equal(len(d.runs_ms[1]), 3)
    assert_equal(len(k.minor_faults), 0)
    assert_equal(len(k.major_faults), 0)
    assert_equal(len(d.minor_faults), 0)
    assert_equal(len(d.major_faults), 0)
    var text = write_result_json(out.warm)
    assert_true(text.find(String('"minor_faults":null,"major_faults":null')) >= 0)
    var back = parse_result_json(text)
    assert_equal(len(back.cells[0].komira.value().minor_faults), 0)


def test_a_cold_result_records_every_run() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^, 88)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^, 27 * _MS)
    var dropper = FakeDropper(rig.shared)
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))
    var out = run_queries(
        session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(),
        RunSettings(88, 16384, 2, 3, 2, 3, 1.0),
    )
    ref k = out.cold.value().cells[0].komira.value()
    assert_equal(len(k.runs_ms), 2)
    assert_equal(len(k.runs_ms[0]), 3)
    assert_equal(len(k.runs_ms[1]), 3)
    assert_equal(k.runs_ms[0][0], 30.0)
    assert_equal(k.runs_ms[1][2], 30.0)
    assert_equal(k.first_ms().value(), 30.0)
    assert_equal(out.cold.value().cells[0].first_ratio.value(), 15.0)
    # the warm result of the same run has its runs too
    assert_equal(len(out.warm.cells[0].komira.value().runs_ms), 2)


def test_a_mismatching_answer_is_recorded_wrong_and_never_timed() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.46), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^)
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))

    var out = run_queries(session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    ref c = out.warm.cells[0]
    assert_equal(c.stage.text(), String("EXEC_FAIL"))
    assert_equal(c.value.text(), String("UNVERIFIED:answer differs from duckdb"))
    assert_false(Bool(c.komira))
    assert_false(Bool(c.duckdb))
    assert_false(Bool(c.ratio))
    assert_equal(c.verdict, String("NO_RATIO"))
    assert_false(out.outcomes[0].timed)
    assert_true(out.outcomes[0].note.find(String("column 0")) >= 0)
    # the arm ran once (the check) and DuckDB ran the query once (its answer)
    assert_equal(rig.log_text(), String("prepare 8 4 16384|run rows|"))
    assert_equal(_runs(rig.sent_text(), String("SELECT revenue_q6")), 1)
    var report = format_run(out)
    assert_equal(run_status(out), 1)
    assert_true(report.find(String("== failed ==\ntpch/q6  EXEC_FAIL")) >= 0)


def test_rows_in_the_wrong_order_are_recorded_wrong_and_never_timed() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("ordered"), String('[{"k":1},\n{"k":2}]'), String(""), 2 * _MS))
    rules.append(Rule(String("unordered"), String('[{"k":1},\n{"k":2}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/o"), ARM_ROWS, String(""), _rows_keys(2, 1), 3 * _MS))
    scripts.append(Script(String("tpch/u"), ARM_ROWS, String(""), _rows_keys(2, 1), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^)
    var dropper = NoCacheDropper()
    var keys = List[OrderKey]()
    keys.append(OrderKey(0))
    var queries = List[QuerySpec]()
    queries.append(_q(String("o"), String("SELECT ordered"), keys^))
    queries.append(_q(String("u"), String("SELECT unordered")))

    var out = run_queries(session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    assert_equal(out.warm.cells[0].value.text(), String("UNVERIFIED:rows not in ORDER BY order"))
    assert_false(Bool(out.warm.cells[0].komira))
    assert_equal(out.warm.cells[1].value.text(), String("IDENTICAL"))
    assert_equal(out.warm.cells[1].ratio.value(), 1.5)
    assert_equal(_runs(rig.sent_text(), String("SELECT ordered")), 1)
    assert_equal(_runs(rig.sent_text(), String("SELECT unordered")), 7)


def test_a_refusal_is_listed_by_name_and_nothing_is_timed() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    rules.append(Rule(String("revenue_q1"), String('[{"revenue":1.0}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var arm = RefusalArm()
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))
    queries.append(_q(String("q1"), String("SELECT revenue_q1")))

    var out = run_queries(session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    assert_equal(len(out.warm.cells), 2)
    for i in range(2):
        assert_equal(out.warm.cells[i].stage.text(), String("UNSUPPORTED:no_engine_arm"))
        assert_false(Bool(out.warm.cells[i].komira))
        assert_false(Bool(out.warm.cells[i].ratio))
        assert_false(out.outcomes[i].timed)
    var report = format_run(out)
    assert_equal(run_status(out), 1)
    assert_true(
        report.find(String("== unserved (refused by the komira arm) ==\ntpch/q6  UNSUPPORTED:no_engine_arm\ntpch/q1  UNSUPPORTED:no_engine_arm\n"))
        >= 0
    )
    assert_true(report.find(String("== failed ==\nnone\n")) >= 0)
    assert_true(report.find(String("== cold ==\nnot requested\n")) >= 0)
    assert_equal(_runs(rig.sent_text(), String("SELECT revenue_q6")), 1)
    assert_equal(_runs(rig.sent_text(), String("SELECT revenue_q1")), 1)
    assert_equal(arm.asked, 2)
    # a result of refusals is still a result the report package reads
    var back = parse_result_json(write_result_json(out.warm))
    assert_equal(back.cells[0].stage.text(), String("UNSUPPORTED:no_engine_arm"))


def test_a_failure_of_the_arm_is_recorded_as_its_stage() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("revenue_q6"), String('[{"revenue":1.0}]'), String(""), 2 * _MS))
    rules.append(Rule(String("revenue_q1"), String('[{"revenue":1.0}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_BIND_FAIL, String("no column nope"), ResultSet(), 0))
    scripts.append(Script(String("tpch/q1"), ARM_EXEC_FAIL, String("out of memory"), ResultSet(), 0))
    var arm = FakeArm(rig.cell, rig.shared, scripts^)
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))
    queries.append(_q(String("q1"), String("SELECT revenue_q1")))

    var out = run_queries(session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    assert_equal(out.warm.cells[0].stage.text(), String("BIND_FAIL"))
    assert_equal(out.warm.cells[1].stage.text(), String("EXEC_FAIL"))
    assert_equal(out.outcomes[0].note, String("no column nope"))
    assert_equal(out.outcomes[1].note, String("out of memory"))
    assert_equal(write_result_json(out.warm).find(String("out of memory")), -1)
    assert_true(format_run(out).find(String("tpch/q6  BIND_FAIL  UNVERIFIED:komira did not run  no column nope")) >= 0)


def test_cold_and_warm_runs_are_separate_results() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^, 27 * _MS)
    var dropper = FakeDropper(rig.shared)
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))

    var out = run_queries(
        session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(), RunSettings(4, 16384, 2, 3, 2, 4, 1.0)
    )

    assert_true(Bool(out.cold))
    ref cold_result = out.cold.value()
    ref warm = out.warm.cells[0]
    ref cold = cold_result.cells[0]
    assert_equal(warm.komira.value().ms, 3.0)
    assert_equal(cold.komira.value().ms, 30.0)
    assert_equal(warm.duckdb.value().ms, 2.0)
    assert_equal(cold.duckdb.value().ms, 2.0)
    assert_equal(warm.reps, 3)
    assert_equal(cold.reps, 4)
    assert_equal(out.warm.run.sweeps, 2)
    assert_equal(cold_result.run.sweeps, 2)
    assert_equal(cold_result.run.reps, 4)
    assert_equal(len(cold.komira.value().ms_per_sweep), 2)
    assert_equal(cold.ratio.value(), 15.0)
    # one probe drop, the check, six warm runs with no drop, then a drop before
    # each run of each engine: komira's run sits between two drops per rep
    var want = String("prepare 8 4 16384|drop 8|run rows|")
    for _ in range(6):
        want += String("run count|")
    for _ in range(8):
        want += String("drop 8|close|prepare 8 4 16384|run count|drop 8|")
    assert_equal(rig.log_text(), want)
    var report = format_run(out)
    assert_true(report.find(String("== warm ==")) >= 0)
    assert_true(report.find(String("== cold ==\n")) >= 0)
    assert_equal(_count(report, String("== cold ==")), 1)
    assert_equal(_count(report, String("== warm ==")), 1)


def test_a_timed_run_that_returns_other_rows_than_the_check_ends_the_run() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("revenue"), String('[{"revenue":1.0}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(1.0), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^, 0, False, True)
    var none = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue")))
    with assert_raises(contains="rows for tpch/q6 in a timed run"):
        _ = run_queries(session, arm, none, BenchClock.manual(rig.cell), queries, _inputs(), _settings())


def _one_col(name: String, var cells: List[Cell]) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(name)
    rs.types.append(_declared_of_cell(cells[0]))
    for i in range(len(cells)):
        var r = List[Cell]()
        r.append(cells[i].copy())
        rs.add_row(r^)
    return rs^


def test_every_kind_of_difference_is_a_wrong_answer() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("d_int"), String('[{"k":1}]'), String(""), 2 * _MS))
    rules.append(Rule(String("d_str"), String('[{"k":"a"}]'), String(""), 2 * _MS))
    rules.append(Rule(String("d_rows"), String('[{"k":1},\n{"k":2}]'), String(""), 2 * _MS))
    rules.append(Rule(String("d_null"), String('[{"k":null}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    var a = List[Cell]()
    a.append(Cell.integer(2))
    scripts.append(Script(String("tpch/i"), ARM_ROWS, String(""), _one_col(String("k"), a^), 3 * _MS))
    var b = List[Cell]()
    b.append(Cell.text(String("b")))
    scripts.append(Script(String("tpch/s"), ARM_ROWS, String(""), _one_col(String("k"), b^), 3 * _MS))
    var c = List[Cell]()
    c.append(Cell.integer(1))
    scripts.append(Script(String("tpch/r"), ARM_ROWS, String(""), _one_col(String("k"), c^), 3 * _MS))
    var d = List[Cell]()
    d.append(Cell.integer(1))
    scripts.append(Script(String("tpch/n"), ARM_ROWS, String(""), _one_col(String("k"), d^), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^)
    var none = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("i"), String("SELECT d_int")))
    queries.append(_q(String("s"), String("SELECT d_str")))
    queries.append(_q(String("r"), String("SELECT d_rows")))
    queries.append(_q(String("n"), String("SELECT d_null")))

    var out = run_queries(session, arm, none, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    for i in range(4):
        assert_equal(out.warm.cells[i].value.text(), String("UNVERIFIED:answer differs from duckdb"))
        assert_false(Bool(out.warm.cells[i].komira))
        assert_false(out.outcomes[i].timed)
    assert_equal(rig.log_text(), String("prepare 8 4 16384|run rows|run rows|run rows|run rows|"))


def test_the_tolerance_is_printed_and_written() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("SELECT 1"), String('[{"v":1}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var arm = RefusalArm()
    var none = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT 1")))
    var out = run_queries(session, arm, none, BenchClock.manual(rig.cell), queries, _inputs(), _settings())
    var text = comparison_text()
    assert_true(text.startswith(String("float_rel_tol ") + String(REL_TOL) + String("\nfloat_abs_floor ") + String(ABS_FLOOR) + String("\n")))
    assert_true(
        format_run(out).find(String("float tolerance: relative ") + String(REL_TOL) + String(", absolute floor ") + String(ABS_FLOOR) + String(";")) >= 0
    )
    assert_equal(REL_TOL, 1e-9)
    assert_equal(ABS_FLOOR, 1e-6)


def test_cold_is_not_measured_when_the_cache_cannot_be_dropped() raises:
    for variant in range(2):
        var rig = Rig()
        var rules = List[Rule]()
        rules.append(Rule(String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
        var session = rig.duckdb(rules^)
        var scripts = List[Script]()
        scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
        var arm = FakeArm(rig.cell, rig.shared, scripts^)
        var queries = List[QuerySpec]()
        queries.append(_q(String("q6"), String("SELECT revenue_q6")))
        var out: RunOutput
        if variant == 0:
            var none = NoCacheDropper()
            out = run_queries(session, arm, none, BenchClock.manual(rig.cell), queries, _inputs(), _settings(2))
        else:
            var failing = FakeDropper(rig.shared, True)
            out = run_queries(session, arm, failing, BenchClock.manual(rig.cell), queries, _inputs(), _settings(2))
        assert_false(Bool(out.cold))
        assert_equal(out.warm.cells[0].verdict, String("FAIL"))
        assert_true(out.cold_note.byte_length() > 0)
        assert_true(format_run(out).find(String("== cold ==\nnot measured: ")) >= 0)
        if variant == 1:
            assert_true(out.cold_note.find(String("not permitted")) >= 0)


def test_the_result_round_trips_and_the_files_are_written() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("abc"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    rules.append(Rule(String("hello"), String('[{"revenue":1.0}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
    scripts.append(Script(String("tpch/q1"), ARM_ROWS, String(""), _rows_one(1.0), 1 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^, 27 * _MS)
    var dropper = FakeDropper(rig.shared)
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("abc")))
    queries.append(_q(String("q1"), String("hello")))

    var out = run_queries(
        session, arm, dropper, BenchClock.manual(rig.cell), queries, _inputs(), RunSettings(4, 16384, 2, 3, 2, 3, 1.0)
    )

    var text = write_result_json(out.warm)
    assert_equal(write_result_json(parse_result_json(text)), text)
    assert_equal(out.warm.cells[1].ratio.value(), 0.5)
    assert_equal(out.warm.cells[1].verdict, String("PASS"))

    var d = test_tmpdir() + "/runner_files"
    makedirs(d, exist_ok=True)
    write_run(out, d + "/")
    assert_equal(Path(d + "/warm/result.json").read_text(), text)
    assert_equal(
        write_result_json(parse_result_json(Path(d + "/cold/result.json").read_text())),
        write_result_json(out.cold.value()),
    )
    var digests = Path(d + "/queries.sha256").read_text()
    assert_equal(digests, queries_file_text(queries))
    assert_equal(Path(d + "/comparison.txt").read_text(), comparison_text())
    assert_true(
        digests.startswith(
            String("tpch/q6 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\n")
            + String("tpch/q1 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824\nlisting_sha256 ")
        )
    )
    assert_equal(out.outcomes[0].sha256, String("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))


def test_faults_end_the_run() raises:
    # DuckDB cannot answer the reference query
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("broken"), String(""), String("Binder Error: no such column\n"), 0))
    var session = rig.duckdb(rules^)
    var arm = RefusalArm()
    var none = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT broken")))
    with assert_raises(contains="duckdb failed on tpch/q6"):
        _ = run_queries(session, arm, none, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    # a time the clock cannot resolve is not a result
    var rig2 = Rig()
    var rules2 = List[Rule]()
    rules2.append(Rule(String("instant"), String('[{"revenue":1.0}]'), String(""), 0))
    var session2 = rig2.duckdb(rules2^)
    var scripts2 = List[Script]()
    scripts2.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(1.0), 3 * _MS))
    var arm2 = FakeArm(rig2.cell, rig2.shared, scripts2^)
    var queries2 = List[QuerySpec]()
    queries2.append(_q(String("q6"), String("SELECT instant")))
    with assert_raises(contains="below the clock resolution"):
        _ = run_queries(session2, arm2, none, BenchClock.manual(rig2.cell), queries2, _inputs(), _settings())

    # an arm that stops completing after its check passed
    var rig3 = Rig()
    var rules3 = List[Rule]()
    rules3.append(Rule(String("revenue"), String('[{"revenue":1.0}]'), String(""), 2 * _MS))
    var session3 = rig3.duckdb(rules3^)
    var scripts3 = List[Script]()
    scripts3.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(1.0), 3 * _MS))
    var arm3 = FakeArm(rig3.cell, rig3.shared, scripts3^, 0, True)
    var queries3 = List[QuerySpec]()
    queries3.append(_q(String("q6"), String("SELECT revenue")))
    with assert_raises(contains="stopped completing"):
        _ = run_queries(session3, arm3, none, BenchClock.manual(rig3.cell), queries3, _inputs(), _settings())

    # the query list
    var rig4 = Rig()
    var session4 = rig4.duckdb(List[Rule]())
    var arm4 = RefusalArm()
    with assert_raises(contains="at least one query"):
        _ = run_queries(session4, arm4, none, BenchClock.manual(rig4.cell), List[QuerySpec](), _inputs(), _settings())
    var other = List[QuerySpec]()
    other.append(QuerySpec(String("clickbench"), String("q0"), String("clickbench"), String("SELECT 1")))
    with assert_raises(contains="the run's dataset is tpch"):
        _ = run_queries(session4, arm4, none, BenchClock.manual(rig4.cell), other, _inputs(), _settings())
    var twice = List[QuerySpec]()
    twice.append(_q(String("q6"), String("SELECT 1")))
    twice.append(_q(String("q6"), String("SELECT 2")))
    with assert_raises(contains="listed twice"):
        _ = run_queries(session4, arm4, none, BenchClock.manual(rig4.cell), twice, _inputs(), _settings())


def _int_rows(declared: String) -> ResultSet:
    var rs = _rows_keys(1, 1)
    rs.types[0] = declared
    rs.rows.pop()
    return rs^


def test_a_different_declared_type_is_a_wrong_answer_by_name() raises:
    var rig = Rig()
    var rules = List[Rule]()
    var as_integer = String('[{"column_name":"k","column_type":"INTEGER","null":"YES","key":null,"default":null,"extra":null}]')
    var as_bigint = String('[{"column_name":"k","column_type":"BIGINT","null":"YES","key":null,"default":null,"extra":null}]')
    rules.append(Rule(String("t_int"), String('[{"k":1}]'), String(""), 2 * _MS, as_integer))
    rules.append(Rule(String("t_big"), String('[{"k":1}]'), String(""), 2 * _MS, as_bigint))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/a"), ARM_ROWS, String(""), _int_rows(String("BIGINT")), 3 * _MS))
    scripts.append(Script(String("tpch/b"), ARM_ROWS, String(""), _int_rows(String("BIGINT")), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^)
    var none = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("a"), String("SELECT t_int")))
    queries.append(_q(String("b"), String("SELECT t_big")))

    var out = run_queries(session, arm, none, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    # DuckDB's INTEGER against the arm's BIGINT, the same value: wrong, by name
    assert_equal(out.warm.cells[0].stage.text(), String("EXEC_FAIL"))
    assert_equal(out.warm.cells[0].value.text(), String("UNVERIFIED:answer differs from duckdb"))
    assert_false(Bool(out.warm.cells[0].komira))
    assert_false(out.outcomes[0].timed)
    ref note = out.outcomes[0].note
    assert_true(note.find(String("declared type")) >= 0, note)
    assert_true(note.find(String("INTEGER")) >= 0, note)
    assert_true(note.find(String("BIGINT")) >= 0, note)
    # the same value with the same declared type is timed
    assert_equal(out.warm.cells[1].value.text(), String("IDENTICAL"))
    assert_true(out.outcomes[1].timed)


comptime _REASON: String = "Arrow has no 128-bit integer: HUGEINT as DECIMAL(38,0)"
comptime _NINES: String = "99999999999999999999999999999999999999"


def _wide_rows(declared: String, last: String) raises -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("k"))
    rs.types.append(declared)
    var a = List[Cell]()
    a.append(Cell.decimal(String("5")))
    rs.add_row(a^)
    var b = List[Cell]()
    b.append(Cell.decimal(last))
    rs.add_row(b^)
    return rs^


def test_hugeint_against_decimal_38_0_is_a_departure_that_is_timed_and_never_a_pass() raises:
    var rig = Rig()
    var rules = List[Rule]()
    var as_hugeint = String('[{"column_name":"k","column_type":"HUGEINT","null":"YES","key":null,"default":null,"extra":null}]')
    var json = String('[{"k":"5"},{"k":"') + String(_NINES) + String('"}]')
    rules.append(Rule(String("h_same"), json, String(""), 2 * _MS, as_hugeint))
    rules.append(Rule(String("h_other"), json, String(""), 2 * _MS, as_hugeint))
    rules.append(Rule(String("h_big"), String('[{"k":"5"},{"k":"7"}]'), String(""), 2 * _MS, as_hugeint))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/a"), ARM_ROWS, String(""), _wide_rows(String("DECIMAL(38,0)"), String(_NINES)), 1 * _MS))
    scripts.append(Script(String("tpch/b"), ARM_ROWS, String(""), _wide_rows(String("DECIMAL(38,0)"), String("99999999999999999999999999999999999998")), 1 * _MS))
    scripts.append(Script(String("tpch/c"), ARM_ROWS, String(""), _wide_rows(String("BIGINT"), String("7")), 1 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^)
    var none = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("a"), String("SELECT h_same")))
    queries.append(_q(String("b"), String("SELECT h_other")))
    queries.append(_q(String("c"), String("SELECT h_big")))

    var out = run_queries(session, arm, none, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    ref a = out.warm.cells[0]
    assert_equal(a.stage.text(), String("EXEC_OK"))
    assert_equal(a.value.text(), String("DEPARTURE:") + String(_REASON))
    assert_true(out.outcomes[0].timed)
    assert_equal(a.ratio.value(), 0.5)
    assert_equal(a.verdict, String("DEPARTURE"))
    assert_equal(out.outcomes[0].value, String("DEPARTURE:") + String(_REASON))
    # a value a unit apart, and HUGEINT against BIGINT, are wrong answers
    assert_equal(out.warm.cells[1].value.text(), String("UNVERIFIED:answer differs from duckdb"))
    assert_false(out.outcomes[1].timed)
    assert_equal(out.warm.cells[2].value.text(), String("UNVERIFIED:answer differs from duckdb"))
    assert_true(out.outcomes[2].note.find(String("HUGEINT")) >= 0, out.outcomes[2].note)
    assert_true(out.outcomes[2].note.find(String("BIGINT")) >= 0, out.outcomes[2].note)
    var text = format_run(out)
    assert_true(text.find(String("PASS 0/3")) >= 0, text)
    assert_true(text.find(String("DEPARTURE 1/3")) >= 0, text)
    assert_true(text.find(String("DEPARTURE(") + String(_REASON) + String(")")) >= 0, text)
    assert_equal(run_status(out), 1)
    assert_true(comparison_text().find(String("allowed departure ") + String(_REASON) + String("\n")) >= 0)
    var only = List[ReportCell]()
    only.append(out.warm.cells[0].copy())
    var alone = out.warm.copy()
    alone.cells = only^
    assert_equal(exit_code(summarize(alone)), 0)
    var back = parse_result_json(write_result_json(alone))
    assert_equal(back.cells[0].value.text(), String("DEPARTURE:") + String(_REASON))


def test_only_the_fetch_of_a_query_is_described() raises:
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("revenue_q6"), String('[{"revenue":123.45}]'), String(""), 2 * _MS))
    rules.append(Rule(String("revenue_q1"), String('[{"revenue":1.0}]'), String(""), 2 * _MS))
    var session = rig.duckdb(rules^)
    var scripts = List[Script]()
    scripts.append(Script(String("tpch/q6"), ARM_ROWS, String(""), _rows_one(123.45), 3 * _MS))
    scripts.append(Script(String("tpch/q1"), ARM_ROWS, String(""), _rows_one(1.0), 3 * _MS))
    var arm = FakeArm(rig.cell, rig.shared, scripts^)
    var none = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), String("SELECT revenue_q6")))
    queries.append(_q(String("q1"), String("SELECT revenue_q1")))

    var out = run_queries(session, arm, none, BenchClock.manual(rig.cell), queries, _inputs(), _settings())

    assert_true(out.outcomes[0].timed and out.outcomes[1].timed)
    var sent = rig.sent_text()
    # per query: one fetch and one DESCRIBE, then 2 sweeps of 3 timed reps
    assert_equal(_runs(sent, String("SELECT revenue_q6")), 7)
    assert_equal(_runs(sent, String("SELECT revenue_q1")), 7)
    assert_equal(_count(sent, String("DESCRIBE SELECT revenue_q6")), 1)
    assert_equal(_count(sent, String("DESCRIBE SELECT revenue_q1")), 1)
    assert_equal(_count(sent, String("DESCRIBE")), 2)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
