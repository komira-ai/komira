# =============================================================================
# komira_job_supervisor/tests/test_heartbeat_proto_roundtrip.mojo
#   The supervisor's heartbeat value, encoded by `encode_heartbeat`, decodes
#   as the komira.job_report.v1 `JobHeartbeat` it should be.
# =============================================================================
#
# The wire messages' own round trip is welded to komira_job_report_proto.
# This test pins the supervisor's PROJECTION onto them: each of the four
# phases the supervisor reports lands on its wire number, the failure
# forensics land field for field in `JobFailure`, and an absent optional stays
# absent on the wire.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_proto

from komira_job_report_proto.job_report import JobHeartbeat, JobPhase

from komira_job_supervisor.heartbeat_client import (
    SupervisorHeartbeat,
    encode_heartbeat,
)
from komira_job_supervisor.job_supervisor_state import (
    FailureReport,
    JobSupervisorPhase,
)


def _decode(hb: SupervisorHeartbeat) raises -> JobHeartbeat:
    return decode_proto[JobHeartbeat](encode_heartbeat(hb))


def _bare(phase: JobSupervisorPhase) -> SupervisorHeartbeat:
    return SupervisorHeartbeat(
        String("j"),
        phase,
        String("i"),
        Optional[Int32](),
        Optional[String](),
        Optional[FailureReport](),
    )


def test_each_phase_lands_on_its_wire_number() raises:
    assert_equal(
        _decode(_bare(JobSupervisorPhase.running())).phase.value,
        JobPhase.JOB_PHASE_RUNNING,
        "RUNNING",
    )
    assert_equal(
        _decode(_bare(JobSupervisorPhase.completed())).phase.value,
        JobPhase.JOB_PHASE_COMPLETED,
        "COMPLETED",
    )
    assert_equal(
        _decode(_bare(JobSupervisorPhase.failed())).phase.value,
        JobPhase.JOB_PHASE_FAILED,
        "FAILED",
    )
    assert_equal(
        _decode(_bare(JobSupervisorPhase.cancelled())).phase.value,
        JobPhase.JOB_PHASE_CANCELLED,
        "CANCELLED",
    )
    print("  test_each_phase_lands_on_its_wire_number: PASS")


def test_a_failed_beat_carries_its_forensics() raises:
    var tail = List[String]()
    tail.append(String("thread panicked at boom"))
    tail.append(String("note: run with RUST_BACKTRACE=1"))
    var hb = SupervisorHeartbeat(
        String("nightly-report"),
        JobSupervisorPhase.failed(),
        String("worker-7"),
        Optional[Int32](Int32(42)),
        Optional[String](String("processing batch 7")),
        Optional[FailureReport](
            FailureReport(
                Optional[Int32](Int32(7)),
                Optional[Int32](Int32(9)),
                tail^,
                Optional[String](String("panicked at boom")),
            )
        ),
    )
    var back = _decode(hb)
    assert_equal(back.job_id, String("nightly-report"), "job_id")
    assert_equal(back.instance_name, String("worker-7"), "instance_name")
    assert_equal(back.progress.value(), UInt32(42), "progress")
    assert_equal(back.message.value(), String("processing batch 7"), "message")
    assert_true(Bool(back.failure), "failure present")
    ref fr = back.failure.value()
    assert_equal(fr.exit_code.value(), Int32(7), "exit_code")
    assert_equal(fr.signal.value(), Int32(9), "signal")
    assert_equal(len(fr.stderr_tail), 2, "two stderr_tail lines")
    assert_equal(fr.stderr_tail[0], String("thread panicked at boom"), "tail[0]")
    assert_equal(
        fr.stderr_tail[1], String("note: run with RUST_BACKTRACE=1"), "tail[1]"
    )
    assert_equal(fr.panic_message.value(), String("panicked at boom"), "panic")
    print("  test_a_failed_beat_carries_its_forensics: PASS")


def test_absent_optionals_stay_absent() raises:
    var back = _decode(_bare(JobSupervisorPhase.running()))
    assert_equal(back.job_id, String("j"), "job_id")
    assert_equal(back.instance_name, String("i"), "instance_name")
    assert_false(Bool(back.progress), "absent progress -> None")
    assert_false(Bool(back.message), "absent message -> None")
    assert_false(Bool(back.failure), "absent failure -> None")

    # A failure with only a signal: the absent exit code and panic stay absent.
    var hb = SupervisorHeartbeat(
        String("j"),
        JobSupervisorPhase.failed(),
        String(""),
        Optional[Int32](),
        Optional[String](),
        Optional[FailureReport](
            FailureReport(
                Optional[Int32](),
                Optional[Int32](Int32(15)),
                List[String](),
                Optional[String](),
            )
        ),
    )
    var f = _decode(hb)
    ref fr = f.failure.value()
    assert_false(Bool(fr.exit_code), "absent exit_code")
    assert_equal(fr.signal.value(), Int32(15), "signal")
    assert_equal(len(fr.stderr_tail), 0, "empty stderr_tail")
    assert_false(Bool(fr.panic_message), "absent panic_message")
    print("  test_absent_optionals_stay_absent: PASS")


def main() raises:
    print("test_heartbeat_proto_roundtrip:")
    test_each_phase_lands_on_its_wire_number()
    test_a_failed_beat_carries_its_forensics()
    test_absent_optionals_stay_absent()
    print("test_heartbeat_proto_roundtrip: ALL PASS")
