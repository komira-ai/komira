# =============================================================================
# test_job_supervisor_heartbeat_loopback.mojo -- run_job_supervisor, the REAL
# HttpHeartbeatReporter and REAL children, against a stateful heartbeat
# receiver on a real komira_http_server HttpServer, in one build action
# =============================================================================
#
# Each case runs `run_job_supervisor` on one thread (a `/bin/sh` job spawned
# through komira_supervisor) while a `HeartbeatReceiver` (heartbeat_receiver.mojo)
# is served on 127.0.0.1 on the other. Every assertion about what the
# supervisor reported is made from the receiver's side, i.e. from the decoded
# wire, and every case asserts the receiver recorded no violation of its state
# machine (a beat after a terminal one, CANCELLED without a CANCEL, RUNNING
# after a CANCEL, a FAILED beat without a JobFailure, a wrong job id...).
#
#   (a) COMPLETED: the job waits for the receiver's first-beat gate, then
#       `sleep 3`. History ASSIGNED, RUNNING, COMPLETED; the run returned
#       COMPLETED. The first beat is proven to precede the spawn by an ORDER
#       of events, with no wait in it (heartbeat_receiver.mojo, FIRST-BEAT
#       PROBE): before answering beat 1 the receiver asks the kernel whether
#       this process has a child, and only then creates the gate file. The
#       job is a posix_spawn child of this process, in the process table
#       from the moment the spawn returns, so a supervisor that spawned
#       before beat 1 (planted: delete the initial pre-spawn beat) has a
#       child when beat 1 arrives, on any worker however slow, and the probe
#       records a violation; the job cannot exit before the probe looks, as
#       it is held at the gate. The job also records whether the gate was
#       already there when it started (it must be: the job-side record of
#       the same order). At least 3 RUNNING beats: the pre-spawn
#       one, the one right after spawn, and one after a full interval with the
#       job still running (a loop that never beats again sends only 2). The
#       wire carries no exit code for COMPLETED: the receiver derives exit 0
#       from the phase, so the exit-code check here only confirms that a job
#       exiting 0 maps to COMPLETED with no JobFailure (a JobFailure on a
#       COMPLETED beat is a violation). Catches: a terminal phase mapped wrong,
#       a missing initial beat, a beat sent after the terminal one.
#   (b) cancel: the job writes its pid and execs `sleep 30`. The receiver flags
#       cancel_requested after the 3rd RUNNING beat, so the 4th (about 2 s
#       after spawn) is answered CANCEL. History ASSIGNED, RUNNING, CANCELLING,
#       CANCELLED; beats RUNNING x4 then CANCELLED; replies CONTINUE x3,
#       CANCEL; the pid was alive when CANCEL was sent and is gone after the
#       run (kill(pid, 0) fails); well under 30 s. Catches: a reporter that
#       drops the CANCEL (planted: the RUNNING beat after CANCEL is a violation
#       and the job runs to COMPLETED), a supervisor that reports CANCELLED but
#       leaves the child running.
#   (c) FAILED: 80 stderr lines of 112 bytes (8960 bytes, every line distinct
#       by its index), exit 3, with max_stderr_lines set to twice that so the
#       supervisor's line cap cannot be what drops a line. The receiver gets
#       every line, byte for byte, exit code 3 (this one IS read off the wire,
#       from the JobFailure), no signal, history ASSIGNED, RUNNING, FAILED.
#       The FAILED beat's body is larger than the server's first-recv buffer
#       (komira_http_server REQ_BUF_BYTES), so the server needed more than one
#       recv to reassemble it (dispatch's cross-recv body accumulation; argued
#       from the buffer size, not counted). Catches: a tail cut at a byte
#       budget (planted: truncate at 4096 bytes), a dropped or reordered line;
#       a body dispatched short would fail to decode (an "undecodable body"
#       violation), argued, not planted.
#   CONTROL: every beat answered with directive 7, a number this build has no
#       name for; `sleep 3` runs to COMPLETED. Without it, (b) is satisfied by a
#       supervisor that stops on any reply.
#
# This replaces komira_job_supervisor's test_heartbeat_send_cancel, whose
# responder was a raw-socket pthread replaying scripted replies: (b) and the
# CONTROL are its two cases, now against a receiver that holds the run's state.
# =============================================================================

from std.os import remove
from std.pathlib import Path
from std.testing import assert_equal, assert_true

from komira_clock import now_ns
from komira_http_core.codec import HttpMethod
from komira_http_server.connection import REQ_BUF_BYTES
from komira_http_server.routing import Router
from komira_http_server.server import HttpServer, HttpServerConfig
from komira_objectstore import InMemoryConditionalStore
from komira_runtime_paths import test_tmpdir
from komira_supervisor.proc_ffi import proc_kill

from komira_job_report_proto.job_report import JobDirective, JobPhase

from komira_job_supervisor import (
    HttpHeartbeatReporter,
    JobSupervisorConfig,
    JobSupervisorPhase,
    run_job_supervisor,
)
from komira_job_supervisor.heartbeat_auth import NoHeartbeatAuth

from komira_job_supervisor_loopback import (
    BEAT_PATH,
    CHILDREN_NONE,
    ClientLeg,
    DispatchServeLoop,
    HeartbeatReceiver,
    RECEIVER_ASSIGNED,
    RECEIVER_CANCELLED,
    RECEIVER_CANCELLING,
    RECEIVER_COMPLETED,
    RECEIVER_FAILED,
    RECEIVER_RUNNING,
    children_name,
    receiver_state_name,
    serve_while,
)


comptime _JOB_ID = "job-loopback"
comptime _INSTANCE = "instance-loopback"
comptime _TAIL_LINES = 80
# Stated, not defaulted, so (c) cannot be broken by a lower default cap.
comptime _MAX_STDERR_LINES = _TAIL_LINES * 2
# 98 bytes, so each tail line is "tail-NNN " (9) + 98 + " NNN" (4) = 111
# characters plus its newline.
comptime _PAD = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz0123456789"


struct _SupervisorLeg(ClientLeg):
    """Thread 1: one `run_job_supervisor` of `/bin/sh -c <script>` with the
    real HTTP reporter pointed at the receiver."""

    var url: String
    var script: String
    var phase: JobSupervisorPhase
    var wall_ms: Int

    def __init__(out self, var url: String, var script: String):
        self.url = url^
        self.script = script^
        self.phase = JobSupervisorPhase.running()
        self.wall_ms = -1

    def run(mut self) raises:
        var argv = List[String]()
        argv.append(String("-c"))
        argv.append(self.script)
        var cfg = JobSupervisorConfig(
            String(_JOB_ID),
            String(_INSTANCE),
            String("/bin/sh"),
            argv^,
            self.url,
            heartbeat_interval_secs=1,
            max_stderr_lines=_MAX_STDERR_LINES,
        )
        var started = now_ns()
        self.phase = run_job_supervisor[
            HttpHeartbeatReporter[NoHeartbeatAuth], InMemoryConditionalStore
        ](
            cfg^,
            HttpHeartbeatReporter[NoHeartbeatAuth](self.url, NoHeartbeatAuth()),
            None,
            None,
        )
        self.wall_ms = Int((now_ns() - started) // 1_000_000)


struct _Outcome(Movable):
    """A finished duet: the serve loop (its `dispatcher` is the receiver, read
    after the join), the phase the run returned and its wall time."""

    var loop: DispatchServeLoop[HeartbeatReceiver]
    var phase: JobSupervisorPhase
    var wall_ms: Int

    def __init__(
        out self,
        var loop: DispatchServeLoop[HeartbeatReceiver],
        phase: JobSupervisorPhase,
        wall_ms: Int,
    ):
        self.loop = loop^
        self.phase = phase
        self.wall_ms = wall_ms


def _run(var receiver: HeartbeatReceiver, var script: String) raises -> _Outcome:
    var router = Router()
    router.add(HttpMethod.post(), BEAT_PATH, 0)
    var server = HttpServer(
        config=HttpServerConfig.default_ephemeral(), router=router^
    )
    var url = String("http://127.0.0.1:") + String(server.local_port()) + String(
        BEAT_PATH
    )
    var loop = DispatchServeLoop(server^, receiver^)
    var leg = _SupervisorLeg(url^, script^)
    try:
        serve_while(loop, leg)
    except e:
        # What each side recorded, so the failure can be read off the log.
        print(
            "  the duet failed: "
            + String(e)
            + "\n  run returned "
            + String(leg.phase.wire_str())
            + " after "
            + String(leg.wall_ms)
            + " ms\n  "
            + loop.dispatcher.describe()
        )
        raise e^
    return _Outcome(loop^, leg.phase, leg.wall_ms)


def _history(r: HeartbeatReceiver) -> String:
    var s = String("")
    for i in range(len(r.history)):
        if i > 0:
            s += String(" -> ")
        s += receiver_state_name(r.history[i])
    return s^


def _assert_no_violations(r: HeartbeatReceiver) raises:
    var listed = String("")
    for v in r.violations:
        listed += String("\n    ") + v
    assert_equal(len(r.violations), 0, "receiver violations:" + listed)


def _assert_history(r: HeartbeatReceiver, expected: List[Int]) raises:
    var want = String("")
    for i in range(len(expected)):
        if i > 0:
            want += String(" -> ")
        want += receiver_state_name(expected[i])
    assert_equal(_history(r), want, "receiver state history")


def _tail_line(i: Int) -> String:
    var n = String(i)
    while n.byte_length() < 3:
        n = String("0") + n
    return String("tail-") + n + String(" ") + String(_PAD) + String(" ") + n


def _pid_file(name: String) raises -> String:
    var f = test_tmpdir() + String("/") + name
    if Path(f).exists():
        remove(f)
    return f^


def _gated_then(gate: String, order_file: String, then: String) -> String:
    """A script whose first act records whether `gate` already exists
    (`open` or `closed`) in `order_file`, then waits for `gate` (the loop
    never runs when it already exists), then runs `then`. The wait is
    bounded (1200 polls of 50 ms): if the gate never opens (beat 1 never
    reached the receiver), the job appends `gate-timeout` to `order_file`
    and exits 97, so the run ends and the case fails with the receiver's
    state printed instead of hanging."""
    return (
        String("if [ -e '")
        + gate
        + String("' ]; then echo open > '")
        + order_file
        + String("'; else echo closed > '")
        + order_file
        + String("'; fi; i=0; while [ ! -e '")
        + gate
        + String("' ]; do i=$((i + 1)); if [ \"$i\" -gt 1200 ]; then echo gate-timeout >> '")
        + order_file
        + String("'; exit 97; fi; sleep 0.05; done; ")
        + then
    )


def _writes_pid_then(pid_file: String, then: String) -> String:
    """A script that writes its pid and a newline to `pid_file`, then runs
    `then` (which `exec`s, so the pid stays the job's)."""
    return String("echo $$ > '") + pid_file + String("'; ") + then


def test_a_completed_lifecycle() raises:
    var gate = _pid_file(String("job_a.gate"))
    var order = _pid_file(String("job_a.order"))
    var res = _run(
        HeartbeatReceiver(
            String(_JOB_ID), String(_INSTANCE), first_beat_gate=gate
        ),
        _gated_then(gate, order, String("exec sleep 3")),
    )
    ref r = res.loop.dispatcher
    try:
        _check_a(r, res, order)
    except e:
        print("  test_a_completed_lifecycle: FAIL\n  " + r.describe())
        raise e^
    print("  test_a_completed_lifecycle: PASS (" + _history(r) + ")")


def _check_a(r: HeartbeatReceiver, res: _Outcome, order: String) raises:
    _assert_no_violations(r)
    assert_equal(
        r.first_beat_children,
        CHILDREN_NONE,
        "no child when beat 1 arrived: "
        + children_name(r.first_beat_children),
    )
    assert_true(r.gate_opened, "the receiver opened the gate at beat 1")
    assert_equal(
        Path(order).read_text(),
        String("open\n"),
        "the job started after the gate (beat 1's answer) was there",
    )
    var want = List[Int]()
    want.append(RECEIVER_ASSIGNED)
    want.append(RECEIVER_RUNNING)
    want.append(RECEIVER_COMPLETED)
    _assert_history(r, want)
    assert_equal(r.state, RECEIVER_COMPLETED, "final state")
    assert_true(
        res.phase == JobSupervisorPhase.completed(),
        "run returned " + String(res.phase.wire_str()),
    )
    assert_true(
        r.running_beats >= 3,
        "RUNNING beats (pre-spawn, after spawn, after an interval): "
        + String(r.running_beats),
    )
    var n = len(r.phases)
    assert_equal(r.phases[n - 1], JobPhase.JOB_PHASE_COMPLETED, "last beat")
    # Derived by the receiver from the COMPLETED phase (the wire carries no
    # COMPLETED exit code): see the header.
    assert_equal(r.exit_code.value(), Int32(0), "exit 0 maps to COMPLETED")
    assert_true(not r.cancel_requested, "no cancel was requested")


def test_b_cancel_stops_and_reaps_the_child() raises:
    var pid_file = _pid_file(String("job_b.pid"))
    var res = _run(
        HeartbeatReceiver(
            String(_JOB_ID),
            String(_INSTANCE),
            cancel_after_running_beats=3,
            pid_file=pid_file,
        ),
        _writes_pid_then(pid_file, String("exec sleep 30")),
    )
    ref r = res.loop.dispatcher
    try:
        _assert_no_violations(r)
        var want = List[Int]()
        want.append(RECEIVER_ASSIGNED)
        want.append(RECEIVER_RUNNING)
        want.append(RECEIVER_CANCELLING)
        want.append(RECEIVER_CANCELLED)
        _assert_history(r, want)
        assert_true(r.cancel_requested, "the receiver flagged cancel_requested")
        assert_true(
            res.phase == JobSupervisorPhase.cancelled(),
            "run returned " + String(res.phase.wire_str()),
        )
        assert_equal(len(r.phases), 5, "beats: RUNNING x4, CANCELLED")
        for i in range(4):
            assert_equal(
                r.phases[i], JobPhase.JOB_PHASE_RUNNING, "beat " + String(i + 1)
            )
        assert_equal(r.phases[4], JobPhase.JOB_PHASE_CANCELLED, "beat 5")
        for i in range(3):
            assert_equal(
                r.replies[i],
                JobDirective.JOB_DIRECTIVE_CONTINUE,
                "reply " + String(i + 1),
            )
        assert_equal(r.replies[3], JobDirective.JOB_DIRECTIVE_CANCEL, "reply 4")
        assert_true(r.probed_pid > 0, "the job's pid was read when CANCEL was sent")
        assert_true(r.probed_alive, "the job was alive when CANCEL was sent")
        assert_true(
            proc_kill(Int32(r.probed_pid), Int32(0)) != 0,
            "the job (pid " + String(r.probed_pid) + ") is gone after the run",
        )
        assert_true(
            res.wall_ms < 20000,
            "the job was stopped, not waited out: "
            + String(res.wall_ms)
            + " ms",
        )
    except e:
        print(
            "  test_b_cancel_stops_and_reaps_the_child: FAIL\n  "
            + r.describe()
        )
        raise e^
    print("  test_b_cancel_stops_and_reaps_the_child: PASS (" + _history(r) + ")")


def test_c_failed_with_a_long_stderr_tail() raises:
    var script = (
        String("i=0; while [ $i -lt ")
        + String(_TAIL_LINES)
        + String(" ]; do n=$(printf '%03d' $i); printf 'tail-%s %s %s\\n'")
        + String(" $n ")
        + String(_PAD)
        + String(" $n >&2; i=$((i+1)); done; exit 3")
    )
    var res = _run(
        HeartbeatReceiver(String(_JOB_ID), String(_INSTANCE)), script^
    )
    ref r = res.loop.dispatcher
    try:
        _assert_no_violations(r)
        var want = List[Int]()
        want.append(RECEIVER_ASSIGNED)
        want.append(RECEIVER_RUNNING)
        want.append(RECEIVER_FAILED)
        _assert_history(r, want)
        assert_true(
            res.phase == JobSupervisorPhase.failed(),
            "run returned " + String(res.phase.wire_str()),
        )
        assert_true(Bool(r.exit_code), "exit code on the wire")
        assert_equal(r.exit_code.value(), Int32(3), "exit code")
        assert_true(_TAIL_LINES < _MAX_STDERR_LINES, "the line cap is not under test")
        assert_true(not r.signal, "no signal")

        var expected = String("")
        for i in range(_TAIL_LINES):
            expected += _tail_line(i) + String("\n")
        var got = String("")
        for line in r.stderr_tail:
            got += line + String("\n")
        assert_true(
            expected.byte_length() > 4096,
            "the tail is longer than 4096 bytes: " + String(expected.byte_length()),
        )
        assert_equal(
            got.byte_length(), expected.byte_length(), "stderr tail byte length"
        )
        assert_equal(len(r.stderr_tail), _TAIL_LINES, "stderr tail lines")
        assert_true(got == expected, "stderr tail bytes equal")
        assert_true(
            r.terminal_body_len > REQ_BUF_BYTES,
            "the FAILED beat ("
            + String(r.terminal_body_len)
            + " bytes) exceeds the server's first recv ("
            + String(REQ_BUF_BYTES)
            + " bytes), so it was reassembled across recvs",
        )
        print(
            "  test_c_failed_with_a_long_stderr_tail: PASS ("
            + String(got.byte_length())
            + " tail bytes, a "
            + String(r.terminal_body_len)
            + "-byte beat)"
        )
    except e:
        print(
            "  test_c_failed_with_a_long_stderr_tail: FAIL\n  " + r.describe()
        )
        raise e^


def test_control_an_unknown_directive_does_not_stop_the_job() raises:
    var res = _run(
        HeartbeatReceiver(
            String(_JOB_ID), String(_INSTANCE), continue_directive=7
        ),
        String("sleep 3"),
    )
    ref r = res.loop.dispatcher
    try:
        _assert_no_violations(r)
        assert_true(
            res.phase == JobSupervisorPhase.completed(),
            "an unknown directive is not CANCEL: the job ran to COMPLETED, got "
            + String(res.phase.wire_str()),
        )
        assert_equal(r.state, RECEIVER_COMPLETED, "final state")
        assert_true(
            r.running_beats >= 3, "beats were answered while the job ran"
        )
        for i in range(len(r.replies)):
            assert_equal(r.replies[i], 7, "every reply is directive 7")
    except e:
        print(
            "  test_control_an_unknown_directive_does_not_stop_the_job: FAIL"
            + "\n  "
            + r.describe()
        )
        raise e^
    print("  test_control_an_unknown_directive_does_not_stop_the_job: PASS")


def main() raises:
    print("test_job_supervisor_heartbeat_loopback:")
    test_a_completed_lifecycle()
    test_b_cancel_stops_and_reaps_the_child()
    test_c_failed_with_a_long_stderr_tail()
    test_control_an_unknown_directive_does_not_stop_the_job()
    print("test_job_supervisor_heartbeat_loopback: ALL PASS")
