# =============================================================================
# komira_grpc/headers.mojo — Build request HeaderMap from CallOptions
# =============================================================================
#
# Every gRPC client request must set:
#   - `Content-Type`: per protocol (P.unary_content_type() / .stream_content_type()).
#   - `Accept`: per protocol.
#   - `Connect-Protocol-Version: 1` for Connect (P.connect_protocol_version()).
#   - `Grpc-Timeout` if CallOptions.has_deadline().
#   - `Grpc-Accept-Encoding: identity` to negotiate the "no compression" path
#     (compression is not supported; this saves servers that default to
#     gzip from compressing responses we can't decode).
#   - User metadata — VERBATIM keys on the classic-gRPC arm, `grpc-metadata-`
#     prefixed on the Connect arm. See `_drain_user_metadata`.
#
# Encapsulation: NO UnsafePointer in any public sig. The runtime clock value
# (`now_us`) is passed in by the caller — this module is clock-agnostic.
# =============================================================================

from komira_connect.deadline import (
    encode_grpc_timeout_us,
)
from komira_http.client.header_map import HeaderMap

from komira_grpc.protocol import Protocol
from komira_grpc.call_options import CallOptions, CALL_DEADLINE_UNSET


# =============================================================================
# §1 — Canonical request header names + values.
# =============================================================================

comptime GRPC_HEADER_CONTENT_TYPE: String = "content-type"
comptime GRPC_HEADER_ACCEPT: String = "accept"
comptime GRPC_HEADER_CONNECT_PROTOCOL_VERSION: String = "connect-protocol-version"
comptime GRPC_HEADER_GRPC_TIMEOUT: String = "grpc-timeout"
comptime GRPC_HEADER_GRPC_ACCEPT_ENCODING: String = "grpc-accept-encoding"
comptime GRPC_HEADER_GRPC_ENCODING: String = "grpc-encoding"
comptime GRPC_HEADER_TE: String = "te"

comptime GRPC_TE_TRAILERS: String = "trailers"
"""Per the gRPC-over-HTTP/2 protocol (PROTOCOL-HTTP2.md), a classic-gRPC
request MUST carry `TE: trailers` — it tells the HTTP/2 server the client will
read the terminal status from trailers. A strict gRPC server (e.g. grpc-go,
as embedded in several cloud-service emulators) stalls the handler waiting for a
client that can receive trailers when this header is absent, surfacing as
DEADLINE_EXCEEDED. Emitted ONLY for the enveloped (classic gRPC) protocols;
Connect does not use it."""

comptime GRPC_ENCODING_IDENTITY: String = "identity"
"""Negotiates `identity` (no compression). The framer decodes the
per-message compression flag, but the client stays identity-only by sending
`Grpc-Accept-Encoding: identity` so servers don't gzip the response."""


# =============================================================================
# §2 — build_unary_request_headers[P] — for unary calls.
# =============================================================================


def build_unary_request_headers[
    P: Protocol
](
    opts: CallOptions,
    now_us: Int,
) raises -> HeaderMap:
    """Build the request HeaderMap for a unary RPC call.

    Args:
        opts:   CallOptions (deadline + metadata).
        now_us: Current clock value in microseconds — used to compute the
                relative `Grpc-Timeout` header from the absolute deadline.

    Returns a HeaderMap ready to attach to a ClientRequest:
      - content-type: P.unary_content_type()
      - accept:       P.accept_header()
      - connect-protocol-version: "1" (Connect only)
      - grpc-timeout: (only if opts.has_deadline())
      - grpc-accept-encoding: identity
      - user metadata (per opts.metadata) — `<key>: <value>` on classic gRPC,
        `grpc-metadata-<key>: <value>` on Connect. See `_drain_user_metadata`.
    """
    var hdrs = HeaderMap()
    hdrs.append(GRPC_HEADER_CONTENT_TYPE, P.unary_content_type())
    hdrs.append(GRPC_HEADER_ACCEPT, P.accept_header())
    # `TE: trailers` is MANDATORY for classic gRPC (the terminal status arrives
    # in HTTP/2 trailers). A strict gRPC server stalls without it → DEADLINE.
    comptime if P.unary_is_enveloped():
        hdrs.append(GRPC_HEADER_TE, GRPC_TE_TRAILERS)
    var connect_ver = P.connect_protocol_version()
    if connect_ver.__bool__():
        hdrs.append(
            GRPC_HEADER_CONNECT_PROTOCOL_VERSION, connect_ver.value()
        )
    _set_grpc_timeout_if_set(hdrs, opts, now_us)
    hdrs.append(GRPC_HEADER_GRPC_ACCEPT_ENCODING, GRPC_ENCODING_IDENTITY)
    _drain_user_metadata[P](hdrs, opts)
    # RAW transport / routing headers (authorization, x-goog-request-params):
    # emitted VERBATIM, no grpc-metadata- prefix.
    opts.raw_metadata.drain_raw_into_request_headers(hdrs)
    return hdrs^


# =============================================================================
# §3 — build_stream_request_headers[P] — for streaming calls.
# =============================================================================


def build_stream_request_headers[
    P: Protocol
](
    opts: CallOptions,
    now_us: Int,
) raises -> HeaderMap:
    """Build the request HeaderMap for a streaming RPC call.

    Identical to build_unary_request_headers except content-type +
    accept are P.stream_content_type() (different from unary on Connect:
    `application/connect+proto` vs `application/proto`).
    """
    var hdrs = HeaderMap()
    hdrs.append(GRPC_HEADER_CONTENT_TYPE, P.stream_content_type())
    hdrs.append(GRPC_HEADER_ACCEPT, P.stream_content_type())
    var connect_ver = P.connect_protocol_version()
    if connect_ver.__bool__():
        hdrs.append(
            GRPC_HEADER_CONNECT_PROTOCOL_VERSION, connect_ver.value()
        )
    else:
        # Classic gRPC over HTTP/2
        # MUST send `te: trailers` on STREAMING calls too — the terminal
        # `grpc-status` arrives in HTTP/2 trailers regardless of unary vs
        # streaming. A spec-compliant gRPC frontend (nghttpx, Envoy, the
        # Google front-ends) REJECTS a streaming request without it
        # (trailers-only `grpc-status=2`, empty body -> the client surfaces
        # "client-stream produced no response message"). Gated on the
        # classic-gRPC arm (connect_protocol_version() == None); Connect
        # streaming is enveloped but does NOT use HTTP/2 trailers, so it MUST
        # NOT send `te: trailers` (do not key this on unary_is_enveloped()).
        hdrs.append(GRPC_HEADER_TE, GRPC_TE_TRAILERS)
    _set_grpc_timeout_if_set(hdrs, opts, now_us)
    hdrs.append(GRPC_HEADER_GRPC_ACCEPT_ENCODING, GRPC_ENCODING_IDENTITY)
    _drain_user_metadata[P](hdrs, opts)
    # RAW transport / routing headers (authorization, x-goog-request-params):
    # emitted VERBATIM, no grpc-metadata- prefix.
    opts.raw_metadata.drain_raw_into_request_headers(hdrs)
    return hdrs^


# =============================================================================
# §4 — Helpers.
# =============================================================================


def _drain_user_metadata[
    P: Protocol
](mut hdrs: HeaderMap, opts: CallOptions) raises:
    """Emit `opts.metadata` in the spelling THIS protocol's peer reads.

    ★ THE PREFIX IS PROTOCOL-SPECIFIC.

    Over **gRPC/HTTP2** a Custom-Metadata key travels VERBATIM — it IS the
    header name (`PROTOCOL-HTTP2.md`, "Custom-Metadata"). The gRPC interop
    `custom_metadata` case echoes `x-grpc-test-echo-initial` by that exact
    name, and a real gRPC server has no notion of a prefixed spelling.

    Over **Connect** the `Grpc-Metadata-` prefix is exactly right: Connect
    carries gRPC metadata across a protocol translation and needs it
    distinguishable from generic HTTP headers.

    A client that prefixed every key on BOTH arms would send a classic-gRPC
    server `grpc-metadata-x-grpc-test-echo-initial` instead of
    `x-grpc-test-echo-initial`, and the server would ignore it. The interop
    case cannot pass on such a client, and neither can any server-side
    routing or auth that reads a custom key by name.

    The discriminator is `connect_protocol_version()` — Some("1") for the two
    Connect protocols, None for classic gRPC — the same one this module
    already uses to decide `connect-protocol-version` and `te: trailers`.
    Deliberately NOT `unary_is_enveloped()`: Connect STREAMING is enveloped
    too, and keying on it would put the wrong spelling on that arm.
    """
    if P.connect_protocol_version().__bool__():
        opts.metadata.drain_into_request_headers(hdrs)
    else:
        opts.metadata.drain_verbatim_into_request_headers(hdrs)


def _set_grpc_timeout_if_set(
    mut hdrs: HeaderMap,
    opts: CallOptions,
    now_us: Int,
) raises:
    """If `opts.has_deadline()`, compute `relative = deadline - now_us` and
    append `Grpc-Timeout` header.

    The unit char picks the largest unit that represents the timeout
    WITHOUT rounding. encode_grpc_timeout_us handles that. The value is
    capped at 8 digits per spec; the encoder degrades to `u` (micros)
    for non-integer fits.

    For an already-tripped or 0-or-negative remaining: emit `Grpc-Timeout: 0u`
    so the server sees the timeout and either rejects immediately or
    burns through fast.
    """
    if not opts.has_deadline():
        return
    var remaining_us = opts.deadline_micros - now_us
    if remaining_us < 0:
        remaining_us = 0
    var value = encode_grpc_timeout_us(remaining_us)
    hdrs.append(GRPC_HEADER_GRPC_TIMEOUT, value^)
