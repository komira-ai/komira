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
#       On a manual clock: buffered stdout under the chunk size is not written
#       by the timer at the start nor 999 ms into a 1 s flush interval, and is
#       written once the clock reaches the interval.
#   test_a_failed_spawn_raises_and_marks_nothing_spawned
#       A job binary that does not exist: the spawn raises naming the job,
#       and the supervisor does not count the job as spawned; the run loop
#       raises the same, after its first RUNNING beat.
#   test_a_terminal_beat_with_no_delay_is_retried_at_once
#       `finalize_heartbeat_within` with a first delay of 0 against a reporter
#       that always answers 503, on a manual clock: exactly `max_attempts` (8)
#       sends and the last outcome returned, and the clock has not moved: the
#       retries waited 0 ms. CONTROL: the default first delay moves the clock
#       by exactly 9750 ms (250, 500, 1000, then 2000 four times), so a retry
#       that slept the default schedule instead of the caller's 0 fails the
#       first arm. A 404 is sent once.
#   test_the_loop_clocks_wait_exactly_what_they_are_asked
#       `ManualLoopClock` moves its cell by exactly each wait (nothing for 0)
#       and records it; the wait helper moves nothing for 0 or less and reads
#       the cell; `SystemLoopClock` hands out no cell, reads a clock that never
#       goes back, and a wait of 0 s returns at once.
#   test_a_failure_report_copy_keeps_the_panic_line
#       `FailureReport.copy()` carries the panic line over.
# =============================================================================

from std.ffi import external_call
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

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
    ManualLoopClock,
    SupervisorHeartbeat,
    SystemLoopClock,
    run_job_supervisor,
)
from komira_job_supervisor.loop_clock import clock_now_ns, clock_sleep_ms
from komira_job_supervisor.job_supervisor import (
    TERMINAL_BEAT_FIRST_DELAY_MS,
    TERMINAL_BEAT_MAX_ATTEMPTS,
    TERMINAL_BEAT_MAX_DELAY_MS,
    _detect_panic,
)
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
comptime _CLOCK_START_NS: Int = 5_000_000_000
"""Where a manual clock stands when a test starts it."""


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
    """Wait for the job's exit through try_wait only (no drain); the exit is
    the event, so the wait has no bound of its own."""
    while not js.supervisor.try_wait().collected:
        _sleep_ms(5)


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
    assert_equal(len(js.stdout_partial), 0)
    assert_equal(len(js.stderr_partial), 0)

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
    while not done.child_exited:
        done.poll_and_drain()
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
    while not js.child_exited:
        js.poll_and_drain()
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
    var clock = ArcPointer[Int](_CLOCK_START_NS)
    js.set_test_clock(clock)
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
    clock[] += 999 * 1_000_000  # 1 ms short of the 1 s flush interval
    js._tick_stream_timer()
    var short = True
    try:
        _ = view.get(key)
        short = True
    except:
        short = False
    assert_false(short, "999 ms into a 1 s interval: not written yet")
    clock[] += 1_000_000  # the interval has passed
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
    var clock = ArcPointer[Int](_CLOCK_START_NS)
    js.set_test_clock(clock)
    var out = js.finalize_heartbeat_within(60_000, 0, TERMINAL_BEAT_MAX_ATTEMPTS)
    assert_equal(sends[], TERMINAL_BEAT_MAX_ATTEMPTS, "max_attempts sends")
    assert_equal(out.status, 503, "the last outcome")
    assert_equal(
        clock[], _CLOCK_START_NS, "a first delay of 0 waits 0 ms between sends"
    )
    # CONTROL: the default schedule waits after each of the first seven
    # sends: 250, 500, 1000, then 2000 four times, 9750 ms in all. The clock
    # moves by exactly what the retries waited, so a retry that ignored the
    # caller's first delay and slept this schedule instead would move it too.
    var expected_ms = 0
    var d = TERMINAL_BEAT_FIRST_DELAY_MS
    for _ in range(TERMINAL_BEAT_MAX_ATTEMPTS - 1):
        expected_ms += d
        d = min(d * 2, TERMINAL_BEAT_MAX_DELAY_MS)
    assert_equal(expected_ms, 9750, "the default schedule")
    var scheduled_sends = ArcPointer[Int](0)
    var scheduled = JobSupervisor[Answering, InMemoryConditionalStore](
        _config(String("/bin/true")), Answering(503, scheduled_sends), None
    )
    var scheduled_clock = ArcPointer[Int](_CLOCK_START_NS)
    scheduled.set_test_clock(scheduled_clock)
    _ = scheduled.finalize_heartbeat_within(
        60_000, TERMINAL_BEAT_FIRST_DELAY_MS, TERMINAL_BEAT_MAX_ATTEMPTS
    )
    assert_equal(scheduled_sends[], TERMINAL_BEAT_MAX_ATTEMPTS)
    assert_equal(
        scheduled_clock[] - _CLOCK_START_NS,
        expected_ms * 1_000_000,
        "the default schedule waits 250, 500, 1000, then 2000 ms",
    )
    # CONTROL: a 404 cannot change by repeating: one send.
    var once = ArcPointer[Int](0)
    var js404 = JobSupervisor[Answering, InMemoryConditionalStore](
        _config(String("/bin/true")), Answering(404, once), None
    )
    _ = js404.finalize_heartbeat_within(60_000, 0, 3)
    assert_equal(once[], 1, "a 404 is sent once")
    print("  test_a_terminal_beat_with_no_delay_is_retried_at_once: PASS")


def test_the_loop_clocks_wait_exactly_what_they_are_asked() raises:
    # A manual clock moves by what is waited, records it, and moves by nothing
    # for a wait of 0 or less.
    var cell = ArcPointer[Int](_CLOCK_START_NS)
    var manual = ManualLoopClock(cell)
    assert_equal(manual.now_ns(), UInt64(_CLOCK_START_NS))
    manual.sleep_secs(2)
    manual.sleep_secs(0)
    assert_equal(cell[], _CLOCK_START_NS + 2_000_000_000, "2 s waited, 0 s not")
    assert_equal(len(manual.slept_ms), 2)
    assert_equal(manual.slept_ms[0], 2000)
    assert_equal(manual.slept_ms[1], 0)
    assert_equal(manual.now_ns(), UInt64(cell[]), "it reads the cell")
    assert_true(Bool(manual.test_clock()), "it hands its cell to the supervisor")
    # A helper wait of 0 ms or less moves the cell by nothing, and a reading
    # is the cell's.
    clock_sleep_ms(Optional[ArcPointer[Int]](cell), 0)
    clock_sleep_ms(Optional[ArcPointer[Int]](cell), -5)
    assert_equal(cell[], _CLOCK_START_NS + 2_000_000_000, "no wait, no move")
    clock_sleep_ms(Optional[ArcPointer[Int]](cell), 250)
    assert_equal(clock_now_ns(Optional[ArcPointer[Int]](cell)), UInt64(cell[]))
    assert_equal(cell[], _CLOCK_START_NS + 2_250_000_000, "250 ms waited")
    # The system clock has no cell to hand over, never reads backwards, and a
    # wait of 0 s returns at once.
    var system = SystemLoopClock()
    var first = system.now_ns()
    system.sleep_secs(0)
    assert_true(system.now_ns() >= first, "the monotonic clock never goes back")
    assert_false(Bool(system.test_clock()), "no cell: the supervisor uses the system")
    print("  test_the_loop_clocks_wait_exactly_what_they_are_asked: PASS")


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
    test_the_loop_clocks_wait_exactly_what_they_are_asked()
    test_a_failure_report_copy_keeps_the_panic_line()
    print("test_job_supervisor_steps: ALL PASS")
