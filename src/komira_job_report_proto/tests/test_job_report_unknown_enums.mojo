# =============================================================================
# komira_job_report_proto/tests/test_job_report_unknown_enums.mojo
#   An enum number this build does not know decodes to that number.
# =============================================================================
#
# A newer peer can send a phase or a directive this build has no name for.
# Proto3 enums are open: the generated wrapper keeps the number rather than
# failing the decode or folding it into a known value. A sender of
# JobHeartbeatReply relies on that being visible, because the supervisor reads
# only an explicit JOB_DIRECTIVE_CANCEL as "stop the job": an unknown
# directive must not decode AS CANCEL, and must not fail the whole reply.
#
# The bytes are written by hand (field 1, varint), so the test does not depend
# on the encoder accepting an out-of-range value.
# =============================================================================

from std.testing import assert_equal, assert_false, assert_true

from komira_proto_codec import decode_proto, encode_proto

from komira_job_report_proto.job_report import (
    JobDirective,
    JobHeartbeat,
    JobHeartbeatReply,
    JobPhase,
)


def _varint_field(field: Int, value: Int) -> List[UInt8]:
    """One varint field: tag (field << 3 | 0), then `value` as a varint."""
    var out = List[UInt8]()
    out.append(UInt8(field << 3))
    var v = value
    while v >= 0x80:
        out.append(UInt8((v & 0x7F) | 0x80))
        v >>= 7
    out.append(UInt8(v))
    return out^


def test_an_unknown_directive_keeps_its_number() raises:
    var back = decode_proto[JobHeartbeatReply](_varint_field(1, 7))
    assert_equal(back.directive.value, 7, "the unknown number survives")
    assert_true(
        back.directive.value != JobDirective.JOB_DIRECTIVE_CANCEL,
        "an unknown directive is not CANCEL",
    )
    # CONTROL: the same hand-written bytes with CANCEL's number decode to
    # CANCEL, so the bytes above are a well-formed directive field.
    var ctl = decode_proto[JobHeartbeatReply](
        _varint_field(1, JobDirective.JOB_DIRECTIVE_CANCEL)
    )
    assert_equal(
        ctl.directive.value, JobDirective.JOB_DIRECTIVE_CANCEL, "CONTROL: CANCEL"
    )
    print("  test_an_unknown_directive_keeps_its_number: PASS")


def test_an_unknown_phase_keeps_its_number() raises:
    # job_id "j" (field 1, length-delimited), then phase 99 (field 2).
    var bytes = List[UInt8]()
    bytes.append(UInt8(0x0A))
    bytes.append(UInt8(1))
    bytes.append(UInt8(ord("j")))
    bytes.extend(_varint_field(2, 99))
    var back = decode_proto[JobHeartbeat](bytes^)
    assert_equal(back.job_id, String("j"), "job_id")
    assert_equal(back.phase.value, 99, "the unknown phase number survives")
    # It re-encodes to the same number: a receiver that forwards the report
    # does not lose it.
    var again = decode_proto[JobHeartbeat](encode_proto[JobHeartbeat](back))
    assert_equal(again.phase.value, 99, "re-encoded unknown phase")
    print("  test_an_unknown_phase_keeps_its_number: PASS")


def main() raises:
    print("test_job_report_unknown_enums:")
    test_an_unknown_directive_keeps_its_number()
    test_an_unknown_phase_keeps_its_number()
    print("test_job_report_unknown_enums: ALL PASS")
