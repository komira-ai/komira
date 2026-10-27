# The DuckDB session over a stand-in process that lives in the test: it reads
# what the session sends, prints marker lines back, answers a query by looking
# its text up in a rule list, and moves a manual clock a set amount while a
# query "runs". No process is started, no clock is read, nothing sleeps.
#
# What each test proves:
# - test_timing_is_end_marker_minus_start_marker: the duration of a timed query
#   is the clock difference between the arrival of its two markers, for a
#   query that takes 7000 ns of clock and one that takes none; the number of
#   the query counts up; lines DuckDB printed before the start marker do not
#   count.
# - test_markers_split_across_reads_are_still_found: output delivered three
#   bytes at a time, so every marker line and the JSON arrive in pieces, gives
#   the same duration and the same rows.
# - test_an_error_between_the_markers_belongs_to_that_query: the error text a
#   query writes comes back with that query only, and the next query on the
#   same session runs clean.
# - test_fetch_returns_the_rows_in_json_mode: the session switches DuckDB to
#   JSON mode for a fetch and to trash mode for a timed query, and the rows
#   come back typed.
# - test_start_sets_and_reads_back_the_fairness_settings: the thread count and
#   the memory limit (in KiB) are sent as SET statements, extra settings are
#   sent and read back by name, and the read-back is returned.
# - test_start_refuses_a_session_that_does_not_match: a thread count that did
#   not take, another version, another build, an unpinned version, a memory
#   limit that is not whole KiB and a setting name with a quote each raise.
# - test_the_end_of_output_before_the_end_marker_raises: a process that exits
#   mid-query is an error, not a hang and not a zero time.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import (
    BenchClock,
    DuckDbSession,
    DuckDbTransport,
    StdoutChunk,
)
from komira_bench_duckdb.cells import KIND_INT, KIND_TEXT
from komira_bench_duckdb.text import slice_bytes


struct Rule(Copyable, Movable):
    var needle: String
    var json: String
    var error: String
    var cost: Int

    def __init__(out self, needle: String, json: String, error: String, cost: Int):
        self.needle = needle
        self.json = json
        self.error = error
        self.cost = cost


struct FakeDuckDb(DuckDbTransport):
    var clock: ArcPointer[Int]
    var sent: ArcPointer[List[String]]
    var rules: List[Rule]
    var fragment: Bool
    var cut_before_end: Bool
    var chunks: List[String]
    var advances: List[Int]
    var at: Int
    var errors: String
    var statement: String
    var cost: Int
    var mode: String

    def __init__(
        out self,
        clock: ArcPointer[Int],
        sent: ArcPointer[List[String]],
        var rules: List[Rule],
        fragment: Bool = False,
        cut_before_end: Bool = False,
    ):
        self.clock = clock
        self.sent = sent
        self.rules = rules^
        self.fragment = fragment
        self.cut_before_end = cut_before_end
        self.chunks = List[String]()
        self.advances = List[Int]()
        self.at = 0
        self.errors = String("")
        self.statement = String("")
        self.cost = 0
        self.mode = String("")

    def emit(mut self, text: String, advance: Int):
        if not self.fragment:
            self.chunks.append(text)
            self.advances.append(advance)
            return
        var n = text.byte_length()
        var i = 0
        while i < n:
            var j = i + 3
            if j > n:
                j = n
            self.chunks.append(String(text[byte=i:j]))
            self.advances.append(advance if i == 0 else 0)
            i = j

    def run_statement(mut self):
        for i in range(len(self.rules)):
            if self.statement.find(self.rules[i].needle) >= 0:
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
                self.mode = String(line[byte=6:line.byte_length()])
            elif line.startswith(String(".print ")):
                var payload = String(line[byte=7:line.byte_length()])
                if payload.startswith(String("@@E")):
                    if not self.cut_before_end:
                        self.emit(payload + String("\n"), self.cost)
                    self.cost = 0
                else:
                    self.emit(payload + String("\n"), 0)
            else:
                self.statement += line + String("\n")
                if line.endswith(String(";")):
                    self.run_statement()

    def read_stdout(mut self) raises -> StdoutChunk:
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

    def finish(mut self) raises -> Int:
        return 0


def _sent_text(sent: ArcPointer[List[String]]) -> String:
    var out = String("")
    for i in range(len(sent[])):
        out += sent[][i]
    return out^


def _settings_rules() -> List[Rule]:
    var rules = List[Rule]()
    rules.append(Rule(String("SELECT 1 AS ready"), String('[{"ready":1}]'), String(""), 0))
    rules.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"16.0 MiB","version":"v1.5.6","source_id":"069cc9f9b5","extra_0":"true"}]'),
            String(""),
            0,
        )
    )
    return rules^


def _no_extras() -> List[Tuple[String, String]]:
    return List[Tuple[String, String]]()


def test_timing_is_end_marker_minus_start_marker() raises:
    var cell = ArcPointer[Int](1000)
    var sent = ArcPointer[List[String]](List[String]())
    var rules = List[Rule]()
    rules.append(Rule(String("slow"), String(""), String(""), 7000))
    rules.append(Rule(String("quick"), String(""), String(""), 0))
    var fake = FakeDuckDb(cell, sent, rules^)
    fake.emit(String("a line from before the session\n"), 50_000)
    var s = DuckDbSession[FakeDuckDb](fake^, BenchClock.manual(cell))
    var a = s.run_timed(String("SELECT slow"))
    assert_true(a.ok())
    assert_equal(a.id, 1)
    assert_equal(a.elapsed_ns, 7000)
    var b = s.run_timed(String("SELECT quick;"))
    assert_equal(b.id, 2)
    assert_equal(b.elapsed_ns, 0)
    var text = _sent_text(sent)
    assert_true(text.find(String(".mode trash\n.print @@S 1\nSELECT slow\n;\n.print @@E 1\n")) >= 0)
    assert_true(text.find(String(".print @@S 2\nSELECT quick;\n.print @@E 2\n")) >= 0)
    assert_equal(s.close(), 0)


def test_markers_split_across_reads_are_still_found() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var rules = List[Rule]()
    rules.append(
        Rule(String("SELECT pieces"), String('[{"a":1,"b":"x"},\n{"a":2,"b":"y"}]'), String(""), 4000)
    )
    var fake = FakeDuckDb(cell, sent, rules^, True)
    var s = DuckDbSession[FakeDuckDb](fake^, BenchClock.manual(cell))
    var t = s.run_timed(String("SELECT pieces"))
    assert_equal(t.elapsed_ns, 4000)
    var f = s.fetch(String("SELECT pieces"))
    assert_true(f.ok())
    assert_equal(f.rows.row_count(), 2)
    assert_equal(f.rows.rows[1][1].s, String("y"))


def test_an_error_between_the_markers_belongs_to_that_query() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var rules = List[Rule]()
    rules.append(Rule(String("broken"), String(""), String("Parser Error: syntax error\n"), 10))
    var s = DuckDbSession[FakeDuckDb](FakeDuckDb(cell, sent, rules^), BenchClock.manual(cell))
    var bad = s.run_timed(String("SELEC broken"))
    assert_false(bad.ok())
    assert_equal(bad.error, String("Parser Error: syntax error\n"))
    var good = s.run_timed(String("SELECT 1"))
    assert_true(good.ok())
    assert_equal(good.id, 2)
    var fetched = s.fetch(String("SELEC broken"))
    assert_false(fetched.ok())
    assert_equal(fetched.rows.row_count(), 0)


def test_fetch_returns_the_rows_in_json_mode() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var rules = List[Rule]()
    rules.append(Rule(String("SELECT rows"), String('[{"n":7,"name":"seven"}]'), String(""), 0))
    var s = DuckDbSession[FakeDuckDb](FakeDuckDb(cell, sent, rules^), BenchClock.manual(cell))
    var f = s.fetch(String("SELECT rows"))
    assert_true(f.ok())
    assert_equal(f.rows.names[0], String("n"))
    assert_equal(f.rows.rows[0][0].kind, KIND_INT)
    assert_equal(f.rows.rows[0][0].i, Int64(7))
    assert_equal(f.rows.rows[0][1].kind, KIND_TEXT)
    var text = _sent_text(sent)
    assert_true(text.find(String(".mode json\n.print @@S 1\nSELECT rows\n;\n")) >= 0)
    _ = s.run_timed(String("SELECT rows"))
    assert_true(_sent_text(sent).find(String(".mode trash\n.print @@S 2\n")) >= 0)


def test_start_sets_and_reads_back_the_fairness_settings() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var s = DuckDbSession[FakeDuckDb](FakeDuckDb(cell, sent, _settings_rules()), BenchClock.manual(cell))
    var extras = List[Tuple[String, String]]()
    extras.append((String("parquet_metadata_cache"), String("true")))
    var got = s.start(4, 16384, String("1.5.6"), extras^)
    assert_equal(got.threads, 4)
    assert_equal(got.memory_limit_bytes, 16384)
    assert_equal(got.threads_readback, String("4"))
    assert_equal(got.memory_limit_readback, String("16.0 MiB"))
    assert_equal(got.version, String("v1.5.6"))
    assert_equal(got.source_id, String("069cc9f9b5"))
    assert_equal(got.extra_names[0], String("parquet_metadata_cache"))
    assert_equal(got.extra_readbacks[0], String("true"))
    var text = _sent_text(sent)
    assert_true(text.find(String("SET threads=4;\n")) >= 0)
    assert_true(text.find(String("SET memory_limit='16KiB';\n")) >= 0)
    assert_true(text.find(String("SET parquet_metadata_cache='true';\n")) >= 0)


def _refused(rules: List[Rule], threads: Int, memory: Int, version: String, extras: List[Tuple[String, String]]) -> Bool:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var s = DuckDbSession[FakeDuckDb](FakeDuckDb(cell, sent, rules.copy()), BenchClock.manual(cell))
    try:
        _ = s.start(threads, memory, version, extras.copy())
    except:
        return True
    return False


def test_start_refuses_a_session_that_does_not_match() raises:
    var no = _no_extras()
    # a thread count that did not take
    var other_threads = List[Rule]()
    other_threads.append(Rule(String("SELECT 1 AS ready"), String('[{"ready":1}]'), String(""), 0))
    other_threads.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":2,"memory_limit":"x","version":"v1.5.6","source_id":"069cc9f9b5"}]'),
            String(""),
            0,
        )
    )
    assert_true(_refused(other_threads, 4, 16384, String("1.5.6"), no))
    # another version
    var other_version = List[Rule]()
    other_version.append(Rule(String("SELECT 1 AS ready"), String('[{"ready":1}]'), String(""), 0))
    other_version.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"x","version":"v1.5.5","source_id":"069cc9f9b5"}]'),
            String(""),
            0,
        )
    )
    assert_true(_refused(other_version, 4, 16384, String("1.5.6"), no))
    # another build of the same version
    var other_build = List[Rule]()
    other_build.append(Rule(String("SELECT 1 AS ready"), String('[{"ready":1}]'), String(""), 0))
    other_build.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"x","version":"v1.5.6","source_id":"0123456789"}]'),
            String(""),
            0,
        )
    )
    assert_true(_refused(other_build, 4, 16384, String("1.5.6"), no))
    # a refused SET
    var refuses = List[Rule]()
    refuses.append(Rule(String("SELECT 1 AS ready"), String(""), String("Catalog Error: unknown setting"), 0))
    assert_true(_refused(refuses, 4, 16384, String("1.5.6"), no))
    # arguments the session will not send
    assert_true(_refused(_settings_rules(), 4, 16384, String("9.9.9"), no))
    assert_true(_refused(_settings_rules(), 4, 1500, String("1.5.6"), no))
    assert_true(_refused(_settings_rules(), 0, 16384, String("1.5.6"), no))
    var quoted = List[Tuple[String, String]]()
    quoted.append((String("a'b"), String("1")))
    assert_true(_refused(_settings_rules(), 4, 16384, String("1.5.6"), quoted))
    # and the matching session is accepted
    var extras = List[Tuple[String, String]]()
    extras.append((String("parquet_metadata_cache"), String("true")))
    assert_false(_refused(_settings_rules(), 4, 16384, String("1.5.6"), extras))


def test_the_end_of_output_before_the_end_marker_raises() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var s = DuckDbSession[FakeDuckDb](
        FakeDuckDb(cell, sent, List[Rule](), False, True), BenchClock.manual(cell)
    )
    var raised = False
    try:
        _ = s.run_timed(String("SELECT 1"))
    except:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
