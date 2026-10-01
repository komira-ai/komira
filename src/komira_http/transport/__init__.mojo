# =============================================================================
# src/komira_http/transport/__init__.mojo — L0 transport facade
# =============================================================================
#
# per-pthread share-nothing event loop on top of
# komira_async's public state-machine track API. macOS arm64 via
# kqueue, Linux x86_64 via epoll — comptime-selected via
# CompilationTarget.is_macos() inside `accept_loop`.
# =============================================================================

from .connection import (
    CONN_STATE_READING,
    CONN_STATE_WAITING_FOR_WRITABLE,
    ConnEntry,
    REQ_BUF_BYTES,
    RESP_BUF_CAP,
)

# Route→handler dispatch hook (the application request→response leaf the
# canned/chained paths lack). An app package plugs a `RequestDispatcher`
# conformer in via `HttpServer.serve_one_iteration_dispatch[D]`.
from .dispatch import (
    CtxRequestDispatcher,
    RequestDispatcher,
    consumable_request_for,
    serve_read_round_dispatch,
    serve_read_round_dispatch_chained,
)

# live gRPC-over-HTTP/2 dispatch seam + trailer emission.
# streaming sibling seam (server/client streaming).
from .grpc_emit import (
    GRPC_KIND_CLIENT_STREAM,
    GRPC_KIND_SERVER_STREAM,
    GRPC_KIND_UNARY,
    GrpcDispatch,
    GrpcResponse,
    GrpcStreamDispatch,
    GrpcStreamResponse,
    NoopGrpcDispatch,
    emit_grpc_response,
    emit_grpc_stream_response,
    is_grpc_content_type,
)

# client-side IoStream + Connector traits +
# StreamIo / Pending POD types. Co-owned dir
from .io_stream import (
    Connector,
    IoStream,
    NEGOTIATED_HTTP_1_1,
    NEGOTIATED_HTTP_2,
    NEGOTIATED_HTTP_3,
    Pending,
    STREAM_IO_EOF,
    STREAM_IO_ERROR,
    STREAM_IO_PENDING,
    STREAM_IO_READY,
    StreamIo,
    TRANSPORT_KIND_DPDK,
    TRANSPORT_KIND_KERNEL_TCP,
    TRANSPORT_KIND_QUIC,
)

# KernelTcpConnector + TcpIoStream
# production conformers. The critical path.
from .kernel_tcp import (
    KernelTcpConnector,
    TcpIoStream,
)

# ScriptedConnector + ScriptedStream
# mock conformers. first-class deliverable — the designed-in
# test seam for all unit tests.
from .scripted import (
    ScriptedConnector,
    ScriptedStream,
)
