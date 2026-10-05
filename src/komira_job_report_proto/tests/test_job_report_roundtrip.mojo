# =============================================================================
# komira_job_report_proto/tests/test_job_report_roundtrip.mojo
#   Every job report message survives protobuf-binary encode -> decode.
# =============================================================================
#
# Encode and decode are independent code paths in komira_proto_codec, so a
# field that comes back with the value it went in with is a real signal. Each
# message is round-tripped with every field set, and again with every
# optional field absent (it must come back absent, not as a zero).
#
# A round trip cannot see a renumbering (both ends use the same constants),
# and a peer built from an older copy of the file can. So the enum numbers
# and two messages' exact bytes are pinned too.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_proto, encode_proto

from komira_job_report_proto.job_report import (
    JobDirective,
    JobFailure,
    JobHeartbeat,
    JobHeartbeatReply,
    JobPhase,
)


def _failure() -> JobFailure:
    var tail = List[String]()
    tail.append(String("thread panicked at boom"))
    tail.append(String("note: run with RUST_BACKTRACE=1"))
    return JobFailure(
        Optional[Int32](Int32(7)),
        Optional[Int32](Int32(9)),
        tail^,
        Optional[String](String("panicked at boom")),
    )


def test_a_heartbeat_with_every_field_set() raises:
    var hb = JobHeartbeat(
        String("nightly-report"),
        JobPhase(JobPhase.JOB_PHASE_FAILED),
        String("worker-7"),
        Optional[UInt32](UInt32(42)),
        Optional[String](String("processing batch 7")),
        Optional[JobFailure](_failure()),
    )
    var bytes = encode_proto[JobHeartbeat](hb)
    assert_true(len(bytes) > 0, "non-empty wire bytes")
    var back = decode_proto[JobHeartbeat](bytes^)

    assert_equal(back.job_id, String("nightly-report"), "job_id")
    assert_equal(back.phase.value, JobPhase.JOB_PHASE_FAILED, "phase")
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
    print("  test_a_heartbeat_with_every_field_set: PASS")


def test_a_heartbeat_with_the_optionals_absent() raises:
    var hb = JobHeartbeat(
        String("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
        JobPhase(JobPhase.JOB_PHASE_RUNNING),
        String(""),
        None,
        None,
        None,
    )
    var back = decode_proto[JobHeartbeat](encode_proto[JobHeartbeat](hb))
    assert_equal(
        back.job_id, String("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"), "job_id"
    )
    assert_equal(back.phase.value, JobPhase.JOB_PHASE_RUNNING, "phase")
    assert_equal(back.instance_name, String(""), "empty instance_name")
    assert_false(Bool(back.progress), "absent progress -> None")
    assert_false(Bool(back.message), "absent message -> None")
    assert_false(Bool(back.failure), "absent failure -> None")
    # CONTROL: a present zero is not the same as absent.
    var zero = JobHeartbeat(
        String("j"),
        JobPhase(JobPhase.JOB_PHASE_RUNNING),
        String(""),
        Optional[UInt32](UInt32(0)),
        Optional[String](String("")),
        None,
    )
    var zback = decode_proto[JobHeartbeat](encode_proto[JobHeartbeat](zero))
    assert_true(Bool(zback.progress), "CONTROL: progress 0 stays present")
    assert_equal(zback.progress.value(), UInt32(0), "CONTROL: progress 0")
    assert_true(Bool(zback.message), "CONTROL: an empty message stays present")
    print("  test_a_heartbeat_with_the_optionals_absent: PASS")


def test_every_phase_round_trips() raises:
    var phases = List[Int]()
    phases.append(JobPhase.JOB_PHASE_RUNNING)
    phases.append(JobPhase.JOB_PHASE_COMPLETED)
    phases.append(JobPhase.JOB_PHASE_FAILED)
    phases.append(JobPhase.JOB_PHASE_CANCELLED)
    for p in phases:
        var hb = JobHeartbeat(
            String("j"), JobPhase(p), String("i"), None, None, None
        )
        var back = decode_proto[JobHeartbeat](encode_proto[JobHeartbeat](hb))
        assert_equal(back.phase.value, p, "phase " + String(p))
    # The four phases are distinct numbers.
    assert_true(
        JobPhase.JOB_PHASE_RUNNING != JobPhase.JOB_PHASE_COMPLETED
        and JobPhase.JOB_PHASE_COMPLETED != JobPhase.JOB_PHASE_FAILED
        and JobPhase.JOB_PHASE_FAILED != JobPhase.JOB_PHASE_CANCELLED,
        "distinct phase numbers",
    )
    print("  test_every_phase_round_trips: PASS")


def test_the_reply_round_trips_both_directives() raises:
    var cancel = JobHeartbeatReply(JobDirective(JobDirective.JOB_DIRECTIVE_CANCEL))
    var cb = encode_proto[JobHeartbeatReply](cancel)
    assert_true(len(cb) > 0, "CANCEL is not the zero value: it is on the wire")
    var cback = decode_proto[JobHeartbeatReply](cb^)
    assert_equal(
        cback.directive.value, JobDirective.JOB_DIRECTIVE_CANCEL, "CANCEL"
    )

    var cont = JobHeartbeatReply(
        JobDirective(JobDirective.JOB_DIRECTIVE_CONTINUE)
    )
    var kb = encode_proto[JobHeartbeatReply](cont)
    var kback = decode_proto[JobHeartbeatReply](kb^)
    assert_equal(
        kback.directive.value, JobDirective.JOB_DIRECTIVE_CONTINUE, "CONTINUE"
    )
    # An empty body is all defaults: CONTINUE.
    var empty = decode_proto[JobHeartbeatReply](List[UInt8]())
    assert_equal(
        empty.directive.value,
        JobDirective.JOB_DIRECTIVE_CONTINUE,
        "an empty reply is CONTINUE",
    )
    print("  test_the_reply_round_trips_both_directives: PASS")


def test_a_failure_on_its_own() raises:
    var fr = JobFailure(None, Optional[Int32](Int32(15)), List[String](), None)
    var back = decode_proto[JobFailure](encode_proto[JobFailure](fr))
    assert_false(Bool(back.exit_code), "exit_code absent")
    assert_equal(back.signal.value(), Int32(15), "signal")
    assert_equal(len(back.stderr_tail), 0, "empty stderr_tail")
    assert_false(Bool(back.panic_message), "panic_message absent")
    print("  test_a_failure_on_its_own: PASS")


def test_the_wire_numbers_are_pinned() raises:
    assert_equal(JobPhase.JOB_PHASE_UNSPECIFIED, 0, "UNSPECIFIED")
    assert_equal(JobPhase.JOB_PHASE_RUNNING, 1, "RUNNING")
    assert_equal(JobPhase.JOB_PHASE_COMPLETED, 2, "COMPLETED")
    assert_equal(JobPhase.JOB_PHASE_FAILED, 3, "FAILED")
    assert_equal(JobPhase.JOB_PHASE_CANCELLED, 4, "CANCELLED")
    assert_equal(JobDirective.JOB_DIRECTIVE_CONTINUE, 0, "CONTINUE")
    assert_equal(JobDirective.JOB_DIRECTIVE_CANCEL, 1, "CANCEL")

    # CANCEL is field 1, varint 1.
    var cancel = encode_proto[JobHeartbeatReply](
        JobHeartbeatReply(JobDirective(JobDirective.JOB_DIRECTIVE_CANCEL))
    )
    assert_equal(len(cancel), 2, "CANCEL reply is two bytes")
    assert_equal(cancel[0], UInt8(0x08), "field 1, varint")
    assert_equal(cancel[1], UInt8(0x01), "CANCEL = 1")

    # job_id "j" (field 1, length 1), phase RUNNING (field 2, varint 1),
    # instance_name "i" (field 3, length 1).
    var hb = encode_proto[JobHeartbeat](
        JobHeartbeat(
            String("j"),
            JobPhase(JobPhase.JOB_PHASE_RUNNING),
            String("i"),
            None,
            None,
            None,
        )
    )
    var want = List[UInt8]()
    for b in [0x0A, 0x01, 0x6A, 0x10, 0x01, 0x1A, 0x01, 0x69]:
        want.append(UInt8(b))
    assert_equal(len(hb), len(want), "heartbeat length")
    for i in range(len(want)):
        assert_equal(hb[i], want[i], "heartbeat byte " + String(i))
    print("  test_the_wire_numbers_are_pinned: PASS")


def main() raises:
    print("test_job_report_roundtrip:")
    test_a_heartbeat_with_every_field_set()
    test_a_heartbeat_with_the_optionals_absent()
    test_every_phase_round_trips()
    test_the_reply_round_trips_both_directives()
    test_a_failure_on_its_own()
    test_the_wire_numbers_are_pinned()
    print("test_job_report_roundtrip: ALL PASS")
