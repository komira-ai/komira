# The page-fault counters of a DuckDB child process: how /proc/<pid>/stat is
# read, what a timed query carries, and the delta of two readings. No duration
# is checked; the clock is a counter the fake moves.
#
# What each test proves:
# - test_the_fault_fields_are_read_after_the_command_name: field 10 (minor
#   faults) and field 12 (major faults) of a stat line are read; a command name
#   with spaces and parentheses in it does not shift them (the fields are
#   counted from the last closing parenthesis); a line that is cut short, has
#   a non-numeric field or no parenthesis gives no reading, not a zero.
# - test_a_delta_is_the_later_reading_minus_the_earlier: FaultCount.minus.
# - test_a_missing_stat_file_gives_no_reading: a path that does not exist reads
#   as not measured, on every platform.
# - test_this_process_reads_on_linux_and_counts_never_go_down: on Linux the
#   stat file of this process reads, with minor faults above zero, and a
#   second reading is not below the first; elsewhere there is no reading.
# - test_a_timed_query_carries_the_fault_delta_around_it: three timed queries
#   against a transport whose counters move by 5000/2, 900/0 and 900/0 while
#   each runs carry exactly those deltas, whatever the totals were before.
# - test_a_transport_without_counters_times_a_query_with_no_faults: a
#   transport that cannot read its process's counters still times the query,
#   and the timing's faults are absent, not zero.

from std.memory import ArcPointer
from std.sys.info import CompilationTarget
from std.testing import TestSuite, assert_equal, assert_true

from komira_bench_duckdb import (
    BenchClock,
    DuckDbSession,
    DuckDbTransport,
    FaultCount,
    StdoutChunk,
    parse_stat_faults,
    read_stat_faults,
)


def test_the_fault_fields_are_read_after_the_command_name() raises:
    var plain = parse_stat_faults(
        String("4242 (duckdb) S 1 4242 4242 0 -1 4194304 12345 678 9 10 111 222 0 0 20 0 8 0 1000 2000 300 18446744073709551615\n")
    )
    assert_true(Bool(plain))
    assert_equal(plain.value().minor, Int64(12345))
    assert_equal(plain.value().major, Int64(9))
    # a name with spaces and a parenthesis in it
    var odd = parse_stat_faults(
        String("77 (my (odd) cmd) R 1 77 77 0 -1 4194560 31 0 4 0 1 2 0 0 20 0 1 0 5 6 7\n")
    )
    assert_true(Bool(odd))
    assert_equal(odd.value().minor, Int64(31))
    assert_equal(odd.value().major, Int64(4))
    # cut short, not a number, no command name, nothing
    assert_true(not Bool(parse_stat_faults(String("4242 (duckdb) S 1 4242 4242 0 -1 4194304 12345 678"))))
    assert_true(not Bool(parse_stat_faults(String("4242 (duckdb) S 1 4242 4242 0 -1 4194304 x 678 9 10"))))
    assert_true(not Bool(parse_stat_faults(String("4242 duckdb S 1 4242 4242 0 -1 4194304 12345 678 9 10"))))
    assert_true(not Bool(parse_stat_faults(String(""))))


def test_a_delta_is_the_later_reading_minus_the_earlier() raises:
    var d = FaultCount(Int64(5900), Int64(3)).minus(FaultCount(Int64(900), Int64(1)))
    assert_equal(d.minor, Int64(5000))
    assert_equal(d.major, Int64(2))


def test_a_missing_stat_file_gives_no_reading() raises:
    assert_true(not Bool(read_stat_faults(String("/nonexistent/komira-bench-duckdb/stat"))))


def test_this_process_reads_on_linux_and_counts_never_go_down() raises:
    comptime if CompilationTarget.is_linux():
        var first = read_stat_faults(String("/proc/self/stat"))
        assert_true(Bool(first))
        assert_true(first.value().minor > 0)
        var second = read_stat_faults(String("/proc/self/stat"))
        assert_true(Bool(second))
        assert_true(second.value().minor >= first.value().minor)
        assert_true(second.value().major >= first.value().major)
    else:
        assert_true(not Bool(read_stat_faults(String("/proc/self/stat"))))


struct CountingFake(DuckDbTransport):
    """A transport that answers each marker line at once and moves its fault
    totals by the next scripted step when a query's end marker is sent."""

    var clock: ArcPointer[Int]
    var lines: List[String]
    var at: Int
    var counters: Bool
    var minor: Int64
    var major: Int64
    var steps_minor: List[Int64]
    var steps_major: List[Int64]
    var ended: Int

    def __init__(
        out self,
        clock: ArcPointer[Int],
        counters: Bool,
        var steps_minor: List[Int64],
        var steps_major: List[Int64],
    ):
        self.clock = clock
        self.lines = List[String]()
        self.at = 0
        self.counters = counters
        self.minor = 100000
        self.major = 40
        self.steps_minor = steps_minor^
        self.steps_major = steps_major^
        self.ended = 0

    def send(mut self, text: String) raises:
        var rest = text
        while rest.byte_length() > 0:
            var nl = rest.find(String("\n"))
            var line = rest
            if nl >= 0:
                line = String(rest[byte=0:nl])
                rest = String(rest[byte = nl + 1 : rest.byte_length()])
            else:
                rest = String("")
            if line.startswith(String(".print ")):
                var payload = String(line[byte=7 : line.byte_length()])
                if payload.startswith(String("@@E")) and self.ended < len(self.steps_minor):
                    self.minor += self.steps_minor[self.ended]
                    self.major += self.steps_major[self.ended]
                    self.ended += 1
                self.lines.append(payload + String("\n"))

    def read_stdout(mut self, max_wait_ms: Int) raises -> StdoutChunk:
        if self.at >= len(self.lines):
            return StdoutChunk(String(""), True)
        self.clock[] = self.clock[] + 1000
        var t = self.lines[self.at]
        self.at += 1
        return StdoutChunk(t^, False)

    def take_stderr(mut self) raises -> String:
        return String("")

    def kill(mut self) raises:
        pass

    def finish(mut self) raises -> Int:
        return 0

    def child_faults(self) -> Optional[FaultCount]:
        if not self.counters:
            return Optional[FaultCount]()
        return Optional[FaultCount](FaultCount(self.minor, self.major))


def _steps(a: Int64, b: Int64, c: Int64) -> List[Int64]:
    var out = List[Int64]()
    out.append(a)
    out.append(b)
    out.append(c)
    return out^


def test_a_timed_query_carries_the_fault_delta_around_it() raises:
    var clock = ArcPointer[Int](1000)
    var s = DuckDbSession[CountingFake](
        CountingFake(clock, True, _steps(5000, 900, 900), _steps(2, 0, 0)), BenchClock.manual(clock)
    )
    var a = s.run_timed(String("SELECT 1"))
    var b = s.run_timed(String("SELECT 1"))
    var c = s.run_timed(String("SELECT 1"))
    assert_true(a.ok() and a.resolved)
    assert_equal(a.faults.value().minor, Int64(5000))
    assert_equal(a.faults.value().major, Int64(2))
    assert_equal(b.faults.value().minor, Int64(900))
    assert_equal(b.faults.value().major, Int64(0))
    assert_equal(c.faults.value().minor, Int64(900))
    assert_equal(c.faults.value().major, Int64(0))


def test_a_transport_without_counters_times_a_query_with_no_faults() raises:
    var clock = ArcPointer[Int](1000)
    var s = DuckDbSession[CountingFake](
        CountingFake(clock, False, _steps(5000, 900, 900), _steps(2, 0, 0)), BenchClock.manual(clock)
    )
    var a = s.run_timed(String("SELECT 1"))
    assert_true(a.ok() and a.resolved)
    assert_true(a.elapsed_ns > 0)
    assert_true(not Bool(a.faults))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
