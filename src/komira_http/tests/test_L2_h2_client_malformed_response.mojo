"""L2 h2 CLIENT — malformed-response + trailers conformance (RFC 9113 §8.1.1).

WHY THIS FILE EXISTS. `_handle_inbound_headers_or_cont`
(`client/h2_client.mojo`) walks the decoded response header list, pulls
`:status` by string compare, and appends *everything else verbatim* into the
per-stream `response_header_lists` slot. There is NO validation of any kind:
not of the `:status` value, not of pseudo-header placement, not of field-name
or field-value syntax, not of connection-specific fields, not of
`content-length` against the DATA it framed, and not of a SECOND header block
(trailers) re-entering the same code path.

Two of those are SILENT WRONG ANSWERS rather than errors, which is worse than
a hard failure:

  * a response with NO `:status` leaves `response_status` at 0;
  * a TRAILER block re-enters at the `:status` branch and REWRITES an
    already-delivered status — a 500 becomes a 200 after the body has
    already been handed over.

THE BAR IS A THIRD-PARTY ONE, deliberately. Go's `net/http2` pins this with a
table (`TestMetaFrameHeader`) plus `TestTransportHandlesInvalidStatuslessResponse`
and `TestTransportRejectsConnHeaders`; hyper has `response_missing_status` and
`malformed_response_headers_dont_unlink_stream`; h2spec covers the whole
§8.1.2.* group. Every case below names the rule it encodes.

WHAT A CASE ASSERTS. RFC 9113 §8.1.1: "A malformed request or response is one
that is an otherwise valid sequence of frames but is invalid due to the
presence of extraneous or missing fields ... An endpoint that receives a
malformed request or response MUST treat it as a stream error (Section 5.4.2)
of type PROTOCOL_ERROR."  So the safety property is TWO-part:

  (1) the peer is told — RST_STREAM(PROTOCOL_ERROR) on that stream (a
      connection-level GOAWAY also satisfies "refused", and is accepted here
      so the suite does not become noise about stream-vs-connection scope);
  (2) the malformed response is NOT handed to the caller as a success.

`_refusal_summary` answers (1) and `_delivered_status` answers (2), and every
failure message prints both so the report is actionable without a debugger.

BYTE-EXACT HPACK, ON PURPOSE. `HpackEncoder.encode_block` takes `String` name
and value, so it cannot express an uppercase field name with a NUL in its
value. `_hpack_literal_raw` emits RFC 7541 §6.2.2 (literal without indexing,
new name, no Huffman) BYTE BY BYTE, which is exactly what a hostile or broken
origin puts on the wire.
"""

from komira_http.client.h2_client import (
    H2ClientConnectionState,
    extract_response_for_stream,
    process_received_frames,
)
from komira_http.codec.h2.continuation_splitter import (
    split_header_block_into_frames,
)
from komira_http.codec.h2.frame import (
    FRAME_DECODE_OK,
    FRAME_GOAWAY,
    FRAME_RST_STREAM,
    decode_frame,
    encode_data_frame,
    encode_headers_frame,
)


# =============================================================================
# Helpers — byte-exact HPACK + frame construction.
# =============================================================================


def _bytes_of(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var sb = s.as_bytes()
    var i = 0
    while i < len(sb):
        out.append(sb[i])
        i = i + 1
    return out^


def _hpack_literal_raw(
    name: List[UInt8], value: List[UInt8], mut out: List[UInt8],
) raises:
    """RFC 7541 §6.2.2 — literal header field WITHOUT indexing, new name,
    no Huffman. Byte-exact: the caller chooses every byte of the name and
    the value, which is the only way to put an uppercase letter, a space,
    a control byte, a NUL, a CR or an LF where the RFC forbids one.

    Without-indexing (rather than incremental) keeps the decoder's dynamic
    table untouched, so successive blocks on one connection decode
    independently and a case cannot be perturbed by the one before it.
    """
    if len(name) > 126 or len(value) > 126:
        raise Error(
            "_hpack_literal_raw: name/value must fit a 7-bit length prefix"
        )
    out.append(UInt8(0x00))  # 0000_0000 — literal w/o indexing, new name
    out.append(UInt8(len(name)))  # H=0, 7-bit length
    var i = 0
    while i < len(name):
        out.append(name[i])
        i = i + 1
    out.append(UInt8(len(value)))  # H=0, 7-bit length
    var j = 0
    while j < len(value):
        out.append(value[j])
        j = j + 1


def _hpack_literal(
    name: String, value: String, mut out: List[UInt8],
) raises:
    _hpack_literal_raw(_bytes_of(name), _bytes_of(value), out)


def _headers_frame(
    sid: UInt32, var block: List[UInt8], end_stream: Bool, end_headers: Bool,
) -> List[UInt8]:
    var out = List[UInt8]()
    encode_headers_frame(sid, block^, end_stream, end_headers, out)
    return out^


def _data_frame(
    sid: UInt32, var payload: List[UInt8], end_stream: Bool,
) -> List[UInt8]:
    var out = List[UInt8]()
    encode_data_frame(sid, payload^, end_stream, out)
    return out^


def _concat(var a: List[UInt8], b: List[UInt8]) -> List[UInt8]:
    var out = a^
    var i = 0
    while i < len(b):
        out.append(b[i])
        i = i + 1
    return out^


# =============================================================================
# Helpers — client state + observation.
# =============================================================================


def _client_with_open_stream(sid: UInt32) -> H2ClientConnectionState:
    """A client connection with `sid` already OPEN, as it would be after
    the request HEADERS went out. No preface is queued — nothing here
    drives a peer decoder, and an empty `pending_out` makes the refusal
    scan unambiguous."""
    var c = H2ClientConnectionState()
    _ = c.create_stream(sid)
    return c^


def _feed(mut h2: H2ClientConnectionState, bytes: List[UInt8]) raises:
    """Route server-shaped bytes into the client and dispatch them."""
    h2.append_recv_bytes(Span(bytes))
    _ = process_received_frames(h2)


def _scan_rst_code(bytes: List[UInt8], sid: UInt32) raises -> Int64:
    """The error code of the first RST_STREAM on `sid` in `bytes`, or -1."""
    var off = 0
    var n = len(bytes)
    while off < n:
        var tail = List[UInt8]()
        var i = off
        while i < n:
            tail.append(bytes[i])
            i = i + 1
        var res = decode_frame(Span(tail), 16384)
        if res.status != FRAME_DECODE_OK:
            return Int64(-1)
        if res.consumed <= 0:
            return Int64(-1)
        if (
            res.frame.header.kind == FRAME_RST_STREAM
            and res.frame.header.stream_id == sid
        ):
            return Int64(Int(res.frame.rst_error_code))
        off = off + res.consumed
    return Int64(-1)


def _scan_goaway_code(bytes: List[UInt8]) raises -> Int64:
    """The error code of the first GOAWAY in `bytes`, or -1."""
    var off = 0
    var n = len(bytes)
    while off < n:
        var tail = List[UInt8]()
        var i = off
        while i < n:
            tail.append(bytes[i])
            i = i + 1
        var res = decode_frame(Span(tail), 16384)
        if res.status != FRAME_DECODE_OK:
            return Int64(-1)
        if res.consumed <= 0:
            return Int64(-1)
        if res.frame.header.kind == FRAME_GOAWAY:
            return Int64(Int(res.frame.goaway_error_code))
        off = off + res.consumed
    return Int64(-1)


def _refusal_summary(
    mut h2: H2ClientConnectionState, sid: UInt32,
) raises -> String:
    """DRAINS `pending_out` and says how the client refused the response:
    `RST_STREAM(<code>)`, `GOAWAY(<code>)`, or `NONE`. WINDOW_UPDATE and
    SETTINGS-ACK traffic in the same buffer is skipped, not misread."""
    var out = h2.take_out_bytes()
    var r = _scan_rst_code(out, sid)
    if r >= 0:
        return String("RST_STREAM(") + String(r) + String(")")
    var g = _scan_goaway_code(out)
    if g >= 0:
        return String("GOAWAY(") + String(g) + String(")")
    return String("NONE")


def _refused(summary: String) -> Bool:
    return summary != String("NONE")


def _delivered_status(mut h2: H2ClientConnectionState, sid: UInt32) -> Int:
    """The status the CALLER would see, or -1 if extraction refuses."""
    try:
        var triple = extract_response_for_stream(h2, sid)
        return Int(triple[0])
    except:
        return -1


def _raw_status(mut h2: H2ClientConnectionState, sid: UInt32) -> Int:
    """`streams[idx].response_status` as the driver left it."""
    var idx = h2.find_stream_idx(sid)
    if idx < 0:
        return -1
    return Int(h2.streams[idx].response_status)


def _slot_len(mut h2: H2ClientConnectionState, sid: UInt32) -> Int:
    """How many caller-visible header pairs the stream's slot holds."""
    var idx = h2.find_stream_idx(sid)
    if idx < 0:
        return -1
    var slot = h2.streams[idx].response_header_idx
    if slot < 0:
        return -1
    return len(h2.response_header_lists[slot])


def _slot_has_name(
    mut h2: H2ClientConnectionState, sid: UInt32, name: String,
) -> Bool:
    var idx = h2.find_stream_idx(sid)
    if idx < 0:
        return False
    var slot = h2.streams[idx].response_header_idx
    if slot < 0:
        return False
    var n = len(h2.response_header_lists[slot])
    var i = 0
    while i < n:
        if String(h2.response_header_lists[slot][i].name) == name:
            return True
        i = i + 1
    return False


def _assert_malformed(
    mut h2: H2ClientConnectionState, sid: UInt32, case_label: String,
) raises:
    """The two-part §8.1.1 property, applied to one crafted response."""
    var summary = _refusal_summary(h2, sid)
    var delivered = _delivered_status(h2, sid)
    if not _refused(summary):
        raise Error(
            case_label
            + ": RFC 9113 §8.1.1 requires a stream error of type"
            + " PROTOCOL_ERROR; the client signalled NOTHING to the peer"
            + " (pending_out held no RST_STREAM and no GOAWAY) and handed"
            + " the caller status=" + String(delivered)
        )
    if delivered >= 0:
        raise Error(
            case_label
            + ": the client signalled " + summary
            + " but STILL delivered the malformed response to the caller"
            + " as status=" + String(delivered)
        )


# =============================================================================
# §A — Controls. These encode behaviour the driver ALREADY has; they exist so
#      a fix cannot pass this suite by refusing everything, and so the suite
#      itself is falsifiable by mutation.
# =============================================================================


def test_control_well_formed_response_is_accepted() raises:
    """A well-formed `:status 200` + one regular field + a body must be
    delivered untouched. The floor under every refusal case below."""
    print("  test_control_well_formed_response_is_accepted...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var block = List[UInt8]()
    _hpack_literal(String(":status"), String("200"), block)
    _hpack_literal(String("content-type"), String("text/plain"), block)
    var wire = _headers_frame(sid, block^, False, True)
    wire = _concat(wire^, _data_frame(sid, _bytes_of(String("hi")), True))
    _feed(c, wire)

    var summary = _refusal_summary(c, sid)
    if _refused(summary):
        raise Error(
            "a well-formed 200 response was refused with " + summary
        )
    var delivered = _delivered_status(c, sid)
    if delivered != 200:
        raise Error(
            "well-formed 200: caller should see 200; got "
            + String(delivered)
        )
    if not _slot_has_name(c, sid, String("content-type")):
        raise Error(
            "well-formed 200: content-type missing from the delivered"
            + " header slot"
        )
    if _slot_len(c, sid) != 1:
        raise Error(
            "well-formed 200: expected exactly 1 caller-visible header;"
            + " got " + String(_slot_len(c, sid))
        )
    print("    OK")


def test_control_headers_on_unopened_stream_is_protocol_error() raises:
    """RFC 9113 §5.1 — response HEADERS on a stream the client never
    opened is a connection error. Already implemented; a control."""
    print("  test_control_headers_on_unopened_stream_is_protocol_error...")
    var c = H2ClientConnectionState()
    var block = List[UInt8]()
    _hpack_literal(String(":status"), String("200"), block)
    _feed(c, _headers_frame(UInt32(7), block^, True, True))
    var g = _scan_goaway_code(c.take_out_bytes())
    if g != Int64(1):
        raise Error(
            "HEADERS on an unopened stream must emit GOAWAY(PROTOCOL_ERROR"
            + "=1); got code " + String(g)
        )
    print("    OK")


def test_control_data_on_unopened_stream_is_protocol_error() raises:
    """RFC 9113 §6.1 — DATA on a stream the client never opened is a
    connection error. Already implemented; a control."""
    print("  test_control_data_on_unopened_stream_is_protocol_error...")
    var c = H2ClientConnectionState()
    _feed(c, _data_frame(UInt32(9), _bytes_of(String("hi")), True))
    var g = _scan_goaway_code(c.take_out_bytes())
    if g != Int64(1):
        raise Error(
            "DATA on an unopened stream must emit GOAWAY(PROTOCOL_ERROR=1);"
            + " got code " + String(g)
        )
    print("    OK")


def test_control_continuation_without_headers_is_protocol_error() raises:
    """RFC 9113 §6.10 — a CONTINUATION with no HEADERS in front of it is a
    connection error. Already implemented; a control."""
    print(
        "  test_control_continuation_without_headers_is_protocol_error..."
    )
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    # A bare CONTINUATION: HEADERS-shaped payload, CONTINUATION frame kind.
    var block = List[UInt8]()
    _hpack_literal(String("x-late"), String("v"), block)
    var wire = List[UInt8]()
    # Frame header: 3-byte length, kind=0x09, flags=END_HEADERS, stream id.
    wire.append(UInt8(0))
    wire.append(UInt8(0))
    wire.append(UInt8(len(block)))
    wire.append(UInt8(0x09))
    wire.append(UInt8(0x04))
    wire.append(UInt8(0))
    wire.append(UInt8(0))
    wire.append(UInt8(0))
    wire.append(UInt8(Int(sid)))
    var i = 0
    while i < len(block):
        wire.append(block[i])
        i = i + 1
    _feed(c, wire)
    var g = _scan_goaway_code(c.take_out_bytes())
    if g != Int64(1):
        raise Error(
            "a bare CONTINUATION must emit GOAWAY(PROTOCOL_ERROR=1); got"
            + " code " + String(g)
        )
    print("    OK")


# =============================================================================
# §B — :status validation (RFC 9113 §8.3.2 / §8.1.1).
# =============================================================================


def test_missing_status_is_malformed() raises:
    """RFC 9113 §8.3.2: "For HTTP/2 responses, a single ':status'
    pseudo-header field is defined". Its ABSENCE makes the response
    malformed.

    Go: `TestTransportHandlesInvalidStatuslessResponse`.
    hyper: `response_missing_status`.
    """
    print("  test_missing_status_is_malformed...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var block = List[UInt8]()
    _hpack_literal(String("content-type"), String("text/plain"), block)
    _feed(c, _headers_frame(sid, block^, True, True))
    _assert_malformed(c, sid, String("response with no :status"))
    print("    OK")


def test_malformed_status_values_table() raises:
    """A `:status` that is not exactly three ASCII digits is malformed.

    The digit loop in `_handle_inbound_headers_or_cont` BREAKS on the first
    non-digit and KEEPS the partial value, so '2oo' yields status 2 — a
    plausible-looking number the caller cannot distinguish from a real one.
    Table shape borrowed from Go's `TestMetaFrameHeader`.
    """
    print("  test_malformed_status_values_table...")
    var cases = List[String]()
    cases.append(String(""))       # empty
    cases.append(String("2oo"))    # letters after one digit -> status 2
    cases.append(String("20"))     # two digits
    cases.append(String("0200"))   # four digits
    cases.append(String("2 0"))    # embedded space
    cases.append(String("+200"))   # leading sign -> status 0
    cases.append(String("abc"))    # no digits at all -> status 0
    var i = 0
    var failed = List[String]()
    while i < len(cases):
        var sid = UInt32(1)
        var c = _client_with_open_stream(sid)
        var block = List[UInt8]()
        _hpack_literal(String(":status"), cases[i], block)
        _feed(c, _headers_frame(sid, block^, True, True))
        var raw = _raw_status(c, sid)
        var summary = _refusal_summary(c, sid)
        var delivered = _delivered_status(c, sid)
        if (not _refused(summary)) or delivered >= 0:
            failed.append(
                String("  :status='") + cases[i] + String("' -> refusal=")
                + summary + String(" response_status=") + String(raw)
                + String(" delivered=") + String(delivered)
            )
        i = i + 1
    if len(failed) > 0:
        var msg = String(
            "a :status that is not three ASCII digits must be a stream"
            + " error (RFC 9113 §8.3.2 + §8.1.1). Accepted instead:\n"
        )
        var k = 0
        while k < len(failed):
            msg = msg + failed[k] + String("\n")
            k = k + 1
        raise Error(msg)
    print("    OK")


# =============================================================================
# §C — pseudo-header rules (RFC 9113 §8.3).
# =============================================================================


def test_unknown_pseudo_header_is_malformed() raises:
    """RFC 9113 §8.3: "Endpoints MUST treat a request or response that
    contains undefined or invalid pseudo-header fields as malformed"."""
    print("  test_unknown_pseudo_header_is_malformed...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var block = List[UInt8]()
    _hpack_literal(String(":status"), String("200"), block)
    _hpack_literal(String(":test"), String("x"), block)
    _feed(c, _headers_frame(sid, block^, True, True))
    _assert_malformed(c, sid, String("response carrying ':test'"))
    print("    OK")


def test_request_pseudo_headers_in_response_table() raises:
    """RFC 9113 §8.3: ':method', ':scheme', ':authority' and ':path' are
    REQUEST pseudo-headers. A response carrying one is malformed."""
    print("  test_request_pseudo_headers_in_response_table...")
    var names = List[String]()
    names.append(String(":method"))
    names.append(String(":path"))
    names.append(String(":scheme"))
    names.append(String(":authority"))
    var failed = List[String]()
    var i = 0
    while i < len(names):
        var sid = UInt32(1)
        var c = _client_with_open_stream(sid)
        var block = List[UInt8]()
        _hpack_literal(String(":status"), String("200"), block)
        _hpack_literal(names[i], String("GET"), block)
        _feed(c, _headers_frame(sid, block^, True, True))
        var summary = _refusal_summary(c, sid)
        var delivered = _delivered_status(c, sid)
        if (not _refused(summary)) or delivered >= 0:
            failed.append(
                String("  ") + names[i] + String(" -> refusal=") + summary
                + String(" delivered=") + String(delivered)
                + String(" slot_carries_it=")
                + String(_slot_has_name(c, sid, names[i]))
            )
        i = i + 1
    if len(failed) > 0:
        var msg = String(
            "a REQUEST pseudo-header in a response must be a stream error"
            + " (RFC 9113 §8.3). Accepted instead:\n"
        )
        var k = 0
        while k < len(failed):
            msg = msg + failed[k] + String("\n")
            k = k + 1
        raise Error(msg)
    print("    OK")


def test_pseudo_header_after_regular_field_is_malformed() raises:
    """RFC 9113 §8.3: "All pseudo-header fields MUST appear in a field
    block before all regular field lines." Go pins this as
    `pseudo_order` in `frame_test.go`."""
    print("  test_pseudo_header_after_regular_field_is_malformed...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var block = List[UInt8]()
    _hpack_literal(String("content-type"), String("text/plain"), block)
    _hpack_literal(String(":status"), String("200"), block)
    _feed(c, _headers_frame(sid, block^, True, True))
    _assert_malformed(
        c, sid, String(":status appearing after a regular field"),
    )
    print("    OK")


def test_duplicate_pseudo_header_is_malformed() raises:
    """RFC 9113 §8.3: a pseudo-header field MUST NOT appear more than once.
    Go pins this as `pseudo_dup` in `frame_test.go`.

    Today the second occurrence simply overwrites the first, so the caller
    sees whichever the SERVER put last — the in-block form of the trailer
    overwrite below.
    """
    print("  test_duplicate_pseudo_header_is_malformed...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var block = List[UInt8]()
    _hpack_literal(String(":status"), String("500"), block)
    _hpack_literal(String(":status"), String("200"), block)
    _feed(c, _headers_frame(sid, block^, True, True))
    var raw = _raw_status(c, sid)
    var summary = _refusal_summary(c, sid)
    var delivered = _delivered_status(c, sid)
    if (not _refused(summary)) or delivered >= 0:
        raise Error(
            "a duplicated :status must be a stream error (RFC 9113 §8.3);"
            + " refusal=" + summary + " response_status=" + String(raw)
            + " delivered=" + String(delivered)
            + " (the SECOND value won, so a server can restate its own"
            + " status inside one block)"
        )
    print("    OK")


# =============================================================================
# §D — field-name / field-value syntax (RFC 9113 §8.2.1).
# =============================================================================


def test_malformed_field_names_table() raises:
    """RFC 9113 §8.2.1: a field name MUST be lowercase, MUST NOT be empty,
    and MUST contain only `token` characters — no space, no control byte,
    and no ':' anywhere but a pseudo-header's first octet. "A request or
    response that includes characters not permitted ... MUST be treated as
    malformed."
    """
    print("  test_malformed_field_names_table...")
    var labels = List[String]()
    var names = List[List[UInt8]]()

    labels.append(String("uppercase 'X-TEST'"))
    names.append(_bytes_of(String("X-TEST")))

    labels.append(String("space inside the name"))
    names.append(_bytes_of(String("x test")))

    labels.append(String("control byte 0x01 inside the name"))
    var ctl = _bytes_of(String("x"))
    ctl.append(UInt8(0x01))
    ctl.append(UInt8(ord("t")))
    names.append(ctl^)

    labels.append(String("':' at a non-leading position"))
    names.append(_bytes_of(String("x:test")))

    labels.append(String("empty field name"))
    names.append(List[UInt8]())

    var failed = List[String]()
    var i = 0
    while i < len(labels):
        var sid = UInt32(1)
        var c = _client_with_open_stream(sid)
        var block = List[UInt8]()
        _hpack_literal(String(":status"), String("200"), block)
        _hpack_literal_raw(names[i], _bytes_of(String("v")), block)
        try:
            _feed(c, _headers_frame(sid, block^, True, True))
        except e:
            # A raise out of the dispatch path is a refusal too — record it
            # as such rather than letting it abort the whole table.
            _ = e
            i = i + 1
            continue
        var summary = _refusal_summary(c, sid)
        var delivered = _delivered_status(c, sid)
        if (not _refused(summary)) or delivered >= 0:
            failed.append(
                String("  ") + labels[i] + String(" -> refusal=") + summary
                + String(" delivered=") + String(delivered)
            )
        i = i + 1
    if len(failed) > 0:
        var msg = String(
            "a malformed response field NAME must be a stream error"
            + " (RFC 9113 §8.2.1). Accepted verbatim instead:\n"
        )
        var k = 0
        while k < len(failed):
            msg = msg + failed[k] + String("\n")
            k = k + 1
        raise Error(msg)
    print("    OK")


def test_malformed_field_values_table() raises:
    """RFC 9113 §8.2.1: "A field value MUST NOT contain the zero value
    (ASCII NUL, 0x00), line feed (ASCII LF, 0x0a), or carriage return
    (ASCII CR, 0x0d)". Forwarding one is how an h2->h1 hop becomes a
    response-splitting gadget."""
    print("  test_malformed_field_values_table...")
    var labels = List[String]()
    var values = List[List[UInt8]]()

    labels.append(String("CR in the value"))
    var v_cr = _bytes_of(String("a"))
    v_cr.append(UInt8(0x0d))
    v_cr.append(UInt8(ord("b")))
    values.append(v_cr^)

    labels.append(String("LF in the value"))
    var v_lf = _bytes_of(String("a"))
    v_lf.append(UInt8(0x0a))
    v_lf.append(UInt8(ord("b")))
    values.append(v_lf^)

    labels.append(String("NUL in the value"))
    var v_nul = _bytes_of(String("a"))
    v_nul.append(UInt8(0x00))
    v_nul.append(UInt8(ord("b")))
    values.append(v_nul^)

    var failed = List[String]()
    var i = 0
    while i < len(labels):
        var sid = UInt32(1)
        var c = _client_with_open_stream(sid)
        var block = List[UInt8]()
        _hpack_literal(String(":status"), String("200"), block)
        _hpack_literal_raw(_bytes_of(String("x-probe")), values[i], block)
        try:
            _feed(c, _headers_frame(sid, block^, True, True))
        except e:
            _ = e
            i = i + 1
            continue
        var summary = _refusal_summary(c, sid)
        var delivered = _delivered_status(c, sid)
        if (not _refused(summary)) or delivered >= 0:
            failed.append(
                String("  ") + labels[i] + String(" -> refusal=") + summary
                + String(" delivered=") + String(delivered)
            )
        i = i + 1
    if len(failed) > 0:
        var msg = String(
            "a response field VALUE holding CR, LF or NUL must be a stream"
            + " error (RFC 9113 §8.2.1). Accepted verbatim instead:\n"
        )
        var k = 0
        while k < len(failed):
            msg = msg + failed[k] + String("\n")
            k = k + 1
        raise Error(msg)
    print("    OK")


# =============================================================================
# §E — connection-specific fields (RFC 9113 §8.2.2).
# =============================================================================


def test_connection_specific_headers_table() raises:
    """RFC 9113 §8.2.2: "An endpoint MUST NOT generate an HTTP/2 message
    containing connection-specific header fields ... Any message
    containing connection-specific header fields MUST be treated as
    malformed". Go pins this as `TestTransportRejectsConnHeaders`."""
    print("  test_connection_specific_headers_table...")
    var names = List[String]()
    names.append(String("connection"))
    names.append(String("keep-alive"))
    names.append(String("proxy-connection"))
    names.append(String("transfer-encoding"))
    names.append(String("upgrade"))
    var failed = List[String]()
    var i = 0
    while i < len(names):
        var sid = UInt32(1)
        var c = _client_with_open_stream(sid)
        var block = List[UInt8]()
        _hpack_literal(String(":status"), String("200"), block)
        _hpack_literal(names[i], String("close"), block)
        _feed(c, _headers_frame(sid, block^, True, True))
        var summary = _refusal_summary(c, sid)
        var delivered = _delivered_status(c, sid)
        if (not _refused(summary)) or delivered >= 0:
            failed.append(
                String("  ") + names[i] + String(" -> refusal=") + summary
                + String(" delivered=") + String(delivered)
                + String(" slot_carries_it=")
                + String(_slot_has_name(c, sid, names[i]))
            )
        i = i + 1
    if len(failed) > 0:
        var msg = String(
            "a connection-specific field in a response must be a stream"
            + " error (RFC 9113 §8.2.2). Accepted instead:\n"
        )
        var k = 0
        while k < len(failed):
            msg = msg + failed[k] + String("\n")
            k = k + 1
        raise Error(msg)
    print("    OK")


def test_te_header_only_trailers_is_permitted() raises:
    """RFC 9113 §8.2.2 carve-out: `te` is the ONE connection-specific name
    that may appear, and then only with the exact value "trailers". Both
    halves are asserted so a fix cannot satisfy this by banning `te`
    outright."""
    print("  test_te_header_only_trailers_is_permitted...")
    # (a) te: trailers — MUST be accepted.
    var sid = UInt32(1)
    var ok = _client_with_open_stream(sid)
    var block_ok = List[UInt8]()
    _hpack_literal(String(":status"), String("200"), block_ok)
    _hpack_literal(String("te"), String("trailers"), block_ok)
    _feed(ok, _headers_frame(sid, block_ok^, True, True))
    var summary_ok = _refusal_summary(ok, sid)
    if _refused(summary_ok):
        raise Error(
            "'te: trailers' is explicitly permitted by RFC 9113 §8.2.2;"
            + " the client refused it with " + summary_ok
        )
    if _delivered_status(ok, sid) != 200:
        raise Error("'te: trailers' response should deliver status 200")

    # (b) te: gzip — MUST be malformed.
    var bad = _client_with_open_stream(sid)
    var block_bad = List[UInt8]()
    _hpack_literal(String(":status"), String("200"), block_bad)
    _hpack_literal(String("te"), String("gzip"), block_bad)
    _feed(bad, _headers_frame(sid, block_bad^, True, True))
    _assert_malformed(bad, sid, String("'te: gzip'"))
    print("    OK")


# =============================================================================
# §F — content-length vs the framed DATA (RFC 9113 §8.1.1).
# =============================================================================


def _content_length_case(
    cl: String, var payloads: List[List[UInt8]], case_label: String,
) raises:
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var block = List[UInt8]()
    _hpack_literal(String(":status"), String("200"), block)
    _hpack_literal(String("content-length"), cl, block)
    var wire = _headers_frame(sid, block^, False, True)
    var i = 0
    while i < len(payloads):
        var last = i == len(payloads) - 1
        var body = List[UInt8]()
        var j = 0
        while j < len(payloads[i]):
            body.append(payloads[i][j])
            j = j + 1
        wire = _concat(wire^, _data_frame(sid, body^, last))
        i = i + 1
    _feed(c, wire)
    _assert_malformed(c, sid, case_label)


def test_content_length_mismatch_table() raises:
    """RFC 9113 §8.1.1: "A response is also malformed if the value of a
    content-length header field does not equal the sum of the DATA frame
    payload lengths that form the content".

    A client that does not check this hands the caller a SHORT body with no
    error — the h2 twin of the h1 `EOF_MID_RESPONSE` chunked truncation,
    except it does not even raise.
    """
    print("  test_content_length_mismatch_table...")
    # (a) content-length longer than the DATA — a truncated body.
    var short_payloads = List[List[UInt8]]()
    short_payloads.append(_bytes_of(String("hi")))
    _content_length_case(
        String("5"), short_payloads^,
        String("content-length: 5 with 2 DATA bytes"),
    )
    # (b) content-length shorter than the DATA — extra content.
    var long_payloads = List[List[UInt8]]()
    long_payloads.append(_bytes_of(String("hello world")))
    _content_length_case(
        String("2"), long_payloads^,
        String("content-length: 2 with 11 DATA bytes"),
    )
    # (c) the same mismatch spread across THREE DATA frames — the sum, not
    #     the last frame, is what §8.1.1 compares.
    var multi = List[List[UInt8]]()
    multi.append(_bytes_of(String("aa")))
    multi.append(_bytes_of(String("bb")))
    multi.append(_bytes_of(String("cc")))
    _content_length_case(
        String("10"), multi^,
        String("content-length: 10 with 2+2+2 DATA bytes"),
    )
    print("    OK")


def test_content_length_with_sign_is_malformed() raises:
    """RFC 9110 §8.6: content-length is 1*DIGIT. A leading '+' or '-' is
    not a digit, so the field is invalid and the message malformed."""
    print("  test_content_length_with_sign_is_malformed...")
    var plus = List[List[UInt8]]()
    plus.append(_bytes_of(String("hi")))
    _content_length_case(
        String("+2"), plus^, String("content-length: '+2'"),
    )
    var minus = List[List[UInt8]]()
    minus.append(_bytes_of(String("hi")))
    _content_length_case(
        String("-2"), minus^, String("content-length: '-2'"),
    )
    print("    OK")


def test_no_content_response_keeps_content_length() raises:
    """THE CARVE-OUT, and it must NOT become a refusal. §8.1.1 exempts a
    message "defined as having no content" — a 204 or 304, or the response
    to HEAD — so a non-zero content-length with zero DATA frames is legal
    there and must still be delivered, header intact."""
    print("  test_no_content_response_keeps_content_length...")
    var codes = List[String]()
    codes.append(String("204"))
    codes.append(String("304"))
    var i = 0
    while i < len(codes):
        var sid = UInt32(1)
        var c = _client_with_open_stream(sid)
        var block = List[UInt8]()
        _hpack_literal(String(":status"), codes[i], block)
        _hpack_literal(String("content-length"), String("42"), block)
        _feed(c, _headers_frame(sid, block^, True, True))
        var summary = _refusal_summary(c, sid)
        if _refused(summary):
            raise Error(
                "a " + codes[i] + " with content-length: 42 and no DATA is"
                + " NOT malformed (RFC 9113 §8.1.1 exempts a message"
                + " defined as having no content); refused with " + summary
            )
        var delivered = _delivered_status(c, sid)
        if delivered != Int(atol(codes[i])):
            raise Error(
                "a " + codes[i] + " response should deliver status "
                + codes[i] + "; got " + String(delivered)
            )
        if not _slot_has_name(c, sid, String("content-length")):
            raise Error(
                "a " + codes[i] + " response should still carry its"
                + " content-length header to the caller"
            )
        i = i + 1
    print("    OK")


# =============================================================================
# §G — TRAILERS (RFC 9113 §8.1). ★ The worst cases in this file.
# =============================================================================


def _send_500_then_trailer(
    mut c: H2ClientConnectionState,
    sid: UInt32,
    var trailer_block: List[UInt8],
    trailer_end_stream: Bool,
) raises:
    """A complete 500 response — HEADERS, then a DATA body — followed by a
    SECOND HEADERS block on the same stream. That second block is the
    trailer section, and it re-enters `_handle_inbound_headers_or_cont` at
    the same `:status` branch the response head used."""
    var head = List[UInt8]()
    _hpack_literal(String(":status"), String("500"), head)
    _hpack_literal(String("content-type"), String("text/plain"), head)
    var wire = _headers_frame(sid, head^, False, True)
    wire = _concat(wire^, _data_frame(sid, _bytes_of(String("boom")), False))
    wire = _concat(
        wire^, _headers_frame(sid, trailer_block^, trailer_end_stream, True),
    )
    _feed(c, wire)


def test_trailers_must_not_overwrite_status() raises:
    """★ THE ONE THAT MATTERS. A second HEADERS block on a stream is the
    TRAILER section (RFC 9113 §8.1): "Trailers MUST NOT include
    pseudo-header fields". The client's handler does not know the
    difference between a head block and a trailer block, so the trailer's
    `:status` RE-ASSIGNS `streams[idx].response_status` — turning a 500
    into a 200 AFTER the body has already been received.

    Anyone who can append a header block to a stream — a broken origin, a
    compromised intermediary, a proxy that rewrites trailers — can flip the
    outcome of a request the caller has already been given the body for.
    """
    print("  test_trailers_must_not_overwrite_status...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var trailer = List[UInt8]()
    _hpack_literal(String(":status"), String("200"), trailer)
    _send_500_then_trailer(c, sid, trailer^, True)
    var raw = _raw_status(c, sid)
    var delivered = _delivered_status(c, sid)
    if delivered == 200 or raw == 200:
        raise Error(
            "a TRAILER block rewrote an already-delivered :status:"
            + " the response head said 500, the trailer said 200, and the"
            + " caller is told " + String(delivered)
            + " (streams[idx].response_status=" + String(raw) + ")."
            + " RFC 9113 §8.1 forbids a pseudo-header in a trailer"
            + " section; the status of a response is fixed by its head."
        )
    if delivered != 500:
        raise Error(
            "after a 500 head + a trailer block the caller must still see"
            + " 500 (or a refusal of the malformed trailer); got "
            + String(delivered)
        )
    print("    OK")


def test_trailers_must_not_merge_into_response_headers() raises:
    """RFC 9113 §8.1 / RFC 9110 §6.5: the trailer section is DISTINCT from
    the header section. Today every trailer field is appended to the same
    `response_header_lists` slot as the response head, so the caller cannot
    tell a field the server committed to before the body from one it
    appended after — which is the whole reason trailers are separated."""
    print("  test_trailers_must_not_merge_into_response_headers...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var trailer = List[UInt8]()
    _hpack_literal(String("grpc-status"), String("13"), trailer)
    _hpack_literal(String("x-trailer-probe"), String("v"), trailer)
    _send_500_then_trailer(c, sid, trailer^, True)
    if _slot_has_name(c, sid, String("x-trailer-probe")):
        raise Error(
            "a TRAILER field was merged into the response HEADER map:"
            + " 'x-trailer-probe' arrived in the trailer section but the"
            + " caller reads it beside 'content-type' from the head"
            + " (slot now holds " + String(_slot_len(c, sid))
            + " pairs). Trailers must be delivered separately."
        )
    print("    OK")


def test_trailer_block_with_pseudo_header_is_malformed() raises:
    """RFC 9113 §8.1: "Trailers MUST NOT include pseudo-header fields."
    A trailer carrying ANY pseudo-header — not only `:status` — is
    malformed and must be a stream error."""
    print("  test_trailer_block_with_pseudo_header_is_malformed...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var trailer = List[UInt8]()
    _hpack_literal(String(":method"), String("GET"), trailer)
    _send_500_then_trailer(c, sid, trailer^, True)
    var summary = _refusal_summary(c, sid)
    if not _refused(summary):
        raise Error(
            "a trailer section carrying ':method' must be a stream error"
            + " (RFC 9113 §8.1); the client signalled nothing and the"
            + " field landed in the caller's header map="
            + String(_slot_has_name(c, sid, String(":method")))
        )
    print("    OK")


def test_trailer_block_without_end_stream_is_malformed() raises:
    """RFC 9113 §8.1: the trailer section is the LAST thing on a stream,
    so its final frame carries END_STREAM. A second header block that does
    NOT end the stream leaves the stream in a state where more content
    could follow a trailer section — a protocol error."""
    print("  test_trailer_block_without_end_stream_is_malformed...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var trailer = List[UInt8]()
    _hpack_literal(String("x-trailer"), String("v"), trailer)
    _send_500_then_trailer(c, sid, trailer^, False)
    var summary = _refusal_summary(c, sid)
    if not _refused(summary):
        raise Error(
            "a trailer block WITHOUT END_STREAM must be a stream error"
            + " (RFC 9113 §8.1); the client accepted it silently"
        )
    print("    OK")


def test_trailer_field_name_uppercase_is_malformed() raises:
    """§8.2.1's field-name rules apply to the trailer section too — there
    is no relaxation for trailers."""
    print("  test_trailer_field_name_uppercase_is_malformed...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var trailer = List[UInt8]()
    _hpack_literal_raw(
        _bytes_of(String("X-Trailer")), _bytes_of(String("v")), trailer,
    )
    _send_500_then_trailer(c, sid, trailer^, True)
    var summary = _refusal_summary(c, sid)
    if not _refused(summary):
        raise Error(
            "an uppercase field name in a TRAILER section must be a stream"
            + " error (RFC 9113 §8.2.1); the client accepted it and the"
            + " caller's header map carries it="
            + String(_slot_has_name(c, sid, String("X-Trailer")))
        )
    print("    OK")


# =============================================================================
# §H — 1xx informational responses (RFC 9113 §8.1, RFC 9110 §15.2).
# =============================================================================


def test_informational_1xx_does_not_leak_into_final_response() raises:
    """A 1xx is an INTERIM response: it is followed by the real one on the
    same stream. Both blocks land in the SAME `response_header_lists` slot
    and the same `response_status` field today, so the caller receives the
    UNION of the two header sets and whichever status arrived last.

    Concretely relevant here: Cloud Run sits in front of the affected
    service, and gRPC-over-h2 emits 1xx in some configurations.
    """
    print("  test_informational_1xx_does_not_leak_into_final_response...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var interim = List[UInt8]()
    _hpack_literal(String(":status"), String("103"), interim)
    _hpack_literal(String("link"), String("</s.css>; rel=preload"), interim)
    var wire = _headers_frame(sid, interim^, False, True)
    var final = List[UInt8]()
    _hpack_literal(String(":status"), String("200"), final)
    _hpack_literal(String("content-type"), String("text/plain"), final)
    wire = _concat(wire^, _headers_frame(sid, final^, True, True))
    _feed(c, wire)

    var delivered = _delivered_status(c, sid)
    if delivered != 200:
        raise Error(
            "after a 103 interim + a 200 final, the caller must see 200;"
            + " got " + String(delivered)
        )
    if _slot_has_name(c, sid, String("link")):
        raise Error(
            "the 1xx interim response's 'link' header LEAKED into the"
            + " final response's header map (slot holds "
            + String(_slot_len(c, sid))
            + " pairs; the final response declared 1). A 1xx is a separate"
            + " message (RFC 9110 §15.2) and its fields are not the final"
            + " response's fields."
        )
    print("    OK")


def test_data_between_1xx_and_final_headers_is_malformed() raises:
    """RFC 9110 §15.2: a 1xx response "consists only of the status line and
    optional header fields" — it has no content. DATA arriving between the
    interim block and the final response head is a protocol error, not
    response body."""
    print("  test_data_between_1xx_and_final_headers_is_malformed...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    var interim = List[UInt8]()
    _hpack_literal(String(":status"), String("100"), interim)
    var wire = _headers_frame(sid, interim^, False, True)
    wire = _concat(wire^, _data_frame(sid, _bytes_of(String("nope")), False))
    var final = List[UInt8]()
    _hpack_literal(String(":status"), String("200"), final)
    wire = _concat(wire^, _headers_frame(sid, final^, True, True))
    _feed(c, wire)
    var summary = _refusal_summary(c, sid)
    if not _refused(summary):
        raise Error(
            "DATA between a 1xx interim response and the final response"
            + " head must be a stream error; the client accepted it and"
            + " prepended it to the 200's body"
        )
    print("    OK")


def test_data_before_any_headers_is_malformed() raises:
    """RFC 9113 §8.1: an HTTP/2 message is a HEADERS frame followed by
    zero or more CONTINUATION and then DATA. DATA on an OPEN stream that
    has not yet carried a response head is not body — there is no message
    for it to belong to."""
    print("  test_data_before_any_headers_is_malformed...")
    var sid = UInt32(1)
    var c = _client_with_open_stream(sid)
    _feed(c, _data_frame(sid, _bytes_of(String("early")), False))
    var summary = _refusal_summary(c, sid)
    if not _refused(summary):
        raise Error(
            "DATA arriving before any response HEADERS on an open stream"
            + " must be a stream error (RFC 9113 §8.1); the client"
            + " buffered it as response body instead"
        )
    print("    OK")


# =============================================================================
# §I — the generated response-shape matrix (Go's TestTransportResPattern,
#      reduced). A table finds mechanically what two hand-written shapes
#      cannot: the trailer-merge defect reproduces across every CONTINUATION
#      split, and the matrix says exactly which cells it touches.
# =============================================================================


def _split_frames(
    sid: UInt32,
    var block: List[UInt8],
    continuations: Int,
    end_stream: Bool,
) -> List[UInt8]:
    """Emit `block` as HEADERS + exactly `continuations` CONTINUATION
    frames, by choosing the frame cap that produces that many pieces. An
    EMPTY block is one HEADERS frame and cannot be split — the caller
    accounts for that cell."""
    var n = len(block)
    if n == 0 or continuations <= 0:
        return _headers_frame(sid, block^, end_stream, True)
    var pieces = continuations + 1
    var cap = n // pieces
    if n % pieces != 0:
        cap = cap + 1
    if cap < 1:
        cap = 1
    var out = List[UInt8]()
    split_header_block_into_frames(sid, block^, cap, end_stream, out)
    return out^


def test_res_pattern_matrix() raises:
    """c in {0,1,2} CONTINUATION frames x h in {1,2} HEADERS blocks x
    d in {0,1} DATA frames x t in {0,1,2} trailer fields — 36 cells.

    Every cell asserts ONE invariant that holds regardless of framing:
    the response head declared `:status 200` and exactly one regular
    field, so the caller must see 200 and must NOT see a trailer field.
    """
    print("  test_res_pattern_matrix...")
    var failed = List[String]()
    var checked = 0
    for c_n in range(0, 3):
        for h_n in range(1, 3):
            for d_n in range(0, 2):
                for t_n in range(0, 3):
                    if h_n == 1 and t_n != 0:
                        continue  # trailer fields need a trailer block
                    checked = checked + 1
                    var sid = UInt32(1)
                    var cl = _client_with_open_stream(sid)
                    var head = List[UInt8]()
                    _hpack_literal(String(":status"), String("200"), head)
                    _hpack_literal(
                        String("content-type"), String("text/plain"), head,
                    )
                    var head_end_stream = h_n == 1 and d_n == 0
                    var wire = _split_frames(
                        sid, head^, c_n, head_end_stream,
                    )
                    if d_n == 1:
                        var body_end = h_n == 1
                        wire = _concat(
                            wire^,
                            _data_frame(
                                sid, _bytes_of(String("hi")), body_end,
                            ),
                        )
                    if h_n == 2:
                        var trailer = List[UInt8]()
                        var ti = 0
                        while ti < t_n:
                            _hpack_literal(
                                String("x-trailer-") + String(ti),
                                String("v"),
                                trailer,
                            )
                            ti = ti + 1
                        wire = _concat(
                            wire^, _split_frames(sid, trailer^, c_n, True),
                        )
                    _feed(cl, wire)

                    var label = (
                        String("c=") + String(c_n) + String(" h=")
                        + String(h_n) + String(" d=") + String(d_n)
                        + String(" t=") + String(t_n)
                    )
                    var delivered = _delivered_status(cl, sid)
                    if delivered != 200:
                        failed.append(
                            String("  ") + label
                            + String(": caller status=") + String(delivered)
                            + String(" (expected 200)")
                        )
                        continue
                    var leaked = -1
                    var tj = 0
                    while tj < t_n:
                        if _slot_has_name(
                            cl, sid, String("x-trailer-") + String(tj),
                        ):
                            leaked = tj
                            break
                        tj = tj + 1
                    if leaked >= 0:
                        failed.append(
                            String("  ") + label
                            + String(": trailer field 'x-trailer-")
                            + String(leaked)
                            + String("' merged into the response header"
                                     + " map (slot holds ")
                            + String(_slot_len(cl, sid))
                            + String(" pairs; the head declared 1)")
                        )
    if len(failed) > 0:
        var msg = (
            String("response-shape matrix: ") + String(len(failed))
            + String(" of ") + String(checked)
            + String(" cells violate the head's own declaration.\n")
        )
        var k = 0
        while k < len(failed):
            msg = msg + failed[k] + String("\n")
            k = k + 1
        raise Error(msg)
    print("    OK — " + String(checked) + " cells")


# =============================================================================
# main — every case runs, every failure is reported.
# =============================================================================
#
# ⚠ WHY THIS `main` IS NOT THE PACKAGE'S USUAL STRAIGHT-LINE ONE. The
# neighbouring h2 tests call each case in sequence and let the first raise
# abort the binary. That is right when one case is expected to fail at a
# time; it is wrong for a conformance suite, where the FIRST failure would
# hide every other one and each re-run would surface exactly one more. Every
# case still runs, every failure is still printed with its own repro, and the
# binary still exits non-zero if ANY case failed — the gate is unchanged.


def main() raises:
    print("== L2 h2 client — malformed response + trailers (RFC 9113 §8.1.1) ==")
    var failures = List[String]()

    print(" §A controls")
    try:
        test_control_well_formed_response_is_accepted()
    except e:
        failures.append(String("control_well_formed_response: ") + String(e))
    try:
        test_control_headers_on_unopened_stream_is_protocol_error()
    except e:
        failures.append(String("control_headers_unopened: ") + String(e))
    try:
        test_control_data_on_unopened_stream_is_protocol_error()
    except e:
        failures.append(String("control_data_unopened: ") + String(e))
    try:
        test_control_continuation_without_headers_is_protocol_error()
    except e:
        failures.append(String("control_bare_continuation: ") + String(e))

    print(" §B :status")
    try:
        test_missing_status_is_malformed()
    except e:
        failures.append(String("missing_status: ") + String(e))
    try:
        test_malformed_status_values_table()
    except e:
        failures.append(String("malformed_status_values: ") + String(e))

    print(" §C pseudo-headers")
    try:
        test_unknown_pseudo_header_is_malformed()
    except e:
        failures.append(String("unknown_pseudo_header: ") + String(e))
    try:
        test_request_pseudo_headers_in_response_table()
    except e:
        failures.append(String("request_pseudo_in_response: ") + String(e))
    try:
        test_pseudo_header_after_regular_field_is_malformed()
    except e:
        failures.append(String("pseudo_after_regular: ") + String(e))
    try:
        test_duplicate_pseudo_header_is_malformed()
    except e:
        failures.append(String("duplicate_pseudo: ") + String(e))

    print(" §D field syntax")
    try:
        test_malformed_field_names_table()
    except e:
        failures.append(String("malformed_field_names: ") + String(e))
    try:
        test_malformed_field_values_table()
    except e:
        failures.append(String("malformed_field_values: ") + String(e))

    print(" §E connection-specific fields")
    try:
        test_connection_specific_headers_table()
    except e:
        failures.append(String("connection_specific_headers: ") + String(e))
    try:
        test_te_header_only_trailers_is_permitted()
    except e:
        failures.append(String("te_only_trailers: ") + String(e))

    print(" §F content-length")
    try:
        test_content_length_mismatch_table()
    except e:
        failures.append(String("content_length_mismatch: ") + String(e))
    try:
        test_content_length_with_sign_is_malformed()
    except e:
        failures.append(String("content_length_sign: ") + String(e))
    try:
        test_no_content_response_keeps_content_length()
    except e:
        failures.append(String("no_content_carve_out: ") + String(e))

    print(" §G trailers")
    try:
        test_trailers_must_not_overwrite_status()
    except e:
        failures.append(String("trailers_overwrite_status: ") + String(e))
    try:
        test_trailers_must_not_merge_into_response_headers()
    except e:
        failures.append(String("trailers_merge_into_headers: ") + String(e))
    try:
        test_trailer_block_with_pseudo_header_is_malformed()
    except e:
        failures.append(String("trailer_pseudo_header: ") + String(e))
    try:
        test_trailer_block_without_end_stream_is_malformed()
    except e:
        failures.append(String("trailer_no_end_stream: ") + String(e))
    try:
        test_trailer_field_name_uppercase_is_malformed()
    except e:
        failures.append(String("trailer_uppercase_name: ") + String(e))

    print(" §H 1xx informational")
    try:
        test_informational_1xx_does_not_leak_into_final_response()
    except e:
        failures.append(String("1xx_leaks_into_final: ") + String(e))
    try:
        test_data_between_1xx_and_final_headers_is_malformed()
    except e:
        failures.append(String("data_between_1xx_and_final: ") + String(e))
    try:
        test_data_before_any_headers_is_malformed()
    except e:
        failures.append(String("data_before_headers: ") + String(e))

    print(" §I response-shape matrix")
    try:
        test_res_pattern_matrix()
    except e:
        failures.append(String("res_pattern_matrix: ") + String(e))

    if len(failures) > 0:
        print("")
        print("==== MALFORMED-RESPONSE CONFORMANCE FAILURES ====")
        var i = 0
        while i < len(failures):
            print("[" + String(i + 1) + "] " + failures[i])
            i = i + 1
        raise Error(
            String("h2 client malformed-response conformance: ")
            + String(len(failures))
            + String(" case(s) FAILED (see the list above)")
        )
    print("== L2 h2 client malformed-response conformance PASSED ==")
