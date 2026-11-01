# =============================================================================
# komira_job_supervisor/tests/test_pid1_stop_and_reap.mojo
#   The supervisor as a container's PID 1: a stop signal sent to it reaches
#   the job's whole process group and ends in a CANCELLED beat, orphans are
#   collected, the job starts with default signal dispositions, and the
#   terminal beat is retried within a budget.
# =============================================================================
#
# A file of its own: these tests send signals to this process and make it a
# child subreaper, and each one leaves no child behind for the next.
#
# Off Linux there is no child subreaper and no /proc: the four tests that need
# one of them (the grandchild, the SIGKILL, the orphans, the default signals)
# are skipped by name, and adopt_orphans() is asserted to refuse instead.
#
#   test_the_run_loop_turns_a_platform_sigterm_into_cancelled  (runs FIRST)
#       `run_job_supervisor_with_clock` (on a manual clock) on `sh -c 'kill
#       -TERM $PPID; exec sleep 30'`: the job SIGTERMs its parent, this
#       process, as a platform stops a container. The run ends CANCELLED and
#       the last beat is CANCELLED naming SIGTERM (a run that ignored the stop
#       would end COMPLETED after the job's own 30 s). Nothing in this file
#       installs the handler
#       before this test, so with run_job_supervisor's install removed
#       (mutant: no handler) the SIGTERM kills this process and the build fails.
#   test_a_stop_before_the_spawn_starts_no_job
#       The reporter SIGTERMs this process while the first RUNNING beat is
#       being sent, as a platform may stop a container during the fetch or
#       the first beat. The run ends CANCELLED with two beats, the second
#       saying the job was not started, and the loop never waits. Mutant: no stop check before the spawn -> the job is spawned
#       and stopped on the first loop pass ("the job was stopped").
#       It also asserts that this process has no child when the run returns,
#       so a job that is spawned and left running fails here, on every
#       platform. Mutant: the stop check's guard removed (spawn always)
#       -> "a job was spawned and left running".
#   test_a_stop_signal_reaches_the_grandchild
#       Stepping: the job starts `sleep 60` in the background, prints its pid,
#       SIGTERMs this process and waits. act_on_stop_signal forwards SIGTERM
#       to the job's process group: the shell and the grandchild both die of
#       the SIGTERM (not of a SIGKILL after the grace), the grandchild pid is
#       gone, and the beat is CANCELLED. Mutant: signal the pid, not the group
#       (Supervisor._signal_child) -> the grandchild survives the SIGTERM and
#       the SIGKILL.
#   test_sigkill_reaches_a_grandchild_that_ignores_sigterm
#       The job starts a grandchild that ignores SIGTERM (`trap '' TERM`,
#       kept across exec), which prints its pid and then SIGTERMs this
#       process, so the ignore is in place before any stop is sent. The
#       stop's SIGTERM kills the shell only; with a 500 ms grace (the
#       grace_ms argument), act_on_stop_signal must SIGKILL the group when the
#       grace is out and return only once the group is empty: the
#       grandchild is gone and the group signal finds nobody before the
#       CANCELLED beat is sent. The grace is komira_supervisor's own wait; its
#       length is that package's to test, so no elapsed time is read here. Mutants: the SIGKILL sent to the job's pid
#       instead of its group (Supervisor.terminate_with) -> the grandchild
#       survives; the grace loop returning as soon as the job itself is
#       reaped (group condition dropped) -> no SIGKILL at all, the
#       grandchild survives.
#   test_a_forwarded_sigint_stays_sigint
#       The job sends SIGINT to this process; the job is stopped by SIGINT
#       (signal 2), not by a SIGTERM substituted for it.
#   test_orphans_are_reaped
#       The job starts three background subshells, prints their pids and exits
#       at once; they are re-parented to this process (a subreaper) and exit
#       0.2 s later. Once /proc shows all three exited (zombies of this
#       process), ONE poll_and_drain leaves this process with no child at all. Mutants: no reap in poll_and_drain -> three zombies; the shim's
#       loop collecting only the first -> two zombies.
#   test_the_job_starts_with_default_signals
#       This process ignores SIGPIPE (as it does after any TLS connection);
#       the job's SigIgn mask has no SIGPIPE bit. CONTROL: a plain Supervisor
#       child does inherit the ignore, so the arm is not vacuous. Mutant: no
#       set_default_signals in spawn_child_spec.
#   test_the_terminal_beat_is_retried_after_one_503
#       A reporter answering 503 then 200: finalize_heartbeat sends twice and
#       returns ok (mutant: send once). CONTROLS: a 403 is sent once; an
#       always-503 receiver gets exactly max_attempts sends, and a short
#       budget stops the retries before max_attempts. The jobs run on a manual
#       clock the retries' waits move, so the budget is counted, not timed.
# =============================================================================

from std.ffi import external_call
from std.sys.info import CompilationTarget
from std.memory import ArcPointer
from std.testing import assert_equal, assert_false, assert_true

from komira_async.reactor.graceful_shutdown import ignore_sigpipe
from komira_objectstore import InMemoryConditionalStore
from komira_supervisor import (
    ChildSpec,
    Supervisor,
    adopt_orphans,
    install_stop_signal_handler,
    proc_probe_children,
)
from komira_supervisor.proc_ffi import (
    SIGINT,
    SIGKILL,
    SIGTERM,
    proc_kill,
    proc_kill_group,
)

from komira_job_supervisor import (
    HeartbeatOutcome,
    HeartbeatReporter,
    JobSupervisor,
    JobSupervisorConfig,
    ManualLoopClock,
    SupervisorHeartbeat,
    run_job_supervisor_with_clock,
    terminal_beat_retryable,
)
from komira_job_supervisor.job_supervisor_state import JobSupervisorPhase


struct Recorder(HeartbeatReporter):
    """Records each beat as `PHASE|message`; answers with the next scripted
    status (200 once the script runs out)."""

    var beats: ArcPointer[List[String]]
    var script: List[Int]
    var sent: Int

    def __init__(out self, beats: ArcPointer[List[String]]):
        self.beats = beats
        self.script = List[Int]()
        self.sent = 0

    def __init__(out self, beats: ArcPointer[List[String]], var script: List[Int]):
        self.beats = beats
        self.script = script^
        self.sent = 0

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        var status = 200
        if self.sent < len(self.script):
            status = self.script[self.sent]
        self.sent += 1
        return HeartbeatOutcome(status >= 200 and status < 300, False, status)


struct StopOnFirstBeat(HeartbeatReporter):
    """Records each beat as `PHASE|message`; on the FIRST one it sends
    SIGTERM to this process (a stop arriving during the first beat)."""

    var beats: ArcPointer[List[String]]

    def __init__(out self, beats: ArcPointer[List[String]]):
        self.beats = beats

    def report(mut self, hb: SupervisorHeartbeat) -> HeartbeatOutcome:
        var line = String(hb.phase.wire_str()) + String("|")
        if hb.message:
            line += hb.message.value()
        self.beats[].append(line^)
        if len(self.beats[]) == 1:
            _ = proc_kill(external_call["getpid", Int32](), SIGTERM)
        return HeartbeatOutcome(True, False, 200)


comptime TestJob = JobSupervisor[Recorder, InMemoryConditionalStore]
comptime _CLOCK_START_NS: Int = 4_000_000_000
"""Where a manual clock stands when a run starts."""


def _shell_job(script: String) -> JobSupervisorConfig:
    var argv = List[String]()
    argv.append(String("-c"))
    argv.append(script)
    return JobSupervisorConfig(
        String("pid1-job"),
        String("instance-1"),
        String("/bin/sh"),
        argv^,
        String("http://127.0.0.1:1/beat"),
        heartbeat_interval_secs=1,
    )


def _sleep_ms(ms: Int):
    _ = external_call["usleep", Int32](UInt32(ms * 1000))


def _await_stop(mut js: TestJob, grace_ms: Int) raises:
    """Call act_on_stop_signal every 10 ms until it takes a signal (the job
    sends it). The signal is the event waited for, so the wait has no bound of
    its own."""
    while not js.act_on_stop_signal(grace_ms):
        js.poll_and_drain()
        _sleep_ms(10)


def test_the_run_loop_turns_a_platform_sigterm_into_cancelled() raises:
    var beats = ArcPointer[List[String]](List[String]())
    var clock = ManualLoopClock(ArcPointer[Int](_CLOCK_START_NS))
    var phase = run_job_supervisor_with_clock[
        Recorder, InMemoryConditionalStore, ManualLoopClock
    ](
        _shell_job(String("kill -TERM $PPID; exec sleep 30")),
        Recorder(beats),
        None,
        None,
        clock,
    )
    assert_true(phase == JobSupervisorPhase.cancelled(), "a platform SIGTERM cancels")
    var last = beats[][len(beats[]) - 1]
    assert_true(
        last.startswith(String("CANCELLED|the supervisor received SIGTERM")),
        "the terminal beat: " + last,
    )
    assert_true(beats[][0].startswith(String("RUNNING|")), "RUNNING first")
    print("  test_the_run_loop_turns_a_platform_sigterm_into_cancelled: PASS")


def test_a_stop_before_the_spawn_starts_no_job() raises:
    var beats = ArcPointer[List[String]](List[String]())
    var clock = ManualLoopClock(ArcPointer[Int](_CLOCK_START_NS))
    var phase = run_job_supervisor_with_clock[
        StopOnFirstBeat, InMemoryConditionalStore, ManualLoopClock
    ](
        _shell_job(String("exec sleep 30")),
        StopOnFirstBeat(beats),
        None,
        None,
        clock,
    )
    assert_true(phase == JobSupervisorPhase.cancelled(), "a stop before the spawn cancels")
    assert_equal(len(beats[]), 2, "RUNNING, then the terminal beat")
    assert_true(beats[][0].startswith(String("RUNNING|")), beats[][0])
    assert_equal(
        beats[][1],
        String(
            "CANCELLED|the supervisor received SIGTERM; the job was not started"
        ),
        "the job was never spawned",
    )
    assert_equal(len(clock.slept_ms), 0, "the loop never waited: no job to wait for")
    # The heartbeats alone cannot tell "never spawned" from "spawned and left
    # running": check that this process has no child at all. waitid(P_ALL) is
    # POSIX, so this runs on every platform. The test before this one reaps
    # its own job, and nothing here adopts orphans yet.
    var p = proc_probe_children()
    assert_false(
        p.any_child,
        "pre-spawn stop: a job was spawned and left running (exited pid "
        + String(p.exited_pid)
        + ")",
    )
    print("  test_a_stop_before_the_spawn_starts_no_job: PASS")


def test_a_stop_signal_reaches_the_grandchild() raises:
    install_stop_signal_handler()
    assert_true(adopt_orphans(), "this process receives orphans (Linux)")
    var beats = ArcPointer[List[String]](List[String]())
    var js = TestJob(_shell_job(String("unused")), Recorder(beats), None)
    js.spawn_child_spec(
        ChildSpec.shell(String("sleep 60 & echo $!; kill -TERM $PPID; wait"))
    )
    while len(js.stdout_ring) == 0:
        js.poll_and_drain()
        _sleep_ms(10)
    assert_equal(len(js.stdout_ring), 1, "the job printed its grandchild's pid")
    var grandchild = Int32(atol(js.stdout_ring[0]))
    assert_equal(proc_kill(grandchild, Int32(0)), Int32(0), "the grandchild runs")

    _await_stop(js, 5000)
    var survived = proc_kill(grandchild, Int32(0)) == Int32(0)
    if survived:
        _ = proc_kill(grandchild, SIGKILL)  # do not leave it to the next test
    assert_false(survived, "the group SIGTERM reached the grandchild")
    # The job died of the SIGTERM, not of the SIGKILL that follows the grace:
    # the group emptied within the grace.
    assert_equal(js.exit_info.signal, SIGTERM, "the job died of the SIGTERM")
    js.analyze_exit()
    assert_true(js.terminal_phase() == JobSupervisorPhase.cancelled(), "CANCELLED")
    _ = js.finalize_heartbeat()
    var last = beats[][len(beats[]) - 1]
    assert_true(
        last.startswith(String("CANCELLED|the supervisor received SIGTERM")), last
    )
    _ = js^
    print("  test_a_stop_signal_reaches_the_grandchild: PASS")


comptime _TERM_IGNORING_GRANDCHILD = (
    "p=$PPID; (trap '' TERM; exec sh -c 'echo $$; kill -TERM \"$1\";"
    " exec sleep 60 >/dev/null 2>&1' grandchild \"$p\") & wait"
)
"""The job: a background subshell ignores SIGTERM and execs a shell (the
ignore is inherited by exec) that prints its own pid, SIGTERMs this process
(the job's parent, passed as $1) and becomes `sleep 60` with the pipes
closed. The job itself waits with SIGTERM at its default."""


def test_sigkill_reaches_a_grandchild_that_ignores_sigterm() raises:
    install_stop_signal_handler()
    assert_true(adopt_orphans(), "this process receives orphans (Linux)")
    var beats = ArcPointer[List[String]](List[String]())
    var js = TestJob(_shell_job(String("unused")), Recorder(beats), None)
    js.spawn_child_spec(ChildSpec.shell(String(_TERM_IGNORING_GRANDCHILD)))
    var group = js.supervisor.process_group()
    assert_true(group > Int32(1), "the job leads its own group")
    while len(js.stdout_ring) == 0:
        js.poll_and_drain()
        _sleep_ms(10)
    assert_equal(len(js.stdout_ring), 1, "the grandchild printed its pid")
    var grandchild = Int32(atol(js.stdout_ring[0]))
    assert_equal(proc_kill(grandchild, Int32(0)), Int32(0), "the grandchild runs")

    comptime GRACE_MS = 500
    _await_stop(js, GRACE_MS)
    # Read before anything else runs: the stop has returned, the CANCELLED
    # beat has not been sent yet.
    var survived = proc_kill(grandchild, Int32(0)) == Int32(0)
    var group_left = proc_kill_group(group, Int32(0)) == Int32(0)
    if survived:
        _ = proc_kill(grandchild, SIGKILL)  # do not leave it to the next test
    assert_false(survived, "the SIGKILL after the grace reached the grandchild")
    assert_false(group_left, "the group was empty when the stop returned")
    assert_equal(js.exit_info.signal, SIGTERM, "the job died of the SIGTERM")
    js.analyze_exit()
    _ = js.finalize_heartbeat()
    var last = beats[][len(beats[]) - 1]
    assert_true(
        last.startswith(String("CANCELLED|the supervisor received SIGTERM")), last
    )
    _ = js^
    print("  test_sigkill_reaches_a_grandchild_that_ignores_sigterm: PASS")


def test_a_forwarded_sigint_stays_sigint() raises:
    install_stop_signal_handler()
    var beats = ArcPointer[List[String]](List[String]())
    var js = TestJob(_shell_job(String("unused")), Recorder(beats), None)
    js.spawn_child_spec(ChildSpec.shell(String("kill -INT $PPID; exec sleep 30")))
    _ = _await_stop(js, 5000)
    assert_equal(js.exit_info.signal, SIGINT, "the job got the SIGINT itself")
    js.analyze_exit()
    _ = js.finalize_heartbeat()
    var last = beats[][len(beats[]) - 1]
    assert_true(
        last.startswith(String("CANCELLED|the supervisor received SIGINT")), last
    )
    _ = js^
    print("  test_a_forwarded_sigint_stays_sigint: PASS")


def _await_zombie(pid: Int32):
    """Wait until `pid` has exited and waits to be collected (state Z in
    /proc), or /proc no longer lists it. The exit is the event, so the wait
    has no bound of its own."""
    var path = String("/proc/") + String(Int(pid)) + String("/stat")
    while True:
        try:
            with open(path, "r") as f:
                # "pid (comm) S ...": the state follows the last ')'.
                var stat = f.read()
                var bytes = stat.as_bytes()
                var close = len(bytes) - 1
                while close >= 0 and bytes[close] != UInt8(41):
                    close -= 1
                if close >= 0 and close + 2 < len(bytes):
                    if bytes[close + 2] == UInt8(90):  # 'Z'
                        return
        except:
            return
        _sleep_ms(5)


def test_orphans_are_reaped() raises:
    assert_true(adopt_orphans(), "this process receives orphans (Linux)")
    var js = TestJob(
        _shell_job(String("unused")),
        Recorder(ArcPointer[List[String]](List[String]())),
        None,
    )
    # Each background subshell prints its pid, then exits 7 after 0.2 s.
    js.spawn_child_spec(
        ChildSpec.shell(
            String("for i in 1 2 3; do (sleep 0.2; exit 7) & echo $!; done; exit 0")
        )
    )
    while not js.child_exited:
        js.poll_and_drain()
        _sleep_ms(10)
    assert_equal(js.exit_info.exit_code, Int32(0), "the job itself exited 0")
    assert_equal(len(js.stdout_ring), 3, "the job printed its three orphans' pids")
    # Wait for the event the pass is about: every orphan has exited and is a
    # zombie of this process (nothing here collects it).
    for i in range(3):
        _await_zombie(Int32(atol(js.stdout_ring[i])))
    js.poll_and_drain()  # ONE pass
    var p = proc_probe_children()
    assert_false(
        p.any_child,
        "one pass left no child; an exited one: " + String(p.exited_pid),
    )
    _ = js^
    print("  test_orphans_are_reaped: PASS")


comptime _SIGPIPE_IGNORED_EXIT = (
    "v=$(grep '^SigIgn' /proc/self/status | cut -f2);"
    " exit $(( (0x$v >> 12) & 1 ))"
)
"""Exit 1 iff SIGPIPE (signal 13, bit 12 of SigIgn) is ignored. grep reads its
own status; exec keeps an ignored signal ignored, so it shows the shell's."""


def test_the_job_starts_with_default_signals() raises:
    assert_true(ignore_sigpipe(), "this process ignores SIGPIPE")
    var control = Supervisor()
    assert_true(control.spawn(ChildSpec.shell(String(_SIGPIPE_IGNORED_EXIT))) > 0)
    _ = control.drain_pipe(control.stdout_fd())
    _ = control.drain_pipe(control.stderr_fd())
    assert_equal(
        control.wait_exit().exit_code,
        Int32(1),
        "CONTROL: a plain child inherits the ignored SIGPIPE",
    )
    control.close()

    var js = TestJob(
        _shell_job(String("unused")),
        Recorder(ArcPointer[List[String]](List[String]())),
        None,
    )
    js.spawn_child_spec(ChildSpec.shell(String(_SIGPIPE_IGNORED_EXIT)))
    while not js.child_exited:
        js.poll_and_drain()
        _sleep_ms(10)
    assert_equal(js.exit_info.exit_code, Int32(0), "the job's SIGPIPE is default")
    _ = js^
    print("  test_the_job_starts_with_default_signals: PASS")


def _finished_job(var script: List[Int], beats: ArcPointer[List[String]]) -> TestJob:
    var js = TestJob(_shell_job(String("unused")), Recorder(beats, script^), None)
    js.state.phase = JobSupervisorPhase.completed()
    js.set_test_clock(ArcPointer[Int](_CLOCK_START_NS))
    return js^


def test_the_terminal_beat_is_retried_after_one_503() raises:
    var beats = ArcPointer[List[String]](List[String]())
    var js = _finished_job([503, 200], beats)
    var out = js.finalize_heartbeat()
    assert_equal(len(beats[]), 2, "sent again after the 503")
    assert_true(out.ok, "the retry was delivered")
    assert_true(beats[][1].startswith(String("COMPLETED|")), beats[][1])
    _ = js^

    var refused = ArcPointer[List[String]](List[String]())
    var js2 = _finished_job([403, 200], refused)
    var out2 = js2.finalize_heartbeat()
    assert_equal(len(refused[]), 1, "CONTROL: a 403 is not sent again")
    assert_false(out2.ok, "CONTROL: the 403 is the outcome")
    _ = js2^

    var down = ArcPointer[List[String]](List[String]())
    var js3 = _finished_job([503, 503, 503, 503, 503, 503], down)
    var out3 = js3.finalize_heartbeat_within(60_000, 1, 3)
    assert_equal(len(down[]), 3, "CONTROL: at most max_attempts sends")
    assert_equal(out3.status, 503, "CONTROL: the last failure is the outcome")
    _ = js3^

    var slow = ArcPointer[List[String]](List[String]())
    var js4 = _finished_job([503, 503, 503, 503, 503, 503], slow)
    _ = js4.finalize_heartbeat_within(150, 100, 8)
    assert_equal(len(slow[]), 2, "CONTROL: the budget ends the retries")
    _ = js4^

    for s in [0, -1, 408, 429, 500, 503, 599]:
        assert_true(terminal_beat_retryable(s), "retryable: " + String(s))
    for s in [-2, 200, 400, 401, 403, 404, 499, 600]:
        assert_false(terminal_beat_retryable(s), "final: " + String(s))
    print("  test_the_terminal_beat_is_retried_after_one_503: PASS")


def main() raises:
    # FIRST: nothing before it may install the stop handler (module header).
    test_the_run_loop_turns_a_platform_sigterm_into_cancelled()
    test_a_stop_before_the_spawn_starts_no_job()
    test_a_forwarded_sigint_stays_sigint()
    test_the_terminal_beat_is_retried_after_one_503()
    comptime if CompilationTarget.is_linux():
        test_a_stop_signal_reaches_the_grandchild()
        test_sigkill_reaches_a_grandchild_that_ignores_sigterm()
        test_orphans_are_reaped()
        test_the_job_starts_with_default_signals()
    else:
        assert_false(adopt_orphans(), "no child subreaper off Linux")
        print(
            "  SKIP (not Linux: no child subreaper, no /proc):"
            " grandchild, SIGKILL escalation, orphans, default signals"
        )
    print("PASS test_pid1_stop_and_reap")
