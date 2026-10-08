# =============================================================================
# tests/test_L2_h2_frame_coverage.mojo: every line and branch of
# codec/h2/frame.mojo, held to RFC 9113 sections 4 and 6
# =============================================================================
#
# test_L2_h2_frame.mojo holds the round trips and a first set of refusals.
# This file adds what it leaves out: each decode arm's other branches
# (padding, priority fields, stream 0, short and long payloads, the reserved
# bit), the exact error of every refusal (code, scope, stream, `consumed`),
# the byte order of every multi-byte field, and the encoders' masks and flags.
#
# Where h2spec (the conformance suite komira_http_conformance runs against
# the server) has a case for the same rule, the test sends that case's bytes
# and names it as `h2spec http2/<section>/<n>`. The other inputs are built
# from the RFC's field layout, one rule per test.
# =============================================================================

from std.testing import TestSuite, assert_equal, assert_false, assert_true

from komira_http_core.codec.h2 import (
    FLAG_ACK,
    FLAG_END_HEADERS,
    FLAG_END_STREAM,
    FLAG_PADDED,
    FLAG_PRIORITY,
    FRAME_CONTINUATION,
    FRAME_DATA,
    FRAME_DECODE_ERROR,
    FRAME_DECODE_NEED_MORE,
    FRAME_GOAWAY,
    FRAME_HEADERS,
    FRAME_PING,
    FRAME_PRIORITY,
    FRAME_PUSH_PROMISE,
    FRAME_RST_STREAM,
    FRAME_SETTINGS,
    FRAME_WINDOW_UPDATE,
    FrameDecodeResult,
    FrameHeader,
    H2_ERR_FRAME_SIZE_ERROR,
    H2_ERR_NO_ERROR,
    H2_ERR_PROTOCOL_ERROR,
    MAX_FRAME_PAYLOAD_DEFAULT,
    MAX_FRAME_PAYLOAD_HARD_CAP,
    SettingsEntry,
    decode_frame,
    encode_data_frame,
    encode_frame_header,
    encode_goaway_frame,
    encode_headers_frame,
    encode_ping_frame,
    encode_settings_frame,
    encode_window_update_frame,
)
from komira_http_core.codec.h2.frame import FRAME_NONE, H2_ERR_CANCEL


# =============================================================================
# Helpers
# =============================================================================


def _b(*vals: Int) -> List[UInt8]:
    """The bytes `vals`, in order."""
    var out = List[UInt8]()
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))
    return out^


def _push(mut out: List[UInt8], *vals: Int):
    for i in range(len(vals)):
        out.append(UInt8(vals[i]))


def _zeros(mut out: List[UInt8], n: Int):
    for _ in range(n):
        out.append(UInt8(0))


def _decode(ref buf: List[UInt8]) -> FrameDecodeResult:
    return decode_frame(Span(buf), MAX_FRAME_PAYLOAD_DEFAULT)


def _assert_conn_error(dec: FrameDecodeResult, code: UInt32) raises:
    """A connection error (RFC 9113 §5.4.1) of `code`. The resync contract
    of FrameDecodeResult: a connection-scoped error consumes nothing and
    names no stream."""
    assert_equal(Int(dec.status), Int(FRAME_DECODE_ERROR))
    assert_equal(Int(dec.error_code), Int(code))
    assert_true(dec.is_connection_error)
    assert_equal(dec.consumed, 0)
    assert_equal(Int(dec.error_stream_id), 0)


def _assert_payload(dec: FrameDecodeResult, want: List[UInt8]) raises:
    assert_equal(len(dec.frame.payload), len(want))
    for i in range(len(want)):
        assert_equal(Int(dec.frame.payload[i]), Int(want[i]))


# =============================================================================
# RFC 9113 §4.1: the frame header
# =============================================================================


def test_defaults() raises:
    """A fresh header is the "no frame" sentinel; a fresh result is
    NEED_MORE with no error, so a caller reading an unset result never
    sees a frame or an error."""
    var h = FrameHeader()
    assert_equal(Int(h.kind), Int(FRAME_NONE))
    assert_equal(Int(h.length), 0)
    assert_equal(Int(h.flags), 0)
    assert_equal(Int(h.stream_id), 0)
    var r = FrameDecodeResult()
    assert_equal(Int(r.status), Int(FRAME_DECODE_NEED_MORE))
    assert_true(r.is_need_more())
    assert_false(r.is_ok())
    assert_false(r.is_error())
    assert_equal(Int(r.error_code), Int(H2_ERR_NO_ERROR))


def test_header_fields_big_endian_on_decode() raises:
    """§4.1: Length is 24 bits and Stream Identifier 31 bits, network
    order. Every byte of both is non-zero, so a swapped or dropped byte
    changes the value read (length 0x010203 needs a max frame size above
    the 2^14 default, §6.5.2, up to 2^24-1)."""
    var length = 0x010203
    var wire = List[UInt8]()
    _push(wire, 0x01, 0x02, 0x03, 0x16, 0x00, 0x12, 0x34, 0x56, 0x78)
    _zeros(wire, length)
    var dec = decode_frame(Span(wire), MAX_FRAME_PAYLOAD_HARD_CAP)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.length), length)
    assert_equal(Int(dec.frame.header.stream_id), 0x12345678)
    assert_equal(dec.consumed, 9 + length)
    assert_equal(len(dec.frame.payload), length)


def test_unknown_type_ignored_h2spec_4_1_1() raises:
    """§4.1 / §5.5: frames of unknown types MUST be ignored and discarded.
    h2spec http2/4.1/1's bytes: type 0x16, length 8, stream 0, eight zero
    payload bytes, then a PING whose data is all zero. The decoder returns
    the unknown frame as OK and consumes exactly it, so the PING decodes
    next."""
    var wire = List[UInt8]()
    _push(wire, 0x00, 0x00, 0x08, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00)
    _zeros(wire, 8)
    encode_ping_frame(SIMD[DType.uint8, 8](0), False, wire)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), 0x16)
    assert_equal(dec.consumed, 17)
    assert_equal(len(dec.frame.payload), 8)
    var nxt = decode_frame(Span(wire)[dec.consumed:], MAX_FRAME_PAYLOAD_DEFAULT)
    assert_true(nxt.is_ok())
    assert_equal(Int(nxt.frame.header.kind), Int(FRAME_PING))
    assert_equal(nxt.consumed, 17)


def test_unknown_type_keeps_raw_payload() raises:
    """§4.1 / §5.5: the same unknown-type frame as h2spec http2/4.1/1 but
    with distinct non-zero payload bytes (not h2spec's), so a dropped,
    reordered or zeroed payload byte shows. The PING after it carries data
    byte 7, read back to show the decoder resumed at the PING."""
    var wire = List[UInt8]()
    _push(wire, 0x00, 0x00, 0x08, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00)
    _push(wire, 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17)
    encode_ping_frame(SIMD[DType.uint8, 8](7), False, wire)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), 0x16)
    assert_equal(dec.consumed, 17)
    var want = _b(0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17)
    _assert_payload(dec, want)
    var nxt = decode_frame(Span(wire)[dec.consumed:], MAX_FRAME_PAYLOAD_DEFAULT)
    assert_true(nxt.is_ok())
    assert_equal(Int(nxt.frame.header.kind), Int(FRAME_PING))
    assert_equal(Int(nxt.frame.ping_data[7]), 7)


def test_unknown_type_on_a_stream_ignored() raises:
    """§4.1: an unknown type is ignored whatever its stream and flags:
    no stream-0 or flag rule of a known type applies to it."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(2), UInt8(0xfa), UInt8(0xff), UInt32(9), wire)
    _push(wire, 0xab, 0xcd)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.flags), 0xff)
    assert_equal(Int(dec.frame.header.stream_id), 9)
    var want = _b(0xab, 0xcd)
    _assert_payload(dec, want)


def test_undefined_flags_ignored_h2spec_4_1_2() raises:
    """§4.1: unused flags MUST be ignored on receipt. h2spec http2/4.1/2:
    a PING with flags 0x16 (0x01 ACK is not set) decodes as a PING, the
    flags kept as received."""
    var wire = _b(0x00, 0x00, 0x08, 0x06, 0x16, 0x00, 0x00, 0x00, 0x00)
    _zeros(wire, 8)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_PING))
    assert_equal(Int(dec.frame.header.flags), 0x16)


def test_reserved_bit_ignored_h2spec_4_1_3() raises:
    """§4.1: the reserved bit MUST be ignored when receiving. h2spec
    http2/4.1/3: a PING whose stream field is 0x80000000. With the bit
    masked the stream is 0 and the PING is valid; unmasked it would be
    stream 0x80000000 and a PING there is a PROTOCOL_ERROR (§6.7)."""
    var wire = _b(0x00, 0x00, 0x08, 0x06, 0x16, 0x80, 0x00, 0x00, 0x00)
    _zeros(wire, 8)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.stream_id), 0)


def test_encode_header_masks_length_and_reserved_bit() raises:
    """§4.1: Length is 24 bits; R MUST be unset when sending. The encoder
    keeps the low 24 bits of the length and the low 31 of the stream."""
    var out = List[UInt8]()
    encode_frame_header(
        UInt32(0x7fabcdef), FRAME_HEADERS, UInt8(0x25), UInt32(0xffffffff), out,
    )
    var want = _b(0xab, 0xcd, 0xef, 0x01, 0x25, 0x7f, 0xff, 0xff, 0xff)
    assert_equal(len(out), 9)
    for i in range(9):
        assert_equal(Int(out[i]), Int(want[i]))


def test_need_more_one_byte_short() raises:
    """A header one byte short, and a payload one byte short, are
    NEED_MORE (no error, nothing consumed); one more byte decodes."""
    var hdr = _b(0x00, 0x00, 0x00, 0x04, 0x01, 0x00, 0x00, 0x00)
    var r = _decode(hdr)
    assert_true(r.is_need_more())
    assert_equal(r.consumed, 0)
    var wire = List[UInt8]()
    encode_frame_header(UInt32(3), FRAME_DATA, UInt8(0), UInt32(1), wire)
    _push(wire, 1, 2)
    r = _decode(wire)
    assert_true(r.is_need_more())
    assert_equal(r.consumed, 0)
    wire.append(UInt8(3))
    r = _decode(wire)
    assert_true(r.is_ok())
    assert_equal(r.consumed, 12)


# =============================================================================
# RFC 9113 §4.2: frame size
# =============================================================================


def test_length_equal_to_max_accepted_h2spec_4_2_1() raises:
    """§4.2: a frame of exactly SETTINGS_MAX_FRAME_SIZE is allowed.
    h2spec http2/4.2/1: DATA with 2^14 octets."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(MAX_FRAME_PAYLOAD_DEFAULT), FRAME_DATA, FLAG_END_STREAM,
        UInt32(1), wire,
    )
    _zeros(wire, MAX_FRAME_PAYLOAD_DEFAULT)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(len(dec.frame.payload), MAX_FRAME_PAYLOAD_DEFAULT)


def test_headers_over_max_h2spec_4_2_3() raises:
    """§4.2: a frame over SETTINGS_MAX_FRAME_SIZE is a FRAME_SIZE_ERROR,
    a connection error for a frame that can alter connection state (a
    HEADERS frame does: h2spec http2/4.2/3). The limit is the argument,
    not the default: 5 bytes against a limit of 4 is refused before the
    payload arrives."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(5), FRAME_HEADERS, FLAG_END_HEADERS, UInt32(1), wire)
    var dec = decode_frame(Span(wire), 4)
    _assert_conn_error(dec, H2_ERR_FRAME_SIZE_ERROR)
    _zeros(wire, 5)
    dec = decode_frame(Span(wire), 5)
    assert_true(dec.is_ok())


# =============================================================================
# RFC 9113 §6.1: DATA
# =============================================================================


def test_data_padded() raises:
    """§6.1: with PADDED, the first byte is Pad Length and that many
    trailing bytes are padding, removed from the data."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(6), FRAME_DATA, FLAG_PADDED | FLAG_END_STREAM, UInt32(3), wire,
    )
    _push(wire, 2, 0x61, 0x62, 0x63, 0xee, 0xee)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.padding_length), 2)
    assert_equal(dec.consumed, 15)
    var want = _b(0x61, 0x62, 0x63)
    _assert_payload(dec, want)


def test_data_all_padding() raises:
    """§6.1: Pad Length one less than the payload length leaves no data;
    that is valid (only "the length of the frame payload or greater" is
    refused)."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_DATA, FLAG_PADDED, UInt32(3), wire)
    _push(wire, 3, 0, 0, 0)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.padding_length), 3)
    assert_equal(len(dec.frame.payload), 0)


def test_data_pad_length_equal_to_payload_length() raises:
    """§6.1: "If the length of the padding is the length of the frame
    payload or greater, the recipient MUST treat this as a connection
    error of type PROTOCOL_ERROR." The boundary: equal."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_DATA, FLAG_PADDED, UInt32(3), wire)
    _push(wire, 4, 0, 0, 0)
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def test_data_invalid_pad_length_h2spec_6_1_3() raises:
    """§6.1, h2spec http2/6.1/3: length 5, Pad Length 6."""
    var wire = _b(0x00, 0x00, 0x05, 0x00, 0x09, 0x00, 0x00, 0x00, 0x01)
    _push(wire, 0x06, 0x54, 0x65, 0x73, 0x74)
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def test_data_padded_empty_payload() raises:
    """§6.1: PADDED with a zero-length payload has no room for Pad Length.
    The input is exactly the 9-byte header and nothing after it, so a
    decoder that reads a Pad Length anyway reads one byte past the input:
    the `length == 0` check is what refuses this frame (with it disabled,
    the read aborts out of bounds). Refused as a connection PROTOCOL_ERROR.
    RFC 9113 §4.2 names FRAME_SIZE_ERROR for a frame "too small to contain
    mandatory frame data"; this pins today's code, a departure tracked in
    #866, so the fix for #866 flips this test on purpose."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(0), FRAME_DATA, FLAG_PADDED, UInt32(1), wire)
    assert_equal(len(wire), 9)
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def test_data_unpadded_keeps_pad_like_bytes() raises:
    """§6.1: without PADDED there is no Pad Length; every byte is data."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(2), FRAME_DATA, UInt8(0), UInt32(1), wire)
    _push(wire, 1, 0)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.padding_length), 0)
    var want = _b(1, 0)
    _assert_payload(dec, want)


def test_encode_data_flags() raises:
    """§6.1: END_STREAM (0x1) is set only when asked; the encoder emits no
    padding."""
    var a = List[UInt8]()
    encode_data_frame(UInt32(1), _b(9), True, a)
    assert_equal(Int(a[4]), Int(FLAG_END_STREAM))
    var b = List[UInt8]()
    encode_data_frame(UInt32(1), _b(9), False, b)
    assert_equal(Int(b[4]), 0)
    assert_equal(len(b), 10)


# =============================================================================
# RFC 9113 §6.2: HEADERS
# =============================================================================


def test_headers_stream_0_h2spec_6_2_3() raises:
    """§6.2: HEADERS on stream 0 is a connection PROTOCOL_ERROR
    (h2spec http2/6.2/3)."""
    var wire = List[UInt8]()
    encode_headers_frame(UInt32(0), _b(0x82), True, True, wire)
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def test_headers_invalid_pad_length_h2spec_6_2_4() raises:
    """§6.2, h2spec http2/6.2/4: flags 0x0d (END_STREAM, END_HEADERS,
    PADDED), length = fragment + 1, Pad Length = fragment + 2."""
    var frag = _b(0x82, 0x86, 0x84)
    var wire = _b(0x00, 0x00, len(frag) + 1, 0x01, 0x0d, 0x00, 0x00, 0x00, 0x01)
    wire.append(UInt8(len(frag) + 2))
    for i in range(len(frag)):
        wire.append(frag[i])
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def test_headers_pad_length_equal_to_payload_length() raises:
    """§6.2 (as §6.1): padding the length of the payload is refused."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(3), FRAME_HEADERS, FLAG_PADDED, UInt32(1), wire)
    _push(wire, 3, 0x82, 0)
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def test_headers_padded_empty_payload() raises:
    """§6.2: PADDED with no room for Pad Length; as DATA (see
    test_data_padded_empty_payload), the input ends at the 9-byte header so
    only the `length == 0` check stands between the decoder and a read past
    the input. Refused as PROTOCOL_ERROR today; §4.2 says FRAME_SIZE_ERROR,
    the departure tracked in #866."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(0), FRAME_HEADERS, FLAG_PADDED, UInt32(1), wire)
    assert_equal(len(wire), 9)
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def test_headers_padded() raises:
    """§6.2: Pad Length and padding are removed; the fragment is what is
    between them."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(5), FRAME_HEADERS, FLAG_PADDED | FLAG_END_HEADERS, UInt32(5), wire,
    )
    _push(wire, 2, 0x82, 0x84, 0xee, 0xee)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.padding_length), 2)
    var want = _b(0x82, 0x84)
    _assert_payload(dec, want)


def test_headers_priority_fields() raises:
    """§6.2: with PRIORITY, E (1 bit), Stream Dependency (31 bits) and
    Weight (8 bits) come before the fragment and are not part of it."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(7), FRAME_HEADERS, FLAG_PRIORITY | FLAG_END_HEADERS, UInt32(5), wire,
    )
    _push(wire, 0x81, 0x02, 0x03, 0x04, 0xc8, 0x82, 0x84)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_true(dec.frame.priority_exclusive)
    assert_equal(Int(dec.frame.priority_stream_dep), 0x01020304)
    assert_equal(Int(dec.frame.priority_weight), 0xc8)
    var want = _b(0x82, 0x84)
    _assert_payload(dec, want)


def test_headers_priority_not_exclusive() raises:
    """§6.2: E clear reads as not exclusive."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(5), FRAME_HEADERS, FLAG_PRIORITY, UInt32(5), wire)
    _push(wire, 0x00, 0x00, 0x00, 0x03, 0x10)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_false(dec.frame.priority_exclusive)
    assert_equal(Int(dec.frame.priority_stream_dep), 3)
    assert_equal(Int(dec.frame.priority_weight), 0x10)
    assert_equal(len(dec.frame.payload), 0)


def test_headers_padded_and_priority() raises:
    """§6.2: Pad Length, then the priority fields, then the fragment, then
    the padding."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(9), FRAME_HEADERS, FLAG_PADDED | FLAG_PRIORITY, UInt32(7), wire,
    )
    _push(wire, 1, 0x00, 0x00, 0x00, 0x05, 0x20, 0x82, 0x84, 0xee)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.padding_length), 1)
    assert_equal(Int(dec.frame.priority_stream_dep), 5)
    assert_equal(Int(dec.frame.priority_weight), 0x20)
    var want = _b(0x82, 0x84)
    _assert_payload(dec, want)


def test_headers_priority_too_short() raises:
    """§4.2: a frame too small for its mandatory fields is a
    FRAME_SIZE_ERROR. HEADERS with PRIORITY and 4 bytes cannot hold the 5
    priority bytes."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_HEADERS, FLAG_PRIORITY, UInt32(1), wire)
    _push(wire, 0, 0, 0, 3)
    _assert_conn_error(_decode(wire), H2_ERR_FRAME_SIZE_ERROR)


def test_headers_padding_leaves_no_room_for_priority() raises:
    """§4.2: PADDED and PRIORITY, 6 bytes, Pad Length 1: after the Pad
    Length and the padding 4 bytes remain, short of the 5 priority
    bytes."""
    var wire = List[UInt8]()
    encode_frame_header(
        UInt32(6), FRAME_HEADERS, FLAG_PADDED | FLAG_PRIORITY, UInt32(1), wire,
    )
    _push(wire, 1, 0, 0, 0, 3, 0)
    _assert_conn_error(_decode(wire), H2_ERR_FRAME_SIZE_ERROR)


def test_encode_headers_flags() raises:
    """§6.2: END_STREAM 0x1 and END_HEADERS 0x4, each only when asked."""
    var a = List[UInt8]()
    encode_headers_frame(UInt32(1), _b(0x82), True, True, a)
    assert_equal(Int(a[4]), 0x05)
    var b = List[UInt8]()
    encode_headers_frame(UInt32(1), _b(0x82), True, False, b)
    assert_equal(Int(b[4]), 0x01)
    var c = List[UInt8]()
    encode_headers_frame(UInt32(1), _b(0x82), False, False, c)
    assert_equal(Int(c[4]), 0x00)


# =============================================================================
# RFC 9113 §6.3: PRIORITY
# =============================================================================


def test_priority_decoded() raises:
    """§6.3: a 5-byte PRIORITY on a stream decodes its three fields."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(5), FRAME_PRIORITY, UInt8(0), UInt32(3), wire)
    _push(wire, 0x80, 0x00, 0x00, 0x05, 0x0f)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_true(dec.frame.priority_exclusive)
    assert_equal(Int(dec.frame.priority_stream_dep), 5)
    assert_equal(Int(dec.frame.priority_weight), 0x0f)
    wire[9] = UInt8(0x7f)
    dec = _decode(wire)
    assert_false(dec.frame.priority_exclusive)
    assert_equal(Int(dec.frame.priority_stream_dep), 0x7f000005)


def test_priority_stream_0_h2spec_6_3_1() raises:
    """§6.3: PRIORITY on stream 0 is a connection PROTOCOL_ERROR. h2spec
    http2/6.3/1: dependency 0, not exclusive, weight 255."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(5), FRAME_PRIORITY, UInt8(0), UInt32(0), wire)
    _push(wire, 0, 0, 0, 0, 0xff)
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def test_priority_wrong_length_is_stream_error_h2spec_6_3_2() raises:
    """§6.3: a length other than 5 is a STREAM error FRAME_SIZE_ERROR.
    h2spec http2/6.3/2 bytes. The stream error names the stream and
    consumes the whole frame, so the PING after it decodes next."""
    var wire = _b(0x00, 0x00, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00, 0x01)
    _push(wire, 0x80, 0x00, 0x00, 0x01)
    encode_ping_frame(SIMD[DType.uint8, 8](1), False, wire)
    var dec = _decode(wire)
    assert_equal(Int(dec.status), Int(FRAME_DECODE_ERROR))
    assert_equal(Int(dec.error_code), Int(H2_ERR_FRAME_SIZE_ERROR))
    assert_false(dec.is_connection_error)
    assert_equal(Int(dec.error_stream_id), 1)
    assert_equal(dec.consumed, 13)
    var nxt = decode_frame(Span(wire)[dec.consumed:], MAX_FRAME_PAYLOAD_DEFAULT)
    assert_true(nxt.is_ok())
    assert_equal(Int(nxt.frame.header.kind), Int(FRAME_PING))


# =============================================================================
# RFC 9113 §6.4: RST_STREAM
# =============================================================================


def test_rst_stream_error_code_big_endian() raises:
    """§6.4: the 32-bit error code, network order, every byte non-zero."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_RST_STREAM, UInt8(0), UInt32(1), wire)
    _push(wire, 0x01, 0x02, 0x03, 0x04)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.rst_error_code), 0x01020304)


def test_rst_stream_stream_0_h2spec_6_4_1() raises:
    """§6.4: RST_STREAM on stream 0 is a connection PROTOCOL_ERROR
    (h2spec http2/6.4/1: error code CANCEL)."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_RST_STREAM, UInt8(0), UInt32(0), wire)
    _push(wire, 0, 0, 0, Int(H2_ERR_CANCEL))
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def test_rst_stream_wrong_length_h2spec_6_4_3() raises:
    """§6.4: a length other than 4 is a connection FRAME_SIZE_ERROR
    (h2spec http2/6.4/3 bytes)."""
    var wire = _b(0x00, 0x00, 0x03, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01)
    _push(wire, 0x00, 0x00, 0x00)
    _assert_conn_error(_decode(wire), H2_ERR_FRAME_SIZE_ERROR)


# =============================================================================
# RFC 9113 §6.5: SETTINGS
# =============================================================================


def test_settings_entries_big_endian() raises:
    """§6.5.1: each entry is a 16-bit identifier and a 32-bit value,
    network order; every entry is read, in order. An unknown identifier
    is kept (§6.5.2: the receiver ignores it, the decoder does not
    refuse it)."""
    var entries = List[SettingsEntry]()
    entries.append(SettingsEntry(identifier=UInt16(0x0102), value=UInt32(0x0a0b0c0d)))
    entries.append(SettingsEntry(identifier=UInt16(0x0003), value=UInt32(100)))
    entries.append(SettingsEntry(identifier=UInt16(0xff00), value=UInt32(0xffffffff)))
    var wire = List[UInt8]()
    encode_settings_frame(entries^, wire)
    assert_equal(len(wire), 27)
    var want = _b(0x01, 0x02, 0x0a, 0x0b, 0x0c, 0x0d)
    for i in range(6):
        assert_equal(Int(wire[9 + i]), Int(want[i]))
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(len(dec.frame.settings), 3)
    assert_equal(Int(dec.frame.settings[0].identifier), 0x0102)
    assert_equal(Int(dec.frame.settings[0].value), 0x0a0b0c0d)
    assert_equal(Int(dec.frame.settings[1].identifier), 3)
    assert_equal(Int(dec.frame.settings[1].value), 100)
    assert_equal(Int(dec.frame.settings[2].identifier), 0xff00)
    assert_equal(Int(dec.frame.settings[2].value), 0xffffffff)


def test_settings_empty_non_ack() raises:
    """§6.5: a SETTINGS frame with no parameters is valid."""
    var wire = List[UInt8]()
    encode_settings_frame(List[SettingsEntry](), wire)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(len(dec.frame.settings), 0)


def test_settings_refusals_h2spec_6_5() raises:
    """§6.5, h2spec http2/6.5/1 (ACK with a 1-byte payload:
    FRAME_SIZE_ERROR), 6.5/2 (stream 1: PROTOCOL_ERROR), 6.5/3 (length 3:
    FRAME_SIZE_ERROR); all connection errors."""
    var a = _b(0x00, 0x00, 0x01, 0x04, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00)
    _assert_conn_error(_decode(a), H2_ERR_FRAME_SIZE_ERROR)
    var b = _b(0x00, 0x00, 0x06, 0x04, 0x00, 0x00, 0x00, 0x00, 0x01)
    _push(b, 0x00, 0x03, 0x00, 0x00, 0x00, 0x64)
    _assert_conn_error(_decode(b), H2_ERR_PROTOCOL_ERROR)
    var c = _b(0x00, 0x00, 0x03, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00)
    _push(c, 0x00, 0x03, 0x00)
    _assert_conn_error(_decode(c), H2_ERR_FRAME_SIZE_ERROR)


# =============================================================================
# RFC 9113 §6.6: PUSH_PROMISE
# =============================================================================


def test_push_promise_refused() raises:
    """§8.4: a client cannot push, so a server MUST treat PUSH_PROMISE as a
    connection PROTOCOL_ERROR; this codec also runs with push disabled
    (§6.5.2 SETTINGS_ENABLE_PUSH 0), so it refuses it in either role."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_PUSH_PROMISE, FLAG_END_HEADERS, UInt32(1), wire)
    _push(wire, 0, 0, 0, 2)
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


# =============================================================================
# RFC 9113 §6.7: PING
# =============================================================================


def test_ping_payload_and_ack_h2spec_6_7_1() raises:
    """§6.7: 8 opaque bytes, all kept in order (h2spec http2/6.7/1's
    payload "h2spec"); the ACK reply carries flag 0x1, a request none."""
    var data = SIMD[DType.uint8, 8](0)
    var text = _b(0x68, 0x32, 0x73, 0x70, 0x65, 0x63, 0x00, 0x00)
    for i in range(8):
        data[i] = text[i]
    var wire = List[UInt8]()
    encode_ping_frame(data, True, wire)
    assert_equal(Int(wire[4]), Int(FLAG_ACK))
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    for i in range(8):
        assert_equal(Int(dec.frame.ping_data[i]), Int(text[i]))
    var req = List[UInt8]()
    encode_ping_frame(data, False, req)
    assert_equal(Int(req[4]), 0)


def test_ping_refusals_h2spec_6_7() raises:
    """§6.7, h2spec http2/6.7/3 (stream 1: PROTOCOL_ERROR) and 6.7/4
    (length 6: FRAME_SIZE_ERROR), both connection errors."""
    var a = _b(0x00, 0x00, 0x08, 0x06, 0x00, 0x00, 0x00, 0x00, 0x01)
    _zeros(a, 8)
    _assert_conn_error(_decode(a), H2_ERR_PROTOCOL_ERROR)
    var b = _b(0x00, 0x00, 0x06, 0x06, 0x00, 0x00, 0x00, 0x00, 0x00)
    _zeros(b, 6)
    _assert_conn_error(_decode(b), H2_ERR_FRAME_SIZE_ERROR)


# =============================================================================
# RFC 9113 §6.8: GOAWAY
# =============================================================================


def test_goaway_fields() raises:
    """§6.8: R + Last-Stream-ID (31 bits), Error Code (32 bits), then
    Additional Debug Data. The reserved bit is ignored on receipt and
    unset on send; every byte non-zero to pin the order."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(10), FRAME_GOAWAY, UInt8(0), UInt32(0), wire)
    _push(wire, 0x81, 0x02, 0x03, 0x04, 0x0a, 0x0b, 0x0c, 0x0d, 0x64, 0x67)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.goaway_last_stream_id), 0x01020304)
    assert_equal(Int(dec.frame.goaway_error_code), 0x0a0b0c0d)
    var want = _b(0x64, 0x67)
    _assert_payload(dec, want)
    var out = List[UInt8]()
    encode_goaway_frame(UInt32(0xffffffff), UInt32(0x0a0b0c0d), List[UInt8](), out)
    assert_equal(len(out), 17)
    var enc = _b(0x7f, 0xff, 0xff, 0xff, 0x0a, 0x0b, 0x0c, 0x0d)
    for i in range(8):
        assert_equal(Int(out[9 + i]), Int(enc[i]))


def test_goaway_without_debug_data() raises:
    """§6.8: 8 bytes, no debug data, is the smallest valid GOAWAY."""
    var wire = List[UInt8]()
    encode_goaway_frame(UInt32(3), H2_ERR_NO_ERROR, List[UInt8](), wire)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.goaway_last_stream_id), 3)
    assert_equal(len(dec.frame.payload), 0)


def test_goaway_refusals() raises:
    """§6.8, h2spec http2/6.8/1: GOAWAY on stream 1 is a connection
    PROTOCOL_ERROR. §4.2: 7 bytes cannot hold the 8 mandatory ones, a
    connection FRAME_SIZE_ERROR."""
    var a = _b(0x00, 0x00, 0x08, 0x07, 0x00, 0x00, 0x00, 0x00, 0x01)
    _zeros(a, 8)
    _assert_conn_error(_decode(a), H2_ERR_PROTOCOL_ERROR)
    var b = List[UInt8]()
    encode_frame_header(UInt32(7), FRAME_GOAWAY, UInt8(0), UInt32(0), b)
    _zeros(b, 7)
    _assert_conn_error(_decode(b), H2_ERR_FRAME_SIZE_ERROR)


# =============================================================================
# RFC 9113 §6.9: WINDOW_UPDATE
# =============================================================================


def test_window_update_reserved_bit_ignored() raises:
    """§6.9: R + Window Size Increment (31 bits). The reserved bit is
    ignored on receipt (increment 0x80000001 reads 1) and unset on send;
    every byte non-zero to pin the order."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_WINDOW_UPDATE, UInt8(0), UInt32(1), wire)
    _push(wire, 0x80, 0x00, 0x00, 0x01)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.window_update_increment), 1)
    wire[9] = UInt8(0x01)
    wire[10] = UInt8(0x02)
    wire[11] = UInt8(0x03)
    wire[12] = UInt8(0x04)
    dec = _decode(wire)
    assert_equal(Int(dec.frame.window_update_increment), 0x01020304)
    var out = List[UInt8]()
    encode_window_update_frame(UInt32(1), UInt32(0xffffffff), out)
    var want = _b(0x7f, 0xff, 0xff, 0xff)
    for i in range(4):
        assert_equal(Int(out[9 + i]), Int(want[i]))


def test_window_update_only_reserved_bit_is_zero_increment() raises:
    """§6.9: an increment of 0 is a PROTOCOL_ERROR; with the reserved
    bit ignored, 0x80000000 is an increment of 0. On stream 0 that is a
    connection error (h2spec http2/6.9/1 is the bare-zero case).

    `consumed` is the whole frame (13), not the 0 every other connection
    error returns (`_assert_conn_error`) and FrameDecodeResult's doc
    promises: the WINDOW_UPDATE arms set `consumed = total` for both
    scopes. Pinned as today's value so a change to it is deliberate."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_WINDOW_UPDATE, UInt8(0), UInt32(0), wire)
    _push(wire, 0x80, 0x00, 0x00, 0x00)
    var dec = _decode(wire)
    assert_equal(Int(dec.status), Int(FRAME_DECODE_ERROR))
    assert_equal(Int(dec.error_code), Int(H2_ERR_PROTOCOL_ERROR))
    assert_true(dec.is_connection_error)
    assert_equal(Int(dec.error_stream_id), 0)
    assert_equal(dec.consumed, 13)


def test_window_update_zero_on_stream_resyncs_h2spec_6_9_2() raises:
    """§6.9 / §5.4.2, h2spec http2/6.9/2: increment 0 on a stream is a
    stream error of type PROTOCOL_ERROR; it consumes the frame (13 bytes)
    and names the stream."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(4), FRAME_WINDOW_UPDATE, UInt8(0), UInt32(1), wire)
    _zeros(wire, 4)
    var dec = _decode(wire)
    assert_equal(Int(dec.status), Int(FRAME_DECODE_ERROR))
    assert_equal(Int(dec.error_code), Int(H2_ERR_PROTOCOL_ERROR))
    assert_false(dec.is_connection_error)
    assert_equal(Int(dec.error_stream_id), 1)
    assert_equal(dec.consumed, 13)


def test_window_update_wrong_length_h2spec_6_9_3() raises:
    """§6.9: a length other than 4 is a connection FRAME_SIZE_ERROR
    (h2spec http2/6.9/3 bytes: length 3, stream 0).

    As in test_window_update_only_reserved_bit_is_zero_increment, this
    connection arm sets `consumed` to the whole frame (12), unlike the
    other connection arms, which consume 0. Pinned as today's value."""
    var wire = _b(0x00, 0x00, 0x03, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00)
    _push(wire, 0x00, 0x00, 0x01)
    var dec = _decode(wire)
    assert_equal(Int(dec.status), Int(FRAME_DECODE_ERROR))
    assert_equal(Int(dec.error_code), Int(H2_ERR_FRAME_SIZE_ERROR))
    assert_true(dec.is_connection_error)
    assert_equal(Int(dec.error_stream_id), 0)
    assert_equal(dec.consumed, 12)


# =============================================================================
# RFC 9113 §6.10: CONTINUATION
# =============================================================================


def test_continuation_payload() raises:
    """§6.10: the payload is a field block fragment, kept whole."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(3), FRAME_CONTINUATION, FLAG_END_HEADERS, UInt32(1), wire)
    _push(wire, 0x82, 0x84, 0x86)
    var dec = _decode(wire)
    assert_true(dec.is_ok())
    assert_equal(Int(dec.frame.header.kind), Int(FRAME_CONTINUATION))
    var want = _b(0x82, 0x84, 0x86)
    _assert_payload(dec, want)


def test_continuation_stream_0_h2spec_6_10_3() raises:
    """§6.10: CONTINUATION on stream 0 is a connection PROTOCOL_ERROR
    (h2spec http2/6.10/3)."""
    var wire = List[UInt8]()
    encode_frame_header(UInt32(1), FRAME_CONTINUATION, FLAG_END_HEADERS, UInt32(0), wire)
    wire.append(UInt8(0x82))
    _assert_conn_error(_decode(wire), H2_ERR_PROTOCOL_ERROR)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
