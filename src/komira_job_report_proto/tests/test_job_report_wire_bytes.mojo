# =============================================================================
# komira_job_report_proto/tests/test_job_report_wire_bytes.mojo
#   A JobHeartbeat's exact wire bytes, for the fields the round trip cannot pin.
# =============================================================================
#
# A round trip cannot see a renumbering: encode and decode share the same field
# numbers, so a field moved from 2 to 5 still comes back with its value. A peer
# built from an older copy of the file reads the bytes, not the constants. So
# every field of JobHeartbeat and JobFailure is pinned here by its exact bytes:
# tag (field << 3 | wire type), then the value.
#
# Wire types: 0 = varint, 2 = length-delimited. One-byte strings keep each
# expected byte readable. Fields are written in field-number order.
# =============================================================================

from std.testing import assert_equal

from komira_proto_codec import encode_proto

from komira_job_report_proto.job_report import (
    JobFailure,
    JobHeartbeat,
    JobPhase,
)


def _assert_bytes(got: List[UInt8], want: List[Int], what: String) raises:
    assert_equal(len(got), len(want), what + ": length")
    for i in range(len(want)):
        assert_equal(
            got[i], UInt8(want[i]), what + ": byte " + String(i)
        )


def test_a_failed_heartbeat_pins_every_failure_field() raises:
    var tail = List[String]()
    tail.append(String("a"))
    tail.append(String("b"))
    var hb = JobHeartbeat(
        String("j"),
        JobPhase(JobPhase.JOB_PHASE_FAILED),
        String("i"),
        None,
        None,
        Optional[JobFailure](
            JobFailure(
                Optional[Int32](Int32(7)),
                Optional[Int32](Int32(9)),
                tail^,
                Optional[String](String("p")),
            )
        ),
    )
    # JobFailure, 13 bytes:
    #   exit_code 7        field 1, varint  -> 08 07
    #   signal 9           field 2, varint  -> 10 09
    #   stderr_tail "a"    field 3, length  -> 1A 01 61
    #   stderr_tail "b"    field 3, length  -> 1A 01 62
    #   panic_message "p"  field 4, length  -> 22 01 70
    var want: List[Int] = [
        0x0A, 0x01, 0x6A,  # job_id "j"         field 1, length
        0x10, 0x03,  # phase FAILED = 3         field 2, varint
        0x1A, 0x01, 0x69,  # instance_name "i"  field 3, length
        0x32, 0x0D,  # failure                  field 6, length 13
        0x08, 0x07,
        0x10, 0x09,
        0x1A, 0x01, 0x61,
        0x1A, 0x01, 0x62,
        0x22, 0x01, 0x70,
    ]
    _assert_bytes(encode_proto[JobHeartbeat](hb), want, "failed heartbeat")
    print("  test_a_failed_heartbeat_pins_every_failure_field: PASS")


def test_a_running_heartbeat_pins_progress_and_message() raises:
    var hb = JobHeartbeat(
        String("j"),
        JobPhase(JobPhase.JOB_PHASE_RUNNING),
        String("i"),
        Optional[UInt32](UInt32(42)),
        Optional[String](String("m")),
        None,
    )
    var want: List[Int] = [
        0x0A, 0x01, 0x6A,  # job_id "j"         field 1, length
        0x10, 0x01,  # phase RUNNING = 1        field 2, varint
        0x1A, 0x01, 0x69,  # instance_name "i"  field 3, length
        0x20, 0x2A,  # progress 42              field 4, varint
        0x2A, 0x01, 0x6D,  # message "m"        field 5, length
    ]
    _assert_bytes(encode_proto[JobHeartbeat](hb), want, "running heartbeat")
    print("  test_a_running_heartbeat_pins_progress_and_message: PASS")


def test_a_present_zero_is_on_the_wire() raises:
    # proto3 `optional`: a set zero is written, an absent field is not. A
    # receiver tells "0 percent" from "no progress reported" by these bytes.
    var hb = JobHeartbeat(
        String("j"),
        JobPhase(JobPhase.JOB_PHASE_RUNNING),
        String("i"),
        Optional[UInt32](UInt32(0)),
        Optional[String](String("")),
        Optional[JobFailure](
            JobFailure(
                Optional[Int32](Int32(0)), None, List[String](), None
            )
        ),
    )
    var want: List[Int] = [
        0x0A, 0x01, 0x6A,
        0x10, 0x01,
        0x1A, 0x01, 0x69,
        0x20, 0x00,  # progress 0               field 4, varint
        0x2A, 0x00,  # message ""               field 5, length 0
        0x32, 0x02,  # failure                  field 6, length 2
        0x08, 0x00,  #   exit_code 0            field 1, varint
    ]
    _assert_bytes(encode_proto[JobHeartbeat](hb), want, "present zeros")
    print("  test_a_present_zero_is_on_the_wire: PASS")


def main() raises:
    print("test_job_report_wire_bytes:")
    test_a_failed_heartbeat_pins_every_failure_field()
    test_a_running_heartbeat_pins_progress_and_message()
    test_a_present_zero_is_on_the_wire()
    print("test_job_report_wire_bytes: ALL PASS")
