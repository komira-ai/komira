# =============================================================================
# tests/test_L2_h2_frame.mojo — RFC 9113 frame codec round-trips
# =============================================================================
#
# L2 unit tests. Covers:
#   * encode→decode round-trip for every frame type
#   * 9-byte header packing (length + kind + flags + stream-id with R-bit mask)
#   * SETTINGS payload shape (6-byte entries; ACK-must-be-zero-length)
#   * WINDOW_UPDATE zero-increment split (stream → RST, conn → GOAWAY)
#   * Frame size limits (RFC 9113 §4.2 / §6.5.2)
#   * DATA-on-stream-0 PROTOCOL_ERROR
#   * RST_STREAM length validation
#   * PRIORITY 5-byte size enforcement
#   * GOAWAY shape + parse
#   * Multi-frame buffer NEED_MORE behavior
#
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_http.codec.h2 import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FRAME_DATA,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_PING,
    FRAME_PRIORITY,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    FRAME_WINDOW_UPDATE,
    Frame,
    FrameDecodeResult,
    FrameHeader,
    H2_ERR_FLOW_CONTROL_ERROR,
    H2_ERR_FRAME_SIZE_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    MAX_FRAME_PAYLOAD_DEFAULT,
    SETTINGS_INITIAL_WINDOW_SIZE,
    SETTINGS_MAX_CONCURRENT_STREAMS,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_frame_header,
    encode_goaway_frame,
    encode_headers_frame,
    encode_ping_frame,
    encode_rst_stream_frame,
    encode_settings_ack_frame,
    encode_settings_frame,
    encode_window_update_frame,
)


# =============================================================================
# §1 — Helper: round-trip via decode_frame.
# =============================================================================


def _decode(ref buf: List[UInt8]) -> FrameDecodeResult:
    """Decode `buf` with the default max-frame-size.

    Span construction from a List in Mojo 1.0.0b1 uses `Span(buf)`.
    """
    return decode_frame(Span(buf), MAX_FRAME_PAYLOAD_DEFAULT)


# =============================================================================
# §2 — encode_frame_header packs 9 bytes correctly.
# =============================================================================


def test_frame_header_encoding() raises:
    var out = List[UInt8]()
    # length=0x010203 (1.66 MB-ish), kind=DATA, flags=END_STREAM, stream_id=0x80000005
    # The MSB of stream_id (R bit) MUST be masked off by the encoder; expect 0x00000005.
    encode_frame_header(
        UInt32(0x010203), FRAME_DATA, FLAG_END_STREAM,
        UInt32(0x80000005), out,
    )
    assert_equal(len(out), 9)
    assert_equal(Int(out[0]), 0x01)
    assert_equal(Int(out[1]), 0x02)
    assert_equal(Int(out[2]), 0x03)
    assert_equal(Int(out[3]), Int(FRAME_DATA))
    assert_equal(Int(out[4]), Int(FLAG_END_STREAM))
    assert_equal(Int(out[5]), 0x00)  # R bit masked off
    assert_equal(Int(out[6]), 0x00)
    assert_equal(Int(out[7]), 0x00)
    assert_equal(Int(out[8]), 0x05)


# =============================================================================
# §3 — DATA frame round-trip.
# =============================================================================


def test_data_frame_roundtrip() raises:
    var data = List[UInt8]()
    data.append(UInt8(ord("H")))
    data.append(UInt8(ord("i")))
    data.append(UInt8(ord("!")))
    var wire = List[UInt8]()
    encode_data_frame(UInt32(5), data^, True, wire)
    # 9 + 3 = 12 bytes.
    assert_equal(len(wire), 12)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_DATA))
    assert_equal(Int(dec.frame.header.stream_id), 5)
    assert_equal(Int(dec.frame.header.flags), Int(FLAG_END_STREAM))
    assert_equal(len(dec.frame.payload), 3)
    assert_equal(Int(dec.frame.payload[0]), Int(ord("H")))
    assert_equal(Int(dec.frame.payload[1]), Int(ord("i")))
    assert_equal(Int(dec.frame.payload[2]), Int(ord("!")))


# =============================================================================
# §4 — HEADERS frame round-trip (no priority, no padding).
# =============================================================================


def test_headers_frame_roundtrip() raises:
    # Synthesize a "block fragment" — bytes that would be HPACK output.
    var block = List[UInt8]()
    block.append(UInt8(0x82))  # indexed-static :method GET = static idx 2
    block.append(UInt8(0x84))  # indexed-static :path / = static idx 4
    block.append(UInt8(0x86))  # indexed-static :scheme http = idx 6
    var wire = List[UInt8]()
    encode_headers_frame(UInt32(3), block^, False, True, wire)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_HEADERS))
    assert_equal(Int(dec.frame.header.stream_id), 3)
    assert_equal(Int(dec.frame.header.flags), Int(FLAG_END_HEADERS))
    assert_equal(len(dec.frame.payload), 3)


# =============================================================================
# §5 — SETTINGS round-trip + ACK shape.
# =============================================================================


def test_settings_frame_roundtrip() raises:
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(
        identifier=SETTINGS_INITIAL_WINDOW_SIZE, value=UInt32(65535),
    ))
    entries.append(SettingsEntry(
        identifier=SETTINGS_MAX_CONCURRENT_STREAMS, value=UInt32(100),
    ))
    var wire = List[UInt8]()
    encode_settings_frame(entries^, wire)
    # 9 header + 2 * 6 = 21 bytes.
    assert_equal(len(wire), 21)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_SETTINGS))
    assert_equal(Int(dec.frame.header.stream_id), 0)
    assert_equal(len(dec.frame.settings), 2)
    assert_equal(Int(dec.frame.settings[0].identifier), 4)
    assert_equal(Int(dec.frame.settings[0].value), 65535)


def test_settings_ack_roundtrip() raises:
    var wire = List[UInt8]()
    encode_settings_ack_frame(wire)
    assert_equal(len(wire), 9)
    assert_equal(Int(wire[4]), Int(FLAG_ACK))
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_SETTINGS))
    assert_equal(Int(dec.frame.header.flags), Int(FLAG_ACK))


def test_settings_ack_with_payload_rejected() raises:
    """RFC 9113 §6.5 — SETTINGS-ACK MUST be zero-length."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(6), FRAME_SETTINGS, FLAG_ACK, UInt32(0), wire,
    )
    # Append fake payload.
    var i = 0
    while i < 6:
        wire.append(UInt8(0))
        i = i + 1
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_FRAME_SIZE_ERROR))
    assert_true(dec.is_connection_error)


def test_settings_non_multiple_of_6_rejected() raises:
    """RFC 9113 §6.5.1 — SETTINGS payload MUST be a multiple of 6."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(7), FRAME_SETTINGS, UInt8(0), UInt32(0), wire,
    )
    var i = 0
    while i < 7:
        wire.append(UInt8(0))
        i = i + 1
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_FRAME_SIZE_ERROR))


def test_settings_on_stream_n_rejected() raises:
    """RFC 9113 §6.5 — SETTINGS MUST be on stream 0."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(0), FRAME_SETTINGS, UInt8(0), UInt32(7), wire,
    )
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_PROTOCOL_ERROR))
    assert_true(dec.is_connection_error)


# =============================================================================
# §6 — PING round-trip + length validation.
# =============================================================================


def test_ping_frame_roundtrip() raises:
    var data = SIMD[DType.uint8, 8](0)
    data[0] = UInt8(0x01)
    data[7] = UInt8(0xff)
    var wire = List[UInt8]()
    encode_ping_frame(data, False, wire)
    assert_equal(len(wire), 17)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_PING))
    assert_equal(Int(dec.frame.ping_data[0]), 0x01)
    assert_equal(Int(dec.frame.ping_data[7]), 0xff)


def test_ping_wrong_length_rejected() raises:
    """PING MUST be exactly 8 bytes (RFC 9113 §6.7)."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_PING, UInt8(0), UInt32(0), wire)
    var i = 0
    while i < 4:
        wire.append(UInt8(0))
        i = i + 1
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_FRAME_SIZE_ERROR))


# =============================================================================
# §7 — RST_STREAM round-trip + length validation.
# =============================================================================


def test_rst_stream_roundtrip() raises:
    var wire = List[UInt8]()
    encode_rst_stream_frame(UInt32(5), H2_ERR_PROTOCOL_ERROR, wire)
    assert_equal(len(wire), 13)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_RST_STREAM))
    assert_equal(Int(dec.frame.rst_error_code), Int(H2_ERR_PROTOCOL_ERROR))


def test_rst_stream_wrong_length_rejected() raises:
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(3), FRAME_RST_STREAM, UInt8(0), UInt32(5), wire,
    )
    var i = 0
    while i < 3:
        wire.append(UInt8(0))
        i = i + 1
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_FRAME_SIZE_ERROR))


# =============================================================================
# §8 — GOAWAY round-trip.
# =============================================================================


def test_goaway_frame_roundtrip() raises:
    var debug = List[UInt8]()
    debug.append(UInt8(ord("X")))
    debug.append(UInt8(ord("Y")))
    var wire = List[UInt8]()
    encode_goaway_frame(
        UInt32(7), H2_ERR_PROTOCOL_ERROR, debug^, wire,
    )
    # 9 header + 8 (last_stream_id + error_code) + 2 debug = 19.
    assert_equal(len(wire), 19)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_GOAWAY))
    assert_equal(Int(dec.frame.goaway_last_stream_id), 7)
    assert_equal(Int(dec.frame.goaway_error_code), Int(H2_ERR_PROTOCOL_ERROR))
    assert_equal(len(dec.frame.payload), 2)


# =============================================================================
# §9 — WINDOW_UPDATE round-trip + zero-increment split.
# =============================================================================


def test_window_update_frame_roundtrip() raises:
    var wire = List[UInt8]()
    encode_window_update_frame(UInt32(3), UInt32(65535), wire)
    assert_equal(len(wire), 13)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_WINDOW_UPDATE))
    assert_equal(Int(dec.frame.window_update_increment), 65535)


def test_window_update_zero_increment_on_stream_rst() raises:
    """Ssue 2: zero-increment WINDOW_UPDATE on a non-zero
    stream → RST_STREAM(PROTOCOL_ERROR)."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(4), FRAME_WINDOW_UPDATE, UInt8(0), UInt32(5), wire,
    )
    var i = 0
    while i < 4:
        wire.append(UInt8(0))  # zero increment
        i = i + 1
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_PROTOCOL_ERROR))
    assert_false(dec.is_connection_error)
    assert_equal(Int(dec.error_stream_id), 5)


def test_window_update_zero_increment_on_conn_goaway() raises:
    """Ssue 2: zero-increment WINDOW_UPDATE on stream 0
    → GOAWAY(PROTOCOL_ERROR) (no stream to reset)."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(4), FRAME_WINDOW_UPDATE, UInt8(0), UInt32(0), wire,
    )
    var i = 0
    while i < 4:
        wire.append(UInt8(0))
        i = i + 1
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_PROTOCOL_ERROR))
    assert_true(dec.is_connection_error)


# =============================================================================
# §10 — DATA-on-stream-0 PROTOCOL_ERROR.
# =============================================================================


def test_data_on_stream_0_protocol_error() raises:
    """RFC 9113 §6.1 — DATA frames MUST be associated with a stream;
    stream_id == 0 → connection PROTOCOL_ERROR."""
    var data = List[UInt8]()
    data.append(UInt8(ord("X")))
    var wire = List[UInt8]()
    encode_data_frame(UInt32(0), data^, False, wire)
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_PROTOCOL_ERROR))
    assert_true(dec.is_connection_error)


# =============================================================================
# §11 — PRIORITY 5-byte enforcement.
# =============================================================================


def test_priority_wrong_length_rejected() raises:
    """RFC 9113 §6.3 — PRIORITY MUST be exactly 5 bytes."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(3), FRAME_PRIORITY, UInt8(0), UInt32(1), wire,
    )
    var i = 0
    while i < 3:
        wire.append(UInt8(0))
        i = i + 1
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_FRAME_SIZE_ERROR))


# =============================================================================
# §12 — Max-frame-size exceedance → FRAME_SIZE_ERROR.
# =============================================================================


def test_max_frame_size_exceeded() raises:
    """A frame whose payload exceeds the configured max_frame_size is a
    connection FRAME_SIZE_ERROR (RFC 9113 §4.2)."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(MAX_FRAME_PAYLOAD_DEFAULT + 1),
        FRAME_DATA, UInt8(0), UInt32(5), wire,
    )
    # No need to fill the payload — decode rejects on length check.
    var dec = _decode(wire)
    assert_true(dec.is_error())
    assert_equal(Int(dec.error_code), Int(H2_ERR_FRAME_SIZE_ERROR))


# =============================================================================
# §13 — NEED_MORE behavior on truncated buffer.
# =============================================================================


def test_decode_need_more_on_truncated_header() raises:
    var wire = List[UInt8]()
    wire.append(UInt8(0))
    wire.append(UInt8(0))
    wire.append(UInt8(8))  # length only — header is 9 bytes
    var dec = _decode(wire)
    assert_true(dec.is_need_more())


def test_decode_need_more_on_truncated_body() raises:
    var wire = List[UInt8]()
    encode_frame_header(UInt32(10), FRAME_DATA, UInt8(0), UInt32(3), wire)
    # Don't append the 10-byte body.
    var dec = _decode(wire)
    assert_true(dec.is_need_more())


# =============================================================================
# §14 — main entry point.
# =============================================================================


def main() raises:
    print("test_L2_h2_frame: start")
    test_frame_header_encoding()
    print(" frame_header_encoding PASS")
    test_data_frame_roundtrip()
    print(" data_frame_roundtrip PASS")
    test_headers_frame_roundtrip()
    print(" headers_frame_roundtrip PASS")
    test_settings_frame_roundtrip()
    print(" settings_frame_roundtrip PASS")
    test_settings_ack_roundtrip()
    print(" settings_ack_roundtrip PASS")
    test_settings_ack_with_payload_rejected()
    print(" settings_ack_with_payload_rejected PASS")
    test_settings_non_multiple_of_6_rejected()
    print(" settings_non_multiple_of_6_rejected PASS")
    test_settings_on_stream_n_rejected()
    print(" settings_on_stream_n_rejected PASS")
    test_ping_frame_roundtrip()
    print(" ping_frame_roundtrip PASS")
    test_ping_wrong_length_rejected()
    print(" ping_wrong_length_rejected PASS")
    test_rst_stream_roundtrip()
    print(" rst_stream_roundtrip PASS")
    test_rst_stream_wrong_length_rejected()
    print(" rst_stream_wrong_length_rejected PASS")
    test_goaway_frame_roundtrip()
    print(" goaway_frame_roundtrip PASS")
    test_window_update_frame_roundtrip()
    print(" window_update_frame_roundtrip PASS")
    test_window_update_zero_increment_on_stream_rst()
    print(" window_update_zero_on_stream_rst PASS")
    test_window_update_zero_increment_on_conn_goaway()
    print(" window_update_zero_on_conn_goaway PASS")
    test_data_on_stream_0_protocol_error()
    print(" data_on_stream_0_protocol_error PASS")
    test_priority_wrong_length_rejected()
    print(" priority_wrong_length_rejected PASS")
    test_max_frame_size_exceeded()
    print(" max_frame_size_exceeded PASS")
    test_decode_need_more_on_truncated_header()
    print(" need_more_truncated_header PASS")
    test_decode_need_more_on_truncated_body()
    print(" need_more_truncated_body PASS")
    print("test_L2_h2_frame: ALL 21 TESTS PASS")
