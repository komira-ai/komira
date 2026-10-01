# =============================================================================
# komira_grpc/protocol.mojo — Comptime Protocol parameter trait
# =============================================================================
#
# Zero runtime branching on the hot path.
# The wire protocol (Connect vs classic gRPC vs Connect-JSON) is selected
# by a comptime `Protocol` parameter on the generated client struct; the
# parameter monomorphizes encode/decode, header set, content-type, and
# status-extraction so the call path has NO runtime branches.
#
# Three conformers ship:
#
#   ProtocolGrpcProto      — classic gRPC over HTTP/2, application/grpc+proto.
#                            Unary IS enveloped (5-byte prefix); status from
#                            HTTP/2 trailers.
#   ProtocolConnectProto   — Connect, application/proto (unary) /
#                            application/connect+proto (streaming). Unary is
#                            bare body (no envelope); status from
#                            HTTP-status + (non-2xx → JSON error envelope).
#   ProtocolConnectJson    — Connect, application/json (unary) /
#                            application/connect+json (streaming). Same
#                            shape as ProtocolConnectProto but with JSON
#                            wire form.
#
# The Protocol trait surface is intentionally THIN — fn-pointers cross no
# module boundary, no heap state. Comptime constants only.
#
# Encapsulation: NO UnsafePointer in any public sig. The trait is pure
# comptime metadata.
# =============================================================================


# =============================================================================
# §1 — Protocol trait.
# =============================================================================


trait Protocol(Movable, Deinitable):
    """Wire-protocol comptime parameter for the gRPC client.

    Selects:
      - The HTTP request content-type for unary RPCs.
      - The HTTP request content-type for streaming RPCs.
      - The HTTP request `Accept` header value.
      - Whether unary requests are 5-byte-enveloped (classic gRPC YES;
        Connect NO).
      - The connect-rpc-version header value (Connect MUST send
        `Connect-Protocol-Version: 1`; classic gRPC
        omits it).
      - The status-extraction path (trailers vs initial-headers vs JSON
        error envelope) — abstracted as static methods on Self for now;
        the unary/streaming code paths dispatch on `Self`'s identity at
        comptime.

    The trait has NO state — every conformer is a zero-field struct that
    exists solely to thread the comptime axis. Generated stubs fix the
    Protocol at codegen time, so consumers see a typed
    `EchoServiceClient[C, ProtocolGrpcProto]` (or whichever protocol the
    `buf.gen.yaml` option selected).
    """

    @staticmethod
    def unary_content_type() -> String:
        """The HTTP `Content-Type` request header value for unary RPCs."""
        ...

    @staticmethod
    def stream_content_type() -> String:
        """The HTTP `Content-Type` request header value for streaming
        RPCs (server-streaming, client-streaming, bidi)."""
        ...

    @staticmethod
    def accept_header() -> String:
        """The HTTP `Accept` request header value."""
        ...

    @staticmethod
    def unary_is_enveloped() -> Bool:
        """True iff unary requests / responses are 5-byte-enveloped.
        Classic gRPC: True. Connect-{proto,json}: False (bare body)."""
        ...

    @staticmethod
    def connect_protocol_version() -> Optional[String]:
        """Some("1") for Connect; None for classic gRPC. Every Connect
        request MUST carry
        `Connect-Protocol-Version: 1`."""
        ...

    @staticmethod
    def stream_has_end_stream_envelope() -> Bool:
        """True iff this dialect terminates a STREAM with an envelope whose
        flags byte has bit 7 (0x80, `ENVELOPE_FLAG_END_STREAM`) set.

        ⚠ THIS IS NOT THE SAME QUESTION AS `unary_is_enveloped`, even though
        the two answers happen to be opposite for all three conformers today.
        `unary_is_enveloped` asks how a UNARY body is framed; this asks how a
        STREAM is TERMINATED, and the wire consequence of getting it wrong is
        the opposite direction of harm:

          * Connect-streaming (and gRPC-Web) DO end a stream with a flagged
            envelope carrying a JSON status.
          * Classic gRPC over HTTP/2 has NO end-of-stream envelope flag AT ALL
            — its terminal status rides in real HTTP/2 trailers. Per
            PROTOCOL-HTTP2 the Compressed-Flag is "a 1 byte unsigned integer"
            whose only defined values are 0 and 1, so 0x80 on a classic-gRPC
            stream is a CORRUPT BYTE, not a marker. Reading it as one
            terminates the response early and reports success — a truncated
            answer delivered as a complete one.

        Answering this off `unary_is_enveloped` would be a coincidence the next
        dialect breaks (gRPC-Web is enveloped for unary AND uses the 0x80
        end-of-stream envelope — it would need True for both), which is why it
        is its own question on the trait rather than a derived one.
        """
        ...

    @staticmethod
    def name() -> String:
        """Diagnostic name (for error messages)."""
        ...


# =============================================================================
# §2 — ProtocolGrpcProto — classic gRPC over HTTP/2.
# =============================================================================


@fieldwise_init
struct ProtocolGrpcProto(
    Protocol, Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Classic gRPC, bare `application/grpc`. HTTP/2 mandatory.

    - Unary request/response IS 5-byte-enveloped.
    - Status delivered in HTTP/2 trailers (`grpc-status` + `grpc-message`).
    - Initial HEADERS may carry `grpc-status` (the trailers-only response).
    """

    var _placeholder: UInt8

    @staticmethod
    def new() -> ProtocolGrpcProto:
        return ProtocolGrpcProto(_placeholder=UInt8(0))

    @staticmethod
    def unary_content_type() -> String:
        # Bare `application/grpc` is the canonical, universally-routable
        # content-type. Google's GFE (storage.googleapis.com, Cloud Tasks,
        # Cloud Run, Pub/Sub) returns HTTP 404 text/html for the
        # spec-valid-but-non-canonical `application/grpc+proto` and only
        # routes to gRPC for the bare form (reproducible with curl against
        # storage.googleapis.com). komira_connect's server accepts BOTH forms
        # (codec_id_for_content_type / is_grpc_content_type strip params and
        # match the bare base), so emitting bare is safe against it too.
        return String("application/grpc")

    @staticmethod
    def stream_content_type() -> String:
        return String("application/grpc")

    @staticmethod
    def accept_header() -> String:
        return String("application/grpc")

    @staticmethod
    def unary_is_enveloped() -> Bool:
        return True

    @staticmethod
    def connect_protocol_version() -> Optional[String]:
        return Optional[String]()

    @staticmethod
    def stream_has_end_stream_envelope() -> Bool:
        # Classic gRPC over HTTP/2 terminates a stream with real HTTP/2
        # TRAILERS. There is no end-of-stream envelope flag in this dialect,
        # so 0x80 in a flags byte is corruption — see the trait docstring.
        return False

    @staticmethod
    def name() -> String:
        return String("grpc+proto")


# =============================================================================
# §3 — ProtocolConnectProto — Connect, protobuf-binary wire.
# =============================================================================


@fieldwise_init
struct ProtocolConnectProto(
    Protocol, Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Connect, `application/proto` (unary) / `application/connect+proto`
    (streaming). HTTP/1.1 or HTTP/2.

    - Unary request/response is BARE BODY (no 5-byte envelope).
    - Streaming uses the 5-byte envelope (shared with classic gRPC).
    - Status: HTTP status line for unary; on non-2xx, the body is a
      Connect-JSON error envelope.
    - Streaming: end-of-stream envelope carries the status JSON.
    """

    var _placeholder: UInt8

    @staticmethod
    def new() -> ProtocolConnectProto:
        return ProtocolConnectProto(_placeholder=UInt8(0))

    @staticmethod
    def unary_content_type() -> String:
        return String("application/proto")

    @staticmethod
    def stream_content_type() -> String:
        return String("application/connect+proto")

    @staticmethod
    def accept_header() -> String:
        return String("application/proto")

    @staticmethod
    def unary_is_enveloped() -> Bool:
        return False

    @staticmethod
    def connect_protocol_version() -> Optional[String]:
        return Optional(String("1"))

    @staticmethod
    def stream_has_end_stream_envelope() -> Bool:
        # Connect-streaming ends a stream with an envelope whose flags byte
        # has bit 7 set; its payload is the JSON status (`{}` / `{"error":…}`).
        return True

    @staticmethod
    def name() -> String:
        return String("connect+proto")


# =============================================================================
# §4 — ProtocolConnectJson — Connect, proto3-canonical-JSON wire.
# =============================================================================


@fieldwise_init
struct ProtocolConnectJson(
    Protocol, Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """Connect, `application/json` (unary) / `application/connect+json`
    (streaming). HTTP/1.1 or HTTP/2. JSON debug-friendly variant.

    Same framing rules as ProtocolConnectProto — JSON differs only in
    the encoded bytes a generated stub feeds in / decodes out via the
    `Proto3JsonWire` `komira_serde` backend.
    """

    var _placeholder: UInt8

    @staticmethod
    def new() -> ProtocolConnectJson:
        return ProtocolConnectJson(_placeholder=UInt8(0))

    @staticmethod
    def unary_content_type() -> String:
        return String("application/json")

    @staticmethod
    def stream_content_type() -> String:
        return String("application/connect+json")

    @staticmethod
    def accept_header() -> String:
        return String("application/json")

    @staticmethod
    def unary_is_enveloped() -> Bool:
        return False

    @staticmethod
    def connect_protocol_version() -> Optional[String]:
        return Optional(String("1"))

    @staticmethod
    def stream_has_end_stream_envelope() -> Bool:
        # Connect-streaming ends a stream with an envelope whose flags byte
        # has bit 7 set; its payload is the JSON status (`{}` / `{"error":…}`).
        return True

    @staticmethod
    def name() -> String:
        return String("connect+json")
