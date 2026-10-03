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
    is_grpc_content_type,
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
