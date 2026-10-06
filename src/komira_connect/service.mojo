# =============================================================================
# service.mojo — ConnectService builder + method registry
# =============================================================================
#
# ConnectService is the **third ergonomic surface**
# for service definition (alongside HttpService and Service[OpenApiSpec]).
# It accepts a method-by-method registration of handler fns; under the
# hood it builds a path-keyed dispatch table.
#
# The shape:
#
#   var svc = ConnectService("example.search.v1.SearchService")
#   svc.register_method("/example.search.v1.SearchService/Search", search_handler)
#   svc.register_method("/example.search.v1.SearchService/AddDoc", add_doc_handler)
#   ...
#   var result = svc.handle_request(":path", "Content-Type", request_body)
#
# `handle_request` reads the request path + content-type, dispatches to
# the handler, and returns a DispatchResult. The HttpServer integration
# wires this into the request/response cycle.
#
# The registration surface is meant to serve hand-written and generated
# services alike: a code generator can call `svc.register_method(path,
# handler)` once per RPC method. No generator in this repository emits
# such calls yet.
#
# Encapsulation: NO UnsafePointer in any public sig.
# =============================================================================

from komira_http_core.transport.grpc_emit import (
    GRPC_KIND_CLIENT_STREAM,
    GRPC_KIND_SERVER_STREAM,
    GRPC_KIND_UNARY,
    GrpcDispatch,
    GrpcResponse,
    GrpcStreamDispatch,
    GrpcStreamResponse,
)

from .codec_grpc import (
    GRPC_CONTENT_TYPE_PROTO,
    grpc_decode_stream,
    grpc_encode_unary,
    grpc_percent_encode_message,
)
from .codec_grpc_web import GRPC_WEB_CONTENT_TYPE_PROTO
from .codec_connect_json import CONNECT_JSON_CONTENT_TYPE_UNARY
from .dispatch import (
    CODEC_ID_UNKNOWN,
    CODEC_ID_GRPC,
    CODEC_ID_GRPC_WEB,
    CODEC_ID_CONNECT_JSON,
    ConnectHandlerFn,
    DispatchResult,
    codec_id_for_content_type,
    dispatch,
    grpc_web_error_body,
)
from .status import (
    GRPC_STATUS_OK,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_UNIMPLEMENTED,
    GRPC_STATUS_UNKNOWN,
    grpc_status_to_http_status,
    parse_connect_error,
)


# =============================================================================
# §1 — Method registry entry — POD pair of (path, handler).
# =============================================================================


@fieldwise_init
struct ConnectMethodEntry(Copyable, Movable, ImplicitlyCopyable, Deinitable):
    """One registered RPC method.

    Holds the full Connect-RPC path (e.g. `/example.search.v1.SearchService/Search`)
    and the handler fn-value.
    """

    var path: String
    """The full Connect-RPC path (`/package.Service/Method`)."""

    var handler: ConnectHandlerFn
    """The handler fn invoked by the dispatcher. A fn-pointer is POD (no
    heap), like an FFI function-pointer field."""


# =============================================================================
# §1b — Streaming handler type + registry entry.
# =============================================================================
#
# A streaming handler takes the DECODED inbound messages (each an owned
# List[UInt8] of the inner protobuf bytes) and returns the outbound messages
# (each an owned List[UInt8] of the inner protobuf bytes). The conformer does
# the envelope split (request) + frame (response) around this — the handler
# only sees protobuf message payloads, never envelopes.
#
#   * Server-streaming (DoGet): inbound has exactly 1 message; returns N.
#   * Client-streaming (DoPut): inbound has N messages; returns exactly 1.
#
# A single fn-type covers both directions (the count asymmetry is data, not
# type). `kind` is passed so a handler that serves both shapes can branch.
# The handler raises on error; the conformer maps the Error to a non-zero
# grpc-status close trailer (the partial messages already emitted still go out;
# the trailer carries the error code).

comptime ConnectStreamHandlerFn = def (
    codec_id: UInt8, kind: UInt8, req_messages: List[List[UInt8]]
) raises thin -> List[List[UInt8]]


@fieldwise_init
struct ConnectStreamMethodEntry(
    Copyable, Movable, ImplicitlyCopyable, Deinitable
):
    """One registered streaming RPC method.

    Holds the full path, the streaming handler fn-value, and the streaming
    `kind` (GRPC_KIND_SERVER_STREAM / GRPC_KIND_CLIENT_STREAM)."""

    var path: String
    var handler: ConnectStreamHandlerFn
    var kind: UInt8


# =============================================================================
# §2 — ConnectService — the builder + registry.
# =============================================================================


struct ConnectService(
    GrpcDispatch, GrpcStreamDispatch, Movable, Deinitable
):
    """The Connect-RPC service builder + dispatcher.

    Conforms to `komira_http.GrpcDispatch` so it
    can be installed directly into the live h2 serve loop
    (`HttpServer[ConnectService]`). The serve loop calls `dispatch_grpc`,
    which wraps the existing `handle_request` + translates the
    `DispatchResult` into the plain-data `GrpcResponse` the h2 trailer-emit
    path consumes. This is the cycle-free bridge: `komira_http` names the
    `GrpcDispatch` trait (plain types); `komira_connect` (which depends on
    `komira_http`) provides the conformance.

    Holds a method registry by full path. The HttpServer integration
    layer registers a wildcard route for `/{pkg}.{svc}/...` patterns
    and delegates incoming requests via `handle_request`.

    ConnectService is an HTTP service plus the Connect envelope codec plus
    a method-dispatch table.
    """

    var name: String
    """Service name (informational; used in logs / errors)."""

    var methods: List[ConnectMethodEntry]
    """Registered UNARY methods. Lookup is O(N) linear; for ~10-100 methods per
    service this is fine; if a service grows beyond that, a hash table
    can replace it."""

    var stream_methods: List[ConnectStreamMethodEntry]
    """Registered STREAMING methods. Same linear-scan registry;
    keyed by full path; carries the streaming `kind` (server / client)."""

    def __init__(out self, name: String):
        """Create an empty ConnectService with the given service name."""
        self.name = name
        self.methods = List[ConnectMethodEntry]()
        self.stream_methods = List[ConnectStreamMethodEntry]()

    def register_method(mut self, path: String, handler: ConnectHandlerFn):
        """Register an RPC method.

        `path` should be the full Connect-RPC path, e.g.,
        `/example.search.v1.SearchService/Search`.

        Calling register_method twice with the same path silently
        overwrites the existing handler — this is intentional for
        in-process re-registration (test fixtures, plugins).
        """
        # Overwrite if path already registered
        for i in range(len(self.methods)):
            if self.methods[i].path == path:
                self.methods[i].handler = handler
                return
        self.methods.append(ConnectMethodEntry(path, handler))

    def register_server_stream(
        mut self, path: String, handler: ConnectStreamHandlerFn,
    ):
        """Register a SERVER-streaming RPC method (DoGet shape): one request
        message in -> N response messages out. The handler receives a 1-element
        `req_messages` list and returns N response messages."""
        self._register_stream(path, handler, GRPC_KIND_SERVER_STREAM)

    def register_client_stream(
        mut self, path: String, handler: ConnectStreamHandlerFn,
    ):
        """Register a CLIENT-streaming RPC method (DoPut shape): N request
        messages in -> one response message out. The handler receives an
        N-element `req_messages` list and returns a 1-element response list."""
        self._register_stream(path, handler, GRPC_KIND_CLIENT_STREAM)

    def _register_stream(
        mut self, path: String, handler: ConnectStreamHandlerFn, kind: UInt8,
    ):
        """Register (or overwrite) a streaming method."""
        for i in range(len(self.stream_methods)):
            if self.stream_methods[i].path == path:
                self.stream_methods[i].handler = handler
                self.stream_methods[i].kind = kind
                return
        self.stream_methods.append(
            ConnectStreamMethodEntry(path, handler, kind)
        )

    def _stream_method_idx(imm self, path: String) -> Int:
        """Index of the streaming method for `path`, or -1 if absent."""
        for i in range(len(self.stream_methods)):
            if self.stream_methods[i].path == path:
                return i
        return -1

    def method_count(imm self) -> Int:
        """Number of registered RPC methods."""
        return len(self.methods)

    def has_method(imm self, path: String) -> Bool:
        """True iff `path` is registered."""
        for i in range(len(self.methods)):
            if self.methods[i].path == path:
                return True
        return False

    def lookup_handler(imm self, path: String) -> ConnectHandlerFn:
        """Look up the handler for `path`.

        Returns a sentinel handler that raises GRPC_STATUS_NOT_FOUND if
        the path is not registered. Caller must use has_method to check
        for registration first if they want to surface NOT_FOUND
        differently.
        """
        for i in range(len(self.methods)):
            if self.methods[i].path == path:
                return self.methods[i].handler
        return _not_found_handler

    def handle_request(
        imm self,
        path: String,
        content_type: String,
        request_body: Span[UInt8, _],
    ) -> DispatchResult:
        """Dispatch one incoming request.

        Resolves codec_id from `content_type`, looks up the handler by
        `path`, and dispatches. If `path` is not registered, returns
        a NOT_FOUND result.
        """
        var codec_id = codec_id_for_content_type(content_type)
        if not self.has_method(path):
            return _make_not_found_result(codec_id, path)
        var handler = self.lookup_handler(path)
        return dispatch(handler, codec_id, request_body)

    def dispatch_grpc(
        mut self,
        path: String,
        content_type: String,
        request_body: List[UInt8],
    ) -> GrpcResponse:
        """`GrpcDispatch` conformance: route one live gRPC
        request and return the plain-data `GrpcResponse` the h2 serve loop
        emits (HEADERS + DATA + grpc-status trailer).

        Wraps `handle_request` (which resolves the codec, looks up the
        method, decodes, invokes the handler, re-encodes) and translates the
        resulting `DispatchResult` into a `GrpcResponse`:
          * body  ← the wire-encoded response body (envelope-framed for
                    gRPC; JSON for Connect).
          * grpc_status / grpc_message ← from the DispatchResult; an erroring
                    handler keeps http_status 200 and surfaces the code in the
                    trailer (never an h2 stream error).
          * content_type ← the response content-type for the resolved codec.
          * emit_trailer ← True for gRPC/gRPC-Web (status rides the h2
                    trailer); False for Connect-JSON (status is in the JSON
                    body / HTTP status, ordinary HEADERS+DATA close).

        STREAMING goes through the `dispatch_grpc_stream` sibling
        (server/client streaming, e.g. DoGet/DoPut). This unary method stays
        the single-buffered fast path."""
        var codec_id = codec_id_for_content_type(content_type)
        var result = self.handle_request(path, content_type, Span(request_body))

        # Resolve the response content-type + trailer policy from the codec.
        var resp_ct: String
        var emit_trailer: Bool
        if codec_id == CODEC_ID_GRPC:
            resp_ct = String(GRPC_CONTENT_TYPE_PROTO)
            emit_trailer = True
        elif codec_id == CODEC_ID_GRPC_WEB:
            resp_ct = String(GRPC_WEB_CONTENT_TYPE_PROTO)
            # gRPC-Web carries trailers in the BODY (not h2 trailers); the
            # dispatch already framed them into result.body, so close with an
            # ordinary HEADERS+DATA(END_STREAM) — no h2 trailer.
            emit_trailer = False
        elif codec_id == CODEC_ID_CONNECT_JSON:
            resp_ct = String(CONNECT_JSON_CONTENT_TYPE_UNARY)
            emit_trailer = False
        else:
            # Unknown codec — answer UNIMPLEMENTED as a gRPC trailer.
            resp_ct = String(GRPC_CONTENT_TYPE_PROTO)
            emit_trailer = True

        # Percent-encode grpc-message for the trailer (only meaningful when
        # emit_trailer is True and the status is non-OK).
        var msg = String("")
        if result.grpc_status != GRPC_STATUS_OK:
            msg = grpc_percent_encode_message(result.grpc_message)

        var body_copy = List[UInt8]()
        for i in range(len(result.body)):
            body_copy.append(result.body[i])

        return GrpcResponse(
            body_copy^,
            result.http_status,
            result.grpc_status,
            msg^,
            resp_ct^,
            emit_trailer,
        )

    def grpc_stream_kind(self, path: String) -> UInt8:
        """`GrpcStreamDispatch` conformance. Resolve `path`'s
        streaming kind: GRPC_KIND_SERVER_STREAM / GRPC_KIND_CLIENT_STREAM if a
        streaming method is registered, else GRPC_KIND_UNARY (the serve loop
        then routes to the unary `dispatch_grpc` fast path)."""
        var idx = self._stream_method_idx(path)
        if idx < 0:
            return GRPC_KIND_UNARY
        return self.stream_methods[idx].kind

    def dispatch_grpc_stream(
        mut self,
        path: String,
        content_type: String,
        kind: UInt8,
        request_body: List[UInt8],
    ) -> GrpcStreamResponse:
        """`GrpcStreamDispatch` conformance: route a streaming
        gRPC request and return the per-message response bodies + close status.

        Pipeline (gRPC codec only — gRPC streaming requires HTTP/2):
          1. Split the request body into N inbound envelopes
             (`grpc_decode_stream`). Server-streaming has 1; client-streaming
             has N. (A request that mis-frames -> grpc-status close, no
             messages.)
          2. Copy each inbound payload into an owned List[UInt8] (the handler
             takes owned messages — same fn-typed-field origin constraint as
             the unary path).
          3. Invoke the streaming handler -> N outbound message payloads.
          4. Frame each outbound payload into its own gRPC envelope
             (`grpc_encode_unary` = one 5-byte envelope around the message) —
             each becomes a separate h2 DATA frame in `emit_grpc_stream_response`.
          5. On handler error: parse the [connect:N] code -> a non-zero
             grpc-status close (any messages already framed before the raise are
             dropped; the trailer carries the error).
        """
        # gRPC streaming uses the gRPC codec (envelope framing + h2 trailers).
        var resp_ct = String(GRPC_CONTENT_TYPE_PROTO)

        # ---- 1+2) split the inbound envelopes into owned message payloads. ----
        var req_messages = List[List[UInt8]]()
        try:
            var envelopes = grpc_decode_stream(Span(request_body))
            for ei in range(len(envelopes)):
                var payload = List[UInt8]()
                var view = envelopes[ei].payload
                for bi in range(len(view)):
                    payload.append(view[bi])
                req_messages.append(payload^)
        except e:
            # Malformed request framing -> INVALID-ish; surface as a close
            # trailer (UNKNOWN) with no messages.
            return GrpcStreamResponse(
                List[List[UInt8]](),
                UInt16(200),
                GRPC_STATUS_UNKNOWN,
                grpc_percent_encode_message(String(e)),
                resp_ct^,
            )

        # ---- method lookup. ----
        var idx = self._stream_method_idx(path)
        if idx < 0:
            return GrpcStreamResponse(
                List[List[UInt8]](),
                UInt16(200),
                GRPC_STATUS_NOT_FOUND,
                grpc_percent_encode_message(
                    String("method ") + path + " not registered"
                ),
                resp_ct^,
            )
        var handler = self.stream_methods[idx].handler

        # ---- 3) invoke the streaming handler. ----
        var out_messages: List[List[UInt8]]
        try:
            out_messages = handler(CODEC_ID_GRPC, kind, req_messages^)
        except e:
            var parsed = parse_connect_error(String(e))
            return GrpcStreamResponse(
                List[List[UInt8]](),
                UInt16(200),
                parsed[0],
                grpc_percent_encode_message(parsed[1]),
                resp_ct^,
            )

        # ---- 4) frame each outbound payload into its own gRPC envelope. ----
        var framed = List[List[UInt8]]()
        for oi in range(len(out_messages)):
            framed.append(grpc_encode_unary(Span(out_messages[oi])))

        return GrpcStreamResponse(
            framed^,
            UInt16(200),
            GRPC_STATUS_OK,
            String(""),
            resp_ct^,
        )


# =============================================================================
# §3 — Sentinel "method not found" handler + result builder.
# =============================================================================


def _not_found_handler(codec_id: UInt8, req_body: List[UInt8]) raises -> List[UInt8]:
    """Sentinel handler invoked when a method lookup misses.

    Always raises the formatted not-found error. The dispatcher catches
    it and emits the correct wire status.
    """
    from .status import format_connect_error
    raise Error(String(format_connect_error(GRPC_STATUS_NOT_FOUND, String("method not registered"))))


def _make_not_found_result(codec_id: UInt8, path: String) -> DispatchResult:
    """Build a NOT_FOUND DispatchResult for `path`.

    Used by `handle_request` to short-circuit when the path is not in
    the registry — avoids the cost of invoking the sentinel handler.
    """
    from .codec_connect_json import build_connect_error_json

    var body = List[UInt8]()
    var http_status = grpc_status_to_http_status(GRPC_STATUS_NOT_FOUND)
    if codec_id == CODEC_ID_CONNECT_JSON:
        body = build_connect_error_json(
            GRPC_STATUS_NOT_FOUND, String("method ") + path + " not registered"
        )
    elif codec_id == CODEC_ID_GRPC:
        # gRPC: 200 + trailer carries status; body empty
        http_status = UInt16(200)
    elif codec_id == CODEC_ID_GRPC_WEB:
        # gRPC-Web: 200 + the trailer frame in the body.
        body = grpc_web_error_body(
            GRPC_STATUS_NOT_FOUND, String("method ") + path + " not registered"
        )
        http_status = UInt16(200)
    return DispatchResult(
        body^,
        http_status,
        GRPC_STATUS_NOT_FOUND,
        String("method ") + path + " not registered",
        codec_id,
    )
