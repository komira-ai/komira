"""`komira_grpc` — gRPC + Connect-RPC client runtime.

The CLIENT side of the gRPC and Connect-RPC specifications
(https://grpc.io + https://connectrpc.com).

The client speaks the gRPC protocol family — classic gRPC over HTTP/2 AND
Connect — sharing one runtime substrate for framing (envelope), status codes,
deadlines / cancellation, and metadata. The wire-protocol axis is a comptime
`Protocol` parameter (`ProtocolGrpcProto`, `ProtocolConnectProto`,
`ProtocolConnectJson`); generated stubs fix it at codegen time so the hot path
has ZERO runtime branching.

The server counterpart is `komira_connect`. The shared substrate (envelope /
status / 3 codecs / deadline) lives there as its one home; `komira_grpc`
IMPORTS it and never duplicates it.

Dependency direction (cycle-free):
  komira_grpc -> komira_connect  (envelope / status / 3 codecs / deadline)
  komira_grpc -> komira_http     (HttpClient + Body + HeaderMap)
  komira_grpc -> komira_async    (Reactor / CancellationToken / Runtime)
  komira_grpc -> komira_obs      (the monotonic clock behind the re-issue bound)

The client operates on opaque message bytes; message (de)serialization is the
generated stub's concern, so this package does not depend on a codec.

Encapsulation: NO UnsafePointer in any public sig. ZERO wildcard origins.
ZERO `unsafe_from_address`. ZERO `take_pointee` (Optional.take +
OwnedPointer.into_inner instead). ZERO new ArcPointer (stream structs are
short-lived, one per call).
"""

from .error import (
    GrpcError,
    format_grpc_error_message,
    parse_grpc_error_message,
    parse_grpc_status_code,
    parse_grpc_status_trailers,
    parse_grpc_status_initial_headers,
    grpc_error_from_http_non_200,
    from_connect_error_envelope,
)

from .metadata import (
    GRPC_METADATA_HEADER_PREFIX,
    GRPC_BIN_HEADER_SUFFIX,
    RpcMetadata,
    base64_encode_standard,
    base64_decode_standard,
)

from .framing import (
    ClientFramer,
    PoppedEnvelope,
)

from .protocol import (
    Protocol,
    ProtocolGrpcProto,
    ProtocolConnectProto,
    ProtocolConnectJson,
)

from .call_options import (
    CALL_DEADLINE_UNSET,
    CallOptions,
)

from .routing import (
    build_routing_params,
    match_path_template,
)

from .wire import (
    encode_unary_request,
    decode_unary_response,
    encode_stream_message,
)

from .stream import (
    STREAM_OUTCOME_MESSAGE,
    STREAM_OUTCOME_PENDING,
    STREAM_OUTCOME_END_OK,
    STREAM_OUTCOME_END_ERROR,
    StreamOutcome,
    ServerStreamDecoder,
    ClientStreamEncoder,
    BidiStreamCodec,
)

from .client import (
    GrpcClient,
    UnaryResult,
)

from .retry import (
    RETRY_CODES_AIP194,
    RETRY_CODES_UNAVAILABLE_OR_INTERNAL,
    RETRY_CODE_MASK_EMPTY,
    RetryPolicy,
    backoff_cap_ms,
    backoff_draw_ms,
    is_retryable_grpc_error,
    retry_code_bit,
    retry_mask_has,
    sleep_backoff_ms,
)

from .headers import (
    GRPC_HEADER_CONTENT_TYPE,
    GRPC_HEADER_ACCEPT,
    GRPC_HEADER_CONNECT_PROTOCOL_VERSION,
    GRPC_HEADER_GRPC_TIMEOUT,
    GRPC_HEADER_GRPC_ACCEPT_ENCODING,
    GRPC_HEADER_GRPC_ENCODING,
    GRPC_ENCODING_IDENTITY,
    build_unary_request_headers,
    build_stream_request_headers,
)

# Re-exports from komira_connect for one-line `from komira_grpc import ...`
# ergonomics. Codegen consumers import GRPC_STATUS_* / GrpcError from the
# same module — saves a per-file import for the 17 status constants.
from komira_connect.status import (
    GRPC_STATUS_OK,
    GRPC_STATUS_CANCELLED,
    GRPC_STATUS_UNKNOWN,
    GRPC_STATUS_INVALID_ARGUMENT,
    GRPC_STATUS_DEADLINE_EXCEEDED,
    GRPC_STATUS_NOT_FOUND,
    GRPC_STATUS_ALREADY_EXISTS,
    GRPC_STATUS_PERMISSION_DENIED,
    GRPC_STATUS_RESOURCE_EXHAUSTED,
    GRPC_STATUS_FAILED_PRECONDITION,
    GRPC_STATUS_ABORTED,
    GRPC_STATUS_OUT_OF_RANGE,
    GRPC_STATUS_UNIMPLEMENTED,
    GRPC_STATUS_INTERNAL,
    GRPC_STATUS_UNAVAILABLE,
    GRPC_STATUS_DATA_LOSS,
    GRPC_STATUS_UNAUTHENTICATED,
)
