"""`komira_connect` — Connect-RPC server runtime.

Server-side implementation of the Connect-RPC specification
(https://connectrpc.com). Supports three codecs over a unified service
surface:

  - grpc+proto       (classic gRPC, HTTP/2 only)
  - grpc-web+proto   (gRPC-Web, HTTP/1.1 + HTTP/2)
  - connect+json     (Connect protocol, HTTP/1.1 + HTTP/2)

`ConnectService` is the builder: a path-keyed method registry filled by
`register_method(path, handler)` calls, written by hand today.

Dependency direction (cycle-free):
  komira_connect -> komira_http   (HttpServer and its transport, TLS and
                                   codec layers)

Encapsulation: no UnsafePointer in any public signature, no wildcard
origins, no `unsafe_from_address`, no ArcPointer.
"""

from .envelope import (
    ENVELOPE_HEADER_SIZE,
    ENVELOPE_FLAG_COMPRESSED,
    ENVELOPE_FLAG_END_STREAM,
    EnvelopeView,
    write_envelope_header,
    write_envelope,
    read_envelope_header,
    split_envelopes,
    split_first_envelope,
)

from .codec_grpc import (
    GRPC_CONTENT_TYPE,
    GRPC_CONTENT_TYPE_PROTO,
    GRPC_TRAILER_STATUS,
    GRPC_TRAILER_MESSAGE,
    GrpcTrailers,
    grpc_encode_unary,
    grpc_append_message,
    grpc_decode_unary,
    grpc_decode_stream,
    grpc_make_trailers,
    grpc_make_ok_trailers,
    grpc_percent_encode_message,
    grpc_percent_encode_bytes,
    grpc_percent_decode_message,
)

from .codec_grpc_web import (
    GRPC_WEB_CONTENT_TYPE,
    GRPC_WEB_CONTENT_TYPE_PROTO,
    GrpcWebDecodedBody,
    grpc_web_encode_unary,
    grpc_web_encode_request,
    grpc_web_append_message,
    grpc_web_append_trailers,
    grpc_web_decode_response,
    grpc_web_decode_request,
)

from .codec_connect_json import (
    CONNECT_JSON_CONTENT_TYPE_UNARY,
    CONNECT_JSON_CONTENT_TYPE_STREAM,
    ConnectStreamDecodedBody,
    ConnectErrorEnvelope,
    connect_json_encode_unary,
    connect_json_decode_unary,
    connect_json_append_message,
    connect_json_append_end_stream,
    connect_json_decode_stream,
    build_connect_error_json,
    build_connect_end_stream_json,
    parse_connect_error_json,
)

from .deadline import (
    DEADLINE_UNSET_MICROS,
    parse_grpc_timeout,
    parse_connect_timeout_ms,
    encode_grpc_timeout_us,
)

from .dispatch import (
    CODEC_ID_UNKNOWN,
    CODEC_ID_GRPC,
    CODEC_ID_GRPC_WEB,
    CODEC_ID_CONNECT_JSON,
    ConnectHandlerFn,
    DispatchResult,
    codec_id_for_content_type,
    dispatch,
)

from .service import (
    ConnectMethodEntry,
    ConnectService,
    ConnectStreamHandlerFn,
    ConnectStreamMethodEntry,
)

from .server_integration import (
    CONNECT_SERVICE_HANDLER_ID,
    register_connect_wildcard,
    dispatch_connect_request,
)

from .status import (
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
    grpc_status_to_http_status,
    grpc_status_to_connect_name,
    connect_name_to_grpc_status,
    format_connect_error,
    parse_connect_error,
)
