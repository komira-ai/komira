"""`komira_http` — Mojo-native HTTP client and server.

HTTP/1.1 (plaintext and native TLS via s2n-tls), HTTP/2 and gRPC /
Connect-RPC serving, and an HTTP client with pooling, retries and timeouts.

This module's curated re-exports are the canonical public surface.
Internal sub-modules (`codec`, `routing`, `transport`, `server`) may be
imported directly for advanced use cases.

Layers:
  - L0 Transport  — `transport/`
  - L1 TLS        — `tls/`
  - L2 Codec      — `codec/`
  - L3 Middleware — `middleware/`
  - L4 Routing    — `routing/`
  - Client        — `client/`
  - HttpServer    — `server.mojo`

"""

from .codec import (
    HTTP_METHOD_DELETE,
    HTTP_METHOD_GET,
    HTTP_METHOD_HEAD,
    HTTP_METHOD_OPTIONS,
    HTTP_METHOD_PATCH,
    HTTP_METHOD_POST,
    HTTP_METHOD_PUT,
    HTTP_METHOD_UNKNOWN,
    RESPONSE_FRAMING_CHUNKED,
    RESPONSE_FRAMING_CONTENT_LENGTH,
    ChunkedDecoder,
    ChunkedDecodeResult,
    HeadersParseOutcome,
    HttpMethod,
    HttpRequest,
    HttpResponse,
    ParseError,
    ParseLimits,
    build_100_continue_bytes,
    build_error_response_bytes,
    decode_block,
    parse_request_head,
    response_may_be_chunked,
    sanitize_for_log,
    serialize_response,
    serialize_response_framed,
    serialize_response_head,
    status_text,
)
from .middleware import (
    AuthedUser,
    ChainOutcome,
    CorsConfig,
    CorsMiddleware,
    ErrorMappingConfig,
    ErrorMappingMiddleware,
    GrantClaim,
    LogEntry,
    LoggingMiddleware,
    Middleware,
    MiddlewareChain,
    PassthroughMiddleware,
    RequestContext,
    TracingMiddleware,
    run_chain,
)
from .routing import (
    HANDLER_NOT_FOUND,
    Route,
    RouteBlock,
    AppRouter,
    Router,
    RouterBuildError,
)
from .server import HttpServer, HttpServerConfig, HttpServerStats
from .serving import (
    DEFAULT_SERVE_PORT,
    GcpServerlessEntry,
    ServerlessEntry,
    parse_serve_port,
    serve_one_iteration_chained_over,
    serve_one_iteration_over,
)
from .tls import (
    TLS_OUTCOME_BLOCKED_ON_READ,
    TLS_OUTCOME_BLOCKED_ON_WRITE,
    TLS_OUTCOME_DONE,
    TLS_OUTCOME_ERROR,
    TlsConfig,
    TlsConnection,
    TlsStream,
)
from .transport import (
    CONN_STATE_READING,
    CONN_STATE_WAITING_FOR_WRITABLE,
    ConnEntry,
    CtxRequestDispatcher,
    GRPC_KIND_CLIENT_STREAM,
    GRPC_KIND_SERVER_STREAM,
    GRPC_KIND_UNARY,
    GrpcDispatch,
    GrpcResponse,
    GrpcStreamDispatch,
    GrpcStreamResponse,
    NoopGrpcDispatch,
    RequestDispatcher,
    consumable_request_for,
    emit_grpc_response,
    emit_grpc_stream_response,
    is_grpc_content_type,
    serve_read_round_dispatch,
    serve_read_round_dispatch_chained,
)
