# =============================================================================
# komira_grpc/wire.mojo — Wire-format marshalling layer (transport-free)
# =============================================================================
#
# The transport-free wire layer: this module IS what the client uses to
# encode the request body bytes / decode the response body bytes.
#
# The gRPC client adds ZERO transport. It marshals Mojo values into request
# body bytes + Mojo values out of response body bytes. The HTTP transport is
# plumbed through `HttpClient.send` (in client.mojo).
#
# This module is comptime-parametric on `P: Protocol`. Each function
# monomorphizes per protocol; classic gRPC `grpc+proto` uses
# `grpc_encode_unary` / `grpc_decode_unary` from komira_connect.codec_grpc;
# Connect unary uses bare body (no envelope). Streaming is handled in
# stream.mojo; this file owns ONLY unary.
#
# Encapsulation: NO UnsafePointer in any public sig. Inputs are
# `Span[UInt8, _]` (origin-inferred) and `List[UInt8]` (owned).
# =============================================================================

from komira_connect.envelope import (
    write_envelope,
    write_envelope_header,
    split_first_envelope,
    ENVELOPE_HEADER_SIZE,
    ENVELOPE_FLAG_COMPRESSED,
)
from komira_connect.codec_grpc import (
    grpc_encode_unary,
    grpc_decode_unary,
)
from komira_connect.codec_connect_json import parse_connect_error_json

from komira_grpc.protocol import Protocol
from komira_grpc.error import GrpcError, parse_grpc_status_trailers
from komira_connect.status import GRPC_STATUS_UNKNOWN


# =============================================================================
# §1 — encode_unary_request[P] — Mojo bytes → request body bytes.
# =============================================================================


def encode_unary_request[
    P: Protocol
](message_bytes: Span[UInt8, _]) -> List[UInt8]:
    """Encode a serialized message into the unary request body.

    Framing:
      - Classic gRPC (`grpc+proto`): 5-byte envelope wraps `message_bytes`.
      - Connect (`proto` or `json`): bare body — `message_bytes` IS the
        request body verbatim.

    The choice is comptime per `P.unary_is_enveloped()` — no runtime branch
    after monomorphization.

    Args:
        message_bytes: The already-serialized Mojo value
            (`Serializable.encode[E: WireEncoder]` output).

    Returns:
        The HTTP request body bytes ready to feed to `BytesBody.from_bytes`.
    """
    comptime if P.unary_is_enveloped():
        return grpc_encode_unary(message_bytes)
    # Connect-unary — bare body. Copy out so the caller owns it.
    var out = List[UInt8]()
    for i in range(len(message_bytes)):
        out.append(message_bytes[i])
    return out^


# =============================================================================
# §2 — decode_unary_response[P] — response body bytes → Mojo decode input.
# =============================================================================


def decode_unary_response[
    P: Protocol,
    origin: Origin[mut=False],
](
    body: Span[UInt8, origin],
    http_status: UInt16,
) raises -> Span[UInt8, origin]:
    """Decode the unary response body to a span over the inner message bytes.

    Framing and status:
      - Classic gRPC: HTTP must be 200 (raised as UNKNOWN otherwise); body
        is 5-byte-enveloped → strip envelope and return the payload span.
        Status comes from TRAILERS, not body — that path is handled
        separately by `decode_unary_response_status`.
      - Connect unary: HTTP 200 means body is bare-encoded message bytes;
        HTTP non-2xx means body is a JSON error envelope — raise GrpcError
        via the format_grpc_error_message string-prefix protocol.

    The returned Span is bounded by the input `body`'s origin; the caller
    feeds it straight into `Serializable.decode[D: WireDecoder]`.

    Raises GrpcError (as a raised Error with the [grpc:N] prefix) on:
      - Classic gRPC: HTTP non-200 (UNKNOWN with HTTP-status diagnostic).
      - Connect unary: HTTP non-2xx (the JSON error envelope's code).
      - Malformed envelope (UNKNOWN with diagnostic).
    """
    comptime if P.unary_is_enveloped():
        # Classic gRPC. HTTP non-200 maps to UNKNOWN.
        if http_status != 200:
            raise Error(
                String("[grpc:")
                + String(Int(GRPC_STATUS_UNKNOWN))
                + "] HTTP non-200 before gRPC framing: status="
                + String(Int(http_status))
            )
        # Body is one 5-byte envelope. Strip it.
        return grpc_decode_unary(body)
    else:
        # Connect-unary. HTTP 2xx → bare body; non-2xx → JSON error envelope.
        if http_status >= 200 and http_status < 300:
            return body
        # Non-2xx — parse the error envelope, fall back to UNKNOWN if the
        # envelope is malformed. Note the parse-then-raise sequence: the
        # `raise` must NOT be inside the `try` because Mojo's `try/except`
        # catches every Error, including the one we just constructed.
        var parsed_code = GRPC_STATUS_UNKNOWN
        var parsed_msg = String("")
        var parsed_ok: Bool
        try:
            var env = parse_connect_error_json(body)
            parsed_code = env.code
            parsed_msg = env.message
            parsed_ok = True
        except _:
            parsed_ok = False
        if parsed_ok:
            raise Error(
                String("[grpc:")
                + String(Int(parsed_code))
                + "] "
                + parsed_msg
            )
        # Malformed JSON envelope — fall back to UNKNOWN with diagnostic.
        raise Error(
            String("[grpc:")
            + String(Int(GRPC_STATUS_UNKNOWN))
            + "] HTTP non-2xx Connect response with malformed error"
            " envelope: status="
            + String(Int(http_status))
        )


# =============================================================================
# §3 — encode_stream_message[P] — encode one message into a streaming body.
# =============================================================================


def encode_stream_message[
    P: Protocol
](mut out: List[UInt8], message_bytes: Span[UInt8, _]):
    """Append one envelope-framed message to `out` for a streaming body.

    All four streaming modes — server-streaming requests, client-streaming
    requests, bidi requests, server-streaming responses, client-streaming
    responses, bidi responses — use the 5-byte envelope shared between
    classic gRPC and Connect-streaming.

    Connect-unary skips envelope but Connect-STREAMING does NOT — so this
    function is unconditional on P; it just appends the envelope.

    Args:
        out: Destination buffer (mutated).
        message_bytes: The already-serialized Mojo value.
    """
    write_envelope(out, UInt8(0), message_bytes)
