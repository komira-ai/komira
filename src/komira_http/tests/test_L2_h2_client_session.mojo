"""L2 H2ClientConnectionState + preface/SETTINGS plumbing.

Validates the h2 client connection-state machinery without going through
real TCP: build an H2ClientConnectionState, queue the preface + initial
SETTINGS, feed a synthesized server SETTINGS into recv_buf, verify the
ack is staged and server settings applied. Also: odd-id stream allocator,
stream lookup, max-concurrent enforcement, GOAWAY accounting.
"""


from komira_http.client.h2_client import (
    H2C_FLAG_GOAWAY_RECEIVED,
    H2C_FLAG_PREFACE_SENT,
    H2C_FLAG_SERVER_SETTINGS_SEEN,
    H2C_FLAG_SETTINGS_SENT,
    H2ClientConnectionState,
    H2ClientStream,
    apply_peer_settings_and_ack,
    build_initial_client_settings,
    emit_goaway_for_client,
    queue_client_preface_and_settings,
)
from komira_http.codec.h2.connection_preface import (
    H2_CLIENT_PREFACE_LEN,
)
from komira_http.codec.h2.frame import (
    FLAG_ACK,
    FRAME_DECODE_OK,
    FRAME_GOAWAY,
    FRAME_SETTINGS,
    H2_ERR_NO_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    SETTINGS_HEADER_TABLE_SIZE,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SETTINGS_MAX_CONCURRENT_STREAMS,
    SETTINGS_MAX_FRAME_SIZE,
    SettingsEntry,
    decode_frame,
)


def test_queue_preface_and_settings_emits_24_byte_magic_then_settings() raises:
    """After queue_client_preface_and_settings: pending_out begins with
    the 24-byte preface, then carries a valid SETTINGS frame."""
    print("  test_queue_preface_and_settings_emits_24_byte_magic_then_settings...")

    var h2 = H2ClientConnectionState()
    if h2.is_preface_sent():
        raise Error("flag should be unset before queue")
    queue_client_preface_and_settings(h2)
    if not h2.is_preface_sent():
        raise Error("PREFACE_SENT flag should be set after queue")
    if not h2.is_settings_sent():
        raise Error("SETTINGS_SENT flag should be set after queue")

    var pending = h2.take_out_bytes()
    if len(pending) < H2_CLIENT_PREFACE_LEN:
        raise Error(
            "pending_out shorter than preface; got "
            + String(len(pending))
        )

    # Verify first 24 bytes match the canonical magic: "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".
    var expected = String("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")
    var expected_bytes = expected.as_bytes()
    var i = 0
    while i < H2_CLIENT_PREFACE_LEN:
        if pending[i] != expected_bytes[i]:
            raise Error(
                "preface mismatch at byte " + String(i) + ": got "
                + String(Int(pending[i])) + " expected "
                + String(Int(expected_bytes[i]))
            )
        i = i + 1

    # Verify the next frame decodes as a SETTINGS frame.
    var settings_view_start = H2_CLIENT_PREFACE_LEN
    var tail = List[UInt8]()
    var j = settings_view_start
    while j < len(pending):
        tail.append(pending[j])
        j = j + 1
    var res = decode_frame(Span(tail), 16384)
    if res.status != FRAME_DECODE_OK:
        raise Error(
            "SETTINGS frame did not decode OK; status="
            + String(Int(res.status))
        )
    if res.frame.header.kind != FRAME_SETTINGS:
        raise Error(
            "expected SETTINGS frame after preface; got kind="
            + String(Int(res.frame.header.kind))
        )
    if (res.frame.header.flags & FLAG_ACK) != UInt8(0):
        raise Error("initial SETTINGS must NOT carry the ACK flag")
    if res.frame.header.stream_id != UInt32(0):
        raise Error("SETTINGS stream_id must be 0; got " + String(Int(res.frame.header.stream_id)))
    # Initial SETTINGS has 5 default entries.
    if len(res.frame.settings) != 5:
        raise Error(
            "expected 5 default SETTINGS entries; got "
            + String(len(res.frame.settings))
        )
    print("    OK")


def test_queue_idempotent_on_already_sent() raises:
    """queue_client_preface_and_settings is idempotent: calling twice
    does NOT emit the preface a second time."""
    print("  test_queue_idempotent_on_already_sent...")

    var h2 = H2ClientConnectionState()
    queue_client_preface_and_settings(h2)
    var first_n = len(h2.pending_out)
    queue_client_preface_and_settings(h2)
    var second_n = len(h2.pending_out)
    if second_n != first_n:
        raise Error(
            "second queue should be no-op; first_n=" + String(first_n)
            + " second_n=" + String(second_n)
        )
    print("    OK")


def test_apply_peer_settings_emits_ack_and_applies_values() raises:
    """Synthesize the server's non-ACK SETTINGS; apply_peer_settings_and_ack
    must (1) update h2 state fields, (2) stage a SETTINGS-ACK in pending_out."""
    print("  test_apply_peer_settings_emits_ack_and_applies_values...")

    var h2 = H2ClientConnectionState()
    var settings = List[SettingsEntry]()
    settings.append(SettingsEntry(
        identifier=SETTINGS_INITIAL_WINDOW_SIZE,
        value=UInt32(131072),  # 128 KiB
    ))
    settings.append(SettingsEntry(
        identifier=SETTINGS_MAX_FRAME_SIZE,
        value=UInt32(32768),
    ))
    settings.append(SettingsEntry(
        identifier=SETTINGS_MAX_CONCURRENT_STREAMS,
        value=UInt32(50),
    ))
    settings.append(SettingsEntry(
        identifier=SETTINGS_HEADER_TABLE_SIZE,
        value=UInt32(8192),
    ))
    var ok = apply_peer_settings_and_ack(h2, settings^)
    if not ok:
        raise Error("apply_peer_settings_and_ack should succeed for valid settings")
    if not h2.is_server_settings_seen():
        raise Error("SERVER_SETTINGS_SEEN flag should be set")
    if h2.max_frame_size_peer != 32768:
        raise Error(
            "max_frame_size_peer should be 32768; got "
            + String(h2.max_frame_size_peer)
        )
    if h2.max_concurrent_streams_peer != UInt32(50):
        raise Error(
            "max_concurrent_streams_peer should be 50; got "
            + String(Int(h2.max_concurrent_streams_peer))
        )
    if Int(h2.send_fc.initial_window_size) != 131072:
        raise Error(
            "send_fc.initial_window_size should be 131072; got "
            + String(Int(h2.send_fc.initial_window_size))
        )
    # Verify the SETTINGS-ACK was staged.
    var pending = h2.take_out_bytes()
    var res = decode_frame(Span(pending), 16384)
    if res.status != FRAME_DECODE_OK:
        raise Error(
            "SETTINGS-ACK should decode OK; status="
            + String(Int(res.status))
        )
    if res.frame.header.kind != FRAME_SETTINGS:
        raise Error("expected SETTINGS-ACK frame")
    if (res.frame.header.flags & FLAG_ACK) == UInt8(0):
        raise Error("ACK flag should be set on response SETTINGS")
    if res.frame.header.length != UInt32(0):
        raise Error("SETTINGS-ACK must have zero payload length")
    print("    OK")


def test_apply_peer_settings_rejects_invalid_max_frame_size() raises:
    """SETTINGS_MAX_FRAME_SIZE outside [16384, 16777215] → False."""
    print("  test_apply_peer_settings_rejects_invalid_max_frame_size...")

    var h2 = H2ClientConnectionState()
    var settings = List[SettingsEntry]()
    settings.append(SettingsEntry(
        identifier=SETTINGS_MAX_FRAME_SIZE,
        value=UInt32(100),  # below 16384 minimum
    ))
    var ok = apply_peer_settings_and_ack(h2, settings^)
    if ok:
        raise Error(
            "apply_peer_settings_and_ack should reject MAX_FRAME_SIZE=100"
        )
    print("    OK")


def test_apply_peer_settings_rejects_window_size_overflow() raises:
    """SETTINGS_INITIAL_WINDOW_SIZE > 2^31-1 → False (RFC 9113 §6.5.2)."""
    print("  test_apply_peer_settings_rejects_window_size_overflow...")

    var h2 = H2ClientConnectionState()
    var settings = List[SettingsEntry]()
    settings.append(SettingsEntry(
        identifier=SETTINGS_INITIAL_WINDOW_SIZE,
        value=UInt32(0x80000000),  # 2^31, just over limit
    ))
    var ok = apply_peer_settings_and_ack(h2, settings^)
    if ok:
        raise Error(
            "apply_peer_settings_and_ack should reject INITIAL_WINDOW_SIZE=2^31"
        )
    print("    OK")


def test_allocate_client_stream_id_yields_odd_increasing() raises:
    """Client stream IDs are 1, 3, 5, 7, ... per RFC 9113 §5.1.1."""
    print("  test_allocate_client_stream_id_yields_odd_increasing...")

    var h2 = H2ClientConnectionState()
    var sid1 = h2.allocate_client_stream_id()
    var sid2 = h2.allocate_client_stream_id()
    var sid3 = h2.allocate_client_stream_id()
    if sid1 != UInt32(1):
        raise Error("first sid should be 1; got " + String(Int(sid1)))
    if sid2 != UInt32(3):
        raise Error("second sid should be 3; got " + String(Int(sid2)))
    if sid3 != UInt32(5):
        raise Error("third sid should be 5; got " + String(Int(sid3)))
    # Verify odd-numbered invariant.
    var i: UInt32 = UInt32(0)
    while i < UInt32(10):
        var sid = h2.allocate_client_stream_id()
        if (Int(sid) % 2) != 1:
            raise Error(
                "stream id must be odd; got " + String(Int(sid))
            )
        i = i + UInt32(1)
    print("    OK")


def test_create_stream_records_state_and_indices() raises:
    """create_stream allocates response-header + response-body slots and
    transitions the stream to STREAM_STATE_OPEN."""
    print("  test_create_stream_records_state_and_indices...")

    var h2 = H2ClientConnectionState()
    var sid = h2.allocate_client_stream_id()
    var idx = h2.create_stream(sid)
    if idx != 0:
        raise Error("first stream idx should be 0; got " + String(idx))
    if h2.streams[idx].stream_id != sid:
        raise Error("stream_id mismatch")
    if h2.streams[idx].response_header_idx != 0:
        raise Error("response_header_idx should be 0 for first stream")
    if h2.streams[idx].response_body_idx != 0:
        raise Error("response_body_idx should be 0 for first stream")
    if len(h2.response_header_lists) != 1:
        raise Error("response_header_lists should have 1 slot")
    if len(h2.response_body_buffers) != 1:
        raise Error("response_body_buffers should have 1 slot")
    # Find should return the same index.
    var found = h2.find_stream_idx(sid)
    if found != idx:
        raise Error(
            "find_stream_idx mismatch: got " + String(found)
            + " expected " + String(idx)
        )
    # Open streams count = 1.
    if h2.open_streams_count() != UInt32(1):
        raise Error(
            "open_streams_count should be 1; got "
            + String(Int(h2.open_streams_count()))
        )
    print("    OK")


def test_emit_goaway_for_client_encodes_protocol_error() raises:
    """emit_goaway_for_client stages a valid GOAWAY frame in pending_out."""
    print("  test_emit_goaway_for_client_encodes_protocol_error...")

    var h2 = H2ClientConnectionState()
    emit_goaway_for_client(h2, H2_ERR_PROTOCOL_ERROR)
    var pending = h2.take_out_bytes()
    var res = decode_frame(Span(pending), 16384)
    if res.status != FRAME_DECODE_OK:
        raise Error(
            "GOAWAY should decode OK; status=" + String(Int(res.status))
        )
    if res.frame.header.kind != FRAME_GOAWAY:
        raise Error(
            "expected GOAWAY frame; got kind="
            + String(Int(res.frame.header.kind))
        )
    if res.frame.goaway_error_code != H2_ERR_PROTOCOL_ERROR:
        raise Error(
            "GOAWAY error_code mismatch: got "
            + String(Int(res.frame.goaway_error_code))
        )
    print("    OK")


def test_mark_goaway_received_records_last_stream_id_and_error() raises:
    """mark_goaway_received bookkeeping for pool's draining-conn logic."""
    print("  test_mark_goaway_received_records_last_stream_id_and_error...")

    var h2 = H2ClientConnectionState()
    if h2.is_goaway_received():
        raise Error("GOAWAY_RECEIVED should be clear at construction")
    h2.mark_goaway_received(UInt32(99), H2_ERR_NO_ERROR)
    if not h2.is_goaway_received():
        raise Error("GOAWAY_RECEIVED should be set after mark")
    if h2.goaway_last_stream_id != UInt32(99):
        raise Error(
            "goaway_last_stream_id mismatch: got "
            + String(Int(h2.goaway_last_stream_id))
        )
    if h2.goaway_error_code != H2_ERR_NO_ERROR:
        raise Error("goaway_error_code mismatch")
    print("    OK")


def test_recv_buf_append_consume_round_trip() raises:
    """append_recv_bytes + consume_recv_bytes preserves byte boundaries."""
    print("  test_recv_buf_append_consume_round_trip...")

    var h2 = H2ClientConnectionState()
    var src = List[UInt8]()
    var k = 0
    while k < 100:
        src.append(UInt8(k))
        k = k + 1
    h2.append_recv_bytes(Span(src))
    if len(h2.recv_buf) != 100:
        raise Error("recv_buf len should be 100; got " + String(len(h2.recv_buf)))
    h2.consume_recv_bytes(40)
    if len(h2.recv_buf) != 60:
        raise Error("after consume(40) recv_buf len should be 60")
    # Front byte after consume(40) should be 40.
    if h2.recv_buf[0] != UInt8(40):
        raise Error(
            "first byte after consume(40) should be 40; got "
            + String(Int(h2.recv_buf[0]))
        )
    # consume more than available — clears.
    h2.consume_recv_bytes(100)
    if len(h2.recv_buf) != 0:
        raise Error("consume(over-len) should clear recv_buf")
    print("    OK")


def main() raises:
    print("== L2 H2ClientConnectionState ==")
    test_queue_preface_and_settings_emits_24_byte_magic_then_settings()
    test_queue_idempotent_on_already_sent()
    test_apply_peer_settings_emits_ack_and_applies_values()
    test_apply_peer_settings_rejects_invalid_max_frame_size()
    test_apply_peer_settings_rejects_window_size_overflow()
    test_allocate_client_stream_id_yields_odd_increasing()
    test_create_stream_records_state_and_indices()
    test_emit_goaway_for_client_encodes_protocol_error()
    test_mark_goaway_received_records_last_stream_id_and_error()
    test_recv_buf_append_consume_round_trip()
    print("== L2 H2ClientConnectionState PASSED (10 tests) ==")
