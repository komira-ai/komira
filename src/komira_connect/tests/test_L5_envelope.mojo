# =============================================================================
# test_L5_envelope.mojo — Connect-RPC 5-byte envelope framing round-trip
# =============================================================================
#
# Envelope round-trip + multi-frame stream split.
#
# Coverage:
#   T1   write_envelope_header + read_envelope_header — exact 5-byte shape
#        (flags + 4-byte BE length). Both directions.
#   T2   write_envelope + split_first_envelope — single envelope round-trip
#        for a small payload (4-byte body).
#   T3   write_envelope + split_envelopes — multi-frame stream (3 envelopes,
#        each with a different flag set + payload).
#   T4   END_STREAM flag set on the LAST envelope (grpc-web trailers shape).
#   T5   COMPRESSED flag set (the bit is carried, not interpreted).
#   T6   Zero-length payload — minimum valid envelope (5 header + 0 body).
#   T7   Large payload — 8 KB envelope (within HTTP/2 default max frame).
#   T8   Boundary-byte length encoding — 256, 65536, 16777216 (each crosses
#        a uint32 BE byte boundary).
#   T9   Short-read error — buffer truncated mid-header raises.
#   T10  Truncated-payload error — declared length exceeds remaining bytes.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_connect import (
    ENVELOPE_HEADER_SIZE,
    ENVELOPE_FLAG_COMPRESSED,
    ENVELOPE_FLAG_END_STREAM,
    EnvelopeView,
    write_envelope_header,
    write_envelope,
    read_envelope_header,
    split_envelopes,
    split_first_envelope,
)


def test_t1_header_round_trip() raises:
    """T1 — write_envelope_header + read_envelope_header exact 5-byte shape."""
    var out = List[UInt8]()
    write_envelope_header(out, 0x00, 12345)
    assert_equal(len(out), ENVELOPE_HEADER_SIZE, "header is 5 bytes")
    # flags
    assert_equal(out[0], UInt8(0), "flags byte")
    # length 12345 = 0x00 00 30 39
    assert_equal(out[1], UInt8(0x00), "len byte 0")
    assert_equal(out[2], UInt8(0x00), "len byte 1")
    assert_equal(out[3], UInt8(0x30), "len byte 2")
    assert_equal(out[4], UInt8(0x39), "len byte 3")

    # Decode side
    var hdr = read_envelope_header(Span(out), 0)
    assert_equal(hdr[0], UInt8(0), "decoded flags")
    assert_equal(hdr[1], 12345, "decoded length")


def test_t2_single_envelope_round_trip() raises:
    """T2 — write_envelope + split_first_envelope round-trip."""
    var payload = List[UInt8]()
    payload.append(UInt8(0xDE))
    payload.append(UInt8(0xAD))
    payload.append(UInt8(0xBE))
    payload.append(UInt8(0xEF))

    var wire = List[UInt8]()
    write_envelope(wire, 0x00, Span(payload))
    assert_equal(len(wire), 5 + 4, "5 header + 4 body")

    var result = split_first_envelope(Span(wire), 0)
    var env = result[0]
    var next_offset = result[1]
    assert_equal(env.flags, UInt8(0), "envelope flags")
    assert_equal(len(env.payload), 4, "envelope payload length")
    assert_equal(env.payload[0], UInt8(0xDE), "envelope byte 0")
    assert_equal(env.payload[1], UInt8(0xAD), "envelope byte 1")
    assert_equal(env.payload[2], UInt8(0xBE), "envelope byte 2")
    assert_equal(env.payload[3], UInt8(0xEF), "envelope byte 3")
    assert_equal(next_offset, 9, "next_offset = end of envelope")
    assert_false(env.is_compressed(), "not compressed")
    assert_false(env.is_end_stream(), "not end_stream")


def test_t3_multi_envelope_split() raises:
    """T3 — split_envelopes over a 3-envelope concatenated stream."""
    var wire = List[UInt8]()

    var p1 = List[UInt8]()
    p1.append(UInt8(0x01))
    p1.append(UInt8(0x02))
    write_envelope(wire, 0x00, Span(p1))

    var p2 = List[UInt8]()
    p2.append(UInt8(0x03))
    p2.append(UInt8(0x04))
    p2.append(UInt8(0x05))
    write_envelope(wire, ENVELOPE_FLAG_COMPRESSED, Span(p2))

    var p3 = List[UInt8]()
    p3.append(UInt8(0x06))
    write_envelope(wire, ENVELOPE_FLAG_END_STREAM, Span(p3))

    # Decode
    var envs = split_envelopes(Span(wire))
    assert_equal(len(envs), 3, "3 envelopes")
    assert_equal(envs[0].flags, UInt8(0), "env0 flags")
    assert_equal(len(envs[0].payload), 2, "env0 payload len")
    assert_equal(envs[0].payload[0], UInt8(0x01), "env0 byte 0")

    assert_equal(envs[1].flags, ENVELOPE_FLAG_COMPRESSED, "env1 flags")
    assert_true(envs[1].is_compressed(), "env1 compressed")
    assert_equal(len(envs[1].payload), 3, "env1 payload len")
    assert_equal(envs[1].payload[2], UInt8(0x05), "env1 byte 2")

    assert_equal(envs[2].flags, ENVELOPE_FLAG_END_STREAM, "env2 flags")
    assert_true(envs[2].is_end_stream(), "env2 end_stream")
    assert_equal(len(envs[2].payload), 1, "env2 payload len")
    assert_equal(envs[2].payload[0], UInt8(0x06), "env2 byte 0")


def test_t4_end_stream_last_envelope() raises:
    """T4 — END_STREAM flag set on LAST envelope (grpc-web trailers shape)."""
    var wire = List[UInt8]()
    var data = List[UInt8]()
    data.append(UInt8(0xAA))
    write_envelope(wire, 0x00, Span(data))

    # Trailer envelope: empty body for this test (real grpc-web trailers
    # would be an HTTP trailer block).
    var trailer = List[UInt8]()
    write_envelope(wire, ENVELOPE_FLAG_END_STREAM, Span(trailer))

    var envs = split_envelopes(Span(wire))
    assert_equal(len(envs), 2, "data + trailer")
    assert_false(envs[0].is_end_stream(), "data is NOT end_stream")
    assert_true(envs[1].is_end_stream(), "trailer IS end_stream")


def test_t5_compressed_flag() raises:
    """T5 — COMPRESSED flag bit isolation (carried, not interpreted)."""
    var wire = List[UInt8]()
    var p = List[UInt8]()
    p.append(UInt8(0x42))
    write_envelope(wire, ENVELOPE_FLAG_COMPRESSED, Span(p))

    var envs = split_envelopes(Span(wire))
    assert_equal(len(envs), 1, "1 envelope")
    assert_true(envs[0].is_compressed(), "compressed bit set")
    assert_false(envs[0].is_end_stream(), "end_stream bit clear")


def test_t6_zero_length_payload() raises:
    """T6 — minimum valid envelope: 5-byte header with 0 payload."""
    var wire = List[UInt8]()
    var empty = List[UInt8]()
    write_envelope(wire, 0x00, Span(empty))
    assert_equal(len(wire), 5, "just the header")

    var envs = split_envelopes(Span(wire))
    assert_equal(len(envs), 1, "1 envelope")
    assert_equal(len(envs[0].payload), 0, "empty payload")


def test_t7_large_payload() raises:
    """T7 — 8 KB envelope."""
    var p = List[UInt8]()
    for i in range(8192):
        p.append(UInt8(i & 0xFF))
    var wire = List[UInt8]()
    write_envelope(wire, 0x00, Span(p))
    assert_equal(len(wire), 5 + 8192, "5 + 8 KB")

    var envs = split_envelopes(Span(wire))
    assert_equal(len(envs), 1, "1 envelope")
    assert_equal(len(envs[0].payload), 8192, "8 KB body")
    # Verify a few bytes
    assert_equal(envs[0].payload[0], UInt8(0), "byte 0")
    assert_equal(envs[0].payload[255], UInt8(255), "byte 255")
    assert_equal(envs[0].payload[256], UInt8(0), "byte 256 (wrap)")


def test_t8_length_byte_boundaries() raises:
    """T8 — encode lengths at byte boundaries: 256, 65536, 16777216."""
    # length = 256 = 0x00000100
    var wire1 = List[UInt8]()
    write_envelope_header(wire1, 0x00, 256)
    assert_equal(wire1[1], UInt8(0), "256 byte 0")
    assert_equal(wire1[2], UInt8(0), "256 byte 1")
    assert_equal(wire1[3], UInt8(1), "256 byte 2")
    assert_equal(wire1[4], UInt8(0), "256 byte 3")
    var hdr1 = read_envelope_header(Span(wire1), 0)
    assert_equal(hdr1[1], 256, "decoded 256")

    # length = 65536 = 0x00010000
    var wire2 = List[UInt8]()
    write_envelope_header(wire2, 0x00, 65536)
    assert_equal(wire2[1], UInt8(0), "65536 byte 0")
    assert_equal(wire2[2], UInt8(1), "65536 byte 1")
    assert_equal(wire2[3], UInt8(0), "65536 byte 2")
    assert_equal(wire2[4], UInt8(0), "65536 byte 3")
    var hdr2 = read_envelope_header(Span(wire2), 0)
    assert_equal(hdr2[1], 65536, "decoded 65536")

    # length = 16777216 = 0x01000000
    var wire3 = List[UInt8]()
    write_envelope_header(wire3, 0x00, 16777216)
    assert_equal(wire3[1], UInt8(1), "16777216 byte 0")
    assert_equal(wire3[2], UInt8(0), "16777216 byte 1")
    assert_equal(wire3[3], UInt8(0), "16777216 byte 2")
    assert_equal(wire3[4], UInt8(0), "16777216 byte 3")
    var hdr3 = read_envelope_header(Span(wire3), 0)
    assert_equal(hdr3[1], 16777216, "decoded 16777216")


def test_t9_short_read_error() raises:
    """T9 — buffer truncated mid-header raises."""
    var wire = List[UInt8]()
    wire.append(UInt8(0))
    wire.append(UInt8(0))
    wire.append(UInt8(0))  # only 3 bytes; header needs 5
    var raised = False
    try:
        var _ = read_envelope_header(Span(wire), 0)
    except:
        raised = True
    assert_true(raised, "short read raised")


def test_t10_truncated_payload_error() raises:
    """T10 — declared length exceeds remaining bytes."""
    var wire = List[UInt8]()
    # Header claims length=100 but we only have 5 + 10 bytes in the buffer
    write_envelope_header(wire, 0x00, 100)
    for i in range(10):
        wire.append(UInt8(i))

    var raised = False
    try:
        var _ = split_envelopes(Span(wire))
    except:
        raised = True
    assert_true(raised, "truncated payload raised")


def main() raises:
    test_t1_header_round_trip()
    test_t2_single_envelope_round_trip()
    test_t3_multi_envelope_split()
    test_t4_end_stream_last_envelope()
    test_t5_compressed_flag()
    test_t6_zero_length_payload()
    test_t7_large_payload()
    test_t8_length_byte_boundaries()
    test_t9_short_read_error()
    test_t10_truncated_payload_error()
    print("test_L5_envelope: 10/10 PASS")
