# The recorded answers, over a DuckDB that lives in the test: it reads what the
# session sends, answers a query by looking its text up in a rule list and
# prints the marker lines the session waits for. No process is started and
# nothing is timed.
#
# What each test proves:
# - test_the_corpus_answers_round_trip_through_the_reference_reader: the text
#   written for the 22 corpus queries is read back by bench_duckdb's reader as
#   22 answers in the suite's order, each with the row count, the declared
#   column types and ORDER BY keys DuckDB's answer and the key table gave, and
#   a query with no ORDER BY records none.
# - test_the_header_names_the_notice_the_queries_the_duckdb_and_the_data: the
#   comment lines say the results are not TPC-H results, give the suite's
#   digest, the DuckDB version and the lock fingerprint, and the reader skips
#   them, and a header with no final newline still ends its line.
# - test_the_views_are_the_tables_the_queries_name: one CREATE OR REPLACE VIEW
#   per table over its file, with a quote in a path doubled; a name list and a
#   path list of different lengths are refused; a refused view names its table.
# - test_a_query_duckdb_refuses_fails_naming_the_query: DuckDB's text is in the
#   message with the query's key, and no answer is written for it.
# - test_an_answer_out_of_its_order_fails_naming_the_query: rows that do not
#   follow the query's keys raise instead of being recorded as the answer.
# - test_a_column_that_mixes_numbers_and_text_is_refused: the answer has no
#   recordable form and the message names the column.
# - test_an_answer_with_no_rows_is_refused: a query that returns no rows raises
#   naming the query, because such an answer records no columns and would check
#   nothing.
# - test_the_run_writes_the_answers_and_the_lock_and_names_one_in_the_other: the
#   answers file, the lock file and the 22 query texts (byte for byte the
#   corpus's) exist, the file's header holds the lock's
#   fingerprint, DuckDB was started on one thread with the memory limit asked
#   for and every file of the manifest is a view.
# - test_unusable_data_stops_before_duckdb_is_asked_anything: a missing table
#   file raises with the verification report and nothing was sent.
# - test_an_existing_answers_file_is_never_replaced: the file keeps its bytes
#   and DuckDB is not started.

from std.memory import ArcPointer
from std.os import makedirs
from std.os.path import exists
from std.pathlib import Path
from std.testing import TestSuite, assert_equal, assert_false, assert_raises, assert_true

from bench_corpus import Query, Suite, suite
from bench_data import read_lock_file, tpch_manifest
from bench_duckdb import (
    BenchClock,
    DuckDbSession,
    DuckDbTransport,
    StdoutChunk,
    parse_references,
)
from bench_duckdb.text import slice_bytes
from runtime_paths import test_tmpdir

from tpch_answers import (
    ANSWERS_FILE,
    QUERIES_DIR,
    produce_tpch_sf1_answers,
    record_answers,
    register_tables,
    tpch_header,
)


struct Rule(Copyable, Movable):
    var needle: String
    var json: String
    var error: String
    var types: String

    def __init__(out self, needle: String, json: String, error: String, types: String):
        self.needle = needle
        self.json = json
        self.error = error
        self.types = types


struct FakeDuckDb(DuckDbTransport):
    var sent: ArcPointer[List[String]]
    var rules: List[Rule]
    var chunks: List[String]
    var at: Int
    var errors: String
    var statement: String
    var mode: String

    def __init__(out self, sent: ArcPointer[List[String]], var rules: List[Rule]):
        self.sent = sent
        self.rules = rules^
        self.chunks = List[String]()
        self.at = 0
        self.errors = String("")
        self.statement = String("")
        self.mode = String("")

    def run_statement(mut self):
        for i in range(len(self.rules)):
            if self.statement.find(self.rules[i].needle) >= 0:
                if self.statement.startswith(String("DESCRIBE ")):
                    if self.mode == "json":
                        self.chunks.append(self.rules[i].types + String("\n"))
                elif self.mode == "json" and self.rules[i].json.byte_length() > 0:
                    self.chunks.append(self.rules[i].json + String("\n"))
                self.errors += self.rules[i].error
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
                self.mode = String(line[byte=6:line.byte_length()])
            elif line.startswith(String(".print ")):
                self.chunks.append(String(line[byte=7:line.byte_length()]) + String("\n"))
            else:
                self.statement += line + String("\n")
                if line.endswith(String(";")):
                    self.run_statement()

    def read_stdout(mut self, max_wait_ms: Int) raises -> StdoutChunk:
        if self.at >= len(self.chunks):
            return StdoutChunk(String(""), True)
        var t = self.chunks[self.at]
        self.at += 1
        return StdoutChunk(t^, False)

    def take_stderr(mut self) raises -> String:
        var e = self.errors
        self.errors = String("")
        return e^

    def kill(mut self) raises:
        pass

    def finish(mut self) raises -> Int:
        return 0


def _l(var w: List[String]) -> List[String]:
    return w^


def _describe(types: List[String]) -> String:
    var out = String("[")
    for i in range(len(types)):
        if i > 0:
            out += String(",")
        out += (
            String('{"column_name":"c') + String(i) + String('","column_type":"') + types[i]
            + String('","null":"YES","key":null,"default":null,"extra":null}')
        )
    return out + String("]")


def _bigints(n: Int) -> List[String]:
    var out = List[String]()
    for _ in range(n):
        out.append(String("BIGINT"))
    return out^


def _row(n: Int, v: Int) -> String:
    var out = String("{")
    for i in range(n):
        if i > 0:
            out += String(",")
        out += String('"c') + String(i) + String('":') + String(v)
    return out + String("}")


def _settings_rule() -> Rule:
    return Rule(
        String("current_setting('threads')"),
        String('[{"threads":1,"memory_limit":"4.0 GiB","version":"v1.5.6","source_id":"069cc9f9b5"}]'),
        String(""),
        String(""),
    )


def _session(
    var rules: List[Rule], sent: ArcPointer[List[String]]
) -> DuckDbSession[FakeDuckDb]:
    return DuckDbSession[FakeDuckDb](FakeDuckDb(sent, rules^), BenchClock.system())


def _started(var rules: List[Rule], sent: ArcPointer[List[String]]) raises -> DuckDbSession[FakeDuckDb]:
    rules.append(_settings_rule())
    var s = _session(rules^, sent)
    _ = s.start(1, 4 * 1024 * 1024 * 1024)
    return s^


def _one_row_rules(corpus: Suite) -> List[Rule]:
    """Every query answers one row of five BIGINT columns (the widest result
    the key table names), which is in every query's order."""
    var rules = List[Rule]()
    for i in range(len(corpus.queries)):
        rules.append(
            Rule(
                corpus.queries[i].text,
                String("[") + _row(5, i + 1) + String("]"),
                String(""),
                _describe(_bigints(5)),
            )
        )
    return rules^


def _suite_of(var queries: List[Query]) -> Suite:
    return Suite(String("tpch"), String("t"), String("n"), queries^)


def _query(id: String, text: String) -> Query:
    return Query(String("tpch"), id.copy(), String("tpch"), text.copy())


def test_the_corpus_answers_round_trip_through_the_reference_reader() raises:
    var corpus = suite("tpch")
    var sent = ArcPointer[List[String]](List[String]())
    var s = _started(_one_row_rules(corpus), sent)
    var text = record_answers(s, corpus, String(""))
    var refs = parse_references(text)
    assert_equal(len(refs.answers), 22)
    for i in range(22):
        ref a = refs.answers[i]
        assert_equal(a.id, String("tpch/") + corpus.queries[i].id)
        assert_equal(a.signature.rows, 1)
        assert_equal(len(a.signature.columns), 5)
        assert_equal(a.signature.types[0], "BIGINT")
    var q1 = refs.answers[refs.find(String("tpch/q1"))].copy()
    assert_equal(len(q1.order), 2)
    var q2 = refs.answers[refs.find(String("tpch/q2"))].copy()
    assert_equal(len(q2.order), 4)
    assert_true(q2.order[0].descending)
    var q6 = refs.answers[refs.find(String("tpch/q6"))].copy()
    assert_equal(len(q6.order), 0)
    assert_equal(s.close(), 0)


def test_the_header_names_the_notice_the_queries_the_duckdb_and_the_data() raises:
    var corpus = suite("tpch")
    var h = tpch_header(corpus, String("v1.5.6"), String("abc"))
    assert_equal(
        h,
        String("# derived from TPC-H; not comparable to published TPC-H results\n")
        + String("# suite tpch sha256 ") + corpus.sha256() + String("\n")
        + String("# duckdb v1.5.6\n# data lock fingerprint abc\n"),
    )
    var sent = ArcPointer[List[String]](List[String]())
    var s = _started(_one_row_rules(corpus), sent)
    var text = record_answers(s, corpus, h)
    assert_true(text.startswith(h))
    assert_equal(len(parse_references(text).answers), 22)
    # a header whose last line has no newline still ends its line
    var s2 = _started(_one_row_rules(corpus), ArcPointer[List[String]](List[String]()))
    assert_true(record_answers(s2, corpus, String("# x")).startswith(String("# x\nformat 3\n")))


def test_the_views_are_the_tables_the_queries_name() raises:
    var sent = ArcPointer[List[String]](List[String]())
    var s = _started(List[Rule](), sent)
    var names = _l(["lineitem", "we\"ird"])
    var paths = _l(["/d/lineitem.parquet", "/d/it's.parquet"])
    register_tables(s, names, paths)
    var all = String("")
    for i in range(len(sent[])):
        all += sent[][i]
    assert_true(all.find(String('CREATE OR REPLACE VIEW "lineitem" AS SELECT * FROM read_parquet(\'/d/lineitem.parquet\')')) >= 0)
    assert_true(all.find(String('CREATE OR REPLACE VIEW "we""ird" AS SELECT * FROM read_parquet(\'/d/it\'\'s.parquet\')')) >= 0)
    with assert_raises(contains="one path per table name"):
        register_tables(s, names, _l(["/d/a"]))
    var rules = List[Rule]()
    rules.append(Rule(String("CREATE OR REPLACE VIEW \"lineitem\""), String(""), String("IO Error: no such file"), String("")))
    var t = _started(rules^, ArcPointer[List[String]](List[String]()))
    with assert_raises(contains="duckdb cannot register lineitem: IO Error: no such file"):
        register_tables(t, _l(["lineitem"]), _l(["/x"]))


def test_a_query_duckdb_refuses_fails_naming_the_query() raises:
    var q = _query("q6", "select refused")
    var rules = List[Rule]()
    rules.append(Rule(q.text, String(""), String("Binder Error: no column"), String("")))
    var s = _started(rules^, ArcPointer[List[String]](List[String]()))
    var qs = List[Query]()
    qs.append(q.copy())
    with assert_raises(contains="duckdb refused tpch/q6: Binder Error: no column"):
        _ = record_answers(s, _suite_of(qs^), String(""))


def test_an_answer_out_of_its_order_fails_naming_the_query() raises:
    var q = _query("q4", "select unordered")
    var rules = List[Rule]()
    rules.append(
        Rule(
            q.text,
            String("[") + _row(2, 5) + String(",") + _row(2, 3) + String("]"),
            String(""),
            _describe(_bigints(2)),
        )
    )
    var s = _started(rules^, ArcPointer[List[String]](List[String]()))
    var qs = List[Query]()
    qs.append(q.copy())
    with assert_raises(contains="tpch/q4 came back from duckdb out of its order: VIOLATED: row 1"):
        _ = record_answers(s, _suite_of(qs^), String(""))


def test_a_column_that_mixes_numbers_and_text_is_refused() raises:
    var q = _query("q6", "select mixed")
    var rules = List[Rule]()
    rules.append(
        Rule(q.text, String('[{"c0":1},{"c0":"x"}]'), String(""), _describe(_bigints(1)))
    )
    var s = _started(rules^, ArcPointer[List[String]](List[String]()))
    var qs = List[Query]()
    qs.append(q.copy())
    with assert_raises(contains="column 0 mixes values"):
        _ = record_answers(s, _suite_of(qs^), String(""))


def test_an_answer_with_no_rows_is_refused() raises:
    var q = _query("q6", "select nothing")
    var rules = List[Rule]()
    rules.append(Rule(q.text, String("[]"), String(""), _describe(_bigints(2))))
    var s = _started(rules^, ArcPointer[List[String]](List[String]()))
    var qs = List[Query]()
    qs.append(q.copy())
    with assert_raises(contains="tpch/q6 returned no rows"):
        _ = record_answers(s, _suite_of(qs^), String(""))


def _stage(dir: String, skip: String = String("")) raises:
    var m = tpch_manifest(1)
    makedirs(dir + "/tpch/sf1", exist_ok=True)
    for i in range(len(m.files)):
        if m.files[i].path.find(skip) >= 0 and skip.byte_length() > 0:
            continue
        Path(dir + "/" + m.files[i].path).write_text(String("rows of ") + m.files[i].path)


def test_the_run_writes_the_answers_and_the_lock_and_names_one_in_the_other() raises:
    var cache = test_tmpdir() + "/answers_run_cache"
    var out = test_tmpdir() + "/answers_run_out"
    _stage(cache)
    var corpus = suite("tpch")
    var sent = ArcPointer[List[String]](List[String]())
    var rules = _one_row_rules(corpus)
    rules.append(_settings_rule())
    var s = _session(rules^, sent)
    var line = produce_tpch_sf1_answers(s, cache, out, 4)
    var lock = read_lock_file(out, String("tpch"), String("sf1"))
    assert_equal(len(lock.entries), 8)
    var text = Path(out + "/" + String(ANSWERS_FILE)).read_text()
    assert_true(text.find(String("# data lock fingerprint ") + lock.fingerprint() + String("\n")) >= 0)
    assert_true(text.find(String("# duckdb v1.5.6\n")) >= 0)
    assert_equal(len(parse_references(text).answers), 22)
    assert_true(line.find(lock.fingerprint()) >= 0)
    for i in range(len(corpus.queries)):
        var file = out + "/" + String(QUERIES_DIR) + "/" + corpus.queries[i].id + ".sql"
        assert_equal(Path(file).read_text(), corpus.queries[i].text)
    var all = String("")
    for i in range(len(sent[])):
        all += sent[][i]
    assert_true(all.find(String("SET threads=1\n")) >= 0)
    assert_true(all.find(String("SET memory_limit='4194304KiB'")) >= 0)
    var m = tpch_manifest(1)
    for i in range(len(m.files)):
        assert_true(all.find(String("read_parquet('") + cache + String("/") + m.files[i].path + String("')")) >= 0)


def test_unusable_data_stops_before_duckdb_is_asked_anything() raises:
    var cache = test_tmpdir() + "/answers_missing_cache"
    var out = test_tmpdir() + "/answers_missing_out"
    _stage(cache, String("orders"))
    var sent = ArcPointer[List[String]](List[String]())
    var s = _session(List[Rule](), sent)
    with assert_raises(contains="the staged TPC-H files are not usable"):
        _ = produce_tpch_sf1_answers(s, cache, out, 4)
    assert_equal(len(sent[]), 0)
    assert_false(exists(out + "/" + String(ANSWERS_FILE)))


def test_an_existing_answers_file_is_never_replaced() raises:
    var cache = test_tmpdir() + "/answers_kept_cache"
    var out = test_tmpdir() + "/answers_kept_out"
    _stage(cache)
    makedirs(out, exist_ok=True)
    Path(out + "/" + String(ANSWERS_FILE)).write_text(String("kept"))
    var sent = ArcPointer[List[String]](List[String]())
    var s = _session(List[Rule](), sent)
    with assert_raises(contains="exists; it is never overwritten"):
        _ = produce_tpch_sf1_answers(s, cache, out, 4)
    assert_equal(Path(out + "/" + String(ANSWERS_FILE)).read_text(), "kept")
    assert_equal(len(sent[]), 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
