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
    OrderKey,
    ResultSet,
    StdoutChunk,
    parse_json_rows,
)
from komira_bench_duckdb.cells import KIND_FLOAT, KIND_TEXT
from komira_bench_duckdb.text import slice_bytes
from komira_bench_report import (
    DuckDbPin,
    parse_result_json,
    write_result_json,
)
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

    def __init__(out self, needle: String, json: String, error: String, cost: Int, types: String = String("")):
        self.needle = needle
        self.json = json
        self.error = error
        self.cost = cost
        self.types = types

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

    def __init__(
        out self, clock: ArcPointer[Int], sent: ArcPointer[List[String]], var rules: List[Rule]
    ):
        self.clock = clock
        self.sent = sent
        self.rules = rules^
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
                self.errors += self.rules[i].error
                self.cost = self.rules[i].cost
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


def _settings_rule() -> Rule:
    return Rule(
        String("current_setting('threads')"),
        String('[{"threads":4,"memory_limit":"16.0 KiB","version":"v1.5.6","source_id":"069cc9f9b5"}]'),
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

    def __init__(
        out self,
        clock: ArcPointer[Int],
        shared: ArcPointer[Shared],
        var scripts: List[Script],
        cold_penalty: Int = 0,
        stop_after_check: Bool = False,
        wrong_count: Bool = False,
    ):
        self.wrong_count = wrong_count
        self.clock = clock
        self.shared = shared
        self.scripts = scripts^
        self.cold_penalty = cold_penalty
        self.stop_after_check = stop_after_check

    def label(self) -> String:
        return String("fake")

    def prepare(mut self, tables: List[TableBinding], threads: Int, memory_limit_bytes: Int) raises:
        self.shared[].log.append(
            String("prepare ") + String(len(tables)) + String(" ") + String(threads) + String(" ") + String(memory_limit_bytes)
        )

    def run(mut self, query: QuerySpec, materialize: Bool) raises -> ArmAnswer:
        self.shared[].log.append(String("run ") + (String("rows") if materialize else String("count")))
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

    def __init__(out self):
        self.cell = ArcPointer[Int](1000)
        self.sent = ArcPointer[List[String]](List[String]())
        self.shared = ArcPointer[Shared](Shared())

    def duckdb(self, var rules: List[Rule]) -> DuckDbSession[FakeDuckDb]:
        rules.insert(0, _settings_rule())
        return DuckDbSession[FakeDuckDb](FakeDuckDb(self.cell, self.sent, rules^), BenchClock.manual(self.cell))

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
    var session = rig.duckdb(List[Rule]())
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
