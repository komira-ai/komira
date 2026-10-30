# The komira arm (`KomiraArm`, over `run_sql`) and the conversion of its result
# batches into the rows the comparison reads, tested against a lineitem-shaped
# Parquet file written here (the generator of komira_pipeline_exec's Q6 test,
# DECIMAL(15,2) money, DATE32 ship date) and a DuckDB that is a stand-in in
# this file: it prints marker lines and answers a query by looking its text up
# in a rule list, and moves a manual clock a set amount while a query "runs".
# No DuckDB binary is started. The komira side is the real engine, timed on
# the host clock; no test asserts a duration.
#
# The oracle is independent of the engine: the expected revenue of Q6 is an
# integer computed in this file, row by row, from the same table (cents times
# cents), written as DuckDB would print the DECIMAL(38,4) in JSON, and given to
# the stand-in as its answer.
#
# What each test proves, and the defect it catches:
# - test_q6_text_matches_the_oracle_and_is_timed: the corpus text of tpch/q6
#   run through run_queries on the real arm gives rows the runner finds equal
#   to the stand-in's answer; the cell is EXEC_OK and IDENTICAL, timed on both
#   sides with one row each; the TPC-H notice is printed once. Catches an arm
#   that returns a different value or kind, or rows the signature cannot match.
# - test_the_decimal_arrives_as_duckdb_prints_it: DuckDB's JSON quotes the
#   DECIMAL(38,4) sum of Q6; the cell the session makes from that and the cell
#   the arm makes are the same exact kind and compare identical, a unit in the
#   last place of DuckDB's text does not, and neither is a double or a text,
#   with the column named revenue. Catches a DECIMAL read as a text, rounded to
#   a double, or divided as a float.
# - test_a_join_is_refused_and_not_timed: a self-join is listed under
#   "unserved" as UNSUPPORTED:lower.LOWERING_UNCUTTABLE_NODE, the stand-in ran
#   it once (for its answer) and never timed, and the arm kept the engine's
#   whole message. Catches a refusal that is timed, hidden or recorded under a
#   token the result refuses (a path).
# - test_a_wrong_fake_answer_is_wrong_and_not_timed: an answer 1 percent away
#   from the engine's is EXEC_FAIL with "answer differs from duckdb", no time
#   on either side, and the stand-in ran the query once. Catches a check that
#   times what it did not verify.
# - test_not_materializing_counts_the_rows_of_the_checked_run: for Q6, a
#   filtered projection, a count and an empty sum, run(materialize=False)
#   returns the row count the materialized run has. Catches a count taken from
#   something else than the result.
# - test_results_cover_decimal_bigint_date_varchar_and_null: the engine's rows
#   for a projection and for aggregates are the typed cells the stand-in's JSON
#   would parse to: DECIMAL, DATE as text, BIGINT as integer, NULL (a NULL
#   input and an empty SUM) as null.
# - test_cold_reps_prepare_the_context_again: with cold sweeps, each cold rep
#   closes the arm and prepares a new context (3 prepares and 2 closes for one
#   warm preparation and 2 cold reps) and the timed rows still equal the
#   checked run's. Catches a cold rep that reuses the warm context.
# - test_an_unregistrable_table_ends_the_run_naming_it: a table whose file is
#   missing makes prepare raise naming the table; a run before prepare raises.
# - test_refusals_are_recorded_by_what_they_mean: against the real engine, an
#   unknown column is BIND_FAIL, three INT64 values of 2^62 summed are EXEC_FAIL
#   and a join is a refusal; outcome_of_refusal maps the messages of the other
#   steps. Catches an engine fault read as a missing feature.
# - test_conversion_of_unsigned_float_and_dictionary_columns: UINT64 at 2^63-1
#   is an integer and at 2^63 a real, UINT8/16/32 are integers, a FLOAT 0.1 is
#   the double 0.1 and not the widened float, a dictionary string column raises
#   RESULT_TYPE_UNSUPPORTED.
# - test_the_refusal_token_is_the_step_and_the_code: refusal_token on the
#   shapes the engine's messages have, none with a slash.
# - test_conversion_of_decimals_is_exact: DECIMAL(38,4) cells equal the
#   literal doubles of their exact text; DECIMAL scale 0 is an integer inside
#   64 bits and a real outside; NULL stays NULL.
# - test_conversion_of_dates: epoch, a leap day, the day before the epoch, the
#   first day of Q6's range, year 1 and the last day of year 9999 render as
#   YYYY-MM-DD; the day after year 9999 and the day before year 1 raise.
# - test_conversion_of_other_columns: INT64, FLOAT64, nullable VARCHAR and a
#   second batch are cells in order with the first batch's names; a column
#   type with no mapping raises RESULT_TYPE_UNSUPPORTED and no batch is an
#   empty result.

from std.memory import ArcPointer
from std.os import makedirs
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from komira_arrow.arrow_types import ArrowType
from komira_arrow.column import Column
from komira_arrow.decimal_array import Decimal128Array
from komira_arrow.dictionary_array import StringDictionaryArray
from komira_arrow.primitive_array import PrimitiveArray
from komira_arrow.schema import Field, RecordBatch, RecordBatchBuilder, SchemaBuilder
from komira_arrow.string_array import StringArray
from komira_buffer.heap_region import HeapRegion
from komira_bench_corpus.catalog import find_query
from komira_bench_data import DatasetFile, DatasetManifest
from komira_bench_duckdb import (
    BenchClock,
    Cell,
    DuckDbSession,
    DuckDbTransport,
    KIND_FLOAT,
    KIND_INT,
    KIND_NULL,
    KIND_TEXT,
    ResultSet,
    StdoutChunk,
    compare_signatures,
    signature_of,
)
from komira_bench_duckdb.text import slice_bytes
from komira_bench_report import DuckDbPin
from komira_parquet_writer.record_batch_writer import write_record_batch_to_parquet_bytes
from komira_pipeline_exec.tpch_q6 import (
    LineitemTable,
    Q6_DATE_FROM,
    Q6_DATE_TO,
    lineitem_batch,
    q6_table,
)
from komira_runtime_paths import test_tmpdir
from komira_scalar_arithmetic.decimal_arith import I128

from komira_bench_runner import (
    ARM_BIND_FAIL,
    ARM_EXEC_FAIL,
    ARM_REFUSED,
    ARM_ROWS,
    CacheDropper,
    HostFacts,
    KomiraArm,
    NoCacheDropper,
    QuerySpec,
    RESULT_TYPE_UNSUPPORTED,
    RunInputs,
    RunSettings,
    OUTCOME_BIND_FAILURE,
    OUTCOME_EXEC_FAILURE,
    OUTCOME_UNSUPPORTED,
    TableBinding,
    outcome_of_refusal,
    date32_text,
    decimal_cell,
    format_run,
    refusal_token,
    result_set_of,
    run_queries,
    run_status,
)

comptime _SHA: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
comptime _MS: Int = 1_000_000
comptime _MEMORY: Int = 268435456


# --- the DuckDB stand-in (as in test_runner) --------------------------------------


struct Rule(Copyable, Movable):
    var needle: String
    var json: String
    var cost: Int
    var types: String

    def __init__(out self, needle: String, json: String, cost: Int, types: String = String("")):
        self.needle = needle
        self.json = json
        self.cost = cost
        self.types = types


struct FakeDuckDb(DuckDbTransport):
    var clock: ArcPointer[Int]
    var sent: ArcPointer[List[String]]
    var rules: List[Rule]
    var chunks: List[String]
    var advances: List[Int]
    var at: Int
    var statement: String
    var cost: Int
    var mode: String

    def __init__(out self, clock: ArcPointer[Int], sent: ArcPointer[List[String]], var rules: List[Rule]):
        self.clock = clock
        self.sent = sent
        self.rules = rules^
        self.chunks = List[String]()
        self.advances = List[Int]()
        self.at = 0
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
                    # DuckDB's answer to DESCRIBE <query>: the rule's `types`
                    if self.mode == "json" and self.rules[i].types.byte_length() > 0:
                        self.emit(self.rules[i].types + String("\n"), 0)
                elif self.mode == "json" and self.rules[i].json.byte_length() > 0:
                    self.emit(self.rules[i].json + String("\n"), 0)
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
        return String("")

    def kill(mut self) raises:
        self.sent[].append(String("<killed>"))

    def finish(mut self) raises -> Int:
        return 0


struct CountingDropper(CacheDropper):
    var drops: ArcPointer[Int]

    def __init__(out self, drops: ArcPointer[Int]):
        self.drops = drops

    def can_drop(self) -> Bool:
        return True

    def drop(mut self, files: List[String]) raises:
        self.drops[] = self.drops[] + 1


struct Rig(Movable):
    var cell: ArcPointer[Int]
    var sent: ArcPointer[List[String]]

    def __init__(out self):
        self.cell = ArcPointer[Int](1000)
        self.sent = ArcPointer[List[String]](List[String]())

    def duckdb(self, var rules: List[Rule]) -> DuckDbSession[FakeDuckDb]:
        rules.insert(
            0,
            Rule(
                String("current_setting('threads')"),
                String('[{"threads":2,"memory_limit":"256.0 MiB","version":"v1.5.6","source_id":"069cc9f9b5"}]'),
                0,
            ),
        )
        return DuckDbSession[FakeDuckDb](FakeDuckDb(self.cell, self.sent, rules^), BenchClock.manual(self.cell))

    def sent_text(self) -> String:
        var out = String("")
        for i in range(len(self.sent[])):
            out += self.sent[][i]
        return out^


def _count(text: String, needle: String) -> Int:
    var n = 0
    var at = 0
    while True:
        var f = text.find(needle, at)
        if f < 0:
            return n
        n += 1
        at = f + needle.byte_length()


# --- the fixture and the oracle ----------------------------------------------------

comptime _LINEITEM_REL: String = "tpch/sf1/lineitem.parquet"


def _lineitem_path() raises -> String:
    return test_tmpdir() + "/" + String(_LINEITEM_REL)


def _write_fixture(ref t: LineitemTable) raises -> String:
    makedirs(test_tmpdir() + "/tpch/sf1", exist_ok=True)
    var path = _lineitem_path()
    var bytes = write_record_batch_to_parquet_bytes(lineitem_batch(t, 0, t.rows()), max_rows_per_rg=100)
    var fh = open(path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    return path^


def _oracle_revenue(ref t: LineitemTable) -> Int:
    """Q6 row by row, in cents times cents. A NULL discount drops the row; a
    NULL price leaves the product NULL, which SUM skips."""
    var revenue = 0
    for r in range(t.rows()):
        if t.discount_null[r]:
            continue
        var date_ok = t.shipdate[r] >= Q6_DATE_FROM and t.shipdate[r] < Q6_DATE_TO
        var disc_ok = t.discount[r] >= 5 and t.discount[r] <= 7
        var qty_ok = t.quantity[r] < 2400
        if date_ok and disc_ok and qty_ok and not t.price_null[r]:
            revenue += t.price[r] * t.discount[r]
    return revenue


def _fixed(v: Int, scale: Int) -> String:
    """A non-negative integer `v` with `scale` fractional digits, as DuckDB
    prints a DECIMAL in JSON."""
    var unit = 1
    for _ in range(scale):
        unit *= 10
    var frac = String(v % unit)
    while frac.byte_length() < scale:
        frac = "0" + frac
    return String(v // unit) + "." + frac


def _q6_rule(revenue: String) -> Rule:
    """The stand-in's answer to Q6 as DuckDB 1.5 prints it in `.mode json`: the
    DECIMAL(38,4) sum is QUOTED (the shell quotes DECIMAL, HUGEINT, UHUGEINT,
    UBIGINT and every non-numeric type), and DESCRIBE names the column type."""
    return Rule(
        String("revenue"),
        String('[{"revenue":"') + revenue + String('"}]'),
        2 * _MS,
        String('[{"column_name":"revenue","column_type":"DECIMAL(38,4)","null":"YES","key":null,"default":null,"extra":null}]'),
    )


def _duckdb_cell(value: String) raises -> Cell:
    """The cell the session makes from DuckDB's JSON for the Q6 sum `value`."""
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(_q6_rule(value))
    var session = rig.duckdb(rules^)
    var f = session.fetch(_q6())
    assert_true(f.ok(), f.error)
    return f.rows.rows[0][0].copy()


def _one_row(cell: Cell) -> ResultSet:
    var rs = ResultSet()
    rs.names.append(String("revenue"))
    var row = List[Cell]()
    row.append(cell.copy())
    rs.add_row(row^)
    return rs^


def _runs(text: String, query: String) -> Int:
    """How many times `query` was run (its DESCRIBE is not a run)."""
    return _count(text, query) - _count(text, String("DESCRIBE ") + query)


def _manifest(rows: Int) -> DatasetManifest:
    var files = List[DatasetFile]()
    files.append(DatasetFile.unrecorded(String(_LINEITEM_REL), rows))
    return DatasetManifest(String("tpch"), String("sf1"), String(""), files^)


def _inputs(rows: Int) raises -> RunInputs:
    return RunInputs(
        _manifest(rows),
        test_tmpdir(),
        String(_SHA),
        DuckDbPin(String("1.5.6"), String(_SHA), String("PINNED")),
        HostFacts(String("test-class"), String("test cpu"), Int64(2), Int64(17179869184), String("linux 6.1"), String("0.0.0-test")),
    )


def _settings(cold_sweeps: Int = 0) -> RunSettings:
    return RunSettings(2, _MEMORY, 2, 2, cold_sweeps, 2, 1.0)


def _q(id: String, text: String) -> QuerySpec:
    return QuerySpec(String("tpch"), id, String("tpch"), text)


def _q6() raises -> String:
    return find_query(String("tpch/q6")).text


def _tables() raises -> List[TableBinding]:
    var out = List[TableBinding]()
    out.append(TableBinding(String("lineitem"), _lineitem_path(), -1))
    return out^


def _prepared(rows: Int = 0) raises -> KomiraArm:
    var arm = KomiraArm()
    arm.prepare(_tables(), 2, _MEMORY)
    return arm^


# --- tests: the arm in a run --------------------------------------------------------


def test_q6_text_matches_the_oracle_and_is_timed() raises:
    var t = q6_table(600)
    var want = _oracle_revenue(t)
    assert_true(want > 0)
    _ = _write_fixture(t)
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(_q6_rule(_fixed(want, 4)))
    var session = rig.duckdb(rules^)
    var arm = KomiraArm()
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), _q6()))

    var out = run_queries(session, arm, dropper, BenchClock.system(), queries, _inputs(t.rows()), _settings())
    arm.close()

    ref c = out.warm.cells[0]
    assert_equal(c.id, String("tpch/q6"))
    assert_equal(c.stage.text(), String("EXEC_OK"))
    assert_equal(c.value.text(), String("IDENTICAL"))
    assert_true(Bool(c.komira))
    assert_true(Bool(c.duckdb))
    assert_equal(c.komira.value().rows, Int64(1))
    assert_equal(c.duckdb.value().rows, Int64(1))
    assert_equal(c.duckdb.value().ms, 2.0)
    assert_true(out.outcomes[0].timed)
    assert_equal(arm.prepares, 1)
    assert_equal(arm.closes, 1)
    # DuckDB ran the query once for its answer and four times timed (2 sweeps of 2)
    assert_equal(_runs(rig.sent_text(), _q6()), 5)
    var report = format_run(out)
    assert_equal(_count(report, String("derived from TPC-H; not comparable to published TPC-H results")), 1)


def test_the_decimal_arrives_as_duckdb_prints_it() raises:
    """DuckDB's JSON quotes the DECIMAL and the session turns it into the same
    kind of cell the arm makes: both sides are one exact kind, neither a
    double nor a text."""
    var t = q6_table(600)
    var want = _oracle_revenue(t)
    _ = _write_fixture(t)
    var arm = _prepared()
    var answer = arm.run(_q(String("q6"), _q6()), True)
    assert_equal(answer.kind, ARM_ROWS)
    assert_equal(answer.row_count, Int64(1))
    assert_equal(answer.rows.names[0], String("revenue"))
    ref cell = answer.rows.rows[0][0]
    assert_true(cell.kind != KIND_FLOAT, "a DECIMAL is not rounded to a double")
    assert_true(cell.kind != KIND_TEXT)
    var theirs = _duckdb_cell(_fixed(want, 4))
    assert_equal(cell.kind, theirs.kind)
    var verdict = compare_signatures(signature_of(_one_row(cell)), signature_of(_one_row(theirs)))
    assert_true(verdict.identical, verdict.label())
    # a unit in the last place of the same DuckDB text is a different answer
    var off = _duckdb_cell(_fixed(want + 1, 4))
    assert_false(compare_signatures(signature_of(_one_row(cell)), signature_of(_one_row(off))).identical)
    arm.close()


def test_a_join_is_refused_and_not_timed() raises:
    var t = q6_table(50)
    _ = _write_fixture(t)
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(Rule(String("join lineitem"), String('[{"n":50}]'), 2 * _MS))
    var session = rig.duckdb(rules^)
    var arm = KomiraArm()
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(
        _q(String("j"), String("select count(*) as n from lineitem a join lineitem b on a.l_orderkey = b.l_orderkey"))
    )

    var out = run_queries(session, arm, dropper, BenchClock.system(), queries, _inputs(t.rows()), _settings())

    ref c = out.warm.cells[0]
    assert_equal(c.stage.text(), String("UNSUPPORTED:lower.LOWERING_UNCUTTABLE_NODE"))
    assert_false(Bool(c.komira))
    assert_false(Bool(c.duckdb))
    assert_false(out.outcomes[0].timed)
    assert_equal(run_status(out), 1)
    var report = format_run(out)
    assert_true(
        report.find(
            String("== unserved (refused by the komira arm) ==\ntpch/j  UNSUPPORTED:lower.LOWERING_UNCUTTABLE_NODE\n")
        )
        >= 0
    )
    assert_equal(_count(rig.sent_text(), String("join lineitem")), 1)
    assert_true(arm.last_refusal.startswith(String("lower: LOWERING_UNCUTTABLE_NODE")))
    arm.close()


def test_a_wrong_fake_answer_is_wrong_and_not_timed() raises:
    var t = q6_table(600)
    var want = _oracle_revenue(t)
    _ = _write_fixture(t)
    var rig = Rig()
    var rules = List[Rule]()
    var wrong = want + want // 100 + 1
    rules.append(_q6_rule(_fixed(wrong, 4)))
    var session = rig.duckdb(rules^)
    var arm = KomiraArm()
    var dropper = NoCacheDropper()
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), _q6()))

    var out = run_queries(session, arm, dropper, BenchClock.system(), queries, _inputs(t.rows()), _settings())
    arm.close()

    ref c = out.warm.cells[0]
    assert_equal(c.stage.text(), String("EXEC_FAIL"))
    assert_equal(c.value.text(), String("UNVERIFIED:answer differs from duckdb"))
    assert_false(Bool(c.komira))
    assert_false(Bool(c.duckdb))
    assert_false(Bool(c.ratio))
    assert_false(out.outcomes[0].timed)
    assert_equal(run_status(out), 1)
    # the stand-in ran the query once, for its answer, and never timed
    assert_equal(_runs(rig.sent_text(), _q6()), 1)
    assert_equal(arm.prepares, 1)


def test_not_materializing_counts_the_rows_of_the_checked_run() raises:
    var t = q6_table(600)
    _ = _write_fixture(t)
    var arm = _prepared()
    var texts = List[String]()
    texts.append(_q6())
    texts.append(String("select l_orderkey, l_discount from lineitem where l_orderkey < 25"))
    texts.append(String("select count(*) as n from lineitem"))
    texts.append(String("select sum(l_extendedprice) as s from lineitem where l_orderkey < 0"))
    for i in range(len(texts)):
        var q = _q(String("c") + String(i), texts[i])
        var checked = arm.run(q, True)
        assert_equal(checked.kind, ARM_ROWS, "query " + String(i) + " did not complete: " + arm.last_refusal)
        var counted = arm.run(q, False)
        assert_equal(counted.kind, ARM_ROWS)
        assert_equal(counted.row_count, checked.row_count)
        assert_equal(counted.row_count, Int64(checked.rows.row_count()))
        assert_equal(counted.rows.row_count(), 0)
    assert_equal(arm.run(_q(String("c1"), texts[1]), False).row_count, Int64(25))
    arm.close()


def test_results_cover_decimal_bigint_date_varchar_and_null() raises:
    var t = q6_table(600)
    _ = _write_fixture(t)
    var arm = _prepared()

    var n = arm.run(_q(String("n"), String("select count(*) as n from lineitem")), True)
    assert_equal(n.kind, ARM_ROWS, arm.last_refusal)
    assert_equal(n.rows.rows[0][0].kind, KIND_INT)
    assert_equal(n.rows.rows[0][0].i, Int64(t.rows()))

    var empty = arm.run(_q(String("e"), String("select sum(l_extendedprice) as s from lineitem where l_orderkey < 0")), True)
    assert_equal(empty.kind, ARM_ROWS, arm.last_refusal)
    assert_equal(empty.rows.row_count(), 1)
    assert_equal(empty.rows.rows[0][0].kind, KIND_NULL)

    var p = arm.run(
        _q(String("p"), String("select l_orderkey, l_extendedprice, l_shipdate from lineitem where l_orderkey < 25")), True
    )
    assert_equal(p.kind, ARM_ROWS, arm.last_refusal)
    assert_equal(p.rows.row_count(), 25)
    assert_equal(p.rows.names[2], String("l_shipdate"))
    var seen = 0
    for r in range(p.rows.row_count()):
        ref row = p.rows.rows[r]
        assert_equal(row[0].kind, KIND_INT)
        var k = Int(row[0].i)
        assert_true(k >= 0 and k < 25)
        if t.price_null[k]:
            assert_equal(row[1].kind, KIND_NULL)
        else:
            assert_equal(row[1].kind, KIND_FLOAT)
            assert_true(row[1].f == atof(_fixed(t.price[k], 2)))
        assert_equal(row[2].kind, KIND_TEXT)
        assert_equal(row[2].s, date32_text(t.shipdate[k]))
        seen += 1
    assert_equal(seen, 25)
    arm.close()


def test_cold_reps_prepare_the_context_again() raises:
    var t = q6_table(600)
    var want = _oracle_revenue(t)
    _ = _write_fixture(t)
    var rig = Rig()
    var rules = List[Rule]()
    rules.append(_q6_rule(_fixed(want, 4)))
    var session = rig.duckdb(rules^)
    var arm = KomiraArm()
    var drops = ArcPointer[Int](0)
    var dropper = CountingDropper(drops)
    var queries = List[QuerySpec]()
    queries.append(_q(String("q6"), _q6()))

    var out = run_queries(session, arm, dropper, BenchClock.system(), queries, _inputs(t.rows()), _settings(1))
    arm.close()

    assert_true(Bool(out.cold))
    ref cold = out.cold.value().cells[0]
    assert_equal(cold.stage.text(), String("EXEC_OK"))
    assert_equal(cold.value.text(), String("IDENTICAL"))
    assert_equal(cold.komira.value().rows, Int64(1))
    assert_equal(out.cold.value().run.reps, 2)
    # one preparation for the check and the warm runs, one per cold rep; every
    # context but the last is closed by the cold loop, the last by the caller
    assert_equal(arm.prepares, 3)
    assert_equal(arm.closes, 3)
    assert_true(drops[] > 0)


def test_an_unregistrable_table_ends_the_run_naming_it() raises:
    var arm = KomiraArm()
    var tables = List[TableBinding]()
    tables.append(TableBinding(String("orders"), test_tmpdir() + "/komira_arm_no_such_file.parquet", -1))
    with assert_raises(contains="cannot register table orders"):
        arm.prepare(tables, 2, _MEMORY)
    assert_false(arm.is_prepared())
    with assert_raises(contains="not prepared"):
        _ = arm.run(_q(String("x"), String("select 1")), True)


def test_the_refusal_token_is_the_step_and_the_code() raises:
    assert_equal(
        refusal_token(String("lower"), String("LOWERING_UNCUTTABLE_NODE: PLAN_JOIN (a join)")),
        String("lower.LOWERING_UNCUTTABLE_NODE"),
    )
    assert_equal(
        refusal_token(String("execute"), String("EXECUTE_UNSUPPORTED_PARAM: the plan scans an in-memory batch")),
        String("execute.EXECUTE_UNSUPPORTED_PARAM"),
    )
    assert_equal(refusal_token(String("parse"), String("SQL syntax error at 1:1")), String("parse"))
    assert_equal(refusal_token(String("bind"), String("table '/data/x.parquet' not found")), String("bind"))
    assert_equal(refusal_token(String("bind"), String("")), String("bind"))
    assert_equal(refusal_token(String("execute"), String("AB: short code")), String("execute"))
    var t = refusal_token(String("bind"), String("STATEMENT_NOT_A_QUERY: only a query runs here"))
    assert_equal(t, String("bind.STATEMENT_NOT_A_QUERY"))
    assert_equal(t.find(String("/")), -1)


# --- tests: the conversion ----------------------------------------------------------


def _i128(v: Int) -> I128:
    return Scalar[DType.int64](v).cast[DType.int128]()


def _i64(a: Int, b: Int = -1, n: Int = 1) -> List[Int64]:
    var out = List[Int64]()
    out.append(Int64(a))
    if n == 2:
        out.append(Int64(b))
    return out^


def _f64(a: Float64, b: Float64 = 0.0, n: Int = 1) -> List[Float64]:
    var out = List[Float64]()
    out.append(a)
    if n == 2:
        out.append(b)
    return out^


def _i32(a: Int, b: Int = -1, n: Int = 1) -> List[Int32]:
    var out = List[Int32]()
    out.append(Int32(a))
    if n == 2:
        out.append(Int32(b))
    return out^


def _batches_of(var batch: RecordBatch) -> List[RecordBatch]:
    var out = List[RecordBatch]()
    out.append(batch^)
    return out^


def test_conversion_of_decimals_is_exact() raises:
    var arr = Decimal128Array.allocate_nullable(5, 38, 4)
    arr.set_i128(0, _i128(123456789012345678))
    arr.set_i128(1, _i128(-5))
    arr.set_i128(2, _i128(0))
    arr.set_null(3)
    arr.set_i128(4, _i128(7))
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field.decimal128("d", 38, 4, True))
    builder.add_column(Column.from_decimal128(arr^))
    var rs = result_set_of(_batches_of(builder.build(sb.build())))
    assert_equal(rs.names[0], String("d"))
    assert_equal(rs.row_count(), 5)
    assert_equal(rs.rows[0][0].kind, KIND_FLOAT)
    assert_true(rs.rows[0][0].f == 12345678901234.5678)
    assert_true(rs.rows[1][0].f == -0.0005)
    assert_equal(rs.rows[2][0].kind, KIND_FLOAT)
    assert_true(rs.rows[2][0].f == 0.0)
    assert_equal(rs.rows[3][0].kind, KIND_NULL)
    assert_true(rs.rows[4][0].f == 0.0007)
    # scale 0 is an integer while it fits 64 bits and a real beyond
    var small = decimal_cell(_i128(-42), 0)
    assert_equal(small.kind, KIND_INT)
    assert_equal(small.i, Int64(-42))
    var edge = decimal_cell(I128(9223372036854775807), 0)
    assert_equal(edge.kind, KIND_INT)
    assert_equal(edge.i, Int64(9223372036854775807))
    var big = decimal_cell(I128(1000000000) * I128(1000000000) * I128(10), 0)
    assert_equal(big.kind, KIND_FLOAT)
    assert_true(big.f == 1e19)


def test_conversion_of_dates() raises:
    assert_equal(date32_text(0), String("1970-01-01"))
    assert_equal(date32_text(-1), String("1969-12-31"))
    assert_equal(date32_text(Q6_DATE_FROM), String("1994-01-01"))
    assert_equal(date32_text(Q6_DATE_TO), String("1995-01-01"))
    assert_equal(date32_text(11016), String("2000-02-29"))
    assert_equal(date32_text(2932896), String("9999-12-31"))
    assert_equal(date32_text(-719162), String("0001-01-01"))
    with assert_raises(contains=RESULT_TYPE_UNSUPPORTED):
        _ = date32_text(2932897)
    with assert_raises(contains=RESULT_TYPE_UNSUPPORTED):
        _ = date32_text(-719163)


def test_conversion_of_other_columns() raises:
    var ids = PrimitiveArray[DType.int64].from_list(_i64(3, -4, 2))
    var xs = PrimitiveArray[DType.float64].from_list(_f64(1.5, -0.25, 2))
    var names = List[String]()
    names.append(String("ab"))
    names.append(String(""))
    var valid = List[Bool]()
    valid.append(True)
    valid.append(False)
    var strs = StringArray.from_strings_with_validity(names, valid)
    var days = PrimitiveArray[DType.int32].from_list(_i32(8766, 0, 2))
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field("id", ArrowType.INT64, False))
    builder.add_column(Column.from_primitive[DType.int64](ids^))
    sb.add_field(Field("x", ArrowType.FLOAT64, False))
    builder.add_column(Column.from_primitive[DType.float64](xs^))
    sb.add_field(Field("s", ArrowType.STRING, True))
    builder.add_column(Column.from_string(strs^))
    sb.add_field(Field("d", ArrowType.DATE32, False))
    builder.add_column(Column.from_primitive_with_arrow_type[DType.int32](days^, ArrowType.DATE32))
    var batches = _batches_of(builder.build(sb.build()))

    var more_ids = PrimitiveArray[DType.int64].from_list(_i64(9))
    var more_xs = PrimitiveArray[DType.float64].from_list(_f64(2.0))
    var more_names = List[String]()
    more_names.append(String("z"))
    var more_strs = StringArray.from_strings(more_names)
    var more_days = PrimitiveArray[DType.int32].from_list(_i32(11016))
    var sb2 = SchemaBuilder()
    var builder2 = RecordBatchBuilder()
    sb2.add_field(Field("id", ArrowType.INT64, False))
    builder2.add_column(Column.from_primitive[DType.int64](more_ids^))
    sb2.add_field(Field("x", ArrowType.FLOAT64, False))
    builder2.add_column(Column.from_primitive[DType.float64](more_xs^))
    sb2.add_field(Field("s", ArrowType.STRING, True))
    builder2.add_column(Column.from_string(more_strs^))
    sb2.add_field(Field("d", ArrowType.DATE32, False))
    builder2.add_column(Column.from_primitive_with_arrow_type[DType.int32](more_days^, ArrowType.DATE32))
    batches.append(builder2.build(sb2.build()))

    var rs = result_set_of(batches)
    assert_equal(rs.column_count(), 4)
    assert_equal(rs.names[0], String("id"))
    assert_equal(rs.names[3], String("d"))
    assert_equal(rs.row_count(), 3)
    assert_equal(rs.rows[0][0].i, Int64(3))
    assert_equal(rs.rows[1][0].i, Int64(-4))
    assert_equal(rs.rows[2][0].i, Int64(9))
    assert_equal(rs.rows[0][1].kind, KIND_FLOAT)
    assert_true(rs.rows[1][1].f == -0.25)
    assert_equal(rs.rows[0][2].kind, KIND_TEXT)
    assert_equal(rs.rows[0][2].s, String("ab"))
    assert_equal(rs.rows[1][2].kind, KIND_NULL)
    assert_equal(rs.rows[2][2].s, String("z"))
    assert_equal(rs.rows[0][3].s, String("1994-01-01"))
    assert_equal(rs.rows[1][3].s, String("1970-01-01"))
    assert_equal(rs.rows[2][3].s, String("2000-02-29"))

    assert_equal(result_set_of(List[RecordBatch]()).row_count(), 0)

    var stamps = PrimitiveArray[DType.int64].from_list(_i64(1))
    var sb3 = SchemaBuilder()
    var builder3 = RecordBatchBuilder()
    sb3.add_field(Field("t", ArrowType.TIMESTAMP_US, False))
    builder3.add_column(Column.from_primitive_with_arrow_type[DType.int64](stamps^, ArrowType.TIMESTAMP_US))
    with assert_raises(contains=RESULT_TYPE_UNSUPPORTED):
        _ = result_set_of(_batches_of(builder3.build(sb3.build())))


def test_refusals_are_recorded_by_what_they_mean() raises:
    var t = q6_table(50)
    _ = _write_fixture(t)
    makedirs(test_tmpdir() + "/tpch/sf1", exist_ok=True)
    var big_path = test_tmpdir() + "/tpch/sf1/komira_arm_big.parquet"
    var v = PrimitiveArray[DType.int64].allocate(3)
    for i in range(3):
        v.set(i, Int64(4611686018427387904))
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(Field("v", ArrowType.INT64, False))
    builder.add_column(Column.from_primitive[DType.int64](v^))
    var bytes = write_record_batch_to_parquet_bytes(builder.build(sb.build()), max_rows_per_rg=100)
    var fh = open(big_path, "w")
    fh.write_bytes(Span(bytes))
    fh.close()
    var tables = _tables()
    tables.append(TableBinding(String("big"), big_path, -1))
    var arm = KomiraArm()
    arm.prepare(tables, 2, _MEMORY)

    var unknown = arm.run(_q(String("u"), String("select no_such_column from lineitem")), True)
    assert_equal(unknown.kind, ARM_BIND_FAIL, arm.last_refusal)
    assert_true(unknown.detail.startswith(String("bind: ")))

    var overflow = arm.run(_q(String("o"), String("select sum(v) as s from big")), True)
    assert_equal(overflow.kind, ARM_EXEC_FAIL, arm.last_refusal)
    assert_true(overflow.detail.startswith(String("execute: ")))

    var join = arm.run(
        _q(String("j"), String("select count(*) from lineitem a join lineitem b on a.l_orderkey = b.l_orderkey")), True
    )
    assert_equal(join.kind, ARM_REFUSED)
    assert_equal(join.detail, String("lower.LOWERING_UNCUTTABLE_NODE"))
    arm.close()

    assert_equal(outcome_of_refusal(String("parse"), String("SQL syntax error: x")), OUTCOME_UNSUPPORTED)
    assert_equal(outcome_of_refusal(String("bind"), String("SQL not supported: NATURAL / USING")), OUTCOME_UNSUPPORTED)
    assert_equal(outcome_of_refusal(String("bind"), String("STATEMENT_NOT_A_QUERY: only")), OUTCOME_UNSUPPORTED)
    assert_equal(outcome_of_refusal(String("bind"), String("SQL bind error: unknown column")), OUTCOME_BIND_FAILURE)
    assert_equal(outcome_of_refusal(String("optimize"), String("OPTIMIZE_UNRESOLVED_SCALAR: x")), OUTCOME_UNSUPPORTED)
    assert_equal(outcome_of_refusal(String("optimize"), String("internal error")), OUTCOME_EXEC_FAILURE)
    assert_equal(outcome_of_refusal(String("lower"), String("LOWERING_INPUTS_SCAN_COUNT: x")), OUTCOME_UNSUPPORTED)
    assert_equal(outcome_of_refusal(String("lower"), String("table schema changed")), OUTCOME_EXEC_FAILURE)
    assert_equal(outcome_of_refusal(String("execute"), String("EXECUTE_UNSUPPORTED_PARAM: x")), OUTCOME_UNSUPPORTED)
    assert_equal(outcome_of_refusal(String("execute"), String("sum is outside the 64-bit range")), OUTCOME_EXEC_FAILURE)


def _one_column_batch(var name: String, var field: Field, var col: Column[HeapRegion]) raises -> List[RecordBatch]:
    var sb = SchemaBuilder()
    var builder = RecordBatchBuilder()
    sb.add_field(field^)
    builder.add_column(col^)
    return _batches_of(builder.build(sb.build()))


def test_conversion_of_unsigned_float_and_dictionary_columns() raises:
    var u64 = PrimitiveArray[DType.uint64].allocate(2)
    u64.set(0, UInt64(9223372036854775807))
    u64.set(1, UInt64(9223372036854775808))
    var rs = result_set_of(
        _one_column_batch(String("u"), Field("u", ArrowType.UINT64, False), Column.from_primitive[DType.uint64](u64^))
    )
    assert_equal(rs.rows[0][0].kind, KIND_INT)
    assert_equal(rs.rows[0][0].i, Int64(9223372036854775807))
    assert_equal(rs.rows[1][0].kind, KIND_FLOAT)
    assert_true(rs.rows[1][0].f == 9223372036854775808.0)

    var u32 = PrimitiveArray[DType.uint32].allocate(1)
    u32.set(0, UInt32(4294967295))
    var r32 = result_set_of(
        _one_column_batch(String("u"), Field("u", ArrowType.UINT32, False), Column.from_primitive[DType.uint32](u32^))
    )
    assert_equal(r32.rows[0][0].kind, KIND_INT)
    assert_equal(r32.rows[0][0].i, Int64(4294967295))
    var u16 = PrimitiveArray[DType.uint16].allocate(1)
    u16.set(0, UInt16(65535))
    var r16 = result_set_of(
        _one_column_batch(String("u"), Field("u", ArrowType.UINT16, False), Column.from_primitive[DType.uint16](u16^))
    )
    assert_equal(r16.rows[0][0].i, Int64(65535))
    var u8 = PrimitiveArray[DType.uint8].allocate(1)
    u8.set(0, UInt8(255))
    var r8 = result_set_of(
        _one_column_batch(String("u"), Field("u", ArrowType.UINT8, False), Column.from_primitive[DType.uint8](u8^))
    )
    assert_equal(r8.rows[0][0].kind, KIND_INT)
    assert_equal(r8.rows[0][0].i, Int64(255))

    var f32 = PrimitiveArray[DType.float32].allocate(1)
    f32.set(0, Float32(0.1))
    var rf = result_set_of(
        _one_column_batch(String("f"), Field("f", ArrowType.FLOAT32, False), Column.from_primitive[DType.float32](f32^))
    )
    assert_equal(rf.rows[0][0].kind, KIND_FLOAT)
    assert_true(rf.rows[0][0].f == atof(String("0.1")), "a FLOAT must be read from its shortest text")
    assert_true(rf.rows[0][0].f != Float64(Float32(0.1)))

    var idx = PrimitiveArray[DType.int32].allocate(2)
    idx.set(0, Int32(1))
    idx.set(1, Int32(0))
    var dict_values = List[String]()
    dict_values.append(String("a"))
    dict_values.append(String("b"))
    var dict = StringDictionaryArray.from_parts(idx^, StringArray.from_strings(dict_values))
    with assert_raises(contains=RESULT_TYPE_UNSUPPORTED):
        _ = result_set_of(
            _one_column_batch(String("d"), Field("d", ArrowType.STRING, False), Column.from_dictionary(dict^))
        )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
