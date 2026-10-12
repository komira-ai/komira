# =============================================================================
# komira_job_supervisor/tests/test_job_supervisor_steps.mojo
#   The JobSupervisor's stepping methods at the edges the run loop reaches
#   rarely: the panic scan, the bounded stderr ring, the tails the final drain
#   keeps, a cancel or a stop that comes too late to matter, a clock reading
#   from before the spawn, the stream timer, and a spawn that fails.
# =============================================================================
#
#   test_the_panic_line_is_the_first_match_in_any_case
#       `_detect_panic` returns the FIRST stderr line holding "panic" in any
#       letter case, anywhere in the line, and None when no line holds all
#       five letters in a row.
#   test_the_stderr_ring_keeps_the_last_lines
#       With --max-stderr-lines=3, five stderr lines leave the LAST three.
#   test_the_final_drain_keeps_the_unterminated_tails
#       A job whose last stdout and stderr lines have no newline: after the
#       exit, `_final_drain` reads what is left and pushes both partial lines
#       into the rings. With the pipes closed, a drain changes nothing.
#   test_a_cancel_needs_a_request_and_a_running_job
#       `act_on_cancel` stops nothing without a cancel request, and leaves the
#       result of a job that already exited as it is.
#   test_a_clock_reading_before_the_spawn_stops_nothing
#       `enforce_max_runtime` at an instant before the spawn does not stop the
#       job (an unsigned `now - spawned_at` would wrap past any limit).
#   test_a_stop_after_the_job_ended_keeps_its_result
#       A SIGTERM taken after the job exited ends the loop (True) but the job
#       stays COMPLETED, with no stop message.
#   test_the_stream_timer_flushes_a_quiet_chunk
#       Buffered stdout under the chunk size is written by the timer once the
#       flush interval has passed, and not before.
#   test_a_failed_spawn_raises_and_marks_nothing_spawned
#       A job binary that does not exist: the spawn raises naming the job,
#       and the supervisor does not count the job as spawned; the run loop
#       raises the same, after its first RUNNING beat.
#   test_a_terminal_beat_with_no_delay_is_retried_at_once
#       `finalize_heartbeat_within` with a first delay of 0 against a reporter
#       that always answers 503: exactly `max_attempts` sends, back to back,
#       and the last outcome returned. A 404 is sent once.
#   test_a_failure_report_copy_keeps_the_panic_line
#       `FailureReport.copy()` carries the panic line over.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_clock import now_ns
from komira_objectstore import InMemoryConditionalStore, SharedInMemoryConditionalStore
from komira_objectstore.path import Path
from komira_supervisor import ChildSpec, install_stop_signal_handler
from komira_supervisor.pid1 import take_stop_signal
from komira_supervisor.proc_ffi import SIGTERM, proc_kill

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisor,
    JobSupervisorConfig,
    SupervisorHeartbeat,
    run_job_supervisor,
)
from komira_job_supervisor.job_supervisor import _detect_panic, _sleep_secs
from komira_job_supervisor.job_supervisor_state import (
    FailureReport,
    JobSupervisorPhase,
)


struct Recorder(HeartbeatReporter):
    """Records each beat as `PHASE|message`."""

    var beats: ArcPointer[List[String]]

    def __init__(out self, beats: ArcPointer[List[String]]):
        self.beats = beats

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        return HeartbeatOutcome(True, False, 200)


comptime Steps = JobSupervisor[Recorder, InMemoryConditionalStore]


def _sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def _config(
    var binary: String, max_stderr_lines: Int = 100, max_runtime_secs: Int = 0
) -> JobSupervisorConfig:
    return JobSupervisorConfig(
        String("steps"),
        String("instance-1"),
        binary^,
        List[String](),
        String("http://127.0.0.1:1/beat"),
        heartbeat_interval_secs=1,
        max_stderr_lines=max_stderr_lines,
        max_runtime_secs=max_runtime_secs,
    )


def _steps(var config: JobSupervisorConfig) -> Steps:
    return Steps(config^, Recorder(ArcPointer[List[String]](List[String]())), None)


def _lines(*xs: String) -> List[String]:
    var out = List[String]()
    for x in xs:
        out.append(String(x))
    return out^


def _wait_collected(mut js: Steps) raises:
    """Wait for the job's exit through try_wait only (no drain)."""
    for _ in range(2000):
        if js.supervisor.try_wait().collected:
            return
        _sleep_ms(5)
    raise Error("the job did not exit within 10 s")


def test_the_panic_line_is_the_first_match_in_any_case() raises:
    var hit = _detect_panic(
        _lines("starting", "worker 3: Panicked at src/main.rs:9", "panic: again")
    )
    assert_equal(hit.value(), String("worker 3: Panicked at src/main.rs:9"))
    var tail = _detect_panic(_lines("ok", "fatal error: PANIC"))
    assert_equal(tail.value(), String("fatal error: PANIC"), "at the end of a line")
    # CONTROL: no line holds the five letters in a row.
    assert_false(_detect_panic(_lines("pani", "p anic", "PANI-C")).__bool__())
    assert_false(_detect_panic(List[String]()).__bool__())
    print("  test_the_panic_line_is_the_first_match_in_any_case: PASS")


def test_the_stderr_ring_keeps_the_last_lines() raises:
    var js = _steps(_config(String("/bin/true"), max_stderr_lines=3))
    js._absorb(String("e1\ne2\ne3\ne4\ne5\n"), False)
    assert_equal(len(js.stderr_ring), 3, "bounded at three")
    assert_equal(js.stderr_ring[0], String("e3"))
    assert_equal(js.stderr_ring[1], String("e4"))
    assert_equal(js.stderr_ring[2], String("e5"))
    # CONTROL: under the bound nothing is dropped.
    var wide = _steps(_config(String("/bin/true"), max_stderr_lines=10))
    wide._absorb(String("e1\ne2\n"), False)
    assert_equal(len(wide.stderr_ring), 2)
    assert_equal(wide.stderr_ring[0], String("e1"))
    print("  test_the_stderr_ring_keeps_the_last_lines: PASS")


def test_the_final_drain_keeps_the_unterminated_tails() raises:
    var js = _steps(_config(String("/bin/sh")))
    js.spawn_child_spec(
        ChildSpec.shell(
            String("printf 'out-1\\nout-tail'; printf 'err-1\\nerr-tail' >&2")
        )
    )
    _wait_collected(js)
    js._final_drain()
    assert_equal(len(js.stdout_ring), 2, "stdout: one whole line and the tail")
    assert_equal(js.stdout_ring[0], String("out-1"))
    assert_equal(js.stdout_ring[1], String("out-tail"))
    assert_equal(len(js.stderr_ring), 2, "stderr: one whole line and the tail")
    assert_equal(js.stderr_ring[0], String("err-1"))
    assert_equal(js.stderr_ring[1], String("err-tail"))
    assert_equal(js.stdout_partial, String(""))
    assert_equal(js.stderr_partial, String(""))

    # The pipes closed: a drain of either kind reads nothing and keeps the rings.
    js.supervisor.close()
    js._incremental_drain()
    js._final_drain()
    assert_equal(len(js.stdout_ring), 2)
    assert_equal(len(js.stderr_ring), 2)
    print("  test_the_final_drain_keeps_the_unterminated_tails: PASS")


def test_a_cancel_needs_a_request_and_a_running_job() raises:
    # No request: a running job is left running.
    var live = _steps(_config(String("/bin/sh")))
    live.spawn_child_spec(ChildSpec.shell(String("exec sleep 30")))
    live.act_on_cancel(100)
    assert_false(live.child_exited, "no cancel request: the job runs on")
    assert_false(live.supervisor.try_wait().collected, "and was not signalled")
    assert_true(live.state.phase == JobSupervisorPhase.running())
    _ = live.supervisor.terminate(100)

    # A request that comes after the job exited: its result stands.
    var done = _steps(_config(String("/bin/true")))
    done.spawn_child()
    for _ in range(2000):
        done.poll_and_drain()
        if done.child_exited:
            break
        _sleep_ms(5)
    assert_true(done.child_exited, "/bin/true exited")
    done.state.cancel_requested = True
    done.act_on_cancel(100)
    assert_true(
        done.state.phase == JobSupervisorPhase.running(), "not marked CANCELLED"
    )
    done.analyze_exit()
    assert_true(done.terminal_phase() == JobSupervisorPhase.completed(), "COMPLETED")
    print("  test_a_cancel_needs_a_request_and_a_running_job: PASS")


def test_a_clock_reading_before_the_spawn_stops_nothing() raises:
    var js = _steps(_config(String("/bin/sh"), max_runtime_secs=1))
    js.spawn_child_spec(ChildSpec.shell(String("exec sleep 30")))
    assert_false(
        js.enforce_max_runtime(js.spawned_at_ns - 1, 100),
        "an instant before the spawn is not past the limit",
    )
    assert_false(js.child_exited, "the job runs on")
    assert_false(js.state.timed_out)
    # CONTROL: the same job at one second past the spawn is stopped.
    assert_true(js.enforce_max_runtime(js.spawned_at_ns + 1_000_000_000, 100))
    assert_true(js.child_exited)
    print("  test_a_clock_reading_before_the_spawn_stops_nothing: PASS")


def test_a_stop_after_the_job_ended_keeps_its_result() raises:
    install_stop_signal_handler()
    _ = take_stop_signal()  # nothing left over from before
    var js = _steps(_config(String("/bin/true")))
    js.spawn_child()
    for _ in range(2000):
        js.poll_and_drain()
        if js.child_exited:
            break
        _sleep_ms(5)
    assert_true(js.child_exited, "/bin/true exited")
    _ = proc_kill(external_call["getpid", Int32](), SIGTERM)
    assert_true(js.act_on_stop_signal(100), "the stop is taken: the loop ends")
    assert_true(js.state.phase == JobSupervisorPhase.running(), "not CANCELLED")
    assert_false(js.state.message.__bool__(), "no stop message")
    js.analyze_exit()
    assert_true(js.terminal_phase() == JobSupervisorPhase.completed(), "COMPLETED")
    # CONTROL: with no signal pending, nothing is taken.
    assert_false(js.act_on_stop_signal(100))
    print("  test_a_stop_after_the_job_ended_keeps_its_result: PASS")


def test_the_stream_timer_flushes_a_quiet_chunk() raises:
    var store = SharedInMemoryConditionalStore()
    var view = store.clone()
    var config = _config(String("/bin/true"))
    config.log_prefix = String("logs/quiet")
    config.log_chunk_bytes = 1 << 20
    config.log_flush_secs = 1
    var js = JobSupervisor[Recorder, SharedInMemoryConditionalStore](
        config^,
        Recorder(ArcPointer[List[String]](List[String]())),
        Optional[SharedInMemoryConditionalStore](store^),
    )
    var key = Path.parse(String("logs/quiet/chunks/0.log"))
    js._absorb(String("quiet\n"), True)
    js._tick_stream_timer()
    var early = True
    try:
        _ = view.get(key)
        early = True
    except:
        early = False
    assert_false(early, "under the size and inside the interval: not written yet")
    _sleep_ms(1100)
    js._tick_stream_timer()
    var got = view.get(key)
    assert_equal(String(unsafe_from_utf8=Span(got)), String("quiet\n"))
    # CONTROL: with no store the timer is a no-op.
    var bare = _steps(_config(String("/bin/true")))
    bare._absorb(String("x\n"), True)
    bare._tick_stream_timer()
    assert_false(bare.log_sink.enabled)
    print("  test_the_stream_timer_flushes_a_quiet_chunk: PASS")


def test_a_failed_spawn_raises_and_marks_nothing_spawned() raises:
    var js = _steps(_config(String("/nonexistent.invalid/job")))
    var r = String("")
    try:
        js.spawn_child()
    except e:
        r = String(e)
    assert_true(r.find(String("spawn failed for job steps")) >= 0, r)
    assert_false(js.spawned, "nothing was spawned")

    var beats = ArcPointer[List[String]](List[String]())
    r = String("")
    try:
        _ = run_job_supervisor[Recorder, InMemoryConditionalStore](
            _config(String("/nonexistent.invalid/job")), Recorder(beats), None, None
        )
    except e:
        r = String(e)
    assert_true(r.find(String("spawn failed for job steps")) >= 0, "run: " + r)
    assert_equal(len(beats[]), 1, "only the first RUNNING beat went out")
    assert_true(beats[][0].startswith(String("RUNNING|")))
    print("  test_a_failed_spawn_raises_and_marks_nothing_spawned: PASS")


struct Answering(HeartbeatReporter):
    """Answers every beat with `status` (not delivered) and counts them."""

    var status: Int
    var sends: ArcPointer[Int]

    def __init__(out self, status: Int, sends: ArcPointer[Int]):
        self.status = status
        self.sends = sends

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        self.sends[] += 1
        return HeartbeatOutcome(False, False, self.status)


def test_a_terminal_beat_with_no_delay_is_retried_at_once() raises:
    var sends = ArcPointer[Int](0)
    var js = JobSupervisor[Answering, InMemoryConditionalStore](
        _config(String("/bin/true")), Answering(503, sends), None
    )
    var t0 = now_ns()
    var out = js.finalize_heartbeat_within(60_000, 0, 3)
    var took_ms = Int((now_ns() - t0) // 1_000_000)
    assert_equal(sends[], 3, "max_attempts sends")
    assert_equal(out.status, 503, "the last outcome")
    assert_true(took_ms < 1000, "no delay between them: " + String(took_ms))
    _sleep_secs(0)
    assert_true(Int((now_ns() - t0) // 1_000_000) < 1000, "a zero sleep returns")
    # CONTROL: a 404 cannot change by repeating: one send.
    var once = ArcPointer[Int](0)
    var js404 = JobSupervisor[Answering, InMemoryConditionalStore](
        _config(String("/bin/true")), Answering(404, once), None
    )
    _ = js404.finalize_heartbeat_within(60_000, 0, 3)
    assert_equal(once[], 1, "a 404 is sent once")
    print("  test_a_terminal_beat_with_no_delay_is_retried_at_once: PASS")


def test_a_failure_report_copy_keeps_the_panic_line() raises:
    var f = FailureReport(
        Optional[Int32](Int32(101)),
        None,
        _lines("thread 'main' panicked at x"),
        Optional[String](String("thread 'main' panicked at x")),
    )
    var c = f.copy()
    assert_equal(c.panic_message.value(), String("thread 'main' panicked at x"))
    assert_equal(c.exit_code.value(), Int32(101))
    assert_false(c.signal.__bool__())
    assert_equal(len(c.stderr_tail), 1)
    print("  test_a_failure_report_copy_keeps_the_panic_line: PASS")


def main() raises:
    print("test_job_supervisor_steps:")
    test_the_panic_line_is_the_first_match_in_any_case()
    test_the_stderr_ring_keeps_the_last_lines()
    test_the_final_drain_keeps_the_unterminated_tails()
    test_a_cancel_needs_a_request_and_a_running_job()
    test_a_clock_reading_before_the_spawn_stops_nothing()
    test_a_stop_after_the_job_ended_keeps_its_result()
    test_the_stream_timer_flushes_a_quiet_chunk()
    test_a_failed_spawn_raises_and_marks_nothing_spawned()
    test_a_terminal_beat_with_no_delay_is_retried_at_once()
    test_a_failure_report_copy_keeps_the_panic_line()
    print("test_job_supervisor_steps: ALL PASS")
