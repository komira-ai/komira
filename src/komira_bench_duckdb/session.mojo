# One persistent DuckDB session, driven over stdin and stdout.
#
# Every query is wrapped in two marker lines the host sends itself:
#
#     .print @@S <n>
#     <the query>
#     .print @@E <n>
#
# and the host stamps each marker line with its own clock when the line arrives
# on the stdout pipe. A timed query's duration is the stamp of its end marker
# minus the stamp of its start marker; DuckDB's own timer is not used. A timed
# query runs with `.mode trash`, so no result is rendered. A fetched query runs
# with `.mode json` and its rows come back as a `ResultSet`. DuckDB's JSON
# quotes DECIMAL, HUGEINT, UHUGEINT and UBIGINT values, like a text, so every
# fetched answer is followed by `DESCRIBE <the same query>` (nothing is
# rewritten, and a timed query never gets one): the column types it answers
# with are recorded on the result as declared types (declared_types.mojo) and
# the quoted values of those columns are read by them.
#
# Both arms of a comparison run with the same thread count and the same memory
# limit (`start` sets and reads back both on the DuckDB side; the other arm is
# configured from the same two numbers). A DuckDB error is the text the process
# wrote to stderr between the two markers; it is returned with the query, not
# raised, so one failing query does not end the run.
#
# A session can be told how long it may wait through silence (`max_silence_ms`
# of its constructor): a wait for output that long without a byte raises, and
# the caller stops the process with `kill`. Without a limit a query that never
# ends its statement (an unterminated quote or comment) waits forever.

from .cells import Cell, KIND_FLOAT, KIND_INT, KIND_TEXT, ResultSet
from .clock import BenchClock
from .memory import lower_ascii, parse_size, size_matches
from .pins import DEFAULT_DUCKDB_VERSION, find_pin, duckdb_pins
from .declared_types import duckdb_declared_type
from .faults import FaultCount
from .rows_json import EXACT_NONE, exactness_of_type, parse_json_rows
from .text import slice_bytes
from .transport import DuckDbTransport, StdoutChunk

comptime START_MARKER: String = "@@S"
comptime END_MARKER: String = "@@E"


struct StampedLine(Copyable, Movable):
    """One stdout line and the clock reading when it arrived."""

    var text: String
    var stamp: Int

    def __init__(out self, var text: String, stamp: Int):
        self.text = text^
        self.stamp = stamp


struct QueryTiming(Copyable, Movable):
    """The timing of one query: the host-side time from its start marker to
    its end marker in nanoseconds, and DuckDB's error text if it had one.
    `resolved` is False when both markers were stamped with the same clock
    reading (they arrived in one read), so the query took less than the clock
    could tell apart and `elapsed_ns` is 0 for that reason, not a measurement.
    `faults` is the page faults of the DuckDB process between the two readings
    taken around the query (one just before it is sent, one just after its end
    marker is read), or nothing where the transport cannot read them."""

    var id: Int
    var elapsed_ns: Int
    var error: String
    var resolved: Bool
    var faults: Optional[FaultCount]

    def __init__(
        out self,
        id: Int,
        elapsed_ns: Int,
        var error: String,
        resolved: Bool = True,
        var faults: Optional[FaultCount] = Optional[FaultCount](),
    ):
        self.id = id
        self.elapsed_ns = elapsed_ns
        self.error = error^
        self.resolved = resolved
        self.faults = faults^

    def ok(self) -> Bool:
        return self.error.byte_length() == 0


struct FetchResult(Copyable, Movable):
    """The rows of a fetched query, or DuckDB's error text."""

    var rows: ResultSet
    var error: String

    def __init__(out self):
        self.rows = ResultSet()
        self.error = String("")

    def ok(self) -> Bool:
        return self.error.byte_length() == 0


struct FairnessSettings(Copyable, Movable):
    """What the session was asked for and what DuckDB read back."""

    var threads: Int
    var memory_limit_bytes: Int
    var threads_readback: String
    var memory_limit_readback: String
    var version: String
    var source_id: String
    var extra_names: List[String]
    var extra_readbacks: List[String]

    def __init__(out self, threads: Int, memory_limit_bytes: Int):
        self.threads = threads
        self.memory_limit_bytes = memory_limit_bytes
        self.threads_readback = String("")
        self.memory_limit_readback = String("")
        self.version = String("")
        self.source_id = String("")
        self.extra_names = List[String]()
        self.extra_readbacks = List[String]()


def _terminated(sql: String) -> String:
    """`sql` followed by a line that ends the statement. A query whose last
    line ends with a semicolon is sent as it is, unless that line holds a `--`
    (the semicolon may be inside a comment), in which case the terminator is
    added anyway: an empty statement does nothing."""
    var b = sql.as_bytes()
    var n = len(b)
    while n > 0 and (b[n - 1] == UInt8(32) or b[n - 1] == UInt8(10) or b[n - 1] == UInt8(13) or b[n - 1] == UInt8(9)):
        n -= 1
    var body = String(sql[byte=0:n])
    if n > 0 and b[n - 1] == UInt8(59):
        var line_start = n
        while line_start > 0 and b[line_start - 1] != UInt8(10):
            line_start -= 1
        if String(sql[byte=line_start:n]).find(String("--")) < 0:
            return body + String("\n")
    return body + String("\n;\n")


def _setting_took(requested: String, readback: String) -> Bool:
    """Whether a read-back setting is the requested value: the same text
    ignoring case, or the same size when both are sizes."""
    if lower_ascii(requested) == lower_ascii(readback):
        return True
    try:
        return size_matches(readback, parse_size(requested).bytes)
    except:
        return False


def _single_quoted(s: String) raises -> String:
    for c in s.as_bytes():
        if c == UInt8(39) or c == UInt8(10) or c == UInt8(0):
            raise Error(String("not usable inside a SQL literal: ") + s)
    return String("'") + s + String("'")


def _as_text(c: Cell) -> String:
    """A read-back cell as text (a number is written out)."""
    if c.kind == KIND_TEXT:
        return c.s.copy()
    if c.kind == KIND_INT:
        return String(c.i)
    if c.kind == KIND_FLOAT:
        return String(c.f)
    return String("")


struct DuckDbSession[T: DuckDbTransport](Movable):
    """A DuckDB process and the conversation with it."""

    var _t: Self.T
    var _clock: BenchClock
    var _silence_ms: Int
    var _lines: List[StampedLine]
    var _next: Int
    var _partial: String
    var _eof: Bool
    var _broken: Bool
    var _query_id: Int
    var _last_faults: Optional[FaultCount]

    def __init__(out self, var transport: Self.T, var clock: BenchClock, max_silence_ms: Int = 0):
        """`max_silence_ms` above zero bounds every wait for output: that many
        milliseconds without a byte raises (zero waits without limit)."""
        self._t = transport^
        self._clock = clock^
        self._silence_ms = max_silence_ms
        self._lines = List[StampedLine]()
        self._next = 0
        self._partial = String("")
        self._eof = False
        self._broken = False
        self._query_id = 0
        self._last_faults = Optional[FaultCount]()

    # --- reading -------------------------------------------------------------

    def _fill(mut self) raises:
        """Read once and queue the complete lines it finished, each with the
        clock reading taken right after the read returned."""
        if self._eof:
            raise Error("duckdb closed its output")
        var chunk = self._t.read_stdout(self._silence_ms)
        var stamp = self._clock.now()
        if chunk.timed_out:
            self._broken = True
            raise Error(
                String("duckdb printed nothing for ") + String(self._silence_ms)
                + String(" ms before the end marker; the session is unusable, stop the process with kill()")
            )
        if chunk.eof:
            self._eof = True
            return
        self._partial += chunk.text
        var from_byte = 0
        while True:
            var nl = self._partial.find(String("\n"), from_byte)
            if nl < 0:
                break
            var line = String(self._partial[byte=from_byte:nl])
            from_byte = nl + 1
            if line.endswith(String("\r")):
                line = slice_bytes(line, 0, line.byte_length() - 1)
            self._lines.append(StampedLine(line^, stamp))
        if from_byte > 0:
            self._partial = slice_bytes(self._partial, from_byte, self._partial.byte_length())

    def _next_line(mut self) raises -> StampedLine:
        while self._next >= len(self._lines):
            self._fill()
        var l = self._lines[self._next].copy()
        self._next += 1
        return l^

    def _marker(self, kind: String, id: Int) -> String:
        return kind + String(" ") + String(id)

    def _run(
        mut self, mode: String, sql: String, with_faults: Bool = False
    ) raises -> Tuple[Int, String, String, Bool]:
        """Send one marked query and wait for its end marker. Returns the
        elapsed nanoseconds between the markers, the text between them, the
        error text and whether the two markers carry different clock
        readings. With `with_faults` the transport's page-fault counters are
        read just before the query is sent and just after its end marker is
        read, and the difference is left in `_last_faults` (nothing when the
        transport has no counters)."""
        if self._broken:
            raise Error("the session is unusable after an earlier failure")
        self._query_id += 1
        var id = self._query_id
        var start = self._marker(String(START_MARKER), id)
        var end = self._marker(String(END_MARKER), id)
        var before = Optional[FaultCount]()
        self._last_faults = Optional[FaultCount]()
        if with_faults:
            before = self._t.child_faults()
        try:
            self._t.send(
                String(".mode ") + mode + String("\n.print ") + start + String("\n")
                + _terminated(sql) + String(".print ") + end + String("\n")
            )
        except e:
            self._broken = True
            raise Error(String(e))
        var started = False
        var t0 = 0
        var body = String("")
        while True:
            var l = self._next_line()
            if not started:
                if l.text == start:
                    started = True
                    t0 = l.stamp
                continue
            if l.text == end:
                if with_faults and before:
                    var after = self._t.child_faults()
                    if after:
                        self._last_faults = Optional[FaultCount](after.value().minus(before.value()))
                var err = self._t.take_stderr()
                if self._next >= len(self._lines):
                    self._lines = List[StampedLine]()
                    self._next = 0
                return (l.stamp - t0, body^, err^, l.stamp != t0)
            body += l.text + String("\n")

    # --- queries -------------------------------------------------------------

    def run_timed(mut self, sql: String) raises -> QueryTiming:
        """Run `sql` with no result rendered and return the marker-to-marker
        time. The id of the timing is the query's number in this session."""
        var r = self._run(String("trash"), sql, True)
        return QueryTiming(self._query_id, r[0], r[2].copy(), r[3], self._last_faults.copy())

    def fetch(mut self, sql: String) raises -> FetchResult:
        """Run `sql` in JSON mode and parse its rows. A query with no rows
        comes back with no column names. The column types come from `DESCRIBE`
        of the same query, sent after every successful fetch, and are recorded
        on the rows as the declared types of the columns (an answer with no
        rows has them too). A quoted value in a DECIMAL, HUGEINT, UHUGEINT or
        UBIGINT column is the number it is (see rows_json.mojo)."""
        return self._fetch(sql, True)

    def _fetch(mut self, sql: String, typed: Bool) raises -> FetchResult:
        var r = self._run(String("json"), sql)
        var out = FetchResult()
        if r[2].byte_length() > 0:
            out.error = r[2].copy()
            return out^
        out.rows = parse_json_rows(r[1])
        if not typed:
            return out^
        var d = self._run(String("json"), String("DESCRIBE ") + sql)
        if d[2].byte_length() > 0:
            out.error = String("duckdb cannot describe the columns of the query: ") + d[2]
            return out^
        var described = parse_json_rows(d[1])
        var at = -1
        for i in range(len(described.names)):
            if described.names[i] == "column_type":
                at = i
        if at < 0 or (out.rows.column_count() > 0 and described.row_count() != out.rows.column_count()):
            raise Error("duckdb's DESCRIBE did not give one column_type per column of the answer")
        var raw = List[String]()
        var declared = List[String]()
        var exact = False
        for i in range(described.row_count()):
            var t = _as_text(described.rows[i][at])
            if exactness_of_type(t) != EXACT_NONE:
                exact = True
            declared.append(duckdb_declared_type(t))
            raw.append(t^)
        if exact and out.rows.column_count() > 0:
            # the same rows again, now read by their column types
            out.rows = parse_json_rows(r[1], raw)
        out.rows.types = declared^
        return out^

    def kill(mut self) raises:
        """Stop the DuckDB process now. The session cannot be used after."""
        self._broken = True
        self._t.kill()

    # --- setup ---------------------------------------------------------------

    def _set(mut self, statement: String) raises:
        """Run one statement that renders nothing; raise on DuckDB's error."""
        var t = self.run_timed(statement)
        if not t.ok():
            raise Error(String("duckdb refused `") + statement + String("`: ") + t.error)

    def start(
        mut self,
        threads: Int,
        memory_limit_bytes: Int,
        version: String = String(DEFAULT_DUCKDB_VERSION),
        extra_settings: List[Tuple[String, String]] = List[Tuple[String, String]](),
    ) raises -> FairnessSettings:
        """Set the thread count, the memory limit and any extra settings
        (name and value pairs, applied in order), turn off extension
        auto-install and auto-load (so a run never fetches code), read the
        settings back, and check that the process is the DuckDB release
        `version`. Each setting goes through its own statement with nothing
        rendered; only the read-back is fetched. Raises on a refused setting,
        a thread count, memory limit or extra setting that did not take, or
        another version. The memory limit must be a whole number of KiB."""
        if threads < 1:
            raise Error("threads must be at least 1")
        if memory_limit_bytes < 1024 or memory_limit_bytes % 1024 != 0:
            raise Error("the memory limit must be a whole number of KiB")
        var at = find_pin(version)
        if at < 0:
            raise Error(String("no pin for duckdb ") + version)
        var pin = duckdb_pins()[at].copy()
        var settings = FairnessSettings(threads, memory_limit_bytes)
        for i in range(len(extra_settings)):
            var name = extra_settings[i][0]
            if name.byte_length() == 0:
                raise Error("an empty setting name")
            for c in name.as_bytes():
                var ok = (c >= UInt8(97) and c <= UInt8(122)) or (c >= UInt8(48) and c <= UInt8(57)) or c == UInt8(95)
                if not ok:
                    raise Error(String("not a setting name: ") + name)
        self._set(String("SET autoinstall_known_extensions=false"))
        self._set(String("SET autoload_known_extensions=false"))
        self._set(String("SET threads=") + String(threads))
        self._set(String("SET memory_limit=") + _single_quoted(String(memory_limit_bytes // 1024) + String("KiB")))
        for i in range(len(extra_settings)):
            self._set(String("SET ") + extra_settings[i][0] + String("=") + _single_quoted(extra_settings[i][1]))
        var query = String(
            "SELECT current_setting('threads') AS threads, current_setting('memory_limit') AS memory_limit,"
            " (SELECT library_version FROM pragma_version()) AS version,"
            " (SELECT source_id FROM pragma_version()) AS source_id"
        )
        for i in range(len(extra_settings)):
            query += String(", current_setting('") + extra_settings[i][0] + String("')::VARCHAR AS extra_") + String(i)
        var got = self._fetch(query, False)
        if not got.ok():
            raise Error(String("duckdb cannot read its settings back: ") + got.error)
        if got.rows.row_count() != 1 or got.rows.column_count() != 4 + len(extra_settings):
            raise Error("the settings read-back has an unexpected shape")
        settings.threads_readback = _as_text(got.rows.rows[0][0])
        settings.memory_limit_readback = _as_text(got.rows.rows[0][1])
        settings.version = _as_text(got.rows.rows[0][2])
        settings.source_id = _as_text(got.rows.rows[0][3])
        for i in range(len(extra_settings)):
            settings.extra_names.append(extra_settings[i][0])
            settings.extra_readbacks.append(_as_text(got.rows.rows[0][4 + i]))
        if settings.threads_readback != String(threads):
            raise Error(String("duckdb runs ") + settings.threads_readback + String(" threads, not ") + String(threads))
        if not size_matches(settings.memory_limit_readback, Float64(memory_limit_bytes)):
            raise Error(
                String("duckdb reports a memory limit of ") + settings.memory_limit_readback
                + String(", not ") + String(memory_limit_bytes // 1024) + String(" KiB")
            )
        for i in range(len(extra_settings)):
            if not _setting_took(extra_settings[i][1], settings.extra_readbacks[i]):
                raise Error(
                    String("duckdb reports ") + settings.extra_readbacks[i] + String(" for ")
                    + extra_settings[i][0] + String(", not ") + extra_settings[i][1]
                )
        if settings.version != String("v") + version:
            raise Error(String("duckdb reports ") + settings.version + String(", not v") + version)
        if settings.source_id.byte_length() < 7 or not pin.commit.startswith(settings.source_id):
            raise Error(String("duckdb was built from ") + settings.source_id + String(", not the pinned commit"))
        return settings^

    def close(mut self) raises -> Int:
        """End the session and return the process's exit code."""
        return self._t.finish()
