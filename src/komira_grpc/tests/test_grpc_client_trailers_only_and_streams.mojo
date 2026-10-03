# =============================================================================
# test_grpc_client_trailers_only_and_streams.mojo — GrpcClient's four entry
# points against the response shapes real gRPC servers actually send
# =============================================================================
#
# WHY THIS FILE EXISTS. `GrpcClient` has four entry points, and each carries a
# terminal-status check written for a shape a happy-path test never drives (a
# TRAILERS-ONLY response). The check exists because without it a real failure
# — `ReadObject` on a missing object, `WriteObject` with a stale
# `ifGenerationMatch` — comes back to the caller as an EMPTY BUFFER or as a
# generic transport error instead of NOT_FOUND / FAILED_PRECONDITION.
#
# THE TRAILERS-ONLY SHAPE, which is what most of this file is about. Per
# PROTOCOL-HTTP2 §"Responses", a gRPC server that fails before producing any
# message sends ONE HEADERS frame with END_STREAM set, carrying `:status: 200`,
# `content-type: application/grpc` and a non-zero `grpc-status`. No DATA frame
# ever arrives. It is not an edge case: it is how every permission failure,
# every not-found and every unimplemented method is delivered, and gRPC's own
# interop suite has a dedicated `unimplemented_method` case for it.
#
# ⚠ A TRANSPORT THAT CANNOT DELIVER IT reports
#
#     HttpError[EOF_MID_RESPONSE]: peer closed while h2 streams in flight
#
# instead of surfacing the status, so the status never reaches the retry layer
# at all (`test_unary_status_retry`'s fixture scripts a NON-EMPTY body for this
# reason). This file asserts the bodyless shape directly.
#
# TWO RIGS, and which one each case needs:
#   * the HTTP/1.1 `ScriptedStream` (as `test_e2e_grpc_client.mojo`) wherever
#     the claim is about the BODY — it cannot carry trailers at all;
#   * the HTTP/2 `ScriptedStream` (as `test_unary_status_retry.mojo`) wherever
#     the claim is about HEADERS or TRAILERS. Its two load-bearing properties —
#     ALPN h2 reported, and `set_max_read_per_call(1)` — are stated at
#     `_h2_client`.
#
# Hermetic — no socket, no network, no thread.
#
# ⚠ THE DRIVER RUNS EVERY CASE. `main` wraps each one so a RED does not mask
# the next.
# =============================================================================

from std.sys.info import CompilationTarget
from std.testing import assert_equal, assert_true, assert_false

from komira_async.cancellation.token import CancellationToken
from komira_async.ops.waker_sink import NoopSink
from komira_async.reactor.reactor import BACKEND_EPOLL, BACKEND_KQUEUE, Reactor
from komira_async.runtime.runtime import PerCoreAsyncRuntime

from komira_http_client.client import HttpClient
from komira_http_client.url import Url
from komira_http_core.codec.h2.frame import (
    SettingsEntry,
    encode_data_frame,
    encode_headers_frame,
    encode_settings_frame,
)
from komira_http_core.codec.h2.hpack import HpackEncoder, HpackHeader
from komira_http_core.transport.io_stream import NEGOTIATED_HTTP_2
from komira_http_core.transport.scripted import ScriptedConnector, ScriptedStream

from komira_grpc import (
    BidiStreamCodec,
    CallOptions,
    ClientStreamEncoder,
    GrpcClient,
    Protocol,
    ProtocolConnectProto,
    ProtocolGrpcProto,
    ServerStreamDecoder,
    STREAM_OUTCOME_END_ERROR,
    STREAM_OUTCOME_END_OK,
    STREAM_OUTCOME_MESSAGE,
    STREAM_OUTCOME_PENDING,
    GRPC_STATUS_FAILED_PRECONDITION,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_PERMISSION_DENIED,
    GRPC_STATUS_UNIMPLEMENTED,
    encode_stream_message,
    encode_unary_request,
    parse_grpc_status_code,
)
from komira_connect.envelope import ENVELOPE_FLAG_END_STREAM, write_envelope


comptime RT = PerCoreAsyncRuntime[NoopSink]

comptime _PATH: String = "/test.EchoService/Call"

comptime _GRPC_NOT_FOUND: Int = 5
comptime _GRPC_PERMISSION_DENIED: Int = 7
comptime _GRPC_FAILED_PRECONDITION: Int = 9
comptime _GRPC_UNIMPLEMENTED: Int = 12


# =============================================================================
# §0 — fixtures
# =============================================================================


def _b(s: String) -> List[UInt8]:
    var out = List[UInt8]()
    var bs = s.as_bytes()
    var i = 0
    while i < len(bs):
        out.append(bs[i])
        i = i + 1
    return out^


def _text(bytes: List[UInt8]) -> String:
    var s = String("")
    for i in range(len(bytes)):
        s += chr(Int(bytes[i]))
    return s^


def _make_reactor() raises -> Reactor[NoopSink]:
    comptime if CompilationTarget.is_linux():
        return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_EPOLL)
    return Reactor[NoopSink](NoopSink(_placeholder=UInt8(0)), BACKEND_KQUEUE)


# ---- rig 1: HTTP/1.1, for claims about the BODY ------------------------------


def _http_200(content_type: String, body: List[UInt8]) -> List[UInt8]:
    """A canned HTTP/1.1 200 whose body is `body`. Content-Length is exact so
    the RecvRingBody drains one Data frame and then End."""
    var head = _b(
        String("HTTP/1.1 200 OK\r\nContent-Type: ")
        + content_type
        + "\r\nContent-Length: "
        + String(len(body))
        + "\r\n\r\n"
    )
    var out = List[UInt8]()
    for i in range(len(head)):
        out.append(head[i])
    for i in range(len(body)):
        out.append(body[i])
    return out^


def _h1_client(var wire: List[UInt8]) raises -> GrpcClient[ScriptedConnector]:
    var stream = ScriptedStream.from_read_script(wire^)
    var connector = ScriptedConnector.with_stream(stream^)
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var base = Url.parse(String("http://127.0.0.1:8080/"))
    return GrpcClient[ScriptedConnector](http^, base^)


# ---- rig 2: HTTP/2, for claims about HEADERS and TRAILERS --------------------


def _h2_client(var script: List[UInt8]) raises -> GrpcClient[ScriptedConnector]:
    """One scripted h2 connection, https authority, serving its script ONE BYTE
    PER READ.

    ⚠ BOTH PROPERTIES ARE LOAD-BEARING (as in `test_unary_status_retry`):
      * without the ALPN report, `send_grpc_pooled` drops the dial and falls
        back to HTTP/1.1, which never produces a gRPC status at all;
      * without `set_max_read_per_call(1)`, a greedy read pulls frames for
        streams the connection has not created yet and the client drops them.
    """
    var s = ScriptedStream.from_read_script(script^)
    s.set_negotiated_protocol(NEGOTIATED_HTTP_2)
    s.set_max_read_per_call(1)
    var connector = ScriptedConnector.with_stream_tls(s^)
    var http = HttpClient[ScriptedConnector].with_defaults(connector^)
    var base = Url.parse(String("https://run.googleapis.com:443/"))
    return GrpcClient[ScriptedConnector](http^, base^)


def _h2_prologue() raises -> List[UInt8]:
    var out = List[UInt8]()
    var entries = List[SettingsEntry]()
    encode_settings_frame(entries^, out)
    return out^


def _append_trailers_only(
    sid: Int,
    code: Int,
    with_content_type: Bool,
    mut hpack: HpackEncoder,
    mut out: List[UInt8],
) raises:
    """THE TRAILERS-ONLY RESPONSE: one HEADERS frame with END_STREAM, carrying
    `:status: 200` + `grpc-status: <code>`, and NO DATA frame — exactly what a
    gRPC server sends when it fails before producing a message."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    if with_content_type:
        hdrs.append(
            HpackHeader(String("content-type"), String("application/grpc"))
        )
    hdrs.append(HpackHeader(String("grpc-status"), String(code)))
    hdrs.append(HpackHeader(String("grpc-message"), String("trailers-only")))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        UInt32(sid), block^, end_stream=True, end_headers=True, out=out
    )


def _append_status_with_body(
    sid: Int,
    code: Int,
    var body: List[UInt8],
    mut hpack: HpackEncoder,
    mut out: List[UInt8],
) raises:
    """The status-carrying shape that DOES reach the status layer in this rig:
    HEADERS without END_STREAM, then a NON-EMPTY DATA frame with END_STREAM.

    This is the shape `test_unary_status_retry.mojo` uses; using it
    here isolates "does the entry point raise the header status" from "can the
    transport deliver a bodyless response at all", which are two different
    claims and two different findings."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(
        HpackHeader(String("content-type"), String("application/grpc"))
    )
    hdrs.append(HpackHeader(String("grpc-status"), String(code)))
    hdrs.append(HpackHeader(String("grpc-message"), String("scripted")))
    hdrs.append(HpackHeader(String("content-length"), String(len(body))))
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        UInt32(sid), block^, end_stream=False, end_headers=True, out=out
    )
    encode_data_frame(UInt32(sid), body^, end_stream=True, out=out)


def _append_body_then_real_trailers(
    sid: Int,
    code: Int,
    var body: List[UInt8],
    mut hpack: HpackEncoder,
    mut out: List[UInt8],
) raises:
    """The FULL classic-gRPC response: initial HEADERS, a DATA frame, then a
    SECOND HEADERS frame (the real HTTP/2 TRAILERS) carrying the terminal
    `grpc-status` with END_STREAM."""
    var hdrs = List[HpackHeader]()
    hdrs.append(HpackHeader(String(":status"), String("200")))
    hdrs.append(
        HpackHeader(String("content-type"), String("application/grpc"))
    )
    var block = hpack.encode_block(hdrs^)
    encode_headers_frame(
        UInt32(sid), block^, end_stream=False, end_headers=True, out=out
    )
    encode_data_frame(UInt32(sid), body^, end_stream=False, out=out)
    var trailers = List[HpackHeader]()
    trailers.append(HpackHeader(String("grpc-status"), String(code)))
    trailers.append(
        HpackHeader(String("grpc-message"), String("terminal-in-trailers"))
    )
    var tblock = hpack.encode_block(trailers^)
    encode_headers_frame(
        UInt32(sid), tblock^, end_stream=True, end_headers=True, out=out
    )


def _connect_end_stream(var json: String) -> List[UInt8]:
    """A Connect end-of-stream envelope (END_STREAM flag, JSON payload)."""
    var out = List[UInt8]()
    write_envelope(out, ENVELOPE_FLAG_END_STREAM, Span(_b(json)))
    return out^


def _drain(var decoder: ServerStreamDecoder[ProtocolGrpcProto]) raises -> (
    List[String]
):
    var got = List[String]()
    var iters = 0
    while iters < 200:
        iters = iters + 1
        var o = decoder.try_next_message()
        if o.kind == STREAM_OUTCOME_MESSAGE:
            got.append(_text(o.message_bytes))
            continue
        break
    return got^


# =============================================================================
# §1 — TRAILERS-ONLY at `unary_call`
# =============================================================================


def test_unary_trailers_only_surfaces_the_status() raises:
    """★ THE SHAPE `parse_grpc_status_initial_headers` EXISTS FOR.

    ONE HEADERS frame, END_STREAM set, `:status: 200` +
    `content-type: application/grpc` + `grpc-status: 12`. No DATA frame. This is
    how a gRPC server reports an unimplemented method, a permission failure, or
    a not-found — gRPC's own interop suite calls it `unimplemented_method`.

    The caller must receive UNIMPLEMENTED. It must NOT receive a transport
    error, and it must not receive "empty body — expected at least one
    envelope": there is no body BY DESIGN, and treating its absence as a
    malformed body is the same category error as treating an unterminated
    chunked body as a decode problem.
    """
    var script = _h2_prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    _append_trailers_only(1, _GRPC_UNIMPLEMENTED, True, hpack, script)

    var client = _h2_client(script^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("req"))

    var raised = False
    var message = String("")
    var n_bytes = -1
    try:
        var r = client.unary_call[RT, ProtocolGrpcProto](
            String(_PATH), Span(msg), opts, Int(0), reactor, token
        )
        n_bytes = len(r.message_bytes)
    except e:
        raised = True
        message = String(e)

    if not raised:
        raise Error(
            String(
                "a trailers-only UNIMPLEMENTED response returned SUCCESS with "
            )
            + String(n_bytes)
            + " message bytes — the caller never learns the RPC failed"
        )
    if parse_grpc_status_code(message) != _GRPC_UNIMPLEMENTED:
        raise Error(
            "a trailers-only response (one HEADERS frame with END_STREAM,"
            " `grpc-status: 12`, no DATA) did not surface as [grpc:12]. This is"
            " the response shape EVERY permission failure, not-found and"
            " unimplemented method uses, and"
            " `parse_grpc_status_initial_headers` exists precisely to read it."
            " got: "
            + message
        )


def test_unary_trailers_only_without_content_type_is_not_an_eof() raises:
    """The same trailers-only response with NO `content-type` header.

    A gRPC client must answer this with a status naming the problem
    (grpc-go: `Internal`, "malformed header: missing HTTP content-type"), never
    with a transport error. Split from the case above so the two failure modes
    — "the status is not read" and "the content-type is not checked" — are
    reported separately.
    """
    var script = _h2_prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    _append_trailers_only(1, _GRPC_PERMISSION_DENIED, False, hpack, script)

    var client = _h2_client(script^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("req"))

    var raised = False
    var message = String("")
    try:
        var r = client.unary_call[RT, ProtocolGrpcProto](
            String(_PATH), Span(msg), opts, Int(0), reactor, token
        )
        _ = len(r.message_bytes)
    except e:
        raised = True
        message = String(e)

    assert_true(raised, "a non-OK response must not return success")
    if String("EOF_MID_RESPONSE") in message:
        raise Error(
            "a trailers-only response with no content-type came back as"
            " `EOF_MID_RESPONSE` — a TRANSPORT error for a response the peer"
            " delivered completely and correctly at the h2 layer."
            " got: "
            + message
        )
    if parse_grpc_status_code(message) < 0:
        raise Error(
            "a trailers-only response with no content-type raised an error"
            " carrying no `[grpc:N]` status at all. got: "
            + message
        )


def test_unary_terminal_status_in_a_real_trailers_frame() raises:
    """The FULL classic-gRPC response: initial HEADERS, a DATA frame, then a
    SECOND HEADERS frame carrying the terminal `grpc-status` — a real HTTP/2
    TRAILERS block, which is where classic gRPC puts its status on EVERY
    successful and unsuccessful call.

    ⚠ The client's body drain discards trailer BodyFrames outright, so the
    only way a terminal status can be honoured is the client reading the
    response's TRAILER section (`_grpc_status_from_sections`). This case is
    what establishes that it does — without it, the discard is the line at
    which a real terminal status would be dropped on the floor and nothing
    would say so.
    """
    var script = _h2_prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    var body = encode_unary_request[ProtocolGrpcProto](Span(_b(String("resp"))))
    _append_body_then_real_trailers(
        1, _GRPC_FAILED_PRECONDITION, body^, hpack, script
    )

    var client = _h2_client(script^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("req"))

    var raised = False
    var message = String("")
    var returned = String("")
    try:
        var r = client.unary_call[RT, ProtocolGrpcProto](
            String(_PATH), Span(msg), opts, Int(0), reactor, token
        )
        returned = _text(r.message_bytes)
    except e:
        raised = True
        message = String(e)

    if not raised:
        raise Error(
            String(
                "a terminal `grpc-status: 9` delivered in a REAL HTTP/2"
                " TRAILERS frame was DROPPED — the call returned '"
            )
            + returned
            + "' as a success. A classic-gRPC status lives in trailers; a"
            " client that ignores them reports every failure as a success"
        )
    assert_equal(
        parse_grpc_status_code(message),
        _GRPC_FAILED_PRECONDITION,
        String("the trailer status must reach the caller. got: ") + message,
    )


# =============================================================================
# §2 — `server_stream`: the trailers-only error that would otherwise read as an
#      empty result
# =============================================================================


def test_server_stream_raises_the_header_status_rather_than_yielding_nothing(
) raises:
    """`server_stream`'s terminal-status check exists so a `ReadObject` on a
    missing object surfaces NOT_FOUND instead of a silent empty buffer.

    Status on the response HEADERS, body present (the shape this rig can
    deliver — see `_append_status_with_body`). The call must RAISE `[grpc:5]`,
    not return a decoder the caller then finds empty.
    """
    var script = _h2_prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    var body = encode_unary_request[ProtocolGrpcProto](Span(_b(String("x"))))
    _append_status_with_body(1, _GRPC_NOT_FOUND, body^, hpack, script)

    var client = _h2_client(script^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var req = _b(String("read"))

    var raised = False
    var message = String("")
    var n_msgs = -1
    try:
        var decoder = client.server_stream[RT, ProtocolGrpcProto](
            String(_PATH), Span(req), opts, Int(0), reactor, token
        )
        n_msgs = len(_drain(decoder^))
    except e:
        raised = True
        message = String(e)

    if not raised:
        raise Error(
            String(
                "server_stream returned a decoder for a NOT_FOUND response"
                " instead of raising — the caller sees "
            )
            + String(n_msgs)
            + " message(s) and a silent truncated read, which is the defect"
            " `server_stream`'s terminal-status check exists to prevent"
        )
    assert_equal(
        parse_grpc_status_code(message),
        _GRPC_NOT_FOUND,
        String("server_stream must raise the typed status. got: ") + message,
    )


def test_server_stream_trailers_only_error_surfaces_the_status() raises:
    """The REAL shape of that same failure: trailers-only, EMPTY body.

    A `ReadObject` on a missing object produces no DATA frame at all. If this
    cannot be delivered, `server_stream`'s terminal-status check never fires for
    the case it was written for.
    """
    var script = _h2_prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    _append_trailers_only(1, _GRPC_NOT_FOUND, True, hpack, script)

    var client = _h2_client(script^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var req = _b(String("read"))

    var raised = False
    var message = String("")
    try:
        var decoder = client.server_stream[RT, ProtocolGrpcProto](
            String(_PATH), Span(req), opts, Int(0), reactor, token
        )
        _ = len(_drain(decoder^))
    except e:
        raised = True
        message = String(e)

    assert_true(raised, "a NOT_FOUND server-stream must not return cleanly")
    if parse_grpc_status_code(message) != _GRPC_NOT_FOUND:
        raise Error(
            "a trailers-only NOT_FOUND (the shape a real missing-object read"
            " produces: no DATA frame at all) did not surface as [grpc:5]. got: "
            + message
        )


# =============================================================================
# §3 — `client_stream`
# =============================================================================


def _client_stream_over[
    P: Protocol
](
    content_type: String,
    var body: List[UInt8],
) raises -> Tuple[Bool, String, String]:
    """Drive `client_stream[P]` against an HTTP/1.1 response whose body is
    `body`. Returns (raised, returned_payload, error_message).

    ⚠ PARAMETERIC ON `P` BECAUSE THE WIRE SHAPE DECIDES THE PROTOCOL, NOT THE
    OTHER WAY AROUND. `_first_stream_message`'s four arms are protocol-generic
    (`client.mojo`: one `while` loop, no `comptime if`), so each arm can be
    driven over whichever protocol OWNS the wire shape that manufactures it —
    and a case that feeds a Connect end-of-stream envelope MUST say
    `ProtocolConnectProto`, because classic gRPC has no such envelope. See
    `test_client_stream_end_error_is_reraised_with_its_status`.
    """
    var client = _h1_client(_http_200(content_type, body))
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var encoder = ClientStreamEncoder[P].new()
    encoder.encode_message(Span(_b(String("chunk-1"))))
    encoder.encode_message(Span(_b(String("chunk-2"))))
    encoder.mark_close()

    var returned = String("")
    var message = String("")
    var raised = False
    try:
        var r = client.client_stream[RT, P](
            String(_PATH), encoder^, opts, Int(0), reactor, token
        )
        returned = _text(r.message_bytes)
    except e:
        raised = True
        message = String(e)
    return (raised, returned, message)


def _client_stream_over_body(
    var body: List[UInt8],
) raises -> Tuple[Bool, String, String]:
    """`_client_stream_over` at classic gRPC — the default for every case whose
    body is a classic-gRPC wire."""
    return _client_stream_over[ProtocolGrpcProto](
        String("application/grpc"), body^
    )


def test_client_stream_returns_the_single_terminal_message() raises:
    """The happy path — N requests, ONE response message."""
    var body = List[UInt8]()
    encode_stream_message[ProtocolGrpcProto](body, Span(_b(String("ACCEPTED"))))
    var out = _client_stream_over_body(body^)
    if out[0]:
        raise Error(
            String("client_stream raised on a well-formed response: ") + out[2]
        )
    assert_equal(
        out[1],
        String("ACCEPTED"),
        "the single terminal message must come back verbatim",
    )


def test_client_stream_empty_response_raises_a_typed_status() raises:
    """`_first_stream_message`'s PENDING arm: the response body is empty, so no
    terminal message ever arrives. Must raise a `[grpc:N]`-anchored error."""
    var out = _client_stream_over_body(List[UInt8]())
    assert_true(
        out[0], "an empty client-stream response must not return success"
    )
    if parse_grpc_status_code(out[2]) < 0:
        raise Error(
            String(
                "client_stream over an empty body raised an error with no"
                " `[grpc:N]` anchor. got: "
            )
            + out[2]
        )


def test_client_stream_end_ok_before_a_message_raises() raises:
    """`_first_stream_message`'s END_OK arm: the stream terminates cleanly
    BEFORE producing the one response message a client-streaming RPC owes."""
    var out = _client_stream_over_body(_connect_end_stream(String("{}")))
    assert_true(
        out[0],
        "a stream that ended before the response message must not return"
        " success",
    )
    if parse_grpc_status_code(out[2]) < 0:
        raise Error(
            String(
                "client_stream over a clean end-of-stream with no message"
                " raised an error with no `[grpc:N]` anchor. got: "
            )
            + out[2]
        )


def test_client_stream_end_error_is_reraised_with_its_status() raises:
    """`_first_stream_message`'s END_ERROR arm: the decoded terminal status must
    be re-raised VERBATIM as `[grpc:N]`, not flattened into a generic error —
    the caller's classifier keys on the code.

    ⚠ WHY THIS RUNS ON `ProtocolConnectProto`. Driving `ProtocolGrpcProto` over a
    body built by `_connect_end_stream` — a CONNECT end-of-stream envelope,
    flags byte 0x80 — would assert a shape the wire format does not have: per
    PROTOCOL-HTTP2 ("Responses"), classic gRPC over HTTP/2
    terminates a stream with real HTTP/2 TRAILERS and has NO end-of-stream
    envelope flag, and its Compressed-Flag is "a 1 byte unsigned integer" whose
    only defined values are 0 and 1 — so 0x80 on a classic-gRPC stream is a
    CORRUPT BYTE, which grpc-go fails with `codes.Internal, "grpc: received
    unexpected payload format %d"`.

    Such a fixture would encode the very defect
    `test_flag_0x80_on_classic_grpc_truncates_the_stream_silently` reds:
    reading 0x80 as a terminator on classic gRPC, which truncates a response
    and reports it complete. The two could not both be satisfied.

    The CLAIM — that a decoded terminal status survives `_first_stream_message`'s
    re-raise with its code intact — is tested at FULL strength
    (the code is still DECODED OUT OF THE TERMINAL PAYLOAD, not synthesised from
    a flag byte). It simply runs on the protocol that owns this wire:
    `ProtocolConnectProto`, where the end-of-stream envelope is real and
    `{"error":{"code":"not_found"}}` is its defined status carrier.
    `_first_stream_message` is protocol-generic, so the arm under test is
    byte-for-byte the same one.
    """
    var out = _client_stream_over[ProtocolConnectProto](
        String("application/connect+proto"),
        _connect_end_stream(
            String('{"error":{"code":"not_found","message":"no such row"}}')
        ),
    )
    assert_true(out[0], "a terminal END_ERROR must raise")
    assert_equal(
        parse_grpc_status_code(out[2]),
        _GRPC_NOT_FOUND,
        String("the decoded terminal status must survive the re-raise. got: ")
        + out[2],
    )


def test_client_stream_trailers_only_error_surfaces_the_real_status() raises:
    """`client_stream`'s terminal-status check exists because a `WriteObject`
    with a stale
    `ifGenerationMatch` returns FAILED_PRECONDITION with an EMPTY body. Without
    it `_first_stream_message` sees the empty body and raises grpc_code 2
    (classified TRANSPORT) instead of 9 (PRECONDITION / 412).

    Status on the HEADERS, body present — the shape this rig can deliver.
    """
    var script = _h2_prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    var body = encode_unary_request[ProtocolGrpcProto](Span(_b(String("x"))))
    _append_status_with_body(1, _GRPC_FAILED_PRECONDITION, body^, hpack, script)

    var client = _h2_client(script^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var encoder = ClientStreamEncoder[ProtocolGrpcProto].new()
    encoder.encode_message(Span(_b(String("bytes"))))
    encoder.mark_close()

    var raised = False
    var message = String("")
    try:
        var r = client.client_stream[RT, ProtocolGrpcProto](
            String(_PATH), encoder^, opts, Int(0), reactor, token
        )
        _ = len(r.message_bytes)
    except e:
        raised = True
        message = String(e)

    assert_true(raised, "a FAILED_PRECONDITION write must raise")
    assert_equal(
        parse_grpc_status_code(message),
        _GRPC_FAILED_PRECONDITION,
        String(
            "the REAL status must reach the caller — grpc_code 2 here means"
            " the caller classifies a precondition failure as a transport"
            " fault and retries it. got: "
        )
        + message,
    )


# =============================================================================
# §4 — `bidi_stream`
# =============================================================================


def test_bidi_stream_round_trips_both_directions() raises:
    """The happy path — two requests buffered, two responses decoded."""
    var body = List[UInt8]()
    encode_stream_message[ProtocolGrpcProto](body, Span(_b(String("R1"))))
    encode_stream_message[ProtocolGrpcProto](body, Span(_b(String("R2"))))

    var client = _h1_client(_http_200(String("application/grpc"), body))
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var codec = BidiStreamCodec[ProtocolGrpcProto].new()
    codec.encoder.encode_message(Span(_b(String("Q1"))))
    codec.encoder.encode_message(Span(_b(String("Q2"))))
    codec.encoder.mark_close()

    var decoder = client.bidi_stream[RT, ProtocolGrpcProto](
        String(_PATH), codec^, opts, Int(0), reactor, token
    )
    var got = _drain(decoder^)
    assert_equal(len(got), 2, "two response messages")
    assert_equal(got[0], String("R1"), "first response")
    assert_equal(got[1], String("R2"), "second response")


def test_bidi_stream_raises_a_non_ok_terminal_status() raises:
    """★ `bidi_stream` NEEDS THE TERMINAL-STATUS CHECK TOO.

    `unary_call` (§3a), `server_stream` (§4 3a) and `client_stream` (§5 2a) each
    read the terminal status off the response and raise a non-OK code. A
    `bidi_stream` that only drained the body and handed back a decoder,
    whatever the status said, would return a decoder the caller finds empty
    for a bidi RPC the server REJECTED — the identical silent-empty-result
    defect that the comments on the other three entry points describe at
    length as the reason those checks exist.
    """
    var script = _h2_prologue()
    var hpack = HpackEncoder(max_table_size=4096)
    var body = encode_unary_request[ProtocolGrpcProto](Span(_b(String("x"))))
    _append_status_with_body(1, _GRPC_PERMISSION_DENIED, body^, hpack, script)

    var client = _h2_client(script^)
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var codec = BidiStreamCodec[ProtocolGrpcProto].new()
    codec.encoder.encode_message(Span(_b(String("Q1"))))
    codec.encoder.mark_close()

    var raised = False
    var message = String("")
    var n_msgs = -1
    try:
        var decoder = client.bidi_stream[RT, ProtocolGrpcProto](
            String(_PATH), codec^, opts, Int(0), reactor, token
        )
        n_msgs = len(_drain(decoder^))
    except e:
        raised = True
        message = String(e)

    if not raised:
        raise Error(
            String(
                "bidi_stream returned a decoder for a PERMISSION_DENIED"
                " response instead of raising — the caller gets "
            )
            + String(n_msgs)
            + " message(s) and no indication the RPC was rejected. The other"
            " three entry points each check"
            " `parse_grpc_status_initial_headers`; this one does not"
        )
    assert_equal(
        parse_grpc_status_code(message),
        _GRPC_PERMISSION_DENIED,
        String("bidi_stream must raise the typed status. got: ") + message,
    )


# =============================================================================
# §5 — the response content-type is validated
# =============================================================================


def test_non_grpc_content_type_is_reported_as_such() raises:
    """★ A gRPC-UNAWARE INTERMEDIARY'S HTML PAGE IS FED TO THE ENVELOPE DECODER.

    Without a response content-type check, a captive portal, a proxy error
    page or a misrouted request answering `:status: 200` with `text/html` has
    its HTML body handed to `grpc_decode_unary`, which reads the first byte as
    the Compressed-Flag and the next four as a big-endian length — here
    `"html"` = 0x68746D6C = 1752392044 — and raises a bare "truncated payload"
    naming a length that came from the HTML.

    A conformant client checks the content-type FIRST: grpc-go answers a
    non-`application/grpc` content-type on a 200 with
    `Internal, "malformed header: missing HTTP content-type"` / the actual type,
    so the operator is told what actually came back rather than being sent to
    debug a framing bug that does not exist.
    """
    var html = _b(
        String(
            "<html><head><title>502 Bad Gateway</title></head><body>"
            "<h1>502 Bad Gateway</h1></body></html>"
        )
    )
    var client = _h1_client(_http_200(String("text/html"), html))
    var reactor = _make_reactor()
    var token = CancellationToken.never()
    var opts = CallOptions()
    var msg = _b(String("req"))

    var raised = False
    var message = String("")
    try:
        var r = client.unary_call[RT, ProtocolGrpcProto](
            String(_PATH), Span(msg), opts, Int(0), reactor, token
        )
        _ = len(r.message_bytes)
    except e:
        raised = True
        message = String(e)

    assert_true(raised, "an HTML body is not a gRPC response")
    if String("text/html") not in message:
        raise Error(
            "a `text/html` 200 was decoded as a gRPC envelope and the error"
            " never mentions the content-type — the operator is handed a"
            " framing diagnostic for what is actually a routing failure. got: "
            + message
        )


# =============================================================================
# §6 — driver
# =============================================================================


def main() raises:
    print(
        "test_grpc_client_trailers_only_and_streams: GrpcClient's four entry"
        " points"
    )
    var failures = List[String]()

    try:
        test_unary_trailers_only_surfaces_the_status()
        print("  PASS  unary trailers-only surfaces the status")
    except e:
        failures.append(
            String("unary_trailers_only_surfaces_the_status: ") + String(e)
        )
        print("  FAIL  unary trailers-only surfaces the status")

    try:
        test_unary_trailers_only_without_content_type_is_not_an_eof()
        print("  PASS  unary trailers-only without content-type is not an EOF")
    except e:
        failures.append(
            String(
                "unary_trailers_only_without_content_type_is_not_an_eof: "
            )
            + String(e)
        )
        print("  FAIL  unary trailers-only without content-type is not an EOF")

    try:
        test_unary_terminal_status_in_a_real_trailers_frame()
        print("  PASS  unary terminal status in a real TRAILERS frame")
    except e:
        failures.append(
            String("unary_terminal_status_in_a_real_trailers_frame: ")
            + String(e)
        )
        print("  FAIL  unary terminal status in a real TRAILERS frame")

    try:
        test_server_stream_raises_the_header_status_rather_than_yielding_nothing()
        print("  PASS  server_stream raises the header status")
    except e:
        failures.append(
            String(
                "server_stream_raises_the_header_status_rather_than_yielding_nothing: "
            )
            + String(e)
        )
        print("  FAIL  server_stream raises the header status")

    try:
        test_server_stream_trailers_only_error_surfaces_the_status()
        print("  PASS  server_stream trailers-only error surfaces the status")
    except e:
        failures.append(
            String("server_stream_trailers_only_error_surfaces_the_status: ")
            + String(e)
        )
        print("  FAIL  server_stream trailers-only error surfaces the status")

    try:
        test_client_stream_returns_the_single_terminal_message()
        print("  PASS  client_stream returns the single terminal message")
    except e:
        failures.append(
            String("client_stream_returns_the_single_terminal_message: ")
            + String(e)
        )
        print("  FAIL  client_stream returns the single terminal message")

    try:
        test_client_stream_empty_response_raises_a_typed_status()
        print("  PASS  client_stream empty response raises a typed status")
    except e:
        failures.append(
            String("client_stream_empty_response_raises_a_typed_status: ")
            + String(e)
        )
        print("  FAIL  client_stream empty response raises a typed status")

    try:
        test_client_stream_end_ok_before_a_message_raises()
        print("  PASS  client_stream END_OK before a message raises")
    except e:
        failures.append(
            String("client_stream_end_ok_before_a_message_raises: ") + String(e)
        )
        print("  FAIL  client_stream END_OK before a message raises")

    try:
        test_client_stream_end_error_is_reraised_with_its_status()
        print("  PASS  client_stream END_ERROR is re-raised with its status")
    except e:
        failures.append(
            String("client_stream_end_error_is_reraised_with_its_status: ")
            + String(e)
        )
        print("  FAIL  client_stream END_ERROR is re-raised with its status")

    try:
        test_client_stream_trailers_only_error_surfaces_the_real_status()
        print("  PASS  client_stream header status surfaces as the real code")
    except e:
        failures.append(
            String(
                "client_stream_trailers_only_error_surfaces_the_real_status: "
            )
            + String(e)
        )
        print("  FAIL  client_stream header status surfaces as the real code")

    try:
        test_bidi_stream_round_trips_both_directions()
        print("  PASS  bidi_stream round-trips both directions")
    except e:
        failures.append(
            String("bidi_stream_round_trips_both_directions: ") + String(e)
        )
        print("  FAIL  bidi_stream round-trips both directions")

    try:
        test_bidi_stream_raises_a_non_ok_terminal_status()
        print("  PASS  bidi_stream raises a non-OK terminal status")
    except e:
        failures.append(
            String("bidi_stream_raises_a_non_ok_terminal_status: ") + String(e)
        )
        print("  FAIL  bidi_stream raises a non-OK terminal status")

    try:
        test_non_grpc_content_type_is_reported_as_such()
        print("  PASS  a non-gRPC content-type is reported as such")
    except e:
        failures.append(
            String("non_grpc_content_type_is_reported_as_such: ") + String(e)
        )
        print("  FAIL  a non-gRPC content-type is reported as such")

    if len(failures) > 0:
        var report = String("test_grpc_client_trailers_only_and_streams: ")
        report += String(len(failures)) + " case(s) FAILED\n"
        for i in range(len(failures)):
            report += String("\n---- ") + failures[i] + "\n"
        raise Error(report)
    print("test_grpc_client_trailers_only_and_streams: ALL PASS")
