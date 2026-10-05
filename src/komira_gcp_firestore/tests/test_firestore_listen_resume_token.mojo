# =============================================================================
# test_firestore_listen_resume_token.mojo — falsifier: the Listen
#   transport EXPOSES the resume_token + read_time from a TargetChange.
# =============================================================================
#
# CDC-Firestore ChangeSource. The Firestore Watch CDC path checkpoints
# on a `TargetChange` (typically NO_CHANGE / CURRENT) that carries BOTH:
#   * a `resume_token` (bytes, field 4) — the opaque cursor to resume the watch;
#   * a `read_time`    (google.protobuf.Timestamp, field 6) — the consistent
#                       snapshot time, the ORDERING KEY for the CDC records.
# (Per the public google/firestore/v1/firestore.proto, BOTH live INSIDE
# TargetChange, NOT on ListenResponse — verified on the wire.)
#
# `decode_listen_response` reads the TargetChange with the generated message
# and carries both onto the `ListenEvent`.
#
# THE FALSIFIERS:
#   (1) A synthetic TargetChange(NO_CHANGE) carrying a known resume_token (bytes)
#       + a known read_time (seconds, nanos) decodes to a ListenEvent whose
#       resume_token bytes + read_time seconds/nanos round-trip EXACTLY.
#   (2) A TargetChange with NO resume_token / NO read_time decodes to a
#       ListenEvent with has_resume_token=False + has_read_time=False (the
#       "not set on every target change" case). `resume_token` is a proto3
#       `bytes` field, which carries no presence: an empty token is no token.
#   (3) A DocumentChange (no target_change fields) has has_resume_token=False +
#       has_read_time=False (the resumable position rides on TargetChange only).
#
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_protobuf.writer import (
    pb_write_varint_field,
    pb_write_message_field,
    pb_write_bytes_field,
    pb_write_string_field,
)

from komira_gcp_firestore.firestore_listen_proto import (
    ListenEvent,
    decode_listen_response,
    LE_TARGET_CHANGE,
    LE_DOCUMENT_CHANGE,
    TCT_NO_CHANGE,
    TCT_CURRENT,
)

# google.firestore.v1 / google.protobuf field numbers, for building the
# server's side of the wire independently of the generated messages.
comptime LRESP_TARGET_CHANGE = 2  # ListenResponse.target_change
comptime LRESP_DOCUMENT_CHANGE = 3  # ListenResponse.document_change
comptime TC_TARGET_CHANGE_TYPE = 1  # TargetChange.target_change_type
comptime TC_RESUME_TOKEN = 4  # TargetChange.resume_token
comptime TC_READ_TIME = 6  # TargetChange.read_time
comptime FTS_SECONDS = 1  # Timestamp.seconds
comptime FTS_NANOS = 2  # Timestamp.nanos
comptime DC_DOCUMENT = 1  # DocumentChange.document
comptime DOC_NAME = 1  # Document.name


# -----------------------------------------------------------------------------
# Synthetic Firestore protobuf builders (server-side fixtures — independent of
# the client's own encoder for the response side, an honest falsifier).
# -----------------------------------------------------------------------------


def _timestamp_msg(seconds: Int64, nanos: Int64) -> List[UInt8]:
    """A google.protobuf.Timestamp { seconds = 1; nanos = 2; } sub-message."""
    var ts = List[UInt8]()
    pb_write_varint_field(ts, FTS_SECONDS, UInt64(seconds))
    pb_write_varint_field(ts, FTS_NANOS, UInt64(nanos))
    return ts^


def _target_change_with_resume(
    change_type: Int,
    resume_token: List[UInt8],
    read_seconds: Int64,
    read_nanos: Int64,
) -> List[UInt8]:
    """A ListenResponse{ target_change = 2 { target_change_type; resume_token = 4;
    read_time = 6 } } carrying a resume_token + read_time."""
    var tc = List[UInt8]()
    pb_write_varint_field(tc, TC_TARGET_CHANGE_TYPE, UInt64(change_type))
    pb_write_bytes_field(tc, TC_RESUME_TOKEN, resume_token)
    pb_write_message_field(
        tc, TC_READ_TIME, _timestamp_msg(read_seconds, read_nanos)
    )
    var resp = List[UInt8]()
    pb_write_message_field(resp, LRESP_TARGET_CHANGE, tc)
    return resp^


def _target_change_bare(change_type: Int) -> List[UInt8]:
    """A ListenResponse{ target_change = 2 { target_change_type } } with NO
    resume_token / read_time (the "not set on every target change" case)."""
    var tc = List[UInt8]()
    pb_write_varint_field(tc, TC_TARGET_CHANGE_TYPE, UInt64(change_type))
    var resp = List[UInt8]()
    pb_write_message_field(resp, LRESP_TARGET_CHANGE, tc)
    return resp^


def _document_change(name: String) -> List[UInt8]:
    """A ListenResponse{ document_change = 3 { document = 1 { name = 1 } } }."""
    var doc = List[UInt8]()
    pb_write_string_field(doc, DOC_NAME, name)
    var dc = List[UInt8]()
    pb_write_message_field(dc, DC_DOCUMENT, doc)
    var resp = List[UInt8]()
    pb_write_message_field(resp, LRESP_DOCUMENT_CHANGE, dc)
    return resp^


# =============================================================================
# (1) resume_token + read_time round-trip.
# =============================================================================
def test_target_change_carries_resume_token_and_read_time() raises:
    print("  test_target_change_carries_resume_token_and_read_time...")
    var token = List[UInt8]()
    token.append(UInt8(0xDE))
    token.append(UInt8(0xAD))
    token.append(UInt8(0xBE))
    token.append(UInt8(0xEF))
    var bytes = _target_change_with_resume(
        TCT_NO_CHANGE, token, Int64(1_800_000_000), Int64(123_456_789)
    )
    var view = Span[UInt8](bytes).as_imm()
    var ev = decode_listen_response(view)

    assert_equal(ev.kind, LE_TARGET_CHANGE)
    assert_equal(ev.target_change_type, TCT_NO_CHANGE)

    # resume_token round-trips EXACTLY.
    assert_true(ev.has_resume_token, "resume_token present")
    assert_equal(len(ev.resume_token), 4, "resume_token length")
    assert_equal(Int(ev.resume_token[0]), 0xDE)
    assert_equal(Int(ev.resume_token[1]), 0xAD)
    assert_equal(Int(ev.resume_token[2]), 0xBE)
    assert_equal(Int(ev.resume_token[3]), 0xEF)

    # read_time seconds/nanos round-trip EXACTLY.
    assert_true(ev.has_read_time, "read_time present")
    assert_equal(ev.read_time_seconds, Int64(1_800_000_000), "read_time seconds")
    assert_equal(ev.read_time_nanos, Int64(123_456_789), "read_time nanos")
    print("    OK")


# =============================================================================
# (2) A TargetChange with NO resume_token / read_time -> flags False.
# =============================================================================
def test_target_change_without_resume_token_flags_absent() raises:
    print("  test_target_change_without_resume_token_flags_absent...")
    var bytes = _target_change_bare(TCT_CURRENT)
    var view = Span[UInt8](bytes).as_imm()
    var ev = decode_listen_response(view)

    assert_equal(ev.kind, LE_TARGET_CHANGE)
    assert_equal(ev.target_change_type, TCT_CURRENT)
    assert_false(
        ev.has_resume_token,
        "a TargetChange with no resume_token carries no resume position",
    )
    assert_false(ev.has_read_time, "no read_time on this TargetChange")
    print("    OK")


# =============================================================================
# (3) A DocumentChange carries no resumable position.
# =============================================================================
def test_document_change_has_no_resume_position() raises:
    print("  test_document_change_has_no_resume_position...")
    var bytes = _document_change(
        String("projects/p/databases/d/documents/c/x")
    )
    var view = Span[UInt8](bytes).as_imm()
    var ev = decode_listen_response(view)

    assert_equal(ev.kind, LE_DOCUMENT_CHANGE)
    assert_false(ev.has_resume_token, "resumable position rides TargetChange only")
    assert_false(ev.has_read_time, "no read_time on a DocumentChange")
    print("    OK")


def main() raises:
    print("test_firestore_listen_resume_token (transport exposes"
          " resume_token + read_time)")
    test_target_change_carries_resume_token_and_read_time()
    test_target_change_without_resume_token_flags_absent()
    test_document_change_has_no_resume_position()
    print("ALL PASS")
