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
#   is missing or holds no complete line; a first beat whose pid file already
#   exists (the first-beat probe); a request that is not `POST /beat`.
#
# The legal paths are walked too: the cancel path (CANCEL answers the beat
# AFTER the one that flagged it) and a job that exits while CANCELLING.
# =============================================================================

from std.testing import assert_equal, assert_true

from std.os import remove
from std.pathlib import Path

from komira_http_core.codec import HttpMethod
from komira_proto_codec import encode_proto
from komira_runtime_paths import test_tmpdir

from komira_job_report_proto.job_report import (
    JobDirective,
    JobFailure,
    JobHeartbeat,
    JobPhase,
)

from komira_job_supervisor_loopback import (
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


def test_the_first_beat_probe_fires_when_the_job_already_runs() raises:
    var f = _scratch_file(String("rules_first.pid"), String("1\n"))
    var r = HeartbeatReceiver(
        String(_JOB), String(_INST), pid_file=f, first_beat_wait_ms=50
    )
    _ = r.receive(_running())
    _ = r.receive(_running())
    _one_violation(r, String("the first beat arrived after the job started"))
    # CONTROL: no file, the probe waits and records nothing.
    var g = _scratch_file(String("rules_first_absent.pid"), String(""))
    var r2 = HeartbeatReceiver(
        String(_JOB), String(_INST), pid_file=g, first_beat_wait_ms=50
    )
    _ = r2.receive(_running())
    assert_equal(len(r2.violations), 0, "CONTROL: no file, no violation")
    print("  test_the_first_beat_probe_fires_when_the_job_already_runs: PASS")


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
    test_the_first_beat_probe_fires_when_the_job_already_runs()
    test_only_post_beat_is_admitted()
    print("test_heartbeat_receiver_rules: ALL PASS")
