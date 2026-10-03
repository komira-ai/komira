# =============================================================================
# test_grpc_truncation_and_terminal.mojo — truncation, terminal-state
# stickiness, and the typed-status contract
# =============================================================================
#
# WHY THIS FILE EXISTS. A failure such as
#
#     HttpError[EOF_MID_RESPONSE: chunked body unterminated]
#
# is TRANSPORT-SHAPED: it escapes the typed-status contract every caller keys
# on. A gRPC client can have the SAME class of hole, arriving through a
# different codec, and this file is its falsifier set. Three separable claims,
# each of which a conformant gRPC client is required to honour and each of which
# is checked here against the shipped code:
#
#   (A) EVERY decode failure carries a STATUS. grpc-go fails an RPC whose
#       message cannot be parsed with a `status.Error` — never a bare error:
#       `codes.Internal` for "grpc: failed to unmarshal" / "received unexpected
#       payload format", `codes.Unimplemented` for an uninstalled decompressor,
#       `codes.ResourceExhausted` for a message over the receive limit. Our
#       contract is the `[grpc:<N>]` prefix (`format_grpc_error_message`), which
#       `parse_grpc_status_code` and `is_retryable_grpc_error` both key on. An
#       error with no `[grpc:` anchor is INVISIBLE to every classifier.
#
#   (B) A TRUNCATED MESSAGE IS AN ERROR, NEVER A CLEAN END. A stream that ends
#       mid-envelope is `io.ErrUnexpectedEOF` in grpc-go and fails the RPC. It
#       must never be reported as a successful end-of-stream that silently drops
#       the partial bytes — that is a SILENT WRONG ANSWER, the worst failure
#       mode a decoder has.
#
#   (C) A TERMINAL ERROR IS STICKY. Once a stream has ended with a non-OK
#       status, every subsequent poll must report that same status. A consumer
#       that re-polls after an error and is told "success" acts on a stream that
#       failed.
#
# Also pinned here: the zero-length message (`empty_unary` — the most basic
# interop case in the gRPC conformance suite, which the `test_L5_framing` cases,
# all using a non-empty payload, do not cover), the receive-size limit on both
# sides of its boundary, and the compressed-flag byte's VALUE space.
#
# ⚠ THE COMPRESSED-FLAG BYTE IS NOT A BITFIELD IN CLASSIC gRPC. Per
# PROTOCOL-HTTP2 the Compressed-Flag is "a 1 byte unsigned integer" whose only
# defined values are 0 and 1; grpc-go switches on the WHOLE BYTE and fails
# anything else with `codes.Internal, "grpc: received unexpected payload format
# %d"`. A decoder that tests two BITS (`0x01` COMPRESSED, `0x80` END_STREAM)
# lets 0x02..0x7F fall through as a plain uncompressed message and reads 0x80
# as an end-of-stream marker classic gRPC does not have at all.
#
# ⚠ SCOPE NOTE ON THE 0x01 CASE. `test_L5_stream`'s t8 case pins flag 0x01
# (a genuinely COMPRESSED envelope) to `UNKNOWN`. 0x01 is a VALID flag value, so
# it is a different conformance question (grpc-go answers `Unimplemented` there,
# for an uninstalled decompressor) and this file deliberately does NOT assert on
# it. Every flag byte asserted below is one the spec admits no reading of.
#
# ⚠ THE DRIVER RUNS EVERY CASE. `main` wraps each case so one RED does not mask
# the next — the point of the exercise is the full list of what conforms and
# what does not, not the first line that stops.
#
# Transport-free: no socket, no reactor, no thread. Hermetic.
# =============================================================================

from std.testing import assert_equal, assert_true, assert_false

from komira_grpc import (
    ClientFramer,
    ProtocolConnectProto,
    ProtocolGrpcProto,
    ServerStreamDecoder,
    StreamOutcome,
    STREAM_OUTCOME_END_ERROR,
    STREAM_OUTCOME_END_OK,
    STREAM_OUTCOME_MESSAGE,
    STREAM_OUTCOME_PENDING,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_RESOURCE_EXHAUSTED,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_UNKNOWN,
    decode_unary_response,
    encode_stream_message,
    parse_grpc_status_code,
)
from komira_grpc.framing import MAX_RECV_MESSAGE_SIZE
from komira_connect.envelope import (
    ENVELOPE_FLAG_COMPRESSED,
    ENVELOPE_FLAG_END_STREAM,
    write_envelope,
    write_envelope_header,
)
from komira_http.client.header_map import HeaderMap


# =============================================================================
# §0 — fixtures
# =============================================================================


def _bytes(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        out.append(bs[i])
        i = i + 1
    return out^


def _filler(n: Int) -> List[UInt8]:
    """`n` deterministic bytes."""
    var out = List[UInt8]()
    var i = 0
    while i < n:
        out.append(UInt8(i & 0xFF))
        i = i + 1
    return out^


def _hex1(n: Int) -> String:
    if n < 10:
        return String(chr(ord("0") + n))
    return String(chr(ord("A") + n - 10))


def _hex2(b: UInt8) -> String:
    return _hex1(Int(b) >> 4) + _hex1(Int(b) & 0x0F)


def _kind_name(k: UInt8) -> String:
    if k == STREAM_OUTCOME_MESSAGE:
        return String("MESSAGE")
    if k == STREAM_OUTCOME_PENDING:
        return String("PENDING")
    if k == STREAM_OUTCOME_END_OK:
        return String("END_OK")
    if k == STREAM_OUTCOME_END_ERROR:
        return String("END_ERROR")
    return String("kind=") + String(Int(k))


def _ok_trailers() raises -> HeaderMap:
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("0"))
    return tr^


def _decode_unary_failure_message(var body: List[UInt8]) raises -> String:
    """Drive `decode_unary_response[ProtocolGrpcProto]` over a malformed
    classic-gRPC unary body and return the message it raised.

    Raises if the decode SUCCEEDS — every body handed to this helper is one the
    codec is required to reject, so a successful decode is itself the failure.
    """
    var raised = False
    var message = String("")
    try:
        var span = decode_unary_response[ProtocolGrpcProto](
            Span(body), UInt16(200)
        )
        _ = len(span)
    except e:
        raised = True
        message = String(e)
    if not raised:
        raise Error(
            "decode_unary_response ACCEPTED a body the gRPC wire format"
            " forbids — it must raise"
        )
    return message^


# =============================================================================
# §1 — (A) the typed-status contract: the four `grpc_decode_unary` raise arms
# =============================================================================


def test_decode_unary_failure_arms_carry_a_typed_grpc_status() raises:
    """★ EVERY `grpc_decode_unary` FAILURE ARM CARRIES A STATUS.

    `decode_unary_response[ProtocolGrpcProto]` delegates to
    `komira_connect.codec_grpc.grpc_decode_unary`, which has four failure arms
    (plus the `split_first_envelope` truncation raise it calls into). If one
    raised a BARE `Error(...)` string with no `[grpc:<N>]` prefix, then,
    because the message carries no `[grpc:` anchor:
      * `parse_grpc_status_code` would return -1,
      * `is_retryable_grpc_error` would return False for EVERY policy,
      * every caller classifier that keys on the anchor would miss it entirely.

    That is precisely the shape of `HttpError[EOF_MID_RESPONSE: chunked body
    unterminated]`: a transport-class failure that reaches the caller as an
    untyped error and is therefore invisible to the layer whose job is to decide
    what to do about it.

    The bar (grpc-go `parser.recvMsg` / `recvAndDecompress`): a malformed or
    truncated message is `codes.Internal`; a compressed message with no
    decompressor is `codes.Unimplemented`. Both are STATUSES. This test asserts
    only the weaker, un-arguable half — that SOME status rides on the error.
    """
    var problems = String("")
    var n_failing = 0

    # --- arm 1: empty body (`len(body) == 0`). -------------------------------
    var empty = List[UInt8]()
    var m1 = _decode_unary_failure_message(empty^)
    if parse_grpc_status_code(m1) < 0:
        n_failing = n_failing + 1
        problems += String("\n  [1/4] EMPTY BODY -> no [grpc:] anchor: ") + m1

    # --- arm 2: truncated envelope (header declares 100, body carries 20). ---
    var truncated = List[UInt8]()
    write_envelope_header(truncated, UInt8(0), 100)
    var short_payload = _filler(20)
    for i in range(len(short_payload)):
        truncated.append(short_payload[i])
    var m2 = _decode_unary_failure_message(truncated^)
    if parse_grpc_status_code(m2) < 0:
        n_failing = n_failing + 1
        problems += (
            String("\n  [2/4] TRUNCATED ENVELOPE -> no [grpc:] anchor: ") + m2
        )

    # --- arm 3: compressed envelope (no decompressor installed). -------------
    var compressed = List[UInt8]()
    write_envelope(
        compressed, ENVELOPE_FLAG_COMPRESSED, Span(_bytes(String("gzipped")))
    )
    var m3 = _decode_unary_failure_message(compressed^)
    if parse_grpc_status_code(m3) < 0:
        n_failing = n_failing + 1
        problems += (
            String("\n  [3/4] COMPRESSED ENVELOPE -> no [grpc:] anchor: ") + m3
        )

    # --- arm 4: trailing bytes after the single unary envelope. --------------
    var trailing = List[UInt8]()
    write_envelope(trailing, UInt8(0), Span(_bytes(String("one"))))
    write_envelope(trailing, UInt8(0), Span(_bytes(String("two"))))
    var m4 = _decode_unary_failure_message(trailing^)
    if parse_grpc_status_code(m4) < 0:
        n_failing = n_failing + 1
        problems += (
            String("\n  [4/4] TRAILING BYTES -> no [grpc:] anchor: ") + m4
        )

    if n_failing > 0:
        raise Error(
            String(n_failing)
            + " of 4 `grpc_decode_unary` failure arms raise an UNTYPED error."
            " A decode failure with no `[grpc:<N>]` anchor is invisible to"
            " `parse_grpc_status_code` (-1), to `is_retryable_grpc_error`"
            " (False under every policy) and to every caller classifier that"
            " keys on the anchor — the gRPC analogue of an"
            " `EOF_MID_RESPONSE` defect. grpc-go answers each of these with a"
            " status (Internal / Unimplemented)."
            + problems
        )


def test_max_recv_refusal_carries_a_typed_grpc_status() raises:
    """The receive-size refusal must carry the `[grpc:8]` anchor, not merely
    name RESOURCE_EXHAUSTED *in prose* — prose alone is the same escape as the
    four arms above: a human reading a log sees the right word, while every
    classifier sees an anchorless transport error. Kept separate from the
    four-arm test so one failure does not mask the other.
    """
    var f = ClientFramer.new()
    var header = List[UInt8]()
    write_envelope_header(header, UInt8(0), MAX_RECV_MESSAGE_SIZE + 1)
    f.feed(Span(header))

    var raised = False
    var message = String("")
    try:
        var opt = f.try_pop_envelope()
        _ = opt.__bool__()
    except e:
        raised = True
        message = String(e)
    assert_true(
        raised,
        "a declared payload one byte over MAX_RECV_MESSAGE_SIZE must be"
        " refused before it is buffered",
    )
    assert_true(
        String("RESOURCE_EXHAUSTED") in message,
        String("the refusal must name the status the spec mandates. got: ")
        + message,
    )
    if parse_grpc_status_code(message) < 0:
        raise Error(
            "the over-limit refusal raises an UNTYPED error — it names"
            " RESOURCE_EXHAUSTED in prose but carries no `[grpc:"
            + String(Int(GRPC_STATUS_RESOURCE_EXHAUSTED))
            + "]` anchor, so `parse_grpc_status_code` returns -1 and every"
            " caller classifier misses it. got: "
            + message
        )


# =============================================================================
# §2 — (B) a truncated message is an error, never a clean end
# =============================================================================


def test_truncated_final_message_is_not_a_clean_end_of_stream() raises:
    """★ A SILENT WRONG ANSWER: a stream whose last message is cut short must
    not be reported as a SUCCESSFUL end with the partial bytes vanishing.

    Wire: a 5-byte prefix declaring 10 payload bytes, followed by only 6 — then
    the classic-gRPC terminal trailers `grpc-status: 0`.

    `ServerStreamDecoder.try_next_message` asks the framer for an envelope
    (None — 6 of 10 bytes), then finds `_pending_status`. Reporting END_OK
    there would never mention the 6 buffered bytes, and the consumer would be
    told the stream completed successfully.

    grpc-go reads the 5-byte header, then reads exactly `length` bytes, and a
    short read at end-of-stream is `io.ErrUnexpectedEOF` — the RPC FAILS. The
    information needed to detect this is already in hand:
    `ClientFramer.unconsumed_len()` is 11, not 0.
    """
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var wire = List[UInt8]()
    write_envelope_header(wire, UInt8(0), 10)
    var partial = _filler(6)
    for i in range(len(partial)):
        wire.append(partial[i])
    d.feed(Span(wire))
    # Pre-condition: nothing is poppable yet — the message is incomplete.
    assert_equal(
        d.try_next_message().kind,
        STREAM_OUTCOME_PENDING,
        "6 of 10 payload bytes is not a message yet",
    )
    # The stream now ENDS: classic-gRPC terminal trailers, status OK.
    d.feed_trailers(_ok_trailers())
    var o = d.try_next_message()
    if o.kind != STREAM_OUTCOME_END_ERROR:
        raise Error(
            "a stream that ended 4 bytes short of a 10-byte message reported "
            + _kind_name(o.kind)
            + " — the 11 buffered bytes were silently discarded and the"
            " consumer was told the stream completed successfully. A truncated"
            " message is `io.ErrUnexpectedEOF` in grpc-go and fails the RPC;"
            " it must surface as END_ERROR (INTERNAL), never END_OK"
        )


def test_incomplete_length_prefix_at_stream_end_is_not_a_clean_end() raises:
    """The same defect with FEWER THAN FIVE bytes: a stream that ends inside the
    length prefix itself.

    3 bytes of a 5-byte prefix, then `grpc-status: 0`. The framer cannot even
    read a header, so it returns None; a decoder reporting END_OK here would
    read as "the stream ended cleanly with zero messages", which is a
    legitimate and common gRPC outcome and therefore indistinguishable from
    this corruption.
    """
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var wire = List[UInt8]()
    wire.append(UInt8(0))
    wire.append(UInt8(0))
    wire.append(UInt8(0))
    d.feed(Span(wire))
    d.feed_trailers(_ok_trailers())
    var o = d.try_next_message()
    if o.kind != STREAM_OUTCOME_END_ERROR:
        raise Error(
            "a stream that ended 3 bytes into a 5-byte length prefix reported "
            + _kind_name(o.kind)
            + " — indistinguishable from the legitimate 'ended cleanly with"
            " zero messages' outcome. It must name an incomplete length prefix"
            " (END_ERROR / INTERNAL)"
        )


def test_client_framer_leaves_the_truncation_evidence_in_hand() raises:
    """The FRAMER's half of the two cases above, asserted positively so the
    responsibility is precisely located.

    `ClientFramer` has no end-of-stream signal — `try_pop_envelope() -> None`
    means BOTH "feed me more" and (at end-of-stream) "this message is
    truncated", and the framer cannot tell them apart because only its caller
    knows the stream ended, so the distinction belongs to the caller.

    What it DOES have is `unconsumed_len()`, which is non-zero in exactly the
    truncated case. This test pins that, so the caller's truncation check has a
    supported primitive to build on and it cannot regress.
    """
    var f = ClientFramer.new()
    var wire = List[UInt8]()
    write_envelope_header(wire, UInt8(0), 10)
    var partial = _filler(6)
    for i in range(len(partial)):
        wire.append(partial[i])
    f.feed(Span(wire))
    assert_false(
        f.try_pop_envelope().__bool__(),
        "6 of 10 payload bytes is not a poppable envelope",
    )
    assert_equal(
        f.unconsumed_len(),
        11,
        "the 5 header bytes + 6 payload bytes are still buffered — the"
        " evidence a terminal check needs is in hand",
    )
    var f2 = ClientFramer.new()
    var three = List[UInt8]()
    three.append(UInt8(0))
    three.append(UInt8(0))
    three.append(UInt8(0))
    f2.feed(Span(three))
    assert_false(f2.try_pop_envelope().__bool__(), "3 bytes is not a header")
    assert_equal(
        f2.unconsumed_len(), 3, "the 3 prefix bytes are still buffered"
    )


# =============================================================================
# §3 — (C) a terminal ERROR must be sticky, exactly as a terminal OK is
# =============================================================================


def test_end_error_is_sticky_across_repeated_polls() raises:
    """★ NOT AN ERROR REPORTED EXACTLY ONCE, AND SUCCESS EVERY TIME AFTER.

    A decoder whose replay is

        if self._terminated:
            return StreamOutcome.end_ok()

    — with `_terminated` set by BOTH terminal paths and `_pending_status.take()`
    emptying the Optional — yields END_ERROR(14) on the FIRST poll after
    non-OK trailers and END_OK on every poll after it. A consumer that
    re-polls — a retry wrapper, a drain-to-completion loop, a second pass over
    an iterator — would be told the stream succeeded.

    `test_L5_stream`'s t7 pins stickiness for the OK case only, which cannot
    see this: with the sticky value hardcoded to `end_ok()`, the OK case is
    sticky by accident rather than by construction.
    """
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var tr = HeaderMap()
    tr.append(String("grpc-status"), String("14"))
    tr.append(String("grpc-message"), String("upstream-unavailable"))
    d.feed_trailers(tr)

    var o1 = d.try_next_message()
    assert_equal(o1.kind, STREAM_OUTCOME_END_ERROR, "first poll is END_ERROR")
    assert_equal(o1.error.code, GRPC_STATUS_UNAVAILABLE, "first poll code 14")

    var o2 = d.try_next_message()
    if o2.kind != STREAM_OUTCOME_END_ERROR:
        raise Error(
            "the SECOND poll after a non-OK terminal status reported "
            + _kind_name(o2.kind)
            + " — a consumer that re-polls after an error is told the stream"
            " succeeded. A terminal error must be as sticky as a terminal OK"
        )
    assert_equal(o2.error.code, GRPC_STATUS_UNAVAILABLE, "second poll code 14")

    var o3 = d.try_next_message()
    assert_equal(
        o3.kind, STREAM_OUTCOME_END_ERROR, "third poll is still END_ERROR"
    )
    assert_equal(o3.error.code, GRPC_STATUS_UNAVAILABLE, "third poll code 14")


def test_end_error_from_a_connect_end_stream_envelope_is_sticky() raises:
    """The same stickiness claim on the OTHER terminal path — the Connect
    end-of-stream envelope — so stickiness at one call site cannot be mistaken
    for stickiness of the class.
    """
    var d = ServerStreamDecoder[ProtocolConnectProto].new()
    var wire = List[UInt8]()
    var err_json = _bytes(
        String('{"error":{"code":"not_found","message":"user 42 not found"}}')
    )
    write_envelope(wire, ENVELOPE_FLAG_END_STREAM, Span(err_json))
    d.feed(Span(wire))

    var o1 = d.try_next_message()
    assert_equal(o1.kind, STREAM_OUTCOME_END_ERROR, "first poll is END_ERROR")
    var first_code = o1.error.code

    var o2 = d.try_next_message()
    if o2.kind != STREAM_OUTCOME_END_ERROR:
        raise Error(
            "the SECOND poll after a Connect end-of-stream ERROR envelope"
            " reported "
            + _kind_name(o2.kind)
            + " — the terminal error is not sticky on this path either"
        )
    assert_equal(
        o2.error.code, first_code, "the sticky status must be the same status"
    )


def test_end_error_from_an_unreadable_envelope_is_sticky() raises:
    """And on the THIRD terminal-error path: the compressed-envelope refusal,
    which also sets `_terminated` and must not be followed by END_OK forever.
    """
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var wire = List[UInt8]()
    write_envelope(
        wire, ENVELOPE_FLAG_COMPRESSED, Span(_bytes(String("gzipped")))
    )
    d.feed(Span(wire))

    var o1 = d.try_next_message()
    assert_equal(o1.kind, STREAM_OUTCOME_END_ERROR, "first poll is END_ERROR")
    var o2 = d.try_next_message()
    if o2.kind != STREAM_OUTCOME_END_ERROR:
        raise Error(
            "the SECOND poll after an unreadable-envelope refusal reported "
            + _kind_name(o2.kind)
            + " — the terminal error is not sticky on this path either"
        )


# =============================================================================
# §4 — the zero-length message (`empty_unary`)
# =============================================================================


def test_zero_length_message_yields_one_empty_message() raises:
    """`00 00 00 00 00` and nothing more is ONE message with a 0-byte payload.

    This is the most basic interop case there is — `google.protobuf.Empty` is
    the response of a large fraction of real RPCs, and its serialization is zero
    bytes. Every existing `test_L5_framing` case uses a non-empty payload, so a
    framer that treated `length == 0` as "incomplete" would pass all ten of them
    and hang on every real `empty_unary` call.

    Pinned at all three altitudes the byte sequence passes through.
    """
    # (a) the framer.
    var f = ClientFramer.new()
    var wire = List[UInt8]()
    write_envelope_header(wire, UInt8(0), 0)
    f.feed(Span(wire))
    var opt = f.try_pop_envelope()
    assert_true(
        opt.__bool__(),
        "a zero-length envelope is a COMPLETE message, not an incomplete one",
    )
    var env = opt.take()
    assert_equal(len(env.payload), 0, "the payload is 0 bytes")
    assert_equal(f.unconsumed_len(), 0, "all 5 bytes consumed")
    assert_false(
        f.try_pop_envelope().__bool__(), "and there is not a second message"
    )

    # (b) the streaming decoder.
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var wire2 = List[UInt8]()
    write_envelope_header(wire2, UInt8(0), 0)
    d.feed(Span(wire2))
    var o = d.try_next_message()
    assert_equal(
        o.kind,
        STREAM_OUTCOME_MESSAGE,
        "a zero-length envelope is a MESSAGE outcome",
    )
    assert_equal(len(o.message_bytes), 0, "carrying 0 payload bytes")

    # (c) the unary decode path.
    var body = List[UInt8]()
    write_envelope_header(body, UInt8(0), 0)
    var inner = decode_unary_response[ProtocolGrpcProto](
        Span(body), UInt16(200)
    )
    assert_equal(len(inner), 0, "empty_unary decodes to a 0-byte message")


def test_ten_zero_length_messages_are_ten_messages() raises:
    """Ten back-to-back `empty_unary` responses on one server-stream are ten
    messages, not one and a hang. Guards the cursor arithmetic in the
    `length == 0` case specifically."""
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var wire = List[UInt8]()
    var i = 0
    while i < 10:
        write_envelope_header(wire, UInt8(0), 0)
        i = i + 1
    d.feed(Span(wire))
    var seen = 0
    while seen < 10:
        var o = d.try_next_message()
        if o.kind != STREAM_OUTCOME_MESSAGE:
            raise Error(
                String("expected 10 zero-length messages; message ")
                + String(seen + 1)
                + " came back as "
                + _kind_name(o.kind)
            )
        assert_equal(len(o.message_bytes), 0, "each is 0 bytes")
        seen = seen + 1
    assert_equal(
        d.try_next_message().kind,
        STREAM_OUTCOME_PENDING,
        "and the eleventh poll is PENDING, not an eleventh message",
    )


# =============================================================================
# §5 — the receive-size limit, on BOTH sides of its boundary
# =============================================================================


def test_max_recv_message_size_boundary_both_sides() raises:
    """A declared length of exactly `MAX_RECV_MESSAGE_SIZE` must POP; one byte
    more must be REFUSED.

    `ClientFramer.try_pop_envelope` spells the comparison `length > MAX_RECV_MESSAGE_SIZE`,
    so the limit is INCLUSIVE — a message of exactly the documented maximum is
    legal, which matches gRPC's own `maxReceiveMessageSize` semantics. Both
    sides are pinned because a lone over-limit test passes just as happily
    against a `>=`, which would reject the largest LEGAL message.
    """
    # -- at the limit: must pop.
    var at_limit = List[UInt8]()
    write_envelope_header(at_limit, UInt8(0), MAX_RECV_MESSAGE_SIZE)
    var k = 0
    while k < MAX_RECV_MESSAGE_SIZE:
        at_limit.append(UInt8(k & 0xFF))
        k = k + 1
    var f = ClientFramer.new()
    f.feed_owned(at_limit^)
    var opt = f.try_pop_envelope()
    assert_true(
        opt.__bool__(),
        "a message of exactly MAX_RECV_MESSAGE_SIZE is legal and must pop —"
        " the comparison is `>`, so the limit is inclusive",
    )
    var env = opt.take()
    assert_equal(
        len(env.payload),
        MAX_RECV_MESSAGE_SIZE,
        "the whole payload comes back",
    )

    # -- one byte over: must refuse, from the HEADER alone.
    var over = List[UInt8]()
    write_envelope_header(over, UInt8(0), MAX_RECV_MESSAGE_SIZE + 1)
    var f2 = ClientFramer.new()
    f2.feed(Span(over))
    var raised = False
    var message = String("")
    try:
        var o = f2.try_pop_envelope()
        _ = o.__bool__()
    except e:
        raised = True
        message = String(e)
    assert_true(
        raised,
        "one byte over the limit must be refused BEFORE the client commits to"
        " buffering it — the refusal reads the 5-byte header only",
    )
    assert_true(
        String("RESOURCE_EXHAUSTED") in message,
        String("the refusal must name the mandated status. got: ") + message,
    )


def test_max_recv_refusal_propagates_out_of_try_next_message() raises:
    """The refusal must reach the CALLER as a raise, not present as a terminated
    stream.

    `ServerStreamDecoder.try_next_message` calls `try_pop_envelope` without a
    `try`, so the raise propagates — which is the correct shape: a decoder that
    swallowed it into END_ERROR would be indistinguishable from an ordinary
    non-OK status, and the RPC's failure mode would read as a server decision
    rather than a client limit.
    """
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var over = List[UInt8]()
    write_envelope_header(over, UInt8(0), MAX_RECV_MESSAGE_SIZE + 1)
    d.feed(Span(over))
    var raised = False
    var message = String("")
    try:
        var o = d.try_next_message()
        message = String("returned ") + _kind_name(o.kind)
    except e:
        raised = True
        message = String(e)
    assert_true(
        raised,
        String(
            "an over-limit declared length must raise out of"
            " try_next_message, not present as a stream outcome. got: "
        )
        + message,
    )
    assert_true(
        String("RESOURCE_EXHAUSTED") in message,
        String("and the raise must name the status. got: ") + message,
    )


# =============================================================================
# §6 — the compressed-flag byte is a VALUE, not a bitfield
# =============================================================================


def _grpc_outcome_for_flag(flag: UInt8) raises -> Tuple[UInt8, UInt8]:
    """Feed ONE classic-gRPC envelope whose flags byte is `flag` and report
    (outcome kind, error code)."""
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var wire = List[UInt8]()
    write_envelope(wire, flag, Span(_bytes(String("payload"))))
    d.feed(Span(wire))
    var o = d.try_next_message()
    return (o.kind, o.error.code)


def test_invalid_compressed_flag_bytes_fail_the_rpc_with_internal() raises:
    """★ 0x02..0xFF ARE NOT FLAG COMBINATIONS — THEY ARE INVALID BYTES.

    Per PROTOCOL-HTTP2 the Compressed-Flag is a 1-byte unsigned integer whose
    only defined values are 0 and 1. grpc-go switches on the whole byte and
    answers anything else with

        status.Errorf(codes.Internal,
                      "grpc: received unexpected payload format %d", pf)

    A decoder that tests two BITS instead would get every one wrong:

      * 0x02, 0x7F — neither bit set — would be delivered to the application
        as an ORDINARY UNCOMPRESSED MESSAGE. A framing desynchronisation, a
        gRPC-unaware intermediary, or a peer speaking a different envelope
        dialect would be handed straight through as valid data.
      * 0x80 — read as END_STREAM, a marker classic gRPC over HTTP/2 does not
        have (its terminal status rides in HTTP/2 trailers). The stream would
        be TERMINATED, and `_parse_connect_end_stream` would find no `"error"`
        key in the protobuf payload, so it would terminate as END_OK: a
        corrupt byte silently truncates the response and reports success.
      * 0x03, 0xFF — bit 0 set, so the compressed arm would fire and answer
        UNKNOWN rather than naming the byte.

    ⚠ 0x01 is deliberately NOT in this set: it is a VALID flag value, and what
    status a genuinely-compressed envelope deserves is a separate question
    (`test_L5_stream`'s t8 pins UNKNOWN there; grpc-go answers
    `Unimplemented` for an uninstalled decompressor). Every byte below is one
    the spec admits no reading of at all.
    """
    var flags = List[UInt8]()
    flags.append(UInt8(0x02))
    flags.append(UInt8(0x03))
    flags.append(UInt8(0x7F))
    flags.append(UInt8(0x80))
    flags.append(UInt8(0xFF))

    var problems = String("")
    var n_failing = 0
    for i in range(len(flags)):
        var flag = flags[i]
        var got = _grpc_outcome_for_flag(flag)
        var kind = got[0]
        var code = got[1]
        if kind != STREAM_OUTCOME_END_ERROR or code != GRPC_STATUS_INTERNAL:
            n_failing = n_failing + 1
            problems += (
                String("\n  flags=0x")
                + _hex2(flag)
                + " -> "
                + _kind_name(kind)
                + " (code "
                + String(Int(code))
                + "); required: END_ERROR / INTERNAL("
                + String(Int(GRPC_STATUS_INTERNAL))
                + ")"
            )

    if n_failing > 0:
        raise Error(
            String(n_failing)
            + " of 5 invalid Compressed-Flag bytes were not failed with"
            " INTERNAL. The flags byte is a 1-byte unsigned VALUE whose only"
            " defined readings are 0 and 1, not a bitfield; grpc-go answers"
            ' every other value with Internal "received unexpected payload'
            ' format". Reading it as two bits delivers 0x02..0x7F to the'
            " application as ordinary data and reads 0x80 as an end-of-stream"
            " marker classic gRPC does not have."
            + problems
        )


def test_flag_0x80_on_classic_grpc_truncates_the_stream_silently() raises:
    """The sharpest single consequence of the bitfield reading, isolated so it
    cannot be lost inside the parameterised failure above.

    Wire: TWO ordinary classic-gRPC messages, the first of which carries a
    corrupt flags byte 0x80. A conformant client fails the RPC. The bitfield
    reading terminates the stream as a SUCCESS and never delivers the second
    message — a truncated response reported as a complete one.
    """
    var d = ServerStreamDecoder[ProtocolGrpcProto].new()
    var wire = List[UInt8]()
    write_envelope(wire, UInt8(0x80), Span(_bytes(String("FIRST"))))
    encode_stream_message[ProtocolGrpcProto](
        wire, Span(_bytes(String("SECOND")))
    )
    d.feed(Span(wire))
    var o = d.try_next_message()
    if o.kind == STREAM_OUTCOME_END_OK:
        raise Error(
            "a classic-gRPC envelope with flags byte 0x80 TERMINATED the"
            " stream as END_OK — the second message was never delivered and"
            " the consumer was told the response was complete. Classic gRPC"
            " over HTTP/2 has no end-of-stream envelope flag at all; its"
            " terminal status rides in HTTP/2 trailers"
        )
    if o.kind != STREAM_OUTCOME_END_ERROR:
        raise Error(
            "flags byte 0x80 on classic gRPC came back as "
            + _kind_name(o.kind)
            + "; it must fail the RPC with INTERNAL"
        )


# =============================================================================
# §7 — driver
# =============================================================================


def main() raises:
    print("test_grpc_truncation_and_terminal: gRPC truncation + terminal state")
    var failures = List[String]()

    try:
        test_decode_unary_failure_arms_carry_a_typed_grpc_status()
        print("  PASS  decode-unary failure arms carry a typed status")
    except e:
        failures.append(
            String("decode_unary_failure_arms_carry_a_typed_grpc_status: ")
            + String(e)
        )
        print("  FAIL  decode-unary failure arms carry a typed status")

    try:
        test_max_recv_refusal_carries_a_typed_grpc_status()
        print("  PASS  max-recv refusal carries a typed status")
    except e:
        failures.append(
            String("max_recv_refusal_carries_a_typed_grpc_status: ") + String(e)
        )
        print("  FAIL  max-recv refusal carries a typed status")

    try:
        test_truncated_final_message_is_not_a_clean_end_of_stream()
        print("  PASS  truncated final message is not a clean end")
    except e:
        failures.append(
            String("truncated_final_message_is_not_a_clean_end_of_stream: ")
            + String(e)
        )
        print("  FAIL  truncated final message is not a clean end")

    try:
        test_incomplete_length_prefix_at_stream_end_is_not_a_clean_end()
        print("  PASS  incomplete length prefix is not a clean end")
    except e:
        failures.append(
            String(
                "incomplete_length_prefix_at_stream_end_is_not_a_clean_end: "
            )
            + String(e)
        )
        print("  FAIL  incomplete length prefix is not a clean end")

    try:
        test_client_framer_leaves_the_truncation_evidence_in_hand()
        print("  PASS  framer leaves the truncation evidence in hand")
    except e:
        failures.append(
            String("client_framer_leaves_the_truncation_evidence_in_hand: ")
            + String(e)
        )
        print("  FAIL  framer leaves the truncation evidence in hand")

    try:
        test_end_error_is_sticky_across_repeated_polls()
        print("  PASS  END_ERROR is sticky (trailers path)")
    except e:
        failures.append(
            String("end_error_is_sticky_across_repeated_polls: ") + String(e)
        )
        print("  FAIL  END_ERROR is sticky (trailers path)")

    try:
        test_end_error_from_a_connect_end_stream_envelope_is_sticky()
        print("  PASS  END_ERROR is sticky (Connect end-stream path)")
    except e:
        failures.append(
            String("end_error_from_a_connect_end_stream_envelope_is_sticky: ")
            + String(e)
        )
        print("  FAIL  END_ERROR is sticky (Connect end-stream path)")

    try:
        test_end_error_from_an_unreadable_envelope_is_sticky()
        print("  PASS  END_ERROR is sticky (unreadable-envelope path)")
    except e:
        failures.append(
            String("end_error_from_an_unreadable_envelope_is_sticky: ")
            + String(e)
        )
        print("  FAIL  END_ERROR is sticky (unreadable-envelope path)")

    try:
        test_zero_length_message_yields_one_empty_message()
        print("  PASS  zero-length message (empty_unary)")
    except e:
        failures.append(
            String("zero_length_message_yields_one_empty_message: ") + String(e)
        )
        print("  FAIL  zero-length message (empty_unary)")

    try:
        test_ten_zero_length_messages_are_ten_messages()
        print("  PASS  ten zero-length messages are ten messages")
    except e:
        failures.append(
            String("ten_zero_length_messages_are_ten_messages: ") + String(e)
        )
        print("  FAIL  ten zero-length messages are ten messages")

    try:
        test_max_recv_message_size_boundary_both_sides()
        print("  PASS  MAX_RECV boundary, both sides")
    except e:
        failures.append(
            String("max_recv_message_size_boundary_both_sides: ") + String(e)
        )
        print("  FAIL  MAX_RECV boundary, both sides")

    try:
        test_max_recv_refusal_propagates_out_of_try_next_message()
        print("  PASS  MAX_RECV refusal propagates out of try_next_message")
    except e:
        failures.append(
            String("max_recv_refusal_propagates_out_of_try_next_message: ")
            + String(e)
        )
        print("  FAIL  MAX_RECV refusal propagates out of try_next_message")

    try:
        test_invalid_compressed_flag_bytes_fail_the_rpc_with_internal()
        print("  PASS  invalid Compressed-Flag bytes fail with INTERNAL")
    except e:
        failures.append(
            String("invalid_compressed_flag_bytes_fail_the_rpc_with_internal: ")
            + String(e)
        )
        print("  FAIL  invalid Compressed-Flag bytes fail with INTERNAL")

    try:
        test_flag_0x80_on_classic_grpc_truncates_the_stream_silently()
        print("  PASS  flag 0x80 on classic gRPC does not truncate silently")
    except e:
        failures.append(
            String("flag_0x80_on_classic_grpc_truncates_the_stream_silently: ")
            + String(e)
        )
        print("  FAIL  flag 0x80 on classic gRPC does not truncate silently")

    if len(failures) > 0:
        var report = String("test_grpc_truncation_and_terminal: ")
        report += String(len(failures)) + " case(s) FAILED\n"
        for i in range(len(failures)):
            report += String("\n---- ") + failures[i] + "\n"
        raise Error(report)
    print("test_grpc_truncation_and_terminal: ALL PASS")
