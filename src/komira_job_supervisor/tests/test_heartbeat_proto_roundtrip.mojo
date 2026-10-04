# =============================================================================
# komira_job_supervisor/tests/test_heartbeat_proto_roundtrip.mojo
# =============================================================================
#
# The encode->decode IDENTITY gate for the generated supervisor.proto messages
# the supervisor speaks, through the same `komira_proto_codec` protobuf-binary
# entry points (`encode_proto` / `decode_proto`) it uses on the wire: the
# generated `SupervisorHeartbeat` / `HeartbeatResponse` / `FailureReport`
# survive a round trip field for field (encode and decode are independent
# code paths, so a round trip is a real correctness signal).
#
# Coverage:
#   * SupervisorHeartbeat with ALL fields set (incl. optional progress/message
#     + the nested FailureReport + the JobPhase enum) -> identity.
#   * SupervisorHeartbeat with the optionals ABSENT -> they decode back to None.
#   * HeartbeatResponse(cancel=true) and (cancel=false) -> identity.
#   * FailureReport (the nested forensics message) on its own -> identity,
#     including the repeated `stderr_tail`.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_proto_codec import encode_proto, decode_proto

# The generated supervisor.proto messages (komira_supervisor_proto).
from komira_supervisor_proto.supervisor import (
    SupervisorHeartbeat,
    HeartbeatResponse,
    FailureReport,
    JobPhase,
)


def test_supervisor_heartbeat_all_fields_roundtrip() raises:
    """A SupervisorHeartbeat with every field set — required job_id/phase/
    pod_name + optional progress/message + a nested FailureReport — survives
    encode->decode identity over the protobuf-binary backend."""
    var stderr_tail = List[String]()
    stderr_tail.append(String("thread panicked at boom"))
    stderr_tail.append(String("note: run with RUST_BACKTRACE=1"))
    var failure = FailureReport(
        Optional[Int32](Int32(7)),  # exit_code
        Optional[Int32](Int32(9)),  # signal
        stderr_tail^,  # stderr_tail (repeated)
        Optional[String](String("panicked at boom")),  # panic_message
        Optional[String](String("child exited non-zero")),  # reason
        Optional[UInt64](UInt64(123456789)),  # last_record_offset
    )

    var hb = SupervisorHeartbeat(
        String("nightly-report"),  # job_id (the supervisor's --job-name)
        JobPhase(JobPhase.JOB_PHASE_FAILED),  # phase
        String("worker-7"),  # pod_name (the supervisor's --instance-name)
        Optional[UInt32](UInt32(42)),  # progress
        Optional[String](String("processing batch 7")),  # message
        Optional[FailureReport](failure^),  # failure
        None,  # node_id (not a job supervisor's field: absent)
        None,  # load (absent)
        List[UInt32](),  # owned_partitions (empty)
        None,  # advertised_host (absent)
        None,  # advertised_port (absent)
    )

    var bytes = encode_proto[SupervisorHeartbeat](hb)
    assert_true(len(bytes) > 0, "non-empty wire bytes")
    var back = decode_proto[SupervisorHeartbeat](bytes^)

    assert_equal(
        back.job_id,
        String("nightly-report"),
        "job_id",
    )
    assert_equal(back.phase.value, JobPhase.JOB_PHASE_FAILED, "phase enum")
    assert_equal(back.pod_name, String("worker-7"), "pod_name")
    assert_true(Bool(back.progress), "progress present")
    assert_equal(back.progress.value(), UInt32(42), "progress value")
    assert_true(Bool(back.message), "message present")
    assert_equal(
        back.message.value(), String("processing batch 7"), "message value"
    )

    assert_true(Bool(back.failure), "failure present")
    ref fr = back.failure.value()
    assert_true(Bool(fr.exit_code), "exit_code present")
    assert_equal(fr.exit_code.value(), Int32(7), "exit_code value")
    assert_true(Bool(fr.signal), "signal present")
    assert_equal(fr.signal.value(), Int32(9), "signal value")
    assert_equal(len(fr.stderr_tail), 2, "two stderr_tail lines")
    assert_equal(
        fr.stderr_tail[0], String("thread panicked at boom"), "stderr_tail[0]"
    )
    assert_equal(
        fr.stderr_tail[1],
        String("note: run with RUST_BACKTRACE=1"),
        "stderr_tail[1]",
    )
    assert_true(Bool(fr.panic_message), "panic_message present")
    assert_equal(
        fr.panic_message.value(), String("panicked at boom"), "panic_message"
    )
    assert_true(Bool(fr.reason), "reason present")
    assert_equal(
        fr.reason.value(), String("child exited non-zero"), "reason"
    )
    assert_true(Bool(fr.last_record_offset), "last_record_offset present")
    assert_equal(
        fr.last_record_offset.value(),
        UInt64(123456789),
        "last_record_offset value",
    )
    print("  test_supervisor_heartbeat_all_fields_roundtrip: PASS")


def test_supervisor_heartbeat_optionals_absent_roundtrip() raises:
    """A RUNNING heartbeat with NO optional fields — progress/message/failure
    decode back to None; required job_id/phase/pod_name still set."""
    var hb = SupervisorHeartbeat(
        String("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        JobPhase(JobPhase.JOB_PHASE_RUNNING),
        String("worker-xyz"),
        None,  # progress
        None,  # message
        None,  # failure
        None,  # node_id
        None,  # load
        List[UInt32](),  # owned_partitions
        None,  # advertised_host
        None,  # advertised_port
    )
    var bytes = encode_proto[SupervisorHeartbeat](hb)
    var back = decode_proto[SupervisorHeartbeat](bytes^)

    assert_equal(
        back.job_id, String("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), "job_id"
    )
    assert_equal(back.phase.value, JobPhase.JOB_PHASE_RUNNING, "phase RUNNING")
    assert_equal(back.pod_name, String("worker-xyz"), "pod_name")
    assert_false(Bool(back.progress), "absent progress -> None")
    assert_false(Bool(back.message), "absent message -> None")
    assert_false(Bool(back.failure), "absent failure -> None")
    # A job supervisor's heartbeat carries no node identity / load / partitions.
    assert_false(Bool(back.node_id), "absent node_id -> None")
    assert_false(Bool(back.load), "absent load -> None")
    assert_equal(len(back.owned_partitions), 0, "empty owned_partitions")
    print("  test_supervisor_heartbeat_optionals_absent_roundtrip: PASS")


def test_heartbeat_response_roundtrip() raises:
    """HeartbeatResponse(cancel) round-trips for both true and false, the
    other fields empty (the shape a job supervisor reads)."""
    var yes = HeartbeatResponse(True, List[UInt32](), None, None, List[Int64]())
    var yb = encode_proto[HeartbeatResponse](yes)
    var yback = decode_proto[HeartbeatResponse](yb^)
    assert_true(yback.cancel, "cancel=true round-trips")
    assert_equal(len(yback.assigned_partitions), 0, "empty assigned_partitions")
    assert_false(Bool(yback.cluster), "absent cluster -> None")
    assert_false(Bool(yback.broker_cluster), "absent broker_cluster -> None")
    assert_equal(
        len(yback.assigned_generations), 0, "empty assigned_generations"
    )

    var no = HeartbeatResponse(False, List[UInt32](), None, None, List[Int64]())
    var nb = encode_proto[HeartbeatResponse](no)
    var nback = decode_proto[HeartbeatResponse](nb^)
    assert_false(nback.cancel, "cancel=false round-trips")
    print("  test_heartbeat_response_roundtrip: PASS")


def test_failure_report_standalone_roundtrip() raises:
    """The nested FailureReport message round-trips on its own (empty
    stderr_tail + a subset of the optionals)."""
    var fr = FailureReport(
        Optional[Int32](Int32(-1)),  # exit_code (killed by signal => -1 style)
        None,  # signal
        List[String](),  # stderr_tail (empty)
        None,  # panic_message
        Optional[String](String("oom")),  # reason
        None,  # last_record_offset
    )
    var bytes = encode_proto[FailureReport](fr)
    var back = decode_proto[FailureReport](bytes^)
    assert_true(Bool(back.exit_code), "exit_code present")
    assert_equal(back.exit_code.value(), Int32(-1), "exit_code value")
    assert_false(Bool(back.signal), "signal absent")
    assert_equal(len(back.stderr_tail), 0, "empty stderr_tail")
    assert_false(Bool(back.panic_message), "panic_message absent")
    assert_true(Bool(back.reason), "reason present")
    assert_equal(back.reason.value(), String("oom"), "reason value")
    assert_false(Bool(back.last_record_offset), "last_record_offset absent")
    print("  test_failure_report_standalone_roundtrip: PASS")


def main() raises:
    print("test_heartbeat_proto_roundtrip: heartbeat proto-binary gate")
    test_supervisor_heartbeat_all_fields_roundtrip()
    test_supervisor_heartbeat_optionals_absent_roundtrip()
    test_heartbeat_response_roundtrip()
    test_failure_report_standalone_roundtrip()
    print("ALL HEARTBEAT PROTO-BINARY ROUND-TRIP TESTS PASSED")
