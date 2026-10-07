"""Transport surface shared by client and server: plain TCP, the scripted fake, the
IO stream trait, stream parking, gRPC trailer emission."""

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
    emit_grpc_trailers_only,
    is_grpc_content_type,
)
from .grpc_timeout import (
    GRPC_DEADLINE_EXCEEDED_MESSAGE,
    GRPC_MALFORMED_TIMEOUT_PREFIX,
    GRPC_STATUS_DEADLINE_EXCEEDED,
    GRPC_STATUS_INTERNAL,
    GRPC_TIMEOUT_ABSENT,
    GRPC_TIMEOUT_MALFORMED,
    GRPC_TIMEOUT_SET,
    GrpcDeadline,
    GrpcTimeout,
    emit_grpc_deadline_exceeded,
    emit_grpc_malformed_timeout,
    find_grpc_timeout,
    grpc_deadline_at_arrival,
    is_grpc_h2_content_type,
    parse_grpc_timeout_value,
)
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
from .kernel_tcp import KernelTcpConnector, TcpIoStream
from .scripted import ScriptedConnector, ScriptedStream
