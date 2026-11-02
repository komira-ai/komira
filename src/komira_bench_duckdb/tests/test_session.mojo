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
#   the memory limit (in KiB) are sent as SET statements, one statement each
#   with nothing rendered, extension auto-install and auto-load are turned
#   off, extra settings are sent and read back by name, and the read-back is
#   returned.
# - test_start_refuses_a_session_that_does_not_match: a thread count that did
#   not take, a memory limit that did not take, an extra setting that did not
#   take, another version, another build, a build id too short to compare, a
#   refused SET, an unpinned version, a memory limit that is not whole KiB and
#   a setting name with a quote each raise; a size written differently (`4
#   KiB` for `4KiB`) is accepted.
# - test_the_end_of_output_before_the_end_marker_raises: a process that exits
#   mid-query is an error, not a hang and not a zero time.
# - test_a_wait_through_silence_raises_and_the_process_can_be_stopped: a
#   process that never prints the end marker makes the query raise once the
#   transport reports the wait ran out, later queries are refused without
#   being sent, and `kill` reaches the transport.
# - test_a_failed_write_raises_and_ends_the_session: a transport that cannot
#   be written to makes the query raise and later queries are refused.
# - test_markers_read_together_are_reported_unresolved: both markers in one
#   read give an elapsed time of 0 with `resolved` False, markers in two reads
#   with the clock moved between them are resolved.
# - test_a_query_ending_in_a_comment_still_gets_its_terminator: a last line
#   that ends with a semicolon inside a `--` comment is followed by a line of
#   its own that ends the statement; a plain trailing semicolon is not
#   doubled.
# - test_a_quoted_decimal_is_a_decimal_and_the_timed_run_is_untouched: DuckDB's
#   JSON quotes a DECIMAL (as it does every non-bare type); the fetch asks
#   DuckDB for the column types with DESCRIBE <query> (never with a rewritten
#   query), the quoted value is then neither a text nor a double, and a timed
#   run afterwards sends no DESCRIBE.
# - test_a_quoted_number_in_a_varchar_column_stays_text: '1994' in a VARCHAR
#   column is still a text.
# - test_wide_integers_are_exact_and_small_ones_are_integers: a quoted HUGEINT
#   is always an exact decimal (as the engine's DECIMAL(38,0) is), a UBIGINT
#   inside 63 bits is an integer, a HUGEINT one
#   past 2^63 or a UBIGINT at 2^64-1 is neither a text nor a double, and two
#   values a unit apart do not compare equal.
# - test_decimals_compare_exactly_and_by_value: 123.40 in DECIMAL(10,2) and 123.4
#   in DECIMAL(10,1) are the same value, 123141078.2283 and 123141078.2284 are
#   not, and a sum of two DECIMAL(38,0) maxima, which does not fit 128 bits,
#   still tells a unit apart.
# - test_a_decimal_against_a_double_is_a_kind_difference: the same number as a
#   DECIMAL and as a double does not compare equal and says the kinds differ.
# - test_text_that_is_not_an_exact_number_in_an_exact_column_is_an_error: a
#   fraction in a HUGEINT column and a DECIMAL value with more than 38
#   fractional digits raise instead of becoming texts.
# - test_every_fetch_records_the_declared_types: a fetch whose answer holds no
#   text written like a number (a BIGINT, a DOUBLE, a VARCHAR and a DECIMAL
#   column) still sends DESCRIBE <query> once and records the four declared
#   types in the shared vocabulary. Catches a lazy DESCRIBE that skips the types.
# - test_an_answer_with_no_rows_still_has_its_declared_types: an empty answer
#   has its column types.
# - test_a_type_outside_the_mapping_is_recorded_as_unmapped: TIMESTAMP is
#   recorded as an unmapped type that keeps its name, not dropped.
# - test_a_describe_with_the_wrong_number_of_columns_raises: a DESCRIBE with two
#   columns for a one-column answer is an error.
# - test_a_timed_run_sends_no_describe: timed runs of a query send no DESCRIBE,
#   before or after a fetch of the same query.
# - test_the_settings_read_back_sends_no_describe: `start` sends no DESCRIBE.

from std.memory import ArcPointer
from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_bench_duckdb import (
    BenchClock,
    Cell,
    DuckDbSession,
    DuckDbTransport,
    ResultSet,
    is_unmapped,
    StdoutChunk,
    compare_signatures,
    signature_of,
)
from komira_bench_duckdb.cells import KIND_DECIMAL, KIND_FLOAT, KIND_INT, KIND_NULL, KIND_TEXT
from komira_bench_duckdb.text import slice_bytes


struct Rule(Copyable, Movable):
    var needle: String
    var json: String
    var error: String
    var cost: Int
    var types: String

    def __init__(out self, needle: String, json: String, error: String, cost: Int, types: String = String("")):
        self.needle = needle
        self.json = json
        self.error = error
        self.cost = cost
        self.types = types


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
    var stall: Bool
    var one_read: Bool
    var fail_send: Bool

    def __init__(
        out self,
        clock: ArcPointer[Int],
        sent: ArcPointer[List[String]],
        var rules: List[Rule],
        fragment: Bool = False,
        cut_before_end: Bool = False,
        stall: Bool = False,
        one_read: Bool = False,
        fail_send: Bool = False,
    ):
        self.stall = stall
        self.one_read = one_read
        self.fail_send = fail_send
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
        if self.one_read and len(self.chunks) > self.at:
            self.chunks[len(self.chunks) - 1] += text
            self.advances[len(self.advances) - 1] += advance
            return
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
                if self.statement.startswith(String("DESCRIBE ")):
                    # what DuckDB answers for DESCRIBE <query>: the rule's `types`
                    if self.mode == "json" and self.rules[i].types.byte_length() > 0:
                        self.emit(self.rules[i].types + String("\n"), 0)
                elif self.mode == "json" and self.rules[i].json.byte_length() > 0:
                    self.emit(self.rules[i].json + String("\n"), 0)
                self.errors += self.rules[i].error
                self.cost = self.rules[i].cost
                break
        self.statement = String("")

    def send(mut self, text: String) raises:
        if self.fail_send:
            raise Error("broken pipe")
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

    def read_stdout(mut self, max_wait_ms: Int) raises -> StdoutChunk:
        if self.at >= len(self.chunks):
            if self.stall:
                return StdoutChunk(String(""), False, True)
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


def _sent_text(sent: ArcPointer[List[String]]) -> String:
    var out = String("")
    for i in range(len(sent[])):
        out += sent[][i]
    return out^


def _settings_rules() -> List[Rule]:
    var rules = List[Rule]()
    rules.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"16.0 KiB","version":"v1.5.6","source_id":"069cc9f9b5","extra_0":"true"}]'),
            String(""),
            0,
        )
    )
    return rules^


def _no_extras() -> List[Tuple[String, String]]:
    return List[Tuple[String, String]]()


def _names2(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    return out^


def _describe_many(names: List[String], types: List[String]) -> String:
    """What DuckDB answers for DESCRIBE of a query with these columns."""
    var out = String("[")
    for i in range(len(names)):
        if i > 0:
            out += String(",\n")
        out += (
            String('{"column_name":"') + names[i] + String('","column_type":"') + types[i]
            + String('","null":"YES","key":null,"default":null,"extra":null}')
        )
    return out + String("]")


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
        Rule(
            String("SELECT pieces"), String('[{"a":1,"b":"x"},\n{"a":2,"b":"y"}]'), String(""), 4000,
            _describe_many(_names2("a", "b"), _names2("BIGINT", "VARCHAR")),
        )
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
    rules.append(
        Rule(
            String("SELECT rows"), String('[{"n":7,"name":"seven"}]'), String(""), 0,
            _describe_many(_names2("n", "name"), _names2("BIGINT", "VARCHAR")),
        )
    )
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
    # the fetch used two numbers: the query and its DESCRIBE
    assert_true(_sent_text(sent).find(String(".mode trash\n.print @@S 3\n")) >= 0)


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
    assert_equal(got.memory_limit_readback, String("16.0 KiB"))
    assert_equal(got.version, String("v1.5.6"))
    assert_equal(got.source_id, String("069cc9f9b5"))
    assert_equal(got.extra_names[0], String("parquet_metadata_cache"))
    assert_equal(got.extra_readbacks[0], String("true"))
    var text = _sent_text(sent)
    assert_true(text.find(String(".mode trash\n.print @@S 3\nSET threads=4\n;\n.print @@E 3\n")) >= 0)
    assert_true(text.find(String("SET memory_limit='16KiB'\n;\n")) >= 0)
    assert_true(text.find(String("SET parquet_metadata_cache='true'\n;\n")) >= 0)
    assert_true(text.find(String("SET autoinstall_known_extensions=false\n;\n")) >= 0)
    assert_true(text.find(String("SET autoload_known_extensions=false\n;\n")) >= 0)
    assert_true(text.find(String(".mode json\n.print @@S 6\nSELECT current_setting('threads')")) >= 0)


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
    other_threads.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":2,"memory_limit":"16.0 KiB","version":"v1.5.6","source_id":"069cc9f9b5"}]'),
            String(""),
            0,
        )
    )
    assert_true(_refused(other_threads, 4, 16384, String("1.5.6"), no))
    # another version
    var other_version = List[Rule]()
    other_version.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"16.0 KiB","version":"v1.5.5","source_id":"069cc9f9b5"}]'),
            String(""),
            0,
        )
    )
    assert_true(_refused(other_version, 4, 16384, String("1.5.6"), no))
    # another build of the same version
    var other_build = List[Rule]()
    other_build.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"16.0 KiB","version":"v1.5.6","source_id":"0123456789"}]'),
            String(""),
            0,
        )
    )
    assert_true(_refused(other_build, 4, 16384, String("1.5.6"), no))
    # a memory limit that did not take (1 MiB read back for 16 KiB)
    var other_memory = List[Rule]()
    other_memory.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"1.0 MiB","version":"v1.5.6","source_id":"069cc9f9b5"}]'),
            String(""),
            0,
        )
    )
    assert_true(_refused(other_memory, 4, 16384, String("1.5.6"), no))
    var unreadable_memory = List[Rule]()
    unreadable_memory.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"lots","version":"v1.5.6","source_id":"069cc9f9b5"}]'),
            String(""),
            0,
        )
    )
    assert_true(_refused(unreadable_memory, 4, 16384, String("1.5.6"), no))
    # an extra setting that read back as another value
    var other_extra = List[Rule]()
    other_extra.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"16.0 KiB","version":"v1.5.6","source_id":"069cc9f9b5","extra_0":"false"}]'),
            String(""),
            0,
        )
    )
    var wants_true = List[Tuple[String, String]]()
    wants_true.append((String("parquet_metadata_cache"), String("true")))
    assert_true(_refused(other_extra, 4, 16384, String("1.5.6"), wants_true))
    # a build id too short to tell builds apart
    var short_id = List[Rule]()
    short_id.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"16.0 KiB","version":"v1.5.6","source_id":"0"}]'),
            String(""),
            0,
        )
    )
    assert_true(_refused(short_id, 4, 16384, String("1.5.6"), no))
    # a refused SET
    var refuses = List[Rule]()
    refuses.append(Rule(String("SET threads"), String(""), String("Catalog Error: unknown setting"), 0))
    assert_true(_refused(refuses, 4, 16384, String("1.5.6"), no))
    # arguments the session will not send
    assert_true(_refused(_settings_rules(), 4, 16384, String("9.9.9"), no))
    assert_true(_refused(_settings_rules(), 4, 1500, String("1.5.6"), no))
    assert_true(_refused(_settings_rules(), 0, 16384, String("1.5.6"), no))
    var quoted = List[Tuple[String, String]]()
    quoted.append((String("a'b"), String("1")))
    assert_true(_refused(_settings_rules(), 4, 16384, String("1.5.6"), quoted))
    # a size read back with another spelling is the same size
    var spelled = List[Rule]()
    spelled.append(
        Rule(
            String("current_setting('threads')"),
            String('[{"threads":4,"memory_limit":"16384 B","version":"v1.5.6","source_id":"069cc9f9b5","extra_0":"4.0 GiB"}]'),
            String(""),
            0,
        )
    )
    var wants_size = List[Tuple[String, String]]()
    wants_size.append((String("max_temp_directory_size"), String("4GiB")))
    assert_false(_refused(spelled, 4, 16384, String("1.5.6"), wants_size))
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


def test_a_wait_through_silence_raises_and_the_process_can_be_stopped() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var s = DuckDbSession[FakeDuckDb](
        FakeDuckDb(cell, sent, List[Rule](), False, True, True), BenchClock.manual(cell), 250
    )
    var message = String("")
    try:
        _ = s.run_timed(String("SELECT 'unterminated"))
    except e:
        message = String(e)
    assert_true(message.find(String("printed nothing for 250 ms")) >= 0)
    var sent_before = len(sent[])
    var refused = False
    try:
        _ = s.run_timed(String("SELECT 1"))
    except:
        refused = True
    assert_true(refused)
    assert_equal(len(sent[]), sent_before)
    s.kill()
    assert_equal(sent[][len(sent[]) - 1], String("<killed>"))


def test_a_failed_write_raises_and_ends_the_session() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var s = DuckDbSession[FakeDuckDb](
        FakeDuckDb(cell, sent, List[Rule](), False, False, False, False, True), BenchClock.manual(cell)
    )
    var first = False
    try:
        _ = s.run_timed(String("SELECT 1"))
    except:
        first = True
    assert_true(first)
    var second_message = String("")
    try:
        _ = s.fetch(String("SELECT 1"))
    except e:
        second_message = String(e)
    assert_true(second_message.find(String("unusable")) >= 0)


def test_markers_read_together_are_reported_unresolved() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var rules = List[Rule]()
    rules.append(Rule(String("slow"), String(""), String(""), 7000))
    var together = DuckDbSession[FakeDuckDb](
        FakeDuckDb(cell, sent, rules.copy(), False, False, False, True), BenchClock.manual(cell)
    )
    var joined = together.run_timed(String("SELECT slow"))
    assert_equal(joined.elapsed_ns, 0)
    assert_false(joined.resolved)
    var cell2 = ArcPointer[Int](0)
    var apart = DuckDbSession[FakeDuckDb](
        FakeDuckDb(cell2, ArcPointer[List[String]](List[String]()), rules^), BenchClock.manual(cell2)
    )
    var split = apart.run_timed(String("SELECT slow"))
    assert_equal(split.elapsed_ns, 7000)
    assert_true(split.resolved)


def test_a_query_ending_in_a_comment_still_gets_its_terminator() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var s = DuckDbSession[FakeDuckDb](FakeDuckDb(cell, sent, List[Rule]()), BenchClock.manual(cell))
    _ = s.run_timed(String("SELECT 1\n-- done;"))
    _ = s.run_timed(String("SELECT 2; "))
    _ = s.run_timed(String("SELECT 3"))
    var text = _sent_text(sent)
    assert_true(text.find(String("SELECT 1\n-- done;\n;\n.print @@E 1\n")) >= 0)
    assert_true(text.find(String("SELECT 2;\n.print @@E 2\n")) >= 0)
    assert_true(text.find(String("SELECT 3\n;\n.print @@E 3\n")) >= 0)


def _describe(ty: String) -> String:
    return (
        String('[{"column_name":"v","column_type":"') + ty
        + String('","null":"YES","key":null,"default":null,"extra":null}]')
    )


def _fetched(json: String, ty: String) raises -> ResultSet:
    """The rows of `SELECT one` when DuckDB prints `json` and describes the
    column as `ty`."""
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var rules = List[Rule]()
    rules.append(Rule(String("SELECT one"), json, String(""), 0, _describe(ty)))
    var s = DuckDbSession[FakeDuckDb](FakeDuckDb(cell, sent, rules^), BenchClock.manual(cell))
    var f = s.fetch(String("SELECT one"))
    assert_true(f.ok(), f.error)
    return f.rows.copy()


def _one(value: String) -> String:
    return String('[{"v":"') + value + String('"}]')


def _verdict_reason(a: ResultSet, b: ResultSet) raises -> String:
    """The first reason the two answers differ in their values, or an empty
    text when they are identical. The declared types are left out: these tests
    are about the values (123.40 at two scales is one value), and the
    declared types are compared in test_declared_types."""
    var x = a.copy()
    x.types = List[String]()
    var y = b.copy()
    y.types = List[String]()
    var v = compare_signatures(signature_of(x), signature_of(y))
    if v.identical:
        return String("")
    return v.reasons[0].copy()


def test_a_quoted_decimal_is_a_decimal_and_the_timed_run_is_untouched() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var rules = List[Rule]()
    rules.append(
        Rule(String("SELECT revenue"), _one(String("123141078.2283")), String(""), 0, _describe(String("DECIMAL(38,4)")))
    )
    var s = DuckDbSession[FakeDuckDb](FakeDuckDb(cell, sent, rules^), BenchClock.manual(cell))
    var f = s.fetch(String("SELECT revenue"))
    assert_true(f.ok())
    var c = f.rows.rows[0][0].copy()
    assert_true(c.kind != KIND_TEXT, "a quoted DECIMAL must not be a text")
    assert_true(c.kind != KIND_FLOAT, "a DECIMAL must not be rounded to a double")
    assert_true(c.kind != KIND_NULL)
    assert_true(c.kind != KIND_INT)
    var text = _sent_text(sent)
    assert_true(text.find(String("DESCRIBE SELECT revenue")) >= 0, "the column types are read with DESCRIBE <query>")
    assert_true(text.find(String("\nSELECT revenue\n;\n.print @@E")) >= 0, "the query text is sent as it is")
    var before = _count(text, String("DESCRIBE"))
    _ = s.run_timed(String("SELECT revenue"))
    assert_equal(_count(_sent_text(sent), String("DESCRIBE")), before)


def _count(text: String, needle: String) -> Int:
    var n = 0
    var at = 0
    while True:
        var f = text.find(needle, at)
        if f < 0:
            return n
        n += 1
        at = f + needle.byte_length()


def test_a_quoted_number_in_a_varchar_column_stays_text() raises:
    var rows = _fetched(_one(String("1994")), String("VARCHAR"))
    assert_equal(rows.rows[0][0].kind, KIND_TEXT)
    assert_equal(rows.rows[0][0].s, String("1994"))
    var dates = _fetched(_one(String("1994-01-01")), String("DATE"))
    assert_equal(dates.rows[0][0].kind, KIND_TEXT)
    assert_equal(dates.rows[0][0].s, String("1994-01-01"))


def test_wide_integers_are_exact_and_small_ones_are_integers() raises:
    var small = _fetched(_one(String("9223372036854775807")), String("HUGEINT"))
    assert_equal(small.rows[0][0].kind, KIND_DECIMAL)
    assert_equal(small.rows[0][0].s, String("9223372036854775807"))
    var negative = _fetched(_one(String("-9223372036854775808")), String("HUGEINT"))
    assert_equal(negative.rows[0][0].kind, KIND_DECIMAL)
    var ubig = _fetched(_one(String("9223372036854775807")), String("UBIGINT"))
    assert_equal(ubig.rows[0][0].kind, KIND_INT)
    assert_equal(ubig.rows[0][0].i, Int64(9223372036854775807))
    var past = _fetched(_one(String("9223372036854775808")), String("UBIGINT"))
    assert_true(past.rows[0][0].kind != KIND_TEXT)
    assert_true(past.rows[0][0].kind != KIND_FLOAT)
    var top = _fetched(_one(String("18446744073709551615")), String("UBIGINT"))
    var next = _fetched(_one(String("18446744073709551614")), String("UBIGINT"))
    assert_true(top.rows[0][0].kind != KIND_TEXT)
    assert_true(top.rows[0][0].kind != KIND_FLOAT)
    assert_true(_verdict_reason(top, top).byte_length() == 0)
    assert_true(_verdict_reason(top, next).find(String("sum differs")) >= 0)
    var huge = _fetched(_one(String("170141183460469231731687303715884105727")), String("HUGEINT"))
    var huge_next = _fetched(_one(String("170141183460469231731687303715884105726")), String("HUGEINT"))
    var uhuge = _fetched(_one(String("340282366920938463463374607431768211455")), String("UHUGEINT"))
    assert_true(huge.rows[0][0].kind != KIND_TEXT)
    assert_true(uhuge.rows[0][0].kind != KIND_TEXT)
    assert_true(_verdict_reason(huge, huge_next).find(String("sum differs")) >= 0)


def test_decimals_compare_exactly_and_by_value() raises:
    var a = _fetched(_one(String("123.40")), String("DECIMAL(10,2)"))
    var b = _fetched(_one(String("123.4")), String("DECIMAL(10,1)"))
    assert_equal(_verdict_reason(a, b), String(""))
    var x = _fetched(_one(String("123141078.2283")), String("DECIMAL(38,4)"))
    var y = _fetched(_one(String("123141078.2284")), String("DECIMAL(38,4)"))
    assert_equal(_verdict_reason(x, x), String(""))
    assert_true(_verdict_reason(x, y).find(String("sum differs")) >= 0)
    # two DECIMAL(38,0) maxima add up past 128 bits; a unit still shows
    var nines = String("99999999999999999999999999999999999999")
    var eights = String("99999999999999999999999999999999999998")
    var pair = String('[{"v":"') + nines + String('"},{"v":"') + nines + String('"}]')
    var pair_less = String('[{"v":"') + nines + String('"},{"v":"') + eights + String('"}]')
    var p = _fetched(pair, String("DECIMAL(38,0)"))
    var q = _fetched(pair_less, String("DECIMAL(38,0)"))
    assert_equal(_verdict_reason(p, p), String(""))
    assert_true(_verdict_reason(p, q).find(String("sum differs")) >= 0)


def test_a_decimal_against_a_double_is_a_kind_difference() raises:
    var d = _fetched(_one(String("1.5")), String("DECIMAL(3,1)"))
    var f = ResultSet()
    f.names.append(String("v"))
    var row = List[Cell]()
    row.append(Cell.real(1.5))
    f.add_row(row^)
    var reason = _verdict_reason(d, f)
    assert_true(reason.find(String("has kind")) >= 0, "a decimal against a double is a kind difference: " + reason)


def test_text_that_is_not_an_exact_number_in_an_exact_column_is_an_error() raises:
    var raised = False
    try:
        _ = _fetched(_one(String("1.5")), String("HUGEINT"))
    except:
        raised = True
    assert_true(raised, "a fraction in a HUGEINT column is an error")
    raised = False
    try:
        _ = _fetched(_one(String("0.1234567890123456789012345678901234567890")), String("DECIMAL(38,38)"))
    except:
        raised = True
    assert_true(raised, "more than 38 fractional digits is an error")


def _one_rule_session(
    sent: ArcPointer[List[String]], needle: String, json: String, names: List[String], types: List[String]
) -> DuckDbSession[FakeDuckDb]:
    var cell = ArcPointer[Int](0)
    var rules = List[Rule]()
    rules.append(Rule(needle, json, String(""), 0, _describe_many(names, types)))
    return DuckDbSession[FakeDuckDb](FakeDuckDb(cell, sent, rules^), BenchClock.manual(cell))


def _names1(a: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    return out^


def test_every_fetch_records_the_declared_types() raises:
    var sent = ArcPointer[List[String]](List[String]())
    var s = _one_rule_session(
        sent, String("SELECT mixed"), String('[{"n":7,"x":1.5,"t":"a","d":"2.50"}]'),
        _names4("n", "x", "t", "d"), _names4("BIGINT", "DOUBLE", "VARCHAR", "DECIMAL(10,2)"),
    )
    var f = s.fetch(String("SELECT mixed"))
    assert_true(f.ok(), f.error)
    assert_equal(len(f.rows.types), 4)
    assert_equal(f.rows.types[0], String("BIGINT"))
    assert_equal(f.rows.types[1], String("DOUBLE"))
    assert_equal(f.rows.types[2], String("VARCHAR"))
    assert_equal(f.rows.types[3], String("DECIMAL(10,2)"))
    assert_equal(_count(_sent_text(sent), String("DESCRIBE SELECT mixed")), 1)
    assert_true(
        _sent_text(sent).find(String("\nSELECT mixed\n;\n.print @@E")) >= 0, "the query text is sent as it is"
    )


def test_an_answer_with_no_rows_still_has_its_declared_types() raises:
    var sent = ArcPointer[List[String]](List[String]())
    var s = _one_rule_session(sent, String("SELECT none"), String("[]"), _names1("v"), _names1("DOUBLE"))
    var f = s.fetch(String("SELECT none"))
    assert_true(f.ok(), f.error)
    assert_equal(f.rows.row_count(), 0)
    assert_equal(len(f.rows.types), 1)
    assert_equal(f.rows.types[0], String("DOUBLE"))


def test_a_type_outside_the_mapping_is_recorded_as_unmapped() raises:
    var sent = ArcPointer[List[String]](List[String]())
    var s = _one_rule_session(
        sent, String("SELECT stamp"), String('[{"v":"2024-01-01 00:00:00"}]'), _names1("v"), _names1("TIMESTAMP")
    )
    var f = s.fetch(String("SELECT stamp"))
    assert_true(f.ok(), f.error)
    assert_equal(len(f.rows.types), 1)
    assert_true(is_unmapped(f.rows.types[0]), f.rows.types[0])
    assert_true(f.rows.types[0].find(String("TIMESTAMP")) >= 0, f.rows.types[0])


def test_a_describe_with_the_wrong_number_of_columns_raises() raises:
    var sent = ArcPointer[List[String]](List[String]())
    var s = _one_rule_session(
        sent, String("SELECT one"), String('[{"v":1}]'), _names2("v", "w"), _names2("BIGINT", "BIGINT")
    )
    var raised = False
    try:
        _ = s.fetch(String("SELECT one"))
    except e:
        raised = True
        assert_true(String(e).find(String("column_type")) >= 0, String(e))
    assert_true(raised, "two column types for a one-column answer must not be accepted")


def test_a_timed_run_sends_no_describe() raises:
    var sent = ArcPointer[List[String]](List[String]())
    var s = _one_rule_session(sent, String("SELECT timed"), String('[{"v":1}]'), _names1("v"), _names1("BIGINT"))
    _ = s.run_timed(String("SELECT timed"))
    _ = s.run_timed(String("SELECT timed"))
    assert_equal(_count(_sent_text(sent), String("DESCRIBE")), 0)
    _ = s.fetch(String("SELECT timed"))
    assert_equal(_count(_sent_text(sent), String("DESCRIBE")), 1)
    _ = s.run_timed(String("SELECT timed"))
    assert_equal(_count(_sent_text(sent), String("DESCRIBE")), 1, "only the fetch described the query")


def test_the_settings_read_back_sends_no_describe() raises:
    var cell = ArcPointer[Int](0)
    var sent = ArcPointer[List[String]](List[String]())
    var s = DuckDbSession[FakeDuckDb](FakeDuckDb(cell, sent, _settings_rules()), BenchClock.manual(cell))
    var extras = List[Tuple[String, String]]()
    extras.append((String("parquet_metadata_cache"), String("true")))
    _ = s.start(4, 16384, String("1.5.6"), extras^)
    assert_equal(_count(_sent_text(sent), String("DESCRIBE")), 0)


def _names4(a: String, b: String, c: String, d: String) -> List[String]:
    var out = List[String]()
    out.append(a)
    out.append(b)
    out.append(c)
    out.append(d)
    return out^


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
