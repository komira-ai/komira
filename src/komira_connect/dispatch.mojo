# =============================================================================
# dispatch.mojo — Connect-RPC method dispatch
# =============================================================================
#
# The runtime dispatcher: given (codec_id, method_path, request_body), invokes
# the registered handler and returns the response body bytes.
#
# The handler is registered by `ConnectService` (service.mojo) and called
# back via a Mojo `fn` value (`ConnectHandlerFn`) — this gives a complete
# dispatch pipeline that needs no generated per-service code; a registration
# layer built on generated message types could use the same pipeline.
#
# Encapsulation: NO UnsafePointer in any public sig. The fn-value `ConnectHandlerFn`
# IS a code pointer (a non-owning value), so it's safe — a code pointer
# with no heap, value-semantically POD, like an FFI function-pointer field.
# =============================================================================

from .codec_grpc import (
    GRPC_CONTENT_TYPE,
    GRPC_CONTENT_TYPE_PROTO,
    GrpcTrailers,
    grpc_decode_unary,
    grpc_encode_unary,
    grpc_make_ok_trailers,
    grpc_make_trailers,
)
from .codec_grpc_web import (
    GRPC_WEB_CONTENT_TYPE,
    GRPC_WEB_CONTENT_TYPE_PROTO,
    grpc_web_decode_request,
    grpc_web_encode_unary,
)
from .codec_connect_json import (
    CONNECT_JSON_CONTENT_TYPE_UNARY,
    CONNECT_JSON_CONTENT_TYPE_STREAM,
    CONNECT_PROTO_CONTENT_TYPE_UNARY,
    CONNECT_PROTO_CONTENT_TYPE_STREAM,
    connect_json_decode_unary,
    connect_json_encode_unary,
    build_connect_error_json,
)
from .status import (
    GRPC_STATUS_OK,
    GRPC_STATUS_UNKNOWN,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_UNIMPLEMENTED,
    grpc_status_to_http_status,
    grpc_status_to_connect_name,
    parse_connect_error,
    format_connect_error,
)


# =============================================================================
# §1 — Codec ID constants — passed to handler functions to indicate wire.
# =============================================================================

comptime CODEC_ID_UNKNOWN: UInt8 = 0
comptime CODEC_ID_GRPC: UInt8 = 1
comptime CODEC_ID_GRPC_WEB: UInt8 = 2
comptime CODEC_ID_CONNECT_JSON: UInt8 = 3


def codec_id_for_content_type(ct: String) -> UInt8:
    """Map a Content-Type header value to the codec_id.

    Returns CODEC_ID_UNKNOWN for unrecognized types — the dispatcher
    surfaces this as a 415 / GRPC_STATUS_UNIMPLEMENTED.
    """
    # Strip parameters (e.g., `application/grpc+proto; charset=utf-8`)
    var base = _strip_content_type_params(ct)
    if base == GRPC_CONTENT_TYPE or base == GRPC_CONTENT_TYPE_PROTO:
        return CODEC_ID_GRPC
    if base == GRPC_WEB_CONTENT_TYPE or base == GRPC_WEB_CONTENT_TYPE_PROTO:
        return CODEC_ID_GRPC_WEB
    if base == CONNECT_JSON_CONTENT_TYPE_UNARY or base == CONNECT_JSON_CONTENT_TYPE_STREAM:
        return CODEC_ID_CONNECT_JSON
    # Connect-proto unary (`application/proto`) + streaming
    # (`application/connect+proto`) share the Connect codec's bare-body
    # framing + JSON error-envelope shape — only the success payload bytes
    # differ (protobuf-binary vs proto3-JSON), and those are opaque to the
    # dispatcher (copied through unchanged). Route onto CODEC_ID_CONNECT_JSON.
    # See CONNECT_PROTO_CONTENT_TYPE_UNARY doc in codec_connect_json.mojo.
    if base == CONNECT_PROTO_CONTENT_TYPE_UNARY or base == CONNECT_PROTO_CONTENT_TYPE_STREAM:
        return CODEC_ID_CONNECT_JSON
    return CODEC_ID_UNKNOWN


def _strip_content_type_params(ct: String) -> String:
    """Return the base content-type (before any `; param=value` suffix)."""
    var n = ct.byte_length()
    for i in range(n):
        var b = ord(ct[byte=i])
        if b == ord(";"):
            # Build substring [0..i)
            var out = List[UInt8](capacity=i)
            for j in range(i):
                out.append(UInt8(ord(ct[byte=j])))
            return String(unsafe_from_utf8=Span(out))
    return ct


# =============================================================================
# §2 — ConnectHandlerFn — the handler function signature.
# =============================================================================
#
# A handler:
#   - takes the decoded request body bytes (the typed message bytes for
#     gRPC/gRPC-Web; the JSON bytes for Connect-JSON) as an owned
#     List[UInt8] (the dispatcher copies the wire view into a fresh List
#     before invoking the handler — one extra copy at the boundary buys
#     a concrete fn-type that doesn't have parametric origin in its
#     signature, which Mojo does not allow on fn-typed fields);
#   - returns response body bytes (same shape — typed-message-bytes for
#     gRPC/gRPC-Web, JSON bytes for Connect-JSON);
#   - the codec_id is passed in so the handler can dispatch to the
#     correct decoder/encoder pair (typically generated code that
#     understands all 3 codecs);
#   - raises an Error if the request is invalid; the dispatcher
#     translates the Error into a status code via format_connect_error /
#     parse_connect_error.
#
# This shape is intentionally simple — it's the canonical surface that
# generated code targets. Streaming, deadlines and cancellation layer
# above this base.
# =============================================================================

comptime ConnectHandlerFn = def (codec_id: UInt8, req_body: List[UInt8]) raises thin -> List[UInt8]


# =============================================================================
# §3 — DispatchResult — the dispatcher's outcome.
# =============================================================================


@fieldwise_init
struct DispatchResult(Movable, Deinitable):
    """Outcome of a dispatch call.

    Fields:
        body: The response body bytes (already wire-encoded per the codec
              — envelope-framed for gRPC/gRPC-Web; raw JSON for Connect-JSON).
        http_status: The HTTP status code to set on the response
                     (200 for gRPC successes, since status goes in trailers;
                      the mapped HTTP status from grpc_status_to_http_status
                      for Connect-JSON errors).
        grpc_status: The gRPC canonical code for the outcome (0 for success).
                     For gRPC + gRPC-Web, the caller emits this as a trailer.
        grpc_message: The grpc-message text for non-OK outcomes (empty for OK).
                      The caller emits this in trailers (gRPC) / body trailer
                      envelope (gRPC-Web) / JSON error body (Connect-JSON).
        codec_id: Echo of the resolved codec; informational for the caller.
    """

    var body: List[UInt8]
    var http_status: UInt16
    var grpc_status: UInt8
    var grpc_message: String
    var codec_id: UInt8

    def is_ok(imm self) -> Bool:
        return self.grpc_status == GRPC_STATUS_OK


# =============================================================================
# §4 — The dispatcher entry point.
# =============================================================================


def dispatch(
    handler: ConnectHandlerFn,
    codec_id: UInt8,
    request_body: Span[UInt8, _],
) -> DispatchResult:
    """Run a Connect-RPC method dispatch.

    Decodes the request body per `codec_id`, invokes `handler`, encodes
    the response back per `codec_id`. Catches any raised Error and maps
    it into the result struct (the caller emits the right wire trailers
    or error body).

    Args:
        handler: The handler fn to invoke. Reads the decoded message
                 body and returns response message body.
        codec_id: One of CODEC_ID_GRPC / GRPC_WEB / CONNECT_JSON.
        request_body: The raw HTTP request body bytes (still
                      envelope-framed for gRPC/gRPC-Web; raw JSON for
                      Connect-JSON unary).

    Returns:
        DispatchResult with body + http_status + grpc_status + grpc_message.
    """
    if codec_id == CODEC_ID_UNKNOWN:
        return _make_error_result(
            CODEC_ID_UNKNOWN,
            GRPC_STATUS_UNIMPLEMENTED,
            String("unsupported content-type"),
        )

    # Decode the request body to extract the inner message bytes, then
    # copy into an owned List[UInt8] before invoking the handler. The
    # copy is necessary because Mojo fn-typed fields cannot carry a
    # parametric origin in their signature — handler receives an owned
    # List[UInt8] instead of a Span view. One extra copy per dispatch
    # call; a dispatcher parameterized at comptime on the message types could
    # avoid it.
    var inner_request_bytes = List[UInt8]()
    try:
        if codec_id == CODEC_ID_GRPC:
            var view = grpc_decode_unary(request_body)
            for i in range(len(view)):
                inner_request_bytes.append(view[i])
        elif codec_id == CODEC_ID_GRPC_WEB:
            # gRPC-Web request: data envelope(s), no trailers
            var messages = grpc_web_decode_request(request_body)
            if len(messages) == 0:
                return _make_error_result(
                    codec_id,
                    GRPC_STATUS_UNKNOWN,
                    String("empty grpc-web request"),
                )
            # Unary: take the first message
            var view = messages[0]
            for i in range(len(view)):
                inner_request_bytes.append(view[i])
        else:
            # CONNECT_JSON — body IS the message bytes; copy as-is
            for i in range(len(request_body)):
                inner_request_bytes.append(request_body[i])
    except e:
        return _make_error_result(codec_id, GRPC_STATUS_UNKNOWN, String(e))

    # Invoke the handler.
    var inner_response: List[UInt8]
    try:
        inner_response = handler(codec_id, inner_request_bytes^)
    except e:
        # Try to parse the [connect:N] prefix; fall back to UNKNOWN.
        var parsed = parse_connect_error(String(e))
        return _make_error_result(codec_id, parsed[0], parsed[1])

    # Encode the response back to the wire.
    var response_body: List[UInt8]
    if codec_id == CODEC_ID_GRPC:
        response_body = grpc_encode_unary(Span(inner_response))
    elif codec_id == CODEC_ID_GRPC_WEB:
        response_body = grpc_web_encode_unary(Span(inner_response), grpc_make_ok_trailers())
    else:
        # CONNECT_JSON — body is the JSON bytes directly
        response_body = connect_json_encode_unary(Span(inner_response))

    return DispatchResult(
        response_body^,
        UInt16(200),
        GRPC_STATUS_OK,
        String(""),
        codec_id,
    )


def _make_error_result(
    codec_id: UInt8, grpc_status: UInt8, message: String
) -> DispatchResult:
    """Build a DispatchResult representing an error outcome.

    For Connect-JSON, body is the JSON error envelope. For gRPC and
    gRPC-Web, body is empty (the caller emits the error in trailers).
    """
    var body = List[UInt8]()
    var http_status = grpc_status_to_http_status(grpc_status)
    if codec_id == CODEC_ID_CONNECT_JSON:
        body = build_connect_error_json(grpc_status, message)
    elif codec_id == CODEC_ID_GRPC:
        # No body on error; trailers carry status
        http_status = UInt16(200)  # gRPC always 200 OK at HTTP layer
    elif codec_id == CODEC_ID_GRPC_WEB:
        # gRPC-Web puts trailers in body; for errors we ship an empty
        # data envelope + trailer envelope with the status. Caller can
        # use grpc_web_encode_unary(empty, trailers) — but for the
        # dispatcher's simple return, leave body empty and let the
        # caller compose. http_status stays 200 (gRPC-Web semantics).
        http_status = UInt16(200)
    return DispatchResult(body^, http_status, grpc_status, message, codec_id)
