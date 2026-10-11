# =============================================================================
# src/komira_http_core/codec/h2/frame.mojo — RFC 9113 HTTP/2 frame codec
# =============================================================================
#
#
# Pure-functional H2 frame encode/decode. Discriminator-tagged POD `Frame`
# struct with per-variant flat fields. Frames are in-flight pass-by-value;
# never accumulated in byte-backed slabs (pointer safety).
#
# Encode/decode bodies plus the type surface and constants downstream
# modules import.
#
# No UnsafePointer in any public sig. No wildcard origin. No
# `unsafe_from_address`.
# =============================================================================


# =============================================================================
# §1 — Frame type discriminator (RFC 9113 §6).
# =============================================================================

comptime FRAME_DATA: UInt8 = 0x00
comptime FRAME_HEADERS: UInt8 = 0x01
comptime FRAME_PRIORITY: UInt8 = 0x02
comptime FRAME_RST_STREAM: UInt8 = 0x03
comptime FRAME_SETTINGS: UInt8 = 0x04
comptime FRAME_PUSH_PROMISE: UInt8 = 0x05
comptime FRAME_PING: UInt8 = 0x06
comptime FRAME_GOAWAY: UInt8 = 0x07
comptime FRAME_WINDOW_UPDATE: UInt8 = 0x08
comptime FRAME_CONTINUATION: UInt8 = 0x09

# Sentinel for "uninitialized" frame.
comptime FRAME_NONE: UInt8 = 0xff


# =============================================================================
# §2 — Frame flags (per-type meaning).
# =============================================================================

comptime FLAG_ACK: UInt8 = 0x01          # SETTINGS / PING
comptime FLAG_END_STREAM: UInt8 = 0x01   # DATA / HEADERS
comptime FLAG_END_HEADERS: UInt8 = 0x04  # HEADERS / CONTINUATION / PUSH_PROMISE
comptime FLAG_PADDED: UInt8 = 0x08       # DATA / HEADERS / PUSH_PROMISE
comptime FLAG_PRIORITY: UInt8 = 0x20     # HEADERS


# =============================================================================
# §3 — Frame size limits (RFC 9113 §4.2 + §6.5.2).
# =============================================================================

comptime MAX_FRAME_PAYLOAD_DEFAULT: Int = 16384       # 2**14 default initial
comptime MAX_FRAME_PAYLOAD_HARD_CAP: Int = 16777215   # 2**24 - 1 max settable


# =============================================================================
# §4 — HTTP/2 error codes (RFC 9113 §7).
# =============================================================================

comptime H2_ERR_NO_ERROR: UInt32 = 0x0
comptime H2_ERR_PROTOCOL_ERROR: UInt32 = 0x1
comptime H2_ERR_INTERNAL_ERROR: UInt32 = 0x2
comptime H2_ERR_FLOW_CONTROL_ERROR: UInt32 = 0x3
comptime H2_ERR_SETTINGS_TIMEOUT: UInt32 = 0x4
comptime H2_ERR_STREAM_CLOSED: UInt32 = 0x5
comptime H2_ERR_FRAME_SIZE_ERROR: UInt32 = 0x6
comptime H2_ERR_REFUSED_STREAM: UInt32 = 0x7
comptime H2_ERR_CANCEL: UInt32 = 0x8
comptime H2_ERR_COMPRESSION_ERROR: UInt32 = 0x9
comptime H2_ERR_CONNECT_ERROR: UInt32 = 0xa
comptime H2_ERR_ENHANCE_YOUR_CALM: UInt32 = 0xb
comptime H2_ERR_INADEQUATE_SECURITY: UInt32 = 0xc
comptime H2_ERR_HTTP_1_1_REQUIRED: UInt32 = 0xd


# =============================================================================
# §5 — SETTINGS identifiers (RFC 9113 §6.5.2).
# =============================================================================

comptime SETTINGS_HEADER_TABLE_SIZE: UInt16 = 0x1
comptime SETTINGS_ENABLE_PUSH: UInt16 = 0x2
comptime SETTINGS_MAX_CONCURRENT_STREAMS: UInt16 = 0x3
comptime SETTINGS_INITIAL_WINDOW_SIZE: UInt16 = 0x4
comptime SETTINGS_MAX_FRAME_SIZE: UInt16 = 0x5
comptime SETTINGS_MAX_HEADER_LIST_SIZE: UInt16 = 0x6


# =============================================================================
# §6 — FrameHeader (9-byte fixed prefix; RFC 9113 §4.1).
# =============================================================================


@fieldwise_init
struct FrameHeader(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """The 9-byte frame header.

    Wire format (RFC 9113 §4.1):
        Length    (24 bits, network-order)
        Type      ( 8 bits)
        Flags     ( 8 bits)
        R         ( 1 bit, reserved, MUST be 0 on send, MUST be ignored on recv)
        Stream ID (31 bits, network-order)

    `length` is the payload byte count (NOT including the 9-byte header).
    `stream_id` is the 31-bit stream identifier with R bit masked off.
    """

    var length: UInt32      # 24 bits used; high 8 always 0
    var kind: UInt8
    var flags: UInt8
    var stream_id: UInt32   # 31 bits used; high bit (R) always 0

    def __init__(out self):
        self.length = UInt32(0)
        self.kind = FRAME_NONE
        self.flags = UInt8(0)
        self.stream_id = UInt32(0)


# =============================================================================
# §7 — SettingsEntry (one (identifier, value) pair).
# =============================================================================


@fieldwise_init
struct SettingsEntry(
    Copyable, ImplicitlyCopyable, Movable, Deinitable,
):
    """One SETTINGS parameter (RFC 9113 §6.5.1)."""
    var identifier: UInt16
    var value: UInt32


# =============================================================================
# §8 — Frame (discriminator-tagged container for any frame variant).
# =============================================================================


struct Frame(Movable, Deinitable):
    """Decoded HTTP/2 frame.

    Discriminator-tagged: `header.kind` selects which fields are populated.
    `payload` carries the variant-specific body bytes for HEADERS /
    CONTINUATION / DATA / PUSH_PROMISE. Fixed-format frames (PING,
    RST_STREAM, GOAWAY, WINDOW_UPDATE) populate the typed scalar fields.

    Movable, NOT Copyable — `payload: List[UInt8]` owns heap.

    Pointer safety: Frame is in-flight pass-by-value; the H2 connection driver
    decodes one frame at a time and discards. NOT stored in byte-backed
    slabs (which would be the stale-pointer trap shape for `List[UInt8]`-fielded
    Movable).
    """

    var header: FrameHeader
    var payload: List[UInt8]  # block fragment (HEADERS/CONTINUATION/PUSH_PROMISE) or DATA bytes

    # PING: 8 bytes opaque data.
    var ping_data: SIMD[DType.uint8, 8]

    # RST_STREAM: error code.
    var rst_error_code: UInt32

    # GOAWAY: last-stream-id + error code + debug-data (lives in `payload`).
    var goaway_last_stream_id: UInt32
    var goaway_error_code: UInt32

    # WINDOW_UPDATE: increment (31 bits).
    var window_update_increment: UInt32

    # SETTINGS: list of (id, value) pairs.
    var settings: List[SettingsEntry]

    # HEADERS/DATA padding length (0 if not padded).
    var padding_length: UInt8

    # HEADERS priority fields (if FLAG_PRIORITY set; parses but ignores).
    var priority_exclusive: Bool
    var priority_stream_dep: UInt32
    var priority_weight: UInt8

    def __init__(out self):
        self.header = FrameHeader()
        self.payload = List[UInt8]()
        self.ping_data = SIMD[DType.uint8, 8](0)
        self.rst_error_code = UInt32(0)
        self.goaway_last_stream_id = UInt32(0)
        self.goaway_error_code = UInt32(0)
        self.window_update_increment = UInt32(0)
        self.settings = List[SettingsEntry]()
        self.padding_length = UInt8(0)
        self.priority_exclusive = False
        self.priority_stream_dep = UInt32(0)
        self.priority_weight = UInt8(0)


# =============================================================================
# §9 — FrameDecodeResult (encoder/decoder outcome wrapper).
# =============================================================================


comptime FRAME_DECODE_OK: UInt8 = 0
comptime FRAME_DECODE_NEED_MORE: UInt8 = 1
comptime FRAME_DECODE_ERROR: UInt8 = 2


struct FrameDecodeResult(Movable, Deinitable):
    """Outcome of decode_frame.

    On OK: `frame` is populated; `consumed` is bytes consumed from input.
    On NEED_MORE: caller should read more bytes + retry.
    On ERROR: `error_code` (H2_ERR_*) + `is_connection_error` (vs stream)
    indicate how to respond on-wire. `error_stream_id` is the stream
    affected (0 if connection error or N/A).

    ★ `consumed` ON ERROR IS THE RESYNCHRONISATION CONTRACT, and it is the
    difference between the two scopes rather than a bookkeeping detail:

      * STREAM-scoped error  -> `consumed == 9 + length`. The whole offending
        frame was in the input, so the caller skips it, answers with
        RST_STREAM(`error_stream_id`), and KEEPS DECODING. RFC 9113 §5.4.2:
        a stream error does not disturb the connection, and on a pooled h2
        connection the other N-1 multiplexed requests are still running.
      * CONNECTION-scoped error -> `consumed == 0`. There is no next frame
        to resynchronise to; the caller emits GOAWAY and stops.

    A caller that answers every decode error with GOAWAY throws this
    distinction away -- the severity inversion this contract exists to
    prevent.
    """

    var status: UInt8
    var frame: Frame
    var consumed: Int
    var error_code: UInt32
    var is_connection_error: Bool
    var error_stream_id: UInt32

    def __init__(out self):
        self.status = FRAME_DECODE_NEED_MORE
        self.frame = Frame()
        self.consumed = 0
        self.error_code = H2_ERR_NO_ERROR
        self.is_connection_error = False
        self.error_stream_id = UInt32(0)

    def is_ok(self) -> Bool:
        return self.status == FRAME_DECODE_OK

    def is_need_more(self) -> Bool:
        return self.status == FRAME_DECODE_NEED_MORE

    def is_error(self) -> Bool:
        return self.status == FRAME_DECODE_ERROR


# =============================================================================
# §10 — Big-endian helpers (private, file-scope).
# =============================================================================


def _read_u24_be(buf: Span[UInt8, _], off: Int) -> UInt32:
    """Read a 24-bit big-endian unsigned integer at `buf[off:off+3]`."""
    var b0 = UInt32(Int(buf[off]))
    var b1 = UInt32(Int(buf[off + 1]))
    var b2 = UInt32(Int(buf[off + 2]))
    return (b0 << 16) | (b1 << 8) | b2


def _read_u32_be(buf: Span[UInt8, _], off: Int) -> UInt32:
    """Read a 32-bit big-endian unsigned integer at `buf[off:off+4]`."""
    var b0 = UInt32(Int(buf[off]))
    var b1 = UInt32(Int(buf[off + 1]))
    var b2 = UInt32(Int(buf[off + 2]))
    var b3 = UInt32(Int(buf[off + 3]))
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3


def _write_u24_be(value: UInt32, mut out: List[UInt8]):
    """Append a 24-bit big-endian unsigned integer to `out`."""
    out.append(UInt8(Int((value >> 16) & UInt32(0xff))))
    out.append(UInt8(Int((value >> 8) & UInt32(0xff))))
    out.append(UInt8(Int(value & UInt32(0xff))))


def _write_u32_be(value: UInt32, mut out: List[UInt8]):
    """Append a 32-bit big-endian unsigned integer to `out`."""
    out.append(UInt8(Int((value >> 24) & UInt32(0xff))))
    out.append(UInt8(Int((value >> 16) & UInt32(0xff))))
    out.append(UInt8(Int((value >> 8) & UInt32(0xff))))
    out.append(UInt8(Int(value & UInt32(0xff))))


# =============================================================================
# §11 — Public frame codec API (bodies land in).
# =============================================================================


def encode_frame_header(
    length: UInt32,
    kind: UInt8,
    flags: UInt8,
    stream_id: UInt32,
    mut out: List[UInt8],
):
    """Serialize a 9-byte frame header into `out`.

    `length` must fit in 24 bits. `stream_id` MSB (R bit) is masked off
    by the encoder per RFC 9113 §4.1.
    """
    _write_u24_be(length & UInt32(0x00ffffff), out)
    out.append(kind)
    out.append(flags)
    _write_u32_be(stream_id & UInt32(0x7fffffff), out)


def decode_frame(
    buf: Span[UInt8, _],
    max_frame_size: Int,
) -> FrameDecodeResult:
    """Decode one H2 frame from `buf[0:]`.

    Returns NEED_MORE if `len(buf) < 9 + payload-length`. Validates length
    against `max_frame_size` (SETTINGS_MAX_FRAME_SIZE) — overflow is a
    FRAME_SIZE_ERROR connection error per RFC 9113 §4.2.

    Frame-type-specific payload validation (e.g., SETTINGS payload %% 6 == 0;
    WINDOW_UPDATE increment != 0; etc.) is performed inline.

    fills in the per-frame-type decode bodies.
    """
    var out = FrameDecodeResult()
    var n = len(buf)
    if n < 9:
        out.status = FRAME_DECODE_NEED_MORE
        return out^

    var length = _read_u24_be(buf, 0)
    var kind = buf[3]
    var flags = buf[4]
    var sid_raw = _read_u32_be(buf, 5)
    var stream_id = sid_raw & UInt32(0x7fffffff)

    # Frame-size validation (RFC 9113 §4.2 / §6.5.2): payload length must
    # fit within current SETTINGS_MAX_FRAME_SIZE (peer's value; we advertise
    # ours). On exceed, FRAME_SIZE_ERROR connection error.
    if Int(length) > max_frame_size:
        out.status = FRAME_DECODE_ERROR
        out.error_code = H2_ERR_FRAME_SIZE_ERROR
        out.is_connection_error = True
        return out^

    var total = 9 + Int(length)
    if n < total:
        out.status = FRAME_DECODE_NEED_MORE
        return out^

    out.frame.header = FrameHeader(
        length=length, kind=kind, flags=flags, stream_id=stream_id,
    )

    var payload_off = 9
    var payload_end = total

    # ---- Per-frame-type decode.

    if kind == FRAME_DATA:
        if stream_id == UInt32(0):
            # DATA on stream 0 is a connection PROTOCOL_ERROR (RFC 9113 §6.1).
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_PROTOCOL_ERROR
            out.is_connection_error = True
            return out^
        var po = payload_off
        var pe = payload_end
        if (flags & FLAG_PADDED) != UInt8(0):
            if length == UInt32(0):
                # No room for the Pad Length octet. RFC 9113 §4.2: a frame
                # "too small to contain mandatory frame data" is a
                # FRAME_SIZE_ERROR; answered as a connection error.
                out.status = FRAME_DECODE_ERROR
                out.error_code = H2_ERR_FRAME_SIZE_ERROR
                out.is_connection_error = True
                return out^
            var pad_len = Int(buf[po])
            if pad_len >= Int(length):
                out.status = FRAME_DECODE_ERROR
                out.error_code = H2_ERR_PROTOCOL_ERROR
                out.is_connection_error = True
                return out^
            out.frame.padding_length = UInt8(pad_len)
            po = po + 1
            pe = pe - pad_len
        var i = po
        while i < pe:
            out.frame.payload.append(buf[i])
            i = i + 1
    elif kind == FRAME_HEADERS:
        if stream_id == UInt32(0):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_PROTOCOL_ERROR
            out.is_connection_error = True
            return out^
        var po = payload_off
        var pe = payload_end
        if (flags & FLAG_PADDED) != UInt8(0):
            if length == UInt32(0):
                # No room for the Pad Length octet. RFC 9113 §4.2: a frame
                # "too small to contain mandatory frame data" is a
                # FRAME_SIZE_ERROR; answered as a connection error.
                out.status = FRAME_DECODE_ERROR
                out.error_code = H2_ERR_FRAME_SIZE_ERROR
                out.is_connection_error = True
                return out^
            var pad_len = Int(buf[po])
            if pad_len >= Int(length):
                out.status = FRAME_DECODE_ERROR
                out.error_code = H2_ERR_PROTOCOL_ERROR
                out.is_connection_error = True
                return out^
            out.frame.padding_length = UInt8(pad_len)
            po = po + 1
            pe = pe - pad_len
        if (flags & FLAG_PRIORITY) != UInt8(0):
            if pe - po < 5:
                out.status = FRAME_DECODE_ERROR
                out.error_code = H2_ERR_FRAME_SIZE_ERROR
                out.is_connection_error = True
                return out^
            var sd_raw = _read_u32_be(buf, po)
            out.frame.priority_exclusive = (
                (sd_raw & UInt32(0x80000000)) != UInt32(0)
            )
            out.frame.priority_stream_dep = sd_raw & UInt32(0x7fffffff)
            out.frame.priority_weight = buf[po + 4]
            po = po + 5
        var i = po
        while i < pe:
            out.frame.payload.append(buf[i])
            i = i + 1
    elif kind == FRAME_PRIORITY:
        # RFC 9113 §6.3: PRIORITY is always 5 bytes; deprecated but parsed.
        if length != UInt32(5):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_FRAME_SIZE_ERROR
            out.is_connection_error = False
            out.error_stream_id = stream_id
            # ★ A STREAM-SCOPED ERROR MUST BE RESYNCHRONISABLE. `n >= total`
            # was established above, so the whole offending frame is in `buf`
            # and the caller can skip exactly `consumed` bytes and carry on
            # decoding the NEXT frame -- which is what "stream error" means
            # (RFC 9113 §5.4.2: the connection is NOT torn down). A
            # connection-scoped error deliberately leaves `consumed == 0`:
            # there is no "next frame" to resynchronise to.
            out.consumed = total
            return out^
        if stream_id == UInt32(0):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_PROTOCOL_ERROR
            out.is_connection_error = True
            return out^
        var sd_raw = _read_u32_be(buf, payload_off)
        out.frame.priority_exclusive = (
            (sd_raw & UInt32(0x80000000)) != UInt32(0)
        )
        out.frame.priority_stream_dep = sd_raw & UInt32(0x7fffffff)
        out.frame.priority_weight = buf[payload_off + 4]
    elif kind == FRAME_RST_STREAM:
        if length != UInt32(4):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_FRAME_SIZE_ERROR
            out.is_connection_error = True
            return out^
        if stream_id == UInt32(0):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_PROTOCOL_ERROR
            out.is_connection_error = True
            return out^
        out.frame.rst_error_code = _read_u32_be(buf, payload_off)
    elif kind == FRAME_SETTINGS:
        if stream_id != UInt32(0):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_PROTOCOL_ERROR
            out.is_connection_error = True
            return out^
        if (flags & FLAG_ACK) != UInt8(0):
            # ACK MUST be zero-length per RFC 9113 §6.5.
            if length != UInt32(0):
                out.status = FRAME_DECODE_ERROR
                out.error_code = H2_ERR_FRAME_SIZE_ERROR
                out.is_connection_error = True
                return out^
        else:
            # Body must be a multiple of 6 bytes.
            if (Int(length) % 6) != 0:
                out.status = FRAME_DECODE_ERROR
                out.error_code = H2_ERR_FRAME_SIZE_ERROR
                out.is_connection_error = True
                return out^
            var num_entries = Int(length) // 6
            var i = 0
            while i < num_entries:
                var ent_off = payload_off + i * 6
                var ident = (
                    (UInt16(Int(buf[ent_off])) << 8)
                    | UInt16(Int(buf[ent_off + 1]))
                )
                var val = _read_u32_be(buf, ent_off + 2)
                out.frame.settings.append(SettingsEntry(
                    identifier=ident, value=val,
                ))
                i = i + 1
    elif kind == FRAME_PUSH_PROMISE:
        # server does not push; per RFC 9113 §8.4 if push is disabled, the
        # peer MUST NOT send PUSH_PROMISE. Treat as PROTOCOL_ERROR.
        out.status = FRAME_DECODE_ERROR
        out.error_code = H2_ERR_PROTOCOL_ERROR
        out.is_connection_error = True
        return out^
    elif kind == FRAME_PING:
        if length != UInt32(8):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_FRAME_SIZE_ERROR
            out.is_connection_error = True
            return out^
        if stream_id != UInt32(0):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_PROTOCOL_ERROR
            out.is_connection_error = True
            return out^
        var j = 0
        while j < 8:
            out.frame.ping_data[j] = buf[payload_off + j]
            j = j + 1
    elif kind == FRAME_GOAWAY:
        if length < UInt32(8):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_FRAME_SIZE_ERROR
            out.is_connection_error = True
            return out^
        if stream_id != UInt32(0):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_PROTOCOL_ERROR
            out.is_connection_error = True
            return out^
        var lsi = _read_u32_be(buf, payload_off) & UInt32(0x7fffffff)
        var ec = _read_u32_be(buf, payload_off + 4)
        out.frame.goaway_last_stream_id = lsi
        out.frame.goaway_error_code = ec
        # Remaining bytes are debug-data; stuff into payload.
        var k = payload_off + 8
        while k < payload_end:
            out.frame.payload.append(buf[k])
            k = k + 1
    elif kind == FRAME_WINDOW_UPDATE:
        if length != UInt32(4):
            # RFC 9113 §6.9: "A WINDOW_UPDATE frame with a length other
            # than 4 octets MUST be treated as a connection error of type
            # FRAME_SIZE_ERROR", on any stream, so no stream and nothing
            # consumed (the connection-error contract above).
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_FRAME_SIZE_ERROR
            out.is_connection_error = True
            return out^
        var inc_raw = _read_u32_be(buf, payload_off)
        var inc = inc_raw & UInt32(0x7fffffff)
        if inc == UInt32(0):
            # Per RFC 9113 §6.9.1 +ssue 2:
            #   stream 0 → GOAWAY(PROTOCOL_ERROR)
            #   non-zero stream → RST_STREAM(PROTOCOL_ERROR)
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_PROTOCOL_ERROR
            out.is_connection_error = (stream_id == UInt32(0))
            out.error_stream_id = stream_id
            out.consumed = total
            return out^
        out.frame.window_update_increment = inc
    elif kind == FRAME_CONTINUATION:
        if stream_id == UInt32(0):
            out.status = FRAME_DECODE_ERROR
            out.error_code = H2_ERR_PROTOCOL_ERROR
            out.is_connection_error = True
            return out^
        var i = payload_off
        while i < payload_end:
            out.frame.payload.append(buf[i])
            i = i + 1
    else:
        # Unknown frame types are ignored per RFC 9113 §4.1 ("frames of
        # unknown types MUST be ignored"). Surface as OK with payload=raw
        # bytes; the connection driver chooses to skip.
        var i = payload_off
        while i < payload_end:
            out.frame.payload.append(buf[i])
            i = i + 1

    out.status = FRAME_DECODE_OK
    out.consumed = total
    return out^


def encode_data_frame(
    stream_id: UInt32,
    var data: List[UInt8],
    end_stream: Bool,
    mut out: List[UInt8],
):
    """Serialize a DATA frame.

    Padding is NOT emitted by this encoder.
    """
    var flags = UInt8(0)
    if end_stream:
        flags = flags | FLAG_END_STREAM
    encode_frame_header(
        UInt32(len(data)), FRAME_DATA, flags, stream_id, out,
    )
    var i = 0
    while i < len(data):
        out.append(data[i])
        i = i + 1


def encode_headers_frame(
    stream_id: UInt32,
    var block_fragment: List[UInt8],
    end_stream: Bool,
    end_headers: Bool,
    mut out: List[UInt8],
):
    """Serialize a HEADERS frame (no padding, no priority).

    `block_fragment` is the HPACK-encoded header block (caller produced
    via HpackEncoder.encode_block).
    """
    var flags = UInt8(0)
    if end_stream:
        flags = flags | FLAG_END_STREAM
    if end_headers:
        flags = flags | FLAG_END_HEADERS
    encode_frame_header(
        UInt32(len(block_fragment)), FRAME_HEADERS, flags, stream_id, out,
    )
    var i = 0
    while i < len(block_fragment):
        out.append(block_fragment[i])
        i = i + 1


def encode_rst_stream_frame(
    stream_id: UInt32,
    error_code: UInt32,
    mut out: List[UInt8],
):
    """Serialize a RST_STREAM frame (RFC 9113 §6.4)."""
    encode_frame_header(
        UInt32(4), FRAME_RST_STREAM, UInt8(0), stream_id, out,
    )
    _write_u32_be(error_code, out)


def encode_settings_frame(
    var entries: List[SettingsEntry],
    mut out: List[UInt8],
):
    """Serialize a SETTINGS frame (non-ACK). Each entry is 6 bytes:
    2-byte identifier + 4-byte value (RFC 9113 §6.5.1)."""
    var n = len(entries)
    encode_frame_header(
        UInt32(n * 6), FRAME_SETTINGS, UInt8(0), UInt32(0), out,
    )
    var i = 0
    while i < n:
        var e = entries[i]
        out.append(UInt8(Int((e.identifier >> 8) & UInt16(0xff))))
        out.append(UInt8(Int(e.identifier & UInt16(0xff))))
        _write_u32_be(e.value, out)
        i = i + 1


def encode_settings_ack_frame(mut out: List[UInt8]):
    """Serialize a SETTINGS-ACK frame (zero-length, flags=ACK)."""
    encode_frame_header(
        UInt32(0), FRAME_SETTINGS, FLAG_ACK, UInt32(0), out,
    )


def encode_ping_frame(
    data: SIMD[DType.uint8, 8],
    is_ack: Bool,
    mut out: List[UInt8],
):
    """Serialize a PING frame (8 bytes opaque)."""
    var flags = FLAG_ACK if is_ack else UInt8(0)
    encode_frame_header(
        UInt32(8), FRAME_PING, flags, UInt32(0), out,
    )
    var i = 0
    while i < 8:
        out.append(data[i])
        i = i + 1


def encode_goaway_frame(
    last_stream_id: UInt32,
    error_code: UInt32,
    var debug_data: List[UInt8],
    mut out: List[UInt8],
):
    """Serialize a GOAWAY frame (RFC 9113 §6.8)."""
    var dn = len(debug_data)
    encode_frame_header(
        UInt32(8 + dn), FRAME_GOAWAY, UInt8(0), UInt32(0), out,
    )
    _write_u32_be(last_stream_id & UInt32(0x7fffffff), out)
    _write_u32_be(error_code, out)
    var i = 0
    while i < dn:
        out.append(debug_data[i])
        i = i + 1


def encode_window_update_frame(
    stream_id: UInt32,
    increment: UInt32,
    mut out: List[UInt8],
):
    """Serialize a WINDOW_UPDATE frame.

    `increment` must be in [1, 2**31-1]; caller validates per RFC 9113 §6.9.1.
    """
    encode_frame_header(
        UInt32(4), FRAME_WINDOW_UPDATE, UInt8(0), stream_id, out,
    )
    _write_u32_be(increment & UInt32(0x7fffffff), out)
