# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_store_faults.mojo
#   A log store that refuses or stalls: the live stream retries a chunk once
#   and then drops it, the terminal writes report failure without raising, a
#   disabled or empty stream writes nothing, the crash report escapes what
#   JSON needs escaped, and a slow write cannot let the job outlive its
#   maximum runtime by another RUNNING beat.
# =============================================================================
#
# `FaultyStore` wraps a `SharedInMemoryConditionalStore`: its `put` counts
# every attempt, refuses the next `fail_puts` attempts, and can sleep first.
# The other verbs pass through.
#
#   test_a_refused_chunk_is_retried_once
#       One refusal: the chunk is written by the retry (two attempts).
#   test_a_chunk_refused_twice_is_dropped_and_the_index_moves_on
#       Two refusals: no third attempt, the chunk is dropped (not counted as
#       written), and the next chunk is written under the NEXT index.
#   test_a_disabled_or_empty_stream_writes_nothing
#       A disabled sink writes nothing even holding bytes; an enabled one with
#       nothing buffered writes nothing on any flush.
#   test_the_terminal_writes_report_a_refusal
#       logs.txt and crash_report.json on a refusing store: each returns False
#       (and raises nothing); the control store gets both.
#   test_the_crash_report_escapes_and_lists_its_fields
#       Quote, backslash, tab, CR and LF are escaped; the signal and the panic
#       line appear; stderr lines are comma-separated; no exit_code when the
#       job did not exit.
#   test_a_slow_write_cannot_buy_the_job_another_beat
#       The stream timer's write stalls 3 s, carrying the loop past a 3 s
#       maximum runtime: the limit check at the top of the next iteration
#       stops the job before any further RUNNING beat. Read from each beat's
#       time, not a beat count: every RUNNING beat is sent less than 3 s after
#       the first beat after the spawn (the spawn precedes it, so this holds
#       however a loaded host shifts the schedule), where a loop that beat
#       once more after the stall would beat about 5 s after it.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_clock import now_ns
from komira_objectstore import SharedInMemoryConditionalStore
from komira_objectstore.path import Path
from komira_objectstore.store import ConditionalWriteStore, ObjectStore
from komira_objectstore.types import (
    CoalescePolicy,
    ListResult,
    ObjectMeta,
    WritePrecondition,
)

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisorConfig,
    JobSupervisorPhase,
    LogStreamSink,
    SupervisorHeartbeat,
    build_crash_report_json,
    run_job_supervisor,
    upload_crash_report,
    upload_logs,
)
from komira_job_supervisor.job_supervisor_state import FailureReport


def _sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


struct Knobs(Movable):
    var fail_puts: Int
    var put_delay_ms: Int
    var put_attempts: Int

    def __init__(out self, fail_puts: Int, put_delay_ms: Int):
        self.fail_puts = fail_puts
        self.put_delay_ms = put_delay_ms
        self.put_attempts = 0


struct FaultyStore(ConditionalWriteStore, ObjectStore, Movable, Deinitable):
    var inner: SharedInMemoryConditionalStore
    var knobs: ArcPointer[Knobs]

    def __init__(
        out self, var inner: SharedInMemoryConditionalStore, knobs: ArcPointer[Knobs]
    ):
        self.inner = inner^
        self.knobs = knobs

    def head(self, path: Path) raises -> ObjectMeta:
        return self.inner.head(path)

    def list_with_delimiter(self, prefix: Path) raises -> ListResult:
        return self.inner.list_with_delimiter(prefix)

    def coalesce_policy(self) -> CoalescePolicy:
        return self.inner.coalesce_policy()

    def conditional_put(
        self, path: Path, bytes: List[UInt8], precond: WritePrecondition
    ) raises -> ObjectMeta:
        return self.inner.conditional_put(path, bytes, precond)

    def compare_and_swap(
        self, path: Path, bytes: List[UInt8], expected_version: String
    ) raises -> ObjectMeta:
        return self.inner.compare_and_swap(path, bytes, expected_version)

    def put(self, path: Path, bytes: List[UInt8]) raises -> ObjectMeta:
        self.knobs[].put_attempts += 1
        if self.knobs[].put_delay_ms > 0:
            _sleep_ms(self.knobs[].put_delay_ms)
        if self.knobs[].fail_puts > 0:
            self.knobs[].fail_puts -= 1
            raise Error("scripted: the store refused the write")
        return self.inner.put(path, bytes)

    def get_range(
        self, path: Path, start: Int64, length: Int64
    ) raises -> List[UInt8]:
        return self.inner.get_range(path, start, length)

    def get(self, path: Path) raises -> List[UInt8]:
        return self.inner.get(path)

    def delete(self, path: Path) raises -> None:
        self.inner.delete(path)


def _faulty(
    fail_puts: Int, put_delay_ms: Int = 0
) -> Tuple[FaultyStore, SharedInMemoryConditionalStore, ArcPointer[Knobs]]:
    var inner = SharedInMemoryConditionalStore()
    var view = inner.clone()
    var knobs = ArcPointer[Knobs](Knobs(fail_puts, put_delay_ms))
    return (FaultyStore(inner^, knobs), view^, knobs)


def _text_at(store: SharedInMemoryConditionalStore, key: String) -> String:
    """The object's text, or "<absent>"."""
    try:
        var b = store.get(Path.parse(key))
        return String(unsafe_from_utf8=Span(b))
    except:
        return String("<absent>")


def test_a_refused_chunk_is_retried_once() raises:
    var t = _faulty(1)
    var sink = LogStreamSink(String("logs/r"), 4, 60_000, True)
    sink.feed_stdout[FaultyStore](String("abcd"), t[0])
    assert_equal(t[2][].put_attempts, 2, "one refusal, one retry")
    assert_equal(_text_at(t[1], String("logs/r/chunks/0.log")), String("abcd"))
    assert_equal(sink.uploaded_count, 1)
    assert_equal(sink.chunks_produced(), 1)
    print("  test_a_refused_chunk_is_retried_once: PASS")


def test_a_chunk_refused_twice_is_dropped_and_the_index_moves_on() raises:
    var t = _faulty(2)
    var sink = LogStreamSink(String("logs/d"), 4, 60_000, True)
    sink.feed_stdout[FaultyStore](String("abcd"), t[0])
    assert_equal(t[2][].put_attempts, 2, "two attempts, no third")
    assert_equal(sink.uploaded_count, 0, "a dropped chunk is not counted as written")
    assert_equal(sink.chunks_produced(), 1, "but its index is used")
    assert_equal(len(sink.current_chunk), 0, "and its bytes are gone")
    assert_equal(_text_at(t[1], String("logs/d/chunks/0.log")), String("<absent>"))
    # The store recovers: the next chunk goes under index 1.
    sink.feed_stdout[FaultyStore](String("efgh"), t[0])
    assert_equal(t[2][].put_attempts, 3)
    assert_equal(_text_at(t[1], String("logs/d/chunks/1.log")), String("efgh"))
    assert_equal(sink.uploaded_count, 1)
    print("  test_a_chunk_refused_twice_is_dropped_and_the_index_moves_on: PASS")


def test_a_disabled_or_empty_stream_writes_nothing() raises:
    var t = _faulty(0)
    var off = LogStreamSink.disabled()
    off.feed_stdout[FaultyStore](String("abcdef"), t[0])
    assert_equal(len(off.current_chunk), 0, "a disabled sink buffers nothing")
    # Even holding bytes, a disabled sink writes none of them.
    off.current_chunk.append(UInt8(0x41))
    off.maybe_flush[FaultyStore](t[0])
    off.flush_current[FaultyStore](t[0])
    off.flush_final[FaultyStore](t[0])
    assert_equal(t[2][].put_attempts, 0, "disabled: no write")

    var empty = LogStreamSink(String("logs/e"), 4, 1, True)
    _sleep_ms(5)  # past its 1 ms interval
    empty.maybe_flush[FaultyStore](t[0])
    empty.flush_current[FaultyStore](t[0])
    empty.flush_final[FaultyStore](t[0])
    assert_equal(t[2][].put_attempts, 0, "nothing buffered: no write")
    assert_equal(empty.chunks_produced(), 0, "and no index used")

    # CONTROL: one byte and the interval passed: it is written.
    empty.feed_stdout[FaultyStore](String("z"), t[0])
    assert_equal(t[2][].put_attempts, 1)
    assert_equal(_text_at(t[1], String("logs/e/chunks/0.log")), String("z"))
    print("  test_a_disabled_or_empty_stream_writes_nothing: PASS")


def _config(var prefix: String) -> JobSupervisorConfig:
    return JobSupervisorConfig(
        String("job-1"),
        String("inst-1"),
        String("/bin/true"),
        List[String](),
        String("http://127.0.0.1:1/beat"),
        log_prefix=prefix^,
    )


def _failure() -> FailureReport:
    var tail = List[String]()
    tail.append(String("boom"))
    return FailureReport(Optional[Int32](Int32(3)), None, tail^, None)


def test_the_terminal_writes_report_a_refusal() raises:
    var t = _faulty(100)
    var lines = List[String]()
    lines.append(String("out"))
    assert_false(
        upload_logs[FaultyStore](_config(String("logs/t")), t[0], lines),
        "a refused logs.txt is reported",
    )
    assert_false(
        upload_crash_report[FaultyStore](_config(String("logs/t")), t[0], _failure()),
        "a refused crash report is reported",
    )
    assert_equal(_text_at(t[1], String("logs/t/logs.txt")), String("<absent>"))
    # CONTROL: the same writes on a store that accepts them.
    var ok = _faulty(0)
    assert_true(upload_logs[FaultyStore](_config(String("logs/t")), ok[0], lines))
    assert_true(
        upload_crash_report[FaultyStore](_config(String("logs/t")), ok[0], _failure())
    )
    assert_equal(_text_at(ok[1], String("logs/t/logs.txt")), String("out"))
    assert_true(
        _text_at(ok[1], String("logs/t/crash_report.json")).startswith(
            String('{"job_name":"job-1"')
        )
    )
    print("  test_the_terminal_writes_report_a_refusal: PASS")


def test_the_crash_report_escapes_and_lists_its_fields() raises:
    var tail = List[String]()
    tail.append(String("a\\b"))
    tail.append(String("cr\r\nlf"))
    var f = FailureReport(
        None, Optional[Int32](Int32(9)), tail^, Optional[String](String("panic: \"x\""))
    )
    var json = build_crash_report_json(String('j"1'), String("i\t1"), f)
    var want = String(
        '{"job_name":"j\\"1","instance_name":"i\\t1","signal":9,'
        '"stderr_tail":["a\\\\b","cr\\r\\nlf"],'
        '"panic_message":"panic: \\"x\\"","timestamp":"'
    )
    assert_true(json.startswith(want), json)
    assert_equal(json.byte_length(), want.byte_length() + 16 + 2, "stamp then \"}")
    assert_true(json.endswith(String('Z"}')), json)
    assert_false(json.find(String("exit_code")) >= 0, "no exit_code: it did not exit")
    print("  test_the_crash_report_escapes_and_lists_its_fields: PASS")


struct Recorder(HeartbeatReporter):
    var beats: ArcPointer[List[String]]

    def __init__(out self, beats: ArcPointer[List[String]]):
        self.beats = beats

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        return HeartbeatOutcome(True, False, 200)


struct TimedRecorder(HeartbeatReporter):
    """A Recorder that also keeps each beat's monotonic time."""

    var beats: ArcPointer[List[String]]
    var at_ns: ArcPointer[List[UInt64]]

    def __init__(
        out self, beats: ArcPointer[List[String]], at_ns: ArcPointer[List[UInt64]]
    ):
        self.beats = beats
        self.at_ns = at_ns

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        self.at_ns[].append(now_ns())
        return HeartbeatOutcome(True, False, 200)


def test_a_slow_write_cannot_buy_the_job_another_beat() raises:
    # Interval 1 s, flush interval 2 s, limit 3 s; the job prints "x" at once.
    # Beats: RUNNING before the spawn, RUNNING at t~0 and t~1.
    # t~1: "x" is buffered; the stream is 1 s old, so the timer writes nothing.
    # t~2: the inner limit check passes (2 s < 3 s); the timer writes the
    #      chunk and the write stalls 3 s.
    # t~5: the next iteration's limit check stops the job before its RUNNING
    #      beat, then FAILED. A loop without that check beats RUNNING at t~5.
    var argv = List[String]()
    argv.append(String("-c"))
    argv.append(String("printf x; exec sleep 30"))
    var config = JobSupervisorConfig(
        String("slow-store"),
        String("inst-1"),
        String("/bin/sh"),
        argv^,
        String("http://127.0.0.1:1/beat"),
        heartbeat_interval_secs=1,
        log_prefix=String("logs/slow"),
        log_chunk_bytes=1 << 20,
        log_flush_secs=2,
        max_runtime_secs=3,
    )
    var inner = SharedInMemoryConditionalStore()
    var view = inner.clone()
    var slow = FaultyStore(inner^, ArcPointer[Knobs](Knobs(0, 3000)))
    var beats = ArcPointer[List[String]](List[String]())
    var at_ns = ArcPointer[List[UInt64]](List[UInt64]())
    var phase = run_job_supervisor[TimedRecorder, FaultyStore](
        config^, TimedRecorder(beats, at_ns), None, Optional[FaultyStore](slow^)
    )
    assert_true(phase == JobSupervisorPhase.failed(), "the limit stopped it")
    # Beat 0 is sent before the spawn, beat 1 after it.
    assert_true(len(beats[]) >= 3, "two RUNNING beats and the terminal one")
    assert_true(beats[][1].startswith(String("RUNNING|")), beats[][1])
    var after_spawn = at_ns[][1]
    for i in range(1, len(beats[])):
        if beats[][i].startswith(String("RUNNING|")):
            var ms = Int((at_ns[][i] - after_spawn) // 1_000_000)
            assert_true(
                ms < 3000,
                "a RUNNING beat " + String(ms) + " ms after the spawn's beat,"
                " past the 3 s limit",
            )
    var last = beats[][len(beats[]) - 1]
    assert_true(last.startswith(String("FAILED|max runtime of 3 s exceeded")), last)
    assert_equal(_text_at(view, String("logs/slow/chunks/0.log")), String("x"))
    print("  test_a_slow_write_cannot_buy_the_job_another_beat: PASS")


def main() raises:
    print("test_job_supervisor_store_faults:")
    test_a_refused_chunk_is_retried_once()
    test_a_chunk_refused_twice_is_dropped_and_the_index_moves_on()
    test_a_disabled_or_empty_stream_writes_nothing()
    test_the_terminal_writes_report_a_refusal()
    test_the_crash_report_escapes_and_lists_its_fields()
    test_a_slow_write_cannot_buy_the_job_another_beat()
    print("test_job_supervisor_store_faults: ALL PASS")
