# =============================================================================
# test_heartbeat_receiver_rules.mojo -- the receiver's state machine, beat by
# beat, without a socket
# =============================================================================
#
# The loopback test asserts "no violation recorded" after every run. That
# assertion is only worth something if each rule can fire, so each rule is
# fed here a beat that breaks it (encoded `JobHeartbeat` bytes straight into
# `HeartbeatReceiver.receive`) and must record exactly one violation:
#
#   a RUNNING beat after CANCEL was sent; CANCELLED without a CANCEL; FAILED
#   without a JobFailure; RUNNING or COMPLETED with one; a terminal beat
#   before any RUNNING beat; a beat after the terminal one; another job's id;
#   another instance's name; a phase outside the enum, after a RUNNING beat
#   and as the FIRST beat (named as a phase, not as an early terminal beat); a
#   body that does not decode (answered REPLY_REFUSED); a pid probe whose file
#   is missing or holds no complete line; a first beat that arrives while this
#   process already has a child (the first-beat probe; a real child is
#   spawned for it, and the CONTROL without one records nothing and still
#   opens the gate); a first beat that arrives while this process has an
#   exited, unreaped child (recorded, and the child is left for its owner's
#   waitpid); a request that is not `POST /beat`.
#
# The legal paths are walked too: the cancel path (CANCEL answers the beat
# AFTER the one that flagged it) and a job that exits while CANCELLING.
# =============================================================================

from std.testing import assert_equal, assert_true

from std.os import remove
from std.pathlib import Path
from std.time import sleep

from komira_http_core.codec import HttpMethod
from komira_proto_codec import encode_proto
from komira_runtime_paths import test_tmpdir
from komira_supervisor import ChildSpec, Supervisor
from komira_supervisor.proc_ffi import proc_kill, proc_probe_children

from komira_job_report_proto.job_report import (
    JobDirective,
    JobFailure,
    JobHeartbeat,
    JobPhase,
)

from komira_job_supervisor_loopback import (
    CHILDREN_EXITED,
    CHILDREN_NONE,
    CHILDREN_NOT_PROBED,
    CHILDREN_RUNNING,
    HeartbeatReceiver,
    RECEIVER_CANCELLED,
    RECEIVER_CANCELLING,
    RECEIVER_COMPLETED,
    RECEIVER_FAILED,
    RECEIVER_RUNNING,
    REPLY_REFUSED,
)


comptime _JOB = "job-rules"
comptime _INST = "instance-rules"
comptime _CONTINUE = JobDirective.JOB_DIRECTIVE_CONTINUE
comptime _CANCEL = JobDirective.JOB_DIRECTIVE_CANCEL


def _rx(cancel_after: Int = 0) -> HeartbeatReceiver:
    return HeartbeatReceiver(
        String(_JOB), String(_INST), cancel_after_running_beats=cancel_after
    )


def _failure(exit_code: Int32) -> JobFailure:
    var tail = List[String]()
    tail.append(String("first"))
    tail.append(String("last"))
    return JobFailure(Optional[Int32](exit_code), None, tail^, None)


def _beat(
    phase: Int,
    var failure: Optional[JobFailure] = None,
    job: String = String(_JOB),
    inst: String = String(_INST),
) raises -> List[UInt8]:
    return encode_proto[JobHeartbeat](
        JobHeartbeat(
            String(job), JobPhase(phase), String(inst), None, None, failure^
        )
    )


def _running() raises -> List[UInt8]:
    return _beat(JobPhase.JOB_PHASE_RUNNING)


def _one_violation(r: HeartbeatReceiver, contains: String) raises:
    assert_equal(len(r.violations), 1, "exactly one violation")
    assert_true(
        r.violations[0].find(contains) >= 0,
        "violation names '" + contains + "': " + r.violations[0],
    )


def test_the_cancel_path_answers_the_beat_after_the_flag() raises:
    var r = _rx(cancel_after=2)
    assert_equal(r.receive(_running()), _CONTINUE, "beat 1")
    assert_true(not r.cancel_requested, "not flagged after beat 1")
    assert_equal(r.receive(_running()), _CONTINUE, "beat 2 flags, answers CONTINUE")
    assert_true(r.cancel_requested, "flagged after beat 2")
    assert_equal(r.receive(_running()), _CANCEL, "beat 3 is answered CANCEL")
    assert_equal(r.state, RECEIVER_CANCELLING, "CANCELLING")
    _ = r.receive(_beat(JobPhase.JOB_PHASE_CANCELLED))
    assert_equal(r.state, RECEIVER_CANCELLED, "CANCELLED")
    assert_equal(len(r.violations), 0, "no violation")
    assert_equal(len(r.history), 4, "ASSIGNED RUNNING CANCELLING CANCELLED")
    print("  test_the_cancel_path_answers_the_beat_after_the_flag: PASS")


def test_a_job_may_exit_while_cancelling() raises:
    var r = _rx(cancel_after=1)
    _ = r.receive(_running())
    assert_equal(r.receive(_running()), _CANCEL, "beat 2 is answered CANCEL")
    _ = r.receive(_beat(JobPhase.JOB_PHASE_FAILED, Optional[JobFailure](_failure(Int32(1)))))
    assert_equal(r.state, RECEIVER_FAILED, "FAILED from CANCELLING")
    assert_equal(len(r.violations), 0, "no violation")
    assert_equal(r.exit_code.value(), Int32(1), "exit code")
    assert_equal(len(r.stderr_tail), 2, "tail")
    print("  test_a_job_may_exit_while_cancelling: PASS")


def test_running_after_cancel_is_a_violation() raises:
    var r = _rx(cancel_after=1)
    _ = r.receive(_running())
    _ = r.receive(_running())
    _ = r.receive(_running())
    _one_violation(r, String("RUNNING after CANCEL"))
    print("  test_running_after_cancel_is_a_violation: PASS")


def test_cancelled_without_cancel_is_a_violation() raises:
    var r = _rx()
    _ = r.receive(_running())
    _ = r.receive(_beat(JobPhase.JOB_PHASE_CANCELLED))
    _one_violation(r, String("CANCELLED without a CANCEL"))
    print("  test_cancelled_without_cancel_is_a_violation: PASS")


def test_failed_without_failure_is_a_violation() raises:
    var r = _rx()
    _ = r.receive(_running())
    _ = r.receive(_beat(JobPhase.JOB_PHASE_FAILED))
    _one_violation(r, String("FAILED without a JobFailure"))
    assert_true(not r.exit_code, "no exit code invented")
    print("  test_failed_without_failure_is_a_violation: PASS")


def test_completed_with_failure_is_a_violation() raises:
    var r = _rx()
    _ = r.receive(_running())
    _ = r.receive(
        _beat(JobPhase.JOB_PHASE_COMPLETED, Optional[JobFailure](_failure(Int32(2))))
    )
    _one_violation(r, String("COMPLETED carries a JobFailure"))
    print("  test_completed_with_failure_is_a_violation: PASS")


def test_terminal_before_running_is_a_violation() raises:
    var r = _rx()
    _ = r.receive(_beat(JobPhase.JOB_PHASE_COMPLETED))
    _one_violation(r, String("before any RUNNING"))
    print("  test_terminal_before_running_is_a_violation: PASS")


def test_a_beat_after_terminal_is_a_violation() raises:
    var r = _rx()
    _ = r.receive(_running())
    _ = r.receive(_beat(JobPhase.JOB_PHASE_COMPLETED))
    assert_equal(r.state, RECEIVER_COMPLETED, "COMPLETED")
    assert_equal(r.exit_code.value(), Int32(0), "COMPLETED records exit 0")
    _ = r.receive(_running())
    _one_violation(r, String("after the terminal state COMPLETED"))
    assert_equal(r.state, RECEIVER_COMPLETED, "still COMPLETED")
    print("  test_a_beat_after_terminal_is_a_violation: PASS")


def test_another_job_or_instance_is_a_violation() raises:
    var r = _rx()
    _ = r.receive(_beat(JobPhase.JOB_PHASE_RUNNING, None, String("other-job")))
    _one_violation(r, String("job_id other-job"))
    var r2 = _rx()
    _ = r2.receive(
        _beat(JobPhase.JOB_PHASE_RUNNING, None, String(_JOB), String("other"))
    )
    _one_violation(r2, String("instance_name other"))
    print("  test_another_job_or_instance_is_a_violation: PASS")


def test_a_phase_outside_the_enum_is_a_violation() raises:
    var r = _rx()
    _ = r.receive(_running())
    _ = r.receive(_beat(9))
    _one_violation(r, String("phase 9"))
    assert_equal(r.state, RECEIVER_RUNNING, "state unchanged")
    print("  test_a_phase_outside_the_enum_is_a_violation: PASS")


def test_an_undecodable_body_is_refused() raises:
    var r = _rx()
    # Field 1 (a string) declares 5 bytes and carries 1.
    var bad = List[UInt8]()
    bad.append(UInt8(0x0A))
    bad.append(UInt8(0x05))
    bad.append(UInt8(0x41))
    assert_equal(r.receive(bad^), REPLY_REFUSED, "refused")
    _one_violation(r, String("undecodable"))
    print("  test_an_undecodable_body_is_refused: PASS")


def test_a_missing_pid_file_is_a_violation() raises:
    var r = HeartbeatReceiver(
        String(_JOB),
        String(_INST),
        cancel_after_running_beats=1,
        pid_file=String("no/such/dir/job.pid"),
        pid_wait_ms=50,
    )
    _ = r.receive(_running())
    assert_equal(r.receive(_running()), _CANCEL, "CANCEL is still sent")
    _one_violation(r, String("pid probe"))
    assert_equal(r.probed_pid, -1, "no pid invented")
    print("  test_a_missing_pid_file_is_a_violation: PASS")


def test_running_with_failure_is_a_violation() raises:
    var r = _rx()
    _ = r.receive(
        _beat(JobPhase.JOB_PHASE_RUNNING, Optional[JobFailure](_failure(Int32(1))))
    )
    _one_violation(r, String("RUNNING carries a JobFailure"))
    print("  test_running_with_failure_is_a_violation: PASS")


def test_a_first_beat_outside_the_enum_is_named_as_a_phase() raises:
    var r = _rx()
    _ = r.receive(_beat(9))
    _one_violation(r, String("phase 9"))
    assert_true(
        r.violations[0].find(String("before any RUNNING")) < 0,
        "not an early terminal beat: " + r.violations[0],
    )
    var r0 = _rx()
    _ = r0.receive(_beat(JobPhase.JOB_PHASE_UNSPECIFIED))
    _one_violation(r0, String("phase 0"))
    print("  test_a_first_beat_outside_the_enum_is_named_as_a_phase: PASS")


def _scratch_file(name: String, content: String) raises -> String:
    var f = test_tmpdir() + String("/") + name
    if Path(f).exists():
        remove(f)
    if content.byte_length() > 0:
        Path(f).write_text(content)
    return f^


def test_a_half_written_pid_file_is_a_violation() raises:
    var f = _scratch_file(String("rules_half.pid"), String("123"))
    var r = HeartbeatReceiver(
        String(_JOB),
        String(_INST),
        cancel_after_running_beats=1,
        pid_file=f,
        pid_wait_ms=50,
    )
    _ = r.receive(_running())
    assert_equal(r.receive(_running()), _CANCEL, "CANCEL is still sent")
    _one_violation(r, String("no complete pid line"))
    assert_equal(r.probed_pid, -1, "no pid read from a partial line")
    print("  test_a_half_written_pid_file_is_a_violation: PASS")


def test_the_first_beat_probe_fires_when_a_child_already_exists() raises:
    # CONTROL first, while this process has no child: nothing recorded, the
    # gate is opened, and only the FIRST beat probes.
    var g = _scratch_file(String("rules_gate_control"), String(""))
    var r0 = HeartbeatReceiver(
        String(_JOB), String(_INST), first_beat_gate=g
    )
    assert_equal(r0.first_beat_children, CHILDREN_NOT_PROBED, "not yet")
    _ = r0.receive(_running())
    assert_equal(len(r0.violations), 0, "CONTROL: no child, no violation")
    assert_equal(r0.first_beat_children, CHILDREN_NONE, "CONTROL: no child")
    assert_true(r0.gate_opened, "CONTROL: the gate was opened")
    assert_true(Path(g).exists(), "CONTROL: the gate file exists")

    # A live child of this process when beat 1 arrives: the shape of a
    # supervisor that spawned before its first beat.
    var f = _scratch_file(String("rules_gate_child"), String(""))
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("exec sleep 30")))
    assert_true(pid > Int32(0), "spawned a child: " + String(pid))
    var r = HeartbeatReceiver(
        String(_JOB), String(_INST), first_beat_gate=f
    )
    _ = r.receive(_running())
    _ = r.receive(_running())
    var still_alive = proc_kill(pid, Int32(0)) == 0
    _ = sup.terminate(1000)
    sup.close()
    _one_violation(
        r, String("the first beat arrived after the job was spawned")
    )
    assert_equal(r.first_beat_children, CHILDREN_RUNNING, "a running child")
    assert_true(still_alive, "the probe did not reap the running child")
    assert_true(r.gate_opened, "the gate is opened even on a violation")
    print("  test_the_first_beat_probe_fires_when_a_child_already_exists: PASS")


def _await_exited_unreaped(pid: Int32) raises:
    """Poll komira_supervisor's non-reaping child probe 5 ms apart, up to 1000
    times, until it names `pid` as an exited, unreaped child. (An exit
    notification is not enough: on XNU EVFILT_PROC NOTE_EXIT may fire before
    the child is a waitable zombie.)"""
    var polls = 0
    while proc_probe_children().exited_pid != pid:
        polls += 1
        assert_true(
            polls < 1000,
            "child "
            + String(pid)
            + " not seen as exited after 1000 probes 5 ms apart",
        )
        sleep(Float64(0.005))


def test_the_first_beat_probe_leaves_an_exited_child_to_its_owner() raises:
    # An exited, unreaped child of this process when beat 1 arrives. The
    # probe must see it and must NOT reap it: the child belongs to whoever
    # spawned it, and that owner's waitpid(pid) still has to collect it.
    var f = _scratch_file(String("rules_gate_exited"), String(""))
    var sup = Supervisor()
    var pid = sup.spawn(ChildSpec.shell(String("exit 7")))
    assert_true(pid > Int32(0), "spawned a child: " + String(pid))
    _ = sup.drain_pipe(sup.stdout_fd())
    _ = sup.drain_pipe(sup.stderr_fd())
    _await_exited_unreaped(pid)
    var r = HeartbeatReceiver(
        String(_JOB), String(_INST), first_beat_gate=f
    )
    _ = r.receive(_running())
    var owner = sup.try_wait()
    if not owner.collected:
        _ = sup.terminate(1000)
    sup.close()
    _one_violation(
        r, String("the first beat arrived after the job was spawned")
    )
    assert_equal(r.first_beat_children, CHILDREN_EXITED, "an exited child")
    assert_true(
        owner.collected,
        "the owner's waitpid collected the child after the probe (error "
        + String(owner.error)
        + ")",
    )
    assert_equal(owner.exit_code, Int32(7), "the owner saw exit code 7")
    print(
        "  test_the_first_beat_probe_leaves_an_exited_child_to_its_owner: PASS"
    )


def test_only_post_beat_is_admitted() raises:
    var r = _rx()
    assert_true(r.admit(HttpMethod.post(), String("/beat")), "POST /beat")
    assert_equal(len(r.violations), 0, "POST /beat is no violation")
    assert_true(not r.admit(HttpMethod.get(), String("/beat")), "GET refused")
    _one_violation(r, String("request GET /beat"))
    var r2 = _rx()
    assert_true(
        not r2.admit(HttpMethod.post(), String("/other")), "path refused"
    )
    _one_violation(r2, String("request POST /other"))
    print("  test_only_post_beat_is_admitted: PASS")


def main() raises:
    print("test_heartbeat_receiver_rules:")
    test_the_cancel_path_answers_the_beat_after_the_flag()
    test_a_job_may_exit_while_cancelling()
    test_running_after_cancel_is_a_violation()
    test_cancelled_without_cancel_is_a_violation()
    test_failed_without_failure_is_a_violation()
    test_completed_with_failure_is_a_violation()
    test_terminal_before_running_is_a_violation()
    test_a_beat_after_terminal_is_a_violation()
    test_another_job_or_instance_is_a_violation()
    test_a_phase_outside_the_enum_is_a_violation()
    test_an_undecodable_body_is_refused()
    test_a_missing_pid_file_is_a_violation()
    test_running_with_failure_is_a_violation()
    test_a_first_beat_outside_the_enum_is_named_as_a_phase()
    test_a_half_written_pid_file_is_a_violation()
    test_the_first_beat_probe_fires_when_a_child_already_exists()
    test_the_first_beat_probe_leaves_an_exited_child_to_its_owner()
    test_only_post_beat_is_admitted()
    print("test_heartbeat_receiver_rules: ALL PASS")
